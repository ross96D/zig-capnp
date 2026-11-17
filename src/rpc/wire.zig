//! Stateless builders for the small RPC control messages.
//!
//! Messages with a fixed shape can be built directly into caller-provided
//! storage. Variable-length messages (abort / exception) use a
//! `GrowableMessage`, which owns its segments.

const std = @import("std");
const capnp = @import("capnp");
const rpc = @import("generated/rpc.zig");

const message_initial_segment_bytes: u32 = 1024;
const header_bytes = capnp.frameHeaderSize(1);

/// Exact framed sizes of the fixed-shape control messages.
pub const finish_size = capnp.framedSize(&[_]capnp.Size{
    capnp.Size.ofStruct(rpc.Message.builder_trait),
    capnp.Size.ofStruct(rpc.Finish.builder_trait),
});
pub const release_size = capnp.framedSize(&[_]capnp.Size{
    capnp.Size.ofStruct(rpc.Message.builder_trait),
    capnp.Size.ofStruct(rpc.Release.builder_trait),
});
pub const bootstrap_size = capnp.framedSize(&[_]capnp.Size{
    capnp.Size.ofStruct(rpc.Message.builder_trait),
    capnp.Size.ofStruct(rpc.Bootstrap.builder_trait),
});
pub const disembargo_size = capnp.framedSize(&[_]capnp.Size{
    capnp.Size.ofStruct(rpc.Message.builder_trait),
    capnp.Size.ofStruct(rpc.Disembargo.builder_trait),
    capnp.Size.ofStruct(rpc.MessageTarget.builder_trait),
});

pub fn buildFinishInto(
    frame: []u8,
    question_id: u32,
    release_result_caps: bool,
) !capnp.MessageBuilder {
    if (frame.len < finish_size) return error.NoSpaceLeft;

    var message = capnp.MessageBuilder.initBuffer(frame);

    var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
    var finish = try root.setFinish();
    finish.setQuestionId(question_id);
    finish.setReleaseResultCaps(release_result_caps);

    return message;
}

pub fn buildReleaseInto(
    frame: []u8,
    export_id: u32,
    reference_count: u32,
) ![]u8 {
    if (frame.len < release_size) return error.NoSpaceLeft;

    var message = capnp.MessageBuilder.initBuffer(frame[header_bytes..]);

    var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
    var release = try root.setRelease();
    release.setId(export_id);
    release.setReferenceCount(reference_count);

    return finishFrame(frame, &message);
}

pub fn buildDisembargoInto(frame: []u8, export_id: u32, embargo_id: u32) ![]u8 {
    if (frame.len < disembargo_size) return error.NoSpaceLeft;

    var message = capnp.MessageBuilder.initBuffer(frame[header_bytes..]);

    var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
    var disembargo = try root.setDisembargo();
    var target = try disembargo.target();
    target.setImportedCap(export_id);
    disembargo.context().setSenderLoopback(embargo_id);

    return finishFrame(frame, &message);
}

pub fn buildBootstrapInto(frame: []u8, question_id: u32) ![]u8 {
    if (frame.len < bootstrap_size) return error.NoSpaceLeft;

    var message = capnp.MessageBuilder.initBuffer(frame[header_bytes..]);

    var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
    var bootstrap = try root.setBootstrap();
    bootstrap.setQuestionId(question_id);

    return finishFrame(frame, &message);
}

pub fn buildFinish(
    allocator: std.mem.Allocator,
    question_id: u32,
    release_result_caps: bool,
) ![]u8 {
    const bytes = try allocator.alloc(u8, finish_size);
    errdefer allocator.free(bytes);
    _ = try buildFinishInto(bytes, question_id, release_result_caps);
    return bytes;
}

pub fn buildRelease(
    allocator: std.mem.Allocator,
    export_id: u32,
    reference_count: u32,
) ![]u8 {
    const bytes = try allocator.alloc(u8, release_size);
    errdefer allocator.free(bytes);
    _ = try buildReleaseInto(bytes, export_id, reference_count);
    return bytes;
}

pub fn buildAbort(
    allocator: std.mem.Allocator,
    reason: [:0]const u8,
    abort_type: rpc.Exception.Type,
) ![]u8 {
    var message = try capnp.GrowableMessage.init(allocator, message_initial_segment_bytes);
    defer message.deinit();

    var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
    var exception = try root.setAbort();
    try exception.setReason(reason);
    exception.setType(abort_type);

    return try serialize(allocator, message);
}

pub fn buildException(
    allocator: std.mem.Allocator,
    answer_id: u32,
    reason: [:0]const u8,
    release_param_caps: bool,
) ![]u8 {
    var message = try capnp.GrowableMessage.init(allocator, message_initial_segment_bytes);
    defer message.deinit();

    var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
    var return_ = try root.setReturn();
    return_.setAnswerId(answer_id);
    return_.setReleaseParamCaps(release_param_caps);

    var exception = try return_.setException();
    try exception.setReason(reason);
    exception.setType(.failed);

    return try serialize(allocator, message);
}

fn finishFrame(frame: []u8, message: *const capnp.MessageBuilder) ![]u8 {
    const header = try message.writeHeader(frame[0..header_bytes]);
    return frame[0 .. header.len + message.segmentSlices()[0].len];
}

fn serialize(allocator: std.mem.Allocator, message: anytype) ![]u8 {
    const size = message.serializedSize();
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    _ = try message.writeToBuffer(bytes);
    return bytes;
}

const _Root = @This();

test "compiles" {
    std.testing.refAllDecls(_Root);
}
