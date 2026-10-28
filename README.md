# Bairava

A 2D pixel-art game engine in progress, written in Zig. It draws a tile map at a fixed native resolution, scales it to any window size with nearest-neighbor filtering, and lets a player walk around while a camera follows. Rendering goes through SDL3's GPU API, with shaders written in Slang and compiled to SPIR-V.

⚠️ The engine is not stable for production use (yet).

The package is named `zig_sdl3_slang` in `build.zig.zon`, the executable is `my-game`, and the window title is `My Game`.

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
- **slangc**, the Slang shader compiler, on your `PATH`.
- **A GPU driver with Vulkan support.** The device is created with SPIR-V shaders only, so SDL selects a Vulkan backend, and the renderer requests Vulkan 1.2.
- **Internet access for the first build**, so Zig can fetch SDL3. Later builds work offline.
- **Optional:** Windows PowerShell with .NET's `System.Drawing`, for the asset script.

## Building and running

Run commands from the project root. Shader and asset paths are relative to the working directory.

```
zig build                          # compile the executable and shaders into zig-out/
zig build run                      # build and launch the game
zig build run -Dgpu-debug=true     # launch with SDL GPU validation enabled
zig build test                     # run unit tests (no GPU or SDL needed)
```

`zig build` installs `zig-out/bin/my-game(.exe)` and the compiled shaders in `zig-out/shaders/`.

## Debugging

Logs print to stderr, so `zig build run` shows them in the terminal. Each line has a timestamp, a level, and a scope:

```
[    1523ms] INFO  engine: window 960x540, native view 320x180, 60 update steps per second
```

Levels, from least to most severe, are `debug`, `info`, `warn`, and `err`. Debug builds show every level. Other builds show `info` and up. To change the threshold, set `engine.log.min_level` in `main.zig`.

Assertions check invariants. A failed one prints the file and line, then panics with a stack trace. They run in Debug and ReleaseSafe builds and are compiled out in ReleaseFast and ReleaseSmall. Use `engine.log.assert(ok, @src(), "message {d}", .{value})` for a condition that should hold, and `engine.log.fail(@src(), "message", .{})` for code that should never run.

## Controls

| Input | Action |
|---|---|
| Arrow keys, or W A S D | Move |
| Esc | Quit |
| F11 | Toggle fullscreen |
| I | Toggle integer scale |
| Left mouse button | Captured but not used yet (see Known issues) |

Keys are bound to named actions in `game/controls.zig`.

## Project structure

