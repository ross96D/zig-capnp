const std = @import("std");
const capnp = @import("capnp");
const point = @import("point");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var builder = capnp.MessageBuilder{ .allocator = allocator };
    try builder.init();
    defer builder.deinit();

    var p = try builder.initRootStruct(point.Point.Builder, point.Point.builder_trait);
    p.setX(3);
    p.setY(7);
    try p.setName("packed");

    const raw = try builder.toBytes(allocator);
    defer allocator.free(raw);

    var packed_writer = std.Io.Writer.Allocating.init(allocator);
    defer packed_writer.deinit();
    try capnp.packing.pack(&packed_writer.writer, raw);
    const packed_bytes = try packed_writer.toOwnedSlice();
    defer allocator.free(packed_bytes);

    const unpacked_len = try capnp.packing.messageSize(packed_bytes);
    const unpacked = try allocator.alloc(u8, unpacked_len);
    defer allocator.free(unpacked);

    var fixed = std.Io.Writer.fixed(unpacked);
    try capnp.packing.unpack(&fixed, packed_bytes);

    var message = try capnp.Message.fromBytes(unpacked, allocator);
    defer message.deinit(allocator);

    const reader = try message.getRootStruct(point.Point.Reader, point.Point.reader_trait);
    std.debug.print("Packed message: raw={d} bytes, packed={d} bytes, x={d}\n", .{
        raw.len,
        packed_bytes.len,
        reader.x(),
    });
}
