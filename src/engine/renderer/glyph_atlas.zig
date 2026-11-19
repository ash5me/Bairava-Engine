//! The runtime glyph atlas: the glyph cache (text/glyph_cache.zig) with its coverage pages on the GPU and, while the 2D
//! renderer is active, a 2D copy of each page. Phase 3 of the rendering migration plan. Decisions P3-1, P3-2, P3-10, and
//! P3-11 are recorded in docs/Bairava_Phase0/Bairava-Engine-Rendering-Migration-Plan.phase0-status.md, section 21.
//!
//! Frame use (wired in the runtime frame loop):
//!   1. Text draws call `lookup` on the cache. On a miss they rasterize the glyph and call `insert`.
//!   2. After all of the frame's text is queued, and before the SDL2D branch and the sprite upload, call
//!      `flush(frame.cmd, ctx.renderer == .sdl2d)`. The flush has two steps, described on `flush`.
//!   3. Sprites draw from `pageTexture(region.page)`, with the texel rectangle from `spriteSource`.
//!
//! Why this is safe with frames in flight:
//!   - A glyph's texels are written once and never move (see glyph_cache.zig). A frame still in flight may read
//!     them. Region uploads never touch them again. Overflow regions spill into a frame's upload scratch; they never
//!     force a rewrite of live page texels.
//!   - The GPU copies are recorded into the same command buffer as the sprite draws that sample them, before those draws,
//!     which is the same order the sprite vertex upload relies on.
//!   - A 2D copy is only made, updated, or released in `flush`, which runs before any 2D draw of the frame. Queued sprites
//!     hold the GPU page texture pointer, and that texture lives until `deinit`. Pages never change size.
//!   - `deinit` and `Cache.clear` rewrite or free GPU objects, so the caller must wait for the GPU to go idle first.
//!
//! Memory: each GPU page costs 1 MiB in R8, and its CPU mirror costs 1 MiB. A page's 2D copy costs 4 MiB (RGBA) and
//! exists only while the 2D renderer is active and the page is in use.
//!
//! Threading: the atlas belongs to the render thread, like the cache it owns.

const std = @import("std");
const testing = std.testing;
const glyph_cache = @import("../text/glyph_cache.zig");
const sprite = @import("sprite.zig");
const texture = @import("texture.zig");
const backend = @import("backends/sdl_gpu/backend.zig");

const Texture = texture.Texture;
pub const FlushError = std.mem.Allocator.Error || backend.texture.CoverageUploadError;

/// What `flush` does with one page's 2D copy.
pub const Action2d = enum {
    /// Nothing to do.
    none,
    /// Make the copy from the whole CPU page, which already holds every change.
    sync_whole_page,
    /// Write the page's changed regions into the copy.
    update_regions,
    /// Release the copy. A page keeps its GPU texture.
    release,
};

/// The 2D copy's plan for one page. `valid` says whether the copy currently exists. A copy exists only after a flush
/// with the 2D renderer active, and every flush without it releases the copy, so existing means current. `in_use` says
/// whether the page holds any glyph. `changed` says whether the page has changed regions since the last flush.
pub fn plan2d(sdl2d_active: bool, valid: bool, in_use: bool, changed: bool) Action2d {
    if (!sdl2d_active) return .release;
    if (!valid) return if (in_use) .sync_whole_page else .none;
    return if (changed) .update_regions else .none;
}

pub const GatherCounts = struct {
    fixed: usize = 0,
    spill: usize = 0,

    pub fn total(self: GatherCounts) usize {
        return self.fixed + self.spill;
    }
};

/// Gathers one page's changed regions into fixed-size and spill buffers. A full-page region is reserved for explicit
/// cache resets/rebuilds; overflow glyph writes stay as individual regions.
pub fn gatherPage(
    cache: *const glyph_cache.Cache,
    page: u32,
    out: []texture.CoverageRegion,
    spill_out: []texture.CoverageRegion,
) GatherCounts {
    const size = cache.page_size;
    if (cache.pageNeedsFullUpload(page)) {
        out[0] = .{ .x = 0, .y = 0, .w = size, .h = size, .stride = size, .coverage = cache.pagePixels(page), .cycle = true };
        return .{ .fixed = 1 };
    }
    var counts = GatherCounts{};
    for (cache.pendingRegions()) |region| {
        if (region.page != page) continue;
        out[counts.fixed] = .{
            .x = region.x,
            .y = region.y,
            .w = region.w,
            .h = region.h,
            .stride = size,
            .coverage = cache.regionCoverage(region),
        };
        counts.fixed += 1;
    }
    for (cache.pendingSpill()) |region| {
        if (region.page != page) continue;
        spill_out[counts.spill] = .{
            .x = region.x,
            .y = region.y,
            .w = region.w,
            .h = region.h,
            .stride = size,
            .coverage = cache.regionCoverage(region),
        };
        counts.spill += 1;
    }
    return counts;
}

