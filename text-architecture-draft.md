# Bairava text architecture (draft)

Status: draft for review. Nothing here is implemented. It refines the rendering path in the Phase 0 migration plan and adds a bitmap-first track for pixel-art games.

## 1. Principles

1. **One text API.** Callers choose a font and a style. They don't choose a glyph source or a renderer.
2. **Bitmap is the default.** Pixel-art games use bitmap rendering with nearest filtering and whole-pixel placement.
3. **MSDF is optional.** It's for scalable outline fonts only and is never the default.
4. **Shaping and glyph images are separate.** Shaping comes from an OpenType face. Glyph images come from a glyph source. Section 3.3 explains why.

## 2. Components

```
Font System
├── Font asset importer
│   ├── Bitmap font (BMFont .fnt + page PNGs)           → glyph source: bitmap, prebaked
│   ├── Legacy .bfnt (v1, v2, v4)                       → glyph source: bitmap, prebaked
│   └── TrueType / OpenType (outline)
│       ├── shaping face (HarfBuzz)                     → always present
│       ├── runtime rasterizer (stb_truetype)           → glyph source: bitmap, on demand
│       └── MSDF generator (offline, optional)          → glyph source: MSDF
│
├── Font cache (keyed per glyph source; see 3.2)
│
└── Text API
    └── shaper → layout → renderer
        ├── Bitmap renderer: coverage atlas, nearest sampling (default)
        └── MSDF renderer: distance-field shader (optional)
```

TrueType can feed either renderer. A pixel-art game uses the bitmap renderer for every font, including outline fonts such as the shipped Arial UI font. MSDF is chosen per font, and only for outline fonts.

## 3. Interfaces

These are concepts, not final signatures.

- **Font**: id, kind (bitmap or outline), metrics (ascent, descent, line height in pixels), an optional shaping face, a glyph source, and a default renderer.
- **Glyph source**: returns a glyph image with an atlas page, a texel rectangle, an offset from the pen and baseline in pixels, an advance in pixels, and a render mode (coverage or MSDF).
- **Renderer**: draws shaped glyph runs. Renderer selection follows the rules in section 5.
- **Text API**: `measure`, `layout`, and `draw`, taking a font and options (size in pixels, color, alignment, line height). Effects and markup are out of scope here.

### 3.1 Glyph keys

- Bitmap: (font, glyph ID, pixel size, rasterization mode). Mono or gray rasterization is part of the key.
- MSDF: (font, glyph ID). Size is not part of the key, because one distance field serves every size.

### 3.2 Glyph IDs and codepoints

HarfBuzz returns glyph IDs from the shaping face. A glyph source must be able to look up images by glyph ID. TrueType sources do this natively. A bitmap sheet keyed by codepoint can be mapped through the font's cmap, but only for Latin text, where each codepoint maps to one glyph and no substitution happens.

### 3.3 Shaping face and glyph source

Bitmap fonts have no GSUB or GPOS tables, so HarfBuzz can't shape Tamil or other complex scripts with them. That gives two cases:

- **Latin with a hand-drawn bitmap font.** Kerning comes from the `.fnt` file, with one glyph per codepoint. This needs no shaping face.
- **Complex scripts.** The bitmap glyph set must be generated from the TrueType or OpenType font by the asset tool and keyed by the glyph IDs that HarfBuzz produces. A hand-drawn sheet can't express this.

## 4. Pixel-art rules

- Nearest sampling for every bitmap atlas.
- Glyph origins and pen positions round to whole pixels before drawing.
- Bitmap fonts render at integer scale by default. A non-integer request rounds to the nearest integer and logs a diagnostic.
- Mono rasterization is used at small pixel-art sizes, and gray at larger sizes. The mode belongs to the glyph source, not the renderer.
- A missing glyph draws the font's fallback, which is `?` by default.

## 5. MSDF path (optional)

- **Generation:** offline, in the asset builder, using msdf-atlas-gen pinned under the dependency policy.
- **Atlas:** an RGB(A) distance field with one entry per glyph, independent of size.
- **Shader:** a median of the channels with a screen-space range, written in Slang for every GPU backend.
- **Scope:** outline fonts only. Bitmap fonts never use it.
- **SDL 2D renderer:** this renderer doesn't accept custom fragment shaders, so MSDF can't draw there. By default, MSDF text falls back to the bitmap renderer, using the same font rasterized at the requested size, and logs a diagnostic.

## 6. Work order

Two tracks feed one API:

- **Track A, pixel-art bitmap:** the bitmap importer, bitmap metrics and layout, the nearest-filtered renderer, and the cache.
- **Track B, outline text:** this is the accepted Latin and Tamil scope from the migration plan. It covers runtime TrueType rasterization (Phase 2), the glyph cache (Phase 3), and HarfBuzz shaping (Phase 4).

MSDF follows Track B as an optional renderer after Phase 5. Markup follows Phase 5 too.

| Order | Work | Why | Migration plan link |
|---|---|---|---|
| 1 | Text API and font interface | Sets the seam first, so later work doesn't rewrite callers | New. Defined before Phase 2 |
| 2 | Bitmap font importer (BMFont and legacy `.bfnt`) | Essential for pixel art | New. Keeps `.bfnt` loading |
| 3 | Bitmap metrics and layout | Enables text layout | Phase 5, plain-text path |
| 4 | Nearest-filtered bitmap renderer | Preserves the pixel look | Phase 5, renderer path |
| 5 | Runtime TrueType rasterization and glyph cache | Outline fonts and any-size text | Phases 2 and 3 |
| 6 | HarfBuzz shaping | Tamil, and Latin kerning through OpenType | Phase 4 |
| 7 | Layout on shaped runs | Tamil wrapping on cluster boundaries | Phase 5 |
| 8 | MSDF generator and shader | Optional outline renderer | After Phase 5 |
| 9 | Markup | Decided: after Phase 5 | After Phase 5 |

The priority list in the design direction left out shaping and runtime rasterization. Both are needed for the accepted Tamil scope, so they stay in the plan. Track A and Track B can run in either order. Track A is listed first because the default look is pixel art.

## 7. Decisions

These are defaults. Confirm or change each one.

- **D1. Hand-drawn bitmap format:** BMFont text (`.fnt` plus PNG pages).
- **D2. Complex scripts in bitmap fonts:** generated from the outline font and keyed by glyph ID (section 3.3).
- **D3. MSDF on the 2D renderer:** fall back to the bitmap renderer with the same font.
- **D4. Bitmap scale:** integer only. Non-integer requests round and log.
- **D5. MSDF generation:** offline in the asset builder, not at runtime.
- **D6. Track order:** Track A first, then Track B.
- **D7. Legacy `.bfnt`:** keeps loading during migration, as a bitmap glyph source. Removed only after its consumers have moved.

Still awaiting the owner's answer from the migration plan: the atlas page policy (four 1024² pages with no eviction) and the order of text and Dear ImGui migration.

## 8. Not in this design

- Effects: wave, shake, pulse, color, and reveal. These are a future enhancement. The pixel-snapping choice for effect motion moves with them.
- Markup, which comes after Phase 5.
- Bidirectional, right-to-left, and vertical text; variable and color fonts.
- Runtime CFF. It stays prebaked, as decided in Phase 0.
