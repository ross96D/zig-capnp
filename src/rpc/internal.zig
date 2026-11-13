//! Pure internal types shared by the RPC runtime.
//!
//! Nothing in this file may depend on `Connection`; keeping these declarations
//! leaf-level avoids import cycles when the runtime is split into modules.

const std = @import("std");

pub const PendingCall = struct {
    question_id: u32,
    bytes: []u8,
};

pub const LocalKey = struct {
    context: usize,
    interface_id: u64,
    dispatch: usize,
};

pub const LocalKeyContext = struct {
    pub fn hash(_: LocalKeyContext, key: LocalKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.context));
        hasher.update(std.mem.asBytes(&key.interface_id));
        hasher.update(std.mem.asBytes(&key.dispatch));
        return hasher.final();
    }

    pub fn eql(_: LocalKeyContext, a: LocalKey, b: LocalKey) bool {
        return a.context == b.context and
            a.interface_id == b.interface_id and
            a.dispatch == b.dispatch;
    }
};

pub const ExportKind = enum {
    hosted,
    promise,
};

pub const FinishState = enum {
    not_sent,
    sent,
};

pub const AnswerCallState = enum {
    /// A placeholder created so pipelined calls have somewhere to attach.
    reserved,
    /// The original Call has been received (dispatching or queued).
    received,
};

pub const ConnectionLifecycle = enum { open, closing, closed };
pub const ConnectionDrainState = enum { idle, draining };
