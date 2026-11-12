//! RPC microbenchmarks.
//!
//! Run with:
//!   zig build bench -Doptimize=ReleaseFast
//!
//! The benchmark intentionally measures the public API end-to-end, including
//! message serialization, capability table handling, and scheduling.

const std = @import("std");
const capnp = @import("capnp");
const capnp_rpc = @import("capnp_rpc");

const connection = capnp_rpc.connection;
const transports = capnp_rpc.transports;
const rpc = capnp_rpc.rpc;

const EchoInterface = struct {
    const id: u64 = 0x6b4f2d2f8c1a9031;

    fn dispatch(_: *anyopaque, method_id: u16, call: connection.Call) anyerror!void {
        if (method_id != 0) return error.MethodNotFound;
        try call.results.setText(try call.params.asText());
    }
};

const BenchState = struct {
    echo: connection.LocalCapability,
};

const BenchInterface = struct {
    const id: u64 = 0xc1a7e5d04b92683f;

    fn dispatch(context: *anyopaque, method_id: u16, call: connection.Call) anyerror!void {
        const state: *BenchState = @ptrCast(@alignCast(context));
        switch (method_id) {
            0 => try call.results.setText(try call.params.asText()),
            1 => {
                const index = try call.addLocalResultCapability(state.echo);
                call.results.setCapability(index);
            },
            2 => {
                if (call.capabilities.len != 1) return error.MissingCapability;
                try call.results.setText("ok");
            },
            else => return error.MethodNotFound,
        }
    }
};

const iterations_local: usize = 50_000;
const iterations_remote: usize = 20_000;
const iterations_capability: usize = 10_000;
const iterations_pipeline: usize = 5_000;

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    try benchLocal(allocator);
    try benchRemote(allocator);
    try benchCapabilityPassing(allocator);
    try benchPipeline(allocator);
}

fn benchLocal(allocator: std.mem.Allocator) !void {
    var loopback = transports.Loopback.init(allocator);
    defer loopback.deinit();

    const conn = try connection.Connection.init(allocator, loopback.endpoint(.server));
    defer conn.deinit();

    var state = BenchState{ .echo = .{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    } };
    const capability = try conn.initLocal(.{
        .context = &state,
        .interface_id = BenchInterface.id,
        .dispatch = BenchInterface.dispatch,
    });
    defer capability.release();

    try localCalls(conn, capability, 1000);

    const start = nowNs();
    try localCalls(conn, capability, iterations_local);
    report("local-call", iterations_local, nowNs() - start);
}

fn localCalls(
    conn: *connection.Connection,
    capability: connection.Capability,
    iterations: usize,
) !void {
    for (0..iterations) |_| {
        var request = try conn.beginCall(capability, BenchInterface.id, 0);
        defer request.deinit();
        var params = try request.params();
        try params.content().setText("bench");
        var response = try request.send();
        defer response.deinit();
        const payload = try response.payload();
        _ = try (try payload.content()).asText();
    }
}

fn benchRemote(allocator: std.mem.Allocator) !void {
    var fixture = try RemoteFixture.init(allocator);
    defer fixture.deinit();

    try remoteCalls(fixture.client, fixture.server, fixture.link, fixture.provider, 200);

    const start = nowNs();
    try remoteCalls(fixture.client, fixture.server, fixture.link, fixture.provider, iterations_remote);
    report("scripted-call", iterations_remote, nowNs() - start);
}

fn remoteCalls(
    client: *connection.Connection,
    server: *connection.Connection,
    link: *transports.Scripted,
    provider: connection.Capability,
    iterations: usize,
) !void {
    for (0..iterations) |_| {
        var request = try client.beginCall(provider, BenchInterface.id, 0);
        defer request.deinit();
        var params = try request.params();
        try params.content().setText("bench");
        var pending = try request.start();
        defer pending.deinit();

        try pump(client, server, link);
        var response = try pending.wait();
        const payload = try response.payload();
        _ = try (try payload.content()).asText();
        response.deinit();

        try pump(client, server, link);
    }
}

fn benchCapabilityPassing(allocator: std.mem.Allocator) !void {
    var fixture = try RemoteFixture.init(allocator);
    defer fixture.deinit();

    const echoed = try fixture.client.initLocal(.{
        .context = null,
        .interface_id = EchoInterface.id,
        .dispatch = EchoInterface.dispatch,
    });
    defer echoed.release();

    try capabilityCalls(fixture.client, fixture.server, fixture.link, fixture.provider, echoed, 100);

    const start = nowNs();
    try capabilityCalls(
        fixture.client,
        fixture.server,
        fixture.link,
        fixture.provider,
        echoed,
        iterations_capability,
    );
    report("scripted-cap-pass", iterations_capability, nowNs() - start);
}

