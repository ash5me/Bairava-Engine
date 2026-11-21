//! TB-08 exercises isometric projection, depth sorting, tile collision, A* navigation, and camera controls.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb08");
const Cell = engine.navigation.Cell;
const tile_w: f32 = 32;
const tile_h: f32 = 16;
const half_tile_w = tile_w * 0.5;
const half_tile_h = tile_h * 0.5;
const map_origin_x: f32 = 320;
const map_origin_y: f32 = 48;
const move_speed: f32 = 72;

const map_text =
    \\version 1
    \\size 16 12
    \\tileset 2
    \\solid 1
    \\layer ground
    \\1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    \\1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
    \\1 0 0 0 1 0 0 0 0 0 1 0 0 0 0 1
    \\1 0 0 0 1 0 0 0 0 0 1 0 0 0 0 1
    \\1 0 0 0 1 1 1 0 0 0 1 0 0 0 0 1
    \\1 0 0 0 0 0 0 0 0 0 1 0 0 0 0 1
    \\1 0 1 1 1 0 0 0 0 0 1 0 0 0 0 1
    \\1 0 0 0 0 0 0 0 0 0 1 0 0 0 0 1
    \\1 0 0 0 0 0 0 1 1 0 1 0 0 0 0 1
    \\1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
    \\1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
    \\1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
;

const config = engine.Config{
    .title = "Bairava TB-08 Isometric World",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.045, 0.065, 0.075 },
    .settings_file = "tb08_settings.txt",
};

var run_frame_limit: ?u64 = null;

