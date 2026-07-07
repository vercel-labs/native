const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const window_width: f32 = 860;
const window_height: f32 = 560;
const toolbar_height: f32 = 48;
const statusbar_height: f32 = 34;
const command_id = "app.sync";

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
    \\      background: #f7f8fa;
    \\      color: #171717;
    \\    }
    \\    main {
    \\      width: min(680px, calc(100vw - 48px));
    \\      padding: 42px 0;
    \\      margin: 0 auto;
    \\      display: grid;
    \\      gap: 18px;
    \\    }
    \\    h1 { margin: 0; font-size: 30px; line-height: 1.1; font-weight: 650; letter-spacing: 0; }
    \\    p { margin: 0; color: #606975; line-height: 1.55; }
    \\    .panel {
    \\      display: grid;
    \\      grid-template-columns: 1fr auto;
    \\      gap: 18px;
    \\      align-items: center;
    \\      padding: 18px 0;
    \\      border-top: 1px solid #e3e6ea;
    \\      border-bottom: 1px solid #e3e6ea;
    \\    }
    \\    button {
    \\      min-width: 116px;
    \\      border: 1px solid #171717;
    \\      border-radius: 7px;
    \\      padding: 9px 13px;
    \\      font: inherit;
    \\      font-weight: 590;
    \\      color: white;
    \\      background: #171717;
    \\      cursor: pointer;
    \\    }
    \\    pre {
    \\      min-height: 92px;
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
    \\      body { background: #111316; color: #f4f4f5; }
    \\      p { color: #a1a1aa; }
    \\      .panel { border-color: #2b2f37; }
    \\      button { color: #111316; background: #f4f4f5; border-color: #f4f4f5; }
    \\      pre { color: #d4d4d8; background: #171a20; border-color: #2b2f37; }
    \\    }
    \\  </style>
    \\</head>
    \\<body>
    \\  <main>
    \\    <h1>One command, five entry points</h1>
    \\    <p>The toolbar button, View menu, tray item, primary shortcut, and WebView button all dispatch app.sync into the same Zig command handler.</p>
    \\    <div class="panel">
    \\      <p>Dispatch from the WebView through the built-in command bridge.</p>
    \\      <button id="sync" type="button">Sync</button>
    \\      <button id="commands" type="button">List Commands</button>
    \\    </div>
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
    \\    const listCommands = () => {
    \\      if (window.zero && window.zero.commands && window.zero.commands.list) {
    \\        return window.zero.commands.list();
    \\      }
    \\      return window.zero.invoke("native-sdk.command.list", {});
    \\    };
    \\    document.querySelector("#sync").addEventListener("click", async () => {
    \\      try { show(await invokeCommand("app.sync")); } catch (error) { fail(error); }
    \\    });
    \\    document.querySelector("#commands").addEventListener("click", async () => {
    \\      try { show(await listCommands()); } catch (error) { fail(error); }
    \\    });
    \\  </script>
    \\</body>
    \\</html>
;

const app_permissions = [_][]const u8{native_sdk.security.permission_command};
const bridge_origins = [_][]const u8{ "zero://inline", "zero://app" };
const command_permission = [_][]const u8{native_sdk.security.permission_command};
const command_catalog = [_]native_sdk.Command{.{ .id = command_id, .title = "Sync" }};
const builtin_policies = [_]native_sdk.BridgeCommandPolicy{
    .{ .name = "native-sdk.command.invoke", .permissions = &command_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.command.list", .permissions = &command_permission, .origins = &bridge_origins },
};
const tray_items = [_]native_sdk.TrayMenuItem{
    .{ .id = 1, .label = "Sync", .command = command_id },
};
const shell_views = [_]native_sdk.ShellView{
    .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = toolbar_height, .layer = 20, .role = "Toolbar" },
    .{ .label = "sync-button", .kind = .button, .parent = "toolbar", .x = 12, .y = 9, .width = 92, .height = 30, .layer = 21, .accessibility_label = "Sync now", .text = "Sync", .command = command_id },
    .{ .label = "main", .kind = .webview, .url = "zero://inline", .fill = true },
    .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = statusbar_height, .layer = 20, .role = "Status" },
    .{ .label = "status-label", .kind = .label, .parent = "statusbar", .x = 14, .y = 8, .width = 620, .height = 18, .layer = 21, .text = "Ready. Use the toolbar, menu, tray, shortcut, or WebView button." },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Command App",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

const CommandApp = struct {
    command_count: u32 = 0,
    sources: [8]native_sdk.CommandSource = [_]native_sdk.CommandSource{.runtime} ** 8,
    last_command_name: []const u8 = "",

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "command-app",
            .source = native_sdk.WebViewSource.html(html),
            .scene_fn = scene,
            .start_fn = start,
            .event_fn = event,
        };
    }

    fn scene(context: *anyopaque) anyerror!native_sdk.ShellConfig {
        _ = context;
        return shell_scene;
    }

    fn start(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        _ = context;
        try runtime.createTray(.{
            .tooltip = "Native SDK Command App",
            .items = &tray_items,
        });
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event_value) {
            .command => |command| {
                if (std.mem.eql(u8, command.name, command_id)) {
                    try self.handleCommand(runtime, command);
                }
            },
            .appearance_changed, .shortcut, .timer, .effects_wake, .audio, .files_dropped, .gpu_surface_frame, .gpu_surface_resized, .gpu_surface_input, .canvas_widget_pointer, .canvas_widget_keyboard, .canvas_widget_scroll, .canvas_widget_file_drop, .canvas_widget_drag, .canvas_widget_context_menu, .canvas_widget_context_menu_request, .canvas_widget_dismiss, .canvas_widget_context_press, .canvas_widget_resize, .canvas_widget_change, .window_closed, .automation_provenance, .lifecycle => {},
        }
    }

    fn handleCommand(self: *@This(), runtime: *native_sdk.Runtime, command: native_sdk.CommandEvent) anyerror!void {
        if (self.command_count < self.sources.len) {
            self.sources[self.command_count] = command.source;
        }
        self.command_count += 1;
        self.last_command_name = command.name;

        var status_buffer: [128]u8 = undefined;
        const status = try std.fmt.bufPrint(
            &status_buffer,
            "Handled {s} from {s}. Count {d}.",
            .{ command.name, @tagName(command.source), self.command_count },
        );
        const status_window_id = if (command.window_id == 0) 1 else command.window_id;
        _ = try runtime.updateView(status_window_id, "status-label", .{ .text = status });
    }
};

pub fn main(init: std.process.Init) !void {
    var app = CommandApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "command-app",
        .window_title = "Native SDK Command App",
        .bundle_id = "dev.native_sdk.command_app",
        .default_frame = native_sdk.geometry.RectF.init(0, 0, window_width, window_height),
        .builtin_bridge = .{ .enabled = true, .commands = &builtin_policies },
        .js_window_api = true,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &bridge_origins },
        },
    }, init);
}

