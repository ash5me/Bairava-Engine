# TB-23 Deterministic Input Replay and Checkpoints

Run the headless replay validation:

```sh
zig build run-tb23
```

The scenario records one input snapshot per 60 Hz simulation tick, using a fixed seed. It then
round-trips the recording through the versioned replay codec and replays the same stream under
30, 60, and 120 Hz render schedules. Each simulation tick is checked against its live-run state
hash, and serialized state checkpoints are restored and compared every 30 ticks.

The executable prints per-rate results and a final JSON summary. Any metadata, tick, or checkpoint
mismatch exits with an error. Format incompatibility, malformed input, truncation, and corrupted
checkpoint payloads are also covered by automated unit tests.

Replay logs are diagnostic recordings, not save files. They contain format version, simulation
seed, fixed update rate, per-tick input snapshots, and caller-serialized state checkpoints. The
engine does not migrate old replay versions or interpret game checkpoint bytes.
