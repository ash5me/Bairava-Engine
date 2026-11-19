//! Simulation-owned action press windows. Input edges remain one-update events; this buffer can
//! keep a chosen action available for a fixed number of updates.

const std = @import("std");
const action = @import("action.zig");
const input = @import("input.zig");

/// Keeps each action's most recent press available for its configured duration.
pub fn ActionBuffer(comptime Action: type) type {
    if (@typeInfo(Action) != .@"enum") @compileError("an action buffer needs an enum of actions");
    const count = std.enums.values(Action).len;

    return struct {
        const Self = @This();
        const ActionMap = action.ActionMap(Action);

        windows: [count]f32 = [_]f32{0} ** count,
        remaining: [count]u64 = [_]u64{0} ** count,

        /// Sets how many seconds a press remains available. Invalid windows disable buffering.
        pub fn setWindow(self: *Self, selected: Action, seconds: f32) void {
            const index = @intFromEnum(selected);
            self.windows[index] = if (std.math.isFinite(seconds) and seconds >= 0) seconds else 0;
        }

        /// Updates action windows once per fixed update, after the input for that update is ready.
        /// `dt` is the fixed simulation step in seconds.
        pub fn begin(self: *Self, map: *const ActionMap, state: *const input.Input, dt: f32) void {
            for (std.enums.values(Action)) |selected| {
                const index = @intFromEnum(selected);
                if (map.pressed(state, selected)) {
                    self.remaining[index] = tickCount(self.windows[index], dt);
                } else if (self.remaining[index] > 0) {
                    self.remaining[index] -= 1;
                }
            }
        }

        /// True while the action's buffered press has not expired or been consumed.
        pub fn pending(self: *const Self, selected: Action) bool {
            return self.remaining[@intFromEnum(selected)] > 0;
        }

        /// Clears and returns the pending state, so one press cannot trigger twice.
        pub fn consume(self: *Self, selected: Action) bool {
            const index = @intFromEnum(selected);
            const was_pending = self.remaining[index] > 0;
            self.remaining[index] = 0;
            return was_pending;
        }
    };
}

fn tickCount(seconds: f32, dt: f32) u64 {
    if (seconds <= 0 or !std.math.isFinite(dt) or dt <= 0) return 0;
    const ticks = @ceil(@as(f64, seconds) / @as(f64, dt));
    if (!std.math.isFinite(ticks) or ticks >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
        return std.math.maxInt(u64);
    }
    return @intFromFloat(ticks);
}

const TestAction = enum { jump };
const TestMap = action.ActionMap(TestAction);
const TestBuffer = ActionBuffer(TestAction);
const defaults = action.Defaults(TestAction).init(.{ .jump = &.{.{ .key = .space }} });

fn newMap() TestMap {
    return TestMap.fromDefaults(defaults);
}

test "a zero window preserves only the existing one-latch press edge" {
    const map = newMap();
    var state = input.Input{};
    var buffer = TestBuffer{};
    buffer.setWindow(.jump, 0);

    state.keyDown(.space);
    state.latch();
    buffer.begin(&map, &state, 1.0 / 60.0);
    try std.testing.expect(map.pressed(&state, .jump));
    try std.testing.expect(!buffer.pending(.jump));

    state.latch();
    buffer.begin(&map, &state, 1.0 / 60.0);
    try std.testing.expect(!map.pressed(&state, .jump));
    try std.testing.expect(!buffer.pending(.jump));
}

test "a 100 millisecond window is pending through tick five and expires on tick six" {
    const map = newMap();
    var state = input.Input{};
    var buffer = TestBuffer{};
    const dt: f32 = 1.0 / 60.0;
    buffer.setWindow(.jump, 0.1);

    state.keyDown(.space);
    state.latch();
    buffer.begin(&map, &state, dt);
    try std.testing.expect(buffer.pending(.jump));
    var tick: u32 = 1;
    while (tick <= 5) : (tick += 1) {
        state.latch();
        buffer.begin(&map, &state, dt);
    }
    try std.testing.expect(buffer.consume(.jump));
    try std.testing.expect(!buffer.consume(.jump));

    state.latch();
    buffer.begin(&map, &state, dt);
    try std.testing.expect(!buffer.pending(.jump));
}

