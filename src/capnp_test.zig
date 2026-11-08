const std = @import("std");
const capnp = @import("capnp");
const schema = @import("capnpc").schema;

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

    const request = try message.getRootStruct(schema.CodeGeneratorRequest.Reader, schema.CodeGeneratorRequest.reader_trait);
    const nodes = try request.nodes();

    try std.testing.expectEqual(@as(u29, 43), nodes.length);

    var seen: [expected_schema_structs.len]bool = @splat(false);
    var schema_struct_count: usize = 0;

    for (0..nodes.length) |i| {
        const node = nodes.get(@intCast(i));
        if (node.which() != .@"struct") continue;

        const display_name = try node.displayName();
        if (std.mem.indexOf(u8, display_name, "schema.capnp:") == null) continue;

        schema_struct_count += 1;
        const struct_node = node.@"struct"().?;
        var found = false;

        for (expected_schema_structs, 0..) |expected, j| {
            if (expected.id != node.id()) continue;

            found = true;
            seen[j] = true;
            try std.testing.expect(std.mem.endsWith(u8, display_name, expected.name));
            try std.testing.expectEqual(expected.data_words, struct_node.dataWordCount());
            try std.testing.expectEqual(expected.ptr_words, struct_node.pointerCount());
            try std.testing.expectEqual(expected.is_group, struct_node.isGroup());
            try std.testing.expectEqual(expected.discriminant_count, struct_node.discriminantCount());
            try std.testing.expectEqual(expected.discriminant_offset, struct_node.discriminantOffset());
            break;
        }

        try std.testing.expect(found);
    }

    try std.testing.expectEqual(expected_schema_structs.len, schema_struct_count);
    for (seen) |was_seen| {
        try std.testing.expect(was_seen);
    }
}
