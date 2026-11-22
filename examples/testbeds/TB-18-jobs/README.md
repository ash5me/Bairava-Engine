# TB-18 Job System Laboratory

TB-18 is a bounded command-line testbed for the engine's worker pool. It submits a configurable
batch containing small and larger CPU jobs, validates each returned checksum after the counter
wait, and reports worker count, peak concurrent jobs, and process CPU time.

## Run

```powershell
zig build run-tb18
```

The program prints one JSON result object and returns a failing exit code if any fixture fails.
Workload size can be changed without rebuilding:

```powershell
zig build run-tb18 -- --workers 4 --queue 256 --jobs 128 --iterations 200000
```

Bounds are 0–32 workers, 1–4096 queued jobs, 1–1,000,000 jobs, and at most 100,000,000
`jobs * iterations`; every eighth job performs four times the base iterations. `--workers 0`
executes the batch on the submitting thread. CPU time is process CPU time, not elapsed wall time.

## Fixtures and limits

The startup checks exercise a full one-slot queue and verify that overflow executes inline, nested
jobs that submit children and wait without deadlocking, a pool shutdown with running and queued
work, and an error result returned through job-owned data. Job functions only access their own
inputs/results and atomic counters; they do not touch the renderer, logger, asset arenas, or game
state. Errors are values written by a job and checked after synchronization; the pool has no
exception or cancellation API. Cancellation is not tested because it is not supported.

The platform's job-worker implementation still requires target-platform validation; the repository
job tests and this lab exercise the current host's threading path.
