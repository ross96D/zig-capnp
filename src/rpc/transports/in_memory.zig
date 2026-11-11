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
        .flush = flush,
        .fd = fd,
        .wantsWrite = wantsWrite,
        .isClosed = isClosed,
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

    fn flush(context: *anyopaque, side: Side) anyerror!void {
        _ = context;
        _ = side;
    }

    fn fd(context: *anyopaque, side: Side) std.posix.fd_t {
        _ = context;
        _ = side;
        return -1;
    }

    fn wantsWrite(context: *anyopaque, side: Side) bool {
        _ = context;
        _ = side;
        return false;
    }

    fn isClosed(context: *anyopaque, side: Side) bool {
        _ = context;
        _ = side;
        return false;
    }
};
