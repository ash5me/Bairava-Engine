//! Deterministic rendering workload for measuring frame phases and draw submission.

const engine = @import("bairava");

const sprite_count: u32 = 1000;
const texture_path = "assets/sample/white.png";

const config = engine.Config{
    .title = "Bairava benchmark",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.06, 0.07, 0.09 },
    .settings_file = "benchmark_settings.txt",
};

const Benchmark = struct {
    texture: engine.Texture,

    pub fn init(ctx: *engine.Context) !Benchmark {
        return .{ .texture = try ctx.loadTexture(texture_path) };
    }

    pub fn update(self: *Benchmark, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        _ = self;
        _ = nav;
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.diagnostics_enabled) ctx.diagnostics.snapshot.world.entities = sprite_count;
    }

    pub fn draw(self: *Benchmark, dc: *const engine.DrawContext) void {
        var index: u32 = 0;
        while (index < sprite_count) : (index += 1) {
            const column = index % 40;
            const row = index / 40;
            const shade = @as(f32, @floatFromInt(index % 7)) / 12.0;
            dc.batch.drawSprite(
                &self.texture,
                .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                .{
                    .x = @as(f32, @floatFromInt(column)) * 8,
                    .y = @as(f32, @floatFromInt(row)) * 6,
                    .w = 8,
                    .h = 6,
                },
                .{ .tint = .{ 0.75 + shade, 0.8, 0.9 - shade } },
            );
        }
    }

    pub fn debugText(_: *const Benchmark, out: *engine.diagnostics.Text) void {
        out.print("benchmark: {d} deterministic sprites; Escape quits", .{sprite_count});
    }

    pub fn deinit(self: *Benchmark) void {
        self.texture.deinit();
    }
};

pub fn main() !void {
    try engine.run(engine.SceneHost(Benchmark), config);
}
