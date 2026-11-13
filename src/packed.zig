const std = @import("std");

/// Errors produced while decoding or encoding Cap'n Proto packed data.
pub const PackedError = error{
    InvalidPacked,
    SizeOverflow,
};

const BLOCK_WORDS = 4;
const BLOCK_BYTES = BLOCK_WORDS * 8;
const BLOCK_VECTOR = @Vector(BLOCK_BYTES, u8);
const WORD_VECTOR = @Vector(8, u8);

const WordIterator = struct {
    input: []const u8,
    offset: usize = 0,
    zero_words: u32 = 0,

    fn next(self: *WordIterator) PackedError!?[8]u8 {
        if (self.zero_words != 0) {
            self.zero_words -= 1;
            return @as([8]u8, @splat(0));
        }

        if (self.offset >= self.input.len) return null;

        const tag = self.input[self.offset];
        self.offset += 1;

        if (tag == 0) {
            if (self.offset >= self.input.len) return PackedError.InvalidPacked;
            const count = @as(u32, self.input[self.offset]) + 1;
            self.offset += 1;
            self.zero_words = count - 1;
            return @as([8]u8, @splat(0));
        }

        var word: [8]u8 = @splat(0);
        for (0..8) |index| {
            const bit: u3 = @intCast(index);
            if ((tag & (@as(u8, 1) << bit)) != 0) {
                if (self.offset >= self.input.len) return PackedError.InvalidPacked;
                word[index] = self.input[self.offset];
                self.offset += 1;
            }
        }
        return word;
    }
};

fn blockMask(bytes: []const u8) u32 {
    const block: BLOCK_VECTOR = bytes[0..BLOCK_BYTES].*;
    return @bitCast(block != @as(BLOCK_VECTOR, @splat(0)));
}

fn wordTag(word: []const u8) u8 {
    const value: WORD_VECTOR = word[0..8].*;
    return @bitCast(value != @as(WORD_VECTOR, @splat(0)));
}

fn tagFromMask(mask: u32, index: usize) u8 {
    const shift: u5 = @intCast(index * 8);
    return @truncate(mask >> shift);
}

fn writePackedWord(writer: *std.Io.Writer, word: []const u8, tag: u8) !void {
    var output: [9]u8 = undefined;
    output[0] = tag;
    var len: usize = 1;

    if (tag == 0xff) {
        @memcpy(output[1..9], word[0..8]);
        len = 9;
    } else {
        var bits = tag;
        while (bits != 0) {
            const index: u3 = @intCast(@ctz(bits));
            output[len] = word[index];
            len += 1;
            bits &= bits - 1;
        }
    }

    try writer.writeAll(output[0..len]);
}

fn writeZeroRun(writer: *std.Io.Writer, bytes: []const u8, start: usize) !usize {
    var count: usize = 1;
    var offset = start + 8;

    while (count < 256) {
        const remaining = 256 - count;
        if (remaining >= BLOCK_WORDS and offset + BLOCK_BYTES <= bytes.len) {
            if (blockMask(bytes[offset..]) == 0) {
                count += BLOCK_WORDS;
                offset += BLOCK_BYTES;
                continue;
            }
        }

        if (offset + 8 > bytes.len) break;
        if (@as(u64, @bitCast(bytes[offset..][0..8].*)) != 0) break;

        count += 1;
        offset += 8;
    }

    const run = [2]u8{ 0, @intCast(count - 1) };
    try writer.writeAll(&run);
    return offset;
}

