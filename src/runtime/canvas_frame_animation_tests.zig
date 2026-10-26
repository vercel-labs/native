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

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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
    // Override extent union, inflated by the AA bleed and clipped.
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 21, 11), moved_frame.dirty_bounds.?);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 21, 11), harness.runtime.views[0].canvas_frame_dirty_bounds.?);

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

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasRenderAnimations(1, "canvas", &animations);
    try std.testing.expectEqual(@as(usize, 1), (try harness.runtime.canvasRenderAnimations(1, "canvas")).len);
    try std.testing.expect(harness.runtime.invalidated);
    // Scheduling invalidates the ANIMATED command's extent (its bounds
    // widened by the from/to transforms), never the whole 40x20 view —
    // a UiApp rebuild re-bases its animations on every update, and a
    // full-frame region here silently defeated incremental presentation.
    const schedule_regions = harness.runtime.pendingDirtyRegions();
    try std.testing.expect(schedule_regions.len > 0);
    for (schedule_regions) |region| {
        try std.testing.expect(region.width <= 20);
        try std.testing.expect(region.height <= 10);
    }

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const frame_requests_before_mid = harness.null_platform.gpu_surface_frame_request_count;
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
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 16, 11), mid_frame.dirty_bounds.?);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(frame_requests_before_mid + 1, harness.null_platform.gpu_surface_frame_request_count);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const frame_requests_before_final = harness.null_platform.gpu_surface_frame_request_count;
    const final_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 3,
        .timestamp_ns = start_ns + 1_000_000_000,
    }, frame_storage);
    try std.testing.expect(final_frame.requiresRender());
    try std.testing.expectEqual(@as(f32, 1), final_frame.render_plan.commands[0].opacity);
    try std.testing.expectEqualDeep(canvas.Affine.identity(), final_frame.render_plan.commands[0].transform);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 16, 11), final_frame.dirty_bounds.?);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(frame_requests_before_final, harness.null_platform.gpu_surface_frame_request_count);
    try std.testing.expectEqual(@as(usize, 0), (try harness.runtime.canvasRenderAnimations(1, "canvas")).len);
    try std.testing.expectEqual(@as(usize, 0), runtimeViewCanvasFrameRenderOverrides(&harness.runtime.views[0]).len);

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 4,
        .timestamp_ns = start_ns + 1_016_000_000,
    }, frame_storage);
    try std.testing.expect(!clean_frame.requiresRender());
    try std.testing.expect(clean_frame.dirty_bounds == null);
}

test "runtime spins visible spinners and parks the view on unmount" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-spinner-rotation", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 120),
    });

    const spinner = canvas.Widget{
        .id = 5,
        .kind = .spinner,
        .frame = geometry.RectF.init(20, 20, 20, 20),
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{spinner} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    // The visible spinner arms ONE looping rotation animation on its arc
    // command — never completing, so frame scheduling keeps sampling it.
    const view = &harness.runtime.views[0];
    const arc_id = canvas.spinnerWidgetArcCommandId(5);
    try std.testing.expectEqual(@as(usize, 1), view.canvas_widget_loop_animation_count);
    try std.testing.expectEqual(arc_id, view.canvas_widget_loop_animation_ids[0]);
    try std.testing.expectEqual(@as(usize, 1), view.canvas_render_animation_count);
    try std.testing.expect(view.canvasRenderAnimationsActive(60 * std.time.ns_per_s));

    // The rotation PUMPS: successive frame timestamps sample different
    // transforms (a quarter turn apart here), spinning about the arc's
    // own center so the sampled override moves real geometry.
    const start_ns = view.canvasRenderAnimations()[0].start_ns;
    var overrides: [4]canvas.CanvasRenderOverride = undefined;
    const probe = geometry.PointF.init(39, 30); // right edge of the spinner circle
    const first = try view.sampleCanvasRenderAnimations(start_ns + 100 * std.time.ns_per_ms, &overrides);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqual(arc_id, first[0].id);
    const first_point = first[0].transform.?.transformPoint(probe);
    var later_overrides: [4]canvas.CanvasRenderOverride = undefined;
    const later = try view.sampleCanvasRenderAnimations(start_ns + 350 * std.time.ns_per_ms, &later_overrides);
    const later_point = later[0].transform.?.transformPoint(probe);
    try std.testing.expect(@abs(first_point.x - later_point.x) > 1 or @abs(first_point.y - later_point.y) > 1);
    // The spinner center is the rotation's fixed point.
    const center = first[0].transform.?.transformPoint(geometry.PointF.init(30, 30));
    try std.testing.expectApproxEqAbs(@as(f32, 30), center.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 30), center.y, 0.01);

    // An unrelated display refresh must NOT reset the rotation phase.
    _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
    try std.testing.expectEqual(@as(usize, 1), view.canvas_render_animation_count);
    try std.testing.expectEqual(start_ns, view.canvasRenderAnimations()[0].start_ns);

    // Unmount: a rebuild without the spinner removes the animation so
    // the view goes idle (the frame pump's park condition).
    const empty = [_]canvas.Widget{.{
        .id = 6,
        .kind = .text,
        .frame = geometry.RectF.init(10, 10, 80, 20),
        .text = "Done",
    }};
    var empty_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const empty_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &empty }, geometry.RectF.init(0, 0, 240, 120), &empty_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", empty_layout);
    try std.testing.expectEqual(@as(usize, 0), view.canvas_widget_loop_animation_count);
    try std.testing.expectEqual(@as(usize, 0), view.canvas_render_animation_count);
    try std.testing.expect(!view.canvasRenderAnimationsActive(60 * std.time.ns_per_s));
}

