const std = @import("std");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.panic("SDL_Init failed: {s}", .{c.SDL_GetError()});
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("My Game", 800, 600, 0) orelse {
        std.debug.panic("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
    };
    defer c.SDL_DestroyWindow(window);

    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) running = false;
        }
        c.SDL_Delay(16);
    }
}
