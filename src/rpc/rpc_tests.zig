const std = @import("std");
const capnp = @import("capnp");
const rpc = @import("rpc.zig");
const connection = @import("connection.zig");
const transports = @import("transports/mod.zig");

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
                state.calls += 1;
                const index = try call.addLocalResultCapability(state.echo);
                call.results.setCapability(index);
            },
            1 => {
                if (call.capabilities.len != 1) return error.MissingCapability;
                // The params content must survive adding a capability to the
                // request's cap table.
                if (try call.params.asCapability() != 0) return error.UnexpectedParams;

                var request = try call.connection.beginCall(call.capabilities[0], EchoInterface.id, 0);
                defer request.deinit();
                var params = try request.params();
                try params.content().setText("from-client");
                var response = try request.send();
                defer response.deinit();

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
            4 => {
                // Return the caller's own capability: this is encoded as
                // receiverHosted and decoded back into a local handle.
                if (call.capabilities.len != 1) return error.MissingCapability;
                const index = try call.addResultCapability(call.capabilities[0]);
                call.results.setCapability(index);
            },
            5 => {
                // Return two references to the same capability so tests can
                // exercise releasing result caps that the caller never took.
                _ = try call.addLocalResultCapability(state.echo);
                _ = try call.addLocalResultCapability(state.echo);
                call.results.setCapability(0);
            },
            6 => {
                // Store a borrowed capability parameter for later use by the
                // test after the capability's answer resolves.
                if (call.capabilities.len != 1) return error.MissingCapability;
                if (state.stored) |old| old.release();
                state.stored = call.capabilities[0].retain();
                try call.results.setText("stored");
            },
            7 => {
                // Resolve our stored promise to the capability parameter.
                if (call.capabilities.len != 1) return error.MissingCapability;
                const promise = state.promise orelse return error.MissingPromise;
                try call.connection.resolvePromise(promise, call.capabilities[0]);
                try call.results.setText("resolved-to-param");
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
    stored: ?connection.Capability = null,
    calls: usize = 0,
};

fn scriptedPump(
    client: *connection.Connection,
    server: *connection.Connection,
    link: *transports.Scripted,
) !void {
    while (true) {
        var progressed = false;
        while (try link.deliverNext(.client)) {
            try server.step();
            progressed = true;
        }
        while (try link.deliverNext(.server)) {
            try client.step();
            progressed = true;
        }
        if (!progressed) return;
    }
}

fn messageIsReturnException(bytes: []const u8) !bool {
    var message = try capnp.Message.fromBytes(bytes, testing.allocator);
    defer message.deinit(testing.allocator);

    const root = try message.getRootStruct(rpc.Message.Reader, rpc.Message.reader_trait);
    const return_ = (try root.@"return"()) orelse return error.NotReturn;
    return return_.which() == .exception;
}

fn scriptedBootstrap(
    server: *connection.Connection,
    client: *connection.Connection,
    link: *transports.Scripted,
    capability: connection.LocalCapability,
) !connection.Capability {
    server.setBootstrap(try server.initLocal(capability));

    var promise = try client.bootstrapStart();
    try scriptedPump(client, server, link);
    const bootstrapped = try promise.wait();
    try scriptedPump(client, server, link);
    return bootstrapped;
}

const PipelineInterface = struct {
    const id: u64 = 0x9d7a02c4e8b1635f;

    fn dispatch(context: *anyopaque, method_id: u16, call: connection.Call) anyerror!void {
        const state: *ProviderState = @ptrCast(@alignCast(context));
        switch (method_id) {
            0 => {
                // Wait for a client-provided capability before returning a
                // local capability. This keeps the handler busy long enough
                // for a dependent pipelined call to arrive.
                if (call.capabilities.len != 1) return error.MissingCapability;

                var echo_request = try call.connection.beginCall(call.capabilities[0], EchoInterface.id, 0);
                defer echo_request.deinit();
                var echo_params = try echo_request.params();
                try echo_params.content().setText("wait");
                var echo_response = try echo_request.send();
                defer echo_response.deinit();
                const echo_payload = try echo_response.payload();
                _ = try (try echo_payload.content()).asText();

                const index = try call.addLocalResultCapability(state.echo);
                call.results.setCapability(index);
            },
            1 => {
                // The capability parameter is the promised result of method 0.
                // It is resolved locally by the time this call is dispatched.
                if (call.capabilities.len != 1) return error.MissingCapability;

                var echo_request = try call.connection.beginCall(call.capabilities[0], EchoInterface.id, 0);
                defer echo_request.deinit();
                var echo_params = try echo_request.params();
                try echo_params.content().setText("pipelined");
                var echo_response = try echo_request.send();
                defer echo_response.deinit();
                const echo_payload = try echo_response.payload();
                try call.results.setText(try (try echo_payload.content()).asText());
            },
            else => return error.MethodNotFound,
        }
    }
};

test "generated RPC protocol bindings compile" {
    std.testing.refAllDecls(@import("rpc.zig"));
    std.testing.refAllDecls(@import("rpc_twoparty.zig"));
}

test "level 0 bootstrap, call, return, and finish" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    server.setBootstrap(try server.initLocal(.{
        .context = null,
        .interface_id = TestInterface.id,
        .dispatch = TestInterface.dispatch,
    }));

    const capability = try client.bootstrap();

    var request = try client.beginCall(capability, TestInterface.id, 0);
    defer request.deinit();

    var params = try request.params();
    try params.content().setText("ping");

    var response = try request.send();
    defer response.deinit();

    const payload = try response.payload();
    const result = try (try payload.content()).asText();
    try testing.expectEqualStrings("pong", result);
}

