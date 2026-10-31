//! Drains the SDL event queue once per frame. Quit, F11 (fullscreen), and F3 (overlay) are handled
//! here. Every event also reaches the input state, which keeps presses and clicks until the next
//! update step takes them.

const c = @import("../platform/sdl/sdl.zig").c;
const platform = @import("../platform/platform.zig");
const Input = @import("../input/input.zig").Input;
const logging = @import("../logging/log.zig");
const elog = logging.scoped("engine");

/// What the event queue asked the engine to do during one pump.
pub const Result = struct {
    /// The window asked to close.
    quit: bool = false,
    /// F3 was pressed, so the debug overlay toggles.
    toggle_overlay: bool = false,
};

/// Handles every queued event. Keyboard and mouse state is updated as each event arrives.
pub fn pump(window: *c.SDL_Window, input: *Input) Result {
    var result = Result{};
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        if (event.type == c.SDL_EVENT_QUIT) {
            elog.info("quit requested by the window", .{});
            result.quit = true;
        }
        if (event.type == c.SDL_EVENT_KEY_DOWN and event.key.key == c.SDLK_F11 and !event.key.repeat) {
            platform.window.toggleFullscreen(window);
        }
        if (event.type == c.SDL_EVENT_KEY_DOWN and event.key.key == c.SDLK_F3 and !event.key.repeat) {
            result.toggle_overlay = true;
        }
        platform.input.handleEvent(input, &event);
    }
    return result;
}
