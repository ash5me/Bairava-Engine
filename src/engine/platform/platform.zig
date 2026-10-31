//! The platform layer: everything that talks to the operating system or to SDL. Only the files
//! under platform/sdl/ import SDL, and the rest of the engine reaches the platform through here.

const sdl_input = @import("sdl/input.zig");
const types = @import("types.zig");

pub const Scancode = types.Scancode;
pub const MouseButton = types.MouseButton;
pub const Event = types.Event;

/// Platform events and held keys, as the engine uses them.
pub const events = struct {
    /// The next event the engine consumes, or null when the queue has none left. Events the engine
    /// does not consume are skipped.
    pub fn poll() ?Event {
        return sdl_input.poll();
    }

    /// Whether a physical key is held, as of the latest query.
    pub fn isHeld(code: Scancode) bool {
        return sdl_input.isHeld(code);
    }
};

// Still re-exported from the SDL backend. Each moves behind this file in its own step.
pub const sdl = @import("sdl/sdl.zig");
pub const window = @import("sdl/window.zig");
pub const gpu = @import("sdl/gpu.zig");
pub const audio = @import("sdl/audio.zig");
