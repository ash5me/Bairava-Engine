/*
 * asset_build: validate manifest entries, copy runtime assets, and emit an asset index.
 *
 * Manifest rows use whitespace-separated fields:
 *   name type source output dependencies
 * Dependencies are comma-separated asset names, or '-'. Paths are project-relative and
 * outputs are relative to the generated asset directory.
 */

#include "../../vendor/stb_image.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <direct.h>
#define make_directory(path) _mkdir(path)
#define PATH_SEPARATOR '\\'
#else
#include <unistd.h>
#define make_directory(path) mkdir(path, 0777)
#define PATH_SEPARATOR '/'
#endif

#define MAX_ENTRIES 1024
#define FIELD_SIZE 1024

typedef struct {
    char name[FIELD_SIZE];
    char type[32];
    char source[FIELD_SIZE];
    char output[FIELD_SIZE];
    char dependencies[FIELD_SIZE];
} entry;

static int safe_relative_path(const char *path) {
    if (path[0] == '\0' || path[0] == '/' || path[0] == '\\' || strchr(path, ':') != NULL || strchr(path, '\\') != NULL) return 0;
    const char *segment = path;
    for (const char *p = path;; p++) {
        if (*p == '/' || *p == '\0') {
            size_t length = (size_t)(p - segment);
            if (length == 0 || (length == 1 && segment[0] == '.') || (length == 2 && segment[0] == '.' && segment[1] == '.')) return 0;
            if (*p == '\0') break;
            segment = p + 1;
        }
    }
    return 1;
}

static int safe_name(const char *name) {
    if (name[0] == '\0') return 0;
    const unsigned char *segment = (const unsigned char *)name;
    for (const unsigned char *p = segment;; p++) {
        if (*p == '/' || *p == '\0') {
            if (p == segment || !((*segment >= 'a' && *segment <= 'z') || (*segment >= '0' && *segment <= '9'))) return 0;
            if (*p == '\0') break;
            segment = p + 1;
            continue;
        }
        if (!( (*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '_' || *p == '-' || *p == '.')) return 0;
    }
    return strstr(name, "..") == NULL;
}

static int mkdirs(const char *path) {
    char buffer[FIELD_SIZE * 2];
    size_t length = strlen(path);
    if (length == 0 || length >= sizeof buffer) return 0;
    memcpy(buffer, path, length + 1);
    for (char *p = buffer + 1; *p; p++) {
        if (*p == '/' || *p == '\\') {
            char saved = *p;
            *p = '\0';
            if (make_directory(buffer) != 0 && errno != EEXIST) return 0;
            *p = saved;
        }
    }
    return make_directory(buffer) == 0 || errno == EEXIST;
}

static int file_exists(const char *path) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) return 0;
    fclose(file);
    return 1;
}

static int valid_kind(const entry *item) {
    if (strcmp(item->type, "image") == 0) {
        int width = 0, height = 0, channels = 0;
        if (!stbi_info(item->source, &width, &height, &channels) || width <= 0 || height <= 0) {
            fprintf(stderr, "asset_build: invalid image '%s': %s\n", item->source, stbi_failure_reason());
            return 0;
        }
    } else if (strcmp(item->type, "audio") == 0) {
        unsigned char header[12];
        FILE *file = fopen(item->source, "rb");
        if (file == NULL || fread(header, 1, sizeof header, file) != sizeof header || fclose(file) != 0 ||
            memcmp(header, "RIFF", 4) != 0 || memcmp(header + 8, "WAVE", 4) != 0) {
            fprintf(stderr, "asset_build: '%s' is not a readable RIFF/WAVE file\n", item->source);
            return 0;
        }
    } else if (strcmp(item->type, "font") == 0) {
        unsigned char header[4];
        FILE *file = fopen(item->source, "rb");
        if (file == NULL || fread(header, 1, sizeof header, file) != sizeof header || fclose(file) != 0 ||
            !(memcmp(header, "\000\001\000\000", 4) == 0 || memcmp(header, "OTTO", 4) == 0 || memcmp(header, "true", 4) == 0 || memcmp(header, "typ1", 4) == 0)) {
            fprintf(stderr, "asset_build: '%s' is not a supported TrueType/OpenType font\n", item->source);
            return 0;
        }
    } else if (strcmp(item->type, "map") != 0 && strcmp(item->type, "file") != 0) {
        fprintf(stderr, "asset_build: unknown type '%s' for '%s'\n", item->type, item->name);
        return 0;
    }
    return 1;
}

static int copy_file(const char *source, const char *destination) {
    FILE *input = fopen(source, "rb");
    if (input == NULL) {
        fprintf(stderr, "asset_build: cannot read '%s': %s\n", source, strerror(errno));
        return 0;
    }
    FILE *output = fopen(destination, "wb");
    if (output == NULL) {
        fprintf(stderr, "asset_build: cannot write '%s': %s\n", destination, strerror(errno));
        fclose(input);
        return 0;
    }
    unsigned char buffer[16384];
    size_t count;
    int ok = 1;
    while ((count = fread(buffer, 1, sizeof buffer, input)) != 0) {
        if (fwrite(buffer, 1, count, output) != count) { ok = 0; break; }
    }
    if (ferror(input)) ok = 0;
    if (fclose(input) != 0 || fclose(output) != 0) ok = 0;
    if (!ok) remove(destination);
    return ok;
}

