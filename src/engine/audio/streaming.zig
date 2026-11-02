//! Streamed reading for long sounds. A `Decoder` reads a sound a chunk at a time from a `Source`, so a voice never holds
//! the whole file. Two kinds are read: PCM or float WAV, whose sample bytes come back as they are stored, and BRAD IMA
//! ADPCM sidecars, which are decoded to int16 as they are read. The whole-file decoder in `ima.zig` and this one agree
//! sample for sample, and a test checks that for several chunk sizes.
//!
//! This file is pure. It reads only through `Source`, so its unit tests run with no device and no file system.

const std = @import("std");
const builtin = @import("builtin");

const types = @import("../platform/types.zig");
const ima = @import("ima.zig");
const spatial = @import("spatial.zig");

comptime {
    // WAV sample data is little-endian on disk, and it is returned as stored. The playback formats are native-endian,
    // so this holds only on a little-endian target. Every target the engine ships for is little-endian.
    if (builtin.cpu.arch.endian() != .little) @compileError("streamed WAV needs a little-endian target");
}

pub const PcmFormat = types.PcmFormat;

/// The source could not supply bytes that its size promised.
pub const ReadError = error{ReadFailed};

/// Errors from opening or reading a streamed sound.
pub const Error = ReadError || error{
    /// The bytes are not a sound this decoder can read: a bad header, a size that doesn't match the header, or no
    /// sample frames.
    InvalidAudio,
    /// The sound is well formed but in a format the engine does not play, such as 24-bit WAV, or the bytes are not a
    /// WAV or BRAD file at all.
    UnsupportedFormat,
};

/// Where a decoder reads from: a context and a read function, plus the source's size in bytes.
pub const Source = struct {
    context: *anyopaque,
    readFn: *const fn (context: *anyopaque, offset: u64, dst: []u8) ReadError!usize,
    size: u64,

    /// Reads up to `dst.len` bytes starting at `offset`, and returns how many were read. Returns 0 at the end.
    pub fn readAt(self: Source, offset: u64, dst: []u8) ReadError!usize {
        return self.readFn(self.context, offset, dst);
    }
};

/// The most sample frames an IMA read decodes at once. A bigger request is answered over several reads.
pub const max_chunk_frames: u32 = 1024;

const wave_format_pcm: u16 = 0x0001;
const wave_format_ieee_float: u16 = 0x0003;
const wave_format_extensible: u16 = 0xFFFE;

/// The BRAD v1 header is 24 bytes, and each channel's block starts with a 4-byte predictor and step index.
const ima_header_len: u64 = 24;

/// A decoder for one streamed sound. It keeps its place between reads, and `rewind` starts it over.
pub const Decoder = union(enum) {
    wav: Wav,
    brad: Ima,

    /// The format of the bytes `read` returns. A WAV keeps the file's own format. A BRAD sound comes back as int16.
    pub fn format(self: *const Decoder) PcmFormat {
        return switch (self.*) {
            .wav => |w| w.format,
            .brad => |b| PcmFormat{ .sample_rate = b.sample_rate, .channels = b.channels, .kind = .int16 },
        };
    }

    /// The number of sample frames in the sound.
    pub fn frameCount(self: *const Decoder) u64 {
        return switch (self.*) {
            .wav => |w| w.data_len / @as(u64, spatial.frameBytes(w.format)),
            .brad => |b| b.frames,
        };
    }

    /// Starts the sound over, from its first frame.
    pub fn rewind(self: *Decoder) void {
        switch (self.*) {
            .wav => |*w| w.position = 0,
            .brad => |*b| b.restart(),
        }
    }

    /// Reads the next whole frames of the sound into `out`, in the format `format` gives, and returns how many bytes it
    /// wrote. Returns 0 once the sound has ended. `out` must hold at least one frame.
    pub fn read(self: *Decoder, out: []u8) Error!usize {
        return switch (self.*) {
            .wav => |*w| readWav(w, out),
            .brad => |*b| b.read(out),
        };
    }
};

