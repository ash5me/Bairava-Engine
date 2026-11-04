/*
 * font_bake.c: bakes TrueType and OpenType outlines into a bitmap glyph atlas, offline.
 *
 * The atlas is RGBA8 with white glyphs. Coverage goes into alpha and RGB stays white, so a quad's tint
 * sets the text color. The top two rows hold a solid white block for filled rectangles, and glyph pixels
 * are written below it.
 *
 * TrueType outlines are rasterized by stb_truetype. OpenType CFF outlines, which stb_truetype does not
 * read, are rasterized by FreeType at FONT_OVERSAMPLE times the size and box-filtered down, so they
 * come out with the same weight and placement as the TrueType path.
 */
#include "font_bake.h"

#include "stb_truetype.h"

#include <ft2build.h>
#include FT_FREETYPE_H

#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define ATLAS_MIN 128
#define ATLAS_MAX 4096
#define WHITE_ROWS 2
#define WHITE_COLS 2
#define FONT_OVERSAMPLE 3

static int round_px(float v);
static int compare_kerning(const void *a, const void *b);

typedef struct ft_bitmap_copy {
    unsigned char *pixels;
    int width, height, left, top;
    float advance;
} ft_bitmap_copy;

static int ft_open_face(const unsigned char *data, size_t len, float pixel_height, FT_Library *library, FT_Face *face) {
    if (!data || len == 0 || len > (size_t)LONG_MAX || FT_Init_FreeType(library) != 0) return 0;
    if (FT_New_Memory_Face(*library, data, (FT_Long)len, 0, face) != 0) {
        FT_Done_FreeType(*library);
        *library = NULL;
        return 0;
    }
    if (FT_Set_Char_Size(*face, 0, (FT_F26Dot6)(pixel_height * (float)FONT_OVERSAMPLE * 64.0f + 0.5f), 72, 72) != 0) {
        FT_Done_Face(*face);
        FT_Done_FreeType(*library);
        *face = NULL;
        *library = NULL;
        return 0;
    }
    return 1;
}

static int ft_copy_bitmap(const FT_Bitmap *bitmap, unsigned char **pixels) {
    int pitch = bitmap->pitch < 0 ? -bitmap->pitch : bitmap->pitch;
    size_t size = (size_t)bitmap->width * bitmap->rows;
    unsigned char *copy;
    if (!bitmap->width || !bitmap->rows) { *pixels = NULL; return 1; }
    if (bitmap->pixel_mode != FT_PIXEL_MODE_GRAY && bitmap->pixel_mode != FT_PIXEL_MODE_MONO) return 0;
    copy = malloc(size);
    if (!copy) return 0;
    for (unsigned int y = 0; y < bitmap->rows; y++) {
        const unsigned char *row = bitmap->buffer + (bitmap->pitch >= 0 ? (size_t)y * pitch : (size_t)(bitmap->rows - 1 - y) * pitch);
        for (unsigned int x = 0; x < bitmap->width; x++) {
            unsigned char value;
            if (bitmap->pixel_mode == FT_PIXEL_MODE_MONO)
                value = (row[x >> 3] & (0x80u >> (x & 7))) ? 255 : 0;
            else if (bitmap->num_grays > 1 && bitmap->num_grays != 256)
                value = (unsigned char)((unsigned int)row[x] * 255u / (bitmap->num_grays - 1));
            else value = row[x];
            copy[(size_t)y * bitmap->width + x] = value;
        }
    }
    *pixels = copy;
    return 1;
}

