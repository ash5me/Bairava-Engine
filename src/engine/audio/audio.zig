//! Sound output: the API the engine and the game use. `Audio` owns the voices and the playback policy.
//! Every device and stream operation goes through `platform.audio`, so no SDL type reaches this file.
//! Sound bytes come through `platform.files`. IMA sidecars are decoded in `ima.zig`, and long sounds are read in
//! `streaming.zig`. Both are SDL-free. Positional sounds are placed by `spatial.zig`: their loudness and pan follow the
//! listener, and their bytes are panned as they are queued.
//!
//! Two kinds of sound play. A `Sound` is read whole and converted once, which suits short effects. A `StreamedSound`
//! stays on disk: each voice that plays it opens its own reader and decodes a chunk at a time, which suits music and
//! ambience. See docs/audio-streaming.md.

const std = @import("std");

const platform = @import("../platform/platform.zig");
const ima = @import("ima.zig");
const rules = @import("voices.zig");
const spatial = @import("spatial.zig");
const streaming = @import("streaming.zig");
const logging = @import("../logging/log.zig");
const collector = @import("../diagnostics/collector.zig");

const log = logging.scoped("audio");

/// Voices that can play at once.
pub const max_voices: u16 = 32;

/// Bytes of scratch space for panning. Every panned run fits here, whatever the sound's length.
pub const scratch_bytes: usize = 8192;

/// Bytes a streamed voice moves at a time: decoded sound on its way to the converter, and converted sound on its way to
/// the panner. Every voice shares the buffer, because each one is done with it before the next one starts.
pub const stream_chunk_bytes: usize = 4096;

/// A streamed voice that is not positional keeps this many seconds of sound queued ahead of playback. A stall in the game
/// loop shorter than that does not reach the output.
const stream_lookahead_seconds: u32 = 1;

/// The most steps one update may spend on a streamed voice. A step moves one chunk, so the cap only stops a stream that
/// never reaches its target from holding the frame. The voice picks up where it stopped on the next update.
const max_stream_steps: u32 = 4096;

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

