/*
 * Mirror of src/engine/text/glyph_cache.zig, src/engine/text/glyph_resolver.zig, and plan2d in
 * src/engine/renderer/glyph_atlas.zig. It belongs to Phase 4 of the text and font system migration plan.
 * The Zig source comments call this "Phase 3 of the rendering migration plan". That label is legacy.
 * The resolver's glyph source is synthetic (fake_metrics, fake_coverage). RuntimeFont, stb_truetype, and
 * HarfBuzz are not modeled, so the real font's metric values are checked only by the Zig tests.
 * checks/glyph_cache_parity.txt maps each Zig test to its check here.
 *
 * Each function below follows its Zig counterpart line for line, and each check uses the same
 * numbers as the matching Zig test. This checks the control flow, the packing arithmetic, the table,
 * and the pending-list rules under AddressSanitizer and UBSan. It does NOT compile the Zig. The owner's
 * `zig build test` is the first real check of the Zig.
 *
 * Mutation builds: define one MUT_* macro to plant a bug. The run must then fail. See the RESULTS file.
 */
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DEFAULT_PAGE_SIZE 1024u
#define DEFAULT_PAGE_COUNT 4u
#define MAX_PAGE_SIZE 8192u
#define MAX_PAGE_COUNT 64u
#define PADDING 1u
#define WHITE_SIZE 2u
#define MAX_PENDING 512u
#define INITIAL_SLOTS 256u

typedef struct { uint32_t page, x, y, w, h; } Region;
typedef struct { float advance, xoff, yoff; uint32_t width, height; } Metrics;
typedef enum { RASTER_GRAY = 0, RASTER_MONO = 1 } RasterMode;
typedef struct { uint32_t font, glyph, size_bits; RasterMode mode; } GlyphKey;
typedef struct { Metrics metrics; Region region; } Entry;
typedef struct {
    uint64_t hits, misses, inserts, empty_glyphs, cache_full, too_large;
    uint64_t missing_codepoints, removed, rehashes;
    uint32_t pages_in_use, entries;
    uint64_t rasterized, missing_glyphs, allocated_bytes;
} Stats;

typedef enum { ERR_NONE = 0, ERR_GLYPH_TOO_LARGE, ERR_ATLAS_FULL, ERR_INVALID_BITMAP, ERR_INVALID_OPTIONS, ERR_OOM, ERR_GLYPH_OUT_OF_RANGE, ERR_UNSUPPORTED_MODE } Err;
typedef enum { SLOT_EMPTY, SLOT_USED, SLOT_TOMBSTONE } SlotState;
typedef struct { SlotState state; GlyphKey key; Entry entry; } Slot;

typedef struct {
    uint8_t *pixels;
    uint32_t cursor_x, shelf_y, shelf_h;
    int used, dirty_all;
} Page;

typedef struct {
    uint32_t page_size;
    Page *pages;
    size_t page_count;
    Slot *slots;
    size_t slot_len;
    size_t live, tombstones;
    Region pending[MAX_PENDING];
    size_t pending_count;
    Stats stats;
} Cache;

/* ---- harness ---------------------------------------------------------- */

static int failures = 0;
static int checks = 0;
static const char *current = "";

#define CHECK(cond, msg)                                                       \
    do {                                                                       \
        checks++;                                                              \
        if (!(cond)) {                                                         \
            failures++;                                                        \
            printf("FAIL: %s: %s (line %d)\n", current, msg, __LINE__);        \
        }                                                                      \
    } while (0)

#define CHECK_EQ(actual, expected, msg)                                        \
    do {                                                                       \
        checks++;                                                              \
        if ((unsigned long long)(actual) != (unsigned long long)(expected)) {  \
            failures++;                                                        \
            printf("FAIL: %s: %s: got %llu, want %llu (line %d)\n", current,   \
                   msg, (unsigned long long)(actual),                          \
                   (unsigned long long)(expected), __LINE__);                  \
        }                                                                      \
    } while (0)

#define CHECK_ERR(call, err, msg)                                              \
    do {                                                                       \
        checks++;                                                              \
        Err got_ = (call);                                                     \
        if (got_ != (err)) {                                                   \
            failures++;                                                        \
            printf("FAIL: %s: %s: got error %d, want %d (line %d)\n", current, \
                   msg, (int)got_, (int)(err), __LINE__);                      \
        }                                                                      \
    } while (0)

static void begin(const char *name) {
    current = name;
    printf("--- %s\n", name);
}

/* ---- helpers ---------------------------------------------------------- */

static uint32_t size_bits_of(float pixel_height) {
    uint32_t bits;
    memcpy(&bits, &pixel_height, sizeof bits);
    return bits;
}

static GlyphKey key_of(uint32_t font, uint32_t glyph) {
    GlyphKey k = { font, glyph, size_bits_of(16.0f), RASTER_GRAY };
    return k;
}

static Metrics metrics_of(uint32_t w, uint32_t h) {
    Metrics m;
    m.advance = (float)(w + 1);
    m.xoff = 0;
    m.yoff = -(float)h;
    m.width = w;
    m.height = h;
    return m;
}

static int region_eq(Region a, Region b) {
    return a.page == b.page && a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h;
}

static Region white_region(void) {
    Region r = { 0, 0, 0, WHITE_SIZE, WHITE_SIZE };
    return r;
}

static uint32_t mix(uint32_t value) {
    uint32_t h = value;
    h ^= h >> 16;
    h *= 0x85ebca6bu;
    h ^= h >> 13;
    h *= 0xc2b2ae35u;
    h ^= h >> 16;
    return h;
}

static size_t hash_key(GlyphKey key) {
    uint32_t h = mix(key.font);
    h = mix(h ^ key.glyph);
    h = mix(h ^ key.size_bits);
    h = mix(h ^ (uint32_t)key.mode);
    return (size_t)h;
}

static int same_key(GlyphKey a, GlyphKey b) {
#ifdef MUT_MODE_NOT_IN_EQ
    return a.font == b.font && a.glyph == b.glyph && a.size_bits == b.size_bits;
#else
    return a.font == b.font && a.glyph == b.glyph && a.size_bits == b.size_bits && a.mode == b.mode;
#endif
}

/* ---- allocation hook (the std.testing.FailingAllocator model) ---------- */

/* Every allocation the cache makes goes through cache_alloc. It counts successful allocations and fails
 * once that count reaches alloc_fail_at, as FailingAllocator does, so the Nth allocation of a test fails
 * in both languages. Zero-size allocations are not counted: Zig's alloc(T, 0) makes no allocator call. */
static size_t alloc_count = 0;
static size_t alloc_fail_at = SIZE_MAX;

static void alloc_plan(size_t fail_at) {
    alloc_count = 0;
    alloc_fail_at = fail_at;
}

static void *cache_alloc(size_t count, size_t size) {
    if (alloc_count == alloc_fail_at) return NULL;
    void *p = calloc(count, size);
    if (p) alloc_count++;
    return p;
}

/* ---- page packer (Page.place) ----------------------------------------- */

static int page_place(Page *p, uint32_t page_size, uint32_t w, uint32_t h, uint32_t *ox, uint32_t *oy) {
#ifdef MUT_NOPAD
    uint32_t pw = w;
    uint32_t ph = h;
#else
    uint32_t pw = w + PADDING;
    uint32_t ph = h + PADDING;
#endif
    uint32_t x = p->cursor_x;
    uint32_t y = p->shelf_y;
    uint32_t shelf_h = p->shelf_h;
#ifndef MUT_NOWRAP
    if (x + pw > page_size) {
        y += shelf_h;
        x = 0;
        shelf_h = 0;
    }
#endif
    if (y + ph > page_size) return 0;
    p->cursor_x = x + pw;
    p->shelf_y = y;
    p->shelf_h = shelf_h > ph ? shelf_h : ph;
    p->used = 1;
    *ox = x;
    *oy = y;
    return 1;
}

/* ---- cache ------------------------------------------------------------ */

static void mark_pending(Cache *c, Region r) {
    if (c->pending_count < MAX_PENDING) {
        c->pending[c->pending_count++] = r;
    } else {
#ifndef MUT_NOOVERFLOW
        c->pages[r.page].dirty_all = 1;
#endif
    }
}

static void reserve_white(Cache *c) {
    uint32_t ox = 0, oy = 0;
    int ok = page_place(&c->pages[0], c->page_size, WHITE_SIZE, WHITE_SIZE, &ox, &oy);
    if (!ok) abort(); /* page_size >= 3 is checked in init */
    for (uint32_t row = 0; row < WHITE_SIZE; row++) {
        size_t start = (size_t)(oy + row) * c->page_size + ox;
        memset(c->pages[0].pixels + start, 255, WHITE_SIZE);
    }
    Region r = { 0, ox, oy, WHITE_SIZE, WHITE_SIZE };
    mark_pending(c, r);
}

