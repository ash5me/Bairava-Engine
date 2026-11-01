/*
 * jobs.h: a job system. A pool runs jobs on worker threads. A job is a function and its data, and
 * a counter can group jobs so the caller can wait for them. The pool is the only place threads are
 * created, so the rest of the engine can say what can run off the main thread without owning any
 * threads itself.
 *
 * Rules that keep it safe:
 *   - Jobs must not touch engine state that belongs to the main thread: the logger, the GPU, the
 *     asset arenas, and the game. A job works on its own data and hands results back through
 *     memory the caller reads after jobs_wait or jobs_is_done returns true.
 *   - A counter must outlive every job submitted with it and every wait on it.
 *   - A job may submit more jobs and wait on them. jobs_wait runs queued jobs while it waits, so
 *     this cannot deadlock, even with one worker.
 *   - With zero workers every job runs on the thread that submits it, which makes tests and
 *     single-threaded builds deterministic.
 */
#ifndef BAIRAVA_JOBS_H
#define BAIRAVA_JOBS_H

typedef void (*jobs_fn)(void *data);

/*
 * Counts the jobs submitted with it that have not finished. Zero means nothing is pending.
 * Zero-initialize it before the first submit. Its fields belong to the pool, so read them only
 * through jobs_is_done and jobs_wait.
 */
typedef struct jobs_counter {
    unsigned pending;
} jobs_counter;

typedef struct jobs_pool jobs_pool;

/*
 * Starts `workers` threads with room for `queue_capacity` queued jobs (zero picks 256). Fewer
 * workers than requested start if the operating system refuses a thread; zero workers means inline
 * execution. Returns NULL only when memory runs out.
 */
jobs_pool *jobs_pool_create(unsigned workers, unsigned queue_capacity);

/*
 * Stops the pool after the queued jobs finish, joins the workers, and frees the pool. Do not
 * submit jobs while it is being destroyed.
 */
void jobs_pool_destroy(jobs_pool *pool);

/*
 * Queues fn(data). When `counter` is not NULL it is incremented now and decremented after the job
 * returns. If the queue is full, or the pool has no workers, the job runs on the calling thread
 * before this returns. Returns 0 on success and -1 for a NULL pool or function.
 */
int jobs_submit(jobs_pool *pool, jobs_counter *counter, jobs_fn fn, void *data);

/*
 * Returns once `counter` is zero. While it waits, the calling thread runs queued jobs. Use it to
 * wait for work that jobs_submit started.
 */
void jobs_wait(jobs_pool *pool, jobs_counter *counter);

/* Returns 1 when every job submitted with `counter` has finished, and 0 otherwise. Never blocks. */
int jobs_is_done(jobs_pool *pool, const jobs_counter *counter);

/* The number of worker threads actually running. */
unsigned jobs_worker_count(const jobs_pool *pool);

/* The number of jobs waiting in the queue, not counting any already running. */
unsigned jobs_queued(jobs_pool *pool);

#endif
