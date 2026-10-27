//! Entry point. Hands the game to the engine. Gameplay changes belong in src/game/.

const engine = @import("engine/engine.zig");
const config = @import("game/config.zig");
const Game = @import("game/game.zig").Game;

pub fn main() void {
    engine.run(Game, .{
        .title = config.title,
        .window_w = config.window_w,
        .window_h = config.window_h,
        .native_w = config.native_w,
        .native_h = config.native_h,
        .clear_rgb = config.clear_rgb,
    });
}
