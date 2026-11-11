const std = @import("std");
const capnp_rpc = @import("capnp_rpc");
const schema = @import("generated/services.zig");

const socket_path = "/tmp/zig-capnp-rpc-pipeline.sock";

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var stream = try capnp_rpc.transports.Unix.Stream.connect(allocator, socket_path, .{});
    defer stream.deinit();

    var connection = try capnp_rpc.Connection.init(allocator, stream.endpoint(.client));
    defer connection.deinit();

    const factory_capability = try connection.bootstrap();
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
            var add_request = try calculator.add();
            defer add_request.deinit();
            var add_params = try add_request.params();
            add_params.setA(20);
            add_params.setB(22);
            var add_response = try add_request.send();
            defer add_response.deinit(allocator);
            const add_results = try add_response.results(
                schema.Calculator.AddResults.Reader,
                schema.Calculator.AddResults.reader_trait,
            );
            std.debug.print("Pipelined add: {d}\n", .{add_results.result()});
        }

        {
            var multiply_request = try calculator.multiply();
            defer multiply_request.deinit();
            var multiply_params = try multiply_request.params();
            multiply_params.setA(6);
            multiply_params.setB(7);
            var multiply_response = try multiply_request.send();
            defer multiply_response.deinit(allocator);
            const multiply_results = try multiply_response.results(
                schema.Calculator.MultiplyResults.Reader,
                schema.Calculator.MultiplyResults.reader_trait,
            );
            std.debug.print("Pipelined multiply: {d}\n", .{multiply_results.result()});
        }

        var calculator_response = try calculator_pending.wait();
        defer calculator_response.deinit(allocator);
    }
}
