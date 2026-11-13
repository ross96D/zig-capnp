const std = @import("std");
const transport = @import("../transport.zig");
const Transport = transport.Transport;
const Side = transport.Side;

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

    /// Number of messages waiting to be received by `side`.
    pub fn pending(self: *Loopback, side: Side) usize {
        return self.queues[@backingInt(side)].items.len;
    }

    fn send(t: Transport, parts: transport.MessageParts) anyerror!void {
        const self: *Loopback = @ptrCast(@alignCast(t.context));
        const copy = try parts.toOwnedBytes(self.allocator);
        errdefer self.allocator.free(copy);

        const peer: usize = 1 - @backingInt(t.side);
        try self.queues[peer].append(self.allocator, copy);
    }

    fn receive(t: Transport, allocator: std.mem.Allocator) anyerror!?[]u8 {
        _ = allocator;
        const self: *Loopback = @ptrCast(@alignCast(t.context));
        const idx = @backingInt(t.side);
        if (self.queues[idx].items.len == 0) return null;
        return self.queues[idx].orderedRemove(0);
    }

    fn flush(_: Transport) anyerror!void {}

    fn fd(_: Transport) std.posix.fd_t {
        return -1;
    }

    fn wantsWrite(_: Transport) bool {
        return false;
    }

    fn isClosed(_: Transport) bool {
        return false;
    }
};
