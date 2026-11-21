//! TB-09 exercises platform movement, one-way collision, jumping, animation, checkpoints, and hazards.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb09");
const Collider = engine.physics.collision.Collider;
const Box = engine.physics.shapes.Box;
const Point = engine.physics.shapes.Point;
const layer: u32 = 1;
const fixed_dt: f32 = 1.0 / 120.0;
const player_w: f32 = 10;
const player_h: f32 = 20;
const move_speed: f32 = 142;
const jump_speed: f32 = 292;
const gravity: f32 = 760;
const moving_platform_index: usize = 3;
const hazard_index: usize = 5;
const checkpoint_index: usize = 6;

const config = engine.Config{
    .title = "Bairava TB-09 Platformer",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.035, 0.055, 0.075 },
    .settings_file = "tb09_settings.txt",
};

const machine_source =
    \\machine 1
    \\param moving
    \\param facing
    \\state idle
    \\clip idle_down when facing == 0
    \\clip idle_right when facing == 1
    \\clip idle_up when facing == 2
    \\clip idle_left when facing == 3
    \\state walk
    \\clip walk_down when facing == 0
    \\clip walk_right when facing == 1
    \\clip walk_up when facing == 2
    \\clip walk_left when facing == 3
    \\start idle
    \\transition idle -> walk when moving == 1 blend 0.08
    \\transition walk -> idle when moving == 0 blend 0.08
;

const Controls = struct {
    direction: f32 = 0,
    jump: bool = false,
    drop: bool = false,
};

const Kinematics = struct {
    x: f32 = 30,
    y: f32 = 220,
    vx: f32 = 0,
    vy: f32 = 0,
    time: f32 = 0,
    drop_timer: f32 = 0,
    grounded: bool = false,
    grounded_on_moving: bool = false,
    landings: u32 = 0,
};

const SimResult = struct {
    state: Kinematics,
    platform_rides: u32,
    jumps: u32,
};

