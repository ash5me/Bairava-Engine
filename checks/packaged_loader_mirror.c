/*
 * Mirror of src/engine/text/runtime_font.zig after the packaged-loader wiring (Phase 2, 2026-11-17).
 *
 * This is NOT the Zig code, and it does not show that the Zig compiles. The Zig is compiled and tested
 * only by `zig build test`. This harness re-runs, in C, the parts that can be wrong in logic alone:
 *
 *   - which check runs first (the pixel height is checked before the reader is called),
 *   - who frees the file bytes on each error path (exactly once, and never twice),
 *   - how the reader's error names map onto the face's error names,
 *   - the format rules (TrueType glyf only), and
 *   - the HarfBuzz scale conversion, and that the new pixel-height bound keeps it inside a C int.
 *
 * It runs under AddressSanitizer and UBSan, and it counts live allocations, so a double free or a
 * leaked buffer fails the run. It also reads the shipped assets/font.ttf directly and checks the
 * metrics that the Zig tests pin (upem 2048, ascent 1854, descent -434, 4652 glyphs).
 *
 * Build from the repository root:
 *   gcc -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
 *       checks/packaged_loader_mirror.c -lm -o packaged_loader_mirror
 * Run:
 *   ./packaged_loader_mirror
 */

#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_PIXEL_HEIGHT 4096.0f

/* The face's error names (runtime_font.zig Error and LoadError). */
typedef enum {
    OK = 0,
    E_INVALID_FONT,
    E_UNSUPPORTED_FORMAT,
    E_INVALID_PIXEL_HEIGHT,
    E_FILE_NOT_FOUND,
    E_READ_FAILED,
    E_PATH_TOO_LONG,
    E_OUT_OF_MEMORY
} err_t;

/* The reader's error names (staging.ReadError). */
typedef enum {
    R_OK = 0,
    R_NOT_FOUND,
    R_READ_FAILED,
    R_PATH_TOO_LONG,
    R_OUT_OF_MEMORY
} reader_err_t;

static const char *err_name(err_t e) {
    switch (e) {
        case OK: return "OK";
        case E_INVALID_FONT: return "InvalidFont";
        case E_UNSUPPORTED_FORMAT: return "UnsupportedFontFormat";
        case E_INVALID_PIXEL_HEIGHT: return "InvalidPixelHeight";
        case E_FILE_NOT_FOUND: return "FileNotFound";
        case E_READ_FAILED: return "ReadFailed";
        case E_PATH_TOO_LONG: return "PathTooLong";
        case E_OUT_OF_MEMORY: return "OutOfMemory";
    }
    return "?";
}

/* ---- counted allocation: every buffer the mirror owns goes through these ---- */

static long live_allocations = 0;

static void *c_alloc(size_t n) {
    void *p = malloc(n);
    if (p != NULL) live_allocations++;
    return p;
}

static void c_free(void *p) {
    if (p != NULL) {
        live_allocations--;
        free(p);
    }
}

/* ---- the checks ---- */

static int failures = 0;

#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        if (cond) {                                                          \
            printf("ok:   %s\n", msg);                                       \
        } else {                                                             \
            printf("FAIL: %s  (line %d)\n", msg, __LINE__);                  \
            failures++;                                                      \
        }                                                                    \
    } while (0)

/* Mirror of checkPixelHeight: 0 < px <= max. NaN fails the first test, and infinity the second. */
static err_t check_pixel_height(float px) {
    if (!(px > 0.0f && px <= MAX_PIXEL_HEIGHT)) return E_INVALID_PIXEL_HEIGHT;
    return OK;
}

static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint16_t be16(const uint8_t *p) {
    return (uint16_t)(((uint32_t)p[0] << 8) | (uint32_t)p[1]);
}

