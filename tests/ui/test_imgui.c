/*
 * test_imgui.c: drives the widgets with scripted pointer input and checks what they report.
 *
 * Build and run from the project root, after fetching stb_truetype.h into vendor/:
 *   gcc -std=c99 -Wall -Wextra -fsanitize=address,undefined -Ivendor -Isrc/engine/ui \
 *       tests/ui/test_imgui.c src/engine/ui/imgui.c src/engine/text/text.c \
 *       vendor/stb_truetype_impl.c -lm -o test_imgui
 *   ./test_imgui path/to/font.ttf
 */
#include "imgui.h"

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

/* The column every test uses: left edge 10, width 200, top 10. */
#define COL_X 10.0f
#define COL_Y 10.0f
#define COL_W 200.0f

static ui_font font;
static ui_context ui; /* static, because the quad list is large */

static ui_input pointer(float x, float y, int down, int pressed, int released) {
    ui_input in = { x, y, down, pressed, released };
    return in;
}

/* Vertical center of row `row` in the column. */
static float row_mid(int row) {
    float h = (float)font.line_height + 2 * ui.theme.pad;
    return COL_Y + row * (h + ui.theme.spacing) + h * 0.5f;
}

static int button_frame(ui_input in, const char *label) {
    int clicked;
    ui_begin(&ui, &in, COL_X, COL_Y, COL_W);
    clicked = ui_button(&ui, label);
    ui_end(&ui);
    return clicked;
}

static int slider_frame(ui_input in, const char *label, float *value, float lo, float hi) {
    int changed;
    ui_begin(&ui, &in, COL_X, COL_Y, COL_W);
    changed = ui_slider(&ui, label, value, lo, hi);
    ui_end(&ui);
    return changed;
}

static int near(float a, float b) {
    float d = a - b;
    return d > -0.01f && d < 0.01f;
}

static void test_button_click(void) {
    float y = row_mid(0);
    int c_hover, c_press, c_hold, c_release, c_after;

    c_hover = button_frame(pointer(60, y, 0, 0, 0), "Go");
    CHECK(ui.list.count > 0);
    CHECK(ui.list.items[0].color.r == ui.theme.button_hot.r); /* hovered: the hot color */
    c_press = button_frame(pointer(60, y, 1, 1, 0), "Go");
    c_hold = button_frame(pointer(60, y, 1, 0, 0), "Go");
    c_release = button_frame(pointer(60, y, 0, 0, 1), "Go");
    c_after = button_frame(pointer(60, y, 0, 0, 0), "Go");

    CHECK(!c_hover && !c_press && !c_hold);
    CHECK(c_release == 1);
    CHECK(!c_after);
}

static void test_release_outside_cancels(void) {
    float y = row_mid(0);
    CHECK(!button_frame(pointer(60, y, 1, 1, 0), "Go"));  /* press starts on the button */
    CHECK(!button_frame(pointer(500, y, 0, 0, 1), "Go")); /* released well away from it */
    CHECK(!button_frame(pointer(60, y, 0, 0, 0), "Go"));  /* and the next frame is quiet */
}

static void test_suffix_separates_widgets(void) {
    float y1 = row_mid(1);
    int a = 0, b = 0;
    ui_input in;

    /* Two buttons that both show "Go", told apart by their suffixes. Press on the second, release on it. */
    in = pointer(60, y1, 1, 1, 0);
    ui_begin(&ui, &in, COL_X, COL_Y, COL_W);
    a = ui_button(&ui, "Go##a");
    b = ui_button(&ui, "Go##b");
    ui_end(&ui);
    CHECK(!a && !b);

    in = pointer(60, y1, 0, 0, 1);
    ui_begin(&ui, &in, COL_X, COL_Y, COL_W);
    a = ui_button(&ui, "Go##a");
    b = ui_button(&ui, "Go##b");
    ui_end(&ui);
    CHECK(!a);
    CHECK(b == 1);
}

static void test_slider_drag(void) {
    float track_x = COL_X + COL_W * 0.4f;
    float track_w = COL_W * 0.6f - ui.theme.pad;
    float y = row_mid(0);
    float value = 0;
    int changed;

    changed = slider_frame(pointer(track_x + 0.75f * track_w, y, 0, 0, 0), "Volume", &value, 0, 10);
    CHECK(!changed && value == 0); /* hover alone changes nothing */

    changed = slider_frame(pointer(track_x + 0.75f * track_w, y, 1, 1, 0), "Volume", &value, 0, 10);
    CHECK(changed && near(value, 7.5f)); /* press at 75% of the track */

    changed = slider_frame(pointer(track_x + track_w + 50, y, 1, 0, 0), "Volume", &value, 0, 10);
    CHECK(changed && value == 10); /* drag past the end: clamped to the top */

    changed = slider_frame(pointer(track_x + track_w + 50, y, 0, 0, 1), "Volume", &value, 0, 10);
    CHECK(!changed && value == 10); /* release: no further change */

    changed = slider_frame(pointer(5, 500, 0, 0, 0), "Volume", &value, 0, 10);
    CHECK(!changed && value == 10); /* far away, nothing is grabbed */
}

static void test_label_hides_suffix(void) {
    int plain, suffixed;
    ui_input in = pointer(0, 0, 0, 0, 0);

    ui_begin(&ui, &in, COL_X, COL_Y, COL_W);
    ui_label(&ui, "Hi");
    plain = ui.list.count;
    ui_end(&ui);

    ui_begin(&ui, &in, COL_X, COL_Y, COL_W);
    ui_label(&ui, "Hi##extra");
    suffixed = ui.list.count;
    ui_end(&ui);

    CHECK(plain > 0);
    CHECK(plain == suffixed); /* the suffix is identity only, never drawn */
}

static void test_rows_stack(void) {
    float row_h = (float)font.line_height + 2 * ui.theme.pad;
    float second_y = COL_Y + row_h + ui.theme.spacing;
    ui_input in = pointer(0, 0, 0, 0, 0);
    int found = 0;
    int i;

    ui_begin(&ui, &in, COL_X, COL_Y, COL_W);
    ui_button(&ui, "A");
    ui_button(&ui, "B");
    ui_end(&ui);

    /* Each button fills the full column width, and the glyph quads are narrower. */
    for (i = 0; i < ui.list.count; i++) {
        if (ui.list.items[i].dst.w == COL_W && near(ui.list.items[i].dst.y, second_y)) found = 1;
    }
    CHECK(found);
}

static void test_overflow_is_counted(void) {
    ui_input in = pointer(0, 0, 0, 0, 0);
    int i;

    ui_begin(&ui, &in, COL_X, COL_Y, COL_W);
    for (i = 0; i < UI_MAX_QUADS + 300; i++) ui_label(&ui, "x");
    ui_end(&ui);

    CHECK(ui.list.count == UI_MAX_QUADS);
    CHECK(ui.list.dropped > 0);
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
    if (ui_font_bake(ttf, len, 12.0f, 32, 95, &font) != 0) {
        fprintf(stderr, "font bake failed\n");
        return 1;
    }
    ui_init(&ui, &font);

    test_button_click();
    test_release_outside_cancels();
    test_suffix_separates_widgets();
    test_slider_drag();
    test_label_hides_suffix();
    test_rows_stack();
    test_overflow_is_counted();

    free(ttf);
    ui_font_destroy(&font);
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("imgui: all checks passed\n");
    return 0;
}
