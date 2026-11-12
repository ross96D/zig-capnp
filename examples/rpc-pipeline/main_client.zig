const std = @import("std");
const capnp_rpc = @import("capnp_rpc");
const schema = @import("generated/services.zig");
const int_expr = @import("int_expr.zig");

const socket_path = "/tmp/zig-capnp-rpc-pipeline.sock";

pub fn main() !void {
    var safe_allocator = std.heap.SafeAllocator.init(std.heap.page_allocator, .{});
    defer {
        _ = safe_allocator.deinit();
    }
    const allocator = safe_allocator.allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var stream = try capnp_rpc.transports.Unix.Stream.connect(allocator, socket_path, .{});
    defer stream.deinit();

    var connection = try capnp_rpc.Connection.init(allocator, stream.endpoint(.client));
    defer connection.deinit();

    const factory_capability = try connection.bootstrap();
    var factory = schema.Factory.Client.fromCapability(factory_capability);
    defer factory.deinit();

    // {
    //     var version_request = try factory.version();
    //     defer version_request.deinit();
    //     var version_response = try version_request.send();
    //     defer version_response.deinit();
    //     const version_results = try version_response.results(
    //         schema.Factory.VersionResults.Reader,
    //         schema.Factory.VersionResults.reader_trait,
    //     );
    //     std.debug.print("Factory version: {s}\n", .{try version_results.version()});
    // }

    // // Ask for a Greeter, then call it before the Factory call returns.
    // {
    //     var greeter_request = try factory.getGreeter();
    //     defer greeter_request.deinit();
    //     var greeter_pending = try greeter_request.start();
    //     const greeter_capability = try greeter_pending.capability(0);
    //     const greeter = schema.Greeter.Client.fromCapability(greeter_capability);

    //     {
    //         var hello_request = try greeter.hello();
    //         defer hello_request.deinit();
    //         var hello_params = try hello_request.params();
    //         try hello_params.setName("Ada");
    //         var hello_response = try hello_request.send();
    //         defer hello_response.deinit();
    //         const hello_results = try hello_response.results(
    //             schema.Greeter.HelloResults.Reader,
    //             schema.Greeter.HelloResults.reader_trait,
    //         );
    //         std.debug.print("Pipelined hello: {s}\n", .{try hello_results.message()});
    //     }

    //     {
    //         var farewell_request = try greeter.farewell();
    //         defer farewell_request.deinit();
    //         var farewell_params = try farewell_request.params();
    //         try farewell_params.setName("Ada");
    //         var farewell_response = try farewell_request.send();
    //         defer farewell_response.deinit();
    //         const farewell_results = try farewell_response.results(
    //             schema.Greeter.FarewellResults.Reader,
    //             schema.Greeter.FarewellResults.reader_trait,
    //         );
    //         std.debug.print("Pipelined farewell: {s}\n", .{try farewell_results.message()});
    //     }

    //     var greeter_response = try greeter_pending.wait();
    //     defer greeter_response.deinit();
    // }

    // Same idea with another interface.
    {
        var calculator_request = try factory.getCalculator();
        defer calculator_request.deinit();
        var calculator_pending = try calculator_request.start();
        const calculator_capability = try calculator_pending.capability(0);
        var calculator = schema.Calculator.Client.fromCapability(calculator_capability);
        defer calculator.deinit();

        {
            const a = try int_expr.IntExpr.init(arena.allocator(), 20);
            const b = try int_expr.IntExpr.init(arena.allocator(), 22);
            const c = try int_expr.IntExpr.init(arena.allocator(), 2);

            var add_request = try calculator.add();
            defer add_request.deinit();
            const a_index = try add_request.addLocalCapability(a.capability());
            const b_index = try add_request.addLocalCapability(b.capability());
            var add_params = try add_request.params();
            add_params.setA().setCapability(a_index);
            add_params.setB().setCapability(b_index);

            var add_promise = try add_request.start();

            var multiply_request = try calculator.multiply();
            defer multiply_request.deinit();
            const add_promise_cap = try add_promise.capability(0);
            defer add_promise_cap.release();
            const add_promise_index = try multiply_request.addCapability(add_promise_cap);
            const c_index = try multiply_request.addLocalCapability(c.capability());
            var multiply_params = try multiply_request.params();
            multiply_params.setA().setCapability(add_promise_index);
            multiply_params.setB().setCapability(c_index);

            var multiply_response = try multiply_request.send();
            defer multiply_response.deinit();
            const multiply_results = try multiply_response.results(
                schema.Calculator.MultiplyResults.Reader,
                schema.Calculator.MultiplyResults.reader_trait,
            );
            const multiply_result = try multiply_response.capability(try (try multiply_results.result()).asCapability());
            std.debug.print("Pipelined multiply: {d}\n", .{try int_expr.IntExpr.evalCapability(connection, multiply_result)});
            multiply_result.release();

            var add_response = try add_promise.wait();
            defer add_response.deinit();
            const add_results = try add_response.results(
                schema.Calculator.AddResults.Reader,
                schema.Calculator.AddResults.reader_trait,
            );
            const add_result = try add_response.capability(try (try add_results.result()).asCapability());
            std.debug.print("Pipelined add: {d}\n", .{try int_expr.IntExpr.evalCapability(connection, add_result)});
            add_result.release();
        }

        var calculator_response = try calculator_pending.wait();
        defer calculator_response.deinit();
    }
}
