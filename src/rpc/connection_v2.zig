const std = @import("std");

const capnp = @import("../capnp.zig"); // TODO use capnp library instead
// const capnp = @import("capnp");
const rpc = @import("generated/rpc.zig");
const twoparty = @import("generated/rpc_twoparty.zig");
const wire = @import("wire.zig");

const Transport = @import("transport.zig").Transport;
const MessageParts = @import("transport.zig").MessageParts;
const SlotMap = @import("slot_map.zig").SlotMap;

pub const Side = twoparty.Side;

/// **(level 0)**
///
/// Identifies a question in the sender's question table (which corresponds to the receiver's answer
/// table).  The questioner (caller) chooses an ID when making a call.  The ID remains valid in
/// caller -> callee messages until a Finish message is sent, and remains valid in callee -> caller
/// messages until a Return message is sent.
pub const QuestionId = i32;

/// **(level 0)**
///
/// Identifies an answer in the sender's answer table (which corresponds to the receiver's question
/// table).
///
/// AnswerId is physically equivalent to QuestionId, since the question and answer tables correspond,
/// but we define a separate type for documentation purposes:  we always use the type representing
/// the sender's point of view.
pub const AnswerId = i32;

/// **(level 1)**
///
/// Identifies an exported capability or promise in the sender's export table (which corresponds
/// to the receiver's import table).  The exporter chooses an ID before sending a capability over the
/// wire.  If the capability is already in the table, the exporter should reuse the same ID.  If the
/// ID is a promise (as opposed to a settled capability), this must be indicated at the time the ID
/// is introduced (e.g. by using `senderPromise` instead of `senderHosted` in `CapDescriptor`); in
/// this case, the importer shall expect a later `Resolve` message that replaces the promise.
///
/// ExportId/ImportIds are subject to reference counting.  Whenever an `ExportId` is sent over the
/// wire (from the exporter to the importer), the export's reference count is incremented (unless
/// otherwise specified).  The reference count is later decremented by a `Release` message.  Since
/// the `Release` message can specify an arbitrary number by which to reduce the reference count, the
/// importer should usually batch reference decrements and only send a `Release` when it believes the
/// reference count has hit zero.  Of course, it is possible that a new reference to the export is
/// in-flight at the time that the `Release` message is sent, so it is necessary for the exporter to
/// keep track of the reference count on its end as well to avoid race conditions.
///
/// When a connection is lost, all exports are implicitly released.  It is not possible to restore
/// a connection state after disconnect (although a transport layer could implement a concept of
/// persistent connections if it is transparent to the RPC layer).
pub const ExportId = i32;

/// **(level 1)**
///
/// Identifies an imported capability or promise in the sender's import table (which corresponds to
/// the receiver's export table).
///
/// ImportId is physically equivalent to ExportId, since the export and import tables correspond,
/// but we define a separate type for documentation purposes:  we always use the type representing
/// the sender's point of view.
///
/// An `ImportId` remains valid in importer -> exporter messages until the importer has sent
/// `Release` messages that (it believes) have reduced the reference count to zero.
pub const ImportId = i32;

