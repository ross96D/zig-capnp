const std = @import("std");
const capnp_rpc = @import("capnp_rpc");
const schema = @import("generated/services.zig");
const int_expr = @import("int_expr.zig");

const socket_path = "/tmp/zig-capnp-rpc-pipeline.sock";

const GreeterImpl = struct {
    fn hello(
        _: *anyopaque,
        params: schema.Greeter.HelloParams.Reader,
        results: schema.Greeter.HelloResults.Builder,
        _: capnp_rpc.Call,
    ) anyerror!void {
        var buffer: [128]u8 = undefined;
        const message = try std.fmt.bufPrintSentinel(&buffer, "Hello, {s}!", .{try params.name()}, 0);
        try results.setMessage(message);
    }

    fn farewell(
        _: *anyopaque,
        params: schema.Greeter.FarewellParams.Reader,
        results: schema.Greeter.FarewellResults.Builder,
        _: capnp_rpc.Call,
    ) anyerror!void {
        var buffer: [128]u8 = undefined;
        const message = try std.fmt.bufPrintSentinel(&buffer, "Goodbye, {s}.", .{try params.name()}, 0);
        try results.setMessage(message);
    }
};

const CalculatorState = struct {
    allocator: std.mem.Allocator,
};

const CalculatorImpl = struct {
    fn add(
        context: *anyopaque,
        params: schema.Calculator.AddParams.Reader,
        results: schema.Calculator.AddResults.Builder,
        call: capnp_rpc.Call,
    ) anyerror!void {
        const state: *CalculatorState = @ptrCast(@alignCast(context));
        const a = try int_expr.IntExpr.evalCapability(
            call.connection,
            try int_expr.capabilityForParam(call, try params.a()),
        );
        const b = try int_expr.IntExpr.evalCapability(
            call.connection,
            try int_expr.capabilityForParam(call, try params.b()),
        );
        const result = try int_expr.IntExpr.init(state.allocator, a + b);
        const index = try call.addLocalResultCapability(result.capability());
        results.result().setCapability(index);
    }

    fn multiply(
        context: *anyopaque,
        params: schema.Calculator.MultiplyParams.Reader,
        results: schema.Calculator.MultiplyResults.Builder,
        call: capnp_rpc.Call,
    ) anyerror!void {
        const state: *CalculatorState = @ptrCast(@alignCast(context));
        const a = try int_expr.IntExpr.evalCapability(
            call.connection,
            try int_expr.capabilityForParam(call, try params.a()),
        );
        const b = try int_expr.IntExpr.evalCapability(
            call.connection,
            try int_expr.capabilityForParam(call, try params.b()),
        );
        const result = try int_expr.IntExpr.init(state.allocator, a * b);
        const index = try call.addLocalResultCapability(result.capability());
        results.result().setCapability(index);
    }
};

const Services = struct {
    greeter: capnp_rpc.LocalCapability,
    calculator: capnp_rpc.LocalCapability,
};

const FactoryImpl = struct {
    fn getGreeter(
        context: *anyopaque,
        _: schema.Factory.GetGreeterParams.Reader,
        results: schema.Factory.GetGreeterResults.Builder,
        call: capnp_rpc.Call,
    ) anyerror!void {
        const services: *Services = @ptrCast(@alignCast(context));
        const index = try call.addLocalResultCapability(services.greeter);
        results.greeter().setCapability(index);
    }

    fn getCalculator(
        context: *anyopaque,
        _: schema.Factory.GetCalculatorParams.Reader,
        results: schema.Factory.GetCalculatorResults.Builder,
        call: capnp_rpc.Call,
    ) anyerror!void {
        const services: *Services = @ptrCast(@alignCast(context));
        const index = try call.addLocalResultCapability(services.calculator);
        results.calculator().setCapability(index);
    }

    fn version(
        _: *anyopaque,
        _: schema.Factory.VersionParams.Reader,
        results: schema.Factory.VersionResults.Builder,
        _: capnp_rpc.Call,
    ) anyerror!void {
        try results.setVersion("pipeline-demo v1");
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var listener = try capnp_rpc.transports.Unix.Listener.listen(allocator, socket_path, .{
        .unlink_existing = true,
    });
    defer listener.deinit();

    std.debug.print("listening on {s}\n", .{socket_path});

    while (true) {
        var accepted: ?capnp_rpc.transports.Unix.Stream = null;
        while (accepted == null) {
            accepted = try listener.accept();
            if (accepted == null) {
                var fds = [1]std.posix.pollfd{.{
                    .fd = listener.fd(),
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                _ = try std.posix.poll(&fds, -1);
            }
        }

        var stream = accepted.?;
        defer stream.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var connection = try capnp_rpc.Connection.init(allocator, stream.endpoint(.server));
        defer connection.deinit();

        var stateless_server_context: u8 = 0;
        var greeter_server = schema.Greeter.Server{
            .context = &stateless_server_context,
            .vtable = .{
                .hello = GreeterImpl.hello,
                .farewell = GreeterImpl.farewell,
            },
        };
        var calculator_state = CalculatorState{ .allocator = arena.allocator() };
        var calculator_server = schema.Calculator.Server{
            .context = &calculator_state,
            .vtable = .{
                .add = CalculatorImpl.add,
                .multiply = CalculatorImpl.multiply,
            },
        };

        var services = Services{
            .greeter = greeter_server.localCapability(),
            .calculator = calculator_server.localCapability(),
        };
        var factory_server = schema.Factory.Server{
            .context = &services,
            .vtable = .{
                .getGreeter = FactoryImpl.getGreeter,
                .getCalculator = FactoryImpl.getCalculator,
                .version = FactoryImpl.version,
            },
        };
        connection.setBootstrap(try connection.initLocal(factory_server.localCapability()));

        while (true) {
            var events: i16 = std.posix.POLL.IN;
            if (connection.wantsWrite()) events |= std.posix.POLL.OUT;

            var fds = [1]std.posix.pollfd{.{
                .fd = connection.fd(),
                .events = events,
                .revents = 0,
            }};
            _ = try std.posix.poll(&fds, -1);

            try connection.step();
            if (connection.isClosed()) break;
        }
    }
}
