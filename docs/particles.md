# Particles

`bairava.particles.System` simulates bounded, deterministic particles and can queue them as sprites.
Create a system with an allocator, maximum live-particle count, and RNG seed; configure it, set its
emitter position, then call `update(dt)` during game updates:

```zig
var particles = try engine.particles.System.init(allocator, 256, 1234);
defer particles.deinit();

try particles.setConfig(.{
    .emission_rate = 40,
    .lifetime = .{ 0.4, 0.8 },
    .speed = .{ 20, 60 },
    .angle = .{ -3.14, 0 },
    .size = .{ 2, 6 },
    .end_size = 0,
});
particles.setPosition(.{ 100, 80 });
particles.update(dt);
```

Continuous emission preserves fractional particles between updates. `emit(count)` creates a burst
immediately and returns the number that fit; the system never exceeds its fixed capacity and does
not allocate after initialization. Particle lifetime, speed, angle, and size ranges are sampled
deterministically from the supplied seed. `setConfig` rejects non-finite or out-of-range values
without changing the previous configuration. Non-finite and non-positive update steps are ignored.

To draw, call `System.draw(&sprite_batch, texture, source_rect, z)` after beginning the sprite batch.
Particles are centered on their positions and interpolate their size and RGBA tint over their
lifetime. Gravity is constant per system and affects velocity. Game code owns the texture and
controls particle-system lifetime.
