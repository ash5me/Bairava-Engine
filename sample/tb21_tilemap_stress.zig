//! TB-21 Tilemap Validation and Stress Test.
//! Builds deterministic maps through the public parser, exercises render culling and tile
//! collision, and animates a decoration tile from simulation ticks.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb21");
const TileMap = engine.tilemap.TileMap;
const Layer = engine.tilemap.Layer;
const Box = engine.tilemap.Box;
const Point = engine.tilemap.Point;

const Options = struct {
    cols: u32 = 128,
    rows: u32 = 96,
    frames: u64 = 180,
    update_hz: u32 = 60,
};

var options = Options{};

const config = engine.Config{
    .title = "Bairava TB-21 Tilemap Validation and Stress",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.045, 0.055, 0.075 },
    .settings_file = "tb21_settings.txt",
};

const animation_col: u32 = 4;
const animation_row: u32 = 4;
const animation_frames: u8 = 4;
const animation_rate_hz: u32 = 6;

const Tb21 = struct {
    map: TileMap,
    texture: engine.Texture,
    tileset_region: engine.atlas.Region,
    total_tiles: u64,
    total_solid_tiles: u64,
    total_one_way_tiles: u64,
    target: Point,
    show_decoration: bool = true,
    show_foreground: bool = true,
    animation_frame: u8 = 0,
    reloads: u64 = 0,
    collision_checks: u64 = 0,
    collision_failures: u64 = 0,
    culling_failures: u64 = 0,
    draw_samples: u64 = 0,
    submitted_tiles_total: u64 = 0,
    visible_tiles_total: u64 = 0,
    report_written: bool = false,

    pub fn init(ctx: *engine.Context) !Tb21 {
        var map = try createMap(ctx.allocators.game, options.cols, options.rows);
        errdefer map.deinit(ctx.allocators.game);
        var texture = try ctx.loadTexture("assets/tile.png");
        errdefer texture.deinit();
        const across = texture.width / engine.tilemap.tile_size;
        const down = texture.height / engine.tilemap.tile_size;
        if (across == 0 or down == 0 or across * down < 220) return error.InvalidTileset;
        const total_tiles = countTiles(&map);
        const total_solid_tiles = countSolidTiles(&map);
        const total_one_way_tiles = countOneWayTiles(&map);
        const world_w = @as(f32, @floatFromInt(map.cols)) * engine.tilemap.tile_px;
        const world_h = @as(f32, @floatFromInt(map.rows)) * engine.tilemap.tile_px;
        ctx.camera.world_w = @max(world_w, ctx.camera.view_w);
        ctx.camera.world_h = @max(world_h, ctx.camera.view_h);
        const target = Point{ .x = world_w / 2, .y = world_h / 2 };
        ctx.camera.follow(target.x, target.y);
        return .{
            .map = map,
            .texture = texture,
            .tileset_region = .{
                .x = 0,
                .y = 0,
                .w = across * engine.tilemap.tile_size,
                .h = down * engine.tilemap.tile_size,
            },
            .total_tiles = total_tiles,
            .total_solid_tiles = total_solid_tiles,
            .total_one_way_tiles = total_one_way_tiles,
            .target = target,
        };
    }

    pub fn update(self: *Tb21, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.input.wasPressed(.equal) or ctx.input.wasPressed(.keypad_plus)) ctx.zoomBy(1.25);
        if (ctx.input.wasPressed(.minus) or ctx.input.wasPressed(.keypad_minus)) ctx.zoomBy(0.8);
        if (ctx.input.wasPressed(.zero)) ctx.resetZoom();
        if (ctx.input.wasPressed(.q)) self.show_decoration = !self.show_decoration;
        if (ctx.input.wasPressed(.e)) self.show_foreground = !self.show_foreground;
        if (ctx.input.wasPressed(.r)) self.reloadMap(ctx);

        const speed = 140 * ctx.dt;
        if (ctx.input.held(.left) or ctx.input.held(.a)) self.target.x -= speed;
        if (ctx.input.held(.right) or ctx.input.held(.d)) self.target.x += speed;
        if (ctx.input.held(.up) or ctx.input.held(.w)) self.target.y -= speed;
        if (ctx.input.held(.down) or ctx.input.held(.s)) self.target.y += speed;
        const world_w = @as(f32, @floatFromInt(self.map.cols)) * engine.tilemap.tile_px;
        const world_h = @as(f32, @floatFromInt(self.map.rows)) * engine.tilemap.tile_px;
        self.target.x = std.math.clamp(self.target.x, 0, world_w);
        self.target.y = std.math.clamp(self.target.y, 0, world_h);

        ctx.camera.world_w = @max(world_w, ctx.camera.view_w);
        ctx.camera.world_h = @max(world_h, ctx.camera.view_h);
        ctx.camera.followSmooth(self.target.x, self.target.y, ctx.dt, 4);
        self.animation_frame = @intCast((ctx.simulation_tick / animationTicks(options.update_hz)) % animation_frames);
        self.map.tiles[animationIndex(&self.map)] = 3 + self.animation_frame;
        if (!self.report_written) self.verifyCollision();

        if (!self.report_written and ctx.diagnostics.snapshot.frames >= options.frames) self.report(ctx);
    }

    fn reloadMap(self: *Tb21, ctx: *engine.Context) void {
        var replacement = createMap(ctx.allocators.game, options.cols, options.rows) catch |err| {
            log.err("map reload failed: {s}", .{@errorName(err)});
            return;
        };
        replacement.tiles[animationIndex(&replacement)] = 3 + self.animation_frame;
        self.map.deinit(ctx.allocators.game);
        self.map = replacement;
        self.total_tiles = countTiles(&self.map);
        self.total_solid_tiles = countSolidTiles(&self.map);
        self.total_one_way_tiles = countOneWayTiles(&self.map);
        self.reloads += 1;
    }

    fn verifyCollision(self: *Tb21) void {
        const tile_px = engine.tilemap.tile_px;
        const tile_count = @as(u64, self.map.cols) * self.map.rows;
        const probe_count: u32 = 4;
        var probe: u32 = 0;
        while (probe < probe_count) : (probe += 1) {
            const ordinal = (self.collision_checks * 17 + @as(u64, probe) * 131) % tile_count;
            const col: u32 = @intCast(ordinal % self.map.cols);
            const row: u32 = @intCast(ordinal / self.map.cols);
            const inset: f32 = switch (probe) {
                0 => 0,
                1 => 0.25,
                2 => tile_px - 12,
                else => tile_px / 2,
            };
            const box = Box{
                .x = @as(f32, @floatFromInt(col)) * tile_px + inset,
                .y = @as(f32, @floatFromInt(row)) * tile_px + inset,
                .w = 12,
                .h = 12,
            };
            const map_hit = self.map.boxOverlapsSolid(box);
            const sprite_hit = collisionReference(&self.map, box);
            self.collision_checks += 1;
            if (map_hit != sprite_hit) {
                self.collision_failures += 1;
                log.err("tile collision mismatch at ({d:.2},{d:.2}) size 12x12: map {any}, shape reference {any}", .{
                    box.x,
                    box.y,
                    map_hit,
                    sprite_hit,
                });
            }
        }
    }

    pub fn draw(self: *Tb21, dc: *const engine.DrawContext) void {
        const before = dc.batch.sprite_count;
        engine.tilemap_draw.drawLayer(&self.map, dc.batch, &self.texture, self.tileset_region, dc.cam, .ground, .{});
        if (self.show_decoration) {
            engine.tilemap_draw.drawLayer(&self.map, dc.batch, &self.texture, self.tileset_region, dc.cam, .decoration, .{});
        }
        const player = Box{ .x = self.target.x - 6, .y = self.target.y - 7, .w = 12, .h = 14 };
        dc.batch.drawSprite(
            &self.texture,
            .{ .x = 0, .y = 0, .w = engine.tilemap.tile_px, .h = engine.tilemap.tile_px },
            .{
                .x = dc.cam.screenX(player.x),
                .y = dc.cam.screenY(player.y),
                .w = player.w,
                .h = player.h,
            },
            .{ .tint = .{ 0.95, 0.32, 0.2 }, .z = 1 },
        );
        if (self.show_foreground) {
            engine.tilemap_draw.drawLayer(&self.map, dc.batch, &self.texture, self.tileset_region, dc.cam, .foreground, .{ .z = 2 });
        }
        const submitted = dc.batch.sprite_count - before - 1;
        const visible = visibleTileCount(&self.map, dc.cam.viewRect(), self.show_decoration, self.show_foreground);
        if (submitted < visible) {
            self.culling_failures += 1;
            log.err("tile culling omitted visible tiles: submitted {d}, visible {d}", .{ submitted, visible });
        }
        self.draw_samples += 1;
        self.submitted_tiles_total += submitted;
        self.visible_tiles_total += visible;
    }

    fn report(self: *Tb21, ctx: *engine.Context) void {
        self.report_written = true;
        const submitted_avg = if (self.draw_samples == 0) 0 else @as(f64, @floatFromInt(self.submitted_tiles_total)) / @as(f64, @floatFromInt(self.draw_samples));
        const visible_avg = if (self.draw_samples == 0) 0 else @as(f64, @floatFromInt(self.visible_tiles_total)) / @as(f64, @floatFromInt(self.draw_samples));
        const visible_now = visibleTileCount(&self.map, ctx.camera.viewRect(), self.show_decoration, self.show_foreground);
        const enabled_tiles = countEnabledTiles(&self.map, self.show_decoration, self.show_foreground);
        const culled = enabled_tiles - @min(enabled_tiles, visible_now);
        const frames = ctx.diagnostics.stats.of(.frame);
        log.info("TB-21 map {d}x{d} ({d} tiles, {d} solid, {d} one-way), memory {d} bytes, view submitted avg {d:.1}, currently visible {d:.1}, currently culled {d}", .{
            self.map.cols,
            self.map.rows,
            self.total_tiles,
            self.total_solid_tiles,
            self.total_one_way_tiles,
            self.map.tiles.len,
            submitted_avg,
            visible_avg,
            culled,
        });
        log.info("TB-21 collision checks {d}, failures {d}, culling failures {d}, reloads {d}, animation frame {d}, frame avg/p95 {d:.2}/{d:.2} ms", .{
            self.collision_checks,
            self.collision_failures,
            self.culling_failures,
            self.reloads,
            self.animation_frame,
            frames.average() * 1000,
            frames.percentile(0.95) * 1000,
        });
        var json: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(
            &json,
            "{{\"testbed\":\"TB-21\",\"scenario\":\"tilemap-validation-stress\",\"result\":\"{s}\",\"cols\":{d},\"rows\":{d},\"map_tiles\":{d},\"solid_tiles\":{d},\"one_way_tiles\":{d},\"map_memory_bytes\":{d},\"draw_samples\":{d},\"submitted_tiles_avg\":{d:.2},\"visible_tiles_avg\":{d:.2},\"culled_tiles_now\":{d},\"collision_checks\":{d},\"collision_failures\":{d},\"culling_failures\":{d},\"reloads\":{d},\"animation_frame\":{d},\"update_hz\":{d},\"frame_ms_avg\":{d:.3},\"frame_ms_p95\":{d:.3}}}\n",
            .{
                if (self.collision_failures == 0 and self.culling_failures == 0) "pass" else "fail",
                self.map.cols,
                self.map.rows,
                self.total_tiles,
                self.total_solid_tiles,
                self.total_one_way_tiles,
                self.map.tiles.len,
                self.draw_samples,
                submitted_avg,
                visible_avg,
                culled,
                self.collision_checks,
                self.collision_failures,
                self.culling_failures,
                self.reloads,
                self.animation_frame,
                options.update_hz,
                frames.average() * 1000,
                frames.percentile(0.95) * 1000,
            },
        ) catch |err| {
            log.err("TB-21 metrics formatting failed: {s}", .{@errorName(err)});
            return;
        };
        ctx.writeFile("TB-21-tilemap-results.json", text) catch |err| {
            log.err("TB-21 metrics could not be written: {s}", .{@errorName(err)});
        };
    }

    pub fn debugText(self: *const Tb21, out: *engine.diagnostics.Text) void {
        out.print("TB-21: {d}x{d} tiles; WASD/arrows move, +/- zoom, Q/E layers, R reload, Escape quits", .{ self.map.cols, self.map.rows });
        out.print("submitted avg {d:.1}, collision checks {d}, failures {d}; animation frame {d}", .{
            if (self.draw_samples == 0) 0 else @as(f32, @floatFromInt(self.submitted_tiles_total)) / @as(f32, @floatFromInt(self.draw_samples)),
            self.collision_checks,
            self.collision_failures,
            self.animation_frame,
        });
    }

    pub fn deinitWithContext(self: *Tb21, ctx: *engine.Context) void {
        self.map.deinit(ctx.allocators.game);
        self.texture.deinit();
    }

    pub fn deinit(self: *Tb21) void {
        _ = self;
    }
};

