//! Post-processing: a chain of effect passes that run after the world is drawn and before it is shown.
//!
//! Each effect reads the image the pass before it wrote, and writes a new image. Two targets are enough for a
//! chain of any length. Pass i writes target `targetIndex(i)`, so consecutive passes alternate between the two
//! targets, and each pass reads only what the pass before it finished writing. The last pass's target is the
//! final image, which the present pass stretches onto the window.
//!
//! An empty chain does nothing, and the world target is presented exactly as it was before effects existed.
//! The chain runs after everything the game draws, so effects also apply to the debug overlay.

const std = @import("std");
const render_types = @import("render_types.zig");
const renderer = @import("renderer.zig");
const sprite = @import("sprite.zig");
const texture = @import("texture.zig");
const backend = @import("backends/sdl_gpu/backend.zig");

pub const Effect = render_types.Effect;

/// The target that pass `pass` writes, which is 0 or 1. Consecutive passes write different targets.
pub fn targetIndex(pass: usize) usize {
    return pass % 2;
}

/// The target that holds the final image of a chain of `count` passes, or null for an empty chain.
pub fn finalTargetIndex(count: usize) ?usize {
    if (count == 0) return null;
    return targetIndex(count - 1);
}

/// The clear color behind each pass. Every pass draws a quad over its whole target, so the clear only shows
/// where blending lets the target through. Black keeps that predictable.
const clear_black = render_types.Color{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

/// The effects of one chain, their batches, and the two targets they alternate between.
pub const Chain = struct {
    allocator: std.mem.Allocator,
    device: *backend.Device,
    format: backend.TextureFormat,
    /// How many effects are in use. Only the first `count` entries of the arrays below are valid.
    count: usize = 0,
    effects: [render_types.max_post_effects]Effect = undefined,
    batches: [render_types.max_post_effects]sprite.SpriteBatch = undefined,
    /// The two alternating targets, sized to the view. They exist only while `has_targets` is true.
    targets: [2]texture.Texture = undefined,
    has_targets: bool = false,

    /// Creates a chain of `effects`, with targets sized `width` by `height`. An empty list makes no GPU
    /// objects. A list longer than `render_types.max_post_effects` panics. The game sets that list, so
    /// the mistake is found at startup.
    pub fn init(allocator: std.mem.Allocator, device: *backend.Device, format: backend.TextureFormat, effects: []const Effect, width: u32, height: u32) Chain {
        if (effects.len > render_types.max_post_effects) {
            std.debug.panic("post-processing chain has {d} effects, more than the {d} allowed", .{ effects.len, render_types.max_post_effects });
        }
        var chain = Chain{ .allocator = allocator, .device = device, .format = format, .count = effects.len };
        for (effects, 0..) |effect, i| {
            chain.effects[i] = effect;
            chain.batches[i] = sprite.createEffect(allocator, device, format, effect);
        }
        if (chain.count > 0) chain.resize(width, height);
        return chain;
    }

    /// Releases the targets and the batches. The device must still exist.
    pub fn deinit(self: *Chain) void {
        if (self.has_targets) {
            for (&self.targets) |*target| target.deinit();
            self.has_targets = false;
        }
        for (self.batches[0..self.count]) |*batch| batch.deinit();
        self.* = undefined;
    }

    /// True when the chain has at least one effect, so `run` does work.
    pub fn enabled(self: *const Chain) bool {
        return self.count > 0;
    }

    /// Sizes the two targets to `width` by `height`, the view's size. Does nothing for an empty chain, or when
    /// the targets already have that size. The caller waits for the GPU first, because the old targets may still
    /// be in use. The runtime does that before it rebuilds the world target.
    pub fn resize(self: *Chain, width: u32, height: u32) void {
        if (self.count == 0) return;
        if (self.has_targets and self.targets[0].width == width and self.targets[0].height == height) return;
        if (self.has_targets) {
            for (&self.targets) |*target| target.deinit();
        }
        for (&self.targets) |*target| {
            target.* = texture.createTarget(self.allocator, self.device, width, height, self.format);
        }
        self.has_targets = true;
    }

    /// Runs every effect in order. The first pass reads `source`, the world image, which must be the size the
    /// chain was resized to. Returns the texture the present pass should draw. With no effects that is `source`.
    pub fn run(self: *Chain, cmd: *backend.CommandBuffer, source: *const texture.Texture) *const texture.Texture {
        if (self.count == 0) return source;
        if (!self.has_targets) std.debug.panic("post-processing ran before its targets were sized", .{});

        var input = source;
        for (self.batches[0..self.count], 0..) |*batch, pass| {
            const target = &self.targets[targetIndex(pass)];
            const full = sprite.Rect{
                .x = 0,
                .y = 0,
                .w = @floatFromInt(target.width),
                .h = @floatFromInt(target.height),
            };
            const sampled = sprite.Rect{
                .x = 0,
                .y = 0,
                .w = @floatFromInt(input.width),
                .h = @floatFromInt(input.height),
            };

            // One quad covers the whole target and samples the whole input. The batch is set up and uploaded
            // outside the render pass, as the world batch is.
            batch.begin(full.w, full.h);
            batch.drawSprite(input, sampled, full, .{});
            sprite.upload(batch, cmd);

            const pass_handle = renderer.beginPass(cmd, texture.backendTexture(target), clear_black);
            sprite.draw(batch, pass_handle);
            renderer.endPass(pass_handle);

            input = target;
        }
        return input;
    }
};

test "passes alternate between two targets, and the last pass names the final one" {
    try std.testing.expectEqual(@as(usize, 0), targetIndex(0));
    try std.testing.expectEqual(@as(usize, 1), targetIndex(1));
    try std.testing.expectEqual(@as(usize, 0), targetIndex(2));
    try std.testing.expectEqual(@as(?usize, null), finalTargetIndex(0));
    try std.testing.expectEqual(@as(?usize, 0), finalTargetIndex(1));
    try std.testing.expectEqual(@as(?usize, 1), finalTargetIndex(2));
    try std.testing.expectEqual(@as(?usize, 0), finalTargetIndex(3));
}
