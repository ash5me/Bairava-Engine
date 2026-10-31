//! SDL startup and shutdown. This is the only file that calls `SDL_Init`, `SDL_InitSubSystem`, or
//! `SDL_Quit`. Other backend files open and close their own windows, devices, and streams, but they
//! never start or stop the subsystems those run on.
//!
//! Order, as `core/lifecycle.zig` calls it. Startup: settings are read, then `init`, then the
//! window, the GPU device, and the audio device. Shutdown: the audio device, the batches, the
//! target, the GPU, and the window are released, then `shutdown`.

const std = @import("std");

const c = @import("sdl.zig").c;
const logging = @import("../../logging/log.zig");

const audio_log = logging.scoped("audio");

/// Starts SDL's video subsystem, which the window and GPU need, and its audio subsystem. A video
/// failure is fatal, so this panics. An audio failure is logged, and the game runs silent, since the
/// audio backend opens no device when the subsystem is not up.
<<<<<<< HEAD
pub const InitError = error{
    VideoInitFailed,
};

pub fn init() InitError!void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        logging.scoped("platform").warn("video initialization failed: {s}", .{c.SDL_GetError()});
        return error.VideoInitFailed;
=======
pub fn init() void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.panic("SDL_Init failed: {s}", .{c.SDL_GetError()});
>>>>>>> main
    }
    if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
        audio_log.warn("audio subsystem unavailable, continuing silent: {s}", .{c.SDL_GetError()});
    }
}

/// Shuts SDL down, including every subsystem `init` started. Call it once, after every window,
/// device, and stream is released.
pub fn shutdown() void {
    c.SDL_Quit();
}
