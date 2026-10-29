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
    /// One texture that holds every sprite. Packing them at build time means the whole world and
    /// the player sample the same texture, so they can share a draw call.
    atlas: engine.Texture,
    /// Where each sprite sits in the atlas, read from the index beside it.
    atlas_index: engine.atlas.Atlas,
    /// The atlas regions of the sprites this game draws.
    tile: engine.atlas.Region,
    warrior: engine.atlas.Region,

    pub fn init(ctx: *engine.Context) Game {
        const index = loadAtlasIndex(ctx);
        const atlas = ctx.loadTexture(config.atlas_image_path);
        checkAtlasSize(&index, &atlas);
        log.info("atlas {d}x{d} with {d} sprites", .{ atlas.width, atlas.height, index.len });

        const tile = regionNamed(&index, "tile");
        const warrior = regionNamed(&index, "warrior");
        const level = Level.load(ctx, config.level_path);
        checkTileset(&level, tile);

        const spawn = level.map.spawn;
        const player = Player.standingOn(spawn.col, spawn.row);
        log.info("map {d}x{d} tiles, player starts on tile ({d}, {d})", .{ level.map.cols, level.map.rows, spawn.col, spawn.row });

        return .{
            .level = level,
            .player = player,
            .atlas = atlas,
            .atlas_index = index,
            .tile = tile,
            .warrior = warrior,
        };
    }

    pub fn deinit(self: *Game) void {
        self.level.deinit();
        self.atlas.deinit();
        self.atlas_index.deinit();
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
        self.level.drawLayer(dc.batch, &self.atlas, self.tile, dc.cam, .ground);
        self.level.drawLayer(dc.batch, &self.atlas, self.tile, dc.cam, .decoration);
        self.player.draw(dc.batch, &self.atlas, self.warrior, dc.cam, dc.alpha);
        self.level.drawLayer(dc.batch, &self.atlas, self.tile, dc.cam, .foreground);
    }
};

/// Reads and parses the atlas index. The index is written by the build, so a missing or malformed
/// one means the build is broken, and this panics and says why.
fn loadAtlasIndex(ctx: *const engine.Context) engine.atlas.Atlas {
    const text = ctx.readFile(config.atlas_index_path) catch |err| {
        std.debug.panic("atlas index '{s}' could not be read: {s}", .{ config.atlas_index_path, @errorName(err) });
    };
    defer std.heap.page_allocator.free(text);
    return engine.atlas.Atlas.parse(std.heap.page_allocator, text) catch |err| {
        std.debug.panic("atlas index '{s}' is invalid: {s}", .{ config.atlas_index_path, @errorName(err) });
    };
}

/// The index must describe the image it was packed with. A stale or mismatched pair would draw the
/// wrong pixels, so this checks the sizes match before anything is drawn.
fn checkAtlasSize(index: *const engine.atlas.Atlas, atlas: *const engine.Texture) void {
    if (index.width != atlas.width or index.height != atlas.height) {
        std.debug.panic("atlas index is for {d}x{d}, but the atlas image is {d}x{d}; rebuild", .{
            index.width, index.height, atlas.width, atlas.height,
        });
    }
}

/// The region of the sprite called `name`. A name that isn't in the atlas is a bug in the sprite
/// list in build.zig, so it panics.
fn regionNamed(index: *const engine.atlas.Atlas, name: []const u8) engine.atlas.Region {
    return index.find(name) orelse std.debug.panic("sprite '{s}' is not in the atlas; add it to atlas_sprites in build.zig", .{name});
}

/// Every tile ID in the map must name a tile in the tile sprite. Otherwise the map would draw blank
/// or wrong tiles. Panics with the offending ID so the map or the sprite can be fixed.
fn checkTileset(level: *const Level, tileset: engine.atlas.Region) void {
    const count = Level.tileCount(tileset);
    const largest = level.map.largestId();
    if (largest >= count) {
        std.debug.panic("the map uses tile ID {d}, but the tile sprite holds only {d} tiles", .{ largest, count });
    }
}
