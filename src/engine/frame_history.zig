//! The frame times the debug overlay graphs, and the numbers it shows about them. Pure math with
//! no SDL or GPU, so `zig build test` covers it.

const std = @import("std");

/// Frames kept. The graph has one column per kept frame, so this is also its width in pixels.
pub const capacity = 120;

/// The last `capacity` frame times, in seconds, kept as a ring. A new sample overwrites the oldest.
pub const FrameHistory = struct {
    samples: [capacity]f32 = [_]f32{0} ** capacity,
    /// Where the next sample is written.
    next: usize = 0,
    /// How many samples are kept, up to `capacity`.
    len: usize = 0,

    pub fn push(self: *FrameHistory, seconds: f32) void {
        self.samples[self.next] = seconds;
        self.next = (self.next + 1) % capacity;
        if (self.len < capacity) self.len += 1;
    }

    /// The sample at `i`, where 0 is the oldest kept and `len - 1` is the newest. An index past the
    /// kept samples returns 0.
    pub fn at(self: *const FrameHistory, i: usize) f32 {
        if (i >= self.len) return 0;
        const oldest = (self.next + capacity - self.len) % capacity;
        return self.samples[(oldest + i) % capacity];
    }

    /// The newest sample, or 0 when nothing has been recorded.
    pub fn last(self: *const FrameHistory) f32 {
        if (self.len == 0) return 0;
        return self.at(self.len - 1);
    }

    /// The mean of the kept samples, or 0 when there are none.
    pub fn average(self: *const FrameHistory) f32 {
        if (self.len == 0) return 0;
        var sum: f32 = 0;
        var i: usize = 0;
        while (i < self.len) : (i += 1) sum += self.at(i);
        return sum / @as(f32, @floatFromInt(self.len));
    }

    /// The largest kept sample, or 0 when there are none.
    pub fn max(self: *const FrameHistory) f32 {
        var largest: f32 = 0;
        var i: usize = 0;
        while (i < self.len) : (i += 1) largest = @max(largest, self.at(i));
        return largest;
    }
};

/// How far `seconds` reaches up a graph that is `full_scale` seconds tall, from 0 to 1. A zero or
/// negative scale draws nothing, so the caller never divides by zero.
pub fn fraction(seconds: f32, full_scale: f32) f32 {
    if (!(full_scale > 0)) return 0;
    return std.math.clamp(seconds / full_scale, 0, 1);
}

test "an empty history reports zeros" {
    const h = FrameHistory{};
    try std.testing.expectEqual(@as(f32, 0), h.last());
    try std.testing.expectEqual(@as(f32, 0), h.average());
    try std.testing.expectEqual(@as(f32, 0), h.max());
}

test "samples read oldest first, and the newest overwrites the oldest once full" {
    var h = FrameHistory{};
    h.push(1);
    h.push(2);
    h.push(3);
    try std.testing.expectEqual(@as(usize, 3), h.len);
    try std.testing.expectEqual(@as(f32, 1), h.at(0));
    try std.testing.expectEqual(@as(f32, 3), h.at(2));
    try std.testing.expectEqual(@as(f32, 3), h.last());
    try std.testing.expectEqual(@as(f32, 0), h.at(3));

    var i: usize = 0;
    while (i < capacity) : (i += 1) h.push(@floatFromInt(i + 10));
    // The last `capacity` pushes are 10 through capacity + 9, so those are the samples kept now.
    try std.testing.expectEqual(@as(usize, capacity), h.len);
    try std.testing.expectEqual(@as(f32, 10), h.at(0));
    try std.testing.expectEqual(@as(f32, capacity + 9), h.last());
}

test "average and max cover only the samples kept" {
    var h = FrameHistory{};
    h.push(0.010);
    h.push(0.030);
    h.push(0.020);
    try std.testing.expectApproxEqAbs(@as(f32, 0.020), h.average(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.030), h.max(), 1e-6);
}

test "fraction scales into a graph, clamps, and tolerates a zero scale" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), fraction(0.010, 0.020), 1e-6);
    try std.testing.expectEqual(@as(f32, 1), fraction(0.5, 0.020));
    try std.testing.expectEqual(@as(f32, 0), fraction(0.010, 0));
}
