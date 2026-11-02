//! Sound output: the API the engine and the game use. `Audio` owns the voices and the playback policy.
//! Every device and stream operation goes through `platform.audio`, so no SDL type reaches this file.
//! Sound bytes come through `platform.files`. IMA sidecars are decoded in `ima.zig`, which is SDL-free.
//! Positional sounds are placed by `spatial.zig`: their loudness and pan follow the listener, and their bytes are
//! panned as they are queued.

const std = @import("std");

const platform = @import("../platform/platform.zig");
const ima = @import("ima.zig");
const rules = @import("voices.zig");
const spatial = @import("spatial.zig");
const logging = @import("../logging/log.zig");
const collector = @import("../diagnostics/collector.zig");

const log = logging.scoped("audio");

/// Voices that can play at once.
pub const max_voices: u16 = 32;

/// Bytes of scratch space for panning. Every panned run fits here, whatever the sound's length.
pub const scratch_bytes: usize = 8192;

/// A positional voice is queued this many seconds ahead, as one tenth of a second. A change of pan or distance is
/// heard within that time. A stall in the game loop longer than this can leave a positional voice silent until the
/// next update.
const positional_lookahead_divisor: u32 = 10;

pub const Handle = rules.Handle;

pub const Error = error{
    /// No playback device is open, so nothing can play or load.
    NoDevice,
    /// Every voice is busy. The caller decides whether that matters.
    NoFreeVoice,
    /// The file couldn't be read or decoded as WAV or BRAD IMA ADPCM.
    LoadFailed,
    /// The decoded sound couldn't be converted to the device format.
    ConvertFailed,
    /// The platform couldn't create or bind a stream for the voice.
    StreamFailed,
};

/// A sound in the device's format, ready to play. It owns its samples and frees them with the
/// allocator it was made with, so free it with `deinit`.
pub const Sound = struct {
    allocator: std.mem.Allocator,
    samples: []u8,

    pub fn deinit(self: *Sound) void {
        self.allocator.free(self.samples);
        self.* = undefined;
    }
};

pub const PlayOptions = struct {
    /// Volume of this voice, from 0 (silent) to 1 (full). The master gain multiplies it.
    gain: f32 = 1.0,
    /// Repeat until stopped.
    loop: bool = false,
    /// Left-right placement, from -1 (full left) to 1 (full right), with 0 at center. A positional voice adds its own
    /// placement to this, and the sum is clamped to the same range.
    pan: f32 = 0.0,
    /// Where the sound comes from, in world pixels, as measured from the listener set with `setListener`. Null for a
    /// sound that plays the same everywhere. A positional sound gets quieter with distance and pans toward its side.
    position: ?spatial.Point = null,
    /// The distance, in pixels, at which a positional sound falls silent. Ignored when `position` is null.
    range: f32 = spatial.default_range,
};

fn clampGain(value: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
}

/// What a busy voice holds.
const Playing = struct {
    stream: *platform.AudioStream,
    sound: *const Sound,
    looping: bool,
    /// The voice's own gain, from 0 to 1, kept so the master gain can change without losing it.
    gain: f32,
    /// The pan the caller asked for, from -1 (left) to 1 (right). A positional voice adds its place to it.
    pan: f32,
    /// Where the voice is, in world pixels. Null for a voice that plays the same everywhere.
    position: ?spatial.Point,
    /// The distance at which a positional voice falls silent, in pixels.
    range: f32,
    /// How loud the voice is at its place, from 0 to 1. Set from the listener by `refreshMix`.
    attenuation: f32 = 1,
    /// The pan the voice's bytes are written with: its own pan plus its place, clamped. Set by `refreshMix`.
    effective_pan: f32 = 0,
    /// How many bytes of the sound have been fed, counted from its start. A looping voice wraps back to zero.
    cursor: usize = 0,
    /// True once a non-looping voice has been fed its whole sound, or was refused partway and cut short.
    fed: bool = false,
};

/// How many bytes a positional voice keeps queued ahead of playback, for a device format.
fn lookaheadBytes(format: platform.PcmFormat) usize {
    const frames = @max(format.sample_rate / positional_lookahead_divisor, 1);
    return @as(usize, frames) * spatial.frameBytes(format);
}

