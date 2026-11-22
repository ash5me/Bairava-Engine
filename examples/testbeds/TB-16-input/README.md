# TB-16 Input Laboratory

TB-16 displays the engine's keyboard, mouse, gamepad, and semantic-action state while running
startup fixtures for input edges, remapping, gamepad disconnect/reconnect, and action-buffer timing.

## Run a bounded test

```powershell
zig build run-tb16 -- --frames 360
```

The test writes `TB-16-input-results.json` beside the executable. The report includes fixture
checks and observed input event counts. Use `--help` to see the available command-line option.

## Controls

- Tab or Left/Right: change pages.
- F: arm a Confirm action remap, then press a supported control to bind it. The left mouse button
  is excluded to avoid binding a click on the UI. The new binding is saved through the engine
  settings API.
- R: pause/resume action-buffer aging.
- Up/Down: change the action-buffer window.
- Escape: exit.

Connect or disconnect a gamepad while the test runs to inspect its supported buttons, axes, and
connection generation. The actions page shows current bindings and the Confirm buffer state.

## Coverage limits

The startup fixtures apply synthetic events to the public input state and verify press/release
edges, remapping, stale gamepad-generation rejection, fixed-tick buffer expiry during catch-up
updates, and paused buffer aging. They do not emulate OS window focus changes or measure
physical-device latency. The current public input event API has no focus gained/lost event, and
touch input is not implemented, so those areas are explicitly not tested.