const Tb09 = struct {
    colliders: [7]Collider,
    physics: Kinematics = .{},
    accumulator: f32 = 0,
    checkpoint_x: f32 = 34,
    checkpoint_y: f32 = 220,
    library: engine.animation.Library,
    machine: engine.animation.Machine,
    moving_param: u8,
    facing_param: u8,
    texture: engine.Texture,
    particle_texture: engine.Texture,
    particles: engine.particles.System,
    sound: ?engine.audio.Sound,
    facing: i32 = 1,
    animation_changes: u64 = 0,
    jump_count: u64 = 0,
    landing_count: u64 = 0,
    hazard_hits: u64 = 0,
    checkpoints: u64 = 0,
    platform_rides: u64 = 0,
    high_speed_checks: u64 = 0,
    high_speed_failures: u64 = 0,
    moving_platform_carry_checks: u64 = 0,
    moving_platform_carry_failures: u64 = 0,
    animation_validation_checks: u64 = 0,
    animation_validation_failures: u64 = 0,
    render_rate_checks: u64 = 0,
    render_rate_failures: u64 = 0,
    max_rate_position_error: f32 = 0,
    report_written: bool = false,
    jump_buffer: f32 = 0,

    pub fn init(ctx: *engine.Context) !Tb09 {
        const library_source = try ctx.readFile(ctx.allocators.asset, "assets/animations/warrior.anim");
        defer ctx.allocators.asset.free(library_source);
        var library = try engine.animation.Library.parse(ctx.allocators.game, library_source, 80, 128);
        errdefer library.deinit();

        var definition = try engine.animation.MachineDefinition.parse(ctx.allocators.game, machine_source, &library);
        errdefer definition.deinit();
        var machine = engine.animation.Machine.init(definition, &library);
        errdefer machine.deinit();
        const moving_param = machine.paramId("moving") orelse return error.InvalidAnimation;
        const facing_param = machine.paramId("facing") orelse return error.InvalidAnimation;

        var texture = try ctx.loadTexture("assets/warrior_16x32.png");
        errdefer texture.deinit();
        var particle_texture = try ctx.loadTexture("assets/sample/white.png");
        errdefer particle_texture.deinit();

        var particles = try engine.particles.System.init(ctx.allocators.game, 96, 0x09C0FFEE);
        errdefer particles.deinit();
        try particles.setConfig(.{
            .lifetime = .{ 0.18, 0.42 },
            .speed = .{ 16, 54 },
            .angle = .{ -std.math.pi, 0 },
            .size = .{ 2, 4 },
            .end_size = 1,
            .color = .{ 0.94, 0.72, 0.33, 0.9 },
            .end_color = .{ 0.55, 0.38, 0.2, 0 },
            .gravity = .{ 0, 100 },
        });

        const sound: ?engine.audio.Sound = if (ctx.audio.device != null)
            try ctx.loadSound("assets/wind1.wav")
        else
            null;
        errdefer if (sound) |loaded| {
            var owned = loaded;
            owned.deinit();
        };

        var self = Tb09{
            .colliders = makeColliders(platformX(0)),
            .library = library,
            .machine = machine,
            .moving_param = moving_param,
            .facing_param = facing_param,
            .texture = texture,
            .particle_texture = particle_texture,
            .particles = particles,
            .sound = sound,
        };
        ctx.camera.world_w = 640;
        ctx.camera.world_h = 320;
        ctx.camera.follow(self.physics.x + player_w / 2, self.physics.y + player_h / 2);
        self.runValidation();
        return self;
    }

    pub fn update(self: *Tb09, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.input.wasPressed(.space) or ctx.input.wasPressed(.w) or ctx.input.wasPressed(.up)) {
            self.jump_buffer = 0.12;
        }

        var direction: f32 = 0;
        if (ctx.input.held(.left) or ctx.input.held(.a)) direction -= 1;
        if (ctx.input.held(.right) or ctx.input.held(.d)) direction += 1;
        if (direction < 0) self.facing = 3 else if (direction > 0) self.facing = 1;
        const controls = Controls{
            .direction = direction,
            .jump = self.jump_buffer > 0,
            .drop = (ctx.input.held(.down) or ctx.input.held(.s)) and ctx.input.wasPressed(.space),
        };
        self.jump_buffer = @max(0, self.jump_buffer - ctx.dt);

        self.accumulator += @min(ctx.dt, 0.1);
        var steps: u8 = 0;
        while (self.accumulator >= fixed_dt and steps < 16) : (steps += 1) {
            const previous_grounded = self.physics.grounded;
            step(&self.physics, &self.colliders, fixed_dt, controls);
            self.accumulator -= fixed_dt;
            if (controls.jump and previous_grounded and !controls.drop) {
                self.jump_count += 1;
                self.playSound(ctx);
            }
            if (self.physics.landings > 0 and self.physics.landings > self.landing_count) {
                self.landing_count = self.physics.landings;
                self.emitLanding();
                self.playSound(ctx);
            }
            if (self.physics.grounded_on_moving) self.platform_rides += 1;
            self.updateTriggers(ctx);
            self.particles.update(fixed_dt);
            self.updateAnimation(fixed_dt);
        }
        ctx.camera.world_w = 640;
        ctx.camera.world_h = 320;
        ctx.camera.followSmooth(self.physics.x + player_w / 2, self.physics.y + player_h / 2, ctx.dt, 5);
        if (!self.report_written and ctx.diagnostics.snapshot.frames >= options.frames) self.report(ctx);
        if (run_frame_limit) |limit| {
            if (ctx.diagnostics.snapshot.frames >= limit) ctx.running = false;
        }
    }

    pub fn draw(self: *Tb09, dc: *const engine.DrawContext) void {
        drawRect(dc, &self.particle_texture, .{ .x = 0, .y = 0, .w = 640, .h = 320 }, .{ 0.06, 0.09, 0.12 }, -10);
        for (self.colliders, 0..) |collider, index| {
            if (index == hazard_index) {
                drawRect(dc, &self.particle_texture, collider.box, .{ 0.85, 0.22, 0.17 }, 0);
            } else if (index == checkpoint_index) {
                drawRect(dc, &self.particle_texture, collider.box, .{ 0.95, 0.78, 0.26 }, 0);
            } else {
                const tint: [3]f32 = if (index == moving_platform_index)
                    .{ 0.31, 0.68, 0.83 }
                else if (collider.one_way)
                    .{ 0.45, 0.56, 0.38 }
                else
                    .{ 0.34, 0.4, 0.47 };
                drawRect(dc, &self.particle_texture, collider.box, tint, 0);
            }
        }
        self.particles.draw(
            dc.batch,
            &self.particle_texture,
            .{ .x = 0, .y = 0, .w = 4, .h = 4 },
            1,
            dc.cam,
        );
        const pose = self.machine.pose();
        if (pose.previous) |previous| drawFrame(dc, &self.texture, previous, self.physics.x - 3, self.physics.y - 11, 1);
        drawFrame(dc, &self.texture, pose.frame, self.physics.x - 3, self.physics.y - 11, pose.weight);
    }

    pub fn debugText(self: *const Tb09, out: *engine.diagnostics.Text) void {
        out.print("TB-09 Platformer | A/D or arrows move, Space/W jump, Down+Space drop, Escape quits", .{});
        out.print("jumps {d} landings {d} rides {d} hazards {d} checkpoints {d}", .{
            self.jump_count,
            self.landing_count,
            self.platform_rides,
            self.hazard_hits,
            self.checkpoints,
        });
    }

    pub fn deinitWithContext(self: *Tb09, _: *engine.Context) void {
        if (self.sound) |*sound| sound.deinit();
        self.particles.deinit();
        self.particle_texture.deinit();
        self.texture.deinit();
        self.machine.deinit();
        self.library.deinit();
    }

    pub fn deinit(self: *Tb09) void {
        _ = self;
    }

    fn updateAnimation(self: *Tb09, dt: f32) void {
        const moving = @abs(self.physics.vx) > 0.1;
        self.machine.set(self.moving_param, @intFromBool(moving));
        self.machine.set(self.facing_param, self.facing);
        const old_state = self.machine.stateName();
        const old_clip = self.machine.clipName();
        self.machine.update(dt, &self.library);
        if (old_state.len > 0 and
            (!std.mem.eql(u8, old_state, self.machine.stateName()) or
                !std.mem.eql(u8, old_clip, self.machine.clipName())))
        {
            self.animation_changes += 1;
        }
    }

    fn updateTriggers(self: *Tb09, ctx: *engine.Context) void {
        const box = playerBox(self.physics);
        if (engine.physics.collision.colliderOverlaps(self.colliders[hazard_index], .{
            .box = box,
            .layer = layer,
        })) {
            self.hazard_hits += 1;
            self.physics.x = self.checkpoint_x;
            self.physics.y = self.checkpoint_y;
            self.physics.vx = 0;
            self.physics.vy = 0;
            self.physics.grounded = false;
            self.physics.grounded_on_moving = false;
            self.emitLanding();
            self.playSound(ctx);
            return;
        }
        if (engine.physics.collision.colliderOverlaps(self.colliders[checkpoint_index], .{
            .box = box,
            .layer = layer,
        }) and (self.checkpoint_x != 438 or self.checkpoint_y != 130)) {
            self.checkpoint_x = 438;
            self.checkpoint_y = 130;
            self.checkpoints += 1;
            self.playSound(ctx);
        }
    }

    fn emitLanding(self: *Tb09) void {
        self.particles.setPosition(.{ self.physics.x + player_w / 2, self.physics.y + player_h });
        _ = self.particles.emit(8);
    }

    fn playSound(self: *Tb09, ctx: *engine.Context) void {
        if (self.sound) |*sound| {
            _ = ctx.audio.play(sound, .{ .bus = .sfx }) catch |err| {
                log.warn("platformer sound could not play: {s}", .{@errorName(err)});
            };
        }
    }

    fn runValidation(self: *Tb09) void {
        self.verifyRenderRateIndependence();
        self.verifyHighSpeedCollision();
        self.verifyMovingPlatformCarry();
        self.verifyAnimationTransition();
    }

    fn verifyRenderRateIndependence(self: *Tb09) void {
        const rates = [_]f32{ 1.0 / 30.0, 1.0 / 60.0, 1.0 / 120.0 };
        var baseline: ?Kinematics = null;
        for (rates) |rate| {
            const result = simulateAtRate(rate);
            self.render_rate_checks += 1;
            if (result.state.landings == 0 or result.jumps == 0) self.render_rate_failures += 1;
            if (baseline) |expected| {
                const error_distance = @max(@abs(expected.x - result.state.x), @abs(expected.y - result.state.y));
                self.max_rate_position_error = @max(self.max_rate_position_error, error_distance);
                if (error_distance > 0.02 or expected.landings != result.state.landings) {
                    self.render_rate_failures += 1;
                }
            } else {
                baseline = result.state;
            }
        }
    }

    fn verifyHighSpeedCollision(self: *Tb09) void {
        var colliders = makeColliders(platformX(0));
        const start = Box{ .x = 485, .y = 230, .w = player_w, .h = player_h };
        const moved = engine.physics.queries.moveBox(&colliders, start, 180, 0, layer);
        self.high_speed_checks += 1;
        if (moved.x + player_w > colliders[4].box.x + 0.01 or moved.x <= start.x) {
            self.high_speed_failures += 1;
        }
        const falling = Box{ .x = 120, .y = 80, .w = player_w, .h = player_h };
        const landed = engine.physics.queries.moveBox(&colliders, falling, 0, 180, layer);
        self.high_speed_checks += 1;
        if (@abs(landed.y - 185) > 0.02) self.high_speed_failures += 1;
    }

    fn verifyMovingPlatformCarry(self: *Tb09) void {
        var colliders = makeColliders(platformX(0));
        const platform = colliders[moving_platform_index].box;
        var state = Kinematics{
            .x = platform.x + 12,
            .y = platform.y - player_h,
            .grounded = true,
            .grounded_on_moving = true,
        };
        const start_x = state.x;
        var tick: u32 = 0;
        while (tick < 120) : (tick += 1) step(&state, &colliders, fixed_dt, .{});
        self.moving_platform_carry_checks += 1;
        if (state.x <= start_x + 2 or !state.grounded) self.moving_platform_carry_failures += 1;
    }

    fn verifyAnimationTransition(self: *Tb09) void {
        self.machine.set(self.moving_param, 1);
        self.machine.set(self.facing_param, self.facing);
        self.machine.update(0.1, &self.library);
        self.animation_validation_checks += 1;
        if (!std.mem.eql(u8, self.machine.stateName(), "walk")) {
            self.animation_validation_failures += 1;
        }
        self.machine.restore(&self.library, 0);
    }

    fn report(self: *Tb09, ctx: *engine.Context) void {
        const pass = self.render_rate_failures == 0 and self.high_speed_failures == 0 and
            self.moving_platform_carry_failures == 0 and self.animation_validation_failures == 0 and
            self.render_rate_checks == 3;
        log.info("TB-09 {s}: render-rate checks {d}/{d}, max position error {d:.5}, high-speed checks {d}/{d}, platform carry checks {d}/{d}, animation checks {d}/{d}, runtime animation changes {d}, jumps {d}, landings {d}", .{
            if (pass) "pass" else "fail",
            self.render_rate_checks,
            self.render_rate_failures,
            self.max_rate_position_error,
            self.high_speed_checks,
            self.high_speed_failures,
            self.moving_platform_carry_checks,
            self.moving_platform_carry_failures,
            self.animation_validation_checks,
            self.animation_validation_failures,
            self.animation_changes,
            self.jump_count,
            self.landing_count,
        });
        var json: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(
            &json,
            "{{\"testbed\":\"TB-09\",\"scenario\":\"platformer\",\"result\":\"{s}\",\"render_rate_checks\":{d},\"render_rate_failures\":{d},\"max_rate_position_error\":{d:.5},\"high_speed_checks\":{d},\"high_speed_failures\":{d},\"moving_platform_carry_checks\":{d},\"moving_platform_carry_failures\":{d},\"animation_validation_checks\":{d},\"animation_validation_failures\":{d},\"runtime_animation_changes\":{d},\"jumps\":{d},\"landings\":{d},\"runtime_platform_ride_ticks\":{d},\"hazard_hits\":{d},\"checkpoints\":{d},\"slope_support\":\"not implemented; one-way surfaces are supported\"}}\n",
            .{
                if (pass) "pass" else "fail",
                self.render_rate_checks,
                self.render_rate_failures,
                self.max_rate_position_error,
                self.high_speed_checks,
                self.high_speed_failures,
                self.moving_platform_carry_checks,
                self.moving_platform_carry_failures,
                self.animation_validation_checks,
                self.animation_validation_failures,
                self.animation_changes,
                self.jump_count,
                self.landing_count,
                self.platform_rides,
                self.hazard_hits,
                self.checkpoints,
            },
        ) catch |err| {
            log.err("TB-09 results could not be formatted: {s}", .{@errorName(err)});
            return;
        };
        ctx.writeFile("TB-09-platformer-results.json", text) catch |err| {
            log.err("TB-09 results could not be written: {s}", .{@errorName(err)});
            return;
        };
        self.report_written = true;
    }
};

