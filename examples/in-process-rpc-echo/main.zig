const std = @import("std");
const capnp_rpc = @import("capnp_rpc");
const echo_schema = @import("generated/echo.zig");

const EchoServer = struct {
    server_name: [:0]const u8 = "not_set",

    fn echo(
        self_: *anyopaque,
        params: echo_schema.Echo.EchoParams.Reader,
        results: echo_schema.Echo.EchoResults.Builder,
        _: capnp_rpc.Call,
    ) anyerror!void {
        const self: *EchoServer = @ptrCast(@alignCast(self_));
        var buffer: [500]u8 = undefined;
        const printed = try std.mem.printSentinel(&buffer, "{s} - {s}", .{ self.server_name, try params.text() }, 0);
        try results.setText(printed);
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const pair = try capnp_rpc.driver.LoopbackPair.init(allocator);
    defer pair.deinit();

    const server_connection = pair.server;
    const client_connection = pair.client;

    var server_impl_1 = EchoServer{ .server_name = "server 1" };
    var server_impl_no_named = EchoServer{};

    var server_1 = echo_schema.Echo.Server{
        .context = @ptrCast(&server_impl_1),
        .vtable = .{ .echo = EchoServer.echo },
    };
    var server_no_named = echo_schema.Echo.Server{
        .context = @ptrCast(&server_impl_no_named),
        .vtable = .{ .echo = EchoServer.echo },
    };

    {
        server_connection.setBootstrap(try server_connection.initLocal(server_1.localCapability()));

        const capability = try client_connection.bootstrap();
        var client = echo_schema.Echo.Client.fromCapability(capability);
        defer client.deinit();

        var request = try client.echo();
        defer request.deinit();

        var params = try request.params();
        try params.setText("hello from Cap'n Proto RPC - 1");

        var response = try request.send();
        defer response.deinit();

        const results = try response.results(
            echo_schema.Echo.EchoResults.Reader,
            echo_schema.Echo.EchoResults.reader_trait,
        );
        std.debug.print("RPC echoed: {s}\n", .{try results.text()});
    }

    {
        server_connection.setBootstrap(try server_connection.initLocal(server_no_named.localCapability()));

        const capability = try client_connection.bootstrap();
        var client = echo_schema.Echo.Client.fromCapability(capability);
        defer client.deinit();

        var request = try client.echo();
        defer request.deinit();

        var params = try request.params();
        try params.setText("hello from Cap'n Proto RPC - no_named");

        var response = try request.send();
        defer response.deinit();

        const results = try response.results(
            echo_schema.Echo.EchoResults.Reader,
            echo_schema.Echo.EchoResults.reader_trait,
        );
        std.debug.print("RPC echoed: {s}\n", .{try results.text()});
    }
}
