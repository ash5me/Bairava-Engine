/*
 * asset_keyer: make a checkerboard background transparent in an image.
 *
 * The two most common near-gray colors in the configured brightness range are treated as the
 * checkerboard. A four-connected flood fill starts at the image border, so matching colors inside
 * enclosed parts of the artwork remain opaque.
 *
 * Usage:
 *   asset_keyer <input-image> <output.png> [--tolerance N] [--chroma N]
 *               [--min-brightness N] [--max-brightness N]
 */

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../../vendor/stb_image_write.h"

#include "../../vendor/stb_image.h"

#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define HISTOGRAM_INITIAL_CAPACITY 1024

typedef struct {
    uint32_t rgb_plus_one;
    size_t count;
} ColorCount;

typedef struct {
    int tolerance;
    int max_chroma;
    int min_brightness;
    int max_brightness;
} Options;

static void usage(FILE *stream, const char *program) {
    fprintf(stream,
        "Usage: %s <input-image> <output.png> [options]\n"
        "\n"
        "Remove a checkerboard background by finding its two most common near-gray colors,\n"
        "then clearing matching pixels connected to the image border.\n"
        "\n"
        "Options (defaults shown):\n"
        "  --tolerance N       per-channel match tolerance (6)\n"
        "  --chroma N          maximum RGB spread for gray colors (6)\n"
        "  --min-brightness N  minimum average RGB brightness (90)\n"
        "  --max-brightness N  maximum average RGB brightness (235)\n"
        "  --help              show this help\n",
        program);
}

static int parse_range(const char *text, int min_value, int max_value, int *out) {
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < min_value || value > max_value) {
        return 0;
    }
    *out = (int)value;
    return 1;
}

static int parse_options(int argc, char **argv, Options *options) {
    *options = (Options){
        .tolerance = 6,
        .max_chroma = 6,
        .min_brightness = 90,
        .max_brightness = 235,
    };

    for (int i = 3; i < argc; i++) {
        int *destination = NULL;
        int minimum = 0;
        int maximum = 255;
        if (strcmp(argv[i], "--tolerance") == 0) {
            destination = &options->tolerance;
        } else if (strcmp(argv[i], "--chroma") == 0) {
            destination = &options->max_chroma;
        } else if (strcmp(argv[i], "--min-brightness") == 0) {
            destination = &options->min_brightness;
        } else if (strcmp(argv[i], "--max-brightness") == 0) {
            destination = &options->max_brightness;
        } else {
            fprintf(stderr, "asset_keyer: unknown option '%s'\n", argv[i]);
            return 0;
        }

        const char *option = argv[i];
        if (i + 1 >= argc) {
            fprintf(stderr, "asset_keyer: missing value for '%s'\n", option);
            return 0;
        }
        if (!parse_range(argv[++i], minimum, maximum, destination)) {
            fprintf(stderr, "asset_keyer: invalid value for '%s'\n", option);
            return 0;
        }
    }

    if (options->min_brightness > options->max_brightness) {
        fprintf(stderr, "asset_keyer: minimum brightness exceeds maximum brightness\n");
        return 0;
    }
    return 1;
}

static uint32_t rgb_key(const unsigned char *pixel) {
    return ((uint32_t)pixel[0] << 16) | ((uint32_t)pixel[1] << 8) | pixel[2];
}

static int is_gray_in_range(const unsigned char *pixel, const Options *options) {
    int red = pixel[0];
    int green = pixel[1];
    int blue = pixel[2];
    int maximum = red > green ? red : green;
    int minimum = red < green ? red : green;
    if (blue > maximum) maximum = blue;
    if (blue < minimum) minimum = blue;
    int brightness = (red + green + blue) / 3;
    return maximum - minimum <= options->max_chroma &&
        brightness >= options->min_brightness && brightness <= options->max_brightness;
}

static uint32_t hash_rgb(uint32_t value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    value ^= value >> 16;
    return value;
}

static ColorCount *find_color(ColorCount *table, size_t capacity, uint32_t rgb) {
    uint32_t key = rgb + 1;
    size_t slot = hash_rgb(rgb) & (capacity - 1);
    for (size_t probe = 0; probe < capacity; probe++) {
        ColorCount *entry = &table[slot];
        if (entry->rgb_plus_one == key || entry->rgb_plus_one == 0) return entry;
        slot = (slot + 1) & (capacity - 1);
    }
    return NULL;
}

