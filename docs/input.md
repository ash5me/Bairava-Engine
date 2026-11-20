# Input and action mapping

Poll input through the `Context` passed to `update`. Bind physical controls to a game-owned enum so
gameplay responds to actions such as `jump` rather than to a particular key.

## Define defaults

The compile-checked [public API example](application-lifecycle.md) defines a typed action enum,
default key bindings, and an action map without requiring a window or graphics device.

`ActionMap` accepts keyboard, mouse, gamepad button, and gamepad-axis bindings. An action can have
up to four default bindings. Exceeding that limit is a programmer error; the settings reader reports
and drops excess configured bindings.

## Read input during update

- `held` stays true while any binding is down.
- `pressed` and `released` are one-update-step edges; do not expect an edge to persist into a later
  update.
- `value` returns a normalized strength, useful for analog sticks and triggers.
- Read the state during `update`; drawing is not the input-consumption phase.

The optional settings file can override defaults using `bairava.bindings`. Bindings are SDL-free
public values, so the same action can work across keyboard and gamepad controls.
