/*
 * ui_solid_check.c: checks the `solid` flag on UI quads (decision D-04, C side).
 *
 * Solid fills (rectangles) are marked solid; glyphs are not. A fill names no atlas texel, because the backend
 * draws it from its own white texture, and no glyph samples the atlas white texel. Nothing else about a quad changes.
 *
 * Build and run from the repository root (the same gcc line as the other checks):
 *   gcc -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
 *       -Isrc/engine/ui -Isrc/engine/text -Ichecks checks/ui_solid_check.c \
 *       src/engine/text/text.c src/engine/ui/imgui.c -lm -o ui_solid_check
 */
#include <stdio.h>
#include <string.h>

#include "imgui.h"
#include "ui_synthetic_font.h"

static int checks_run = 0;
static int checks_failed = 0;

#define CHECK(cond, name)                                                  \
    do {                                                                   \
        checks_run++;                                                      \
        if (!(cond)) {                                                     \
            checks_failed++;                                               \
            printf("  FAIL: %s (line %d)\n", (name), __LINE__);            \
        }                                                                  \
    } while (0)

static ui_quad_list list;   /* static, because the quad list is large */
static ui_context ui;       /* static, for the same reason */
static ui_font font;

static int same_rect(ui_rect a, ui_rect b) {
    return a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h;
}

static int same_color(ui_color a, ui_color b) {
    return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a;
}

static int is_white_texel(ui_rect r) {
    return r.x == SYN_WHITE_X && r.y == SYN_WHITE_Y && r.w == 2 && r.h == 2;
}

static void reset_list(void) {
    list.count = 0;
    list.dropped = 0;
}

/* The two push helpers mark the flag, and keep every other field. */
static void test_push_helpers(void) {
    ui_rect dst = { 1, 2, 3, 4 };
    ui_rect src = { 5, 6, 7, 8 };
    ui_color col = { 0.1f, 0.2f, 0.3f, 0.4f };
    reset_list();
    ui_quad_push(&list, dst, src, col);
    ui_quad_push_solid(&list, dst, src, col);
    CHECK(list.count == 2, "both pushes land in the list");
    CHECK(list.items[0].solid == 0, "ui_quad_push marks a glyph quad, not a solid fill");
    CHECK(list.items[1].solid == 1, "ui_quad_push_solid marks a solid fill");
    CHECK(same_rect(list.items[0].dst, dst) && same_rect(list.items[0].src, src) &&
              same_color(list.items[0].color, col),
          "ui_quad_push keeps dst, src, and color");
    CHECK(same_rect(list.items[1].dst, dst) && same_rect(list.items[1].src, src) &&
              same_color(list.items[1].color, col),
          "ui_quad_push_solid keeps dst, src, and color");
}

/* Glyph quads from ui_font_draw_text are not solid, and none samples the white block. */
static void test_glyph_quads(void) {
    ui_color col = { 1, 1, 1, 1 };
    int i;
    reset_list();
    ui_font_draw_text(&font, &list, 10, 10, "AB C", 4, col);
    CHECK(list.count == 3, "A, B, and C draw one quad each, and the space draws none");
    for (i = 0; i < list.count; i++) {
        CHECK(list.items[i].solid == 0, "a glyph quad is not solid");
        CHECK(!is_white_texel(list.items[i].src), "a glyph quad does not sample the white block");
    }
}

/* A widget frame: the button fill is solid, the label and button text are glyphs. */
static void test_widget_frame(void) {
    ui_input in;
    int solids = 0, glyphs = 0, i;
    memset(&in, 0, sizeof in);
    ui_init(&ui, &font);
    ui_begin(&ui, &in, 10, 10, 200);
    ui_label(&ui, "Hi");
    (void)ui_button(&ui, "Go");
    ui_end(&ui);

    for (i = 0; i < ui.list.count; i++) {
        const ui_quad *q = &ui.list.items[i];
        if (q->solid) {
            solids++;
            CHECK(!is_white_texel(q->src), "a solid fill does not sample the atlas white texel");
            CHECK(q->src.w == 0 && q->src.h == 0, "a solid fill names no atlas rectangle");
        } else {
            glyphs++;
            CHECK(!is_white_texel(q->src), "a widget glyph does not sample the white block");
        }
    }
    CHECK(solids >= 1, "the button draws at least one solid fill");
    CHECK(glyphs >= 4, "the label and the button text draw glyphs (H, i, G, o)");
    CHECK(ui.list.dropped == 0, "a small frame drops nothing");
}

int main(void) {
    printf("ui_solid_check: solid flag on UI quads (D-04, C side)\n");
    if (syn_load_font(&font) != 0) {
        printf("  FAIL: the synthetic font did not load\n");
        return 1;
    }
    test_push_helpers();
    test_glyph_quads();
    test_widget_frame();
    ui_font_destroy(&font);
    printf("\n%d checks, %d failures\n", checks_run, checks_failed);
    printf(checks_failed == 0 ? "PASSED\n" : "FAILED\n");
    return checks_failed == 0 ? 0 : 1;
}
