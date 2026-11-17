Phase 0 baseline for the shipped Arial UI font (assets/font.ttf, Arial 7.07), recorded 2026-11-17.

What is here
  measure.c                 Measures the current prebaked path with the existing runtime loader
                            (src/engine/text/text.c). Prints UI string widths, printable ASCII glyph
                            advances, and baked kerning pairs.
  ui_strings.txt            The 14 UI strings the game and debug overlay draw (from shipped_ui_shaping_check.py).
  m9.txt, m10.txt           measure.c output for ui_font_9px.bfnt (9 px) and default_font_10px.bfnt (10 px).
  compare_arial_ui.py       Kerning sources, baked path versus HarfBuzz at 9 and 10 px, and the gray
                            bake's pixel-height convention.
  compare_arial_ui_output.txt   The comparison output recorded for this folder.
  bake_out/                 The two BFNT files baked from the manifest rows (see Provenance).

Provenance and caveats
  - Baked with tools/assets/build.c and font_bake.c from the uploaded repository, compiled in a scratch
    copy. stb_truetype.h, stb_image.h, stb_rect_pack.h, and stb_image_write.h were taken from upstream
    nothings/stb commit 9600522de53973336fa033a289858a4354cbb04c (stb_truetype 1.28). The two
    *_impl.c files were written in the scratch copy only.
  - FreeType: the build used the system FreeType 2.13 (Ubuntu 24.04). The pinned lock says 2.15.0.
    Mono hinting can differ between FreeType versions, so the 9 px numbers should be rechecked with
    the pinned FreeType before they are relied on.
  - HarfBuzz: 15.1.0, built from the pinned commit 3df40d9b98d6b32f0e4288d4ecfbb158ddb3a372 as a
    shared library.
  - bake_out SHA-256:
      ui_font_9px.bfnt          c4a55f7be59c7592aa739605848607a0718479fbe02f218c7a516b0a3f2eb659
      default_font_10px.bfnt    98a8ffe39823b91b97a4596bc55b0abb8064ff6e9143a89860376fa854cd1d3d
    Compare these with your own bake of the same manifest rows to check the provenance.

Rerun
  gcc -std=c99 -w -Isrc/engine/text -Isrc/engine/ui measure.c src/engine/text/text.c -lm -o measure
  ./measure bake_out/ui_font_9px.bfnt 9 ui_strings.txt > m9.txt
  ./measure bake_out/default_font_10px.bfnt 10 ui_strings.txt > m10.txt
  LD_LIBRARY_PATH=<dir with libharfbuzz.so.0> python3 compare_arial_ui.py ../../../../assets/font.ttf m9.txt m10.txt
