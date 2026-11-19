//! Runtime glyph cache: the CPU side of Phase 3 of the rendering migration plan.
//!
//! The cache maps a glyph to a rectangle in a coverage page. A glyph is rasterized once, its
//! coverage is copied into that rectangle, and later lookups find it by key: font identity, glyph
//! ID, and pixel height. Pages are plain CPU bytes here. The renderer adapter
//! (renderer/glyph_atlas.zig) uploads the regions this file reports as changed. Nothing in this
//! file touches SDL or the GPU, so every rule below is tested without a window.
//!
//! Policy, from docs/Bairava_Phase0/design-note.md section 5 (Q1) and the Phase 3 working
//! assumptions:
//! - Four 1024 by 1024 coverage pages, shelf-packed. Every glyph has one texel of padding on its
//!   right and bottom edges. Sampling is nearest, so the padding keeps a sampled texel from ever
//!   reaching the neighbouring glyph.
//! - No eviction. A glyph's texels are written once and never move. A frame still in flight may read
//!   them. Region uploads never touch them again. A whole-page upload, forced when the pending list
//!   overflows, rewrites them with the same bytes. That path is not covered by this argument, and the
//!   Phase 4 status in the text plan lists it as an open GPU-sync item.
//!   When every page is full, insert returns AtlasFull and counts it in `cache_full`. The caller
//!   draws the fallback glyph, so no glyph is dropped silently.
//! - Page 0 starts with a solid 2 by 2 white block at its origin. Filled rectangles sample it, as the
//!   prebaked font's white block does, so they share the coverage pipeline.
//! - A removed font's glyphs stop being found at once. Their texels stay until `clear`, which
//!   rewrites every page and so must only run while the GPU is idle.
//!
//! Threading: a Cache belongs to the render thread. A glyph's coverage may be rasterized on another
//! thread, but `insert` runs on the render thread.

const std = @import("std");
const font_registry = @import("font_registry.zig");
const FontId = font_registry.FontId;

pub const default_page_size: u32 = 1024;
pub const default_page_count: u32 = 4;
pub const max_page_size: u32 = 8192;
/// D-14: four pages is the agreed atlas ceiling (four 1024 by 1024 R8 pages, 4 MiB). A larger count is refused.
pub const max_page_count: u32 = 4;
/// Texels of empty space on the right and bottom of every glyph.
pub const padding: u32 = 1;
/// Side of the solid white block at the origin of page 0.
pub const white_size: u32 = 2;
/// Changed regions remembered between two flushes. Past this count, the page of the next region is marked for a
/// whole-page upload instead, so the list never grows.
pub const max_pending: usize = 512;
const initial_slots: usize = 256;

pub const Error = error{
    GlyphTooLarge,
    AtlasFull,
    InvalidBitmap,
    InvalidOptions,
} || std.mem.Allocator.Error;

pub const Options = struct {
    page_size: u32 = default_page_size,
    page_count: u32 = default_page_count,
};

/// How a glyph's coverage was rasterized. The same glyph at the same size has a different bitmap in each mode, so each
/// mode is a different key. The runtime path makes gray only. `mono` is listed so that a hinted rasterizer can add its
/// glyphs without sharing keys with gray ones; nothing produces it yet.
pub const RasterMode = enum(u8) { gray = 0, mono = 1 };

/// Identifies one rasterized glyph. `font` is chosen by the caller and must differ between live fonts. `size_bits` is
/// the pixel height's bit pattern, so two heights that differ at all are different keys. `mode` defaults to gray.
pub const GlyphKey = struct {
    font: FontId,
    glyph: u32,
    size_bits: u32,
    mode: RasterMode = .gray,
};

pub fn sizeBits(pixel_height: f32) u32 {
    return @bitCast(pixel_height);
}

/// The metrics of one glyph, in the same pixel conventions as runtime_font.GlyphMetrics.
pub const Metrics = struct {
    /// Pen advance in pixels.
    advance: f32,
    /// Left edge of the bitmap from the pen, in pixels.
    xoff: f32,
    /// Top edge of the bitmap from the baseline, in pixels, y down.
    yoff: f32,
    width: u32,
    height: u32,
};

