/*
 * Characterization tests for the current prebaked text runtime (src/engine/text/text.c).
 *
 * These tests record what the code does today. They are not a specification of what it should do.
 * A migration that changes one of these results must do so on purpose and say so in its notes.
 * Lines marked [CURRENT BEHAVIOR] assert an outcome that may be surprising (for example, an overlong
 * UTF-8 sequence is accepted). They are kept so the migration sees the difference, not hidden.
 *
 * The harness builds synthetic BFNT files in memory, so it needs no font, no baker, no FreeType,
 * and no stb_truetype. text.c depends only on the C standard library and ui_draw.h.
 *
 * Build and run from the repository root:
 *   gcc -std=c11 -Wall -Wextra -pedantic -Isrc/engine/text \
 *       -o /tmp/text_characterization phase0/text_characterization/harness.c
 *   /tmp/text_characterization
 */
#include "text.c" /* the implementation under test, so its static helpers are reachable */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_checks = 0;
static int g_failed = 0;
static const char *g_group = "";

static void check(int ok, const char *what) {
    g_checks++;
    if (!ok) {
        g_failed++;
        printf("  FAIL [%s] %s\n", g_group, what);
    }
}

static int near(float a, float b) { return fabsf(a - b) < 1e-4f; }

/* ---------------------------------------------------------------------------------------------
 * Synthetic BFNT builder. The layout follows what ui_font_load_prebaked reads (text.c).
 *   v1: 48-byte header, no kerning count.   v2: 52-byte header, kerning count at 48.
 *   v4: 56-byte header, fallback codepoint at 52.
 *   Then: glyph table (20 bytes each), kerning table (12 bytes each), atlas (1 byte per texel).
 * ------------------------------------------------------------------------------------------- */

typedef struct { unsigned char *data; size_t len, cap; } Buf;

static void buf_put(Buf *b, const void *src, size_t n) {
    if (b->len + n > b->cap) {
        b->cap = (b->len + n) * 2 + 64;
        b->data = realloc(b->data, b->cap);
    }
    memcpy(b->data + b->len, src, n);
    b->len += n;
}
static void put_u16(Buf *b, unsigned v) {
    unsigned char t[2] = { (unsigned char)(v & 0xFF), (unsigned char)((v >> 8) & 0xFF) };
    buf_put(b, t, 2);
}
static void put_u32(Buf *b, uint32_t v) {
    unsigned char t[4] = { (unsigned char)(v & 0xFF), (unsigned char)((v >> 8) & 0xFF),
                           (unsigned char)((v >> 16) & 0xFF), (unsigned char)((v >> 24) & 0xFF) };
    buf_put(b, t, 4);
}
static void put_f32(Buf *b, float f) {
    uint32_t bits;
    memcpy(&bits, &f, sizeof bits);
    put_u32(b, bits);
}

typedef struct { unsigned x0, y0, x1, y1; float xoff, yoff, xadv; } GlyphSpec;
typedef struct { uint32_t left, right; float advance; } KernSpec;

typedef struct {
    int version;                 /* 1, 2, or 4 */
    float pixel_height;
    int first, count, ascent, line_height;
    int atlas_w, atlas_h;
    int pixel_count;             /* written at offset 36; normally atlas_w * atlas_h */
    int white[4];                /* x, y, w, h */
    int fallback;                /* v4 only */
    GlyphSpec *glyphs;           /* count entries */
    KernSpec *kerns;
    int kern_count;
    unsigned char *atlas;        /* atlas_w * atlas_h bytes, row 0 at the top */
} FontSpec;

