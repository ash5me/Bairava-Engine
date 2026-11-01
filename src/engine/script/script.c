/*
 * script.c: the scripting runtime. Source is tokenized, parsed into a tree of nodes, and run by a
 * tree-walking evaluator. Every node a script runs costs one step, so a loop that never ends stops
 * with an error instead of freezing the game. Calls nest at most BS_MAX_DEPTH deep.
 *
 * Memory: a program owns its source copy, its names and nodes, and its globals. Nothing is
 * collected by a GC, because values are plain numbers, booleans, or strings that point into the
 * program's source. Replacing a script frees the old program in one step.
 */
#include "script.h"

#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BS_NAME_MAX 64
#define BS_MESSAGE_MAX 512 /* the last error, with its script name and line */
#define BS_DETAIL_MAX 256  /* one error's own text */
#define BS_NAME_SHOWN 120  /* longest script name shown in an error */
#define BS_MAX_NATIVES 128
#define BS_MAX_FUNCTIONS 128
#define BS_MAX_GLOBALS 256
#define BS_MAX_STACK 1024
#define BS_MAX_DEPTH 64
#define BS_MAX_PARAMS 8
#define BS_DEFAULT_STEPS 200000u

/* ---- Tokens ---------------------------------------------------------------------------------- */

typedef enum tok_kind {
    T_EOF,
    T_IDENT,
    T_NUMBER,
    T_STRING,
    T_LPAREN,
    T_RPAREN,
    T_LBRACE,
    T_RBRACE,
    T_COMMA,
    T_SEMI,
    T_ASSIGN,
    T_PLUS,
    T_MINUS,
    T_STAR,
    T_SLASH,
    T_BANG,
    T_LT,
    T_LE,
    T_GT,
    T_GE,
    T_EQ,
    T_NE,
    T_AND,
    T_OR,
    T_VAR,
    T_FN,
    T_IF,
    T_ELSE,
    T_WHILE,
    T_RETURN,
    T_TRUE,
    T_FALSE,
    T_NIL
} tok_kind;

typedef struct token {
    tok_kind kind;
    const char *text;
    size_t len;
    int line;
    double number;
} token;

typedef struct keyword_entry {
    const char *word;
    tok_kind kind;
} keyword_entry;

static const keyword_entry keywords[] = {
    {"var", T_VAR},     {"fn", T_FN},         {"if", T_IF},         {"else", T_ELSE},
    {"while", T_WHILE}, {"return", T_RETURN}, {"true", T_TRUE},     {"false", T_FALSE},
    {"nil", T_NIL},
};

/* Longer operators come first, so "<=" wins over "<". */
static const keyword_entry operators[] = {
    {"==", T_EQ},     {"!=", T_NE},     {"<=", T_LE},      {">=", T_GE},       {"&&", T_AND},
    {"||", T_OR},     {"(", T_LPAREN},  {")", T_RPAREN},   {"{", T_LBRACE},    {"}", T_RBRACE},
    {",", T_COMMA},   {";", T_SEMI},    {"=", T_ASSIGN},   {"+", T_PLUS},      {"-", T_MINUS},
    {"*", T_STAR},    {"/", T_SLASH},   {"!", T_BANG},     {"<", T_LT},        {">", T_GT},
};

/* ---- Syntax tree ----------------------------------------------------------------------------- */

typedef enum node_kind {
    N_NUMBER,
    N_STRING,
    N_BOOL,
    N_NIL,
    N_NAME,
    N_CALL,
    N_NEG,
    N_NOT,
    N_BINARY,
    N_AND,
    N_OR,
    N_VAR,
    N_ASSIGN,
    N_IF,
    N_WHILE,
    N_RETURN,
    N_EXPR,
    N_BLOCK
} node_kind;

typedef struct node node;
struct node {
    node_kind kind;
    tok_kind op;
    int line;
    int flag;
    double number;
    const char *text;
    size_t len;
    node *a;
    node *b;
    node *c;
    node **items;
    int count;
};

typedef struct fn_def {
    const char *name;
    size_t name_len;
    const char *params[BS_MAX_PARAMS];
    size_t param_lens[BS_MAX_PARAMS];
    int param_count;
    int line;
    node *body;
} fn_def;

typedef struct global_slot {
    const char *name;
    size_t len;
    bs_value value;
} global_slot;

/* One loaded script. Everything it owns is listed in `allocs` or is one of the fixed arrays below. */
typedef struct program {
    char *name;
    char *source;
    size_t source_len;
    void **allocs;
    size_t alloc_count;
    size_t alloc_cap;
    fn_def fns[BS_MAX_FUNCTIONS];
    int fn_count;
    node **top;
    int top_count;
    global_slot globals[BS_MAX_GLOBALS];
    int global_count;
} program;

/* ---- VM state -------------------------------------------------------------------------------- */

typedef struct native_slot {
    char name[BS_NAME_MAX];
    int getter;
    int min_args;
    int max_args;
    bs_native_fn fn;
    void *user;
} native_slot;

typedef struct local_slot {
    const char *name;
    size_t len;
    bs_value value;
} local_slot;

struct bs_vm {
    native_slot natives[BS_MAX_NATIVES];
    int native_count;
    program *prog;
    size_t max_steps;
    size_t steps_left;
    local_slot stack[BS_MAX_STACK];
    int stack_top;
    int frame_base;
    int depth;
    bs_value ret;
    char error[BS_MESSAGE_MAX];
};

typedef enum flow {
    FLOW_NEXT,
    FLOW_RETURN,
    FLOW_ERROR
} flow;

/* ---- Values ---------------------------------------------------------------------------------- */

bs_value bs_nil(void)
{
    bs_value v;
    v.type = BS_NIL;
    v.as.number = 0;
    return v;
}

