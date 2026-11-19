/*
 * ui_quad_dump.c: prints every quad and widget result for a fixed scenario.
 *
 * It prints dst, src, and color, and never the solid flag, so the same program builds against the original
 * upload (which has no flag) and the changed tree. Diffing the two outputs proves that the quads did not change.
 * Floats print as hex, so the comparison is exact.
 *
 *   gcc -std=c99 -Wall -Wextra -Werror -I<tree>/src/engine/ui -I<tree>/src/engine/text -Ichecks \
 *       checks/ui_quad_dump.c <tree>/src/engine/text/text.c <tree>/src/engine/ui/imgui.c -lm -o dump
 */
#include <stdio.h>
#include <string.h>

#include "imgui.h"
#include "ui_synthetic_font.h"

static ui_quad_list list;
static ui_context ui;
static ui_font font;

static float measure_text(void *context, uint64_t font_id, const char *text, size_t len) {
    (void)font_id;
    return ui_font_text_width((ui_font *)context, text, len);
}

static void draw_text(void *context, uint64_t font_id, ui_quad_list *out, float x, float y,
                      const char *text, size_t len, ui_color color) {
    (void)font_id;
    ui_font_draw_text((ui_font *)context, out, x, y, text, len, color);
}

static void dump_list(const char *tag, const ui_quad_list *l) {
    int i;
    printf("%s count=%d dropped=%d\n", tag, l->count, l->dropped);
    for (i = 0; i < l->count; i++) {
        const ui_quad *q = &l->items[i];
        printf("  %2d dst=(%a,%a,%a,%a) src=(%a,%a,%a,%a) color=(%a,%a,%a,%a)\n", i,
               (double)q->dst.x, (double)q->dst.y, (double)q->dst.w, (double)q->dst.h,
               (double)q->src.x, (double)q->src.y, (double)q->src.w, (double)q->src.h,
               (double)q->color.r, (double)q->color.g, (double)q->color.b, (double)q->color.a);
    }
}

int main(void) {
    ui_color white = { 1, 1, 1, 1 };
    ui_color dim = { 0.5f, 0.25f, 0.125f, 0.75f };
    float slider_value = 0.3f;
    ui_input in;
    int clicked, i;

    /* Text, plain and scaled, through the glyph path. */
    if (syn_load_font(&font) != 0) {
        printf("font did not load\n");
        return 1;
    }
    memset(&list, 0, sizeof list);
    ui_font_draw_text(&font, &list, 10.5f, 3, "Hello, World! ?", 15, white);
    ui_font_draw_text_scaled(&font, &list, 4, 20.25f, "scaled 2x", 9, dim, 2.0f);
    dump_list("text", &list);

    /* Widgets over five frames. Rows: label y 10..25, button y 28..43, slider y 46..61 (line height 9, pad 3,
     * spacing 3). Frames 0-2 hover, press, and release the button. Frames 3-4 press and release the slider. */
    ui_init(&ui, (float)font.line_height, &font, 1, measure_text, draw_text);
    for (i = 0; i < 5; i++) {
        int on_button = i < 3;
        memset(&in, 0, sizeof in);
        in.mouse_x = on_button ? 20.0f : 150.0f;
        in.mouse_y = on_button ? 35.0f : 53.0f;
        in.mouse_down = i == 1 || i == 3;
        in.mouse_pressed = i == 1 || i == 3;
        in.mouse_released = i == 2 || i == 4;
        ui_begin(&ui, &in, 10, 10, 200);
        ui_label(&ui, "Settings");
        clicked = ui_button(&ui, "Go");
        (void)ui_slider(&ui, "Volume", &slider_value, 0.0f, 1.0f);
        ui_end(&ui);
        printf("frame %d clicked=%d slider=%a\n", i, clicked, (double)slider_value);
        dump_list("widgets", &ui.list);
    }

    ui_font_destroy(&font);
    return 0;
}
