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

test "runtime next canvas frame applies render override dirty regions" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-next-frame-overrides", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 40, 20),
    });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 10, 10),
        .fill = .{ .color = canvas.Color.rgb8(255, 0, 0) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var render_commands: [1]canvas.RenderCommand = undefined;
    var render_batches: [1]canvas.RenderBatch = undefined;
    var resources: [1]canvas.RenderResource = undefined;
    var resource_cache_entries: [1]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [1]canvas.GlyphAtlasEntry = undefined;
    var changes: [1]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    };

    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 1 }, frame_storage);
    try std.testing.expect(first_frame.full_repaint);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 40, 20), first_frame.dirty_bounds.?);

    const overrides = [_]canvas.CanvasRenderOverride{.{
        .id = 1,
        .opacity = 0.5,
        .transform = canvas.Affine.translate(10, 0),
    }};
    const moved_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 2,
        .render_overrides = &overrides,
    }, frame_storage);
    try std.testing.expect(!moved_frame.full_repaint);
    try std.testing.expect(moved_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), moved_frame.changes.len);
    try std.testing.expectEqual(@as(f32, 0.5), moved_frame.render_plan.commands[0].opacity);
    try std.testing.expectEqualDeep(canvas.Affine.translate(10, 0), moved_frame.render_plan.commands[0].transform);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 20, 10), moved_frame.dirty_bounds.?);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 20, 10), harness.runtime.views[0].canvas_frame_dirty_bounds.?);

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 3,
        .previous_render_overrides = &overrides,
        .render_overrides = &overrides,
    }, frame_storage);
    try std.testing.expect(!clean_frame.requiresRender());
    try std.testing.expect(clean_frame.dirty_bounds == null);
    try std.testing.expect(harness.runtime.views[0].canvas_frame_dirty_bounds == null);
}

test "runtime schedules canvas render animations without display list rebuild" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-runtime-animation", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 40, 20),
    });
    try std.testing.expectEqual(@as(u64, 0), try harness.runtime.canvasRenderAnimationStartNs(1, "canvas"));

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 10, 10),
        .fill = .{ .color = canvas.Color.rgb8(255, 0, 0) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var render_commands: [1]canvas.RenderCommand = undefined;
    var render_batches: [1]canvas.RenderBatch = undefined;
    var resources: [1]canvas.RenderResource = undefined;
    var resource_cache_entries: [1]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [1]canvas.GlyphAtlasEntry = undefined;
    var changes: [1]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    };

    const start_ns: u64 = 1_000_000_000;
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(40, 20),
        .timestamp_ns = start_ns,
        .nonblank = true,
    } });
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 1, .timestamp_ns = start_ns }, frame_storage);
    try std.testing.expectEqual(start_ns, try harness.runtime.canvasRenderAnimationStartNs(1, "canvas"));
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_move,
        .timestamp_ns = start_ns + 60_000_000,
        .x = 12,
        .y = 8,
    } });
    try std.testing.expectEqual(start_ns + 60_000_000, try harness.runtime.canvasRenderAnimationStartNs(1, "canvas"));
    const initial_revision = harness.runtime.views[0].canvas_revision;

    const animations = [_]canvas.CanvasRenderAnimation{.{
        .id = 1,
        .start_ns = start_ns,
        .duration_ms = 1_000,
        .easing = .linear,
        .from_opacity = 0,
        .to_opacity = 1,
        .from_transform = canvas.Affine.translate(10, 0),
        .to_transform = canvas.Affine.identity(),
    }};
    _ = try harness.runtime.setCanvasRenderAnimations(1, "canvas", &animations);
    try std.testing.expectEqual(@as(usize, 1), (try harness.runtime.canvasRenderAnimations(1, "canvas")).len);
    try std.testing.expect(harness.runtime.invalidated);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const mid_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 2,
        .timestamp_ns = start_ns + 500_000_000,
    }, frame_storage);
    try std.testing.expectEqual(initial_revision, harness.runtime.views[0].canvas_revision);
    try std.testing.expect(!mid_frame.full_repaint);
    try std.testing.expect(mid_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), mid_frame.changes.len);
    try std.testing.expectEqual(@as(f32, 0.5), mid_frame.render_plan.commands[0].opacity);
    try std.testing.expectEqualDeep(canvas.Affine.translate(5, 0), mid_frame.render_plan.commands[0].transform);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 15, 10), mid_frame.dirty_bounds.?);
    try std.testing.expect(harness.runtime.invalidated);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const final_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 3,
        .timestamp_ns = start_ns + 1_000_000_000,
    }, frame_storage);
    try std.testing.expect(final_frame.requiresRender());
    try std.testing.expectEqual(@as(f32, 1), final_frame.render_plan.commands[0].opacity);
    try std.testing.expectEqualDeep(canvas.Affine.identity(), final_frame.render_plan.commands[0].transform);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 15, 10), final_frame.dirty_bounds.?);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), (try harness.runtime.canvasRenderAnimations(1, "canvas")).len);
    try std.testing.expectEqual(@as(usize, 0), runtimeViewCanvasFrameRenderOverrides(&harness.runtime.views[0]).len);

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 4,
        .timestamp_ns = start_ns + 1_016_000_000,
    }, frame_storage);
    try std.testing.expect(!clean_frame.requiresRender());
    try std.testing.expect(clean_frame.dirty_bounds == null);
}

test "runtime classifies render animation final overrides for cleanup" {
    try std.testing.expect(canvasRenderAnimationFinalOverrideNoop(.{
        .id = 1,
        .to_opacity = 1,
        .to_transform = canvas.Affine.identity(),
    }));
    try std.testing.expect(!canvasRenderAnimationFinalOverrideNoop(.{
        .id = 2,
        .to_opacity = 0,
    }));
    try std.testing.expect(!canvasRenderAnimationFinalOverrideNoop(.{
        .id = 3,
        .to_transform = canvas.Affine.translate(8, 0),
    }));
}