test "level 0 remote exception is returned" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    server.setBootstrap(try server.initLocal(.{
        .context = null,
        .interface_id = TestInterface.id,
        .dispatch = TestInterface.dispatch,
    }));

    const capability = try client.bootstrap();

    var request = try client.beginCall(capability, TestInterface.id, 1);
    defer request.deinit();

    var response = try request.send();
    defer response.deinit();

    try testing.expectEqual(rpc.Return.Tag.exception, try response.which());
    const exception = (try response.exception()) orelse return error.MissingException;
    try testing.expectEqualStrings("MethodFailed", try exception.reason());
}

test "level 1 returned capability and release" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

    const provider = try client.bootstrap();

    var request = try client.beginCall(provider, ProviderInterface.id, 0);
    defer request.deinit();
    var response = try request.send();
    defer response.deinit();

    const echo = try response.capability(0);

    var echo_request = try client.beginCall(echo, EchoInterface.id, 0);
    defer echo_request.deinit();
    var echo_params = try echo_request.params();
    try echo_params.content().setText("hello");
    var echo_response = try echo_request.send();
    defer echo_response.deinit();

    const echo_payload = try echo_response.payload();
    try testing.expectEqualStrings("hello", try (try echo_payload.content()).asText());

    const echo_id = echo.imported.export_id;
    echo.release();

    // The released import is gone from the table; the handle is invalid.
    try testing.expect(!client.imports.contains(echo_id));
}

test "level 1 params capability" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

    const provider = try client.bootstrap();

    const client_echo = connection.LocalCapability{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    };

    var request = try client.beginCall(provider, ProviderInterface.id, 1);
    defer request.deinit();
    const cap_index = try request.addLocalCapability(client_echo);
    var params = try request.params();
    params.content().setCapability(cap_index);

    var response = try request.send();
    defer response.deinit();

    const payload = try response.payload();
    try testing.expectEqualStrings("from-client", try (try payload.content()).asText());
}

test "promise pipelining against a returned capability" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

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
    defer echo_response.deinit();

    const echo_payload = try echo_response.payload();
    try testing.expectEqualStrings("pipelined", try (try echo_payload.content()).asText());

    var outer_response = try pending.wait();
    defer outer_response.deinit();
}

test "promise export queues calls until resolved" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

    const provider = try client.bootstrap();

    var promise_request = try client.beginCall(provider, ProviderInterface.id, 2);
    defer promise_request.deinit();
    var promise_response = try promise_request.send();
    defer promise_response.deinit();

    const promise = try promise_response.capability(0);

    var queued_request = try client.beginCall(promise, EchoInterface.id, 0);
    defer queued_request.deinit();
    var queued_params = try queued_request.params();
    try queued_params.content().setText("after-resolve");
    var pending = try queued_request.start();

    const resolved_target = try server.initLocal(state.echo);
    defer resolved_target.release();
    try server.resolvePromise(state.promise.?, resolved_target);

    const promise_import = client.imports.get(promise.imported.export_id).?;
    switch (promise_import.resolved) {
        .none => return error.ResolveNotHandled,
        else => {},
    }

    var queued_response = try pending.wait();
    defer queued_response.deinit();

    const payload = try queued_response.payload();
    try testing.expectEqualStrings("after-resolve", try (try payload.content()).asText());
}

test "pipelined call on an answer queued behind a promise" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

    const provider = try client.bootstrap();
    defer provider.release();

    // Obtain a promise export from the server.
    var promise_request = try client.beginCall(provider, ProviderInterface.id, 2);
    defer promise_request.deinit();
    var promise_response = try promise_request.send();
    defer promise_response.deinit();
    const promise = try promise_response.capability(0);
    defer promise.release();

    // This call queues on the unresolved promise, creating a placeholder
    // answer entry on the server.
    var queued_request = try client.beginCall(promise, ProviderInterface.id, 0);
    defer queued_request.deinit();
    var queued_pending = try queued_request.start();
    defer queued_pending.deinit();

    // Pipeline a call on the queued call's result before the server has been
    // able to produce it.
    const answer_cap = try queued_pending.capability(null);
    defer answer_cap.release();
    var pipelined_request = try client.beginCall(answer_cap, EchoInterface.id, 0);
    defer pipelined_request.deinit();
    var pipelined_params = try pipelined_request.params();
    try pipelined_params.content().setText("pipelined-behind-promise");
    var pipelined_pending = try pipelined_request.start();
    defer pipelined_pending.deinit();

    const resolved = try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    });
    defer resolved.release();
    try server.resolvePromise(state.promise.?, resolved);

    var pipelined_response = try pipelined_pending.wait();
    defer pipelined_response.deinit();
    const pipelined_payload = try pipelined_response.payload();
    try testing.expectEqualStrings(
        "pipelined-behind-promise",
        try (try pipelined_payload.content()).asText(),
    );

    var queued_response = try queued_pending.wait();
    defer queued_response.deinit();
}

