//! Regression / bug-hunting tests for `capnp.zig`.
//!
//! Tests are grouped in three sections:
//!
//!   A. Regressions that should pass today.
//!   B. Behavioural bugs that fail (no panic) against the current code.
//!   C. Crashes. These currently panic instead of returning an error or a
//!      sensible default. They are at the end of the file so that a normal
//!      run reports all of section A/B before hitting the first panic. Use
//!      `TEST_FILTER=<name>` to run one crash test at a time.
//!
//! Every test constructs its message by hand; none of them need files on
//! disk or the `Message.fromFile` API.

const std = @import("std");
const capnp = @import("capnp.zig");

const testing = std.testing;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn writeWord(segment: []u8, word_index: usize, value: u64) void {
    std.mem.writeInt(u64, segment[word_index * 8 ..][0..8], value, .little);
}

fn structPointer(offset_words: i30, data_words: u16, ptr_words: u16) u64 {
    return @bitCast(capnp.Ptr.Struct{
        .offset_words = offset_words,
        .data_words = data_words,
        .ptr_words = ptr_words,
    });
}

fn listPointer(offset_words: i30, element_size: u3, elements_or_words: u29) u64 {
    return @bitCast(capnp.Ptr.List{
        .offset_words = offset_words,
        .element_size = element_size,
        .elements_or_words = elements_or_words,
    });
}

fn farPointer(segment: u32, offset_words: u29, double: bool) u64 {
    return @bitCast(capnp.Ptr.InterSegment{
        .double = double,
        .offset = offset_words,
        .segment = segment,
    });
}

fn readContext(segments: [][]u8, counter: *capnp.Counter) capnp.ReadContext {
    return capnp.ReadContext.fromSegments(segments, counter);
}

/// Accepts any library error. Used where the exact error kind is an API choice.
fn expectAnyError(result: anytype) !void {
    if (result) |_| return error.TestExpectedError else |_| {}
}

// ---------------------------------------------------------------------------
// Test schemas (the minimum surface used by generated code)
// ---------------------------------------------------------------------------

const OneWord = struct {
    pub const _Metadata = capnp.StructMetadata{ .dataWords = 1, .ptrWords = 0 };

    pub const Reader = struct {
        reader: capnp.Struct.Reader,

        pub fn getValue(self: Reader) u64 {
            return self.reader.readIntField(u64, 0);
        }
    };

    pub const Builder = struct {
        builder: capnp.Struct.Builder,

        pub fn setValue(self: Builder, value: u64) void {
            self.builder.writeIntField(u64, 0, value);
        }
    };
};

const BigStruct = struct {
    pub const _Metadata = capnp.StructMetadata{ .dataWords = 9000, .ptrWords = 0 };

    pub const Reader = struct {
        reader: capnp.Struct.Reader,

        pub fn getValue(self: Reader) u64 {
            return self.reader.readIntField(u64, 0);
        }
    };

    pub const Builder = struct {
        builder: capnp.Struct.Builder,

        pub fn setValue(self: Builder, value: u64) void {
            self.builder.writeIntField(u64, 0, value);
        }
    };
};

const ByteListHolder = struct {
    pub const _Metadata = capnp.StructMetadata{ .dataWords = 0, .ptrWords = 1 };

    pub const Reader = struct {
        reader: capnp.Struct.Reader,

        pub fn getBytes(self: Reader) capnp.Error!capnp.List(u8).Reader {
            return self.reader.readPtrField(capnp.List(u8).Reader, 0);
        }
    };

    pub const Builder = struct {
        builder: capnp.Struct.Builder,

        pub fn getBytes(self: Builder) capnp.List(u8).Builder {
            return self.builder.buildPtrField(capnp.List(u8).Builder, 0);
        }
    };
};

