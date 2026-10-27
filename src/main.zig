const std = @import("std");
const build_options = @import("build_options");

const c = @import("sdl.zig").c;
const camera_mod = @import("camera.zig");
const Camera = camera_mod.Camera;
const image = @import("image.zig");
const input = @import("input.zig");
const Input = input.Input;
const renderer = @import("renderer.zig");
const Renderer = renderer.Renderer;
const sprite = @import("sprite.zig");
const SpriteBatch = sprite.SpriteBatch;
const Rect = sprite.Rect;
const Texture = @import("texture.zig").Texture;
const world_mod = @import("world.zig");
const World = world_mod.World;
const tile_px = world_mod.tile_px;

const window_w = 960;
const window_h = 540;

/// The smallest view the game is designed for, in native pixels. Bigger windows show more
/// of the world instead of adding bars.
const native_w: u32 = 320;
const native_h: u32 = 180;
const native_wf: f32 = @floatFromInt(native_w);
const native_hf: f32 = @floatFromInt(native_h);

/// The test map: 40 x 24 tiles, which is 640 x 384 native pixels.
const level = World{ .cols = 40, .rows = 24 };

/// Player speed, in native pixels per second.
const player_speed: f32 = 80.0;

const white = [3]f32{ 1.0, 1.0, 1.0 };
const clear = c.SDL_FColor{ .r = 0.2, .g = 0.3, .b = 0.5, .a = 1.0 };
const black = c.SDL_FColor{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

/// Caps the frame time so a stall (dragging the window, hitting a breakpoint)
/// doesn't make the next frame jump far ahead.
const max_dt: f32 = 0.1;
/// How often the window title is refreshed, in seconds.
const title_interval: f32 = 0.5;

/// The scale at which the smallest native view fits the window, as a fraction.
/// The window is filled on one axis, and the view grows on the other axis.
fn fitScale(win_w: f32, win_h: f32) f32 {
    return @min(win_w / native_wf, win_h / native_hf);
}

/// Draws the player at whole native pixels so its edges stay sharp.
fn drawPlayer(batch: *SpriteBatch, tile: *const Texture, x: f32, y: f32, cam: *const Camera) void {
    const src = Rect{ .x = 0, .y = 0, .w = tile_px, .h = tile_px };
    const dst = Rect{ .x = @round(x) - cam.x, .y = @round(y) - cam.y, .w = tile_px, .h = tile_px };
    batch.drawSprite(tile, src, dst, .{ 1.0, 0.45, 0.45 });
}

pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.panic("SDL_Init failed: {s}", .{c.SDL_GetError()});
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("My Game", window_w, window_h, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse {
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

    // The world is drawn into this target at the view's native size, then stretched to the window.
    // It's rebuilt whenever the view size changes.
    var target = Texture.initTarget(gpu.device, native_w, native_h, format);
    defer target.deinit();

    var world_batch = SpriteBatch.init(gpu.device, format);
    defer world_batch.deinit();
    var screen_batch = SpriteBatch.init(gpu.device, format);
    defer screen_batch.deinit();

    var input_state = Input.init();

    var cam = Camera{
        .view_w = native_wf,
        .view_h = native_hf,
        .world_w = level.widthPx(),
        .world_h = level.heightPx(),
    };

    // The player starts in the middle of the map.
    var player_x = (level.widthPx() - tile_px) / 2.0;
    var player_y = (level.heightPx() - tile_px) / 2.0;

    var last_ns = c.SDL_GetTicksNS();
    var title_timer: f32 = 0;
    var frames: u32 = 0;
    var title_buf: [160:0]u8 = undefined;

    var running = true;
    while (running) {
        // Frame timing: seconds since the last frame, capped at max_dt.
        const now_ns = c.SDL_GetTicksNS();
        const dt = @min(@as(f32, @floatFromInt(now_ns - last_ns)) / 1_000_000_000.0, max_dt);
        last_ns = now_ns;

        // Events: quit requests, F11 fullscreen, and mouse state.
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) running = false;
            if (event.type == c.SDL_EVENT_KEY_DOWN and event.key.key == c.SDLK_F11 and !event.key.repeat) {
                const fullscreen = (c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_FULLSCREEN) != 0;
                _ = c.SDL_SetWindowFullscreen(window, !fullscreen);
            }
            input_state.handleEvent(&event);
        }
        input_state.endFrame();

        // Escape quits.
        if (input_state.held(c.SDL_SCANCODE_ESCAPE)) running = false;

        // Movement: arrow keys or WASD. Diagonal input is normalized so it isn't faster.
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (input_state.held(c.SDL_SCANCODE_LEFT) or input_state.held(c.SDL_SCANCODE_A)) dx -= 1;
        if (input_state.held(c.SDL_SCANCODE_RIGHT) or input_state.held(c.SDL_SCANCODE_D)) dx += 1;
        if (input_state.held(c.SDL_SCANCODE_UP) or input_state.held(c.SDL_SCANCODE_W)) dy -= 1;
        if (input_state.held(c.SDL_SCANCODE_DOWN) or input_state.held(c.SDL_SCANCODE_S)) dy += 1;
        if (dx != 0 and dy != 0) {
            const diagonal = 1.0 / @sqrt(2.0);
            dx *= diagonal;
            dy *= diagonal;
        }

        // Keep the player inside the map.
        player_x = std.math.clamp(player_x + dx * player_speed * dt, 0.0, level.widthPx() - tile_px);
        player_y = std.math.clamp(player_y + dy * player_speed * dt, 0.0, level.heightPx() - tile_px);

        // Window size in pixels, which is also the swapchain size on high-DPI displays.
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(window, &pw, &ph);
        if (pw <= 0 or ph <= 0) continue;
        const win_wf: f32 = @floatFromInt(pw);
        const win_hf: f32 = @floatFromInt(ph);

        // The view is the part of the world the window shows. The 0.01 keeps float rounding
        // from dropping a whole native pixel.
        const scale = fitScale(win_wf, win_hf);
        const view_w: u32 = @intFromFloat(@floor(win_wf / scale + 0.01));
        const view_h: u32 = @intFromFloat(@floor(win_hf / scale + 0.01));
        const view_wf: f32 = @floatFromInt(view_w);
        const view_hf: f32 = @floatFromInt(view_h);

        if (target.width != view_w or target.height != view_h) {
            // Wait first, because the old target may still be in use by the GPU.
            _ = c.SDL_WaitForGPUIdle(gpu.device);
            target.deinit();
            target = Texture.initTarget(gpu.device, view_w, view_h, format);
        }

        // Point the camera at the player's center, using the current view size.
        cam.view_w = view_wf;
        cam.view_h = view_hf;
        cam.follow(player_x + tile_px / 2.0, player_y + tile_px / 2.0);

        // Acquire the frame after the layout is known.
        const frame = gpu.beginFrame() orelse continue;

        // Pass 1: draw the visible world and the player into the view-sized target.
        world_batch.begin(view_wf, view_hf);
        level.draw(&world_batch, &tile, &cam);
        drawPlayer(&world_batch, &tile, player_x, player_y, &cam);
        world_batch.upload(frame.cmd);
        const world_pass = Renderer.beginPass(frame.cmd, target.texture, clear);
        world_batch.draw(world_pass);
        Renderer.endPass(world_pass);

        // Pass 2: stretch the target over the whole window. The stretch is less than one
        // native pixel across the view, which isn't visible, and there are no bars.
        const window_rect = Rect{ .x = 0, .y = 0, .w = win_wf, .h = win_hf };
        const view_rect = Rect{ .x = 0, .y = 0, .w = view_wf, .h = view_hf };
        screen_batch.begin(win_wf, win_hf);
        screen_batch.drawSprite(&target, view_rect, window_rect, white);
        screen_batch.upload(frame.cmd);
        const screen_pass = Renderer.beginPass(frame.cmd, frame.swapchain, black);
        screen_batch.draw(screen_pass);
        Renderer.endPass(screen_pass);

        Renderer.endFrame(frame);

        // Window title: FPS, sprite count, draw calls, scale, and view size, refreshed a few times a second.
        frames += 1;
        title_timer += dt;
        if (title_timer >= title_interval) {
            const fps = @as(f32, @floatFromInt(frames)) / title_timer;
            const title = std.fmt.bufPrintZ(&title_buf, "My Game | {d:.0} fps | {d} sprites | {d} draw calls | {d:.0}% | view {d}x{d}", .{
                fps, world_batch.sprite_count, world_batch.draw_calls + screen_batch.draw_calls, scale * 100.0, view_w, view_h,
            }) catch null;
            if (title) |t| _ = c.SDL_SetWindowTitle(window, t.ptr);
            frames = 0;
            title_timer = 0;
        }
    }
}