fn makeColliders(platform_x: f32) [7]Collider {
    return .{
        .{ .box = .{ .x = 0, .y = 270, .w = 640, .h = 50 }, .layer = layer },
        .{ .box = .{ .x = 100, .y = 205, .w = 88, .h = 8 }, .layer = layer, .one_way = true },
        .{ .box = .{ .x = 392, .y = 170, .w = 100, .h = 8 }, .layer = layer, .one_way = true },
        .{ .box = .{ .x = platform_x, .y = 220, .w = 68, .h = 8 }, .layer = layer, .one_way = true },
        .{ .box = .{ .x = 520, .y = 120, .w = 16, .h = 150 }, .layer = layer },
        .{ .box = .{ .x = 204, .y = 256, .w = 36, .h = 14 }, .layer = layer, .is_trigger = true },
        .{ .box = .{ .x = 438, .y = 150, .w = 16, .h = 20 }, .layer = layer, .is_trigger = true },
    };
}

fn platformX(time: f32) f32 {
    return 264 + 68 * @sin(time * 1.1);
}

fn playerBox(state: Kinematics) Box {
    return .{ .x = state.x, .y = state.y, .w = player_w, .h = player_h };
}

fn supportIndex(box: Box, colliders: []const Collider) ?usize {
    for (colliders, 0..) |collider, index| {
        if (!collider.enabled or collider.is_trigger or collider.box.w <= 0 or collider.box.h <= 0) continue;
        const bottom = box.y + box.h;
        const overlap_x = box.x < collider.box.x + collider.box.w and collider.box.x < box.x + box.w;
        if (overlap_x and @abs(bottom - collider.box.y) <= 0.02) return index;
    }
    return null;
}

