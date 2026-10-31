/*
 * text.h: TrueType and OpenType fonts are baked into a texture atlas of white glyphs, with
 * coverage or SDF data in the alpha channel. Each frame, a string becomes one quad per glyph.
 *
 * Fonts can lazily rasterize glyphs beyond their baked codepoint range when dynamic caching is
 * enabled. Kerning is applied where the font backend exposes it; text is UTF-8 decoded into
 * individual codepoints and does not perform script shaping.
 *
 * This header does not include stb_truetype.h or FreeType headers; only text.c depends on them.
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
    float pixel_height;
    int ascent;            /* distance from the top of a line to its baseline */
    int line_height;       /* distance from one baseline to the next */
    int atlas_w, atlas_h;  /* power-of-two atlas dimensions; dynamic glyphs can grow its height */
    int sdf;               /* atlas alpha stores signed distance when set */
    float sdf_range;
    int freetype_backend;  /* dynamic cache uses FreeType for this source font */
    unsigned char *rgba;   /* atlas pixels, RGBA8, row 0 at the top. Upload this as a texture. */
    ui_glyph *glyphs;      /* count entries, indexed by codepoint - first */
    ui_kerning *kernings;  /* sorted by (left, right), for binary search */
    int kerning_count;
    unsigned char *source_font; /* retained only when dynamic glyph caching is enabled */
    size_t source_font_len;
    int dynamic_glyphs;
    int *extra_codepoints;
    ui_glyph *extra_glyphs;
    int extra_count, extra_capacity;
    int dynamic_x, dynamic_y, dynamic_row_height;
    unsigned int atlas_generation;
    ui_rect white;         /* a solid 2x2 block in the atlas, for filled rectangles */
} ui_font;

/* Bakes `count` codepoints from `first` out of font data at `pixel_height`. Returns 0 on success.
 * The atlas starts at 128 pixels and doubles until every glyph fits, up to 4096. */
int ui_font_bake(const unsigned char *ttf, size_t len, float pixel_height, int first, int count, ui_font *font);
/* Bakes SDF glyphs for smooth scaling. `distance_range` is the encoded distance range in pixels. */
int ui_font_bake_sdf(const unsigned char *ttf, size_t len, float pixel_height, int first, int count,
                     float distance_range, ui_font *font);
/* Retains the font source and enables lazy rasterization for codepoints outside the baked range. */
int ui_font_enable_dynamic(ui_font *font, const unsigned char *font_data, size_t len);
/* Loads a generated BFNT v1, v2, or v3 font atlas and metrics. The requested height must match the baked size. */
int ui_font_load_prebaked(const unsigned char *data, size_t len, float expected_pixel_height, ui_font *font);
void ui_font_destroy(ui_font *font);

/* Width in pixels of the first `len` bytes of UTF-8 text. */
float ui_font_text_width(ui_font *font, const char *text, size_t len);
float ui_font_text_width_scaled(ui_font *font, const char *text, size_t len, float scale);

/* Appends one quad per visible glyph. (x, y) is the top-left corner of the first line box. */
void ui_font_draw_text(ui_font *font, ui_quad_list *out, float x, float y, const char *text, size_t len, ui_color color);
void ui_font_draw_text_scaled(ui_font *font, ui_quad_list *out, float x, float y, const char *text, size_t len, ui_color color, float scale);

#endif