static unsigned char *build_bfnt(const FontSpec *s, size_t *out_len) {
    Buf b = { NULL, 0, 0 };
    int i;
    unsigned header_len = s->version == 1 ? 48u : s->version == 2 ? 52u : 56u;
    buf_put(&b, "BFNT", 4);
    put_u16(&b, (unsigned)s->version);
    put_u16(&b, header_len);
    put_f32(&b, s->pixel_height);
    put_u32(&b, (uint32_t)s->first);
    put_u32(&b, (uint32_t)s->count);
    put_u32(&b, (uint32_t)s->ascent);
    put_u32(&b, (uint32_t)s->line_height);
    put_u32(&b, (uint32_t)s->atlas_w);
    put_u32(&b, (uint32_t)s->atlas_h);
    put_u32(&b, (uint32_t)s->pixel_count);
    for (i = 0; i < 4; i++) put_u16(&b, (unsigned)s->white[i]);
    if (s->version >= 2) put_u32(&b, (uint32_t)s->kern_count);
    if (s->version == 4) put_u32(&b, (uint32_t)s->fallback);
    for (i = 0; i < s->count; i++) {
        const GlyphSpec *g = &s->glyphs[i];
        put_u16(&b, g->x0); put_u16(&b, g->y0); put_u16(&b, g->x1); put_u16(&b, g->y1);
        put_f32(&b, g->xoff); put_f32(&b, g->yoff); put_f32(&b, g->xadv);
    }
    for (i = 0; i < s->kern_count; i++) {
        put_u32(&b, s->kerns[i].left);
        put_u32(&b, s->kerns[i].right);
        put_f32(&b, s->kerns[i].advance);
    }
    buf_put(&b, s->atlas, (size_t)s->atlas_w * (size_t)s->atlas_h);
    *out_len = b.len;
    return b.data;
}

/* A 128x64 atlas holds printable ASCII in a 16-column grid of 8x8 cells, glyph i at cell i.
 * Each glyph is 6x7 texels, sits 7 px above the baseline, and advances 7 px. Space has no ink
 * and advances 4 px. The white block is 2x2 at (0, 60). */
#define ATLAS_W 128
#define ATLAS_H 64

static void default_glyphs(GlyphSpec *g, int first, int count) {
    int i;
    for (i = 0; i < count; i++) {
        int cp = first + i;
        unsigned x0 = (unsigned)((i % 16) * 8), y0 = (unsigned)((i / 16) * 8);
        g[i].x0 = x0; g[i].y0 = y0; g[i].x1 = x0 + 6; g[i].y1 = y0 + 7;
        g[i].xoff = 0; g[i].yoff = -7; g[i].xadv = 7;
        if (cp == ' ') { g[i].x0 = g[i].y0 = g[i].x1 = g[i].y1 = 0; g[i].xadv = 4; }
    }
}

/* Builds the standard test font: printable ASCII, '?' fallback unless `fallback` says otherwise,
 * one kerning pair A-V of -1.5 px, and 'A' advancing 8 px instead of 7. */
static void standard_spec(FontSpec *s, GlyphSpec *glyphs, KernSpec *kerns, unsigned char *atlas, int fallback) {
    memset(s, 0, sizeof *s);
    memset(atlas, 0, ATLAS_W * ATLAS_H);
    s->version = 4;
    s->pixel_height = 8.0f;
    s->first = 32;
    s->count = 95;
    s->ascent = 8;
    s->line_height = 10;
    s->atlas_w = ATLAS_W;
    s->atlas_h = ATLAS_H;
    s->pixel_count = ATLAS_W * ATLAS_H;
    s->white[0] = 0; s->white[1] = 60; s->white[2] = 2; s->white[3] = 2;
    memset(atlas + 60 * ATLAS_W, 255, 2 * ATLAS_W); /* the white block: rows 60..61 */
    s->atlas = atlas;
    default_glyphs(glyphs, s->first, s->count);
    glyphs['A' - 32].xadv = 8; /* 'A' advances 8 px */
    s->glyphs = glyphs;
    kerns[0].left = 'A'; kerns[0].right = 'V'; kerns[0].advance = -1.5f;
    s->kerns = kerns;
    s->kern_count = 1;
    s->fallback = fallback;
}

/* Loads a built font. Returns 0 on success. */
static int load_spec(FontSpec *s, float expect_height, ui_font *font) {
    size_t len = 0;
    unsigned char *data = build_bfnt(s, &len);
    int rc = ui_font_load_prebaked(data, len, expect_height, font);
    free(data);
    return rc;
}

/* ---------------------------------------------------------------------------------------------
 * Groups
 * ------------------------------------------------------------------------------------------- */

