# Animation data

The engine parses and advances animation clips without SDL. The game supplies a named-clip
definition and chooses the clip to play; frame rectangles and timing remain data-driven.

## Version 1 format

Each frame rectangle is relative to the source texture region and measured in texels. Durations are
positive seconds.

```text
animation 1
clip idle_down loop
frame 0 0 16 32 0.12
clip walk_down loop
frame 0 0 16 32 0.12
frame 16 0 16 32 0.12
clip hit once
frame 32 0 16 32 0.08
frame 48 0 16 32 0.14
```

`clip` names may contain lowercase letters, digits, and underscores. Each clip must have at least
one frame. `loop` wraps to its first frame; `once` holds the last frame. Every `frame` line gives
`x y width height duration`; rectangles must be non-empty and fit entirely within the source region.
Blank lines and `#` comments are ignored. Unsupported versions, duplicate clip names, malformed or
non-positive frame durations, and out-of-bounds rectangles are rejected with parse errors.

`engine.animation.Library.parse` validates and owns the parsed definition; `find` returns stable
clip references until `deinit`. `engine.animation.Timeline` advances a selected clip using the
engine's fixed update delta and exposes the current frame and elapsed time. The runtime can inspect
both without advancing playback. Game-specific decisions about which clip name to select stay in
game code.

The sample warrior definition is [`assets/animations/warrior.anim`](../assets/animations/warrior.anim).
The game checks its frame rectangles against the warrior atlas region at startup, then uses the
timeline for idle, movement, and saved animation position. `zig build test` covers parsing,
rectangle bounds, looping metadata, variable frame durations, and deterministic advancement.
