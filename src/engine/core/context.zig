//! What the game sees while it runs. `Context` is passed to `init` and `update`, and it loads
//! assets relative to the folder of the executable. `DrawContext` is passed to `draw`.

const std = @import("std");
const allocator_types = @import("allocators.zig");
const audio = @import("../audio/audio.zig");
const platform = @import("../platform/platform.zig");
const image = @import("../assets/loaders/image.zig");
const atlas = @import("../assets/loaders/atlas.zig");
const logging = @import("../logging/log.zig");
const profile = @import("../profiling/profile.zig");
const ui = @import("../ui/ui.zig");
const view = @import("../renderer/view.zig");
const Camera = @import("../renderer/camera.zig").Camera;
const LoadedAtlas = @import("../renderer/loaded_atlas.zig").LoadedAtlas;
const SpriteBatch = @import("../renderer/sprite.zig").SpriteBatch;
const texture_renderer = @import("../renderer/texture.zig");
const Texture = @import("../renderer/texture.zig").Texture;
const font = @import("../text/font.zig");
const Input = @import("../input/input.zig").Input;

const ScaleMode = view.ScaleMode;
const elog = logging.scoped("engine");
const GpuAccess = opaque {};

pub const AssetError = error{
    PathTooLong,
    FileNotFound,
    ReadFailed,
    DecodeFailed,
    InvalidAtlas,
    InvalidLevel,
    AtlasMismatch,
    FontLoadFailed,
    TextureLoadFailed,
    OutOfMemory,
};

/// Longest full asset path the loader builds, in bytes. A longer path panics with a clear message.
pub const max_full_path = platform.max_full_path;

/// State the game reads and writes during `update`, plus the GPU access it needs in `init`.
pub const Context = struct {
    gpu_state: *GpuAccess,
    /// Restricted allocators for game-owned, asset-owned, and current-frame data.
    allocators: allocator_types.ContextAllocators,
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

    /// Loads an image and uploads it as a texture. Missing and malformed assets are returned as
    /// contextual asset errors; callers decide whether they are recoverable.
    pub fn loadTexture(self: *const Context, relative: []const u8) AssetError!Texture {
        const zone = profile.zoneNamed(@src(), "load texture");
        defer zone.End();
        const device = contextGpuDevice(self);
        if (try variantOrError(self, relative, ".astc", .astc_4x4)) |texture| return texture;
        if (try variantOrError(self, relative, ".bc3", .bc3)) |texture| return texture;
        if (try variantOrError(self, relative, ".bc1", .bc1)) |texture| return texture;
        if (try variantOrError(self, relative, ".rgba", .rgba8)) |texture| return texture;
        var abs_buf: [max_full_path]u8 = undefined;
        const abs = platform.files.absolutePath(.packaged, relative, &abs_buf) catch {
            return error.PathTooLong;
        };
        const bytes = platform.files.read(self.allocators.asset, .packaged, relative) catch |err| {
            return switch (err) {
                error.NotFound => error.FileNotFound,
                error.OutOfMemory => error.OutOfMemory,
                else => error.ReadFailed,
            };
        };
        defer self.allocators.asset.free(bytes);
        var img = image.decodeRgba8(bytes) catch |err| {
            elog.warn("texture '{s}' ({s}) could not be decoded: {s}", .{ relative, abs, @errorName(err) });
            return error.DecodeFailed;
        };
        defer img.deinit();
        elog.debug("loaded texture {s} ({d}x{d})", .{ abs, img.width, img.height });
        return texture_renderer.createRgba8(self.allocators.asset, device, img.width, img.height, img.pixels);
    }

    /// Loads a sound and converts it to the device's format. `relative` is relative to the executable's
    /// folder, like `loadTexture`. A build-encoded IMA sidecar is used when present. It returns an error
    /// instead of panicking, because a missing sound shouldn't stop the game. The caller frees the sound
    /// with `Sound.deinit`.
    pub fn loadSound(self: *const Context, relative: []const u8) audio.Error!audio.Sound {
        return self.audio.loadSound(self.allocators.asset, relative);
    }

    /// Reads a whole packaged file using `allocator`. The caller owns the result and frees it with
    /// that allocator. A missing file gives `error.FileNotFound`; other failures give `error.ReadFailed`.
    pub fn readFile(_: *const Context, allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
        const bytes = platform.files.read(allocator, .packaged, relative) catch |err| return switch (err) {
            error.NotFound => error.FileNotFound,
            error.PathTooLong => error.PathTooLong,
            error.OutOfMemory => error.OutOfMemory,
            else => error.ReadFailed,
        };
        return bytes;
    }

    /// Writes a whole file, replacing any old one. `relative` is relative to the executable's folder,
    /// like `readFile`. The platform logs SDL's reason when the write fails, and this returns an error.
    pub fn writeFile(_: *const Context, relative: []const u8, bytes: []const u8) !void {
        platform.files.write(.beside_executable, relative, bytes) catch |err| return switch (err) {
            error.PathTooLong => error.PathTooLong,
            else => error.WriteFailed,
        };
    }

    /// Loads a UI font. Missing or malformed font assets return an error instead of crashing startup.
    pub fn loadFont(self: *const Context, relative: []const u8, pixel_height: f32) AssetError!ui.Font {
        var prebaked_buf: [max_full_path]u8 = undefined;
        const prebaked_path = std.fmt.bufPrint(&prebaked_buf, "{s}.bfnt", .{relative}) catch {
            return error.PathTooLong;
        };
        const prebaked = self.readFile(self.allocators.asset, prebaked_path) catch null;
        defer if (prebaked) |bytes| self.allocators.asset.free(bytes);
        const ttf_file = self.readFile(self.allocators.asset, relative) catch null;
        defer if (ttf_file) |bytes| self.allocators.asset.free(bytes);
        if (prebaked == null and ttf_file == null) {
            return error.FileNotFound;
        }
        const ttf: []const u8 = ttf_file orelse &.{};
        const pre: []const u8 = prebaked orelse &.{};
        return font.load(self.allocators.asset, contextGpuDevice(self), ttf, pre, pixel_height) catch |err| {
            elog.warn("font '{s}' could not be loaded: {s}", .{ relative, @errorName(err) });
            return error.FontLoadFailed;
        };
    }

    /// Loads a texture atlas and validates the index against the uploaded image.
    pub fn loadAtlas(self: *const Context, image_path: []const u8, index_path: []const u8) AssetError!LoadedAtlas {
        const text = self.readFile(self.allocators.asset, index_path) catch |err| {
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                error.PathTooLong => error.PathTooLong,
                error.OutOfMemory => error.OutOfMemory,
                else => error.ReadFailed,
            };
        };
        defer self.allocators.asset.free(text);
        const index = atlas.Atlas.parse(self.allocators.asset, text) catch |err| {
            elog.warn("atlas index '{s}' is invalid: {s}", .{ index_path, @errorName(err) });
            return error.InvalidAtlas;
        };
        const texture = try self.loadTexture(image_path);
        if (index.width != texture.width or index.height != texture.height) {
            var mutable_texture = texture;
            mutable_texture.deinit();
            var mutable_index = index;
            mutable_index.deinit();
            return error.AtlasMismatch;
        }
        return .{ .texture = texture, .index = index };
    }
};

