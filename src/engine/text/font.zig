//! Fonts on the GPU. A font is a prebaked `.bfnt` file that the asset builder wrote from a TTF or OTF
//! (tools/assets/font_bake.c). Loading parses that file and uploads its glyph atlas once. Nothing here
//! rasterizes outlines, so a character the font was not baked with draws as '?'.

const std = @import("std");
const c = @import("../ui/c.zig").c;
const platform = @import("../platform/platform.zig");
const texture = @import("../renderer/texture.zig");
const Texture = texture.Texture;

/// A font on the GPU: the baked metrics and glyphs from C, plus the atlas texture they sample.
pub const Font = struct {
    /// Metrics, kerning, and glyphs, owned by the C side. Pass `&font.baked` to C functions.
    baked: c.ui_font,
    texture: Texture,

    pub fn deinit(self: *Font) void {
        self.texture.deinit();
        c.ui_font_destroy(&self.baked);
    }
};

/// CPU-side font result. Creating its GPU texture must happen on the main thread. Parsing the file may run
/// on a worker, because this type does not touch GPU objects.
pub const Staged = struct {
    baked: c.ui_font,

    pub fn upload(self: Staged, allocator: std.mem.Allocator, device: *platform.gpu.Device) Font {
        return fromBaked(allocator, device, self.baked);
    }

    pub fn deinit(self: *Staged) void {
        c.ui_font_destroy(&self.baked);
        self.* = undefined;
    }
};

/// Parses a prebaked `.bfnt` file on the calling CPU thread. No GPU resource is created. The file must have been
/// baked at exactly `pixel_height`. Any other size, or a malformed file, is an error.
pub fn stage(prebaked: []const u8, pixel_height: f32) error{InvalidFont}!Staged {
    if (prebaked.len == 0) return error.InvalidFont;
    var baked: c.ui_font = undefined;
    if (c.ui_font_load_prebaked(prebaked.ptr, prebaked.len, pixel_height, &baked) != 0) return error.InvalidFont;
    return .{ .baked = baked };
}

fn fromBaked(allocator: std.mem.Allocator, device: *platform.gpu.Device, baked: c.ui_font) Font {
    const width: u32 = @intCast(baked.atlas_w);
    const height: u32 = @intCast(baked.atlas_h);
    const pixels = baked.rgba[0 .. @as(usize, width) * height * 4];
    return .{ .baked = baked, .texture = texture.createRgba8(allocator, device, width, height, pixels) };
}
