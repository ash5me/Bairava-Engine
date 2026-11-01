//! Bounded, deterministic particle simulation with optional SpriteBatch rendering.

const std = @import("std");
const sprite = @import("renderer/sprite.zig");
const texture = @import("renderer/texture.zig");

/// Per-system parameters shared by continuous and burst emission.
pub const Config = struct {
    /// Particles emitted each second. `update` accumulates fractional emissions.
    emission_rate: f32 = 0,
    /// Inclusive lifetime range in seconds.
    lifetime: [2]f32 = .{ 1, 1 },
    /// Inclusive initial speed range.
    speed: [2]f32 = .{ 0, 0 },
    /// Inclusive initial direction range in radians. Zero points right.
    angle: [2]f32 = .{ 0, 0 },
    /// Inclusive initial size range in pixels.
    size: [2]f32 = .{ 1, 1 },
    /// Final size in pixels, interpolated from each particle's initial size.
    end_size: f32 = 0,
    /// Initial and final RGBA tint.
    color: [4]f32 = .{ 1, 1, 1, 1 },
    end_color: [4]f32 = .{ 1, 1, 1, 0 },
    /// Constant acceleration applied in pixels per second squared.
    gravity: [2]f32 = .{ 0, 0 },
};

/// A live particle. Values are public for inspection and game-specific effects.
pub const Particle = struct {
    position: [2]f32,
    velocity: [2]f32,
    age: f32,
    lifetime: f32,
    start_size: f32,
    end_size: f32,
    start_color: [4]f32,
    end_color: [4]f32,
    rotation: f32 = 0,
    angular_velocity: f32 = 0,

    /// Progress through the particle's life, clamped to 0..1.
    pub fn progress(self: Particle) f32 {
        return std.math.clamp(self.age / self.lifetime, 0, 1);
    }

    pub fn currentSize(self: Particle) f32 {
        return lerp(self.start_size, self.end_size, self.progress());
    }

    pub fn currentColor(self: Particle) [4]f32 {
        return lerpColor(self.start_color, self.end_color, self.progress());
    }
};

/// Fixed-capacity particle storage. No allocations occur after initialization.
pub const System = struct {
    allocator: std.mem.Allocator,
    particles: []Particle,
    count: usize = 0,
    position: [2]f32 = .{ 0, 0 },
    config: Config = .{},
    emission_remainder: f64 = 0,
    random_state: u64,

    pub const Error = std.mem.Allocator.Error || error{InvalidConfig};

    /// Allocates room for at most `capacity` live particles and seeds the deterministic RNG.
    pub fn init(allocator: std.mem.Allocator, capacity: usize, seed: u64) std.mem.Allocator.Error!System {
        return .{
            .allocator = allocator,
            .particles = try allocator.alloc(Particle, capacity),
            .random_state = if (seed == 0) 0x9e3779b97f4a7c15 else seed,
        };
    }

    pub fn deinit(self: *System) void {
        self.allocator.free(self.particles);
        self.* = undefined;
    }

    /// Replaces emission parameters. Invalid values leave the prior configuration unchanged.
    pub fn setConfig(self: *System, config: Config) Error!void {
        if (!validConfig(config)) return error.InvalidConfig;
        self.config = config;
    }

    /// Sets the world-space origin for subsequently emitted particles.
    pub fn setPosition(self: *System, position: [2]f32) void {
        self.position = position;
    }

    /// Emits up to `amount` particles immediately and returns how many fit.
    pub fn emit(self: *System, amount: usize) usize {
        const available = self.particles.len - self.count;
        const emitted = @min(amount, available);
        for (0..emitted) |_| self.spawn();
        return emitted;
    }

    /// Advances particles, removes expired ones, then performs configured continuous emission.
    /// Non-finite or non-positive time steps are ignored.
    pub fn update(self: *System, dt: f32) void {
        if (!std.math.isFinite(dt) or dt <= 0) return;

        var alive: usize = 0;
        for (self.particles[0..self.count]) |particle| {
            var next = particle;
            next.age += dt;
            if (next.age >= next.lifetime) continue;

            next.velocity[0] += self.config.gravity[0] * dt;
            next.velocity[1] += self.config.gravity[1] * dt;
            next.position[0] += next.velocity[0] * dt;
            next.position[1] += next.velocity[1] * dt;
            next.rotation += next.angular_velocity * dt;
            self.particles[alive] = next;
            alive += 1;
        }
        self.count = alive;

        self.emission_remainder += @as(f64, self.config.emission_rate) * @as(f64, dt);
        const requested_float = @floor(self.emission_remainder);
        const requested: usize = if (requested_float >= @as(f64, @floatFromInt(self.particles.len - self.count)))
            self.particles.len - self.count
        else
            @intFromFloat(requested_float);
        self.emission_remainder -= requested_float;
        _ = self.emit(requested);
    }

    /// Queues every live particle as a centered, tinted sprite.
    pub fn draw(
        self: *const System,
        batch: *sprite.SpriteBatch,
        texture_ref: *const texture.Texture,
        source: sprite.Rect,
        z: i32,
    ) void {
        for (self.particles[0..self.count]) |particle| {
            const size = particle.currentSize();
            const color = particle.currentColor();
            batch.drawSprite(texture_ref, source, .{
                .x = particle.position[0] - size * 0.5,
                .y = particle.position[1] - size * 0.5,
                .w = size,
                .h = size,
            }, .{
                .tint = .{ color[0], color[1], color[2] },
                .alpha = color[3],
                .origin = .{ size * 0.5, size * 0.5 },
                .rotation = particle.rotation,
                .z = z,
            });
        }
    }

    fn spawn(self: *System) void {
        const speed = randomRange(self, self.config.speed);
        const angle = randomRange(self, self.config.angle);
        self.particles[self.count] = .{
            .position = self.position,
            .velocity = .{ @cos(angle) * speed, @sin(angle) * speed },
            .age = 0,
            .lifetime = randomRange(self, self.config.lifetime),
            .start_size = randomRange(self, self.config.size),
            .end_size = self.config.end_size,
            .start_color = self.config.color,
            .end_color = self.config.end_color,
        };
        self.count += 1;
    }

    fn nextRandom(self: *System) f32 {
        var value = self.random_state;
        value ^= value >> 12;
        value ^= value << 25;
        value ^= value >> 27;
        self.random_state = value;
        const bits = value *% 0x2545f4914f6cdd1d;
        return @as(f32, @floatFromInt(bits >> 40)) / 16777216.0;
    }
};

