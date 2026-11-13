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

pub const ImportAlias = struct {
    file_id: u64,
    module: []const u8,
    path: []const u8,
};

pub const SourceInfoMap = std.AutoHashMap(u64, schema.Node.SourceInfo.Reader);

fn importBaseName(name: []const u8) []const u8 {
    const without_slash = if (name.len > 0 and name[0] == '/') name[1..] else name;
    const base = if (std.mem.lastIndexOfScalar(u8, without_slash, '/')) |i| without_slash[i + 1 ..] else without_slash;
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| return base[0..i];
    return base;
}

fn importModuleName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const base = importBaseName(name);
    if (base.len == 0) return allocator.dupe(u8, "_import");

    // Prefix every import alias so it cannot collide with generated field
    // names or methods.
    const out = try allocator.alloc(u8, base.len + 1);
    out[0] = '_';
    for (base, 0..) |ch, i| {
        out[i + 1] = if (std.ascii.isAlphanumeric(ch) or ch == '_') ch else '_';
    }
    return out;
}

fn importFilePath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const without_slash = if (name.len > 0 and name[0] == '/') name[1..] else name;
    const stem = if (std.mem.endsWith(u8, without_slash, ".capnp"))
        without_slash[0 .. without_slash.len - ".capnp".len]
    else
        without_slash;
    return std.fmt.allocPrint(allocator, "{s}.zig", .{stem});
}

fn outputFilePath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const stem = if (std.mem.endsWith(u8, name, ".capnp"))
        name[0 .. name.len - ".capnp".len]
    else
        name;
    return std.fmt.allocPrint(allocator, "{s}.zig", .{stem});
}

pub fn collectImports(
    allocator: std.mem.Allocator,
    requested: schema.CodeGeneratorRequest.RequestedFile.Reader,
) ![]ImportAlias {
    const imports = try requested.imports();
    var aliases = std.ArrayList(ImportAlias).empty;
    errdefer aliases.deinit(allocator);

    for (0..imports.length) |i| {
        const import_ = imports.get(@intCast(i));
        const name = try import_.name();
        try aliases.append(allocator, .{
            .file_id = import_.id(),
            .module = try importModuleName(allocator, name),
            .path = try importFilePath(allocator, name),
        });
    }

    return aliases.toOwnedSlice(allocator);
}

pub fn collectSourceInfo(
    allocator: std.mem.Allocator,
    request: schema.CodeGeneratorRequest.Reader,
) !SourceInfoMap {
    var source_info = SourceInfoMap.init(allocator);
    errdefer source_info.deinit();

    const infos = try request.sourceInfo();
    for (0..infos.length) |i| {
        const info = infos.get(@intCast(i));
        try source_info.put(info.id(), info);
    }

    return source_info;
}