const Item = struct {
    pub const _Metadata = capnp.StructMetadata{ .dataWords = 1, .ptrWords = 0 };

    pub const Reader = struct {
        reader: capnp.Struct.Reader,

        pub fn getValue(self: Reader) u64 {
            return self.reader.readIntField(u64, 0);
        }
    };

    pub const Builder = struct {
        builder: capnp.Struct.Builder,

        pub fn setValue(self: Builder, value: u64) void {
            self.builder.writeIntField(u64, 0, value);
        }
    };
};

const ItemListHolder = struct {
    pub const _Metadata = capnp.StructMetadata{ .dataWords = 0, .ptrWords = 1 };

    pub const Reader = struct {
        reader: capnp.Struct.Reader,

        pub fn getItems(self: Reader) capnp.Error!capnp.CompositeListReader(Item) {
            return self.reader.readPtrField(capnp.CompositeListReader(Item), 0);
        }
    };

    pub const Builder = struct {
        builder: capnp.Struct.Builder,

        pub fn getItems(self: Builder) capnp.CompositeListBuilder(Item) {
            return self.builder.buildPtrField(capnp.CompositeListBuilder(Item), 0);
        }
    };
};

const Empty = struct {
    pub const _Metadata = capnp.StructMetadata{ .dataWords = 0, .ptrWords = 0 };

    pub const Reader = struct {
        reader: capnp.Struct.Reader,
    };

    pub const Builder = struct {
        builder: capnp.Struct.Builder,
    };
};

const ZeroItem = struct {
    pub const _Metadata = capnp.StructMetadata{ .dataWords = 0, .ptrWords = 0 };

    pub const Reader = struct {
        reader: capnp.Struct.Reader,
    };

    pub const Builder = struct {
        builder: capnp.Struct.Builder,
    };
};

const Dummy = struct {
    pub const _Metadata = capnp.StructMetadata{ .dataWords = 0, .ptrWords = 0 };

    pub const Reader = struct {
        reader: capnp.Struct.Reader,
    };

    pub const Builder = struct {
        builder: capnp.Struct.Builder,
    };
};

// ===========================================================================
// A. Regressions that should pass against the current code
// ===========================================================================

test "regression: Ptr round-trips through u64" {
    const words = [_]u64{
        0,
        structPointer(0, 1, 2),
        structPointer(-1, 3, 4),
        listPointer(0, 2, 17),
        listPointer(-5, 7, 9000),
        farPointer(3, 42, false),
        farPointer(1, 0, true),
        // Capability pointer: type 3, reserved bits zero, index 7.
        (@as(u64, 7) << 32) | 3,
    };

    for (words) |word| {
        try testing.expectEqual(word, capnp.Ptr.of_u64(word).to_u64());
    }

    try testing.expect(capnp.Ptr.of_u64(0) == .null);
}

test "regression: writeBoolField preserves sibling bits" {
    var builder = capnp.MessageBuilder{ .allocator = testing.allocator };
    try builder.init();
    defer builder.deinit();

    var value = try builder.initRootStruct(OneWord);

    value.builder.writeBoolField(0, true);
    value.builder.writeBoolField(1, true);
    try testing.expectEqual(@as(u8, 0b11), value.builder.readIntField(u8, 0));

    value.builder.writeBoolField(0, false);
    try testing.expectEqual(@as(u8, 0b10), value.builder.readIntField(u8, 0));
}

test "regression: scalar fields beyond the data section read as zero" {
    var data: [16]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(0, 1, 0));
    writeWord(data[0..], 1, 0xffff_ffff_ffff_ffff);

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    // dataWords == 1, so offset 1 (8 bytes in) is outside the data section.
    try testing.expectEqual(@as(u64, 0), s.readIntField(u64, 1));
    try testing.expectEqual(false, s.readBoolField(64));
}

test "regression: null list pointer reads as an empty list" {
    var data: [16]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(0, 0, 1));
    // word 1 is the pointer field and is all zeros (null).

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    const list = try s.readPtrField(capnp.List(u8).Reader, 0);
    try testing.expectEqual(@as(u29, 0), list.length);
}

