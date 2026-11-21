//! TB-01 sprite rendering testbed. This is a deterministic public-API rendering workload for
//! workload tiers, texture-switch pressure, sorting, camera zoom, alpha/tint/rotation/mirroring,
//! and frame/GPU timing. The default is a 1,000-sprite normal tier. Run
//! `zig build run-tb01 -- --count 10000 --textures many --gpu-timing` for the extreme GPU-timing case.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("benchmark");

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
const default_report_frames: u64 = 120;

const Options = struct {
    count: u32 = 1_000,
    texture_mode: []const u8 = "small",
    seed: u32 = 12345,
    frames: u64 = warmup_frames + default_report_frames,
    gpu_timing: bool = false,
};

var benchmark_options = Options{};

var config = engine.Config{
    .title = "Bairava benchmark",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.06, 0.07, 0.09 },
    .settings_file = "benchmark_settings.txt",
    .gpu_timing = false,
};

const Benchmark = struct {
    primary_texture: engine.Texture,
    textures: [4]engine.Texture,
    texture_count: usize,
    entities: []Entity,
    colliders: []Collider,
    collision_queries: u64 = 0,
    collision_hits: u64 = 0,
    reported: bool = false,
    seed: u32,

    const Entity = struct {
        x: f32,
        y: f32,
        vx: f32,
    };

    pub fn init(ctx: *engine.Context) !Benchmark {
        var textures: [4]engine.Texture = undefined;
        const texture_count: usize = if (std.mem.eql(u8, benchmark_options.texture_mode, "many"))
            4
        else if (std.mem.eql(u8, benchmark_options.texture_mode, "small"))
            3
        else
            1;
        const paths = [_][]const u8{
            texture_path,
            "assets/forest_bush.png",
            "assets/forest_rock.png",
            "assets/forest_tree.png",
        };
        var loaded: usize = 0;
        errdefer for (textures[0..loaded]) |*texture| texture.deinit();
        while (loaded < texture_count) : (loaded += 1) {
            textures[loaded] = try ctx.loadTexture(paths[loaded]);
        }
        var primary = textures[0];
        _ = &primary;
        const entities = try ctx.allocators.game.alloc(Entity, @intCast(benchmark_options.count));
        errdefer ctx.allocators.game.free(entities);
        const colliders = try ctx.allocators.game.alloc(Collider, @intCast(benchmark_options.count));
        errdefer ctx.allocators.game.free(colliders);
        var seed = benchmark_options.seed;
        for (entities, 0..) |*entity, index| {
            const item_index: u32 = @intCast(index);
            const column = item_index % columns;
            const row = item_index / columns;
            seed = seed *% 1664525 +% 1013904223;
            const jitter_x: f32 = @floatFromInt(seed % 5);
            seed = seed *% 1664525 +% 1013904223;
            const jitter_y: f32 = @floatFromInt(seed % 4);
            const x = @as(f32, @floatFromInt(column)) * 8 + jitter_x;
            const y = @as(f32, @floatFromInt(row)) * 6 + jitter_y;
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
        return .{
            .primary_texture = textures[0],
            .textures = textures,
            .texture_count = texture_count,
            .entities = entities,
            .colliders = colliders,
            .seed = benchmark_options.seed,
        };
    }

    pub fn update(self: *Benchmark, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        _ = nav;
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.input.wasPressed(.equal)) ctx.zoomBy(1.25);
        if (ctx.input.wasPressed(.minus)) ctx.zoomBy(0.8);
        if (ctx.input.wasPressed(.zero)) ctx.resetZoom();
        const orbit = @as(f32, @floatFromInt(@mod(ctx.diagnostics.snapshot.frames, 240))) / 240.0;
        ctx.camera.x = @sin(orbit * std.math.pi * 2.0) * 24;
        ctx.camera.y = @cos(orbit * std.math.pi * 2.0) * 12;
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
            self.reportWhenReady(ctx.diagnostics, ctx);
        }
        if (ctx.diagnostics.snapshot.frames >= benchmark_options.frames) ctx.running = false;
    }

    /// Logs the summary once, when the warm-up and a full window have passed. The numbers are the ones the F3
    /// overlay and the console show, so a log line and an on-screen reading can be compared directly.
    fn reportWhenReady(self: *Benchmark, collector: *engine.diagnostics.Collector, ctx: *engine.Context) void {
        if (self.reported) return;
        if (collector.snapshot.frames < warmup_frames + report_frames) return;
        self.reported = true;
        const frame = collector.stats.of(.frame);
        const update_phase = collector.stats.of(.update);
        const draw_phase = collector.stats.of(.draw);
        const present_phase = collector.stats.of(.present);
        log.info("TB-01 over {d} frames: count {d}, textures {s}, seed {d}; frame avg {d:.2} median {d:.2} p95 {d:.2} p99 {d:.2} max {d:.2} ms", .{
            frame.len,
            benchmark_options.count,
            benchmark_options.texture_mode,
            benchmark_options.seed,
            frame.average() * 1000.0,
            frame.percentile(0.50) * 1000.0,
            frame.percentile(0.95) * 1000.0,
            frame.percentile(0.99) * 1000.0,
            frame.max() * 1000.0,
        });
        log.info("TB-01 phases: update avg {d:.2}, draw avg {d:.2}, present avg {d:.2} ms", .{
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
        const draws = collector.plots.of(.draw_calls);
        const allocations = collector.plots.of(.allocations);
        log.info("TB-01 per frame: sprites avg {d:.0} p95 {d:.0}; draw calls avg {d:.0} p95 {d:.0}; allocations avg {d:.0}, p95 {d:.0}; spikes {d} over {d:.0} ms", .{
            sprites.average(),
            sprites.percentile(0.95),
            draws.average(),
            draws.percentile(0.95),
            allocations.average(),
            allocations.percentile(0.95),
            collector.spikes.total,
            engine.diagnostics.spike_threshold_seconds * 1000.0,
        });
        log.info("collision workload: {d} query calls, {d} total hits", .{ self.collision_queries, self.collision_hits });

        var json: [2048]u8 = undefined;
        const text = std.fmt.bufPrint(&json,
            "{{\"testbed\":\"TB-01\",\"scenario\":\"sprite-rendering\",\"result\":\"pass\",\"count\":{d},\"texture_mode\":\"{s}\",\"seed\":{d},\"frames\":{d},\"frame_ms_avg\":{d:.3},\"frame_ms_median\":{d:.3},\"frame_ms_p95\":{d:.3},\"frame_ms_p99\":{d:.3},\"frame_ms_max\":{d:.3},\"gpu_ms_avg\":{d:.3},\"sprites_p95\":{d:.0},\"draw_calls_p95\":{d:.0},\"allocations_p95\":{d:.0}}}\n",
            .{
                benchmark_options.count,
                benchmark_options.texture_mode,
                benchmark_options.seed,
                frame.len,
                frame.average() * 1000.0,
                frame.percentile(0.50) * 1000.0,
                frame.percentile(0.95) * 1000.0,
                frame.percentile(0.99) * 1000.0,
                frame.max() * 1000.0,
                gpu.average() * 1000.0,
                sprites.percentile(0.95),
                draws.percentile(0.95),
                allocations.percentile(0.95),
            },
        ) catch "(metrics formatting failed)";
        ctx.writeFile("TB-01-sprite-rendering-results.json", text) catch |err| {
            log.err("TB-01 metrics could not be written: {s}", .{@errorName(err)});
        };
    }

    pub fn draw(self: *Benchmark, dc: *const engine.DrawContext) void {
        for (self.entities, 0..) |entity, index| {
            const shade = @as(f32, @floatFromInt(index % 7)) / 12.0;
            dc.batch.drawSprite(
                &self.textures[index % self.texture_count],
                .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                .{
                    .x = entity.x,
                    .y = entity.y,
                    .w = 8 + @as(f32, @floatFromInt(index % 3)) * 2,
                    .h = 6 + @as(f32, @floatFromInt((index / 3) % 3)) * 2,
                },
                .{
                    .tint = .{ 0.75 + shade, 0.8, 0.9 - shade },
                    .alpha = if (index % 11 == 0) 0.55 else 1,
                    .flip_x = index % 7 == 0,
                    .flip_y = index % 13 == 0,
                    .origin = .{ 4, 3 },
                    .rotation = if (index % 5 == 0) @as(f32, @floatFromInt(index % 12)) * 0.025 else 0,
                    .z = @intCast(index % 6),
                    .depth_y = if (index % 6 == 0) @as(f32, @floatFromInt(index % 91)) else 0,
                },
            );
        }
    }

    pub fn debugText(self: *const Benchmark, out: *engine.diagnostics.Text) void {
        out.print("TB-01: {d} sprites / {d} textures / seed {d}; +/- zoom, Escape quits", .{
            self.entities.len,
            self.texture_count,
            benchmark_options.seed,
        });
    }

    pub fn deinit(self: *Benchmark) void {
        for (self.textures[0..self.texture_count]) |*texture| texture.deinit();
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch |err| {
        log.err("TB-01 could not read command-line options: {s}", .{@errorName(err)});
        return err;
    };

    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--count") and arg_index + 1 < args.len) {
            arg_index += 1;
            benchmark_options.count = std.fmt.parseUnsigned(u32, args[arg_index], 10) catch 1_000;
        } else if (std.mem.eql(u8, arg, "--textures") and arg_index + 1 < args.len) {
            arg_index += 1;
            benchmark_options.texture_mode = args[arg_index];
        } else if (std.mem.eql(u8, arg, "--seed") and arg_index + 1 < args.len) {
            arg_index += 1;
            benchmark_options.seed = std.fmt.parseUnsigned(u32, args[arg_index], 10) catch 12345;
        } else if (std.mem.eql(u8, arg, "--frames") and arg_index + 1 < args.len) {
            arg_index += 1;
            benchmark_options.frames = std.fmt.parseUnsigned(u64, args[arg_index], 10) catch benchmark_options.frames;
        } else if (std.mem.eql(u8, arg, "--gpu-timing")) {
            benchmark_options.gpu_timing = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("TB-01 options: --count 100|500|1000|5000|10000 --textures one|small|many --seed 12345 --frames 180 --gpu-timing\n", .{});
            return;
        } else {
            std.debug.print("unknown TB-01 option: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }
    if (benchmark_options.count == 0) return error.InvalidArgument;
    if (!(std.mem.eql(u8, benchmark_options.texture_mode, "one") or
        std.mem.eql(u8, benchmark_options.texture_mode, "small") or
        std.mem.eql(u8, benchmark_options.texture_mode, "many")))
    {
        return error.InvalidArgument;
    }
    config.gpu_timing = benchmark_options.gpu_timing;
    try engine.run(engine.SceneHost(Benchmark), config);
}
