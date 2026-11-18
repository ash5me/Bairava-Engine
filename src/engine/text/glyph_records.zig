//! Turns a shaped layout into glyph render records (Phase 5): for each drawn glyph, the atlas rectangle it samples and the
//! pixel rectangle it covers. The GPU path turns each record into one sprite on Bairava's SpriteBatch, so this file holds
//! no renderer types and needs no device. Every test here is CPU-only.
//!
//! Placement follows the legacy BFNT path (text.c), so text lands on the same pixels:
//! - the pen starts at the origin plus the line's alignment offset, and moves by each glyph's shaped advance, kept fractional;
//! - each glyph's left edge is rounded to a whole pixel once, from the pen, the glyph's offset, and its bearing;
//! - a line's baseline is the rounded line top plus the rounded ascent, so each line rounds on its own;
//! - a glyph with no ink produces no record but still moves the pen.
//!
//! Records do not own atlas memory. A record's page must have been flushed to the GPU before the draw that samples it.
//! That flush is a Phase 5 renderer task, not something this file does.
//!
//! On error the records appended before the failing glyph stay in `out`. The caller decides whether to draw them.

const std = @import("std");
const glyph_cache = @import("glyph_cache.zig");
const glyph_resolver = @import("glyph_resolver.zig");
const runtime_font = @import("runtime_font.zig");
const font_registry = @import("font_registry.zig");
const FontId = font_registry.FontId;
const shaped_layout = @import("shaped_layout.zig");

pub const Error = glyph_resolver.Error || std.mem.Allocator.Error;

/// One glyph to draw: the atlas rectangle to sample and the destination pixels to cover.
pub const Record = struct {
    /// Atlas page and texel rectangle, row 0 at the top. The same convention as glyph_cache.Region.
    page: u32,
    src_x: u32,
    src_y: u32,
    src_w: u32,
    src_h: u32,
    /// Destination pixels, y down. Whole numbers, so the glyph stays sharp.
    dst_x: f32,
    dst_y: f32,
    dst_w: f32,
    dst_h: f32,
    /// The rasterization mode the coverage was made in. Only gray is produced so far.
    mode: glyph_cache.RasterMode,
};

pub const Options = struct {
    /// The caller's id for this font inside the cache. Two live fonts must not share one.
    font_id: FontId,
    /// The glyph drawn for a glyph ID past the font's last glyph. The caller chooses it; see glyph_resolver.
    fallback_glyph_id: u32,
    mode: glyph_cache.RasterMode = .gray,
};

/// Appends one record per inked glyph of `lay`, drawn with its top-left corner at (x, y), to `out`. Each glyph is resolved
/// through the glyph resolver, so an unseen glyph is rasterized and cached, and a seen one is a cache hit.
pub fn build(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Record),
    cache: *glyph_cache.Cache,
    font: *const runtime_font.RuntimeFont,
    lay: *const shaped_layout.Layout,
    x: f32,
    y: f32,
    options: Options,
) Error!void {
    // The ascent is the same for every line, so round it once. It is rounded as a whole, as text.c does.
    const ascent_px = @round(@as(f32, @floatFromInt(font.ascent)) * font.scale);
    for (lay.lines, 0..) |line, index| {
        const line_top = y + @as(f32, @floatFromInt(index)) * lay.line_height;
        const baseline = @round(line_top) + ascent_px;
        var pen = x + line.x_offset;
        for (lay.glyphsOf(line)) |glyph| {
            const resolved = try glyph_resolver.resolveWithFallback(
                cache,
                options.font_id,
                font,
                glyph.glyph_id,
                options.fallback_glyph_id,
                options.mode,
            );
            const entry = resolved.entry;
            if (entry.metrics.width > 0 and entry.metrics.height > 0) {
                try out.append(allocator, .{
                    .page = entry.region.page,
                    .src_x = entry.region.x,
                    .src_y = entry.region.y,
                    .src_w = entry.region.w,
                    .src_h = entry.region.h,
                    .dst_x = @round(pen + glyph.x_offset + entry.metrics.xoff),
                    .dst_y = baseline + @round(glyph.y_offset + entry.metrics.yoff),
                    .dst_w = @floatFromInt(entry.metrics.width),
                    .dst_h = @floatFromInt(entry.metrics.height),
                    .mode = options.mode,
                });
            }
            pen += glyph.x_advance;
        }
    }
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const shaper = @import("shaper.zig");

const font_path: [:0]const u8 = "assets/font.ttf";
const font_id: FontId = 1;
const test_line_height: f32 = 20;
/// Arial 7.07's glyph index for 'A' and 'V', as the shaper and runtime font tests report them.
const arial_glyph_a: u32 = 36;

fn readFixture(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const hb = runtime_font.hb;
    const blob = hb.hb_blob_create_from_file_or_fail(path.ptr) orelse return error.FixtureMissing;
    defer hb.hb_blob_destroy(blob);
    var len: c_uint = 0;
    const data = hb.hb_blob_get_data(blob, &len);
    if (data == null or len == 0) return error.FixtureMissing;
    const ptr: [*]const u8 = @ptrCast(data);
    return allocator.dupe(u8, ptr[0..@as(usize, len)]);
}

test "a single A is placed on the legacy baseline, with its bearing and size from the face" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    var lay = try shaped_layout.layout(testing.allocator, &sh, "A", 1000, test_line_height, .left, .{});
    defer lay.deinit();
    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(testing.allocator);
    try build(testing.allocator, &records, &cache, &font, &lay, 0, 0, .{ .font_id = font_id, .fallback_glyph_id = 0 });

    try testing.expectEqual(@as(usize, 1), records.items.len);
    const r = records.items[0];
    // Ascent 1854 units at 16 px over 2288 units gives 12.96, which rounds to 13. A's top edge sits 11 px above the baseline
    // and its bearing is -1, so the record starts at (-1, 2) and covers 11 by 11.
    try testing.expectEqual(@as(f32, -1), r.dst_x);
    try testing.expectEqual(@as(f32, 2), r.dst_y);
    try testing.expectEqual(@as(f32, 11), r.dst_w);
    try testing.expectEqual(@as(f32, 11), r.dst_h);
    try testing.expectEqual(glyph_cache.RasterMode.gray, r.mode);
}

