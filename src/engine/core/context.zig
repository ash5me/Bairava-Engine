//! What the game sees while it runs. `Context` is passed to `init` and `update`, and it loads
//! assets relative to the folder of the executable. `DrawContext` is passed to `draw`.

const std = @import("std");
const c = @import("../platform/sdl/sdl.zig").c;
const audio = @import("../audio/audio.zig");
const image = @import("../assets/loaders/image.zig");
const atlas = @import("../assets/loaders/atlas.zig");
const logging = @import("../logging/log.zig");
const profile = @import("../profiling/profile.zig");
const ui = @import("../ui/ui.zig");
const view = @import("../renderer/view.zig");
const Camera = @import("../renderer/camera.zig").Camera;
const LoadedAtlas = @import("../renderer/loaded_atlas.zig").LoadedAtlas;
const SpriteBatch = @import("../renderer/sprite.zig").SpriteBatch;
const Texture = @import("../renderer/texture.zig").Texture;
const Input = @import("../input/input.zig").Input;

const ScaleMode = view.ScaleMode;
const elog = logging.scoped("engine");

/// Longest full asset path the loader builds, in bytes. A longer path panics with a clear message.
pub const max_full_path = 1024;

/// State the game reads and writes during `update`, plus the GPU access it needs in `init`.
pub const Context = struct {
    device: *c.SDL_GPUDevice,
    /// Held keys, presses, releases, and clicks for this update step.
    input: *const Input,
    /// Length of one update step in seconds. This is always the fixed step.
    dt: f32 = 0,
    /// Set to false to end the main loop.
    running: bool = true,
    /// How the native view is fitted to the window. The game may change this at any time.
    scale_mode: ScaleMode = .fit,
    /// The zoom the game is aiming for, where 1 is the normal view. The camera eases toward it each
    /// frame. Change it with `zoomBy` or `resetZoom`, which keep it within the bounds.
    zoom_target: f32 = 1.0,
    /// The zoom bounds from Config. `zoomBy` keeps `zoom_target` between them.
    zoom_min: f32,
    zoom_max: f32,
    /// Where the native view was drawn in the window, from the last frame. Mouse positions are
    /// mapped through this, so they match what the player saw.
    layout: view.Layout,
    /// The camera as the game last drew with it. Read it through `mouseWorld`.
    camera: *const Camera,
    /// Directory of the running executable, with a trailing separator. Asset paths are resolved
    /// against it, because the build installs assets beside the executable.
    base_path: []const u8,
    /// Sound output. Load sounds with `loadSound` and play them through this. It stays silent when
    /// no playback device could be opened.
    audio: *audio.Audio,
    /// Text of the settings file, read at startup. Empty when there is no file. The game reads its
    /// key bindings from it in `init`.
    settings_text: []const u8 = "",

    /// The mouse position in world pixels, as the player sees it. It is the cursor's place in the
    /// view drawn last frame, plus that frame's camera position. Use this in `update` rather than
    /// `input.mouse_x`, which is in window points.
    pub fn mouseWorld(self: *const Context) view.Point {
        return view.windowToWorld(self.layout, self.camera, .{ .x = self.input.mouse_x, .y = self.input.mouse_y });
    }

    /// Multiplies the zoom target by `factor`, within the zoom bounds. Use a factor above 1 to zoom
    /// in and one below 1 to zoom out. The camera eases to the new zoom over the next frames.
    pub fn zoomBy(self: *Context, factor: f32) void {
        self.zoom_target = Camera.zoomTarget(self.zoom_target, factor, self.zoom_min, self.zoom_max);
    }

    /// Aims the zoom back at the normal view.
    pub fn resetZoom(self: *Context) void {
        self.zoom_target = 1.0;
    }

    /// Loads an image and uploads it as a texture. `relative` is relative to the executable's
    /// folder, where the build installs the assets. Panics if the file is missing or can't be decoded.
    pub fn loadTexture(self: *const Context, relative: []const u8) Texture {
        const zone = profile.zoneNamed(@src(), "load texture");
        defer zone.End();
        if (loadCompressedVariant(self, relative, ".astc", .astc_4x4, c.SDL_GPU_TEXTUREFORMAT_ASTC_4x4_UNORM)) |texture| return texture;
        if (loadCompressedVariant(self, relative, ".bc3", .bc3, c.SDL_GPU_TEXTUREFORMAT_BC3_RGBA_UNORM)) |texture| return texture;
        if (loadCompressedVariant(self, relative, ".bc1", .bc1, c.SDL_GPU_TEXTUREFORMAT_BC1_RGBA_UNORM)) |texture| return texture;
        if (loadCompressedVariant(self, relative, ".rgba", .rgba8, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM)) |texture| return texture;
        var buf: [max_full_path]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ self.base_path, relative }) catch {
            std.debug.panic("asset path '{s}' is longer than {d} bytes", .{ relative, max_full_path });
        };
        var img = image.loadRgba8(path.ptr) catch |err| {
            std.debug.panic("failed to load {s}: {s}", .{ path, @errorName(err) });
        };
        defer img.deinit();
        elog.debug("loaded texture {s} ({d}x{d})", .{ path, img.width, img.height });
        return Texture.initRgba8(self.device, img.width, img.height, img.pixels);
    }

    /// Loads a WAV file and converts it to the device's format. `relative` is relative to the
    /// executable's folder, like `loadTexture`. It returns an error instead of panicking, because a
    /// missing sound shouldn't stop the game. The caller frees the sound with `Sound.deinit`.
    pub fn loadSound(self: *const Context, relative: []const u8) audio.Error!audio.Sound {
        var buf: [max_full_path]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ self.base_path, relative }) catch return error.LoadFailed;
        return self.audio.loadSound(path);
    }

    /// Reads a whole file. `relative` is relative to the executable's folder, like `loadTexture`.
    /// The caller owns the result and frees it with `std.heap.page_allocator`.
    pub fn readFile(self: *const Context, relative: []const u8) ![]u8 {
        var buf: [max_full_path]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ self.base_path, relative }) catch return error.PathTooLong;
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse return error.FileNotFound;
        defer c.SDL_free(data);
        const bytes: [*]const u8 = @ptrCast(data);
        return std.heap.page_allocator.dupe(u8, bytes[0..size]);
    }

    /// Writes a whole file, replacing any old one. `relative` is relative to the executable's folder,
    /// like `readFile`. On failure it logs SDL's reason and returns an error.
    pub fn writeFile(self: *const Context, relative: []const u8, bytes: []const u8) !void {
        var buf: [max_full_path]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ self.base_path, relative }) catch {
            elog.err("path for '{s}' is longer than {d} bytes", .{ relative, max_full_path });
            return error.PathTooLong;
        };
        if (!c.SDL_SaveFile(path.ptr, bytes.ptr, bytes.len)) {
            elog.err("could not write '{s}': {s}", .{ relative, c.SDL_GetError() });
            return error.WriteFailed;
        }
    }

    /// Loads a UI font from the TTF at `relative`. It uses the build-preprocessed `<relative>.bfnt`
    /// when that exists and matches `pixel_height`. Panics when neither file can be read, because a
    /// missing font means a broken build.
    pub fn loadFont(self: *const Context, relative: []const u8, pixel_height: f32) ui.Font {
        var prebaked_buf: [max_full_path]u8 = undefined;
        const prebaked_path = std.fmt.bufPrint(&prebaked_buf, "{s}.bfnt", .{relative}) catch {
            std.debug.panic("font path '{s}' is longer than {d} bytes", .{ relative, max_full_path });
        };
        const prebaked = self.readFile(prebaked_path) catch null;
        defer if (prebaked) |bytes| std.heap.page_allocator.free(bytes);
        const ttf_file = self.readFile(relative) catch null;
        defer if (ttf_file) |bytes| std.heap.page_allocator.free(bytes);
        if (prebaked == null and ttf_file == null) {
            std.debug.panic("font '{s}' and its preprocessed asset could not be read", .{relative});
        }
        const ttf: []const u8 = ttf_file orelse &.{};
        const pre: []const u8 = prebaked orelse &.{};
        return ui.Font.load(self.device, ttf, pre, pixel_height) catch |err| {
            std.debug.panic("font '{s}' could not be baked: {s}", .{ relative, @errorName(err) });
        };
    }

    /// Loads a texture atlas: the image at `image_path` and its index at `index_path`, both relative
    /// to the executable's folder. Panics when the index can't be read or parsed, or when its size
    /// doesn't match the image, because the build writes both and a mismatch would draw the wrong pixels.
    pub fn loadAtlas(self: *const Context, image_path: []const u8, index_path: []const u8) LoadedAtlas {
        const text = self.readFile(index_path) catch |err| {
            std.debug.panic("atlas index '{s}' could not be read: {s}", .{ index_path, @errorName(err) });
        };
        defer std.heap.page_allocator.free(text);
        const index = atlas.Atlas.parse(std.heap.page_allocator, text) catch |err| {
            std.debug.panic("atlas index '{s}' is invalid: {s}", .{ index_path, @errorName(err) });
        };
        const texture = self.loadTexture(image_path);
        if (index.width != texture.width or index.height != texture.height) {
            std.debug.panic("atlas index is for {d}x{d}, but the atlas image is {d}x{d}; rebuild", .{
                index.width, index.height, texture.width, texture.height,
            });
        }
        return .{ .texture = texture, .index = index };
    }
};


