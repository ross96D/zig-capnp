const std = @import("std");

const wire = @import("../wire.zig");
const transport = @import("transport.zig");

const Transport = transport.Transport;
const Pipe = transport.testing.Pipe;
const MessageParts = wire.MessageParts;
const testing = std.testing;

/// One segment of one word: a four byte segment count, a four byte segment
/// size, and an eight byte body.
const one_segment_frame = "\x00\x00\x00\x00" ++ "\x01\x00\x00\x00" ++ "abcdefgh";

/// Two segments of one word each; the header is padded to eight bytes.
const two_segment_frame = "\x01\x00\x00\x00" ++
    "\x01\x00\x00\x00" ++
    "\x01\x00\x00\x00" ++
    "\x00\x00\x00\x00" ++
    "12345678" ++
    "ABCDEFGH";

test "pipe queues until flush and preserves frame boundaries" {
    const pipe = try Pipe.init(testing.allocator, .{});
    defer pipe.deinit();

    const a = pipe.endpoint(.a);
    const b = pipe.endpoint(.b);

    try a.send(.{ .header = one_segment_frame });
    try a.send(.{ .header = two_segment_frame });

    // Nothing reaches the peer until flush.
    try testing.expectEqual(@as(usize, 0), pipe.inboundBytes(.b));
    try testing.expectEqual(
        one_segment_frame.len + two_segment_frame.len,
        pipe.pendingBytes(.a),
    );

    // Queued bytes need writability; the peer is still reachable for reads.
    try testing.expectEqual(Transport.Interest.read_write, a.interest());
    try testing.expectEqual(Transport.Interest.read, b.interest());

    try a.flush();
    try testing.expectEqual(@as(usize, 0), pipe.pendingBytes(.a));
    try testing.expectEqual(
        one_segment_frame.len + two_segment_frame.len,
        pipe.inboundBytes(.b),
    );
    try testing.expectEqual(Transport.Interest.read, a.interest());

    const first = (try b.receive(testing.allocator)).?;
    defer testing.allocator.free(first);
    try testing.expectEqualSlices(u8, one_segment_frame, first);

    const second = (try b.receive(testing.allocator)).?;
    defer testing.allocator.free(second);
    try testing.expectEqualSlices(u8, two_segment_frame, second);

    // A drained transport has no frame to report, and that is not EOF.
    try testing.expect((try b.receive(testing.allocator)) == null);
}

test "pipe interest reports reads while a frame is buffered" {
    const pipe = try Pipe.init(testing.allocator, .{});
    defer pipe.deinit();

    const a = pipe.endpoint(.a);
    const b = pipe.endpoint(.b);

    try a.send(.{ .header = one_segment_frame });
    try a.flush();

    // The frame is already buffered, so a poll loop on `read` cannot stall.
    try testing.expectEqual(Transport.Interest.read, b.interest());

    const frame = (try b.receive(testing.allocator)).?;
    defer testing.allocator.free(frame);
    try testing.expectEqualSlices(u8, one_segment_frame, frame);

    // Still open, so the loop keeps waiting for more inbound messages.
    try testing.expectEqual(Transport.Interest.read, b.interest());
    try testing.expect((try b.receive(testing.allocator)) == null);
}

test "pipe flush moves bytes and may leave a partial frame queued" {
    const pipe = try Pipe.init(testing.allocator, .{ .flush_budget = 10 });
    defer pipe.deinit();

    const a = pipe.endpoint(.a);
    const b = pipe.endpoint(.b);

    try a.send(.{ .header = one_segment_frame });

    try a.flush();
    try testing.expectEqual(one_segment_frame.len - 10, pipe.pendingBytes(.a));
    // Half a frame is not a frame.
    try testing.expect((try b.receive(testing.allocator)) == null);
    try testing.expectEqual(Transport.Interest.read_write, a.interest());

    try a.flush();
    try testing.expectEqual(@as(usize, 0), pipe.pendingBytes(.a));
    try testing.expectEqual(Transport.Interest.read, a.interest());

    const frame = (try b.receive(testing.allocator)).?;
    defer testing.allocator.free(frame);
    try testing.expectEqualSlices(u8, one_segment_frame, frame);
}

