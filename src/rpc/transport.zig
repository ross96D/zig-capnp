//! Transport abstraction used by the RPC runtime.
//!
//! This module deliberately has no dependency on the connection/runtime code
//! so that transport implementations can be compiled and tested separately.

const std = @import("std");

pub const Side = enum(u8) { client = 0, server = 1 };

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
    side: Side = .client,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Non-blocking. Copy/write framed message parts into the transport's
        /// output queue and write whatever the peer accepts immediately.
        ///
        /// `parts` is borrowed only for the duration of this call; transports
        /// must copy or write it before returning.
        send: *const fn (transport: Transport, parts: MessageParts) anyerror!void,
        /// Non-blocking. Return one complete message, or null if no complete
        /// message is currently buffered.
        receive: *const fn (transport: Transport, allocator: std.mem.Allocator) anyerror!?[]u8,
        /// Non-blocking. Continue writing buffered outbound bytes.
        flush: *const fn (transport: Transport) anyerror!void,
        /// File descriptor to poll, or -1 for in-memory transports.
        fd: *const fn (transport: Transport) std.posix.fd_t,
        /// True while send() has buffered bytes waiting for writability.
        wantsWrite: *const fn (transport: Transport) bool,
        /// True after EOF or a fatal transport error.
        isClosed: *const fn (transport: Transport) bool,
    };

    pub fn send(self: Transport, parts: MessageParts) anyerror!void {
        return self.vtable.send(self, parts);
    }

    pub fn receive(self: Transport, allocator: std.mem.Allocator) anyerror!?[]u8 {
        return self.vtable.receive(self, allocator);
    }

    pub fn flush(self: Transport) anyerror!void {
        return self.vtable.flush(self);
    }

    pub fn fd(self: Transport) std.posix.fd_t {
        return self.vtable.fd(self);
    }

    pub fn wantsWrite(self: Transport) bool {
        return self.vtable.wantsWrite(self);
    }

    pub fn isClosed(self: Transport) bool {
        return self.vtable.isClosed(self);
    }
};
