/*
 * test_text.c: checks baked and preprocessed font data, plus the glyph quads text produces.
 *
 * Run from the project root with `zig build test-ui`.
 */
#include "text.h"
#include "font_bake.h"
#include "test_support.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static ui_font font;
static ui_quad_list list; /* static, because the quad list is large */
static ui_quad_list second; /* a second list, for comparing what two fonts draw */

static int near(float a, float b) {
    float d = a - b;
    return d > -0.01f && d < 0.01f;
}

static const ui_glyph *glyph(int cp) {
    return &font.glyphs[cp - font.first];
}

static unsigned char alpha_at(int x, int y) {
    return font.alpha[(size_t)y * font.atlas_w + x];
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

    /* A valid multibyte character outside the baked range draws the '?' fallback. */
    list.count = 0;
    ui_font_draw_text(&font, &list, 0, 0, "\xE4\xB8\x80", 3, red);
    CHECK(list.count == 1);
    if (list.count == 1) {
        CHECK(list.items[0].src.x == glyph('?')->x0 && list.items[0].src.y == glyph('?')->y0);
    }

    /* A space has no pixels, so it adds no quad but still moves the pen. */
    list.count = 0;
    ui_font_draw_text(&font, &list, 0, 0, "a b", 3, red);
    CHECK(list.count == 2);

    list.count = 0;
    ui_font_draw_text(&font, &list, 0, 0, "", 0, red);
    CHECK(list.count == 0);
}

/* The mono bake at 7 px, the size the debug overlay uses. Hinting at the real size makes every texel 0 or 255,
 * puts each stem on one whole column, puts the x-height on a whole row, and gives whole-pixel advances. */
static ui_font mono;

