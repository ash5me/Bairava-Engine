//! TB-07 is the single game-like integration sample: tile collision, animated movement,
//! NPC interaction, positional sound, camera follow, and a scene transition.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb07");
const tile_px = engine.tilemap.tile_px;
const player_speed: f32 = 76;
const npc_position = [2]f32{ 304, 72 };
const door_position = [2]f32{ 560, 336 };
const interaction_range: f32 = 28;
const report_after_frames: u64 = 600;

const config = engine.Config{
    .title = "Bairava TB-07 Adventure Integration",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.06, 0.09, 0.08 },
    .settings_file = "tb07_settings.txt",
};

const Campaign = struct {
    movement_ticks: u64 = 0,
    blocked_moves: u64 = 0,
    animation_changes: u64 = 0,
    npc_interactions: u64 = 0,
    door_interactions: u64 = 0,
    scene_transitions: u64 = 0,
    sounds_played: u64 = 0,
    last_interaction: []const u8 = "Explore the village",
    report_written: bool = false,
};

var campaign = Campaign{};

const State = struct {
    atlas: engine.LoadedAtlas,
    map: engine.tilemap.TileMap,
    library: engine.animation.Library,
    player_machine: engine.animation.Machine,
    sound: ?engine.audio.Sound,
    player_x: f32,
    player_y: f32,
    player_facing: i32 = 0,
    moving_param: u8,
    facing_param: u8,
    animation_state: []const u8 = "",
    is_sanctuary: bool,
    elapsed: f32 = 0,
    next_report_frame: u64 = report_after_frames,
    pending_enter: bool = false,
    pending_return: bool = false,

    fn init(ctx: *engine.Context, sanctuary: bool) !State {
        var atlas = try ctx.loadAtlas("assets/atlas.png", "assets/atlas.txt");
        errdefer atlas.deinit();

        const map_source = try ctx.readFile(ctx.allocators.asset, "assets/maps/level1.txt");
        defer ctx.allocators.asset.free(map_source);
        var map = try engine.tilemap.TileMap.parse(ctx.allocators.game, map_source);
        errdefer map.deinit(ctx.allocators.game);

        const animation_source = try ctx.readFile(ctx.allocators.asset, "assets/animations/warrior.anim");
        defer ctx.allocators.asset.free(animation_source);
        var library = try engine.animation.Library.parse(
            ctx.allocators.game,
            animation_source,
            atlas.region("warrior").w,
            atlas.region("warrior").h,
        );
        errdefer library.deinit();

        const machine_source = try ctx.readFile(ctx.allocators.asset, "assets/animations/warrior.machine");
        defer ctx.allocators.asset.free(machine_source);
        var definition = try engine.animation.MachineDefinition.parse(
            ctx.allocators.game,
            machine_source,
            &library,
        );
        errdefer definition.deinit();
        var player_machine = engine.animation.Machine.init(definition, &library);
        errdefer player_machine.deinit();

        const moving_param = player_machine.paramId("moving") orelse return error.InvalidAnimation;
        const facing_param = player_machine.paramId("facing") orelse return error.InvalidAnimation;
        const sound = if (ctx.audio.device != null)
            try ctx.loadSound("assets/wind1.wav")
        else
            null;
        errdefer if (sound) |loaded| {
            var owned = loaded;
            owned.deinit();
        };

        const world_w = @as(f32, @floatFromInt(map.cols)) * tile_px;
        const world_h = @as(f32, @floatFromInt(map.rows)) * tile_px;
        ctx.camera.world_w = world_w;
        ctx.camera.world_h = world_h;
        const player_x: f32 = if (sanctuary) 520 else 48;
        const player_y: f32 = if (sanctuary) 304 else 48;
        ctx.camera.follow(player_x + 8, player_y + 16);

        return .{
            .atlas = atlas,
            .map = map,
            .library = library,
            .player_machine = player_machine,
            .sound = sound,
            .player_x = player_x,
            .player_y = player_y,
            .moving_param = moving_param,
            .facing_param = facing_param,
            .is_sanctuary = sanctuary,
        };
    }

    fn deinit(self: *State, ctx: *engine.Context) void {
        if (self.sound) |*sound| sound.deinit();
        self.player_machine.deinit();
        self.library.deinit();
        self.map.deinit(ctx.allocators.game);
        self.atlas.deinit();
    }

    fn update(self: *State, ctx: *engine.Context) void {
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.input.wasPressed(.space) or ctx.input.wasPressed(.e)) self.interact(ctx);

        var dx: f32 = 0;
        var dy: f32 = 0;
        if (ctx.input.held(.left) or ctx.input.held(.a)) dx -= 1;
        if (ctx.input.held(.right) or ctx.input.held(.d)) dx += 1;
        if (ctx.input.held(.up) or ctx.input.held(.w)) dy -= 1;
        if (ctx.input.held(.down) or ctx.input.held(.s)) dy += 1;
        const moving = dx != 0 or dy != 0;
        if (moving) {
            if (dx != 0 and dy != 0) {
                dx *= 0.70710677;
                dy *= 0.70710677;
            }
            if (@abs(dx) > @abs(dy)) {
                self.player_facing = if (dx > 0) 1 else 3;
            } else {
                self.player_facing = if (dy < 0) 2 else 0;
            }
            const step_x = dx * player_speed * ctx.dt;
            const step_y = dy * player_speed * ctx.dt;
            const body = engine.tilemap.Box{ .x = self.player_x + 2, .y = self.player_y + 10, .w = 12, .h = 20 };
            const resolved = self.map.moveBox(body, step_x, step_y);
            if (resolved.x != body.x + step_x or resolved.y != body.y + step_y) {
                campaign.blocked_moves += 1;
            }
            self.player_x += resolved.x - body.x;
            self.player_y += resolved.y - body.y;
            campaign.movement_ticks += 1;
        }

        self.player_machine.set(self.moving_param, @intFromBool(moving));
        self.player_machine.set(self.facing_param, self.player_facing);
        const previous_state = self.player_machine.stateName();
        self.player_machine.update(ctx.dt, &self.library);
        if (!std.mem.eql(u8, previous_state, self.player_machine.stateName())) {
            campaign.animation_changes += 1;
        }
        self.elapsed += ctx.dt;
        ctx.camera.world_w = @as(f32, @floatFromInt(self.map.cols)) * tile_px;
        ctx.camera.world_h = @as(f32, @floatFromInt(self.map.rows)) * tile_px;
        ctx.camera.followSmooth(self.player_x + 8, self.player_y + 16, ctx.dt, 5);
        ctx.audio.setListener(.{ .x = self.player_x + 8, .y = self.player_y + 16 });

        if (!campaign.report_written and ctx.diagnostics.snapshot.frames >= self.next_report_frame) {
            self.report(ctx);
            self.next_report_frame = ctx.diagnostics.snapshot.frames + 120;
        }
    }

    fn interact(self: *State, ctx: *engine.Context) void {
        if (!self.is_sanctuary and distance(self.player_x + 8, self.player_y + 16, npc_position) <= interaction_range) {
            campaign.npc_interactions += 1;
            campaign.last_interaction = "The villager says: the old shrine is to the east.";
            self.playInteractionSound(ctx, npc_position);
            return;
        }
        if (distance(self.player_x + 8, self.player_y + 16, door_position) <= interaction_range) {
            campaign.door_interactions += 1;
            campaign.last_interaction = if (self.is_sanctuary)
                "The shrine door leads back to the village."
            else
                "The shrine door opens. Press E to return.";
            self.playInteractionSound(ctx, door_position);
            if (self.is_sanctuary) {
                campaign.scene_transitions += 1;
                self.pending_return = true;
            } else {
                campaign.scene_transitions += 1;
                self.pending_enter = true;
            }
        } else {
            campaign.last_interaction = "No one nearby. Move close and press E.";
        }
    }

    fn playInteractionSound(self: *State, ctx: *engine.Context, position: [2]f32) void {
        if (self.sound) |*sound| {
            _ = ctx.audio.play(sound, .{
                .position = .{ .x = position[0], .y = position[1] },
                .range = 320,
                .bus = .ui,
            }) catch |err| {
                log.warn("interaction sound did not play: {s}", .{@errorName(err)});
                return;
            };
            campaign.sounds_played += 1;
        }
    }

    fn draw(self: *State, dc: *const engine.DrawContext) void {
        const tile_region = self.atlas.region("tile");
        for (engine.tilemap.all_layers) |layer| {
            if (layer == .foreground) continue;
            engine.tilemap_draw.drawLayer(
                &self.map,
                dc.batch,
                &self.atlas.texture,
                tile_region,
                dc.cam,
                layer,
                .{},
            );
        }

        if (!self.is_sanctuary) {
            drawCharacter(&self.atlas, &self.library.find("idle_down").?.frames[0], npc_position[0], npc_position[1], .{ 0.55, 0.9, 0.7 }, dc);
        }
        drawDoor(&self.atlas, dc, door_position);
        const pose = self.player_machine.pose();
        const warrior_region = self.atlas.region("warrior");
        if (pose.previous) |previous| drawFrame(dc, &self.atlas.texture, warrior_region, previous, self.player_x, self.player_y, 1);
        drawFrame(dc, &self.atlas.texture, warrior_region, pose.frame, self.player_x, self.player_y, pose.weight);

        engine.tilemap_draw.drawLayer(
            &self.map,
            dc.batch,
            &self.atlas.texture,
            tile_region,
            dc.cam,
            .foreground,
            .{},
        );
    }

    fn debugText(self: *const State, out: *engine.diagnostics.Text) void {
        out.print("TB-07 {s}: WASD/arrows move, E/Space interact, Escape quits", .{
            if (self.is_sanctuary) "Shrine" else "Village",
        });
        out.print("{s}; interactions {d}, transitions {d}, blocked moves {d}", .{
            campaign.last_interaction,
            campaign.npc_interactions + campaign.door_interactions,
            campaign.scene_transitions,
            campaign.blocked_moves,
        });
    }

    fn report(self: *State, ctx: *engine.Context) void {
        const pass = campaign.movement_ticks > 0 and campaign.blocked_moves > 0 and
            campaign.animation_changes > 0 and campaign.npc_interactions > 0 and campaign.scene_transitions > 0;
        var json: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(
            &json,
            "{{\"testbed\":\"TB-07\",\"scenario\":\"top-down-adventure-integration\",\"result\":\"{s}\",\"movement_ticks\":{d},\"blocked_moves\":{d},\"animation_changes\":{d},\"npc_interactions\":{d},\"door_interactions\":{d},\"scene_transitions\":{d},\"positional_sounds_played\":{d},\"audio_available\":{s},\"current_room\":\"{s}\"}}\n",
            .{
                if (pass) "pass" else "incomplete",
                campaign.movement_ticks,
                campaign.blocked_moves,
                campaign.animation_changes,
                campaign.npc_interactions,
                campaign.door_interactions,
                campaign.scene_transitions,
                campaign.sounds_played,
                if (ctx.audio.device != null) "true" else "false",
                if (self.is_sanctuary) "shrine" else "village",
            },
        ) catch |err| {
            log.err("TB-07 report formatting failed: {s}", .{@errorName(err)});
            return;
        };
        ctx.writeFile("TB-07-adventure-results.json", text) catch |err| {
            log.err("TB-07 report could not be written: {s}", .{@errorName(err)});
            return;
        };
        if (pass) campaign.report_written = true;
        log.info("TB-07 report: movement {d}, blocked {d}, animation changes {d}, NPC interactions {d}, transitions {d}, result {s}", .{
            campaign.movement_ticks,
            campaign.blocked_moves,
            campaign.animation_changes,
            campaign.npc_interactions,
            campaign.scene_transitions,
            if (pass) "pass" else "incomplete",
        });
    }
};

