const std = @import("std");
const capnp_rpc = @import("capnp_rpc");
const schema = @import("generated/services.zig");

/// A constant integer expression exposed as the Calculator.IntExpr capability.
pub const IntExpr = struct {
    value: i32,
    server: schema.Calculator.IntExpr.Server,

    pub fn init(allocator: std.mem.Allocator, value: i32) !*IntExpr {
        const self = try allocator.create(IntExpr);
        self.* = .{
            .value = value,
            .server = undefined,
        };
        self.server = .{
            .context = self,
            .vtable = .{ .eval = eval },
        };
        return self;
    }

    pub fn capability(self: *IntExpr) capnp_rpc.LocalCapability {
        return self.server.localCapability();
    }

    fn eval(
        context: *anyopaque,
        _: schema.Calculator.IntExpr.EvalParams.Reader,
        results: schema.Calculator.IntExpr.EvalResults.Builder,
        _: capnp_rpc.Call,
    ) anyerror!void {
        const self: *IntExpr = @ptrCast(@alignCast(context));
        results.setValue(self.value);
    }

    /// Evaluate an IntExpr capability over `connection`.
    pub fn evalCapability(connection: *capnp_rpc.Connection, target: capnp_rpc.Capability) !i32 {
        var request = try connection.beginCall(target, schema.Calculator.IntExpr.id, 0);
        defer request.deinit();
        var response = try request.send();
        defer response.deinit();
        const results = try response.results(
            schema.Calculator.IntExpr.EvalResults.Reader,
            schema.Calculator.IntExpr.EvalResults.reader_trait,
        );
        return results.value();
    }
};

/// Resolve an IntExpr field from this call's capability table.
pub fn capabilityForParam(call: capnp_rpc.Call, expr: schema.Calculator.IntExpr.Reader) !capnp_rpc.Capability {
    const index = try expr.asCapability();
    if (index >= call.capabilities.len) return error.MissingCapability;
    return call.capabilities[index];
}
