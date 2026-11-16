#include <cstdio>
#include <cstdlib>
#include "hb.h"
int main() {
    FILE* f = fopen("/home/claude/work/next2/assets/font.ttf", "rb");
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char* b = (char*)malloc(n); fread(b, 1, n, f); fclose(f);
    hb_face_t* face = hb_face_create(hb_blob_create(b, (unsigned)n, HB_MEMORY_MODE_WRITABLE, b, free), 0);
    hb_font_t* font = hb_font_create(face);
    hb_font_set_scale(font, 16*64, 16*64);
    hb_buffer_t* buf = hb_buffer_create();
    hb_buffer_add_utf8(buf, "", 0, 0, 0);
    hb_buffer_guess_segment_properties(buf);
    hb_shape(font, buf, nullptr, 0);
    printf("empty: length=%u\n", hb_buffer_get_length(buf));
    // Also check a mismatched-length string: AVATAR at 16 px still gives 6 glyphs (already known).
    return 0;
}
