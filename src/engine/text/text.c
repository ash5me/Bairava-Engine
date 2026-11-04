/*
 * text.c: loads prebaked bitmap fonts and turns strings into glyph quads.
 *
 * The BFNT file was baked offline (see tools/assets/font_bake.c), so loading only parses and checks
 * it, and drawing only copies rectangles out of the atlas. Nothing here reads font outlines.
 */
#include "text.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define ATLAS_MAX 4096

static int round_px(float v);
static int compare_kerning(const void *a, const void *b);

/* Nearest whole pixel, halves away from zero. Glyphs are placed on whole pixels so they stay sharp. */
static int round_px(float v) {
    return (int)(v < 0 ? v - 0.5f : v + 0.5f);
}

/* Decodes the codepoint at text[*pos] and moves *pos past it. Malformed input decodes to U+FFFD
 * and moves one byte, so a bad byte can never stall the loop. */
static int utf8_next(const char *text, size_t len, size_t *pos) {
    unsigned char lead = (unsigned char)text[*pos];
    int extra, cp, i;
    if (lead < 0x80) {
        *pos += 1;
        return lead;
    }
    if ((lead & 0xE0) == 0xC0) {
        extra = 1;
        cp = lead & 0x1F;
    } else if ((lead & 0xF0) == 0xE0) {
        extra = 2;
        cp = lead & 0x0F;
    } else if ((lead & 0xF8) == 0xF0) {
        extra = 3;
        cp = lead & 0x07;
    } else {
        *pos += 1;
        return 0xFFFD;
    }
    if (len - *pos <= (size_t)extra) {
        *pos += 1;
        return 0xFFFD;
    }
    for (i = 1; i <= extra; i++) {
        unsigned char next = (unsigned char)text[*pos + i];
        if ((next & 0xC0) != 0x80) {
            *pos += 1;
            return 0xFFFD;
        }
        cp = (cp << 6) | (next & 0x3F);
    }
    *pos += (size_t)extra + 1;
    return cp;
}

/* The codepoint drawn for `cp`: itself when it was baked, otherwise the font's fallback, which is -1 when
 * the font has none. */
static int drawn_codepoint(const ui_font *font, int cp) {
    if (cp >= font->first && cp < font->first + font->count) return cp;
    return font->fallback;
}

/* The glyph for a codepoint that drawn_codepoint has resolved. NULL means nothing is drawn: the font has no
 * fallback, or the codepoint is not one it can draw. */
static const ui_glyph *glyph_for(const ui_font *font, int drawn) {
    int i;
    if (drawn < 0) return NULL;
    i = drawn - font->first;
    return (i >= 0 && i < font->count) ? &font->glyphs[i] : NULL;
}

int ui_font_default_fallback(int first, int count) {
    return ('?' >= first && '?' < first + count) ? '?' : -1;
}

/* Kerning for a pair of drawn codepoints, from the baked table. Pairs not in the table have none. */
static float kerning_for(const ui_font *font, unsigned int left, unsigned int right) {
    int lo = 0, hi = font->kerning_count - 1;
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        const ui_kerning *k = &font->kernings[mid];
        if (k->left == left && k->right == right) return k->advance;
        if (k->left < left || (k->left == left && k->right < right)) lo = mid + 1;
        else hi = mid - 1;
    }
    return 0;
}

static int compare_kerning(const void *a, const void *b) {
    const ui_kerning *ka = (const ui_kerning *)a, *kb = (const ui_kerning *)b;
    if (ka->left != kb->left) return ka->left < kb->left ? -1 : 1;
    if (ka->right != kb->right) return ka->right < kb->right ? -1 : 1;
    return 0;
}

static unsigned short read_u16le(const unsigned char *p) {
    return (unsigned short)(p[0] | ((unsigned short)p[1] << 8));
}

