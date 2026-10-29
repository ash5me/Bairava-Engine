/*
 * text.c: bakes a TTF into a glyph atlas with stb_truetype, and turns strings into quads.
 *
 * The atlas is RGBA8 with white glyphs. stb's coverage goes into alpha and RGB stays white, so
 * a quad's tint sets the text color. The top two rows hold a solid white block for filled
 * rectangles. stb_truetype bakes into the rows below it, and the glyph rows are shifted to match.
 */
#include "text.h"
#include "stb_truetype.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define ATLAS_MIN 128
#define ATLAS_MAX 4096
#define WHITE_ROWS 2
#define WHITE_COLS 2

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

/* The glyph for a codepoint. Anything outside the baked range draws as '?'. NULL means even '?'
 * was not baked, so there is nothing to draw. */
static const ui_glyph *glyph_for(const ui_font *font, int cp) {
    int i = cp - font->first;
    if (i < 0 || i >= font->count) {
        i = '?' - font->first;
        if (i < 0 || i >= font->count) return NULL;
    }
    return &font->glyphs[i];
}

int ui_font_bake(const unsigned char *ttf, size_t len, float pixel_height, int first, int count, ui_font *font) {
    stbtt_fontinfo info;
    stbtt_bakedchar *baked = NULL;
    unsigned char *alpha = NULL, *rgba = NULL;
    int asc, desc, gap, side, rows, i;
    float scale;

    if (font == NULL) return -1;
    memset(font, 0, sizeof *font);
    if (ttf == NULL) return -1;
    if (len < 12 || count <= 0 || pixel_height <= 0 || !stbtt_InitFont(&info, ttf, 0)) return -1;
    stbtt_GetFontVMetrics(&info, &asc, &desc, &gap);
    scale = stbtt_ScaleForPixelHeight(&info, pixel_height);
    baked = malloc(sizeof *baked * (size_t)count);
    if (!baked) return -1;

    /* stb returns a positive row count when every glyph fits, and otherwise a negative count of
     * the glyphs that did. So double the atlas until it returns a positive count. */
    for (side = ATLAS_MIN;; side *= 2) {
        alpha = calloc((size_t)side * side, 1);
        if (!alpha) goto fail;
        /* stb clears all pw * ph bytes it is given. Passing it the rows below the white block keeps
         * that clear inside the buffer and leaves the block alone. */
        rows = stbtt_BakeFontBitmap(ttf, 0, pixel_height, alpha + WHITE_ROWS * side, side, side - WHITE_ROWS, first, count, baked);
        if (rows > 0) break;
        free(alpha);
        alpha = NULL;
        if (side >= ATLAS_MAX) goto fail;
    }

    rgba = malloc((size_t)side * side * 4);
    font->glyphs = malloc(sizeof *font->glyphs * (size_t)count);
    if (!rgba || !font->glyphs) goto fail;

    /* The glyph rows are relative to the bitmap stb was given, which starts below the white block. */
    for (i = 0; i < count; i++) {
        baked[i].y0 += WHITE_ROWS;
        baked[i].y1 += WHITE_ROWS;
    }
    for (int y = 0; y < WHITE_ROWS; y++)
        for (int x = 0; x < WHITE_COLS; x++)
            alpha[y * side + x] = 255;
    for (size_t p = 0; p < (size_t)side * side; p++) {
        rgba[p * 4 + 0] = 255;
        rgba[p * 4 + 1] = 255;
        rgba[p * 4 + 2] = 255;
        rgba[p * 4 + 3] = alpha[p];
    }
    for (i = 0; i < count; i++) {
        font->glyphs[i].x0 = baked[i].x0;
        font->glyphs[i].y0 = baked[i].y0;
        font->glyphs[i].x1 = baked[i].x1;
        font->glyphs[i].y1 = baked[i].y1;
        font->glyphs[i].xoff = baked[i].xoff;
        font->glyphs[i].yoff = baked[i].yoff;
        font->glyphs[i].xadvance = baked[i].xadvance;
    }

    font->first = first;
    font->count = count;
    font->pixel_height = pixel_height;
    font->ascent = round_px((float)asc * scale);
    font->line_height = round_px((float)(asc - desc + gap) * scale);
    font->atlas_w = side;
    font->atlas_h = side;
    font->rgba = rgba;
    font->white = (ui_rect){ 0, 0, WHITE_COLS, WHITE_ROWS };
    free(alpha);
    free(baked);
    return 0;

fail:
    free(alpha);
    free(baked);
    free(rgba);
    free(font->glyphs);
    memset(font, 0, sizeof *font);
    return -1;
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
    int first, count, atlas_w, atlas_h;
    float pixel_height;
    size_t pixels, glyph_offset, pixel_offset, expected_len;
    unsigned char *rgba = NULL;
    ui_glyph *glyphs = NULL;
    if (font == NULL) return -1;
    memset(font, 0, sizeof *font);
    if (data == NULL) return -1;
    if (len < 48 || memcmp(data, "BFNT", 4) != 0 || read_u16le(data + 4) != 1 || read_u16le(data + 6) != 48) return -1;
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
    glyph_offset = 48;
    if ((size_t)count > (SIZE_MAX - glyph_offset) / 20) return -1;
    pixel_offset = glyph_offset + (size_t)count * 20;
    if (pixels > SIZE_MAX - pixel_offset) return -1;
    expected_len = pixel_offset + pixels;
    if (len != expected_len) return -1;

    glyphs = (ui_glyph *)calloc((size_t)count, sizeof *glyphs);
    rgba = (unsigned char *)malloc(pixels * 4);
    if (glyphs == NULL || rgba == NULL) goto fail;
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
    for (size_t i = 0; i < pixels; i++) {
        rgba[i * 4 + 0] = 255;
        rgba[i * 4 + 1] = 255;
        rgba[i * 4 + 2] = 255;
        rgba[i * 4 + 3] = data[pixel_offset + i];
    }
    font->first = first;
    font->count = count;
    font->pixel_height = pixel_height;
    font->ascent = (int)(int32_t)read_u32le(data + 20);
    font->line_height = (int)(int32_t)read_u32le(data + 24);
    font->atlas_w = atlas_w;
    font->atlas_h = atlas_h;
    font->rgba = rgba;
    font->glyphs = glyphs;
    font->white = (ui_rect){ read_u16le(data + 40), read_u16le(data + 42), read_u16le(data + 44), read_u16le(data + 46) };
    if (font->white.x < 0 || font->white.y < 0 || font->white.w <= 0 || font->white.h <= 0 ||
        font->white.x + font->white.w > atlas_w || font->white.y + font->white.h > atlas_h || font->line_height <= 0) goto fail_font;
    return 0;

fail_font:
    memset(font, 0, sizeof *font);
fail:
    free(rgba);
    free(glyphs);
    return -1;
}

