const std = @import("std");
const packing = @import("packed.zig");
const testing = std.testing;

fn expectPack(expected: []const u8, input: []const u8) !void {
    const buffer = try testing.allocator.alloc(u8, expected.len);
    defer testing.allocator.free(buffer);

    var writer = std.Io.Writer.fixed(buffer);
    try packing.pack(&writer, input);

    try testing.expectEqual(expected.len, writer.end);
    try testing.expectEqualSlices(u8, expected, buffer[0..writer.end]);
}

fn expectUnpack(expected: []const u8, input: []const u8) !void {
    const buffer = try testing.allocator.alloc(u8, expected.len);
    defer testing.allocator.free(buffer);

    var writer = std.Io.Writer.fixed(buffer);
    try packing.unpack(&writer, input);

    try testing.expectEqual(expected.len, writer.end);
    try testing.expectEqualSlices(u8, expected, buffer[0..writer.end]);
}

fn expectRoundTrip(bytes: []const u8) !void {
    const packed_buffer = try testing.allocator.alloc(u8, bytes.len + bytes.len / 8);
    defer testing.allocator.free(packed_buffer);

    var packed_writer = std.Io.Writer.fixed(packed_buffer);
    try packing.pack(&packed_writer, bytes);
    const packed_bytes = packed_buffer[0..packed_writer.end];

    const unpacked_buffer = try testing.allocator.alloc(u8, bytes.len);
    defer testing.allocator.free(unpacked_buffer);

    var unpacked_writer = std.Io.Writer.fixed(unpacked_buffer);
    try packing.unpack(&unpacked_writer, packed_bytes);

    try testing.expectEqual(bytes.len, unpacked_writer.end);
    try testing.expectEqualSlices(u8, bytes, unpacked_buffer[0..unpacked_writer.end]);
}

const date_raw = [_]u8{
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0xe7, 0x07, 0x07, 0x0e, 0x00, 0x00, 0x00, 0x00,
};

const date_packed = [_]u8{
    0x10, 0x02, 0x10, 0x01, 0x0f, 0xe7, 0x07, 0x07, 0x0e,
};

const unions_raw = [_]u8{
    0x00, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x1f, 0x00, 0x00, 0x00,
    0x0c, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
};

const unions_packed = [_]u8{
    0x10, 0x06, 0x40, 0x01, 0x11, 0x01, 0x1f, 0x11, 0x0c,
    0x01, 0x01, 0x01, 0x00, 0x00, 0x11, 0x01, 0x02,
};

test "pack and unpack empty input" {
    try expectPack(&.{}, &.{});
    try expectUnpack(&.{}, &.{});
}

test "pack word tags" {
    try expectPack(&.{ 0x01, 0x01 }, &.{ 1, 0, 0, 0, 0, 0, 0, 0 });
    try expectPack(&.{ 0x02, 0x02 }, &.{ 0, 2, 0, 0, 0, 0, 0, 0 });
    try expectPack(&.{ 0x81, 0x01, 0x80 }, &.{ 1, 0, 0, 0, 0, 0, 0, 0x80 });
    try expectPack(&.{ 0xff, 1, 2, 3, 4, 5, 6, 7, 8 }, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
}

test "pack zero runs" {
    var one_word: [8]u8 = @splat(0);
    try expectPack(&.{ 0x00, 0x00 }, &one_word);

    var two_words: [16]u8 = @splat(0);
    try expectPack(&.{ 0x00, 0x01 }, &two_words);

    var max_run: [8 * 256]u8 = @splat(0);
    try expectPack(&.{ 0x00, 0xff }, &max_run);

    var over_max_run: [8 * 257]u8 = @splat(0);
    try expectPack(&.{ 0x00, 0xff, 0x00, 0x00 }, &over_max_run);

    var run_then_words: [8 * 3]u8 = @splat(0);
    run_then_words[16..][0..8].* = .{ 1, 0, 0, 0, 0, 0, 0, 0 };
    try expectPack(&.{ 0x00, 0x01, 0x01, 0x01 }, &run_then_words);
}

test "pack rejects non-word-aligned input" {
    var buffer: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try testing.expectError(packing.PackedError.InvalidPacked, packing.pack(&writer, &.{0}));
    try testing.expectError(packing.PackedError.InvalidPacked, packing.pack(&writer, "hello"));
}

test "unpack expands zero runs" {
    var one_word: [8]u8 = @splat(0);
    try expectUnpack(&one_word, &.{ 0x00, 0x00 });

    var two_words: [16]u8 = @splat(0);
    try expectUnpack(&two_words, &.{ 0x00, 0x01 });

    var max_run: [8 * 256]u8 = @splat(0);
    try expectUnpack(&max_run, &.{ 0x00, 0xff });
}

test "unpack rejects truncated input" {
    var buffer: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try testing.expectError(packing.PackedError.InvalidPacked, packing.unpack(&writer, &.{0x00}));
    try testing.expectError(packing.PackedError.InvalidPacked, packing.unpack(&writer, &.{0x01}));
    try testing.expectError(packing.PackedError.InvalidPacked, packing.unpack(&writer, &.{ 0x81, 0x01 }));
}

test "messageSize reads only the message header" {
    try testing.expectEqual(date_raw.len, try packing.messageSize(&date_packed));
    try testing.expectEqual(unions_raw.len, try packing.messageSize(&unions_packed));

    // Two segments of 1 and 2 words: 16-byte padded header + 8 + 16 bytes.
    try testing.expectEqual(
        @as(usize, 40),
        try packing.messageSize(&.{ 0x11, 0x01, 0x01, 0x01, 0x02 }),
    );

    // Four zero-length segments: zero-run compressed header padding.
    try testing.expectEqual(
        @as(usize, 24),
        try packing.messageSize(&.{ 0x01, 0x03, 0x00, 0x01 }),
    );

    try testing.expectError(packing.PackedError.InvalidPacked, packing.messageSize(&.{}));
    try testing.expectError(
        packing.PackedError.InvalidPacked,
        packing.messageSize(&.{ 0x11, 0x01, 0x01 }),
    );
}

test "packed vectors from capnp" {
    try expectPack(&date_packed, &date_raw);
    try expectUnpack(&date_raw, &date_packed);

    try expectPack(&unions_packed, &unions_raw);
    try expectUnpack(&unions_raw, &unions_packed);
}

test "packed round-trip" {
    try expectRoundTrip(&date_raw);
    try expectRoundTrip(&unions_raw);

    var zero_run: [8 * 257]u8 = @splat(0);
    try expectRoundTrip(&zero_run);

    var mixed: [8 * 3]u8 = @splat(0);
    mixed[0..8].* = .{ 1, 0, 2, 0, 3, 0, 4, 0 };
    mixed[16..][0..8].* = .{ 0, 0, 0, 0, 0, 0, 0, 1 };
    try expectRoundTrip(&mixed);
}