static Err cache_init(Cache *c, uint32_t page_size, uint32_t page_count) {
    memset(c, 0, sizeof *c);
    if (page_size < WHITE_SIZE + PADDING || page_size > MAX_PAGE_SIZE) return ERR_INVALID_OPTIONS;
    if (page_count == 0 || page_count > MAX_PAGE_COUNT) return ERR_INVALID_OPTIONS;
    c->page_size = page_size;
    c->page_count = page_count;
    c->pages = cache_alloc(page_count, sizeof(Page));
    if (!c->pages) return ERR_OOM;
    size_t texels = (size_t)page_size * page_size;
    for (size_t i = 0; i < page_count; i++) {
        c->pages[i].pixels = cache_alloc(texels, 1);
        if (!c->pages[i].pixels) {
            for (size_t j = 0; j < i; j++) free(c->pages[j].pixels);
            free(c->pages);
            return ERR_OOM;
        }
    }
    c->slot_len = INITIAL_SLOTS;
    c->slots = cache_alloc(c->slot_len, sizeof(Slot));
    if (!c->slots) {
        for (size_t j = 0; j < page_count; j++) free(c->pages[j].pixels);
        free(c->pages);
        return ERR_OOM;
    }
    reserve_white(c);
    return ERR_NONE;
}

static void cache_deinit(Cache *c) {
    for (size_t i = 0; i < c->page_count; i++) free(c->pages[i].pixels);
    free(c->pages);
    free(c->slots);
    memset(c, 0, sizeof *c);
}

static size_t cache_mask(const Cache *c) { return c->slot_len - 1; }

/* Index of the used slot holding `key`, or -1. Probes stop at the first empty slot. */
static long find_slot(const Cache *c, GlyphKey key) {
    size_t index = hash_key(key) & cache_mask(c);
    for (size_t probes = 0; probes < c->slot_len; probes++) {
        const Slot *slot = &c->slots[index];
#ifdef MUT_TOMBSTONE_EMPTY
        if (slot->state == SLOT_EMPTY || slot->state == SLOT_TOMBSTONE) return -1;
#else
        if (slot->state == SLOT_EMPTY) return -1;
#endif
        if (slot->state == SLOT_USED && same_key(slot->key, key)) return (long)index;
        index = (index + 1) & cache_mask(c);
    }
    return -1;
}

static int lookup(Cache *c, GlyphKey key, Entry *out) {
    long index = find_slot(c, key);
    if (index >= 0) {
        c->stats.hits++;
        *out = c->slots[index].entry;
        return 1;
    }
#ifndef MUT_NOMISS
    c->stats.misses++;
#endif
    return 0;
}

static void insert_new(Cache *c, GlyphKey key, Entry entry) {
    size_t index = hash_key(key) & cache_mask(c);
    while (c->slots[index].state == SLOT_USED) index = (index + 1) & cache_mask(c);
    if (c->slots[index].state == SLOT_TOMBSTONE) c->tombstones--;
    c->slots[index].state = SLOT_USED;
    c->slots[index].key = key;
    c->slots[index].entry = entry;
    c->live++;
}

static Err ensure_room(Cache *c) {
    if ((c->live + c->tombstones + 1) * 4 <= c->slot_len * 3) return ERR_NONE;
    size_t new_len = c->slot_len;
    while ((c->live + 1) * 2 > new_len) new_len *= 2;
    Slot *fresh = cache_alloc(new_len, sizeof(Slot));
    if (!fresh) return ERR_OOM;
    Slot *old = c->slots;
    size_t old_len = c->slot_len;
    c->slots = fresh;
    c->slot_len = new_len;
    c->live = 0;
    c->tombstones = 0;
    for (size_t i = 0; i < old_len; i++) {
        if (old[i].state == SLOT_USED) {
#ifndef MUT_DROP_ON_GROW
            insert_new(c, old[i].key, old[i].entry);
#endif
        }
    }
    free(old);
    c->stats.rehashes++;
    return ERR_NONE;
}

static Err place_glyph(Cache *c, uint32_t w, uint32_t h, Region *out) {
    for (size_t i = 0; i < c->page_count; i++) {
        uint32_t ox = 0, oy = 0;
        if (page_place(&c->pages[i], c->page_size, w, h, &ox, &oy)) {
            Region r = { (uint32_t)i, ox, oy, w, h };
            *out = r;
            return ERR_NONE;
        }
    }
    c->stats.cache_full++;
    return ERR_ATLAS_FULL;
}

static void blit(Cache *c, Region r, const uint8_t *coverage) {
    Page *page = &c->pages[r.page];
    for (uint32_t row = 0; row < r.h; row++) {
        size_t dst = (size_t)(r.y + row) * c->page_size + r.x;
#ifdef MUT_BAD_STRIDE
        size_t src = (size_t)row * c->page_size;
#else
        size_t src = (size_t)row * r.w;
#endif
        memcpy(page->pixels + dst, coverage + src, r.w);
    }
    mark_pending(c, r);
}

/* Returns the error, and fills *out with the entry (the existing one, for a repeat key). */
static Err cache_insert(Cache *c, GlyphKey key, Metrics m, const uint8_t *coverage, size_t coverage_len, Entry *out) {
    long existing = find_slot(c, key);
    if (existing >= 0) {
        *out = c->slots[existing].entry;
        return ERR_NONE;
    }
    Entry entry;
    memset(&entry, 0, sizeof entry);
    entry.metrics = m;
    if (m.width == 0 || m.height == 0) {
        if (coverage_len != 0) return ERR_INVALID_BITMAP;
        if (ensure_room(c) != ERR_NONE) return ERR_OOM;
        c->stats.empty_glyphs++;
    } else {
        uint32_t limit = c->page_size - PADDING;
        if (m.width > limit || m.height > limit) {
#ifndef MUT_NOTOOLARGE_COUNT
            c->stats.too_large++;
#endif
            return ERR_GLYPH_TOO_LARGE;
        }
        if (coverage_len != (size_t)m.width * (size_t)m.height) return ERR_INVALID_BITMAP;
        if (ensure_room(c) != ERR_NONE) return ERR_OOM;
        Err e = place_glyph(c, m.width, m.height, &entry.region);
        if (e != ERR_NONE) return e;
        blit(c, entry.region, coverage);
    }
    insert_new(c, key, entry);
    c->stats.inserts++;
    *out = entry;
    return ERR_NONE;
}

static uint32_t cache_remove_font(Cache *c, uint32_t font) {
    uint32_t removed = 0;
    for (size_t i = 0; i < c->slot_len; i++) {
        Slot *s = &c->slots[i];
        if (s->state == SLOT_USED && s->key.font == font) {
#ifndef MUT_REMOVE_NOOP
            s->state = SLOT_TOMBSTONE;
            c->live--;
            c->tombstones++;
#endif
            removed++;
        }
    }
    c->stats.removed += removed;
    return removed;
}

static void cache_clear_pending(Cache *c) {
    c->pending_count = 0;
    for (size_t i = 0; i < c->page_count; i++) c->pages[i].dirty_all = 0;
}

static void cache_mark_all_dirty(Cache *c) {
    c->pending_count = 0;
    for (size_t i = 0; i < c->page_count; i++) c->pages[i].dirty_all = 1;
}

static void cache_clear(Cache *c) {
    memset(c->slots, 0, c->slot_len * sizeof(Slot));
    c->live = 0;
    c->tombstones = 0;
    for (size_t i = 0; i < c->page_count; i++) {
        memset(c->pages[i].pixels, 0, (size_t)c->page_size * c->page_size);
        c->pages[i].cursor_x = 0;
        c->pages[i].shelf_y = 0;
        c->pages[i].shelf_h = 0;
        c->pages[i].used = 0;
        c->pages[i].dirty_all = 1;
    }
    c->pending_count = 0;
    reserve_white(c);
}

static Stats cache_snapshot(const Cache *c) {
    Stats s = c->stats;
    s.entries = (uint32_t)c->live;
    uint32_t in_use = 0;
    for (size_t i = 0; i < c->page_count; i++) {
        if (c->pages[i].used) in_use++;
    }
    s.pages_in_use = in_use;
    size_t texels = (size_t)c->page_size * c->page_size;
    s.allocated_bytes = (uint64_t)texels * c->page_count + (uint64_t)c->slot_len * sizeof(Slot);
    return s;
}

static const uint8_t *region_coverage(const Cache *c, Region r) {
    size_t start = (size_t)r.y * c->page_size + r.x;
    return c->pages[r.page].pixels + start;
}

static uint8_t page_byte(const Cache *c, uint32_t page, size_t index) {
    return c->pages[page].pixels[index];
}