/// A rectangle in one page, in texels, row 0 at the top. A glyph with no ink has width and height zero.
pub const Region = struct {
    page: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const Entry = struct {
    metrics: Metrics,
    region: Region,
};

/// Counters for diagnostics. `snapshot` fills the two computed fields.
pub const Stats = struct {
    /// Lookups that found their glyph.
    hits: u64 = 0,
    /// Lookups that did not. Each is normally followed by one insert.
    misses: u64 = 0,
    /// Glyphs stored, with or without page space. `empty_glyphs` counts the ones without.
    inserts: u64 = 0,
    /// Glyphs rasterized on a miss. Counted by glyph_resolver.resolve, including a glyph whose insert was then refused.
    rasterized: u64 = 0,
    /// Requests for a glyph past the font's last glyph. Counted by glyph_resolver.resolveWithFallback, once per request.
    missing_glyphs: u64 = 0,
    /// Glyphs with no ink, stored with no page space.
    empty_glyphs: u64 = 0,
    /// Inserts refused because every page was full.
    cache_full: u64 = 0,
    /// Inserts refused because the glyph is wider or taller than a page allows.
    too_large: u64 = 0,
    /// Codepoints the text layer could not map to a glyph (see noteMissingCodepoint).
    missing_codepoints: u64 = 0,
    /// Entries dropped by removeFont.
    removed: u64 = 0,
    /// Times the lookup table grew.
    rehashes: u64 = 0,
    /// Pages that hold at least one glyph or the white block. Computed by snapshot.
    pages_in_use: u32 = 0,
    /// Glyphs currently found by lookup. Computed by snapshot.
    entries: u32 = 0,
    /// CPU bytes held by the coverage pages and the lookup table. GPU page memory is not counted here. Computed by snapshot.
    allocated_bytes: u64 = 0,
};

const SlotState = enum(u8) { empty, used, tombstone };

const Slot = struct {
    state: SlotState = .empty,
    key: GlyphKey = .{ .font = 0, .glyph = 0, .size_bits = 0 },
    entry: Entry = undefined,
};

/// One page of CPU coverage bytes, with the shelf packer's cursor.
const Page = struct {
    pixels: []u8,
    /// Next free x on the current shelf.
    cursor_x: u32 = 0,
    /// Top of the current shelf.
    shelf_y: u32 = 0,
    /// Height of the tallest glyph on the current shelf.
    shelf_h: u32 = 0,
    /// True once the page holds the white block or a glyph.
    used: bool = false,
    /// True when the whole page must be uploaded before the next draw.
    dirty_all: bool = false,

    /// Places a w by h glyph, plus padding, on the current shelf, or on a new shelf below it when it
    /// does not fit. Returns the top-left texel, or null when the page has no room. A null result
    /// changes nothing.
    fn place(self: *Page, page_size: u32, w: u32, h: u32) ?[2]u32 {
        const pw = w + padding;
        const ph = h + padding;
        var x = self.cursor_x;
        var y = self.shelf_y;
        var shelf_h = self.shelf_h;
        if (x + pw > page_size) {
            y += shelf_h;
            x = 0;
            shelf_h = 0;
        }
        if (y + ph > page_size) return null;
        self.cursor_x = x + pw;
        self.shelf_y = y;
        self.shelf_h = @max(shelf_h, ph);
        self.used = true;
        return [2]u32{ x, y };
    }
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    page_size: u32,
    pages: []Page,
    slots: []Slot,
    /// Slots holding an entry.
    live: usize = 0,
    /// Slots holding a removed entry. Probes pass over them, and an insert may reuse one.
    tombstones: usize = 0,
    pending: [max_pending]Region = undefined,
    pending_count: usize = 0,
    stats: Stats = .{},

    /// Builds the cache and writes the white block into page 0. The block is listed as a pending region, so the
    /// first flush uploads it.
    pub fn init(allocator: std.mem.Allocator, options: Options) Error!Cache {
        if (options.page_size < white_size + padding or options.page_size > max_page_size) return error.InvalidOptions;
        if (options.page_count == 0 or options.page_count > max_page_count) return error.InvalidOptions;

        const pages = try allocator.alloc(Page, options.page_count);
        errdefer allocator.free(pages);
        var made: usize = 0;
        errdefer {
            for (pages[0..made]) |page| allocator.free(page.pixels);
        }
        const texels = @as(usize, options.page_size) * @as(usize, options.page_size);
        while (made < pages.len) : (made += 1) {
            const pixels = try allocator.alloc(u8, texels);
            @memset(pixels, 0);
            pages[made] = .{ .pixels = pixels };
        }

        const slots = try allocator.alloc(Slot, initial_slots);
        errdefer allocator.free(slots);
        for (slots) |*slot| slot.* = .{};

        var cache = Cache{
            .allocator = allocator,
            .page_size = options.page_size,
            .pages = pages,
            .slots = slots,
        };
        cache.reserveWhite();
        return cache;
    }

    pub fn deinit(self: *Cache) void {
        for (self.pages) |page| self.allocator.free(page.pixels);
        self.allocator.free(self.pages);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// The entry for `key`, if it is cached. Counts a hit or a miss.
    pub fn lookup(self: *Cache, key: GlyphKey) ?Entry {
        if (self.findSlot(key)) |index| {
            self.stats.hits += 1;
            return self.slots[index].entry;
        }
        self.stats.misses += 1;
        return null;
    }

    /// Stores a glyph's coverage and returns its entry. `coverage` holds width * height bytes, row 0 first.
    /// A key that is already cached returns its existing entry and changes nothing. A glyph with no ink takes no
    /// page space. A refused insert changes nothing: no page space is used and no entry is added.
    pub fn insert(self: *Cache, key: GlyphKey, metrics: Metrics, coverage: []const u8) Error!Entry {
        if (self.findSlot(key)) |index| return self.slots[index].entry;

        var entry = Entry{
            .metrics = metrics,
            .region = .{ .page = 0, .x = 0, .y = 0, .w = 0, .h = 0 },
        };
        if (metrics.width == 0 or metrics.height == 0) {
            if (coverage.len != 0) return error.InvalidBitmap;
            try self.ensureRoom();
            self.stats.empty_glyphs += 1;
        } else {
            const limit = self.page_size - padding;
            if (metrics.width > limit or metrics.height > limit) {
                self.stats.too_large += 1;
                return error.GlyphTooLarge;
            }
            if (coverage.len != @as(usize, metrics.width) * @as(usize, metrics.height)) return error.InvalidBitmap;
            try self.ensureRoom();
            entry.region = try self.place(metrics.width, metrics.height);
            self.blit(entry.region, coverage);
        }
        self.insertNew(key, entry);
        self.stats.inserts += 1;
        return entry;
    }

    /// Forgets every glyph of `font`. Their texels stay in their pages until `clear`. Returns how many entries were
    /// removed.
    pub fn removeFont(self: *Cache, font: FontId) u32 {
        var removed: u32 = 0;
        for (self.slots) |*slot| {
            if (slot.state == .used and slot.key.font == font) {
                slot.state = .tombstone;
                self.live -= 1;
                self.tombstones += 1;
                removed += 1;
            }
        }
        self.stats.removed += removed;
        return removed;
    }

    /// Forgets every glyph, empties every page, and marks each page for a full upload. Rewrites texels, so only call
    /// it while the GPU is idle.
    pub fn clear(self: *Cache) void {
        for (self.slots) |*slot| slot.* = .{};
        self.live = 0;
        self.tombstones = 0;
        for (self.pages) |*page| {
            @memset(page.pixels, 0);
            page.cursor_x = 0;
            page.shelf_y = 0;
            page.shelf_h = 0;
            page.used = false;
            page.dirty_all = true;
        }
        self.pending_count = 0;
        self.reserveWhite();
    }

    /// Marks every page for a full upload, and keeps the glyphs. The renderer calls this after it creates new page
    /// textures, so the new textures receive the whole cache.
    pub fn markAllDirty(self: *Cache) void {
        self.pending_count = 0;
        for (self.pages) |*page| page.dirty_all = true;
    }

    pub fn noteMissingCodepoint(self: *Cache) void {
        self.stats.missing_codepoints += 1;
    }

    /// Counts one request for a glyph the font does not have. The resolver calls it before it uses the fallback.
    pub fn noteMissingGlyph(self: *Cache) void {
        self.stats.missing_glyphs += 1;
    }

    /// Counts one glyph rasterized on a miss. The resolver calls it right after the rasterizer succeeds.
    pub fn noteRasterized(self: *Cache) void {
        self.stats.rasterized += 1;
    }

    /// The counters, with the computed fields filled in.
    pub fn snapshot(self: *const Cache) Stats {
        var result = self.stats;
        result.entries = @intCast(self.live);
        var in_use: u32 = 0;
        for (self.pages) |page| {
            if (page.used) in_use += 1;
        }
        result.pages_in_use = in_use;
        const texels = @as(u64, self.page_size) * @as(u64, self.page_size);
        result.allocated_bytes = texels * @as(u64, self.pages.len) + @as(u64, self.slots.len) * @sizeOf(Slot);
        return result;
    }

    /// Regions changed since the last clearPending, in write order. A page for which pageNeedsFullUpload is true must
    /// be uploaded whole, and its regions in this list can be skipped.
    pub fn pendingRegions(self: *const Cache) []const Region {
        return self.pending[0..self.pending_count];
    }

    /// True once the page holds the white block or a glyph. A page that is not in use has no sprites and needs no 2D
    /// copy.
    pub fn pageInUse(self: *const Cache, page: u32) bool {
        return self.pages[page].used;
    }

    pub fn pageNeedsFullUpload(self: *const Cache, page: u32) bool {
        return self.pages[page].dirty_all;
    }

    /// All of one page's coverage bytes, row 0 first, `page_size` bytes per row.
    pub fn pagePixels(self: *const Cache, page: u32) []const u8 {
        return self.pages[page].pixels;
    }

    /// The coverage bytes of one region, starting at its top-left texel. Row r of the region starts `page_size` bytes
    /// after row r - 1.
    pub fn regionCoverage(self: *const Cache, region: Region) []const u8 {
        const start = @as(usize, region.y) * @as(usize, self.page_size) + @as(usize, region.x);
        return self.pages[region.page].pixels[start..];
    }

    /// Forgets the pending list and the full-page flags. Call after the renderer has uploaded them.
    pub fn clearPending(self: *Cache) void {
        self.pending_count = 0;
        for (self.pages) |*page| page.dirty_all = false;
    }

    /// The solid white block, for filled rectangles.
    pub fn whiteRegion() Region {
        return .{ .page = 0, .x = 0, .y = 0, .w = white_size, .h = white_size };
    }

    fn reserveWhite(self: *Cache) void {
        const origin = self.pages[0].place(self.page_size, white_size, white_size) orelse unreachable;
        const page = &self.pages[0];
        var row: u32 = 0;
        while (row < white_size) : (row += 1) {
            const start = @as(usize, origin[1] + row) * @as(usize, self.page_size) + @as(usize, origin[0]);
            @memset(page.pixels[start..][0..white_size], 255);
        }
        self.markPending(.{ .page = 0, .x = origin[0], .y = origin[1], .w = white_size, .h = white_size });
    }

    /// Finds a region with room, trying the pages in order. Counts `cache_full` when none has room.
    fn place(self: *Cache, w: u32, h: u32) Error!Region {
        for (self.pages, 0..) |*page, index| {
            if (page.place(self.page_size, w, h)) |origin| {
                return .{ .page = @intCast(index), .x = origin[0], .y = origin[1], .w = w, .h = h };
            }
        }
        self.stats.cache_full += 1;
        return error.AtlasFull;
    }

    /// Copies a glyph's rows into its region and records the region as changed.
    fn blit(self: *Cache, region: Region, coverage: []const u8) void {
        const page = &self.pages[region.page];
        var row: u32 = 0;
        while (row < region.h) : (row += 1) {
            const dst_start = @as(usize, region.y + row) * @as(usize, self.page_size) + @as(usize, region.x);
            const src_start = @as(usize, row) * @as(usize, region.w);
            @memcpy(page.pixels[dst_start..][0..region.w], coverage[src_start..][0..region.w]);
        }
        self.markPending(region);
    }

    fn markPending(self: *Cache, region: Region) void {
        if (self.pending_count < max_pending) {
            self.pending[self.pending_count] = region;
            self.pending_count += 1;
        } else {
            self.pages[region.page].dirty_all = true;
        }
    }

    fn mask(self: *const Cache) usize {
        return self.slots.len - 1;
    }

    /// Index of the used slot holding `key`, or null. Probes stop at the first empty slot.
    fn findSlot(self: *const Cache, key: GlyphKey) ?usize {
        var index = hashKey(key) & self.mask();
        var probes: usize = 0;
        while (probes < self.slots.len) : (probes += 1) {
            const slot = &self.slots[index];
            switch (slot.state) {
                .empty => return null,
                .used => {
                    if (sameKey(slot.key, key)) return index;
                },
                .tombstone => {},
            }
            index = (index + 1) & self.mask();
        }
        return null;
    }

    /// Adds an entry whose key is absent. The table must have room. An insert reuses the first tombstone on its probe.
    fn insertNew(self: *Cache, key: GlyphKey, entry: Entry) void {
        var index = hashKey(key) & self.mask();
        while (self.slots[index].state == .used) index = (index + 1) & self.mask();
        if (self.slots[index].state == .tombstone) self.tombstones -= 1;
        self.slots[index] = .{ .state = .used, .key = key, .entry = entry };
        self.live += 1;
    }

    /// Grows the table, rebuilding it without tombstones, when one more entry would push it past three quarters full.
    /// Growing keeps the load at half or less.
    fn ensureRoom(self: *Cache) Error!void {
        if ((self.live + self.tombstones + 1) * 4 <= self.slots.len * 3) return;
        var new_len = self.slots.len;
        while ((self.live + 1) * 2 > new_len) new_len *= 2;

        const fresh = try self.allocator.alloc(Slot, new_len);
        for (fresh) |*slot| slot.* = .{};
        const old = self.slots;
        self.slots = fresh;
        self.live = 0;
        self.tombstones = 0;
        for (old) |slot| {
            if (slot.state == .used) self.insertNew(slot.key, slot.entry);
        }
        self.allocator.free(old);
        self.stats.rehashes += 1;
    }
};

/// Mixes one 32-bit word. The constants are the murmur3 finalizer.
fn mix(value: u32) u32 {
    var h = value;
    h ^= h >> 16;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;
    return h;
}

/// Folds a font id into the 32 bits `mix` takes, so ids that differ only above bit 31 still spread across slots.
/// Equality (`sameKey`) compares the whole id, so a fold collision costs a probe and never a wrong hit.
fn hashFont(font: FontId) u32 {
    return @truncate(font ^ (font >> 32));
}

fn hashKey(key: GlyphKey) usize {
    var h = mix(hashFont(key.font));
    h = mix(h ^ key.glyph);
    h = mix(h ^ key.size_bits);
    h = mix(h ^ @as(u32, @intFromEnum(key.mode)));
    return h;
}

fn sameKey(a: GlyphKey, b: GlyphKey) bool {
    return a.font == b.font and a.glyph == b.glyph and a.size_bits == b.size_bits and a.mode == b.mode;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn expectRegion(expected: Region, actual: Region) !void {
    try testing.expectEqual(expected.page, actual.page);
    try testing.expectEqual(expected.x, actual.x);
    try testing.expectEqual(expected.y, actual.y);
    try testing.expectEqual(expected.w, actual.w);
    try testing.expectEqual(expected.h, actual.h);
}

fn testMetrics(w: u32, h: u32) Metrics {
    return .{ .advance = @floatFromInt(w + 1), .xoff = 0, .yoff = -@as(f32, @floatFromInt(h)), .width = w, .height = h };
}

fn keyOf(font: FontId, glyph: u32) GlyphKey {
    return .{ .font = font, .glyph = glyph, .size_bits = sizeBits(16) };
}

test "a new cache holds the white block at the origin of page 0 and queues it for upload" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 2 });
    defer cache.deinit();
    try testing.expectEqual(@as(usize, 1), cache.pendingRegions().len);
    try expectRegion(Cache.whiteRegion(), cache.pendingRegions()[0]);
    const pixels = cache.pagePixels(0);
    try testing.expectEqual(@as(u8, 255), pixels[0]);
    try testing.expectEqual(@as(u8, 255), pixels[1]);
    try testing.expectEqual(@as(u8, 255), pixels[32]);
    try testing.expectEqual(@as(u8, 255), pixels[33]);
    try testing.expectEqual(@as(u8, 0), pixels[2]);
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u32, 1), stats.pages_in_use);
    try testing.expectEqual(@as(u32, 0), stats.entries);
    try testing.expect(cache.pageInUse(0));
    try testing.expect(!cache.pageInUse(1));
}

