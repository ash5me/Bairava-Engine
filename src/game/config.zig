//! Game settings: title, window and native view sizes, level path, background color, update
//! rate, and scale mode. Read once at startup. The engine knows nothing else about the game.

const engine = @import("../engine/engine.zig");

/// Window title. The engine appends play stats to it.
pub const title: [:0]const u8 = "Semkootru";
pub const window_w: c_int = 960;
pub const window_h: c_int = 540;
/// The smallest view the art is designed for, in native pixels.
pub const native_w: u32 = 320;
pub const native_h: u32 = 180;
/// Background color behind the world, as RGB from 0 to 1.
pub const clear_rgb = [3]f32{ 0.2, 0.3, 0.5 };
/// Game logic steps per second. Movement is in pixels per second, so this changes smoothness, not speed.
pub const update_hz: u32 = 60;
/// Starting scale mode. Press I in game to toggle between fit and integer.
pub const scale_mode: engine.ScaleMode = .fit;
/// How fast the camera catches up with the player, as a rate per second. Higher is snappier. Zero
/// turns smoothing off, so the camera snaps to the player.
pub const camera_rate: f32 = 10.0;
/// One asset the game loads at startup: the name code uses to refer to it, and its path relative to
/// the project root.
pub const Asset = struct {
    name: []const u8,
    path: []const u8,
};

/// Upper bound on registered assets. The asset table is sized from it.
pub const max_assets: u32 = 32;

/// Every asset the game registers at startup. Names follow the rules in engine/string.zig and must
/// be unique.
pub const assets = [_]Asset{
    .{ .name = "tile", .path = "assets/tile.png" },
    .{ .name = "warrior", .path = "assets/warrior_16x32.png" },
};

comptime {
    if (assets.len > max_assets) @compileError("config.assets has more entries than max_assets");
}

/// The tile map the game loads at startup, relative to the executable's folder.
pub const level_path = "assets/maps/level1.txt";
