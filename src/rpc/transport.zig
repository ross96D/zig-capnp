//! Transport abstraction used by the RPC runtime.
//!
//! This module deliberately has no dependency on the connection/runtime code
//! so that transport implementations can be compiled and tested separately.

const std = @import("std");

pub const Side = enum(u8) { client = 0, server = 1 };

pub const Transport = struct {
    context: *anyopaque,
    side: Side = .client,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Non-blocking. Copy bytes into the transport's write queue and
        /// write whatever the peer accepts immediately.
        send: *const fn (transport: Transport, bytes: []const u8) anyerror!void,
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

    pub fn send(self: Transport, bytes: []const u8) anyerror!void {
        return self.vtable.send(self, bytes);
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
