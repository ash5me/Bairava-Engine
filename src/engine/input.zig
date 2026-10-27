const std = @import("std");
const c = @import("sdl.zig").c;

/// Keys the engine can report. To add one, add it here and map it to its SDL scancode in `scancode`.
pub const Key = enum {
    escape,
    left,
    right,
    up,
    down,
    w,
    a,
    s,
    d,
};

/// Number of keys in `Key`. Per-key arrays are indexed by `@intFromEnum(key)`.
const key_count = std.enums.values(Key).len;

/// Input state. Held keys are polled from SDL's keyboard state. Presses, releases, and mouse
/// clicks come from the event queue, and they last until `beginFrame` clears them.
pub const Input = struct {
    keys: [*c]const bool,
    /// Keys that went down this frame. Key repeats don't count.
    pressed: [key_count]bool = [_]bool{false} ** key_count,
    /// Keys that went up this frame.
    released: [key_count]bool = [_]bool{false} ** key_count,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    left_clicked: bool = false,

    pub fn init() Input {
        // SDL owns this array, and it stays valid for the life of the app.
        return .{ .keys = c.SDL_GetKeyboardState(null) };
    }

    /// Clears the one-shot state from the previous frame. Call once per frame, before pumping events,
    /// so that everything collected this frame is still available to the game's update.
    pub fn beginFrame(self: *Input) void {
        @memset(&self.pressed, false);
        @memset(&self.released, false);
        self.left_clicked = false;
    }

    /// True while the key is held down, as of the latest event pump.
    pub fn held(self: *const Input, key: Key) bool {
        return self.keys[@intCast(scancode(key))];
    }

    /// True on the frame the key went down.
    pub fn wasPressed(self: *const Input, key: Key) bool {
        return self.pressed[@intFromEnum(key)];
    }

    /// True on the frame the key went up.
    pub fn wasReleased(self: *const Input, key: Key) bool {
        return self.released[@intFromEnum(key)];
    }

    /// True while any of `keys` is held.
    pub fn anyHeld(self: *const Input, keys: []const Key) bool {
        for (keys) |key| {
            if (self.held(key)) return true;
        }
        return false;
    }

    /// True on the frame any of `keys` went down.
    pub fn anyPressed(self: *const Input, keys: []const Key) bool {
        for (keys) |key| {
            if (self.wasPressed(key)) return true;
        }
        return false;
    }

    /// True on the frame any of `keys` went up.
    pub fn anyReleased(self: *const Input, keys: []const Key) bool {
        for (keys) |key| {
            if (self.wasReleased(key)) return true;
        }
        return false;
    }

    /// Feeds one event from SDL_PollEvent into the input state.
    pub fn handleEvent(self: *Input, event: *const c.SDL_Event) void {
        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                if (!event.key.repeat) {
                    if (keyFromScancode(event.key.scancode)) |key| self.pressed[@intFromEnum(key)] = true;
                }
            },
            c.SDL_EVENT_KEY_UP => {
                if (keyFromScancode(event.key.scancode)) |key| self.released[@intFromEnum(key)] = true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                self.mouse_x = event.motion.x;
                self.mouse_y = event.motion.y;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (event.button.button == c.SDL_BUTTON_LEFT) self.left_clicked = true;
            },
            else => {},
        }
    }
};

/// Maps a key to its SDL scancode. This is the only place that names SDL keys.
fn scancode(key: Key) c.SDL_Scancode {
    return switch (key) {
        .escape => c.SDL_SCANCODE_ESCAPE,
        .left => c.SDL_SCANCODE_LEFT,
        .right => c.SDL_SCANCODE_RIGHT,
        .up => c.SDL_SCANCODE_UP,
        .down => c.SDL_SCANCODE_DOWN,
        .w => c.SDL_SCANCODE_W,
        .a => c.SDL_SCANCODE_A,
        .s => c.SDL_SCANCODE_S,
        .d => c.SDL_SCANCODE_D,
    };
}

/// The key for an SDL scancode, or null if the engine doesn't name that key.
fn keyFromScancode(code: c.SDL_Scancode) ?Key {
    for (std.enums.values(Key)) |key| {
        if (scancode(key) == code) return key;
    }
    return null;
}
