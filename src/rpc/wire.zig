//! Stateless builders for the small RPC control messages.
//!
//! These functions only need an allocator and plain values; they do not touch
//! connection tables. The caller owns the returned bytes and sends them.

const std = @import("std");
const capnp = @import("capnp");
const rpc = @import("generated/rpc.zig");

const message_initial_segment_bytes: u32 = 1024;

pub fn buildFinish(
    allocator: std.mem.Allocator,
    question_id: u32,
    release_result_caps: bool,
) ![]u8 {
    var message = capnp.MessageBuilder{ .allocator = allocator, .next_segment_bytes = message_initial_segment_bytes };
    try message.init();
    defer message.deinit();

    var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
    var finish = try root.setFinish();
    finish.setQuestionId(question_id);
    finish.setReleaseResultCaps(release_result_caps);

    return try serialize(allocator, message);
}

pub fn buildAbort(
    allocator: std.mem.Allocator,
    reason: [:0]const u8,
    abort_type: rpc.Exception.Type,
) ![]u8 {
    var message = capnp.MessageBuilder{ .allocator = allocator, .next_segment_bytes = message_initial_segment_bytes };
    try message.init();
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
    var message = capnp.MessageBuilder{ .allocator = allocator, .next_segment_bytes = message_initial_segment_bytes };
    try message.init();
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

pub fn buildRelease(
    allocator: std.mem.Allocator,
    export_id: u32,
    reference_count: u32,
) ![]u8 {
    var message = capnp.MessageBuilder{ .allocator = allocator, .next_segment_bytes = message_initial_segment_bytes };
    try message.init();
    defer message.deinit();

    var root = try message.initRootStruct(rpc.Message.Builder, rpc.Message.builder_trait);
    var release = try root.setRelease();
    release.setId(export_id);
    release.setReferenceCount(reference_count);

    return try serialize(allocator, message);
}

fn serialize(allocator: std.mem.Allocator, message: capnp.MessageBuilder) ![]u8 {
    const size = try message.serializedSize();
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    _ = try message.writeToBuffer(bytes);
    return bytes;
}