fn step(state: *Kinematics, colliders: *[7]Collider, dt: f32, controls: Controls) void {
    const old_platform_x = colliders[moving_platform_index].box.x;
    const new_platform_x = platformX(state.time + dt);
    const platform_dx = new_platform_x - old_platform_x;
    colliders[moving_platform_index].box.x = new_platform_x;

    if (state.grounded and state.grounded_on_moving) {
        const carried = engine.physics.queries.moveBox(colliders, playerBox(state.*), platform_dx, 0, layer);
        state.x = carried.x;
    }

    state.vx = controls.direction * move_speed;
    const old_x = state.x;
    const horizontal = engine.physics.queries.moveBox(colliders, playerBox(state.*), state.vx * dt, 0, layer);
    state.x = horizontal.x;
    if (@abs(horizontal.x - (old_x + state.vx * dt)) > 0.01) state.vx = 0;

    if (controls.drop and state.grounded) {
        state.drop_timer = 0.2;
        state.vy = 18;
        state.grounded = false;
        state.grounded_on_moving = false;
    } else if (controls.jump and state.grounded) {
        state.vy = -jump_speed;
        state.grounded = false;
        state.grounded_on_moving = false;
    }

    if (state.drop_timer > 0) state.drop_timer = @max(0, state.drop_timer - dt);
    if (!state.grounded) state.vy = @min(state.vy + gravity * dt, 520);
    const dy = state.vy * dt;
    const vertical = if (state.drop_timer > 0)
        engine.physics.queries.moveBoxIgnoringOneWay(colliders, playerBox(state.*), 0, dy, layer)
    else
        engine.physics.queries.moveBox(colliders, playerBox(state.*), 0, dy, layer);
    const hit_vertical = @abs(vertical.y - (state.y + dy)) > 0.01;
    state.y = vertical.y;
    if (hit_vertical) {
        if (state.vy > 0) state.landings += 1;
        state.vy = 0;
    }

    const support = supportIndex(playerBox(state.*), colliders);
    if (support) |index| {
        if (!controls.jump and state.vy >= 0 and state.drop_timer <= 0) {
            state.grounded = true;
            state.grounded_on_moving = index == moving_platform_index;
            state.vy = 0;
        } else if (state.vy <= 0) {
            state.grounded = false;
            state.grounded_on_moving = false;
        }
    } else {
        state.grounded = false;
        state.grounded_on_moving = false;
    }
    state.time += dt;
}

