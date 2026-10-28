//! Gameplay: the level, the player, and how actions drive them. The engine calls into this
//! file through `init`, `update`, `draw`, and `deinit`, and never looks inside it.

const std = @import("std");

const engine = @import("../engine/engine.zig");
const config = @import("config.zig");
const controls = @import("controls.zig");
const Level = @import("level.zig").Level;
const Player = @import("player.zig").Player;

const log = engine.log.scoped("game");

pub const Game = struct {
    level: Level,
    player: Player,
    /// Asset names and validated paths, registered from config.assets at startup.
    assets: engine.assets.Table,
    tile: engine.Texture,
    warrior: engine.Texture,

    pub fn init(ctx: *engine.Context) Game {
        // Register every asset up front. A bad name or path is a bug in config.zig, so it panics here,
        // where the message says which entry is wrong.
        var table = engine.assets.Table.init(std.heap.page_allocator, config.max_assets) catch |err| {
            std.debug.panic("asset table allocation failed: {s}", .{@errorName(err)});
        };
        for (config.assets) |asset| {
            _ = table.register(asset.name, asset.path) catch |err| {
                std.debug.panic("asset '{s}' at '{s}' was rejected: {s}", .{ asset.name, asset.path, @errorName(err) });
            };
        }
        log.info("registered {d} assets", .{table.count()});

        const tile = loadNamedTexture(ctx, &table, "tile");
        const warrior = loadNamedTexture(ctx, &table, "warrior");
        const level = Level.load(ctx, config.level_path);
        checkTileset(&level, &tile);

        const spawn = level.map.spawn;
        const player = Player.standingOn(spawn.col, spawn.row);
        log.info("map {d}x{d} tiles, player starts on tile ({d}, {d})", .{ level.map.cols, level.map.rows, spawn.col, spawn.row });

        return .{
            .level = level,
            .player = player,
            .assets = table,
            .tile = tile,
            .warrior = warrior,
        };
    }

    pub fn deinit(self: *Game) void {
        self.level.deinit();
        self.warrior.deinit();
        self.tile.deinit();
        self.assets.deinit();
    }

    /// Runs at the fixed update rate. `ctx.dt` is the length of the step.
    pub fn update(self: *Game, ctx: *engine.Context) void {
        const input = ctx.input;
        if (controls.pressed(input, .quit)) {
            log.info("quit action pressed", .{});
            ctx.running = false;
        }
        if (controls.pressed(input, .toggle_scale)) {
            ctx.scale_mode = switch (ctx.scale_mode) {
                .fit => .integer,
                .integer => .fit,
            };
        }
        if (controls.pressed(input, .zoom_in)) ctx.zoomBy(config.zoom_step);
        if (controls.pressed(input, .zoom_out)) ctx.zoomBy(1.0 / config.zoom_step);
        if (controls.pressed(input, .zoom_reset)) ctx.resetZoom();

        // Each movement action contributes one unit on its axis.
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (controls.held(input, .move_left)) dx -= 1;
        if (controls.held(input, .move_right)) dx += 1;
        if (controls.held(input, .move_up)) dy -= 1;
        if (controls.held(input, .move_down)) dy += 1;

        self.player.update(dx, dy, ctx.dt, &self.level.map);
    }

    /// Runs once per frame. `dc.alpha` blends the player between the last two updates. The camera
    /// eases toward the player using the frame time, so its speed doesn't depend on the frame rate.
    pub fn draw(self: *Game, dc: *const engine.DrawContext) void {
        const center = self.player.drawCenter(dc.alpha);
        dc.cam.world_w = self.level.widthPx();
        dc.cam.world_h = self.level.heightPx();
        dc.cam.followSmooth(center.x, center.y, dc.dt, config.camera_rate);

        // Draw order: ground, decoration, the player, and then foreground, which can cover the player.
        self.level.drawLayer(dc.batch, &self.tile, dc.cam, .ground);
        self.level.drawLayer(dc.batch, &self.tile, dc.cam, .decoration);
        self.player.draw(dc.batch, &self.warrior, dc.cam, dc.alpha);
        self.level.drawLayer(dc.batch, &self.tile, dc.cam, .foreground);
    }
};

/// Every tile ID in the map must name a tile in the tileset. Otherwise the map would draw blank or
/// wrong tiles. Panics with the offending ID so the map or the texture can be fixed.
fn checkTileset(level: *const Level, tileset: *const engine.Texture) void {
    const count = Level.tileCount(tileset);
    const largest = level.map.largestId();
    if (largest >= count) {
        std.debug.panic("the map uses tile ID {d}, but the tile texture holds only {d} tiles", .{ largest, count });
    }
}

/// Loads the texture registered under `name`. A name that isn't registered is a bug in config.zig,
/// so it panics.
fn loadNamedTexture(ctx: *engine.Context, table: *const engine.assets.Table, name: []const u8) engine.Texture {
    const id = table.find(name) orelse std.debug.panic("asset '{s}' is not registered", .{name});
    const path = table.pathOf(id) orelse unreachable;
    return ctx.loadTexture(path.slice());
}