test "runtime staggers segmented spinner opacity loops and removes them on unmount" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-spinner-segments", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 120),
    });

    const spinner = canvas.Widget{
        .id = 5,
        .kind = .spinner,
        .frame = geometry.RectF.init(20, 20, 20, 20),
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{spinner} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    // A segmented-register theme (structure rides the token surface, so
    // the pack choice IS the register choice — the runtime never asks).
    const tokens = canvas.DesignTokens.theme(.{ .pack = .geist });
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", tokens);

    // The visible dial arms one `.wrap` opacity loop PER SEGMENT, each
    // segment starting one count-th of the period after its neighbor.
    const view = &harness.runtime.views[0];
    const count = canvas.spinnerWidgetSegmentCount(tokens);
    try std.testing.expectEqual(@as(usize, 12), count);
    try std.testing.expectEqual(count, view.canvas_widget_loop_animation_count);
    try std.testing.expectEqual(count, view.canvas_render_animation_count);
    const period_ns: u64 = 1200 * std.time.ns_per_ms;
    const step_ns = period_ns / 12;
    const anchor = view.canvasRenderAnimations()[0].start_ns;
    for (view.canvasRenderAnimations(), 0..) |animation, segment| {
        try std.testing.expectEqual(canvas.spinnerWidgetSegmentCommandId(5, segment), animation.id);
        try std.testing.expectEqual(canvas.CanvasRenderAnimationLoop.wrap, animation.loop);
        try std.testing.expectEqual(@as(u32, 1200), animation.duration_ms);
        try std.testing.expectEqual(@as(f32, 1), animation.from_opacity.?);
        try std.testing.expectApproxEqAbs(@as(f32, 0.15), animation.to_opacity.?, 0.001);
        try std.testing.expectEqual(anchor + step_ns * segment, animation.start_ns);
    }
    try std.testing.expect(view.canvasRenderAnimationsActive(60 * std.time.ns_per_s));

    // The trail SAMPLES as a linear head-to-tail ramp: one whole period
    // past the anchor, segment 0 has just restarted (the bright head)
    // while its counterclockwise neighbor, one step older, has faded
    // one twelfth of the way to the floor.
    var overrides: [16]canvas.CanvasRenderOverride = undefined;
    const sampled = try view.sampleCanvasRenderAnimations(anchor + period_ns, &overrides);
    try std.testing.expectEqual(count, sampled.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1), sampled[0].opacity.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1 - 0.85 / 12.0), sampled[11].opacity.?, 0.001);
    // Half a period along, the head's opposite segment is mid-fade.
    const mid = try view.sampleCanvasRenderAnimations(anchor + period_ns + period_ns / 2, &overrides);
    try std.testing.expectApproxEqAbs(@as(f32, 1 - 0.85 / 2.0), mid[0].opacity.?, 0.001);

    // An unrelated display refresh must NOT reset the stagger's phase.
    _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
    try std.testing.expectEqual(count, view.canvas_render_animation_count);
    try std.testing.expectEqual(anchor, view.canvasRenderAnimations()[0].start_ns);
    try std.testing.expectEqual(anchor + step_ns * 11, view.canvasRenderAnimations()[11].start_ns);

    // Unmount: a rebuild without the spinner removes every segment loop
    // so the view goes idle (the frame pump's park condition).
    const empty = [_]canvas.Widget{.{
        .id = 6,
        .kind = .text,
        .frame = geometry.RectF.init(10, 10, 80, 20),
        .text = "Done",
    }};
    var empty_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const empty_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &empty }, geometry.RectF.init(0, 0, 240, 120), &empty_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", empty_layout);
    try std.testing.expectEqual(@as(usize, 0), view.canvas_widget_loop_animation_count);
    try std.testing.expectEqual(@as(usize, 0), view.canvas_render_animation_count);
    try std.testing.expect(!view.canvasRenderAnimationsActive(60 * std.time.ns_per_s));
}

