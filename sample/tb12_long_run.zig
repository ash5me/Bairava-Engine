//! TB-12 runs a deterministic, bounded simulation with scene, entity, asset, audio, job, and UI churn.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb12");
const Entity = struct {
    x: f32,
    y: f32,
    speed: f32,
    phase: f32,
    serial: u64,
};
const World = engine.entity.World(Entity, .aos);
const Color = engine.ui.Color;
const white = Color{ .r = 0.93, .g = 0.95, .b = 0.98, .a = 1 };
const muted = Color{ .r = 0.59, .g = 0.68, .b = 0.78, .a = 1 };
const panel = Color{ .r = 0.04, .g = 0.06, .b = 0.09, .a = 0.9 };
const entity_count_limit = 3000;
const worker_job_count = 8;
const snapshot_capacity = 128;
const event_capacity = 32;

const Options = struct {
    ticks: u64 = 3600,
    entities: u32 = 256,
    snapshot_interval: u64 = 600,
    seed: u64 = 0x12B011E7,
};

const options = struct {
    var value = Options{};
};

const config = engine.Config{
    .title = "Bairava TB-12 Long-Running Simulation",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.025, 0.035, 0.055 },
    .settings_file = "tb12_settings.txt",
};

const JobData = struct {
    seed: u64,
    checksum: u64 = 0,
};

fn runChecksum(job: *JobData) void {
    var value = job.seed;
    for (0..256) |_| {
        value ^= value << 13;
        value ^= value >> 7;
        value ^= value << 17;
    }
    job.checksum = value;
}

const ScheduledEvent = struct {
    due_tick: u64,
    serial: u64,
};

const ResourceSnapshot = struct {
    tick: u64,
    entities: usize,
    texture_loaded: usize,
    texture_bytes: usize,
    checkpoint_hash: u64 = 0,
    game_live_allocations: usize,
    game_live_bytes: usize,
    game_high_water_bytes: usize,
    scene_depth: usize,
    scene_switches: u32,
};

const RunState = struct {
    allocator: std.mem.Allocator = undefined,
    world: ?World = null,
    font: engine.ui.FontHandle = .invalid,
    tick: u64 = 0,
    serial: u64 = 0,
    seed: u64 = 0,
    rng: u64 = 0,
    animation_changes: u64 = 0,
    entity_recycles: u64 = 0,
    stale_entity_checks: u64 = 0,
    entity_cycle_failures: u64 = 0,
    scheduled_events: u64 = 0,
    executed_events: u64 = 0,
    event_queue_drops: u64 = 0,
    scene_pushes: u64 = 0,
    scene_pops: u64 = 0,
    overlay_opens: u64 = 0,
    asset_bursts: u64 = 0,
    asset_evictions: u64 = 0,
    texture_acquires: u64 = 0,
    sound_play_attempts: u64 = 0,
    sound_play_failures: u64 = 0,
    jobs_submitted: u64 = 0,
    jobs_verified: u64 = 0,
    job_failures: u64 = 0,
    snapshots: [snapshot_capacity]ResourceSnapshot = undefined,
    snapshot_count: usize = 0,
    snapshot_drops: u64 = 0,
    events: [event_capacity]ScheduledEvent = undefined,
    event_read: usize = 0,
    event_write: usize = 0,
    event_count: usize = 0,
    job_data: [worker_job_count]JobData = undefined,
    first_snapshot: ?ResourceSnapshot = null,
    min_game_bytes: usize = std.math.maxInt(usize),
    max_game_bytes: usize = 0,
    min_texture_bytes: usize = std.math.maxInt(usize),
    max_texture_bytes: usize = 0,
    min_entities: usize = std.math.maxInt(usize),
    max_entities: usize = 0,
    reports_written: bool = false,
};

var active_run: ?*RunState = null;

fn state() *RunState {
    return active_run orelse @panic("TB-12 run state is not initialized");
}

