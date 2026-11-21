//! TB-22 Particle Pool and Overdraw Stress Test.
//! Stresses fixed-capacity particle storage, burst saturation, continuous emission, producer
//! shutdown, deterministic pool reuse, translucent rendering, and camera movement.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb22");
const System = engine.particles.System;
const Particle = engine.particles.Particle;

const Options = struct {
    capacity: usize = 1024,
    frames: u64 = 180,
    burst_size: usize = 0,
};

var options = Options{};

const config = engine.Config{
    .title = "Bairava TB-22 Particle Pool and Overdraw",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.035, 0.045, 0.065 },
    .settings_file = "tb22_settings.txt",
};

const world_w: f32 = 1200;
const world_h: f32 = 700;
const burst_interval: u64 = 18;
const emitter_lifetime_ticks: u64 = 90;
const continuous_emission_rate: f32 = 72;

const Tb22 = struct {
    particles: System,
    texture: engine.Texture,
    producer_position: [2]f32 = .{ world_w / 2, world_h / 2 },
    emitter_active: bool = true,
    emitter_stopped: bool = false,
    ticks: u64 = 0,
    burst_requests: u64 = 0,
    spawned: u64 = 0,
    dropped: u64 = 0,
    expired: u64 = 0,
    peak_active: usize = 0,
    total_drawn: u64 = 0,
    total_drawn_area: f64 = 0,
    draw_samples: u64 = 0,
    reuse_checks: u64 = 0,
    reuse_failures: u64 = 0,
    count_at_emitter_stop: usize = 0,
    survivors_after_emitter_stop: usize = 0,
    report_written: bool = false,
    moving_camera: bool = true,

    pub fn init(ctx: *engine.Context) !Tb22 {
        var particles = try System.init(ctx.allocators.game, options.capacity, 0x22BADA55);
        errdefer particles.deinit();
        try particles.setConfig(.{
            .lifetime = .{ 0.7, 2.4 },
            .speed = .{ 18, 88 },
            .angle = .{ -std.math.pi, std.math.pi },
            .size = .{ 3, 13 },
            .end_size = 1,
            .color = .{ 1, 0.45, 0.1, 0.86 },
            .end_color = .{ 0.2, 0.45, 1, 0 },
            .gravity = .{ 0, 20 },
        });
        var texture = try ctx.loadTexture("assets/sample/white.png");
        errdefer texture.deinit();
        ctx.camera.world_w = world_w;
        ctx.camera.world_h = world_h;
        ctx.camera.follow(world_w / 2, world_h / 2);
        return .{ .particles = particles, .texture = texture };
    }

    pub fn update(self: *Tb22, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.input.wasPressed(.equal) or ctx.input.wasPressed(.keypad_plus)) ctx.zoomBy(1.25);
        if (ctx.input.wasPressed(.minus) or ctx.input.wasPressed(.keypad_minus)) ctx.zoomBy(0.8);
        if (ctx.input.wasPressed(.zero)) ctx.resetZoom();
        if (ctx.input.wasPressed(.space)) {
            self.emitter_active = !self.emitter_active;
            if (!self.emitter_active) {
                self.emitter_stopped = true;
                self.count_at_emitter_stop = self.particles.count;
            } else {
                self.emitter_stopped = false;
            }
        }
        if (ctx.input.wasPressed(.f)) self.moving_camera = !self.moving_camera;

        self.ticks += 1;
        const dt = ctx.dt;
        self.producer_position = .{
            world_w / 2 + @sin(@as(f32, @floatFromInt(self.ticks)) * 0.025) * 260,
            world_h / 2 + @sin(@as(f32, @floatFromInt(self.ticks)) * 0.037) * 140,
        };
        if (self.emitter_active and self.ticks % burst_interval == 0) self.emitBurst();
        if (self.emitter_active and self.ticks >= emitter_lifetime_ticks) {
            self.emitter_active = false;
            self.emitter_stopped = true;
            self.count_at_emitter_stop = self.particles.count;
        }

        self.particles.config.emission_rate = if (self.emitter_active) continuous_emission_rate else 0;
        const pre_update_count = self.particles.count;
        var expired_now: usize = 0;
        for (self.particles.particles[0..pre_update_count]) |particle| {
            if (particle.age + dt >= particle.lifetime) expired_now += 1;
        }
        const continuous_requested_float = @floor(self.particles.emission_remainder +
            @as(f64, self.particles.config.emission_rate) * @as(f64, dt));
        const continuous_requested: usize = @intFromFloat(continuous_requested_float);
        const after_expiry = pre_update_count - expired_now;
        const continuous_accepted = @min(continuous_requested, self.particles.particles.len - after_expiry);
        self.particles.update(dt);
        self.expired += expired_now;
        self.spawned += continuous_accepted;
        self.dropped += continuous_requested - continuous_accepted;
        self.peak_active = @max(self.peak_active, self.particles.count);
        self.verifyParticleFields();

        if (self.moving_camera) {
            ctx.camera.world_w = world_w;
            ctx.camera.world_h = world_h;
            ctx.camera.followSmooth(self.producer_position[0], self.producer_position[1], dt, 2.2);
        }

        if (!self.report_written and ctx.diagnostics.snapshot.frames >= options.frames and
            self.emitter_stopped and self.ticks >= emitter_lifetime_ticks + 24)
        {
            self.report(ctx);
        }
    }

    fn emitBurst(self: *Tb22) void {
        self.particles.setPosition(self.producer_position);
        const requested = options.burst_size;
        const emitted = self.particles.emit(requested);
        self.burst_requests += requested;
        self.spawned += emitted;
        self.dropped += requested - emitted;
    }

    fn verifyParticleFields(self: *Tb22) void {
        for (self.particles.particles[0..self.particles.count]) |particle| {
            self.reuse_checks += 1;
            if (!std.math.isFinite(particle.position[0]) or !std.math.isFinite(particle.position[1]) or
                !std.math.isFinite(particle.velocity[0]) or !std.math.isFinite(particle.velocity[1]) or
                !std.math.isFinite(particle.age) or !std.math.isFinite(particle.lifetime) or
                particle.age < 0 or particle.lifetime <= 0 or particle.age >= particle.lifetime or
                !std.math.isFinite(particle.start_size) or !std.math.isFinite(particle.end_size) or
                !std.math.isFinite(particle.rotation) or !std.math.isFinite(particle.angular_velocity) or
                !finiteColor(particle.start_color) or !finiteColor(particle.end_color))
            {
                self.reuse_failures += 1;
                log.err("particle slot contains invalid/reset-stale fields", .{});
                return;
            }
        }
    }

    pub fn draw(self: *Tb22, dc: *const engine.DrawContext) void {
        const cam = dc.cam;
        drawBackground(&self.texture, dc, cam.*);
        const before = dc.batch.sprite_count;
        self.particles.draw(
            dc.batch,
            &self.texture,
            .{ .x = 0, .y = 0, .w = 4, .h = 4 },
            1,
            cam,
        );
        const drawn = dc.batch.sprite_count - before;
        self.total_drawn += drawn;
        self.draw_samples += 1;
        var area: f64 = 0;
        for (self.particles.particles[0..self.particles.count]) |particle| {
            const size = particle.currentSize();
            const dst = engine.Rect{
                .x = particle.position[0] - size / 2,
                .y = particle.position[1] - size / 2,
                .w = size,
                .h = size,
            };
            const origin = [2]f32{ size / 2, size / 2 };
            if (engine.camera.overlapsView(cam.viewRect(), engine.camera.spriteBounds(dst, origin, particle.rotation), 1)) {
                area += @as(f64, size) * size;
            }
        }
        self.total_drawn_area += area;

        const emitter_size: f32 = 6;
        dc.batch.drawSprite(
            &self.texture,
            .{ .x = 0, .y = 0, .w = 4, .h = 4 },
            .{
                .x = cam.screenX(self.producer_position[0] - emitter_size / 2),
                .y = cam.screenY(self.producer_position[1] - emitter_size / 2),
                .w = emitter_size,
                .h = emitter_size,
            },
            .{ .tint = if (self.emitter_active) .{ 0.2, 1, 0.45 } else .{ 0.45, 0.45, 0.5 }, .z = 2 },
        );
    }

    fn report(self: *Tb22, ctx: *engine.Context) void {
        self.report_written = true;
        if (self.emitter_stopped) {
            self.survivors_after_emitter_stop = self.particles.count;
        }
        const frames = ctx.diagnostics.stats.of(.frame);
        const avg_drawn = if (self.draw_samples == 0) 0 else @as(f64, @floatFromInt(self.total_drawn)) / @as(f64, @floatFromInt(self.draw_samples));
        const avg_area = if (self.draw_samples == 0) 0 else self.total_drawn_area / @as(f64, @floatFromInt(self.draw_samples));
        const view_area = @as(f64, ctx.camera.view_w) * ctx.camera.view_h;
        const overdraw_estimate = if (view_area == 0) 0 else avg_area / view_area;
        log.info("TB-22 capacity {d}, active {d}, peak {d}, emitted {d}, dropped {d}, expired {d}, emitter stopped {any}, survivors {d}", .{
            options.capacity,
            self.particles.count,
            self.peak_active,
            self.spawned,
            self.dropped,
            self.expired,
            self.emitter_stopped,
            self.survivors_after_emitter_stop,
        });
        log.info("TB-22 draw avg {d:.1} particles, estimated sprite-area overdraw {d:.3}x, slot validation checks {d} failures {d}, frame avg/p95 {d:.2}/{d:.2} ms", .{
            avg_drawn,
            overdraw_estimate,
            self.reuse_checks,
            self.reuse_failures,
            frames.average() * 1000,
            frames.percentile(0.95) * 1000,
        });
        var json: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(
            &json,
            "{{\"testbed\":\"TB-22\",\"scenario\":\"particle-pool-overdraw\",\"result\":\"{s}\",\"capacity\":{d},\"active\":{d},\"peak_active\":{d},\"burst_requests\":{d},\"spawned\":{d},\"dropped\":{d},\"expired\":{d},\"emitter_stopped\":{s},\"particles_at_stop\":{d},\"survivors_after_stop\":{d},\"draw_samples\":{d},\"drawn_avg\":{d:.2},\"estimated_overdraw\":{d:.4},\"reuse_field_checks\":{d},\"reuse_field_failures\":{d},\"allocation_bytes\":{d},\"frame_ms_avg\":{d:.3},\"frame_ms_p95\":{d:.3}}}\n",
            .{
                if (self.reuse_failures == 0 and self.dropped > 0 and
                    self.survivors_after_emitter_stop > 0 and self.total_drawn > 0)
                    "pass"
                else
                    "fail",
                options.capacity,
                self.particles.count,
                self.peak_active,
                self.burst_requests,
                self.spawned,
                self.dropped,
                self.expired,
                if (self.emitter_stopped) "true" else "false",
                self.count_at_emitter_stop,
                self.survivors_after_emitter_stop,
                self.draw_samples,
                avg_drawn,
                overdraw_estimate,
                self.reuse_checks,
                self.reuse_failures,
                options.capacity * @sizeOf(Particle),
                frames.average() * 1000,
                frames.percentile(0.95) * 1000,
            },
        ) catch |err| {
            log.err("TB-22 metrics formatting failed: {s}", .{@errorName(err)});
            return;
        };
        ctx.writeFile("TB-22-particle-results.json", text) catch |err| {
            log.err("TB-22 metrics could not be written: {s}", .{@errorName(err)});
        };
    }

    pub fn debugText(self: *const Tb22, out: *engine.diagnostics.Text) void {
        out.print("TB-22 capacity {d} active {d} peak {d}; Space stops/starts bursts, F camera, +/- zoom", .{
            options.capacity,
            self.particles.count,
            self.peak_active,
        });
        out.print("emitted {d} dropped {d} expired {d} validation failures {d}; Escape quits", .{
            self.spawned,
            self.dropped,
            self.expired,
            self.reuse_failures,
        });
    }

    pub fn deinitWithContext(self: *Tb22, _: *engine.Context) void {
        self.particles.deinit();
        self.texture.deinit();
    }

    pub fn deinit(self: *Tb22) void {
        _ = self;
    }
};

