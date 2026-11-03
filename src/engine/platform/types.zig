//! Platform-facing value types. This file imports neither SDL nor engine systems, so the engine and
//! the platform backend can both use it without depending on each other.

/// A physical key, named by its position on the keyboard. A layout changes the character a position
/// produces, not the position, so bindings resolve through these. The engine reports command keys plus
/// the keys named by `Key` (engine/input/input.zig).
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
    backspace,
    f8,
    f5,
    f9,
    f2,
    f3,
    f11,
    f4,
    f10,
};

pub const MouseButton = enum { left, right, middle };

/// The most gamepads the engine tracks at once. A device that connects past this is not tracked.
pub const max_gamepads = 8;

/// A button on a standard gamepad, named by where it sits, so one name is the same control on every
/// controller. A button without a standard place (paddles, the touchpad, extra buttons) is not reported.
pub const GamepadButton = enum {
    south,
    east,
    west,
    north,
    back,
    guide,
    start,
    left_stick,
    right_stick,
    left_shoulder,
    right_shoulder,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
};

/// An axis on a standard gamepad. Each stick has an x and a y axis, and each trigger has one axis.
pub const GamepadAxis = enum { left_x, left_y, right_x, right_y, left_trigger, right_trigger };

/// A connected gamepad as the engine names it. `slot` is its place in the engine's table, and
/// `generation` rises each time that place is given to a new device, so an id from an earlier device
/// no longer matches. The platform makes these, and no SDL identifier leaves the backend.
pub const GamepadId = struct {
    slot: u8,
    generation: u32,
};

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
    /// A gamepad connected. Its id is valid until the matching `gamepad_removed`.
    gamepad_added: GamepadId,
    gamepad_removed: GamepadId,
    gamepad_button_down: struct { id: GamepadId, button: GamepadButton },
    gamepad_button_up: struct { id: GamepadId, button: GamepadButton },
    /// An axis moved. A stick reads from -1 (left or up) to 1 (right or down), and a trigger from 0 to 1.
    /// The value is the raw position, before any dead zone.
    gamepad_axis: struct { id: GamepadId, axis: GamepadAxis, value: f32 },
    /// UTF-8 text from the active text-input session.
    text_input: TextInput,
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

/// A file open for reads at chosen offsets, so a stream can read it a piece at a time. Only the SDL backend knows what
/// it holds. Close it with `platform.files.close`.
pub const OpenFile = opaque {};

/// Bounded text from one platform text-input event, copied out of the backend's event storage.
pub const TextInput = struct {
    bytes: [32]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const TextInput) []const u8 {
        return self.bytes[0..self.len];
    }
};

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