test "regression: primitive list indexing uses the element stride" {
    var data: [10 * 8]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(0, 0, 1));
    writeWord(data[0..], 1, listPointer(0, 4, 8)); // element size 4 => 32-bit

    for (0..8) |i| {
        const value: u32 = @intCast(i * 7);
        std.mem.writeInt(u32, data[16 + i * 4 ..][0..4], value, .little);
    }

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    const list = try s.readPtrField(capnp.List(u32).Reader, 0);
    try testing.expectEqual(@as(u29, 8), list.length);

    for (0..8) |i| {
        try testing.expectEqual(@as(u32, @intCast(i * 7)), list.get(@intCast(i)));
    }
}

// ===========================================================================
// B. Behavioural bugs: these fail without panicking
// ===========================================================================

test "BUG: readBoolField must mask the requested bit" {
    var data: [16]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(0, 1, 0));
    writeWord(data[0..], 1, 0b11); // bits 0 and 1 set

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    try testing.expectEqual(true, s.readBoolField(0));
    try testing.expectEqual(true, s.readBoolField(1));
    try testing.expectEqual(false, s.readBoolField(2));
}

test "BUG: Counter limit is exclusive" {
    var counter = capnp.Counter{ .limit = 10 };

    // A limit of 10 means "more than 10 is an error", so exactly 10 is fine.
    try counter.increment(10);
}

test "BUG: Counter permits a zero-sized increment at a zero limit" {
    var counter = capnp.Counter{ .limit = 0 };

    try counter.increment(0);
}

test "BUG: alloc must allow an allocation that exactly fits a segment" {
    var builder = capnp.MessageBuilder{ .allocator = testing.allocator };
    try builder.init();
    defer builder.deinit();

    // Segment 0 starts with 2^16 bytes = 8192 words of capacity.
    _ = try builder.alloc(0, 8192);

    try testing.expectEqual(@as(usize, 1), builder.segments.len);
}

test "BUG: struct pointer whose data section exceeds the segment is rejected" {
    var data: [16]u8 = @splat(0);
    // Claims 100 data words, but only one word follows the pointer.
    writeWord(data[0..], 0, structPointer(0, 100, 0));

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const context = readContext(segments[0..], &counter);

    try expectAnyError(capnp.StructReader.fromReadContext(context));
}

test "BUG: list pointer whose target exceeds the segment is rejected" {
    var data: [16]u8 = @splat(0);
    // 100 64-bit elements => 800 bytes, but the segment ends after the pointer.
    writeWord(data[0..], 0, listPointer(0, 5, 100));

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const context = readContext(segments[0..], &counter);

    try expectAnyError(capnp.List(u64).Reader.fromReadContext(context));
}

test "BUG: list traversal is not counted against the traversal limit" {
    var data: [1002 * 8]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(0, 0, 1));
    // 1000 64-bit elements following the list pointer.
    writeWord(data[0..], 1, listPointer(0, 5, 1000));

    var segments = [_][]u8{data[0..]};
    // Reading the root struct costs 1 word. The list costs 1000 words.
    var counter = capnp.Counter{ .limit = 16 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    try expectAnyError(s.readPtrField(capnp.List(u64).Reader, 0));
}

test "regression: void list counts elements against the traversal limit" {
    var data: [16]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(0, 0, 1));
    // 100,000 zero-sized elements, taking no wire space.
    writeWord(data[0..], 1, listPointer(0, 0, 100_000));

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 16 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    try expectAnyError(s.readPtrField(capnp.List(void).Reader, 0));
}

test "regression: zero-sized struct list counts elements against the traversal limit" {
    var data: [24]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(0, 0, 1));
    // Inline composite list with zero element words; the tag at word 2 says
    // there are 100,000 zero-sized elements.
    writeWord(data[0..], 1, listPointer(0, 7, 0));
    writeWord(data[0..], 2, structPointer(100_000, 0, 0));

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 16 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    try expectAnyError(s.readPtrField(capnp.CompositeListReader(ZeroItem), 0));
}

