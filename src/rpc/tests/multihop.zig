const std = @import("std");
const connection = @import("../connection.zig");
const transports = @import("../transports/mod.zig");
const support = @import("support.zig");
const testing = std.testing;

const EchoInterface = support.EchoInterface;
const ProviderInterface = support.ProviderInterface;
const ProviderState = support.ProviderState;
const scriptedPump = support.scriptedPump;
const scriptedBootstrap = support.scriptedBootstrap;
const callTargetImportedCap = support.callTargetImportedCap;
const messageIsCall = support.messageIsCall;

const OrderState = struct {
    bytes: [8]u8 = undefined,
    len: usize = 0,
};

const OrderInterface = struct {
    pub const id: u64 = 0x7a4c9e1d3b8f6024;

    fn dispatch(context: *anyopaque, method_id: u16, call: connection.Call) anyerror!void {
        if (method_id != 0) return error.MethodNotFound;
        const state: *OrderState = @ptrCast(@alignCast(context));
        const text = try call.params.asText();
        for (text) |ch| {
            if (state.len >= state.bytes.len) break;
            state.bytes[state.len] = ch;
            state.len += 1;
        }
        try call.results.setText(text);
    }
};

fn obtainPromiseImport(
    client: *connection.Connection,
    server: *connection.Connection,
    link: *transports.Scripted,
    provider: connection.Capability,
) !connection.Capability {
    var request = try client.beginCall(provider, ProviderInterface.id, 2);
    defer request.deinit();

    var pending = try request.start();
    defer pending.deinit();
    try scriptedPump(client, server, link);

    var response = try pending.wait();
    const promise = try response.capability(0);
    errdefer promise.release();

    response.deinit();
    try scriptedPump(client, server, link);
    return promise;
}

fn obtainEchoImport(
    client: *connection.Connection,
    server: *connection.Connection,
    link: *transports.Scripted,
    provider: connection.Capability,
) !connection.Capability {
    var request = try client.beginCall(provider, ProviderInterface.id, 0);
    defer request.deinit();

    var pending = try request.start();
    defer pending.deinit();
    try scriptedPump(client, server, link);

    var response = try pending.wait();
    const capability = try response.capability(0);
    errdefer capability.release();

    response.deinit();
    try scriptedPump(client, server, link);
    return capability;
}

fn outboxContainsCallTarget(
    link: *transports.Scripted,
    side: transports.Side,
    target: u32,
) !bool {
    var index: usize = 0;
    while (link.peekOutbox(side, index)) |bytes| : (index += 1) {
        if (!try messageIsCall(bytes)) continue;
        if (try callTargetImportedCap(bytes) == target) return true;
    }
    return false;
}

test "strict forwarding through a resolved promise chain" {
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

    const promise = try obtainPromiseImport(client, server, &link, provider);
    defer promise.release();

    // R is a promise hosted by the client. Resolving the server's P to R
    // crosses the wire as a receiverHosted descriptor.
    const promise_r = try client.newPromise();
    defer promise_r.release();

    var resolve_request = try client.beginCall(provider, ProviderInterface.id, 7);
    defer resolve_request.deinit();
    _ = try resolve_request.addCapability(promise_r);
    var resolve_pending = try resolve_request.start();
    defer resolve_pending.deinit();

    try scriptedPump(client, server, &link);
    var resolve_response = try resolve_pending.wait();
    defer resolve_response.deinit();
    try scriptedPump(client, server, &link);

    // Q is hosted by the server and is the eventual target of R.
    const promise_q = try obtainEchoImport(client, server, &link, provider);
    defer promise_q.release();

    try client.resolvePromise(promise_r, promise_q);
    try scriptedPump(client, server, &link);

    // The server must have accepted R -> Q as a local resolution.
    const r_import = server.imports.get(promise_r.promised.export_id) orelse
        return error.MissingImport;
    switch (r_import.resolved) {
        .local => {},
        else => return error.ExpectedLocalResolution,
    }

    const promise_id = promise.imported.export_id;
    const promise_r_id = promise_r.promised.export_id;

    var request = try client.beginCall(promise, EchoInterface.id, 0);
    defer request.deinit();
    var params = try request.params();
    try params.content().setText("strict-forwarding");
    var pending = try request.start();
    defer pending.deinit();

    // The client still addresses P, not its resolution R or R's target Q.
    const client_message = link.peekOutbox(.client, 0) orelse return error.MissingCall;
    try testing.expectEqual(promise_id, try callTargetImportedCap(client_message));

    try testing.expect(try link.deliverNext(.client));
    try server.step();

    // The server must forward to R even though R has resolved to Q locally.
    try testing.expect(try outboxContainsCallTarget(&link, .server, promise_r_id));

    try testing.expect(try link.deliverNext(.server));
    try client.step();

    // The client's promise R forwards onward to Q.
    try testing.expect(try outboxContainsCallTarget(
        &link,
        .client,
        promise_q.imported.export_id,
    ));

    try scriptedPump(client, server, &link);

    var response = try pending.wait();
    defer response.deinit();
    const payload = try response.payload();
    try testing.expectEqualStrings("strict-forwarding", try (try payload.content()).asText());
}

