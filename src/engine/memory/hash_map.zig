//! A hash map keyed by validated names (see string.zig).
//!
//! Design:
//! - Open addressing with linear probing over a power-of-two table. The table grows when it
//!   reaches 3/4 full, so probe sequences stay short.
//! - Each slot stores the full 64-bit hash, and every probe compares the hash and then the
//!   whole key. Two different names never share a slot, even when their hashes collide.
//! - Keys are stored inline in the slots, so inserting a key never allocates by itself. Only
//!   growing the table allocates.
//! - Removal uses backward-shift deletion: the entries after the gap move back into it. The
//!   table keeps no tombstones, so lookups are as short after a removal as before it.
//!
//! Nothing in this file imports SDL or the logger.

const std = @import("std");
const strings = @import("string.zig");

pub const Name = strings.Name;

/// 64-bit FNV-1a followed by a splitmix64 finalizer. FNV-1a alone mixes its low bits poorly,
/// and the table picks slots from the low bits, so the finalizer spreads every input bit
/// across the slot index.
pub fn hashName(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        h ^= byte;
        h *%= 0x100000001b3;
    }
    return avalanche(h);
}

fn avalanche(x: u64) u64 {
    var z = x;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// A map from asset names to values of type `V`.
pub fn StringMap(comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Error = std.mem.Allocator.Error || strings.Error || error{
            /// The key is already in the map. The map is unchanged.
            Duplicate,
        };

        const Slot = struct {
            hash: u64,
            key: Name,
            value: V,
            occupied: bool,
        };

        allocator: std.mem.Allocator,
        slots: []Slot,
        len: usize,

        /// Creates an empty map with room for at least `min_capacity` entries before it grows.
        pub fn init(allocator: std.mem.Allocator, min_capacity: usize) std.mem.Allocator.Error!Self {
            var capacity: usize = 8;
            while (capacity * 3 < min_capacity * 4) capacity *= 2;

            const slots = try allocator.alloc(Slot, capacity);
            for (slots) |*slot| slot.occupied = false;
            return .{ .allocator = allocator, .slots = slots, .len = 0 };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        /// Number of entries.
        pub fn count(self: *const Self) usize {
            return self.len;
        }

        /// The value stored under `key`, or null. Lookups don't validate the key, since an
        /// invalid key can never have been stored.
        pub fn get(self: *const Self, key: []const u8) ?V {
            const index = self.findIndex(key) orelse return null;
            return self.slots[index].value;
        }

        /// A pointer to the value stored under `key`, or null. The pointer is invalidated by
        /// the next `insert`, because growing the table moves the slots.
        pub fn getPtr(self: *Self, key: []const u8) ?*V {
            const index = self.findIndex(key) orelse return null;
            return &self.slots[index].value;
        }

        pub fn contains(self: *const Self, key: []const u8) bool {
            return self.findIndex(key) != null;
        }

        /// Adds `key` with `value`. The key is validated, and an existing key fails with
        /// `error.Duplicate` instead of being replaced, so a name can't quietly change meaning.
        /// On any error the map is unchanged.
        pub fn insert(self: *Self, key: []const u8, value: V) Error!void {
            const name = try Name.init(key);
            const hash = hashName(name.slice());
            if (self.findHashed(hash, name.slice()) != null) return error.Duplicate;

            try self.ensureRoom();
            self.place(hash, name, value);
            self.len += 1;
        }

        /// Removes `key` and returns its value, or null if the key isn't in the map. The map is
        /// unchanged in that case.
        pub fn remove(self: *Self, key: []const u8) ?V {
            const index = self.findIndex(key) orelse return null;
            const value = self.slots[index].value;
            self.slots[index].occupied = false;
            self.len -= 1;
            self.shiftBack(index);
            return value;
        }

        /// Fills the gap at `start` so that every remaining key is still reachable from its home
        /// slot. A later slot in the same probe run moves into the gap when the gap lies on that
        /// entry's probe path, meaning between its home slot and its current slot. Otherwise the
        /// entry would be unreachable after the move, so it stays put. The scan ends at the first
        /// empty slot, which always exists because the table is never full.
        fn shiftBack(self: *Self, start: usize) void {
            const mask = self.slots.len - 1;
            var gap = start;
            var probe = (start + 1) & mask;
            while (self.slots[probe].occupied) {
                const home = @as(usize, @truncate(self.slots[probe].hash)) & mask;
                const gap_distance = (gap -% home) & mask;
                const probe_distance = (probe -% home) & mask;
                if (gap_distance < probe_distance) {
                    self.slots[gap] = self.slots[probe];
                    self.slots[probe].occupied = false;
                    gap = probe;
                }
                probe = (probe + 1) & mask;
            }
        }

        fn findIndex(self: *const Self, key: []const u8) ?usize {
            return self.findHashed(hashName(key), key);
        }

        fn findHashed(self: *const Self, hash: u64, key: []const u8) ?usize {
            const mask = self.slots.len - 1;
            var index = @as(usize, @truncate(hash)) & mask;

            // The table is never full, so an empty slot always ends the search. The bound is a
            // guard: if that invariant ever breaks, the lookup reports a miss instead of hanging.
            var probes: usize = 0;
            while (probes < self.slots.len) : (probes += 1) {
                const slot = &self.slots[index];
                if (!slot.occupied) return null;
                if (slot.hash == hash and std.mem.eql(u8, slot.key.slice(), key)) return index;
                index = (index + 1) & mask;
            }
            return null;
        }

        /// Writes a new entry into the first empty slot on its probe path. The caller has
        /// already checked that the key is absent and that there is room.
        fn place(self: *Self, hash: u64, key: Name, value: V) void {
            const mask = self.slots.len - 1;
            var index = @as(usize, @truncate(hash)) & mask;
            while (self.slots[index].occupied) index = (index + 1) & mask;
            self.slots[index] = .{ .hash = hash, .key = key, .value = value, .occupied = true };
        }

        /// Grows the table before an insert that would push it past 3/4 full. If allocation
        /// fails, the table is left as it was.
        fn ensureRoom(self: *Self) std.mem.Allocator.Error!void {
            if ((self.len + 1) * 4 <= self.slots.len * 3) return;
            try self.rehash(self.slots.len * 2);
        }

        fn rehash(self: *Self, new_capacity: usize) std.mem.Allocator.Error!void {
            const new_slots = try self.allocator.alloc(Slot, new_capacity);
            for (new_slots) |*slot| slot.occupied = false;

            const old_slots = self.slots;
            self.slots = new_slots;
            for (old_slots) |slot| {
                if (slot.occupied) self.place(slot.hash, slot.key, slot.value);
            }
            self.allocator.free(old_slots);
        }
    };
}

test "insert and get return the stored values" {
    var map = try StringMap(u32).init(std.testing.allocator, 0);
    defer map.deinit();

    try map.insert("tile", 1);
    try map.insert("warrior", 2);
    try map.insert("ui/button", 3);

    try std.testing.expectEqual(@as(?u32, 1), map.get("tile"));
    try std.testing.expectEqual(@as(?u32, 2), map.get("warrior"));
    try std.testing.expectEqual(@as(?u32, 3), map.get("ui/button"));
    try std.testing.expectEqual(@as(?u32, null), map.get("missing"));
    try std.testing.expectEqual(@as(usize, 3), map.count());
    try std.testing.expect(map.contains("tile"));
    try std.testing.expect(!map.contains("Tile"));
}

test "a key that is a prefix of another key stays distinct" {
    var map = try StringMap(u8).init(std.testing.allocator, 0);
    defer map.deinit();

    try map.insert("ui", 1);
    try map.insert("ui/a", 2);
    try map.insert("ui/ab", 3);

    try std.testing.expectEqual(@as(?u8, 1), map.get("ui"));
    try std.testing.expectEqual(@as(?u8, 2), map.get("ui/a"));
    try std.testing.expectEqual(@as(?u8, 3), map.get("ui/ab"));
    try std.testing.expectEqual(@as(?u8, null), map.get("u"));
}

test "a duplicate key is rejected and the original value is kept" {
    var map = try StringMap(u32).init(std.testing.allocator, 0);
    defer map.deinit();

    try map.insert("tile", 1);
    try std.testing.expectError(error.Duplicate, map.insert("tile", 99));
    try std.testing.expectEqual(@as(?u32, 1), map.get("tile"));
    try std.testing.expectEqual(@as(usize, 1), map.count());
}

test "invalid keys are rejected and leave the map unchanged" {
    var map = try StringMap(u32).init(std.testing.allocator, 0);
    defer map.deinit();

    try std.testing.expectError(error.Empty, map.insert("", 1));
    try std.testing.expectError(error.BadCharacter, map.insert("Tile", 1));
    try std.testing.expectError(error.BadSegment, map.insert("a//b", 1));
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "getPtr allows in-place updates" {
    var map = try StringMap(u32).init(std.testing.allocator, 0);
    defer map.deinit();

    try map.insert("counter", 0);
    map.getPtr("counter").?.* += 5;
    try std.testing.expectEqual(@as(?u32, 5), map.get("counter"));
    try std.testing.expectEqual(@as(?*u32, null), map.getPtr("nope"));
}

test "wrap-around probing finds keys whose home slot is the last slot" {
    // With the initial capacity of 8, the mask is 7. Pick keys whose home slot is 7, so the
    // probe sequence wraps from the end of the table back to slot 0.
    var keys: [4][16]u8 = undefined;
    var key_slices: [4][]const u8 = undefined;
    var found: usize = 0;
    var candidate: u32 = 0;
    while (found < 4) : (candidate += 1) {
        const text = std.fmt.bufPrint(&keys[found], "k{d}", .{candidate}) catch unreachable;
        if (@as(usize, @truncate(hashName(text))) & 7 == 7) {
            key_slices[found] = text;
            found += 1;
        }
    }

    var map = try StringMap(u32).init(std.testing.allocator, 0);
    defer map.deinit();
    for (key_slices, 0..) |key, i| try map.insert(key, @intCast(i));
    for (key_slices, 0..) |key, i| {
        try std.testing.expectEqual(@as(?u32, @intCast(i)), map.get(key));
    }
    try std.testing.expectEqual(@as(usize, 8), map.slots.len);
}

test "the table grows and keeps every entry" {
    const allocator = std.testing.allocator;
    var map = try StringMap(u32).init(allocator, 0);
    defer map.deinit();

    const total: u32 = 5000;
    var name_buf: [32]u8 = undefined;
    for (0..total) |i| {
        const name = std.fmt.bufPrint(&name_buf, "asset/{d:0>5}", .{i}) catch unreachable;
        try map.insert(name, @intCast(i));
    }

    try std.testing.expectEqual(@as(usize, total), map.count());
    try std.testing.expect(map.slots.len >= total);
    // Load stays at or below 3/4, which is what keeps probing short.
    try std.testing.expect(map.count() * 4 <= map.slots.len * 3);

    for (0..total) |i| {
        const name = std.fmt.bufPrint(&name_buf, "asset/{d:0>5}", .{i}) catch unreachable;
        try std.testing.expectEqual(@as(?u32, @intCast(i)), map.get(name));
    }
    try std.testing.expectEqual(@as(?u32, null), map.get("asset/99999"));
}

test "matches std.StringHashMap over a random mix of inserts and lookups" {
    // Names come from a small alphabet, which makes many prefixes and many collisions
    // likely. The map must agree with the standard library at every step.
    const allocator = std.testing.allocator;
    const alphabet = "ab01_-.";

    var prng = std.Random.DefaultPrng.init(0x5eed_1234);
    const random = prng.random();

    var ours = try StringMap(u32).init(allocator, 0);
    defer ours.deinit();
    var oracle = std.StringHashMap(u32).init(allocator);
    defer oracle.deinit();

    // Storage for every generated key. The oracle keeps slices into it, so it must outlive the
    // loop.
    var store: [2000][12]u8 = undefined;
    var lens: [2000]usize = undefined;
    var generated: usize = 0;

    for (0..6000) |step| {
        // Lookups use a key already generated (hit) or a fresh one (miss).
        const do_insert = generated == 0 or random.uintLessThan(u32, 3) != 0;
        if (do_insert and generated < store.len) {
            const len = 1 + random.uintLessThan(usize, 10);
            store[generated][0] = 'a' + @as(u8, @intCast(random.uintLessThan(u8, 2)));
            for (1..len) |i| store[generated][i] = alphabet[random.uintLessThan(usize, alphabet.len)];
            lens[generated] = len;
            generated += 1;
        }

        const pick = random.uintLessThan(usize, generated);
        const key = store[pick][0..lens[pick]];

        if (random.boolean()) {
            // Insert: both maps must agree on whether the key was new.
            const ours_result = ours.insert(key, @intCast(step));
            const already = oracle.contains(key);
            if (already) {
                try std.testing.expectError(error.Duplicate, ours_result);
            } else {
                try ours_result;
                try oracle.put(key, @intCast(step));
            }
        } else {
            // Lookup: values must match exactly.
            try std.testing.expectEqual(oracle.get(key), ours.get(key));
        }
    }

    try std.testing.expectEqual(oracle.count(), ours.count());
    var it = oracle.iterator();
    while (it.next()) |entry| {
        try std.testing.expectEqual(@as(?u32, entry.value_ptr.*), ours.get(entry.key_ptr.*));
    }
}

test "remove returns the value, and later lookups miss" {
    var map = try StringMap(u32).init(std.testing.allocator, 0);
    defer map.deinit();

    try map.insert("tile", 1);
    try map.insert("warrior", 2);
    try map.insert("ui/button", 3);

    try std.testing.expectEqual(@as(?u32, 2), map.remove("warrior"));
    try std.testing.expectEqual(@as(?u32, null), map.get("warrior"));
    try std.testing.expectEqual(@as(?u32, null), map.remove("warrior"));
    try std.testing.expectEqual(@as(?u32, 1), map.get("tile"));
    try std.testing.expectEqual(@as(?u32, 3), map.get("ui/button"));
    try std.testing.expectEqual(@as(usize, 2), map.count());

    // A removed key can be inserted again.
    try map.insert("warrior", 9);
    try std.testing.expectEqual(@as(?u32, 9), map.get("warrior"));
}

test "removals keep the keys that share a probe run reachable, including across the wrap" {
    // Four keys with home slot 6 in an 8-slot table. They fill slots 6, 7, 0, and 1, so the run
    // wraps past the end of the table, and removals must shift entries across that wrap.
    var keys: [4][16]u8 = undefined;
    var key_slices: [4][]const u8 = undefined;
    var found: usize = 0;
    var candidate: u32 = 0;
    while (found < 4) : (candidate += 1) {
        const text = std.fmt.bufPrint(&keys[found], "k{d}", .{candidate}) catch unreachable;
        if (@as(usize, @truncate(hashName(text))) & 7 == 6) {
            key_slices[found] = text;
            found += 1;
        }
    }

    var map = try StringMap(u32).init(std.testing.allocator, 0);
    defer map.deinit();
    for (key_slices, 0..) |key, i| try map.insert(key, @intCast(i));
    try std.testing.expectEqual(@as(usize, 8), map.slots.len);

    // Remove the first key of the run, then the third, which has wrapped to slot 0.
    try std.testing.expectEqual(@as(?u32, 0), map.remove(key_slices[0]));
    try std.testing.expectEqual(@as(?u32, 2), map.remove(key_slices[2]));
    try std.testing.expectEqual(@as(?u32, 1), map.get(key_slices[1]));
    try std.testing.expectEqual(@as(?u32, 3), map.get(key_slices[3]));
    try std.testing.expectEqual(@as(usize, 2), map.count());
}

test "random inserts, lookups, and removals agree with std.StringHashMap" {
    const allocator = std.testing.allocator;
    const alphabet = "ab01_-.";

    var prng = std.Random.DefaultPrng.init(0xdead_beef);
    const random = prng.random();

    var ours = try StringMap(u32).init(allocator, 0);
    defer ours.deinit();
    var oracle = std.StringHashMap(u32).init(allocator);
    defer oracle.deinit();

    // Storage for every generated key. Both maps refer to these bytes, so they must outlive the loop.
    var store: [2000][12]u8 = undefined;
    var lens: [2000]usize = undefined;
    var generated: usize = 0;

    for (0..12000) |step| {
        const do_new = generated == 0 or random.uintLessThan(u32, 4) == 0;
        if (do_new and generated < store.len) {
            const len = 1 + random.uintLessThan(usize, 10);
            store[generated][0] = 'a' + @as(u8, @intCast(random.uintLessThan(u8, 2)));
            for (1..len) |i| store[generated][i] = alphabet[random.uintLessThan(usize, alphabet.len)];
            lens[generated] = len;
            generated += 1;
        }

        const pick = random.uintLessThan(usize, generated);
        const key = store[pick][0..lens[pick]];

        switch (random.uintLessThan(u32, 3)) {
            0 => {
                // Insert: both maps must agree on whether the key was new.
                if (oracle.contains(key)) {
                    try std.testing.expectError(error.Duplicate, ours.insert(key, @intCast(step)));
                } else {
                    try ours.insert(key, @intCast(step));
                    try oracle.put(key, @intCast(step));
                }
            },
            1 => {
                // Remove: both maps must return the same value, or nothing.
                const expected = oracle.get(key);
                if (expected != null) _ = oracle.remove(key);
                try std.testing.expectEqual(expected, ours.remove(key));
            },
            else => {
                try std.testing.expectEqual(oracle.get(key), ours.get(key));
            },
        }
    }

    try std.testing.expectEqual(oracle.count(), ours.count());
    var it = oracle.iterator();
    while (it.next()) |entry| {
        try std.testing.expectEqual(@as(?u32, entry.value_ptr.*), ours.get(entry.key_ptr.*));
    }
}