pub const ConnectionV2 = struct {
    allocator: std.mem.Allocator,

    transport: Transport,
    side: Side,
    bootstrap_cap_id: u32 = 0,

    exports: SlotMap(ExportedCapability) = .init(),
    imports: std.AutoHashMapUnmanaged(u32, ImportedCapability) = .empty,

    questions: SlotMap(Question) = .init(),
    answers: std.AutoHashMapUnmanaged(u32, Answer) = .init(),

    pub fn init(allocator: std.mem.Allocator, transport: Transport, side: Side) ConnectionV2 {
        return .{
            .allocator = allocator,
            .transport = transport,
            .side = side,
        };
    }

    pub fn destroy(self: *ConnectionV2) void {
        self.exports.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.questions.deinit(self.allocator);
        {
            var iter = self.answers.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.answers.deinit(self.allocator);
        }
    }

    pub fn setBootstrap(self: *ConnectionV2, capability: LocalCapability) !void {
        if (self.side == .client) {
            @panic("can only set a bootstrap capability in the server side");
        }
        if (self.exports.get(self.bootstrap_cap_id) != null) {
            // TODO?: should we support several bootsrap initializations?
            @panic("Initialize bootstrap only once");
        }

        const id = try self.exports.add(self.allocator, .{
            .id = 0,
            .local = capability,
            .ref_count = 1, // is this correct?
        });
        self.bootstrap_cap_id = id;
        self.exports.get(id).?.id = id;
    }

    pub fn bootstrap(
        self: *ConnectionV2,
        context: ?*anyopaque,
        on_return: fn (context: ?*anyopaque, returns: *rpc.Return.Reader) void,
    ) !QuestionId {
        // This MessageBuilder should allocate the bytes segments in the stack
        var message = try capnp.GrowableMessage.init(self.allocator, message_initial_segment_bytes);
        defer message.deinit();

        const question = try self.newQuestion(context, on_return);
        errdefer self.questions.remove(question.id);

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var bootstrap_message = try root.setBootstrap();
        bootstrap_message.setQuestionId(question.id);

        try self.send(&message);

        return question.id;
    }

    pub fn beginCall(
        self: *ConnectionV2,
        call_reader: rpc.Call.Reader,
        context: ?*anyopaque,
        on_return: fn (context: ?*anyopaque, returns: *rpc.Return.Reader) void,
    ) !void {
        // Maybe capnp.MessageBuilder should be pooled
        var message = try capnp.GrowableMessage.init(self.allocator, message_initial_segment_bytes);
        defer message.deinit();

        const question = try self.newQuestion(context, on_return);
        errdefer self.questions.remove(question.id);

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var call = try root.setCall();
        try call.copyFrom(call_reader);
        call.setQuestionId(question.id);
        call.setAllowThirdPartyTailCall(false);

        try self.send(&message);

        return question.id;
    }

    /// Send a message without flattening it into a single allocation.
    pub fn send(self: *ConnectionV2, message: *const capnp.MessageBuilder) !void {
        var header_buffer: [message_header_buffer_bytes]u8 = undefined;
        const parts = MessageParts{
            .header = message.writeHeader(&header_buffer) catch unreachable,
            .segments = message.segmentSlices(),
        };
        self.transport.send(parts) catch |err| {
            // TODO: A failed write means the transport can no longer make progress.
            // Deinitialize connection.
            return err;
        };
    }

    fn newQuestion(
        self: *ConnectionV2,
        context: ?*anyopaque,
        on_return: fn (context: ?*anyopaque, returns: *rpc.Return.Reader) void,
    ) !*Question {
        const id = try self.questions.add(self.allocator, .{
            .id = 0,
            .context = context,
            .on_return = on_return,
        });
        var question = self.questions.get(id).?;
        question.id = id;
        return question;
    }

    pub fn onMessage(self: *ConnectionV2, frame: []const u8) void {
        var msg = try capnp.Message.fromOwnedBytes(frame, self.allocator);
        defer msg.deinit(self.allocator);
        const message = try msg.getRootStruct(rpc.Message.Reader, rpc.Message.reader_trait);

        switch (message.which()) {
            .unimplemented => {
                const unimplemented = (try message.unimplemented()).?;
                _ = unimplemented;
                // TODO release resources associated with the message
            },
            .abort => {
                const abort = (try message.abort()).?;
                _ = abort;
                self.destroy();
                // TODO release connection
            },
            // ------------- Level 0 features -------------
            .bootstrap => {
                const bootstraps = (try message.bootstrap()).?;

                if (self.exports.get(self.bootstrap_cap_id) == null) {
                    @panic("TODO send exception no bootstrap interface");
                }

                const buffer_size = comptime capnp.framedSize(&[_]capnp.Size{
                    capnp.Size.ofStruct(rpc.Message.builder_trait),
                    capnp.Size.ofStruct(rpc.Return.builder_trait),
                    capnp.Size.ofStruct(rpc.Payload.builder_trait),
                    capnp.Size.ofCompositeList(rpc.CapDescriptor.builder_trait, 1),
                });
                var buffer: [buffer_size]u8 = undefined;

                var response_builder = capnp.MessageBuilder.initBuffer(&buffer);

                const returns = response_builder.initRootStruct(
                    rpc.Return.Builder,
                    rpc.Return.builder_trait,
                ) catch |err| unreachable_err(err);

                returns.setAnswerId(bootstraps.questionId());
                returns.setReleaseParamCaps(true);

                var results = returns.setResults() catch |err| unreachable_err(err);
                results.content().setCapability(0);

                var cap_table = try results.capTable();
                try cap_table.init(1);
                cap_table.get(0).setSenderHosted(self.bootstrap_cap_id);

                self.send(&response_builder);
            },
            .call => {
                const call = (try message.call()).?;

                self.onCall(&call, frame);
            },
            .@"return" => {
                const returns = (try message.@"return"()).?;
                const anwser_id = returns.answerId();

                if (self.questions.get(anwser_id)) |question| {
                    question.on_return(question.context, returns);
                    self.questions.remove(question.id);

                    var buffer: [wire.finish_size]u8 = undefined;
                    const finish_message = try wire.buildFinishInto(&buffer, question.id, true);
                    self.send(&finish_message);
                }
            },
            .finish => {
                const finish = (try message.finish()).?;
                _ = finish;
            },
            // ------------- Level 1 features -------------
            .resolve => {
                const resolve = (try message.resolve()).?;
                _ = resolve;
            },
            .release => {
                const release = (try message.release()).?;
                _ = release;
            },
            .disembargo => {
                const disembargo = (try message.disembargo()).?;
                _ = disembargo;
            },
            // ------------- Level 2 features -------------
            .obsoleteSave => {
                const obsoleteSave = (try message.obsoleteSave()).?;
                _ = obsoleteSave;
                // TODO send unsupported
            },
            .obsoleteDelete => {
                const obsoleteDelete = (try message.obsoleteDelete()).?;
                _ = obsoleteDelete;
                // TODO send unsupported
            },
            // ------------- Level 3 features -------------
            .provide => {
                const provide = (try message.provide()).?;
                _ = provide;
            },
            .accept => {
                const accept = (try message.accept()).?;
                _ = accept;
            },
            // ------------- Level 4 features -------------
            .join => {
                const join = (try message.join()).?;
                _ = join;
            },
        }
    }

    fn onCall(self: *ConnectionV2, call: *const rpc.Call.Reader, frame: []u8) !void {
        const answer_id = call.questionId();
        const target = try call.target();
        const method_id = call.methodId();

        const sendTo = call.sendResultsTo();
        switch (sendTo.which()) {
            .caller => {},
            else => {
                @panic("TODO: send unsuported");
            },
        }

        const params = try call.params();
        const entry = try self.answers.getOrPut(
            self.allocator,
            answer_id,
            Answer{ .id = answer_id },
        );
        entry.value_ptr.frame = try self.allocator.dupe(u8, frame);

        switch (target.which()) {
            .importedCap => {
                const cap = target.importedCap().?;

                const expo = self.exports.get(cap) orelse {
                    @panic("TODO: send exepction Unknown capability");
                };

                try self.dispatchLocalCapabilityCall(
                    &params,
                    &expo.local,
                    entry.value_ptr,
                );
            },
            .promisedAnswer => {
                const promise = (try target.promisedAnswer()).?;
                self.onCallPromisedAnswer(&params, method_id, &promise);
            },
            else => {
                @panic("TODO: send unsuported target");
            },
        }
    }

    fn dispatchLocalCapabilityCall(
        self: *ConnectionV2,
        local: *LocalCapability,
        answer: *Answer,
    ) !void {
        const call_message = try capnp.Message.fromOwnedBytes(answer.frame, self.allocator);
        defer call_message.deinit(self.allocator);

        const call_message_reader = call_message.getRootStruct(rpc.Message.Reader, rpc.Message.reader_trait) catch |err| unreachable_err(err);
        const call_reader = (call_message_reader.call() catch |err| unreachable_err(err)).?;
        const params = call_reader.params() catch |err| unreachable_err(err).?;
        const method_id = call_reader.methodId();

        var response = try capnp.GrowableMessage.init(self.allocator, message_initial_segment_bytes);
        defer response.deinit();

        var root = try response.initRootStruct(
            rpc.Message.Builder,
            rpc.Message.builder_trait,
        );
        var results = try root.setReturn();

        const call_context = CallContext{
            .connection = &.{},
            .params = &params,
            .results = &results,
        };

        local.dispatch(local.context, method_id, call_context) catch {
            @panic("TODO: send exception");
        };

        // TODO: maybe we could just save the growable message as an optimization.
        const size = response.serializedSize();
        const response_buffer_cpy = try self.allocator.alloc(u8, size);
        response.writeToBuffer(response_buffer_cpy) catch |err| unreachable_err(err);
        answer.return_frame = response_buffer_cpy;

        switch (results.which()) {
            .results => {
                const payload = (try call_context.results.results()).?.asReader();

                answer.dispatch_pending(self);

                var it = answer.pending_calls.first;
                while (it) |node| {
                    const pending: *PendingCall = @fieldParentPtr("node", node);
                    const pending_answer = self.answers.getPtr(pending.answer_id) orelse @panic("BUG: pending answer released but pending call is alive");
                    it = node.next;
                    const cap_descriptor = pending.apply_transform(&payload);

                    switch (cap_descriptor.which()) {
                        .none => @panic("TODO: how to handle this?"),
                        // the author of the answer is the current vat
                        // so this capability is in our exports
                        .senderHosted => {
                            const cap_index = cap_descriptor.senderHosted().?;
                            const capability = self.exports.get(cap_index) orelse {
                                @panic("TODO: send exception");
                            };

                            try self.dispatchLocalCapabilityCall(
                                &pending.params,
                                pending.method_id,
                                &capability.local,
                                pending_answer,
                            );
                        },
                        else => @panic("TODO"),
                    }
                }
            },
            else => @panic("TODO"),
        }
    }

    fn onCallPromisedAnswer(
        self: *ConnectionV2,
        answer: *Answer,
        promise: *const rpc.PromisedAnswer.Reader,
    ) !void {
        const promised_answer_id = promise.questionId();

        const promised_answer = self.answers.getPtr(promised_answer_id) orelse {
            var new_answer = Answer{ .id = promised_answer_id };

            const pending_call = try PendingCall.init(self.allocator, answer.id, &promise);
            new_answer.pending_calls.append(&pending_call.node);

            self.answers.put(self.allocator, promised_answer_id, new_answer);
            return;
        };

        // promised answer is recieved but not yet processed.
        if (promised_answer.return_frame.len == 0) {
            const pending_call = try PendingCall.init(self.allocator, answer.id, promise);
            promised_answer.pending_calls.append(&pending_call.node);

            return;
        }

        const returns = promised_answer.return_frame orelse {};
        _ = returns;
        @panic("TODO: answer is already here. Use it");
    }
};