static void group_loader(void) {
    FontSpec s; GlyphSpec gl[95]; KernSpec kn[2]; unsigned char atlas[ATLAS_W * ATLAS_H];
    ui_font font;
    size_t len = 0;
    unsigned char *data;
    g_group = "loader";

    standard_spec(&s, gl, kn, atlas, '?');
    check(load_spec(&s, 8.0f, &font) == 0, "a v4 font loads at its exact baked height");
    ui_font_destroy(&font);

    check(load_spec(&s, 8.5f, &font) != 0, "a font is rejected at a different requested height");
    check(font.alpha == NULL && font.glyphs == NULL, "a rejected font leaves the output empty");

    /* Height must match exactly, not approximately. */
    check(load_spec(&s, 8.0000005f, &font) != 0, "[CURRENT BEHAVIOR] height compare is exact float equality");

    /* Version rules. */
    s.version = 3;
    check(load_spec(&s, 8.0f, &font) != 0, "version 3 (signed-distance) is rejected");
    s.version = 4;

    /* Structural corruption. */
    data = build_bfnt(&s, &len);
    data[0] = 'X';
    check(ui_font_load_prebaked(data, len, 8.0f, &font) != 0, "bad magic is rejected");
    free(data);

    data = build_bfnt(&s, &len);
    check(ui_font_load_prebaked(data, len - 1, 8.0f, &font) != 0, "a file one byte short is rejected");
    free(data);

    s.pixel_count = ATLAS_W * ATLAS_H + 1;
    check(load_spec(&s, 8.0f, &font) != 0, "a pixel count that disagrees with the atlas size is rejected");
    s.pixel_count = ATLAS_W * ATLAS_H;

    s.kern_count = 2;
    kn[0].left = 'V'; kn[0].right = 'A'; kn[0].advance = 1.0f;
    kn[1].left = 'A'; kn[1].right = 'V'; kn[1].advance = -1.5f;
    check(load_spec(&s, 8.0f, &font) != 0, "kerning pairs out of (left, right) order are rejected");
    kn[0].left = 'A'; kn[0].right = 'V'; kn[0].advance = -1.5f;
    kn[1].left = 'A'; kn[1].right = 'V'; kn[1].advance = -2.0f;
    check(load_spec(&s, 8.0f, &font) != 0, "duplicate kerning pairs are rejected");
    kn[1].left = 'A'; kn[1].right = 0x4E2D; kn[1].advance = 0.5f;
    check(load_spec(&s, 8.0f, &font) != 0, "a kerning codepoint outside the baked range is rejected");
    s.kern_count = 1;

    s.fallback = 200;
    check(load_spec(&s, 8.0f, &font) != 0, "a fallback codepoint outside the baked range is rejected");
    s.fallback = '?';

    s.white[2] = 0;
    check(load_spec(&s, 8.0f, &font) != 0, "a zero-width white block is rejected");
    s.white[2] = 2;

    s.white[1] = ATLAS_H - 1; s.white[3] = 2;
    check(load_spec(&s, 8.0f, &font) != 0, "a white block past the atlas edge is rejected");
    s.white[1] = 60; s.white[3] = 2;

    s.line_height = 0;
    check(load_spec(&s, 8.0f, &font) != 0, "a line height of zero is rejected");
    s.line_height = 10;

    {
        unsigned saved_x1 = gl[1].x1;
        gl[1].x1 = ATLAS_W + 1;
        check(load_spec(&s, 8.0f, &font) != 0, "a glyph rectangle past the atlas edge is rejected");
        gl[1].x1 = saved_x1;
    }

    s.count = 0;
    check(load_spec(&s, 8.0f, &font) != 0, "an empty codepoint range is rejected");
    s.count = 95;

    check(ui_font_load_prebaked(NULL, 0, 8.0f, &font) != 0, "NULL data is rejected");
    check(ui_font_load_prebaked(NULL, 0, 8.0f, NULL) != 0, "NULL font output is rejected");

    /* Older versions, read with the defaults they predate. */
    s.version = 2;
    check(load_spec(&s, 8.0f, &font) == 0, "a v2 font loads");
    check(font.fallback == '?', "[CURRENT BEHAVIOR] v2 gets the default fallback '?' (no field)");
    check(font.kerning_count == 1, "v2 keeps its kerning table");
    ui_font_destroy(&font);

    s.version = 1;
    s.kern_count = 0;
    check(load_spec(&s, 8.0f, &font) == 0, "a v1 font loads");
    check(font.kerning_count == 0, "v1 has no kerning table");
    ui_font_destroy(&font);
}

