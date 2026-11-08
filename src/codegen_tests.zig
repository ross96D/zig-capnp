const std = @import("std");
const capnp = @import("capnp");
const capnpc = @import("capnpc");
const codegen = @import("codegen");

const simple = codegen.simple;
const lists = codegen.lists;
const composite = codegen.composite;
const unions = codegen.unions;
const defaults = codegen.defaults;
const features = codegen.features;
const groups = codegen.groups;

fn generateRequest(allocator: std.mem.Allocator, request_path: []const u8) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        request_path,
        allocator,
        .limited(64 * 1024 * 1024),
    );
    defer allocator.free(bytes);

    var message = try capnp.Message.fromBytes(bytes, allocator);
    defer message.deinit(allocator);

    const request = try message.getRootStruct(capnpc.schema.CodeGeneratorRequest.Reader, capnpc.schema.CodeGeneratorRequest.reader_trait);
    const nodes = try request.getNodes();

    var node_map = std.AutoHashMap(u64, capnpc.schema.Node.Reader).init(allocator);
    defer node_map.deinit();
    for (0..nodes.length) |i| {
        const node = nodes.get(@intCast(i));
        try node_map.put(node.getId(), node);
    }

    const M = capnpc.Refactor(std.Io.Writer);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();

    var ctx = M.WriteContext{
        .writer = &output.writer,
        .indenter = M.Indenter{},
        .nodes = &node_map,
    };

    const files = try request.getRequestedFiles();
    for (0..files.length) |i| {
        const requested = files.get(@intCast(i));
        const requested_file = try ctx.getNodeById(requested.getId());
        try M.writeNode(&ctx, try requested.getFilename(), requested_file);
    }

    return output.toOwnedSlice();
}

const golden_cases = [_]struct {
    request: []const u8,
    expected: []const u8,
}{
    .{ .request = "capnp-tests/codegen/01_simple_struct.request.bin", .expected = "capnp-tests/codegen-zig/generated_01_simple_struct.zig" },
    .{ .request = "capnp-tests/codegen/02_simple_lists.request.bin", .expected = "capnp-tests/codegen-zig/generated_02_simple_lists.zig" },
    .{ .request = "capnp-tests/codegen/03_composite_lists.request.bin", .expected = "capnp-tests/codegen-zig/generated_03_composite_lists.zig" },
    .{ .request = "capnp-tests/codegen/04_unions.request.bin", .expected = "capnp-tests/codegen-zig/generated_04_unions.zig" },
    .{ .request = "capnp-tests/codegen/05_default_values.request.bin", .expected = "capnp-tests/codegen-zig/generated_05_default_values.zig" },
    .{ .request = "capnp-tests/codegen/09_codegen_features.request.bin", .expected = "capnp-tests/codegen-zig/generated_09_codegen_features.zig" },
    .{ .request = "capnp-tests/codegen/10_groups.request.bin", .expected = "capnp-tests/codegen-zig/generated_10_groups.zig" },
};

test "golden generated code" {
    for (golden_cases) |case| {
        const generated = try generateRequest(std.testing.allocator, case.request);
        defer std.testing.allocator.free(generated);

        const expected = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            case.expected,
            std.testing.allocator,
            .limited(64 * 1024 * 1024),
        );
        defer std.testing.allocator.free(expected);

        try std.testing.expectEqualStrings(expected, generated);
    }
}

test "generated modules compile" {
    std.testing.refAllDecls(simple);
    std.testing.refAllDecls(lists);
    std.testing.refAllDecls(composite);
    std.testing.refAllDecls(unions);
    std.testing.refAllDecls(defaults);
    std.testing.refAllDecls(features);
    std.testing.refAllDecls(groups);
}

test "generated primitive list round-trip" {
    var builder = capnp.MessageBuilder{ .allocator = std.testing.allocator };
    try builder.init();
    defer builder.deinit();

    var root = try builder.initRootStruct(lists.Lists.Builder, lists.Lists.builder_trait);
    var values = try root.u8();
    try values.init(7);
    for (0..7) |i| values.set(@intCast(i), @intCast(i));

    var message = builder.toReader();
    const reader = try message.getRootStruct(lists.Lists.Reader, lists.Lists.reader_trait);
    const got = try reader.u8();
    try std.testing.expectEqual(@as(u29, 7), got.length);
    for (0..7) |i| try std.testing.expectEqual(@as(u8, @intCast(i)), got.get(@intCast(i)));
}

test "generated composite list round-trip" {
    var builder = capnp.MessageBuilder{ .allocator = std.testing.allocator };
    try builder.init();
    defer builder.deinit();

    var root = try builder.initRootStruct(composite.Lists.Builder, composite.Lists.builder_trait);
    var dates = try root.dates();
    try dates.init(2);

    var first = dates.get(0);
    first.setYear(2023);
    first.setMonth(7);
    first.setDay(14);

    var second = dates.get(1);
    second.setYear(2022);
    second.setMonth(7);
    second.setDay(14);

    var message = builder.toReader();
    const reader = try message.getRootStruct(composite.Lists.Reader, composite.Lists.reader_trait);
    const got = try reader.dates();
    try std.testing.expectEqual(@as(u29, 2), got.length);
    try std.testing.expectEqual(@as(i16, 2023), got.get(0).year());
    try std.testing.expectEqual(@as(i16, 2022), got.get(1).year());
}