fn createMap(allocator: std.mem.Allocator, cols: u32, rows: u32) !TileMap {
    const capacity = 128 + @as(usize, cols) * rows * 3 * 5;
    const text = try allocator.alloc(u8, capacity);
    defer allocator.free(text);
    var cursor: usize = 0;
    try appendText(text, &cursor, "version 1\nsize {d} {d}\ntileset 220\nsolid 1\noneway 2\n", .{ cols, rows });
    for ([_]Layer{ .ground, .decoration, .foreground }) |layer| {
        try appendText(text, &cursor, "layer {s}\n", .{@tagName(layer)});
        var row: u32 = 0;
        while (row < rows) : (row += 1) {
            var col: u32 = 0;
            while (col < cols) : (col += 1) {
                const id = generatedTile(layer, col, row, cols, rows);
                if (id) |tile_id| {
                    try appendText(text, &cursor, "{d} ", .{tile_id});
                } else {
                    try appendText(text, &cursor, ". ", .{});
                }
            }
            try appendText(text, &cursor, "\n", .{});
        }
    }
    return TileMap.parse(allocator, text[0..cursor]);
}

fn appendText(buffer: []u8, cursor: *usize, comptime format: []const u8, args: anytype) !void {
    const written = try std.fmt.bufPrint(buffer[cursor.*..], format, args);
    cursor.* += written.len;
}

