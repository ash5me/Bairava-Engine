# Bairava SDL Platform Boundary Migration Plan

**Status:** Steps 8 and 9 implemented locally. Supersedes the earlier `migration.md`.
**Scope:** SDL3 platform-boundary migration only.
**Baseline:** Bairava-Engine snapshot targeting Zig `0.16.0-dev` and SDL `3.4.2`.
**Verification:** Local `zig build`, `zig build test`, and the SDL boundary scanner pass. The scanner's negative check rejects an SDL import in reachable core code. Hosted Linux, macOS, and Windows CI results remain unverified.

---

## 1. Goal

Confine SDL-specific platform code to `src/engine/platform/sdl/`, with `src/engine/platform/platform.zig` defining the engine-facing platform contract.

After migration:
- Engine code outside a narrow, documented allowlist does not name SDL types, constants, functions, or C bindings.
- Windowing, events, timing, file access, and audio-device operations go through the platform contract.
- SDL3 remains the only backend. No second backend and no runtime backend switching is added.
- GPU rendering remains SDL_GPU-based, but core code uses engine-facing renderer and platform types rather than SDL declarations.
- Existing game-facing APIs and observable behavior remain unchanged.
- Each step is independently buildable, testable, and revertible.

The objective is a real dependency boundary, not merely moving SDL imports into differently named files.

## 2. Non-goals

This migration does not redesign the renderer or shaders, change asset formats, add gameplay or physics features, integrate the generic asset cache, change the public API in `game/`, or make Bairava an independently consumable Zig package or module. The package work is a follow-on milestone (section 12).

## 3. Architectural contract

```text
game/
  |
  v
core/ and engine systems
  |
  +----> platform/platform.zig ----> platform/sdl/
  |
  +----> renderer/ ----------------> SDL_GPU implementation
  |
  +----> assets/, audio/, input/, text/, ui/, ...
```

Rules:
1. `platform/types.zig` contains platform-facing value types and opaque handles. It imports neither SDL nor engine systems.
2. `platform/platform.zig` defines stable SDL-free signatures. It forwards to the SDL backend but does not expose backend signatures.
3. `platform/sdl/` owns SDL initialization, event translation, window and audio handles, timing, and SDL file APIs.
4. `input/` owns semantic input state and applies platform-neutral events.
5. `audio/` owns engine-level sounds, voices, and playback policy. The SDL backend owns device and stream interaction and SDL-specific conversion and decoding.
6. `renderer/` owns rendering-facing values such as the clear color and GPU format mapping.
7. `core/` coordinates systems and does not call SDL directly.
8. Opaque-handle casts live only inside `platform/sdl/`.

## 4. Current state (snapshot)

**SDL identifiers by file.** Counts are lines matching SDL identifiers in the snapshot grep, so they are approximate.

| File | Lines | What it does with SDL |
|---|---|---|
| `core/context.zig` | 11 | GPU device type, GPU texture formats and support check, asset and save file I/O |
| `core/runtime.zig` | 9 | Base path, frame clock, idle delay, `SDL_FColor` clear color, GPU idle wait |
| `core/lifecycle.zig` | 8 | `SDL_Init` and `SDL_Quit`, window, settings read, swapchain format |
| `core/event.zig` | 6 | Event polling, quit, F11 and F3 keycodes |
| `renderer/renderer.zig` | 8 | Render passes; `SDL_FColor` parameter |
| `renderer/shader.zig` | 19 | Shader formats and creation |
| `renderer/sprite.zig` | 84 | SDL_GPU buffers, pipelines, draws |
| `renderer/texture.zig` | 50 | SDL_GPU textures, samplers, transfers |
| `text/font.zig` | 4 | `SDL_GPUDevice` in font signatures |
| `logging/log.zig` | 2 | `SDL_GetTicksNS` for timestamps |
| `assets/loaders/image.zig` | 5 | `SDL_LoadFile` in both loaders |

