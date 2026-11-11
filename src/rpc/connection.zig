//! Minimal two-party Cap'n Proto RPC runtime.
//!
//! This module implements the transport-independent message pump, the
//! Bootstrap/Call/Return/Finish subset, level-1 capability passing with
//! import/export reference tracking and Release messages, promise exports and
//! resolution, promise pipelining, and loopback Disembargo handling.
//! Third-party introductions remain out of scope.

const std = @import("std");
const capnp = @import("capnp");
const rpc = @import("rpc.zig");

pub const transports = @import("transports/mod.zig");

pub const Side = enum(u8) { client = 0, server = 1 };

pub const Transport = struct {
    context: *anyopaque,
    side: Side = .client,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (context: *anyopaque, side: Side, bytes: []const u8) anyerror!void,
        receive: *const fn (context: *anyopaque, side: Side, allocator: std.mem.Allocator) anyerror!?[]u8,
    };

    pub fn send(self: Transport, bytes: []const u8) anyerror!void {
        // std.debug.print("send {} {}\n", .{ self.side, bytes.len });
        return self.vtable.send(self.context, self.side, bytes);
    }

    pub fn receive(self: Transport, allocator: std.mem.Allocator) anyerror!?[]u8 {
        // std.debug.print("recieve {} \n", .{self.side});
        return self.vtable.receive(self.context, self.side, allocator);
    }
};

pub const Call = struct {
    connection: *Connection,
    params: capnp.AnyPointerReader,
    results: capnp.AnyPointerBuilder,
    capabilities: []const Capability,
    result_capabilities: *std.ArrayList(Capability),

    /// Add a capability to the return payload and return its capability-table
    /// index. Set that index on a capability pointer in `results.content()`.
    pub fn addResultCapability(self: Call, capability: Capability) !u32 {
        const index: u32 = @intCast(self.result_capabilities.items.len);
        try self.result_capabilities.append(self.connection.allocator, capability);
        return index;
    }
};

pub const DispatchFn = *const fn (
    context: *anyopaque,
    method_id: u16,
    call: Call,
) anyerror!void;

pub const LocalCapability = struct {
    context: *anyopaque,
    interface_id: u64,
    dispatch: DispatchFn,
};

pub const ImportedCapability = struct {
    connection: *Connection,
    export_id: u32,
};

pub const DisembargoCallback = struct {
    context: *anyopaque,
    function: *const fn (context: *anyopaque, embargo_id: u32) void,
};

pub const PromisedCapability = struct {
    connection: *Connection,
    export_id: u32,
};

/// A capability expected to appear in the result of an outstanding question.
pub const PromisedAnswerCapability = struct {
    connection: *Connection,
    question_id: u32,
    pointer_field: ?u16,
};

pub const Capability = union(enum) {
    local: LocalCapability,
    imported: ImportedCapability,
    promised: PromisedCapability,
    promised_answer: PromisedAnswerCapability,
    none: void,

    pub fn beginCall(self: Capability, interface_id: u64, method_id: u16) !Request {
        return switch (self) {
            .imported => |capability| capability.connection.beginCall(self, interface_id, method_id),
            .promised_answer => |capability| capability.connection.beginPipelinedCall(self, interface_id, method_id),
            .local, .promised => error.LocalTargetUnsupported,
            .none => error.NoCapability,
        };
    }
};

pub const Response = struct {
    message: capnp.Message,
    connection: *Connection,

    pub fn fromBytes(bytes: []const u8, allocator: std.mem.Allocator, connection: *Connection) !Response {
        const message = try capnp.Message.fromBytes(bytes, allocator);
        return .{ .message = message, .connection = connection };
    }

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        self.message.deinit(allocator);
    }

    pub fn returnReader(self: *Response) !rpc.Return.Reader {
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

    pub fn capability(self: *Response, index: u32) !Capability {
        const result_payload = try self.payload();
        const cap_table = try result_payload.capTable();
        if (index >= cap_table.length) return error.InvalidCapability;
        return self.connection.decodeCapability(cap_table.get(index));
    }

    pub fn exception(self: *Response) !?rpc.Exception.Reader {
        const return_ = try self.returnReader();
        return try return_.exception();
    }
};

