/*
 * script.h: the Bairava scripting runtime. Gameplay scripts are small programs in a C-like
 * language. They can read and write their own variables, call functions they define, and call the
 * host functions the game binds with bs_bind_function. A script can reach nothing else: it has no
 * I/O, no file access, and no way to call the operating system, so the game decides what a script
 * may touch.
 *
 * Language summary (see docs/scripting.md for the full reference):
 *   values      nil, true/false, numbers (64-bit floats), and string literals
 *   statements  var, assignment, if/else, while, return, and calls
 *   top level   var and fn declarations only; top-level vars run once when the script loads
 *   comments    # to the end of the line
 *
 * Threading: a VM belongs to one thread. Call it from the game's update step only.
 */
#ifndef BAIRAVA_SCRIPT_H
#define BAIRAVA_SCRIPT_H

#include <stddef.h>

typedef enum bs_type {
    BS_NIL,
    BS_BOOL,
    BS_NUMBER,
    BS_STRING
} bs_type;

/*
 * A script value. A string points into the script's own copy of its source, so it is valid only
 * until that script is replaced by bs_load. Copy any string the host keeps.
 */
typedef struct bs_value {
    bs_type type;
    union {
        int boolean;
        double number;
        struct {
            const char *ptr;
            size_t len;
        } string;
    } as;
} bs_value;

typedef enum bs_status {
    BS_OK = 0,
    /* A syntax, runtime, or host error. bs_error says what and where. */
    BS_ERROR,
    /* bs_call or bs_get_global: the script does not define that name. Optional hooks use this. */
    BS_NOT_FOUND
} bs_status;

typedef struct bs_vm bs_vm;

/*
 * A host function. `argv` holds `argc` values, which the VM has already checked against the
 * binding's argument range. `user` is the pointer given at binding. Store the return value in
 * *result. To fail, call bs_fail with a message and return BS_ERROR. The message gets the script
 * line that made the call.
 *
 * A host function must not call back into the VM.
 */
typedef bs_status (*bs_native_fn)(bs_vm *vm, void *user, int argc, const bs_value *argv, bs_value *result);

/* Creates a VM. `max_steps_per_call` bounds the work one bs_load or bs_call may do; zero uses a default. */
bs_vm *bs_create(size_t max_steps_per_call);
void bs_destroy(bs_vm *vm);

/*
 * Binds a host function that scripts call as `name(...)`. The name must be an identifier and
 * unique. Calls with fewer than `min_args` or more than `max_args` arguments fail before the
 * function runs. Built-in names abs, min, max, and clamp are already bound.
 */
bs_status bs_bind_function(bs_vm *vm, const char *name, int min_args, int max_args, bs_native_fn fn, void *user);

/*
 * Binds a host value that scripts read as a bare name, such as `clicks`. The getter is called with
 * no arguments each time the name is read. Scripts cannot assign to it.
 */
bs_status bs_bind_getter(bs_vm *vm, const char *name, bs_native_fn fn, void *user);

/*
 * Compiles `source` and runs its top-level var statements. `name` labels error messages. The
 * source is copied, so the caller may free it. On success the script replaces the previous one and
 * its variables start again. On failure the previous script stays active and bs_error says why.
 */
bs_status bs_load(bs_vm *vm, const char *name, const char *source, size_t length);

/*
 * Calls a function the loaded script defines. Returns BS_NOT_FOUND when there is no such function.
 * `result` may be NULL when the return value is not wanted.
 */
bs_status bs_call(bs_vm *vm, const char *function, int argc, const bs_value *argv, bs_value *result);

/* Reads a top-level variable of the loaded script. Returns BS_NOT_FOUND when it does not exist. */
bs_status bs_get_global(bs_vm *vm, const char *name, bs_value *out);

/* Sets the error message from a host function and returns BS_ERROR, for `return bs_fail(vm, "...");`. */
bs_status bs_fail(bs_vm *vm, const char *message);

/* The last error message, such as "hud.bs:12: unknown name 'x'", or an empty string. */
const char *bs_error(const bs_vm *vm);

bs_value bs_nil(void);
bs_value bs_bool(int value);
bs_value bs_number(double value);
bs_value bs_string(const char *ptr, size_t len);

#endif