**Consumed events.** The live code consumes exactly these SDL events: `SDL_EVENT_QUIT`, `SDL_EVENT_KEY_DOWN` (with the repeat flag), `SDL_EVENT_KEY_UP`, `SDL_EVENT_MOUSE_MOTION`, `SDL_EVENT_MOUSE_BUTTON_DOWN`, and `SDL_EVENT_MOUSE_BUTTON_UP`. `Input` uses only the left mouse button. No wheel or window-resize events are consumed, because the window's pixel size is queried every frame. Confirm this on the branch.

**Readable and writable locations.** The base path is the executable's folder. Settings (`settings.txt`) are read from it. The log (`Semkootru.log`) is written to it through `lifecycle.openLog`. The save file is written with `ctx.writeFile` and read with `ctx.readFile` in `game/game.zig`, and both resolve to the same folder. The level map is read with `ctx.readFile` in `game/level.zig`. Because the base path is the executable's folder, asset reads and save reads and writes currently land in the same directory.

**Frame order today.** `runtime.run` calls `SDL_GetBasePath`, then `lifecycle.openLog`, then `Session.start`, which reads settings, calls `SDL_Init`, and creates the window, GPU, and audio. Each frame then measures time, drains events (quit, F11, and F3 are handled, and every event also goes to `Input`), syncs held state from the keyboard state, runs fixed-step updates (with `Input.latch` before each step), updates audio, draws, and presents.

**Key identity.** Bindings already resolve through SDL scancodes in `platform/sdl/input.zig`. F3 and F11 are the only keycode comparisons (`core/event.zig`).

## 5. Decisions

### D1. Forwarding contract
Use explicit forwarding declarations in `platform/platform.zig`. Do not publicly re-export SDL implementation functions. The forwarding signatures are the contract, and they use platform-owned types only.

### D2. Platform types
`platform/types.zig` holds the minimal required types: `Scancode`, `MouseButton`, `Event`, `PixelSize`, `Error`, `max_full_path`, and the opaque handles `Window`, `AudioDevice`, and `AudioStream`. It holds no SDL names and no engine-system imports. GPU types are not defined here. They come from `platform.gpu` (D9).

### D3. Ownership of keys
Keep the engine's `Key` in `engine/input/`, as the revision prefers. Platform events carry a minimal physical-key type, `Scancode`, defined in `platform/types.zig`. It lists the 26 physical keys the engine can receive: the 24 keys `Key` lists today, plus `f3` and `f11`. The SDL backend maps SDL scancodes to `Scancode`. `engine/input/input.zig` maps `Scancode` to `Key` and back. Actions and gameplay bindings stay in `game/controls.zig`.

This keeps the platform layer free of engine imports, at the cost of two short lists that must agree. A sync test checks that every `Key` maps to a `Scancode` and back. If you prefer one shared list, see open decision 1.

### D4. Keyboard mapping
Use scancodes for every key. Current bindings already resolve through scancodes, so this extends the existing convention to F3 and F11 instead of changing bindings. Key-down events carry the repeat flag, and presses ignore auto-repeat as they do today. F3 and F11 match only non-repeating key-downs. Verify movement, F3, and F11 on a non-US layout rather than assuming behavior is unchanged.

### D5. Timing
Keep SDL timing behind `platform.clock`. Expose `nowNs()` and `sleepMs()`. Revisit standard-library timing only after the pinned Zig toolchain is upgraded and tested.

### D6. File access uses explicit locations
`platform.files` takes a location with each call:
- `.packaged` is read-only. It resolves relative to `baseDir()` and holds shipped assets and the level map.
- `.beside_executable` holds settings, the log, and save data. It preserves today's behavior.

Reads are allowed from both locations. Writes are accepted only for `.beside_executable`, and that location is a named compatibility path, not a permanent write policy. Installed application directories may not be writable, so a user-data location should be decided separately (open decision 2).

The game-facing API does not change. `Context.readFile` keeps reading `.packaged`, and `Context.writeFile` keeps writing `.beside_executable`. Today both resolve to the same folder, so the split lives in names and in the write path. The save file is read through `readFile`, so its read and write must move together when a user-data location is approved.

Log paths are built with `files.absolutePath(.beside_executable, name, buf)`, so core never builds paths from raw SDL output. Path and read functions must work before `platform.init()`, because settings are read before SDL initializes today.