static void group_measure(void) {
    FontSpec s; GlyphSpec gl[95]; KernSpec kn[1]; unsigned char atlas[ATLAS_W * ATLAS_H];
    ui_font font;
    g_group = "measure";

    standard_spec(&s, gl, kn, atlas, '?');
    if (load_spec(&s, 8.0f, &font) != 0) { check(0, "standard font failed to load"); return; }

    check(near(ui_font_text_width(&font, "", 0), 0), "empty text is 0 wide");
    check(near(ui_font_text_width(&font, "A", 1), 8), "'A' is its advance, 8 px");
    check(near(ui_font_text_width(&font, "AB", 2), 15), "no pair in the table means no kerning (AB = 8 + 7)");
    check(near(ui_font_text_width(&font, "AV", 2), 13.5f), "the baked A-V pair applies (8 - 1.5 + 7)");
    check(near(ui_font_text_width(&font, " ", 1), 4), "space moves the pen by its advance, 4 px");

    /* Fallbacks. */
    check(near(ui_font_text_width(&font, "\xE4\xB8\x80", 3), 7), "a character outside the range measures as '?' (7)");
    check(near(ui_font_text_width(&font, "A\xE4\xB8\x80V", 5), 22),
          "[CURRENT BEHAVIOR] a fallback glyph breaks kerning: A + '?' + V = 8 + 7 + 7");

    /* Scale: linear, and any non-positive or NaN scale measures zero. */
    check(near(ui_font_text_width_scaled(&font, "AV", 2, 2.0f), 27), "scale 2 doubles the width");
    check(ui_font_text_width_scaled(&font, "AV", 2, 0.0f) == 0, "scale 0 measures 0");
    check(ui_font_text_width_scaled(&font, "AV", 2, -1.0f) == 0, "a negative scale measures 0");
    check(ui_font_text_width_scaled(&font, "AV", 2, NAN) == 0, "[CURRENT BEHAVIOR] NaN scale measures 0");

    ui_font_destroy(&font);

    /* Font with no fallback at all. */
    standard_spec(&s, gl, kn, atlas, -1);
    if (load_spec(&s, 8.0f, &font) != 0) { check(0, "no-fallback font failed to load"); return; }
    check(ui_font_text_width(&font, "\xE4\xB8\x80", 3) == 0, "with no fallback, a missing character measures 0");
    check(near(ui_font_text_width(&font, "A\xE4\xB8\x80V", 5), 13.5f),
          "[CURRENT BEHAVIOR] with no fallback, kerning carries across a skipped character (A-V still applies)");
    ui_font_destroy(&font);
}

