//! Transport abstraction used by the RPC runtime.
//!
//! This module deliberately has no dependency on the connection/runtime code
//! so that transport implementations can be compiled and tested separately.

const std = @import("std");

/// A framed message split into its header and segment payloads.
///
/// Transports may write these directly (e.g. `writev` or a queue append)
/// without first flattening them into a single allocation.
pub const MessageParts = struct {
    header: []const u8,
    segments: []const []const u8 = &.{},

    pub fn serializedSize(self: MessageParts) !usize {
        var total: usize = self.header.len;
        for (self.segments) |segment| {
            total = std.math.add(usize, total, segment.len) catch return error.MessageTooLarge;
        }
        return total;
    }

    /// Flatten the parts into a newly allocated buffer.
    pub fn toOwnedBytes(self: MessageParts, allocator: std.mem.Allocator) ![]u8 {
        const total = try self.serializedSize();
        const bytes = try allocator.alloc(u8, total);
        errdefer allocator.free(bytes);

        @memcpy(bytes[0..self.header.len], self.header);
        var offset: usize = self.header.len;
        for (self.segments) |segment| {
            @memcpy(bytes[offset..][0..segment.len], segment);
            offset += segment.len;
        }
        return bytes;
    }

    /// Write into caller-provided storage.
    pub fn writeToBuffer(self: MessageParts, buffer: []u8) ![]u8 {
        const total = try self.serializedSize();
        if (buffer.len < total) return error.NoSpaceLeft;

        @memcpy(buffer[0..self.header.len], self.header);
        var offset: usize = self.header.len;
        for (self.segments) |segment| {
            @memcpy(buffer[offset..][0..segment.len], segment);
            offset += segment.len;
        }
        return buffer[0..offset];
    }
};

pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        Closed, // peer hung up or we shut down; terminal
        ProtocolError, // malformed frame / limits exceeded; terminal
        OutOfMemory,
    };

    pub const Interest = enum { none, read, write, read_write };
    pub const Waker = struct { context: *anyopaque, wake: *const fn (*anyopaque) void };

    pub const VTable = struct {
        /// FIFO. Never blocks, never calls back into the transport/connection.
        /// `parts` is borrowed for the call only; buffered bytes are copied.
        /// Any error is terminal for the connection.
        send: *const fn (*anyopaque, MessageParts) Error!void,

        /// Next complete frame, or null if one isn't fully buffered yet.
        /// Returned bytes are owned by the caller and freed with `allocator`;
        /// they include the segment table (i.e. are directly usable by
        /// `Message.fromOwnedBytes`).
        receive: *const fn (*anyopaque, std.mem.Allocator) Error!?[]u8,

        /// Try to push queued bytes to the peer.
        flush: *const fn (*anyopaque) Error!void,

        /// Where the caller's event loop should wait.
        interest: *const fn (*anyopaque) Interest,

        /// Optional: non-fd transports (threads, in-process) use this to wake
        /// the loop when a frame becomes available.
        setWaker: *const fn (*anyopaque, ?Waker) void,

        /// Stop accepting sends, flush what's queued, then report error.Closed
        /// from receive/flush.
        shutdown: *const fn (*anyopaque) void,
        /// Drop buffers immediately and report error.Closed.
        close: *const fn (*anyopaque) void,
    };

    pub fn send(self: Transport, parts: MessageParts) anyerror!void {
        return self.vtable.send(self.context, parts);
    }

    pub fn receive(self: Transport, allocator: std.mem.Allocator) anyerror!?[]u8 {
        return self.vtable.receive(self.context, allocator);
    }

    pub fn flush(self: Transport) anyerror!void {
        return self.vtable.flush(self.context);
    }

    pub fn fd(self: Transport) std.posix.fd_t {
        return self.vtable.fd(self.context);
    }

    pub fn wantsWrite(self: Transport) bool {
        return self.vtable.wantsWrite(self.context);
    }

    pub fn isClosed(self: Transport) bool {
        return self.vtable.isClosed(self.context);
    }
};