/* Renders one codepoint at FONT_OVERSAMPLE times the size and box-filters it to the final size. */
static int ft_render_codepoint(FT_Face face, int cp, ft_bitmap_copy *out) {
    FT_Int32 flags = FT_LOAD_DEFAULT | FT_LOAD_NO_BITMAP;
    unsigned char *raw;
    memset(out, 0, sizeof *out);
    if (FT_Load_Char(face, (FT_ULong)cp, flags) != 0) return 0;
    if (FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL) != 0) return 0;
    out->width = ((int)face->glyph->bitmap.width + FONT_OVERSAMPLE - 1) / FONT_OVERSAMPLE;
    out->height = ((int)face->glyph->bitmap.rows + FONT_OVERSAMPLE - 1) / FONT_OVERSAMPLE;
    out->left = (face->glyph->bitmap_left + FONT_OVERSAMPLE / 2) / FONT_OVERSAMPLE;
    out->top = (face->glyph->bitmap_top + FONT_OVERSAMPLE / 2) / FONT_OVERSAMPLE;
    out->advance = (float)face->glyph->advance.x / 64.0f / (float)FONT_OVERSAMPLE;
    if (!ft_copy_bitmap(&face->glyph->bitmap, &raw)) return 0;
    if (out->width <= 0 || out->height <= 0 || !raw) { free(raw); return 1; }
    out->pixels = malloc((size_t)out->width * (size_t)out->height);
    if (!out->pixels) { free(raw); return 0; }
    for (int y = 0; y < out->height; y++) {
        for (int x = 0; x < out->width; x++) {
            unsigned sum = 0;
            unsigned samples = 0;
            for (int oy = 0; oy < FONT_OVERSAMPLE; oy++) {
                int sy = y * FONT_OVERSAMPLE + oy;
                if (sy >= (int)face->glyph->bitmap.rows) continue;
                for (int ox = 0; ox < FONT_OVERSAMPLE; ox++) {
                    int sx = x * FONT_OVERSAMPLE + ox;
                    if (sx >= (int)face->glyph->bitmap.width) continue;
                    sum += raw[(size_t)sy * face->glyph->bitmap.width + sx];
                    samples++;
                }
            }
            out->pixels[(size_t)y * out->width + x] = samples ? (unsigned char)(sum / samples) : 0;
        }
    }
    free(raw);
    return 1;
}

