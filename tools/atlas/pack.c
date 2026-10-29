/*
 * atlas_pack: packs sprite images into one texture atlas with stb_rect_pack.
 *
 * build.zig runs this at build time. It writes two files that the game reads at startup:
 *   atlas.png  the packed sprites, RGBA, with transparent space between them
 *   atlas.txt  where each sprite sits in atlas.png, read by src/engine/atlas.zig
 *
 * Usage:
 *   atlas_pack <out.png> <out.txt> <name> <input.png> [<name> <input.png> ...]
 *
 * The index has a size line, then one line per sprite, in argument order:
 *   size <width> <height>
 *   <name> <x> <y> <w> <h>
 * The rectangle is the sprite's own pixels, in texels from the top-left corner. The padding
 * around it is not part of the rectangle.
 */

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#define STB_RECT_PACK_IMPLEMENTATION
#include "stb_rect_pack.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Transparent texels around each sprite. Nearest-neighbor sampling at a sprite's edge then reads
 * this padding and not a neighboring sprite's pixels. */
#define PADDING 1

/* The atlas is a square whose side is a power of two. The packer tries the smallest side first
 * and doubles it until every sprite fits. */
#define MIN_SIDE 64
#define MAX_SIDE 4096

typedef struct {
    const char *name;
    unsigned char *pixels; /* RGBA8 from stbi_load, row 0 at the top */
    int w, h;              /* size of the sprite's own pixels */
    int x, y;              /* top-left corner in the atlas, set after packing */
} Sprite;

static void die(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    fprintf(stderr, "atlas_pack: ");
    vfprintf(stderr, fmt, args);
    fprintf(stderr, "\n");
    va_end(args);
    exit(1);
}

static void *xcalloc(size_t count, size_t size) {
    void *memory = calloc(count, size);
    if (!memory) die("out of memory");
    return memory;
}

int main(int argc, char **argv) {
    if (argc < 4 || (argc - 3) % 2 != 0) {
        fprintf(stderr, "usage: %s <out.png> <out.txt> <name> <input.png> [<name> <input.png> ...]\n", argv[0]);
        return 2;
    }
    const char *out_png = argv[1];
    const char *out_txt = argv[2];
    int count = (argc - 3) / 2;

    Sprite *sprites = xcalloc((size_t)count, sizeof *sprites);
    stbrp_rect *rects = xcalloc((size_t)count, sizeof *rects);

    /* Load every sprite and make its padded rectangle. The rectangle's id is its index in
     * `sprites`, which lets the output loop find the sprite after the packer reorders rects. */
    for (int i = 0; i < count; i++) {
        const char *name = argv[3 + 2 * i];
        const char *path = argv[4 + 2 * i];
        if (name[0] == '\0' || strpbrk(name, " \t\r\n") != NULL) die("bad sprite name '%s'", name);
        for (int j = 0; j < i; j++) {
            if (strcmp(sprites[j].name, name) == 0) die("sprite name '%s' is listed twice", name);
        }

        int channels = 0;
        sprites[i].name = name;
        sprites[i].pixels = stbi_load(path, &sprites[i].w, &sprites[i].h, &channels, 4);
        if (!sprites[i].pixels) die("could not read '%s': %s", path, stbi_failure_reason());

        rects[i].id = i;
        rects[i].w = (stbrp_coord)(sprites[i].w + 2 * PADDING);
        rects[i].h = (stbrp_coord)(sprites[i].h + 2 * PADDING);
        if (sprites[i].w + 2 * PADDING > MAX_SIDE || sprites[i].h + 2 * PADDING > MAX_SIDE) {
            die("'%s' is larger than the %dx%d atlas", path, MAX_SIDE, MAX_SIDE);
        }
    }

    /* Pack into the smallest square that holds everything. Each attempt starts from an empty atlas. */
    stbrp_node *nodes = xcalloc(MAX_SIDE, sizeof *nodes);
    stbrp_context context;
    int side = MIN_SIDE;
    for (;;) {
        stbrp_init_target(&context, side, side, nodes, side);
        if (stbrp_pack_rects(&context, rects, count)) break;
        if (side >= MAX_SIDE) die("the sprites do not fit in a %dx%d atlas", MAX_SIDE, MAX_SIDE);
        side *= 2;
    }

    /* Copy each sprite's pixels to its place. The atlas starts zeroed, so the space between sprites
     * is fully transparent. */
    unsigned char *atlas = xcalloc((size_t)side * (size_t)side, 4);
    for (int i = 0; i < count; i++) {
        const stbrp_rect *rect = &rects[i];
        Sprite *sprite = &sprites[rect->id];
        sprite->x = rect->x + PADDING;
        sprite->y = rect->y + PADDING;
        for (int row = 0; row < sprite->h; row++) {
            unsigned char *dst = atlas + ((size_t)(sprite->y + row) * (size_t)side + (size_t)sprite->x) * 4;
            memcpy(dst, sprite->pixels + (size_t)row * (size_t)sprite->w * 4, (size_t)sprite->w * 4);
        }
    }

    if (!stbi_write_png(out_png, side, side, 4, atlas, side * 4)) die("could not write '%s'", out_png);

    FILE *index = fopen(out_txt, "w");
    if (!index) die("could not open '%s' for writing", out_txt);
    fprintf(index, "size %d %d\n", side, side);
    for (int i = 0; i < count; i++) {
        fprintf(index, "%s %d %d %d %d\n", sprites[i].name, sprites[i].x, sprites[i].y, sprites[i].w, sprites[i].h);
    }
    if (fclose(index) != 0) die("could not write '%s'", out_txt);

    for (int i = 0; i < count; i++) stbi_image_free(sprites[i].pixels);
    free(atlas);
    free(nodes);
    free(rects);
    free(sprites);
    return 0;
}