test "regression: text without a NUL terminator is rejected" {
    var data: [32]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(0, 0, 1));
    writeWord(data[0..], 1, listPointer(0, 2, 4));
    data[16] = 'a';
    data[17] = 'b';
    data[18] = 'c';
    data[19] = 'd';

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    try expectAnyError(s.readStringField(0));
}

test "regression: deeply nested structs hit the depth limit" {
    const nested_words = 100;
    var data: [nested_words * 8]u8 = @splat(0);

    for (0..nested_words - 1) |i| {
        writeWord(data[0..], i, structPointer(0, 0, 1)); // points at the next word
    }
    writeWord(data[0..], nested_words - 1, structPointer(-1, 0, 0));

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1_000_000 };
    var s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    var depth: u32 = 0;
    while (true) {
        const next = s.readPtrField(capnp.StructReader, 0) catch |err| {
            try testing.expect(err == capnp.Error.DepthLimitExceeded);
            break;
        };
        s = next;
        depth += 1;
    }

    // The root is depth 1; depths 2..64 are readable.
    try testing.expectEqual(@as(u32, 63), depth);
}

test "BUG: ReadContext custom format is not used by std.fmt (Zig 0.17)" {
    var data: [8]u8 = @splat(0xab);

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const context = readContext(segments[0..], &counter);

    const formatted = try std.fmt.allocPrint(testing.allocator, "{f}", .{context});
    defer testing.allocator.free(formatted);

    // The intended format is `{segments = 1, segment = 0, offsetWords = 0}`;
    // the default formatter dumps the segment bytes and field names.
    try testing.expect(std.mem.indexOf(u8, formatted, "segments =") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, ".segments") == null);
}

test "BUG: StructReader custom format is not used by std.fmt (Zig 0.17)" {
    var data: [16]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(0, 1, 0));

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    const formatted = try std.fmt.allocPrint(testing.allocator, "{f}", .{s});
    defer testing.allocator.free(formatted);

    try testing.expect(std.mem.indexOf(u8, formatted, "dataWords =") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, ".dataWords") == null);
}

// ===========================================================================
// C. Crash tests: these currently panic instead of returning an error
// ===========================================================================

test "BUG: Counter overflow is reported as a limit error, not an integer overflow" {
    var counter = capnp.Counter{
        .limit = std.math.maxInt(u32),
        .count = std.math.maxInt(u32) - 1,
    };

    try expectAnyError(counter.increment(2));
}

test "BUG: alloc spare-space computation must not underflow" {
    var builder = capnp.MessageBuilder{ .allocator = testing.allocator };
    try builder.init();
    defer builder.deinit();

    _ = try builder.alloc(0, 8192);

    const before = builder.segments.len;
    _ = try builder.alloc(1, 8193); // 65544 bytes: larger than any existing segment
    try testing.expectEqual(before + 1, builder.segments.len);
}

test "regression: alloc rejects word counts larger than a segment" {
    var builder = capnp.MessageBuilder{ .allocator = testing.allocator };
    try builder.init();
    defer builder.deinit();

    try expectAnyError(builder.alloc(0, std.math.maxInt(u32)));
}

test "regression: root struct larger than one segment must round-trip" {
    var builder = capnp.MessageBuilder{ .allocator = testing.allocator };
    try builder.init();
    defer builder.deinit();

    var value = try builder.initRootStruct(BigStruct);
    value.setValue(0xdead_beef);

    var message = builder.toReader();

    // The root pointer must be a single-far pointer to segment 1.
    const root_ptr = capnp.Ptr.of_u64(std.mem.readInt(u64, message.segments[0][0..8], .little));
    try testing.expect(root_ptr == .inter_segment);
    try testing.expectEqual(false, root_ptr.inter_segment.double);
    try testing.expectEqual(@as(u32, 1), root_ptr.inter_segment.segment);

    // Segment 1 word 0 is the landing pad: a struct pointer with offset 0.
    const pad_ptr = capnp.Ptr.of_u64(std.mem.readInt(u64, message.segments[1][0..8], .little));
    try testing.expect(pad_ptr == .struct_);
    try testing.expectEqual(@as(i30, 0), pad_ptr.struct_.offset_words);
    try testing.expectEqual(@as(u16, 9000), pad_ptr.struct_.data_words);

    const reader = try message.getRootStruct(BigStruct);
    try testing.expectEqual(@as(u64, 0xdead_beef), reader.getValue());
}

