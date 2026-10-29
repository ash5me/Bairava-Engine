/*
 * text.h: bitmap fonts. A TTF file is baked once into a texture atlas of white glyphs, with
 * the coverage in the alpha channel. Each frame, a string becomes one quad per glyph.
 *
 * Only the baked codepoint range can be drawn. Anything outside it draws as '?'. Baked fonts
 * have no kerning and no hinting. Text is UTF-8, decoded into codepoints.
 *
 * This header does not include stb_truetype.h, so only text.c depends on it.
 */
#ifndef UI_TEXT_H
#define UI_TEXT_H

#include <stddef.h>

#include "ui_draw.h"

typedef struct ui_glyph {
    unsigned short x0, y0, x1, y1; /* texel rectangle in the atlas */
    float xoff, yoff;              /* offset from the pen and the baseline, in pixels, y down */
    float xadvance;                /* how far the pen moves after this glyph */
} ui_glyph;

typedef struct ui_font {
    int first, count;      /* baked codepoints: first .. first + count - 1 */
    float pixel_height;
    int ascent;            /* distance from the top of a line to its baseline */
    int line_height;       /* distance from one baseline to the next */
    int atlas_w, atlas_h;  /* square, a power of two */
    unsigned char *rgba;   /* atlas pixels, RGBA8, row 0 at the top. Upload this as a texture. */
    ui_glyph *glyphs;      /* count entries, indexed by codepoint - first */
    ui_rect white;         /* a solid 2x2 block in the atlas, for filled rectangles */
} ui_font;

/* Bakes `count` codepoints from `first` out of TTF data at `pixel_height`. Returns 0 on success.
 * The atlas starts at 128 pixels and doubles until every glyph fits, up to 4096. */
int ui_font_bake(const unsigned char *ttf, size_t len, float pixel_height, int first, int count, ui_font *font);
/* Loads a generated BFNT v1 font atlas and metrics. The requested height must match the baked size. */
int ui_font_load_prebaked(const unsigned char *data, size_t len, float expected_pixel_height, ui_font *font);
void ui_font_destroy(ui_font *font);

/* Width in pixels of the first `len` bytes of UTF-8 text. */
float ui_font_text_width(const ui_font *font, const char *text, size_t len);

/* Appends one quad per visible glyph. (x, y) is the top-left corner of the first line box. */
void ui_font_draw_text(const ui_font *font, ui_quad_list *out, float x, float y, const char *text, size_t len, ui_color color);

#endif
