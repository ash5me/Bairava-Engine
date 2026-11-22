# TB-20 SDL_GPU 2D Backend Parity Smoke

This visual smoke scene runs the same deterministic SDL_GPU 2D workload with a selected SDL_GPU
driver. It is not a direct Vulkan renderer and a successful run on one driver does not establish
cross-backend visual parity.

## Run

From the repository root, build and run the SPIR-V/Vulkan-capable default:

```powershell
zig build run-tb20 -- --frames 360 --seed 20 --revision (git rev-parse HEAD)
```

Request a driver through SDL's `SDL_GPU_DRIVER` hint. SDL may reject a request when its backend,
device, or shader format is unavailable; the runtime-reported driver in the JSON file is the
authoritative value.

```powershell
$env:SDL_GPU_DRIVER = "vulkan"
zig build run-tb20 -- --frames 360 --seed 20 --revision (git rev-parse HEAD)

$env:SDL_GPU_DRIVER = "direct3d12"
zig build run-tb20 -Ddxil=true -- --frames 360 --seed 20 --revision (git rev-parse HEAD)

$env:SDL_GPU_DRIVER = "metal"
zig build run-tb20 -Dmetal=true -- --frames 360 --seed 20 --revision (git rev-parse HEAD)
```

The runtime request is not proof of backend selection. Runs that fail to start are **not run**, not
passes. Clear the variable to let SDL choose its default:

```powershell
Remove-Item Env:SDL_GPU_DRIVER -ErrorAction SilentlyContinue
```

`--frames` is the bounded fixed-update workload length. `--seed` adjusts the scripted animation
phase while all other scene content remains fixed. Escape exits early; an early exit does not write
a completed-run report. A failed backend startup also writes no report, so an existing JSON file
may describe the previous successful run; confirm its `gpu_driver`, seed, and revision before using
it. The testbed writes
`zig-out/bin/TB-20-sdl-gpu-backend-parity-results.json`, including the actual SDL_GPU driver and
device, available shader formats, workload, and process-local frame timings. Use a full SHA with
`--revision` when collecting a baseline.

The JSON distinguishes fixed-update `workload_frames` from rendered `render_frames`; sprite
submission counts are explicit scene `drawSprite` calls, not GPU draw calls or text glyph counts.

## Scene and interpretation

The scene exercises the generated sprite atlas, alpha/tint/rotation, normal-mapped sprites, a
moving point light, bitmap text, and the renderer's off-screen scanline/vignette post-effect chain.
Only Escape is read from physical input; animation is driven by fixed update ticks to avoid
backend-dependent input timing.

`correctness: smoke_setup_pass` means the scene completed its bounded startup/render workload and
the report was written. It is not a pixel-correctness or parity result.
`visual_comparison: not_run` is intentionally retained until screenshots from each available
backend are captured and compared with documented backend-specific tolerances. Record the OS
version, CPU, RAM, display refresh rate, and any visual differences with the result; these values
are not discoverable through the current public runtime APIs. Compare correctness separately from
performance, and do not compare timings across different machines or drivers.
