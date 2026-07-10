//! The runtime half of the native-only-host contract: a build whose
//! app.zon declared no web use ships without the embedded web layer
//! (`Options.web_layer = false`), and every path that would create a
//! webview fails fast with `error.WebViewLayerNotBuilt` and its teaching
//! message — never a platform call into a host whose web layer was
//! compiled out, and never a misleading not-found.

const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const app_manifest = support.app_manifest;
const platform = support.platform;
const App = support.App;
const TestHarness = support.TestHarness;

const teaching_needle = "built without the web layer";

/// A native-only app shape: default empty source, one canvas scene.
const canvas_scene_views = [_]app_manifest.ShellView{
    .{ .label = "canvas", .kind = .gpu_surface, .fill = true },
};
const canvas_scene_windows = [_]app_manifest.ShellWindow{
    .{ .label = "main", .views = &canvas_scene_views },
};

const CanvasApp = struct {
    fn app(self: *@This()) App {
        return .{ .context = self, .name = "native-only", .scene_fn = scene };
    }

    fn scene(context: *anyopaque) anyerror!app_manifest.ShellConfig {
        _ = context;
        return .{ .windows = &canvas_scene_windows };
    }
};

test "native-only runtime starts a canvas scene and refuses webview creation with the teaching error" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    // The null platform's gpu_surface support is opt-in; the fixture
    // scene is a canvas window, so switch it on like a real host.
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.web_layer = false;
    var app_state: CanvasApp = .{};
    try harness.start(app_state.app());

    // The canvas scene booted without touching the web layer.
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.webview_count);

    // Direct webview view creation (the shell/bridge choke point).
    try std.testing.expectError(error.WebViewLayerNotBuilt, harness.runtime.createView(.{
        .window_id = 1,
        .label = "preview",
        .kind = .webview,
        .frame = geometry.RectF.init(0, 0, 320, 240),
        .url = "https://example.com",
    }));

    // A window whose source would materialize a main webview.
    try std.testing.expectError(error.WebViewLayerNotBuilt, harness.runtime.createWindow(.{
        .label = "second",
        .title = "Second",
        .default_frame = geometry.RectF.init(0, 0, 400, 300),
        .source = platform.WebViewSource.url("https://example.com"),
    }));
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.webview_count);
}

test "native-only runtime answers webview bridge verbs with the teaching error" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.web_layer = false;
    harness.runtime.options.js_window_api = true;
    const origins = [_][]const u8{"zero://inline"};
    harness.runtime.options.security.navigation.allowed_origins = &origins;
    var app_state: CanvasApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"native-sdk.webview.create\",\"payload\":{\"label\":\"preview\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    const response = harness.null_platform.lastBridgeResponse();
    try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, teaching_needle) != null);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.webview_count);
}

test "native-only runtime fails fast when a source app reaches webview startup" {
    const SourceApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "source-app", .source = platform.WebViewSource.html("<p>web</p>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.web_layer = false;
    var app_state: SourceApp = .{};
    try std.testing.expectError(error.WebViewLayerNotBuilt, harness.start(app_state.app()));
}

test "web-layer builds keep every webview path working (control)" {
    const SourceApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "source-app", .source = platform.WebViewSource.html("<p>web</p>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: SourceApp = .{};
    try harness.start(app_state.app());
    const webview_origins = [_][]const u8{"https://example.com"};
    harness.runtime.options.security.navigation.allowed_origins = &webview_origins;
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "preview",
        .kind = .webview,
        .frame = geometry.RectF.init(0, 0, 320, 240),
        .url = "https://example.com",
    });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.webview_count);
}
