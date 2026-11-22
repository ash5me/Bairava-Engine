//! TB-14 validates the render graph planner's supported ordering, lifetime, and rejection contracts.

const std = @import("std");
const render_graph = @import("render_graph");

const Options = struct {
    iterations: u32 = 1000,
};

const Results = struct {
    iterations: u32,
    checks: u64 = 0,
    failures: u64 = 0,
    deterministic_fingerprint: u64 = 0,

    fn expect(self: *Results, condition: bool) void {
        self.checks += 1;
        if (!condition) self.failures += 1;
    }
};

fn validateOrderedChain(results: *Results) u64 {
    var graph = render_graph.Graph{};
    const scene = graph.addResource(true);
    var input = scene;
    var outputs: [4]render_graph.ResourceId = undefined;

    for (&outputs) |*output| {
        output.* = graph.addResource(false);
        _ = graph.addPass(&.{input}, &.{output.*});
        input = output.*;
    }
    const present = graph.addPass(&.{input}, &.{});

    const plan = graph.compile() catch {
        results.expect(false);
        return 0;
    };
    results.expect(plan.count == 5);
    results.expect(plan.order[4] == present);
    results.expect(plan.slot_count == 2);
    results.expect(plan.slotOf(scene) == null);
    results.expect(plan.slotOf(outputs[0]) == 0);
    results.expect(plan.slotOf(outputs[1]) == 1);
    results.expect(plan.slotOf(outputs[2]) == 0);
    results.expect(plan.slotOf(outputs[3]) == 1);
    return fingerprint(&plan);
}

fn validateDependencyOrder(results: *Results) u64 {
    var graph = render_graph.Graph{};
    const scene = graph.addResource(true);
    const intermediate = graph.addResource(false);
    const reader = graph.addPass(&.{intermediate}, &.{});
    const writer = graph.addPass(&.{scene}, &.{intermediate});
    const plan = graph.compile() catch {
        results.expect(false);
        return 0;
    };
    results.expect(plan.count == 2);
    results.expect(plan.order[0] == writer);
    results.expect(plan.order[1] == reader);
    results.expect(plan.slotOf(intermediate) == 0);
    return fingerprint(&plan);
}

fn validateOverlappingLifetimes(results: *Results) u64 {
    var graph = render_graph.Graph{};
    const scene = graph.addResource(true);
    const left = graph.addResource(false);
    const right = graph.addResource(false);
    _ = graph.addPass(&.{scene}, &.{left});
    _ = graph.addPass(&.{scene}, &.{right});
    _ = graph.addPass(&.{ left, right }, &.{});
    const plan = graph.compile() catch {
        results.expect(false);
        return 0;
    };
    results.expect(plan.slot_count == 2);
    results.expect(plan.slotOf(left) != plan.slotOf(right));
    return fingerprint(&plan);
}

fn validateRejectedGraphs(results: *Results) u64 {
    var rejected: u64 = 0;

    var missing_writer = render_graph.Graph{};
    const orphan = missing_writer.addResource(false);
    _ = missing_writer.addPass(&.{orphan}, &.{});
    results.expect(compileIs(&missing_writer, error.MissingWriter));
    rejected += 1;

    var multiple_writers = render_graph.Graph{};
    const shared = multiple_writers.addResource(false);
    _ = multiple_writers.addPass(&.{}, &.{shared});
    _ = multiple_writers.addPass(&.{}, &.{shared});
    results.expect(compileIs(&multiple_writers, error.MultipleWriters));
    rejected += 1;

    var external_write = render_graph.Graph{};
    const external = external_write.addResource(true);
    _ = external_write.addPass(&.{}, &.{external});
    results.expect(compileIs(&external_write, error.WrittenExternal));
    rejected += 1;

    var cycle = render_graph.Graph{};
    const a = cycle.addResource(false);
    const b = cycle.addResource(false);
    _ = cycle.addPass(&.{b}, &.{a});
    _ = cycle.addPass(&.{a}, &.{b});
    results.expect(compileIs(&cycle, error.Cycle));
    rejected += 1;

    var self_cycle = render_graph.Graph{};
    const own_output = self_cycle.addResource(false);
    _ = self_cycle.addPass(&.{own_output}, &.{own_output});
    results.expect(compileIs(&self_cycle, error.Cycle));
    rejected += 1;
    return rejected;
}

fn compileIs(graph: *const render_graph.Graph, expected: anyerror) bool {
    _ = graph.compile() catch |err| return err == expected;
    return false;
}

fn fingerprint(plan: *const render_graph.Plan) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (plan.order[0..plan.count]) |pass| {
        hash = (hash ^ pass) *% 0x100000001b3;
    }
    for (plan.slots) |slot| {
        const value: u8 = slot orelse 0xff;
        hash = (hash ^ value) *% 0x100000001b3;
    }
    hash = (hash ^ @as(u64, @intCast(plan.slot_count))) *% 0x100000001b3;
    return hash;
}

fn run(iterations: u32) Results {
    var results = Results{ .iterations = iterations };
    var expected_fingerprint: ?u64 = null;
    for (0..iterations) |_| {
        const a = validateOrderedChain(&results);
        const b = validateDependencyOrder(&results);
        const c = validateOverlappingLifetimes(&results);
        const rejected = validateRejectedGraphs(&results);
        results.expect(rejected == 5);
        const combined = a ^ std.math.rotl(u64, b, 13) ^ std.math.rotl(u64, c, 31) ^ rejected;
        if (expected_fingerprint) |expected| {
            results.expect(combined == expected);
        } else {
            expected_fingerprint = combined;
            results.deterministic_fingerprint = combined;
        }
    }
    return results;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    var options = Options{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--help")) {
            std.debug.print("TB-14 options: --iterations 1000. Validates render-graph ordering, transient-slot lifetimes, deterministic plans, and compile rejection cases.\n", .{});
            return;
        } else if (std.mem.eql(u8, args[index], "--iterations") and index + 1 < args.len) {
            index += 1;
            options.iterations = try std.fmt.parseUnsigned(u32, args[index], 10);
        } else {
            return error.InvalidArgument;
        }
    }
    if (options.iterations == 0 or options.iterations > 1_000_000) return error.InvalidArgument;

    const results = run(options.iterations);
    const status: []const u8 = if (results.failures == 0) "pass" else "fail";
    std.debug.print(
        "{{\"testbed\":\"TB-14\",\"scenario\":\"render-graph-planner\",\"result\":\"{s}\",\"iterations\":{d},\"checks\":{d},\"failures\":{d},\"expected_compile_rejections_per_iteration\":5,\"deterministic_fingerprint\":\"{x}\",\"runtime_resize_validation\":\"unavailable_in_graph_planner\",\"runtime_pass_failure_validation\":\"unavailable_in_graph_planner\"}}\n",
        .{
            status,
            results.iterations,
            results.checks,
            results.failures,
            results.deterministic_fingerprint,
        },
    );
    if (results.failures != 0) return error.ValidationFailed;
}
