const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const geometry = native_sdk.geometry;
const model = @import("model.zig");
const component_app = @import("app.zig");

const GpuComponentsApp = component_app.GpuComponentsApp;

pub fn main(init: std.process.Init) !void {
    var app = GpuComponentsApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "gpu-components",
        .window_title = "Native SDK GPU Components",
        .bundle_id = "dev.native_sdk.gpu_components",
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
