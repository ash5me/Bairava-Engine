//! Gameplay: the level, the player, the demo panel, and how actions drive them. The engine calls
//! into this file through `init`, `update`, `draw`, and `deinit`, and never looks inside it. Game
//! code imports only the named `bairava` module, so everything the game needs from the platform goes through
//! the engine's `Context`.

const std = @import("std");

const engine = @import("bairava");
const config = @import("config.zig");
const controls = @import("controls.zig");
const Level = @import("level.zig").Level;
const Player = @import("player.zig").Player;
const save_store = @import("save.zig");

const log = engine.log.scoped("game");

/// Draw order of the panel. Sprites sort by z, so this places the panel above the world and the player.
const ui_z: i32 = 1000;

/// Colors of the debug geometry the game draws: the player's collision box and its center marker.
const player_box_color = engine.diagnostics.Color{ .r = 0.3, .g = 1.0, .b = 0.4, .a = 0.9 };
const player_marker_color = engine.diagnostics.Color{ .r = 1.0, .g = 0.85, .b = 0.2, .a = 1.0 };

pub const Game = struct {
    level: Level,
    player: Player,
    /// One texture that holds every sprite. Packing them at build time means the whole world and
    /// the player sample the same texture, so they can share a draw call.
    atlas: engine.LoadedAtlas,
    /// Validated explicit frame data, owned for the duration of the game.
    animations: engine.animation.Library,
    /// The atlas regions of the sprites this game draws.
    tile: engine.atlas.Region,
    warrior: engine.atlas.Region,
    /// Immediate-mode UI for the demo panel. It owns its font and its widget state.
    ui: engine.ui.Ui,
    /// Demo panel state: how often the button was clicked, and the slider value.
    clicks: u32,
    volume: f32,
    audio: *engine.audio.Audio,
    ambient_sound: ?engine.audio.Sound,
    ambient_voice: ?engine.audio.Handle,
    ambient_attempted: bool,
    /// Key bindings from the settings file, with the defaults for anything it leaves out.
    bindings: controls.Bindings,
    /// Held keys, for the debug lines and the actions. It lives as long as the session.
    input: *const engine.Input,

    pub fn init(ctx: *engine.Context) engine.AssetError!Game {
        const zone = engine.profile.zoneNamed(@src(), "game init");
        defer zone.End();
        var atlas = ctx.loadAtlas(config.atlas_image_path, config.atlas_index_path) catch |err| {
            log.err("required atlas '{s}'/ '{s}' failed to load: {s}", .{ config.atlas_image_path, config.atlas_index_path, @errorName(err) });
            return err;
        };
        errdefer atlas.deinit();
        watchAtlas(ctx);
        log.info("atlas {d}x{d} with {d} sprites", .{ atlas.texture.width, atlas.texture.height, atlas.index.len });

        const tile = atlas.region("tile");
        const warrior = atlas.region("warrior");
        var animations = loadAnimations(ctx, config.animation_path, warrior.w, warrior.h) catch |err| {
            log.err("required animation data '{s}' failed to load: {s}", .{ config.animation_path, @errorName(err) });
            return err;
        };
        errdefer animations.deinit();
        inline for (.{ "idle_down", "walk_down", "idle_up", "walk_up", "idle_left", "walk_left", "idle_right", "walk_right" }) |name| {
            if (animations.find(name) == null) {
                log.err("animation data '{s}' is missing required clip '{s}'", .{ config.animation_path, name });
                return error.InvalidAnimation;
            }
        }
        var level = Level.load(ctx, config.level_path, config.level_spawn_path) catch |err| {
            log.err("required level '{s}' or spawn metadata '{s}' failed to load: {s}", .{ config.level_path, config.level_spawn_path, @errorName(err) });
            return err;
        };
        errdefer level.deinit();
        checkTileset(&level, tile);

        const spawn = level.spawn;
        const player = Player.standingOn(spawn.col, spawn.row, &animations);
        log.info("map {d}x{d} tiles, player starts on tile ({d}, {d})", .{ level.map.cols, level.map.rows, spawn.col, spawn.row });

        const ui_font = ctx.loadFont(config.ui_font_path, config.ui_font_px) catch |err| {
            log.err("required UI font '{s}' failed to load: {s}", .{ config.ui_font_path, @errorName(err) });
            return err;
        };
        const ui = engine.ui.Ui.init(ctx.allocators.game, ui_font);
        const bindings = controls.load(ctx.settings_text);
        const ambient_sound: ?engine.audio.Sound = ctx.loadSound(config.ambient_sound_path) catch |err| blk: {
            if (err != error.NoDevice) log.warn("ambient sound could not be loaded: {s}", .{@errorName(err)});
            break :blk null;
        };

        var game: Game = .{
            .level = level,
            .player = player,
            .atlas = atlas,
            .animations = animations,
            .tile = tile,
            .warrior = warrior,
            .ui = ui,
            .clicks = 0,
            .volume = 0.5,
            .audio = ctx.audio,
            .ambient_sound = ambient_sound,
            .ambient_voice = null,
            .ambient_attempted = false,
            .bindings = bindings,
            .input = ctx.input,
        };
        game.loadSave(ctx);
        return game;
    }

    /// Adds the game's lines to the diagnostics overlay: where the player is, which way it faces, and
    /// which movement keys are held. The engine calls this once per frame, in development builds only.
    pub fn debugText(self: *const Game, out: *engine.diagnostics.Text) void {
        out.print("player {d:.1}, {d:.1}  facing {s}", .{ self.player.x, self.player.y, @tagName(self.player.facing) });
        out.print("move held: L{d} R{d} U{d} D{d}  clicks {d}", .{
            @intFromBool(self.bindings.held(self.input, .move_left)),
            @intFromBool(self.bindings.held(self.input, .move_right)),
            @intFromBool(self.bindings.held(self.input, .move_up)),
            @intFromBool(self.bindings.held(self.input, .move_down)),
            self.clicks,
        });
    }

    pub fn deinit(self: *Game) void {
        if (self.ambient_voice) |voice| self.audio.stop(voice);
        if (self.ambient_sound) |*sound| sound.deinit();
        self.level.deinit();
        self.animations.deinit();
        self.atlas.deinit();
        self.ui.deinit();
    }

    /// Runs at the fixed update rate. `ctx.dt` is the length of the step. `nav` asks for a change of
    /// scene. This game is one scene, so it never asks.
    pub fn update(self: *Game, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        _ = nav;
        self.reloadAtlasIfChanged(ctx);
        self.startAmbient();
        const input = ctx.input;
        if (self.bindings.pressed(input, .quit)) {
            log.info("quit action pressed", .{});
            ctx.running = false;
        }
        if (self.bindings.pressed(input, .save_game)) self.saveGame(ctx);
        if (self.bindings.pressed(input, .load_game)) self.loadSave(ctx);
        if (self.bindings.pressed(input, .toggle_scale)) {
            ctx.scale_mode = switch (ctx.scale_mode) {
                .fit => .integer,
                .integer => .fit,
            };
        }
        if (self.bindings.pressed(input, .zoom_in)) ctx.zoomBy(config.zoom_step);
        if (self.bindings.pressed(input, .zoom_out)) ctx.zoomBy(1.0 / config.zoom_step);
        if (self.bindings.pressed(input, .zoom_reset)) ctx.resetZoom();
        if (ctx.diagnostics_enabled) {
            const world = &ctx.diagnostics.snapshot.world;
            world.entities = 1;
            world.collision_queries += 1;
            world.map_cols = self.level.map.cols;
            world.map_rows = self.level.map.rows;
            const cursor = ctx.mouseWorld();
            world.selected_col = @intFromFloat(@floor(cursor.x / engine.tilemap.tile_px));
            world.selected_row = @intFromFloat(@floor(cursor.y / engine.tilemap.tile_px));
            world.selected_tile = self.level.map.idAt(.ground, world.selected_col, world.selected_row);
            world.selected_solid = self.level.map.isSolid(world.selected_col, world.selected_row);
        }

        // Each movement action contributes one unit on its axis.
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (self.bindings.held(input, .move_left)) dx -= 1;
        if (self.bindings.held(input, .move_right)) dx += 1;
        if (self.bindings.held(input, .move_up)) dy -= 1;
        if (self.bindings.held(input, .move_down)) dy += 1;

        self.player.update(dx, dy, ctx.dt, &self.level.map, &self.animations);
        self.updateUi(ctx);
    }

    /// Registers the atlas files for hot reload. In a release build this watches nothing. A file that cannot
    /// be watched only means that its changes are not picked up, so it is logged and startup goes on.
    fn watchAtlas(ctx: *engine.Context) void {
        inline for (.{ config.atlas_image_path, config.atlas_index_path }) |path| {
            ctx.watchAsset(path, .atlas) catch |err| log.warn("'{s}' is not watched for reload: {s}", .{ path, @errorName(err) });
        }
    }

    /// Reloads the atlas when its image or index changed on disk. The replacement is loaded and checked first,
    /// and the game switches to it only when it is valid. The GPU must finish with the old atlas before it is
    /// released, so the old one goes last. A rejected reload keeps the atlas the game already has, and logs why.
    fn reloadAtlasIfChanged(self: *Game, ctx: *engine.Context) void {
        const index_changed = ctx.takeChanged(config.atlas_index_path);
        const image_changed = ctx.takeChanged(config.atlas_image_path);
        if (!index_changed and !image_changed) return;

        var fresh = ctx.loadAtlas(config.atlas_image_path, config.atlas_index_path) catch |err| {
            log.warn("atlas reload rejected, keeping the current atlas: {s}", .{@errorName(err)});
            return;
        };
        const tile = fresh.index.find("tile") orelse {
            fresh.deinit();
            log.warn("atlas reload rejected: sprite 'tile' is missing; keeping the current atlas", .{});
            return;
        };
        const warrior = fresh.index.find("warrior") orelse {
            fresh.deinit();
            log.warn("atlas reload rejected: sprite 'warrior' is missing; keeping the current atlas", .{});
            return;
        };
        if (!tilesetFits(&self.level, tile)) {
            fresh.deinit();
            log.warn("atlas reload rejected: the level uses tiles the new tile sprite lacks; keeping the current atlas", .{});
            return;
        }

        ctx.waitGpuIdle();
        self.atlas.deinit();
        self.atlas = fresh;
        self.tile = tile;
        self.warrior = warrior;
        log.info("atlas reloaded: {d}x{d} with {d} sprites", .{ self.atlas.texture.width, self.atlas.texture.height, self.atlas.index.len });
    }

    fn startAmbient(self: *Game) void {
        if (self.ambient_attempted) return;
        self.ambient_attempted = true;
        if (self.ambient_sound) |*sound| {
            self.ambient_voice = self.audio.play(sound, .{ .loop = true }) catch |err| {
                log.warn("ambient sound could not start: {s}", .{@errorName(err)});
                return;
            };
        }
    }

    fn saveGame(self: *const Game, ctx: *const engine.Context) void {
        const state = save_store.State{
            .player_x = self.player.x,
            .player_y = self.player.y,
            .facing = self.player.facing,
            .moving = self.player.anim.clip.frames.len > 1,
            .animation_time = self.player.anim.time,
            .clicks = self.clicks,
            .volume = self.volume,
            .scale_mode = if (ctx.scale_mode == .integer) .integer else .fit,
            .zoom_target = ctx.zoom_target,
        };
        const json = save_store.serialize(ctx.allocators.frame, state) catch |err| {
            log.err("save serialization failed: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.allocators.frame.free(json);

        // writeFile logs the reason when the write fails, so there is nothing more to say here.
        ctx.writeFile(config.save_file_name, json) catch |err| {
            log.err("save '{s}' was not written: {s}", .{ config.save_file_name, @errorName(err) });
            return;
        };
        log.info("saved game to {s}", .{config.save_file_name});
    }

    fn loadSave(self: *Game, ctx: *engine.Context) void {
        const text = ctx.readFile(ctx.allocators.frame, config.save_file_name) catch |err| {
            if (err != error.FileNotFound) log.warn("save '{s}' could not be read: {s}", .{ config.save_file_name, @errorName(err) });
            return;
        };
        defer ctx.allocators.frame.free(text);

        const defaults = save_store.State{
            .player_x = self.player.x,
            .player_y = self.player.y,
            .facing = self.player.facing,
            .clicks = self.clicks,
            .volume = self.volume,
            .scale_mode = if (ctx.scale_mode == .integer) .integer else .fit,
            .zoom_target = ctx.zoom_target,
        };
        const state = save_store.deserialize(ctx.allocators.frame, text, defaults) catch |err| {
            log.warn("save '{s}' was ignored: {s}", .{ config.save_file_name, @errorName(err) });
            return;
        };
        if (!state.level_matches) {
            log.warn("save '{s}' belongs to a different level; it was ignored", .{config.save_file_name});
            return;
        }

        if (positionIsValid(state.player_x, state.player_y, &self.level)) {
            self.player.restore(state.player_x, state.player_y, state.facing, state.moving, state.animation_time, &self.animations);
        } else {
            log.warn("saved player position is outside the current level; using the level spawn", .{});
        }
        self.clicks = state.clicks;
        self.volume = state.volume;
        ctx.scale_mode = if (state.scale_mode == .integer) .integer else .fit;
        ctx.zoom_target = std.math.clamp(state.zoom_target, config.zoom_min, config.zoom_max);
        log.info("loaded game from {s}", .{config.save_file_name});
    }

    /// Runs once per frame. `dc.alpha` blends the player between the last two updates. The camera
    /// eases toward the player using the frame time, so its speed doesn't depend on the frame rate.
    pub fn draw(self: *Game, dc: *const engine.DrawContext) void {
        const center = self.player.drawCenter(dc.alpha);
        dc.cam.world_w = self.level.widthPx();
        dc.cam.world_h = self.level.heightPx();
        dc.cam.followSmooth(center.x, center.y, dc.dt, config.camera_rate);

        // Draw order: ground, decoration, the player, and then foreground, which can cover the player.
        const tiles = &self.atlas.texture;
        const map = &self.level.map;
        if (dc.layers.ground) engine.tilemap_draw.drawLayer(map, dc.batch, tiles, self.tile, dc.cam, .ground);
        if (dc.layers.decoration) engine.tilemap_draw.drawLayer(map, dc.batch, tiles, self.tile, dc.cam, .decoration);
        self.player.draw(dc.batch, tiles, self.warrior, dc.cam, dc.alpha);
        if (dc.layers.foreground) engine.tilemap_draw.drawLayer(map, dc.batch, tiles, self.tile, dc.cam, .foreground);

        // Debug geometry is queued as shapes, and only while its switch is on, so an idle build does no work.
        if (dc.show.tiles) engine.debug_geometry.drawGrid(map, dc.debug, dc.cam);
        if (dc.show.collision) {
            engine.debug_geometry.drawSolid(map, dc.debug, dc.cam);
            const feet = self.player.collisionBox(dc.alpha);
            dc.debug.outline(dc.cam.screenX(feet.x), dc.cam.screenY(feet.y), feet.w, feet.h, player_box_color);
        }
        if (dc.show.entities) {
            const player_center = self.player.drawCenter(dc.alpha);
            dc.debug.point(dc.cam.screenX(player_center.x), dc.cam.screenY(player_center.y), player_marker_color);
        }

        // The panel goes last. Its quads were built in the update step, so this only queues them.
        self.ui.queue(dc.batch, ui_z);
    }

    /// Builds the demo panel for this frame. It runs in the update step, so each press and release
    /// reaches the widgets exactly once.
    fn updateUi(self: *Game, ctx: *engine.Context) void {
        const ui = &self.ui;
        const panel = engine.ui.anchorBounds(ctx.layout.view_w, ctx.layout.view_h, 120, 130, .top_left, 4, 4);
        ui.begin(ctx.input, ctx.layout, panel.x, panel.y, panel.w);
        ui.label("Semkootru");
        ui.label("F5 save  F9 load");
        if (ui.button("Click me##go")) self.clicks += 1;

        var clicks_buf: [32]u8 = undefined;
        ui.label(std.fmt.bufPrint(&clicks_buf, "Clicks: {d}", .{self.clicks}) catch
            std.debug.panic("click label does not fit its buffer", .{}));
        _ = ui.slider("Volume", &self.volume, 0, 1);
        var level_buf: [32]u8 = undefined;
        ui.label(std.fmt.bufPrint(&level_buf, "Level: {d:.2}", .{self.volume}) catch
            std.debug.panic("level label does not fit its buffer", .{}));
        self.audio.setMasterGain(self.volume);
        ui.end();
    }
};

fn loadAnimations(ctx: *const engine.Context, path: []const u8, width_px: u32, height_px: u32) engine.AssetError!engine.animation.Library {
    const source = ctx.readFile(ctx.allocators.asset, path) catch |err| {
        return switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.PathTooLong => error.PathTooLong,
            error.OutOfMemory => error.OutOfMemory,
            else => error.ReadFailed,
        };
    };
    defer ctx.allocators.asset.free(source);
    return engine.animation.Library.parse(ctx.allocators.asset, source, width_px, height_px) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidAnimation,
        };
    };
}

