//! Minimal two-party, level-0 Cap'n Proto RPC runtime.
//!
//! This module implements the transport-independent message pump plus the
//! Bootstrap/Call/Return/Finish subset used by level-0 RPC. Capability
//! passing in payloads and promise pipelining are intentionally left for
//! later protocol levels.

const std = @import("std");
const capnp = @import("capnp");
const rpc = @import("rpc.zig");

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
        return self.vtable.send(self.context, self.side, bytes);
    }

    pub fn receive(self: Transport, allocator: std.mem.Allocator) anyerror!?[]u8 {
        return self.vtable.receive(self.context, self.side, allocator);
    }
};

/// In-memory duplex transport used by tests and local RPC.
pub const Loopback = struct {
    allocator: std.mem.Allocator,
    queues: [2]std.ArrayList([]u8) = .{ .empty, .empty },

    const vtable = Transport.VTable{
        .send = send,
        .receive = receive,
    };

    pub fn init(allocator: std.mem.Allocator) Loopback {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Loopback) void {
        for (&self.queues) |*queue| {
            for (queue.items) |bytes| self.allocator.free(bytes);
            queue.deinit(self.allocator);
        }
    }

    pub fn endpoint(self: *Loopback, side: Side) Transport {
        return .{ .context = self, .side = side, .vtable = &vtable };
    }

    fn send(context: *anyopaque, side: Side, bytes: []const u8) anyerror!void {
        const self: *Loopback = @ptrCast(@alignCast(context));
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);

        const peer: usize = 1 - @backingInt(side);
        try self.queues[peer].append(self.allocator, copy);
    }

    fn receive(context: *anyopaque, side: Side, allocator: std.mem.Allocator) anyerror!?[]u8 {
        _ = allocator;
        const self: *Loopback = @ptrCast(@alignCast(context));
        const idx = @backingInt(side);
        if (self.queues[idx].items.len == 0) return null;
        return self.queues[idx].orderedRemove(0);
    }
};

pub const DispatchFn = *const fn (
    context: *anyopaque,
    method_id: u16,
    params: capnp.AnyPointerReader,
    results: capnp.AnyPointerBuilder,
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

pub const Capability = union(enum) {
    local: LocalCapability,
    imported: ImportedCapability,
};

pub const Response = struct {
    message: capnp.Message,

    pub fn fromBytes(bytes: []const u8, allocator: std.mem.Allocator) !Response {
        const message = try capnp.Message.fromBytes(bytes, allocator);
        return .{ .message = message };
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
    sent: bool = false,

    pub fn params(self: *Request) !rpc.Payload.Builder {
        return try self.call.params();
    }

    pub fn send(self: *Request) !Response {
        if (self.sent) return error.AlreadySent;

        const allocator = self.connection.allocator;
        const bytes = try self.message.toBytes(allocator);
        defer allocator.free(bytes);

        try self.connection.sendRaw(bytes);
        var response = try self.connection.waitReturn(self.question_id);
        errdefer response.deinit(allocator);
        try self.connection.sendFinish(self.question_id, true);

        self.message.deinit();
        allocator.destroy(self.message);
        self.sent = true;
        return response;
    }

    pub fn deinit(self: *Request) void {
        if (self.sent) return;
        self.message.deinit();
        self.connection.allocator.destroy(self.message);
        self.sent = true;
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    /// Optional in-process peer. When set, sending a message immediately pumps
    /// the peer so that the blocking `Request.send` path can complete without
    /// an external event loop.
    peer: ?*Connection = null,
    bootstrap_capability: ?Capability = null,
    next_question_id: u32 = 1,
    next_export_id: u32 = 0,
    returns: std.AutoHashMap(u32, []u8),
    exports: std.AutoHashMap(u32, Capability),

    pub fn init(allocator: std.mem.Allocator, transport: Transport) !Connection {
        return .{
            .allocator = allocator,
            .transport = transport,
            .returns = std.AutoHashMap(u32, []u8).init(allocator),
            .exports = std.AutoHashMap(u32, Capability).init(allocator),
        };
    }

    pub fn deinit(self: *Connection) void {
        var return_it = self.returns.valueIterator();
        while (return_it.next()) |bytes| self.allocator.free(bytes.*);
        self.returns.deinit();
        self.exports.deinit();
    }

    pub fn setBootstrap(self: *Connection, capability: Capability) void {
        self.bootstrap_capability = capability;
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

    pub fn beginCall(
        self: *Connection,
        target: Capability,
        interface_id: u64,
        method_id: u16,
    ) !Request {
        const imported = switch (target) {
            .imported => |capability| capability,
            .local => return error.LocalTargetUnsupported,
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
        return try Response.fromBytes(entry.value, self.allocator);
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
                try self.handleCall(call);
            },
            .@"return" => {
                const return_ = (try root.@"return"()) orelse return error.InvalidMessage;
                try self.handleReturn(return_, bytes);
            },
            .finish => {},
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
        try self.sendRaw(bytes);
    }

    fn handleCall(self: *Connection, call: rpc.Call.Reader) !void {
        const question_id = call.questionId();

        const target = try call.target();
        const export_id = target.importedCap() orelse {
            try self.sendException(question_id, error.UnsupportedTarget);
            return;
        };

        const capability = self.exports.get(export_id) orelse {
            try self.sendException(question_id, error.UnknownCapability);
            return;
        };

        const local = switch (capability) {
            .local => |cap| cap,
            .imported => {
                try self.sendException(question_id, error.ForwardingUnsupported);
                return;
            },
        };

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

        var message = capnp.MessageBuilder{ .allocator = self.allocator };
        try message.init();
        defer message.deinit();

        var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
        var return_ = try root.setReturn();
        return_.setAnswerId(question_id);

        var results = try return_.setResults();
        local.dispatch(local.context, call.methodId(), params, results.content()) catch |err| {
            var exception = try return_.setException();
            try exception.setReason(@errorName(err));
            exception.setType(.failed);
        };

        const bytes = try message.toBytes(self.allocator);
        defer self.allocator.free(bytes);
        try self.sendRaw(bytes);
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

    fn allocQuestionId(self: *Connection) u32 {
        const id = self.next_question_id;
        self.next_question_id +%= 1;
        if (self.next_question_id == 0) self.next_question_id = 1;
        return id;
    }

    fn allocExport(self: *Connection, capability: Capability) !u32 {
        const id = self.next_export_id;
        self.next_export_id +%= 1;
        if (self.next_export_id == 0) self.next_export_id = 1;
        try self.exports.put(id, capability);
        return id;
    }
};