/// Counters for diagnostics and for the first SDL2D run (section 21). They are cumulative since `init`.
pub const FlushStats = struct {
    /// Calls to `flush`.
    flushes: u64 = 0,
    /// Flushes that recorded no GPU copies, because nothing had changed.
    idle_flushes: u64 = 0,
    /// GPU copy regions recorded. A whole-page upload counts as one region.
    gpu_regions: u64 = 0,
    /// Coverage bytes in the GPU copy regions recorded. A failed frame submission is counted again when retried.
    gpu_upload_bytes: u64 = 0,
    /// Whole-page GPU uploads.
    gpu_full_pages: u64 = 0,
    /// 2D copies made from the whole CPU page.
    sdl2d_syncs: u64 = 0,
    /// Changed regions written into 2D copies.
    sdl2d_region_updates: u64 = 0,
    /// 2D copies released because the renderer left 2D.
    sdl2d_releases: u64 = 0,
    /// Pages with glyphs that had no 2D copy while the 2D renderer was active. `sprite.draw2d` skips a quad whose texture
    /// has no copy, so a nonzero value means text is missing in 2D mode.
    sdl2d_missing_copies: u64 = 0,
};

pub const Atlas = struct {
    allocator: std.mem.Allocator,
    cache: glyph_cache.Cache,
    /// One GPU coverage texture per cache page. Created once by `init`, so every sprite's page pointer stays valid.
    pages: []Texture,
    /// Reused only during flush to convert cache spill regions into renderer upload regions.
    spill_regions: std.ArrayList(texture.CoverageRegion) = .empty,
    flush_stats: FlushStats = .{},

    /// Builds the cache and one GPU coverage texture per page. Every page starts blank on the GPU, and the cache lists the
    /// white block as changed, so the first flush uploads it. The 2D copies are not made here.
    pub fn init(allocator: std.mem.Allocator, device: *backend.Device, options: glyph_cache.Options) (glyph_cache.Error || std.mem.Allocator.Error)!Atlas {
        var cache = try glyph_cache.Cache.init(allocator, options);
        errdefer cache.deinit();

        const pages = try allocator.alloc(Texture, cache.pages.len);
        errdefer allocator.free(pages);
        var made: usize = 0;
        errdefer {
            for (pages[0..made]) |*page| page.deinit();
        }

        const size = cache.page_size;
        const blank = try allocator.alloc(u8, @as(usize, size) * @as(usize, size));
        defer allocator.free(blank);
        @memset(blank, 0);
        while (made < pages.len) : (made += 1) {
            pages[made] = texture.createCoverageGpuOnly(allocator, device, size, size, blank);
        }
        return .{ .allocator = allocator, .cache = cache, .pages = pages };
    }

    /// Releases the page textures, their 2D copies, and the cache. Call only after the GPU is idle.
    pub fn deinit(self: *Atlas) void {
        for (self.pages) |*page| page.deinit();
        self.allocator.free(self.pages);
        self.spill_regions.deinit(self.allocator);
        self.cache.deinit();
        self.* = undefined;
    }

    /// Rebuilds every GPU page from the retained CPU cache. Call after GPU idle, with no queued draws that reference
    /// the old page textures. The next 2D flush creates fresh copies from the same cache bytes.
    pub fn recreateGpuResources(self: *Atlas, device: *backend.Device) std.mem.Allocator.Error!void {
        const pages = try self.allocator.alloc(Texture, self.pages.len);
        errdefer self.allocator.free(pages);
        var made: usize = 0;
        errdefer {
            for (pages[0..made]) |*page| page.deinit();
        }

        while (made < pages.len) : (made += 1) {
            pages[made] = texture.createCoverageGpuOnly(
                self.allocator,
                device,
                self.cache.page_size,
                self.cache.page_size,
                self.cache.pagePixels(@intCast(made)),
            );
        }
        for (self.pages) |*page| page.deinit();
        self.allocator.free(self.pages);
        self.pages = pages;
        self.cache.clearPending();
    }

    /// The GPU texture of one page. It stays valid until `deinit`, so queued sprites may keep the pointer.
    pub fn pageTexture(self: *const Atlas, page: u32) *const Texture {
        return &self.pages[page];
    }

    /// The texel rectangle a sprite samples to draw a region.
    pub fn spriteSource(region: glyph_cache.Region) sprite.Rect {
        return .{
            .x = @floatFromInt(region.x),
            .y = @floatFromInt(region.y),
            .w = @floatFromInt(region.w),
            .h = @floatFromInt(region.h),
        };
    }

    /// The flush counters.
    pub fn flushStats(self: *const Atlas) FlushStats {
        return self.flush_stats;
    }

    /// Writes every texel changed since the last acknowledged flush. Call `completeFlush` only after successful frame
    /// submission; otherwise the next frame records the same regions again. Two steps, in this order, for each
    /// page:
    ///   1. GPU, always. The page's changed regions are gathered and recorded into `cmd`, the frame's command buffer,
    ///      before the sprite upload. Nothing in this step reads `sdl2d_active`, so pending glyphs reach the GPU whichever
    ///      renderer is active.
    ///   2. 2D, only the 2D copy. `plan2d` reads `sdl2d_active` and decides whether the copy is made, updated, or released.
    ///      A GPU-only frame releases any copy and writes nothing to it.
    pub fn flush(
        self: *Atlas,
        cmd: *backend.CommandBuffer,
        sdl2d_active: bool,
    ) FlushError!void {
        const size = self.cache.page_size;
        const stats = &self.flush_stats;
        stats.flushes += 1;
        var regions: [glyph_cache.max_pending]texture.CoverageRegion = undefined;
        try self.spill_regions.resize(self.allocator, self.cache.pendingSpill().len);
        var recorded_any = false;

        for (self.pages, 0..) |*page_texture, index| {
            const page: u32 = @intCast(index);

            // Step 1, GPU: unconditional.
            const gathered = gatherPage(&self.cache, page, &regions, self.spill_regions.items);
            const count = gathered.total();
            if (count > 0) {
                if (gathered.fixed > 0) {
                    try texture.recordCoverageGpu(page_texture, cmd, regions[0..gathered.fixed]);
                }
                if (gathered.spill > 0) {
                    try texture.recordCoverageGpu(page_texture, cmd, self.spill_regions.items[0..gathered.spill]);
                }
                recorded_any = true;
                stats.gpu_regions += count;
                for (regions[0..gathered.fixed]) |region| {
                    stats.gpu_upload_bytes += @as(u64, region.w) * region.h;
                }
                for (self.spill_regions.items[0..gathered.spill]) |region| {
                    stats.gpu_upload_bytes += @as(u64, region.w) * region.h;
                }
                if (self.cache.pageNeedsFullUpload(page)) stats.gpu_full_pages += 1;
            }

            // Step 2, 2D: the only place `sdl2d_active` matters.
            const valid = texture.sdl2dState(page_texture) != null;
            const in_use = self.cache.pageInUse(page);
            switch (plan2d(sdl2d_active, valid, in_use, count > 0)) {
                .none => {},
                .sync_whole_page => {
                    texture.syncCoverage2d(self.allocator, page_texture, size, size, self.cache.pagePixels(page));
                    stats.sdl2d_syncs += 1;
                },
                .update_regions => {
                    if (gathered.fixed > 0) {
                        texture.updateCoverage2d(self.allocator, page_texture, regions[0..gathered.fixed]);
                    }
                    if (gathered.spill > 0) {
                        texture.updateCoverage2d(self.allocator, page_texture, self.spill_regions.items[0..gathered.spill]);
                    }
                    stats.sdl2d_region_updates += count;
                },
                .release => {
                    if (valid) stats.sdl2d_releases += 1;
                    texture.releaseCoverage2d(page_texture);
                },
            }
            if (sdl2d_active and in_use and texture.sdl2dState(page_texture) == null) stats.sdl2d_missing_copies += 1;
        }

        if (!recorded_any) stats.idle_flushes += 1;
    }

    /// Commits the recorded changes after the frame command buffer was submitted successfully.
    pub fn completeFlush(self: *Atlas) void {
        self.cache.clearPending();
    }
};

