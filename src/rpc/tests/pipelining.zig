const std = @import("std");
const capnp = @import("capnp");
const rpc = @import("../generated/rpc.zig");
const connection = @import("../connection.zig");
const transports = @import("../transports/mod.zig");
const support = @import("support.zig");
const driver = @import("../driver.zig");
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

test "promise pipelining against a returned capability" {
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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
    try pair.pump();

    const resolved_target = try server.initLocal(state.echo);
    defer resolved_target.release();
    try server.resolvePromise(state.promise.?, resolved_target);
    try pair.pump();

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
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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
    try pair.pump();

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
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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
    try pair.pump();

    // Pipeline on the result before that promise is resolved.
    const answer_cap = try pending.capability(null);
    defer answer_cap.release();
    var pipelined_request = try client.beginCall(answer_cap, EchoInterface.id, 0);
    defer pipelined_request.deinit();
    var pipelined_params = try pipelined_request.params();
    try pipelined_params.content().setText("through-promise-result");
    var pipelined_pending = try pipelined_request.start();
    defer pipelined_pending.deinit();
    try pair.pump();

    const resolved = try server.initLocal(state.echo);
    defer resolved.release();
    try server.resolvePromise(state.promise.?, resolved);
    try pair.pump();

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
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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

test "pipelined capability parameter is deferred and called locally" {
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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

test "pipelined call after wait keeps the answer alive" {
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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

test "bootstrap result can be pipelined" {
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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