fn generatedTile(layer: Layer, col: u32, row: u32, cols: u32, rows: u32) ?u8 {
    const boundary = col == 0 or row == 0 or col + 1 == cols or row + 1 == rows;
    return switch (layer) {
        .ground => if (boundary or (col *% 17 +% row *% 13) % 113 == 0)
            1
        else if ((col *% 23 +% row *% 19) % 173 == 0)
            2
        else
            0,
        .decoration => if ((col *% 7 +% row *% 11) % 29 == 0) 7 + @as(u8, @intCast((col + row) % 4)) else null,
        .foreground => if ((col *% 5 +% row *% 3) % 97 == 0) 12 + @as(u8, @intCast((col ^ row) % 4)) else null,
    };
}

fn animationIndex(map: *const TileMap) usize {
    const cells = @as(usize, map.cols) * map.rows;
    return cells + @as(usize, animation_row) * map.cols + animation_col;
}

fn animationTicks(update_hz: u32) u64 {
    return @max(1, update_hz / animation_rate_hz);
}

fn countTiles(map: *const TileMap) u64 {
    var count: u64 = 0;
    for (map.tiles) |id| {
        if (id != engine.tilemap.empty) count += 1;
    }
    return count;
}

fn countSolidTiles(map: *const TileMap) u64 {
    var count: u64 = 0;
    var row: u32 = 0;
    while (row < map.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < map.cols) : (col += 1) {
            if (map.isSolid(@intCast(col), @intCast(row))) count += 1;
        }
    }
    return count;
}