test "a glyph misses once, is inserted, and then hits, and a repeated insert returns the same entry" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 2 });
    defer cache.deinit();
    const coverage = [_]u8{ 9, 8, 7, 6 };
    try testing.expect(cache.lookup(keyOf(1, 5)) == null);
    const first = try cache.insert(keyOf(1, 5), testMetrics(2, 2), &coverage);
    const hit = cache.lookup(keyOf(1, 5)) orelse return error.TestUnexpectedResult;
    try expectRegion(first.region, hit.region);
    const again = try cache.insert(keyOf(1, 5), testMetrics(2, 2), &coverage);
    try expectRegion(first.region, again.region);
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 1), stats.misses);
    try testing.expectEqual(@as(u64, 1), stats.hits);
    try testing.expectEqual(@as(u64, 1), stats.inserts);
    try testing.expectEqual(@as(u32, 1), stats.entries);
}

test "glyph rows are copied to the region the cache reports, and regionCoverage keeps the page stride" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 2 });
    defer cache.deinit();
    const coverage = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const entry = try cache.insert(keyOf(1, 1), testMetrics(3, 2), &coverage);
    // The white block takes 3 texels on the first shelf, so the first glyph starts at x = 3.
    try testing.expectEqual(@as(u32, 0), entry.region.page);
    try testing.expectEqual(@as(u32, 3), entry.region.x);
    try testing.expectEqual(@as(u32, 0), entry.region.y);
    const pixels = cache.pagePixels(0);
    try testing.expectEqual(@as(u8, 1), pixels[3]);
    try testing.expectEqual(@as(u8, 3), pixels[5]);
    try testing.expectEqual(@as(u8, 4), pixels[32 + 3]);
    try testing.expectEqual(@as(u8, 6), pixels[32 + 5]);
    const view = cache.regionCoverage(entry.region);
    try testing.expectEqual(@as(u8, 4), view[32]);
    try testing.expectEqual(@as(u8, 6), view[32 + 2]);
}

