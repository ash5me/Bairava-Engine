//! Sound output: the API the engine and the game use. `Audio` owns the voices and the playback policy.
//! Every device and stream operation goes through `platform.audio`, so no SDL type reaches this file.
//! Sound bytes come through `platform.files`. IMA sidecars are decoded in `ima.zig`, which is SDL-free.

const std = @import("std");

const platform = @import("../platform/platform.zig");
const ima = @import("ima.zig");
const rules = @import("voices.zig");
const logging = @import("../logging/log.zig");

const log = logging.scoped("audio");

/// Voices that can play at once.
pub const max_voices: u16 = 32;

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
};

/// What a busy voice holds.
const Playing = struct {
    stream: *platform.AudioStream,
    sound: *const Sound,
    looping: bool,
    /// The voice's own gain, kept so the master gain can change without losing it.
    gain: f32,
};

pub const Audio = struct {
    /// The open device, or null when none is open.
    device: ?*platform.AudioDevice = null,
    /// The format the engine mixes in. Sounds convert to it, and voice streams use it on both sides.
    format: platform.PcmFormat = undefined,
    playing: rules.Pool(Playing, max_voices) = .{},
    master_gain: f32 = 1.0,

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

    /// Starts `sound` on a free voice and returns its handle. The voice ends by itself when a
    /// non-looping sound finishes, or when `stop` is called.
    pub fn play(self: *Audio, sound: *const Sound, options: PlayOptions) Error!Handle {
        const device = self.device orelse return error.NoDevice;

        const stream = platform.audio.createStream(self.format) orelse {
            log.warn("could not create an audio stream", .{});
            return error.StreamFailed;
        };
        // Until the voice is stored, this stream belongs to us and must be closed on any error.
        var adopted = false;
        defer if (!adopted) platform.audio.destroyStream(stream);

        platform.audio.setStreamGain(stream, rules.effectiveGain(options.gain, self.master_gain));
        if (!platform.audio.putStreamData(stream, sound.samples)) {
            log.warn("could not queue sound data", .{});
            return error.StreamFailed;
        }
        // Flushing pushes out whatever the stream still holds, so a non-looping sound can finish.
        // A looping sound needs its queue kept full instead, so it isn't flushed.
        if (!options.loop) platform.audio.flushStream(stream);

        if (!platform.audio.bindStream(device, stream)) {
            log.warn("could not bind the audio stream", .{});
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
        platform.audio.destroyStream(playing.stream);
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
            platform.audio.setStreamGain(entry.payload.stream, rules.effectiveGain(entry.payload.gain, gain));
        }
    }

    /// Call once per frame. It frees voices that have finished, and it gives each looping voice another
    /// copy of its sound when the queue runs short.
    pub fn update(self: *Audio) void {
        if (self.device == null) return;
        var it = self.playing.iterator();
        while (it.next()) |entry| {
            const playing = entry.payload;
            const queued = platform.audio.streamQueuedBytes(playing.stream);
            const available = platform.audio.streamAvailableBytes(playing.stream);
            if (rules.isFinished(playing.looping, queued, available)) {
                const stream = playing.stream;
                _ = self.playing.release(entry.handle);
                platform.audio.destroyStream(stream);
            } else if (playing.looping and rules.needsLoopCopy(queued, @intCast(playing.sound.samples.len))) {
                _ = platform.audio.putStreamData(playing.stream, playing.sound.samples);
            }
        }
    }
};

test "a silent Audio refuses to play and ignores the other calls" {
    var audio = Audio{};
    defer audio.deinit();

    const sound = Sound{ .allocator = std.testing.allocator, .samples = &.{} };
    try std.testing.expectError(error.NoDevice, audio.play(&sound, .{}));
    try std.testing.expectError(error.NoDevice, audio.loadSound(std.testing.allocator, "assets/wind1.wav"));

    const never = Handle{ .index = 0, .generation = 0 };
    try std.testing.expect(!audio.isPlaying(never));
    audio.stop(never);
    audio.update();
    audio.setMasterGain(0.5);
    try std.testing.expectEqual(@as(usize, 0), audio.playing.count());
    try std.testing.expectEqual(@as(f32, 0.5), audio.master_gain);
}

test "a Sound frees its samples with the allocator it was made with" {
    const samples = try std.testing.allocator.alloc(u8, 8);
    var sound = Sound{ .allocator = std.testing.allocator, .samples = samples };
    // std.testing.allocator reports a leak if deinit does not free these bytes.
    sound.deinit();
}
