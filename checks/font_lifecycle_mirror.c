/*
 * Mirror of the font ownership paths, for the lifecycle checks in src/engine/text/font_store.zig and
 * src/engine/text/font_lifecycle_test.zig. Each function follows its Zig counterpart line for line:
 *
 *   store_create_with_release   font_store.zig: createWithRelease
 *   store_insert                font_store.zig: insertBfnt, over font_registry.zig's Registry.insert
 *   store_destroy, store_discard font_store.zig: destroy and discard, over Registry.deinitWith and deinit
 *   canvas_*, ui_*              ui.zig: Canvas.create and deinit, Ui.init and deinit
 *   session_stop                core/lifecycle.zig: the font step and the device teardown of stop
 *
 * It does NOT compile the Zig. A font's atlas is a real heap block here, so a release that never happens shows as a
 * leak under LeakSanitizer. The release counters check the same rules without the sanitizers. The owner's
 * `zig build test` is the first real check of the Zig.
 *
 * Each check prints PASS or FAIL. The program exits nonzero if any check fails.
 *
 * Mutation builds: define one MUT_* macro to plant a bug. The run must then fail.
 *
 *   gcc -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
 *       checks/font_lifecycle_mirror.c -o font_lifecycle_mirror
 *   gcc ...same flags... -DMUT_INSERT_NO_RELEASE   -o m1 && ./m1    (a failed insert keeps the font)
 *
 * Mutants: MUT_INSERT_NO_RELEASE, MUT_INSERT_RELEASES_ON_SUCCESS, MUT_DESTROY_SKIPS_RELEASE,
 * MUT_DESTROY_RELEASES_TWICE, MUT_CANVAS_RELEASES, MUT_UI_RELEASES, MUT_STOP_DEVICE_FIRST, MUT_STOP_SKIPS_FONTS.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint64_t font_id_t;
#define INVALID_FONT_ID ((font_id_t)0)
#define FONT_ID_MAX (UINT64_MAX)

/* A font as the store holds it. The atlas is the GPU-side block the destructor frees. */
typedef struct {
    int line_height; /* the font's marker in these checks */
    unsigned char *atlas;
    int released;    /* set by the destructor, so a second release is seen and not freed twice */
} font_t;

typedef void (*release_fn)(font_t *);

/* ---- instrumented destructor: stands in for FontResource.deinit ---- */

#define MARKERS 64 /* the checks use markers up to 51 */
static int release_total;
static int release_by_marker[MARKERS];
static int double_release;
static int released_with_gpu_dead;
static int gpu_alive;

typedef enum { STEP_WAIT_IDLE, STEP_FONT_RELEASE, STEP_DEVICE_DEINIT, STEP_WRONG_DEVICE } step_t;
static step_t steps[64];
static size_t step_count;
static void record(step_t s) { steps[step_count++] = s; }

static void release_counted(font_t *f) {
    if (f->released) {
        double_release++;
        return;
    }
    f->released = 1;
    release_total++;
    release_by_marker[f->line_height]++;
    if (!gpu_alive) released_with_gpu_dead++;
    record(STEP_FONT_RELEASE);
    free(f->atlas);
    f->atlas = NULL;
}

/* ---- the store and its registry (font_store.zig, font_registry.zig) ---- */

#define MAX_ENTRIES 8

typedef struct {
    font_id_t id;
    font_t *slot; /* heap, owned by the registry */
} entry_t;

typedef struct {
    release_fn release;
    font_id_t next_id;
    size_t count;
    entry_t entries[MAX_ENTRIES];
} store_t;

typedef enum { ST_OK = 0, ST_OOM, ST_EXHAUSTED } status_t;

/* Allocation accounting, in the order the Zig code allocates. A check sets fail_index to fail that allocation, the
 * way std.testing.FailingAllocator does. Allocation 0 is the store's own State. */
static long alloc_index;
static long fail_index;
static int alloc_ok(void) {
    long i = alloc_index++;
    return i != fail_index;
}

/* createWithRelease: allocator.create(State), then the empty registry. */
static store_t *store_create_with_release(release_fn release) {
    if (!alloc_ok()) return NULL;
    store_t *s = calloc(1, sizeof *s);
    if (!s) abort();
    s->release = release;
    s->next_id = 1;
    return s;
}

