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

test "runtime next canvas frame retains and evicts glyph atlas cache" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-glyph-cache", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 160, 80),
    });

    const first_commands = [_]canvas.CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 5,
        .size = 14,
        .origin = geometry.PointF.init(12, 32),
        .color = canvas.Color.rgb8(15, 23, 42),
        .text = "A",
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &first_commands });

    var render_commands: [1]canvas.RenderCommand = undefined;
    var render_batches: [1]canvas.RenderBatch = undefined;
    var resources: [1]canvas.RenderResource = undefined;
    var resource_cache_entries: [1]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [1]canvas.GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [1]canvas.GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [2]canvas.GlyphAtlasCacheAction = undefined;
    var text_layout_plans: [1]canvas.TextLayoutPlan = undefined;
    var text_layout_lines: [1]canvas.TextLine = undefined;
    var text_layout_cache_entries: [1]canvas.TextLayoutCacheEntry = undefined;
    var text_layout_cache_actions: [2]canvas.TextLayoutCacheAction = undefined;
    var changes: [1]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .text_layout_plans = &text_layout_plans,
        .text_layout_lines = &text_layout_lines,
        .text_layout_cache_entries = &text_layout_cache_entries,
        .text_layout_cache_actions = &text_layout_cache_actions,
        .changes = &changes,
    };

    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 1 }, frame_storage);
    try std.testing.expectEqual(@as(usize, 1), first_frame.glyph_atlas_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), first_frame.glyph_atlas_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), first_frame.glyph_atlas_cache_plan.evictCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_glyph_atlas_cache_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_glyph_atlas_upload_count);
    try std.testing.expectEqual(@as(usize, 1), first_frame.text_layout_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_cache_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_upload_count);

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 2 }, frame_storage);
    try std.testing.expectEqual(@as(usize, 0), clean_frame.glyph_atlas_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), clean_frame.glyph_atlas_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), clean_frame.glyph_atlas_cache_plan.evictCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_glyph_atlas_cache_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.views[0].canvas_frame_glyph_atlas_retain_count);
    try std.testing.expectEqual(@as(usize, 0), clean_frame.text_layout_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), clean_frame.text_layout_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), clean_frame.text_layout_cache_plan.evictCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_cache_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.views[0].canvas_frame_text_layout_retain_count);

    const next_commands = [_]canvas.CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 5,
        .size = 14,
        .origin = geometry.PointF.init(12, 32),
        .color = canvas.Color.rgb8(15, 23, 42),
        .text = "B",
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &next_commands });

    const changed_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 3 }, frame_storage);
    try std.testing.expectEqual(@as(usize, 1), changed_frame.glyph_atlas_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), changed_frame.glyph_atlas_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 1), changed_frame.glyph_atlas_cache_plan.evictCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_glyph_atlas_cache_count);
    try std.testing.expectEqual(@as(u32, 'B'), harness.runtime.views[0].canvas_frame_glyph_atlas_cache[0].key.glyph_id);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_glyph_atlas_upload_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_glyph_atlas_evict_count);
    try std.testing.expectEqual(@as(usize, 1), changed_frame.text_layout_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), changed_frame.text_layout_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 1), changed_frame.text_layout_cache_plan.evictCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_cache_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_upload_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_evict_count);
}

