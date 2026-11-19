//! Sample game for the scene system, the entity world, and semantic input. It uses only the public
//! Bairava API and imports nothing from Semkootru. Space switches between the red and blue squares, and
//! Tab opens the swarm from either square. Tab in the swarm returns to the red square. Escape quits.
//!
//! The controls are actions, not keys. Each one answers to a keyboard key and to a gamepad button, so the
//! same action works from either: the gamepad's south button is the same as Space, and its Start button
//! is the same as Escape. A left click also opens and closes the swarm.
//!
//! Each square scene loads its texture in `init` and releases it in `deinit`. Textures loaded through
//! the asset loader keep a little host bookkeeping until the run ends, so each switch adds a small amount
//! of memory. Textures acquired by name with `ctx.acquireTexture` can be unloaded early; this sample doesn't use them.

const engine = @import("bairava");

/// A 4x4 white PNG beside the executable. Drawing it with a tint gives a solid square.
const white_path = "assets/sample/white.png";
const swarm_world_w: f32 = 2048;
const swarm_world_h: f32 = 1024;
const far_scroll = engine.camera.Scroll{ .factor_x = 0.25, .factor_y = 0.25 };
const near_scroll = engine.camera.Scroll{ .factor_x = 0.5, .factor_y = 0.5 };

/// What the player can ask for. The bindings below say which keys and buttons ask for it.
const Action = enum { switch_square, toggle_swarm, quit };

/// The sample's bindings. Each action lists its keyboard key first, then its gamepad button, and the
/// swarm also has a mouse button.
const bindings = engine.ActionMap(Action).fromDefaults(engine.ActionDefaults(Action).init(.{
    .switch_square = &.{ .{ .key = .space }, .{ .gamepad_button = .south } },
    .toggle_swarm = &.{ .{ .key = .tab }, .{ .gamepad_button = .north }, .{ .mouse = .left } },
    .quit = &.{ .{ .key = .escape }, .{ .gamepad_button = .start } },
}));

const config = engine.Config{
    .title = "Bairava sample",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.1, 0.1, 0.12 },
    .settings_file = "sample_settings.txt",
};

/// Draws a square of the given tint at the center of the native view.
fn drawSquare(texture: *const engine.Texture, dc: *const engine.DrawContext, tint: [3]f32) void {
    const side: f32 = 64;
    dc.batch.drawSprite(
        texture,
        .{ .x = 0, .y = 0, .w = 4, .h = 4 },
        .{
            .x = dc.cam.screenX(swarm_world_w / 2 - side / 2),
            .y = dc.cam.screenY(swarm_world_h / 2 - side / 2),
            .w = side,
            .h = side,
        },
        .{ .tint = tint },
    );
}

fn centerSampleCamera(ctx: *engine.Context) void {
    ctx.camera.world_w = swarm_world_w;
    ctx.camera.world_h = swarm_world_h;
    ctx.camera.follow(swarm_world_w / 2, swarm_world_h / 2);
}

/// A red square. Space switches to the blue scene, and Tab opens the swarm.
const Red = struct {
    texture: engine.Texture,

    pub fn init(ctx: *engine.Context) !Red {
        centerSampleCamera(ctx);
        return .{ .texture = try ctx.loadTexture(white_path) };
    }

    pub fn update(self: *Red, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        _ = self;
        if (bindings.pressed(ctx.input, .switch_square)) nav.switchTo(Blue);
        if (bindings.pressed(ctx.input, .toggle_swarm)) nav.switchTo(Swarm);
        if (bindings.pressed(ctx.input, .quit)) ctx.running = false;
    }

    pub fn draw(self: *Red, dc: *const engine.DrawContext) void {
        drawSquare(&self.texture, dc, .{ 1.0, 0.35, 0.35 });
    }

    pub fn deinit(self: *Red) void {
        self.texture.deinit();
    }
};

