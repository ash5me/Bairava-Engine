//! The platform layer: everything that talks to the operating system or to SDL. Only the files
//! under platform/sdl/ import SDL, and the rest of the engine reaches the platform through here.

const std = @import("std");

const types = @import("types.zig");
const sdl_audio = @import("sdl/audio.zig");
const sdl_clock = @import("sdl/clock.zig");
const sdl_files = @import("sdl/files.zig");
const sdl_init = @import("sdl/init.zig");
const sdl_input = @import("sdl/input.zig");
const window_backend = @import("sdl/window.zig");

pub const Scancode = types.Scancode;
pub const MouseButton = types.MouseButton;
pub const Event = types.Event;
pub const Window = types.Window;
pub const PixelSize = types.PixelSize;
pub const Location = types.Location;
pub const FileError = types.FileError;
pub const max_full_path = types.max_full_path;
pub const AudioDevice = types.AudioDevice;
pub const AudioStream = types.AudioStream;
pub const PcmFormat = types.PcmFormat;
pub const PcmBuffer = types.PcmBuffer;
pub const OpenedAudio = types.OpenedAudio;
pub const AudioError = types.AudioError;

/// Starts the platform: the video subsystem, which the window and GPU need, and the audio subsystem.
/// A video failure panics. An audio failure is logged, and the game runs silent. Call it once,
/// before any window or device is created.
pub fn init() void {
    sdl_init.init();
}

/// Stops the platform and everything it started. Call it once, after every window, device, and
/// audio stream has been released.
pub fn shutdown() void {
    sdl_init.shutdown();
}

/// Monotonic time and delays. The frame loop and the logger's timestamps both read this clock.
pub const clock = struct {
    /// Nanoseconds from an arbitrary fixed point. Only differences mean anything, and the value never
    /// goes backward.
    pub fn nowNs() u64 {
        return sdl_clock.nowNs();
    }

    /// Blocks the calling thread for at least `ms` milliseconds.
    pub fn sleepMs(ms: u32) void {
        sdl_clock.sleepMs(ms);
    }
};

/// File access. Every call names a location, and the platform decides which folder it resolves to.
/// Writes are accepted only for `.beside_executable`.
pub const files = struct {
    /// The folder the executable runs from, with a trailing separator. Valid until `shutdown`.
    pub fn baseDir() []const u8 {
        return sdl_files.baseDir();
    }

    /// Reads a whole file into memory that the caller owns. `error.NotFound` means the path does not exist.
    pub fn read(allocator: std.mem.Allocator, location: Location, path: []const u8) FileError![]u8 {
        return sdl_files.read(allocator, location, path);
    }

    /// Writes a whole file, replacing any old one. Only `.beside_executable` accepts writes.
    pub fn write(location: Location, path: []const u8, bytes: []const u8) FileError!void {
        return sdl_files.write(location, path, bytes);
    }

    /// The full path for `path` at `location`, built in `buf`.
    pub fn absolutePath(location: Location, path: []const u8, buf: []u8) FileError![:0]const u8 {
        return sdl_files.absolutePath(location, path, buf);
    }
};

/// Platform events and held keys, as the engine uses them.
pub const events = struct {
    /// The next event the engine consumes, or null when the queue has none left. Events the engine
    /// does not consume are skipped.
    pub fn poll() ?Event {
        return sdl_input.poll();
    }

    /// Whether a physical key is held, as of the latest query.
    pub fn isHeld(code: Scancode) bool {
        return sdl_input.isHeld(code);
    }
};

/// The game window. The engine holds a `*Window` and never sees the SDL type behind it.
pub const window = struct {
    /// Creates the game window. Panics if the platform cannot create one.
    pub fn create(title: [:0]const u8, width: c_int, height: c_int, fullscreen: bool) *Window {
        return window_backend.create(title, width, height, fullscreen);
    }

    /// Destroys a window made by `create`.
    pub fn destroy(win: *Window) void {
        window_backend.destroy(win);
    }

    /// Switches the window between windowed and full screen.
    pub fn toggleFullscreen(win: *Window) void {
        window_backend.toggleFullscreen(win);
    }

    /// The window's size in pixels. On high-DPI displays this is larger than its size in points.
    pub fn pixelSize(win: *Window) PixelSize {
        return window_backend.pixelSize(win);
    }

    /// Pixels per point. Mouse positions are in points, so the view mapping needs this.
    pub fn pixelDensity(win: *Window) f32 {
        return window_backend.pixelDensity(win);
    }
};

/// Playback devices and streams. Engine code gets opaque handles and `PcmFormat`, never SDL types.
/// Only the SDL backend knows what a handle holds.
pub const audio = struct {
    /// Opens the default playback device. Null when there is none, which is logged. The engine mixes in
    /// the returned format.
    pub fn openDefault() ?types.OpenedAudio {
        return sdl_audio.openDefault();
    }

    /// Closes a device. Streams bound to it must already be destroyed.
    pub fn closeDevice(device: *types.AudioDevice) void {
        sdl_audio.closeDevice(device);
    }

    /// A stream that takes and returns `format`. Its output converts to the device format when bound.
    pub fn createStream(format: types.PcmFormat) ?*types.AudioStream {
        return sdl_audio.createStream(format);
    }

    /// Binds a stream to a device so the device plays it.
    pub fn bindStream(device: *types.AudioDevice, stream: *types.AudioStream) bool {
        return sdl_audio.bindStream(device, stream);
    }

    /// Unbinds and frees a stream.
    pub fn destroyStream(stream: *types.AudioStream) void {
        sdl_audio.destroyStream(stream);
    }

    /// Queues bytes on a stream, in the stream's format.
    pub fn putStreamData(stream: *types.AudioStream, bytes: []const u8) bool {
        return sdl_audio.putStreamData(stream, bytes);
    }

    /// Pushes out whatever the stream still holds.
    pub fn flushStream(stream: *types.AudioStream) void {
        sdl_audio.flushStream(stream);
    }

    /// Sets the gain a stream plays at.
    pub fn setStreamGain(stream: *types.AudioStream, gain: f32) void {
        sdl_audio.setStreamGain(stream, gain);
    }

    /// Bytes queued on a stream as input.
    pub fn streamQueuedBytes(stream: *types.AudioStream) i32 {
        return sdl_audio.streamQueuedBytes(stream);
    }

    /// Converted bytes a stream holds ready to play.
    pub fn streamAvailableBytes(stream: *types.AudioStream) i32 {
        return sdl_audio.streamAvailableBytes(stream);
    }

    /// Decodes WAV bytes into PCM the caller owns. Needs no device.
    pub fn decodeWav(allocator: std.mem.Allocator, bytes: []const u8) types.AudioError!types.PcmBuffer {
        return sdl_audio.decodeWav(allocator, bytes);
    }

    /// Converts interleaved PCM between formats. Needs no device.
    pub fn convert(allocator: std.mem.Allocator, src: types.PcmFormat, bytes: []const u8, dst: types.PcmFormat) types.AudioError![]u8 {
        return sdl_audio.convert(allocator, src, bytes, dst);
    }
};

// Still re-exported from the SDL backend until the GPU step (8) moves it behind this file. The SDL C
// namespace is not exported, so the engine cannot name SDL types here.
pub const gpu = @import("sdl/gpu.zig");
