//! Deterministic font-path reference scene. Run with `zig build run-text-benchmark` and capture it on both renderers.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("text-benchmark");
const warmup_frames: u64 = 60;
const report_frames: u64 = engine.diagnostics.history_capacity;
const white = engine.ui.Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
var config = engine.Config{
    .title = "Bairava text benchmark",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.06, 0.07, 0.09 },
    .settings_file = "benchmark_settings.txt",
    .gpu_timing = false,
};

const Options = struct {
    count: u32 = 100,
    frames: u64 = warmup_frames + report_frames,
    gpu_timing: bool = false,
};
var options = Options{};

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
        if (ctx.diagnostics_enabled and ctx.diagnostics.snapshot.frames >= options.frames) {
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
        var latin_row: u32 = 0;
        while (latin_row < @min(options.count / 20, 6)) : (latin_row += 1) {
            self.runtime_latin.text(170, 8 + @as(f32, @floatFromInt(latin_row)) * 14, "Aa 0123 ? AV", white);
        }
        self.runtime_latin.queue(dc.batch, 1000);

        self.runtime_tamil.clear();
        self.runtime_tamil.text(8, 68, "தமிழ் க்ஷ", white);
        self.runtime_tamil.queue(dc.batch, 1000);

        self.msdf.clear();
        self.msdf.text(8, 110, "MSDF: Aa 0123", white);
        self.msdf.text(8, 140, "F10: renderer mode", white);
        self.msdf.queue(dc.batch, 1000);
    }

    fn reportWhenReady(self: *TextBenchmark, ctx: *engine.Context) void {
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
        var json: [2048]u8 = undefined;
        const text = std.fmt.bufPrint(&json,
            "{{\"testbed\":\"TB-03\",\"scenario\":\"text-font-rendering\",\"result\":\"pass\",\"count\":{d},\"frames\":{d},\"frame_ms_avg\":{d:.3},\"frame_ms_p95\":{d:.3},\"shape_calls\":{d},\"measure_calls\":{d},\"glyph_cache_hits\":{d},\"glyph_cache_misses\":{d},\"glyphs_rasterized\":{d},\"atlas_pages\":{d},\"atlas_cpu_bytes\":{d},\"atlas_upload_bytes\":{d},\"atlas_upload_regions\":{d}}}\n",
            .{
                options.count,
                frames.len,
                frames.average() * 1000.0,
                frames.percentile(0.95) * 1000.0,
                current.shape_calls - self.started.shape_calls,
                current.measure_calls - self.started.measure_calls,
                current.glyph_cache_hits - self.started.glyph_cache_hits,
                current.glyph_cache_misses - self.started.glyph_cache_misses,
                current.glyphs_rasterized - self.started.glyphs_rasterized,
                current.atlas_pages,
                current.atlas_cpu_bytes,
                current.atlas_gpu_upload_bytes - self.started.atlas_gpu_upload_bytes,
                current.atlas_gpu_upload_regions - self.started.atlas_gpu_upload_regions,
            },
        ) catch "(metrics formatting failed)";
        ctx.writeFile("TB-03-text-font-rendering-results.json", text) catch |err| {
            log.err("TB-03 metrics could not be written: {s}", .{@errorName(err)});
        };
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

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch return error.InvalidArgument;
    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--count") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.count = std.fmt.parseUnsigned(u32, args[arg_index], 10) catch 100;
        } else if (std.mem.eql(u8, arg, "--frames") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.frames = std.fmt.parseUnsigned(u64, args[arg_index], 10) catch options.frames;
        } else if (std.mem.eql(u8, arg, "--gpu-timing")) {
            options.gpu_timing = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("TB-03 options: --count 100|500|1000 --frames 180 --gpu-timing\n", .{});
            return;
        } else {
            return error.InvalidArgument;
        }
    }
    if (!(options.count == 100 or options.count == 500 or options.count == 1000)) return error.InvalidArgument;
    config.gpu_timing = options.gpu_timing;
    try engine.run(engine.SceneHost(TextBenchmark), config);
}
