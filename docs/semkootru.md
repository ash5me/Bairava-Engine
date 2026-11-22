# Semkootru sample game

Semkootru is the data-driven game included with the Bairava Engine repository. This guide covers how to launch it and its game-specific controls, settings, and save files. For the engine API and subsystem behavior, see the [documentation index](README.md).

## Run

From the repository root:

```sh
zig build
zig build run
```

The executable is installed as `zig-out/bin/Semkootru`. Runtime assets are staged under `zig-out/bin/assets/`.

## Controls

| Input | Action |
|---|---|
| Arrow keys or `W A S D` | Move |
| `Esc` | Quit |
| `F8` | Toggle the game menu |
| `F11` | Toggle fullscreen |
| `F3` | Toggle the debug overlay |
| `I` | Toggle integer/fit scaling |
| `+`, `=`, or keypad `+` | Zoom in |
| `-` or keypad `-` | Zoom out |
| `0` | Reset zoom |
| `F5` | Save to the selected slot |
| `F9` | Load from the selected slot |
| `Tab` | Select the next save slot |
| Left mouse button | Interact with UI controls |

Bindings are action-based. Defaults are defined in `src/game/controls.zig`.

## Settings

At startup, the game reads `settings.txt` beside the executable. The repository-root `settings.txt` is the sample configuration; copy it beside the executable to customize resolution, fullscreen, vsync, and input bindings. Changes take effect the next time the game starts.

```text
resolution = 960x540
fullscreen = false
vsync = true
bind move_left = a, left, pad_dpad_left, pad_left_x-
```

Each `bind` line replaces the default bindings for that action. The supported action and key names are listed in the comments in `settings.txt`.

## Saves and diagnostics

Save files are stored beside the executable:

- Slot 1: `save.json`
- Slot 2: `save2.json`
- Slot 3: `save3.json`

Save data is versioned JSON; unsupported newer versions are not silently overwritten. Logs and crash reports are also written beside the executable.

## Related source

- `src/game/config.zig` — window, native resolution, camera, scale, and asset settings
- `src/game/controls.zig` — actions and default input bindings
- `src/game/game.zig` — game setup and scene integration
