//! Gameplay: the level, the player, and how actions drive them. The engine calls into this
//! file through `init`, `update`, `draw`, and `deinit`, and never looks inside it.

const engine = @import("../engine/engine.zig");
const config = @import("config.zig");
const controls = @import("controls.zig");
const Level = @import("level.zig").Level;
const Player = @import("player.zig").Player;

pub const Game = struct {
    level: Level,
    player: Player,
    tile: engine.Texture,
    warrior: engine.Texture,

    pub fn init(ctx: *engine.Context) Game {
        const level = Level{ .cols = config.level_cols, .rows = config.level_rows };
        return .{
            .level = level,
            .player = Player.init(level.widthPx(), level.heightPx()),
            .tile = ctx.loadTexture("assets/tile.png"),
            .warrior = ctx.loadTexture("assets/warrior_16x32.png"),
        };
    }

    pub fn deinit(self: *Game) void {
        self.warrior.deinit();
        self.tile.deinit();
    }

    /// Reads actions and advances the player. The quit action asks the engine to stop.
    pub fn update(self: *Game, ctx: *engine.Context) void {
        const input = ctx.input;
        if (controls.pressed(input, .quit)) ctx.running = false;

        // Each movement action contributes one unit on its axis.
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (controls.held(input, .move_left)) dx -= 1;
        if (controls.held(input, .move_right)) dx += 1;
        if (controls.held(input, .move_up)) dy -= 1;
        if (controls.held(input, .move_down)) dy += 1;

        self.player.update(dx, dy, ctx.dt, self.level.widthPx(), self.level.heightPx());
    }

    /// Points the camera at the player and queues the visible world.
    pub fn draw(self: *Game, dc: *const engine.DrawContext) void {
        dc.cam.world_w = self.level.widthPx();
        dc.cam.world_h = self.level.heightPx();
        dc.cam.follow(self.player.centerX(), self.player.centerY());

        self.level.draw(dc.batch, &self.tile, dc.cam);
        self.player.draw(dc.batch, &self.warrior, dc.cam);
    }
};
