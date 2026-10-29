/*
 * test_text.c: checks baked and preprocessed font data, plus the glyph quads text produces.
 *
 * Build and run from the project root, after fetching stb_truetype.h into vendor/:
 *   gcc -std=c99 -Wall -Wextra -fsanitize=address,undefined -Ivendor -Isrc/engine/ui \
 *       tests/ui/test_text.c src/engine/ui/text.c vendor/stb_truetype_impl.c -lm -o test_text
 *   ./test_text path/to/font.ttf
 */
#include "text.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                      \
        }                                                                    \
    } while (0)

static ui_font font;
static ui_quad_list list; /* static, because the quad list is large */

static int near(float a, float b) {
    float d = a - b;
    return d > -0.01f && d < 0.01f;
}

static const ui_glyph *glyph(int cp) {
    return &font.glyphs[cp - font.first];
}

static unsigned char alpha_at(int x, int y) {
    return font.rgba[((size_t)y * font.atlas_w + x) * 4 + 3];
}

static void check_atlas(void) {
    int w = font.atlas_w, i;

    CHECK(w >= 128 && (w & (w - 1)) == 0); /* power of two, at least the minimum */
    CHECK(font.atlas_h == w);
    CHECK(font.line_height > 0 && font.ascent > 0 && font.ascent <= font.line_height);
    CHECK(font.white.w == 2 && font.white.h == 2);

    /* The white block is opaque, and the rest of the top two rows is empty. */
    for (int y = 0; y < 2; y++) {
        for (int x = 0; x < w; x++) {
            int expect = x < 2 ? 255 : 0;
            CHECK(alpha_at(x, y) == expect);
            CHECK(font.rgba[((size_t)y * w + x) * 4 + 0] == 255);
        }
    }

    /* Every glyph sits below the reserved rows and inside the atlas, and it has coverage where its rectangle says. */
    for (i = 0; i < font.count; i++) {
        const ui_glyph *g = &font.glyphs[i];
        int gw = g->x1 - g->x0, gh = g->y1 - g->y0, sum = 0, x, y;
        if (gw <= 0 || gh <= 0) continue;
        CHECK(g->y0 >= 2);
        CHECK(g->x1 <= w && g->y1 <= w);
        for (y = g->y0; y < g->y1; y++)
            for (x = g->x0; x < g->x1; x++) sum += alpha_at(x, y);
        CHECK(sum > 0);
    }
}

static void check_width(void) {
    CHECK(ui_font_text_width(&font, "", 0) == 0);
    CHECK(near(ui_font_text_width(&font, "ab", 2), glyph('a')->xadvance + glyph('b')->xadvance));
    /* "é" is U+00E9, two bytes of UTF-8, and it is baked in the Latin-1 range. */
    CHECK(near(ui_font_text_width(&font, "\xC3\xA9", 2), glyph(0xE9)->xadvance));
    /* "一" is U+4E00, outside the baked range, so it measures as '?'. */
    CHECK(near(ui_font_text_width(&font, "\xE4\xB8\x80", 3), glyph('?')->xadvance));
    /* A lone continuation byte is malformed, so it becomes U+FFFD, which also falls back to '?'. */
    CHECK(near(ui_font_text_width(&font, "\x80", 1), glyph('?')->xadvance));
}

static void check_draw(void) {
    ui_color red = { 1, 0, 0, 0.5f };
    const ui_glyph *a = glyph('a');
    const ui_quad *q;

    list.count = 0;
    list.dropped = 0;
    ui_font_draw_text(&font, &list, 10, 20, "ab", 2, red);
    CHECK(list.count == 2);
    if (list.count == 2) {
        q = &list.items[0];
        CHECK(q->src.x == a->x0 && q->src.y == a->y0);          /* the source is the glyph's texel rectangle */
        CHECK(q->dst.w == q->src.w && q->dst.h == q->src.h);     /* drawn at one pixel per texel */
        CHECK(q->color.r == 1 && q->color.a == 0.5f);             /* the color passes through unchanged */
        CHECK(list.items[1].dst.x > q->dst.x);                    /* the pen moves right */
    }

    /* "é" must draw its own glyph, not the '?' fallback. The source rectangle identifies the glyph,
     * and it differs from '?' even when two glyphs happen to share an advance width. */
    list.count = 0;
    ui_font_draw_text(&font, &list, 0, 0, "\xC3\xA9", 2, red);
    CHECK(list.count == 1);
    if (list.count == 1) {
        CHECK(list.items[0].src.x == glyph(0xE9)->x0 && list.items[0].src.y == glyph(0xE9)->y0);
    }

    /* A space has no pixels, so it adds no quad but still moves the pen. */
    list.count = 0;
    ui_font_draw_text(&font, &list, 0, 0, "a b", 3, red);
    CHECK(list.count == 2);

    list.count = 0;
    ui_font_draw_text(&font, &list, 0, 0, "", 0, red);
    CHECK(list.count == 0);
}

static unsigned char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    unsigned char *data = NULL;
    long size = 0;
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) == 0) size = ftell(f);
    if (size > 0 && fseek(f, 0, SEEK_SET) == 0) {
        data = malloc((size_t)size);
        if (data && fread(data, 1, (size_t)size, f) == (size_t)size) {
            *len = (size_t)size;
        } else {
            free(data);
            data = NULL;
        }
    }
    fclose(f);
    return data;
}

static void put_u16le(unsigned char *p, unsigned short value) {
    p[0] = (unsigned char)value;
    p[1] = (unsigned char)(value >> 8);
}

static void put_u32le(unsigned char *p, unsigned int value) {
    p[0] = (unsigned char)value;
    p[1] = (unsigned char)(value >> 8);
    p[2] = (unsigned char)(value >> 16);
    p[3] = (unsigned char)(value >> 24);
}