pub const Audio = struct {
    /// The open device, or null when none is open.
    device: ?*platform.AudioDevice = null,
    /// The format the engine mixes in. Sounds convert to it, and voice streams use it on both sides.
    format: platform.PcmFormat = undefined,
    playing: rules.Pool(Playing, max_voices) = .{},
    master_gain: f32 = 1.0,
    /// Where the listener is, in world pixels. Positional voices are heard from here.
    listener: spatial.Point = .{ .x = 0, .y = 0 },
    /// Holds one panned run at a time. Its bytes are copied into a stream, so every voice shares it.
    scratch: [scratch_bytes]u8 = undefined,

    /// Opens the default playback device. This never fails: without a device the object stays silent,
    /// and the platform logs why.
    pub fn init() Audio {
        var audio: Audio = .{};
        if (platform.audio.openDefault()) |opened| {
            audio.device = opened.device;
            audio.format = opened.format;
        }
        return audio;
    }

    /// Stops every voice and closes the device. The audio subsystem stays up, because it belongs to
    /// `platform.shutdown`. Sounds are the caller's to free.
    pub fn deinit(self: *Audio) void {
        const device = self.device orelse return;
        var it = self.playing.iterator();
        while (it.next()) |entry| {
            const stream = entry.payload.stream;
            _ = self.playing.release(entry.handle);
            platform.audio.destroyStream(stream);
        }
        platform.audio.closeDevice(device);
        self.* = .{};
    }

    /// Loads a sound from the packaged assets and converts it to the device's format once, here. When a
    /// build-encoded IMA sidecar (`<relative>.ima`) exists, it is used. Otherwise the WAV at `relative`
    /// is used. The caller frees the result with `Sound.deinit`.
    pub fn loadSound(self: *const Audio, allocator: std.mem.Allocator, relative: []const u8) Error!Sound {
        if (self.device == null) return error.NoDevice;
        if (try self.loadImaSidecar(allocator, relative)) |sound| return sound;

        const wav = platform.files.read(allocator, .packaged, relative) catch |err| {
            log.warn("could not read '{s}': {s}", .{ relative, @errorName(err) });
            return error.LoadFailed;
        };
        defer allocator.free(wav);
        const decoded = platform.audio.decodeWav(allocator, wav) catch |err| {
            log.warn("could not decode '{s}': {s}", .{ relative, @errorName(err) });
            return error.LoadFailed;
        };
        defer allocator.free(decoded.samples);
        const converted = platform.audio.convert(allocator, decoded.format, decoded.samples, self.format) catch {
            log.warn("could not convert '{s}' to the device format", .{relative});
            return error.ConvertFailed;
        };
        return .{ .allocator = allocator, .samples = converted };
    }

    fn loadImaSidecar(self: *const Audio, allocator: std.mem.Allocator, relative: []const u8) Error!?Sound {
        var name_buf: [platform.max_full_path]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}.ima", .{relative}) catch return null;
        const bytes = platform.files.read(allocator, .packaged, name) catch |err| {
            if (err != error.NotFound) log.warn("could not read audio sidecar '{s}': {s}; trying WAV source", .{ name, @errorName(err) });
            return null;
        };
        defer allocator.free(bytes);

        var decoded = ima.decode(allocator, bytes) catch |err| {
            log.warn("could not decode audio sidecar '{s}': {s}; trying WAV source", .{ name, @errorName(err) });
            return null;
        };
        defer decoded.deinit();

        // The sidecar decodes to int16 at its own rate and channel count.
        const source = platform.PcmFormat{
            .sample_rate = decoded.sample_rate,
            .channels = decoded.channels,
            .kind = .int16,
        };
        const converted = platform.audio.convert(allocator, source, std.mem.sliceAsBytes(decoded.samples), self.format) catch {
            log.warn("could not convert audio sidecar '{s}' to the device format", .{name});
            return error.ConvertFailed;
        };
        log.debug("loaded compact audio {s} ({d} Hz, {d} channels)", .{ name, decoded.sample_rate, decoded.channels });
        return Sound{ .allocator = allocator, .samples = converted };
    }

    /// Starts `sound` on a free voice and returns its handle. The voice ends by itself when a non-looping sound
    /// finishes, or when `stop` is called. A positional voice follows the listener and its position, from the next
    /// update on.
    pub fn play(self: *Audio, sound: *const Sound, options: PlayOptions) Error!Handle {
        if (sound.samples.len == 0) {
            log.warn("sound is empty; refusing to play it", .{});
            return error.StreamFailed;
        }
        const device = self.device orelse return error.NoDevice;
        if (rules.wholeBytes(sound.samples.len, spatial.frameBytes(self.format)) == 0) {
            log.warn("sound holds less than one whole frame; refusing to play it", .{});
            return error.StreamFailed;
        }

        const stream = platform.audio.createStream(self.format) orelse {
            log.warn("could not create an audio stream", .{});
            return error.StreamFailed;
        };
        // Until the voice is stored, this stream belongs to us and must be closed on any error.
        var adopted = false;
        defer if (!adopted) platform.audio.destroyStream(stream);

        var voice = Playing{
            .stream = stream,
            .sound = sound,
            .looping = options.loop,
            .gain = clampGain(options.gain),
            .pan = spatial.clampPan(options.pan),
            .position = options.position,
            .range = options.range,
        };
        self.refreshMix(&voice);
        self.applyGain(&voice);
        if (!self.feed(&voice)) {
            log.warn("could not queue sound data", .{});
            return error.StreamFailed;
        }

        if (!platform.audio.bindStream(device, stream)) {
            log.warn("could not bind the audio stream", .{});
            return error.StreamFailed;
        }

        const handle = self.playing.acquire(voice) orelse return error.NoFreeVoice;
        adopted = true;
        return handle;
    }

    /// Sets where the listener is, in world pixels. Every positional voice is heard from here from the next update.
    pub fn setListener(self: *Audio, position: spatial.Point) void {
        self.listener = position;
    }

    /// Moves a voice to `position`, in world pixels. A voice that had no position becomes positional, with the range it
    /// was played with. Its gain changes at the next update. Its pan applies to the audio still to be queued, so a change
    /// is heard within a tenth of a second, and a sound that was queued whole at play time keeps its pan. A stale handle
    /// does nothing.
    pub fn setPosition(self: *Audio, handle: Handle, position: spatial.Point) void {
        const voice = self.playing.get(handle) orelse return;
        voice.position = position;
    }

    /// Stops a voice now. A stale handle, one whose voice already ended, does nothing.
    pub fn stop(self: *Audio, handle: Handle) void {
        const playing = self.playing.release(handle) orelse return;
        platform.audio.destroyStream(playing.stream);
    }

    /// True while the voice behind `handle` is still playing.
    pub fn isPlaying(self: *Audio, handle: Handle) bool {
        return self.playing.get(handle) != null;
    }

    /// Sets the gain every voice is multiplied by. It applies to voices already playing too.
    pub fn setMasterGain(self: *Audio, gain: f32) void {
        self.master_gain = clampGain(gain);
        var it = self.playing.iterator();
        while (it.next()) |entry| self.applyGain(entry.payload);
    }

    /// Copies the audio state into `out` for the console's `audio` command: whether a device is open and
    /// its format, the busy voice count, the master gain, and the first few busy voices. Allocates nothing.
    pub fn describe(self: *Audio, out: *collector.AudioState) void {
        out.* = .{};
        out.device_open = self.device != null;
        if (self.device != null) {
            out.sample_rate = self.format.sample_rate;
            out.channels = self.format.channels;
        }
        out.voices_busy = @intCast(self.playing.count());
        out.voices_max = max_voices;
        out.master_gain = self.master_gain;

        var it = self.playing.iterator();
        while (it.next()) |entry| {
            if (out.listed_count == collector.AudioState.max_listed) break;
            out.listed[out.listed_count] = .{
                .looping = entry.payload.looping,
                .gain = entry.payload.gain,
                .sound_bytes = entry.payload.sound.samples.len,
            };
            out.listed_count += 1;
        }
    }

    /// Call once per frame. It moves each positional voice's gain and pan to the listener's current view, keeps every
    /// voice's stream fed, and frees voices that have finished.
    pub fn update(self: *Audio) void {
        if (self.device == null) return;
        var it = self.playing.iterator();
        while (it.next()) |entry| {
            const voice = entry.payload;
            if (voice.sound.samples.len == 0) {
                const stream = voice.stream;
                _ = self.playing.release(entry.handle);
                platform.audio.destroyStream(stream);
                continue;
            }
            if (voice.position != null) {
                self.refreshMix(voice);
                self.applyGain(voice);
            }
            // A refused feed has already ended a non-looping voice, so the result is not needed here.
            _ = self.feed(voice);
            const queued = platform.audio.streamQueuedBytes(voice.stream);
            const available = platform.audio.streamAvailableBytes(voice.stream);
            if (rules.isFinished(voice.looping, voice.fed, queued, available)) {
                const stream = voice.stream;
                _ = self.playing.release(entry.handle);
                platform.audio.destroyStream(stream);
            }
        }
    }

    /// Works out a voice's attenuation and pan from the listener and its place. A voice without a place plays at full
    /// level, with only the pan it was played with.
    fn refreshMix(self: *const Audio, voice: *Playing) void {
        if (voice.position) |source| {
            const placed = spatial.mix(self.listener, source, voice.range);
            voice.attenuation = placed.attenuation;
            voice.effective_pan = spatial.clampPan(voice.pan + placed.pan);
        } else {
            voice.attenuation = 1;
            voice.effective_pan = voice.pan;
        }
    }

    /// Sets the stream's gain from the voice's own gain, its attenuation, and the master gain.
    fn applyGain(self: *const Audio, voice: *const Playing) void {
        platform.audio.setStreamGain(voice.stream, rules.effectiveGain(voice.gain * voice.attenuation, self.master_gain));
    }

    /// Queues runs of the sound until the stream holds its target. A run that needs panning is written to the scratch
    /// buffer first. A non-looping voice is flushed once its last run is queued, so it can finish. Returns false when
    /// the platform refuses the data. A non-looping voice that is refused is marked fed too, so it ends once its
    /// stream drains.
    fn feed(self: *Audio, voice: *Playing) bool {
        if (voice.fed) return true;
        const format = self.format;
        const frame = spatial.frameBytes(format);
        const whole = rules.wholeBytes(voice.sound.samples.len, frame);
        const target = rules.feedTarget(voice.position != null, whole, lookaheadBytes(format));
        const gains = spatial.channelGains(voice.effective_pan);
        const pans = spatial.needsPan(format.channels, gains);
        // A positional voice is fed in short runs, so a change of place reaches the output soon. A voice that is neither
        // positional nor panned has no reason to split its sound, so it is fed whole.
        const limit: usize = if (voice.position != null or pans) scratch_bytes else whole;
        // A call stops once it has pushed `target` bytes. A healthy stream reaches its target first, so this only stops
        // a stream that never reports what it holds from keeping the game in this loop.
        var pushed: usize = 0;

        while (true) {
            if (!voice.looping and voice.cursor >= whole) {
                finishFeed(voice);
                return true;
            }
            if (pushed >= target) return true;
            const queued = platform.audio.streamQueuedBytes(voice.stream);
            if (!rules.needsInput(queued, target)) return true;
            const run = rules.nextRun(voice.cursor, whole, frame, limit, voice.looping) orelse {
                finishFeed(voice);
                return true;
            };
            const source = voice.sound.samples[run.start..][0..run.len];
            var bytes: []const u8 = source;
            if (pans) {
                const panned = self.scratch[0..run.len];
                spatial.applyChannelGains(panned, source, format.kind, format.channels, gains);
                bytes = panned;
            }
            if (!platform.audio.putStreamData(voice.stream, bytes)) {
                if (!voice.looping) finishFeed(voice);
                return false;
            }
            voice.cursor = run.start + run.len;
            pushed += run.len;
        }
    }

    /// Marks a non-looping voice as fed, and flushes its stream so the last of the sound plays out. A looping voice is
    /// never done, and its queue has to stay full, so it is never flushed.
    fn finishFeed(voice: *Playing) void {
        if (voice.looping) return;
        platform.audio.flushStream(voice.stream);
        voice.fed = true;
    }
};

