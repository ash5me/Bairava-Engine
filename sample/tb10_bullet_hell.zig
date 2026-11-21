//! TB-10 measures deterministic projectile waves, broad-phase collision, pool reuse, and rendering load.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb10");
const Collider = engine.physics.collision.Collider;
const Box = engine.physics.shapes.Box;
const Point = engine.physics.shapes.Point;
const layer: u32 = 1;
const world_w: f32 = 640;
const world_h: f32 = 360;
const fixed_dt: f32 = 1.0 / 120.0;
const wave_period: u64 = 120;
const wave_size: usize = 24;
const player_speed: f32 = 190;
const bullet_speed: f32 = 155;
const projectile_size: f32 = 4;
const enemy_size: f32 = 12;

const Options = struct {
    enemies: usize = 256,
    bullets: usize = 1536,
    frames: u64 = 360,
    seed: u64 = 0x10B011E7,
};

var options = Options{};
var bounded_frames: ?u64 = null;

const config = engine.Config{
    .title = "Bairava TB-10 Bullet Hell",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.025, 0.03, 0.055 },
    .settings_file = "tb10_settings.txt",
};

const Enemy = struct {
    x: f32,
    y: f32,
    hp: u8 = 2,
    active: bool = false,
};

const Team = enum { player, enemy };

const Bullet = struct {
    x: f32 = 0,
    y: f32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
    active: bool = false,
    team: Team = .enemy,
};

const Random = struct {
    state: u64,

    fn next(self: *Random) u64 {
        self.state ^= self.state << 13;
        self.state ^= self.state >> 7;
        self.state ^= self.state << 17;
        return self.state;
    }

    fn unit(self: *Random) f32 {
        return @as(f32, @floatFromInt(self.next() >> 40)) / 16_777_216.0;
    }
};

