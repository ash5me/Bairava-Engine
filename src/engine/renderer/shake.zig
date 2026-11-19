//! Deterministic draw-time camera shake driven by game-owned trauma.

const std = @import("std");

pub const Shake = struct {
    trauma: f32 = 0,
    max_offset: f32 = 8,
    frequency: f32 = 18,
    decay: f32 = 1.6,
    seed: u64 = 1,
    phase: f32 = 0,

    /// Adds trauma from an overlapping event, clamped to the supported range.
    pub fn add(self: *Shake, amount: f32) void {
        if (!std.math.isFinite(amount) or amount < 0) return;
        const current = if (std.math.isFinite(self.trauma)) std.math.clamp(self.trauma, 0, 1) else 0;
        self.trauma = @min(1, current + amount);
    }

    /// Advances shake once per draw. Invalid or negative frame times leave it unchanged.
    pub fn update(self: *Shake, dt: f32) void {
        if (!std.math.isFinite(dt) or dt < 0) return;

        const phase_step = self.frequency * dt;
        const next_phase = self.phase + phase_step;
        if (std.math.isFinite(self.frequency) and std.math.isFinite(next_phase)) self.phase = next_phase;

        if (!std.math.isFinite(self.trauma)) {
            self.trauma = 0;
            return;
        }
        const safe_decay = if (std.math.isFinite(self.decay)) self.decay else 0;
        self.trauma = std.math.clamp(self.trauma - safe_decay * dt, 0, 1);
    }

    /// Samples deterministic, smoothly interpolated value noise on two independent axes.
    pub fn sample(self: *const Shake) [2]f32 {
        if (!std.math.isFinite(self.trauma) or self.trauma <= 0 or
            !std.math.isFinite(self.max_offset) or self.max_offset == 0 or
            !std.math.isFinite(self.phase))
        {
            return .{ 0, 0 };
        }
        const amplitude = self.trauma * self.trauma * self.max_offset;
        if (!std.math.isFinite(amplitude) or amplitude == 0) return .{ 0, 0 };
        return .{
            axisNoise(self.seed, self.phase, 0xA0761D6478BD642F) * amplitude,
            axisNoise(self.seed, self.phase, 0xE7037ED1A0B428DB) * amplitude,
        };
    }
};

fn axisNoise(seed: u64, phase: f32, salt: u64) f32 {
    const whole = @floor(phase);
    const fraction = phase - whole;
    const blend = fraction * fraction * (3 - 2 * fraction);
    const index = phaseIndex(whole);
    const first = hashUnit(seed, index, salt);
    const second = hashUnit(seed, index +% 1, salt);
    return first + (second - first) * blend;
}

fn phaseIndex(whole: f32) i64 {
    const value: f64 = whole;
    const max: f64 = @floatFromInt(std.math.maxInt(i64));
    const min: f64 = @floatFromInt(std.math.minInt(i64));
    if (value >= max) return std.math.maxInt(i64);
    if (value <= min) return std.math.minInt(i64);
    return @intFromFloat(value);
}

fn hashUnit(seed: u64, index: i64, salt: u64) f32 {
    var value = seed ^ @as(u64, @bitCast(index)) ^ salt;
    value +%= 0x9E3779B97F4A7C15;
    value = (value ^ (value >> 30)) *% 0xBF58476D1CE4E5B9;
    value = (value ^ (value >> 27)) *% 0x94D049BB133111EB;
    value ^= value >> 31;
    const unit: f32 = @as(f32, @floatFromInt(value >> 40)) / 16777215.0;
    return unit * 2 - 1;
}

test "zero trauma and zero amplitude produce exactly zero offset" {
    var shake = Shake{ .phase = 12.75 };
    try std.testing.expectEqual([2]f32{ 0, 0 }, shake.sample());
    shake.trauma = 1;
    shake.max_offset = 0;
    try std.testing.expectEqual([2]f32{ 0, 0 }, shake.sample());
}

test "trauma additions stack, clamp, and ignore invalid values" {
    var shake = Shake{};
    shake.add(0.4);
    shake.add(0.4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), shake.trauma, 1e-6);
    shake.add(5);
    try std.testing.expectEqual(@as(f32, 1), shake.trauma);
    shake.add(std.math.nan(f32));
    shake.add(-1);
    try std.testing.expectEqual(@as(f32, 1), shake.trauma);
}

test "decay clears full trauma and leaves it at zero" {
    var shake = Shake{ .trauma = 1, .decay = 1 };
    var i: u32 = 0;
    while (i < 4) : (i += 1) shake.update(0.25);
    try std.testing.expectEqual(@as(f32, 0), shake.trauma);
    shake.update(0.25);
    try std.testing.expectEqual(@as(f32, 0), shake.trauma);
}

test "shake amplitude is quadratic in trauma" {
    var full = Shake{ .trauma = 1, .phase = 4.375 };
    var half = full;
    half.trauma = 0.5;
    const full_sample = full.sample();
    const half_sample = half.sample();
    try std.testing.expectApproxEqAbs(full_sample[0] * 0.25, half_sample[0], 1e-6);
    try std.testing.expectApproxEqAbs(full_sample[1] * 0.25, half_sample[1], 1e-6);
}

test "shake samples are deterministic by seed and phase sequence" {
    var first = Shake{ .trauma = 0.9, .seed = 123 };
    var same = first;
    var different = first;
    different.seed += 1;
    var differed = false;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const a = first.sample();
        const b = same.sample();
        const c = different.sample();
        try std.testing.expectEqual(a, b);
        if (a[0] != c[0] or a[1] != c[1]) differed = true;
        first.update(1.0 / 60.0);
        same.update(1.0 / 60.0);
        different.update(1.0 / 60.0);
    }
    try std.testing.expect(differed);
}

test "invalid update time leaves phase and trauma unchanged" {
    var shake = Shake{ .trauma = 0.75, .phase = 3.5 };
    shake.update(-1);
    try std.testing.expectEqual(@as(f32, 0.75), shake.trauma);
    try std.testing.expectEqual(@as(f32, 3.5), shake.phase);
    shake.update(std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 0.75), shake.trauma);
    try std.testing.expectEqual(@as(f32, 3.5), shake.phase);
}

test "offset camera use does not change the follow smoothing origin" {
    const Camera = @import("camera.zig").Camera;
    var camera = Camera{ .x = 100, .y = 120, .view_w = 40, .view_h = 40, .world_w = 1000, .world_h = 1000 };
    camera.placed = true;
    const draw_camera = camera.offset(7, -5);
    try std.testing.expectEqual(@as(f32, 107), draw_camera.x);
    try std.testing.expectEqual(@as(f32, 115), draw_camera.y);
    camera.followSmooth(300, 300, 0.1, 2);
    try std.testing.expect(camera.x > 100 and camera.x < 300);
    try std.testing.expect(camera.y > 120 and camera.y < 300);
}
