//! The font resource the registry owns, the metrics every provider reports, and the options text code takes.
//!
//! This is the Phase 1 contract of the Text and Font System Migration Plan, for decisions D-01 (one FontHandle
//! over a registry-owned FontResource tagged union), D-05 (the existing text entry points keep their signatures),
//! and D-06 (horizontal left-to-right only, with explicit script and language). The registry in font_registry.zig
//! stores these values, and game-facing code holds only the FontHandle.
//!
//! Providers in this file:
//! - `bfnt_coverage`: a prebaked `.bfnt` coverage atlas (font.zig), kept as the compatibility path.
//! - `bitmap`: a normalized BMFont descriptor and its uploaded coverage pages.
//! - `runtime_coverage`: a TrueType face (runtime_font.zig) and its reusable shaper. Its glyphs are rasterized on
//!   demand into the Phase 4 glyph cache, which owns the atlas, so the face itself holds no atlas.
//! - `msdf`: an offline MFNT v1 glyph-ID atlas, embedded outline face, and matching coverage sibling.
//!
//! Metrics conventions, all in pixels, y down, unrounded. Consumers round them the way text.c does (a rounded line
//! top, then a rounded ascent):
//! - `ascent` is the distance from the top of a line box to its baseline. It is positive.
//! - `descent` is the distance from the baseline to the bottom of a line box. It is positive.
//! - `line_gap` is the extra space between one line box and the next. It is never negative.
//! - `line_height` is the natural baseline-to-baseline distance: ascent + descent + line_gap.
//! A BFNT file records only the ascent and the baseline-to-baseline distance. Its descent is therefore derived as
//! line_height - ascent, and its line gap is zero.
//!
//! Ownership: `Resources` owns each stored resource until `remove`. `release` removes it and then frees the provider.
//! If `insert` fails, nothing was stored, so the caller still owns the resource and must release it.

const std = @import("std");
const font_registry = @import("font_registry.zig");
const font_mod = @import("font.zig");
const runtime_font = @import("runtime_font.zig");
const shaper = @import("shaper.zig");
const bmfont = @import("bmfont.zig");
const layout = @import("layout.zig");
const c = @import("../ui/c.zig").c;
const Texture = @import("../renderer/texture.zig").Texture;

pub const FontHandle = font_registry.FontHandle;

/// The providers a font can be built by.
pub const Provider = enum {
    bfnt_coverage,
    msdf,
    bitmap,
    runtime_coverage,
};

/// Runtime face state kept together at a stable address in the registry. The shaper borrows `face`, so it is
/// initialized only after the resource has been inserted into its final registry allocation.
pub const RuntimeCoverage = struct {
    face: runtime_font.RuntimeFont,
    shaper: ?shaper.Shaper = null,

    pub fn deinit(self: *RuntimeCoverage) void {
        if (self.shaper) |*value| value.deinit();
        self.face.deinit();
        self.* = undefined;
    }
};

/// A normalized bitmap descriptor and the fixed coverage textures for its authored pages.
pub const BitmapFont = struct {
    allocator: std.mem.Allocator,
    descriptor: bmfont.Font,
    pages: []Texture,

    pub fn deinit(self: *BitmapFont) void {
        for (self.pages) |*page| page.deinit();
        self.allocator.free(self.pages);
        self.descriptor.deinit();
        self.* = undefined;
    }
};

pub const MsdfFont = font_mod.MsdfFont;

/// One font's provider-specific state. Only the provider touches it, and game code never does.
pub const FontResource = union(Provider) {
    bfnt_coverage: font_mod.Font,
    msdf: MsdfFont,
    bitmap: BitmapFont,
    runtime_coverage: RuntimeCoverage,

    /// The provider that built this resource.
    pub fn provider(self: *const FontResource) Provider {
        return switch (self.*) {
            .bfnt_coverage => .bfnt_coverage,
            .msdf => .msdf,
            .bitmap => .bitmap,
            .runtime_coverage => .runtime_coverage,
        };
    }

    /// Releases the provider's resources. Call it once, after the resource is out of the registry, or use `release`.
    pub fn deinit(self: *FontResource) void {
        switch (self.*) {
            .bfnt_coverage => |*f| f.deinit(),
            .msdf => |*f| f.deinit(),
            .bitmap => |*f| f.deinit(),
            .runtime_coverage => |*f| f.deinit(),
        }
        self.* = undefined;
    }

    /// The common metrics, in the conventions in the header. This reads only CPU-side data, so it is safe on any thread
    /// that may read the resource.
    pub fn metrics(self: *const FontResource) FontMetrics {
        return switch (self.*) {
            .bfnt_coverage => |*f| bfntMetrics(&f.baked),
            .msdf => |*f| bfntMetrics(&f.baked),
            .bitmap => |*f| bitmapMetrics(&f.descriptor),
            .runtime_coverage => |*f| runtimeMetrics(&f.face),
        };
    }
};

