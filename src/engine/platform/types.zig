//! Platform-facing value types. This file imports neither SDL nor engine systems, so the engine and
//! the platform backend can both use it without depending on each other.

/// A physical key, named by its position on the keyboard. A layout changes the character a position
/// produces, not the position, so bindings resolve through these. The engine reports 26 keys: the 24
/// in `Key` (engine/input/input.zig), plus F3 and F11.
pub const Scancode = enum {
    escape,
    left,
    right,
    up,
    down,
    w,
    a,
    s,
    d,
    i,
    equal,
    minus,
    zero,
    keypad_plus,
    keypad_minus,
    space,
    enter,
    tab,
    q,
    e,
    f,
    r,
    f5,
    f9,
    f3,
    f11,
};

pub const MouseButton = enum { left, right, middle };

/// An event the engine consumes. Backends translate native events into these and drop the rest.
/// Quit is never dropped.
pub const Event = union(enum) {
    quit,
    key_down: struct { scancode: Scancode, repeat: bool },
    key_up: struct { scancode: Scancode },
    /// Mouse position in window points.
    mouse_motion: struct { x: f32, y: f32 },
    mouse_button_down: MouseButton,
    mouse_button_up: MouseButton,
};

/// An application window. The engine holds and passes pointers to it. Only the platform backend knows
/// what is behind one, so the type has no fields.
pub const Window = opaque {};

/// A window size in pixels. This is the swapchain size, which on high-DPI displays is larger than the
/// window's size in points.
pub const PixelSize = struct { w: c_int, h: c_int };

/// Where a file lives. `.packaged` holds the shipped assets and is read-only. `.beside_executable`
/// holds settings, the log, and save data, and it is the only location that accepts writes.
pub const Location = enum { packaged, beside_executable };

/// The longest full path the file API builds, in bytes. A longer path is an error, never a cut-off.
pub const max_full_path = 1024;

/// Errors from file access. `NotFound` means the path does not exist. Any other failure to read
/// is `ReadFailed`.
pub const FileError = error{ NotFound, ReadFailed, WriteFailed, ReadOnlyLocation, PathTooLong, OutOfMemory };

/// An open playback device. The engine holds a pointer to it, and only the SDL backend knows what it means.
pub const AudioDevice = opaque {};

/// A playback stream that is bound to a device. Like `AudioDevice`, the backend gives it meaning.
pub const AudioStream = opaque {};

/// How one sample is stored. These are the only sample kinds the engine handles.
pub const SampleKind = enum { uint8, int16, int32, float32 };

/// Interleaved PCM: the sample rate in Hz, the channel count, and the sample kind.
pub const PcmFormat = struct {
    sample_rate: u32,
    channels: u8,
    kind: SampleKind,
};

/// Decoded PCM bytes, with the format they are in. The caller owns `samples`.
pub const PcmBuffer = struct {
    samples: []u8,
    format: PcmFormat,
};

/// A playback device that opened, and the format the engine mixes in for it.
pub const OpenedAudio = struct {
    device: *AudioDevice,
    format: PcmFormat,
};

/// Errors from the audio backend's decoding and conversion. Device and stream failures are optional
/// returns, and the engine turns them into its own errors.
pub const AudioError = error{ DecodeFailed, ConvertFailed, OutOfMemory };
