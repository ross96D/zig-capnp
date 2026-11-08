const std = @import("std");
const capnp = @import("capnp");
const _Schema = @This();

const ReadOnlyBuilder = struct {
    builder: capnp.StructBuilder,

    pub fn fromStructBuilder(builder: capnp.StructBuilder) @This() {
        return .{ .builder = builder };
    }
};

pub const Node = struct {
    const id: u64 = 0xe682ab4cf923a417;

    pub const struct_ = struct {
        const id: u64 = 0x9ea0b19b37fb4435;

        pub const _Group = struct {};

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 6,
            .ptr_words = 6,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getDataWordCount(self: @This()) u16 {
                return self.reader.readIntField(u16, 7) ^ 0;
            }

            pub fn getPointerCount(self: @This()) u16 {
                return self.reader.readIntField(u16, 12) ^ 0;
            }

            pub fn getPreferredListEncoding(self: @This()) _Schema.ElementSize {
                return @fromBackingInt(@intCast(self.reader.readIntField(u16, 13) ^ 0));
            }

            pub fn getIsGroup(self: @This()) bool {
                return self.reader.readBoolField(224);
            }

            pub fn getDiscriminantCount(self: @This()) u16 {
                return self.reader.readIntField(u16, 15) ^ 0;
            }

            pub fn getDiscriminantOffset(self: @This()) u32 {
                return self.reader.readIntField(u32, 8) ^ 0;
            }

            pub fn getFields(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Field.Reader, _Schema.Field.reader_trait) {
                return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Field.Reader, _Schema.Field.reader_trait), 3);
            }
        };
    };

    pub const enum_ = struct {
        const id: u64 = 0xb54ab3364333f598;

        pub const _Group = struct {};

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 6,
            .ptr_words = 6,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getEnumerants(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Enumerant.Reader, _Schema.Enumerant.reader_trait) {
                return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Enumerant.Reader, _Schema.Enumerant.reader_trait), 3);
            }
        };
    };

    pub const interface = struct {
        const id: u64 = 0xe82753cff0c2218f;

        pub const _Group = struct {};

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 6,
            .ptr_words = 6,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getMethods(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Method.Reader, _Schema.Method.reader_trait) {
                return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Method.Reader, _Schema.Method.reader_trait), 3);
            }

            pub fn getSuperclasses(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Superclass.Reader, _Schema.Superclass.reader_trait) {
                return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Superclass.Reader, _Schema.Superclass.reader_trait), 4);
            }
        };
    };

    pub const const_ = struct {
        const id: u64 = 0xb18aa5ac7a0d9420;

        pub const _Group = struct {};

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 6,
            .ptr_words = 6,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getType(self: @This()) capnp.Error!_Schema.Type.Reader {
                return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 3) };
            }

            pub fn getValue(self: @This()) capnp.Error!_Schema.Value.Reader {
                return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 4) };
            }
        };
    };

    pub const annotation = struct {
        const id: u64 = 0xec1619d4400a0290;

        pub const _Group = struct {};

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 6,
            .ptr_words = 6,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getType(self: @This()) capnp.Error!_Schema.Type.Reader {
                return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 3) };
            }

            pub fn getTargetsFile(self: @This()) bool {
                return self.reader.readBoolField(112);
            }

            pub fn getTargetsConst(self: @This()) bool {
                return self.reader.readBoolField(113);
            }

            pub fn getTargetsEnum(self: @This()) bool {
                return self.reader.readBoolField(114);
            }

            pub fn getTargetsEnumerant(self: @This()) bool {
                return self.reader.readBoolField(115);
            }

            pub fn getTargetsStruct(self: @This()) bool {
                return self.reader.readBoolField(116);
            }

            pub fn getTargetsField(self: @This()) bool {
                return self.reader.readBoolField(117);
            }

            pub fn getTargetsUnion(self: @This()) bool {
                return self.reader.readBoolField(118);
            }

            pub fn getTargetsGroup(self: @This()) bool {
                return self.reader.readBoolField(119);
            }

            pub fn getTargetsInterface(self: @This()) bool {
                return self.reader.readBoolField(120);
            }

            pub fn getTargetsMethod(self: @This()) bool {
                return self.reader.readBoolField(121);
            }

            pub fn getTargetsParam(self: @This()) bool {
                return self.reader.readBoolField(122);
            }

            pub fn getTargetsAnnotation(self: @This()) bool {
                return self.reader.readBoolField(123);
            }
        };
    };

    pub const parameter = struct {
        const id: u64 = 0xb9521bccf10fa3b1;

        pub const _Group = struct {};

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 0,
            .ptr_words = 1,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getName(self: @This()) capnp.Error![:0]const u8 {
                return try self.reader.readStringField(0);
            }
        };
    };

    pub const NestedNode = struct {
        const id: u64 = 0xdebf55bbfa0fc242;

        pub const _Group = struct {};

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 1,
            .ptr_words = 1,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getName(self: @This()) capnp.Error![:0]const u8 {
                return try self.reader.readStringField(0);
            }

            pub fn getId(self: @This()) u64 {
                return self.reader.readIntField(u64, 0) ^ 0;
            }
        };
    };

    pub const SourceInfo = struct {
        const id: u64 = 0xf38e1de3041357ae;

        pub const _Group = struct {};

        pub const Member = struct {
            const id: u64 = 0xc2ba9038898e1fa2;

            pub const _Group = struct {};

            pub const Builder = ReadOnlyBuilder;
            pub const reader_trait = capnp.ReaderTrait(@This().Reader){
                .reader = @This().Reader.fromStructReader,
            };
            pub const builder_trait = capnp.BuilderTrait(@This().Builder){
                .data_words = 0,
                .ptr_words = 1,
                .builder = @This().Builder.fromStructBuilder,
            };

            pub const Reader = struct {
                reader: capnp.StructReader,
                pub fn fromStructReader(reader: capnp.StructReader) @This() {
                    return .{ .reader = reader };
                }

                pub fn getDocComment(self: @This()) capnp.Error![:0]const u8 {
                    return try self.reader.readStringField(0);
                }
            };
        };

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 2,
            .ptr_words = 2,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getId(self: @This()) u64 {
                return self.reader.readIntField(u64, 0) ^ 0;
            }

            pub fn getDocComment(self: @This()) capnp.Error![:0]const u8 {
                return try self.reader.readStringField(0);
            }

            pub fn getMembers(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Node.SourceInfo.Member.Reader, _Schema.Node.SourceInfo.Member.reader_trait) {
                return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Node.SourceInfo.Member.Reader, _Schema.Node.SourceInfo.Member.reader_trait), 1);
            }
        };
    };

    pub const Tag = enum(u16) {
        file,
        @"struct",
        @"enum",
        interface,
        @"const",
        annotation,
        _,
    };

    pub const Builder = ReadOnlyBuilder;
    pub const reader_trait = capnp.ReaderTrait(@This().Reader){
        .reader = @This().Reader.fromStructReader,
    };
    pub const builder_trait = capnp.BuilderTrait(@This().Builder){
        .data_words = 6,
        .ptr_words = 6,
        .builder = @This().Builder.fromStructBuilder,
    };

    pub const Reader = struct {
        reader: capnp.StructReader,
        pub fn fromStructReader(reader: capnp.StructReader) @This() {
            return .{ .reader = reader };
        }

        pub fn which(self: @This()) Tag {
            return @fromBackingInt(@intCast(self.reader.readIntField(u16, 6)));
        }

        pub fn getStruct(self: @This()) ?struct_.Reader {
            return if (self.which() == Tag.@"struct") .{ .reader = self.reader } else null;
        }

        pub fn getId(self: @This()) u64 {
            return self.reader.readIntField(u64, 0) ^ 0;
        }

        pub fn getEnum(self: @This()) ?enum_.Reader {
            return if (self.which() == Tag.@"enum") .{ .reader = self.reader } else null;
        }

        pub fn getConst(self: @This()) ?const_.Reader {
            return if (self.which() == Tag.@"const") .{ .reader = self.reader } else null;
        }

        pub fn getDisplayName(self: @This()) capnp.Error![:0]const u8 {
            return try self.reader.readStringField(0);
        }

        pub fn getDisplayNamePrefixLength(self: @This()) u32 {
            return self.reader.readIntField(u32, 2) ^ 0;
        }

        pub fn getScopeId(self: @This()) u64 {
            return self.reader.readIntField(u64, 2) ^ 0;
        }

        pub fn getNestedNodes(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Node.NestedNode.Reader, _Schema.Node.NestedNode.reader_trait) {
            return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Node.NestedNode.Reader, _Schema.Node.NestedNode.reader_trait), 1);
        }

        pub fn getAnnotations(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Annotation.Reader, _Schema.Annotation.reader_trait) {
            return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Annotation.Reader, _Schema.Annotation.reader_trait), 2);
        }

        pub fn getParameters(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Node.parameter.Reader, _Schema.Node.parameter.reader_trait) {
            return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Node.parameter.Reader, _Schema.Node.parameter.reader_trait), 5);
        }

        pub fn getIsGeneric(self: @This()) bool {
            return self.reader.readBoolField(288);
        }
    };
};