Writes must be routed through `platform.files` and nothing else, so grepping for SDL file calls finds every write.

### D7. Logging clock injection
Logging receives a clock through `logging.setClock(fn () u64)`, which `runtime.run` calls before the first log line. Before injection, timestamps print as `0`, and a test pins that behavior. The logger never imports the platform layer.

### D8. Audio split
Engine audio owns `Sound`, voices, and playback policy. `Sound` stores the allocator that owns its samples, and `Sound.deinit` frees with that allocator. The SDL backend owns device and stream operations, format conversion, and WAV decoding, which is exposed as a bytes-in `decodeWav(allocator, bytes)`. IMA sidecar decoding is platform-independent and stays in `audio/ima.zig`. Both WAV and sidecar bytes come from `platform.files`, not from SDL file APIs.

### D9. GPU boundary and allowlist
Core does not import SDL because the renderer uses SDL_GPU.

Core uses `platform.gpu.Device`, `platform.gpu.TextureFormat`, and `platform.gpu.waitIdle`, plus the existing `platform.gpu.Gpu` and `platform.gpu.Frame` lifecycle surface. The GPU aliases and wait function are explicitly forwarded from `platform/sdl/gpu.zig`; core names no SDL identifiers. The renderer owns `renderer.Color`, GPU format mapping (compression to GPU format), and support checks. SDL clear-color construction moves into the renderer.

The allowlist is file-specific, and every entry carries a reason:
- `platform/sdl/**`: the SDL implementation.
- `platform/platform.zig`: explicit forwarders from the engine contract to the SDL backend.
- `renderer/renderer.zig`: render passes and command-buffer calls use SDL_GPU types.
- `renderer/shader.zig`: SDL_GPU shader creation and format flags.
- `renderer/sprite.zig`: SDL_GPU pipelines, buffers, and draws.
- `renderer/texture.zig`: SDL_GPU textures, samplers, and transfer buffers.
- `tests.zig`: imports SDL backend modules so their platform tests are included; it names no SDL C types.

Do not allow all of `renderer/` or `text/` by default. The four renderer backend files account for most remaining SDL names. Moving them under `platform/sdl/` would shrink the allowlist to one directory, but it is a structural change, so it stays out of this plan.

## 6. Target layout

```text
src/engine/platform/
  platform.zig       SDL-free engine-facing contract and forwarders
  types.zig          Scancode, MouseButton, Event, PixelSize, Error, opaque handles
  sdl/
    sdl.zig          SDL C import
    init.zig         SDL init and shutdown
    window.zig       SDL window implementation
    input.zig        SDL event translation, held-key sampling, scancode table
    clock.zig        SDL clock and delay
    files.zig        SDL base path and file I/O, with locations
    audio.zig        SDL audio device, streams, decode and convert
    gpu.zig          SDL_GPU device aliases and waitIdle

src/engine/input/
  input.zig          Key, Key/Scancode table, Input.apply(Event)

src/engine/audio/
  audio.zig          engine audio API, Sound ownership, load and play
  voices.zig         voice management
  ima.zig            platform-independent IMA sidecar decoder
```

This is a target shape, not a requirement to create duplicate files where equivalent modules already exist.

## 7. Migration steps

Each step is one commit. At the end of every step, run `zig build` and `zig build test`. If a step fails, stop and fix it before proceeding.

### Step 0: Baseline and boundary report

1. Record the branch and commit being migrated.
2. Run `zig build` and `zig build test` on the development machine and record the results.
3. Record CI results for Linux, macOS, and Windows. Mark platforms that could not run as unverified. Do not assume success.
4. Add a warning-only boundary scanner to CI on Ubuntu. It is a grep-based step with no Windows or macOS dependency.
5. The scanner reports file and line for `SDL_` and `SDLK_` identifiers, SDL type names (`SDL_Window`, `SDL_Event`, `SDL_GPU*`, `SDL_Audio*`, `SDL_FColor`), direct imports of `sdl.zig`, `@cImport`, and `c.` namespace references. Match the last as `(^|[^.A-Za-z_])c\.[A-Za-z_]` so that `std.c.` is not counted.
6. Mark each hit as allowed or not against the D9 allowlist. Report allowed hits separately, so the warning list shows only real violations.

