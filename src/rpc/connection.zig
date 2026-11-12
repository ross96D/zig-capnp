//! Minimal two-party Cap'n Proto RPC runtime.
//!
//! This module implements the transport-independent message pump, the
//! Bootstrap/Call/Return/Finish subset, level-1 capability passing with
//! import/export reference tracking and Release messages, promise exports and
//! resolution, promise pipelining, and loopback Disembargo handling.
//! Third-party introductions remain out of scope.
//!
//! ## Capability ownership
//!
//! `Capability` is an owned, refcounted handle. Every handle is obtained with
//! an initial reference and must be released exactly once with `release()`.
//! Handles are created by:
//!
//!   - `Connection.initLocal`, from a borrowed `LocalCapability` descriptor,
//!   - `Connection.bootstrap` / `BootstrapPromise`,
//!   - `Response.capability`,
//!   - `Promise.capability`.
//!
//! `Connection.setBootstrap` consumes a handle. `Request.addCapability` and
//! `Call.addResultCapability` borrow their argument and retain it internally.
//! `Call.capabilities` entries are released by the runtime after dispatch; a
//! handler that stores one must call `retain()`.
//!
//! Local server objects are refcounted by `LocalEntry`. A `LocalCapability`
//! may supply an optional `destroy` callback, which is invoked exactly once,
//! when the last handle and the last wire export referencing the object are
//! gone (or when the connection is torn down).
//!
//! `Connection.deinit` invalidates any handles that are still outstanding;
//! release all handles before destroying the connection when possible.

const std = @import("std");
const capnp = @import("capnp");
pub const rpc = @import("rpc.zig");

pub const transport = @import("transport.zig");
pub const Transport = transport.Transport;
pub const Side = transport.Side;

pub const Call = struct {
    connection: *Connection,
    params: capnp.AnyPointerReader,
    results: capnp.AnyPointerBuilder,
    capabilities: []const Capability,
    result_capabilities: *std.ArrayList(Capability),

    /// Add a capability to the return payload and return its capability-table
    /// index. Set that index on a capability pointer in `results.content()`.
    ///
    /// The argument is borrowed; the runtime retains its own reference for the
    /// duration of the call.
    pub fn addResultCapability(self: Call, capability: Capability) !u32 {
        const index: u32 = @intCast(self.result_capabilities.items.len);
        try self.result_capabilities.append(self.connection.allocator, capability.retain());
        return index;
    }

    /// Convenience for the common case of returning a local capability.
    /// Interns the descriptor, borrows the temporary handle, and releases it.
    pub fn addLocalResultCapability(self: Call, capability: LocalCapability) !u32 {
        const handle = try self.connection.initLocal(capability);
        defer handle.release();
        return self.addResultCapability(handle);
    }
};

pub const DispatchFn = *const fn (
    context: *anyopaque,
    method_id: u16,
    call: Call,
) anyerror!void;

pub const LocalCapability = struct {
    /// Per-object context. Use null for stateless interfaces.
    context: ?*anyopaque,
    interface_id: u64,
    dispatch: DispatchFn,
    /// Optional. Called once when the last handle and wire export are gone.
    destroy: ?*const fn (context: *anyopaque) void = null,
};

/// `DispatchFn` requires a non-null context; stateless descriptors use this
/// stable dummy pointer so that dereferencing it remains a programming error.
var stateless_context: u8 = 0;

fn dispatchContext(context: ?*anyopaque) *anyopaque {
    return context orelse @ptrCast(&stateless_context);
}

pub const DisembargoCallback = struct {
    context: *anyopaque,
    function: *const fn (context: *anyopaque, embargo_id: u32) void,
};

const LocalKey = struct {
    context: usize,
    interface_id: u64,
    dispatch: usize,
};

const LocalKeyContext = struct {
    pub fn hash(_: LocalKeyContext, key: LocalKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.context));
        hasher.update(std.mem.asBytes(&key.interface_id));
        hasher.update(std.mem.asBytes(&key.dispatch));
        return hasher.final();
    }

    pub fn eql(_: LocalKeyContext, a: LocalKey, b: LocalKey) bool {
        return a.context == b.context and
            a.interface_id == b.interface_id and
            a.dispatch == b.dispatch;
    }
};

const LocalEntry = struct {
    connection: *Connection,
    key: LocalKey,
    capability: LocalCapability,
    refs: u32,
    /// At most one wire export id; reused while the peer holds references.
    export_id: ?u32 = null,
};

const ImportEntry = struct {
    connection: *Connection,
    export_id: u32,
    /// Number of `senderHosted`/`senderPromise` descriptors received whose
    /// references have not yet been returned with a Release message.
    wire_refs: u32,
    /// Number of live `Capability` handles sharing this import.
    handle_refs: u32,
    /// Set when a Resolve message names this promise. Kept alive until the
    /// import itself is released.
    resolved: Capability = .none,
};

const PendingCall = struct {
    question_id: u32,
    bytes: []u8,
};

const ExportKind = enum {
    hosted,
    promise,
};

const ExportEntry = struct {
    connection: *Connection,
    export_id: u32,
    /// Owned by the export table.
    capability: Capability,
    wire_refs: u32,
    /// Number of live `Capability.promised` handles.
    handle_refs: u32 = 0,
    kind: ExportKind = .hosted,
    pending_calls: std.ArrayList(PendingCall) = .empty,
};

const FinishState = enum {
    not_sent,
    sent,
};

const QuestionRef = struct {
    connection: *Connection,
    id: u32,
    refs: u32,
    caps_taken: bool = false,
    finish_state: FinishState = .not_sent,
    /// Export ids created while encoding this question's params. Used to
    /// apply `Return.releaseParamCaps`.
    param_export_ids: std.ArrayList(u32) = .empty,

    fn retain(self: *QuestionRef) *QuestionRef {
        self.refs += 1;
        return self;
    }

    fn release(self: *QuestionRef) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs == 0) self.connection.finishQuestion(self);
    }
};

const AnswerCapability = struct {
    connection: *Connection,
    question_id: u32,
    pointer_field: ?u16,
    /// Non-null when this handle belongs to one of our outgoing questions.
    question: ?*QuestionRef,
    refs: u32,
};

const AnswerCallState = enum {
    /// A placeholder created so pipelined calls have somewhere to attach.
    reserved,
    /// The original Call has been received (dispatching or queued).
    received,
};

const AnswerState = struct {
    resolved_bytes: ?[]u8 = null,
    /// Tracks whether the original Call for this question has been received.
    /// Placeholder entries created for pipelining remain `.reserved`.
    call_state: AnswerCallState = .reserved,
    pending: std.ArrayList(PendingCall) = .empty,
    /// Export ids created while encoding this answer's cap table.
    export_ids: std.ArrayList(u32) = .empty,
    /// Capabilities from the params, kept alive until Finish so that result
    /// descriptors such as receiverHosted can still resolve.
    held_caps: std.ArrayList(Capability) = .empty,
};

pub const Capability = union(enum) {
    local: *LocalEntry,
    imported: *ImportEntry,
    promised: *ExportEntry,
    /// Pipelining on the result of a question we asked.
    answer_pipeline: *AnswerCapability,
    /// A capability we promised as part of an answer we owe the peer.
    answer_promise: *AnswerCapability,
    none: void,

    /// Add one reference to this handle and return it.
    pub fn retain(self: Capability) Capability {
        switch (self) {
            .local => |entry| entry.refs += 1,
            .imported => |entry| entry.handle_refs += 1,
            .promised => |entry| entry.handle_refs += 1,
            .answer_pipeline => |entry| entry.refs += 1,
            .answer_promise => |entry| entry.refs += 1,
            .none => {},
        }
        return self;
    }

    /// Release one reference. The handle must not be used afterwards.
    pub fn release(self: Capability) void {
        switch (self) {
            .local => |entry| entry.connection.releaseLocal(entry),
            .imported => |entry| entry.connection.releaseImport(entry),
            .promised => |entry| entry.connection.releasePromiseHandle(entry),
            .answer_pipeline, .answer_promise => |entry| entry.connection.releaseAnswerCapability(entry),
            .none => {},
        }
    }

    pub fn beginCall(self: Capability, interface_id: u64, method_id: u16) !Request {
        return switch (self) {
            .local => |entry| entry.connection.beginLocalCall(entry, interface_id, method_id),
            .imported => |entry| entry.connection.beginImportCall(entry, interface_id, method_id),
            .promised => |entry| entry.connection.beginPromiseCall(entry, interface_id, method_id),
            .answer_pipeline => |entry| entry.connection.beginPipelinedCall(entry, interface_id, method_id),
            .answer_promise => |entry| entry.connection.beginPromisedAnswerCall(entry, interface_id, method_id),
            .none => error.NoCapability,
        };
    }
};

fn isNone(capability: Capability) bool {
    return switch (capability) {
        .none => true,
        else => false,
    };
}

pub const ResponseWireState = struct {
    question: ?*QuestionRef = null,
    caps_taken: bool = false,
    /// One flag per result cap-table entry, set when the entry has been
    /// decoded. Used to release result capabilities the caller did not take.
    taken_caps: ?[]bool = null,
};

pub const ResponseLocalState = struct {
    /// Owned capabilities for in-process (local) calls, indexed like the cap
    /// table. Released by `deinit`.
    caps: []Capability,
};

pub const ResponseState = union(enum) {
    /// A Return message received over the wire.
    wire: ResponseWireState,
    /// A Response synthesized by an in-process call.
    local: ResponseLocalState,
    deinitialized: void,
};