test "glyphs with no ink take no page space and queue nothing" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 1 });
    defer cache.deinit();
    const empty = try cache.insert(keyOf(1, 9), .{ .advance = 4, .xoff = 0, .yoff = 0, .width = 0, .height = 0 }, &[_]u8{});
    try testing.expectEqual(@as(u32, 0), empty.region.w);
    try testing.expectEqual(@as(u32, 0), empty.region.h);
    try testing.expectEqual(@as(usize, 1), cache.pendingRegions().len);
    try testing.expectEqual(@as(u64, 1), cache.snapshot().empty_glyphs);
    try testing.expect(cache.lookup(keyOf(1, 9)) != null);
    // The next glyph still starts where the white block ends.
    const next = try cache.insert(keyOf(1, 10), testMetrics(1, 1), &.{7});
    try testing.expectEqual(@as(u32, 3), next.region.x);
}

test "keys differ by font, glyph, and pixel height" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 2 });
    defer cache.deinit();
    _ = try cache.insert(keyOf(1, 1), testMetrics(1, 1), &.{7});
    try testing.expect(cache.lookup(keyOf(2, 1)) == null);
    try testing.expect(cache.lookup(keyOf(1, 2)) == null);
    const other_size = GlyphKey{ .font = 1, .glyph = 1, .size_bits = sizeBits(17) };
    try testing.expect(cache.lookup(other_size) == null);
    try testing.expect(cache.lookup(keyOf(1, 1)) != null);
}