fn simulateAtRate(render_dt: f32) SimResult {
    var colliders = makeColliders(platformX(0));
    var state = Kinematics{ .x = 36, .y = 245 };
    var accumulator: f32 = 0;
    var render_time: f32 = 0;
    var jump_sent = false;
    var jumps: u32 = 0;
    while (render_time < 5) : (render_time += render_dt) {
        accumulator += render_dt;
        var substeps: u8 = 0;
        while (accumulator >= fixed_dt and substeps < 32) : (substeps += 1) {
            const jump_now = !jump_sent and state.time >= 0.24;
            if (jump_now) jump_sent = true;
            const direction: f32 = if (state.time < 1.7) 1 else if (state.time < 2.2) -1 else 0;
            if (jump_now and state.grounded) jumps += 1;
            step(&state, &colliders, fixed_dt, .{ .direction = direction, .jump = jump_now });
            accumulator -= fixed_dt;
        }
    }
    return .{ .state = state, .platform_rides = 0, .jumps = jumps };
}

fn drawRect(dc: *const engine.DrawContext, texture: *const engine.Texture, box: Box, tint: [3]f32, z: i32) void {
    dc.batch.drawSprite(
        texture,
        .{ .x = 0, .y = 0, .w = 4, .h = 4 },
        .{ .x = dc.cam.screenX(box.x), .y = dc.cam.screenY(box.y), .w = box.w, .h = box.h },
        .{ .tint = tint, .z = z, .depth_y = box.y + box.h },
    );
}