pub const Field = struct {
    const id: u64 = 0x9aad50a41f4af45f;

    pub const Tag = enum(u16) {
        slot,
        group,
        _,
    };

    pub const slot = struct {
        const id: u64 = 0xc42305476bb4746f;

        pub const _Group = struct {};

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 3,
            .ptr_words = 4,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getOffset(self: @This()) u32 {
                return self.reader.readIntField(u32, 1) ^ 0;
            }

            pub fn getType(self: @This()) capnp.Error!_Schema.Type.Reader {
                return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 2) };
            }

            pub fn getDefaultValue(self: @This()) capnp.Error!_Schema.Value.Reader {
                return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 3) };
            }

            pub fn getHadExplicitDefault(self: @This()) bool {
                return self.reader.readBoolField(128);
            }
        };
    };

    pub const group = struct {
        const id: u64 = 0xcafccddb68db1d11;

        pub const _Group = struct {};

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 3,
            .ptr_words = 4,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getTypeId(self: @This()) u64 {
                return self.reader.readIntField(u64, 2) ^ 0;
            }
        };
    };

    pub const ordinal = struct {
        const id: u64 = 0xbb90d5c287870be6;

        pub const _Group = struct {};

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 3,
            .ptr_words = 4,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub const _Tag = union(enum) {
                implicit: void,
                explicit: u16,
                _: u16,
            };

            pub fn which(self: @This()) capnp.Error!_Tag {
                return switch (self.reader.readIntField(u16, 5)) {
                    0 => _Tag{ .implicit = {} },
                    1 => _Tag{ .explicit = self.reader.readIntField(u16, 6) ^ 0 },
                    else => |n| _Tag{ ._ = n },
                };
            }
        };
    };

    pub const Builder = ReadOnlyBuilder;
    pub const reader_trait = capnp.ReaderTrait(@This().Reader){
        .reader = @This().Reader.fromStructReader,
    };
    pub const builder_trait = capnp.BuilderTrait(@This().Builder){
        .data_words = 3,
        .ptr_words = 4,
        .builder = @This().Builder.fromStructBuilder,
    };

    pub const Reader = struct {
        reader: capnp.StructReader,
        pub fn fromStructReader(reader: capnp.StructReader) @This() {
            return .{ .reader = reader };
        }

        pub fn which(self: @This()) Field.Tag {
            return @fromBackingInt(@intCast(self.reader.readIntField(u16, 4)));
        }

        pub fn getSlot(self: @This()) ?slot.Reader {
            return if (self.which() == Tag.slot) .{ .reader = self.reader } else null;
        }

        pub fn getGroup(self: @This()) ?group.Reader {
            return if (self.which() == Tag.group) .{ .reader = self.reader } else null;
        }

        pub fn getName(self: @This()) capnp.Error![:0]const u8 {
            return try self.reader.readStringField(0);
        }

        pub fn getCodeOrder(self: @This()) u16 {
            return self.reader.readIntField(u16, 0) ^ 0;
        }

        pub fn getAnnotations(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Annotation.Reader, _Schema.Annotation.reader_trait) {
            return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Annotation.Reader, _Schema.Annotation.reader_trait), 1);
        }

        pub fn getDiscriminantValue(self: @This()) u16 {
            return self.reader.readIntField(u16, 1) ^ 65535;
        }

        pub fn getOrdinal(self: @This()) _Schema.Field.ordinal.Reader {
            return .{ .reader = self.reader };
        }
    };
};

