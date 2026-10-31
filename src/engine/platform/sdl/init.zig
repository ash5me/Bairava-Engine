//! SDL startup and shutdown. This is the only file that calls `SDL_Init`, `SDL_InitSubSystem`, or
//! `SDL_Quit`. Other backend files open and close their own windows, devices, and streams, but they
//! never start or stop the subsystems those run on.
//!
//! Order, as `core/lifecycle.zig` calls it. Startup: settings are read, then `init`, then the
//! window, the GPU device, and the audio device. Shutdown: the audio device, the batches, the
//! target, the GPU, and the window are released, then the gamepads (see platform.zig), then `shutdown`.

const std = @import("std");

const c = @import("sdl.zig").c;
const logging = @import("../../logging/log.zig");

const audio_log = logging.scoped("audio");
const gamepad_log = logging.scoped("gamepad");

/// Starts SDL's video subsystem, which the window and GPU need, and its audio and gamepad subsystems.
/// A video failure is fatal. An audio failure is logged, and the game runs silent, since the audio
/// backend opens no device when the subsystem is not up. A gamepad failure is logged, and the game
/// runs on the keyboard and mouse.
pub const InitError = error{
    VideoInitFailed,
};

pub fn init() InitError!void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        logging.scoped("platform").warn("video initialization failed: {s}", .{c.SDL_GetError()});
        return error.VideoInitFailed;
    }
    if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
        audio_log.warn("audio subsystem unavailable, continuing silent: {s}", .{c.SDL_GetError()});
    }
    if (!c.SDL_InitSubSystem(c.SDL_INIT_GAMEPAD)) {
        gamepad_log.warn("gamepad subsystem unavailable, continuing without controllers: {s}", .{c.SDL_GetError()});
    }
}

/// Shuts SDL down, including every subsystem `init` started. Call it once, after every window,
/// device, and stream is released.
pub fn shutdown() void {
    c.SDL_Quit();
}