static int ui_font_bake_freetype(const unsigned char *data, size_t len, float pixel_height, int first, int count, ui_font *font) {
    FT_Library library = NULL;
    FT_Face face = NULL;
    ft_bitmap_copy *bitmaps = NULL;
    ui_kerning *kernings = NULL;
    unsigned char *rgba = NULL;
    int side, x, y, row_height, kerning_count = 0, asc, line_height;
    int ok = 0;
    if (!font) return -1;
    memset(font, 0, sizeof *font);
    if (!data || len == 0 || count <= 0 || first < 0 || first + (int64_t)count > 0x110000 || !(pixel_height > 0) ||
        !ft_open_face(data, len, pixel_height, &library, &face)) return -1;
    asc = round_px((float)face->size->metrics.ascender / 64.0f / (float)FONT_OVERSAMPLE);
    line_height = round_px((float)face->size->metrics.height / 64.0f / (float)FONT_OVERSAMPLE);
    bitmaps = (ft_bitmap_copy *)calloc((size_t)count, sizeof *bitmaps);
    font->glyphs = (ui_glyph *)calloc((size_t)count, sizeof *font->glyphs);
    if (!bitmaps || !font->glyphs) goto done;
    for (int i = 0; i < count; i++) {
        if (!ft_render_codepoint(face, first + i, &bitmaps[i])) goto done;
        font->glyphs[i].xoff = (float)bitmaps[i].left;
        font->glyphs[i].yoff = (float)-bitmaps[i].top;
        font->glyphs[i].xadvance = bitmaps[i].advance;
    }
    for (side = ATLAS_MIN; side <= ATLAS_MAX; side *= 2) {
        int fits = 1;
        /* Glyphs start below the white block, so the top WHITE_ROWS rows hold only the solid rectangle. */
        x = WHITE_COLS + 1; y = WHITE_ROWS; row_height = 0;
        for (int i = 0; i < count; i++) {
            int w = bitmaps[i].width, h = bitmaps[i].height;
            if (w <= 0 || h <= 0) { font->glyphs[i].x0 = font->glyphs[i].x1 = 0; font->glyphs[i].y0 = font->glyphs[i].y1 = 0; continue; }
            if (x + w + 1 > side) { x = 0; y += row_height + 1; row_height = 0; }
            if (y + h + 1 > side) { fits = 0; break; }
            font->glyphs[i].x0 = (unsigned short)x; font->glyphs[i].y0 = (unsigned short)y;
            font->glyphs[i].x1 = (unsigned short)(x + w); font->glyphs[i].y1 = (unsigned short)(y + h);
            x += w + 1; if (h > row_height) row_height = h;
        }
        if (fits) break;
        if (side == ATLAS_MAX) goto done;
    }
    rgba = malloc((size_t)side * side * 4);
    if (!rgba) goto done;
    for (size_t p = 0; p < (size_t)side * side; p++) {
        rgba[p * 4] = rgba[p * 4 + 1] = rgba[p * 4 + 2] = 255;
        rgba[p * 4 + 3] = 0;
    }
    for (int yy = 0; yy < WHITE_ROWS; yy++) for (int xx = 0; xx < WHITE_COLS; xx++) rgba[((size_t)yy * side + xx) * 4 + 3] = 255;
    for (int i = 0; i < count; i++) {
        ui_glyph *g = &font->glyphs[i];
        int w = g->x1 - g->x0, h = g->y1 - g->y0;
        if (w <= 0 || h <= 0) continue;
        for (int yy = 0; yy < h; yy++) for (int xx = 0; xx < w; xx++)
            rgba[((size_t)(g->y0 + yy) * side + g->x0 + xx) * 4 + 3] = bitmaps[i].pixels[(size_t)yy * w + xx];
    }
    if (count <= 512) {
        size_t capacity = (size_t)count * (size_t)count;
        kernings = capacity ? malloc(sizeof *kernings * capacity) : NULL;
        if (capacity && !kernings) goto done;
        for (int i = 0; i < count; i++) {
            FT_UInt left = FT_Get_Char_Index(face, (FT_ULong)(first + i));
            if (!left) continue;
            for (int j = 0; j < count; j++) {
                FT_UInt right = FT_Get_Char_Index(face, (FT_ULong)(first + j));
                FT_Vector delta;
                if (!right || FT_Get_Kerning(face, left, right, FT_KERNING_DEFAULT, &delta) != 0 || delta.x == 0) continue;
                kernings[kerning_count++] = (ui_kerning){ (unsigned int)(first + i), (unsigned int)(first + j),
                    (float)delta.x / 64.0f / (float)FONT_OVERSAMPLE };
            }
        }
        if (kerning_count) qsort(kernings, (size_t)kerning_count, sizeof *kernings, compare_kerning);
        else { free(kernings); kernings = NULL; }
    }
    font->first = first; font->count = count; font->pixel_height = pixel_height;
    font->ascent = asc; font->line_height = line_height > 0 ? line_height : asc;
    font->atlas_w = side; font->atlas_h = side; font->rgba = rgba;
    font->kernings = kernings; font->kerning_count = kerning_count;
    font->white = (ui_rect){ 0, 0, WHITE_COLS, WHITE_ROWS };
    rgba = NULL; kernings = NULL; ok = 1;
done:
    if (bitmaps) for (int i = 0; i < count; i++) free(bitmaps[i].pixels);
    free(bitmaps); free(rgba); free(kernings);
    if (face) FT_Done_Face(face);
    if (library) FT_Done_FreeType(library);
    if (!ok) { free(font->glyphs); memset(font, 0, sizeof *font); }
    return ok ? 0 : -1;
}

/* Nearest whole pixel, halves away from zero. */
static int round_px(float v) {
    return (int)(v < 0 ? v - 0.5f : v + 0.5f);
}

static int compare_kerning(const void *a, const void *b) {
    const ui_kerning *ka = (const ui_kerning *)a, *kb = (const ui_kerning *)b;
    if (ka->left != kb->left) return ka->left < kb->left ? -1 : 1;
    if (ka->right != kb->right) return ka->right < kb->right ? -1 : 1;
    return 0;
}

/* stb_truetype exposes GPOS pair lookup but not enumeration. For ordinary UI character sets,
 * enumerate the configured range so both classic kern and GPOS pairs are retained. */
