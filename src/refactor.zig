// We will define a Refactor functor here. This will take the WriterType as the parameter, and will be used throughout.

pub const schema = @import("schema.zig");
const std = @import("std");
const capnp = @import("capnp");

fn Wrapper(comptime T: type, comptime F: anytype) type {
    return struct {
        value: T,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            F(self.value, writer) catch return error.WriteFailed;
        }
    };
}

pub fn wrap(value: anytype, comptime F: anytype) Wrapper(@TypeOf(value), F) {
    return .{ .value = value };
}

fn capitalize(str: []const u8, writer: anytype) !void {
    if (str.len == 0) return;
    try writer.print("{c}{s}", .{ std.ascii.toUpper(str[0]), str[1..] });
}

fn capitalized(x: []const u8) Wrapper([]const u8, capitalize) {
    return wrap(x, capitalize);
}

fn concatFn(values: [2][]const u8, writer: anytype) !void {
    for (values) |value| {
        try writer.print("{s}", .{value});
    }
}

fn concat(value: [2][]const u8) Wrapper([2][]const u8, concatFn) {
    return .{ .value = value };
}

const getter_type = enum {
    reader,
    builder,

    pub fn toString(self: getter_type) []const u8 {
        return @tagName(self);
    }
};

const type_context = enum {
    base,
    reader_getter,
    builder_getter,
};

const keywords = [_][]const u8{
    "addrspace",    "align",     "allowzero",   "and",         "anyframe",
    "anytype",      "asm",       "async",       "await",       "break",
    "callconv",     "catch",     "comptime",    "const",       "continue",
    "defer",        "else",      "enum",        "errdefer",    "error",
    "export",       "extern",    "false",       "fn",          "for",
    "if",           "inline",    "linksection", "noalias",     "noinline",
    "nosuspend",    "null",      "opaque",      "or",          "orelse",
    "packed",       "pub",       "resume",      "return",      "struct",
    "suspend",      "switch",    "test",        "threadlocal", "true",
    "try",          "undefined", "union",       "unpacked",    "usingnamespace",
    "var",          "volatile",  "while",       "anyerror",    "comptime_float",
    "comptime_int", "f16",       "f32",         "f64",         "f80",
    "f128",         "i8",        "i16",         "i32",         "i64",
    "i128",         "isize",     "noreturn",    "type",        "u8",
    "u16",          "u32",       "u64",         "u128",        "usize",
    "void",         "bool",
};

fn isKeyword(name: []const u8) bool {
    for (keywords) |keyword| {
        if (std.mem.eql(u8, keyword, name)) return true;
    }
    return false;
}

fn writeReplaceKeyword(name: []const u8, writer: anytype) !void {
    if (isKeyword(name)) {
        try writer.writeAll("@\"");
        try writer.writeAll(name);
        try writer.writeAll("\"");
    } else {
        try writer.writeAll(name);
    }
}

