//! SDL3 audio: the playback device, the streams that play on it, format conversion, and WAV decoding.
//! This is the only file that calls SDL's audio functions. Engine code reaches them through
//! `platform.audio`, which takes and returns the opaque handles and `PcmFormat` from types.zig, so no
//! SDL audio type crosses into the engine. WAV bytes arrive from the caller, who reads them through
//! `platform.files`, so this file does no file I/O.
//!
//! A device handle holds the SDL device id in the pointer's bits. A stream handle is the SDL stream
//! pointer itself. Both are meaningful only in this file.

const std = @import("std");

const c = @import("sdl.zig").c;
const types = @import("../types.zig");
const logging = @import("../../logging/log.zig");

const log = logging.scoped("audio");

/// The device id SDL uses for "the default playback device".
const default_playback: c.SDL_AudioDeviceID = 0xFFFF_FFFF;

/// Opens the default playback device. Returns null when there is none, and logs why. The audio
/// subsystem is started by `platform.init`, and if that failed, `SDL_WasInit` reports it here.
pub fn openDefault() ?types.OpenedAudio {
    if (c.SDL_WasInit(c.SDL_INIT_AUDIO) == 0) return null;

    const id = c.SDL_OpenAudioDevice(default_playback, null);
    if (id == 0) {
        log.warn("no playback device, continuing silent: {s}", .{c.SDL_GetError()});
        return null;
    }
    var spec: c.SDL_AudioSpec = undefined;
    var sample_frames: c_int = 0;
    if (!c.SDL_GetAudioDeviceFormat(id, &spec, &sample_frames)) {
        log.warn("could not read the device format, continuing silent: {s}", .{c.SDL_GetError()});
        c.SDL_CloseAudioDevice(id);
        return null;
    }
    // Devices open paused, so start this one.
    _ = c.SDL_ResumeAudioDevice(id);

    // The engine mixes in a format it can name. When the device uses another one, mix in float32 at
    // the device's rate and channel count. A bound stream converts to the device's own format.
    const format = fromSpec(spec) orelse types.PcmFormat{
        .sample_rate = @intCast(spec.freq),
        .channels = @intCast(spec.channels),
        .kind = .float32,
    };
    log.info("playback device open: {d} Hz, {d} channels", .{ format.sample_rate, format.channels });
    return .{ .device = deviceHandle(id), .format = format };
}

/// Closes a device. Streams bound to it must already be destroyed.
pub fn closeDevice(device: *types.AudioDevice) void {
    c.SDL_CloseAudioDevice(deviceId(device));
}

/// A stream that takes and returns `format` on both sides. When it is bound, SDL converts its output to
/// the device's format.
pub fn createStream(format: types.PcmFormat) ?*types.AudioStream {
    const spec = toSpec(format) orelse return null;
    const stream = c.SDL_CreateAudioStream(&spec, &spec) orelse return null;
    return streamHandle(stream);
}

/// Binds a stream to a device, so the device plays it. Returns false if SDL refuses.
pub fn bindStream(device: *types.AudioDevice, stream: *types.AudioStream) bool {
    return c.SDL_BindAudioStream(deviceId(device), streamOf(stream));
}

/// Unbinds and frees a stream. Unbinding first is harmless, and it doesn't depend on whether SDL
/// unbinds when a stream is destroyed.
pub fn destroyStream(stream: *types.AudioStream) void {
    const s = streamOf(stream);
    c.SDL_UnbindAudioStream(s);
    c.SDL_DestroyAudioStream(s);
}

/// Queues bytes on a stream, in the stream's format. Returns false if SDL refuses.
pub fn putStreamData(stream: *types.AudioStream, bytes: []const u8) bool {
    if (bytes.len > std.math.maxInt(c_int)) return false;
    return c.SDL_PutAudioStreamData(streamOf(stream), bytes.ptr, @intCast(bytes.len));
}

/// Pushes out whatever the stream still holds, so a non-looping sound can finish.
pub fn flushStream(stream: *types.AudioStream) void {
    _ = c.SDL_FlushAudioStream(streamOf(stream));
}

