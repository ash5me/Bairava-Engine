//! TB-18 exercises worker jobs, bounded-queue overflow, counters, nesting, and shutdown.

const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});
const engine = @import("bairava");

const log = engine.log.scoped("tb18");
const AtomicU32 = std.atomic.Value(u32);
const AtomicU64 = std.atomic.Value(u64);

const Options = struct {
    workers: u32 = 4,
    queue: u32 = 256,
    jobs: u32 = 128,
    iterations: u32 = 200_000,
};

const JobError = enum { none, invalid_input };

const WorkItem = struct {
    index: u32,
    iterations: u32,
    checksum: u64 = 0,
    result_error: JobError = .none,
    active: *AtomicU32,
    peak_active: *AtomicU32,
};

const Child = struct {
    total: *AtomicU64,
    value: u64,
};

const NestedParent = struct {
    pool: *engine.jobs.Pool,
    counter: engine.jobs.Counter = std.mem.zeroes(engine.jobs.Counter),
    total: AtomicU64 = AtomicU64.init(0),
    children: [16]Child = undefined,
};

const Gate = struct {
    started: AtomicU32 = AtomicU32.init(0),
    release: AtomicU32 = AtomicU32.init(0),
    completed: AtomicU32 = AtomicU32.init(0),
};

const Marker = struct {
    completed: *AtomicU32,
};

const ShutdownRelease = struct {
    requested: *AtomicU32,
    gate: *Gate,
};

const Results = struct {
    jobs_submitted: u64 = 0,
    jobs_completed: u64 = 0,
    checksum: u64 = 0,
    failed_job_results: u64 = 0,
    peak_queued_jobs: u32 = 0,
    peak_concurrent_jobs: u32 = 0,
    workers_started: u32 = 0,
    queue_saturation_checks: u64 = 0,
    nested_child_checks: u64 = 0,
    shutdown_pending_checks: u64 = 0,
    error_result_checks: u64 = 0,
    cpu_ticks: u64 = 0,
    fixture_failures: u64 = 0,
};

fn updatePeak(peak: *AtomicU32, candidate: u32) void {
    var observed = peak.load(.monotonic);
    while (observed < candidate) {
        if (peak.cmpxchgWeak(observed, candidate, .monotonic, .monotonic)) |actual| {
            observed = actual;
        } else {
            return;
        }
    }
}

fn runWork(item: *WorkItem) void {
    const active_now = item.active.fetchAdd(1, .monotonic) + 1;
    updatePeak(item.peak_active, active_now);
    var value: u64 = item.index + 1;
    var iteration: u32 = 0;
    while (iteration < item.iterations) : (iteration += 1) {
        value = (value ^ (value >> 13)) *% 0x9e3779b185ebca87;
        value +%= @as(u64, iteration) +% 0x517cc1b727220a95;
    }
    item.checksum = value;
    item.result_error = if (item.iterations == 0) .invalid_input else .none;
    _ = item.active.fetchSub(1, .monotonic);
}

fn runChild(child: *Child) void {
    _ = child.total.fetchAdd(child.value, .monotonic);
}

fn runParent(parent: *NestedParent) void {
    for (&parent.children, 0..) |*child, index| {
        child.* = .{ .total = &parent.total, .value = index + 1 };
        parent.pool.submit(&parent.counter, Child, child, runChild);
    }
    parent.pool.wait(&parent.counter);
}

fn blockOnGate(gate: *Gate) void {
    gate.started.store(1, .release);
    while (gate.release.load(.acquire) == 0) {
        std.atomic.spinLoopHint();
    }
    _ = gate.completed.fetchAdd(1, .monotonic);
}

fn markDone(marker: *Marker) void {
    _ = marker.completed.fetchAdd(1, .monotonic);
}

fn releaseOnShutdown(state: ShutdownRelease) void {
    while (state.requested.load(.acquire) == 0) {
        std.atomic.spinLoopHint();
    }
    state.gate.release.store(1, .release);
}

fn waitUntilStarted(gate: *const Gate) bool {
    var attempts: u32 = 0;
    while (attempts < 10_000_000) : (attempts += 1) {
        if (gate.started.load(.acquire) != 0) return true;
        std.atomic.spinLoopHint();
    }
    return false;
}

