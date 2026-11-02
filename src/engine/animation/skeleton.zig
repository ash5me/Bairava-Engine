//! Skeletal animation for 2D sprites: bones in a hierarchy, sprite attachments placed on bones, and keyed bone
//! transforms that interpolate over time. The data is text, and it is validated when it is parsed, as the clip data is.
//! Like the rest of animation/, this file is pure code with no SDL, so `zig build test` covers it without a window.
//! renderer/skeleton_draw.zig turns a pose into sprites.
//!
//! A bone's transform is a similarity: a position, a rotation in radians, and one uniform scale, all relative to its
//! parent. A child inherits its parent's rotation and scale. For these transforms that composes exactly.

const std = @import("std");

/// The most bones one skeleton may hold. A pose is a fixed-size array of this many transforms, so evaluating one needs
/// no allocation.
pub const max_bones = 64;

/// A bone's transform relative to its parent.
pub const Local = struct {
    x: f32,
    y: f32,
    /// Radians, clockwise on screen, the same convention sprite rotation uses.
    rotation: f32,
    /// A uniform scale, greater than zero.
    scale: f32,
};

/// A bone's transform in skeleton space, after its parents have been applied.
pub const World = struct {
    x: f32,
    y: f32,
    rotation: f32,
    scale: f32,
};

const identity = World{ .x = 0, .y = 0, .rotation = 0, .scale = 1 };

pub const Bone = struct {
    name: []const u8,
    /// Index of the parent bone. The first bone is the root and has no parent. Every other bone's parent comes before it.
    parent: ?u32,
    /// The transform the bone has when no animation moves it.
    rest: Local,
};

/// One sprite drawn on a bone. `x`, `y`, `w`, and `h` name the texels it samples, relative to the source region. The
/// pivot is the point where the sprite sits on its bone and turns: `offset_x` and `offset_y` place it in the bone's
/// space, and `pivot_x` and `pivot_y` name it inside the sprite, in the sprite's own pixels.
pub const Attachment = struct {
    bone: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    offset_x: f32,
    offset_y: f32,
    pivot_x: f32,
    pivot_y: f32,
};

/// Where and how to draw an attachment. `x`, `y`, `w`, and `h` describe its rectangle before rotation, in the pose's
/// pixels. `origin_x` and `origin_y` are the point inside that rectangle that the rotation turns around.
pub const Placement = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    origin_x: f32,
    origin_y: f32,
    rotation: f32,
};

/// What a track changes on its bone.
pub const Kind = enum { rotate, translate, scale };

/// One keyed value. A rotate or scale key uses `value[0]`. A translate key uses both entries, x and then y.
pub const Key = struct {
    time: f32,
    value: [2]f32,
};

/// The keys for one property of one bone, in increasing time order.
pub const Track = struct {
    bone: u32,
    kind: Kind,
    keys: []const Key,
};

/// A named animation: its length in seconds, whether it loops, and the tracks that move bones.
pub const Animation = struct {
    name: []const u8,
    length: f32,
    looping: bool,
    tracks: []const Track,
};

/// The world transform of every bone at one moment. `bones[i]` belongs to bone `i`, and only the first `count` are set.
pub const Pose = struct {
    bones: [max_bones]World = [_]World{identity} ** max_bones,
    count: usize = 0,
};

pub const ParseError = std.mem.Allocator.Error || error{
    BadHeader,
    UnsupportedVersion,
    BadBone,
    BadAttachment,
    BadAnimation,
    BadKey,
    OutOfBounds,
    DuplicateName,
    UnknownBone,
    MissingBone,
    TooManyBones,
};

/// The most words one line may hold for any keyword. The longest keyword takes ten, so a longer line fails its
/// keyword's field-count check.
const max_fields = 16;

const Words = struct {
    items: [max_fields][]const u8 = undefined,
    len: usize = 0,

    fn split(line: []const u8) Words {
        var result = Words{};
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        while (tokens.next()) |word| {
            if (result.len < max_fields) result.items[result.len] = word;
            result.len += 1;
        }
        return result;
    }

    fn slice(self: *const Words) []const []const u8 {
        return self.items[0..@min(self.len, max_fields)];
    }
};