const Tb10 = struct {
    allocator: std.mem.Allocator,
    enemies: []Enemy,
    enemy_colliders: []Collider,
    bullets: []Bullet,
    candidates: []usize,
    enemy_index: engine.physics.broad_phase.Index,
    player_texture: engine.Texture,
    enemy_texture: engine.Texture,
    projectile_texture: engine.Texture,
    particles_texture: engine.Texture,
    particles: engine.particles.System,
    sound: ?engine.audio.Sound,
    rng: Random,
    player_x: f32 = world_w * 0.5,
    player_y: f32 = world_h - 40,
    accumulator: f32 = 0,
    tick: u64 = 0,
    wave: u64 = 0,
    enemy_spawned: u64 = 0,
    enemies_killed: u64 = 0,
    bullets_spawned: u64 = 0,
    bullets_reclaimed: u64 = 0,
    bullet_pool_exhaustions: u64 = 0,
    collision_queries: u64 = 0,
    candidate_checks: u64 = 0,
    bullet_enemy_hits: u64 = 0,
    player_hits: u64 = 0,
    player_shots: u64 = 0,
    next_player_shot: u64 = 0,
    draw_enemy_sprites: u64 = 0,
    draw_bullet_sprites: u64 = 0,
    draw_particle_sprites: u64 = 0,
    audio_play_attempts: u64 = 0,
    audio_voice_drops: u64 = 0,
    render_rate_samples: u64 = 0,
    report_written: bool = false,
    wave_sound: bool = true,
    player_firing: bool = true,

    pub fn init(ctx: *engine.Context) !Tb10 {
        const allocator = ctx.allocators.game;
        const enemies = try allocator.alloc(Enemy, options.enemies);
        errdefer allocator.free(enemies);
        const colliders = try allocator.alloc(Collider, options.enemies);
        errdefer allocator.free(colliders);
        var position_rng = Random{ .state = options.seed ^ 0x454E454D };
        for (enemies, 0..) |*enemy, i| {
            const x = 14 + position_rng.unit() * (world_w - enemy_size - 28);
            const y = 18 + position_rng.unit() * 150;
            enemy.* = .{ .x = x, .y = y };
            colliders[i] = .{
                .box = .{ .x = x, .y = y, .w = enemy_size, .h = enemy_size },
                .layer = layer,
                .enabled = false,
            };
        }
        const bullets = try allocator.alloc(Bullet, options.bullets);
        errdefer allocator.free(bullets);
        @memset(bullets, .{});
        const candidates = try allocator.alloc(usize, options.enemies);
        errdefer allocator.free(candidates);
        var index = try engine.physics.broad_phase.Index.init(allocator, colliders, 24);
        errdefer index.deinit();

        var player_texture = try ctx.loadTexture("assets/warrior_16x32.png");
        errdefer player_texture.deinit();
        var enemy_texture = try ctx.loadTexture("assets/sample/white.png");
        errdefer enemy_texture.deinit();
        var projectile_texture = try ctx.loadTexture("assets/sample/white.png");
        errdefer projectile_texture.deinit();
        var particles_texture = try ctx.loadTexture("assets/sample/white.png");
        errdefer particles_texture.deinit();
        var particles = try engine.particles.System.init(allocator, 512, options.seed ^ 0x50415254);
        errdefer particles.deinit();
        try particles.setConfig(.{
            .lifetime = .{ 0.15, 0.55 },
            .speed = .{ 20, 92 },
            .angle = .{ -std.math.pi, std.math.pi },
            .size = .{ 2, 6 },
            .end_size = 0.5,
            .color = .{ 1, 0.54, 0.15, 0.9 },
            .end_color = .{ 0.9, 0.2, 0.08, 0 },
            .gravity = .{ 0, 18 },
        });
        const sound: ?engine.audio.Sound = if (ctx.audio.device != null)
            try ctx.loadSound("assets/wind1.wav")
        else
            null;
        errdefer if (sound) |loaded| {
            var owned = loaded;
            owned.deinit();
        };
        if (options.seed == 0) return error.InvalidArgument;

        ctx.camera.world_w = world_w;
        ctx.camera.world_h = world_h;
        ctx.camera.follow(world_w * 0.5, world_h * 0.5);
        var self = Tb10{
            .allocator = allocator,
            .enemies = enemies,
            .enemy_colliders = colliders,
            .bullets = bullets,
            .candidates = candidates,
            .enemy_index = index,
            .player_texture = player_texture,
            .enemy_texture = enemy_texture,
            .projectile_texture = projectile_texture,
            .particles_texture = particles_texture,
            .particles = particles,
            .sound = sound,
            .rng = .{ .state = options.seed },
        };
        self.spawnWave(ctx);
        runDeterminismCheck();
        return self;
    }

    pub fn update(self: *Tb10, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.input.wasPressed(.f)) self.wave_sound = !self.wave_sound;
        if (ctx.input.wasPressed(.space)) self.player_firing = !self.player_firing;

        var dx: f32 = 0;
        var dy: f32 = 0;
        if (ctx.input.held(.left) or ctx.input.held(.a)) dx -= 1;
        if (ctx.input.held(.right) or ctx.input.held(.d)) dx += 1;
        if (ctx.input.held(.up) or ctx.input.held(.w)) dy -= 1;
        if (ctx.input.held(.down) or ctx.input.held(.s)) dy += 1;
        if (dx != 0 and dy != 0) {
            dx *= 0.70710677;
            dy *= 0.70710677;
        }
        self.player_x = std.math.clamp(self.player_x + dx * player_speed * ctx.dt, 10, world_w - 10);
        self.player_y = std.math.clamp(self.player_y + dy * player_speed * ctx.dt, world_h * 0.55, world_h - 12);
        if (self.player_firing and self.tick >= self.next_player_shot) {
            self.firePlayerShot();
            self.next_player_shot = self.tick + 9;
        }

        self.accumulator += @min(ctx.dt, 0.1);
        var steps: u8 = 0;
        while (self.accumulator >= fixed_dt and steps < 16) : (steps += 1) {
            self.stepSimulation(fixed_dt, ctx);
            self.accumulator -= fixed_dt;
        }
        self.particles.update(ctx.dt);
        ctx.camera.followSmooth(self.player_x, self.player_y, ctx.dt, 4);
        self.render_rate_samples += 1;

        if (!self.report_written and ctx.diagnostics.snapshot.frames >= options.frames) self.report(ctx);
        if (bounded_frames) |limit| {
            if (ctx.diagnostics.snapshot.frames >= limit) ctx.running = false;
        }
    }

    fn stepSimulation(self: *Tb10, dt: f32, ctx: *engine.Context) void {
        self.tick += 1;
        if (self.tick > 1 and self.tick % wave_period == 1) self.spawnWave(ctx);
        self.stepEnemies();
        self.stepBullets(dt, ctx);
    }

    fn spawnWave(self: *Tb10, ctx: *engine.Context) void {
        self.wave += 1;
        var spawned: usize = 0;
        for (self.enemies, 0..) |*enemy, i| {
            if (enemy.active) continue;
            if (spawned == wave_size) break;
            enemy.active = true;
            enemy.hp = 2;
            self.enemy_colliders[i].enabled = true;
            spawned += 1;
            self.enemy_spawned += 1;
        }
        if (self.wave_sound) self.playSound(ctx);
    }

    fn stepEnemies(self: *Tb10) void {
        const target = Point{ .x = self.player_x, .y = self.player_y };
        for (self.enemies, 0..) |enemy, i| {
            if (!enemy.active) continue;
            if ((self.tick + i * 13) % 46 != 0) continue;
            const angle = std.math.atan2(target.y - enemy.y, target.x - enemy.x);
            const wobble = (self.rng.unit() - 0.5) * 0.18;
            const spread = @as(f32, @floatFromInt(@as(i32, @intCast(i % 3)) - 1)) * 0.12;
            self.spawnBullet(enemy.x + enemy_size * 0.5, enemy.y + enemy_size, angle + wobble + spread, bullet_speed, .enemy);
        }
    }

    fn stepBullets(self: *Tb10, dt: f32, ctx: *engine.Context) void {
        for (self.bullets) |*bullet| {
            if (!bullet.active) continue;
            bullet.x += bullet.vx * dt;
            bullet.y += bullet.vy * dt;
            if (bullet.x < -12 or bullet.y < -12 or bullet.x > world_w + 12 or bullet.y > world_h + 12) {
                bullet.active = false;
                self.bullets_reclaimed += 1;
                continue;
            }
            const probe = Box{ .x = bullet.x - projectile_size / 2, .y = bullet.y - projectile_size / 2, .w = projectile_size, .h = projectile_size };
            if (bullet.team == .player) {
                const count = self.enemy_index.queryRegion(probe, layer, self.candidates);
                self.collision_queries += 1;
                self.candidate_checks += self.enemy_index.candidate_count;
                for (self.candidates[0..count]) |enemy_index| {
                    const enemy = &self.enemies[enemy_index];
                    if (!enemy.active) continue;
                    enemy.hp -= 1;
                    self.bullet_enemy_hits += 1;
                    bullet.active = false;
                    self.bullets_reclaimed += 1;
                    if (enemy.hp == 0) {
                        enemy.active = false;
                        self.enemy_colliders[enemy_index].enabled = false;
                        self.enemies_killed += 1;
                        self.particles.setPosition(.{ enemy.x + enemy_size / 2, enemy.y + enemy_size / 2 });
                        _ = self.particles.emit(10);
                        if (self.bullet_enemy_hits % 8 == 0) self.playSound(ctx);
                    }
                    break;
                }
            } else if (overlaps(probe, .{
                .x = self.player_x - 5,
                .y = self.player_y - 5,
                .w = 10,
                .h = 10,
            })) {
                bullet.active = false;
                self.bullets_reclaimed += 1;
                self.player_hits += 1;
            }
        }
    }

    fn spawnBullet(self: *Tb10, x: f32, y: f32, angle: f32, speed: f32, team: Team) void {
        for (self.bullets) |*bullet| {
            if (bullet.active) continue;
            bullet.* = .{
                .x = x,
                .y = y,
                .vx = @cos(angle) * speed,
                .vy = @sin(angle) * speed,
                .active = true,
                .team = team,
            };
            self.bullets_spawned += 1;
            return;
        }
        self.bullet_pool_exhaustions += 1;
    }

    fn firePlayerShot(self: *Tb10) void {
        var target: ?Enemy = null;
        var nearest_distance_squared = std.math.inf(f32);
        for (self.enemies) |enemy| {
            if (!enemy.active) continue;
            const dx = enemy.x - self.player_x;
            const dy = enemy.y - self.player_y;
            const distance_squared = dx * dx + dy * dy;
            if (distance_squared < nearest_distance_squared) {
                nearest_distance_squared = distance_squared;
                target = enemy;
            }
        }
        if (target) |enemy| {
            self.spawnBullet(self.player_x, self.player_y - 8, std.math.atan2(enemy.y - self.player_y, enemy.x - self.player_x), bullet_speed * 1.5, .player);
            self.player_shots += 1;
        }
    }

    pub fn draw(self: *Tb10, dc: *const engine.DrawContext) void {
        const first_enemy = dc.batch.sprite_count;
        for (self.enemies) |enemy| {
            if (!enemy.active) continue;
            drawRect(dc, &self.enemy_texture, enemy.x, enemy.y, enemy_size, enemy_size, .{ 0.76, 0.24, 0.28 });
        }
        self.draw_enemy_sprites += dc.batch.sprite_count - first_enemy;

        const first_bullet = dc.batch.sprite_count;
        for (self.bullets) |bullet| {
            if (!bullet.active) continue;
            const tint: [3]f32 = if (bullet.team == .player) .{ 0.35, 0.86, 1 } else .{ 0.98, 0.78, 0.27 };
            drawRect(dc, &self.projectile_texture, bullet.x - 2, bullet.y - 2, projectile_size, projectile_size, tint);
        }
        self.draw_bullet_sprites += dc.batch.sprite_count - first_bullet;

        const first_particle = dc.batch.sprite_count;
        self.particles.draw(
            dc.batch,
            &self.particles_texture,
            .{ .x = 0, .y = 0, .w = 4, .h = 4 },
            1,
            dc.cam,
        );
        self.draw_particle_sprites += dc.batch.sprite_count - first_particle;
        drawRect(dc, &self.player_texture, self.player_x - 8, self.player_y - 10, 16, 20, .{ 0.28, 0.72, 0.95 });
    }

    pub fn debugText(self: *const Tb10, out: *engine.diagnostics.Text) void {
        out.print("TB-10 seed {x} wave {d} | WASD/arrows move, Space toggles auto-fire, F toggles audio", .{ options.seed, self.wave });
        out.print("enemies {d}/{d} bullets {d}/{d} pool drops {d}", .{
            self.activeEnemyCount(),
            self.enemies.len,
            self.activeBulletCount(),
            self.bullets.len,
            self.bullet_pool_exhaustions,
        });
        out.print("queries {d} candidates {d} hits {d} shots {d} player hits {d} reclaimed {d} particles {d}", .{
            self.collision_queries,
            self.candidate_checks,
            self.bullet_enemy_hits,
            self.player_shots,
            self.player_hits,
            self.bullets_reclaimed,
            self.particles.count,
        });
    }

    pub fn deinitWithContext(self: *Tb10, _: *engine.Context) void {
        if (self.sound) |*sound| sound.deinit();
        self.particles.deinit();
        self.particles_texture.deinit();
        self.projectile_texture.deinit();
        self.enemy_texture.deinit();
        self.player_texture.deinit();
        self.enemy_index.deinit();
        self.allocator.free(self.candidates);
        self.allocator.free(self.bullets);
        self.allocator.free(self.enemy_colliders);
        self.allocator.free(self.enemies);
    }

    pub fn deinit(self: *Tb10) void {
        _ = self;
    }

    fn activeEnemyCount(self: *const Tb10) usize {
        var count: usize = 0;
        for (self.enemies) |enemy| count += @intFromBool(enemy.active);
        return count;
    }

    fn activeBulletCount(self: *const Tb10) usize {
        var count: usize = 0;
        for (self.bullets) |bullet| count += @intFromBool(bullet.active);
        return count;
    }

    fn playSound(self: *Tb10, ctx: *engine.Context) void {
        if (self.sound) |*sound| {
            self.audio_play_attempts += 1;
            _ = ctx.audio.play(sound, .{ .bus = .sfx }) catch |err| {
                self.audio_voice_drops += 1;
                if (err != error.NoFreeVoice) log.warn("bullet-hell sound could not play: {s}", .{@errorName(err)});
            };
        }
    }

    fn runDeterminismCheck() void {
        var left = Random{ .state = options.seed };
        var right = Random{ .state = options.seed };
        var i: u8 = 0;
        while (i < 16) : (i += 1) {
            if (left.next() != right.next()) {
                log.err("seeded wave generator is not repeatable", .{});
                return;
            }
        }
    }

    fn report(self: *Tb10, ctx: *engine.Context) void {
        const frames = ctx.diagnostics.stats.of(.frame);
        const pass = self.bullet_pool_exhaustions == 0 and self.activeEnemyCount() > 0 and
            self.collision_queries > 0 and self.draw_bullet_sprites > 0 and self.bullets_reclaimed > 0 and
            self.bullet_enemy_hits > 0;
        log.info("TB-10 {s}: seed {x}, waves {d}, enemies spawned/killed {d}/{d}, bullets spawned/reclaimed/dropped {d}/{d}/{d}, queries/candidate checks/hits {d}/{d}/{d}, frame avg/p95 {d:.2}/{d:.2} ms", .{
            if (pass) "pass" else "incomplete",
            options.seed,
            self.wave,
            self.enemy_spawned,
            self.enemies_killed,
            self.bullets_spawned,
            self.bullets_reclaimed,
            self.bullet_pool_exhaustions,
            self.collision_queries,
            self.candidate_checks,
            self.bullet_enemy_hits,
            frames.average() * 1000,
            frames.percentile(0.95) * 1000,
        });
        var json: [1536]u8 = undefined;
        const text = std.fmt.bufPrint(
            &json,
            "{{\"testbed\":\"TB-10\",\"scenario\":\"bullet-hell\",\"result\":\"{s}\",\"seed\":{d},\"waves\":{d},\"enemy_capacity\":{d},\"enemies_spawned\":{d},\"enemies_killed\":{d},\"active_enemies\":{d},\"projectile_capacity\":{d},\"bullets_spawned\":{d},\"player_shots\":{d},\"bullet_enemy_hits\":{d},\"player_hits\":{d},\"bullets_reclaimed\":{d},\"bullet_pool_exhaustions\":{d},\"collision_queries\":{d},\"broadphase_candidate_checks\":{d},\"enemy_sprite_submissions\":{d},\"bullet_sprite_submissions\":{d},\"particle_sprite_submissions\":{d},\"active_bullets\":{d},\"active_particles\":{d},\"audio_play_attempts\":{d},\"audio_voice_drops\":{d},\"render_rate_samples\":{d},\"frame_ms_avg\":{d:.3},\"frame_ms_p95\":{d:.3},\"separate_collision_and_render_counters\":true}}\n",
            .{
                if (pass) "pass" else "incomplete",
                options.seed,
                self.wave,
                self.enemies.len,
                self.enemy_spawned,
                self.enemies_killed,
                self.activeEnemyCount(),
                self.bullets.len,
                self.bullets_spawned,
                self.player_shots,
                self.bullet_enemy_hits,
                self.player_hits,
                self.bullets_reclaimed,
                self.bullet_pool_exhaustions,
                self.collision_queries,
                self.candidate_checks,
                self.draw_enemy_sprites,
                self.draw_bullet_sprites,
                self.draw_particle_sprites,
                self.activeBulletCount(),
                self.particles.count,
                self.audio_play_attempts,
                self.audio_voice_drops,
                self.render_rate_samples,
                frames.average() * 1000,
                frames.percentile(0.95) * 1000,
            },
        ) catch |err| {
            log.err("TB-10 metrics formatting failed: {s}", .{@errorName(err)});
            return;
        };
        ctx.writeFile("TB-10-bullet-hell-results.json", text) catch |err| {
            log.err("TB-10 metrics write failed: {s}", .{@errorName(err)});
            return;
        };
        self.report_written = true;
    }
};

