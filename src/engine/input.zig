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
    i,
};

/// Number of keys in `Key`. Per-key arrays are indexed by `@intFromEnum(key)`.
const key_count = std.enums.values(Key).len;

/// Input state. Held keys are read from SDL's keyboard state when asked. Presses, releases, and
/// clicks come from the event queue. They gather as events arrive, and `latch` hands them to the
/// game one update step at a time.
pub const Input = struct {
    keys: [*c]const bool,
    /// Events gathered since the last `latch`.
    pending_pressed: [key_count]bool = [_]bool{false} ** key_count,
    pending_released: [key_count]bool = [_]bool{false} ** key_count,
    pending_left_click: bool = false,
    /// Events handed to the game by the latest `latch`. These are what the query methods report.
    pressed: [key_count]bool = [_]bool{false} ** key_count,
    released: [key_count]bool = [_]bool{false} ** key_count,
    left_clicked: bool = false,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,

    pub fn init() Input {
        // SDL owns this array, and it stays valid for the life of the app.
        return .{ .keys = c.SDL_GetKeyboardState(null) };
    }

    /// Hands the events gathered since the last call to the game, and starts gathering afresh.
    /// The engine calls this before each update step, so each press or click reaches exactly one update.
    pub fn latch(self: *Input) void {
        self.pressed = self.pending_pressed;
        self.released = self.pending_released;
        self.left_clicked = self.pending_left_click;
        @memset(&self.pending_pressed, false);
        @memset(&self.pending_released, false);
        self.pending_left_click = false;
    }

    /// True while the key is held down, as of the latest event pump.
    pub fn held(self: *const Input, key: Key) bool {
        return self.keys[@intCast(scancode(key))];
    }

    /// True during the update step that first sees the key go down.
    pub fn wasPressed(self: *const Input, key: Key) bool {
        return self.pressed[@intFromEnum(key)];
    }

    /// True during the update step that first sees the key go up.
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

    /// True during the update step that first sees any of `keys` go down.
    pub fn anyPressed(self: *const Input, keys: []const Key) bool {
        for (keys) |key| {
            if (self.wasPressed(key)) return true;
        }
        return false;
    }

    /// True during the update step that first sees any of `keys` go up.
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
                    if (keyFromScancode(event.key.scancode)) |key| self.pending_pressed[@intFromEnum(key)] = true;
                }
            },
            c.SDL_EVENT_KEY_UP => {
                if (keyFromScancode(event.key.scancode)) |key| self.pending_released[@intFromEnum(key)] = true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                self.mouse_x = event.motion.x;
                self.mouse_y = event.motion.y;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (event.button.button == c.SDL_BUTTON_LEFT) self.pending_left_click = true;
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
        .i => c.SDL_SCANCODE_I,
    };
}

/// The key for an SDL scancode, or null if the engine doesn't name that key.
fn keyFromScancode(code: c.SDL_Scancode) ?Key {
    for (std.enums.values(Key)) |key| {
        if (scancode(key) == code) return key;
    }
    return null;
}
