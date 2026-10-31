//! Drains the platform event queue once per frame. Quit, F11 (fullscreen), F3 (overlay), and F4
//! (debug geometry) are handled here. Every event also reaches the input state, which keeps presses,
//! releases, and clicks until the next update step takes them. Gamepads connecting and leaving are
//! logged here as well.

const platform = @import("../platform/platform.zig");
const Input = @import("../input/input.zig").Input;
const logging = @import("../logging/log.zig");
const console_mod = @import("../diagnostics/console.zig");
const collector_mod = @import("../diagnostics/collector.zig");
const gate = @import("../diagnostics/gate.zig");
const elog = logging.scoped("engine");

/// What the event queue asked the engine to do during one pump.
pub const Result = struct {
    /// The window asked to close.
    quit: bool = false,
    /// F3 was pressed, so the debug overlay toggles.
    toggle_overlay: bool = false,
    /// F4 was pressed, so the debug geometry toggles.
    toggle_geometry: bool = false,
};

/// Handles every queued platform event. Keyboard and mouse state is updated as each event arrives.
pub fn pump(
    window: *platform.Window,
    input: *Input,
    console: *console_mod.Console,
    collector: *collector_mod.Collector,
    diagnostics_visible: *bool,
) Result {
    var result = Result{};
    while (platform.events.poll()) |event| {
        var consumed = false;
        switch (event) {
            .quit => {
                elog.info("quit requested by the window", .{});
                result.quit = true;
            },
            .key_down => |down| {
                if (!down.repeat) {
                    switch (down.scancode) {
                        .f2 => if (gate.enabled) {
                            if (console.visible) {
                                console.close();
                                if (!platform.window.stopTextInput(window)) elog.warn("could not stop text input", .{});
                            } else {
                                console.open();
                                if (!platform.window.startTextInput(window)) elog.warn("could not start text input", .{});
                            }
                            consumed = true;
                        },
                        .f11 => {
                            platform.window.toggleFullscreen(window);
                        },
                        .f3 => {
                            result.toggle_overlay = true;
                        },
                        .f4 => {
                            result.toggle_geometry = true;
                        },
                        else => {},
                    }
                    if (gate.enabled and console.visible) {
                        switch (down.scancode) {
                            .enter => {
                                console.submit(collector, diagnostics_visible);
                                consumed = true;
                            },
                            .backspace => {
                                console.backspace();
                                consumed = true;
                            },
                            .escape => {
                                console.close();
                                if (!platform.window.stopTextInput(window)) elog.warn("could not stop text input", .{});
                                consumed = true;
                            },
                            else => {},
                        }
                    }
                }
            },
            .text_input => |text| if (gate.enabled and console.visible) console.append(text.slice()),
            .gamepad_added => |id| elog.info("gamepad connected in slot {d}", .{id.slot}),
            .gamepad_removed => |id| elog.info("gamepad removed from slot {d}", .{id.slot}),
            else => {},
        }
        if (!consumed) input.apply(event);
    }
    return result;
}
