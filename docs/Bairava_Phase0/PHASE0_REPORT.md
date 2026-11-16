# Bairava Text Migration: Phase 0 Report

**Status:** Phase 0 is partly complete. Phases 1 to 6 have not started, as the plan requires. Phase 0's exit criteria (agreed font formats, scripts, API behavior, and fallback policy) are not met until the decisions in section 6 are made.

**Inputs:** `bairava.zip` (the engine), `tools.zip` (the SDL3 proof of concept, "PoC"), and `Bairava-Engine-Rendering-Migration-Plan.md`. Nothing in the engine was changed. The plan is unchanged; a status copy with the Phase 0 checkboxes updated sits beside this report.

## 1. Summary

The plan's direction holds. Routing text through HarfBuzz leaves the shipped UI unchanged for the strings tested, and the PoC's Tamil shaping produces the expected cluster structures. Three things in the plan need to change before Phase 1 begins.

The first is the rasterizer. The plan uses stb_truetype without hinting, which would soften the shipped 9 px UI font. The repository renders that font in 1-bit mode, and my measurements show why it matters. FreeType, already vendored and pinned, would have avoided that, and I recommended it. You chose the plan's stb_truetype default instead, and section 6 records what that requires. The second is coordination: the Dear ImGui plan proposes its own font atlas, which the text migration must not duplicate.

Several smaller problems also need owners, including a changelog that describes a glyph cache the code does not contain, and a proof of concept that fetches HarfBuzz from an unpinned branch. Section 3 lists them.

| Plan item | Status | Note |
|---|---|---|
| Inventory call sites | Done | `inventory/call_sites.txt` |
| Record existing public behavior | Done for the C runtime; Zig read, not run | `characterization/` (70 of 70 checks) |
| Define supported scripts and test strings | Accepted: Latin and Tamil | Corpus in section 5 |
| TrueType only, or keep CFF | Decided: runtime TrueType; CFF prebaked only | Section 6 |
| Direction and language controls, RTL | Decided: left to right; no RTL or bidi | Section 6 |
| `.bfnt` loadable during transition | Required by the rasterizer decision; confirm | Section 6 |
| Memory limits and atlas growth | Working assumption: four pages, then fallback | Section 6 |
| Malformed UTF-8 | Decided: lenient decoder, documented | Section 6 |
| Changelog history | Decided: not used as a baseline | Section 6 |
| Baseline screenshots and performance | Blocked here | Needs the full repository and a display; a coverage baseline was captured instead |

## 2. What was checked and how

Each check below ran in this environment. None needed the full build.