/* ---- plan2d (renderer/glyph_atlas.zig) ------------------------------- */

typedef enum { ACT_NONE, ACT_SYNC_WHOLE_PAGE, ACT_UPDATE_REGIONS, ACT_RELEASE } Action2d;

static Action2d plan_2d(int want_2d, int valid, int in_use, int changed) {
#ifdef MUT_PLAN_KEEP
    if (!want_2d) return ACT_NONE;
#else
    if (!want_2d) return ACT_RELEASE;
#endif
    if (!valid) return in_use ? ACT_SYNC_WHOLE_PAGE : ACT_NONE;
    return changed ? ACT_UPDATE_REGIONS : ACT_NONE;
}

static void t_plan_2d(void) {
    begin("the 2D copy follows the renderer: made when a used page is drawn, updated while changed, released when it leaves 2D");
    CHECK_EQ(plan_2d(0, 0, 1, 1), ACT_RELEASE, "GPU mode, no copy: release (a no-op)");
    CHECK_EQ(plan_2d(0, 1, 1, 0), ACT_RELEASE, "GPU mode, copy present: release");
    CHECK_EQ(plan_2d(1, 0, 1, 0), ACT_SYNC_WHOLE_PAGE, "2D mode, first use of a used page: make the copy");
    CHECK_EQ(plan_2d(1, 0, 0, 0), ACT_NONE, "2D mode, unused page: no copy");
    CHECK_EQ(plan_2d(1, 1, 1, 1), ACT_UPDATE_REGIONS, "2D mode, copy present, changed: update the regions");
    CHECK_EQ(plan_2d(1, 1, 1, 0), ACT_NONE, "2D mode, copy present, unchanged: nothing");
}

/* ---- on-demand resolver (text/glyph_resolver.zig) -------------------- */

/* Glyph 0 has ink, like a .notdef box. A synthetic glyph source standing in for RuntimeFont. It checks the resolver's logic: the key, the counters,
 * the upload rectangle, and the fallback. It does not check metric values from a real font. Glyph 36 is 11 by
 * 11 at 16 px, the size of 'A' in the shipped font. Glyph 7 has no ink, like a space. */
#define FAKE_GLYPH_COUNT 4652u
#define FAKE_A 36u
#define FAKE_EMPTY 7u
#define FAKE_V 57u
#define FAKE_T 55u

typedef struct { uint32_t glyph_count; uint32_t pixel_height; } FakeFont;

static Err fake_metrics(const FakeFont *f, uint32_t gid, Metrics *m) {
    if (gid >= f->glyph_count) return ERR_GLYPH_OUT_OF_RANGE;
    uint32_t w, h;
    if (gid == FAKE_A) {
        w = 11;
        h = 11;
    } else if (gid != 0 && gid % 7 == 0) {
        w = 0;
        h = 0;
    } else {
        w = 2 + gid % 5;
        h = 2 + gid % 4;
    }
    w = w * f->pixel_height / 16;
    h = h * f->pixel_height / 16;
    m->advance = (float)(w + 1);
    m->xoff = 0;
    m->yoff = -(float)h;
    m->width = w;
    m->height = h;
    return ERR_NONE;
}

static void fake_coverage(uint32_t gid, uint32_t w, uint32_t h, uint8_t *out) {
    for (uint32_t r = 0; r < h; r++) {
        for (uint32_t c = 0; c < w; c++) out[r * w + c] = (uint8_t)(gid * 13u + r * 7u + c * 3u + 1u);
    }
}

/* Mirrors resolve() in glyph_resolver.zig: refuse the mode, look up, rasterize on a miss, count, insert. */
static Err resolve(Cache *c, uint32_t font_id, const FakeFont *f, uint32_t gid, RasterMode mode, Entry *out) {
#ifndef MUT_UNSUPPORTED_AS_GRAY
    if (mode != RASTER_GRAY) return ERR_UNSUPPORTED_MODE;
#endif
    GlyphKey key = { font_id, gid, size_bits_of((float)f->pixel_height), mode };
#ifndef MUT_RESOLVE_IGNORES_CACHE
    if (lookup(c, key, out)) return ERR_NONE;
#endif
    Metrics m;
    Err e = fake_metrics(f, gid, &m);
    if (e != ERR_NONE) return e;
    size_t size = (size_t)m.width * (size_t)m.height;
    uint8_t *coverage = NULL;
    if (size > 0) {
        coverage = cache_alloc(size, 1);
        if (!coverage) return ERR_OOM;
        fake_coverage(gid, m.width, m.height, coverage);
    }
#ifndef MUT_RESOLVE_NO_RASTER_COUNT
    c->stats.rasterized++;
#endif
    Err ins = cache_insert(c, key, m, coverage, size, out);
#ifndef MUT_LEAK_COVERAGE
    free(coverage);
#endif
    return ins;
}

/* Mirrors resolveWithFallback() in glyph_resolver.zig. */
static Err resolve_with_fallback(Cache *c, uint32_t font_id, const FakeFont *f, uint32_t gid, uint32_t fallback,
                                 RasterMode mode, Entry *out, int *substituted) {
#ifndef MUT_UNSUPPORTED_AS_GRAY
    if (mode != RASTER_GRAY) {
        *substituted = 0;
        return ERR_UNSUPPORTED_MODE;
    }
#endif
    /* A glyph is missing when its ID is at least the glyph count. Glyph 0 is valid (.notdef). */
#if defined(MUT_ZERO_IS_MISSING)
    int in_font = gid != 0 && gid < f->glyph_count;
#elif defined(MUT_MISSING_OFF_BY_ONE)
    int in_font = gid <= f->glyph_count;
#else
    int in_font = gid < f->glyph_count;
#endif
    if (in_font) {
        *substituted = 0;
        return resolve(c, font_id, f, gid, mode, out);
    }
#ifndef MUT_FALLBACK_NO_COUNT
    c->stats.missing_glyphs++;
#endif
    *substituted = 1;
    return resolve(c, font_id, f, fallback, mode, out);
}

/* Mirrors WarmStats in glyph_resolver.zig. */
typedef struct { uint32_t rasterized, already_cached, substituted; } WarmStats;

/* Mirrors warm() in glyph_resolver.zig: refuse the mode, then resolve each glyph with its fallback, counting it as
 * rasterized when the rasterization counter moved and as already cached when it did not. The first error stops the
 * run and is returned. MUT_WARM_CONTINUES plants a skip-and-go-on bug. MUT_WARM_NO_SUBST_COUNT plants a bug that
 * drops the substituted count. */
static Err warm(Cache *c, uint32_t font_id, const FakeFont *f, const uint32_t *ids, size_t count, uint32_t fallback,
                RasterMode mode, WarmStats *out) {
    memset(out, 0, sizeof *out);
    if (mode != RASTER_GRAY) return ERR_UNSUPPORTED_MODE;
    for (size_t i = 0; i < count; i++) {
        uint64_t before = c->stats.rasterized;
        Entry e;
        int substituted = 0;
        Err err = resolve_with_fallback(c, font_id, f, ids[i], fallback, mode, &e, &substituted);
#ifdef MUT_WARM_CONTINUES
        if (err != ERR_NONE) continue;
#else
        if (err != ERR_NONE) return err;
#endif
#ifndef MUT_WARM_NO_SUBST_COUNT
        if (substituted) out->substituted++;
#endif
        if (c->stats.rasterized != before) {
            out->rasterized++;
        } else {
            out->already_cached++;
        }
    }
    return ERR_NONE;
}

/* ---- tests (names and numbers match the Zig tests) -------------------- */

static void t_white_block(void) {
    begin("a new cache holds the white block at the origin of page 0 and queues it for upload");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 2), ERR_NONE, "init");
    CHECK_EQ(c.pending_count, 1, "one pending region");
    CHECK(region_eq(c.pending[0], white_region()), "pending region is the white block");
    CHECK_EQ(page_byte(&c, 0, 0), 255, "texel (0,0) is white");
    CHECK_EQ(page_byte(&c, 0, 1), 255, "texel (1,0) is white");
    CHECK_EQ(page_byte(&c, 0, 32), 255, "texel (0,1) is white");
    CHECK_EQ(page_byte(&c, 0, 33), 255, "texel (1,1) is white");
    CHECK_EQ(page_byte(&c, 0, 2), 0, "texel (2,0) is not white");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.pages_in_use, 1, "one page in use");
    CHECK_EQ(s.entries, 0, "no entries");
    CHECK(c.pages[0].used, "page 0 is in use");
    CHECK(!c.pages[1].used, "page 1 is not in use");
    cache_deinit(&c);
}

