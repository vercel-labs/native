//! terminal: a recordable terminal embed. libghostty-vt owns cell state
//! and damage; the pty effect vocabulary owns the transport; the canvas
//! owns the pixels. Record a session and it replays byte-identical
//! offline — no shell present.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const vt = @import("ghostty-vt");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "terminal-canvas";
const window_width: f32 = 980;
const window_height: f32 = 640;
pub const window_min_width: f32 = 640;
pub const window_min_height: f32 = 420;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Terminal canvas", .accessibility_label = "Terminal", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Terminal",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Model = struct {
    placeholder: u32 = 0,
};

pub const Msg = union(enum) {
    noop,
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .noop => model.placeholder += 1,
    }
}

const TerminalUi = canvas.Ui(Msg);

pub fn view(ui: *TerminalUi, model: *const Model) TerminalUi.Node {
    _ = model;
    return ui.panel(.{}, .{});
}

const TerminalApp = native_sdk.UiApp(Model, Msg);

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(TerminalApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = TerminalApp.init(std.heap.page_allocator, .{}, .{
        .name = "terminal",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .view = view,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "terminal",
        .window_title = "Terminal",
        .bundle_id = "dev.native_sdk.terminal",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

// ------------------------------------------------------------------ tests

test "the pinned libghostty-vt builds and round-trips terminal state" {
    const gpa = std.testing.allocator;
    var t: vt.Terminal = try .init(std.testing.io, gpa, .{ .cols = 20, .rows = 4 });
    defer t.deinit(gpa);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("hello \x1b[1;31mred\x1b[0m\r\n");
    const str = try t.plainString(gpa);
    defer gpa.free(str);
    try std.testing.expect(std.mem.indexOf(u8, str, "hello red") != null);
}
