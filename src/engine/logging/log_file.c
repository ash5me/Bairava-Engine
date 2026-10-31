/*
 * Log file output through log.c. log.c hands every message to file_sink, which writes it to the
 * file. log.c's own terminal output is turned off, because engine/logging/log.zig prints to stderr itself.
 */

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#endif

#include "log.h"
#include "log_file.h"

/* The open log file, or NULL. file_sink checks it, because log.c can't remove a callback once added. */
static FILE *log_fp = NULL;
/* Set once the sink is registered. It stays registered for the rest of the run. */
static int sink_added = 0;

/* log.c's level for each level from log_file.h, in the same order. */
static const int log_levels[] = { LOG_DEBUG, LOG_INFO, LOG_WARN, LOG_ERROR };

static void file_sink(log_Event *ev) {
  char when[32];
  if (!log_fp) return;
  strftime(when, sizeof(when), "%Y-%m-%d %H:%M:%S", ev->time);
  fprintf(log_fp, "%s %-5s ", when, log_level_string(ev->level));
  vfprintf(log_fp, ev->fmt, ev->ap);
  fputc('\n', log_fp);
  fflush(log_fp);
}

#ifdef _WIN32
/* Paths from SDL are UTF-8, but fopen reads the system code page. Opening by the wide name keeps
 * a non-ASCII folder working. */
static FILE *open_for_write(const char *path) {
  int needed = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
  wchar_t *wide;
  FILE *fp;
  if (needed <= 0) return NULL;
  wide = (wchar_t *) malloc((size_t) needed * sizeof(wchar_t));
  if (!wide) return NULL;
  MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, needed);
  fp = _wfopen(wide, L"w");
  free(wide);
  return fp;
}
#else
static FILE *open_for_write(const char *path) {
  return fopen(path, "w");
}
#endif

void log_file_close(void) {
  if (log_fp) {
    fclose(log_fp);
    log_fp = NULL;
  }
}

int log_file_open(const char *path) {
  FILE *fp;
  log_file_close();
  fp = open_for_write(path);
  if (!fp) return -1;
  if (!sink_added) {
    /* The sink takes every level, because engine/logging/log.zig already drops the ones below min_level. */
    log_set_quiet(true);
    if (log_add_callback(file_sink, NULL, LOG_DEBUG) != 0) {
      fclose(fp);
      return -1;
    }
    sink_added = 1;
  }
  log_fp = fp;
  return 0;
}

void log_file_write(int level, const char *text) {
  if (!log_fp) return;
  if (level < 0) level = 0;
  if (level > 3) level = 3;
  /* The text goes through "%s", so a '%' in a message is printed, not read as a format. */
  log_log(log_levels[level], "", 0, "%s", text);
}
