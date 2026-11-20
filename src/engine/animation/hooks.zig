//! Fixed-capacity runtime notifications for authored animation events and playback phases.

pub const Phase = enum {
    event,
    blend_started,
    blend_finished,
    blend_interrupted,
};

pub const Notice = struct {
    phase: Phase,
    name: []const u8 = "",
    id: ?u32 = null,
    from_state: []const u8 = "",
    to_state: []const u8 = "",
    clip: []const u8 = "",
    blend: f32 = 0,
    weight: f32 = 1,
};

pub const Callback = *const fn (context: ?*anyopaque, notice: Notice) void;
pub const capacity = 4;

const Subscription = struct {
    callback: Callback,
    context: ?*anyopaque,
};

pub const Hooks = struct {
    subscribers: [capacity]?Subscription = [_]?Subscription{null} ** capacity,
    count: usize = 0,

    /// Adds a callback in fire order. Re-subscribing the same function and context is idempotent.
    pub fn subscribe(self: *Hooks, context: ?*anyopaque, callback: Callback) bool {
        for (self.subscribers[0..self.count]) |subscription| {
            const existing = subscription.?;
            if (existing.callback == callback and existing.context == context) return true;
        }
        if (self.count == capacity) return false;
        self.subscribers[self.count] = .{ .callback = callback, .context = context };
        self.count += 1;
        return true;
    }

    /// Removes the matching function and context, keeping the remaining fire order unchanged.
    pub fn unsubscribe(self: *Hooks, context: ?*anyopaque, callback: Callback) bool {
        for (self.subscribers[0..self.count], 0..) |subscription, index| {
            const existing = subscription.?;
            if (existing.callback != callback or existing.context != context) continue;
            var move = index + 1;
            while (move < self.count) : (move += 1) self.subscribers[move - 1] = self.subscribers[move];
            self.count -= 1;
            self.subscribers[self.count] = null;
            return true;
        }
        return false;
    }

    /// Fires the subscriptions present at entry, in subscription order.
    pub fn emit(self: *const Hooks, notice: Notice) void {
        const count_at_start = self.count;
        for (self.subscribers[0..count_at_start]) |subscription| {
            const current = subscription.?;
            current.callback(current.context, notice);
        }
    }
};

test "subscriptions are fixed-capacity, unique, and retain order after unsubscribe" {
    const std = @import("std");
    const Recorder = struct {
        values: [8]u8 = undefined,
        count: usize = 0,
        fn recordWith(value: u8, context: ?*anyopaque, notice: Notice) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.values[self.count] = value + @intFromEnum(notice.phase);
            self.count += 1;
        }
        fn first(context: ?*anyopaque, notice: Notice) void {
            recordWith(0, context, notice);
        }
        fn second(context: ?*anyopaque, notice: Notice) void {
            recordWith(1, context, notice);
        }
        fn third(context: ?*anyopaque, notice: Notice) void {
            recordWith(2, context, notice);
        }
        fn fourth(context: ?*anyopaque, notice: Notice) void {
            recordWith(3, context, notice);
        }
        fn fifth(context: ?*anyopaque, notice: Notice) void {
            recordWith(4, context, notice);
        }
    };
    var recorder = Recorder{};
    var hooks = Hooks{};
    try std.testing.expect(hooks.subscribe(&recorder, Recorder.first));
    try std.testing.expect(hooks.subscribe(&recorder, Recorder.first));
    try std.testing.expectEqual(@as(usize, 1), hooks.count);
    try std.testing.expect(hooks.subscribe(&recorder, Recorder.second));
    try std.testing.expect(hooks.subscribe(&recorder, Recorder.third));
    try std.testing.expect(hooks.subscribe(&recorder, Recorder.fourth));
    try std.testing.expect(!hooks.subscribe(&recorder, Recorder.fifth));
    try std.testing.expect(hooks.unsubscribe(&recorder, Recorder.second));
    hooks.emit(.{ .phase = .event });
    try std.testing.expectEqual(@as(usize, 3), recorder.count);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Phase.event)), recorder.values[0]);
    try std.testing.expectEqual(@as(u8, 2 + @intFromEnum(Phase.event)), recorder.values[1]);
    try std.testing.expectEqual(@as(u8, 3 + @intFromEnum(Phase.event)), recorder.values[2]);
}
