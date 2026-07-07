const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const window_width: f32 = 1040;
const window_height: f32 = 680;
const toolbar_height: f32 = 48;
const navigator_width: f32 = 260;
const statusbar_height: f32 = 34;
const apply_command = "panel.apply";

const html =
    \\<!doctype html>
    \\<html>
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:;">
    \\  <style>
    \\    :root { color-scheme: light dark; }
    \\    * { box-sizing: border-box; }
    \\    body {
    \\      margin: 0;
    \\      min-height: 100vh;
    \\      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", Segoe UI, system-ui, sans-serif;
    \\      background: #f8f9fb;
    \\      color: #18181b;
    \\    }
    \\    main {
    \\      min-height: 100vh;
    \\      padding: 34px 38px;
    \\      display: grid;
    \\      align-content: start;
    \\      gap: 20px;
    \\    }
    \\    h1 { margin: 0; font-size: 30px; line-height: 1.1; font-weight: 650; letter-spacing: 0; }
    \\    p { margin: 0; color: #636b76; line-height: 1.55; }
    \\    .grid {
    \\      display: grid;
    \\      grid-template-columns: repeat(3, minmax(0, 1fr));
    \\      gap: 12px;
    \\      max-width: 720px;
    \\    }
    \\    .metric {
    \\      border: 1px solid #e1e5ea;
    \\      border-radius: 7px;
    \\      padding: 14px;
    \\      background: white;
    \\    }
    \\    .metric strong { display: block; font-size: 24px; margin-bottom: 5px; }
    \\    .metric span { color: #68717d; font-size: 13px; }
    \\    button {
    \\      width: max-content;
    \\      border: 1px solid #18181b;
    \\      border-radius: 7px;
    \\      padding: 9px 13px;
    \\      font: inherit;
    \\      font-weight: 590;
    \\      color: white;
    \\      background: #18181b;
    \\      cursor: pointer;
    \\    }
    \\    pre {
    \\      width: min(720px, 100%);
    \\      min-height: 112px;
    \\      margin: 0;
    \\      padding: 14px 16px;
    \\      overflow: auto;
    \\      border: 1px solid #dde2e8;
    \\      border-radius: 7px;
    \\      background: white;
    \\      color: #374151;
    \\      font-size: 13px;
    \\      line-height: 1.45;
    \\    }
    \\    @media (prefers-color-scheme: dark) {
    \\      body { background: #101214; color: #f4f4f5; }
    \\      p, .metric span { color: #a1a1aa; }
    \\      .metric { background: #171a20; border-color: #2b3038; }
    \\      button { color: #101214; background: #f4f4f5; border-color: #f4f4f5; }
    \\      pre { color: #d4d4d8; background: #171a20; border-color: #2b3038; }
    \\    }
    \\  </style>
    \\</head>
    \\<body>
    \\  <main>
    \\    <h1>Pipeline overview</h1>
    \\    <p>The workspace content stays in the WebView while the surrounding panel controls remain native.</p>
    \\    <div class="grid">
    \\      <div class="metric"><strong>18</strong><span>Open tasks</span></div>
    \\      <div class="metric"><strong>7</strong><span>Ready to review</span></div>
    \\      <div class="metric"><strong>3</strong><span>Blocked items</span></div>
    \\    </div>
    \\    <button id="inspect" type="button">Inspect Panels</button>
    \\    <pre id="output">Ready.</pre>
    \\  </main>
    \\  <script>
    \\    const output = document.querySelector("#output");
    \\    const show = (value) => { output.textContent = JSON.stringify(value, null, 2); };
    \\    const fail = (error) => { output.textContent = `${error.code || "error"}: ${error.message}`; };
    \\    const listViews = () => {
    \\      if (window.zero && window.zero.views && window.zero.views.list) {
    \\        return window.zero.views.list();
    \\      }
    \\      return window.zero.invoke("native-sdk.view.list", null);
    \\    };
    \\    document.querySelector("#inspect").addEventListener("click", async () => {
    \\      try { show(await listViews()); } catch (error) { fail(error); }
    \\    });
    \\  </script>
    \\</body>
    \\</html>
;

const app_permissions = [_][]const u8{native_sdk.security.permission_view};
const bridge_origins = [_][]const u8{ "zero://inline", "zero://app" };
const view_permission = [_][]const u8{native_sdk.security.permission_view};
const builtin_policies = [_]native_sdk.BridgeCommandPolicy{
    .{ .name = "native-sdk.view.list", .permissions = &view_permission, .origins = &bridge_origins },
};
const shell_views = [_]native_sdk.ShellView{
    .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = toolbar_height, .layer = 20, .role = "Toolbar" },
    .{ .label = "toolbar-title", .kind = .label, .parent = "toolbar", .x = 16, .y = 14, .width = 220, .height = 20, .layer = 21, .text = "Pipeline" },
    .{ .label = "body", .kind = .split, .fill = true, .axis = .row },
    .{ .label = "navigator", .kind = .sidebar, .parent = "body", .width = navigator_width, .min_width = 220, .max_width = 320, .layer = 10, .role = "Navigator" },
    .{ .label = "filters", .kind = .stack, .parent = "navigator", .x = 18, .y = 18, .width = 220, .height = 210, .axis = .column, .layer = 11 },
    .{ .label = "filter-title", .kind = .label, .parent = "filters", .width = 220, .height = 20, .layer = 12, .text = "Filters" },
    .{ .label = "project-search", .kind = .search_field, .parent = "filters", .width = 220, .height = 28, .layer = 12, .text = "Search projects" },
    .{ .label = "view-mode", .kind = .segmented_control, .parent = "filters", .width = 172, .height = 30, .layer = 12, .text = "All|Open|Done" },
    .{ .label = "live-filter", .kind = .checkbox, .parent = "filters", .width = 160, .height = 24, .layer = 12, .text = "Live filters" },
    .{ .label = "preview-toggle", .kind = .toggle, .parent = "filters", .width = 140, .height = 28, .layer = 12, .text = "Preview" },
    .{ .label = "apply-filter", .kind = .button, .parent = "filters", .width = 92, .height = 30, .layer = 12, .accessibility_label = "Apply filters", .text = "Apply", .command = apply_command },
    .{ .label = "main", .kind = .webview, .parent = "body", .url = "zero://inline", .fill = true },
    .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = statusbar_height, .layer = 20, .role = "Status" },
    .{ .label = "status-label", .kind = .label, .parent = "statusbar", .x = 14, .y = 8, .width = 560, .height = 18, .layer = 21, .text = "Ready." },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Native Panels",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

const NativePanelsApp = struct {
    apply_count: u32 = 0,
    last_source: native_sdk.CommandSource = .runtime,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "native-panels",
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
                if (std.mem.eql(u8, command.name, apply_command)) {
                    try self.apply(runtime, command);
                }
            },
            .appearance_changed, .shortcut, .timer, .effects_wake, .audio, .files_dropped, .gpu_surface_frame, .gpu_surface_resized, .gpu_surface_input, .canvas_widget_pointer, .canvas_widget_keyboard, .canvas_widget_scroll, .canvas_widget_file_drop, .canvas_widget_drag, .canvas_widget_context_menu, .canvas_widget_context_menu_request, .canvas_widget_dismiss, .canvas_widget_context_press, .canvas_widget_resize, .canvas_widget_change, .window_closed, .automation_provenance, .lifecycle => {},
        }
    }

    fn apply(self: *@This(), runtime: *native_sdk.Runtime, command: native_sdk.CommandEvent) anyerror!void {
        self.apply_count += 1;
        self.last_source = command.source;
        var status_buffer: [128]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "Applied panel filters from {s}. Count {d}.", .{ @tagName(command.source), self.apply_count });
        _ = try runtime.updateView(command.window_id, "status-label", .{ .text = status });
    }
};

pub fn main(init: std.process.Init) !void {
    var app = NativePanelsApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "native-panels",
        .window_title = "Native SDK Native Panels",
        .bundle_id = "dev.native_sdk.native_panels",
        .default_frame = native_sdk.geometry.RectF.init(0, 0, window_width, window_height),
        .builtin_bridge = .{ .enabled = true, .commands = &builtin_policies },
        .js_window_api = true,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &bridge_origins },
        },
    }, init);
}