test "a silent Audio refuses to play and ignores the other calls" {
    var audio = Audio{};
    defer audio.deinit();

    const sound = Sound{ .allocator = std.testing.allocator, .samples = &.{} };
    try std.testing.expectError(error.StreamFailed, audio.play(&sound, .{}));
    try std.testing.expectError(error.NoDevice, audio.loadSound(std.testing.allocator, "assets/wind1.wav"));

    const never = Handle{ .index = 0, .generation = 0 };
    try std.testing.expect(!audio.isPlaying(never));
    audio.stop(never);
    audio.update();
    audio.setMasterGain(0.5);
    audio.setListener(.{ .x = 10, .y = 10 });
    audio.setPosition(never, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(usize, 0), audio.playing.count());
    try std.testing.expectEqual(@as(f32, 0.5), audio.master_gain);
}

test "a Sound frees its samples with the allocator it was made with" {
    const samples = try std.testing.allocator.alloc(u8, 8);
    var sound = Sound{ .allocator = std.testing.allocator, .samples = samples };
    // std.testing.allocator reports a leak if deinit does not free these bytes.
    sound.deinit();
}

test "master gain and play options clamp invalid values and empty sounds" {
    var audio = Audio{};
    defer audio.deinit();

    audio.setMasterGain(std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 0.0), audio.master_gain);

    const empty = Sound{ .allocator = std.testing.allocator, .samples = &.{} };
    try std.testing.expectError(error.StreamFailed, audio.play(&empty, .{ .gain = 2.0, .loop = false, .pan = 3.0 }));

    audio.master_gain = 1.5;
    audio.setMasterGain(5.0);
    try std.testing.expectEqual(@as(f32, 1.0), audio.master_gain);
}