fn runSaturationFixture(results: *Results) !void {
    var pool = try engine.jobs.Pool.init(1, 1);
    var counter = std.mem.zeroes(engine.jobs.Counter);
    var gate = Gate{};
    pool.submit(&counter, Gate, &gate, blockOnGate);
    if (!waitUntilStarted(&gate)) {
        gate.release.store(1, .release);
        pool.wait(&counter);
        pool.deinit();
        return error.WorkerDidNotStart;
    }

    var queued = AtomicU32.init(0);
    var marker = Marker{ .completed = &queued };
    pool.submit(&counter, Marker, &marker, markDone);
    var attempts: u32 = 0;
    while (pool.queuedCount() == 0 and attempts < 10_000_000) : (attempts += 1) {
        std.atomic.spinLoopHint();
    }
    if (pool.queuedCount() != 1) {
        gate.release.store(1, .release);
        pool.wait(&counter);
        pool.deinit();
        return error.QueueDidNotFill;
    }

    var overflow_completed = AtomicU32.init(0);
    var overflow = Marker{ .completed = &overflow_completed };
    pool.submit(&counter, Marker, &overflow, markDone);
    const ran_inline = overflow_completed.load(.monotonic) == 1;
    gate.release.store(1, .release);
    pool.wait(&counter);
    const jobs_done = gate.completed.load(.monotonic) == 1 and queued.load(.monotonic) == 1;
    pool.deinit();
    if (!ran_inline or !jobs_done) return error.QueueOverflowContractFailed;
    results.queue_saturation_checks += 1;
}

fn runShutdownFixture(results: *Results) !void {
    var pool = try engine.jobs.Pool.init(1, 2);
    var counter = std.mem.zeroes(engine.jobs.Counter);
    var gate = Gate{};
    pool.submit(&counter, Gate, &gate, blockOnGate);
    if (!waitUntilStarted(&gate)) {
        gate.release.store(1, .release);
        pool.wait(&counter);
        pool.deinit();
        return error.WorkerDidNotStart;
    }

    var completed = AtomicU32.init(0);
    var first = Marker{ .completed = &completed };
    var second = Marker{ .completed = &completed };
    pool.submit(&counter, Marker, &first, markDone);
    pool.submit(&counter, Marker, &second, markDone);
    if (pool.queuedCount() != 2 or pool.isDone(&counter)) {
        gate.release.store(1, .release);
        pool.wait(&counter);
        pool.deinit();
        return error.ShutdownFixtureNotPending;
    }

    var requested = AtomicU32.init(0);
    const release_thread = std.Thread.spawn(.{}, releaseOnShutdown, .{ShutdownRelease{
        .requested = &requested,
        .gate = &gate,
    }}) catch |err| {
        gate.release.store(1, .release);
        pool.wait(&counter);
        pool.deinit();
        return err;
    };
    requested.store(1, .release);
    pool.deinit();
    release_thread.join();
    if (completed.load(.monotonic) != 2 or gate.completed.load(.monotonic) != 1 or counter.pending != 0) {
        return error.PendingJobsLostAtShutdown;
    }
    results.shutdown_pending_checks += 1;
}

fn expectedChecksum(index: u32, iterations: u32) u64 {
    var value: u64 = index + 1;
    var iteration: u32 = 0;
    while (iteration < iterations) : (iteration += 1) {
        value = (value ^ (value >> 13)) *% 0x9e3779b185ebca87;
        value +%= @as(u64, iteration) +% 0x517cc1b727220a95;
    }
    return value;
}

