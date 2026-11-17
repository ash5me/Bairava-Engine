//! Phase 3 check of the glyph cache against the shipped UI font. The file is read through HarfBuzz's blob loader, as
//! hb_shape_test.zig does, and every glyph comes from RuntimeFont. HarfBuzz is used only to read bytes here. No HarfBuzz
//! type leaves this file, so the cache and the font never share a C type. Nothing here touches the GPU.
//!
//! `zig build test` runs from the repository root (see run_tests.setCwd in build.zig), so the path is relative to it.

const std = @import("std");
const glyph_cache = @import("glyph_cache.zig");
const runtime_font = @import("runtime_font.zig");

const hb = @cImport({
    @cInclude("hb.h");
});

const testing = std.testing;
const font_path: [:0]const u8 = "assets/font.ttf";
/// Glyph IDs cached by the test. The shipped Arial has 4652 glyphs, and the first 300 cover the ASCII range and more.
const glyphs_checked: u32 = 300;

/// Reads the shipped font into bytes the caller owns.
fn readShippedFont(allocator: std.mem.Allocator) ![]u8 {
    const blob = hb.hb_blob_create_from_file_or_fail(font_path.ptr) orelse return error.FixtureMissing;
    defer hb.hb_blob_destroy(blob);
    var len: c_uint = 0;
    const data = hb.hb_blob_get_data(blob, &len);
    if (data == null or len == 0) return error.FixtureMissing;
    // The same C-pointer conversion runtime_font.zig's readFixture uses before it slices.
    const ptr: [*]const u8 = @ptrCast(data);
    return allocator.dupe(u8, ptr[0..@as(usize, len)]);
}

fn keyFor(glyph: u32) glyph_cache.GlyphKey {
    return .{ .font = 1, .glyph = glyph, .size_bits = glyph_cache.sizeBits(16) };
}

test "the first glyphs of the shipped font enter one cache page, and each region holds its rasterized coverage" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();

    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    const count = @min(font.glyph_count, glyphs_checked);
    var glyph: u32 = 0;
    while (glyph < count) : (glyph += 1) {
        const bitmap = try font.rasterize(testing.allocator, glyph);
        defer bitmap.deinit(testing.allocator);
        const metrics = glyph_cache.Metrics{
            .advance = bitmap.metrics.advance,
            .xoff = bitmap.metrics.xoff,
            .yoff = bitmap.metrics.yoff,
            .width = bitmap.metrics.width,
            .height = bitmap.metrics.height,
        };
        const entry = try cache.insert(keyFor(glyph), metrics, bitmap.coverage);
        try testing.expectEqual(bitmap.metrics.advance, entry.metrics.advance);
        if (entry.region.w == 0) continue;

        // Every texel of the region must equal the rasterized coverage at the same position.
        const view = cache.regionCoverage(entry.region);
        var row: u32 = 0;
        while (row < entry.region.h) : (row += 1) {
            var col: u32 = 0;
            while (col < entry.region.w) : (col += 1) {
                const stored = view[@as(usize, row) * @as(usize, cache.page_size) + @as(usize, col)];
                const original = bitmap.coverage[@as(usize, row) * @as(usize, entry.region.w) + @as(usize, col)];
                try testing.expectEqual(original, stored);
            }
        }
    }

    const stats = cache.snapshot();
    try testing.expectEqual(count, stats.entries);
    try testing.expectEqual(@as(u32, 1), stats.pages_in_use);
    try testing.expectEqual(@as(u64, 0), stats.cache_full);

    // A second request finds every glyph without a new insert.
    glyph = 0;
    while (glyph < count) : (glyph += 1) {
        try testing.expect(cache.lookup(keyFor(glyph)) != null);
    }
    try testing.expectEqual(@as(u64, count), cache.snapshot().hits);
}

test "a glyph the cache has not seen before is rasterized and stored on demand" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();

    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    // Glyph 4000 is far from the ASCII range. The cache starts empty, so this is a miss, then a hit.
    const glyph: u32 = 4000;
    try testing.expect(cache.lookup(keyFor(glyph)) == null);
    const bitmap = try font.rasterize(testing.allocator, glyph);
    defer bitmap.deinit(testing.allocator);
    const metrics = glyph_cache.Metrics{
        .advance = bitmap.metrics.advance,
        .xoff = bitmap.metrics.xoff,
        .yoff = bitmap.metrics.yoff,
        .width = bitmap.metrics.width,
        .height = bitmap.metrics.height,
    };
    _ = try cache.insert(keyFor(glyph), metrics, bitmap.coverage);
    try testing.expect(cache.lookup(keyFor(glyph)) != null);
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 1), stats.misses);
    try testing.expectEqual(@as(u64, 1), stats.hits);
}