fn finiteColor(color: [4]f32) bool {
    for (color) |component| if (!std.math.isFinite(component)) return false;
    return true;
}

fn drawBackground(texture: *const engine.Texture, dc: *const engine.DrawContext, cam: engine.Camera) void {
    const spacing: f32 = 32;
    var x = @floor(cam.x / spacing) * spacing;
    while (x < cam.x + dc.view_w + spacing) : (x += spacing) {
        dc.batch.drawSprite(
            texture,
            .{ .x = 0, .y = 0, .w = 4, .h = 4 },
            .{ .x = cam.screenX(x), .y = 0, .w = 1, .h = dc.view_h },
            .{ .tint = .{ 0.14, 0.17, 0.23 }, .alpha = 0.45 },
        );
    }
    var y = @floor(cam.y / spacing) * spacing;
    while (y < cam.y + dc.view_h + spacing) : (y += spacing) {
        dc.batch.drawSprite(
            texture,
            .{ .x = 0, .y = 0, .w = 4, .h = 4 },
            .{ .x = 0, .y = cam.screenY(y), .w = dc.view_w, .h = 1 },
            .{ .tint = .{ 0.14, 0.17, 0.23 }, .alpha = 0.45 },
        );
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch return error.InvalidArgument;
    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--capacity") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.capacity = try std.fmt.parseUnsigned(usize, args[arg_index], 10);
        } else if (std.mem.eql(u8, arg, "--burst") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.burst_size = try std.fmt.parseUnsigned(usize, args[arg_index], 10);
        } else if (std.mem.eql(u8, arg, "--frames") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.frames = try std.fmt.parseUnsigned(u64, args[arg_index], 10);
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("TB-22 options: --capacity 256|1024|4096 --burst N (default capacity/4, minimum 192) --frames 180. Controls: Space stops/starts the emitter, F toggles camera follow, +/- zoom.\n", .{});
            return;
        } else {
            return error.InvalidArgument;
        }
    }
    if (!(options.capacity == 256 or options.capacity == 1024 or options.capacity == 4096) or
        options.burst_size > options.capacity * 2)
    {
        return error.InvalidArgument;
    }
    if (options.burst_size == 0) options.burst_size = @max(192, options.capacity / 4);
    try engine.run(engine.SceneHost(Tb22), config);
}