static int grow_histogram(ColorCount **table, size_t *capacity) {
    if (*capacity > SIZE_MAX / 2 || *capacity * 2 > SIZE_MAX / sizeof **table) return 0;
    size_t new_capacity = *capacity * 2;
    ColorCount *grown = (ColorCount *)calloc(new_capacity, sizeof *grown);
    if (grown == NULL) return 0;

    for (size_t i = 0; i < *capacity; i++) {
        ColorCount old = (*table)[i];
        if (old.rgb_plus_one == 0) continue;
        ColorCount *slot = find_color(grown, new_capacity, old.rgb_plus_one - 1);
        if (slot == NULL) {
            free(grown);
            return 0;
        }
        *slot = old;
    }
    free(*table);
    *table = grown;
    *capacity = new_capacity;
    return 1;
}

static int same_checker_color(const unsigned char *pixel, uint32_t first, uint32_t second, int tolerance) {
    const uint32_t targets[2] = { first, second };
    for (size_t i = 0; i < 2; i++) {
        int red_delta = (int)pixel[0] - (int)((targets[i] >> 16) & 0xff);
        int green_delta = (int)pixel[1] - (int)((targets[i] >> 8) & 0xff);
        int blue_delta = (int)pixel[2] - (int)(targets[i] & 0xff);
        if (abs(red_delta) <= tolerance && abs(green_delta) <= tolerance && abs(blue_delta) <= tolerance) {
            return 1;
        }
    }
    return 0;
}

static int key_checkerboard(unsigned char *pixels, int width, int height, const Options *options,
                            uint32_t *first_color, uint32_t *second_color, size_t *removed) {
    size_t pixel_count = (size_t)width * (size_t)height;
    size_t histogram_capacity = HISTOGRAM_INITIAL_CAPACITY;
    ColorCount *histogram = (ColorCount *)calloc(histogram_capacity, sizeof *histogram);
    if (histogram == NULL) {
        fprintf(stderr, "asset_keyer: could not allocate color histogram\n");
        return 0;
    }

    size_t unique = 0;
    for (size_t i = 0; i < pixel_count; i++) {
        unsigned char *pixel = pixels + i * 4;
        if (!is_gray_in_range(pixel, options)) continue;
        uint32_t key = rgb_key(pixel);
        ColorCount *entry = find_color(histogram, histogram_capacity, key);
        if (entry != NULL && entry->rgb_plus_one == 0 && unique + 1 > histogram_capacity - histogram_capacity / 3) {
            if (!grow_histogram(&histogram, &histogram_capacity)) {
                fprintf(stderr, "asset_keyer: could not grow color histogram\n");
                free(histogram);
                return 0;
            }
            entry = find_color(histogram, histogram_capacity, key);
        }
        if (entry == NULL) {
            fprintf(stderr, "asset_keyer: could not insert color into histogram\n");
            free(histogram);
            return 0;
        }
        if (entry->rgb_plus_one == 0) {
            entry->rgb_plus_one = key + 1;
            unique++;
        }
        entry->count++;
    }

    size_t best_count = 0;
    size_t next_count = 0;
    *first_color = 0;
    *second_color = 0;
    for (size_t i = 0; i < histogram_capacity; i++) {
        if (histogram[i].rgb_plus_one == 0) continue;
        uint32_t color = histogram[i].rgb_plus_one - 1;
        if (histogram[i].count > best_count) {
            next_count = best_count;
            *second_color = *first_color;
            best_count = histogram[i].count;
            *first_color = color;
        } else if (histogram[i].count > next_count) {
            next_count = histogram[i].count;
            *second_color = color;
        }
    }
    free(histogram);

    if (unique < 2) {
        fprintf(stderr, "asset_keyer: found fewer than two gray checker colors in the brightness range\n");
        return 0;
    }

    unsigned char *visited = (unsigned char *)calloc(pixel_count, sizeof *visited);
    if (visited == NULL || pixel_count > SIZE_MAX / sizeof(size_t)) {
        fprintf(stderr, "asset_keyer: could not allocate flood-fill workspace\n");
        free(visited);
        return 0;
    }
    size_t *queue = (size_t *)malloc(pixel_count * sizeof *queue);
    if (queue == NULL) {
        fprintf(stderr, "asset_keyer: could not allocate flood-fill queue\n");
        free(visited);
        return 0;
    }

    size_t head = 0;
    size_t tail = 0;
#define ADD_SEED(index) do { \
    size_t seed_index = (index); \
    if (!visited[seed_index] && same_checker_color(pixels + seed_index * 4, *first_color, *second_color, options->tolerance)) { \
        visited[seed_index] = 1; \
        queue[tail++] = seed_index; \
    } \
} while (0)

    for (int x = 0; x < width; x++) {
        ADD_SEED((size_t)x);
        ADD_SEED((size_t)(height - 1) * (size_t)width + (size_t)x);
    }
    for (int y = 0; y < height; y++) {
        ADD_SEED((size_t)y * (size_t)width);
        ADD_SEED((size_t)y * (size_t)width + (size_t)(width - 1));
    }
