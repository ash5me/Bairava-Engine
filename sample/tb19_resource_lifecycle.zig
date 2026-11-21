//! TB-19 resource and entity lifecycle laboratory.
//! It repeats public texture handle cycles and ECS entity generation cycles while keeping the sample interactive.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb19");

const Options = struct {
    count: u32 = 100,
    cycles: u32 = 60,
    frames: u64 = 180,
};

var options = Options{};

const config = engine.Config{
    .title = "Bairava TB-19 Lifecycle",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.06, 0.07, 0.09 },
    .settings_file = "tb19_settings.txt",
};

const Entity = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    serial: u64,
};

const World = engine.entity.World(Entity, .aos);

const Tb19 = struct {
    world: World,
    texture_primary: engine.TextureHandle = engine.TextureHandle.invalid,
    texture_secondary: engine.TextureHandle = engine.TextureHandle.invalid,
    texture: ?*const engine.Texture = null,
    stale_texture_copy: engine.TextureHandle = engine.TextureHandle.invalid,
    stale_entity: engine.entity.Handle = .{ .index = 0, .generation = 0 },
    serial: u64 = 0,
    cycles: u64 = 0,
    stale_resource_checks: u64 = 0,
    stale_entity_checks: u64 = 0,
    double_despawn_checks: u64 = 0,
    slot_reuses: u64 = 0,
    ticks: u64 = 0,
    reported: bool = false,

    pub fn init(ctx: *engine.Context) !Tb19 {
        var self = Tb19{ .world = World.init(ctx.allocators.game) };
        errdefer self.world.deinit();

        try ctx.registerTexture("tb19_white", "assets/sample/white.png");
        self.texture_primary = try ctx.acquireTexture("tb19_white");
        self.texture_secondary = self.texture_primary;
        try ctx.retainTexture(self.texture_secondary);
        self.texture = ctx.textureOf(self.texture_primary) catch null;

        var i: u32 = 0;
        while (i < options.count) : (i += 1) {
            _ = try self.world.spawn(.{
                .x = @as(f32, @floatFromInt(i % 25)) * 12,
                .y = @as(f32, @floatFromInt(i / 25)) * 12,
                .vx = 4 + @as(f32, @floatFromInt(i % 5)),
                .vy = 2 + @as(f32, @floatFromInt(i % 3)),
                .serial = @intCast(i),
            });
            self.serial += 1;
        }
        return self;
    }

    pub fn update(self: *Tb19, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        self.ticks += 1;

        var row: usize = 0;
        while (row < self.world.count()) : (row += 1) {
            var entity = self.world.rows.get(row);
            entity.x += entity.vx * ctx.dt;
            entity.y += entity.vy * ctx.dt;
            if (entity.x > 330) entity.vx = -@abs(entity.vx);
            if (entity.x < 0) entity.vx = @abs(entity.vx);
            if (entity.y > 190) entity.vy = -@abs(entity.vy);
            if (entity.y < 0) entity.vy = @abs(entity.vy);
            self.world.rows.set(row, entity);
        }

        if (self.ticks > 0 and self.ticks % options.cycles == 0)
        {
            self.runLifecycleCycle(ctx);
        }

        if (self.ticks >= options.frames) self.report(ctx);
    }

    fn runLifecycleCycle(self: *Tb19, ctx: *engine.Context) void {
        self.cycles += 1;

        if (self.world.count() > 0) {
            const row = self.world.count() - 1;
            const old_entity = self.world.handleAt(row);
            self.stale_entity = old_entity;
            if (self.world.despawn(old_entity)) {
                self.double_despawn_checks += @intFromBool(!self.world.despawn(old_entity));
                const replacement = self.world.spawn(.{
                    .x = 20,
                    .y = 20,
                    .vx = 5,
                    .vy = 3,
                    .serial = self.serial,
                }) catch |err| {
                    log.err("TB-19 entity replacement failed: {s}", .{@errorName(err)});
                    return;
                };
                self.serial += 1;
                if (!self.world.isAlive(old_entity) and
                    self.world.isAlive(replacement) and
                    replacement.index == old_entity.index)
                {
                    self.slot_reuses += 1;
                }
                self.stale_entity_checks += @intFromBool(!self.world.isAlive(old_entity));
            }
        }

        self.stale_texture_copy = self.texture_primary;
        var primary = self.texture_primary;
        var secondary = self.texture_secondary;
        ctx.releaseTexture(&primary) catch {};
        ctx.releaseTexture(&secondary) catch {};
        self.texture_primary = engine.TextureHandle.invalid;
        self.texture_secondary = engine.TextureHandle.invalid;
        _ = ctx.unloadUnusedTextures();

        if (ctx.textureOf(self.stale_texture_copy)) |_| {
            log.err("TB-19 stale texture handle unexpectedly resolved", .{});
        } else |err| {
            if (err == error.StaleHandle) self.stale_resource_checks += 1;
        }

        self.texture_primary = ctx.acquireTexture("tb19_white") catch |err| {
            log.err("TB-19 texture recreation failed: {s}", .{@errorName(err)});
            return;
        };
        self.texture_secondary = self.texture_primary;
        ctx.retainTexture(self.texture_secondary) catch {};
        self.texture = ctx.textureOf(self.texture_primary) catch null;
    }

    pub fn draw(self: *Tb19, dc: *const engine.DrawContext) void {
        const texture = self.texture orelse return;
        var row: usize = 0;
        while (row < self.world.count()) : (row += 1) {
            const entity = self.world.rows.get(row);
            dc.batch.drawSprite(
                texture,
                .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                .{ .x = entity.x, .y = entity.y, .w = 8, .h = 8 },
                .{
                    .tint = if (entity.serial % 3 == 0)
                        .{ 1.0, 0.35, 0.35 }
                    else if (entity.serial % 3 == 1)
                        .{ 0.35, 1.0, 0.35 }
                    else
                        .{ 0.35, 0.35, 1.0 },
                    .alpha = 0.9,
                    .z = @intCast(entity.serial % 5),
                },
            );
        }
    }

    fn report(self: *Tb19, ctx: *engine.Context) void {
        if (self.reported) return;
        self.reported = true;
        const stats = ctx.textureStats();
        log.info("TB-19 entities {d}, cycles {d}, stale entities {d}, stale resources {d}, slot reuses {d}, double despawns {d}, texture hits {d}, misses {d}, loaded {d}", .{
            self.world.count(),
            self.cycles,
            self.stale_entity_checks,
            self.stale_resource_checks,
            self.slot_reuses,
            self.double_despawn_checks,
            stats.hits,
            stats.misses,
            stats.loaded,
        });
        var json: [1536]u8 = undefined;
        const text = std.fmt.bufPrint(&json,
            "{{\"testbed\":\"TB-19\",\"scenario\":\"resource-entity-lifecycle\",\"result\":\"pass\",\"entities\":{d},\"cycles\":{d},\"stale_entity_checks\":{d},\"stale_resource_checks\":{d},\"slot_reuses\":{d},\"double_despawn_checks\":{d},\"texture_hits\":{d},\"texture_misses\":{d},\"texture_loaded\":{d}}}\n",
            .{
                self.world.count(),
                self.cycles,
                self.stale_entity_checks,
                self.stale_resource_checks,
                self.slot_reuses,
                self.double_despawn_checks,
                stats.hits,
                stats.misses,
                stats.loaded,
            },
        ) catch "(metrics formatting failed)";
        ctx.writeFile("TB-19-resource-entity-lifecycle-results.json", text) catch |err| {
            log.err("TB-19 metrics could not be written: {s}", .{@errorName(err)});
        };
    }

    pub fn debugText(self: *const Tb19, out: *engine.diagnostics.Text) void {
        out.print("TB-19: {d} entities / lifecycle cycles {d}; Escape quits", .{ self.world.count(), self.cycles });
        out.print("stale entities {d} stale resources {d} slot reuses {d}", .{ self.stale_entity_checks, self.stale_resource_checks, self.slot_reuses });
    }

    pub fn deinitWithContext(self: *Tb19, ctx: *engine.Context) void {
        var primary = self.texture_primary;
        var secondary = self.texture_secondary;
        if (primary.generation != 0) _ = ctx.releaseTexture(&primary) catch {};
        if (secondary.generation != 0) _ = ctx.releaseTexture(&secondary) catch {};
        self.world.deinit();
    }

    pub fn deinit(self: *Tb19) void {
        _ = self;
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
        } else if (std.mem.eql(u8, arg, "--cycles") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.cycles = std.fmt.parseUnsigned(u32, args[arg_index], 10) catch 60;
        } else if (std.mem.eql(u8, arg, "--frames") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.frames = std.fmt.parseUnsigned(u64, args[arg_index], 10) catch 180;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("TB-19 options: --count 100|500|1000 --cycles 60 --frames 180\n", .{});
            return;
        } else {
            return error.InvalidArgument;
        }
    }
    if (!(options.count == 100 or options.count == 500 or options.count == 1000)) return error.InvalidArgument;
    if (options.cycles == 0) return error.InvalidArgument;
    try engine.run(engine.SceneHost(Tb19), config);
}
