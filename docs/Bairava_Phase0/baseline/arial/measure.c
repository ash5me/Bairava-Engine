/* Measures the current prebaked path (text.c) for the shipped UI fonts.
 * Usage: measure <font.bfnt> <expected_pixel_height> <strings-file>
 * Prints: UI string widths, per-glyph xadvance for printable ASCII, and kerning pairs. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "text.h"

static unsigned char *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc((size_t)n); if (!b || fread(b, 1, (size_t)n, f) != (size_t)n) { fclose(f); return NULL; }
    fclose(f); *len = (size_t)n; return b;
}

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: measure <font.bfnt> <px> <strings>\n"); return 2; }
    size_t len; unsigned char *data = slurp(argv[1], &len);
    if (!data) { fprintf(stderr, "cannot read %s\n", argv[1]); return 1; }
    ui_font font; memset(&font, 0, sizeof font);
    if (ui_font_load_prebaked(data, len, (float)atof(argv[2]), &font) != 0) { fprintf(stderr, "load failed\n"); return 1; }
    printf("FONT %s px=%s baked_px=%.1f first=%d count=%d kerning_pairs=%d\n", argv[1], argv[2], font.pixel_height, font.first, font.count, font.kerning_count);
    FILE *s = fopen(argv[3], "r"); char line[256];
    while (s && fgets(line, sizeof line, s)) {
        size_t n = strlen(line); if (n && line[n-1] == '\n') line[--n] = 0;
        printf("WIDTH\t%s\t%.4f\n", line, ui_font_text_width(&font, line, n));
    }
    for (int c = 32; c < 127; c++) {
        if (c < font.first || c >= font.first + font.count) continue;
        printf("ADV\t%d\t%.4f\n", c, font.glyphs[c - font.first].xadvance);
    }
    for (int i = 0; i < font.kerning_count; i++) {
        unsigned l = font.kernings[i].left, r = font.kernings[i].right;
        if (l >= 32 && l < 127 && r >= 32 && r < 127) printf("KERN\t%u\t%u\t%.4f\n", l, r, font.kernings[i].advance);
    }
    ui_font_destroy(&font); free(data); if (s) fclose(s);
    return 0;
}
