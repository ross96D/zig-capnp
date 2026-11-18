//! Transport abstraction used by the RPC runtime.
//!
//! A transport is a *message pipe*: it moves whole serialized Cap'n Proto
//! messages between two vats, preserving frame boundaries and ordering. It
//! knows nothing about the RPC protocol, vat sides, or capabilities; as far as
//! this interface is concerned a two-party stream is symmetric.
//!
//! Nothing here blocks. Callers drive progress with `send`, `receive` and
//! `flush`, then wait on `interest` -- either by polling the optional `fd` or
//! by waiting for the optional `Waker` to fire.
//!
//! ## Contract
//!
//! * Frames are delivered in order, exactly once, never merged or split.
//! * `send` copies whatever it cannot write immediately, so `parts` is only
//!   borrowed for the duration of the call. `send` never blocks and never
//!   calls back into the caller.
//! * `receive` returns a frame owned by the caller and allocated with the
//!   allocator passed to it. The bytes include the segment table, so they can
//!   be handed straight to `capnp.Message.fromOwnedBytes`. `null` means "no
//!   complete frame is buffered yet"; it never means EOF.
//! * EOF and fatal errors surface as `error.Closed`, exactly once, from the
//!   operation that observes them. Every method may return it; it is terminal.
//! * `interest` is consulted after `receive` has been drained until it returns
//!   `null`. `.none` means waiting cannot make progress: do not block.
//! * `shutdown` stops accepting sends, flushes what is queued, then reports
//!   `error.Closed`. `close` drops buffers immediately. Both are idempotent.
//! * `setWaker` is optional. A transport without an `fd` must use it to notify
//!   the event loop. Wakers must be cheap and non-blocking; they may be called
//!   synchronously from `flush`.
//! * `fd` is optional and exists only for transports driven by a poll loop.
//! * Everything is called from one thread unless the transport documents
//!   otherwise. A transport fed from another thread must synchronize
//!   internally and use `setWaker`.
//! * `context` must outlive every copy of the `Transport` value and must never
//!   point into the `Transport` itself, since transports are copied freely.

const std = @import("std");

const MessageParts = @import("../wire.zig").MessageParts;

pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        /// Peer hung up, the transport was shut down, or it failed terminally.
        Closed,
        /// Malformed frame, or a segment/message limit was exceeded.
        ProtocolError,
        /// The message, or the outbound queue, is too large.
        MessageTooLarge,
        OutOfMemory,
    };

    /// Where the caller's event loop should wait.
    pub const Interest = enum {
        /// Waiting cannot make progress. Do not block.
        none,
        /// Wait until inbound progress is possible.
        read,
        /// Wait until outbound progress is possible.
        write,
        /// Wait for either direction.
        read_write,
    };

    /// Called when a transport without an `fd` makes progress possible:
    /// inbound bytes arrived, or the peer closed.
    pub const Waker = struct {
        context: *anyopaque,
        wake: *const fn (context: *anyopaque) void,

        pub fn notify(self: Waker) void {
            self.wake(self.context);
        }
    };

    pub const VTable = struct {
        /// FIFO. Never blocks, never calls back into the transport's owner.
        /// Buffered bytes are copied; `parts` is borrowed for the call only.
        /// Any error is terminal for the connection.
        send: *const fn (context: *anyopaque, parts: MessageParts) Error!void,

        /// Next complete frame, or null if one isn't fully buffered yet.
        /// Returned bytes are owned by the caller and freed with `allocator`.
        receive: *const fn (context: *anyopaque, allocator: std.mem.Allocator) Error!?[]u8,

        /// Try to push queued bytes to the peer.
        flush: *const fn (context: *anyopaque) Error!void,

        /// What the caller's event loop should wait for. Consulted after
        /// `receive` has been drained until it returns `null`.
        interest: *const fn (context: *anyopaque) Interest,

        /// Optional: non-fd transports (threads, in-process) use this to wake
        /// the loop when a frame becomes available.
        setWaker: ?*const fn (context: *anyopaque, waker: ?Waker) void = null,

        /// Optional: the descriptor a poll loop should wait on, if the
        /// transport has one.
        fd: ?*const fn (context: *anyopaque) std.posix.fd_t = null,

        /// Stop accepting sends, flush what's queued, then report
        /// `error.Closed` from `receive` and `flush`.
        shutdown: *const fn (context: *anyopaque) void,

        /// Drop buffers immediately and report `error.Closed`.
        close: *const fn (context: *anyopaque) void,
    };

    pub fn send(self: Transport, parts: MessageParts) Error!void {
        return self.vtable.send(self.context, parts);
    }

    pub fn receive(self: Transport, allocator: std.mem.Allocator) Error!?[]u8 {
        return self.vtable.receive(self.context, allocator);
    }

    pub fn flush(self: Transport) Error!void {
        return self.vtable.flush(self.context);
    }

    pub fn interest(self: Transport) Interest {
        return self.vtable.interest(self.context);
    }

    pub fn setWaker(self: Transport, waker: ?Waker) void {
        if (self.vtable.setWaker) |set| set(self.context, waker);
    }

    pub fn fd(self: Transport) ?std.posix.fd_t {
        const get = self.vtable.fd orelse return null;
        return get(self.context);
    }

    pub fn shutdown(self: Transport) void {
        self.vtable.shutdown(self.context);
    }

    pub fn close(self: Transport) void {
        self.vtable.close(self.context);
    }
};

