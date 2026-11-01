//! A record of the frames that ran long, so a spike that has already passed can still be found. Each spike
//! keeps its frame count, its time, and the phase that took the most time in that frame. The total counts every
//! spike since the run started. Pure data with no clock or GPU, so `zig build test` covers it.

const std = @import("std");
const frame_stats = @import("frame_stats.zig");

/// A frame longer than this counts as a spike: two frames at 60 Hz, the same bar the overlay draws in red.
pub const threshold_seconds: f32 = 2.0 / 60.0;

/// Spikes kept for the overlay. The total still counts every spike past this many.
pub const capacity = 8;

/// One spike: the frame count when it was observed, the frame's time, and the phase that took the most of it.
pub const Spike = struct {
    /// Frames completed when the spike was observed. The frame that ran long is the one just before it.
    frame: u64,
    seconds: f32,
    phase: frame_stats.Phase,
};

pub const SpikeLog = struct {
    recent: [capacity]Spike = undefined,
    /// Where the next spike is written.
    next: usize = 0,
    /// How many spikes are kept, up to `capacity`.
    kept: usize = 0,
    /// Spikes seen since the run started, including any that are no longer kept.
    total: u64 = 0,

    /// Records a frame as a spike when it took longer than `threshold_seconds`. Shorter frames are ignored.
    pub fn observe(self: *SpikeLog, frame: u64, seconds: f32, phase: frame_stats.Phase) void {
        // Written as a negated comparison so that a NaN time is ignored rather than recorded.
        if (!(seconds > threshold_seconds)) return;
        self.recent[self.next] = .{ .frame = frame, .seconds = seconds, .phase = phase };
        self.next = (self.next + 1) % capacity;
        if (self.kept < capacity) self.kept += 1;
        self.total += 1;
    }

    /// The most recent spike, or null when none has been seen.
    pub fn latest(self: *const SpikeLog) ?Spike {
        if (self.kept == 0) return null;
        return self.recent[(self.next + capacity - 1) % capacity];
    }
};

test "a frame at or under the threshold is not a spike" {
    var log = SpikeLog{};
    log.observe(1, threshold_seconds, .update);
    log.observe(2, 0.010, .draw);
    try std.testing.expectEqual(@as(u64, 0), log.total);
    try std.testing.expect(log.latest() == null);
}

test "a NaN frame time is ignored" {
    var log = SpikeLog{};
    log.observe(1, std.math.nan(f32), .update);
    try std.testing.expectEqual(@as(u64, 0), log.total);
}

test "a long frame is kept with its phase, and the latest is the newest" {
    var log = SpikeLog{};
    log.observe(10, 0.040, .draw);
    log.observe(11, 0.050, .gpu);
    try std.testing.expectEqual(@as(u64, 2), log.total);
    const latest = log.latest().?;
    try std.testing.expectEqual(@as(u64, 11), latest.frame);
    try std.testing.expectEqual(frame_stats.Phase.gpu, latest.phase);
    try std.testing.expectApproxEqAbs(@as(f32, 0.050), latest.seconds, 1e-6);
}

test "the kept list holds the newest spikes, while the total keeps counting" {
    var log = SpikeLog{};
    var frame: u64 = 1;
    while (frame <= capacity + 3) : (frame += 1) log.observe(frame, 0.040, .update);
    try std.testing.expectEqual(@as(u64, capacity + 3), log.total);
    try std.testing.expectEqual(@as(usize, capacity), log.kept);
    try std.testing.expectEqual(@as(u64, capacity + 3), log.latest().?.frame);
}
