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
        call: connection.Call,
    ) anyerror!void {
        switch (method_id) {
            0 => {
                const input = try call.params.asText();
                if (!std.mem.eql(u8, input, "ping")) return error.UnexpectedParams;
                try call.results.setText("pong");
            },
            1 => return error.MethodFailed,
            else => return error.MethodNotFound,
        }
    }
};

const EchoInterface = struct {
    const id: u64 = 0x4b7e2d9a1c6f8035;

    fn dispatch(_: *anyopaque, method_id: u16, call: connection.Call) anyerror!void {
        if (method_id != 0) return error.MethodNotFound;
        try call.results.setText(try call.params.asText());
    }
};

const ProviderInterface = struct {
    const id: u64 = 0xd2a6f4c81b903e57;

    fn dispatch(context: *anyopaque, method_id: u16, call: connection.Call) anyerror!void {
        const state: *ProviderState = @ptrCast(@alignCast(context));
        switch (method_id) {
            0 => {
                const index = try call.addResultCapability(.{ .local = state.echo });
                call.results.setCapability(index);
            },
            1 => {
                if (call.capabilities.len != 1) return error.MissingCapability;

                var request = try call.connection.beginCall(call.capabilities[0], EchoInterface.id, 0);
                defer request.deinit();
                var params = try request.params();
                try params.content().setText("from-client");
                var response = try request.send();
                defer response.deinit(call.connection.allocator);

                const payload = try response.payload();
                try call.results.setText(try (try payload.content()).asText());
            },
            2 => {
                const promise = try call.connection.newPromise();
                state.promise = promise;
                const index = try call.addResultCapability(promise);
                call.results.setCapability(index);
            },
            3 => {
                if (call.capabilities.len != 1) return error.MissingCapability;
                switch (call.capabilities[0]) {
                    .local => try call.results.setText("local-answer"),
                    else => return error.NotLocalAnswer,
                }
            },
            else => return error.MethodNotFound,
        }
    }
};

fn recordDisembargo(context: *anyopaque, embargo_id: u32) void {
    const result: *u32 = @ptrCast(@alignCast(context));
    result.* = embargo_id;
}

const ProviderState = struct {
    echo: connection.LocalCapability,
    promise: ?connection.Capability = null,
};

test "generated RPC protocol bindings compile" {
    std.testing.refAllDecls(@import("rpc.zig"));
    std.testing.refAllDecls(@import("rpc_twoparty.zig"));
}

