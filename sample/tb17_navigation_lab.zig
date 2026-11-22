//! TB-17 exercises A*, shared-goal flow fields, follower steering, and changing obstacles.

const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});
const engine = @import("bairava");

const log = engine.log.scoped("tb17");
const Cell = engine.navigation.Cell;
const AgentCount = 64;
const start_cell = Cell{ .col = 1, .row = 1 };
const goal_cell = Cell{ .col = 16, .row = 8 };
const config = engine.Config{
    .title = "Bairava TB-17 Navigation Laboratory",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.035, 0.045, 0.065 },
    .settings_file = "tb17_settings.txt",
};

const map_text =
    \\size 18 10
    \\solid 1
    \\layer ground
    \\1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    \\1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
    \\1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
    \\1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
    \\1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
    \\1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
    \\1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
    \\1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
    \\1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
    \\1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
;

const Scenario = enum(u8) { open, corridor, disconnected, dynamic };

const VizAgent = struct {
    follower: engine.navigation.Follower = .{},
    box: engine.tilemap.Box = .{ .x = 0, .y = 0, .w = 6, .h = 6 },
    spawn: Cell = start_cell,
};

const Tb17 = struct {
    map: engine.tilemap.TileMap,
    texture: engine.Texture,
    pathfinder: engine.navigation.Pathfinder,
    flow: engine.navigation.FlowField,
    path: [engine.navigation.max_path]Cell = undefined,
    path_len: usize = 0,
    scenario: Scenario = .open,
    gate_closed: bool = false,
    agents: [AgentCount]VizAgent = undefined,
    agent_count: usize = 32,
    frames: u64 = 0,
    path_queries: u64 = 0,
    path_failures: u64 = 0,
    no_route_results: u64 = 0,
    expanded_cells: u64 = 0,
    path_length_total: u64 = 0,
    path_time_ticks: u64 = 0,
    flow_rebuilds: u64 = 0,
    flow_time_ticks: u64 = 0,
    dynamic_checks: u64 = 0,
    no_route_checks: u64 = 0,
    corridor_checks: u64 = 0,
    flow_checks: u64 = 0,
    follower_checks: u64 = 0,
    report_written: bool = false,
    last_path_error: ?anyerror = null,

    pub fn init(ctx: *engine.Context) !Tb17 {
        var map = try engine.tilemap.TileMap.parse(ctx.allocators.game, map_text);
        errdefer map.deinit(ctx.allocators.game);
        var texture = try ctx.loadTexture("assets/sample/white.png");
        errdefer texture.deinit();
        var pathfinder = try engine.navigation.Pathfinder.init(ctx.allocators.game);
        errdefer pathfinder.deinit();
        var flow = try engine.navigation.FlowField.init(ctx.allocators.game);
        errdefer flow.deinit();

        var self = Tb17{
            .map = map,
            .texture = texture,
            .pathfinder = pathfinder,
            .flow = flow,
        };
        self.initAgents();
        try self.runFixtures();
        try self.selectScenario(.open);
        ctx.camera.world_w = 320;
        ctx.camera.world_h = 180;
        return self;
    }

    pub fn update(self: *Tb17, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        self.frames += 1;
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.input.wasPressed(.q)) self.selectScenario(.open) catch |err| log.err("open scenario failed: {s}", .{@errorName(err)});
        if (ctx.input.wasPressed(.w)) self.selectScenario(.corridor) catch |err| log.err("corridor scenario failed: {s}", .{@errorName(err)});
        if (ctx.input.wasPressed(.e)) self.selectScenario(.disconnected) catch |err| log.err("disconnected scenario failed: {s}", .{@errorName(err)});
        if (ctx.input.wasPressed(.f)) self.selectScenario(.dynamic) catch |err| log.err("dynamic scenario failed: {s}", .{@errorName(err)});
        if (ctx.input.wasPressed(.space) and self.scenario == .dynamic) self.toggleGate() catch |err| log.err("gate update failed: {s}", .{@errorName(err)});
        if (ctx.input.wasPressed(.equal) or ctx.input.wasPressed(.keypad_plus)) self.agent_count = @min(AgentCount, self.agent_count + 8);
        if (ctx.input.wasPressed(.minus) or ctx.input.wasPressed(.keypad_minus)) self.agent_count = @max(1, self.agent_count -| 8);
        if (ctx.input.wasPressed(.r)) self.rebuildFlow() catch |err| log.err("flow rebuild failed: {s}", .{@errorName(err)});

        self.stepAgents(ctx.dt);
        if (self.frames >= options.frames) {
            self.report(ctx);
            ctx.running = false;
        }
    }

    pub fn draw(self: *Tb17, dc: *const engine.DrawContext) void {
        for (0..self.map.rows) |row| {
            for (0..self.map.cols) |col| {
                const x: f32 = @floatFromInt(col * 16);
                const y: f32 = @floatFromInt(row * 16);
                const blocked = self.map.isSolid(@intCast(col), @intCast(row));
                const tint: [3]f32 = if (blocked)
                    .{ 0.24, 0.27, 0.35 }
                else if (self.flow.cost.len > 0 and self.flow.nextCell(engine.navigation.Grid.init(&self.map), .{
                    .col = @intCast(col),
                    .row = @intCast(row),
                }) != null)
                    .{ 0.11, 0.17, 0.25 }
                else
                    .{ 0.09, 0.12, 0.18 };
                dc.batch.drawSprite(
                    &self.texture,
                    .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                    .{ .x = x, .y = y, .w = 15, .h = 15 },
                    .{ .tint = tint },
                );
            }
        }
        for (self.agents[0..self.agent_count], 0..) |agent, index| {
            const color: [3]f32 = if (index == 0) .{ 1, 0.77, 0.2 } else .{ 0.26, 0.74, 1 };
            dc.batch.drawSprite(
                &self.texture,
                .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                .{ .x = agent.box.x, .y = agent.box.y, .w = agent.box.w, .h = agent.box.h },
                .{ .tint = color },
            );
        }
        dc.batch.drawSprite(
            &self.texture,
            .{ .x = 0, .y = 0, .w = 4, .h = 4 },
            .{ .x = @as(f32, @floatFromInt(goal_cell.col)) * 16 + 5, .y = @as(f32, @floatFromInt(goal_cell.row)) * 16 + 5, .w = 6, .h = 6 },
            .{ .tint = .{ 0.35, 1, 0.47 } },
        );
    }

    pub fn debugText(self: *const Tb17, out: *engine.diagnostics.Text) void {
        out.print("TB-17 Navigation | Q open W corridor E disconnected F dynamic gate Space toggles gate +/- agents R rebuild", .{});
        out.print("Map {s} gate {s} | agents {d} | A* {d} queries, {d} no-route, {d} errors, {d} expanded, avg path {d:.1} cells, CPU {d:.3} ms", .{
            @tagName(self.scenario),
            if (self.gate_closed) "closed" else "open",
            self.agent_count,
            self.path_queries,
            self.no_route_results,
            self.path_failures,
            self.expanded_cells,
            if (self.path_queries == 0) 0 else @as(f64, @floatFromInt(self.path_length_total)) / @as(f64, @floatFromInt(self.path_queries)),
            ticksToMilliseconds(self.path_time_ticks),
        });
        out.print("Flow builds {d}, CPU {d:.3} ms | fixtures: corridor {d}, no-route {d}, dynamic {d}, flow {d}, follower {d}", .{
            self.flow_rebuilds,
            ticksToMilliseconds(self.flow_time_ticks),
            self.corridor_checks,
            self.no_route_checks,
            self.dynamic_checks,
            self.flow_checks,
            self.follower_checks,
        });
    }

    pub fn deinitWithContext(self: *Tb17, ctx: *engine.Context) void {
        self.flow.deinit();
        self.pathfinder.deinit();
        self.texture.deinit();
        self.map.deinit(ctx.allocators.game);
        self.report(ctx);
    }

    pub fn deinit(self: *Tb17) void {
        _ = self;
    }

    fn initAgents(self: *Tb17) void {
        for (&self.agents, 0..) |*agent, index| {
            const col: i32 = 1 + @as(i32, @intCast(index % 3));
            const row: i32 = 1 + @as(i32, @intCast((index / 3) % 7));
            agent.spawn = .{ .col = col, .row = row };
            resetAgent(agent);
        }
    }

    fn resetAgent(agent: *VizAgent) void {
        const center = engine.navigation.cellCenter(agent.spawn);
        agent.box.x = center.x - agent.box.w / 2;
        agent.box.y = center.y - agent.box.h / 2;
        agent.follower.clear();
    }

    fn selectScenario(self: *Tb17, scenario: Scenario) !void {
        self.scenario = scenario;
        self.gate_closed = false;
        self.clearInterior();
        switch (scenario) {
            .open => {
                for (2..7) |row| self.setSolid(8, row, true);
                self.setSolid(8, 4, false);
            },
            .corridor => {
                for (1..17) |col| {
                    if (col != 3) self.setSolid(col, 3, true);
                    if (col != 14) self.setSolid(col, 6, true);
                }
            },
            .disconnected => {
                for (1..17) |col| self.setSolid(col, 4, true);
            },
            .dynamic => {
                for (1..9) |row| self.setSolid(8, row, true);
                self.setSolid(8, 4, false);
            },
        }
        try self.rebuildFlow();
        self.planMainPath();
        self.resetAgents();
    }

    fn toggleGate(self: *Tb17) !void {
        self.gate_closed = !self.gate_closed;
        self.setSolid(8, 4, self.gate_closed);
        try self.rebuildFlow();
        self.planMainPath();
        self.dynamic_checks += 1;
    }

    fn clearInterior(self: *Tb17) void {
        for (1..self.map.rows - 1) |row| {
            for (1..self.map.cols - 1) |col| self.setSolid(col, row, false);
        }
    }

    fn setSolid(self: *Tb17, col: usize, row: usize, solid: bool) void {
        const index = row * @as(usize, self.map.cols) + col;
        self.map.tiles[index] = if (solid) 1 else 0;
    }

    fn planMainPath(self: *Tb17) void {
        var path: [engine.navigation.max_path]Cell = undefined;
        const before = c.clock();
        self.path_queries += 1;
        self.last_path_error = null;
        const length = self.pathfinder.find(engine.navigation.Grid.init(&self.map), start_cell, goal_cell, &path) catch |err| {
            const after = c.clock();
            self.path_time_ticks +%= clockDelta(before, after);
            self.path_len = 0;
            self.last_path_error = err;
            if (err == error.NoPath) {
                self.no_route_results += 1;
            } else {
                self.path_failures += 1;
                log.err("A* query failed: {s}", .{@errorName(err)});
            }
            self.expanded_cells += expandedCount(&self.pathfinder);
            return;
        };
        const after = c.clock();
        self.path_time_ticks +%= clockDelta(before, after);
        self.path_len = length;
        @memcpy(self.path[0..length], path[0..length]);
        self.path_length_total += length;
        self.expanded_cells += expandedCount(&self.pathfinder);
    }

    fn rebuildFlow(self: *Tb17) !void {
        const before = c.clock();
        try self.flow.build(engine.navigation.Grid.init(&self.map), goal_cell);
        const after = c.clock();
        self.flow_time_ticks +%= clockDelta(before, after);
        self.flow_rebuilds += 1;
    }

    fn runFixtures(self: *Tb17) !void {
        try self.selectScenario(.corridor);
        if (self.path_len < 2) return error.CorridorPathMissing;
        self.corridor_checks += 1;

        try self.selectScenario(.disconnected);
        if (self.last_path_error == null or self.last_path_error.? != error.NoPath) return error.DisconnectedMapUnexpectedlyReachable;
        self.no_route_checks += 1;

        try self.selectScenario(.dynamic);
        if (self.path_len < 2) return error.DynamicGateInitiallyBlocked;
        try self.toggleGate();
        if (self.last_path_error == null or self.last_path_error.? != error.NoPath) return error.ClosedGateStillReachable;
        try self.toggleGate();
        if (self.path_len < 2) return error.OpenGatePathMissing;
        self.dynamic_checks += 1;

        var cell = start_cell;
        const grid = engine.navigation.Grid.init(&self.map);
        var steps: usize = 0;
        while (!cell.eql(goal_cell) and steps < self.map.cols * self.map.rows) : (steps += 1) {
            cell = self.flow.nextCell(grid, cell) orelse return error.FlowFieldStalled;
        }
        if (!cell.eql(goal_cell)) return error.FlowFieldDidNotReachGoal;
        self.flow_checks += 1;
        var follower = VizAgent{ .spawn = start_cell };
        resetAgent(&follower);
        steps = 0;
        while (steps < 1000) : (steps += 1) {
            const center = engine.tilemap.Point{
                .x = follower.box.x + follower.box.w / 2,
                .y = follower.box.y + follower.box.h / 2,
            };
            const current = engine.navigation.cellOf(center);
            if (current.eql(goal_cell)) break;
            const next = self.flow.nextCell(grid, current) orelse return error.FollowerFlowStalled;
            const waypoint = engine.navigation.cellCenter(next);
            const position = follower.follower.stepToward(&self.map, follower.box, waypoint, 60, 1.0 / 60.0);
            follower.box.x = position.x;
            follower.box.y = position.y;
        }
        const final_cell = engine.navigation.cellOf(.{
            .x = follower.box.x + follower.box.w / 2,
            .y = follower.box.y + follower.box.h / 2,
        });
        if (!final_cell.eql(goal_cell)) return error.FollowerDidNotReachGoal;
        self.follower_checks += 1;
        try self.selectScenario(.open);
        for (0..AgentCount) |_| self.planMainPath();
    }

    fn resetAgents(self: *Tb17) void {
        const grid = engine.navigation.Grid.init(&self.map);
        var reachable: [18 * 10]Cell = undefined;
        var count: usize = 0;
        for (0..self.map.rows) |row| {
            for (0..self.map.cols) |col| {
                const cell = Cell{ .col = @intCast(col), .row = @intCast(row) };
                if (self.flow.cost[grid.index(cell)] != std.math.maxInt(u32)) {
                    reachable[count] = cell;
                    count += 1;
                }
            }
        }
        if (count == 0) {
            for (&self.agents) |*agent| resetAgent(agent);
            return;
        }
        for (&self.agents, 0..) |*agent, index| {
            agent.spawn = reachable[(index * count) / self.agents.len];
            resetAgent(agent);
        }
    }

    fn stepAgents(self: *Tb17, dt: f32) void {
        const grid = engine.navigation.Grid.init(&self.map);
        for (self.agents[0..self.agent_count]) |*agent| {
            if (engine.navigation.cellOf(.{
                .x = agent.box.x + agent.box.w / 2,
                .y = agent.box.y + agent.box.h / 2,
            }).eql(goal_cell)) continue;
            const here = engine.navigation.cellOf(.{
                .x = agent.box.x + agent.box.w / 2,
                .y = agent.box.y + agent.box.h / 2,
            });
            const next = self.flow.nextCell(grid, here) orelse continue;
            const waypoint = engine.navigation.cellCenter(next);
            const moved = agent.follower.stepToward(&self.map, agent.box, waypoint, 45, dt);
            agent.box.x = moved.x;
            agent.box.y = moved.y;
        }
    }

    fn report(self: *Tb17, ctx: *engine.Context) void {
        if (self.report_written) return;
        self.report_written = true;
        const failed = self.corridor_checks == 0 or self.no_route_checks == 0 or
            self.dynamic_checks < 3 or self.flow_checks == 0 or self.follower_checks == 0 or
            self.path_failures > 0 or self.no_route_results == 0;
        const status: []const u8 = if (failed) "fail" else "pass";
        log.info("TB-17 {s}: A* queries {d}, no-route {d}, errors {d}, expanded {d}, flow rebuilds {d}, fixtures corridor {d}, disconnected {d}, dynamic {d}, flow {d}, follower {d}", .{
            status,
            self.path_queries,
            self.no_route_results,
            self.path_failures,
            self.expanded_cells,
            self.flow_rebuilds,
            self.corridor_checks,
            self.no_route_checks,
            self.dynamic_checks,
            self.flow_checks,
            self.follower_checks,
        });
        var json: [1024]u8 = undefined;
        const result = std.fmt.bufPrint(
            &json,
            \\{{"testbed":"TB-17","scenario":"navigation-laboratory","result":"{s}","frames":{d},"agent_count":{d},"astar_queries":{d},"astar_failures":{d},"no_route_results":{d},"expanded_cells":{d},"total_path_cells":{d},"astar_cpu_ms":{d:.6},"flow_rebuilds":{d},"flow_cpu_ms":{d:.6},"fixture_checks":{{"corridor":{d},"disconnected_no_path":{d},"dynamic_gate":{d},"flow_reaches_goal":{d},"follower_reaches_goal":{d}}},"current_path_length":{d},"current_path_error":"{s}"}}
            \\
        ,
            .{
                status,
                self.frames,
                self.agent_count,
                self.path_queries,
                self.path_failures,
                self.no_route_results,
                self.expanded_cells,
                self.path_length_total,
                ticksToMilliseconds(self.path_time_ticks),
                self.flow_rebuilds,
                ticksToMilliseconds(self.flow_time_ticks),
                self.corridor_checks,
                self.no_route_checks,
                self.dynamic_checks,
                self.flow_checks,
                self.follower_checks,
                self.path_len,
                if (self.last_path_error) |err| @errorName(err) else "none",
            },
        ) catch |err| {
            log.err("TB-17 report formatting failed: {s}", .{@errorName(err)});
            return;
        };
        ctx.writeFile("TB-17-navigation-results.json", result) catch |err| {
            log.err("TB-17 report write failed: {s}", .{@errorName(err)});
        };
    }
};

