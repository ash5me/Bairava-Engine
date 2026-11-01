/*
 * test_jobs.c: checks the job system on real threads. Each check prints its file and line when it
 * fails. The program exits nonzero if any check failed.
 */
#include "jobs.h"

#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond)                                                                \
    do {                                                                           \
        if (!(cond)) {                                                             \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                            \
        }                                                                          \
    } while (0)

static void add_one(void *data)
{
    atomic_int *total = data;
    atomic_fetch_add(total, 1);
}

static void fill_slot(void *data)
{
    int *slot = data;
    *slot = *slot * 3 + 1;
}

static void test_inline_pool_runs_jobs_on_the_caller(void)
{
    jobs_pool *pool = jobs_pool_create(0, 0);
    jobs_counter counter = { 0 };
    atomic_int total = 0;
    int i;
    CHECK(pool != NULL);
    CHECK(jobs_worker_count(pool) == 0);
    for (i = 0; i < 100; i++) CHECK(jobs_submit(pool, &counter, add_one, &total) == 0);
    CHECK(jobs_is_done(pool, &counter));
    jobs_wait(pool, &counter);
    CHECK(atomic_load(&total) == 100);
    jobs_pool_destroy(pool);
}

static void test_workers_run_every_job_once(void)
{
    jobs_pool *pool = jobs_pool_create(4, 64);
    jobs_counter counter = { 0 };
    atomic_int total = 0;
    int i;
    CHECK(pool != NULL);
    CHECK(jobs_worker_count(pool) == 4);
    for (i = 0; i < 10000; i++) CHECK(jobs_submit(pool, &counter, add_one, &total) == 0);
    jobs_wait(pool, &counter);
    CHECK(jobs_is_done(pool, &counter));
    CHECK(atomic_load(&total) == 10000);
    jobs_pool_destroy(pool);
}

/* Each job writes its own slot. The wait must make every write visible to the caller. */
static void test_results_are_visible_after_wait(void)
{
    enum { N = 512 };
    static int slots[N];
    jobs_pool *pool = jobs_pool_create(3, 32);
    jobs_counter counter = { 0 };
    int i;
    memset(slots, 0, sizeof slots);
    for (i = 0; i < N; i++) {
        slots[i] = i;
        CHECK(jobs_submit(pool, &counter, fill_slot, &slots[i]) == 0);
    }
    jobs_wait(pool, &counter);
    for (i = 0; i < N; i++) CHECK(slots[i] == i * 3 + 1);
    jobs_pool_destroy(pool);
}

typedef struct nested_ctx {
    jobs_pool *pool;
    atomic_int *total;
} nested_ctx;

static void parent_job(void *data)
{
    nested_ctx *ctx = data;
    jobs_counter children = { 0 };
    int i;
    for (i = 0; i < 10; i++) jobs_submit(ctx->pool, &children, add_one, ctx->total);
    /* Waiting inside a worker must help run the children, or a single worker would stall here. */
    jobs_wait(ctx->pool, &children);
}

static void test_jobs_can_wait_on_children_with_one_worker(void)
{
    jobs_pool *pool = jobs_pool_create(1, 64);
    jobs_counter parents = { 0 };
    atomic_int total = 0;
    nested_ctx ctx;
    int i;
    ctx.pool = pool;
    ctx.total = &total;
    for (i = 0; i < 20; i++) CHECK(jobs_submit(pool, &parents, parent_job, &ctx) == 0);
    jobs_wait(pool, &parents);
    CHECK(atomic_load(&total) == 200);
    jobs_pool_destroy(pool);
}

static void test_full_queue_runs_overflow_inline(void)
{
    jobs_pool *pool = jobs_pool_create(1, 2);
    jobs_counter counter = { 0 };
    atomic_int total = 0;
    int i;
    for (i = 0; i < 500; i++) CHECK(jobs_submit(pool, &counter, add_one, &total) == 0);
    jobs_wait(pool, &counter);
    CHECK(atomic_load(&total) == 500);
    jobs_pool_destroy(pool);
}

