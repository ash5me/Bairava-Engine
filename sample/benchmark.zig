//! Deterministic rendering workload for measuring frame phases, GPU time, and draw submission. In a development
//! build it logs a summary once a warm-up and a full frame window have passed, so a captured run needs no reading of
//! the overlay. The run sets `gpu_timing`, so each frame waits for the GPU and the summary includes the GPU time.
//! Set `gpu_timing` to false in `config` to measure the frame rate without the wait.

const engine = @import("bairava");

const log = engine.log.scoped("benchmark");

const sprite_count: u32 = 1000;
const texture_path = "assets/sample/white.png";
/// Frames the summary covers. The frame history keeps this many, so once it holds a full window past the warm-up,
/// the summary covers exactly the frames measured.
const report_frames = engine.diagnostics.history_capacity;
/// Frames run before the summary window. Startup work, such as first-frame setup, would skew the averages.
const warmup_frames: u64 = 60;

const config = engine.Config{
    .title = "Bairava benchmark",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.06, 0.07, 0.09 },
    .settings_file = "benchmark_settings.txt",
    .gpu_timing = true,
};

const Benchmark = struct {
    texture: engine.Texture,
    reported: bool = false,

    pub fn init(ctx: *engine.Context) !Benchmark {
        return .{ .texture = try ctx.loadTexture(texture_path) };
    }

    pub fn update(self: *Benchmark, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        _ = nav;
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.diagnostics_enabled) {
            ctx.diagnostics.snapshot.world.entities = sprite_count;
            self.reportWhenReady(ctx.diagnostics);
        }
    }

    /// Logs the summary once, when the warm-up and a full window have passed. The numbers are the ones the F3
    /// overlay and the console show, so a log line and an on-screen reading can be compared directly.
    fn reportWhenReady(self: *Benchmark, collector: *engine.diagnostics.Collector) void {
        if (self.reported) return;
        if (collector.snapshot.frames < warmup_frames + report_frames) return;
        self.reported = true;
        const frame = collector.stats.of(.frame);
        const update_phase = collector.stats.of(.update);
        const draw_phase = collector.stats.of(.draw);
        const present_phase = collector.stats.of(.present);
        log.info("benchmark over {d} frames: frame avg {d:.2} p95 {d:.2} max {d:.2} ms; update avg {d:.2}, draw avg {d:.2}, present avg {d:.2} ms", .{
            frame.len,
            frame.average() * 1000.0,
            frame.percentile(0.95) * 1000.0,
            frame.max() * 1000.0,
            update_phase.average() * 1000.0,
            draw_phase.average() * 1000.0,
            present_phase.average() * 1000.0,
        });
        const gpu = collector.stats.of(.gpu);
        if (gpu.len > 0) {
            log.info("gpu avg {d:.2} p95 {d:.2} ms; each frame waited for the GPU, so the frame figures include it", .{
                gpu.average() * 1000.0,
                gpu.percentile(0.95) * 1000.0,
            });
        }
        const sprites = collector.plots.of(.sprites);
        const allocations = collector.plots.of(.allocations);
        log.info("per frame: sprites p95 {d:.0}; allocations avg {d:.0}, p95 {d:.0}; spikes {d} over {d:.0} ms", .{
            sprites.percentile(0.95),
            allocations.average(),
            allocations.percentile(0.95),
            collector.spikes.total,
            engine.diagnostics.spike_threshold_seconds * 1000.0,
        });
    }

    pub fn draw(self: *Benchmark, dc: *const engine.DrawContext) void {
        var index: u32 = 0;
        while (index < sprite_count) : (index += 1) {
            const column = index % 40;
            const row = index / 40;
            const shade = @as(f32, @floatFromInt(index % 7)) / 12.0;
            dc.batch.drawSprite(
                &self.texture,
                .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                .{
                    .x = @as(f32, @floatFromInt(column)) * 8,
                    .y = @as(f32, @floatFromInt(row)) * 6,
                    .w = 8,
                    .h = 6,
                },
                .{ .tint = .{ 0.75 + shade, 0.8, 0.9 - shade } },
            );
        }
    }

    pub fn debugText(_: *const Benchmark, out: *engine.diagnostics.Text) void {
        out.print("benchmark: {d} deterministic sprites; Escape quits", .{sprite_count});
    }

    pub fn deinit(self: *Benchmark) void {
        self.texture.deinit();
    }
};

pub fn main() !void {
    try engine.run(engine.SceneHost(Benchmark), config);
}
