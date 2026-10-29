//! The SDL-free rules for audio voices: handles that go stale when a voice ends, gain
//! arithmetic, and the decisions about when a voice has finished or needs another copy of
//! its sound. `audio.zig` does the SDL calls and uses these rules. Nothing here imports SDL or
//! the logger, so the unit tests run without an audio device.

const std = @import("std");

/// Names one voice. A handle goes stale when its voice ends, so a handle kept after that can't
/// reach a different voice that later reuses the same slot.
pub const Handle = struct {
    index: u16,
    generation: u32,
};

/// A fixed-capacity table of voices. Each slot has a generation that changes when its voice ends.
/// A handle is valid only while its generation matches the slot's.
pub fn Pool(comptime Payload: type, comptime capacity: u16) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            generation: u32 = 0,
            payload: ?Payload = null,
        };

        slots: [capacity]Slot = [_]Slot{.{}} ** capacity,

        /// Stores `payload` in a free slot and returns its handle, or null if every slot is busy.
        pub fn acquire(self: *Self, payload: Payload) ?Handle {
            for (&self.slots, 0..) |*slot, i| {
                if (slot.payload == null) {
                    slot.payload = payload;
                    return .{ .index = @intCast(i), .generation = slot.generation };
                }
            }
            return null;
        }

        /// The payload behind `handle`, or null if its voice has ended. The pointer is valid until
        /// the next `acquire` or `release`.
        pub fn get(self: *Self, handle: Handle) ?*Payload {
            const slot = self.slotFor(handle) orelse return null;
            if (slot.payload) |*payload| return payload;
            return null;
        }

        /// Ends the voice behind `handle` and returns its payload, so the caller can clean it up.
        /// Returns null, and changes nothing, if the handle is already stale.
        pub fn release(self: *Self, handle: Handle) ?Payload {
            const slot = self.slotFor(handle) orelse return null;
            const payload = slot.payload orelse return null;
            slot.payload = null;
            slot.generation +%= 1;
            return payload;
        }

        /// The number of busy slots.
        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots) |slot| {
                if (slot.payload != null) n += 1;
            }
            return n;
        }

        pub const Entry = struct {
            handle: Handle,
            payload: *Payload,
        };

        /// Visits each busy slot once. Releasing the entry just returned is safe, because the
        /// walk has already moved past its slot.
        pub const Iterator = struct {
            pool: *Self,
            cursor: u16 = 0,

            pub fn next(self: *Iterator) ?Entry {
                while (self.cursor < capacity) {
                    const index = self.cursor;
                    self.cursor += 1;
                    const slot = &self.pool.slots[index];
                    if (slot.payload) |*payload| {
                        return .{
                            .handle = .{ .index = index, .generation = slot.generation },
                            .payload = payload,
                        };
                    }
                }
                return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .pool = self };
        }

        fn slotFor(self: *Self, handle: Handle) ?*Slot {
            if (handle.index >= capacity) return null;
            const slot = &self.slots[handle.index];
            if (slot.generation != handle.generation) return null;
            return slot;
        }
    };
}

/// The gain a voice plays at: its own gain times the master gain. Each factor is clamped to
/// [0, 1], and NaN counts as 0.
pub fn effectiveGain(voice_gain: f32, master_gain: f32) f32 {
    return clamp01(voice_gain) * clamp01(master_gain);
}

fn clamp01(x: f32) f32 {
    if (!(x > 0)) return 0;
    if (x > 1) return 1;
    return x;
}

/// A voice has finished when it isn't looping and nothing is left in its stream, neither queued
/// input nor converted output. A looping voice never finishes on its own.
pub fn isFinished(looping: bool, queued_bytes: c_int, available_bytes: c_int) bool {
    return !looping and queued_bytes <= 0 and available_bytes <= 0;
}

/// A looping voice needs another copy of its sound when less than one full copy is still queued.
/// Adding the copy before the queue runs dry is what keeps the loop seamless.
pub fn needsLoopCopy(queued_bytes: c_int, sound_bytes: c_int) bool {
    return queued_bytes < sound_bytes;
}

test "acquire hands out distinct handles until the pool is full" {
    var pool = Pool(u32, 3){};
    const a = pool.acquire(10).?;
    const b = pool.acquire(20).?;
    const c = pool.acquire(30).?;
    try std.testing.expect(a.index != b.index and b.index != c.index and a.index != c.index);
    try std.testing.expect(pool.acquire(40) == null);
    try std.testing.expectEqual(@as(usize, 3), pool.count());
    try std.testing.expectEqual(@as(u32, 20), pool.get(b).?.*);
}

test "a released handle goes stale, and its slot can be reused safely" {
    var pool = Pool(u32, 2){};
    const first = pool.acquire(1).?;
    try std.testing.expectEqual(@as(?u32, 1), pool.release(first));
    try std.testing.expectEqual(@as(?*u32, null), pool.get(first));
    // Releasing a stale handle changes nothing.
    try std.testing.expectEqual(@as(?u32, null), pool.release(first));

    // The slot is reused under a new generation, so the old handle still can't reach it.
    const second = pool.acquire(2).?;
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expectEqual(@as(?*u32, null), pool.get(first));
    try std.testing.expectEqual(@as(u32, 2), pool.get(second).?.*);
}

test "an out-of-range handle is treated as stale" {
    var pool = Pool(u32, 2){};
    try std.testing.expectEqual(@as(?*u32, null), pool.get(.{ .index = 9, .generation = 0 }));
    try std.testing.expectEqual(@as(?u32, null), pool.release(.{ .index = 9, .generation = 0 }));
}

test "the iterator visits busy slots once, and releasing during the walk is safe" {
    var pool = Pool(u32, 4){};
    _ = pool.acquire(1).?;
    _ = pool.acquire(2).?;
    _ = pool.acquire(3).?;
    _ = pool.acquire(4).?;

    var seen: u32 = 0;
    var total: u32 = 0;
    var it = pool.iterator();
    while (it.next()) |entry| {
        seen += 1;
        total += entry.payload.*;
        // Release every odd payload while walking.
        if (entry.payload.* % 2 == 1) _ = pool.release(entry.handle);
    }
    try std.testing.expectEqual(@as(u32, 4), seen);
    try std.testing.expectEqual(@as(u32, 10), total);
    try std.testing.expectEqual(@as(usize, 2), pool.count());
}

test "gain multiplies voice and master gain, each clamped to [0, 1]" {
    try std.testing.expectEqual(@as(f32, 0.25), effectiveGain(0.5, 0.5));
    try std.testing.expectEqual(@as(f32, 1.0), effectiveGain(2.0, 1.0));
    try std.testing.expectEqual(@as(f32, 0.0), effectiveGain(-1.0, 1.0));
    try std.testing.expectEqual(@as(f32, 0.0), effectiveGain(1.0, std.math.nan(f32)));
    try std.testing.expectEqual(@as(f32, 0.5), effectiveGain(1.0, 0.5));
}

test "a non-looping voice finishes only when nothing is queued or available" {
    try std.testing.expect(!isFinished(false, 100, 0));
    try std.testing.expect(!isFinished(false, 0, 64));
    try std.testing.expect(isFinished(false, 0, 0));
    try std.testing.expect(!isFinished(true, 0, 0));
}

test "a looping voice is topped up when less than one copy is queued" {
    try std.testing.expect(needsLoopCopy(0, 1000));
    try std.testing.expect(needsLoopCopy(999, 1000));
    try std.testing.expect(!needsLoopCopy(1000, 1000));
    try std.testing.expect(!needsLoopCopy(1500, 1000));
}