bs_value bs_bool(int value)
{
    bs_value v;
    v.type = BS_BOOL;
    v.as.boolean = value ? 1 : 0;
    return v;
}

bs_value bs_number(double value)
{
    bs_value v;
    v.type = BS_NUMBER;
    v.as.number = value;
    return v;
}

bs_value bs_string(const char *ptr, size_t len)
{
    bs_value v;
    v.type = BS_STRING;
    v.as.string.ptr = ptr;
    v.as.string.len = len;
    return v;
}

/* nil, false, and zero are false. Everything else is true, including every string. */
static int truthy(bs_value v)
{
    switch (v.type) {
    case BS_NIL:
        return 0;
    case BS_BOOL:
        return v.as.boolean != 0;
    case BS_NUMBER:
        return v.as.number != 0.0;
    case BS_STRING:
        return 1;
    }
    return 0;
}

static int values_equal(bs_value a, bs_value b)
{
    if (a.type != b.type) return 0;
    switch (a.type) {
    case BS_NIL:
        return 1;
    case BS_BOOL:
        return (a.as.boolean != 0) == (b.as.boolean != 0);
    case BS_NUMBER:
        return a.as.number == b.as.number;
    case BS_STRING:
        return a.as.string.len == b.as.string.len &&
               (a.as.string.len == 0 || memcmp(a.as.string.ptr, b.as.string.ptr, a.as.string.len) == 0);
    }
    return 0;
}

/* ---- Errors ---------------------------------------------------------------------------------- */

/* Sets the error to "name:line: detail" for the script the VM is running, and returns 0. */
static int fail_at(bs_vm *vm, int line, const char *fmt, ...)
{
    char detail[BS_DETAIL_MAX];
    va_list args;
    va_start(args, fmt);
    vsnprintf(detail, sizeof detail, fmt, args);
    va_end(args);
    snprintf(vm->error, sizeof vm->error, "%.*s:%d: %s", BS_NAME_SHOWN, vm->prog ? vm->prog->name : "script", line, detail);
    return 0;
}

bs_status bs_fail(bs_vm *vm, const char *message)
{
    snprintf(vm->error, sizeof vm->error, "%s", message);
    return BS_ERROR;
}

const char *bs_error(const bs_vm *vm)
{
    return vm->error;
}

/* ---- Program memory -------------------------------------------------------------------------- */

static void *record_alloc(program *p, size_t size)
{
    void *mem;
    if (p->alloc_count == p->alloc_cap) {
        size_t cap = p->alloc_cap ? p->alloc_cap * 2 : 64;
        void **list = realloc(p->allocs, cap * sizeof *list);
        if (!list) return NULL;
        p->allocs = list;
        p->alloc_cap = cap;
    }
    mem = calloc(1, size);
    if (!mem) return NULL;
    p->allocs[p->alloc_count++] = mem;
    return mem;
}

static void program_free(program *p)
{
    size_t i;
    if (!p) return;
    for (i = 0; i < p->alloc_count; i++) free(p->allocs[i]);
    free(p->allocs);
    free(p->name);
    free(p->source);
    free(p);
}

static program *program_new(const char *name, const char *source, size_t length)
{
    program *p = calloc(1, sizeof *p);
    if (!p) return NULL;
    p->name = malloc(strlen(name) + 1);
    p->source = malloc(length + 1);
    if (!p->name || !p->source) {
        program_free(p);
        return NULL;
    }
    memcpy(p->name, name, strlen(name) + 1);
    memcpy(p->source, source, length);
    p->source[length] = '\0';
    p->source_len = length;
    return p;
}

/* ---- Lexer ----------------------------------------------------------------------------------- */

/* Compile state shared by the lexer and the parser. Compilation stops at the first error. */
typedef struct compiler {
    bs_vm *vm;
    program *prog;
    token *toks;
    int tok_count;
    int tok_cap;
    int pos;
    /* Child nodes waiting to be copied into a list. Nested lists stack above their parents. */
    node **stack;
    int stack_top;
    int stack_cap;
    int failed;
    int error_line;
    char message[BS_DETAIL_MAX];
} compiler;

static void cerr(compiler *c, int line, const char *fmt, ...)
{
    va_list args;
    if (c->failed) return;
    c->failed = 1;
    c->error_line = line;
    va_start(args, fmt);
    vsnprintf(c->message, sizeof c->message, fmt, args);
    va_end(args);
}

static int push_token(compiler *c, tok_kind kind, const char *text, size_t len, int line, double number)
{
    token *t;
    if (c->tok_count == c->tok_cap) {
        int cap = c->tok_cap ? c->tok_cap * 2 : 64;
        token *grown = realloc(c->toks, (size_t)cap * sizeof *grown);
        if (!grown) {
            cerr(c, line, "out of memory");
            return 0;
        }
        c->toks = grown;
        c->tok_cap = cap;
    }
    t = &c->toks[c->tok_count++];
    t->kind = kind;
    t->text = text;
    t->len = len;
    t->line = line;
    t->number = number;
    return 1;
}

static tok_kind keyword_or_ident(const char *text, size_t len)
{
    size_t i;
    for (i = 0; i < sizeof keywords / sizeof keywords[0]; i++) {
        if (strlen(keywords[i].word) == len && memcmp(keywords[i].word, text, len) == 0) return keywords[i].kind;
    }
    return T_IDENT;
}

