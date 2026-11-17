//! Phase 3 check of the glyph cache against the shipped UI font. The file is read through HarfBuzz's blob loader, as
//! hb_shape_test.zig does, and every glyph comes from RuntimeFont. HarfBuzz is used only to read bytes here. No HarfBuzz
//! type leaves this file, so the cache and the font never share a C type. Nothing here touches the GPU.
//!
//! `zig build test` runs from the repository root (see run_tests.setCwd in build.zig), so the path is relative to it.

const std = @import("std");
const glyph_cache = @import("glyph_cache.zig");
const runtime_font = @import("runtime_font.zig");
const resolver = @import("glyph_resolver.zig");

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

test "a repeated request for a glyph finds it, and rasterizes it only once" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    // Glyph 36 is 'A' in the shipped font, as checks/hb_linux_smoke.c measured.
    const first = try resolver.resolve(&cache, 1, &font, 36, .gray);
    const second = try resolver.resolve(&cache, 1, &font, 36, .gray);
    try testing.expectEqual(first.region.x, second.region.x);
    try testing.expectEqual(first.region.y, second.region.y);
    try testing.expectEqual(first.metrics.advance, second.metrics.advance);

    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 1), stats.rasterized);
    try testing.expectEqual(@as(u64, 1), stats.misses);
    try testing.expectEqual(@as(u64, 1), stats.hits);
    try testing.expectEqual(@as(u64, 1), stats.inserts);
}

test "a glyph with an advance and no ink keeps its advance and takes no page space" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    // The first glyph with an advance and no ink is a space in the shipped font.
    var space: u32 = 0;
    while (space < font.glyph_count) : (space += 1) {
        const m = try font.glyphMetrics(space);
        if (m.width == 0 and m.advance > 0) break;
    }
    try testing.expect(space < font.glyph_count);

    const pending_before = cache.pendingRegions().len;
    const entry = try resolver.resolve(&cache, 1, &font, space, .gray);
    try testing.expectEqual(@as(u32, 0), entry.region.w);
    try testing.expectEqual(@as(u32, 0), entry.region.h);
    try testing.expectEqual((try font.glyphMetrics(space)).advance, entry.metrics.advance);
    // No texel changed, so nothing is queued for upload.
    try testing.expectEqual(pending_before, cache.pendingRegions().len);
    try testing.expectEqual(@as(u64, 1), cache.snapshot().empty_glyphs);
}

test "another size or another font id is a different entry and a separate rasterization" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font16 = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font16.deinit();
    var font24 = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 24);
    defer font24.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    _ = try resolver.resolve(&cache, 1, &font16, 36, .gray);
    _ = try resolver.resolve(&cache, 1, &font24, 36, .gray); // same id, other size
    _ = try resolver.resolve(&cache, 2, &font16, 36, .gray); // other id, same size

    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 3), stats.rasterized);
    try testing.expectEqual(@as(u32, 3), stats.entries);
}

test "a glyph that does not fit the page is refused with AtlasFull, counted, and not stored" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    // The white block uses the first 3 texels of the first shelf. 'A' is 11 by 11 plus one texel of padding, which
    // fits neither the rest of that shelf nor a second shelf in a page 12 texels wide.
    var cache = try glyph_cache.Cache.init(testing.allocator, .{ .page_size = 12, .page_count = 1 });
    defer cache.deinit();

    try testing.expectError(error.AtlasFull, resolver.resolve(&cache, 1, &font, 36, .gray));
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 1), stats.rasterized);
    try testing.expectEqual(@as(u64, 1), stats.cache_full);
    try testing.expectEqual(@as(u32, 0), stats.entries);
    try testing.expect(cache.lookup(.{ .font = 1, .glyph = 36, .size_bits = glyph_cache.sizeBits(16) }) == null);
}

test "a glyph ID past the last glyph of the font is refused before anything is stored" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    try testing.expectError(error.GlyphOutOfRange, resolver.resolve(&cache, 1, &font, font.glyph_count, .gray));
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 0), stats.rasterized);
    try testing.expectEqual(@as(u32, 0), stats.entries);
}

