//! Background texture loading. A requested texture is decoded on a worker thread, and the main thread uploads it to the
//! GPU and installs it in the texture store between frames. Workers never touch the store, the GPU, or the logger:
//! each worker reads one file, decodes it into its own slot, and reports back through the job counter.
//!
//! Each frame `pump` runs three steps on the main thread, in this order:
//!   1. Upload decodes that finished, at most `max_uploads` per frame, so the GPU work per frame stays bounded.
//!      A decode that finished but waits for a later frame keeps its slot.
//!   2. Report decodes that failed. The store counts them, and the log names each one. A failed texture is not retried
//!      until it is requested again.
//!   3. Start decodes for waiting requests while a slot is free.
//! With zero workers each decode runs inside its submit, so the same steps run with no thread involved.

const std = @import("std");
const jobs = @import("../jobs/jobs.zig");
const staging = @import("../assets/staging.zig");
const platform = @import("../platform/platform.zig");
const logging = @import("../logging/log.zig");
const context = @import("context.zig");

const elog = logging.scoped("engine");

/// Decodes that can be running, or finished but not yet uploaded, at once. Each one holds decoded pixels until it is
/// uploaded, so this also bounds the memory the streamer holds.
pub const max_in_flight = 4;

/// One decode. The streamer owns the slots, and their addresses never change, so a worker can write to its slot.
const Slot = struct {
    counter: jobs.Counter = std.mem.zeroes(jobs.Counter),
    active: bool = false,
    id: u32 = 0,
    path: [platform.max_full_path]u8 = undefined,
    path_len: usize = 0,
    reader: staging.Reader = undefined,
    allocator: std.mem.Allocator = undefined,
    supported: staging.Supported = .{},
    /// Written by the worker. The main thread reads it only after the counter reports the job done.
    staged: ?staging.Staged = null,
    failure: ?staging.Error = null,
};

/// Runs on a worker thread. It reads and decodes one texture into its slot, and touches nothing else.
fn decode(slot: *Slot) void {
    const path = slot.path[0..slot.path_len];
    if (staging.stage(slot.allocator, slot.reader, path, slot.supported)) |staged| {
        slot.staged = staged;
    } else |err| {
        slot.failure = err;
    }
}

pub const Streamer = struct {
    /// The worker threads. The session owns the pool and outlives the streamer.
    pool: *jobs.Pool,
    /// Reads files for the workers. The engine uses the packaged reader, which is safe off the main thread.
    reader: staging.Reader,
    /// Allocates decoded data. It must be safe to use from worker threads.
    allocator: std.mem.Allocator,
    slots: [max_in_flight]Slot = [_]Slot{.{}} ** max_in_flight,

    /// What one `pump` did this frame.
    pub const Report = struct {
        started: usize = 0,
        uploaded: usize = 0,
        failed: usize = 0,
    };

    pub fn init(pool: *jobs.Pool, reader: staging.Reader, allocator: std.mem.Allocator) Streamer {
        return .{ .pool = pool, .reader = reader, .allocator = allocator };
    }

    /// Runs one frame's worth of work. Call it on the main thread, once per frame, before the updates. `max_uploads`
    /// caps the GPU uploads per frame.
    pub fn pump(self: *Streamer, ctx: *const context.Context, store: *context.TextureStore, max_uploads: usize) Report {
        var report = Report{};

        // 1. Upload finished decodes. Uploading first frees their slots for new requests this same frame.
        for (&self.slots) |*slot| {
            if (!slot.active or !self.pool.isDone(&slot.counter)) continue;
            if (slot.failure) |err| {
                slot.active = false;
                slot.failure = null;
                store.failLoad(slot.id);
                report.failed += 1;
                elog.warn("texture '{s}' could not be loaded: {s}", .{ slot.path[0..slot.path_len], @errorName(err) });
                continue;
            }
            if (report.uploaded >= max_uploads) continue;
            var staged = slot.staged orelse {
                slot.active = false;
                store.failLoad(slot.id);
                report.failed += 1;
                continue;
            };
            slot.staged = null;
            slot.active = false;
            const texture = ctx.uploadStaged(&staged);
            elog.debug("streamed texture {s}{s} ({d}x{d})", .{ slot.path[0..slot.path_len], staged.variant, staged.width, staged.height });
            staged.deinit();
            // The store closes the texture itself if a synchronous acquire loaded it first.
            _ = store.finishLoad(slot.id, texture);
            report.uploaded += 1;
        }

        // 3. Start decodes for waiting requests, while there are free slots.
        const supported = ctx.stageFormats();
        for (&self.slots) |*slot| {
            if (slot.active) continue;
            const ticket = store.beginLoad() orelse break;
            report.started += 1;
            if (ticket.path.len > slot.path.len) {
                store.failLoad(ticket.id);
                report.failed += 1;
                elog.warn("texture path is longer than {d} bytes, so it was not loaded", .{slot.path.len});
                continue;
            }
            @memcpy(slot.path[0..ticket.path.len], ticket.path);
            slot.path_len = ticket.path.len;
            slot.id = ticket.id;
            slot.reader = self.reader;
            slot.allocator = self.allocator;
            slot.supported = supported;
            slot.staged = null;
            slot.failure = null;
            slot.active = true;
            self.pool.submit(&slot.counter, Slot, slot, decode);
        }
        return report;
    }

    /// Waits for decodes that are still running, and frees what they produced without uploading it. Call it before the
    /// pool is destroyed and before the texture store closes.
    pub fn deinit(self: *Streamer) void {
        for (&self.slots) |*slot| {
            if (!slot.active) continue;
            self.pool.wait(&slot.counter);
            if (slot.staged) |*staged| staged.deinit();
            slot.staged = null;
            slot.active = false;
        }
    }
};
