//! Fixed-step input recording/replay and caller-serialized state checkpoints.
//! State bytes are supplied by the game so snapshots remain independent of game types.

const std = @import("std");
const input = @import("input/input.zig");
const gamepad = @import("input/gamepad.zig");
const platform_types = @import("platform/types.zig");

pub const InputSnapshot = input.Input.Snapshot;

pub const Error = error{
    NonSequentialTick,
    TickUnavailable,
    SnapshotBufferTooSmall,
    SnapshotCorrupt,
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
};

fn checksum(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
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
