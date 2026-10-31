/*
 * Log file output through log.c (vendor/log.c). engine/logging/log.zig sends each message here, and log.c
 * delivers it to the file. Nothing here touches SDL or the GPU.
 */

#ifndef LOG_FILE_H
#define LOG_FILE_H

/* Opens `path` for writing, replacing any file already there, so each run starts a new log.
 * Returns 0 on success and -1 if the file can't be opened. Opening again closes the earlier file. */
int log_file_open(const char *path);

/* Flushes and closes the log file. With no file open, this does nothing. */
void log_file_close(void);

/* Writes one line: a timestamp, the level, and `text`. `level` runs from 0 (debug) to 3 (error),
 * the same order as engine/logging/log.zig's Level. Nothing is written while no file is open. */
void log_file_write(int level, const char *text);

#endif
