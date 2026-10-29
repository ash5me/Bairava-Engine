# Bairava Engine

Bairava is an early-stage 2D pixel-art game engine and a small playable demo, written in Zig. The demo opens a 320 × 180 native-resolution view, draws a layered tile map and an animated character, and lets the camera follow the player. SDL3's GPU API handles rendering; shaders are written in Slang and compiled to SPIR-V at build time.

The project is a prototype, not a production-ready engine. The core rendering and game loop are connected, while several reusable systems are still foundations rather than finished game features.

## What works today

- Fixed-rate game updates with frame-interpolated drawing.
- Nearest-neighbor pixel-art scaling, fit and integer scale modes, camera follow, zoom, and view/world coordinate conversion.
- Batched sprites and a texture atlas generated during the build.
- A cross-platform checkerboard-background keyer for source images (`zig build asset-keyer`).
- A cross-platform sprite importer that copies images into the project, registers them in the atlas manifest, and validates image readability (`zig build asset-import`).
- Versioned JSON save/load for player movement components and game/display progress, using Parson (`F5` saves, `F9` loads).
- A text tile-map format with ground, decoration, and foreground layers; tile collision and a spawn point.
- Directional player animation and movement with sliding against solid tiles.
- Keyboard and mouse input, configurable key bindings, and window settings.
- A small immediate-mode UI demo, a frame-time debug overlay, structured logs, and optional Tracy profiling.
- Engine modules for audio playback, asset caching, and entity storage. These are not yet integrated into the demo's gameplay.

There is no level editor, scene/state system, save/load system, or game-specific audio. The importer handles sprite images only; it does not import audio or fonts. The player is still implemented directly as a game struct rather than using the entity world.

## Requirements

- Zig `0.16.0-dev.3142+5ccfeb926` or a compatible version. This is the minimum pinned in `build.zig.zon`.
- `slangc` on `PATH` to compile shaders.
- A GPU driver supported by SDL3. The default build embeds SPIR-V and requests Vulkan; `-Ddxil=true` also builds DXIL for Direct3D 12, and `-Dmetal=true` builds MSL for Metal.
- Network access on the first build if Zig needs to fetch the SDL3 and ztracy dependencies. Zig caches fetched dependencies for later builds.

The repository includes the stb headers and cglm sources needed by the build. Tracy's viewer is only needed when using Tracy profiling; profiling support is disabled by default.

## Build and run

Run these commands from the repository root:

```sh
zig build
zig build run
zig build run -Dgpu-debug=true
zig build run -Ddxil=true
zig build run -Dtracy=true
zig build test
```

`zig build` compiles the executable and shaders, packs the sprites, and installs the game and runtime assets under `zig-out/bin/`. Run the game from the build step or launch `zig-out/bin/Semkootru` directly. Shaders are embedded in the executable; the atlas and game assets are installed beside it.

Build options:

| Option | Effect |
| --- | --- |
| `-Dgpu-debug=true` | Enable SDL GPU validation. |
| `-Ddxil=true` | Compile and embed DXIL shaders in addition to SPIR-V. |
| `-Dmetal=true` | Compile and embed MSL shaders, and let SDL select Metal when available. |
| `-Dtracy=true` | Enable Tracy profiling zones. Connect a compatible Tracy viewer to inspect them. |

`zig build test` runs the Zig unit-test suite. It does not open a window or create a GPU device, but it links SDL and builds the shaders, so `slangc` is still required. The standalone C UI test programs in `tests/ui/` are not part of that build step; compile them with a C compiler using the source and include paths shown below, then pass a TrueType font file when running them:

```sh
zig cc -std=c99 -Wall -Wextra -Ivendor -Isrc/engine/ui tests/ui/test_imgui.c src/engine/ui/imgui.c src/engine/ui/text.c vendor/stb_truetype_impl.c -o test_imgui
./test_imgui assets/font.ttf
zig cc -std=c99 -Wall -Wextra -Ivendor -Isrc/engine/ui tests/ui/test_text.c src/engine/ui/text.c vendor/stb_truetype_impl.c -o test_text
./test_text assets/font.ttf
```