static void t_hit_miss(void) {
    begin("a glyph misses once, is inserted, and then hits, and a repeated insert returns the same entry");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 2), ERR_NONE, "init");
    uint8_t coverage[4] = { 9, 8, 7, 6 };
    Entry e;
    CHECK(!lookup(&c, key_of(1, 5), &e), "first lookup misses");
    Entry first;
    CHECK_ERR(cache_insert(&c, key_of(1, 5), metrics_of(2, 2), coverage, 4, &first), ERR_NONE, "insert");
    CHECK(lookup(&c, key_of(1, 5), &e), "lookup after insert hits");
    CHECK(region_eq(e.region, first.region), "hit has the inserted region");
    Entry again;
    CHECK_ERR(cache_insert(&c, key_of(1, 5), metrics_of(2, 2), coverage, 4, &again), ERR_NONE, "repeat insert");
    CHECK(region_eq(again.region, first.region), "repeat insert returns the same region");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.misses, 1, "one miss");
    CHECK_EQ(s.hits, 1, "one hit");
    CHECK_EQ(s.inserts, 1, "one insert");
    CHECK_EQ(s.entries, 1, "one entry");
    cache_deinit(&c);
}

static void t_rows_copied(void) {
    begin("glyph rows are copied to the region the cache reports, and region coverage keeps the page stride");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 2), ERR_NONE, "init");
    uint8_t coverage[6] = { 1, 2, 3, 4, 5, 6 };
    Entry e;
    CHECK_ERR(cache_insert(&c, key_of(1, 1), metrics_of(3, 2), coverage, 6, &e), ERR_NONE, "insert 3x2");
    CHECK_EQ(e.region.page, 0, "page 0");
    CHECK_EQ(e.region.x, 3, "first glyph after white starts at x=3");
    CHECK_EQ(e.region.y, 0, "first glyph on the first shelf");
    CHECK_EQ(page_byte(&c, 0, 3), 1, "row 0 col 0");
    CHECK_EQ(page_byte(&c, 0, 5), 3, "row 0 col 2");
    CHECK_EQ(page_byte(&c, 0, 32 + 3), 4, "row 1 col 0");
    CHECK_EQ(page_byte(&c, 0, 32 + 5), 6, "row 1 col 2");
    const uint8_t *view = region_coverage(&c, e.region);
    CHECK_EQ(view[0], 1, "view row 0 col 0");
    CHECK_EQ(view[32], 4, "view row 1 col 0 is one page stride down");
    CHECK_EQ(view[32 + 2], 6, "view row 1 col 2");
    cache_deinit(&c);
}

static void t_empty_glyph(void) {
    begin("glyphs with no ink take no page space and queue nothing");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 1), ERR_NONE, "init");
    Entry e;
    Metrics none = { 4.0f, 0, 0, 0, 0 };
    CHECK_ERR(cache_insert(&c, key_of(1, 9), none, NULL, 0, &e), ERR_NONE, "insert empty");
    CHECK_EQ(e.region.w, 0, "empty region has no width");
    CHECK_EQ(e.region.h, 0, "empty region has no height");
    CHECK_EQ(c.pending_count, 1, "pending list unchanged");
    CHECK_EQ(cache_snapshot(&c).empty_glyphs, 1, "one empty glyph");
    CHECK(lookup(&c, key_of(1, 9), &e), "empty glyph is found");
    Entry next;
    CHECK_ERR(cache_insert(&c, key_of(1, 10), metrics_of(1, 1), (const uint8_t *)"\x07", 1, &next), ERR_NONE, "next glyph");
    CHECK_EQ(next.region.x, 3, "next glyph still starts after the white block");
    cache_deinit(&c);
}

static void t_keys(void) {
    begin("keys differ by font, glyph, and pixel height");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 2), ERR_NONE, "init");
    Entry e;
    uint8_t one = 7;
    CHECK_ERR(cache_insert(&c, key_of(1, 1), metrics_of(1, 1), &one, 1, &e), ERR_NONE, "insert");
    CHECK(!lookup(&c, key_of(2, 1), &e), "other font misses");
    CHECK(!lookup(&c, key_of(1, 2), &e), "other glyph misses");
    GlyphKey other_size = { 1, 1, size_bits_of(17.0f), RASTER_GRAY };
    CHECK(!lookup(&c, other_size, &e), "other size misses");
    CHECK(lookup(&c, key_of(1, 1), &e), "original key hits");
    cache_deinit(&c);
}

static void t_shelf_wrap(void) {
    begin("a glyph that does not fit the shelf starts a new shelf below it");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 1), ERR_NONE, "init");
    uint8_t coverage[16];
    memset(coverage, 1, sizeof coverage);
    Entry e;
    for (uint32_t glyph = 1; glyph <= 5; glyph++) {
        CHECK_ERR(cache_insert(&c, key_of(1, glyph), metrics_of(4, 4), coverage, 16, &e), ERR_NONE, "shelf 0 glyph");
        CHECK_EQ(e.region.y, 0, "shelf 0 is at y=0");
    }
    CHECK_ERR(cache_insert(&c, key_of(1, 6), metrics_of(4, 4), coverage, 16, &e), ERR_NONE, "sixth glyph");
    CHECK_EQ(e.region.x, 0, "sixth glyph starts a new shelf at x=0");
    CHECK_EQ(e.region.y, 5, "new shelf is 5 texels down");
    cache_deinit(&c);
}

static void t_full_pages(void) {
    begin("a full page sends the next glyph to the next page, and a full cache refuses it and counts it");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 2), ERR_NONE, "init");
    uint8_t coverage[16];
    memset(coverage, 1, sizeof coverage);
    Entry e;
    for (uint32_t glyph = 1; glyph <= 71; glyph++) {
        CHECK_ERR(cache_insert(&c, key_of(1, glyph), metrics_of(4, 4), coverage, 16, &e), ERR_NONE, "fill");
    }
    CHECK_ERR(cache_insert(&c, key_of(1, 72), metrics_of(4, 4), coverage, 16, &e), ERR_ATLAS_FULL, "72nd refused");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.cache_full, 1, "one cache_full");
    CHECK_EQ(s.pages_in_use, 2, "two pages in use");
    CHECK_EQ(s.entries, 71, "71 entries");
    CHECK(!lookup(&c, key_of(1, 72), &e), "refused glyph is not cached");
    CHECK(lookup(&c, key_of(1, 36), &e), "glyph 36 is cached");
    CHECK_EQ(e.region.page, 1, "glyph 36 is on page 1");
    CHECK_EQ(e.region.x, 0, "glyph 36 at x=0");
    CHECK_EQ(e.region.y, 0, "glyph 36 at y=0");
    cache_deinit(&c);
}

static void t_too_large(void) {
    begin("a glyph wider than the page allows is refused and counted");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 2), ERR_NONE, "init");
    uint8_t coverage[128];
    memset(coverage, 1, sizeof coverage);
    Entry e;
    CHECK_ERR(cache_insert(&c, key_of(1, 1), metrics_of(32, 4), coverage, 128, &e), ERR_GLYPH_TOO_LARGE, "32 wide refused");
    CHECK_EQ(cache_snapshot(&c).too_large, 1, "one too_large");
    CHECK(!lookup(&c, key_of(1, 1), &e), "refused glyph not cached");
    cache_deinit(&c);
}

static void t_bad_bitmap(void) {
    begin("a coverage buffer of the wrong length is refused and leaves the cache unchanged");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 1), ERR_NONE, "init");
    uint8_t three[3] = { 1, 2, 3 };
    Entry e;
    CHECK_ERR(cache_insert(&c, key_of(1, 1), metrics_of(2, 2), three, 3, &e), ERR_INVALID_BITMAP, "3 bytes for 2x2");
    uint8_t one = 1;
    Metrics none = { 1.0f, 0, 0, 0, 0 };
    CHECK_ERR(cache_insert(&c, key_of(1, 2), none, &one, 1, &e), ERR_INVALID_BITMAP, "bytes for empty glyph");
    CHECK_EQ(c.pending_count, 1, "pending unchanged");
    CHECK_EQ(cache_snapshot(&c).entries, 0, "no entries");
    cache_deinit(&c);
}

static void t_remove_font(void) {
    begin("removing a font forgets its glyphs and keeps the others");
    Cache c;
    CHECK_ERR(cache_init(&c, 64, 1), ERR_NONE, "init");
    uint8_t four1[4] = { 1, 1, 1, 1 };
    uint8_t four2[4] = { 2, 2, 2, 2 };
    Entry e;
    for (uint32_t glyph = 1; glyph <= 3; glyph++) {
        CHECK_ERR(cache_insert(&c, key_of(1, glyph), metrics_of(2, 2), four1, 4, &e), ERR_NONE, "font 1");
    }
    CHECK_ERR(cache_insert(&c, key_of(2, 1), metrics_of(2, 2), four2, 4, &e), ERR_NONE, "font 2 a");
    CHECK_ERR(cache_insert(&c, key_of(2, 2), metrics_of(2, 2), four2, 4, &e), ERR_NONE, "font 2 b");
    CHECK_EQ(cache_remove_font(&c, 1), 3, "three removed");
    CHECK(!lookup(&c, key_of(1, 1), &e), "removed glyph misses");
    CHECK(lookup(&c, key_of(2, 1), &e), "other font still hits");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.entries, 2, "two entries left");
    CHECK_EQ(s.removed, 3, "removed counter");
    cache_deinit(&c);
}

