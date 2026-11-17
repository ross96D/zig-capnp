const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const packing = @import("packed.zig");

pub const Ptr = union(enum) {
    pub const Struct = packed struct(u64) {
        type: u2 = 0,
        offset_words: i30,
        data_words: u16,
        ptr_words: u16,
    };
    pub const List = packed struct(u64) {
        type: u2 = 1,
        offset_words: i30,
        element_size: u3,
        elements_or_words: u29,
    };
    pub const InterSegment = packed struct(u64) {
        type: u2 = 2,
        double: bool,
        offset: u29,
        segment: u32,
    };
    pub const Capability = packed struct(u64) {
        type: u2 = 3,
        _: u30,
        index: u32,
    };
    const Type = packed struct(u64) {
        type: u2,
        _: u62,
    };
    null: void,
    struct_: Ptr.Struct,
    list: Ptr.List,
    inter_segment: Ptr.InterSegment,
    capability: Ptr.Capability,

    pub fn of_u64(ptr: u64) Ptr {
        if (ptr == 0) {
            return Ptr.null;
        }
        return switch (@as(Ptr.Type, @bitCast(ptr)).type) {
            0 => Ptr{ .struct_ = @bitCast(ptr) },
            1 => Ptr{ .list = @bitCast(ptr) },
            2 => Ptr{ .inter_segment = @bitCast(ptr) },
            3 => Ptr{ .capability = @bitCast(ptr) },
        };
    }

    pub fn to_u64(ptr: Ptr) u64 {
        var ptr_ = ptr;

        switch (ptr_) {
            .struct_ => |*struct_| {
                struct_.type = 0;
                return @bitCast(struct_.*);
            },
            .list => |*list| {
                list.type = 1;
                return @bitCast(list.*);
            },
            .inter_segment => |*inter_segment| {
                inter_segment.type = 2;
                return @bitCast(inter_segment.*);
            },
            .capability => |*capability| {
                capability.type = 3;
                return @bitCast(capability.*);
            },
            .null => {
                return 0;
            },
        }
    }
};

pub const Error = error{
    LimitExceeded,
    OutOfBounds,
    InvalidPointer,
    OffsetOverflow,
    TypeMismatch,
    TraversalLimitExceeded,
    DepthLimitExceeded,
    MessageTooLarge,
    SegmentLimitReached,
    RootAlreadyInitialized,
    NotInitialized,
    AlreadyInitialized,
    InvalidText,
    NoSpaceLeft,
};

pub const BuildError = Allocator.Error || Error;

pub const Counter = struct {
    count: u32 = 0,
    limit: u32,

    pub fn increment(self: *Counter, x: u32) Error!void {
        self.count = std.math.add(u32, self.count, x) catch return Error.LimitExceeded;

        if (self.count > self.limit) {
            return Error.LimitExceeded;
        }
    }
};

pub const ReadContext = struct {
    segments: []const []const u8,
    segment: u32,
    offset_words: u29,

    depth_counter: Counter = Counter{ .limit = 64 },
    traversal_counter: *Counter,

    pub fn offsetBytes(self: ReadContext) u32 {
        return self.offset_words << 3;
    }

    fn readWordAt(self: ReadContext, segment: u32, word: u32) Error!u64 {
        // TODO maybe change this to a panic because maybe is best to keep read
        // as an error free.
        if (segment >= self.segments.len) return Error.InvalidPointer;
        const seg = self.segments[segment];
        const pos: u64 = @as(u64, word) * 8;
        // TODO maybe change this to a panic because maybe is best to keep read
        // as an error free.
        if (pos + 8 > seg.len) return Error.OutOfBounds;
        return std.mem.readInt(u64, seg[@intCast(pos)..][0..8], .little);
    }

    /// Validates that [start_word, start_word + words) is inside `segment`.
    /// Zero-sized objects are allowed to sit at the end of a segment.
    fn checkObject(self: ReadContext, segment: u32, start_word: u32, words: u32) Error!u29 {
        if (segment >= self.segments.len) return Error.InvalidPointer;

        const start: u64 = @intCast(start_word);
        const segment_words: u64 = self.segments[segment].len / 8;
        if (start > segment_words) return Error.OutOfBounds;
        // substract to avoid overflow
        if (words > segment_words - start) return Error.OutOfBounds;
        if (start > std.math.maxInt(u29)) return Error.InvalidPointer;

        return @intCast(start);
    }

    pub fn readIntWithBound(self: ReadContext, comptime T: type, offset: u32, bound_words: u29) T {
        // Check the declared data-section bound first. This must not touch the
        // segment, so empty structs can be read through a dummy context.
        if (@as(u64, @sizeOf(T)) * offset >= (@as(u64, bound_words) << 3)) return 0;
        if (self.segment >= self.segments.len) return 0;

        const pos: u64 = @as(u64, self.offset_words) * 8 + @as(u64, @sizeOf(T)) * offset;
        const seg = self.segments[self.segment];
        if (pos + @sizeOf(T) > seg.len) return 0;

        return std.mem.readInt(T, seg[@intCast(pos)..][0..@sizeOf(T)], .little);
    }

    pub fn readInt(self: ReadContext, comptime T: type, offset: u32) T {
        const pos = self.offsetBytes() + @sizeOf(T) * offset;
        return std.mem.readInt(T, self.segments[self.segment][pos..][0..@sizeOf(T)], .little);
    }

    pub fn readPtrN(self: ReadContext) Error!Ptr {
        return Ptr.of_u64(try self.readWordAt(self.segment, self.offset_words));
    }

    pub fn readPtr(self: *ReadContext) Error!Ptr {
        var hops: u8 = 0;

        while (true) {
            hops += 1;
            if (hops > 2) return Error.InvalidPointer;

            const raw = try self.readPtrN();

            var tag: Ptr = undefined;
            var content_segment: u32 = 0;
            var content_word_offset: u32 = 0;

            switch (raw) {
                .null, .capability => return raw,
                .inter_segment => |far| {
                    if (far.segment >= self.segments.len) return Error.InvalidPointer;

                    const pad_words: u64 = if (far.double) 2 else 1;
                    const segment_words: u64 = self.segments[far.segment].len / 8;
                    if (@as(u64, far.offset) + pad_words > segment_words) return Error.OutOfBounds;

                    if (!far.double) {
                        // The landing pad is a normal pointer relative to itself.
                        self.segment = far.segment;
                        self.offset_words = far.offset;
                        continue;
                    }

                    // Double-far: word 0 points at the content, word 1 is a tag.
                    const far_content = Ptr.of_u64(try self.readWordAt(far.segment, far.offset));
                    switch (far_content) {
                        .inter_segment => |target| {
                            if (target.double) return Error.InvalidPointer;
                            if (target.segment >= self.segments.len) return Error.InvalidPointer;
                            content_segment = target.segment;
                            content_word_offset = target.offset;
                        },
                        else => return Error.InvalidPointer,
                    }

                    tag = Ptr.of_u64(try self.readWordAt(far.segment, @as(u32, far.offset) + 1));
                },
                .struct_ => |s| {
                    content_segment = self.segment;
                    const tmp = @as(i32, self.offset_words) + 1 + @as(i32, s.offset_words);
                    if (tmp < 0) return Error.InvalidPointer;
                    content_word_offset = @intCast(tmp);
                    tag = raw;
                },
                .list => |l| {
                    content_segment = self.segment;
                    const tmp = @as(i32, self.offset_words) + 1 + @as(i32, l.offset_words);
                    if (tmp < 0) return Error.InvalidPointer;
                    content_word_offset = @intCast(tmp);
                    tag = raw;
                },
            }

            switch (tag) {
                .struct_ => |s| {
                    const words = @as(u32, s.data_words) + s.ptr_words;
                    const word = try self.checkObject(content_segment, content_word_offset, words);

                    self.depth_counter.increment(1) catch return Error.DepthLimitExceeded;
                    self.traversal_counter.increment(words) catch return Error.TraversalLimitExceeded;

                    self.segment = content_segment;
                    self.offset_words = word;

                    return Ptr{
                        .struct_ = .{
                            .offset_words = 0,
                            .data_words = s.data_words,
                            .ptr_words = s.ptr_words,
                        },
                    };
                },
                .list => |l| {
                    const words: u32 = switch (l.element_size) {
                        0 => 0,
                        1 => (std.math.add(u32, l.elements_or_words, 63) catch unreachable) / 64,
                        2 => (std.math.add(u32, l.elements_or_words, 7) catch unreachable) / 8,
                        3 => (std.math.add(u32, l.elements_or_words, 3) catch unreachable) / 4,
                        4 => (std.math.add(u32, l.elements_or_words, 1) catch unreachable) / 2,
                        5, 6 => l.elements_or_words,
                        7 => std.math.add(u32, 1, l.elements_or_words) catch unreachable,
                    };
                    const word = try self.checkObject(content_segment, content_word_offset, words);

                    // Void/zero-sized elements occupy no wire space, but they
                    // count as one word each for traversal-limit purposes.
                    const traversal_words: u32 =
                        if (l.element_size == 0) l.elements_or_words else words;

                    self.depth_counter.increment(1) catch return Error.DepthLimitExceeded;
                    self.traversal_counter.increment(traversal_words) catch return Error.TraversalLimitExceeded;

                    self.segment = content_segment;
                    self.offset_words = word;

                    return Ptr{ .list = .{
                        .offset_words = 0,
                        .element_size = l.element_size,
                        .elements_or_words = l.elements_or_words,
                    } };
                },
                else => return Error.InvalidPointer,
            }
        }
    }

    pub fn readString(self: ReadContext, length: u32) Error![:0]const u8 {
        if (length == 0) return "";
        if (self.segment >= self.segments.len) return Error.InvalidPointer;

        const start: u64 = @as(u64, self.offset_words) * 8;
        const seg = self.segments[self.segment];
        if (start + length > seg.len) return Error.OutOfBounds;

        const text = seg[@intCast(start)..][0..length];
        if (text[length - 1] != 0) return Error.InvalidText;
        return text[0 .. length - 1 :0];
    }

    /// Read a raw byte blob. Unlike text, data is not NUL-terminated.
    pub fn readData(self: ReadContext, length: u32) Error![]const u8 {
        if (length == 0) return "";
        if (self.segment >= self.segments.len) return Error.InvalidPointer;

        const start: u64 = @as(u64, self.offset_words) * 8;
        const seg = self.segments[self.segment];
        if (start + length > seg.len) return Error.OutOfBounds;

        return seg[@intCast(start)..][0..length];
    }

    pub fn fromSegments(segments: []const []const u8, traversal_counter: *Counter) ReadContext {
        return ReadContext{
            .segments = segments,
            .segment = 0,
            .offset_words = 0,
            .traversal_counter = traversal_counter,
        };
    }

    pub fn format(self: ReadContext, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{{segments = {}, segment = {}, offset_words = {}}}", .{ self.segments.len, self.segment, self.offset_words });
    }
};