test "a glyph that does not fit the shelf starts a new shelf below it" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 1 });
    defer cache.deinit();
    const coverage = [_]u8{1} ** 16;
    // Shelf 0 holds the white block and five 4 by 4 glyphs, at x = 3, 8, 13, 18, and 23.
    var glyph: u32 = 1;
    while (glyph <= 5) : (glyph += 1) {
        const entry = try cache.insert(keyOf(1, glyph), testMetrics(4, 4), &coverage);
        try testing.expectEqual(@as(u32, 0), entry.region.y);
    }
    const sixth = try cache.insert(keyOf(1, 6), testMetrics(4, 4), &coverage);
    try testing.expectEqual(@as(u32, 0), sixth.region.x);
    try testing.expectEqual(@as(u32, 5), sixth.region.y);
}

test "a full page sends the next glyph to the next page, and a full cache refuses it and counts it" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 2 });
    defer cache.deinit();
    const coverage = [_]u8{1} ** 16;
    // Page 0 holds 35 of these glyphs after the white block. Page 1 holds 36.
    var glyph: u32 = 1;
    while (glyph <= 71) : (glyph += 1) {
        _ = try cache.insert(keyOf(1, glyph), testMetrics(4, 4), &coverage);
    }
    try testing.expectError(error.AtlasFull, cache.insert(keyOf(1, 72), testMetrics(4, 4), &coverage));
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u64, 1), stats.cache_full);
    try testing.expectEqual(@as(u32, 2), stats.pages_in_use);
    try testing.expectEqual(@as(u32, 71), stats.entries);
    // The refused glyph is not in the table, so a later lookup misses.
    try testing.expect(cache.lookup(keyOf(1, 72)) == null);
    // Glyph 36 is the first one on page 1.
    const first_on_second = cache.lookup(keyOf(1, 36)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), first_on_second.region.page);
    try testing.expectEqual(@as(u32, 0), first_on_second.region.x);
    try testing.expectEqual(@as(u32, 0), first_on_second.region.y);
}

