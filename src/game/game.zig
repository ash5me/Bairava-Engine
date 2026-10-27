//! Gameplay: the level, the player, and how actions drive them. The engine calls into this
//! file through `init`, `update`, `draw`, and `deinit`, and never looks inside it.

const engine = @import("../engine/engine.zig");
const config = @import("config.zig");
const controls = @import("controls.zig");
const Level = @import("level.zig").Level;
const Player = @import("player.zig").Player;

const log = engine.log.scoped("game");

pub const Game = struct {
    level: Level,
    player: Player,
    tile: engine.Texture,
    warrior: engine.Texture,

    pub fn init(ctx: *engine.Context) Game {
        const level = Level{ .cols = config.level_cols, .rows = config.level_rows };
        const player = Player.init(level.widthPx(), level.heightPx());
        log.info("level {d}x{d} tiles, player starts at ({d:.0}, {d:.0})", .{ config.level_cols, config.level_rows, player.x, player.y });
        return .{
            .level = level,
            .player = player,
            .tile = ctx.loadTexture("assets/tile.png"),
            .warrior = ctx.loadTexture("assets/warrior_16x32.png"),
        };
    }

    pub fn deinit(self: *Game) void {
        self.warrior.deinit();
        self.tile.deinit();
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

        // Each movement action contributes one unit on its axis.
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (controls.held(input, .move_left)) dx -= 1;
        if (controls.held(input, .move_right)) dx += 1;
        if (controls.held(input, .move_up)) dy -= 1;
        if (controls.held(input, .move_down)) dy += 1;

        self.player.update(dx, dy, ctx.dt, self.level.widthPx(), self.level.heightPx());
    }

    /// Runs once per frame. `dc.alpha` blends the player between the last two updates.
    pub fn draw(self: *Game, dc: *const engine.DrawContext) void {
        const center = self.player.drawCenter(dc.alpha);
        dc.cam.world_w = self.level.widthPx();
        dc.cam.world_h = self.level.heightPx();
        dc.cam.follow(center.x, center.y);

        self.level.draw(dc.batch, &self.tile, dc.cam);
        self.player.draw(dc.batch, &self.warrior, dc.cam, dc.alpha);
    }
};