/// Chooses a prebuilt GPU-native image variant only when SDL says the active device can sample it.
/// Missing or malformed variants fall through to the next format and ultimately the RGBA8 decoder.
fn loadCompressedVariant(
    ctx: *const Context,
    relative: []const u8,
    suffix: []const u8,
    compression: image.Compression,
    gpu_format: c.SDL_GPUTextureFormat,
) ?Texture {
    if (compression != .rgba8 and !c.SDL_GPUTextureSupportsFormat(ctx.device, gpu_format, c.SDL_GPU_TEXTURETYPE_2D, c.SDL_GPU_TEXTUREUSAGE_SAMPLER)) return null;
    var path_buf: [max_full_path]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}{s}{s}", .{ ctx.base_path, relative, suffix }) catch return null;
    var compressed = image.loadCompressed(path.ptr, compression) catch return null;
    defer compressed.deinit();
    elog.debug("using {s} texture variant {s} ({d}x{d})", .{ @tagName(compression), path, compressed.width, compressed.height });
    if (compression == .rgba8) return Texture.initRgba8(ctx.device, compressed.width, compressed.height, compressed.blocks);
    return Texture.initCompressed(ctx.device, compressed.width, compressed.height, gpu_format, compressed.blocks);
}


/// What the game needs to queue sprites for one frame.
pub const DrawContext = struct {
    /// Sprites are queued here. The engine uploads and draws them.
    batch: *SpriteBatch,
    /// The view camera. The game sets its world size, then calls `follow`.
    cam: *Camera,
    /// Native view size in pixels. The camera's view has this size.
    view_w: f32,
    view_h: f32,
    /// Blend factor between the last two updates. 0 is the previous update, and 1 is the latest.
    alpha: f32,
    /// Seconds since the previous frame, capped like the update loop's frame time. Smoothing that
    /// should not depend on the frame rate uses it.
    dt: f32,
};
