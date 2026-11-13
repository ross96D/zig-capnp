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

test "level 1 returned capability and release" {
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

test "disembargo loopback echo" {
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

    var seen: u32 = 0;
    client.setDisembargoCallback(.{ .context = &seen, .function = recordDisembargo });
    try client.sendDisembargoLoopback(provider, 42);
    try pair.pump();
    try testing.expectEqual(@as(u32, 42), seen);
}

test "receiverAnswer descriptor resolves against the answer table" {
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
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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
    try pair.pump();
    try testing.expect(server.exports.contains(first_echo.imported.export_id));
    try testing.expectEqual(@as(usize, 0), destroyed.count);

    second_echo.release();
    try pair.pump();
    try testing.expect(!server.exports.contains(second_echo.imported.export_id));
    try testing.expectEqual(@as(usize, 1), destroyed.count);
}

test "finish with releaseResultCaps frees result exports" {
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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
    try pair.pump();
    try testing.expectEqual(exported_before, server.exports.count());
    try testing.expectEqual(@as(usize, 1), destroyed.count);
}

test "taking a result capability defers its release to the handle" {
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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
    try pair.pump();

    // Finish(false) keeps the export until the imported handle is released.
    try testing.expect(server.exports.contains(echo.imported.export_id));
    try testing.expectEqual(@as(usize, 0), destroyed.count);

    echo.release();
    try pair.pump();
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
    try pair.pump();
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
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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
    try pair.pump();
    try testing.expectEqual(exported_before + 1, server.exports.count());
    try testing.expectEqual(@as(usize, 0), destroyed.count);

    echo.release();
    try pair.pump();
    try testing.expectEqual(exported_before, server.exports.count());
    try testing.expectEqual(@as(usize, 1), destroyed.count);
}

test "releaseParamCaps from an early error releases client exports" {
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
