const std = @import("std");
const capnp = @import("capnp");
const point = @import("point");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var builder = capnp.MessageBuilder{ .allocator = allocator };
    try builder.init();
    defer builder.deinit();

    var polyline = try builder.initRootStruct(point.Polyline.Builder, point.Polyline.builder_trait);
    var points = try polyline.initPoints(3);
    for (0..3) |i| {
        var p = points.get(@intCast(i));
        p.setX(@intCast(i * 10));
        p.setY(@intCast(i * i));
    }

    const size = try builder.serializedSize();
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    _ = try builder.writeToBuffer(bytes);

    var message = try capnp.Message.fromBytes(bytes, allocator);
    defer message.deinit(allocator);

    const reader = try message.getRootStruct(point.Polyline.Reader, point.Polyline.reader_trait);
    const got = try reader.points();
    std.debug.print("Polyline has {d} points:\n", .{got.length});
    for (0..got.length) |i| {
        const p = got.get(@intCast(i));
        std.debug.print("  ({d}, {d})\n", .{ p.x(), p.y() });
    }
}
