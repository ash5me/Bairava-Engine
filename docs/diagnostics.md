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
- Held and pressed key counts, the names of the held keys, the held actions the game's bindings resolve, and the mouse position in window points.
- Texture store counters: loaded, hits, misses, and failed loads.
- Requested live and peak bytes for the engine, game, asset, and frame allocator scopes.
- The game-published entity count.
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

## Held keys and actions

The overlay's input lines name the keys held now, and the actions they resolve to. The engine names keys by their `Key` names. A game names its actions by declaring a method, which the engine calls once per frame in development builds, with the same rules as `debugText`:

    pub fn debugActions(self: *const Game, input: *const engine.Input, out: *engine.diagnostics.NameList) void {
        self.bindings.addHeldNames(input, out);
    }

A name list keeps 72 bytes of joined names. Names past that are counted and shown as `+N`.

## Audio state

The `audio` console command prints whether a playback device is open and its sample rate and channel count, the busy and maximum voice counts, the master gain, and the first three busy voices. Each voice line gives whether it loops, its own gain, and the length of its sound in bytes. Sounds do not keep their names yet, so voices are listed by slot.

## Inspecting entities and components

The `entities` console command lists the entity count and the names/IDs of published snapshots.
Use `entities <id>` to inspect a selected entity's component values. For example:

    entities
    entities 1

Games publish snapshots through `Context.diagnostics.publishEntities`. Inputs are copied into
bounded diagnostic storage; no pointers or mutable component storage are retained, and the console
reads only those copies. Snapshots are refreshed by the game during update and are capped at 16
entities and four named component values per entity. When a game publishes only a subset, the omitted
entity count is reported. Capacity violations and values that exceed the fixed text capacities are
rejected rather than truncated. The inspector is diagnostic data, not a way to mutate live entities.
The sample game publishes the player's transform, facing, animation, and collision box.

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

## Memory accounting

The `memory` console command reports allocation and free calls, failed allocations, live requested
bytes, request high-water marks, and arena capacity for each scope. The overlay shows live/peak
requested bytes and arena capacity in KiB. Requested bytes are not GPU memory usage; arena capacity
is the backing storage retained by the arena and can exceed the currently live requests. Frame live
counts reset when the frame arena resets; its allocation and peak counters remain cumulative for the
run.

At shutdown, development builds log outstanding counts and requested bytes after the game and engine
resources have been released. These are allocations retained by an arena until its teardown, not
proof of an individual leak: the game and asset arenas intentionally keep their allocations for the
run, and the asset arena currently releases its memory at shutdown. The allocator tests use
`std.testing.allocator` as the parent, which checks that the arenas themselves release their backing
allocations.

## Layering

- `src/engine/diagnostics/*.zig` (except `gate.zig`) and `src/engine/renderer/debug_geometry.zig` are
  pure. They import no SDL, no GPU, and no build options, so `zig build test` covers them.
- `gate.zig` is the only file in this group that reads the build options.
- Overlays read only the collector's published snapshot. They never reach into a subsystem.
- The scene host publishes the active scene's name through `sceneInfo()`. The runtime reads it.

## Cost

With diagnostics off, the runtime does not read the clock for timing, record samples, track arena
allocations, build the snapshot, or create the overlay's font. Each per-frame call site is guarded by
the gate, so the check is a compile-time constant.
