const std = @import("std");
const build_options = @import("build_options");

const c = @import("sdl.zig").c;
const input = @import("input.zig");
const Input = input.Input;
const renderer = @import("renderer.zig");
const Vertex = renderer.Vertex;
const Renderer = renderer.Renderer;

const triangle = [_]Vertex{
    .{ .pos = .{ 0.0, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
};

/// Caps the frame time so a stall (dragging the window, hitting a breakpoint)
/// doesn't make the next frame jump far ahead.
const max_dt: f32 = 0.1;
/// How fast the background color channels change, in units per second.
const color_speed: f32 = 0.5;
/// How often the window title is refreshed, in seconds.
const title_interval: f32 = 0.5;

pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.panic("SDL_Init failed: {s}", .{c.SDL_GetError()});
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("My Game", 800, 600, c.SDL_WINDOW_RESIZABLE) orelse {
        std.debug.panic("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
    };
    defer c.SDL_DestroyWindow(window);

    var gpu = Renderer.init(window, build_options.gpu_debug, &triangle);
    defer gpu.deinit();

    var input_state = Input.init();

    const default_clear = c.SDL_FColor{ .r = 0.2, .g = 0.3, .b = 0.5, .a = 1.0 };
    var clear = default_clear;

    var last_ns = c.SDL_GetTicksNS();
    var title_timer: f32 = 0;
    var frames: u32 = 0;
    var title_buf: [128:0]u8 = undefined;

    var running = true;
    while (running) {
        // Frame timing: seconds since the last frame, capped at max_dt.
        const now_ns = c.SDL_GetTicksNS();
        const dt = @min(@as(f32, @floatFromInt(now_ns - last_ns)) / 1_000_000_000.0, max_dt);
        last_ns = now_ns;

        // Events: quit requests, mouse motion, and mouse clicks.
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) running = false;
            input_state.handleEvent(&event);
        }

        // Held keys: arrows change red and green, W and S change blue, Escape quits.
        if (input_state.held(c.SDL_SCANCODE_ESCAPE)) running = false;
        const step = color_speed * dt;
        if (input_state.held(c.SDL_SCANCODE_RIGHT)) clear.r = @min(clear.r + step, 1.0);
        if (input_state.held(c.SDL_SCANCODE_LEFT)) clear.r = @max(clear.r - step, 0.0);
        if (input_state.held(c.SDL_SCANCODE_UP)) clear.g = @min(clear.g + step, 1.0);
        if (input_state.held(c.SDL_SCANCODE_DOWN)) clear.g = @max(clear.g - step, 0.0);
        if (input_state.held(c.SDL_SCANCODE_W)) clear.b = @min(clear.b + step, 1.0);
        if (input_state.held(c.SDL_SCANCODE_S)) clear.b = @max(clear.b - step, 0.0);

        // A left click resets the background.
        if (input_state.left_clicked) clear = default_clear;
        input_state.endFrame();

        gpu.draw(clear);

        // Window title: FPS and mouse position, refreshed a few times a second.
        frames += 1;
        title_timer += dt;
        if (title_timer >= title_interval) {
            const fps = @as(f32, @floatFromInt(frames)) / title_timer;
            const title = std.fmt.bufPrintZ(&title_buf, "My Game | {d:.0} fps | mouse {d:.0}, {d:.0}", .{
                fps, input_state.mouse_x, input_state.mouse_y,
            }) catch null;
            if (title) |t| _ = c.SDL_SetWindowTitle(window, t.ptr);
            frames = 0;
            title_timer = 0;
        }
    }
}
