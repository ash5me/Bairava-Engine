//! Fonts on the GPU. A font is a prebaked `.bfnt` file that the asset builder wrote from a TTF or OTF
//! (tools/assets/font_bake.c). Loading parses that file and uploads its glyph atlas once. Nothing here
//! rasterizes outlines, so a character the font was not baked with draws the fallback the file records
//! (normally '?'), or nothing when the font records none.

const std = @import("std");
const c = @import("../ui/c.zig").c;
const platform = @import("../platform/platform.zig");
const texture = @import("../renderer/texture.zig");
const runtime_font = @import("runtime_font.zig");
const shaper = @import("shaper.zig");
const Texture = texture.Texture;

/// A font on the GPU: the baked metrics and glyphs from C, plus the atlas texture they sample. The CPU atlas remains
/// resident so the GPU texture can be rebuilt after a renderer-resource reset.
pub const Font = struct {
    /// Metrics, kerning, and glyphs, owned by the C side. Pass `&font.baked` to C functions.
    baked: c.ui_font,
    texture: Texture,

    pub fn recreateGpuResources(self: *Font, allocator: std.mem.Allocator, device: *platform.gpu.Device) void {
        const pixels = self.baked.alpha orelse @panic("BFNT CPU atlas was released before GPU recreation");
        const width: u32 = @intCast(self.baked.atlas_w);
        const height: u32 = @intCast(self.baked.atlas_h);
        const replacement = texture.createCoverage(allocator, device, width, height, pixels[0 .. @as(usize, width) * height]);
        self.texture.deinit();
        self.texture = replacement;
    }

    pub fn deinit(self: *Font) void {
        self.texture.deinit();
        c.ui_font_destroy(&self.baked);
    }
};

/// An offline MFNT font: a glyph-ID table, HarfBuzz face, GPU MSDF atlas, and SDL3 2D coverage sibling.
pub const MsdfFont = struct {
    baked: c.ui_font,
    msdf_texture: Texture,
    coverage_texture: Texture,
    face: runtime_font.RuntimeFont,
    shaper: ?shaper.Shaper = null,

    pub fn recreateGpuResources(self: *MsdfFont, allocator: std.mem.Allocator, device: *platform.gpu.Device) void {
        const texels = @as(usize, @intCast(self.baked.atlas_w)) * @as(usize, @intCast(self.baked.atlas_h));
        const msdf_pixels = self.baked.msdf_rgba orelse @panic("MSDF CPU atlas was released before GPU recreation");
        const coverage_pixels = self.baked.alpha orelse @panic("MSDF coverage atlas was released before GPU recreation");
        const width: u32 = @intCast(self.baked.atlas_w);
        const height: u32 = @intCast(self.baked.atlas_h);
        const replacement_msdf = texture.createMsdf(allocator, device, width, height, msdf_pixels[0 .. texels * 4], self.baked.px_range);
        const replacement_coverage = texture.createCoverage(allocator, device, width, height, coverage_pixels[0..texels]);
        self.msdf_texture.deinit();
        self.coverage_texture.deinit();
        self.msdf_texture = replacement_msdf;
        self.coverage_texture = replacement_coverage;
        self.msdf_texture.sdl2d_fallback = &self.coverage_texture;
    }

    pub fn deinit(self: *MsdfFont) void {
        self.msdf_texture.deinit();
        self.coverage_texture.deinit();
        if (self.shaper) |*value| value.deinit();
        self.face.deinit();
        c.ui_font_destroy(&self.baked);
        self.* = undefined;
    }
};

/// CPU-side font result. Creating its GPU texture must happen on the main thread. Parsing the file may run
/// on a worker, because this type does not touch GPU objects.
pub const Staged = struct {
    baked: c.ui_font,

    /// Uploads the atlas and returns the font. It consumes `self`: the font takes over the metrics, glyphs, and
    /// kerning, so `self` must not be used or deinitialized afterward.
    pub fn upload(self: *Staged, allocator: std.mem.Allocator, device: *platform.gpu.Device) Font {
        const loaded = fromBaked(allocator, device, self.baked);
        self.* = undefined;
        return loaded;
    }

    pub fn deinit(self: *Staged) void {
        c.ui_font_destroy(&self.baked);
        self.* = undefined;
    }
};