fn parseOptions(args: []const [:0]const u8) !Options {
    var options = Options{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--help")) {
            std.debug.print("TB-18 options: --workers 0..32 --queue 1..4096 --jobs 1..1000000 --iterations 1..250000 (jobs * iterations <= 100000000). Every eighth job does 4x work.\n", .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, args[index], "--workers") and index + 1 < args.len) {
            index += 1;
            options.workers = try std.fmt.parseUnsigned(u32, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--queue") and index + 1 < args.len) {
            index += 1;
            options.queue = try std.fmt.parseUnsigned(u32, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--jobs") and index + 1 < args.len) {
            index += 1;
            options.jobs = try std.fmt.parseUnsigned(u32, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--iterations") and index + 1 < args.len) {
            index += 1;
            options.iterations = try std.fmt.parseUnsigned(u32, args[index], 10);
        } else {
            return error.InvalidArgument;
        }
    }
    if (options.workers > 32 or options.queue == 0 or options.queue > 4096 or
        options.jobs == 0 or options.jobs > 1_000_000 or options.iterations == 0 or options.iterations > 250_000 or
        @as(u64, options.jobs) * options.iterations > 100_000_000)
    {
        return error.InvalidArgument;
    }
    return options;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    const options = parseOptions(args) catch |err| {
        if (err == error.HelpRequested) return;
        return err;
    };

    var results = Results{};
    var pool = try engine.jobs.Pool.init(options.workers, options.queue);
    defer pool.deinit();
    var counter = std.mem.zeroes(engine.jobs.Counter);
    var active = AtomicU32.init(0);
    var peak_active = AtomicU32.init(0);
    const work = try arena.allocator().alloc(WorkItem, options.jobs);
    for (work, 0..) |*item, index| {
        item.* = .{
            .index = @intCast(index),
            .iterations = if (index % 8 == 0) options.iterations * 4 else options.iterations,
            .active = &active,
            .peak_active = &peak_active,
        };
    }
    const before = c.clock();
    for (work) |*item| {
        pool.submit(&counter, WorkItem, item, runWork);
        results.peak_queued_jobs = @max(results.peak_queued_jobs, pool.queuedCount());
        results.jobs_submitted += 1;
    }
    pool.wait(&counter);
    const after = c.clock();
    results.cpu_ticks = if (before >= 0 and after >= before) @intCast(after - before) else 0;
    results.peak_concurrent_jobs = peak_active.load(.monotonic);
    results.workers_started = pool.workerCount();
    for (work, 0..) |item, index| {
        const iterations = if (index % 8 == 0) options.iterations * 4 else options.iterations;
        if (item.result_error != .none or item.checksum != expectedChecksum(@intCast(index), iterations)) {
            results.failed_job_results += 1;
        } else {
            results.jobs_completed += 1;
        }
        results.checksum +%= item.checksum;
    }
    if (!pool.isDone(&counter) or results.failed_job_results != 0) results.fixture_failures += 1;

    var invalid = WorkItem{
        .index = 0,
        .iterations = 0,
        .active = &active,
        .peak_active = &peak_active,
    };
    var error_counter = std.mem.zeroes(engine.jobs.Counter);
    pool.submit(&error_counter, WorkItem, &invalid, runWork);
    pool.wait(&error_counter);
    if (invalid.result_error == .invalid_input) {
        results.error_result_checks += 1;
    } else {
        results.fixture_failures += 1;
    }

    var parent = NestedParent{ .pool = &pool };
    var parent_counter = std.mem.zeroes(engine.jobs.Counter);
    pool.submit(&parent_counter, NestedParent, &parent, runParent);
    pool.wait(&parent_counter);
    if (parent.total.load(.monotonic) == 136 and pool.isDone(&parent.counter)) {
        results.nested_child_checks += 1;
    } else {
        results.fixture_failures += 1;
    }

    runSaturationFixture(&results) catch |err| {
        results.fixture_failures += 1;
        log.err("queue saturation fixture failed: {s}", .{@errorName(err)});
    };
    runShutdownFixture(&results) catch |err| {
        results.fixture_failures += 1;
        log.err("pending shutdown fixture failed: {s}", .{@errorName(err)});
    };

    const passed = results.fixture_failures == 0 and results.queue_saturation_checks == 1 and
        results.nested_child_checks == 1 and results.shutdown_pending_checks == 1 and
        results.error_result_checks == 1;
    const status: []const u8 = if (passed) "pass" else "fail";
    const milliseconds = @as(f64, @floatFromInt(results.cpu_ticks)) * 1000 / @as(f64, c.CLOCKS_PER_SEC);
    std.debug.print(
        "{{\"testbed\":\"TB-18\",\"scenario\":\"job-system-laboratory\",\"result\":\"{s}\",\"workers_requested\":{d},\"workers_started\":{d},\"queue_capacity\":{d},\"peak_queued_jobs\":{d},\"jobs_submitted\":{d},\"jobs_completed\":{d},\"failed_job_results\":{d},\"checksum\":{d},\"peak_concurrent_jobs\":{d},\"cpu_ms\":{d:.3},\"fixture_checks\":{{\"queue_saturation_inline_fallback\":{d},\"nested_jobs_wait\":{d},\"shutdown_drains_pending\":{d},\"job_error_result\":{d}}},\"fixture_failures\":{d}}}\n",
        .{
            status,
            options.workers,
            results.workers_started,
            options.queue,
            results.peak_queued_jobs,
            results.jobs_submitted,
            results.jobs_completed,
            results.failed_job_results,
            results.checksum,
            results.peak_concurrent_jobs,
            milliseconds,
            results.queue_saturation_checks,
            results.nested_child_checks,
            results.shutdown_pending_checks,
            results.error_result_checks,
            results.fixture_failures,
        },
    );
    if (!passed) return error.JobLaboratoryFailed;
}
