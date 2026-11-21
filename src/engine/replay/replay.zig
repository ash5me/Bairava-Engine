//! Fixed-step input recording/replay and caller-serialized state checkpoints.
//! State bytes are supplied by the game so snapshots remain independent of game types.

const std = @import("std");
const input = @import("../input/input.zig");
const gamepad = @import("../input/gamepad.zig");
const platform_types = @import("../platform/types.zig");
const fixed_timestep = @import("../core/fixed_timestep.zig");

pub const InputSnapshot = input.Input.Snapshot;
pub const format_version: u16 = 1;
const magic = "BVRP";
const key_count = std.enums.values(input.Key).len;
const mouse_count = std.enums.values(platform_types.MouseButton).len;
const pad_count = platform_types.max_gamepads;
const input_frame_size = 8 + 3 * key_count + 3 * mouse_count + 8 + 8 + pad_count * (1 + 1 + 4 + 8 + gamepad.axis_count * 4 + gamepad.control_count * 5);
const checkpoint_header_size = 8 + 4 + 8;

pub const Error = error{
    NonSequentialTick,
    TickUnavailable,
    SnapshotBufferTooSmall,
    SnapshotCorrupt,
    VersionMismatch,
    InvalidFormat,
    IntegerOverflow,
};

pub const Metadata = struct {
    version: u16 = format_version,
    seed: u64,
    update_hz: u32,
    tick_count: usize,
    input_frame_count: usize,
    checkpoint_count: usize,
};

pub const SnapshotInfo = struct {
    tick: u64,
    byte_count: usize,
    checksum: u64,
};

const RecordedSnapshot = struct {
    info: SnapshotInfo,
    bytes: []u8,
};

