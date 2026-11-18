/*
 * Mirror of src/engine/text/font_registry.zig (Phase 1, decisions D-01 and D-02 of the text and font system
 * migration plan). Each function follows its Zig counterpart line for line: issue(), Registry.insert, get, remove,
 * and indexOf. Each named check uses the same values as the matching Zig test (see font_registry_RESULTS.txt).
 *
 * It does NOT compile the Zig. Its checks cover the control flow and the id rules under AddressSanitizer and UBSan.
 * The owner's `zig build test` is the first real check of the Zig.
 *
 * It also runs a model-based random test: a reference model of live and removed handles is checked against the
 * registry over many random operations, including allocation failures on insert.
 *
 * Mutation builds: define one MUT_* macro to plant a bug. The run must then fail.
 *
 *   gcc -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
 *       checks/font_registry_mirror.c -o font_registry_mirror
 */
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint64_t font_id_t;
#define INVALID_FONT_ID ((font_id_t)0)
#define FONT_ID_MAX (UINT64_MAX)

typedef enum { ST_OK = 0, ST_INVALID, ST_STALE, ST_EXHAUSTED, ST_OOM } status_t;

typedef struct {
    font_id_t id;
    uint32_t value;
} entry_t;

typedef struct {
    font_id_t id;
} handle_t;

typedef struct {
    entry_t *items;
    size_t count;
    size_t cap;
    font_id_t next_id;
    int fail_next_insert; /* test hook: the next insert's table growth fails, after its id is issued */
} registry_t;

static handle_t handle_invalid(void) {
    handle_t h = { INVALID_FONT_ID };
    return h;
}

/* Returns the id at *next and advances it. At the top of the range it fails and leaves *next unchanged. */
static status_t issue(font_id_t *next, font_id_t *out) {
    font_id_t id = *next;
#ifdef MUT_WRAP
    if (id == FONT_ID_MAX) { /* wrap back to 1: reissues an id already handed out */
        *next = 2;
        *out = 1;
        return ST_OK;
    }
#else
    if (id == FONT_ID_MAX) return ST_EXHAUSTED;
#endif
    *next = id + 1;
    *out = id;
    return ST_OK;
}

static void registry_init(registry_t *r) {
    memset(r, 0, sizeof *r);
#ifdef MUT_ZERO_ISSUED
    r->next_id = 0; /* zero is issued: the invalid id names a real font */
#else
    r->next_id = 1;
#endif
}

static void registry_deinit(registry_t *r) {
    free(r->items);
    memset(r, 0, sizeof *r);
}

static status_t registry_insert(registry_t *r, uint32_t value, handle_t *out) {
    font_id_t id;
    if (issue(&r->next_id, &id) != ST_OK) return ST_EXHAUSTED;
    if (r->fail_next_insert) { /* append fails after the id is issued: the id stays spent */
        r->fail_next_insert = 0;
        return ST_OOM;
    }
    if (r->count == r->cap) {
        size_t cap = r->cap ? r->cap * 2 : 4;
        entry_t *grown = realloc(r->items, cap * sizeof *grown);
        if (grown == NULL) return ST_OOM;
        r->items = grown;
        r->cap = cap;
    }
    r->items[r->count].id = id;
    r->items[r->count].value = value;
    r->count++;
    out->id = id;
    return ST_OK;
}

/* Mirror of Registry.indexOf. Never-issued ids are INVALID; issued ids with no live entry are STALE. */
static status_t index_of(const registry_t *r, handle_t h, size_t *index) {
    if (h.id == INVALID_FONT_ID) return ST_INVALID;
#ifdef MUT_INVALID_IS_STALE
    if (h.id >= r->next_id) return ST_STALE;
#else
    if (h.id >= r->next_id) return ST_INVALID;
#endif
    size_t i;
    for (i = 0; i < r->count; i++) {
        if (r->items[i].id == h.id) {
            *index = i;
            return ST_OK;
        }
    }
#ifdef MUT_STALE_IS_INVALID
    return ST_INVALID;
#else
    return ST_STALE;
#endif
}

