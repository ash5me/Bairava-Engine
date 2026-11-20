//! Variable-duration clip playback, independent of the animation facade and state machine.

const std = @import("std");
const data = @import("data.zig");

pub const Timeline = struct {
    clip: *const data.Clip,
    time: f32 = 0,

    pub fn init(clip: *const data.Clip) Timeline {
        return .{ .clip = clip };
    }

    pub fn play(self: *Timeline, clip: *const data.Clip) void {
        if (self.clip == clip) return;
        self.clip = clip;
        self.time = 0;
    }

    pub fn update(self: *Timeline, dt: f32) void {
        if (!std.math.isFinite(dt) or dt <= 0) return;
        const duration = self.clip.duration();
        if (self.clip.looping) {
            self.time = @mod(self.time + dt, duration);
        } else {
            self.time = @min(self.time + dt, duration);
        }
    }

    pub fn frameIndex(self: *const Timeline) usize {
        var elapsed = self.time;
        for (self.clip.frames, 0..) |frame_value, index| {
            if (elapsed < frame_value.duration or index + 1 == self.clip.frames.len) return index;
            elapsed -= frame_value.duration;
        }
        return 0;
    }

    pub fn frame(self: *const Timeline) *const data.Frame {
        return &self.clip.frames[self.frameIndex()];
    }

    pub fn finished(self: *const Timeline) bool {
        return !self.clip.looping and self.time >= self.clip.duration();
    }
};
