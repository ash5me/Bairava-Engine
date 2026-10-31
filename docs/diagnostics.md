# Runtime diagnostics and the debug overlay

Status: P2.1. Development builds only. The overlay and its geometry are compiled out of release builds.

## Turning it on

Diagnostics are on by default in Debug builds and off in the other modes. Override the default with:

    zig build run -Ddev-tools=true     # on, in any mode
    zig build run -Ddev-tools=false    # off, in any mode

The build option is `build_options.dev_tools`, read through `src/engine/diagnostics/gate.zig`.

## Keys

| Key | Action |
|---|---|
| F2 | Open or close the developer command console |
| F3 | Show or hide the overlay |
| F4 | Turn all debug geometry on or off |

F4 has no effect in a release build, because the geometry switches are never read there.

## What the overlay shows

- Frame rate, the last frame time, and the worst frame in the recent window.
- Update and render time for the last frame.
- The active scene's name, the number of scenes opened, and whether a switch is pending.
- Sprites and draw calls, the zoom, the view size, and the camera position.
- Held and pressed key counts, and the mouse position in window points.
- Texture store counters: loaded, hits, misses, and failed loads.
- Shapes queued this frame, and shapes dropped because the list was full.
- The game's own lines (see below).
- Frame-time average, p95, and maximum over the retained sample window.

## Adding game lines

A game adds lines by declaring a method:

    pub fn debugText(self: *const Game, out: *engine.diagnostics.Text) void {
        out.print("player {d:.1}, {d:.1}", .{ self.player.x, self.player.y });
    }

The engine calls it once per frame, in development builds only. A line longer than
`engine.diagnostics.max_line_len` is cut; a line past the `max_lines` limit is counted in `dropped`.
The method must not change game state.

## Drawing debug geometry

Geometry is queued during `draw` and only while its switch is on. Check the switch first:

    if (dc.show.collision) engine.debug_geometry.drawSolid(map, dc.debug, dc.cam);
    if (dc.show.tiles) engine.debug_geometry.drawGrid(map, dc.debug, dc.cam);
    if (dc.show.entities) dc.debug.point(x, y, color);   // view pixels

`dc.debug` takes view-space shapes (`outline`, `fill`, `point`). Map world positions with
`dc.cam.screenX` and `dc.cam.screenY` first, as sprites are mapped. The camera bounds are drawn by the
engine when `dc.show.camera` is on.

The shape list holds `diagnostics.debug_draw.max_shapes` shapes per frame. Extra shapes are counted in
`dropped` and not drawn.

## Layering

- `src/engine/diagnostics/*.zig` (except `gate.zig`) and `src/engine/renderer/debug_geometry.zig` are
  pure. They import no SDL, no GPU, and no build options, so `zig build test` covers them.
- `gate.zig` is the only file in this group that reads the build options.
- Overlays read only the collector's published snapshot. They never reach into a subsystem.
- The scene host publishes the active scene's name through `sceneInfo()`. The runtime reads it.

## Cost

With diagnostics off, the runtime does not read the clock for timing, record samples, build the
snapshot, or create the overlay's font. Each per-frame call site is guarded by the gate, so the check
is a compile-time constant.