static void test_destroy_finishes_queued_jobs(void)
{
    jobs_pool *pool = jobs_pool_create(2, 1024);
    jobs_counter counter = { 0 };
    atomic_int total = 0;
    int i;
    for (i = 0; i < 1000; i++) CHECK(jobs_submit(pool, &counter, add_one, &total) == 0);
    jobs_pool_destroy(pool);
    CHECK(atomic_load(&total) == 1000);
    CHECK(counter.pending == 0);
}

static atomic_int release_flag;

static void wait_for_release(void *data)
{
    atomic_int *ran = data;
    while (atomic_load(&release_flag) == 0) {
    }
    atomic_fetch_add(ran, 1);
}

static void test_is_done_reports_pending_work(void)
{
    jobs_pool *pool = jobs_pool_create(1, 8);
    jobs_counter counter = { 0 };
    atomic_int ran = 0;
    atomic_store(&release_flag, 0);
    CHECK(jobs_submit(pool, &counter, wait_for_release, &ran) == 0);
    CHECK(!jobs_is_done(pool, &counter));
    atomic_store(&release_flag, 1);
    jobs_wait(pool, &counter);
    CHECK(jobs_is_done(pool, &counter));
    CHECK(atomic_load(&ran) == 1);
    jobs_pool_destroy(pool);
}

static void test_counters_are_independent(void)
{
    jobs_pool *pool = jobs_pool_create(2, 16);
    jobs_counter fast = { 0 };
    jobs_counter slow = { 0 };
    atomic_int fast_total = 0;
    atomic_int slow_total = 0;
    int i;
    for (i = 0; i < 50; i++) CHECK(jobs_submit(pool, &fast, add_one, &fast_total) == 0);
    for (i = 0; i < 50; i++) CHECK(jobs_submit(pool, &slow, add_one, &slow_total) == 0);
    jobs_wait(pool, &fast);
    CHECK(atomic_load(&fast_total) == 50);
    jobs_wait(pool, &slow);
    CHECK(atomic_load(&slow_total) == 50);
    jobs_pool_destroy(pool);
}

static void test_null_arguments_are_safe(void)
{
    jobs_counter counter = { 0 };
    CHECK(jobs_submit(NULL, &counter, add_one, NULL) == -1);
    CHECK(jobs_is_done(NULL, &counter));
    jobs_wait(NULL, &counter);
    jobs_pool_destroy(NULL);
    CHECK(jobs_worker_count(NULL) == 0);
    CHECK(jobs_queued(NULL) == 0);
}

static void test_pools_can_be_created_and_destroyed_repeatedly(void)
{
    int round;
    for (round = 0; round < 50; round++) {
        jobs_pool *pool = jobs_pool_create(4, 8);
        jobs_counter counter = { 0 };
        atomic_int total = 0;
        int i;
        CHECK(pool != NULL);
        for (i = 0; i < 40; i++) jobs_submit(pool, &counter, add_one, &total);
        jobs_wait(pool, &counter);
        CHECK(atomic_load(&total) == 40);
        jobs_pool_destroy(pool);
    }
}

int main(void)
{
    test_inline_pool_runs_jobs_on_the_caller();
    test_workers_run_every_job_once();
    test_results_are_visible_after_wait();
    test_jobs_can_wait_on_children_with_one_worker();
    test_full_queue_runs_overflow_inline();
    test_destroy_finishes_queued_jobs();
    test_is_done_reports_pending_work();
    test_counters_are_independent();
    test_null_arguments_are_safe();
    test_pools_can_be_created_and_destroyed_repeatedly();

    if (failures != 0) {
        fprintf(stderr, "%d job check(s) failed\n", failures);
        return 1;
    }
    printf("job tests passed\n");
    return 0;
}