pub const ConnectionContext = struct {};

pub const CallContext = struct {
    conection: *const ConnectionContext,
    params: *rpc.Payload.Reader,
    results: *rpc.Return.Builder,
};

pub const DispatchFn = *const fn (
    context: *anyopaque,
    method_id: u16,
    call_context: *CallContext,
) anyerror!void;

/// Capability located in the current side of the connection
pub const ExportedCapability = struct {
    id: u32,
    ref_count: u32,

    /// for a two party only implementation an exported capability is always
    /// a locally implemented capability
    local: LocalCapability,

    fn dispatch(
        self: *ExportedCapability,
        method_id: u16,
        params: *const rpc.Payload.Reader,
        results: *rpc.Return.Builder,
    ) void {
        const call_context = CallContext{
            .connection = &.{},
            .params = params,
            .results = &results,
        };

        self.dispatch(self.local.context, method_id, call_context) catch {
            @panic("TODO: send exception");
        };
    }
};

/// Locally implemented capability
pub const LocalCapability = struct {
    context: ?*anyopaque,
    interface_id: u64,
    dispatch: DispatchFn,
};

pub const ImportedCapability = struct {
    id: u32,
    ref_count: u32,
};

pub const Question = struct {
    id: u32,
    context: ?*anyopaque,
    on_return: *const fn (context: ?*anyopaque, returns: *rpc.Return.Reader) void,
};

