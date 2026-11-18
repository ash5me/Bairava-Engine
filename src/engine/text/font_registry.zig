//! Font identity for the text system: the registry-issued `FontId`, the `FontHandle` that names one font, and
//! `Registry(T)`, which stores and owns the values behind those handles.
//!
//! This is the Phase 1 font contract of the Text and Font System Migration Plan (decisions D-01 and D-02). It is
//! CPU-only. It imports no renderer, platform, or HarfBuzz module, so game-facing code can hold a `FontHandle`
//! without knowing which provider (bitmap, prebaked coverage, runtime coverage, or MSDF) stores the font.
//!
//! Rules, from D-02:
//! - An id is a `u64` the registry issues. Zero is never issued, so `invalid_font_id` names no font.
//! - An id is never reused during the process lifetime. After a font is removed, its handle stays stale and can
//!   never match a later font.
//! - Issuing fails with `error.FontIdExhausted` at the top of the range. It never wraps.
//!
//! Because ids are never reused, a handle needs no generation counter. That differs from `assets/handle.zig`,
//! which reuses cache slots and therefore needs one.
//!
//! Ownership and lifetime:
//! - `Registry(T)` owns each stored value until `remove` returns it. The caller then releases the value, for example
//!   a GPU texture. Removing does not release anything by itself.
//! - `Registry.deinit` frees only the table. Remove every entry, and release each value, before calling it.
//! - A pointer from `get` is valid until the next `insert` or `remove`, because either may move the table.
//! - A handle is valid only with the registry that issued it. Two registries can issue the same id.

const std = @import("std");

/// A registry-issued font identity. Zero is never issued.
pub const FontId = u64;

/// The id that names no font. Shapers created without a registry id stamp this value on their runs.
pub const invalid_font_id: FontId = 0;

/// What game-facing code holds in place of a font. It contains only the id: removal retires the id for good, so no
/// generation is needed.
pub const FontHandle = struct {
    id: FontId,

    /// The handle that names nothing.
    pub const invalid: FontHandle = .{ .id = invalid_font_id };
};

/// The id counter reached the top of the range, so no further font can be identified.
pub const IssueError = error{FontIdExhausted};

/// Insert can fail with allocation failure, or with id exhaustion.
pub const InsertError = std.mem.Allocator.Error || IssueError;

/// Why a handle can't be used. `InvalidHandle` means the registry never issued it: it is the invalid id, or it is at
/// or past the next id to issue. `StaleHandle` means it was issued, and its font has since been removed.
pub const LookupError = error{ InvalidHandle, StaleHandle };

/// Returns the id at `next.*` and advances `next`. The first id is 1, because `next` starts at 1. At the top of the
/// range it fails and leaves `next` unchanged. It never wraps back to an id already issued.
pub fn issue(next: *FontId) IssueError!FontId {
    const id = next.*;
    std.debug.assert(id != invalid_font_id);
    if (id == std.math.maxInt(FontId)) return error.FontIdExhausted;
    next.* = id + 1;
    return id;
}

/// A table of values keyed by `FontId`, with a handle for each. Lookups are linear, which is fine for the small
/// number of fonts a game loads.
pub fn Registry(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            id: FontId,
            value: T,
        };

        allocator: std.mem.Allocator,
        entries: std.ArrayList(Entry) = .empty,
        /// The next id to issue. Starts at 1, and `issue` advances it.
        next_id: FontId = 1,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Frees the table only. Remove every entry, and release its value, first.
        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }

        /// The number of live entries.
        pub fn count(self: *const Self) usize {
            return self.entries.items.len;
        }

        /// Stores `value` under a new id and returns its handle. If the table cannot grow, the id is still spent. That
        /// is safe, because ids are never reused.
        pub fn insert(self: *Self, value: T) InsertError!FontHandle {
            const id = try issue(&self.next_id);
            try self.entries.append(self.allocator, .{ .id = id, .value = value });
            return .{ .id = id };
        }

        /// Returns the stored value. The pointer is valid until the next `insert` or `remove`.
        pub fn get(self: *Self, handle: FontHandle) LookupError!*T {
            const index = try self.indexOf(handle);
            return &self.entries.items[index].value;
        }

        /// Removes the entry and returns its value. The caller owns the value and must release it. The handle becomes
        /// stale and stays stale.
        pub fn remove(self: *Self, handle: FontHandle) LookupError!T {
            const index = try self.indexOf(handle);
            const removed = self.entries.swapRemove(index);
            return removed.value;
        }

        fn indexOf(self: *const Self, handle: FontHandle) LookupError!usize {
            if (handle.id == invalid_font_id or handle.id >= self.next_id) return error.InvalidHandle;
            for (self.entries.items, 0..) |entry, index| {
                if (entry.id == handle.id) return index;
            }
            return error.StaleHandle;
        }
    };
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Reg = Registry(u32);