static int lex(compiler *c)
{
    const char *s = c->prog->source;
    size_t n = c->prog->source_len;
    size_t i = 0;
    int line = 1;

    while (i < n) {
        unsigned char ch = (unsigned char)s[i];
        if (ch == '\n') {
            line++;
            i++;
            continue;
        }
        if (ch == ' ' || ch == '\t' || ch == '\r') {
            i++;
            continue;
        }
        if (ch == '#') {
            while (i < n && s[i] != '\n') i++;
            continue;
        }
        if (isalpha(ch) || ch == '_') {
            size_t start = i;
            tok_kind kind;
            while (i < n && (isalnum((unsigned char)s[i]) || s[i] == '_')) i++;
            kind = keyword_or_ident(s + start, i - start);
            if (!push_token(c, kind, s + start, i - start, line, 0)) return 0;
            continue;
        }
        if (isdigit(ch)) {
            double value = 0;
            double scale = 0.1;
            while (i < n && isdigit((unsigned char)s[i])) {
                value = value * 10 + (s[i] - '0');
                i++;
            }
            if (i + 1 < n && s[i] == '.' && isdigit((unsigned char)s[i + 1])) {
                i++;
                while (i < n && isdigit((unsigned char)s[i])) {
                    value += (s[i] - '0') * scale;
                    scale *= 0.1;
                    i++;
                }
            }
            if (!push_token(c, T_NUMBER, NULL, 0, line, value)) return 0;
            continue;
        }
        if (ch == '"') {
            size_t start = ++i;
            while (i < n && s[i] != '"' && s[i] != '\n') i++;
            if (i >= n || s[i] != '"') {
                cerr(c, line, "a string is missing its closing quote");
                return 0;
            }
            if (!push_token(c, T_STRING, s + start, i - start, line, 0)) return 0;
            i++;
            continue;
        }
        {
            size_t k;
            int matched = 0;
            for (k = 0; k < sizeof operators / sizeof operators[0]; k++) {
                size_t w = strlen(operators[k].word);
                if (i + w <= n && memcmp(s + i, operators[k].word, w) == 0) {
                    if (!push_token(c, operators[k].kind, s + i, w, line, 0)) return 0;
                    i += w;
                    matched = 1;
                    break;
                }
            }
            if (!matched) {
                cerr(c, line, "unexpected character '%c'", (char)ch);
                return 0;
            }
        }
    }
    return push_token(c, T_EOF, NULL, 0, line, 0);
}

/* ---- Parser ---------------------------------------------------------------------------------- */

static const token *cur(compiler *c)
{
    return &c->toks[c->pos];
}

static tok_kind kind_ahead(compiler *c, int offset)
{
    int index = c->pos + offset;
    if (index >= c->tok_count) return T_EOF;
    return c->toks[index].kind;
}

static void advance(compiler *c)
{
    if (cur(c)->kind != T_EOF) c->pos++;
}

static int accept(compiler *c, tok_kind kind)
{
    if (cur(c)->kind != kind) return 0;
    advance(c);
    return 1;
}

static int expect(compiler *c, tok_kind kind, const char *what)
{
    if (cur(c)->kind == kind) {
        advance(c);
        return 1;
    }
    cerr(c, cur(c)->line, "expected %s", what);
    return 0;
}

static node *new_node(compiler *c, node_kind kind, int line)
{
    node *n = record_alloc(c->prog, sizeof *n);
    if (!n) {
        cerr(c, line, "out of memory");
        return NULL;
    }
    n->kind = kind;
    n->line = line;
    return n;
}

static int list_push(compiler *c, node *n)
{
    if (c->stack_top == c->stack_cap) {
        int cap = c->stack_cap ? c->stack_cap * 2 : 64;
        node **grown = realloc(c->stack, (size_t)cap * sizeof *grown);
        if (!grown) {
            cerr(c, cur(c)->line, "out of memory");
            return 0;
        }
        c->stack = grown;
        c->stack_cap = cap;
    }
    c->stack[c->stack_top++] = n;
    return 1;
}

/* Copies the children pushed since `base` into a new list and pops them. A list with no children has no items. */
static node **list_take(compiler *c, int base, int *count)
{
    int n = c->stack_top - base;
    node **items = NULL;
    *count = n;
    if (n > 0) {
        items = record_alloc(c->prog, (size_t)n * sizeof *items);
        if (!items) {
            cerr(c, cur(c)->line, "out of memory");
            return NULL;
        }
        memcpy(items, c->stack + base, (size_t)n * sizeof *items);
    }
    c->stack_top = base;
    return items;
}

static node *parse_expr_prec(compiler *c, int min_prec);
static node *parse_block(compiler *c);
static node *parse_statement(compiler *c);

static int precedence(tok_kind kind)
{
    switch (kind) {
    case T_OR:
        return 1;
    case T_AND:
        return 2;
    case T_EQ:
    case T_NE:
        return 3;
    case T_LT:
    case T_LE:
    case T_GT:
    case T_GE:
        return 4;
    case T_PLUS:
    case T_MINUS:
        return 5;
    case T_STAR:
    case T_SLASH:
        return 6;
    default:
        return 0;
    }
}

static node *parse_expr(compiler *c)
{
    return parse_expr_prec(c, 1);
}

static node *parse_call(compiler *c)
{
    const token *name = cur(c);
    node *n;
    int base;
    n = new_node(c, N_CALL, name->line);
    if (!n) return NULL;
    n->text = name->text;
    n->len = name->len;
    advance(c); /* name */
    advance(c); /* ( */
    base = c->stack_top;
    if (cur(c)->kind != T_RPAREN) {
        for (;;) {
            node *arg = parse_expr(c);
            if (!arg || !list_push(c, arg)) return NULL;
            if (!accept(c, T_COMMA)) break;
        }
    }
    if (!expect(c, T_RPAREN, "')' after the arguments")) return NULL;
    n->items = list_take(c, base, &n->count);
    return c->failed ? NULL : n;
}

