# Assets and resource ownership

Asset paths passed to `Context` are relative to the executable's packaged asset directory. Use
`loadTexture`, `loadAtlas`, and the corresponding typed loaders for packaged resources; recover from
their returned errors instead of assuming files exist.

## Textures

`loadTexture` returns an owned texture value. Deinitialize it before the run ends, normally from the
owning scene's teardown. For name-registered textures, `acquireTexture` returns a counted handle:
balance each successful acquire or retain with `releaseTexture`. A released or unloaded handle is
invalid and may produce `HandleError`.

The resource cache can unload idle entries to honor its configured budget. A handle is not a promise
that a GPU allocation can never be evicted; request or resolve the resource through its documented
context operations.

## Build-time asset validation

Use the asset manifest and the asset validation guides to check packaged files before runtime.
`zig build check-assets` validates repository asset metadata and generated atlas indexes. Asset
source files and packaged files have different roles; only files included by the manifest are
available to the running game.

## Threading

Background workers can decode staged data, but GPU upload and renderer operations remain on the
engine thread. Any allocator used by worker-visible work must be safe for the configured worker
count. Set `worker_threads` to zero when deterministic main-thread work is more important than
parallel decoding.
