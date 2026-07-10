const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const trace = support.trace;
const json = support.json;
const canvas = support.canvas;
const automation = support.automation;
const bridge = support.bridge;
const app_manifest = support.app_manifest;
const platform = support.platform;
const security = support.security;
const extensions = support.extensions;
const window_state = support.window_state;
const runtime_module = support.runtime_module;
const bridge_payload = support.bridge_payload;
const canvas_frame = support.canvas_frame;
const App = support.App;
const Runtime = support.Runtime;
const Options = support.Options;
const Event = support.Event;
const LifecycleEvent = support.LifecycleEvent;
const CommandEvent = support.CommandEvent;
const Command = support.Command;
const CommandSource = support.CommandSource;
const FrameDiagnostics = support.FrameDiagnostics;
const ShortcutEvent = support.ShortcutEvent;
const Appearance = support.Appearance;
const GpuFrame = support.GpuFrame;
const GpuSurfaceFrameEvent = support.GpuSurfaceFrameEvent;
const GpuSurfaceResizeEvent = support.GpuSurfaceResizeEvent;
const GpuSurfaceInputEvent = support.GpuSurfaceInputEvent;
const CanvasWidgetPointerEvent = support.CanvasWidgetPointerEvent;
const CanvasWidgetKeyboardEvent = support.CanvasWidgetKeyboardEvent;
const CanvasWidgetDisplayListChrome = support.CanvasWidgetDisplayListChrome;
const CanvasPresentationMode = support.CanvasPresentationMode;
const CanvasPresentationResult = support.CanvasPresentationResult;
const CanvasWidgetAccessibilityActionKind = support.CanvasWidgetAccessibilityActionKind;
const CanvasWidgetAccessibilityAction = support.CanvasWidgetAccessibilityAction;
const CanvasWidgetFileDropEvent = support.CanvasWidgetFileDropEvent;
const CanvasWidgetDragEvent = support.CanvasWidgetDragEvent;
const InvalidationReason = support.InvalidationReason;
const TestHarness = support.TestHarness;
const max_canvas_commands_per_view = support.max_canvas_commands_per_view;
const max_canvas_widget_nodes_per_view = support.max_canvas_widget_nodes_per_view;
const jsonStringField = support.jsonStringField;
const jsonNumberField = support.jsonNumberField;
const jsonBoolField = support.jsonBoolField;
const canvasRenderAnimationFinalOverrideNoop = support.canvasRenderAnimationFinalOverrideNoop;
const copyInto = support.copyInto;
const writeViewJson = support.writeViewJson;
const canvasFrameScratchStorage = support.canvasFrameScratchStorage;
const runtimeViewInfo = support.runtimeViewInfo;
const runtimeViewCanvasFrameRenderOverrides = support.runtimeViewCanvasFrameRenderOverrides;
const runtimeViewCanvasRenderAnimationDirtyBoundsForOverrides = support.runtimeViewCanvasRenderAnimationDirtyBoundsForOverrides;
const runtimeViewWidgetSemantics = support.runtimeViewWidgetSemantics;
const runtimeViewSetCanvasWidgetSelected = support.runtimeViewSetCanvasWidgetSelected;
const runtimeViewCanvasWidgetDirtyBounds = support.runtimeViewCanvasWidgetDirtyBounds;
const dispatchAutomationWidgetAction = support.dispatchAutomationWidgetAction;
const shellBoundsForWindow = support.shellBoundsForWindow;
const reloadWindows = support.reloadWindows;
const canvasWidgetSemanticsById = support.canvasWidgetSemanticsById;
const platformWidgetAccessibilityNodeById = support.platformWidgetAccessibilityNodeById;
const builtinBridgeErrorCode = support.builtinBridgeErrorCode;
const builtinBridgeErrorMessage = support.builtinBridgeErrorMessage;
const testViewByLabel = support.testViewByLabel;
const testCanvasWidgetPartId = support.testCanvasWidgetPartId;