fn capabilityCalls(
    client: *connection.Connection,
    server: *connection.Connection,
    link: *transports.Scripted,
    provider: connection.Capability,
    parameter: connection.Capability,
    iterations: usize,
) !void {
    for (0..iterations) |_| {
        var request = try client.beginCall(provider, BenchInterface.id, 2);
        defer request.deinit();
        const index = try request.addCapability(parameter);
        var params = try request.params();
        params.content().setCapability(index);

        var pending = try request.start();
        defer pending.deinit();

        try pump(client, server, link);
        var response = try pending.wait();
        const payload = try response.payload();
        _ = try (try payload.content()).asText();
        response.deinit();

        try pump(client, server, link);
    }
}

fn benchPipeline(allocator: std.mem.Allocator) !void {
    var fixture = try RemoteFixture.init(allocator);
    defer fixture.deinit();

    try pipelinedCalls(fixture.client, fixture.server, fixture.link, fixture.provider, 100);

    const start = nowNs();
    try pipelinedCalls(fixture.client, fixture.server, fixture.link, fixture.provider, iterations_pipeline);
    report("scripted-pipeline", iterations_pipeline, nowNs() - start);
}

fn pipelinedCalls(
    client: *connection.Connection,
    server: *connection.Connection,
    link: *transports.Scripted,
    provider: connection.Capability,
    iterations: usize,
) !void {
    for (0..iterations) |_| {
        var factory_request = try client.beginCall(provider, BenchInterface.id, 1);
        defer factory_request.deinit();
        var factory_pending = try factory_request.start();
        defer factory_pending.deinit();

        const result_capability = try factory_pending.capability(null);
        defer result_capability.release();

        var echo_request = try client.beginCall(result_capability, EchoInterface.id, 0);
        defer echo_request.deinit();
        var params = try echo_request.params();
        try params.content().setText("bench");
        var echo_pending = try echo_request.start();
        defer echo_pending.deinit();

        try pump(client, server, link);

        var echo_response = try echo_pending.wait();
        const echoed = try echo_response.payload();
        _ = try (try echoed.content()).asText();
        echo_response.deinit();

        var factory_response = try factory_pending.wait();
        factory_response.deinit();

        try pump(client, server, link);
    }
}

const RemoteFixture = struct {
    link: *transports.Scripted,
    server: *connection.Connection,
    client: *connection.Connection,
    provider: connection.Capability,
    state: *BenchState,

    fn init(allocator: std.mem.Allocator) !RemoteFixture {
        const link = try allocator.create(transports.Scripted);
        link.* = transports.Scripted.init(allocator);
        errdefer {
            link.deinit();
            allocator.destroy(link);
        }

        const server = try connection.Connection.init(allocator, link.endpoint(.server));
        errdefer server.deinit();
        const client = try connection.Connection.init(allocator, link.endpoint(.client));
        errdefer client.deinit();

        const state = try allocator.create(BenchState);
        errdefer allocator.destroy(state);
        state.* = .{ .echo = .{
            .context = null,
            .interface_id = EchoInterface.id,
            .dispatch = EchoInterface.dispatch,
        } };
        const provider = try bootstrap(server, client, link, .{
            .context = state,
            .interface_id = BenchInterface.id,
            .dispatch = BenchInterface.dispatch,
        });

        return .{
            .link = link,
            .server = server,
            .client = client,
            .provider = provider,
            .state = state,
        };
    }

    fn deinit(self: *RemoteFixture) void {
        const allocator = self.link.allocator;
        self.provider.release();
        self.client.deinit();
        self.server.deinit();
        self.link.deinit();
        allocator.destroy(self.link);
        allocator.destroy(self.state);
    }
};

fn bootstrap(
    server: *connection.Connection,
    client: *connection.Connection,
    link: *transports.Scripted,
    capability: connection.LocalCapability,
) !connection.Capability {
    server.setBootstrap(try server.initLocal(capability));
    var promise = try client.bootstrapStart();
    try pump(client, server, link);
    const bootstrapped = try promise.wait();
    try pump(client, server, link);
    return bootstrapped;
}

fn pump(
    client: *connection.Connection,
    server: *connection.Connection,
    link: *transports.Scripted,
) !void {
    while (true) {
        var progressed = false;
        while (try link.deliverNext(.client)) {
            try server.step();
            progressed = true;
        }
        while (try link.deliverNext(.server)) {
            try client.step();
            progressed = true;
        }
        if (!progressed) return;
    }
}

fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn report(name: []const u8, iterations: usize, elapsed_ns: u64) void {
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
    const mops = 1000.0 / ns_per_op;
    std.debug.print(
        "{s:<24} {d:>8} iters  {d:>11.1} ns/op  {d:>8.3} Mops/s\n",
        .{ name, iterations, ns_per_op, mops },
    );
}