test "pipelining through a promise result before it resolves" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

    const provider = try client.bootstrap();
    defer provider.release();

    // This call's result is itself a promise export.
    var request = try client.beginCall(provider, ProviderInterface.id, 2);
    defer request.deinit();
    var pending = try request.start();
    defer pending.deinit();

    // Pipeline on the result before that promise is resolved.
    const answer_cap = try pending.capability(null);
    defer answer_cap.release();
    var pipelined_request = try client.beginCall(answer_cap, EchoInterface.id, 0);
    defer pipelined_request.deinit();
    var pipelined_params = try pipelined_request.params();
    try pipelined_params.content().setText("through-promise-result");
    var pipelined_pending = try pipelined_request.start();
    defer pipelined_pending.deinit();

    const resolved = try server.initLocal(state.echo);
    defer resolved.release();
    try server.resolvePromise(state.promise.?, resolved);

    var pipelined_response = try pipelined_pending.wait();
    defer pipelined_response.deinit();
    const pipelined_payload = try pipelined_response.payload();
    try testing.expectEqualStrings(
        "through-promise-result",
        try (try pipelined_payload.content()).asText(),
    );

    var response = try pending.wait();
    defer response.deinit();
}

test "receiverAnswer queued behind a promise dispatches locally once resolved" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

    const provider = try client.bootstrap();
    defer provider.release();

    var promise_request = try client.beginCall(provider, ProviderInterface.id, 2);
    defer promise_request.deinit();
    var promise_response = try promise_request.send();
    defer promise_response.deinit();
    const promise = try promise_response.capability(0);
    defer promise.release();

    // Queue a call behind the promise. Its answer is not available yet.
    var queued_request = try client.beginCall(promise, ProviderInterface.id, 0);
    defer queued_request.deinit();
    var queued_pending = try queued_request.start();
    defer queued_pending.deinit();

    // Pass the promised answer back as a parameter. The server stores the
    // unresolved handle instead of dispatching it over the wire.
    const answer_cap = try queued_pending.capability(null);
    defer answer_cap.release();
    var store_request = try client.beginCall(provider, ProviderInterface.id, 6);
    defer store_request.deinit();
    const index = try store_request.addCapability(answer_cap);
    var store_params = try store_request.params();
    store_params.content().setCapability(index);
    var store_response = try store_request.send();
    defer store_response.deinit();
    const store_payload = try store_response.payload();
    try testing.expectEqualStrings("stored", try (try store_payload.content()).asText());

    const stored = state.stored orelse return error.MissingStoredCapability;
    defer {
        stored.release();
        state.stored = null;
    }

    // Before the answer resolves, the capability cannot dispatch locally yet;
    // it must not fall back to sending a wrongly-addressed wire call.
    try testing.expectError(error.AnswerNotReady, server.beginCall(stored, EchoInterface.id, 0));

    const resolved = try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    });
    defer resolved.release();
    try server.resolvePromise(state.promise.?, resolved);

    // The answer is now resolved, so the previously unresolved handle must
    // dispatch locally rather than sending a promisedAnswer message.
    var local_request = try server.beginCall(stored, EchoInterface.id, 0);
    defer local_request.deinit();
    var local_params = try local_request.params();
    try local_params.content().setText("local-answer");
    var local_response = try local_request.send();
    defer local_response.deinit();
    const local_payload = try local_response.payload();
    try testing.expectEqualStrings("local-answer", try (try local_payload.content()).asText());

    var queued_response = try queued_pending.wait();
    defer queued_response.deinit();
}

