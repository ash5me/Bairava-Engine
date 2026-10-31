//! Sound output through SDL3 audio streams.
//!
//! One playback device opens when the engine starts, in the device's own format. Each sound that
//! plays gets its own `SDL_AudioStream`, bound to that device, and SDL mixes every bound stream.
//! Sounds convert to the device's format once, when they load. A playing voice never converts,
//! and its queued byte counts are in the same units as the samples it was given.
//!
//! Voices are fixed in number (`max_voices`). Playing when every voice is busy returns
//! `error.NoFreeVoice`. A missing audio device doesn't stop the game: `Audio.init` logs a warning
//! and the object stays silent, so every `play` returns `error.NoDevice`.
//!
//! Call `update` once per frame. It frees voices that have finished, and it keeps looping voices
//! fed. A looping voice reads its sound again on every top-up, so the `Sound` must stay loaded
//! until the voice stops. The SDL-free rules live in `audio_voices.zig`.

const std = @import("std");

const c = @import("sdl.zig").c;
const rules = @import("../../audio/voices.zig");
const ima = @import("../../audio/ima.zig");
pub const Handle = rules.Handle;

const log = @import("../../logging/log.zig").scoped("audio");
/// Voices that can play at once.
pub const max_voices: u16 = 32;

/// The device id SDL uses for "the default playback device".
const default_playback: c.SDL_AudioDeviceID = 0xFFFF_FFFF;

pub const Error = error{
    /// No playback device is open, so nothing can play or load.
    NoDevice,
    /// Every voice is busy. The caller decides whether that matters.
    NoFreeVoice,
    /// The file couldn't be read or decoded as WAV or BRAD IMA ADPCM.
    LoadFailed,
    /// The decoded sound couldn't be converted to the device format.
    ConvertFailed,
    /// SDL couldn't create or bind a stream for the voice.
    StreamFailed,
};

/// A sound in the device's format, ready to play. It owns its samples, so free it with `deinit`.
pub const Sound = struct {
    samples: []u8,

    pub fn deinit(self: *Sound) void {
        // An empty sound owns no SDL buffer, so there is nothing to free.
        if (self.samples.len > 0) c.SDL_free(@ptrCast(self.samples.ptr));
        self.* = undefined;
    }
};

pub const PlayOptions = struct {
    /// Volume of this voice, from 0 (silent) to 1 (full). The master gain multiplies it.
    gain: f32 = 1.0,
    /// Repeat until stopped.
    loop: bool = false,
};

/// What a busy voice holds.
const Playing = struct {
    stream: *c.SDL_AudioStream,
    sound: *const Sound,
    looping: bool,
    /// The voice's own gain, kept so the master gain can change without losing it.
    gain: f32,
};

