//! Linear algebra through cglm. This is the only file that imports cglm's headers. The rest of
//! the engine uses the plain types and functions here, so a change to cglm touches one file.
//!
//! Conventions follow cglm. Vectors are arrays of `f32`. Matrices are column-major, so
//! `m[column][row]`, and a point is transformed as `m * v`. Angles are in radians.
//!
//! build.zig builds cglm with `CGLM_ALL_UNALIGNED` and without its SIMD paths. Without the first,
//! cglm assumes 16-byte alignment, which Zig arrays don't guarantee. Without the second, the
//! translated headers and the compiled C use the same portable code. This file never imports SDL
//! or the logger.

const std = @import("std");

const c = @cImport({
    // Match build.zig: no SIMD paths, so the translated headers and the compiled C agree.
    @cUndef("__SSE__");
    @cUndef("__SSE2__");
    @cUndef("__SSE3__");
    @cUndef("__SSE4_1__");
    @cUndef("__SSE4_2__");
    @cUndef("__AVX__");
    @cUndef("__ARM_NEON");
    @cUndef("__ARM_NEON__");
    @cUndef("__wasm_simd128__");
    @cDefine("CGLM_ALL_UNALIGNED", "1");
    @cInclude("cglm/cglm.h");
});

pub const Vec2 = [2]f32;
pub const Vec4 = [4]f32;
pub const Mat4 = [4][4]f32;

pub fn identity() Mat4 {
    var m: Mat4 = undefined;
    c.glm_mat4_identity(&m);
    return m;
}

/// The matrix `a * b`. Applying the result to a point is the same as applying `b` first, then `a`.
pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var left = a;
    var right = b;
    var out: Mat4 = undefined;
    c.glm_mat4_mul(&left, &right, &out);
    return out;
}

/// A translation by `(x, y)` in the plane z = 0.
pub fn translate2d(x: f32, y: f32) Mat4 {
    var m: Mat4 = undefined;
    var offset = [3]f32{ x, y, 0.0 };
    c.glm_translate_make(&m, &offset);
    return m;
}

/// A rotation by `angle` radians around the z axis. With the pixel projection below, which
/// flips y, positive angles look clockwise on screen.
pub fn rotateZ(angle: f32) Mat4 {
    var m: Mat4 = undefined;
    var axis = [3]f32{ 0.0, 0.0, 1.0 };
    c.glm_rotate_make(&m, angle, &axis);
    return m;
}

/// The projection from pixel space to normalized device coordinates for a `width` by `height`
/// view. `(0, 0)` is the top-left corner and `(width, height)` is the bottom-right corner. The
/// result is x right and y up, with z set to 0 by the sprite shader, so depth isn't used.
pub fn ortho2d(width: f32, height: f32) Mat4 {
    var m: Mat4 = undefined;
    // Passing bottom = height and top = 0 flips y, so y grows downward on screen.
    c.glm_ortho(0.0, width, height, 0.0, -1.0, 1.0, &m);
    return m;
}

/// Applies `m` to the point `(x, y, 0, 1)` and returns the x and y of the result. For affine
/// and orthographic matrices the result's w stays 1, so no divide is needed.
pub fn transformPoint(m: *const Mat4, x: f32, y: f32) Vec2 {
    var matrix = m.*;
    var point = Vec4{ x, y, 0.0, 1.0 };
    var out: Vec4 = undefined;
    c.glm_mat4_mulv(&matrix, &point, &out);
    return .{ out[0], out[1] };
}

/// The length of `v`.
pub fn length2(v: Vec2) f32 {
    var work = v;
    return c.glm_vec2_norm(&work);
}

/// `v` scaled to length 1. A zero vector is returned unchanged, not as NaN, so callers can pass
/// input straight through without checking it first.
pub fn normalizeOrZero(v: Vec2) Vec2 {
    var work = v;
    if (c.glm_vec2_norm(&work) == 0.0) return .{ 0.0, 0.0 };
    c.glm_vec2_normalize(&work);
    return work;
}

test "identity leaves points unchanged" {
    const p = transformPoint(&identity(), 3.5, -2.0);
    try std.testing.expectEqual(@as(f32, 3.5), p[0]);
    try std.testing.expectEqual(@as(f32, -2.0), p[1]);
}

test "ortho2d maps the corners of the view to the corners of clip space" {
    const m = ortho2d(320.0, 180.0);
    const top_left = transformPoint(&m, 0.0, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), top_left[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), top_left[1], 1e-6);

    const bottom_right = transformPoint(&m, 320.0, 180.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), bottom_right[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), bottom_right[1], 1e-6);

    const center = transformPoint(&m, 160.0, 90.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), center[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), center[1], 1e-6);
}

test "ortho2d matches the pixel-to-NDC formula the sprite batch used before" {
    // This is the formula that sprite.zig used before the projection matrix, so this test
    // shows the change preserves where every pixel lands.
    const widths = [_]f32{ 320.0, 960.0, 1280.0, 777.0 };
    const heights = [_]f32{ 180.0, 540.0, 720.0, 433.0 };
    for (widths, heights) |w, h| {
        const m = ortho2d(w, h);
        var step: f32 = 0.0;
        while (step <= 1.0) : (step += 0.125) {
            const x = w * step;
            const y = h * (1.0 - step);
            const got = transformPoint(&m, x, y);
            const want_x = x / w * 2.0 - 1.0;
            const want_y = 1.0 - y / h * 2.0;
            try std.testing.expectApproxEqAbs(want_x, got[0], 1e-5);
            try std.testing.expectApproxEqAbs(want_y, got[1], 1e-5);
        }
    }
}

test "mul applies the right-hand matrix first" {
    // Scale-then-translate and translate-then-scale give different points, which is how the
    // order is checked.
    var scale = identity();
    scale[0][0] = 2.0;
    scale[1][1] = 2.0;
    const translate = translate2d(10.0, 0.0);

    // translate * scale: scale first, so (1, 1) -> (2, 2) -> (12, 2).
    const ts = mul(translate, scale);
    const a = transformPoint(&ts, 1.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), a[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), a[1], 1e-6);

    // scale * translate: translate first, so (1, 1) -> (11, 1) -> (22, 2).
    const st = mul(scale, translate);
    const b = transformPoint(&st, 1.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 22.0), b[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), b[1], 1e-6);
}

test "rotateZ turns a point a quarter turn counter-clockwise in the math convention" {
    const m = rotateZ(std.math.pi / 2.0);
    const p = transformPoint(&m, 1.0, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), p[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), p[1], 1e-6);
}

test "length2 and normalizeOrZero" {
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), length2(.{ 3.0, 4.0 }), 1e-6);

    const unit = normalizeOrZero(.{ 3.0, 4.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), unit[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), unit[1], 1e-6);

    const diagonal = normalizeOrZero(.{ 1.0, 1.0 });
    const expected = 1.0 / @sqrt(2.0);
    try std.testing.expectApproxEqAbs(@as(f32, expected), diagonal[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, expected), diagonal[1], 1e-6);

    // A cardinal direction already has length 1, so it comes back unchanged.
    const cardinal = normalizeOrZero(.{ 0.0, -1.0 });
    try std.testing.expectEqual(@as(f32, 0.0), cardinal[0]);
    try std.testing.expectEqual(@as(f32, -1.0), cardinal[1]);

    // The zero vector comes back as zero, not NaN.
    const zero = normalizeOrZero(.{ 0.0, 0.0 });
    try std.testing.expectEqual(@as(f32, 0.0), zero[0]);
    try std.testing.expectEqual(@as(f32, 0.0), zero[1]);
}