test "a failed allocation while rasterizing stores nothing and counts no rasterization" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    // With one page, the cache's init makes three allocations. The fourth is the rasterizer's coverage buffer.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 3 });
    var cache = try glyph_cache.Cache.init(failing.allocator(), .{ .page_count = 1 });
    defer cache.deinit();

    try testing.expectError(error.OutOfMemory, resolver.resolve(&cache, 1, &font, 36, .gray));
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 0), stats.rasterized);
    try testing.expectEqual(@as(u32, 0), stats.entries);
}

test "an unsupported raster mode is refused before the cache is consulted" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    try testing.expectError(error.UnsupportedRasterMode, resolver.resolve(&cache, 1, &font, 36, .mono));
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 0), stats.hits);
    try testing.expectEqual(@as(u64, 0), stats.misses);
    try testing.expectEqual(@as(u64, 0), stats.rasterized);
    try testing.expectEqual(@as(u32, 0), stats.entries);
}

test "a mono entry of a glyph does not serve a gray request, and a gray entry does not serve mono" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    // No mono rasterizer exists yet, so the mono entry is inserted by hand. It stands in for what one would store.
    const gray = try resolver.resolve(&cache, 1, &font, 36, .gray);
    const mono_key = glyph_cache.GlyphKey{ .font = 1, .glyph = 36, .size_bits = glyph_cache.sizeBits(16), .mode = .mono };
    try testing.expect(cache.lookup(mono_key) == null);
    const bitmap = try font.rasterize(testing.allocator, 36);
    defer bitmap.deinit(testing.allocator);
    const mono_metrics = glyph_cache.Metrics{
        .advance = bitmap.metrics.advance,
        .xoff = bitmap.metrics.xoff,
        .yoff = bitmap.metrics.yoff,
        .width = bitmap.metrics.width,
        .height = bitmap.metrics.height,
    };
    _ = try cache.insert(mono_key, mono_metrics, bitmap.coverage);

    const mono = cache.lookup(mono_key) orelse return error.TestUnexpectedResult;
    try testing.expect(mono.region.x != gray.region.x or mono.region.y != gray.region.y);
    const gray_again = try resolver.resolve(&cache, 1, &font, 36, .gray);
    try testing.expectEqual(gray.region.x, gray_again.region.x);
    try testing.expectEqual(gray.region.y, gray_again.region.y);

    // Misses: the first gray request and the first mono lookup. Hits: the mono lookup and the second gray request.
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 2), stats.misses);
    try testing.expectEqual(@as(u64, 2), stats.hits);
    try testing.expectEqual(@as(u64, 1), stats.rasterized);
    try testing.expectEqual(@as(u32, 2), stats.entries);
}

test "a glyph past the end of the font draws the fallback glyph, counts one missing glyph, and stores nothing for it" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    const result = try resolver.resolveWithFallback(&cache, 1, &font, font.glyph_count, 36, .gray);
    try testing.expect(result.substituted);
    const direct = try resolver.resolve(&cache, 1, &font, 36, .gray);
    try testing.expectEqual(direct.region.x, result.entry.region.x);
    try testing.expectEqual(direct.region.y, result.entry.region.y);
    try testing.expectEqual(direct.metrics.advance, result.entry.metrics.advance);

    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 1), stats.missing_glyphs);
    try testing.expectEqual(@as(u64, 1), stats.rasterized);
    try testing.expectEqual(@as(u32, 1), stats.entries);
}

test "a glyph inside the font is drawn as itself, and is not counted as missing" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    // The fallback is glyph 0 here, which must not be used, since glyph 36 exists.
    const result = try resolver.resolveWithFallback(&cache, 1, &font, 36, 0, .gray);
    try testing.expect(!result.substituted);
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 0), stats.missing_glyphs);
    try testing.expectEqual(@as(u64, 1), stats.rasterized);
    try testing.expectEqual(@as(u32, 1), stats.entries);
}