const ELEMENTS: usize = 1;
const BITS: usize = 1;
const WORDS: usize = 1;
const BYTES: usize = 1;

pub const AnyPointerReader = struct {
    context: ReadContext,
    ptr: Ptr,

    pub fn fromReadContext(context: ReadContext) Error!AnyPointerReader {
        var _context = context;
        const ptr = try _context.readPtr();

        return AnyPointerReader{
            .context = _context,
            .ptr = ptr,
        };
    }

    pub fn fromNull(context: ReadContext) AnyPointerReader {
        return .{ .context = context, .ptr = .null };
    }

    pub fn asStruct(self: AnyPointerReader, comptime T: type, comptime trait: ReaderTrait(T)) Error!T {
        return switch (self.ptr) {
            .struct_ => |s| trait.reader(.{
                .context = self.context,
                .data_words = s.data_words,
                .ptr_words = s.ptr_words,
            }),
            .null => trait.reader(StructReader.fromNull(self.context)),
            else => Error.TypeMismatch,
        };
    }

    pub fn asList(self: AnyPointerReader, comptime T: type) Error!ListReader(T) {
        return switch (self.ptr) {
            .list => |list| ListReader(T).fromPtr(self.context, list),
            .null => ListReader(T).fromNull(self.context),
            else => Error.TypeMismatch,
        };
    }

    pub fn asCompositeList(self: AnyPointerReader, comptime T: type, comptime trait: ReaderTrait(T)) Error!CompositeListReader(T, trait) {
        return switch (self.ptr) {
            .list => |list| CompositeListReader(T, trait).fromPtr(self.context, list),
            .null => CompositeListReader(T, trait).empty,
            else => Error.TypeMismatch,
        };
    }

    pub fn asText(self: AnyPointerReader) Error![:0]const u8 {
        return switch (self.ptr) {
            .list => |list| (try ListReader(u8).fromPtr(self.context, list)).getString(),
            .null => "",
            else => Error.TypeMismatch,
        };
    }

    pub fn asData(self: AnyPointerReader) Error![]const u8 {
        return switch (self.ptr) {
            .list => |list| (try ListReader(u8).fromPtr(self.context, list)).getData(),
            .null => "",
            else => Error.TypeMismatch,
        };
    }

    pub fn asCapability(self: AnyPointerReader) Error!u32 {
        return switch (self.ptr) {
            .capability => |capability| capability.index,
            else => Error.TypeMismatch,
        };
    }
};

pub const AnyPointerBuilder = struct {
    context: BuildContext,

    pub fn fromBuildContext(context: BuildContext) AnyPointerBuilder {
        return .{ .context = context };
    }

    pub fn initStruct(self: AnyPointerBuilder, comptime T: type, comptime trait: BuilderTrait(T)) BuildError!T {
        var ptr = self.context;
        return trait.builder(try ptr.allocStruct(trait.data_words, trait.ptr_words));
    }

    pub fn initList(self: AnyPointerBuilder, comptime T: type) ListBuilder(T) {
        return ListBuilder(T).fromBuildContext(self.context);
    }

    pub fn initCompositeList(self: AnyPointerBuilder, comptime T: type, comptime trait: BuilderTrait(T)) CompositeListBuilder(T, trait) {
        return CompositeListBuilder(T, trait).fromBuildContext(self.context);
    }

    pub fn setText(self: AnyPointerBuilder, value: [:0]const u8) BuildError!void {
        var list = ListBuilder(u8).fromBuildContext(self.context);
        try list.init(@intCast(value.len + 1));
        for (value, 0..) |byte, i| list.set(@intCast(i), byte);
        list.set(@intCast(value.len), 0);
    }

    pub fn setData(self: AnyPointerBuilder, value: []const u8) BuildError!void {
        var list = ListBuilder(u8).fromBuildContext(self.context);
        try list.init(@intCast(value.len));
        for (value, 0..) |byte, i| list.set(@intCast(i), byte);
    }

    pub fn setFromReader(self: AnyPointerBuilder, source: AnyPointerReader) BuildError!void {
        var context = self.context;
        try context.builder.copyPointerTo(&context, source);
    }

    /// Copy a pointer graph while preserving capability pointer indices.
    /// The caller must also copy/translate the source capability table.
    pub fn setFromReaderWithCaps(self: AnyPointerBuilder, source: AnyPointerReader) BuildError!void {
        var context = self.context;
        try context.builder.copyPointerToWithCaps(&context, source);
    }

    pub fn setCapability(self: AnyPointerBuilder, index: u32) void {
        var context = self.context;
        const raw: u64 = 3 | (@as(u64, index) << 32);
        context.writePtr(Ptr{ .capability = @bitCast(raw) });
    }

    pub fn clear(self: AnyPointerBuilder) void {
        var context = self.context;
        context.writePtr(.null);
    }
};

pub const AnyPointerListReader = struct {
    context: ReadContext,
    length: u29,

    pub fn fromReadContext(context: ReadContext) Error!AnyPointerListReader {
        var _context = context;
        switch (try _context.readPtr()) {
            .null => return .{ .context = context, .length = 0 },
            .list => |list| {
                if (list.element_size != 6) return Error.TypeMismatch;
                return .{ .context = _context, .length = list.elements_or_words };
            },
            else => return Error.TypeMismatch,
        }
    }

    pub fn fromNull(context: ReadContext) AnyPointerListReader {
        return .{ .context = context, .length = 0 };
    }

    pub fn get(self: AnyPointerListReader, index: u32) Error!AnyPointerReader {
        std.debug.assert(index < self.length);
        var context = self.context;
        context.offset_words = @intCast(@as(u64, context.offset_words) + index);
        return AnyPointerReader.fromReadContext(context);
    }
};

pub const AnyPointerListBuilder = struct {
    ptr: BuildContext,
    context: ?BuildContext,
    length: u29,

    pub fn fromBuildContext(ptr: BuildContext) AnyPointerListBuilder {
        std.debug.assert(ptr.readInt(u64, 0) == 0);
        return .{ .ptr = ptr, .context = null, .length = 0 };
    }

    pub fn init(self: *AnyPointerListBuilder, length: u29) BuildError!void {
        if (self.length != 0) return Error.AlreadyInitialized;

        const object = try self.ptr.builder.allocObject(self.ptr, length);
        self.context = object.content;
        self.length = length;

        try writeObjectPointer(&self.ptr, object, Ptr{ .list = .{
            .offset_words = 0,
            .elements_or_words = length,
            .element_size = 6,
        } });
    }

    pub fn copyFrom(self: *AnyPointerListBuilder, source: AnyPointerListReader) BuildError!void {
        try self.init(source.length);

        for (0..source.length) |i| {
            try self.get(@intCast(i)).setFromReader(try source.get(@intCast(i)));
        }
    }

    pub fn get(self: AnyPointerListBuilder, index: u32) AnyPointerBuilder {
        std.debug.assert(index < self.length);
        var context = self.context.?;
        context.offset_words = @intCast(@as(u64, context.offset_words) + index);
        return AnyPointerBuilder.fromBuildContext(context);
    }
};

/// Descriptor used when a generic parameter is bound to Text.
pub const Text = struct {
    pub const Reader = ListReader(u8);
    pub const Builder = ListBuilder(u8);

    pub fn readField(reader: StructReader, offset: u16) Error!Reader {
        return reader.readPtrField(Reader, offset);
    }

    pub fn buildField(builder: StructBuilder, offset: u16) BuildError!Builder {
        return builder.buildPtrField(Builder, offset);
    }
};

/// Descriptor used when a generic parameter is bound to Data.
pub const Data = struct {
    pub const Reader = ListReader(u8);
    pub const Builder = ListBuilder(u8);

    pub fn readField(reader: StructReader, offset: u16) Error!Reader {
        return reader.readPtrField(Reader, offset);
    }

    pub fn buildField(builder: StructBuilder, offset: u16) BuildError!Builder {
        return builder.buildPtrField(Builder, offset);
    }
};

/// Descriptor used when a generic parameter is bound to AnyPointer.
pub const AnyPointer = struct {
    pub const Reader = AnyPointerReader;
    pub const Builder = AnyPointerBuilder;

    pub fn readField(reader: StructReader, offset: u16) Error!Reader {
        return reader.readPtrField(Reader, offset);
    }

    pub fn buildField(builder: StructBuilder, offset: u16) BuildError!Builder {
        return builder.buildPtrField(Builder, offset);
    }
};