void ui_font_destroy(ui_font *font) {
    free(font->rgba);
    free(font->glyphs);
    memset(font, 0, sizeof *font);
}

float ui_font_text_width(const ui_font *font, const char *text, size_t len) {
    float width = 0;
    size_t pos = 0;
    while (pos < len) {
        const ui_glyph *g = glyph_for(font, utf8_next(text, len, &pos));
        if (g) width += g->xadvance;
    }
    return width;
}

void ui_font_draw_text(const ui_font *font, ui_quad_list *out, float x, float y, const char *text, size_t len, ui_color color) {
    int baseline = round_px(y) + font->ascent;
    float pen = x;
    size_t pos = 0;
    while (pos < len) {
        const ui_glyph *g = glyph_for(font, utf8_next(text, len, &pos));
        if (!g) continue;
        int w = g->x1 - g->x0;
        int h = g->y1 - g->y0;
        /* Blank glyphs such as the space have no pixels, but they still move the pen. */
        if (w > 0 && h > 0) {
            ui_rect dst = { (float)round_px(pen + g->xoff), (float)(baseline + round_px(g->yoff)), (float)w, (float)h };
            ui_rect src = { (float)g->x0, (float)g->y0, (float)w, (float)h };
            ui_quad_push(out, dst, src, color);
        }
        pen += g->xadvance;
    }
}
