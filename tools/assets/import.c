/*
 * asset_import: copy a sprite into the project and register it for atlas packing.
 *
 * Usage: asset_import <source-image> <sprite-name>
 *
 * The source format is preserved. Sprite names are one lowercase path segment, and the resulting
 * image is written under assets/imported/. The sprite is then appended to assets/sprites.txt.
 */

#include "../../vendor/stb_image.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <direct.h>
#define make_directory(path) _mkdir(path)
#else
#define make_directory(path) mkdir(path, 0777)
#endif

static int valid_name(const char *name) {
    size_t length = strlen(name);
    if (length == 0 || length > 64 ||
        (!(name[0] >= 'a' && name[0] <= 'z') && !(name[0] >= '0' && name[0] <= '9'))) {
        return 0;
    }
    for (const unsigned char *ch = (const unsigned char *)name; *ch != '\0'; ch++) {
        if (!((*ch >= 'a' && *ch <= 'z') || (*ch >= '0' && *ch <= '9') || *ch == '_' || *ch == '-')) {
            return 0;
        }
    }
    return 1;
}

static const char *source_extension(const char *path) {
    const char *base = path;
    for (const char *ch = path; *ch != '\0'; ch++) {
        if (*ch == '/' || *ch == '\\') base = ch + 1;
    }
    const char *dot = strrchr(base, '.');
    if (dot == NULL || dot[1] == '\0' || strlen(dot) > 16) return NULL;
    for (const unsigned char *ch = (const unsigned char *)dot; *ch != '\0'; ch++) {
        if (!(isalnum(*ch) || *ch == '.')) return NULL;
    }
    return dot;
}

static int manifest_contains(const char *name) {
    FILE *manifest = fopen("assets/sprites.txt", "r");
    if (manifest == NULL) return 0;
    char line[1024];
    char existing[256];
    int found = 0;
    while (fgets(line, sizeof line, manifest) != NULL) {
        if (sscanf(line, "%255s", existing) == 1 && strcmp(name, existing) == 0) {
            found = 1;
            break;
        }
    }
    fclose(manifest);
    return found;
}

static int same_file(const char *first, const char *second) {
    struct stat first_info;
    struct stat second_info;
    if (strcmp(first, second) == 0) return 1;
    if (stat(first, &first_info) != 0 || stat(second, &second_info) != 0) return 0;
    return first_info.st_dev == second_info.st_dev && first_info.st_ino == second_info.st_ino;
}

static int copy_file(const char *source, const char *destination) {
    FILE *input = fopen(source, "rb");
    if (input == NULL) {
        fprintf(stderr, "asset_import: could not open '%s': %s\n", source, strerror(errno));
        return 0;
    }
    FILE *output = fopen(destination, "wb");
    if (output == NULL) {
        fprintf(stderr, "asset_import: could not create '%s': %s\n", destination, strerror(errno));
        fclose(input);
        return 0;
    }

    unsigned char buffer[16384];
    int ok = 1;
    size_t read_count;
    while ((read_count = fread(buffer, 1, sizeof buffer, input)) != 0) {
        if (fwrite(buffer, 1, read_count, output) != read_count) {
            ok = 0;
            break;
        }
    }
    if (ferror(input)) ok = 0;
    if (fclose(input) != 0) ok = 0;
    if (fclose(output) != 0) ok = 0;
    if (!ok) {
        fprintf(stderr, "asset_import: failed while copying '%s'\n", source);
        remove(destination);
    }
    return ok;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--help") == 0) {
        printf("Usage: %s <source-image> <sprite-name>\n\n", argv[0]);
        printf("Copies a supported image to assets/imported/ and registers it in assets/sprites.txt.\n");
        return 0;
    }
    if (argc != 3 || !valid_name(argv[2])) {
        fprintf(stderr, "Usage: %s <source-image> <sprite-name>\n", argv[0]);
        fprintf(stderr, "Sprite names must start with a lowercase letter or digit and contain only lowercase letters, digits, '_' or '-'.\n");
        return 2;
    }

    int width = 0, height = 0, channels = 0;
    if (!stbi_info(argv[1], &width, &height, &channels)) {
        fprintf(stderr, "asset_import: could not read image '%s': %s\n", argv[1], stbi_failure_reason());
        return 1;
    }
    const char *extension = source_extension(argv[1]);
    if (extension == NULL) {
        fprintf(stderr, "asset_import: source image must have a simple file extension\n");
        return 2;
    }
    if (manifest_contains(argv[2])) {
        fprintf(stderr, "asset_import: sprite name '%s' is already registered\n", argv[2]);
        return 1;
    }

    int directory_result = make_directory("assets/imported");
    if (directory_result != 0 && errno != EEXIST) {
        fprintf(stderr, "asset_import: could not create assets/imported: %s\n", strerror(errno));
        return 1;
    }

    size_t destination_size = strlen(argv[2]) + strlen(extension) + sizeof "assets/imported/";
    if (destination_size - 1 > 255) {
        fprintf(stderr, "asset_import: generated asset path is too long\n");
        return 2;
    }
    char *destination = (char *)malloc(destination_size);
    if (destination == NULL) {
        fprintf(stderr, "asset_import: out of memory\n");
        free(destination);
        return 1;
    }
    snprintf(destination, destination_size, "assets/imported/%s%s", argv[2], extension);

    struct stat existing;
    if (stat(destination, &existing) == 0 || same_file(argv[1], destination)) {
        fprintf(stderr, "asset_import: destination '%s' already exists\n", destination);
        free(destination);
        return 1;
    }
    if (!copy_file(argv[1], destination)) {
        free(destination);
        return 1;
    }

    FILE *manifest = fopen("assets/sprites.txt", "a");
    int manifest_ok = manifest != NULL;
    if (manifest_ok && fprintf(manifest, "%s %s\n", argv[2], destination) < 0) manifest_ok = 0;
    if (manifest != NULL && fclose(manifest) != 0) manifest_ok = 0;
    if (!manifest_ok) {
        fprintf(stderr, "asset_import: could not update assets/sprites.txt\n");
        remove(destination);
        free(destination);
        return 1;
    }

    printf("Imported %s (%dx%d) as '%s' -> %s\n", argv[1], width, height, argv[2], destination);
    free(destination);
    return 0;
}
