# Deterministic input replay and state checkpoints

The fixed-step loop gives every simulation update the same `dt`. `engine.replay.Log` records the input snapshot seen by
each update and reapplies those snapshots without consulting platform input. The game owns the log and chooses where to
record or play it:

```zig
var recording = engine.replay.Log.init(ctx.allocators.game);
defer recording.deinit();

// At the top of the game's fixed-step update:
try recording.recordInput(ctx.simulation_tick, ctx.input);
```

For playback, replace live input immediately before the update:

```zig
const replay_tick = try recording.applyNextInput(ctx.input);
std.debug.assert(replay_tick == ctx.simulation_tick);
```

`recordInput` requires consecutive ticks. `seek` positions the playback cursor at an exact recorded tick, and `rewind`
restarts it. A replayed input includes held keys, key press/release edges, mouse state and position, gamepad identities,
axes, held controls, and gamepad edges. Platform events are not replayed; gameplay should use the recorded input snapshot
and deterministic simulation state rather than live device state.

The engine cannot serialize arbitrary game state, so games provide their own stable snapshot representation:

```zig
const state_bytes = try game.serialize(ctx.allocators.frame);
// After update tick N, record a checkpoint for the next update boundary N + 1.
_ = try recording.recordState(ctx.simulation_tick + 1, state_bytes);

var restored: [4096]u8 = undefined;
const checkpoint = try recording.restoreStateAtOrBefore(target_tick, &restored);
try game.deserialize(restored[0..checkpoint.byte_count]);
try recording.seek(checkpoint.tick);
```

After restoring, advance by repeatedly applying `applyNextInput` and running one fixed update, until the desired tick.

`Context.simulation_tick` is a zero-based fixed-update index. `recordInput` records the snapshot visible during that
update. A checkpoint's tick denotes the next update boundary to run; record the initial state at tick zero and record
the state after update N at tick N + 1. Checkpoints are copied into the log and carry a checksum. The nearest checkpoint
at or before a target tick can be restored; `restoreStateAtOrBefore` checks the checksum and output capacity. Snapshots
must be recorded in increasing tick order. Use the same game version, initial content, fixed update rate, and
deterministic random seeds for a meaningful replay. The log is currently an in-memory runtime facility; persistence and
cross-version compatibility are the game's responsibility.

Replays do not make nondeterministic game code deterministic by themselves. Simulation must avoid wall-clock reads,
unordered iteration, and unseeded randomness, and must define how external events are handled.