fn drawFrame(dc: *const engine.DrawContext, texture: *const engine.Texture, frame: *const engine.animation.Frame, x: f32, y: f32, alpha: f32) void {
    dc.batch.drawSprite(
        texture,
        .{
            .x = @floatFromInt(frame.x),
            .y = @floatFromInt(frame.y),
            .w = @floatFromInt(frame.w),
            .h = @floatFromInt(frame.h),
        },
        .{ .x = dc.cam.screenX(x), .y = dc.cam.screenY(y), .w = 16, .h = 32 },
        .{ .alpha = alpha, .depth_y = y + 32 },
    );
}

const Options = struct { frames: u64 = 240 };
var options = Options{};
var run_frame_limit: ?u64 = null;

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch return error.InvalidArgument;
    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        if (std.mem.eql(u8, args[arg_index], "--help")) {
            std.debug.print("TB-09 options: --frames 240. Controls: A/D or arrows move, Space/W jump, Down+Space drop through, Escape quits.\n", .{});
            return;
        } else if (std.mem.eql(u8, args[arg_index], "--frames") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.frames = try std.fmt.parseUnsigned(u64, args[arg_index], 10);
            if (options.frames == 0) return error.InvalidArgument;
            run_frame_limit = options.frames;
        } else {
            return error.InvalidArgument;
        }
    }
    try engine.run(engine.SceneHost(Tb09), config);
}
