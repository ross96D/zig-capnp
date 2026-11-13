//! Deterministic scripted transport for tests.
//!
//! Unlike the automatic loopback transport, `Scripted` does not deliver
//! messages by itself. Bytes sent by an endpoint land in that endpoint's
//! outbox; tests decide when (and in what order) to move them into the peer's
//! inbox. This makes ordering, cancellation, and malformed-message tests
//! deterministic without a blocking driver.

const std = @import("std");
const transport = @import("../transport.zig");
const Transport = transport.Transport;
const Side = transport.Side;

pub const Scripted = struct {
    allocator: std.mem.Allocator,
    outbox: [2]std.ArrayList([]u8) = .{ .empty, .empty },
    inbox: [2]std.ArrayList([]u8) = .{ .empty, .empty },
    closed: [2]bool = .{ false, false },

    const vtable = Transport.VTable{
        .send = send,
        .receive = receive,
        .flush = flush,
        .fd = fd,
        .wantsWrite = wantsWrite,
        .isClosed = isClosed,
    };

    pub fn init(allocator: std.mem.Allocator) Scripted {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scripted) void {
        for (&self.outbox) |*queue| {
            for (queue.items) |bytes| self.allocator.free(bytes);
            queue.deinit(self.allocator);
        }
        for (&self.inbox) |*queue| {
            for (queue.items) |bytes| self.allocator.free(bytes);
            queue.deinit(self.allocator);
        }
    }

    pub fn endpoint(self: *Scripted, side: Side) Transport {
        return .{ .context = self, .side = side, .vtable = &vtable };
    }

    /// Close one endpoint's outgoing half. `receive` still drains messages
    /// already in that endpoint's inbox.
    pub fn closeEndpoint(self: *Scripted, side: Side) void {
        self.closed[sideIndex(side)] = true;
    }

    pub fn endpointClosed(self: *Scripted, side: Side) bool {
        return self.closed[sideIndex(side)];
    }

    /// Number of messages sent by `side` that have not been delivered yet.
    pub fn outboxLen(self: *Scripted, side: Side) usize {
        return self.outbox[sideIndex(side)].items.len;
    }

    /// Number of messages waiting to be received by `side`.
    pub fn inboxLen(self: *Scripted, side: Side) usize {
        return self.inbox[sideIndex(side)].items.len;
    }

    /// Move the next message sent by `side` into the opposite endpoint's
    /// inbox. Returns false when the outbox is empty.
    pub fn deliverNext(self: *Scripted, side: Side) !bool {
        const from = sideIndex(side);
        const to = 1 - from;
        if (self.outbox[from].items.len == 0) return false;

        const bytes = self.outbox[from].orderedRemove(0);
        errdefer self.allocator.free(bytes);
        try self.inbox[to].append(self.allocator, bytes);
        return true;
    }

    /// Move every currently queued message sent by `side` to its peer.
    /// Messages produced while processing are not drained automatically.
    pub fn deliverAll(self: *Scripted, side: Side) !usize {
        var count: usize = 0;
        while (try self.deliverNext(side)) count += 1;
        return count;
    }

    /// Borrow the raw message at `index` in `side`'s outbox without removing it.
    pub fn peekOutbox(self: *Scripted, side: Side, index: usize) ?[]const u8 {
        const items = self.outbox[sideIndex(side)].items;
        if (index >= items.len) return null;
        return items[index];
    }

    /// Take ownership of the next raw message sent by `side`.
    pub fn takeOutbox(self: *Scripted, side: Side) !?[]u8 {
        const queue = &self.outbox[sideIndex(side)];
        if (queue.items.len == 0) return null;
        return queue.orderedRemove(0);
    }

    /// Give ownership of a raw message to the endpoint's inbox.
    pub fn pushInbox(self: *Scripted, side: Side, bytes: []u8) !void {
        try self.inbox[sideIndex(side)].append(self.allocator, bytes);
    }

    /// Copy a raw message into an endpoint's inbox.
    pub fn inject(self: *Scripted, side: Side, bytes: []const u8) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        try self.pushInbox(side, copy);
    }

    fn send(t: Transport, parts: transport.MessageParts) anyerror!void {
        const self: *Scripted = @ptrCast(@alignCast(t.context));
        const from = sideIndex(t.side);
        if (self.closed[from]) return error.EndOfStream;

        const copy = try parts.toOwnedBytes(self.allocator);
        errdefer self.allocator.free(copy);
        try self.outbox[from].append(self.allocator, copy);
    }

    fn receive(t: Transport, allocator: std.mem.Allocator) anyerror!?[]u8 {
        _ = allocator;
        const self: *Scripted = @ptrCast(@alignCast(t.context));
        const queue = &self.inbox[sideIndex(t.side)];
        if (queue.items.len == 0) return null;
        return queue.orderedRemove(0);
    }

    fn flush(_: Transport) anyerror!void {}

    fn fd(_: Transport) std.posix.fd_t {
        return -1;
    }

    fn wantsWrite(_: Transport) bool {
        return false;
    }

    fn isClosed(t: Transport) bool {
        const self: *Scripted = @ptrCast(@alignCast(t.context));
        return self.closed[sideIndex(t.side)];
    }
};

fn sideIndex(side: Side) usize {
    return @backingInt(side);
}