static node *parse_primary(compiler *c)
{
    const token *t = cur(c);
    node *n;
    switch (t->kind) {
    case T_NUMBER:
        n = new_node(c, N_NUMBER, t->line);
        if (!n) return NULL;
        n->number = t->number;
        advance(c);
        return n;
    case T_STRING:
        n = new_node(c, N_STRING, t->line);
        if (!n) return NULL;
        n->text = t->text;
        n->len = t->len;
        advance(c);
        return n;
    case T_TRUE:
    case T_FALSE:
        n = new_node(c, N_BOOL, t->line);
        if (!n) return NULL;
        n->flag = t->kind == T_TRUE;
        advance(c);
        return n;
    case T_NIL:
        n = new_node(c, N_NIL, t->line);
        if (!n) return NULL;
        advance(c);
        return n;
    case T_IDENT:
        if (kind_ahead(c, 1) == T_LPAREN) return parse_call(c);
        n = new_node(c, N_NAME, t->line);
        if (!n) return NULL;
        n->text = t->text;
        n->len = t->len;
        advance(c);
        return n;
    case T_LPAREN:
        advance(c);
        n = parse_expr(c);
        if (!n) return NULL;
        if (!expect(c, T_RPAREN, "')'")) return NULL;
        return n;
    default:
        cerr(c, t->line, "expected a value");
        return NULL;
    }
}

static node *parse_unary(compiler *c)
{
    tok_kind kind = cur(c)->kind;
    if (kind == T_MINUS || kind == T_BANG) {
        int line = cur(c)->line;
        node *operand;
        node *n;
        advance(c);
        operand = parse_unary(c);
        if (!operand) return NULL;
        n = new_node(c, kind == T_MINUS ? N_NEG : N_NOT, line);
        if (!n) return NULL;
        n->a = operand;
        return n;
    }
    return parse_primary(c);
}

/* Precedence climbing: binds tighter operators first, and groups equal ones to the left. */
static node *parse_expr_prec(compiler *c, int min_prec)
{
    node *left = parse_unary(c);
    if (!left) return NULL;
    for (;;) {
        tok_kind op = cur(c)->kind;
        int prec = precedence(op);
        int line = cur(c)->line;
        node *right;
        node *bin;
        if (prec == 0 || prec < min_prec) return left;
        advance(c);
        right = parse_expr_prec(c, prec + 1);
        if (!right) return NULL;
        bin = new_node(c, op == T_AND ? N_AND : op == T_OR ? N_OR : N_BINARY, line);
        if (!bin) return NULL;
        bin->op = op;
        bin->a = left;
        bin->b = right;
        left = bin;
    }
}

static node *parse_var(compiler *c)
{
    int line = cur(c)->line;
    node *n;
    advance(c); /* var */
    if (cur(c)->kind != T_IDENT) {
        cerr(c, cur(c)->line, "expected a name after 'var'");
        return NULL;
    }
    n = new_node(c, N_VAR, line);
    if (!n) return NULL;
    n->text = cur(c)->text;
    n->len = cur(c)->len;
    advance(c);
    if (accept(c, T_ASSIGN)) {
        n->a = parse_expr(c);
        if (!n->a) return NULL;
    }
    if (!expect(c, T_SEMI, "';' after the variable")) return NULL;
    return n;
}

static node *parse_assign(compiler *c)
{
    node *n = new_node(c, N_ASSIGN, cur(c)->line);
    if (!n) return NULL;
    n->text = cur(c)->text;
    n->len = cur(c)->len;
    advance(c); /* name */
    advance(c); /* = */
    n->a = parse_expr(c);
    if (!n->a) return NULL;
    if (!expect(c, T_SEMI, "';' after the assignment")) return NULL;
    return n;
}

static node *parse_if(compiler *c)
{
    int line = cur(c)->line;
    node *n;
    advance(c); /* if */
    if (!expect(c, T_LPAREN, "'(' after 'if'")) return NULL;
    n = new_node(c, N_IF, line);
    if (!n) return NULL;
    n->a = parse_expr(c);
    if (!n->a) return NULL;
    if (!expect(c, T_RPAREN, "')' after the condition")) return NULL;
    n->b = parse_block(c);
    if (!n->b) return NULL;
    if (accept(c, T_ELSE)) {
        n->c = cur(c)->kind == T_IF ? parse_if(c) : parse_block(c);
        if (!n->c) return NULL;
    }
    return n;
}

static node *parse_while(compiler *c)
{
    int line = cur(c)->line;
    node *n;
    advance(c); /* while */
    if (!expect(c, T_LPAREN, "'(' after 'while'")) return NULL;
    n = new_node(c, N_WHILE, line);
    if (!n) return NULL;
    n->a = parse_expr(c);
    if (!n->a) return NULL;
    if (!expect(c, T_RPAREN, "')' after the condition")) return NULL;
    n->b = parse_block(c);
    if (!n->b) return NULL;
    return n;
}

static node *parse_return(compiler *c)
{
    node *n;
    int line = cur(c)->line;
    advance(c); /* return */
    n = new_node(c, N_RETURN, line);
    if (!n) return NULL;
    if (cur(c)->kind != T_SEMI) {
        n->a = parse_expr(c);
        if (!n->a) return NULL;
    }
    if (!expect(c, T_SEMI, "';' after return")) return NULL;
    return n;
}

static node *parse_statement(compiler *c)
{
    const token *t = cur(c);
    switch (t->kind) {
    case T_VAR:
        return parse_var(c);
    case T_IF:
        return parse_if(c);
    case T_WHILE:
        return parse_while(c);
    case T_RETURN:
        return parse_return(c);
    case T_IDENT:
        if (kind_ahead(c, 1) == T_ASSIGN) return parse_assign(c);
        if (kind_ahead(c, 1) == T_LPAREN) {
            node *stmt = new_node(c, N_EXPR, t->line);
            if (!stmt) return NULL;
            stmt->a = parse_call(c);
            if (!stmt->a) return NULL;
            if (!expect(c, T_SEMI, "';' after the call")) return NULL;
            return stmt;
        }
        cerr(c, t->line, "expected '=' or '(' after '%.*s'", (int)t->len, t->text);
        return NULL;
    default:
        cerr(c, t->line, "expected a statement");
        return NULL;
    }
}