test "generated union round-trip" {
    var builder = capnp.MessageBuilder{ .allocator = std.testing.allocator };
    try builder.init();
    defer builder.deinit();

    var root = try builder.initRootStruct(unions.UnionTestList.Builder, unions.UnionTestList.builder_trait);
    var list = try root.unionTests();
    try list.init(3);

    var first = list.get(0);
    first.setInt32(77);

    var second = list.get(1);
    second.setVoid();

    var third = list.get(2);
    third.setInt32(99);

    var message = builder.toReader();
    const reader = try message.getRootStruct(unions.UnionTestList.Reader, unions.UnionTestList.reader_trait);
    const got = try reader.unionTests();
    try std.testing.expectEqual(unions.UnionTest.Tag.int32, got.get(0).which());
    try std.testing.expectEqual(@as(?i32, 77), got.get(0).int32());
    try std.testing.expectEqual(unions.UnionTest.Tag.void, got.get(1).which());
    try std.testing.expectEqual(@as(?i32, null), got.get(1).int32());
    try std.testing.expectEqual(@as(?i32, 99), got.get(2).int32());
}

test "generated defaults round-trip and fixture" {
    var builder = capnp.MessageBuilder{ .allocator = std.testing.allocator };
    try builder.init();
    defer builder.deinit();

    var root = try builder.initRootStruct(defaults.Defaults.Builder, defaults.Defaults.builder_trait);
    try std.testing.expectEqual(@as(i32, 17), root.int32());
    root.setInt32(100);

    var message = builder.toReader();
    const reader = try message.getRootStruct(defaults.Defaults.Reader, defaults.Defaults.reader_trait);
    try std.testing.expectEqual(@as(i32, 100), reader.int32());

    const file = try std.Io.Dir.cwd().openFile(std.testing.io, "capnp-tests/05_default_values.bin", .{});
    defer file.close(std.testing.io);
    var fixture_message = try capnp.Message.fromFile(file, std.testing.io, std.testing.allocator);
    defer fixture_message.deinit(std.testing.allocator);
    const fixture = try fixture_message.getRootStruct(defaults.Defaults.Reader, defaults.Defaults.reader_trait);
    try std.testing.expectEqual(@as(i32, 17), fixture.int32());
}

test "generated text, data, enum, list, and defaults round-trip" {
    var builder = capnp.MessageBuilder{ .allocator = std.testing.allocator };
    try builder.init();
    defer builder.deinit();

    var root = try builder.initRootStruct(features.Features.Builder, features.Features.builder_trait);
    try std.testing.expectEqual(true, root.enabled());
    try std.testing.expectEqual(@as(f32, 1.5), root.ratio());
    try std.testing.expectEqual(@as(i32, -7), root.offset());
    try std.testing.expectEqual(features.Color.green, root.color());

    try root.setName("hello");
    try root.setBlob("bytes");
    root.setColor(.blue);
    root.setEnabled(false);
    root.setRatio(3.25);
    root.setOffset(1234);

    var colors = try root.colors();
    try colors.init(3);
    colors.set(0, .red);
    colors.set(1, .green);
    colors.set(2, .blue);

    var child = try root.child();
    try child.setName("child");

    var message = builder.toReader();
    const reader = try message.getRootStruct(features.Features.Reader, features.Features.reader_trait);
    try std.testing.expectEqualStrings("hello", try reader.name());
    try std.testing.expectEqualStrings("bytes", try reader.blob());
    try std.testing.expectEqual(false, reader.enabled());
    try std.testing.expectEqual(@as(f32, 3.25), reader.ratio());
    try std.testing.expectEqual(@as(i32, 1234), reader.offset());
    try std.testing.expectEqual(features.Color.blue, reader.color());
    try std.testing.expectEqual(features.Color.blue, (try reader.colors()).get(2));
    try std.testing.expectEqualStrings("child", try (try reader.child()).name());
}

test "generated groups round-trip" {
    var builder = capnp.MessageBuilder{ .allocator = std.testing.allocator };
    try builder.init();
    defer builder.deinit();

    var root = try builder.initRootStruct(groups.WithGroup.Builder, groups.WithGroup.builder_trait);
    var point = root.point();
    point.setX(10);
    point.setY(20);

    var union_builder = capnp.MessageBuilder{ .allocator = std.testing.allocator };
    try union_builder.init();
    defer union_builder.deinit();

    var union_root = try union_builder.initRootStruct(groups.WithUnionGroup.Builder, groups.WithUnionGroup.builder_trait);
    try std.testing.expectEqual(groups.WithUnionGroup.Tag.a, union_root.which());
    var a = union_root.a().?;
    a.setX(5);
    union_root.setB(7);
    try std.testing.expectEqual(groups.WithUnionGroup.Tag.b, union_root.which());
    try std.testing.expect(union_root.a() == null);

    var message = builder.toReader();
    const reader = try message.getRootStruct(groups.WithGroup.Reader, groups.WithGroup.reader_trait);
    try std.testing.expectEqual(@as(i32, 10), reader.point().x());
    try std.testing.expectEqual(@as(i32, 20), reader.point().y());

    var union_message = union_builder.toReader();
    const union_reader = try union_message.getRootStruct(groups.WithUnionGroup.Reader, groups.WithUnionGroup.reader_trait);
    try std.testing.expectEqual(groups.WithUnionGroup.Tag.b, union_reader.which());
    try std.testing.expectEqual(@as(?i32, 7), union_reader.b());
}
