/*
 * test_text.c: checks the baked atlas and the glyph quads that text produces.
 *
 * Build and run from the project root, after fetching stb_truetype.h into vendor/:
 *   gcc -std=c99 -Wall -Wextra -fsanitize=address,undefined -Ivendor -Isrc/engine/ui \
 *       tests/ui/test_text.c src/engine/ui/text.c vendor/stb_truetype_impl.c -lm -o test_text
 *   ./test_text path/to/font.ttf
 */
#include "text.h"

#include <stdio.h>
#include <stdlib.h>

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

    free(ttf);
    ui_font_destroy(&font);
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("text: all checks passed\n");
    return 0;
}
