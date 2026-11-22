# TB-12 Long-Running Simulation

TB-12 runs a seeded fixed-step workload with moving/animated entities, scheduled events, recurring
scene overlays, entity generation reuse, transient texture loading, worker jobs, audio playback,
changing UI text, and periodic resource snapshots.

## Run a smoke test

```powershell
zig build run-tb12 -- --ticks 1200 --snapshot-interval 300
```

The bounded run writes `TB-12-long-run-results.json` beside the executable and logs each resource
snapshot. The report includes periodic history endpoints and min/max entity, texture, and game-memory
measurements. Job checksums and stale entity handles are verified during the run.

## Run the initial long campaign

At 60 fixed updates per second, 30 minutes is approximately 108,000 simulation ticks:

```powershell
zig build run-tb12 -- --ticks 108000 --snapshot-interval 3600 --entities 256 --seed 0x12B011E7
```

Use `--ticks 216000` for an approximately 60-minute campaign. Long campaigns should run on the
target machine and renderer; the testbed does not claim that a smoke run establishes long-term
stability. Replay failures with TB-23 using the reported seed and first divergent tick.

## Options

- `--ticks N`: bounded fixed-update duration; default 3600.
- `--entities N`: steady-state entity population, 1–3000; default 256.
- `--snapshot-interval N`: simulation ticks between resource snapshots; default 600.
- `--seed N`: nonzero deterministic workload seed; default `0x12B011E7`.
- `--help`: print options and exit.

Escape exits early. An early exit is reported as incomplete. A full campaign result should be
reviewed with the periodic log snapshots and allocator/resource trend data, not only the final
pass/incomplete field.
