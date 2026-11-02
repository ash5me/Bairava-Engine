//! Queues a skeleton's attachments as sprites. The skeleton data and the pose are pure, so this file only turns them into
//! `drawSprite` calls, the same way tilemap_draw.zig turns tiles into sprites. The batch is a parameter, so tests can pass
//! a stub and need no GPU.

const std = @import("std");

const skeleton = @import("../animation/skeleton.zig");

/// Queues every attachment of `pose`, in the order the data lists them. `texture` is the texture the attachments sample
/// from. `sheet_x` and `sheet_y` locate the source region in that texture, because attachment rectangles are relative to
/// it, as animation frames are. `x` and `y` place the skeleton's origin in view pixels. `tint` and `alpha` apply to every
/// attachment. `pose` must have been evaluated from `data`.
pub fn drawPose(
    batch: anytype,
    texture: anytype,
    data: *const skeleton.Data,
    pose: *const skeleton.Pose,
    sheet_x: f32,
    sheet_y: f32,
    x: f32,
    y: f32,
    tint: [3]f32,
    alpha: f32,
) void {
    for (data.attachmentSlice()) |attachment| {
        const placed = skeleton.place(pose.bones[attachment.bone], attachment);
        batch.drawSprite(
            texture,
            .{
                .x = sheet_x + @as(f32, @floatFromInt(attachment.x)),
                .y = sheet_y + @as(f32, @floatFromInt(attachment.y)),
                .w = @as(f32, @floatFromInt(attachment.w)),
                .h = @as(f32, @floatFromInt(attachment.h)),
            },
            .{
                .x = x + placed.x,
                .y = y + placed.y,
                .w = placed.w,
                .h = placed.h,
            },
            .{
                .tint = tint,
                .alpha = alpha,
                .origin = .{ placed.origin_x, placed.origin_y },
                .rotation = placed.rotation,
            },
        );
    }
}

test "the draw helper queues each attachment from its region, placed on its bone, with the pivot as the origin" {
    const source = "skeleton 1\nbone root - 10 20 0 1\nattach root 2 3 4 4 0 0 2 2\nanim idle loop 1\n";
    var data = try skeleton.Data.parse(std.testing.allocator, source, 16, 16);
    defer data.deinit();
    var pose = skeleton.Pose{};
    skeleton.evaluate(&data, data.findAnimation("idle").?, 0, &pose);

    const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
    const Options = struct {
        tint: [3]f32 = .{ 1, 1, 1 },
        alpha: f32 = 1,
        origin: [2]f32 = .{ 0, 0 },
        rotation: f32 = 0,
    };
    const Recorder = struct {
        calls: usize = 0,
        src: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        dst: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        origin: [2]f32 = .{ 0, 0 },

        fn drawSprite(self: *@This(), image: *const u8, src: Rect, dst: Rect, options: Options) void {
            _ = image;
            self.calls += 1;
            self.src = src;
            self.dst = dst;
            self.origin = options.origin;
        }
    };

    var recorder = Recorder{};
    var texture: u8 = 0;
    drawPose(&recorder, &texture, &data, &pose, 100, 50, 5, 6, .{ 1, 1, 1 }, 1);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    // The region starts at (100, 50) and the attachment's rectangle at (2, 3) within it.
    try std.testing.expectApproxEqAbs(@as(f32, 102), recorder.src.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 53), recorder.src.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 4), recorder.src.w, 1e-5);
    // The bone is at (10, 20), the pivot is 2 pixels into the sprite, and the view origin is (5, 6).
    try std.testing.expectApproxEqAbs(@as(f32, 13), recorder.dst.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 24), recorder.dst.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), recorder.origin[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), recorder.origin[1], 1e-5);
}
