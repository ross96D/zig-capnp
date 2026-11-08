const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

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
    segments: [][]u8,
    segment: u32,
    offset_words: u29,

    depth_counter: Counter = Counter{ .limit = 64 },
    traversal_counter: *Counter,

    pub fn offsetBytes(self: ReadContext) u32 {
        return self.offset_words << 3;
    }

    fn readWordAt(self: ReadContext, segment: u32, word: u32) Error!u64 {
        if (segment >= self.segments.len) return Error.InvalidPointer;
        const seg = self.segments[segment];
        const pos: u64 = @as(u64, word) * 8;
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

    pub fn fromSegments(segments: [][]u8, traversal_counter: *Counter) ReadContext {
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
};

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

pub const Struct = struct {
    pub const Builder = StructBuilder;
    pub const Reader = StructReader;
};

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
                .list => |list| {
                    const expected_element_size: u3 = switch (T) {
                        void => 0,
                        bool => 1,
                        u8, i8 => 2,
                        u16, i16 => 3,
                        u32, i32, f32 => 4,
                        u64, i64, f64 => 5,
                        else => @compileError("unsupported list element type"),
                    };
                    if (list.element_size != expected_element_size) return Error.TypeMismatch;

                    return Self{
                        .context = _context,
                        .elementSize = list.element_size,
                        .length = list.elements_or_words,
                    };
                },
                else => return Error.TypeMismatch,
            }
        }

        pub fn fromNull(context: ReadContext) Self {
            return .{ .context = context, .elementSize = 0, .length = 0 };
        }

        pub fn get(self: Self, ix: u32) T {
            return self.context.readInt(T, ix);
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
        const element_size: u3 = switch (T) {
            void => 0,
            bool => 1,
            u8, i8 => 2,
            u16, i16 => 3,
            u32, i32, f32 => 4,
            u64, i64, f64 => 5,
            else => unreachable,
        };

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

            const element_count: u32 = length;
            const size_in_words: u32 = switch (element_size) {
                0 => 0,
                1 => (element_count + 63) / 64,
                2 => (element_count + 7) / 8,
                3 => (element_count + 3) / 4,
                4 => (element_count + 1) / 2,
                5 => element_count,
                else => unreachable,
            };

            const object = try self.ptr.builder.allocObject(self.ptr, size_in_words);
            self.context = object.content;
            self.length = length;

            try writeObjectPointer(&self.ptr, object, Ptr{ .list = .{
                .offset_words = 0,
                .elements_or_words = length,
                .element_size = element_size,
            } });
        }

        pub fn set(self: *Self, index: u32, value: T) void {
            std.debug.assert(self.context != null);
            std.debug.assert(index < self.length);
            self.context.?.writeInt(T, index, value);
        }

        pub fn get(self: Self, ix: u32) T {
            std.debug.assert(ix < self.length);
            return self.context.?.readInt(T, ix);
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
                .list => |list_ptr| {
                    if (list_ptr.element_size != 7) return Error.TypeMismatch;

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

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        for (self.segments) |segment| {
            allocator.free(segment);
        }
        allocator.free(self.segments);
    }

    pub fn getRootStruct(self: *Message, comptime T: type, comptime trait: ReaderTrait(T)) Error!T {
        self.traversal_counter = Counter{ .limit = 8 * 1024 * 1024 };
        return trait.reader(try StructReader.fromReadContext(ReadContext.fromSegments(self.segments, &self.traversal_counter)));
    }
};