static void t_probe_chain(void) {
    begin("a removed entry does not hide the entries probed past it");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 1), ERR_NONE, "init");
    GlyphKey first = key_of(1, 1);
    size_t home = hash_key(first) & cache_mask(&c);
    uint32_t glyph = 2;
    GlyphKey second = key_of(2, glyph);
    while ((hash_key(second) & cache_mask(&c)) != home) {
        glyph++;
        second = key_of(2, glyph);
    }
    uint8_t seven = 7, eight = 8;
    Entry e;
    CHECK_ERR(cache_insert(&c, first, metrics_of(1, 1), &seven, 1, &e), ERR_NONE, "first");
    CHECK_ERR(cache_insert(&c, second, metrics_of(1, 1), &eight, 1, &e), ERR_NONE, "second");
    CHECK_EQ(cache_remove_font(&c, 1), 1, "one removed");
    CHECK(lookup(&c, second, &e), "second is still found past the tombstone");
    CHECK(!lookup(&c, first, &e), "first is gone");
    cache_deinit(&c);
}

static void t_growth(void) {
    begin("the table grows as entries are added, and every entry is still found afterwards");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    uint8_t coverage = 200;
    Entry e;
    for (uint32_t glyph = 0; glyph < 1000; glyph++) {
        CHECK_ERR(cache_insert(&c, key_of(7, glyph), metrics_of(1, 1), &coverage, 1, &e), ERR_NONE, "insert");
    }
    int all = 1;
    for (uint32_t glyph = 0; glyph < 1000; glyph++) {
        if (!lookup(&c, key_of(7, glyph), &e) || e.metrics.width != 1) all = 0;
    }
    CHECK(all, "all 1000 entries found after growth");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.entries, 1000, "1000 entries");
    CHECK_EQ(s.rehashes, 3, "three rehashes: 256 to 2048");
    cache_deinit(&c);
}

static void t_pending_overflow(void) {
    begin("more changed glyphs than the pending list holds mark their page for a full upload");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    uint8_t five = 5;
    Entry e;
    for (uint32_t glyph = 0; glyph < 600; glyph++) {
        CHECK_ERR(cache_insert(&c, key_of(1, glyph), metrics_of(1, 1), &five, 1, &e), ERR_NONE, "insert");
    }
    CHECK_EQ(c.pending_count, MAX_PENDING, "pending list is full");
    CHECK(c.pages[0].dirty_all, "page 0 needs a full upload");
    CHECK(!c.pages[1].dirty_all, "page 1 does not");
    cache_clear_pending(&c);
    CHECK_EQ(c.pending_count, 0, "pending cleared");
    CHECK(!c.pages[0].dirty_all, "page 0 flag cleared");
    cache_deinit(&c);
}

static void t_clear(void) {
    begin("clear empties the pages and marks every page for a full upload");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 2), ERR_NONE, "init");
    uint8_t nine[4] = { 9, 9, 9, 9 };
    Entry e;
    CHECK_ERR(cache_insert(&c, key_of(1, 1), metrics_of(2, 2), nine, 4, &e), ERR_NONE, "insert");
    cache_clear_pending(&c);
    cache_clear(&c);
    CHECK(!lookup(&c, key_of(1, 1), &e), "glyph gone after clear");
    CHECK_EQ(page_byte(&c, 0, (size_t)e.region.y * 32 + e.region.x), 0, "old texels zeroed");
    CHECK_EQ(page_byte(&c, 0, 0), 255, "white block back");
    CHECK(c.pages[0].dirty_all, "page 0 full upload");
    CHECK(c.pages[1].dirty_all, "page 1 full upload");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.pages_in_use, 1, "only page 0 (white) in use");
    CHECK_EQ(s.entries, 0, "no entries");
    cache_deinit(&c);
}

static void t_mark_all_dirty(void) {
    begin("markAllDirty queues every page and keeps the glyphs");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 2), ERR_NONE, "init");
    uint8_t nine[4] = { 9, 9, 9, 9 };
    Entry e;
    CHECK_ERR(cache_insert(&c, key_of(1, 1), metrics_of(2, 2), nine, 4, &e), ERR_NONE, "insert");
    cache_clear_pending(&c);
    cache_mark_all_dirty(&c);
    CHECK_EQ(c.pending_count, 0, "pending list empty");
    CHECK(c.pages[0].dirty_all && c.pages[1].dirty_all, "both pages need a full upload");
    CHECK(lookup(&c, key_of(1, 1), &e), "glyph kept");
    cache_deinit(&c);
}

static void t_missing(void) {
    begin("missing codepoints are counted");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 1), ERR_NONE, "init");
    c.stats.missing_codepoints += 2;
    CHECK_EQ(cache_snapshot(&c).missing_codepoints, 2, "two missing");
    cache_deinit(&c);
}

static void t_options(void) {
    begin("invalid options are refused before anything is allocated");
    Cache c;
    CHECK_ERR(cache_init(&c, 2, DEFAULT_PAGE_COUNT), ERR_INVALID_OPTIONS, "page_size 2 refused");
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, 0), ERR_INVALID_OPTIONS, "page_count 0 refused");
    CHECK_ERR(cache_init(&c, MAX_PAGE_SIZE + 1, DEFAULT_PAGE_COUNT), ERR_INVALID_OPTIONS, "too large refused");
}

static void t_size_bits(void) {
    begin("the pixel-height key is the float's bit pattern");
    uint32_t sixteen = size_bits_of(16.0f);
    uint32_t sixteen_and_half = size_bits_of(16.5f);
    CHECK_EQ(sixteen, 0x41800000u, "16.0 has the IEEE pattern");
    CHECK(sixteen != sixteen_and_half, "16 and 16.5 differ");
}

/* Model of Atlas.flush's GPU step. Atlas.flush needs a device, so no test can call it headless; this model follows
 * its order: gather each page, record the GPU regions unconditionally, then let plan_2d read the renderer flag. The
 * MUT_FLUSH_GATED build gates the GPU record on the flag, which is the bug this check exists to catch. */
static size_t gather_model(const Cache *c, uint32_t page) {
    if (c->pages[page].dirty_all) return 1;
    size_t n = 0;
    for (size_t i = 0; i < c->pending_count; i++) {
        if (c->pending[i].page == page) n++;
    }
    return n;
}

static size_t flush_model_gpu(const Cache *c, int sdl2d_active, size_t *syncs) {
    size_t gpu = 0;
    *syncs = 0;
    for (uint32_t page = 0; page < c->page_count; page++) {
        size_t count = gather_model(c, page);
#ifdef MUT_FLUSH_GATED
        if (sdl2d_active && count > 0) gpu += count;
#else
        gpu += count;
#endif
        if (plan_2d(sdl2d_active, 0, c->pages[page].used, count > 0) == ACT_SYNC_WHOLE_PAGE) (*syncs)++;
    }
    return gpu;
}

static void t_flush_gpu_independent(void) {
    begin("the GPU step records the same regions whichever renderer is active (flush model)");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 2), ERR_NONE, "init");
    uint8_t four[4] = { 9, 9, 9, 9 };
    Entry e;
    CHECK_ERR(cache_insert(&c, key_of(1, 1), metrics_of(2, 2), four, 4, &e), ERR_NONE, "insert");
    size_t syncs_gpu = 0, syncs_2d = 0;
    size_t gpu_off = flush_model_gpu(&c, 0, &syncs_gpu);
    size_t gpu_on = flush_model_gpu(&c, 1, &syncs_2d);
    CHECK_EQ(gpu_off, 2, "GPU mode: white block and the glyph are both recorded");
    CHECK_EQ(gpu_on, gpu_off, "2D mode records the same GPU regions as GPU mode");
    CHECK_EQ(syncs_gpu, 0, "GPU mode makes no 2D copy");
    CHECK_EQ(syncs_2d, 1, "2D mode makes one copy: page 0 is in use, page 1 is not");
    cache_deinit(&c);
}