const Options = struct {
    frames: u64 = 360,
};

var options = Options{};

fn expandedCount(pathfinder: *const engine.navigation.Pathfinder) u64 {
    var count: u64 = 0;
    for (pathfinder.closed) |stamp| {
        if (stamp == pathfinder.stamp) count += 1;
    }
    return count;
}

fn clockDelta(before: c.clock_t, after: c.clock_t) u64 {
    if (before < 0 or after < before) return 0;
    return @intCast(after - before);
}

fn ticksToMilliseconds(ticks: u64) f64 {
    return @as(f64, @floatFromInt(ticks)) * 1000.0 / @as(f64, c.CLOCKS_PER_SEC);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--help")) {
            std.debug.print("TB-17 options: --frames N. Q open map, W narrow corridor, E disconnected route, F dynamic gate; Space toggles gate; +/- changes agents; R rebuilds the flow field; Escape exits.\n", .{});
            return;
        } else if (std.mem.eql(u8, args[index], "--frames") and index + 1 < args.len) {
            index += 1;
            options.frames = try std.fmt.parseUnsigned(u64, args[index], 10);
        } else {
            return error.InvalidArgument;
        }
    }
    if (options.frames == 0 or options.frames > 1_000_000) return error.InvalidArgument;
    try engine.run(engine.SceneHost(Tb17), config);
}
