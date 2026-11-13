//! Flat, ID-indexed slot storage with an embedded free list.
//!
//! IDs allocated by a connection occupy a dense range, so a plain `[]?*T`
//! indexed by ID is the natural lookup structure.  Without reuse its length
//! would grow with the total number of calls rather than the number of live
//! entries.  `IdSlots` keeps the same flat-array access but recycles released
//! IDs through a free list stored in the slots themselves.
//!
//! Some IDs cannot be recycled immediately because a message naming them may
//! still be in flight.  Those IDs are marked `.tombstone` and stay reserved
//! until the caller explicitly clears them.  A tombstone holds no value.

const std = @import("std");

pub fn IdSlots(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Slot = union(enum) {
            /// Never allocated, or currently being handed out by `allocId`.
            unused,
            /// Part of the embedded free list; value is the next free ID,
            /// with zero terminating the list.
            free: u32,
            /// The ID is live and points at `T`.
            live: *T,
            /// The ID is reserved until an outstanding message arrives.
            tombstone,
        };

        items: std.ArrayListUnmanaged(Slot) = .empty,
        free_head: u32 = 0,
        live_count: u32 = 0,
        tombstone_count: u32 = 0,

        pub fn count(self: *const Self) usize {
            return self.live_count;
        }

        pub fn tombstoneCount(self: *const Self) usize {
            return self.tombstone_count;
        }

        pub fn getPtr(self: *Self, id: u32) ?*T {
            if (id == 0 or id >= self.items.items.len) return null;
            return switch (self.items.items[id]) {
                .live => |ptr| ptr,
                else => null,
            };
        }

        /// Compatibility alias for map-like call sites.
        pub fn get(self: *Self, id: u32) ?*T {
            return self.getPtr(id);
        }

        pub fn contains(self: *const Self, id: u32) bool {
            if (id == 0 or id >= self.items.items.len) return false;
            return switch (self.items.items[id]) {
                .live => true,
                else => false,
            };
        }

        pub fn isTombstone(self: *const Self, id: u32) bool {
            if (id == 0 or id >= self.items.items.len) return false;
            return switch (self.items.items[id]) {
                .tombstone => true,
                else => false,
            };
        }

        fn growTo(self: *Self, allocator: std.mem.Allocator, id: u32) !void {
            const needed = @as(usize, id) + 1;
            if (needed <= self.items.items.len) return;

            const old_len = self.items.items.len;
            try self.items.resize(allocator, needed);
            for (self.items.items[old_len..]) |*slot| slot.* = .unused;
        }

        pub fn insert(self: *Self, allocator: std.mem.Allocator, id: u32, ptr: *T) !void {
            std.debug.assert(id != 0);
            try self.growTo(allocator, id);
            std.debug.assert(switch (self.items.items[id]) {
                .unused => true,
                else => false,
            });
            self.items.items[id] = .{ .live = ptr };
            self.live_count += 1;
        }

        fn pushFree(self: *Self, id: u32) void {
            self.items.items[id] = .{ .free = self.free_head };
            self.free_head = id;
        }

        /// Remove and return the value at `id`, recycling the ID immediately.
        pub fn release(self: *Self, id: u32) *T {
            std.debug.assert(id != 0 and id < self.items.items.len);
            const ptr = switch (self.items.items[id]) {
                .live => |value| value,
                else => unreachable,
            };
            self.pushFree(id);
            std.debug.assert(self.live_count > 0);
            self.live_count -= 1;
            return ptr;
        }

        /// Remove the value but keep the ID reserved.  The caller must later
        /// call `clearTombstone` when the outstanding message arrives.
        pub fn tombstone(self: *Self, id: u32) *T {
            std.debug.assert(id != 0 and id < self.items.items.len);
            const ptr = switch (self.items.items[id]) {
                .live => |value| value,
                else => unreachable,
            };
            self.items.items[id] = .tombstone;
            std.debug.assert(self.live_count > 0);
            self.live_count -= 1;
            self.tombstone_count += 1;
            return ptr;
        }

        pub fn clearTombstone(self: *Self, id: u32) void {
            std.debug.assert(id != 0 and id < self.items.items.len);
            std.debug.assert(switch (self.items.items[id]) {
                .tombstone => true,
                else => false,
            });
            self.tombstone_count -= 1;
            self.pushFree(id);
        }

        /// Allocate an ID.  Free IDs are preferred; otherwise `next_id` is
        /// advanced.  The returned ID's slot is `.unused` until the caller
        /// calls `insert`.
        pub fn allocId(
            self: *Self,
            allocator: std.mem.Allocator,
            next_id: *u32,
        ) !u32 {
            if (self.free_head != 0) {
                const id = self.free_head;
                self.free_head = switch (self.items.items[id]) {
                    .free => |next| next,
                    else => unreachable,
                };
                self.items.items[id] = .unused;
                return id;
            }

            // The free list is empty.  Normally `next_id` equals the
            // high-water mark.  Wrap-around and tombstones require a scan.
            var attempts: usize = 0;
            const slot_count = self.items.items.len;
            while (attempts <= slot_count) : (attempts += 1) {
                var id = next_id.*;
                if (id == 0) id = 1;
                next_id.* = if (id == std.math.maxInt(u32)) 1 else id + 1;

                // `next_id > items.len` means the counter wrapped before the
                // slot array did.  Restart the scan at the beginning rather
                // than trying to grow the array to a huge id.
                if (id > self.items.items.len) {
                    id = 1;
                    next_id.* = 2;
                }

                if (id >= self.items.items.len) {
                    try self.growTo(allocator, id);
                    return id;
                }

                switch (self.items.items[id]) {
                    .unused => return id,
                    .live, .tombstone => continue,
                    .free => unreachable,
                }
            }

            return error.IdSpaceExhausted;
        }

        pub fn firstLiveId(self: *const Self) ?u32 {
            for (self.items.items, 0..) |slot, index| {
                switch (slot) {
                    .live => return @intCast(index),
                    else => {},
                }
            }
            return null;
        }

        pub const ValueIterator = struct {
            slots: []const Slot,
            index: usize = 0,

            pub fn next(self: *ValueIterator) ?*T {
                while (self.index < self.slots.len) {
                    const slot = self.slots[self.index];
                    self.index += 1;
                    switch (slot) {
                        .live => |ptr| return ptr,
                        else => {},
                    }
                }
                return null;
            }
        };

        pub fn valueIterator(self: *const Self) ValueIterator {
            return .{ .slots = self.items.items };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
            self.* = .{};
        }
    };
}