/// Descriptor used when a generic parameter is bound to an interface.
pub const Interface = AnyPointer;

pub fn StructType(comptime T: type, comptime trait: BuilderTrait(T.Builder)) type {
    return struct {
        pub const Reader = T.Reader;
        pub const Builder = T.Builder;

        pub fn readField(reader: StructReader, offset: u16) Error!Reader {
            return reader.readPtrField(Reader, offset);
        }

        pub fn buildField(builder: StructBuilder, offset: u16) BuildError!Builder {
            return builder.buildStructField(Builder, trait, offset);
        }
    };
}

pub const StructReader = struct {
    context: ReadContext,
    data_words: u16,
    ptr_words: u16,

    pub fn readIntField(self: StructReader, comptime T: type, offset: u32) T {
        return self.context.readIntWithBound(T, offset, self.data_words);
    }

    pub fn readBoolField(self: StructReader, comptime offset: u32) bool {
        const bucket: u29 = comptime offset / 8;
        const shift: u3 = comptime offset % 8;

        return ((self.readIntField(u8, bucket) >> shift) & 1) != 0;
    }

    pub fn readPtrField(self: StructReader, comptime T: type, ptrNo: u16) Error!T {
        // A field past the end of the pointer section reads as null. This is
        // normal when a newer schema reads an older, shorter struct.
        if (ptrNo >= self.ptr_words) return T.fromNull(self.context);

        var context = self.context;
        context.offset_words = @intCast(@as(u64, context.offset_words) +
            @as(u64, self.data_words) + ptrNo);
        return try T.fromReadContext(context);
    }

    pub fn readVoid(_: StructReader) void {}

    pub fn readStringField(self: StructReader, ptrNo: u16) Error![:0]const u8 {
        return (try self.readPtrField(ListReader(u8), ptrNo)).getString();
    }

    pub fn readDataField(self: StructReader, ptrNo: u16) Error![]const u8 {
        return (try self.readPtrField(ListReader(u8), ptrNo)).getData();
    }

    pub fn readFloatField(self: StructReader, comptime T: type, offset: u32) T {
        const U = comptime switch (T) {
            f32 => u32,
            f64 => u64,
            else => unreachable,
        };
        return @bitCast(self.readIntField(U, offset));
    }

    pub fn fromReadContext(context: ReadContext) Error!StructReader {
        var _context = context;

        return switch (try _context.readPtr()) {
            .null => .{
                .context = _context,
                .data_words = 0,
                .ptr_words = 0,
            },
            .struct_ => |s| .{
                .context = _context,
                .data_words = s.data_words,
                .ptr_words = s.ptr_words,
            },
            else => Error.TypeMismatch,
        };
    }

    pub fn fromNull(context: ReadContext) StructReader {
        return .{ .context = context, .data_words = 0, .ptr_words = 0 };
    }

    pub fn format(self: StructReader, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{{context = {}, dataWords = {}, ptrWords = {}}}", .{ self.context, self.data_words, self.ptr_words });
    }
};

pub const StructBuilder = struct {
    context: BuildContext,
    data_words: u16,
    ptr_words: u16,

    pub fn readIntField(self: StructBuilder, comptime T: type, offset: u32) T {
        return self.context.readIntWithBound(T, offset, self.data_words);
    }

    pub fn writeIntField(self: StructBuilder, comptime T: type, offset: u32, value: T) void {
        std.debug.assert(@as(u64, @sizeOf(T)) * offset + @sizeOf(T) <= @as(u64, self.data_words) * 8);
        return self.context.writeInt(T, offset, value);
    }

    pub fn buildPtrField(self: StructBuilder, comptime T: type, offset: u29) T {
        std.debug.assert(offset < self.ptr_words);
        var ptr = self.context;
        ptr.relativeWords(self.data_words + offset);
        return T.fromBuildContext(ptr);
    }

    pub fn buildStructField(
        self: StructBuilder,
        comptime T: type,
        comptime trait: BuilderTrait(T),
        ptr_no: u16,
    ) BuildError!T {
        std.debug.assert(ptr_no < self.ptr_words);
        var ptr = self.context;
        ptr.relativeWords(self.data_words + ptr_no);
        return trait.builder(try ptr.allocStruct(trait.data_words, trait.ptr_words));
    }

    pub fn fromBuildContext(context: BuildContext) StructBuilder {
        const ptr = Ptr.of_u64(context.readInt(u64, 0));
        switch (ptr) {
            .null => return .{ .context = context, .data_words = 0, .ptr_words = 0 },
            .struct_ => |struct_| {
                var _context = context;
                _context.offset_words = @intCast(@as(u64, _context.offset_words) +
                    1 + @as(u64, @intCast(struct_.offset_words)));
                return .{
                    .context = _context,
                    .data_words = struct_.data_words,
                    .ptr_words = struct_.ptr_words,
                };
            },
            else => return .{ .context = context, .data_words = 0, .ptr_words = 0 },
        }
    }

    pub fn asReader(self: StructBuilder) StructReader {
        self.context.builder.traversal_counter = Counter{ .limit = 8 * 1024 * 1024 };

        return .{
            .context = .{
                .segments = self.context.builder.segmentSlices(),
                .segment = self.context.segment,
                .offset_words = self.context.offset_words,
                .traversal_counter = &self.context.builder.traversal_counter,
            },
            .data_words = self.data_words,
            .ptr_words = self.ptr_words,
        };
    }

    pub fn copyContentFrom(self: StructBuilder, source: StructReader) BuildError!void {
        const shared_data = @min(self.data_words, source.data_words);

        if (shared_data != 0) {
            const bytes: usize = @as(usize, shared_data) * 8;
            const src_start: usize = source.context.offsetBytes();
            const dst_start: usize = self.context.offsetBytes();

            const src = source.context.segments[source.context.segment][src_start..][0..bytes];
            const dst = self.context.builder.segments[self.context.segment][dst_start..][0..bytes];

            @memcpy(dst, src);
        }

        if (self.data_words > shared_data) {
            const start: usize = @as(usize, self.context.offsetBytes()) + @as(usize, shared_data) * 8;
            const bytes: usize = @as(usize, self.data_words - shared_data) * 8;
            @memset(self.context.builder.segments[self.context.segment][start..][0..bytes], 0);
        }

        for (0..self.ptr_words) |i| {
            const ptr_no: u16 = @intCast(i);
            const dest = self.buildPtrField(AnyPointerBuilder, ptr_no);

            if (ptr_no < source.ptr_words) {
                try dest.setFromReader(try source.readPtrField(AnyPointerReader, ptr_no));
            } else {
                dest.clear();
            }
        }
    }

    pub fn readPtrField(self: StructBuilder, comptime T: type, ptr_no: u16) Error!T {
        return self.asReader().readPtrField(T, ptr_no);
    }

    pub fn readStringField(self: StructBuilder, ptr_no: u16) Error![:0]const u8 {
        return (try self.readPtrField(ListReader(u8), ptr_no)).getString();
    }

    pub fn readDataField(self: StructBuilder, ptr_no: u16) Error![]const u8 {
        return (try self.readPtrField(ListReader(u8), ptr_no)).getData();
    }

    pub fn writeStringField(self: StructBuilder, ptr_no: u16, value: [:0]const u8) BuildError!void {
        var list = self.buildPtrField(ListBuilder(u8), ptr_no);
        try list.init(@intCast(value.len + 1));
        for (value, 0..) |byte, i| list.set(@intCast(i), byte);
        list.set(@intCast(value.len), 0);
    }

    pub fn writeDataField(self: StructBuilder, ptr_no: u16, value: []const u8) BuildError!void {
        var list = self.buildPtrField(ListBuilder(u8), ptr_no);
        try list.init(@intCast(value.len));
        for (value, 0..) |byte, i| list.set(@intCast(i), byte);
    }

    pub fn readFloatField(self: StructBuilder, comptime T: type, offset: u32) T {
        const U = comptime switch (T) {
            f32 => u32,
            f64 => u64,
            else => unreachable,
        };
        return @bitCast(self.readIntField(U, offset));
    }

    pub fn readVoid(_: StructBuilder) void {}

    pub fn writeFloatField(self: StructBuilder, comptime T: type, offset: u32, value: T) void {
        const U = comptime switch (T) {
            f32 => u32,
            f64 => u64,
            else => unreachable,
        };
        return self.writeIntField(U, offset, @bitCast(value));
    }

    pub fn readBoolField(self: StructBuilder, comptime offset: u32) bool {
        const bucket: u29 = comptime offset / 8;
        const shift: u3 = comptime offset % 8;

        return ((self.readIntField(u8, bucket) >> shift) & 1) != 0;
    }

    pub fn writeBoolField(self: StructBuilder, comptime offset: u32, value: bool) void {
        const bucket: u29 = comptime offset / 8;
        const shift: u3 = comptime offset % 8;
        const mask: u8 = comptime @as(u8, 1) << shift;

        const old = self.readIntField(u8, bucket);

        self.writeIntField(u8, bucket, ~mask & old | if (value) mask else 0);
    }
};

/// Compile-time contract for a generated Cap'n Proto reader type `T`.
pub fn ReaderTrait(comptime T: type) type {
    return struct {
        /// Wrap a raw wire reader in the generated type-safe reader.
        reader: fn (StructReader) T,
    };
}

/// Compile-time contract for a generated Cap'n Proto builder type `T`.
pub fn BuilderTrait(comptime T: type) type {
    return struct {
        data_words: u16,
        ptr_words: u16,

        /// Wrap a raw wire builder in the generated type-safe builder.
        builder: fn (StructBuilder) T,
    };
}

