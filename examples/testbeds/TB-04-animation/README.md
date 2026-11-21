# TB-04 Animation Stress Test

Purpose: exercise clip selection, animation machines, frame playback, transitions, blend windows,
and authored events across a configurable population.

## Run

```sh
zig build run-tb04 -- --count 100 --frames 180
zig build run-tb04 -- --count 500 --frames 180
zig build run-tb04 -- --count 1000 --frames 180
```

Supported counts are `100`, `500`, and `1000`. `--frames` selects when the metrics summary is
written; the window remains open until Escape. Press Space to pause/resume and R to restart the
machines.

Metrics include transitions, active blend evaluations, authored events, and dropped event counts.
The run writes `TB-04-animation-results.json` beside the executable.

## Known limitations

- The visual stress scene uses sprite animation machines and crossfades. Skeletal hierarchies,
  blend trees, root motion, and hook lifecycle are covered by the headless animation unit tests,
  but are not yet part of this visual scene.
- The runtime uses the current update timestep; a separate frame-rate comparison harness is not
  included.
- Reference screenshots are not captured automatically.