test "a page's changed regions are gathered once, and an unchanged page gathers nothing" {
    var cache = try glyph_cache.Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 2 });
    defer cache.deinit();
    var out: [glyph_cache.max_pending]texture.CoverageRegion = undefined;
    // The white block is the only change so far.
    var spill: [0]texture.CoverageRegion = .{};
    try testing.expectEqual(@as(usize, 1), gatherPage(&cache, 0, &out, &spill).total());
    try testing.expectEqual(@as(usize, 0), gatherPage(&cache, 1, &out, &spill).total());
    cache.clearPending();
    // Nothing changed since the last flush, so nothing is uploaded.
    try testing.expectEqual(@as(usize, 0), gatherPage(&cache, 0, &out, &spill).total());
}

test "a glyph's region is gathered with the page stride, and a whole-page upload is one region" {
    var cache = try glyph_cache.Cache.init(testing.allocator, .{ .page_size = 32, .page_count = 1 });
    defer cache.deinit();
    _ = try cache.insert(
        .{ .font = 1, .glyph = 1, .size_bits = glyph_cache.sizeBits(16) },
        .{ .advance = 2, .xoff = 0, .yoff = -2, .width = 2, .height = 2 },
        &[_]u8{ 1, 2, 3, 4 },
    );
    cache.clearPending();
    _ = try cache.insert(
        .{ .font = 1, .glyph = 2, .size_bits = glyph_cache.sizeBits(16) },
        .{ .advance = 2, .xoff = 0, .yoff = -2, .width = 2, .height = 2 },
        &[_]u8{ 5, 6, 7, 8 },
    );
    var out: [glyph_cache.max_pending]texture.CoverageRegion = undefined;
    var spill: [0]texture.CoverageRegion = .{};
    try testing.expectEqual(@as(usize, 1), gatherPage(&cache, 0, &out, &spill).total());
    try testing.expectEqual(@as(u32, 2), out[0].w);
    try testing.expectEqual(@as(u32, 32), out[0].stride);
    // The second glyph sits at x = 6: the first glyph is at 3..4 and its padding is texel 5. Its first texel is 5.
    try testing.expectEqual(@as(u8, 5), out[0].coverage[0]);
    cache.clearPending();
    cache.markAllDirty();
    const full = gatherPage(&cache, 0, &out, &spill);
    try testing.expectEqual(@as(usize, 1), full.total());
    try testing.expectEqual(@as(u32, 32), out[0].w);
    try testing.expectEqual(@as(u32, 32), out[0].h);
    try testing.expect(out[0].cycle);
}