static void group_utf8(void) {
    size_t pos;
    int cp;
    g_group = "utf8";

    /* Well-formed input decodes as usual. */
    pos = 0; cp = utf8_next("A", 1, &pos);
    check(cp == 'A' && pos == 1, "ASCII decodes to one byte");
    pos = 0; cp = utf8_next("\xE4\xB8\x80", 3, &pos);
    check(cp == 0x4E00 && pos == 3, "a 3-byte sequence decodes");

    /* Overlong and surrogate forms are accepted. A strict decoder would reject these. */
    pos = 0; cp = utf8_next("\xC1\xA0", 2, &pos);
    check(cp == 0x60 && pos == 2, "[CURRENT BEHAVIOR] overlong 2-byte C1 A0 decodes as U+0060 (accepted)");
    pos = 0; cp = utf8_next("\xE0\x80\x80", 3, &pos);
    check(cp == 0 && pos == 3, "[CURRENT BEHAVIOR] overlong 3-byte E0 80 80 decodes as U+0000 (accepted)");
    pos = 0; cp = utf8_next("\xED\xA0\x80", 3, &pos);
    check(cp == 0xD800 && pos == 3, "[CURRENT BEHAVIOR] surrogate ED A0 80 decodes as U+D800 (accepted)");
    pos = 0; cp = utf8_next("\xF4\x90\x80\x80", 4, &pos);
    check(cp == 0x110000 && pos == 4, "[CURRENT BEHAVIOR] code point past U+10FFFF decodes (accepted)");

    /* Malformed input yields U+FFFD and advances exactly one byte. */
    pos = 0; cp = utf8_next("\x80", 1, &pos);
    check(cp == 0xFFFD && pos == 1, "a lone continuation byte is U+FFFD, one byte consumed");
    pos = 0; cp = utf8_next("\xC3", 1, &pos);
    check(cp == 0xFFFD && pos == 1, "a truncated sequence at the end is U+FFFD, one byte consumed");
    pos = 0; cp = utf8_next("\xE4\x41\x42", 3, &pos);
    check(cp == 0xFFFD && pos == 1, "a lead byte followed by a non-continuation is U+FFFD, one byte consumed");
    pos = 0; cp = utf8_next("\xF8\x80\x80\x80\x80", 5, &pos);
    check(cp == 0xFFFD && pos == 1, "a 5-byte lead (F8) is U+FFFD, one byte consumed");

    /* A truncated multi-byte run decodes to one U+FFFD per byte. Count the draws for E4 B8. */
    {
        size_t p = 0, n = 0;
        const char *t = "\xE4\xB8";
        while (p < 2) { utf8_next(t, 2, &p); n++; }
        check(n == 2, "a truncated 3-byte run (E4 B8) takes two steps, one per byte");
    }
}

