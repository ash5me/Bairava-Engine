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

## Skeleton data, version 1

A skeleton is a hierarchy of bones with sprites attached to them, and animations that key each bone's position,
rotation, and scale. Like clip data, it is text that starts with a version header. `engine.animation.skeleton.Data.parse`
validates it against the size of its source region before any of it is used, and `deinit` releases the result.

```text
skeleton 1
bone root - 0 0 0 1
bone torso root 0 -12 0 1
bone arm torso 4 0 0 1
attach torso 0 0 16 16 0 0 8 8
attach arm 16 0 8 4 0 0 0 2
anim swing loop 1
event 0.25 footstep
key arm rotate 0 0
key arm rotate 0.5 0.5
key arm rotate 1 0
key torso translate 0 0 0
key torso translate 0.5 0 -1
key torso translate 1 0 0
```

Fields are separated by spaces or tabs. Blank lines and lines that start with `#` are ignored. Readers reject any other
version.

`bone NAME PARENT X Y ROTATION SCALE` declares a bone. The first bone is the root, and its parent is `-`. Every other
bone names an earlier bone as its parent. Position is relative to the parent, rotation is in radians and turns clockwise
on screen, and scale is a uniform factor greater than zero. A skeleton holds at most 64 bones.

`attach BONE X Y W H OFFSET_X OFFSET_Y PIVOT_X PIVOT_Y` draws one sprite on a bone. X, Y, W, and H give its rectangle in
texels, relative to the source region, and the rectangle must lie inside that region. The offset places the pivot in the
bone's space. The pivot is the point inside the sprite that sits on that spot, and the sprite turns around it, so it must
lie inside the rectangle. Attachments draw in the order they are listed.

`anim NAME loop|once LENGTH` starts an animation whose length is in seconds. Every `bone` and `attach` line comes before
the first `anim`.

`event TIME NAME` adds a marker to the current animation. Event times must be in increasing order and lie from zero
through the animation length. Names use lowercase letters, digits, and underscores.

`key BONE rotate|scale TIME VALUE` and `key BONE translate TIME X Y` add keys. A rotate or scale key replaces the bone's
rotation or scale, and a translate key replaces its position. The keys of one property on one bone must be listed
together, in increasing time order, and they must lie within the animation's length. A bone and property that appears
again after another track in the same animation is an error. A scale key must be greater than zero.

Evaluation is in `engine.animation.skeleton.evaluate(&data, animation, time, &pose)`. It writes every bone's world
transform to a `Pose` without allocating. Keys interpolate linearly. A looping animation wraps its time, and between its
last key and its first key it interpolates across the wrap. A one-shot holds its first key until that key's time, and
its last key after the end. A property with no keys keeps its rest value. A child is placed in its parent's rotated and
scaled space, and it inherits the parent's rotation and scale.

`skeleton.Player` plays one animation. It holds a pointer to the data, the animation, and a time, and it offers `init`,
`play`, `update(dt)`, `finished`, and `pose`. `pollEvent()` returns crossed event markers in playback order. Up to 16
events wait in its queue; excess events are dropped and counted in `dropped`. A looping clip emits a marker again each
time playback crosses it.

Root translation on bone 0 is extracted as motion. `rootMotionDelta()` returns the displacement from the most recent
update, including loop wraps; apply it to the owning entity. Use `poseWithoutRootMotion()` when drawing that entity, so
the root's accumulated translation is not applied a second time. The player points into the data, so the data must
outlive it.

`skeleton.BlendTree` blends a sorted set of `BlendNode { threshold, animation }` entries as a one-dimensional blend
space. `BlendTree.init(&data, &nodes)` rejects empty trees, non-finite or unordered thresholds, invalid durations, and
animations from another data set. `tree.evaluate(parameter, phase, &pose)` clamps the parameter to the endpoint clips
or interpolates between the adjacent clips; `phase` is normalized time from zero to one and each clip is sampled at the
same phase. Bone positions and scales are linear blends, and rotations use the shortest angular path. This API is
allocation-free; the caller owns the node array and advances the normalized phase.

`skeleton.place(bone, attachment)` returns one attachment's rectangle, origin, and rotation in the pose's pixels. The
renderer's `engine.skeleton_draw.drawPose(batch, texture, data, pose, sheet_x, sheet_y, x, y, tint, alpha)` queues every
attachment through `SpriteBatch.drawSprite`. The pivot stays on its bone, and the sprite turns with the bone.

Version 1 has these limits. Keys interpolate linearly, and scale is uniform. Blend trees are one-dimensional; the
caller advances their normalized phase. Root motion is extracted from the first bone's translation track. There is no
inverse kinematics. Attachments have no tint, flip, or draw order of their own, so they draw in file order. The warrior
and the sample game do not use skeletons yet.