/// Size of the segment table for a framed message with `segment_count`
/// segments, padded to a word boundary.
pub fn frameHeaderSize(segment_count: usize) usize {
    return std.mem.alignForward(usize, 4 * (segment_count + 1), 8);
}

/// Word count for one part of a compile-time message shape. Combine these with
/// `framedSize`.
pub const Size = struct {
    words: usize,

    pub fn ofStruct(comptime trait: anytype) Size {
        return .{ .words = @as(usize, trait.data_words) + trait.ptr_words };
    }

    /// A composite list is a tag word followed by `count` elements.
    pub fn ofCompositeList(comptime trait: anytype, comptime count: usize) Size {
        const stride = @as(usize, trait.data_words) + trait.ptr_words;
        return .{ .words = 1 + count * stride };
    }

    pub fn ofList(comptime T: type, comptime count: usize) Size {
        return .{ .words = listWordCountComptime(listElementSize(T), count) };
    }

    /// Text is `len` bytes plus a NUL terminator.
    pub fn ofText(comptime len: usize) Size {
        return .{ .words = (len + 8) / 8 };
    }

    pub fn ofData(comptime len: usize) Size {
        return .{ .words = (len + 7) / 8 };
    }

    pub fn ofWords(comptime count: usize) Size {
        return .{ .words = count };
    }
};

fn listWordCountComptime(comptime element_size: u3, comptime count: usize) usize {
    return switch (element_size) {
        0 => 0,
        1 => (count + 63) / 64,
        2 => (count + 7) / 8,
        3 => (count + 3) / 4,
        4 => (count + 1) / 2,
        5, 6 => count,
        7 => unreachable,
    };
}

/// Compile-time size of a single-segment message containing the given parts,
/// including the root pointer and the frame header. Every part must be a
/// `Size`; the object graph must be fixed at compile time.
pub fn framedSize(comptime parts: []const Size) usize {
    var words: usize = 1; // root pointer
    inline for (parts) |part| words += part.words;
    return words * 8;
}

test "framedSize supports compile-time list shapes" {
    const trait = .{ .data_words = 1, .ptr_words = 1 };

    try std.testing.expectEqual(@as(usize, 8 + 8 * (1 + 2)), framedSize(.{Size.ofStruct(trait)}));
    try std.testing.expectEqual(@as(usize, 8 + 8 * (1 + 2 + 3)), framedSize(.{
        Size.ofStruct(trait),
        Size.ofCompositeList(trait, 1),
    }));

    try std.testing.expectEqual(@as(usize, 0), Size.ofList(void, 100).words);
    try std.testing.expectEqual(@as(usize, 1), Size.ofList(bool, 64).words);
    try std.testing.expectEqual(@as(usize, 2), Size.ofList(bool, 65).words);
    try std.testing.expectEqual(@as(usize, 2), Size.ofList(u8, 9).words);
    try std.testing.expectEqual(@as(usize, 4), Size.ofList(u32, 8).words);
    try std.testing.expectEqual(@as(usize, 8), Size.ofList(u64, 8).words);
    try std.testing.expectEqual(@as(usize, 1), Size.ofText(0).words);
    try std.testing.expectEqual(@as(usize, 2), Size.ofText(8).words);
    try std.testing.expectEqual(@as(usize, 1), Size.ofData(8).words);
    try std.testing.expectEqual(@as(usize, 2), Size.ofData(9).words);
    try std.testing.expectEqual(@as(usize, 3), Size.ofWords(3).words);
}

pub const Struct = struct {
    pub const Builder = StructBuilder;
    pub const Reader = StructReader;
};

fn listElementSize(comptime T: type) u3 {
    return switch (T) {
        void => 0,
        bool => 1,
        u8, i8 => 2,
        u16, i16 => 3,
        u32, i32, f32 => 4,
        u64, i64, f64 => 5,
        else => switch (@typeInfo(T)) {
            .@"enum" => 3,
            else => @compileError("unsupported list element type"),
        },
    };
}

fn listWordCount(element_size: u3, count: u29) BuildError!u32 {
    return switch (element_size) {
        0 => 0,
        1 => (std.math.add(u32, count, 63) catch return Error.MessageTooLarge) / 64,
        2 => (std.math.add(u32, count, 7) catch return Error.MessageTooLarge) / 8,
        3 => (std.math.add(u32, count, 3) catch return Error.MessageTooLarge) / 4,
        4 => (std.math.add(u32, count, 1) catch return Error.MessageTooLarge) / 2,
        5, 6 => count,
        7 => unreachable,
    };
}

fn listGet(comptime T: type, context: ReadContext, ix: u32) T {
    if (T == bool) {
        const bucket = ix / 8;
        const shift: u3 = @intCast(ix % 8);
        return ((context.readInt(u8, bucket) >> shift) & 1) != 0;
    }
    if (@typeInfo(T) == .@"enum") {
        return @fromBackingInt(@intCast(context.readInt(u16, ix)));
    }
    return context.readInt(T, ix);
}

fn listSet(comptime T: type, context: BuildContext, ix: u32, value: T) void {
    if (T == bool) {
        const bucket = ix / 8;
        const shift: u3 = @intCast(ix % 8);
        const mask: u8 = @as(u8, 1) << shift;
        const old = context.readInt(u8, bucket);
        context.writeInt(u8, bucket, ~mask & old | if (value) mask else 0);
        return;
    }
    if (@typeInfo(T) == .@"enum") {
        context.writeInt(u16, ix, @intCast(@backingInt(value)));
        return;
    }
    context.writeInt(T, ix, value);
}

pub fn ListReader(comptime T: type) type {
    return struct {
        const Self = @This();

        context: ReadContext,

        elementSize: u3,
        length: u29,

        pub fn fromReadContext(context: ReadContext) Error!Self {
            var _context = context;
            switch (try _context.readPtr()) {
                .null => return Self.fromNull(context),
                .list => |list| return Self.fromPtr(_context, list),
                else => return Error.TypeMismatch,
            }
        }

        pub fn fromPtr(context: ReadContext, list: Ptr.List) Error!Self {
            if (list.element_size != listElementSize(T)) return Error.TypeMismatch;

            return Self{
                .context = context,
                .elementSize = list.element_size,
                .length = list.elements_or_words,
            };
        }

        pub fn fromNull(context: ReadContext) Self {
            return .{ .context = context, .elementSize = 0, .length = 0 };
        }

        pub fn get(self: Self, ix: u32) T {
            return listGet(T, self.context, ix);
        }

        pub fn getString(self: Self) Error![:0]const u8 {
            comptime std.debug.assert(T == u8);
            return self.context.readString(self.length);
        }

        pub fn getData(self: Self) Error![]const u8 {
            comptime std.debug.assert(T == u8);
            return self.context.readData(self.length);
        }
    };
}

pub fn ListBuilder(comptime T: type) type {
    return struct {
        const Self = @This();
        const element_size: u3 = listElementSize(T);

        ptr: BuildContext,
        context: ?BuildContext,

        length: u29,

        pub fn fromBuildContext(ptr: BuildContext) Self {

            // For now, just assert pointer is empty.
            std.debug.assert(ptr.readInt(u64, 0) == 0);

            return Self{ .ptr = ptr, .context = null, .length = 0 };
        }

        pub fn init(self: *Self, length: u29) BuildError!void {
            if (self.length != 0) return Error.AlreadyInitialized;

            const size_in_words = try listWordCount(element_size, length);

            const object = try self.ptr.builder.allocObject(self.ptr, size_in_words);
            self.context = object.content;
            self.length = length;

            try writeObjectPointer(&self.ptr, object, Ptr{ .list = .{
                .offset_words = 0,
                .elements_or_words = length,
                .element_size = element_size,
            } });
        }

        pub fn copyFrom(self: *Self, source: ListReader(T)) BuildError!void {
            try self.init(source.length);

            const words = try listWordCount(element_size, source.length);
            if (words == 0) return;

            const bytes: usize = @as(usize, words) * 8;
            const src_start: usize = source.context.offsetBytes();
            const dst = self.context.?;
            const dst_start: usize = dst.offsetBytes();

            const src = source.context.segments[source.context.segment][src_start..][0..bytes];
            const dest = dst.builder.segments[dst.segment][dst_start..][0..bytes];

            @memcpy(dest, src);
        }

        pub fn set(self: *Self, index: u32, value: T) void {
            std.debug.assert(self.context != null);
            std.debug.assert(index < self.length);
            listSet(T, self.context.?, index, value);
        }

        pub fn get(self: Self, ix: u32) T {
            std.debug.assert(ix < self.length);
            return listGet(T, self.context.?, ix);
        }
    };
}

pub fn List(comptime T: type) type {
    switch (@typeInfo(T)) {
        .@"struct" => @compileError(
            "struct element types need capnp.CompositeListReader or capnp.CompositeListBuilder",
        ),
        else => {},
    }

    return struct {
        pub const Builder = ListBuilder(T);
        pub const Reader = ListReader(T);
    };
}

