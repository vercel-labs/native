const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const canvas_label = "main-canvas";
const window_width: f32 = 420;
const window_height: f32 = 260;

const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Native-only canvas", .accessibility_label = "Native-only canvas", .gpu_backend = .software, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native Only",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub const Msg = union(enum) { toggle };

pub const Model = struct {
    active: bool = false,

    pub fn status(self: *const Model, arena: std.mem.Allocator) []const u8 {
        _ = arena;
        return if (self.active) "Active" else "Ready";
    }
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .toggle => model.active = !model.active,
    }
}

const NativeOnlyApp = native_sdk.UiApp(Model, Msg);

pub fn main(init: std.process.Init) !void {
    const app_state = try NativeOnlyApp.create(std.heap.page_allocator, .{
        .name = "native-only",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .markup = .{ .source = @embedFile("app.native"), .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "native-only",
        .window_title = "Native Only",
        .bundle_id = "dev.native_sdk.native_only",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
    }, init);
}

test "native-only fixture updates without web content" {
    var model: Model = .{};
    update(&model, .toggle);
    try std.testing.expect(model.active);
}