/// A parsed skeleton and its animations. It owns its source text and arrays, and the names it returns stay valid until
/// `deinit`.
pub const Data = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    bone_storage: []Bone,
    bone_count: usize,
    attachment_storage: []Attachment,
    attachment_count: usize,
    animation_storage: []Animation,
    animation_count: usize,
    track_storage: []Track,
    track_count: usize,
    key_storage: []Key,
    key_count: usize,

    /// Parses skeleton text. `region_w` and `region_h` give the size of the source region that attachment rectangles
    /// are relative to, as they do for animation frames.
    pub fn parse(allocator: std.mem.Allocator, source: []const u8, region_w: u32, region_h: u32) ParseError!Data {
        const capacity = std.mem.count(u8, source, "\n") + 1;
        const owned_source = try allocator.dupe(u8, source);
        errdefer allocator.free(owned_source);
        const bones = try allocator.alloc(Bone, @min(capacity, max_bones));
        errdefer allocator.free(bones);
        const attachments = try allocator.alloc(Attachment, capacity);
        errdefer allocator.free(attachments);
        const animations = try allocator.alloc(Animation, capacity);
        errdefer allocator.free(animations);
        const tracks = try allocator.alloc(Track, capacity);
        errdefer allocator.free(tracks);
        const keys = try allocator.alloc(Key, capacity);
        errdefer allocator.free(keys);

        var result = Data{
            .allocator = allocator,
            .source = owned_source,
            .bone_storage = bones,
            .bone_count = 0,
            .attachment_storage = attachments,
            .attachment_count = 0,
            .animation_storage = animations,
            .animation_count = 0,
            .track_storage = tracks,
            .track_count = 0,
            .key_storage = keys,
            .key_count = 0,
        };
        var have_header = false;
        var in_animations = false;
        // The first track of the animation being read. An animation's tracks are contiguous in storage.
        var first_track: usize = 0;
        // The first key of the track being read, so that its keys can be given as one slice.
        var track_key_start: usize = 0;

        var lines = std.mem.splitScalar(u8, owned_source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const words = Words.split(line);
            const fields = words.slice();
            if (fields.len == 0) continue;
            const keyword = fields[0];
            if (!have_header) {
                if (!std.mem.eql(u8, keyword, "skeleton") or fields.len != 2) return error.BadHeader;
                const version = try parseU32(fields[1], error.BadHeader);
                if (version != 1) return error.UnsupportedVersion;
                have_header = true;
            } else if (std.mem.eql(u8, keyword, "bone")) {
                if (in_animations) return error.BadBone;
                try result.addBone(fields);
            } else if (std.mem.eql(u8, keyword, "attach")) {
                if (in_animations) return error.BadAttachment;
                try result.addAttachment(fields, region_w, region_h);
            } else if (std.mem.eql(u8, keyword, "anim")) {
                try result.addAnimation(fields);
                in_animations = true;
                first_track = result.track_count;
            } else if (std.mem.eql(u8, keyword, "key")) {
                if (!in_animations) return error.BadKey;
                track_key_start = try result.addKey(fields, first_track, track_key_start);
            } else {
                return error.BadHeader;
            }
        }

        if (!have_header) return error.BadHeader;
        if (result.bone_count == 0) return error.MissingBone;
        return result;
    }

    pub fn deinit(self: *Data) void {
        self.allocator.free(self.key_storage);
        self.allocator.free(self.track_storage);
        self.allocator.free(self.animation_storage);
        self.allocator.free(self.attachment_storage);
        self.allocator.free(self.bone_storage);
        self.allocator.free(self.source);
        self.* = undefined;
    }

    /// The bones, root first.
    pub fn boneSlice(self: *const Data) []const Bone {
        return self.bone_storage[0..self.bone_count];
    }

    /// The attachments, in the order they are drawn.
    pub fn attachmentSlice(self: *const Data) []const Attachment {
        return self.attachment_storage[0..self.attachment_count];
    }

    /// The index of the bone named `name`, or null.
    pub fn boneIndex(self: *const Data, name: []const u8) ?u32 {
        for (self.bone_storage[0..self.bone_count], 0..) |bone, index| {
            if (std.mem.eql(u8, bone.name, name)) return @intCast(index);
        }
        return null;
    }

    /// The animation named `name`, or null. The pointer stays valid until `deinit`.
    pub fn findAnimation(self: *const Data, name: []const u8) ?*const Animation {
        for (self.animation_storage[0..self.animation_count]) |*animation| {
            if (std.mem.eql(u8, animation.name, name)) return animation;
        }
        return null;
    }

    fn animationIndex(self: *const Data, name: []const u8) ?u32 {
        for (self.animation_storage[0..self.animation_count], 0..) |animation, index| {
            if (std.mem.eql(u8, animation.name, name)) return @intCast(index);
        }
        return null;
    }

    // `bone NAME PARENT X Y ROTATION SCALE`. PARENT is `-` for the first bone only.
    fn addBone(self: *Data, fields: []const []const u8) ParseError!void {
        if (fields.len != 7) return error.BadBone;
        const name = fields[1];
        if (!validName(name)) return error.BadBone;
        if (self.boneIndex(name) != null) return error.DuplicateName;
        var parent: ?u32 = null;
        if (!std.mem.eql(u8, fields[2], "-")) {
            parent = self.boneIndex(fields[2]) orelse return error.UnknownBone;
        }
        if (self.bone_count > 0 and parent == null) return error.BadBone;
        const rest = Local{
            .x = try parseFinite(fields[3], error.BadBone),
            .y = try parseFinite(fields[4], error.BadBone),
            .rotation = try parseFinite(fields[5], error.BadBone),
            .scale = try parseFinite(fields[6], error.BadBone),
        };
        if (rest.scale <= 0) return error.BadBone;
        if (self.bone_count == self.bone_storage.len) return error.TooManyBones;
        self.bone_storage[self.bone_count] = .{ .name = name, .parent = parent, .rest = rest };
        self.bone_count += 1;
    }

    // `attach BONE X Y W H OFFSET_X OFFSET_Y PIVOT_X PIVOT_Y`. The rectangle must lie inside the source region, and the
    // pivot must lie inside the rectangle.
    fn addAttachment(self: *Data, fields: []const []const u8, region_w: u32, region_h: u32) ParseError!void {
        if (fields.len != 10) return error.BadAttachment;
        const bone = self.boneIndex(fields[1]) orelse return error.UnknownBone;
        const x = try parseU32(fields[2], error.BadAttachment);
        const y = try parseU32(fields[3], error.BadAttachment);
        const w = try parseU32(fields[4], error.BadAttachment);
        const h = try parseU32(fields[5], error.BadAttachment);
        if (w == 0 or h == 0) return error.BadAttachment;
        if (x > region_w or y > region_h or w > region_w - x or h > region_h - y) return error.OutOfBounds;
        const offset_x = try parseFinite(fields[6], error.BadAttachment);
        const offset_y = try parseFinite(fields[7], error.BadAttachment);
        const pivot_x = try parseFinite(fields[8], error.BadAttachment);
        const pivot_y = try parseFinite(fields[9], error.BadAttachment);
        if (pivot_x < 0 or pivot_y < 0) return error.BadAttachment;
        if (pivot_x > @as(f32, @floatFromInt(w)) or pivot_y > @as(f32, @floatFromInt(h))) return error.BadAttachment;
        if (self.attachment_count == self.attachment_storage.len) return error.BadAttachment;
        self.attachment_storage[self.attachment_count] = .{
            .bone = bone,
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .offset_x = offset_x,
            .offset_y = offset_y,
            .pivot_x = pivot_x,
            .pivot_y = pivot_y,
        };
        self.attachment_count += 1;
    }

    // `anim NAME loop|once LENGTH`. Animations come after every bone and attachment.
    fn addAnimation(self: *Data, fields: []const []const u8) ParseError!void {
        if (fields.len != 4) return error.BadAnimation;
        const name = fields[1];
        if (!validName(name)) return error.BadAnimation;
        if (self.animationIndex(name) != null) return error.DuplicateName;
        const looping = if (std.mem.eql(u8, fields[2], "loop"))
            true
        else if (std.mem.eql(u8, fields[2], "once"))
            false
        else
            return error.BadAnimation;
        const length = try parseFinite(fields[3], error.BadAnimation);
        if (length <= 0) return error.BadAnimation;
        if (self.animation_count == self.animation_storage.len) return error.BadAnimation;
        self.animation_storage[self.animation_count] = .{
            .name = name,
            .length = length,
            .looping = looping,
            .tracks = self.track_storage[self.track_count..self.track_count],
        };
        self.animation_count += 1;
    }

    // `key BONE rotate|scale TIME VALUE` or `key BONE translate TIME X Y`. The keys of one track must be contiguous and
    // in increasing time order, and they must lie inside the animation's length. Returns the index of the first key of
    // the track the key belongs to.
    fn addKey(self: *Data, fields: []const []const u8, first_track: usize, track_start: usize) ParseError!usize {
        if (fields.len != 5 and fields.len != 6) return error.BadKey;
        const bone = self.boneIndex(fields[1]) orelse return error.UnknownBone;
        const kind = std.meta.stringToEnum(Kind, fields[2]) orelse return error.BadKey;
        const expected: usize = if (kind == .translate) 6 else 5;
        if (fields.len != expected) return error.BadKey;
        const time = try parseFinite(fields[3], error.BadKey);
        var value = [2]f32{ 0, 0 };
        value[0] = try parseFinite(fields[4], error.BadKey);
        if (kind == .translate) value[1] = try parseFinite(fields[5], error.BadKey);
        if (kind == .scale and value[0] <= 0) return error.BadKey;
        const animation = &self.animation_storage[self.animation_count - 1];
        if (time < 0 or time > animation.length) return error.BadKey;
        if (self.key_count == self.key_storage.len) return error.BadKey;

        // A key for the track written last continues that track, so its time must come after the track's last key.
        const continues = self.track_count > first_track and
            self.track_storage[self.track_count - 1].bone == bone and
            self.track_storage[self.track_count - 1].kind == kind;
        if (continues) {
            if (time <= self.key_storage[self.key_count - 1].time) return error.BadKey;
            self.key_storage[self.key_count] = .{ .time = time, .value = value };
            self.key_count += 1;
            self.track_storage[self.track_count - 1].keys = self.key_storage[track_start..self.key_count];
            return track_start;
        }

        // Anything else starts a new track. The same bone and property may not appear twice in one animation.
        for (self.track_storage[first_track..self.track_count]) |existing| {
            if (existing.bone == bone and existing.kind == kind) return error.BadKey;
        }
        if (self.track_count == self.track_storage.len) return error.BadKey;
        const start = self.key_count;
        self.key_storage[self.key_count] = .{ .time = time, .value = value };
        self.key_count += 1;
        self.track_storage[self.track_count] = .{
            .bone = bone,
            .kind = kind,
            .keys = self.key_storage[start..self.key_count],
        };
        self.track_count += 1;
        animation.tracks = self.track_storage[first_track..self.track_count];
        return start;
    }
};