**Done when:** the baseline is recorded and the warning report reproduces locally and in CI.

### Step 1: Verify and remove unreachable legacy files

The 31 root-level files below are candidates, not an unconditional deletion list. An import-graph walk from `main.zig` and `tests.zig` shows none is reachable. They are `animation.zig`, `asset_cache.zig`, `assets.zig`, `atlas.zig`, `audio.zig`, `audio_voices.zig`, `camera.zig`, `debug_overlay.zig`, `engine.zig`, `entity.zig`, `frame_history.zig`, `hash_map.zig`, `ima.zig`, `image.zig`, `input.zig`, `loaded_atlas.zig`, `log.zig`, `math.zig`, `profile.zig`, `renderer.zig`, `sdl.zig`, `settings.zig`, `shader.zig`, `sprite.zig`, `string.zig`, `texture.zig`, `tilemap.zig`, `tilemap_draw.zig`, `ui.zig`, `vector.zig`, and `view.zig` under `src/engine/`.

1. Re-check imports, build scripts, generated code, scripts, docs, tests, and tooling on the current branch.
2. Check git history and uncommitted work for each candidate.
3. Confirm no path-based or tooling dependency remains.
4. Delete only files proven obsolete.
5. Keep the commit deletion-only. Move or refactor anything still needed in a separate commit.

**Done when:** build and tests pass, and the commit contains only verified deletions.

### Step 2: Platform event contract

The event contract must preserve every event that engine and game code consume today. The minimum set, from the snapshot, is quit, key down with repeat, key up, mouse motion, and mouse button down and up. Add wheel or resize only if the branch consumes them.

```zig
pub const MouseButton = enum { left, right, middle };

pub const Event = union(enum) {
    quit,
    key_down: struct { scancode: Scancode, repeat: bool },
    key_up: struct { scancode: Scancode },
    mouse_motion: struct { x: f32, y: f32 }, // window points
    mouse_button_down: MouseButton,
    mouse_button_up: MouseButton,
};
```

Do not silently discard quit events. Unknown SDL events may be ignored. Currently consumed events may not be.

Implementation:
1. Add `Scancode`, `MouseButton`, and `Event` to `platform/types.zig`.
2. In `platform/sdl/input.zig`, split pure translation, `translate(*const c.SDL_Event) ?Event`, from polling, `poll() ?Event`. Polling drains `SDL_PollEvent` and skips events that do not map. The scancode table and the existing SDL-event tests stay in this file.
3. `platform.zig` forwards `events.poll()` and `events.isHeld(scancode)`.
4. In `engine/input/input.zig`, keep `Key`, add the `Key`/`Scancode` table, and add `Input.apply(Event)`. It calls the existing `keyDown`, `keyUp`, `moveMouse`, and `leftButton` methods. Non-left buttons are ignored, as today.
5. Held-state sampling stays separate. Once per frame, after the drain, `runtime` loops over `Key` and calls `input.setHeld(key, platform.events.isHeld(scancodeOf(key)))`.
6. `core/event.zig` drains `platform.events.poll()`. It handles `quit`, and it handles F11 (non-repeating key-down, toggles fullscreen) and F3 (non-repeating key-down, toggles the overlay) by scancode. Everything else goes to `Input.apply`.
7. Document frame order at the top of `input/input.zig`: events, then held-state sampling, then update steps (latch before each step), then draw. Presses and releases accumulate in `Input` between update steps, so a frame with no update step keeps them.
8. Test translation without a window: each event type, the repeat flag, unknown events returning `null`, and a sync test that the `Key`/`Scancode` table covers every `Key`.

**Done when:** no `SDL_Event` or SDL key constant appears outside `platform/sdl/`, and the event and input tests cover the consumed set.

### Step 3: Opaque window handle

