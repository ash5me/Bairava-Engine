//! Text and widgets, bridged from the C code in src/engine/ui/. The C side builds quads in pixels,
//! all sampling one font atlas. This file bakes the font onto the GPU and queues each quad as a
//! sprite, so text and widgets draw through the same batch as everything else.

const sdl = @import("sdl.zig");
const sprite = @import("sprite.zig");
const Texture = @import("texture.zig").Texture;

pub const c = @cImport({
    @cInclude("imgui.h");
});

/// The first codepoint baked, and how many. 32 to 255 covers printable ASCII and Latin-1.
const first_codepoint: c_int = 32;
const codepoint_count: c_int = 224;

/// A font on the GPU: the baked metrics and glyphs from C, plus the atlas texture they sample.
pub const Font = struct {
    /// Metrics and glyphs, owned by the C side. Pass `&font.baked` to C functions.
    baked: c.ui_font,
    texture: Texture,

    /// Bakes the TTF bytes at `pixel_height` pixels, then uploads the atlas. The bytes are only read
    /// during this call, so the caller may free them afterward.
    pub fn bake(device: *sdl.c.SDL_GPUDevice, ttf: []const u8, pixel_height: f32) !Font {
        var baked: c.ui_font = undefined;
        if (c.ui_font_bake(ttf.ptr, ttf.len, pixel_height, first_codepoint, codepoint_count, &baked) != 0) {
            return error.BakeFailed;
        }
        const w: u32 = @intCast(baked.atlas_w);
        const h: u32 = @intCast(baked.atlas_h);
        const pixels = baked.rgba[0 .. @as(usize, w) * @as(usize, h) * 4];
        // initRgba8 copies the pixels into a transfer buffer before returning, so the C copy can go.
        return .{ .baked = baked, .texture = Texture.initRgba8(device, w, h, pixels) };
    }

    pub fn deinit(self: *Font) void {
        self.texture.deinit();
        c.ui_font_destroy(&self.baked);
    }
};

/// Queues each quad in `list` as one sprite on `batch`. A quad's `src` is its texel rectangle in
/// `texture`, its `dst` is its pixel rectangle, and the color's RGB and alpha become the sprite's
/// tint and alpha. `z` puts the UI above or below other sprites, as with any sprite.
pub fn queueQuads(batch: *sprite.SpriteBatch, texture: *const Texture, list: *const c.ui_quad_list, z: i32) void {
    const count: usize = @intCast(list.count);
    for (list.items[0..count]) |q| {
        batch.drawSprite(
            texture,
            .{ .x = q.src.x, .y = q.src.y, .w = q.src.w, .h = q.src.h },
            .{ .x = q.dst.x, .y = q.dst.y, .w = q.dst.w, .h = q.dst.h },
            .{ .tint = .{ q.color.r, q.color.g, q.color.b }, .alpha = q.color.a, .z = z },
        );
    }
}