static status_t registry_get(const registry_t *r, handle_t h, uint32_t *value) {
    size_t index = 0;
    status_t s = index_of(r, h, &index);
    if (s != ST_OK) return s;
    *value = r->items[index].value;
    return ST_OK;
}

/* Mirror of Registry.remove: swap-remove, returning the value the caller now owns. */
static status_t registry_remove(registry_t *r, handle_t h, uint32_t *value) {
    size_t index = 0;
    status_t s = index_of(r, h, &index);
    if (s != ST_OK) return s;
    *value = r->items[index].value;
    r->items[index] = r->items[r->count - 1];
    r->count--;
#ifdef MUT_REUSE_ID
    if (h.id == r->next_id - 1) r->next_id = h.id; /* reclaims the last id: a later insert reissues it */
#endif
    return ST_OK;
}

/* ---- checks ----------------------------------------------------------- */

static int checks_run = 0;
static int checks_failed = 0;

#define CHECK(cond, name)                                                 \
    do {                                                                  \
        checks_run++;                                                     \
        if (!(cond)) {                                                    \
            checks_failed++;                                              \
            printf("  FAIL: %s  (line %d)\n", (name), __LINE__);          \
        }                                                                 \
    } while (0)

/* Zig test: "the first id issued is 1, and zero is never issued" */
static void test_first_id_is_one(void) {
    font_id_t next = 1, id = 0;
    CHECK(issue(&next, &id) == ST_OK, "first issue succeeds");
    CHECK(id == 1, "the first id issued is 1");
    CHECK(next == 2, "the counter advances to 2");
    CHECK(INVALID_FONT_ID == 0, "the invalid id is zero");
    registry_t r;
    registry_init(&r);
    CHECK(r.next_id == 1, "a fresh registry starts issuing at 1");
    registry_deinit(&r);
}

/* Zig test: "exhaustion fails at the top of the range and leaves the counter where it was" */
static void test_exhaustion_at_top(void) {
    font_id_t next = FONT_ID_MAX - 1, id = 0;
    CHECK(issue(&next, &id) == ST_OK && id == FONT_ID_MAX - 1, "the second-to-last id is issued");
    CHECK(next == FONT_ID_MAX, "the counter reaches the top");
    CHECK(issue(&next, &id) == ST_EXHAUSTED, "issuing at the top fails with exhaustion");
    CHECK(issue(&next, &id) == ST_EXHAUSTED, "a second issue also fails");
    CHECK(next == FONT_ID_MAX, "the counter stays at the top and does not wrap");
}

/* Zig test: "an inserted value is found by its handle" */
static void test_insert_then_get(void) {
    registry_t r;
    registry_init(&r);
    handle_t a, b;
    uint32_t v = 0;
    CHECK(registry_insert(&r, 10, &a) == ST_OK, "insert a");
    CHECK(registry_insert(&r, 20, &b) == ST_OK, "insert b");
    CHECK(a.id != b.id, "two inserts get distinct ids");
    CHECK(registry_get(&r, a, &v) == ST_OK && v == 10, "get a returns 10");
    CHECK(registry_get(&r, b, &v) == ST_OK && v == 20, "get b returns 20");
    CHECK(r.count == 2, "the registry holds two entries");
    registry_deinit(&r);
}

/* Zig test: "the invalid handle, and an id never issued, are InvalidHandle" */
static void test_invalid_handles(void) {
    registry_t r;
    registry_init(&r);
    handle_t a;
    uint32_t v = 0;
    registry_insert(&r, 1, &a);
    handle_t never = { 99 };
    CHECK(registry_get(&r, handle_invalid(), &v) == ST_INVALID, "the invalid handle is INVALID on get");
    CHECK(registry_get(&r, never, &v) == ST_INVALID, "an id past next_id is INVALID on get");
    CHECK(registry_remove(&r, handle_invalid(), &v) == ST_INVALID, "the invalid handle is INVALID on remove");
    registry_deinit(&r);
}

