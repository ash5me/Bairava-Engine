# TB-22 Particle Pool and Overdraw Stress

Purpose: exercise bounded particle storage, burst saturation, continuous emission, producer
shutdown, particle lifetime independence, and transparent sprite overdraw.

## Run

```sh
zig build run-tb22 -- --capacity 256 --burst 192 --frames 180
zig build run-tb22 -- --capacity 1024 --burst 192 --frames 180
zig build run-tb22 -- --capacity 4096 --frames 180
```

`--capacity` accepts 256, 1024, or 4096 particles. By default, `--burst` scales to at least 192
and otherwise one quarter of capacity; explicitly setting it controls requested particles per burst
(up to twice the capacity). `--frames` selects the earliest frame for reporting. The run
waits until the timed emitter has stopped and post-stop particle survival has been observed; the
window then remains open until Escape.

Controls:

- `Space`: stop/start the emitter. Stopping emission does not destroy live particles.
- `F`: pause/resume camera follow.
- `+` / `-` and `0`: zoom in/out and reset zoom.
- `Escape`: quit.

The test combines periodic bursts with sustained emission. Capacity exhaustion drops newest
particles: `System.emit` returns the accepted count, and the sample records requested, spawned,
dropped, and expired totals. The fixed pool is allocated once and never grows. Per-frame field
validation catches invalid age/lifetime, non-finite motion/rotation, and stale colors/sizes after
slots are reused. The scene uses translucent particles, a moving camera, and reports visible sprite
counts plus a visible sprite-area overdraw estimate. Results are written to
`TB-22-particle-results.json` beside the executable.

The particle renderer currently submits particles as ordinary unlit sprites. Lighting interaction,
emitter-owned particle cancellation, and automatic pool recycling are not provided by this API;
particles already emitted remain system-owned until their configured lifetimes expire.
