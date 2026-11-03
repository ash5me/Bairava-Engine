//! SDL3 2D renderer lifecycle. This backend owns presentation to the window and exposes
//! integer-pixel destinations without leaking SDL types outside platform/sdl.

const std = @import("std");
const c = @import("sdl.zig").c;
const types = @import("../types.zig");
const window_backend = @import("window.zig");

pub const CreateError = error{CreateRendererFailed};

var active: ?*Renderer = null;

pub fn activate(renderer: *Renderer) void {
    active = renderer;
}

pub fn deactivate() void {
    active = null;
}

pub fn createTexture(width: u32, height: u32, pixels: []const u8) ?*c.SDL_Texture {
    const r = active orelse return null;
    const texture = c.SDL_CreateTexture(r.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, @intCast(width), @intCast(height)) orelse return null;
    _ = c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_NEAREST);
    _ = c.SDL_UpdateTexture(texture, null, pixels.ptr, @intCast(width * 4));
    return texture;
}

pub fn destroyTexture(texture: ?*c.SDL_Texture) void {
    if (texture) |value| c.SDL_DestroyTexture(value);
}

pub fn draw(
    texture: *c.SDL_Texture,
    src_x: f32,
    src_y: f32,
    src_w: f32,
    src_h: f32,
    dst_x: f32,
    dst_y: f32,
    dst_w: f32,
    dst_h: f32,
    presentation_x: f32,
    presentation_y: f32,
    scale_x: f32,
    scale_y: f32,
    tint: [3]f32,
    alpha: f32,
    flip_x: bool,
    flip_y: bool,
    origin_x: f32,
    origin_y: f32,
    rotation: f32,
) void {
    const r = active orelse return;
    _ = c.SDL_SetTextureColorMod(texture, @intFromFloat(std.math.clamp(tint[0], 0, 1) * 255), @intFromFloat(std.math.clamp(tint[1], 0, 1) * 255), @intFromFloat(std.math.clamp(tint[2], 0, 1) * 255));
    _ = c.SDL_SetTextureAlphaModFloat(texture, std.math.clamp(alpha, 0, 1));
    _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);

    const src = c.SDL_FRect{ .x = src_x, .y = src_y, .w = src_w, .h = src_h };
    const screen_w = dst_w * scale_x;
    const screen_h = dst_h * scale_y;
    const screen_x = presentation_x + dst_x * scale_x;
    const screen_y = presentation_y + dst_y * scale_y;
    const dst = c.SDL_FRect{ .x = screen_x, .y = screen_y, .w = screen_w, .h = screen_h };
    const center = c.SDL_FPoint{
        .x = screen_w * std.math.clamp(origin_x / @max(dst_w, 1), 0, 1),
        .y = screen_h * std.math.clamp(origin_y / @max(dst_h, 1), 0, 1),
    };
    const flip: c.SDL_FlipMode = if (flip_x)
        c.SDL_FLIP_HORIZONTAL
    else if (flip_y)
        c.SDL_FLIP_VERTICAL
    else
        c.SDL_FLIP_NONE;
    _ = c.SDL_RenderTextureRotated(r.renderer, texture, &src, &dst, rotation * 180.0 / std.math.pi, &center, flip);
}

pub const Renderer = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,

    pub fn init(window: *types.Window) CreateError!Renderer {
        const sdl_window = window_backend.toSdl(window);
        const sdl_renderer = c.SDL_CreateRenderer(sdl_window, null) orelse {
            return error.CreateRendererFailed;
        };
        _ = c.SDL_SetDefaultTextureScaleMode(sdl_renderer, c.SDL_SCALEMODE_NEAREST);
        return .{ .window = sdl_window, .renderer = sdl_renderer };
    }

    pub fn setVsync(self: *Renderer, enabled: bool) void {
        _ = c.SDL_SetRenderVSync(self.renderer, if (enabled) 1 else 0);
    }

    pub fn clear(self: *Renderer, r: u8, g: u8, b: u8, a: u8) void {
        _ = c.SDL_SetRenderDrawColor(self.renderer, r, g, b, a);
        _ = c.SDL_RenderClear(self.renderer);
    }

    pub fn present(self: *Renderer) void {
        _ = c.SDL_RenderPresent(self.renderer);
    }

    pub fn deinit(self: *Renderer) void {
        c.SDL_DestroyRenderer(self.renderer);
        self.* = undefined;
    }
};