/* Zig test: "a removed font's handle is stale, and removing it again is stale" */
static void test_removed_is_stale(void) {
    registry_t r;
    registry_init(&r);
    handle_t h;
    uint32_t v = 0;
    registry_insert(&r, 7, &h);
    CHECK(registry_remove(&r, h, &v) == ST_OK && v == 7, "remove returns the value");
    CHECK(registry_get(&r, h, &v) == ST_STALE, "a removed handle is STALE on get");
    CHECK(registry_remove(&r, h, &v) == ST_STALE, "removing again is STALE");
    CHECK(r.count == 0, "the registry is empty after removal");
    registry_deinit(&r);
}

/* Zig test: "a removed id is never issued again" */
static void test_removed_id_not_reissued(void) {
    registry_t r;
    registry_init(&r);
    handle_t old, fresh;
    uint32_t v = 0;
    registry_insert(&r, 1, &old);
    registry_remove(&r, old, &v);
    registry_insert(&r, 2, &fresh);
    CHECK(fresh.id != old.id, "the id after a removal is new");
    CHECK(registry_get(&r, old, &v) == ST_STALE, "the old handle stays STALE");
    CHECK(registry_get(&r, fresh, &v) == ST_OK && v == 2, "the fresh handle returns 2");
    registry_deinit(&r);
}

/* Zig test: "removing one font leaves the other handles valid" */
static void test_remove_middle_keeps_others(void) {
    registry_t r;
    registry_init(&r);
    handle_t a, b, c;
    uint32_t v = 0;
    registry_insert(&r, 1, &a);
    registry_insert(&r, 2, &b);
    registry_insert(&r, 3, &c);
    registry_remove(&r, b, &v);
    CHECK(registry_get(&r, a, &v) == ST_OK && v == 1, "a stays valid after b is removed");
    CHECK(registry_get(&r, c, &v) == ST_OK && v == 3, "c stays valid after b is removed");
    CHECK(registry_get(&r, b, &v) == ST_STALE, "b is STALE");
    registry_deinit(&r);
}

/* Zig test: "a registry at the top of the id range refuses insert without wrapping" */
static void test_insert_at_top(void) {
    registry_t r;
    registry_init(&r);
    r.next_id = FONT_ID_MAX - 1;
    handle_t last, refused;
    uint32_t v = 0;
    CHECK(registry_insert(&r, 5, &last) == ST_OK, "the last id can be inserted");
    CHECK(last.id == FONT_ID_MAX - 1, "its id is the second-to-last value");
    CHECK(registry_insert(&r, 6, &refused) == ST_EXHAUSTED, "insert past the top is refused");
    CHECK(r.count == 1, "the refused insert stores nothing");
    CHECK(registry_get(&r, last, &v) == ST_OK && v == 5, "the stored value is still reachable");
    registry_deinit(&r);
}

/* Not a Zig test: the D-02 rule that an insert whose table growth fails still spends its id. */
static void test_oom_spends_id(void) {
    registry_t r;
    registry_init(&r);
    handle_t failed, ok;
    r.fail_next_insert = 1;
    CHECK(registry_insert(&r, 1, &failed) == ST_OOM, "the injected allocation failure is reported");
    CHECK(r.count == 0, "a failed insert stores nothing");
    CHECK(r.next_id == 2, "the failed insert still spent id 1");
    CHECK(registry_insert(&r, 2, &ok) == ST_OK, "the next insert succeeds");
    CHECK(ok.id == 2, "the next insert gets id 2, not the spent id");
    registry_deinit(&r);
}

/* ---- model-based random test ------------------------------------------ */

static uint64_t rng_state = 0x9E3779B97F4A7C15ull;
static uint64_t rng_next(void) {
    /* xorshift64*: deterministic, so a failure reproduces. */
    rng_state ^= rng_state >> 12;
    rng_state ^= rng_state << 25;
    rng_state ^= rng_state >> 27;
    return rng_state * 2685821657736338717ull;
}

#define MODEL_CAP 4096
typedef struct {
    font_id_t id;
    uint32_t value;
} live_t;

