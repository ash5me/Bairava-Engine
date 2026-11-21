//! TB-05 Collision and Physics Test.
//! Compares the broad-phase index to linear query results across boxes, rotated boxes,
//! circles, layers, trigger overlaps, casts, raycasts, and axis-separated movement.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb05");
const Box = engine.physics.shapes.Box;
const Point = engine.physics.shapes.Point;
const Circle = engine.physics.shapes.Circle;
const Collider = engine.physics.broad_phase.Collider;
const Index = engine.physics.broad_phase.Index;
const Hit = engine.physics.collision.Hit;
const queries = engine.physics.queries;

const Options = struct {
    count: u32 = 100,
    probes: u32 = 1,
    frames: u64 = 180,
};

var options = Options{};

const config = engine.Config{
    .title = "Bairava TB-05 Collision and Physics",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.06, 0.07, 0.09 },
    .settings_file = "tb05_settings.txt",
};

const Tb05 = struct {
    colliders: []Collider,
    index: Index,
    texture: engine.Texture,
    query_count: u64 = 0,
    candidates_seen: u64 = 0,
    parity_failures: u64 = 0,
    ray_hits: u64 = 0,
    box_cast_hits: u64 = 0,
    circle_cast_hits: u64 = 0,
    movement_checks: u64 = 0,
    trigger_enters: u64 = 0,
    trigger_stays: u64 = 0,
    trigger_exits: u64 = 0,
    tick: u64 = 0,
    reported: bool = false,
    previous_pairs: [8]queries.OverlapPair = undefined,
    previous_pair_count: usize = 0,

    pub fn init(ctx: *engine.Context) !Tb05 {
        const colliders = try ctx.allocators.game.alloc(Collider, options.count);
        errdefer ctx.allocators.game.free(colliders);
        for (colliders, 0..) |*collider, i| {
            const ix: u32 = @intCast(i);
            const x = if (ix < 40)
                32 + @as(f32, @floatFromInt(ix % 8)) * 2
            else
                @as(f32, @floatFromInt(ix % 40)) * 12;
            const y = if (ix < 40)
                32 + @as(f32, @floatFromInt(ix / 8)) * 2
            else
                @as(f32, @floatFromInt(ix / 40)) * 12;
            collider.* = .{
                .box = .{ .x = x, .y = y, .w = 8, .h = 8 },
                .layer = @as(u32, 1) << @intCast(ix % 2),
                .rotation = if (ix % 7 == 0) 0.25 else 0,
                .circle = if (ix % 5 == 0) Circle{ .x = x + 4, .y = y + 4, .r = 4 } else null,
                .is_trigger = ix % 17 == 0,
                .enabled = ix % 31 != 0,
            };
        }
        var index = try Index.init(ctx.allocators.game, colliders, 24);
        errdefer index.deinit();
        var texture = try ctx.loadTexture("assets/sample/white.png");
        errdefer texture.deinit();
        return .{ .colliders = colliders, .index = index, .texture = texture };
    }

    pub fn update(self: *Tb05, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.diagnostics.snapshot.frames >= options.frames) self.report(ctx);
        if (self.reported) return;
        self.tick += 1;
        self.verifyTriggerTransitions();

        var probe: u32 = 0;
        while (probe < options.probes) : (probe += 1) {
            const x = @as(f32, @floatFromInt((probe * 53 + @as(u32, @truncate(self.tick * 7))) % 480));
            const scene_height = ((options.count + 39) / 40) * 12;
            const y = @as(f32, @floatFromInt((probe * 29 + @as(u32, @truncate(self.tick * 3))) % scene_height));
            const mask: u32 = if (probe % 2 == 0) 1 else 2;
            const region = Box{ .x = x, .y = y, .w = 18, .h = 18 };

            var linear_hits: [5000]usize = undefined;
            var indexed_hits: [5000]usize = undefined;
            const linear_count = queries.queryRegion(self.colliders, region, mask, &linear_hits);
            const indexed_count = self.index.queryRegion(region, mask, &indexed_hits);
            self.query_count += 1;
            self.candidates_seen += self.index.candidate_count;
            if (linear_count != indexed_count or
                !std.mem.eql(usize, linear_hits[0..linear_count], indexed_hits[0..indexed_count]))
            {
                self.parity_failures += 1;
                log.err("region-query mismatch on update {d}, probe {d}: linear {d}, indexed {d}", .{ self.tick, probe, linear_count, indexed_count });
            }

            const linear_ray = queries.raycast(self.colliders, .{ .x = x, .y = y }, .{ .x = 30, .y = 16 }, mask);
            const indexed_ray = self.index.raycast(.{ .x = x, .y = y }, .{ .x = 30, .y = 16 }, mask);
            if (sameHit(linear_ray, indexed_ray)) {
                if (indexed_ray != null) self.ray_hits += 1;
            } else {
                self.parity_failures += 1;
                log.err("raycast mismatch on update {d}, probe {d}", .{ self.tick, probe });
            }

            const moving_box = Box{ .x = x, .y = y, .w = 6, .h = 6 };
            const linear_box_cast = queries.castBox(self.colliders, moving_box, .{ .x = 32, .y = 0 }, mask);
            const indexed_box_cast = self.index.castBox(moving_box, .{ .x = 32, .y = 0 }, mask);
            if (sameHit(linear_box_cast, indexed_box_cast)) {
                if (indexed_box_cast != null) self.box_cast_hits += 1;
            } else {
                self.parity_failures += 1;
                log.err("box-cast mismatch on update {d}, probe {d}", .{ self.tick, probe });
            }

            const moving_circle = Circle{ .x = x + 3, .y = y + 3, .r = 3 };
            const linear_circle_cast = queries.castCircle(self.colliders, moving_circle, .{ .x = 28, .y = 9 }, mask);
            const indexed_circle_cast = self.index.castCircle(moving_circle, .{ .x = 28, .y = 9 }, mask);
            if (sameHit(linear_circle_cast, indexed_circle_cast)) {
                if (indexed_circle_cast != null) self.circle_cast_hits += 1;
            } else {
                self.parity_failures += 1;
                log.err("circle-cast mismatch on update {d}, probe {d}", .{ self.tick, probe });
            }

            const linear_move = queries.moveBox(self.colliders, moving_box, 32, 12, mask);
            const indexed_move = self.index.moveBox(moving_box, 32, 12, mask);
            self.movement_checks += 1;
            if (!approxPoint(linear_move, indexed_move)) {
                self.parity_failures += 1;
                log.err("movement mismatch on update {d}, probe {d}: linear ({d:.3},{d:.3}), indexed ({d:.3},{d:.3})", .{
                    self.tick,
                    probe,
                    linear_move.x,
                    linear_move.y,
                    indexed_move.x,
                    indexed_move.y,
                });
            }
        }

        if (self.parity_failures > 0) {
            log.err("TB-05 detected {d} broad-phase/linear parity failures", .{self.parity_failures});
            self.reported = false;
            self.report(ctx);
            ctx.running = false;
            return;
        }
    }

    fn verifyTriggerTransitions(self: *Tb05) void {
        var pair: [8]queries.OverlapPair = undefined;
        var events: [8]queries.OverlapEvent = undefined;
        const phase = self.tick % 3;
        const trigger_colliders = [_]Collider{
            .{
                .box = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
                .layer = 1,
                .is_trigger = true,
            },
            .{
                .box = .{ .x = if (phase == 2) 40 else 10, .y = 0, .w = 8, .h = 8 },
                .layer = 1,
            },
        };
        const result = queries.collectTriggerEvents(
            &trigger_colliders,
            self.previous_pairs[0..self.previous_pair_count],
            &pair,
            &events,
        );
        for (events[0..result.event_count]) |event| {
            switch (event.phase) {
                .enter => self.trigger_enters += 1,
                .stay => self.trigger_stays += 1,
                .exit => self.trigger_exits += 1,
            }
        }
        self.previous_pair_count = @min(result.pair_count, pair.len);
        @memcpy(self.previous_pairs[0..self.previous_pair_count], pair[0..self.previous_pair_count]);
    }

    pub fn draw(self: *Tb05, dc: *const engine.DrawContext) void {
        for (self.colliders, 0..) |collider, i| {
            if (!collider.enabled or i >= 500) continue;
            const tint: [3]f32 = if (collider.is_trigger)
                .{ 0.95, 0.55, 0.25 }
            else if (collider.circle != null)
                .{ 0.35, 0.75, 0.95 }
            else
                .{ 0.45, 0.8, 0.5 };
            dc.batch.drawSprite(
                &self.texture,
                .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                .{ .x = collider.box.x, .y = collider.box.y, .w = 8, .h = 8 },
                .{ .tint = tint, .alpha = 0.8, .rotation = collider.rotation, .origin = .{ 4, 4 } },
            );
        }
    }

    fn report(self: *Tb05, ctx: *engine.Context) void {
        if (self.reported) return;
        self.reported = true;
        const frames = ctx.diagnostics.stats.of(.frame);
        const avg_candidates = if (self.query_count == 0)
            0
        else
            @as(f64, @floatFromInt(self.candidates_seen)) / @as(f64, @floatFromInt(self.query_count));
        log.info("TB-05 colliders {d}, query comparisons {d}, parity failures {d}, avg candidates {d:.1}, ray hits {d}, box casts {d}, circle casts {d}, movement checks {d}", .{
            options.count,
            self.query_count,
            self.parity_failures,
            avg_candidates,
            self.ray_hits,
            self.box_cast_hits,
            self.circle_cast_hits,
            self.movement_checks,
        });
        log.info("TB-05 trigger enter/stay/exit {d}/{d}/{d}; frame avg {d:.2} p95 {d:.2} ms", .{
            self.trigger_enters,
            self.trigger_stays,
            self.trigger_exits,
            frames.average() * 1000.0,
            frames.percentile(0.95) * 1000.0,
        });
        var json: [1536]u8 = undefined;
        const text = std.fmt.bufPrint(
            &json,
            "{{\"testbed\":\"TB-05\",\"scenario\":\"collision-physics\",\"result\":\"{s}\",\"colliders\":{d},\"queries\":{d},\"parity_failures\":{d},\"avg_candidates\":{d:.2},\"ray_hits\":{d},\"box_cast_hits\":{d},\"circle_cast_hits\":{d},\"movement_checks\":{d},\"trigger_enters\":{d},\"trigger_stays\":{d},\"trigger_exits\":{d},\"frame_ms_avg\":{d:.3},\"frame_ms_p95\":{d:.3}}}\n",
            .{
                if (self.parity_failures == 0) "pass" else "fail",
                options.count,
                self.query_count,
                self.parity_failures,
                avg_candidates,
                self.ray_hits,
                self.box_cast_hits,
                self.circle_cast_hits,
                self.movement_checks,
                self.trigger_enters,
                self.trigger_stays,
                self.trigger_exits,
                frames.average() * 1000.0,
                frames.percentile(0.95) * 1000.0,
            },
        ) catch |err| {
            log.err("TB-05 metrics could not be formatted: {s}", .{@errorName(err)});
            return;
        };
        ctx.writeFile("TB-05-collision-results.json", text) catch |err| {
            log.err("TB-05 metrics could not be written: {s}", .{@errorName(err)});
        };
    }

    pub fn debugText(self: *const Tb05, out: *engine.diagnostics.Text) void {
        out.print("TB-05: {d} colliders; Escape quits", .{options.count});
        out.print("queries {d} parity errors {d} candidates avg {d:.1}", .{
            self.query_count,
            self.parity_failures,
            if (self.query_count == 0) 0 else @as(f32, @floatFromInt(self.candidates_seen)) / @as(f32, @floatFromInt(self.query_count)),
        });
        out.print("trigger enter/stay/exit {d}/{d}/{d}", .{ self.trigger_enters, self.trigger_stays, self.trigger_exits });
    }

    pub fn deinitWithContext(self: *Tb05, ctx: *engine.Context) void {
        self.index.deinit();
        ctx.allocators.game.free(self.colliders);
        self.texture.deinit();
    }

    pub fn deinit(self: *Tb05) void {
        _ = self;
    }
};

fn sameHit(a: ?Hit, b: ?Hit) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.index == b.?.index and @abs(a.?.fraction - b.?.fraction) <= 0.0001;
}

fn approxPoint(a: Point, b: Point) bool {
    return @abs(a.x - b.x) <= 0.0001 and @abs(a.y - b.y) <= 0.0001;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch return error.InvalidArgument;
    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--count") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.count = try std.fmt.parseUnsigned(u32, args[arg_index], 10);
        } else if (std.mem.eql(u8, arg, "--probes") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.probes = try std.fmt.parseUnsigned(u32, args[arg_index], 10);
        } else if (std.mem.eql(u8, arg, "--frames") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.frames = try std.fmt.parseUnsigned(u64, args[arg_index], 10);
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("TB-05 options: --count 100|500|1000|5000 --probes 1 --frames 180\n", .{});
            return;
        } else {
            return error.InvalidArgument;
        }
    }
    if (!(options.count == 100 or options.count == 500 or options.count == 1000 or options.count == 5000)) return error.InvalidArgument;
    if (options.probes == 0 or options.probes > 256) return error.InvalidArgument;
    try engine.run(engine.SceneHost(Tb05), config);
}
