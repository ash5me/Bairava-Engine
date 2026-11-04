//! Value types the renderer and its SDL GPU backend share. Nothing in this file names an SDL type, so
//! engine code can use these values without importing the backend.

const std = @import("std");

/// An RGBA color, each channel from 0 to 1. Clear colors use it.
pub const Color = struct { r: f32, g: f32, b: f32, a: f32 };

/// A post-processing effect: one full-view pass over the image before it. Each one is a fragment shader in
/// shaders/default.slang, and backends/sdl_gpu/post.zig picks the shader for it.
pub const Effect = enum { grayscale, vignette, scanlines };

/// The most effects one post-processing chain may hold. Its passes are allocated when the chain is created.
pub const max_post_effects: usize = 8;

/// Settings every post-processing effect reads. Each value is a strength from 0 to 1. The four floats make one
/// 16-byte row, so the struct's bytes go to the GPU as they are. The layout matches `PostBlock` in shaders/default.slang.
pub const PostParams = extern struct {
    /// How far the corners fall toward black under the vignette. 0 turns the vignette off.
    vignette: f32,
    /// The brightness of the dimmed scanline rows. 1 leaves every row as bright as the rest.
    scanline_dim: f32,
    /// How much color the grayscale effect removes. 1 is full grayscale, and 0 leaves the image as it is.
    grayscale: f32,
    /// Unused. It fills the row to 16 bytes.
    padding: f32,
};

/// The settings the effects had before they could be changed, so a chain with the defaults looks as it always did.
pub const default_post_params = PostParams{ .vignette = 0.25, .scanline_dim = 0.8, .grayscale = 1, .padding = 0 };

/// Vertex layout for sprite quads. Positions are in normalized device coordinates. Color is RGBA:
/// the tint in RGB, and the sprite's alpha in A. `normal_basis` is the 2x2 matrix that turns a normal map's x
/// and y with the sprite's flip and rotation, stored row by row as [m00, m01, m10, m11]. All four corners of a
/// quad share it, and only lit sprites read it.
pub const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
    normal_basis: [4]f32,
};

/// A sprite is one quad: four vertices, drawn as two triangles through the index buffer.
pub const vertices_per_quad = 4;
pub const indices_per_quad = 6;
/// Indices are 32-bit, so one batch can hold any number of quads. 16-bit indices would cap a batch
/// at about 16 thousand.
pub const index_size = @sizeOf(u32);

/// The corners of one quad in the two triangles, as offsets into the quad's four vertices. drawSprite
/// writes the corners top-left, bottom-left, bottom-right, top-right, so these triangles are the ones
/// six separate vertices used to make.
pub const quad_corner_order = [indices_per_quad]usize{ 0, 1, 2, 0, 2, 3 };

/// The index the index buffer holds at position `k` of quad number `quad`. It is an absolute vertex
/// number in the frame's vertex storage, so a draw needs no base vertex. Each quad needs its own
/// numbers. A pattern shared by every quad would send a batch of many quads to the first quad's
/// vertices.
pub fn indexValue(quad: usize, k: usize) u32 {
    return @intCast(quad * vertices_per_quad + quad_corner_order[k]);
}

/// The capacity to grow to: `current` doubled, starting from at least 1, until it holds `needed`.
pub fn grownCapacity(current: usize, needed: usize) usize {
    var capacity = @max(current, 1);
    while (capacity < needed) capacity *= 2;
    return capacity;
}

/// The most lights one frame may place. The lights are uniform data, so this is also the array size in
/// `LightBlock` in shaders/default.slang, and the two must change together.
pub const max_lights: usize = 16;
/// The most shadow-casting line segments one frame may submit to the lit sprite shader.
pub const max_shadow_segments: usize = 16;

/// The uniform block lit sprites read: ambient light, point lights, and shadow segments. Every field is four floats,
/// so each row is 16 bytes and the struct's bytes can be pushed to the GPU as they are. The layout matches
/// `LightBlock` in shaders/default.slang, and a test checks the size.
pub const LightUniforms = extern struct {
    /// The ambient light as rgb, then an unused float. A fully lit sprite is at full brightness.
    ambient: [4]f32,
    /// Per light: x and y in view pixels, its height above the view in pixels, and its radius in pixels.
    position: [max_lights][4]f32,
    /// Per light: rgb, then the intensity multiplier.
    color: [max_lights][4]f32,
    /// Per segment: start xy and end xy, in view pixels.
    shadow_segment: [max_shadow_segments][4]f32,
    /// x holds the light count; y holds the shadow segment count.
    info: [4]f32,

    /// Clears every light and sets the ambient light to full brightness.
    pub fn reset(self: *LightUniforms) void {
        self.* = std.mem.zeroes(LightUniforms);
        self.ambient = .{ 1, 1, 1, 0 };
    }
};

test "the light block is the size its shader declares, in whole 16-byte rows" {
    // One ambient row, one info row, and rows for lights and shadow segments.
    try std.testing.expectEqual(@as(usize, 16 * (2 + 2 * max_lights + max_shadow_segments)), @sizeOf(LightUniforms));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(LightUniforms) % 16);
}

test "a reset light block has full ambient light and no lights" {
    var lights: LightUniforms = undefined;
    lights.reset();
    try std.testing.expectEqual(@as(f32, 1), lights.ambient[0]);
    try std.testing.expectEqual(@as(f32, 0), lights.info[0]);
    try std.testing.expectEqual(@as(f32, 0), lights.info[1]);
    try std.testing.expectEqual(@as(f32, 0), lights.position[max_lights - 1][3]);
    try std.testing.expectEqual(@as(f32, 0), lights.shadow_segment[max_shadow_segments - 1][3]);
}

test "the post settings are one 16-byte row, and the defaults keep the effects' original strengths" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PostParams));
    try std.testing.expectEqual(@as(f32, 0.25), default_post_params.vignette);
    try std.testing.expectEqual(@as(f32, 0.8), default_post_params.scanline_dim);
    try std.testing.expectEqual(@as(f32, 1), default_post_params.grayscale);
}
