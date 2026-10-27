const c = @import("sdl.zig").c;

/// Input for one frame. Held keys are polled from SDL's keyboard state,
/// and mouse movement and clicks are collected from the event queue.
pub const Input = struct {
    keys: [*c]const bool,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    left_clicked: bool = false,

    pub fn init() Input {
        // SDL owns this array, and it stays valid for the life of the app.
        return .{ .keys = c.SDL_GetKeyboardState(null) };
    }

    /// True while the key is held down, as of the latest event pump.
    pub fn held(self: *const Input, scancode: c.SDL_Scancode) bool {
        return self.keys[@intCast(scancode)];
    }

    /// Feeds one event from SDL_PollEvent into the input state.
    pub fn handleEvent(self: *Input, event: *const c.SDL_Event) void {
        switch (event.type) {
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

    /// Clears one-shot events. Call once per frame, after reading them.
    pub fn endFrame(self: *Input) void {
        self.left_clicked = false;
    }
};
