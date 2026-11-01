/*
 * jobs.c: the job system. One mutex guards the queue and every counter, so a counter read under the
 * lock always agrees with the jobs that finished before it. Coarse jobs, such as decoding an image,
 * take far longer than a lock, so one lock is enough and keeps the logic simple to check.
 *
 * Two condition variables do the signaling. `work` wakes an idle worker when a job is queued.
 * `done` wakes every waiter when some counter reaches zero, and each waiter checks its own counter.
 */
#include "jobs.h"

#include <stdint.h>
#include <stdlib.h>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <process.h>
#  include <windows.h>
typedef CRITICAL_SECTION jobs_lock;
typedef CONDITION_VARIABLE jobs_cond;
typedef HANDLE jobs_thread;

static void lock_init(jobs_lock *m) { InitializeCriticalSection(m); }
static void lock_destroy(jobs_lock *m) { DeleteCriticalSection(m); }
static void lock_take(jobs_lock *m) { EnterCriticalSection(m); }
static void lock_release(jobs_lock *m) { LeaveCriticalSection(m); }
static void cond_init(jobs_cond *c) { InitializeConditionVariable(c); }
static void cond_destroy(jobs_cond *c) { (void)c; }
static void cond_wait(jobs_cond *c, jobs_lock *m) { SleepConditionVariableCS(c, m, INFINITE); }
static void cond_signal(jobs_cond *c) { WakeConditionVariable(c); }
static void cond_broadcast(jobs_cond *c) { WakeAllConditionVariable(c); }
#else
#  include <pthread.h>
typedef pthread_mutex_t jobs_lock;
typedef pthread_cond_t jobs_cond;
typedef pthread_t jobs_thread;

static void lock_init(jobs_lock *m) { pthread_mutex_init(m, NULL); }
static void lock_destroy(jobs_lock *m) { pthread_mutex_destroy(m); }
static void lock_take(jobs_lock *m) { pthread_mutex_lock(m); }
static void lock_release(jobs_lock *m) { pthread_mutex_unlock(m); }
static void cond_init(jobs_cond *c) { pthread_cond_init(c, NULL); }
static void cond_destroy(jobs_cond *c) { pthread_cond_destroy(c); }
static void cond_wait(jobs_cond *c, jobs_lock *m) { pthread_cond_wait(c, m); }
static void cond_signal(jobs_cond *c) { pthread_cond_signal(c); }
static void cond_broadcast(jobs_cond *c) { pthread_cond_broadcast(c); }
#endif

typedef struct jobs_entry {
    jobs_fn fn;
    void *data;
    jobs_counter *counter;
} jobs_entry;

struct jobs_pool {
    jobs_lock lock;
    jobs_cond work;
    jobs_cond done;
    jobs_entry *ring;
    unsigned capacity;
    unsigned head;
    unsigned count;
    jobs_thread *threads;
    unsigned worker_count;
    int stopping;
};

/* Removes the oldest queued job. The caller holds the lock and has checked count > 0. */
static jobs_entry pop(jobs_pool *pool)
{
    jobs_entry job = pool->ring[pool->head];
    pool->head = (pool->head + 1) % pool->capacity;
    pool->count--;
    return job;
}

/* Records that a job finished. The caller holds the lock. Waiters are woken when a counter reaches zero. */
static void finish(jobs_pool *pool, jobs_counter *counter)
{
    if (counter && --counter->pending == 0) cond_broadcast(&pool->done);
}

static void worker_loop(jobs_pool *pool)
{
    lock_take(&pool->lock);
    for (;;) {
        jobs_entry job;
        while (pool->count == 0 && !pool->stopping) cond_wait(&pool->work, &pool->lock);
        if (pool->count == 0) break; /* stopping, and the queue is empty */
        job = pop(pool);
        lock_release(&pool->lock);
        job.fn(job.data);
        lock_take(&pool->lock);
        finish(pool, job.counter);
    }
    lock_release(&pool->lock);
}

#if defined(_WIN32)
static unsigned __stdcall worker_entry(void *arg)
{
    worker_loop((jobs_pool *)arg);
    return 0;
}

static int thread_create(jobs_thread *thread, jobs_pool *pool)
{
    uintptr_t handle = _beginthreadex(NULL, 0, worker_entry, pool, 0, NULL);
    if (handle == 0) return -1;
    *thread = (HANDLE)handle;
    return 0;
}