1. Define `Window` as an opaque platform handle in `types.zig`.
2. Keep SDL window pointers private to `platform/sdl/window.zig`.
3. Make `Session`, event coordination, and runtime use `*platform.Window`.
4. Keep all conversions between the opaque handle and `*c.SDL_Window` inside the SDL backend.
5. `Gpu.init` accepts `*platform.Window` and performs the SDL conversion inside `platform/sdl/gpu.zig`.

**Done when:** `SDL_Window` appears only in `platform/sdl/`, and window operations compile through the contract.

### Step 4: Centralize initialization and shutdown

1. Add `platform/sdl/init.zig` with platform `init()` and `shutdown()`.
2. Preserve startup order: settings and the base path are read before SDL initialization, and stay available before it unless separately proven otherwise.
3. Video, window, and GPU initialization failures remain fatal, as today.
4. Audio subsystem and device initialization failure remains nonfatal. Log a warning and allow silent gameplay.
5. Audio teardown closes only the device and streams it owns. It does not call `SDL_Quit` or tear down the subsystem.
6. Call `platform.shutdown()` once, after audio, GPU, and window resources are released.

The startup order is `init` (settings read, `platform.init`), then window, GPU, and audio device. The shutdown order is audio device, batches, target, GPU, window, then `platform.shutdown`.

**Done when:** `SDL_Init`, `SDL_Quit`, and `SDL_InitSubSystem` appear only in `platform/sdl/init.zig`, the startup order is documented, and a missing audio device still starts the game.

### Step 5: Clock and logging

1. Add `platform/sdl/clock.zig` and forward `nowNs()` and `sleepMs()`.
2. Replace the direct SDL timing calls in `runtime.zig`.
3. Remove the SDL import from `logging/log.zig`. Add `setClock`, and have `write` use it for timestamps.
4. `runtime.run` calls `logging.setClock(platform.clock.nowNs)` before `lifecycle.openLog`, so the first log line is timestamped.
5. Test pre-injection behavior (timestamps print as `0`) and verify that timestamps stay consistent with the runtime clock after injection.

**Done when:** `logging/log.zig` has no platform or SDL dependency, and `runtime.zig` makes no direct SDL timing calls.

### Step 6: File access and ownership

1. Add `platform/sdl/files.zig` with `baseDir()`, `read(allocator, location, path)`, `write(location, path, bytes)`, and `absolutePath(location, path, buf)`.
2. `read` returns bytes owned by the caller's allocator. The SDL buffer is freed inside the backend.
3. Reads return `NotFound` only when the path does not exist, and `ReadFailed` for any other failure. Check existence with SDL's path-info API before loading, and confirm that function on SDL 3.4.2. Compressed-variant loading treats only `NotFound` as an absent variant and propagates everything else.
4. Writes are accepted only for `.beside_executable`. Other write attempts return an error.
5. Route settings reads, `Context.readFile`, and `Context.writeFile` through the platform file API, following D6.
6. Change image loading to accept bytes. `loadRgba8(path)` becomes `decodeRgba8(bytes)`. `loadCompressed(path, ...)` goes away, and callers read the bytes and call the existing `parseCompressed`. The stb decode already works from memory.
7. Keep image decoding independent of SDL.
8. Test that allocator ownership holds, that a missing file returns `NotFound`, that an existing file's bytes match, and that writes to `.packaged` are rejected. Test `decodeRgba8` with `@embedFile` on a small asset, so the test needs no working directory.

**Done when:** SDL file functions appear only in `platform/sdl/files.zig`, `assets/loaders/image.zig` has no SDL import, and the file and decode tests pass.

### Step 7: Audio ownership and backend split

1. Keep engine-level `Audio`, `Sound`, and voice policy in `engine/audio/`.
2. Keep SDL device and stream operations in `platform/sdl/audio.zig`.
3. Use opaque `AudioDevice` and `AudioStream` handles at the contract boundary.
4. Expose WAV decoding through `decodeWav(allocator, bytes)`, so file I/O stays in the file layer.
5. Keep IMA sidecar decoding pure and independent of SDL.
6. `Sound` stores its allocator, and `Sound.deinit` frees with it.
7. Remove public exposure of SDL audio structures, such as `Audio.format: c.SDL_AudioSpec`. Expose only an engine-level `PcmFormat` (sample rate, channels, sample kind) defined in `types.zig`.
8. Split tests. Decode tests run without a device. Conversion tests run where possible without playback hardware. Device creation and playback get a manual smoke test or a suitable CI host.

