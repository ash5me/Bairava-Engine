/*
 * test_imgui.c: drives the widgets with scripted pointer and key input and checks what they report.
 *
 * Run from the project root with `zig build test-ui`.
 */
#include "imgui.h"
#include "test_support.h"

#include <stdio.h>

/* The column every test uses: left edge 10, width 200, top 10. */
#define COL_X 10.0f
#define COL_Y 10.0f
#define COL_W 200.0f
/* A pointer x inside a keybind row's box, which starts 40% of the way across the column. */
#define BOX_X (COL_X + COL_W * 0.7f)

static ui_font font;
static ui_context ui; /* static, because the quad list is large */

static ui_input pointer(float x, float y, int down, int pressed, int released) {
    ui_input in = { .mouse_x = x, .mouse_y = y, .mouse_down = down, .mouse_pressed = pressed, .mouse_released = released };
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

/* A frame with no pointer, where one control went down (0 for none) and the cancel control may have. */
static ui_input keyed(unsigned control, int cancel) {
    ui_input in = pointer(-100, -100, 0, 0, 0);
    in.control = control;
    in.cancel = cancel;
    return in;
}

static unsigned keybind_frame(ui_input in, const char *label, const char *value) {
    unsigned code;
    ui_begin(&ui, &in, COL_X, COL_Y, COL_W);
    code = ui_keybind(&ui, label, value);
    ui_end(&ui);
    return code;
}

/* Clicks the row at the top of the column, which leaves it waiting for a control. */
static void start_listening(const char *label) {
    float y = row_mid(0);
    keybind_frame(pointer(BOX_X, y, 1, 1, 0), label, "left");
    keybind_frame(pointer(BOX_X, y, 0, 0, 1), label, "left");
}

static unsigned keybind_and_button(ui_input in, int *clicked) {
    unsigned code;
    ui_begin(&ui, &in, COL_X, COL_Y, COL_W);
    code = ui_keybind(&ui, "move_left", "left");
    *clicked = ui_button(&ui, "Go");
    ui_end(&ui);
    return code;
}

static void test_keybind_click_then_bind(void) {
    float y = row_mid(0);

    CHECK(keybind_frame(pointer(BOX_X, y, 0, 0, 0), "move_left", "left") == 0); /* hover alone starts nothing */
    CHECK(keybind_frame(pointer(BOX_X, y, 1, 1, 0), "move_left", "left") == 0); /* press on the box */
    CHECK(keybind_frame(pointer(BOX_X, y, 0, 0, 1), "move_left", "left") == 0); /* release on it: the row waits */
    CHECK(ui.listening != 0);

    CHECK(keybind_frame(keyed(7, 0), "move_left", "left") == 7); /* the next control is the new binding */
    CHECK(ui.listening == 0);                                    /* and the row stops waiting */
    CHECK(keybind_frame(keyed(9, 0), "move_left", "left") == 0); /* idle again, so a later control changes nothing */
}

static void test_keybind_escape_cancels(void) {
    CHECK(keybind_frame(keyed(5, 0), "move_left", "left") == 0); /* idle: a control does nothing */
    CHECK(ui.listening == 0);

    start_listening("move_left");
    CHECK(ui.listening != 0);
    CHECK(keybind_frame(keyed(3, 1), "move_left", "left") == 0); /* cancel ends the wait, and binds nothing */
    CHECK(ui.listening == 0);
    CHECK(keybind_frame(keyed(3, 0), "move_left", "left") == 0);
}

static void test_keybind_locks_other_widgets(void) {
    float y1 = row_mid(1);
    int clicked = 0;

    start_listening("move_left");
    CHECK(ui.listening != 0);

    /* A press and release on the button while the row waits: the button must not click. */
    keybind_and_button(pointer(60, y1, 1, 1, 0), &clicked);
    CHECK(!clicked);
    keybind_and_button(pointer(60, y1, 0, 0, 1), &clicked);
    CHECK(!clicked);
    CHECK(ui.listening != 0); /* and the stray click did not end the wait */

    CHECK(keybind_and_button(keyed(5, 0), &clicked) == 5);
    CHECK(ui.listening == 0);

    /* Once nothing waits, the button clicks as usual. */
    keybind_and_button(pointer(60, y1, 1, 1, 0), &clicked);
    CHECK(!clicked);
    keybind_and_button(pointer(60, y1, 0, 0, 1), &clicked);
    CHECK(clicked);
}

/* The press that binds a control lands on the row itself. Its release must not start the row waiting again. */
static void test_keybind_bind_on_press_does_not_restart(void) {
    float y = row_mid(0);
    ui_input press = pointer(BOX_X, y, 1, 1, 0);

    start_listening("move_left");
    press.control = 8; /* a control pressed on the waiting row binds it */
    CHECK(keybind_frame(press, "move_left", "left") == 8);
    CHECK(ui.listening == 0);
    CHECK(keybind_frame(pointer(BOX_X, y, 1, 0, 0), "move_left", "left") == 0); /* hold */
    CHECK(keybind_frame(pointer(BOX_X, y, 0, 0, 1), "move_left", "left") == 0); /* release on the row */
    CHECK(ui.listening == 0);                                                   /* and that release starts no new wait */
}

static void test_keybind_release_away_does_not_wait(void) {
    float y = row_mid(0);

    CHECK(keybind_frame(pointer(BOX_X, y, 1, 1, 0), "move_left", "left") == 0); /* press on the box */
    CHECK(keybind_frame(pointer(5, 500, 0, 0, 1), "move_left", "left") == 0);   /* release well away from it */
    CHECK(ui.listening == 0);
}

static void test_keybind_gives_up_when_not_drawn(void) {
    ui_input in = pointer(0, 0, 0, 0, 0);

    start_listening("move_left");
    CHECK(ui.listening != 0);

    ui_begin(&ui, &in, COL_X, COL_Y, COL_W);
    ui_end(&ui); /* a frame without the row */
    CHECK(ui.listening == 0);
    CHECK(keybind_frame(keyed(4, 0), "move_left", "left") == 0);
}

static void test_keybind_lit_while_waiting(void) {
    ui_input idle = pointer(0, 0, 0, 0, 0);

    keybind_frame(idle, "move_left", "left");
    CHECK(ui.list.count > 0);
    CHECK(ui.list.items[0].color.r == ui.theme.button.r); /* idle: the plain button color */

    start_listening("move_left");
    keybind_frame(idle, "move_left", "left");
    CHECK(ui.list.items[0].color.r == ui.theme.button_active.r); /* waiting: the active color, so it reads as armed */
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s font.ttf\n", argv[0]);
        return 2;
    }
    if (!ui_test_load_font(argv[1], 12.0f, 32, 95, &font)) {
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
    test_keybind_click_then_bind();
    test_keybind_escape_cancels();
    test_keybind_locks_other_widgets();
    test_keybind_bind_on_press_does_not_restart();
    test_keybind_release_away_does_not_wait();
    test_keybind_gives_up_when_not_drawn();
    test_keybind_lit_while_waiting();

    ui_font_destroy(&font);
    if (ui_test_failures) {
        fprintf(stderr, "%d check(s) failed\n", ui_test_failures);
        return 1;
    }
    printf("imgui: all checks passed\n");
    return 0;
}
