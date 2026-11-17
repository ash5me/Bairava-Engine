//! The runtime glyph atlas: the glyph cache (text/glyph_cache.zig) with its coverage pages on the GPU and in the 2D
//! renderer. Phase 3 of the rendering migration plan.
//!
//! Frame use:
//!   1. A text draw calls `lookup` on the cache. On a miss it rasterizes the glyph and calls `insert`.
//!   2. Before the frame's sprite upload, `flush` writes every texel changed since the last flush. It records the GPU
//!      copies into the frame's command buffer, and it updates the 2D renderer's copies at once.
//!   3. Sprites draw from `pageTexture(region.page)`, with the texel rectangle from `spriteSource`.
//!
//! Why this is safe with frames in flight:
//!   - A glyph's texels are written once and never move (see glyph_cache.zig). A frame still in flight may read them, but
//!     no later write touches them.
//!   - A flush records its copies into the same command buffer as the sprite draws that sample them, before the draws, so
//!     SDL orders the copy first. The sprite upload is recorded after `flush`, which is why the caller must flush first.
//!   - Queued sprites hold the page texture pointer, and a page texture lives until `deinit`. The pages never change size.
//!   - `deinit` and `Cache.clear` rewrite or free GPU objects, so the caller must wait for the GPU to go idle first.
//!
//! Threading: the atlas belongs to the render thread, like the cache it owns.

const std = @import("std");
const glyph_cache = @import("../text/glyph_cache.zig");
const sprite = @import("sprite.zig");
const texture = @import("texture.zig");
const backend = @import("backends/sdl_gpu/backend.zig");

const Texture = texture.Texture;

pub const Atlas = struct {
    allocator: std.mem.Allocator,
    cache: glyph_cache.Cache,
    /// One coverage texture per cache page. Created once by `init`, so every sprite's page pointer stays valid.
    pages: []Texture,

    /// Builds the cache and one coverage texture per page. Every page starts blank on the GPU. The cache lists the white
    /// block as changed, so the first flush uploads it. Needs an active 2D renderer, since each page also gets a 2D copy.
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
            pages[made] = texture.createCoverage(allocator, device, size, size, blank);
        }
        return .{ .allocator = allocator, .cache = cache, .pages = pages };
    }

    /// Releases the page textures and the cache. Call only after the GPU is idle.
    pub fn deinit(self: *Atlas) void {
        for (self.pages) |*page| page.deinit();
        self.allocator.free(self.pages);
        self.cache.deinit();
        self.* = undefined;
    }

    /// The texture of one page. It stays valid until `deinit`, so queued sprites may keep the pointer.
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

    /// Writes every texel changed since the last flush to its page, then clears the changed list. A page that needs a
    /// whole-page upload is written whole, and its listed regions are skipped. `cmd` is the frame's command buffer, and
    /// the call must come before the sprite upload that samples these texels.
    pub fn flush(self: *Atlas, cmd: *backend.CommandBuffer) void {
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
            if (count > 0) {
                texture.updateCoverageRegions(self.allocator, page_texture, cmd, regions[0..count]);
            }
        }
        self.cache.clearPending();
    }
};

test "the atlas and its flush compile against the backend" {
    std.testing.refAllDecls(Atlas);
}
