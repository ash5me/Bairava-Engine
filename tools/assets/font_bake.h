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

/* How the glyph coverage is rasterized. GRAY is anti-aliased, and is the default. MONO is one-bit and hinted at
 * the real size: every texel is 0 or 255, and the stems and heights land on whole pixels. Use MONO for small UI
 * sizes, where a gray stem narrower than a pixel cannot reach full strength. */
typedef enum ui_font_raster {
    UI_FONT_RASTER_GRAY = 0,
    UI_FONT_RASTER_MONO = 1
} ui_font_raster;

enum { UI_MSDF_MAX_ATLAS_SIZE = 1024 };

typedef enum ui_msdf_bake_result {
    UI_MSDF_BAKE_OK = 0,
    UI_MSDF_BAKE_FAILED = 1,
    UI_MSDF_BAKE_ATLAS_TOO_LARGE = 2
} ui_msdf_bake_result;

#ifdef __cplusplus
extern "C" {
#endif

/* Bakes `count` codepoints from `first` out of font data at `pixel_height` into `font`, in GRAY mode. Returns 0 on
 * success. The atlas starts at 128 pixels and doubles until every glyph fits, up to 4096. Release the result with
 * ui_font_destroy. */
int ui_font_bake(const unsigned char *ttf, size_t len, float pixel_height, int first, int count, ui_font *font);

/* The same bake in the chosen rasterization mode. Returns 0 on success. On failure `font` is left empty. */
int ui_font_bake_mode(const unsigned char *ttf, size_t len, float pixel_height, int first, int count,
                      ui_font_raster raster, ui_font *font);

/* Emits an MFNT v1 asset with a 4-pixel RGB MSDF, matching R8 coverage atlas, glyph plane bounds, and
 * the TrueType source bytes needed for HarfBuzz shaping at runtime. */
int ui_msdf_bake(const unsigned char *font_data, size_t font_size, float pixel_height,
                 unsigned fallback_codepoint, const char *path);

#ifdef __cplusplus
}
#endif

#endif