static void t_gather(void) {
    begin("a page's changed regions are gathered once, and an unchanged page gathers nothing");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 2), ERR_NONE, "init");
    /* The white block is the only change so far: page 0 has one pending region, page 1 none. */
    CHECK_EQ(c.pending_count, 1, "page 0: one changed region");
    CHECK(c.pending[0].page == 0, "that region is on page 0");
    cache_clear_pending(&c);
    /* After a flush nothing is pending and nothing needs a full upload, so the next flush records nothing. */
    CHECK_EQ(c.pending_count, 0, "nothing gathered after the flush");
    CHECK(!c.pages[0].dirty_all && !c.pages[1].dirty_all, "no page flagged after the flush");
    cache_deinit(&c);
}

static void t_gather_stride(void) {
    begin("a glyph's region is gathered with the page stride, and a whole-page upload is one region");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 1), ERR_NONE, "init");
    uint8_t first[4] = { 1, 2, 3, 4 };
    uint8_t second[4] = { 5, 6, 7, 8 };
    Entry e;
    CHECK_ERR(cache_insert(&c, key_of(1, 1), metrics_of(2, 2), first, 4, &e), ERR_NONE, "first glyph");
    cache_clear_pending(&c);
    CHECK_ERR(cache_insert(&c, key_of(1, 2), metrics_of(2, 2), second, 4, &e), ERR_NONE, "second glyph");
    CHECK_EQ(c.pending_count, 1, "one changed region");
    CHECK_EQ(c.pending[0].w, 2, "region width");
    CHECK_EQ(c.pending[0].x, 6, "second glyph sits at x=6 after glyph one (3..4) and its padding (5)");
    /* The first texel of the region is pages[0][x + 0 * stride]; the stride is the page width, 32. */
    CHECK_EQ(page_byte(&c, 0, (size_t)c.pending[0].y * 32 + c.pending[0].x), 5, "first texel of the region");
    cache_clear_pending(&c);
    cache_mark_all_dirty(&c);
    CHECK(c.pages[0].dirty_all, "a whole-page upload is one region covering the page");
    CHECK_EQ(c.pending_count, 0, "the changed list is not used for a whole-page upload");
    cache_deinit(&c);
}

/* ---- tests for the new behavior (names match the Zig tests; see checks/glyph_cache_parity.txt) -- */

static void t_mode_default(void) {
    begin("a key without a mode is gray, and gray is the zero value, so a zeroed mode is gray");
    GlyphKey k = { 1, 1, size_bits_of(16.0f), RASTER_GRAY };
    CHECK_EQ(k.mode, RASTER_GRAY, "the explicit default is gray");
    CHECK_EQ(RASTER_GRAY, 0, "gray is zero");
    GlyphKey z;
    memset(&z, 0, sizeof z);
    CHECK_EQ(z.mode, RASTER_GRAY, "a zeroed key is gray");
    CHECK_EQ(key_of(1, 1).mode, RASTER_GRAY, "key_of is gray");
}

static void t_mode_keys(void) {
    begin("keys differ by rasterization mode, so gray and mono coverage of one glyph are two entries");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 1), ERR_NONE, "init");
    GlyphKey gray = { 1, 5, size_bits_of(16.0f), RASTER_GRAY };
    GlyphKey mono = gray;
    mono.mode = RASTER_MONO;
    uint8_t gray_cov[4] = { 1, 2, 3, 4 };
    uint8_t mono_cov[4] = { 5, 6, 7, 8 };
    Entry e, g, m;
    CHECK_ERR(cache_insert(&c, gray, metrics_of(2, 2), gray_cov, 4, &e), ERR_NONE, "gray insert");
    CHECK(!lookup(&c, mono, &e), "mono lookup misses before its insert");
    CHECK_ERR(cache_insert(&c, mono, metrics_of(2, 2), mono_cov, 4, &e), ERR_NONE, "mono insert");
    CHECK_EQ(cache_snapshot(&c).entries, 2, "two entries");
    CHECK(lookup(&c, gray, &g), "gray hits");
    CHECK(lookup(&c, mono, &m), "mono hits");
    CHECK_EQ(region_coverage(&c, g.region)[0], 1, "gray coverage");
    CHECK_EQ(region_coverage(&c, m.region)[0], 5, "mono coverage");
    cache_deinit(&c);
}

static void t_mode_collision(void) {
    begin("a gray and a mono key that share a probe chain stay apart");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 1), ERR_NONE, "init");
    size_t mask = cache_mask(&c);
    GlyphKey gray = { 1, 1, size_bits_of(16.0f), RASTER_GRAY };
    GlyphKey mono = gray;
    mono.mode = RASTER_MONO;
    /* Hashing includes the mode, so the two keys usually start in different buckets. Search for a glyph whose gray
     * and mono keys share a bucket. Only then does an equality check that ignores the mode show up. */
    uint32_t glyph = 1;
    for (; glyph < 100000u; glyph++) {
        gray.glyph = glyph;
        mono.glyph = glyph;
        if ((hash_key(gray) & mask) == (hash_key(mono) & mask)) break;
    }
    CHECK(glyph < 100000u, "a same-bucket pair exists");
    uint8_t cov[4] = { 1, 2, 3, 4 };
    Entry e, g;
    CHECK_ERR(cache_insert(&c, gray, metrics_of(2, 2), cov, 4, &e), ERR_NONE, "gray insert");
    CHECK(!lookup(&c, mono, &e), "mono misses in the gray key's probe chain");
    CHECK(lookup(&c, gray, &g), "gray still hits");
    cache_deinit(&c);
}

static void t_allocated_bytes(void) {
    begin("allocated bytes count the coverage pages and the lookup table");
    Cache c;
    CHECK_ERR(cache_init(&c, 32, 2), ERR_NONE, "init");
    size_t expected = 2 * 32 * 32 + INITIAL_SLOTS * sizeof(Slot);
    CHECK_EQ(cache_snapshot(&c).allocated_bytes, expected, "pages plus table, in this language's Slot size");
    cache_deinit(&c);
}

static void t_alloc_init(void) {
    begin("a failed allocation in init is reported, and init frees what it had already made");
    for (size_t fail_at = 0; fail_at < 3; fail_at++) {
        Cache c;
        alloc_plan(fail_at);
        CHECK_ERR(cache_init(&c, 32, 1), ERR_OOM, "a failing allocation is reported as OOM");
    }
    alloc_plan(SIZE_MAX);
}

static void t_alloc_growth(void) {
    begin("a lookup table that cannot grow refuses the insert and keeps the entries it has");
    Cache c;
    alloc_plan(3);
    CHECK_ERR(cache_init(&c, 1024, 1), ERR_NONE, "init makes three allocations");
    const uint32_t room = INITIAL_SLOTS * 3 / 4;
    uint8_t one[1] = { 7 };
    Entry e;
    for (uint32_t glyph = 1; glyph <= room; glyph++) {
        CHECK_ERR(cache_insert(&c, key_of(1, glyph), metrics_of(1, 1), one, 1, &e), ERR_NONE, "fill");
    }
    CHECK_ERR(cache_insert(&c, key_of(1, room + 1), metrics_of(1, 1), one, 1, &e), ERR_OOM, "growth refused");
    alloc_plan(SIZE_MAX);
    CHECK_EQ(cache_snapshot(&c).entries, room, "entries kept");
    CHECK_EQ(cache_snapshot(&c).rehashes, 0, "no rehash happened");
    CHECK(lookup(&c, key_of(1, room), &e), "last kept entry is found");
    CHECK(!lookup(&c, key_of(1, room + 1), &e), "refused entry is not stored");
    cache_deinit(&c);
}

static void t_resolve_repeat(void) {
    begin("a repeated request for a glyph finds it, and rasterizes it only once");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    Entry first, second;
    CHECK_ERR(resolve(&c, 1, &f, FAKE_A, RASTER_GRAY, &first), ERR_NONE, "first request");
    CHECK_ERR(resolve(&c, 1, &f, FAKE_A, RASTER_GRAY, &second), ERR_NONE, "second request");
    CHECK(region_eq(first.region, second.region), "same region both times");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.rasterized, 1, "one rasterization");
    CHECK_EQ(s.misses, 1, "one miss");
    CHECK_EQ(s.hits, 1, "one hit");
    CHECK_EQ(s.inserts, 1, "one insert");
    cache_deinit(&c);
}

static void t_resolve_empty(void) {
    begin("a glyph with an advance and no ink keeps its advance and takes no page space");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    size_t pending_before = c.pending_count;
    Entry e;
    CHECK_ERR(resolve(&c, 1, &f, FAKE_EMPTY, RASTER_GRAY, &e), ERR_NONE, "empty glyph resolves");
    Metrics want;
    CHECK_ERR(fake_metrics(&f, FAKE_EMPTY, &want), ERR_NONE, "font metrics");
    CHECK_EQ(e.region.w, 0, "no width in the atlas");
    CHECK_EQ(e.region.h, 0, "no height in the atlas");
    CHECK(e.metrics.advance == want.advance, "advance kept");
    CHECK_EQ(c.pending_count, pending_before, "nothing queued for upload");
    CHECK_EQ(cache_snapshot(&c).empty_glyphs, 1, "one empty glyph");
    cache_deinit(&c);
}

