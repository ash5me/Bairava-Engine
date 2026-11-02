# Bairava

A 2D pixel-art game engine in progress, written in Zig. It draws a tile map at a fixed native resolution, scales it to any window size with nearest-neighbor filtering, and lets a player walk around while a camera follows and zooms. Rendering goes through SDL3's GPU API, with shaders written in Slang and compiled to SPIR-V, and optionally to DXIL for Direct3D 12 or MSL for Metal.

⚠️ The engine is not stable for production use (yet).

The package is named `Bairava` in `build.zig.zon`, the executable is `Semkootru`, and the window title is `Semkootru`.

**Status:** early prototype. The rendering path works end to end, and one animated character walks a tile map while the camera follows. Collision has not been started. The entity and audio modules exist and have tests, but the game does not use them yet. Text and basic UI widgets have a first version that hasn't been checked in the running game yet.

The public engine API is version `0.1.0`, available as `engine.version`. See the [API compatibility policy](docs/api-compatibility.md) before upgrading or depending on the API.

## Contents

- [Requirements](#requirements)
- [Building and running](#building-and-running)
- [Build profiles](docs/build-profiles.md)
- [Dependency policy](docs/dependency-policy.md)
- [API compatibility policy](docs/api-compatibility.md)
- [Platform capabilities](docs/platform-capabilities.md)
- [Debugging](#debugging)
- [Controls](#controls)
- [Project structure](#project-structure)
- [How it works](#how-it-works)
- [Libraries and tools](#libraries-and-tools)
- [Progress](#progress)
- [Building on what exists](#building-on-what-exists)
- [Known issues](#known-issues)
- [Roadmap](#roadmap)
- [Conventions](#conventions)

## Requirements

- **Zig** at the version named by `minimum_zig_version` in `build.zig.zon`, currently `0.16.0-dev.3142+5ccfeb926`.
- **slangc**, the Slang shader compiler, on your `PATH`. Building the optional DXIL shaders (`-Ddxil=true`) also needs a `slangc` that can emit DXIL.
- **For Metal:** build with `-Dmetal=true`; `slangc` must support its Metal target.
- **A GPU backend supported by SDL3.** The default build provides SPIR-V and requests Vulkan 1.2. `-Ddxil=true` adds DXIL for Direct3D 12, and `-Dmetal=true` adds MSL for Metal.
- **Internet access for the first build**, so Zig can fetch SDL3. Later builds work offline.
- **cglm 0.9.7** is vendored under `vendor/cglm/`, including the C sources and headers used by the build.
- **Pinned dependencies** are recorded in [docs/dependency-lock.json](docs/dependency-lock.json). Verify configured versions and vendored source hashes with `python scripts/check-dependency-pins.py`. Do not replace vendored dependencies with files from a floating upstream branch.
- **FreeType 2.15.0** is vendored under `vendor/freetype-2.15.0/` with its FreeType License. The minimal in-tree build rasterizes TrueType and OpenType CFF outlines and generates SDF glyphs.
- **Optional:** the cross-platform checkerboard keyer can be built through Zig; see [Asset keyer](#asset-keyer).
- **Optional:** Arm's `astcenc` on `PATH`, for ASTC 4x4 texture variants. The build doesn't need it for the other formats.
- **Optional:** the Tracy profiler, version 0.14.1, to view profiling zones with `-Dtracy=true`. Get it from [wolfpld/tracy](https://github.com/wolfpld/tracy/releases/tag/v0.14.1). The game's Tracy client is built from source by `build.zig`, through ztracy, so only the viewer is separate. See Debugging.

## Building and running

Run commands from the project root. `zig build` defaults to the `development` profile. The build installs `assets/` beside the executable in `zig-out/bin/assets/`, and shaders are embedded in the executable, so the game runs from any directory.

```
zig build                          # compile the executable and shaders into zig-out/
zig build run                      # build and launch the game
zig build run -Dprofile=debug      # Debug checks, no dev overlay, SDL GPU validation
zig build -Dprofile=release        # optimized player build
zig build run -Dgpu-debug=true     # launch with SDL GPU validation enabled
zig build run -Dtracy=true         # launch with Tracy profiling zones, for a Tracy profiler that is already running
zig build -Ddxil=true              # also compile DXIL shaders for Direct3D 12
zig build run -Dmetal=true         # also compile MSL shaders and allow SDL to select Metal
zig build run-sample               # build and launch the scene sample, which uses no Semkootru code
zig build run-benchmark            # run the deterministic 1000-sprite workload; logs its frame, GPU, and spike summary
zig build test                     # run Zig, public API, C UI, and asset-tool tests (needs SDL, slangc, Python 3; no GPU/window)
zig build test-ui                  # run only the C text and widget tests
powershell -ExecutionPolicy Bypass -File .\scripts\package-release.ps1
                                  # package the current build into zig-out/release for a ship-ready artifact
```

`zig build` installs `zig-out/bin/Semkootru(.exe)`. The compiled shaders are embedded in that executable, so `zig-out/shaders/` is no longer written. The build validates and stages runtime files from `assets/asset_manifest.txt` under `zig-out/bin/assets/`, including a generated `asset-index.txt`. The helper script `scripts/package-release.ps1` packages the built executable plus the runtime assets and shipped docs into a clean `zig-out/release` folder without bringing in dev-only editor or console files. It also writes a `release-manifest.txt` in the package with the build timestamp, artifact name, and current git commit when available, so the release folder is easier to audit.

 Each manifest row declares a name, kind, source, runtime path, and named dependencies. Image, WAV, and TrueType/OpenType inputs are format-checked; maps and generic files are checked for existence. Image entries emit BC1, BC3, and RGBA8 GPU texture variants alongside the source image; when `astcenc` is installed and available on `PATH`, the builder also emits ASTC 4x4. The sprite atlas is packed from `assets/sprites.txt` and sent through the same texture processor, with its regions written to `atlas.txt`. At runtime, SDL's format support query picks ASTC, BC3, or BC1 when the active device can sample that format; otherwise the prebuilt RGBA8 variant or decoded source image is used. Audio entries are copied as WAV and encoded to compact IMA ADPCM sidecars; `wav` entries are copied uncompressed. Font entries generate `.bfnt` files containing a packed glyph atlas, metrics, codepoint range, and kerning pairs; bitmap atlases are default, while font rows may request SDF output. The UI and debug overlay load a sidecar that matches their configured pixel height and fall back to TTF baking if it is absent, malformed, or sized differently. The audio system prefers an IMA sidecar and falls back to WAV, then converts samples to the playback device's format.Run `zig build asset-build` to validate and stage the general asset set without installing the game. Use `audio` for uncompressed PCM WAV inputs that should also get an IMA ADPCM sidecar, or `wav` to keep only the WAV runtime file. Font rows include bake height, first codepoint, and glyph count after dependencies, for example `font font assets/font.ttf font.ttf - 10 32 224`; append `sdf` to generate a scalable distance-field atlas instead of the default bitmap atlas. The build graph tracks the manifest, its source files, and the generated atlas input, so edits rebuild the asset step. Install Arm's `astcenc` command line tool and put it on `PATH` to generate ASTC variants; BC1, BC3, RGBA8, IMA ADPCM, and `.bfnt` outputs do not need extra tools.

See [docs/build-profiles.md](docs/build-profiles.md) for the profile defaults and overrides, [docs/dependency-policy.md](docs/dependency-policy.md) for dependency updates and release provenance, [docs/platform-capabilities.md](docs/platform-capabilities.md) for runtime feature queries and unsupported-feature behavior, and [docs/lighting.md](docs/lighting.md) for ambient, point, and shadow-segment lighting.



## P3 migration status

The engine has completed the in-scope P3 runtime work for content packaging, audio safety, save/load validation, camera/view hardening, viewport-relative UI layout, and reproducible release packaging. A dedicated summary lives in [docs/p3-migration-status.md](docs/p3-migration-status.md).

Key runtime access points:
- Asset validation and packaged runtime files: `zig-out/bin/assets/`
- Release artifact and manifest: `zig-out/release/` and `zig-out/release/release-manifest.txt`
- Runtime asset definitions: `assets/asset_manifest.txt` and `assets/sprites.txt`
- Save logic: `src/game/save.zig`
- UI layout: `src/engine/ui/ui.zig`
- Camera/view: `src/engine/renderer/camera.zig` and `src/engine/renderer/view.zig`

How to test the P3 work:
- `zig build check-assets` to validate the manifest and staged atlas assets.
- `zig build asset-build` to rebuild packaged runtime assets without installing the game.
- `zig build test` to run the canonical Zig and C test suites for the engine/game modules.
- `powershell -ExecutionPolicy Bypass -File .\scripts\package-release.ps1` to package a release and generate `release-manifest.txt`.
- `zig build run` or `zig build run-sample` to exercise the runtime and sample content path.

The C text and widget harnesses in `tests/ui/` are part of `zig build test` and run on the same Linux, macOS, and Windows CI matrix as the Zig tests. The dedicated `zig build test-ui` target runs only those harnesses; pass an alternate font after `--` (for example, `zig build test-ui -- assets/font.ttf`). `scripts/run-ui-tests.ps1` remains available on Windows as a wrapper around that build step. Both harnesses share setup and assertion helpers in `tests/ui/test_support.c` and `tests/ui/test_support.h`. Shared Zig fixtures for sprite batches and compressed-image variants live in `src/engine/test_fixtures.zig`.

## Continuous integration

`.github/workflows/ci.yml` builds and runs the unit tests on GitHub-hosted Linux, macOS, and Windows runners. Linux also runs `scripts/boundary_scan.py --fail`, which enforces the SDL import allowlist. It installs the Zig version declared by `build.zig.zon` and Slang 2026.20. The macOS job also builds with `-Dmetal=true` to compile the Metal shaders.

## Asset keyer

`tools/assets/keyer.c` replaces the old Windows-only `scripts/key_checker.ps1`. Build and run it on Windows, Linux, or macOS with Zig:

```sh
zig build asset-keyer -- assets/warrior.png assets/warrior_keyed.png
```

The tool finds the two most common near-gray colors in its brightness range, then makes matching pixels transparent only when they connect to the image border. This keeps similarly colored pixels enclosed by the artwork. It reads image formats supported by stb_image and writes PNG. Pass an output path explicitly to preserve the source image. Use `zig build asset-keyer -- --help` for tolerance and brightness options.

## Importing a sprite

Use the cross-platform importer to copy an image into the project and register it for the atlas:

```sh
zig build asset-import -- path/to/sprite.png my_sprite
zig build
```

The importer validates the image, preserves its file format, copies it to `assets/imported/`, and adds its name and path to `assets/sprites.txt`. The next build packs it into the runtime atlas automatically. Sprite names must start with a lowercase letter or digit and contain only lowercase letters, digits, `_`, or `-`; names must be unique. Keep the source artwork outside the project if you want an untouched copy. To remove an imported sprite, remove its row from `assets/sprites.txt` and delete its copied file. Run `zig build asset-import -- --help` for usage.

To remove a checkerboard before importing, run the keyer first and import its PNG output:

```sh
zig build asset-keyer -- path/to/sprite.png path/to/sprite_keyed.png
zig build asset-import -- path/to/sprite_keyed.png my_sprite
```

## Save and load

Press **F5** to save or **F9** to load. Saves are written to `save.json` beside the executable and use Parson to serialize a pretty, human-editable JSON document. The `save_version` field and component-scoped keys keep the format resilient: older files can omit newer component fields, while a save with a newer unsupported version is ignored and left untouched unless you explicitly save over it.

The file maps game state into component paths: `components.player.transform` stores position, rotation, and scale, `components.player.facing` stores direction, `components.player.animation` stores movement and elapsed time, `components.game.progress` stores clicks and volume, `components.world.level` identifies the map, and `components.display` stores scale mode and zoom. Version 1 saves with flat `transform.x` and `transform.y` values remain readable. Invalid component values fall back to defaults; saved player positions outside the map or inside solid tiles are rejected.

For example:

```json
{
  "save_version": 2,
  "components": {
    "player": {
      "transform": {
        "position": { "x": 64, "y": 48, "z": 0 },
        "rotation": { "x": 0, "y": 0, "z": 0, "w": 1 },
        "scale": { "x": 1, "y": 1, "z": 1 }
      },
      "facing": { "direction": "down" },
      "animation": { "moving": false, "elapsed_seconds": 0 }
    },
    "game": { "progress": { "clicks": 3, "volume": 0.5 } },
    "world": { "level": { "id": "level1" } },
    "display": { "scale_mode": "fit", "zoom_target": 1 }
  }
}
```

## Debugging

Logs print to stderr, so `zig build run` shows them in the terminal, and they are also written to `Semkootru.log` beside the executable (see Log file below). Each terminal line has a timestamp, a level, and a scope:

```
[    1523ms] INFO  engine: window 960x540, native view 320x180, 60 update steps per second
```

Levels, from least to most severe, are `debug`, `info`, `warn`, and `err`. Debug builds show every level. Other builds show `info` and up. To change the threshold, assign to `engine.log.min_level`, a `pub var`, for example at the top of `main` in `main.zig`.

Assertions check invariants. A failed one prints the file and line, then panics with a stack trace. They run in Debug and ReleaseSafe builds and are compiled out in ReleaseFast and ReleaseSmall. Use `engine.log.assert(ok, @src(), "message {d}", .{value})` for a condition that should hold, and `engine.log.fail(@src(), "message", .{})` for code that should never run.

Every panic is also recorded in the log file before Zig prints it, so a failed assertion or a startup failure, such as a missing font, leaves its reason behind:

```
2026-10-29 07:57:18 ERROR panic: UI font 'assets/font.ttf' could not be read: FileNotFound
```

### Log file

`Semkootru.log` is written to the executable's folder, so after `zig build` it is `zig-out/bin/Semkootru.log`. Each line has a wall-clock time, a level, and a scope, and it holds the same messages as the terminal:

```
2026-10-29 07:57:18 INFO  game: atlas 512x512 with 2 sprites
```

The file is written by log.c (`vendor/log.c`), through `src/engine/logging/log_file.c`. Each run replaces the file from the last run, so it holds one run only. Every line is flushed as it's written, so the file is complete even when the game crashes. Both outputs use the same level threshold. Change `log_file_name` in `game/config.zig` to rename the file, or set it to `null` to log to the terminal only. If the file can't be opened, the game warns in the terminal and keeps running.

### Profiling with Tracy

Profiling zones mark scopes in the frame. The engine marks each frame, and zones cover the event and update steps, the drawing passes, the sprite uploads, the GPU submit, the GPU wait when `Config.gpu_timing` is on, the debug overlay, and asset loading. Game code can add zones too. Zones compile to nothing unless the build uses `-Dtracy=true`, so a normal build has no profiler code. To profile:

1. Start the Tracy profiler, version 0.14.1, which matches the client that ztracy bundles.
2. Run `zig build run -Dtracy=true`. The log says `profiling zones on (Tracy)`.
3. Connect the profiler to `127.0.0.1`. Each frame appears as a frame mark, and the zones appear on the timeline.

To add a zone in game code, use `engine.profile`. A named zone reads best when one function has several zones:

```zig
const zone = engine.profile.zoneNamed(@src(), "draw enemies");
defer zone.End();
```

`engine.profile.zone(@src())` names the zone after its function. Put zones around passes and layers rather than inside per-sprite loops, because each zone has a cost.

### GPU timing and frame spikes

`Config.gpu_timing` measures the GPU's share of each frame, and it is off by default. SDL's GPU API has no timestamp queries here, so the engine submits the frame and then waits on a fence until the GPU finishes it. That wait is the `gpu` phase. The overlay shows it, and Tracy plots it as `gpu ms`. The CPU waits, so the CPU and GPU work add up, and these frame times measure a cost, not a rate. The benchmark turns the option on.

A frame longer than two 60 Hz budgets (33 ms) counts as a spike. The overlay shows how many spikes there have been since startup, and the latest one with its frame and the phase that took the most time. Spikes are recorded only in development builds.

## Controls

| Input | Action |
|---|---|
| Arrow keys, or W A S D | Move |
| Esc | Quit |
| F11 | Toggle fullscreen |
| F3 | Show or hide the debug overlay |
| I | Toggle integer scale |
| = or keypad + | Zoom in |
| - or keypad - | Zoom out |
| 0 | Reset zoom to 1× |
| F5 | Save the game to `save.json` |
| F9 | Load the game from `save.json` |
| Left mouse button | Presses the demo panel's button and drags its slider. |

Keys are bound to named actions in `game/controls.zig`. The defaults are in the table above, and `settings.txt` can rebind them to keys, mouse buttons, gamepad buttons, or gamepad stick and trigger halves. Semkootru's defaults are keyboard only, so a gamepad needs a `bind` line, for example `bind move_left = pad_dpad_left, pad_left_x-`.

### Settings file

The game reads `settings.txt` from beside the executable at startup. The project root has a copy with the defaults. Copy it into the folder with `Semkootru` (for example `zig-out/bin/`) to edit it. Changes apply the next time the game starts. A missing file means the defaults. The file holds `name = value` lines, and lines that start with `#` are comments. Game code can also rebind during play with `controls.rebind(ctx, &bindings, .move_left, &.{.{ .key = .q }})`; it updates the action immediately and atomically saves the new bindings. If saving fails, the previous bindings remain active. An empty binding list writes `none` and leaves that action unbound. Other settings and comments in the file are retained.

| Setting | Values | Default |
|---|---|---|
| `resolution` | `WIDTHxHEIGHT` in pixels, each from 64 to 8192 | `960x540` |
| `fullscreen` | `true` or `false`. `yes`/`no` and `on`/`off` also work. | `false` |
| `vsync` | `true` or `false`, or `on`/`off` and `yes`/`no`. Off presents frames as soon as they are ready, which can tear. | `true` |
| `bind <action> = <binding>, ...` | Replaces the bindings for one action, up to 4. Use `none` to leave an action unbound. Keys use their names (`left`, `a`, `f5`). Mouse buttons are `mouse_left`, `mouse_right`, and `mouse_middle`. Gamepad buttons are `pad_` and the name, such as `pad_south` or `pad_dpad_left`. Stick halves are `pad_left_x-` or `pad_right_y+`, and triggers are `pad_left_trigger`. The full grammar is in `src/engine/input/mapping.zig`. | The keys in the table above |

The action names for `bind` are `move_left`, `move_right`, `move_up`, `move_down`, `quit`, `toggle_scale`, `zoom_in`, `zoom_out`, `zoom_reset`, `save_game`, and `load_game`.

With `fullscreen = true` the window uses the monitor's own mode, so `resolution` applies when the window is windowed. F11 still toggles fullscreen during play. A bad value or an unknown name is written to the log and the default is kept.

## Project structure

```
.
├── build.zig                  Build graph: SDL3, stb_image, cglm, ztracy (with `-Dtracy=true`), log.c and its glue, shader compilation and embedding (SPIR-V, plus optional DXIL and MSL), manifest-driven asset staging, the texture atlas, run and test steps
├── build.zig.zon              Package manifest and pinned dependencies
├── src/
│   ├── main.zig               Entry point: hands the game to the engine
│   ├── engine/                Reusable engine code. Never names a game type. Modules are grouped by area.
│   │   ├── core/              The public API, the frame loop, and what the engine owns while it runs
│   │   │   ├── engine.zig     Public engine API. Game code imports only this file
│   │   │   ├── application.zig   `Config`: what the game passes to `run`
│   │   │   ├── runtime.zig    `run` and the frame loop: fixed-timestep updates, layout, passes, present
│   │   │   ├── context.zig    `Context` (init and update), `DrawContext` (draw), and asset loading through them
│   │   │   ├── lifecycle.zig  `Session`: startup and shutdown of settings, platform, window, GPU, batches, input, audio
│   │   │   ├── event.zig      Event pump: quit, F11 fullscreen, F3 overlay, and input events
│   │   │   ├── settings.zig   Settings file: name = value lines and the window settings. `bind` lines are read by input/mapping.zig
│   │   │   └── math.zig       cglm wrappers: projection, transforms, normalization. The only cglm import
│   │   ├── platform/          SDL-free engine contract and the SDL implementation
│   │   │   ├── platform.zig   Explicit forwarders for files, events, window, clock, audio, and GPU
│   │   │   ├── types.zig      SDL-free platform values, errors, and opaque handles
│   │   │   └── sdl/
│   │   │       ├── sdl.zig    The SDL3 C import
│   │   │       ├── init.zig   SDL subsystem initialization and shutdown
│   │   │       ├── files.zig  Executable-relative file access
│   │   │       ├── clock.zig  Monotonic time and delay
│   │   │       ├── window.zig Window creation, fullscreen, pixel size and density
│   │   │       ├── gpu.zig    GPU device, swapchain, frame acquire/submit, and idle wait
│   │   │       ├── input.zig  SDL events, keyboard, mouse, and gamepad state into platform events
│   │       ├── gamepad.zig  The open gamepads: SDL ids to engine ids, and buttons and axes to engine names
│   │   │       └── audio.zig  Playback device, WAV decoding, conversion, and SDL streams
│   │   ├── renderer/          Drawing
│   │   │   ├── renderer.zig   Render passes and color targets, on engine-owned types
│   │   │   ├── post.zig       Post-processing chain: effect passes over the world target, alternating two targets
│   │   │   ├── render_types.zig  Color, vertex layout, and index values shared with the backend
│   │   │   ├── sprite.zig     Batched textured quads: z order and batching on the CPU, then the backend draws
│   │   │   ├── texture.zig    2D textures and render targets, as engine values over the backend's state
│   │   │   ├── backends/sdl_gpu/  The only renderer code that names SDL_GPU types
│   │   │   │   ├── backend.zig  Root: SDL GPU type aliases and the backend modules
│   │   │   │   ├── shader.zig   Picks a shader format and creates GPU shaders from embedded code
│   │   │   │   ├── pass.zig     Begins and ends render passes, with the clear color
│   │   │   │   ├── texture.zig  GPU textures, samplers, upload fences, and format mapping
│   │   │   │   ├── post.zig     Effect fragment shaders, one per `render_types.Effect`
│   │   │   │   └── sprite.zig   Sprite pipeline, vertex and index buffers, upload, and draw calls
│   │   │   ├── camera.zig     View position, follow target, smoothing, edge clamping, zoom easing
│   │   │   ├── view.zig       Fits the view to the window for each zoom and scale mode, and maps mouse positions
│   │   │   ├── loaded_atlas.zig  The atlas on the GPU: its texture, its index, and each sprite's region
│   │   │   ├── tilemap_draw.zig  Draws one tile layer at a time, with view culling
│   │   │   └── skeleton_draw.zig  Queues a skeleton's attachments as sprites, with each pivot on its bone
│   │   ├── assets/            Names, caching, and loading
│   │   │   ├── manager.zig    Facade over the registry, cache, and loaders
│   │   │   ├── registry.zig   Asset table: names to ids and validated paths
│   │   │   ├── cache.zig      Asset cache: loads each asset once, reference counts, unloads unused entries
│   │   │   └── loaders/
│   │   │       ├── image.zig  Image decoding through stb_image, to RGBA8
│   │   │       └── atlas.zig  Texture atlas index: parsing and lookup by name
│   │   ├── input/
│   │   │   ├── input.zig      Keys, mouse buttons, and gamepad slots: held, pressed, and released. No platform code
│   │   │   ├── gamepad.zig    Gamepad slots: buttons and axes, the dead zone, and the threshold for stick halves
│   │   │   ├── action.zig     `ActionMap`: the bindings of each game action, and how each one reads
│   │   │   └── mapping.zig    Reads `bind` lines from the settings file into an action map
│   │   ├── audio/
│   │   │   ├── audio.zig      Sound ownership, loading, and playback API through the platform facade
│   │   │   ├── voices.zig     Voice handles, gain, and the finish, loop, and feed rules. No SDL
│   │   │   ├── spatial.zig    Positional audio: distance falloff, pan, and per-sample channel gains. Pure
│   │   │   └── ima.zig        BRAD IMA ADPCM decoder to interleaved signed 16-bit PCM
│   │   ├── animation/
│   │   │   ├── animation.zig  Sprite-sheet clips and the animator that plays them
│   │   │   └── skeleton.zig   Bones, sprite attachments, and keyed transforms: parsing, evaluation, and playback
│   │   ├── ecs/
│   │   │   └── entity.zig     Entity world: component rows, generational handles, swap-remove despawn
│   │   ├── physics/
│   │   │   └── shapes.zig     Point and Box in pixels, used by movement and collision
│   │   ├── scene/
│   │   │   └── tilemap.zig    Tile map format, layers, solid tiles, and box movement against tiles
│   │   ├── text/
│   │   │   ├── font.zig       Font on the GPU: prebaked sidecar or TTF baking, lazy glyph growth
│   │   │   ├── layout.zig     Pure UTF-8 line wrapping and horizontal alignment over font metrics
│   │   │   ├── text.h         Font baking and text drawing API. Does not include rasterizer headers
│   │   │   └── text.c         stb_truetype and FreeType baking, BFNT metadata, one quad per glyph
│   │   ├── ui/
│   │   │   ├── ui.zig         Canvas and Ui: bridge from the C widgets to the sprite batch
│   │   │   ├── c.zig          The one C import of the UI headers
│   │   │   ├── ui_draw.h      Quad and draw list types, shared by text and widgets
│   │   │   ├── imgui.h        Immediate-mode UI API: begin and end a frame, label, button, slider
│   │   │   └── imgui.c        The widgets, with hot and active ids, and ## suffixes for duplicate labels
│   │   ├── memory/            Storage types: fixed-capacity strings, hash map, AoS and SoA vectors
│   │   │   ├── string.zig     Validated fixed-capacity Name and Path types
│   │   │   ├── hash_map.zig   StringMap: open-addressing hash map keyed by Name
│   │   │   └── vector.zig     Custom struct vectors in AoS or SoA layout
│   │   ├── logging/
│   │   │   ├── log.zig        Logging to the terminal and the log file, the panic record, and assertions
│   │   │   ├── log_file.h     Log file output through log.c
│   │   │   └── log_file.c     The sink log.c calls, which writes each line with a wall-clock time
│   │   ├── profiling/
│   │   │   ├── profile.zig    Tracy profiling zones and frame marks. The only ztracy import
│   │   │   ├── debug_overlay.zig  On-screen frame-time graph and frame stats, toggled with F3
│   │   │   └── frame_history.zig  Frame-time history and statistics. Pure math
│   │   ├── jobs/
│   │   │   ├── jobs.h, jobs.c    Worker pool, counters, and waits, in C (docs/jobs.md)
│   │   │   └── jobs.zig          Zig interface: typed submit, wait, and isDone
│   │   └── script/
│   │       ├── script.h, script.c  The scripting runtime, in C (docs/scripting.md)
│   │       └── script.zig        Zig interface: values, typed bindings, load and call
│   ├── game/                  Gameplay code. Uses the engine only through engine/core/engine.zig
│   │   ├── game.zig           Game state, asset loading, the UI font, the demo panel, update and draw
│   │   ├── controls.zig       Named actions, default keys, and the `bind` lines that rebind them
│   │   ├── player.zig         Player position, facing, walk clips, drawing
│   │   ├── level.zig          Level: loads the tile map and reports its size
│   │   ├── save.zig           Save file: versioned Parson JSON, with defaults for any fields a save omits
│   │   └── config.zig         Title, window and native sizes, level path, UI font path and size, background color, update rate, scale mode, camera rate, zoom limits and step, asset list
│   └── tests.zig              Test root for the Zig unit and backend tests. Opens no window or GPU device.
├── shaders/
│   └── default.slang          Sprite vertex and fragment shaders. Compiled once per target, and `-DDXIL_TARGET` selects the D3D12 sampler layout
├── scripts/
│   ├── run-ui-tests.ps1       Windows wrapper for `zig build test-ui`
│   └── find-dxil.ps1          Windows: runs `zig build -Ddxil=true` and lists any .dxil and .spv outputs it finds
├── tools/
│   ├── assets/keyer.c         Cross-platform checkerboard-background removal tool
│   ├── assets/import.c        Copies and registers atlas sprites
│   ├── assets/build.c         Validates assets, emits GPU texture formats, IMA ADPCM audio, preprocessed fonts, and the asset index
│   └── atlas/pack.c           Build-time texture atlas packer; writes atlas.png and atlas.txt
├── tests/
│   └── ui/
│       ├── test_imgui.c       Scripted-input checks for the widgets (C)
│       ├── test_text.c        Checks for the baked atlas and the glyph quads text produces (C)
│       ├── test_support.c     Shared C harness setup and assertions
│       └── test_support.h     Shared C test helpers
├── assets/
│   ├── asset_manifest.txt     Runtime asset names, kinds, source/output paths, and dependencies
│   ├── sprites.txt            Sprite names and image paths used by the atlas build
│   ├── tile.png               Tile texture used by the map, packed into the atlas at build time
│   ├── warrior.png            Original warrior artwork (kept unchanged)
│   ├── warrior_keyed.png      Output of the asset keyer on warrior.png. Not in the sprite list
│   ├── warrior_16x32.png      Sprite sheet, 5 columns × 4 rows of 16×32 cells, packed into the atlas at build time
│   ├── wind1.wav              Looping ambience, with an IMA ADPCM sidecar built by the manifest
│   ├── font.ttf               UI font; TrueType and OpenType CFF outlines are supported. Copy a font here; fonts are not included.
│   └── maps/level1.txt        Level 1 tile map: layers of tile IDs, solid tiles, spawn cell
├── vendor/                    log.c and log.h; stb image and atlas tools; stb_truetype; FreeType 2.15.0 source and license; cglm (headers, C sources, license) in vendor/cglm/
└── .gitignore
```

## How it works

### Rendering model

The world is drawn at native resolution into an offscreen target, and that target is then stretched to fill the window.

```
world tiles + player ──► pass 1: sprite batch ──► native target (view_w x view_h)
                                                        │
                                pass 2: stretch quad    ▼
                                                  swapchain (window pixels)
```

At zoom 1 the native view is never smaller than 320x180 pixels. The window's aspect ratio decides which axis fits exactly: on the limiting axis the view is exactly 320 or 180 pixels, and the other axis shows more of the world. In fit mode the window therefore never has black bars. At the default 960x540 window the scale is exactly 3x, which is the cleanest case for pixel art. Other sizes give fractional scales, so some native pixels cover three screen pixels and others cover four. The default fit mode accepts that trade-off. Integer mode uses a whole-number multiple of the view size, so every native pixel is the same size. The result is centered, and thin black bars fill any leftover space at the edges. Set `scale_mode` in `game/config.zig`, or press I to toggle it. Integer mode needs a window at least as large as one native view. Below that, it falls back to fit.

Zoom multiplies the scale, and the view size follows from it. At zoom 2 the scale doubles and the view is half as large, so each world pixel is twice as big. At zoom 0.5 the view is twice as large. The camera, culling, and mouse mapping all read the view size, so they work at any zoom. In integer mode the zoomed scale is rounded to a whole number, never below 1, so every native pixel is still the same size.

### Frame lifecycle

The loop is in `core/runtime.zig`. Game logic runs at a fixed rate, and drawing runs once per frame.

1. Measure the frame time since the last frame, capped at 0.1 s.
2. Drain the platform event queue. The engine handles quit requests, F11, F3, and F4. Unconsumed translated events are also queued for `Context.pollEvent()` in FIFO order; console-consumed input and quit are not exposed. Input state updates immediately, while presses and releases wait for the next update step. See [event conventions](docs/event-conventions.md).
3. Add the frame time to an accumulator. While it holds at least one fixed step (1/60 s by default), latch the pending input so it reaches exactly one update, run game `update` with `ctx.dt` set to that step, and subtract the step. Stop early if the game sets `running` to false.
4. Game `update`: read actions from `game/controls.zig`. Quit, scale toggle, and zoom act on their press. Movement actions move the player at 80 px/s, with diagonals normalized, and solid tiles stop the player's feet on each axis, so the player slides along walls.
5. Compute `alpha`, the leftover fraction of a step, from 0 to 1. Drawing blends between the last two updates with it, so motion stays smooth when the display rate and update rate differ.
6. Read the window size in pixels. If either side is zero, the window is minimized, so sleep for 16 ms (`idle_sleep_ms` in `engine/core/engine.zig`) and start the next frame. Otherwise, ease the camera's zoom toward the zoom the game asked for, choose the scale for the current scale mode and zoom (see Rendering model), then compute the view size. The reference native view is 320×180 in `game/config.zig`.
7. If the view size changed, call `platform.gpu.waitIdle` and recreate the native target.
8. Acquire a command buffer and swapchain texture. If either is unavailable, sleep for the same 16 ms and start the next frame, so a minimized window doesn't spin.
9. Pass 1: game `draw` points the camera at the player's blended center and queues the visible tiles and the player. The engine uploads the vertices and draws them into the native target. The debug overlay is queued after the game, in the same pass.
10. Post-processing, only when `post_effects` in `game/config.zig` names effects: each effect is one full-view pass. It reads the image before it, and the passes alternate between two targets. The last pass's image is what pass 2 shows.
11. Pass 2: queue one quad that stretches the native target, or the last effect's image, across the window. In fit mode it covers the whole window. In integer mode it covers a centered whole-number multiple of the view.
12. Submit the command buffer.

### Coordinate systems

- **World space** is in native pixels, with the origin at the map's top-left corner and y increasing downward. Tiles are 16 px.
- **Camera** `x` and `y` give the world position of the view's top-left corner. They keep fractions while the camera eases. Each sprite and tile rounds its screen position once, with `Camera.screenX` and `screenY`, so everything stays on whole pixels without the camera stepping on its own.
- **Sprite destinations** are in view pixels, so world positions have the camera subtracted. `SpriteBatch` multiplies them by the projection from `math.ortho2d`, which gives normalized device coordinates with y pointing up.
- **Sprite sources** are in texels. `drawSprite` converts them to 0 to 1 UV coordinates.
- **Tint** is an RGB multiplier, and **alpha** is a separate per-sprite multiplier. Both are set through `drawSprite`'s options.
- **Zoom** changes the view size, not the world units. At zoom 2 the view covers half as many world pixels, so the camera, culling, and mouse mapping need no zoom-specific code.
- **Mouse** positions from SDL are in window points. `Context.mouseWorld` converts them to world pixels, using the layout and camera of the last frame drawn.
- **UI** positions are in view pixels, from the top-left corner of the view. The camera doesn't move them. The UI maps the pointer with `view.windowToView`, not `Context.mouseWorld`, so the panel stays put while the camera moves.

## Libraries and tools

| Name | Version | Used for | License |
|---|---|---|---|
| Zig | 0.16.0-dev, pinned by `minimum_zig_version` | Language, build system, standard library | MIT |
| SDL3 | 3.4.2, via the `sdl` 0.4.0 Zig wrapper on Codeberg (`brodo/SDL`), pinned to commit `95a338c` in `build.zig.zon` | Window, events, keyboard and gamepad state, SDL_GPU API, file loading, timing, memory, audio streams | zlib |
| stb_image | 2.30, vendored in `vendor/` | Decoding PNG and other image formats to RGBA8, and image validation in the importer (`tools/assets/import.c`) and the keyer (`tools/assets/keyer.c`) | Public domain or MIT |
| stb_image_write | 1.16, vendored in `vendor/` | Writing `atlas.png` in the build's atlas packer | Public domain or MIT |
| stb_rect_pack | 1.01, vendored in `vendor/` | Packing sprites into the texture atlas at build time (`tools/atlas/pack.c`) | Public domain or MIT |
| stb_truetype | 1.26, vendored in `vendor/` | Build-time font preprocessing and TTF fallback baking (`tools/assets/build.c`, `src/engine/text/text.c`) | Public domain or MIT |
| FreeType | 2.15.0, vendored in `vendor/freetype-2.15.0/` | CFF-capable font baking, SDF rasterization, and dynamic glyph caching | FreeType License |
| cglm | 0.9.7, vendored in `vendor/cglm/`: headers, the 46 C sources its CMake lists, and its license | Vector and matrix math, the pixel projection, and transforms | MIT |
| log.c | rxi's log.c, 2020 (`log_Event` API), vendored in `vendor/log.c` and `vendor/log.h` | Delivers each message to the log file through `src/engine/logging/log_file.c` | MIT |
| ztracy | Zig bindings, pinned to commit `2d06ebe` in `build.zig.zon` | Tracy zones and frame marks, compiled in with `-Dtracy=true` through `src/engine/profiling/profile.zig` | MIT |
| Tracy client | 0.14.1, bundled in ztracy's `libs/tracy/` and built from source with `-Dtracy=true` | The profiler's runtime: records zones and sends them to the Tracy viewer | 3-clause BSD |
| Slang (`slangc`) | 2026.20, installed by CI; local builds need it on `PATH` | Compiles `shaders/default.slang` to SPIR-V (pinned to the SPIR-V 1.5 profile) and, with `-Ddxil=true`, to DXIL (`sm_6_0`) | Apache 2.0 with LLVM exception |
| Arm astcenc | Optional, installed separately and on `PATH` | ASTC 4x4 texture variants, encoded at build time (`tools/assets/build.c`) | Apache 2.0 |
| Vulkan | System driver, selected by SDL_GPU | GPU backend that runs the SPIR-V shaders | Driver, not bundled |
| Direct3D 12 | System driver, selected by SDL_GPU | Optional GPU backend that runs the DXIL shaders | Driver, not bundled |
| Parson | Vendored in `vendor/parson.c` and `vendor/parson.h` | Versioned human-editable save JSON (`src/game/save.zig`) | MIT |

## Progress

### Implemented

**Platform and application**
- SDL3 initialization and a resizable, high-DPI window that starts at 960x540 unless `settings.txt` says otherwise.
- Quit on window close or Esc. F11 toggles fullscreen.
- Fixed-timestep update loop (60 steps per second by default) with an accumulator. Frame time is capped at 0.1 s, and `draw` gets an interpolation factor.
- Live stats in an on-screen debug overlay with a frame-time graph, toggled with F3. The window title is no longer used for stats.
- Opt-in GPU timing with `Config.gpu_timing`, which waits on a fence to report the frame's GPU cost, and a record of recent frame spikes on the overlay.
- A minimized window idles instead of spinning the CPU.
- Profiling zones through Tracy (`-Dtracy=true`), which compile to nothing otherwise, and a log file beside the executable, written through log.c. Panics are recorded in the log file.

**GPU and shaders**
- GPU device creation with a Vulkan 1.2 request, SPIR-V shaders (plus DXIL when built with `-Ddxil=true`), and an optional validation layer (`-Dgpu-debug`).
- Swapchain claim, command buffer acquire and submit, and clear-color render passes.
- A build step that compiles two Slang entry points to SPIR-V, and to DXIL when `-Ddxil=true` is set, and embeds them in the executable.
- Shader loading that picks the first format the device accepts (SPIR-V first, then DXIL). Shader code is embedded in the executable at build time, aligned for 32-bit word reads, and each shader's entry point and resource counts are declared as a `shader.Source` beside the pipeline in `renderer/backends/sdl_gpu/sprite.zig`.
- One sprite shader: the texture sample multiplied by the vertex color.

**Textures and images**
- PNG decoding through stb_image, converted to RGBA8.
- Texture upload through a transfer buffer, queued without waiting for the GPU.
- Render-target textures in the swapchain format.
- Nearest-neighbor sampler with clamp-to-edge addressing.
- Assets installed beside the executable and loaded through `platform.files`, so the game runs from any directory.
- Build-time texture atlas: `tools/atlas/pack.c` packs the sprites listed in `assets/sprites.txt` into one square PNG with stb_rect_pack. The square is the smallest power of two that fits, and each sprite has one transparent texel of padding on every side. `engine/assets/loaders/atlas.zig` reads the index written beside the image, and the game draws every sprite from that one texture.

**2D rendering**
- Sprite batching: quads buffered per frame as four vertices drawn through an index buffer, one draw call per run of the same texture, alpha blending, tint, source rectangles, and no fixed sprite or texture-switch limit.
- Per-sprite options through `drawSprite`: flip, rotation around an origin, alpha, and z-order. Sprites are sorted by z once per frame, and sprites with equal z keep the order they were added in.
- Tile world rendering with view culling and a one-tile margin.
- Camera follow with frame-rate-independent smoothing, edge clamping, pixel snapping, and centering when the world is smaller than the view.
- Camera zoom from keys. Each press multiplies or divides the zoom by 1.25, and the camera eases to the new zoom in logarithmic steps. Zoom changes the view size, so the camera, culling, and mouse mapping work unchanged. Integer mode rounds the zoomed scale to a whole number.
- The two-pass pixel-art pipeline: native target, then stretch to the window.
- Fit and integer scale modes, set in `game/config.zig` or toggled with I.

**Text and UI**
- TrueType fonts are preprocessed at build time into compact `.bfnt` v2 bitmap sidecars containing the glyph atlas, metrics, codepoint range, and kerning pairs. FreeType handles CFF-based OpenType fonts. The runtime still accepts v1 sidecars and expands sidecars to RGBA for GPU upload. It falls back to source-font baking if a sidecar is unavailable or incompatible.
- Font manifest entries can opt into `.bfnt` v3 SDF atlases by appending `sdf`; bitmap output stays the default. `Font.bakeSdf` is also available for runtime baking, and `ui_font_draw_text_scaled` scales glyph quads while the sprite shader reconstructs smooth coverage.
- Text becomes one quad per glyph, decoded from UTF-8. `Font.load` lazily rasterizes and caches codepoints outside the baked range from the retained font source; unsupported glyphs draw as `?`.
- `Canvas.layoutText(allocator, text, max_width, alignment)` wraps words at spaces/tabs, preserves blank lines, splits overlong words at codepoint boundaries, and reports line widths and total height. Draw it with `drawTextLayout`; the layout owns its line array but borrows the source text, and must be released with `deinit`.
- Immediate-mode widgets in `src/engine/ui/imgui.c`: label, button, and slider. Hover and press are tracked through two ids, and a `##` suffix tells duplicate labels apart without drawing the suffix.
- `src/engine/ui/ui.zig` uploads the font and queues the UI quads as sprites at z 1000, so they draw above the world.
- Input tracks the held state of keys and all three mouse buttons, and each press and release reaches one update step.
- Semantic actions: a game names its actions and binds each to keys, mouse buttons, gamepad buttons, or stick and trigger halves. A key and a gamepad button can trigger the same action. The sample switches scenes with either.
- Gamepads through SDL: hotplug, a dead zone on sticks, and the first gamepad connected as the primary one. Presses and releases latch like keys.
- A demo panel in `game/game.zig` (a label, a click counter, and a volume slider) runs in the update step, as a first end-to-end check of the text and widget path.

**Math and data**
- cglm for vectors and matrices, wrapped in `core/math.zig`. The sprite projection and diagonal normalization use it. `core/math.zig` also covers 3D transforms, perspective and look-at matrices, and quaternions (slerp, look rotation, billboard). Only the 2D parts are used so far.
- Validated names and paths (`memory/string.zig`), a hash map keyed by names (`memory/hash_map.zig`), and an asset table that gives each name a dense id (`assets/registry.zig`).
- Tile maps (`scene/tilemap.zig`): a text format with three layers (ground, decoration, foreground), tile IDs, empty cells written as `.`, solid IDs, and a spawn cell. Malformed maps report what is wrong. `TileMap.moveBox` moves a box against solid tiles, one axis at a time.
- Sprite-sheet animation (`animation/animation.zig`): clips that name a row of frames, with frame time and loop mode, and an animator per entity.
- `zig build test` runs the Zig unit and public API tests plus both C UI harnesses. The Zig renderer tests link SDL, but no test opens a window or creates a GPU device.
- Mouse mapping from window points to view and world pixels in `renderer/view.zig`, through `Context.mouseWorld`. Its tests run with `zig build test`.

**Gameplay**
- Player movement with arrow keys or WASD, normalized diagonals, and collision with solid tiles.
- A 16×32 South Indian warrior sprite loaded from `assets/warrior_16x32.png`, with separate player width and height constants.
- Directional sprite selection for front/down, right, back/up, and left; horizontal input wins when moving diagonally.
- Walk clips with frame 0 shown while idle, and each walk row cycles through its five frames. Changing clip restarts it at its first frame.

**Tooling**
- `-Dgpu-debug`, `-Ddxil`, and `-Dtracy` build options.
- `tools/assets/keyer.c` replaces the old PowerShell checkerboard-removal script. The current warrior runtime sheet is `assets/warrior_16x32.png`; the keyer requires separate input and output paths, so it leaves the source artwork in place.

### Module status

These estimates are rough. They measure how close each area is to something usable for a small 2D game, not how much code it has.

| Area | File | Status | Est. done | Notes |
|---|---|---|---|---|
| Platform | `platform/platform.zig`, `platform/sdl/` | Complete | 100% | SDL-free forwarding contract; SDL imports are restricted to the backend and documented GPU renderer files. Linux CI enforces the allowlist. |
| Engine | `engine/core/engine.zig` | Prototype | 65% | Window, GPU setup, native-view pipeline, fixed-timestep loop, fit and integer scaling, camera zoom, and the `Game` interface. Missing: device-lost recovery. |
| Logging and assertions | `engine/logging/log.zig`, `logging/log_file.c`, `vendor/log.c` | Functional | 85% | Levels, scopes, timestamps, and assertions that check in Debug and ReleaseSafe. Terminal and log file output through log.c, with panics recorded in the file. Missing: rotation, and keeping logs from earlier runs. |
| Profiling | `profiling/profile.zig`, `engine/core/engine.zig`, `diagnostics/plots.zig`, `core/allocators.zig` | Functional | 75% | Tracy zones for the frame, events, updates, passes, uploads, submit, the GPU wait, the debug overlay, and asset loads, plus frame marks. Compiled in only with `-Dtracy=true`. A captured session checked the zone names and counts. Per-frame allocation counts and bytes for each scope, and four per-frame plots (sprites, draw calls, allocations, allocated bytes) shown in the overlay and sent to Tracy as plots. The plot calls and the allocation counts have not been checked in a captured Tracy session. GPU time per frame with `Config.gpu_timing`, measured by a fence wait that stalls the CPU. Missing: per-pass GPU timing, since the SDL GPU API the engine uses shows no timestamp queries in the code (confirm against the pinned SDL), and Tracy memory events. Those need a matching free for every allocation, and the arenas free in bulk, so each would need a registry of live pointers. |
| Gameplay | `game/` | Prototype | 20% | Player with directional walk clips, one level loaded from `assets/maps/level1.txt` and drawn in layers, and movement and quit actions bound in `game/controls.zig`. No entities or rules. |
| Renderer | `renderer/renderer.zig`, `renderer/render_graph.zig` | Solid base | 80% | Device, swapchain, and passes work. Asks the device for DXIL and MSL only when the build embeds those formats. Pass settings are unit tested. Device and frame calls need a GPU and aren't. A render graph (`renderer/render_graph.zig`) checks pass declarations, orders the passes, and shares transient targets between passes whose lifetimes don't overlap. The post-processing chain (`renderer/post.zig`) is built from it and runs fragment-shader effects (grayscale, vignette, scanlines) between the two passes. The graph is unit tested. The chain has not been run on a GPU yet. Missing: device-lost recovery, pass helpers, and a graph for the world pass itself. |
| Shaders | `renderer/backends/sdl_gpu/shader.zig` | Basic | 65% | Picks the first shader format the device accepts (SPIR-V, DXIL, then MSL) and creates GPU shaders from code embedded at build time. DXIL (`-Ddxil=true`) and MSL (`-Dmetal=true`) are optional. Per-shader entry points and resource counts are declared in `renderer/backends/sdl_gpu/sprite.zig`. Missing: reflection. Uniform buffer count is supported but unused. |
| Textures | `renderer/texture.zig` | Solid base | 70% | Uploads queue without waiting, and `isReady` reports when one finishes. Missing: unload and reload. |
| Atlas | `assets/loaders/atlas.zig`, `tools/atlas/pack.c` | Functional | 60% | Build-time packing with stb_rect_pack, index parsing with validation, and lookup by name. Missing: runtime packing, several atlas pages, rotated sprites. |
| Images | `assets/loaders/image.zig` | Basic | 60% | PNG and other formats through stb_image to RGBA8. Synchronous, relative paths only. |
| Math | `core/math.zig` | Functional | 60% | cglm wrappers: identity, mul, invert, transpose, translate, scale, rotate, ortho, perspective, look-at, point and vector transforms, 3D vector helpers, and quaternions (slerp, look rotation, billboard). 18 tests. Only the 2D parts are used so far. |
| Strings | `memory/string.zig` | Functional | 70% | Validated `Name` (up to 64 bytes) and `Path` (up to 255 bytes, null-terminated). Rules are in the file's doc comments. |
| Hash map | `memory/hash_map.zig` | Functional | 70% | Open addressing with full key comparison, growth at 3/4 load, removal by backward-shift deletion (no tombstones), checked against `std.StringHashMap`. |
| Assets | `assets/registry.zig` | Early | 40% | Names, dense ids, and validated paths. The game no longer uses it, since its sprites come from the atlas. Loading and caching are in `assets/cache.zig`, which looks assets up by these names. |
| Asset cache | `assets/cache.zig` | Early | 50% | Generic cache keyed by asset name: reference counts, load on first `acquire`, `unloadUnused`, a byte budget with least-recently-used eviction, and priority preloading through `request` and `pump`. Names and paths come from `assets/registry.zig`, and the index is the engine's `StringMap`. Not yet compiled or run. The engine's texture store uses it, but the game still loads its atlas, font, and sound directly. Textures load in the background through the job system (docs/jobs.md). Missing: fonts and sounds in the cache; hot reload; unloading on a schedule. |
| Sprites | `renderer/sprite.zig`, `renderer/backends/sdl_gpu/sprite.zig` | Functional | 80% | Batched quads with four vertices each and a 32-bit index buffer. Per-sprite tint, alpha, flip, rotation around an origin, and z-order, sorted once per frame. Storage grows with each frame. Normal maps (`Options.normal`) light a sprite with up to 16 point lights from `SpriteBatch.addLight`, drawn through a second pipeline. `Options.lit` lights a sprite with no map of its own as a flat surface, through a shared one-texel map that is ready a frame after the batch is created. Tile layers take the same options through `tilemap_draw.drawLayer`. Each vertex carries a 2x2 normal basis, so a flipped or turned sprite lights as it appears; that adds 16 bytes per vertex. The lit path has not been run on a GPU yet. Missing: instancing. The player and the UI stay unlit until a game passes `lit` for them. |
| Camera | `renderer/camera.zig` | Functional | 75% | Follow, frame-rate-independent smoothing, clamp, per-sprite pixel rounding, and eased zoom. Missing: dead zone, shake. |
| Animation | `animation/animation.zig`, `animation/machine.zig`, `animation/skeleton.zig` | Functional | 60% | Sprite-sheet clips, a state machine that blends between clips and emits frame events, and skeletal animation: bones with sprite attachments and keyed transforms. See `docs/animation.md`. |
| Level | `game/level.zig` | Early | 50% | Loads the tile map and reports its size. Drawing is in `engine/renderer/tilemap_draw.zig`, one layer at a time in ground, decoration, player, foreground order, with culling. Solid tiles block the player. No tile animation. |
| Tile map | `engine/scene/tilemap.zig` | Functional | 70% | Text map format with clear parse errors, three layers, empty cells, solid IDs on any layer, a spawn cell, and box movement that stops at solid tiles, one axis at a time. Missing: Tiled import. |
| Input | `input/input.zig` | Functional | 75% | Held, pressed, and released keys and mouse buttons. One-shot input reaches exactly one update step. `mouse_x` and `mouse_y` are window points; use `Context.mouseWorld` for world coordinates. Clicks don't store a position yet. No text input. Unit tests run through `src/tests.zig`. |
| Actions | `input/action.zig`, `input/mapping.zig` | Functional | 70% | `ActionMap` evaluates each game action from any of its bindings: keys, mouse buttons, gamepad buttons, and stick or trigger halves. `bind` lines in the settings file replace an action's bindings, and problems are logged. Missing: rebinding UI, which is out of scope for P1. |
| Gamepad | `input/gamepad.zig`, `platform/sdl/gamepad.zig` | Functional | 65% | Connect and disconnect with hotplug, the first gamepad connected as the primary, a dead zone on sticks, and a stale id is ignored once its slot is reused. Unit-tested without SDL. Not yet checked with a physical controller. Missing: rumble, sensors, and per-player routing. |
| View mapping | `renderer/view.zig` | Functional | 70% | Fits the native view to the window for each zoom and scale mode (`chooseFit`). Converts mouse positions from window points to view and world pixels, using the rectangle the view is drawn into. Pure math with its own tests, run by `zig build test`. |
| Build | `build.zig`, `.github/workflows/ci.yml` | Functional | 70% | Builds SDL3, stb_image, stb_truetype, cglm, the UI C sources, embedded shaders (SPIR-V, optional DXIL and MSL), the texture atlas, the asset keyer, run step, and test step. CI builds and tests on Linux, macOS, and Windows. |
| Assets | `tools/assets/keyer.c` | Utility | 30% | Cross-platform checkerboard keyer with configurable color thresholds, connected-border flood fill, and PNG output. It replaces the old one-off PowerShell script; it is not a general asset pipeline. |
| Tests | `src/tests.zig`, `tests/ui/` | Functional | 50% | Zig unit and public API tests plus C text/widget harnesses, all run by `zig build test`. The Zig renderer tests link SDL, but no test opens a window or creates a GPU device. |
| Vector | `memory/vector.zig` | Functional | 60% | Generic struct vector in AoS or SoA, one allocation for either layout, strided column views that work under both, and contiguous `items` under SoA. Missing: shrinking, sorting, and removal of unused capacity. |
| Entities | `ecs/entity.zig`, `sample/main.zig` (swarm scene) | Functional | 70% | World of component rows with generational handles, dense rows, swap-remove despawn that repairs the moved row, and `handleAt` from a row to its handle. The iteration and mutation rules are in the module doc. The sample's swarm uses it. The player is still a struct in `game/player.zig`. Level metadata places prefabs as entities; see `docs/prefabs.md`. Missing: queries beyond the row walk, and prefab components other than a tile. |
| Navigation | `engine/navigation/` (`grid.zig`, `pathfind.zig`, `follow.zig`), `game/enemy.zig`, `game/enemy_ai.zig` | Early | 50% | A walkable grid over the tile map with line of sight, A* routes with the corner rule and reusable arrays, and a follower that walks a box through tile collision and snaps onto cells. Enemies use them to wander, chase the player, and walk home. See `docs/navigation.md`. Missing: dynamic obstacles, route smoothing, enemy combat, and saving enemies. |
| Debug overlay | `profiling/debug_overlay.zig`, `profiling/frame_history.zig`, `diagnostics/plots.zig`, `diagnostics/spike_log.zig` | Early | 65% | Frame-time graph and frame stats drawn in the native view, toggled with F3. Replaces the title stats. Shows the average, p95, and max, the update and render split, the GPU wait when `Config.gpu_timing` is on, the latest frame spikes over 33 ms with the phase that took the most time, a strip of allocations per frame, and a line of per-frame plot values. The frame history, spike log, and plot series are unit tested. The overlay has not yet been checked in the running game. Missing: per-pass GPU timing. |
| Collision | `physics/shapes.zig`, `physics/collision.zig`, `physics/queries.zig`, `physics/broad_phase.zig` | Early | 50% | Point, box, and circle overlap tests; layer-filtered point, region, and movement queries; and an optional uniform-grid broad phase for static collider slices. Geometry and layers must stay fixed while indexed. There is no swept test. The player still moves through the tile map, which has its own movement. |
| Audio | `audio/audio.zig`, `audio/voices.zig`, `audio/spatial.zig`, `audio/ima.zig`, `platform/sdl/audio.zig` | Early | 45% | Engine audio owns sounds and voices; the SDL backend owns the optional playback device, streams, WAV byte decoding, and format conversion. Build-generated IMA sidecars decode in the platform-independent engine module. The game loops `wind1.wav`, controlled by the demo volume slider. Positional sounds (`PlayOptions.position` with `Audio.setListener` and `Audio.setPosition`) fall off linearly with distance and pan by their side; see `audio/spatial.zig`. Missing: streaming long music from disk, volume categories, reacting to device changes. |
| Text | `text/text.c`, `text/text.h`, `text/layout.zig`, `ui/ui.zig` | Early | 45% | Build-time TTF/CFF preprocessing into `.bfnt` v2 bitmap or v3 SDF sidecars with glyph atlas, metrics, codepoint range, and kerning pairs; v1 sidecars remain readable. `Font.load` lazily rasterizes and caches missing codepoints, growing the atlas and refreshing its GPU texture. `Canvas.layoutText` wraps at spaces/tabs, handles explicit newlines, splits long words on UTF-8 boundaries, and aligns each line. One quad per glyph, UTF-8 input. Missing: shaping for Tamil and other complex scripts. |
| UI widgets | `ui/imgui.c`, `ui/imgui.h` | Early | 35% | Label, button, and slider with hot and active ids and `##` suffixes. Tested with the C harness using scripted input. Not yet checked in the running game. Missing: checkbox, panels and layouts beyond one column, text input, keyboard focus, scrolling. |
| Scenes | `engine/scene/scene.zig`, `engine/scene/scene_manager.zig`, `engine/scene/host.zig` | Early | 50% | Scene contract and a manager with a stack of scenes. `switchTo` replaces the active scene. `push` opens a child scene above it, and the scene below is suspended: not updated, but still drawn. `pop` closes the active scene so the one below resumes. `SceneHost` runs scenes as a game, and changes apply after the update that asked for them. A failed `init` keeps the stack as it was. The sample game and Semkootru both run through it. |
| Jobs | `jobs/jobs.c`, `core/texture_stream.zig`, `assets/staging.zig` | Functional | 60% | A worker pool with a bounded queue, counters, and waits that run queued jobs. Textures decode on workers and upload on the main thread between frames. The C tests run in `zig build test`. Not yet run on Windows. Missing: background loading for fonts and sounds. |
| Scripting | `script/script.c`, `script/script.zig`, `game/script_host.zig` | Early | 50% | A small C-like language with values, functions, and bounded execution, bound to the game through typed Zig functions. A failed load keeps the previous script. Missing: hot reload from the game, and string and table operations. See docs/scripting.md. |

## Building on what exists

These are the natural extension points. Each one reuses existing code.

**Character sprite and animation.** The warrior is a region of the texture atlas, found by name at startup, and drawn through the existing `drawSprite` source-rectangle API, offset by that region. Each cell is 16×32 pixels. `game/player.zig` keeps a facing and an `engine.animation.Animator`. Each update, `clipFor` picks the clip for the facing and whether the player is moving, and the animator restarts only when the clip changes. Each walk row uses its five frames, and the clip for standing still shows frame 0. To add an animation, define a `Clip` (sheet row, frame count, frame time, loop mode) and select it in `clipFor`.

**Add a tile layer.** Layers are the `Layer` enum in `engine/scene/tilemap.zig`, and `all_layers` lists them. To add one, add an enum value and its name to `parseLayer`, then call `engine.tilemap_draw.drawLayer` for it in `Game.draw` at the point in the draw order where it belongs, passing the sprite options its tiles use (`.{}` for unlit, or `.{ .lit = true }` to light the layer). A solid ID on any layer blocks movement.

**Add collision to an entity.** Give the entity a `tilemap.Box` and call `TileMap.moveBox` with its movement each update, the same way `Player.update` does. Map edges count as solid, so they act as walls.

**Add camera effects.** The camera is a position and a view size. `followSmooth` eases toward the clamped target, and `camera_rate` in `game/config.zig` sets how fast. Shake is an offset applied after `follow`. Zoom is already in place: `Context.zoomBy` and `resetZoom` set the target, `engine/core/engine.zig` eases `Camera.zoom` toward it each frame, and `view.chooseFit` turns the zoom into a scale and a view size. Drawing and culling read the view size, so they need no changes. To change the limits or the step, edit `zoom_min`, `zoom_max`, `zoom_step`, and `zoom_rate` in `game/config.zig`.

**Add input actions.** Add a name to `Action` in `game/controls.zig` and give it default bindings in `defaults`. Query it with `self.bindings.held(input, .name)`, `pressed`, `released`, or `value`, where `value` is the strength from 0 to 1 that an analog stick sets. The settings file can then bind it with a `bind` line. Gameplay never checks a key or a button directly. To use a key the engine doesn't know yet, add it to `Key` in `engine/input/input.zig` and map it to its SDL scancode, and it works in `bind` lines at once. To use a gamepad button the engine doesn't name yet, add it to `GamepadButton` in `platform/types.zig` and map its SDL name in `platform/sdl/gamepad.zig`.

**Add a shader or pipeline.** Add the entry point to `shaders/default.slang`, because `build.zig` compiles only that file (to compile another file, give `ShaderEntry` a source path). Add a row for each entry point to `shader_entries` in `build.zig`, and declare a `shader.Source` in `renderer/backends/sdl_gpu/sprite.zig` with the stage, resource counts, and embedded code for each format. DXIL and MSL slices are empty unless enabled with `-Ddxil=true` or `-Dmetal=true`. Follow the target-specific resource declarations in `default.slang`; Slang emits Metal texture and sampler arguments for MSL. Load it with `shader.load` and create a pipeline the way `backends/sdl_gpu/sprite.zig`'s `create` does. Pipelines are built for a specific shader pair and color format, so a second one needs its own init.

**Add a render target.** `texture.createTarget` creates a target in the swapchain format. Pass it to `renderer.beginPass` to draw into it, then sample it like any other texture. Use this for lighting or a minimap. Full-screen effects belong in the post-processing chain instead.

**Add a post-processing effect.** An effect is one fragment entry point in `shaders/default.slang`. Add a row for it to `shader_entries` in `build.zig`, add its name to `render_types.Effect`, and map that name to its shader in `renderer/backends/sdl_gpu/post.zig`. Turn it on by listing it in `game/config.zig` as `post_effects`, for example `&.{ .vignette }`. Effects run in order over the finished world, after the game draws, so they also change the debug overlay. The effects read their strengths from `game/config.zig` as `post_params`: vignette, scanline dim, and grayscale amount, each from 0 to 1. A new effect that needs its own value adds a field to `render_types.PostParams`, which fills the same 16-byte block.

**Add a sprite.** Run `zig build asset-import -- path/to/image.png sprite_name`. This copies the image to `assets/imported/` and registers it in `assets/sprites.txt`; the next `zig build` packs it into the atlas. In the game, look the sprite up once with `atlas.region(name)`, on the `LoadedAtlas` in `Game.atlas`, and store the returned region in a field, as `Game.init` does for `tile` and `warrior`. Draw it by offsetting the source rectangle by the region's position in the atlas, as `engine.tilemap_draw.drawLayer` and `Player.draw` do.

**Add entities.** Define the components as one struct with a field per component value, for example `const Body = struct { x: f32, vx: f32, id: u64 };`. Create a world with `var world = engine.entity.World(Body, .soa).init(allocator)`, choosing `.aos` or `.soa` as the layout (see `engine/memory/vector.zig`). Spawn with `world.spawn(row)`, which returns a `Handle`. Keep the handle, not a row index, because despawning moves rows. A system loops over `0..world.count()` and reads a field with `world.rows.column("vx")`, which works the same under either layout. Under SoA, `world.rows.items("x")` gives a plain slice when a system needs one. Draw entities as `Player.draw` does, subtracting the camera from world positions.

**Add a UI widget or panel.** Widgets are in `src/engine/ui/imgui.c`. A widget takes the next row of its column with `next_row`, calls `interact` to track hover and press, then appends quads with `fill` or `ui_font_draw_text`. The demo panel in `game/game.zig` shows the pattern: `updateUi` builds the widgets in the update step, so each press is seen once, and `draw` passes the quads to `engine.ui.queueQuads`. To change the font, replace `assets/font.ttf`, or edit `ui_font_path` and `ui_font_px` in `game/config.zig`.

## Known issues

1. **Fixed: mouse coordinates were in window points, not world pixels.** `Context.mouseWorld` converts the mouse position from points to pixels, maps it through the rectangle the view was drawn into (which covers the scale, centering, and rounding), and adds the camera position. Both the layout and the camera come from the last frame drawn, so an update sees what the player saw. Clicks don't store a position yet, so a click handler reads the cursor's last known position.

2. **Fixed: asset paths depended on the working directory.** The build installs `assets/` beside the executable, and `Context.loadTexture` resolves paths through `platform.files`. Shaders are embedded at build time, so nothing else depends on the working directory.

3. **Fixed: a minimized window spun the CPU.** A zero-size window, or a frame with no swapchain, used to restart the loop without waiting. Both cases now sleep for 16 ms first, so a minimized window idles.

4. **Vulkan is the default backend. Direct3D 12 and Metal formats are opt-in.** SPIR-V shaders are always built. `zig build -Ddxil=true` embeds DXIL (`sm_6_0`), and `zig build -Dmetal=true` embeds MSL; the renderer tells SDL which optional formats are available. `shader.pickFormat` selects the first supported format. SDL consumes Slang's MSL source with the original entry-point names. The `default.slang` sampler declarations cover Vulkan and D3D12; Slang maps the texture and sampler to Metal arguments for MSL. Vertex locations match the attributes in `renderer/backends/sdl_gpu/sprite.zig`.

5. **Fixed: names didn't match.** The package is `Bairava` in `build.zig.zon`, the executable and window are `Semkootru`, and the sprite shader is `default.slang`.

6. **Fixed: the `root.zig` template is gone.** `zig init` created `src/root.zig`, which nothing imported. The project no longer has it, and `zig build test` runs `src/tests.zig`.

7. **Fixed: texture uploads blocked.** `Texture.initRgba8` used to wait for the GPU to go idle. It now queues the copy and returns. `Texture.isReady` reports when the copy finishes, and `SpriteBatch.draw` skips a texture until then, so a texture can be loaded at any time.

8. **Fixed: sprite batches had hard limits.** `SpriteBatch` used to panic above 8192 sprites or 256 texture switches in one frame. Its vertex storage, batch list, and GPU buffers now double when they fill. The one ceiling left is SDL's 32-bit buffer size, about 33 million sprites in one frame.

9. **Fixed: the package file list omitted build inputs.** `.paths` in `build.zig.zon` now includes `shaders` and `vendor`, which the build needs. `assets` stays out, since the build doesn't read it.

10. **Fixed: the SPIR-V version was not pinned.** `build.zig` now passes `-profile spirv_1_5` to `slangc`, the version that matches the Vulkan 1.2 request made at runtime.

11. **Fixed: `renderer/view.zig`'s tests didn't run.** `src/tests.zig` imports `renderer/view.zig`, so its tests run with `zig build test`.

12. **Zoom recreates the native target.** A zoom step that changes the view size rebuilds the native target and waits for the GPU to go idle, as a window resize does. Zoom eases over a fraction of a second, so one zoom can cause several rebuilds. The target is small, so this should be cheap, but it has not been measured. In fit mode a fractional zoom leaves some native pixels one screen pixel larger than others, as fit mode already does. Integer mode rounds zoom to whole scales, so its steps are coarser than fit mode's, and at a base scale of 1 it cannot zoom out at all.

13. **Complex shaping isn't supported.** TrueType and OpenType CFF outlines can be rasterized and kerning is applied, and `Canvas.layoutText` provides wrapping and line alignment, but glyph placement remains one Unicode codepoint per glyph. Tamil and other complex scripts that need substitutions or contextual positioning won't render correctly.
14. **GPU timing stalls the CPU.** `Config.gpu_timing` waits for each frame to finish on the GPU, so CPU and GPU work don't overlap in that mode. The engine has no per-pass GPU timing, because the SDL GPU API it uses shows no timestamp queries in the code. Confirm this against the pinned SDL version.

## Roadmap

### Phase 1: finish the vertical slice

- [x] Draw the warrior from `assets/warrior_16x32.png` with 16×32 source frames and directional walk animation.
- [x] Fix one-shot input and add press and release detection.
- [x] Map keys to named actions.
- [x] Move the player and game state out of `main.zig`.
- [x] Separate fixed-timestep updates from rendering.
- [x] Add an integer-scale option for pixel-perfect output.

### Phase 2: a playable map

- [x] Store tile IDs per cell and per layer, loaded from a simple custom text format. Importing Tiled exports is not started.
- [x] Tile collision with axis-separated movement.
- [x] Multiple layers: ground, decoration, and foreground. The player is drawn between decoration and foreground.
- [x] Camera zoom. Eased, bounded by `zoom_min` and `zoom_max`, and bound to keys.
- [x] Advanced animation state and per-entity animation data. Clips and an animator per entity are done. Blending between clips and animation events are not.

### Phase 3: engine infrastructure

- [x] Texture atlas with packing at build time.
- [x] Index buffer for quads (4 vertices instead of 6). The vertex and index buffers grow together.
- [x] Sprite flip, rotation, origin, per-sprite alpha, and z-order, passed as `drawSprite` options.
- [x] Entity system: AoS and SoA vectors under a handle-based world. The player is not migrated yet.
- [ ] Asset manager with caching. Executable-relative paths already work. The cache module exists in `assets/cache.zig`, but the game doesn't load its textures through it yet.
- [x] Asynchronous texture uploads.
- [x] Shader embedding at build time.
- [x] Audio through SDL3 audio streams, with PCM WAV support and optional build-encoded IMA ADPCM sidecars. The demo loops its wind ambience and exposes master volume through the UI slider. Positional voices, with distance falloff and pan, are queued a tenth of a second ahead so that moves are heard promptly.
- [ ] Text rendering and basic UI widgets.
- [ ] On-screen debug overlay with a frame-time graph, replacing the title stats.
- [x] Profiling zones (for example Tracy), and log file output.
- [x] Settings file for resolution, fullscreen, vsync, and key bindings.
- [x] Unit tests wired into `zig build test`.

### Phase 4: platforms and tooling

- [x] Compile shaders to DXIL (Direct3D 12) alongside SPIR-V, opt-in with `-Ddxil=true`, and enable that device format.
- [x] Compile shaders to MSL (Metal) and enable that device format, opt-in with `-Dmetal=true`.
- [x] Linux and macOS native build coverage and continuous integration in `.github/workflows/ci.yml` (the workflow also covers Windows).
- [x] Cross-platform checkerboard keyer replacing `key_checker.ps1` (`tools/assets/keyer.c`, `zig build asset-keyer`).
- [x] Sprite import workflow (`zig build asset-import`): validate, copy, and register an image for the atlas. It preserves the source format and does not transcode or compress assets.
- [ ] Level editor and Tiled map import.
- [x] Save and load with versioned Parson JSON; F5 saves and F9 loads.

### Phase 5: build-time content pipeline

MonoGame's MGCB is a useful comparison for the missing layer: it processes source content into runtime-ready assets. Bairava compiles shaders, packs sprites into an atlas, and has a sprite importer. The manifest-driven `zig build asset-build` step turns source assets into GPU texture variants (RGBA8, BC1, BC3, and ASTC when `astcenc` is available) and IMA ADPCM audio sidecars, with a generated index. The importer only copies and registers an image; it does not transcode it. At runtime, the best texture variant the device can sample is chosen, and audio prefers the IMA sidecar, falling back to WAV, then converts to the active device format.

The engine is currently a 2D project, so prioritize textures, audio, and fonts rather than 3D model conversion. Keep source assets editable, and make generated outputs reproducible from a content manifest and selected build target.

- [x] Add a general, manifest-driven asset build step that validates source assets, tracks dependencies, and emits runtime-ready outputs with a generated asset index.
- [x] Transcode and compress textures for supported GPU formats, including BC1/BC3 and ASTC where available. Keep an RGBA8 fallback and select an output the active SDL GPU device can load.
- [x] Convert or encode source audio into smaller runtime assets and load those formats through the audio system; retain WAV input for simple or uncompressed assets.
- [x] Move font processing toward build-time outputs and metadata so runtime loading can use preprocessed font assets where appropriate.
- [x] Defer 3D model processing until the engine has a 3D rendering path and model-based content to support.

### Phase 6: native and vector font processing

- [x] Complete SpriteFont support for native TTF/OTF inputs, including CFF outlines.
  - [x] Preprocess configurable codepoint ranges into packed bitmap or SDF atlases with kerning metadata (`.bfnt` v2/v3).
  - [x] Rasterize and cache missing glyphs from TrueType outlines at runtime, growing and refreshing the GPU atlas.
  - [x] Render and scale SDF glyphs through the sprite shader.
  - [x] Add FreeType rasterization for CFF-based OpenType fonts, including dynamic glyph caching.

## Conventions

- Units: world, camera, and sprite positions are in native pixels, and time is `f32` seconds.
- Game `update` runs at the fixed rate `update_hz` in `game/config.zig`, and `ctx.dt` is that step. `draw` runs once per frame and gets `alpha`, which blends between the last two updates.
- Asset paths are relative to the executable's folder. The build installs `assets/` to `zig-out/bin/assets/`, along with the packed `atlas.png` and `atlas.txt`, so a path such as `assets/atlas.png` works from any directory.
- `assets/warrior.png` is the original source art; the build packs the prepared 80×128 `assets/warrior_16x32.png` sheet into the atlas instead.
- SDL's C header is imported once in `platform/sdl/sdl.zig`. SDL imports and names are allowed in `platform/sdl/`, the forwarding contract, `src/tests.zig` backend-test imports, and the SDL GPU backend in `renderer/backends/sdl_gpu/`; Linux CI enforces this list with `scripts/boundary_scan.py --fail`. Core code uses the platform facade and renderer-owned values, not SDL declarations. Unrelated C integrations such as cglm, Parson, stb_image, and the UI bridge are outside this SDL boundary. Only `core/math.zig` imports cglm's headers, and only `profiling/profile.zig` imports ztracy.
- The C code for text and widgets lives in `src/engine/ui/` and never touches SDL or the GPU. `text.c` uses stb_truetype for TrueType and FreeType for CFF-capable font rasterization; `vendor/stb_truetype_impl.c` provides stb_truetype's implementation. `ui/ui.zig` is the one bridge from that code to the sprite batch.
- `core/math.zig`, `memory/string.zig`, `memory/hash_map.zig`, `assets/registry.zig`, `assets/cache.zig`, `assets/loaders/atlas.zig`, `memory/vector.zig`, `ecs/entity.zig`, `renderer/view.zig`, `scene/tilemap.zig`, `scene/scene_manager.zig`, `physics/collision.zig`, `physics/queries.zig`, `renderer/camera.zig`, `animation/animation.zig`, `audio/voices.zig`, `input/input.zig`, `input/gamepad.zig`, `input/action.zig`, and `input/mapping.zig` are device-independent and have unit tests. Keep new pure code the same way when you can. Platform backend and renderer GPU tests may use SDL declarations but do not open a window or create a GPU device.
- Asset names and paths are validated once, when they're registered, and nothing downstream checks them again.
- Engine code lives in `src/engine/` and never names a game type. Game code lives in `src/game/` and uses the engine only through `engine/core/engine.zig`.
- Startup failures (configuration, window, GPU device, and the game's `init`) are logged, release what was opened, and come back from `engine.run` as an error. GPU resources created once the device is running (textures, shaders, pipelines, buffers) panic with the SDL message, because the engine can't continue without them. Asset loaders return Zig errors. Ownership rules are in `docs/ownership.md`.
- Capacity limits are constants that panic when exceeded, so overflows are caught early.
- Log with `engine.log.scoped`, and check invariants with `engine.log.assert`. Don't use `std.debug.assert`, which is undefined behavior in release builds.
- GPU objects are released by their `deinit`. Resources in the engine loop and in the game's `deinit` are released with `defer`, in reverse order of creation.
- Comments explain why. Public items have doc comments.

Update the status table when a module changes, so this file stays useful.