// This is effectively like a functor (a parametrerized module) in OCaml.
pub fn Refactor(comptime W: type) type {
    return struct {
        const WriterType = W;
        const E = W.Error || capnp.Error || error{NodeNotFound};
        const Self = @This();

        pub const Indenter = struct {
            level: usize = 0,

            pub fn write(self: Indenter, writer: *W) E!void {
                for (0..self.level) |_| {
                    try writer.writeAll("    ");
                }
            }

            pub fn inc(self: *Indenter) void {
                self.level += 1;
            }

            pub fn dec(self: *Indenter) void {
                self.level -= 1;
            }
        };

        const TypedContext = struct {
            ctx: *WriteContext,
            typ: schema.Type.Reader,
            gt: type_context,
            with_error: bool,
        };

        fn typedFn(ctx: TypedContext, writer: anytype) E!void {
            _ = writer;
            return writeType(ctx.ctx, ctx.typ, ctx.gt, ctx.with_error, false);
        }

        fn typed(value: TypedContext) Wrapper(TypedContext, typedFn) {
            return .{ .value = value };
        }

        fn printArg(writer: *W, value: anytype) E!void {
            switch (@typeInfo(@TypeOf(value))) {
                .@"struct" => try writer.print("{f}", .{value}),
                else => try writer.print("{s}", .{value}),
            }
        }

        // Idea: Create type combinators

        // Idea 2: simplify output. That way we don’t need to worry about errors when calling which()
        // THis would entail which just returning an enum(u16).

        //pub fn (comptime T: type, comptime T2: type) type {}

        pub const NodeMap = std.AutoHashMap(u64, schema.Node.Reader);

        pub const WriteContext = struct {
            writer: *W,
            indenter: Indenter,
            nodes: *const NodeMap,

            pub fn getNodeById(self: *WriteContext, id: u64) E!schema.Node.Reader {
                return self.nodes.get(id) orelse error.NodeNotFound;
            }

            fn writeNodeNameById(self: *WriteContext, id: u64) E!void {
                try self.writeNodeName(try self.getNodeById(id));
            }

            fn writeNodeName(self: *WriteContext, node: schema.Node.Reader) E!void {
                // cppFullName first checks scopeID isn’t zero,

                var current_node = node;
                var ancestors: [64]u64 = undefined;
                var ancestors_len: usize = 0;

                ancestors[ancestors_len] = current_node.getId();
                ancestors_len += 1;
                var scope_id = current_node.getScopeId();

                // Get all ancestors.
                while (scope_id != 0) {
                    if (ancestors_len == ancestors.len) @panic("writeNodeName: stack overflow");
                    ancestors[ancestors_len] = scope_id;
                    ancestors_len += 1;
                    current_node = try self.getNodeById(scope_id);
                    scope_id = current_node.getScopeId();
                }

                // ASSUME This works because files should always be the outermost scope.
                if (current_node.which() == .file) {
                    try self.writer.writeAll("_Root");
                }

                // Drop the root from the list; walk from its child down to the node.
                ancestors_len -= 1;

                while (ancestors_len > 0) {
                    ancestors_len -= 1;
                    const child_node_id = ancestors[ancestors_len];
                    const parent_nested_nodes = try current_node.getNestedNodes();
                    const scope_name: []const u8 = result: for (0..parent_nested_nodes.length) |i| {
                        const nested_node = parent_nested_nodes.get(@intCast(i));
                        if (nested_node.getId() == child_node_id) {
                            break :result try nested_node.getName();
                        }
                    } else {
                        // It must be a group from a field
                        const fields = try current_node.getStruct().?.getFields();
                        for (0..fields.length) |i| {
                            const field = fields.get(@intCast(i));
                            if (field.getGroup()) |group| {
                                if (group.getTypeId() == child_node_id) {
                                    break :result try field.getName();
                                }
                            }
                        }
                        @panic("No link from parent to child – this should never happen");
                    };

                    try self.writer.writeAll(".");
                    try writeReplaceKeyword(scope_name, self.writer);
                    current_node = try self.getNodeById(child_node_id);
                }
            }

            pub fn writeIndent(self: *WriteContext) E!void {
                try self.indenter.write(self.writer);
            }

            pub fn openGetter(ctx: *WriteContext, field: schema.Field.Reader, gt: getter_type) E!void {
                const name = try field.getName();
                try ctx.writeIndent();
                const tgt: type_context = switch (gt) {
                    .reader => .reader_getter,
                    .builder => .builder_getter,
                };
                switch (field.which()) {
                    .slot => {
                        const typ = try field.getSlot().?.getType();
                        try ctx.writer.writeAll("pub fn ");
                        try writeReplaceKeyword(name, ctx.writer);
                        try ctx.writer.writeAll("(self: @This()) ");
                        try writeType(ctx, typ, tgt, true, field.getDiscriminantValue() != 0xffff);
                        try ctx.writer.writeAll(" {\n");
                    },
                    .group => {
                        try ctx.writer.writeAll("pub fn ");
                        try writeReplaceKeyword(name, ctx.writer);
                        try ctx.writer.writeAll("(self: @This()) ");
                        if (field.getDiscriminantValue() != 0xffff) {
                            try ctx.writer.writeAll("?");
                        }
                        try ctx.writeNodeNameById(field.getGroup().?.getTypeId());
                        try ctx.writer.print(".{f}", .{capitalized(gt.toString())});
                        try ctx.writer.writeAll(" {\n");
                    },
                    else => {},
                }
                ctx.indenter.inc();
            }

            pub fn openSetter(ctx: *WriteContext, name: []const u8, typ: anytype, rtyp: []const u8) E!void {
                try ctx.writeIndent();
                try ctx.writer.print("pub fn set{f}(self: @This(), value: ", .{capitalized(name)});
                try printArg(ctx.writer, typ);
                try ctx.writer.print(") {s} {{\n", .{rtyp});
                ctx.indenter.inc();
            }

            pub fn openVoidSetter(ctx: *WriteContext, name: []const u8) E!void {
                try ctx.writeIndent();
                try ctx.writer.print("pub fn set{f}(self: @This()) void {{\n", .{capitalized(name)});
                ctx.indenter.inc();
            }

            pub fn closeGetter(ctx: *WriteContext) E!void {
                ctx.indenter.dec();
                try ctx.writeIndent();
                try ctx.writer.writeAll("}");
            }

            const closeSetter = closeGetter;
        };

        fn zigNameHelper(comptime name: []const u8, comptime n: usize) []const u8 {
            return name[0..1] ++ name[n..];
        }

        fn writeListType(ctx: *WriteContext, element: schema.Type.Reader, gt: type_context) E!void {
            if (element.which() == .struct_) {
                const id = element.getStruct().?.getTypeId();
                const builder = gt == .builder_getter;
                try ctx.writer.writeAll(if (builder) "capnp.CompositeListBuilder(" else "capnp.CompositeListReader(");
                try ctx.writeNodeNameById(id);
                try ctx.writer.writeAll(if (builder) ".Builder, " else ".Reader, ");
                try ctx.writeNodeNameById(id);
                try ctx.writer.writeAll(if (builder) ".builder_trait)" else ".reader_trait)");
                return;
            }

            try ctx.writer.writeAll("capnp.List(");
            try writeType(ctx, element, .base, false, false);
            try ctx.writer.writeAll(")");
            try ctx.writer.writeAll(switch (gt) {
                .base => "",
                .reader_getter => ".Reader",
                .builder_getter => ".Builder",
            });
        }

        pub fn writeType(ctx: *WriteContext, reader: schema.Type.Reader, gt: type_context, with_error: bool, is_optional: bool) E!void {
            if (with_error) {
                switch (reader.which()) {
                    .list, .data, .text, .struct_, .anyPointer, .interface => {
                        try ctx.writer.writeAll(if (gt == .builder_getter) "capnp.BuildError!" else "capnp.Error!");
                    },
                    else => {},
                }
            }
            if (is_optional) {
                try ctx.writer.writeAll("?");
            }
            switch (reader.which()) {
                .void => try ctx.writer.writeAll("void"),
                .bool => try ctx.writer.writeAll("bool"),
                inline .int8, .int16, .int32, .int64 => |x| try ctx.writer.writeAll(zigNameHelper(@tagName(x), 3)),
                inline .uint8, .uint16, .uint32, .uint64 => |x| try ctx.writer.writeAll(zigNameHelper(@tagName(x), 4)),
                inline .float32, .float64 => |x| try ctx.writer.writeAll(zigNameHelper(@tagName(x), 5)),
                .text => try ctx.writer.writeAll("[:0]const u8"),
                .data => try ctx.writer.writeAll("[]const u8"),
                .list => try writeListType(ctx, try reader.getList().?.getElementType(), gt),
                .enum_ => try ctx.writeNodeNameById(reader.getEnum().?.getTypeId()),
                .struct_ => {
                    try ctx.writeNodeNameById(reader.getStruct().?.getTypeId());
                    try ctx.writer.writeAll(switch (gt) {
                        .base => "",
                        .reader_getter => ".Reader",
                        .builder_getter => ".Builder",
                    });
                },
                .interface, .anyPointer => try ctx.writer.writeAll("capnp.AnyPointerReader"),
                else => try ctx.writer.writeAll("capnp.AnyPointerReader"),
            }
        }

        pub fn writeNode(ctx: *WriteContext, name: []const u8, node: schema.Node.Reader) E!void {
            switch (node.which()) {
                .file => {
                    try ctx.writer.print("// {s}\n", .{name});
                    try ctx.writer.writeAll("// This file is automatically generated. DO NOT EDIT.\n\n");
                    try ctx.writer.writeAll("const _Root = @This();\nconst capnp = @import(\"capnp\");\n\n");

                    const nested_nodes = try node.getNestedNodes();
                    for (0..nested_nodes.length) |i| {
                        const nested_node = nested_nodes.get(@intCast(i));
                        try writeNode(ctx, try nested_node.getName(), try ctx.getNodeById(nested_node.getId()));
                    }
                },

                .@"enum" => {
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const ");
                    try writeReplaceKeyword(name, ctx.writer);
                    try ctx.writer.writeAll(" = enum(u16) {\n");
                    ctx.indenter.inc();

                    const enumerants = try node.getEnum().?.getEnumerants();
                    for (0..enumerants.length) |i| {
                        const enumerant = enumerants.get(@intCast(i));
                        try ctx.writeIndent();
                        try writeReplaceKeyword(try enumerant.getName(), ctx.writer);
                        try ctx.writer.print(" = {d},\n", .{i});
                    }
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("_,\n");

                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("};\n");
                },

                .interface => {
                    // not yet implemented
                },

                .@"const" => {},

                .annotation => {},

                .@"struct" => {
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const ");
                    try writeReplaceKeyword(name, ctx.writer);
                    try ctx.writer.writeAll(" = struct {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.print("pub const id: u64 = 0x{x};\n\n", .{node.getId()});

                    const struct_ = node.getStruct().?;
                    const fields = try struct_.getFields();

                    if (struct_.getDiscriminantCount() > 0) {
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub const Tag = enum(u16) {\n");
                        ctx.indenter.inc();

                        for (0..fields.length) |i| {
                            const field = fields.get(@intCast(i));
                            if (field.getDiscriminantValue() == 0xffff) continue;
                            try ctx.writeIndent();
                            try writeReplaceKeyword(try field.getName(), ctx.writer);
                            try ctx.writer.print(" = {},\n", .{field.getDiscriminantValue()});
                        }
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("_,\n");

                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("};\n\n");
                    }

                    for (0..fields.length) |i| {
                        const field = fields.get(@intCast(i));
                        if (field.which() != .group) continue;

                        try writeNode(ctx, try field.getName(), try ctx.getNodeById(field.getGroup().?.getTypeId()));
                    }

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const Reader = struct {\n");
                    ctx.indenter.inc();

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("reader: capnp.StructReader,\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub fn fromStructReader(reader: capnp.StructReader) @This() {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("return .{ .reader = reader };\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub fn fromReadContext(context: capnp.ReadContext) capnp.Error!@This() {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("return fromStructReader(try capnp.StructReader.fromReadContext(context));\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub fn fromNull(context: capnp.ReadContext) @This() {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("return fromStructReader(capnp.StructReader.fromNull(context));\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}\n\n");

                    if (struct_.getDiscriminantCount() > 0) {
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub fn which(self: @This()) ");
                        try ctx.writeNodeName(node);
                        try ctx.writer.writeAll(".Tag {\n");
                        ctx.indenter.inc();

                        try ctx.writeIndent();
                        try ctx.writer.print("return @fromBackingInt(@intCast(self.reader.readIntField(u16, {d})));\n", .{struct_.getDiscriminantOffset()});

                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("}\n\n");
                    }

                    for (0..fields.length) |i| {
                        try writeGetter(
                            ctx,
                            struct_.getDiscriminantOffset(),
                            fields.get(@intCast(i)),
                            .reader,
                        );
                        try ctx.writer.writeAll("\n\n");
                    }

                    // Nested nodes
                    const nested_nodes = try node.getNestedNodes();
                    for (0..nested_nodes.length) |i| {
                        const nested_node = nested_nodes.get(@intCast(i));
                        try writeNode(ctx, try nested_node.getName(), try ctx.getNodeById(nested_node.getId()));
                    }

                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("};\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const reader_trait = capnp.ReaderTrait(@This().Reader){\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll(".reader = @This().Reader.fromStructReader,\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("};\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const Builder = struct {\n");
                    ctx.indenter.inc();

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("builder: capnp.StructBuilder,\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub fn fromStructBuilder(builder: capnp.StructBuilder) @This() {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("return .{ .builder = builder };\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}\n\n");

                    if (struct_.getDiscriminantCount() > 0) {
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub fn which(self: @This()) Tag {\n");
                        ctx.indenter.inc();
                        try ctx.writeIndent();
                        try ctx.writer.print("return @fromBackingInt(@intCast(self.builder.readIntField(u16, {d})));\n", .{struct_.getDiscriminantOffset()});
                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("}\n\n");
                    }

                    for (0..fields.length) |i| {
                        try writeGetter(
                            ctx,
                            struct_.getDiscriminantOffset(),
                            fields.get(@intCast(i)),
                            .builder,
                        );
                        try ctx.writer.writeAll("\n\n");
                        try writeSetter(ctx, struct_.getDiscriminantOffset(), fields.get(@intCast(i)));
                        try ctx.writer.writeAll("\n\n");
                    }

                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("};\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const builder_trait = capnp.BuilderTrait(@This().Builder){\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.print(".data_words = {d},\n", .{struct_.getDataWordCount()});
                    try ctx.writeIndent();
                    try ctx.writer.print(".ptr_words = {d},\n", .{struct_.getPointerCount()});
                    try ctx.writeIndent();
                    try ctx.writer.writeAll(".builder = @This().Builder.fromStructBuilder,\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("};\n\n");

                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("};\n\n");
                },
                _ => {
                    @panic("Unknown node type");
                },
            }
        }

        fn writeIntDefault(writer: *W, comptime tag: schema.Type.Tag, value: schema.Value.Reader.Tag) E!void {
            switch (tag) {
                .int8 => try writer.print("{d}", .{switch (value) {
                    .int8 => |v| v,
                    else => 0,
                }}),
                .int16 => try writer.print("{d}", .{switch (value) {
                    .int16 => |v| v,
                    else => 0,
                }}),
                .int32 => try writer.print("{d}", .{switch (value) {
                    .int32 => |v| v,
                    else => 0,
                }}),
                .int64 => try writer.print("{d}", .{switch (value) {
                    .int64 => |v| v,
                    else => 0,
                }}),
                .uint8 => try writer.print("{d}", .{switch (value) {
                    .uint8 => |v| v,
                    else => 0,
                }}),
                .uint16 => try writer.print("{d}", .{switch (value) {
                    .uint16 => |v| v,
                    else => 0,
                }}),
                .uint32 => try writer.print("{d}", .{switch (value) {
                    .uint32 => |v| v,
                    else => 0,
                }}),
                .uint64 => try writer.print("{d}", .{switch (value) {
                    .uint64 => |v| v,
                    else => 0,
                }}),
                else => unreachable,
            }
        }

        pub fn writeGetter(ctx: *WriteContext, discriminantOffset: u32, field: schema.Field.Reader, gt: getter_type) E!void {
            const target = gt.toString();

            try ctx.openGetter(field, gt);

            if (field.getDiscriminantValue() != 0xffff) {
                try ctx.writeIndent();
                try ctx.writer.print("if (self.{s}.readIntField(u16, {}) != {}) {{ return null; }}\n", .{ target, discriminantOffset, field.getDiscriminantValue() });
            }

            try ctx.writeIndent();

            switch (field.which()) {
                .slot => {
                    const slot = field.getSlot().?;
                    const t = try slot.getType();

                    switch (t.which()) {
                        .void => {
                            try ctx.writer.print("return self.{s}.readVoid();\n", .{target});
                        },
                        .bool => {
                            const default_value = switch (try (try slot.getDefaultValue()).which()) {
                                .bool => |v| v,
                                else => false,
                            };
                            try ctx.writer.print("return self.{s}.readBoolField({d}) != {s};\n", .{
                                target,
                                slot.getOffset(),
                                if (default_value) "true" else "false",
                            });
                        },
                        inline .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64 => |typeTag| {
                            const typeTagName = @tagName(typeTag);
                            const default_value = try (try slot.getDefaultValue()).which();

                            try ctx.writer.print("return self.{s}.readIntField({s}, {d}) ^ ", .{
                                target,
                                zigNameHelper(typeTagName, if (typeTagName[0] == 'u') 4 else 3),
                                slot.getOffset(),
                            });
                            try writeIntDefault(ctx.writer, typeTag, default_value);
                            try ctx.writer.writeAll(";\n");
                        },
                        inline .float32, .float64 => |typeTag| {
                            const default_value = try (try slot.getDefaultValue()).which();
                            const bits: u64 = switch (typeTag) {
                                .float32 => switch (default_value) {
                                    .float32 => |v| @as(u32, @bitCast(v)),
                                    else => 0,
                                },
                                .float64 => switch (default_value) {
                                    .float64 => |v| @as(u64, @bitCast(v)),
                                    else => 0,
                                },
                                else => unreachable,
                            };
                            const int_type = if (typeTag == .float32) "u32" else "u64";
                            try ctx.writer.print("return @bitCast(self.{s}.readIntField({s}, {d}) ^ {d});\n", .{
                                target,
                                int_type,
                                slot.getOffset(),
                                bits,
                            });
                        },
                        .text => {
                            try ctx.writer.print(
                                "return self.{s}.readStringField({d});\n",
                                .{
                                    gt.toString(),
                                    field.getSlot().?.getOffset(),
                                },
                            );
                        },
                        .data => {
                            try ctx.writer.print(
                                "return self.{s}.readDataField({d});\n",
                                .{
                                    gt.toString(),
                                    field.getSlot().?.getOffset(),
                                },
                            );
                        },
                        .list => {
                            const method = if (gt == .builder) "buildPtrField" else "readPtrField";
                            try ctx.writer.print("return self.{s}.{s}(", .{ target, method });
                            try writeType(ctx, t, if (gt == .builder) .builder_getter else .reader_getter, false, false);
                            try ctx.writer.print(", {d});\n", .{slot.getOffset()});
                        },
                        .struct_ => {
                            const id = t.getStruct().?.getTypeId();
                            if (gt == .builder) {
                                try ctx.writer.writeAll("return self.builder.buildStructField(");
                                try ctx.writeNodeNameById(id);
                                try ctx.writer.writeAll(".Builder, ");
                                try ctx.writeNodeNameById(id);
                                try ctx.writer.writeAll(".builder_trait, ");
                                try ctx.writer.print("{d});\n", .{slot.getOffset()});
                            } else {
                                try ctx.writer.writeAll("return self.reader.readPtrField(");
                                try ctx.writeNodeNameById(id);
                                try ctx.writer.writeAll(".Reader, ");
                                try ctx.writer.print("{d});\n", .{slot.getOffset()});
                            }
                        },
                        .anyPointer, .interface => {
                            try ctx.writer.print("return self.{s}.readPtrField(capnp.AnyPointerReader, {d});\n", .{ target, slot.getOffset() });
                        },
                        .enum_ => {
                            const default_value = switch (try (try slot.getDefaultValue()).which()) {
                                .enum_ => |v| v,
                                else => 0,
                            };
                            try ctx.writer.print("return @fromBackingInt(@intCast(self.{s}.readIntField(u16, {d}) ^ {d}));\n", .{
                                target,
                                slot.getOffset(),
                                default_value,
                            });
                        },
                        else => {},
                    }
                },
                .group => {
                    if (field.getGroup().?.getTypeId() == 0) {
                        std.debug.print("Problem with group {s} {}\n", .{ try field.getName(), field.getGroup().?.getTypeId() });
                        @panic("ERROR");
                    }

                    switch (gt) {
                        .reader => try ctx.writer.writeAll("return .{ .reader = self.reader };\n"),
                        .builder => try ctx.writer.writeAll("return .{ .builder = self.builder };\n"),
                    }

                    // try ctx.writeIndent();
                    // try ctx.writeNodeNameById(field.getGroup().?.getTypeId());
                },
                else => {},
            }
            try ctx.closeGetter();
        }

        fn writeDiscriminant(ctx: *WriteContext, discriminant_offset: u32, field: schema.Field.Reader) E!void {
            const discriminant = field.getDiscriminantValue();
            if (discriminant == 0xffff) return;
            try ctx.writeIndent();
            try ctx.writer.print("self.builder.writeIntField(u16, {d}, {d});\n", .{ discriminant_offset, discriminant });
        }

        pub fn writeSetter(ctx: *WriteContext, discriminant_offset: u32, field: schema.Field.Reader) E!void {
            switch (field.which()) {
                .slot => {
                    const slot = field.getSlot().?;
                    const t = try slot.getType();

                    switch (t.which()) {
                        .void => {
                            try ctx.openVoidSetter(try field.getName());
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();
                            try ctx.writer.writeAll("return;\n");
                            try ctx.closeSetter();
                        },

                        .bool => {
                            const default_value = switch (try (try slot.getDefaultValue()).which()) {
                                .bool => |v| v,
                                else => false,
                            };
                            try ctx.openSetter(try field.getName(), "bool", "void");
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();
                            try ctx.writer.print("self.builder.writeBoolField({d}, value != {s});\n", .{
                                slot.getOffset(),
                                if (default_value) "true" else "false",
                            });
                            try ctx.closeSetter();
                        },

                        inline .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64 => |typeTag| {
                            const typeTagName = @tagName(typeTag);
                            const zigTypeName = zigNameHelper(typeTagName, if (typeTagName[0] == 'u') 4 else 3);

                            const default_value = try (try slot.getDefaultValue()).which();

                            try ctx.openSetter(try field.getName(), zigTypeName, "void");
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();

                            try ctx.writer.print("self.builder.writeIntField({s}, {d}, value ^ ", .{
                                zigTypeName,
                                slot.getOffset(),
                            });
                            try writeIntDefault(ctx.writer, typeTag, default_value);
                            try ctx.writer.writeAll(");\n");
                            try ctx.closeSetter();
                        },

                        inline .float32, .float64 => |typeTag| {
                            const typeTagName = @tagName(typeTag);
                            const zigTypeName = zigNameHelper(typeTagName, 5);

                            const default_value = try (try slot.getDefaultValue()).which();
                            const bits: u64 = switch (typeTag) {
                                .float32 => switch (default_value) {
                                    .float32 => |v| @as(u32, @bitCast(v)),
                                    else => 0,
                                },
                                .float64 => switch (default_value) {
                                    .float64 => |v| @as(u64, @bitCast(v)),
                                    else => 0,
                                },
                                else => unreachable,
                            };
                            const int_type = if (typeTag == .float32) "u32" else "u64";

                            try ctx.openSetter(try field.getName(), zigTypeName, "void");
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();

                            try ctx.writer.print("self.builder.writeIntField({s}, {d}, @as({s}, @bitCast(value)) ^ {d});\n", .{
                                int_type,
                                slot.getOffset(),
                                int_type,
                                bits,
                            });
                            try ctx.closeSetter();
                        },

                        .text => {
                            try ctx.openSetter(try field.getName(), "[:0]const u8", "capnp.BuildError!void");
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();
                            try ctx.writer.print("try self.builder.writeStringField({d}, value);\n", .{slot.getOffset()});
                            try ctx.closeSetter();
                        },

                        .data => {
                            try ctx.openSetter(try field.getName(), "[]const u8", "capnp.BuildError!void");
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();
                            try ctx.writer.print("try self.builder.writeDataField({d}, value);\n", .{slot.getOffset()});
                            try ctx.closeSetter();
                        },

                        .enum_ => {
                            const default_value = switch (try (try slot.getDefaultValue()).which()) {
                                .enum_ => |v| v,
                                else => 0,
                            };

                            try ctx.openSetter(try field.getName(), typed(.{ .ctx = ctx, .gt = .base, .typ = t, .with_error = false }), "void");
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();
                            try ctx.writer.print("self.builder.writeIntField(u16, {d}, @intCast(@backingInt(value) ^ {d}));\n", .{ slot.getOffset(), default_value });
                            try ctx.closeSetter();
                        },

                        else => {},
                    }
                },
                .group => {
                    const group = field.getGroup().?;
                    if (group.getTypeId() == 0) {
                        std.debug.panic("ERROR: Problem with group {s} {}", .{ try field.getName(), group.getTypeId() });
                    }

                    if (field.getDiscriminantValue() == 0xffff) return;

                    try ctx.writeIndent();
                    try ctx.writer.print("pub fn set{f}(self: @This()) ", .{capitalized(try field.getName())});
                    try ctx.writeNodeNameById(group.getTypeId());
                    try ctx.writer.writeAll(".Builder {\n");
                    ctx.indenter.inc();
                    try writeDiscriminant(ctx, discriminant_offset, field);
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("return .{ .builder = self.builder };\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}");
                },
                else => {},
            }
        }
    };
}

test "simple" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const M = Refactor(@TypeOf(writer));

    const file = try std.Io.Dir.cwd().openFile(std.testing.io, "capnp-tests/08-schema-examples.void.bin", .{});
    defer file.close(std.testing.io);

    var message = try capnp.Message.fromFile(file, std.testing.io, std.testing.allocator);
    defer message.deinit(std.testing.allocator);

    var nodes = M.NodeMap.init(std.testing.allocator);
    defer nodes.deinit();

    var ctx = M.WriteContext{
        .writer = &writer,
        .indenter = M.Indenter{},
        .nodes = &nodes,
    };

    const reader = try message.getRootStruct(schema.Type.Reader, schema.Type.reader_trait);
    try M.writeType(&ctx, reader, .reader_getter, true, false);

    try std.testing.expectEqualStrings("void", writer.buffered());
}

test "writeReaderGetterReturnType" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const M = Refactor(@TypeOf(writer));

    const file = try std.Io.Dir.cwd().openFile(std.testing.io, "capnp-tests/08-schema-examples.node.bin", .{});
    defer file.close(std.testing.io);

    var message = try capnp.Message.fromFile(file, std.testing.io, std.testing.allocator);
    defer message.deinit(std.testing.allocator);

    var nodes = M.NodeMap.init(std.testing.allocator);
    defer nodes.deinit();

    var ctx = M.WriteContext{
        .writer = &writer,
        .indenter = M.Indenter{},
        .nodes = &nodes,
    };

    const reader = try message.getRootStruct(schema.Node.Reader, schema.Node.reader_trait);
    const fields = try reader.getStruct().?.getFields();

    writer.end = 0;
    try M.writeType(&ctx, try fields.get(0).getSlot().?.getType(), .reader_getter, true, false);
    try std.testing.expectEqualStrings("void", writer.buffered());

    writer.end = 0;
    try M.writeType(&ctx, try fields.get(1).getSlot().?.getType(), .reader_getter, true, false);
    try std.testing.expectEqualStrings("bool", writer.buffered());
}

test "field" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const M = Refactor(@TypeOf(writer));

    const file = try std.Io.Dir.cwd().openFile(std.testing.io, "capnp-tests/08-schema-examples.node.bin", .{});
    defer file.close(std.testing.io);

    var message = try capnp.Message.fromFile(file, std.testing.io, std.testing.allocator);
    defer message.deinit(std.testing.allocator);

    var nodes = M.NodeMap.init(std.testing.allocator);
    defer nodes.deinit();

    var ctx = M.WriteContext{
        .writer = &writer,
        .indenter = M.Indenter{},
        .nodes = &nodes,
    };

    const reader = try message.getRootStruct(schema.Node.Reader, schema.Node.reader_trait);
    const struct_reader = reader.getStruct().?;
    const field = (try struct_reader.getFields()).get(2);

    writer.end = 0;
    try M.writeGetter(&ctx, struct_reader.getDiscriminantOffset(), field, .reader);
    try std.testing.expectEqualStrings("pub fn int32(self: @This()) i32 {\n    return self.reader.readIntField(i32, 0) ^ 0;\n}", writer.buffered());
}

test "compiler" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "capnp-tests/06_schema.capnp.original.1.bin",
        std.testing.allocator,
        .limited(64 * 1024 * 1024),
    );
    defer std.testing.allocator.free(bytes);

    var message = try capnp.Message.fromBytes(bytes, std.testing.allocator);
    defer message.deinit(std.testing.allocator);

    const request = try message.getRootStruct(schema.CodeGeneratorRequest.Reader, schema.CodeGeneratorRequest.reader_trait);
    const nodes = try request.getNodes();

    var node_map = std.AutoHashMap(u64, schema.Node.Reader).init(std.testing.allocator);
    defer node_map.deinit();
    for (0..nodes.length) |i| {
        const node = nodes.get(@intCast(i));
        try node_map.put(node.getId(), node);
    }

    const M = Refactor(std.Io.Writer);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var ctx = M.WriteContext{
        .writer = &output.writer,
        .indenter = M.Indenter{},
        .nodes = &node_map,
    };

    const files = try request.getRequestedFiles();
    const requested_file = try ctx.getNodeById(files.get(0).getId());
    try M.writeNode(&ctx, try files.get(0).getFilename(), requested_file);

    const code = try output.toOwnedSlice();
    defer std.testing.allocator.free(code);

    try std.testing.expect(code.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, code, "// "));
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const") != null);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buf);
    const bytes = try stdin_reader.interface.allocRemaining(allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(bytes);

    var message = try capnp.Message.fromBytes(bytes, arena);
    defer message.deinit(arena);

    const request = try message.getRootStruct(schema.CodeGeneratorRequest.Reader, schema.CodeGeneratorRequest.reader_trait);

    var node_map = std.AutoHashMap(u64, schema.Node.Reader).init(allocator);
    defer node_map.deinit();

    const nodes = try request.getNodes();
    for (0..nodes.length) |i| {
        const node = nodes.get(@intCast(i));
        try node_map.put(node.getId(), node);
    }

    const M = Refactor(std.Io.Writer);

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(init.io, &out_buf);

    const files = try request.getRequestedFiles();
    for (0..files.length) |i| {
        const requested = files.get(@intCast(i));

        var output = std.Io.Writer.Allocating.init(allocator);
        defer output.deinit();

        var ctx = M.WriteContext{
            .writer = &output.writer,
            .indenter = M.Indenter{},
            .nodes = &node_map,
        };

        const requested_file = try ctx.getNodeById(requested.getId());
        try M.writeNode(&ctx, try requested.getFilename(), requested_file);

        const code = try output.toOwnedSlice();
        defer allocator.free(code);
        try out_writer.interface.writeAll(code);
    }
    try out_writer.interface.flush();
}