test "a missing glyph whose fallback is also missing fails, counts the miss, and stores nothing" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    try testing.expectError(
        error.GlyphOutOfRange,
        resolver.resolveWithFallback(&cache, 1, &font, font.glyph_count, font.glyph_count, .gray),
    );
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 1), stats.missing_glyphs);
    try testing.expectEqual(@as(u64, 0), stats.rasterized);
    try testing.expectEqual(@as(u32, 0), stats.entries);
}

test "an unsupported mode is refused by the fallback path before any miss is counted" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    try testing.expectError(
        error.UnsupportedRasterMode,
        resolver.resolveWithFallback(&cache, 1, &font, font.glyph_count, 36, .mono),
    );
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 0), stats.missing_glyphs);
    try testing.expectEqual(@as(u64, 0), stats.misses);
    try testing.expectEqual(@as(u64, 0), stats.rasterized);
}

test "the resolved metrics match the font, and the cache entry and its pending upload agree with them" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    const entry = try resolver.resolve(&cache, 1, &font, 36, .gray);
    const m = try font.glyphMetrics(36);
    try testing.expectEqual(m.advance, entry.metrics.advance);
    try testing.expectEqual(m.xoff, entry.metrics.xoff);
    try testing.expectEqual(m.yoff, entry.metrics.yoff);
    try testing.expectEqual(m.width, entry.metrics.width);
    try testing.expectEqual(m.height, entry.metrics.height);
    // The region is exactly the glyph's ink rectangle.
    try testing.expectEqual(m.width, entry.region.w);
    try testing.expectEqual(m.height, entry.region.h);

    // A later lookup with the same key finds the same region.
    const key = glyph_cache.GlyphKey{ .font = 1, .glyph = 36, .size_bits = glyph_cache.sizeBits(16) };
    const found = cache.lookup(key) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(entry.region.page, found.region.page);
    try testing.expectEqual(entry.region.x, found.region.x);
    try testing.expectEqual(entry.region.y, found.region.y);

    // The next flush uploads that same rectangle.
    var queued = false;
    for (cache.pendingRegions()) |r| {
        if (r.page == entry.region.page and r.x == entry.region.x and r.y == entry.region.y and
            r.w == entry.region.w and r.h == entry.region.h) queued = true;
    }
    try testing.expect(queued);

    // The stored texels are the rasterized coverage, row by row.
    const bitmap = try font.rasterize(testing.allocator, 36);
    defer bitmap.deinit(testing.allocator);
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

test "glyph 0 is valid: it is drawn as itself, is cached like any glyph, and is never counted as missing" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    // Glyph 0 is .notdef. It is a real glyph, so it is not missing, whatever its outline looks like.
    const result = try resolver.resolveWithFallback(&cache, 1, &font, 0, 36, .gray);
    try testing.expect(!result.substituted);
    const m = try font.glyphMetrics(0);
    try testing.expectEqual(m.advance, result.entry.metrics.advance);

    // A second request is a hit. Zero gets no special treatment in the cache.
    _ = try resolver.resolve(&cache, 1, &font, 0, .gray);
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 0), stats.missing_glyphs);
    try testing.expectEqual(@as(u64, 1), stats.rasterized);
    try testing.expectEqual(@as(u64, 1), stats.misses);
    try testing.expectEqual(@as(u64, 1), stats.hits);
}

test "the last glyph is valid, and the glyph after it is missing, at the font's glyph count" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    // A glyph is missing when its ID is at least the font's glyph count. The count is 4652, so 4651 is the last valid ID.
    const last = font.glyph_count - 1;
    const valid = try resolver.resolveWithFallback(&cache, 1, &font, last, 36, .gray);
    try testing.expect(!valid.substituted);
    const past = try resolver.resolveWithFallback(&cache, 1, &font, font.glyph_count, 36, .gray);
    try testing.expect(past.substituted);
    try testing.expectEqual(@as(u64, 1), cache.snapshot().missing_glyphs);
}