pub const Enumerant = struct {
    const id: u64 = 0x978a7cebdc549a4d;

    pub const _Group = struct {};

    pub const Builder = ReadOnlyBuilder;
    pub const reader_trait = capnp.ReaderTrait(@This().Reader){
        .reader = @This().Reader.fromStructReader,
    };
    pub const builder_trait = capnp.BuilderTrait(@This().Builder){
        .data_words = 1,
        .ptr_words = 2,
        .builder = @This().Builder.fromStructBuilder,
    };

    pub const Reader = struct {
        reader: capnp.StructReader,
        pub fn fromStructReader(reader: capnp.StructReader) @This() {
            return .{ .reader = reader };
        }

        pub fn getName(self: @This()) capnp.Error![:0]const u8 {
            return try self.reader.readStringField(0);
        }

        pub fn getCodeOrder(self: @This()) u16 {
            return self.reader.readIntField(u16, 0) ^ 0;
        }

        pub fn getAnnotations(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Annotation.Reader, _Schema.Annotation.reader_trait) {
            return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Annotation.Reader, _Schema.Annotation.reader_trait), 1);
        }
    };
};

pub const Superclass = struct {
    const id: u64 = 0xa9962a9ed0a4d7f8;

    pub const _Group = struct {};

    pub const Builder = ReadOnlyBuilder;
    pub const reader_trait = capnp.ReaderTrait(@This().Reader){
        .reader = @This().Reader.fromStructReader,
    };
    pub const builder_trait = capnp.BuilderTrait(@This().Builder){
        .data_words = 1,
        .ptr_words = 1,
        .builder = @This().Builder.fromStructBuilder,
    };

    pub const Reader = struct {
        reader: capnp.StructReader,
        pub fn fromStructReader(reader: capnp.StructReader) @This() {
            return .{ .reader = reader };
        }

        pub fn getId(self: @This()) u64 {
            return self.reader.readIntField(u64, 0) ^ 0;
        }

        pub fn getBrand(self: @This()) capnp.Error!_Schema.Brand.Reader {
            return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 0) };
        }
    };
};

pub const Method = struct {
    const id: u64 = 0x9500cce23b334d80;

    pub const _Group = struct {};

    pub const Builder = ReadOnlyBuilder;
    pub const reader_trait = capnp.ReaderTrait(@This().Reader){
        .reader = @This().Reader.fromStructReader,
    };
    pub const builder_trait = capnp.BuilderTrait(@This().Builder){
        .data_words = 3,
        .ptr_words = 5,
        .builder = @This().Builder.fromStructBuilder,
    };

    pub const Reader = struct {
        reader: capnp.StructReader,
        pub fn fromStructReader(reader: capnp.StructReader) @This() {
            return .{ .reader = reader };
        }

        pub fn getName(self: @This()) capnp.Error![:0]const u8 {
            return try self.reader.readStringField(0);
        }

        pub fn getCodeOrder(self: @This()) u16 {
            return self.reader.readIntField(u16, 0) ^ 0;
        }

        pub fn getParamStructType(self: @This()) u64 {
            return self.reader.readIntField(u64, 1) ^ 0;
        }

        pub fn getResultStructType(self: @This()) u64 {
            return self.reader.readIntField(u64, 2) ^ 0;
        }

        pub fn getAnnotations(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Annotation.Reader, _Schema.Annotation.reader_trait) {
            return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Annotation.Reader, _Schema.Annotation.reader_trait), 1);
        }

        pub fn getParamBrand(self: @This()) capnp.Error!_Schema.Brand.Reader {
            return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 2) };
        }

        pub fn getResultBrand(self: @This()) capnp.Error!_Schema.Brand.Reader {
            return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 3) };
        }

        pub fn getImplicitParameters(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Node.parameter.Reader, _Schema.Node.parameter.reader_trait) {
            return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Node.parameter.Reader, _Schema.Node.parameter.reader_trait), 4);
        }
    };
};