pub fn CompositeListBuilder(
    comptime T: type,
    comptime trait: BuilderTrait(T),
) type {
    return struct {
        const Self = @This();

        ptr: BuildContext,
        context: ?BuildContext,

        length: u29,

        pub fn fromBuildContext(ptr: BuildContext) Self {

            // For now, just assert pointer is empty.
            std.debug.assert(ptr.readInt(u64, 0) == 0);

            return Self{ .ptr = ptr, .context = null, .length = 0 };
        }

        pub fn init(self: *Self, length: u29) BuildError!void {
            if (self.length != 0) return Error.AlreadyInitialized;

            const stride = @as(u32, trait.data_words) + trait.ptr_words;
            const element_words = std.math.mul(u32, stride, length) catch return Error.MessageTooLarge;
            const payload_words = std.math.add(u32, 1, element_words) catch return Error.MessageTooLarge;

            const object = try self.ptr.builder.allocObject(self.ptr, payload_words);

            // The tag word describes the elements and stores their count.
            var tag = object.content;
            tag.writePtr(Ptr{ .struct_ = .{
                .offset_words = @intCast(length),
                .data_words = trait.data_words,
                .ptr_words = trait.ptr_words,
            } });

            var elements = object.content;
            elements.offset_words += 1;
            self.context = elements;
            self.length = length;

            try writeObjectPointer(&self.ptr, object, Ptr{ .list = .{
                .offset_words = 0,
                .elements_or_words = @intCast(element_words),
                .element_size = 7,
            } });
        }

        pub fn copyFrom(self: *Self, source: anytype) BuildError!void {
            try self.init(source.length);
            if (source.length == 0) return;

            const src_stride = @as(u64, source.dataWords) + source.ptrWords;
            const dst_stride = @as(u64, trait.data_words) + trait.ptr_words;

            const src_context = source.context.?;
            const dst_context = self.context.?;

            for (0..source.length) |i| {
                var src = src_context;
                src.offset_words = @intCast(@as(u64, src.offset_words) + src_stride * i);

                var dst = dst_context;
                dst.offset_words = @intCast(@as(u64, dst.offset_words) + dst_stride * i);

                try (StructBuilder{
                    .context = dst,
                    .data_words = trait.data_words,
                    .ptr_words = trait.ptr_words,
                }).copyContentFrom(.{
                    .context = src,
                    .data_words = source.dataWords,
                    .ptr_words = source.ptrWords,
                });
            }
        }

        pub fn get(self: Self, ix: u32) T {
            std.debug.assert(ix < self.length);
            var _context = self.context.?;
            const stride = @as(u64, trait.data_words) + trait.ptr_words;
            // TODO this need improvement to avoid so much int cast
            _context.offset_words = @intCast(@as(u64, _context.offset_words) + stride * ix);

            return trait.builder(StructBuilder{
                .context = _context,
                .data_words = trait.data_words,
                .ptr_words = trait.ptr_words,
            });
        }
    };
}

pub fn ListIterator(comptime T: type, comptime U: type) type {
    return struct {
        const Self = @This();
        reader: T,
        ix: u29 = 0,

        pub fn next(self: *Self) ?U {
            if (self.ix < self.reader.length) {
                const out = self.reader.get(self.ix);
                self.ix += 1;
                return out;
            } else {
                return null;
            }
        }
    };
}

pub fn CompositeListReader(
    comptime T: type,
    comptime trait: ReaderTrait(T),
) type {
    return struct {
        const Self = @This();

        context: ?ReadContext,

        elementSize: u3,
        length: u29,

        dataWords: u16,
        ptrWords: u16,

        pub const empty = Self{ .context = null, .elementSize = 0, .length = 0, .dataWords = 0, .ptrWords = 0 };

        pub fn fromReadContext(context: ReadContext) Error!Self {
            var _context = context;

            switch (try _context.readPtr()) {
                .null => return Self.empty,
                .list => |list_ptr| return Self.fromPtr(_context, list_ptr),
                else => return Error.TypeMismatch,
            }
        }

        pub fn fromPtr(context: ReadContext, list_ptr: Ptr.List) Error!Self {
            if (list_ptr.element_size != 7) return Error.TypeMismatch;

            var _context = context;
            switch (try _context.readPtrN()) {
                .struct_ => |struct_ptr| {
                    if (struct_ptr.offset_words < 0) return Error.InvalidPointer;

                    const length: u29 = @intCast(struct_ptr.offset_words);
                    const stride = @as(u64, struct_ptr.data_words) + struct_ptr.ptr_words;
                    if (@as(u64, length) * stride > list_ptr.elements_or_words) {
                        return Error.OutOfBounds;
                    }

                    // Zero-sized structs still count as one word per
                    // element against the traversal limit.
                    if (stride == 0) {
                        _context.traversal_counter.increment(length) catch
                            return Error.TraversalLimitExceeded;
                    }

                    _context.offset_words += 1;

                    return Self{
                        .context = _context,
                        .elementSize = 7,
                        .length = length,
                        .dataWords = struct_ptr.data_words,
                        .ptrWords = struct_ptr.ptr_words,
                    };
                },
                else => return Error.TypeMismatch,
            }
        }

        pub fn fromNull(_: ReadContext) Self {
            return Self.empty;
        }

        pub fn iter(self: Self) ListIterator(Self, T) {
            return ListIterator(Self, T){
                .reader = self,
                .ix = 0,
            };
        }

        pub fn get(self: Self, ix: u32) T {
            std.debug.assert(ix < self.length);

            var _context = self.context.?;
            const stride = @as(u64, self.ptrWords) + self.dataWords;
            _context.offset_words = @intCast(@as(u64, _context.offset_words) + stride * ix);

            return trait.reader(StructReader{
                .context = _context,
                .data_words = self.dataWords,
                .ptr_words = self.ptrWords,
            });
        }
    };
}

pub const Message = struct {
    segments: [][]u8 = undefined,
    /// Set when the message owns a contiguous serialized buffer and `segments`
    /// point into it. In that case `deinit` frees the buffer once instead of
    /// freeing each segment independently.
    owned_bytes: ?[]u8 = null,
    traversal_counter: Counter = Counter{ .limit = 8 * 1024 * 1024 },

    pub fn fromFile(file: std.Io.File, io: std.Io, allocator: std.mem.Allocator) !Message {
        var buffer: [4]u8 = undefined;

        std.debug.assert(4 == try file.readPositionalAll(io, &buffer, 0));

        const segmentCount = 1 + std.mem.readInt(u32, buffer[0..4], .little);

        var segmentLengthsBuffer = try allocator.alloc(u8, 4 * segmentCount * BYTES);
        defer allocator.free(segmentLengthsBuffer);

        var offset: u64 = 4;
        std.debug.assert(segmentLengthsBuffer.len == try file.readPositionalAll(io, segmentLengthsBuffer, offset));
        offset += segmentLengthsBuffer.len;

        const segments = try allocator.alloc([]u8, segmentCount * ELEMENTS);

        for (0..segmentCount) |i| {
            const segmentWords = std.mem.readInt(u32, segmentLengthsBuffer[i * 4 ..][0..4], .little);
            segments[i] = try allocator.alloc(u8, segmentWords * 8 * BYTES);
            std.debug.assert(segments[i].len == try file.readPositionalAll(io, segments[i], offset));
            offset += segments[i].len;
        }
        return Message{ .segments = segments };
    }

    pub fn fromPackedBytes(input: []const u8, allocator: std.mem.Allocator) !Message {
        const size = try packing.messageSize(input);
        const unpacked = try allocator.alloc(u8, size);
        defer allocator.free(unpacked);

        var writer = std.Io.Writer.fixed(unpacked);
        try packing.unpack(&writer, input);
        if (writer.end != size) return Error.OutOfBounds;

        return fromBytes(unpacked, allocator);
    }

    pub fn fromPackedFile(file: std.Io.File, io: std.Io, allocator: std.mem.Allocator) !Message {
        const file_size = try file.length(io);
        if (file_size > std.math.maxInt(usize)) return Error.MessageTooLarge;

        const input = try allocator.alloc(u8, @intCast(file_size));
        defer allocator.free(input);

        const read = try file.readPositionalAll(io, input, 0);
        if (read != input.len) return Error.OutOfBounds;

        return fromPackedBytes(input, allocator);
    }

    pub fn fromBytes(bytes: []const u8, allocator: std.mem.Allocator) !Message {
        if (bytes.len < 4) return Error.OutOfBounds;

        const segment_count: usize = 1 + std.mem.readInt(u32, bytes[0..4], .little);
        const table_bytes = std.math.mul(usize, 4, segment_count) catch return Error.MessageTooLarge;
        const data_offset = std.mem.alignForward(usize, 4 + table_bytes, 8);
        if (data_offset > bytes.len) return Error.OutOfBounds;

        const segments = try allocator.alloc([]u8, segment_count);
        var initialized: usize = 0;
        errdefer {
            for (segments[0..initialized]) |segment| allocator.free(segment);
            allocator.free(segments);
        }

        var offset = data_offset;
        for (0..segment_count) |i| {
            const words = std.mem.readInt(u32, bytes[4 + i * 4 ..][0..4], .little);
            const byte_len = std.math.mul(usize, words, 8) catch return Error.MessageTooLarge;
            if (offset + byte_len > bytes.len) return Error.OutOfBounds;

            segments[i] = try allocator.alloc(u8, byte_len);
            initialized += 1;
            @memcpy(segments[i], bytes[offset..][0..byte_len]);
            offset += byte_len;
        }

        return Message{ .segments = segments };
    }

    /// Parse a contiguous serialized message and take ownership of `bytes`.
    ///
    /// On success the returned message frees `bytes` from `deinit`; on error
    /// the caller retains ownership of `bytes`.
    pub fn fromOwnedBytes(bytes: []u8, allocator: std.mem.Allocator) !Message {
        if (bytes.len < 4) return Error.OutOfBounds;

        const segment_count: usize = 1 + std.mem.readInt(u32, bytes[0..4], .little);
        const table_bytes = std.math.mul(usize, 4, segment_count) catch return Error.MessageTooLarge;
        const data_offset = std.mem.alignForward(usize, 4 + table_bytes, 8);
        if (data_offset > bytes.len) return Error.OutOfBounds;

        const segments = try allocator.alloc([]u8, segment_count);
        errdefer allocator.free(segments);

        var offset = data_offset;
        for (0..segment_count) |i| {
            const words = std.mem.readInt(u32, bytes[4 + i * 4 ..][0..4], .little);
            const byte_len = std.math.mul(usize, words, 8) catch return Error.MessageTooLarge;
            if (offset + byte_len > bytes.len) return Error.OutOfBounds;

            segments[i] = bytes[offset..][0..byte_len];
            offset += byte_len;
        }

        return Message{ .segments = segments, .owned_bytes = bytes };
    }

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        if (self.owned_bytes) |bytes| {
            allocator.free(self.segments);
            allocator.free(bytes);
        } else {
            for (self.segments) |segment| {
                allocator.free(segment);
            }
            allocator.free(self.segments);
        }
    }

    pub fn getRootStruct(self: *Message, comptime T: type, comptime trait: ReaderTrait(T)) Error!T {
        self.traversal_counter = Counter{ .limit = 8 * 1024 * 1024 };
        return trait.reader(try StructReader.fromReadContext(ReadContext.fromSegments(self.segments, &self.traversal_counter)));
    }
};