test "regression: empty lists round-trip at the end of a segment" {
    {
        var builder = capnp.MessageBuilder{ .allocator = testing.allocator };
        try builder.init();
        defer builder.deinit();

        var holder = try builder.initRootStruct(ByteListHolder);
        var bytes = holder.getBytes();
        try bytes.init(0);

        var message = builder.toReader();
        const reader = try message.getRootStruct(ByteListHolder);
        const list = try reader.getBytes();
        try testing.expectEqual(@as(u29, 0), list.length);
    }

    {
        var builder = capnp.MessageBuilder{ .allocator = testing.allocator };
        try builder.init();
        defer builder.deinit();

        var holder = try builder.initRootStruct(ItemListHolder);
        var items = holder.getItems();
        try items.init(0);

        var message = builder.toReader();
        const reader = try message.getRootStruct(ItemListHolder);
        const list = try reader.getItems();
        try testing.expectEqual(@as(u29, 0), list.length);
    }
}

test "regression: empty struct is encoded with offset -1" {
    var builder = capnp.MessageBuilder{ .allocator = testing.allocator };
    try builder.init();
    defer builder.deinit();

    _ = try builder.initRootStruct(Empty);

    var message = builder.toReader();
    const root_ptr = capnp.Ptr.of_u64(std.mem.readInt(u64, message.segments[0][0..8], .little));
    try testing.expect(root_ptr == .struct_);
    try testing.expectEqual(@as(i30, -1), root_ptr.struct_.offset_words);
    try testing.expectEqual(@as(u16, 0), root_ptr.struct_.data_words);
    try testing.expectEqual(@as(u16, 0), root_ptr.struct_.ptr_words);

    const reader = try message.getRootStruct(Empty);
    try testing.expectEqual(@as(u16, 0), reader.reader.data_words);
    try testing.expectEqual(@as(u16, 0), reader.reader.ptr_words);
}

test "BUG: byte list that crosses a segment must round-trip" {
    var builder = capnp.MessageBuilder{ .allocator = testing.allocator };
    try builder.init();
    defer builder.deinit();

    {
        var holder = try builder.initRootStruct(ByteListHolder);
        var list = holder.getBytes();
        try list.init(100_000);

        list.set(0, 0x12);
        list.set(99_999, 0x34);
    }

    var message = builder.toReader();
    const holder = try message.getRootStruct(ByteListHolder);
    const list = try holder.getBytes();

    try testing.expectEqual(@as(u29, 100_000), list.length);
    try testing.expectEqual(@as(u8, 0x12), list.get(0));
    try testing.expectEqual(@as(u8, 0x34), list.get(99_999));
}

test "BUG: composite list that crosses a segment must round-trip" {
    var builder = capnp.MessageBuilder{ .allocator = testing.allocator };
    try builder.init();
    defer builder.deinit();

    {
        var holder = try builder.initRootStruct(ItemListHolder);
        var list = holder.getItems();
        try list.init(20_000); // 20k words, larger than segment 0

        list.get(0).setValue(11);
        list.get(19_999).setValue(22);
    }

    var message = builder.toReader();
    const holder = try message.getRootStruct(ItemListHolder);
    const list = try holder.getItems();

    try testing.expectEqual(@as(u29, 20_000), list.length);
    try testing.expectEqual(@as(u64, 11), list.get(0).getValue());
    try testing.expectEqual(@as(u64, 22), list.get(19_999).getValue());
}