test "the first id issued is 1, and zero is never issued" {
    var next: FontId = 1;
    try testing.expectEqual(@as(FontId, 1), try issue(&next));
    try testing.expectEqual(@as(FontId, 2), next);
    try testing.expect(invalid_font_id == 0);
}

test "exhaustion fails at the top of the range and leaves the counter where it was" {
    const top = std.math.maxInt(FontId);
    var next: FontId = top - 1;
    try testing.expectEqual(top - 1, try issue(&next));
    try testing.expectEqual(top, next);
    try testing.expectError(error.FontIdExhausted, issue(&next));
    try testing.expectError(error.FontIdExhausted, issue(&next));
    try testing.expectEqual(top, next);
}

test "an inserted value is found by its handle" {
    var reg = Reg.init(testing.allocator);
    defer reg.deinit();
    const a = try reg.insert(10);
    const b = try reg.insert(20);
    try testing.expect(a.id != b.id);
    try testing.expectEqual(@as(u32, 10), (try reg.get(a)).*);
    try testing.expectEqual(@as(u32, 20), (try reg.get(b)).*);
    try testing.expectEqual(@as(usize, 2), reg.count());
    _ = try reg.remove(a);
    _ = try reg.remove(b);
}

test "the invalid handle, and an id never issued, are InvalidHandle" {
    var reg = Reg.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.insert(1);
    try testing.expectError(error.InvalidHandle, reg.get(FontHandle.invalid));
    try testing.expectError(error.InvalidHandle, reg.get(.{ .id = 99 }));
    try testing.expectError(error.InvalidHandle, reg.remove(FontHandle.invalid));
}

test "a removed font's handle is stale, and removing it again is stale" {
    var reg = Reg.init(testing.allocator);
    defer reg.deinit();
    const h = try reg.insert(7);
    try testing.expectEqual(@as(u32, 7), try reg.remove(h));
    try testing.expectError(error.StaleHandle, reg.get(h));
    try testing.expectError(error.StaleHandle, reg.remove(h));
    try testing.expectEqual(@as(usize, 0), reg.count());
}

test "a removed id is never issued again" {
    var reg = Reg.init(testing.allocator);
    defer reg.deinit();
    const old = try reg.insert(1);
    _ = try reg.remove(old);
    const fresh = try reg.insert(2);
    try testing.expect(fresh.id != old.id);
    try testing.expectError(error.StaleHandle, reg.get(old));
    try testing.expectEqual(@as(u32, 2), (try reg.get(fresh)).*);
}

test "removing one font leaves the other handles valid" {
    var reg = Reg.init(testing.allocator);
    defer reg.deinit();
    const a = try reg.insert(1);
    const b = try reg.insert(2);
    const c = try reg.insert(3);
    _ = try reg.remove(b);
    try testing.expectEqual(@as(u32, 1), (try reg.get(a)).*);
    try testing.expectEqual(@as(u32, 3), (try reg.get(c)).*);
    try testing.expectError(error.StaleHandle, reg.get(b));
    _ = try reg.remove(a);
    _ = try reg.remove(c);
}

test "a registry at the top of the id range refuses insert without wrapping" {
    var reg = Reg.init(testing.allocator);
    defer reg.deinit();
    const top = std.math.maxInt(FontId);
    reg.next_id = top - 1;
    const last = try reg.insert(5);
    try testing.expectEqual(top - 1, last.id);
    try testing.expectError(error.FontIdExhausted, reg.insert(6));
    try testing.expectEqual(@as(usize, 1), reg.count());
    try testing.expectEqual(@as(u32, 5), (try reg.get(last)).*);
    _ = try reg.remove(last);
}