pub const BuildContext = struct {
    builder: *MessageBuilder,
    segment: u32,
    offset_words: u29,
    grower: ?*Grower = null,

    pub fn offsetBytes(self: BuildContext) u32 {
        return self.offset_words << 3;
    }

    pub fn readIntWithBound(self: BuildContext, comptime T: type, offset: u32, boundWords: u29) T {
        const pos = self.offsetBytes() + @sizeOf(T) * offset;
        const segment = self.builder.segments[self.segment];
        return if (@sizeOf(T) * offset < boundWords << 3) std.mem.readInt(T, segment[pos..][0..@sizeOf(T)], .little) else 0;
    }

    pub fn readInt(self: BuildContext, comptime T: type, offset: u32) T {
        const pos = self.offsetBytes() + @sizeOf(T) * offset;
        const segment = self.builder.segments[self.segment];
        return std.mem.readInt(T, segment[pos..][0..@sizeOf(T)], .little);
    }

    pub fn writeInt(self: BuildContext, comptime T: type, offset: u32, value: T) void {
        const pos = self.offsetBytes() + @sizeOf(T) * offset;
        const segment = self.builder.segments[self.segment];
        return std.mem.writeInt(T, segment[pos..][0..@sizeOf(T)], value, .little);
    }

    pub fn writePtr(self: *BuildContext, ptr: Ptr) void {
        self.writeInt(u64, 0, ptr.to_u64());
    }

    pub fn allocStruct(self: *BuildContext, dataWords: u16, ptrWords: u16) BuildError!StructBuilder {
        if (dataWords == 0 and ptrWords == 0) {
            // Offset -1 distinguishes an empty struct from a null pointer.
            self.writePtr(Ptr{ .struct_ = .{
                .offset_words = -1,
                .data_words = 0,
                .ptr_words = 0,
            } });
            return StructBuilder{ .context = self.*, .ptr_words = 0, .data_words = 0 };
        }

        const words = @as(u32, dataWords) + ptrWords;
        const object = try self.builder.allocObject(self.*, words);

        try writeObjectPointer(self, object, Ptr{
            .struct_ = .{
                .offset_words = 0,
                .data_words = dataWords,
                .ptr_words = ptrWords,
            },
        });

        return StructBuilder{ .context = object.content, .ptr_words = ptrWords, .data_words = dataWords };
    }

    pub fn relativeWords(self: *BuildContext, dx: i30) void {
        self.offset_words = @intCast(dx + self.offset_words);
    }
};

const max_segment_bytes: u32 = (1 << 32) - 8;

const Object = struct {
    tag: BuildContext,
    content: BuildContext,
    needs_far: bool,
};

fn writeObjectPointer(pointer: *BuildContext, object: Object, payload: Ptr) BuildError!void {
    var p = payload;

    if (!object.needs_far) {
        const delta = @as(i64, object.content.offset_words) - @as(i64, pointer.offset_words) - 1;
        if (delta < std.math.minInt(i30) or delta > std.math.maxInt(i30)) {
            return Error.OffsetOverflow;
        }
        const offset: i30 = @intCast(delta);

        switch (p) {
            .struct_ => |*s| s.offset_words = offset,
            .list => |*l| l.offset_words = offset,
            else => unreachable,
        }
        pointer.writePtr(p);
        return;
    }

    // The payload is immediately after the landing pad, so its offset is zero.
    switch (p) {
        .struct_ => |*s| s.offset_words = 0,
        .list => |*l| l.offset_words = 0,
        else => unreachable,
    }

    var tag = object.tag;
    tag.writePtr(p);
    pointer.writePtr(Ptr{ .inter_segment = .{
        .double = false,
        .offset = @intCast(object.tag.offset_words),
        .segment = object.tag.segment,
    } });
}

pub const max_segments: usize = 4;

/// Allocation policy for builders that need to grow past their initial
/// storage. `MessageBuilder` itself never allocates; the policy is passed
/// explicitly through the build context.
pub const Grower = struct {
    allocator: Allocator,
    // Capacity for the next new segment. Grows geometrically, capped at max_segment_bytes.
    next_segment_bytes: u32 = 1 << 16,

    pub fn grow(self: *Grower, min_bytes: u32) BuildError![]u8 {
        if (min_bytes > max_segment_bytes) return Error.MessageTooLarge;

        var capacity: u32 = self.next_segment_bytes;
        if (capacity < min_bytes) {
            capacity = std.math.ceilPowerOfTwo(u32, min_bytes) catch max_segment_bytes;
        }
        if (capacity > max_segment_bytes) capacity = max_segment_bytes;
        if (capacity < min_bytes) return Error.MessageTooLarge;

        const segment = try self.allocator.alloc(u8, capacity);
        self.next_segment_bytes = @min(std.math.mul(u32, capacity, 2) catch max_segment_bytes, max_segment_bytes);
        return segment;
    }
};

