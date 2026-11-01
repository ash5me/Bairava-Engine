# Scripting

Gameplay scripts are small programs in a C-like language. The engine runs them on the main thread, from the update
step. A script can read and change its own variables, define functions, and call the functions and values the game
binds for it. It cannot reach files, the network, or the operating system.

The runtime is in `src/engine/script/script.c` and `script.h`, with the Zig interface in `script.zig`. The game's
bindings are in `src/game/script_host.zig`, and the example script is `assets/scripts/game.bs`.

## Language

Comments start with `#` and run to the end of the line.

Values are `nil`, booleans (`true`, `false`), numbers (64-bit floats, written `12` or `0.25`), and strings written
in double quotes. A string cannot contain a double quote or a line break, and there are no escape sequences.

Truth: `nil`, `false`, and `0` are false. Everything else is true, including every string.

Operators, from tightest to loosest:

- unary `-` and `!`
- `*` and `/`
- `+` and `-`
- `<`, `<=`, `>`, `>=`
- `==` and `!=`
- `&&`, which short-circuits
- `||`, which short-circuits

`+`, `-`, `*`, `/`, and the comparisons need numbers. `==` and `!=` work on any values, and two values of different
types are never equal. Division by zero is an error.

Statements:

    var name = expression;          # declares a variable; the initializer is optional
    name = expression;              # assigns to a variable that exists
    if (condition) { ... } else if (condition) { ... } else { ... }
    while (condition) { ... }
    return expression;              # or `return;` for nil
    name(arguments);                # a call used as a statement

The top level of a script holds only `var` and `fn` declarations. A top-level `var` runs once, when the script loads,
in order. Anything that runs repeatedly goes inside a function.

    var count = 0;

    fn on_update() {
        if (clicks > count) {
            count = clicks;
        }
    }

Functions take up to eight parameters and return nil unless they `return` a value. A function sees its own parameters
and variables, the top-level variables, and the bound names. Variables declared with `var` live until the end of the
block they are in, and an inner declaration can shadow an outer one. Functions cannot be nested, and they cannot be
passed around as values.

Calls nest at most 64 deep.

## Built-in functions

`abs(x)`, `min(a, b)`, `max(a, b)`, and `clamp(x, low, high)`. Each takes numbers. `clamp` fails when `low` is
greater than `high`.

## Game bindings

The game provides these to every script:

| Name | Kind | Meaning |
|---|---|---|
| `clicks` | value | How many times the demo button was clicked |
| `volume` | value | The volume slider, from 0 to 1 |
| `zoom` | value | The zoom the game is aiming for |
| `dt` | value | Seconds in the current update step |
| `log(text)` | function | Writes `text` to the log, in the `script` scope |
| `set_volume(level)` | function | Sets the volume, clamped to 0 to 1 |
| `zoom_by(factor)` | function | Multiplies the zoom target, within the zoom limits; `factor` must be above zero |
| `zoom_reset()` | function | Aims the zoom back at 1 |

A value cannot be assigned to. `clicks = 3;` is an error, and so is any name nobody bound.

The game calls the script's `on_update` function once per update step, when the script defines one. A missing
`on_update` is not an error.

## Errors and limits

Every error carries the script's name and line, for example `game.bs:4: unknown name 'scor'`. A script that fails
while it loads leaves the previous script active. A script that fails during a call is logged once, and the game turns
it off for the rest of the run.

Each load or call may run at most `script_max_steps` steps. The game sets that to 100,000 in `src/game/config.zig`. A loop that never ends stops with an error instead of freezing the game.

Scripts are loaded once at startup. Reloading while the game runs is not wired yet, although `bs_load` already keeps the
previous script when a new one fails to compile.

## Adding a binding

In Zig, a host function takes the game's state and a `Call`, and returns a `script.Value`:

    fn spawnTile(state: *State, call: script.Call) script.HostError!script.Value {
        const x = script.asNumber(call.args[0]) orelse return call.fail("spawn needs a number");
        state.spawn(x);
        return script.nilValue();
    }

Bind it with `script.Bindings(State).function(&vm, "spawn", 1, 1, state, spawnTile)`. Bind a value with
`Bindings(State).value(&vm, "name", state, getter)`. The bindings keep a pointer to the state, so the state must
outlive the VM and must not move while the VM exists. The game keeps its bridge on the heap for that reason.

A host function must not call back into the script.

## Testing

The C tests in `tests/script/test_script.c` cover the language, the bindings, error messages, the limits, and reload
rollback. They run as part of `zig build test`. `tests/script/fuzz_script.c` feeds random token sequences to the
runtime; it is not part of the test build, and its header says how to run it under sanitizers.
