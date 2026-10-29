/*
 * imgui.c: the widgets. The design follows the pattern from Casey Muratori's immediate-mode
 * notes and from nuklear. Two ids carry state across frames. `hot` is the widget under the
 * pointer, and `active` is the widget a press started on. A press that begins over a hot widget
 * makes it active, and the button coming up ends it.
 */
#include "imgui.h"

#include <string.h>

/* Length of the drawn part of a label: everything before the first "##". */
static size_t shown_len(const char *s, size_t n) {
    size_t i;
    for (i = 0; i + 1 < n; i++) {
        if (s[i] == '#' && s[i + 1] == '#') return i;
    }
    return n;
}

/* FNV-1a over the whole label, suffix included, so "Go##a" and "Go##b" are different widgets.
 * Never 0, because 0 means no widget. */
static unsigned id_for(const char *s, size_t n) {
    unsigned h = 2166136261u;
    size_t i;
    for (i = 0; i < n; i++) {
        h ^= (unsigned char)s[i];
        h *= 16777619u;
    }
    return h ? h : 1;
}

static float clamp01(float t) {
    return t < 0 ? 0 : t > 1 ? 1 : t;
}

static int inside(ui_rect r, float x, float y) {
    return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;
}

static float row_height(const ui_context *ui) {
    return (float)ui->font->line_height + 2 * ui->theme.pad;
}

/* Takes the next row of the column. Rows stack downward with the theme's spacing between them. */
static ui_rect next_row(ui_context *ui, float h) {
    ui_rect r = { ui->x, ui->cursor_y, ui->w, h };
    ui->cursor_y += h + ui->theme.spacing;
    return r;
}

static void fill(ui_context *ui, ui_rect r, ui_color c) {
    ui_quad_push(&ui->list, r, ui->font->white, c);
}

/* The press logic every widget shares. Hover is only claimed while nothing is active, so a widget
 * being pressed keeps the pointer even after the pointer leaves it. Returns 1 while `id` is active. */
static int interact(ui_context *ui, unsigned id, ui_rect r) {
    if (!ui->active && inside(r, ui->in.mouse_x, ui->in.mouse_y)) ui->hot = id;
    if (!ui->active && ui->hot == id && ui->in.mouse_pressed) ui->active = id;
    return ui->active == id;
}

void ui_init(ui_context *ui, ui_font *font) {
    memset(ui, 0, sizeof *ui);
    ui->font = font;
    ui->theme = (ui_theme){
        .text = { 0.95f, 0.95f, 0.95f, 1 },
        .button = { 0.22f, 0.24f, 0.30f, 1 },
        .button_hot = { 0.30f, 0.33f, 0.40f, 1 },
        .button_active = { 0.14f, 0.16f, 0.20f, 1 },
        .track = { 0.15f, 0.15f, 0.18f, 1 },
        .fill = { 0.35f, 0.60f, 0.90f, 1 },
        .knob = { 0.90f, 0.90f, 0.92f, 1 },
        .pad = 3,
        .spacing = 3,
    };
}

void ui_begin(ui_context *ui, const ui_input *in, float x, float y, float w) {
    ui->in = *in;
    ui->x = x;
    ui->w = w;
    ui->cursor_y = y;
    ui->hot = 0;
    ui->list.count = 0;
    ui->list.dropped = 0;
}

void ui_end(ui_context *ui) {
    /* A press lasts until the button comes up, so the next frame starts with nothing active,
     * even if the widget that owned the press was not drawn this frame. */
    if (!ui->in.mouse_down) ui->active = 0;
}

void ui_label(ui_context *ui, const char *text) {
    size_t n = strlen(text);
    ui_rect r = next_row(ui, row_height(ui));
    ui_font_draw_text(ui->font, &ui->list, r.x + ui->theme.pad, r.y + ui->theme.pad, text, shown_len(text, n), ui->theme.text);
}

int ui_button(ui_context *ui, const char *label) {
    size_t n = strlen(label), shown = shown_len(label, n);
    unsigned id = id_for(label, n);
    ui_rect r = next_row(ui, row_height(ui));
    int held = interact(ui, id, r);
    int clicked = held && ui->in.mouse_released && inside(r, ui->in.mouse_x, ui->in.mouse_y);
    ui_color c = ui->active == id ? ui->theme.button_active : ui->hot == id ? ui->theme.button_hot : ui->theme.button;
    float tw = ui_font_text_width(ui->font, label, shown);
    fill(ui, r, c);
    ui_font_draw_text(ui->font, &ui->list, r.x + (r.w - tw) * 0.5f, r.y + ui->theme.pad, label, shown, ui->theme.text);
    return clicked;
}

int ui_slider(ui_context *ui, const char *label, float *value, float lo, float hi) {
    size_t n = strlen(label), shown = shown_len(label, n);
    unsigned id = id_for(label, n);
    float pad = ui->theme.pad;
    ui_rect r = next_row(ui, row_height(ui));
    /* The label takes the left 40% of the row, and the track fills the rest. The hit box runs
     * half a pad past each end of the track, so the knob is easy to grab at either end. */
    ui_rect track = { r.x + r.w * 0.4f, r.y + r.h * 0.5f - 2, r.w * 0.6f - pad, 4 };
    ui_rect hit = { track.x - pad, r.y, track.w + 2 * pad, r.h };
    int changed = 0;
    float t, knob_x;

    if (interact(ui, id, hit) && track.w > 0) {
        float v = lo + clamp01((ui->in.mouse_x - track.x) / track.w) * (hi - lo);
        changed = v != *value;
        *value = v;
    }
    t = hi > lo ? clamp01((*value - lo) / (hi - lo)) : 0;
    knob_x = track.x + track.w * t;
    fill(ui, track, ui->theme.track);
    fill(ui, (ui_rect){ track.x, track.y, track.w * t, track.h }, ui->theme.fill);
    fill(ui, (ui_rect){ knob_x - 2, r.y + pad, 4, r.h - 2 * pad }, ui->active == id ? ui->theme.fill : ui->theme.knob);
    ui_font_draw_text(ui->font, &ui->list, r.x + pad, r.y + pad, label, shown, ui->theme.text);
    return changed;
}