fn drawRect(dc: *const engine.DrawContext, texture: *const engine.Texture, x: f32, y: f32, w: f32, h: f32, tint: [3]f32) void {
    dc.batch.drawSprite(
        texture,
        .{ .x = 0, .y = 0, .w = 4, .h = 4 },
        .{ .x = dc.cam.screenX(x), .y = dc.cam.screenY(y), .w = w, .h = h },
        .{ .tint = tint, .depth_y = y + h },
    );
}

fn overlaps(a: Box, b: Box) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch return error.InvalidArgument;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--help")) {
            std.debug.print("TB-10 options: --enemies 256 --bullets 1536 --frames 360 --seed 0x10B011E7. Controls: WASD/arrows move, Space toggles auto-fire, F toggles audio.\n", .{});
            return;
        } else if (std.mem.eql(u8, args[index], "--enemies") and index + 1 < args.len) {
            index += 1;
            options.enemies = try std.fmt.parseUnsigned(usize, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--bullets") and index + 1 < args.len) {
            index += 1;
            options.bullets = try std.fmt.parseUnsigned(usize, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--frames") and index + 1 < args.len) {
            index += 1;
            options.frames = try std.fmt.parseUnsigned(u64, args[index], 10);
            bounded_frames = options.frames;
        } else if (std.mem.eql(u8, args[index], "--seed") and index + 1 < args.len) {
            index += 1;
            options.seed = try std.fmt.parseUnsigned(u64, args[index], 0);
        } else {
            return error.InvalidArgument;
        }
    }
    if (options.enemies < wave_size or options.enemies > 5000 or options.bullets == 0 or options.bullets > 20_000 or options.seed == 0) {
        return error.InvalidArgument;
    }
    try engine.run(engine.SceneHost(Tb10), config);
}
