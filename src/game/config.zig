//! Game settings: title, window and native view sizes, level size, background color, update
//! rate, and scale mode. Read once at startup. The engine knows nothing else about the game.

const engine = @import("../engine/engine.zig");

/// Window title. The engine appends play stats to it.
pub const title: [:0]const u8 = "My Game";
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
/// Size of the test level, in tiles.
pub const level_cols: u32 = 40;
pub const level_rows: u32 = 24;