pub const Audio = struct {
    /// The open device, or 0 when none is open.
    device: c.SDL_AudioDeviceID = 0,
    /// The device's format. Sounds convert to it, and voice streams use it on both sides.
    format: c.SDL_AudioSpec = undefined,
    playing: rules.Pool(Playing, max_voices) = .{},
    master_gain: f32 = 1.0,

    /// Opens the default playback device. This never fails: without a device the object stays
    /// silent and logs why. The audio subsystem must already be up, since `platform.init` starts it.
    pub fn init() Audio {
        var audio: Audio = .{};
        // platform/sdl/init.zig logs why the subsystem is down, so only the silent state is left here.
        if (c.SDL_WasInit(c.SDL_INIT_AUDIO) == 0) return audio;

        const device = c.SDL_OpenAudioDevice(default_playback, null);
        if (device == 0) {
            log.warn("no playback device, continuing silent: {s}", .{c.SDL_GetError()});
            return audio;
        }

        var sample_frames: c_int = 0;
        if (!c.SDL_GetAudioDeviceFormat(device, &audio.format, &sample_frames)) {
            log.warn("could not read the device format, continuing silent: {s}", .{c.SDL_GetError()});
            c.SDL_CloseAudioDevice(device);
            return audio;
        }

        // Devices open paused, so start this one.
        _ = c.SDL_ResumeAudioDevice(device);
        audio.device = device;
        log.info("playback device open: {d} Hz, {d} channels", .{ audio.format.freq, audio.format.channels });
        return audio;
    }

    /// Stops every voice and closes the device. The audio subsystem stays up, because it belongs to
    /// `platform.shutdown`. Sounds are the caller's to free.
    pub fn deinit(self: *Audio) void {
        if (self.device == 0) return;
        var it = self.playing.iterator();
        while (it.next()) |entry| {
            const stream = entry.payload.stream;
            _ = self.playing.release(entry.handle);
            closeStream(stream);
        }
        c.SDL_CloseAudioDevice(self.device);
        self.* = .{};
    }

    /// Loads a build-encoded BRAD IMA ADPCM sidecar when present, otherwise loads the WAV source,
    /// then converts samples once to the playback device's format. `path` names the WAV input;
    /// its encoded sidecar is `path.ima`. The caller frees the result with `Sound.deinit`.
    pub fn loadSound(self: *const Audio, path: [:0]const u8) Error!Sound {
        if (self.device == 0) return error.NoDevice;
        if (try self.loadImaSidecar(path)) |sound| return sound;

        var source_spec: c.SDL_AudioSpec = undefined;
        var source_buf: [*c]u8 = null;
        var source_len: u32 = 0;
        if (!c.SDL_LoadWAV(path.ptr, &source_spec, &source_buf, &source_len)) {
            log.warn("could not load '{s}': {s}", .{ path, c.SDL_GetError() });
            return error.LoadFailed;
        }
        defer c.SDL_free(@ptrCast(source_buf));

        if (source_len > std.math.maxInt(c_int)) {
            log.warn("'{s}' is too large to play", .{path});
            return error.ConvertFailed;
        }

        var converted: [*c]u8 = null;
        var converted_len: c_int = 0;
        if (!c.SDL_ConvertAudioSamples(&source_spec, source_buf, @intCast(source_len), &self.format, &converted, &converted_len)) {
            log.warn("could not convert '{s}' to the device format: {s}", .{ path, c.SDL_GetError() });
            return error.ConvertFailed;
        }

        if (converted_len <= 0 or converted == null) {
            // Nothing to play. Free the buffer if SDL returned one, and hand back an empty sound.
            c.SDL_free(@ptrCast(converted));
            return .{ .samples = &.{} };
        }
        const ptr: [*]u8 = @ptrCast(converted);
        return .{ .samples = ptr[0..@intCast(converted_len)] };
    }

    fn loadImaSidecar(self: *const Audio, path: [:0]const u8) Error!?Sound {
        var path_buf: [4096]u8 = undefined;
        const sidecar_path = std.fmt.bufPrintZ(&path_buf, "{s}.ima", .{path}) catch return null;
        var size: usize = 0;
        const file = c.SDL_LoadFile(sidecar_path.ptr, &size) orelse return null;
        defer c.SDL_free(file);
        const bytes: [*]const u8 = @ptrCast(file);
        var decoded = ima.decode(std.heap.page_allocator, bytes[0..size]) catch |err| {
            log.warn("could not decode audio sidecar '{s}': {s}; trying WAV source", .{ sidecar_path, @errorName(err) });
            return null;
        };
        defer decoded.deinit();
        const max_audio_bytes: usize = @intCast(std.math.maxInt(c_int));
        if (@as(usize, decoded.sample_rate) > max_audio_bytes or decoded.samples.len > max_audio_bytes / @sizeOf(i16)) return error.ConvertFailed;

        var source_spec = std.mem.zeroes(c.SDL_AudioSpec);
        source_spec.format = c.SDL_AUDIO_S16;
        source_spec.channels = decoded.channels;
        source_spec.freq = @intCast(decoded.sample_rate);
        var converted: [*c]u8 = null;
        var converted_len: c_int = 0;
        const source: [*c]u8 = @ptrCast(decoded.samples.ptr);
        const source_len: c_int = @intCast(decoded.samples.len * @sizeOf(i16));
        if (!c.SDL_ConvertAudioSamples(&source_spec, source, source_len, &self.format, &converted, &converted_len)) {
            log.warn("could not convert audio sidecar '{s}' to the device format: {s}", .{ sidecar_path, c.SDL_GetError() });
            return error.ConvertFailed;
        }
        if (converted_len <= 0 or converted == null) {
            c.SDL_free(@ptrCast(converted));
            return .{ .samples = &.{} };
        }
        const samples: [*]u8 = @ptrCast(converted);
        log.debug("loaded compact audio {s} ({d} Hz, {d} channels)", .{ sidecar_path, decoded.sample_rate, decoded.channels });
        return .{ .samples = samples[0..@intCast(converted_len)] };
    }

    /// Starts `sound` on a free voice and returns its handle. The voice ends by itself when a
    /// non-looping sound finishes, or when `stop` is called.
    pub fn play(self: *Audio, sound: *const Sound, options: PlayOptions) Error!Handle {
        if (self.device == 0) return error.NoDevice;

        const stream = c.SDL_CreateAudioStream(&self.format, &self.format) orelse {
            log.warn("could not create an audio stream: {s}", .{c.SDL_GetError()});
            return error.StreamFailed;
        };
        // Until the voice is stored, this stream belongs to us and must be closed on any error.
        var adopted = false;
        defer {
            if (!adopted) closeStream(stream);
        }

        _ = c.SDL_SetAudioStreamGain(stream, rules.effectiveGain(options.gain, self.master_gain));

        const sound_len: c_int = @intCast(sound.samples.len);
        if (!c.SDL_PutAudioStreamData(stream, @ptrCast(sound.samples.ptr), sound_len)) {
            log.warn("could not queue sound data: {s}", .{c.SDL_GetError()});
            return error.StreamFailed;
        }
        // Flushing pushes out whatever the stream still holds, so a non-looping sound can finish.
        // A looping sound needs its queue kept full instead, so it isn't flushed.
        if (!options.loop) _ = c.SDL_FlushAudioStream(stream);

        if (!c.SDL_BindAudioStream(self.device, stream)) {
            log.warn("could not bind the audio stream: {s}", .{c.SDL_GetError()});
            return error.StreamFailed;
        }

        const handle = self.playing.acquire(.{
            .stream = stream,
            .sound = sound,
            .looping = options.loop,
            .gain = options.gain,
        }) orelse return error.NoFreeVoice;
        adopted = true;
        return handle;
    }

    /// Stops a voice now. A stale handle, one whose voice already ended, does nothing.
    pub fn stop(self: *Audio, handle: Handle) void {
        const playing = self.playing.release(handle) orelse return;
        closeStream(playing.stream);
    }

    /// True while the voice behind `handle` is still playing.
    pub fn isPlaying(self: *Audio, handle: Handle) bool {
        return self.playing.get(handle) != null;
    }

    /// Sets the gain every voice is multiplied by. It applies to voices already playing too.
    pub fn setMasterGain(self: *Audio, gain: f32) void {
        self.master_gain = gain;
        var it = self.playing.iterator();
        while (it.next()) |entry| {
            _ = c.SDL_SetAudioStreamGain(entry.payload.stream, rules.effectiveGain(entry.payload.gain, gain));
        }
    }

    /// Call once per frame. It frees voices that have finished, and it gives each looping voice
    /// another copy of its sound when the queue runs short.
    pub fn update(self: *Audio) void {
        if (self.device == 0) return;
        var it = self.playing.iterator();
        while (it.next()) |entry| {
            const playing = entry.payload;
            const queued = c.SDL_GetAudioStreamQueued(playing.stream);
            const available = c.SDL_GetAudioStreamAvailable(playing.stream);
            if (rules.isFinished(playing.looping, queued, available)) {
                const stream = playing.stream;
                _ = self.playing.release(entry.handle);
                closeStream(stream);
            } else if (playing.looping and rules.needsLoopCopy(queued, @intCast(playing.sound.samples.len))) {
                _ = c.SDL_PutAudioStreamData(playing.stream, @ptrCast(playing.sound.samples.ptr), @intCast(playing.sound.samples.len));
            }
        }
    }
};

/// Unbinds and frees a voice's stream. Unbinding first is harmless, and it doesn't depend on
/// whether SDL unbinds when a stream is destroyed.
fn closeStream(stream: *c.SDL_AudioStream) void {
    c.SDL_UnbindAudioStream(stream);
    c.SDL_DestroyAudioStream(stream);
}

test "a silent Audio refuses to play and ignores the other calls" {
    var audio = Audio{};
    defer audio.deinit();

    const sound = Sound{ .samples = &.{} };
    try std.testing.expectError(error.NoDevice, audio.play(&sound, .{}));
    try std.testing.expectError(error.NoDevice, audio.loadSound("assets/wind1.wav"));

    const never = Handle{ .index = 0, .generation = 0 };
    try std.testing.expect(!audio.isPlaying(never));
    audio.stop(never);
    audio.update();
    audio.setMasterGain(0.5);
    try std.testing.expectEqual(@as(usize, 0), audio.playing.count());
    try std.testing.expectEqual(@as(f32, 0.5), audio.master_gain);
}