const _empty_byte_slice: [0]u8 = .{};

pub const Answer = struct {
    id: u32,
    pending_calls: std.DoublyLinkedList = .{},
    // bytes that decode into a rpc.Message from the call message
    frame: []const u8 = &_empty_byte_slice,
    // bytes that decode into a rpc.Message from the return message
    return_frame: []const u8 = &_empty_byte_slice,

    fn deinit(self: *Answer, allocator: std.mem.Allocator) void {
        if (self.frame.len > 0) allocator.free(self.frame);
        if (self.return_frame.len > 0) allocator.free(self.return_frame);
    }

    fn dispatch_pending(self: *Answer, conn: *ConnectionV2) void {
        const msg = try capnp.Message.fromOwnedBytes(self.return_frame, conn.allocator);
        msg.deinit(conn.allocator);
        const message = try msg.getRootStruct(rpc.Message.Reader, rpc.Message.reader_trait);
        const returns = (try message.@"return"()).?;
        const payload = (try returns.results()).?;

        while (self.pending_calls.popFirst()) |node| {
            const pending: *PendingCall = @fieldParentPtr("node", node);
            const pending_answer = self.answers.getPtr(pending.answer_id) orelse @panic("BUG: pending answer released but pending call is alive");
            const cap_descriptor = pending.apply_transform(&payload);

            switch (cap_descriptor.which()) {
                .none => @panic("TODO: how to handle this?"),
                // the author of the answer is the current vat
                // so this capability is in our exports
                .senderHosted => {
                    const cap_index = cap_descriptor.senderHosted().?;
                    const capability = self.exports.get(cap_index) orelse {
                        @panic("TODO: send exception");
                    };

                    try conn.dispatchLocalCapabilityCall(&capability.local, pending_answer);
                },
                else => @panic("TODO"),
            }
        }
    }
};