/// Sets the gain the stream plays at.
pub fn setStreamGain(stream: *types.AudioStream, gain: f32) void {
    _ = c.SDL_SetAudioStreamGain(streamOf(stream), gain);
}

/// Bytes queued on the stream as input.
pub fn streamQueuedBytes(stream: *types.AudioStream) i32 {
    return @intCast(c.SDL_GetAudioStreamQueued(streamOf(stream)));
}

/// Converted bytes the stream holds ready to play.
pub fn streamAvailableBytes(stream: *types.AudioStream) i32 {
    return @intCast(c.SDL_GetAudioStreamAvailable(streamOf(stream)));
}

/// Decodes WAV bytes. The samples come back in the file's own format when the engine can name it.
/// Otherwise they come back as int16 at the file's rate and channel count. The caller frees
/// `samples` with the same allocator. This needs no audio device.
pub fn decodeWav(allocator: std.mem.Allocator, bytes: []const u8) types.AudioError!types.PcmBuffer {
    if (bytes.len == 0 or bytes.len > std.math.maxInt(c_int)) return error.DecodeFailed;
    // SDL reads the caller's bytes in place. SDL_LoadWAV_IO closes the stream, which frees it.
    const io = c.SDL_IOFromConstMem(bytes.ptr, bytes.len) orelse return error.DecodeFailed;
    var spec: c.SDL_AudioSpec = undefined;
    var buf: [*c]u8 = null;
    var buf_len: u32 = 0;
    if (!c.SDL_LoadWAV_IO(io, true, &spec, &buf, &buf_len)) {
        log.warn("could not decode WAV: {s}", .{c.SDL_GetError()});
        return error.DecodeFailed;
    }
    defer c.SDL_free(@ptrCast(buf));
    const raw = bytesOf(buf, buf_len);

    if (fromSpec(spec)) |format| {
        return .{ .samples = try allocator.dupe(u8, raw), .format = format };
    }
    // An unusual WAV format: let SDL convert it to int16 at the file's own rate and channels.
    const target = types.PcmFormat{
        .sample_rate = @intCast(spec.freq),
        .channels = @intCast(spec.channels),
        .kind = .int16,
    };
    const dst = toSpec(target) orelse return error.DecodeFailed;
    return .{ .samples = try convertBytes(allocator, spec, raw, dst), .format = target };
}

/// Converts interleaved PCM from `src` to `dst`. The caller frees the result with `allocator`. Rate,
/// channel count, and sample kind may all change. This needs no audio device.
pub fn convert(allocator: std.mem.Allocator, src: types.PcmFormat, bytes: []const u8, dst: types.PcmFormat) types.AudioError![]u8 {
    const src_spec = toSpec(src) orelse return error.ConvertFailed;
    const dst_spec = toSpec(dst) orelse return error.ConvertFailed;
    return convertBytes(allocator, src_spec, bytes, dst_spec);
}

fn convertBytes(allocator: std.mem.Allocator, src: c.SDL_AudioSpec, bytes: []const u8, dst: c.SDL_AudioSpec) types.AudioError![]u8 {
    if (bytes.len > std.math.maxInt(c_int)) return error.ConvertFailed;
    var out: [*c]u8 = null;
    var out_len: c_int = 0;
    if (!c.SDL_ConvertAudioSamples(&src, bytes.ptr, @intCast(bytes.len), &dst, &out, &out_len)) {
        log.warn("could not convert audio: {s}", .{c.SDL_GetError()});
        return error.ConvertFailed;
    }
    defer c.SDL_free(@ptrCast(out));
    if (out_len <= 0 or out == null) return allocator.alloc(u8, 0);
    return allocator.dupe(u8, bytesOf(out, @intCast(out_len)));
}

fn deviceHandle(id: c.SDL_AudioDeviceID) *types.AudioDevice {
    return @ptrFromInt(@as(usize, id));
}

fn deviceId(device: *types.AudioDevice) c.SDL_AudioDeviceID {
    return @intCast(@intFromPtr(device));
}

fn streamHandle(stream: *c.SDL_AudioStream) *types.AudioStream {
    return @ptrCast(stream);
}