test "overflow regions gather into spill output instead of a cycling whole-page upload" {
    var cache = try glyph_cache.Cache.init(testing.allocator, .{});
    defer cache.deinit();
    cache.clearPending();
    var glyph: u32 = 0;
    while (glyph < glyph_cache.max_pending + 88) : (glyph += 1) {
        _ = try cache.insert(
            .{ .font = 1, .glyph = glyph, .size_bits = glyph_cache.sizeBits(16) },
            .{ .advance = 2, .xoff = 0, .yoff = -2, .width = 1, .height = 1 },
            &.{5},
        );
    }

    var fixed: [glyph_cache.max_pending]texture.CoverageRegion = undefined;
    var spilled = try testing.allocator.alloc(texture.CoverageRegion, cache.pendingSpill().len);
    defer testing.allocator.free(spilled);
    const counts = gatherPage(&cache, 0, &fixed, spilled);
    try testing.expectEqual(glyph_cache.max_pending, counts.fixed);
    try testing.expectEqual(@as(usize, 88), counts.spill);
    try testing.expect(!cache.pageNeedsFullUpload(0));
    for (fixed[0..counts.fixed]) |region| try testing.expect(!region.cycle);
    for (spilled[0..counts.spill]) |region| try testing.expect(!region.cycle);
}

test "the 2D copy follows the renderer: made when a used page is drawn, updated while changed, released when it leaves 2D" {
    try testing.expectEqual(Action2d.release, plan2d(false, false, true, true));
    try testing.expectEqual(Action2d.release, plan2d(false, true, true, false));
    try testing.expectEqual(Action2d.sync_whole_page, plan2d(true, false, true, false));
    try testing.expectEqual(Action2d.none, plan2d(true, false, false, false));
    try testing.expectEqual(Action2d.update_regions, plan2d(true, true, true, true));
    try testing.expectEqual(Action2d.none, plan2d(true, true, true, false));
}

test "the atlas and its flush compile against the backend" {
    std.testing.refAllDecls(Atlas);
}
