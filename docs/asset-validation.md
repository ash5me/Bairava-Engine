# Asset validation and hot reload

Status: P2.2. Validation runs in the build tool and at atlas load time. Hot reload runs only in
development builds.

## Checking the project

    zig build check-assets

Run it from the project root. It checks, without a window or a GPU:

- `assets/asset_manifest.txt`: names, types, source and output paths, dependencies, and font fields.
- `assets/sprites.txt`: sprite names and image paths.
- `zig-out/bin/assets/atlas.txt` and `atlas.png`, when a build has produced them. The index and the
  image must agree on size.

Each problem prints as `path:line: reason`. The step fails when there is any problem, and CI runs it
after the build.

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

Games register files and then ask for changes in `update`:

    ctx.watchAsset("assets/atlas.txt", .atlas) catch {};   // in init; a no-op in release builds
    if (ctx.takeChanged("assets/atlas.txt")) { ... }       // in update

Kinds that can be watched are `atlas` (the index and image, reloaded together) and `animation`.
Any other type is refused, so nothing reloads before its dependencies and destruction order are
defined.

A reload follows the order that keeps the GPU safe:

1. Load and validate the replacement. Missing sprites, a level that uses tiles the sheet lacks, or a
   bad file each reject the reload.
2. Wait until the GPU has finished the frames it was given (`ctx.waitGpuIdle()`).
3. Switch the game to the new resource, then release the old one.

A rejected reload keeps the resource the game already has, and logs why. The game never switches to a
resource it has not checked.

## Release builds

`Context.watchAsset` accepts the call and watches nothing. The runtime never polls. The check tool
is a build step and is not part of the game.