const SimulationScene = struct {
    actor_texture: engine.TextureHandle,
    actor_image: *const engine.Texture,
    font: engine.ui.FontHandle,
    canvas: engine.ui.Canvas,
    audio: *engine.audio.Audio,
    sound: ?engine.audio.Sound,
    sound_voice: ?engine.audio.Handle = null,

    pub fn init(ctx: *engine.Context) !SimulationScene {
        const run = state();
        run.allocator = ctx.allocators.game;
        run.seed = options.value.seed;
        run.rng = options.value.seed;

        try ctx.registerTexture("tb12_actor", "assets/sample/white.png");
        try ctx.registerTexture("tb12_overlay", "assets/sample/white.png");
        try ctx.registerTexture("tb12_transient", "assets/sample/white.png");

        const actor_texture = try ctx.acquireTexture("tb12_actor");
        errdefer {
            var handle = actor_texture;
            ctx.releaseTexture(&handle) catch |err| log.err("initial actor texture cleanup failed: {s}", .{@errorName(err)});
        }
        const actor_image = try ctx.textureOf(actor_texture);
        const font = try ctx.loadFont("assets/ui_font_9px.bfnt", 9);
        run.font = font;
        const canvas = engine.ui.Canvas.create(ctx.allocators.game, ctx.fonts, font);
        errdefer {
            var cleanup = canvas;
            cleanup.deinit();
            ctx.unloadFont(font) catch |err| log.err("initial UI font cleanup failed: {s}", .{@errorName(err)});
        }

        var world = World.init(ctx.allocators.game);
        errdefer world.deinit();
        for (0..options.value.entities) |index| {
            const serial: u64 = @intCast(index);
            const x_jitter = @as(f32, @floatFromInt(nextRandom(run) % 500)) / 100;
            _ = try world.spawn(.{
                .x = @as(f32, @floatFromInt(index % 32)) * 9 + 12 + x_jitter,
                .y = @as(f32, @floatFromInt(index / 32)) * 12 + 30,
                .speed = 4 + @as(f32, @floatFromInt(index % 9)),
                .phase = @as(f32, @floatFromInt(index % 60)) / 60,
                .serial = serial,
            });
            run.serial += 1;
        }

        const sound: ?engine.audio.Sound = if (ctx.audio.device != null)
            try ctx.loadSound("assets/wind1.wav")
        else
            null;

        run.world = world;
        return .{
            .actor_texture = actor_texture,
            .actor_image = actor_image,
            .font = font,
            .canvas = canvas,
            .audio = ctx.audio,
            .sound = sound,
        };
    }

    pub fn update(self: *SimulationScene, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        const run = state();
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        run.tick += 1;
        self.updateEntities(ctx.dt);
        self.scheduleAndRunEvents(ctx);

        if (run.tick % 180 == 0) self.assetBurst(ctx);
        if (run.tick % 300 == 0) self.runJobs(ctx);
        if (run.tick % 240 == 0) self.playSound(ctx);
        if (run.tick % 600 == 1) {
            nav.push(OverlayScene);
            run.scene_pushes += 1;
        }
        if (run.tick % options.value.snapshot_interval == 0) self.takeSnapshot(ctx);

        if (ctx.simulation_tick >= options.value.ticks) {
            self.writeReport(ctx, true);
            ctx.running = false;
        }
    }

    fn updateEntities(_: *SimulationScene, dt: f32) void {
        const run = state();
        const world = if (run.world) |*value| value else return;
        var row: usize = 0;
        while (row < world.count()) : (row += 1) {
            var entity = world.rows.get(row);
            entity.phase += dt * entity.speed;
            entity.x += dt * entity.speed;
            if (entity.x > 308) entity.x = 8;
            if (@floor(entity.phase) != @floor(entity.phase - dt * entity.speed)) run.animation_changes += 1;
            world.rows.set(row, entity);
        }
    }

    fn scheduleAndRunEvents(self: *SimulationScene, ctx: *engine.Context) void {
        const run = state();
        if (run.tick % 90 == 0) {
            if (run.event_count == event_capacity) {
                run.event_queue_drops += 1;
            } else {
                run.events[run.event_write] = .{ .due_tick = run.tick + 15, .serial = run.serial };
                run.event_write = (run.event_write + 1) % event_capacity;
                run.event_count += 1;
                run.serial += 1;
                run.scheduled_events += 1;
            }
        }
        while (run.event_count > 0) {
            const event = run.events[run.event_read];
            if (event.due_tick > run.tick) break;
            run.event_read = (run.event_read + 1) % event_capacity;
            run.event_count -= 1;
            self.executeEvent(ctx, event);
        }
    }

    fn executeEvent(self: *SimulationScene, ctx: *engine.Context, event: ScheduledEvent) void {
        const run = state();
        const world = if (run.world) |*value| value else return;
        if (world.count() > 0) {
            const row = @as(usize, @intCast(event.serial % world.count()));
            const stale = world.handleAt(row);
            if (world.despawn(stale)) {
                run.stale_entity_checks += @intFromBool(!world.isAlive(stale));
                const replacement = world.spawn(.{
                    .x = @as(f32, @floatFromInt(nextRandom(run) % 30000)) / 100,
                    .y = 34 + @as(f32, @floatFromInt(event.serial % 10)) * 12,
                    .speed = 4 + @as(f32, @floatFromInt(event.serial % 8)),
                    .phase = @as(f32, @floatFromInt(event.serial % 60)) / 60,
                    .serial = event.serial,
                }) catch |err| {
                    run.entity_cycle_failures += 1;
                    log.err("entity replacement failed: {s}", .{@errorName(err)});
                    return;
                };
                run.entity_recycles += 1;
                if (!world.isAlive(replacement)) run.entity_cycle_failures += 1;
                run.executed_events += 1;
            } else {
                run.entity_cycle_failures += 1;
            }
        }
        self.assetBurst(ctx);
        self.runJobs(ctx);
    }

    fn assetBurst(_: *SimulationScene, ctx: *engine.Context) void {
        const run = state();
        var handle = ctx.acquireTexture("tb12_transient") catch |err| {
            log.err("transient texture acquire failed: {s}", .{@errorName(err)});
            return;
        };
        run.texture_acquires += 1;
        ctx.releaseTexture(&handle) catch |err| {
            log.err("transient texture release failed: {s}", .{@errorName(err)});
            return;
        };
        run.asset_bursts += 1;
    }

    fn runJobs(_: *SimulationScene, ctx: *engine.Context) void {
        const run = state();
        const pool = ctx.jobs orelse {
            run.job_failures += 1;
            log.err("job pool is unavailable during the long-run scenario", .{});
            return;
        };
        var counter = std.mem.zeroes(engine.jobs.Counter);
        for (&run.job_data, 0..) |*job, index| {
            job.* = .{ .seed = run.seed ^ run.tick ^ @as(u64, @intCast(index + 1)) };
            pool.submit(&counter, JobData, job, runChecksum);
            run.jobs_submitted += 1;
        }
        pool.wait(&counter);
        for (run.job_data) |job| {
            var expected = JobData{ .seed = job.seed };
            runChecksum(&expected);
            if (expected.checksum == job.checksum) {
                run.jobs_verified += 1;
            } else {
                run.job_failures += 1;
            }
        }
    }

    fn playSound(self: *SimulationScene, ctx: *engine.Context) void {
        const sound = if (self.sound) |*value| value else return;
        const run = state();
        if (self.sound_voice) |voice| {
            if (ctx.audio.isPlaying(voice)) ctx.audio.stop(voice);
        }
        run.sound_play_attempts += 1;
        self.sound_voice = ctx.audio.play(sound, .{ .gain = 0.15, .bus = .ambience }) catch |err| blk: {
            run.sound_play_failures += 1;
            log.warn("simulation ambience playback failed: {s}", .{@errorName(err)});
            break :blk null;
        };
    }

    fn takeSnapshot(_: *SimulationScene, ctx: *engine.Context) void {
        const run = state();
        const world_count = if (run.world) |world| world.count() else 0;
        const texture_stats = ctx.textureStats();
        const memory = ctx.diagnostics.snapshot.memory;
        const checkpoint_hash = checkpointHash(run);
        const sample = ResourceSnapshot{
            .tick = run.tick,
            .entities = world_count,
            .texture_loaded = texture_stats.loaded,
            .texture_bytes = texture_stats.bytes,
            .game_live_allocations = memory.game.live_allocations,
            .game_live_bytes = memory.game.live_bytes,
            .game_high_water_bytes = memory.game.high_water_bytes,
            .scene_depth = ctx.diagnostics.snapshot.scene.depth,
            .scene_switches = ctx.diagnostics.snapshot.scene.switches,
            .checkpoint_hash = checkpoint_hash,
        };
        if (run.first_snapshot == null) run.first_snapshot = sample;
        run.min_game_bytes = @min(run.min_game_bytes, sample.game_live_bytes);
        run.max_game_bytes = @max(run.max_game_bytes, sample.game_live_bytes);
        run.min_texture_bytes = @min(run.min_texture_bytes, sample.texture_bytes);
        run.max_texture_bytes = @max(run.max_texture_bytes, sample.texture_bytes);
        run.min_entities = @min(run.min_entities, sample.entities);
        run.max_entities = @max(run.max_entities, sample.entities);
        if (run.snapshot_count < run.snapshots.len) {
            run.snapshots[run.snapshot_count] = sample;
            run.snapshot_count += 1;
        } else {
            run.snapshot_drops += 1;
        }
        log.info("TB-12 snapshot tick {d}: entities {d}, textures {d}/{d} B, game allocations {d}/{d} B (high-water {d} B), scene depth/switches {d}/{d}", .{
            sample.tick,
            sample.entities,
            sample.texture_loaded,
            sample.texture_bytes,
            sample.game_live_allocations,
            sample.game_live_bytes,
            sample.game_high_water_bytes,
            sample.scene_depth,
            sample.scene_switches,
        });
    }

    pub fn draw(self: *SimulationScene, dc: *const engine.DrawContext) void {
        const run = state();
        const world = run.world orelse return;
        var row: usize = 0;
        while (row < world.count()) : (row += 1) {
            const entity = world.rows.get(row);
            const pulse: f32 = if (@mod(@as(i64, @intFromFloat(@floor(entity.phase))), 2) == 0) 0.45 else 0.9;
            dc.batch.drawSprite(
                self.actor_image,
                .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                .{ .x = entity.x, .y = entity.y, .w = 5, .h = 7 },
                .{ .tint = .{ pulse, 0.75, 0.42 }, .depth_y = entity.y + 7 },
            );
        }

        self.canvas.clear();
        self.canvas.rect(8, 8, 304, 21, panel);
        var status: [160]u8 = undefined;
        const status_text = std.fmt.bufPrint(&status, "TB-12  tick {d}   entities {d}   events {d}   scenes {d}/{d}", .{
            run.tick,
            world.count(),
            run.executed_events,
            run.scene_pushes,
            run.scene_pops,
        }) catch "TB-12 status unavailable";
        self.canvas.text(14, 14, status_text, white);
        var detail: [160]u8 = undefined;
        const detail_text = std.fmt.bufPrint(&detail, "Q/E is not required: deterministic autonomous run | assets {d} jobs {d} animation {d}", .{
            run.asset_bursts,
            run.jobs_verified,
            run.animation_changes,
        }) catch "TB-12 metrics";
        self.canvas.text(12, 164, detail_text, muted);
        self.canvas.queue(dc.batch, 900);
    }

    fn writeReport(self: *SimulationScene, ctx: *engine.Context, reached_target: bool) void {
        const run = state();
        if (run.reports_written) return;
        run.reports_written = true;
        const world_count = if (run.world) |world| world.count() else 0;
        const texture_stats = ctx.textureStats();
        const sound_ok = run.sound_play_failures == 0 and
            (ctx.audio.device == null or (self.sound != null and run.sound_play_attempts > 0));
        const passed = reached_target and world_count == options.value.entities and run.scheduled_events > 0 and
            run.executed_events == run.scheduled_events and run.event_queue_drops == 0 and run.jobs_submitted > 0 and
            run.jobs_verified == run.jobs_submitted and run.job_failures == 0 and run.scene_pushes > 0 and
            run.scene_pops == run.scene_pushes and run.entity_cycle_failures == 0 and
            run.stale_entity_checks == run.entity_recycles and run.asset_bursts > 0 and
            run.asset_evictions > 0 and sound_ok and run.snapshot_count > 0;
        const result: []const u8 = if (passed) "pass" else "incomplete";
        log.info("TB-12 {s}: simulation ticks {d}, outer frames {d}, root ticks {d}, entities {d}, scheduled events {d}/{d}, scene pushes/pops {d}/{d}, job checks {d}/{d}, asset bursts {d}, snapshots {d} (+{d} omitted), sound failures {d}", .{
            result,
            ctx.simulation_tick,
            ctx.diagnostics.snapshot.frames,
            run.tick,
            world_count,
            run.executed_events,
            run.scheduled_events,
            run.scene_pushes,
            run.scene_pops,
            run.jobs_verified,
            run.jobs_submitted,
            run.asset_bursts,
            run.snapshot_count,
            run.snapshot_drops,
            run.sound_play_failures,
        });

        var json: [32_768]u8 = undefined;
        const first = run.first_snapshot orelse ResourceSnapshot{
            .tick = 0,
            .entities = 0,
            .texture_loaded = 0,
            .texture_bytes = 0,
            .game_live_allocations = 0,
            .game_live_bytes = 0,
            .game_high_water_bytes = 0,
            .scene_depth = 0,
            .scene_switches = 0,
            .checkpoint_hash = 0,
        };
        const last = if (run.snapshot_count > 0) run.snapshots[run.snapshot_count - 1] else first;
        const summary = std.fmt.bufPrint(
            &json,
            "{{\"testbed\":\"TB-12\",\"scenario\":\"long-running-simulation\",\"result\":\"{s}\",\"simulation_ticks\":{d},\"root_ticks\":{d},\"seed\":{d},\"entity_count\":{d},\"entity_recycles\":{d},\"stale_entity_checks\":{d},\"entity_cycle_failures\":{d},\"scheduled_events\":{d},\"executed_events\":{d},\"event_queue_drops\":{d},\"scene_pushes\":{d},\"scene_pops\":{d},\"overlay_opens\":{d},\"asset_bursts\":{d},\"asset_evictions\":{d},\"jobs_submitted\":{d},\"jobs_verified\":{d},\"job_failures\":{d},\"sound_play_attempts\":{d},\"sound_play_failures\":{d},\"animation_changes\":{d},\"texture_loaded\":{d},\"texture_bytes\":{d},\"snapshot_count\":{d},\"snapshot_drops\":{d},\"entities_min\":{d},\"entities_max\":{d},\"game_bytes_min\":{d},\"game_bytes_max\":{d},\"texture_bytes_min\":{d},\"texture_bytes_max\":{d}",
            .{
                result,
                ctx.simulation_tick,
                run.tick,
                run.seed,
                world_count,
                run.entity_recycles,
                run.stale_entity_checks,
                run.entity_cycle_failures,
                run.scheduled_events,
                run.executed_events,
                run.event_queue_drops,
                run.scene_pushes,
                run.scene_pops,
                run.overlay_opens,
                run.asset_bursts,
                run.asset_evictions,
                run.jobs_submitted,
                run.jobs_verified,
                run.job_failures,
                run.sound_play_attempts,
                run.sound_play_failures,
                run.animation_changes,
                texture_stats.loaded,
                texture_stats.bytes,
                run.snapshot_count,
                run.snapshot_drops,
                if (run.snapshot_count == 0) 0 else run.min_entities,
                run.max_entities,
                if (run.snapshot_count == 0) 0 else run.min_game_bytes,
                run.max_game_bytes,
                if (run.snapshot_count == 0) 0 else run.min_texture_bytes,
                run.max_texture_bytes,
            },
        ) catch {
            self.logFormatError();
            return;
        };
        const output = std.fmt.bufPrint(
            json[summary.len..],
            ",\"outer_frames\":{d},\"sound_available\":{d},\"checkpoint_hash_first\":{d},\"checkpoint_hash_last\":{d},\"snapshot_first\":{{\"tick\":{d},\"entities\":{d},\"game_live_bytes\":{d},\"game_high_water_bytes\":{d},\"texture_loaded\":{d},\"texture_bytes\":{d}}},\"snapshot_last\":{{\"tick\":{d},\"entities\":{d},\"game_live_bytes\":{d},\"game_high_water_bytes\":{d},\"texture_loaded\":{d},\"texture_bytes\":{d}}}}}\n",
            .{
                ctx.diagnostics.snapshot.frames,
                @intFromBool(self.sound != null),
                first.checkpoint_hash,
                last.checkpoint_hash,
                first.tick,
                first.entities,
                first.game_live_bytes,
                first.game_high_water_bytes,
                first.texture_loaded,
                first.texture_bytes,
                last.tick,
                last.entities,
                last.game_live_bytes,
                last.game_high_water_bytes,
                last.texture_loaded,
                last.texture_bytes,
            },
        ) catch {
            self.logFormatError();
            return;
        };
        ctx.writeFile("TB-12-long-run-results.json", json[0 .. summary.len + output.len]) catch |err| {
            log.err("TB-12 report could not be written: {s}", .{@errorName(err)});
            return;
        };
    }

    fn logFormatError(_: *SimulationScene) void {
        log.err("TB-12 metrics formatting exceeded its output buffer", .{});
    }

    pub fn debugText(_: *const SimulationScene, out: *engine.diagnostics.Text) void {
        const run = state();
        out.print("TB-12 deterministic run: tick {d}, entities {d}, events {d}/{d}", .{
            run.tick,
            if (run.world) |world| world.count() else 0,
            run.executed_events,
            run.scheduled_events,
        });
        out.print("scenes {d}/{d}, jobs verified {d}, snapshots {d}; Escape exits", .{
            run.scene_pushes,
            run.scene_pops,
            run.jobs_verified,
            run.snapshot_count,
        });
    }

    pub fn deinitWithContext(self: *SimulationScene, ctx: *engine.Context) void {
        self.writeReport(ctx, false);
        self.canvas.deinit();
        ctx.unloadFont(self.font) catch |err| log.err("TB-12 font cleanup failed: {s}", .{@errorName(err)});
        ctx.releaseTexture(&self.actor_texture) catch |err| log.err("TB-12 actor texture cleanup failed: {s}", .{@errorName(err)});
        _ = ctx.unloadUnusedTextures();
        if (self.sound_voice) |voice| self.audio.stop(voice);
        if (self.sound) |*sound| sound.deinit();
        if (state().world) |*world| world.deinit();
        state().world = null;
    }

    pub fn deinit(self: *SimulationScene) void {
        self.canvas.deinit();
        if (self.sound_voice) |voice| self.audio.stop(voice);
        if (self.sound) |*sound| sound.deinit();
        if (state().world) |*world| world.deinit();
        state().world = null;
    }
};