test "resolved promise routes calls to a locally hosted capability" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

    const provider = try client.bootstrap();
    defer provider.release();

    var promise_request = try client.beginCall(provider, ProviderInterface.id, 2);
    defer promise_request.deinit();
    var promise_response = try promise_request.send();
    defer promise_response.deinit();
    const promise = try promise_response.capability(0);
    defer promise.release();

    // Resolve the server's promise to a capability hosted by the client.
    var resolve_request = try client.beginCall(provider, ProviderInterface.id, 7);
    defer resolve_request.deinit();
    const index = try resolve_request.addLocalCapability(.{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    });
    var resolve_params = try resolve_request.params();
    resolve_params.content().setCapability(index);
    var resolve_response = try resolve_request.send();
    defer resolve_response.deinit();
    const resolve_payload = try resolve_response.payload();
    try testing.expectEqualStrings("resolved-to-param", try (try resolve_payload.content()).asText());

    const promise_import = client.imports.get(promise.imported.export_id).?;
    switch (promise_import.resolved) {
        .local => {},
        else => return error.ResolveNotRoutedLocally,
    }

    // A call on the promise must now dispatch on the client's local object,
    // not make a round trip to the server.
    var echo_request = try client.beginCall(promise, EchoInterface.id, 0);
    defer echo_request.deinit();
    var echo_params = try echo_request.params();
    try echo_params.content().setText("local-reflection");
    var echo_response = try echo_request.send();
    defer echo_response.deinit();
    const echo_payload = try echo_response.payload();
    try testing.expectEqualStrings("local-reflection", try (try echo_payload.content()).asText());
}

test "send failure releases its question" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    const client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    server.setBootstrap(try server.initLocal(.{
        .context = null,
        .interface_id = TestInterface.id,
        .dispatch = TestInterface.dispatch,
    }));

    const provider = try client.bootstrap();
    defer provider.release();

    // Remove the progress source so waitReturn fails instead of blocking.
    client.peer = null;

    var request = try client.beginCall(provider, TestInterface.id, 0);
    defer request.deinit();
    try testing.expectError(error.NoWaitSource, request.send());
    try testing.expectEqual(@as(usize, 0), client.questions.count());
}

test "bootstrap wait failure releases its question" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const conn = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer conn.deinit();

    var promise = try conn.bootstrapStart();
    try testing.expectError(error.NoWaitSource, promise.wait());
    try testing.expectEqual(@as(usize, 0), conn.questions.count());
}

test "unsupported messages abort the connection" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    const client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    var message = capnp.MessageBuilder{ .allocator = testing.allocator };
    try message.init();
    defer message.deinit();

    var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
    _ = try root.setUnimplemented();

    const bytes = try message.toBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    // The loopback transport always sends to the opposite side, so send from
    // the server to deliver the message to the client.
    try server.transport.send(bytes);

    try testing.expectError(error.UnsupportedMessage, client.step());
    try testing.expect(client.isClosed());
    try testing.expectError(error.EndOfStream, client.step());

    // The client must have sent an Abort to the peer.
    try testing.expectError(error.ConnectionAborted, server.step());
    try testing.expect(server.isClosed());
}

test "connection deinit frees outstanding question param exports" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    const client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    server.setBootstrap(try server.initLocal(.{
        .context = null,
        .interface_id = TestInterface.id,
        .dispatch = TestInterface.dispatch,
    }));

    const provider = try client.bootstrap();
    defer provider.release();

    var request = try client.beginCall(provider, TestInterface.id, 0);
    defer request.deinit();
    const index = try request.addLocalCapability(.{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    });
    var params = try request.params();
    params.content().setCapability(index);

    // Leave the question outstanding so Connection.deinit must clean up the
    // question's param export bookkeeping itself.
    _ = try request.start();
}

test "disembargo loopback echo" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

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

test "receiverAnswer descriptor resolves against the answer table" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

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
    defer response.deinit();

    const payload = try response.payload();
    try testing.expectEqualStrings("local-answer", try (try payload.content()).asText());

    var initial_response = try pending.wait();
    defer initial_response.deinit();
}

test "local capability call" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var conn = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer conn.deinit();

    const local_echo = connection.LocalCapability{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    };

    const local_cap = try conn.initLocal(local_echo);
    defer local_cap.release();
    var request = try conn.beginCall(local_cap, EchoInterface.id, 0);
    defer request.deinit();
    var params = try request.params();
    try params.content().setText("local");
    var response = try request.send();
    defer response.deinit();

    const payload = try response.payload();
    try testing.expectEqualStrings("local", try (try payload.content()).asText());
}

test "pipelined capability parameter is deferred and called locally" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = PipelineInterface.id,
        .dispatch = PipelineInterface.dispatch,
    }));

    const provider = try client.bootstrap();

    const client_echo = connection.LocalCapability{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    };

    var first_request = try client.beginCall(provider, PipelineInterface.id, 0);
    defer first_request.deinit();
    const first_cap = try first_request.addLocalCapability(client_echo);
    var first_params = try first_request.params();
    first_params.content().setCapability(first_cap);

    var pending = try first_request.start();

    var second_request = try client.beginCall(provider, PipelineInterface.id, 1);
    defer second_request.deinit();
    const second_promise_cap = try pending.capability(null);
    defer second_promise_cap.release();
    const second_cap = try second_request.addCapability(second_promise_cap);
    var second_params = try second_request.params();
    second_params.content().setCapability(second_cap);

    var second_response = try second_request.send();
    defer second_response.deinit();

    const second_payload = try second_response.payload();
    try testing.expectEqualStrings("pipelined", try (try second_payload.content()).asText());

    var first_response = try pending.wait();
    defer first_response.deinit();
}