pub const Response = struct {
    message: capnp.Message,
    connection: *Connection,
    allocator: std.mem.Allocator,
    state: ResponseState,

    pub fn fromBytes(bytes: []const u8, connection: *Connection) !Response {
        const message = try capnp.Message.fromBytes(bytes, connection.allocator);
        return .{
            .message = message,
            .connection = connection,
            .allocator = connection.allocator,
            .state = .{ .wire = .{} },
        };
    }

    pub fn deinit(self: *Response) void {
        const allocator = self.allocator;
        switch (self.state) {
            .deinitialized => return,
            .wire => |*wire| {
                if (wire.taken_caps != null) self.releaseUntakenCaps();
                if (wire.taken_caps) |flags| {
                    allocator.free(flags);
                    wire.taken_caps = null;
                }
                if (wire.question) |question| {
                    question.caps_taken = question.caps_taken or wire.caps_taken;
                    wire.question = null;
                    question.release();
                }
            },
            .local => |*local| {
                for (local.caps) |handle| handle.release();
                allocator.free(local.caps);
            },
        }
        self.message.deinit(allocator);
        self.state = .deinitialized;
    }

    fn attachQuestion(self: *Response, question: *QuestionRef) void {
        switch (self.state) {
            .wire => |*wire| wire.question = question,
            .local, .deinitialized => unreachable,
        }
    }

    fn markTaken(self: *Response, cap_count: u29, index: u32) !void {
        const wire = switch (self.state) {
            .wire => |*wire| wire,
            .local, .deinitialized => unreachable,
        };
        if (wire.taken_caps == null) {
            const flags = try self.allocator.alloc(bool, @intCast(cap_count));
            @memset(flags, false);
            wire.taken_caps = flags;
        }
        wire.taken_caps.?[index] = true;
    }

    /// Finish was sent with `releaseResultCaps = false` because at least one
    /// result capability was taken. Release the exports that were not taken.
    fn releaseUntakenCaps(self: *Response) void {
        const wire = switch (self.state) {
            .wire => |*wire| wire,
            .local, .deinitialized => return,
        };
        const result_payload = self.payload() catch return;
        const cap_table = result_payload.capTable() catch return;
        const flags = wire.taken_caps.?;
        for (0..cap_table.length) |i| {
            if (i < flags.len and flags[i]) continue;
            const descriptor = cap_table.get(@intCast(i));
            if (descriptor.senderHosted()) |export_id| {
                self.connection.sendRelease(export_id, 1) catch |err| self.connection.noteError(err);
            } else if (descriptor.senderPromise()) |export_id| {
                self.connection.sendRelease(export_id, 1) catch |err| self.connection.noteError(err);
            }
        }
    }

    pub fn returnReader(self: *Response) !rpc.Return.Reader {
        if (self.state == .deinitialized) return error.InvalidResponse;
        const root = try self.message.getRootStruct(rpc.Message.Reader, rpc.Message.reader_trait);
        return (try root.@"return"()) orelse error.InvalidReturn;
    }

    pub fn which(self: *Response) !rpc.Return.Tag {
        return (try self.returnReader()).which();
    }

    pub fn payload(self: *Response) !rpc.Payload.Reader {
        const return_ = try self.returnReader();
        return (try return_.results()) orelse error.InvalidReturn;
    }

    pub fn results(self: *Response, comptime T: type, comptime trait: capnp.ReaderTrait(T)) !T {
        const result_payload = try self.payload();
        const content = try result_payload.content();
        return content.asStruct(T, trait);
    }

    /// Decode a capability from the result cap table. The returned handle owns
    /// one reference and must be released by the caller.
    pub fn capability(self: *Response, index: u32) !Capability {
        switch (self.state) {
            .deinitialized => return error.InvalidResponse,
            .local => |local| {
                if (index >= local.caps.len) return error.InvalidCapability;
                return local.caps[index].retain();
            },
            .wire => |*wire| {
                const result_payload = try self.payload();
                const cap_table = try result_payload.capTable();
                if (index >= cap_table.length) return error.InvalidCapability;
                if (wire.taken_caps) |flags| {
                    if (index < flags.len and flags[index]) return error.CapabilityAlreadyTaken;
                }
                const handle = try self.connection.decodeCapability(cap_table.get(index));
                if (!isNone(handle)) {
                    self.markTaken(cap_table.length, index) catch |err| {
                        handle.release();
                        return err;
                    };
                    wire.caps_taken = true;
                    if (wire.question) |question| question.caps_taken = true;
                }
                return handle;
            },
        }
    }

    pub fn exception(self: *Response) !?rpc.Exception.Reader {
        const return_ = try self.returnReader();
        return try return_.exception();
    }
};

pub const RequestPending = struct {
    message: *capnp.MessageBuilder,
    call: rpc.Call.Builder,
    question_id: u32,
    question: ?*QuestionRef = null,
    caps: std.ArrayList(Capability) = .empty,
    params_builder: ?rpc.Payload.Builder = null,
    local_target: ?*LocalEntry = null,
    target: Capability = .none,
};

pub const RequestState = union(enum) {
    pending: RequestPending,
    started: void,
    deinitialized: void,
};

pub const Request = struct {
    connection: *Connection,
    state: RequestState,

    fn pendingState(self: *Request) !*RequestPending {
        return switch (self.state) {
            .pending => |*pending| pending,
            .started, .deinitialized => error.AlreadySent,
        };
    }

    fn pendingParams(_: *Request, pending: *RequestPending) !rpc.Payload.Builder {
        // Building the params field again would allocate a fresh Payload and
        // discard any content or cap table already written to it, so cache the
        // builder for the lifetime of the request.
        if (pending.params_builder) |payload| return payload;
        const payload = try pending.call.params();
        pending.params_builder = payload;
        return payload;
    }

    pub fn params(self: *Request) !rpc.Payload.Builder {
        return self.pendingParams(try self.pendingState());
    }

    pub fn initParams(self: *Request, comptime T: type, comptime trait: capnp.BuilderTrait(T)) !T {
        const payload = try self.params();
        return payload.content().initStruct(T, trait);
    }

    /// Add a capability to the params cap table and return its index.
    /// The argument is borrowed; the request retains it until `deinit`.
    pub fn addCapability(self: *Request, capability: Capability) !u32 {
        const pending = try self.pendingState();
        const index: u32 = @intCast(pending.caps.items.len);
        try pending.caps.append(self.connection.allocator, capability.retain());
        return index;
    }

    /// Convenience for the common case of passing a local capability.
    pub fn addLocalCapability(self: *Request, capability: LocalCapability) !u32 {
        const handle = try self.connection.initLocal(capability);
        defer handle.release();
        return self.addCapability(handle);
    }

    fn deinitCaps(self: *Request, pending: *RequestPending) void {
        for (pending.caps.items) |capability| capability.release();
        pending.caps.deinit(self.connection.allocator);
    }

    fn releaseTarget(_: *Request, pending: *RequestPending) void {
        pending.target.release();
        pending.target = .none;
    }

    fn discardQuestion(self: *Request, pending: *RequestPending) void {
        if (pending.question) |question| {
            pending.question = null;
            self.connection.destroyQuestion(question);
        }
    }

    fn encodeCaps(self: *Request, pending: *RequestPending) !void {
        if (pending.caps.items.len == 0) return;
        const payload = try self.pendingParams(pending);
        var cap_table = try payload.capTable();
        try cap_table.init(@intCast(pending.caps.items.len));
        for (pending.caps.items, 0..) |capability, i| {
            const export_id = try self.connection.encodeCapability(capability, cap_table.get(@intCast(i)));
            if (export_id) |id| {
                if (pending.question) |question| {
                    try question.param_export_ids.append(self.connection.allocator, id);
                }
            }
        }
    }

    /// Send the call without waiting for its Return. The returned Promise can
    /// be used to pipeline calls on the eventual result.
    pub fn start(self: *Request) !Promise {
        const pending = try self.pendingState();
        if (pending.local_target) |local| return self.startLocal(pending, local);

        const allocator = self.connection.allocator;
        const question = pending.question orelse return error.MissingQuestion;

        try self.encodeCaps(pending);

        const bytes = try pending.message.toBytes(allocator);
        defer allocator.free(bytes);

        try self.connection.sendRaw(bytes);

        pending.message.deinit();
        allocator.destroy(pending.message);
        self.deinitCaps(pending);
        self.releaseTarget(pending);
        self.state = .started;

        return .{ .connection = self.connection, .state = .{ .question = question } };
    }

    fn startLocal(self: *Request, pending: *RequestPending, local: *LocalEntry) !Promise {
        const allocator = self.connection.allocator;

        // Local calls never go over the wire, so the params' capability
        // pointers should reference the request's handles directly rather than
        // being exported and then decoded as imports of ourselves.

        const request_bytes = try pending.message.toBytes(allocator);
        defer allocator.free(request_bytes);

        var request_message = try capnp.Message.fromBytes(request_bytes, allocator);
        defer request_message.deinit(allocator);

        const root = try request_message.getRootStruct(rpc.Message.Reader, rpc.Message.reader_trait);
        const call = (try root.call()) orelse return error.InvalidMessage;

        var return_bytes: ?[]u8 = null;
        var local_caps = std.ArrayList(Capability).empty;
        errdefer {
            for (local_caps.items) |capability| capability.release();
            local_caps.deinit(allocator);
        }
        try self.connection.dispatchLocalCall(
            call,
            local.capability,
            pending.question_id,
            &return_bytes,
            &local_caps,
            pending.caps.items,
        );
        const bytes = return_bytes.?;
        defer allocator.free(bytes);

        var response = try Response.fromBytes(bytes, self.connection);
        const caps = local_caps.toOwnedSlice(allocator) catch |err| {
            response.deinit();
            return err;
        };
        response.state = .{ .local = .{ .caps = caps } };

        pending.message.deinit();
        allocator.destroy(pending.message);
        self.deinitCaps(pending);
        self.releaseTarget(pending);
        self.state = .started;

        if (self.connection.dispatch_depth == 0) {
            self.connection.drainDeferredCalls() catch |err| {
                response.deinit();
                return err;
            };
        }

        return .{
            .connection = self.connection,
            .state = .{ .local_response = response },
        };
    }

    pub fn send(self: *Request) !Response {
        var promise = try self.start();
        // `wait` transfers the question reference into the returned Response
        // on success. On failure the promise still owns it, so release it
        // (which also sends Finish) rather than leaking the question.
        defer promise.deinit();
        return promise.wait();
    }

    pub fn deinit(self: *Request) void {
        switch (self.state) {
            .pending => |*pending| {
                self.deinitCaps(pending);
                self.releaseTarget(pending);
                self.discardQuestion(pending);
                pending.message.deinit();
                self.connection.allocator.destroy(pending.message);
                self.state = .deinitialized;
            },
            .started, .deinitialized => self.state = .deinitialized,
        }
    }
};