fn Room(comptime sanctuary: bool) type {
    return struct {
        state: State,

        pub fn init(ctx: *engine.Context) !@This() {
            return .{ .state = try State.init(ctx, sanctuary) };
        }

        pub fn update(self: *@This(), ctx: *engine.Context, nav: *engine.SceneNavigator) void {
            self.state.update(ctx);
            if (self.state.pending_enter) {
                self.state.pending_enter = false;
                nav.switchTo(Sanctuary);
            } else if (self.state.pending_return) {
                self.state.pending_return = false;
                nav.switchTo(Village);
            }
        }

        pub fn draw(self: *@This(), dc: *const engine.DrawContext) void {
            self.state.draw(dc);
        }

        pub fn debugText(self: *const @This(), out: *engine.diagnostics.Text) void {
            self.state.debugText(out);
        }

        pub fn deinitWithContext(self: *@This(), ctx: *engine.Context) void {
            self.state.deinit(ctx);
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };
}

const Village = Room(false);
const Sanctuary = Room(true);

fn distance(x: f32, y: f32, point: [2]f32) f32 {
    const dx = x - point[0];
    const dy = y - point[1];
    return @sqrt(dx * dx + dy * dy);
}

fn drawFrame(
    dc: *const engine.DrawContext,
    texture: *const engine.Texture,
    region: engine.atlas.Region,
    frame: *const engine.animation.Frame,
    x: f32,
    y: f32,
    alpha: f32,
) void {
    dc.batch.drawSprite(
        texture,
        .{
            .x = @as(f32, @floatFromInt(region.x + frame.x)),
            .y = @as(f32, @floatFromInt(region.y + frame.y)),
            .w = @floatFromInt(frame.w),
            .h = @floatFromInt(frame.h),
        },
        .{ .x = dc.cam.screenX(x), .y = dc.cam.screenY(y), .w = 16, .h = 32 },
        .{ .alpha = alpha, .depth_y = y + 32 },
    );
}

fn drawCharacter(
    atlas: *const engine.LoadedAtlas,
    frame: *const engine.animation.Frame,
    x: f32,
    y: f32,
    tint: [3]f32,
    dc: *const engine.DrawContext,
) void {
    const region = atlas.region("warrior");
    dc.batch.drawSprite(
        &atlas.texture,
        .{
            .x = @as(f32, @floatFromInt(region.x + frame.x)),
            .y = @as(f32, @floatFromInt(region.y + frame.y)),
            .w = @floatFromInt(frame.w),
            .h = @floatFromInt(frame.h),
        },
        .{ .x = dc.cam.screenX(x), .y = dc.cam.screenY(y), .w = 16, .h = 32 },
        .{ .tint = tint, .depth_y = y + 32 },
    );
}

fn drawDoor(atlas: *const engine.LoadedAtlas, dc: *const engine.DrawContext, point: [2]f32) void {
    const tile = atlas.region("tile");
    dc.batch.drawSprite(
        &atlas.texture,
        .{ .x = @floatFromInt(tile.x + 2 * engine.tilemap.tile_size), .y = @floatFromInt(tile.y), .w = tile_px, .h = tile_px },
        .{ .x = dc.cam.screenX(point[0] - 8), .y = dc.cam.screenY(point[1] - 8), .w = tile_px, .h = tile_px },
        .{ .tint = .{ 0.9, 0.72, 0.35 }, .depth_y = point[1] + 8 },
    );
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch return error.InvalidArgument;
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--help")) {
            std.debug.print("TB-07 Top-Down Adventure integration sample. Controls: WASD/arrows move, E/Space interact, Escape quits. Results update after 600 frames.\n", .{});
            return;
        }
        return error.InvalidArgument;
    }
    try engine.run(engine.SceneHost(Village), config);
}