test "BUG: initRootStruct must not silently write the root pointer at a non-zero word" {
    var builder = capnp.MessageBuilder{ .allocator = testing.allocator };
    try builder.init();
    defer builder.deinit();

    // Occupy words 0..4. The root pointer normally has to live at word 0.
    _ = try builder.alloc(0, 4);

    if (builder.initRootStruct(OneWord)) |value| {
        value.setValue(42);

        var message = builder.toReader();
        const reader = try message.getRootStruct(OneWord);
        try testing.expectEqual(@as(u64, 42), reader.getValue());
    } else |_| {
        // Refusing to create a root pointer after other allocations is fine.
    }
}

test "BUG: null struct pointer must yield an empty struct" {
    var data: [8]u8 = @splat(0);

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const context = readContext(segments[0..], &counter);

    const s = try capnp.StructReader.fromReadContext(context);
    try testing.expectEqual(@as(u16, 0), s.data_words);
    try testing.expectEqual(@as(u16, 0), s.ptr_words);
    try testing.expectEqual(@as(u64, 0), s.readIntField(u64, 0));
}

test "regression: zero-sized struct uses offset -1, not null" {
    var data: [8]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(-1, 0, 0));

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    try testing.expectEqual(@as(u16, 0), s.data_words);
    try testing.expectEqual(@as(u16, 0), s.ptr_words);
    try testing.expectEqual(@as(u64, 0), s.readIntField(u64, 0));
}

test "BUG: struct pointer with maximal section sizes must not overflow" {
    var data: [16]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(0, 0xffff, 0xffff));

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = std.math.maxInt(u32) };
    var context = readContext(segments[0..], &counter);

    try expectAnyError(context.readPtr());
}

test "BUG: struct pointer with maximal offset must not overflow" {
    var data: [16]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(std.math.maxInt(i30), 0, 0));

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    var context = readContext(segments[0..], &counter);

    try expectAnyError(context.readPtr());
}

test "BUG: pointer whose target is before the segment must be rejected" {
    var data: [16]u8 = @splat(0);
    // offset -2 means target = pointer + 1 - 2 = -1.
    writeWord(data[0..], 0, structPointer(-2, 0, 0));

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    var context = readContext(segments[0..], &counter);

    try expectAnyError(context.readPtr());
}

test "BUG: far pointer with an out-of-range segment must be rejected" {
    var data: [8]u8 = @splat(0);
    writeWord(data[0..], 0, farPointer(7, 0, false));

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const context = readContext(segments[0..], &counter);

    try expectAnyError(capnp.StructReader.fromReadContext(context));
}

test "BUG: single-far pointer must be resolved through its landing pad" {
    var segment0: [8]u8 = @splat(0);
    var segment1: [16]u8 = @splat(0);

    writeWord(segment0[0..], 0, farPointer(1, 0, false));
    // Landing pad in segment 1, word 0: struct pointer to word 1.
    writeWord(segment1[0..], 0, structPointer(0, 1, 0));
    writeWord(segment1[0..], 1, 0x1234_5678);

    var segments = [_][]u8{ segment0[0..], segment1[0..] };
    var counter = capnp.Counter{ .limit = 1000 };
    const context = readContext(segments[0..], &counter);

    const s = try capnp.StructReader.fromReadContext(context);
    try testing.expectEqual(@as(u64, 0x1234_5678), s.readIntField(u64, 0));
}

test "regression: double-far pointer resolves to its content" {
    var segment0: [8]u8 = @splat(0);
    var segment1: [16]u8 = @splat(0);
    var segment2: [8]u8 = @splat(0);

    writeWord(segment0[0..], 0, farPointer(1, 0, true));
    // Double-far landing pad: word 0 points at the content, word 1 is the tag.
    writeWord(segment1[0..], 0, farPointer(2, 0, false));
    writeWord(segment1[0..], 1, structPointer(0, 1, 0));
    writeWord(segment2[0..], 0, 0xabcd_ef01);

    var segments = [_][]u8{ segment0[0..], segment1[0..], segment2[0..] };
    var counter = capnp.Counter{ .limit = 1000 };
    const context = readContext(segments[0..], &counter);

    const s = try capnp.StructReader.fromReadContext(context);
    try testing.expectEqual(@as(u64, 0xabcd_ef01), s.readIntField(u64, 0));
}

