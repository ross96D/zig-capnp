//! Unix-domain socket transport.
//!
//! This file only contains transport-level concerns: message framing,
//! outbound buffering, and the `Transport` vtable. Socket setup and raw
//! non-blocking I/O live in `unix_io.zig`.

const std = @import("std");
const connection = @import("../connection.zig");
const io = @import("unix_io.zig");

const Transport = connection.Transport;
const Side = connection.Side;

const read_chunk_size = 64 * 1024;

pub const Options = struct {
    max_message_bytes: usize = 64 * 1024 * 1024,
    max_segments: usize = 512,
    kernel_backlog: u31 = 128,
    unlink_existing: bool = false,
    unlink_on_deinit: bool = true,
};

pub const Stream = struct {
    allocator: std.mem.Allocator,
    socket: io.Socket,
    reader: FrameReader,
    writer: WriteQueue,
    options: Options,
    closed: bool = false,

    const vtable = Transport.VTable{
        .send = send,
        .receive = receive,
        .flush = flush,
        .fd = fd,
        .wantsWrite = wantsWrite,
        .isClosed = isClosed,
    };

    pub fn connect(
        allocator: std.mem.Allocator,
        path: []const u8,
        options: Options,
    ) !Stream {
        return init(allocator, try io.Socket.connect(path), options);
    }

    pub fn init(
        allocator: std.mem.Allocator,
        socket: io.Socket,
        options: Options,
    ) Stream {
        return .{
            .allocator = allocator,
            .socket = socket,
            .reader = .{ .allocator = allocator },
            .writer = .{ .allocator = allocator },
            .options = options,
        };
    }

    pub fn deinit(self: *Stream) void {
        self.socket.close();
        self.reader.deinit();
        self.writer.deinit();
    }

    pub fn endpoint(self: *Stream, side: Side) Transport {
        return .{ .context = self, .side = side, .vtable = &vtable };
    }

    fn send(context: *anyopaque, side: Side, bytes: []const u8) anyerror!void {
        _ = side;
        const self: *Stream = @ptrCast(@alignCast(context));
        if (self.closed) return error.EndOfStream;

        try self.writer.append(bytes);
        try self.flushPending();
    }

    fn receive(
        context: *anyopaque,
        side: Side,
        allocator: std.mem.Allocator,
    ) anyerror!?[]u8 {
        _ = side;
        const self: *Stream = @ptrCast(@alignCast(context));

        while (true) {
            if (try self.reader.next(allocator, self.options)) |message| {
                return message;
            }
            if (self.closed) return null;

            self.reader.compactIfNeeded();
            try self.reader.buf.ensureUnusedCapacity(self.allocator, read_chunk_size);

            const spare = self.reader.buf.unusedCapacitySlice();
            const dest = spare[0..@min(spare.len, read_chunk_size)];
            const n = self.socket.read(dest) catch |err| switch (err) {
                error.WouldBlock => return null,
                else => {
                    self.closed = true;
                    return err;
                },
            };

            if (n == 0) {
                self.closed = true;
                return null;
            }
            self.reader.buf.items.len += n;
        }
    }

    fn flushPending(self: *Stream) anyerror!void {
        self.writer.flush(self.socket) catch |err| {
            self.closed = true;
            return err;
        };
    }

    fn flush(context: *anyopaque, side: Side) anyerror!void {
        _ = side;
        const self: *Stream = @ptrCast(@alignCast(context));
        try self.flushPending();
    }

    fn fd(context: *anyopaque, side: Side) std.posix.fd_t {
        _ = side;
        const self: *Stream = @ptrCast(@alignCast(context));
        return self.socket.fd;
    }

    fn wantsWrite(context: *anyopaque, side: Side) bool {
        _ = side;
        const self: *Stream = @ptrCast(@alignCast(context));
        return !self.writer.isEmpty();
    }

    fn isClosed(context: *anyopaque, side: Side) bool {
        _ = side;
        const self: *Stream = @ptrCast(@alignCast(context));
        return self.closed;
    }
};

