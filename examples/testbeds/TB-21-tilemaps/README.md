# TB-21 Tilemap Validation and Stress

Purpose: exercise deterministic map parsing, visible tile submission, layer order, animation,
tile collision coordinates, and repeated map replacement.

## Run

```sh
zig build run-tb21 -- --cols 40 --rows 24 --hz 60 --frames 180
zig build run-tb21 -- --cols 128 --rows 96 --hz 60 --frames 180
zig build run-tb21 -- --cols 512 --rows 256 --hz 120 --frames 180
```

Supported dimensions are 40-512 columns and 24-256 rows. `--hz` accepts 30, 60, or 120 and
sets the simulation update rate. `--frames` selects when the summary is written; the scene remains
open until Escape.

Controls:

- WASD or arrow keys: move the camera target across the map.
- `+` / `-` and `0`: zoom in/out and reset zoom.
- `Q` / `E`: toggle decoration/foreground layers.
- `R`: replace and release the generated map.
- `Escape`: quit.

Generated maps have a dense ground layer, sparse decoration/foreground layers, deterministic solid
and one-way cells, and a 6 Hz animated decoration tile driven by simulation ticks. The workload
records visible and submitted tiles, culled tiles, map memory, collision-reference parity, reload
count, and frame-time average/p95. Results are written to `TB-21-tilemap-results.json` beside the
executable.

Map replacement allocates and parses the new map before releasing the old one; repeated `R`
presses exercise unload/reload without leaving old tile storage live.

The renderer's documented one-tile draw margin is included in submitted counts. Split-screen,
animated tile assets/metadata, and asynchronous map streaming are outside the current tilemap API.
