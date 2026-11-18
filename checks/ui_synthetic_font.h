/*
 * ui_synthetic_font.h: an in-memory BFNT v4 font for the UI quad checks.
 *
 * It needs no FreeType and no stb_truetype, so the checks build with the same gcc line as the
 * characterization harness. The layout follows what ui_font_load_prebaked reads (src/engine/text/text.c):
 *   56-byte v4 header (fallback codepoint at 52), then 95 glyph records of 20 bytes, then the atlas.
 * The font has printable ASCII U+0020..U+007E in a 16-column grid of 8x8 cells, 8 px tall, with the
 * white block 2x2 at (0, 60) in the atlas. Space has no ink and advances 4 px; the others advance 7 px.
 */
#ifndef UI_SYNTHETIC_FONT_H
#define UI_SYNTHETIC_FONT_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "text.h"

#define SYN_ATLAS_W 128
#define SYN_ATLAS_H 64
#define SYN_WHITE_X 0
#define SYN_WHITE_Y 60
#define SYN_PIXEL_HEIGHT 8.0f

typedef struct {
    unsigned char *data;
    size_t len, cap;
} syn_buf;

static inline void syn_put(syn_buf *b, const void *src, size_t n) {
    if (b->len + n > b->cap) {
        b->cap = (b->len + n) * 2 + 64;
        b->data = (unsigned char *)realloc(b->data, b->cap);
    }
    memcpy(b->data + b->len, src, n);
    b->len += n;
}

static inline void syn_u16(syn_buf *b, unsigned v) {
    unsigned char t[2] = { (unsigned char)(v & 0xFF), (unsigned char)((v >> 8) & 0xFF) };
    syn_put(b, t, 2);
}

static inline void syn_u32(syn_buf *b, uint32_t v) {
    unsigned char t[4] = { (unsigned char)(v & 0xFF), (unsigned char)((v >> 8) & 0xFF),
                           (unsigned char)((v >> 16) & 0xFF), (unsigned char)((v >> 24) & 0xFF) };
    syn_put(b, t, 4);
}

static inline void syn_f32(syn_buf *b, float f) {
    uint32_t bits;
    memcpy(&bits, &f, sizeof bits);
    syn_u32(b, bits);
}

/* Loads the synthetic font into `font`. Returns 0 on success, like ui_font_load_prebaked. */
static inline int syn_load_font(ui_font *font) {
    unsigned char atlas[SYN_ATLAS_W * SYN_ATLAS_H];
    syn_buf b = { NULL, 0, 0 };
    int i, rc;

    memset(atlas, 0, sizeof atlas);
    for (i = 0; i < 95; i++) {
        int x0 = (i % 16) * 8, y0 = (i / 16) * 8, x, y;
        if (i == 0) continue; /* space: no ink */
        for (y = 0; y < 7; y++)
            for (x = 0; x < 6; x++)
                atlas[(y0 + y) * SYN_ATLAS_W + x0 + x] = 200;
    }
    for (i = 0; i < 2; i++) {
        int x;
        for (x = 0; x < 2; x++) atlas[(SYN_WHITE_Y + i) * SYN_ATLAS_W + SYN_WHITE_X + x] = 255;
    }

    syn_put(&b, "BFNT", 4);
    syn_u16(&b, 4);                       /* version */
    syn_u16(&b, 56);                      /* header length */
    syn_f32(&b, SYN_PIXEL_HEIGHT);        /* offset 8 */
    syn_u32(&b, 32);                      /* first codepoint, offset 12 */
    syn_u32(&b, 95);                      /* glyph count, offset 16 */
    syn_u32(&b, 7);                       /* ascent, offset 20 */
    syn_u32(&b, 9);                       /* line height, offset 24 */
    syn_u32(&b, SYN_ATLAS_W);             /* offset 28 */
    syn_u32(&b, SYN_ATLAS_H);             /* offset 32 */
    syn_u32(&b, SYN_ATLAS_W * SYN_ATLAS_H); /* pixel count, offset 36 */
    syn_u16(&b, SYN_WHITE_X);             /* white block, offsets 40..47 */
    syn_u16(&b, SYN_WHITE_Y);
    syn_u16(&b, 2);
    syn_u16(&b, 2);
    syn_u32(&b, 0);                       /* kerning count, offset 48 */
    syn_u32(&b, 63);                      /* fallback '?', offset 52 */
    for (i = 0; i < 95; i++) {
        unsigned x0 = (unsigned)((i % 16) * 8), y0 = (unsigned)((i / 16) * 8);
        if (i == 0) { /* space */
            syn_u16(&b, 0); syn_u16(&b, 0); syn_u16(&b, 0); syn_u16(&b, 0);
            syn_f32(&b, 0.0f); syn_f32(&b, 0.0f); syn_f32(&b, 4.0f);
        } else {
            syn_u16(&b, x0); syn_u16(&b, y0); syn_u16(&b, x0 + 6); syn_u16(&b, y0 + 7);
            syn_f32(&b, 0.0f); syn_f32(&b, -7.0f); syn_f32(&b, 7.0f);
        }
    }
    syn_put(&b, atlas, sizeof atlas);

    rc = ui_font_load_prebaked(b.data, b.len, SYN_PIXEL_HEIGHT, font);
    free(b.data);
    return rc;
}

#endif