test "native-only null runtime completes startup without a browser security hook" {
    const TestApp = struct {
        const views = [_]app_manifest.ShellView{.{
            .label = "main-canvas",
            .kind = .gpu_surface,
            .fill = true,
        }};
        const windows = [_]app_manifest.ShellWindow{.{
            .label = "main",
            .views = &views,
        }};

        fn scene(context: *anyopaque) anyerror!app_manifest.ShellConfig {
            _ = context;
            return .{ .windows = &windows };
        }
    };

    var app_context: u8 = 0;
    var null_platform = platform.NullPlatform.init(.{});
    null_platform.gpu_surfaces = true;
    const runtime = try std.testing.allocator.create(Runtime);
    defer std.testing.allocator.destroy(runtime);
    Runtime.initAt(runtime, .{
        .platform = null_platform.nativePlatform(),
        .security = .{ .permissions = &.{security.permission_view} },
    });

    try runtime.run(.{
        .context = &app_context,
        .name = "native-runtime-smoke",
        .scene_fn = TestApp.scene,
    });

    try std.testing.expectEqual(@as(usize, 1), runtime.view_count);
    try std.testing.expectEqual(@as(u64, 1), runtime.frame_index);
}

test "runtime dispatches shortcut command events" {
    const TestApp = struct {
        command_count: u32 = 0,
        shortcut_count: u32 = 0,
        last_name: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_window_id: platform.WindowId = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shortcut-command", .source = platform.WebViewSource.html("<h1>Shortcuts</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    self.command_count += 1;
                    self.last_name = command.name;
                    self.last_source = command.source;
                    self.last_window_id = command.window_id;
                },
                .shortcut => {
                    self.shortcut_count += 1;
                },
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .shortcut = .{
        .id = "app.refresh",
        .key = "r",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.shortcut_count);
    try std.testing.expectEqualStrings("app.refresh", app_state.last_name);
    try std.testing.expectEqual(CommandSource.shortcut, app_state.last_source);
    try std.testing.expectEqual(@as(platform.WindowId, 1), app_state.last_window_id);
}

test "runtime configures platform menus" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "menus", .source = platform.WebViewSource.html("<h1>Menus</h1>") };
        }
    };

    const items = [_]platform.MenuItem{
        .{ .label = "Refresh", .command = "app.refresh", .key = "r", .modifiers = .{ .primary = true } },
    };
    const menus = [_]platform.Menu{.{ .title = "View", .items = &items }};
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.menus = &menus;
    var app_state: TestApp = .{};
    try harness.runtime.run(app_state.app());

    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.configuredMenus().len);
    try std.testing.expectEqualStrings("View", harness.null_platform.configuredMenus()[0].title);
    try std.testing.expectEqualStrings("app.refresh", harness.null_platform.configuredMenus()[0].items[0].command);
}

test "runtime rejects invalid platform menu shortcuts" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "invalid-menus", .source = platform.WebViewSource.html("<h1>Menus</h1>") };
        }
    };

    const items = [_]platform.MenuItem{
        .{ .label = "Refresh", .command = "app.refresh", .key = "r" },
    };
    const menus = [_]platform.Menu{.{ .title = "View", .items = &items }};
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.menus = &menus;
    var app_state: TestApp = .{};

    try std.testing.expectError(error.InvalidShortcut, harness.runtime.run(app_state.app()));
}

test "runtime rejects invalid keyboard shortcuts" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "invalid-shortcuts", .source = platform.WebViewSource.html("<h1>Shortcuts</h1>") };
        }
    };

    const long_id = [_]u8{'x'} ** (platform.max_shortcut_id_bytes + 1);
    const shortcuts = [_]platform.Shortcut{.{ .id = long_id[0..], .key = "p" }};
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.shortcuts = &shortcuts;
    var app_state: TestApp = .{};

    try std.testing.expectError(error.InvalidShortcut, harness.runtime.run(app_state.app()));
}

test "runtime rejects invalid command catalog" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "invalid-commands", .source = platform.WebViewSource.html("<h1>Commands</h1>") };
        }
    };

    const commands = [_]Command{
        .{ .id = "app.refresh", .title = "Refresh" },
        .{ .id = "app.refresh", .title = "Duplicate Refresh" },
    };
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.commands = &commands;
    var app_state: TestApp = .{};

    try std.testing.expectError(error.DuplicateCommand, harness.runtime.run(app_state.app()));
}

