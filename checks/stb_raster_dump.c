#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

static unsigned char *slurp(const char *p, long *n) {
    FILE *f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc(*n); if (fread(b, 1, *n, f) != (size_t)*n) { fprintf(stderr, "short read\n"); } fclose(f); return b;
}
static unsigned long long fnv(const unsigned char *b, size_t n) {
    unsigned long long h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ULL; }
    return h;
}
int main(int argc, char **argv) {
    long n; unsigned char *data = slurp(argv[1], &n);
    if (!data) { fprintf(stderr, "cannot read %s\n", argv[1]); return 1; }
    stbtt_fontinfo info;
    if (!stbtt_InitFont(&info, data, stbtt_GetFontOffsetForIndex(data, 0))) { printf("INIT_FAIL\n"); return 0; }
    static const float heights[] = {4,5,6,7,8,9,10,11,12,13,14,15,16,18,20,22,24,26,28,30,32,36,40,44,48,56,64};
    static const int ranges[][2] = {{0, 0x2FFF}, {0x0B80, 0x0BFF}};
    for (size_t h = 0; h < sizeof heights / sizeof heights[0]; h++) {
        float scale = stbtt_ScaleForPixelHeight(&info, heights[h]);
        for (size_t r = 0; r < 2; r++)
            for (int cp = ranges[r][0]; cp <= ranges[r][1]; cp++) {
                int w, hgt, xo, yo;
                unsigned char *bm = stbtt_GetCodepointBitmap(&info, scale, scale, cp, &w, &hgt, &xo, &yo);
                if (!bm) { printf("px%g U+%04X empty\n", heights[h], cp); continue; }
                printf("px%g U+%04X %dx%d off=%d,%d hash=%016llx\n", heights[h], cp, w, hgt, xo, yo,
                       fnv(bm, (size_t)w * hgt));
                stbtt_FreeBitmap(bm, NULL);
            }
    }
    return 0;
}
