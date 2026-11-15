//! Flat, ID-indexed slot storage with an embedded free list.
//!
//! IDs allocated by a connection occupy a dense range, so a plain `[]Slot`
//! indexed by ID is the natural lookup structure.  Without reuse its length
//! would grow with the total number of calls (or exports) rather than the
//! number of live entries.  `SlotMap` keeps the same flat-array access but
//! recycles released IDs through a free list stored in the slots themselves.
//!
//! Some IDs cannot be recycled immediately because a message naming them may
//! still be in flight.  Those IDs are marked `.tombstone` and stay reserved
//! until the caller explicitly clears them.  A tombstone holds no value.
//!
//! ID 0 is reserved as the null ID and is never handed out, which lets it
//! double as the free-list terminator.  IDs are wire-visible in the RPC
//! protocol, so they are `u32` rather than `usize`.

const std = @import("std");

pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Slot identifier.
        pub const Id = u32;

        /// Reserved ID; never returned by `add`.
        pub const null_id: Id = 0;

        pub const Slot = union(enum) {
            /// Never allocated, or a hole left by a sparse allocation.
            unused,
            /// Part of the embedded free list; value is the next free ID,
            /// with `null_id` terminating the list.
            free: Id,
            /// The ID is live and points at `T`.
            live: T,
            /// The ID is reserved until an outstanding message arrives.
            tombstone,
        };

        /// One item produced by `iterator`.
        pub const Entry = struct {
            id: Id,
            value: *const T,
        };

        items: std.ArrayListUnmanaged(Slot) = .empty,
        /// Cursor for fresh IDs.  Never `null_id`.
        next_id: Id = 1,
        /// Head of the embedded free list, or `null_id` when empty.
        free_head: Id = null_id,
        live_count: usize = 0,
        tombstone_count: usize = 0,

        pub fn init() Self {
            return .{};
        }

        /// Frees the slot array.  Values are *not* destroyed: callers own the
        /// `*T`s and must drain live and tombstoned entries themselves.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
            self.* = .{};
        }

        pub fn count(self: *const Self) usize {
            return self.live_count;
        }

        pub fn tombstoneCount(self: *const Self) usize {
            return self.tombstone_count;
        }

        /// Compatibility alias for map-like call sites.
        pub fn get(self: *const Self, id: Id) ?*T {
            if (id >= self.items.items.len) return null;
            var slot = &self.items.items[id];
            return switch (slot.*) {
                .live => &slot.live,
                else => null,
            };
        }

        pub fn contains(self: *const Self, id: Id) bool {
            if (id >= self.items.items.len) return false;
            return switch (self.items.items[id]) {
                .live => true,
                else => false,
            };
        }

        pub fn isTombstone(self: *const Self, id: Id) bool {
            if (id >= self.items.items.len) return false;
            return switch (self.items.items[id]) {
                .tombstone => true,
                else => false,
            };
        }

        /// Allocate an ID and store `value` in it.
        ///
        /// Allocating and inserting are one operation, so there is no window
        /// in which an ID is neither live, reserved, nor on the free list.
        /// Callers that need an ID before constructing `T` should construct
        /// `T` first (setting its ID field afterwards) rather than reserving
        /// an ID up front.
        pub fn add(self: *Self, allocator: std.mem.Allocator, value: T) !Id {
            const id = try self.allocId(allocator);
            std.debug.assert(switch (self.items.items[id]) {
                .unused => true,
                else => false,
            });
            self.items.items[id] = .{ .live = value };
            self.live_count += 1;
            return id;
        }

        /// Remove and return the value at `id`, recycling the ID immediately.
        pub fn remove(self: *Self, id: Id) ?T {
            const value = self.tryTakeLive(id);
            self.pushFree(id);
            return value;
        }

        /// Remove the value but keep the ID reserved.  The caller must later
        /// call `clearTombstone` when the outstanding message arrives.
        pub fn tombstone(self: *Self, id: Id) ?T {
            const value = self.tryTakeLive(id);
            self.items.items[id] = .tombstone;
            self.tombstone_count += 1;
            return value;
        }

        /// Release a tombstoned ID back to the free list.
        pub fn clearTombstone(self: *Self, id: Id) void {
            std.debug.assert(id != null_id);
            std.debug.assert(id < self.items.items.len);
            std.debug.assert(switch (self.items.items[id]) {
                .tombstone => true,
                else => false,
            });
            std.debug.assert(self.tombstone_count > 0);

            self.tombstone_count -= 1;
            self.pushFree(id);
        }

        fn tryTakeLive(self: *Self, id: Id) ?T {
            std.debug.assert(id != null_id);
            std.debug.assert(id < self.items.items.len);

            const value = switch (self.items.items[id]) {
                .live => |value| value,
                else => return null,
            };
            std.debug.assert(self.live_count > 0);
            self.live_count -= 1;
            return value;
        }

        fn pushFree(self: *Self, id: Id) void {
            self.items.items[id] = .{ .free = self.free_head };
            self.free_head = id;
        }

        fn popFree(self: *Self) ?Id {
            const id = self.free_head;
            if (id == null_id) return null;

            std.debug.assert(id < self.items.items.len);
            self.free_head = switch (self.items.items[id]) {
                .free => |next| next,
                else => unreachable,
            };
            self.items.items[id] = .unused;
            return id;
        }

        fn allocId(self: *Self, allocator: std.mem.Allocator) !Id {
            if (self.popFree()) |id| return id;

            // The free list is empty, so no slot in `items` is `.free`.  Walk
            // forward from the cursor at most once around the table.
            const len = self.items.items.len;
            var candidate: Id = if (self.next_id == null_id) 1 else self.next_id;
            var probes: usize = 0;

            while (probes <= len) : (probes += 1) {
                // The counter can wrap before the array does.  Restart the
                // scan at one instead of trying to grow to a huge sparse id.
                if (candidate > len) candidate = 1;

                // Past the high-water mark: grow and take the new slot.
                if (candidate >= len) {
                    try self.growTo(allocator, candidate);
                    self.next_id = increment(candidate);
                    return candidate;
                }

                switch (self.items.items[candidate]) {
                    .unused => {
                        self.next_id = increment(candidate);
                        return candidate;
                    },
                    .live, .tombstone => {},
                    .free => unreachable,
                }

                candidate = increment(candidate);
            }

            return error.IdSpaceExhausted;
        }

        fn increment(id: Id) Id {
            return if (id == std.math.maxInt(Id)) 1 else id + 1;
        }

        fn growTo(self: *Self, allocator: std.mem.Allocator, id: Id) !void {
            const needed = std.math.add(usize, @as(usize, id), 1) catch
                return error.IdSpaceExhausted;
            if (needed <= self.items.items.len) return;

            const old_len = self.items.items.len;
            try self.items.resize(allocator, needed);
            for (self.items.items[old_len..]) |*slot| slot.* = .unused;
        }

        pub const Iterator = struct {
            slots: []const Slot,
            index: u32 = 0,

            /// Yields live entries.  Removing or tombstoning the entry just
            /// returned is allowed; growing the map is not.
            pub fn next(self: *Iterator) ?Entry {
                while (self.index < self.slots.len) {
                    const index = self.index;
                    self.index += 1;
                    const slot = &self.slots[index];
                    switch (slot.*) {
                        .live => return .{ .id = index, .value = &slot.live },
                        else => {},
                    }
                }
                return null;
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{ .slots = self.items.items };
        }

        /// First live ID, if any.  Prefer `iterator` when walking all entries;
        /// repeated `firstLiveId`/`remove` calls are quadratic.
        pub fn firstLiveId(self: *const Self) ?Id {
            for (self.items.items, 0..) |slot, index| {
                switch (slot) {
                    .live => return @intCast(index),
                    else => {},
                }
            }
            return null;
        }
    };
}

