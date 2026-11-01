# Asset validation and hot reload

Status: P2.2. Validation runs in the build tool and at atlas load time. Hot reload runs only in
development builds.

## Checking the project

    zig build check-assets

Run it from the project root. It checks, without a window or a GPU:

- `assets/asset_manifest.txt`: names, types, source and output paths, dependencies, and font fields.
- Every `map` source with the runtime tilemap parser, including dimensions, layers, rows, and tile IDs.
- `.spawn` file sources against the dimensions of their dependent map.
- `.anim` file sources with the runtime animation parser. Animation manifest entries must depend on
  their atlas image asset; when the built atlas index is available, frame rectangles are checked
  against that sprite's dimensions.
- `assets/sprites.txt`: sprite names and image paths.
- `zig-out/bin/assets/atlas.txt` and `atlas.png`, when a build has produced them. The index and the
  image must agree on size.

Content parser errors print as `source-path: ParserError`; manifest and atlas format errors include
their source line. The step fails when there is any problem, and CI runs it after the build so the
animation bounds check can use the generated atlas index.

## Rules

Manifest lines are `name type source output dependencies`. A font line adds `pixel_height
first_codepoint glyph_count [bitmap|sdf]` after the dependencies.

| Rule | Reason shown |
|---|---|
| Names start with a lowercase letter or digit, and use only lowercase letters, digits, `_`, `-` | asset name must start with ... |
| Names are unique within a file | duplicate asset name |
| Types are `image`, `audio`, `wav`, `font`, `map`, or `file` | unknown asset type |
| Sources and outputs are relative, inside the project, and free of `..` | source path must be relative ... |
| Sources exist | source file does not exist |
| Sources have a format the type accepts (`image`: png, jpg, jpeg, bmp, tga; `audio`/`wav`: wav; `font`: ttf, otf; `map`: txt; `file`: any) | ... must be ... |
| Dependencies name an asset declared in the same manifest, in any order | dependency names an asset ... |
| Font pixel height is above 0, the glyph count is above 0, the mode is `bitmap` or `sdf` | font ... |
| Atlas index: `size W H` first, then `name x y w h`; the rectangle is inside the atlas and nonzero | sprite reaches past the edge ... |
| Atlas size matches the image's header size | the atlas size does not match its image |

A check keeps going after an issue. A report holds up to 64 issues and counts the rest.

## At load time

`Context.loadAtlas` logs every problem in an index with its line before it refuses the index. An atlas
whose size differs from its image logs both sizes.

## Hot reload (development builds)

The engine polls watched files once per frame, before the update steps, at most every 250 ms. A
change is reported once, and only after the new modification time holds for two looks. A file that
is still being written is therefore not read half-done.

Games can register individual files and then ask for changes in `update`:

    ctx.watchAsset("assets/atlas.txt", .atlas) catch |err| log.warn("asset watch failed: {s}", .{@errorName(err)});
    if (ctx.takeChanged("assets/atlas.txt")) { ... }       // in update

For assets produced by `asset-build`, `ctx.watchAssetGraph("assets/asset-index.txt")` loads the
generated index and watches each indexed output relative to the index file's directory.
`ctx.takeAssetChanged("level1")` then reports a
settled change to that asset or any transitive dependency, once per changed output. The watcher
accepts the index's `asset-index-v1` format, normalizes Windows output separators, and rejects
unknown dependencies, duplicate names or paths, unsafe paths, and unsupported index versions.

The atlas image is an indexed output, while the packer's `atlas.txt` is generated separately, so the
game watches both: it queries `takeAssetChanged("atlas")` and separately checks
`takeChanged("assets/atlas.txt")`. If the generated dependency index cannot be loaded, the game logs
the reason and falls back to watching the atlas image and index directly.

Kinds that can be watched explicitly are `atlas` (the index and image, reloaded together) and
`animation`. Indexed outputs are watched as generic assets; the game decides what to reload by asking
about the affected asset name. Explicit watches and indexed outputs share a bounded watcher (256
indexed assets plus 32 additional files).

A reload follows the order that keeps the GPU safe:

1. Load and validate the replacement. Missing sprites, a level that uses tiles the sheet lacks, or a
   bad file each reject the reload.
2. Wait until the GPU has finished the frames it was given (`ctx.waitGpuIdle()`).
3. Switch the game to the new resource, then release the old one.

A rejected reload keeps the resource the game already has, and logs why. The game never switches to a
resource it has not checked.

## Release builds

`Context.watchAsset` and `Context.watchAssetGraph` accept the call and watch nothing. The runtime
never polls. The check tool is a build step and is not part of the game.
