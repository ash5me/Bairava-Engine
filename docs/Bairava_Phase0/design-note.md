# Bairava text rendering: Phase 0 design note

Status: Phase 0 closed 2026-11-17. Decisions D1 to D3 and Q1 to Q3 are the owner's answers. Scope is the rendering migration plan: text rendering only, with the existing SDL GPU and SDL3 2D renderers unchanged.

## 1. Font sources

| Source | Glyph source | Advances | Kerning | Pixel-height convention | Status |
|---|---|---|---|---|---|
| Prebaked mono BFNT (`ui_font_9px`) | FreeType hinted, 1-bit | Baked whole-pixel advances (D1) | Baked; kerns that round to 0 px are dropped (D3) | em (FreeType ppem) | Shipping |
| Prebaked gray BFNT (`default_font_10px`) | stb_truetype coverage | Baked, unhinted | Baked: stb reads GPOS and `kern` | px × upem / (ascent − descent) (D2) | Shipping |
| Legacy BFNT v1, v2, v4 | Prebaked | From file | From file | As baked | Loadable during migration |
| Runtime TrueType outline | stb_truetype, on demand (Phase 2 to 4) | HarfBuzz, unhinted | HarfBuzz GPOS, unrounded | Must match the gray convention (D2), so a gray BFNT and a runtime face at the same size measure the same | Planned |
| CFF or OpenType CFF | Offline FreeType bake only | n/a | n/a | n/a | Not at runtime (Phase 0) |

## 2. Rules for advances, scale, and kerning (D1 to D3)

- **D1, advances.** For prebaked BFNT fonts the baked advance table is authoritative. HarfBuzz advances apply only to fonts whose glyph source is a runtime outline face. The text API must therefore take advances from the font provider, not from the shaper, so that layout of a BFNT font does not change.
- **D2, scale.** A gray TrueType bake takes pixel height as ascent minus descent (stb `ScaleForPixelHeight`). A mono bake takes it as em (FreeType). Both conventions stay. Each font face records its convention in its metadata, and the runtime outline face follows the gray rule.
- **D3, kerning.** A mono bake drops every kern that rounds to zero whole pixels at its baked size. A gray bake keeps all of them. A runtime outline face applies unrounded GPOS kerning.

**Consequence.** Under D1 to D3 the shipped UI fonts render with the same advances, kerning, and widths as today. The migration causes no visible change to shipped text, which is the outcome the plan requires. The measured baseline is in `baseline/arial/`.

## 3. Shaping

- HarfBuzz 15.1.0, from the pinned commit `3df40d9…`, vendored under `vendor/harfbuzz-15.1.0/`. Lock hash `6c1fac27…` verified against the commit export.
- Used for outline fonts only (Phases 3 and 4). BFNT fonts are not shaped for advances.
- Scope: Latin and Tamil, left to right. No bidi, no right-to-left, no vertical text. These are out of scope for this migration.
- The shipped Arial file has GSUB `liga` and other features, but no printable ASCII pair is substituted. Measured: 0 substituted pairs.

## 4. Missing glyphs

- **BFNT.** A codepoint outside the baked range draws the font's fallback, which is `?` when the bake included it, and nothing otherwise (`text.h`). Agreed.
- **Runtime outline (Q3).** A missing codepoint draws the font's `?` glyph when the font has one, and nothing otherwise. Each missing codepoint increments a diagnostic counter.

## 5. Atlas and cache (Q1)

Four 1024² R8 coverage pages, no eviction. A `glyph_cache_full` diagnostic is raised when the pages fill, and no glyph is dropped silently. Static BFNT atlases are not part of the dynamic cache.

Phase 3 decisions (see `Bairava-Engine-Rendering-Migration-Plan.phase0-status.md`, section 21):

- **P3-1, white block (accepted).** A 2×2 solid block at the origin of page 0, reserved and uploaded first. Filled rectangles sample it through the coverage pipeline.
- **P3-2, eager GPU pages (accepted provisionally).** All four GPU pages and their CPU mirrors are created with the atlas. Revisit with the first Phase 5 `pages_in_use` data.
- **P3-10, lazy 2D copies (implemented).** A page's SDL2D copy is made on the first 2D flush that finds the page in use. It is rebuilt from the CPU mirror, kept current while the 2D renderer is active, and released when the renderer leaves 2D. The GPU-only session therefore carries no 2D copies.

Memory: GPU only, 8 MiB. With the 2D renderer and all four pages in use, 24 MiB. Both figures are arithmetic, not measurements.

## 6. Renderers

Both SDL GPU and the SDL3 2D renderer are acceptance targets. The coverage shader and sprite batching are reused. Phase 0 changes no renderer code.

## 7. Consequences for later phases

- **Phase 2.** The runtime face defines the pixel-to-unit mapping once, following D2. It rasterizes by glyph ID.
- **Phase 4.** HarfBuzz positions apply only to outline fonts. BFNT fonts keep their baked advances (D1).
- **Phase 5.** Layout reads advances through the font provider. Layout tests compare BFNT widths with `baseline/arial/`.
- **Dear ImGui (Q2).** The text migration comes first. ImGui's font atlas then becomes a client of the glyph cache, so the coverage atlas has one owner.

## 8. Test corpus

- Latin: all 95 printable ASCII characters in the shipped Arial 7.07 file (`baseline/arial/`).
- UI: the 14 strings the game and overlay draw (`baseline/arial/ui_strings.txt`).
- Tamil: **not testable yet.** The repository has no Tamil TrueType file, and the Tamil checks in `baseline/tamil_font_checker.txt` read the Latin file. A Tamil font with GSUB and GPOS is needed before Phase 4 shaping tests can run.
- Malformed UTF-8 and empty input: planned for Phase 4.

## 9. Dependencies

- HarfBuzz 15.1.0, pinned and vendored, as above.
- stb_truetype 1.28, commit `9600522…`. The raw header SHA-256 is `428cfe93…`, which matches the policy's expected value.
- FreeType stays offline, for the bake only. It is not added to the runtime.

## 10. Phase 0 status: closed

Done: call-site inventory, C runtime characterization (70 of 70), Latin and Tamil scope, format decisions, the bidi decision, BFNT compatibility, D1 to D3, Q1 to Q3, and the measured shipped-font baseline.

Open, none of which blocks Phase 2:
- Tamil test font. Needed before Phase 4 shaping tests.
- Baseline screenshots, which need a display. The plan's exit gate accepts tests or screenshots, and the measured baseline satisfies it. Capture them before Phase 5 exits.
- The 9 px numbers were measured with FreeType 2.13, not the pinned 2.15.0. Recheck them before Phase 5 acceptance.

Phase 2 may start when Phase 1 is green on Linux, Windows, and macOS in CI.
