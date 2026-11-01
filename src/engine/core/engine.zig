//! The engine's public API. Game code imports only this file: everything the game may use is
//! re-exported here, so the modules under src/engine/ can move without changing game code.
//!
//! Engine code never names a game type. A game plugs in by passing a type with `init`, `update`,
//! `draw`, and `deinit` to `run`. `init` runs once; then `update` and `draw` repeat until shutdown;
//! after successful initialization, `deinit` runs once. The game owns resources it loads and must
//! release them in `deinit` before the engine tears down the GPU and platform. If `init` fails,
//! `deinit` does not run, so `init` must release what it opened before the failing step. Game `init`
//! may return a recoverable error: `run` logs it, releases what the engine opened, and returns the
//! error to its caller, so a failed start never looks like a clean exit. Truly fatal programmer
//! errors and broken invariants still panic.
//!
//! Timing: `update` runs at a fixed rate, so game logic doesn't depend on the display. `draw`
//! runs once per frame and gets `alpha` to blend between the last two updates.

pub const Config = @import("application.zig").Config;
pub const Context = @import("context.zig").Context;
pub const AssetError = @import("context.zig").AssetError;
pub const Capabilities = @import("../capabilities.zig").Capabilities;
pub const ShaderFormats = @import("../capabilities.zig").ShaderFormats;
pub const TextureFormats = @import("../capabilities.zig").TextureFormats;
pub const PresentationCapabilities = @import("../capabilities.zig").PresentationCapabilities;
/// A translated, SDL-independent platform event delivered through `Context.pollEvent`.
pub const Event = @import("../platform/types.zig").Event;
pub const Scancode = @import("../platform/types.zig").Scancode;
pub const GamepadId = @import("../platform/types.zig").GamepadId;
pub const TextInput = @import("../platform/types.zig").TextInput;
pub const DrawContext = @import("context.zig").DrawContext;
pub const Allocators = @import("allocators.zig").ContextAllocators;
pub const run = @import("runtime.zig").run;

/// How the native view is fitted to the window. See `view.chooseFit`.
pub const ScaleMode = @import("../renderer/view.zig").ScaleMode;

/// A post-processing effect, named in `Config.post_effects`. See renderer/post.zig.
pub const Effect = @import("../renderer/render_types.zig").Effect;
/// The strengths the post-processing effects read, named in `Config.post_params`. See renderer/render_types.zig.
pub const PostParams = @import("../renderer/render_types.zig").PostParams;
/// The post-processing strengths the effects had before they could be changed.
pub const default_post_params = @import("../renderer/render_types.zig").default_post_params;
/// How urgently a texture is preloaded, for `Context.requestTexture`.
pub const TexturePriority = @import("context.zig").TexturePriority;