/// Metrics that every provider reports the same way. See the header for the conventions.
pub const FontMetrics = struct {
    /// The size the font was made at, in pixels: baked size for BFNT, descriptor size for bitmap, or pixel height for runtime.
    pixel_height: f32,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    /// The natural baseline-to-baseline distance: ascent + descent + line_gap.
    line_height: f32,
};

fn bfntMetrics(baked: *const c.ui_font) FontMetrics {
    const ascent: f32 = @floatFromInt(baked.ascent);
    const line_height: f32 = @floatFromInt(baked.line_height);
    return .{
        .pixel_height = baked.pixel_height,
        .ascent = ascent,
        .descent = line_height - ascent,
        .line_gap = 0,
        .line_height = line_height,
    };
}

fn runtimeMetrics(face: *const runtime_font.RuntimeFont) FontMetrics {
    // The face keeps its font-unit values. The stb scale turns them into pixels, the same scale the glyphs use.
    const scale = face.scale;
    const ascent = @as(f32, @floatFromInt(face.ascent)) * scale;
    const descent = -@as(f32, @floatFromInt(face.descent)) * scale;
    const line_gap = @as(f32, @floatFromInt(face.line_gap)) * scale;
    return .{
        .pixel_height = face.pixel_height,
        .ascent = ascent,
        .descent = descent,
        .line_gap = line_gap,
        .line_height = ascent + descent + line_gap,
    };
}

fn bitmapMetrics(descriptor: *const bmfont.Font) FontMetrics {
    const line_height: f32 = @floatFromInt(descriptor.line_height);
    const ascent: f32 = @floatFromInt(descriptor.base);
    return .{
        .pixel_height = @floatFromInt(descriptor.size),
        .ascent = ascent,
        .descent = line_height - ascent,
        .line_gap = 0,
        .line_height = line_height,
    };
}

/// The registry that owns every font's resource. Game code holds the `FontHandle`s it returns.
pub const Resources = font_registry.Registry(FontResource);

/// The metrics of the font `handle` names. An invalid or stale handle fails, as `Registry.get` does.
pub fn metricsFor(resources: *Resources, handle: FontHandle) font_registry.LookupError!FontMetrics {
    const resource = try resources.get(handle);
    return resource.metrics();
}

/// Removes the font `handle` names and releases its provider. The handle is stale after this returns.
pub fn release(resources: *Resources, handle: FontHandle) font_registry.LookupError!void {
    var resource = try resources.remove(handle);
    resource.deinit();
}

/// The writing direction. The first release is horizontal left to right only (D-06), so this has one value. A
/// right-to-left or bidi direction would be a new variant, decided in its own phase.
pub const Direction = enum { ltr };

/// Options a text call takes. Only `font` has no default. Script and language are never guessed from the text, so
/// the defaults are the compatibility values `Latn` and `en`. Callers of other scripts set them, for example Tamil
/// callers set `Taml` and `ta`.
pub const TextOptions = struct {
    font: FontHandle,
    /// ISO 15924 script tag, passed to the shaper.
    script: []const u8 = "Latn",
    /// BCP 47 language tag, passed to the shaper.
    language: []const u8 = "en",
    direction: Direction = .ltr,
    alignment: layout.Alignment = .left,
    /// The width in pixels to wrap at, or null for no wrapping.
    wrap_width: ?f32 = null,
    /// Magnification applied at draw time to every measure and placement. The font's own pixel size is fixed when it loads.
    scale: f32 = 1,
    /// A multiplier on the font's natural line height. Layout takes an explicit line height today, so Phase 5 applies this.
    line_spacing: f32 = 1,
    /// RGBA tint, each channel from 0 to 1.
    color: [4]f32 = .{ 1, 1, 1, 1 },

    /// The shaper options for this text.
    pub fn shaperOptions(self: TextOptions) shaper.Options {
        return .{ .script = self.script, .language = self.language };
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Reads a file through HarfBuzz's loader and returns an owned copy, as runtime_font.zig's tests do.
fn readFixture(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const blob = runtime_font.hb.hb_blob_create_from_file_or_fail(path.ptr) orelse return error.FixtureMissing;
    defer runtime_font.hb.hb_blob_destroy(blob);
    var len: c_uint = 0;
    const data = runtime_font.hb.hb_blob_get_data(blob, &len);
    if (data == null or len == 0) return error.FixtureMissing;
    const ptr: [*]const u8 = @ptrCast(data);
    return allocator.dupe(u8, ptr[0..@as(usize, len)]);
}

test "a runtime face reports ascent, descent, and line gap in pixels from the scale its glyphs use" {
    const bytes = try readFixture(testing.allocator, "assets/font.ttf");
    defer testing.allocator.free(bytes);
    var resource = FontResource{ .runtime_coverage = .{ .face = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16) } };
    defer resource.deinit();

    try testing.expectEqual(Provider.runtime_coverage, resource.provider());
    const m = resource.metrics();
    try testing.expectEqual(@as(f32, 16), m.pixel_height);
    // hhea of assets/font.ttf: ascender 1854, descender -434, lineGap 67, over 2048 units per em. At 16 px the scale is
    // 16 / 2288 pixels per unit, the value runtime_font.zig pins. checks/font_resource_check.py reads the same hhea.
    try testing.expectApproxEqAbs(@as(f32, 12.96503), m.ascent, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3.03497), m.descent, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.46853), m.line_gap, 1e-4);
}