/// Opens a streamed sound from `source`. It reads and checks the header, and nothing else, until `read` is called.
pub fn open(source: Source) Error!Decoder {
    if (source.size < 4) return error.InvalidAudio;
    var magic: [4]u8 = undefined;
    try readExact(source, 0, &magic);
    if (std.mem.eql(u8, &magic, "RIFF")) return openWav(source);
    if (std.mem.eql(u8, &magic, "BRAD")) return openBrad(source);
    return error.UnsupportedFormat;
}

/// Fills `dst` from `offset`, reading as often as the source needs. A source that ends early is an error, because the
/// sizes checked when the sound was opened promised more bytes than that.
fn readExact(source: Source, offset: u64, dst: []u8) ReadError!void {
    var done: usize = 0;
    while (done < dst.len) {
        const n = try source.readAt(offset + @as(u64, done), dst[done..]);
        if (n == 0) return error.ReadFailed;
        done += n;
    }
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn writeSample(out: []u8, index: usize, value: i32) void {
    const sample: i16 = @intCast(value);
    std.mem.writeInt(i16, out[index * 2 ..][0..2], sample, .little);
}

// ---- WAV ----

const Wav = struct {
    source: Source,
    format: PcmFormat,
    /// Where the sample data starts in the source, and how long it is in bytes, rounded down to whole frames.
    data_offset: u64,
    data_len: u64,
    /// How many bytes of the data have been read.
    position: u64 = 0,
};

fn openWav(source: Source) Error!Decoder {
    if (source.size < 12) return error.InvalidAudio;
    var riff: [12]u8 = undefined;
    try readExact(source, 0, &riff);
    if (!std.mem.eql(u8, riff[8..12], "WAVE")) return error.InvalidAudio;

    var format: ?PcmFormat = null;
    var data_offset: u64 = 0;
    var data_len: u64 = 0;
    var found_data = false;
    var offset: u64 = 12;
    while (offset + 8 <= source.size) {
        var head: [8]u8 = undefined;
        try readExact(source, offset, &head);
        const declared: u64 = readU32(head[4..8]);
        const body = offset + 8;
        if (std.mem.eql(u8, head[0..4], "fmt ")) {
            format = try parseFmt(source, body, declared);
        } else if (std.mem.eql(u8, head[0..4], "data")) {
            // A data length larger than the file is clipped to the bytes the file has.
            data_offset = body;
            data_len = @min(declared, source.size - body);
            found_data = true;
        }
        if (format != null and found_data) break;
        // Chunks are padded to an even length.
        offset = body + declared + (declared & 1);
    }

    const fmt = format orelse return error.InvalidAudio;
    if (!found_data) return error.InvalidAudio;
    const frame: u64 = spatial.frameBytes(fmt);
    const whole = data_len - data_len % frame;
    if (whole == 0) return error.InvalidAudio;
    return .{ .wav = .{ .source = source, .format = fmt, .data_offset = data_offset, .data_len = whole } };
}

/// Reads a fmt chunk whose body starts at `body` and is `declared` bytes long.
fn parseFmt(source: Source, body: u64, declared: u64) Error!PcmFormat {
    if (declared < 16 or body + declared > source.size) return error.InvalidAudio;
    var bytes: [40]u8 = undefined;
    const want: usize = @intCast(@min(declared, @as(u64, bytes.len)));
    try readExact(source, body, bytes[0..want]);

    var tag = readU16(bytes[0..2]);
    const channels = readU16(bytes[2..4]);
    const rate = readU32(bytes[4..8]);
    const block_align = readU16(bytes[12..14]);
    const bits = readU16(bytes[14..16]);
    if (tag == wave_format_extensible) {
        if (declared < 26) return error.InvalidAudio;
        // The sub-format GUID starts with the format tag that applies.
        tag = readU16(bytes[24..26]);
    }
    if (channels == 0 or channels > 8 or rate == 0) return error.InvalidAudio;

    const kind: types.SampleKind = switch (tag) {
        wave_format_pcm => switch (bits) {
            8 => .uint8,
            16 => .int16,
            32 => .int32,
            else => return error.UnsupportedFormat,
        },
        wave_format_ieee_float => switch (bits) {
            32 => .float32,
            else => return error.UnsupportedFormat,
        },
        else => return error.UnsupportedFormat,
    };
    const format = PcmFormat{ .sample_rate = rate, .channels = @intCast(channels), .kind = kind };
    if (@as(usize, block_align) != spatial.frameBytes(format)) return error.InvalidAudio;
    return format;
}

fn readWav(wav: *Wav, out: []u8) Error!usize {
    const frame = spatial.frameBytes(wav.format);
    std.debug.assert(out.len >= frame);
    const left = wav.data_len - wav.position;
    const room: u64 = @min(left, @as(u64, out.len));
    const take: u64 = room - room % @as(u64, frame);
    if (take == 0) return 0;
    try readExact(wav.source, wav.data_offset + wav.position, out[0..@intCast(take)]);
    wav.position += take;
    const bytes: usize = @intCast(take);
    return bytes;
}

// ---- BRAD IMA ADPCM ----

/// A BRAD sound. Its channels are stored one after another, each as a whole block, so a read takes a run of nibbles from
/// each block at its own offset. Each channel keeps its own predictor and step index between reads.
const Ima = struct {
    source: Source,
    sample_rate: u32,
    channels: u8,
    frames: u32,
    /// Bytes from one channel's block to the next: the 4-byte block header, then the packed nibbles.
    block_bytes: u64,
    /// Each channel's predictor and step index at the start of the sound.
    start_predictor: [2]i32,
    start_step: [2]i32,
    /// Each channel's predictor and step index after the frames read so far.
    predictor: [2]i32,
    step: [2]i32,
    /// How many frames have been read.
    position: u32 = 0,

    fn restart(self: *Ima) void {
        self.predictor = self.start_predictor;
        self.step = self.start_step;
        self.position = 0;
    }

    fn read(self: *Ima, out: []u8) Error!usize {
        const channels: usize = self.channels;
        const frame_bytes: usize = channels * 2;
        std.debug.assert(out.len >= frame_bytes);
        if (self.position >= self.frames) return 0;

        const start: u64 = self.position;
        const left: u64 = self.frames - start;
        const room: u64 = out.len / frame_bytes;
        const count: u64 = @min(@min(left, room), max_chunk_frames);

        // Frame 0 is the block header's predictor, with no nibble. Every later frame f is decoded from nibble f - 1.
        const first_frame: u64 = @max(start, 1);
        const first_nibble: u64 = first_frame - 1;
        const nibbles: u64 = start + count - first_frame;
        const end_nibble: u64 = first_nibble + nibbles;

        var nibble_bytes: [max_chunk_frames / 2 + 2]u8 = undefined;
        for (0..channels) |c| {
            var predictor = self.predictor[c];
            var step = self.step[c];
            const block: u64 = ima_header_len + @as(u64, c) * self.block_bytes;
            if (start == 0) writeSample(out, c, predictor);
            if (nibbles > 0) {
                const first_byte = first_nibble / 2;
                const last_byte = (end_nibble - 1) / 2;
                const len: usize = @intCast(last_byte - first_byte + 1);
                try readExact(self.source, block + 4 + first_byte, nibble_bytes[0..len]);
                var k: u64 = first_nibble;
                while (k < end_nibble) : (k += 1) {
                    const byte = nibble_bytes[@intCast(k / 2 - first_byte)];
                    const code: u4 = if (k % 2 == 0) @truncate(byte) else @truncate(byte >> 4);
                    predictor = ima.decodeNibble(code, &step, predictor);
                    const local: usize = @intCast(k + 1 - start);
                    writeSample(out, local * channels + c, predictor);
                }
            }
            self.predictor[c] = predictor;
            self.step[c] = step;
        }

        self.position = @intCast(start + count);
        const bytes: usize = @intCast(count * @as(u64, frame_bytes));
        return bytes;
    }
};

fn openBrad(source: Source) Error!Decoder {
    if (source.size < ima_header_len) return error.InvalidAudio;
    var head: [24]u8 = undefined;
    try readExact(source, 0, &head);
    if (!std.mem.eql(u8, head[0..4], "BRAD") or head[4] != 1) return error.InvalidAudio;

    const channels = head[5];
    const sample_rate = readU32(head[8..12]);
    const frames = readU32(head[12..16]);
    const payload_len = readU32(head[16..20]);
    if ((channels != 1 and channels != 2) or sample_rate == 0 or frames == 0) return error.InvalidAudio;

    const block_bytes: u64 = 4 + frames / 2;
    // The file must hold exactly the header's payload: one block per channel, and nothing more.
    if (@as(u64, payload_len) != source.size - ima_header_len) return error.InvalidAudio;
    if (@as(u64, payload_len) != block_bytes * @as(u64, channels)) return error.InvalidAudio;

    var start_predictor: [2]i32 = .{ 0, 0 };
    var start_step: [2]i32 = .{ 0, 0 };
    const count: usize = channels;
    for (0..count) |c| {
        var block_head: [4]u8 = undefined;
        try readExact(source, ima_header_len + @as(u64, c) * block_bytes, &block_head);
        const predictor: i16 = @bitCast(readU16(block_head[0..2]));
        const step = block_head[2];
        if (step > 88) return error.InvalidAudio;
        start_predictor[c] = predictor;
        start_step[c] = step;
    }

    return .{ .brad = .{
        .source = source,
        .sample_rate = sample_rate,
        .channels = channels,
        .frames = frames,
        .block_bytes = block_bytes,
        .start_predictor = start_predictor,
        .start_step = start_step,
        .predictor = start_predictor,
        .step = start_step,
    } };
}

// ---- Tests ----

/// A source over a byte slice. `max_read` caps each read, so the callers' read loops get exercised.
const MemorySource = struct {
    bytes: []const u8,
    max_read: usize = std.math.maxInt(usize),

    fn read(context: *anyopaque, offset: u64, dst: []u8) ReadError!usize {
        const self: *const MemorySource = @ptrCast(@alignCast(context));
        const start: usize = @intCast(offset);
        if (start >= self.bytes.len) return 0;
        const n = @min(@min(dst.len, self.bytes.len - start), self.max_read);
        @memcpy(dst[0..n], self.bytes[start..][0..n]);
        return n;
    }

    fn source(self: *MemorySource) Source {
        return .{ .context = self, .readFn = read, .size = @as(u64, self.bytes.len) };
    }
};

fn nextSeed(seed: u32) u32 {
    return seed *% 1664525 +% 1013904223;
}

/// Builds a BRAD file with a valid header and pseudo-random predictors, step indices, and nibbles. Every nibble is a
/// valid code, so any payload decodes, which lets the test compare two decoders on arbitrary data.
fn buildBrad(allocator: std.mem.Allocator, channels: u8, frames: u32) ![]u8 {
    const count: usize = channels;
    const block_bytes: usize = 4 + frames / 2;
    const total = 24 + block_bytes * count;
    const bytes = try allocator.alloc(u8, total);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "BRAD");
    bytes[4] = 1;
    bytes[5] = channels;
    std.mem.writeInt(u32, bytes[8..12], 22050, .little);
    std.mem.writeInt(u32, bytes[12..16], frames, .little);
    std.mem.writeInt(u32, bytes[16..20], @intCast(total - 24), .little);

    var seed: u32 = 12345;
    for (0..count) |c| {
        const block = bytes[24 + c * block_bytes ..][0..block_bytes];
        seed = nextSeed(seed);
        std.mem.writeInt(u16, block[0..2], @truncate(seed >> 8), .little);
        seed = nextSeed(seed);
        block[2] = @intCast(seed % 89);
        for (block[4..]) |*byte| {
            seed = nextSeed(seed);
            byte.* = @truncate(seed >> 16);
        }
    }
    return bytes;
}