test "the pen moves by the shaped advance, so V after A is placed by the kerned advance" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    var lay = try shaped_layout.layout(testing.allocator, &sh, "AV", 1000, test_line_height, .left, .{});
    defer lay.deinit();
    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(testing.allocator);
    try build(testing.allocator, &records, &cache, &font, &lay, 0, 0, .{ .font_id = font_id, .fallback_glyph_id = 0 });
    try testing.expectEqual(@as(usize, 2), records.items.len);

    const kerned_pen = lay.glyphsOf(lay.lines[0])[0].x_advance;
    const v_metrics = try font.glyphMetrics(lay.glyphsOf(lay.lines[0])[1].glyph_id);
    try testing.expectEqual(@round(kerned_pen + v_metrics.xoff), records.items[1].dst_x);
    // The unkerned advance of A would round to a different pixel, so this check tells the two apart.
    const alone = try font.glyphMetrics(arial_glyph_a);
    try testing.expect(@round(alone.advance + v_metrics.xoff) != records.items[1].dst_x);
}

test "a space moves the pen and draws nothing" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    var lay = try shaped_layout.layout(testing.allocator, &sh, "A B", 1000, test_line_height, .left, .{});
    defer lay.deinit();
    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(testing.allocator);
    try build(testing.allocator, &records, &cache, &font, &lay, 0, 0, .{ .font_id = font_id, .fallback_glyph_id = 0 });
    // A and B have ink, the space between them does not.
    try testing.expectEqual(@as(usize, 2), records.items.len);
    const glyphs = lay.glyphsOf(lay.lines[0]);
    const b_metrics = try font.glyphMetrics(glyphs[2].glyph_id);
    const b_pen = glyphs[0].x_advance + glyphs[1].x_advance;
    try testing.expectEqual(@round(b_pen + glyphs[2].x_offset + b_metrics.xoff), records.items[1].dst_x);
}

test "a repeated glyph is rasterized once across two builds, and both builds draw the same rectangles" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    var lay = try shaped_layout.layout(testing.allocator, &sh, "AAAA", 1000, test_line_height, .left, .{});
    defer lay.deinit();
    var first: std.ArrayList(Record) = .empty;
    defer first.deinit(testing.allocator);
    try build(testing.allocator, &first, &cache, &font, &lay, 0, 0, .{ .font_id = font_id, .fallback_glyph_id = 0 });
    var second: std.ArrayList(Record) = .empty;
    defer second.deinit(testing.allocator);
    try build(testing.allocator, &second, &cache, &font, &lay, 0, 0, .{ .font_id = font_id, .fallback_glyph_id = 0 });

    try testing.expectEqual(@as(u64, 1), cache.stats.rasterized);
    try testing.expectEqual(@as(usize, 4), first.items.len);
    try testing.expectEqualSlices(Record, first.items, second.items);
}