static node *parse_block(compiler *c)
{
    int line = cur(c)->line;
    int base;
    node *block;
    if (!expect(c, T_LBRACE, "'{' to start a block")) return NULL;
    base = c->stack_top;
    while (cur(c)->kind != T_RBRACE) {
        node *s;
        if (cur(c)->kind == T_EOF) {
            cerr(c, cur(c)->line, "a block is missing its closing '}'");
            return NULL;
        }
        s = parse_statement(c);
        if (!s || !list_push(c, s)) return NULL;
    }
    advance(c);
    block = new_node(c, N_BLOCK, line);
    if (!block) return NULL;
    block->items = list_take(c, base, &block->count);
    return c->failed ? NULL : block;
}

static int same_name(const char *a, size_t alen, const char *b, size_t blen)
{
    return alen == blen && memcmp(a, b, alen) == 0;
}

static native_slot *find_native(bs_vm *vm, const char *name, size_t len)
{
    int i;
    for (i = 0; i < vm->native_count; i++) {
        if (same_name(name, len, vm->natives[i].name, strlen(vm->natives[i].name))) return &vm->natives[i];
    }
    return NULL;
}

static fn_def *find_function(program *p, const char *name, size_t len)
{
    int i;
    if (!p) return NULL;
    for (i = 0; i < p->fn_count; i++) {
        if (same_name(name, len, p->fns[i].name, p->fns[i].name_len)) return &p->fns[i];
    }
    return NULL;
}

static global_slot *find_global(program *p, const char *name, size_t len)
{
    int i;
    if (!p) return NULL;
    for (i = 0; i < p->global_count; i++) {
        if (same_name(name, len, p->globals[i].name, p->globals[i].len)) return &p->globals[i];
    }
    return NULL;
}

static int parse_function(compiler *c)
{
    fn_def def;
    int line = cur(c)->line;
    memset(&def, 0, sizeof def);
    advance(c); /* fn */
    if (cur(c)->kind != T_IDENT) {
        cerr(c, cur(c)->line, "expected a function name after 'fn'");
        return 0;
    }
    def.name = cur(c)->text;
    def.name_len = cur(c)->len;
    def.line = line;
    advance(c);
    if (!expect(c, T_LPAREN, "'(' after the function name")) return 0;
    if (cur(c)->kind != T_RPAREN) {
        for (;;) {
            if (cur(c)->kind != T_IDENT) {
                cerr(c, cur(c)->line, "expected a parameter name");
                return 0;
            }
            if (def.param_count == BS_MAX_PARAMS) {
                cerr(c, cur(c)->line, "a function takes at most %d parameters", BS_MAX_PARAMS);
                return 0;
            }
            def.params[def.param_count] = cur(c)->text;
            def.param_lens[def.param_count] = cur(c)->len;
            def.param_count++;
            advance(c);
            if (!accept(c, T_COMMA)) break;
        }
    }
    if (!expect(c, T_RPAREN, "')' after the parameters")) return 0;
    def.body = parse_block(c);
    if (!def.body) return 0;

    if (find_native(c->vm, def.name, def.name_len)) {
        cerr(c, line, "'%.*s' is already a host function", (int)def.name_len, def.name);
        return 0;
    }
    if (find_function(c->prog, def.name, def.name_len)) {
        cerr(c, line, "'%.*s' is already defined", (int)def.name_len, def.name);
        return 0;
    }
    if (c->prog->fn_count == BS_MAX_FUNCTIONS) {
        cerr(c, line, "a script may define at most %d functions", BS_MAX_FUNCTIONS);
        return 0;
    }
    c->prog->fns[c->prog->fn_count++] = def;
    return 1;
}

static int compile_program(compiler *c)
{
    int base = c->stack_top;
    c->pos = 0;
    while (cur(c)->kind != T_EOF) {
        switch (cur(c)->kind) {
        case T_FN:
            if (!parse_function(c)) return 0;
            break;
        case T_VAR: {
            node *n = parse_var(c);
            if (!n || !list_push(c, n)) return 0;
            break;
        }
        default:
            cerr(c, cur(c)->line, "only 'var' and 'fn' can appear at the top level");
            return 0;
        }
    }
    c->prog->top = list_take(c, base, &c->prog->top_count);
    return !c->failed;
}

static void compiler_free(compiler *c)
{
    free(c->toks);
    free(c->stack);
}

/* ---- Evaluator ------------------------------------------------------------------------------- */

static int eval(bs_vm *vm, const node *n, bs_value *out);
static flow exec(bs_vm *vm, const node *n);
static flow exec_block(bs_vm *vm, const node *n);

static int tick(bs_vm *vm, int line)
{
    if (vm->steps_left == 0) {
        return fail_at(vm, line, "stopped after %zu steps, so a loop may never end", vm->max_steps);
    }
    vm->steps_left--;
    return 1;
}

static int find_local(bs_vm *vm, const char *name, size_t len, local_slot **out)
{
    int i;
    for (i = vm->stack_top - 1; i >= vm->frame_base; i--) {
        if (same_name(name, len, vm->stack[i].name, vm->stack[i].len)) {
            *out = &vm->stack[i];
            return 1;
        }
    }
    return 0;
}

static int call_native(bs_vm *vm, const native_slot *nat, int line, int argc, const bs_value *argv, bs_value *out)
{
    bs_value result = bs_nil();
    char message[BS_DETAIL_MAX];
    bs_status status;
    if (argc < nat->min_args || argc > nat->max_args) {
        if (nat->min_args == nat->max_args) {
            return fail_at(vm, line, "'%s' takes %d arguments, but got %d", nat->name, nat->min_args, argc);
        }
        return fail_at(vm, line, "'%s' takes %d to %d arguments, but got %d", nat->name, nat->min_args, nat->max_args, argc);
    }
    vm->error[0] = '\0';
    status = nat->fn(vm, nat->user, argc, argv, &result);
    if (status != BS_OK) {
        snprintf(message, sizeof message, "%.*s", BS_DETAIL_MAX - 1, vm->error[0] ? vm->error : "a host function failed");
        return fail_at(vm, line, "%s", message);
    }
    *out = result;
    return 1;
}