/// A long sound that stays on disk. It records the packaged path and the format, and nothing else: each `playStreamed`
/// opens its own reader, and the reader closes when its voice ends, so there is nothing to free. Make one with
/// `openStreamed`. The file it names must not change while a voice plays it.
pub const StreamedSound = struct {
    /// The packaged path the sound streams from, relative to the executable's folder. A `.ima` sidecar is named here
    /// when one was chosen.
    path_buf: [platform.max_full_path]u8 = undefined,
    path_len: u16 = 0,
    /// The format the sound's frames come in, before they are converted to the device's format.
    format: platform.PcmFormat,
    /// The number of sample frames in the sound.
    frames: u64,

    pub fn path(self: *const StreamedSound) []const u8 {
        return self.path_buf[0..self.path_len];
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

/// Where a voice's sound comes from.
const Source = union(enum) {
    /// A sound loaded whole. The voice feeds it from memory, by a cursor.
    memory: *const Sound,
    /// A sound read from disk a chunk at a time.
    streamed: Streamed,
};

/// What a streamed voice holds: its reader, and the converter from the reader's format to the device's.
const Streamed = struct {
    file: *platform.OpenFile,
    decoder: streaming.Decoder,
    converter: *platform.AudioStream,
    /// The file's size in bytes. Diagnostics report it as the voice's sound length.
    file_bytes: u64,
    /// True once the decoder has no more sound and the converter has been flushed, so only its last output is left.
    input_done: bool = false,
};

/// What a busy voice holds.
const Playing = struct {
    stream: *platform.AudioStream,
    source: Source,
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
    /// How many bytes of a memory sound have been fed, counted from its start. A looping voice wraps back to zero.
    cursor: usize = 0,
    /// True once a non-looping voice has been fed its whole sound, or was refused partway and cut short.
    fed: bool = false,
};

/// How many bytes a positional voice keeps queued ahead of playback, for a device format.
fn lookaheadBytes(format: platform.PcmFormat) usize {
    const frames = @max(format.sample_rate / positional_lookahead_divisor, 1);
    return @as(usize, frames) * spatial.frameBytes(format);
}

/// How many bytes a streamed voice keeps queued. A positional voice uses the same short lookahead as a loaded one, so a
/// change of place is heard promptly. Any other streamed voice keeps a second of sound queued, so a hitch in the game
/// loop does not reach the output.
fn voiceTargetBytes(format: platform.PcmFormat, positional: bool) usize {
    if (positional) return lookaheadBytes(format);
    return rules.streamTargetBytes(format.sample_rate, spatial.frameBytes(format), stream_lookahead_seconds);
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
    /// Holds one chunk of a streamed voice at a time, decoded or converted. Every voice shares it, like `scratch`.
    stream_chunk: [stream_chunk_bytes]u8 align(16) = undefined,

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
        while (it.next()) |entry| self.retire(entry.handle);
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

    /// Opens a long sound to stream from disk. `relative` names the WAV, relative to the executable's folder, as for
    /// `loadSound`, and a build-encoded IMA sidecar is preferred when one exists. Only the header is read here. Use this
    /// for music and ambience. Short effects load better with `loadSound`.
    pub fn openStreamed(self: *const Audio, relative: []const u8) Error!StreamedSound {
        if (self.device == null) return error.NoDevice;
        var sidecar_buf: [platform.max_full_path]u8 = undefined;
        if (std.fmt.bufPrint(&sidecar_buf, "{s}.ima", .{relative})) |sidecar| {
            if (probeStreamed(sidecar)) |found| {
                return found;
            } else |err| {
                if (err != error.NotFound) log.warn("could not stream audio sidecar '{s}': {s}; trying WAV source", .{ sidecar, @errorName(err) });
            }
        } else |_| {}
        return probeStreamed(relative) catch |err| {
            log.warn("could not stream '{s}': {s}", .{ relative, @errorName(err) });
            return error.LoadFailed;
        };
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
        return self.startVoice(device, .{ .memory = sound }, options);
    }

    /// Starts a streamed sound on a free voice, and returns its handle. It takes the same options and has the same
    /// lifetime as `play`. The voice opens its own reader, which closes when the voice ends, so the `StreamedSound` is
    /// only read here, at the start.
    pub fn playStreamed(self: *Audio, sound: *const StreamedSound, options: PlayOptions) Error!Handle {
        const device = self.device orelse return error.NoDevice;
        const reader = try self.openVoiceReader(sound.path());
        return self.startVoice(device, .{ .streamed = reader }, options);
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
        self.retire(handle);
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
                .sound_bytes = soundBytes(entry.payload),
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
            if (isEmptyMemory(voice)) {
                self.retire(entry.handle);
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
                self.retire(entry.handle);
            }
        }
    }

    /// Ends the voice behind `handle` and frees everything it holds. A stale handle does nothing.
    fn retire(self: *Audio, handle: Handle) void {
        var done = self.playing.release(handle) orelse return;
        destroyPlaying(&done);
    }

    /// Creates the voice's stream, feeds it, binds it to the device, and stores the voice. The source is owned from here
    /// on: if anything fails, it is freed here, so the caller never frees it.
    fn startVoice(self: *Audio, device: *platform.AudioDevice, source: Source, options: PlayOptions) Error!Handle {
        var owned = source;
        const voice_stream = platform.audio.createStream(self.format) orelse {
            log.warn("could not create an audio stream", .{});
            destroySource(&owned);
            return error.StreamFailed;
        };
        var voice = Playing{
            .stream = voice_stream,
            .source = owned,
            .looping = options.loop,
            .gain = clampGain(options.gain),
            .pan = spatial.clampPan(options.pan),
            .position = options.position,
            .range = options.range,
        };
        // Until the voice is stored, it belongs to us and everything it holds is freed on any error.
        var adopted = false;
        defer if (!adopted) destroyPlaying(&voice);

        self.refreshMix(&voice);
        self.applyGain(&voice);
        if (!self.feed(&voice)) {
            log.warn("could not queue sound data", .{});
            return error.StreamFailed;
        }
        if (!platform.audio.bindStream(device, voice_stream)) {
            log.warn("could not bind the audio stream", .{});
            return error.StreamFailed;
        }
        const handle = self.playing.acquire(voice) orelse return error.NoFreeVoice;
        adopted = true;
        return handle;
    }

    /// Opens the packaged file at `path` for one voice, along with the converter from its format to the device's. On
    /// failure, everything opened so far is closed again.
    fn openVoiceReader(self: *const Audio, path: []const u8) Error!Streamed {
        const file = platform.files.open(.packaged, path) catch |err| {
            log.warn("could not open '{s}': {s}", .{ path, @errorName(err) });
            return error.LoadFailed;
        };
        errdefer platform.files.close(file);
        const size = platform.files.size(file) catch |err| {
            log.warn("could not size '{s}': {s}", .{ path, @errorName(err) });
            return error.LoadFailed;
        };
        const decoder = streaming.open(sourceOf(file, size)) catch |err| {
            log.warn("could not stream '{s}': {s}", .{ path, @errorName(err) });
            return error.LoadFailed;
        };
        const converter = platform.audio.createConverter(decoder.format(), self.format) orelse {
            log.warn("could not convert '{s}' to the device format", .{path});
            return error.ConvertFailed;
        };
        return .{ .file = file, .decoder = decoder, .converter = converter, .file_bytes = size };
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

    /// Keeps a voice's stream fed. Returns false when the platform refuses the data.
    fn feed(self: *Audio, voice: *Playing) bool {
        return switch (voice.source) {
            .memory => |sound| self.feedMemory(voice, sound),
            .streamed => |*streamed| self.feedStreamed(voice, streamed),
        };
    }

    /// Queues runs of a loaded sound until the stream holds its target. A run that needs panning is written to the scratch
    /// buffer first. A non-looping voice is flushed once its last run is queued, so it can finish. Returns false when
    /// the platform refuses the data. A non-looping voice that is refused is marked fed too, so it ends once its
    /// stream drains.
    fn feedMemory(self: *Audio, voice: *Playing, sound: *const Sound) bool {
        if (voice.fed) return true;
        const format = self.format;
        const frame = spatial.frameBytes(format);
        const whole = rules.wholeBytes(sound.samples.len, frame);
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
            const source = sound.samples[run.start..][0..run.len];
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

    /// Keeps a streamed voice fed. Converted sound goes to the voice's stream first. When the converter has none ready,
    /// the decoder reads its next chunk into the converter. Returns false when the platform refuses the data.
    fn feedStreamed(self: *Audio, voice: *Playing, streamed: *Streamed) bool {
        if (voice.fed) return true;
        const format = self.format;
        const frame = spatial.frameBytes(format);
        const target = voiceTargetBytes(format, voice.position != null);
        const gains = spatial.channelGains(voice.effective_pan);
        const pans = spatial.needsPan(format.channels, gains);
        // Whole frames only, so a chunk of converted sound never splits a frame.
        const chunk_limit = stream_chunk_bytes - stream_chunk_bytes % frame;
        var pushed: usize = 0;
        var steps: u32 = 0;
        while (steps < max_stream_steps) : (steps += 1) {
            if (pushed >= target) return true;
            const queued = platform.audio.streamQueuedBytes(voice.stream);
            if (!rules.needsInput(queued, target)) return true;

            const ready = platform.audio.streamAvailableBytes(streamed.converter);
            if (ready > 0) {
                const want: usize = @min(chunk_limit, @as(usize, @intCast(ready)));
                const got = platform.audio.getStreamData(streamed.converter, self.stream_chunk[0..want]);
                if (got < 0) {
                    log.warn("could not read converted audio", .{});
                    refuseStreamed(voice);
                    return false;
                }
                if (got == 0) return true;
                const n: usize = @intCast(got);
                var bytes: []const u8 = self.stream_chunk[0..n];
                if (pans) {
                    spatial.applyChannelGains(self.scratch[0..n], self.stream_chunk[0..n], format.kind, format.channels, gains);
                    bytes = self.scratch[0..n];
                }
                if (!platform.audio.putStreamData(voice.stream, bytes)) {
                    log.warn("could not queue sound data", .{});
                    refuseStreamed(voice);
                    return false;
                }
                pushed += n;
                continue;
            }

            if (streamed.input_done) {
                // The converter has given up its last sound, and the decoder had none left, so the voice is fed.
                voice.fed = true;
                return true;
            }
            if (!self.pumpInput(voice, streamed)) finishInput(voice, streamed);
        }
        return true;
    }

    /// Moves the decoder's next chunk into the converter. A looping voice starts its sound again at the end, and its
    /// converter keeps going, so the loop joins up. Returns false when there is no more sound, or the sound failed.
    fn pumpInput(self: *Audio, voice: *Playing, streamed: *Streamed) bool {
        var got = streamed.decoder.read(self.stream_chunk[0..]) catch |err| {
            log.warn("streamed sound stopped early: {s}", .{@errorName(err)});
            return false;
        };
        if (got == 0 and voice.looping) {
            streamed.decoder.rewind();
            got = streamed.decoder.read(self.stream_chunk[0..]) catch |err| {
                log.warn("streamed sound stopped early: {s}", .{@errorName(err)});
                return false;
            };
        }
        if (got == 0) return false;
        if (!platform.audio.putStreamData(streamed.converter, self.stream_chunk[0..got])) {
            log.warn("could not convert streamed sound data", .{});
            return false;
        }
        return true;
    }

    /// Ends a streamed voice's input. The converter is flushed so its last sound comes out, and the voice finishes once
    /// that has played. A looping voice that loses its sound stops looping for the same reason.
    fn finishInput(voice: *Playing, streamed: *Streamed) void {
        voice.looping = false;
        streamed.input_done = true;
        platform.audio.flushStream(streamed.converter);
    }

    /// Ends a streamed voice the platform refused. It finishes once its stream drains, and it never loops again.
    fn refuseStreamed(voice: *Playing) void {
        voice.looping = false;
        voice.fed = true;
        platform.audio.flushStream(voice.stream);
    }

    /// Marks a non-looping voice as fed, and flushes its stream so the last of the sound plays out. A looping voice is
    /// never done, and its queue has to stay full, so it is never flushed.
    fn finishFeed(voice: *Playing) void {
        if (voice.looping) return;
        platform.audio.flushStream(voice.stream);
        voice.fed = true;
    }
};

/// The reader for a streamed sound's file. The platform file is the context.
fn sourceOf(file: *platform.OpenFile, size: u64) streaming.Source {
    return .{ .context = file, .readFn = readOpenFile, .size = size };
}

fn readOpenFile(context: *anyopaque, offset: u64, dst: []u8) streaming.ReadError!usize {
    const file: *platform.OpenFile = @ptrCast(context);
    return platform.files.readAt(file, offset, dst) catch error.ReadFailed;
}

const ProbeError = platform.FileError || streaming.Error;

/// Reads the header of the packaged file at `path`, and returns the sound it describes. The file is closed again, since a
/// voice opens its own reader when it plays.
fn probeStreamed(path: []const u8) ProbeError!StreamedSound {
    if (path.len > platform.max_full_path) return error.PathTooLong;
    const file = try platform.files.open(.packaged, path);
    defer platform.files.close(file);
    const size = try platform.files.size(file);
    const decoder = try streaming.open(sourceOf(file, size));
    var sound = StreamedSound{ .format = decoder.format(), .frames = decoder.frameCount() };
    @memcpy(sound.path_buf[0..path.len], path);
    sound.path_len = @intCast(path.len);
    return sound;
}

/// Frees what a voice's source holds: a streamed voice's converter and reader. A loaded sound holds nothing.
fn destroySource(source: *Source) void {
    switch (source.*) {
        .memory => {},
        .streamed => |*streamed| {
            platform.audio.destroyStream(streamed.converter);
            platform.files.close(streamed.file);
        },
    }
}

/// Frees everything a busy voice holds: its device stream and its source.
fn destroyPlaying(voice: *Playing) void {
    platform.audio.destroyStream(voice.stream);
    destroySource(&voice.source);
}

fn isEmptyMemory(voice: *const Playing) bool {
    return switch (voice.source) {
        .memory => |sound| sound.samples.len == 0,
        .streamed => false,
    };
}

/// The length of a voice's sound in bytes: its samples for a loaded sound, or its file's size for a streamed one.
fn soundBytes(voice: *const Playing) usize {
    return switch (voice.source) {
        .memory => |sound| sound.samples.len,
        .streamed => |streamed| @intCast(streamed.file_bytes),
    };
}

test "a silent Audio refuses to play, open, and stream, and ignores the other calls" {
    var audio = Audio{};
    defer audio.deinit();

    const sound = Sound{ .allocator = std.testing.allocator, .samples = &.{} };
    try std.testing.expectError(error.StreamFailed, audio.play(&sound, .{}));
    try std.testing.expectError(error.NoDevice, audio.loadSound(std.testing.allocator, "assets/wind1.wav"));
    try std.testing.expectError(error.NoDevice, audio.openStreamed("assets/wind1.wav"));

    const streamed = StreamedSound{ .format = .{ .sample_rate = 22050, .channels = 1, .kind = .int16 }, .frames = 4 };
    try std.testing.expectError(error.NoDevice, audio.playStreamed(&streamed, .{}));

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

test "a streamed sound's path is the bytes it was given" {
    var sound = StreamedSound{ .format = .{ .sample_rate = 22050, .channels = 1, .kind = .int16 }, .frames = 4 };
    @memcpy(sound.path_buf[0..9], "music.wav");
    sound.path_len = 9;
    try std.testing.expectEqualStrings("music.wav", sound.path());
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
        .source = .{ .memory = &sound },
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

test "a streamed voice keeps a second queued, or a positional voice's short lookahead" {
    const stereo_float = platform.PcmFormat{ .sample_rate = 48000, .channels = 2, .kind = .float32 };
    try std.testing.expectEqual(@as(usize, 48000 * 8), voiceTargetBytes(stereo_float, false));
    try std.testing.expectEqual(@as(usize, 4800 * 8), voiceTargetBytes(stereo_float, true));
}

test "a streamed voice reports its file's size as its sound length" {
    const streamed = Streamed{ .file = undefined, .decoder = undefined, .converter = undefined, .file_bytes = 1234 };
    const voice = Playing{
        .stream = undefined,
        .source = .{ .streamed = streamed },
        .looping = false,
        .gain = 1,
        .pan = 0,
        .position = null,
        .range = spatial.default_range,
    };
    try std.testing.expectEqual(@as(usize, 1234), soundBytes(&voice));
    try std.testing.expect(!isEmptyMemory(&voice));
}
