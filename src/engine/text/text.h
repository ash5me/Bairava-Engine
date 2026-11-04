/*
 * text.h: prebaked bitmap fonts, loaded and drawn by the engine.
 *
 * A font is a BFNT file that the asset builder bakes offline (tools/assets/font_bake.c). It holds an
 * atlas of white glyphs with coverage in the alpha channel, glyph metrics, and kerning pairs. The
 * engine never rasterizes outlines: it parses the file, uploads the atlas once, and each frame a
 * string becomes one quad per glyph. Quads that sample the same atlas are drawn as one batch.
 *
 * A codepoint outside the baked range draws the font's fallback, which is '?' when the font was baked with
 * it and nothing otherwise. Kerning comes only from the baked table. Text is UTF-8 decoded into codepoints
 * and is not shaped.
 *
 * Nothing in this header or in text.c depends on FreeType or stb_truetype.
 */
#ifndef UI_TEXT_H
#define UI_TEXT_H

#include <stddef.h>

#include "../ui/ui_draw.h"

typedef struct ui_glyph {
    unsigned short x0, y0, x1, y1; /* texel rectangle in the atlas */
    float xoff, yoff;              /* offset from the pen and the baseline, in pixels, y down */
    float xadvance;                /* how far the pen moves after this glyph */
} ui_glyph;

typedef struct ui_kerning {
    unsigned int left, right; /* Unicode codepoints */
    float advance;            /* adjustment before the right glyph */
} ui_kerning;

typedef struct ui_font {
    int first, count;      /* baked codepoints: first .. first + count - 1 */
    int fallback;          /* codepoint drawn for a character outside the baked range, or -1 for none */
    float pixel_height;    /* the size the atlas was baked at */
    int ascent;            /* distance from the top of a line to its baseline */
    int line_height;       /* distance from one baseline to the next */
    int atlas_w, atlas_h;  /* power-of-two atlas dimensions, fixed once baked */
    unsigned char *rgba;   /* atlas pixels, RGBA8, row 0 at the top. Upload this as a texture, then call
                              ui_font_release_atlas. NULL once released. */
    ui_glyph *glyphs;      /* count entries, indexed by codepoint - first */
    ui_kerning *kernings;  /* sorted by (left, right), for binary search */
    int kerning_count;
    ui_rect white;         /* a solid 2x2 block in the atlas, for filled rectangles */
} ui_font;

/* The fallback a font gets when it does not record one: '?' when the range includes it, otherwise -1 (none).
 * The baker uses it for every font, and the loader uses it for v1 and v2 files, which predate the field. */
int ui_font_default_fallback(int first, int count);

/* Loads a BFNT v1, v2, or v4 font: its metrics, glyphs, kerning, fallback, and atlas. The file must have been
 * baked at `expected_pixel_height`, or it is rejected. Returns 0 on success. On failure `font` is left empty. */
int ui_font_load_prebaked(const unsigned char *data, size_t len, float expected_pixel_height, ui_font *font);
void ui_font_destroy(ui_font *font);
/* Frees the CPU copy of the atlas once the caller has uploaded it. Metrics, glyphs, and kerning stay valid,
 * and measuring and drawing never read pixels. Safe to call more than once, and on a NULL font. */
void ui_font_release_atlas(ui_font *font);

/* Width in pixels of the first `len` bytes of UTF-8 text. */
float ui_font_text_width(ui_font *font, const char *text, size_t len);
float ui_font_text_width_scaled(ui_font *font, const char *text, size_t len, float scale);

/* Appends one quad per visible glyph. (x, y) is the top-left corner of the first line box. */
void ui_font_draw_text(ui_font *font, ui_quad_list *out, float x, float y, const char *text, size_t len, ui_color color);
void ui_font_draw_text_scaled(ui_font *font, ui_quad_list *out, float x, float y, const char *text, size_t len, ui_color color, float scale);

#endif