/// An owned recording. `recordInput` must be called once after input is latched for each fixed update.
/// State checkpoints are optional and contain game-defined serialized simulation state.
pub const Log = struct {
    allocator: std.mem.Allocator,
    seed: u64 = 0,
    update_hz: u32 = 60,
    frames: std.ArrayList(Frame) = .empty,
    snapshots: std.ArrayList(RecordedSnapshot) = .empty,
    cursor: usize = 0,

    const Frame = struct {
        tick: u64,
        input: InputSnapshot,
    };

    pub fn init(allocator: std.mem.Allocator) Log {
        return .{ .allocator = allocator };
    }

    pub fn initWithSeed(allocator: std.mem.Allocator, seed: u64, update_hz: u32) Log {
        return .{ .allocator = allocator, .seed = seed, .update_hz = update_hz };
    }

    pub fn deinit(self: *Log) void {
        for (self.snapshots.items) |snapshot| self.allocator.free(snapshot.bytes);
        self.snapshots.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn frameCount(self: *const Log) usize {
        return self.frames.items.len;
    }

    pub fn snapshotCount(self: *const Log) usize {
        return self.snapshots.items.len;
    }

    pub fn metadata(self: *const Log) Metadata {
        return .{
            .seed = self.seed,
            .update_hz = self.update_hz,
            .tick_count = self.frames.items.len,
            .input_frame_count = self.frames.items.len,
            .checkpoint_count = self.snapshots.items.len,
        };
    }

    /// Records the input state visible to a simulation update, rejecting gaps and duplicate ticks.
    pub fn recordInput(self: *Log, tick: u64, state: *const input.Input) (Error || std.mem.Allocator.Error)!void {
        if (self.frames.items.len > 0) {
            const previous = self.frames.items[self.frames.items.len - 1].tick;
            if (previous == std.math.maxInt(u64) or tick != previous + 1) return error.NonSequentialTick;
        }
        try self.frames.append(self.allocator, .{ .tick = tick, .input = state.snapshot() });
    }

    /// Applies the next recorded update input and returns its tick. Replay never samples platform input.
    pub fn applyNextInput(self: *Log, destination: *input.Input) Error!u64 {
        if (self.cursor >= self.frames.items.len) return error.TickUnavailable;
        const frame = self.frames.items[self.cursor];
        destination.restoreSnapshot(frame.input);
        self.cursor += 1;
        return frame.tick;
    }

    /// Restarts playback at the first recorded frame.
    pub fn rewind(self: *Log) void {
        self.cursor = 0;
    }

    /// Positions playback at an exact recorded tick.
    pub fn seek(self: *Log, tick: u64) Error!void {
        for (self.frames.items, 0..) |frame, index| {
            if (frame.tick == tick) {
                self.cursor = index;
                return;
            }
        }
        return error.TickUnavailable;
    }

    /// Stores caller-serialized state for restoring after seeking. Snapshot ticks must increase strictly.
    pub fn recordState(self: *Log, tick: u64, bytes: []const u8) (Error || std.mem.Allocator.Error)!SnapshotInfo {
        if (self.snapshots.items.len > 0 and tick <= self.snapshots.items[self.snapshots.items.len - 1].info.tick) {
            return error.NonSequentialTick;
        }
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        const info = SnapshotInfo{ .tick = tick, .byte_count = owned.len, .checksum = checksum(owned) };
        try self.snapshots.append(self.allocator, .{ .info = info, .bytes = owned });
        return info;
    }

    /// Copies the newest checkpoint at or before `tick` into `out`.
    pub fn restoreStateAtOrBefore(self: *const Log, tick: u64, out: []u8) Error!SnapshotInfo {
        var found: ?RecordedSnapshot = null;
        for (self.snapshots.items) |snapshot| {
            if (snapshot.info.tick > tick) break;
            found = snapshot;
        }
        const snapshot = found orelse return error.TickUnavailable;
        if (snapshot.info.byte_count > out.len) return error.SnapshotBufferTooSmall;
        if (checksum(snapshot.bytes) != snapshot.info.checksum) return error.SnapshotCorrupt;
        @memcpy(out[0..snapshot.info.byte_count], snapshot.bytes);
        return snapshot.info;
    }

    /// Latest checkpoint at or before `tick`, if any.
    pub fn snapshotAtOrBefore(self: *const Log, tick: u64) ?SnapshotInfo {
        var found: ?SnapshotInfo = null;
        for (self.snapshots.items) |snapshot| {
            if (snapshot.info.tick > tick) break;
            found = snapshot.info;
        }
        return found;
    }

    /// Returns the exact byte count needed by `encode`.
    pub fn encodedSize(self: *const Log) Error!usize {
        if (self.update_hz == 0) return error.InvalidFormat;
        var size: usize = 4 + 2 + 8 + 4 + 8 + 8;
        size = try checkedAdd(size, try checkedMultiply(self.frames.items.len, input_frame_size));
        for (self.snapshots.items) |snapshot| {
            if (snapshot.info.byte_count != snapshot.bytes.len) return error.InvalidFormat;
            if (checksum(snapshot.bytes) != snapshot.info.checksum) return error.SnapshotCorrupt;
            if (snapshot.bytes.len > std.math.maxInt(u32)) return error.IntegerOverflow;
            size = try checkedAdd(size, checkpoint_header_size);
            size = try checkedAdd(size, snapshot.bytes.len);
        }
        return size;
    }

    /// Encodes the replay using a versioned, little-endian format. `out` must have `encodedSize()` bytes.
    pub fn encode(self: *const Log, out: []u8) (Error || std.mem.Allocator.Error)!usize {
        const required = try self.encodedSize();
        if (out.len < required) return error.SnapshotBufferTooSmall;
        var writer = Writer{ .bytes = out[0..required] };
        try writer.writeBytes(magic);
        try writer.writeInt(u16, format_version);
        try writer.writeInt(u64, self.seed);
        try writer.writeInt(u32, self.update_hz);
        try writer.writeInt(u64, try usizeToU64(self.frames.items.len));
        try writer.writeInt(u64, try usizeToU64(self.snapshots.items.len));
        for (self.frames.items) |frame| {
            try writer.writeInt(u64, frame.tick);
            try writeInputSnapshot(&writer, frame.input);
        }
        for (self.snapshots.items) |snapshot| {
            try writer.writeInt(u64, snapshot.info.tick);
            try writer.writeInt(u32, @intCast(snapshot.bytes.len));
            try writer.writeInt(u64, snapshot.info.checksum);
            try writer.writeBytes(snapshot.bytes);
        }
        return writer.index;
    }

    /// Decodes an owned recording. Unsupported versions, malformed payloads, and corrupt checkpoints
    /// are rejected; the caller owns the returned log and must call `deinit`.
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!Log {
        var reader = Reader{ .bytes = bytes };
        if (!std.mem.eql(u8, try reader.readBytes(magic.len), magic)) return error.InvalidFormat;
        const version = try reader.readInt(u16);
        if (version != format_version) return error.VersionMismatch;
        var log = Log.initWithSeed(allocator, try reader.readInt(u64), try reader.readInt(u32));
        errdefer log.deinit();
        if (log.update_hz == 0) return error.InvalidFormat;

        const frame_count = try u64ToUsize(try reader.readInt(u64));
        const snapshot_count = try u64ToUsize(try reader.readInt(u64));
        if (frame_count > reader.remaining() / input_frame_size) return error.InvalidFormat;
        for (0..frame_count) |_| {
            const tick = try reader.readInt(u64);
            if (log.frames.items.len > 0) {
                const previous = log.frames.items[log.frames.items.len - 1].tick;
                if (previous == std.math.maxInt(u64) or tick != previous + 1) return error.InvalidFormat;
            }
            const snapshot = try readInputSnapshot(&reader);
            try log.frames.append(allocator, .{ .tick = tick, .input = snapshot });
        }

        if (snapshot_count > reader.remaining() / checkpoint_header_size) return error.InvalidFormat;
        var previous_snapshot_tick: ?u64 = null;
        for (0..snapshot_count) |_| {
            const tick = try reader.readInt(u64);
            if (previous_snapshot_tick) |previous| {
                if (tick <= previous) return error.InvalidFormat;
            }
            previous_snapshot_tick = tick;
            const byte_count = try reader.readInt(u32);
            const expected_checksum = try reader.readInt(u64);
            const state = try reader.readBytes(byte_count);
            if (checksum(state) != expected_checksum) return error.SnapshotCorrupt;
            const owned = try allocator.dupe(u8, state);
            errdefer allocator.free(owned);
            try log.snapshots.append(allocator, .{
                .info = .{ .tick = tick, .byte_count = owned.len, .checksum = expected_checksum },
                .bytes = owned,
            });
        }
        if (reader.remaining() != 0) return error.InvalidFormat;
        return log;
    }
};

pub fn hashState(bytes: []const u8) u64 {
    return checksum(bytes);
}

fn checksum(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}

fn checkedAdd(left: usize, right: usize) Error!usize {
    const result = @addWithOverflow(left, right);
    if (result[1] != 0) return error.IntegerOverflow;
    return result[0];
}

fn checkedMultiply(left: usize, right: usize) Error!usize {
    const result = @mulWithOverflow(left, right);
    if (result[1] != 0) return error.IntegerOverflow;
    return result[0];
}

fn usizeToU64(value: usize) Error!u64 {
    if (value > std.math.maxInt(u64)) return error.IntegerOverflow;
    return @intCast(value);
}

fn u64ToUsize(value: u64) Error!usize {
    if (value > std.math.maxInt(usize)) return error.InvalidFormat;
    return @intCast(value);
}

const Writer = struct {
    bytes: []u8,
    index: usize = 0,

    fn writeBytes(self: *Writer, bytes: []const u8) Error!void {
        if (bytes.len > self.bytes.len - self.index) return error.InvalidFormat;
        @memcpy(self.bytes[self.index .. self.index + bytes.len], bytes);
        self.index += bytes.len;
    }

    fn writeInt(self: *Writer, comptime T: type, value: T) Error!void {
        var remaining = value;
        inline for (0..@sizeOf(T)) |_| {
            try self.writeByte(@truncate(remaining));
            remaining >>= 8;
        }
    }

    fn writeByte(self: *Writer, byte: u8) Error!void {
        if (self.index >= self.bytes.len) return error.InvalidFormat;
        self.bytes[self.index] = byte;
        self.index += 1;
    }

    fn writeBool(self: *Writer, value: bool) Error!void {
        try self.writeByte(@intFromBool(value));
    }

    fn writeFloat(self: *Writer, value: f32) Error!void {
        try self.writeInt(u32, @bitCast(value));
    }
};

const Reader = struct {
    bytes: []const u8,
    index: usize = 0,

    fn remaining(self: *const Reader) usize {
        return self.bytes.len - self.index;
    }

    fn readBytes(self: *Reader, count: usize) Error![]const u8 {
        if (count > self.remaining()) return error.InvalidFormat;
        const result = self.bytes[self.index .. self.index + count];
        self.index += count;
        return result;
    }

    fn readInt(self: *Reader, comptime T: type) Error!T {
        var value: T = 0;
        inline for (0..@sizeOf(T)) |byte_index| {
            value |= @as(T, try self.readByte()) << @intCast(byte_index * 8);
        }
        return value;
    }

    fn readByte(self: *Reader) Error!u8 {
        if (self.index >= self.bytes.len) return error.InvalidFormat;
        const value = self.bytes[self.index];
        self.index += 1;
        return value;
    }

    fn readBool(self: *Reader) Error!bool {
        return switch (try self.readByte()) {
            0 => false,
            1 => true,
            else => error.InvalidFormat,
        };
    }

    fn readFloat(self: *Reader) Error!f32 {
        return @bitCast(try self.readInt(u32));
    }
};

fn writeInputSnapshot(writer: *Writer, state: InputSnapshot) Error!void {
    for (state.held_keys) |value| try writer.writeBool(value);
    for (state.pressed) |value| try writer.writeBool(value);
    for (state.released) |value| try writer.writeBool(value);
    for (state.mouse_held) |value| try writer.writeBool(value);
    for (state.mouse_pressed) |value| try writer.writeBool(value);
    for (state.mouse_released) |value| try writer.writeBool(value);
    try writer.writeFloat(state.mouse_x);
    try writer.writeFloat(state.mouse_y);
    try writer.writeInt(u64, state.connections);
    for (state.pads) |pad| {
        try writer.writeBool(pad.id != null);
        if (pad.id) |id| {
            try writer.writeByte(id.slot);
            try writer.writeInt(u32, id.generation);
        } else {
            try writer.writeByte(0);
            try writer.writeInt(u32, 0);
        }
        try writer.writeInt(u64, pad.order);
        for (pad.axes) |axis| try writer.writeFloat(axis);
        for (pad.held) |value| try writer.writeBool(value);
        for (pad.pending_pressed) |value| try writer.writeBool(value);
        for (pad.pending_released) |value| try writer.writeBool(value);
        for (pad.pressed) |value| try writer.writeBool(value);
        for (pad.released) |value| try writer.writeBool(value);
    }
}

fn readInputSnapshot(reader: *Reader) Error!InputSnapshot {
    var state = std.mem.zeroes(InputSnapshot);
    for (&state.held_keys) |*value| value.* = try reader.readBool();
    for (&state.pressed) |*value| value.* = try reader.readBool();
    for (&state.released) |*value| value.* = try reader.readBool();
    for (&state.mouse_held) |*value| value.* = try reader.readBool();
    for (&state.mouse_pressed) |*value| value.* = try reader.readBool();
    for (&state.mouse_released) |*value| value.* = try reader.readBool();
    state.mouse_x = try reader.readFloat();
    state.mouse_y = try reader.readFloat();
    state.connections = try reader.readInt(u64);
    for (&state.pads, 0..) |*pad, pad_index| {
        const connected = try reader.readBool();
        const slot = try reader.readByte();
        const generation = try reader.readInt(u32);
        if (connected) {
            if (slot != pad_index or generation == 0) return error.InvalidFormat;
            pad.id = .{ .slot = slot, .generation = generation };
        } else if (slot != 0 or generation != 0) {
            return error.InvalidFormat;
        }
        pad.order = try reader.readInt(u64);
        for (&pad.axes) |*axis| axis.* = try reader.readFloat();
        for (&pad.held) |*value| value.* = try reader.readBool();
        for (&pad.pending_pressed) |*value| value.* = try reader.readBool();
        for (&pad.pending_released) |*value| value.* = try reader.readBool();
        for (&pad.pressed) |*value| value.* = try reader.readBool();
        for (&pad.released) |*value| value.* = try reader.readBool();
    }
    return state;
}

test "a replay log records and reapplies latched keyboard, mouse, and gamepad state" {
    var original = input.Input{};
    original.keyDown(.space);
    original.setHeld(.space, true);
    original.mouseButton(.left, true);
    original.moveMouse(18.5, 42);
    const pad_id = platform_types.GamepadId{ .slot = 0, .generation = 3 };
    original.gamepadAdded(pad_id);
    original.gamepadButton(pad_id, .south, true);
    original.latch();

    var log = Log.init(std.testing.allocator);
    defer log.deinit();
    try log.recordInput(12, &original);

    var replayed = input.Input{};
    replayed.keyDown(.escape);
    try std.testing.expectEqual(@as(u64, 12), try log.applyNextInput(&replayed));
    try std.testing.expect(replayed.held(.space));
    try std.testing.expect(replayed.wasPressed(.space));
    try std.testing.expect(!replayed.wasPressed(.escape));
    try std.testing.expect(replayed.mousePressed(.left));
    try std.testing.expectEqual(@as(f32, 18.5), replayed.mouse_x);
    try std.testing.expect(replayed.primaryPad().?.pressed[gamepad.buttonControl(.south)]);
    try std.testing.expectError(error.TickUnavailable, log.applyNextInput(&replayed));
}

test "a replay recording enforces sequential ticks and can rewind or seek" {
    var log = Log.init(std.testing.allocator);
    defer log.deinit();
    const empty = input.Input{};
    try log.recordInput(5, &empty);
    try std.testing.expectError(error.NonSequentialTick, log.recordInput(7, &empty));
    try log.recordInput(6, &empty);
    var replayed = input.Input{};
    try std.testing.expectEqual(@as(u64, 5), try log.applyNextInput(&replayed));
    try log.seek(6);
    try std.testing.expectEqual(@as(u64, 6), try log.applyNextInput(&replayed));
    log.rewind();
    try std.testing.expectEqual(@as(u64, 5), try log.applyNextInput(&replayed));
    try std.testing.expectError(error.TickUnavailable, log.seek(9));
}

test "fixed-step replay reproduces a game-owned simulation from recorded input" {
    const ticks = 120;
    var recording = Log.init(std.testing.allocator);
    defer recording.deinit();

    var live = input.Input{};
    for (0..ticks) |tick| {
        if (tick == 10) {
            live.keyDown(.space);
            live.setHeld(.space, true);
        } else if (tick == 70) {
            live.keyUp(.space);
            live.setHeld(.space, false);
        }
        live.latch();
        try recording.recordInput(@intCast(tick), &live);
    }

    const simulate = struct {
        fn run(log: *Log, tick_count: usize) !i64 {
            var accumulator = fixed_timestep.Accumulator.init(60);
            var replayed = input.Input{};
            var position: i64 = 0;
            for (0..tick_count) |_| {
                _ = accumulator.addFrameTime(accumulator.fixed_dt);
                while (accumulator.hasStep()) {
                    _ = try log.applyNextInput(&replayed);
                    position += if (replayed.held(.space)) @as(i64, 2) else -1;
                    if (replayed.wasPressed(.space)) position += 17;
                    accumulator.consumeStep();
                }
            }
            return position;
        }
    }.run;

    const first = try simulate(&recording, ticks);
    recording.rewind();
    const second = try simulate(&recording, ticks);
    try std.testing.expectEqual(first, second);
}

test "state snapshots restore the nearest checkpoint and validate output capacity" {
    var log = Log.init(std.testing.allocator);
    defer log.deinit();
    const first = try log.recordState(0, "initial");
    const second = try log.recordState(60, "later-state");
    try std.testing.expectEqual(@as(u64, 0), first.tick);
    try std.testing.expectEqual(@as(u64, 60), second.tick);
    try std.testing.expectError(error.NonSequentialTick, log.recordState(60, "duplicate"));
    var empty = Log.init(std.testing.allocator);
    defer empty.deinit();
    var output: [16]u8 = undefined;
    try std.testing.expectError(error.TickUnavailable, empty.restoreStateAtOrBefore(0, &output));
    try std.testing.expectError(error.SnapshotBufferTooSmall, log.restoreStateAtOrBefore(0, &.{}));
    const restored = try log.restoreStateAtOrBefore(75, &output);
    try std.testing.expectEqual(@as(u64, 60), restored.tick);
    try std.testing.expectEqualStrings("later-state", output[0..restored.byte_count]);
    try std.testing.expectEqual(@as(u64, 0), log.snapshotAtOrBefore(59).?.tick);
}

test "versioned encoding round-trips metadata, inputs, and checked state checkpoints" {
    var live = input.Input{};
    const pad_id = platform_types.GamepadId{ .slot = 2, .generation = 7 };
    live.gamepadAdded(pad_id);
    live.gamepadAxis(pad_id, .left_x, 0.75);
    live.keyDown(.d);
    live.setHeld(.d, true);
    live.mouseButton(.right, true);
    live.moveMouse(123.25, 45.5);
    live.latch();

    var original = Log.initWithSeed(std.testing.allocator, 0x23C0FFEE, 60);
    defer original.deinit();
    try original.recordInput(10, &live);
    _ = try original.recordState(10, "checkpoint-10");
    live.latch();
    try original.recordInput(11, &live);

    const encoded = try std.testing.allocator.alloc(u8, try original.encodedSize());
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqual(encoded.len, try original.encode(encoded));

    var decoded = try Log.decode(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(original.metadata(), decoded.metadata());
    var replayed = input.Input{};
    try std.testing.expectEqual(@as(u64, 10), try decoded.applyNextInput(&replayed));
    try std.testing.expect(replayed.held(.d));
    try std.testing.expect(replayed.wasPressed(.d));
    try std.testing.expect(replayed.mouseDown(.right));
    try std.testing.expectEqual(@as(f32, 123.25), replayed.mouse_x);
    try std.testing.expectEqual(pad_id, replayed.primaryPad().?.id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6875), replayed.primaryPad().?.axes[0], 1e-6);

    var restored: [32]u8 = undefined;
    const info = try decoded.restoreStateAtOrBefore(10, &restored);
    try std.testing.expectEqual(@as(u64, 10), info.tick);
    try std.testing.expectEqualStrings("checkpoint-10", restored[0..info.byte_count]);
}

test "the replay decoder rejects unsupported versions, malformed input, truncation, and corruption" {
    var log = Log.initWithSeed(std.testing.allocator, 3, 60);
    defer log.deinit();
    const state = input.Input{};
    try log.recordInput(0, &state);
    _ = try log.recordState(0, "safe");
    const encoded = try std.testing.allocator.alloc(u8, try log.encodedSize());
    defer std.testing.allocator.free(encoded);
    _ = try log.encode(encoded);

    const wrong_version = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(wrong_version);
    wrong_version[4] = 0xff;
    try std.testing.expectError(error.VersionMismatch, Log.decode(std.testing.allocator, wrong_version));

    const bad_bool = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_bool);
    bad_bool[4 + 2 + 8 + 4 + 8 + 8 + 8] = 2;
    try std.testing.expectError(error.InvalidFormat, Log.decode(std.testing.allocator, bad_bool));
    try std.testing.expectError(error.InvalidFormat, Log.decode(std.testing.allocator, encoded[0 .. encoded.len - 1]));

    const bad_checkpoint = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_checkpoint);
    bad_checkpoint[bad_checkpoint.len - 1] ^= 0x80;
    try std.testing.expectError(error.SnapshotCorrupt, Log.decode(std.testing.allocator, bad_checkpoint));
}

