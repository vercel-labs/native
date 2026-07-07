const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const html =
    \\<!doctype html>
    \\<html>
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' http://127.0.0.1:5173 ws://127.0.0.1:5173">
    \\  <style>
    \\    body { margin: 0; min-height: 100vh; display: grid; place-items: center; font-family: -apple-system, system-ui, sans-serif; background: #f8fafc; color: #0f172a; }
    \\    main { width: min(560px, calc(100vw - 48px)); padding: 32px; border-radius: 18px; background: white; box-shadow: 0 20px 50px rgba(15, 23, 42, 0.12); }
    \\    h1 { margin: 0 0 12px; font-size: 32px; }
    \\    p { margin: 0 0 20px; line-height: 1.5; color: #475569; }
    \\    .actions { display: flex; flex-wrap: wrap; gap: 10px; }
    \\    button { border: 0; border-radius: 999px; padding: 10px 16px; font: inherit; font-weight: 600; color: white; background: #2563eb; cursor: pointer; }
    \\    pre { min-height: 52px; margin: 18px 0 0; padding: 14px; border-radius: 12px; overflow: auto; background: #0f172a; color: #dbeafe; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <main>
    \\    <h1>Hello from Native SDK</h1>
    \\    <p>A small Zig desktop shell around the system WebView with a secure native command bridge.</p>
    \\    <div class="actions">
    \\      <button id="ping" type="button">Call native.ping</button>
    \\      <button id="open-window" type="button">Open JS window</button>
    \\      <button id="list-windows" type="button">List windows</button>
    \\      <button id="focus-window" type="button">Focus JS window</button>
    \\      <button id="close-window" type="button">Close JS window</button>
    \\      <button id="open-webview" type="button">Open child WebView</button>
    \\      <button id="resize-webview" type="button">Resize WebView</button>
    \\      <button id="navigate-webview" type="button">Navigate WebView</button>
    \\      <button id="close-webview" type="button">Close WebView</button>
    \\    </div>
    \\    <pre id="output">Bridge ready.</pre>
    \\  </main>
    \\  <script>
    \\    const output = document.querySelector("#output");
    \\    let jsWindow = null;
    \\    let childWebView = null;
    \\    function show(value) {
    \\      output.textContent = JSON.stringify(value, null, 2);
    \\    }
    \\    document.querySelector("#ping").addEventListener("click", async () => {
    \\      try {
    \\        const result = await window.zero.invoke("native.ping", { source: "webview" });
    \\        show(result);
    \\      } catch (error) {
    \\        output.textContent = `${error.code || "error"}: ${error.message}`;
    \\      }
    \\    });
    \\    document.querySelector("#open-window").addEventListener("click", async () => {
    \\      jsWindow = await window.zero.windows.create({
    \\        label: `js-tools-${Date.now()}`,
    \\        title: "JS Tools",
    \\        width: 420,
    \\        height: 320,
    \\      });
    \\      show(jsWindow);
    \\    });
    \\    document.querySelector("#list-windows").addEventListener("click", async () => {
    \\      show(await window.zero.windows.list());
    \\    });
    \\    document.querySelector("#focus-window").addEventListener("click", async () => {
    \\      if (jsWindow) show(await window.zero.windows.focus(jsWindow.id));
    \\    });
    \\    document.querySelector("#close-window").addEventListener("click", async () => {
    \\      if (jsWindow) show(await window.zero.windows.close(jsWindow.id));
    \\    });
    \\    document.querySelector("#open-webview").addEventListener("click", async () => {
    \\      childWebView = await window.zero.webviews.create({
    \\        label: "preview",
    \\        url: "https://example.com",
    \\        frame: { x: 24, y: 24, width: 420, height: 260 },
    \\      });
    \\      show(childWebView);
    \\    });
    \\    document.querySelector("#resize-webview").addEventListener("click", async () => {
    \\      if (childWebView) show(await childWebView.setFrame({ x: 36, y: 36, width: 520, height: 320 }));
    \\    });
    \\    document.querySelector("#navigate-webview").addEventListener("click", async () => {
    \\      if (childWebView) show(await childWebView.navigate("https://example.com/?native-sdk=1"));
    \\    });
    \\    document.querySelector("#close-webview").addEventListener("click", async () => {
    \\      if (childWebView) {
    \\        show(await childWebView.close());
    \\        childWebView = null;
    \\      }
    \\    });
    \\  </script>
    \\</body>
    \\</html>
;

const app_permissions = [_][]const u8{native_sdk.security.permission_window};
const example_origins = [_][]const u8{ "zero://inline", "zero://app" };
const bridge_policies = [_]native_sdk.BridgeCommandPolicy{.{ .name = "native.ping" }};
const window_permission = [_][]const u8{native_sdk.security.permission_window};
const builtin_policies = [_]native_sdk.BridgeCommandPolicy{
    .{ .name = "native-sdk.window.list", .permissions = &window_permission, .origins = &example_origins },
    .{ .name = "native-sdk.window.create", .permissions = &window_permission, .origins = &example_origins },
    .{ .name = "native-sdk.window.focus", .permissions = &window_permission, .origins = &example_origins },
    .{ .name = "native-sdk.window.close", .permissions = &window_permission, .origins = &example_origins },
    .{ .name = "native-sdk.webview.create", .permissions = &window_permission, .origins = &example_origins },
    .{ .name = "native-sdk.webview.list", .permissions = &window_permission, .origins = &example_origins },
    .{ .name = "native-sdk.webview.setFrame", .permissions = &window_permission, .origins = &example_origins },
    .{ .name = "native-sdk.webview.navigate", .permissions = &window_permission, .origins = &example_origins },
    .{ .name = "native-sdk.webview.setZoom", .permissions = &window_permission, .origins = &example_origins },
    .{ .name = "native-sdk.webview.setLayer", .permissions = &window_permission, .origins = &example_origins },
    .{ .name = "native-sdk.webview.close", .permissions = &window_permission, .origins = &example_origins },
};

const WebViewApp = struct {
    ping_count: u32 = 0,
    bridge_handlers: [1]native_sdk.BridgeHandler = undefined,
    env_map: *std.process.Environ.Map,

    fn app(self: *@This()) native_sdk.App {
        return .{ .context = self, .name = "webview", .source = native_sdk.WebViewSource.html(html), .source_fn = source };
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.env_map.get("NATIVE_SDK_FRONTEND_URL") != null) {
            return native_sdk.frontend.sourceFromEnv(self.env_map, .{ .dist = "dist" });
        }
        if (self.env_map.get("NATIVE_SDK_FRONTEND_ASSETS") != null) {
            return native_sdk.frontend.productionSource(.{ .dist = "dist" });
        }
        return native_sdk.WebViewSource.html(html);
    }

    fn bridge(self: *@This()) native_sdk.BridgeDispatcher {
        self.bridge_handlers = .{.{ .name = "native.ping", .context = self, .invoke_fn = ping }};
        return .{
            .policy = .{ .enabled = true, .commands = &bridge_policies },
            .registry = .{ .handlers = &self.bridge_handlers },
        };
    }

    fn ping(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        const self: *@This() = @ptrCast(@alignCast(context));
        self.ping_count += 1;
        return std.fmt.bufPrint(output, "{{\"message\":\"pong from Zig\",\"count\":{d}}}", .{self.ping_count});
    }
};

pub fn main(init: std.process.Init) !void {
    var app = WebViewApp{ .env_map = init.environ_map };
    try runner.runWithOptions(app.app(), .{
        .app_name = "webview",
        .window_title = "Native SDK WebView",
        .bundle_id = "dev.native_sdk.webview",
        .bridge = app.bridge(),
        .builtin_bridge = .{ .enabled = true, .commands = &builtin_policies },
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app", "https://example.com" } },
        },
    }, init);
}

test "inline html stays within the runtime window source budget" {
    // An inline source past this budget fails window load at app_start and
    // the main window comes up blank; catch the overflow at test time.
    try std.testing.expect(html.len <= native_sdk.platform.max_window_source_bytes);
}

test "webview bridge returns native ping response" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var app = WebViewApp{ .env_map = &env };
    var dispatcher = app.bridge();
    var output: [512]u8 = undefined;
    const response = dispatcher.dispatch(
        \\{"id":"1","command":"native.ping","payload":{"source":"test"}}
    , .{ .origin = "zero://inline" }, &output);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "pong from Zig") != null);
}