test "command app routes toolbar menu tray shortcut and bridge commands" {
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{ .size = native_sdk.geometry.SizeF.init(window_width, window_height) });
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.builtin_bridge = .{ .enabled = true, .commands = &builtin_policies };
    harness.runtime.options.js_window_api = true;
    harness.runtime.options.commands = &command_catalog;
    harness.runtime.options.security = .{
        .permissions = &app_permissions,
        .navigation = .{ .allowed_origins = &bridge_origins },
    };

    var app = CommandApp{};
    try harness.start(app.app());

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .native_command = .{
        .name = command_id,
        .window_id = 1,
        .view_label = "sync-button",
    } });
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .menu_command = .{
        .name = command_id,
        .window_id = 1,
    } });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.trayCreateCount());
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .tray_action = 1 });
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .shortcut = .{
        .id = command_id,
        .key = "s",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"native-sdk.command.invoke\",\"payload\":{\"name\":\"app.sync\"}}",
        .origin = "zero://inline",
        .window_id = 1,
        .webview_label = "main",
    } });
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"native-sdk.command.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
        .webview_label = "main",
    } });

    try std.testing.expectEqual(@as(u32, 5), app.command_count);
    try std.testing.expectEqualStrings(command_id, app.last_command_name);
    try std.testing.expectEqual(native_sdk.CommandSource.toolbar, app.sources[0]);
    try std.testing.expectEqual(native_sdk.CommandSource.menu, app.sources[1]);
    try std.testing.expectEqual(native_sdk.CommandSource.tray, app.sources[2]);
    try std.testing.expectEqual(native_sdk.CommandSource.shortcut, app.sources[3]);
    try std.testing.expectEqual(native_sdk.CommandSource.bridge, app.sources[4]);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"id\":\"app.sync\"") != null);
}