/// Evaluates `animation` at `time` seconds into it, writing every bone's world transform to `out`. A looping animation
/// wraps `time`. A one-shot holds its first key until that key's time and its last key after the last key. A property
/// with no track keeps its rest value. A translate key replaces the bone's position, and rotate and scale keys replace
/// its rotation and scale.
pub fn evaluate(data: *const Data, animation: *const Animation, time: f32, out: *Pose) void {
    const bones = data.boneSlice();
    var locals: [max_bones]Local = undefined;
    for (bones, 0..) |bone, index| locals[index] = bone.rest;
    for (animation.tracks) |track| {
        if (track.keys.len == 0) continue;
        const value = sampleKeys(track.keys, time, animation.length, animation.looping);
        const local = &locals[track.bone];
        switch (track.kind) {
            .rotate => {
                local.rotation = value[0];
            },
            .translate => {
                local.x = value[0];
                local.y = value[1];
            },
            .scale => {
                local.scale = value[0];
            },
        }
    }
    out.count = bones.len;
    for (bones, 0..) |bone, index| {
        const parent = if (bone.parent) |parent_index| out.bones[parent_index] else identity;
        out.bones[index] = compose(parent, locals[index]);
    }
}

/// Where and how to draw `attachment` on a bone whose world transform is `bone`.
pub fn place(bone: World, attachment: Attachment) Placement {
    const c = @cos(bone.rotation);
    const s = @sin(bone.rotation);
    // The pivot sits at the bone's point plus the attachment's offset, in the bone's rotated and scaled space.
    const pivot_x = bone.x + bone.scale * (c * attachment.offset_x - s * attachment.offset_y);
    const pivot_y = bone.y + bone.scale * (s * attachment.offset_x + c * attachment.offset_y);
    // drawSprite rotates the rectangle around its origin, which stays at x + origin_x, y + origin_y. So the rectangle's
    // corner sits one scaled pivot offset away from the pivot, before rotation.
    const origin_x = bone.scale * attachment.pivot_x;
    const origin_y = bone.scale * attachment.pivot_y;
    return .{
        .x = pivot_x - origin_x,
        .y = pivot_y - origin_y,
        .w = bone.scale * @as(f32, @floatFromInt(attachment.w)),
        .h = bone.scale * @as(f32, @floatFromInt(attachment.h)),
        .origin_x = origin_x,
        .origin_y = origin_y,
        .rotation = bone.rotation,
    };
}