pub const Listener = struct {
    allocator: std.mem.Allocator,
    socket: io.Listener,
    path: []u8,
    options: Options,
    unlink_on_deinit: bool,

    pub fn listen(
        allocator: std.mem.Allocator,
        path: []const u8,
        options: Options,
    ) !Listener {
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);

        const abstract = path.len > 0 and path[0] == 0;
        if (options.unlink_existing and !abstract) io.unlink(path);

        const socket = try io.Listener.listen(path, options.kernel_backlog);
        return .{
            .allocator = allocator,
            .socket = socket,
            .path = owned,
            .options = options,
            .unlink_on_deinit = options.unlink_on_deinit and !abstract,
        };
    }

    pub fn accept(self: *Listener) !?Stream {
        const socket = (try self.socket.accept()) orelse return null;
        return Stream.init(self.allocator, socket, self.options);
    }

    pub fn deinit(self: *Listener) void {
        self.socket.close();
        if (self.unlink_on_deinit) io.unlink(self.path);
        self.allocator.free(self.path);
    }
};

const FrameReader = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,

    fn deinit(self: *FrameReader) void {
        self.buf.deinit(self.allocator);
    }

    fn compactIfNeeded(self: *FrameReader) void {
        if (self.start == 0) return;
        if (self.start < self.buf.items.len / 2 and self.buf.items.len < read_chunk_size) {
            return;
        }

        const remaining = self.buf.items.len - self.start;
        if (remaining > 0) {
            std.mem.copyForwards(
                u8,
                self.buf.items[0..remaining],
                self.buf.items[self.start..],
            );
        }
        self.buf.shrinkRetainingCapacity(remaining);
        self.start = 0;
    }

    fn next(
        self: *FrameReader,
        allocator: std.mem.Allocator,
        options: Options,
    ) !?[]u8 {
        const available = self.buf.items[self.start..];
        if (available.len < 4) return null;

        const segment_count_wire = std.mem.readInt(u32, available[0..4], .little);
        const segment_count_wide: u64 = @as(u64, segment_count_wire) + 1;
        if (segment_count_wide > options.max_segments) return error.MessageTooLarge;

        const segment_count: usize = @intCast(segment_count_wide);
        const table_len = std.math.mul(usize, 4, segment_count) catch
            return error.MessageTooLarge;
        const table_end = std.math.add(usize, 4, table_len) catch
            return error.MessageTooLarge;
        const header_len = std.mem.alignForward(usize, table_end, 8);
        if (available.len < header_len) return null;

        var body_len: usize = 0;
        for (0..segment_count) |i| {
            const words = std.mem.readInt(u32, available[4 + i * 4 ..][0..4], .little);
            const segment_bytes = std.math.mul(usize, words, 8) catch
                return error.MessageTooLarge;
            body_len = std.math.add(usize, body_len, segment_bytes) catch
                return error.MessageTooLarge;
        }

        const total = std.math.add(usize, header_len, body_len) catch
            return error.MessageTooLarge;
        if (total > options.max_message_bytes) return error.MessageTooLarge;
        if (available.len < total) return null;

        const message = try allocator.dupe(u8, available[0..total]);
        self.start += total;
        self.compactIfNeeded();
        return message;
    }
};

const WriteQueue = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,

    fn deinit(self: *WriteQueue) void {
        self.buf.deinit(self.allocator);
    }

    fn isEmpty(self: *const WriteQueue) bool {
        return self.start >= self.buf.items.len;
    }

    fn append(self: *WriteQueue, bytes: []const u8) !void {
        self.compactIfNeeded();
        try self.buf.appendSlice(self.allocator, bytes);
    }

    fn compactIfNeeded(self: *WriteQueue) void {
        if (self.start == 0) return;
        if (self.start < self.buf.items.len / 2) return;

        const remaining = self.buf.items.len - self.start;
        if (remaining > 0) {
            std.mem.copyForwards(
                u8,
                self.buf.items[0..remaining],
                self.buf.items[self.start..],
            );
        }
        self.buf.shrinkRetainingCapacity(remaining);
        self.start = 0;
    }

    fn flush(self: *WriteQueue, socket: io.Socket) !void {
        while (self.start < self.buf.items.len) {
            const n = socket.write(self.buf.items[self.start..]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (n == 0) return error.BrokenPipe;
            self.start += n;
        }

        self.buf.clearRetainingCapacity();
        self.start = 0;
    }
};
