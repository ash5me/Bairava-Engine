//! Positional audio: how loud a sound is at a distance from the listener, where it sits left to right, and how a
//! stereo stream is panned sample by sample. This is pure code with no SDL and no device, so `zig build test`
//! covers it. `audio.zig` uses these functions for its voices.
//!
//! The model suits a 2D game that measures in pixels:
//!   - Attenuation falls in a straight line from 1 at the listener to 0 at the range, and stays 0 beyond it.
//!   - Pan is the source's horizontal offset from the listener, divided by the range and clamped to [-1, 1]. A
//!     source a full range to the right pans fully right.
//!   - The channel gains are linear and unity at the center. The near ear keeps full level, the far ear fades as the
//!     pan grows, and nothing is boosted, so nothing clips.

const std = @import("std");
const builtin = @import("builtin");
const shapes = @import("../physics/shapes.zig");
const types = @import("../platform/types.zig");

/// A position in world pixels. Positional sounds and the listener use the same space.
pub const Point = shapes.Point;

/// The range a positional sound uses when its caller gives none, in pixels: ten tiles.
pub const default_range: f32 = 160;
/// The shortest range the math uses. A smaller one is raised to this.
pub const min_range: f32 = 1;

/// How loud a sound plays at one place, and where it sits.
pub const Mix = struct {
    /// From 0 (silent) to 1 (full level).
    attenuation: f32,
    /// From -1 (full left) to 1 (full right).
    pan: f32,
};

/// The gain of each of the first two channels of a stream, each from 0 to 1.
pub const ChannelGains = struct {
    left: f32,
    right: f32,
};

/// The range the math actually uses. A range that is not finite falls back to `default_range`, and a finite one is
/// raised to at least `min_range`.
pub fn usableRange(range: f32) f32 {
    if (!std.math.isFinite(range)) return default_range;
    return @max(range, min_range);
}

/// Clamps a pan to [-1, 1]. A pan that is not finite counts as center.
pub fn clampPan(pan: f32) f32 {
    if (!std.math.isFinite(pan)) return 0;
    return std.math.clamp(pan, -1.0, 1.0);
}

/// How a source at `source` sounds to a listener at `listener`. A source whose position is not finite is silent.
pub fn mix(listener: Point, source: Point, range: f32) Mix {
    const dx = source.x - listener.x;
    const dy = source.y - listener.y;
    const distance = @sqrt(dx * dx + dy * dy);
    if (!std.math.isFinite(distance)) return .{ .attenuation = 0, .pan = 0 };
    const r = usableRange(range);
    return .{
        .attenuation = std.math.clamp(1.0 - distance / r, 0.0, 1.0),
        .pan = std.math.clamp(dx / r, -1.0, 1.0),
    };
}

/// The gain of each channel for a pan. Linear and unity at the center: the near side keeps full level, and the far
/// side fades as the pan grows, reaching silence at full pan. A pan that is not finite counts as center.
pub fn channelGains(pan: f32) ChannelGains {
    const p = clampPan(pan);
    return .{
        .left = 1.0 - @max(p, 0.0),
        .right = 1.0 + @min(p, 0.0),
    };
}

/// True when panning changes the samples: the stream has two or more channels to pan between, and a gain is below 1.
pub fn needsPan(channels: u8, gains: ChannelGains) bool {
    return channels >= 2 and (gains.left != 1.0 or gains.right != 1.0);
}

/// Bytes one sample of `kind` takes up.
pub fn bytesPerSample(kind: types.SampleKind) usize {
    return switch (kind) {
        .uint8 => 1,
        .int16 => 2,
        .int32, .float32 => 4,
    };
}

/// Bytes in one frame: one sample for each channel.
pub fn frameBytes(format: types.PcmFormat) usize {
    return @as(usize, format.channels) * bytesPerSample(format.kind);
}

/// Copies `src` to `out`, scaling the first channel of each frame by `gains.left` and the second by `gains.right`.
/// Any further channels are copied unchanged, and mono data is copied unchanged, since it has no second channel to pan
/// between. Samples are read and written in the platform's byte order, which is how SDL stores them. Only the first
/// `min(out.len, src.len)` bytes are used, and a partial frame at the end is copied as it is.
pub fn applyChannelGains(out: []u8, src: []const u8, kind: types.SampleKind, channels: u8, gains: ChannelGains) void {
    const len = @min(out.len, src.len);
    @memcpy(out[0..len], src[0..len]);
    const width = bytesPerSample(kind);
    const frame = @as(usize, channels) * width;
    if (channels < 2 or frame == 0) return;
    var offset: usize = 0;
    while (offset + width <= len) : (offset += width) {
        const channel = (offset % frame) / width;
        if (channel >= 2) continue;
        const gain: f32 = if (channel == 0) gains.left else gains.right;
        scaleSample(out[offset..][0..width], kind, gain);
    }
}