const testing = std.testing;

const TestValue = struct {
    value: u32,
};

test "SlotMap adds, removes, and reuses IDs" {
    var map = SlotMap(*const TestValue).init();
    defer map.deinit(testing.allocator);

    var values: [4]TestValue = undefined;

    const first = try map.add(testing.allocator, &values[0]);
    try testing.expectEqual(@as(u32, 1), first);
    values[0].value = 10;

    const second = try map.add(testing.allocator, &values[1]);
    try testing.expectEqual(@as(u32, 2), second);
    values[1].value = 20;

    try testing.expectEqual(@as(usize, 2), map.count());
    try testing.expectEqual(@as(u32, 20), map.get(second).?.*.value);

    _ = map.remove(first);
    try testing.expectEqual(@as(usize, 1), map.count());
    try testing.expect(map.get(first) == null);

    // The freed ID is reused and the cursor does not move.
    const reused = try map.add(testing.allocator, &values[2]);
    try testing.expectEqual(first, reused);
    try testing.expectEqual(@as(usize, 2), map.count());
}

test "SlotMap tombstones are not reused until cleared" {
    var map = SlotMap(*const TestValue).init();
    defer map.deinit(testing.allocator);

    const values: [2]TestValue = undefined;

    const id = try map.add(testing.allocator, &values[0]);
    _ = map.tombstone(id);
    try testing.expect(map.isTombstone(id));
    try testing.expectEqual(@as(usize, 1), map.tombstoneCount());
    try testing.expectEqual(@as(usize, 0), map.count());

    const next = try map.add(testing.allocator, &values[1]);
    try testing.expect(next != id);
    try testing.expectEqual(@as(usize, 1), map.count());

    map.clearTombstone(id);
    try testing.expect(!map.isTombstone(id));
    try testing.expectEqual(@as(usize, 0), map.tombstoneCount());

    const reused = try map.add(testing.allocator, &values[0]);
    try testing.expectEqual(id, reused);
}