pub const BuildContext = struct {
    builder: *MessageBuilder,
    segments: *[][]u8,
    segment: u32,
    offset_words: u29,

    pub fn offsetBytes(self: BuildContext) u32 {
        return self.offset_words << 3;
    }

    pub fn readIntWithBound(self: BuildContext, comptime T: type, offset: u32, boundWords: u29) T {
        const pos = self.offsetBytes() + @sizeOf(T) * offset;
        return if (@sizeOf(T) * offset < boundWords << 3) std.mem.readInt(T, self.segments.*[self.segment][pos..][0..@sizeOf(T)], .little) else 0;
    }

    pub fn readInt(self: BuildContext, comptime T: type, offset: u32) T {
        const pos = self.offsetBytes() + @sizeOf(T) * offset;
        return std.mem.readInt(T, self.segments.*[self.segment][pos..][0..@sizeOf(T)], .little);
    }

    pub fn writeInt(self: BuildContext, comptime T: type, offset: u32, value: T) void {
        const pos = self.offsetBytes() + @sizeOf(T) * offset;
        return std.mem.writeInt(T, self.segments.*[self.segment][pos..][0..@sizeOf(T)], value, .little);
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

pub const MessageBuilder = struct {
    allocator: Allocator = std.heap.page_allocator,
    // Capacity for the next new segment. Grows geometrically, capped at max_segment_bytes.
    next_segment_bytes: u32 = 1 << 16,
    segment_store: [16][]u8 = std.mem.zeroes([16][]u8),
    segment_capacity: [16]u32 = std.mem.zeroes([16]u32),
    segments: [][]u8 = std.mem.zeroes([][]u8),

    pub fn init(self: *MessageBuilder) BuildError!void {
        _ = try self.expandAssert(1);
    }

    inline fn segmentCapacity(self: MessageBuilder, segment: u32) u32 {
        return self.segment_capacity[segment];
    }

    pub fn expandAssert(self: *MessageBuilder, min_bytes: u32) BuildError!u32 {
        const len: u32 = @intCast(self.segments.len);
        if (len == self.segment_capacity.len) return Error.SegmentLimitReached;
        if (min_bytes > max_segment_bytes) return Error.MessageTooLarge;

        var capacity: u32 = self.next_segment_bytes;
        if (capacity < min_bytes) {
            capacity = std.math.ceilPowerOfTwo(u32, min_bytes) catch max_segment_bytes;
        }
        if (capacity > max_segment_bytes) capacity = max_segment_bytes;
        if (capacity < min_bytes) return Error.MessageTooLarge;

        self.segment_store[len] = try self.allocator.alloc(u8, capacity);
        self.segment_store[len].len = 0;
        self.segment_capacity[len] = capacity;
        self.next_segment_bytes = @min(std.math.mul(u32, capacity, 2) catch max_segment_bytes, max_segment_bytes);
        self.segments = self.segment_store[0 .. len + 1];
        return len;
    }

    pub fn allocAssert(self: *MessageBuilder, segment: u32, bytes: u32) BuildContext {
        std.debug.assert(segment < self.segments.len);
        std.debug.assert(@as(u64, self.segments[segment].len) + bytes <= self.segmentCapacity(segment));

        defer self.segments[segment].len += bytes;
        const seg = self.segments[segment];
        @memset(seg.ptr[seg.len .. seg.len + bytes], 0);
        return .{ .builder = self, .segments = &self.segments, .segment = segment, .offset_words = @intCast(seg.len >> 3) };
    }

    /// try to allocate in the given segment.
    pub fn alloc(self: *MessageBuilder, segment: u32, words: u32) BuildError!BuildContext {
        const bytes: u32 = std.math.mul(u32, words, 8) catch return Error.MessageTooLarge;
        if (bytes > max_segment_bytes) return Error.MessageTooLarge;

        if (segment < self.segments.len) {
            const used: u64 = self.segments[segment].len;
            if (used + bytes <= self.segmentCapacity(segment)) {
                return self.allocAssert(segment, bytes);
            }
        }

        var best_ix: u32 = 0;
        var best_spare: i64 = -1;

        for (self.segments, 0..) |seg, n_| {
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
            const new_segment = try self.expandAssert(bytes);
            return self.allocAssert(new_segment, bytes);
        }

        return self.allocAssert(best_ix, bytes);
    }

    fn allocObject(self: *MessageBuilder, pointer: BuildContext, words: u32) BuildError!Object {
        const bytes = std.math.mul(u32, words, 8) catch return Error.MessageTooLarge;
        if (bytes > max_segment_bytes) return Error.MessageTooLarge;

        // Prefer placing the object in the pointer's own segment.
        if (pointer.segment < self.segments.len) {
            const used: u64 = self.segments[pointer.segment].len;
            if (used + bytes <= self.segmentCapacity(pointer.segment)) {
                return .{
                    .tag = pointer,
                    .content = self.allocAssert(pointer.segment, bytes),
                    .needs_far = false,
                };
            }
        }

        // Reserve [landing pad][payload] contiguously in another segment.
        const padded_words = std.math.add(u32, words, 1) catch return Error.MessageTooLarge;
        const start = try self.alloc(pointer.segment, padded_words);

        var content = start;
        content.offset_words += 1;

        return .{
            .tag = start,
            .content = content,
            .needs_far = true,
        };
    }

    pub fn deinit(self: *MessageBuilder) void {
        for (self.segments, 0..) |*segment, n| {
            segment.len = self.segmentCapacity(@as(u32, @intCast(n)));
            self.allocator.free(segment.*);
        }
    }

    pub fn toReader(self: MessageBuilder) Message {
        return Message{ .segments = self.segments };
    }

    pub fn initRootStruct(self: *MessageBuilder, comptime T: type, comptime trait: BuilderTrait(T)) BuildError!T {
        if (self.segments.len != 1 or self.segments[0].len != 0) return Error.RootAlreadyInitialized;

        // The root pointer must be segment 0, word 0.
        var ctx = self.allocAssert(0, 8);
        return trait.builder(try ctx.allocStruct(trait.data_words, trait.ptr_words));
    }
};

test "test MessageBuilder" {
    var builder = MessageBuilder{ .allocator = std.testing.allocator };
    try builder.init();
    defer builder.deinit();
    try std.testing.expectEqual(@as(usize, 1), builder.segments.len);

    {
        const context = try builder.alloc(0, 1024);
        try std.testing.expectEqual(@as(u32, 0), context.segment);
        try std.testing.expectEqual(@as(u32, 0), context.offset_words);
        try std.testing.expectEqual(@as(usize, 8192), context.segments.*[0].len);
    }

    {
        const context = try builder.alloc(0, 1024);
        try std.testing.expectEqual(@as(u32, 0), context.segment);
        try std.testing.expectEqual(@as(u32, 1024), context.offset_words);
        try std.testing.expectEqual(@as(usize, 16384), context.segments.*[0].len);
    }

    {
        const context = try builder.alloc(0, 8192 * 2);
        try std.testing.expectEqual(@as(u32, 1), context.segment);
        try std.testing.expectEqual(@as(u32, 0), context.offset_words);
        try std.testing.expectEqual(@as(usize, 8192 * 2 * 8), context.segments.*[1].len);
    }

    {
        const context = try builder.alloc(1, 1024);
        try std.testing.expectEqual(@as(u32, 0), context.segment);
        try std.testing.expectEqual(@as(u32, 2048), context.offset_words);
        try std.testing.expectEqual(@as(usize, 8192 * 3), context.segments.*[0].len);
    }
}

test {
    _ = @import("capnp_bug_tests.zig");
}