/// True when every tile ID in the level names a tile in the tileset. A reload uses this to refuse an atlas that
/// would draw blank or wrong tiles, without stopping the game the way the startup check does.
fn tilesetFits(level: *const Level, tileset: engine.atlas.Region) bool {
    const count = tileset.cellCount(engine.tilemap.tile_size);
    if (level.map.tileset_count) |expected| {
        if (expected != count) return false;
    }
    return level.map.largestId() < count;
}

/// True when a player whose top-left corner is at (x, y) fits in the level without touching a solid
/// tile. The bounds check uses the whole sprite, and the collision check uses the feet.
fn positionIsValid(x: f32, y: f32, level: *const Level) bool {
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or x < 0 or y < 0 or
        x + Player.sprite_w > level.widthPx() or y + Player.sprite_h > level.heightPx()) return false;
    return !level.map.boxOverlapsSolid(Player.feetAt(x, y));
}

/// Every tile ID in the map must name a tile in the tile sprite. Otherwise the map would draw blank
/// or wrong tiles. Panics with the offending ID so the map or the sprite can be fixed.
fn checkTileset(level: *const Level, tileset: engine.atlas.Region) void {
    const count = tileset.cellCount(engine.tilemap.tile_size);
    if (level.map.tileset_count) |expected| {
        if (expected != count) {
            std.debug.panic("the map expects {d} tiles, but the tile sprite holds {d}", .{ expected, count });
        }
    }
    const largest = level.map.largestId();
    if (largest >= count) {
        std.debug.panic("the map uses tile ID {d}, but the tile sprite holds only {d} tiles", .{ largest, count });
    }
}