#undef ADD_SEED

    *removed = 0;
    while (head < tail) {
        size_t index = queue[head++];
        unsigned char *pixel = pixels + index * 4;
        pixel[3] = 0;
        (*removed)++;

        size_t neighbors[4];
        size_t neighbor_count = 0;
        size_t x = index % (size_t)width;
        size_t y = index / (size_t)width;
        if (x > 0) neighbors[neighbor_count++] = index - 1;
        if (x + 1 < (size_t)width) neighbors[neighbor_count++] = index + 1;
        if (y > 0) neighbors[neighbor_count++] = index - (size_t)width;
        if (y + 1 < (size_t)height) neighbors[neighbor_count++] = index + (size_t)width;

        for (size_t n = 0; n < neighbor_count; n++) {
            size_t neighbor = neighbors[n];
            if (visited[neighbor]) continue;
            if (!same_checker_color(pixels + neighbor * 4, *first_color, *second_color, options->tolerance)) continue;
            visited[neighbor] = 1;
            queue[tail++] = neighbor;
        }
    }

    free(queue);
    free(visited);
    return 1;
}

static void print_rgb(uint32_t color, char out[8]) {
    snprintf(out, 8, "#%06X", color);
}

static int paths_identify_same_file(const char *first, const char *second) {
    struct stat first_info;
    struct stat second_info;
    if (strcmp(first, second) == 0) return 1;
    if (stat(first, &first_info) != 0 || stat(second, &second_info) != 0) return 0;
    return first_info.st_dev == second_info.st_dev && first_info.st_ino == second_info.st_ino;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--help") == 0) {
        usage(stdout, argv[0]);
        return 0;
    }
    if (argc < 3) {
        usage(stderr, argv[0]);
        return 2;
    }
    if (paths_identify_same_file(argv[1], argv[2])) {
        fprintf(stderr, "asset_keyer: input and output paths must be different\n");
        return 2;
    }

    Options options;
    if (!parse_options(argc, argv, &options)) {
        usage(stderr, argv[0]);
        return 2;
    }

    int width = 0, height = 0, channels = 0;
    unsigned char *pixels = stbi_load(argv[1], &width, &height, &channels, 4);
    if (pixels == NULL) {
        fprintf(stderr, "asset_keyer: could not read '%s': %s\n", argv[1], stbi_failure_reason());
        return 1;
    }
    if (width <= 0 || height <= 0 || width > INT_MAX / 4 || (size_t)width > SIZE_MAX / (size_t)height ||
        (size_t)width * (size_t)height > SIZE_MAX / 4) {
        fprintf(stderr, "asset_keyer: image dimensions are too large\n");
        stbi_image_free(pixels);
        return 1;
    }

    uint32_t first_color, second_color;
    size_t removed;
    if (!key_checkerboard(pixels, width, height, &options, &first_color, &second_color, &removed)) {
        stbi_image_free(pixels);
        return 1;
    }

    if (!stbi_write_png(argv[2], width, height, 4, pixels, width * 4)) {
        fprintf(stderr, "asset_keyer: could not write '%s'\n", argv[2]);
        stbi_image_free(pixels);
        return 1;
    }

    char first_text[8], second_text[8];
    print_rgb(first_color, first_text);
    print_rgb(second_color, second_text);
    printf("Size %dx%d. Checker colors %s and %s. Keyed out %zu pixels. Saved %s\n",
        width, height, first_text, second_text, removed, argv[2]);
    stbi_image_free(pixels);
    return 0;
}