On Windows, use `.exe` output names and invoke them with `.\test_imgui.exe` and `.\test_text.exe`.

## Controls

| Input | Action |
| --- | --- |
| Arrow keys or W, A, S, D | Move |
| Esc | Quit |
| F11 | Toggle fullscreen |
| F3 | Show or hide the debug overlay |
| I | Toggle fit/integer scaling |
| `=` or keypad `+` | Zoom in |
| `-` or keypad `-` | Zoom out |
| `0` | Reset zoom |
| Left mouse button | Use the demo panel's button and slider |

The controls are defaults and can be changed in `settings.txt`.

## Settings

At startup the game reads `settings.txt` beside the executable. The repository-root `settings.txt` is a template; copy it to `zig-out/bin/settings.txt` to change settings for a built game. Missing or invalid settings fall back to defaults, with invalid values reported in the log.

```ini
resolution = 960x540
fullscreen = false
vsync = true
bind move_left = left, a
```

Window dimensions must be from 64 to 8192 pixels. Boolean values accept `true`/`false`, `yes`/`no`, and `on`/`off`. A `bind` line replaces the defaults for one named action and can list up to four comma-separated key names. Valid action names are `move_left`, `move_right`, `move_up`, `move_down`, `quit`, `toggle_scale`, `zoom_in`, `zoom_out`, and `zoom_reset`. Key names are the SDL key enum names used in `src/engine/input.zig`.

## Project layout

```text
build.zig                 Build graph, shader compilation, atlas packing, run and test steps
build.zig.zon             Zig version and pinned package dependencies
assets/                   Sprites, font, sound sample, and demo map
shaders/                  Slang shader source
src/main.zig              Entry point and engine/game wiring
src/engine/                Rendering, loop, input, camera, assets, audio, UI, and utilities
src/engine/ui/             C text and immediate-mode widget implementation
src/game/                  Demo game, player, level, controls, and configuration
src/tests.zig              Zig unit-test root
tests/ui/                  Standalone C UI test harnesses
tools/atlas/               Build-time texture-atlas packer
tools/assets/              Cross-platform checkerboard keyer and sprite importer
vendor/                    Third-party C headers/sources used by the build
```

The main integration boundary is `src/engine/engine.zig`: a game supplies `init`, `update`, `draw`, and `deinit` hooks. Engine code is under `src/engine/`; demo-specific behavior and configuration live under `src/game/`.

## Map format

The demo map at `assets/maps/level1.txt` is plain text. It begins with a size and spawn cell, may list solid tile IDs, then declares one or more layers followed by rows of tile IDs. `.` means an empty cell. Tile IDs select 16 × 16 cells from the tile sprite, counted left-to-right and then top-to-bottom. Supported layers are `ground`, `decoration`, and `foreground`; the player is drawn between decoration and foreground.

```text
size 40 24
solid 1
spawn 20 12
layer ground
1 1 1 1 ...
```

See `src/engine/tilemap.zig` for the parser's complete validation rules.

## Runtime diagnostics

The game writes logs to the terminal and to `zig-out/bin/Semkootru.log`. The file is replaced on each run. The on-screen frame-time overlay toggles with F3. For CPU/GPU zone timelines, start a compatible Tracy viewer and run `zig build run -Dtracy=true`.

## Development status

The project currently provides a working vertical slice and a growing set of engine primitives. The demo exercises rendering, map parsing and collision, camera behavior, animation, controls, settings, UI, and the debug overlay. Audio, the entity world, and asset-cache modules exist, but the sample game does not yet use them. GitHub Actions in `.github/workflows/ci.yml` is configured to build and run unit tests on Linux, macOS, and Windows, and to compile Metal shaders on macOS. Content authoring tools and production-readiness remain future work.
