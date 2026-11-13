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

fn serializeMessage(message: capnp.MessageBuilder) ![]u8 {
    const size = try message.serializedSize();
    const bytes = try testing.allocator.alloc(u8, size);
    errdefer testing.allocator.free(bytes);
    _ = try message.writeToBuffer(bytes);
    return bytes;
}

fn buildResolve(promise_id: u32, target_id: u32) ![]u8 {
    var message = capnp.MessageBuilder{ .allocator = testing.allocator };
    try message.init();
    defer message.deinit();

    var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
    var resolve = try root.setResolve();
    resolve.setPromiseId(promise_id);
    const cap = try resolve.setCap();
    cap.setSenderPromise(target_id);

    return serializeMessage(message);
}

test "send failure releases its question" {
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

    server.setBootstrap(try server.initLocal(.{
        .context = null,
        .interface_id = TestInterface.id,
        .dispatch = TestInterface.dispatch,
    }));

    const provider = try client.bootstrap();
    defer provider.release();

    // Remove the progress source so waitReturn fails instead of blocking.
    client.setWaker(null);

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

    const bytes = try serializeMessage(message);
    defer testing.allocator.free(bytes);
    // The loopback transport always sends to the opposite side, so send from
    // the server to deliver the message to the client.
    try server.transport.send(.{ .header = bytes });

    try testing.expectError(error.UnsupportedMessage, client.step());
    try testing.expect(client.isClosed());
    try testing.expectError(error.EndOfStream, client.step());

    // The client must have sent an Abort to the peer.
    try testing.expectError(error.ConnectionAborted, server.step());
    try testing.expect(server.isClosed());
}

test "connection deinit frees outstanding question param exports" {
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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

    const unknown_bytes = try serializeMessage(message);
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

test "deep local call nesting" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const conn = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer conn.deinit();

    var state = support.RecursiveState{};
    const capability = try conn.initLocal(.{
        .context = &state,
        .interface_id = support.RecursiveInterface.id,
        .dispatch = support.RecursiveInterface.dispatch,
    });
    defer capability.release();
    state.capability = capability;

    var request = try conn.beginCall(capability, support.RecursiveInterface.id, 0);
    defer request.deinit();
    var params = try request.params();
    try params.content().setText("128");

    var response = try request.send();
    defer response.deinit();
    const payload = try response.payload();
    try testing.expectEqualStrings("done", try (try payload.content()).asText());
}

test "limit: cap table entries" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const conn = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer conn.deinit();
    conn.setLimits(.{ .max_cap_table_entries = 1 });

    const capability = try conn.initLocal(.{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    });
    defer capability.release();

    var request = try conn.beginCall(capability, EchoInterface.id, 0);
    defer request.deinit();

    _ = try request.addCapability(capability);
    try testing.expectError(error.CapTableLimitExceeded, request.addCapability(capability));
}

test "limit: live questions" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const conn = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer conn.deinit();
    conn.setLimits(.{ .max_live_questions = 1 });

    var first = try conn.bootstrapStart();
    defer first.deinit();

    try testing.expectError(error.QuestionLimitExceeded, conn.bootstrapStart());
}

test "limit: live exports" {
    var loopback = transports.Loopback.init(testing.allocator);
    defer loopback.deinit();

    const conn = try connection.Connection.init(testing.allocator, loopback.endpoint(.server));
    defer conn.deinit();
    conn.setLimits(.{ .max_live_exports = 0 });

    try testing.expectError(error.ExportLimitExceeded, conn.newPromise());
}

test "limit: live imports" {
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

    // The bootstrap import already occupies the single allowed slot.
    client.setLimits(.{ .max_live_imports = 1 });

    var request = try client.beginCall(provider, ProviderInterface.id, 0);
    var response = try request.send();
    defer response.deinit();

    try testing.expectError(error.ImportLimitExceeded, response.capability(0));
}

test "limit: live answers" {
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

    // The bootstrap answer is still live. Do not allow a second one.
    server.setLimits(.{ .max_live_answers = @intCast(server.answers.count()) });

    var request = try client.beginCall(provider, ProviderInterface.id, 0);
    defer request.deinit();
    var pending = try request.start();
    defer pending.deinit();

    _ = try link.deliverNext(.client);
    try testing.expectError(error.AnswerLimitExceeded, server.step());
    try testing.expect(server.isClosed());
}

test "protocol: oversized message aborts" {
    var link = transports.Scripted.init(testing.allocator);
    defer link.deinit();

    const conn = try connection.Connection.init(testing.allocator, link.endpoint(.client));
    defer conn.deinit();
    conn.setLimits(.{ .max_message_bytes = 8 });

    try link.inject(.client, "0123456789");
    try testing.expectError(error.MessageTooLarge, conn.step());
    try testing.expect(conn.isClosed());
}

test "protocol: self-referential Resolve aborts" {
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
    const promise_id = promise.imported.export_id;

    const resolve = try buildResolve(promise_id, promise_id);
    try link.pushInbox(.client, resolve);
    try testing.expectError(error.CyclicResolve, client.step());
    try testing.expect(client.isClosed());
}

test "protocol: cyclic Resolve chain aborts" {
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

    var first_request = try client.beginCall(provider, ProviderInterface.id, 2);
    defer first_request.deinit();
    var first_pending = try first_request.start();
    defer first_pending.deinit();
    try scriptedPump(client, server, &link);
    var first_response = try first_pending.wait();
    defer first_response.deinit();
    const first = try first_response.capability(0);
    defer first.release();

    var second_request = try client.beginCall(provider, ProviderInterface.id, 2);
    defer second_request.deinit();
    var second_pending = try second_request.start();
    defer second_pending.deinit();
    try scriptedPump(client, server, &link);
    var second_response = try second_pending.wait();
    defer second_response.deinit();
    const second = try second_response.capability(0);
    defer second.release();

    const first_id = first.imported.export_id;
    const second_id = second.imported.export_id;

    const resolve_first = try buildResolve(first_id, second_id);
    try link.pushInbox(.client, resolve_first);
    const resolve_second = try buildResolve(second_id, first_id);
    try link.pushInbox(.client, resolve_second);

    try testing.expectError(error.CyclicResolve, client.step());
    try testing.expect(client.isClosed());
}

test "limit: pending calls on a promise" {
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

    server.setLimits(.{ .max_pending_calls_per_promise = 0 });

    var queued_request = try client.beginCall(promise, ProviderInterface.id, 0);
    defer queued_request.deinit();
    var queued_pending = try queued_request.start();
    defer queued_pending.deinit();

    _ = try link.deliverNext(.client);
    try testing.expectError(error.PendingCallLimitExceeded, server.step());
    try testing.expect(server.isClosed());
}

test "teardown with outstanding questions, answers, and returns" {
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

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var request = try client.beginCall(provider, ProviderInterface.id, 0);
        _ = try request.start();
        request.deinit();
    }

    try pair.pump();

    try testing.expectEqual(@as(usize, 3), client.questions.count());
    try testing.expectEqual(@as(usize, 3), client.returns.count());
    try testing.expectEqual(@as(usize, 3), server.answers.count());
}
