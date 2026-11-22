# TB-13 Lighting Laboratory

TB-13 compares an unlit stone tile with tiled normal-mapped samples under moving, overlapping
colored point lights. It also draws a moving visible occluder and shadow segment. The matching
64x64 albedo and tangent-space normal map are in `assets/testbeds/tb13/`.

## Run a bounded validation

```powershell
zig build run-tb13 -- --frames 360 --lights 3
```

For an automated full-capacity scene (16 lights and 16 shadow segments), use:

```powershell
zig build run-tb13 -- --frames 360 --capacity-sweep
```

The runner enables GPU timing and writes `TB-13-lighting-results-N.json` beside the executable,
where `N` is the active light count. The report records capacity checks, normal-map/depth checks,
sprite/light/shadow samples, and average/p95 frame and GPU time. Capacity validation fills all
16 light and 16 shadow slots, verifies one additional item is rejected for each, and reports
failures in the result.

## Controls

- Left/Right: decrease/increase the active point-light count (0–16).
- Up/Down: increase/decrease ambient level.
- Space: toggle the moving occluder and its shadow segment.
- F: toggle the maximum-capacity scene (16 lights and 16 shadow segments).
- E: toggle animated normal-map rotation.
- Escape: exit.

For a light-cost sweep, run the bounded command once at each count. For example:

```powershell
1..16 | ForEach-Object { zig build run-tb13 -- --frames 360 --lights $_ }
```

The per-count JSON files remain in `zig-out/bin`. GPU timing waits for each frame's GPU work to
finish; compare runs on the same machine and renderer, and retain the reported GPU timings rather
than treating frame time as GPU-only cost.

## Visual review

Capture a screenshot at 1, 4, 8, and 16 lights, with the moving shadow on and off, and inspect
the unlit reference against the normal-mapped tiles. Use `F` to check the full shadow-segment
capacity and `E` to check that flipped/rotated normals follow their sprites. These screenshots
and renderer-specific performance results are manual checks; a bounded smoke run does not replace
them.