const native_endian = builtin.cpu.arch.endian();

/// Multiplies one sample, stored in `bytes`, by `gain`, and rounds the result back into the sample's range.
fn scaleSample(bytes: []u8, kind: types.SampleKind, gain: f32) void {
    const g: f64 = gain;
    switch (kind) {
        .uint8 => {
            const centered = @as(f64, @floatFromInt(bytes[0])) - 128.0;
            bytes[0] = roundClamp(u8, centered * g + 128.0);
        },
        .int16 => {
            const value = std.mem.readInt(i16, bytes[0..2], native_endian);
            std.mem.writeInt(i16, bytes[0..2], roundClamp(i16, @as(f64, value) * g), native_endian);
        },
        .int32 => {
            const value = std.mem.readInt(i32, bytes[0..4], native_endian);
            std.mem.writeInt(i32, bytes[0..4], roundClamp(i32, @as(f64, value) * g), native_endian);
        },
        .float32 => {
            const value: f32 = @bitCast(std.mem.readInt(u32, bytes[0..4], native_endian));
            const scaled: u32 = @bitCast(value * gain);
            std.mem.writeInt(u32, bytes[0..4], scaled, native_endian);
        },
    }
}

/// Rounds half away from zero and clamps into `T`. NaN counts as zero.
fn roundClamp(comptime T: type, value: f64) T {
    if (!(value == value)) return 0;
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(std.math.maxInt(T));
    return @intFromFloat(std.math.clamp(@round(value), lo, hi));
}

// ---- tests ----

const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqualSlices = std.testing.expectEqualSlices;

test "attenuation falls linearly to silence at the range, and stays silent beyond it" {
    const listener = Point{ .x = 0, .y = 0 };
    try expectApproxEqAbs(@as(f32, 1.0), mix(listener, .{ .x = 0, .y = 0 }, 160).attenuation, 1e-6);
    try expectApproxEqAbs(@as(f32, 0.5), mix(listener, .{ .x = 80, .y = 0 }, 160).attenuation, 1e-6);
    // A 3-4-5 offset is 5 pixels away, whichever way it points.
    try expectApproxEqAbs(@as(f32, 1.0 - 5.0 / 160.0), mix(listener, .{ .x = 3, .y = 4 }, 160).attenuation, 1e-6);
    try expectEqual(@as(f32, 0), mix(listener, .{ .x = 160, .y = 0 }, 160).attenuation);
    try expectEqual(@as(f32, 0), mix(listener, .{ .x = 500, .y = 0 }, 160).attenuation);
}

test "pan follows the source's side, is full one range away, and is centered straight ahead" {
    const listener = Point{ .x = 0, .y = 0 };
    try expectApproxEqAbs(@as(f32, 0.5), mix(listener, .{ .x = 80, .y = 0 }, 160).pan, 1e-6);
    try expectApproxEqAbs(@as(f32, -1.0), mix(listener, .{ .x = -160, .y = 0 }, 160).pan, 1e-6);
    try expectEqual(@as(f32, 0), mix(listener, .{ .x = 0, .y = 50 }, 160).pan);
    try expectEqual(@as(f32, 1.0), mix(listener, .{ .x = 1000, .y = 0 }, 160).pan);
}

test "channel gains are unity at center, and the far ear fades to silence at full pan" {
    const center = channelGains(0);
    try expectEqual(@as(f32, 1.0), center.left);
    try expectEqual(@as(f32, 1.0), center.right);

    const hard_left = channelGains(-1);
    try expectEqual(@as(f32, 1.0), hard_left.left);
    try expectEqual(@as(f32, 0.0), hard_left.right);

    const hard_right = channelGains(1);
    try expectEqual(@as(f32, 0.0), hard_right.left);
    try expectEqual(@as(f32, 1.0), hard_right.right);

    const right_half = channelGains(0.5);
    try expectApproxEqAbs(@as(f32, 0.5), right_half.left, 1e-6);
    try expectEqual(@as(f32, 1.0), right_half.right);

    // Out-of-range and non-finite pans are clamped, and a non-finite pan counts as center.
    try expectEqual(@as(f32, 0.0), channelGains(7).left);
    const unknown = channelGains(std.math.nan(f32));
    try expectEqual(@as(f32, 1.0), unknown.left);
    try expectEqual(@as(f32, 1.0), unknown.right);
}

