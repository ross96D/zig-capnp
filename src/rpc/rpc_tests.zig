const std = @import("std");

test {
    _ = @import("wire.zig");
    _ = @import("transports/transport.zig");
    _ = @import("transports/transport_tests.zig");
    _ = @import("tests/mod.zig");
}

test "generated RPC protocol bindings compile" {
    std.testing.refAllDecls(@import("generated/rpc.zig"));
    std.testing.refAllDecls(@import("generated/rpc_twoparty.zig"));
}