static int call_script(bs_vm *vm, const fn_def *fn, int line, int argc, const bs_value *argv, bs_value *out)
{
    int saved_base = vm->frame_base;
    int saved_top = vm->stack_top;
    flow f;
    int i;
    if (argc != fn->param_count) {
        return fail_at(vm, line, "'%.*s' takes %d arguments, but got %d", (int)fn->name_len, fn->name, fn->param_count, argc);
    }
    if (vm->depth >= BS_MAX_DEPTH) return fail_at(vm, line, "calls are nested more than %d deep", BS_MAX_DEPTH);
    if (vm->stack_top + argc > BS_MAX_STACK) return fail_at(vm, line, "too many local variables");

    vm->frame_base = vm->stack_top;
    for (i = 0; i < argc; i++) {
        local_slot *slot = &vm->stack[vm->stack_top++];
        slot->name = fn->params[i];
        slot->len = fn->param_lens[i];
        slot->value = argv[i];
    }
    vm->depth++;
    f = exec_block(vm, fn->body);
    vm->depth--;
    if (f == FLOW_ERROR) {
        vm->frame_base = saved_base;
        vm->stack_top = saved_top;
        return 0;
    }
    *out = f == FLOW_RETURN ? vm->ret : bs_nil();
    vm->frame_base = saved_base;
    vm->stack_top = saved_top;
    return 1;
}

static int lookup_value(bs_vm *vm, const node *n, bs_value *out)
{
    local_slot *loc;
    global_slot *g;
    native_slot *nat;
    if (find_local(vm, n->text, n->len, &loc)) {
        *out = loc->value;
        return 1;
    }
    g = find_global(vm->prog, n->text, n->len);
    if (g) {
        *out = g->value;
        return 1;
    }
    nat = find_native(vm, n->text, n->len);
    if (nat && nat->getter) return call_native(vm, nat, n->line, 0, NULL, out);
    if (nat) return fail_at(vm, n->line, "'%.*s' is a function; call it with ( )", (int)n->len, n->text);
    return fail_at(vm, n->line, "unknown name '%.*s'", (int)n->len, n->text);
}

static int call_named(bs_vm *vm, const node *n, bs_value *out)
{
    bs_value argv[BS_MAX_PARAMS];
    native_slot *nat;
    fn_def *fn;
    int i;
    if (n->count > BS_MAX_PARAMS) {
        return fail_at(vm, n->line, "a call takes at most %d arguments", BS_MAX_PARAMS);
    }
    for (i = 0; i < n->count; i++) {
        if (!eval(vm, n->items[i], &argv[i])) return 0;
    }
    nat = find_native(vm, n->text, n->len);
    if (nat && nat->getter) return fail_at(vm, n->line, "'%.*s' is a value, not a function", (int)n->len, n->text);
    if (nat) return call_native(vm, nat, n->line, n->count, argv, out);
    fn = find_function(vm->prog, n->text, n->len);
    if (fn) return call_script(vm, fn, n->line, n->count, argv, out);
    return fail_at(vm, n->line, "unknown function '%.*s'", (int)n->len, n->text);
}

static int eval_binary(bs_vm *vm, const node *n, bs_value *out)
{
    bs_value a;
    bs_value b;
    double x;
    double y;
    if (!eval(vm, n->a, &a) || !eval(vm, n->b, &b)) return 0;
    if (n->op == T_EQ) {
        *out = bs_bool(values_equal(a, b));
        return 1;
    }
    if (n->op == T_NE) {
        *out = bs_bool(!values_equal(a, b));
        return 1;
    }
    if (a.type != BS_NUMBER || b.type != BS_NUMBER) {
        return fail_at(vm, n->line, "this operator needs two numbers");
    }
    x = a.as.number;
    y = b.as.number;
    switch (n->op) {
    case T_PLUS:
        *out = bs_number(x + y);
        return 1;
    case T_MINUS:
        *out = bs_number(x - y);
        return 1;
    case T_STAR:
        *out = bs_number(x * y);
        return 1;
    case T_SLASH:
        if (y == 0.0) return fail_at(vm, n->line, "division by zero");
        *out = bs_number(x / y);
        return 1;
    case T_LT:
        *out = bs_bool(x < y);
        return 1;
    case T_LE:
        *out = bs_bool(x <= y);
        return 1;
    case T_GT:
        *out = bs_bool(x > y);
        return 1;
    case T_GE:
        *out = bs_bool(x >= y);
        return 1;
    default:
        return fail_at(vm, n->line, "internal error: unknown operator");
    }
}

static int eval(bs_vm *vm, const node *n, bs_value *out)
{
    bs_value v;
    if (!tick(vm, n->line)) return 0;
    switch (n->kind) {
    case N_NUMBER:
        *out = bs_number(n->number);
        return 1;
    case N_STRING:
        *out = bs_string(n->text, n->len);
        return 1;
    case N_BOOL:
        *out = bs_bool(n->flag);
        return 1;
    case N_NIL:
        *out = bs_nil();
        return 1;
    case N_NAME:
        return lookup_value(vm, n, out);
    case N_CALL:
        return call_named(vm, n, out);
    case N_NEG:
        if (!eval(vm, n->a, &v)) return 0;
        if (v.type != BS_NUMBER) return fail_at(vm, n->line, "'-' needs a number");
        *out = bs_number(-v.as.number);
        return 1;
    case N_NOT:
        if (!eval(vm, n->a, &v)) return 0;
        *out = bs_bool(!truthy(v));
        return 1;
    case N_AND:
        if (!eval(vm, n->a, &v)) return 0;
        if (!truthy(v)) {
            *out = bs_bool(0);
            return 1;
        }
        if (!eval(vm, n->b, &v)) return 0;
        *out = bs_bool(truthy(v));
        return 1;
    case N_OR:
        if (!eval(vm, n->a, &v)) return 0;
        if (truthy(v)) {
            *out = bs_bool(1);
            return 1;
        }
        if (!eval(vm, n->b, &v)) return 0;
        *out = bs_bool(truthy(v));
        return 1;
    case N_BINARY:
        return eval_binary(vm, n, out);
    default:
        return fail_at(vm, n->line, "internal error: a statement was used as a value");
    }
}