pub const Type = struct {
    const id: u64 = 0xd07378ede1f9cc60;

    pub const List = struct {
        const id: u64 = 0x87e739250a60ea97;

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 3,
            .ptr_words = 1,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getElementType(self: @This()) capnp.Error!_Schema.Type.Reader {
                return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 0) };
            }
        };
    };

    pub const Enum = struct {
        const id: u64 = 0x9e0e78711a7f87a9;

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 3,
            .ptr_words = 1,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getTypeId(self: @This()) u64 {
                return self.reader.readIntField(u64, 1) ^ 0;
            }

            pub fn getBrand(self: @This()) capnp.Error!_Schema.Brand.Reader {
                return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 0) };
            }
        };
    };

    pub const Struct = struct {
        const id: u64 = 0xac3a6f60ef4cc6d3;

        pub const _Group = struct {};

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 3,
            .ptr_words = 1,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getTypeId(self: @This()) u64 {
                return self.reader.readIntField(u64, 1) ^ 0;
            }

            pub fn getBrand(self: @This()) capnp.Error!_Schema.Brand.Reader {
                return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 0) };
            }
        };
    };

    pub const Interface = struct {
        const id: u64 = 0xed8bca69f7fb0cbf;

        pub const _Group = struct {};

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 3,
            .ptr_words = 1,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getTypeId(self: @This()) u64 {
                return self.reader.readIntField(u64, 1) ^ 0;
            }

            pub fn getBrand(self: @This()) capnp.Error!_Schema.Brand.Reader {
                return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 0) };
            }
        };
    };

    pub const AnyPointer = struct {
        const id: u64 = 0xc2573fe8a23e49f1;

        pub const _Group = struct {
            pub const Unconstrained = struct {
                pub const _Tag = union(enum) {
                    anyKind: void,
                    struct_: void,
                    list: void,
                    capability: void,
                    _: u16,
                };

                const id: u64 = 0x8e3b5f79fe593656;

                pub const _Group = struct {};

                pub const Builder = ReadOnlyBuilder;
                pub const reader_trait = capnp.ReaderTrait(@This().Reader){
                    .reader = @This().Reader.fromStructReader,
                };
                pub const builder_trait = capnp.BuilderTrait(@This().Builder){
                    .data_words = 3,
                    .ptr_words = 1,
                    .builder = @This().Builder.fromStructBuilder,
                };

                pub const Reader = struct {
                    reader: capnp.StructReader,
                    pub fn fromStructReader(reader: capnp.StructReader) @This() {
                        return .{ .reader = reader };
                    }

                    pub fn which(self: @This()) capnp.Error!_Tag {
                        return switch (self.reader.readIntField(u16, 5)) {
                            0 => _Tag{ .anyKind = {} },
                            1 => _Tag{ .struct_ = {} },
                            2 => _Tag{ .list = {} },
                            3 => _Tag{ .capability = {} },
                            else => |n| _Tag{ ._ = n },
                        };
                    }
                };
            };

            pub const Parameter = struct {
                const id: u64 = 0x9dd1f724f4614a85;

                pub const _Group = struct {};

                pub const Builder = ReadOnlyBuilder;
                pub const reader_trait = capnp.ReaderTrait(@This().Reader){
                    .reader = @This().Reader.fromStructReader,
                };
                pub const builder_trait = capnp.BuilderTrait(@This().Builder){
                    .data_words = 3,
                    .ptr_words = 1,
                    .builder = @This().Builder.fromStructBuilder,
                };

                pub const Reader = struct {
                    reader: capnp.StructReader,
                    pub fn fromStructReader(reader: capnp.StructReader) @This() {
                        return .{ .reader = reader };
                    }

                    pub fn getScopeId(self: @This()) u64 {
                        return self.reader.readIntField(u64, 2) ^ 0;
                    }

                    pub fn getParameterIndex(self: @This()) u16 {
                        return self.reader.readIntField(u16, 5) ^ 0;
                    }
                };
            };

            pub const ImplicitMethodParameter = struct {
                const id: u64 = 0xbaefc9120c56e274;

                pub const _Group = struct {};

                pub const Builder = ReadOnlyBuilder;
                pub const reader_trait = capnp.ReaderTrait(@This().Reader){
                    .reader = @This().Reader.fromStructReader,
                };
                pub const builder_trait = capnp.BuilderTrait(@This().Builder){
                    .data_words = 3,
                    .ptr_words = 1,
                    .builder = @This().Builder.fromStructBuilder,
                };

                pub const Reader = struct {
                    reader: capnp.StructReader,
                    pub fn fromStructReader(reader: capnp.StructReader) @This() {
                        return .{ .reader = reader };
                    }

                    pub fn getParameterIndex(self: @This()) u16 {
                        return self.reader.readIntField(u16, 5) ^ 0;
                    }
                };
            };
        };

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 3,
            .ptr_words = 1,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub const _Tag = union(enum) {
                unconstrained: _Schema.Type.AnyPointer._Group.Unconstrained.Reader,
                parameter: _Schema.Type.AnyPointer._Group.Parameter.Reader,
                implicitMethodParameter: _Schema.Type.AnyPointer._Group.ImplicitMethodParameter.Reader,
                _: u16,
            };

            pub fn which(self: @This()) capnp.Error!_Tag {
                return switch (self.reader.readIntField(u16, 4)) {
                    0 => _Tag{ .unconstrained = .{ .reader = self.reader } },
                    1 => _Tag{ .parameter = .{ .reader = self.reader } },
                    2 => _Tag{ .implicitMethodParameter = .{ .reader = self.reader } },
                    else => |n| _Tag{ ._ = n },
                };
            }
        };
    };

    pub const Tag = enum(u16) {
        void,
        bool,
        int8,
        int16,
        int32,
        int64,
        uint8,
        uint16,
        uint32,
        uint64,
        float32,
        float64,
        text,
        data,
        list,
        enum_,
        struct_,
        interface,
        anyPointer,
        _,
    };

    pub const Builder = ReadOnlyBuilder;
    pub const reader_trait = capnp.ReaderTrait(@This().Reader){
        .reader = @This().Reader.fromStructReader,
    };
    pub const builder_trait = capnp.BuilderTrait(@This().Builder){
        .data_words = 3,
        .ptr_words = 1,
        .builder = @This().Builder.fromStructBuilder,
    };

    pub const Reader = struct {
        reader: capnp.StructReader,
        pub fn fromStructReader(reader: capnp.StructReader) @This() {
            return .{ .reader = reader };
        }

        pub fn which(self: @This()) Tag {
            return @fromBackingInt(@intCast(self.reader.readIntField(u16, 0)));
        }

        pub fn getList(self: @This()) ?Type.List.Reader {
            return if (self.which() == Tag.list) .{ .reader = self.reader } else null;
        }

        pub fn getStruct(self: @This()) ?Type.Struct.Reader {
            return if (self.which() == Tag.struct_) .{ .reader = self.reader } else null;
        }

        pub fn getEnum(self: @This()) ?Type.Enum.Reader {
            return if (self.which() == Tag.enum_) .{ .reader = self.reader } else null;
        }
    };
};

pub const Brand = struct {
    const id: u64 = 0x903455f06065422b;

    pub const _Group = struct {};

    pub const Scope = struct {
        const id: u64 = 0xabd73485a9636bc9;

        pub const _Group = struct {};

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 2,
            .ptr_words = 1,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub const _Tag = union(enum) {
                bind: capnp.CompositeListReader(_Schema.Brand.Binding.Reader, _Schema.Brand.Binding.reader_trait),
                inherit: void,
                _: u16,
            };

            pub fn which(self: @This()) capnp.Error!_Tag {
                return switch (self.reader.readIntField(u16, 4)) {
                    0 => _Tag{ .bind = try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Brand.Binding.Reader, _Schema.Brand.Binding.reader_trait), 0) },
                    1 => _Tag{ .inherit = {} },
                    else => |n| _Tag{ ._ = n },
                };
            }
            pub fn getScopeId(self: @This()) u64 {
                return self.reader.readIntField(u64, 0) ^ 0;
            }
        };
    };

    pub const Binding = struct {
        const id: u64 = 0xc863cd16969ee7fc;

        pub const _Group = struct {};

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 1,
            .ptr_words = 1,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub const _Tag = union(enum) {
                unbound: void,
                type: _Schema.Type.Reader,
                _: u16,
            };

            pub fn which(self: @This()) capnp.Error!_Tag {
                return switch (self.reader.readIntField(u16, 0)) {
                    0 => _Tag{ .unbound = {} },
                    1 => _Tag{ .type = .{ .reader = try self.reader.readPtrField(capnp.StructReader, 0) } },
                    else => |n| _Tag{ ._ = n },
                };
            }
        };
    };

    pub const Builder = ReadOnlyBuilder;
    pub const reader_trait = capnp.ReaderTrait(@This().Reader){
        .reader = @This().Reader.fromStructReader,
    };
    pub const builder_trait = capnp.BuilderTrait(@This().Builder){
        .data_words = 0,
        .ptr_words = 1,
        .builder = @This().Builder.fromStructBuilder,
    };

    pub const Reader = struct {
        reader: capnp.StructReader,
        pub fn fromStructReader(reader: capnp.StructReader) @This() {
            return .{ .reader = reader };
        }

        pub fn getScopes(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Brand.Scope.Reader, _Schema.Brand.Scope.reader_trait) {
            return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Brand.Scope.Reader, _Schema.Brand.Scope.reader_trait), 0);
        }
    };
};

