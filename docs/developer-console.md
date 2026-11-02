# Developer command console

The console is available only when development tools are enabled. In Debug builds, press **F2** to
open/close it. Text is collected through SDL text input; Enter submits, Backspace edits, and Escape
closes it. The console uses fixed-size input/output buffers and does not evaluate expressions or
access files, memory, or code.

| Command | Purpose |
|---|---|
| `help` | List registered commands |
| `scene` | Show the scene hierarchy: open scenes from the root to the active one, the switch count, and any pending transition |
| `entities` | Show the published entity count |
| `assets` | Show texture cache counts and estimated bytes |
| `performance` | Show average, p95, and maximum frame time plus phase averages |
| `performance PHASE` | Inspect `frame`, `events`, `asset`, `update`, `audio`, `draw`, or `present` |
| `tile` | Show the ground tile and collision metadata under the cursor |
| `diagnostics on\|off\|toggle` | Show or hide the diagnostics overlay |
| `collision on\|off\|toggle` | Toggle collision visualization |
| `tiles on\|off\|toggle` | Toggle tile-boundary visualization |
| `layer NAME on\|off\|toggle` | Show/hide `ground`, `decoration`, or `foreground` |

Commands are explicitly registered in `engine/diagnostics/console.zig`. Arguments are checked
strictly; unknown commands and invalid arguments return usage text. Commands read the published
diagnostics snapshot or change only supported diagnostic visibility switches. The parser and
registry are pure and covered by `zig build test`.

Build with `zig build run -Ddev-tools=false` to omit the console and other development services.
Release builds have development tools disabled by default.
