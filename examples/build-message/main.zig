const std = @import("std");
const capnp = @import("capnp");
const point = @import("point");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var builder = try capnp.GrowableMessage.init(allocator, 65536);
    defer builder.deinit();

    var p = try builder.initRootStruct(point.Point.Builder, point.Point.builder_trait);
    p.setX(12);
    p.setY(-4);
    try p.setName("corner");

    const size = try builder.serializedSize();
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    _ = try builder.writeToBuffer(bytes);

    var message = try capnp.Message.fromBytes(bytes, allocator);
    defer message.deinit(allocator);

    const reader = try message.getRootStruct(point.Point.Reader, point.Point.reader_trait);
    std.debug.print("Point: x={d}, y={d}, name={s}\n", .{
        reader.x(),
        reader.y(),
        try reader.name(),
    });
}
