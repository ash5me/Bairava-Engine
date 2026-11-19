//! A short draw-time sprite flash composited as a second, unlit sprite quad.

const std = @import("std");

const sprite = @import("sprite.zig");
const Texture = @import("texture.zig").Texture;

pub const HitFlash = struct {
    color: [3]f32 = .{ 1, 1, 1 },
    duration: f32 = 0.12,
    remaining: f32 = 0,

    /// Starts or restarts the flash duration.
    pub fn trigger(self: *HitFlash) void {
        if (!std.math.isFinite(self.duration) or self.duration <= 0) {
            self.remaining = 0;
            return;
        }
        self.remaining = self.duration;
    }

    /// Advances the flash timer. Invalid or negative time leaves it unchanged.
    pub fn update(self: *HitFlash, dt: f32) void {
        if (!std.math.isFinite(dt) or dt < 0) return;
        if (!std.math.isFinite(self.remaining)) {
            self.remaining = 0;
            return;
        }
        self.remaining = @max(0, self.remaining - dt);
    }

    /// Returns the linear remaining strength in [0, 1].
    pub fn amount(self: *const HitFlash) f32 {
        if (!std.math.isFinite(self.duration) or self.duration <= 0 or
            !std.math.isFinite(self.remaining) or self.remaining <= 0)
        {
            return 0;
        }
        return std.math.clamp(self.remaining / self.duration, 0, 1);
    }
};

/// Queues the base sprite and, while active, a matching unlit overlay quad.
pub fn draw(
    batch: *sprite.SpriteBatch,
    texture: *const Texture,
    src: sprite.Rect,
    dst: sprite.Rect,
    opts: sprite.Options,
    flash: HitFlash,
) void {
    batch.drawSprite(texture, src, dst, opts);
    const strength = flash.amount();
    if (strength <= 0) return;

    var overlay = opts;
    overlay.tint = flash.color;
    overlay.alpha = opts.alpha * strength;
    overlay.normal = null;
    overlay.lit = false;
    batch.drawSprite(texture, src, dst, overlay);
}

test "hit flash trigger, duration, refresh, and expiry" {
    var flash = HitFlash{};
    try std.testing.expectEqual(@as(f32, 0), flash.amount());
    flash.trigger();
    try std.testing.expectEqual(@as(f32, 1), flash.amount());
    flash.update(flash.duration / 2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), flash.amount(), 1e-6);
    flash.trigger();
    try std.testing.expectEqual(@as(f32, 1), flash.amount());
    flash.update(flash.duration);
    try std.testing.expectEqual(@as(f32, 0), flash.amount());
    flash.update(1);
    try std.testing.expectEqual(@as(f32, 0), flash.remaining);
}

test "invalid hit flash duration and update time do not arm or advance" {
    var flash = HitFlash{ .duration = 0, .remaining = 0.1 };
    flash.trigger();
    try std.testing.expectEqual(@as(f32, 0), flash.remaining);
    try std.testing.expectEqual(@as(f32, 0), flash.amount());
    flash.duration = 0.12;
    flash.remaining = 0.08;
    flash.update(-1);
    try std.testing.expectEqual(@as(f32, 0.08), flash.remaining);
    flash.update(std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 0.08), flash.remaining);
    flash.duration = std.math.inf(f32);
    flash.trigger();
    try std.testing.expectEqual(@as(f32, 0), flash.remaining);
}

test "an inactive hit flash queues only the caller's unchanged sprite" {
    const fixtures = @import("../test_fixtures.zig");
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = fixtures.batch(&no_vertices, &no_batches);
    defer fixtures.freeBatch(&batch);
    batch.begin(100, 80);
    const texture = fixtures.texture(16, 16);
    const opts = sprite.Options{ .tint = .{ 1, 0.5, 0.5 }, .alpha = 0.7, .z = 4 };

    draw(&batch, &texture, .{ .x = 0, .y = 0, .w = 16, .h = 16 }, .{ .x = 10, .y = 12, .w = 16, .h = 16 }, opts, .{});
    try std.testing.expectEqual(@as(u32, 1), batch.sprite_count);
    batch.prepare();
    try std.testing.expectEqual([4]f32{ 1, 0.5, 0.5, 0.7 }, batch.vertices[0].color);
}

test "an active flash overlays the base tint with the requested color and alpha" {
    const fixtures = @import("../test_fixtures.zig");
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = fixtures.batch(&no_vertices, &no_batches);
    defer fixtures.freeBatch(&batch);
    batch.begin(100, 80);
    const texture = fixtures.texture(16, 16);
    const normal = fixtures.texture(16, 16);
    const src = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    const dst = sprite.Rect{ .x = 10, .y = 12, .w = 16, .h = 16 };
    const opts = sprite.Options{
        .tint = .{ 1, 0.5, 0.5 },
        .alpha = 0.8,
        .flip_x = true,
        .origin = .{ 8, 8 },
        .rotation = 0.25,
        .z = 4,
        .depth_y = 32,
        .normal = &normal,
        .lit = true,
    };
    draw(&batch, &texture, src, dst, opts, .{ .remaining = 0.12 });
    try std.testing.expectEqual(@as(u32, 2), batch.sprite_count);
    batch.prepare();

    try std.testing.expectEqual([4]f32{ 1, 0.5, 0.5, 0.8 }, batch.vertices[0].color);
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 0.8 }, batch.vertices[4].color);
    try std.testing.expectEqual(batch.vertices[0].pos, batch.vertices[4].pos);
    try std.testing.expectEqual(batch.vertices[0].uv, batch.vertices[4].uv);
    try std.testing.expectEqual(@as(usize, 2), batch.batch_count);
    try std.testing.expect(batch.batches[0].normal != null);
    try std.testing.expect(batch.batches[1].normal == null);
}

test "a half-strength overlay uses half the base alpha and retains painter order" {
    const fixtures = @import("../test_fixtures.zig");
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = fixtures.batch(&no_vertices, &no_batches);
    defer fixtures.freeBatch(&batch);
    batch.begin(100, 80);
    const texture = fixtures.texture(16, 16);
    const opts = sprite.Options{ .tint = .{ 1, 0.5, 0.5 }, .alpha = 0.6, .z = 7 };
    draw(
        &batch,
        &texture,
        .{ .x = 0, .y = 0, .w = 16, .h = 16 },
        .{ .x = 10, .y = 12, .w = 16, .h = 16 },
        opts,
        .{ .remaining = 0.06, .duration = 0.12 },
    );
    batch.prepare();
    try std.testing.expectEqual(@as(u32, 2), batch.sprite_count);
    try std.testing.expectEqual([4]f32{ 1, 0.5, 0.5, 0.6 }, batch.vertices[0].color);
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 0.3 }, batch.vertices[4].color);
}
