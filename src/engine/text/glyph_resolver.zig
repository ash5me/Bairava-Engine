//! Resolves glyphs of a runtime outline font to their regions in a glyph cache. This is the on-demand path of Phase 4 of
//! the text and font system migration plan: a lookup that hits returns the stored entry, and a miss rasterizes the glyph
//! once and stores it. Source comments in glyph_cache.zig and glyph_atlas.zig call this "Phase 3 of the rendering
//! migration plan". That label is legacy. The text plan's numbering is authoritative.
//!
//! Callers pass glyph IDs, the ones HarfBuzz returns after shaping. Nothing here maps codepoints.
//!
//! The functions are CPU-only. The renderer's atlas (renderer/glyph_atlas.zig) owns the cache, and its next flush
//! uploads any region these calls changed. Callers must flush before a draw samples the region.

const glyph_cache = @import("glyph_cache.zig");
const runtime_font = @import("runtime_font.zig");

pub const Error = runtime_font.Error || glyph_cache.Error || error{UnsupportedRasterMode};

/// What `resolveWithFallback` drew: the entry, and whether it stands in for a glyph the font does not have.
pub const Resolved = struct {
    entry: glyph_cache.Entry,
    substituted: bool,
};

/// Whether this path can produce a mode. The runtime rasterizer makes gray coverage only. Any other mode fails with
/// UnsupportedRasterMode, so gray glyphs are never stored under a mono key.
pub fn supports(mode: glyph_cache.RasterMode) bool {
    return switch (mode) {
        .gray => true,
        .mono => false,
    };
}

/// Returns the cache entry for `glyph_id` of `font` in `mode`.
///
/// `font_id` names `font` inside the cache. Two live fonts must not share an id, and a font's glyphs are forgotten by
/// `cache.removeFont(font_id)`. The key also carries the font's pixel height and the mode, so one font at two sizes
/// holds two entries.
///
/// An unsupported mode is refused before the cache is consulted, so it counts nothing. A hit rasterizes nothing and
/// counts a hit. A miss counts a miss, rasterizes the glyph, counts one rasterization, and stores the coverage. An
/// out-of-range glyph fails in the rasterizer before a rasterization is counted, so nothing is stored. A glyph whose
/// insert is refused (AtlasFull, for instance) still counts its rasterization. The caller then draws its fallback, so
/// no glyph is dropped silently.
pub fn resolve(
    cache: *glyph_cache.Cache,
    font_id: u32,
    font: *const runtime_font.RuntimeFont,
    glyph_id: u32,
    mode: glyph_cache.RasterMode,
) Error!glyph_cache.Entry {
    if (!supports(mode)) return error.UnsupportedRasterMode;
    const key = glyph_cache.GlyphKey{
        .font = font_id,
        .glyph = glyph_id,
        .size_bits = glyph_cache.sizeBits(font.pixel_height),
        .mode = mode,
    };
    if (cache.lookup(key)) |entry| return entry;

    const bitmap = try font.rasterize(cache.allocator, glyph_id);
    defer bitmap.deinit(cache.allocator);
    cache.noteRasterized();
    return cache.insert(key, metricsOf(bitmap.metrics), bitmap.coverage);
}

/// Resolves `glyph_id`, or `fallback_glyph_id` when the font does not have `glyph_id`. A glyph is missing when its ID is
/// past the font's last glyph. Glyph 0 is a real glyph in TrueType (.notdef), so it is not treated as missing here.
///
/// The caller passes the fallback glyph ID. This function does not choose a fallback: mapping `?` through the character
/// map, and what to draw when no fallback exists, are deferred to Phase 7. Each request for a missing glyph counts once
/// in `missing_glyphs`, whether or not the fallback then resolves. The missing glyph itself is never stored. An
/// unsupported mode is refused first, so it counts nothing.
pub fn resolveWithFallback(
    cache: *glyph_cache.Cache,
    font_id: u32,
    font: *const runtime_font.RuntimeFont,
    glyph_id: u32,
    fallback_glyph_id: u32,
    mode: glyph_cache.RasterMode,
) Error!Resolved {
    if (!supports(mode)) return error.UnsupportedRasterMode;
    if (glyph_id < font.glyph_count) {
        return .{ .entry = try resolve(cache, font_id, font, glyph_id, mode), .substituted = false };
    }
    cache.noteMissingGlyph();
    return .{ .entry = try resolve(cache, font_id, font, fallback_glyph_id, mode), .substituted = true };
}

fn metricsOf(m: runtime_font.GlyphMetrics) glyph_cache.Metrics {
    return .{
        .advance = m.advance,
        .xoff = m.xoff,
        .yoff = m.yoff,
        .width = m.width,
        .height = m.height,
    };
}
