//! Development check for the runtime glyph atlas (Phase 4 of the text and font system migration plan).
//!
//! It draws outline text through the glyph atlas, one glyph at a time, and logs the atlas counters every few hundred
//! frames. Run it with the GPU validation layer on to check two things:
//!   - every glyph is uploaded before a draw samples it, while new glyphs keep arriving (each new phrase brings glyphs
//!     the cache has not seen, so uploads keep happening while earlier frames are still in flight);
//!   - the counters match the picture: misses stop once a phrase is warm, and `sdl2d copies missing` stays 0.
//!   - on frame 60, a burst of 600 new glyphs overflows the fixed pending list and the log reports region uploads with
//!     no whole-page rewrite.
//!
//! The shipped engine has it off. Temporarily set `enabled` below to true for the GPU run, then restore false. Run
//! `zig build run -Dgpu-debug=true` and watch the log for "glyph check" lines and for validation errors.
//!
//! The text uses the codepoint minus 29 as the glyph ID. That is the Arial layout this project ships: A is 36, V is 57,
//! T is 55, and R is 53, as checks/hb_linux_RESULTS.txt measured. The check skips shaping, so kerning is not applied.
//! It tests the atlas, not the text API.

const std = @import("std");

const staging = @import("../assets/staging.zig");
const logging = @import("../logging/log.zig");
const glyph_cache = @import("../text/glyph_cache.zig");
const resolver = @import("../text/glyph_resolver.zig");
const font_registry = @import("../text/font_registry.zig");
const runtime_font = @import("../text/runtime_font.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const sprite = @import("sprite.zig");

const elog = logging.scoped("glyph check");

/// Set to true only for the requested GPU validation run. Restore false afterward; production text uses the same atlas.
pub const enabled: bool = false;

/// The packaged font, relative to the package folder. The manifest row for `ui_font_ttf` writes it under assets/fonts.
/// If the log says FileNotFound, check where the font landed under zig-out\bin and change this path to match.
const font_path = "assets/fonts/font.ttf";
const pixel_height: f32 = 24;
const font_id: font_registry.FontId = 0xFFFF_FFFF_FFFF_FFFE;

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

/// The burst queues enough new glyphs to overflow the fixed pending list. Those writes must stay region uploads.
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
    atlas: *glyph_atlas.Atlas,
    font: runtime_font.RuntimeFont,
    frame_count: u64 = 0,
    burst_pending: bool = false,
    burst_regions_before: u64 = 0,
    burst_full_pages_before: u64 = 0,
    /// Glyphs that could not be drawn at all, such as AtlasFull. A fallback is not a failure, so it does not count.
    failures: u64 = 0,
};

/// Loads the check font and borrows the session's shared atlas.
pub fn create(allocator: std.mem.Allocator, atlas: *glyph_atlas.Atlas) !State {
    var font = runtime_font.RuntimeFont.loadPackaged(allocator, staging.packagedReader(), font_path, pixel_height) catch |err| {
        elog.err("could not load {s}: {s}", .{ font_path, @errorName(err) });
        return err;
    };
    errdefer font.deinit();
    elog.info("on: {s} at {d} px, {d} glyphs, atlas of {d} pages, {d}x{d} texels", .{
        font_path, pixel_height, font.glyph_count, atlas.cache.pages.len, atlas.cache.page_size, atlas.cache.page_size,
    });
    return .{ .atlas = atlas, .font = font };
}

/// Releases the check font. The Session owns the shared atlas.
pub fn destroy(state: *State) void {
    state.font.deinit();
}

/// Queues this frame's phrase. The runtime performs the single atlas flush after this returns.
pub fn frame(state: *State, batch: *sprite.SpriteBatch) void {
    const index = (state.frame_count / frames_per_phrase) % phrases.len;
    queuePhrase(state, batch, phrases[index]);
    const burst_now = state.frame_count == burst_frame;
    state.burst_pending = burst_now;
    if (burst_now) {
        state.burst_regions_before = state.atlas.flushStats().gpu_regions;
        state.burst_full_pages_before = state.atlas.flushStats().gpu_full_pages;
        queueBurst(state, batch);
    }
}

/// Reports work from the runtime's shared flush, then advances the diagnostic frame.
pub fn afterFlush(state: *State) void {
    if (state.burst_pending) reportBurst(state);
    state.burst_pending = false;
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

/// Reports whether the burst was uploaded as regions without rewriting live page texels.
fn reportBurst(state: *State) void {
    const flush = state.atlas.flushStats();
    const regions = flush.gpu_regions - state.burst_regions_before;
    const full_pages = flush.gpu_full_pages - state.burst_full_pages_before;
    if (full_pages == 0 and regions >= burst_size) {
        elog.info("burst: overflow spill uploaded as {d} regions, no whole-page rewrite", .{regions});
    } else {
        elog.err("burst: expected at least {d} region uploads and no whole-page rewrite, got {d} regions and {d} full pages", .{
            burst_size, regions, full_pages,
        });
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
