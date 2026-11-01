//! Post-processing: a chain of effect passes that run after the world is drawn and before it is shown.
//!
//! Each effect reads the image the pass before it wrote, and writes a new image. Two targets are enough for a
//! chain of any length. The render graph in render_graph.zig gives each pass's output a target, so consecutive
//! passes alternate between the two targets, and each pass reads only what the pass before it finished writing. The last pass's target is the
//! final image, which the present pass stretches onto the window.
//!
//! An empty chain does nothing, and the world target is presented exactly as it was before effects existed.
//! The chain runs after everything the game draws, so effects also apply to the debug overlay.

const std = @import("std");
const render_graph = @import("render_graph.zig");
const render_types = @import("render_types.zig");
const renderer = @import("renderer.zig");
const sprite = @import("sprite.zig");
const texture = @import("texture.zig");
const backend = @import("backends/sdl_gpu/backend.zig");

pub const Effect = render_types.Effect;

/// Nothing read or written: the present pass reads the final image, and the graph needs an empty list to write.
const no_resources: []const render_graph.ResourceId = &.{};

/// The graph of a chain of `count` effects. The scene is an external input, since the caller draws it. Each effect
/// reads the image before it and writes a new one, and the present pass reads the last image. The plan gives each
/// image a target slot, and the slots alternate, so two targets serve a chain of any length.
fn planChain(count: usize) render_graph.Plan {
    var graph = render_graph.Graph{};
    var input = graph.addResource(true);
    for (0..count) |_| {
        const output = graph.addResource(false);
        _ = graph.addPass(&.{input}, &.{output});
        input = output;
    }
    _ = graph.addPass(&.{input}, no_resources);
    return graph.compile() catch |err| std.debug.panic("post-processing graph is invalid: {s}", .{@errorName(err)});
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
    /// The render graph's plan for this chain. It gives each effect's output one of the two targets.
    plan: render_graph.Plan = .{},
    /// The settings every effect pass reads. `run` pushes them before each pass.
    settings: render_types.PostParams = render_types.default_post_params,

    /// Creates a chain of `effects`, with targets sized `width` by `height`. An empty list makes no GPU
    /// objects. A list longer than `render_types.max_post_effects` panics. The game sets that list, so
    /// the mistake is found at startup.
    pub fn init(allocator: std.mem.Allocator, device: *backend.Device, format: backend.TextureFormat, effects: []const Effect, settings: render_types.PostParams, width: u32, height: u32) Chain {
        if (effects.len > render_types.max_post_effects) {
            std.debug.panic("post-processing chain has {d} effects, more than the {d} allowed", .{ effects.len, render_types.max_post_effects });
        }
        var chain = Chain{ .allocator = allocator, .device = device, .format = format, .count = effects.len, .settings = settings };
        chain.plan = planChain(effects.len);
        if (chain.plan.slot_count > chain.targets.len) {
            std.debug.panic("post-processing needs {d} targets, and a chain has two", .{chain.plan.slot_count});
        }
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
            const target = &self.targets[self.outputSlot(pass)];
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

            backend.post.pushSettings(cmd, &self.settings);
            const pass_handle = renderer.beginPass(cmd, texture.backendTexture(target), clear_black);
            sprite.draw(batch, pass_handle);
            renderer.endPass(pass_handle);

            input = target;
        }
        return input;
    }

    /// The target slot that the effect at `pass` writes. Output i is resource i + 1, since resource 0 is the scene.
    fn outputSlot(self: *const Chain, pass: usize) usize {
        const slot = self.plan.slotOf(@intCast(pass + 1)) orelse {
            std.debug.panic("post-processing pass {d} has no target in its plan", .{pass});
        };
        return slot;
    }
};

test "the chain's plan alternates between two targets, and its outputs are the effects' outputs" {
    const three = planChain(3);
    try std.testing.expectEqual(@as(usize, 2), three.slot_count);
    try std.testing.expectEqual(@as(?u8, null), three.slotOf(0));
    try std.testing.expectEqual(@as(?u8, 0), three.slotOf(1));
    try std.testing.expectEqual(@as(?u8, 1), three.slotOf(2));
    try std.testing.expectEqual(@as(?u8, 0), three.slotOf(3));

    const none = planChain(0);
    try std.testing.expectEqual(@as(usize, 0), none.slot_count);
}

test "a chain of any allowed length fits in its two targets" {
    var count: usize = 0;
    while (count <= render_types.max_post_effects) : (count += 1) {
        try std.testing.expect(planChain(count).slot_count <= 2);
    }
}
