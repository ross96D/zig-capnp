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

test "level 0 bootstrap, call, return, and finish" {
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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
    const pair = try driver.LoopbackPair.init(testing.allocator);
    defer pair.deinit();

    const server = pair.server;
    const client = pair.client;

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
