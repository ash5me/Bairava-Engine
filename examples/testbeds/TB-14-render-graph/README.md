# TB-14 Render Graph Validation

The current render graph is an internal, pure planner. It compiles pass/resource declarations into
a deterministic pass order and assigns transient resource slots by lifetime. Post-processing uses
the planner for its fixed effect chain and owns two GPU targets; it does not expose user-authored
passes, target assignment, or a pass-failure injection hook.

## Run planner validation

```powershell
zig build run-tb14 -- --iterations 1000
```

Each iteration rebuilds and compiles these fixtures:

- A four-pass image chain, verifying dependency order and two-slot reuse.
- A reader declared before its writer, verifying the writer is scheduled first.
- Two outputs whose lifetimes overlap, verifying they receive distinct slots.
- Invalid fixtures for missing writers, multiple writers, external writes, a dependency cycle,
  and a pass that reads its own output.

The runner reports the total checks, failures, stable-plan fingerprint, and an explicit
`unavailable_in_graph_planner` status for runtime resize and failed-pass recovery. A passing result
only covers the planner fixtures; it does not imply GPU target recreation or pass execution was
tested. Those require an engine-level test hook or a public post-chain diagnostics surface.

## Current coverage boundaries

- The planner has no size, target-allocation, or execution state, so this testbed cannot observe
  real target resize/recreation.
- `post.Chain.run` has no recoverable pass error result or injection API. This runner validates
  compile-time declaration failures but does not claim GPU pass-failure recovery.
- The engine's existing renderer/post-processing tests remain necessary for GPU-backed behavior.
