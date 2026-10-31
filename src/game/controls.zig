//! Named actions and the bindings they start with. Gameplay asks for actions and never for keys or
//! buttons. The defaults below are Semkootru's own, and the settings file rebinds an action with a
//! `bind` line, such as `bind move_left = left, a, pad_dpad_left`. The engine reads the binding
//! names (see src/engine/input/mapping.zig): keys by their enum names, mouse buttons as `mouse_left`,
//! gamepad buttons as `pad_south`, and stick halves as `pad_left_x-`.

const engine = @import("bairava");

/// Everything the player can ask for through input. Add a name here, then give it default bindings in
/// `defaults`. The settings file can bind it with a `bind` line.
pub const Action = enum {
    move_left,
    move_right,
    move_up,
    move_down,
    quit,
    toggle_scale,
    zoom_in,
    zoom_out,
    zoom_reset,
    save_game,
    load_game,
};

/// The bindings each action starts with. An action missing from this table is a compile error.
const defaults = engine.ActionDefaults(Action).init(.{
    .move_left = &.{ .{ .key = .left }, .{ .key = .a } },
    .move_right = &.{ .{ .key = .right }, .{ .key = .d } },
    .move_up = &.{ .{ .key = .up }, .{ .key = .w } },
    .move_down = &.{ .{ .key = .down }, .{ .key = .s } },
    .quit = &.{.{ .key = .escape }},
    .toggle_scale = &.{.{ .key = .i }},
    .zoom_in = &.{ .{ .key = .equal }, .{ .key = .keypad_plus } },
    .zoom_out = &.{ .{ .key = .minus }, .{ .key = .keypad_minus } },
    .zoom_reset = &.{.{ .key = .zero }},
    .save_game = &.{.{ .key = .f5 }},
    .load_game = &.{.{ .key = .f9 }},
});

/// The bindings the game asks through. See `engine.ActionMap`.
pub const Bindings = engine.ActionMap(Action);

/// The game's bindings: the defaults, with the `bind` lines of the settings text applied over them.
pub fn load(settings_text: []const u8) Bindings {
    return engine.bindings.load(Action, defaults, settings_text);
}
