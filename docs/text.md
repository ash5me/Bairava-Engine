# Text and prebaked fonts

Text is drawn from bitmap fonts that are baked offline by the asset builder. The engine never rasterizes
glyph outlines at runtime, and it does not ship the TTF. Missing text is never drawn by a fallback
rasterizer; a character the font was not baked with draws the fallback glyph the file records, normally `?`.

## Content pipeline

A font is one manifest row in `assets/asset_manifest.txt`:

```text
ui_font_8px font assets/font.ttf ui_font_8px.bfnt - 8 32 224
```

The fields are the asset name, the type, the TTF or OTF source, the output `.bfnt` file, the
dependencies (`-`), the pixel height, the first codepoint, and the glyph count. `zig build asset-build`
runs `asset_build`, which calls the baker in `tools/assets/font_bake.c` and writes a BFNT v4 file: a
56-byte header, a glyph table, kerning pairs, and one alpha byte per atlas pixel.

The baker rasterizes TrueType outlines with stb_truetype. It rasterizes OpenType CFF outlines with
FreeType at three times the size and box-filters the result down, so both paths produce the same weight
and placement. The atlas is white glyphs with coverage in the alpha channel, and its top-left 2x2 block is
solid white for filled rectangles. Atlas sizes are powers of two from 128 to 4096 pixels.

## Runtime

`ctx.loadFont(path, pixel_height)` reads the `.bfnt` file. The file must have been baked at exactly
`pixel_height`; a mismatch is rejected rather than rebuilt. The atlas uploads once, and is not refreshed
afterward. It is stored as one coverage byte per texel: an R8 texture on the GPU, a quarter of the memory
of RGBA8. Its glyphs are drawn through a coverage pipeline, which reads that byte as the glyph's alpha and
applies the text color. Once the upload has copied the bytes, the CPU copy is released, so a loaded font keeps
only its metrics, glyph table, and kerning pairs. Measuring and drawing never read atlas pixels.

Each frame, a string becomes one quad per visible glyph. A quad's source is the glyph's rectangle in the
atlas, and its destination is a whole-pixel rectangle on screen. Quads are queued on the sprite batch,
which draws each run of consecutive quads that share the atlas in one draw call. A font atlas is never lit,
so its quads always take the coverage pipeline.

## Limits

- Codepoints outside the baked range draw the font's fallback, which the file records. The baker records
  `?` for any font whose range includes it, and no fallback otherwise, so such a font draws nothing for
  characters it lacks. Text is decoded as UTF-8, but it is not shaped.
- Kerning comes only from the baked pair table.
- Glyphs are placed on whole pixels. There is no signed-distance or sub-pixel scaling.
- A font atlas is a single coverage channel. A glyph's color comes only from the quad's tint, so a font
  cannot carry its own colors.
- Each size is a separate file. To draw at a new size, add a manifest row and load its file with the same
  pixel height.

## Formats

The builder writes BFNT v4. The loader accepts v1, which has no kerning table, v2, and v4. v4 adds the
fallback codepoint at offset 52, with -1 meaning none. v1 and v2 files get the default: `?` when the
range includes it, otherwise none. Version 3, which carried a signed-distance flag, is rejected.

## Where the code lives

- `src/engine/text/text.h`, `text.c`: the runtime loader, text measuring, quad building, and
  `ui_font_release_atlas`. They depend on nothing but the C standard library.
- `src/engine/text/font.zig`: the GPU upload of a loaded font's atlas as an R8 texture, followed by the
  release of its CPU copy.
- `src/engine/renderer/texture.zig` (`createCoverage`) and `backends/sdl_gpu/texture.zig` (`uploadCoverage`):
  the alpha-only texture. `shaders/default.slang` (`fontFragmentMain`) and `backends/sdl_gpu/sprite.zig`
  (`coverage_fragment`) make the coverage pipeline that draws it.
- `tools/assets/font_bake.h`, `font_bake.c`: the offline baker, used by the asset builder and the UI tests.
- `tools/assets/build.c`: writes the BFNT file for each font row.