/// Keys, mouse, and gamepad state for the game. See input/input.zig.
pub const Input = @import("../input/input.zig").Input;
pub const Key = @import("../input/input.zig").Key;
/// Physical controls that actions can be bound to: a key, a mouse button, a gamepad button, or half of
/// a gamepad axis. See input/action.zig.
pub const Binding = @import("../input/action.zig").Binding;
/// Maps the game's actions to their bindings. Build one from `ActionDefaults`, and ask it about actions
/// each update step. See input/action.zig.
pub const ActionMap = @import("../input/action.zig").ActionMap;
/// The starting bindings of an action enum, as a table indexed by action. See input/action.zig.
pub const ActionDefaults = @import("../input/action.zig").Defaults;
/// Reads the `bind` lines of the settings file over a game's defaults. See input/mapping.zig.
pub const bindings = @import("../input/mapping.zig");
/// The buttons and axes of a standard gamepad, and the mouse buttons, as bindings name them.
pub const MouseButton = @import("../platform/types.zig").MouseButton;
pub const GamepadButton = @import("../platform/types.zig").GamepadButton;
pub const GamepadAxis = @import("../platform/types.zig").GamepadAxis;
pub const Camera = @import("../renderer/camera.zig").Camera;
pub const Rect = @import("../renderer/sprite.zig").Rect;
pub const SpriteBatch = @import("../renderer/sprite.zig").SpriteBatch;
/// A point light for lit sprites, added with `SpriteBatch.addLight` in `draw`. See renderer/sprite.zig.
pub const Light = @import("../renderer/sprite.zig").Light;
pub const Texture = @import("../renderer/texture.zig").Texture;
/// A texture atlas on the GPU, with where each sprite sits in it. See `Context.loadAtlas`.
pub const LoadedAtlas = @import("../renderer/loaded_atlas.zig").LoadedAtlas;
/// A counted reference to a texture registered with `Context.registerTexture`. See `Context.acquireTexture`.
pub const TextureHandle = @import("context.zig").TextureHandle;
/// Why a handle can't be used: it was never issued or was released, or its texture has been unloaded.
pub const HandleError = @import("../assets/handle.zig").LookupError;
/// Fits the native view to the window, and maps window, view, and world coordinates.
/// `Context.mouseWorld` uses the mapping.
pub const view = @import("../renderer/view.zig");
/// Vector and matrix math, backed by cglm.
pub const math = @import("math.zig");
/// Local transforms and parent-child world-matrix composition.
pub const transform = @import("transform.zig");
/// Validated fixed-capacity strings for names and paths.
pub const strings = @import("../memory/string.zig");
/// Hash map keyed by validated names.
pub const hash_map = @import("../memory/hash_map.zig");
/// Asset names, ids, and validated paths.
pub const assets = @import("../assets/registry.zig");
/// Asset validation rules: manifests, sprite lists, atlas indexes. See docs/asset-validation.md.
pub const validate = @import("../assets/validate.zig");
/// Development hot reload: which watched files changed. See docs/asset-validation.md.
pub const hot_reload = @import("../assets/hot_reload.zig");
/// Texture atlas index: the rectangle of each sprite inside the atlas image.
pub const atlas = @import("../assets/loaders/atlas.zig");
/// Custom struct vectors in an array-of-structs or structure-of-arrays layout.
pub const vector = @import("../memory/vector.zig");
/// The entity world: component rows with generational handles, stored in a vector.
pub const entity = @import("../ecs/entity.zig");
/// Tile maps: the map file format, layers, solid tiles, and box movement against them.
pub const tilemap = @import("../scene/tilemap.zig");
/// Queues tile map layers as sprites, one per visible tile. The map itself stays SDL-free.
pub const tilemap_draw = @import("../renderer/tilemap_draw.zig");
/// Sprite-sheet animation: clips that name a row of frames, and an animator that plays them.
pub const animation = @import("../animation/animation.zig");
/// Sound output: the playback device, sounds, and voices.
pub const audio = @import("../audio/audio.zig");
/// The settings file: `name = value` lines, and the window settings the engine reads from them.
pub const settings = @import("settings.zig");
/// Diagnostics: the text lines and debug shapes a game adds, and the frame snapshot. See docs/diagnostics.md.
pub const diagnostics = @import("../diagnostics/diagnostics.zig");
/// Bounded, development-only command registry and parser. See docs/developer-console.md.
pub const console = @import("../diagnostics/console.zig");
/// Debug geometry for the world: the tile grid, solid cells, and the camera bounds.
pub const debug_geometry = @import("../renderer/debug_geometry.zig");
/// Text and widgets: fonts baked with stb_truetype, and the IMGUI widgets in src/engine/ui/.
pub const ui = @import("../ui/ui.zig");
/// Logging and assertions. Game code uses `engine.log.scoped("name")` and `engine.log.assert`.
pub const log = @import("../logging/log.zig");
pub const crash = @import("../logging/crash.zig");
/// Profiling zones for the Tracy profiler. They record only when the build uses -Dtracy=true.
pub const profile = @import("../profiling/profile.zig");
/// Scenes: one active scene at a time, switched at a safe point. See scene/scene_manager.zig.
pub const scene = @import("../scene/scene.zig");
/// Runs a chain of scenes as a game. Pass `SceneHost(FirstScene)` to `run`.
pub fn SceneHost(comptime Root: type) type {
    return @import("../scene/host.zig").Host(Context, DrawContext, Root);
}
/// The handle a scene gets in `update`, for asking to change scene.
pub const SceneNavigator = @import("../scene/scene_manager.zig").Manager(Context, DrawContext).Navigator;
