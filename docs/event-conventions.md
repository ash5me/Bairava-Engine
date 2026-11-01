# Game-facing event conventions

`engine.Event` is the SDL-independent tagged union of translated platform events.
During `update`, call `ctx.pollEvent()` to remove the next event, or receive `null`
when the queue is empty:

```zig
while (ctx.pollEvent()) |event| {
    switch (event) {
        .key_down => |key| if (key.scancode == .f5 and !key.repeat) {
            // Handle a non-repeated F5 press.
        },
        .text_input => |text| {
            // `text.slice()` is valid while this copied event value is in scope.
            _ = text.slice();
        },
        else => {},
    }
}
```

## Ordering and lifetime

- The engine drains platform events once at the beginning of each outer frame, in
  platform arrival order. It handles engine commands first, then queues unconsumed
  events for the game, then applies them to `Input`.
- The game queue is FIFO. It is not automatically cleared between update steps.
  Polling removes an event exactly once; if a frame has no update step, its events
  remain queued for the next update. With multiple fixed updates in one frame,
  events remain available until game code polls them.
- Events are returned by value. Payloads such as `TextInput` are copied, so their
  storage does not depend on SDL's event buffer. Keep any derived slices or
  pointers only as long as their owning returned value remains alive.
- The queue grows as needed and reports allocation failure through `engine.run`;
  it does not silently discard events. It is owned by the run and released at
  shutdown.
- Window quit requests are handled by the engine and are not published. Events
  consumed by the development console are also hidden from game code. Other
  translated input, including engine hotkey key events, is available to the game.
- `Input` remains the preferred API for held controls, one-update presses and
  releases, mouse position, and gamepad state. Use events for ordered, individual
  platform actions such as text input or observing device connection transitions.
- A `GamepadId` identifies one connection generation. Treat it as valid only
  until its matching `gamepad_removed` event; a later connection may reuse its
  slot with a different generation.

The channel is for platform events, not arbitrary game-domain messages. For
communication between game systems, define a game-owned message type and queue
with explicit ownership appropriate to that game.
