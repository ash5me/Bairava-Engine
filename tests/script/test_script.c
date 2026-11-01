/*
 * test_script.c: checks the scripting runtime without a window or a GPU. Each check prints its
 * file and line when it fails, and the program exits nonzero if any check failed.
 */
#include "script.h"

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

/* Loads `source` into `vm` and reports whether it compiled and ran its top level cleanly. */
static int load(bs_vm *vm, const char *source)
{
    return bs_load(vm, "test.bs", source, strlen(source)) == BS_OK;
}

static double global_number(bs_vm *vm, const char *name)
{
    bs_value v;
    if (bs_get_global(vm, name, &v) != BS_OK || v.type != BS_NUMBER) {
        fprintf(stderr, "%s:%d: global '%s' is not a number\n", __FILE__, __LINE__, name);
        failures++;
        return -12345.0;
    }
    return v.as.number;
}

static int global_bool(bs_vm *vm, const char *name, int expected)
{
    bs_value v;
    if (bs_get_global(vm, name, &v) != BS_OK || v.type != BS_BOOL) {
        fprintf(stderr, "%s:%d: global '%s' is not a bool\n", __FILE__, __LINE__, name);
        failures++;
        return 0;
    }
    return (v.as.boolean != 0) == (expected != 0);
}

static int error_contains(bs_vm *vm, const char *text)
{
    return strstr(bs_error(vm), text) != NULL;
}

/* ---- Language --------------------------------------------------------------------------------- */

static void test_arithmetic_and_precedence(void)
{
    bs_vm *vm = bs_create(0);
    CHECK(load(vm, "var a = 1 + 2 * 3;\n"
                   "var b = (1 + 2) * 3;\n"
                   "var c = 10 - 4 - 3;\n"
                   "var d = 8 / 2 / 2;\n"
                   "var e = -3 + 5;\n"
                   "var f = 1.5 * 2;\n"
                   "var g = 0.25 + 0.25;\n"));
    CHECK(global_number(vm, "a") == 7);
    CHECK(global_number(vm, "b") == 9);
    CHECK(global_number(vm, "c") == 3);
    CHECK(global_number(vm, "d") == 2);
    CHECK(global_number(vm, "e") == 2);
    CHECK(global_number(vm, "f") == 3);
    CHECK(global_number(vm, "g") == 0.5);
    bs_destroy(vm);
}

static void test_comparison_logic_and_truthiness(void)
{
    bs_vm *vm = bs_create(0);
    CHECK(load(vm, "var t1 = 1 < 2 && 2 >= 2;\n"
                   "var t2 = !(1 == 1) || 3 != 3;\n"
                   "var t3 = nil == nil;\n"
                   "var t4 = \"a\" == \"a\";\n"
                   "var t5 = \"a\" == \"b\";\n"
                   "var t6 = 1 == true;\n"
                   "var zero = 0;\n"
                   "var r = 0;\n"
                   "fn check() { if (zero) { r = 1; } }\n"
                   "var s = false && missing();\n"
                   "var u = true || missing();\n"));
    CHECK(bs_call(vm, "check", 0, NULL, NULL) == BS_OK);
    CHECK(global_bool(vm, "t1", 1));
    CHECK(global_bool(vm, "t2", 0));
    CHECK(global_bool(vm, "t3", 1));
    CHECK(global_bool(vm, "t4", 1));
    CHECK(global_bool(vm, "t5", 0));
    CHECK(global_bool(vm, "t6", 0));
    CHECK(global_number(vm, "r") == 0);
    CHECK(global_bool(vm, "s", 0));
    CHECK(global_bool(vm, "u", 1));
    bs_destroy(vm);
}

