//! Linux unix-domain socket setup and non-blocking I/O.
//!
//! Everything in this file is the part that `std.Io` would normally provide:
//! socket creation, bind/listen/accept/connect, and non-blocking read/write.
//! The transport layer in `unix.zig` only deals with message framing and
//! buffering.

const std = @import("std");
const linux = std.os.linux;

const path_field_len = @sizeOf(@FieldType(linux.sockaddr.un, "path"));

pub const Socket = struct {
    fd: linux.fd_t,

    pub fn connect(path: []const u8) !Socket {
        const fd = try createSocket();
        errdefer _ = linux.close(fd);

        const addr = try makeAddress(path);
        const rc = linux.connect(fd, @ptrCast(&addr), addressLen(path));
        switch (linux.errno(rc)) {
            .SUCCESS => return .{ .fd = fd },
            .INPROGRESS => {
                try waitWritable(fd);
                return .{ .fd = fd };
            },
            .CONNREFUSED => return error.ConnectionRefused,
            .NOENT => return error.FileNotFound,
            .ACCES, .PERM => return error.AccessDenied,
            .NOTDIR => return error.NotDir,
            .AGAIN => return error.WouldBlock,
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => return error.ConnectFailed,
        }
    }

    pub fn read(self: Socket, buf: []u8) !usize {
        if (buf.len == 0) return 0;

        while (true) {
            const rc = linux.read(self.fd, buf.ptr, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .AGAIN => return error.WouldBlock,
                .INTR => continue,
                .CONNRESET => return error.ConnectionResetByPeer,
                .NOTCONN => return error.SocketUnconnected,
                .BADF => return error.Unexpected,
                else => return error.ReadFailed,
            }
        }
    }

    pub fn write(self: Socket, bytes: []const u8) !usize {
        if (bytes.len == 0) return 0;

        while (true) {
            const rc = linux.sendto(
                self.fd,
                bytes.ptr,
                bytes.len,
                linux.MSG.NOSIGNAL,
                null,
                0,
            );
            switch (linux.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .AGAIN => return error.WouldBlock,
                .INTR => continue,
                .PIPE => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                .BADF => return error.Unexpected,
                else => return error.WriteFailed,
            }
        }
    }

    pub fn close(self: *Socket) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }
};

pub const Listener = struct {
    fd: linux.fd_t,

    pub fn listen(path: []const u8, backlog: u31) !Listener {
        const fd = try createSocket();
        errdefer _ = linux.close(fd);

        const addr = try makeAddress(path);
        switch (linux.errno(linux.bind(fd, @ptrCast(&addr), addressLen(path)))) {
            .SUCCESS => {},
            .ADDRINUSE => return error.AddressInUse,
            .ACCES, .PERM => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .ROFS => return error.ReadOnlyFileSystem,
            .NAMETOOLONG => return error.NameTooLong,
            .LOOP => return error.SymLinkLoop,
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => return error.BindFailed,
        }

        switch (linux.errno(linux.listen(fd, backlog))) {
            .SUCCESS => {},
            .ADDRINUSE => return error.AddressInUse,
            .BADF => return error.Unexpected,
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => return error.ListenFailed,
        }

        return .{ .fd = fd };
    }

    pub fn accept(self: Listener) !?Socket {
        while (true) {
            const rc = linux.accept4(
                self.fd,
                null,
                null,
                linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
            );
            switch (linux.errno(rc)) {
                .SUCCESS => return .{ .fd = @intCast(rc) },
                .AGAIN => return null,
                .INTR => continue,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS, .NOMEM => return error.SystemResources,
                .CONNABORTED => return error.ConnectionAborted,
                .BADF => return error.Unexpected,
                else => return error.AcceptFailed,
            }
        }
    }

    pub fn close(self: *Listener) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }
};

pub fn unlink(path: []const u8) void {
    const z = std.posix.toPosixPath(path) catch return;
    _ = linux.unlink(&z);
}

fn createSocket() !linux.fd_t {
    const rc = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    switch (linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        else => return error.SocketCreateFailed,
    }
}

fn makeAddress(path: []const u8) !linux.sockaddr.un {
    if (path.len > path_field_len) return error.NameTooLong;

    var addr: linux.sockaddr.un = std.mem.zeroes(linux.sockaddr.un);
    addr.family = linux.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

fn addressLen(path: []const u8) linux.socklen_t {
    return @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len);
}

fn waitWritable(fd: linux.fd_t) !void {
    var fds = [1]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};
    const n = try std.posix.poll(&fds, -1);
    if (n == 0) return error.ConnectFailed;

    var err_code: i32 = 0;
    var len: linux.socklen_t = @intCast(@sizeOf(i32));
    switch (linux.errno(linux.getsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.ERROR,
        @ptrCast(&err_code),
        &len,
    ))) {
        .SUCCESS => {},
        else => return error.ConnectFailed,
    }
    if (err_code != 0) return error.ConnectFailed;
}