static void test_random_model(size_t operations) {
    registry_t r;
    registry_init(&r);
    live_t *live = calloc(MODEL_CAP, sizeof *live);
    font_id_t *dead = calloc(MODEL_CAP, sizeof *dead);
    size_t n_live = 0, n_dead = 0;
    size_t i;
    uint64_t bad = 0;

    if (live == NULL || dead == NULL) {
        printf("  FAIL: model allocation\n");
        checks_failed++;
        free(live);
        free(dead);
        registry_deinit(&r);
        return;
    }

    for (i = 0; i < operations; i++) {
        uint64_t roll = rng_next() % 100;
        if (roll < 35 && n_live < MODEL_CAP - 1) {
            /* insert, sometimes with an injected allocation failure */
            font_id_t before = r.next_id;
            uint32_t value = (uint32_t)rng_next();
            handle_t h;
            if (rng_next() % 16 == 0) r.fail_next_insert = 1;
            status_t s = registry_insert(&r, value, &h);
            if (s == ST_OK) {
                if (!(h.id >= before && h.id < r.next_id)) bad++;      /* id comes from the counter */
                if (h.id == INVALID_FONT_ID) bad++;                    /* zero is never issued */
                live[n_live].id = h.id;
                live[n_live].value = value;
                n_live++;
            } else if (s == ST_OOM) {
                if (r.next_id != before + 1) bad++;                    /* the failed id is spent */
            } else {
                bad++;
            }
        } else if (roll < 55 && n_live > 0) {
            /* remove a live font: the value comes back and the handle goes stale */
            size_t k = (size_t)(rng_next() % n_live);
            handle_t h = { live[k].id };
            uint32_t v = 0;
            if (registry_remove(&r, h, &v) != ST_OK || v != live[k].value) bad++;
            if (n_dead < MODEL_CAP) dead[n_dead++] = live[k].id;
            live[k] = live[n_live - 1];
            n_live--;
        } else if (roll < 80 && n_live > 0) {
            /* get a live font: the stored value comes back */
            size_t k = (size_t)(rng_next() % n_live);
            handle_t h = { live[k].id };
            uint32_t v = 0;
            if (registry_get(&r, h, &v) != ST_OK || v != live[k].value) bad++;
        } else if (roll < 90 && n_dead > 0) {
            /* get a removed font: it must stay STALE forever */
            size_t k = (size_t)(rng_next() % n_dead);
            handle_t h = { dead[k] };
            uint32_t v = 0;
            if (registry_get(&r, h, &v) != ST_STALE) bad++;
            if (registry_remove(&r, h, &v) != ST_STALE) bad++;
        } else {
            /* the invalid id, and ids past the counter, are INVALID */
            uint32_t v = 0;
            if (registry_get(&r, handle_invalid(), &v) != ST_INVALID) bad++;
            handle_t beyond = { r.next_id + (font_id_t)(rng_next() % 1000) };
            if (registry_get(&r, beyond, &v) != ST_INVALID) bad++;
        }
        if (r.count != n_live) bad++;
    }

    CHECK(bad == 0, "random model: every operation matches the reference model");
    printf("  random model: %zu operations, %llu mismatches, %zu live, %zu removed\n",
           operations, (unsigned long long)bad, n_live, n_dead);

    free(live);
    free(dead);
    registry_deinit(&r);
}

int main(void) {
    printf("font_registry mirror: Phase 1 contract (D-01, D-02)\n");
    test_first_id_is_one();
    test_exhaustion_at_top();
    test_insert_then_get();
    test_invalid_handles();
    test_removed_is_stale();
    test_removed_id_not_reissued();
    test_remove_middle_keeps_others();
    test_insert_at_top();
    test_oom_spends_id();
    test_random_model(200000);
    test_random_model(200000);
    printf("\n%d checks, %d failures\n", checks_run, checks_failed);
    printf(checks_failed == 0 ? "PASSED\n" : "FAILED\n");
    return checks_failed == 0 ? 0 : 1;
}