```
.
├── build.zig                  Build graph: SDL3, stb_image, cglm, shader compilation, run and test steps
├── build.zig.zon              Package manifest and pinned dependencies
├── src/
│   ├── main.zig               Entry point: hands the game to the engine
│   ├── engine/                Reusable engine code. Never names a game type.
│   │   ├── engine.zig         Public engine API: window, fixed-timestep loop, scale modes, Config, Context, DrawContext
│   │   ├── sdl.zig            The only SDL3 C import
│   │   ├── renderer.zig       GPU device, swapchain, command buffers, render passes
│   │   ├── shader.zig         Loads SPIR-V from disk and creates GPU shaders
│   │   ├── texture.zig        2D textures, render targets, nearest-neighbor sampler
│   │   ├── image.zig          Decodes image files to RGBA8 with stb_image
│   │   ├── sprite.zig         Batched textured quads, sprite pipeline, vertex upload
│   │   ├── camera.zig         View position, follow target, edge clamping
│   │   ├── input.zig          Key enum, held, pressed, and released state, mouse events
│   │   ├── log.zig            Logging and assertions for debugging
│   │   ├── math.zig           cglm wrappers: projection, transforms, normalization. The only cglm import.
│   │   ├── string.zig         Validated fixed-capacity Name and Path types
│   │   ├── hash_map.zig       StringMap: open-addressing hash map keyed by Name
│   │   └── assets.zig         Asset Table: names to ids and validated paths
│   ├── game/                  Gameplay code. Uses the engine only through engine/engine.zig.
│   │   ├── game.zig           Game state, asset loading, update and draw
│   │   ├── controls.zig       Named actions and the keys bound to them
│   │   ├── player.zig         Player position, facing, walk animation, drawing
│   │   ├── level.zig          Tile grid, view culling, tile drawing
│   │   └── config.zig         Title, window and native sizes, level size, background color, update rate, scale mode, asset list
│   ├── root.zig               Unused template file from `zig init`
│   └── tests.zig              Test root for `zig build test`. Pure modules only.
├── shaders/
│   └── triangle.slang         Sprite vertex and fragment shaders (the name is legacy)
├── assets/
│   ├── tile.png               Tile texture used by the map
│   ├── warrior.png            Original warrior artwork (kept unchanged)
│   └── warrior_16x32.png      Runtime sprite sheet: 5 columns × 4 rows of 16×32 cells
├── scripts/
│   └── key_checker.ps1        Windows tool that keys out a checkerboard background
├── vendor/                    stb_image.h and stb_image_impl.c; cglm (headers, C sources, license) in vendor/cglm/
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

The native view is never smaller than 320x180 pixels. The window's aspect ratio decides which axis fits exactly: on the limiting axis the view is exactly 320 or 180 pixels, and the other axis shows more of the world. In fit mode the window therefore never has black bars. At the default 960x540 window the scale is exactly 3x, which is the cleanest case for pixel art. Other sizes give fractional scales, so some native pixels cover three screen pixels and others cover four. The default fit mode accepts that trade-off. Integer mode uses a whole-number multiple of the view size, so every native pixel is the same size. The result is centered, and thin black bars fill any leftover space at the edges. Set `scale_mode` in `game/config.zig`, or press I to toggle it.

### Frame lifecycle

The loop is in `engine/engine.zig`. Game logic runs at a fixed rate, and drawing runs once per frame.

1. Measure the frame time since the last frame, capped at 0.1 s.
2. Drain the SDL event queue. The engine handles quit requests and F11. Key and mouse events update the held state, and presses, releases, and clicks wait in `Input` for the next update step.
3. Add the frame time to an accumulator. While it holds at least one fixed step (1/60 s by default), latch the pending input so it reaches exactly one update, run game `update` with `ctx.dt` set to that step, and subtract the step. Stop early if the game sets `running` to false.
4. Game `update`: read actions from `game/controls.zig`. Quit and scale toggle act on their press. Movement actions move the player at 80 px/s, with diagonals normalized, and the player is clamped to the map.
5. Compute `alpha`, the leftover fraction of a step, from 0 to 1. Drawing blends between the last two updates with it, so motion stays smooth when the display rate and update rate differ.
6. Read the window size in pixels. If either side is zero, the window is minimized, so sleep for 16 ms (`idle_sleep_ms` in `engine/engine.zig`) and start the next frame. Otherwise, choose the scale for the current scale mode (see Rendering model), then compute the view size. The native view is 320×180 in `game/config.zig`.
7. If the view size changed, wait for the GPU to go idle and recreate the native target.
8. Acquire a command buffer and swapchain texture. If either is unavailable, sleep for the same 16 ms and start the next frame, so a minimized window doesn't spin.
9. Pass 1: game `draw` points the camera at the player's blended center and queues the visible tiles and the player. The engine uploads the vertices and draws them into the native target.
10. Pass 2: queue one quad that stretches the native target across the window. In fit mode it covers the whole window. In integer mode it covers a centered whole-number multiple of the view.
11. Submit the command buffer. Every 0.5 s, refresh the window title with FPS, sprite count, draw calls, scale, scale mode, and view size.

### Coordinate systems

- **World space** is in native pixels, with the origin at the map's top-left corner and y increasing downward. Tiles are 16 px.
- **Camera** `x` and `y` give the world position of the view's top-left corner.
- **Sprite destinations** are in view pixels, so world positions have the camera subtracted. `SpriteBatch` multiplies them by the projection from `math.ortho2d`, which gives normalized device coordinates with y pointing up.
- **Sprite sources** are in texels. `drawSprite` converts them to 0 to 1 UV coordinates.
- **Tint** is an RGB multiplier. There is no alpha tint.

## Libraries and tools

| Name | Version | Used for | License |
|---|---|---|---|
| Zig | 0.16.0-dev, pinned by `minimum_zig_version` | Language, build system, standard library | MIT |
| SDL3 | 3.4.2, via the `sdl` 0.4.0 Zig wrapper on Codeberg (`brodo/SDL`), pinned to commit `95a338c` in `build.zig.zon` | Window, events, keyboard state, SDL_GPU API, file loading, timing, memory | zlib |
| stb_image | Vendored in `vendor/` | Decoding PNG and other image formats to RGBA8 | Public domain or MIT |
| cglm | 0.9.7, vendored in `vendor/cglm/`: headers, the 46 C sources its CMake lists, and its license | Vector and matrix math, the pixel projection, and transforms | MIT |
| Slang (`slangc`) | Installed separately, on `PATH` | Compiles `shaders/triangle.slang` to SPIR-V; no explicit profile is set (see Known issues) | Apache 2.0 with LLVM exception |
| Vulkan | System driver, selected by SDL_GPU | GPU backend that runs the SPIR-V shaders | Driver, not bundled |
| PowerShell and System.Drawing | Windows | `scripts/key_checker.ps1` | Windows built-in |

## Progress

### Implemented

**Platform and application**
- SDL3 initialization and a resizable, high-DPI window that starts at 960x540.
- Quit on window close or Esc. F11 toggles fullscreen.
- Variable-timestep loop with delta time capped at 0.1 s.
- Live stats in the window title.
- A minimized window idles instead of spinning the CPU.

**GPU and shaders**
- GPU device creation with a Vulkan 1.2 request, SPIR-V shaders, and an optional validation layer (`-Dgpu-debug`).
- Swapchain claim, command buffer acquire and submit, and clear-color render passes.
- A build step that compiles two Slang entry points to SPIR-V.
- A runtime SPIR-V loader that takes sampler and uniform-buffer counts.
- One sprite shader: the texture sample multiplied by the vertex color.

**Textures and images**
- PNG decoding through stb_image, converted to RGBA8.
- Texture upload through a transfer buffer.
- Render-target textures in the swapchain format.
- Nearest-neighbor sampler with clamp-to-edge addressing.

**2D rendering**
- Sprite batching: quads buffered per frame, one draw call per run of the same texture, alpha blending, tint, and source rectangles.
- Tile world rendering with view culling and a one-tile margin.
- Camera follow with edge clamping, pixel snapping, and centering when the world is smaller than the view.
- The two-pass pixel-art pipeline: native target, then stretch to the window.

**Math and data**
- cglm for vectors and matrices, wrapped in `math.zig`. The sprite projection and diagonal normalization use it.
- Validated names and paths (`string.zig`), a hash map keyed by names (`hash_map.zig`), and an asset table that gives each name a dense id (`assets.zig`).
- `zig build test` runs unit tests for these modules without SDL or a GPU.

**Gameplay**
- Player movement with arrow keys or WASD, normalized diagonals, and map clamping.
- A 16×32 South Indian warrior sprite loaded from `assets/warrior_16x32.png`, with separate player width and height constants.
- Directional sprite selection for front/down, right, back/up, and left; horizontal input wins when moving diagonally.
- Walk-frame timing with frame 0 used while idle; the back-facing row cycles through four frames.

**Tooling**
- `-Dgpu-debug` build option.
- `scripts/key_checker.ps1` is a legacy checkerboard-removal tool for the older character art. The current warrior runtime sheet is `assets/warrior_16x32.png`; `assets/warrior.png` is retained as the untouched source artwork.

### Module status

These estimates are rough. They measure how close each area is to something usable for a small 2D game, not how much code it has.

| Area | File | Status | Est. done | Notes |
|---|---|---|---|---|
| Platform | `sdl.zig` | Complete | 100% | Single C-import point for SDL3. |
| Engine | `engine/engine.zig` | Prototype | 60% | Window, GPU setup, native-view pipeline, fixed-timestep loop, fit and integer scaling, and the `Game` interface. Missing: scene or state system, device-lost recovery. |
| Logging and assertions | `engine/log.zig` | Functional | 70% | Levels, scopes, timestamps, and assertions that check in Debug and ReleaseSafe. Missing: log file output, profiling zones. |
| Gameplay | `game/` | Prototype | 15% | Player with directional walk animation, one test level, and movement and quit actions bound in `game/controls.zig`. No entities, rules, or level files. |
| Renderer | `renderer.zig` | Solid base | 70% | Device, swapchain, and passes work. Missing: device-lost recovery, other backends' shader formats, pass helpers. |
| Shaders | `shader.zig` | Basic | 50% | Loads SPIR-V from disk. Missing: embedding, reflection, hot reload. Uniform buffer count is supported but unused. |
| Textures | `texture.zig` | Solid base | 70% | Synchronous upload that waits for GPU idle. Missing: atlases, async uploads, unload and reload. |
| Images | `image.zig` | Basic | 60% | PNG and other formats through stb_image to RGBA8. Synchronous, relative paths only. |
| Math | `math.zig` | Functional | 60% | cglm wrappers: identity, mul, translate, rotate, ortho, transform, normalize. Missing: 3D helpers, quaternions. |
| Strings | `string.zig` | Functional | 70% | Validated `Name` (up to 64 bytes) and `Path` (up to 255 bytes, null-terminated). Rules are in the file's doc comments. |
| Hash map | `hash_map.zig` | Functional | 70% | Open addressing with full key comparison, growth at 3/4 load, checked against `std.StringHashMap`. Missing: removal. |
| Assets | `assets.zig` | Early | 40% | Names, dense ids, and validated paths. Missing: loading, caching, unloading. |
| Sprites | `sprite.zig` | Functional | 60% | Batched quads and source rectangles. Missing: index buffer, rotation, flip, origin, alpha tint, z-order, growable capacity. |
| Camera | `camera.zig` | Functional | 50% | Follow, clamp, and pixel snap. Missing: smoothing, dead zone, zoom, shake. |
| Level | `game/level.zig` | Early | 25% | One uniform layer drawn with culling. No tile data, multiple layers, loading, or collision. |
| Input | `input.zig` | Functional | 60% | Held, pressed, and released keys work through the `Key` enum, and one-shot input reaches exactly one update step. Clicks are captured but not usable yet, and mouse position is in window space (see Known issues). No gamepad or text input. |
| Build | `build.zig` | Functional | 60% | Builds SDL3, stb_image, cglm, shaders, the run step, and the test step. Missing: asset install step, other shader targets. |
| Assets | `scripts/key_checker.ps1` | One-off tool | 15% | Windows only, one hardcoded file pair. Not an asset pipeline. |
| Tests | `src/tests.zig` | Functional | 40% | Unit tests for the pure modules, run by `zig build test`. Missing: tests for SDL-facing code. |
| Entities | none | Not started | 0% | The player is a struct in `game/player.zig`. There is no entity list yet. |
| Collision | none | Not started | 0% | |
| Audio | none | Not started | 0% | |
| UI and text | none | Not started | 0% | |
| Scenes and state | none | Not started | 0% | |

## Building on what exists

These are the natural extension points. Each one reuses existing code.

**Character sprite and animation.** The warrior is loaded once from `assets/warrior_16x32.png` and drawn through the existing `drawSprite` source-rectangle API. Each cell is 16×32 pixels. `game/player.zig` tracks a facing row, walk timer, and frame index; the back-facing row uses four frames, while the other rows use five. Frame 0 is selected while idle.

**Add per-cell tile data.** `Level` already knows its size and culls visible cells. Give it a `[]u16` of tile IDs with `cols * rows` entries. In `draw`, look up each cell's ID, convert it to a source rectangle in the tileset, and keep the same loop. The checkerboard tint is a stand-in for real data and can go.

**Add collision.** Give `Level` a `solid(col, row) bool` query. Move the player along x and resolve against overlapping solid cells, then move along y. The map clamp in `game/player.zig` is a special case: the map edges act as walls.

**Add camera effects.** The camera is a position and a view size. Smoothing is a lerp toward the target before clamping. Shake is an offset applied after `follow`. Zoom changes the native view size that `engine/engine.zig` uses in `fitScale`, and the rest of the pipeline already handles any view size.

**Add input actions.** Add a name to `Action` in `game/controls.zig`, bind its keys in `keysFor`, and query it with `controls.held`, `controls.pressed`, or `controls.released`. Gameplay never checks a key directly. To use a key the engine doesn't know yet, add it to `Key` in `engine/input.zig` and map it to its SDL scancode.

**Add a shader or pipeline.** Put the file in `shaders/`, add its entry points to the list in `build.zig`, load it with `shader.loadSpirv`, and create a pipeline the way `SpriteBatch.init` does. Pipelines are built for a specific shader pair and color format, so a second one needs its own init.

**Add a render target.** `Texture.initTarget` creates a target in the swapchain format. Pass it to `Renderer.beginPass` to draw into it, then sample it like any other texture. Use this for lighting, post-processing, or a minimap.

**Add an asset.** Add a `{ .name, .path }` entry to `assets` in `game/config.zig`. The name must follow the rules in `engine/string.zig`, and the path must be relative to the project root. Both are checked when the game starts. Look the asset up once with `table.find(name)` and keep the returned id.

**Add entities.** Store entities in an array of structs with a position, a velocity, and a sprite or animation. Update and draw them in the loop, subtracting the camera from world positions the same way `Player.draw` does. Once there are several entity types, consider the ECS approach from the roadmap.

## Known issues

1. **Mouse coordinates are in the wrong space for gameplay.** `motion.x` and `motion.y` are window-space values, but the render size comes from `SDL_GetWindowSizeInPixels`. On high-DPI displays these differ. Convert window coordinates to pixels, divide by the scale to get view pixels, then add the camera position to get world coordinates.

2. **Asset and shader paths depend on the working directory.** Running the executable from another folder panics on the first load. The asset paths are listed in `game/config.zig`, and the shader paths are hardcoded in `engine/sprite.zig`. Both are relative to the working directory. Resolve paths relative to the executable, or embed the compiled shaders.

3. **Fixed: a minimized window spun the CPU.** A zero-size window, or a frame with no swapchain, used to restart the loop without waiting. Both cases now sleep for 16 ms first, so a minimized window idles.

4. **The backend is assumed to be Vulkan.** The device accepts SPIR-V only, and the renderer sets Vulkan options. This works on the current machine. Other backends (D3D12, Metal) need DXIL or MSL shaders, which are on the roadmap. The sampler in `triangle.slang` is bound with the Vulkan-specific `[vk::binding(0, 2)]` attribute, so the binding layout will need attention when those targets are added.

5. **Names don't match.** The package is `zig_sdl3_slang`, the executable is `my-game`, the window is `My Game`, and the sprite shader is `triangle.slang`. Choose one scheme and rename.

6. **`root.zig` is template code.** Its functions and test are not used by the game, and `zig build test` runs `src/tests.zig`, which doesn't import it. Delete the file or move real tests into it.

7. **Texture uploads block.** `Texture.initRgba8` waits for the GPU to go idle. That is fine at load time, but it must not run every frame.

8. **Fixed batch limits.** `SpriteBatch` panics above 8192 sprites or 256 texture switches in one frame. These limits fail loudly on purpose, but they will need revisiting once there are many textures or large levels.

9. **Fixed: the package file list omitted build inputs.** `.paths` in `build.zig.zon` now includes `shaders` and `vendor`, which the build needs. `assets` stays out, since the build doesn't read it.

10. **The SPIR-V version is not pinned.** `build.zig` and `renderer.zig` both say the shaders are SPIR-V 1.5, but the `slangc` command passes no `-profile` flag, so the output depends on the installed Slang version's default. SPIR-V 1.5 is the version that matches the Vulkan 1.2 request made at runtime, so the two should be set together. Add `-profile spirv_1_5` to the command, or change the comment if another version is intended.

## Roadmap

### Phase 1: finish the vertical slice

- [x] Draw the warrior from `assets/warrior_16x32.png` with 16×32 source frames and directional walk animation.
- [x] Fix one-shot input and add press and release detection.
- [x] Map keys to named actions.
- [x] Move the player and game state out of `main.zig`.
- [x] Separate fixed-timestep updates from rendering.
- [x] Add an integer-scale option for pixel-perfect output.

### Phase 2: a playable map

- [ ] Store tile IDs per cell and per layer, loaded from a file (a Tiled export or a simple custom format).
- [ ] Tile collision with axis-separated movement.
- [ ] Multiple layers: ground, decoration, and foreground.
- [ ] Camera zoom and smoothing. Edge clamping already works.
- [ ] Advanced animation state and per-entity animation data. Basic directional walk animation is done (see Phase 1).

### Phase 3: engine infrastructure

- [ ] Texture atlas with packing at build time.
- [ ] Index buffer for quads (4 vertices instead of 6) and a growable vertex buffer.
- [ ] Sprite flip, rotation, origin, per-sprite alpha, and z-order.
- [ ] Entity system: an array of structs first, ECS later if the number of entity types requires it.
- [ ] Asset manager with caching and executable-relative paths.
- [ ] Asynchronous texture uploads.
- [ ] Shader embedding or generation at build time.
- [ ] Audio through SDL3 audio streams.
- [ ] Text rendering and basic UI widgets.
- [ ] On-screen debug overlay with a frame-time graph, replacing the title stats.
- [ ] Profiling zones (for example Tracy), and log file output.
- [ ] Settings file for resolution, fullscreen, vsync, and key bindings.
- [x] Unit tests wired into `zig build test`.

### Phase 4: platforms and tooling

- [ ] Compile shaders to DXIL (Direct3D 12) and MSL (Metal) alongside SPIR-V, and enable those device formats.
- [ ] Linux and macOS builds, plus continuous integration.
- [ ] A cross-platform asset tool to replace `key_checker.ps1`.
- [ ] A level editor or import workflow.
- [ ] Save and load.

## Conventions

- Units: world, camera, and sprite positions are in native pixels, and time is `f32` seconds.
- Game `update` runs at the fixed rate `update_hz` in `game/config.zig`, and `ctx.dt` is that step. `draw` runs once per frame and gets `alpha`, which blends between the last two updates.
- Paths are relative to the project root; run `zig build run` from the repository root so `assets/warrior_16x32.png` can be found.
- `assets/warrior.png` is the original source art; the game loads the prepared 80×128 `assets/warrior_16x32.png` sheet instead.
- Only `sdl.zig` imports SDL's C headers, and only `math.zig` imports cglm's.
- `math.zig`, `string.zig`, `hash_map.zig`, and `assets.zig` don't import SDL or `log.zig`, so `zig build test` runs without a GPU. Keep new pure code the same way when you can.
- Asset names and paths are validated once, when they're registered, and nothing downstream checks them again.
- Engine code lives in `src/engine/` and never names a game type. Game code lives in `src/game/` and uses the engine only through `engine/engine.zig`.
- Initialization failures and shader or GPU setup errors panic with the SDL message. Image loading returns Zig errors.
- Capacity limits are constants that panic when exceeded, so overflows are caught early.
- Log with `engine.log.scoped`, and check invariants with `engine.log.assert`. Don't use `std.debug.assert`, which is undefined behavior in release builds.
- GPU objects are released by their `deinit`. Resources in the engine loop and in the game's `deinit` are released with `defer`, in reverse order of creation.
- Comments explain why. Public items have doc comments.

Update the status table when a module changes, so this file stays useful.
