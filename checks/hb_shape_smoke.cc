#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "hb.h"

static hb_blob_t* load(const char* path) {
    FILE* f = fopen(path, "rb"); if (!f) return nullptr;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char* buf = (char*)malloc(n); fread(buf, 1, n, f); fclose(f);
    return hb_blob_create(buf, (unsigned)n, HB_MEMORY_MODE_WRITABLE, buf, free);
}

static int shape(const char* font_path, const char* text, const char* label) {
    hb_blob_t* blob = load(font_path);
    if (!blob) { printf("%s: cannot load %s\n", label, font_path); return 1; }
    hb_face_t* face = hb_face_create(blob, 0);
    hb_font_t* font = hb_font_create(face);
    hb_font_set_scale(font, 16 * 64, 16 * 64);   // 16 px in 26.6, direction-independent
    hb_buffer_t* buf = hb_buffer_create();
    hb_buffer_add_utf8(buf, text, -1, 0, -1);
    hb_buffer_guess_segment_properties(buf);
    hb_shape(font, buf, nullptr, 0);
    unsigned n = hb_buffer_get_length(buf);
    const hb_glyph_info_t* info = hb_buffer_get_glyph_infos(buf, nullptr);
    const hb_glyph_position_t* pos = hb_buffer_get_glyph_positions(buf, nullptr);
    printf("%s: %u glyphs for %zu bytes, dir=%s\n", label, n, strlen(text),
           hb_direction_to_string(hb_buffer_get_direction(buf)));
    for (unsigned i = 0; i < n && i < 12; i++)
        printf("  [%u] gid=%u cluster=%u adv=%d off=(%d,%d)\n", i, info[i].codepoint, info[i].cluster,
               pos[i].x_advance, pos[i].x_offset, pos[i].y_offset);
    hb_buffer_destroy(buf); hb_font_destroy(font); hb_face_destroy(face); hb_blob_destroy(blob);
    return 0;
}

int main() {
    printf("HarfBuzz %s\n", hb_version_string());
    int rc = 0;
    rc |= shape("/home/claude/work/next2/assets/font.ttf", "AVATAR", "VT323 Latin");
    rc |= shape("/home/claude/work/tools/assets/tamil.ttf", "\xE0\xAE\xA4\xE0\xAE\xAE\xE0\xAE\xBF\xE0\xAE\xB4\xE0\xAF\x8D", "Tamil tamil.ttf");
    return rc;
}
