# Logging and diagnostic error reporting

Status: P2.3.

## Levels

From least to most severe: `trace`, `debug`, `info`, `warn`, `error`. A message below the minimum level
is dropped before it is formatted. The minimum starts at `debug` in Debug builds and at `info` in the
other modes.

## Choosing the level in the settings file

    log_level = debug

Accepted values are `trace`, `debug`, `info`, `warn` (or `warning`), and `error`, in any case. A value
that is not a level name is logged and the default is kept. The setting is read at startup, before the
window opens, so startup messages honor it. Release builds use the same setting, so a shipped build can
log more when a tester sets it.

## Writing messages

    const log = engine.log.scoped("game");
    log.trace("per-step detail", .{});
    log.info("level loaded: {s}", .{name});

Each line carries a scope, which names the subsystem. Use the scope of the module that owns the work.

## Failures

Every failure says three things: the operation, the resource it was working on, and the error.

- `engine.log.recovered(scope, operation, resource, err, instead)` logs a warning, for a failure the
  caller continues past. The last argument says what happens instead. Example: a missing debug font
  logs that the overlay is off.
- `engine.log.fatal(scope, operation, resource, err)` logs an error, for a failure that stops the
  operation. The caller then returns the error.

Neither helper replaces the error. The caller still returns the typed Zig error it received, so
callers can still match on it.

## Startup failures

`Session.start` records the step it is on. If a step fails, the run logs one summary line naming the
subsystem and the operation:

    startup failed in the window subsystem while creating the window: WindowCreateFailed; anything opened before it was released

Startup failures are fatal: the run returns the error, and the caller decides the exit status. Cleanup
still happens in reverse order through `errdefer`, as `docs/ownership.md` describes. The unit tests
cover the stage names and the summary text. Testing the teardown itself needs a window and a GPU device,
so it is covered by review.

## Recoverable and fatal, in short

| Situation | Level | Stops the run? |
|---|---|---|
| Missing optional file (a sidecar, a font for the overlay) | debug or warn, via `recovered` | No |
| Asset that fails to load, where the game can fall back | warn, via `recovered` | No |
| Save that fails to write | error, via `fatal` | No, the game keeps running |
| Engine startup step fails | error, the summary line | Yes |
| Broken invariant | assertion panic (Debug, ReleaseSafe) | Yes |

## Log file

The log file (`Semkootru.log`, beside the executable) takes the same levels as the terminal. Every
line is flushed as it is written, so the file is complete even after a crash. Each run replaces the
previous file.

The C sink maps `trace` to `LOG_TRACE` in log.c, and it clamps any level outside 0 to 4.

## Crash reports

A panic writes a crash report beside the executable, as `Semkootru.crash.txt`, before Zig prints the stack
trace. The report holds the panic message, the frame number, the scene name, the mouse position in window
points, and the held keys. Each run removes the report left by the run before it, at startup, so a report
always belongs to the run that wrote it. The stack trace goes to the terminal only.

The frame loop records the frame, scene, and input once per frame with a few stores. That happens in every
build, so a release crash has the same context as a debug one.

The game sets the report file name with `crash_file` in its config. Null writes no report, and the log
still records the panic.

## Not done

- No log rotation, and no logs kept from earlier runs. Both are listed as open items in the README.
- No third-party logging framework.