fn streamOf(stream: *types.AudioStream) *c.SDL_AudioStream {
    return @ptrCast(stream);
}

/// The bytes SDL returned, or an empty slice when it returned none.
fn bytesOf(buf: [*c]u8, len: u32) []const u8 {
    if (buf == null or len == 0) return &.{};
    const ptr: [*]const u8 = @ptrCast(buf);
    return ptr[0..len];
}

fn toSpec(format: types.PcmFormat) ?c.SDL_AudioSpec {
    if (format.sample_rate == 0 or format.channels == 0 or format.sample_rate > std.math.maxInt(c_int)) return null;
    var spec = std.mem.zeroes(c.SDL_AudioSpec);
    spec.format = switch (format.kind) {
        .uint8 => c.SDL_AUDIO_U8,
        .int16 => c.SDL_AUDIO_S16,
        .int32 => c.SDL_AUDIO_S32,
        .float32 => c.SDL_AUDIO_F32,
    };
    spec.channels = format.channels;
    spec.freq = @intCast(format.sample_rate);
    return spec;
}

fn fromSpec(spec: c.SDL_AudioSpec) ?types.PcmFormat {
    if (spec.freq <= 0 or spec.channels <= 0 or spec.channels > std.math.maxInt(u8)) return null;
    const kind: types.SampleKind = if (spec.format == c.SDL_AUDIO_U8)
        .uint8
    else if (spec.format == c.SDL_AUDIO_S16)
        .int16
    else if (spec.format == c.SDL_AUDIO_S32)
        .int32
    else if (spec.format == c.SDL_AUDIO_F32)
        .float32
    else
        return null;
    return .{ .sample_rate = @intCast(spec.freq), .channels = @intCast(spec.channels), .kind = kind };
}

/// A 16-bit mono WAV at 22050 Hz with two samples, 1000 and -1000, built in memory so that the test
/// needs no file and no device.
const mono_wav = [_]u8{
    'R', 'I', 'F', 'F', 40, 0, 0, 0, 'W', 'A', 'V', 'E',
    'f', 'm', 't', ' ', 16, 0, 0, 0, 1, 0, 1, 0, 0x22, 0x56, 0, 0, 0x44, 0xAC, 0, 0, 2, 0, 16, 0,
    'd', 'a', 't', 'a', 4, 0, 0, 0, 0xE8, 0x03, 0x18, 0xFC,
};

test "WAV decodes from bytes without an audio device" {
    const decoded = try decodeWav(std.testing.allocator, &mono_wav);
    defer std.testing.allocator.free(decoded.samples);
    try std.testing.expectEqual(@as(u32, 22050), decoded.format.sample_rate);
    try std.testing.expectEqual(@as(u8, 1), decoded.format.channels);
    try std.testing.expectEqual(types.SampleKind.int16, decoded.format.kind);
    try std.testing.expectEqualSlices(u8, &.{ 0xE8, 0x03, 0x18, 0xFC }, decoded.samples);
}

test "WAV decoding rejects bytes that are not a WAV file" {
    try std.testing.expectError(error.DecodeFailed, decodeWav(std.testing.allocator, "this is not a wav file"));
    try std.testing.expectError(error.DecodeFailed, decodeWav(std.testing.allocator, ""));
}

test "conversion to the same format returns the same samples" {
    const fmt = types.PcmFormat{ .sample_rate = 22050, .channels = 1, .kind = .int16 };
    const out = try convert(std.testing.allocator, fmt, &.{ 0xE8, 0x03, 0x18, 0xFC }, fmt);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, &.{ 0xE8, 0x03, 0x18, 0xFC }, out);
}

test "conversion to float stereo gives whole frames" {
    const src = types.PcmFormat{ .sample_rate = 22050, .channels = 1, .kind = .int16 };
    const dst = types.PcmFormat{ .sample_rate = 48000, .channels = 2, .kind = .float32 };
    const out = try convert(std.testing.allocator, src, &.{ 0xE8, 0x03, 0x18, 0xFC }, dst);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len > 0);
    // Two channels of four-byte floats make eight bytes per frame.
    try std.testing.expectEqual(@as(usize, 0), out.len % 8);
}
