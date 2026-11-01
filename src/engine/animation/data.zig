//! Versioned, text-based sprite animation data. Parsing is independent of rendering and checks
//! every frame rectangle against the source region supplied by the caller.

const std = @import("std");

pub const Frame = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    duration: f32,
};

pub const Clip = struct {
    name: []const u8,
    frames: []const Frame,
    looping: bool,

    pub fn duration(self: Clip) f32 {
        var total: f32 = 0;
        for (self.frames) |frame| total += frame.duration;
        return total;
    }
};

pub const ParseError = std.mem.Allocator.Error || error{
    BadHeader,
    UnsupportedVersion,
    BadClip,
    BadFrame,
    OutOfBounds,
    DuplicateClip,
    MissingClip,
};

pub const Library = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    clips: []Clip,
    clip_count: usize,
    frame_storage: []Frame,

    /// The library owns its source and parsed arrays; its clip names remain valid until deinit.
    pub fn parse(allocator: std.mem.Allocator, source: []const u8, texture_w: u32, texture_h: u32) ParseError!Library {
        const capacity = std.mem.count(u8, source, "\n") + 1;
        const owned_source = try allocator.dupe(u8, source);
        errdefer allocator.free(owned_source);
        const clips = try allocator.alloc(Clip, capacity);
        errdefer allocator.free(clips);
        const frames = try allocator.alloc(Frame, capacity);
        errdefer allocator.free(frames);

        var result = Library{
            .allocator = allocator,
            .source = owned_source,
            .clips = clips,
            .clip_count = 0,
            .frame_storage = frames,
        };
        var have_header = false;
        var active_frame_start: usize = 0;
        var frame_count: usize = 0;

        var lines = std.mem.splitScalar(u8, owned_source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var words = std.mem.tokenizeAny(u8, line, " \t");
            const keyword = words.next() orelse continue;
            if (!have_header) {
                if (!std.mem.eql(u8, keyword, "animation")) return error.BadHeader;
                const version = try parseU32(words.next(), error.BadHeader);
                if (words.next() != null) return error.BadHeader;
                if (version != 1) return error.UnsupportedVersion;
                have_header = true;
                continue;
            }

            if (std.mem.eql(u8, keyword, "clip")) {
                if (result.clip_count > 0) {
                    if (frame_count == active_frame_start) return error.BadClip;
                    result.clips[result.clip_count - 1].frames = frames[active_frame_start..frame_count];
                }
                const name = words.next() orelse return error.BadClip;
                const mode = words.next() orelse return error.BadClip;
                if (words.next() != null or !validName(name)) return error.BadClip;
                const looping = if (std.mem.eql(u8, mode, "loop")) true else if (std.mem.eql(u8, mode, "once")) false else return error.BadClip;
                for (result.clips[0..result.clip_count]) |existing| {
                    if (std.mem.eql(u8, existing.name, name)) return error.DuplicateClip;
                }
                if (result.clip_count == capacity) return error.BadClip;
                result.clips[result.clip_count] = .{ .name = name, .frames = &.{}, .looping = looping };
                result.clip_count += 1;
                active_frame_start = frame_count;
            } else if (std.mem.eql(u8, keyword, "frame")) {
                if (result.clip_count == 0 or frame_count == capacity) return error.BadFrame;
                const x = try parseU32(words.next(), error.BadFrame);
                const y = try parseU32(words.next(), error.BadFrame);
                const w = try parseU32(words.next(), error.BadFrame);
                const h = try parseU32(words.next(), error.BadFrame);
                const duration = try parseDuration(words.next());
                if (words.next() != null or w == 0 or h == 0) return error.BadFrame;
                if (x > texture_w or y > texture_h or w > texture_w - x or h > texture_h - y) return error.OutOfBounds;
                frames[frame_count] = .{ .x = x, .y = y, .w = w, .h = h, .duration = duration };
                frame_count += 1;
            } else {
                return error.BadHeader;
            }
        }

        if (!have_header) return error.BadHeader;
        if (result.clip_count == 0) return error.MissingClip;
        if (frame_count == active_frame_start) return error.BadClip;
        result.clips[result.clip_count - 1].frames = frames[active_frame_start..frame_count];
        return result;
    }

    pub fn deinit(self: *Library) void {
        self.allocator.free(self.frame_storage);
        self.allocator.free(self.clips);
        self.allocator.free(self.source);
        self.* = undefined;
    }

    /// The index of the clip named `name`, or null. The index stays valid until `deinit`.
    pub fn indexOf(self: *const Library, name: []const u8) ?u32 {
        for (self.clips[0..self.clip_count], 0..) |clip, index| {
            if (std.mem.eql(u8, clip.name, name)) return @intCast(index);
        }
        return null;
    }

    pub fn find(self: *const Library, name: []const u8) ?*const Clip {
        for (self.clips[0..self.clip_count]) |*clip| {
            if (std.mem.eql(u8, clip.name, name)) return clip;
        }
        return null;
    }
};

fn parseU32(word: ?[]const u8, comptime err: anytype) ParseError!u32 {
    const text = word orelse return err;
    return std.fmt.parseInt(u32, text, 10) catch return err;
}

fn parseDuration(word: ?[]const u8) ParseError!f32 {
    const text = word orelse return error.BadFrame;
    const value = std.fmt.parseFloat(f32, text) catch return error.BadFrame;
    if (!std.math.isFinite(value) or value <= 0) return error.BadFrame;
    return value;
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |char| {
        if (!((char >= 'a' and char <= 'z') or (char >= '0' and char <= '9') or char == '_')) return false;
    }
    return true;
}

test "versioned animation data parses named clips and owns frame data" {
    const source =
        \\animation 1
        \\clip idle_down loop
        \\frame 0 0 16 32 0.1
        \\clip walk_down loop
        \\frame 16 0 16 32 0.08
        \\frame 32 0 16 32 0.12
    ;
    var library = try Library.parse(std.testing.allocator, source, 48, 32);
    defer library.deinit();
    const walk = library.find("walk_down").?;
    try std.testing.expectEqual(@as(usize, 2), walk.frames.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), walk.duration(), 1e-6);
    try std.testing.expect(walk.looping);
}

test "animation data rejects unsupported versions, duplicate names, bad durations, and out-of-bounds frames" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedVersion, Library.parse(allocator, "animation 2\n", 16, 16));
    try std.testing.expectError(error.DuplicateClip, Library.parse(allocator, "animation 1\nclip idle loop\nframe 0 0 1 1 1\nclip idle once\nframe 0 0 1 1 1\n", 16, 16));
    try std.testing.expectError(error.BadFrame, Library.parse(allocator, "animation 1\nclip idle loop\nframe 0 0 1 1 0\n", 16, 16));
    try std.testing.expectError(error.OutOfBounds, Library.parse(allocator, "animation 1\nclip idle loop\nframe 15 0 2 1 0.1\n", 16, 16));
}
