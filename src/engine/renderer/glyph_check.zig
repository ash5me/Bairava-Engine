//! Development check for the runtime glyph atlas (Phase 4 of the text and font system migration plan).
//!
//! It draws outline text through the glyph atlas, one glyph at a time, and logs the atlas counters every few hundred
//! frames. Run it with the GPU validation layer on to check two things:
//!   - every glyph is uploaded before a draw samples it, while new glyphs keep arriving (each new phrase brings glyphs
//!     the cache has not seen, so uploads keep happening while earlier frames are still in flight);
//!   - the counters match the picture: misses stop once a phrase is warm, and `sdl2d copies missing` stays 0.
//!   - the whole-page path runs: on frame 60 a burst of new glyphs overflows the pending list, and the log must report
//!     one whole-page upload for that flush.
//!
//! The shipped engine has it off. `enabled` below is on for the GPU run, so set it to false before you ship. To run it,
//! run `zig build run -Dgpu-debug=true` and watch the log for "glyph check" lines and for validation errors.
//!
//! The text uses the codepoint minus 29 as the glyph ID. That is the Arial layout this project ships: A is 36, V is 57,
//! T is 55, and R is 53, as checks/hb_linux_RESULTS.txt measured. The check skips shaping, so kerning is not applied.
//! It tests the atlas, not the text API. Phase 5 replaces this mapping with shaping.

const std = @import("std");

const staging = @import("../assets/staging.zig");
const logging = @import("../logging/log.zig");
const glyph_cache = @import("../text/glyph_cache.zig");
const resolver = @import("../text/glyph_resolver.zig");
const runtime_font = @import("../text/runtime_font.zig");
const backend = @import("backends/sdl_gpu/backend.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const sprite = @import("sprite.zig");

const elog = logging.scoped("glyph check");

/// Set to true to run the check. The shipped engine has it off. lifecycle.zig reads this to decide whether to create
/// the check at all.
pub const enabled: bool = true;

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

/// The burst: on `burst_frame`, the check queues `burst_size` glyphs that have ink, and the frame flushes them all at
/// once. Each new glyph is one pending region, so more than `glyph_cache.max_pending` of them overflow the list, and
/// the page takes a whole-page upload. The burst's glyphs are drawn too, so their samples come after that upload in
/// the same frame.
const burst_size: usize = 600;
/// The phrases use glyph IDs 3 to 97, so the burst starts above them and every burst glyph is new to the cache.
const burst_first_glyph: u32 = 200;
const burst_frame: u64 = 60;
const burst_columns: usize = 40;

comptime {
    if (burst_size <= glyph_cache.max_pending) {
        @compileError("the burst must queue more glyphs than glyph_cache.max_pending, or it never overflows the pending list");
    }
}

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
    const burst_now = state.frame_count == burst_frame;
    if (burst_now) queueBurst(state, batch);
    // The whole-page count is read before the flush, so only this flush's whole-page uploads are counted.
    const full_pages_before = state.atlas.flushStats().gpu_full_pages;
    state.atlas.flush(cmd, sdl2d_active);
    if (burst_now) reportBurst(state, full_pages_before);
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

/// Queues the burst's glyphs. It takes the first `burst_size` glyphs with ink from `burst_first_glyph` on, resolves each
/// (each one is a new cache entry), and draws it in a grid. The log gives the count found and the count new to the
/// cache, so a burst that adds nothing new shows up in the log.
fn queueBurst(state: *State, batch: *sprite.SpriteBatch) void {
    const misses_before = state.atlas.cache.snapshot().misses;
    var inked: usize = 0;
    var glyph: u32 = burst_first_glyph;
    while (inked < burst_size and glyph < state.font.glyph_count) : (glyph += 1) {
        const metrics = state.font.glyphMetrics(glyph) catch continue;
        // A glyph with no ink takes no atlas space and queues no region, so it is not part of the burst.
        if (metrics.width == 0 or metrics.height == 0) continue;
        const entry = resolver.resolve(&state.atlas.cache, font_id, &state.font, glyph, .gray) catch |err| {
            state.failures += 1;
            elog.err("burst glyph {d} not drawn: {s}", .{ glyph, @errorName(err) });
            continue;
        };
        batch.drawSprite(
            state.atlas.pageTexture(entry.region.page),
            glyph_atlas.Atlas.spriteSource(entry.region),
            .{
                .x = 4 + @as(f32, @floatFromInt(inked % burst_columns)) * 8,
                .y = 4 + @as(f32, @floatFromInt(inked / burst_columns)) * 12,
                .w = @floatFromInt(entry.region.w),
                .h = @floatFromInt(entry.region.h),
            },
            .{},
        );
        inked += 1;
    }
    const new_glyphs = state.atlas.cache.snapshot().misses - misses_before;
    if (inked < burst_size) {
        elog.err("burst: only {d} glyphs with ink from ID {d} on; the burst needs {d}", .{ inked, burst_first_glyph, burst_size });
    }
    elog.info("burst: {d} glyphs with ink queued, {d} new to the cache, against a pending limit of {d}", .{
        inked, new_glyphs, glyph_cache.max_pending,
    });
}

/// Reports whether the burst's flush made a whole-page upload. A burst that does not overflow the pending list leaves the
/// page on incremental uploads, and the check would then miss the path it exists to test.
fn reportBurst(state: *State, full_pages_before: u64) void {
    const full_pages = state.atlas.flushStats().gpu_full_pages - full_pages_before;
    if (full_pages > 0) {
        elog.info("burst: whole-page upload in the burst's flush, as expected: {d} page(s)", .{full_pages});
    } else {
        elog.err("burst: no whole-page upload in the burst's flush, so the overflow path did not run", .{});
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