Confirm that `decodeWav` works without an initialized audio device. If it needs `SDL_Init`, the decode tests can initialize SDL without opening a device.

**Done when:** SDL audio types and functions appear only in `platform/sdl/audio.zig`, decode tests pass, and optional audio initialization stays nonfatal.

### Step 8: Remove SDL references from core and narrow the GPU boundary

1. Replace `SDL_FColor` in `core/runtime.zig` with `renderer.Color`, a plain four-float struct. `renderer.beginPass` converts it to SDL_GPU types.
2. Route GPU idle waiting through `platform.gpu.waitIdle`.
3. `core/context.zig` types its device as `platform.gpu.Device`.
4. Move GPU texture-format mapping and support checks out of `core/context.zig` and into `renderer/texture.zig`. `Context` keeps the file-loading logic.
5. `core/lifecycle.zig` types the swapchain format as `platform.gpu.TextureFormat`, and passes it to renderer constructors.
6. Inspect lifecycle, runtime, and context for SDL identifiers, imports, and `c.` references, not only direct imports.

**Done when:** no file under `core/` imports SDL, names an SDL identifier, or uses SDL C bindings, and rendering still works.

### Step 9: Enforce the boundary and document it

1. Turn the warning-only scanner into a failing CI check.
2. Use the file-specific allowlist from D9. Every exception has a documented reason. `text/font.zig` uses the platform GPU device type and is no longer an exception; `tests.zig` is allowed only to import backend modules for their test declarations.
3. The scanner checks SDL names, constants, types, direct SDL C imports, backend imports, and SDL C namespace aliases. Unrelated C integrations such as cglm and Parson are not SDL boundary violations.
4. Add a negative test. On a temporary branch, add a forbidden SDL reference to a `core/` file, confirm CI fails, then remove it.
5. Update the README architecture rules, source tree, platform and audio descriptions, and test documentation.
6. Update the build and test comments that describe SDL linking and initialization, in `build.zig` and `tests.zig`.
7. Make sure the documentation describes what CI actually enforces.

**Done when:** CI passes on the clean branch, fails on the deliberate violation, and the README rules match the enforced allowlist.

## 8. Verification matrix

Run `zig build` and `zig build test` after every step. Run CI on Linux, macOS, and Windows before merging. Mark unavailable checks as unverified.

| Area | Required check |
|---|---|
| Startup and shutdown | Window opens at the configured size; clean close releases resources |
| Input | WASD, pressed and released edges, mouse motion and buttons, click-to-world mapping |
| Window controls | F3 overlay, F11 fullscreen, quit event |
| Camera and rendering | Camera follow and zoom; textures and overlay font render |
| Timing | Fixed timestep stays stable; delay path works |
| Files | Asset and settings reads work; log and save writes use `.beside_executable` |
| Audio | Game starts without an audio device; decode tests pass |
| GPU | Run with `-Dgpu-debug=true`; validation stays clean |
| Boundary | Scanner reports no forbidden SDL references outside the allowlist |
| Tests | Tests that load `assets/` use the project-root working directory set in `build.zig` |

Manual smoke tests are required after the event, window, lifecycle, files, audio, and GPU steps. If a check cannot run in CI (such as physical audio playback), mark it manual, not passed.

## 9. Risks and mitigations