static int build_kerning(const stbtt_fontinfo *info, float scale, int first, int count,
                         ui_kerning **out, int *out_count) {
    ui_kerning *pairs;
    int used = 0;
    *out = NULL;
    *out_count = 0;
    if (count <= 512) {
        size_t capacity = (size_t)count * (size_t)count;
        if (capacity == 0) return 1;
        pairs = malloc(sizeof *pairs * capacity);
        if (!pairs) return 0;
        for (int i = 0; i < count; i++) {
            int left = first + i;
            if (stbtt_FindGlyphIndex(info, left) == 0) continue;
            for (int j = 0; j < count; j++) {
                int right = first + j;
                int amount;
                if (stbtt_FindGlyphIndex(info, right) == 0) continue;
                amount = stbtt_GetCodepointKernAdvance(info, left, right);
                if (amount != 0) pairs[used++] = (ui_kerning){ (unsigned int)left, (unsigned int)right, (float)amount * scale };
            }
        }
    } else {
        /* For large ranges, enumerate the compact classic kern table instead of probing every
         * possible codepoint pair. stb_truetype's table enumerator covers the OpenType kern table. */
        int table_count = stbtt_GetKerningTableLength(info);
        int glyph_count = info->numGlyphs;
        stbtt_kerningentry *table;
        int *glyph_to_codepoint;
        if (table_count <= 0 || glyph_count <= 0) return 1;
        table = malloc(sizeof *table * (size_t)table_count);
        glyph_to_codepoint = malloc(sizeof *glyph_to_codepoint * (size_t)glyph_count);
        pairs = malloc(sizeof *pairs * (size_t)table_count);
        if (!table || !glyph_to_codepoint || !pairs) {
            free(table); free(glyph_to_codepoint); free(pairs);
            return 0;
        }
        for (int i = 0; i < glyph_count; i++) glyph_to_codepoint[i] = -1;
        for (int i = 0; i < count; i++) {
            int glyph = stbtt_FindGlyphIndex(info, first + i);
            if (glyph > 0 && glyph < glyph_count && glyph_to_codepoint[glyph] < 0)
                glyph_to_codepoint[glyph] = first + i;
        }
        table_count = stbtt_GetKerningTable(info, table, table_count);
        for (int i = 0; i < table_count; i++) {
            int left = table[i].glyph1, right = table[i].glyph2;
            if (left <= 0 || right <= 0 || left >= glyph_count || right >= glyph_count ||
                glyph_to_codepoint[left] < 0 || glyph_to_codepoint[right] < 0 || table[i].advance == 0) continue;
            pairs[used++] = (ui_kerning){ (unsigned int)glyph_to_codepoint[left],
                                          (unsigned int)glyph_to_codepoint[right],
                                          (float)table[i].advance * scale };
        }
        free(table);
        free(glyph_to_codepoint);
    }
    if (used == 0) { free(pairs); return 1; }
    qsort(pairs, (size_t)used, sizeof *pairs, compare_kerning);
    *out = pairs;
    *out_count = used;
    return 1;
}

int ui_font_bake(const unsigned char *ttf, size_t len, float pixel_height, int first, int count, ui_font *font) {
    stbtt_fontinfo info;
    stbtt_bakedchar *baked = NULL;
    unsigned char *alpha = NULL, *rgba = NULL;
    int asc, desc, gap, side, rows, i, kerning_count = 0;
    float scale;
    ui_kerning *kernings = NULL;

    if (font == NULL) return -1;
    memset(font, 0, sizeof *font);
    if (ttf == NULL) return -1;
    if (len < 12 || count <= 0 || pixel_height <= 0) return -1;
    if ((len >= 4 && memcmp(ttf, "OTTO", 4) == 0) || !stbtt_InitFont(&info, ttf, 0)) {
        if (ui_font_bake_freetype(ttf, len, pixel_height, first, count, font) != 0) return -1;
        font->fallback = ui_font_default_fallback(first, count);
        return 0;
    }
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
    if (!build_kerning(&info, scale, first, count, &kernings, &kerning_count)) goto fail;

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
    font->kernings = kernings;
    font->kerning_count = kerning_count;
    font->fallback = ui_font_default_fallback(first, count);
    free(alpha);
    free(baked);
    return 0;

fail:
    free(alpha);
    free(baked);
    free(rgba);
    free(font->glyphs);
    free(kernings);
    memset(font, 0, sizeof *font);
    return -1;
}
