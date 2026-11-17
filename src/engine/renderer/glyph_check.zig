//! Development check for the runtime glyph atlas (Phase 4 of the text and font system migration plan).
//!
//! It draws outline text through the glyph atlas, one glyph at a time, and logs the atlas counters every few hundred
//! frames. Run it with the GPU validation layer on to check two things:
//!   - every glyph is uploaded before a draw samples it, while new glyphs keep arriving (each new phrase brings glyphs
//!     the cache has not seen, so uploads keep happening while earlier frames are still in flight);
//!   - the counters match the picture: misses stop once a phrase is warm, and `sdl2d copies missing` stays 0.
//!
//! Off by default. To run it, set `enabled` to true in this file, then run `zig build run -Dgpu-debug=true` and watch
//! the log for "glyph check" lines and for validation errors.
//!
//! The text uses the codepoint minus 29 as the glyph ID. That is the Arial layout this project ships: A is 36, V is 57,
//! T is 55, and R is 53, as checks/hb_linux_RESULTS.txt measured. The check skips shaping, so kerning is not applied.
//! It tests the atlas, not the text API. Phase 5 replaces this mapping with shaping.

const std = @import("std");

const staging = @import("../assets/staging.zig");
const logging = @import("../logging/log.zig");
const resolver = @import("../text/glyph_resolver.zig");
const runtime_font = @import("../text/runtime_font.zig");
const backend = @import("backends/sdl_gpu/backend.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const sprite = @import("sprite.zig");

const elog = logging.scoped("glyph check");

/// Set to true to run the check. The shipped engine has it off. lifecycle.zig reads this to decide whether to create
/// the check at all.
pub const enabled: bool = false;

/// The packaged font, relative to the package folder. The manifest row for `ui_font_ttf` writes it under assets/fonts.
/// If the log says FileNotFound, check where the font landed under zig-out\bin and change this path to match.
const font_path = "assets/fonts/font.ttf";
const pixel_height: f32 = 24;
const font_id: u32 = 1;

/// The codepoint minus this is the glyph ID in the shipped Arial. Codepoints below it are not printable here.
const glyph_offset: u32 = 29;
/// The fallback for a glyph the font does not have. It is '?', as the glyph ID the Arial layout gives it.
const question_glyph: u32 = '?' - glyph_offset;

/// Phrases drawn in turn, each for `frames_per_phrase` frames. The first pass through the list fills the cache. Each
/// later phrase brings glyphs the cache has not seen, so the atlas keeps uploading.
const phrases = [_][]const u8{
    "BAIRAVA ATLAS CHECK",
    "the quick brown fox 0123456789",
    "JUMPS OVER! THE LAZY DOG?",
    "@#$%&*()-_=+[]{};:,.<>/ ~",
};
const frames_per_phrase: u64 = 120;
const report_every: u64 = 240;
const pen_start_x: f32 = 4;
const baseline_y: f32 = 24;

pub const State = struct {
    atlas: glyph_atlas.Atlas,
    font: runtime_font.RuntimeFont,
    frame_count: u64 = 0,
    /// Glyphs that could not be drawn at all, such as AtlasFull. A fallback is not a failure, so it does not count.
    failures: u64 = 0,
};

/// Loads the font and builds the atlas. The caller destroys the state with `destroy` once the GPU is idle.
pub fn create(allocator: std.mem.Allocator, device: *backend.Device) !State {
    var font = runtime_font.RuntimeFont.loadPackaged(allocator, staging.packagedReader(), font_path, pixel_height) catch |err| {
        elog.err("could not load {s}: {s}", .{ font_path, @errorName(err) });
        return err;
    };
    errdefer font.deinit();
    var atlas = try glyph_atlas.Atlas.init(allocator, device, .{});
    errdefer atlas.deinit();
    elog.info("on: {s} at {d} px, {d} glyphs, atlas of {d} pages, {d}x{d} texels", .{
        font_path, pixel_height, font.glyph_count, atlas.cache.pages.len, atlas.cache.page_size, atlas.cache.page_size,
    });
    return .{ .atlas = atlas, .font = font };
}

/// Releases the atlas and the font. The GPU must be idle first, because the atlas owns GPU textures.
pub fn destroy(state: *State) void {
    state.atlas.deinit();
    state.font.deinit();
}

/// Queues this frame's phrase and flushes the atlas. Call it after the game has queued its sprites, and before the
/// sprite upload, outside any render pass. `sdl2d_active` is the renderer that draws this frame.
pub fn frame(state: *State, batch: *sprite.SpriteBatch, cmd: *backend.CommandBuffer, sdl2d_active: bool) void {
    const index = (state.frame_count / frames_per_phrase) % phrases.len;
    queuePhrase(state, batch, phrases[index]);
    state.atlas.flush(cmd, sdl2d_active);
    state.frame_count += 1;
    if (state.frame_count % report_every == 0) report(state);
}

fn queuePhrase(state: *State, batch: *sprite.SpriteBatch, phrase: []const u8) void {
    var pen_x: f32 = pen_start_x;
    for (phrase) |byte| {
        const glyph: u32 = if (byte >= glyph_offset) @as(u32, byte) - glyph_offset else state.font.glyph_count;
        const result = resolver.resolveWithFallback(&state.atlas.cache, font_id, &state.font, glyph, question_glyph, .gray) catch |err| {
            state.failures += 1;
            elog.err("glyph {d} ('{c}') not drawn: {s}", .{ glyph, byte, @errorName(err) });
            continue;
        };
        const entry = result.entry;
        if (entry.region.w > 0 and entry.region.h > 0) {
            batch.drawSprite(
                state.atlas.pageTexture(entry.region.page),
                glyph_atlas.Atlas.spriteSource(entry.region),
                .{
                    .x = @round(pen_x + entry.metrics.xoff),
                    .y = @round(baseline_y + entry.metrics.yoff),
                    .w = @floatFromInt(entry.region.w),
                    .h = @floatFromInt(entry.region.h),
                },
                .{},
            );
        }
        pen_x = @round(pen_x + entry.metrics.advance);
    }
}

fn report(state: *State) void {
    const stats = state.atlas.cache.snapshot();
    const flush = state.atlas.flushStats();
    elog.info(
        "frame {d}: hits {d} misses {d} rasterized {d} missing {d} entries {d} pages {d} bytes {d} | flushes {d} gpu regions {d} full pages {d} idle {d} sdl2d copies missing {d} | failures {d}",
        .{
            state.frame_count,
            stats.hits,
            stats.misses,
            stats.rasterized,
            stats.missing_glyphs,
            stats.entries,
            stats.pages_in_use,
            stats.allocated_bytes,
            flush.flushes,
            flush.gpu_regions,
            flush.gpu_full_pages,
            flush.idle_flushes,
            flush.sdl2d_missing_copies,
            state.failures,
        },
    );
    if (flush.sdl2d_missing_copies != 0 or state.failures != 0) {
        elog.err("FAIL: text was skipped or not drawn", .{});
    }
}
