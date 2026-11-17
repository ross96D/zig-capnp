const std = @import("std");
const capnp = @import("capnp");
const capnp_rpc = @import("capnp_rpc");
const capnpc = @import("capnpc");
const codegen = @import("codegen");

var stateless_server_context: u8 = 0;

const simple = codegen.simple;
const lists = codegen.lists;
const composite = codegen.composite;
const unions = codegen.unions;
const defaults = codegen.defaults;
const bits_floats = codegen.bits_floats;
const features = codegen.features;
const groups = codegen.groups;
const annotations = codegen.annotations;
const interfaces = codegen.interfaces;
const generics = codegen.generics;
const void_setters = codegen.void_setters;

fn expectMessageBytes(actual: []const u8, fixture_path: []const u8) !void {
    const expected = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        fixture_path,
        std.testing.allocator,
        .limited(64 * 1024 * 1024),
    );
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "generated message bytes match capnp eval" {
    try expectMessageBytes(simple.date20230714Message(), "capnp-tests/01_simple_struct_date_20230714.bin");
    try expectMessageBytes(simple.datem20230714Message(), "capnp-tests/01_simple_struct_datem_20230714.bin");
    try expectMessageBytes(lists.listTestMessage(), "capnp-tests/02_simple_lists.bin");
    try expectMessageBytes(composite.listTestMessage(), "capnp-tests/03_composite_lists.bin");
    try expectMessageBytes(unions.test1Message(), "capnp-tests/04_unions.bin");
    try expectMessageBytes(defaults.testMessage(), "capnp-tests/05_default_values.bin");
    try expectMessageBytes(bits_floats.testMessage(), "capnp-tests/07_bits_and_floats.bin");
    try expectMessageBytes(features.testMessage(), "capnp-tests/09_codegen_features.bin");
    try expectMessageBytes(groups.pointTestMessage(), "capnp-tests/10_groups_point.bin");
    try expectMessageBytes(groups.unionTestMessage(), "capnp-tests/10_groups_union.bin");
}

test "generated modules compile" {
    std.testing.refAllDecls(simple);
    std.testing.refAllDecls(lists);
    std.testing.refAllDecls(composite);
    std.testing.refAllDecls(unions);
    std.testing.refAllDecls(defaults);
    std.testing.refAllDecls(features);
    std.testing.refAllDecls(groups);
    std.testing.refAllDecls(annotations);
    std.testing.refAllDecls(interfaces);
    std.testing.refAllDecls(generics);
    std.testing.refAllDecls(void_setters);
}

test "generated primitive list round-trip" {
    var builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
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
    var builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
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
    var builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer builder.deinit();

    var root = try builder.initRootStruct(unions.UnionTestList.Builder, unions.UnionTestList.builder_trait);
    var list = try root.unionTests();
    try list.init(3);

    var first = list.get(0);
    first.setInt32(0);

    var second = list.get(1);
    second.setVoid();

    var third = list.get(2);
    third.setInt32(2);

    var message = builder.toReader();
    const reader = try message.getRootStruct(unions.UnionTestList.Reader, unions.UnionTestList.reader_trait);
    const got = try reader.unionTests();
    try std.testing.expectEqual(unions.UnionTest.Tag.int32, got.get(0).which());
    try std.testing.expectEqual(@as(?i32, 0), got.get(0).int32());
    try std.testing.expectEqual(unions.UnionTest.Tag.void, got.get(1).which());
    try std.testing.expectEqual(@as(?i32, null), got.get(1).int32());
    try std.testing.expectEqual(@as(?i32, 2), got.get(2).int32());
}