test "a glyph wider than the page allows is refused and counted" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 2 });
    defer cache.deinit();
    try testing.expectError(error.GlyphTooLarge, cache.insert(keyOf(1, 1), testMetrics(32, 4), &([_]u8{1} ** 128)));
    try testing.expectEqual(@as(u64, 1), cache.snapshot().too_large);
    try testing.expect(cache.lookup(keyOf(1, 1)) == null);
}

test "a coverage buffer of the wrong length is refused and leaves the cache unchanged" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 1 });
    defer cache.deinit();
    try testing.expectError(error.InvalidBitmap, cache.insert(keyOf(1, 1), testMetrics(2, 2), &.{ 1, 2, 3 }));
    try testing.expectError(error.InvalidBitmap, cache.insert(keyOf(1, 2), .{ .advance = 1, .xoff = 0, .yoff = 0, .width = 0, .height = 0 }, &.{1}));
    try testing.expectEqual(@as(usize, 1), cache.pendingRegions().len);
    try testing.expectEqual(@as(u32, 0), cache.snapshot().entries);
}

test "removing a font forgets its glyphs and keeps the others" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 64, .page_count = 1 });
    defer cache.deinit();
    var glyph: u32 = 1;
    while (glyph <= 3) : (glyph += 1) _ = try cache.insert(keyOf(1, glyph), testMetrics(2, 2), &([_]u8{1} ** 4));
    _ = try cache.insert(keyOf(2, 1), testMetrics(2, 2), &([_]u8{2} ** 4));
    _ = try cache.insert(keyOf(2, 2), testMetrics(2, 2), &([_]u8{2} ** 4));
    try testing.expectEqual(@as(u32, 3), cache.removeFont(1));
    try testing.expect(cache.lookup(keyOf(1, 1)) == null);
    try testing.expect(cache.lookup(keyOf(2, 1)) != null);
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u32, 2), stats.entries);
    try testing.expectEqual(@as(u64, 3), stats.removed);
}

