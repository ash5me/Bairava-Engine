//! Named-module root for `zig build check-assets`. The tool imports the asset validation rules through
//! this file, so the rules are compiled once and shared with the engine. It contains no SDL or GPU code.

pub const validate = @import("engine/assets/validate.zig");
pub const bmfont_check = @import("engine/assets/bmfont_check.zig");
pub const bmfont = @import("engine/text/bmfont.zig");
pub const tilemap = @import("engine/scene/tilemap.zig");
pub const animation = @import("engine/animation/data.zig");
pub const level_data = @import("game/level_data.zig");
pub const prefab = @import("game/prefab.zig");
