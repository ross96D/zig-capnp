const std = @import("std");

const capnp = @import("../capnp.zig"); // TODO use capnp library instead
// const capnp = @import("capnp");
const rpc = @import("generated/rpc.zig");
const twoparty = @import("generated/rpc_twoparty.zig");

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

    pub fn init(allocator: std.mem.Allocator, transport: Transport, side: Side) ConnectionV2 {
        return .{
            .allocator = allocator,
            .transport = transport,
            .side = side,
        };
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
        var message = capnp.MessageBuilder{
            .allocator = self.allocator,
            .next_segment_bytes = message_initial_segment_bytes,
        };
        try message.init();
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
        var message = capnp.MessageBuilder{
            .allocator = self.allocator,
            .next_segment_bytes = message_initial_segment_bytes,
        };
        try message.init();
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

    pub fn onMessage(self: *ConnectionV2, message: *rpc.Message.Reader) void {
        switch (message.which()) {
            .unimplemented => {
                const unimplemented = (try message.unimplemented()).?;
                _ = unimplemented;
            },
            .abort => {
                const abort = (try message.abort()).?;
                _ = abort;
            },
            // ------------- Level 0 features -------------
            .bootstrap => {
                const bootstraps = (try message.bootstrap()).?;

                if (self.exports.get(self.bootstrap_cap_id) == null) {
                    @panic("TODO send exception no bootstrap interface");
                }

                var response_builder = capnp.MessageBuilder{ .allocator = self.allocator };
                try response_builder.init();
                defer response_builder.deinit();
                const returns = response_builder.initRootStruct(rpc.Return.Builder, rpc.Return.builder_trait) catch {
                    @panic("TODO abort");
                };
                returns.setAnswerId(bootstraps.questionId());
                returns.setReleaseParamCaps(true);

                var results = returns.setResults() catch |err| std.debug.panic("unreachable {}", .{err});
                results.content().setCapability(0);

                var cap_table = try results.capTable();
                try cap_table.init(1);
                cap_table.get(0).setSenderHosted(self.bootstrap_cap_id);

                self.send(&response_builder);
            },
            .call => {
                const call = (try message.call()).?;
                _ = call;
            },
            .@"return" => {
                const returns = (try message.@"return"()).?;
                const anwser_id = returns.answerId();
                if (self.questions.get(anwser_id)) |question| {
                    question.on_return(question.context, returns);
                    self.questions.remove(question.id);

                    // TODO send Finish
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
};

pub const ConnectionContext = struct {};

pub const CallContext = struct {
    conection: *const ConnectionContext,
    params: rpc.Payload.Reader,
    results: rpc.Return.Builder,
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

/// RPC control messages are usually small. Avoid `MessageBuilder`'s 64 KiB
/// default reservation for every request/response.
const message_initial_segment_bytes: u32 = 1024;

/// `MessageBuilder` stores at most 16 segments. Header size for 16 segments is
/// 4 * (16 + 1) = 68 bytes, aligned up to 72.
const message_header_buffer_bytes: usize = 72;

test "_" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ConnectionV2);
}
