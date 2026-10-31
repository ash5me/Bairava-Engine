//! Linear algebra through cglm. This is the only file that imports cglm's headers. The rest of
//! the engine uses the plain types and functions here, so a change to cglm touches one file.
//!
//! Conventions follow cglm. Vectors are arrays of `f32`. Matrices are column-major, so
//! `m[column][row]`, and a point is transformed as `m * v`. Quaternions are `[x, y, z, w]`, which
//! is cglm's versor layout. Angles are in radians.
//!
//! Projections are right-handed: a camera looks down -Z. Depth runs from 0 at the near plane to 1
//! at the far plane. That is the clip space SDL_GPU uses on every backend, and it is set by
//! CGLM_FORCE_DEPTH_ZERO_TO_ONE below. If build.zig compiles cglm's C sources, give them the same
//! define, so cglm's exported `glmc_` functions use the same depth range as the translated headers.
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
    // Depth from 0 (near) to 1 (far), as SDL_GPU expects. Affects perspective and ortho depth only.
    @cDefine("CGLM_FORCE_DEPTH_ZERO_TO_ONE", "1");
    @cInclude("cglm/cglm.h");
    // The exported (non-inline) versions, compiled by build.zig. Used only by a test that checks
    // they agree with the translated headers.
    @cInclude("cglm/call.h");
});

pub const Vec2 = [2]f32;
pub const Vec3 = [3]f32;
pub const Vec4 = [4]f32;
pub const Mat4 = [4][4]f32;
/// A unit quaternion for a rotation, stored as `[x, y, z, w]`.
pub const Quat = [4]f32;

/// Below this length, a cross product is treated as zero when choosing a fallback axis.
const parallel_epsilon: f32 = 1e-6;

// ----------------------------------------------------------------------------- matrices

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

/// The inverse of `m`. A singular matrix has no inverse, and the result is meaningless for it.
pub fn invert(m: Mat4) Mat4 {
    var src = m;
    var out: Mat4 = undefined;
    c.glm_mat4_inv(&src, &out);
    return out;
}

/// The transpose of `m`. For a rotation, the transpose is also the inverse.
pub fn transpose(m: Mat4) Mat4 {
    var out = m;
    c.glm_mat4_transpose(&out);
    return out;
}

// ----------------------------------------------------------------------------- transforms

/// A translation by `v`.
pub fn translate3d(v: Vec3) Mat4 {
    var m: Mat4 = undefined;
    var offset = v;
    c.glm_translate_make(&m, &offset);
    return m;
}

/// A translation by `(x, y)` in the plane z = 0.
pub fn translate2d(x: f32, y: f32) Mat4 {
    return translate3d(.{ x, y, 0.0 });
}

/// A scale by `s` along each axis.
pub fn scale3d(s: Vec3) Mat4 {
    var m: Mat4 = undefined;
    var factors = s;
    c.glm_scale_make(&m, &factors);
    return m;
}

/// A rotation by `angle` radians around `axis`, which must have length 1. Positive angles follow
/// the right-hand rule: looking back along the axis toward the origin, they turn counter-clockwise.
pub fn rotate3d(axis: Vec3, angle: f32) Mat4 {
    var m: Mat4 = undefined;
    var a = axis;
    c.glm_rotate_make(&m, angle, &a);
    return m;
}

/// A rotation by `angle` radians around the z axis. With the pixel projection below, which flips
/// y, positive angles look clockwise on screen.
pub fn rotateZ(angle: f32) Mat4 {
    return rotate3d(.{ 0.0, 0.0, 1.0 }, angle);
}

// ----------------------------------------------------------------------------- projections

/// An orthographic projection of the box with x from `left` to `right`, y from `bottom` to `top`,
/// and depth from `near` to `far`. Depths are distances in front of the camera, as for
/// `perspective`. Passing `bottom` above `top` flips y.
pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
    var m: Mat4 = undefined;
    c.glm_ortho(left, right, bottom, top, near, far, &m);
    return m;
}

