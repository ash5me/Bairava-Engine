//! Named actions and the keys bound to them. Gameplay asks for actions and never for keys, so
//! changing a binding means editing one line in this file.

const engine = @import("../engine/engine.zig");

/// Everything the player can ask for through input. Add a name here, then bind it in `keysFor`.
pub const Action = enum {
    move_left,
    move_right,
    move_up,
    move_down,
    quit,
    toggle_scale,
};

// An action is active when any of its keys is.
const move_left_keys = [_]engine.Key{ .left, .a };
const move_right_keys = [_]engine.Key{ .right, .d };
const move_up_keys = [_]engine.Key{ .up, .w };
const move_down_keys = [_]engine.Key{ .down, .s };
const quit_keys = [_]engine.Key{.escape};
const toggle_scale_keys = [_]engine.Key{.i};

/// The keys bound to an action. The switch has no default, so an action without a binding
/// is a compile error.
pub fn keysFor(action: Action) []const engine.Key {
    return switch (action) {
        .move_left => &move_left_keys,
        .move_right => &move_right_keys,
        .move_up => &move_up_keys,
        .move_down => &move_down_keys,
        .quit => &quit_keys,
        .toggle_scale => &toggle_scale_keys,
    };
}

/// True while any key bound to `action` is held.
pub fn held(input: *const engine.Input, action: Action) bool {
    return input.anyHeld(keysFor(action));
}

/// True during the update step that first sees any key bound to `action` go down.
pub fn pressed(input: *const engine.Input, action: Action) bool {
    return input.anyPressed(keysFor(action));
}

/// True during the update step that first sees any key bound to `action` go up.
pub fn released(input: *const engine.Input, action: Action) bool {
    return input.anyReleased(keysFor(action));
}
