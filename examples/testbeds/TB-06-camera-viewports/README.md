# TB-06 Camera and Viewport Test

Purpose: exercise public camera follow and viewport behavior under deterministic target motion,
window resizing, zoom changes, and presentation scaling.

## Run

```sh
zig build run-tb06 -- --frames 180
```

`--frames` selects when the metrics summary is written; the scene remains interactive until
Escape. Resize the window during a run to exercise viewport and drawable-size changes.

Controls:

- `+` / `-` and `0`: zoom in/out and reset zoom.
- `I`: switch between fit and integer scaling.
- `Tab`: toggle camera dead-zone, look-ahead, and keep-inside constraints.
- `F`: toggle smooth follow.
- `Space`: add draw-only camera shake.
- `F4`: toggle camera/dead-zone debug outlines.
- `Escape`: quit.

The workload follows a moving target through a large bounded world, draws off-screen landmarks,
and applies a vignette post effect. It checks camera bounds and window-to-world pointer coordinate
round trips, and reports viewport/drawable dimensions, pixel density, zoom, conversion error,
off-screen landmarks, and frame-time average/p95. Results are written to
`TB-06-camera-viewport-results.json` beside the executable.

## Capability limits

The current public runtime exposes one gameplay camera and one view per frame. Split-screen and
multiple simultaneous camera views are not supported and are recorded as a capability gap in the
results. The runtime manages render-target recreation on resize; high-DPI behavior should be
verified on a display whose window-pixel density is greater than one.