- **Event loss:** preserve quit and every consumed event, and test translation separately.
- **Input edge timing:** document and test the frame order for event edges and held-state sampling.
- **Startup order:** keep settings and the base path available before SDL initialization.
- **Writable paths:** executable directories may not be writable after installation. Separate asset reads from user-data writes, and keep the compatibility write path explicit.
- **Save coupling:** the save file is read and written through the same base-path helpers. When a user-data location is approved, both must move together.
- **SDL before init:** confirm that `SDL_GetTicksNS` and `SDL_GetBasePath` are valid before `SDL_Init` on SDL 3.4.2. If the clock is not, the first log lines print zero, which is the documented pre-injection behavior.
- **Audio failure policy:** audio initialization stays nonfatal, and subsystem shutdown stays centralized.
- **Allocator mismatch:** free sample data with the allocator that allocated it. `Sound` records that allocator.
- **Opaque casts:** keep casts inside `platform/sdl/`, and only for handles that the backend created. GPU types are aliases, not opaque casts.
- **Key lists:** `Key` and `Scancode` must agree. The sync test is the guard.
- **Keyboard layouts:** test F3, F11, and movement on a non-US layout.
- **Toolchain drift:** use only APIs supported by the pinned Zig development version.
- **False positives:** report file and line, and keep the allowlist narrow. Do not weaken checks to make CI pass.

## 10. Rollback

Each step is one commit and should be independently revertible. Revert in reverse order. Do not combine unrelated refactors with a migration step. If a correction is needed, commit it and verify it before proceeding.

## 11. Open decisions before implementation

1. **Key ownership.** The plan follows the revision's preference: `Key` stays in `engine/input/`, and platform events carry a separate `Scancode`. The alternative is one shared physical-key enum in `platform/types.zig`, re-exported from input. That is simpler, because the current `Key` already lists only physical keys and no actions. Choose one before step 2.
2. **Writable locations.** On the snapshot, settings, the log, and the save file all live beside the executable. This plan keeps that behavior behind `.beside_executable`. Confirm that the branch matches, and decide separately where user data should live, which is a follow-on decision.
3. **Renderer and font allowlist.** On the snapshot, `renderer/renderer.zig`, `shader.zig`, `sprite.zig`, and `texture.zig` need SDL_GPU names in this migration. `text/font.zig` should drop off once it uses `platform.gpu.Device`. `tests.zig` should drop off once the `colorTargetInfo` test moves into `renderer/renderer.zig`. Confirm on the branch.
4. **Consumed events.** On the snapshot, the consumed set is quit, key down with repeat, key up, mouse motion, and left mouse button down and up. Wheel and resize are not consumed. Confirm on the branch, including uncommitted changes.

These are implementation decisions, not reasons to broaden the migration.

## 12. Definition of done

- Platform contract signatures are SDL-free.
- Engine core contains no SDL imports, SDL identifiers, or C binding references.
- Remaining SDL references are inside the documented, file-specific allowlist.
- CI enforces the boundary, and the negative test proves it can fail.
- `zig build` and `zig build test` pass.
- Linux, macOS, and Windows CI pass, or unavailable platforms are explicitly marked unverified.
- The game-facing API and observable behavior remain unchanged.
- The README describes the actual architecture and the enforced rules.

**Follow-on milestone (not part of this plan):** export Bairava as an independently consumable Zig module or package, make Semkootru consume that public module, integrate the asset manager with runtime resource ownership, and validate the boundary by building a second distinct game without modifying Bairava internals.

---

## Appendix A: Changes from the previous draft

- Structure and rules follow `revision_20plan.md`.
- Current-state facts from the snapshot were added: the consumed event set, the readable and writable locations, and SDL identifier counts per file.
- The previous draft recommended moving `Key` into `platform/types.zig`. This revision keeps `Key` in `engine/input/` and adds a platform `Scancode`, per the revision's preference. Open decision 1 covers the alternative.
- File access now takes an explicit location. The previous draft's `files.read` and `files.write` had no notion of location, so the write path was implicit.
- The allowlist is file-specific. The previous draft allowed `renderer/` and `text/` directory-wide.
- Core names exactly three GPU items through `platform.gpu`. The renderer owns `Color` and format mapping.
- Step 0 runs the scanner on Ubuntu only, as warning-only, with a precise pattern for `c.` references.
- Step 1 verifies candidates before deletion. The previous draft treated the list as settled.
- Step 2 names the event set and the frame order.
- Step 9 adds the negative test and the README corrections.
- Open decisions now record what the snapshot shows.
