//! A render graph for a frame's passes. Each pass declares which resources it reads and writes.
//! `compile` checks those declarations, orders the passes so each one runs after the passes that
//! write its inputs, and gives every transient resource a slot. Two resources share a slot when
//! their lifetimes don't overlap, so a chain of full-view passes, each reading the output of the one
//! before it, needs two slots however long the chain is. The module is pure data with no GPU, so
//! `zig build test` covers it.

const std = @import("std");

/// Most passes a graph holds. Dependencies are kept as bitmasks over passes, so this is also their width.
pub const max_passes = 16;
/// Most resources a graph holds. Each pass's reads and writes are bitmasks over resources.
pub const max_resources = 16;

pub const PassId = u8;
pub const ResourceId = u8;

/// Why `compile` rejects a graph. Each one is a mistake in how the passes were declared.
pub const CompileError = error{
    /// A transient resource is read, but no pass writes it.
    MissingWriter,
    /// A pass writes an external resource. External resources come from outside the graph.
    WrittenExternal,
    /// Two passes write the same resource.
    MultipleWriters,
    /// The passes wait on each other in a loop, so no order runs each one after its inputs. A pass
    /// that reads what it writes is a loop too.
    Cycle,
};

/// Bit `id` of a mask.
fn bit(id: usize) u16 {
    const shift: std.math.Log2Int(u16) = @intCast(id);
    return @as(u16, 1) << shift;
}

fn isSet(mask: u16, id: usize) bool {
    return (mask & bit(id)) != 0;
}

/// A slot is free for a resource written at position `at` when the resource that last used it was
/// last read before `at`. A slot that was never used is free.
fn isFree(occupied_until: ?usize, at: usize) bool {
    return if (occupied_until) |until| until < at else true;
}

/// What the graph knows about one resource.
const Resource = struct {
    external: bool,
};

/// The reads and writes of one pass, as bitmasks over resources.
const Pass = struct {
    reads: u16 = 0,
    writes: u16 = 0,
};

/// The order of a compiled graph, and the slot of each transient resource.
pub const Plan = struct {
    /// Passes in the order they run. Only the first `count` entries are valid.
    order: [max_passes]PassId = [_]PassId{0} ** max_passes,
    count: usize = 0,
    /// The slot each resource uses. External resources, and resources no pass writes, have none.
    slots: [max_resources]?u8 = [_]?u8{null} ** max_resources,
    /// How many slots the transient resources share.
    slot_count: usize = 0,

    /// The slot of `resource`, or null when it has none.
    pub fn slotOf(self: *const Plan, resource: ResourceId) ?u8 {
        return self.slots[resource];
    }
};

pub const Graph = struct {
    resources: [max_resources]Resource = undefined,
    resource_count: usize = 0,
    passes: [max_passes]Pass = [_]Pass{.{}} ** max_passes,
    pass_count: usize = 0,

    /// Adds a resource and returns its id. An external resource comes from outside the graph: the
    /// caller supplies its contents, and no pass may write it.
    pub fn addResource(self: *Graph, external: bool) ResourceId {
        if (self.resource_count == max_resources) {
            std.debug.panic("a render graph holds at most {d} resources", .{max_resources});
        }
        self.resources[self.resource_count] = .{ .external = external };
        const id: ResourceId = @intCast(self.resource_count);
        self.resource_count += 1;
        return id;
    }

    /// Adds a pass that reads `reads` and writes `writes`, and returns its id. Passes with no order
    /// between them run in the order they were added.
    pub fn addPass(self: *Graph, reads: []const ResourceId, writes: []const ResourceId) PassId {
        if (self.pass_count == max_passes) {
            std.debug.panic("a render graph holds at most {d} passes", .{max_passes});
        }
        var pass = Pass{};
        for (reads) |resource| pass.reads |= bit(resource);
        for (writes) |resource| pass.writes |= bit(resource);
        self.passes[self.pass_count] = pass;
        const id: PassId = @intCast(self.pass_count);
        self.pass_count += 1;
        return id;
    }

    /// Checks the declarations and returns the plan. The graph itself is not changed.
    pub fn compile(self: *const Graph) CompileError!Plan {
        // The pass that writes each resource, if one does.
        var writer: [max_resources]?usize = [_]?usize{null} ** max_resources;
        for (self.passes[0..self.pass_count], 0..) |pass, p| {
            for (0..self.resource_count) |r| {
                if (!isSet(pass.writes, r)) continue;
                if (self.resources[r].external) return error.WrittenExternal;
                if (writer[r] != null) return error.MultipleWriters;
                writer[r] = p;
            }
        }

        // Each pass waits for the writers of what it reads. A transient resource with no writer is
        // an error, and a pass that reads its own output is a loop.
        var waits_for: [max_passes]u16 = [_]u16{0} ** max_passes;
        for (self.passes[0..self.pass_count], 0..) |pass, p| {
            for (0..self.resource_count) |r| {
                if (!isSet(pass.reads, r) or self.resources[r].external) continue;
                const w = writer[r] orelse return error.MissingWriter;
                if (w == p) return error.Cycle;
                waits_for[p] |= bit(w);
            }
        }

        // Repeatedly run the lowest-numbered pass whose inputs have all run. Taking the lowest first
        // keeps the order stable, so passes with no order between them keep the order they were added in.
        var plan = Plan{};
        var done: u16 = 0;
        while (plan.count < self.pass_count) {
            var next: ?usize = null;
            for (0..self.pass_count) |p| {
                if (isSet(done, p)) continue;
                if ((waits_for[p] & ~done) != 0) continue;
                next = p;
                break;
            }
            const chosen = next orelse return error.Cycle;
            plan.order[plan.count] = @intCast(chosen);
            plan.count += 1;
            done |= bit(chosen);
        }

        // Walk the passes in order. Each transient resource takes the lowest slot that is free when its
        // writer runs. A slot is free once the resource that used it has had its last reader.
        var position = [_]usize{0} ** max_passes;
        for (plan.order[0..plan.count], 0..) |pass, at| position[pass] = at;

        var occupied_until: [max_resources]?usize = [_]?usize{null} ** max_resources;
        for (plan.order[0..plan.count], 0..) |pass, at| {
            for (0..self.resource_count) |r| {
                if (!isSet(self.passes[pass].writes, r) or self.resources[r].external) continue;

                // The last pass that reads this resource. A resource nobody reads still holds its slot
                // during the pass that writes it.
                var last = at;
                for (self.passes[0..self.pass_count], 0..) |reader, p| {
                    if (isSet(reader.reads, r)) last = @max(last, position[p]);
                }

                var slot: usize = 0;
                while (slot < plan.slot_count and !isFree(occupied_until[slot], at)) : (slot += 1) {}
                if (slot == plan.slot_count) plan.slot_count += 1;
                plan.slots[r] = @intCast(slot);
                occupied_until[slot] = last;
            }
        }
        return plan;
    }
};