const DestroyCounter = struct {
    count: usize = 0,
};

fn countDestroy(context: *anyopaque) void {
    const counter: *DestroyCounter = @ptrCast(@alignCast(context));
    counter.count += 1;
}

test "local capability handles intern and destroy once" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var conn = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer conn.deinit();

    var destroyed = DestroyCounter{};
    const descriptor = connection.LocalCapability{
        .context = &destroyed,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
        .destroy = countDestroy,
    };

    const first = try conn.initLocal(descriptor);
    const second = try conn.initLocal(descriptor);
    try testing.expect(first.local == second.local);
    try testing.expectEqual(@as(u32, 2), first.local.refs);
    try testing.expectEqual(@as(usize, 0), destroyed.count);

    first.release();
    try testing.expectEqual(@as(u32, 1), second.local.refs);
    try testing.expectEqual(@as(usize, 0), destroyed.count);

    second.release();
    try testing.expectEqual(@as(usize, 1), destroyed.count);
    try testing.expectEqual(@as(usize, 0), conn.locals.count());
}

test "connection deinit destroys local bootstrap target" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var conn = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    var destroyed = DestroyCounter{};
    conn.setBootstrap(try conn.initLocal(.{
        .context = &destroyed,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
        .destroy = countDestroy,
    }));

    conn.deinit();
    try testing.expectEqual(@as(usize, 1), destroyed.count);
}

test "export reference counts and destroy after peer release" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var destroyed = DestroyCounter{};
    var state = ProviderState{ .echo = .{
        .context = &destroyed,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
        .destroy = countDestroy,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

    const provider = try client.bootstrap();
    defer provider.release();

    var first_request = try client.beginCall(provider, ProviderInterface.id, 0);
    defer first_request.deinit();
    var first_response = try first_request.send();
    defer first_response.deinit();
    const first_echo = try first_response.capability(0);

    var second_request = try client.beginCall(provider, ProviderInterface.id, 0);
    defer second_request.deinit();
    var second_response = try second_request.send();
    defer second_response.deinit();
    const second_echo = try second_response.capability(0);

    try testing.expectEqual(first_echo.imported.export_id, second_echo.imported.export_id);
    const export_entry = server.exports.get(first_echo.imported.export_id).?;
    try testing.expectEqual(@as(u32, 2), export_entry.wire_refs);
    try testing.expectEqual(@as(usize, 0), destroyed.count);

    first_echo.release();
    try testing.expect(server.exports.contains(first_echo.imported.export_id));
    try testing.expectEqual(@as(usize, 0), destroyed.count);

    second_echo.release();
    try testing.expect(!server.exports.contains(second_echo.imported.export_id));
    try testing.expectEqual(@as(usize, 1), destroyed.count);
}

test "finish with releaseResultCaps frees result exports" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var destroyed = DestroyCounter{};
    var state = ProviderState{ .echo = .{
        .context = &destroyed,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
        .destroy = countDestroy,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

    const provider = try client.bootstrap();
    defer provider.release();

    const exported_before = server.exports.count();

    var request = try client.beginCall(provider, ProviderInterface.id, 0);
    defer request.deinit();
    var response = try request.send();
    try testing.expectEqual(exported_before + 1, server.exports.count());

    // Do not take the result capability: Finish must release it implicitly.
    response.deinit();
    try testing.expectEqual(exported_before, server.exports.count());
    try testing.expectEqual(@as(usize, 1), destroyed.count);
}

test "taking a result capability defers its release to the handle" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var destroyed = DestroyCounter{};
    var state = ProviderState{ .echo = .{
        .context = &destroyed,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
        .destroy = countDestroy,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

    const provider = try client.bootstrap();
    defer provider.release();

    const exported_before = server.exports.count();

    var request = try client.beginCall(provider, ProviderInterface.id, 0);
    defer request.deinit();
    var response = try request.send();
    const echo = try response.capability(0);

    response.deinit();

    // Finish(false) keeps the export until the imported handle is released.
    try testing.expect(server.exports.contains(echo.imported.export_id));
    try testing.expectEqual(@as(usize, 0), destroyed.count);

    echo.release();
    try testing.expect(!server.exports.contains(echo.imported.export_id));
    try testing.expectEqual(exported_before, server.exports.count());
    try testing.expectEqual(@as(usize, 1), destroyed.count);
}

test "unsent promise handle release frees its export" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var conn = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer conn.deinit();

    const promise = try conn.newPromise();
    try testing.expectEqual(@as(usize, 1), conn.exports.count());

    promise.release();
    try testing.expectEqual(@as(usize, 0), conn.exports.count());
}

test "receiverHosted returns the owner's local capability" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

    var destroyed = DestroyCounter{};
    const echo_descriptor = connection.LocalCapability{
        .context = &destroyed,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
        .destroy = countDestroy,
    };
    const client_echo = try client.initLocal(echo_descriptor);

    const provider = try client.bootstrap();
    defer provider.release();

    var request = try client.beginCall(provider, ProviderInterface.id, 4);
    defer request.deinit();
    const cap_index = try request.addLocalCapability(echo_descriptor);
    var params = try request.params();
    params.content().setCapability(cap_index);

    var response = try request.send();
    const returned = try response.capability(0);

    try testing.expect(returned.local == client_echo.local);
    try testing.expect(client_echo.local.export_id != null);

    returned.release();
    try testing.expectEqual(@as(usize, 0), destroyed.count);

    response.deinit();
    try testing.expect(client_echo.local.export_id == null);

    client_echo.release();
    try testing.expectEqual(@as(usize, 1), destroyed.count);
}

test "local call returns a local capability handle" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var conn = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer conn.deinit();

    var destroyed = DestroyCounter{};
    var state = ProviderState{ .echo = .{
        .context = &destroyed,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
        .destroy = countDestroy,
    } };
    const provider = try conn.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    });
    defer provider.release();

    var request = try conn.beginCall(provider, ProviderInterface.id, 0);
    defer request.deinit();
    var response = try request.send();

    const echo = try response.capability(0);
    try testing.expect(echo == .local);
    echo.release();

    response.deinit();
    try testing.expectEqual(@as(usize, 1), destroyed.count);
}