static void check_mono(const char *path) {
    int w, h, i, bad_texels = 0, bad_advances = 0, l_index, z_index, x;
    const ui_glyph *l, *z;
    if (!ui_test_load_font_raster(path, 7.0f, 32, 224, UI_FONT_RASTER_MONO, &mono)) {
        CHECK(0);
        return;
    }
    w = mono.atlas_w;
    h = mono.atlas_h;

    /* Every texel is either empty or full: there is no gray. */
    for (i = 0; i < w * h; i++) {
        if (mono.alpha[i] != 0 && mono.alpha[i] != 255) bad_texels++;
    }
    CHECK(bad_texels == 0);
    CHECK(mono.alpha[0] == 255 && mono.alpha[1] == 255); /* the white block survives */

    /* Hinted advances are whole pixels, so letter spacing is even. */
    for (i = 0; i < mono.count; i++) {
        if (mono.glyphs[i].xadvance != (float)(int)mono.glyphs[i].xadvance) bad_advances++;
    }
    CHECK(bad_advances == 0);

    /* The stem of 'l' fills exactly one column of its middle row, at full strength. */
    l_index = 'l' - mono.first;
    l = &mono.glyphs[l_index];
    CHECK(l->x1 > l->x0 && l->y1 > l->y0);
    if (l->x1 > l->x0 && l->y1 > l->y0) {
        int row = l->y0 + (l->y1 - l->y0) / 2, peak = 0, columns = 0;
        for (x = l->x0; x < l->x1; x++) {
            int v = mono.alpha[row * w + x];
            if (v > peak) peak = v;
            if (v != 0) columns++;
        }
        CHECK(peak == 255);
        CHECK(columns == 1);
    }

    /* The top row of 'z' is full, so the x-height falls on a pixel edge rather than splitting a row. */
    z_index = 'z' - mono.first;
    z = &mono.glyphs[z_index];
    CHECK(z->x1 > z->x0 && z->y1 > z->y0);
    if (z->x1 > z->x0 && z->y1 > z->y0) {
        int peak = 0;
        for (x = z->x0; x < z->x1; x++) {
            int v = mono.alpha[z->y0 * w + x];
            if (v > peak) peak = v;
        }
        CHECK(peak == 255);
    }

    /* An invalid raster or size is rejected, and leaves the font empty. */
    {
        ui_font rejected;
        memset(&rejected, 0xA5, sizeof rejected);
        CHECK(ui_font_bake_mode(NULL, 0, 7.0f, 32, 224, UI_FONT_RASTER_MONO, &rejected) != 0);
        CHECK(rejected.alpha == NULL && rejected.glyphs == NULL);
        CHECK(ui_font_bake_mode(NULL, 0, 7.0f, 32, 224, (ui_font_raster)99, &rejected) != 0);
        CHECK(rejected.alpha == NULL && rejected.glyphs == NULL);
    }
    ui_font_destroy(&mono);
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
    CHECK(rejected.alpha == NULL && rejected.glyphs == NULL);
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
    for (size_t i = 0; i < pixels; i++) data[pixel_offset + i] = font.alpha[i];

    CHECK(ui_font_load_prebaked(data, len, font.pixel_height, &loaded) == 0);
    if (loaded.alpha != NULL) {
        CHECK(loaded.first == font.first && loaded.count == font.count);
        CHECK(loaded.pixel_height == font.pixel_height && loaded.line_height == font.line_height);
        CHECK(loaded.atlas_w == font.atlas_w && loaded.atlas_h == font.atlas_h);
        CHECK(memcmp(loaded.alpha, font.alpha, pixels) == 0);
        CHECK(loaded.fallback == '?'); /* v1 has no field, so the default applies */
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
    data[4] = 5;
    expect_prebaked_rejected(data, len, font.pixel_height); /* unsupported version 5. Version 2 is supported; see check_v2_format. */
    data[4] = 3;
    put_u16le(data + 6, 56);
    expect_prebaked_rejected(data, len, font.pixel_height); /* SDF atlases (v3) are no longer supported */
    put_u16le(data + 6, 48);
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

/* Serializes `f` as a BFNT v4 file that records `fallback`. The caller frees the result. */
static unsigned char *write_v4(const ui_font *f, int fallback, size_t *len_out) {
    size_t pixels = (size_t)f->atlas_w * (size_t)f->atlas_h;
    size_t len = 56 + (size_t)f->count * 20 + (size_t)f->kerning_count * 12 + pixels;
    unsigned char *data = calloc(len, 1);
    size_t pos = 56, p;
    unsigned int bits;
    int i;
    if (data == NULL) return NULL;
    memcpy(data, "BFNT", 4);
    put_u16le(data + 4, 4);
    put_u16le(data + 6, 56);
    memcpy(&bits, &f->pixel_height, sizeof bits); put_u32le(data + 8, bits);
    put_u32le(data + 12, (unsigned int)f->first);
    put_u32le(data + 16, (unsigned int)f->count);
    put_u32le(data + 20, (unsigned int)f->ascent);
    put_u32le(data + 24, (unsigned int)f->line_height);
    put_u32le(data + 28, (unsigned int)f->atlas_w);
    put_u32le(data + 32, (unsigned int)f->atlas_h);
    put_u32le(data + 36, (unsigned int)pixels);
    put_u16le(data + 40, (unsigned short)f->white.x);
    put_u16le(data + 42, (unsigned short)f->white.y);
    put_u16le(data + 44, (unsigned short)f->white.w);
    put_u16le(data + 46, (unsigned short)f->white.h);
    put_u32le(data + 48, (unsigned int)f->kerning_count);
    put_u32le(data + 52, (unsigned int)fallback);
    for (i = 0; i < f->count; i++, pos += 20) {
        const ui_glyph *g = &f->glyphs[i];
        unsigned char *dst = data + pos;
        put_u16le(dst, g->x0); put_u16le(dst + 2, g->y0);
        put_u16le(dst + 4, g->x1); put_u16le(dst + 6, g->y1);
        memcpy(&bits, &g->xoff, sizeof bits); put_u32le(dst + 8, bits);
        memcpy(&bits, &g->yoff, sizeof bits); put_u32le(dst + 12, bits);
        memcpy(&bits, &g->xadvance, sizeof bits); put_u32le(dst + 16, bits);
    }
    for (i = 0; i < f->kerning_count; i++, pos += 12) {
        unsigned char *dst = data + pos;
        put_u32le(dst, f->kernings[i].left);
        put_u32le(dst + 4, f->kernings[i].right);
        memcpy(&bits, &f->kernings[i].advance, sizeof bits); put_u32le(dst + 8, bits);
    }
    for (p = 0; p < pixels; p++) data[pos + p] = f->alpha[p];
    *len_out = len;
    return data;
}

/* Serializes `f` as a BFNT v2 file: a 52-byte header that records a kerning count and has no fallback field,
 * so the loader gives it the default. Layout: header, glyph records, kerning records, atlas. The caller frees
 * the result. No v2 file ships in the repository, and the baker writes only v4, so this writer is the fixture. */
static unsigned char *write_v2(const ui_font *f, size_t *len_out) {
    size_t pixels = (size_t)f->atlas_w * (size_t)f->atlas_h;
    size_t len = 52 + (size_t)f->count * 20 + (size_t)f->kerning_count * 12 + pixels;
    unsigned char *data = calloc(len, 1);
    size_t pos = 52, p;
    unsigned int bits;
    int i;
    if (data == NULL) return NULL;
    memcpy(data, "BFNT", 4);
    put_u16le(data + 4, 2);
    put_u16le(data + 6, 52);
    memcpy(&bits, &f->pixel_height, sizeof bits); put_u32le(data + 8, bits);
    put_u32le(data + 12, (unsigned int)f->first);
    put_u32le(data + 16, (unsigned int)f->count);
    put_u32le(data + 20, (unsigned int)f->ascent);
    put_u32le(data + 24, (unsigned int)f->line_height);
    put_u32le(data + 28, (unsigned int)f->atlas_w);
    put_u32le(data + 32, (unsigned int)f->atlas_h);
    put_u32le(data + 36, (unsigned int)pixels);
    put_u16le(data + 40, (unsigned short)f->white.x);
    put_u16le(data + 42, (unsigned short)f->white.y);
    put_u16le(data + 44, (unsigned short)f->white.w);
    put_u16le(data + 46, (unsigned short)f->white.h);
    put_u32le(data + 48, (unsigned int)f->kerning_count);
    for (i = 0; i < f->count; i++, pos += 20) {
        const ui_glyph *g = &f->glyphs[i];
        unsigned char *dst = data + pos;
        put_u16le(dst, g->x0); put_u16le(dst + 2, g->y0);
        put_u16le(dst + 4, g->x1); put_u16le(dst + 6, g->y1);
        memcpy(&bits, &g->xoff, sizeof bits); put_u32le(dst + 8, bits);
        memcpy(&bits, &g->yoff, sizeof bits); put_u32le(dst + 12, bits);
        memcpy(&bits, &g->xadvance, sizeof bits); put_u32le(dst + 16, bits);
    }
    for (i = 0; i < f->kerning_count; i++, pos += 12) {
        unsigned char *dst = data + pos;
        put_u32le(dst, f->kernings[i].left);
        put_u32le(dst + 4, f->kernings[i].right);
        memcpy(&bits, &f->kernings[i].advance, sizeof bits); put_u32le(dst + 8, bits);
    }
    for (p = 0; p < pixels; p++) data[pos + p] = f->alpha[p];
    *len_out = len;
    return data;
}

/* The fallback is part of the file. '?' is recorded for a font that has it, a font without '?' may record
 * none, and a fallback outside the baked range is malformed. */
static void check_fallback(const char *path) {
    static ui_font letters; /* a font with no '?' in its range */
    ui_color red = { 1, 0, 0, 1 };
    unsigned char *data;
    size_t len = 0;
    ui_font loaded;

    data = write_v4(&font, '?', &len);
    CHECK(data != NULL);
    if (data != NULL) {
        CHECK(ui_font_load_prebaked(data, len, font.pixel_height, &loaded) == 0);
        if (loaded.alpha != NULL) {
            CHECK(loaded.fallback == '?');
            ui_font_destroy(&loaded);
        }
        put_u32le(data + 52, 0); /* outside the baked range */
        expect_prebaked_rejected(data, len, font.pixel_height);
        put_u32le(data + 52, (unsigned int)-1); /* none is always allowed */
        CHECK(ui_font_load_prebaked(data, len, font.pixel_height, &loaded) == 0);
        if (loaded.alpha != NULL) {
            CHECK(loaded.fallback == -1);
            list.count = 0;
            ui_font_draw_text(&loaded, &list, 0, 0, "\xE4\xB8\x80", 3, red); /* U+4E00, not baked */
            CHECK(list.count == 0);
            ui_font_destroy(&loaded);
        }
        free(data);
    }

    if (!ui_test_load_font(path, 16.0f, 'a', 26, &letters)) {
        ui_test_failures++;
        return;
    }
    CHECK(letters.fallback == -1);
    CHECK(ui_font_text_width(&letters, "?", 1) == 0);
    list.count = 0;
    ui_font_draw_text(&letters, &list, 0, 0, "a?b", 3, red);
    CHECK(list.count == 2); /* '?' draws nothing, but the pen still moves past it */

    data = write_v4(&letters, '?', &len); /* '?' is not baked in this font, so it cannot be the fallback */
    CHECK(data != NULL);
    if (data != NULL) {
        expect_prebaked_rejected(data, len, letters.pixel_height);
        free(data);
    }

    data = write_v4(&letters, 'b', &len);
    CHECK(data != NULL);
    if (data != NULL) {
        CHECK(ui_font_load_prebaked(data, len, letters.pixel_height, &loaded) == 0);
        if (loaded.alpha != NULL) {
            const ui_glyph *b = &letters.glyphs['b' - letters.first];
            CHECK(loaded.fallback == 'b');
            list.count = 0;
            ui_font_draw_text(&loaded, &list, 0, 0, "?", 1, red);
            CHECK(list.count == 1);
            if (list.count == 1) CHECK(list.items[0].src.x == b->x0 && list.items[0].src.y == b->y0);
            ui_font_destroy(&loaded);
        }
        free(data);
    }
    ui_font_destroy(&letters);
}

/* A font built by hand, so every value the v2 check depends on is known. The atlas is 8 by 8 with a 2 by 2 white
 * block in the corner. Each glyph is a 2 by 2 rectangle at (2, 2) with advance 3 + (codepoint % 4): 'A' advances 4,
 * 'B' advances 5, and '?' advances 6. Kerning: 1 pair adds ('A', 'B') by -1; 2 pairs also add ('B', 'A') by -0.5,
 * which sorts after it. The caller frees the font with ui_font_destroy. */
static void make_v2_fixture(ui_font *f, int first, int count, int kern_pairs) {
    static const float kern_advance[2] = { -1.0f, -0.5f };
    static const unsigned int kern_left[2] = { 'A', 'B' }, kern_right[2] = { 'B', 'A' };
    int i, x, y;
    memset(f, 0, sizeof *f);
    f->first = first;
    f->count = count;
    f->fallback = ui_font_default_fallback(first, count);
    f->pixel_height = 8.0f;
    f->ascent = 8;
    f->line_height = 10;
    f->atlas_w = 8;
    f->atlas_h = 8;
    f->white = (ui_rect){ 0, 0, 2, 2 };
    f->alpha = calloc(64, 1);
    f->glyphs = calloc((size_t)count, sizeof *f->glyphs);
    f->kernings = kern_pairs > 0 ? calloc((size_t)kern_pairs, sizeof *f->kernings) : NULL;
    f->kerning_count = kern_pairs;
    if (f->alpha == NULL || f->glyphs == NULL || (kern_pairs > 0 && f->kernings == NULL)) {
        ui_test_failures++;
        return;
    }
    for (y = 0; y < 8; y++)
        for (x = 0; x < 8; x++)
            f->alpha[y * 8 + x] = (x < 2 && y < 2) ? 255 : (unsigned char)(10 * (x + y) + 1);
    for (i = 0; i < count; i++) {
        ui_glyph *g = &f->glyphs[i];
        g->x0 = 2; g->y0 = 2; g->x1 = 4; g->y1 = 4;
        g->xoff = 0; g->yoff = -6;
        g->xadvance = 3.0f + (float)((first + i) % 4);
    }
    for (i = 0; i < kern_pairs; i++) {
        f->kernings[i].left = kern_left[i];
        f->kernings[i].right = kern_right[i];
        f->kernings[i].advance = kern_advance[i];
    }
}

static int same_glyph(const ui_glyph *a, const ui_glyph *b) {
    return a->x0 == b->x0 && a->y0 == b->y0 && a->x1 == b->x1 && a->y1 == b->y1 &&
           a->xoff == b->xoff && a->yoff == b->yoff && a->xadvance == b->xadvance;
}

static int same_quad(const ui_quad *a, const ui_quad *b) {
    return a->dst.x == b->dst.x && a->dst.y == b->dst.y && a->dst.w == b->dst.w && a->dst.h == b->dst.h &&
           a->src.x == b->src.x && a->src.y == b->src.y && a->src.w == b->src.w && a->src.h == b->src.h &&
           a->color.r == b->color.r && a->color.g == b->color.g && a->color.b == b->color.b && a->color.a == b->color.a;
}

/* BFNT v2 is not covered by the v1 and v4 checks: each version has its own header length and its own optional
 * field. This writes a real v2 file and checks what the loader makes of it, field by field, then the rejections
 * that depend on the v2 layout. */
static void check_v2_format(void) {
    ui_font src, loaded, plain, wide;
    ui_color red = { 1, 0, 0, 1 };
    unsigned char *data;
    unsigned char kept[24];
    size_t len = 0;
    int i, same;

    /* 'A' and 'B' with two kerning pairs. No '?' is in the range, so the default fallback is none. */
    make_v2_fixture(&src, 65, 2, 2);
    data = write_v2(&src, &len);
    CHECK(data != NULL);
    if (data == NULL) {
        ui_font_destroy(&src);
        return;
    }
    CHECK(data[4] == 2 && data[5] == 0 && data[6] == 52 && data[7] == 0); /* the fixture is really v2 */
    CHECK(ui_font_load_prebaked(data, len, src.pixel_height, &loaded) == 0);
    if (loaded.alpha != NULL) {
        CHECK(loaded.first == 65 && loaded.count == 2 && loaded.kerning_count == 2);
        CHECK(loaded.pixel_height == 8.0f && loaded.ascent == 8 && loaded.line_height == 10);
        CHECK(loaded.atlas_w == 8 && loaded.atlas_h == 8);
        CHECK(loaded.white.x == 0 && loaded.white.y == 0 && loaded.white.w == 2 && loaded.white.h == 2);
        CHECK(memcmp(loaded.alpha, src.alpha, 64) == 0);
        same = 1;
        for (i = 0; i < 2; i++) same &= same_glyph(&loaded.glyphs[i], &src.glyphs[i]);
        CHECK(same);
        CHECK(loaded.kernings[0].left == 'A' && loaded.kernings[0].right == 'B' && loaded.kernings[0].advance == -1.0f);
        CHECK(loaded.kernings[1].left == 'B' && loaded.kernings[1].right == 'A' && loaded.kernings[1].advance == -0.5f);
        /* v2 has no fallback field, so it gets the default, which is none here. The 52 bytes where v4 reads
         * the fallback hold the first glyph in a v2 file, so reading them would give a different value. */
        CHECK(loaded.fallback == -1);
        CHECK(near(ui_font_text_width(&loaded, "A", 1), 4.0f));
        CHECK(near(ui_font_text_width(&loaded, "AB", 2), 8.0f)); /* 4 + 5 - 1 */
        CHECK(near(ui_font_text_width(&loaded, "BA", 2), 8.5f)); /* 5 + 4 - 0.5 */
        CHECK(near(ui_font_text_width(&loaded, "C", 1), 0.0f));   /* not baked, and no fallback, so nothing */

        /* Drawing the loaded font gives the same quads as drawing the font it was written from. */
        list.count = 0;
        second.count = 0;
        ui_font_draw_text(&src, &list, 0, 0, "ABBA", 4, red);
        ui_font_draw_text(&loaded, &second, 0, 0, "ABBA", 4, red);
        CHECK(list.count == 4 && second.count == list.count);
        same = second.count == list.count;
        for (i = 0; same && i < list.count; i++) same = same_quad(&list.items[i], &second.items[i]);
        CHECK(same);
        ui_font_destroy(&loaded);
    }

    /* Rejections specific to the v2 layout. Each change is undone afterward. */
    expect_prebaked_rejected(data, len, 9.0f); /* baked at 8 px, asked for 9 */
    data[6] = 48; expect_prebaked_rejected(data, len, 8.0f); data[6] = 52; /* v1's header length on a v2 file */
    data[6] = 56; expect_prebaked_rejected(data, len, 8.0f); data[6] = 52; /* v4's header length on a v2 file */
    put_u32le(data + 48, 3); expect_prebaked_rejected(data, len, 8.0f); put_u32le(data + 48, 2); /* kerning count disagrees with the length */
    put_u32le(data + 96, 70); expect_prebaked_rejected(data, len, 8.0f); put_u32le(data + 96, 'B'); /* right is outside 'A'..'B' */
    memcpy(kept, data + 92, 24);
    memcpy(data + 92, kept + 12, 12); memcpy(data + 104, kept, 12); /* kerning pairs out of (left, right) order */
    expect_prebaked_rejected(data, len, 8.0f);
    memcpy(data + 92, kept, 24);
    data[4] = 5; expect_prebaked_rejected(data, len, 8.0f); data[4] = 2; /* an unsupported version with a v2 header length */
    expect_prebaked_rejected(data, len - 1, 8.0f); /* truncated kerning and atlas */
    free(data);
    ui_font_destroy(&src);

    /* No kerning pairs: the count is zero, the table is absent, and widths are plain advances. */
    make_v2_fixture(&plain, 65, 2, 0);
    data = write_v2(&plain, &len);
    if (data != NULL) {
        CHECK(ui_font_load_prebaked(data, len, 8.0f, &loaded) == 0);
        if (loaded.alpha != NULL) {
            CHECK(loaded.kerning_count == 0 && loaded.kernings == NULL);
            CHECK(near(ui_font_text_width(&loaded, "AB", 2), 9.0f)); /* 4 + 5, no kerning */
            ui_font_destroy(&loaded);
        }
        free(data);
    }
    ui_font_destroy(&plain);

    /* A range that holds '?' gets '?' as its default fallback, and a codepoint outside the range draws it. */
    make_v2_fixture(&wide, 32, 95, 1);
    data = write_v2(&wide, &len);
    if (data != NULL) {
        CHECK(ui_font_load_prebaked(data, len, 8.0f, &loaded) == 0);
        if (loaded.alpha != NULL) {
            CHECK(loaded.fallback == '?');
            CHECK(near(ui_font_text_width(&loaded, "\x01", 1), 6.0f)); /* U+0001 is not baked, so it measures as '?' */
            CHECK(near(ui_font_text_width(&loaded, "AB", 2), 8.0f));
            ui_font_destroy(&loaded);
        }
        free(data);
    }
    ui_font_destroy(&wide);
}

/* After the atlas is uploaded its CPU copy is released. Measuring and drawing must still work, and
 * releasing again is harmless. This runs last, because the atlas is gone afterward. */
static void check_release(void) {
    float width = ui_font_text_width(&font, "ab", 2);
    ui_color red = { 1, 0, 0, 1 };

    ui_font_release_atlas(&font);
    CHECK(font.alpha == NULL);
    CHECK(font.glyphs != NULL && font.count > 0);
    CHECK(near(ui_font_text_width(&font, "ab", 2), width));

    list.count = 0;
    ui_font_draw_text(&font, &list, 0, 0, "ab", 2, red);
    CHECK(list.count == 2);

    ui_font_release_atlas(&font);
    ui_font_release_atlas(NULL);
    CHECK(font.alpha == NULL);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s font.ttf\n", argv[0]);
        return 2;
    }
    /* Bake printable ASCII and the Latin-1 range. */
    if (!ui_test_load_font(argv[1], 16.0f, 32, 224, &font)) {
        return 1;
    }

    check_atlas();
    check_width();
    check_draw();
    check_prebaked_roundtrip();
    check_v2_format();
    check_fallback(argv[1]);
    check_release();
    check_mono(argv[1]);

    ui_font_destroy(&font);
    if (ui_test_failures) {
        fprintf(stderr, "%d check(s) failed\n", ui_test_failures);
        return 1;
    }
    printf("text: all checks passed\n");
    return 0;
}
