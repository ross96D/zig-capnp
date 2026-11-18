//! Level 0 smoke test for `ConnectionV2`: request the bootstrap capability,
//! wait for the answer, then call the bootstrap interface (an echo).

const std = @import("std");

const capnp = @import("capnp");
const rpc = @import("../generated/rpc.zig");

const connection = @import("../connection_v2.zig");
const transports = @import("../transports/mod.zig");
const transport = @import("../transports/transport.zig");

const ConnectionV2 = connection.ConnectionV2;
const CallContext = connection.CallContext;
const LocalCapability = connection.LocalCapability;
const Pipe = transport.testing.Pipe;
const testing = std.testing;

const echo_interface_id: u64 = 0x4b7e2d9a1c6f8035;
const echo_request = "ping";

/// The bootstrap interface. Method 0 echoes its text parameter back.
fn echoDispatch(_: ?*anyopaque, method_id: u16, call: *CallContext) anyerror!void {
    if (method_id != 0) return error.MethodNotFound;

    const request = try (try call.params.content()).asText();
    var results = try call.results.setResults();
    try results.content().setText(request);
}

const BootstrapState = struct {
    done: bool = false,
    capability: u32 = 0xDEAD_BEEF,
};

/// Bootstrap answers carry the new capability in slot 0 of the payload's
/// capability table.
fn onBootstrapReturn(context: ?*anyopaque, returns: *const rpc.Return.Reader) void {
    const state: *BootstrapState = @ptrCast(@alignCast(context.?));

    const payload = (returns.results() catch @panic("bootstrap answer has no payload")) orelse
        @panic("bootstrap answer has no payload");
    const cap_table = payload.capTable() catch @panic("bootstrap answer has no cap table");
    const descriptor = cap_table.get(0);

    state.capability = descriptor.senderHosted() orelse
        @panic("bootstrap capability is not senderHosted");
    state.done = true;
}

const CallState = struct {
    done: bool = false,
    response: [32]u8 = undefined,
    response_len: usize = 0,

    fn text(self: *const CallState) []const u8 {
        return self.response[0..self.response_len];
    }
};

fn onCallReturn(context: ?*anyopaque, returns: *const rpc.Return.Reader) void {
    const state: *CallState = @ptrCast(@alignCast(context.?));

    const payload = (returns.results() catch @panic("call answer has no payload")) orelse
        @panic("call answer has no payload");
    const text = (payload.content() catch @panic("call answer has no content"))
        .asText() catch @panic("call answer is not text");

    // The connection owns the frame that backs `text`, so copy it out before
    // returning from the callback.
    state.response_len = @min(text.len, state.response.len);
    @memcpy(state.response[0..state.response_len], text[0..state.response_len]);
    state.done = true;
}

/// Move queued frames between the two endpoints until neither side makes
/// progress any more.
fn pump(pipe: *Pipe, client: *ConnectionV2, server: *ConnectionV2) !void {
    const server_transport = pipe.endpoint(.a);
    const client_transport = pipe.endpoint(.b);

    var rounds: usize = 0;
    while (rounds < 32) : (rounds += 1) {
        var progressed = false;

        try server_transport.flush();
        try client_transport.flush();

        while (try server_transport.receive(testing.allocator)) |frame| {
            // `onMessage` takes ownership of the frame.
            server.onMessage(frame) catch |err| std.debug.panic("unexpected {}", .{err});
            testing.allocator.free(frame);
            progressed = true;
        }

        while (try client_transport.receive(testing.allocator)) |frame| {
            client.onMessage(frame) catch |err| std.debug.panic("unexpected {}", .{err});
            testing.allocator.free(frame);
            progressed = true;
        }

        if (!progressed) return;
    }

    return error.PumpDidNotSettle;
}

test "bootstrap then call the echo bootstrap interface" {
    const pipe = try Pipe.init(testing.allocator, .{});
    defer pipe.deinit();

    var server = ConnectionV2.init(testing.allocator, pipe.endpoint(.a), "server");
    defer server.destroy();

    var client = ConnectionV2.init(testing.allocator, pipe.endpoint(.b), "client");
    defer client.destroy();

    try server.setBootstrap(LocalCapability{
        .context = null,
        .interface_id = echo_interface_id,
        .dispatch = echoDispatch,
    });

    // 1. Ask for the bootstrap capability and wait for the answer.
    var bootstrap_state = BootstrapState{};
    _ = try client.bootstrap(&bootstrap_state, onBootstrapReturn);

    try pump(pipe, &client, &server);
    try testing.expect(bootstrap_state.done);

    // 2. Build a call aimed at the capability we just received.
    var message = try capnp.GrowableMessage.init(testing.allocator, 1024);
    defer message.deinit();

    var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
    var call = try root.setCall();

    var target = try call.target();
    target.setImportedCap(bootstrap_state.capability);

    call.setMethodId(0);
    call.sendResultsTo().setCaller();

    var params = try call.params();
    try params.content().setText(echo_request);

    var call_state = CallState{};
    _ = try client.makeCall(call.asReader(), &call_state, onCallReturn);

    // 3. Pump until the echo answer comes back.
    try pump(pipe, &client, &server);
    try testing.expect(call_state.done);
    try testing.expectEqualStrings(echo_request, call_state.text());
}
