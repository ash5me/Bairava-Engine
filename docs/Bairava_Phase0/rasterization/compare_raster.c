/*
 * Renders the shipped UI font (VT323, 9 px) three ways and prints the coverage, so the rasterization
 * choice in the migration plan can be judged from measurements instead of from the docs.
 *
 *   stb   : stb_truetype, unhinted box-filter coverage. This is the plan's Phase 2 rasterizer.
 *   ft_mono : FreeType, 1-bit, hinted. This is what the baker writes for the shipped mono rows.
 *   ft_gray : FreeType, anti-aliased, hinted. Shown for comparison only.
 *
 * FreeType and stb use the same pixel height the baker uses: FreeType via FT_Set_Char_Size at 72 dpi,
 * stb via stbtt_ScaleForPixelHeight. stb comes from the PoC's third_party/stb_truetype.h (v1.28);
 * Bairava vendors 1.26 (see dependency-lock.json). The rasterizer core is the same for this comparison.
 *
 * Build:
 *   gcc -std=c11 -O1 -I/usr/include/freetype2 -I<PoC>/third_party compare_raster.c -lfreetype -lm -o compare_raster
 * Run: ./compare_raster <bairava>/assets/font.ttf
 */
#include <ft2build.h>
#include FT_FREETYPE_H

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PIXEL_HEIGHT 9

static unsigned char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    unsigned char *data;
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    *len = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    data = malloc(*len);
    if (fread(data, 1, *len, f) != *len) { fclose(f); free(data); return NULL; }
    fclose(f);
    return data;
}

/* Prints a coverage bitmap. Gray uses a ramp of characters; mono uses '#' for ink. */
static void print_gray(const unsigned char *px, int w, int h) {
    static const char ramp[] = " .:-=+*#%@";
    for (int y = 0; y < h; y++) {
        printf("      |");
        for (int x = 0; x < w; x++) {
            int v = px[y * w + x];
            putchar(ramp[v * 9 / 255]);
        }
        printf("|\n");
    }
}

/* Per-column ink sum for the ink rows, to show how one stem spreads over columns. */
static void column_profile(const unsigned char *px, int w, int h, const char *label) {
    printf("      %s columns:", label);
    for (int x = 0; x < w; x++) {
        int sum = 0;
        for (int y = 0; y < h; y++) sum += px[y * w + x];
        printf(" %3d", sum / 255 > 0 ? (int)(100.0 * sum / (255.0 * h) + 0.5) : 0);
    }
    printf("   (percent of column height)\n");
}

static void stb_render(const unsigned char *ttf, unsigned int codepoint) {
    stbtt_fontinfo info;
    int w, h, xoff, yoff;
    float scale;
    unsigned char *bmp;
    if (!stbtt_InitFont(&info, ttf, 0)) { printf("stb: InitFont failed\n"); return; }
    scale = stbtt_ScaleForPixelHeight(&info, PIXEL_HEIGHT);
    bmp = stbtt_GetCodepointBitmap(&info, scale, scale, (int)codepoint, &w, &h, &xoff, &yoff);
    printf("  stb gray  '%c'  %dx%d px\n", (char)codepoint, w, h);
    if (bmp) {
        print_gray(bmp, w, h);
        column_profile(bmp, w, h, "stb    ");
        stbtt_FreeBitmap(bmp, NULL);
    }
}

static void ft_render(FT_Face face, unsigned int codepoint, FT_Int32 load_flags, FT_Render_Mode mode, const char *label) {
    FT_GlyphSlot slot = face->glyph;
    int w, h, pitch, mono;
    const unsigned char *buf;
    unsigned char *px;
    if (FT_Load_Char(face, codepoint, load_flags) != 0 || FT_Render_Glyph(slot, mode) != 0) {
        printf("  %s: load failed\n", label);
        return;
    }
    w = (int)slot->bitmap.width;
    h = (int)slot->bitmap.rows;
    pitch = slot->bitmap.pitch;
    buf = slot->bitmap.buffer;
    mono = slot->bitmap.pixel_mode == FT_PIXEL_MODE_MONO;
    printf("  %s  '%c'  %dx%d px\n", label, (char)codepoint, w, h);
    px = calloc((size_t)(w * h > 0 ? w * h : 1), 1);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            if (mono) {
                int bit = (buf[y * pitch + x / 8] >> (7 - (x % 8))) & 1;
                px[y * w + x] = bit ? 255 : 0;
            } else {
                px[y * w + x] = buf[y * pitch + x];
            }
        }
    }
    print_gray(px, w, h);
    column_profile(px, w, h, mono ? "mono   " : "ft gray");
    free(px);
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "font.ttf";
    size_t len = 0;
    unsigned char *ttf = read_file(path, &len);
    FT_Library lib;
    FT_Face face;
    const unsigned int glyphs[] = { 'l', 'i', 'H' };
    if (!ttf) { fprintf(stderr, "cannot read %s\n", path); return 1; }

    printf("Font: %s (%zu bytes), %d px\n\n", path, len, PIXEL_HEIGHT);

    printf("== stb_truetype (plan Phase 2 rasterizer, unhinted)\n");
    for (size_t i = 0; i < sizeof glyphs / sizeof glyphs[0]; i++) stb_render(ttf, glyphs[i]);

    if (FT_Init_FreeType(&lib) != 0 || FT_New_Memory_Face(lib, ttf, (FT_Long)len, 0, &face) != 0) {
        fprintf(stderr, "FreeType init failed\n");
        return 1;
    }
    /* Same call the baker makes: a char size in 1/64 pt at 72 dpi, so pt == px. */
    FT_Set_Char_Size(face, 0, (FT_F26Dot6)(PIXEL_HEIGHT * 64), 72, 72);

    printf("\n== FreeType mono, hinted (what the shipped UI rows use)\n");
    for (size_t i = 0; i < sizeof glyphs / sizeof glyphs[0]; i++)
        ft_render(face, glyphs[i], FT_LOAD_TARGET_MONO | FT_LOAD_NO_BITMAP, FT_RENDER_MODE_MONO, "ft_mono");

    printf("\n== FreeType gray, hinted (comparison only)\n");
    for (size_t i = 0; i < sizeof glyphs / sizeof glyphs[0]; i++)
        ft_render(face, glyphs[i], FT_LOAD_DEFAULT | FT_LOAD_NO_BITMAP, FT_RENDER_MODE_NORMAL, "ft_gray");

    FT_Done_Face(face);
    FT_Done_FreeType(lib);
    free(ttf);
    return 0;
}
