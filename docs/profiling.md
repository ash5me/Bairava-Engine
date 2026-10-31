# Profiling and repeatable workload

Development builds retain 120 frame samples per phase. The diagnostics overlay reports average,
nearest-rank p95, and worst frame time; `performance` in the F2 console prints the same summaries
with update, draw, and present phase averages. Timed phases are frame, event processing, asset
watcher polling, fixed update, audio maintenance, world draw/submission, and presentation. Asset
reload work performed inside the game's update remains part of update timing.

Run the deterministic rendering workload with:

```text
zig build run-benchmark
```

It draws 1,000 tinted sprites, in a fixed 40-by-25 grid, from one 4x4 texture at a 320x180 native
view. The workload and texture are the same each run; it has no random state or dynamic entity
spawning. Use the same build mode, resolution, vsync setting, and graphics backend when comparing
results. Let it run for at least 120 frames after startup, then record average, p95, and worst frame
times along with the individual phase averages. F3 toggles the overlay; F2 opens the console, where
`performance` prints the current summary; Escape quits.

The measurements are deliberately runtime-local and are not uploaded. No machine-independent
baseline is committed because results depend on hardware, drivers, window compositor, and vsync.
Record the machine/OS, CPU/GPU, Zig version, build mode, backend, and workload count beside any
captured measurements. The overlay's counters include sprites/draw submissions, the game's
published entity count, texture-cache counts/estimated bytes, and gameplay-published collision
query calls.

`-Dtracy=true` additionally enables Tracy zones for function-level investigation. Compare the
repeatable workload first and use those zones to locate a measured bottleneck before changing data
layouts or caches.