pub fn Refactor(comptime W: type) type {
    return struct {
        const WriterType = W;
        const E = W.Error || capnp.Error || std.mem.Allocator.Error || error{ NodeNotFound, UnknownImport };
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
            source_info: ?*const SourceInfoMap = null,
            allocator: std.mem.Allocator = std.heap.page_allocator,
            current_file_id: u64 = 0,
            imports: []const ImportAlias = &.{},
            emit_header: bool = true,
            used_imports: ?*std.AutoHashMap(u64, void) = null,
            interface_depth: usize = 0,

            pub fn getNodeById(self: *WriteContext, id: u64) E!schema.Node.Reader {
                return self.nodes.get(id) orelse error.NodeNotFound;
            }

            fn importForFile(self: *WriteContext, id: u64) ?ImportAlias {
                for (self.imports) |import_| {
                    if (import_.file_id == id) return import_;
                }
                return null;
            }

            fn writeNodeNameById(self: *WriteContext, id: u64) E!void {
                try self.writeNodeName(try self.getNodeById(id));
            }

            fn writeNodeName(self: *WriteContext, node: schema.Node.Reader) E!void {
                // cppFullName first checks scopeID isn’t zero,

                var current_node = node;
                var ancestors: [64]u64 = undefined;
                var ancestors_len: usize = 0;

                ancestors[ancestors_len] = current_node.id();
                ancestors_len += 1;
                var scope_id = current_node.scopeId();

                // Get all ancestors.
                while (scope_id != 0) {
                    if (ancestors_len == ancestors.len) @panic("writeNodeName: stack overflow");
                    ancestors[ancestors_len] = scope_id;
                    ancestors_len += 1;
                    current_node = try self.getNodeById(scope_id);
                    scope_id = current_node.scopeId();
                }

                // The outermost scope is always a file.
                if (current_node.which() == .file) {
                    if (current_node.id() == self.current_file_id) {
                        try self.writer.writeAll("_Root");
                    } else if (self.importForFile(current_node.id())) |import_| {
                        if (self.used_imports) |used| try used.put(current_node.id(), {});
                        try writeReplaceKeyword(import_.module, self.writer);
                    } else {
                        return error.UnknownImport;
                    }
                }

                // Drop the root from the list; walk from its child down to the node.
                ancestors_len -= 1;

                while (ancestors_len > 0) {
                    ancestors_len -= 1;
                    const child_node_id = ancestors[ancestors_len];
                    const parent_nested_nodes = try current_node.nestedNodes();
                    const scope_name: []const u8 = result: for (0..parent_nested_nodes.length) |i| {
                        const nested_node = parent_nested_nodes.get(@intCast(i));
                        if (nested_node.id() == child_node_id) {
                            break :result try nested_node.name();
                        }
                    } else {
                        // It must be a group from a field
                        const fields = try current_node.@"struct"().?.fields();
                        for (0..fields.length) |i| {
                            const field = fields.get(@intCast(i));
                            if (field.group()) |group| {
                                if (group.typeId() == child_node_id) {
                                    break :result try field.name();
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

            fn nodeDoc(ctx: *WriteContext, node: schema.Node.Reader) E!?[]const u8 {
                const source_info = ctx.source_info orelse return null;
                const info = source_info.get(node.id()) orelse return null;
                const doc = try info.docComment();
                return if (doc.len == 0) null else doc;
            }

            fn memberDoc(ctx: *WriteContext, node: schema.Node.Reader, index: usize) E!?[]const u8 {
                const source_info = ctx.source_info orelse return null;
                const info = source_info.get(node.id()) orelse return null;
                const members = try info.members();
                if (index >= members.length) return null;
                const doc = try members.get(@intCast(index)).docComment();
                return if (doc.len == 0) null else doc;
            }

            fn writeDocComment(ctx: *WriteContext, comptime prefix: []const u8, doc: ?[]const u8) E!bool {
                const text = doc orelse return false;
                const trimmed = std.mem.trim(u8, text, "\r\n");
                if (trimmed.len == 0) return false;

                var lines = std.mem.splitScalar(u8, trimmed, '\n');
                while (lines.next()) |raw_line| {
                    const line = std.mem.trimEnd(u8, raw_line, " \t\r");
                    try ctx.writeIndent();
                    try ctx.writer.writeAll(prefix);
                    if (line.len != 0) {
                        try ctx.writer.writeByte(' ');
                        try ctx.writer.writeAll(line);
                    }
                    try ctx.writer.writeByte('\n');
                }
                return true;
            }

            pub fn openGetter(ctx: *WriteContext, field: schema.Field.Reader, gt: getter_type) E!void {
                const name = try field.name();
                try ctx.writeIndent();
                const tgt: type_context = switch (gt) {
                    .reader => .reader_getter,
                    .builder => .builder_getter,
                };
                switch (field.which()) {
                    .slot => {
                        const typ = try field.slot().?.type();
                        const with_error = if (gt == .builder)
                            switch (typ.which()) {
                                .anyPointer => isParameterType(typ),
                                .interface => false,
                                else => true,
                            }
                        else
                            true;
                        try ctx.writer.writeAll("pub fn ");
                        try writeReplaceKeyword(name, ctx.writer);
                        try ctx.writer.writeAll("(self: @This()) ");
                        try writeType(ctx, typ, tgt, with_error, field.discriminantValue() != 0xffff);
                        try ctx.writer.writeAll(" {\n");
                    },
                    .group => {
                        try ctx.writer.writeAll("pub fn ");
                        try writeReplaceKeyword(name, ctx.writer);
                        try ctx.writer.writeAll("(self: @This()) ");
                        if (field.discriminantValue() != 0xffff) {
                            try ctx.writer.writeAll("?");
                        }
                        try ctx.writeNodeNameById(field.group().?.typeId());
                        try ctx.writer.print(".{f}", .{capitalized(gt.toString())});
                        try ctx.writer.writeAll(" {\n");
                    },
                    else => {},
                }
                ctx.indenter.inc();
            }

            pub fn openSetter(ctx: *WriteContext, name: []const u8, typ: anytype, rtyp: []const u8) E!void {
                try ctx.writeIndent();
                try ctx.writer.print("pub fn set{f}(self: @This(), v: ", .{capitalized(name)});
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

        fn typeParameterName(ctx: *WriteContext, typ: schema.Type.Reader) E!?[]u8 {
            if (typ.which() != .anyPointer) return null;
            const parameter = typ.anyPointer().?.parameter() orelse return null;

            const scope = try ctx.getNodeById(parameter.scopeId());
            const parameters = try scope.parameters();
            const index = parameter.parameterIndex();
            if (index >= parameters.length) return null;

            return @as(?[]u8, try sanitizeName(ctx.allocator, try parameters.get(index).name()));
        }

        fn isParameterType(typ: schema.Type.Reader) bool {
            if (typ.which() != .anyPointer) return false;
            return typ.anyPointer().?.parameter() != null;
        }

        fn nodeIsGeneric(ctx: *WriteContext, id: u64) E!bool {
            const node = try ctx.getNodeById(id);
            const parameters = try node.parameters();
            return parameters.length != 0;
        }

        fn writeTypeDescriptor(ctx: *WriteContext, typ: schema.Type.Reader) E!void {
            switch (typ.which()) {
                .text => try ctx.writer.writeAll("capnp.Text"),
                .data => try ctx.writer.writeAll("capnp.Data"),
                .anyPointer => {
                    if (try typeParameterName(ctx, typ)) |name| {
                        defer ctx.allocator.free(name);
                        try ctx.writer.writeAll(name);
                    } else {
                        try ctx.writer.writeAll("capnp.AnyPointer");
                    }
                },
                .interface => try ctx.writer.writeAll("capnp.Interface"),
                .@"struct" => {
                    try ctx.writer.writeAll("capnp.StructType(");
                    try writeType(ctx, typ, .base, false, false);
                    try ctx.writer.writeAll(", ");
                    try writeType(ctx, typ, .base, false, false);
                    try ctx.writer.writeAll(".builder_trait)");
                },
                else => try ctx.writer.writeAll("capnp.AnyPointer"),
            }
        }

        fn writeBrandArgs(ctx: *WriteContext, id: u64, brand: schema.Brand.Reader) E!void {
            const node = try ctx.getNodeById(id);
            const parameters = try node.parameters();
            if (parameters.length == 0) return;

            try ctx.writer.writeByte('(');

            var bindings: ?capnp.CompositeListReader(schema.Brand.Binding.Reader, schema.Brand.Binding.reader_trait) = null;
            const scopes = try brand.scopes();
            for (0..scopes.length) |i| {
                const scope = scopes.get(@intCast(i));
                if (scope.scopeId() != id) continue;
                if (scope.which() != .bind) continue;
                if (try scope.bind()) |bound| {
                    bindings = bound;
                    break;
                }
            }

            for (0..parameters.length) |i| {
                if (i != 0) try ctx.writer.writeAll(", ");

                var wrote = false;
                if (bindings) |bound| {
                    if (i < bound.length) {
                        const binding = bound.get(@intCast(i));
                        if (binding.which() == .type) {
                            if (try binding.type()) |argument| {
                                try writeTypeDescriptor(ctx, argument);
                                wrote = true;
                            }
                        }
                    }
                }
                if (!wrote) try ctx.writer.writeAll("capnp.AnyPointer");
            }

            try ctx.writer.writeByte(')');
        }

        fn writeListType(ctx: *WriteContext, element: schema.Type.Reader, gt: type_context) E!void {
            if (element.which() == .interface or element.which() == .anyPointer) {
                try ctx.writer.writeAll(switch (gt) {
                    .builder_getter => "capnp.AnyPointerListBuilder",
                    else => "capnp.AnyPointerListReader",
                });
                return;
            }

            if (element.which() == .@"struct") {
                const builder = gt == .builder_getter;
                try ctx.writer.writeAll(if (builder) "capnp.CompositeListBuilder(" else "capnp.CompositeListReader(");
                try writeType(ctx, element, .base, false, false);
                try ctx.writer.writeAll(if (builder) ".Builder, " else ".Reader, ");
                try writeType(ctx, element, .base, false, false);
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
                    .list, .data, .text, .@"struct", .anyPointer, .interface => {
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
                .list => try writeListType(ctx, try reader.list().?.elementType(), gt),
                .@"enum" => try ctx.writeNodeNameById(reader.@"enum"().?.typeId()),
                .@"struct" => {
                    const struct_ = reader.@"struct"().?;
                    const id = struct_.typeId();
                    try ctx.writeNodeNameById(id);
                    if (try nodeIsGeneric(ctx, id)) {
                        try writeBrandArgs(ctx, id, try struct_.brand());
                    }
                    try ctx.writer.writeAll(switch (gt) {
                        .base => "",
                        .reader_getter => ".Reader",
                        .builder_getter => ".Builder",
                    });
                },
                .interface => {
                    const interface = reader.interface().?;
                    const id = interface.typeId();
                    try ctx.writeNodeNameById(id);
                    if (try nodeIsGeneric(ctx, id)) {
                        try writeBrandArgs(ctx, id, try interface.brand());
                    }
                    try ctx.writer.writeAll(switch (gt) {
                        .base => "",
                        .reader_getter => ".Reader",
                        .builder_getter => ".Builder",
                    });
                },
                .anyPointer => {
                    if (try typeParameterName(ctx, reader)) |name| {
                        defer ctx.allocator.free(name);
                        try ctx.writer.writeAll(name);
                        try ctx.writer.writeAll(switch (gt) {
                            .base => "",
                            .reader_getter => ".Reader",
                            .builder_getter => ".Builder",
                        });
                    } else {
                        try ctx.writer.writeAll(switch (gt) {
                            .builder_getter => "capnp.AnyPointerBuilder",
                            else => "capnp.AnyPointerReader",
                        });
                    }
                },
                else => try ctx.writer.writeAll("capnp.AnyPointerReader"),
            }
        }

        fn sanitizeName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
            if (name.len == 0) return allocator.dupe(u8, "_annotation");
            const needs_prefix = std.ascii.isDigit(name[0]);
            const out = try allocator.alloc(u8, name.len + @intFromBool(needs_prefix));
            var i: usize = 0;
            if (needs_prefix) {
                out[0] = '_';
                i = 1;
            }
            for (name) |ch| {
                out[i] = if (std.ascii.isAlphanumeric(ch) or ch == '_') ch else '_';
                i += 1;
            }
            return out;
        }

        fn annotationName(ctx: *WriteContext, node: schema.Node.Reader) E![]const u8 {
            const display = try node.displayName();
            const prefix: usize = @intCast(node.displayNamePrefixLength());
            const name = if (prefix <= display.len) display[prefix..] else display;
            return sanitizeName(ctx.allocator, name);
        }

        fn methodTypeName(ctx: *WriteContext, method_name: []const u8, suffix: []const u8) E![]u8 {
            const base = try sanitizeName(ctx.allocator, method_name);
            defer ctx.allocator.free(base);

            if (base.len == 0) {
                return std.fmt.allocPrint(ctx.allocator, "Method{s}", .{suffix});
            }

            const out = try ctx.allocator.alloc(u8, base.len + suffix.len);
            out[0] = std.ascii.toUpper(base[0]);
            @memcpy(out[1..base.len], base[1..]);
            @memcpy(out[base.len..], suffix);
            return out;
        }

        fn writeNodeTypeName(ctx: *WriteContext, node: schema.Node.Reader) E!void {
            try ctx.writeNodeName(node);
            const parameters = try node.parameters();
            if (parameters.length == 0) return;

            try ctx.writer.writeByte('(');
            for (0..parameters.length) |i| {
                if (i != 0) try ctx.writer.writeAll(", ");
                const parameter_name = try sanitizeName(ctx.allocator, try parameters.get(@intCast(i)).name());
                defer ctx.allocator.free(parameter_name);
                try writeReplaceKeyword(parameter_name, ctx.writer);
            }
            try ctx.writer.writeByte(')');
        }

        fn writeAnnotationEntry(ctx: *WriteContext, annotation: schema.Annotation.Reader) E!void {
            const node = try ctx.getNodeById(annotation.id());
            const declaration = node.annotation() orelse {
                try ctx.writeIndent();
                try ctx.writer.print("// unsupported annotation {x}: declaration not found\n", .{annotation.id()});
                return;
            };
            const typ = try declaration.type();
            const value = try annotation.value();
            const name = try annotationName(ctx, node);
            defer ctx.allocator.free(name);

            switch (value.which()) {
                .@"struct" => {
                    try writeStaticConst(ctx, name, typ, (try value.@"struct"()).?, null);
                    return;
                },
                .list => {
                    try writeStaticConst(ctx, name, typ, (try value.list()).?, null);
                    return;
                },
                .anyPointer => {
                    try writeStaticConst(ctx, name, typ, (try value.anyPointer()).?, null);
                    return;
                },
                else => {
                    try ctx.writeIndent();
                    try ctx.writer.print("// unsupported annotation {s}: interface values are not implemented\n", .{name});
                    return;
                },
            }

            try ctx.writeIndent();
            try ctx.writer.writeAll("pub const ");
            try writeReplaceKeyword(name, ctx.writer);
            try ctx.writer.writeAll(": ");
            try writeType(ctx, typ, .base, false, false);
            try ctx.writer.writeAll(" = ");
            try writeConstValue(ctx, typ, value);
            try ctx.writer.writeAll(";\n");
        }

        fn writeAnnotations(
            ctx: *WriteContext,
            annotations: capnp.CompositeListReader(schema.Annotation.Reader, schema.Annotation.reader_trait),
            namespace: []const u8,
        ) E!void {
            if (annotations.length == 0) return;

            try ctx.writeIndent();
            try ctx.writer.print("pub const {s} = struct {{\n", .{namespace});
            ctx.indenter.inc();
            for (0..annotations.length) |i| {
                try writeAnnotationEntry(ctx, annotations.get(@intCast(i)));
            }
            ctx.indenter.dec();
            try ctx.writeIndent();
            try ctx.writer.writeAll("};\n");
        }

        fn writeFieldAnnotations(
            ctx: *WriteContext,
            fields: capnp.CompositeListReader(schema.Field.Reader, schema.Field.reader_trait),
        ) E!void {
            var any = false;
            for (0..fields.length) |i| {
                if ((try fields.get(@intCast(i)).annotations()).length != 0) {
                    any = true;
                    break;
                }
            }
            if (!any) return;

            try ctx.writeIndent();
            try ctx.writer.writeAll("pub const field_annotations = struct {\n");
            ctx.indenter.inc();
            for (0..fields.length) |i| {
                const field = fields.get(@intCast(i));
                const annotations = try field.annotations();
                if (annotations.length == 0) continue;

                try ctx.writeIndent();
                try ctx.writer.writeAll("pub const ");
                try writeReplaceKeyword(try field.name(), ctx.writer);
                try ctx.writer.writeAll(" = struct {\n");
                ctx.indenter.inc();
                for (0..annotations.length) |j| {
                    try writeAnnotationEntry(ctx, annotations.get(@intCast(j)));
                }
                ctx.indenter.dec();
                try ctx.writeIndent();
                try ctx.writer.writeAll("};\n");
            }
            ctx.indenter.dec();
            try ctx.writeIndent();
            try ctx.writer.writeAll("};\n");
        }

        fn writeEnumerantAnnotations(
            ctx: *WriteContext,
            enumerants: capnp.CompositeListReader(schema.Enumerant.Reader, schema.Enumerant.reader_trait),
        ) E!void {
            var any = false;
            for (0..enumerants.length) |i| {
                if ((try enumerants.get(@intCast(i)).annotations()).length != 0) {
                    any = true;
                    break;
                }
            }
            if (!any) return;

            try ctx.writeIndent();
            try ctx.writer.writeAll("pub const enumerant_annotations = struct {\n");
            ctx.indenter.inc();
            for (0..enumerants.length) |i| {
                const enumerant = enumerants.get(@intCast(i));
                const annotations = try enumerant.annotations();
                if (annotations.length == 0) continue;

                try ctx.writeIndent();
                try ctx.writer.writeAll("pub const ");
                try writeReplaceKeyword(try enumerant.name(), ctx.writer);
                try ctx.writer.writeAll(" = struct {\n");
                ctx.indenter.inc();
                for (0..annotations.length) |j| {
                    try writeAnnotationEntry(ctx, annotations.get(@intCast(j)));
                }
                ctx.indenter.dec();
                try ctx.writeIndent();
                try ctx.writer.writeAll("};\n");
            }
            ctx.indenter.dec();
            try ctx.writeIndent();
            try ctx.writer.writeAll("};\n");
        }

        pub fn generateFile(
            allocator: std.mem.Allocator,
            arena: std.mem.Allocator,
            requested: schema.CodeGeneratorRequest.RequestedFile.Reader,
            nodes: *const NodeMap,
            source_info: *const SourceInfoMap,
            imports: []const ImportAlias,
        ) E![]u8 {
            var used = std.AutoHashMap(u64, void).init(allocator);
            defer used.deinit();

            var discard_buf: [4096]u8 = undefined;
            var discard = std.Io.Writer.Discarding.init(&discard_buf);
            {
                var ctx = WriteContext{
                    .writer = &discard.writer,
                    .indenter = Indenter{},
                    .nodes = nodes,
                    .source_info = source_info,
                    .allocator = allocator,
                    .current_file_id = requested.id(),
                    .imports = imports,
                    .emit_header = false,
                    .used_imports = &used,
                };
                const file_node = try ctx.getNodeById(requested.id());
                try writeNode(&ctx, try requested.filename(), file_node);
            }

            var used_aliases = std.ArrayList(ImportAlias).empty;
            for (imports) |import_| {
                if (used.contains(import_.file_id)) {
                    try used_aliases.append(arena, import_);
                }
            }

            var output = std.Io.Writer.Allocating.init(allocator);
            errdefer output.deinit();
            var ctx = WriteContext{
                .writer = &output.writer,
                .indenter = Indenter{},
                .nodes = nodes,
                .source_info = source_info,
                .allocator = allocator,
                .current_file_id = requested.id(),
                .imports = used_aliases.items,
                .emit_header = true,
            };
            const file_node = try ctx.getNodeById(requested.id());
            try writeNode(&ctx, try requested.filename(), file_node);
            return output.toOwnedSlice();
        }

        pub fn writeNode(ctx: *WriteContext, name: []const u8, node: schema.Node.Reader) E!void {
            switch (node.which()) {
                .file => {
                    if (ctx.emit_header) {
                        try ctx.writer.print("// {s}\n", .{name});
                        try ctx.writer.writeAll("// This file is automatically generated. DO NOT EDIT.\n\n");
                        if (try ctx.writeDocComment("//!", try ctx.nodeDoc(node))) {
                            try ctx.writer.writeByte('\n');
                        }
                        try ctx.writer.writeAll("const _Root = @This();\nconst capnp = @import(\"capnp\");\n");
                        for (ctx.imports) |import_| {
                            try ctx.writer.writeAll("const ");
                            try writeReplaceKeyword(import_.module, ctx.writer);
                            try ctx.writer.print(" = @import(\"{s}\");\n", .{import_.path});
                        }
                        try ctx.writer.writeAll("\n");
                    }

                    const nested_nodes = try node.nestedNodes();
                    for (0..nested_nodes.length) |i| {
                        const nested_node = nested_nodes.get(@intCast(i));
                        try writeNode(ctx, try nested_node.name(), try ctx.getNodeById(nested_node.id()));
                    }
                },

                .@"enum" => {
                    _ = try ctx.writeDocComment("///", try ctx.nodeDoc(node));
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const ");
                    try writeReplaceKeyword(name, ctx.writer);
                    try ctx.writer.writeAll(" = enum(u16) {\n");
                    ctx.indenter.inc();

                    const enumerants = try node.@"enum"().?.enumerants();
                    for (0..enumerants.length) |i| {
                        const enumerant = enumerants.get(@intCast(i));
                        _ = try ctx.writeDocComment("///", try ctx.memberDoc(node, i));
                        try ctx.writeIndent();
                        try writeReplaceKeyword(try enumerant.name(), ctx.writer);
                        try ctx.writer.print(" = {d},\n", .{i});
                    }
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("_,\n");

                    try writeAnnotations(ctx, try node.annotations(), "annotations");
                    try writeEnumerantAnnotations(ctx, enumerants);

                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("};\n");
                },

                .interface => {
                    _ = try ctx.writeDocComment("///", try ctx.nodeDoc(node));
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const ");
                    try writeReplaceKeyword(name, ctx.writer);
                    try ctx.writer.writeAll(" = struct {\n");
                    ctx.indenter.inc();

                    try ctx.writeIndent();
                    try ctx.writer.print("pub const id: u64 = 0x{x};\n\n", .{node.id()});

                    // A nested interface can reuse the RPC import from its parent
                    // interface; declaring it again would be an ambiguous reference.
                    if (ctx.interface_depth == 0) {
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("const _capnp_rpc = @import(\"capnp_rpc\");\n\n");
                    }
                    ctx.interface_depth += 1;
                    defer ctx.interface_depth -= 1;

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const Reader = capnp.AnyPointerReader;\n");
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const Builder = capnp.AnyPointerBuilder;\n\n");

                    const interface = node.interface().?;
                    const methods = try interface.methods();

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const Method = enum(u16) {\n");
                    ctx.indenter.inc();
                    for (0..methods.length) |i| {
                        const method = methods.get(@intCast(i));
                        _ = try ctx.writeDocComment("///", try ctx.memberDoc(node, i));
                        try ctx.writeIndent();
                        try writeReplaceKeyword(try method.name(), ctx.writer);
                        try ctx.writer.print(" = {d},\n", .{i});
                    }
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("_,\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("};\n\n");

                    const superclasses = try interface.superclasses();
                    if (superclasses.length != 0) {
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub const superclasses = [_]u64{\n");
                        ctx.indenter.inc();
                        for (0..superclasses.length) |i| {
                            try ctx.writeIndent();
                            try ctx.writer.print("0x{x},\n", .{superclasses.get(@intCast(i)).id()});
                        }
                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("};\n\n");
                    }

                    for (0..methods.length) |i| {
                        const method = methods.get(@intCast(i));

                        const params_id = method.paramStructType();
                        if (params_id != 0) {
                            const params = try ctx.getNodeById(params_id);
                            const type_name = try methodTypeName(ctx, try method.name(), "Params");
                            defer ctx.allocator.free(type_name);
                            if (params.scopeId() == 0) {
                                try writeNode(ctx, type_name, params);
                            } else {
                                try ctx.writeIndent();
                                try ctx.writer.writeAll("pub const ");
                                try writeReplaceKeyword(type_name, ctx.writer);
                                try ctx.writer.writeAll(" = ");
                                try ctx.writeNodeNameById(params_id);
                                try ctx.writer.writeAll(";\n\n");
                            }
                        }

                        const results_id = method.resultStructType();
                        if (results_id != 0) {
                            const results = try ctx.getNodeById(results_id);
                            const type_name = try methodTypeName(ctx, try method.name(), "Results");
                            defer ctx.allocator.free(type_name);
                            if (results.scopeId() == 0) {
                                try writeNode(ctx, type_name, results);
                            } else {
                                try ctx.writeIndent();
                                try ctx.writer.writeAll("pub const ");
                                try writeReplaceKeyword(type_name, ctx.writer);
                                try ctx.writer.writeAll(" = ");
                                try ctx.writeNodeNameById(results_id);
                                try ctx.writer.writeAll(";\n\n");
                            }
                        }
                    }

                    for (0..methods.length) |i| {
                        const method = methods.get(@intCast(i));
                        const method_name = try method.name();
                        const request_name = try methodTypeName(ctx, method_name, "Request");
                        defer ctx.allocator.free(request_name);
                        const params_name = try methodTypeName(ctx, method_name, "Params");
                        defer ctx.allocator.free(params_name);

                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub const ");
                        try writeReplaceKeyword(request_name, ctx.writer);
                        try ctx.writer.writeAll(" = struct {\n");
                        ctx.indenter.inc();

                        try ctx.writeIndent();
                        try ctx.writer.writeAll("request: _capnp_rpc.Request,\n\n");

                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub fn params(self: *@This()) !");
                        try writeReplaceKeyword(params_name, ctx.writer);
                        try ctx.writer.writeAll(".Builder {\n");
                        ctx.indenter.inc();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("return try self.request.initParams(");
                        try writeReplaceKeyword(params_name, ctx.writer);
                        try ctx.writer.writeAll(".Builder, ");
                        try writeReplaceKeyword(params_name, ctx.writer);
                        try ctx.writer.writeAll(".builder_trait);\n");
                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("}\n\n");

                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub fn addCapability(self: *@This(), capability: _capnp_rpc.Capability) !u32 {\n");
                        ctx.indenter.inc();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("return self.request.addCapability(capability);\n");
                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("}\n\n");

                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub fn addLocalCapability(self: *@This(), capability: _capnp_rpc.LocalCapability) !u32 {\n");
                        ctx.indenter.inc();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("return self.request.addLocalCapability(capability);\n");
                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("}\n\n");

                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub fn start(self: *@This()) !_capnp_rpc.Promise {\n");
                        ctx.indenter.inc();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("return self.request.start();\n");
                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("}\n\n");

                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub fn send(self: *@This()) !_capnp_rpc.Response {\n");
                        ctx.indenter.inc();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("return self.request.send();\n");
                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("}\n\n");

                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub fn deinit(self: *@This()) void {\n");
                        ctx.indenter.inc();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("self.request.deinit();\n");
                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("}\n");

                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("};\n\n");
                    }

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const Client = struct {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("capability: _capnp_rpc.Capability,\n\n");
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("/// Takes ownership of `capability`; release it with `deinit`.\n");
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub fn fromCapability(capability: _capnp_rpc.Capability) @This() {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("return .{ .capability = capability };\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("/// Release the owned capability handle.\n");
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub fn deinit(self: *@This()) void {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("self.capability.release();\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}\n");

                    for (0..methods.length) |i| {
                        const method = methods.get(@intCast(i));
                        const method_name = try method.name();
                        const request_name = try methodTypeName(ctx, method_name, "Request");
                        defer ctx.allocator.free(request_name);

                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub fn ");
                        try writeReplaceKeyword(method_name, ctx.writer);
                        try ctx.writer.writeAll("(self: *@This()) !");
                        try writeReplaceKeyword(request_name, ctx.writer);
                        try ctx.writer.writeAll(" {\n");
                        ctx.indenter.inc();
                        try ctx.writeIndent();
                        try ctx.writer.print("return .{{ .request = try self.capability.beginCall(0x{x}, {d}) }};\n", .{ node.id(), i });
                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("}\n");
                    }

                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("};\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const Server = struct {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("context: *anyopaque,\n");
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("vtable: VTable,\n");
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("/// Optional. Called when the last handle and wire export are gone.\n");
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("destroy: ?*const fn (context: *anyopaque) void = null,\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const VTable = struct {\n");
                    ctx.indenter.inc();
                    for (0..methods.length) |i| {
                        const method = methods.get(@intCast(i));
                        const method_name = try method.name();
                        const params_name = try methodTypeName(ctx, method_name, "Params");
                        defer ctx.allocator.free(params_name);
                        const results_name = try methodTypeName(ctx, method_name, "Results");
                        defer ctx.allocator.free(results_name);

                        try ctx.writeIndent();
                        try writeReplaceKeyword(method_name, ctx.writer);
                        try ctx.writer.writeAll(": *const fn (context: *anyopaque, params: ");
                        try writeReplaceKeyword(params_name, ctx.writer);
                        try ctx.writer.writeAll(".Reader, results: ");
                        try writeReplaceKeyword(results_name, ctx.writer);
                        try ctx.writer.writeAll(".Builder, capnp_call: _capnp_rpc.Call) anyerror!void,\n");
                    }
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("};\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub fn localCapability(self: *@This()) _capnp_rpc.LocalCapability {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.print("return .{{ .context = self, .interface_id = 0x{x}, .dispatch = dispatch, .destroy = self.destroy }};\n", .{node.id()});
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("fn dispatch(capnp_context: *anyopaque, capnp_method_id: u16, capnp_call: _capnp_rpc.Call) anyerror!void {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("const self: *@This() = @ptrCast(@alignCast(capnp_context));\n");
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("switch (capnp_method_id) {\n");
                    ctx.indenter.inc();
                    for (0..methods.length) |i| {
                        const method = methods.get(@intCast(i));
                        const method_name = try method.name();
                        const params_name = try methodTypeName(ctx, method_name, "Params");
                        defer ctx.allocator.free(params_name);
                        const results_name = try methodTypeName(ctx, method_name, "Results");
                        defer ctx.allocator.free(results_name);

                        try ctx.writeIndent();
                        try ctx.writer.print("{d} => {{\n", .{i});
                        ctx.indenter.inc();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("const params = try capnp_call.params.asStruct(");
                        try writeReplaceKeyword(params_name, ctx.writer);
                        try ctx.writer.writeAll(".Reader, ");
                        try writeReplaceKeyword(params_name, ctx.writer);
                        try ctx.writer.writeAll(".reader_trait);\n");
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("const results = try capnp_call.results.initStruct(");
                        try writeReplaceKeyword(results_name, ctx.writer);
                        try ctx.writer.writeAll(".Builder, ");
                        try writeReplaceKeyword(results_name, ctx.writer);
                        try ctx.writer.writeAll(".builder_trait);\n");
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("return self.vtable.");
                        try writeReplaceKeyword(method_name, ctx.writer);
                        try ctx.writer.writeAll("(self.context, params, results, capnp_call);\n");
                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("},\n");
                    }
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("else => return error.MethodNotFound,\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}\n");

                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("};\n");

                    try writeAnnotations(ctx, try node.annotations(), "annotations");

                    const nested_nodes = try node.nestedNodes();
                    for (0..nested_nodes.length) |i| {
                        const nested_node = nested_nodes.get(@intCast(i));
                        try writeNode(ctx, try nested_node.name(), try ctx.getNodeById(nested_node.id()));
                    }

                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("};\n");
                },

                .@"const" => {
                    const const_node = node.@"const"().?;
                    const typ = try const_node.type();
                    const value = try const_node.value();
                    const doc = try ctx.nodeDoc(node);

                    switch (value.which()) {
                        .void,
                        .bool,
                        .int8,
                        .int16,
                        .int32,
                        .int64,
                        .uint8,
                        .uint16,
                        .uint32,
                        .uint64,
                        .float32,
                        .float64,
                        .text,
                        .data,
                        .@"enum",
                        => {},
                        .@"struct" => {
                            try writeStaticConst(ctx, name, typ, (try value.@"struct"()).?, doc);
                            return;
                        },
                        .list => {
                            try writeStaticConst(ctx, name, typ, (try value.list()).?, doc);
                            return;
                        },
                        .anyPointer => {
                            try writeStaticConst(ctx, name, typ, (try value.anyPointer()).?, doc);
                            return;
                        },
                        else => {
                            try ctx.writeIndent();
                            try ctx.writer.print("// unsupported const {s}: interface constants are not implemented\n", .{name});
                            return;
                        },
                    }

                    _ = try ctx.writeDocComment("///", doc);
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const ");
                    try writeReplaceKeyword(name, ctx.writer);
                    try ctx.writer.writeAll(": ");
                    try writeType(ctx, typ, .base, false, false);
                    try ctx.writer.writeAll(" = ");
                    try writeConstValue(ctx, typ, value);
                    try ctx.writer.writeAll(";\n");
                },

                .annotation => {},

                .@"struct" => {
                    const parameters = try node.parameters();
                    const is_generic = parameters.length != 0;

                    _ = try ctx.writeDocComment("///", try ctx.nodeDoc(node));
                    if (is_generic) {
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub fn ");
                        try writeReplaceKeyword(name, ctx.writer);
                        try ctx.writer.writeByte('(');
                        for (0..parameters.length) |i| {
                            if (i != 0) try ctx.writer.writeAll(", ");
                            const parameter_name = try sanitizeName(ctx.allocator, try parameters.get(@intCast(i)).name());
                            defer ctx.allocator.free(parameter_name);
                            try ctx.writer.writeAll("comptime ");
                            try writeReplaceKeyword(parameter_name, ctx.writer);
                            try ctx.writer.writeAll(": type");
                        }
                        try ctx.writer.writeAll(") type {\n");
                        ctx.indenter.inc();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("return struct {\n");
                        ctx.indenter.inc();
                    } else {
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub const ");
                        try writeReplaceKeyword(name, ctx.writer);
                        try ctx.writer.writeAll(" = struct {\n");
                        ctx.indenter.inc();
                    }
                    try ctx.writeIndent();
                    try ctx.writer.print("pub const id: u64 = 0x{x};\n\n", .{node.id()});

                    const struct_ = node.@"struct"().?;
                    const fields = try struct_.fields();

                    if (struct_.discriminantCount() > 0) {
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub const Tag = enum(u16) {\n");
                        ctx.indenter.inc();

                        for (0..fields.length) |i| {
                            const field = fields.get(@intCast(i));
                            if (field.discriminantValue() == 0xffff) continue;
                            _ = try ctx.writeDocComment("///", try ctx.memberDoc(node, i));
                            try ctx.writeIndent();
                            try writeReplaceKeyword(try field.name(), ctx.writer);
                            try ctx.writer.print(" = {},\n", .{field.discriminantValue()});
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

                        try writeNode(ctx, try field.name(), try ctx.getNodeById(field.group().?.typeId()));
                    }

                    try writeAnnotations(ctx, try node.annotations(), "annotations");
                    try writeFieldAnnotations(ctx, fields);

                    const nested_nodes = try node.nestedNodes();
                    for (0..nested_nodes.length) |i| {
                        const nested_node = nested_nodes.get(@intCast(i));
                        try writeNode(ctx, try nested_node.name(), try ctx.getNodeById(nested_node.id()));
                    }

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const Reader = struct {\n");
                    ctx.indenter.inc();

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("reader: capnp.StructReader,\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub fn fromStructReader(capnp_reader: capnp.StructReader) @This() {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("return .{ .reader = capnp_reader };\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub fn fromReadContext(capnp_context: capnp.ReadContext) capnp.Error!@This() {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("return @This().fromStructReader(try capnp.StructReader.fromReadContext(capnp_context));\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub fn fromNull(capnp_context: capnp.ReadContext) @This() {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("return @This().fromStructReader(capnp.StructReader.fromNull(capnp_context));\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}\n\n");

                    if (struct_.discriminantCount() > 0) {
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub fn which(self: @This()) ");
                        try writeNodeTypeName(ctx, node);
                        try ctx.writer.writeAll(".Tag {\n");
                        ctx.indenter.inc();

                        try ctx.writeIndent();
                        try ctx.writer.print("return @fromBackingInt(@intCast(self.reader.readIntField(u16, {d})));\n", .{struct_.discriminantOffset()});

                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("}\n\n");
                    }

                    for (0..fields.length) |i| {
                        try writeGetter(
                            ctx,
                            struct_.discriminantOffset(),
                            fields.get(@intCast(i)),
                            .reader,
                            try ctx.memberDoc(node, i),
                        );
                        try ctx.writer.writeAll("\n\n");
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
                    try ctx.writer.writeAll("pub fn fromStructBuilder(capnp_builder: capnp.StructBuilder) @This() {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("return .{ .builder = capnp_builder };\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub fn fromBuildContext(capnp_context: capnp.BuildContext) @This() {\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("return .{ .builder = capnp.StructBuilder.fromBuildContext(capnp_context) };\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("}\n\n");

                    if (struct_.discriminantCount() > 0) {
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("pub fn which(self: @This()) ");
                        try writeNodeTypeName(ctx, node);
                        try ctx.writer.writeAll(".Tag {\n");
                        ctx.indenter.inc();
                        try ctx.writeIndent();
                        try ctx.writer.print("return @fromBackingInt(@intCast(self.builder.readIntField(u16, {d})));\n", .{struct_.discriminantOffset()});
                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("}\n\n");
                    }

                    for (0..fields.length) |i| {
                        try writeGetter(
                            ctx,
                            struct_.discriminantOffset(),
                            fields.get(@intCast(i)),
                            .builder,
                            try ctx.memberDoc(node, i),
                        );
                        try ctx.writer.writeAll("\n\n");
                        try writeSetter(ctx, struct_.discriminantOffset(), fields.get(@intCast(i)));
                        try ctx.writer.writeAll("\n\n");
                    }

                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("};\n\n");

                    try ctx.writeIndent();
                    try ctx.writer.writeAll("pub const builder_trait = capnp.BuilderTrait(@This().Builder){\n");
                    ctx.indenter.inc();
                    try ctx.writeIndent();
                    try ctx.writer.print(".data_words = {d},\n", .{struct_.dataWordCount()});
                    try ctx.writeIndent();
                    try ctx.writer.print(".ptr_words = {d},\n", .{struct_.pointerCount()});
                    try ctx.writeIndent();
                    try ctx.writer.writeAll(".builder = @This().Builder.fromStructBuilder,\n");
                    ctx.indenter.dec();
                    try ctx.writeIndent();
                    try ctx.writer.writeAll("};\n\n");

                    if (is_generic) {
                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("};\n");
                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("}\n\n");
                    } else {
                        ctx.indenter.dec();
                        try ctx.writeIndent();
                        try ctx.writer.writeAll("};\n\n");
                    }
                },
                _ => {
                    @panic("Unknown node type");
                },
            }
        }

        fn writeIntDefault(writer: *W, comptime tag: schema.Type.Tag, value: schema.Value.Reader) E!void {
            switch (tag) {
                .int8 => try writer.print("{d}", .{value.int8() orelse 0}),
                .int16 => try writer.print("{d}", .{value.int16() orelse 0}),
                .int32 => try writer.print("{d}", .{value.int32() orelse 0}),
                .int64 => try writer.print("{d}", .{value.int64() orelse 0}),
                .uint8 => try writer.print("{d}", .{value.uint8() orelse 0}),
                .uint16 => try writer.print("{d}", .{value.uint16() orelse 0}),
                .uint32 => try writer.print("{d}", .{value.uint32() orelse 0}),
                .uint64 => try writer.print("{d}", .{value.uint64() orelse 0}),
                else => unreachable,
            }
        }

        fn writeStringLiteral(writer: *W, bytes: []const u8) E!void {
            try writer.writeByte('"');
            for (bytes) |byte| {
                switch (byte) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try writer.writeByte(byte),
                    else => try writer.print("\\x{x:0>2}", .{byte}),
                }
            }
            try writer.writeByte('"');
        }

        fn writeStaticConst(
            ctx: *WriteContext,
            name: []const u8,
            typ: schema.Type.Reader,
            source: capnp.AnyPointerReader,
            doc: ?[]const u8,
        ) E!void {
            var builder = capnp.MessageBuilder{ .allocator = ctx.allocator };
            try builder.init();
            defer builder.deinit();
            try builder.initFromAnyPointer(source);

            const size = try builder.serializedSize();
            const bytes = try ctx.allocator.alloc(u8, size);
            defer ctx.allocator.free(bytes);
            _ = try builder.writeToBuffer(bytes);

            const segment_count: usize = 1 + std.mem.readInt(u32, bytes[0..4], .little);
            const data_start = std.mem.alignForward(usize, 4 + 4 * segment_count, 8);

            try ctx.writeIndent();
            try ctx.writer.print("const {s}_bytes align(8) = [_]u8{{\n", .{name});
            ctx.indenter.inc();
            try ctx.writeIndent();
            for (bytes, 0..) |byte, i| {
                if (i != 0 and i % 16 == 0) {
                    try ctx.writer.writeAll("\n");
                    try ctx.writeIndent();
                }
                try ctx.writer.print("0x{x:0>2}, ", .{byte});
            }
            try ctx.writer.writeAll("\n");
            ctx.indenter.dec();
            try ctx.writeIndent();
            try ctx.writer.writeAll("};\n\n");

            try ctx.writeIndent();
            try ctx.writer.print("const {s}_segments = [_][]const u8{{\n", .{name});
            ctx.indenter.inc();
            var offset = data_start;
            for (0..segment_count) |i| {
                const segment_bytes = std.math.mul(usize, std.mem.readInt(u32, bytes[4 + i * 4 ..][0..4], .little), 8) catch return error.MessageTooLarge;
                try ctx.writeIndent();
                try ctx.writer.print("{s}_bytes[{d}..][0..{d}],\n", .{ name, offset, segment_bytes });
                offset += segment_bytes;
            }
            ctx.indenter.dec();
            try ctx.writeIndent();
            try ctx.writer.writeAll("};\n\n");

            _ = try ctx.writeDocComment("///", doc);
            try ctx.writeIndent();
            try ctx.writer.writeAll("pub fn ");
            try writeReplaceKeyword(name, ctx.writer);
            try ctx.writer.writeAll("() ");
            try writeType(ctx, typ, .reader_getter, false, false);
            try ctx.writer.writeAll(" {\n");
            ctx.indenter.inc();
            try ctx.writeIndent();
            try ctx.writer.writeAll("return capnp.getStaticRoot(");
            try writeType(ctx, typ, .reader_getter, false, false);
            try ctx.writer.print(", &{s}_segments) catch unreachable;\n", .{name});
            ctx.indenter.dec();
            try ctx.writeIndent();
            try ctx.writer.writeAll("}\n\n");

            try ctx.writeIndent();
            try ctx.writer.print("pub fn {s}Message() []const u8 {{\n", .{name});
            ctx.indenter.inc();
            try ctx.writeIndent();
            try ctx.writer.print("return &{s}_bytes;\n", .{name});
            ctx.indenter.dec();
            try ctx.writeIndent();
            try ctx.writer.writeAll("}\n");
        }

        fn writeConstValue(ctx: *WriteContext, typ: schema.Type.Reader, value: schema.Value.Reader) E!void {
            switch (value.which()) {
                .void => try ctx.writer.writeAll("{}"),
                .bool => try ctx.writer.writeAll(if (value.bool().?) "true" else "false"),
                .int8 => try ctx.writer.print("{d}", .{value.int8().?}),
                .int16 => try ctx.writer.print("{d}", .{value.int16().?}),
                .int32 => try ctx.writer.print("{d}", .{value.int32().?}),
                .int64 => try ctx.writer.print("{d}", .{value.int64().?}),
                .uint8 => try ctx.writer.print("{d}", .{value.uint8().?}),
                .uint16 => try ctx.writer.print("{d}", .{value.uint16().?}),
                .uint32 => try ctx.writer.print("{d}", .{value.uint32().?}),
                .uint64 => try ctx.writer.print("{d}", .{value.uint64().?}),
                .float32 => try ctx.writer.print("{d}", .{value.float32().?}),
                .float64 => try ctx.writer.print("{d}", .{value.float64().?}),
                .text => try writeStringLiteral(ctx.writer, try value.text() orelse ""),
                .data => try writeStringLiteral(ctx.writer, try value.data() orelse ""),
                .@"enum" => {
                    const v = value.@"enum"().?;
                    if (typ.@"enum"()) |enum_| {
                        const id = enum_.typeId();
                        const enum_node = try ctx.getNodeById(id);
                        const enumerants = try enum_node.@"enum"().?.enumerants();
                        if (v < enumerants.length) {
                            try ctx.writeNodeNameById(id);
                            try ctx.writer.writeAll(".");
                            try writeReplaceKeyword(try enumerants.get(v).name(), ctx.writer);
                            return;
                        }
                    }
                    try ctx.writer.print("@fromBackingInt(@intCast({d}))", .{v});
                },
                .list, .@"struct", .interface, .anyPointer => unreachable,
                else => unreachable,
            }
        }

        pub fn writeGetter(
            ctx: *WriteContext,
            discriminantOffset: u32,
            field: schema.Field.Reader,
            gt: getter_type,
            doc: ?[]const u8,
        ) E!void {
            const target = gt.toString();

            _ = try ctx.writeDocComment("///", doc);
            try ctx.openGetter(field, gt);

            if (field.discriminantValue() != 0xffff) {
                try ctx.writeIndent();
                try ctx.writer.print("if (self.{s}.readIntField(u16, {}) != {}) {{ return null; }}\n", .{ target, discriminantOffset, field.discriminantValue() });
            }

            try ctx.writeIndent();

            switch (field.which()) {
                .slot => {
                    const slot = field.slot().?;
                    const t = try slot.type();

                    switch (t.which()) {
                        .void => {
                            try ctx.writer.print("return self.{s}.readVoid();\n", .{target});
                        },
                        .bool => {
                            const default_value = (try slot.defaultValue()).bool() orelse false;
                            try ctx.writer.print("return self.{s}.readBoolField({d}) != {s};\n", .{
                                target,
                                slot.offset(),
                                if (default_value) "true" else "false",
                            });
                        },
                        inline .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64 => |typeTag| {
                            const typeTagName = @tagName(typeTag);
                            const default_value = try slot.defaultValue();

                            try ctx.writer.print("return self.{s}.readIntField({s}, {d}) ^ ", .{
                                target,
                                zigNameHelper(typeTagName, if (typeTagName[0] == 'u') 4 else 3),
                                slot.offset(),
                            });
                            try writeIntDefault(ctx.writer, typeTag, default_value);
                            try ctx.writer.writeAll(";\n");
                        },
                        inline .float32, .float64 => |typeTag| {
                            const default_value = try slot.defaultValue();
                            const bits: u64 = switch (typeTag) {
                                .float32 => if (default_value.float32()) |v| @as(u32, @bitCast(v)) else 0,
                                .float64 => if (default_value.float64()) |v| @as(u64, @bitCast(v)) else 0,
                                else => unreachable,
                            };
                            const int_type = if (typeTag == .float32) "u32" else "u64";
                            try ctx.writer.print("return @bitCast(self.{s}.readIntField({s}, {d}) ^ {d});\n", .{
                                target,
                                int_type,
                                slot.offset(),
                                bits,
                            });
                        },
                        .text => {
                            try ctx.writer.print(
                                "return try self.{s}.readStringField({d});\n",
                                .{
                                    gt.toString(),
                                    field.slot().?.offset(),
                                },
                            );
                        },
                        .data => {
                            try ctx.writer.print(
                                "return try self.{s}.readDataField({d});\n",
                                .{
                                    gt.toString(),
                                    field.slot().?.offset(),
                                },
                            );
                        },
                        .list => {
                            const method = if (gt == .builder) "buildPtrField" else "readPtrField";
                            try ctx.writer.print("return {s}self.{s}.{s}(", .{ if (gt == .builder) "" else "try ", target, method });
                            try writeType(ctx, t, if (gt == .builder) .builder_getter else .reader_getter, false, false);
                            try ctx.writer.print(", {d});\n", .{slot.offset()});
                        },
                        .@"struct" => {
                            if (gt == .builder) {
                                try ctx.writer.writeAll("return try self.builder.buildStructField(");
                                try writeType(ctx, t, .builder_getter, false, false);
                                try ctx.writer.writeAll(", ");
                                try writeType(ctx, t, .base, false, false);
                                try ctx.writer.writeAll(".builder_trait, ");
                                try ctx.writer.print("{d});\n", .{slot.offset()});
                            } else {
                                try ctx.writer.writeAll("return try self.reader.readPtrField(");
                                try writeType(ctx, t, .reader_getter, false, false);
                                try ctx.writer.print(", {d});\n", .{slot.offset()});
                            }
                        },
                        .anyPointer => {
                            if (try typeParameterName(ctx, t)) |name| {
                                defer ctx.allocator.free(name);
                                if (gt == .builder) {
                                    try ctx.writer.print("return try {s}.buildField(self.builder, {d});\n", .{ name, slot.offset() });
                                } else {
                                    try ctx.writer.print("return try {s}.readField(self.reader, {d});\n", .{ name, slot.offset() });
                                }
                            } else if (gt == .builder) {
                                try ctx.writer.writeAll("return self.builder.buildPtrField(");
                                try writeType(ctx, t, .builder_getter, false, false);
                                try ctx.writer.print(", {d});\n", .{slot.offset()});
                            } else {
                                try ctx.writer.writeAll("return try self.reader.readPtrField(");
                                try writeType(ctx, t, .reader_getter, false, false);
                                try ctx.writer.print(", {d});\n", .{slot.offset()});
                            }
                        },
                        .interface => {
                            if (gt == .builder) {
                                try ctx.writer.writeAll("return self.builder.buildPtrField(");
                                try writeType(ctx, t, .builder_getter, false, false);
                                try ctx.writer.print(", {d});\n", .{slot.offset()});
                            } else {
                                try ctx.writer.writeAll("return try self.reader.readPtrField(");
                                try writeType(ctx, t, .reader_getter, false, false);
                                try ctx.writer.print(", {d});\n", .{slot.offset()});
                            }
                        },
                        .@"enum" => {
                            const default_value = (try slot.defaultValue()).@"enum"() orelse 0;
                            try ctx.writer.print("return @fromBackingInt(@intCast(self.{s}.readIntField(u16, {d}) ^ {d}));\n", .{
                                target,
                                slot.offset(),
                                default_value,
                            });
                        },
                        else => {},
                    }
                },
                .group => {
                    if (field.group().?.typeId() == 0) {
                        std.debug.print("Problem with group {s} {}\n", .{ try field.name(), field.group().?.typeId() });
                        @panic("ERROR");
                    }

                    switch (gt) {
                        .reader => try ctx.writer.writeAll("return .{ .reader = self.reader };\n"),
                        .builder => try ctx.writer.writeAll("return .{ .builder = self.builder };\n"),
                    }

                    // try ctx.writeIndent();
                    // try ctx.writeNodeNameById(field.group().?.typeId());
                },
                else => {},
            }
            try ctx.closeGetter();
        }

        fn writeDiscriminant(ctx: *WriteContext, discriminant_offset: u32, field: schema.Field.Reader) E!void {
            const discriminant = field.discriminantValue();
            if (discriminant == 0xffff) return;
            try ctx.writeIndent();
            try ctx.writer.print("self.builder.writeIntField(u16, {d}, {d});\n", .{ discriminant_offset, discriminant });
        }

        pub fn writeSetter(ctx: *WriteContext, discriminant_offset: u32, field: schema.Field.Reader) E!void {
            switch (field.which()) {
                .slot => {
                    const slot = field.slot().?;
                    const t = try slot.type();

                    switch (t.which()) {
                        .void => {
                            try ctx.openVoidSetter(try field.name());
                            if (field.discriminantValue() == 0xffff) {
                                // Non-union void fields have no discriminant to
                                // write, so self would otherwise be unused.
                                try ctx.writeIndent();
                                try ctx.writer.writeAll("_ = self;\n");
                            } else {
                                try writeDiscriminant(ctx, discriminant_offset, field);
                            }
                            try ctx.writeIndent();
                            try ctx.writer.writeAll("return;\n");
                            try ctx.closeSetter();
                        },

                        .bool => {
                            const default_value = (try slot.defaultValue()).bool() orelse false;
                            try ctx.openSetter(try field.name(), "bool", "void");
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();
                            try ctx.writer.print("self.builder.writeBoolField({d}, v != {s});\n", .{
                                slot.offset(),
                                if (default_value) "true" else "false",
                            });
                            try ctx.closeSetter();
                        },

                        inline .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64 => |typeTag| {
                            const typeTagName = @tagName(typeTag);
                            const zigTypeName = zigNameHelper(typeTagName, if (typeTagName[0] == 'u') 4 else 3);

                            const default_value = try slot.defaultValue();

                            try ctx.openSetter(try field.name(), zigTypeName, "void");
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();

                            try ctx.writer.print("self.builder.writeIntField({s}, {d}, v ^ ", .{
                                zigTypeName,
                                slot.offset(),
                            });
                            try writeIntDefault(ctx.writer, typeTag, default_value);
                            try ctx.writer.writeAll(");\n");
                            try ctx.closeSetter();
                        },

                        inline .float32, .float64 => |typeTag| {
                            const typeTagName = @tagName(typeTag);
                            const zigTypeName = zigNameHelper(typeTagName, 5);

                            const default_value = try slot.defaultValue();
                            const bits: u64 = switch (typeTag) {
                                .float32 => if (default_value.float32()) |v| @as(u32, @bitCast(v)) else 0,
                                .float64 => if (default_value.float64()) |v| @as(u64, @bitCast(v)) else 0,
                                else => unreachable,
                            };
                            const int_type = if (typeTag == .float32) "u32" else "u64";

                            try ctx.openSetter(try field.name(), zigTypeName, "void");
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();

                            try ctx.writer.print("self.builder.writeIntField({s}, {d}, @as({s}, @bitCast(v)) ^ {d});\n", .{
                                int_type,
                                slot.offset(),
                                int_type,
                                bits,
                            });
                            try ctx.closeSetter();
                        },

                        .text => {
                            try ctx.openSetter(try field.name(), "[:0]const u8", "capnp.BuildError!void");
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();
                            try ctx.writer.print("try self.builder.writeStringField({d}, v);\n", .{slot.offset()});
                            try ctx.closeSetter();
                        },

                        .data => {
                            try ctx.openSetter(try field.name(), "[]const u8", "capnp.BuildError!void");
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();
                            try ctx.writer.print("try self.builder.writeDataField({d}, v);\n", .{slot.offset()});
                            try ctx.closeSetter();
                        },

                        .@"enum" => {
                            const default_value = (try slot.defaultValue()).@"enum"() orelse 0;

                            try ctx.openSetter(try field.name(), typed(.{ .ctx = ctx, .gt = .base, .typ = t, .with_error = false }), "void");
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();
                            try ctx.writer.print("self.builder.writeIntField(u16, {d}, @intCast(@backingInt(v) ^ {d}));\n", .{ slot.offset(), default_value });
                            try ctx.closeSetter();
                        },

                        .@"struct" => {
                            try ctx.writeIndent();
                            try ctx.writer.print("pub fn set{f}(self: @This()) ", .{capitalized(try field.name())});
                            try writeType(ctx, t, .builder_getter, true, false);
                            try ctx.writer.writeAll(" {\n");
                            ctx.indenter.inc();
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();
                            try ctx.writer.writeAll("return try self.builder.buildStructField(");
                            try writeType(ctx, t, .builder_getter, false, false);
                            try ctx.writer.writeAll(", ");
                            try writeType(ctx, t, .base, false, false);
                            try ctx.writer.writeAll(".builder_trait, ");
                            try ctx.writer.print("{d});\n", .{slot.offset()});
                            ctx.indenter.dec();
                            try ctx.writeIndent();
                            try ctx.writer.writeAll("}\n");
                        },

                        .list, .anyPointer, .interface => {
                            try ctx.writeIndent();
                            try ctx.writer.print("pub fn set{f}(self: @This()) ", .{capitalized(try field.name())});
                            try writeType(ctx, t, .builder_getter, false, false);
                            try ctx.writer.writeAll(" {\n");
                            ctx.indenter.inc();
                            try writeDiscriminant(ctx, discriminant_offset, field);
                            try ctx.writeIndent();
                            try ctx.writer.writeAll("return self.builder.buildPtrField(");
                            try writeType(ctx, t, .builder_getter, false, false);
                            try ctx.writer.print(", {d});\n", .{slot.offset()});
                            ctx.indenter.dec();
                            try ctx.writeIndent();
                            try ctx.writer.writeAll("}\n");
                        },

                        else => {},
                    }
                },
                .group => {
                    const group = field.group().?;
                    if (group.typeId() == 0) {
                        std.debug.panic("ERROR: Problem with group {s} {}", .{ try field.name(), group.typeId() });
                    }

                    if (field.discriminantValue() == 0xffff) return;

                    try ctx.writeIndent();
                    try ctx.writer.print("pub fn set{f}(self: @This()) ", .{capitalized(try field.name())});
                    try ctx.writeNodeNameById(group.typeId());
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
    const fields = try reader.@"struct"().?.fields();

    writer.end = 0;
    try M.writeType(&ctx, try fields.get(0).slot().?.type(), .reader_getter, true, false);
    try std.testing.expectEqualStrings("void", writer.buffered());

    writer.end = 0;
    try M.writeType(&ctx, try fields.get(1).slot().?.type(), .reader_getter, true, false);
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
    const struct_reader = reader.@"struct"().?;
    const field = (try struct_reader.fields()).get(2);

    writer.end = 0;
    try M.writeGetter(&ctx, struct_reader.discriminantOffset(), field, .reader, null);
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
    const nodes = try request.nodes();

    var node_map = std.AutoHashMap(u64, schema.Node.Reader).init(std.testing.allocator);
    defer node_map.deinit();
    for (0..nodes.length) |i| {
        const node = nodes.get(@intCast(i));
        try node_map.put(node.id(), node);
    }

    var source_info = try collectSourceInfo(std.testing.allocator, request);
    defer source_info.deinit();

    const M = Refactor(std.Io.Writer);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var import_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer import_arena.deinit();

    const files = try request.requestedFiles();
    const requested = files.get(0);
    const imports = try collectImports(import_arena.allocator(), requested);

    var ctx = M.WriteContext{
        .writer = &output.writer,
        .indenter = M.Indenter{},
        .nodes = &node_map,
        .source_info = &source_info,
        .allocator = std.testing.allocator,
        .current_file_id = requested.id(),
        .imports = imports,
    };

    const requested_file = try ctx.getNodeById(requested.id());
    try M.writeNode(&ctx, try requested.filename(), requested_file);

    const code = try output.toOwnedSlice();
    defer std.testing.allocator.free(code);

    try std.testing.expect(code.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, code, "// "));
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "/// Schema for a field of a struct.") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "/// All nodes parsed by the compiler") != null);
}

fn generateRequestForTest(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(64 * 1024 * 1024),
    );
    defer allocator.free(bytes);

    var message = try capnp.Message.fromBytes(bytes, allocator);
    defer message.deinit(allocator);

    const M = Refactor(std.Io.Writer);

    const request = try message.getRootStruct(schema.CodeGeneratorRequest.Reader, schema.CodeGeneratorRequest.reader_trait);
    const nodes = try request.nodes();

    var node_map = M.NodeMap.init(allocator);
    defer node_map.deinit();
    for (0..nodes.length) |i| {
        const node = nodes.get(@intCast(i));
        try node_map.put(node.id(), node);
    }

    var source_info = try collectSourceInfo(allocator, request);
    defer source_info.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const files = try request.requestedFiles();
    const requested = files.get(0);
    const imports = try collectImports(arena.allocator(), requested);

    return M.generateFile(allocator, arena.allocator(), requested, &node_map, &source_info, imports);
}

test "doc comments" {
    const features_code = try generateRequestForTest(
        std.testing.allocator,
        "capnp-tests/codegen-request/09_codegen_features.request.bin",
    );
    defer std.testing.allocator.free(features_code);

    try std.testing.expect(std.mem.indexOf(u8, features_code, "//! File-level documentation for the codegen feature fixture.") != null);
    try std.testing.expect(std.mem.indexOf(u8, features_code, "/// Documentation for the Color enum.") != null);
    try std.testing.expect(std.mem.indexOf(u8, features_code, "/// Documentation for the red enumerant.") != null);
    try std.testing.expect(std.mem.indexOf(u8, features_code, "/// Documentation for the Features struct.") != null);
    try std.testing.expect(std.mem.indexOf(u8, features_code, "/// Documentation for the test constant.") != null);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, features_code, "/// Documentation for the name field."),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, features_code, "/// Documentation for the blob field."),
    );

    const union_code = try generateRequestForTest(
        std.testing.allocator,
        "capnp-tests/codegen-request/04_unions.request.bin",
    );
    defer std.testing.allocator.free(union_code);

    try std.testing.expectEqual(
        @as(usize, 3),
        std.mem.count(u8, union_code, "/// Documentation for the void union field."),
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        std.mem.count(u8, union_code, "/// Documentation for the int32 union field."),
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var to_stdout = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--stdout")) to_stdout = true;
    }

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buf);
    const bytes = try stdin_reader.interface.allocRemaining(allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(bytes);

    var message = try capnp.Message.fromBytes(bytes, arena);
    defer message.deinit(arena);

    const request = try message.getRootStruct(schema.CodeGeneratorRequest.Reader, schema.CodeGeneratorRequest.reader_trait);

    var node_map = std.AutoHashMap(u64, schema.Node.Reader).init(allocator);
    defer node_map.deinit();

    const nodes = try request.nodes();
    for (0..nodes.length) |i| {
        const node = nodes.get(@intCast(i));
        try node_map.put(node.id(), node);
    }

    var source_info = try collectSourceInfo(allocator, request);
    defer source_info.deinit();

    const M = Refactor(std.Io.Writer);
    const files = try request.requestedFiles();

    if (to_stdout) {
        var out_buf: [4096]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(init.io, &out_buf);

        for (0..files.length) |i| {
            const requested = files.get(@intCast(i));
            const imports = try collectImports(arena, requested);
            const code = try M.generateFile(allocator, arena, requested, &node_map, &source_info, imports);
            defer allocator.free(code);
            try out_writer.interface.writeAll(code);
        }
        try out_writer.interface.flush();
        return;
    }

    const cwd = std.Io.Dir.cwd();
    for (0..files.length) |i| {
        const requested = files.get(@intCast(i));
        const imports = try collectImports(arena, requested);
        const code = try M.generateFile(allocator, arena, requested, &node_map, &source_info, imports);
        defer allocator.free(code);

        const out_path = try outputFilePath(arena, try requested.filename());
        if (std.mem.lastIndexOfScalar(u8, out_path, '/')) |slash| {
            try cwd.createDirPath(init.io, out_path[0..slash]);
        }
        try cwd.writeFile(init.io, .{ .sub_path = out_path, .data = code });
    }
}