static int push_local(bs_vm *vm, const node *n, bs_value value)
{
    local_slot *slot;
    if (vm->stack_top >= BS_MAX_STACK) return fail_at(vm, n->line, "too many local variables");
    slot = &vm->stack[vm->stack_top++];
    slot->name = n->text;
    slot->len = n->len;
    slot->value = value;
    return 1;
}

static int assign(bs_vm *vm, const node *n, bs_value value)
{
    local_slot *loc;
    global_slot *g = find_global(vm->prog, n->text, n->len);
    if (find_local(vm, n->text, n->len, &loc)) {
        loc->value = value;
        return 1;
    }
    if (g) {
        g->value = value;
        return 1;
    }
    if (find_native(vm, n->text, n->len)) return fail_at(vm, n->line, "'%.*s' is read-only", (int)n->len, n->text);
    return fail_at(vm, n->line, "'%.*s' is not declared; declare it with var first", (int)n->len, n->text);
}

static flow exec_block(bs_vm *vm, const node *n)
{
    int saved = vm->stack_top;
    flow f = FLOW_NEXT;
    int i;
    for (i = 0; i < n->count && f == FLOW_NEXT; i++) f = exec(vm, n->items[i]);
    vm->stack_top = saved;
    return f;
}

static flow exec_while(bs_vm *vm, const node *n)
{
    for (;;) {
        bs_value cond;
        flow f;
        if (!eval(vm, n->a, &cond)) return FLOW_ERROR;
        if (!truthy(cond)) return FLOW_NEXT;
        f = exec(vm, n->b);
        if (f != FLOW_NEXT) return f;
    }
}

static flow exec(bs_vm *vm, const node *n)
{
    if (!tick(vm, n->line)) return FLOW_ERROR;
    switch (n->kind) {
    case N_BLOCK:
        return exec_block(vm, n);
    case N_VAR: {
        bs_value v = bs_nil();
        if (n->a && !eval(vm, n->a, &v)) return FLOW_ERROR;
        return push_local(vm, n, v) ? FLOW_NEXT : FLOW_ERROR;
    }
    case N_ASSIGN: {
        bs_value v;
        if (!eval(vm, n->a, &v)) return FLOW_ERROR;
        return assign(vm, n, v) ? FLOW_NEXT : FLOW_ERROR;
    }
    case N_IF: {
        bs_value cond;
        if (!eval(vm, n->a, &cond)) return FLOW_ERROR;
        if (truthy(cond)) return exec(vm, n->b);
        if (n->c) return exec(vm, n->c);
        return FLOW_NEXT;
    }
    case N_WHILE:
        return exec_while(vm, n);
    case N_RETURN: {
        bs_value v = bs_nil();
        if (n->a && !eval(vm, n->a, &v)) return FLOW_ERROR;
        vm->ret = v;
        return FLOW_RETURN;
    }
    case N_EXPR: {
        bs_value discard;
        return eval(vm, n->a, &discard) ? FLOW_NEXT : FLOW_ERROR;
    }
    default:
        fail_at(vm, n->line, "internal error: an expression was used as a statement");
        return FLOW_ERROR;
    }
}

/* Runs one top-level var: evaluates its value and adds it to the program's globals. */
static int run_top_var(bs_vm *vm, const node *n)
{
    bs_value v = bs_nil();
    program *p = vm->prog;
    if (find_native(vm, n->text, n->len)) return fail_at(vm, n->line, "'%.*s' is already a host name", (int)n->len, n->text);
    if (find_global(p, n->text, n->len)) return fail_at(vm, n->line, "'%.*s' is already defined", (int)n->len, n->text);
    if (n->a && !eval(vm, n->a, &v)) return 0;
    if (p->global_count == BS_MAX_GLOBALS) return fail_at(vm, n->line, "a script may define at most %d variables", BS_MAX_GLOBALS);
    p->globals[p->global_count].name = n->text;
    p->globals[p->global_count].len = n->len;
    p->globals[p->global_count].value = v;
    p->global_count++;
    return 1;
}

/* ---- Public API ------------------------------------------------------------------------------ */

static bs_status bind_name(bs_vm *vm, const char *name, int getter, int min_args, int max_args, bs_native_fn fn, void *user)
{
    size_t len;
    int i;
    native_slot *slot;
    if (!name || !fn) return bs_fail(vm, "a host binding needs a name and a function");
    len = strlen(name);
    if (len == 0 || len >= BS_NAME_MAX || !(isalpha((unsigned char)name[0]) || name[0] == '_')) {
        return bs_fail(vm, "a host binding name must be an identifier shorter than 64 characters");
    }
    for (i = 0; i < (int)len; i++) {
        if (!(isalnum((unsigned char)name[i]) || name[i] == '_')) return bs_fail(vm, "a host binding name must be an identifier");
    }
    if (find_native(vm, name, len)) return bs_fail(vm, "a host binding with this name already exists");
    if (vm->native_count == BS_MAX_NATIVES) return bs_fail(vm, "too many host bindings");
    slot = &vm->natives[vm->native_count++];
    memcpy(slot->name, name, len + 1);
    slot->getter = getter;
    slot->min_args = min_args;
    slot->max_args = max_args;
    slot->fn = fn;
    slot->user = user;
    return BS_OK;
}

