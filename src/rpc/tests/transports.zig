const std = @import("std");
const capnp = @import("capnp");
const rpc = @import("../generated/rpc.zig");
const connection = @import("../connection.zig");
const transports = @import("../transports/mod.zig");
const support = @import("support.zig");
const testing = std.testing;

const TestInterface = support.TestInterface;
const EchoInterface = support.EchoInterface;
const ProviderInterface = support.ProviderInterface;
const PipelineInterface = support.PipelineInterface;
const ProviderState = support.ProviderState;
const DestroyCounter = support.DestroyCounter;
const countDestroy = support.countDestroy;
const recordDisembargo = support.recordDisembargo;
const scriptedPump = support.scriptedPump;
const scriptedBootstrap = support.scriptedBootstrap;
const messageIsReturnException = support.messageIsReturnException;

fn receiveWithPoll(
    transport: connection.Transport,
    allocator: std.mem.Allocator,
) ![]u8 {
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        if (try transport.receive(allocator)) |message| return message;

        var fds = [1]std.posix.pollfd{.{
            .fd = transport.fd(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = try std.posix.poll(&fds, 100);
    }
    return error.Timeout;
}

fn pollConnections(
    client: connection.Transport,
    server: connection.Transport,
) !void {
    var fds = [2]std.posix.pollfd{
        .{ .fd = client.fd(), .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = server.fd(), .events = std.posix.POLL.IN, .revents = 0 },
    };
    _ = try std.posix.poll(&fds, 1000);
}

test "unix transport frames messages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.net.UnixAddress.max_len]u8 = undefined;
    const path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/rpc.sock",
        .{tmp.sub_path[0..]},
    );

    var listener = try transports.Unix.Listener.listen(
        testing.allocator,
        path,
        .{},
    );
    defer listener.deinit();

    var client_stream = try transports.Unix.Stream.connect(
        testing.allocator,
        path,
        .{},
    );
    defer client_stream.deinit();

    var server_stream = (try listener.accept()) orelse return error.NoConnection;
    defer server_stream.deinit();

    const client = client_stream.endpoint(.client);
    const server = server_stream.endpoint(.server);

    // One segment containing one word.
    const frame1 = "\x00\x00\x00\x00" ++ "\x01\x00\x00\x00" ++ "abcdefgh";
    // Two segments, each one word, with the required header padding.
    const frame2 = "\x01\x00\x00\x00" ++
        "\x01\x00\x00\x00" ++
        "\x01\x00\x00\x00" ++
        "\x00\x00\x00\x00" ++
        "12345678" ++
        "ABCDEFGH";

    try client.send(frame1);
    try client.send(frame2);

    const got1 = try receiveWithPoll(server, testing.allocator);
    defer testing.allocator.free(got1);
    try testing.expectEqualSlices(u8, frame1, got1);

    const got2 = try receiveWithPoll(server, testing.allocator);
    defer testing.allocator.free(got2);
    try testing.expectEqualSlices(u8, frame2, got2);
}

test "unix transport carries an RPC call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.net.UnixAddress.max_len]u8 = undefined;
    const path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/rpc.sock",
        .{tmp.sub_path[0..]},
    );

    var listener = try transports.Unix.Listener.listen(
        testing.allocator,
        path,
        .{},
    );
    defer listener.deinit();

    var client_stream = try transports.Unix.Stream.connect(
        testing.allocator,
        path,
        .{},
    );
    defer client_stream.deinit();

    var server_stream = (try listener.accept()) orelse return error.NoConnection;
    defer server_stream.deinit();

    var server = try connection.Connection.init(
        testing.allocator,
        server_stream.endpoint(.server),
    );
    defer server.deinit();

    var client = try connection.Connection.init(
        testing.allocator,
        client_stream.endpoint(.client),
    );
    defer client.deinit();

    server.setBootstrap(try server.initLocal(.{
        .context = null,
        .interface_id = TestInterface.id,
        .dispatch = TestInterface.dispatch,
    }));

    var bootstrap = try client.bootstrapStart();
    var capability: connection.Capability = undefined;
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        if (try bootstrap.tryTake()) |cap| {
            capability = cap;
            break;
        }
        try pollConnections(client.transport, server.transport);
        try client.step();
        try server.step();
    } else return error.Timeout;

    var request = try client.beginCall(capability, TestInterface.id, 0);
    defer request.deinit();

    var params = try request.params();
    try params.content().setText("ping");

    var promise = try request.start();
    var response: connection.Response = undefined;
    attempts = 0;
    while (attempts < 1000) : (attempts += 1) {
        if (try promise.tryTake()) |result| {
            response = result;
            break;
        }
        try pollConnections(client.transport, server.transport);
        try client.step();
        try server.step();
    } else return error.Timeout;
    defer response.deinit();

    const payload = try response.payload();
    const result = try (try payload.content()).asText();
    try testing.expectEqualStrings("pong", result);
}