test "pipe delivers buffered frames before reporting eof" {
    const pipe = try Pipe.init(testing.allocator, .{});
    defer pipe.deinit();

    const a = pipe.endpoint(.a);
    const b = pipe.endpoint(.b);

    try a.send(.{ .header = one_segment_frame });
    try a.send(.{ .header = two_segment_frame });
    try a.flush();

    // Abrupt close drops the local endpoint's unflushed bytes, but frames that
    // already reached the peer stay readable.
    try a.send(.{ .header = one_segment_frame });
    a.close();

    try testing.expect(pipe.isClosed(.a));
    try testing.expectEqual(Transport.Interest.none, a.interest());
    try testing.expectError(error.Closed, a.send(.{ .header = one_segment_frame }));
    try testing.expectError(error.Closed, a.flush());

    // A peer that is gone cannot accept new frames either.
    try testing.expectError(error.Closed, b.send(.{ .header = one_segment_frame }));
    try testing.expectError(error.Closed, b.flush());

    const first = (try b.receive(testing.allocator)).?;
    defer testing.allocator.free(first);
    try testing.expectEqualSlices(u8, one_segment_frame, first);

    const second = (try b.receive(testing.allocator)).?;
    defer testing.allocator.free(second);
    try testing.expectEqualSlices(u8, two_segment_frame, second);

    // The third frame was never flushed, so EOF is all that is left.
    try testing.expectError(error.Closed, b.receive(testing.allocator));
    try testing.expectEqual(Transport.Interest.none, b.interest());
}

test "pipe shutdown flushes queued frames before closing" {
    const pipe = try Pipe.init(testing.allocator, .{});
    defer pipe.deinit();

    const a = pipe.endpoint(.a);
    const b = pipe.endpoint(.b);

    try a.send(.{ .header = one_segment_frame });
    a.shutdown();

    // This is what lets an Abort or a final Return reach the peer.
    const frame = (try b.receive(testing.allocator)).?;
    defer testing.allocator.free(frame);
    try testing.expectEqualSlices(u8, one_segment_frame, frame);

    try testing.expectError(error.Closed, b.receive(testing.allocator));

    try testing.expectError(error.Closed, a.send(.{ .header = one_segment_frame }));
    try testing.expectError(error.Closed, a.flush());
    try testing.expectEqual(Transport.Interest.none, a.interest());
}

test "pipe rejects malformed frames" {
    // A segment count above the protocol limit.
    try expectReceiveError(error.ProtocolError, "\xff\xff\xff\xff", .{});
    // A single segment claiming 2^32 - 1 words.
    try expectReceiveError(error.ProtocolError, "\x00\x00\x00\x00" ++ "\xff\xff\xff\xff", .{});
    // A frame whose declared segments exceed the message limit. `send` only
    // checks the bytes it is given, so the framing check belongs to `receive`.
    try expectReceiveError(
        error.ProtocolError,
        "\x00\x00\x00\x00" ++ "\x00\x00\x00\x10",
        .{ .max_message_bytes = 64 },
    );
}

test "pipe enforces the outbound message limit" {
    const pipe = try Pipe.init(testing.allocator, .{ .max_message_bytes = 8 });
    defer pipe.deinit();

    try testing.expectError(
        error.MessageTooLarge,
        pipe.endpoint(.a).send(.{ .header = one_segment_frame }),
    );
    try testing.expectEqual(@as(usize, 0), pipe.pendingBytes(.a));
}

test "pipe wakes the peer when bytes arrive" {
    const pipe = try Pipe.init(testing.allocator, .{});
    defer pipe.deinit();

    const a = pipe.endpoint(.a);
    const b = pipe.endpoint(.b);

    var wakes: usize = 0;
    const Counter = struct {
        fn wake(context: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(context));
            count.* += 1;
        }
    };
    b.setWaker(.{ .context = &wakes, .wake = Counter.wake });

    // `send` only queues, so the peer has nothing to wake up for.
    try a.send(.{ .header = one_segment_frame });
    try testing.expectEqual(@as(usize, 0), wakes);

    try a.flush();
    try testing.expectEqual(@as(usize, 1), wakes);

    // Nothing left to move: no wakeup.
    try a.flush();
    try testing.expectEqual(@as(usize, 1), wakes);

    // EOF wakes the loop too, so that it can observe `Closed`.
    a.close();
    try testing.expectEqual(@as(usize, 2), wakes);

    b.setWaker(null);
}

test "pipe has no file descriptor" {
    const pipe = try Pipe.init(testing.allocator, .{});
    defer pipe.deinit();

    const a = pipe.endpoint(.a);
    // The interface must not require a descriptor; the waker is enough.
    try testing.expectEqual(@as(?std.posix.fd_t, null), a.fd());
    // Optional hooks are safe to call on transports that do not need them.
    a.setWaker(null);
}

test "transport interface declares" {
    std.testing.refAllDecls(Transport);
    std.testing.refAllDecls(Pipe);
    std.testing.refAllDecls(MessageParts);
}

fn expectReceiveError(
    expected: Transport.Error,
    header: []const u8,
    options: Pipe.Options,
) !void {
    const pipe = try Pipe.init(testing.allocator, options);
    defer pipe.deinit();

    const a = pipe.endpoint(.a);
    try a.send(.{ .header = header });
    try a.flush();

    try testing.expectError(expected, pipe.endpoint(.b).receive(testing.allocator));
}
