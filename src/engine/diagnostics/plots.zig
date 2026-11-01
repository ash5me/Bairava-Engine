//! Per-frame values that the debug overlay draws as strips and that Tracy plots over time. Each plot
//! keeps the same window of frames as the frame graph, so the overlay can report its average and p95
//! as well as draw it. Pure data with no clock or GPU, so `zig build test` covers it.

const std = @import("std");
const frame_history = @import("../profiling/frame_history.zig");

/// The values the runtime records once per frame.
pub const Plot = enum {
    /// Sprites queued for the world view, before the overlay adds its own.
    sprites,
    /// Draw calls issued last frame, for the world pass and the window pass.
    draw_calls,
    /// Allocations requested so far this frame, across every scope.
    allocations,
    /// Bytes those allocations requested.
    allocated_bytes,
};

const plot_count = std.enums.values(Plot).len;

/// One history per plot.
pub const Plots = struct {
    series: [plot_count]frame_history.FrameHistory = [_]frame_history.FrameHistory{.{}} ** plot_count,

    /// Records one sample of `plot` for this frame.
    pub fn record(self: *Plots, plot: Plot, value: f32) void {
        self.series[@intFromEnum(plot)].push(value);
    }

    /// The recent samples of `plot`.
    pub fn of(self: *const Plots, plot: Plot) *const frame_history.FrameHistory {
        return &self.series[@intFromEnum(plot)];
    }
};

test "each plot keeps its own samples" {
    var plots = Plots{};
    plots.record(.sprites, 1000);
    plots.record(.sprites, 1200);
    plots.record(.allocations, 3);

    try std.testing.expectEqual(@as(usize, 2), plots.of(.sprites).len);
    try std.testing.expectEqual(@as(f32, 1200), plots.of(.sprites).last());
    try std.testing.expectEqual(@as(f32, 3), plots.of(.allocations).last());
    try std.testing.expectEqual(@as(usize, 0), plots.of(.draw_calls).len);
}

test "a plot reports the nearest-rank p95 of its window" {
    var plots = Plots{};
    var value: f32 = 1;
    while (value <= 20) : (value += 1) plots.record(.draw_calls, value);
    // Nearest rank: ceil(0.95 * 20) = 19, the 19th smallest of the twenty samples.
    try std.testing.expectEqual(@as(f32, 19), plots.of(.draw_calls).percentile(0.95));
    try std.testing.expectEqual(@as(f32, 20), plots.of(.draw_calls).max());
}
