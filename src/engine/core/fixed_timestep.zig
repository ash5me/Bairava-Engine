const std = @import("std");

const max_frame_dt: f32 = 0.1;

pub const Accumulator = struct {
    fixed_dt: f32,
    remaining: f32 = 0,

    pub fn init(update_hz: u32) Accumulator {
        std.debug.assert(update_hz > 0);
        return .{ .fixed_dt = 1.0 / @as(f32, @floatFromInt(update_hz)) };
    }

    pub fn addFrameTime(self: *Accumulator, elapsed_seconds: f32) f32 {
        const frame_dt = @min(elapsed_seconds, max_frame_dt);
        self.remaining += frame_dt;
        return frame_dt;
    }

    pub fn hasStep(self: *const Accumulator) bool {
        return self.remaining >= self.fixed_dt;
    }

    pub fn consumeStep(self: *Accumulator) void {
        self.remaining -= self.fixed_dt;
    }

    pub fn interpolationAlpha(self: *const Accumulator) f32 {
        return @min(self.remaining / self.fixed_dt, 1.0);
    }
};

test "fixed timestep waits for a complete step and returns the configured delta" {
    var accumulator = Accumulator.init(60);
    const half_step = accumulator.fixed_dt / 2.0;

    _ = accumulator.addFrameTime(half_step);
    try std.testing.expect(!accumulator.hasStep());
    _ = accumulator.addFrameTime(half_step);
    try std.testing.expect(accumulator.hasStep());
    try std.testing.expectApproxEqAbs(1.0 / 60.0, accumulator.fixed_dt, 1e-6);

    accumulator.consumeStep();
    try std.testing.expect(!accumulator.hasStep());
    try std.testing.expectApproxEqAbs(@as(f32, 0), accumulator.interpolationAlpha(), 1e-6);
}

test "fixed timestep consumes multiple steps and preserves the fractional remainder" {
    var accumulator = Accumulator.init(40);
    _ = accumulator.addFrameTime(0.0625);

    var steps: u32 = 0;
    while (accumulator.hasStep()) {
        accumulator.consumeStep();
        steps += 1;
    }

    try std.testing.expectEqual(@as(u32, 2), steps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), accumulator.interpolationAlpha(), 1e-5);
}

test "fixed timestep clamps long frames and bounds interpolation alpha" {
    var accumulator = Accumulator.init(60);
    const accepted_dt = accumulator.addFrameTime(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), accepted_dt, 1e-6);

    var steps: u32 = 0;
    while (accumulator.hasStep()) {
        accumulator.consumeStep();
        steps += 1;
    }

    try std.testing.expect(steps > 0);
    try std.testing.expect(steps <= 6);
    const alpha = accumulator.interpolationAlpha();
    try std.testing.expect(alpha >= 0.0 and alpha <= 1.0);
}