test "multi-hop resolution preserves E-order" {
    var link = transports.Scripted.init(testing.allocator);
    defer link.deinit();

    const server = try connection.Connection.init(testing.allocator, link.endpoint(.server));
    defer server.deinit();

    const client = try connection.Connection.init(testing.allocator, link.endpoint(.client));
    defer client.deinit();

    var order = OrderState{};
    var state = ProviderState{ .echo = .{
        .context = &order,
        .interface_id = OrderInterface.id,
        .dispatch = OrderInterface.dispatch,
    } };
    const provider = try scriptedBootstrap(server, client, &link, .{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    });
    defer provider.release();

    const promise = try obtainPromiseImport(client, server, &link, provider);
    defer promise.release();

    const promise_r = try client.newPromise();
    defer promise_r.release();

    var resolve_request = try client.beginCall(provider, ProviderInterface.id, 7);
    defer resolve_request.deinit();
    _ = try resolve_request.addCapability(promise_r);
    var resolve_pending = try resolve_request.start();
    defer resolve_pending.deinit();

    try scriptedPump(client, server, &link);
    var resolve_response = try resolve_pending.wait();
    defer resolve_response.deinit();
    try scriptedPump(client, server, &link);

    const promise_q = try obtainEchoImport(client, server, &link, provider);
    defer promise_q.release();

    const promise_r_id = promise_r.promised.export_id;

    // foo is sent while R is still unresolved. It travels P -> R and queues on
    // the client's R export.
    var foo_request = try client.beginCall(promise, OrderInterface.id, 0);
    defer foo_request.deinit();
    var foo_params = try foo_request.params();
    try foo_params.content().setText("foo");
    var foo_pending = try foo_request.start();
    defer foo_pending.deinit();

    try testing.expect(try link.deliverNext(.client));
    try server.step();
    try testing.expect(try outboxContainsCallTarget(&link, .server, promise_r_id));

    try testing.expect(try link.deliverNext(.server));
    try client.step();

    // Resolving R to Q flushes the queued foo call. bar is issued afterwards
    // and must still go through P -> R before reaching Q.
    try client.resolvePromise(promise_r, promise_q);

    var bar_request = try client.beginCall(promise, OrderInterface.id, 0);
    defer bar_request.deinit();
    var bar_params = try bar_request.params();
    try bar_params.content().setText("bar");
    var bar_pending = try bar_request.start();
    defer bar_pending.deinit();

    _ = try link.deliverAll(.client);
    try server.step();

    // bar must be forwarded to R, not dispatched directly against Q.
    try testing.expect(try outboxContainsCallTarget(&link, .server, promise_r_id));

    try scriptedPump(client, server, &link);

    var foo_response = try foo_pending.wait();
    defer foo_response.deinit();
    var bar_response = try bar_pending.wait();
    defer bar_response.deinit();

    try testing.expectEqual(@as(usize, 6), order.len);
    try testing.expectEqualStrings("foobar", order.bytes[0..order.len]);
}

test "pipelined answer keeps promise identity across a resolution chain" {
    var link = transports.Scripted.init(testing.allocator);
    defer link.deinit();

    const server = try connection.Connection.init(testing.allocator, link.endpoint(.server));
    defer server.deinit();

    const client = try connection.Connection.init(testing.allocator, link.endpoint(.client));
    defer client.deinit();

    var order = OrderState{};
    var state = ProviderState{ .echo = .{
        .context = &order,
        .interface_id = OrderInterface.id,
        .dispatch = OrderInterface.dispatch,
    } };
    const provider = try scriptedBootstrap(server, client, &link, .{
        .context = &state,
        .interface_id = ProviderInterface.id,
        .dispatch = ProviderInterface.dispatch,
    });
    defer provider.release();

    // P is obtained through a Return, then pipelined on.
    var request = try client.beginCall(provider, ProviderInterface.id, 2);
    defer request.deinit();
    var pending = try request.start();
    defer pending.deinit();

    const answer_capability = try pending.capability(null);
    defer answer_capability.release();

    try scriptedPump(client, server, &link);
    var response = try pending.wait();
    defer response.deinit();

    const promise = try response.capability(0);
    defer promise.release();
    try scriptedPump(client, server, &link);

    // R is another server promise, and Q is a server-local object.
    const promise_r = try server.newPromise();
    defer promise_r.release();
    try server.resolvePromise(state.promise.?, promise_r);
    try scriptedPump(client, server, &link);

    const promise_q = try server.initLocal(.{
        .context = &order,
        .interface_id = OrderInterface.id,
        .dispatch = OrderInterface.dispatch,
    });
    defer promise_q.release();
    try server.resolvePromise(promise_r, promise_q);
    try scriptedPump(client, server, &link);

    // Neither side may flatten P to R's target. P still names R, and R still
    // names Q.
    const promise_import = client.imports.get(promise.imported.export_id) orelse
        return error.MissingImport;
    switch (promise_import.resolved) {
        .imported => |resolved| {
            try testing.expectEqual(promise_r.promised.export_id, resolved.export_id);
        },
        else => return error.ExpectedImportedResolution,
    }

    const r_import = client.imports.get(promise_r.promised.export_id) orelse
        return error.MissingImport;
    switch (r_import.resolved) {
        .imported => {},
        else => return error.ExpectedImportedResolution,
    }

    const promise_export = server.exports.get(state.promise.?.promised.export_id) orelse
        return error.MissingExport;
    switch (promise_export.capability) {
        .promised => |resolved| try testing.expect(resolved == promise_r.promised),
        else => return error.PromiseFlattened,
    }

    var pipelined_request = try client.beginCall(answer_capability, OrderInterface.id, 0);
    defer pipelined_request.deinit();
    var pipelined_params = try pipelined_request.params();
    try pipelined_params.content().setText("chain");
    var pipelined_pending = try pipelined_request.start();
    defer pipelined_pending.deinit();

    try scriptedPump(client, server, &link);

    var pipelined_response = try pipelined_pending.wait();
    defer pipelined_response.deinit();
    const payload = try pipelined_response.payload();
    try testing.expectEqualStrings("chain", try (try payload.content()).asText());

    try testing.expectEqual(@as(usize, 5), order.len);
    try testing.expectEqualStrings("chain", order.bytes[0..order.len]);
}
