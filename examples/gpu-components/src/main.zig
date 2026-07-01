const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const geometry = zero_native.geometry;
const model = @import("model.zig");
const component_app = @import("app.zig");

const GpuComponentsApp = component_app.GpuComponentsApp;

pub fn main(init: std.process.Init) !void {
    var app = GpuComponentsApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "gpu-components",
        .window_title = "zero-native GPU Components",
        .bundle_id = "dev.zero_native.gpu_components",
        .icon_path = "assets/icon.icns",
        .default_frame = geometry.RectF.init(0, 0, model.window_width, model.window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &component_app.app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
