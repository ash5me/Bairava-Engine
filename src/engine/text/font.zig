//! Fonts on the GPU. A font is baked from TTF data at a pixel height, or loaded from the build's
//! preprocessed `.bfnt` sidecar when that matches. Its glyph atlas is uploaded as one texture, and
//! `refreshTexture` uploads it again when a lazily rasterized glyph grows the atlas.

const c = @import("../ui/c.zig").c;
<<<<<<< HEAD
const std = @import("std");
const platform = @import("../platform/platform.zig");
const profile = @import("../profiling/profile.zig");
const texture = @import("../renderer/texture.zig");
const Texture = texture.Texture;
=======
const platform = @import("../platform/platform.zig");
const profile = @import("../profiling/profile.zig");
const Texture = @import("../renderer/texture.zig").Texture;
>>>>>>> main

/// The first codepoint baked, and how many. 32 to 255 covers printable ASCII and Latin-1.
const first_codepoint: c_int = 32;
const codepoint_count: c_int = 224;


/// A font on the GPU: the baked metrics and glyphs from C, plus the atlas texture they sample.
pub const Font = struct {
    /// Metrics and glyphs, owned by the C side. Pass `&font.baked` to C functions.
    baked: c.ui_font,
    texture: Texture,
    uploaded_generation: u32,

<<<<<<< HEAD
=======
    /// Loads a build-preprocessed font when present and baked at the requested size; otherwise it
    /// bakes the supplied TTF data. Both inputs are only read during this call.
    pub fn load(device: *platform.gpu.Device, ttf: []const u8, prebaked: []const u8, pixel_height: f32) !Font {
        if (prebaked.len > 0) {
            var baked: c.ui_font = undefined;
            if (c.ui_font_load_prebaked(prebaked.ptr, prebaked.len, pixel_height, &baked) == 0) {
                var font = fromBaked(device, baked);
                // Dynamic glyphs are rasterized from the TTF. Without it, codepoints outside the
                // baked range draw blank, and the prebaked font is still usable.
                if (ttf.len > 0) try font.enableDynamic(ttf);
                return font;
            }
        }
        var font = try bake(device, ttf, pixel_height);
        try font.enableDynamic(ttf);
        return font;
    }

    /// Bakes TTF bytes at `pixel_height` pixels, then uploads the atlas. Use `load` when a matching
    /// build-time font asset may be available.
    pub fn bake(device: *platform.gpu.Device, ttf: []const u8, pixel_height: f32) !Font {
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
    pub fn bakeSdf(device: *platform.gpu.Device, ttf: []const u8, pixel_height: f32, distance_range: f32) !Font {
        const zone = profile.zoneNamed(@src(), "bake SDF font");
        defer zone.End();
        var baked: c.ui_font = undefined;
        if (c.ui_font_bake_sdf(ttf.ptr, ttf.len, pixel_height, first_codepoint, codepoint_count, distance_range, &baked) != 0) {
            return error.BakeFailed;
        }
        return fromBaked(device, baked);
    }

>>>>>>> main
    /// Enables lazy rasterization for codepoints outside the baked range. The font bytes are copied
    /// into the C font object and kept until deinit.
    pub fn enableDynamic(self: *Font, ttf: []const u8) !void {
        if (c.ui_font_enable_dynamic(&self.baked, ttf.ptr, ttf.len) != 0) return error.DynamicFontFailed;
    }

<<<<<<< HEAD
=======
    fn fromBaked(device: *platform.gpu.Device, baked: c.ui_font) Font {
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

>>>>>>> main
    pub fn refreshTexture(self: *Font) void {
        if (self.uploaded_generation == self.baked.atlas_generation) return;
        self.texture.deinit();
        const w: u32 = @intCast(self.baked.atlas_w);
        const h: u32 = @intCast(self.baked.atlas_h);
        const pixels = self.baked.rgba[0 .. @as(usize, w) * @as(usize, h) * 4];
<<<<<<< HEAD
        texture.updateRgba8(&self.texture, w, h, pixels, self.baked.sdf != 0);
=======
        self.texture = if (self.baked.sdf != 0)
            Texture.initRgba8Linear(self.texture.device, w, h, pixels)
        else
            Texture.initRgba8(self.texture.device, w, h, pixels);
>>>>>>> main
        self.uploaded_generation = self.baked.atlas_generation;
    }

    pub fn deinit(self: *Font) void {
        self.texture.deinit();
        c.ui_font_destroy(&self.baked);
    }
};

<<<<<<< HEAD
/// Loads a build-preprocessed font when present, otherwise baking the supplied TTF bytes.
pub fn load(allocator: std.mem.Allocator, device: *platform.gpu.Device, ttf: []const u8, prebaked: []const u8, pixel_height: f32) !Font {
    if (prebaked.len > 0) {
        var baked: c.ui_font = undefined;
        if (c.ui_font_load_prebaked(prebaked.ptr, prebaked.len, pixel_height, &baked) == 0) {
            var loaded = fromBaked(allocator, device, baked);
            if (ttf.len > 0) try loaded.enableDynamic(ttf);
            return loaded;
        }
    }
    var baked = try bake(allocator, device, ttf, pixel_height);
    try baked.enableDynamic(ttf);
    return baked;
}

pub fn bake(allocator: std.mem.Allocator, device: *platform.gpu.Device, ttf: []const u8, pixel_height: f32) !Font {
    const zone = profile.zoneNamed(@src(), "bake font");
    defer zone.End();
    var baked: c.ui_font = undefined;
    if (c.ui_font_bake(ttf.ptr, ttf.len, pixel_height, first_codepoint, codepoint_count, &baked) != 0) return error.BakeFailed;
    return fromBaked(allocator, device, baked);
}

pub fn bakeSdf(allocator: std.mem.Allocator, device: *platform.gpu.Device, ttf: []const u8, pixel_height: f32, distance_range: f32) !Font {
    const zone = profile.zoneNamed(@src(), "bake SDF font");
    defer zone.End();
    var baked: c.ui_font = undefined;
    if (c.ui_font_bake_sdf(ttf.ptr, ttf.len, pixel_height, first_codepoint, codepoint_count, distance_range, &baked) != 0) return error.BakeFailed;
    return fromBaked(allocator, device, baked);
}

fn fromBaked(allocator: std.mem.Allocator, device: *platform.gpu.Device, baked: c.ui_font) Font {
    const width: u32 = @intCast(baked.atlas_w);
    const height: u32 = @intCast(baked.atlas_h);
    const pixels = baked.rgba[0 .. @as(usize, width) * height * 4];
    const atlas_texture = if (baked.sdf != 0)
        texture.createRgba8Linear(allocator, device, width, height, pixels)
    else
        texture.createRgba8(allocator, device, width, height, pixels);
    return .{ .baked = baked, .texture = atlas_texture, .uploaded_generation = baked.atlas_generation };
}
=======
>>>>>>> main
