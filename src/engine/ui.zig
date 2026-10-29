//! Text and widgets, bridged from the C code in src/engine/ui/. The C side builds quads in pixels,
//! all sampling one font atlas. This file loads preprocessed font assets when they match the
//! requested size, falls back to baking TTF data, and queues each quad as a sprite.

const sdl = @import("sdl.zig");
const sprite = @import("sprite.zig");
const profile = @import("profile.zig");
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
    uploaded_generation: u32,

    /// Loads a build-preprocessed font when present and baked at the requested size; otherwise it
    /// bakes the supplied TTF data. Both inputs are only read during this call.
    pub fn load(device: *sdl.c.SDL_GPUDevice, ttf: []const u8, prebaked: []const u8, pixel_height: f32) !Font {
        if (prebaked.len > 0) {
            var baked: c.ui_font = undefined;
            if (c.ui_font_load_prebaked(prebaked.ptr, prebaked.len, pixel_height, &baked) == 0) {
                var font = fromBaked(device, baked);
                try font.enableDynamic(ttf);
                return font;
            }
        }
        var font = try bake(device, ttf, pixel_height);
        try font.enableDynamic(ttf);
        return font;
    }

    /// Bakes TTF bytes at `pixel_height` pixels, then uploads the atlas. Use `load` when a matching
    /// build-time font asset may be available.
    pub fn bake(device: *sdl.c.SDL_GPUDevice, ttf: []const u8, pixel_height: f32) !Font {
        const zone = profile.zoneNamed(@src(), "bake font");
        defer zone.End();
        var baked: c.ui_font = undefined;
        if (c.ui_font_bake(ttf.ptr, ttf.len, pixel_height, first_codepoint, codepoint_count, &baked) != 0) {
            return error.BakeFailed;
        }
        return fromBaked(device, baked);
    }

    /// Bakes an SDF atlas from TTF bytes for smooth text scaling. `distance_range` sets the encoded
    /// distance range in pixels; eight pixels is a useful default for UI fonts.
    pub fn bakeSdf(device: *sdl.c.SDL_GPUDevice, ttf: []const u8, pixel_height: f32, distance_range: f32) !Font {
        const zone = profile.zoneNamed(@src(), "bake SDF font");
        defer zone.End();
        var baked: c.ui_font = undefined;
        if (c.ui_font_bake_sdf(ttf.ptr, ttf.len, pixel_height, first_codepoint, codepoint_count, distance_range, &baked) != 0) {
            return error.BakeFailed;
        }
        return fromBaked(device, baked);
    }

    /// Enables lazy rasterization for codepoints outside the baked range. The font bytes are copied
    /// into the C font object and kept until deinit.
    pub fn enableDynamic(self: *Font, ttf: []const u8) !void {
        if (c.ui_font_enable_dynamic(&self.baked, ttf.ptr, ttf.len) != 0) return error.DynamicFontFailed;
    }

    fn fromBaked(device: *sdl.c.SDL_GPUDevice, baked: c.ui_font) Font {
        const w: u32 = @intCast(baked.atlas_w);
        const h: u32 = @intCast(baked.atlas_h);
        const pixels = baked.rgba[0 .. @as(usize, w) * @as(usize, h) * 4];
        // initRgba8 copies the pixels into a transfer buffer before returning, so the C copy can go.
        const texture = if (baked.sdf != 0)
            Texture.initRgba8Linear(device, w, h, pixels)
        else
            Texture.initRgba8(device, w, h, pixels);
        return .{ .baked = baked, .texture = texture, .uploaded_generation = baked.atlas_generation };
    }

    fn refreshTexture(self: *Font) void {
        if (self.uploaded_generation == self.baked.atlas_generation) return;
        self.texture.deinit();
        const w: u32 = @intCast(self.baked.atlas_w);
        const h: u32 = @intCast(self.baked.atlas_h);
        const pixels = self.baked.rgba[0 .. @as(usize, w) * @as(usize, h) * 4];
        self.texture = if (self.baked.sdf != 0)
            Texture.initRgba8Linear(self.texture.device, w, h, pixels)
        else
            Texture.initRgba8(self.texture.device, w, h, pixels);
        self.uploaded_generation = self.baked.atlas_generation;
    }

    pub fn deinit(self: *Font) void {
        self.texture.deinit();
        c.ui_font_destroy(&self.baked);
    }
};

/// Queues each quad in `list` as one sprite on `batch`. A quad's `src` is its texel rectangle in
/// `texture`, its `dst` is its pixel rectangle, and the color's RGB and alpha become the sprite's
/// tint and alpha. `z` puts the UI above or below other sprites, as with any sprite.
pub fn queueQuads(batch: *sprite.SpriteBatch, font: *Font, list: *const c.ui_quad_list, z: i32) void {
    font.refreshTexture();
    const count: usize = @intCast(list.count);
    for (list.items[0..count]) |q| {
        batch.drawSprite(
            &font.texture,
            .{ .x = q.src.x, .y = q.src.y, .w = q.src.w, .h = q.src.h },
            .{ .x = q.dst.x, .y = q.dst.y, .w = q.dst.w, .h = q.dst.h },
            .{ .tint = .{ q.color.r, q.color.g, q.color.b }, .alpha = q.color.a, .z = z, .sdf = q.sdf != 0 },
        );
    }
}
