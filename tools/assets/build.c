/*
 * asset_build: validate manifest entries, copy runtime assets, and emit an asset index.
 *
 * Manifest rows use whitespace-separated fields:
 *   name type source output dependencies
 * Dependencies are comma-separated asset names, or '-'. Paths are project-relative and
 * outputs are relative to the generated asset directory.
 */

#include "../../vendor/stb_image.h"
#include "../../src/engine/ui/text.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <direct.h>
#include <process.h>
#define make_directory(path) _mkdir(path)
#define PATH_SEPARATOR '\\'
#else
#include <unistd.h>
#include <sys/wait.h>
#define make_directory(path) mkdir(path, 0777)
#define PATH_SEPARATOR '/'
#endif

#define MAX_ENTRIES 1024
#define FIELD_SIZE 1024

typedef struct {
    char name[FIELD_SIZE];
    char type[32];
    char source[FIELD_SIZE];
    char output[FIELD_SIZE];
    char dependencies[FIELD_SIZE];
    float font_pixel_height;
    int font_first;
    int font_count;
    int font_sdf;
} entry;

enum { TEX_RGBA8 = 0, TEX_BC1 = 1, TEX_BC3 = 2, TEX_ASTC_4X4 = 3 };

static void write_u32le(unsigned char *out, unsigned int value) {
    out[0] = (unsigned char)value;
    out[1] = (unsigned char)(value >> 8);
    out[2] = (unsigned char)(value >> 16);
    out[3] = (unsigned char)(value >> 24);
}

static void write_u16le(unsigned char *out, unsigned short value) {
    out[0] = (unsigned char)value;
    out[1] = (unsigned char)(value >> 8);
}