/// Plays one animation of a skeleton. The player points into the data, so the data must outlive it.
pub const Player = struct {
    data: *const Data,
    animation: *const Animation,
    /// Seconds into the animation. A looping animation keeps it inside one play-through.
    time: f32 = 0,

    pub fn init(data: *const Data, animation: *const Animation) Player {
        return .{ .data = data, .animation = animation };
    }

    /// Switches to `animation`. Asking for the animation that already plays changes nothing.
    pub fn play(self: *Player, animation: *const Animation) void {
        if (self.animation == animation) return;
        self.animation = animation;
        self.time = 0;
    }

    /// Advances by `dt` seconds. Steps that are not finite or not positive do nothing.
    pub fn update(self: *Player, dt: f32) void {
        if (!std.math.isFinite(dt) or dt <= 0) return;
        const length = self.animation.length;
        if (self.animation.looping) {
            self.time = @mod(self.time + dt, length);
        } else {
            self.time = @min(self.time + dt, length);
        }
    }

    /// True when a one-shot animation has reached its end.
    pub fn finished(self: *const Player) bool {
        return !self.animation.looping and self.time >= self.animation.length;
    }

    /// Writes the pose at the current time.
    pub fn pose(self: *const Player, out: *Pose) void {
        evaluate(self.data, self.animation, self.time, out);
    }
};