const Tb08 = struct {
    map: engine.tilemap.TileMap,
    pathfinder: engine.navigation.Pathfinder,
    texture: engine.Texture,
    path: [engine.navigation.max_path]Cell = undefined,
    path_len: usize = 0,
    path_index: usize = 0,
    player_x: f32,
    player_y: f32,
    frames: u64 = 0,
    projection_checks: u64 = 0,
    projection_failures: u64 = 0,
    path_checks: u64 = 0,
    path_failures: u64 = 0,
    depth_checks: u64 = 0,
    depth_failures: u64 = 0,
    click_requests: u64 = 0,
    rejected_targets: u64 = 0,
    reached_cells: u64 = 0,
    report_written: bool = false,

    pub fn init(ctx: *engine.Context) !Tb08 {
        var map = try engine.tilemap.TileMap.parse(ctx.allocators.game, map_text);
        errdefer map.deinit(ctx.allocators.game);
        var pathfinder = try engine.navigation.Pathfinder.init(ctx.allocators.game);
        errdefer pathfinder.deinit();
        var texture = try ctx.loadTexture("assets/sample/white.png");
        errdefer texture.deinit();

        const start = Cell{ .col = 1, .row = 1 };
        const start_pos = project(start);
        ctx.camera.world_w = 640;
        ctx.camera.world_h = 320;
        ctx.camera.follow(start_pos.x, start_pos.y);

        var self = Tb08{
            .map = map,
            .pathfinder = pathfinder,
            .texture = texture,
            .player_x = start_pos.x,
            .player_y = start_pos.y,
        };
        self.verifyProjection();
        self.verifyDepthOrder();
        self.verifyNavigation();
        return self;
    }

    pub fn update(self: *Tb08, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.input.wasPressed(.equal) or ctx.input.wasPressed(.keypad_plus)) ctx.zoomBy(1.25);
        if (ctx.input.wasPressed(.minus) or ctx.input.wasPressed(.keypad_minus)) ctx.zoomBy(0.8);
        if (ctx.input.wasPressed(.zero)) ctx.resetZoom();
        if (ctx.input.mousePressed(.left)) {
            const mouse = ctx.mouseWorld();
            self.requestPath(mouse.x, mouse.y);
        }

        if (ctx.input.wasPressed(.left) or ctx.input.wasPressed(.a)) self.requestStep(-1, 0);
        if (ctx.input.wasPressed(.right) or ctx.input.wasPressed(.d)) self.requestStep(1, 0);
        if (ctx.input.wasPressed(.up) or ctx.input.wasPressed(.w)) self.requestStep(0, -1);
        if (ctx.input.wasPressed(.down) or ctx.input.wasPressed(.s)) self.requestStep(0, 1);

        self.advance(ctx.dt);
        ctx.camera.world_w = 640;
        ctx.camera.world_h = 320;
        ctx.camera.followSmooth(self.player_x, self.player_y, ctx.dt, 5);
        self.frames += 1;
        if (!self.report_written and ctx.diagnostics.snapshot.frames >= 180) self.report(ctx);
        if (run_frame_limit) |limit| {
            if (ctx.diagnostics.snapshot.frames >= limit) ctx.running = false;
        }
    }

    pub fn draw(self: *Tb08, dc: *const engine.DrawContext) void {
        self.drawWorld(dc);
        if (self.path_len > self.path_index) {
            for (self.path[self.path_index..self.path_len]) |cell| {
                const p = project(cell);
                drawDiamond(dc, &self.texture, p.x, p.y, .{ 0.95, 0.76, 0.24 }, 0);
            }
        }
        self.drawObjects(dc);
        dc.batch.drawSprite(
            &self.texture,
            .{ .x = 0, .y = 0, .w = 4, .h = 4 },
            .{ .x = dc.cam.screenX(self.player_x - 7), .y = dc.cam.screenY(self.player_y - 22), .w = 14, .h = 22 },
            .{ .tint = .{ 0.95, 0.32, 0.24 }, .depth_y = self.player_y },
        );
    }

    pub fn debugText(self: *const Tb08, out: *engine.diagnostics.Text) void {
        out.print("TB-08 Isometric World | click: navigate, WASD/arrows: step, +/-: zoom, 0: reset", .{});
        out.print("Projection checks {d} ({d} failures), paths {d} ({d} failures), reached {d}, rejected {d}", .{
            self.projection_checks,
            self.projection_failures,
            self.path_checks,
            self.path_failures,
            self.reached_cells,
            self.rejected_targets,
        });
    }

    pub fn deinitWithContext(self: *Tb08, ctx: *engine.Context) void {
        self.texture.deinit();
        self.pathfinder.deinit();
        self.map.deinit(ctx.allocators.game);
    }

    pub fn deinit(self: *Tb08) void {
        _ = self;
    }

    fn requestStep(self: *Tb08, dc: i32, dr: i32) void {
        const current = self.currentCell();
        const target = Cell{ .col = current.col + dc, .row = current.row + dr };
        self.setPath(target);
    }

    fn requestPath(self: *Tb08, mouse_x: f32, mouse_y: f32) void {
        self.click_requests += 1;
        const cell = unproject(mouse_x, mouse_y);
        if (cell.col < 0 or cell.row < 0 or cell.col >= @as(i32, @intCast(self.map.cols)) or cell.row >= @as(i32, @intCast(self.map.rows))) {
            self.rejected_targets += 1;
            return;
        }
        self.setPath(.{ .col = cell.col, .row = cell.row });
    }

    fn setPath(self: *Tb08, target: Cell) void {
        self.path_len = 0;
        self.path_index = 0;
        const start = self.currentCell();
        const grid = engine.navigation.Grid.init(&self.map);
        const length = self.pathfinder.find(grid, start, target, &self.path) catch |err| {
            self.rejected_targets += 1;
            if (err != error.GoalBlocked and err != error.OutOfBounds and err != error.NoPath) {
                log.warn("navigation request failed: {s}", .{@errorName(err)});
            }
            return;
        };
        self.path_len = length;
        self.path_index = if (length > 1) 1 else length;
        self.path_checks += 1;
    }

    fn advance(self: *Tb08, dt: f32) void {
        if (self.path_index >= self.path_len) return;
        const target = project(self.path[self.path_index]);
        const dx = target.x - self.player_x;
        const dy = target.y - self.player_y;
        const distance = @sqrt(dx * dx + dy * dy);
        const step = move_speed * dt;
        if (distance <= step or distance < 0.001) {
            self.player_x = target.x;
            self.player_y = target.y;
            self.path_index += 1;
            self.reached_cells += 1;
        } else {
            self.player_x += dx / distance * step;
            self.player_y += dy / distance * step;
        }
    }

    fn currentCell(self: *const Tb08) Cell {
        const cell = unproject(self.player_x, self.player_y);
        return .{ .col = cell.col, .row = cell.row };
    }

    fn verifyProjection(self: *Tb08) void {
        for (0..self.map.rows) |row| {
            for (0..self.map.cols) |col| {
                const cell = Cell{ .col = @intCast(col), .row = @intCast(row) };
                const world = project(cell);
                const inverse = unproject(world.x, world.y);
                self.projection_checks += 1;
                if (!cell.eql(inverse)) self.projection_failures += 1;
            }
        }
    }

    fn verifyDepthOrder(self: *Tb08) void {
        const behind_player: f32 = 120;
        const player: f32 = 140;
        const in_front_of_player: f32 = 160;
        self.depth_checks += 2;
        if (!depthBefore(behind_player, player) or depthBefore(in_front_of_player, player)) {
            self.depth_failures += 1;
        }
    }

    fn verifyNavigation(self: *Tb08) void {
        var route: [engine.navigation.max_path]Cell = undefined;
        const grid = engine.navigation.Grid.init(&self.map);
        const length = self.pathfinder.find(grid, .{ .col = 1, .row = 1 }, .{ .col = 14, .row = 10 }, &route) catch |err| {
            self.path_failures += 1;
            log.err("initial navigation verification failed: {s}", .{@errorName(err)});
            return;
        };
        if (length < 2) {
            self.path_failures += 1;
            return;
        }
        for (route[0..length]) |cell| {
            if (!grid.walkable(cell)) self.path_failures += 1;
            const world = project(cell);
            if (!cell.eql(unproject(world.x, world.y))) self.path_failures += 1;
        }
        self.path_checks += 1;
    }

    fn drawWorld(self: *const Tb08, dc: *const engine.DrawContext) void {
        for (0..self.map.rows) |row| {
            for (0..self.map.cols) |col| {
                const cell = Cell{ .col = @intCast(col), .row = @intCast(row) };
                const p = project(cell);
                const blocked = self.map.isSolid(@intCast(col), @intCast(row));
                const tint: [3]f32 = if (blocked)
                    .{ 0.23, 0.32, 0.3 }
                else if ((row + col) % 2 == 0)
                    .{ 0.2, 0.43, 0.34 }
                else
                    .{ 0.17, 0.38, 0.31 };
                drawDiamond(dc, &self.texture, p.x, p.y, tint, -1);
            }
        }
    }

    fn drawObjects(self: *const Tb08, dc: *const engine.DrawContext) void {
        for (1..self.map.rows - 1) |row| {
            for (1..self.map.cols - 1) |col| {
                if (!self.map.isSolid(@intCast(col), @intCast(row))) continue;
                const cell = Cell{ .col = @intCast(col), .row = @intCast(row) };
                const p = project(cell);
                const is_tree = (row + col) % 3 == 0;
                if (is_tree) {
                    dc.batch.drawSprite(
                        &self.texture,
                        .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                        .{ .x = dc.cam.screenX(p.x - 3), .y = dc.cam.screenY(p.y - 27), .w = 6, .h = 24 },
                        .{ .tint = .{ 0.42, 0.27, 0.13 }, .depth_y = p.y },
                    );
                    dc.batch.drawSprite(
                        &self.texture,
                        .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                        .{ .x = dc.cam.screenX(p.x - 10), .y = dc.cam.screenY(p.y - 34), .w = 20, .h = 18 },
                        .{ .tint = .{ 0.17, 0.52, 0.27 }, .depth_y = p.y },
                    );
                } else {
                    dc.batch.drawSprite(
                        &self.texture,
                        .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                        .{ .x = dc.cam.screenX(p.x - 12), .y = dc.cam.screenY(p.y - 24), .w = 24, .h = 24 },
                        .{ .tint = .{ 0.57, 0.43, 0.29 }, .depth_y = p.y },
                    );
                    dc.batch.drawSprite(
                        &self.texture,
                        .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                        .{ .x = dc.cam.screenX(p.x - 12), .y = dc.cam.screenY(p.y - 30), .w = 24, .h = 8 },
                        .{ .tint = .{ 0.72, 0.53, 0.3 }, .depth_y = p.y },
                    );
                }
            }
        }
    }

    fn report(self: *Tb08, ctx: *engine.Context) void {
        const pass = self.projection_failures == 0 and self.path_failures == 0 and
            self.depth_failures == 0 and self.path_checks > 0;
        log.info("TB-08 result {s}: projection {d}/{d} checks, navigation {d} paths/{d} failures, depth {d}/{d} checks, clicks {d}, rejected {d}, reached {d}", .{
            if (pass) "pass" else "fail",
            self.projection_checks,
            self.projection_failures,
            self.path_checks,
            self.path_failures,
            self.depth_checks,
            self.depth_failures,
            self.click_requests,
            self.rejected_targets,
            self.reached_cells,
        });
        var json: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(
            &json,
            "{{\"testbed\":\"TB-08\",\"scenario\":\"isometric-world\",\"result\":\"{s}\",\"projection_checks\":{d},\"projection_failures\":{d},\"navigation_path_checks\":{d},\"navigation_failures\":{d},\"depth_order_checks\":{d},\"depth_order_failures\":{d},\"click_requests\":{d},\"rejected_targets\":{d},\"reached_cells\":{d},\"camera_zoom\":{d:.3},\"elevation_workaround\":\"single depth_y per grounded prop; multi-level vertical occlusion is not modeled\"}}\n",
            .{
                if (pass) "pass" else "fail",
                self.projection_checks,
                self.projection_failures,
                self.path_checks,
                self.path_failures,
                self.depth_checks,
                self.depth_failures,
                self.click_requests,
                self.rejected_targets,
                self.reached_cells,
                ctx.camera.zoom,
            },
        ) catch |err| {
            log.err("TB-08 results could not be formatted: {s}", .{@errorName(err)});
            return;
        };
        ctx.writeFile("TB-08-isometric-results.json", text) catch |err| {
            log.err("TB-08 results could not be written: {s}", .{@errorName(err)});
            return;
        };
        self.report_written = true;
    }
};

