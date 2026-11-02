# Ownership and error rules

These rules cover `engine.run`, the memory it creates, the resources a game receives, and how
failures are reported. The code they describe is in `src/engine/core/runtime.zig`,
`allocators.zig`, `lifecycle.zig`, `context.zig`, and the texture store in `assets/manager.zig`.

## Memory

The caller owns the parent allocator, `Config.allocator`, which defaults to the page allocator.
`run` creates four arenas from it and returns their memory to it when the run ends:

| Arena | Exposed as | Lifetime |
|---|---|---|
| engine | (internal) | The whole run. Settings text, the target, sprite batches, the debug overlay, and the texture store's tables use it. |
| game | `ctx.allocators.game` | The game instance. Use it for state that lives across updates. |
| asset | `ctx.allocators.asset` | The whole run. Loaded textures, atlases, levels, fonts, and sounds use it. |
| frame | `ctx.allocators.frame` | One loop iteration. It is reset before each frame, so don't keep pointers into it. |

Asset memory is not returned to the system until the run ends. Texture handles (below) free the GPU
memory of textures that nothing holds, but each texture's small host structure stays in the asset
arena until the run ends. Textures and other assets loaded directly with `ctx.loadTexture`,
`ctx.loadAtlas`, `ctx.loadFont`, or `ctx.loadSound` are never unloaded early, so a game should load
those once and keep them.

## Resources handed to the game

The session owns the window, the GPU device, the native target, the sprite batches, the texture
store, and the audio device. The game receives the resources below. It owns each one from the moment
it is returned and must release it.

| Resource | Created by | Released by |
|---|---|---|
| Texture | `ctx.loadTexture` | `Texture.deinit`, or the atlas that holds it |
| Texture handle | `ctx.acquireTexture(name)`, after `ctx.registerTexture` | `ctx.releaseTexture(&handle)`, or the store at shutdown |
| Atlas | `ctx.loadAtlas` | `LoadedAtlas.deinit` |
| UI font | `ctx.loadFont`, then passed to `ui.Ui.init` | `Ui.deinit` |
| Sound | `ctx.loadSound` | `Sound.deinit` |
| Streamed sound | `ctx.openStreamed` | Nothing to free. Each playing voice opens its own reader and closes it when the voice ends |
| File bytes | `ctx.readFile(allocator, ...)` | the caller, with the same allocator |

The debug overlay takes ownership of its font when it is created, and `Overlay.deinit` frees it.

## Texture handles

A texture can also be requested by name. The name is registered with the image path it stands for,
and a handle to it is a counted reference:

- `ctx.registerTexture(name, path)` gives a name to a path, relative to the executable's folder.
  Register each name before its first acquire. Names follow the rules in `assets/registry.zig` and
  must be unique. At most `max_registered_textures` (256) names fit.
- `ctx.acquireTexture(name)` returns a handle, loading the texture on first use. Each acquire adds one
  reference. Acquiring a name again shares the same GPU texture.
- `ctx.textureOf(handle)` returns the `*const Texture` that a handle names, for drawing. The pointer is
  valid while the handle holds a reference.
- `ctx.retainTexture(handle)` adds a reference to a handle that is already held, for a second holder.
- `ctx.releaseTexture(&handle)` drops one reference and clears the handle, so the same variable can't
  release twice. Each acquire, and each retain, needs exactly one release.
- `ctx.unloadUnusedTextures()` unloads the textures that no handle holds and frees their GPU memory.
  A texture with a reference is never unloaded early.

A handle is two numbers, not a pointer, so it stays valid while the store grows. When a texture is
unloaded, every handle to its old load becomes stale. `ctx.textureOf` then returns `error.StaleHandle`,
and `releaseTexture` returns the same error without changing any reference count, so a stale release
can't drop a reference that belongs to a new holder of the same texture. A handle that was never issued,
or was already released, returns `error.InvalidHandle`.

A handle is not a lease token. If a copy of a handle is released after the original was released, and
the texture is still loaded, the copy releases a reference that someone else may hold. Release each
handle variable exactly once.

Acquiring can fail with `error.UnknownAsset` for a name that was never registered, `error.InvalidName`
for a malformed name, or the load error (for example `error.FileNotFound` or `error.DecodeFailed`).
A failed acquire caches nothing. Releasing more references than were acquired is a programmer error,
and it panics.

## Teardown order

`run` registers its cleanup in the order it opens things, and Zig runs deferred cleanup in reverse.
The shutdown order is therefore:

1. The debug overlay is released.
2. `Game.deinit` runs, so the game releases its textures and texture handles while the device still exists.
3. `Session.stop` runs: audio, sprite batches, target, the texture store (which logs its counters and
   unloads any texture that is still loaded), GPU device, window, then SDL.
4. The arenas are released.
5. The log file is closed.

A game's `deinit` must release everything it loaded. The engine tears down the texture store and the
device right after it, so any resource the game keeps past that point will reference a destroyed
device. A handle the game still holds at that point is invalid.

A panic does not run deferred cleanup. The process aborts, and the operating system reclaims the
memory. The panic message is written to the log file first.

## Startup

`Session.start` opens resources in dependency order. Each fallible step records that it succeeded,
and an `errdefer` releases everything recorded so far. A failed start therefore leaves the session
stopped. The config is validated before any platform resource is created. The texture store is set up
after the context exists, because its loader loads textures through the context.

If `Game.init` fails, `run` does not call `Game.deinit`. `init` must release what it opened before
the failing step, using `errdefer` as `game/game.zig` does.

## Errors

| Situation | Handling |
|---|---|
| Invalid config, window or GPU device creation failure, or `Game.init` failure | Logged, cleaned up, and returned from `run`. The caller decides the exit status. |
| Missing or malformed asset | Returned as an `AssetError` from the `Context` loaders. The game decides whether it is fatal. |
| Unknown or malformed texture name | Returned as `error.UnknownAsset` or `error.InvalidName` from `acquireTexture`. |
| Stale or invalid texture handle | Returned as `error.StaleHandle` or `error.InvalidHandle` (`HandleError`). The game decides how to recover. |
| No audio device | Not an error. The game runs silent, and sound loads return `error.NoDevice`. |
| GPU resource creation after the device is up (textures, shaders, pipelines, buffers) | Panics with the SDL message. The engine cannot continue without these. |
| Broken invariant or programmer error | `engine.log.assert` (Debug and ReleaseSafe) or `engine.log.fail` (every build mode). Don't use `std.debug.assert`. Releasing a handle more often than it was acquired also panics. |

## Open items

- Textures acquired by name can be unloaded early. Textures loaded directly, atlases, fonts, and sounds
  cannot yet. Each would need its own store, built the same way as the texture store.
- Device-lost recovery is not implemented.
- No test starts a real window or GPU device. Startup ordering and the texture store's GPU teardown
  are covered by review, not by an automated test.