test "a streamed BRAD sound reads the same samples as the whole-file decoder, for any chunk size" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { channels: u8, frames: u32 }{
        .{ .channels = 1, .frames = 1 },
        .{ .channels = 1, .frames = 2 },
        .{ .channels = 1, .frames = 64 },
        .{ .channels = 2, .frames = 2 },
        .{ .channels = 2, .frames = 37 },
        .{ .channels = 2, .frames = 3000 },
    };
    for (cases) |case| {
        const bytes = try buildBrad(allocator, case.channels, case.frames);
        defer allocator.free(bytes);
        var whole = try ima.decode(allocator, bytes);
        defer whole.deinit();

        const expected = try allocator.alloc(u8, whole.samples.len * 2);
        defer allocator.free(expected);
        for (whole.samples, 0..) |sample, i| std.mem.writeInt(i16, expected[i * 2 ..][0..2], sample, .little);

        for ([_]usize{ 1, 2, 3, 7, 1024, 5000 }) |chunk_frames| {
            for ([_]usize{ std.math.maxInt(usize), 1 }) |max_read| {
                var mem = MemorySource{ .bytes = bytes, .max_read = max_read };
                var decoder = try open(mem.source());
                const format = decoder.format();
                try std.testing.expectEqual(@as(u32, 22050), format.sample_rate);
                try std.testing.expectEqual(case.channels, format.channels);
                try std.testing.expectEqual(types.SampleKind.int16, format.kind);
                try std.testing.expectEqual(@as(u64, case.frames), decoder.frameCount());

                const limit = chunk_frames * @as(usize, case.channels) * 2;
                var piece: [20000]u8 = undefined;
                const got = try allocator.alloc(u8, expected.len);
                defer allocator.free(got);
                var filled: usize = 0;
                while (true) {
                    const n = try decoder.read(piece[0..limit]);
                    if (n == 0) break;
                    try std.testing.expect(filled + n <= got.len);
                    @memcpy(got[filled..][0..n], piece[0..n]);
                    filled += n;
                }
                try std.testing.expectEqual(expected.len, filled);
                try std.testing.expectEqualSlices(u8, expected, got);

                // Rewinding starts the sound over.
                decoder.rewind();
                const again = try decoder.read(piece[0 .. @as(usize, case.channels) * 2]);
                try std.testing.expectEqualSlices(u8, expected[0..again], piece[0..again]);
            }
        }
    }
}