static int write_variant(const char *path, unsigned char format, unsigned int width, unsigned int height,
                         const unsigned char *data, size_t data_size) {
    FILE *file = fopen(path, "wb");
    if (file == NULL) return 0;
    unsigned char header[16] = { 'B', 'R', 'T', 'X', format, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    write_u32le(header + 8, width);
    write_u32le(header + 12, height);
    int ok = fwrite(header, 1, sizeof header, file) == sizeof header && fwrite(data, 1, data_size, file) == data_size;
    if (fclose(file) != 0) ok = 0;
    if (!ok) remove(path);
    return ok;
}

static unsigned short pack_565(unsigned char r, unsigned char g, unsigned char b) {
    return (unsigned short)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

static void unpack_565(unsigned short value, unsigned char *color) {
    color[0] = (unsigned char)(((value >> 11) & 31) * 255 / 31);
    color[1] = (unsigned char)(((value >> 5) & 63) * 255 / 63);
    color[2] = (unsigned char)((value & 31) * 255 / 31);
}

static unsigned int color_distance(const unsigned char *a, const unsigned char *b) {
    int r = (int)a[0] - b[0], g = (int)a[1] - b[1], bl = (int)a[2] - b[2];
    return (unsigned int)(r * r + g * g + bl * bl);
}

static void encode_bc1_block(const unsigned char *rgba, unsigned int width, unsigned int height,
                             unsigned int bx, unsigned int by, unsigned char *out, int allow_alpha) {
    unsigned char px[16][4];
    unsigned char lo[3] = { 255, 255, 255 }, hi[3] = { 0, 0, 0 };
    int transparent = 0;
    for (unsigned int y = 0; y < 4; y++) for (unsigned int x = 0; x < 4; x++) {
        unsigned int sx = bx * 4 + x, sy = by * 4 + y;
        if (sx >= width) sx = width - 1;
        if (sy >= height) sy = height - 1;
        unsigned char *p = px[y * 4 + x];
        memcpy(p, rgba + ((size_t)sy * width + sx) * 4, 4);
        if (allow_alpha && p[3] < 128) { transparent = 1; continue; }
        for (unsigned int c = 0; c < 3; c++) { if (p[c] < lo[c]) lo[c] = p[c]; if (p[c] > hi[c]) hi[c] = p[c]; }
    }
    unsigned short c0 = pack_565(hi[0], hi[1], hi[2]);
    unsigned short c1 = pack_565(lo[0], lo[1], lo[2]);
    if ((!transparent && c0 <= c1) || (transparent && c0 > c1)) { unsigned short swap = c0; c0 = c1; c1 = swap; }
    unsigned char palette[4][4] = {{0}};
    unpack_565(c0, palette[0]); unpack_565(c1, palette[1]);
    if (c0 > c1) {
        for (unsigned int c = 0; c < 3; c++) { palette[2][c] = (unsigned char)((2 * palette[0][c] + palette[1][c]) / 3); palette[3][c] = (unsigned char)((palette[0][c] + 2 * palette[1][c]) / 3); }
    } else {
        for (unsigned int c = 0; c < 3; c++) palette[2][c] = (unsigned char)((palette[0][c] + palette[1][c]) / 2);
    }
    out[0] = (unsigned char)c0; out[1] = (unsigned char)(c0 >> 8);
    out[2] = (unsigned char)c1; out[3] = (unsigned char)(c1 >> 8);
    unsigned int indices = 0;
    for (unsigned int i = 0; i < 16; i++) {
        unsigned int best = 0, best_distance = ~0u;
        if (transparent && px[i][3] < 128) best = 3;
        else {
            unsigned int palette_count = c0 > c1 ? 4 : 3;
            for (unsigned int j = 0; j < palette_count; j++) {
                unsigned int d = color_distance(px[i], palette[j]);
                if (d < best_distance) { best_distance = d; best = j; }
            }
        }
        indices |= best << (2 * i);
    }
    out[4] = (unsigned char)indices; out[5] = (unsigned char)(indices >> 8);
    out[6] = (unsigned char)(indices >> 16); out[7] = (unsigned char)(indices >> 24);
}

static void encode_bc3_alpha_block(const unsigned char *rgba, unsigned int width, unsigned int height,
                                   unsigned int bx, unsigned int by, unsigned char *out) {
    unsigned char alpha[16];
    unsigned char hi = 0, lo = 255;
    for (unsigned int y = 0; y < 4; y++) for (unsigned int x = 0; x < 4; x++) {
        unsigned int sx = bx * 4 + x, sy = by * 4 + y;
        if (sx >= width) sx = width - 1;
        if (sy >= height) sy = height - 1;
        unsigned char a = rgba[((size_t)sy * width + sx) * 4 + 3];
        alpha[y * 4 + x] = a;
        if (a > hi) hi = a;
        if (a < lo) lo = a;
    }
    out[0] = hi; out[1] = lo;
    unsigned char palette[8] = { hi, lo };
    if (hi > lo) for (unsigned int i = 1; i <= 6; i++) palette[i + 1] = (unsigned char)(((7 - i) * hi + i * lo) / 7);
    else {
        for (unsigned int i = 1; i <= 4; i++) palette[i + 1] = (unsigned char)(((5 - i) * hi + i * lo) / 5);
        palette[6] = 0; palette[7] = 255;
    }
    unsigned long long indices = 0;
    for (unsigned int i = 0; i < 16; i++) {
        unsigned int best = 0, best_distance = ~0u;
        for (unsigned int j = 0; j < 8; j++) {
            unsigned int d = alpha[i] > palette[j] ? alpha[i] - palette[j] : palette[j] - alpha[i];
            if (d < best_distance) { best_distance = d; best = j; }
        }
        indices |= (unsigned long long)best << (3 * i);
    }
    for (unsigned int i = 0; i < 6; i++) out[2 + i] = (unsigned char)(indices >> (8 * i));
}

static int encode_bc(const unsigned char *rgba, unsigned int width, unsigned int height,
                     const char *output_path, int bc3) {
    unsigned int blocks_x = (width + 3) / 4, blocks_y = (height + 3) / 4;
    size_t block_size = bc3 ? 16 : 8;
    size_t size = (size_t)blocks_x * blocks_y * block_size;
    unsigned char *data = (unsigned char *)malloc(size);
    if (data == NULL) return 0;
    for (unsigned int y = 0; y < blocks_y; y++) for (unsigned int x = 0; x < blocks_x; x++) {
        unsigned char *block = data + ((size_t)y * blocks_x + x) * block_size;
        if (bc3) {
            encode_bc3_alpha_block(rgba, width, height, x, y, block);
            encode_bc1_block(rgba, width, height, x, y, block + 8, 0);
        } else encode_bc1_block(rgba, width, height, x, y, block, 1);
    }
    int ok = write_variant(output_path, bc3 ? TEX_BC3 : TEX_BC1, width, height, data, size);
    free(data);
    return ok;
}

static int run_astcenc(char *const args[]) {
#ifdef _WIN32
    return _spawnvp(_P_WAIT, args[0], (const char * const *)args) == 0;
#else
    pid_t child = fork();
    if (child < 0) return 0;
    if (child == 0) { execvp(args[0], args); _exit(127); }
    int status = 0;
    return waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
#endif
}

static int try_astc(const entry *item, const unsigned char *rgba, unsigned int width, unsigned int height,
                    const char *output_path, const char *output_dir) {
    (void)rgba;
    char temp_path[FIELD_SIZE * 2];
    (void)output_dir;
    if (snprintf(temp_path, sizeof temp_path, "%s-tmp.astc", output_path) >= (int)sizeof temp_path) return 0;
    for (char *p = temp_path; *p; p++) if (*p == '/' || *p == '\\') *p = PATH_SEPARATOR;
    char *args[] = { (char *)"astcenc", (char *)"-cl", (char *)item->source, temp_path, (char *)"4x4", (char *)"-medium", NULL };
    if (!run_astcenc(args)) { remove(temp_path); return 0; }
    FILE *file = fopen(temp_path, "rb");
    if (file == NULL) { remove(temp_path); return 0; }
    unsigned char astc_header[16];
    if (fread(astc_header, 1, sizeof astc_header, file) != sizeof astc_header ||
        astc_header[0] != 0x13 || astc_header[1] != 0xAB || astc_header[2] != 0xA1 || astc_header[3] != 0x5C) {
        fclose(file); remove(temp_path); return 0;
    }
    unsigned int astc_width = astc_header[7] | ((unsigned int)astc_header[8] << 8) | ((unsigned int)astc_header[9] << 16);
    unsigned int astc_height = astc_header[10] | ((unsigned int)astc_header[11] << 8) | ((unsigned int)astc_header[12] << 16);
    if (astc_width != width || astc_height != height) { fclose(file); remove(temp_path); return 0; }
    if (fseek(file, 0, SEEK_END) != 0) { fclose(file); remove(temp_path); return 0; }
    long file_size = ftell(file);
    if (file_size < 16 || fseek(file, 16, SEEK_SET) != 0) { fclose(file); remove(temp_path); return 0; }
    size_t payload_size = (size_t)(file_size - 16);
    unsigned char *payload = (unsigned char *)malloc(payload_size);
    int ok = payload != NULL && fread(payload, 1, payload_size, file) == payload_size;
    fclose(file); remove(temp_path);
    if (ok) ok = write_variant(output_path, TEX_ASTC_4X4, width, height, payload, payload_size);
    free(payload);
    return ok;
}

static int build_texture_variants(const entry *item, const char *output_path, const char *output_dir, int *astc_available) {
    int width = 0, height = 0, channels = 0;
    unsigned char *rgba = stbi_load(item->source, &width, &height, &channels, 4);
    if (rgba == NULL || width <= 0 || height <= 0) {
        fprintf(stderr, "asset_build: cannot decode image '%s': %s\n", item->source, stbi_failure_reason());
        if (rgba != NULL) stbi_image_free(rgba);
        return 0;
    }
    char rgba_path[FIELD_SIZE * 2], bc1_path[FIELD_SIZE * 2], bc3_path[FIELD_SIZE * 2], astc_path[FIELD_SIZE * 2];
    snprintf(rgba_path, sizeof rgba_path, "%s.rgba", output_path);
    snprintf(bc1_path, sizeof bc1_path, "%s.bc1", output_path);
    snprintf(bc3_path, sizeof bc3_path, "%s.bc3", output_path);
    snprintf(astc_path, sizeof astc_path, "%s.astc", output_path);
    size_t rgba_size = (size_t)width * (size_t)height * 4;
    int ok = write_variant(rgba_path, TEX_RGBA8, (unsigned int)width, (unsigned int)height, rgba, rgba_size) &&
             encode_bc(rgba, (unsigned int)width, (unsigned int)height, bc1_path, 0) &&
             encode_bc(rgba, (unsigned int)width, (unsigned int)height, bc3_path, 1);
    if (!ok) fprintf(stderr, "asset_build: failed to encode BC texture variants for '%s'\n", item->name);
    *astc_available = 0;
    if (ok) *astc_available = try_astc(item, rgba, (unsigned int)width, (unsigned int)height, astc_path, output_dir);
    if (!*astc_available) remove(astc_path);
    stbi_image_free(rgba);
    return ok;
}

static int safe_relative_path(const char *path) {
    if (path[0] == '\0' || path[0] == '/' || path[0] == '\\' || strchr(path, ':') != NULL || strchr(path, '\\') != NULL) return 0;
    const char *segment = path;
    for (const char *p = path;; p++) {
        if (*p == '/' || *p == '\0') {
            size_t length = (size_t)(p - segment);
            if (length == 0 || (length == 1 && segment[0] == '.') || (length == 2 && segment[0] == '.' && segment[1] == '.')) return 0;
            if (*p == '\0') break;
            segment = p + 1;
        }
    }
    return 1;
}

static int safe_name(const char *name) {
    if (name[0] == '\0') return 0;
    const unsigned char *segment = (const unsigned char *)name;
    for (const unsigned char *p = segment;; p++) {
        if (*p == '/' || *p == '\0') {
            if (p == segment || !((*segment >= 'a' && *segment <= 'z') || (*segment >= '0' && *segment <= '9'))) return 0;
            if (*p == '\0') break;
            segment = p + 1;
            continue;
        }
        if (!( (*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '_' || *p == '-' || *p == '.')) return 0;
    }
    return strstr(name, "..") == NULL;
}

static int mkdirs(const char *path) {
    char buffer[FIELD_SIZE * 2];
    size_t length = strlen(path);
    if (length == 0 || length >= sizeof buffer) return 0;
    memcpy(buffer, path, length + 1);
    for (char *p = buffer + 1; *p; p++) {
        if (*p == '/' || *p == '\\') {
            char saved = *p;
            *p = '\0';
            if (make_directory(buffer) != 0 && errno != EEXIST) return 0;
            *p = saved;
        }
    }
    return make_directory(buffer) == 0 || errno == EEXIST;
}

static int file_exists(const char *path) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) return 0;
    fclose(file);
    return 1;
}

static int valid_kind(const entry *item) {
    if (strcmp(item->type, "image") == 0) {
        int width = 0, height = 0, channels = 0;
        if (!stbi_info(item->source, &width, &height, &channels) || width <= 0 || height <= 0) {
            fprintf(stderr, "asset_build: invalid image '%s': %s\n", item->source, stbi_failure_reason());
            return 0;
        }
    } else if (strcmp(item->type, "audio") == 0 || strcmp(item->type, "wav") == 0) {
        unsigned char header[12];
        FILE *file = fopen(item->source, "rb");
        if (file == NULL || fread(header, 1, sizeof header, file) != sizeof header || fclose(file) != 0 ||
            memcmp(header, "RIFF", 4) != 0 || memcmp(header + 8, "WAVE", 4) != 0) {
            fprintf(stderr, "asset_build: '%s' is not a readable RIFF/WAVE file\n", item->source);
            return 0;
        }
    } else if (strcmp(item->type, "font") == 0) {
        unsigned char header[4];
        FILE *file = fopen(item->source, "rb");
        if (file == NULL || fread(header, 1, sizeof header, file) != sizeof header || fclose(file) != 0 ||
            !(memcmp(header, "\000\001\000\000", 4) == 0 || memcmp(header, "OTTO", 4) == 0 || memcmp(header, "true", 4) == 0 || memcmp(header, "typ1", 4) == 0)) {
            fprintf(stderr, "asset_build: '%s' is not a supported TrueType/OpenType font\n", item->source);
            return 0;
        }
    } else if (strcmp(item->type, "map") != 0 && strcmp(item->type, "file") != 0) {
        fprintf(stderr, "asset_build: unknown type '%s' for '%s'\n", item->type, item->name);
        return 0;
    }
    return 1;
}

static int build_prebaked_font(const entry *item, const char *output_path) {
    FILE *source = fopen(item->source, "rb");
    if (source == NULL || fseek(source, 0, SEEK_END) != 0) {
        if (source != NULL) fclose(source);
        return 0;
    }
    long ttf_size = ftell(source);
    if (ttf_size <= 0 || fseek(source, 0, SEEK_SET) != 0) { fclose(source); return 0; }
    unsigned char *ttf = (unsigned char *)malloc((size_t)ttf_size);
    if (ttf == NULL) { fclose(source); return 0; }
    int read_ok = fread(ttf, 1, (size_t)ttf_size, source) == (size_t)ttf_size;
    fclose(source);
    if (!read_ok) { free(ttf); return 0; }

    ui_font font;
    int bake_result = item->font_sdf
        ? ui_font_bake_sdf(ttf, (size_t)ttf_size, item->font_pixel_height, item->font_first, item->font_count, 8.0f, &font)
        : ui_font_bake(ttf, (size_t)ttf_size, item->font_pixel_height, item->font_first, item->font_count, &font);
    if (bake_result != 0) {
        fprintf(stderr, "asset_build: could not bake font '%s' at %.2f px\n", item->name, item->font_pixel_height);
        free(ttf);
        return 0;
    }
    free(ttf);
    unsigned int atlas_pixels = (unsigned int)font.atlas_w * (unsigned int)font.atlas_h;
    char prebaked_path[FIELD_SIZE * 2];
    if (snprintf(prebaked_path, sizeof prebaked_path, "%s.bfnt", output_path) >= (int)sizeof prebaked_path) {
        ui_font_destroy(&font); return 0;
    }
    FILE *output = fopen(prebaked_path, "wb");
    if (output == NULL) { ui_font_destroy(&font); return 0; }

    unsigned char header[56] = {0};
    memcpy(header, "BFNT", 4);
    write_u16le(header + 4, font.sdf ? 3 : 2);
    write_u16le(header + 6, font.sdf ? 56 : 52);
    unsigned int pixel_height_bits = 0;
    memcpy(&pixel_height_bits, &font.pixel_height, sizeof pixel_height_bits);
    write_u32le(header + 8, pixel_height_bits);
    write_u32le(header + 12, (unsigned int)font.first);
    write_u32le(header + 16, (unsigned int)font.count);
    write_u32le(header + 20, (unsigned int)font.ascent);
    write_u32le(header + 24, (unsigned int)font.line_height);
    write_u32le(header + 28, (unsigned int)font.atlas_w);
    write_u32le(header + 32, (unsigned int)font.atlas_h);
    write_u32le(header + 36, atlas_pixels);
    write_u16le(header + 40, (unsigned short)font.white.x);
    write_u16le(header + 42, (unsigned short)font.white.y);
    write_u16le(header + 44, (unsigned short)font.white.w);
    write_u16le(header + 46, (unsigned short)font.white.h);
    write_u32le(header + 48, (unsigned int)font.kerning_count);
    write_u32le(header + 52, font.sdf ? 1u : 0u);

    size_t header_size = font.sdf ? 56 : 52;
    int ok = fwrite(header, 1, header_size, output) == header_size;
    for (int i = 0; ok && i < font.count; i++) {
        unsigned char glyph[20];
        const ui_glyph *g = &font.glyphs[i];
        write_u16le(glyph + 0, g->x0); write_u16le(glyph + 2, g->y0);
        write_u16le(glyph + 4, g->x1); write_u16le(glyph + 6, g->y1);
        unsigned int xoff_bits = 0, yoff_bits = 0, advance_bits = 0;
        memcpy(&xoff_bits, &g->xoff, 4); memcpy(&yoff_bits, &g->yoff, 4); memcpy(&advance_bits, &g->xadvance, 4);
        write_u32le(glyph + 8, xoff_bits); write_u32le(glyph + 12, yoff_bits); write_u32le(glyph + 16, advance_bits);
        ok = fwrite(glyph, 1, sizeof glyph, output) == sizeof glyph;
    }
    for (int i = 0; ok && i < font.kerning_count; i++) {
        unsigned char kerning[12];
        unsigned int advance_bits = 0;
        write_u32le(kerning, font.kernings[i].left);
        write_u32le(kerning + 4, font.kernings[i].right);
        memcpy(&advance_bits, &font.kernings[i].advance, 4);
        write_u32le(kerning + 8, advance_bits);
        ok = fwrite(kerning, 1, sizeof kerning, output) == sizeof kerning;
    }
    for (unsigned int i = 0; ok && i < atlas_pixels; i++) ok = fwrite(&font.rgba[(size_t)i * 4 + 3], 1, 1, output) == 1;
    if (fclose(output) != 0) ok = 0;
    if (!ok) { fprintf(stderr, "asset_build: failed to write preprocessed font '%s'\n", prebaked_path); remove(prebaked_path); }
    ui_font_destroy(&font);
    return ok;
}

static int copy_file(const char *source, const char *destination) {
    FILE *input = fopen(source, "rb");
    if (input == NULL) {
        fprintf(stderr, "asset_build: cannot read '%s': %s\n", source, strerror(errno));
        return 0;
    }
    FILE *output = fopen(destination, "wb");
    if (output == NULL) {
        fprintf(stderr, "asset_build: cannot write '%s': %s\n", destination, strerror(errno));
        fclose(input);
        return 0;
    }
    unsigned char buffer[16384];
    size_t count;
    int ok = 1;
    while ((count = fread(buffer, 1, sizeof buffer, input)) != 0) {
        if (fwrite(buffer, 1, count, output) != count) { ok = 0; break; }
    }
    if (ferror(input)) ok = 0;
    if (fclose(input) != 0 || fclose(output) != 0) ok = 0;
    if (!ok) remove(destination);
    return ok;
}

typedef struct {
    unsigned int sample_rate;
    unsigned int channels;
    unsigned int frames;
    short *samples;
} pcm_wav;

static unsigned short read_u16le(const unsigned char *p) {
    return (unsigned short)(p[0] | ((unsigned short)p[1] << 8));
}

static unsigned int read_u32le(const unsigned char *p) {
    return (unsigned int)p[0] | ((unsigned int)p[1] << 8) | ((unsigned int)p[2] << 16) | ((unsigned int)p[3] << 24);
}

static int load_pcm_wav(const char *path, pcm_wav *wav) {
    memset(wav, 0, sizeof *wav);
    FILE *file = fopen(path, "rb");
    if (file == NULL) return 0;
    if (fseek(file, 0, SEEK_END) != 0) { fclose(file); return 0; }
    long file_length = ftell(file);
    if (file_length < 12 || fseek(file, 0, SEEK_SET) != 0) { fclose(file); return 0; }
    size_t size = (size_t)file_length;
    unsigned char *bytes = (unsigned char *)malloc(size);
    if (bytes == NULL) { fclose(file); return 0; }
    int read_ok = fread(bytes, 1, size, file) == size;
    fclose(file);
    if (!read_ok || memcmp(bytes, "RIFF", 4) != 0 || memcmp(bytes + 8, "WAVE", 4) != 0) { free(bytes); return 0; }

    unsigned int channels = 0, sample_rate = 0, block_align = 0, bits = 0, encoding = 0;
    const unsigned char *pcm = NULL;
    size_t pcm_size = 0;
    size_t cursor = 12;
    while (cursor + 8 <= size) {
        const unsigned char *chunk = bytes + cursor;
        unsigned int chunk_size = read_u32le(chunk + 4);
        size_t data_offset = cursor + 8;
        if ((size_t)chunk_size > size - data_offset) { free(bytes); return 0; }
        if (memcmp(chunk, "fmt ", 4) == 0 && chunk_size >= 16) {
            encoding = read_u16le(bytes + data_offset);
            channels = read_u16le(bytes + data_offset + 2);
            sample_rate = read_u32le(bytes + data_offset + 4);
            block_align = read_u16le(bytes + data_offset + 12);
            bits = read_u16le(bytes + data_offset + 14);
        } else if (memcmp(chunk, "data", 4) == 0) {
            pcm = bytes + data_offset;
            pcm_size = chunk_size;
        }
        cursor = data_offset + chunk_size + (chunk_size & 1u);
    }
    if (encoding != 1 || channels == 0 || channels > 2 || sample_rate == 0 ||
        (bits != 8 && bits != 16) || block_align != channels * (bits / 8) ||
        pcm == NULL || pcm_size == 0 || pcm_size % block_align != 0 ||
        pcm_size / block_align > 0xffffffffu) {
        free(bytes); return 0;
    }
    unsigned int frames = (unsigned int)(pcm_size / block_align);
    size_t sample_count = (size_t)frames * channels;
    short *samples = (short *)malloc(sample_count * sizeof *samples);
    if (samples == NULL) { free(bytes); return 0; }
    for (size_t i = 0; i < sample_count; i++) {
        samples[i] = bits == 16 ? (short)read_u16le(pcm + i * 2) : (short)(((int)pcm[i] - 128) << 8);
    }
    free(bytes);
    wav->sample_rate = sample_rate;
    wav->channels = channels;
    wav->frames = frames;
    wav->samples = samples;
    return 1;
}

static const int ima_step_table[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253,
    279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166,
    1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
    4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
};
static const int ima_index_table[16] = { -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8 };

static unsigned char ima_encode_sample(short sample, int *predictor, int *step_index) {
    int step = ima_step_table[*step_index];
    int delta = (int)sample - *predictor;
    unsigned char code = 0;
    if (delta < 0) { code = 8; delta = -delta; }
    int difference = step >> 3;
    if (delta >= step) { code |= 4; delta -= step; difference += step; }
    if (delta >= (step >> 1)) { code |= 2; delta -= step >> 1; difference += step >> 1; }
    if (delta >= (step >> 2)) { code |= 1; difference += step >> 2; }
    *predictor += (code & 8) ? -difference : difference;
    if (*predictor > 32767) *predictor = 32767;
    if (*predictor < -32768) *predictor = -32768;
    *step_index += ima_index_table[code];
    if (*step_index < 0) *step_index = 0;
    if (*step_index > 88) *step_index = 88;
    return code;
}

static int encode_ima_wav(const char *source, const char *destination) {
    pcm_wav wav;
    if (!load_pcm_wav(source, &wav)) {
        fprintf(stderr, "asset_build: '%s' must be uncompressed PCM WAV (8/16-bit, mono/stereo) for IMA encoding\n", source);
        return 0;
    }
    size_t bytes_per_channel = 4 + wav.frames / 2;
    size_t payload_size = bytes_per_channel * wav.channels;
    size_t total_size = 24 + payload_size;
    unsigned char *output = (unsigned char *)calloc(total_size, 1);
    if (output == NULL) { free(wav.samples); return 0; }
    memcpy(output, "BRAD", 4);
    output[4] = 1;
    output[5] = (unsigned char)wav.channels;
    write_u32le(output + 8, wav.sample_rate);
    write_u32le(output + 12, wav.frames);
    write_u32le(output + 16, (unsigned int)payload_size);
    for (unsigned int channel = 0; channel < wav.channels; channel++) {
        size_t channel_offset = 24 + bytes_per_channel * channel;
        int predictor = wav.samples[channel];
        unsigned short predictor_bits = (unsigned short)predictor;
        int step_index = 0;
        output[channel_offset] = (unsigned char)predictor_bits;
        output[channel_offset + 1] = (unsigned char)(predictor_bits >> 8);
        output[channel_offset + 2] = 0;
        for (unsigned int frame = 1; frame < wav.frames; frame++) {
            unsigned char code = ima_encode_sample(wav.samples[(size_t)frame * wav.channels + channel], &predictor, &step_index);
            size_t nibble_index = frame - 1;
            size_t byte_index = channel_offset + 4 + nibble_index / 2;
            if ((nibble_index & 1u) == 0) output[byte_index] = code;
            else output[byte_index] |= (unsigned char)(code << 4);
        }
    }
    FILE *file = fopen(destination, "wb");
    int ok = file != NULL;
    if (ok && fwrite(output, 1, total_size, file) != total_size) ok = 0;
    if (file != NULL && fclose(file) != 0) ok = 0;
    if (!ok) { fprintf(stderr, "asset_build: cannot encode audio to '%s'\n", destination); remove(destination); }
    free(output);
    free(wav.samples);
    return ok;
}

static int dependency_exists(const entry *entries, size_t count, const char *name) {
    for (size_t i = 0; i < count; i++) if (strcmp(entries[i].name, name) == 0) return 1;
    return 0;
}

static int process_manifest(int argc, char **argv, const char *manifest_path, const char *output_dir) {
    FILE *manifest = fopen(manifest_path, "r");
    if (manifest == NULL) { fprintf(stderr, "asset_build: cannot open manifest '%s'\n", manifest_path); return 1; }
    entry *entries = (entry *)calloc(MAX_ENTRIES, sizeof *entries);
    if (entries == NULL) { fclose(manifest); return 1; }
    char line[FIELD_SIZE * 5];
    size_t count = 0, line_number = 0;
    int failed = 0;
    while (fgets(line, sizeof line, manifest) != NULL) {
        line_number++;
        if (line[0] == '#' || line[0] == '\n' || line[0] == '\r') continue;
        entry item = {0};
        char font_height_text[32] = {0}, font_first_text[32] = {0}, font_count_text[32] = {0}, extra[2];
        char font_mode_text[16] = {0};
        int fields = sscanf(line, "%1023s %31s %1023s %1023s %1023s %31s %31s %31s %15s %1s",
                            item.name, item.type, item.source, item.output, item.dependencies,
                            font_height_text, font_first_text, font_count_text, font_mode_text, extra);
        if (fields < 5 || (strcmp(item.type, "font") == 0 ? (fields != 8 && fields != 9) : fields != 5)) {
            fprintf(stderr, "asset_build: %s:%zu: expected five fields, or eight/nine for fonts\n", manifest_path, line_number); failed = 1; break;
        }
        if (strcmp(item.type, "font") == 0) {
            char *end = NULL;
            item.font_pixel_height = strtof(font_height_text, &end);
            if (end == font_height_text || *end != '\0' || !(item.font_pixel_height > 0.0f && item.font_pixel_height <= 4096.0f)) {
                fprintf(stderr, "asset_build: %s:%zu: invalid font pixel height\n", manifest_path, line_number); failed = 1; break;
            }
            long first = strtol(font_first_text, &end, 10);
            if (end == font_first_text || *end != '\0' || first < 0 || first > 0x10ffff) {
                fprintf(stderr, "asset_build: %s:%zu: invalid first font codepoint\n", manifest_path, line_number); failed = 1; break;
            }
            item.font_first = (int)first;
            long glyph_count = strtol(font_count_text, &end, 10);
            if (end == font_count_text || *end != '\0' || glyph_count <= 0 || glyph_count > 65536 || first + glyph_count > 0x110000) {
                fprintf(stderr, "asset_build: %s:%zu: invalid font glyph count\n", manifest_path, line_number); failed = 1; break;
            }
            item.font_count = (int)glyph_count;
            if (fields == 9) {
                if (strcmp(font_mode_text, "sdf") == 0) item.font_sdf = 1;
                else if (strcmp(font_mode_text, "bitmap") != 0) {
                    fprintf(stderr, "asset_build: %s:%zu: font mode must be bitmap or sdf\n", manifest_path, line_number); failed = 1; break;
                }
            }
        }
        if (!safe_name(item.name) || !safe_relative_path(item.source) || !safe_relative_path(item.output) ||
            count == MAX_ENTRIES || !file_exists(item.source) || !valid_kind(&item)) {
            if (!failed) fprintf(stderr, "asset_build: %s:%zu: invalid entry '%s'\n", manifest_path, line_number, item.name);
            failed = 1; break;
        }
        for (size_t i = 0; i < count; i++) {
            if (strcmp(entries[i].name, item.name) == 0 || strcmp(entries[i].output, item.output) == 0) {
                fprintf(stderr, "asset_build: %s:%zu: duplicate name or output\n", manifest_path, line_number); failed = 1; break;
            }
        }
        if (failed) break;
        entries[count++] = item;
    }
    fclose(manifest);
    if (failed) { free(entries); return 1; }
    for (int arg = 3; arg < argc;) {
        if (arg + 4 >= argc || strcmp(argv[arg], "--include-image") != 0 || count == MAX_ENTRIES) {
            fprintf(stderr, "asset_build: expected '--include-image <name> <source> <output> <dependencies>'\n");
            free(entries); return 2;
        }
        entry item = {0};
        snprintf(item.name, sizeof item.name, "%s", argv[arg + 1]);
        snprintf(item.type, sizeof item.type, "image");
        snprintf(item.source, sizeof item.source, "%s", argv[arg + 2]);
        snprintf(item.output, sizeof item.output, "%s", argv[arg + 3]);
        snprintf(item.dependencies, sizeof item.dependencies, "%s", argv[arg + 4]);
        if (!safe_name(item.name) || !safe_relative_path(item.output) || !valid_kind(&item)) {
            fprintf(stderr, "asset_build: invalid generated image '%s'\n", item.name);
            free(entries); return 1;
        }
        for (size_t i = 0; i < count; i++) {
            if (strcmp(entries[i].name, item.name) == 0 || strcmp(entries[i].output, item.output) == 0) {
                fprintf(stderr, "asset_build: duplicate generated image name or output\n"); free(entries); return 1;
            }
        }
        entries[count++] = item;
        arg += 5;
    }
    for (size_t i = 0; i < count; i++) {
        if (strcmp(entries[i].dependencies, "-") == 0) continue;
        char deps[FIELD_SIZE];
        memcpy(deps, entries[i].dependencies, sizeof deps);
        for (char *dep = strtok(deps, ","); dep != NULL; dep = strtok(NULL, ",")) {
            if (!safe_name(dep) || !dependency_exists(entries, count, dep)) {
                fprintf(stderr, "asset_build: '%s' depends on unknown asset '%s'\n", entries[i].name, dep); free(entries); return 1;
            }
        }
    }

    if (!mkdirs(output_dir)) { fprintf(stderr, "asset_build: cannot create output directory '%s'\n", output_dir); free(entries); return 1; }
    char index_path[FIELD_SIZE * 2];
    if (snprintf(index_path, sizeof index_path, "%s%casset-index.txt", output_dir, PATH_SEPARATOR) >= (int)sizeof index_path) { free(entries); return 1; }
    FILE *index = fopen(index_path, "w");
    if (index == NULL) { fprintf(stderr, "asset_build: cannot create '%s'\n", index_path); free(entries); return 1; }
    fprintf(index, "# asset-index-v1\n# name type path source dependencies rgba8 bc1 bc3 astc audio_ima\n");
    for (size_t i = 0; i < count; i++) {
        char relative_output[FIELD_SIZE];
        size_t output_length = strlen(entries[i].output);
        if (output_length >= sizeof relative_output) { failed = 1; break; }
        memcpy(relative_output, entries[i].output, output_length + 1);
        for (char *p = relative_output; *p; p++) if (*p == '/' || *p == '\\') *p = PATH_SEPARATOR;
        char destination[FIELD_SIZE * 2];
        if (snprintf(destination, sizeof destination, "%s%c%s", output_dir, PATH_SEPARATOR, relative_output) >= (int)sizeof destination) { failed = 1; break; }
        char parent[FIELD_SIZE * 2];
        memcpy(parent, destination, strlen(destination) + 1);
        char *slash = strrchr(parent, PATH_SEPARATOR);
        if (slash != NULL) { *slash = '\0'; if (!mkdirs(parent)) { failed = 1; break; } }
        if (!copy_file(entries[i].source, destination)) { failed = 1; break; }
        int astc_available = 0;
        if (strcmp(entries[i].type, "image") == 0 && !build_texture_variants(&entries[i], destination, output_dir, &astc_available)) { failed = 1; break; }
        char ima_path[FIELD_SIZE * 2] = {0};
        if (strcmp(entries[i].type, "audio") == 0) {
            if (snprintf(ima_path, sizeof ima_path, "%s.ima", destination) >= (int)sizeof ima_path || !encode_ima_wav(entries[i].source, ima_path)) { failed = 1; break; }
        }
        char prebaked_font_path[FIELD_SIZE * 2] = {0};
        if (strcmp(entries[i].type, "font") == 0) {
            if (snprintf(prebaked_font_path, sizeof prebaked_font_path, "%s.bfnt", destination) >= (int)sizeof prebaked_font_path || !build_prebaked_font(&entries[i], destination)) { failed = 1; break; }
        }
        const char *source_for_index = safe_relative_path(entries[i].source) ? entries[i].source : "generated";
        fprintf(index, "%s %s %s %s %s", entries[i].name, entries[i].type, entries[i].output, source_for_index, entries[i].dependencies);
        if (strcmp(entries[i].type, "image") == 0) fprintf(index, " %s.rgba %s.bc1 %s.bc3 %s", entries[i].output, entries[i].output, entries[i].output, astc_available ? entries[i].output : "-");
        if (strcmp(entries[i].type, "image") == 0 && astc_available) fprintf(index, ".astc");
        if (strcmp(entries[i].type, "audio") == 0) fprintf(index, " %s.ima", entries[i].output);
        if (strcmp(entries[i].type, "font") == 0) fprintf(index, " %s.bfnt px=%.2f first=%d count=%d", entries[i].output, entries[i].font_pixel_height, entries[i].font_first, entries[i].font_count);
        fputc('\n', index);
    }
    if (fclose(index) != 0) failed = 1;
    free(entries);
    if (failed) { fprintf(stderr, "asset_build: failed to produce runtime assets\n"); return 1; }
    printf("Built %zu assets with index %s\n", count, index_path);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--help") == 0) {
        printf("Usage: asset_build <manifest> <output-directory>\n");
        return 0;
    }
    if (argc < 3) { fprintf(stderr, "Usage: asset_build <manifest> <output-directory> [--include-image <name> <source> <output> <dependencies>]...\n"); return 2; }
    return process_manifest(argc, argv, argv[1], argv[2]);
}