test "a removed entry does not hide the entries probed past it" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 1 });
    defer cache.deinit();
    const first = keyOf(1, 1);
    const home = hashKey(first) & (cache.slots.len - 1);
    // Find a key of another font whose probe starts at the same slot, so it has to pass the first entry.
    var glyph: u32 = 2;
    var second = keyOf(2, glyph);
    while ((hashKey(second) & (cache.slots.len - 1)) != home) {
        glyph += 1;
        second = keyOf(2, glyph);
    }
    _ = try cache.insert(first, testMetrics(1, 1), &.{7});
    _ = try cache.insert(second, testMetrics(1, 1), &.{8});
    try testing.expectEqual(@as(u32, 1), cache.removeFont(1));
    try testing.expect(cache.lookup(second) != null);
    try testing.expect(cache.lookup(first) == null);
}

test "the table grows as entries are added, and every entry is still found afterwards" {
    var cache = try Cache.init(testing.allocator, .{});
    defer cache.deinit();
    const coverage = [_]u8{200};
    var glyph: u32 = 0;
    while (glyph < 1000) : (glyph += 1) {
        _ = try cache.insert(keyOf(7, glyph), testMetrics(1, 1), &coverage);
    }
    glyph = 0;
    while (glyph < 1000) : (glyph += 1) {
        const entry = cache.lookup(keyOf(7, glyph)) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u32, 1), entry.metrics.width);
    }
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u32, 1000), stats.entries);
    try testing.expectEqual(@as(u64, 3), stats.rehashes);
}

test "more changed glyphs than the pending list holds mark their page for a full upload" {
    var cache = try Cache.init(testing.allocator, .{});
    defer cache.deinit();
    var glyph: u32 = 0;
    while (glyph < 600) : (glyph += 1) {
        _ = try cache.insert(keyOf(1, glyph), testMetrics(1, 1), &.{5});
    }
    try testing.expectEqual(max_pending, cache.pendingRegions().len);
    try testing.expect(cache.pageNeedsFullUpload(0));
    try testing.expect(!cache.pageNeedsFullUpload(1));
    cache.clearPending();
    try testing.expectEqual(@as(usize, 0), cache.pendingRegions().len);
    try testing.expect(!cache.pageNeedsFullUpload(0));
}

test "clear empties the pages and marks every page for a full upload" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 2 });
    defer cache.deinit();
    const entry = try cache.insert(keyOf(1, 1), testMetrics(2, 2), &([_]u8{9} ** 4));
    cache.clearPending();
    cache.clear();
    try testing.expect(cache.lookup(keyOf(1, 1)) == null);
    try testing.expectEqual(@as(u8, 0), cache.pagePixels(0)[@as(usize, entry.region.y) * 32 + @as(usize, entry.region.x)]);
    try testing.expectEqual(@as(u8, 255), cache.pagePixels(0)[0]);
    try testing.expect(cache.pageNeedsFullUpload(0));
    try testing.expect(cache.pageNeedsFullUpload(1));
    const stats = cache.snapshot();
    try testing.expectEqual(@as(u32, 1), stats.pages_in_use);
    try testing.expectEqual(@as(u32, 0), stats.entries);
}

test "markAllDirty queues every page and keeps the glyphs" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 2 });
    defer cache.deinit();
    _ = try cache.insert(keyOf(1, 1), testMetrics(2, 2), &([_]u8{9} ** 4));
    cache.clearPending();
    cache.markAllDirty();
    try testing.expectEqual(@as(usize, 0), cache.pendingRegions().len);
    try testing.expect(cache.pageNeedsFullUpload(0));
    try testing.expect(cache.pageNeedsFullUpload(1));
    try testing.expect(cache.lookup(keyOf(1, 1)) != null);
}

test "missing codepoints are counted" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 1 });
    defer cache.deinit();
    cache.noteMissingCodepoint();
    cache.noteMissingCodepoint();
    try testing.expectEqual(@as(u64, 2), cache.snapshot().missing_codepoints);
}

test "invalid options are refused before anything is allocated" {
    try testing.expectError(error.InvalidOptions, Cache.init(testing.allocator, .{ .page_size = 2 }));
    try testing.expectError(error.InvalidOptions, Cache.init(testing.allocator, .{ .page_count = 0 }));
    try testing.expectError(error.InvalidOptions, Cache.init(testing.allocator, .{ .page_size = max_page_size + 1 }));
}

test "the pixel-height key is the float's bit pattern" {
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, 16.0))), sizeBits(16.0));
    try testing.expect(sizeBits(16.0) != sizeBits(16.5));
}