fn randomRange(system: *System, range: [2]f32) f32 {
    return range[0] + (range[1] - range[0]) * system.nextRandom();
}

fn lerp(start: f32, end: f32, amount: f32) f32 {
    return start + (end - start) * amount;
}

fn lerpColor(start: [4]f32, end: [4]f32, amount: f32) [4]f32 {
    return .{
        lerp(start[0], end[0], amount),
        lerp(start[1], end[1], amount),
        lerp(start[2], end[2], amount),
        lerp(start[3], end[3], amount),
    };
}

fn validConfig(config: Config) bool {
    if (!finite(config.emission_rate) or config.emission_rate < 0) return false;
    if (!validRange(config.lifetime) or config.lifetime[0] <= 0) return false;
    if (!validRange(config.speed) or config.speed[0] < 0) return false;
    if (!validRange(config.angle)) return false;
    if (!validRange(config.size) or config.size[0] < 0) return false;
    if (!finite(config.end_size) or config.end_size < 0) return false;
    for (config.gravity) |component| if (!finite(component)) return false;
    for (config.color) |component| if (!unit(component)) return false;
    for (config.end_color) |component| if (!unit(component)) return false;
    return true;
}

fn validRange(range: [2]f32) bool {
    return finite(range[0]) and finite(range[1]) and range[0] <= range[1];
}

fn finite(value: f32) bool {
    return std.math.isFinite(value);
}

fn unit(value: f32) bool {
    return finite(value) and value >= 0 and value <= 1;
}

test "burst emission respects capacity and update removes expired particles" {
    var system = try System.init(std.testing.allocator, 2, 1);
    defer system.deinit();

    try system.setConfig(.{ .lifetime = .{ 0.5, 0.5 }, .speed = .{ 2, 2 }, .angle = .{ 0, 0 } });
    system.setPosition(.{ 3, 4 });
    try std.testing.expectEqual(@as(usize, 2), system.emit(4));
    try std.testing.expectEqual(@as(usize, 2), system.count);
    system.update(0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), system.particles[0].position[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4), system.particles[0].position[1], 1e-6);
    system.update(0.25);
    try std.testing.expectEqual(@as(usize, 0), system.count);
}

test "continuous emission preserves fractional rates and ignores invalid time steps" {
    var system = try System.init(std.testing.allocator, 10, 2);
    defer system.deinit();
    try system.setConfig(.{ .emission_rate = 2 });

    system.update(0.25);
    try std.testing.expectEqual(@as(usize, 0), system.count);
    system.update(0.25);
    try std.testing.expectEqual(@as(usize, 1), system.count);
    system.update(std.math.nan(f32));
    system.update(-1);
    try std.testing.expectEqual(@as(usize, 1), system.count);
}

test "seeded systems produce identical particles and interpolation" {
    var first = try System.init(std.testing.allocator, 4, 42);
    defer first.deinit();
    var second = try System.init(std.testing.allocator, 4, 42);
    defer second.deinit();
    const config = Config{
        .lifetime = .{ 1, 2 },
        .speed = .{ 3, 5 },
        .angle = .{ -1, 1 },
        .size = .{ 2, 8 },
    };
    try first.setConfig(config);
    try second.setConfig(config);
    _ = first.emit(4);
    _ = second.emit(4);

    for (first.particles[0..first.count], second.particles[0..second.count]) |a, b| {
        try std.testing.expectEqual(a.position, b.position);
        try std.testing.expectEqual(a.velocity, b.velocity);
        try std.testing.expectEqual(a.lifetime, b.lifetime);
        try std.testing.expectEqual(a.start_size, b.start_size);
    }
    first.update(0.5);
    const particle = first.particles[0];
    try std.testing.expectApproxEqAbs(
        particle.start_size + (particle.end_size - particle.start_size) * particle.progress(),
        particle.currentSize(),
        1e-6,
    );
}

test "invalid configuration leaves the previous configuration unchanged" {
    var system = try System.init(std.testing.allocator, 1, 3);
    defer system.deinit();

    try std.testing.expectError(error.InvalidConfig, system.setConfig(.{ .lifetime = .{ 0, 1 } }));
    try std.testing.expectEqual(@as(f32, 0), system.config.emission_rate);
    try std.testing.expectError(error.InvalidConfig, system.setConfig(.{ .color = .{ 1, 1, 1, 2 } }));
}