/* Registry.insert: issue, then the slot allocation, then the append. The value is copied in. On failure the store
 * keeps nothing, so the caller still owns the value. */
static status_t registry_insert(store_t *s, font_t value, font_id_t *out_id) {
    font_id_t id = s->next_id;
    if (id == FONT_ID_MAX) return ST_EXHAUSTED; /* issue: the counter is not advanced */
    s->next_id = id + 1;                       /* the id is spent before the allocation */
    if (!alloc_ok()) return ST_OOM;            /* allocator.create(T) */
    font_t *slot = malloc(sizeof *slot);
    if (!slot) abort();
    *slot = value;
    if (s->count == MAX_ENTRIES) { /* entries.append fails; errdefer frees the slot */
        free(slot);
        return ST_OOM;
    }
    s->entries[s->count].id = id;
    s->entries[s->count].slot = slot;
    s->count++;
    *out_id = id;
    return ST_OK;
}

/* insertBfnt: the store takes the font. If the insert fails, the store releases the new font, and that is the only
 * release on the failure path. */
static status_t store_insert(store_t *s, font_t *resource, font_id_t *out_id) {
    status_t st = registry_insert(s, *resource, out_id);
#ifndef MUT_INSERT_NO_RELEASE
    if (st != ST_OK) s->release(resource);
#endif
#ifdef MUT_INSERT_RELEASES_ON_SUCCESS
    if (st == ST_OK) s->release(resource);
#endif
    return st;
}

/* destroy: release each stored font once (Registry.deinitWith), then free the registry and the store. */
static void store_destroy(store_t *s) {
    for (size_t i = 0; i < s->count; i++) {
#ifndef MUT_DESTROY_SKIPS_RELEASE
        s->release(s->entries[i].slot);
#endif
#ifdef MUT_DESTROY_RELEASES_TWICE
        s->release(s->entries[i].slot);
#endif
        free(s->entries[i].slot);
    }
    free(s);
}

/* discard: free the registry's slots and the store. It releases no font. */
static void store_discard(store_t *s) {
    for (size_t i = 0; i < s->count; i++) free(s->entries[i].slot);
    free(s);
}

static font_t *store_get(store_t *s, font_id_t id) {
    for (size_t i = 0; i < s->count; i++) {
        if (s->entries[i].id == id) return s->entries[i].slot;
    }
    return NULL;
}

#if defined(MUT_CANVAS_RELEASES) || defined(MUT_UI_RELEASES)
/* Mutant only: removes a font from the store and releases it, as a Canvas or Ui that freed its font would. */
static void store_remove_release(store_t *s, font_id_t id) {
    for (size_t i = 0; i < s->count; i++) {
        if (s->entries[i].id == id) {
            s->release(s->entries[i].slot);
            free(s->entries[i].slot);
            s->entries[i] = s->entries[--s->count];
            return;
        }
    }
}
#endif

/* ---- Canvas and Ui (ui.zig): wrapper memory only, the font is borrowed ---- */

typedef struct {
    store_t *fonts;
    font_id_t font;
    unsigned char *list;
} canvas_t;

static canvas_t canvas_create(store_t *fonts, font_id_t font) {
    canvas_t cv;
    cv.fonts = fonts;
    cv.font = font;
    cv.list = malloc(64);
    if (!cv.list) abort();
    return cv;
}

static void canvas_deinit(canvas_t *cv) {
#ifdef MUT_CANVAS_RELEASES
    store_remove_release(cv->fonts, cv->font);
#endif
    free(cv->list);
    cv->list = NULL;
}

typedef struct {
    canvas_t canvas;
    unsigned char *ctx;
} ui_t;

static ui_t ui_init(store_t *fonts, font_id_t font) {
    ui_t u;
    u.canvas = canvas_create(fonts, font);
    u.ctx = malloc(128);
    if (!u.ctx) abort();
    return u;
}

static void ui_deinit(ui_t *u) {
    free(u->ctx);
    u->ctx = NULL;
#ifdef MUT_UI_RELEASES
    store_remove_release(u->canvas.fonts, u->canvas.font);
#endif
    canvas_deinit(&u->canvas);
}

/* ---- Session.stop (core/lifecycle.zig): the font step, then the device teardown ---- */

