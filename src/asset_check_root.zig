//! Named-module root for `zig build check-assets`. The tool imports the asset validation rules through
//! this file, so the rules are compiled once and shared with the engine. It contains no SDL or GPU code.

pub const validate = @import("engine/assets/validate.zig");