/// A message builder backed exclusively by caller-provided storage. It owns no
/// memory and never allocates. Use `GrowableMessage` when the message may need
/// to grow beyond its initial buffer.
pub const MessageBuilder = struct {
    segments: [max_segments][]u8 = std.mem.zeroes([max_segments][]u8),
    capacities: [max_segments]u32 = std.mem.zeroes([max_segments]u32),
    count: u8 = 0,
    traversal_counter: Counter = Counter{ .limit = 8 * 1024 * 1024 },

    pub fn initBuffer(buffer: []u8) MessageBuilder {
        var self = MessageBuilder{};
        self.addSegment(buffer);
        return self;
    }

    pub fn initSegments(buffers: []const []u8) BuildError!MessageBuilder {
        if (buffers.len > max_segments) return Error.SegmentLimitReached;
        var self = MessageBuilder{};
        for (buffers) |buffer| self.addSegment(buffer);
        return self;
    }

    pub fn deinitSegments(self: *MessageBuilder, allocator: std.mem.Allocator) void {
        for (self.segments[0..self.count], 0..) |segment, i| {
            allocator.free(segment.ptr[0..self.capacities[i]]);
        }
        self.count = 0;
    }

    fn addSegment(self: *MessageBuilder, buffer: []u8) void {
        std.debug.assert(self.count < max_segments);
        const usable = buffer.len - (buffer.len % 8);
        self.segments[self.count] = buffer[0..0];
        self.capacities[self.count] = @intCast(usable);
        self.count += 1;
    }

    /// Reset the used length of every segment. `GrowableMessage.reset` also
    /// frees segments grown beyond the first one.
    pub fn reset(self: *MessageBuilder) void {
        for (self.segments[0..self.count]) |*segment| segment.len = 0;
        self.traversal_counter = Counter{ .limit = 8 * 1024 * 1024 };
    }

    inline fn segmentCapacity(self: *const MessageBuilder, segment: u32) u32 {
        return self.capacities[segment];
    }

    pub fn expandAssert(self: *MessageBuilder, min_bytes: u32, grower: ?*Grower) BuildError!u32 {
        if (self.count >= max_segments) return Error.SegmentLimitReached;
        if (min_bytes > max_segment_bytes) return Error.MessageTooLarge;
        const g = grower orelse return Error.NoSpaceLeft;

        const segment = try g.grow(min_bytes);
        self.addSegment(segment);
        return self.count - 1;
    }

    pub fn allocAssert(self: *MessageBuilder, segment: u32, bytes: u32, grower: ?*Grower) BuildContext {
        std.debug.assert(segment < self.count);
        std.debug.assert(@as(u64, self.segments[segment].len) + bytes <= self.segmentCapacity(segment));

        defer self.segments[segment].len += bytes;
        const seg = self.segments[segment];
        @memset(seg.ptr[seg.len .. seg.len + bytes], 0);
        return .{ .builder = self, .segment = segment, .offset_words = @intCast(seg.len >> 3), .grower = grower };
    }

    /// try to allocate in the given segment.
    pub fn alloc(self: *MessageBuilder, segment: u32, words: u32) BuildError!BuildContext {
        return self.allocWithGrower(segment, words, null);
    }

    pub fn allocWithGrower(self: *MessageBuilder, segment: u32, words: u32, grower: ?*Grower) BuildError!BuildContext {
        const bytes: u32 = std.math.mul(u32, words, 8) catch return Error.MessageTooLarge;
        if (bytes > max_segment_bytes) return Error.MessageTooLarge;

        if (segment < self.count) {
            const used: u64 = self.segments[segment].len;
            if (used + bytes <= self.segmentCapacity(segment)) {
                return self.allocAssert(segment, bytes, grower);
            }
        }

        var best_ix: u32 = 0;
        var best_spare: i64 = -1;

        for (self.segments[0..self.count], 0..) |seg, n_| {
            const n: u32 = @intCast(n_);
            if (n == segment) continue;

            const spare: i64 =
                @as(i64, self.segmentCapacity(n)) -
                @as(i64, @intCast(seg.len + bytes));
            if (spare > best_spare) {
                best_spare = spare;
                best_ix = n;
            }
        }

        if (best_spare < 0) {
            const new_segment = try self.expandAssert(bytes, grower);
            return self.allocAssert(new_segment, bytes, grower);
        }

        return self.allocAssert(best_ix, bytes, grower);
    }

    fn allocObject(self: *MessageBuilder, pointer: BuildContext, words: u32) BuildError!Object {
        const bytes = std.math.mul(u32, words, 8) catch return Error.MessageTooLarge;
        if (bytes > max_segment_bytes) return Error.MessageTooLarge;

        // Prefer placing the object in the pointer's own segment.
        if (pointer.segment < self.count) {
            const used: u64 = self.segments[pointer.segment].len;
            if (used + bytes <= self.segmentCapacity(pointer.segment)) {
                return .{
                    .tag = pointer,
                    .content = self.allocAssert(pointer.segment, bytes, pointer.grower),
                    .needs_far = false,
                };
            }
        }

        // Reserve [landing pad][payload] contiguously in another segment.
        const padded_words = std.math.add(u32, words, 1) catch return Error.MessageTooLarge;
        const start = try self.allocWithGrower(pointer.segment, padded_words, pointer.grower);

        var content = start;
        content.offset_words += 1;

        return .{
            .tag = start,
            .content = content,
            .needs_far = true,
        };
    }

    /// Borrow the builder's segments as a readable message. The returned
    /// message is valid only while this builder is alive and must not be
    /// deinitialized.
    pub fn toReader(self: *const MessageBuilder) Message {
        return Message{ .segments = @constCast(self.segments[0..self.count]) };
    }

    /// Exact size of the framed serialized message.
    pub fn serializedSize(self: *const MessageBuilder) usize {
        const segment_count = self.count;
        const table_bytes = 4 * (segment_count + 1);
        const header_size = std.mem.alignForward(usize, table_bytes, 8);

        var total: usize = header_size;
        for (self.segments[0..self.count]) |segment| {
            total = std.math.add(usize, total, segment.len) catch std.debug.panic("mult overflow {} {}", .{ total, segment.len });
        }
        return total;
    }

    /// Borrow the builder's segment bytes. The slices are valid only while
    /// this builder is alive and must not be written through.
    pub fn segmentSlices(self: *const MessageBuilder) []const []const u8 {
        return @as([*]const []const u8, @ptrCast(self.segments[0..self.count].ptr))[0..self.count];
    }

    /// Number of segments currently in use.
    pub fn segmentCount(self: *const MessageBuilder) usize {
        return self.count;
    }

    /// Write the framed message header into `buffer` and return the used
    /// header slice.
    pub fn writeHeader(self: *const MessageBuilder, buffer: []u8) Error![]const u8 {
        const segment_count = self.count;
        std.debug.assert(segment_count > 0);

        const table_bytes = 4 * (segment_count + 1);
        const header_size = std.mem.alignForward(usize, table_bytes, 8);
        if (buffer.len < header_size) return Error.NoSpaceLeft;

        std.mem.writeInt(u32, buffer[0..4], @intCast(segment_count - 1), .little);

        var offset: usize = 4;
        for (self.segments[0..self.count]) |segment| {
            std.debug.assert(segment.len % 8 == 0);
            std.mem.writeInt(u32, buffer[offset..][0..4], @intCast(segment.len / 8), .little);
            offset += 4;
        }

        @memset(buffer[offset..header_size], 0);
        return buffer[0..header_size];
    }

    /// Serialize into caller-provided storage. Returns the written slice.
    pub fn writeToBuffer(self: *const MessageBuilder, buffer: []u8) Error![]u8 {
        const total = try self.serializedSize();
        if (buffer.len < total) return Error.NoSpaceLeft;

        const header = try self.writeHeader(buffer);
        var offset: usize = header.len;
        for (self.segments[0..self.count]) |segment| {
            @memcpy(buffer[offset..][0..segment.len], segment);
            offset += segment.len;
        }

        return buffer[0..offset];
    }

    // pub fn writeTo(self: *const MessageBuilder, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    //     const segment_count = self.count;
    //     std.debug.assert(segment_count > 0);

    //     var buf: [4]u8 = undefined;
    //     std.mem.writeInt(u32, &buf, @intCast(segment_count - 1), .little);
    //     try writer.writeAll(&buf);

    //     for (self.segments[0..self.count]) |segment| {
    //         std.debug.assert(segment.len % 8 == 0);
    //         std.mem.writeInt(u32, &buf, @intCast(segment.len / 8), .little);
    //         try writer.writeAll(&buf);
    //     }

    //     // Pad the segment table to a word boundary.
    //     const table_bytes = 4 * (segment_count + 1);
    //     var padding = (8 - (table_bytes % 8)) % 8;
    //     while (padding > 0) : (padding -= 1) try writer.writeByte(0);

    //     for (self.segments[0..self.count]) |segment| try writer.writeAll(segment);
    // }

    pub fn writePackedTo(self: *const MessageBuilder, writer: *std.Io.Writer, scratch: []u8) !void {
        const bytes = try self.writeToBuffer(scratch);
        try packing.pack(writer, bytes);
    }

    fn copyStructBody(
        self: *MessageBuilder,
        source: ReadContext,
        dest: BuildContext,
        data_words: u16,
        ptr_words: u16,
        allow_caps: bool,
    ) BuildError!void {
        if (data_words != 0) {
            const bytes: usize = @as(usize, data_words) * 8;
            const src_start: usize = source.offsetBytes();
            const dst_start: usize = dest.offsetBytes();

            const src = source.segments[source.segment][src_start..][0..bytes];
            const dst = dest.builder.segments[dest.segment][dst_start..][0..bytes];
            @memcpy(dst, src);
        }
        for (0..ptr_words) |i| {
            var src = source;
            src.offset_words += data_words + @as(u29, @intCast(i));
            const ptr = try src.readPtr();
            var dst = dest;
            dst.offset_words += data_words + @as(u29, @intCast(i));
            try self.copyPointerToInternal(&dst, .{ .context = src, .ptr = ptr }, allow_caps);
        }
    }

    fn copyListTo(self: *MessageBuilder, dest: *BuildContext, source: ReadContext, list: Ptr.List, allow_caps: bool) BuildError!void {
        if (list.element_size == 7) {
            const tag_raw = source.readInt(u64, 0);
            const tag = Ptr.of_u64(tag_raw);
            const struct_tag = switch (tag) {
                .struct_ => |s| s,
                else => return Error.InvalidPointer,
            };
            const element_count: u32 = @intCast(struct_tag.offset_words);
            const stride: u32 = @as(u32, struct_tag.data_words) + struct_tag.ptr_words;
            const payload_words = std.math.add(u32, 1, list.elements_or_words) catch return Error.MessageTooLarge;

            const object = try self.allocObject(dest.*, payload_words);
            try writeObjectPointer(dest, object, Ptr{ .list = .{
                .offset_words = 0,
                .elements_or_words = list.elements_or_words,
                .element_size = 7,
            } });
            object.content.writeInt(u64, 0, tag_raw);

            for (0..element_count) |i| {
                var src = source;
                src.offset_words += 1 + @as(u29, @intCast(i)) * @as(u29, @intCast(stride));
                var dst = object.content;
                dst.offset_words += 1 + @as(u29, @intCast(i)) * @as(u29, @intCast(stride));
                try self.copyStructBody(src, dst, struct_tag.data_words, struct_tag.ptr_words, allow_caps);
            }
            return;
        }

        const words = try listWordCount(list.element_size, list.elements_or_words);
        const object = try self.allocObject(dest.*, words);
        try writeObjectPointer(dest, object, Ptr{ .list = .{
            .offset_words = 0,
            .elements_or_words = list.elements_or_words,
            .element_size = list.element_size,
        } });

        if (list.element_size == 6) {
            for (0..list.elements_or_words) |i| {
                var src = source;
                src.offset_words += @intCast(i);
                const ptr = try src.readPtr();
                var dst = object.content;
                dst.offset_words += @intCast(i);
                try self.copyPointerToInternal(&dst, .{ .context = src, .ptr = ptr }, allow_caps);
            }
        } else if (words != 0) {
            const bytes: usize = @as(usize, words) * 8;
            const src_start: usize = source.offsetBytes();
            const dst_start: usize = object.content.offsetBytes();

            const src = source.segments[source.segment][src_start..][0..bytes];
            const dst = object.content.builder.segments[object.content.segment][dst_start..][0..bytes];
            @memcpy(dst, src);
        }
    }

    fn copyPointerToInternal(
        self: *MessageBuilder,
        dest: *BuildContext,
        source: AnyPointerReader,
        allow_caps: bool,
    ) BuildError!void {
        switch (source.ptr) {
            .null => dest.writePtr(.null),
            .capability => {
                if (!allow_caps) return Error.TypeMismatch;
                dest.writePtr(source.ptr);
            },
            .struct_ => |struct_| {
                const words = @as(u32, struct_.data_words) + struct_.ptr_words;
                if (words == 0) {
                    _ = try dest.allocStruct(0, 0);
                    return;
                }
                const object = try self.allocObject(dest.*, words);
                try writeObjectPointer(dest, object, Ptr{ .struct_ = .{
                    .offset_words = 0,
                    .data_words = struct_.data_words,
                    .ptr_words = struct_.ptr_words,
                } });
                try self.copyStructBody(source.context, object.content, struct_.data_words, struct_.ptr_words, allow_caps);
            },
            .list => |list| try self.copyListTo(dest, source.context, list, allow_caps),
            .inter_segment => return Error.InvalidPointer,
        }
    }

    pub fn copyPointerTo(self: *MessageBuilder, dest: *BuildContext, source: AnyPointerReader) BuildError!void {
        return self.copyPointerToInternal(dest, source, false);
    }

    /// Copy a pointer graph, preserving capability pointer indices. The caller
    /// is responsible for supplying a corresponding capability table.
    pub fn copyPointerToWithCaps(self: *MessageBuilder, dest: *BuildContext, source: AnyPointerReader) BuildError!void {
        return self.copyPointerToInternal(dest, source, true);
    }

    pub fn initFromAnyPointer(self: *MessageBuilder, source: AnyPointerReader) BuildError!void {
        return self.initFromAnyPointerWithGrower(source, null);
    }

    pub fn initFromAnyPointerWithGrower(self: *MessageBuilder, source: AnyPointerReader, grower: ?*Grower) BuildError!void {
        if (self.count != 1 or self.segments[0].len != 0) return Error.RootAlreadyInitialized;
        var root = self.allocAssert(0, 8, grower);
        try self.copyPointerTo(&root, source);
    }

    pub fn initRootStruct(self: *MessageBuilder, comptime T: type, comptime trait: BuilderTrait(T)) BuildError!T {
        return self.initRootStructWithGrower(T, trait, null);
    }

    pub fn initRootStructWithGrower(self: *MessageBuilder, comptime T: type, comptime trait: BuilderTrait(T), grower: ?*Grower) BuildError!T {
        if (self.count != 1 or self.segments[0].len != 0) return Error.RootAlreadyInitialized;

        // The root pointer must be segment 0, word 0.
        var ctx = self.allocAssert(0, 8, grower);
        return trait.builder(try ctx.allocStruct(trait.data_words, trait.ptr_words));
    }
};

