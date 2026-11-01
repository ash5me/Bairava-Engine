//! Frame timing by phase. The runtime records how long each phase of a frame took, in seconds, and
//! the overlay and the console read the last value, the average, and the worst recent value of each.
//! Every phase keeps its own ring of recent samples (see profiling/frame_history.zig). Pure
//! arithmetic with no clock, so the runtime passes in durations it measured.

const std = @import("std");
const frame_history = @import("../profiling/frame_history.zig");

/// The phases the runtime times. `frame` is the whole loop iteration, from one frame's start to the
/// next. `update` is every fixed step taken this frame. `draw` is the game's draw and the world pass,
/// and `present` is the window pass and the submit. `gpu` is the wait for the GPU to finish the frame,
/// which only `Config.gpu_timing` records; it falls inside `present`.
pub const Phase = enum {
    frame,
    events,
    asset,
    update,
    audio,
    draw,
    present,
    gpu,
};

const phase_count = std.enums.values(Phase).len;

pub const Stats = struct {
    histories: [phase_count]frame_history.FrameHistory = [_]frame_history.FrameHistory{.{}} ** phase_count,

    /// Records one sample of `phase`, in seconds.
    pub fn record(self: *Stats, phase: Phase, seconds: f32) void {
        self.histories[@intFromEnum(phase)].push(seconds);
    }

    /// The recent samples of `phase`, for reading its last, average, and worst value.
    pub fn of(self: *const Stats, phase: Phase) *const frame_history.FrameHistory {
        return &self.histories[@intFromEnum(phase)];
    }
};

test "each phase keeps its own samples" {
    var stats = Stats{};
    stats.record(.update, 0.004);
    stats.record(.update, 0.008);
    stats.record(.draw, 0.001);

    try std.testing.expectEqual(@as(f32, 0.008), stats.of(.update).last());
    try std.testing.expectApproxEqAbs(@as(f32, 0.006), stats.of(.update).average(), 1e-6);
    try std.testing.expectEqual(@as(f32, 0.008), stats.of(.update).max());
    try std.testing.expectEqual(@as(f32, 0.001), stats.of(.draw).last());
    try std.testing.expectEqual(@as(usize, 0), stats.of(.present).len);
}
