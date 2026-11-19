/*
 * bfnt_fp_contract_repro.c: why the BFNT measurement parity test failed on FMA-capable hosts, and why
 * build.zig passes -ffp-contract=off to text.c.
 *
 * It replays src/engine/text/bfnt_measure.zig's test in C with the same fonts, kernings, corpus, scales, and loop
 * order, and compares ui_font_text_width_scaled (text.c) with an unfused port of the Zig arithmetic.
 *
 * Reproduce (from the repository root):
 *   gcc -std=c99 -O2 -mfma -ffp-contract=fast -c src/engine/text/text.c -Isrc/engine/text -Isrc/engine/ui -o text_fma.o
 *   gcc -std=c99 -O2 -mfma -ffp-contract=off  -c src/engine/text/text.c -Isrc/engine/text -Isrc/engine/ui -o text_off.o
 *   gcc -std=c99 -O2 -c checks/bfnt_fp_contract_repro.c -Isrc/engine/text -Isrc/engine/ui -o repro.o
 *   gcc -o repro_fma repro.o text_fma.o -lm && ./repro_fma   # fused: mismatches
 *   gcc -o repro_off repro.o text_off.o -lm && ./repro_off   # unfused: 0 mismatches
 *
 * Expected: fused text.c gives 3 mismatches in 456 comparisons, first at font 0, corpus 5, scale 1.5, where
 * text.c = 0x427DCCCD and the port = 0x427DCCCA (the owner's Windows run reported 1115540685 vs 1115540682).
 * Unfused text.c gives 0 mismatches.
 */
/* Replays bfnt_measure.zig's parity test: same glyphs, kernings, fonts, corpus, scales, loop order. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "text.h"

/* Unfused port of bfnt_measure.zig's width (one rounding per operation, as Zig computes it). */
static int u8_next(const char *t, size_t len, size_t *pos) {
    unsigned char lead = (unsigned char)t[*pos];
    int extra, cp, i;
    if (lead < 0x80) { *pos += 1; return lead; }
    if ((lead & 0xE0) == 0xC0) { extra = 1; cp = lead & 0x1F; }
    else if ((lead & 0xF0) == 0xE0) { extra = 2; cp = lead & 0x0F; }
    else if ((lead & 0xF8) == 0xF0) { extra = 3; cp = lead & 0x07; }
    else { *pos += 1; return 0xFFFD; }
    if (len - *pos <= (size_t)extra) { *pos += 1; return 0xFFFD; }
    for (i = 1; i <= extra; i++) {
        unsigned char nx = (unsigned char)t[*pos + i];
        if ((nx & 0xC0) != 0x80) { *pos += 1; return 0xFFFD; }
        cp = (cp << 6) | (nx & 0x3F);
    }
    *pos += (size_t)extra + 1;
    return cp;
}
static float kern_for(const ui_font *f, unsigned l, unsigned r) {
    int lo = 0, hi = f->kerning_count - 1;
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        const ui_kerning *k = &f->kernings[mid];
        if (k->left == l && k->right == r) return k->advance;
        if (k->left < l || (k->left == l && k->right < r)) lo = mid + 1; else hi = mid - 1;
    }
    return 0;
}
static float port_width(const ui_font *f, const char *t, size_t len, float scale) {
    float total = 0; size_t pos = 0; int prev = -1;
    if (!(scale > 0)) return 0;
    while (pos < len) {
        int cp = u8_next(t, len, &pos);
        int drawn = (cp >= f->first && cp < f->first + f->count) ? cp : f->fallback;
        int i;
        const ui_glyph *g;
        if (drawn < 0) continue;
        i = drawn - f->first;
        if (i < 0 || i >= f->count) continue;
        g = &f->glyphs[i];
        if (prev >= 0) total = total + kern_for(f, (unsigned)prev, (unsigned)drawn) * scale;
        total = total + g->xadvance * scale;
        prev = drawn;
    }
    return total;
}

int main(void) {
    static ui_glyph glyphs[95];
    static ui_kerning kernings[5] = {
        {32, 65, -0.5f}, {63, 63, 0.25f}, {65, 86, -1.5f}, {84, 111, -0.75f}, {86, 65, -1.25f}};
    ui_font fonts[4];
    static const char *corpus[] = {"", "A", "AV", "VA", "TAV", "Hello, world", "?", "\xc3\xa9", "\xff",
        "\xe2\x82", "\xed\xa0\x80", "\xc0\x80", "\xf7\xbf\xbf\xbf", "A\x80V", "\xe6\x97\xa5", "AAAA\xe2",
        "a\x00b", "\xf0\x9f\x98\x80", "VAVAV"};
    static const size_t corpus_len[] = {0, 1, 2, 2, 3, 12, 1, 2, 1, 2, 3, 2, 4, 3, 3, 5, 3, 4, 5};
    static const float scales[] = {1.0f, 0.5f, 2.0f, 0.0f, -1.0f, 1.5f};
    size_t i, c, s, n = 0;
    int mismatches = 0;
    for (i = 0; i < 95; i++) {
        memset(&glyphs[i], 0, sizeof glyphs[i]);
        glyphs[i].xadvance = 3.1f + (float)(i % 7) * 0.1f;   /* f32 arithmetic, as Zig does it */
    }
    memset(fonts, 0, sizeof fonts);
    fonts[0].first = 32; fonts[0].count = 95; fonts[0].fallback = '?';
    fonts[1].first = 65; fonts[1].count = 26; fonts[1].fallback = -1;
    fonts[2].first = 0;  fonts[2].count = 0;  fonts[2].fallback = -1;
    fonts[3].first = 0;  fonts[3].count = 0;  fonts[3].fallback = '?';
    for (i = 0; i < 4; i++) { fonts[i].glyphs = glyphs; fonts[i].kernings = kernings; fonts[i].kerning_count = 5; }

    for (i = 0; i < 4; i++) for (c = 0; c < sizeof corpus / sizeof corpus[0]; c++) for (s = 0; s < 6; s++) {
        float expected = ui_font_text_width_scaled(&fonts[i], corpus[c], corpus_len[c], scales[s]);
        float actual = port_width(&fonts[i], corpus[c], corpus_len[c], scales[s]);
        uint32_t eb, ab; memcpy(&eb, &expected, 4); memcpy(&ab, &actual, 4);
        n++;
        if (eb != ab) {
            if (mismatches == 0)
                printf("FIRST MISMATCH: font %zu corpus %zu scale %g: text.c=%u (0x%08X) port=%u (0x%08X)\n",
                       i, c, scales[s], eb, eb, ab, ab);
            mismatches++;
        }
    }
    printf("%zu comparisons, %d mismatches\n", n, mismatches);
    return 0;
}