static void test_control_flow_and_loops(void)
{
    bs_vm *vm = bs_create(0);
    CHECK(load(vm, "fn sum_to(n) {\n"
                   "    var total = 0;\n"
                   "    var i = 1;\n"
                   "    while (i <= n) {\n"
                   "        total = total + i;\n"
                   "        i = i + 1;\n"
                   "    }\n"
                   "    return total;\n"
                   "}\n"
                   "fn grade(x) {\n"
                   "    if (x >= 90) { return 3; } else if (x >= 50) { return 2; } else { return 1; }\n"
                   "}\n"
                   "var total = sum_to(10);\n"
                   "var g1 = grade(95);\n"
                   "var g2 = grade(60);\n"
                   "var g3 = grade(10);\n"));
    CHECK(global_number(vm, "total") == 55);
    CHECK(global_number(vm, "g1") == 3);
    CHECK(global_number(vm, "g2") == 2);
    CHECK(global_number(vm, "g3") == 1);
    CHECK(bs_call(vm, "grade", 0, NULL, NULL) == BS_ERROR); /* wrong arity, not a missing function */
    bs_destroy(vm);
}

static void test_functions_recursion_and_scope(void)
{
    bs_vm *vm = bs_create(0);
    bs_value arg;
    bs_value out;
    CHECK(load(vm, "fn fib(n) {\n"
                   "    if (n < 2) { return n; }\n"
                   "    return fib(n - 1) + fib(n - 2);\n"
                   "}\n"
                   "fn scope() {\n"
                   "    var x = 1;\n"
                   "    if (true) { var x = 2; }\n"
                   "    return x;\n"
                   "}\n"
                   "var counter = 0;\n"
                   "fn bump() { counter = counter + 1; }\n"));
    arg = bs_number(10);
    CHECK(bs_call(vm, "fib", 1, &arg, &out) == BS_OK);
    CHECK(out.type == BS_NUMBER && out.as.number == 55);
    CHECK(bs_call(vm, "scope", 0, NULL, &out) == BS_OK);
    CHECK(out.type == BS_NUMBER && out.as.number == 1);
    CHECK(bs_call(vm, "bump", 0, NULL, NULL) == BS_OK);
    CHECK(bs_call(vm, "bump", 0, NULL, NULL) == BS_OK);
    CHECK(bs_call(vm, "bump", 0, NULL, NULL) == BS_OK);
    CHECK(global_number(vm, "counter") == 3);
    CHECK(bs_call(vm, "no_such_function", 0, NULL, NULL) == BS_NOT_FOUND);
    bs_destroy(vm);
}

static void test_string_return_and_comments(void)
{
    bs_vm *vm = bs_create(0);
    bs_value out;
    CHECK(load(vm, "# a comment line\n"
                   "fn name() {\n"
                   "    return \"bairava\"; # trailing comment\n"
                   "}\n"));
    CHECK(bs_call(vm, "name", 0, NULL, &out) == BS_OK);
    CHECK(out.type == BS_STRING && out.as.string.len == 7 && memcmp(out.as.string.ptr, "bairava", 7) == 0);
    bs_destroy(vm);
}

static void test_builtins(void)
{
    bs_vm *vm = bs_create(0);
    CHECK(load(vm, "var a = abs(-4);\n"
                   "var b = min(3, 9);\n"
                   "var c = max(3, 9);\n"
                   "var d = clamp(12, 0, 10);\n"
                   "var e = clamp(-2, 0, 10);\n"));
    CHECK(global_number(vm, "a") == 4);
    CHECK(global_number(vm, "b") == 3);
    CHECK(global_number(vm, "c") == 9);
    CHECK(global_number(vm, "d") == 10);
    CHECK(global_number(vm, "e") == 0);
    CHECK(!load(vm, "var bad = clamp(1, 5, 2);\n"));
    bs_destroy(vm);
}

/* ---- Host bindings ---------------------------------------------------------------------------- */

static int add_calls = 0;
static char recorded[64];

static bs_status host_add(bs_vm *vm, void *user, int argc, const bs_value *argv, bs_value *result)
{
    (void)vm;
    (void)user;
    (void)argc;
    add_calls++;
    *result = bs_number(argv[0].as.number + argv[1].as.number);
    return BS_OK;
}