fn countOneWayTiles(map: *const TileMap) u64 {
    var count: u64 = 0;
    var row: u32 = 0;
    while (row < map.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < map.cols) : (col += 1) {
            if (map.isOneWay(@intCast(col), @intCast(row))) count += 1;
        }
    }
    return count;
}

fn countEnabledTiles(map: *const TileMap, show_decoration: bool, show_foreground: bool) u64 {
    var count: u64 = 0;
    for (0..map.tiles.len) |index| {
        const layer: Layer = @enumFromInt(index / (@as(usize, map.cols) * map.rows));
        if (layer == .decoration and !show_decoration) continue;
        if (layer == .foreground and !show_foreground) continue;
        if (map.tiles[index] != engine.tilemap.empty) count += 1;
    }
    return count;
}

fn collisionReference(map: *const TileMap, box: Box) bool {
    const tile_px = engine.tilemap.tile_px;
    const first_col: i32 = @intFromFloat(@floor(box.x / tile_px));
    const first_row: i32 = @intFromFloat(@floor(box.y / tile_px));
    const last_col: i32 = @intFromFloat(@ceil((box.x + box.w) / tile_px) - 1);
    const last_row: i32 = @intFromFloat(@ceil((box.y + box.h) / tile_px) - 1);
    var row = first_row;
    while (row <= last_row) : (row += 1) {
        var col = first_col;
        while (col <= last_col) : (col += 1) {
            if (map.isSolid(col, row)) {
                const tile = engine.physics.collision.Collider{
                    .box = .{
                        .x = @as(f32, @floatFromInt(col)) * tile_px,
                        .y = @as(f32, @floatFromInt(row)) * tile_px,
                        .w = tile_px,
                        .h = tile_px,
                    },
                    .layer = 1,
                };
                if (engine.physics.collision.overlapsProbe(tile, box)) return true;
            }
        }
    }
    return false;
}