| Check | Method | Result | Evidence |
|---|---|---|---|
| Current runtime text behavior | Compiled the engine's `text.c` with gcc and ran a harness that builds synthetic `.bfnt` files | 70 of 70 checks pass. The harness records the current behavior, including the surprising cases in 3.4 | `characterization/` |
| Shaping of Latin and Tamil | HarfBuzz 8.3.0, called through `ctypes` | Kerning applied (A-V narrowed by 152 units, T-o by 227). The Tamil vowel sign O splits into three glyphs. The conjunct க்ஷ forms one ligature | `shaping/snapshot_system_harfbuzz_8.3.0.json` |
| Shipped UI under shaping | VT323 (Bairava's UI font): all 95 printable ASCII characters and 14 UI strings from the game and overlay | Zero differences in glyph ID, advance, or offset | `shaping/shipped_ui_shaping_results.txt` |
| Rasterization of the shipped UI font | stb_truetype (PoC copy) against FreeType 2.13.2, mono and gray, at 9 px | See 3.1 | `rasterization/vt323_9px_results.txt` |
| Atlas size | Glyph bounds at 48 px, with padding and 15% packing loss | Tamil: 190 inked glyphs, one 1024² page. PoC Latin: 4648 glyphs, five pages | `baseline/atlas_estimate.txt` |
| Boundary scan and pin check | Ran the CI commands locally | Boundary: zero reachable violations, self-test 3 of 3. Pin check fails on this upload (3.9) | `baseline/ci_checks_on_upload.txt` |
| Tamil font checker | The PoC's `check_tamil_font.py` on both fonts | `tamil.ttf` reported usable, though its GPOS table has no Tamil script (3.8) | `baseline/tamil_font_checker.txt` |

## 3. Findings

### 3.1 The plan's rasterizer would soften the shipped UI

The shipped UI rows are rendered in mono mode. The baker (`tools/assets/font_bake.c`, `ui_font_bake_mode`) sends every mono row through FreeType at the real size with hinting, producing one-bit texels. `docs/text.md` says the 9 px UI must use this mode. The plan's Phase 2 instead uses stb_truetype, which does not hint and has no 1-bit mode.

The measurement on VT323 at 9 px shows the difference. The `l` glyph's stem gets its ink from a single column at 100% in FreeType's mono output. In stb_truetype's output the same stem splits across two columns at 59% and 24%. FreeType's hinted gray output is also smeared, at 69% and 27%. So the crispness comes from the one-bit mode, not from hinting alone, and a gray rasterizer cannot match the shipped look at this size.

As written, Phase 2 would change how the shipped UI looks, and the plan does not name this requirement anywhere. The Phase 6 screenshot comparison would catch it, but only after the work is done. This should be a requirement at Phase 0.

### 3.2 FreeType is already a pinned dependency

FreeType 2.15.0 is vendored at `vendor/freetype-2.15.0` and locked in `docs/dependency-lock.json`. The baker builds it. `build.zig` says the runtime engine never links it, and `text.h` says nothing in `text.c` depends on FreeType or stb_truetype. My search of `build.zig` found no FreeType in the engine module's wiring. I did not read the whole build file, so confirm this before Phase 1.

Using FreeType at runtime would keep one-bit hinted output for the shipped rows, support CFF without adding a dependency, and let runtime glyphs match baked glyphs for the same font and size. That last property is a strong acceptance test. The costs are real, though. The rule in `text.h` and `docs/text.md` changes. `FT_Face` is not thread-safe, and fonts are parsed on worker threads (`Staged` in `font.zig`), so each face needs a single owner. The runtime binary grows by an amount I did not measure.

### 3.3 Shaping changes Latin spacing for fonts with kerning

For VT323 and the tested strings, shaping produces identical glyphs and positions. The PoC's Latin font does have GPOS kerning, and HarfBuzz applies it. The current prebaked path reads kerning only from the baked table, and the shipped fonts have none. So shipped text is unaffected, but any future font with GPOS pairs will change spacing once it goes through shaping. That is the intended benefit, and it should appear in the migration notes as a visible change.

### 3.4 Malformed UTF-8 has two decoders

`text.c` accepts overlong encodings and surrogates. `C1 A0` decodes to U+0060, and `ED A0 80` to U+D800. The Zig line splitter in `layout.zig` uses `std.unicode`, which rejects both, so the two can disagree about the same bytes. I could not run the Zig side to confirm the exact behavior. Decision: keep the lenient decoder and document it (section 6). That makes `layout.zig` adopt the same rule in Phase 4 or 5, so measuring and splitting agree on every input.

### 3.5 The atlas lifecycle and the 2D renderer

`font.zig` releases the CPU atlas right after upload, and `ui_font_release_atlas` documents that drawing never reads pixels. A growable cache needs either retained CPU pixels or per-glyph GPU updates from staged data. Phase 3 must choose one.

The 2D renderer adds a second copy. `createCoverage` in `renderer/texture.zig` builds an RGBA8 copy of every atlas, and `renderer2d.zig` uploads it as a static SDL texture. `docs/text.md` describes the memory as one R8 texture, a quarter of RGBA8. That figure counts only the GPU path. Each 1024² page costs 1 MiB of R8 on the GPU and 4 MiB of RGBA on the 2D path, plus any retained CPU copy. Dynamic updates must cover both paths: streaming access or replacement on the 2D path, with replacement fenced against queued draws.

### 3.6 Two migrations want the same atlas

`docs/dearimgui-migration-plan.md` replaces the widgets in `src/engine/ui/` with Dear ImGui. Its Phase 4 uploads ImGui's font atlas to an engine texture and supports dynamic rebuilds, and its risk table requires that "one explicit adapter owns upload, rebuild and lifetime." This plan adds a runtime glyph cache with the same ownership question, and it changes the same `Canvas` and `Ui` internals. Without an agreed order, each migration will build its own adapter. This is one of the decisions in section 6.

### 3.7 The changelog and the code disagree

`CHANGES.md` says the project "Added configurable bitmap/SDF font ranges, kerning metadata, dynamic glyph cache growth, and FreeType CFF support." The code does not match. Version 3 files and `sdf` rows are rejected, there is no cache, and the runtime does not link FreeType. The same file also describes a 7 px and then an 8 px Semkootru menu font, while `config.zig` and the manifest use 9 px. Decision: `CHANGES.md` is not used as a baseline for this migration. The code and `docs/text.md` are. The file itself needs correcting in a separate change.

### 3.8 The proof of concept has specific problems

The PoC's README fetches HarfBuzz from the `main` branch archive. `docs/dependency-policy.md` forbids floating branches, and this snapshot is HarfBuzz 15.1.0. Phase 1 must pin a revision.

`shaper.zig` documents `y_offset` as y-down, while `main.zig` subtracts it, which treats it as y-up. The two cannot both be right. Phase 4 needs one conversion in one place and a test that checks a mark's position against a rendered reference.

The shaper also creates a HarfBuzz blob, face, and font on every call, which the plan's ownership rules forbid. Phase 2 should reuse them.

The Tamil checker's verdict ignores GPOS. In the snapshot, marks still receive offsets, so HarfBuzz is finding positioning through a fallback script. The checker warns about something that is not, by itself, a rendering failure.

The PoC caps a frame at 1024 quads, where the engine allows 4096. The atlas also packs a glyph again each time it appears in a shaped run. Neither is a correctness problem, but the engine's limits should be used.

### 3.9 The upload cannot be built

`bairava.zip` contains no `vendor/` directory and no `build.zig.zon`. The pin checker fails for exactly that reason. `CHANGES.md` records the same limitation. Phase 1 needs the full repository, and so does every measurement in section 7.

### 3.10 Gaps in the plan

The plan has no requirement for one-bit or hinted rendering of small UI text (3.1). It does not mention the 4096-quad frame cap, the RGBA copy on the 2D path (3.5), or the overlap with Dear ImGui (3.6). The boundary scanner checks only SDL names, so it cannot yet stop game code from importing HarfBuzz or FreeType. Phase 5 should add those names to `scripts/boundary_scan.py`.

The effort estimate should be revisited after the rasterizer decision. A FreeType runtime reuses an existing build target, which may shorten Phase 1 and Phase 2, but it adds the thread-ownership and lifetime work described in 3.2.

## 4. Compatibility matrix (draft)

| Behavior | Current | Plan requirement | Proposed for first release |
|---|---|---|---|
| Font source | Prebaked `.bfnt` only | Runtime TTF or OTF | Runtime TrueType (glyf); CFF stays prebaked |
| Shaping | None; UTF-8 decoded to codepoints | HarfBuzz for all scripts, including Latin | HarfBuzz for Latin and Tamil |
| Kerning | Baked pair table only | GPOS through shaping | GPOS through shaping; baked pairs still read for old files |
| Rasterization | Baker: stb (TrueType gray), FreeType (mono, CFF) | stb at runtime | stb_truetype 1.26 at runtime, matching the baker's gray output |
| Small UI text | One-bit, hinted, prebaked | Not addressed | Unchanged: prebaked mono rows stay in use; runtime text is softer at small sizes |
| Baseline | `y` is the top of the line box; baseline is `round(y) + round(ascent × scale)` | Preserve | Preserve |
| Pixel placement | Whole-pixel glyphs; halves round away from zero | Preserve | Preserve |
| Scale | Any positive scale; zero, negative, and NaN draw or measure nothing | Preserve | Preserve |
| Unmapped characters | Draw the baked `?` fallback, or nothing | Multi-font fallback out of scope | Preserve |
| Malformed UTF-8 | Lenient; one U+FFFD per bad byte; overlong forms accepted | Deterministic | Lenient decoder shared by measuring and splitting; documented |
| Line wrapping | Splits at spaces and tabs; long words split on codepoints | Cluster-safe | Cluster boundaries; no change for ASCII |
| Frame quad cap | 4096; overflow counted in `dropped` | Preserve | Preserve |
| `.bfnt` loading | v1, v2, v4; exact height match; v3 rejected | Loadable during transition | Preserve; v3 stays rejected |
| Solid rectangles | 2×2 white block in the font atlas | Preserve | Reserve a white texel in the glyph atlas |
| Atlas memory | CPU copy freed after upload | Growth policy | Section 5 |

## 5. Proposals still open

**Runtime rasterizer (D1, decided).** The choice is recorded in section 6, which also keeps the alternatives I weighed.

**Memory and growth (working assumption).** Use 1024² R8 pages, up to four per process. Do not evict in the first release. When the cache is full, draw the fallback glyph and count it in a `glyph_cache_full` diagnostic, so that loss is never silent. The full Tamil glyph set fits in one page. The full PoC Latin set would need five, but on-demand use stays far below that. This is a proposal to test in Phase 3, not a measured limit.

**Test corpus.** Use the shaping cases in `shaping/shape_reference.py` (Tamil conjuncts, vowel signs, the PoC mixed line, and Latin kerning) together with the 95 ASCII characters and 14 UI strings in `shaping/shipped_ui_shaping_check.py`. Phase 1 must regenerate the snapshot with the pinned HarfBuzz version before it is used as an acceptance baseline.

## 6. Decisions

### Recorded

**Runtime rasterizer: stb_truetype.** This is the plan's default, and it is your choice; I had recommended FreeType. The runtime path therefore cannot produce the one-bit hinted look, which brings three consequences.

The shipped 9 px UI font has to stay on its prebaked mono rows, which the baker still writes through FreeType. That makes keeping `.bfnt` loadable a requirement rather than an option. The runtime glyph cache must not serve the small UI sizes. Text rasterized at runtime will be softer than mono at small sizes, and `docs/text.md` must say so when Phase 6 rewrites it.

The stb path is also cheaper than it first looked. stb_truetype is already vendored at 1.26, and the baker uses it for TrueType gray output. A runtime glyph should therefore match a baked gray glyph for the same font and size, which gives an acceptance test with no new dependency. Phase 1 should reuse the vendored 1.26. The PoC's 1.28 fixes composite-glyph scaling, which matters only if a font in use hits that case; upgrading would go through the dependency policy.

**Font formats: runtime TrueType (glyf) only.** OpenType CFF remains a baker input, rasterized by FreeType at bake time, and is not available for runtime glyph caching in this release. The requirement "FreeType rasterization for CFF-based OpenType fonts, including dynamic glyph caching" is deferred, and `requirements.md` should say so.

**Scope: Latin and Tamil, left to right.** Right-to-left, bidi, and multi-font fallback are out. Shaping uses explicit script and language tags (Latn with en, Taml with ta) rather than guessing, and the corpus in section 5 covers both scripts.

### Working assumption, to confirm

**Dear ImGui ordering.** You had no preference, so I am proceeding with the text migration first. The Dear ImGui adapter should consume the new glyph cache rather than build a second atlas, and the Dear ImGui plan needs a line saying so. Tell me if you prefer otherwise.

### Decided in the second round

**Malformed UTF-8: keep the lenient decoder, and document it.** `text.c` keeps accepting overlong forms and surrogates, and any bad byte maps to one U+FFFD. Because `layout.zig` currently uses a strict decoder, it must switch to the same lenient rule in Phase 4 or 5. Measuring and splitting then agree on every input. The change needs a test with an overlong sequence, and `docs/text.md` must state the rule.

**Glyph cache limit: four pages, then fallback (working assumption).** You had no preference, so I adopted the proposal: four 1024² R8 pages per process, no eviction in the first release, and a `glyph_cache_full` diagnostic whenever a glyph falls back. Confirm or change it when Phase 3 designs the cache.

**CHANGES.md: not a baseline.** You asked that it not be followed. The code and `docs/text.md` define the baseline, and this plan relies on neither the changelog's glyph-cache claim nor its FreeType CFF claim. The file should be corrected in a separate change, outside this migration.

### Phase 0 exit

Phase 0's exit criteria are met. Font formats, scripts, public API behavior, and fallback policy are agreed, subject to the working assumptions above and to the Dear ImGui ordering. Baseline screenshots and performance numbers remain a blocked checklist item, not an exit criterion, and they move to Phase 1 and Phase 6.

### What Phase 1 needs

Phase 1 cannot start in this environment. It needs the full repository, including `vendor/` and `build.zig.zon`, which this upload lacks. It also needs Zig 0.16.0-dev.3142+5ccfeb926 and slangc 2026.20, as recorded in the lock file. It needs network access to fetch and hash a HarfBuzz revision the team chooses, and the CI platform matrix, which proves the link on Linux, Windows, and macOS. Phase 1 then pins HarfBuzz, reuses the vendored stb_truetype 1.26, and runs the pin checker.

## 7. What could not be done here

No Zig code was compiled or run, because there is no Zig compiler, no `vendor/` tree, and no `build.zig.zon`. No screenshots were taken, because there is no display or GPU, so the visual comparison in Phase 6 is not started. No performance numbers were recorded.

Several versions differ from the ones that will ship. The shaping snapshot uses HarfBuzz 8.3.0, the PoC uses 15.1.0, and Phase 1 will pin something else. The rasterization comparison used the PoC's stb_truetype 1.28 and the system FreeType 2.13.2, while the repository locks stb 1.26 and vendors FreeType 2.15.0. The comparison should be rerun with the locked versions. The layout code was read but not executed.

## 8. Package contents

```
Bairava_Phase0/
  PHASE0_REPORT.md                       this report
  Bairava-Engine-Rendering-Migration-Plan.phase0-status.md   plan copy with Phase 0 boxes updated
  characterization/harness.c             runtime behavior tests (C, uses text.c directly)
  characterization/results.txt           70 of 70 pass
  shaping/shape_reference.py             HarfBuzz reference snapshot via ctypes
  shaping/snapshot_system_harfbuzz_8.3.0.json
  shaping/shipped_ui_shaping_check.py    VT323 and UI strings under shaping
  shaping/shipped_ui_shaping_results.txt
  rasterization/compare_raster.c         stb vs FreeType comparison for VT323 at 9 px
  rasterization/vt323_9px_results.txt
  baseline/ci_checks_on_upload.txt       boundary and pin checks on the upload
  baseline/tamil_font_checker.txt        PoC font checker output
  baseline/atlas_estimate.py, .txt       atlas size estimate
  inventory/call_sites.txt               text call sites, grouped
```

To reproduce, run the harness from the repository root with `gcc -std=c11 -Wall -Wextra -pedantic -Isrc/engine/text characterization/harness.c`. Run `shaping/shape_reference.py --assets <PoC>/assets`, and `shaping/shipped_ui_shaping_check.py <repo>/assets/font.ttf`. For the rasterization comparison, compile `compare_raster.c` with the FreeType headers and the PoC's `third_party` directory on the include path.