static bs_status host_record(bs_vm *vm, void *user, int argc, const bs_value *argv, bs_value *result)
{
    size_t n = argv[0].as.string.len < sizeof recorded - 1 ? argv[0].as.string.len : sizeof recorded - 1;
    (void)vm;
    (void)user;
    (void)argc;
    memcpy(recorded, argv[0].as.string.ptr, n);
    recorded[n] = '\0';
    *result = bs_nil();
    return BS_OK;
}

static bs_status host_fail(bs_vm *vm, void *user, int argc, const bs_value *argv, bs_value *result)
{
    (void)user;
    (void)argc;
    (void)argv;
    (void)result;
    return bs_fail(vm, "the door is locked");
}

static bs_status host_score(bs_vm *vm, void *user, int argc, const bs_value *argv, bs_value *result)
{
    (void)vm;
    (void)user;
    (void)argc;
    (void)argv;
    *result = bs_number(42);
    return BS_OK;
}

static void test_host_bindings(void)
{
    bs_vm *vm = bs_create(0);
    CHECK(bs_bind_function(vm, "add2", 2, 2, host_add, NULL) == BS_OK);
    CHECK(bs_bind_function(vm, "record", 1, 1, host_record, NULL) == BS_OK);
    CHECK(bs_bind_function(vm, "open_door", 0, 0, host_fail, NULL) == BS_OK);
    CHECK(bs_bind_getter(vm, "score", host_score, NULL) == BS_OK);
    CHECK(bs_bind_function(vm, "add2", 2, 2, host_add, NULL) == BS_ERROR); /* duplicate name */
    CHECK(bs_bind_function(vm, "9lives", 0, 0, host_add, NULL) == BS_ERROR); /* not an identifier */
    CHECK(load(vm, "var total = add2(score, 1);\n"
                   "fn announce() { record(\"hello host\"); }\n"));
    CHECK(global_number(vm, "total") == 43);
    CHECK(bs_call(vm, "announce", 0, NULL, NULL) == BS_OK);
    CHECK(add_calls == 1);
    CHECK(strcmp(recorded, "hello host") == 0);

    CHECK(!load(vm, "var x = add2(1);\n"));
    CHECK(error_contains(vm, "takes 2 arguments, but got 1"));
    CHECK(error_contains(vm, "test.bs:1:"));

    CHECK(!load(vm, "var y = 1;\nvar z = open_door();\n"));
    CHECK(error_contains(vm, "the door is locked"));
    CHECK(error_contains(vm, "test.bs:2:"));

    CHECK(load(vm, "fn f() { score = 3; }\n"));
    CHECK(bs_call(vm, "f", 0, NULL, NULL) == BS_ERROR);
    CHECK(error_contains(vm, "'score' is read-only"));
    bs_destroy(vm);
}

/* ---- Errors ----------------------------------------------------------------------------------- */

static void test_syntax_errors_name_the_line(void)
{
    bs_vm *vm = bs_create(0);
    CHECK(!load(vm, "var a = 1;\nvar b = ;\n"));
    CHECK(error_contains(vm, "test.bs:2: expected a value"));
    CHECK(!load(vm, "var s = \"open;\n"));
    CHECK(error_contains(vm, "closing quote"));
    CHECK(!load(vm, "x = 1;\n"));
    CHECK(error_contains(vm, "only 'var' and 'fn' can appear at the top level"));
    CHECK(!load(vm, "fn broken() {\n    var q = 1;\n"));
    CHECK(error_contains(vm, "closing '}'"));
    CHECK(!load(vm, "var a = 1 @ 2;\n"));
    CHECK(error_contains(vm, "unexpected character '@'"));
    bs_destroy(vm);
}