/// The 2D pixel projection for a `width` by `height` view. `(0, 0)` is the top-left corner and
/// `(width, height)` is the bottom-right corner. The output is x right and y up, in normalized
/// device coordinates. The sprite shader sets depth itself, so the depth range here doesn't matter
/// for sprites.
pub fn ortho2d(width: f32, height: f32) Mat4 {
    // Passing bottom = height and top = 0 flips y, so y grows downward on screen.
    return orthographic(0.0, width, height, 0.0, 0.0, 1.0);
}

/// A perspective projection with a vertical field of view of `fovy` radians. Points `near` and
/// `far` units in front of the camera map to depth 0 and 1. `aspect` is width divided by height.
pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat4 {
    var m: Mat4 = undefined;
    c.glm_perspective(fovy, aspect, near, far, &m);
    return m;
}

/// The view matrix for a camera at `eye` looking at `target`. `up` is the world's up direction and
/// must not be parallel to the view direction.
pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
    var e = eye;
    var t = target;
    var u = up;
    var m: Mat4 = undefined;
    c.glm_lookat(&e, &t, &u, &m);
    return m;
}

// ----------------------------------------------------------------------------- points

/// Applies `m` to a homogeneous point and returns all four components, without a divide by w.
pub fn transformVec4(m: *const Mat4, v: Vec4) Vec4 {
    var matrix = m.*;
    var point = v;
    var out: Vec4 = undefined;
    c.glm_mat4_mulv(&matrix, &point, &out);
    return out;
}

/// Applies `m` to the point `(x, y, 0)` and returns the x and y of the result after the perspective
/// divide. For affine and orthographic matrices w stays 1, so the divide changes nothing. Points
/// behind a perspective camera have negative w and come out flipped, so clip them first.
pub fn transformPoint(m: *const Mat4, x: f32, y: f32) Vec2 {
    const h = transformVec4(m, .{ x, y, 0.0, 1.0 });
    return .{ h[0] / h[3], h[1] / h[3] };
}

/// Applies `m` to the point `p` and divides by w. For a projection matrix the result is in
/// normalized device coordinates, with depth in [0, 1] for points between the near and far planes.
pub fn transformPoint3(m: *const Mat4, p: Vec3) Vec3 {
    const h = transformVec4(m, .{ p[0], p[1], p[2], 1.0 });
    return .{ h[0] / h[3], h[1] / h[3], h[2] / h[3] };
}

// ----------------------------------------------------------------------------- 2D vectors

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

// ----------------------------------------------------------------------------- 3D vectors

pub fn add3(a: Vec3, b: Vec3) Vec3 {
    var x = a;
    var y = b;
    var out: Vec3 = undefined;
    c.glm_vec3_add(&x, &y, &out);
    return out;
}

pub fn sub3(a: Vec3, b: Vec3) Vec3 {
    var x = a;
    var y = b;
    var out: Vec3 = undefined;
    c.glm_vec3_sub(&x, &y, &out);
    return out;
}

pub fn scale3(v: Vec3, s: f32) Vec3 {
    var x = v;
    var out: Vec3 = undefined;
    c.glm_vec3_scale(&x, s, &out);
    return out;
}

pub fn dot3(a: Vec3, b: Vec3) f32 {
    var x = a;
    var y = b;
    return c.glm_vec3_dot(&x, &y);
}

/// The cross product `a x b`. It is perpendicular to both inputs, and its length is the area of
/// the parallelogram they span.
pub fn cross3(a: Vec3, b: Vec3) Vec3 {
    var x = a;
    var y = b;
    var out: Vec3 = undefined;
    c.glm_vec3_cross(&x, &y, &out);
    return out;
}

pub fn length3(v: Vec3) f32 {
    var work = v;
    return c.glm_vec3_norm(&work);
}

/// `v` scaled to length 1. A zero vector comes back as zero, not NaN.
pub fn normalize3OrZero(v: Vec3) Vec3 {
    var work = v;
    if (c.glm_vec3_norm(&work) == 0.0) return .{ 0.0, 0.0, 0.0 };
    c.glm_vec3_normalize(&work);
    return work;
}

// ----------------------------------------------------------------------------- quaternions

pub fn quatIdentity() Quat {
    var q: Quat = undefined;
    c.glm_quat_identity(&q);
    return q;
}

