//! Windows through SDL3: creation, fullscreen, and the size and density the renderer needs. This
//! file converts between the engine's opaque `platform.Window` and SDL's window. Outside
//! platform/sdl/, nothing sees an SDL window.

const std = @import("std");
const c = @import("sdl.zig").c;
const types = @import("../types.zig");
const Window = types.Window;
const PixelSize = types.PixelSize;

/// The SDL window behind an engine handle. Only handles this backend created are converted here,
/// so the pointer is always a real SDL window.
pub fn toSdl(window: *Window) *c.SDL_Window {
    return @ptrCast(window);
}

/// The engine handle for an SDL window this backend created.
pub fn fromSdl(sdl_window: *c.SDL_Window) *Window {
    return @ptrCast(sdl_window);
}

/// Creates the game window. It is resizable and uses the full pixel density of high-DPI displays.
<<<<<<< HEAD
pub const CreateError = error{WindowCreateFailed};

pub fn create(title: [:0]const u8, width: c_int, height: c_int, fullscreen: bool) CreateError!*Window {
    const window_flags: u64 = @as(u64, c.SDL_WINDOW_RESIZABLE) | @as(u64, c.SDL_WINDOW_HIGH_PIXEL_DENSITY) |
        (if (fullscreen) @as(u64, c.SDL_WINDOW_FULLSCREEN) else 0);
    const sdl_window = c.SDL_CreateWindow(title.ptr, width, height, window_flags) orelse {
        return error.WindowCreateFailed;
=======
pub fn create(title: [:0]const u8, width: c_int, height: c_int, fullscreen: bool) *Window {
    const window_flags: u64 = @as(u64, c.SDL_WINDOW_RESIZABLE) | @as(u64, c.SDL_WINDOW_HIGH_PIXEL_DENSITY) |
        (if (fullscreen) @as(u64, c.SDL_WINDOW_FULLSCREEN) else 0);
    const sdl_window = c.SDL_CreateWindow(title.ptr, width, height, window_flags) orelse {
        std.debug.panic("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
>>>>>>> main
    };
    return fromSdl(sdl_window);
}

/// Destroys a window made by `create`.
pub fn destroy(window: *Window) void {
    c.SDL_DestroyWindow(toSdl(window));
}

/// Switches the window between windowed and full screen.
pub fn toggleFullscreen(window: *Window) void {
    const sdl_window = toSdl(window);
    const fullscreen = (c.SDL_GetWindowFlags(sdl_window) & c.SDL_WINDOW_FULLSCREEN) != 0;
    _ = c.SDL_SetWindowFullscreen(sdl_window, !fullscreen);
}

/// The window's size in pixels. On high-DPI displays this is larger than its size in points.
pub fn pixelSize(window: *Window) PixelSize {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(toSdl(window), &w, &h);
    return .{ .w = w, .h = h };
}

/// Pixels per point. Mouse positions are in points, so the view mapping needs this.
pub fn pixelDensity(window: *Window) f32 {
    return c.SDL_GetWindowPixelDensity(toSdl(window));
}

test "an SDL window converts to a handle and back to the same pointer" {
    // The pointer is never dereferenced, so any address is enough to check the conversion.
    var stand_in: u8 = 0;
    const sdl_window: *c.SDL_Window = @ptrCast(&stand_in);
    try std.testing.expect(toSdl(fromSdl(sdl_window)) == sdl_window);
}