/// Test transports.
pub const testing = struct {
    /// Cap'n Proto's protocol limit on the number of segments in a message.
    pub const default_max_segments: u32 = 512;
    pub const default_max_message_bytes: usize = 64 * 1024 * 1024;

    /// In-memory duplex transport with no file descriptor.
    ///
    /// `send` only queues bytes; nothing reaches the peer until `flush`, and a
    /// flush may move just a prefix of the queued bytes (see
    /// `Options.flush_budget`). Received bytes are framed with the same rules
    /// as a socket transport, so malformed input surfaces as
    /// `error.ProtocolError`.
    ///
    /// The object is heap-allocated so the `Transport` values returned by
    /// `endpoint` never dangle.
    pub const Pipe = struct {
        allocator: std.mem.Allocator,
        options: Options,

        /// Bytes queued by an endpoint that `flush` has not moved yet.
        pending: [2]std.ArrayList(u8) = .{ .empty, .empty },
        /// Bytes moved to an endpoint that `receive` has not handed out yet.
        inbound: [2]std.ArrayList(u8) = .{ .empty, .empty },
        /// The peer is gone: no more bytes will arrive, `send` and `flush`
        /// report `Closed`, and `receive` reports it once no complete frame is
        /// left.
        eof_in: [2]bool = .{ false, false },
        /// The local endpoint reported `Closed` and accepts nothing more.
        closed: [2]bool = .{ false, false },
        wakers: [2]?Transport.Waker = .{ null, null },
        states: [2]State = undefined,

        pub const Endpoint = enum(u1) { a = 0, b = 1 };

        pub const Options = struct {
            /// Maximum number of bytes moved by a single `flush`. `null` moves
            /// everything queued. Lets tests observe partial writes.
            flush_budget: ?usize = null,
            /// Largest frame allowed in either direction.
            max_message_bytes: usize = default_max_message_bytes,
            /// Largest segment count accepted on receive.
            max_segments: u32 = default_max_segments,
        };

        const State = struct {
            pipe: *Pipe,
            index: usize,
        };

        const vtable = Transport.VTable{
            .send = send,
            .receive = receive,
            .flush = flush,
            .interest = interest,
            .setWaker = setWaker,
            .shutdown = shutdown,
            .close = close,
        };

        pub fn init(allocator: std.mem.Allocator, options: Options) !*Pipe {
            const self = try allocator.create(Pipe);
            errdefer allocator.destroy(self);

            self.* = .{ .allocator = allocator, .options = options };
            self.states = .{
                .{ .pipe = self, .index = 0 },
                .{ .pipe = self, .index = 1 },
            };

            return self;
        }

        pub fn deinit(self: *Pipe) void {
            for (&self.pending) |*queue| queue.deinit(self.allocator);
            for (&self.inbound) |*queue| queue.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn endpoint(self: *Pipe, which: Endpoint) Transport {
            const index = @backingInt(which);
            return .{ .context = &self.states[index], .vtable = &vtable };
        }

        pub fn endpoints(self: *Pipe) [2]Transport {
            return .{ self.endpoint(.a), self.endpoint(.b) };
        }

        /// Bytes queued by `which` and not yet flushed.
        pub fn pendingBytes(self: *Pipe, which: Endpoint) usize {
            return self.pending[@backingInt(which)].items.len;
        }

        /// Bytes delivered to `which` and not yet received.
        pub fn inboundBytes(self: *Pipe, which: Endpoint) usize {
            return self.inbound[@backingInt(which)].items.len;
        }

        pub fn isClosed(self: *Pipe, which: Endpoint) bool {
            return self.closed[@backingInt(which)];
        }

        fn state(context: *anyopaque) *State {
            return @ptrCast(@alignCast(context));
        }

        fn send(context: *anyopaque, parts: MessageParts) Transport.Error!void {
            const s = state(context);
            const self = s.pipe;
            const index = s.index;

            // A peer that closed before us will never read these bytes.
            if (self.closed[index] or self.eof_in[index]) return error.Closed;

            const total = parts.serializedSize() catch return error.MessageTooLarge;
            if (total > self.options.max_message_bytes) return error.MessageTooLarge;

            const queue = &self.pending[index];
            try queue.appendSlice(self.allocator, parts.header);
            for (parts.segments) |segment| {
                try queue.appendSlice(self.allocator, segment);
            }
        }

        fn receive(context: *anyopaque, allocator: std.mem.Allocator) Transport.Error!?[]u8 {
            const s = state(context);
            const self = s.pipe;
            const index = s.index;

            if (self.closed[index]) return error.Closed;

            const queue = &self.inbound[index];
            if (try scanFrame(queue.items, self.options)) |frame_len| {
                const frame = allocator.alloc(u8, frame_len) catch return error.OutOfMemory;
                @memcpy(frame, queue.items[0..frame_len]);

                std.mem.copyForwards(u8, queue.items[0..], queue.items[frame_len..]);
                queue.shrinkRetainingCapacity(queue.items.len - frame_len);

                return frame;
            }

            if (self.eof_in[index]) return error.Closed;
            return null;
        }

        fn flush(context: *anyopaque) Transport.Error!void {
            const s = state(context);
            const self = s.pipe;

            if (self.closed[s.index] or self.eof_in[s.index]) return error.Closed;

            const budget = self.options.flush_budget orelse std.math.maxInt(usize);
            return self.movePending(s.index, budget);
        }

        fn interest(context: *anyopaque) Transport.Interest {
            const s = state(context);
            const self = s.pipe;

            // Once either side is gone no further progress is possible; the
            // caller observes it through `error.Closed` from `receive`.
            if (self.closed[s.index] or self.eof_in[s.index]) return .none;

            return if (self.pending[s.index].items.len != 0) .read_write else .read;
        }

        fn setWaker(context: *anyopaque, waker: ?Transport.Waker) void {
            const s = state(context);
            s.pipe.wakers[s.index] = waker;
        }

        fn shutdown(context: *anyopaque) void {
            const s = state(context);
            const self = s.pipe;

            if (self.closed[s.index]) return;

            self.movePending(s.index, std.math.maxInt(usize)) catch {};
            self.closed[s.index] = true;
            self.eof_in[1 - s.index] = true;
            self.notify(1 - s.index);
        }

        fn close(context: *anyopaque) void {
            const s = state(context);
            const self = s.pipe;

            if (self.closed[s.index]) return;

            self.closed[s.index] = true;
            self.pending[s.index].clearRetainingCapacity();
            self.inbound[s.index].clearRetainingCapacity();
            self.eof_in[1 - s.index] = true;
            self.notify(1 - s.index);
        }

        fn notify(self: *Pipe, index: usize) void {
            if (self.wakers[index]) |waker| waker.notify();
        }

        fn movePending(self: *Pipe, index: usize, limit: usize) Transport.Error!void {
            const peer = 1 - index;
            const queue = &self.pending[index];
            const count = @min(limit, queue.items.len);
            if (count == 0) return;

            self.inbound[peer].appendSlice(self.allocator, queue.items[0..count]) catch
                return error.OutOfMemory;

            std.mem.copyForwards(u8, queue.items[0..], queue.items[count..]);
            queue.shrinkRetainingCapacity(queue.items.len - count);
            self.notify(peer);
        }

        /// Length of the complete frame at the front of `bytes`, `null` if more
        /// bytes are needed, or `ProtocolError` if the segment table is
        /// invalid. Mirrors the framing accepted by `capnp.Message`.
        fn scanFrame(bytes: []const u8, options: Options) Transport.Error!?usize {
            if (bytes.len < 4) return null;

            const segment_count_minus_one = std.mem.readInt(u32, bytes[0..4], .little);
            if (segment_count_minus_one >= options.max_segments) return error.ProtocolError;
            const segment_count: usize = @as(usize, segment_count_minus_one) + 1;

            const table_bytes = std.math.mul(usize, segment_count, 4) catch
                return error.ProtocolError;
            const data_offset = std.mem.alignForward(usize, 4 + table_bytes, 8);
            if (bytes.len < data_offset) return null;

            var total = data_offset;
            var i: usize = 0;
            while (i < segment_count) : (i += 1) {
                const words = std.mem.readInt(u32, bytes[4 + i * 4 ..][0..4], .little);
                const segment_bytes = std.math.mul(usize, words, 8) catch
                    return error.ProtocolError;
                total = std.math.add(usize, total, segment_bytes) catch
                    return error.ProtocolError;
                if (total > options.max_message_bytes) return error.ProtocolError;
            }

            if (bytes.len < total) return null;
            return total;
        }
    };
};