fn visibleTileCount(map: *const TileMap, view: Box, show_decoration: bool, show_foreground: bool) u64 {
    const tile_px = engine.tilemap.tile_px;
    const first_col = @max(0, @as(i32, @intFromFloat(@floor(view.x / tile_px))));
    const first_row = @max(0, @as(i32, @intFromFloat(@floor(view.y / tile_px))));
    const last_col = @min(@as(i32, @intCast(map.cols)), @as(i32, @intFromFloat(@ceil((view.x + view.w) / tile_px))));
    const last_row = @min(@as(i32, @intCast(map.rows)), @as(i32, @intFromFloat(@ceil((view.y + view.h) / tile_px))));
    var count: u64 = 0;
    var row = first_row;
    while (row < last_row) : (row += 1) {
        var col = first_col;
        while (col < last_col) : (col += 1) {
            if (map.idAt(.ground, col, row) != null) count += 1;
            if (show_decoration and map.idAt(.decoration, col, row) != null) count += 1;
            if (show_foreground and map.idAt(.foreground, col, row) != null) count += 1;
        }
    }
    return count;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch return error.InvalidArgument;
    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--cols") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.cols = try std.fmt.parseUnsigned(u32, args[arg_index], 10);
        } else if (std.mem.eql(u8, arg, "--rows") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.rows = try std.fmt.parseUnsigned(u32, args[arg_index], 10);
        } else if (std.mem.eql(u8, arg, "--frames") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.frames = try std.fmt.parseUnsigned(u64, args[arg_index], 10);
        } else if (std.mem.eql(u8, arg, "--hz") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.update_hz = try std.fmt.parseUnsigned(u32, args[arg_index], 10);
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("TB-21 options: --cols 40..512 --rows 24..256 --hz 30|60|120 --frames 180. Controls: WASD/arrows move, +/- zoom, Q/E layers, R reload.\n", .{});
            return;
        } else {
            return error.InvalidArgument;
        }
    }
    if (options.cols < 40 or options.cols > 512 or options.rows < 24 or options.rows > 256 or
        !(options.update_hz == 30 or options.update_hz == 60 or options.update_hz == 120))
    {
        return error.InvalidArgument;
    }
    var run_config = config;
    run_config.update_hz = options.update_hz;
    try engine.run(engine.SceneHost(Tb21), run_config);
}