test "level 0 bootstrap, call, return, and finish" {
    var loopback = connection.transports.Loopback.init(testing.allocator);
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
    var loopback = connection.transports.Loopback.init(testing.allocator);
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

test "level 1 returned capability and release" {
    var loopback = connection.transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = &server;
    server.peer = &client;

    var state = ProviderState{ .echo = .{
        .context = undefined,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(.{ .local = .{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    } });

    const provider = try client.bootstrap();

    var request = try client.beginCall(provider, ProviderInterface.id, 0);
    defer request.deinit();
    var response = try request.send();
    defer response.deinit(testing.allocator);

    const echo = try response.capability(0);

    var echo_request = try client.beginCall(echo, EchoInterface.id, 0);
    defer echo_request.deinit();
    var echo_params = try echo_request.params();
    try echo_params.content().setText("hello");
    var echo_response = try echo_request.send();
    defer echo_response.deinit(testing.allocator);

    const echo_payload = try echo_response.payload();
    try testing.expectEqualStrings("hello", try (try echo_payload.content()).asText());

    try client.releaseCapability(echo);

    var failed_request = try client.beginCall(echo, EchoInterface.id, 0);
    defer failed_request.deinit();
    var failed_response = try failed_request.send();
    defer failed_response.deinit(testing.allocator);
    try testing.expectEqual(rpc.Return.Tag.exception, try failed_response.which());
}

test "level 1 params capability" {
    var loopback = connection.transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = &server;
    server.peer = &client;

    var state = ProviderState{ .echo = .{
        .context = undefined,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(.{ .local = .{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    } });

    const provider = try client.bootstrap();

    const client_echo = connection.LocalCapability{
        .context = undefined,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    };

    var request = try client.beginCall(provider, ProviderInterface.id, 1);
    defer request.deinit();
    const cap_index = try request.addCapability(.{ .local = client_echo });
    var params = try request.params();
    params.content().setCapability(cap_index);

    var response = try request.send();
    defer response.deinit(testing.allocator);

    const payload = try response.payload();
    try testing.expectEqualStrings("from-client", try (try payload.content()).asText());
}

test "promise pipelining against a returned capability" {
    var loopback = connection.transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = &server;
    server.peer = &client;

    var state = ProviderState{ .echo = .{
        .context = undefined,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(.{ .local = .{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    } });

    const provider = try client.bootstrap();

    var request = try client.beginCall(provider, ProviderInterface.id, 0);
    defer request.deinit();
    var pending = try request.start();
    const promised_echo = try pending.capability(null);

    var echo_request = try client.beginCall(promised_echo, EchoInterface.id, 0);
    defer echo_request.deinit();
    var echo_params = try echo_request.params();
    try echo_params.content().setText("pipelined");
    var echo_response = try echo_request.send();
    defer echo_response.deinit(testing.allocator);

    const echo_payload = try echo_response.payload();
    try testing.expectEqualStrings("pipelined", try (try echo_payload.content()).asText());

    var outer_response = try pending.wait();
    defer outer_response.deinit(testing.allocator);
}

test "promise export queues calls until resolved" {
    var loopback = connection.transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = &server;
    server.peer = &client;

    var state = ProviderState{ .echo = .{
        .context = undefined,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(.{ .local = .{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    } });

    const provider = try client.bootstrap();

    var promise_request = try client.beginCall(provider, ProviderInterface.id, 2);
    defer promise_request.deinit();
    var promise_response = try promise_request.send();
    defer promise_response.deinit(testing.allocator);

    const promise = try promise_response.capability(0);

    var queued_request = try client.beginCall(promise, EchoInterface.id, 0);
    defer queued_request.deinit();
    var queued_params = try queued_request.params();
    try queued_params.content().setText("after-resolve");
    var pending = try queued_request.start();

    try server.resolvePromise(state.promise.?, .{ .local = state.echo });

    var queued_response = try pending.wait();
    defer queued_response.deinit(testing.allocator);

    const payload = try queued_response.payload();
    try testing.expectEqualStrings("after-resolve", try (try payload.content()).asText());
}

test "disembargo loopback echo" {
    var loopback = connection.transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = &server;
    server.peer = &client;

    var state = ProviderState{ .echo = .{
        .context = undefined,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(.{ .local = .{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    } });

    const provider = try client.bootstrap();

    var seen: u32 = 0;
    client.setDisembargoCallback(.{ .context = &seen, .function = recordDisembargo });
    try client.sendDisembargoLoopback(provider, 42);
    try testing.expectEqual(@as(u32, 42), seen);
}

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

    var listener = try connection.transports.Unix.Listener.listen(
        testing.allocator,
        path,
        .{},
    );
    defer listener.deinit();

    var client_stream = try connection.transports.Unix.Stream.connect(
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

    var listener = try connection.transports.Unix.Listener.listen(
        testing.allocator,
        path,
        .{},
    );
    defer listener.deinit();

    var client_stream = try connection.transports.Unix.Stream.connect(
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

    server.setBootstrap(.{ .local = .{
        .context = undefined,
        .interface_id = TestInterface.id,
        .dispatch = TestInterface.dispatch,
    } });

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
    defer response.deinit(testing.allocator);

    const payload = try response.payload();
    const result = try (try payload.content()).asText();
    try testing.expectEqualStrings("pong", result);
}

test "receiverAnswer descriptor resolves against the answer table" {
    var loopback = connection.transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = &server;
    server.peer = &client;

    var state = ProviderState{ .echo = .{
        .context = undefined,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(.{ .local = .{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    } });

    const provider = try client.bootstrap();

    var initial_request = try client.beginCall(provider, ProviderInterface.id, 0);
    defer initial_request.deinit();
    var pending = try initial_request.start();
    const promised = try pending.capability(null);

    var request = try client.beginCall(provider, ProviderInterface.id, 3);
    defer request.deinit();
    const cap_index = try request.addCapability(promised);
    var params = try request.params();
    params.content().setCapability(cap_index);

    var response = try request.send();
    defer response.deinit(testing.allocator);

    const payload = try response.payload();
    try testing.expectEqualStrings("local-answer", try (try payload.content()).asText());

    var initial_response = try pending.wait();
    defer initial_response.deinit(testing.allocator);
}
