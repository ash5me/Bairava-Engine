//! The platform layer: everything that talks to the operating system or to SDL. Only the files
//! under platform/sdl/ import SDL, and the rest of the engine reaches the platform through here.

const types = @import("types.zig");
const sdl_clock = @import("sdl/clock.zig");
const sdl_init = @import("sdl/init.zig");
const sdl_input = @import("sdl/input.zig");
const window_backend = @import("sdl/window.zig");

pub const Scancode = types.Scancode;
pub const MouseButton = types.MouseButton;
pub const Event = types.Event;
pub const Window = types.Window;
pub const PixelSize = types.PixelSize;

/// Starts the platform: the video subsystem, which the window and GPU need, and the audio subsystem.
/// A video failure panics. An audio failure is logged, and the game runs silent. Call it once,
/// before any window or device is created.
pub fn init() void {
    sdl_init.init();
}

/// Stops the platform and everything it started. Call it once, after every window, device, and
/// audio stream has been released.
pub fn shutdown() void {
    sdl_init.shutdown();
}

/// Monotonic time and delays. The frame loop and the logger's timestamps both read this clock.
pub const clock = struct {
    /// Nanoseconds from an arbitrary fixed point. Only differences mean anything, and the value never
    /// goes backward.
    pub fn nowNs() u64 {
        return sdl_clock.nowNs();
    }

    /// Blocks the calling thread for at least `ms` milliseconds.
    pub fn sleepMs(ms: u32) void {
        sdl_clock.sleepMs(ms);
    }
};

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

/// The game window. The engine holds a `*Window` and never sees the SDL type behind it.
pub const window = struct {
    /// Creates the game window. Panics if the platform cannot create one.
    pub fn create(title: [:0]const u8, width: c_int, height: c_int, fullscreen: bool) *Window {
        return window_backend.create(title, width, height, fullscreen);
    }

    /// Destroys a window made by `create`.
    pub fn destroy(win: *Window) void {
        window_backend.destroy(win);
    }

    /// Switches the window between windowed and full screen.
    pub fn toggleFullscreen(win: *Window) void {
        window_backend.toggleFullscreen(win);
    }

    /// The window's size in pixels. On high-DPI displays this is larger than its size in points.
    pub fn pixelSize(win: *Window) PixelSize {
        return window_backend.pixelSize(win);
    }

    /// Pixels per point. Mouse positions are in points, so the view mapping needs this.
    pub fn pixelDensity(win: *Window) f32 {
        return window_backend.pixelDensity(win);
    }
};

// Still re-exported from the SDL backend. The GPU step (8) and the audio step (7) move these
// behind this file. The SDL C namespace is not exported, so the engine cannot name SDL types here.
pub const gpu = @import("sdl/gpu.zig");
pub const audio = @import("sdl/audio.zig");
