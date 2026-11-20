# Rendering sprites and cameras

Rendering is submitted from the game's `draw` callback through the frame's `DrawContext.batch`.
The renderer owns the frame target and submission lifecycle; game code does not initialize or flush
the batch directly.

## World and screen coordinates

The camera and sprite rectangles use pixel-valued world coordinates. `DrawContext.cam` converts
world positions into the current view. Use its conversion methods when placing a sprite in world
space; screen-space UI can instead use the view layout.

The configured native view is a reference size, not a crop that changes with window aspect ratio.
The view is fitted into the window using the configured scale mode. Query the layout rather than
assuming that window points and world pixels are interchangeable, especially for mouse input.

## Submission and order

- Load a texture during initialization or update, then submit it during `draw`.
- `drawSprite` takes a source rectangle in texture texels and a destination rectangle in view pixels.
- Use `SpriteOptions.z` for depth ordering and preserve meaningful submission order for equal depth.
- Keep the `DrawContext` and references to its frame-scoped data inside the callback.
- Keep GPU operations on the engine thread.

The public [sample game](https://github.com/ash5me/Bairava-Engine/tree/main/sample) shows camera
conversion, sprite submission, tinting, and parallax. It is compiled by the normal build.

## Backend limits

SDL_GPU is the feature-complete renderer. The SDL3 2D renderer option is reserved and resolves to
SDL_GPU until the alternate path is implemented. Renderer capability queries are runtime
information; do not infer support from a requested configuration alone.
