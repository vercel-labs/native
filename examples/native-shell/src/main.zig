const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const window_width: f32 = 1100;
const window_height: f32 = 760;
const toolbar_height: f32 = 52;
const sidebar_width: f32 = 240;
const statusbar_height: f32 = 40;

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
    \\        <div class="label">View list</div>
    \\        <div class="meta">Reads the runtime view tree, including native views and the main WebView.</div>
    \\        <button id="views" type="button">List Views</button>
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
    \\      return window.zero.invoke("zero-native.command.invoke", { name });
    \\    };
    \\    document.querySelector("#refresh").addEventListener("click", async () => {
    \\      try { show(await invokeCommand("app.refresh")); } catch (error) { fail(error); }
    \\    });
    \\    document.querySelector("#views").addEventListener("click", async () => {
    \\      try { show(await window.zero.views.list()); } catch (error) { fail(error); }
    \\    });
    \\  </script>
    \\</body>
    \\</html>
;

const app_permissions = [_][]const u8{zero_native.security.permission_window};
const bridge_origins = [_][]const u8{ "zero://inline", "zero://app" };
const window_permission = [_][]const u8{zero_native.security.permission_window};
const builtin_policies = [_]zero_native.BridgeCommandPolicy{
    .{ .name = "zero-native.command.invoke", .permissions = &window_permission, .origins = &bridge_origins },
    .{ .name = "zero-native.view.list", .permissions = &window_permission, .origins = &bridge_origins },
};
const shortcuts = [_]zero_native.Shortcut{
    .{ .id = "app.refresh", .key = "r", .modifiers = .{ .primary = true } },
};
const view_menu_items = [_]zero_native.MenuItem{
    .{ .label = "Refresh", .command = "app.refresh", .key = "r", .modifiers = .{ .primary = true } },
};
const menus = [_]zero_native.Menu{
    .{ .title = "View", .items = &view_menu_items },
};
const shell_views = [_]zero_native.ShellView{
    .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = toolbar_height, .layer = 20, .role = "Toolbar" },
    .{ .label = "refresh-button", .kind = .button, .parent = "toolbar", .x = 12, .y = 10, .width = 88, .height = 30, .layer = 21, .text = "Refresh", .command = "app.refresh" },
    .{ .label = "palette-button", .kind = .button, .parent = "toolbar", .x = 108, .y = 10, .width = 132, .height = 30, .layer = 21, .text = "Command" },
    .{ .label = "title-search", .kind = .titlebar_accessory, .x = 780, .y = 8, .width = 300, .height = 36, .layer = 21, .role = "Search" },
    .{ .label = "surface-search", .kind = .search_field, .parent = "title-search", .x = 0, .y = 3, .width = 280, .height = 28, .layer = 22, .text = "Search native surfaces" },
    .{ .label = "sidebar", .kind = .sidebar, .edge = .left, .width = sidebar_width, .layer = 10, .role = "Sidebar" },
    .{ .label = "sidebar-title", .kind = .label, .parent = "sidebar", .x = 18, .y = 18, .width = 180, .height = 20, .layer = 11, .text = "Workspace" },
    .{ .label = "sidebar-item", .kind = .label, .parent = "sidebar", .x = 18, .y = 52, .width = 180, .height = 20, .layer = 11, .text = "Native chrome" },
    .{ .label = "sidebar-live", .kind = .checkbox, .parent = "sidebar", .x = 18, .y = 92, .width = 160, .height = 24, .layer = 11, .text = "Live native UI" },
    .{ .label = "sidebar-mode", .kind = .toggle, .parent = "sidebar", .x = 18, .y = 128, .width = 128, .height = 28, .layer = 11, .text = "Focus mode" },
    .{ .label = "main", .kind = .webview, .url = "zero://inline", .fill = true },
    .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = statusbar_height, .layer = 20, .role = "Status" },
    .{ .label = "status-label", .kind = .label, .parent = "statusbar", .x = 16, .y = 11, .width = 520, .height = 18, .layer = 21, .text = "Ready. Press Cmd-R or use the WebView button." },
};

const NativeShellApp = struct {
    refresh_count: u32 = 0,
    last_command_source: zero_native.CommandSource = .runtime,

    fn app(self: *@This()) zero_native.App {
        return .{
            .context = self,
            .name = "native-shell",
            .source = zero_native.WebViewSource.html(html),
            .start_fn = start,
            .event_fn = event,
        };
    }

    fn start(context: *anyopaque, runtime: *zero_native.Runtime) anyerror!void {
        _ = context;
        try runtime.createShellViews(1, &shell_views, zero_native.geometry.RectF.init(0, 0, window_width, window_height));
    }

    fn event(context: *anyopaque, runtime: *zero_native.Runtime, event_value: zero_native.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event_value) {
            .command => |command| {
                if (std.mem.eql(u8, command.name, "app.refresh")) {
                    try self.refresh(runtime, command.source);
                }
            },
            .shortcut, .files_dropped, .lifecycle => {},
        }
    }

    fn refresh(self: *@This(), runtime: *zero_native.Runtime, source: zero_native.CommandSource) anyerror!void {
        self.refresh_count += 1;
        self.last_command_source = source;
        var status_buffer: [128]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "Refreshed from {s}. Count {d}.", .{ @tagName(source), self.refresh_count });
        _ = try runtime.updateView(1, "status-label", .{ .text = status });
    }
};

pub fn main(init: std.process.Init) !void {
    var app = NativeShellApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "native-shell",
        .window_title = "zero-native Native Shell",
        .bundle_id = "dev.zero_native.native_shell",
        .icon_path = "assets/icon.icns",
        .default_frame = zero_native.geometry.RectF.init(0, 0, window_width, window_height),
        .builtin_bridge = .{ .enabled = true, .commands = &builtin_policies },
        .js_window_api = true,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &bridge_origins },
        },
        .menus = &menus,
        .shortcuts = &shortcuts,
    }, init);
}

test "native shell starts with native chrome views" {
    var harness: zero_native.TestHarness() = undefined;
    harness.init(.{ .size = zero_native.geometry.SizeF.init(window_width, window_height) });
    var app = NativeShellApp{};
    try harness.start(app.app());

    var views_buffer: [16]zero_native.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expect(containsView(views, "toolbar", .toolbar));
    try std.testing.expect(containsView(views, "surface-search", .search_field));
    try std.testing.expect(containsView(views, "sidebar", .sidebar));
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
    try std.testing.expectEqual(zero_native.CommandSource.toolbar, app.last_command_source);

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .menu_command = .{
        .name = "app.refresh",
        .window_id = 1,
    } });
    try std.testing.expectEqual(@as(u32, 2), app.refresh_count);
    try std.testing.expectEqual(zero_native.CommandSource.menu, app.last_command_source);

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .shortcut = .{
        .id = "app.refresh",
        .key = "r",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try std.testing.expectEqual(@as(u32, 3), app.refresh_count);
    try std.testing.expectEqual(zero_native.CommandSource.shortcut, app.last_command_source);
}

fn containsView(views: []const zero_native.ViewInfo, label: []const u8, kind: zero_native.ViewKind) bool {
    for (views) |view| {
        if (std.mem.eql(u8, view.label, label) and view.kind == kind) return true;
    }
    return false;
}
