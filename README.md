# Bairava Engine

Bairava is an experimental 2D game engine written in Zig, with SDL3 and a data-driven sample game named **Semkootru**.

The engine provides a fixed-timestep application loop, SDL3 GPU rendering, pixel-perfect camera and viewport handling, sprites and tile maps, texture streaming, animation, audio, UI, particles, navigation, scripting, jobs, saves, diagnostics, and developer tooling. The public engine API remains in early development and is not production-ready.

Semkootru is the included vertical-slice game and also a reference for building a scene with the public API.

## What is included

- SDL3 windowing, input, gamepad, audio, clocks, and SDL_GPU rendering
- Vulkan/SPIR-V by default, with optional Direct3D 12 DXIL and Metal MSL shaders
- Fixed native resolution rendering with fit and integer scale modes
- Sprite batching, tile maps, cameras, zoom, post-processing, lighting, and skeletal drawing
- Manifest-driven asset builds, atlases, BC1/BC3/ASTC/RGBA8 texture variants, streaming, hot reload, dependency tracking, and generated asset indexes
- Text and bitmap/SDF font tooling, immediate-mode UI widgets, and layout
- ECS-style entities, string/integer animation events, AABB/rotated collision components, uniform-grid queries, navigation, AI, replay, particles, and localization
- Audio playback, streaming, spatial mixing, and background job workers
- A small game scripting runtime and typed host bindings
- Save slots, settings, logging, crash reports, Tracy profiling, and a debug overlay
- A standalone scene sample and a deterministic sprite benchmark

## Requirements

- Zig `0.16.0-dev.3142+5ccfeb926` or the `minimum_zig_version` declared in `build.zig.zon`
- Slang `slangc` on `PATH`
- Internet access on the first build so Zig can fetch pinned dependencies

Optional tools and targets:

- Direct3D 12: build with `-Ddxil=true`; `slangc` must support DXIL
- Metal: build with `-Dmetal=true`; `slangc` must support MSL
- Tracy: build with `-Dtracy=true` and run the Tracy 0.14.1 viewer
- GPU validation: build with `-Dgpu-debug=true`
- ASTC textures: install Arm `astcenc` on `PATH`

SDL3 3.4.2, ztracy, stb_image, stb_image_write, stb_rect_pack, stb_truetype, FreeType, cglm, Parson, and log.c are pinned or vendored. See the [dependency policy](docs/dependency-policy.md) and [dependency lock](docs/dependency-lock.json) before updating them.

## Quick start

Run these commands from the repository root.

```sh
zig build
zig build run
```

`zig build` installs the game to `zig-out/bin/Semkootru`. Runtime assets are staged in `zig-out/bin/assets/`, and shaders are embedded in the executable.

```sh
zig build run -Dprofile=debug       # debug checks and SDL GPU validation
zig build run -Dprofile=release     # optimized release build
zig build run -Dgpu-debug=true      # enable GPU validation explicitly
zig build run -Dtracy=true          # enable Tracy profiling zones
zig build run -Ddxil=true           # add Direct3D 12 shader output
zig build run -Dmetal=true          # add Metal shader output

zig build run-sample                # public-engine scene sample
zig build run-benchmark             # 1000-sprite profiling workload
zig build test                      # Zig, C, API, asset, jobs, and UI tests
zig build test-ui                   # C text and widget tests only
zig build check-assets              # validate the asset manifest and atlas
zig build asset-build               # build assets without installing the game
```

