# TB-08 Isometric World

Run the interactive world:

```sh
zig build run-tb08
```

For an automated bounded smoke run, use `zig build run-tb08 -- --frames 180`.

Click any walkable cell to pathfind to it. WASD or the arrow keys request a neighboring cell,
`+`/`-` zoom, `0` resets zoom, and Escape quits. After 180 frames the sample writes
`TB-08-isometric-results.json` beside the executable and continues running.

The sample projects a small tilemap into isometric screen coordinates, uses the engine's tilemap
collision and A* grid navigation, and sorts the grounded character and tall props by their projected
ground-contact Y. Its report checks every cell's projection/inverse mapping, validates an example
navigation route, and checks representative depth-order comparisons. Click and movement counters
are recorded for manual interaction runs.

Elevation limitation: each tree or building is sorted as one grounded object using one `depth_y`.
This correctly handles characters passing behind or in front of props on a single plane, but does
not model multiple walkable elevations, bridges, or per-part occlusion. Those cases need explicit Z
bands or split prop sprites and are not claimed as supported here.