/// Pack a standard Cap'n Proto message byte stream into `writer`.
///
/// `bytes` must be word-aligned, as all serialized Cap'n Proto messages are.
pub fn pack(writer: *std.Io.Writer, bytes: []const u8) (PackedError || std.Io.Writer.Error)!void {
    if (bytes.len % 8 != 0) return PackedError.InvalidPacked;

    var offset: usize = 0;

    while (offset + BLOCK_BYTES <= bytes.len) {
        const mask = blockMask(bytes[offset..]);
        if (mask == 0) {
            offset = try writeZeroRun(writer, bytes, offset);
            continue;
        }

        var word_index: usize = 0;
        while (word_index < BLOCK_WORDS) : (word_index += 1) {
            const tag = tagFromMask(mask, word_index);
            if (tag == 0) {
                offset = try writeZeroRun(writer, bytes, offset);
                break;
            }

            try writePackedWord(writer, bytes[offset..][0..8], tag);
            offset += 8;
        }
    }

    while (offset < bytes.len) {
        const word = bytes[offset..][0..8];
        const tag = wordTag(word);
        if (tag == 0) {
            offset = try writeZeroRun(writer, bytes, offset);
        } else {
            try writePackedWord(writer, word, tag);
            offset += 8;
        }
    }
}

/// Unpack a Cap'n Proto packed byte stream into `writer`.
///
/// There is no fixed maximum output size.
pub fn unpack(writer: *std.Io.Writer, input: []const u8) (PackedError || std.Io.Writer.Error)!void {
    var offset: usize = 0;

    while (offset < input.len) {
        const tag = input[offset];
        offset += 1;

        if (tag == 0) {
            if (offset >= input.len) return PackedError.InvalidPacked;
            const count = @as(usize, input[offset]) + 1;
            offset += 1;
            try writer.splatByteAll(0, count * 8);
            continue;
        }

        if (tag == 0xff) {
            if (input.len - offset < 8) return PackedError.InvalidPacked;
            try writer.writeAll(input[offset..][0..8]);
            offset += 8;
            continue;
        }

        var word: [8]u8 = @splat(0);
        var bits = tag;
        while (bits != 0) {
            const index: u3 = @intCast(@ctz(bits));
            if (offset >= input.len) return PackedError.InvalidPacked;
            word[index] = input[offset];
            offset += 1;
            bits &= bits - 1;
        }
        try writer.writeAll(&word);
    }
}

/// Decode only the standard message header and return the exact unpacked
/// message size in bytes.
///
/// This can be used to size a fixed output sink before calling `unpack`.
pub fn messageSize(input: []const u8) PackedError!usize {
    var words = WordIterator{ .input = input };
    const first = (try words.next()) orelse return PackedError.InvalidPacked;

    const segment_count_minus_one = std.mem.readInt(u32, first[0..4], .little);
    const segment_count: u64 = @as(u64, segment_count_minus_one) + 1;

    const table_bytes = std.math.mul(u64, segment_count, 4) catch return PackedError.SizeOverflow;
    const header_bytes = std.math.add(u64, table_bytes, 4) catch return PackedError.SizeOverflow;
    const header_words = std.math.add(u64, header_bytes, 7) catch return PackedError.SizeOverflow;
    const header_word_count = header_words / 8;
    var total = std.math.mul(u64, header_word_count, 8) catch return PackedError.SizeOverflow;

    var segment_index: u64 = 0;
    if (segment_index < segment_count) {
        const segment_words = std.mem.readInt(u32, first[4..8], .little);
        total = std.math.add(u64, total, @as(u64, segment_words) * 8) catch return PackedError.SizeOverflow;
        segment_index += 1;
    }

    var remaining_header_words = header_word_count - 1;
    while (remaining_header_words > 0) : (remaining_header_words -= 1) {
        const word = (try words.next()) orelse return PackedError.InvalidPacked;

        if (segment_index < segment_count) {
            const segment_words = std.mem.readInt(u32, word[0..4], .little);
            total = std.math.add(u64, total, @as(u64, segment_words) * 8) catch return PackedError.SizeOverflow;
            segment_index += 1;
        }

        if (segment_index < segment_count) {
            const segment_words = std.mem.readInt(u32, word[4..8], .little);
            total = std.math.add(u64, total, @as(u64, segment_words) * 8) catch return PackedError.SizeOverflow;
            segment_index += 1;
        }
    }

    if (segment_index != segment_count) return PackedError.InvalidPacked;
    return std.math.cast(usize, total) orelse PackedError.SizeOverflow;
}