test "a BRAD sound with no frames, or a size that doesn't match its header, is refused" {
    const allocator = std.testing.allocator;
    const empty = try buildBrad(allocator, 1, 0);
    defer allocator.free(empty);
    var mem_empty = MemorySource{ .bytes = empty };
    try std.testing.expectError(error.InvalidAudio, open(mem_empty.source()));

    const bytes = try buildBrad(allocator, 2, 10);
    defer allocator.free(bytes);
    var short = MemorySource{ .bytes = bytes[0 .. bytes.len - 1] };
    try std.testing.expectError(error.InvalidAudio, open(short.source()));

    const padded = try allocator.alloc(u8, bytes.len + 1);
    defer allocator.free(padded);
    @memcpy(padded[0..bytes.len], bytes);
    padded[bytes.len] = 0;
    var long = MemorySource{ .bytes = padded };
    try std.testing.expectError(error.InvalidAudio, open(long.source()));
}

const Writer = struct {
    bytes: []u8,
    at: usize = 0,

    fn raw(self: *Writer, text: []const u8) void {
        @memcpy(self.bytes[self.at..][0..text.len], text);
        self.at += text.len;
    }

    fn u16le(self: *Writer, value: u16) void {
        std.mem.writeInt(u16, self.bytes[self.at..][0..2], value, .little);
        self.at += 2;
    }

    fn u32le(self: *Writer, value: u32) void {
        std.mem.writeInt(u32, self.bytes[self.at..][0..4], value, .little);
        self.at += 4;
    }
};

