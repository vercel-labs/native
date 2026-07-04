//! system-monitor: a live CPU / memory / process monitor built to
//! showcase the Native SDK effects channel — no library calls into the
//! kernel, no third-party services, just the OS's own commands run
//! through `fx.spawn` on an `fx.startTimer` cadence.
//!
//! The loop: a repeating 2 s timer fires -> `update` spawns `ps` and the
//! per-OS memory command in `.collect` mode -> each exit Msg delivers the
//! whole stdout -> pure parsers (`sampler.zig`, fixture-tested against
//! committed real output) turn it into stat tiles, 60-sample sparkline
//! history, and a top-CPU process table with search, sort toggles, and a
//! confirmed SIGTERM context-menu action.
//!
//! Authoring split (markup-first): the header is a comptime-compiled
//! `.zml` view; the tiles, sparklines (bar charts built in Zig views —
//! one token-tinted bar widget per sample), toolbar (vector icons paired
//! with press handlers), table, and the confirmation overlay are Zig.
//! See `src/view.zig`.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const model_mod = @import("model.zig");
const theme = @import("theme.zig");
const view_mod = @import("view.zig");

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const update = model_mod.update;
pub const boot = model_mod.boot;
pub const rootView = view_mod.rootView;

pub const canvas_label = "monitor-canvas";
pub const window_width = view_mod.window_width;
pub const window_height = view_mod.window_height;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "System monitor canvas", .accessibility_label = "System monitor", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "System Monitor",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// -------------------------------------------------------------------- app

pub const MonitorApp = native_sdk.UiApp(Model, Msg);

pub fn monitorOptions() MonitorApp.Options {
    return .{
        .name = "system-monitor",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .view = rootView,
        .tokens_fn = tokensFromModel,
        .on_appearance = onAppearance,
    };
}

/// Design tokens derive from the model's theme preference plus the
/// OS-reported appearance (scheme, contrast, reduced motion).
pub fn tokensFromModel(model: *const Model) canvas.DesignTokens {
    return theme.tokens(model.colorScheme(), model.appearance.high_contrast, model.appearance.reduce_motion);
}

/// System appearance changes land in the model so `tokens_fn` re-derives;
/// the `auto` theme preference follows them live.
fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return Msg{ .set_appearance = appearance };
}

// ------------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(MonitorApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = MonitorApp.init(std.heap.page_allocator, .{}, monitorOptions());
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "system-monitor",
        .window_title = "System Monitor",
        .bundle_id = "dev.native_sdk.system_monitor",
        .icon_path = "assets/icon.icns",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
