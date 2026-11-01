//! Zig interface to the job system in jobs.h. The C code owns the worker threads and the queue. This file gives them
//! Zig types and a typed way to submit work. The rules jobs must follow are in docs/jobs.md. In short: a job touches
//! only its own data and never the logger, the GPU, the asset arenas, or game state.

const std = @import("std");
const logging = @import("../logging/log.zig");

const c = @cImport({
    @cInclude("jobs.h");
});

/// Counts a group of submitted jobs. Zero it before the first submit, and keep it alive until the group is waited on.
pub const Counter = c.jobs_counter;

/// Worker threads and their queue. Create one for the run, and destroy it after the last job has been waited on.
pub const Pool = struct {
    raw: *c.jobs_pool,

    /// Starts `workers` threads with room for `queue_capacity` queued jobs. Zero workers runs every job on the
    /// thread that submits it.
    pub fn init(workers: u32, queue_capacity: u32) error{OutOfMemory}!Pool {
        // C pointers coerce to optional pointers, so the null check goes through a `?*` binding.
        const maybe: ?*c.jobs_pool = c.jobs_pool_create(workers, queue_capacity);
        const raw = maybe orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Finishes the queued jobs, joins the workers, and frees the pool. Submit nothing while this runs.
    pub fn deinit(self: *Pool) void {
        c.jobs_pool_destroy(self.raw);
        self.* = undefined;
    }

    /// Queues `func(data)`, and adds it to `counter` when one is given. `Data` is the type of the job's data, which
    /// the job receives as a pointer. If the queue is full, the job runs before this returns.
    pub fn submit(self: *Pool, counter: ?*Counter, comptime Data: type, data: *Data, comptime func: fn (*Data) void) void {
        const Trampoline = struct {
            fn run(raw: ?*anyopaque) callconv(.c) void {
                const typed: *Data = @ptrCast(@alignCast(raw.?));
                func(typed);
            }
        };
        const status = c.jobs_submit(self.raw, counter, Trampoline.run, data);
        logging.assert(status == 0, @src(), "a job was submitted with a null pool or function", .{});
    }

    /// Returns once every job added to `counter` has finished. The calling thread runs queued jobs while it waits.
    pub fn wait(self: *Pool, counter: *Counter) void {
        c.jobs_wait(self.raw, counter);
    }

    /// True once every job added to `counter` has finished. Never blocks.
    pub fn isDone(self: *Pool, counter: *const Counter) bool {
        return c.jobs_is_done(self.raw, counter) != 0;
    }

    /// The number of worker threads that are running.
    pub fn workerCount(self: *const Pool) u32 {
        return c.jobs_worker_count(self.raw);
    }
};

// ---- Tests --------------------------------------------------------------------------------------

fn addOne(total: *std.atomic.Value(u32)) void {
    _ = total.fetchAdd(1, .monotonic);
}

test "a pool runs every submitted job once, and wait returns only after all of them" {
    var pool = try Pool.init(3, 16);
    defer pool.deinit();
    var counter = std.mem.zeroes(Counter);
    var total = std.atomic.Value(u32).init(0);
    for (0..200) |_| pool.submit(&counter, std.atomic.Value(u32), &total, addOne);
    pool.wait(&counter);
    try std.testing.expect(pool.isDone(&counter));
    try std.testing.expectEqual(@as(u32, 200), total.load(.monotonic));
}

test "a pool with zero workers runs each job on the submitting thread" {
    var pool = try Pool.init(0, 4);
    defer pool.deinit();
    try std.testing.expectEqual(@as(u32, 0), pool.workerCount());
    var counter = std.mem.zeroes(Counter);
    var total = std.atomic.Value(u32).init(0);
    pool.submit(&counter, std.atomic.Value(u32), &total, addOne);
    try std.testing.expect(pool.isDone(&counter));
    try std.testing.expectEqual(@as(u32, 1), total.load(.monotonic));
}