const Op = struct {
    pointer_field: u16,
};

const PendingCall = struct {
    answer_id: u32,
    operations: []Op,
    node: std.DoublyLinkedList.Node,

    fn init(
        allocator: std.mem.Allocator,
        answer_id: u32,
        promised_answer: *const rpc.PromisedAnswer.Reader,
    ) !*PendingCall {
        const transform = try promised_answer.transform();

        const pending_call = try allocator.create(PendingCall);
        pending_call.answer_id = answer_id;

        var len = 0;
        for (0..transform.length) |i| {
            const op = transform.get(i);
            switch (op.which()) {
                .noop => {},
                .getPointerField => len += 1,
                else => @panic("TODO: return unsuported"),
            }
        }

        const operations = try allocator.alloc(Op, len);
        for (0..transform.length) |i| {
            const op = transform.get(i);
            switch (op.which()) {
                .noop => {},
                .getPointerField => {
                    operations[i].pointer_field = op.getPointerField().?;
                },
                else => unreachable,
            }
        }

        pending_call.operations = operations;

        return pending_call;
    }

    fn deinit(self: *PendingCall, allocator: std.mem.Allocator) void {
        allocator.free(self.operations);
        allocator.destroy(self);
    }

    fn apply_transform(self: *const PendingCall, payload: *const rpc.Payload.Reader) rpc.CapDescriptor.Reader {
        var value = payload.content() catch @panic("TODO: send exception");
        const cap_table = payload.capTable() catch @panic("TODO: send exception");

        for (self.operations) |op| {
            switch (value.ptr) {
                .struct_ => |struct_| {
                    const reader = capnp.StructReader{
                        .context = value.context,
                        .data_words = struct_.data_words,
                        .ptr_words = struct_.ptr_words,
                    };
                    value = reader.readPtrField(capnp.AnyPointer, op.pointer_field) catch @panic("TODO send exception in pending call");
                },
                else => @panic("TODO send exception in pending call"),
            }
        }

        const cap_index = value.asCapability() catch @panic("TODO: send exception in pending call");
        if (cap_index >= cap_table.length) {
            @panic("TODO: send exception");
        }
        return cap_table.get(cap_index);
    }
};

/// RPC control messages are usually small. Avoid `MessageBuilder`'s 64 KiB
/// default reservation for every request/response.
const message_initial_segment_bytes: u32 = 1024;

/// `MessageBuilder` stores at most 16 segments. Header size for 16 segments is
/// 4 * (16 + 1) = 68 bytes, aligned up to 72.
const message_header_buffer_bytes: usize = (capnp.max_segments + 1) * 4;

inline fn unreachable_err(err: anyerror) noreturn {
    std.debug.panicExtra(@returnAddress(), "unreachable {}", .{err});
}

test "_" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ConnectionV2);
}
