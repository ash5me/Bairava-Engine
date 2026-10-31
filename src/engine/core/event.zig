//! Drains the platform event queue once per frame. Quit, F11 (fullscreen), and F3 (overlay) are
//! handled here. Every event also reaches the input state, which keeps presses, releases, and clicks
//! until the next update step takes them. Gamepads connecting and leaving are logged here as well.

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
pub fn pump(window: *platform.Window, input: *Input) Result {
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
            .gamepad_added => |id| elog.info("gamepad connected in slot {d}", .{id.slot}),
            .gamepad_removed => |id| elog.info("gamepad removed from slot {d}", .{id.slot}),
            else => {},
        }
        input.apply(event);
    }
    return result;
}