pub const PromiseState = union(enum) {
    question: *QuestionRef,
    local_response: Response,
    finished: void,
};

pub const Promise = struct {
    connection: *Connection,
    state: PromiseState,

    /// Release this promise without waiting for its Return, canceling the
    /// call if it is still outstanding.
    pub fn deinit(self: *Promise) void {
        switch (self.state) {
            .finished => {},
            .local_response => |*response| {
                response.deinit();
                self.state = .finished;
            },
            .question => |question| {
                self.state = .finished;
                question.release();
            },
        }
    }

    pub fn wait(self: *Promise) !Response {
        switch (self.state) {
            .finished => return error.AlreadyFinished,
            .local_response => |response| {
                self.state = .finished;
                return response;
            },
            .question => |question| {
                var response = try self.connection.waitReturn(question.id);
                response.attachQuestion(question);
                self.state = .finished;
                return response;
            },
        }
    }

    /// Non-blocking completion check. The caller is responsible for driving
    /// `Connection.step()` as transport events arrive.
    pub fn tryTake(self: *Promise) !?Response {
        switch (self.state) {
            .finished => return error.AlreadyFinished,
            .local_response => |response| {
                self.state = .finished;
                return response;
            },
            .question => |question| {
                const response = (try self.connection.takeReturn(question.id)) orelse return null;
                var result = response;
                result.attachQuestion(question);
                self.state = .finished;
                return result;
            },
        }
    }

    /// Return a capability handle addressing the root result, or a pointer
    /// field within the result struct. The caller owns the handle.
    pub fn capability(self: *Promise, pointer_field: ?u16) !Capability {
        switch (self.state) {
            .finished => return error.AlreadyFinished,
            .local_response => return error.LocalPipeliningUnsupported,
            .question => |question| return self.connection.newAnswerCapability(question, pointer_field),
        }
    }
};

pub const BootstrapPromiseState = union(enum) {
    question: *QuestionRef,
    finished: void,
};

pub const BootstrapPromise = struct {
    connection: *Connection,
    state: BootstrapPromiseState,

    /// Release this bootstrap request without waiting for its Return.
    pub fn deinit(self: *BootstrapPromise) void {
        switch (self.state) {
            .finished => {},
            .question => |question| {
                self.state = .finished;
                question.release();
            },
        }
    }

    /// Return a capability handle addressing the bootstrap result. The caller
    /// owns the handle. As with `Promise.capability`, this can be used to
    /// pipeline calls before the bootstrap Return arrives.
    pub fn capability(self: *BootstrapPromise) !Capability {
        switch (self.state) {
            .finished => return error.AlreadyFinished,
            .question => |question| return self.connection.newAnswerCapability(question, null),
        }
    }

    pub fn wait(self: *BootstrapPromise) !Capability {
        switch (self.state) {
            .finished => return error.AlreadyFinished,
            .question => |question| {
                var response = self.connection.waitReturn(question.id) catch |err| {
                    self.state = .finished;
                    question.release();
                    return err;
                };
                defer response.deinit();

                const bootstrap_capability = self.connection.finishBootstrap(&response) catch |err| {
                    self.state = .finished;
                    question.release();
                    return err;
                };

                question.caps_taken = !isNone(bootstrap_capability);
                self.state = .finished;
                question.release();
                return bootstrap_capability;
            },
        }
    }

    /// Non-blocking completion check. The caller is responsible for driving
    /// `Connection.step()` as transport events arrive.
    pub fn tryTake(self: *BootstrapPromise) !?Capability {
        switch (self.state) {
            .finished => return error.AlreadyFinished,
            .question => |question| {
                const response = (self.connection.takeReturn(question.id) catch |err| {
                    self.state = .finished;
                    question.release();
                    return err;
                }) orelse return null;
                var result = response;
                defer result.deinit();

                const bootstrap_capability = self.connection.finishBootstrap(&result) catch |err| {
                    self.state = .finished;
                    question.release();
                    return err;
                };

                question.caps_taken = !isNone(bootstrap_capability);
                self.state = .finished;
                question.release();
                return bootstrap_capability;
            },
        }
    }
};

pub const ConnectionLifecycle = enum { open, closing, closed };
pub const ConnectionDrainState = enum { idle, draining };

