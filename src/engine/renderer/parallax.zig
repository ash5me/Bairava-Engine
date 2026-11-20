//! Repeating background planes queued through SpriteBatch. This module owns no textures or update state.

const std = @import("std");

const camera = @import("camera.zig");
const sprite = @import("sprite.zig");
const Texture = @import("texture.zig").Texture;

const max_plane_quads: usize = 4096;

pub const Plane = struct {
    scroll: camera.Scroll = .{},
    /// Texels sampled for every copy. The texture sampler clamps at the atlas edge.
    src: sprite.Rect,
    /// View-pixel size of each copy.
    period_w: f32,
    period_h: f32,
    repeat_x: bool = true,
    repeat_y: bool = true,
    /// Layer-space top-left when the matching axis does not repeat.
    anchor_x: f32 = 0,
    anchor_y: f32 = 0,
    z: i32 = 0,
    tint: [3]f32 = .{ 1, 1, 1 },
    alpha: f32 = 1,
};

const AxisCopies = struct {
    first: f32,
    count: usize,
};

/// Queues enough copies to cover the view, with one extra copy beyond each edge.
pub fn drawPlane(batch: *sprite.SpriteBatch, texture: *const Texture, cam: *const camera.Camera, plane: Plane) void {
    if (!std.math.isFinite(cam.view_w) or !std.math.isFinite(cam.view_h) or cam.view_w <= 0 or cam.view_h <= 0) {
        std.debug.panic("parallax plane period {d}x{d} has invalid view size {d}x{d}", .{
            plane.period_w, plane.period_h, cam.view_w, cam.view_h,
        });
    }
    validatePeriod(plane.period_w, cam.view_w, plane.repeat_x);
    validatePeriod(plane.period_h, cam.view_h, plane.repeat_y);
    if ((!plane.repeat_x and !std.math.isFinite(plane.anchor_x)) or
        (!plane.repeat_y and !std.math.isFinite(plane.anchor_y)))
    {
        std.debug.panic("parallax plane period {d}x{d} has a non-finite anchor for view {d}x{d}", .{
            plane.period_w, plane.period_h, cam.view_w, cam.view_h,
        });
    }

    const layer_cam = cam.scrolled(plane.scroll);
    const layer_view = layer_cam.viewRect();
    const xs = axisCopies(layer_view.x, layer_view.w, plane.period_w, plane.repeat_x, plane.anchor_x);
    const ys = axisCopies(layer_view.y, layer_view.h, plane.period_h, plane.repeat_y, plane.anchor_y);
    if (xs.count > max_plane_quads / ys.count) {
        std.debug.panic("parallax plane period {d}x{d} exceeds {d} quads for view {d}x{d}", .{
            plane.period_w, plane.period_h, max_plane_quads, cam.view_w, cam.view_h,
        });
    }

    var y_index: usize = 0;
    while (y_index < ys.count) : (y_index += 1) {
        const layer_y = if (plane.repeat_y)
            ys.first + @as(f32, @floatFromInt(y_index)) * plane.period_h
        else
            plane.anchor_y;
        var x_index: usize = 0;
        while (x_index < xs.count) : (x_index += 1) {
            const layer_x = if (plane.repeat_x)
                xs.first + @as(f32, @floatFromInt(x_index)) * plane.period_w
            else
                plane.anchor_x;
            batch.drawSprite(texture, plane.src, .{
                .x = layer_cam.screenX(layer_x),
                .y = layer_cam.screenY(layer_y),
                .w = plane.period_w,
                .h = plane.period_h,
            }, .{
                .z = plane.z,
                .tint = plane.tint,
                .alpha = plane.alpha,
            });
        }
    }
}

fn validatePeriod(period: f32, view_size: f32, repeats: bool) void {
    if (!std.math.isFinite(period) or period <= 0 or (repeats and (period < 1 or period != @floor(period)))) {
        std.debug.panic("parallax plane period {d} must be positive and integer-valued when repeating (view {d})", .{
            period, view_size,
        });
    }
}