The Windows release package helper can be run with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package-release.ps1
```

It creates `zig-out/release/` with the executable, packaged assets, documentation, and a `release-manifest.txt`.

## Controls

| Input | Action |
|---|---|
| Arrow keys or `W A S D` | Move |
| Esc | Quit |
| F11 | Toggle fullscreen |
| F3 | Toggle the debug overlay |
| `I` | Toggle fit/integer scaling |
| `+`, `=`, or keypad `+` | Zoom in |
| `-` or keypad `-` | Zoom out |
| `0` | Reset zoom |
| F5 | Save to the selected slot |
| F9 | Load from the selected slot |
| Tab | Select the next save slot |
| Left mouse button | Interact with UI controls |

Input is action-based. Defaults are defined in `src/game/controls.zig`, and the copy of `settings.txt` beside the executable can rebind actions to keyboard, mouse, gamepad, stick, or trigger inputs.

## Settings and saves

At startup, the game reads `settings.txt` beside the executable. It controls resolution, fullscreen, vsync, and named action bindings.

```text
resolution = 960x540
fullscreen = false
vsync = true
bind move_left = a, left, pad_dpad_left, pad_left_x-
```

See `settings.txt` for the complete default configuration. Missing values use the game defaults in `src/game/config.zig`.

Saves are stored beside the executable:

- Slot 1: `save.json`
- Slot 2: `save2.json`
- Slot 3: `save3.json`

Saves use versioned, human-readable JSON. Invalid values are rejected or fall back safely, and unsupported newer versions are not silently overwritten.

## Asset pipeline

Asset definitions live in:

- `assets/asset_manifest.txt` for packaged runtime assets
- `assets/sprites.txt` for source sprites packed into the atlas
- `assets/animations/`, `assets/maps/`, `assets/scripts/`, and `assets/prefabs.txt`

The build validates images, WAVs, maps, fonts, and generic files; generates an asset index; packs `atlas.png` and `atlas.txt`; and prepares compressed texture and audio variants.

Useful asset commands:

```sh
zig build asset-import -- path/to/sprite.png my_sprite
zig build asset-keyer -- path/to/sprite.png path/to/sprite_keyed.png
zig build check-assets
```

Import names must be unique and use lowercase letters, digits, `_`, or `-`. The importer copies source artwork into `assets/imported/` and registers it in `assets/sprites.txt`.

For texture formats, the runtime prefers a format supported by the active GPU device. It falls back through ASTC, BC3, BC1, prebuilt RGBA8, or source-image decoding as capabilities allow. The asset build emits RGBA8 plus BC1/BC3 variants and ASTC variants when `astcenc` is available.

Fonts generate `.bfnt` v2/v3 sidecars by default, with configurable codepoint ranges and kerning metadata. Font rows may append `sdf` for a distance-field atlas. Missing glyphs can rasterize dynamically from FreeType or stb_truetype and grow the GPU atlas. Audio rows can produce either copied WAV files or WAV plus IMA ADPCM sidecars.

## Requirements status

The implementation manifest in [requirements.md](requirements.md) is complete. This includes manifest-driven asset builds and generated indexes; BC1/BC3/ASTC variants with RGBA8 fallback; build-time bitmap/SDF fonts with kerning, dynamic glyph caching, and FreeType CFF support; ECS collision components with rotated boxes, layers, and masks; uniform-grid collision queries and movement; string or integer animation events; and normal-map sprites with ECS-accumulated point lights and shadow segments.

Rotated boxes use separating-axis overlap and exact oriented-box point containment. Rotated grid insertion uses conservative AABB bounds, while movement performs exact narrow-phase overlap checks. Broad-phase movement and linear queries share X-first/Y-second resolution; the complete movement response remains axis-based and does not rotate the mover.

## Project structure

```text
build.zig                    Zig build graph
build.zig.zon                Package metadata and pinned dependencies
src/main.zig                 Semkootru entry point
src/game/                    Semkootru gameplay, UI, saves, and configuration
src/engine/                  Public engine modules
src/engine/core/             Application loop, context, lifecycle, and settings
src/engine/platform/         SDL abstraction and backend implementation
src/engine/renderer/         Camera, drawing, GPU backend, post-processing, and lighting
src/engine/assets/           Registry, cache, loaders, streaming, and hot reload
src/engine/animation/        Clips, state machines, and skeletal animation
src/engine/audio/            Voices, streaming, spatial audio, and IMA decoding
src/engine/ecs/              Entity storage
src/engine/navigation/       Pathfinding and steering
src/engine/ai/               Enemy AI support
src/engine/physics/          Collision shapes and queries
src/engine/ui/               Text UI and immediate-mode widgets
src/engine/jobs/             Worker job pool
src/engine/script/           Lightweight scripting runtime
src/engine/diagnostics/      Debug overlay, console, plots, and frame diagnostics
sample/                      Public API scene and benchmark samples
tools/                       Asset tools built through Zig
tests/                       Zig and C test suites
docs/                        Architecture and subsystem documentation
assets/                      Runtime sources, maps, scripts, sprites, and fonts
```

The package root is `src/engine/bairava.zig`. Normal game code should depend on exported types from that module rather than importing engine-private files.

## Documentation

Start with the subsystem guides that match your work:

- [Architecture](docs/whole-architecture.jfif)
- [API compatibility](docs/api-compatibility.md)
- [Build profiles](docs/build-profiles.md)
- [Platform capabilities](docs/platform-capabilities.md)
- [Asset streaming](docs/asset-streaming.md)
- [Animation](docs/animation.md)
- [AI](docs/ai.md)
- [Audio streaming](docs/audio-streaming.md)
- [Lighting](docs/lighting.md)
- [Physics and collision queries](docs/physics.md)
- [Navigation](docs/navigation.md)
- [Particles](docs/particles.md)
- [Jobs](docs/jobs.md)
- [Scripting](docs/scripting.md)
- [Prefabs](docs/prefabs.md)
- [Tile maps](docs/tilemap.md)
- [Saves and replay](docs/replay.md)
- [Developer console](docs/developer-console.md)
- [Logging](docs/logging.md)
- [Diagnostics](docs/diagnostics.md)
- [Profiling](docs/profiling.md)
- [Localization](docs/localization.md)
- [Dear ImGui migration plan](docs/dearimgui-migration-plan.md)
- [Release migration status](docs/p3-migration-status.md)

## Architecture notes

The runtime separates game-facing types from the SDL-specific implementation:

- Game code reads and writes state through `Context`, `DrawContext`, and public engine types.
- The fixed timestep loop updates game state, then the renderer draws an interpolated frame.
- Native coordinates are 320x180 pixels by default. The camera is expressed in native/world pixels.
- The world renders into a native render target and is scaled into the window.
- The SDL GPU implementation owns backend-specific pipelines, buffers, shaders, and transfer operations.
- Asset names resolve through a manifest-backed registry; generated runtime files live beside the executable.

More detail is available in the subsystem guides above.

## Debugging

The debug overlay toggles with **F3**. Development builds show frame timing, frame history, GPU timing, memory and asset diagnostics, and useful developer controls.

Logs are written beside the executable as `Semkootru.log`. Panics are also recorded in the log and in `Semkootru.crash.txt`.

For Tracy:

```sh
zig build run -Dtracy=true
```

Run the Tracy 0.14.1 viewer before launching or connect after startup.

## Testing and continuous integration

```sh
zig build test
zig build test-ui -- assets/font.ttf
python scripts/check-dependency-pins.py
python scripts/boundary_scan.py --fail
```

The main test target runs Zig engine/game tests, public API checks, C text/UI tests, asset-tool tests, and the job/script harnesses. It does not require opening a game window or creating a GPU device.

The CI workflow builds Linux, macOS, and Windows. Linux checks engine dependency boundaries; macOS also compiles Metal shaders.

## Building on what exists

The engine and sample are already suitable for:

- Experiments with fixed-timestep 2D rendering
- Small platformers or tile-based game prototypes
- Pixel-art renderer and asset-pipeline development
- UI, font, audio, streaming, diagnostics, and tooling work
- Evaluating public API boundaries before integration into a larger game

Before building a larger title, review the current API compatibility policy and migration status. Module interfaces and file formats may change while the engine is at version `0.1.0`.

## Conventions

- Run build, asset, and test commands from the repository root.
- Keep source assets in `assets/`; do not hand-edit generated files under `zig-out/`.
- Put dependency updates through the dependency policy and lock tooling.
- Keep SDL and platform types behind the engine abstraction unless working in the SDL backend.
- Make build profile behavior explicit in `build.zig`; do not introduce silent test-only branches.
- Add public APIs to the engine root module and update API compatibility tests when changing exports.
- Record subsystem behavior in the matching guide under `docs/`.