test "native panels compose split sidebar controls and web content" {
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{ .size = native_sdk.geometry.SizeF.init(window_width, window_height) });
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.builtin_bridge = .{ .enabled = true, .commands = &builtin_policies };
    harness.runtime.options.js_window_api = true;
    harness.runtime.options.security = .{
        .permissions = &app_permissions,
        .navigation = .{ .allowed_origins = &bridge_origins },
    };

    var app = NativePanelsApp{};
    try harness.start(app.app());

    var views_buffer: [20]native_sdk.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    const body = findView(views, "body").?;
    const navigator = findView(views, "navigator").?;
    const filters = findView(views, "filters").?;
    const content = findView(views, "main").?;

    try std.testing.expectEqual(native_sdk.ViewKind.split, body.kind);
    try std.testing.expectEqual(native_sdk.ViewKind.sidebar, navigator.kind);
    try std.testing.expectEqual(native_sdk.ViewKind.stack, filters.kind);
    try std.testing.expectEqual(native_sdk.ViewKind.webview, content.kind);
    try std.testing.expectEqualStrings("body", navigator.parent.?);
    try std.testing.expectEqualStrings("navigator", filters.parent.?);
    try std.testing.expectEqual(toolbar_height, body.frame.y);
    try std.testing.expectEqual(navigator_width, navigator.frame.width);
    try std.testing.expectEqual(navigator_width, content.frame.x);

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .native_command = .{
        .name = apply_command,
        .window_id = 1,
        .view_label = "apply-filter",
    } });
    try std.testing.expectEqual(@as(u32, 1), app.apply_count);
    try std.testing.expectEqual(native_sdk.CommandSource.native_view, app.last_source);

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"native-sdk.view.list\",\"payload\":null}",
        .origin = "zero://inline",
        .window_id = 1,
        .webview_label = "main",
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"navigator\"") != null);
}

fn findView(views: []const native_sdk.ViewInfo, label: []const u8) ?native_sdk.ViewInfo {
    for (views) |view| {
        if (std.mem.eql(u8, view.label, label)) return view;
    }
    return null;
}