test "runtime next canvas frame keeps recent unused text caches warm" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-text-cache-retention", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 160, 80),
    });

    const first_commands = [_]canvas.CanvasCommand{
        .{ .draw_text = .{
            .id = 1,
            .font_id = 5,
            .size = 14,
            .origin = geometry.PointF.init(12, 32),
            .color = canvas.Color.rgb8(15, 23, 42),
            .text = "A",
        } },
        .{ .draw_text = .{
            .id = 2,
            .font_id = 5,
            .size = 14,
            .origin = geometry.PointF.init(32, 32),
            .color = canvas.Color.rgb8(15, 23, 42),
            .text = "B",
        } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &first_commands });

    var render_commands: [2]canvas.RenderCommand = undefined;
    var render_batches: [2]canvas.RenderBatch = undefined;
    var resources: [2]canvas.RenderResource = undefined;
    var resource_cache_entries: [2]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [4]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [2]canvas.GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [2]canvas.GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [4]canvas.GlyphAtlasCacheAction = undefined;
    var text_layout_plans: [2]canvas.TextLayoutPlan = undefined;
    var text_layout_lines: [2]canvas.TextLine = undefined;
    var text_layout_cache_entries: [2]canvas.TextLayoutCacheEntry = undefined;
    var text_layout_cache_actions: [4]canvas.TextLayoutCacheAction = undefined;
    var changes: [2]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .text_layout_plans = &text_layout_plans,
        .text_layout_lines = &text_layout_lines,
        .text_layout_cache_entries = &text_layout_cache_entries,
        .text_layout_cache_actions = &text_layout_cache_actions,
        .changes = &changes,
    };

    _ = try harness.runtime.setCanvasFrameBudget(1, "canvas", .{
        .max_glyph_atlas_uploads = 1,
        .max_text_layout_uploads = 1,
    });
    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 1 }, frame_storage);
    try std.testing.expectEqual(@as(usize, 2), first_frame.glyph_atlas_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), first_frame.text_layout_cache_plan.uploadCount());
    const first_budget_status = first_frame.budgetStatus();
    try std.testing.expect(first_budget_status.glyph_atlas_uploads_over);
    try std.testing.expect(first_budget_status.text_layout_uploads_over);
    try std.testing.expectEqual(@as(usize, 2), first_budget_status.exceededCount());
    try std.testing.expectEqual(@as(usize, 2), harness.runtime.views[0].canvas_frame_budget_status.exceededCount());

    const second_commands = [_]canvas.CanvasCommand{first_commands[0]};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &second_commands });
    const second_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 2 }, frame_storage);
    try std.testing.expect(second_frame.requiresRender());
    try std.testing.expect(second_frame.budgetStatus().ok());
    try std.testing.expectEqual(@as(usize, 2), second_frame.glyph_atlas_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 0), second_frame.glyph_atlas_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), second_frame.glyph_atlas_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), second_frame.glyph_atlas_cache_plan.evictCount());
    try std.testing.expectEqual(@as(u64, 2), second_frame.glyph_atlas_cache_plan.entries[0].last_used_frame);
    try std.testing.expectEqual(@as(u64, 1), second_frame.glyph_atlas_cache_plan.entries[1].last_used_frame);
    try std.testing.expectEqual(@as(usize, 2), second_frame.text_layout_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 0), second_frame.text_layout_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), second_frame.text_layout_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), second_frame.text_layout_cache_plan.evictCount());
    try std.testing.expectEqual(@as(u64, 2), second_frame.text_layout_cache_plan.entries[0].last_used_frame);
    try std.testing.expectEqual(@as(u64, 1), second_frame.text_layout_cache_plan.entries[1].last_used_frame);
}

test "runtime canvas frame scratch storage includes text layout caches" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-scratch-text-cache", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 160, 80),
    });

    const first_commands = [_]canvas.CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 5,
        .size = 14,
        .origin = geometry.PointF.init(12, 32),
        .color = canvas.Color.rgb8(15, 23, 42),
        .text = "First",
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &first_commands });

    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 1 }, canvasFrameScratchStorage(&harness.runtime));
    try std.testing.expectEqual(@as(usize, 1), first_frame.text_layout_plan.planCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.text_layout_plan.lineCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.text_layout_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_cache_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_upload_count);

    const next_commands = [_]canvas.CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 5,
        .size = 14,
        .origin = geometry.PointF.init(12, 32),
        .color = canvas.Color.rgb8(15, 23, 42),
        .text = "Second",
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &next_commands });

    const changed_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 2 }, canvasFrameScratchStorage(&harness.runtime));
    try std.testing.expect(changed_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), changed_frame.text_layout_plan.planCount());
    try std.testing.expectEqual(@as(usize, 1), changed_frame.text_layout_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), changed_frame.text_layout_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), changed_frame.text_layout_cache_plan.evictCount());
    try std.testing.expectEqual(@as(usize, 2), harness.runtime.views[0].canvas_frame_text_layout_cache_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_upload_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_retain_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.views[0].canvas_frame_text_layout_evict_count);
}
