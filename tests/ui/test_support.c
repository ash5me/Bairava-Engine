#include "test_support.h"
#include "font_bake.h"

#include <stdio.h>
#include <stdlib.h>

int ui_test_failures;

int ui_test_load_font(const char *path, float pixel_height, int first, int count, ui_font *font) {
    FILE *file = fopen(path, "rb");
    unsigned char *data = NULL;
    long size = 0;
    int result = 0;

    if (file == NULL) {
        fprintf(stderr, "cannot read %s\n", path);
        return 0;
    }
    if (fseek(file, 0, SEEK_END) == 0) size = ftell(file);
    if (size > 0 && fseek(file, 0, SEEK_SET) == 0) {
        data = malloc((size_t)size);
        if (data == NULL || fread(data, 1, (size_t)size, file) != (size_t)size) {
            free(data);
            data = NULL;
        }
    }
    fclose(file);
    if (data == NULL) {
        fprintf(stderr, "cannot read %s\n", path);
        return 0;
    }

    result = ui_font_bake(data, (size_t)size, pixel_height, first, count, font) == 0;
    free(data);
    if (!result) fprintf(stderr, "font bake failed\n");
    return result;
}