pub const Request = struct {
    connection: *Connection,
    message: *capnp.MessageBuilder,
    call: rpc.Call.Builder,
    question_id: u32,
    caps: std.ArrayList(Capability) = .empty,
    caps_deinitialized: bool = false,
    sent: bool = false,

    pub fn params(self: *Request) !rpc.Payload.Builder {
        return try self.call.params();
    }

    pub fn initParams(self: *Request, comptime T: type, comptime trait: capnp.BuilderTrait(T)) !T {
        const payload = try self.params();
        return payload.content().initStruct(T, trait);
    }

    /// Add a capability to the params cap table and return its index.
    pub fn addCapability(self: *Request, capability: Capability) !u32 {
        if (self.sent) return error.AlreadySent;
        const index: u32 = @intCast(self.caps.items.len);
        try self.caps.append(self.connection.allocator, capability);
        return index;
    }

    fn deinitCaps(self: *Request) void {
        if (self.caps_deinitialized) return;
        self.caps.deinit(self.connection.allocator);
        self.caps_deinitialized = true;
    }

    /// Send the call without waiting for its Return. The returned Promise can
    /// be used to pipeline calls on the eventual result.
    pub fn start(self: *Request) !Promise {
        if (self.sent) return error.AlreadySent;

        const allocator = self.connection.allocator;

        if (self.caps.items.len != 0) {
            const payload = try self.params();
            var cap_table = try payload.capTable();
            try cap_table.init(@intCast(self.caps.items.len));
            for (self.caps.items, 0..) |capability, i| {
                try self.connection.encodeCapability(capability, cap_table.get(@intCast(i)));
            }
        }

        const bytes = try self.message.toBytes(allocator);
        defer allocator.free(bytes);

        try self.connection.sendRaw(bytes);

        self.message.deinit();
        allocator.destroy(self.message);
        self.deinitCaps();
        self.sent = true;

        return .{ .connection = self.connection, .question_id = self.question_id };
    }

    pub fn send(self: *Request) !Response {
        var promise = try self.start();
        return promise.wait();
    }

    pub fn deinit(self: *Request) void {
        self.deinitCaps();
        if (self.sent) return;
        self.message.deinit();
        self.connection.allocator.destroy(self.message);
        self.sent = true;
    }
};

pub const Promise = struct {
    connection: *Connection,
    question_id: u32,
    finished: bool = false,

    pub fn wait(self: *Promise) !Response {
        if (self.finished) return error.AlreadyFinished;
        var response = try self.connection.waitReturn(self.question_id);
        errdefer response.deinit(self.connection.allocator);
        try self.connection.sendFinish(self.question_id, true);
        self.finished = true;
        return response;
    }

    /// Return a capability handle addressing the root result, or a pointer
    /// field within the result struct.
    pub fn capability(self: Promise, pointer_field: ?u16) !Capability {
        if (self.finished) return error.AlreadyFinished;
        return .{ .promised_answer = .{
            .connection = self.connection,
            .question_id = self.question_id,
            .pointer_field = pointer_field,
        } };
    }
};

const ExportEntry = struct {
    capability: Capability,
    ref_count: u32,
    is_promise: bool = false,
    pending_calls: std.ArrayList([]u8) = .empty,
};