static uint32_t read_u32le(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static float read_f32le(const unsigned char *p) {
    uint32_t bits = read_u32le(p);
    float value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

int ui_font_load_prebaked(const unsigned char *data, size_t len, float expected_pixel_height, ui_font *font) {
    int first, count, atlas_w, atlas_h, version, fallback, kerning_count = 0;
    float pixel_height;
    size_t header_len, pixels, glyph_offset, pixel_offset, expected_len;
    unsigned char *alpha = NULL;
    ui_glyph *glyphs = NULL;
    ui_kerning *kernings = NULL;
    if (font == NULL) return -1;
    memset(font, 0, sizeof *font);
    if (data == NULL) return -1;
    if (len < 48 || memcmp(data, "BFNT", 4) != 0) return -1;
    /* Version 3 carried a signed-distance flag. Those atlases are not rasterized or sampled any more,
     * so they are rejected, and the builder must bake a bitmap atlas instead. Version 4 adds the fallback
     * codepoint to the header; v1 and v2 predate it and use the default. */
    version = read_u16le(data + 4);
    header_len = version == 1 ? 48u : version == 2 ? 52u : version == 4 ? 56u : 0u;
    if (header_len == 0 || (size_t)read_u16le(data + 6) != header_len || len < header_len) return -1;
    pixel_height = read_f32le(data + 8);
    first = (int)(int32_t)read_u32le(data + 12);
    count = (int)(int32_t)read_u32le(data + 16);
    atlas_w = (int)read_u32le(data + 28);
    atlas_h = (int)read_u32le(data + 32);
    if (!(pixel_height > 0 && pixel_height == expected_pixel_height) || first < 0 || count <= 0 ||
        (uint64_t)(unsigned int)first + (unsigned int)count > 0x110000u ||
        atlas_w <= 0 || atlas_h <= 0 || atlas_w > ATLAS_MAX || atlas_h > ATLAS_MAX) return -1;
    pixels = (size_t)atlas_w * (size_t)atlas_h;
    if (read_u32le(data + 36) != pixels) return -1;
    fallback = ui_font_default_fallback(first, count);
    if (version == 4) {
        fallback = (int)(int32_t)read_u32le(data + 52);
        if (fallback != -1 && (fallback < first || fallback >= first + count)) return -1;
    }
    glyph_offset = header_len;
    if (version >= 2) {
        uint32_t raw_count = read_u32le(data + 48);
        if (raw_count > 1u << 20) return -1;
        kerning_count = (int)raw_count;
    }
    if ((size_t)count > (SIZE_MAX - glyph_offset) / 20) return -1;
    pixel_offset = glyph_offset + (size_t)count * 20;
    if ((size_t)kerning_count > (SIZE_MAX - pixel_offset) / 12) return -1;
    pixel_offset += (size_t)kerning_count * 12;
    if (pixels > SIZE_MAX - pixel_offset) return -1;
    expected_len = pixel_offset + pixels;
    if (len != expected_len) return -1;

    glyphs = (ui_glyph *)calloc((size_t)count, sizeof *glyphs);
    alpha = (unsigned char *)malloc(pixels);
    kernings = kerning_count > 0 ? (ui_kerning *)calloc((size_t)kerning_count, sizeof *kernings) : NULL;
    if (glyphs == NULL || alpha == NULL || (kerning_count > 0 && kernings == NULL)) goto fail;
    for (int i = 0; i < count; i++) {
        const unsigned char *src = data + glyph_offset + (size_t)i * 20;
        ui_glyph *g = &glyphs[i];
        g->x0 = read_u16le(src + 0); g->y0 = read_u16le(src + 2);
        g->x1 = read_u16le(src + 4); g->y1 = read_u16le(src + 6);
        g->xoff = read_f32le(src + 8); g->yoff = read_f32le(src + 12); g->xadvance = read_f32le(src + 16);
        if (g->x0 > g->x1 || g->y0 > g->y1 || g->x1 > atlas_w || g->y1 > atlas_h ||
            !(g->xoff == g->xoff && g->yoff == g->yoff && g->xadvance == g->xadvance) ||
            g->xoff < -atlas_w || g->xoff > atlas_w || g->yoff < -atlas_h || g->yoff > atlas_h ||
            g->xadvance < 0 || g->xadvance > atlas_w * 2) goto fail;
    }
    for (int i = 0; i < kerning_count; i++) {
        const unsigned char *src = data + glyph_offset + (size_t)count * 20 + (size_t)i * 12;
        kernings[i].left = read_u32le(src);
        kernings[i].right = read_u32le(src + 4);
        kernings[i].advance = read_f32le(src + 8);
        if (kernings[i].left < (unsigned int)first || kernings[i].right < (unsigned int)first ||
            kernings[i].left >= (unsigned int)(first + count) || kernings[i].right >= (unsigned int)(first + count) ||
            !(kernings[i].advance == kernings[i].advance) || kernings[i].advance < -atlas_w || kernings[i].advance > atlas_w) goto fail;
        if (i > 0 && compare_kerning(&kernings[i - 1], &kernings[i]) >= 0) goto fail;
    }
    memcpy(alpha, data + pixel_offset, pixels);
    font->first = first;
    font->count = count;
    font->fallback = fallback;
    font->pixel_height = pixel_height;
    font->ascent = (int)(int32_t)read_u32le(data + 20);
    font->line_height = (int)(int32_t)read_u32le(data + 24);
    font->atlas_w = atlas_w;
    font->atlas_h = atlas_h;
    font->alpha = alpha;
    font->glyphs = glyphs;
    font->kernings = kernings;
    font->kerning_count = kerning_count;
    font->white = (ui_rect){ read_u16le(data + 40), read_u16le(data + 42), read_u16le(data + 44), read_u16le(data + 46) };
    if (font->white.x < 0 || font->white.y < 0 || font->white.w <= 0 || font->white.h <= 0 ||
        font->white.x + font->white.w > atlas_w || font->white.y + font->white.h > atlas_h || font->line_height <= 0) goto fail_font;
    return 0;

fail_font:
    memset(font, 0, sizeof *font);
fail:
    free(alpha);
    free(glyphs);
    free(kernings);
    return -1;
}

void ui_font_destroy(ui_font *font) {
    free(font->alpha);
    free(font->glyphs);
    free(font->kernings);
    memset(font, 0, sizeof *font);
}

void ui_font_release_atlas(ui_font *font) {
    if (font == NULL) return;
    free(font->alpha);
    font->alpha = NULL;
}

float ui_font_text_width(ui_font *font, const char *text, size_t len) {
    return ui_font_text_width_scaled(font, text, len, 1.0f);
}

float ui_font_text_width_scaled(ui_font *font, const char *text, size_t len, float scale) {
    float width = 0;
    size_t pos = 0;
    int previous = -1;
    if (!(scale > 0)) return 0;
    while (pos < len) {
        int drawn = drawn_codepoint(font, utf8_next(text, len, &pos));
        const ui_glyph *g = glyph_for(font, drawn);
        if (!g) continue;
        if (previous >= 0) width += kerning_for(font, (unsigned int)previous, (unsigned int)drawn) * scale;
        width += g->xadvance * scale;
        previous = drawn;
    }
    return width;
}

void ui_font_draw_text(ui_font *font, ui_quad_list *out, float x, float y, const char *text, size_t len, ui_color color) {
    ui_font_draw_text_scaled(font, out, x, y, text, len, color, 1.0f);
}

void ui_font_draw_text_scaled(ui_font *font, ui_quad_list *out, float x, float y, const char *text, size_t len, ui_color color, float scale) {
    int baseline;
    float pen = x;
    size_t pos = 0;
    int previous = -1;
    if (!(scale > 0)) return;
    baseline = round_px(y) + round_px(font->ascent * scale);
    while (pos < len) {
        int drawn = drawn_codepoint(font, utf8_next(text, len, &pos));
        const ui_glyph *g = glyph_for(font, drawn);
        int w, h;
        if (!g) continue;
        if (previous >= 0) pen += kerning_for(font, (unsigned int)previous, (unsigned int)drawn) * scale;
        w = g->x1 - g->x0;
        h = g->y1 - g->y0;
        /* Blank glyphs such as the space have no pixels, but they still move the pen. */
        if (w > 0 && h > 0) {
            ui_rect dst = { (float)round_px(pen + g->xoff * scale), (float)(baseline + round_px(g->yoff * scale)),
                            (float)round_px(w * scale), (float)round_px(h * scale) };
            ui_rect src = { (float)g->x0, (float)g->y0, (float)w, (float)h };
            ui_quad_push(out, dst, src, color);
        }
        pen += g->xadvance * scale;
        previous = drawn;
    }
}