typedef struct {
    int stopped;
    int fonts_ready;
    int gpu_created;
    store_t *fonts;
    void *device;
} session_t;

static void *expected_device;

static void wait_idle_fake(void *device) {
    record(device == expected_device ? STEP_WAIT_IDLE : STEP_WRONG_DEVICE);
}

static void device_deinit_fake(void) {
    gpu_alive = 0;
    record(STEP_DEVICE_DEINIT);
}

static void session_stop(session_t *ss) {
    if (ss->stopped) return;
    ss->stopped = 1;
#ifdef MUT_STOP_DEVICE_FIRST
    if (ss->gpu_created) {
        device_deinit_fake();
        ss->gpu_created = 0;
    }
#endif
    if (ss->fonts_ready) {
        wait_idle_fake(ss->device);
#ifndef MUT_STOP_SKIPS_FONTS
        store_destroy(ss->fonts);
#endif
        ss->fonts_ready = 0;
    }
#ifndef MUT_STOP_DEVICE_FIRST
    if (ss->gpu_created) {
        device_deinit_fake();
        ss->gpu_created = 0;
    }
#endif
}

/* ---- checks ---- */

static int checks_run;
static int checks_failed;

static void check(int ok, const char *name) {
    checks_run++;
    if (ok) {
        printf("PASS %s\n", name);
    } else {
        printf("FAIL %s\n", name);
        checks_failed++;
    }
    fflush(stdout);
}

static void begin_check(void) {
    alloc_index = 0;
    fail_index = -1;
    release_total = 0;
    memset(release_by_marker, 0, sizeof release_by_marker);
    double_release = 0;
    released_with_gpu_dead = 0;
    gpu_alive = 1;
    step_count = 0;
    expected_device = NULL;
}

static font_t make_font(int marker, int with_atlas) {
    font_t f;
    f.line_height = marker;
    f.atlas = with_atlas ? malloc(16) : NULL;
    f.released = 0;
    return f;
}

static size_t count_of(store_t *s) { return s->count; }

static void check_store_owns_on_insert(void) {
    begin_check();
    store_t *s = store_create_with_release(release_counted);
    font_t f = make_font(11, 1);
    font_id_t id = 0;
    status_t st = store_insert(s, &f, &id);
    check(st == ST_OK, "insert: succeeds");
    check(release_total == 0, "insert: the store owns the font, so the insert releases nothing");
    check(count_of(s) == 1, "insert: the store holds one font");
    check(store_get(s, id) != NULL && store_get(s, id)->line_height == 11, "insert: the handle resolves to the font");
    store_destroy(s);
    check(release_total == 1 && release_by_marker[11] == 1, "destroy after insert: the font is released exactly once");
    check(double_release == 0, "destroy after insert: no second release");
}

static void check_canvas_leaves_font_alive(void) {
    begin_check();
    store_t *s = store_create_with_release(release_counted);
    font_t f = make_font(31, 1);
    font_id_t id = 0;
    (void)store_insert(s, &f, &id);
    canvas_t cv = canvas_create(s, id);
    canvas_deinit(&cv);
    check(release_total == 0, "Canvas deinit: releases nothing");
    check(store_get(s, id) != NULL && store_get(s, id)->line_height == 31,
          "Canvas deinit: the font is still in the store and answers its handle");
    store_destroy(s);
    check(release_total == 1 && release_by_marker[31] == 1, "store destroy after Canvas: released exactly once");
}

static void check_ui_leaves_font_alive(void) {
    begin_check();
    store_t *s = store_create_with_release(release_counted);
    font_t f = make_font(32, 1);
    font_id_t id = 0;
    (void)store_insert(s, &f, &id);
    ui_t u = ui_init(s, id);
    ui_deinit(&u);
    check(release_total == 0, "Ui deinit: releases nothing");
    check(store_get(s, id) != NULL && store_get(s, id)->line_height == 32,
          "Ui deinit: the font is still in the store and answers its handle");
    store_destroy(s);
    check(release_total == 1 && release_by_marker[32] == 1, "store destroy after Ui: released exactly once");
}

