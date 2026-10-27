//! Game settings: title, window and native view sizes, level size, and background color.
//! The engine receives these once at startup and knows nothing else about the game.

/// Window title. The engine appends play stats to it.
pub const title: [:0]const u8 = "My Game";
pub const window_w: c_int = 960;
pub const window_h: c_int = 540;
/// The smallest view the art is designed for, in native pixels.
pub const native_w: u32 = 320;
pub const native_h: u32 = 180;
/// Background color behind the world, as RGB from 0 to 1.
pub const clear_rgb = [3]f32{ 0.2, 0.3, 0.5 };
/// Size of the test level, in tiles.
pub const level_cols: u32 = 40;
pub const level_rows: u32 = 24;
