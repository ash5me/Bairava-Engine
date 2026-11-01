//! The diagnostics API the game and the overlays use: the text lines a game adds each frame, the
//! debug shapes it queues, and the published snapshot. See docs/diagnostics.md for the usage rules.

pub const Text = @import("text.zig").Text;
pub const DebugDraw = @import("debug_draw.zig").Draw;
pub const Color = @import("debug_draw.zig").Color;
pub const Collector = @import("collector.zig").Collector;
pub const Geometry = @import("collector.zig").Geometry;
pub const Snapshot = @import("collector.zig").Snapshot;
pub const Memory = @import("collector.zig").Memory;
pub const EntityInput = @import("collector.zig").EntityInput;
pub const ComponentInput = @import("collector.zig").ComponentInput;
pub const EntitySnapshot = @import("collector.zig").EntitySnapshot;
pub const ComponentSnapshot = @import("collector.zig").ComponentSnapshot;
pub const component_value_capacity = @import("collector.zig").component_value_capacity;
pub const FrameStats = @import("frame_stats.zig").Stats;
pub const Phase = @import("frame_stats.zig").Phase;
pub const Console = @import("console.zig").Console;
pub const console_commands = @import("console.zig").registry;