/// A rotation by `angle` radians around `axis`. The axis is normalized first, and a zero axis
/// gives the identity.
pub fn quatFromAxisAngle(axis: Vec3, angle: f32) Quat {
    const unit = normalize3OrZero(axis);
    if (dot3(unit, unit) == 0.0) return quatIdentity();
    var a = unit;
    var q: Quat = undefined;
    c.glm_quatv(&q, angle, &a);
    return q;
}

/// The rotation `a * b`. Applied to a vector, it rotates by `b` first, then by `a`. That is the
/// same order `mul` uses for matrices, so `quatToMat4(quatMul(a, b))` equals
/// `mul(quatToMat4(a), quatToMat4(b))`.
pub fn quatMul(a: Quat, b: Quat) Quat {
    var left = a;
    var right = b;
    var out: Quat = undefined;
    c.glm_quat_mul(&left, &right, &out);
    return out;
}

/// The reverse of a unit quaternion's rotation. Multiplying a quaternion by its conjugate gives
/// the identity.
pub fn quatConjugate(q: Quat) Quat {
    var src = q;
    var out: Quat = undefined;
    c.glm_quat_conjugate(&src, &out);
    return out;
}

/// `q` scaled to length 1. A zero quaternion isn't a rotation, so it comes back as the identity.
pub fn quatNormalize(q: Quat) Quat {
    var work = q;
    if (c.glm_quat_norm(&work) == 0.0) return quatIdentity();
    c.glm_quat_normalize(&work);
    return work;
}

/// Rotates `v` by the unit quaternion `q`.
pub fn quatRotate(q: Quat, v: Vec3) Vec3 {
    var src = q;
    var point = v;
    var out: Vec3 = undefined;
    c.glm_quat_rotatev(&src, &point, &out);
    return out;
}

/// Interpolates from `a` to `b` by `t`, where 0 gives `a` and 1 gives `b`. The interpolation
/// follows the shorter arc, even when the two quaternions are on opposite sides of the sphere.
pub fn quatSlerp(a: Quat, b: Quat, t: f32) Quat {
    var from = a;
    // A quaternion and its negation are the same rotation. Flipping `b` into the same hemisphere
    // as `a` keeps the interpolation on the shorter arc.
    const d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
    var to = if (d < 0.0) Quat{ -b[0], -b[1], -b[2], -b[3] } else b;
    var out: Quat = undefined;
    c.glm_quat_slerp(&from, &to, t, &out);
    return out;
}

/// The 4x4 rotation matrix for `q`.
pub fn quatToMat4(q: Quat) Mat4 {
    var src = q;
    var m: Mat4 = undefined;
    c.glm_quat_mat4(&src, &m);
    return m;
}

/// The unit quaternion for the rotation part of `m`. `m` should be a pure rotation, with no scale
/// or shear, or the result is not a rotation.
pub fn quatFromMat4(m: Mat4) Quat {
    var src = m;
    var q: Quat = undefined;
    c.glm_mat4_quat(&src, &q);
    return q;
}

/// The rotation that points local -Z along `forward`, which is the direction a camera looks in.
/// Local +X ends up to the right, and local +Y is as close to `up` as the rotation allows.
/// `forward` must not be zero.
pub fn lookRotation(forward: Vec3, up: Vec3) Quat {
    const f = normalize3OrZero(forward);
    // A side vector perpendicular to `f`. If `up` is parallel to `f`, fall back to another axis.
    var side = cross3(f, up);
    if (length3(side) < parallel_epsilon) side = cross3(f, .{ 1.0, 0.0, 0.0 });
    if (length3(side) < parallel_epsilon) side = cross3(f, .{ 0.0, 0.0, 1.0 });
    side = normalize3OrZero(side);
    const u = cross3(side, f);
    // Each column is where a local axis ends up. Local Z is -f, so the view direction is -Z.
    const m: Mat4 = .{
        .{ side[0], side[1], side[2], 0.0 },
        .{ u[0], u[1], u[2], 0.0 },
        .{ -f[0], -f[1], -f[2], 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
    };
    return quatFromMat4(m);
}

/// The orientation for a sprite at `object` that faces the camera at `camera`. Local +Z points at
/// the camera. Pass the world's up for an upright (cylindrical) billboard, or the camera's own up
/// for a sprite aligned with the screen.
pub fn billboard(object: Vec3, camera: Vec3, up: Vec3) Quat {
    return lookRotation(sub3(object, camera), up);
}

// ----------------------------------------------------------------------------- tests

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

test "length3, normalize3OrZero, dot3 and cross3" {
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), length3(.{ 2.0, 3.0, 6.0 }), 1e-6);

    const unit = normalize3OrZero(.{ 2.0, 3.0, 6.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 7.0), unit[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0 / 7.0), unit[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0 / 7.0), unit[2], 1e-6);

    const zero = normalize3OrZero(.{ 0.0, 0.0, 0.0 });
    try std.testing.expectEqual(@as(f32, 0.0), zero[2]);

    try std.testing.expectApproxEqAbs(@as(f32, 8.0), dot3(.{ 1.0, 2.0, 3.0 }, .{ 2.0, 0.0, 2.0 }), 1e-6);

    const z_axis = cross3(.{ 1.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), z_axis[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), z_axis[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), z_axis[2], 1e-6);
}