const WavSpec = struct {
    tag: u16 = wave_format_pcm,
    channels: u16 = 2,
    rate: u32 = 22050,
    bits: u16 = 16,
    block_align: u16 = 4,
    /// The data length written into the data chunk header, which need not match the bytes that follow it.
    declared: u32,
    /// Whether an odd-length LIST chunk sits between fmt and data, so the test checks that other chunks are skipped.
    list: bool = true,
};

fn buildWav(allocator: std.mem.Allocator, spec: WavSpec, data: []const u8) ![]u8 {
    const list_len: usize = if (spec.list) 8 + 3 + 1 else 0;
    const total: usize = 12 + (8 + 16) + list_len + (8 + data.len);
    const bytes = try allocator.alloc(u8, total);
    var w = Writer{ .bytes = bytes };
    w.raw("RIFF");
    w.u32le(@intCast(total - 8));
    w.raw("WAVE");
    w.raw("fmt ");
    w.u32le(16);
    w.u16le(spec.tag);
    w.u16le(spec.channels);
    w.u32le(spec.rate);
    w.u32le(spec.rate * @as(u32, spec.block_align));
    w.u16le(spec.block_align);
    w.u16le(spec.bits);
    if (spec.list) {
        w.raw("LIST");
        w.u32le(3);
        w.raw("abc");
        w.raw("\x00");
    }
    w.raw("data");
    w.u32le(spec.declared);
    w.raw(data);
    return bytes;
}