test "recorded input produces identical fixed-step checkpoints at different render rates" {
    const tick_count = 120;
    const seed: u64 = 0x23D371;
    var recording = Log.initWithSeed(std.testing.allocator, seed, 60);
    defer recording.deinit();

    var live_input = input.Input{};
    for (0..tick_count) |tick| {
        if (tick == 8 or tick == 66) {
            live_input.keyDown(.space);
            live_input.setHeld(.space, true);
        } else if (tick == 32 or tick == 94) {
            live_input.keyUp(.space);
            live_input.setHeld(.space, false);
        }
        live_input.latch();
        try recording.recordInput(@intCast(tick), &live_input);
    }

    const State = struct {
        position: i64,
        random_state: u64,

        fn step(self: *@This(), state: *const input.Input) void {
            self.random_state ^= self.random_state >> 12;
            self.random_state ^= self.random_state << 25;
            self.random_state ^= self.random_state >> 27;
            const random_value = self.random_state *% 0x2545f4914f6cdd1d;
            self.position += if (state.held(.space)) 2 else -1;
            if (state.wasPressed(.space)) self.position += 17;
            self.position += @as(i64, @intCast(random_value % 3)) - 1;
        }

        fn hash(self: @This()) u64 {
            var bytes: [16]u8 = undefined;
            for (0..8) |index| {
                bytes[index] = @truncate(@as(u64, @bitCast(self.position)) >> @intCast(index * 8));
                bytes[index + 8] = @truncate(self.random_state >> @intCast(index * 8));
            }
            return hashState(&bytes);
        }
    };

    var expected_input = input.Input{};
    var expected_state = State{ .position = 0, .random_state = seed };
    var expected_hashes: [tick_count]u64 = undefined;
    for (0..tick_count) |tick| {
        _ = try recording.applyNextInput(&expected_input);
        expected_state.step(&expected_input);
        expected_hashes[tick] = expected_state.hash();
    }

    const runAtRate = struct {
        fn run(log: *Log, render_hz: u32, hashes: []const u64) !?u64 {
            log.rewind();
            var accumulator = fixed_timestep.Accumulator.init(log.update_hz);
            var replayed_input = input.Input{};
            var state = State{ .position = 0, .random_state = log.seed };
            var tick: usize = 0;
            while (tick < hashes.len) {
                _ = accumulator.addFrameTime(1.0 / @as(f32, @floatFromInt(render_hz)));
                while (accumulator.hasStep() and tick < hashes.len) {
                    _ = try log.applyNextInput(&replayed_input);
                    state.step(&replayed_input);
                    if (state.hash() != hashes[tick]) return @as(u64, @intCast(tick));
                    tick += 1;
                    accumulator.consumeStep();
                }
            }
            return null;
        }
    }.run;

    for ([_]u32{ 30, 60, 120 }) |render_hz| {
        try std.testing.expectEqual(@as(?u64, null), try runAtRate(&recording, render_hz, &expected_hashes));
    }
}
