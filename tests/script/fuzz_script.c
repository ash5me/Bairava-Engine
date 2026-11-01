/*
 * fuzz_script.c: feeds random token sequences to the script runtime and checks it neither crashes nor leaves an
 * empty error. It is not part of `zig build test`. Run it under sanitizers, for example:
 *   cc -std=c11 -g -O1 -fsanitize=address,undefined -Isrc/engine/script tests/script/fuzz_script.c src/engine/script/script.c -o fuzz_script
 *   ./fuzz_script 1 20000
 */
#include "script.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static bs_status host_echo(bs_vm *vm, void *user, int argc, const bs_value *argv, bs_value *result) {
    (void)vm; (void)user; (void)argc; (void)argv; *result = bs_number(1); return BS_OK;
}
static bs_status host_getter(bs_vm *vm, void *user, int argc, const bs_value *argv, bs_value *result) {
    (void)vm; (void)user; (void)argc; (void)argv; *result = bs_number(2); return BS_OK;
}

static const char *pieces[] = {
    "var ", "fn ", "if ", "else ", "while ", "return ", "true ", "false ", "nil ",
    "x ", "y ", "f ", "abs", "min", "clamp", "echo", "gauge", "(", ")", "{", "}", ",", ";",
    "=", "+", "-", "*", "/", "!", "<", "<=", ">", ">=", "==", "!=", "&&", "||",
    "1", "2.5", "0", "\"s\"", "\"", "#c\n", "\n", " ", "@", "%", "..",
};

int main(int argc, char **argv) {
    unsigned seed = argc > 1 ? (unsigned)atoi(argv[1]) : 1u;
    int iterations = argc > 2 ? atoi(argv[2]) : 20000;
    size_t ok = 0, rejected = 0, ran = 0;
    srand(seed);
    for (int it = 0; it < iterations; it++) {
        char buf[512];
        size_t len = 0;
        int pieces_n = 1 + rand() % 60;
        for (int k = 0; k < pieces_n && len < sizeof buf - 32; k++) {
            const char *p = pieces[rand() % (sizeof pieces / sizeof pieces[0])];
            size_t pl = strlen(p);
            memcpy(buf + len, p, pl); len += pl;
        }
        bs_vm *vm = bs_create(2000);
        bs_bind_function(vm, "echo", 0, 2, host_echo, NULL);
        bs_bind_getter(vm, "gauge", host_getter, NULL);
        if (bs_load(vm, "fuzz.bs", buf, len) == BS_OK) {
            ok++;
            bs_value out;
            bs_call(vm, "f", 0, NULL, &out);
            bs_call(vm, "x", 1, &(bs_value){ .type = BS_NUMBER, .as.number = 3 }, &out);
            ran++;
        } else {
            rejected++;
            if (strlen(bs_error(vm)) == 0) { fprintf(stderr, "empty error for input #%d\n", it); return 2; }
        }
        bs_destroy(vm);
    }
    printf("fuzz: %d programs, %zu loaded, %zu rejected with a message, %zu run\n", iterations, ok, rejected, ran);
    return 0;
}