test "a chain of passes that each read the last output shares two slots" {
    var graph = Graph{};
    const scene = graph.addResource(true);
    var input = scene;
    var outputs: [4]ResourceId = undefined;
    for (&outputs) |*output| {
        output.* = graph.addResource(false);
        _ = graph.addPass(&.{input}, &.{output.*});
        input = output.*;
    }
    _ = graph.addPass(&.{input}, &.{});

    const plan = try graph.compile();
    try std.testing.expectEqual(@as(usize, 5), plan.count);
    try std.testing.expectEqual(@as(usize, 2), plan.slot_count);
    try std.testing.expectEqual(@as(?u8, 0), plan.slotOf(outputs[0]));
    try std.testing.expectEqual(@as(?u8, 1), plan.slotOf(outputs[1]));
    try std.testing.expectEqual(@as(?u8, 0), plan.slotOf(outputs[2]));
    try std.testing.expectEqual(@as(?u8, 1), plan.slotOf(outputs[3]));
    try std.testing.expectEqual(@as(?u8, null), plan.slotOf(scene));
}

test "a pass runs after the passes that write its inputs, even when it was added first" {
    var graph = Graph{};
    const source = graph.addResource(true);
    const middle = graph.addResource(false);
    const reader = graph.addPass(&.{middle}, &.{});
    const writer = graph.addPass(&.{source}, &.{middle});

    const plan = try graph.compile();
    try std.testing.expectEqual(writer, plan.order[0]);
    try std.testing.expectEqual(reader, plan.order[1]);
}

test "resources that are alive at the same time get different slots" {
    var graph = Graph{};
    const source = graph.addResource(true);
    const left = graph.addResource(false);
    const right = graph.addResource(false);
    _ = graph.addPass(&.{source}, &.{left});
    _ = graph.addPass(&.{source}, &.{right});
    _ = graph.addPass(&.{ left, right }, &.{});

    const plan = try graph.compile();
    try std.testing.expectEqual(@as(usize, 2), plan.slot_count);
    try std.testing.expect(plan.slotOf(left).? != plan.slotOf(right).?);
}

test "an empty graph compiles to an empty plan" {
    var graph = Graph{};
    const plan = try graph.compile();
    try std.testing.expectEqual(@as(usize, 0), plan.count);
    try std.testing.expectEqual(@as(usize, 0), plan.slot_count);
}

test "a transient resource that no pass writes is rejected when something reads it" {
    var graph = Graph{};
    const orphan = graph.addResource(false);
    _ = graph.addPass(&.{orphan}, &.{});
    try std.testing.expectError(error.MissingWriter, graph.compile());
}

test "two passes that write the same resource are rejected" {
    var graph = Graph{};
    const shared = graph.addResource(false);
    _ = graph.addPass(&.{}, &.{shared});
    _ = graph.addPass(&.{}, &.{shared});
    try std.testing.expectError(error.MultipleWriters, graph.compile());
}

test "a pass may not write an external resource" {
    var graph = Graph{};
    const external = graph.addResource(true);
    _ = graph.addPass(&.{}, &.{external});
    try std.testing.expectError(error.WrittenExternal, graph.compile());
}

test "passes that wait on each other are a cycle, and so is a pass that reads its own output" {
    var loop = Graph{};
    const a_out = loop.addResource(false);
    const b_out = loop.addResource(false);
    _ = loop.addPass(&.{b_out}, &.{a_out});
    _ = loop.addPass(&.{a_out}, &.{b_out});
    try std.testing.expectError(error.Cycle, loop.compile());

    var self_read = Graph{};
    const own = self_read.addResource(false);
    _ = self_read.addPass(&.{own}, &.{own});
    try std.testing.expectError(error.Cycle, self_read.compile());
}
