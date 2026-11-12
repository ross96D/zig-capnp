const builtin = @import("builtin");

pub const Transport = @import("../transport.zig").Transport;
pub const Side = @import("../transport.zig").Side;

pub const Loopback = @import("in_memory.zig").Loopback;
pub const Scripted = @import("scripted.zig").Scripted;

/// The Unix transport currently uses raw Linux syscalls. Keep the core runtime
/// portable by only compiling it on Linux.
pub const Unix = if (builtin.os.tag == .linux) @import("unix.zig") else struct {};