static void check_destroy_releases_each_once(void) {
    begin_check();
    store_t *s = store_create_with_release(release_counted);
    font_id_t id = 0;
    font_t a = make_font(21, 1), b = make_font(22, 1), c = make_font(23, 1);
    (void)store_insert(s, &a, &id);
    (void)store_insert(s, &b, &id);
    (void)store_insert(s, &c, &id);
    check(release_total == 0, "three fonts stored: nothing released yet");
    store_destroy(s);
    check(release_total == 3, "store destroy: three releases for three fonts");
    check(release_by_marker[21] == 1 && release_by_marker[22] == 1 && release_by_marker[23] == 1,
          "store destroy: each font released exactly once");
    check(double_release == 0, "store destroy: no font released twice");
}

static void check_failed_insert_releases_new_font(void) {
    begin_check();
    /* Allocation 0 is the State and must succeed. Allocation 1 is the slot for the new font, and it fails. */
    store_t *s = store_create_with_release(release_counted);
    fail_index = 1;
    font_t f = make_font(31, 1);
    font_id_t id = 0;
    check(s != NULL, "failed insert: store created (State allocation succeeds)");
    /* The store was created before fail_index was set, so the failing slot is the next allocation. */
    status_t st = store_insert(s, &f, &id);
    check(st == ST_OOM, "failed insert: reports out of memory");
    check(release_by_marker[31] == 1 && release_total == 1,
          "failed insert: the new font is released exactly once");
    check(count_of(s) == 0, "failed insert: the store holds nothing");
    store_destroy(s);
    check(release_total == 1, "store destroy after failed insert: no further release");
}

static void check_exhausted_insert_releases_new_font(void) {
    begin_check();
    store_t *s = store_create_with_release(release_counted);
    font_t earlier = make_font(41, 1);
    font_id_t earlier_id = 0;
    (void)store_insert(s, &earlier, &earlier_id);
    s->next_id = FONT_ID_MAX;
    font_t f = make_font(42, 1);
    font_id_t id = 0;
    status_t st = store_insert(s, &f, &id);
    check(st == ST_EXHAUSTED, "id exhaustion: reports exhaustion");
    check(release_by_marker[42] == 1 && release_total == 1,
          "id exhaustion: the new font is released exactly once");
    check(count_of(s) == 1 && store_get(s, earlier_id) != NULL,
          "id exhaustion: the earlier font is still stored");
    store_destroy(s);
    check(release_total == 2 && release_by_marker[41] == 1,
          "store destroy after exhaustion: the earlier font is released once, and no other");
}

static void check_discard_releases_nothing(void) {
    begin_check();
    store_t *s = store_create_with_release(release_counted);
    font_t f = make_font(51, 0);
    font_id_t id = 0;
    (void)store_insert(s, &f, &id);
    store_discard(s);
    check(release_total == 0, "discard: releases no font");
}

static void check_session_shutdown_order(void) {
    begin_check();
    store_t *s = store_create_with_release(release_counted);
    font_t a = make_font(41, 1), b = make_font(42, 1);
    font_id_t id = 0;
    (void)store_insert(s, &a, &id);
    (void)store_insert(s, &b, &id);
    unsigned char device_token = 0;
    expected_device = &device_token;
    session_t ss;
    ss.stopped = 0;
    ss.fonts_ready = 1;
    ss.gpu_created = 1;
    ss.fonts = s;
    ss.device = &device_token;
    step_count = 0;
    session_stop(&ss);

    step_t expected[] = { STEP_WAIT_IDLE, STEP_FONT_RELEASE, STEP_FONT_RELEASE, STEP_DEVICE_DEINIT };
    size_t n = sizeof expected / sizeof expected[0];
    int same = step_count == n;
    for (size_t i = 0; same && i < n; i++) same = steps[i] == expected[i];
    check(same, "session stop: wait, then both font releases, then the device goes");
    check(released_with_gpu_dead == 0, "session stop: no font is released after the device is gone");
    check(!ss.fonts_ready && !ss.gpu_created, "session stop: the font step and the device step are both done");
}

int main(void) {
    check_store_owns_on_insert();
    check_canvas_leaves_font_alive();
    check_ui_leaves_font_alive();
    check_destroy_releases_each_once();
    check_failed_insert_releases_new_font();
    check_exhausted_insert_releases_new_font();
    check_discard_releases_nothing();
    check_session_shutdown_order();
    printf("%d of %d checks pass\n", checks_run - checks_failed, checks_run);
    return checks_failed == 0 ? 0 : 1;
}
