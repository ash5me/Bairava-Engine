/*
 * Mirror of src/engine/text/glyph_cache.zig (Phase 3 of the rendering migration plan, 2026-11-17).
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
typedef struct { uint32_t font, glyph, size_bits; } GlyphKey;
typedef struct { Metrics metrics; Region region; } Entry;
typedef struct {
    uint64_t hits, misses, inserts, empty_glyphs, cache_full, too_large;
    uint64_t missing_codepoints, removed, rehashes;
    uint32_t pages_in_use, entries;
} Stats;

typedef enum { ERR_NONE = 0, ERR_GLYPH_TOO_LARGE, ERR_ATLAS_FULL, ERR_INVALID_BITMAP, ERR_INVALID_OPTIONS, ERR_OOM } Err;
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
    GlyphKey k = { font, glyph, size_bits_of(16.0f) };
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
    return (size_t)h;
}

static int same_key(GlyphKey a, GlyphKey b) {
    return a.font == b.font && a.glyph == b.glyph && a.size_bits == b.size_bits;
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
    c->pages = calloc(page_count, sizeof(Page));
    if (!c->pages) return ERR_OOM;
    size_t texels = (size_t)page_size * page_size;
    for (size_t i = 0; i < page_count; i++) {
        c->pages[i].pixels = calloc(texels, 1);
        if (!c->pages[i].pixels) {
            for (size_t j = 0; j < i; j++) free(c->pages[j].pixels);
            free(c->pages);
            return ERR_OOM;
        }
    }
    c->slot_len = INITIAL_SLOTS;
    c->slots = calloc(c->slot_len, sizeof(Slot));
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
    Slot *fresh = calloc(new_len, sizeof(Slot));
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
    return s;
}

static const uint8_t *region_coverage(const Cache *c, Region r) {
    size_t start = (size_t)r.y * c->page_size + r.x;
    return c->pages[r.page].pixels + start;
}

static uint8_t page_byte(const Cache *c, uint32_t page, size_t index) {
    return c->pages[page].pixels[index];
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
    GlyphKey other_size = { 1, 1, size_bits_of(17.0f) };
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
    printf("\n%d checks, %d failures\n", checks, failures);
    if (failures != 0) {
        printf("FAILED\n");
        return 1;
    }
    printf("PASSED\n");
    return 0;
}