static void expect_prebaked_rejected(const unsigned char *data, size_t len, float height) {
    ui_font rejected;
    memset(&rejected, 0xA5, sizeof rejected);
    CHECK(ui_font_load_prebaked(data, len, height, &rejected) != 0);
    CHECK(rejected.rgba == NULL && rejected.glyphs == NULL);
    CHECK(rejected.count == 0 && rejected.atlas_w == 0);
}

static void check_prebaked_roundtrip(void) {
    size_t pixels = (size_t)font.atlas_w * font.atlas_h;
    size_t len = 48 + (size_t)font.count * 20 + pixels;
    size_t pixel_offset = 48 + (size_t)font.count * 20;
    unsigned char *data = calloc(len, 1);
    ui_font loaded;
    unsigned int bits;
    CHECK(data != NULL);
    if (data == NULL) return;

    memcpy(data, "BFNT", 4);
    put_u16le(data + 4, 1);
    put_u16le(data + 6, 48);
    memcpy(&bits, &font.pixel_height, sizeof bits); put_u32le(data + 8, bits);
    put_u32le(data + 12, (unsigned int)font.first);
    put_u32le(data + 16, (unsigned int)font.count);
    put_u32le(data + 20, (unsigned int)font.ascent);
    put_u32le(data + 24, (unsigned int)font.line_height);
    put_u32le(data + 28, (unsigned int)font.atlas_w);
    put_u32le(data + 32, (unsigned int)font.atlas_h);
    put_u32le(data + 36, (unsigned int)pixels);
    put_u16le(data + 40, (unsigned short)font.white.x);
    put_u16le(data + 42, (unsigned short)font.white.y);
    put_u16le(data + 44, (unsigned short)font.white.w);
    put_u16le(data + 46, (unsigned short)font.white.h);
    for (int i = 0; i < font.count; i++) {
        unsigned char *dst = data + 48 + (size_t)i * 20;
        const ui_glyph *g = &font.glyphs[i];
        put_u16le(dst, g->x0);
        put_u16le(dst + 2, g->y0); put_u16le(dst + 4, g->x1); put_u16le(dst + 6, g->y1);
        memcpy(&bits, &g->xoff, sizeof bits); put_u32le(dst + 8, bits);
        memcpy(&bits, &g->yoff, sizeof bits); put_u32le(dst + 12, bits);
        memcpy(&bits, &g->xadvance, sizeof bits); put_u32le(dst + 16, bits);
    }
    for (size_t i = 0; i < pixels; i++) data[pixel_offset + i] = font.rgba[i * 4 + 3];

    CHECK(ui_font_load_prebaked(data, len, font.pixel_height, &loaded) == 0);
    if (loaded.rgba != NULL) {
        CHECK(loaded.first == font.first && loaded.count == font.count);
        CHECK(loaded.pixel_height == font.pixel_height && loaded.line_height == font.line_height);
        CHECK(loaded.atlas_w == font.atlas_w && loaded.atlas_h == font.atlas_h);
        CHECK(memcmp(loaded.rgba, font.rgba, pixels * 4) == 0);
        CHECK(near(loaded.glyphs['a' - loaded.first].xadvance, glyph('a')->xadvance));
        ui_font_destroy(&loaded);
    }
    expect_prebaked_rejected(data, len, font.pixel_height + 1); /* configured size mismatch */
    expect_prebaked_rejected(data, len - 1, font.pixel_height); /* truncated atlas payload */
    expect_prebaked_rejected(NULL, len, font.pixel_height);
    CHECK(ui_font_load_prebaked(data, len, font.pixel_height, NULL) != 0);

    data[0] = 'X';
    expect_prebaked_rejected(data, len, font.pixel_height); /* bad magic */
    data[0] = 'B';
    data[4] = 2;
    expect_prebaked_rejected(data, len, font.pixel_height); /* unsupported version */
    data[4] = 1;
    data[36] ^= 1;
    expect_prebaked_rejected(data, len, font.pixel_height); /* inconsistent atlas pixel count */
    data[36] ^= 1;

    put_u16le(data + 48, 2); /* first glyph has x0 > x1 */
    expect_prebaked_rejected(data, len, font.pixel_height);
    put_u16le(data + 48, font.glyphs[0].x0);
    data[48 + 8] = 0; data[48 + 9] = 0; data[48 + 10] = 128; data[48 + 11] = 127; /* infinite x offset */
    expect_prebaked_rejected(data, len, font.pixel_height);
    memcpy(&bits, &font.glyphs[0].xoff, sizeof bits); put_u32le(data + 48 + 8, bits);

    put_u16le(data + 44, 0); /* empty solid-white sample rectangle */
    expect_prebaked_rejected(data, len, font.pixel_height);
    free(data);
}

int main(int argc, char **argv) {
    unsigned char *ttf;
    size_t len = 0;

    if (argc != 2) {
        fprintf(stderr, "usage: %s font.ttf\n", argv[0]);
        return 2;
    }
    ttf = read_file(argv[1], &len);
    if (!ttf) {
        fprintf(stderr, "cannot read %s\n", argv[1]);
        return 2;
    }
    /* 32..255 covers printable ASCII and Latin-1, so the "é" check has a real glyph. */
    if (ui_font_bake(ttf, len, 16.0f, 32, 224, &font) != 0) {
        fprintf(stderr, "font bake failed\n");
        return 1;
    }

    check_atlas();
    check_width();
    check_draw();
    check_prebaked_roundtrip();

    free(ttf);
    ui_font_destroy(&font);
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("text: all checks passed\n");
    return 0;
}
