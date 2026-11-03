/*
 * imgui.h: immediate-mode widgets. Each frame the game calls ui_begin, then the widgets in the
 * order they should appear, then ui_end. Every widget call returns what the player did to it this
 * frame, and appends its quads to ui->list. The only state kept between frames is which widget
 * the pointer is over, which one a press started on, and which keybind row is waiting for a control.
 *
 * Widgets stack downward in one column of the width given to ui_begin. They must not overlap.
 * A label names its widget, so two widgets with the same label share state. To tell duplicates
 * apart, add a suffix: "Volume##music" draws "Volume" and identifies the widget by the whole text.
 * Run the UI in the game's update step so each press is seen once, then draw ui->list.
 */
#ifndef UI_IMGUI_H
#define UI_IMGUI_H

#include "../text/text.h"

/* Pointer and key state for one frame, in the same pixels the UI is drawn in. */
typedef struct ui_input {
    float mouse_x, mouse_y;
    int mouse_down;     /* the button is held */
    int mouse_pressed;  /* the button went down this frame */
    int mouse_released; /* the button came up this frame */
    unsigned control;   /* a control that went down this frame, as a code the caller chose, or 0 for none */
    int cancel;         /* the cancel control went down this frame, which ends a keybind row's wait */
} ui_input;

typedef struct ui_theme {
    ui_color text;
    ui_color button, button_hot, button_active;
    ui_color track, fill, knob;
    float pad;     /* space inside a widget, in pixels */
    float spacing; /* space between widgets, in pixels */
} ui_theme;

typedef struct ui_context {
    ui_font *font;
    ui_theme theme;
    ui_input in;
    unsigned hot;          /* the widget under the pointer, or 0 */
    unsigned active;       /* the widget a press started on, or 0 */
    unsigned listening;    /* the keybind row waiting for a control, or 0 */
    unsigned locked_by;    /* the row that was waiting when this frame began; other widgets take no presses while set */
    int listening_drawn;   /* whether the waiting row was drawn this frame. A row that is not drawn gives up its wait */
    float x, w, cursor_y;  /* the column: left edge, width, and where the next row goes */
    ui_quad_list list;     /* this frame's quads, in draw order */
} ui_context;

void ui_init(ui_context *ui, ui_font *font);
void ui_begin(ui_context *ui, const ui_input *in, float x, float y, float w);
void ui_end(ui_context *ui);
void ui_cancel_listening(ui_context *ui);
void ui_clear(ui_context *ui);

void ui_label(ui_context *ui, const char *text);
int ui_button(ui_context *ui, const char *label);                                    /* 1 on the frame it is clicked */
int ui_slider(ui_context *ui, const char *label, float *value, float lo, float hi);  /* 1 on a frame the value changes */
/* A row that rebinds one control. `value` is the current binding, drawn at the right of the row, and must not be NULL.
 * Clicking the row makes it wait. The next control pressed is returned as its code, and the row stops waiting. The
 * cancel control ends the wait without a change, and so does the row not being drawn for a frame. While a row waits,
 * other widgets neither highlight nor take presses, so the press that binds a control cannot also click something.
 * Returns 0 on every other frame. */
unsigned ui_keybind(ui_context *ui, const char *label, const char *value);

#endif
