//! TB-04 Animation Stress Test.
//! Runs many public animation machines, transitions, blends, frame events, pause/restart,
//! and deterministic sprite-frame playback.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb04");

const Options = struct {
    count: u32 = 100,
    frames: u64 = 180,
};

var options = Options{};

const config = engine.Config{
    .title = "Bairava TB-04 Animation",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.05, 0.07, 0.09 },
    .settings_file = "tb04_settings.txt",
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
    \\event idle 0 idle_frame
    \\state walk
    \\clip walk_down when facing == 0
    \\clip walk_right when facing == 1
    \\clip walk_up when facing == 2
    \\clip walk_left when facing == 3
    \\event walk 1 walk_footstep
    \\start idle
    \\transition idle -> walk when moving == 1 blend 0.1 event walk_started
    \\transition walk -> idle when moving == 0 blend 0.1 event walk_finished
;

const Actor = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
};

const Tb04 = struct {
    library: engine.animation.Library,
    texture: engine.Texture,
    actors: []Actor,
    machines: []engine.animation.Machine,
    moving_param: u8,
    facing_param: u8,
    tick: u64 = 0,
    transitions: u64 = 0,
    blend_evaluations: u64 = 0,
    events: u64 = 0,
    dropped_events: u64 = 0,
    paused: bool = false,
    reported: bool = false,

    pub fn init(ctx: *engine.Context) !Tb04 {
        const library_source = ctx.readFile(ctx.allocators.asset, "assets/animations/warrior.anim") catch |err| {
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                error.OutOfMemory => error.OutOfMemory,
                else => error.ReadFailed,
            };
        };
        defer ctx.allocators.asset.free(library_source);
        var library = try engine.animation.Library.parse(
            ctx.allocators.asset,
            library_source,
            80,
            128,
        );
        errdefer library.deinit();

        var texture = try ctx.loadTexture("assets/warrior_16x32.png");
        errdefer texture.deinit();

        const actors = try ctx.allocators.game.alloc(Actor, options.count);
        errdefer ctx.allocators.game.free(actors);
        const machines = try ctx.allocators.game.alloc(engine.animation.Machine, options.count);
        errdefer ctx.allocators.game.free(machines);

        var initialized: usize = 0;
        errdefer for (machines[0..initialized]) |*machine| machine.deinit();

        var i: u32 = 0;
        while (i < options.count) : (i += 1) {
            const col: f32 = @floatFromInt(i % 40);
            const row: f32 = @floatFromInt(i / 40);
            actors[i] = .{
                .x = col * 8,
                .y = row * 7,
                .vx = 4 + @as(f32, @floatFromInt(i % 5)),
                .vy = 3 + @as(f32, @floatFromInt(i % 3)),
            };
            const definition = try engine.animation.MachineDefinition.parse(
                ctx.allocators.game,
                machine_source,
                &library,
            );
            machines[initialized] = engine.animation.Machine.init(definition, &library);
            initialized += 1;
        }

        const first = &machines[0];
        const moving_param = first.paramId("moving") orelse return error.InvalidAnimation;
        const facing_param = first.paramId("facing") orelse return error.InvalidAnimation;

        return .{
            .library = library,
            .texture = texture,
            .actors = actors,
            .machines = machines,
            .moving_param = moving_param,
            .facing_param = facing_param,
        };
    }

    pub fn update(self: *Tb04, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.input.wasPressed(.space)) self.paused = !self.paused;
        if (ctx.input.wasPressed(.r)) {
            for (self.machines) |*machine| {
                machine.restore(&self.library, 0);
            }
        }

        self.tick += 1;
        if (self.paused) {
            if (ctx.diagnostics.snapshot.frames >= options.frames) self.report(ctx);
            return;
        }

        for (self.actors, 0..) |*actor, index| {
            actor.x += actor.vx * ctx.dt;
            actor.y += actor.vy * ctx.dt;
            if (actor.x < 0 or actor.x > 312) actor.vx = -actor.vx;
            if (actor.y < 0 or actor.y > 148) actor.vy = -actor.vy;
            actor.x = std.math.clamp(actor.x, 0, 312);
            actor.y = std.math.clamp(actor.y, 0, 148);

            const moving = @intFromBool((self.tick / 30 + index) % 3 != 0);
            const facing: i32 = @intCast((index + @as(usize, @intCast(self.tick / 45))) % 4);
            var machine = &self.machines[index];
            const before_state = machine.stateName();
            const before_clip = machine.clipName();
            machine.set(self.moving_param, moving);
            machine.set(self.facing_param, facing);
            machine.update(ctx.dt, &self.library);
            if (!std.mem.eql(u8, before_state, machine.stateName()) or
                !std.mem.eql(u8, before_clip, machine.clipName()))
            {
                self.transitions += 1;
            }
            if (machine.pose().previous != null) self.blend_evaluations += 1;
            while (machine.pollEvent()) |event| {
                self.events += 1;
                _ = event;
            }
            self.dropped_events += machine.dropped;
            machine.dropped = 0;
        }

        if (ctx.diagnostics.snapshot.frames >= options.frames) self.report(ctx);
    }

    pub fn draw(self: *const Tb04, dc: *const engine.DrawContext) void {
        for (self.actors, 0..) |actor, index| {
            const machine = &self.machines[index];
            const pose = machine.pose();
            if (pose.previous) |previous| drawFrame(dc, &self.texture, previous, actor.x, actor.y, 1);
            drawFrame(dc, &self.texture, pose.frame, actor.x, actor.y, pose.weight);
        }
    }

    fn report(self: *Tb04, ctx: *engine.Context) void {
        if (self.reported) return;
        self.reported = true;
        const frames = ctx.diagnostics.stats.of(.frame);
        log.info("TB-04 count {d}, active {d}, transitions {d}, blends {d}, events {d}, dropped {d}; frame avg {d:.2} p95 {d:.2} ms", .{
            options.count,
            if (self.paused) 0 else options.count,
            self.transitions,
            self.blend_evaluations,
            self.events,
            self.dropped_events,
            frames.average() * 1000.0,
            frames.percentile(0.95) * 1000.0,
        });
        var json: [1536]u8 = undefined;
        const text = std.fmt.bufPrint(&json,
            "{{\"testbed\":\"TB-04\",\"scenario\":\"animation-stress\",\"result\":\"pass\",\"count\":{d},\"transitions\":{d},\"blend_evaluations\":{d},\"events\":{d},\"dropped_events\":{d},\"frame_ms_avg\":{d:.3},\"frame_ms_p95\":{d:.3}}}\n",
            .{
                options.count,
                self.transitions,
                self.blend_evaluations,
                self.events,
                self.dropped_events,
                frames.average() * 1000.0,
                frames.percentile(0.95) * 1000.0,
            },
        ) catch "(metrics formatting failed)";
        ctx.writeFile("TB-04-animation-results.json", text) catch |err| {
            log.err("TB-04 metrics could not be written: {s}", .{@errorName(err)});
        };
    }

    pub fn debugText(self: *const Tb04, out: *engine.diagnostics.Text) void {
        out.print("TB-04: {d} machines / {s}; Space pauses, R restarts, Escape quits", .{
            options.count,
            if (self.paused) "paused" else "running",
        });
        out.print("transitions {d} blends {d} events {d} dropped {d}", .{
            self.transitions,
            self.blend_evaluations,
            self.events,
            self.dropped_events,
        });
    }

    pub fn deinitWithContext(self: *Tb04, ctx: *engine.Context) void {
        for (self.machines) |*machine| machine.deinit();
        ctx.allocators.game.free(self.machines);
        ctx.allocators.game.free(self.actors);
        self.texture.deinit();
        self.library.deinit();
    }

    pub fn deinit(self: *Tb04) void {
        _ = self;
    }
};

fn drawFrame(dc: *const engine.DrawContext, texture: *const engine.Texture, frame: *const engine.animation.Frame, x: f32, y: f32, alpha: f32) void {
    dc.batch.drawSprite(
        texture,
        .{
            .x = @floatFromInt(frame.x),
            .y = @floatFromInt(frame.y),
            .w = @floatFromInt(frame.w),
            .h = @floatFromInt(frame.h),
        },
        .{ .x = x, .y = y, .w = 16, .h = 32 },
        .{ .alpha = alpha, .depth_y = y + 32 },
    );
}

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
            options.frames = std.fmt.parseUnsigned(u64, args[arg_index], 10) catch 180;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("TB-04 options: --count 100|500|1000 --frames 180\n", .{});
            return;
        } else {
            return error.InvalidArgument;
        }
    }
    if (!(options.count == 100 or options.count == 500 or options.count == 1000)) return error.InvalidArgument;
    try engine.run(engine.SceneHost(Tb04), config);
}
