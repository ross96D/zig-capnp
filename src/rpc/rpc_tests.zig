const std = @import("std");

test "generated RPC protocol bindings compile" {
    std.testing.refAllDecls(@import("rpc.zig"));
    std.testing.refAllDecls(@import("rpc_twoparty.zig"));
}