/* Mirror of checkFormat: TrueType glyf only. Every other input is rejected before any parser runs. */
static err_t check_format(const uint8_t *b, size_t len) {
    if (len < 12) return E_INVALID_FONT;
    switch (be32(b)) {
        case 0x00010000u:
        case 0x74727565u: /* 'true' */
            break;
        case 0x4F54544Fu: /* 'OTTO' (CFF) */
        case 0x74746366u: /* 'ttcf' (collection) */
            return E_UNSUPPORTED_FORMAT;
        default:
            return E_INVALID_FONT;
    }
    size_t num_tables = be16(b + 4);
    if (len < 12 + 16 * num_tables) return E_INVALID_FONT;
    int has_glyf = 0;
    int has_cff = 0;
    for (size_t i = 0; i < num_tables; i++) {
        const uint8_t *tag = b + 12 + 16 * i;
        if (memcmp(tag, "glyf", 4) == 0) has_glyf = 1;
        if (memcmp(tag, "CFF ", 4) == 0 || memcmp(tag, "CFF2", 4) == 0) has_cff = 1;
    }
    if (has_cff && !has_glyf) return E_UNSUPPORTED_FORMAT;
    if (!has_glyf) return E_INVALID_FONT;
    return OK;
}

/* Mirror of the HarfBuzz scale: em = px * upem / (ascent - descent), scale = round(em * 64), 26.6 units.
 * Returns 0 if the rounded value does not fit a C int. Zig's @intFromFloat panics on that, so the
 * pixel-height bound must keep every accepted height inside the range. */
static int hb_scale_for(float px, uint32_t upem, int ascent, int descent, int *out) {
    float em = px * (float)upem / (float)(ascent - descent);
    float scaled = roundf(em * 64.0f);
    if (!(scaled >= (float)INT_MIN && scaled <= (float)INT_MAX)) return 0;
    *out = (int)scaled;
    return 1;
}

typedef struct {
    uint32_t upem;
    int asc;
    int desc;
    uint32_t num_glyphs;
} metrics_t;

/* Finds a table by tag in the table directory. Every offset is bounds-checked. */
static int find_table(const uint8_t *b, size_t len, const char tag[4], size_t *off, size_t *tlen) {
    if (len < 12) return 0;
    size_t n = be16(b + 4);
    if (len < 12 + 16 * n) return 0;
    for (size_t i = 0; i < n; i++) {
        const uint8_t *rec = b + 12 + 16 * i;
        if (memcmp(rec, tag, 4) == 0) {
            size_t o = be32(rec + 8);
            size_t l = be32(rec + 12);
            if (o > len || l > len - o) return 0;
            *off = o;
            *tlen = l;
            return 1;
        }
    }
    return 0;
}

/* Reads the three metrics the Zig code takes from the file: unitsPerEm (head), ascender and descender
 * (hhea), and numGlyphs (maxp). These stand in for stbtt_InitFont, GetFontVMetrics, and hb_face_get_upem. */
static err_t read_metrics(const uint8_t *b, size_t len, metrics_t *m) {
    size_t o = 0;
    size_t l = 0;
    if (!find_table(b, len, "head", &o, &l) || l < 20) return E_INVALID_FONT;
    m->upem = be16(b + o + 18);
    if (!find_table(b, len, "hhea", &o, &l) || l < 8) return E_INVALID_FONT;
    m->asc = (int16_t)be16(b + o + 4);
    m->desc = (int16_t)be16(b + o + 6);
    if (!find_table(b, len, "maxp", &o, &l) || l < 6) return E_INVALID_FONT;
    m->num_glyphs = be16(b + o + 4);
    if (m->upem == 0) return E_INVALID_FONT;
    return OK;
}

/* A face: the owned file bytes, and three objects standing in for the blob, the HarfBuzz face, and the
 * HarfBuzz font, which the Zig code errdefers in that order. */
typedef struct {
    uint8_t *bytes;
    size_t len;
    float pixel_height;
    int scale;
    metrics_t metrics;
    void *objs[3];
} face_t;

static void face_destroy(face_t *f) {
    /* Same order as RuntimeFont.deinit: font, face, blob, then the bytes. */
    for (int i = 2; i >= 0; i--) c_free(f->objs[i]);
    c_free(f->bytes);
    memset(f, 0, sizeof *f);
}

/* Mirror of fromOwned: takes ownership of `bytes`, and frees them on every failure. `fail_stage` picks a
 * simulated failure point: 1 = stbtt init, 2 = blob, 3 = face, 4 = font. 0 means no failure. */