fn compose(parent: World, local: Local) World {
    const c = @cos(parent.rotation);
    const s = @sin(parent.rotation);
    return .{
        .x = parent.x + parent.scale * (c * local.x - s * local.y),
        .y = parent.y + parent.scale * (s * local.x + c * local.y),
        .rotation = parent.rotation + local.rotation,
        .scale = parent.scale * local.scale,
    };
}

/// The value of a track at `time`. `keys` is never empty and is in increasing time order.
fn sampleKeys(keys: []const Key, time: f32, length: f32, looping: bool) [2]f32 {
    const first = keys[0];
    const last = keys[keys.len - 1];
    if (keys.len == 1) return first.value;
    const t = if (looping) @mod(time, length) else std.math.clamp(time, 0.0, length);
    if (t < first.time) {
        if (!looping) return first.value;
        // Before the first key, a looping track interpolates from the last key of the previous play-through.
        return lerpPair(last.time - length, last.value, first.time, first.value, t);
    }
    if (t >= last.time) {
        if (!looping) return last.value;
        // After the last key, a looping track interpolates toward the first key of the next play-through.
        return lerpPair(last.time, last.value, first.time + length, first.value, t);
    }
    var index: usize = 0;
    while (keys[index + 1].time <= t) index += 1;
    return lerpPair(keys[index].time, keys[index].value, keys[index + 1].time, keys[index + 1].value, t);
}

fn lerpPair(t0: f32, v0: [2]f32, t1: f32, v1: [2]f32, t: f32) [2]f32 {
    const span = t1 - t0;
    if (!(span > 0)) return v0;
    const fraction = std.math.clamp((t - t0) / span, 0.0, 1.0);
    return .{ v0[0] + (v1[0] - v0[0]) * fraction, v0[1] + (v1[1] - v0[1]) * fraction };
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |char| {
        if (!((char >= 'a' and char <= 'z') or (char >= '0' and char <= '9') or char == '_')) return false;
    }
    return true;
}

fn parseU32(text: []const u8, comptime err: anytype) ParseError!u32 {
    return std.fmt.parseInt(u32, text, 10) catch return err;
}

fn parseFinite(text: []const u8, comptime err: anytype) ParseError!f32 {
    const value = std.fmt.parseFloat(f32, text) catch return err;
    if (!std.math.isFinite(value)) return err;
    return value;
}

