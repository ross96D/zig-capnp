//! Optional drivers for in-process connections.
//!
//! The runtime itself never pumps a peer from `sendRaw`. Blocking convenience
//! calls (`Request.send`, `Connection.bootstrap`) need a progress source when
//! the transport has no file descriptor. `LoopbackPair` owns two in-memory
//! connections and installs wakers that step the opposite side only while a
//! blocking wait is active.

const std = @import("std");
const connection = @import("connection.zig");
const transports = @import("transports/mod.zig");

pub const LoopbackPair = struct {
    allocator: std.mem.Allocator,
    transport: transports.Loopback,
    client: *connection.Connection,
    server: *connection.Connection,

    /// Allocate and wire a client/server pair. The pair is heap-allocated so
    /// the waker context pointers stay stable for the connections' lifetime.
    pub fn init(allocator: std.mem.Allocator) !*LoopbackPair {
        const self = try allocator.create(LoopbackPair);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.transport = transports.Loopback.init(allocator);
        errdefer self.transport.deinit();

        self.client = try connection.Connection.init(allocator, self.transport.endpoint(.client));
        errdefer self.client.deinit();

        self.server = try connection.Connection.init(allocator, self.transport.endpoint(.server));
        errdefer self.server.deinit();

        self.client.setWaker(.{ .context = self, .function = wakeClient });
        self.server.setWaker(.{ .context = self, .function = wakeServer });
        return self;
    }

    pub fn deinit(self: *LoopbackPair) void {
        const allocator = self.allocator;
        self.client.deinit();
        self.server.deinit();
        self.transport.deinit();
        allocator.destroy(self);
    }

    /// Process currently available messages on both ends.
    pub fn step(self: *LoopbackPair) !void {
        try self.client.step();
        try self.server.step();
    }

    /// Drive both endpoints until the in-memory queues are empty.
    pub fn pump(self: *LoopbackPair) !void {
        while (true) {
            try self.client.step();
            try self.server.step();
            if (self.transport.pending(.client) == 0 and
                self.transport.pending(.server) == 0) return;
        }
    }

    /// Convenience for the common test/example case.
    pub fn bootstrap(self: *LoopbackPair) !connection.Capability {
        return self.client.bootstrap();
    }

    fn wakeClient(context: *anyopaque) anyerror!void {
        const self: *LoopbackPair = @ptrCast(@alignCast(context));
        try self.server.step();
    }

    fn wakeServer(context: *anyopaque) anyerror!void {
        const self: *LoopbackPair = @ptrCast(@alignCast(context));
        try self.client.step();
    }
};
