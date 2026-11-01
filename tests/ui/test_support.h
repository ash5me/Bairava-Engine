#ifndef BAIRAVA_UI_TEST_SUPPORT_H
#define BAIRAVA_UI_TEST_SUPPORT_H

#include "text.h"
#include <stdio.h>

extern int ui_test_failures;

#define CHECK(cond)                                                           \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
            ui_test_failures++;                                               \
        }                                                                     \
    } while (0)

int ui_test_load_font(const char *path, float pixel_height, int first, int count, ui_font *font);

#endif
