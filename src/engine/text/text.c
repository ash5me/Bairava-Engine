/*
 * text.c: bakes TrueType/OpenType fonts into glyph atlases and turns strings into quads.
 *
 * The atlas is RGBA8 with white glyphs. stb's coverage goes into alpha and RGB stays white, so
 * a quad's tint sets the text color. The top two rows hold a solid white block for filled
 * rectangles. Glyph pixels are written below the white block.
 */
#include "text.h"
#include "stb_truetype.h"

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MODULE_H

#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define ATLAS_MIN 128
#define ATLAS_MAX 4096
#define WHITE_ROWS 2
#define WHITE_COLS 2

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
    if (FT_Set_Char_Size(*face, 0, (FT_F26Dot6)(pixel_height * 64.0f + 0.5f), 72, 72) != 0) {
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

static int ft_render_codepoint(FT_Face face, int cp, int sdf, ft_bitmap_copy *out) {
    FT_Int32 flags = FT_LOAD_DEFAULT | FT_LOAD_NO_BITMAP;
    memset(out, 0, sizeof *out);
    if (sdf) flags |= FT_LOAD_NO_HINTING;
    if (FT_Load_Char(face, (FT_ULong)cp, flags) != 0) return 0;
    if (FT_Render_Glyph(face->glyph, sdf ? FT_RENDER_MODE_SDF : FT_RENDER_MODE_NORMAL) != 0) return 0;
    out->width = (int)face->glyph->bitmap.width;
    out->height = (int)face->glyph->bitmap.rows;
    out->left = face->glyph->bitmap_left;
    out->top = face->glyph->bitmap_top;
    out->advance = (float)face->glyph->advance.x / 64.0f;
    return ft_copy_bitmap(&face->glyph->bitmap, &out->pixels);
}

static int ui_font_bake_freetype(const unsigned char *data, size_t len, float pixel_height, int first, int count,
                                 int sdf, float distance_range, ui_font *font) {
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
        (sdf && !(distance_range >= 1.0f && distance_range <= 32.0f)) ||
        !ft_open_face(data, len, pixel_height, &library, &face)) return -1;
    if (sdf) {
        FT_Int spread = (FT_Int)(distance_range + 0.5f);
        (void)FT_Property_Set(library, "sdf", "spread", &spread);
    }
    asc = round_px((float)face->size->metrics.ascender / 64.0f);
    line_height = round_px((float)face->size->metrics.height / 64.0f);
    bitmaps = (ft_bitmap_copy *)calloc((size_t)count, sizeof *bitmaps);
    font->glyphs = (ui_glyph *)calloc((size_t)count, sizeof *font->glyphs);
    if (!bitmaps || !font->glyphs) goto done;
    for (int i = 0; i < count; i++) {
        if (!ft_render_codepoint(face, first + i, sdf, &bitmaps[i])) goto done;
        font->glyphs[i].xoff = (float)bitmaps[i].left;
        font->glyphs[i].yoff = (float)-bitmaps[i].top;
        font->glyphs[i].xadvance = bitmaps[i].advance;
    }
    for (side = ATLAS_MIN; side <= ATLAS_MAX; side *= 2) {
        x = WHITE_COLS + 1; y = 0; row_height = 0;
        int fits = 1;
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
                kernings[kerning_count++] = (ui_kerning){ (unsigned int)(first + i), (unsigned int)(first + j), (float)delta.x / 64.0f };
            }
        }
        if (kerning_count) qsort(kernings, (size_t)kerning_count, sizeof *kernings, compare_kerning);
        else { free(kernings); kernings = NULL; }
    }
    font->first = first; font->count = count; font->pixel_height = pixel_height;
    font->ascent = asc; font->line_height = line_height > 0 ? line_height : asc;
    font->atlas_w = side; font->atlas_h = side; font->rgba = rgba; font->sdf = sdf;
    font->sdf_range = sdf ? distance_range : 0;
    font->freetype_backend = 1;
    font->kernings = kernings; font->kerning_count = kerning_count;
    font->atlas_generation = 1;
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
    if (i >= 0 && i < font->count) return &font->glyphs[i];
    if (font->dynamic_glyphs) {
        for (int n = 0; n < font->extra_count; n++)
            if (font->extra_codepoints[n] == cp) return &font->extra_glyphs[n];
    }
    i = '?' - font->first;
    if (i < 0 || i >= font->count) return NULL;
    return &font->glyphs[i];
}

