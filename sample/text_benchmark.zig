//! Deterministic font-path reference scene. Run with `zig build run-text-benchmark` and capture it on both renderers.

const engine = @import("bairava");

const log = engine.log.scoped("text-benchmark");
const warmup_frames: u64 = 60;
const report_frames: u64 = engine.diagnostics.history_capacity;
const white = engine.ui.Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
const config = engine.Config{
    .title = "Bairava text benchmark",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.06, 0.07, 0.09 },
    .settings_file = "benchmark_settings.txt",
    .gpu_timing = true,
};

const TextBenchmark = struct {
    bitmap: engine.ui.Canvas,
    bfnt: engine.ui.Canvas,
    runtime_latin: engine.ui.Canvas,
    runtime_tamil: engine.ui.Canvas,
    msdf: engine.ui.Canvas,
    started: engine.ui.FontProfileStats = .{},
    reported: bool = false,

    pub fn init(ctx: *engine.Context) !TextBenchmark {
        const bitmap = try ctx.loadBitmapFont("assets/fonts/font8x8_basic.fnt");
        const bfnt = try ctx.loadFont("assets/ui_font_9px.bfnt", 9);
        const runtime_latin = try ctx.loadOutlineFont("assets/fonts/font.ttf", 16);
        const runtime_tamil = try ctx.loadOutlineFont("assets/fonts/tamilfont.ttf", 24);
        const msdf = try ctx.loadMsdfFont("assets/default_font_msdf_24px.mfnt", 24);
        const allocator = ctx.allocators.game;
        return .{
            .bitmap = engine.ui.Canvas.create(allocator, ctx.fonts, bitmap),
            .bfnt = engine.ui.Canvas.create(allocator, ctx.fonts, bfnt),
            .runtime_latin = engine.ui.Canvas.create(allocator, ctx.fonts, runtime_latin),
            .runtime_tamil = engine.ui.Canvas.create(allocator, ctx.fonts, runtime_tamil),
            .msdf = engine.ui.Canvas.create(allocator, ctx.fonts, msdf),
        };
    }

    pub fn update(self: *TextBenchmark, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        _ = nav;
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.diagnostics_enabled and ctx.diagnostics.snapshot.frames >= warmup_frames and self.started.shape_calls == 0) {
            self.started = ctx.fonts.profileStats();
        }
        if (ctx.diagnostics_enabled and ctx.diagnostics.snapshot.frames >= warmup_frames + report_frames) {
            self.reportWhenReady(ctx);
        }
    }

    pub fn draw(self: *TextBenchmark, dc: *const engine.DrawContext) void {
        self.bitmap.clear();
        self.bitmap.text(8, 8, "BITMAP 0123456789 ?", white);
        self.bitmap.queue(dc.batch, 1000);

        self.bfnt.clear();
        self.bfnt.text(8, 22, "BFNT coverage: AVATAR", white);
        self.bfnt.queue(dc.batch, 1000);

        self.runtime_latin.clear();
        self.runtime_latin.text(8, 40, "Runtime: AVATAR a\u{0305}", white);
        self.runtime_latin.queue(dc.batch, 1000);

        self.runtime_tamil.clear();
        self.runtime_tamil.text(8, 68, "தமிழ் க்ஷ", white);
        self.runtime_tamil.queue(dc.batch, 1000);

        self.msdf.clear();
        self.msdf.text(8, 110, "MSDF: Aa 0123", white);
        self.msdf.text(8, 140, "F10: renderer mode", white);
        self.msdf.queue(dc.batch, 1000);
    }

    fn reportWhenReady(self: *TextBenchmark, ctx: *const engine.Context) void {
        if (self.reported) return;
        self.reported = true;
        const current = ctx.fonts.profileStats();
        const frames = ctx.diagnostics.stats.of(.frame);
        log.info(
            "text workload over {d} frames: frame avg {d:.2} p95 {d:.2} ms; shaping {d} calls/{d} ms, measure {d} calls/{d} ms; cache hits {d}, misses {d}, rasterized {d}; atlas {d} page(s), {d} CPU bytes, {d} uploaded bytes in {d} regions",
            .{
                frames.len,
                frames.average() * 1000.0,
                frames.percentile(0.95) * 1000.0,
                current.shape_calls - self.started.shape_calls,
                @as(f64, @floatFromInt(current.shape_nanoseconds - self.started.shape_nanoseconds)) / 1_000_000.0,
                current.measure_calls - self.started.measure_calls,
                @as(f64, @floatFromInt(current.measure_nanoseconds - self.started.measure_nanoseconds)) / 1_000_000.0,
                current.glyph_cache_hits - self.started.glyph_cache_hits,
                current.glyph_cache_misses - self.started.glyph_cache_misses,
                current.glyphs_rasterized - self.started.glyphs_rasterized,
                current.atlas_pages,
                current.atlas_cpu_bytes,
                current.atlas_gpu_upload_bytes - self.started.atlas_gpu_upload_bytes,
                current.atlas_gpu_upload_regions - self.started.atlas_gpu_upload_regions,
            },
        );
        log.info("last frame draw calls: {d}; use F10 to compare SDL_GPU and SDL3 2D", .{ctx.diagnostics.snapshot.world.draw_calls});
    }

    pub fn debugText(_: *const TextBenchmark, out: *engine.diagnostics.Text) void {
        out.print("Text reference: bitmap, BFNT, Latin, Tamil, MSDF; Escape quits", .{});
    }

    pub fn deinit(self: *TextBenchmark) void {
        self.msdf.deinit();
        self.runtime_tamil.deinit();
        self.runtime_latin.deinit();
        self.bfnt.deinit();
        self.bitmap.deinit();
    }
};

pub fn main() !void {
    try engine.run(engine.SceneHost(TextBenchmark), config);
}
