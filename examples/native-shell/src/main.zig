const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const window_width: f32 = 1100;
const window_height: f32 = 760;
const toolbar_height: f32 = 52;
const sidebar_width: f32 = 240;
const statusbar_height: f32 = 40;
const preview_label = "preview";
const preview_url = "zero://inline";
const preview_frame = native_sdk.geometry.RectF.init(520, 96, 320, 220);

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
    \\      background: #f6f7f9;
    \\      color: #171717;
    \\    }
    \\    main {
    \\      min-height: 100vh;
    \\      padding: 34px 40px;
    \\      display: grid;
    \\      align-content: start;
    \\      gap: 22px;
    \\    }
    \\    header { max-width: 720px; }
    \\    h1 { margin: 0 0 8px; font-size: 30px; font-weight: 650; letter-spacing: 0; }
    \\    p { margin: 0; max-width: 620px; color: #5f6672; line-height: 1.55; }
    \\    section { display: grid; gap: 12px; max-width: 760px; }
    \\    .row {
    \\      display: grid;
    \\      grid-template-columns: 150px 1fr auto;
    \\      gap: 14px;
    \\      align-items: center;
    \\      min-height: 52px;
    \\      padding: 13px 0;
    \\      border-top: 1px solid #e6e8eb;
    \\    }
    \\    .row:last-child { border-bottom: 1px solid #e6e8eb; }
    \\    .label { font-weight: 590; }
    \\    .meta { color: #6b7280; line-height: 1.45; }
    \\    button {
    \\      min-width: 108px;
    \\      border: 1px solid #171717;
    \\      border-radius: 7px;
    \\      padding: 8px 12px;
    \\      font: inherit;
    \\      font-weight: 580;
    \\      color: white;
    \\      background: #171717;
    \\      cursor: pointer;
    \\    }
    \\    pre {
    \\      width: min(760px, 100%);
    \\      min-height: 58px;
    \\      margin: 0;
    \\      padding: 14px 16px;
    \\      overflow: auto;
    \\      border: 1px solid #dde1e6;
    \\      border-radius: 7px;
    \\      background: white;
    \\      color: #374151;
    \\      font-size: 13px;
    \\      line-height: 1.45;
    \\    }
    \\    @media (prefers-color-scheme: dark) {
    \\      body { background: #101114; color: #f4f4f5; }
    \\      p, .meta { color: #a1a1aa; }
    \\      .row { border-color: #292c33; }
    \\      .row:last-child { border-color: #292c33; }
    \\      button { color: #101114; background: #f4f4f5; border-color: #f4f4f5; }
    \\      pre { color: #d4d4d8; background: #17191f; border-color: #292c33; }
    \\    }
    \\  </style>
    \\</head>
    \\<body>
    \\  <main>
    \\    <header>
    \\      <h1>Native shell content</h1>
    \\      <p>The toolbar, sidebar, and statusbar are native views. This WebView owns only the content workspace.</p>
    \\    </header>
    \\    <section>
    \\      <div class="row">
    \\        <div class="label">Bridge command</div>
    \\        <div class="meta">Dispatches app.refresh through the built-in command bridge.</div>
    \\        <button id="refresh" type="button">Refresh</button>
    \\      </div>
    \\      <div class="row">
    \\        <div class="label">Runtime lists</div>
    \\        <div class="meta">Reads native views and manifest commands.</div>
    \\        <div><button id="views" type="button">Views</button> <button id="commands" type="button">Commands</button></div>
    \\      </div>
    \\    </section>
    \\    <pre id="output">Ready.</pre>
    \\  </main>
    \\  <script>
    \\    const output = document.querySelector("#output");
    \\    const show = (value) => { output.textContent = JSON.stringify(value, null, 2); };
    \\    const fail = (error) => { output.textContent = `${error.code || "error"}: ${error.message}`; };
    \\    const invokeCommand = (name) => {
    \\      if (window.zero && window.zero.commands && window.zero.commands.invoke) {
    \\        return window.zero.commands.invoke(name);
    \\      }
    \\      return window.zero.invoke("native-sdk.command.invoke", { name });
    \\    };
    \\    document.querySelector("#refresh").addEventListener("click", async () => {
    \\      try { show(await invokeCommand("app.refresh")); } catch (error) { fail(error); }
    \\    });
    \\    document.querySelector("#views").addEventListener("click", async () => {
    \\      try { show(await window.zero.views.list()); } catch (error) { fail(error); }
    \\    });
    \\    document.querySelector("#commands").addEventListener("click", async () => {
    \\      try { show(await window.zero.commands.list()); } catch (error) { fail(error); }
    \\    });
    \\  </script>
    \\</body>
    \\</html>
;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const bridge_origins = [_][]const u8{ "zero://inline", "zero://app" };
const command_permission = [_][]const u8{native_sdk.security.permission_command};
const view_permission = [_][]const u8{native_sdk.security.permission_view};
const builtin_policies = [_]native_sdk.BridgeCommandPolicy{
    .{ .name = "native-sdk.command.invoke", .permissions = &command_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.command.list", .permissions = &command_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.view.list", .permissions = &view_permission, .origins = &bridge_origins },
};
const shell_views = [_]native_sdk.ShellView{
    .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = toolbar_height, .layer = 20, .role = "Toolbar" },
    .{ .label = "refresh-button", .kind = .button, .parent = "toolbar", .x = 12, .y = 10, .width = 88, .height = 30, .layer = 21, .accessibility_label = "Refresh workspace", .text = "Refresh", .command = "app.refresh" },
    .{ .label = "palette-button", .kind = .button, .parent = "toolbar", .x = 108, .y = 10, .width = 132, .height = 30, .layer = 21, .text = "Command" },
    .{ .label = "refresh-icon", .kind = .icon_button, .parent = "toolbar", .x = 248, .y = 10, .width = 30, .height = 30, .layer = 21, .accessibility_label = "Refresh workspace", .text = "R", .command = "app.refresh" },
    .{ .label = "sync-indicator", .kind = .progress_indicator, .parent = "toolbar", .x = 288, .y = 13, .width = 24, .height = 24, .layer = 21, .role = "Syncing" },
    .{ .label = "view-mode", .kind = .segmented_control, .parent = "toolbar", .x = 324, .y = 10, .width = 168, .height = 30, .layer = 21, .text = "List|Grid", .command = "app.view.mode" },
    .{ .label = "title-search", .kind = .titlebar_accessory, .x = 780, .y = 8, .width = 300, .height = 36, .layer = 21, .role = "Search" },
    .{ .label = "surface-search", .kind = .search_field, .parent = "title-search", .x = 0, .y = 3, .width = 280, .height = 28, .layer = 22, .text = "Search native surfaces" },
    .{ .label = "sidebar", .kind = .sidebar, .edge = .left, .width = sidebar_width, .min_width = 200, .max_width = 320, .layer = 10, .role = "Sidebar" },
    .{ .label = "sidebar-title", .kind = .label, .parent = "sidebar", .x = 18, .y = 18, .width = 180, .height = 20, .layer = 11, .text = "Workspace" },
    .{ .label = "sidebar-stack", .kind = .stack, .parent = "sidebar", .x = 18, .y = 52, .width = 180, .height = 124, .axis = .column, .layer = 11 },
    .{ .label = "sidebar-item", .kind = .label, .parent = "sidebar-stack", .width = 180, .height = 20, .layer = 12, .text = "Native chrome" },
    .{ .label = "sidebar-live", .kind = .checkbox, .parent = "sidebar-stack", .width = 160, .height = 24, .layer = 12, .text = "Live native UI" },
    .{ .label = "sidebar-mode", .kind = .toggle, .parent = "sidebar-stack", .width = 128, .height = 28, .layer = 12, .text = "Focus mode" },
    .{ .label = "main", .kind = .webview, .url = "zero://inline", .fill = true },
    .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = statusbar_height, .layer = 20, .role = "Status" },
    .{ .label = "status-label", .kind = .label, .parent = "statusbar", .x = 16, .y = 11, .width = 520, .height = 18, .layer = 21, .text = "Ready. Press Cmd-R or use the WebView button." },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Native Shell",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

const NativeShellApp = struct {
    refresh_count: u32 = 0,
    last_command_source: native_sdk.CommandSource = .runtime,
    preview_open: bool = false,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "native-shell",
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
                if (std.mem.eql(u8, command.name, "app.refresh")) {
                    try self.refresh(runtime, command.source);
                } else if (std.mem.eql(u8, command.name, "app.preview.open")) {
                    try self.openPreview(runtime);
                } else if (std.mem.eql(u8, command.name, "app.preview.close")) {
                    try self.closePreview(runtime);
                }
            },
            .appearance_changed, .shortcut, .timer, .effects_wake, .audio, .files_dropped, .gpu_surface_frame, .gpu_surface_resized, .gpu_surface_input, .canvas_widget_pointer, .canvas_widget_keyboard, .canvas_widget_scroll, .canvas_widget_file_drop, .canvas_widget_drag, .canvas_widget_context_menu, .canvas_widget_context_menu_request, .canvas_widget_dismiss, .canvas_widget_context_press, .canvas_widget_resize, .canvas_widget_change, .window_closed, .automation_provenance, .lifecycle => {},
        }
    }

    fn refresh(self: *@This(), runtime: *native_sdk.Runtime, source: native_sdk.CommandSource) anyerror!void {
        self.refresh_count += 1;
        self.last_command_source = source;
        var status_buffer: [128]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "Refreshed from {s}. Count {d}.", .{ @tagName(source), self.refresh_count });
        try self.setStatus(runtime, status);
    }

    fn openPreview(self: *@This(), runtime: *native_sdk.Runtime) anyerror!void {
        if (!self.preview_open) {
            _ = try runtime.createView(.{
                .window_id = 1,
                .label = preview_label,
                .kind = .webview,
                .url = preview_url,
                .frame = preview_frame,
                .layer = 30,
            });
            self.preview_open = true;
        }
        try self.setStatus(runtime, "Preview WebView open.");
    }

    fn closePreview(self: *@This(), runtime: *native_sdk.Runtime) anyerror!void {
        if (self.preview_open) {
            try runtime.closeView(1, preview_label);
            self.preview_open = false;
        }
        try self.setStatus(runtime, "Preview WebView closed.");
    }

    fn setStatus(self: *@This(), runtime: *native_sdk.Runtime, status: []const u8) anyerror!void {
        _ = self;
        _ = try runtime.updateView(1, "status-label", .{ .text = status });
    }
};

pub fn main(init: std.process.Init) !void {
    var app = NativeShellApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "native-shell",
        .window_title = "Native SDK Native Shell",
        .bundle_id = "dev.native_sdk.native_shell",
        .default_frame = native_sdk.geometry.RectF.init(0, 0, window_width, window_height),
        .builtin_bridge = .{ .enabled = true, .commands = &builtin_policies },
        .js_window_api = true,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &bridge_origins },
        },
    }, init);
}