test "invert undoes a transform" {
    const axis = normalize3OrZero(.{ 0.0, 1.0, 1.0 });
    const m = mul(translate3d(.{ 1.0, -2.0, 3.0 }), mul(rotate3d(axis, 0.6), scale3d(.{ 2.0, 2.0, 2.0 })));
    const product = mul(m, invert(m));
    const id = identity();
    for (0..4) |col| {
        for (0..4) |row| {
            try std.testing.expectApproxEqAbs(id[col][row], product[col][row], 1e-5);
        }
    }
}

test "perspective maps the near plane to depth 0 and the far plane to depth 1" {
    const m = perspective(std.math.pi / 3.0, 16.0 / 9.0, 0.5, 50.0);
    const near_pt = transformPoint3(&m, .{ 0.0, 0.0, -0.5 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), near_pt[2], 1e-5);
    const far_pt = transformPoint3(&m, .{ 0.0, 0.0, -50.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), far_pt[2], 1e-5);
}

test "perspective divides by w, so the edge of the view lands on the edge of clip space" {
    // With a 90 degree vertical field of view and square aspect, the view's half-width at a
    // distance of 2 is 2, so the corner (2, 2, -2) is at the corner of clip space.
    const m = perspective(std.math.pi / 2.0, 1.0, 1.0, 10.0);
    const corner = transformPoint3(&m, .{ 2.0, 2.0, -2.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corner[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corner[1], 1e-5);
}

test "cglm's exported perspective matches perspective(), so build.zig and math.zig agree on depth" {
    // The exported glmc_* functions come from the C library that build.zig compiles. The wrappers
    // use the translated headers. If the two were built with different depth ranges, these would
    // differ in the depth row.
    var exported: Mat4 = undefined;
    c.glmc_perspective(std.math.pi / 3.0, 16.0 / 9.0, 0.5, 50.0, &exported);
    const ours = perspective(std.math.pi / 3.0, 16.0 / 9.0, 0.5, 50.0);
    for (0..4) |col| {
        for (0..4) |row| {
            try std.testing.expectApproxEqAbs(ours[col][row], exported[col][row], 1e-6);
        }
    }
}

test "lookAt puts the target straight ahead and keeps world +X on the camera's right" {
    // The camera at (0, 0, 5) looks down -Z. The origin is 5 units ahead, and world +X is to the right.
    const view = lookAt(.{ 0.0, 0.0, 5.0 }, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
    const origin = transformPoint3(&view, .{ 0.0, 0.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), origin[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), origin[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), origin[2], 1e-6);

    const right = transformPoint3(&view, .{ 1.0, 0.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), right[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), right[2], 1e-6);
}

test "quaternion rotation agrees with the matrix built from the same quaternion" {
    const q = quatFromAxisAngle(.{ 1.0, 2.0, 3.0 }, 0.7);
    const v = Vec3{ 0.3, -1.2, 2.0 };
    const by_quat = quatRotate(q, v);
    const by_mat = transformPoint3(&quatToMat4(q), v);
    try std.testing.expectApproxEqAbs(by_mat[0], by_quat[0], 1e-5);
    try std.testing.expectApproxEqAbs(by_mat[1], by_quat[1], 1e-5);
    try std.testing.expectApproxEqAbs(by_mat[2], by_quat[2], 1e-5);
}

test "quatMul composes rotations in the same order as mul" {
    const a = quatFromAxisAngle(.{ 0.0, 0.0, 1.0 }, 0.4);
    const b = quatFromAxisAngle(.{ 1.0, 0.0, 0.0 }, 1.1);

    const via_quat = quatToMat4(quatMul(a, b));
    const via_mat = mul(quatToMat4(a), quatToMat4(b));
    for (0..4) |col| {
        for (0..4) |row| {
            try std.testing.expectApproxEqAbs(via_mat[col][row], via_quat[col][row], 1e-5);
        }
    }

    // Applied to a vector: b first, then a.
    const v = Vec3{ 0.5, 1.0, -0.25 };
    const direct = quatRotate(quatMul(a, b), v);
    const stepwise = quatRotate(a, quatRotate(b, v));
    try std.testing.expectApproxEqAbs(stepwise[0], direct[0], 1e-5);
    try std.testing.expectApproxEqAbs(stepwise[1], direct[1], 1e-5);
    try std.testing.expectApproxEqAbs(stepwise[2], direct[2], 1e-5);

    // A rotation times its conjugate is the identity.
    const back = quatMul(a, quatConjugate(a));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), back[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), back[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), back[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), back[3], 1e-6);
}

test "quatFromAxisAngle with a zero axis is the identity" {
    const q = quatFromAxisAngle(.{ 0.0, 0.0, 0.0 }, 1.0);
    try std.testing.expectEqual(@as(f32, 1.0), q[3]);
    try std.testing.expectEqual(@as(f32, 0.0), q[0]);
}

test "quatSlerp halfway takes the shorter arc, even for the negated quaternion" {
    const a = quatIdentity();
    const b = quatFromAxisAngle(.{ 0.0, 1.0, 0.0 }, std.math.pi / 2.0);
    // The same rotation as `b`, with the quaternion negated. Interpolating must not take the long way.
    const b_negated = Quat{ -b[0], -b[1], -b[2], -b[3] };
    const halfway = quatSlerp(a, b_negated, 0.5);
    const expected = quatFromAxisAngle(.{ 0.0, 1.0, 0.0 }, std.math.pi / 4.0);

    const probe = Vec3{ 1.0, 0.0, 0.0 };
    const got = quatRotate(halfway, probe);
    const want = quatRotate(expected, probe);
    try std.testing.expectApproxEqAbs(want[0], got[0], 1e-5);
    try std.testing.expectApproxEqAbs(want[1], got[1], 1e-5);
    try std.testing.expectApproxEqAbs(want[2], got[2], 1e-5);
}

test "lookRotation points local -Z along forward and keeps local +X on the right" {
    // Looking down +X with +Y up, the camera's right-hand side is +Z (forward x up = X x Y = Z).
    const q = lookRotation(.{ 1.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });

    const along = quatRotate(q, .{ 0.0, 0.0, -1.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), along[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), along[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), along[2], 1e-5);

    const right = quatRotate(q, .{ 1.0, 0.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), right[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), right[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), right[2], 1e-5);

    const up_axis = quatRotate(q, .{ 0.0, 1.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), up_axis[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), up_axis[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), up_axis[2], 1e-5);
}

test "billboard turns the sprite's front toward the camera" {
    const object = Vec3{ 3.0, 1.0, -2.0 };
    const camera = Vec3{ -4.0, 2.0, 6.0 };
    const q = billboard(object, camera, .{ 0.0, 1.0, 0.0 });

    const front = quatRotate(q, .{ 0.0, 0.0, 1.0 });
    const want = normalize3OrZero(sub3(camera, object));
    try std.testing.expectApproxEqAbs(want[0], front[0], 1e-5);
    try std.testing.expectApproxEqAbs(want[1], front[1], 1e-5);
    try std.testing.expectApproxEqAbs(want[2], front[2], 1e-5);
}