test "SlotMap wraps without returning zero and skips occupied slots" {
    var map = SlotMap(*const TestValue).init();
    defer map.deinit(testing.allocator);

    const values: [4]TestValue = undefined;

    const first = try map.add(testing.allocator, &values[0]);
    try testing.expectEqual(@as(u32, 1), first);
    const second = try map.add(testing.allocator, &values[1]);
    try testing.expectEqual(@as(u32, 2), second);
    const third = try map.add(testing.allocator, &values[2]);
    try testing.expectEqual(@as(u32, 3), third);

    // Simulate counter wrap-around.  The live slots must be skipped and the
    // slot array must not grow to the old u32 id.
    map.next_id = std.math.maxInt(u32);
    const after_wrap = try map.add(testing.allocator, &values[3]);
    try testing.expectEqual(@as(u32, 4), after_wrap);
    try testing.expect(after_wrap != 0);

    try testing.expectEqual(@as(usize, 5), map.items.items.len);
    try testing.expectEqual(@as(usize, 4), map.count());
}

test "SlotMap iterator visits live entries with their IDs" {
    var map = SlotMap(*const TestValue).init();
    defer map.deinit(testing.allocator);

    const values = [_]TestValue{
        .{ .value = 1 },
        .{ .value = 2 },
        .{ .value = 3 },
    };

    const first = try map.add(testing.allocator, &values[0]);
    const second = try map.add(testing.allocator, &values[1]);
    const third = try map.add(testing.allocator, &values[2]);
    try testing.expectEqual(@as(u32, 1), first);
    try testing.expectEqual(@as(u32, 2), second);
    try testing.expectEqual(@as(u32, 3), third);

    _ = map.remove(second);

    var iterator = map.iterator();
    var sum: u32 = 0;
    var seen: usize = 0;
    while (iterator.next()) |entry| {
        seen += 1;
        sum += entry.value.*.value;

        // Draining through the iterator is the supported teardown pattern and
        // does not resize the slot array.
        _ = map.remove(entry.id);
    }

    try testing.expectEqual(@as(usize, 2), seen);
    try testing.expectEqual(@as(u32, 4), sum);
    try testing.expectEqual(@as(usize, 0), map.count());
}
