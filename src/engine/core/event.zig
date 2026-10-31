//! Drains the platform event queue once per frame. Quit, F11 (fullscreen), and F3 (overlay) are
//! handled here. Every event also reaches the input state, which keeps presses and clicks until the
//! next update step takes them.

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

/// Handles every queued platform event. Keyboard and mouse state is updated as each event arrives.
/// The window is still an SDL window here. The window step changes it to `platform.Window`.
pub fn pump(window: *c.SDL_Window, input: *Input) Result {
    var result = Result{};
    while (platform.events.poll()) |event| {
        switch (event) {
            .quit => {
                elog.info("quit requested by the window", .{});
                result.quit = true;
            },
            .key_down => |down| {
                if (!down.repeat) {
                    switch (down.scancode) {
                        .f11 => {
                            platform.window.toggleFullscreen(window);
                        },
                        .f3 => {
                            result.toggle_overlay = true;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
        input.apply(event);
    }
    return result;
}
