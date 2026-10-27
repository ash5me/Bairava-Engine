const std = @import("std");
const build_options = @import("build_options");

const c = @import("sdl.zig").c;
const image = @import("image.zig");
const input = @import("input.zig");
const Input = input.Input;
const renderer = @import("renderer.zig");
const Renderer = renderer.Renderer;
const sprite = @import("sprite.zig");
const SpriteBatch = sprite.SpriteBatch;
const Rect = sprite.Rect;
const Texture = @import("texture.zig").Texture;

const window_w = 800;
const window_h = 600;

/// On-screen size of each tile, in pixels.
const tile_size: f32 = 32.0;
/// Space between tiles, in pixels.
const tile_gap: f32 = 4.0;
const grid_cols: u32 = 20;
const grid_rows: u32 = 12;

/// Caps the frame time so a stall (dragging the window, hitting a breakpoint)
/// doesn't make the next frame jump far ahead.
const max_dt: f32 = 0.1;
/// How fast the background color channels change, in units per second.
const color_speed: f32 = 0.5;
/// How often the window title is refreshed, in seconds.
const title_interval: f32 = 0.5;

/// Queues a centered grid of tiles, all using one texture.
/// Each tile's tint pulses on its own phase, so the batch carries varied vertex colors.
fn drawTileGrid(batch: *SpriteBatch, tile: *const Texture, elapsed: f32, view_w: f32, view_h: f32) void {
    const spacing = tile_size + tile_gap;
    const grid_w = @as(f32, @floatFromInt(grid_cols)) * spacing - tile_gap;
    const grid_h = @as(f32, @floatFromInt(grid_rows)) * spacing - tile_gap;
    const origin_x = (view_w - grid_w) / 2.0;
    const origin_y = (view_h - grid_h) / 2.0;

    const src = Rect{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(tile.width),
        .h = @floatFromInt(tile.height),
    };

    var row: u32 = 0;
    while (row < grid_rows) : (row += 1) {
        var col: u32 = 0;
        while (col < grid_cols) : (col += 1) {
            const dst = Rect{
                .x = origin_x + @as(f32, @floatFromInt(col)) * spacing,
                .y = origin_y + @as(f32, @floatFromInt(row)) * spacing,
                .w = tile_size,
                .h = tile_size,
            };
            const phase = @as(f32, @floatFromInt(col + row)) * 0.4;
            const pulse = 0.5 + 0.5 * @sin(elapsed * 2.0 + phase);
            batch.drawSprite(tile, src, dst, .{ 1.0, 0.6 + 0.4 * pulse, 1.0 });
        }
    }
}

pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.panic("SDL_Init failed: {s}", .{c.SDL_GetError()});
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("My Game", window_w, window_h, c.SDL_WINDOW_RESIZABLE) orelse {
        std.debug.panic("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
    };
    defer c.SDL_DestroyWindow(window);

    var gpu = Renderer.init(window, build_options.gpu_debug);
    defer gpu.deinit();

    var img = image.loadRgba8("assets/tile.png") catch |err| {
        std.debug.panic("failed to load assets/tile.png: {s}", .{@errorName(err)});
    };
    defer img.deinit();

    var tile = Texture.initRgba8(gpu.device, img.width, img.height, img.pixels);
    defer tile.deinit();

    var batch = SpriteBatch.init(gpu.device, gpu.swapchainFormat());
    defer batch.deinit();

    var input_state = Input.init();

    const default_clear = c.SDL_FColor{ .r = 0.2, .g = 0.3, .b = 0.5, .a = 1.0 };
    var clear = default_clear;

    var last_ns = c.SDL_GetTicksNS();
    var elapsed: f32 = 0;
    var title_timer: f32 = 0;
    var frames: u32 = 0;
    var title_buf: [128:0]u8 = undefined;

    var running = true;
    while (running) {
        // Frame timing: seconds since the last frame, capped at max_dt.
        const now_ns = c.SDL_GetTicksNS();
        const dt = @min(@as(f32, @floatFromInt(now_ns - last_ns)) / 1_000_000_000.0, max_dt);
        last_ns = now_ns;
        elapsed += dt;

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

        // Build this frame's sprites on the CPU. Nothing touches the GPU here.
        var win_w: c_int = 0;
        var win_h: c_int = 0;
        _ = c.SDL_GetWindowSize(window, &win_w, &win_h);
        const view_w: f32 = @floatFromInt(win_w);
        const view_h: f32 = @floatFromInt(win_h);
        batch.begin(view_w, view_h);
        drawTileGrid(&batch, &tile, elapsed, view_w, view_h);

        // GPU work: upload the sprite vertices, then draw them inside one render pass.
        const frame = gpu.beginFrame() orelse continue;
        batch.upload(frame.cmd);
        const pass = Renderer.beginPass(frame, clear);
        batch.draw(pass);
        Renderer.endPass(pass);
        Renderer.endFrame(frame);

        // Window title: FPS, sprite count, and draw calls, refreshed a few times a second.
        frames += 1;
        title_timer += dt;
        if (title_timer >= title_interval) {
            const fps = @as(f32, @floatFromInt(frames)) / title_timer;
            const title = std.fmt.bufPrintZ(&title_buf, "My Game | {d:.0} fps | {d} sprites | {d} draw calls", .{
                fps, batch.sprite_count, batch.draw_calls,
            }) catch null;
            if (title) |t| _ = c.SDL_SetWindowTitle(window, t.ptr);
            frames = 0;
            title_timer = 0;
        }
    }
}
