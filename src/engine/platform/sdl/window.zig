//! Windows through SDL3: creation, fullscreen, and the size and density the renderer needs.

const std = @import("std");
const c = @import("sdl.zig").c;

/// Creates the game window. It is resizable and uses the full pixel density of high-DPI displays.
pub fn create(title: [:0]const u8, width: c_int, height: c_int, fullscreen: bool) *c.SDL_Window {
    const window_flags: u64 = @as(u64, c.SDL_WINDOW_RESIZABLE) | @as(u64, c.SDL_WINDOW_HIGH_PIXEL_DENSITY) |
        (if (fullscreen) @as(u64, c.SDL_WINDOW_FULLSCREEN) else 0);
    return c.SDL_CreateWindow(title.ptr, width, height, window_flags) orelse {
        std.debug.panic("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
    };
}

/// Switches the window between windowed and full screen.
pub fn toggleFullscreen(window: *c.SDL_Window) void {
    const fullscreen = (c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_FULLSCREEN) != 0;
    _ = c.SDL_SetWindowFullscreen(window, !fullscreen);
}

/// The window's size in pixels. On high-DPI displays this is larger than its size in points.
pub const PixelSize = struct { w: c_int, h: c_int };

pub fn pixelSize(window: *c.SDL_Window) PixelSize {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window, &w, &h);
    return .{ .w = w, .h = h };
}

/// Pixels per point. Mouse positions are in points, so the view mapping needs this.
pub fn pixelDensity(window: *c.SDL_Window) f32 {
    return c.SDL_GetWindowPixelDensity(window);
}