test "keys differ by rasterization mode, so gray and mono coverage of one glyph are two entries" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 1 });
    defer cache.deinit();
    const gray = GlyphKey{ .font = 1, .glyph = 5, .size_bits = sizeBits(16) };
    var mono = gray;
    mono.mode = .mono;

    _ = try cache.insert(gray, testMetrics(2, 2), &[_]u8{ 1, 2, 3, 4 });
    try testing.expect(cache.lookup(mono) == null);
    _ = try cache.insert(mono, testMetrics(2, 2), &[_]u8{ 5, 6, 7, 8 });

    try testing.expectEqual(@as(u32, 2), cache.snapshot().entries);
    const gray_entry = cache.lookup(gray) orelse return error.TestUnexpectedResult;
    const mono_entry = cache.lookup(mono) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 1), cache.regionCoverage(gray_entry.region)[0]);
    try testing.expectEqual(@as(u8, 5), cache.regionCoverage(mono_entry.region)[0]);
}

test "allocated bytes count the coverage pages and the lookup table" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 2 });
    defer cache.deinit();
    const expected: u64 = 2 * 32 * 32 + initial_slots * @sizeOf(Slot);
    try testing.expectEqual(expected, cache.snapshot().allocated_bytes);
}

test "a failed allocation in init is reported, and init frees what it had already made" {
    // With one page, init makes three allocations: the page list, the page's bytes, and the lookup table. Failing any
    // one of them must return OutOfMemory. testing.allocator fails the test if the earlier ones are left allocated.
    var fail_at: usize = 0;
    while (fail_at < 3) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_at });
        try testing.expectError(error.OutOfMemory, Cache.init(failing.allocator(), .{ .page_size = 32, .page_count = 1 }));
    }
}

test "a lookup table that cannot grow refuses the insert and keeps the entries it has" {
    // The fourth allocation with one page is the first growth of the lookup table. Growth starts when one more entry
    // would pass three quarters full, so the first `room` entries fit and the next insert needs the allocation.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 3 });
    var cache = try Cache.init(failing.allocator(), .{ .page_size = 1024, .page_count = 1 });
    defer cache.deinit();

    const room: u32 = initial_slots * 3 / 4;
    var glyph: u32 = 1;
    while (glyph <= room) : (glyph += 1) _ = try cache.insert(keyOf(1, glyph), testMetrics(1, 1), &.{7});
    try testing.expectError(error.OutOfMemory, cache.insert(keyOf(1, room + 1), testMetrics(1, 1), &.{7}));

    try testing.expectEqual(room, cache.snapshot().entries);
    try testing.expectEqual(@as(u64, 0), cache.snapshot().rehashes);
    try testing.expect(cache.lookup(keyOf(1, room)) != null);
    try testing.expect(cache.lookup(keyOf(1, room + 1)) == null);
}

test "a key without a mode is gray, and gray is the zero value, so a zeroed mode is gray" {
    const key = GlyphKey{ .font = 1, .glyph = 1, .size_bits = sizeBits(16) };
    try testing.expectEqual(RasterMode.gray, key.mode);
    try testing.expectEqual(@as(u8, 0), @intFromEnum(RasterMode.gray));
}

test "a gray and a mono key that share a probe chain stay apart" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 1 });
    defer cache.deinit();
    const mask = cache.slots.len - 1;
    var gray = GlyphKey{ .font = 1, .glyph = 1, .size_bits = sizeBits(16) };
    var mono = gray;
    mono.mode = .mono;

    // Hashing includes the mode, so the two keys usually start in different buckets. Search for a glyph whose gray
    // and mono keys share a bucket. Only then does an equality check that ignores the mode show up.
    var glyph: u32 = 1;
    while (glyph < 100000) : (glyph += 1) {
        gray.glyph = glyph;
        mono.glyph = glyph;
        if ((hashKey(gray) & mask) == (hashKey(mono) & mask)) break;
    }
    try testing.expect(glyph < 100000);

    _ = try cache.insert(gray, testMetrics(2, 2), &[_]u8{ 1, 2, 3, 4 });
    try testing.expect(cache.lookup(mono) == null);
    try testing.expect(cache.lookup(gray) != null);
}

test "fonts whose ids differ only above bit 31 are different fonts" {
    var cache = try Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 2 });
    defer cache.deinit();
    const coverage = [_]u8{ 9, 8, 7, 6 };
    const high: FontId = 1 + (1 << 32);
    _ = try cache.insert(keyOf(1, 5), testMetrics(2, 2), &coverage);
    try testing.expect(cache.lookup(keyOf(high, 5)) == null);
    _ = try cache.insert(keyOf(high, 5), testMetrics(2, 2), &coverage);
    try testing.expectEqual(@as(u32, 2), cache.snapshot().entries);
    try testing.expectEqual(@as(u32, 1), cache.removeFont(high));
    try testing.expect(cache.lookup(keyOf(1, 5)) != null);
    try testing.expect(cache.lookup(keyOf(high, 5)) == null);
}

test "the page ceiling is the four pages D-14 allows, and a fifth is refused" {
    try testing.expectEqual(@as(u32, 4), max_page_count);
    try testing.expectError(error.InvalidOptions, Cache.init(testing.allocator, .{ .page_count = max_page_count + 1 }));
}