test "native shell starts with native chrome views" {
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{ .size = native_sdk.geometry.SizeF.init(window_width, window_height) });
    defer harness.destroy(std.testing.allocator);
    var app = NativeShellApp{};
    try harness.start(app.app());

    var views_buffer: [20]native_sdk.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expect(containsView(views, "toolbar", .toolbar));
    try std.testing.expect(containsView(views, "refresh-icon", .icon_button));
    try std.testing.expect(containsView(views, "view-mode", .segmented_control));
    try std.testing.expect(containsView(views, "surface-search", .search_field));
    try std.testing.expect(containsView(views, "sidebar", .sidebar));
    try std.testing.expect(containsView(views, "sidebar-stack", .stack));
    try std.testing.expect(containsView(views, "sidebar-live", .checkbox));
    try std.testing.expect(containsView(views, "sidebar-mode", .toggle));
    try std.testing.expect(containsView(views, "statusbar", .statusbar));
    try std.testing.expect(containsView(views, "status-label", .label));

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .native_command = .{
        .name = "app.refresh",
        .window_id = 1,
        .view_label = "refresh-button",
    } });
    try std.testing.expectEqual(@as(u32, 1), app.refresh_count);
    try std.testing.expectEqual(native_sdk.CommandSource.toolbar, app.last_command_source);

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .menu_command = .{
        .name = "app.refresh",
        .window_id = 1,
    } });
    try std.testing.expectEqual(@as(u32, 2), app.refresh_count);
    try std.testing.expectEqual(native_sdk.CommandSource.menu, app.last_command_source);

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .shortcut = .{
        .id = "app.refresh",
        .key = "r",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try std.testing.expectEqual(@as(u32, 3), app.refresh_count);
    try std.testing.expectEqual(native_sdk.CommandSource.shortcut, app.last_command_source);

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .menu_command = .{
        .name = "app.preview.open",
        .window_id = 1,
    } });
    try std.testing.expect(app.preview_open);
    const preview_views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expect(containsView(preview_views, preview_label, .webview));

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .menu_command = .{
        .name = "app.preview.close",
        .window_id = 1,
    } });
    try std.testing.expect(!app.preview_open);
    const closed_views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expect(!containsView(closed_views, preview_label, .webview));
}

fn containsView(views: []const native_sdk.ViewInfo, label: []const u8, kind: native_sdk.ViewKind) bool {
    for (views) |view| {
        if (std.mem.eql(u8, view.label, label) and view.kind == kind) return true;
    }
    return false;
}