test "pipelined call after wait keeps the answer alive" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    var server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    var client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

    const provider = try client.bootstrap();
    defer provider.release();

    var request = try client.beginCall(provider, ProviderInterface.id, 0);
    defer request.deinit();
    var pending = try request.start();
    const pipelined_echo = try pending.capability(null);
    defer pipelined_echo.release();

    var response = try pending.wait();
    defer response.deinit();

    // The answer must still be alive even though wait() has completed.
    var echo_request = try client.beginCall(pipelined_echo, EchoInterface.id, 0);
    defer echo_request.deinit();
    var echo_params = try echo_request.params();
    try echo_params.content().setText("late-pipeline");
    var echo_response = try echo_request.send();
    defer echo_response.deinit();

    const echo_payload = try echo_response.payload();
    try testing.expectEqualStrings("late-pipeline", try (try echo_payload.content()).asText());
}

test "local call passes a local capability parameter" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const conn = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer conn.deinit();

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    const provider = try conn.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    });
    defer provider.release();

    var request = try conn.beginCall(provider, ProviderInterface.id, 1);
    defer request.deinit();
    const cap_index = try request.addLocalCapability(.{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    });
    var params = try request.params();
    params.content().setCapability(cap_index);

    var response = try request.send();
    defer response.deinit();

    const payload = try response.payload();
    try testing.expectEqualStrings("from-client", try (try payload.content()).asText());
}

test "unused result capabilities are released" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    const client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var destroyed = DestroyCounter{};
    var state = ProviderState{ .echo = .{
        .context = &destroyed,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
        .destroy = countDestroy,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

    const provider = try client.bootstrap();
    defer provider.release();

    const exported_before = server.exports.count();

    var request = try client.beginCall(provider, ProviderInterface.id, 5);
    defer request.deinit();
    var response = try request.send();
    const echo = try response.capability(0);

    // Taking one result cap makes Finish keep all of them; the runtime must
    // still release the result caps the caller never decoded.
    response.deinit();
    try testing.expectEqual(exported_before + 1, server.exports.count());
    try testing.expectEqual(@as(usize, 0), destroyed.count);

    echo.release();
    try testing.expectEqual(exported_before, server.exports.count());
    try testing.expectEqual(@as(usize, 1), destroyed.count);
}

test "promise deinit releases its question" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const conn = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer conn.deinit();

    var promise = try conn.bootstrapStart();
    try testing.expectEqual(@as(usize, 1), conn.questions.count());
    promise.deinit();
    try testing.expectEqual(@as(usize, 0), conn.questions.count());
}

test "bootstrap result can be pipelined" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    const client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    server.setBootstrap(try server.initLocal(.{
        .context = null,
        .interface_id = TestInterface.id,
        .dispatch = TestInterface.dispatch,
    }));

    var bootstrap = try client.bootstrapStart();
    const pipelined = try bootstrap.capability();
    defer pipelined.release();

    var request = try client.beginCall(pipelined, TestInterface.id, 0);
    defer request.deinit();
    var params = try request.params();
    try params.content().setText("ping");

    var response = try request.send();
    defer response.deinit();
    const payload = try response.payload();
    try testing.expectEqualStrings("pong", try (try payload.content()).asText());

    const capability = try bootstrap.wait();
    capability.release();
}