const OverlayScene = struct {
    texture: engine.TextureHandle,
    image: *const engine.Texture,
    canvas: engine.ui.Canvas,
    elapsed: u32 = 0,

    pub fn init(ctx: *engine.Context) !OverlayScene {
        var texture = try ctx.acquireTexture("tb12_overlay");
        errdefer ctx.releaseTexture(&texture) catch |err| log.err("TB-12 overlay texture cleanup failed: {s}", .{@errorName(err)});
        const image = try ctx.textureOf(texture);
        if (active_run == null) return error.InvalidRunState;
        const canvas = engine.ui.Canvas.create(ctx.allocators.game, ctx.fonts, state().font);
        state().overlay_opens += 1;
        return .{ .texture = texture, .image = image, .canvas = canvas };
    }

    pub fn update(self: *OverlayScene, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        self.elapsed += 1;
        if (self.elapsed >= 30 or ctx.simulation_tick >= options.value.ticks) {
            state().scene_pops += 1;
            nav.pop();
        }
    }

    pub fn draw(self: *OverlayScene, dc: *const engine.DrawContext) void {
        self.canvas.clear();
        self.canvas.rect(95, 67, 130, 42, panel);
        self.canvas.text(105, 75, "Scheduled event", white);
        self.canvas.text(105, 91, "Scene resumed shortly", muted);
        dc.batch.drawSprite(self.image, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, .{ .x = 102, .y = 106, .w = 116, .h = 2 }, .{ .tint = .{ 0.2, 0.55, 0.8 }, .depth_y = 108 });
        self.canvas.queue(dc.batch, 1000);
    }

    pub fn deinitWithContext(self: *OverlayScene, ctx: *engine.Context) void {
        self.canvas.deinit();
        ctx.releaseTexture(&self.texture) catch |err| log.err("TB-12 overlay texture release failed: {s}", .{@errorName(err)});
        state().asset_evictions += ctx.unloadUnusedTextures();
    }

    pub fn deinit(self: *OverlayScene) void {
        self.canvas.deinit();
    }
};

