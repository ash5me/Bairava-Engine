const std = @import("std");
const engine = @import("bairava");

const tick_count: usize = 120;
const update_hz: u32 = 60;
const seed: u64 = 0x23D371;
const render_rates = [_]u32{ 30, 60, 120 };

const SimulationState = struct {
    position: i64 = 0,
    random_state: u64,

    fn step(self: *SimulationState, input: *const engine.Input) void {
        self.random_state ^= self.random_state >> 12;
        self.random_state ^= self.random_state << 25;
        self.random_state ^= self.random_state >> 27;
        const random_value = self.random_state *% 0x2545f4914f6cdd1d;
        self.position += if (input.held(.space)) 2 else -1;
        if (input.wasPressed(.space)) self.position += 17;
        self.position += @as(i64, @intCast(random_value % 3)) - 1;
    }

    fn serialize(self: SimulationState) [16]u8 {
        var bytes: [16]u8 = undefined;
        for (0..8) |index| {
            bytes[index] = @truncate(@as(u64, @bitCast(self.position)) >> @intCast(index * 8));
            bytes[index + 8] = @truncate(self.random_state >> @intCast(index * 8));
        }
        return bytes;
    }

    fn hash(self: SimulationState) u64 {
        return engine.replay.hashState(&self.serialize());
    }
};

const ReplayRun = struct {
    ticks: usize,
    first_divergent_tick: ?u64,
    checkpoint_matches: usize,
};

fn buildRecording(allocator: std.mem.Allocator) !struct {
    log: engine.replay.Log,
    hashes: [tick_count]u64,
} {
    var log = engine.replay.Log.initWithSeed(allocator, seed, update_hz);
    errdefer log.deinit();
    var input = engine.Input{};
    var state = SimulationState{ .random_state = seed };
    var hashes: [tick_count]u64 = undefined;

    for (0..tick_count) |tick| {
        if (tick == 8 or tick == 66) {
            input.keyDown(.space);
            input.setHeld(.space, true);
        } else if (tick == 32 or tick == 94) {
            input.keyUp(.space);
            input.setHeld(.space, false);
        }
        input.latch();
        try log.recordInput(@intCast(tick), &input);
        state.step(&input);
        hashes[tick] = state.hash();
        if ((tick + 1) % 30 == 0) {
            const bytes = state.serialize();
            _ = try log.recordState(@intCast(tick + 1), &bytes);
        }
    }
    return .{ .log = log, .hashes = hashes };
}

fn replayAtRenderRate(log: *engine.replay.Log, hashes: []const u64, render_hz: u32) !ReplayRun {
    log.rewind();
    var input = engine.Input{};
    var state = SimulationState{ .random_state = log.seed };
    var ticks: usize = 0;
    var checkpoint_matches: usize = 0;
    var accumulator: u64 = 0;

    for (0..render_hz * 2) |_| {
        accumulator += update_hz;
        while (accumulator >= render_hz and ticks < hashes.len) {
            _ = try log.applyNextInput(&input);
            state.step(&input);
            if (state.hash() != hashes[ticks]) {
                return .{
                    .ticks = ticks + 1,
                    .first_divergent_tick = ticks,
                    .checkpoint_matches = checkpoint_matches,
                };
            }
            ticks += 1;
            accumulator -= render_hz;

            if (ticks % 30 == 0) {
                var restored: [16]u8 = undefined;
                const snapshot = try log.restoreStateAtOrBefore(ticks, &restored);
                const current = state.serialize();
                if (snapshot.tick != ticks or !std.mem.eql(u8, &restored, &current)) {
                    return .{
                        .ticks = ticks,
                        .first_divergent_tick = ticks - 1,
                        .checkpoint_matches = checkpoint_matches,
                    };
                }
                checkpoint_matches += 1;
            }
        }
    }
    return .{ .ticks = ticks, .first_divergent_tick = null, .checkpoint_matches = checkpoint_matches };
}

pub fn main() !void {
    var recording = try buildRecording(std.heap.page_allocator);
    defer recording.log.deinit();
    const encoded_size = try recording.log.encodedSize();
    const encoded = try std.heap.page_allocator.alloc(u8, encoded_size);
    defer std.heap.page_allocator.free(encoded);
    _ = try recording.log.encode(encoded);
    var decoded = try engine.replay.Log.decode(std.heap.page_allocator, encoded);
    defer decoded.deinit();

    const metadata = decoded.metadata();
    if (metadata.version != engine.replay.format_version or metadata.seed != seed or
        metadata.update_hz != update_hz or metadata.tick_count != tick_count or metadata.checkpoint_count != 4)
    {
        return error.InvalidReplayMetadata;
    }

    var total_checkpoints: usize = 0;
    for (render_rates) |render_hz| {
        const result = try replayAtRenderRate(&decoded, &recording.hashes, render_hz);
        total_checkpoints += result.checkpoint_matches;
        std.debug.print(
            "{{\"render_hz\":{d},\"ticks\":{d},\"first_divergent_tick\":{any},\"checkpoint_matches\":{d}}}\n",
            .{
                render_hz,
                result.ticks,
                result.first_divergent_tick,
                result.checkpoint_matches,
            },
        );
        if (result.first_divergent_tick != null or result.ticks != tick_count or result.checkpoint_matches != 4) {
            return error.ReplayDiverged;
        }
    }
    std.debug.print(
        "{{\"testbed\":\"TB-23\",\"result\":\"pass\",\"version\":{d},\"seed\":{d},\"update_hz\":{d},\"tick_count\":{d},\"input_frames\":{d},\"checkpoint_count\":{d},\"checkpoint_hash\":{d},\"encoded_bytes\":{d},\"rate_runs\":{d},\"checkpoint_matches\":{d},\"first_divergent_tick\":null}}\n",
        .{
            metadata.version,
            metadata.seed,
            metadata.update_hz,
            metadata.tick_count,
            metadata.input_frame_count,
            metadata.checkpoint_count,
            recording.log.snapshotAtOrBefore(tick_count).?.checksum,
            encoded_size,
            render_rates.len,
            total_checkpoints,
        },
    );
}
