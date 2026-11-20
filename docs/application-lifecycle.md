# Application lifecycle

Game code imports the `bairava` module and gives `bairava.run` a game type and a `bairava.Config`.
The engine validates configuration before opening platform resources, creates the context, calls the
game's `init`, and then repeats fixed-step `update` and per-frame `draw` until the game stops.

## Compile-checked public API example

This headless example is compiled and run by `zig build test`; the normal `zig build` also compiles
the public-API sample game.

<!-- include-code: examples/api_basics.zig -->

## Lifetime and failure behavior

- The allocator in `Config` must outlive the complete `run` call.
- A successful game `init` is paired with game teardown before GPU and platform teardown.
- If game `init` returns an error, game teardown is not called. Release resources acquired before
  the failing operation inside `init`.
- The context passed to `init` and `update` is borrowed for that call. Do not retain it.
- Updates use the configured fixed frequency. Drawing happens once per presented frame and is not
  a fixed-step callback.

`Config.validate` can be used to report invalid values before calling `run`. Startup errors are
returned to the caller; a clean stop returns normally. The `run` contract is also summarized in the
[public API reference](../api/).

## Run the sample game

From the repository root, `zig build run-sample` builds and launches the scene sample. It uses the
public API and requires a display and a supported SDL_GPU device.