static void t_resolve_size_id(void) {
    begin("another size or another font id is a different entry and a separate rasterization");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    FakeFont f16 = { FAKE_GLYPH_COUNT, 16 };
    FakeFont f24 = { FAKE_GLYPH_COUNT, 24 };
    Entry e;
    CHECK_ERR(resolve(&c, 1, &f16, FAKE_A, RASTER_GRAY, &e), ERR_NONE, "font 1 at 16 px");
    CHECK_ERR(resolve(&c, 1, &f24, FAKE_A, RASTER_GRAY, &e), ERR_NONE, "font 1 at 24 px");
    CHECK_ERR(resolve(&c, 2, &f16, FAKE_A, RASTER_GRAY, &e), ERR_NONE, "font 2 at 16 px");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.rasterized, 3, "three rasterizations");
    CHECK_EQ(s.entries, 3, "three entries");
    cache_deinit(&c);
}

static void t_resolve_atlas_full(void) {
    begin("a glyph that does not fit the page is refused with AtlasFull, counted, and not stored");
    Cache c;
    CHECK_ERR(cache_init(&c, 12, 1), ERR_NONE, "a page 12 texels wide");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    Entry e;
    CHECK_ERR(resolve(&c, 1, &f, FAKE_A, RASTER_GRAY, &e), ERR_ATLAS_FULL, "A does not fit");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.rasterized, 1, "rasterized once");
    CHECK_EQ(s.cache_full, 1, "one cache_full");
    CHECK_EQ(s.entries, 0, "nothing stored");
    CHECK(!lookup(&c, key_of(1, FAKE_A), &e), "A is not cached");
    cache_deinit(&c);
}

static void t_resolve_out_of_range(void) {
    begin("a glyph ID past the last glyph of the font is refused before anything is stored");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    Entry e;
    CHECK_ERR(resolve(&c, 1, &f, f.glyph_count, RASTER_GRAY, &e), ERR_GLYPH_OUT_OF_RANGE, "past the end");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.rasterized, 0, "no rasterization");
    CHECK_EQ(s.entries, 0, "nothing stored");
    cache_deinit(&c);
}

static void t_resolve_alloc_fail(void) {
    begin("a failed allocation while rasterizing stores nothing and counts no rasterization");
    Cache c;
    alloc_plan(3);
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, 1), ERR_NONE, "init with one page makes three allocations");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    Entry e;
    CHECK_ERR(resolve(&c, 1, &f, FAKE_A, RASTER_GRAY, &e), ERR_OOM, "the coverage buffer is refused");
    alloc_plan(SIZE_MAX);
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.rasterized, 0, "no rasterization counted");
    CHECK_EQ(s.entries, 0, "nothing stored");
    cache_deinit(&c);
}

static void t_resolve_unsupported(void) {
    begin("an unsupported raster mode is refused before the cache is consulted");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    Entry e;
    CHECK_ERR(resolve(&c, 1, &f, FAKE_A, RASTER_MONO, &e), ERR_UNSUPPORTED_MODE, "mono is refused");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.hits, 0, "no hit counted");
    CHECK_EQ(s.misses, 0, "no miss counted");
    CHECK_EQ(s.rasterized, 0, "no rasterization");
    CHECK_EQ(s.entries, 0, "nothing stored");
    cache_deinit(&c);
}

static void t_mode_hits_misses(void) {
    begin("a mono entry of a glyph does not serve a gray request, and a gray entry does not serve mono");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    Entry gray, mono_entry, gray_again;
    CHECK_ERR(resolve(&c, 1, &f, FAKE_A, RASTER_GRAY, &gray), ERR_NONE, "gray request");
    GlyphKey mono_key = key_of(1, FAKE_A);
    mono_key.mode = RASTER_MONO;
    CHECK(!lookup(&c, mono_key, &mono_entry), "mono lookup misses");
    /* No mono rasterizer exists, so the mono entry is inserted by hand, as a future rasterizer would. */
    Metrics mm;
    CHECK_ERR(fake_metrics(&f, FAKE_A, &mm), ERR_NONE, "font metrics");
    uint8_t cov[121];
    fake_coverage(FAKE_A, mm.width, mm.height, cov);
    CHECK_ERR(cache_insert(&c, mono_key, mm, cov, 121, &mono_entry), ERR_NONE, "mono insert");
    CHECK(lookup(&c, mono_key, &mono_entry), "mono lookup hits");
    CHECK(!(mono_entry.region.x == gray.region.x && mono_entry.region.y == gray.region.y), "mono sits elsewhere");
    CHECK_ERR(resolve(&c, 1, &f, FAKE_A, RASTER_GRAY, &gray_again), ERR_NONE, "gray again");
    CHECK(region_eq(gray_again.region, gray.region), "gray again is the gray entry");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.misses, 2, "misses: first gray, first mono lookup");
    CHECK_EQ(s.hits, 2, "hits: mono lookup, second gray");
    CHECK_EQ(s.rasterized, 1, "one rasterization");
    CHECK_EQ(s.entries, 2, "two entries");
    cache_deinit(&c);
}

static void t_fallback_missing(void) {
    begin("a glyph past the end of the font draws the fallback glyph, counts one missing glyph, and stores nothing for it");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    Entry e;
    int sub = -1;
    CHECK_ERR(resolve_with_fallback(&c, 1, &f, f.glyph_count, FAKE_A, RASTER_GRAY, &e, &sub), ERR_NONE, "fallback resolves");
    CHECK_EQ(sub, 1, "the entry is a substitute");
    Entry direct;
    CHECK_ERR(resolve(&c, 1, &f, FAKE_A, RASTER_GRAY, &direct), ERR_NONE, "direct request");
    CHECK(region_eq(e.region, direct.region), "the fallback entry is the A entry");
    CHECK(e.metrics.advance == direct.metrics.advance, "same advance");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.missing_glyphs, 1, "one missing glyph");
    CHECK_EQ(s.rasterized, 1, "only the fallback is rasterized");
    CHECK_EQ(s.entries, 1, "only the fallback is stored");
    cache_deinit(&c);
}

static void t_fallback_in_range(void) {
    begin("a glyph inside the font is drawn as itself, and is not counted as missing");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    Entry e;
    int sub = -1;
    CHECK_ERR(resolve_with_fallback(&c, 1, &f, FAKE_A, 0, RASTER_GRAY, &e, &sub), ERR_NONE, "in-range resolves");
    CHECK_EQ(sub, 0, "not a substitute");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.missing_glyphs, 0, "no missing glyph");
    CHECK_EQ(s.rasterized, 1, "one rasterization");
    CHECK_EQ(s.entries, 1, "one entry");
    cache_deinit(&c);
}

static void t_fallback_both_missing(void) {
    begin("a missing glyph whose fallback is also missing fails, counts the miss, and stores nothing");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    Entry e;
    int sub = -1;
    CHECK_ERR(resolve_with_fallback(&c, 1, &f, f.glyph_count, f.glyph_count, RASTER_GRAY, &e, &sub),
              ERR_GLYPH_OUT_OF_RANGE, "both missing");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.missing_glyphs, 1, "the miss is counted");
    CHECK_EQ(s.rasterized, 0, "no rasterization");
    CHECK_EQ(s.entries, 0, "nothing stored");
    cache_deinit(&c);
}

static void t_fallback_unsupported(void) {
    begin("an unsupported mode is refused by the fallback path before any miss is counted");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    Entry e;
    int sub = -1;
    CHECK_ERR(resolve_with_fallback(&c, 1, &f, f.glyph_count, FAKE_A, RASTER_MONO, &e, &sub), ERR_UNSUPPORTED_MODE,
              "mono refused");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.missing_glyphs, 0, "no missing glyph counted");
    CHECK_EQ(s.misses, 0, "no miss counted");
    CHECK_EQ(s.rasterized, 0, "no rasterization");
    cache_deinit(&c);
}