static err_t from_owned(uint8_t *bytes, size_t len, float px, face_t *face, int fail_stage) {
    metrics_t m;
    void *objs[3] = {NULL, NULL, NULL};
    err_t e = check_pixel_height(px);
    if (e != OK) goto fail;
    e = check_format(bytes, len);
    if (e != OK) goto fail;
    if ((uint64_t)len > (uint64_t)UINT32_MAX) {
        e = E_INVALID_FONT;
        goto fail;
    }
    if (fail_stage == 1) {
        e = E_INVALID_FONT;
        goto fail;
    }
    e = read_metrics(bytes, len, &m);
    if (e != OK) goto fail;
    if (m.asc - m.desc <= 0) {
        e = E_INVALID_FONT;
        goto fail;
    }
    for (int i = 0; i < 3; i++) {
        if (fail_stage == i + 2) {
            e = E_INVALID_FONT;
            goto cleanup_objs;
        }
        objs[i] = c_alloc(16);
        if (objs[i] == NULL) {
            e = E_OUT_OF_MEMORY;
            goto cleanup_objs;
        }
    }
    int scale = 0;
    if (!hb_scale_for(px, m.upem, m.asc, m.desc, &scale)) {
        e = E_INVALID_PIXEL_HEIGHT;
        goto cleanup_objs;
    }
    face->bytes = bytes;
    face->len = len;
    face->pixel_height = px;
    face->scale = scale;
    face->metrics = m;
    memcpy(face->objs, objs, sizeof objs);
    return OK;

cleanup_objs:
    for (int i = 2; i >= 0; i--) c_free(objs[i]);
fail:
    c_free(bytes);
    return e;
}

/* Mirror of init: checks the height and format before the copy, so a rejected file costs no allocation. */
static err_t init_copy(const uint8_t *src, size_t len, float px, face_t *face, int fail_stage) {
    err_t e = check_pixel_height(px);
    if (e != OK) return e;
    e = check_format(src, len);
    if (e != OK) return e;
    uint8_t *bytes = c_alloc(len);
    if (bytes == NULL) return E_OUT_OF_MEMORY;
    memcpy(bytes, src, len);
    return from_owned(bytes, len, px, face, fail_stage);
}

/* The fake packaged reader. It serves one name, counts calls, and can be forced to fail. */
typedef struct {
    const char *name;
    const uint8_t *bytes;
    size_t len;
    reader_err_t force;
    int calls;
} reader_t;

/* Mirror of staging.Reader.read: returns a buffer the caller owns, or an error. */
static reader_err_t reader_read(reader_t *r, const char *relative, uint8_t **out, size_t *out_len) {
    r->calls++;
    if (r->force != R_OK) return r->force;
    if (strcmp(relative, r->name) != 0) return R_NOT_FOUND;
    uint8_t *copy = c_alloc(r->len);
    if (copy == NULL) return R_OUT_OF_MEMORY;
    memcpy(copy, r->bytes, r->len);
    *out = copy;
    *out_len = r->len;
    return R_OK;
}

/* Mirror of the switch in loadPackaged that renames the reader's errors. */
static err_t map_reader_error(reader_err_t e) {
    switch (e) {
        case R_NOT_FOUND: return E_FILE_NOT_FOUND;
        case R_READ_FAILED: return E_READ_FAILED;
        case R_PATH_TOO_LONG: return E_PATH_TOO_LONG;
        case R_OUT_OF_MEMORY: return E_OUT_OF_MEMORY;
        case R_OK: break;
    }
    return E_READ_FAILED;
}

/* Mirror of loadPackaged: checks the height, then reads, then builds the face on the reader's bytes. */
static err_t load_packaged(reader_t *r, const char *relative, float px, face_t *face, int fail_stage) {
    err_t e = check_pixel_height(px);
    if (e != OK) return e;
    uint8_t *bytes = NULL;
    size_t len = 0;
    reader_err_t re = reader_read(r, relative, &bytes, &len);
    if (re != R_OK) return map_reader_error(re);
    return from_owned(bytes, len, px, face, fail_stage);
}

