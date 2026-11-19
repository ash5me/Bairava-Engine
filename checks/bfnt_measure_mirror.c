/* bfnt_measure_mirror.c: checks the planned Zig port of BFNT text measurement (src/engine/text/bfnt_measure.zig)
 * against the C reference, ui_font_text_width_scaled in src/engine/text/text.c.
 *
 * The port below follows the Zig file line for line. It is compared bit for bit with the C reference on synthetic
 * fonts, on a fixed corpus of valid and malformed UTF-8, and on 40000 seeded random byte strings.
 *
 * Build and run from the repository root:
 *   gcc -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
 *       -Isrc/engine/text -Isrc/engine/ui checks/bfnt_measure_mirror.c src/engine/text/text.c -lm -o bfnt_measure_mirror
 *   ./bfnt_measure_mirror
 * Exit status 0 means every comparison matched.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "text.h"

/* ---- the port (mirrors bfnt_measure.zig) ------------------------------------------------------------------------ */

static int32_t next_codepoint(const unsigned char *text, size_t len, size_t *pos) {
    unsigned char lead = text[*pos];
    size_t extra;
    uint32_t cp;
    size_t i;
    if (lead < 0x80) {
        *pos += 1;
        return (int32_t)lead;
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
    if (len - *pos <= extra) {
        *pos += 1;
        return 0xFFFD;
    }
    for (i = 1; i <= extra; i++) {
        unsigned char next = text[*pos + i];
        if ((next & 0xC0) != 0x80) {
            *pos += 1;
            return 0xFFFD;
        }
        cp = (cp << 6) | (next & 0x3F);
    }
    *pos += extra + 1;
    return (int32_t)cp;
}

static int32_t drawn_port(const ui_font *font, int32_t cp) {
    if (cp >= font->first && cp < font->first + font->count) return cp;
    return font->fallback;
}

static const ui_glyph *glyph_port(const ui_font *font, int32_t drawn) {
    int64_t i;
    if (drawn < 0) return NULL;
    i = (int64_t)drawn - (int64_t)font->first;
    return (i >= 0 && i < (int64_t)font->count) ? &font->glyphs[i] : NULL;
}

static float kerning_port(const ui_font *font, uint32_t left, uint32_t right) {
    int64_t lo = 0;
    int64_t hi = (int64_t)font->kerning_count - 1;
    while (lo <= hi) {
        int64_t mid = lo + (hi - lo) / 2;
        const ui_kerning *k = &font->kernings[mid];
        if (k->left == left && k->right == right) return k->advance;
        if (k->left < left || (k->left == left && k->right < right)) lo = mid + 1;
        else hi = mid - 1;
    }
    return 0;
}

static float width_port(const ui_font *font, const char *text, size_t len, float scale) {
    float total = 0;
    size_t pos = 0;
    int32_t previous = -1;
    if (!(scale > 0)) return 0;
    while (pos < len) {
        int32_t drawn = drawn_port(font, next_codepoint((const unsigned char *)text, len, &pos));
        const ui_glyph *g = glyph_port(font, drawn);
        if (!g) continue;
        if (previous >= 0) total += kerning_port(font, (uint32_t)previous, (uint32_t)drawn) * scale;
        total += g->xadvance * scale;
        previous = drawn;
    }
    return total;
}

/* ---- fixtures ---------------------------------------------------------------------------------------------------- */

static ui_glyph glyphs[95];

/* Sorted by (left, right), as the loader requires for the binary search. */
static ui_kerning kernings[] = {
    {32u, 65u, -0.5f},
    {63u, 63u, 0.25f},
    {65u, 86u, -1.5f},
    {84u, 111u, -0.75f},
    {86u, 65u, -1.25f},
};

static void make_font(ui_font *f, int first, int count, int fallback) {
    memset(f, 0, sizeof *f);
    f->first = first;
    f->count = count;
    f->fallback = fallback;
    f->pixel_height = 9.0f;
    f->glyphs = glyphs;
    f->kernings = kernings;
    f->kerning_count = (int)(sizeof kernings / sizeof kernings[0]);
}

typedef struct {
    const char *bytes;
    size_t len;
} sample;

static const sample corpus[] = {
    {"", 0},
    {"A", 1},
    {"AV", 2},
    {"VA", 2},
    {"TAV", 3},
    {"Hello, world", 12},
    {"?", 1},
    {"\xc3\xa9", 2},
    {"\xff", 1},
    {"\xe2\x82", 2},
    {"\xed\xa0\x80", 3},
    {"\xc0\x80", 2},
    {"\xf7\xbf\xbf\xbf", 4},
    {"A\x80V", 3},
    {"\xe6\x97\xa5", 3},
    {"AAAA\xe2", 5},
    {"a\0b", 3},
    {"\xf0\x9f\x98\x80", 4},
    {"VAVAV", 5},
    {"\x41\x56\x41", 3},
};

static const float scales[] = {1.0f, 0.5f, 2.0f, 0.0f, -1.0f, 1.5f};

static uint32_t rng_state = 0x5EEDu;

static uint32_t next_random(void) {
    rng_state = rng_state * 1664525u + 1013904223u;
    return rng_state >> 8;
}

/* ---- comparison -------------------------------------------------------------------------------------------------- */

static size_t comparisons = 0;
static size_t mismatches = 0;

static void compare(ui_font *font, const char *text, size_t len, float scale) {
    float reference = ui_font_text_width_scaled(font, text, len, scale);
    float port = width_port(font, text, len, scale);
    comparisons++;
    if (memcmp(&reference, &port, sizeof reference) != 0) {
        mismatches++;
        if (mismatches <= 5) {
            printf("MISMATCH len=%zu scale=%a reference=%a port=%a\n", len, scale, reference, port);
        }
    }
}

int main(void) {
    ui_font font_a, font_b, font_c, font_d;
    size_t i, s, r;
    size_t fuzz_count = 40000;
    size_t n_scales = sizeof scales / sizeof scales[0];
    size_t n_corpus = sizeof corpus / sizeof corpus[0];

    for (i = 0; i < sizeof glyphs / sizeof glyphs[0]; i++) {
        glyphs[i].xadvance = 3.1f + (float)(i % 7) * 0.1f;
    }

    /* A: the usual range with '?' as fallback. B: a narrow range with no fallback. C: a range that is empty, with no
     * fallback. D: an empty range whose fallback is '?', which is still not drawn. */
    make_font(&font_a, 32, 95, 63);
    make_font(&font_b, 65, 26, -1);
    make_font(&font_c, 0, 0, -1);
    make_font(&font_d, 0, 0, 63);

    ui_font *fonts[] = {&font_a, &font_b, &font_c, &font_d};
    for (i = 0; i < sizeof fonts / sizeof fonts[0]; i++) {
        for (s = 0; s < n_corpus; s++) {
            for (r = 0; r < n_scales; r++) compare(fonts[i], corpus[s].bytes, corpus[s].len, scales[r]);
        }
    }

    for (i = 0; i < fuzz_count; i++) {
        char buffer[16];
        size_t len = next_random() % 11;
        size_t k;
        for (k = 0; k < len; k++) buffer[k] = (char)(next_random() & 0xFF);
        for (r = 0; r < n_scales; r++) {
            size_t f;
            for (f = 0; f < sizeof fonts / sizeof fonts[0]; f++) compare(fonts[f], buffer, len, scales[r]);
        }
    }

    /* A few values for the record. */
    printf("example  \"AV\" in A at 1.0: %a\n", width_port(&font_a, "AV", 2, 1.0f));
    printf("example  \"VAVAV\" in A at 2.0: %a\n", width_port(&font_a, "VAVAV", 5, 2.0f));
    printf("example  \"\\xe6\\x97\\xa5\" (unbaked) in B at 1.0: %a\n", width_port(&font_b, "\xe6\x97\xa5", 3, 1.0f));
    printf("bfnt measure mirror: %zu comparisons, %zu mismatches\n", comparisons, mismatches);
    return mismatches == 0 ? 0 : 1;
}