static void thread_join(jobs_thread thread)
{
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
}
#else
static void *worker_entry(void *arg)
{
    worker_loop((jobs_pool *)arg);
    return NULL;
}

static int thread_create(jobs_thread *thread, jobs_pool *pool)
{
    return pthread_create(thread, NULL, worker_entry, pool) == 0 ? 0 : -1;
}

static void thread_join(jobs_thread thread)
{
    pthread_join(thread, NULL);
}
#endif

jobs_pool *jobs_pool_create(unsigned workers, unsigned queue_capacity)
{
    jobs_pool *pool;
    unsigned i;
    if (queue_capacity == 0) queue_capacity = 256;
    pool = calloc(1, sizeof *pool);
    if (!pool) return NULL;
    pool->ring = calloc(queue_capacity, sizeof *pool->ring);
    pool->threads = calloc(workers ? workers : 1, sizeof *pool->threads);
    if (!pool->ring || !pool->threads) {
        free(pool->ring);
        free(pool->threads);
        free(pool);
        return NULL;
    }
    pool->capacity = queue_capacity;
    lock_init(&pool->lock);
    cond_init(&pool->work);
    cond_init(&pool->done);
    /* Workers start only after the lock and conditions exist, because they use them at once. */
    for (i = 0; i < workers; i++) {
        if (thread_create(&pool->threads[pool->worker_count], pool) != 0) break;
        pool->worker_count++;
    }
    return pool;
}

void jobs_pool_destroy(jobs_pool *pool)
{
    unsigned i;
    if (!pool) return;
    lock_take(&pool->lock);
    pool->stopping = 1;
    cond_broadcast(&pool->work);
    lock_release(&pool->lock);
    /* Workers leave only once the queue is empty, so every queued job runs before the join returns. */
    for (i = 0; i < pool->worker_count; i++) thread_join(pool->threads[i]);
    cond_destroy(&pool->work);
    cond_destroy(&pool->done);
    lock_destroy(&pool->lock);
    free(pool->threads);
    free(pool->ring);
    free(pool);
}

int jobs_submit(jobs_pool *pool, jobs_counter *counter, jobs_fn fn, void *data)
{
    jobs_entry job;
    if (!pool || !fn) return -1;
    job.fn = fn;
    job.data = data;
    job.counter = counter;

    lock_take(&pool->lock);
    if (counter) counter->pending++;
    if (pool->worker_count == 0 || pool->stopping || pool->count == pool->capacity) {
        /* Running the job here keeps a full queue from blocking the caller, and it can't deadlock. */
        lock_release(&pool->lock);
        fn(data);
        lock_take(&pool->lock);
        finish(pool, counter);
        lock_release(&pool->lock);
        return 0;
    }
    pool->ring[(pool->head + pool->count) % pool->capacity] = job;
    pool->count++;
    cond_signal(&pool->work);
    lock_release(&pool->lock);
    return 0;
}

void jobs_wait(jobs_pool *pool, jobs_counter *counter)
{
    if (!pool || !counter) return;
    lock_take(&pool->lock);
    while (counter->pending > 0) {
        if (pool->count > 0) {
            /* Help instead of sleeping, so a job waiting on its children never holds a worker idle. */
            jobs_entry job = pop(pool);
            lock_release(&pool->lock);
            job.fn(job.data);
            lock_take(&pool->lock);
            finish(pool, job.counter);
        } else {
            /* Nothing is queued, so the jobs we wait for are running on other threads. */
            cond_wait(&pool->done, &pool->lock);
        }
    }
    lock_release(&pool->lock);
}

int jobs_is_done(jobs_pool *pool, const jobs_counter *counter)
{
    int done;
    if (!pool || !counter) return 1;
    lock_take(&pool->lock);
    done = counter->pending == 0;
    lock_release(&pool->lock);
    return done;
}

unsigned jobs_worker_count(const jobs_pool *pool)
{
    return pool ? pool->worker_count : 0;
}

unsigned jobs_queued(jobs_pool *pool)
{
    unsigned n;
    if (!pool) return 0;
    lock_take(&pool->lock);
    n = pool->count;
    lock_release(&pool->lock);
    return n;
}