static void test_runtime_errors(void)
{
    bs_vm *vm = bs_create(0);
    CHECK(!load(vm, "var a = missing + 1;\n"));
    CHECK(error_contains(vm, "unknown name 'missing'"));
    CHECK(!load(vm, "var b = 1 / 0;\n"));
    CHECK(error_contains(vm, "division by zero"));
    CHECK(!load(vm, "var c = \"x\" + 1;\n"));
    CHECK(error_contains(vm, "needs two numbers"));
    CHECK(!load(vm, "var d = nosuch(1);\n"));
    CHECK(error_contains(vm, "unknown function 'nosuch'"));
    CHECK(load(vm, "fn f() { undeclared = 1; }\n"));
    CHECK(bs_call(vm, "f", 0, NULL, NULL) == BS_ERROR);
    CHECK(error_contains(vm, "not declared"));
    CHECK(!load(vm, "var dup = 1;\nvar dup = 2;\n"));
    CHECK(error_contains(vm, "'dup' is already defined"));
    CHECK(!load(vm, "fn abs() { return 1; }\n"));
    CHECK(error_contains(vm, "already a host function"));
    bs_destroy(vm);
}

static void test_step_and_depth_limits(void)
{
    bs_vm *vm = bs_create(5000);
    bs_value out;
    CHECK(load(vm, "fn spin() { while (true) { } }\n"
                   "fn down(n) { return down(n + 1); }\n"));
    CHECK(bs_call(vm, "spin", 0, NULL, NULL) == BS_ERROR);
    CHECK(error_contains(vm, "may never end"));
    CHECK(bs_call(vm, "down", 1, &(bs_value){ .type = BS_NUMBER, .as.number = 0 }, &out) == BS_ERROR);
    CHECK(error_contains(vm, "nested more than"));
    /* The budget resets for each call, so a later call still works. */
    CHECK(load(vm, "fn ok() { return 7; }\n"));
    CHECK(bs_call(vm, "ok", 0, NULL, &out) == BS_OK);
    CHECK(out.type == BS_NUMBER && out.as.number == 7);
    bs_destroy(vm);
}

/* ---- Reloading -------------------------------------------------------------------------------- */

static void test_reload_keeps_previous_script_on_failure(void)
{
    bs_vm *vm = bs_create(0);
    bs_value out;
    CHECK(load(vm, "var v = 1;\nfn value() { return v; }\n"));
    CHECK(!load(vm, "var v = 99;\nfn value() { return v + ; }\n"));
    CHECK(bs_call(vm, "value", 0, NULL, &out) == BS_OK);
    CHECK(out.type == BS_NUMBER && out.as.number == 1);
    CHECK(global_number(vm, "v") == 1);

    CHECK(!load(vm, "var v = 5;\nvar boom = 1 / 0;\n"));
    CHECK(global_number(vm, "v") == 1);

    CHECK(load(vm, "var v = 5;\nfn value() { return v * 2; }\n"));
    CHECK(bs_call(vm, "value", 0, NULL, &out) == BS_OK);
    CHECK(out.type == BS_NUMBER && out.as.number == 10);
    bs_destroy(vm);
}

static void test_clamp_and_limits_are_checked_at_binding(void)
{
    bs_vm *vm = bs_create(0);
    CHECK(bs_bind_function(vm, "too_many", 0, 9, host_add, NULL) == BS_ERROR);
    CHECK(bs_bind_function(vm, "backwards", 2, 1, host_add, NULL) == BS_ERROR);
    bs_destroy(vm);
}

int main(void)
{
    test_arithmetic_and_precedence();
    test_comparison_logic_and_truthiness();
    test_control_flow_and_loops();
    test_functions_recursion_and_scope();
    test_string_return_and_comments();
    test_builtins();
    test_host_bindings();
    test_syntax_errors_name_the_line();
    test_runtime_errors();
    test_step_and_depth_limits();
    test_reload_keeps_previous_script_on_failure();
    test_clamp_and_limits_are_checked_at_binding();

    if (failures != 0) {
        fprintf(stderr, "%d script check(s) failed\n", failures);
        return 1;
    }
    printf("script tests passed\n");
    return 0;
}