/* ---- the shipped font, read straight from disk ---- */

static uint8_t *read_whole_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long n = ftell(f);
    if (n <= 0) { fclose(f); return NULL; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    uint8_t *buf = malloc((size_t)n); /* not counted: this is the harness's input, not the face's */
    if (buf == NULL) { fclose(f); return NULL; }
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) { free(buf); fclose(f); return NULL; }
    fclose(f);
    *len = (size_t)n;
    return buf;
}

int main(void) {
    printf("Packaged-loader mirror: checks/packaged_loader_mirror.c (mirrors src/engine/text/runtime_font.zig)\n");
    printf("This checks control flow and numeric bounds in C. It does not compile the Zig.\n\n");

    /* ---- 1. pixel-height rules ---- */
    printf("=== 1. pixel-height rules ===\n");
    CHECK(check_pixel_height(16.0f) == OK, "16 px is accepted");
    CHECK(check_pixel_height(MAX_PIXEL_HEIGHT) == OK, "max_pixel_height itself is accepted");
    CHECK(check_pixel_height(0.0f) == E_INVALID_PIXEL_HEIGHT, "0 px is refused");
    CHECK(check_pixel_height(-4.0f) == E_INVALID_PIXEL_HEIGHT, "negative px is refused");
    CHECK(check_pixel_height(NAN) == E_INVALID_PIXEL_HEIGHT, "NaN px is refused");
    CHECK(check_pixel_height(INFINITY) == E_INVALID_PIXEL_HEIGHT, "infinite px is refused");
    CHECK(check_pixel_height(4097.0f) == E_INVALID_PIXEL_HEIGHT, "just above the bound is refused");
    CHECK(check_pixel_height(1e9f) == E_INVALID_PIXEL_HEIGHT, "1e9 px is refused");

    /* Every accepted height must convert without leaving the C int range. Sweep the range. */
    int sweep_ok = 1;
    for (int i = 1; i <= 100000; i++) {
        float px = (float)i * (MAX_PIXEL_HEIGHT / 100000.0f);
        int s = 0;
        if (check_pixel_height(px) == OK && !hb_scale_for(px, 2048, 1854, -434, &s)) sweep_ok = 0;
    }
    CHECK(sweep_ok, "every accepted height in (0, 4096] converts into the C int scale");

    /* What the bound prevents: a finite height that the old code would have passed straight to @intFromFloat. */
    int overflow_scale = 0;
    CHECK(!hb_scale_for(1e9f, 2048, 1854, -434, &overflow_scale),
          "1e9 px would overflow the scale (the bound refuses it first)");

    /* ---- 2. HarfBuzz scale values the Zig tests pin ---- */
    printf("\n=== 2. HarfBuzz scale ===\n");
    int s16 = 0;
    CHECK(hb_scale_for(16.0f, 2048, 1854, -434, &s16) && s16 == 917,
          "16 px gives scale 917 (the Zig test expects 917)");
    int smax = 0;
    CHECK(hb_scale_for(MAX_PIXEL_HEIGHT, 2048, 1854, -434, &smax) && smax == 234646,
          "4096 px gives scale 234646 (the Zig test expects 234646)");

    /* ---- 3. the shipped font, read from disk ---- */
    printf("\n=== 3. shipped assets/font.ttf ===\n");
    size_t font_len = 0;
    uint8_t *font_bytes = read_whole_file("assets/font.ttf", &font_len);
    CHECK(font_bytes != NULL, "assets/font.ttf can be read (run from the repository root)");
    if (font_bytes == NULL) {
        printf("\nFAILED: the shipped font is needed for the rest of the checks.\n");
        return 1;
    }
    CHECK(check_format(font_bytes, font_len) == OK, "the shipped font is accepted as TrueType glyf");
    metrics_t shipped;
    CHECK(read_metrics(font_bytes, font_len, &shipped) == OK, "the shipped font's head, hhea, and maxp tables parse");
    CHECK(shipped.upem == 2048, "unitsPerEm is 2048 (the Zig test expects 2048)");
    CHECK(shipped.asc == 1854, "hhea ascender is 1854 (the Zig test expects 1854)");
    CHECK(shipped.desc == -434, "hhea descender is -434 (the Zig test expects -434)");
    CHECK(shipped.num_glyphs == 4652, "maxp numGlyphs is 4652 (the Zig test expects 4652)");

    /* ---- 4. format rules on small inputs (the six cases in the Zig tests) ---- */
    printf("\n=== 4. container rules ===\n");
    static const uint8_t otto[12] = {'O', 'T', 'T', 'O', 0, 0, 0, 0, 0, 0, 0, 0};
    static const uint8_t ttcf[12] = {'t', 't', 'c', 'f', 0, 0, 0, 0, 0, 0, 0, 0};
    static const uint8_t cff_only[28] = {0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0,
                                         'C', 'F', 'F', ' ', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    static const uint8_t truncated[12] = {0, 1, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0};
    static const char junk[] = "not a font file at all";
    CHECK(check_format((const uint8_t *)junk, strlen(junk)) == E_INVALID_FONT, "text that is not a font is refused");
    CHECK(check_format(otto, sizeof otto) == E_UNSUPPORTED_FORMAT, "OTTO (CFF) is refused as unsupported");
    CHECK(check_format(ttcf, sizeof ttcf) == E_UNSUPPORTED_FORMAT, "ttcf (collection) is refused as unsupported");
    CHECK(check_format(cff_only, sizeof cff_only) == E_UNSUPPORTED_FORMAT, "a CFF-only table set is refused as unsupported");
    CHECK(check_format(truncated, sizeof truncated) == E_INVALID_FONT, "a header that promises tables it lacks is refused");
    CHECK(check_format(font_bytes, 0) == E_INVALID_FONT, "an empty input is refused");

    /* ---- 5. the packaged path: order, mapping, and ownership ---- */
    printf("\n=== 5. packaged loader: order, error mapping, and ownership ===\n");
    reader_t serve = {"fonts/font.ttf", font_bytes, font_len, R_OK, 0};
    face_t face;
    memset(&face, 0, sizeof face);

    err_t e = load_packaged(&serve, "fonts/font.ttf", 16.0f, &face, 0);
    CHECK(e == OK, "a packaged font loads through the reader");
    CHECK(serve.calls == 1, "the file is read exactly once");
    CHECK(face.len == font_len && memcmp(face.bytes, font_bytes, font_len) == 0,
          "the face holds the reader's bytes, byte for byte");
    CHECK(face.scale == 917, "the loaded face's scale is 917 at 16 px");
    CHECK(live_allocations == 4, "a loaded face owns its bytes and three objects, and nothing else");
    face_destroy(&face);
    CHECK(live_allocations == 0, "destroying the face frees everything it owned");

    reader_t missing = {"fonts/font.ttf", font_bytes, font_len, R_OK, 0};
    memset(&face, 0, sizeof face);
    e = load_packaged(&missing, "fonts/other.ttf", 16.0f, &face, 0);
    CHECK(e == E_FILE_NOT_FOUND && missing.calls == 1, "a name the package lacks gives FileNotFound after one read");
    CHECK(live_allocations == 0, "a missing file leaves nothing allocated");

    reader_t untouched = {"fonts/font.ttf", font_bytes, font_len, R_OK, 0};
    e = load_packaged(&untouched, "fonts/font.ttf", 0.0f, &face, 0);
    CHECK(e == E_INVALID_PIXEL_HEIGHT, "a bad height is refused");
    e = load_packaged(&untouched, "fonts/font.ttf", 1e9f, &face, 0);
    CHECK(e == E_INVALID_PIXEL_HEIGHT && untouched.calls == 0,
          "a bad height is refused before the reader is called, both times");

    reader_t read_failed = {"fonts/font.ttf", font_bytes, font_len, R_READ_FAILED, 0};
    e = load_packaged(&read_failed, "fonts/font.ttf", 16.0f, &face, 0);
    CHECK(e == E_READ_FAILED, "the reader's ReadFailed comes back as ReadFailed");
    reader_t too_long = {"fonts/font.ttf", font_bytes, font_len, R_PATH_TOO_LONG, 0};
    e = load_packaged(&too_long, "fonts/font.ttf", 16.0f, &face, 0);
    CHECK(e == E_PATH_TOO_LONG, "the reader's PathTooLong comes back as PathTooLong");
    reader_t oom = {"fonts/font.ttf", font_bytes, font_len, R_OUT_OF_MEMORY, 0};
    e = load_packaged(&oom, "fonts/font.ttf", 16.0f, &face, 0);
    CHECK(e == E_OUT_OF_MEMORY, "the reader's OutOfMemory comes back as OutOfMemory");
    CHECK(live_allocations == 0, "none of the reader failures leaves anything allocated");

    /* A packaged file that is not a font: the bytes the reader gave must be freed by the face's code. */
    reader_t junk_reader = {"fonts/junk.ttf", (const uint8_t *)junk, strlen(junk), R_OK, 0};
    e = load_packaged(&junk_reader, "fonts/junk.ttf", 16.0f, &face, 0);
    CHECK(e == E_INVALID_FONT && live_allocations == 0,
          "junk read through the reader is rejected, and its bytes are freed once");

    reader_t otto_reader = {"fonts/cff.otf", otto, sizeof otto, R_OK, 0};
    e = load_packaged(&otto_reader, "fonts/cff.otf", 16.0f, &face, 0);
    CHECK(e == E_UNSUPPORTED_FORMAT && live_allocations == 0,
          "a CFF file read through the reader is rejected, and its bytes are freed once");

    /* Fail at every simulated stage after the bytes are owned. Each path must free exactly what it took. */
    int stage_ok = 1;
    for (int stage = 1; stage <= 4; stage++) {
        reader_t r = {"fonts/font.ttf", font_bytes, font_len, R_OK, 0};
        memset(&face, 0, sizeof face);
        e = load_packaged(&r, "fonts/font.ttf", 16.0f, &face, stage);
        printf("      stage %d fails with %s, live allocations afterwards: %ld\n", stage, err_name(e), live_allocations);
        if (e != E_INVALID_FONT || live_allocations != 0) stage_ok = 0;
    }
    CHECK(stage_ok, "a failure at each of the four stages frees every buffer that was taken");

    /* The init path (bytes the caller already holds) follows the same rules. */
    memset(&face, 0, sizeof face);
    e = init_copy(font_bytes, font_len, 16.0f, &face, 0);
    CHECK(e == OK && live_allocations == 4, "init copies the bytes and builds the face");
    face_destroy(&face);
    CHECK(live_allocations == 0, "init's face frees everything on destroy");

    e = init_copy(font_bytes, font_len, 1e9f, &face, 0);
    CHECK(e == E_INVALID_PIXEL_HEIGHT && live_allocations == 0, "init refuses the overflow height without allocating");
    e = init_copy((const uint8_t *)junk, strlen(junk), 16.0f, &face, 0);
    CHECK(e == E_INVALID_FONT && live_allocations == 0, "init refuses junk without allocating");
    e = init_copy(font_bytes, font_len, 16.0f, &face, 3);
    CHECK(e == E_INVALID_FONT && live_allocations == 0, "init frees its copy when the face build fails");

    /* Repeated create and destroy: the lifecycle test's pattern. */
    int cycles_ok = 1;
    for (int i = 0; i < 20; i++) {
        reader_t r = {"fonts/font.ttf", font_bytes, font_len, R_OK, 0};
        memset(&face, 0, sizeof face);
        if (load_packaged(&r, "fonts/font.ttf", 16.0f, &face, 0) != OK) cycles_ok = 0;
        face_destroy(&face);
    }
    CHECK(cycles_ok && live_allocations == 0, "20 packaged create and destroy cycles leave nothing allocated");

    free(font_bytes);
    CHECK(live_allocations == 0, "the whole run ends with no counted allocation left");

    printf("\n");
    if (failures == 0) {
        printf("PASSED (0 failures)\n");
        return 0;
    }
    printf("FAILED (%d failures)\n", failures);
    return 1;
}