/// A blue square. Space switches back to the red scene, and Tab opens the swarm.
const Blue = struct {
    texture: engine.Texture,

    pub fn init(ctx: *engine.Context) !Blue {
        centerSampleCamera(ctx);
        return .{ .texture = try ctx.loadTexture(white_path) };
    }

    pub fn update(self: *Blue, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        _ = self;
        if (bindings.pressed(ctx.input, .switch_square)) nav.switchTo(Red);
        if (bindings.pressed(ctx.input, .toggle_swarm)) nav.switchTo(Swarm);
        if (bindings.pressed(ctx.input, .quit)) ctx.running = false;
    }

    pub fn draw(self: *Blue, dc: *const engine.DrawContext) void {
        drawSquare(&self.texture, dc, .{ 0.35, 0.55, 1.0 });
    }

    pub fn deinit(self: *Blue) void {
        self.texture.deinit();
    }
};

/// The sample's components. They belong to the sample, not the engine.
const Mote = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    age: f32,
};

const Motes = engine.entity.World(Mote, .soa);

const max_motes: usize = 300;
const mote_life: f32 = 4.0;
const mote_speed: f32 = 60.0;
const mote_side: f32 = 3.0;
const spawn_rate: f32 = 60.0;

/// Deterministic pseudo-random numbers in [0, 1), so every run looks the same.
fn nextUnit(seed: *u32) f32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return @as(f32, @floatFromInt(seed.* >> 8)) / 16777216.0;
}

/// The one system. It moves every mote, bounces it off the view edges, and despawns it when its life
/// runs out. Rows are walked from the last to the first, so each despawn moves only a row the walk has
/// already visited.
fn stepMotes(world: *Motes, dt: f32, left: f32, top: f32, view_w: f32, view_h: f32) void {
    var row = world.count();
    while (row > 0) {
        row -= 1;
        const handle = world.handleAt(row);
        var m = world.get(handle).?;
        m.age += dt;
        if (m.age >= mote_life) {
            _ = world.despawn(handle);
            continue;
        }
        m.x += m.vx * dt;
        m.y += m.vy * dt;
        if (m.x < left) {
            m.x = left;
            m.vx = -m.vx;
        }
        if (m.x > left + view_w - mote_side) {
            m.x = left + view_w - mote_side;
            m.vx = -m.vx;
        }
        if (m.y < top) {
            m.y = top;
            m.vy = -m.vy;
        }
        if (m.y > top + view_h - mote_side) {
            m.y = top + view_h - mote_side;
            m.vy = -m.vy;
        }
        _ = world.set(handle, m);
    }
}

/// The swarm: motes that spawn at the center, fly outward, and expire. It shows the entity world in use.
const Swarm = struct {
    texture: engine.Texture,
    motes: Motes,
    seed: u32,
    spawn_accum: f32,
    elapsed: f32,

    pub fn init(ctx: *engine.Context) !Swarm {
        centerSampleCamera(ctx);
        return .{
            .texture = try ctx.loadTexture(white_path),
            .motes = Motes.init(ctx.allocators.game),
            .seed = 12345,
            .spawn_accum = 0,
            .elapsed = 0,
        };
    }

    pub fn update(self: *Swarm, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        if (bindings.pressed(ctx.input, .toggle_swarm)) nav.switchTo(Red);
        if (bindings.pressed(ctx.input, .quit)) ctx.running = false;

        self.elapsed += ctx.dt;
        const target_x = swarm_world_w / 2 + @sin(self.elapsed * 0.23) * 420;
        const target_y = swarm_world_h / 2 + @sin(self.elapsed * 0.17) * 180;
        ctx.camera.followSmooth(target_x, target_y, ctx.dt, 2.5);

        // Spawning happens here, outside the system's loop, so it cannot disturb the walk.
        self.spawn_accum += spawn_rate * ctx.dt;
        while (self.spawn_accum >= 1.0) : (self.spawn_accum -= 1.0) {
            if (self.motes.count() >= max_motes) break;
            const vx = (nextUnit(&self.seed) * 2 - 1) * mote_speed;
            const vy = (nextUnit(&self.seed) * 2 - 1) * mote_speed;
            const center_x = ctx.camera.x + ctx.layout.view_w / 2;
            const center_y = ctx.camera.y + ctx.layout.view_h / 2;
            _ = self.motes.spawn(.{ .x = center_x, .y = center_y, .vx = vx, .vy = vy, .age = 0 }) catch break;
        }

        stepMotes(&self.motes, ctx.dt, ctx.camera.x, ctx.camera.y, ctx.layout.view_w, ctx.layout.view_h);
    }

    pub fn draw(self: *Swarm, dc: *const engine.DrawContext) void {
        drawSwarmBackdrop(&self.texture, dc);
        var row: usize = 0;
        while (row < self.motes.count()) : (row += 1) {
            const m = self.motes.get(self.motes.handleAt(row)).?;
            dc.batch.drawSprite(
                &self.texture,
                .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                .{
                    .x = dc.cam.screenX(m.x),
                    .y = dc.cam.screenY(m.y),
                    .w = mote_side,
                    .h = mote_side,
                },
                .{ .tint = .{ 1.0, 0.9, 0.4 } },
            );
        }
    }

    pub fn deinit(self: *Swarm) void {
        self.motes.deinit();
        self.texture.deinit();
    }
};

