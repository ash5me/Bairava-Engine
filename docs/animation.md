# Animation data

The engine parses and advances animation clips without SDL. A clip is a row of frames with durations. The
animation machine chooses which clip plays, from parameters the game sets each update. Frame rectangles,
timing, and the choice of clip are data, so gameplay code only says what the entity is doing.

## Clip format, version 1

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
clip references until `deinit`, and `indexOf` returns the clip's index.

## Animation machine, version 1

The machine is text too. It names parameters, states, the clips each state can play, transitions between
states, and frame events. A parameter is an integer that the game sets. A `trigger` parameter is cleared
when a transition that tests it fires, so it acts once.

```text
machine 1
param moving
param facing
param hurt trigger
state idle
clip idle_down when facing == 0
clip idle_up when facing == 2
state walk
clip walk_down when facing == 0
clip walk_up when facing == 2
event walk 1 footstep
state hit
clip hit_down
start idle
transition idle -> walk when moving == 1 blend 0.1 event started_walking
transition walk -> idle when moving == 0 blend 0.1
transition * -> hit when hurt
```

- A state plays its first clip variant whose condition holds. If none holds, it plays its first variant.
  A variant with no `when` always holds. A state holds up to four variants.
- A condition is `param OP value`, where OP is `==`, `!=`, `<`, `<=`, `>`, or `>=`. A bare `param` means
  `param != 0`. Join conditions with `and`; a clause holds up to four.
- A transition is `transition FROM -> TO`, with optional `when`, `blend SECONDS`, and `event NAME`, in
  that order. `FROM` may be `*`, which matches any state. Transitions are tried in the order written, and
  at most one fires per update. A transition into the current state never fires.
- `blend` crossfades the clip being left over the given seconds. A transition with no blend switches at once.
  Variant changes inside a state never blend; they restart the clip.
- `event STATE FRAME NAME` emits NAME when playback reaches FRAME in that state. Frame events fire as
  playback passes a frame, so a clip that starts on a frame does not emit that frame's event until it wraps
  or moves past it. An update that passes a whole loop of a short clip may emit fewer events than the frames
  it passed.
- The start state is the first state, unless a `start` line names another.
- `machine.stateName()`, `clipName()`, `clipTime()`, and `frameIndex()` report the current position.
- `machine.pose()` returns the frame to draw. While a blend runs it also returns the frame of the clip
  being left, and the weight of the current frame. Draw the old frame fully, then the new one at its weight.
- `machine.pollEvent()` returns queued events, oldest first. Sixteen events can wait; more are dropped
  and counted in `dropped`.
- `machine.restore(library, elapsed)` settles the state from the current parameters, seeks the clip, and
  blends nothing and queues no events. Games use it when loading a save.

`engine.animation.MachineDefinition.parse` checks the text against a library. Unknown clips, parameters,
and states, malformed lines, and too many items are parse errors. The definition copies its text, so the
library may be replaced without invalidating it, but the clip indices must still match that library.

## The warrior

The sample warrior's clips are in [`assets/animations/warrior.anim`](../assets/animations/warrior.anim), and
its machine is [`assets/animations/warrior.machine`](../assets/animations/warrior.machine). The machine has
`moving` and `facing` parameters, with facing 0 down, 1 right, 2 up, and 3 left, so it chooses the idle or walk
clip for each direction. The game sets those two parameters each update and does not name clips. It checks the
frame rectangles against the warrior atlas region at startup, and the machine checks its clip names when it loads.

`zig build test` covers parsing, rectangle bounds, looping metadata, variable frame durations, deterministic
advancement, machine transitions, blending, variants, triggers, events, and restore.
