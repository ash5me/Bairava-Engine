# Text and fonts

Text can use prebaked `.bfnt` coverage fonts or a runtime TrueType outline face. The engine does not ship a TTF with a
`.bfnt`; callers loading an outline font provide its packaged asset separately.

## Content pipeline

A font is one manifest row in `assets/asset_manifest.txt`:

```text
ui_font_9px font assets/font.ttf ui_font_9px.bfnt - 9 32 224 mono
```

The fields are the asset name, the type, the TTF or OTF source, the output `.bfnt` file, the
dependencies (`-`), the pixel height, the first codepoint, and the glyph count. A ninth field is optional and
names the rasterization: `gray`, the default, or `mono`. Any other ninth field is an error, and so is a tenth.
`zig build asset-build` runs `asset_build`, which calls the baker in `tools/assets/font_bake.c` and writes a BFNT
v4 file: a 56-byte header, a glyph table, kerning pairs, and one alpha byte per atlas pixel. The file format
does not depend on the rasterization, so the runtime loads both the same way.

The atlas is white glyphs with coverage in the alpha channel, and its top-left 2x2 block is solid white for
filled rectangles. Atlas sizes are powers of two from 128 to 4096 pixels.

## Hand-authored bitmap fonts

The asset manifest supports a `coverage` row for an 8-bit grayscale PNG to tightly packed `.r8`, and a `bitmap_font`
row for an AngelCode BMFont text descriptor. The descriptor's quoted page `file=` names the source PNG basename;
the builder rewrites only that value in the packaged `.fnt` to the corresponding `.r8` basename. Every page is
one byte per texel with no row padding. `check-assets` checks the PNG's grayscale IHDR, descriptor dimensions,
coverage dependency wiring, and any packaged `.r8` byte length.

Load the packaged descriptor through `Context.loadBitmapFont`, then use the existing `Canvas.text`, `textWidth`,
`layoutText`, and `drawTextLayout` methods. Bitmap fonts use the same quad list and SpriteBatch submission as other
fonts. Each glyph uses its authored atlas rectangle and offsets; page IDs select the corresponding coverage texture.
The loader uses the existing nearest/clamp sampling, with no atlas repacking or extra padding. Whole-pixel placement
is intended for native resolution and integer scaling.

Bitmap mapping is one glyph per UTF-8 codepoint, with the descriptor fallback glyph used for missing codepoints and
its kerning pairs applied before advances. It does not provide ligatures or complex-script shaping. The D-09 sample
is `font8x8_basic`, a 16-by-6 grid of 8-by-8 cells with zero padding and an 8-pixel advance; the cells are drawn
directly from the authored atlas.

## Rasterization

A row's mode decides how each glyph's coverage is computed. The two modes differ in what a texel can hold.

- `gray` (the default) is anti-aliased. TrueType outlines are rasterized by stb_truetype, which does not hint.
  OpenType CFF outlines are rasterized by FreeType at three times the size and box-filtered down, so both paths
  come out with the same weight and placement. Gray suits sizes where stems span several pixels.
- `mono` is FreeType's one-bit rasterizer at the real size, with hinting. Every texel is 0 or 255. Stems fall on
  whole columns and heights on whole rows, so text at a small size stays sharp. The shipped UI and debug fonts
  use mono.

Why mono for small sizes: the shipped font's stems are about 0.09 em wide. At 7 px that is 0.6 pixels, so a
gray stem can never reach full strength, and it spreads across one or two columns depending on where the
glyph's origin falls. At 10 px the `l` stem splits evenly across two columns at about 42 percent each. Hinting
the outline in gray mode would fix heights and advances, but it would not widen those stems, so mono is the
mode that makes them whole. Mono is aliased, which reads as a pixel
font, so it suits the engine's nearest-neighbor sampling and whole-number scales. Mono is not a cure at every
size, though: at 7 px the hinted outline loses strokes and letters become hard to tell apart, and at 8 px
parentheses and some letters still blur together. The game UI and the debug overlay therefore both use the
9 px mono atlas. Gray at 8 px was the other option, but its strokes are too faint on a dark background. Check
a new small size by reading it on screen before shipping it.

Mono uses FreeType's kerning table, which is the classic `kern` table. The gray path also reads GPOS pairs, so a
font that kerns only through GPOS loses those pairs when it is baked in mono. The shipped Arial font has 96 kerning pairs for printable ASCII, in both the classic `kern` table and GPOS, with the same values. FreeType's grid-fitted mono kerning rounds every one of them to zero at 9 px, so the 9 px mono atlas has none. The 10 px gray atlas keeps all 96. See docs/Bairava_Phase0/baseline/arial/README.txt.

## Runtime

`ctx.loadFont(path, pixel_height)` reads the `.bfnt` file. The file must have been baked at exactly
`pixel_height`; a mismatch is rejected rather than rebuilt. The atlas uploads once, and is not refreshed
afterward. It is stored as one coverage byte per texel: an R8 texture on the GPU, a quarter of the memory
of RGBA8. Its glyphs are drawn through a coverage pipeline, which reads that byte as the glyph's alpha and
applies the text color. Once the upload has copied the bytes, the CPU copy is released, so a loaded font keeps
only its metrics, glyph table, and kerning pairs. Measuring and drawing never read atlas pixels.

`ctx.loadOutlineFont(path, pixel_height)` loads a TrueType `glyf` outline face and fixes its size at load time. CFF,
CFF2, and TrueType collections are rejected with `FontLoadFailed`. The existing `Canvas.textWidth` path shapes outline
text with the compatibility defaults `Latn`, `en`, and left-to-right direction. Text layout and the public `Canvas`
methods remain shared with `.bfnt` fonts. Runtime glyph submission is not enabled yet: calling `Canvas.text` or
`Canvas.drawTextLayout` with an outline font fails explicitly until the renderer has page-aware atlas upload and binding.
The C-backed widgets remain `.bfnt`-only.

For `.bfnt` and bitmap fonts, a string becomes one quad per visible glyph. A quad's source is the glyph's rectangle in
the atlas, and its destination is a whole-pixel rectangle on screen. Quads are queued on the sprite batch, which draws
each run of consecutive quads that share the atlas page in one draw call. A font atlas is never lit, so its quads
always take the coverage pipeline.

## Limits

- For `.bfnt`, codepoints outside the baked range draw the font's fallback, which the file records. The baker records
  `?` for any font whose range includes it, and no fallback otherwise, so such a font draws nothing for
- characters it lacks. BFNT text is decoded as UTF-8, but it is not shaped.
- Bitmap fonts map one UTF-8 codepoint to one glyph, apply authored kerning, and use the descriptor fallback for misses.
  They do not support ligatures or complex-script shaping; malformed UTF-8 maps to U+FFFD before fallback.
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
  `ui_font_bake` bakes gray, and `ui_font_bake_mode` takes the rasterization mode as a parameter.
- `tools/assets/build.c`: writes the BFNT file for each font row.