fn nextRandom(run: *RunState) u64 {
    run.rng ^= run.rng << 13;
    run.rng ^= run.rng >> 7;
    run.rng ^= run.rng << 17;
    return run.rng;
}

fn checkpointHash(run: *const RunState) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    hash = mixHash(hash, run.tick);
    hash = mixHash(hash, run.serial);
    if (run.world) |world| {
        hash = mixHash(hash, world.count());
        for (0..world.count()) |row| {
            const entity = world.rows.get(row);
            hash = mixHash(hash, floatBits(entity.x));
            hash = mixHash(hash, floatBits(entity.y));
            hash = mixHash(hash, floatBits(entity.speed));
            hash = mixHash(hash, floatBits(entity.phase));
            hash = mixHash(hash, entity.serial);
        }
    }
    return hash;
}

fn mixHash(hash: u64, value: u64) u64 {
    return (hash ^ value) *% 0x100000001b3;
}

fn floatBits(value: f32) u64 {
    return @as(u64, @as(u32, @bitCast(value)));
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch return error.InvalidArgument;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--help")) {
            std.debug.print("TB-12 options: --ticks 3600 --entities 256 --snapshot-interval 600 --seed 0x12B011E7. A 30-minute run is about --ticks 108000 at 60 updates per second.\n", .{});
            return;
        } else if (std.mem.eql(u8, args[index], "--ticks") and index + 1 < args.len) {
            index += 1;
            options.value.ticks = try std.fmt.parseUnsigned(u64, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--entities") and index + 1 < args.len) {
            index += 1;
            options.value.entities = try std.fmt.parseUnsigned(u32, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--snapshot-interval") and index + 1 < args.len) {
            index += 1;
            options.value.snapshot_interval = try std.fmt.parseUnsigned(u64, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--seed") and index + 1 < args.len) {
            index += 1;
            options.value.seed = try std.fmt.parseUnsigned(u64, args[index], 0);
        } else {
            return error.InvalidArgument;
        }
    }
    if (options.value.ticks == 0 or options.value.ticks > 100_000_000 or
        options.value.entities == 0 or options.value.entities > entity_count_limit or
        options.value.snapshot_interval == 0 or options.value.seed == 0)
    {
        return error.InvalidArgument;
    }

    const run = try std.heap.page_allocator.create(RunState);
    defer std.heap.page_allocator.destroy(run);
    run.* = .{};
    active_run = run;
    defer active_run = null;
    try engine.run(engine.SceneHost(SimulationScene), config);
}
