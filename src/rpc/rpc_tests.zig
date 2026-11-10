const std = @import("std");
const capnp = @import("capnp");
const rpc = @import("rpc.zig");
const connection = @import("connection.zig");

const testing = std.testing;

const TestInterface = struct {
    const id: u64 = 0x8f13b9d2a7c4e601;

    fn dispatch(
        _: *anyopaque,
        method_id: u16,
        params: capnp.AnyPointerReader,
        results: capnp.AnyPointerBuilder,
    ) anyerror!void {
        switch (method_id) {
            0 => {
                const input = try params.asText();
                if (!std.mem.eql(u8, input, "ping")) return error.UnexpectedParams;
                try results.setText("pong");
            },
            1 => return error.MethodFailed,
            else => return error.MethodNotFound,
        }
    }
};

test "generated RPC protocol bindings compile" {
    std.testing.refAllDecls(@import("rpc.zig"));
    std.testing.refAllDecls(@import("rpc_twoparty.zig"));
}

test "level 0 bootstrap, call, return, and finish" {
    var loopback = connection.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = &server;
    server.peer = &client;

    server.setBootstrap(.{ .local = .{
        .context = undefined,
        .interface_id = TestInterface.id,
        .dispatch = TestInterface.dispatch,
    } });

    const capability = try client.bootstrap();

    var request = try client.beginCall(capability, TestInterface.id, 0);
    defer request.deinit();

    var params = try request.params();
    try params.content().setText("ping");

    var response = try request.send();
    defer response.deinit(testing.allocator);

    const payload = try response.payload();
    const result = try (try payload.content()).asText();
    try testing.expectEqualStrings("pong", result);
}

test "level 0 remote exception is returned" {
    var loopback = connection.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = &server;
    server.peer = &client;

    server.setBootstrap(.{ .local = .{
        .context = undefined,
        .interface_id = TestInterface.id,
        .dispatch = TestInterface.dispatch,
    } });

    const capability = try client.bootstrap();

    var request = try client.beginCall(capability, TestInterface.id, 1);
    defer request.deinit();

    var response = try request.send();
    defer response.deinit(testing.allocator);

    try testing.expectEqual(rpc.Return.Tag.exception, try response.which());
    const exception = (try response.exception()) orelse return error.MissingException;
    try testing.expectEqualStrings("MethodFailed", try exception.reason());
}