test "the natural line height is ascent plus descent plus line gap" {
    const bytes = try readFixture(testing.allocator, "assets/font.ttf");
    defer testing.allocator.free(bytes);
    var resource = FontResource{ .runtime_coverage = .{ .face = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16) } };
    defer resource.deinit();

    const m = resource.metrics();
    try testing.expectApproxEqAbs(m.ascent + m.descent + m.line_gap, m.line_height, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 16.46853), m.line_height, 1e-4);
}

test "a BFNT font reports its baked ascent, and its descent is the rest of the baked line" {
    var baked = std.mem.zeroes(c.ui_font);
    baked.pixel_height = 9;
    baked.ascent = 7;
    baked.line_height = 10;
    // The atlas is never read here, so the texture stays undefined. This resource is not deinitialized.
    const resource = FontResource{ .bfnt_coverage = .{ .baked = baked, .texture = undefined } };

    try testing.expectEqual(Provider.bfnt_coverage, resource.provider());
    const m = resource.metrics();
    try testing.expectEqual(@as(f32, 9), m.pixel_height);
    try testing.expectEqual(@as(f32, 7), m.ascent);
    try testing.expectEqual(@as(f32, 3), m.descent);
    try testing.expectEqual(@as(f32, 0), m.line_gap);
    try testing.expectEqual(@as(f32, 10), m.line_height);
}

test "a runtime font stored in the registry is found by its handle, and released on remove" {
    const bytes = try readFixture(testing.allocator, "assets/font.ttf");
    defer testing.allocator.free(bytes);
    var resources = Resources.init(testing.allocator);
    defer resources.deinit();

    var face = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    // If the insert fails, nothing was stored, so the face is still ours to release.
    const handle = resources.insert(.{ .runtime_coverage = .{ .face = face } }) catch |err| {
        face.deinit();
        return err;
    };
    try testing.expectEqual(@as(usize, 1), resources.count());
    const before = try metricsFor(&resources, handle);
    try testing.expectApproxEqAbs(@as(f32, 12.96503), before.ascent, 1e-4);

    try release(&resources, handle);
    try testing.expectEqual(@as(usize, 0), resources.count());
    try testing.expectError(error.StaleHandle, metricsFor(&resources, handle));
    try testing.expectError(error.StaleHandle, release(&resources, handle));
}

test "the invalid handle names no font in the resource registry" {
    var resources = Resources.init(testing.allocator);
    defer resources.deinit();
    try testing.expectError(error.InvalidHandle, metricsFor(&resources, FontHandle.invalid));
}

test "text options default to Latin, English, left to right, and no wrapping" {
    const opts = TextOptions{ .font = .{ .id = 1 } };
    try testing.expectEqualStrings("Latn", opts.script);
    try testing.expectEqualStrings("en", opts.language);
    try testing.expectEqual(Direction.ltr, opts.direction);
    try testing.expectEqual(layout.Alignment.left, opts.alignment);
    try testing.expectEqual(@as(?f32, null), opts.wrap_width);
    try testing.expectEqual(@as(f32, 1), opts.scale);
    try testing.expectEqual(@as(f32, 1), opts.line_spacing);

    const so = opts.shaperOptions();
    try testing.expectEqualStrings("Latn", so.script);
    try testing.expectEqualStrings("en", so.language);
}

test "a Tamil caller names Taml and ta, and the shaper receives them unchanged" {
    const opts = TextOptions{ .font = .{ .id = 2 }, .script = "Taml", .language = "ta" };
    const so = opts.shaperOptions();
    try testing.expectEqualStrings("Taml", so.script);
    try testing.expectEqualStrings("ta", so.language);
}
