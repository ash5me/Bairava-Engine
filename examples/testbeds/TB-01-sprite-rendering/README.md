# TB-01 Sprite Rendering Stress Test

Purpose: establish the deterministic sprite-rendering baseline through the public engine API.

## Run

```sh
zig build run-tb01 -- --count 10000 --textures many --seed 12345 --frames 180
zig build run-tb01 -- --count 100 --textures one --seed 12345 --frames 180
zig build run-tb01 -- --count 10000 --textures many --gpu-timing --seed 12345 --frames 180
```

Supported workload counts are `100`, `500`, `1000`, `5000`, and `10000`. Texture modes are `one`,
`small`, and `many`. The window closes automatically after the requested frame count. Escape also
ends the run.

The default configuration uses 1,000 sprites, the small texture set, and no GPU timing stall.
GPU timing is opt-in with `--gpu-timing`; it waits for the GPU each frame and should not be used
as a frame-rate target. Use F3 for live diagnostics.

At the end of the warm-up and 120-frame report window, the test logs:

- frame average, median, p95, p99, and maximum
- update, draw, present, and GPU timing
- submitted sprites and draw calls
- allocation count and plot spikes

The run writes `TB-01-sprite-rendering-results.json` beside the executable. The JSON is a local
machine-readable summary; do not compare it across machines unless OS, CPU, GPU, driver, display,
and build mode are recorded.

## Known limitations

- Reference screenshots are not yet captured automatically.
- Sorting, batching, mirroring, tint, alpha, scale, and rotation are exercised visually and through
  existing sprite unit tests; this sample does not invent private correctness hooks.
- Point lights, normal maps, shadow casters, off-screen targets, and post-processing are not enabled
  in the baseline. They remain separate workload modes for a follow-up TB-01 result pass.