test "runtime rejects oversized webview source" {
    const TestApp = struct {
        bytes: [platform.max_window_source_bytes + 1]u8 = [_]u8{'x'} ** (platform.max_window_source_bytes + 1),

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "oversized-source", .source = platform.WebViewSource.html(&self.bytes) };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: TestApp = .{};

    try std.testing.expectError(error.WindowSourceTooLarge, harness.start(app_state.app()));
}

test "runtime refreshes app source and keeps reload fields owned" {
    const TestApp = struct {
        root_path: [8]u8 = "dist-one".*,
        entry: [10]u8 = "index.html".*,
        origin: [13]u8 = "zero://assets".*,

        fn source(context: *anyopaque) anyerror!platform.WebViewSource {
            const self: *@This() = @ptrCast(@alignCast(context));
            return platform.WebViewSource.assets(.{
                .root_path = self.root_path[0..],
                .entry = self.entry[0..],
                .origin = self.origin[0..],
                .spa_fallback = false,
            });
        }

        fn app(self: *@This()) App {
            return .{
                .context = self,
                .name = "asset-source",
                .source_fn = source,
            };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    const secondary = try harness.runtime.createWindow(.{
        .label = "external",
        .title = "External",
        .source = platform.WebViewSource.url("https://example.test"),
    });

    @memcpy(app_state.root_path[0..], "dist-two");
    @memcpy(app_state.entry[0..], "other.html");
    @memcpy(app_state.origin[0..], "zero://mutant");
    try reloadWindows(&harness.runtime, app_state.app());

    @memcpy(app_state.root_path[0..], "dist-bad");
    @memcpy(app_state.entry[0..], "mutant.htm");
    @memcpy(app_state.origin[0..], "zero://future");

    const loaded = harness.null_platform.window_sources[0].?;
    try std.testing.expectEqual(platform.WebViewSourceKind.assets, loaded.kind);
    try std.testing.expectEqualStrings("zero://mutant", loaded.bytes);
    const assets = loaded.asset_options.?;
    try std.testing.expectEqualStrings("dist-two", assets.root_path);
    try std.testing.expectEqualStrings("other.html", assets.entry);
    try std.testing.expectEqualStrings("zero://mutant", assets.origin);
    try std.testing.expect(!assets.spa_fallback);

    const secondary_source = harness.null_platform.window_sources[@intCast(secondary.id - 1)].?;
    try std.testing.expectEqual(platform.WebViewSourceKind.url, secondary_source.kind);
    try std.testing.expectEqualStrings("https://example.test", secondary_source.bytes);
}

test "extension registry receives runtime lifecycle and command hooks" {
    const ModuleState = struct {
        started: bool = false,
        stopped: bool = false,
        commands: u32 = 0,

        fn start(context: *anyopaque, runtime_context: extensions.RuntimeContext) anyerror!void {
            try std.testing.expectEqualStrings("null", runtime_context.platform_name);
            const self: *@This() = @ptrCast(@alignCast(context));
            self.started = true;
        }

        fn stop(context: *anyopaque, runtime_context: extensions.RuntimeContext) anyerror!void {
            _ = runtime_context;
            const self: *@This() = @ptrCast(@alignCast(context));
            self.stopped = true;
        }

        fn command(context: *anyopaque, runtime_context: extensions.RuntimeContext, command_value: extensions.Command) anyerror!void {
            _ = runtime_context;
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, command_value.name, "native.ping")) self.commands += 1;
        }
    };

    var module_state: ModuleState = .{};
    const modules = [_]extensions.Module{.{
        .info = .{ .id = 1, .name = "native-test", .capabilities = &.{.{ .kind = .native_module }} },
        .context = &module_state,
        .hooks = .{ .start_fn = ModuleState.start, .stop_fn = ModuleState.stop, .command_fn = ModuleState.command },
    }};

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.extensions = .{ .modules = &modules };

    const app = App{ .context = &module_state, .name = "extensions", .source = platform.WebViewSource.html("<p>Extensions</p>") };
    try harness.start(app);
    try harness.runtime.dispatchEvent(app, .{ .command = .{ .name = "native.ping" } });
    try harness.stop(app);

    try std.testing.expect(module_state.started);
    try std.testing.expect(module_state.stopped);
    try std.testing.expectEqual(@as(u32, 1), module_state.commands);
}