static void t_consistency(void) {
    begin("the resolved metrics match the font, and the cache entry and its pending upload agree with them");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    Entry e;
    CHECK_ERR(resolve(&c, 1, &f, FAKE_A, RASTER_GRAY, &e), ERR_NONE, "resolve A");
    Metrics m;
    CHECK_ERR(fake_metrics(&f, FAKE_A, &m), ERR_NONE, "font metrics");
    CHECK(e.metrics.advance == m.advance, "advance matches the font");
    CHECK(e.metrics.xoff == m.xoff, "xoff matches the font");
    CHECK(e.metrics.yoff == m.yoff, "yoff matches the font");
    CHECK_EQ(e.metrics.width, m.width, "width matches the font");
    CHECK_EQ(e.metrics.height, m.height, "height matches the font");
    CHECK_EQ(e.region.w, m.width, "the region is the ink width");
    CHECK_EQ(e.region.h, m.height, "the region is the ink height");
    Entry found;
    CHECK(lookup(&c, key_of(1, FAKE_A), &found), "a later lookup finds the entry");
    CHECK(region_eq(found.region, e.region), "the lookup returns the same region");
    int queued = 0;
    for (size_t i = 0; i < c.pending_count; i++) {
        if (region_eq(c.pending[i], e.region)) queued = 1;
    }
    CHECK(queued, "the next flush uploads that rectangle");
    uint8_t want[121];
    fake_coverage(FAKE_A, m.width, m.height, want);
    int same = 1;
    for (uint32_t row = 0; row < e.region.h; row++) {
        for (uint32_t col = 0; col < e.region.w; col++) {
            if (region_coverage(&c, e.region)[row * c.page_size + col] != want[row * e.region.w + col]) same = 0;
        }
    }
    CHECK(same, "stored texels equal the rasterized coverage, row by row");
    cache_deinit(&c);
}

static void t_glyph_zero(void) {
    begin("glyph 0 is valid: it is drawn as itself, is cached like any glyph, and is never counted as missing");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    Entry e;
    int sub = -1;
    CHECK_ERR(resolve_with_fallback(&c, 1, &f, 0, FAKE_A, RASTER_GRAY, &e, &sub), ERR_NONE, "glyph 0 resolves");
    CHECK_EQ(sub, 0, "glyph 0 is not a substitute");
    Metrics m;
    CHECK_ERR(fake_metrics(&f, 0, &m), ERR_NONE, "font metrics for glyph 0");
    CHECK(e.metrics.advance == m.advance, "glyph 0 keeps its own advance");
    CHECK_ERR(resolve(&c, 1, &f, 0, RASTER_GRAY, &e), ERR_NONE, "second request for glyph 0");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.missing_glyphs, 0, "glyph 0 is never counted as missing");
    CHECK_EQ(s.rasterized, 1, "glyph 0 is rasterized once");
    CHECK_EQ(s.misses, 1, "one miss");
    CHECK_EQ(s.hits, 1, "the second request hits");
    cache_deinit(&c);
}

static void t_glyph_boundary(void) {
    begin("the last glyph is valid, and the glyph after it is missing, at the font's glyph count");
    Cache c;
    CHECK_ERR(cache_init(&c, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_COUNT), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    Entry e;
    int sub = -1;
    uint32_t last = f.glyph_count - 1;
    CHECK_ERR(resolve_with_fallback(&c, 1, &f, last, FAKE_A, RASTER_GRAY, &e, &sub), ERR_NONE, "last glyph resolves");
    CHECK_EQ(sub, 0, "the last glyph is not a substitute");
    CHECK_ERR(resolve_with_fallback(&c, 1, &f, f.glyph_count, FAKE_A, RASTER_GRAY, &e, &sub), ERR_NONE,
              "the glyph after it resolves to the fallback");
    CHECK_EQ(sub, 1, "the glyph after the last is a substitute");
    CHECK_EQ(cache_snapshot(&c).missing_glyphs, 1, "exactly one missing glyph");
    cache_deinit(&c);
}

static void t_warm_run(void) {
    begin("warming a run of glyphs caches each one, so a later resolve of any of them is a hit and rasterizes nothing");
    Cache c;
    CHECK_ERR(cache_init(&c, 1024, 4), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    const uint32_t run[] = { FAKE_A, FAKE_V, FAKE_T, FAKE_A };
    WarmStats w;
    CHECK_ERR(warm(&c, 1, &f, run, 4, FAKE_A, RASTER_GRAY, &w), ERR_NONE, "warm the run");
    CHECK_EQ(w.rasterized, 3, "three glyphs rasterized");
    CHECK_EQ(w.already_cached, 1, "the repeated A is already cached");
    CHECK_EQ(w.substituted, 0, "no fallback used");
    Entry e;
    for (size_t i = 0; i < 3; i++) {
        CHECK_ERR(resolve(&c, 1, &f, run[i], RASTER_GRAY, &e), ERR_NONE, "resolve after warm-up");
    }
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.rasterized, 3, "no rasterization after warm-up");
    CHECK_EQ(s.misses, 3, "three misses, all in warm-up");
    CHECK_EQ(s.hits, 4, "one hit in warm-up, three after");
    cache_deinit(&c);
}

static void t_warm_stops(void) {
    begin("warming stops at the first refused glyph and reports how far it got");
    Cache c;
    /* A page of 8 texels takes no glyph wider or taller than 7, so glyph 36 (11 by 11) is refused. */
    CHECK_ERR(cache_init(&c, 8, 1), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    const uint32_t run[] = { FAKE_EMPTY, FAKE_A, FAKE_V };
    WarmStats w;
    CHECK_ERR(warm(&c, 1, &f, run, 3, FAKE_A, RASTER_GRAY, &w), ERR_GLYPH_TOO_LARGE, "the warm-up stops at A");
    CHECK_EQ(w.rasterized, 1, "only the empty glyph was cached");
    CHECK_EQ(w.already_cached, 0, "none was already cached");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.rasterized, 2, "A was rasterized, then refused by the insert");
    CHECK_EQ(s.entries, 1, "one entry stored");
    CHECK_EQ(s.too_large, 1, "one glyph too large");
    CHECK_EQ(s.misses, 2, "V was never looked up");
    cache_deinit(&c);
}

static void t_warm_mode(void) {
    begin("warming refuses an unsupported mode before anything is cached");
    Cache c;
    CHECK_ERR(cache_init(&c, 1024, 4), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    const uint32_t run[] = { FAKE_A, FAKE_V };
    WarmStats w;
    CHECK_ERR(warm(&c, 1, &f, run, 2, FAKE_A, RASTER_MONO, &w), ERR_UNSUPPORTED_MODE, "mono is refused");
    CHECK_EQ(w.rasterized, 0, "nothing rasterized");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.misses, 0, "no lookup was counted");
    CHECK_EQ(s.rasterized, 0, "no rasterization");
    CHECK_EQ(s.entries, 0, "nothing stored");
    cache_deinit(&c);
}

static void t_warm_fallback(void) {
    begin("warming substitutes the fallback for glyphs past the end, counts each, and stores nothing for them");
    Cache c;
    CHECK_ERR(cache_init(&c, 1024, 4), ERR_NONE, "init");
    FakeFont f = { FAKE_GLYPH_COUNT, 16 };
    const uint32_t run[] = { FAKE_GLYPH_COUNT, FAKE_A, FAKE_GLYPH_COUNT + 5 };
    WarmStats w;
    CHECK_ERR(warm(&c, 1, &f, run, 3, FAKE_A, RASTER_GRAY, &w), ERR_NONE, "warm-up with missing glyphs");
    CHECK_EQ(w.rasterized, 1, "the fallback was rasterized once");
    CHECK_EQ(w.already_cached, 2, "the direct A and the third fallback were already cached");
    CHECK_EQ(w.substituted, 2, "two requests drew the fallback");
    Stats s = cache_snapshot(&c);
    CHECK_EQ(s.missing_glyphs, 2, "two missing glyphs counted");
    CHECK_EQ(s.entries, 1, "the missing glyphs were not stored");
    cache_deinit(&c);
}

int main(void) {
    t_white_block();
    t_hit_miss();
    t_rows_copied();
    t_empty_glyph();
    t_keys();
    t_shelf_wrap();
    t_full_pages();
    t_too_large();
    t_bad_bitmap();
    t_remove_font();
    t_probe_chain();
    t_growth();
    t_pending_overflow();
    t_clear();
    t_mark_all_dirty();
    t_missing();
    t_options();
    t_size_bits();
    t_plan_2d();
    t_gather();
    t_gather_stride();
    t_flush_gpu_independent();
    t_mode_default();
    t_mode_keys();
    t_mode_collision();
    t_allocated_bytes();
    t_alloc_init();
    t_alloc_growth();
    t_resolve_repeat();
    t_resolve_empty();
    t_resolve_size_id();
    t_resolve_atlas_full();
    t_resolve_out_of_range();
    t_resolve_alloc_fail();
    t_resolve_unsupported();
    t_mode_hits_misses();
    t_fallback_missing();
    t_fallback_in_range();
    t_fallback_both_missing();
    t_fallback_unsupported();
    t_consistency();
    t_glyph_zero();
    t_glyph_boundary();
    t_warm_run();
    t_warm_stops();
    t_warm_mode();
    t_warm_fallback();
    printf("\n%d checks, %d failures\n", checks, failures);
    if (failures != 0) {
        printf("FAILED\n");
        return 1;
    }
    printf("PASSED\n");
    return 0;
}