pub const MsdfStaged = struct {
    baked: c.ui_font,

    pub fn upload(
        self: *MsdfStaged,
        allocator: std.mem.Allocator,
        device: *platform.gpu.Device,
    ) (runtime_font.Error || error{InvalidFont})!MsdfFont {
        if (self.baked.is_msdf == 0 or self.baked.px_range != 4.0 or self.baked.source_bytes == null or
            self.baked.source_len == 0 or self.baked.msdf_rgba == null or self.baked.alpha == null)
        {
            c.ui_font_destroy(&self.baked);
            self.* = undefined;
            return error.InvalidFont;
        }
        var face = runtime_font.RuntimeFont.init(
            allocator,
            self.baked.source_bytes[0..self.baked.source_len],
            self.baked.pixel_height,
        ) catch |err| {
            c.ui_font_destroy(&self.baked);
            self.* = undefined;
            return err;
        };
        errdefer face.deinit();
        if (face.glyph_count != @as(u32, @intCast(self.baked.count))) {
            c.ui_font_destroy(&self.baked);
            self.* = undefined;
            return error.InvalidFont;
        }
        const width: u32 = @intCast(self.baked.atlas_w);
        const height: u32 = @intCast(self.baked.atlas_h);
        const texels = @as(usize, width) * height;
        const msdf_pixels = self.baked.msdf_rgba[0 .. texels * 4];
        const coverage_pixels = self.baked.alpha[0..texels];
        const msdf_texture = texture.createMsdf(allocator, device, width, height, msdf_pixels, self.baked.px_range);
        const coverage_texture = texture.createCoverage(allocator, device, width, height, coverage_pixels);
        allocator.free(self.baked.source_bytes[0..self.baked.source_len]);
        self.baked.source_bytes = null;
        self.baked.source_len = 0;
        const baked = self.baked;
        self.* = undefined;
        return .{
            .baked = baked,
            .msdf_texture = msdf_texture,
            .coverage_texture = coverage_texture,
            .face = face,
        };
    }

    pub fn deinit(self: *MsdfStaged) void {
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
    if (baked.is_msdf != 0) {
        c.ui_font_destroy(&baked);
        return error.InvalidFont;
    }
    return .{ .baked = baked };
}

pub fn stageMsdf(prebaked: []const u8, pixel_height: f32) error{InvalidFont}!MsdfStaged {
    if (prebaked.len == 0) return error.InvalidFont;
    var baked: c.ui_font = undefined;
    if (c.ui_font_load_prebaked(prebaked.ptr, prebaked.len, pixel_height, &baked) != 0) return error.InvalidFont;
    if (baked.is_msdf == 0) {
        c.ui_font_destroy(&baked);
        return error.InvalidFont;
    }
    return .{ .baked = baked };
}

fn fromBaked(allocator: std.mem.Allocator, device: *platform.gpu.Device, baked: c.ui_font) Font {
    const width: u32 = @intCast(baked.atlas_w);
    const height: u32 = @intCast(baked.atlas_h);
    const pixels = baked.alpha[0 .. @as(usize, width) * height];
    const atlas = texture.createCoverage(allocator, device, width, height, pixels);
    return .{ .baked = baked, .texture = atlas };
}

test "MFNT v1 descriptors load at their baked pixel height" {
    const testing = std.testing;
    const data = try testing.allocator.alloc(u8, 64 + 28 + 1 + 4 + 1);
    defer testing.allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "MFNT");
    putU16Le(data, 4, 1);
    putU16Le(data, 6, 64);
    putF32Le(data, 8, 16);
    putF32Le(data, 12, 4);
    putU32Le(data, 16, 1);
    putU32Le(data, 20, '?');
    putU32Le(data, 24, 0);
    putF32Le(data, 28, 12);
    putF32Le(data, 32, 16);
    putU32Le(data, 36, 1);
    putU32Le(data, 40, 1);
    putU32Le(data, 44, 1);
    putU32Le(data, 48, 1);
    putU32Le(data, 52, 4);
    putU32Le(data, 56, 28);
    putF32Le(data, 64 + 24, 8);
    data[data.len - 1] = 1;

    try testing.expectError(error.InvalidFont, stageMsdf(data, 15));
    var staged = try stageMsdf(data, 16);
    defer staged.deinit();
    try testing.expectEqual(@as(c_int, 1), staged.baked.is_msdf);
    try testing.expectEqual(@as(f32, 4), staged.baked.px_range);
    try testing.expectEqual(@as(c_int, 1), staged.baked.count);
}

fn putU16Le(data: []u8, offset: usize, value: u16) void {
    data[offset] = @truncate(value);
    data[offset + 1] = @truncate(value >> 8);
}

fn putU32Le(data: []u8, offset: usize, value: u32) void {
    data[offset] = @truncate(value);
    data[offset + 1] = @truncate(value >> 8);
    data[offset + 2] = @truncate(value >> 16);
    data[offset + 3] = @truncate(value >> 24);
}

fn putF32Le(data: []u8, offset: usize, value: f32) void {
    putU32Le(data, offset, @bitCast(value));
}