test "generated defaults round-trip and fixture" {
    var builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
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
    var builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
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

test "generated AnyPointer round-trip" {
    {
        var builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
        defer builder.deinit();

        var root = try builder.initRootStruct(features.Features.Builder, features.Features.builder_trait);
        try root.ptr().setText("any-pointer");

        var message = builder.toReader();
        const reader = try message.getRootStruct(features.Features.Reader, features.Features.reader_trait);
        try std.testing.expectEqualStrings("any-pointer", try (try reader.ptr()).asText());
    }

    {
        var builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
        defer builder.deinit();

        var root = try builder.initRootStruct(features.Features.Builder, features.Features.builder_trait);
        var nested = try root.ptr().initStruct(features.Features.Builder, features.Features.builder_trait);
        try nested.setName("nested");

        var message = builder.toReader();
        const reader = try message.getRootStruct(features.Features.Reader, features.Features.reader_trait);
        const nested_reader = try (try reader.ptr()).asStruct(features.Features.Reader, features.Features.reader_trait);
        try std.testing.expectEqualStrings("nested", try nested_reader.name());
    }

    {
        var builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
        defer builder.deinit();

        var root = try builder.initRootStruct(features.Features.Builder, features.Features.builder_trait);
        var list = root.ptr().initList(u16);
        try list.init(2);
        list.set(0, 7);
        list.set(1, 9);

        var message = builder.toReader();
        const reader = try message.getRootStruct(features.Features.Reader, features.Features.reader_trait);
        const got = try (try reader.ptr()).asList(u16);
        try std.testing.expectEqual(@as(u29, 2), got.length);
        try std.testing.expectEqual(@as(u16, 7), got.get(0));
        try std.testing.expectEqual(@as(u16, 9), got.get(1));
    }

    {
        var builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
        defer builder.deinit();

        var root = try builder.initRootStruct(features.Features.Builder, features.Features.builder_trait);
        var list = root.ptr().initCompositeList(features.Features.Builder, features.Features.builder_trait);
        try list.init(2);

        var first = list.get(0);
        try first.setName("first");
        var second = list.get(1);
        try second.setName("second");

        var message = builder.toReader();
        const reader = try message.getRootStruct(features.Features.Reader, features.Features.reader_trait);
        const got = try (try reader.ptr()).asCompositeList(features.Features.Reader, features.Features.reader_trait);
        try std.testing.expectEqual(@as(u29, 2), got.length);
        try std.testing.expectEqualStrings("first", try got.get(0).name());
        try std.testing.expectEqualStrings("second", try got.get(1).name());
    }
}

test "generated interface fields and pointer lists round-trip" {
    var builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer builder.deinit();

    var root = try builder.initRootStruct(interfaces.InterfaceHolder.Builder, interfaces.InterfaceHolder.builder_trait);
    try root.calculator().setText("calculator");

    var list = try root.calculators();
    try list.init(2);
    try list.get(0).setText("first");
    try list.get(1).setText("second");

    var message = builder.toReader();
    const reader = try message.getRootStruct(interfaces.InterfaceHolder.Reader, interfaces.InterfaceHolder.reader_trait);
    try std.testing.expectEqualStrings("calculator", try (try reader.calculator()).asText());

    const got = try reader.calculators();
    try std.testing.expectEqual(@as(u29, 2), got.length);
    try std.testing.expectEqualStrings("first", try (try got.get(0)).asText());
    try std.testing.expectEqualStrings("second", try (try got.get(1)).asText());
}

test "generated generic struct round-trip" {
    var builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer builder.deinit();

    var root = try builder.initRootStruct(generics.Holder.Builder, generics.Holder.builder_trait);
    var box = try root.itemBox();
    var item = try box.value();
    item.setN(42);

    var message = builder.toReader();
    const reader = try message.getRootStruct(generics.Holder.Reader, generics.Holder.reader_trait);
    const item_reader = try (try reader.itemBox()).value();
    try std.testing.expectEqual(@as(i32, 42), item_reader.n());
}

const TypedValue = struct {
    fn eval(
        _: *anyopaque,
        _: interfaces.Calculator.Value.EvalParams.Reader,
        results: interfaces.Calculator.Value.EvalResults.Builder,
        _: capnp_rpc.Call,
    ) anyerror!void {
        results.setValue(42);
    }
};

const TypedCalculator = struct {
    fn add(
        context: *anyopaque,
        _: interfaces.Calculator.AddParams.Reader,
        results: interfaces.Calculator.AddResults.Builder,
        call: capnp_rpc.Call,
    ) anyerror!void {
        const value: *interfaces.Calculator.Value.Server = @ptrCast(@alignCast(context));
        const index = try call.addLocalResultCapability(value.localCapability());
        results.setSum().setCapability(index);
    }

    fn reset(
        _: *anyopaque,
        _: interfaces.Calculator.ResetParams.Reader,
        _: interfaces.Calculator.ResetResults.Builder,
        _: capnp_rpc.Call,
    ) anyerror!void {}
};

test "generated groups round-trip" {
    var builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer builder.deinit();

    var root = try builder.initRootStruct(groups.WithGroup.Builder, groups.WithGroup.builder_trait);
    var point = root.point();
    point.setX(10);
    point.setY(20);

    var union_builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
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

test "generated non-union void setters compile and work" {
    var builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer builder.deinit();

    var root = try builder.initRootStruct(void_setters.VoidFields.Builder, void_setters.VoidFields.builder_trait);

    // A non-union Void field has no discriminant to write, which previously
    // left the generated setter's `self` parameter unused and failed to compile.
    root.setNothing();
    root.setFlag(true);
    try std.testing.expect(root.flag());

    root.setValue(7);
    try std.testing.expectEqual(void_setters.VoidFields.Tag.value, root.which());
    try std.testing.expectEqual(@as(?i32, 7), root.value());

    root.setChoice();
    try std.testing.expectEqual(void_setters.VoidFields.Tag.choice, root.which());
    try std.testing.expect(root.choice() != null);
}

test "generated struct copyFrom copies all field kinds" {
    var src_builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer src_builder.deinit();

    var src = try src_builder.initRootStruct(features.Features.Builder, features.Features.builder_trait);
    try src.setName("root");
    try src.setBlob(&[_]u8{ 1, 2, 3, 4 });
    src.setColor(.blue);
    src.setEnabled(true);
    src.setRatio(1.5);
    src.setOffset(-42);

    var colors = try src.colors();
    try colors.init(3);
    colors.set(0, .red);
    colors.set(1, .green);
    colors.set(2, .blue);

    var child = try src.setChild();
    try child.setName("child");
    child.setOffset(7);

    try src.ptr().setText("payload");

    var src_message = src_builder.toReader();
    const src_reader = try src_message.getRootStruct(features.Features.Reader, features.Features.reader_trait);

    var dst_builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer dst_builder.deinit();

    var dst = try dst_builder.initRootStruct(features.Features.Builder, features.Features.builder_trait);
    dst.copyFrom(src_reader);

    var dst_message = dst_builder.toReader();
    const got = try dst_message.getRootStruct(features.Features.Reader, features.Features.reader_trait);

    try std.testing.expectEqualStrings("root", try got.name());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, try got.blob());
    try std.testing.expectEqual(features.Color.blue, got.color());
    try std.testing.expectEqual(src_reader.enabled(), got.enabled());
    try std.testing.expectEqual(src_reader.ratio(), got.ratio());
    try std.testing.expectEqual(@as(i32, -42), got.offset());

    const got_colors = try got.colors();
    try std.testing.expectEqual(@as(u29, 3), got_colors.length);
    try std.testing.expectEqual(features.Color.red, got_colors.get(0));
    try std.testing.expectEqual(features.Color.green, got_colors.get(1));
    try std.testing.expectEqual(features.Color.blue, got_colors.get(2));

    const got_child = try got.child();
    try std.testing.expectEqualStrings("child", try got_child.name());
    try std.testing.expectEqual(@as(i32, 7), got_child.offset());

    const got_ptr = try got.ptr();
    try std.testing.expectEqualStrings("payload", try got_ptr.asText());
}

test "generated primitive list copyFrom" {
    var src_builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer src_builder.deinit();

    var src = try src_builder.initRootStruct(features.Features.Builder, features.Features.builder_trait);
    var colors = try src.colors();
    try colors.init(4);
    colors.set(0, .red);
    colors.set(1, .green);
    colors.set(2, .blue);
    colors.set(3, .red);

    var src_message = src_builder.toReader();
    const src_reader = try src_message.getRootStruct(features.Features.Reader, features.Features.reader_trait);

    var dst_builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer dst_builder.deinit();

    var dst = try dst_builder.initRootStruct(features.Features.Builder, features.Features.builder_trait);
    var dst_colors = try dst.colors();
    try dst_colors.copyFrom(try src_reader.colors());

    var dst_message = dst_builder.toReader();
    const got = try dst_message.getRootStruct(features.Features.Reader, features.Features.reader_trait);
    const got_colors = try got.colors();

    try std.testing.expectEqual(@as(u29, 4), got_colors.length);
    try std.testing.expectEqual(features.Color.red, got_colors.get(0));
    try std.testing.expectEqual(features.Color.green, got_colors.get(1));
    try std.testing.expectEqual(features.Color.blue, got_colors.get(2));
    try std.testing.expectEqual(features.Color.red, got_colors.get(3));
}

test "generated composite list copyFrom" {
    var src_builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer src_builder.deinit();

    var src = try src_builder.initRootStruct(composite.Lists.Builder, composite.Lists.builder_trait);
    var dates = try src.dates();
    try dates.init(2);

    var first = dates.get(0);
    first.setYear(2023);
    first.setMonth(7);
    first.setDay(14);

    var second = dates.get(1);
    second.setYear(2022);
    second.setMonth(12);
    second.setDay(31);

    var src_message = src_builder.toReader();
    const src_reader = try src_message.getRootStruct(composite.Lists.Reader, composite.Lists.reader_trait);

    // Copy the whole struct (exercises the generic pointer/list copy path).
    var whole_builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer whole_builder.deinit();

    var whole = try whole_builder.initRootStruct(composite.Lists.Builder, composite.Lists.builder_trait);
    whole.copyFrom(src_reader);

    var whole_message = whole_builder.toReader();
    const whole_reader = try whole_message.getRootStruct(composite.Lists.Reader, composite.Lists.reader_trait);
    const whole_dates = try whole_reader.dates();
    try std.testing.expectEqual(@as(u29, 2), whole_dates.length);
    try std.testing.expectEqual(@as(i16, 2023), whole_dates.get(0).year());
    try std.testing.expectEqual(@as(u8, 7), whole_dates.get(0).month());
    try std.testing.expectEqual(@as(i16, 2022), whole_dates.get(1).year());

    // Copy just the composite list through CompositeListBuilder.copyFrom.
    var list_builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer list_builder.deinit();

    var list_root = try list_builder.initRootStruct(composite.Lists.Builder, composite.Lists.builder_trait);
    var list_dates = try list_root.dates();
    try list_dates.copyFrom(try src_reader.dates());

    var list_message = list_builder.toReader();
    const list_reader = try list_message.getRootStruct(composite.Lists.Reader, composite.Lists.reader_trait);
    const got_dates = try list_reader.dates();
    try std.testing.expectEqual(@as(u29, 2), got_dates.length);
    try std.testing.expectEqual(@as(u8, 31), got_dates.get(1).day());
}

test "generated union and group copyFrom" {
    var union_builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer union_builder.deinit();

    var union_root = try union_builder.initRootStruct(unions.UnionTestList.Builder, unions.UnionTestList.builder_trait);
    var union_list = try union_root.unionTests();
    try union_list.init(2);
    union_list.get(0).setInt32(123);
    union_list.get(1).setVoid();

    var union_message = union_builder.toReader();
    const union_reader = try union_message.getRootStruct(unions.UnionTestList.Reader, unions.UnionTestList.reader_trait);

    var union_dst_builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer union_dst_builder.deinit();

    var union_dst = try union_dst_builder.initRootStruct(unions.UnionTestList.Builder, unions.UnionTestList.builder_trait);
    union_dst.copyFrom(union_reader);

    var union_dst_message = union_dst_builder.toReader();
    const union_got = try union_dst_message.getRootStruct(unions.UnionTestList.Reader, unions.UnionTestList.reader_trait);
    const got_list = try union_got.unionTests();
    try std.testing.expectEqual(@as(u29, 2), got_list.length);
    try std.testing.expectEqual(unions.UnionTest.Tag.int32, got_list.get(0).which());
    try std.testing.expectEqual(@as(?i32, 123), got_list.get(0).int32());
    try std.testing.expectEqual(unions.UnionTest.Tag.void, got_list.get(1).which());

    const group_reader = groups.pointTest();

    var group_dst_builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer group_dst_builder.deinit();

    var group_dst = try group_dst_builder.initRootStruct(groups.WithGroup.Builder, groups.WithGroup.builder_trait);
    group_dst.copyFrom(group_reader);

    var group_dst_message = group_dst_builder.toReader();
    const group_got = try group_dst_message.getRootStruct(groups.WithGroup.Reader, groups.WithGroup.reader_trait);
    try std.testing.expectEqual(@as(i32, 10), group_got.point().x());
    try std.testing.expectEqual(@as(i32, 20), group_got.point().y());
}

test "generated builder copyFrom accepts asReader" {
    var src_builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer src_builder.deinit();

    var src = try src_builder.initRootStruct(features.Features.Builder, features.Features.builder_trait);
    try src.setName("from-builder");
    src.setOffset(99);

    var dst_builder = try capnp.GrowableMessage.init(std.testing.allocator, 65536);
    defer dst_builder.deinit();

    var dst = try dst_builder.initRootStruct(features.Features.Builder, features.Features.builder_trait);
    dst.copyFrom(src.asReader());

    var dst_message = dst_builder.toReader();
    const got = try dst_message.getRootStruct(features.Features.Reader, features.Features.reader_trait);
    try std.testing.expectEqualStrings("from-builder", try got.name());
    try std.testing.expectEqual(@as(i32, 99), got.offset());
}