pub const Value = struct {
    const id: u64 = 0xce23dcd2d7b00c9b;

    pub const _Group = struct {};

    pub const Builder = ReadOnlyBuilder;
    pub const reader_trait = capnp.ReaderTrait(@This().Reader){
        .reader = @This().Reader.fromStructReader,
    };
    pub const builder_trait = capnp.BuilderTrait(@This().Builder){
        .data_words = 2,
        .ptr_words = 1,
        .builder = @This().Builder.fromStructBuilder,
    };

    pub const Reader = struct {
        reader: capnp.StructReader,
        pub fn fromStructReader(reader: capnp.StructReader) @This() {
            return .{ .reader = reader };
        }

        pub const Tag = union(enum) {
            void: void,
            bool: bool,
            int8: i8,
            int16: i16,
            int32: i32,
            int64: i64,
            uint8: u8,
            uint16: u16,
            uint32: u32,
            uint64: u64,
            float32: f32,
            float64: f64,
            text: [:0]const u8,
            data: []const u8,
            list: capnp.AnyPointerReader,
            enum_: u16,
            struct_: capnp.AnyPointerReader,
            interface: void,
            anyPointer: capnp.AnyPointerReader,
            _: u16,
        };

        pub fn which(self: @This()) capnp.Error!Tag {
            return switch (self.reader.readIntField(u16, 0)) {
                0 => Tag{ .void = {} },
                1 => Tag{ .bool = self.reader.readBoolField(16) },
                2 => Tag{ .int8 = self.reader.readIntField(i8, 2) ^ 0 },
                3 => Tag{ .int16 = self.reader.readIntField(i16, 1) ^ 0 },
                4 => Tag{ .int32 = self.reader.readIntField(i32, 1) ^ 0 },
                5 => Tag{ .int64 = self.reader.readIntField(i64, 1) ^ 0 },
                6 => Tag{ .uint8 = self.reader.readIntField(u8, 2) ^ 0 },
                7 => Tag{ .uint16 = self.reader.readIntField(u16, 1) ^ 0 },
                8 => Tag{ .uint32 = self.reader.readIntField(u32, 1) ^ 0 },
                9 => Tag{ .uint64 = self.reader.readIntField(u64, 1) ^ 0 },
                10 => Tag{ .float32 = self.reader.readFloatField(f32, 1) },
                11 => Tag{ .float64 = self.reader.readFloatField(f64, 1) },
                12 => Tag{ .text = try self.reader.readStringField(0) },
                13 => Tag{ .data = try self.reader.readDataField(0) },
                14 => Tag{ .list = try self.reader.readPtrField(capnp.AnyPointerReader, 0) },
                15 => Tag{ .enum_ = self.reader.readIntField(u16, 1) ^ 0 },
                16 => Tag{ .struct_ = try self.reader.readPtrField(capnp.AnyPointerReader, 0) },
                17 => Tag{ .interface = {} },
                18 => Tag{ .anyPointer = try self.reader.readPtrField(capnp.AnyPointerReader, 0) },
                else => |n| Tag{ ._ = n },
            };
        }
    };
};

pub const Annotation = struct {
    const id: u64 = 0xf1c8950dab257542;

    pub const _Group = struct {};

    pub const Builder = ReadOnlyBuilder;
    pub const reader_trait = capnp.ReaderTrait(@This().Reader){
        .reader = @This().Reader.fromStructReader,
    };
    pub const builder_trait = capnp.BuilderTrait(@This().Builder){
        .data_words = 1,
        .ptr_words = 2,
        .builder = @This().Builder.fromStructBuilder,
    };

    pub const Reader = struct {
        reader: capnp.StructReader,
        pub fn fromStructReader(reader: capnp.StructReader) @This() {
            return .{ .reader = reader };
        }

        pub fn getId(self: @This()) u64 {
            return self.reader.readIntField(u64, 0) ^ 0;
        }

        pub fn getValue(self: @This()) capnp.Error!_Schema.Value.Reader {
            return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 0) };
        }

        pub fn getBrand(self: @This()) capnp.Error!_Schema.Brand.Reader {
            return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 1) };
        }
    };
};

pub const ElementSize = enum(u16) {
    empty,
    bit,
    byte,
    twoBytes,
    fourBytes,
    eightBytes,
    pointer,
    inlineComposite,
    _,
};
pub const CapnpVersion = struct {
    const id: u64 = 0xd85d305b7d839963;

    pub const _Group = struct {};

    pub const Builder = ReadOnlyBuilder;
    pub const reader_trait = capnp.ReaderTrait(@This().Reader){
        .reader = @This().Reader.fromStructReader,
    };
    pub const builder_trait = capnp.BuilderTrait(@This().Builder){
        .data_words = 1,
        .ptr_words = 0,
        .builder = @This().Builder.fromStructBuilder,
    };

    pub const Reader = struct {
        reader: capnp.StructReader,
        pub fn fromStructReader(reader: capnp.StructReader) @This() {
            return .{ .reader = reader };
        }

        pub fn getMajor(self: @This()) u16 {
            return self.reader.readIntField(u16, 0) ^ 0;
        }

        pub fn getMinor(self: @This()) u8 {
            return self.reader.readIntField(u8, 2) ^ 0;
        }

        pub fn getMicro(self: @This()) u8 {
            return self.reader.readIntField(u8, 3) ^ 0;
        }
    };
};