test "a range that is not finite uses the default, and a tiny one is raised to the minimum" {
    try expectEqual(default_range, usableRange(std.math.nan(f32)));
    try expectEqual(default_range, usableRange(std.math.inf(f32)));
    try expectEqual(min_range, usableRange(0));
    try expectEqual(@as(f32, 40), usableRange(40));

    const listener = Point{ .x = 0, .y = 0 };
    const with_nan = mix(listener, .{ .x = 80, .y = 0 }, std.math.nan(f32));
    try expectApproxEqAbs(@as(f32, 0.5), with_nan.attenuation, 1e-6);
}

test "a source without a finite position is silent" {
    const listener = Point{ .x = 0, .y = 0 };
    const lost = mix(listener, .{ .x = std.math.nan(f32), .y = 0 }, 160);
    try expectEqual(@as(f32, 0), lost.attenuation);
    try expectEqual(@as(f32, 0), lost.pan);
}

fn writeF32(bytes: []u8, value: f32) void {
    std.mem.writeInt(u32, bytes[0..4], @bitCast(value), native_endian);
}

fn readF32(bytes: []const u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[0..4], native_endian));
}

test "float samples are scaled per channel, and the stereo frame stays whole" {
    var src: [16]u8 = undefined;
    writeF32(src[0..4], 1.0);
    writeF32(src[4..8], 1.0);
    writeF32(src[8..12], 0.5);
    writeF32(src[12..16], -0.5);
    var out: [16]u8 = undefined;
    applyChannelGains(&out, &src, .float32, 2, .{ .left = 0.5, .right = 1.0 });
    try expectApproxEqAbs(@as(f32, 0.5), readF32(out[0..4]), 1e-6);
    try expectApproxEqAbs(@as(f32, 1.0), readF32(out[4..8]), 1e-6);
    try expectApproxEqAbs(@as(f32, 0.25), readF32(out[8..12]), 1e-6);
    try expectApproxEqAbs(@as(f32, -0.5), readF32(out[12..16]), 1e-6);
}

test "int16 samples are scaled and rounded half away from zero" {
    const native = native_endian;
    var src: [8]u8 = undefined;
    std.mem.writeInt(i16, src[0..2], 1000, native);
    std.mem.writeInt(i16, src[2..4], -1000, native);
    std.mem.writeInt(i16, src[4..6], 3, native);
    std.mem.writeInt(i16, src[6..8], 3, native);
    var out: [8]u8 = undefined;
    applyChannelGains(&out, &src, .int16, 2, .{ .left = 0.5, .right = 0.25 });
    try expectEqual(@as(i16, 500), std.mem.readInt(i16, out[0..2], native));
    try expectEqual(@as(i16, -250), std.mem.readInt(i16, out[2..4], native));
    // 3 times 0.5 is 1.5, which rounds away from zero to 2. The right channel is 3 times 0.25, which is 0.75, so 1.
    try expectEqual(@as(i16, 2), std.mem.readInt(i16, out[4..6], native));
    try expectEqual(@as(i16, 1), std.mem.readInt(i16, out[6..8], native));
}

test "uint8 samples are scaled around the midpoint" {
    var src = [_]u8{ 200, 56 };
    var out: [2]u8 = undefined;
    applyChannelGains(&out, &src, .uint8, 2, .{ .left = 0.5, .right = 1.0 });
    // (200 - 128) times 0.5 plus 128 is 164. The right channel is unity, so it keeps its value.
    try expectEqual(@as(u8, 164), out[0]);
    try expectEqual(@as(u8, 56), out[1]);
}

test "int32 samples scale at full precision, and channels past the second pass through" {
    const native = native_endian;
    var src: [12]u8 = undefined;
    std.mem.writeInt(i32, src[0..4], 1_000_000, native);
    std.mem.writeInt(i32, src[4..8], 1_000_000, native);
    std.mem.writeInt(i32, src[8..12], 1_000_000, native);
    var out: [12]u8 = undefined;
    applyChannelGains(&out, &src, .int32, 3, .{ .left = 0.5, .right = 0.25 });
    try expectEqual(@as(i32, 500_000), std.mem.readInt(i32, out[0..4], native));
    try expectEqual(@as(i32, 250_000), std.mem.readInt(i32, out[4..8], native));
    try expectEqual(@as(i32, 1_000_000), std.mem.readInt(i32, out[8..12], native));
}

test "mono data is copied unchanged, and needs no panning" {
    var src = [_]u8{ 1, 2, 3, 4 };
    var out: [4]u8 = undefined;
    applyChannelGains(&out, &src, .uint8, 1, .{ .left = 0.0, .right = 0.0 });
    try expectEqualSlices(u8, &src, &out);
    try expectEqual(false, needsPan(1, channelGains(-1)));
}

test "a centered stereo stream needs no panning, and a panned one does" {
    try expectEqual(false, needsPan(2, channelGains(0)));
    try expectEqual(true, needsPan(2, channelGains(-1)));
    try expectEqual(true, needsPan(2, channelGains(0.25)));
}