test "lines stack by the line height, and each baseline rounds on its own" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    var lay = try shaped_layout.layout(testing.allocator, &sh, "A\nA", 1000, test_line_height, .left, .{});
    defer lay.deinit();
    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(testing.allocator);
    try build(testing.allocator, &records, &cache, &font, &lay, 0, 0, .{ .font_id = font_id, .fallback_glyph_id = 0 });
    try testing.expectEqual(@as(usize, 2), records.items.len);
    try testing.expectEqual(records.items[0].dst_y + test_line_height, records.items[1].dst_y);

    // An origin of 0.6 rounds the top to 1, so the whole line moves down one pixel. An origin of 0.4 would not move it.
    var moved: std.ArrayList(Record) = .empty;
    defer moved.deinit(testing.allocator);
    try build(testing.allocator, &moved, &cache, &font, &lay, 0, 0.6, .{ .font_id = font_id, .fallback_glyph_id = 0 });
    try testing.expectEqual(records.items[0].dst_y + 1, moved.items[0].dst_y);
    var still: std.ArrayList(Record) = .empty;
    defer still.deinit(testing.allocator);
    try build(testing.allocator, &still, &cache, &font, &lay, 0, 0.4, .{ .font_id = font_id, .fallback_glyph_id = 0 });
    try testing.expectEqual(records.items[0].dst_y, still.items[0].dst_y);
}

test "right alignment moves the record by the line's offset" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    const width = try sh.measure("A", .{});
    var lay = try shaped_layout.layout(testing.allocator, &sh, "A", 100, test_line_height, .right, .{});
    defer lay.deinit();
    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(testing.allocator);
    try build(testing.allocator, &records, &cache, &font, &lay, 0, 0, .{ .font_id = font_id, .fallback_glyph_id = 0 });
    // The offset is 100 - width, and A's bearing is -1.
    try testing.expectEqual(@round((100 - width) - 1), records.items[0].dst_x);
}

test "a mono request is refused before the cache is touched" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    var lay = try shaped_layout.layout(testing.allocator, &sh, "A", 1000, test_line_height, .left, .{});
    defer lay.deinit();
    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(testing.allocator);
    try testing.expectError(error.UnsupportedRasterMode, build(testing.allocator, &records, &cache, &font, &lay, 0, 0, .{
        .font_id = font_id,
        .fallback_glyph_id = 0,
        .mode = .mono,
    }));
    try testing.expectEqual(@as(usize, 0), records.items.len);
    try testing.expectEqual(@as(u64, 0), cache.stats.misses);
    try testing.expectEqual(@as(u64, 0), cache.stats.rasterized);
}

test "every record samples a rectangle inside its atlas page" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    var lay = try shaped_layout.layout(testing.allocator, &sh, "AVATAR wraps here", 60, test_line_height, .left, .{});
    defer lay.deinit();
    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(testing.allocator);
    try build(testing.allocator, &records, &cache, &font, &lay, 0, 0, .{ .font_id = font_id, .fallback_glyph_id = 0 });
    try testing.expect(records.items.len > 0);
    for (records.items) |r| {
        try testing.expect(r.src_x + r.src_w <= glyph_cache.default_page_size);
        try testing.expect(r.src_y + r.src_h <= glyph_cache.default_page_size);
        try testing.expect(r.src_w > 0 and r.src_h > 0);
    }
}

test "an empty layout adds no records and caches nothing" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    var lay = try shaped_layout.layout(testing.allocator, &sh, "", 100, test_line_height, .left, .{});
    defer lay.deinit();
    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(testing.allocator);
    try build(testing.allocator, &records, &cache, &font, &lay, 0, 0, .{ .font_id = font_id, .fallback_glyph_id = 0 });
    try testing.expectEqual(@as(usize, 0), records.items.len);
    try testing.expectEqual(@as(u64, 0), cache.stats.rasterized);
}

test "repeated layout-and-record rounds leave nothing allocated" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();

    // testing.allocator fails the test if a layout, a record list, or a glyph array is left behind.
    var round: usize = 0;
    while (round < 30) : (round += 1) {
        var lay = try shaped_layout.layout(testing.allocator, &sh, "wrap AAAA", 40, test_line_height, .center, .{});
        defer lay.deinit();
        var records: std.ArrayList(Record) = .empty;
        defer records.deinit(testing.allocator);
        try build(testing.allocator, &records, &cache, &font, &lay, 0, 0, .{ .font_id = font_id, .fallback_glyph_id = 0 });
        try testing.expect(records.items.len > 0);
    }
}