fn fixedTextMeasureForTests(context: ?*anyopaque, font_id: u64, size: f32, text: []const u8) f32 {
    _ = context;
    _ = font_id;
    _ = size;
    return @floatFromInt(text.len * 7);
}

test "runtime exposes no text measure provider on the null platform" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);

    try std.testing.expect(harness.runtime.textMeasureProvider() == null);
    const tokens = harness.runtime.tokensWithTextMeasure(.{});
    try std.testing.expect(tokens.text_measure == null);
    try std.testing.expect(std.meta.eql(canvas.DesignTokens{}, tokens));
}

test "runtime wraps a platform text measure service into a canvas provider" {
    var null_platform = platform.NullPlatform.init(.{});
    var measured_platform = null_platform.platform();
    measured_platform.services.measure_text_fn = fixedTextMeasureForTests;

    const runtime = try std.testing.allocator.create(Runtime);
    defer std.testing.allocator.destroy(runtime);
    Runtime.initAt(runtime, .{ .platform = measured_platform });

    const provider = runtime.textMeasureProvider() orelse return error.MissingProvider;
    try std.testing.expectEqual(@as(f32, 35), provider.measureWidth(1, 12, "hello"));

    const tokens = runtime.tokensWithTextMeasure(.{});
    try std.testing.expect(tokens.text_measure != null);
    try std.testing.expectEqual(
        @as(f32, 21),
        canvas.measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, "abc", 12),
    );
    // Stable identity: stamping twice compares equal so token equality
    // checks in the reconcile path stay quiescent frame to frame.
    try std.testing.expect(std.meta.eql(tokens, runtime.tokensWithTextMeasure(.{})));
}

fn countedBatchedMeasureForTests(context: ?*anyopaque, font_id: u64, size: f32, text: []const u8, advances: []f32) bool {
    _ = context;
    _ = font_id;
    _ = size;
    // Flat 7px per byte, matching fixedTextMeasureForTests so batched
    // sums and per-prefix widths agree exactly.
    for (advances[0..text.len]) |*advance| advance.* = 7;
    return true;
}

test "runtime threads the batched measure service into the canvas provider" {
    var null_platform = platform.NullPlatform.init(.{});
    var measured_platform = null_platform.platform();
    measured_platform.services.measure_text_fn = fixedTextMeasureForTests;
    measured_platform.services.measure_text_advances_fn = countedBatchedMeasureForTests;

    const runtime = try std.testing.allocator.create(Runtime);
    defer std.testing.allocator.destroy(runtime);
    Runtime.initAt(runtime, .{ .platform = measured_platform });

    const provider = runtime.textMeasureProvider() orelse return error.MissingProvider;
    try std.testing.expect(provider.measure_advances_fn != null);
    var advances: [5]f32 = undefined;
    try std.testing.expect(provider.measureAdvances(1, 12, "hello", &advances));
    for (advances) |advance| try std.testing.expectEqual(@as(f32, 7), advance);
    // The batched sum agrees with the unbatched width for this provider.
    try std.testing.expectEqual(@as(f32, 35), provider.measureWidth(1, 12, "hello"));
}

test "runtime construction bumps the text measure generation" {
    var null_platform = platform.NullPlatform.init(.{});
    const before = canvas.textMeasureGeneration();
    const runtime = try std.testing.allocator.create(Runtime);
    defer std.testing.allocator.destroy(runtime);
    Runtime.initAt(runtime, .{ .platform = null_platform.platform() });
    // A recycled provider context address from a destroyed runtime must
    // never serve a fresh runtime stale advances or wrap results.
    try std.testing.expect(canvas.textMeasureGeneration() > before);
}