test "skeleton data parses bones, attachments, and keyed tracks" {
    const source =
        \\skeleton 1
        \\bone root - 0 0 0 1
        \\bone arm root 4 0 0 1
        \\attach arm 0 0 8 4 0 0 0 2
        \\anim swing loop 1
        \\key arm rotate 0 0
        \\key arm rotate 0.5 0.5
        \\key root translate 0 0 0
        \\key root translate 0.5 2 0
    ;
    var data = try Data.parse(std.testing.allocator, source, 16, 16);
    defer data.deinit();
    try std.testing.expectEqual(@as(usize, 2), data.boneSlice().len);
    try std.testing.expectEqual(@as(?u32, null), data.boneSlice()[0].parent);
    try std.testing.expectEqual(@as(?u32, 0), data.boneSlice()[1].parent);
    try std.testing.expectEqual(@as(usize, 1), data.attachmentSlice().len);
    const swing = data.findAnimation("swing").?;
    try std.testing.expect(swing.looping);
    try std.testing.expectEqual(@as(usize, 2), swing.tracks.len);
    try std.testing.expectEqual(@as(usize, 2), swing.tracks[0].keys.len);
    try std.testing.expectEqual(Kind.translate, swing.tracks[1].kind);
}

test "skeleton data rejects bad versions, names, parents, bounds, and key order" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedVersion, Data.parse(allocator, "skeleton 2\n", 16, 16));
    try std.testing.expectError(error.BadHeader, Data.parse(allocator, "bone root - 0 0 0 1\n", 16, 16));
    try std.testing.expectError(error.MissingBone, Data.parse(allocator, "skeleton 1\n", 16, 16));
    try std.testing.expectError(error.UnknownBone, Data.parse(allocator, "skeleton 1\nbone arm root 0 0 0 1\n", 16, 16));
    try std.testing.expectError(error.DuplicateName, Data.parse(allocator, "skeleton 1\nbone root - 0 0 0 1\nbone root root 0 0 0 1\n", 16, 16));
    try std.testing.expectError(error.BadBone, Data.parse(allocator, "skeleton 1\nbone root - 0 0 0 1\nbone arm - 0 0 0 1\n", 16, 16));
    try std.testing.expectError(error.BadBone, Data.parse(allocator, "skeleton 1\nbone root - 0 0 0 0\n", 16, 16));
    try std.testing.expectError(error.OutOfBounds, Data.parse(allocator, "skeleton 1\nbone root - 0 0 0 1\nattach root 15 0 4 4 0 0 0 0\n", 16, 16));
    try std.testing.expectError(error.BadAttachment, Data.parse(allocator, "skeleton 1\nbone root - 0 0 0 1\nattach root 0 0 4 4 0 0 5 0\n", 16, 16));
    try std.testing.expectError(error.BadBone, Data.parse(allocator, "skeleton 1\nbone root - 0 0 0 1\nanim a loop 1\nbone arm root 0 0 0 1\n", 16, 16));
    try std.testing.expectError(error.BadKey, Data.parse(allocator, "skeleton 1\nbone root - 0 0 0 1\nkey root rotate 0 0\n", 16, 16));
    try std.testing.expectError(error.BadAnimation, Data.parse(allocator, "skeleton 1\nbone root - 0 0 0 1\nanim a sometimes 1\n", 16, 16));
    try std.testing.expectError(error.BadKey, Data.parse(allocator, "skeleton 1\nbone root - 0 0 0 1\nanim a loop 1\nkey root rotate 0 0\nkey root rotate 0 1\n", 16, 16));
    try std.testing.expectError(error.BadKey, Data.parse(allocator, "skeleton 1\nbone root - 0 0 0 1\nanim a once 1\nkey root rotate 1.5 0\n", 16, 16));
    try std.testing.expectError(error.BadKey, Data.parse(allocator, "skeleton 1\nbone root - 0 0 0 1\nanim a loop 1\nkey root scale 0 0\n", 16, 16));
    try std.testing.expectError(error.BadKey, Data.parse(allocator, "skeleton 1\nbone root - 0 0 0 1\nanim a loop 1\nkey root rotate 0 0\nkey root translate 0.5 1 1\nkey root rotate 0.8 1\n", 16, 16));
}

test "a child's world transform follows its parent's rotation and scale" {
    const source = "skeleton 1\nbone root - 0 0 1.5707963 1\nbone arm root 10 0 0 1\nanim hold loop 1\n";
    var data = try Data.parse(std.testing.allocator, source, 16, 16);
    defer data.deinit();
    var pose = Pose{};
    evaluate(&data, data.findAnimation("hold").?, 0, &pose);
    try std.testing.expectEqual(@as(usize, 2), pose.count);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pose.bones[1].x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 10), pose.bones[1].y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5707963), pose.bones[1].rotation, 1e-5);
}

