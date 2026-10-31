//! Decoder for the build pipeline's compact BRAD IMA ADPCM sound format.

const std = @import("std");

const step_table = [_]i32{
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253,
    279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166,
    1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
    4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
};
const index_table = [_]i32{ -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8 };

pub const Sound = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    frames: u32,
    samples: []i16,

    pub fn deinit(self: *Sound) void {
        self.allocator.free(self.samples);
    }
};

/// Decodes a BRAD v1 file into interleaved signed 16-bit PCM. The file keeps one predictor and
/// packed 4-bit deltas per channel, reducing PCM storage to about half its original size.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Sound {
    if (data.len < 24 or !std.mem.eql(u8, data[0..4], "BRAD") or data[4] != 1) return error.InvalidAudio;
    const channels = data[5];
    const sample_rate = readU32(data[8..12]);
    const frames = readU32(data[12..16]);
    const payload_len = readU32(data[16..20]);
    if ((channels != 1 and channels != 2) or sample_rate == 0 or frames == 0 or payload_len != data.len - 24) return error.InvalidAudio;

    const channel_count: usize = channels;
    const frame_count: usize = frames;
    const bytes_per_channel = 4 + frame_count / 2;
    const expected_payload = std.math.mul(usize, bytes_per_channel, channel_count) catch return error.InvalidAudio;
    const sample_count = std.math.mul(usize, frame_count, channel_count) catch return error.InvalidAudio;
    if (payload_len != expected_payload) return error.InvalidAudio;

    const samples = try allocator.alloc(i16, sample_count);
    errdefer allocator.free(samples);
    for (0..channel_count) |channel| {
        const block = data[24 + channel * bytes_per_channel ..][0..bytes_per_channel];
        var predictor: i32 = @as(i16, @bitCast(readU16(block[0..2])));
        var step_index: i32 = block[2];
        if (step_index > 88) return error.InvalidAudio;
        samples[channel] = @intCast(predictor);
        for (1..frame_count) |frame| {
            const nibble_index = frame - 1;
            const encoded_byte = block[4 + nibble_index / 2];
            const code: u4 = if ((nibble_index & 1) == 0) @truncate(encoded_byte) else @truncate(encoded_byte >> 4);
            predictor = decodeNibble(code, &step_index, predictor);
            samples[frame * channel_count + channel] = @intCast(predictor);
        }
    }
    return .{ .allocator = allocator, .sample_rate = sample_rate, .channels = channels, .frames = frames, .samples = samples };
}

fn readU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

fn decodeNibble(code: u4, step_index: *i32, predictor: i32) i32 {
    const code_value: i32 = code;
    const step = step_table[@intCast(step_index.*)];
    var difference = step >> 3;
    if ((code_value & 1) != 0) difference += step >> 2;
    if ((code_value & 2) != 0) difference += step >> 1;
    if ((code_value & 4) != 0) difference += step;
    const next_predictor = std.math.clamp(predictor + (if ((code_value & 8) != 0) -difference else difference), -32768, 32767);
    step_index.* = std.math.clamp(step_index.* + index_table[@intCast(code_value)], 0, 88);
    return next_predictor;
}

test "BRAD decoder expands packed samples and preserves metadata" {
    const bytes = [_]u8{
        'B', 'R', 'A', 'D', 1, 1, 0, 0,
        0x44, 0xAC, 0, 0, // 44100 Hz
        3, 0, 0, 0, // 3 frames
        5, 0, 0, 0, // 4-byte channel header plus one packed byte
        0, 0, 0, 0,
        0, 0, 0, 0, 0x21, // predictor 0; codes 1 then 2
    };
    var decoded = try decode(std.testing.allocator, &bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 44100), decoded.sample_rate);
    try std.testing.expectEqual(@as(u8, 1), decoded.channels);
    try std.testing.expectEqual(@as(u32, 3), decoded.frames);
    try std.testing.expectEqualSlices(i16, &.{ 0, 1, 4 }, decoded.samples);
}

test "BRAD decoder handles planar channel blocks as interleaved PCM" {
    const bytes = [_]u8{
        'B', 'R', 'A', 'D', 1, 2, 0, 0,
        0x44, 0xAC, 0, 0,
        2, 0, 0, 0,
        10, 0, 0, 0,
        0, 0, 0, 0,
        0x64, 0, 0, 0, 0x01, // channel 0: 100 then slightly higher
        0x9C, 0xFF, 0, 0, 0x09, // channel 1: -100 then lower
    };
    var decoded = try decode(std.testing.allocator, &bytes);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(i16, &.{ 100, -100, 101, -101 }, decoded.samples);
}

test "BRAD decoder rejects unsupported versions, channel counts, and malformed payloads" {
    const valid = [_]u8{ 'B', 'R', 'A', 'D', 1, 1, 0, 0, 0x44, 0xAC, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidAudio, decode(std.testing.allocator, valid[0..23]));
    var bad_version = valid;
    bad_version[4] = 2;
    try std.testing.expectError(error.InvalidAudio, decode(std.testing.allocator, &bad_version));
    var bad_channels = valid;
    bad_channels[5] = 3;
    try std.testing.expectError(error.InvalidAudio, decode(std.testing.allocator, &bad_channels));
    var bad_payload = valid;
    bad_payload[16] = 3;
    try std.testing.expectError(error.InvalidAudio, decode(std.testing.allocator, &bad_payload));
}
