/*
 * font_bake.h: offline glyph baking, for the asset builder and the UI tests.
 *
 * This is the only code in the project that rasterizes font outlines. The engine never calls it: it
 * loads the BFNT file that the asset builder writes from the result. See docs/text.md.
 */
#ifndef BAIRAVA_FONT_BAKE_H
#define BAIRAVA_FONT_BAKE_H

#include <stddef.h>

#include "../../src/engine/text/text.h"

/* Bakes `count` codepoints from `first` out of font data at `pixel_height` into `font`. Returns 0 on
 * success. The atlas starts at 128 pixels and doubles until every glyph fits, up to 4096. Release the
 * result with ui_font_destroy. */
int ui_font_bake(const unsigned char *ttf, size_t len, float pixel_height, int first, int count, ui_font *font);

#endif