test "consuming the press on its first tick prevents a later repeat" {
    const map = newMap();
    var state = input.Input{};
    var buffer = TestBuffer{};
    buffer.setWindow(.jump, 0.1);

    state.keyDown(.space);
    state.latch();
    buffer.begin(&map, &state, 1.0 / 60.0);
    try std.testing.expect(buffer.consume(.jump));
    state.latch();
    buffer.begin(&map, &state, 1.0 / 60.0);
    try std.testing.expect(!buffer.pending(.jump));
}

test "a catch-up update ages the window by one simulation tick, not by a frame" {
    const map = newMap();
    var state = input.Input{};
    var buffer = TestBuffer{};
    buffer.setWindow(.jump, 0.1);

    state.keyDown(.space);
    state.latch();
    buffer.begin(&map, &state, 1.0 / 60.0);
    state.latch();
    buffer.begin(&map, &state, 1.0 / 60.0);
    try std.testing.expect(buffer.pending(.jump));
    try std.testing.expect(buffer.consume(.jump));
}

test "a press during an open window refreshes its full duration" {
    const map = newMap();
    var state = input.Input{};
    var buffer = TestBuffer{};
    const dt: f32 = 1.0 / 60.0;
    buffer.setWindow(.jump, 0.1);

    state.keyDown(.space);
    state.latch();
    buffer.begin(&map, &state, dt);
    var tick: u32 = 0;
    while (tick < 4) : (tick += 1) {
        state.latch();
        buffer.begin(&map, &state, dt);
    }
    state.keyUp(.space);
    state.latch();
    buffer.begin(&map, &state, dt);
    state.keyDown(.space);
    state.latch();
    buffer.begin(&map, &state, dt);

    tick = 0;
    while (tick < 5) : (tick += 1) {
        state.latch();
        buffer.begin(&map, &state, dt);
    }
    try std.testing.expect(buffer.consume(.jump));
    state.latch();
    buffer.begin(&map, &state, dt);
    try std.testing.expect(!buffer.pending(.jump));
}

test "a press and release in one latch arms the buffer without held state" {
    const map = newMap();
    var state = input.Input{};
    var buffer = TestBuffer{};
    buffer.setWindow(.jump, 0.1);

    state.keyDown(.space);
    state.keyUp(.space);
    state.latch();
    buffer.begin(&map, &state, 1.0 / 60.0);
    try std.testing.expect(map.pressed(&state, .jump));
    try std.testing.expect(!map.held(&state, .jump));
    try std.testing.expect(buffer.pending(.jump));
}

test "invalid windows do not arm an action" {
    const map = newMap();
    var state = input.Input{};
    var buffer = TestBuffer{};
    buffer.setWindow(.jump, std.math.nan(f32));
    state.keyDown(.space);
    state.latch();
    buffer.begin(&map, &state, 1.0 / 60.0);
    try std.testing.expect(!buffer.pending(.jump));

    buffer.setWindow(.jump, -1);
    state.keyUp(.space);
    state.latch();
    state.keyDown(.space);
    state.latch();
    buffer.begin(&map, &state, 1.0 / 60.0);
    try std.testing.expect(!buffer.pending(.jump));
}

test "a one-step window survives its press tick" {
    const map = newMap();
    var state = input.Input{};
    var buffer = TestBuffer{};
    buffer.setWindow(.jump, 1.0 / 60.0);
    state.keyDown(.space);
    state.latch();
    buffer.begin(&map, &state, 1.0 / 60.0);
    try std.testing.expect(buffer.pending(.jump));
}

test "replay input restoration does not rewind the action countdown" {
    const map = newMap();
    var state = input.Input{};
    var buffer = TestBuffer{};
    const dt: f32 = 1.0 / 60.0;
    buffer.setWindow(.jump, 0.1);

    state.keyDown(.space);
    state.latch();
    const press_snapshot = state.snapshot();
    buffer.begin(&map, &state, dt);

    state.latch();
    buffer.begin(&map, &state, dt);
    const no_press_snapshot = state.snapshot();
    state.latch();
    buffer.begin(&map, &state, dt);
    state.latch();
    buffer.begin(&map, &state, dt);
    try std.testing.expect(buffer.pending(.jump));

    state.restoreSnapshot(no_press_snapshot);
    buffer.begin(&map, &state, dt);
    try std.testing.expect(buffer.pending(.jump));
    try std.testing.expect(!map.pressed(&state, .jump));

    state.restoreSnapshot(press_snapshot);
    try std.testing.expect(buffer.pending(.jump));
}