test "keyed rotations interpolate, a loop wraps, and a one-shot holds its last key" {
    const loop_source = "skeleton 1\nbone root - 0 0 0 1\nbone arm root 10 0 0 1\nanim spin loop 2\nkey arm rotate 0 0\nkey arm rotate 1 1\n";
    var loop_data = try Data.parse(std.testing.allocator, loop_source, 16, 16);
    defer loop_data.deinit();
    var pose = Pose{};
    evaluate(&loop_data, loop_data.findAnimation("spin").?, 0.5, &pose);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), pose.bones[1].rotation, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 10), pose.bones[1].x, 1e-5);
    // Between the last key (time 1, value 1) and the first key wrapped to time 2 (value 0).
    evaluate(&loop_data, loop_data.findAnimation("spin").?, 1.5, &pose);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), pose.bones[1].rotation, 1e-5);

    const once_source = "skeleton 1\nbone root - 0 0 0 1\nbone arm root 10 0 0 1\nanim spin once 2\nkey arm rotate 0 0\nkey arm rotate 1 1\n";
    var once_data = try Data.parse(std.testing.allocator, once_source, 16, 16);
    defer once_data.deinit();
    evaluate(&once_data, once_data.findAnimation("spin").?, 5, &pose);
    try std.testing.expectApproxEqAbs(@as(f32, 1), pose.bones[1].rotation, 1e-5);
}

test "translate and scale keys replace the bone's position and scale" {
    const source = "skeleton 1\nbone root - 0 0 0 1\nbone arm root 10 0 0 1\nanim slide once 1\nkey arm translate 0 0 0\nkey arm translate 1 4 2\nkey arm scale 0 1\nkey arm scale 1 3\n";
    var data = try Data.parse(std.testing.allocator, source, 16, 16);
    defer data.deinit();
    var pose = Pose{};
    evaluate(&data, data.findAnimation("slide").?, 0.5, &pose);
    try std.testing.expectApproxEqAbs(@as(f32, 2), pose.bones[1].x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), pose.bones[1].y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), pose.bones[1].scale, 1e-5);
}

test "an attachment's pivot sits on the bone's point, and the sprite turns around it" {
    const at_bone = place(.{ .x = 10, .y = 20, .rotation = 0, .scale = 1 }, .{
        .bone = 0,
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .offset_x = 0,
        .offset_y = 0,
        .pivot_x = 2,
        .pivot_y = 2,
    });
    try std.testing.expectApproxEqAbs(@as(f32, 8), at_bone.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 18), at_bone.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), at_bone.origin_x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 4), at_bone.w, 1e-5);

    // A quarter turn: the pivot is at offset (5, 0) turned to (0, 5), and the rectangle turns with the bone.
    const turned = place(.{ .x = 0, .y = 0, .rotation = 1.5707963, .scale = 1 }, .{
        .bone = 0,
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .offset_x = 5,
        .offset_y = 0,
        .pivot_x = 0,
        .pivot_y = 0,
    });
    try std.testing.expectApproxEqAbs(@as(f32, 0), turned.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 5), turned.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5707963), turned.rotation, 1e-5);

    // A bone scale of 2 doubles the rectangle and the pivot's distances from it.
    const scaled = place(.{ .x = 0, .y = 0, .rotation = 0, .scale = 2 }, .{
        .bone = 0,
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .offset_x = 0,
        .offset_y = 0,
        .pivot_x = 1,
        .pivot_y = 1,
    });
    try std.testing.expectApproxEqAbs(@as(f32, -2), scaled.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 8), scaled.w, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), scaled.origin_x, 1e-5);
}

test "a player wraps a looping animation and holds a one-shot at its end" {
    const source = "skeleton 1\nbone root - 0 0 0 1\nanim loop_anim loop 2\nanim once_anim once 2\n";
    var data = try Data.parse(std.testing.allocator, source, 16, 16);
    defer data.deinit();
    var player = Player.init(&data, data.findAnimation("loop_anim").?);
    player.update(2.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), player.time, 1e-5);
    try std.testing.expect(!player.finished());

    player.play(data.findAnimation("once_anim").?);
    try std.testing.expectEqual(@as(f32, 0), player.time);
    player.update(5);
    try std.testing.expect(player.finished());
    try std.testing.expectApproxEqAbs(@as(f32, 2), player.time, 1e-5);
}
