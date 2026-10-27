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

const tile_px: f32 = 16.0;

const window_w = 800;
const window_h = 600;

/// The world is laid out in these native pixels, then scaled up to the window.
const native_w: u32 = 320;
const native_h: u32 = 180;
const native_wf: f32 = @floatFromInt(native_w);
const native_hf: f32 = @floatFromInt(native_h);

/// Gap between tiles, in native pixels.
const tile_gap: f32 = 2.0;

const white = [3]f32{ 1.0, 1.0, 1.0 };
/// Color behind the scaled world, visible when the window isn't an exact multiple of the native size.
const letterbox = c.SDL_FColor{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

/// Caps the frame time so a stall (dragging the window, hitting a breakpoint)
/// doesn't make the next frame jump far ahead.
const max_dt: f32 = 0.1;
/// How fast the background color channels change, in units per second.
const color_speed: f32 = 0.5;
/// How often the window title is refreshed, in seconds.
const title_interval: f32 = 0.5;

/// The largest whole-number scale at which the native frame fits in the window, and at least 1.
/// The scale at which the native frame fits the window, as a fraction.
/// 3.0 means 300%: three screen pixels for each native pixel.
fn fitScale(win_w: f32, win_h: f32) f32 {
    return @min(win_w / native_wf, win_h / native_hf);
}

/// Fills the native frame with fixed-size tiles, centered.
/// Each tile is the top-left tile_px x tile_px cell of the image.
fn drawTileGrid(batch: *SpriteBatch, tile: *const Texture, elapsed: f32) void {
    const step = tile_px + tile_gap;

    const cols: u32 = @intFromFloat(@floor((native_wf + tile_gap) / step));
    const rows: u32 = @intFromFloat(@floor((native_hf + tile_gap) / step));
    const grid_w = @as(f32, @floatFromInt(cols)) * step - tile_gap;
    const grid_h = @as(f32, @floatFromInt(rows)) * step - tile_gap;
    const origin_x = @floor((native_wf - grid_w) / 2.0);
    const origin_y = @floor((native_hf - grid_h) / 2.0);

    const src = Rect{ .x = 0, .y = 0, .w = tile_px, .h = tile_px };

    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            const dst = Rect{
                .x = origin_x + @as(f32, @floatFromInt(col)) * step,
                .y = origin_y + @as(f32, @floatFromInt(row)) * step,
                .w = tile_px,
                .h = tile_px,
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

    const format = gpu.swapchainFormat();

    var img = image.loadRgba8("assets/tile.png") catch |err| {
        std.debug.panic("failed to load assets/tile.png: {s}", .{@errorName(err)});
    };
    defer img.deinit();

    var tile = Texture.initRgba8(gpu.device, img.width, img.height, img.pixels);
    defer tile.deinit();

    // The world is drawn here at native resolution, then scaled to the window.
    var target = Texture.initTarget(gpu.device, native_w, native_h, format);
    defer target.deinit();

    // Two batches: one for the world, one for the final scaled image.
    var world = SpriteBatch.init(gpu.device, format);
    defer world.deinit();
    var screen = SpriteBatch.init(gpu.device, format);
    defer screen.deinit();

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

        // Acquire the frame first, so the swapchain size is known before anything is laid out.
        const frame = gpu.beginFrame() orelse continue;

        // Pass 1: draw the world at native resolution into the target.
        world.begin(native_wf, native_hf);
        drawTileGrid(&world, &tile, elapsed);
        world.upload(frame.cmd);
        const world_pass = Renderer.beginPass(frame.cmd, target.texture, clear);
        world.draw(world_pass);
        Renderer.endPass(world_pass);

        // Pass 2: scale the target to fit the window and center it. The scale is fractional,
        // so the image grows and shrinks smoothly with the window.
        const win_wf: f32 = @floatFromInt(frame.width);
        const win_hf: f32 = @floatFromInt(frame.height);
        const scale = fitScale(win_wf, win_hf);
        const scaled_w = native_wf * scale;
        const scaled_h = native_hf * scale;
        const dst = Rect{
            .x = (win_wf - scaled_w) / 2.0,
            .y = (win_hf - scaled_h) / 2.0,
            .w = scaled_w,
            .h = scaled_h,
        };
        const full = Rect{ .x = 0, .y = 0, .w = native_wf, .h = native_hf };

        screen.begin(win_wf, win_hf);
        screen.drawSprite(&target, full, dst, white);
        screen.upload(frame.cmd);
        const screen_pass = Renderer.beginPass(frame.cmd, frame.swapchain, letterbox);
        screen.draw(screen_pass);
        Renderer.endPass(screen_pass);

        Renderer.endFrame(frame);

        // Window title: FPS, sprite count, draw calls, and scale, refreshed a few times a second.
        frames += 1;
        title_timer += dt;
        if (title_timer >= title_interval) {
            const fps = @as(f32, @floatFromInt(frames)) / title_timer;
            const title = std.fmt.bufPrintZ(&title_buf, "My Game | {d:.0} fps | {d} sprites | {d} draw calls | {d:.0}%", .{
                fps, world.sprite_count, world.draw_calls + screen.draw_calls, scale * 100.0,
            }) catch null;
            if (title) |t| _ = c.SDL_SetWindowTitle(window, t.ptr);
            frames = 0;
            title_timer = 0;
        }
    }
}
