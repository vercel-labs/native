const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const window_width: f32 = 1120;
const window_height: f32 = 720;
const toolbar_height: f32 = 52;
const canvas_width: f32 = 680;
const statusbar_height: f32 = 34;
const refresh_command = "gpu.refresh";
const mode_command = "gpu.mode";

const html =
    \\<!doctype html>
    \\<html>
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; style-src 'self' 'unsafe-inline';">
    \\  <style>
    \\    :root { color-scheme: light dark; }
    \\    * { box-sizing: border-box; }
    \\    body {
    \\      margin: 0;
    \\      min-height: 100vh;
    \\      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", Segoe UI, system-ui, sans-serif;
    \\      background: #f7f8fb;
    \\      color: #16181d;
    \\    }
    \\    main {
    \\      min-height: 100vh;
    \\      padding: 34px 34px;
    \\      display: grid;
    \\      align-content: start;
    \\      gap: 18px;
    \\    }
    \\    h1 { margin: 0; font-size: 28px; line-height: 1.12; font-weight: 660; letter-spacing: 0; }
    \\    p { margin: 0; color: #606876; line-height: 1.55; }
    \\    .facts {
    \\      display: grid;
    \\      gap: 10px;
    \\      max-width: 360px;
    \\    }
    \\    .fact {
    \\      border: 1px solid #dde3ea;
    \\      border-radius: 7px;
    \\      padding: 12px 13px;
    \\      background: white;
    \\    }
    \\    .fact strong {
    \\      display: block;
    \\      font-size: 13px;
    \\      margin-bottom: 4px;
    \\    }
    \\    .fact span {
    \\      display: block;
    \\      color: #697386;
    \\      font-size: 13px;
    \\      line-height: 1.45;
    \\    }
    \\    @media (prefers-color-scheme: dark) {
    \\      body { background: #101216; color: #f4f6f8; }
    \\      p, .fact span { color: #a2aab7; }
    \\      .fact { background: #181b21; border-color: #2a303a; }
    \\    }
    \\  </style>
    \\</head>
    \\<body>
    \\  <main>
    \\    <h1>GPU surface</h1>
    \\    <p>The left pane is a native Metal-backed child view. This WebView remains a sibling surface in the same native shell.</p>
    \\    <div class="facts">
    \\      <div class="fact"><strong>Surface</strong><span><code>ViewKind.gpu_surface</code> now maps to a real AppKit Metal view.</span></div>
    \\      <div class="fact"><strong>Composition</strong><span>Native controls, WebView content, and GPU output share the same window layout.</span></div>
    \\      <div class="fact"><strong>Next layer</strong><span>The display-list renderer can sit above this surface without changing the app model.</span></div>
    \\    </div>
    \\  </main>
    \\</body>
    \\</html>
;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = toolbar_height, .layer = 20, .role = "Toolbar" },
    .{ .label = "toolbar-title", .kind = .label, .parent = "toolbar", .x = 18, .y = 16, .width = 220, .height = 20, .layer = 21, .text = "GPU Surface" },
    .{ .label = "frame-mode", .kind = .segmented_control, .parent = "toolbar", .x = 252, .y = 11, .width = 178, .height = 30, .layer = 21, .text = "Canvas|Hybrid", .command = mode_command },
    .{ .label = "refresh", .kind = .button, .parent = "toolbar", .x = 448, .y = 11, .width = 86, .height = 30, .layer = 21, .text = "Refresh", .command = refresh_command },
    .{ .label = "body", .kind = .split, .fill = true, .axis = .row },
    .{ .label = "canvas", .kind = .gpu_surface, .parent = "body", .width = canvas_width, .min_width = 480, .layer = 10, .role = "Animated Metal surface", .accessibility_label = "Animated GPU surface", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
    .{ .label = "inspector", .kind = .webview, .parent = "body", .url = "zero://inline", .fill = true },
    .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = statusbar_height, .layer = 20, .role = "Status" },
    .{ .label = "status-label", .kind = .label, .parent = "statusbar", .x = 14, .y = 8, .width = 720, .height = 18, .layer = 21, .text = "Metal surface ready." },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK GPU Surface",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

const GpuSurfaceApp = struct {
    refresh_count: u32 = 0,
    mode_count: u32 = 0,
    gpu_frame_count: u64 = 0,
    gpu_resize_count: u32 = 0,
    gpu_input_count: u32 = 0,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "gpu-surface",
            .source = native_sdk.WebViewSource.html(html),
            .scene_fn = scene,
            .event_fn = event,
        };
    }

    fn scene(context: *anyopaque) anyerror!native_sdk.ShellConfig {
        _ = context;
        return shell_scene;
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event_value) {
            .command => |command| {
                if (std.mem.eql(u8, command.name, refresh_command)) {
                    try self.refresh(runtime, command);
                } else if (std.mem.eql(u8, command.name, mode_command)) {
                    try self.toggleMode(runtime, command);
                }
            },
            .gpu_surface_frame => |frame_event| {
                if (std.mem.eql(u8, frame_event.label, "canvas") and self.gpu_frame_count == 0) {
                    self.gpu_frame_count = frame_event.frame_index + 1;
                    try self.updateStatus(runtime, frame_event.window_id, "GPU frame 1 from canvas.");
                }
            },
            .gpu_surface_resized => |resize_event| {
                if (std.mem.eql(u8, resize_event.label, "canvas")) {
                    self.gpu_resize_count += 1;
                }
            },
            .gpu_surface_input => |input_event| {
                if (std.mem.eql(u8, input_event.label, "canvas")) {
                    self.gpu_input_count += 1;
                }
            },
            .appearance_changed, .shortcut, .timer, .effects_wake, .audio, .files_dropped, .canvas_widget_pointer, .canvas_widget_keyboard, .canvas_widget_scroll, .canvas_widget_file_drop, .canvas_widget_drag, .canvas_widget_context_menu, .canvas_widget_context_menu_request, .canvas_widget_dismiss, .canvas_widget_context_press, .canvas_widget_resize, .canvas_widget_change, .window_closed, .automation_provenance, .lifecycle => {},
        }
    }

    fn updateStatus(self: *@This(), runtime: *native_sdk.Runtime, window_id: native_sdk.WindowId, text: []const u8) anyerror!void {
        _ = self;
        _ = try runtime.updateView(window_id, "status-label", .{ .text = text });
    }

    fn refresh(self: *@This(), runtime: *native_sdk.Runtime, command: native_sdk.CommandEvent) anyerror!void {
        self.refresh_count += 1;
        var status_buffer: [160]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "GPU surface refreshed from {s}. Count {d}.", .{ @tagName(command.source), self.refresh_count });
        try self.updateStatus(runtime, command.window_id, status);
    }

    fn toggleMode(self: *@This(), runtime: *native_sdk.Runtime, command: native_sdk.CommandEvent) anyerror!void {
        self.mode_count += 1;
        var status_buffer: [160]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "Mode control fired from {s}. Count {d}.", .{ @tagName(command.source), self.mode_count });
        try self.updateStatus(runtime, command.window_id, status);
    }
};

pub fn main(init: std.process.Init) !void {
    var app = GpuSurfaceApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "gpu-surface",
        .window_title = "Native SDK GPU Surface",
        .bundle_id = "dev.native_sdk.gpu_surface",
        .default_frame = native_sdk.geometry.RectF.init(0, 0, window_width, window_height),
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test "gpu surface scene declares gpu and web siblings" {
    try std.testing.expect(shell_views[5].kind == .gpu_surface);
    try std.testing.expect(shell_views[6].kind == .webview);
    try std.testing.expectEqualStrings("body", shell_views[5].parent.?);
    try std.testing.expectEqualStrings("body", shell_views[6].parent.?);
    try std.testing.expect(shell_views[5].gpu_backend.? == .metal);
    try std.testing.expect(shell_views[5].gpu_pixel_format.? == .bgra8_unorm);
    try std.testing.expect(shell_views[5].gpu_present_mode.? == .timer);
    try std.testing.expect(shell_views[5].gpu_alpha_mode.? == .@"opaque");
    try std.testing.expect(shell_views[5].gpu_color_space.? == .srgb);
    try std.testing.expect(shell_views[5].gpu_vsync.?);
}
