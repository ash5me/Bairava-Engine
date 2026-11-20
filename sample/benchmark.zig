//! Deterministic rendering workload for measuring frame phases, GPU time, and draw submission. In a development
//! build it logs a summary once a warm-up and a full frame window have passed, so a captured run needs no reading of
//! the overlay. The run sets `gpu_timing`, so each frame waits for the GPU and the summary includes the GPU time.
//! Set `gpu_timing` to false in `config` to measure the frame rate without the wait.

const engine = @import("bairava");

const log = engine.log.scoped("benchmark");

const entity_count: u32 = 10_000;
const collision_queries_per_update: u32 = 1_000;
const columns: u32 = 100;
const texture_path = "assets/sample/white.png";
const Collider = engine.physics.broad_phase.Collider;
const CollisionIndex = engine.physics.broad_phase.Index;
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
    entities: []Entity,
    colliders: []Collider,
    collision_queries: u64 = 0,
    collision_hits: u64 = 0,
    reported: bool = false,

    const Entity = struct {
        x: f32,
        y: f32,
        vx: f32,
    };

    pub fn init(ctx: *engine.Context) !Benchmark {
        var texture = try ctx.loadTexture(texture_path);
        errdefer texture.deinit();
        const entities = try ctx.allocators.game.alloc(Entity, @intCast(entity_count));
        const colliders = try ctx.allocators.game.alloc(Collider, @intCast(entity_count));
        for (entities, 0..) |*entity, index| {
            const item_index: u32 = @intCast(index);
            const column = item_index % columns;
            const row = item_index / columns;
            const x = @as(f32, @floatFromInt(column)) * 8;
            const y = @as(f32, @floatFromInt(row)) * 6;
            entity.* = .{
                .x = x,
                .y = y,
                .vx = 8 + @as(f32, @floatFromInt(index % 5)),
            };
            colliders[index] = .{
                .box = .{ .x = x, .y = y, .w = 8, .h = 6 },
                .layer = 1,
            };
        }
        return .{ .texture = texture, .entities = entities, .colliders = colliders };
    }

    pub fn update(self: *Benchmark, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        _ = nav;
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        for (self.entities, 0..) |*entity, index| {
            entity.x += entity.vx * ctx.dt;
            if (entity.x >= 800) entity.x -= 800;
            self.colliders[index].box.x = entity.x;
        }
        var collision_index = CollisionIndex.init(ctx.allocators.frame, self.colliders, 16) catch |err| {
            log.err("collision benchmark index build failed: {s}", .{@errorName(err)});
            ctx.running = false;
            return;
        };
        defer collision_index.deinit();
        var hits: u64 = 0;
        for (0..collision_queries_per_update) |query| {
            const query_index: u32 = @intCast(query);
            const x: f32 = @floatFromInt((query_index *% 37) % 800);
            const y: f32 = @floatFromInt((query_index *% 19) % 600);
            var results: [64]usize = undefined;
            hits += @intCast(collision_index.queryRegion(
                .{ .x = x, .y = y, .w = 32, .h = 24 },
                1,
                &results,
            ));
        }
        self.collision_queries += collision_queries_per_update;
        self.collision_hits += hits;
        if (ctx.diagnostics_enabled) {
            ctx.diagnostics.snapshot.world.entities = @intCast(self.entities.len);
            ctx.diagnostics.snapshot.world.collision_queries += collision_queries_per_update;
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
        log.info("collision workload: {d} query calls, {d} total hits", .{ self.collision_queries, self.collision_hits });
    }

    pub fn draw(self: *Benchmark, dc: *const engine.DrawContext) void {
        for (self.entities, 0..) |entity, index| {
            const shade = @as(f32, @floatFromInt(index % 7)) / 12.0;
            dc.batch.drawSprite(
                &self.texture,
                .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                .{
                    .x = entity.x,
                    .y = entity.y,
                    .w = 8,
                    .h = 6,
                },
                .{ .tint = .{ 0.75 + shade, 0.8, 0.9 - shade } },
            );
        }
    }

    pub fn debugText(_: *const Benchmark, out: *engine.diagnostics.Text) void {
        out.print("benchmark: {d} moving entities / sprites; Escape quits", .{entity_count});
    }

    pub fn deinit(self: *Benchmark) void {
        self.texture.deinit();
    }
};

pub fn main() !void {
    try engine.run(engine.SceneHost(Benchmark), config);
}