test "a streamed WAV returns its samples as stored, past other chunks, for any read size" {
    const allocator = std.testing.allocator;
    var data: [64]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @intCast(i * 3 + 1);
    const bytes = try buildWav(allocator, .{ .declared = 64 }, &data);
    defer allocator.free(bytes);

    for ([_]usize{ 4, 8, 12, 4096 }) |read_size| {
        var mem = MemorySource{ .bytes = bytes };
        var decoder = try open(mem.source());
        const format = decoder.format();
        try std.testing.expectEqual(@as(u32, 22050), format.sample_rate);
        try std.testing.expectEqual(@as(u8, 2), format.channels);
        try std.testing.expectEqual(types.SampleKind.int16, format.kind);
        try std.testing.expectEqual(@as(u64, 16), decoder.frameCount());

        var piece: [4096]u8 = undefined;
        var got: [64]u8 = undefined;
        var filled: usize = 0;
        while (true) {
            const n = try decoder.read(piece[0..read_size]);
            if (n == 0) break;
            @memcpy(got[filled..][0..n], piece[0..n]);
            filled += n;
        }
        try std.testing.expectEqual(@as(usize, 64), filled);
        try std.testing.expectEqualSlices(u8, &data, &got);

        decoder.rewind();
        const again = try decoder.read(piece[0..4]);
        try std.testing.expectEqualSlices(u8, data[0..4], piece[0..again]);
    }
}

test "a WAV data chunk longer than the file is clipped to the bytes present, in whole frames" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const bytes = try buildWav(allocator, .{ .declared = std.math.maxInt(u32), .list = false }, &data);
    defer allocator.free(bytes);
    var mem = MemorySource{ .bytes = bytes };
    var decoder = try open(mem.source());
    try std.testing.expectEqual(@as(u64, 2), decoder.frameCount());
    var piece: [16]u8 = undefined;
    const n = try decoder.read(&piece);
    try std.testing.expectEqualSlices(u8, data[0..8], piece[0..n]);
    try std.testing.expectEqual(@as(usize, 0), try decoder.read(&piece));
}

test "WAV and other files this decoder can't stream are refused with a reason" {
    const allocator = std.testing.allocator;
    const data = [_]u8{0} ** 12;

    // 24-bit PCM: the engine has no 24-bit sample kind.
    const bits24 = try buildWav(allocator, .{ .bits = 24, .block_align = 6, .declared = 12, .list = false }, &data);
    defer allocator.free(bits24);
    var mem24 = MemorySource{ .bytes = bits24 };
    try std.testing.expectError(error.UnsupportedFormat, open(mem24.source()));

    // A block align that doesn't match the channel count and sample size.
    const bad_align = try buildWav(allocator, .{ .block_align = 3, .declared = 12, .list = false }, &data);
    defer allocator.free(bad_align);
    var mem_align = MemorySource{ .bytes = bad_align };
    try std.testing.expectError(error.InvalidAudio, open(mem_align.source()));

    var mem_text = MemorySource{ .bytes = "this is not a wav file" };
    try std.testing.expectError(error.UnsupportedFormat, open(mem_text.source()));
}
