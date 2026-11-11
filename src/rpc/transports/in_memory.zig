const std = @import("std");
const connection = @import("../connection.zig");
const Transport = connection.Transport;
const Side = connection.Side;

/// In-memory duplex transport used by tests and local RPC.
pub const Loopback = struct {
    allocator: std.mem.Allocator,
    queues: [2]std.ArrayList([]u8) = .{ .empty, .empty },

    const vtable = Transport.VTable{
        .send = send,
        .receive = receive,
    };

    pub fn init(allocator: std.mem.Allocator) Loopback {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Loopback) void {
        for (&self.queues) |*queue| {
            for (queue.items) |bytes| self.allocator.free(bytes);
            queue.deinit(self.allocator);
        }
    }

    pub fn endpoint(self: *Loopback, side: Side) Transport {
        return .{ .context = self, .side = side, .vtable = &vtable };
    }

    fn send(context: *anyopaque, side: Side, bytes: []const u8) anyerror!void {
        const self: *Loopback = @ptrCast(@alignCast(context));
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);

        const peer: usize = 1 - @backingInt(side);
        try self.queues[peer].append(self.allocator, copy);
    }

    fn receive(context: *anyopaque, side: Side, allocator: std.mem.Allocator) anyerror!?[]u8 {
        _ = allocator;
        const self: *Loopback = @ptrCast(@alignCast(context));
        const idx = @backingInt(side);
        if (self.queues[idx].items.len == 0) return null;
        return self.queues[idx].orderedRemove(0);
    }
};