pub const CodeGeneratorRequest = struct {
    const id: u64 = 0xbfc546f6210ad7ce;

    pub const _Group = struct {};

    pub const RequestedFile = struct {
        const id: u64 = 0xcfea0eb02e810062;

        pub const _Group = struct {};

        pub const Import = struct {
            const id: u64 = 0xae504193122357e5;

            pub const _Group = struct {};

            pub const Builder = ReadOnlyBuilder;
            pub const reader_trait = capnp.ReaderTrait(@This().Reader){
                .reader = @This().Reader.fromStructReader,
            };
            pub const builder_trait = capnp.BuilderTrait(@This().Builder){
                .data_words = 1,
                .ptr_words = 1,
                .builder = @This().Builder.fromStructBuilder,
            };

            pub const Reader = struct {
                reader: capnp.StructReader,
                pub fn fromStructReader(reader: capnp.StructReader) @This() {
                    return .{ .reader = reader };
                }

                pub fn getId(self: @This()) u64 {
                    return self.reader.readIntField(u64, 0) ^ 0;
                }

                pub fn getName(self: @This()) capnp.Error![:0]const u8 {
                    return try self.reader.readStringField(0);
                }
            };
        };

        pub const Builder = ReadOnlyBuilder;
        pub const reader_trait = capnp.ReaderTrait(@This().Reader){
            .reader = @This().Reader.fromStructReader,
        };
        pub const builder_trait = capnp.BuilderTrait(@This().Builder){
            .data_words = 1,
            .ptr_words = 3,
            .builder = @This().Builder.fromStructBuilder,
        };

        pub const Reader = struct {
            reader: capnp.StructReader,
            pub fn fromStructReader(reader: capnp.StructReader) @This() {
                return .{ .reader = reader };
            }

            pub fn getId(self: @This()) u64 {
                return self.reader.readIntField(u64, 0) ^ 0;
            }

            pub fn getFilename(self: @This()) capnp.Error![:0]const u8 {
                return try self.reader.readStringField(0);
            }

            pub fn getImports(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.CodeGeneratorRequest.RequestedFile.Import.Reader, _Schema.CodeGeneratorRequest.RequestedFile.Import.reader_trait) {
                return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.CodeGeneratorRequest.RequestedFile.Import.Reader, _Schema.CodeGeneratorRequest.RequestedFile.Import.reader_trait), 1);
            }
        };
    };

    pub const Builder = ReadOnlyBuilder;
    pub const reader_trait = capnp.ReaderTrait(@This().Reader){
        .reader = @This().Reader.fromStructReader,
    };
    pub const builder_trait = capnp.BuilderTrait(@This().Builder){
        .data_words = 0,
        .ptr_words = 4,
        .builder = @This().Builder.fromStructBuilder,
    };

    pub const Reader = struct {
        reader: capnp.StructReader,
        pub fn fromStructReader(reader: capnp.StructReader) @This() {
            return .{ .reader = reader };
        }

        pub fn getNodes(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Node.Reader, _Schema.Node.reader_trait) {
            return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Node.Reader, _Schema.Node.reader_trait), 0);
        }

        pub fn getRequestedFiles(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.CodeGeneratorRequest.RequestedFile.Reader, _Schema.CodeGeneratorRequest.RequestedFile.reader_trait) {
            return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.CodeGeneratorRequest.RequestedFile.Reader, _Schema.CodeGeneratorRequest.RequestedFile.reader_trait), 1);
        }

        pub fn getCapnpVersion(self: @This()) capnp.Error!_Schema.CapnpVersion.Reader {
            return .{ .reader = try self.reader.readPtrField(capnp.StructReader, 2) };
        }

        pub fn getSourceInfo(self: @This()) capnp.Error!capnp.CompositeListReader(_Schema.Node.SourceInfo.Reader, _Schema.Node.SourceInfo.reader_trait) {
            return try self.reader.readPtrField(capnp.CompositeListReader(_Schema.Node.SourceInfo.Reader, _Schema.Node.SourceInfo.reader_trait), 3);
        }
    };
};

test "schema declarations are analyzable" {
    _ = &_Schema.Node.struct_.Reader.getFields;
    _ = &_Schema.Node.enum_.Reader.getEnumerants;
    _ = &_Schema.Node.interface.Reader.getMethods;
    _ = &_Schema.Node.interface.Reader.getSuperclasses;
    _ = &_Schema.Node.SourceInfo.Reader.getMembers;
    _ = &_Schema.Node.Reader.getNestedNodes;
    _ = &_Schema.Node.Reader.getAnnotations;
    _ = &_Schema.Node.Reader.getParameters;
    _ = &_Schema.Node.Reader.getStruct;
    _ = &_Schema.Node.Reader.getEnum;
    _ = &_Schema.Field.Reader.getAnnotations;
    _ = &_Schema.Enumerant.Reader.getAnnotations;
    _ = &_Schema.Method.Reader.getAnnotations;
    _ = &_Schema.Method.Reader.getImplicitParameters;
    _ = &_Schema.Superclass.Reader.getBrand;
    _ = &_Schema.Brand.Scope.Reader.which;
    _ = &_Schema.Brand.Reader.getScopes;
    _ = &_Schema.Type.Reader.which;
    _ = &_Schema.Type.Reader.getList;
    _ = &_Schema.Type.Reader.getStruct;
    _ = &_Schema.Type.Reader.getEnum;
    _ = &_Schema.Type.AnyPointer.Reader.which;
    _ = &_Schema.Value.Reader.which;
    _ = &_Schema.CodeGeneratorRequest.RequestedFile.Reader.getImports;
    _ = &_Schema.CodeGeneratorRequest.Reader.getNodes;
    _ = &_Schema.CodeGeneratorRequest.Reader.getRequestedFiles;
    _ = &_Schema.CodeGeneratorRequest.Reader.getSourceInfo;
}

const ExpectedStruct = struct {
    id: u64,
    name: []const u8,
    data_words: u16,
    ptr_words: u16,
    is_group: bool,
    discriminant_count: u16,
    discriminant_offset: u32,
};