test "releaseParamCaps from an early error releases client exports" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const server = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer server.deinit();

    const client = try connection.Connection.init(testing.allocator, loopback.endpoint(.client));
    defer client.deinit();

    client.peer = server;
    server.peer = client;

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    server.setBootstrap(try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    }));

    const provider = try client.bootstrap();
    defer provider.release();

    var request = try client.beginCall(provider, 0xdead_beef, 0);
    defer request.deinit();
    const cap_index = try request.addLocalCapability(.{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    });
    var params = try request.params();
    params.content().setCapability(cap_index);

    var response = try request.send();
    defer response.deinit();

    try testing.expectEqual(rpc.Return.Tag.exception, try response.which());
    // The callee never decoded the params, so its Return told us to release
    // the param export immediately.
    try testing.expectEqual(@as(usize, 0), client.exports.count());
}

test "promise deinit releases a local response" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const conn = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer conn.deinit();

    var destroyed = DestroyCounter{};
    var state = ProviderState{ .echo = .{
        .context = &destroyed,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
        .destroy = countDestroy,
    } };
    const provider = try conn.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    });
    defer provider.release();

    var request = try conn.beginCall(provider, ProviderInterface.id, 0);
    defer request.deinit();
    var promise = try request.start();
    promise.deinit();

    try testing.expectEqual(@as(usize, 1), destroyed.count);
}

test "lifecycle deinit is idempotent" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const conn = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer conn.deinit();

    const provider = try conn.initLocal(.{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    });
    defer provider.release();

    var request = try conn.beginCall(provider, EchoInterface.id, 0);
    var params = try request.params();
    try params.content().setText("idempotent");
    var response = try request.send();
    response.deinit();
    response.deinit();
    request.deinit();
    request.deinit();

    var unsent = try conn.beginCall(provider, EchoInterface.id, 0);
    unsent.deinit();
    unsent.deinit();

    var pending_request = try conn.beginCall(provider, EchoInterface.id, 0);
    var promise = try pending_request.start();
    promise.deinit();
    promise.deinit();
    pending_request.deinit();
    pending_request.deinit();
}

test "scripted transport: Finish cancels a call queued behind a promise" {
    var link = transports.Scripted.init(testing.allocator);
    defer link.deinit();

    const server = try connection.Connection.init(testing.allocator, link.endpoint(.server));
    defer server.deinit();

    const client = try connection.Connection.init(testing.allocator, link.endpoint(.client));
    defer client.deinit();

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    const provider = try scriptedBootstrap(server, client, &link, .{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    });
    defer provider.release();

    var promise_request = try client.beginCall(provider, ProviderInterface.id, 2);
    defer promise_request.deinit();
    var promise_pending = try promise_request.start();
    defer promise_pending.deinit();
    try scriptedPump(client, server, &link);
    var promise_response = try promise_pending.wait();
    defer promise_response.deinit();
    const promise = try promise_response.capability(0);
    defer promise.release();
    try scriptedPump(client, server, &link);

    var queued_request = try client.beginCall(promise, ProviderInterface.id, 0);
    defer queued_request.deinit();
    var queued_pending = try queued_request.start();

    // Deliver the call; it queues behind the unresolved promise.
    _ = try link.deliverNext(.client);
    try server.step();
    try testing.expectEqual(@as(usize, 0), state.calls);

    // Cancel the queued call before resolution.
    queued_pending.deinit();
    _ = try link.deliverNext(.client);
    try server.step();

    const resolved = try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    });
    defer resolved.release();
    try server.resolvePromise(state.promise.?, resolved);
    try scriptedPump(client, server, &link);

    try testing.expectEqual(@as(usize, 0), state.calls);
}

test "scripted transport: late Return is ignored after cancellation" {
    var link = transports.Scripted.init(testing.allocator);
    defer link.deinit();

    const server = try connection.Connection.init(testing.allocator, link.endpoint(.server));
    defer server.deinit();

    const client = try connection.Connection.init(testing.allocator, link.endpoint(.client));
    defer client.deinit();

    const provider = try scriptedBootstrap(server, client, &link, .{
        .context = null,
        .interface_id = TestInterface.id,
        .dispatch = TestInterface.dispatch,
    });
    defer provider.release();

    var request = try client.beginCall(provider, TestInterface.id, 0);
    defer request.deinit();
    var params = try request.params();
    try params.content().setText("ping");
    var pending = try request.start();

    _ = try link.deliverNext(.client);
    try server.step();
    try testing.expectEqual(@as(usize, 1), link.outboxLen(.server));

    pending.deinit();
    try testing.expectEqual(@as(usize, 0), client.questions.count());

    _ = try link.deliverNext(.server);
    try client.step();
    try testing.expectEqual(@as(usize, 0), client.returns.count());
}

