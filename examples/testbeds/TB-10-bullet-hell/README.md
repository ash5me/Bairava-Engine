# TB-10 Bullet Hell Stress Test

Run the default seeded workload:

```sh
zig build run-tb10
```

Options: `--enemies 256`, `--bullets 1536`, `--frames 360`, and `--seed 0x10B011E7`.
Use `zig build run-tb10 -- --frames 360` for a bounded run. Controls: WASD or arrows move;
Space toggles auto-fire, `F` toggles wave/effect sounds, and Escape quits.

Waves activate a fixed pool of enemies and emit deterministic aimed projectile patterns. Projectiles
use a bounded reusable pool, collide against enabled enemies through the broad-phase index, and are
reclaimed after leaving the play area. Enemy defeats emit particles; short sound playback is
throttled, and unavailable audio voices are counted rather than treated as fatal.

The debug overlay reports active pool sizes, collision queries/candidate checks, hits, reclaim and
exhaustion counts. The JSON report separates collision workload counters from enemy/projectile/
particle sprite submissions and includes whole-frame average/p95 timings. The seed and bounded
capacities make a workload reproducible; GPU timing is intentionally not required.