bs_status bs_bind_function(bs_vm *vm, const char *name, int min_args, int max_args, bs_native_fn fn, void *user)
{
    if (min_args < 0 || max_args < min_args || max_args > BS_MAX_PARAMS) {
        return bs_fail(vm, "a host function takes between 0 and 8 arguments");
    }
    return bind_name(vm, name, 0, min_args, max_args, fn, user);
}

bs_status bs_bind_getter(bs_vm *vm, const char *name, bs_native_fn fn, void *user)
{
    return bind_name(vm, name, 1, 0, 0, fn, user);
}

static bs_status builtin_abs(bs_vm *vm, void *user, int argc, const bs_value *argv, bs_value *result)
{
    (void)user;
    (void)argc;
    if (argv[0].type != BS_NUMBER) return bs_fail(vm, "abs needs a number");
    *result = bs_number(argv[0].as.number < 0 ? -argv[0].as.number : argv[0].as.number);
    return BS_OK;
}

static bs_status builtin_min(bs_vm *vm, void *user, int argc, const bs_value *argv, bs_value *result)
{
    (void)user;
    (void)argc;
    if (argv[0].type != BS_NUMBER || argv[1].type != BS_NUMBER) return bs_fail(vm, "min needs two numbers");
    *result = bs_number(argv[0].as.number < argv[1].as.number ? argv[0].as.number : argv[1].as.number);
    return BS_OK;
}

static bs_status builtin_max(bs_vm *vm, void *user, int argc, const bs_value *argv, bs_value *result)
{
    (void)user;
    (void)argc;
    if (argv[0].type != BS_NUMBER || argv[1].type != BS_NUMBER) return bs_fail(vm, "max needs two numbers");
    *result = bs_number(argv[0].as.number > argv[1].as.number ? argv[0].as.number : argv[1].as.number);
    return BS_OK;
}

static bs_status builtin_clamp(bs_vm *vm, void *user, int argc, const bs_value *argv, bs_value *result)
{
    double x;
    double lo;
    double hi;
    (void)user;
    (void)argc;
    if (argv[0].type != BS_NUMBER || argv[1].type != BS_NUMBER || argv[2].type != BS_NUMBER) {
        return bs_fail(vm, "clamp needs three numbers");
    }
    x = argv[0].as.number;
    lo = argv[1].as.number;
    hi = argv[2].as.number;
    if (lo > hi) return bs_fail(vm, "clamp needs its lower bound to be at most its upper bound");
    *result = bs_number(x < lo ? lo : x > hi ? hi : x);
    return BS_OK;
}

bs_vm *bs_create(size_t max_steps_per_call)
{
    bs_vm *vm = calloc(1, sizeof *vm);
    if (!vm) return NULL;
    vm->max_steps = max_steps_per_call ? max_steps_per_call : BS_DEFAULT_STEPS;
    vm->ret = bs_nil();
    if (bs_bind_function(vm, "abs", 1, 1, builtin_abs, NULL) != BS_OK ||
        bs_bind_function(vm, "min", 2, 2, builtin_min, NULL) != BS_OK ||
        bs_bind_function(vm, "max", 2, 2, builtin_max, NULL) != BS_OK ||
        bs_bind_function(vm, "clamp", 3, 3, builtin_clamp, NULL) != BS_OK) {
        free(vm);
        return NULL;
    }
    return vm;
}

void bs_destroy(bs_vm *vm)
{
    if (!vm) return;
    program_free(vm->prog);
    free(vm);
}

bs_status bs_load(bs_vm *vm, const char *name, const char *source, size_t length)
{
    program *next;
    program *previous = vm->prog;
    compiler c;
    int i;

    next = program_new(name, source, length);
    if (!next) return bs_fail(vm, "out of memory loading a script");

    memset(&c, 0, sizeof c);
    c.vm = vm;
    c.prog = next;
    if (!lex(&c) || !compile_program(&c)) {
        snprintf(vm->error, sizeof vm->error, "%.*s:%d: %s", BS_NAME_SHOWN, name, c.error_line, c.message);
        compiler_free(&c);
        program_free(next);
        return BS_ERROR;
    }
    compiler_free(&c);

    /* The new program runs its top-level vars while it is current, so its functions are visible. */
    vm->prog = next;
    vm->steps_left = vm->max_steps;
    vm->stack_top = 0;
    vm->frame_base = 0;
    vm->depth = 0;
    vm->error[0] = '\0';
    for (i = 0; i < next->top_count; i++) {
        if (!run_top_var(vm, next->top[i])) {
            vm->prog = previous;
            program_free(next);
            return BS_ERROR;
        }
    }
    program_free(previous);
    return BS_OK;
}

bs_status bs_call(bs_vm *vm, const char *function, int argc, const bs_value *argv, bs_value *result)
{
    fn_def *fn;
    bs_value out = bs_nil();
    if (!vm->prog) return BS_NOT_FOUND;
    fn = find_function(vm->prog, function, strlen(function));
    if (!fn) return BS_NOT_FOUND;
    vm->steps_left = vm->max_steps;
    vm->stack_top = 0;
    vm->frame_base = 0;
    vm->depth = 0;
    vm->error[0] = '\0';
    if (!call_script(vm, fn, fn->line, argc, argv, &out)) return BS_ERROR;
    if (result) *result = out;
    return BS_OK;
}

bs_status bs_get_global(bs_vm *vm, const char *name, bs_value *out)
{
    global_slot *g = find_global(vm->prog, name, strlen(name));
    if (!g) return BS_NOT_FOUND;
    *out = g->value;
    return BS_OK;
}