test "describe reports a silent audio state with no voices" {
    var audio = Audio{};
    defer audio.deinit();
    var state = collector.AudioState{};
    audio.describe(&state);
    try std.testing.expect(!state.device_open);
    try std.testing.expectEqual(@as(u32, 0), state.voices_busy);
    try std.testing.expectEqual(@as(u32, max_voices), state.voices_max);
    try std.testing.expectEqual(@as(u8, 0), state.listed_count);
}

test "a positional voice's attenuation and pan come from the listener, and its own pan is added to them" {
    var audio = Audio{};
    audio.listener = .{ .x = 0, .y = 0 };
    const sound = Sound{ .allocator = std.testing.allocator, .samples = &.{} };
    var voice = Playing{
        .stream = undefined,
        .sound = &sound,
        .looping = false,
        .gain = 1,
        .pan = -0.25,
        .position = .{ .x = 80, .y = 0 },
        .range = 160,
    };
    audio.refreshMix(&voice);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), voice.attenuation, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), voice.effective_pan, 1e-6);

    // Moving the listener onto the source makes the sound full and centered, apart from the voice's own pan.
    audio.listener = .{ .x = 80, .y = 0 };
    audio.refreshMix(&voice);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), voice.attenuation, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.25), voice.effective_pan, 1e-6);

    // A voice with no place keeps full level, with only its own pan.
    voice.position = null;
    audio.refreshMix(&voice);
    try std.testing.expectEqual(@as(f32, 1.0), voice.attenuation);
    try std.testing.expectEqual(@as(f32, -0.25), voice.effective_pan);
}

test "the lookahead is a tenth of a second of whole frames, and at least one frame" {
    const stereo_float = platform.PcmFormat{ .sample_rate = 48000, .channels = 2, .kind = .float32 };
    try std.testing.expectEqual(@as(usize, 4800 * 8), lookaheadBytes(stereo_float));
    const tiny = platform.PcmFormat{ .sample_rate = 1, .channels = 1, .kind = .uint8 };
    try std.testing.expectEqual(@as(usize, 1), lookaheadBytes(tiny));
}