pub const Connection = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    /// Optional in-process peer. When set, sending a message immediately pumps
    /// the peer so that the blocking `Request.send` path can complete without
    /// an external event loop.
    peer: ?*Connection = null,
    bootstrap_capability: Capability = .none,
    disembargo_callback: ?DisembargoCallback = null,
    next_question_id: u32 = 1,
    next_export_id: u32 = 1,
    returns: std.AutoHashMap(u32, []u8),
    exports: std.AutoHashMap(u32, *ExportEntry),
    imports: std.AutoHashMap(u32, *ImportEntry),
    locals: std.HashMap(LocalKey, *LocalEntry, LocalKeyContext, std.hash_map.default_max_load_percentage),
    answers: std.AutoHashMap(u32, AnswerState),
    questions: std.AutoHashMap(u32, *QuestionRef),
    queued_questions: std.AutoHashMap(u32, void),
    answer_capabilities: std.ArrayList(*AnswerCapability) = .empty,
    dispatch_depth: usize = 0,
    deferred_calls: std.ArrayList(PendingCall) = .empty,
    drain_state: ConnectionDrainState = .idle,
    pending_error: ?anyerror = null,
    lifecycle: ConnectionLifecycle = .open,

    pub fn init(allocator: std.mem.Allocator, transport_value: Transport) !*Connection {
        const self = try allocator.create(Connection);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .transport = transport_value,
            .returns = std.AutoHashMap(u32, []u8).init(allocator),
            .exports = std.AutoHashMap(u32, *ExportEntry).init(allocator),
            .imports = std.AutoHashMap(u32, *ImportEntry).init(allocator),
            .locals = std.HashMap(LocalKey, *LocalEntry, LocalKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .answers = std.AutoHashMap(u32, AnswerState).init(allocator),
            .questions = std.AutoHashMap(u32, *QuestionRef).init(allocator),
            .queued_questions = std.AutoHashMap(u32, void).init(allocator),
        };
        return self;
    }

    pub fn fd(self: *Connection) std.posix.fd_t {
        return self.transport.fd();
    }

    pub fn wantsWrite(self: *Connection) bool {
        return self.transport.wantsWrite();
    }

    pub fn isClosed(self: *Connection) bool {
        return self.lifecycle == .closed or self.transport.isClosed();
    }

    pub fn deinit(self: *Connection) void {
        const allocator = self.allocator;
        if (self.peer) |peer| {
            // Keep the peer from retaining a pointer to freed connection state.
            if (peer.peer == self) peer.peer = null;
        }
        self.lifecycle = .closing;
        self.bootstrap_capability.release();
        self.bootstrap_capability = .none;

        var return_it = self.returns.valueIterator();
        while (return_it.next()) |bytes| self.allocator.free(bytes.*);
        self.returns.deinit();

        // Answer-held capabilities may reference imports, exports, or questions,
        // so release them before tearing those tables down.
        while (self.answers.count() != 0) {
            var answer_it = self.answers.iterator();
            const question_id = answer_it.next().?.key_ptr.*;
            var answer = self.answers.fetchRemove(question_id).?.value;
            for (answer.held_caps.items) |capability| capability.release();
            answer.held_caps.deinit(self.allocator);
            if (answer.resolved_bytes) |bytes| self.allocator.free(bytes);
            for (answer.pending.items) |item| {
                _ = self.queued_questions.remove(item.question_id);
                self.allocator.free(item.bytes);
            }
            answer.pending.deinit(self.allocator);
            answer.export_ids.deinit(self.allocator);
        }
        self.answers.deinit();

        // Remove each entry before destroying it: releasing a capability may
        // recursively destroy another export or import, and hash maps must not
        // be mutated while they are being iterated.
        while (self.exports.count() != 0) {
            var export_it = self.exports.valueIterator();
            const entry = export_it.next().?.*;
            _ = self.exports.remove(entry.export_id);
            self.destroyExport(entry);
        }
        self.exports.deinit();

        while (self.imports.count() != 0) {
            var import_it = self.imports.valueIterator();
            const entry = import_it.next().?.*;
            _ = self.imports.remove(entry.export_id);
            self.destroyImport(entry);
        }
        self.imports.deinit();

        while (self.answer_capabilities.items.len != 0) {
            const entry = self.answer_capabilities.pop().?;
            if (entry.question) |question| {
                std.debug.assert(question.refs > 0);
                question.refs -= 1;
            }
            self.allocator.destroy(entry);
        }
        self.answer_capabilities.deinit(self.allocator);

        while (self.questions.count() != 0) {
            var question_it = self.questions.valueIterator();
            const question = question_it.next().?.*;
            _ = self.questions.remove(question.id);
            question.param_export_ids.deinit(self.allocator);
            self.allocator.destroy(question);
        }
        self.questions.deinit();
        self.queued_questions.deinit();

        self.destroyRemainingLocals();

        for (self.deferred_calls.items) |item| self.allocator.free(item.bytes);
        self.deferred_calls.deinit(self.allocator);

        self.lifecycle = .closed;
        allocator.destroy(self);
    }

    fn destroyRemainingLocals(self: *Connection) void {
        while (self.locals.count() != 0) {
            var it = self.locals.valueIterator();
            const entry = it.next().?.*;
            _ = self.locals.remove(entry.key);
            if (entry.capability.destroy) |destroy| destroy(dispatchContext(entry.capability.context));
            self.allocator.destroy(entry);
        }
        self.locals.deinit();
    }

    fn destroyExport(self: *Connection, entry: *ExportEntry) void {
        switch (entry.capability) {
            .local => |local| {
                if (local.export_id == entry.export_id) local.export_id = null;
            },
            else => {},
        }
        if (!isNone(entry.capability)) entry.capability.release();
        for (entry.pending_calls.items) |item| {
            _ = self.queued_questions.remove(item.question_id);
            self.allocator.free(item.bytes);
        }
        entry.pending_calls.deinit(self.allocator);
        self.allocator.destroy(entry);
    }

    fn destroyImport(self: *Connection, entry: *ImportEntry) void {
        if (!isNone(entry.resolved)) entry.resolved.release();
        self.allocator.destroy(entry);
    }

    fn destroyQuestion(self: *Connection, question: *QuestionRef) void {
        if (self.questions.get(question.id) == question) {
            _ = self.questions.remove(question.id);
        }
        if (self.returns.fetchRemove(question.id)) |removed| {
            self.allocator.free(removed.value);
        }
        question.param_export_ids.deinit(self.allocator);
        self.allocator.destroy(question);
    }

    fn finishQuestion(self: *Connection, question: *QuestionRef) void {
        if (question.finish_state == .not_sent) {
            question.finish_state = .sent;
            if (self.lifecycle == .open) {
                self.sendFinish(question.id, !question.caps_taken) catch |err| self.noteError(err);
            }
        }
        self.destroyQuestion(question);
    }

    fn noteError(self: *Connection, err: anyerror) void {
        if (self.pending_error == null) self.pending_error = err;
    }

    /// Mark the connection unusable and notify the peer. Used for protocol
    /// errors that cannot be reported as a call exception.
    fn failConnection(
        self: *Connection,
        err: anyerror,
        abort_type: rpc.Exception.Type,
    ) anyerror {
        if (self.lifecycle == .open) {
            self.sendAbort(@errorName(err), abort_type) catch {};
        }
        self.lifecycle = .closed;
        return err;
    }

    fn sendAbort(
        self: *Connection,
        reason: [:0]const u8,
        abort_type: rpc.Exception.Type,
    ) !void {
        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var exception = try root.setAbort();
        try exception.setReason(reason);
        exception.setType(abort_type);

        const bytes = try message.toBytes(self.allocator);
        defer self.allocator.free(bytes);
        try self.sendRaw(bytes);
    }

    /// Create an owned handle for a local capability. Descriptors with the same
    /// context, interface id, and dispatch function share one `LocalEntry`.
    pub fn initLocal(self: *Connection, capability: LocalCapability) !Capability {
        const key = LocalKey{
            .context = if (capability.context) |ptr| @intFromPtr(ptr) else 0,
            .interface_id = capability.interface_id,
            .dispatch = @intFromPtr(capability.dispatch),
        };

        if (self.locals.get(key)) |entry| {
            entry.refs += 1;
            if (entry.capability.destroy == null) entry.capability.destroy = capability.destroy;
            return .{ .local = entry };
        }

        const entry = try self.allocator.create(LocalEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .connection = self,
            .key = key,
            .capability = capability,
            .refs = 1,
        };
        try self.locals.put(key, entry);
        return .{ .local = entry };
    }

    fn releaseLocal(self: *Connection, entry: *LocalEntry) void {
        std.debug.assert(entry.refs > 0);
        entry.refs -= 1;
        if (entry.refs != 0) return;

        std.debug.assert(entry.export_id == null);
        if (self.locals.get(entry.key) == entry) {
            _ = self.locals.remove(entry.key);
        }
        if (entry.capability.destroy) |destroy| destroy(dispatchContext(entry.capability.context));
        self.allocator.destroy(entry);
    }

    pub fn setBootstrap(self: *Connection, capability: Capability) void {
        if (!isNone(self.bootstrap_capability)) self.bootstrap_capability.release();
        self.bootstrap_capability = capability;
    }

    pub fn setDisembargoCallback(self: *Connection, callback: ?DisembargoCallback) void {
        self.disembargo_callback = callback;
    }

    /// Process all currently available messages and flush buffered output.
    /// This never waits for the transport.
    pub fn step(self: *Connection) !void {
        if (self.lifecycle == .closed) return error.EndOfStream;
        if (self.pending_error) |err| {
            self.pending_error = null;
            return err;
        }
        while (try self.transport.receive(self.allocator)) |bytes| {
            defer self.allocator.free(bytes);
            self.handle(bytes) catch |err| return self.failConnection(err, .failed);
            if (self.dispatch_depth == 0) {
                self.drainDeferredCalls() catch |err| return self.failConnection(err, .failed);
            }
        }
        try self.transport.flush();
    }

    fn waitForProgress(self: *Connection) !void {
        if (self.transport.fd() < 0) {
            const peer = self.peer orelse return error.NoWaitSource;
            try peer.step();
            try self.step();
            return;
        }

        var events: i16 = std.posix.POLL.IN;
        if (self.transport.wantsWrite()) events |= std.posix.POLL.OUT;

        var fds = [1]std.posix.pollfd{.{
            .fd = self.transport.fd(),
            .events = events,
            .revents = 0,
        }};
        _ = try std.posix.poll(&fds, -1);
        try self.step();
    }

    pub fn bootstrapStart(self: *Connection) !BootstrapPromise {
        const question = try self.newQuestion();
        errdefer self.destroyQuestion(question);

        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var bootstrap_message = try root.setBootstrap();
        bootstrap_message.setQuestionId(question.id);

        const bytes = try message.toBytes(self.allocator);
        defer self.allocator.free(bytes);

        try self.sendRaw(bytes);
        return .{ .connection = self, .state = .{ .question = question } };
    }

    pub fn bootstrap(self: *Connection) !Capability {
        var promise = try self.bootstrapStart();
        return promise.wait();
    }

    fn finishBootstrap(self: *Connection, response: *Response) !Capability {
        _ = self;
        switch (try response.which()) {
            .results => {
                const payload = try response.payload();
                const content = try payload.content();
                const cap_index = try content.asCapability();
                return response.capability(cap_index);
            },
            .exception => return error.RemoteException,
            else => return error.InvalidReturn,
        }
    }

    pub fn newPromise(self: *Connection) !Capability {
        const export_id = self.allocExportId();
        const entry = try self.allocator.create(ExportEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .connection = self,
            .export_id = export_id,
            .capability = .none,
            .wire_refs = 0,
            .handle_refs = 1,
            .kind = .promise,
        };
        try self.exports.put(export_id, entry);
        return .{ .promised = entry };
    }

    pub fn resolvePromise(self: *Connection, promise: Capability, target: Capability) !void {
        const entry = switch (promise) {
            .promised => |value| value,
            else => return error.NotPromise,
        };
        if (entry.connection != self) return error.WrongConnection;
        if (entry.kind != .promise) return error.NotPromise;

        entry.kind = .hosted;
        const previous = entry.capability;
        entry.capability = target.retain();
        if (!isNone(previous)) previous.release();

        var pending = entry.pending_calls;
        entry.pending_calls = .empty;
        defer {
            for (pending.items) |item| self.allocator.free(item.bytes);
            pending.deinit(self.allocator);
        }

        self.sendResolve(entry.export_id, target) catch |err| {
            // The peer will never forward these calls now. Report the failure
            // for each queued call instead of leaving its caller blocked.
            for (pending.items) |item| {
                _ = self.queued_questions.remove(item.question_id);
                self.sendException(item.question_id, err, true) catch {};
            }
            self.maybeDestroyExport(entry);
            return err;
        };

        for (pending.items) |item| {
            _ = self.queued_questions.remove(item.question_id);
            // The placeholder answer entry was created when the call was
            // queued. Let the replay claim it again without tripping the
            // duplicate-question check, while preserving any pipelined calls
            // already attached to it.
            if (self.answers.getPtr(item.question_id)) |answer| answer.call_state = .reserved;
            self.handle(item.bytes) catch |err| {
                // If replay failed before the answer could be claimed again,
                // keep treating the question as received so a duplicate Call
                // cannot overwrite the entry.
                if (self.answers.getPtr(item.question_id)) |answer| answer.call_state = .received;
                self.sendException(item.question_id, err, true) catch {};
            };
        }

        // Replayed calls may have attached pipelined calls while dispatching.
        // Those get deferred because dispatch_depth is nonzero; drain them now
        // that we are back at the top level.
        if (self.dispatch_depth == 0) try self.drainDeferredCalls();

        self.maybeDestroyExport(entry);
    }

    pub fn beginCall(
        self: *Connection,
        target: Capability,
        interface_id: u64,
        method_id: u16,
    ) anyerror!Request {
        return switch (target) {
            .local => |entry| self.beginLocalCall(entry, interface_id, method_id),
            .imported => |entry| self.beginImportCall(entry, interface_id, method_id),
            .promised => |entry| self.beginPromiseCall(entry, interface_id, method_id),
            .answer_pipeline => |entry| self.beginPipelinedCall(entry, interface_id, method_id),
            .answer_promise => |entry| self.beginPromisedAnswerCall(entry, interface_id, method_id),
            .none => error.NoCapability,
        };
    }

    fn beginPromiseCall(
        self: *Connection,
        entry: *ExportEntry,
        interface_id: u64,
        method_id: u16,
    ) !Request {
        if (entry.connection != self) return error.WrongConnection;
        if (entry.kind == .promise) return error.LocalTargetUnsupported;
        return self.beginCall(entry.capability, interface_id, method_id);
    }

    fn beginImportCall(
        self: *Connection,
        entry: *ImportEntry,
        interface_id: u64,
        method_id: u16,
    ) !Request {
        if (entry.connection != self) return error.WrongConnection;
        if (self.imports.get(entry.export_id) != entry) return error.UnknownCapability;

        // If the peer resolved this promise to a capability we host locally,
        // route the call directly. Sending it to the promise id would make the
        // peer forward it back (or reject it), and there is no wire ordering
        // to preserve for a locally-hosted target.
        switch (entry.resolved) {
            .local => |resolved| return self.beginLocalCall(resolved, interface_id, method_id),
            else => {},
        }

        const question = try self.newQuestion();
        errdefer self.destroyQuestion(question);

        const message = try self.allocator.create(capnp.MessageBuilder);
        errdefer self.allocator.destroy(message);
        message.* = .{ .allocator = self.allocator };
        try message.init();
        errdefer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var call = try root.setCall();
        call.setQuestionId(question.id);

        var message_target = try call.target();
        message_target.setImportedCap(entry.export_id);
        call.setInterfaceId(interface_id);
        call.setMethodId(method_id);

        const retained_target: Capability = .{ .imported = entry };
        return .{
            .connection = self,
            .state = .{ .pending = .{
                .message = message,
                .call = call,
                .question_id = question.id,
                .question = question,
                .target = retained_target.retain(),
            } },
        };
    }

    fn beginLocalCall(
        self: *Connection,
        entry: *LocalEntry,
        interface_id: u64,
        method_id: u16,
    ) !Request {
        if (entry.connection != self) return error.WrongConnection;
        const question_id = self.allocQuestionId();
        const message = try self.allocator.create(capnp.MessageBuilder);
        errdefer self.allocator.destroy(message);
        message.* = .{ .allocator = self.allocator };
        try message.init();
        errdefer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var call = try root.setCall();
        call.setQuestionId(question_id);
        call.setInterfaceId(interface_id);
        call.setMethodId(method_id);

        const retained_target: Capability = .{ .local = entry };
        return .{
            .connection = self,
            .state = .{ .pending = .{
                .message = message,
                .call = call,
                .question_id = question_id,
                .local_target = entry,
                .target = retained_target.retain(),
            } },
        };
    }

    fn beginPromisedAnswerCall(
        self: *Connection,
        entry: *AnswerCapability,
        interface_id: u64,
        method_id: u16,
    ) !Request {
        if (entry.connection != self) return error.WrongConnection;
        std.debug.assert(entry.question == null);

        // This handle refers to an answer we owe the peer (created from a
        // `receiverAnswer` descriptor), not to an outstanding question of
        // ours. It must be resolved locally; sending `promisedAnswer` back
        // over the wire would address the wrong table.
        const answer = self.answers.getPtr(entry.question_id) orelse return error.UnknownAnswer;
        const bytes = answer.resolved_bytes orelse return error.AnswerNotReady;
        const capability = try self.resolveAnswerCapabilityField(bytes, entry.pointer_field);
        defer capability.release();
        return self.beginCall(capability, interface_id, method_id);
    }

    fn beginPipelinedCall(
        self: *Connection,
        entry: *AnswerCapability,
        interface_id: u64,
        method_id: u16,
    ) !Request {
        if (entry.connection != self) return error.WrongConnection;
        std.debug.assert(entry.question != null);

        const question = try self.newQuestion();
        errdefer self.destroyQuestion(question);

        const message = try self.allocator.create(capnp.MessageBuilder);
        errdefer self.allocator.destroy(message);
        message.* = .{ .allocator = self.allocator };
        try message.init();
        errdefer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var call = try root.setCall();
        call.setQuestionId(question.id);

        var message_target = try call.target();
        var promised_answer = try message_target.setPromisedAnswer();
        promised_answer.setQuestionId(entry.question_id);
        if (entry.pointer_field) |pointer_field| {
            var transform = try promised_answer.transform();
            try transform.init(1);
            transform.get(0).setGetPointerField(pointer_field);
        }

        call.setInterfaceId(interface_id);
        call.setMethodId(method_id);

        const retained_target: Capability = .{ .answer_pipeline = entry };
        return .{
            .connection = self,
            .state = .{ .pending = .{
                .message = message,
                .call = call,
                .question_id = question.id,
                .question = question,
                .target = retained_target.retain(),
            } },
        };
    }

    fn newQuestion(self: *Connection) !*QuestionRef {
        const id = self.allocQuestionId();
        const question = try self.allocator.create(QuestionRef);
        errdefer self.allocator.destroy(question);
        question.* = .{
            .connection = self,
            .id = id,
            .refs = 1,
        };
        try self.questions.put(id, question);
        return question;
    }

    fn newAnswerCapability(
        self: *Connection,
        question: *QuestionRef,
        pointer_field: ?u16,
    ) !Capability {
        const entry = try self.allocator.create(AnswerCapability);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .connection = self,
            .question_id = question.id,
            .pointer_field = pointer_field,
            .question = question.retain(),
            .refs = 1,
        };
        try self.answer_capabilities.append(self.allocator, entry);
        return .{ .answer_pipeline = entry };
    }

    fn newUnresolvedAnswerCapability(
        self: *Connection,
        question_id: u32,
        pointer_field: ?u16,
    ) !Capability {
        const entry = try self.allocator.create(AnswerCapability);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .connection = self,
            .question_id = question_id,
            .pointer_field = pointer_field,
            .question = null,
            .refs = 1,
        };
        try self.answer_capabilities.append(self.allocator, entry);
        return .{ .answer_promise = entry };
    }

    fn releaseAnswerCapability(self: *Connection, entry: *AnswerCapability) void {
        std.debug.assert(entry.refs > 0);
        entry.refs -= 1;
        if (entry.refs != 0) return;
        for (self.answer_capabilities.items, 0..) |item, i| {
            if (item == entry) {
                _ = self.answer_capabilities.swapRemove(i);
                break;
            }
        }
        if (entry.question) |question| question.release();
        self.allocator.destroy(entry);
    }

    fn sendRaw(self: *Connection, bytes: []const u8) anyerror!void {
        try self.transport.send(bytes);
        if (self.peer) |peer| try peer.step();
    }

    fn waitReturn(self: *Connection, question_id: u32) !Response {
        while (true) {
            if (try self.takeReturn(question_id)) |response| return response;

            if (self.lifecycle == .closed) return error.EndOfStream;

            if (self.transport.isClosed()) {
                // Drain anything that was already buffered before the close.
                try self.step();
                if (try self.takeReturn(question_id)) |response| return response;
                return error.EndOfStream;
            }

            try self.waitForProgress();
        }
    }

    fn takeReturn(self: *Connection, question_id: u32) !?Response {
        const entry = self.returns.fetchRemove(question_id) orelse return null;
        defer self.allocator.free(entry.value);
        return try Response.fromBytes(entry.value, self);
    }

    fn sendFinish(self: *Connection, question_id: u32, release_result_caps: bool) !void {
        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var finish = try root.setFinish();
        finish.setQuestionId(question_id);
        finish.setReleaseResultCaps(release_result_caps);

        const bytes = try message.toBytes(self.allocator);
        defer self.allocator.free(bytes);
        try self.sendRaw(bytes);
    }

    fn handle(self: *Connection, bytes: []const u8) anyerror!void {
        var message = try capnp.Message.fromBytes(bytes, self.allocator);
        defer message.deinit(self.allocator);

        const root = try message.getRootStruct(rpc.Message.Reader, rpc.Message.reader_trait);
        switch (root.which()) {
            .bootstrap => {
                const bootstrap_message = (try root.bootstrap()) orelse return error.InvalidMessage;
                try self.handleBootstrap(bootstrap_message);
            },
            .call => {
                const call = (try root.call()) orelse return error.InvalidMessage;
                if (self.dispatch_depth != 0) {
                    const copy = try self.allocator.dupe(u8, bytes);
                    errdefer self.allocator.free(copy);
                    try self.deferred_calls.append(self.allocator, .{
                        .question_id = call.questionId(),
                        .bytes = copy,
                    });
                    return;
                }
                try self.handleCall(call, bytes);
            },
            .@"return" => {
                const return_ = (try root.@"return"()) orelse return error.InvalidMessage;
                try self.handleReturn(return_, bytes);
            },
            .finish => {
                const finish = (try root.finish()) orelse return error.InvalidMessage;
                try self.handleFinish(finish);
            },
            .resolve => {
                const resolve = (try root.resolve()) orelse return error.InvalidMessage;
                try self.handleResolve(resolve);
            },
            .disembargo => {
                const disembargo = (try root.disembargo()) orelse return error.InvalidMessage;
                try self.handleDisembargo(disembargo);
            },
            .release => {
                const release = (try root.release()) orelse return error.InvalidMessage;
                try self.handleRelease(release);
            },
            .abort => {
                self.lifecycle = .closed;
                return error.ConnectionAborted;
            },
            else => return self.failConnection(error.UnsupportedMessage, .unimplemented),
        }
    }

    fn handleBootstrap(self: *Connection, bootstrap_message: rpc.Bootstrap.Reader) !void {
        const question_id = bootstrap_message.questionId();
        if (self.answers.contains(question_id) or self.queued_questions.contains(question_id)) {
            try self.sendException(question_id, error.DuplicateQuestion, true);
            return;
        }
        if (isNone(self.bootstrap_capability)) {
            try self.sendException(question_id, error.NoBootstrapInterface, true);
            return;
        }

        const export_id = switch (self.bootstrap_capability) {
            .local => |entry| try self.exportLocal(entry),
            else => {
                try self.sendException(question_id, error.UnsupportedBootstrapCapability, true);
                return;
            },
        };

        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var return_ = try root.setReturn();
        return_.setAnswerId(question_id);
        return_.setReleaseParamCaps(true);

        var results = try return_.setResults();
        results.content().setCapability(0);

        var cap_table = try results.capTable();
        try cap_table.init(1);
        cap_table.get(0).setSenderHosted(export_id);

        const answer = try self.ensureAnswer(question_id);
        answer.call_state = .received;
        try answer.export_ids.append(self.allocator, export_id);

        const bytes = try message.toBytes(self.allocator);
        defer self.allocator.free(bytes);
        try self.storeAnswer(question_id, bytes);
        try self.sendRaw(bytes);
        try self.processPendingAnswer(question_id);
    }

    fn handleCall(self: *Connection, call: rpc.Call.Reader, bytes: []const u8) !void {
        const question_id = call.questionId();
        if (self.queued_questions.contains(question_id)) {
            try self.sendException(question_id, error.DuplicateQuestion, true);
            return;
        }
        if (self.answers.getPtr(question_id)) |answer| {
            if (answer.call_state == .received) {
                try self.sendException(question_id, error.DuplicateQuestion, true);
                return;
            }
        }
        const target = try call.target();

        if (try target.promisedAnswer()) |promised| {
            try self.handlePromisedCall(call, promised, bytes);
            return;
        }

        const export_id = target.importedCap() orelse {
            try self.sendException(question_id, error.UnsupportedTarget, true);
            return;
        };

        const entry = self.exports.get(export_id) orelse {
            try self.sendException(question_id, error.UnknownCapability, true);
            return;
        };

        if (entry.kind == .promise) {
            try self.queuePromiseCall(entry, question_id, bytes);
            return;
        }

        try self.deliverCall(call, entry.capability, question_id, bytes);
    }

    fn handlePromisedCall(
        self: *Connection,
        call: rpc.Call.Reader,
        promised: rpc.PromisedAnswer.Reader,
        bytes: []const u8,
    ) !void {
        const answer_id = promised.questionId();
        const question_id = call.questionId();
        const transform = try promised.transform();

        const entry = self.answers.getPtr(answer_id) orelse {
            try self.sendException(question_id, error.UnknownAnswer, true);
            return;
        };

        if (entry.resolved_bytes == null) {
            try self.queueAnswerCall(entry, question_id, bytes);
            return;
        }

        const capability = self.resolveAnswerCapability(entry.resolved_bytes.?, transform) catch |err| {
            try self.sendException(question_id, err, true);
            return;
        };
        defer capability.release();

        try self.deliverCall(call, capability, question_id, bytes);
    }

    /// Queue a call behind an unresolved promise export. The answer entry is
    /// created eagerly so calls pipelined on this question can be queued in
    /// `AnswerState.pending` before the promise resolves.
    fn queuePromiseCall(
        self: *Connection,
        entry: *ExportEntry,
        question_id: u32,
        bytes: []const u8,
    ) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);

        try entry.pending_calls.append(self.allocator, .{
            .question_id = question_id,
            .bytes = copy,
        });
        errdefer _ = entry.pending_calls.pop();

        try self.queued_questions.put(question_id, {});
        errdefer _ = self.queued_questions.remove(question_id);

        const answer = try self.ensureAnswer(question_id);
        answer.call_state = .received;
    }

    /// Queue a pipelined call until the answer it depends on is resolved.
    fn queueAnswerCall(
        self: *Connection,
        answer: *AnswerState,
        question_id: u32,
        bytes: []const u8,
    ) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);

        try answer.pending.append(self.allocator, .{
            .question_id = question_id,
            .bytes = copy,
        });
        errdefer _ = answer.pending.pop();

        try self.queued_questions.put(question_id, {});
        errdefer _ = self.queued_questions.remove(question_id);
    }

    /// Deliver an incoming Call to a resolved target capability. Used both for
    /// direct `importedCap` targets and for targets resolved from pipelined
    /// answers. `.promised` handles are queued or unwrapped as needed.
    fn deliverCall(
        self: *Connection,
        call: rpc.Call.Reader,
        target: Capability,
        question_id: u32,
        bytes: []const u8,
    ) anyerror!void {
        switch (target) {
            .local => |local| try self.dispatchLocalCall(call, local.capability, question_id, null, null, null),
            .promised => |entry| {
                if (entry.connection != self) {
                    try self.sendException(question_id, error.ForeignCapability, true);
                    return;
                }
                if (entry.kind == .promise) {
                    try self.queuePromiseCall(entry, question_id, bytes);
                    return;
                }
                try self.deliverCall(call, entry.capability, question_id, bytes);
            },
            .imported => try self.sendException(question_id, error.ForwardingUnsupported, true),
            .answer_pipeline, .answer_promise => try self.sendException(question_id, error.UnsupportedPromisedTarget, true),
            .none => try self.sendException(question_id, error.UnknownCapability, true),
        }
    }

    fn dispatchLocalCall(
        self: *Connection,
        call: rpc.Call.Reader,
        local: LocalCapability,
        question_id: u32,
        local_sink: ?*?[]u8,
        local_caps_sink: ?*std.ArrayList(Capability),
        param_caps_override: ?[]const Capability,
    ) anyerror!void {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;

        if (call.interfaceId() != local.interface_id) {
            if (local_sink != null) return error.UnknownInterface;
            try self.sendException(question_id, error.UnknownInterface, true);
            return;
        }

        if (call.sendResultsTo().which() != .caller) {
            if (local_sink != null) return error.UnsupportedSendResultsTo;
            try self.sendException(question_id, error.UnsupportedSendResultsTo, true);
            return;
        }

        const params_payload = try call.params();
        const params = try params_payload.content();
        var decoded_caps: ?[]Capability = null;
        if (param_caps_override == null) {
            decoded_caps = try self.decodeCapTable(params_payload);
        }
        const params_caps = param_caps_override orelse decoded_caps.?;
        defer {
            if (decoded_caps) |caps| {
                for (caps) |capability| capability.release();
                self.allocator.free(caps);
            }
        }

        if (local_sink == null) {
            const answer = try self.ensureAnswer(question_id);
            answer.call_state = .received;
            for (params_caps) |capability| {
                try answer.held_caps.append(self.allocator, capability.retain());
            }
        }

        var result_caps = std.ArrayList(Capability).empty;
        defer {
            for (result_caps.items) |capability| capability.release();
            result_caps.deinit(self.allocator);
        }

        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var return_ = try root.setReturn();
        return_.setAnswerId(question_id);
        // The params capabilities are held until Finish and released with
        // explicit Release messages.
        return_.setReleaseParamCaps(local_sink != null);

        var results = try return_.setResults();
        const call_context = Call{
            .connection = self,
            .params = params,
            .results = results.content(),
            .capabilities = params_caps,
            .result_capabilities = &result_caps,
        };

        const bytes = dispatch: {
            local.dispatch(dispatchContext(local.context), call.methodId(), call_context) catch |err| {
                var exception = try return_.setException();
                return_.setReleaseParamCaps(local_sink != null);
                try exception.setReason(@errorName(err));
                exception.setType(.failed);
                break :dispatch try message.toBytes(self.allocator);
            };

            if (result_caps.items.len != 0) {
                var cap_table = try results.capTable();
                try cap_table.init(@intCast(result_caps.items.len));
                if (local_sink != null) {
                    const caps = local_caps_sink orelse return error.MissingLocalCapSink;
                    for (result_caps.items, 0..) |capability, i| {
                        cap_table.get(@intCast(i)).setNone();
                        try caps.append(self.allocator, capability.retain());
                    }
                } else {
                    const answer = try self.ensureAnswer(question_id);
                    for (result_caps.items, 0..) |capability, i| {
                        const export_id = try self.encodeCapability(capability, cap_table.get(@intCast(i)));
                        if (export_id) |id| try answer.export_ids.append(self.allocator, id);
                    }
                }
            }

            break :dispatch try message.toBytes(self.allocator);
        };

        if (local_sink) |sink| {
            sink.* = bytes;
            return;
        }

        defer self.allocator.free(bytes);
        try self.storeAnswer(question_id, bytes);
        try self.sendRaw(bytes);
        try self.processPendingAnswer(question_id);
    }

    fn drainDeferredCalls(self: *Connection) anyerror!void {
        if (self.drain_state == .draining or self.dispatch_depth != 0) return;
        self.drain_state = .draining;
        defer self.drain_state = .idle;

        while (self.deferred_calls.items.len != 0) {
            if (self.dispatch_depth != 0) return;
            const item = self.deferred_calls.orderedRemove(0);
            defer self.allocator.free(item.bytes);
            try self.handle(item.bytes);
        }
    }

    fn ensureAnswer(self: *Connection, question_id: u32) !*AnswerState {
        const entry = try self.answers.getOrPut(question_id);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        return entry.value_ptr;
    }

    fn storeAnswer(self: *Connection, question_id: u32, bytes: []const u8) !void {
        const entry = try self.ensureAnswer(question_id);
        const copy = try self.allocator.dupe(u8, bytes);
        if (entry.resolved_bytes) |old| self.allocator.free(old);
        entry.resolved_bytes = copy;
    }

    fn processPendingAnswer(self: *Connection, question_id: u32) anyerror!void {
        const entry = self.answers.getPtr(question_id) orelse return;
        if (entry.pending.items.len == 0) return;

        var pending = entry.pending;
        entry.pending = .empty;
        defer pending.deinit(self.allocator);

        // Free every entry that was not successfully replayed, including the
        // current one when `handle` fails partway through the drain.
        var handled: usize = 0;
        defer {
            for (pending.items[handled..]) |item| {
                _ = self.queued_questions.remove(item.question_id);
                self.allocator.free(item.bytes);
            }
        }

        while (handled < pending.items.len) {
            const item = pending.items[handled];
            _ = self.queued_questions.remove(item.question_id);
            try self.handle(item.bytes);
            self.allocator.free(item.bytes);
            handled += 1;
        }
    }

    fn resolveAnswerCapability(
        self: *Connection,
        answer_bytes: []const u8,
        transform: capnp.CompositeListReader(rpc.PromisedAnswer.Op.Reader, rpc.PromisedAnswer.Op.reader_trait),
    ) !Capability {
        var message = try capnp.Message.fromBytes(answer_bytes, self.allocator);
        defer message.deinit(self.allocator);

        const root = try message.getRootStruct(rpc.Message.Reader, rpc.Message.reader_trait);
        const return_ = (try root.@"return"()) orelse return error.InvalidAnswer;
        const payload = (try return_.results()) orelse return error.InvalidAnswer;

        var value = try payload.content();
        for (0..transform.length) |i| {
            const op = transform.get(@intCast(i));
            const pointer_field = op.getPointerField() orelse return error.UnsupportedTransform;
            switch (value.ptr) {
                .struct_ => |struct_| {
                    const reader = capnp.StructReader{
                        .context = value.context,
                        .data_words = struct_.data_words,
                        .ptr_words = struct_.ptr_words,
                    };
                    value = try reader.readPtrField(capnp.AnyPointerReader, pointer_field);
                },
                else => return error.InvalidPointer,
            }
        }

        const cap_index = try value.asCapability();
        const cap_table = try payload.capTable();
        if (cap_index >= cap_table.length) return error.InvalidCapability;
        return self.decodeAnswerCapability(cap_table.get(cap_index));
    }

    fn resolveAnswerCapabilityField(
        self: *Connection,
        answer_bytes: []const u8,
        pointer_field: ?u16,
    ) !Capability {
        var message = try capnp.Message.fromBytes(answer_bytes, self.allocator);
        defer message.deinit(self.allocator);

        const root = try message.getRootStruct(rpc.Message.Reader, rpc.Message.reader_trait);
        const return_ = (try root.@"return"()) orelse return error.InvalidAnswer;
        const payload = (try return_.results()) orelse return error.InvalidAnswer;

        var value = try payload.content();
        if (pointer_field) |field| {
            switch (value.ptr) {
                .struct_ => |struct_| {
                    const reader = capnp.StructReader{
                        .context = value.context,
                        .data_words = struct_.data_words,
                        .ptr_words = struct_.ptr_words,
                    };
                    value = try reader.readPtrField(capnp.AnyPointerReader, field);
                },
                else => return error.InvalidPointer,
            }
        }

        const cap_index = try value.asCapability();
        const cap_table = try payload.capTable();
        if (cap_index >= cap_table.length) return error.InvalidCapability;
        return self.decodeAnswerCapability(cap_table.get(cap_index));
    }

    fn decodeAnswerCapability(self: *Connection, descriptor: rpc.CapDescriptor.Reader) !Capability {
        if (descriptor.none() != null) return .none;

        if (descriptor.senderHosted()) |export_id| {
            const entry = self.exports.get(export_id) orelse return error.UnknownCapability;
            return entry.capability.retain();
        }

        if (descriptor.senderPromise()) |export_id| {
            // Preserve the promise identity. If it is still unresolved, calls
            // on this capability must queue on the export instead of being
            // decoded as `.none`.
            const entry = self.exports.get(export_id) orelse return error.UnknownCapability;
            entry.handle_refs += 1;
            return .{ .promised = entry };
        }

        if (descriptor.receiverHosted()) |export_id| {
            const entry = self.imports.get(export_id) orelse return error.UnknownCapability;
            entry.handle_refs += 1;
            return .{ .imported = entry };
        }

        return error.UnsupportedCapability;
    }

    fn releaseExportRef(self: *Connection, export_id: u32, count: u32) void {
        const entry = self.exports.get(export_id) orelse return;
        if (count >= entry.wire_refs) {
            entry.wire_refs = 0;
        } else {
            entry.wire_refs -= count;
        }
        self.maybeDestroyExport(entry);
    }

    fn cancelQueuedCalls(self: *Connection, question_id: u32) void {
        var deferred_index: usize = 0;
        while (deferred_index < self.deferred_calls.items.len) {
            if (self.deferred_calls.items[deferred_index].question_id == question_id) {
                const item = self.deferred_calls.orderedRemove(deferred_index);
                self.allocator.free(item.bytes);
            } else {
                deferred_index += 1;
            }
        }

        var export_it = self.exports.valueIterator();
        while (export_it.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            var index: usize = 0;
            while (index < entry.pending_calls.items.len) {
                if (entry.pending_calls.items[index].question_id == question_id) {
                    const item = entry.pending_calls.orderedRemove(index);
                    self.allocator.free(item.bytes);
                } else {
                    index += 1;
                }
            }
        }

        var answer_it = self.answers.valueIterator();
        while (answer_it.next()) |answer| {
            var index: usize = 0;
            while (index < answer.pending.items.len) {
                if (answer.pending.items[index].question_id == question_id) {
                    const item = answer.pending.orderedRemove(index);
                    self.allocator.free(item.bytes);
                } else {
                    index += 1;
                }
            }
        }
    }

    fn handleFinish(self: *Connection, finish: rpc.Finish.Reader) !void {
        const question_id = finish.questionId();
        if (self.answers.fetchRemove(question_id)) |removed| {
            var answer = removed.value;
            if (finish.releaseResultCaps()) {
                for (answer.export_ids.items) |export_id| {
                    self.releaseExportRef(export_id, 1);
                }
            }
            if (answer.resolved_bytes) |bytes| self.allocator.free(bytes);
            for (answer.pending.items) |item| {
                _ = self.queued_questions.remove(item.question_id);
                self.allocator.free(item.bytes);
            }
            answer.pending.deinit(self.allocator);
            answer.export_ids.deinit(self.allocator);
            for (answer.held_caps.items) |capability| capability.release();
            answer.held_caps.deinit(self.allocator);
        }
        _ = self.queued_questions.remove(question_id);
        self.cancelQueuedCalls(question_id);
    }

    fn handleRelease(self: *Connection, release: rpc.Release.Reader) !void {
        self.releaseExportRef(release.id(), release.referenceCount());
    }

    fn handleResolve(self: *Connection, resolve: rpc.Resolve.Reader) !void {
        const promise_id = resolve.promiseId();
        const descriptor = try resolve.cap();
        const entry = self.imports.get(promise_id) orelse {
            if (descriptor) |descriptor_value| {
                // We already released this promise. Release the resolution too.
                const capability = try self.decodeCapability(descriptor_value);
                capability.release();
            }
            return;
        };

        if (!isNone(entry.resolved)) {
            entry.resolved.release();
            entry.resolved = .none;
        }

        if (descriptor) |descriptor_value| {
            entry.resolved = try self.decodeCapability(descriptor_value);
        }
    }

    fn handleReturn(self: *Connection, return_: rpc.Return.Reader, bytes: []const u8) !void {
        const answer_id = return_.answerId();
        // A Return for a question we no longer track is a late reply to a
        // canceled/abandoned call. Ignore it instead of growing the table.
        const question = self.questions.get(answer_id) orelse return;
        if (return_.releaseParamCaps()) {
            for (question.param_export_ids.items) |export_id| {
                self.releaseExportRef(export_id, 1);
            }
            question.param_export_ids.clearRetainingCapacity();
        }

        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);

        if (try self.returns.fetchPut(answer_id, copy)) |old| {
            self.allocator.free(old.value);
        }
    }

    fn sendException(self: *Connection, answer_id: u32, err: anyerror, release_param_caps: bool) !void {
        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var return_ = try root.setReturn();
        return_.setAnswerId(answer_id);
        return_.setReleaseParamCaps(release_param_caps);

        var exception = try return_.setException();
        try exception.setReason(@errorName(err));
        exception.setType(.failed);

        const bytes = try message.toBytes(self.allocator);
        defer self.allocator.free(bytes);
        try self.sendRaw(bytes);
    }

    fn decodeCapTable(self: *Connection, payload: rpc.Payload.Reader) ![]Capability {
        const cap_table = try payload.capTable();
        var caps = std.ArrayList(Capability).empty;
        errdefer {
            for (caps.items) |capability| capability.release();
            caps.deinit(self.allocator);
        }

        for (0..cap_table.length) |i| {
            try caps.append(self.allocator, try self.decodeCapability(cap_table.get(@intCast(i))));
        }
        return caps.toOwnedSlice(self.allocator);
    }

    fn decodeCapability(self: *Connection, descriptor: rpc.CapDescriptor.Reader) !Capability {
        if (descriptor.none() != null) return .none;

        if (descriptor.senderHosted()) |export_id| {
            return self.importCapability(export_id);
        }

        if (descriptor.senderPromise()) |export_id| {
            return self.importCapability(export_id);
        }

        if (descriptor.receiverHosted()) |export_id| {
            const entry = self.exports.get(export_id) orelse return error.UnknownCapability;
            return entry.capability.retain();
        }

        if (try descriptor.receiverAnswer()) |answer| {
            const question_id = answer.questionId();
            const transform = try answer.transform();

            if (self.answers.getPtr(question_id)) |state| {
                if (state.resolved_bytes) |bytes| {
                    return try self.resolveAnswerCapability(bytes, transform);
                }
            }

            if (transform.length > 1) return error.UnsupportedCapability;
            var pointer_field: ?u16 = null;
            if (transform.length == 1) {
                const op = transform.get(0);
                pointer_field = op.getPointerField() orelse return error.UnsupportedCapability;
            }
            return self.newUnresolvedAnswerCapability(question_id, pointer_field);
        }

        return error.UnsupportedCapability;
    }

    fn importCapability(self: *Connection, export_id: u32) !Capability {
        if (self.imports.get(export_id)) |entry| {
            entry.wire_refs += 1;
            entry.handle_refs += 1;
            return .{ .imported = entry };
        }

        const entry = try self.allocator.create(ImportEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .connection = self,
            .export_id = export_id,
            .wire_refs = 1,
            .handle_refs = 1,
        };
        try self.imports.put(export_id, entry);
        return .{ .imported = entry };
    }

    fn releaseImport(self: *Connection, entry: *ImportEntry) void {
        std.debug.assert(entry.handle_refs > 0);
        entry.handle_refs -= 1;
        if (entry.handle_refs != 0) return;

        if (self.imports.get(entry.export_id) == entry) {
            _ = self.imports.remove(entry.export_id);
        }

        if (!isNone(entry.resolved)) {
            entry.resolved.release();
            entry.resolved = .none;
        }

        if (entry.wire_refs > 0 and self.lifecycle == .open) {
            self.sendRelease(entry.export_id, entry.wire_refs) catch |err| self.noteError(err);
        }
        self.allocator.destroy(entry);
    }

    /// Encode a capability into a `CapDescriptor`. Returns the export id used,
    /// when the descriptor created or reused an export.
    fn encodeCapability(
        self: *Connection,
        capability: Capability,
        descriptor: rpc.CapDescriptor.Builder,
    ) !?u32 {
        switch (capability) {
            .none => {
                descriptor.setNone();
                return null;
            },
            .local => |entry| {
                const export_id = try self.exportLocal(entry);
                descriptor.setSenderHosted(export_id);
                return export_id;
            },
            .promised => |entry| {
                if (entry.connection != self) return error.ForeignCapability;
                if (entry.kind != .promise) return self.encodeCapability(entry.capability, descriptor);
                const export_id = try self.exportShared(capability);
                descriptor.setSenderPromise(export_id);
                return export_id;
            },
            .answer_pipeline => |answer| {
                if (answer.connection != self) return error.ForeignCapability;
                var promised_answer = try descriptor.setReceiverAnswer();
                promised_answer.setQuestionId(answer.question_id);
                if (answer.pointer_field) |pointer_field| {
                    var transform = try promised_answer.transform();
                    try transform.init(1);
                    transform.get(0).setGetPointerField(pointer_field);
                }
                return null;
            },
            // An answer we owe the peer cannot be encoded as a capability: the
            // peer has no address for it in its own tables.
            .answer_promise => return error.UnsupportedCapability,
            .imported => |imported| {
                if (imported.connection != self) return error.ForeignCapability;
                if (self.imports.get(imported.export_id) != imported) return error.UnknownCapability;
                descriptor.setReceiverHosted(imported.export_id);
                return null;
            },
        }
    }

    fn exportShared(self: *Connection, capability: Capability) !u32 {
        return switch (capability) {
            .local => |entry| self.exportLocal(entry),
            .promised => |entry| blk: {
                if (entry.connection != self) return error.ForeignCapability;
                entry.wire_refs += 1;
                break :blk entry.export_id;
            },
            else => error.UnsupportedCapability,
        };
    }

    fn exportLocal(self: *Connection, entry: *LocalEntry) !u32 {
        if (entry.connection != self) return error.ForeignCapability;

        if (entry.export_id) |export_id| {
            if (self.exports.get(export_id)) |export_entry| {
                export_entry.wire_refs += 1;
                return export_id;
            }
            entry.export_id = null;
        }

        const export_entry = try self.allocExport(.{ .local = entry });
        export_entry.wire_refs = 1;
        entry.export_id = export_entry.export_id;
        return export_entry.export_id;
    }

    fn allocExport(self: *Connection, capability: Capability) !*ExportEntry {
        const export_id = self.allocExportId();
        const entry = try self.allocator.create(ExportEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .connection = self,
            .export_id = export_id,
            .capability = capability.retain(),
            .wire_refs = 0,
        };
        try self.exports.put(export_id, entry);
        return entry;
    }

    fn maybeDestroyExport(self: *Connection, entry: *ExportEntry) void {
        if (entry.wire_refs != 0 or entry.handle_refs != 0) return;

        if (self.exports.get(entry.export_id) == entry) {
            _ = self.exports.remove(entry.export_id);
        }
        switch (entry.capability) {
            .local => |local| {
                if (local.export_id == entry.export_id) local.export_id = null;
            },
            else => {},
        }
        self.destroyExport(entry);
    }

    fn releasePromiseHandle(self: *Connection, entry: *ExportEntry) void {
        std.debug.assert(entry.handle_refs > 0);
        entry.handle_refs -= 1;
        self.maybeDestroyExport(entry);
    }

    pub fn sendDisembargoLoopback(self: *Connection, target: Capability, embargo_id: u32) !void {
        const imported = switch (target) {
            .imported => |capability| capability,
            else => return error.NotImportedCapability,
        };
        if (imported.connection != self) return error.WrongConnection;

        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var disembargo = try root.setDisembargo();
        var target_builder = try disembargo.target();
        target_builder.setImportedCap(imported.export_id);
        var context = disembargo.context();
        context.setSenderLoopback(embargo_id);

        const bytes = try message.toBytes(self.allocator);
        defer self.allocator.free(bytes);
        try self.sendRaw(bytes);
    }

    fn handleDisembargo(self: *Connection, disembargo: rpc.Disembargo.Reader) !void {
        const context = disembargo.context();
        switch (context.which()) {
            .senderLoopback => {
                const embargo_id = context.senderLoopback() orelse return;

                var message = capnp.MessageBuilder{ .allocator = self.allocator };
                try message.init();
                defer message.deinit();

                var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
                var echo = try root.setDisembargo();
                var echo_target = try echo.target();
                const incoming_target = try disembargo.target();
                if (incoming_target.importedCap()) |target_id| {
                    echo_target.setImportedCap(target_id);
                } else if (try incoming_target.promisedAnswer()) |incoming_answer| {
                    var echo_answer = try echo_target.setPromisedAnswer();
                    echo_answer.setQuestionId(incoming_answer.questionId());
                    const transform = try incoming_answer.transform();
                    if (transform.length != 0) {
                        var echo_transform = try echo_answer.transform();
                        try echo_transform.init(transform.length);
                        for (0..transform.length) |i| {
                            const op = transform.get(@intCast(i));
                            const pointer_field = op.getPointerField() orelse
                                return error.UnsupportedTransform;
                            echo_transform.get(@intCast(i)).setGetPointerField(pointer_field);
                        }
                    }
                } else {
                    return error.UnsupportedTarget;
                }
                var echo_context = echo.context();
                echo_context.setReceiverLoopback(embargo_id);

                const bytes = try message.toBytes(self.allocator);
                defer self.allocator.free(bytes);
                try self.sendRaw(bytes);
            },
            .receiverLoopback => {
                const embargo_id = context.receiverLoopback() orelse return;
                if (self.disembargo_callback) |callback| {
                    callback.function(callback.context, embargo_id);
                }
            },
            else => {},
        }
    }

    fn sendResolve(self: *Connection, promise_id: u32, target: Capability) !void {
        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var resolve = try root.setResolve();
        resolve.setPromiseId(promise_id);
        const cap = try resolve.setCap();
        _ = try self.encodeCapability(target, cap);

        const bytes = try message.toBytes(self.allocator);
        defer self.allocator.free(bytes);
        try self.sendRaw(bytes);
    }

    fn sendRelease(self: *Connection, export_id: u32, reference_count: u32) !void {
        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var release = try root.setRelease();
        release.setId(export_id);
        release.setReferenceCount(reference_count);

        const bytes = try message.toBytes(self.allocator);
        defer self.allocator.free(bytes);
        try self.sendRaw(bytes);
    }

    fn allocQuestionId(self: *Connection) u32 {
        while (true) {
            const id = self.next_question_id;
            self.next_question_id +%= 1;
            if (self.next_question_id == 0) self.next_question_id = 1;
            if (!self.questions.contains(id) and !self.returns.contains(id)) return id;
        }
    }

    fn allocExportId(self: *Connection) u32 {
        while (true) {
            const id = self.next_export_id;
            self.next_export_id +%= 1;
            if (self.next_export_id == 0) self.next_export_id = 1;
            if (!self.exports.contains(id)) return id;
        }
    }
};
