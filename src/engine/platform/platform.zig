//! The platform layer: everything that talks to the operating system or to SDL. Only the files
//! under platform/sdl/ import SDL, and the rest of the engine reaches the platform through here.

pub const sdl = @import("sdl/sdl.zig");
pub const window = @import("sdl/window.zig");
pub const gpu = @import("sdl/gpu.zig");
pub const input = @import("sdl/input.zig");
pub const audio = @import("sdl/audio.zig");