// Golden table extracted from:
// capnp decode /usr/local/include/capnp/schema.capnp CodeGeneratorRequest \
//   < capnp-tests/06_schema.capnp.original.1.bin
const expected_schema_structs = [_]ExpectedStruct{
    .{ .id = 0x9aad50a41f4af45f, .name = "Field", .data_words = 3, .ptr_words = 4, .is_group = false, .discriminant_count = 2, .discriminant_offset = 4 },
    .{ .id = 0xe682ab4cf923a417, .name = "Node", .data_words = 6, .ptr_words = 6, .is_group = false, .discriminant_count = 6, .discriminant_offset = 6 },
    .{ .id = 0x9ea0b19b37fb4435, .name = "Node.struct", .data_words = 6, .ptr_words = 6, .is_group = true, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0x978a7cebdc549a4d, .name = "Enumerant", .data_words = 1, .ptr_words = 2, .is_group = false, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xb54ab3364333f598, .name = "Node.enum", .data_words = 6, .ptr_words = 6, .is_group = true, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0x9500cce23b334d80, .name = "Method", .data_words = 3, .ptr_words = 5, .is_group = false, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xa9962a9ed0a4d7f8, .name = "Superclass", .data_words = 1, .ptr_words = 1, .is_group = false, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xe82753cff0c2218f, .name = "Node.interface", .data_words = 6, .ptr_words = 6, .is_group = true, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xd07378ede1f9cc60, .name = "Type", .data_words = 3, .ptr_words = 1, .is_group = false, .discriminant_count = 19, .discriminant_offset = 0 },
    .{ .id = 0xce23dcd2d7b00c9b, .name = "Value", .data_words = 2, .ptr_words = 1, .is_group = false, .discriminant_count = 19, .discriminant_offset = 0 },
    .{ .id = 0xb18aa5ac7a0d9420, .name = "Node.const", .data_words = 6, .ptr_words = 6, .is_group = true, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xec1619d4400a0290, .name = "Node.annotation", .data_words = 6, .ptr_words = 6, .is_group = true, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xdebf55bbfa0fc242, .name = "Node.NestedNode", .data_words = 1, .ptr_words = 1, .is_group = false, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xf1c8950dab257542, .name = "Annotation", .data_words = 1, .ptr_words = 2, .is_group = false, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xb9521bccf10fa3b1, .name = "Node.Parameter", .data_words = 0, .ptr_words = 1, .is_group = false, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0x903455f06065422b, .name = "Brand", .data_words = 0, .ptr_words = 1, .is_group = false, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xabd73485a9636bc9, .name = "Brand.Scope", .data_words = 2, .ptr_words = 1, .is_group = false, .discriminant_count = 2, .discriminant_offset = 4 },
    .{ .id = 0xc863cd16969ee7fc, .name = "Brand.Binding", .data_words = 1, .ptr_words = 1, .is_group = false, .discriminant_count = 2, .discriminant_offset = 0 },
    .{ .id = 0x87e739250a60ea97, .name = "Type.list", .data_words = 3, .ptr_words = 1, .is_group = true, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0x9e0e78711a7f87a9, .name = "Type.enum", .data_words = 3, .ptr_words = 1, .is_group = true, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xac3a6f60ef4cc6d3, .name = "Type.struct", .data_words = 3, .ptr_words = 1, .is_group = true, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xed8bca69f7fb0cbf, .name = "Type.interface", .data_words = 3, .ptr_words = 1, .is_group = true, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0x8e3b5f79fe593656, .name = "Type.anyPointer.unconstrained", .data_words = 3, .ptr_words = 1, .is_group = true, .discriminant_count = 4, .discriminant_offset = 5 },
    .{ .id = 0x9dd1f724f4614a85, .name = "Type.anyPointer.parameter", .data_words = 3, .ptr_words = 1, .is_group = true, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xbaefc9120c56e274, .name = "Type.anyPointer.implicitMethodParameter", .data_words = 3, .ptr_words = 1, .is_group = true, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xc2573fe8a23e49f1, .name = "Type.anyPointer", .data_words = 3, .ptr_words = 1, .is_group = true, .discriminant_count = 3, .discriminant_offset = 4 },
    .{ .id = 0xc42305476bb4746f, .name = "Field.slot", .data_words = 3, .ptr_words = 4, .is_group = true, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xcafccddb68db1d11, .name = "Field.group", .data_words = 3, .ptr_words = 4, .is_group = true, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xbb90d5c287870be6, .name = "Field.ordinal", .data_words = 3, .ptr_words = 4, .is_group = true, .discriminant_count = 2, .discriminant_offset = 5 },
    .{ .id = 0xc2ba9038898e1fa2, .name = "Node.SourceInfo.Member", .data_words = 0, .ptr_words = 1, .is_group = false, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xf38e1de3041357ae, .name = "Node.SourceInfo", .data_words = 2, .ptr_words = 2, .is_group = false, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xd85d305b7d839963, .name = "CapnpVersion", .data_words = 1, .ptr_words = 0, .is_group = false, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xcfea0eb02e810062, .name = "CodeGeneratorRequest.RequestedFile", .data_words = 1, .ptr_words = 3, .is_group = false, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xbfc546f6210ad7ce, .name = "CodeGeneratorRequest", .data_words = 0, .ptr_words = 4, .is_group = false, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xae504193122357e5, .name = "CodeGeneratorRequest.RequestedFile.Import", .data_words = 1, .ptr_words = 1, .is_group = false, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xf8ea2bf176925da0, .name = "CodeGeneratorRequest.RequestedFile.FileSourceInfo", .data_words = 0, .ptr_words = 1, .is_group = false, .discriminant_count = 0, .discriminant_offset = 0 },
    .{ .id = 0xdda719892e0499bb, .name = "CodeGeneratorRequest.RequestedFile.FileSourceInfo.Identifier", .data_words = 3, .ptr_words = 0, .is_group = false, .discriminant_count = 2, .discriminant_offset = 8 },
    .{ .id = 0xfc69d5e1d630a151, .name = "CodeGeneratorRequest.RequestedFile.FileSourceInfo.Identifier.member", .data_words = 3, .ptr_words = 0, .is_group = true, .discriminant_count = 0, .discriminant_offset = 0 },
};