const AnswerState = struct {
    resolved_bytes: ?[]u8 = null,
    pending: std.ArrayList([]u8) = .empty,
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    /// Optional in-process peer. When set, sending a message immediately pumps
    /// the peer so that the blocking `Request.send` path can complete without
    /// an external event loop.
    peer: ?*Connection = null,
    bootstrap_capability: ?Capability = null,
    disembargo_callback: ?DisembargoCallback = null,
    next_question_id: u32 = 1,
    next_export_id: u32 = 0,
    returns: std.AutoHashMap(u32, []u8),
    exports: std.AutoHashMap(u32, ExportEntry),
    imports: std.AutoHashMap(u32, u32),
    answers: std.AutoHashMap(u32, AnswerState),

    pub fn init(allocator: std.mem.Allocator, transport: Transport) !Connection {
        return .{
            .allocator = allocator,
            .transport = transport,
            .returns = std.AutoHashMap(u32, []u8).init(allocator),
            .exports = std.AutoHashMap(u32, ExportEntry).init(allocator),
            .imports = std.AutoHashMap(u32, u32).init(allocator),
            .answers = std.AutoHashMap(u32, AnswerState).init(allocator),
        };
    }

    pub fn deinit(self: *Connection) void {
        var return_it = self.returns.valueIterator();
        while (return_it.next()) |bytes| self.allocator.free(bytes.*);
        self.returns.deinit();

        var export_it = self.exports.valueIterator();
        while (export_it.next()) |entry| {
            for (entry.pending_calls.items) |bytes| self.allocator.free(bytes);
            entry.pending_calls.deinit(self.allocator);
        }
        self.exports.deinit();

        var answer_it = self.answers.valueIterator();
        while (answer_it.next()) |answer| {
            if (answer.resolved_bytes) |bytes| self.allocator.free(bytes);
            for (answer.pending.items) |bytes| self.allocator.free(bytes);
            answer.pending.deinit(self.allocator);
        }
        self.answers.deinit();
        self.imports.deinit();
    }

    pub fn setBootstrap(self: *Connection, capability: Capability) void {
        self.bootstrap_capability = capability;
    }

    pub fn setDisembargoCallback(self: *Connection, callback: ?DisembargoCallback) void {
        self.disembargo_callback = callback;
    }

    pub fn pump(self: *Connection) !void {
        while (try self.transport.receive(self.allocator)) |bytes| {
            defer self.allocator.free(bytes);
            try self.handle(bytes);
        }
    }

    pub fn bootstrap(self: *Connection) !Capability {
        const question_id = self.allocQuestionId();

        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var bootstrap_message = try root.setBootstrap();
        bootstrap_message.setQuestionId(question_id);

        const bytes = try message.toBytes(self.allocator);
        defer self.allocator.free(bytes);

        try self.sendRaw(bytes);
        var response = try self.waitReturn(question_id);
        defer response.deinit(self.allocator);

        switch (try response.which()) {
            .results => {
                const payload = try response.payload();
                const content = try payload.content();
                const cap_index = try content.asCapability();
                const cap_table = try payload.capTable();
                if (cap_index >= cap_table.length) return error.InvalidCapability;

                const descriptor = cap_table.get(cap_index);
                const export_id = descriptor.senderHosted() orelse return error.InvalidCapability;
                try self.registerImport(export_id);

                try self.sendFinish(question_id, false);
                return .{ .imported = .{ .connection = self, .export_id = export_id } };
            },
            .exception => {
                try self.sendFinish(question_id, true);
                return error.RemoteException;
            },
            else => {
                try self.sendFinish(question_id, true);
                return error.InvalidReturn;
            },
        }
    }

    pub fn newPromise(self: *Connection) !Capability {
        const export_id = self.allocExportId();
        const capability: Capability = .{ .promised = .{
            .connection = self,
            .export_id = export_id,
        } };
        try self.exports.put(export_id, .{
            .capability = capability,
            .ref_count = 1,
            .is_promise = true,
        });
        return capability;
    }

    pub fn resolvePromise(self: *Connection, promise: Capability, target: Capability) !void {
        const promised = switch (promise) {
            .promised => |value| value,
            else => return error.NotPromise,
        };
        if (promised.connection != self) return error.WrongConnection;

        const entry = self.exports.getPtr(promised.export_id) orelse return error.UnknownCapability;
        if (!entry.is_promise) return error.NotPromise;
        entry.is_promise = false;
        entry.capability = target;

        var pending = entry.pending_calls;
        entry.pending_calls = .empty;
        defer {
            for (pending.items) |bytes| self.allocator.free(bytes);
            pending.deinit(self.allocator);
        }
        try self.sendResolve(promised.export_id, target);

        for (pending.items) |bytes| {
            try self.handle(bytes);
        }
    }

    pub fn beginCall(
        self: *Connection,
        target: Capability,
        interface_id: u64,
        method_id: u16,
    ) !Request {
        const imported = switch (target) {
            .imported => |capability| capability,
            .promised_answer => return self.beginPipelinedCall(target, interface_id, method_id),
            .local, .promised => return error.LocalTargetUnsupported,
            .none => return error.NoCapability,
        };
        if (imported.connection != self) return error.WrongConnection;

        const question_id = self.allocQuestionId();
        const message = try self.allocator.create(capnp.MessageBuilder);
        errdefer self.allocator.destroy(message);
        message.* = .{ .allocator = self.allocator };
        try message.init();
        errdefer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var call = try root.setCall();
        call.setQuestionId(question_id);

        var message_target = try call.target();
        message_target.setImportedCap(imported.export_id);
        call.setInterfaceId(interface_id);
        call.setMethodId(method_id);

        return .{
            .connection = self,
            .message = message,
            .call = call,
            .question_id = question_id,
        };
    }

    pub fn beginPipelinedCall(
        self: *Connection,
        target: Capability,
        interface_id: u64,
        method_id: u16,
    ) !Request {
        const promised = switch (target) {
            .promised_answer => |capability| capability,
            else => return error.NotPromisedAnswer,
        };
        if (promised.connection != self) return error.WrongConnection;

        const question_id = self.allocQuestionId();
        const message = try self.allocator.create(capnp.MessageBuilder);
        errdefer self.allocator.destroy(message);
        message.* = .{ .allocator = self.allocator };
        try message.init();
        errdefer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var call = try root.setCall();
        call.setQuestionId(question_id);

        var message_target = try call.target();
        var promised_answer = try message_target.setPromisedAnswer();
        promised_answer.setQuestionId(promised.question_id);
        if (promised.pointer_field) |pointer_field| {
            var transform = try promised_answer.transform();
            try transform.init(1);
            transform.get(0).setGetPointerField(pointer_field);
        }

        call.setInterfaceId(interface_id);
        call.setMethodId(method_id);

        return .{
            .connection = self,
            .message = message,
            .call = call,
            .question_id = question_id,
        };
    }

    fn sendRaw(self: *Connection, bytes: []const u8) anyerror!void {
        try self.transport.send(bytes);
        if (self.peer) |peer| try peer.pump();
    }

    fn waitReturn(self: *Connection, question_id: u32) !Response {
        if (try self.takeReturn(question_id)) |response| return response;
        try self.pump();
        return (try self.takeReturn(question_id)) orelse error.NoResponse;
    }

    fn takeReturn(self: *Connection, question_id: u32) !?Response {
        const entry = self.returns.fetchRemove(question_id) orelse return null;
        defer self.allocator.free(entry.value);
        return try Response.fromBytes(entry.value, self.allocator, self);
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

    fn handle(self: *Connection, bytes: []const u8) !void {
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
            .resolve => {},
            .disembargo => {
                const disembargo = (try root.disembargo()) orelse return error.InvalidMessage;
                try self.handleDisembargo(disembargo);
            },
            .release => {
                const release = (try root.release()) orelse return error.InvalidMessage;
                try self.handleRelease(release);
            },
            .abort => return error.ConnectionAborted,
            else => return error.UnsupportedMessage,
        }
    }

    fn handleBootstrap(self: *Connection, bootstrap_message: rpc.Bootstrap.Reader) !void {
        const question_id = bootstrap_message.questionId();
        const capability = self.bootstrap_capability orelse {
            try self.sendException(question_id, error.NoBootstrapInterface);
            return;
        };

        const export_id = try self.allocExport(capability);

        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var return_ = try root.setReturn();
        return_.setAnswerId(question_id);

        var results = try return_.setResults();
        results.content().setCapability(0);

        var cap_table = try results.capTable();
        try cap_table.init(1);
        cap_table.get(0).setSenderHosted(export_id);

        const bytes = try message.toBytes(self.allocator);
        defer self.allocator.free(bytes);
        try self.storeAnswer(question_id, bytes);
        try self.sendRaw(bytes);
        try self.processPendingAnswer(question_id);
    }

    fn handleCall(self: *Connection, call: rpc.Call.Reader, bytes: []const u8) !void {
        const question_id = call.questionId();
        const target = try call.target();

        if (try target.promisedAnswer()) |promised| {
            try self.handlePromisedCall(call, promised, bytes);
            return;
        }

        const export_id = target.importedCap() orelse {
            try self.sendException(question_id, error.UnsupportedTarget);
            return;
        };

        const entry = self.exports.getPtr(export_id) orelse {
            try self.sendException(question_id, error.UnknownCapability);
            return;
        };

        if (entry.is_promise) {
            const copy = try self.allocator.dupe(u8, bytes);
            errdefer self.allocator.free(copy);
            try entry.pending_calls.append(self.allocator, copy);
            return;
        }

        const local = switch (entry.capability) {
            .local => |cap| cap,
            .imported => {
                try self.sendException(question_id, error.ForwardingUnsupported);
                return;
            },
            .promised, .promised_answer => {
                try self.sendException(question_id, error.UnsupportedTarget);
                return;
            },
            .none => {
                try self.sendException(question_id, error.UnknownCapability);
                return;
            },
        };

        try self.dispatchLocalCall(call, local, question_id);
    }

    fn handlePromisedCall(
        self: *Connection,
        call: rpc.Call.Reader,
        promised: rpc.PromisedAnswer.Reader,
        bytes: []const u8,
    ) !void {
        const answer_id = promised.questionId();
        const transform = try promised.transform();

        const entry = try self.answers.getOrPut(answer_id);
        if (!entry.found_existing) entry.value_ptr.* = .{};

        if (entry.value_ptr.resolved_bytes == null) {
            const copy = try self.allocator.dupe(u8, bytes);
            errdefer self.allocator.free(copy);
            try entry.value_ptr.pending.append(self.allocator, copy);
            return;
        }

        const capability = self.resolveAnswerCapability(entry.value_ptr.resolved_bytes.?, transform) catch |err| {
            try self.sendException(call.questionId(), err);
            return;
        };

        switch (capability) {
            .local => |local| try self.dispatchLocalCall(call, local, call.questionId()),
            else => try self.sendException(call.questionId(), error.UnsupportedPromisedTarget),
        }
    }

    fn dispatchLocalCall(self: *Connection, call: rpc.Call.Reader, local: LocalCapability, question_id: u32) !void {
        if (call.interfaceId() != local.interface_id) {
            try self.sendException(question_id, error.UnknownInterface);
            return;
        }

        if (call.sendResultsTo().which() != .caller) {
            try self.sendException(question_id, error.UnsupportedSendResultsTo);
            return;
        }

        const params_payload = try call.params();
        const params = try params_payload.content();
        const params_caps = try self.decodeCapTable(params_payload);
        defer self.allocator.free(params_caps);

        var result_caps = std.ArrayList(Capability).empty;
        defer result_caps.deinit(self.allocator);

        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var return_ = try root.setReturn();
        return_.setAnswerId(question_id);

        var results = try return_.setResults();
        const call_context = Call{
            .connection = self,
            .params = params,
            .results = results.content(),
            .capabilities = params_caps,
            .result_capabilities = &result_caps,
        };

        local.dispatch(local.context, call.methodId(), call_context) catch |err| {
            var exception = try return_.setException();
            try exception.setReason(@errorName(err));
            exception.setType(.failed);

            const bytes = try message.toBytes(self.allocator);
            defer self.allocator.free(bytes);
            try self.storeAnswer(question_id, bytes);
            try self.sendRaw(bytes);
            try self.processPendingAnswer(question_id);
            return;
        };

        if (result_caps.items.len != 0) {
            var cap_table = try results.capTable();
            try cap_table.init(@intCast(result_caps.items.len));
            for (result_caps.items, 0..) |capability, i| {
                try self.encodeCapability(capability, cap_table.get(@intCast(i)));
            }
        }

        const bytes = try message.toBytes(self.allocator);
        defer self.allocator.free(bytes);
        try self.storeAnswer(question_id, bytes);
        try self.sendRaw(bytes);
        try self.processPendingAnswer(question_id);
    }

    fn storeAnswer(self: *Connection, question_id: u32, bytes: []const u8) !void {
        const entry = try self.answers.getOrPut(question_id);
        if (!entry.found_existing) entry.value_ptr.* = .{};

        const copy = try self.allocator.dupe(u8, bytes);
        if (entry.value_ptr.resolved_bytes) |old| self.allocator.free(old);
        entry.value_ptr.resolved_bytes = copy;
    }

    fn processPendingAnswer(self: *Connection, question_id: u32) anyerror!void {
        const entry = self.answers.getPtr(question_id) orelse return;
        if (entry.pending.items.len == 0) return;

        var pending = entry.pending;
        entry.pending = .empty;
        defer pending.deinit(self.allocator);

        for (pending.items) |bytes| {
            defer self.allocator.free(bytes);
            try self.handle(bytes);
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

    fn decodeAnswerCapability(self: *Connection, descriptor: rpc.CapDescriptor.Reader) !Capability {
        if (descriptor.none() != null) return .none;

        if (descriptor.senderHosted()) |export_id| {
            const entry = self.exports.get(export_id) orelse return error.UnknownCapability;
            return entry.capability;
        }

        if (descriptor.senderPromise()) |export_id| {
            const entry = self.exports.get(export_id) orelse return error.UnknownCapability;
            return entry.capability;
        }

        if (descriptor.receiverHosted()) |export_id| {
            try self.registerImport(export_id);
            return .{ .imported = .{ .connection = self, .export_id = export_id } };
        }

        return error.UnsupportedCapability;
    }

    fn handleFinish(self: *Connection, finish: rpc.Finish.Reader) !void {
        const question_id = finish.questionId();
        if (self.answers.fetchRemove(question_id)) |removed| {
            var answer = removed.value;
            if (answer.resolved_bytes) |bytes| self.allocator.free(bytes);
            for (answer.pending.items) |bytes| self.allocator.free(bytes);
            answer.pending.deinit(self.allocator);
        }
    }
    fn handleRelease(self: *Connection, release: rpc.Release.Reader) !void {
        const export_id = release.id();
        const count = release.referenceCount();
        if (self.exports.getPtr(export_id)) |entry| {
            if (count >= entry.ref_count) {
                if (self.exports.fetchRemove(export_id)) |removed| {
                    var removed_entry = removed.value;
                    for (removed_entry.pending_calls.items) |bytes| self.allocator.free(bytes);
                    removed_entry.pending_calls.deinit(self.allocator);
                }
            } else {
                entry.ref_count -= count;
            }
        }
    }

    fn handleReturn(self: *Connection, return_: rpc.Return.Reader, bytes: []const u8) !void {
        const answer_id = return_.answerId();
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);

        if (try self.returns.fetchPut(answer_id, copy)) |old| {
            self.allocator.free(old.value);
        }
    }

    fn sendException(self: *Connection, answer_id: u32, err: anyerror) !void {
        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var return_ = try root.setReturn();
        return_.setAnswerId(answer_id);

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
        errdefer caps.deinit(self.allocator);

        for (0..cap_table.length) |i| {
            try caps.append(self.allocator, try self.decodeCapability(cap_table.get(@intCast(i))));
        }
        return caps.toOwnedSlice(self.allocator);
    }

    fn decodeCapability(self: *Connection, descriptor: rpc.CapDescriptor.Reader) !Capability {
        if (descriptor.none() != null) return .none;

        if (descriptor.senderHosted()) |export_id| {
            try self.registerImport(export_id);
            return .{ .imported = .{ .connection = self, .export_id = export_id } };
        }

        if (descriptor.senderPromise()) |export_id| {
            try self.registerImport(export_id);
            return .{ .imported = .{ .connection = self, .export_id = export_id } };
        }

        if (descriptor.receiverHosted()) |export_id| {
            const entry = self.exports.get(export_id) orelse return error.UnknownCapability;
            return entry.capability;
        }

        if (try descriptor.receiverAnswer()) |answer| {
            const question_id = answer.questionId();
            const transform = try answer.transform();

            if (self.answers.getPtr(question_id)) |state| {
                if (state.resolved_bytes) |bytes| {
                    if (self.resolveAnswerCapability(bytes, transform)) |resolved| {
                        return resolved;
                    } else |_| {}
                }
            }

            if (transform.length > 1) return error.UnsupportedCapability;
            var pointer_field: ?u16 = null;
            if (transform.length == 1) {
                const op = transform.get(0);
                pointer_field = op.getPointerField() orelse return error.UnsupportedCapability;
            }
            return .{ .promised_answer = .{
                .connection = self,
                .question_id = question_id,
                .pointer_field = pointer_field,
            } };
        }

        return error.UnsupportedCapability;
    }

    fn encodeCapability(self: *Connection, capability: Capability, descriptor: rpc.CapDescriptor.Builder) !void {
        switch (capability) {
            .none => descriptor.setNone(),
            .local => descriptor.setSenderHosted(try self.allocExport(capability)),
            .promised => |promised| {
                if (promised.connection != self) return error.ForeignCapability;
                descriptor.setSenderPromise(promised.export_id);
            },
            .promised_answer => |answer| {
                if (answer.connection != self) return error.ForeignCapability;
                var promised_answer = try descriptor.setReceiverAnswer();
                promised_answer.setQuestionId(answer.question_id);
                if (answer.pointer_field) |pointer_field| {
                    var transform = try promised_answer.transform();
                    try transform.init(1);
                    transform.get(0).setGetPointerField(pointer_field);
                }
            },
            .imported => |imported| {
                if (imported.connection != self) return error.ForeignCapability;
                descriptor.setReceiverHosted(imported.export_id);
            },
        }
    }

    fn registerImport(self: *Connection, export_id: u32) !void {
        const entry = try self.imports.getOrPut(export_id);
        if (entry.found_existing) {
            entry.value_ptr.* += 1;
        } else {
            entry.value_ptr.* = 1;
        }
    }

    pub fn releaseCapability(self: *Connection, capability: Capability) !void {
        switch (capability) {
            .imported => |imported| {
                if (imported.connection != self) return error.WrongConnection;
                const count = self.imports.getPtr(imported.export_id) orelse return error.UnknownCapability;
                if (count.* > 1) {
                    count.* -= 1;
                    return;
                }
                _ = self.imports.remove(imported.export_id);
                try self.sendRelease(imported.export_id);
            },
            .local, .promised, .promised_answer, .none => {},
        }
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
        try self.encodeCapability(target, cap);

        const bytes = try message.toBytes(self.allocator);
        defer self.allocator.free(bytes);
        try self.sendRaw(bytes);
    }

    fn sendRelease(self: *Connection, export_id: u32) !void {
        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var release = try root.setRelease();
        release.setId(export_id);
        release.setReferenceCount(1);

        const bytes = try message.toBytes(self.allocator);
        defer self.allocator.free(bytes);
        try self.sendRaw(bytes);
    }

    fn allocQuestionId(self: *Connection) u32 {
        const id = self.next_question_id;
        self.next_question_id +%= 1;
        if (self.next_question_id == 0) self.next_question_id = 1;
        return id;
    }

    fn allocExportId(self: *Connection) u32 {
        const id = self.next_export_id;
        self.next_export_id +%= 1;
        if (self.next_export_id == 0) self.next_export_id = 1;
        return id;
    }

    fn allocExport(self: *Connection, capability: Capability) !u32 {
        const id = self.allocExportId();
        try self.exports.put(id, .{ .capability = capability, .ref_count = 1 });
        return id;
    }
};
