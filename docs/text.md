# Text and fonts

Game code uses one text surface: load a `FontHandle`, then measure, lay out, and draw through
`Canvas.text`, `Canvas.textWidth`, `Canvas.layoutText`, and `Canvas.drawTextLayout`. The font provider
and renderer-specific texture details stay inside the engine.

The compatibility text methods use HarfBuzz's `Latn`/`en` defaults. For scripts that need explicit
shaping properties, pass `ui.TextOptions` to `Canvas.textWithOptions`,
`Canvas.textWidthWithOptions`, and `Canvas.layoutTextWithOptions`, for example
`.{ .script = "Taml", .language = "ta" }`. Measurement and layout must use the same options as
drawing so widths, wrapping, and glyph placement agree. These options affect runtime outline and
MSDF fonts; static BFNT and bitmap providers retain their existing codepoint-based behavior.

There are three rendering kinds:

| Kind | Source and loading | Sampling and rendering |
|---|---|---|
| Static coverage | BFNT is baked offline; hand-authored BMFont bitmap descriptors are also accepted as a coverage provider. BFNT uses `Context.loadFont(path, pixel_height)`. Bitmap fonts use `Context.loadBitmapFont(path)` and the size recorded by the descriptor. | GPU uses R8 coverage; SDL3 2D uses the matching white-RGBA/alpha texture. Nearest filtering and whole-pixel placement preserve pixel edges. |
| Runtime coverage | TrueType `glyf` outlines loaded with `Context.loadOutlineFont(path, pixel_height)`. `pixel_height` fixes the face size. Glyphs are rasterized on demand into the session's bounded coverage atlas. | GPU and SDL3 2D use the shared dynamic coverage pages, synchronized before drawing. Sampling is nearest. |
| MSDF | An offline MFNT v1 asset generated from a TrueType source; load with `Context.loadMsdfFont(path, pixel_height)`. The baked `pixel_height` must match. `pxRange` is stored in the descriptor; the current baker uses 4. | SDL_GPU uses the median-distance shader and a per-texture clamp-to-edge linear sampler. SDL3 2D uses the matching coverage sibling, not the RGB distance field. |

Hand-authored bitmap fonts are a distinct import/metrics provider, but share the static coverage
rendering path; they are not converted to MSDF. The existing `.bfnt` format remains supported through
its compatibility adapter.

## Asset pipeline

An ordinary BFNT manifest row bakes an atlas and metrics at one size:

```text
ui_font_9px font assets/font.ttf ui_font_9px.bfnt - 9 32 224 mono
```

The final optional field selects `gray` or `mono` rasterization. BFNT v4 records a fallback codepoint;
older BFNT v1/v2 files retain their documented compatibility defaults. BFNT v3, which carried the old
signed-distance flag, is rejected.

Hand-authored bitmap fonts use a `coverage` row to package each grayscale PNG page as tightly packed
`.r8` bytes, plus a `bitmap_font` row for the AngelCode BMFont descriptor. The source descriptor names
PNG basenames; the packaged descriptor names the matching `.r8` basenames. Pages use nearest sampling,
authored rectangles and offsets, and integer placement/scaling. Bitmap mapping is one glyph per UTF-8
codepoint with authored kerning and a descriptor fallback. It does not provide ligatures or complex-script
shaping.

An MSDF row uses the `msdf` mode and outputs a separate `.mfnt` asset. The offline asset builder runs
msdfgen over supported outlines and emits both the RGBA MSDF atlas and an R8 coverage sibling. The atlas
cap is 1024×1024 per font: 4 MiB MSDF plus 1 MiB coverage. Oversized bakes fail; glyphs are not dropped
and the atlas does not grow.

Use the same baked size when loading BFNT or MFNT. Runtime outline faces are initialized at their requested
`pixel_height`; they are not silently resized later. A bitmap font's size comes from its descriptor.
`pxRange` is an MSDF distance-field parameter, not a font size or a scale multiplier.

## Shaping, fallback, and limits

Runtime outline and MSDF fonts use HarfBuzz shaping with explicit script, language, and direction. The
compatibility defaults are `Latn`, `en`, and left-to-right. Horizontal LTR text is supported; paragraph
bidi processing is not. Runtime outlines accept TrueType `glyf` outlines; CFF/CFF2 and TrueType
collections are unsupported for that path.

There is no font fallback chain. A missing runtime cmap entry or `.notdef` glyph resolves once, after
shaping, to `?` in that same face; if the face has no `?`, no ink is drawn. BFNT and bitmap fonts use
their recorded/descriptor fallback when available and otherwise draw nothing for the missing glyph.

Coverage textures, including BFNT and bitmap pages, stay nearest-filtered. MSDF atlases alone get a
clamp-to-edge linear sampler; changing that sampler does not change pixel-art or other textures.
MSDF requires the GPU median shader for distance-field reconstruction. The SDL3 2D backend cannot run
that shader and therefore draws the coverage sibling baked from the same source. It never displays the
raw RGB distance field.

The existing C BFNT code remains only as a compatibility adapter. It is not a second public text API,
and no legacy BFNT consumer or asset format is removed by this migration.

## Resource lifetime and diagnostics

CPU atlas bytes remain owned by BFNT, bitmap, MSDF, and runtime-coverage resources so their text GPU
textures can be rebuilt after an idle-safe resource reset while the device is still valid. The engine
does not currently expose a full SDL_GPU device-loss recovery/replacement path; retaining pixels alone
does not imply that the whole renderer can survive device loss.

Unloaded font handles become stale immediately. Their GPU resources remain alive while queued work may
refer to them, and are collected at an idle-safe point. Runtime atlas uploads remain pending until the
frame command buffer submits successfully; staging or submission failures are surfaced and retried.
SDL's coverage upload call has no per-copy result, so the engine cannot reliably detect an individual
copy failure through that API.

Run `zig build run-text-benchmark` for a deterministic bitmap/BFNT/Latin/Tamil/MSDF scene and
text-specific shaping, cache, atlas, upload, draw-call, and frame counters. Its output supplements but
does not replace display-backed visual acceptance.

## Validation and visual acceptance

`zig build test` runs the engine, C UI, and asset-tool tests. `zig build test-ui` runs the C text and
widget tests directly, and `zig build check-assets` validates manifests and packaged assets. The asset
builder tests cover bitmap, BFNT, and MFNT generation, including malformed inputs and the MSDF size cap.

Visual acceptance still requires reference captures for the mono bitmap font, gray BFNT, shaped Latin,
shaped Tamil (vowel signs and conjuncts), and MSDF at native and enlarged scales. Compare coverage
aliasing with MSDF smoothness, verify the median shader on SDL_GPU and the coverage sibling on SDL3 2D,
and confirm an ordinary non-font texture remains nearest-filtered. These are display-backed checks;
successful compilation or CPU tests alone do not close them.
