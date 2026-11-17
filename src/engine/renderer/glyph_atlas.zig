//! The runtime glyph atlas: the glyph cache (text/glyph_cache.zig) with its coverage pages on the GPU and, while the 2D
//! renderer is in use, in the 2D renderer. Phase 3 of the rendering migration plan. Decisions P3-1 and P3-2 are recorded
//! in docs/Bairava_Phase0/Bairava-Engine-Rendering-Migration-Plan.phase0-status.md, section 21.
//!
//! Frame use (Phase 5 wires this in; see the insertion point in section 21):
//!   1. A text draw calls `lookup` on the cache. On a miss it rasterizes the glyph and calls `insert`.
//!   2. Before the frame's sprite upload and before the 2D branch, `flush(cmd, renderer == .sdl2d)` writes every texel
//!      changed since the last flush. The GPU copies are recorded into `cmd`. The 2D copy follows the renderer: it is made
//!      when the 2D renderer first draws a used page, updated while the 2D renderer is active, and released when the
//!      renderer leaves 2D.
//!   3. Sprites draw from `pageTexture(region.page)`, with the texel rectangle from `spriteSource`.
//!
//! Why this is safe with frames in flight:
//!   - A glyph's texels are written once and never move (see glyph_cache.zig). A frame still in flight may read them, and
//!     no later write touches them.
//!   - The GPU copies are recorded into the same command buffer as the sprite draws that sample them, before those draws,
//!     which is the same order the sprite vertex upload relies on.
//!   - A 2D copy is only ever released or rebuilt between frames, in `flush`, which runs before any 2D draw of the frame.
//!     Queued sprites hold the GPU page texture pointer, and that texture lives until `deinit`. Pages never change size.
//!   - `deinit` and `Cache.clear` rewrite or free GPU objects, so the caller must wait for the GPU to go idle first.
//!
//! Memory: the GPU pages cost 1 MiB each in R8 and 1 MiB each in the CPU mirror. A page's 2D copy costs 4 MiB (RGBA) and
//! exists only while the 2D renderer is active and the page is in use. A GPU-only session therefore carries no 2D copies.
//!
//! Threading: the atlas belongs to the render thread, like the cache it owns.

const std = @import("std");
const testing = std.testing;
const glyph_cache = @import("../text/glyph_cache.zig");
const sprite = @import("sprite.zig");
const texture = @import("texture.zig");
const backend = @import("backends/sdl_gpu/backend.zig");

const Texture = texture.Texture;

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

/// The 2D copy's plan for one page. `valid` says whether the copy currently exists, which is the only state the copy
/// can be in: a copy exists only after a 2D flush, and a flush outside 2D releases it. `in_use` says whether the page
/// holds any glyph, and `changed` says whether the page has changed regions since the last flush.
pub fn plan2d(want_2d: bool, valid: bool, in_use: bool, changed: bool) Action2d {
    if (!want_2d) return .release;
    if (!valid) return if (in_use) .sync_whole_page else .none;
    return if (changed) .update_regions else .none;
}

pub const Atlas = struct {
    allocator: std.mem.Allocator,
    cache: glyph_cache.Cache,
    /// One GPU coverage texture per cache page. Created once by `init`, so every sprite's page pointer stays valid.
    pages: []Texture,

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
        self.cache.deinit();
        self.* = undefined;
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

    /// Writes every texel changed since the last flush. The GPU copies are recorded into `cmd`, the frame's command buffer,
    /// which must come before the sprite upload that samples these texels. The 2D copies follow `want_2d` (pass
    /// `renderer == .sdl2d`), as `plan2d` decides. A page that needs a whole-page upload is written whole, and its listed
    /// regions are skipped. Then the changed list is cleared.
    pub fn flush(self: *Atlas, cmd: *backend.CommandBuffer, want_2d: bool) void {
        const size = self.cache.page_size;
        var regions: [glyph_cache.max_pending]texture.CoverageRegion = undefined;
        for (self.pages, 0..) |*page_texture, index| {
            const page: u32 = @intCast(index);
            var count: usize = 0;
            if (self.cache.pageNeedsFullUpload(page)) {
                regions[0] = .{ .x = 0, .y = 0, .w = size, .h = size, .stride = size, .coverage = self.cache.pagePixels(page) };
                count = 1;
            } else {
                for (self.cache.pendingRegions()) |region| {
                    if (region.page != page) continue;
                    regions[count] = .{
                        .x = region.x,
                        .y = region.y,
                        .w = region.w,
                        .h = region.h,
                        .stride = size,
                        .coverage = self.cache.regionCoverage(region),
                    };
                    count += 1;
                }
            }
            if (count > 0) texture.recordCoverageGpu(page_texture, cmd, regions[0..count]);

            const valid = texture.sdl2dState(page_texture) != null;
            switch (plan2d(want_2d, valid, self.cache.pageInUse(page), count > 0)) {
                .none => {},
                .sync_whole_page => texture.syncCoverage2d(self.allocator, page_texture, size, size, self.cache.pagePixels(page)),
                .update_regions => texture.updateCoverage2d(self.allocator, page_texture, regions[0..count]),
                .release => texture.releaseCoverage2d(page_texture),
            }
        }
        self.cache.clearPending();
    }
};

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
