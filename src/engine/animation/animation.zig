//! Frame animation for sprite sheets, with validated explicit-frame data and playback.
//! one clip at a time. This is pure code with no SDL, so `zig build test` covers it without a window.
//! The engine knows nothing about characters. The game defines its clips and decides when to play them.

const std = @import("std");

/// One animation: a row of frames on a sprite sheet, played left to right.
pub const Clip = struct {
    /// Sheet row the frames are in. Frame 0 is the left-most cell.
    row: u32,
    /// How many frames play from the row, at least 1.
    frame_count: u32,
    /// Seconds each frame is shown.
    frame_time: f32,
    /// A looping clip starts over after its last frame. A clip that doesn't loop holds its last frame.
    looping: bool,

    /// Length of one play-through, in seconds.
    pub fn duration(self: Clip) f32 {
        return @as(f32, @floatFromInt(self.frame_count)) * self.frame_time;
    }

    /// True when both clips use the same frames and the same timing.
    pub fn same(self: Clip, other: Clip) bool {
        return self.row == other.row and
            self.frame_count == other.frame_count and
            self.frame_time == other.frame_time and
            self.looping == other.looping;
    }
};

/// Plays one clip and tracks how far into it the animation has got. Each entity that animates
/// owns one.
pub const Animator = struct {
    clip: Clip,
    /// Seconds into the current play-through. It stays inside one play-through, so it never grows
    /// large enough to lose precision.
    time: f32 = 0,

    pub fn init(clip: Clip) Animator {
        return .{ .clip = clip };
    }

    /// Switches to `clip`. Asking for the clip that already plays changes nothing, so it's safe to
    /// call every update. A different clip starts from its first frame.
    pub fn play(self: *Animator, clip: Clip) void {
        if (self.clip.same(clip)) return;
        self.clip = clip;
        self.time = 0;
    }

    /// Advances the animation by `dt` seconds.
    pub fn update(self: *Animator, dt: f32) void {
        const length = self.clip.duration();
        if (length <= 0) {
            self.time = 0;
            return;
        }
        self.time += dt;
        if (self.clip.looping) {
            self.time = @mod(self.time, length);
        } else {
            self.time = @min(self.time, length);
        }
    }

    /// The frame to draw now, from 0 to `frame_count - 1`.
    pub fn frame(self: *const Animator) u32 {
        if (self.clip.frame_time <= 0 or self.clip.frame_count == 0) return 0;
        const index: u32 = @intFromFloat(@floor(self.time / self.clip.frame_time));
        return @min(index, self.clip.frame_count - 1);
    }
};

pub const data = @import("data.zig");
pub const Library = data.Library;
pub const Frame = data.Frame;
pub const DataClip = data.Clip;

/// The state machine that chooses clips: states, transitions, conditions, blending, and events.
pub const machine = @import("machine.zig");
pub const Machine = machine.Machine;
pub const MachineDefinition = machine.Definition;

/// Skeletal animation: bones, sprite attachments on them, and keyed bone transforms. See docs/animation.md.
pub const skeleton = @import("skeleton.zig");

/// Plays a validated variable-duration clip using fixed engine update steps.
pub const Timeline = struct {
    clip: *const DataClip,
    time: f32 = 0,

    pub fn init(clip: *const DataClip) Timeline {
        return .{ .clip = clip };
    }

    pub fn play(self: *Timeline, clip: *const DataClip) void {
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

    pub fn frame(self: *const Timeline) *const Frame {
        return &self.clip.frames[self.frameIndex()];
    }

    pub fn finished(self: *const Timeline) bool {
        return !self.clip.looping and self.time >= self.clip.duration();
    }
};

test "variable-duration timeline advances deterministically and holds the last non-looping frame" {
    const source = "animation 1\nclip once once\nframe 0 0 1 1 0.1\nframe 1 0 1 1 0.2\n";
    var library = try data.Library.parse(std.testing.allocator, source, 2, 1);
    defer library.deinit();
    var timeline = Timeline.init(library.find("once").?);
    timeline.update(0.1);
    try std.testing.expectEqual(@as(usize, 1), timeline.frameIndex());
    timeline.update(0.5);
    try std.testing.expect(timeline.finished());
    try std.testing.expectEqual(@as(usize, 1), timeline.frameIndex());
}