static int add_dynamic_glyph(ui_font *font, int cp) {
    stbtt_fontinfo info;
    unsigned char *bitmap = NULL;
    int w = 0, h = 0, xoff = 0, yoff = 0, advance = 0, lsb = 0;
    int x, y, row_height;
    int bitmap_freetype = 0;
    ui_glyph glyph = {0};
    if (!font->dynamic_glyphs || cp < 0 || cp > 0x10ffff) return 0;
    for (int n = 0; n < font->extra_count; n++) if (font->extra_codepoints[n] == cp) return 1;
    if (font->freetype_backend) {
        FT_Library library = NULL;
        FT_Face face = NULL;
        ft_bitmap_copy copy;
        if (!ft_open_face(font->source_font, font->source_font_len, font->pixel_height, &library, &face)) return 0;
        if (font->sdf) {
            FT_Int spread = (FT_Int)((font->sdf_range > 0 ? font->sdf_range : 8.0f) + 0.5f);
            (void)FT_Property_Set(library, "sdf", "spread", &spread);
        }
        if (FT_Get_Char_Index(face, (FT_ULong)cp) == 0 || !ft_render_codepoint(face, cp, font->sdf, &copy)) {
            FT_Done_Face(face); FT_Done_FreeType(library); return 0;
        }
        FT_Done_Face(face); FT_Done_FreeType(library);
        bitmap = copy.pixels; w = copy.width; h = copy.height;
        xoff = copy.left; yoff = -copy.top;
        glyph.xadvance = copy.advance;
        bitmap_freetype = 1;
    } else {
        if (!stbtt_InitFont(&info, font->source_font, 0) || stbtt_FindGlyphIndex(&info, cp) == 0) return 0;
        stbtt_GetCodepointHMetrics(&info, cp, &advance, &lsb);
        glyph.xadvance = (float)advance * stbtt_ScaleForPixelHeight(&info, font->pixel_height);
        if (font->sdf) {
            float range = font->sdf_range > 0 ? font->sdf_range : 8.0f;
            int padding = (int)(range + 0.999f);
            bitmap = stbtt_GetCodepointSDF(&info, stbtt_ScaleForPixelHeight(&info, font->pixel_height), cp,
                                           padding, 128, 127.0f / range, &w, &h, &xoff, &yoff);
        } else {
            bitmap = stbtt_GetCodepointBitmap(&info, stbtt_ScaleForPixelHeight(&info, font->pixel_height),
                                              stbtt_ScaleForPixelHeight(&info, font->pixel_height), cp,
                                              &w, &h, &xoff, &yoff);
        }
    }
    if (font->extra_count == font->extra_capacity) {
        int capacity = font->extra_capacity ? font->extra_capacity * 2 : 32;
        int *cps = realloc(font->extra_codepoints, sizeof *cps * (size_t)capacity);
        ui_glyph *gs;
        if (!cps) return -1;
        font->extra_codepoints = cps;
        gs = realloc(font->extra_glyphs, sizeof *gs * (size_t)capacity);
        if (!gs) return -1;
        font->extra_glyphs = gs;
        font->extra_capacity = capacity;
    }
    glyph.xoff = (float)xoff;
    glyph.yoff = (float)yoff;
    if (w > 0 && h > 0 && bitmap) {
        x = font->dynamic_x;
        y = font->dynamic_y;
        row_height = font->dynamic_row_height;
        if (x + w + 1 > font->atlas_w) { x = 0; y += row_height + 1; row_height = 0; }
        if (w + 1 > font->atlas_w) goto fail;
        if (y + h + 1 > font->atlas_h) {
            int new_height = font->atlas_h;
            unsigned char *grown;
            while (new_height < y + h + 1 && new_height < ATLAS_MAX) new_height *= 2;
            if (new_height > ATLAS_MAX) new_height = ATLAS_MAX;
            if (new_height < y + h + 1) goto fail;
            grown = malloc((size_t)font->atlas_w * new_height * 4);
            if (!grown) goto fail;
            for (size_t p = 0; p < (size_t)font->atlas_w * new_height; p++) {
                grown[p * 4 + 0] = 255; grown[p * 4 + 1] = 255; grown[p * 4 + 2] = 255; grown[p * 4 + 3] = 0;
            }
            memcpy(grown, font->rgba, (size_t)font->atlas_w * font->atlas_h * 4);
            free(font->rgba);
            font->rgba = grown;
            font->atlas_h = new_height;
        }
        glyph.x0 = (unsigned short)x; glyph.y0 = (unsigned short)y;
        glyph.x1 = (unsigned short)(x + w); glyph.y1 = (unsigned short)(y + h);
        for (int yy = 0; yy < h; yy++) for (int xx = 0; xx < w; xx++)
            font->rgba[((size_t)(y + yy) * font->atlas_w + x + xx) * 4 + 3] = bitmap[(size_t)yy * w + xx];
        if (bitmap_freetype) free(bitmap);
        else if (font->sdf) stbtt_FreeSDF(bitmap, info.userdata);
        else stbtt_FreeBitmap(bitmap, info.userdata);
        bitmap = NULL;
        font->dynamic_x = x + w + 1;
        font->dynamic_y = y;
        font->dynamic_row_height = h > row_height ? h : row_height;
        font->atlas_generation++;
    }
    font->extra_codepoints[font->extra_count] = cp;
    font->extra_glyphs[font->extra_count] = glyph;
    font->extra_count++;
    return 1;
fail:
    if (bitmap) {
        if (bitmap_freetype) free(bitmap);
        else if (font->sdf) stbtt_FreeSDF(bitmap, info.userdata);
        else stbtt_FreeBitmap(bitmap, info.userdata);
    }
    return 0;
}

