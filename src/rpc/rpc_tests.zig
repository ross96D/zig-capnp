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
