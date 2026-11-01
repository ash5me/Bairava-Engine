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
results. Let it run past its 60-frame warm-up and the 120 frames it summarizes, then record average, p95, and worst frame
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

The benchmark also logs that summary itself, under the `benchmark` log scope, once the warm-up and 120 frames are recorded. The benchmark turns on `Config.gpu_timing`, so it logs the GPU summary too, and it logs the spike count with it. Its frame figures therefore include the GPU wait. It runs only in development builds, where the frame times are kept, so a release build logs nothing.

The overlay shows a strip of allocations per frame and a line of per-frame plot values. The plots are sprites queued, draw calls made last frame, allocations requested so far this frame across every scope, and bytes requested. Each plot keeps the same 120-frame window as the frame graph, so its average and p95 are over those frames. Allocation counts restart at the start of each frame, while the totals in the memory line keep counting from startup.

`-Dtracy=true` also sends those four plots to Tracy, and it draws them beside the zones. The plot calls use Tracy's C entry point `___tracy_emit_plot`. If a Tracy build fails to link on that name, check the Tracy headers in the vendored tree.

GPU time is measured only when `Config.gpu_timing` is set, and the benchmark sets it. The engine then submits each frame and waits on a fence until the GPU finishes it. That wait is the `gpu` phase, it is the last part of `present`, and it is sent to Tracy as the `gpu ms` plot. The pass zones still measure only the CPU's recording work. SDL's GPU API, as this engine uses it, does not appear to expose timestamp queries, so the figure covers the whole frame and not each pass. Confirm this against the pinned SDL version before relying on it.

The wait stalls the CPU, so with `gpu_timing` on the CPU and GPU work add up. Those frame times measure a cost, not a rate to play at, and they should not be compared with a run that leaves the option off.

A frame longer than two 60 Hz budgets (33 ms) is a spike. The overlay shows how many have happened since startup, and the latest one with its frame count and the phase that took most of that frame. Spikes are recorded only in development builds.