int ui_font_enable_dynamic(ui_font *font, const unsigned char *font_data, size_t len) {
    unsigned char *copy;
    stbtt_fontinfo info;
    int use_freetype = 0;
    if (!font || !font_data || len < 12) return -1;
    if ((len >= 4 && memcmp(font_data, "OTTO", 4) == 0) || !stbtt_InitFont(&info, font_data, 0)) {
        FT_Library library = NULL;
        FT_Face face = NULL;
        if (!ft_open_face(font_data, len, font->pixel_height, &library, &face)) return -1;
        FT_Done_Face(face); FT_Done_FreeType(library);
        use_freetype = 1;
    }
    copy = malloc(len);
    if (!copy) return -1;
    memcpy(copy, font_data, len);
    free(font->source_font);
    font->source_font = copy;
    font->source_font_len = len;
    font->dynamic_glyphs = 1;
    font->freetype_backend = use_freetype;
    font->dynamic_x = 0;
    font->dynamic_y = font->atlas_h;
    font->dynamic_row_height = 0;
    return 0;
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

static float kerning_for(const ui_font *font, unsigned int left, unsigned int right) {
    if (font->dynamic_glyphs && font->source_font &&
        (left < (unsigned int)font->first || left >= (unsigned int)(font->first + font->count) ||
         right < (unsigned int)font->first || right >= (unsigned int)(font->first + font->count))) {
        stbtt_fontinfo info;
        if (stbtt_InitFont(&info, font->source_font, 0))
            return (float)stbtt_GetCodepointKernAdvance(&info, (int)left, (int)right) * stbtt_ScaleForPixelHeight(&info, font->pixel_height);
    }
    int lo = 0, hi = font->kerning_count - 1;
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        const ui_kerning *k = &font->kernings[mid];
        if (k->left == left && k->right == right) return k->advance;
        if (k->left < left || (k->left == left && k->right < right)) lo = mid + 1;
        else hi = mid - 1;
    }
    if (font->dynamic_glyphs && font->freetype_backend && font->source_font &&
        (font->kerning_count == 0 || left < (unsigned int)font->first || left >= (unsigned int)(font->first + font->count) ||
         right < (unsigned int)font->first || right >= (unsigned int)(font->first + font->count))) {
        FT_Library library = NULL;
        FT_Face face = NULL;
        FT_Vector delta;
        float amount = 0;
        if (ft_open_face(font->source_font, font->source_font_len, font->pixel_height, &library, &face)) {
            FT_UInt left_glyph = FT_Get_Char_Index(face, (FT_ULong)left);
            FT_UInt right_glyph = FT_Get_Char_Index(face, (FT_ULong)right);
            if (left_glyph && right_glyph && FT_Get_Kerning(face, left_glyph, right_glyph, FT_KERNING_DEFAULT, &delta) == 0)
                amount = (float)delta.x / 64.0f;
            FT_Done_Face(face); FT_Done_FreeType(library);
        }
        return amount;
    }
    return 0;
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
    if ((len >= 4 && memcmp(ttf, "OTTO", 4) == 0) || !stbtt_InitFont(&info, ttf, 0))
        return ui_font_bake_freetype(ttf, len, pixel_height, first, count, 0, 0, font);
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
    font->atlas_generation = 1;
    font->rgba = rgba;
    font->white = (ui_rect){ 0, 0, WHITE_COLS, WHITE_ROWS };
    font->kernings = kernings;
    font->kerning_count = kerning_count;
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

typedef struct sdf_glyph {
    unsigned char *pixels;
    int width, height, xoff, yoff;
} sdf_glyph;

int ui_font_bake_sdf(const unsigned char *ttf, size_t len, float pixel_height, int first, int count,
                     float distance_range, ui_font *font) {
    return ui_font_bake_freetype(ttf, len, pixel_height, first, count, 1, distance_range, font);
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
    int first, count, atlas_w, atlas_h, version, kerning_count = 0;
    float pixel_height;
    size_t pixels, glyph_offset, pixel_offset, expected_len;
    unsigned char *rgba = NULL;
    ui_glyph *glyphs = NULL;
    ui_kerning *kernings = NULL;
    if (font == NULL) return -1;
    memset(font, 0, sizeof *font);
    if (data == NULL) return -1;
    if (len < 48 || memcmp(data, "BFNT", 4) != 0) return -1;
    version = read_u16le(data + 4);
    if ((version < 1 || version > 3) ||
        read_u16le(data + 6) != (version == 1 ? 48 : (version == 2 ? 52 : 56)) ||
        len < (version == 1 ? 48u : (version == 2 ? 52u : 56u))) return -1;
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
    glyph_offset = version == 1 ? 48 : (version == 2 ? 52 : 56);
    if (version >= 2) {
        uint32_t raw_count = read_u32le(data + 48);
        if (raw_count > 1u << 20) return -1;
        kerning_count = (int)raw_count;
    }
    if (version == 3 && (read_u32le(data + 52) & ~1u) != 0) return -1;
    if ((size_t)count > (SIZE_MAX - glyph_offset) / 20) return -1;
    pixel_offset = glyph_offset + (size_t)count * 20;
    if ((size_t)kerning_count > (SIZE_MAX - pixel_offset) / 12) return -1;
    pixel_offset += (size_t)kerning_count * 12;
    if (pixels > SIZE_MAX - pixel_offset) return -1;
    expected_len = pixel_offset + pixels;
    if (len != expected_len) return -1;

    glyphs = (ui_glyph *)calloc((size_t)count, sizeof *glyphs);
    rgba = (unsigned char *)malloc(pixels * 4);
    kernings = kerning_count > 0 ? (ui_kerning *)calloc((size_t)kerning_count, sizeof *kernings) : NULL;
    if (glyphs == NULL || rgba == NULL || (kerning_count > 0 && kernings == NULL)) goto fail;
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
    font->kernings = kernings;
    font->kerning_count = kerning_count;
    font->sdf = version == 3 && (read_u32le(data + 52) & 1u) != 0;
    font->white = (ui_rect){ read_u16le(data + 40), read_u16le(data + 42), read_u16le(data + 44), read_u16le(data + 46) };
    if (font->white.x < 0 || font->white.y < 0 || font->white.w <= 0 || font->white.h <= 0 ||
        font->white.x + font->white.w > atlas_w || font->white.y + font->white.h > atlas_h || font->line_height <= 0) goto fail_font;
    return 0;

fail_font:
    memset(font, 0, sizeof *font);
fail:
    free(rgba);
    free(glyphs);
    free(kernings);
    return -1;
}

void ui_font_destroy(ui_font *font) {
    free(font->rgba);
    free(font->glyphs);
    free(font->kernings);
    free(font->source_font);
    free(font->extra_codepoints);
    free(font->extra_glyphs);
    memset(font, 0, sizeof *font);
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
        int cp = utf8_next(text, len, &pos);
        int resolved = cp;
        if (font->dynamic_glyphs && (cp < font->first || cp >= font->first + font->count))
            (void)add_dynamic_glyph(font, cp);
        const ui_glyph *g = glyph_for(font, cp);
        if (resolved < font->first || resolved >= font->first + font->count) resolved = '?';
        if (g) {
            if (previous >= 0) width += kerning_for(font, (unsigned int)previous, (unsigned int)resolved) * scale;
            width += g->xadvance * scale;
            previous = resolved;
        }
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
        int cp = utf8_next(text, len, &pos);
        int resolved = cp;
        if (font->dynamic_glyphs && (cp < font->first || cp >= font->first + font->count))
            (void)add_dynamic_glyph(font, cp);
        const ui_glyph *g = glyph_for(font, cp);
        if (!g) continue;
        if (resolved < font->first || resolved >= font->first + font->count) resolved = '?';
        if (previous >= 0) pen += kerning_for(font, (unsigned int)previous, (unsigned int)resolved) * scale;
        int w = g->x1 - g->x0;
        int h = g->y1 - g->y0;
        /* Blank glyphs such as the space have no pixels, but they still move the pen. */
        if (w > 0 && h > 0) {
            ui_rect dst = { (float)round_px(pen + g->xoff * scale), (float)(baseline + round_px(g->yoff * scale)), w * scale, h * scale };
            ui_rect src = { (float)g->x0, (float)g->y0, (float)w, (float)h };
            ui_quad_push(out, dst, src, color);
            out->items[out->count - 1].sdf = font->sdf;
        }
        pen += g->xadvance * scale;
        previous = resolved;
    }
}