const testing = std.testing;

const TestValue = struct {
    value: u32,
};

test "IdSlots allocates, releases, and reuses IDs" {
    var slots = IdSlots(TestValue){};
    defer slots.deinit(testing.allocator);

    var values: [4]TestValue = undefined;
    var next_id: u32 = 1;

    const first = try slots.allocId(testing.allocator, &next_id);
    try testing.expectEqual(@as(u32, 1), first);
    try slots.insert(testing.allocator, first, &values[0]);
    values[0].value = 10;

    const second = try slots.allocId(testing.allocator, &next_id);
    try testing.expectEqual(@as(u32, 2), second);
    try slots.insert(testing.allocator, second, &values[1]);
    values[1].value = 20;

    try testing.expectEqual(@as(usize, 2), slots.count());
    try testing.expectEqual(@as(u32, 20), slots.get(second).?.value);

    _ = slots.release(first);
    try testing.expectEqual(@as(usize, 1), slots.count());
    try testing.expect(slots.get(first) == null);

    const reused = try slots.allocId(testing.allocator, &next_id);
    try testing.expectEqual(first, reused);
    try slots.insert(testing.allocator, reused, &values[2]);
}

test "IdSlots tombstones are not reused until cleared" {
    var slots = IdSlots(TestValue){};
    defer slots.deinit(testing.allocator);

    var value = TestValue{ .value = 1 };
    var next_id: u32 = 1;

    const id = try slots.allocId(testing.allocator, &next_id);
    try slots.insert(testing.allocator, id, &value);
    _ = slots.tombstone(id);
    try testing.expect(slots.isTombstone(id));
    try testing.expectEqual(@as(usize, 1), slots.tombstoneCount());

    const next = try slots.allocId(testing.allocator, &next_id);
    try testing.expect(next != id);
    try slots.insert(testing.allocator, next, &value);

    slots.clearTombstone(id);
    try testing.expect(!slots.isTombstone(id));
    try testing.expectEqual(@as(usize, 0), slots.tombstoneCount());

    const reused = try slots.allocId(testing.allocator, &next_id);
    try testing.expectEqual(id, reused);
}

test "IdSlots wraps without returning zero and skips occupied slots" {
    var slots = IdSlots(TestValue){};
    defer slots.deinit(testing.allocator);

    var values: [3]TestValue = undefined;

    // Zero is not a valid ID; the first allocation starts at one.
    var next_id: u32 = 0;
    const first = try slots.allocId(testing.allocator, &next_id);
    try testing.expectEqual(@as(u32, 1), first);
    try slots.insert(testing.allocator, first, &values[0]);

    // Simulate wrap-around. The live slot must be skipped.
    next_id = 1;
    const second = try slots.allocId(testing.allocator, &next_id);
    try testing.expectEqual(@as(u32, 2), second);
    try slots.insert(testing.allocator, second, &values[1]);

    next_id = 0;
    const third = try slots.allocId(testing.allocator, &next_id);
    try testing.expectEqual(@as(u32, 3), third);
    try slots.insert(testing.allocator, third, &values[2]);

    // A wrapped `next_id` must not grow the slot array to the old u32 id.
    next_id = std.math.maxInt(u32);
    const after_wrap = try slots.allocId(testing.allocator, &next_id);
    try testing.expectEqual(@as(u32, 4), after_wrap);

    try testing.expectEqual(@as(usize, 5), slots.items.items.len);
    try testing.expectEqual(@as(usize, 3), slots.count());
}

test "IdSlots value iterator visits live values only" {
    var slots = IdSlots(TestValue){};
    defer slots.deinit(testing.allocator);

    var values = [_]TestValue{
        .{ .value = 1 },
        .{ .value = 2 },
        .{ .value = 3 },
    };
    var next_id: u32 = 1;

    const first = try slots.allocId(testing.allocator, &next_id);
    try slots.insert(testing.allocator, first, &values[0]);
    const second = try slots.allocId(testing.allocator, &next_id);
    try slots.insert(testing.allocator, second, &values[1]);
    const third = try slots.allocId(testing.allocator, &next_id);
    try slots.insert(testing.allocator, third, &values[2]);

    _ = slots.release(second);

    var iterator = slots.valueIterator();
    var sum: u32 = 0;
    while (iterator.next()) |value| sum += value.value;
    try testing.expectEqual(@as(u32, 4), sum);
}