static void group_draw(void) {
    FontSpec s; GlyphSpec gl[95]; KernSpec kn[1]; unsigned char atlas[ATLAS_W * ATLAS_H];
    ui_font font;
    static ui_quad_list list;
    g_group = "draw";

    standard_spec(&s, gl, kn, atlas, '?');
    if (load_spec(&s, 8.0f, &font) != 0) { check(0, "standard font failed to load"); return; }

    /* 'A' is cell 33: x0 = 8, y0 = 16, size 6x7. */
    list.count = 0; list.dropped = 0;
    ui_font_draw_text(&font, &list, 10.4f, 5.0f, "A", 1, (ui_color){ 1, 0.5f, 0.25f, 0.75f });
    check(list.count == 1, "one visible glyph makes one quad");
    if (list.count == 1) {
        ui_quad q = list.items[0];
        /* Baseline = round(5.0) + round(ascent 8) = 13. dst.y = 13 + round(yoff -7) = 6. */
        check(near(q.dst.x, 10) && near(q.dst.y, 6), "baseline is round(y) + round(ascent); quad top = baseline + round(yoff)");
        check(near(q.dst.w, 6) && near(q.dst.h, 7), "quad size equals the glyph's texel size at scale 1");
        check(near(q.src.x, 8) && near(q.src.y, 16) && near(q.src.w, 6) && near(q.src.h, 7),
              "quad source is the glyph's atlas rectangle");
        check(near(q.color.r, 1) && near(q.color.g, 0.5f) && near(q.color.b, 0.25f) && near(q.color.a, 0.75f),
              "color passes through unchanged");
    }

    /* Whole-pixel placement uses round-half-away-from-zero for the pen. */
    list.count = 0;
    ui_font_draw_text(&font, &list, 10.5f, 0, "A", 1, (ui_color){ 1, 1, 1, 1 });
    check(list.count == 1 && near(list.items[0].dst.x, 11), "x = 10.5 rounds to 11 (half away from zero)");
    list.count = 0;
    ui_font_draw_text(&font, &list, -2.5f, 0, "A", 1, (ui_color){ 1, 1, 1, 1 });
    check(list.count == 1 && near(list.items[0].dst.x, -3), "x = -2.5 rounds to -3 (half away from zero)");

    /* Blank glyphs advance the pen but emit no quad. */
    list.count = 0;
    ui_font_draw_text(&font, &list, 0, 0, " A", 2, (ui_color){ 1, 1, 1, 1 });
    check(list.count == 1 && near(list.items[0].dst.x, 4), "space emits no quad and moves the next glyph by 4");

    /* Kerning applies to drawn pairs, as it does to measurement. */
    list.count = 0;
    ui_font_draw_text(&font, &list, 0, 0, "AV", 2, (ui_color){ 1, 1, 1, 1 });
    check(list.count == 2 && near(list.items[1].dst.x, 7),
          "V's pen lands at 8 - 1.5 = 6.5, which rounds to 7 (half away from zero)");

    /* Unbaked codepoints draw the fallback glyph, '?' at cell 31 (x0 = 120, y0 = 8). */
    list.count = 0;
    ui_font_draw_text(&font, &list, 0, 0, "\xE4\xB8\x80", 3, (ui_color){ 1, 1, 1, 1 });
    check(list.count == 1 && near(list.items[0].src.x, 120) && near(list.items[0].src.y, 8),
          "an unbaked character draws the '?' glyph");

    /* Scale: nearest rounding of each quad, baseline scaled too. */
    list.count = 0;
    ui_font_draw_text_scaled(&font, &list, 0, 0, "A", 1, (ui_color){ 1, 1, 1, 1 }, 2.0f);
    check(list.count == 1 && near(list.items[0].dst.w, 12) && near(list.items[0].dst.h, 14),
          "scale 2 doubles the quad size");
    check(list.count == 1 && near(list.items[0].dst.y, 2), "scale 2: baseline 16, top at 16 + round(-14) = 2");
    list.count = 0;
    ui_font_draw_text_scaled(&font, &list, 0, 0, "A", 1, (ui_color){ 1, 1, 1, 1 }, 0.5f);
    check(list.count == 1 && near(list.items[0].dst.h, 4),
          "scale 0.5: the quad height 3.5 rounds to 4 (half away from zero)");
    list.count = 0;
    ui_font_draw_text_scaled(&font, &list, 0, 0, "A", 1, (ui_color){ 1, 1, 1, 1 }, 0);
    check(list.count == 0, "scale 0 draws nothing");

    /* The list has a fixed capacity; overflow is counted, not drawn. */
    list.count = 0; list.dropped = 0;
    {
        char many[5000];
        memset(many, 'A', sizeof many);
        ui_font_draw_text(&font, &list, 0, 0, many, sizeof many, (ui_color){ 1, 1, 1, 1 });
    }
    check(list.count == UI_MAX_QUADS, "a frame draws at most UI_MAX_QUADS (4096) glyphs");
    check(list.dropped == 5000 - UI_MAX_QUADS, "glyphs past the cap are counted in `dropped`");

    /* Releasing the CPU atlas keeps metrics and drawing intact. */
    ui_font_release_atlas(&font);
    check(font.alpha == NULL, "release_atlas frees the CPU atlas");
    check(near(ui_font_text_width(&font, "AV", 2), 13.5f), "measuring still works after release");
    ui_font_release_atlas(&font);
    ui_font_release_atlas(NULL);
    check(1, "release_atlas is safe to call twice, and on NULL");

    ui_font_destroy(&font);
}

static void group_fallback(void) {
    FontSpec s; GlyphSpec gl[95]; KernSpec kn[1]; unsigned char atlas[ATLAS_W * ATLAS_H];
    ui_font font;
    static ui_quad_list list;
    g_group = "fallback";

    check(ui_font_default_fallback(32, 95) == '?', "default fallback is '?' when the range includes it");
    check(ui_font_default_fallback(0x4E00, 10) == -1, "default fallback is none when the range excludes it");

    standard_spec(&s, gl, kn, atlas, -1);
    if (load_spec(&s, 8.0f, &font) != 0) { check(0, "no-fallback font failed to load"); return; }
    list.count = 0;
    ui_font_draw_text(&font, &list, 0, 0, "\xE4\xB8\x80", 3, (ui_color){ 1, 1, 1, 1 });
    check(list.count == 0, "with no fallback recorded, an unbaked character draws nothing");
    ui_font_destroy(&font);
}

int main(void) {
    printf("Bairava text runtime: characterization of the current prebaked path\n");
    group_loader();
    group_measure();
    group_utf8();
    group_draw();
    group_fallback();
    printf("\n%d checks, %d failed\n", g_checks, g_failed);
    return g_failed == 0 ? 0 : 1;
}
