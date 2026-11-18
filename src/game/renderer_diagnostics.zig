//! Temporary visual fixture for validating Canvas rectangles and text on both renderers.
//!
//! Call `draw(&game.ui.canvas, config.native_w, config.native_h)` while diagnostic mode is active.
//! The function clears the canvas and rebuilds the fixture every frame.
//!
//! Coordinates are in native view pixels. The fixture is designed for a 320x180 view.

const engine = @import("bairava");
const Canvas = engine.ui.Canvas;
const Color = engine.ui.Color;

const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
const black = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
const red = Color{ .r = 1, .g = 0, .b = 0, .a = 1 };
const green = Color{ .r = 0, .g = 1, .b = 0, .a = 1 };
const blue = Color{ .r = 0, .g = 0, .b = 1, .a = 1 };
const orange = Color{ .r = 1, .g = 0.45, .b = 0, .a = 1 };
const cyan = Color{ .r = 0, .g = 0.85, .b = 1, .a = 1 };
const yellow = Color{ .r = 1, .g = 0.9, .b = 0, .a = 1 };
const panel = Color{ .r = 0.10, .g = 0.12, .b = 0.16, .a = 1 };
const muted = Color{ .r = 0.68, .g = 0.72, .b = 0.78, .a = 1 };

/// Rebuilds the renderer diagnostic pattern on `canvas`.
///
/// Tests:
/// - opaque solid fills and tint;
/// - alpha blending over known backgrounds;
/// - painter order for overlapping rectangles;
/// - 1-, 2-, and 4-pixel geometry;
/// - alternating rectangle/text submissions (texture-run boundaries).
///
/// `view_w` and `view_h` should be the logical/native view dimensions, not window points.
pub fn draw(canvas: *Canvas, view_w: f32, view_h: f32) void {
    canvas.clear();

    // Background and title.
    canvas.rect(0, 0, view_w, view_h, panel);
    canvas.text(5, 3, "RENDERER DIAGNOSTICS  F6: close", white);

    // A. Solid fills: each swatch should be uniform and fully opaque.
    canvas.text(5, 17, "A. SOLID FILLS", muted);
    canvas.rect(5, 29, 34, 17, red);
    canvas.rect(43, 29, 34, 17, green);
    canvas.rect(81, 29, 34, 17, blue);
    canvas.rect(119, 29, 34, 17, white);
    canvas.rect(157, 29, 34, 17, orange);
    canvas.rect(195, 29, 34, 17, cyan);
    canvas.rect(233, 29, 34, 17, yellow);

    // B. Alpha: white overlays on black, middle gray, and white backgrounds.
    // Expected center colors are approximately RGB 128, 192, and 255 respectively
    // for 50%-alpha white over these three backgrounds.
    canvas.text(5, 51, "B. ALPHA  (WHITE @ 50%)", muted);
    canvas.rect(5, 63, 42, 17, black);
    canvas.rect(5, 63, 42, 17, .{ .r = 1, .g = 1, .b = 1, .a = 0.5 });

    canvas.rect(53, 63, 42, 17, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 });
    canvas.rect(53, 63, 42, 17, .{ .r = 1, .g = 1, .b = 1, .a = 0.5 });

    canvas.rect(101, 63, 42, 17, white);
    canvas.rect(101, 63, 42, 17, .{ .r = 1, .g = 1, .b = 1, .a = 0.5 });

    // Also check quarter- and three-quarter-alpha over black.
    canvas.rect(151, 63, 30, 17, black);
    canvas.rect(151, 63, 30, 17, .{ .r = 1, .g = 1, .b = 1, .a = 0.25 });
    canvas.rect(187, 63, 30, 17, black);
    canvas.rect(187, 63, 30, 17, .{ .r = 1, .g = 1, .b = 1, .a = 0.75 });
    canvas.text(223, 67, "25%   75%", white);

    // C. Painter order: red first, blue second, green last.
    // The visible overlap must be green over blue over red.
    canvas.text(5, 85, "C. OVERLAP  (RED -> BLUE -> GREEN)", muted);
    canvas.rect(7, 98, 48, 25, red);
    canvas.rect(27, 98, 48, 25, blue);
    canvas.rect(47, 98, 48, 25, green);

    // D. Pixel-aligned thin geometry.
    canvas.text(110, 85, "D. THIN LINES", muted);
    canvas.rect(112, 99, 48, 1, white);
    canvas.rect(112, 103, 48, 2, white);
    canvas.rect(112, 109, 48, 4, white);
    canvas.rect(166, 99, 1, 14, white);
    canvas.rect(171, 99, 2, 14, white);
    canvas.rect(178, 99, 4, 14, white);
    canvas.text(188, 101, "1 2 4 px", white);

    // E. Alternating submissions. Do not group/reorder these by texture:
    // rect -> text -> rect -> text -> rect. The order must remain visible.
    // This is especially useful after Canvas.rect moves to the renderer-owned white texture.
    canvas.text(5, 132, "E. RECT / GLYPH INTERLEAVING", muted);
    canvas.rect(5, 145, 22, 17, orange);
    canvas.text(31, 149, "TEXT 1", white);
    canvas.rect(82, 145, 22, 17, cyan);
    canvas.text(108, 149, "TEXT 2", white);
    canvas.rect(159, 145, 22, 17, yellow);
    canvas.text(185, 149, "TEXT 3", white);

    // F. Edge / clipping.
    // Each rectangle crosses one viewport boundary.
    // Only the portion inside the viewport should be visible.
    canvas.text(5, 168, "F. EDGE / CLIP", muted);

    // Top boundary
    canvas.rect(30, -3, 20, 6, red);

    // Left boundary
    canvas.rect(-3, 30, 6, 20, green);

    // Right boundary
    canvas.rect(view_w - 3, 55, 6, 20, blue);

    // Bottom boundary
    canvas.rect(60, view_h - 3, 20, 6, yellow);
}