static int dependency_exists(const entry *entries, size_t count, const char *name) {
    for (size_t i = 0; i < count; i++) if (strcmp(entries[i].name, name) == 0) return 1;
    return 0;
}

static int process_manifest(const char *manifest_path, const char *output_dir) {
    FILE *manifest = fopen(manifest_path, "r");
    if (manifest == NULL) { fprintf(stderr, "asset_build: cannot open manifest '%s'\n", manifest_path); return 1; }
    entry *entries = (entry *)calloc(MAX_ENTRIES, sizeof *entries);
    if (entries == NULL) { fclose(manifest); return 1; }
    char line[FIELD_SIZE * 5];
    size_t count = 0, line_number = 0;
    int failed = 0;
    while (fgets(line, sizeof line, manifest) != NULL) {
        line_number++;
        if (line[0] == '#' || line[0] == '\n' || line[0] == '\r') continue;
        entry item = {0};
        char extra[2];
        if (sscanf(line, "%1023s %31s %1023s %1023s %1023s %1s", item.name, item.type, item.source, item.output, item.dependencies, extra) != 5) {
            fprintf(stderr, "asset_build: %s:%zu: expected five fields\n", manifest_path, line_number); failed = 1; break;
        }
        if (!safe_name(item.name) || !safe_relative_path(item.source) || !safe_relative_path(item.output) ||
            count == MAX_ENTRIES || !file_exists(item.source) || !valid_kind(&item)) {
            if (!failed) fprintf(stderr, "asset_build: %s:%zu: invalid entry '%s'\n", manifest_path, line_number, item.name);
            failed = 1; break;
        }
        for (size_t i = 0; i < count; i++) {
            if (strcmp(entries[i].name, item.name) == 0 || strcmp(entries[i].output, item.output) == 0) {
                fprintf(stderr, "asset_build: %s:%zu: duplicate name or output\n", manifest_path, line_number); failed = 1; break;
            }
        }
        if (failed) break;
        entries[count++] = item;
    }
    fclose(manifest);
    if (failed) { free(entries); return 1; }
    for (size_t i = 0; i < count; i++) {
        if (strcmp(entries[i].dependencies, "-") == 0) continue;
        char deps[FIELD_SIZE];
        memcpy(deps, entries[i].dependencies, sizeof deps);
        for (char *dep = strtok(deps, ","); dep != NULL; dep = strtok(NULL, ",")) {
            if (!safe_name(dep) || !dependency_exists(entries, count, dep)) {
                fprintf(stderr, "asset_build: '%s' depends on unknown asset '%s'\n", entries[i].name, dep); free(entries); return 1;
            }
        }
    }

    if (!mkdirs(output_dir)) { fprintf(stderr, "asset_build: cannot create output directory '%s'\n", output_dir); free(entries); return 1; }
    char index_path[FIELD_SIZE * 2];
    if (snprintf(index_path, sizeof index_path, "%s%casset-index.txt", output_dir, PATH_SEPARATOR) >= (int)sizeof index_path) { free(entries); return 1; }
    FILE *index = fopen(index_path, "w");
    if (index == NULL) { fprintf(stderr, "asset_build: cannot create '%s'\n", index_path); free(entries); return 1; }
    fprintf(index, "# asset-index-v1\n# name type path source dependencies\n");
    for (size_t i = 0; i < count; i++) {
        char relative_output[FIELD_SIZE];
        size_t output_length = strlen(entries[i].output);
        if (output_length >= sizeof relative_output) { failed = 1; break; }
        memcpy(relative_output, entries[i].output, output_length + 1);
        for (char *p = relative_output; *p; p++) if (*p == '/' || *p == '\\') *p = PATH_SEPARATOR;
        char destination[FIELD_SIZE * 2];
        if (snprintf(destination, sizeof destination, "%s%c%s", output_dir, PATH_SEPARATOR, relative_output) >= (int)sizeof destination) { failed = 1; break; }
        char parent[FIELD_SIZE * 2];
        memcpy(parent, destination, strlen(destination) + 1);
        char *slash = strrchr(parent, PATH_SEPARATOR);
        if (slash != NULL) { *slash = '\0'; if (!mkdirs(parent)) { failed = 1; break; } }
        if (!copy_file(entries[i].source, destination)) { failed = 1; break; }
        fprintf(index, "%s %s %s %s %s\n", entries[i].name, entries[i].type, entries[i].output, entries[i].source, entries[i].dependencies);
    }
    if (fclose(index) != 0) failed = 1;
    free(entries);
    if (failed) { fprintf(stderr, "asset_build: failed to produce runtime assets\n"); return 1; }
    printf("Built %zu assets with index %s\n", count, index_path);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--help") == 0) {
        printf("Usage: asset_build <manifest> <output-directory>\n");
        return 0;
    }
    if (argc != 3) { fprintf(stderr, "Usage: asset_build <manifest> <output-directory>\n"); return 2; }
    return process_manifest(argv[1], argv[2]);
}
