/*
 * ui_draw.h: the draw list that text and widgets write into.
 *
 * A quad says where to draw one rectangle of a texture and how to tint it. It has the same
 * shape as a sprite in src/engine/sprite.zig, so a backend draws each quad as one drawSprite
 * call (see src/engine/ui.zig). Nothing here depends on SDL or the GPU.
 */
#ifndef UI_DRAW_H
#define UI_DRAW_H

/* Quads one frame can hold. Quads past this are counted in `dropped` and not drawn. */
#define UI_MAX_QUADS 4096

typedef struct ui_rect {
    float x, y, w, h;
} ui_rect;

typedef struct ui_color {
    float r, g, b, a;
} ui_color;

typedef struct ui_quad {
    ui_rect dst;    /* where to draw, in pixels from the top-left of the UI */
    ui_rect src;    /* what to draw, in texels of the font atlas */
    ui_color color; /* RGB tints the texel, and alpha multiplies its alpha */
    int sdf;        /* sample alpha as a signed distance field */
} ui_quad;

typedef struct ui_quad_list {
    ui_quad items[UI_MAX_QUADS];
    int count;
    int dropped;
} ui_quad_list;

static inline void ui_quad_push(ui_quad_list *list, ui_rect dst, ui_rect src, ui_color color) {
    ui_quad *q;
    if (list->count == UI_MAX_QUADS) {
        list->dropped++;
        return;
    }
    q = &list->items[list->count++];
    q->dst = dst;
    q->src = src;
    q->color = color;
    q->sdf = 0;
}

#endif
