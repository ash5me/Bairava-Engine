//! The one C import of the UI headers, shared by ui/ui.zig and text/font.zig. Each @cImport makes
//! its own Zig types, so both files must use this one to agree on `ui_font` and the other types.

pub const c = @cImport({
    @cInclude("imgui.h");
});