fn contextGpuDevice(ctx: *const Context) *platform.gpu.Device {
    return @ptrCast(ctx.gpu_state);
}


/// Chooses a prebuilt GPU-native image variant only when SDL says the active device can sample it.
/// A missing variant, or one that doesn't parse, falls through to the next format and ultimately the
/// RGBA8 decoder. Any other read failure is returned to the caller.
fn loadCompressedVariant(
    ctx: *const Context,
    relative: []const u8,
    suffix: []const u8,
    compression: image.Compression,
) !?Texture {
    const device = contextGpuDevice(ctx);
    if (compression != .rgba8 and !texture_renderer.supportsCompression(device, compression)) return null;
    var name_buf: [max_full_path]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ relative, suffix }) catch return null;
    const bytes = platform.files.read(ctx.allocators.asset, .packaged, name) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    defer ctx.allocators.asset.free(bytes);
    var compressed = image.parseCompressed(ctx.allocators.asset, bytes, compression) catch return null;
    defer compressed.deinit();
    elog.debug("using {s} texture variant {s} ({d}x{d})", .{ @tagName(compression), name, compressed.width, compressed.height });
    if (compression == .rgba8) return texture_renderer.createRgba8(ctx.allocators.asset, device, compressed.width, compressed.height, compressed.blocks);
    return texture_renderer.createCompressed(ctx.allocators.asset, device, compressed.width, compressed.height, compression, compressed.blocks);
}

/// Loads a prebuilt GPU-native variant, returning missing variants as fallback opportunities.
fn variantOrError(
    ctx: *const Context,
    relative: []const u8,
    suffix: []const u8,
    compression: image.Compression,
) AssetError!?Texture {
    return loadCompressedVariant(ctx, relative, suffix, compression) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.PathTooLong => error.PathTooLong,
            else => error.ReadFailed,
        };
    };
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
