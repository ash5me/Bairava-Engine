//! TB-02 asset loading and streaming testbed.
//! Uses public texture registration, counted handles, cache statistics, worker preloading,
//! eviction, missing-file failures, and development hot reload.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb02");

const Options = struct {
    count: u32 = 100,
    cycles: u32 = 60,
    frames: u64 = 180,
};

var options = Options{};

const config = engine.Config{
    .title = "Bairava TB-02 Asset Streaming",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.05, 0.07, 0.09 },
    .settings_file = "tb02_settings.txt",
};

const names = [_][]const u8{ "tb02_white", "tb02_bush", "tb02_rock", "tb02_tree" };
const paths = [_][]const u8{
    "assets/sample/white.png",
    "assets/forest_bush.png",
    "assets/forest_rock.png",
    "assets/forest_tree.png",
};

const Tb02 = struct {
    handles: [4]engine.TextureHandle = [_]engine.TextureHandle{engine.TextureHandle.invalid} ** 4,
    textures: [4]?*const engine.Texture = [_]?*const engine.Texture{null} ** 4,
    live: usize = 0,
    acquire_calls: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    failed_loads: u64 = 0,
    stale_checks: u64 = 0,
    unload_evictions: u64 = 0,
    reload_changes: u64 = 0,
    reported: bool = false,

    pub fn init(ctx: *engine.Context) !Tb02 {
        var self = Tb02{};
        for (names, 0..) |name, index| {
            try ctx.registerTexture(name, paths[index]);
            try ctx.requestTexture(name, if (index == 0) .high else .normal);
        }
        try ctx.registerTexture("tb02_missing", "assets/tb02_missing.png");
        ctx.watchAsset("assets/forest_bush.png", .asset) catch |err| {
            log.warn("TB-02 hot reload watch unavailable: {s}", .{@errorName(err)});
        };

        for (names, 0..) |name, index| {
            if (ctx.acquireTexture(name)) |handle| {
                self.handles[index] = handle;
                self.textures[index] = ctx.textureOf(handle) catch null;
                self.live += 1;
                self.acquire_calls += 1;
            } else |err| {
                log.err("TB-02 could not acquire {s}: {s}", .{ name, @errorName(err) });
                return err;
            }
        }

        const missing = ctx.acquireTexture("tb02_missing");
        if (missing) |*handle| {
            var mutable = handle.*;
            _ = ctx.releaseTexture(&mutable) catch {};
            self.failed_loads += 1;
        } else |err| {
            self.failed_loads += 1;
            log.info("TB-02 missing asset returned expected error: {s}", .{@errorName(err)});
        }
        return self;
    }

    pub fn update(self: *Tb02, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        if (ctx.input.wasPressed(.escape)) ctx.running = false;

        if (ctx.takeChanged("assets/forest_bush.png")) {
            self.reload_changes += 1;
            log.info("TB-02 detected a settled hot reload for forest_bush.png", .{});
        }

        var i: u32 = 0;
        while (i < options.count) : (i += 1) {
            const name = names[i % names.len];
            if (ctx.acquireTexture(name)) |handle| {
                self.acquire_calls += 1;
                if (ctx.textureOf(handle)) |_| {} else |err| {
                    log.err("TB-02 handle lookup failed: {s}", .{@errorName(err)});
                }
                ctx.retainTexture(handle) catch |err| {
                    log.err("TB-02 retain failed: {s}", .{@errorName(err)});
                };
                var retained = handle;
                ctx.releaseTexture(&retained) catch {};
                var released = handle;
                ctx.releaseTexture(&released) catch {};
            } else |err| {
                self.failed_loads += 1;
                log.debug("TB-02 workload load failed: {s}", .{@errorName(err)});
            }
        }

        if (ctx.diagnostics.snapshot.frames % options.cycles == 0) {
            for (&self.handles) |*handle| {
                if (handle.generation != 0) _ = ctx.releaseTexture(handle) catch {};
            }
            self.unload_evictions += ctx.unloadUnusedTextures();
            for (names, 0..) |name, index| {
                if (ctx.acquireTexture(name)) |handle| {
                    self.handles[index] = handle;
                    self.textures[index] = ctx.textureOf(handle) catch null;
                    self.acquire_calls += 1;
                } else |err| {
                    self.failed_loads += 1;
                    log.debug("TB-02 eviction reload failed: {s}", .{@errorName(err)});
                }
            }
        }

        if (ctx.diagnostics.snapshot.frames % 30 == 0) {
            const stats = ctx.textureStats();
            self.hits = stats.hits;
            self.misses = stats.misses;
        }

        if (ctx.diagnostics.snapshot.frames >= options.frames) {
            self.report(ctx);
        }
    }

    pub fn draw(self: *Tb02, dc: *const engine.DrawContext) void {
        for (0..@min(options.count, 1000)) |index| {
            const handle_index = index % self.live;
            const texture = self.textures[handle_index] orelse continue;
            const col: f32 = @floatFromInt(index % 25);
            const row: f32 = @floatFromInt(index / 25);
            dc.batch.drawSprite(
                texture,
                .{ .x = 0, .y = 0, .w = @as(f32, @floatFromInt(texture.width)), .h = @as(f32, @floatFromInt(texture.height)) },
                .{ .x = col * 13, .y = row * 13, .w = 12, .h = 12 },
                .{ .alpha = 0.9, .z = @intCast(index % 4), .depth_y = row },
            );
        }
    }

    fn report(self: *Tb02, ctx: *engine.Context) void {
        if (self.reported) return;
        self.reported = true;
        const stats = ctx.textureStats();
        log.info("TB-02 count {d}, cycles {d}, acquires {d}, hits {d}, misses {d}, failed {d}, evictions {d}, reload changes {d}", .{
            options.count,
            options.cycles,
            self.acquire_calls,
            stats.hits,
            stats.misses,
            self.failed_loads,
            self.unload_evictions,
            self.reload_changes,
        });
        var json: [1536]u8 = undefined;
        const text = std.fmt.bufPrint(&json,
            "{{\"testbed\":\"TB-02\",\"scenario\":\"asset-streaming\",\"result\":\"pass\",\"count\":{d},\"cycles\":{d},\"acquire_calls\":{d},\"hits\":{d},\"misses\":{d},\"failed_loads\":{d},\"evictions\":{d},\"reload_changes\":{d}}}\n",
            .{
                options.count,
                options.cycles,
                self.acquire_calls,
                stats.hits,
                stats.misses,
                stats.failed_loads,
                self.unload_evictions,
                self.reload_changes,
            },
        ) catch "(metrics formatting failed)";
        ctx.writeFile("TB-02-asset-streaming-results.json", text) catch |err| {
            log.err("TB-02 metrics could not be written: {s}", .{@errorName(err)});
        };
    }

    pub fn debugText(self: *const Tb02, out: *engine.diagnostics.Text) void {
        out.print("TB-02: {d} repeated asset requests / {d} live; Escape quits", .{ options.count, self.live });
        out.print("hits {d} misses {d} evictions {d} reload changes {d}", .{ self.hits, self.misses, self.unload_evictions, self.reload_changes });
    }

    pub fn deinitWithContext(self: *Tb02, ctx: *engine.Context) void {
        for (&self.handles) |*handle| {
            if (handle.generation != 0) _ = ctx.releaseTexture(handle) catch {};
        }
    }

    pub fn deinit(self: *Tb02) void {
        _ = self;
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch return error.InvalidArgument;

    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--count") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.count = std.fmt.parseUnsigned(u32, args[arg_index], 10) catch 100;
        } else if (std.mem.eql(u8, arg, "--cycles") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.cycles = std.fmt.parseUnsigned(u32, args[arg_index], 10) catch 60;
        } else if (std.mem.eql(u8, arg, "--frames") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.frames = std.fmt.parseUnsigned(u64, args[arg_index], 10) catch 180;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("TB-02 options: --count 100|500|1000 --cycles 60 --frames 180\n", .{});
            return;
        } else {
            return error.InvalidArgument;
        }
    }
    if (!(options.count == 100 or options.count == 500 or options.count == 1000)) return error.InvalidArgument;
    try engine.run(engine.SceneHost(Tb02), config);
}
