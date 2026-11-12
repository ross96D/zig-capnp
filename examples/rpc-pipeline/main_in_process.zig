const std = @import("std");
const capnp_rpc = @import("capnp_rpc");
const schema = @import("generated/services.zig");
const int_expr = @import("int_expr.zig");

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
        const index = try call.addResultCapability(.{ .local = result.capability() });
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
        const index = try call.addResultCapability(.{ .local = result.capability() });
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
        const index = try call.addResultCapability(.{ .local = services.greeter });
        results.greeter().setCapability(index);
    }

    fn getCalculator(
        context: *anyopaque,
        _: schema.Factory.GetCalculatorParams.Reader,
        results: schema.Factory.GetCalculatorResults.Builder,
        call: capnp_rpc.Call,
    ) anyerror!void {
        const services: *Services = @ptrCast(@alignCast(context));
        const index = try call.addResultCapability(.{ .local = services.calculator });
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var loopback = capnp_rpc.transports.Loopback.init(allocator);
    defer loopback.deinit();

    var server_connection = try capnp_rpc.Connection.init(allocator, loopback.endpoint(.server));
    defer server_connection.deinit();

    var client_connection = try capnp_rpc.Connection.init(allocator, loopback.endpoint(.client));
    defer client_connection.deinit();

    client_connection.peer = &server_connection;
    server_connection.peer = &client_connection;

    var greeter_server = schema.Greeter.Server{
        .context = undefined,
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
    server_connection.setBootstrap(.{ .local = factory_server.localCapability() });

    const factory_capability = try client_connection.bootstrap();
    const factory = schema.Factory.Client.fromCapability(factory_capability);

    {
        var version_request = try factory.version();
        defer version_request.deinit();
        var version_response = try version_request.send();
        defer version_response.deinit(allocator);
        const version_results = try version_response.results(
            schema.Factory.VersionResults.Reader,
            schema.Factory.VersionResults.reader_trait,
        );
        std.debug.print("Factory version: {s}\n", .{try version_results.version()});
    }

    // Ask for a Greeter, then call it before the Factory call returns.
    {
        var greeter_request = try factory.getGreeter();
        defer greeter_request.deinit();
        var greeter_pending = try greeter_request.start();
        const greeter_capability = try greeter_pending.capability(0);
        const greeter = schema.Greeter.Client.fromCapability(greeter_capability);

        {
            var hello_request = try greeter.hello();
            defer hello_request.deinit();
            var hello_params = try hello_request.params();
            try hello_params.setName("Ada");
            var hello_response = try hello_request.send();
            defer hello_response.deinit(allocator);
            const hello_results = try hello_response.results(
                schema.Greeter.HelloResults.Reader,
                schema.Greeter.HelloResults.reader_trait,
            );
            std.debug.print("Pipelined hello: {s}\n", .{try hello_results.message()});
        }

        {
            var farewell_request = try greeter.farewell();
            defer farewell_request.deinit();
            var farewell_params = try farewell_request.params();
            try farewell_params.setName("Ada");
            var farewell_response = try farewell_request.send();
            defer farewell_response.deinit(allocator);
            const farewell_results = try farewell_response.results(
                schema.Greeter.FarewellResults.Reader,
                schema.Greeter.FarewellResults.reader_trait,
            );
            std.debug.print("Pipelined farewell: {s}\n", .{try farewell_results.message()});
        }

        var greeter_response = try greeter_pending.wait();
        defer greeter_response.deinit(allocator);
    }

    // Same idea with another interface.
    {
        var calculator_request = try factory.getCalculator();
        defer calculator_request.deinit();
        var calculator_pending = try calculator_request.start();
        const calculator_capability = try calculator_pending.capability(0);
        const calculator = schema.Calculator.Client.fromCapability(calculator_capability);

        {
            const a = try int_expr.IntExpr.init(arena.allocator(), 20);
            const b = try int_expr.IntExpr.init(arena.allocator(), 22);

            var add_request = try calculator.add();
            defer add_request.deinit();
            const a_index = try add_request.addCapability(.{ .local = a.capability() });
            const b_index = try add_request.addCapability(.{ .local = b.capability() });
            var add_params = try add_request.params();
            add_params.setA().setCapability(a_index);
            add_params.setB().setCapability(b_index);

            var add_response = try add_request.send();
            defer add_response.deinit(allocator);
            const add_results = try add_response.results(
                schema.Calculator.AddResults.Reader,
                schema.Calculator.AddResults.reader_trait,
            );
            const result = try add_response.capability(try (try add_results.result()).asCapability());
            std.debug.print("Pipelined add: {d}\n", .{try int_expr.IntExpr.evalCapability(&client_connection, result)});
        }

        {
            const a = try int_expr.IntExpr.init(arena.allocator(), 6);
            const b = try int_expr.IntExpr.init(arena.allocator(), 7);

            var multiply_request = try calculator.multiply();
            defer multiply_request.deinit();
            const a_index = try multiply_request.addCapability(.{ .local = a.capability() });
            const b_index = try multiply_request.addCapability(.{ .local = b.capability() });
            var multiply_params = try multiply_request.params();
            multiply_params.setA().setCapability(a_index);
            multiply_params.setB().setCapability(b_index);

            var multiply_response = try multiply_request.send();
            defer multiply_response.deinit(allocator);
            const multiply_results = try multiply_response.results(
                schema.Calculator.MultiplyResults.Reader,
                schema.Calculator.MultiplyResults.reader_trait,
            );
            const result = try multiply_response.capability(try (try multiply_results.result()).asCapability());
            std.debug.print("Pipelined multiply: {d}\n", .{try int_expr.IntExpr.evalCapability(&client_connection, result)});
        }

        var calculator_response = try calculator_pending.wait();
        defer calculator_response.deinit(allocator);
    }
}