test "golden: CodeGeneratorRequest node table" {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, "capnp-tests/06_schema.capnp.original.1.bin", .{});
    defer file.close(std.testing.io);

    var message = try capnp.Message.fromFile(file, std.testing.io, std.testing.allocator);
    defer message.deinit(std.testing.allocator);

    const request = try message.getRootStruct(_Schema.CodeGeneratorRequest.Reader, _Schema.CodeGeneratorRequest.reader_trait);
    const nodes = try request.getNodes();

    try std.testing.expectEqual(@as(u29, 43), nodes.length);

    var seen: [expected_schema_structs.len]bool = @splat(false);
    var schema_struct_count: usize = 0;

    for (0..nodes.length) |i| {
        const node = nodes.get(@intCast(i));
        if (node.which() != .@"struct") continue;

        const display_name = try node.getDisplayName();
        if (std.mem.indexOf(u8, display_name, "schema.capnp:") == null) continue;

        schema_struct_count += 1;
        const struct_node = node.getStruct().?;
        var found = false;

        for (expected_schema_structs, 0..) |expected, j| {
            if (expected.id != node.getId()) continue;

            found = true;
            seen[j] = true;
            try std.testing.expect(std.mem.endsWith(u8, display_name, expected.name));
            try std.testing.expectEqual(expected.data_words, struct_node.getDataWordCount());
            try std.testing.expectEqual(expected.ptr_words, struct_node.getPointerCount());
            try std.testing.expectEqual(expected.is_group, struct_node.getIsGroup());
            try std.testing.expectEqual(expected.discriminant_count, struct_node.getDiscriminantCount());
            try std.testing.expectEqual(expected.discriminant_offset, struct_node.getDiscriminantOffset());
            break;
        }

        try std.testing.expect(found);
    }

    try std.testing.expectEqual(expected_schema_structs.len, schema_struct_count);
    for (seen) |was_seen| {
        try std.testing.expect(was_seen);
    }
}

test "golden: requested file and version" {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, "capnp-tests/06_schema.capnp.original.1.bin", .{});
    defer file.close(std.testing.io);

    var message = try capnp.Message.fromFile(file, std.testing.io, std.testing.allocator);
    defer message.deinit(std.testing.allocator);

    const request = try message.getRootStruct(_Schema.CodeGeneratorRequest.Reader, _Schema.CodeGeneratorRequest.reader_trait);
    const files = try request.getRequestedFiles();

    try std.testing.expectEqual(@as(u29, 1), files.length);

    const requested = files.get(0);
    try std.testing.expectEqual(@as(u64, 0xa93fc509624c72d9), requested.getId());
    try std.testing.expectEqualStrings("usr/local/include/capnp/schema.capnp", try requested.getFilename());

    const imports = try requested.getImports();
    try std.testing.expectEqual(@as(u29, 1), imports.length);
    try std.testing.expectEqual(@as(u64, 13688829037717245569), imports.get(0).getId());
    try std.testing.expectEqualStrings("/capnp/c++.capnp", try imports.get(0).getName());

    const version = try request.getCapnpVersion();
    try std.testing.expectEqual(@as(u16, 1), version.getMajor());
    try std.testing.expectEqual(@as(u8, 5), version.getMinor());
    try std.testing.expectEqual(@as(u8, 0), version.getMicro());
}

test "golden: Node fixture fields" {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, "capnp-tests/08-schema-examples.node.bin", .{});
    defer file.close(std.testing.io);

    var message = try capnp.Message.fromFile(file, std.testing.io, std.testing.allocator);
    defer message.deinit(std.testing.allocator);

    const node = try message.getRootStruct(_Schema.Node.Reader, _Schema.Node.reader_trait);
    try std.testing.expectEqual(_Schema.Node.Tag.@"struct", node.which());

    const struct_node = node.getStruct().?;
    try std.testing.expectEqual(@as(u16, 0), struct_node.getDataWordCount());
    try std.testing.expectEqual(@as(u16, 0), struct_node.getPointerCount());
    try std.testing.expectEqual(_Schema.ElementSize.empty, struct_node.getPreferredListEncoding());
    try std.testing.expectEqual(false, struct_node.getIsGroup());
    try std.testing.expectEqual(@as(u16, 0), struct_node.getDiscriminantCount());
    try std.testing.expectEqual(@as(u32, 0), struct_node.getDiscriminantOffset());

    const fields = try struct_node.getFields();
    const expected_names = [_][]const u8{ "void", "bool", "int32", "float32", "text", "data", "int32List", "struct" };
    const expected_types = [_]_Schema.Type.Tag{
        .void,
        .bool,
        .int32,
        .float32,
        .text,
        .data,
        .list,
        .struct_,
    };

    try std.testing.expectEqual(expected_names.len, fields.length);

    for (0..fields.length) |i| {
        const field = fields.get(@intCast(i));
        const name = try field.getName();

        try std.testing.expectEqualStrings(expected_names[i], name);
        try std.testing.expectEqual(@as(u16, 0), field.getCodeOrder());
        try std.testing.expectEqual(@as(u16, 65535), field.getDiscriminantValue());

        const slot = field.getSlot().?;
        try std.testing.expectEqual(@as(u32, 0), slot.getOffset());
        try std.testing.expectEqual(false, slot.getHadExplicitDefault());

        const typ = try slot.getType();
        try std.testing.expectEqual(expected_types[i], typ.which());

        switch (try field.getOrdinal().which()) {
            .implicit => {},
            else => return error.TestUnexpectedResult,
        }
    }

    const list_field = fields.get(6);
    const list_type = try list_field.getSlot().?.getType();
    try std.testing.expectEqual(_Schema.Type.Tag.int32, (try list_type.getList().?.getElementType()).which());

    const struct_field = fields.get(7);
    const struct_type = try struct_field.getSlot().?.getType();
    try std.testing.expectEqual(@as(u64, 0), struct_type.getStruct().?.getTypeId());
}

test "golden: Type void fixture" {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, "capnp-tests/08-schema-examples.void.bin", .{});
    defer file.close(std.testing.io);

    var message = try capnp.Message.fromFile(file, std.testing.io, std.testing.allocator);
    defer message.deinit(std.testing.allocator);

    const typ = try message.getRootStruct(_Schema.Type.Reader, _Schema.Type.reader_trait);
    try std.testing.expectEqual(_Schema.Type.Tag.void, typ.which());
}