fn drawSwarmBackdrop(texture: *const engine.Texture, dc: *const engine.DrawContext) void {
    const src = engine.Rect{ .x = 0, .y = 0, .w = 4, .h = 4 };
    engine.parallax.drawPlane(dc.batch, texture, dc.cam, .{
        .scroll = .{ .factor_x = 0, .factor_y = 0 },
        .src = src,
        .period_w = dc.view_w,
        .period_h = dc.view_h,
        .repeat_x = false,
        .repeat_y = false,
        .tint = .{ 0.025, 0.04, 0.09 },
        .z = -30,
    });
    engine.parallax.drawPlane(dc.batch, texture, dc.cam, .{
        .scroll = far_scroll,
        .src = src,
        .period_w = 80,
        .period_h = swarm_world_h,
        .repeat_y = false,
        .tint = .{ 0.1, 0.24, 0.35 },
        .alpha = 0.2,
        .z = -30,
    });
    engine.parallax.drawPlane(dc.batch, texture, dc.cam, .{
        .scroll = near_scroll,
        .src = src,
        .period_w = 128,
        .period_h = swarm_world_h,
        .repeat_y = false,
        .tint = .{ 0.19, 0.32, 0.38 },
        .alpha = 0.16,
        .z = -30,
    });
    drawParallaxMarks(texture, dc, far_scroll, 80, 110, .{ 0.35, 0.62, 0.78 }, 2);
    drawParallaxMarks(texture, dc, near_scroll, 128, 220, .{ 0.5, 0.76, 0.7 }, 3);
}

fn drawParallaxMarks(
    texture: *const engine.Texture,
    dc: *const engine.DrawContext,
    scroll: engine.camera.Scroll,
    spacing: f32,
    base_y: f32,
    tint: [3]f32,
    side: f32,
) void {
    const layer_cam = dc.cam.scrolled(scroll);
    const first = @floor(layer_cam.x / spacing) - 1;
    const count: usize = @intFromFloat(@ceil(dc.view_w / spacing) + 2);
    const rows = [_]f32{ 0, 18, 42, 64 };
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const world_x = (first + @as(f32, @floatFromInt(index))) * spacing + spacing * 0.35;
        const world_y = base_y + rows[index % rows.len];
        dc.batch.drawSprite(texture, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, .{
            .x = layer_cam.screenX(world_x),
            .y = layer_cam.screenY(world_y),
            .w = side,
            .h = side,
        }, .{ .tint = tint, .alpha = 0.9, .z = -29 });
    }
}

pub fn main() !void {
    try engine.run(engine.SceneHost(Red), config);
}