/// A message builder that owns its segments and can grow on demand. Use this
/// when the final message size is not known up front. It will use
/// `next_segment_bytes` as the initial capacity and for each new segment.
pub const GrowableMessage = struct {
    builder: MessageBuilder,
    grower: Grower,

    pub fn init(allocator: Allocator, initial_bytes: u32) BuildError!GrowableMessage {
        var grower = Grower{ .allocator = allocator, .next_segment_bytes = initial_bytes };
        const first = try grower.grow(8);
        return .{
            .builder = MessageBuilder.initBuffer(first),
            .grower = grower,
        };
    }

    pub fn deinit(self: *GrowableMessage) void {
        self.builder.deinitSegments(self.grower.allocator);
    }

    pub fn reset(self: *GrowableMessage) void {
        if (self.builder.count == 0) return;
        for (self.builder.segments[1..self.builder.count], 1..) |segment, i| {
            self.grower.allocator.free(segment.ptr[0..self.builder.capacities[i]]);
        }
        self.builder.count = 1;
        self.builder.segments[0].len = 0;
        self.builder.traversal_counter = Counter{ .limit = 8 * 1024 * 1024 };
    }

    pub fn initRootStruct(self: *GrowableMessage, comptime T: type, comptime trait: BuilderTrait(T)) BuildError!T {
        return self.builder.initRootStructWithGrower(T, trait, &self.grower);
    }

    pub fn initFromAnyPointer(self: *GrowableMessage, source: AnyPointerReader) BuildError!void {
        return self.builder.initFromAnyPointerWithGrower(source, &self.grower);
    }

    pub fn alloc(self: *GrowableMessage, segment: u32, words: u32) BuildError!BuildContext {
        return self.builder.allocWithGrower(segment, words, &self.grower);
    }

    pub fn allocAssert(self: *GrowableMessage, segment: u32, bytes: u32) BuildContext {
        return self.builder.allocAssert(segment, bytes, &self.grower);
    }

    pub fn toReader(self: *const GrowableMessage) Message {
        return self.builder.toReader();
    }

    pub fn serializedSize(self: *const GrowableMessage) usize {
        return self.builder.serializedSize();
    }

    pub fn segmentSlices(self: *const GrowableMessage) []const []const u8 {
        return self.builder.segmentSlices();
    }

    pub fn segmentCount(self: *const GrowableMessage) usize {
        return self.builder.segmentCount();
    }

    pub fn writeHeader(self: *const GrowableMessage, buffer: []u8) Error![]const u8 {
        return self.builder.writeHeader(buffer);
    }

    pub fn writeToBuffer(self: *const GrowableMessage, buffer: []u8) Error![]u8 {
        return self.builder.writeToBuffer(buffer);
    }

    // pub fn writeTo(self: *const GrowableMessage, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    //     return self.builder.writeTo(writer);
    // }

    pub fn writePackedTo(self: *const GrowableMessage, writer: *std.Io.Writer, scratch: []u8) !void {
        return self.builder.writePackedTo(writer, scratch);
    }
};

threadlocal var static_traversal_counter: Counter = .{ .limit = std.math.maxInt(u32) };

pub fn getStaticRoot(comptime T: type, segments: []const []const u8) Error!T {
    static_traversal_counter = .{ .limit = std.math.maxInt(u32) };
    return T.fromReadContext(ReadContext.fromSegments(segments, &static_traversal_counter));
}

test "test MessageBuilder" {
    var builder = try GrowableMessage.init(std.testing.allocator, 1 << 16);
    defer builder.deinit();
    try std.testing.expectEqual(@as(usize, 1), builder.segmentCount());

    {
        const context = try builder.alloc(0, 1024);
        try std.testing.expectEqual(@as(u32, 0), context.segment);
        try std.testing.expectEqual(@as(u32, 0), context.offset_words);
        try std.testing.expectEqual(@as(usize, 8192), context.builder.segments[0].len);
    }

    {
        const context = try builder.alloc(0, 1024);
        try std.testing.expectEqual(@as(u32, 0), context.segment);
        try std.testing.expectEqual(@as(u32, 1024), context.offset_words);
        try std.testing.expectEqual(@as(usize, 16384), context.builder.segments[0].len);
    }

    {
        const context = try builder.alloc(0, 8192 * 2);
        try std.testing.expectEqual(@as(u32, 1), context.segment);
        try std.testing.expectEqual(@as(u32, 0), context.offset_words);
        try std.testing.expectEqual(@as(usize, 8192 * 2 * 8), context.builder.segments[1].len);
    }

    {
        const context = try builder.alloc(1, 1024);
        try std.testing.expectEqual(@as(u32, 0), context.segment);
        try std.testing.expectEqual(@as(u32, 2048), context.offset_words);
        try std.testing.expectEqual(@as(usize, 8192 * 3), context.builder.segments[0].len);
    }
}

test "MessageBuilder builds into caller-provided storage" {
    var storage: [64]u8 align(8) = undefined;
    var builder = MessageBuilder.initBuffer(&storage);

    const context = try builder.alloc(0, 4);
    try std.testing.expectEqual(@as(u32, 0), context.segment);
    try std.testing.expectEqual(@as(usize, 32), builder.segments[0].len);
    try std.testing.expectEqual(@as(usize, 1), builder.segmentCount());

    builder.reset();
    try std.testing.expectEqual(@as(usize, 0), builder.segments[0].len);
}

test "fixed MessageBuilder rejects overflow" {
    var storage: [8]u8 align(8) = undefined;
    var builder = MessageBuilder.initBuffer(&storage);

    _ = try builder.alloc(0, 1);
    try std.testing.expectError(error.NoSpaceLeft, builder.alloc(0, 1));
}

test "GrowableMessage reset reuses the initial segment" {
    var builder = try GrowableMessage.init(std.testing.allocator, 1024);
    defer builder.deinit();

    _ = try builder.alloc(0, 8);
    _ = try builder.alloc(0, 1024);
    try std.testing.expectEqual(@as(usize, 2), builder.segmentCount());

    builder.reset();
    try std.testing.expectEqual(@as(usize, 1), builder.segmentCount());
    try std.testing.expectEqual(@as(usize, 0), builder.builder.segments[0].len);
}

test "Message.fromOwnedBytes takes ownership" {
    var builder = try GrowableMessage.init(std.testing.allocator, 1024);
    defer builder.deinit();

    _ = try builder.alloc(0, 2);
    const size = try builder.serializedSize();
    const bytes = try std.testing.allocator.alloc(u8, size);
    _ = try builder.writeToBuffer(bytes);

    var message = try Message.fromOwnedBytes(bytes, std.testing.allocator);
    defer message.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), message.segments.len);
    try std.testing.expectEqual(builder.builder.segments[0].len, message.segments[0].len);
}

test "capnp struct sizes" {
    try std.testing.expectEqual(16, @sizeOf(Ptr));
    try std.testing.expectEqual(56, @sizeOf(AnyPointerReader));
    try std.testing.expectEqual(24, @sizeOf(AnyPointerBuilder));
    try std.testing.expectEqual(48, @sizeOf(StructReader));
    try std.testing.expectEqual(64, @sizeOf(ListBuilder(i32)));
    try std.testing.expectEqual(48, @sizeOf(ListReader(i32)));
    try std.testing.expectEqual(32, @sizeOf(StructBuilder));
    try std.testing.expectEqual(40, @sizeOf(ReadContext));
    try std.testing.expectEqual(24, @sizeOf(BuildContext));
}

test {
    _ = @import("packed_tests.zig");
    _ = @import("capnp_bug_tests.zig");
}
