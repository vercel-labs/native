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
const automation = support.automation;
const platform = support.platform;
const App = support.App;
const Event = support.Event;
const Runtime = support.Runtime;
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

/// The scripted platform loop for the automation-driven session below:
/// startup, one frame, then two dropbox commands written from the loop's
/// own thread (like a driver writing while the app runs) and drained by
/// the following frames — deterministic, no watcher timing involved.
const NativeOnlyAutomationLoop = struct {
    null_platform: *platform.NullPlatform,
    automation_dir: []const u8,

    fn run(context: *anyopaque, handler: platform.EventHandler, handler_context: *anyopaque) anyerror!void {
        const self: *NativeOnlyAutomationLoop = @ptrCast(@alignCast(context));
        try handler(handler_context, .app_start);
        try handler(handler_context, .{ .surface_resized = self.null_platform.surface_value });
        try handler(handler_context, .frame_requested);

        var path_buffer: [160]u8 = undefined;
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/command-1.txt", .{self.automation_dir}),
            .data = "menu-command probe.normal\n",
        });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/command-2.txt", .{self.automation_dir}),
            .data = "menu-command probe.webview\n",
        });
        try handler(handler_context, .frame_requested);
        try handler(handler_context, .frame_requested);
        try handler(handler_context, .app_shutdown);
    }
};

/// A native-only canvas app driven entirely through automation: a
/// normal command mutates state, and a command that tries to create a
/// webview records the gate's answer.
const NativeOnlyAutomationApp = struct {
    normal_commands: usize = 0,
    webview_error: ?anyerror = null,

    fn scene(context: *anyopaque) anyerror!app_manifest.ShellConfig {
        _ = context;
        return .{ .windows = &canvas_scene_windows };
    }

    fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
        const self: *NativeOnlyAutomationApp = @ptrCast(@alignCast(context));
        if (event_value != .command) return;
        if (std.mem.eql(u8, event_value.command.name, "probe.normal")) {
            self.normal_commands += 1;
            return;
        }
        if (std.mem.eql(u8, event_value.command.name, "probe.webview")) {
            _ = runtime.createView(.{
                .window_id = 1,
                .label = "preview",
                .kind = .webview,
                .frame = geometry.RectF.init(0, 0, 320, 240),
                .url = "https://example.com",
            }) catch |err| {
                self.webview_error = err;
                return;
            };
            self.webview_error = null;
        }
    }

    fn app(self: *NativeOnlyAutomationApp) App {
        return .{
            .context = self,
            .name = "native-only-automation",
            .scene_fn = scene,
            .event_fn = event,
        };
    }
};

test "automation drives a native-only session: commands work, webview creation teaches" {
    // Pid-suffixed dropbox (this test compiles into more than one test
    // binary; parallel copies must not share a directory).
    var dir_buffer: [64]u8 = undefined;
    const automation_dir = try automation.watcher.testDirectory(&dir_buffer, ".zig-cache/test-automation-web-layer");
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(std.testing.io, automation_dir) catch {};
    try cwd.createDirPath(std.testing.io, automation_dir);
    defer cwd.deleteTree(std.testing.io, automation_dir) catch {};

    // Heap-hosted: NullPlatform and Runtime are both multi-megabyte.
    const null_platform = try std.heap.page_allocator.create(platform.NullPlatform);
    defer std.heap.page_allocator.destroy(null_platform);
    null_platform.* = platform.NullPlatform.init(.{});
    null_platform.gpu_surfaces = true;
    var loop: NativeOnlyAutomationLoop = .{ .null_platform = null_platform, .automation_dir = automation_dir };

    var platform_value = null_platform.platform();
    platform_value.run_fn = NativeOnlyAutomationLoop.run;
    platform_value.context = &loop;

    const runtime = try std.heap.page_allocator.create(Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    Runtime.initAt(runtime, .{
        .platform = platform_value,
        .automation = automation.Server.init(std.testing.io, automation_dir, "WebLayerGate"),
        .web_layer = false,
    });

    var app_state: NativeOnlyAutomationApp = .{};
    try runtime.run(app_state.app());

    // Normal operation: the automation-driven command reached the app.
    try std.testing.expectEqual(@as(usize, 1), app_state.normal_commands);
    // The automation-driven webview attempt got the teaching error, and
    // no webview ever reached the platform host.
    try std.testing.expectEqual(@as(?anyerror, error.WebViewLayerNotBuilt), app_state.webview_error);
    try std.testing.expectEqual(@as(usize, 0), null_platform.webview_count);
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
