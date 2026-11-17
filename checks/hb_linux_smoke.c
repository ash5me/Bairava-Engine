/*
 * Linux check for the vendored HarfBuzz 15.1.0 build. It repeats the assertions in
 * src/engine/text/hb_smoke.zig and src/engine/text/hb_shape_test.zig through the same
 * HarfBuzz C API, so it can run without Zig or a display.
 *
 * Build from the repository root, with vendor/harfbuzz-15.1.0/ present:
 *
 *   g++ -std=c++11 -fno-exceptions -fno-rtti -c vendor/harfbuzz-15.1.0/src/harfbuzz.cc \
 *       -Ivendor/harfbuzz-15.1.0/src -o harfbuzz.o
 *   gcc -std=c99 -Wall -Wextra -Ivendor/harfbuzz-15.1.0/src checks/hb_linux_smoke.c \
 *       harfbuzz.o -lstdc++ -lm -o hb_linux_smoke
 *   ./hb_linux_smoke assets/font.ttf
 *
 * The font argument defaults to assets/font.ttf, the shipped UI font (Arial 7.07). The
 * assertions mirror hb_shape_test.zig. Exit status is 0 when every check passes and 1 otherwise.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "hb.h"

static int failures = 0;

#define CHECK(cond, msg)                                    \
    do {                                                    \
        if (!(cond)) {                                      \
            printf("FAIL: %s\n", msg);                      \
            failures++;                                     \
        } else {                                            \
            printf("ok:   %s\n", msg);                      \
        }                                                   \
    } while (0)

typedef struct {
    int ok;                    /* 0 if the font could not be loaded */
    unsigned count;
    uint32_t gids[16];
    uint32_t clusters[16];
    int32_t advances[16];
} Shaped;

/* Shapes text at pixel_height pixels per em, as in hb_shape_test.zig. */
static Shaped shape(const char *path, const char *text, unsigned pixel_height) {
    Shaped out;
    memset(&out, 0, sizeof out);

    hb_blob_t *blob = hb_blob_create_from_file_or_fail(path);
    if (!blob) return out;
    hb_face_t *face = hb_face_create(blob, 0);
    hb_font_t *font = hb_font_create(face);

    int scale = (int)(pixel_height * 64);  /* HarfBuzz scales in 26.6 fixed point */
    hb_font_set_scale(font, scale, scale);

    hb_buffer_t *buf = hb_buffer_create();
    size_t len = strlen(text);
    hb_buffer_add_utf8(buf, text, (int)len, 0, (int)len);
    hb_buffer_guess_segment_properties(buf);
    hb_shape(font, buf, NULL, 0);

    unsigned n = hb_buffer_get_length(buf);
    if (n > 16) n = 16;
    const hb_glyph_info_t *infos = hb_buffer_get_glyph_infos(buf, NULL);
    const hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(buf, NULL);
    out.ok = 1;
    out.count = n;
    for (unsigned i = 0; i < n; i++) {
        out.gids[i] = infos[i].codepoint;
        out.clusters[i] = infos[i].cluster;
        out.advances[i] = pos[i].x_advance;
    }

    hb_buffer_destroy(buf);
    hb_font_destroy(font);
    hb_face_destroy(face);
    hb_blob_destroy(blob);
    return out;
}

int main(int argc, char **argv) {
    const char *font = argc > 1 ? argv[1] : "assets/font.ttf";
    const char *version = hb_version_string();

    CHECK(strcmp(version, "15.1.0") == 0, "HarfBuzz links and reports pinned version 15.1.0");
    printf("      hb_version_string() = %s, font = %s\n", version, font);

    Shaped avatar = shape(font, "AVATAR", 16);
    CHECK(avatar.ok && avatar.count == 6, "AVATAR shapes to six glyphs");

    int clusters_ok = avatar.ok && avatar.count == 6;
    for (unsigned i = 0; clusters_ok && i < 6; i++) {
        if (avatar.clusters[i] != i) clusters_ok = 0;
    }
    CHECK(clusters_ok, "clusters are 0..5 in input order");

    CHECK(avatar.ok && avatar.gids[0] == avatar.gids[2] && avatar.gids[0] == avatar.gids[4],
          "repeated A in AVATAR maps to one glyph id");

    Shaped pair = shape(font, "AV", 16);
    Shaped alone = shape(font, "A", 16);
    CHECK(pair.ok && pair.count == 2 && alone.ok && alone.count == 1,
          "AV shapes to two glyphs and A alone to one");
    CHECK(pair.ok && alone.ok && pair.advances[0] < alone.advances[0],
          "shipped Arial kerns the AV pair: the A is narrower before V than alone");

    int proportional = avatar.ok && avatar.count == 6;
    int all_equal = 1;
    for (unsigned i = 0; proportional && i < 6; i++) {
        if (avatar.advances[i] <= 0) proportional = 0;
        if (avatar.advances[i] != avatar.advances[0]) all_equal = 0;
    }
    CHECK(proportional && !all_equal,
          "shipped Arial is proportional: AVATAR advances are positive and not all equal");

    printf("      AVATAR gids=");
    for (unsigned i = 0; avatar.ok && i < avatar.count; i++)
        printf("%u%s", avatar.gids[i], i + 1 < avatar.count ? "," : "");
    printf("  advances=");
    for (unsigned i = 0; avatar.ok && i < avatar.count; i++)
        printf("%d%s", avatar.advances[i], i + 1 < avatar.count ? "," : "");
    printf("\n");

    Shaped empty = shape(font, "", 16);
    CHECK(empty.ok && empty.count == 0, "empty text shapes to zero glyphs");

    printf("%s (%d failure%s)\n", failures ? "FAILED" : "PASSED", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