test "BUG: double-far pad word 0 must be a far pointer" {
    var segment0: [8]u8 = @splat(0);
    var segment1: [16]u8 = @splat(0);

    writeWord(segment0[0..], 0, farPointer(1, 0, true));
    // word 0 is null instead of a far pointer.
    writeWord(segment1[0..], 1, structPointer(0, 1, 0));

    var segments = [_][]u8{ segment0[0..], segment1[0..] };
    var counter = capnp.Counter{ .limit = 1000 };
    const context = readContext(segments[0..], &counter);

    try expectAnyError(capnp.StructReader.fromReadContext(context));
}

test "BUG: far pointer landing pad beyond the segment must be rejected" {
    var data: [8]u8 = @splat(0);
    writeWord(data[0..], 0, farPointer(0, 1, false)); // pad is word 1, but only word 0 exists

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    var context = readContext(segments[0..], &counter);

    try expectAnyError(context.readPtr());
}

test "BUG: missing pointer field must read as a null pointer" {
    var data: [16]u8 = @splat(0);
    // Non-null struct with one data word but no pointer words. (An all-zero
    // struct pointer word is the null pointer, so dataWords must be non-zero.)
    writeWord(data[0..], 0, structPointer(0, 1, 0));
    writeWord(data[0..], 1, 0xffff_ffff_ffff_ffff);

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    const list = try s.readPtrField(capnp.List(u8).Reader, 0);
    try testing.expectEqual(@as(u29, 0), list.length);
}

test "BUG: readStringField on a non-list pointer must be an error" {
    var data: [24]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(0, 0, 1)); // root struct, one pointer
    writeWord(data[0..], 1, structPointer(0, 1, 0)); // pointer field points at a struct
    writeWord(data[0..], 2, 1);

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    try expectAnyError(s.readStringField(0));
}

test "BUG: text length beyond the segment must be an error" {
    var data: [16]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(0, 0, 1)); // root struct, one pointer
    writeWord(data[0..], 1, listPointer(0, 2, 100)); // 100-byte text, target out of segment

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    try expectAnyError(s.readStringField(0));
}

test "BUG: list element size must be validated against the requested type" {
    var data: [24]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(0, 0, 1));
    // element size 5 == 8-byte elements, but we will read it as List(u8).
    writeWord(data[0..], 1, listPointer(0, 5, 1));
    writeWord(data[0..], 2, 0);

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    try expectAnyError(s.readPtrField(capnp.List(u8).Reader, 0));
}

test "BUG: composite list with a non-struct tag must be an error" {
    var data: [32]u8 = @splat(0);
    writeWord(data[0..], 0, structPointer(0, 0, 1));
    // element size 7 == inline composite, one word of content, followed by
    // the tag word at word 2.
    writeWord(data[0..], 1, listPointer(0, 7, 1));
    // word 2 is the tag word and is zero (null), not a struct pointer.

    var segments = [_][]u8{data[0..]};
    var counter = capnp.Counter{ .limit = 1000 };
    const s = try capnp.StructReader.fromReadContext(readContext(segments[0..], &counter));

    try expectAnyError(s.readPtrField(capnp.CompositeListReader(Dummy), 0));
}

test "BUG: ListBuilder.init can be called twice without an error" {
    var builder = capnp.MessageBuilder{ .allocator = testing.allocator };
    try builder.init();
    defer builder.deinit();

    var holder = try builder.initRootStruct(ByteListHolder);
    var list = holder.getBytes();

    try list.init(4);
    try expectAnyError(list.init(4));
}
