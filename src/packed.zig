const std = @import("std");

/// Errors produced while decoding or encoding Cap'n Proto packed data.
pub const PackedError = error{
    InvalidPacked,
    SizeOverflow,
};

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

/// Pack a standard Cap'n Proto message byte stream into `writer`.
///
/// `bytes` must be word-aligned, as all serialized Cap'n Proto messages are.
pub fn pack(writer: *std.Io.Writer, bytes: []const u8) (PackedError || std.Io.Writer.Error)!void {
    if (bytes.len % 8 != 0) return PackedError.InvalidPacked;

    var offset: usize = 0;
    while (offset < bytes.len) {
        const word = bytes[offset..][0..8];

        if (allZero(word)) {
            var count: usize = 1;
            var next = offset + 8;
            while (count < 256 and next + 8 <= bytes.len) {
                if (!allZero(bytes[next..][0..8])) break;
                count += 1;
                next += 8;
            }

            try writer.writeByte(0);
            try writer.writeByte(@intCast(count - 1));
            offset = next;
            continue;
        }

        var tag: u8 = 0;
        for (word, 0..) |byte, index| {
            if (byte != 0) {
                const bit: u3 = @intCast(index);
                tag |= @as(u8, 1) << bit;
            }
        }

        try writer.writeByte(tag);
        for (word, 0..) |byte, index| {
            const bit: u3 = @intCast(index);
            if ((tag & (@as(u8, 1) << bit)) != 0) {
                try writer.writeByte(byte);
            }
        }

        offset += 8;
    }
}

/// Unpack a Cap'n Proto packed byte stream into `writer`.
///
/// There is no fixed maximum output size.
pub fn unpack(writer: *std.Io.Writer, input: []const u8) (PackedError || std.Io.Writer.Error)!void {
    var words = WordIterator{ .input = input };
    while (try words.next()) |word| {
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

fn allZero(word: []const u8) bool {
    for (word) |byte| {
        if (byte != 0) return false;
    }
    return true;
}
