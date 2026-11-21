# TB-05 Collision and Physics Test

Purpose: validate the collision query broad phase against the linear reference queries for a
deterministic mixed-shape scene.

## Run

```sh
zig build run-tb05 -- --count 100 --probes 8 --frames 180
zig build run-tb05 -- --count 500 --probes 4 --frames 180
zig build run-tb05 -- --count 1000 --probes 2 --frames 180
zig build run-tb05 -- --count 5000 --probes 1 --frames 180
```

`--probes` sets the number of comparisons per update (1-256; defaults to 1). `--frames` selects
when the summary is written; the window remains open until Escape. After reporting, the workload
pauses so the large-count tiers do not continue to monopolize CPU while the window remains open.

The scene combines axis-aligned and rotated boxes, circles, disabled colliders, trigger shapes,
two collision layers, and a dense overlapping cluster. Region queries, raycasts, box/circle casts,
and box movement are compared with the broad-phase index and linear query implementations using
alternating layer masks. A separate moving-trigger fixture checks enter, stay, and exit transitions.
Any broad-phase mismatch is logged, records a failed result, and stops the workload.

Metrics include query parity failures, average broad-phase candidates, hit counts, movement
checks, trigger transitions, and frame-time average/p95. Results are written to
`TB-05-collision-results.json` beside the executable.

## Scope and limitations

This testbed validates the current query and movement-resolution APIs; it is not a rigid-body
solver and does not simulate forces, joints, or velocity integration. The movement case exercises
the current axis-separated `moveBox` behavior, while shape casts are swept queries. Fast-motion
behavior should not be generalized beyond the tested shapes and paths.
