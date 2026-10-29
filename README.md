# Bairava

A 2D pixel-art game engine in progress, written in Zig. It draws a tile map at a fixed native resolution, scales it to any window size with nearest-neighbor filtering, and lets a player walk around while a camera follows and zooms. Rendering goes through SDL3's GPU API, with shaders written in Slang and compiled to SPIR-V, and optionally to DXIL for Direct3D 12.

⚠️ The engine is not stable for production use (yet).

The package is named `Bairava` in `build.zig.zon`, the executable is `Semkootru`, and the window title is `Semkootru`.

**Status:** early prototype. The rendering path works end to end, and one animated character walks a tile map while the camera follows. Gameplay systems such as entities, collision, audio, and UI have not been started.

## Contents

- [Requirements](#requirements)
- [Building and running](#building-and-running)
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
- **A GPU driver with Vulkan support.** SPIR-V shaders are always built, so by default SDL selects a Vulkan backend, and the renderer requests Vulkan 1.2. Building with `-Ddxil=true` also embeds DXIL shaders and lets the device accept them, which is the route to Direct3D 12 (see Known issues).
- **Internet access for the first build**, so Zig can fetch SDL3. Later builds work offline.
- **`vendor/stb_rect_pack.h` and `vendor/stb_image_write.h`**, used by the build to pack the texture atlas. Both are single-file libraries from [nothings/stb](https://github.com/nothings/stb). Fetch them once before the first build: `curl -L -o vendor/stb_rect_pack.h https://raw.githubusercontent.com/nothings/stb/master/stb_rect_pack.h`, and the same for `stb_image_write.h`.
- **Optional:** Windows PowerShell with .NET's `System.Drawing`, for the asset script.

## Building and running

Run commands from the project root. The build installs `assets/` beside the executable in `zig-out/bin/assets/`, and shaders are embedded in the executable, so the game runs from any directory.

```
zig build                          # compile the executable and shaders into zig-out/
zig build run                      # build and launch the game
zig build run -Dgpu-debug=true     # launch with SDL GPU validation enabled
zig build -Ddxil=true              # also compile DXIL shaders for Direct3D 12
zig build test                     # run unit tests (no GPU or window; links SDL and needs slangc)
```

`zig build` installs `zig-out/bin/Semkootru(.exe)`. The compiled shaders are embedded in that executable, so `zig-out/shaders/` is no longer written. `zig build` also packs the sprites listed in `atlas_sprites` in `build.zig` into `zig-out/bin/assets/atlas.png`, and writes where each sprite sits to `atlas.txt` beside it.

## Debugging

Logs print to stderr, so `zig build run` shows them in the terminal. Each line has a timestamp, a level, and a scope:

```
[    1523ms] INFO  engine: window 960x540, native view 320x180, 60 update steps per second
```

Levels, from least to most severe, are `debug`, `info`, `warn`, and `err`. Debug builds show every level. Other builds show `info` and up. To change the threshold, assign to `engine.log.min_level`, a `pub var`, for example at the top of `main` in `main.zig`.

Assertions check invariants. A failed one prints the file and line, then panics with a stack trace. They run in Debug and ReleaseSafe builds and are compiled out in ReleaseFast and ReleaseSmall. Use `engine.log.assert(ok, @src(), "message {d}", .{value})` for a condition that should hold, and `engine.log.fail(@src(), "message", .{})` for code that should never run.

## Controls

| Input | Action |
|---|---|
| Arrow keys, or W A S D | Move |
| Esc | Quit |
| F11 | Toggle fullscreen |
| I | Toggle integer scale |
| = or keypad + | Zoom in |
| - or keypad - | Zoom out |
| 0 | Reset zoom to 1× |
| Left mouse button | Captured as `Input.left_clicked`, but no action uses it yet. Clicks don't record a position (see Known issues, item 1). |

Keys are bound to named actions in `game/controls.zig`.

## Project structure

```
.
├── build.zig                  Build graph: SDL3, stb_image, cglm, shader compilation and embedding (SPIR-V, plus DXIL with `-Ddxil=true`), the texture atlas, run and test steps
├── build.zig.zon              Package manifest and pinned dependencies
├── src/
│   ├── main.zig               Entry point: hands the game to the engine
│   ├── engine/                Reusable engine code. Never names a game type.
│   │   ├── engine.zig         Public engine API: window, fixed-timestep loop, scale modes, Config, Context, DrawContext
│   │   ├── sdl.zig            The only SDL3 C import
│   │   ├── renderer.zig       GPU device, swapchain, command buffers, render passes
│   │   ├── shader.zig         Picks a shader format (SPIR-V, then DXIL) and creates GPU shaders from embedded code
│   │   ├── texture.zig        2D textures, render targets, nearest-neighbor sampler
│   │   ├── image.zig          Decodes image files to RGBA8 with stb_image
│   │   ├── sprite.zig         Batched textured quads, sprite pipeline, vertex upload
│   │   ├── camera.zig         View position, follow target, smoothing, edge clamping, zoom easing
│   │   ├── animation.zig      Sprite-sheet clips and the animator that plays them
│   │   ├── input.zig          Key enum, held, pressed, and released state, mouse events
│   │   ├── view.zig           Fits the view to the window for each zoom and scale mode, and maps mouse positions from window to view and world
│   │   ├── log.zig            Logging and assertions for debugging
│   │   ├── math.zig           cglm wrappers: projection, transforms, normalization. The only cglm import.
│   │   ├── string.zig         Validated fixed-capacity Name and Path types
│   │   ├── hash_map.zig       StringMap: open-addressing hash map keyed by Name
│   │   ├── assets.zig         Asset Table: names to ids and validated paths
│   │   ├── asset_cache.zig    Asset cache: loads each asset once, reference counts, unloads unused entries
│   │   ├── atlas.zig          Texture atlas index: the rectangle of each sprite in the atlas image
│   │   ├── vector.zig         Custom struct vectors in AoS or SoA layout, with strided column views
│   │   ├── entity.zig         Entity world: component rows, generational handles, swap-remove despawn
│   │   └── tilemap.zig        Tile map format and parser, layers, solid tiles, box movement against tiles
│   ├── game/                  Gameplay code. Uses the engine only through engine/engine.zig.
│   │   ├── game.zig           Game state, asset loading, update and draw
│   │   ├── controls.zig       Named actions and the keys bound to them
│   │   ├── player.zig         Player position, facing, walk clips, drawing
│   │   ├── level.zig          Level: loads the tile map, draws one layer at a time with view culling
│   │   └── config.zig         Title, window and native sizes, level path, background color, update rate, scale mode, camera rate, zoom limits and step, asset list
│   ├── root.zig               Unused template file from `zig init`
│   └── tests.zig              Test root for `zig build test`: every unit test. Pure modules, plus input and renderer, which import SDL. Opens no window.
├── shaders/
│   └── default.slang          Sprite vertex and fragment shaders. Compiled once per target, and `-DDXIL_TARGET` selects the D3D12 sampler layout
├── tools/
│   └── atlas/
│       └── pack.c             Build-time texture atlas packer (stb_rect_pack). Writes atlas.png and atlas.txt
├── assets/
│   ├── tile.png               Tile texture used by the map, packed into the atlas at build time
│   ├── warrior.png            Original warrior artwork (kept unchanged)
│   ├── warrior_16x32.png      Sprite sheet, 5 columns × 4 rows of 16×32 cells, packed into the atlas at build time
│   └── maps/level1.txt        Level 1 tile map: layers of tile IDs, solid tiles, spawn cell
├── scripts/
│   └── key_checker.ps1        Windows tool that keys out a checkerboard background
├── vendor/                    stb_image.h and stb_image_impl.c; stb_image_write.h and stb_rect_pack.h for the atlas packer; cglm (headers, C sources, license) in vendor/cglm/
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

The loop is in `engine/engine.zig`. Game logic runs at a fixed rate, and drawing runs once per frame.

1. Measure the frame time since the last frame, capped at 0.1 s.
2. Drain the SDL event queue. The engine handles quit requests and F11. Key and mouse events update the held state, and presses, releases, and clicks wait in `Input` for the next update step.
3. Add the frame time to an accumulator. While it holds at least one fixed step (1/60 s by default), latch the pending input so it reaches exactly one update, run game `update` with `ctx.dt` set to that step, and subtract the step. Stop early if the game sets `running` to false.
4. Game `update`: read actions from `game/controls.zig`. Quit, scale toggle, and zoom act on their press. Movement actions move the player at 80 px/s, with diagonals normalized, and solid tiles stop the player's feet on each axis, so the player slides along walls.
5. Compute `alpha`, the leftover fraction of a step, from 0 to 1. Drawing blends between the last two updates with it, so motion stays smooth when the display rate and update rate differ.
6. Read the window size in pixels. If either side is zero, the window is minimized, so sleep for 16 ms (`idle_sleep_ms` in `engine/engine.zig`) and start the next frame. Otherwise, ease the camera's zoom toward the zoom the game asked for, choose the scale for the current scale mode and zoom (see Rendering model), then compute the view size. The reference native view is 320×180 in `game/config.zig`.
7. If the view size changed, wait for the GPU to go idle and recreate the native target.
8. Acquire a command buffer and swapchain texture. If either is unavailable, sleep for the same 16 ms and start the next frame, so a minimized window doesn't spin.
9. Pass 1: game `draw` points the camera at the player's blended center and queues the visible tiles and the player. The engine uploads the vertices and draws them into the native target.
10. Pass 2: queue one quad that stretches the native target across the window. In fit mode it covers the whole window. In integer mode it covers a centered whole-number multiple of the view.
11. Submit the command buffer. Every 0.5 s, refresh the window title with FPS, sprite count, draw calls, scale, scale mode, and view size.

### Coordinate systems

- **World space** is in native pixels, with the origin at the map's top-left corner and y increasing downward. Tiles are 16 px.
- **Camera** `x` and `y` give the world position of the view's top-left corner. They keep fractions while the camera eases. Each sprite and tile rounds its screen position once, with `Camera.screenX` and `screenY`, so everything stays on whole pixels without the camera stepping on its own.
- **Sprite destinations** are in view pixels, so world positions have the camera subtracted. `SpriteBatch` multiplies them by the projection from `math.ortho2d`, which gives normalized device coordinates with y pointing up.
- **Sprite sources** are in texels. `drawSprite` converts them to 0 to 1 UV coordinates.
- **Tint** is an RGB multiplier, and **alpha** is a separate per-sprite multiplier. Both are set through `drawSprite`'s options.
- **Zoom** changes the view size, not the world units. At zoom 2 the view covers half as many world pixels, so the camera, culling, and mouse mapping need no zoom-specific code.
- **Mouse** positions from SDL are in window points. `Context.mouseWorld` converts them to world pixels, using the layout and camera of the last frame drawn.

## Libraries and tools

| Name | Version | Used for | License |
|---|---|---|---|
| Zig | 0.16.0-dev, pinned by `minimum_zig_version` | Language, build system, standard library | MIT |
| SDL3 | 3.4.2, via the `sdl` 0.4.0 Zig wrapper on Codeberg (`brodo/SDL`), pinned to commit `95a338c` in `build.zig.zon` | Window, events, keyboard state, SDL_GPU API, file loading, timing, memory | zlib |
| stb_image | Vendored in `vendor/` | Decoding PNG and other image formats to RGBA8 | Public domain or MIT |
| stb_image_write | Vendored in `vendor/` | Writing `atlas.png` in the build's atlas packer | Public domain or MIT |
| stb_rect_pack | Vendored in `vendor/` | Packing sprites into the texture atlas at build time (`tools/atlas/pack.c`) | Public domain or MIT |
| cglm | 0.9.7, vendored in `vendor/cglm/`: headers, the 46 C sources its CMake lists, and its license | Vector and matrix math, the pixel projection, and transforms | MIT |
| Slang (`slangc`) | Installed separately, on `PATH` | Compiles `shaders/default.slang` to SPIR-V (pinned to the SPIR-V 1.5 profile) and, with `-Ddxil=true`, to DXIL (`sm_6_0`) | Apache 2.0 with LLVM exception |
| Vulkan | System driver, selected by SDL_GPU | GPU backend that runs the SPIR-V shaders | Driver, not bundled |
| Direct3D 12 | System driver, selected by SDL_GPU | Optional GPU backend that runs the DXIL shaders | Driver, not bundled |
| PowerShell and System.Drawing | Windows | `scripts/key_checker.ps1` | Windows built-in |

## Progress

### Implemented

**Platform and application**
- SDL3 initialization and a resizable, high-DPI window that starts at 960x540.
- Quit on window close or Esc. F11 toggles fullscreen.
- Fixed-timestep update loop (60 steps per second by default) with an accumulator. Frame time is capped at 0.1 s, and `draw` gets an interpolation factor.
- Live stats in the window title.
- A minimized window idles instead of spinning the CPU.

**GPU and shaders**
- GPU device creation with a Vulkan 1.2 request, SPIR-V shaders (plus DXIL when built with `-Ddxil=true`), and an optional validation layer (`-Dgpu-debug`).
- Swapchain claim, command buffer acquire and submit, and clear-color render passes.
- A build step that compiles two Slang entry points to SPIR-V, and to DXIL when `-Ddxil=true` is set, and embeds them in the executable.
- Shader loading that picks the first format the device accepts (SPIR-V first, then DXIL). Shader code is embedded in the executable at build time, aligned for 32-bit word reads, and each shader's entry point and resource counts are declared as a `shader.Source` beside the pipeline in `sprite.zig`.
- One sprite shader: the texture sample multiplied by the vertex color.

**Textures and images**
- PNG decoding through stb_image, converted to RGBA8.
- Texture upload through a transfer buffer, queued without waiting for the GPU.
- Render-target textures in the swapchain format.
- Nearest-neighbor sampler with clamp-to-edge addressing.
- Assets installed beside the executable and loaded through `SDL_GetBasePath`, so the game runs from any directory.
- Build-time texture atlas: `tools/atlas/pack.c` packs the sprites listed in `atlas_sprites` (`build.zig`) into one square PNG with stb_rect_pack. The square is the smallest power of two that fits, and each sprite has one transparent texel of padding on every side. `engine/atlas.zig` reads the index written beside the image, and the game draws every sprite from that one texture.

**2D rendering**
- Sprite batching: quads buffered per frame as four vertices drawn through an index buffer, one draw call per run of the same texture, alpha blending, tint, source rectangles, and no fixed sprite or texture-switch limit.
- Per-sprite options through `drawSprite`: flip, rotation around an origin, alpha, and z-order. Sprites are sorted by z once per frame, and sprites with equal z keep the order they were added in.
- Tile world rendering with view culling and a one-tile margin.
- Camera follow with frame-rate-independent smoothing, edge clamping, pixel snapping, and centering when the world is smaller than the view.
- Camera zoom from keys. Each press multiplies or divides the zoom by 1.25, and the camera eases to the new zoom in logarithmic steps. Zoom changes the view size, so the camera, culling, and mouse mapping work unchanged. Integer mode rounds the zoomed scale to a whole number.
- The two-pass pixel-art pipeline: native target, then stretch to the window.
- Fit and integer scale modes, set in `game/config.zig` or toggled with I.

**Math and data**
- cglm for vectors and matrices, wrapped in `math.zig`. The sprite projection and diagonal normalization use it. `math.zig` also covers 3D transforms, perspective and look-at matrices, and quaternions (slerp, look rotation, billboard). Only the 2D parts are used so far.
- Validated names and paths (`string.zig`), a hash map keyed by names (`hash_map.zig`), and an asset table that gives each name a dense id (`assets.zig`).
- Tile maps (`tilemap.zig`): a text format with three layers (ground, decoration, foreground), tile IDs, empty cells written as `.`, solid IDs, and a spawn cell. Malformed maps report what is wrong. `TileMap.moveBox` moves a box against solid tiles, one axis at a time.
- Sprite-sheet animation (`animation.zig`): clips that name a row of frames, with frame time and loop mode, and an animator per entity.
- `zig build test` runs every unit test: the string, hash map, asset table, math, view, tile map, camera, animation, input, and renderer modules. It links SDL and opens no window or GPU device.
- Mouse mapping from window points to view and world pixels in `view.zig`, through `Context.mouseWorld`. Its tests run with `zig build test`.

**Gameplay**
- Player movement with arrow keys or WASD, normalized diagonals, and collision with solid tiles.
- A 16×32 South Indian warrior sprite loaded from `assets/warrior_16x32.png`, with separate player width and height constants.
- Directional sprite selection for front/down, right, back/up, and left; horizontal input wins when moving diagonally.
- Walk clips with frame 0 shown while idle; the back-facing row cycles through four frames. Changing clip restarts it at its first frame.

**Tooling**
- `-Dgpu-debug` and `-Ddxil` build options.
- `scripts/key_checker.ps1` is a legacy checkerboard-removal tool for the older character art. The current warrior runtime sheet is `assets/warrior_16x32.png`; `assets/warrior.png` is retained as the untouched source artwork.

### Module status

These estimates are rough. They measure how close each area is to something usable for a small 2D game, not how much code it has.

| Area | File | Status | Est. done | Notes |
|---|---|---|---|---|
| Platform | `sdl.zig` | Complete | 100% | Single C-import point for SDL3. |
| Engine | `engine/engine.zig` | Prototype | 65% | Window, GPU setup, native-view pipeline, fixed-timestep loop, fit and integer scaling, camera zoom, and the `Game` interface. Missing: scene or state system, device-lost recovery. |
| Logging and assertions | `engine/log.zig` | Functional | 70% | Levels, scopes, timestamps, and assertions that check in Debug and ReleaseSafe. Missing: log file output, profiling zones. |
| Gameplay | `game/` | Prototype | 20% | Player with directional walk clips, one level loaded from `assets/maps/level1.txt` and drawn in layers, and movement and quit actions bound in `game/controls.zig`. No entities or rules. |
| Renderer | `renderer.zig` | Solid base | 70% | Device, swapchain, and passes work. Asks the device for DXIL only when the build embeds it. Pass settings are unit tested. Device and frame calls need a GPU and aren't. Missing: device-lost recovery, Metal support, pass helpers. |
| Shaders | `shader.zig` | Basic | 55% | Picks the first shader format the device accepts (SPIR-V, then DXIL) and creates GPU shaders from code embedded at build time. DXIL is optional (`-Ddxil=true`). Per-shader entry points and resource counts are declared in `sprite.zig`. Missing: MSL, reflection. Uniform buffer count is supported but unused. |
| Textures | `texture.zig` | Solid base | 70% | Uploads queue without waiting, and `isReady` reports when one finishes. Missing: unload and reload. |
| Atlas | `atlas.zig`, `tools/atlas/pack.c` | Functional | 60% | Build-time packing with stb_rect_pack, index parsing with validation, and lookup by name. Missing: runtime packing, several atlas pages, rotated sprites. |
| Images | `image.zig` | Basic | 60% | PNG and other formats through stb_image to RGBA8. Synchronous, relative paths only. |
| Math | `math.zig` | Functional | 60% | cglm wrappers: identity, mul, invert, transpose, translate, scale, rotate, ortho, perspective, look-at, point and vector transforms, 3D vector helpers, and quaternions (slerp, look rotation, billboard). 18 tests. Only the 2D parts are used so far. |
| Strings | `string.zig` | Functional | 70% | Validated `Name` (up to 64 bytes) and `Path` (up to 255 bytes, null-terminated). Rules are in the file's doc comments. |
| Hash map | `hash_map.zig` | Functional | 70% | Open addressing with full key comparison, growth at 3/4 load, removal by backward-shift deletion (no tombstones), checked against `std.StringHashMap`. |
| Assets | `assets.zig` | Early | 40% | Names, dense ids, and validated paths. The game no longer uses it, since its sprites come from the atlas. Loading and caching are in `asset_cache.zig`, which looks assets up by these names. |
| Asset cache | `asset_cache.zig` | Early | 50% | Generic cache keyed by asset name: reference counts, load on first `acquire`, and `unloadUnused`. Names and paths come from `assets.zig`, and the index is the engine's `StringMap`. Not yet compiled or run, and not yet used by the engine or game. Missing: GPU textures through the cache, unloading on a schedule, hot reload. |
| Sprites | `sprite.zig` | Functional | 75% | Batched quads with four vertices each and a 32-bit index buffer. Per-sprite tint, alpha, flip, rotation around an origin, and z-order, sorted once per frame. Storage grows with each frame. Missing: instancing. |
| Camera | `camera.zig` | Functional | 75% | Follow, frame-rate-independent smoothing, clamp, per-sprite pixel rounding, and eased zoom. Missing: dead zone, shake. |
| Animation | `animation.zig` | Functional | 60% | Clips with a row, frame count, frame time, and loop mode, plus an `Animator` per entity that restarts only when its clip changes. Missing: blending between clips, animation events. |
| Level | `game/level.zig` | Early | 50% | Tile map drawn one layer at a time with culling, in ground, decoration, player, foreground order. Solid tiles block the player. No tile animation. |
| Tile map | `engine/tilemap.zig` | Functional | 70% | Text map format with clear parse errors, three layers, empty cells, solid IDs on any layer, a spawn cell, and box movement that stops at solid tiles, one axis at a time. Missing: Tiled import. |
| Input | `input.zig` | Functional | 60% | Held, pressed, and released keys work through the `Key` enum, and one-shot input reaches exactly one update step. Clicks are captured but have no position yet. `mouse_x` and `mouse_y` are window points; use `Context.mouseWorld` for world coordinates. No gamepad or text input. Unit tests are in `src/tests.zig`. |
| View mapping | `view.zig` | Functional | 70% | Fits the native view to the window for each zoom and scale mode (`chooseFit`). Converts mouse positions from window points to view and world pixels, using the rectangle the view is drawn into. Pure math with its own tests, run by `zig build test`. |
| Build | `build.zig` | Functional | 60% | Builds SDL3, stb_image, cglm, embedded shaders (SPIR-V, and DXIL with `-Ddxil=true`), the texture atlas, the run step, and the test step. Installs `assets/` beside the executable. Missing: a Metal (MSL) shader target. |
| Assets | `scripts/key_checker.ps1` | One-off tool | 15% | Windows only, one hardcoded file pair. Not an asset pipeline. |
| Tests | `src/tests.zig` | Functional | 50% | Every unit test, run by `zig build test`: string, hash map, assets, math, view, tile map, camera, animation, input, and renderer. Missing: tests that open a window or create a GPU device. |
| Vector | `vector.zig` | Functional | 60% | Generic struct vector in AoS or SoA, one allocation for either layout, strided column views that work under both, and contiguous `items` under SoA. Missing: shrinking, sorting, and removal of unused capacity. |
| Entities | `entity.zig` | Functional | 45% | World of component rows with generational handles, dense rows, and swap-remove despawn that repairs the handle of a moved row. The player is still a struct in `game/player.zig`, so no game code uses the world yet. Missing: spawning from level data, queries, and component tags. |
| Collision | none | Not started | 0% | |
| Audio | none | Not started | 0% | |
| UI and text | none | Not started | 0% | |
| Scenes and state | none | Not started | 0% | |

## Building on what exists

These are the natural extension points. Each one reuses existing code.

**Character sprite and animation.** The warrior is a region of the texture atlas, found by name at startup, and drawn through the existing `drawSprite` source-rectangle API, offset by that region. Each cell is 16×32 pixels. `game/player.zig` keeps a facing and an `engine.animation.Animator`. Each update, `clipFor` picks the clip for the facing and whether the player is moving, and the animator restarts only when the clip changes. The back-facing row uses four frames, while the other rows use five, and the clip for standing still shows frame 0. To add an animation, define a `Clip` (sheet row, frame count, frame time, loop mode) and select it in `clipFor`.

**Add a tile layer.** Layers are the `Layer` enum in `engine/tilemap.zig`, and `all_layers` lists them. To add one, add an enum value and its name to `parseLayer`, then call `Level.drawLayer` for it in `Game.draw` at the point in the draw order where it belongs. A solid ID on any layer blocks movement.

**Add collision to an entity.** Give the entity a `tilemap.Box` and call `TileMap.moveBox` with its movement each update, the same way `Player.update` does. Map edges count as solid, so they act as walls.

**Add camera effects.** The camera is a position and a view size. `followSmooth` eases toward the clamped target, and `camera_rate` in `game/config.zig` sets how fast. Shake is an offset applied after `follow`. Zoom is already in place: `Context.zoomBy` and `resetZoom` set the target, `engine/engine.zig` eases `Camera.zoom` toward it each frame, and `view.chooseFit` turns the zoom into a scale and a view size. Drawing and culling read the view size, so they need no changes. To change the limits or the step, edit `zoom_min`, `zoom_max`, `zoom_step`, and `zoom_rate` in `game/config.zig`.

**Add input actions.** Add a name to `Action` in `game/controls.zig`, bind its keys in `keysFor`, and query it with `controls.held`, `controls.pressed`, or `controls.released`. Gameplay never checks a key directly. To use a key the engine doesn't know yet, add it to `Key` in `engine/input.zig` and map it to its SDL scancode.

**Add a shader or pipeline.** Add the entry point to `shaders/default.slang`, because `build.zig` compiles only that file (to compile another file, give `ShaderEntry` a source path). Add a row for each entry point to `shader_entries` in `build.zig`, and declare a `shader.Source` in `sprite.zig` with the stage, resource counts, and embedded code for both formats (for example `.code = .{ .spirv = embedded.default_vert, .dxil = embedded.default_vert_dxil }`; the DXIL slice is empty unless the build used `-Ddxil=true`). If the shader samples a texture, follow the `DXIL_TARGET` split in `default.slang`, since Vulkan and D3D12 declare samplers differently. Load it with `shader.load` and create a pipeline the way `SpriteBatch.init` does. Pipelines are built for a specific shader pair and color format, so a second one needs its own init.

**Add a render target.** `Texture.initTarget` creates a target in the swapchain format. Pass it to `Renderer.beginPass` to draw into it, then sample it like any other texture. Use this for lighting, post-processing, or a minimap.

**Add a sprite.** Add a `.{ .name, .file }` row to `atlas_sprites` in `build.zig`. The next `zig build` packs it into the atlas. The name must follow the rules in `engine/string.zig`. In the game, look the sprite up once with `Game.atlas_index.find(name)` and keep the returned region. Draw it by offsetting the source rectangle by the region's position in the atlas, as `Level.drawLayer` and `Player.draw` do.

**Add entities.** Define the components as one struct with a field per component value, for example `const Body = struct { x: f32, vx: f32, id: u64 };`. Create a world with `var world = engine.entity.World(Body, .soa).init(allocator)`, choosing `.aos` or `.soa` as the layout (see `engine/vector.zig`). Spawn with `world.spawn(row)`, which returns a `Handle`. Keep the handle, not a row index, because despawning moves rows. A system loops over `0..world.count()` and reads a field with `world.rows.column("vx")`, which works the same under either layout. Under SoA, `world.rows.items("x")` gives a plain slice when a system needs one. Draw entities as `Player.draw` does, subtracting the camera from world positions.

## Known issues

1. **Fixed: mouse coordinates were in window points, not world pixels.** `Context.mouseWorld` converts the mouse position from points to pixels, maps it through the rectangle the view was drawn into (which covers the scale, centering, and rounding), and adds the camera position. Both the layout and the camera come from the last frame drawn, so an update sees what the player saw. Clicks don't store a position yet, so a click handler reads the cursor's last known position.

2. **Fixed: asset paths depended on the working directory.** The build installs `assets/` beside the executable, and `Context.loadTexture` resolves paths against the executable's folder from `SDL_GetBasePath`. Shaders are embedded at build time, so nothing else depends on the working directory.

3. **Fixed: a minimized window spun the CPU.** A zero-size window, or a frame with no swapchain, used to restart the loop without waiting. Both cases now sleep for 16 ms first, so a minimized window idles.

4. **Vulkan is the default backend. Direct3D 12 is opt-in, and Metal isn't supported.** SPIR-V shaders are always built, and the renderer always sets Vulkan 1.2 options. `zig build -Ddxil=true` also compiles DXIL (`sm_6_0`) and tells the device to accept it. `shader.pickFormat` then takes the first format the device accepts, with SPIR-V ahead of DXIL. Metal needs MSL shaders, which don't exist yet. `default.slang` declares its sampler two ways: a combined `Sampler2D` at `[vk::binding(0, 2)]` for Vulkan, and separate `t0` and `s0` registers in space 2 for DXIL, chosen by the `-DDXIL_TARGET` define that `build.zig` passes. Vertex locations are explicit and match the attributes in `sprite.zig`.

5. **Fixed: names didn't match.** The package is `Bairava` in `build.zig.zon`, the executable and window are `Semkootru`, and the sprite shader is `default.slang`.

6. **`root.zig` is template code.** Its functions and test are not used by the game, and `zig build test` runs `src/tests.zig`, which doesn't import it. Delete the file or move real tests into it.

7. **Fixed: texture uploads blocked.** `Texture.initRgba8` used to wait for the GPU to go idle. It now queues the copy and returns. `Texture.isReady` reports when the copy finishes, and `SpriteBatch.draw` skips a texture until then, so a texture can be loaded at any time.

8. **Fixed: sprite batches had hard limits.** `SpriteBatch` used to panic above 8192 sprites or 256 texture switches in one frame. Its vertex storage, batch list, and GPU buffers now double when they fill. The one ceiling left is SDL's 32-bit buffer size, about 33 million sprites in one frame.

9. **Fixed: the package file list omitted build inputs.** `.paths` in `build.zig.zon` now includes `shaders` and `vendor`, which the build needs. `assets` stays out, since the build doesn't read it.

10. **Fixed: the SPIR-V version was not pinned.** `build.zig` now passes `-profile spirv_1_5` to `slangc`, the version that matches the Vulkan 1.2 request made at runtime.

11. **Fixed: `view.zig`'s tests didn't run.** `src/tests.zig` imports `view.zig`, so its five tests run with `zig build test`.

12. **Zoom recreates the native target.** A zoom step that changes the view size rebuilds the native target and waits for the GPU to go idle, as a window resize does. Zoom eases over a fraction of a second, so one zoom can cause several rebuilds. The target is small, so this should be cheap, but it has not been measured. In fit mode a fractional zoom leaves some native pixels one screen pixel larger than others, as fit mode already does. Integer mode rounds zoom to whole scales, so its steps are coarser than fit mode's, and at a base scale of 1 it cannot zoom out at all.

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
- [ ] Asset manager with caching. Executable-relative paths already work. The cache module exists in `asset_cache.zig`, but the game doesn't load its textures through it yet.
- [x] Asynchronous texture uploads.
- [x] Shader embedding at build time.
- [ ] Audio through SDL3 audio streams.
- [ ] Text rendering and basic UI widgets.
- [ ] On-screen debug overlay with a frame-time graph, replacing the title stats.
- [ ] Profiling zones (for example Tracy), and log file output.
- [ ] Settings file for resolution, fullscreen, vsync, and key bindings.
- [x] Unit tests wired into `zig build test`.

### Phase 4: platforms and tooling

- [x] Compile shaders to DXIL (Direct3D 12) alongside SPIR-V, opt-in with `-Ddxil=true`, and enable that device format.
- [ ] Compile shaders to MSL (Metal) and enable that device format.
- [ ] Linux and macOS builds, plus continuous integration.
- [ ] A cross-platform asset tool to replace `key_checker.ps1`.
- [ ] A level editor or import workflow.
- [ ] Save and load.

## Conventions

- Units: world, camera, and sprite positions are in native pixels, and time is `f32` seconds.
- Game `update` runs at the fixed rate `update_hz` in `game/config.zig`, and `ctx.dt` is that step. `draw` runs once per frame and gets `alpha`, which blends between the last two updates.
- Asset paths are relative to the executable's folder. The build installs `assets/` to `zig-out/bin/assets/`, along with the packed `atlas.png` and `atlas.txt`, so a path such as `assets/atlas.png` works from any directory.
- `assets/warrior.png` is the original source art; the build packs the prepared 80×128 `assets/warrior_16x32.png` sheet into the atlas instead.
- Only `sdl.zig` imports SDL's C headers, and only `math.zig` imports cglm's.
- `math.zig`, `string.zig`, `hash_map.zig`, `assets.zig`, `asset_cache.zig`, `atlas.zig`, `vector.zig`, `entity.zig`, `view.zig`, `tilemap.zig`, `camera.zig`, and `animation.zig` don't import SDL or `log.zig`, so they can be tested without a GPU. Keep new pure code the same way when you can, and list its file in `src/tests.zig`. Modules that import SDL are listed there too, and their tests call no SDL function that needs a window or GPU.
- Asset names and paths are validated once, when they're registered, and nothing downstream checks them again.
- Engine code lives in `src/engine/` and never names a game type. Game code lives in `src/game/` and uses the engine only through `engine/engine.zig`.
- Initialization failures and shader or GPU setup errors panic with the SDL message. Image loading returns Zig errors.
- Capacity limits are constants that panic when exceeded, so overflows are caught early.
- Log with `engine.log.scoped`, and check invariants with `engine.log.assert`. Don't use `std.debug.assert`, which is undefined behavior in release builds.
- GPU objects are released by their `deinit`. Resources in the engine loop and in the game's `deinit` are released with `defer`, in reverse order of creation.
- Comments explain why. Public items have doc comments.

Update the status table when a module changes, so this file stays useful.