fn axisCopies(origin: f32, view_size: f32, period: f32, repeats: bool, anchor: f32) AxisCopies {
    if (!repeats) return .{ .first = anchor, .count = 1 };

    const periods_in_view = @ceil(view_size / period);
    if (!std.math.isFinite(periods_in_view) or periods_in_view > @as(f32, @floatFromInt(max_plane_quads - 2))) {
        std.debug.panic("parallax plane period {d} exceeds {d} quads for view {d}", .{
            period, max_plane_quads, view_size,
        });
    }
    const count: usize = @intFromFloat(periods_in_view + 2);
    const first = @floor(origin / period) * period - period;
    return .{ .first = first, .count = count };
}

test "repeating planes cover the view with seam-free integer periods" {
    const fixtures = @import("../test_fixtures.zig");
    const test_sprite = @import("sprite.zig");
    const test_camera = @import("camera.zig").Camera;
    var no_vertices: [0]test_sprite.Vertex = .{};
    var no_batches: [0]test_sprite.Batch = .{};
    var batch = fixtures.batch(&no_vertices, &no_batches);
    defer fixtures.freeBatch(&batch);
    const tex = fixtures.texture(16, 16);
    const view_w: f32 = 64;

    const camera_xs = [_]f32{ 0, 5.25, 100.5, -22.3 };
    for (camera_xs) |camera_x| {
        batch.begin(view_w, 40);
        const cam = test_camera{
            .x = camera_x,
            .y = 7.5,
            .view_w = view_w,
            .view_h = 40,
            .world_w = 512,
            .world_h = 256,
        };
        drawPlane(&batch, &tex, &cam, .{
            .scroll = .{ .factor_x = 0.5 },
            .src = .{ .x = 0, .y = 0, .w = 16, .h = 16 },
            .period_w = 16,
            .period_h = 16,
            .repeat_y = false,
        });
        try std.testing.expectEqual(@as(u32, 6), batch.sprite_count);
        batch.prepare();
        try std.testing.expectEqual(@as(usize, 24), batch.vertex_count);

        var lefts: [6]f32 = undefined;
        for (0..lefts.len) |quad_index| {
            const vertex = batch.vertices[quad_index * 4];
            lefts[quad_index] = (vertex.pos[0] + 1) * view_w / 2;
        }
        for (1..lefts.len) |index| {
            try std.testing.expectApproxEqAbs(@as(f32, 16), lefts[index] - lefts[index - 1], 0.001);
        }
        var pixel: usize = 0;
        while (pixel < @as(usize, @intFromFloat(view_w))) : (pixel += 1) {
            var covered = false;
            for (lefts) |left| {
                if (@as(f32, @floatFromInt(pixel)) >= left and
                    @as(f32, @floatFromInt(pixel)) < left + 16)
                {
                    covered = true;
                    break;
                }
            }
            try std.testing.expect(covered);
        }
    }
}

test "a non-repeating plane emits one anchored quad" {
    const fixtures = @import("../test_fixtures.zig");
    const test_sprite = @import("sprite.zig");
    const test_camera = @import("camera.zig").Camera;
    var no_vertices: [0]test_sprite.Vertex = .{};
    var no_batches: [0]test_sprite.Batch = .{};
    var batch = fixtures.batch(&no_vertices, &no_batches);
    defer fixtures.freeBatch(&batch);
    batch.begin(64, 40);
    const tex = fixtures.texture(16, 16);
    const cam = test_camera{ .view_w = 64, .view_h = 40, .world_w = 64, .world_h = 40 };
    drawPlane(&batch, &tex, &cam, .{
        .src = .{ .x = 0, .y = 0, .w = 16, .h = 16 },
        .period_w = 32,
        .period_h = 20,
        .repeat_x = false,
        .repeat_y = false,
        .anchor_x = 9,
        .anchor_y = 11,
    });
    try std.testing.expectEqual(@as(u32, 1), batch.sprite_count);
    batch.prepare();
    const left = (batch.vertices[0].pos[0] + 1) * 64 / 2;
    const top = (1 - batch.vertices[0].pos[1]) * 40 / 2;
    try std.testing.expectApproxEqAbs(@as(f32, 9), left, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 11), top, 0.001);
}