test "runtime pulses visible skeletons and removes the loop on unmount" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-skeleton-pulse", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 120),
    });

    const skeleton = canvas.Widget{
        .id = 5,
        .kind = .skeleton,
        .frame = geometry.RectF.init(20, 20, 160, 20),
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{skeleton} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    // The visible skeleton arms ONE looping ping-pong opacity pulse on
    // its fill command — never completing, so frames keep sampling it.
    const view = &harness.runtime.views[0];
    const fill_id = canvas.skeletonWidgetFillCommandId(5);
    try std.testing.expectEqual(@as(usize, 1), view.canvas_widget_loop_animation_count);
    try std.testing.expectEqual(fill_id, view.canvas_widget_loop_animation_ids[0]);
    try std.testing.expectEqual(@as(usize, 1), view.canvas_render_animation_count);
    try std.testing.expectEqual(canvas.CanvasRenderAnimationLoop.ping_pong, view.canvasRenderAnimations()[0].loop);
    try std.testing.expect(view.canvasRenderAnimationsActive(60 * std.time.ns_per_s));

    // The pulse OSCILLATES between full opacity and the floor: the
    // sweep midpoint dims the fill, the sweep end sits at the floor,
    // and the next sweep brings it back up — never below 0.5, never
    // above 1 (the placeholder must not read as empty space).
    const start_ns = view.canvasRenderAnimations()[0].start_ns;
    var overrides: [4]canvas.CanvasRenderOverride = undefined;
    const mid = try view.sampleCanvasRenderAnimations(start_ns + 500 * std.time.ns_per_ms, &overrides);
    try std.testing.expectEqual(@as(usize, 1), mid.len);
    try std.testing.expectEqual(fill_id, mid[0].id);
    const mid_opacity = mid[0].opacity.?;
    try std.testing.expect(mid_opacity < 1 and mid_opacity >= 0.5);
    var floor_overrides: [4]canvas.CanvasRenderOverride = undefined;
    const floor = try view.sampleCanvasRenderAnimations(start_ns + 1000 * std.time.ns_per_ms, &floor_overrides);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), floor[0].opacity.?, 0.01);
    var back_overrides: [4]canvas.CanvasRenderOverride = undefined;
    const back = try view.sampleCanvasRenderAnimations(start_ns + 2000 * std.time.ns_per_ms, &back_overrides);
    try std.testing.expectApproxEqAbs(@as(f32, 1), back[0].opacity.?, 0.01);

    // An unrelated display refresh must NOT reset the pulse phase.
    _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
    try std.testing.expectEqual(@as(usize, 1), view.canvas_render_animation_count);
    try std.testing.expectEqual(start_ns, view.canvasRenderAnimations()[0].start_ns);

    // Unmount: a rebuild without the skeleton removes the loop so the
    // view goes idle (the frame pump's park condition).
    const loaded = [_]canvas.Widget{.{
        .id = 6,
        .kind = .text,
        .frame = geometry.RectF.init(10, 10, 80, 20),
        .text = "Loaded",
    }};
    var loaded_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const loaded_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &loaded }, geometry.RectF.init(0, 0, 240, 120), &loaded_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", loaded_layout);
    try std.testing.expectEqual(@as(usize, 0), view.canvas_widget_loop_animation_count);
    try std.testing.expectEqual(@as(usize, 0), view.canvas_render_animation_count);
}