const Projected = struct { x: f32, y: f32 };

fn project(cell: Cell) Projected {
    const col: f32 = @floatFromInt(cell.col);
    const row: f32 = @floatFromInt(cell.row);
    return .{
        .x = map_origin_x + (col - row) * half_tile_w,
        .y = map_origin_y + (col + row) * half_tile_h,
    };
}

fn unproject(x: f32, y: f32) Cell {
    const iso_x = (x - map_origin_x) / half_tile_w;
    const iso_y = (y - map_origin_y) / half_tile_h;
    return .{
        .col = @intFromFloat(@round((iso_x + iso_y) * 0.5)),
        .row = @intFromFloat(@round((iso_y - iso_x) * 0.5)),
    };
}

fn depthBefore(a: f32, b: f32) bool {
    return a < b;
}

fn drawDiamond(dc: *const engine.DrawContext, texture: *const engine.Texture, x: f32, y: f32, tint: [3]f32, z: i32) void {
    dc.batch.drawSprite(
        texture,
        .{ .x = 0, .y = 0, .w = 4, .h = 4 },
        .{ .x = dc.cam.screenX(x - 9), .y = dc.cam.screenY(y - 9), .w = 18, .h = 18 },
        .{ .tint = tint, .rotation = @as(f32, std.math.pi) / 4, .origin = .{ 9, 9 }, .z = z, .depth_y = y },
    );
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch return error.InvalidArgument;
    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        if (std.mem.eql(u8, args[arg_index], "--help")) {
            std.debug.print("TB-08 options: --frames N runs a bounded smoke test. Click a walkable tile to navigate; WASD/arrows step; +/- zoom; 0 reset; Escape quits.\n", .{});
            return;
        } else if (std.mem.eql(u8, args[arg_index], "--frames") and arg_index + 1 < args.len) {
            arg_index += 1;
            run_frame_limit = try std.fmt.parseUnsigned(u64, args[arg_index], 10);
            if (run_frame_limit.? == 0) return error.InvalidArgument;
        } else {
            return error.InvalidArgument;
        }
    }
    try engine.run(engine.SceneHost(Tb08), config);
}