test "scripted transport: duplicate questions and unknown exports are rejected" {
    var link = transports.Scripted.init(testing.allocator);
    defer link.deinit();

    const server = try connection.Connection.init(testing.allocator, link.endpoint(.server));
    defer server.deinit();

    const client = try connection.Connection.init(testing.allocator, link.endpoint(.client));
    defer client.deinit();

    const provider = try scriptedBootstrap(server, client, &link, .{
        .context = null,
        .interface_id = TestInterface.id,
        .dispatch = TestInterface.dispatch,
    });
    defer provider.release();

    var request = try client.beginCall(provider, TestInterface.id, 0);
    defer request.deinit();
    var params = try request.params();
    try params.content().setText("ping");
    var pending = try request.start();
    defer pending.deinit();

    const call_bytes = (try link.takeOutbox(.client)).?;
    defer testing.allocator.free(call_bytes);

    try link.pushInbox(.server, try testing.allocator.dupe(u8, call_bytes));
    try server.step();
    try link.pushInbox(.server, try testing.allocator.dupe(u8, call_bytes));
    try server.step();

    var exception_count: usize = 0;
    while (try link.takeOutbox(.server)) |bytes| {
        defer testing.allocator.free(bytes);
        if (try messageIsReturnException(bytes)) exception_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), exception_count);

    // An unknown imported capability id must also return an exception.
    var message = capnp.MessageBuilder{ .allocator = testing.allocator };
    try message.init();
    defer message.deinit();

    var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
    var call = try root.setCall();
    call.setQuestionId(0x1234);
    var target = try call.target();
    target.setImportedCap(0xdead);
    call.setInterfaceId(TestInterface.id);
    call.setMethodId(0);

    const unknown_bytes = try message.toBytes(testing.allocator);
    try link.pushInbox(.server, unknown_bytes);
    try server.step();

    const unknown_response = (try link.takeOutbox(.server)).?;
    defer testing.allocator.free(unknown_response);
    try testing.expect(try messageIsReturnException(unknown_response));
}

test "scripted transport: late Resolve after import release is harmless" {
    var link = transports.Scripted.init(testing.allocator);
    defer link.deinit();

    const server = try connection.Connection.init(testing.allocator, link.endpoint(.server));
    defer server.deinit();

    const client = try connection.Connection.init(testing.allocator, link.endpoint(.client));
    defer client.deinit();

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    const provider = try scriptedBootstrap(server, client, &link, .{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    });
    defer provider.release();

    var promise_request = try client.beginCall(provider, ProviderInterface.id, 2);
    defer promise_request.deinit();
    var promise_pending = try promise_request.start();
    defer promise_pending.deinit();
    try scriptedPump(client, server, &link);
    var promise_response = try promise_pending.wait();
    defer promise_response.deinit();
    const promise = try promise_response.capability(0);
    const promise_import_id = promise.imported.export_id;
    promise.release();
    try testing.expect(client.imports.get(promise_import_id) == null);

    // Deliver the Release, then resolve the export after the client forgot it.
    try scriptedPump(client, server, &link);

    const resolved = try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    });
    defer resolved.release();
    try server.resolvePromise(state.promise.?, resolved);
    try scriptedPump(client, server, &link);

    try testing.expect(client.imports.get(promise_import_id) == null);
}

test "scripted transport: pipelined calls survive explicit message ordering" {
    var link = transports.Scripted.init(testing.allocator);
    defer link.deinit();

    const server = try connection.Connection.init(testing.allocator, link.endpoint(.server));
    defer server.deinit();

    const client = try connection.Connection.init(testing.allocator, link.endpoint(.client));
    defer client.deinit();

    var state = ProviderState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    const provider = try scriptedBootstrap(server, client, &link, .{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    });
    defer provider.release();

    var promise_request = try client.beginCall(provider, ProviderInterface.id, 2);
    defer promise_request.deinit();
    var promise_pending = try promise_request.start();
    defer promise_pending.deinit();
    try scriptedPump(client, server, &link);
    var promise_response = try promise_pending.wait();
    defer promise_response.deinit();
    const promise = try promise_response.capability(0);
    defer promise.release();
    try scriptedPump(client, server, &link);

    var queued_request = try client.beginCall(promise, ProviderInterface.id, 0);
    defer queued_request.deinit();
    var queued_pending = try queued_request.start();
    _ = try link.deliverNext(.client);
    try server.step();

    const answer_cap = try queued_pending.capability(null);
    defer answer_cap.release();
    var pipelined_request = try client.beginCall(answer_cap, EchoInterface.id, 0);
    defer pipelined_request.deinit();
    var pipelined_params = try pipelined_request.params();
    try pipelined_params.content().setText("scripted-pipeline");
    var pipelined_pending = try pipelined_request.start();

    _ = try link.deliverNext(.client);
    try server.step();

    const resolved = try server.initLocal(.{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    });
    defer resolved.release();
    try server.resolvePromise(state.promise.?, resolved);
    try scriptedPump(client, server, &link);

    var pipelined_response = try pipelined_pending.wait();
    defer pipelined_response.deinit();
    const pipelined_payload = try pipelined_response.payload();
    try testing.expectEqualStrings(
        "scripted-pipeline",
        try (try pipelined_payload.content()).asText(),
    );

    var queued_response = try queued_pending.wait();
    defer queued_response.deinit();
    try testing.expectEqual(@as(usize, 1), state.calls);
}