test "warming a run of glyphs caches each one, so a later resolve of any of them is a hit and rasterizes nothing" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    // 'A' is 36, 'V' is 57, and 'T' is 55 in the shipped font. The repeated 'A' is already cached when it comes round.
    const run = [_]u32{ 36, 57, 55, 36 };
    var warmed: resolver.WarmStats = .{};
    try resolver.warm(&cache, 1, &font, &run, 36, .gray, &warmed);
    try testing.expectEqual(@as(u32, 3), warmed.rasterized);
    try testing.expectEqual(@as(u32, 1), warmed.already_cached);
    try testing.expectEqual(@as(u32, 0), warmed.substituted);

    for (run[0..3]) |glyph| {
        _ = try resolver.resolve(&cache, 1, &font, glyph, .gray);
    }
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 3), stats.rasterized);
    try testing.expectEqual(@as(u64, 3), stats.misses);
    try testing.expectEqual(@as(u64, 4), stats.hits);
}

test "warming stops at the first refused glyph and reports how far it got" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    // A page of 8 texels takes no glyph wider or taller than 7, so 'A' (11 by 11 at 16 px) is refused.
    var cache = try glyph_cache.Cache.init(testing.allocator, .{ .page_size = 8, .page_count = 1 });
    defer cache.deinit();

    // The first glyph with an advance and no ink is a space. It takes no page space, so it is cached before 'A'.
    var space: u32 = 0;
    while (space < font.glyph_count) : (space += 1) {
        const m = try font.glyphMetrics(space);
        if (m.width == 0 and m.advance > 0) break;
    }
    const run = [_]u32{ space, 36, 57 };
    var warmed: resolver.WarmStats = .{};
    try testing.expectError(error.GlyphTooLarge, resolver.warm(&cache, 1, &font, &run, 36, .gray, &warmed));
    try testing.expectEqual(@as(u32, 1), warmed.rasterized);
    try testing.expectEqual(@as(u32, 0), warmed.already_cached);

    const stats = cache.snapshot();
    // 'A' was rasterized, then the insert refused it, so the rasterization is counted and nothing is stored for it.
    try testing.expectEqual(@as(u64, 2), stats.rasterized);
    try testing.expectEqual(@as(u32, 1), stats.entries);
    try testing.expectEqual(@as(u64, 1), stats.too_large);
    // 'V' was never looked up, so only the space and 'A' missed.
    try testing.expectEqual(@as(u64, 2), stats.misses);
}

test "warming refuses an unsupported mode before anything is cached" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    const run = [_]u32{ 36, 57 };
    var warmed: resolver.WarmStats = .{};
    try testing.expectError(error.UnsupportedRasterMode, resolver.warm(&cache, 1, &font, &run, 36, .mono, &warmed));
    try testing.expectEqual(@as(u32, 0), warmed.rasterized);
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 0), stats.misses);
    try testing.expectEqual(@as(u64, 0), stats.rasterized);
    try testing.expectEqual(@as(u32, 0), stats.entries);
}

test "warming substitutes the fallback for glyphs past the end, counts each, and stores nothing for them" {
    const bytes = try readShippedFont(testing.allocator);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    const past_end = font.glyph_count;
    const run = [_]u32{ past_end, 36, past_end + 5 };
    var warmed: resolver.WarmStats = .{};
    try resolver.warm(&cache, 1, &font, &run, 36, .gray, &warmed);
    // The first request rasterizes the fallback. The second asks for 'A' directly, and the third draws the fallback.
    // Both of those find 'A' already cached.
    try testing.expectEqual(@as(u32, 1), warmed.rasterized);
    try testing.expectEqual(@as(u32, 2), warmed.already_cached);
    try testing.expectEqual(@as(u32, 2), warmed.substituted);
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 2), stats.missing_glyphs);
    try testing.expectEqual(@as(u32, 1), stats.entries);
}