test "runtime leaves skeletons static under reduced motion" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-skeleton-reduced-motion", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 120),
    });

    const skeleton = canvas.Widget{
        .id = 5,
        .kind = .skeleton,
        .frame = geometry.RectF.init(20, 20, 160, 20),
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{skeleton} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", canvas.DesignTokens.theme(.{ .reduce_motion = true }));

    // Reduced motion arms nothing: the placeholder renders as a static
    // block and the view never pumps frames for it.
    const view = &harness.runtime.views[0];
    try std.testing.expectEqual(@as(usize, 0), view.canvas_widget_loop_animation_count);
    try std.testing.expectEqual(@as(usize, 0), view.canvas_render_animation_count);
    try std.testing.expect(!view.canvasRenderAnimationsActive(60 * std.time.ns_per_s));
}

test "runtime leaves spinners static under reduced motion" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-spinner-reduced-motion", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 120),
    });

    const spinner = canvas.Widget{
        .id = 5,
        .kind = .spinner,
        .frame = geometry.RectF.init(20, 20, 20, 20),
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{spinner} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", canvas.DesignTokens.theme(.{ .reduce_motion = true }));

    // Reduced motion arms nothing: the arc renders as a static pose and
    // the view never pumps frames for it.
    const view = &harness.runtime.views[0];
    try std.testing.expectEqual(@as(usize, 0), view.canvas_widget_loop_animation_count);
    try std.testing.expectEqual(@as(usize, 0), view.canvas_render_animation_count);
    try std.testing.expect(!view.canvasRenderAnimationsActive(60 * std.time.ns_per_s));
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

test "runtime caret blink parks the frame pump and wakes at sweep boundaries; blur goes idle" {
    const TestApp = struct {
        frame_requires_render: bool = false,
        text_layout_upload_count: usize = 0,
        path_geometry_retain_count: usize = 0,
        image_retain_count: usize = 0,
        layer_retain_count: usize = 0,
        visual_effect_retain_count: usize = 0,
        render_overrides: []const canvas.CanvasRenderOverride = &.{},

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-caret-blink-scheduling", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .gpu_surface_frame => |frame_event| {
                    const frame = try runtime.nextCanvasFrame(frame_event.window_id, frame_event.label, .{
                        .frame_index = frame_event.frame_index,
                        .timestamp_ns = frame_event.timestamp_ns,
                        .surface_size = frame_event.size,
                        .scale = frame_event.scale_factor,
                        .render_overrides = self.render_overrides,
                    }, runtime.canvasFrameScratchStorage());
                    self.frame_requires_render = frame.requiresRender();
                    self.text_layout_upload_count = frame.text_layout_cache_plan.uploadCount();
                    self.path_geometry_retain_count = frame.path_geometry_cache_plan.retainCount();
                    self.image_retain_count = frame.image_cache_plan.retainCount();
                    self.layer_retain_count = frame.layer_cache_plan.retainCount();
                    self.visual_effect_retain_count = frame.visual_effect_cache_plan.retainCount();
                },
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state = TestApp{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 120),
    });

    const chrome_path = [_]canvas.PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(4, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(24, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(14, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const chrome_commands = [_]canvas.CanvasCommand{
        .{ .fill_path = .{
            .id = 100,
            .elements = &chrome_path,
            .fill = .{ .color = canvas.Color.rgb8(14, 165, 233) },
        } },
        .{ .shadow = .{
            .id = 102,
            .rect = geometry.RectF.init(58, 8, 20, 14),
            .radius = canvas.Radius.all(5),
            .blur = 8,
            .color = canvas.Color.rgba8(15, 23, 42, 80),
        } },
        .{ .draw_image = .{
            .id = 101,
            .image_id = 42,
            .dst = geometry.RectF.init(32, 4, 18, 18),
        } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &chrome_commands });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .placeholder = "Search",
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayListWithChrome(1, "canvas", .{}, .{
        .prefix_command_count = chrome_commands.len,
    });

    // Click-focus the field: the caret arms its looping blink (solid
    // 500 ms lead, then the 500 ms ping-pong sweeps — the first visual
    // boundary is one sweep past the lead's end, i.e. input time + 1 s).
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .timestamp_ns = 1_000_000_000,
        .x = 90,
        .y = 34,
    } });
    const view = &harness.runtime.views[0];
    const blink_id = canvas.textCaretCommandId(.text_field, 2);
    try std.testing.expectEqual(blink_id, view.canvas_widget_caret_blink_id);
    try std.testing.expectEqual(@as(u64, 1_500_000_000), view.canvasRenderAnimations()[0].start_ns);

    const requests_after_focus = harness.null_platform.gpu_surface_frame_request_count;
    // Presenting the focus frame must NOT re-arm the display-grid pump
    // (the pre-fix behavior requested a frame per present — the
    // focused-input CPU burn): the blink is the view's only time-work,
    // so the frame parks the pump and the framework's one-shot caret
    // wake carries the next boundary instead.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(240, 120),
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
    } });
    try std.testing.expect(app_state.frame_requires_render);
    try std.testing.expectEqual(requests_after_focus, harness.null_platform.gpu_surface_frame_request_count);
    const parked_wake = harness.null_platform.startedTimer(platform.caret_blink_timer_id).?;
    try std.testing.expect(parked_wake.active);
    try std.testing.expect(!parked_wake.repeats);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), parked_wake.interval_ns);

    // A jitter-EARLY wake (before the boundary) is NOT due: no frame
    // request, and the re-arm still targets the boundary ahead.
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(platform.caret_blink_timer_id, 1_800_000_000).?);
    try std.testing.expectEqual(requests_after_focus, harness.null_platform.gpu_surface_frame_request_count);
    const early_wake = harness.null_platform.startedTimer(platform.caret_blink_timer_id).?;
    try std.testing.expect(early_wake.active);
    try std.testing.expectEqual(@as(u64, 200_000_000), early_wake.interval_ns);

    // The boundary wake requests EXACTLY one frame — the blink's on/off
    // toggle renders at ~2 Hz instead of every display interval.
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(platform.caret_blink_timer_id, 2_000_000_000).?);
    try std.testing.expectEqual(requests_after_focus + 1, harness.null_platform.gpu_surface_frame_request_count);
    const boundary_wake = harness.null_platform.startedTimer(platform.caret_blink_timer_id).?;
    try std.testing.expect(boundary_wake.active);
    try std.testing.expectEqual(@as(u64, 500_000_000), boundary_wake.interval_ns);

    // The boundary frame presents the fade-out extreme (the readable
    // caret toggled off), reuses the field's cached text layout (no new
    // layout uploads — bounded frame work), and parks the pump again.
    view.gpu_timestamp_ns = 2_000_003_000;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(240, 120),
        .frame_index = 2,
        .timestamp_ns = 2_000_003_000,
    } });
    try std.testing.expect(app_state.frame_requires_render);
    try std.testing.expectEqual(@as(usize, 0), app_state.text_layout_upload_count);
    const presented_overrides = view.canvasFrameRenderOverrides();
    try std.testing.expectEqual(@as(usize, 1), presented_overrides.len);
    try std.testing.expectEqual(blink_id, presented_overrides[0].id);
    try std.testing.expect(presented_overrides[0].opacity.? < 0.1);
    try std.testing.expectEqual(requests_after_focus + 1, harness.null_platform.gpu_surface_frame_request_count);
    const blink_wake = harness.null_platform.startedTimer(platform.caret_blink_timer_id).?;
    try std.testing.expect(blink_wake.active);
    try std.testing.expectEqual(@as(u64, 499_997_000), blink_wake.interval_ns);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(240, 120),
        .frame_index = 3,
        .timestamp_ns = 2_016_669_667,
    } });
    try std.testing.expect(!app_state.frame_requires_render);
    const initial_explicit_overrides = [_]canvas.CanvasRenderOverride{
        .{ .id = 100, .opacity = 0.4 },
        .{ .id = 101, .opacity = 0.4 },
    };
    app_state.render_overrides = &initial_explicit_overrides;
    try canvas_frame.RuntimeCanvasFrames(Runtime).requestCanvasFrameForView(&harness.runtime, 0);
    try std.testing.expectEqual(requests_after_focus + 2, harness.null_platform.gpu_surface_frame_request_count);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(240, 120),
        .frame_index = 4,
        .timestamp_ns = 2_050_000_000,
    } });
    try std.testing.expect(app_state.frame_requires_render);
    const changed_explicit_overrides = [_]canvas.CanvasRenderOverride{
        .{ .id = 100, .opacity = 0.5 },
        .{ .id = 101, .opacity = 0.4 },
    };
    app_state.render_overrides = &changed_explicit_overrides;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(240, 120),
        .frame_index = 5,
        .timestamp_ns = 2_100_000_000,
    } });
    try std.testing.expect(app_state.frame_requires_render);
    try std.testing.expectEqual(@as(usize, 1), app_state.path_geometry_retain_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.image_retain_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.layer_retain_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.visual_effect_retain_count);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(240, 120),
        .frame_index = 6,
        .timestamp_ns = 2_200_000_000,
    } });
    try std.testing.expectEqual(@as(usize, 1), app_state.path_geometry_retain_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.image_retain_count);
    try std.testing.expect(app_state.layer_retain_count > 0);
    try std.testing.expectEqual(@as(usize, 1), app_state.visual_effect_retain_count);
    var scheduled_caret_overrides_at_removal: [1]canvas.CanvasRenderOverride = undefined;
    const scheduled_caret_overrides_at_removal_sample = try view.sampleCanvasRenderAnimations(2_450_000_000, &scheduled_caret_overrides_at_removal);
    try std.testing.expectEqual(@as(usize, 1), scheduled_caret_overrides_at_removal_sample.len);
    const caret_collision_override = [_]canvas.CanvasRenderOverride{.{
        .id = blink_id,
        .opacity = scheduled_caret_overrides_at_removal_sample[0].opacity,
    }};
    app_state.render_overrides = &caret_collision_override;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(240, 120),
        .frame_index = 8,
        .timestamp_ns = 2_400_000_000,
    } });
    try std.testing.expect(app_state.frame_requires_render);
    app_state.render_overrides = &.{};
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(240, 120),
        .frame_index = 9,
        .timestamp_ns = 2_450_000_000,
    } });
    try std.testing.expect(app_state.frame_requires_render);
    try std.testing.expectEqual(@as(usize, 1), app_state.path_geometry_retain_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.image_retain_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.layer_retain_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.visual_effect_retain_count);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(240, 120),
        .frame_index = 10,
        .timestamp_ns = 2_500_000_000,
    } });
    try std.testing.expect(app_state.frame_requires_render);

    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(platform.caret_blink_timer_id, 3_000_000_000).?);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(240, 120),
        .frame_index = 11,
        .timestamp_ns = 3_016_669_667,
    } });
    try std.testing.expect(app_state.frame_requires_render);

    const spinner = canvas.Widget{
        .id = 5,
        .kind = .spinner,
        .frame = geometry.RectF.init(180, 20, 20, 20),
    };
    var spinner_nodes: [3]canvas.WidgetLayoutNode = undefined;
    const spinner_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{ text_field, spinner } }, geometry.RectF.init(0, 0, 240, 120), &spinner_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", spinner_layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(240, 120),
        .frame_index = 12,
        .timestamp_ns = 3_033_333_000,
    } });
    try std.testing.expect(app_state.frame_requires_render);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(240, 120),
        .frame_index = 13,
        .timestamp_ns = 3_050_000_000,
    } });
    try std.testing.expect(app_state.frame_requires_render);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    // Blur drops the blink (the animation is removed, nothing arms
    // another wake) — and a STALE wake left over from the parked pump
    // neither requests a frame nor survives: the view goes idle.
    view.focused = false;
    _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), view.canvas_widget_caret_blink_id);
    try std.testing.expectEqual(@as(usize, 0), view.canvas_render_animation_count);
    const requests_after_blur = harness.null_platform.gpu_surface_frame_request_count;
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(platform.caret_blink_timer_id, 3_600_000_000).?);
    try std.testing.expectEqual(requests_after_blur, harness.null_platform.gpu_surface_frame_request_count);
    try std.testing.expect(!harness.null_platform.startedTimer(platform.caret_blink_timer_id).?.active);
    try std.testing.expect(harness.null_platform.fireTimer(platform.caret_blink_timer_id, 3_700_000_000) == null);
}
