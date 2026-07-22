const support = @import("test_support.zig");
const canvas_frame_helpers = @import("canvas_frame_helpers.zig");
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

test "runtime presents next canvas frame pixels" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-present-next-frame", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 4, 4),
    });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(1, 1, 2, 2),
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
    var pixels: [8 * 8 * 4]u8 = undefined;
    var scratch: [8 * 8 * 4]u8 = undefined;

    const frame = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{
        .frame_index = 1,
        .surface_size = geometry.SizeF.init(4, 4),
        .scale = 2,
    }, frame_storage, &pixels, &scratch, canvas.Color.rgb8(0, 0, 0));

    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqual(@as(usize, 8), harness.null_platform.gpu_surface_present_width);
    try std.testing.expectEqual(@as(usize, 8), harness.null_platform.gpu_surface_present_height);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 4, 4), harness.null_platform.gpu_surface_present_dirty_bounds.?);
    try std.testing.expectEqual(@as(usize, 8 * 8 * 4), harness.null_platform.gpu_surface_present_byte_len);
    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
    try std.testing.expect(!presented_frame.canvas_frame_full_repaint);
    try std.testing.expect(presented_frame.canvas_frame_dirty_bounds == null);
    try std.testing.expectEqual(@as(usize, 0), presented_frame.canvas_frame_profile_work_units);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.idle, presented_frame.canvas_frame_profile_risk);

    const changed_commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(2, 1, 1, 2),
        .fill = .{ .color = canvas.Color.rgb8(0, 128, 255) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &changed_commands });
    const changed_frame = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{
        .frame_index = 2,
        .surface_size = geometry.SizeF.init(4, 4),
        .scale = 2,
    }, frame_storage, &pixels, &scratch, canvas.Color.rgb8(0, 0, 0));

    try std.testing.expect(changed_frame.requiresRender());
    try std.testing.expect(!changed_frame.full_repaint);
    try std.testing.expect(changed_frame.dirty_bounds != null);
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqualDeep(changed_frame.dirty_bounds.?, harness.null_platform.gpu_surface_present_dirty_bounds.?);
}

test "runtime next canvas frame presents empty canvas once" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-empty-next-frame", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });

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

    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 1,
        .surface_size = geometry.SizeF.init(320, 240),
    }, frame_storage);
    try std.testing.expect(first_frame.full_repaint);
    try std.testing.expect(first_frame.requiresRender());
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 320, 240), first_frame.dirty_bounds.?);
    try std.testing.expect(harness.runtime.views[0].presented_canvas_valid);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].presented_canvas_revision);
    try std.testing.expect(harness.runtime.views[0].canvas_frame_requires_render);
    try std.testing.expect(harness.runtime.views[0].canvas_frame_full_repaint);

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 2,
        .surface_size = geometry.SizeF.init(320, 240),
    }, frame_storage);
    try std.testing.expect(!clean_frame.full_repaint);
    try std.testing.expect(!clean_frame.requiresRender());
    try std.testing.expect(clean_frame.dirty_bounds == null);
    try std.testing.expect(!harness.runtime.views[0].canvas_frame_requires_render);
    try std.testing.expect(!harness.runtime.views[0].canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.views[0].canvas_frame_change_count);
    try std.testing.expect(harness.runtime.views[0].canvas_frame_dirty_bounds == null);
}

test "runtime duplicate GPU surface resize keeps retained canvas frame clean" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-duplicate-resize", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });
    const initial_frame = harness.runtime.views[0].frame;

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = "canvas",
        .frame = initial_frame,
        .scale_factor = 2,
    } });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 320, 240),
        .fill = .{ .color = canvas.Color.rgb8(245, 248, 255) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var render_commands: [1]canvas.RenderCommand = undefined;
    var render_batches: [1]canvas.RenderBatch = undefined;
    var resources: [1]canvas.RenderResource = undefined;
    var resource_cache_entries: [1]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [1]canvas.GlyphAtlasEntry = undefined;
    var changes: [2]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    };

    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 1,
        .surface_size = geometry.SizeF.init(320, 240),
        .scale = 2,
    }, frame_storage);
    try std.testing.expect(first_frame.full_repaint);
    try std.testing.expect(harness.runtime.views[0].presented_canvas_valid);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = "canvas",
        .frame = initial_frame,
        .scale_factor = 2,
    } });
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.dirty_region_count);
    try std.testing.expect(harness.runtime.views[0].presented_canvas_valid);

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 2,
        .surface_size = geometry.SizeF.init(320, 240),
        .scale = 2,
    }, frame_storage);
    try std.testing.expect(!clean_frame.full_repaint);
    try std.testing.expect(!clean_frame.requiresRender());

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = "canvas",
        .frame = geometry.RectF.init(0, 0, 360, 240),
        .scale_factor = 2,
    } });
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(!harness.runtime.views[0].presented_canvas_valid);
}

test "runtime next canvas frame keeps unchanged clipped display lists incremental" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-clipped-next-frame", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 120, 80),
    });

    const commands = [_]canvas.CanvasCommand{
        .{ .push_clip = .{ .id = 90, .rect = geometry.RectF.init(0, 0, 80, 48) } },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(8, 8, 96, 32), .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) } } },
        .pop_clip,
    };
    const changed_commands = [_]canvas.CanvasCommand{
        .{ .push_clip = .{ .id = 90, .rect = geometry.RectF.init(0, 0, 80, 48) } },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(12, 8, 96, 32), .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) } } },
        .pop_clip,
    };

    var render_commands: [2]canvas.RenderCommand = undefined;
    var render_batches: [1]canvas.RenderBatch = undefined;
    var resources: [2]canvas.RenderResource = undefined;
    var resource_cache_entries: [2]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [4]canvas.RenderResourceCacheAction = undefined;
    var layers: [2]canvas.RenderLayer = undefined;
    var layer_cache_entries: [2]canvas.RenderLayerCacheEntry = undefined;
    var layer_cache_actions: [4]canvas.RenderLayerCacheAction = undefined;
    var glyphs: [0]canvas.GlyphAtlasEntry = .{};
    var changes: [4]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .layers = &layers,
        .layer_cache_entries = &layer_cache_entries,
        .layer_cache_actions = &layer_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    };

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });
    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 1 }, frame_storage);
    try std.testing.expect(first_frame.full_repaint);
    try std.testing.expect(first_frame.requiresRender());

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 2 }, frame_storage);
    try std.testing.expect(!clean_frame.full_repaint);
    try std.testing.expect(!clean_frame.requiresRender());
    try std.testing.expect(clean_frame.dirty_bounds == null);

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &changed_commands });
    const changed_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 3 }, frame_storage);
    try std.testing.expect(!changed_frame.full_repaint);
    try std.testing.expect(changed_frame.requiresRender());
    try std.testing.expect(changed_frame.dirty_bounds != null);
}

test "runtime invalidates canvas display list dirty regions" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-dirty", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(50, 70, 320, 240),
    });

    var initial_commands: [1]canvas.CanvasCommand = undefined;
    var initial_builder = canvas.Builder.init(&initial_commands);
    try initial_builder.fillRect(.{
        .id = 1,
        .rect = geometry.RectF.init(-10, -10, 40, 40),
        .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
    });

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", initial_builder.displayList());
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(50, 70, 30, 30), harness.runtime.pendingDirtyRegions()[0]);

    var moved_commands: [1]canvas.CanvasCommand = undefined;
    var moved_builder = canvas.Builder.init(&moved_commands);
    try moved_builder.fillRect(.{
        .id = 1,
        .rect = geometry.RectF.init(10, 0, 40, 40),
        .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
    });

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", moved_builder.displayList());
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(50, 70, 50, 40), harness.runtime.pendingDirtyRegions()[0]);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", moved_builder.displayList());
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);
}

test "runtime requests gpu surface frames for retained canvas changes" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-frame-request", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(50, 70, 320, 240),
    });

    var initial_commands: [1]canvas.CanvasCommand = undefined;
    var initial_builder = canvas.Builder.init(&initial_commands);
    try initial_builder.fillRect(.{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 40, 40),
        .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
    });

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", initial_builder.displayList());
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_frame_request_count);
    try std.testing.expectEqual(@as(platform.WindowId, 1), harness.null_platform.gpu_surface_frame_request_window_id);
    try std.testing.expectEqualStrings("canvas", harness.null_platform.gpu_surface_frame_request_label_storage[0..harness.null_platform.gpu_surface_frame_request_label_len]);

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", initial_builder.displayList());
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_frame_request_count);

    var moved_commands: [1]canvas.CanvasCommand = undefined;
    var moved_builder = canvas.Builder.init(&moved_commands);
    try moved_builder.fillRect(.{
        .id = 1,
        .rect = geometry.RectF.init(8, 0, 40, 40),
        .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
    });

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", moved_builder.displayList());
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.gpu_surface_frame_request_count);
}

// Incremental-vs-full pixel oracle for reflow damage: present tree A,
// swap to tree B through the SAME incremental machinery a selection
// change drives (keyed subtree replaced, elements removed/shrunk/moved),
// then compare the incrementally updated buffer against a fresh full
// render of tree B. Any byte difference is a stale pixel the damage
// region failed to cover.
fn expectIncrementalPixelPresentMatchesFullRender(
    comptime name: []const u8,
    retained_baseline: bool,
    scale: f32,
) !void {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = name, .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const surface = geometry.SizeF.init(220, 80);
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.pixel_present_retained_baseline = retained_baseline;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, surface.width, surface.height),
    });

    // Detail-pane shape: a surface panel behind a row of pills. Tree A
    // shows two wide pills; tree B (another selection) shows one shorter,
    // shifted pill under NEW ids — the keyed replacement a `for`/`if`
    // reconciliation produces.
    const tree_a = [_]canvas.Widget{
        .{ .id = 10, .kind = .panel, .frame = geometry.RectF.init(0, 0, 220, 80) },
        .{ .id = 20, .kind = .badge, .frame = geometry.RectF.init(10, 24, 120, 24), .text = "In progress" },
        .{ .id = 21, .kind = .badge, .frame = geometry.RectF.init(140, 24, 70, 24), .text = "High" },
    };
    const tree_b = [_]canvas.Widget{
        .{ .id = 10, .kind = .panel, .frame = geometry.RectF.init(0, 0, 220, 80) },
        .{ .id = 30, .kind = .badge, .frame = geometry.RectF.init(10, 26, 60, 20), .text = "Open" },
    };

    const pixel_size = try canvas_frame.canvasSurfacePixelSize(surface, scale);
    const incremental = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(incremental);
    const full = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(full);
    const scratch = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(scratch);
    const clear_color = canvas.Color.rgb8(15, 23, 42);

    var nodes_a: [4]canvas.WidgetLayoutNode = undefined;
    const layout_a = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &tree_a }, geometry.RectF.init(0, 0, surface.width, surface.height), &nodes_a);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout_a);
    _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
    _ = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{
        .frame_index = 1,
        .timestamp_ns = 16_000_000,
        .surface_size = surface,
        .scale = scale,
    }, canvasFrameScratchStorage(&harness.runtime), incremental, scratch, clear_color);

    var nodes_b: [4]canvas.WidgetLayoutNode = undefined;
    const layout_b = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &tree_b }, geometry.RectF.init(0, 0, surface.width, surface.height), &nodes_b);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout_b);
    const swapped = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{
        .frame_index = 2,
        .timestamp_ns = 32_000_000,
        .surface_size = surface,
        .scale = scale,
    }, canvasFrameScratchStorage(&harness.runtime), incremental, scratch, clear_color);
    // The oracle only proves anything if the swap actually rode the
    // incremental path.
    try std.testing.expect(!swapped.full_repaint);
    try std.testing.expect(swapped.dirty_bounds != null);

    _ = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{
        .frame_index = 3,
        .timestamp_ns = 48_000_000,
        .surface_size = surface,
        .scale = scale,
        .full_repaint = true,
    }, canvasFrameScratchStorage(&harness.runtime), full, scratch, clear_color);

    try std.testing.expectEqualSlices(u8, full, incremental);
}

test "incremental repaint redraws unchanged neighbors sharing a boundary pixel" {
    // A fractional dirty edge lands mid-pixel: the clear covers the
    // whole boundary pixel, so an UNCHANGED antialiased neighbor that
    // painted partial coverage into that pixel must be redrawn.
    // Damage snapped to the device-pixel grid keeps the cull region
    // identical to the cleared pixels; culled against the unaligned
    // float rect, the neighbor's boundary coverage was erased into a
    // missing fringe.
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-boundary-pixel", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const surface = geometry.SizeF.init(32, 16);
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    // The refined dirty path (retained key+fingerprint baseline) is
    // the one that produces a TIGHT rect around the changed command;
    // the summary fallback dirties every keyed command and would mask
    // the boundary-pixel hazard.
    harness.runtime.options.pixel_present_retained_baseline = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, surface.width, surface.height),
    });

    // The changing rect ends mid-pixel at x=10.2; the unchanged rounded
    // neighbor begins at x=11.3, feathering antialiased coverage into
    // pixel column 11 — the column the aligned clear wipes.
    const neighbor = canvas.CanvasCommand{ .fill_rounded_rect = .{
        .id = 2,
        .rect = geometry.RectF.init(11.3, 2, 8, 8),
        .radius = canvas.Radius.all(3),
        .fill = .{ .color = canvas.Color.rgb8(148, 163, 184) },
    } };
    const changing = struct {
        fn command(color: canvas.Color) canvas.CanvasCommand {
            return .{ .fill_rect = .{
                .id = 1,
                .rect = geometry.RectF.init(2, 2, 8.2, 8),
                .fill = .{ .color = color },
            } };
        }
    }.command;

    const byte_len: usize = 32 * 16 * 4;
    var incremental: [byte_len]u8 = undefined;
    var full: [byte_len]u8 = undefined;
    var scratch: [byte_len]u8 = undefined;
    const clear_color = canvas.Color.rgb8(15, 23, 42);

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &.{ changing(canvas.Color.rgb8(255, 0, 0)), neighbor } });
    _ = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{
        .frame_index = 1,
        .timestamp_ns = 16_000_000,
        .surface_size = surface,
    }, canvasFrameScratchStorage(&harness.runtime), &incremental, &scratch, clear_color);

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &.{ changing(canvas.Color.rgb8(37, 99, 235)), neighbor } });
    const swapped = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{
        .frame_index = 2,
        .timestamp_ns = 32_000_000,
        .surface_size = surface,
    }, canvasFrameScratchStorage(&harness.runtime), &incremental, &scratch, clear_color);
    try std.testing.expect(!swapped.full_repaint);
    try std.testing.expect(swapped.dirty_bounds != null);

    _ = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{
        .frame_index = 3,
        .timestamp_ns = 48_000_000,
        .surface_size = surface,
        .full_repaint = true,
    }, canvasFrameScratchStorage(&harness.runtime), &full, &scratch, clear_color);

    try std.testing.expectEqualSlices(u8, &full, &incremental);
}

test "a finer presentation scale re-aligns damage to its own pixel grid" {
    // Pixel grids need not nest across scales: a plan-grid-aligned
    // dirty edge at 11 points sits mid-pixel at a 1.5x presentation
    // scale, so the present's clear wipes a boundary pixel whose
    // antialiased coverage came from an unchanged neighbor the
    // plan-aligned scissor culled. Damage presented at a DIFFERENT
    // scale must re-snap outward on the presentation grid.
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-fractional-scale-grid", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const surface = geometry.SizeF.init(32, 16);
    const presentation_scale: f32 = 1.5;
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.pixel_present_retained_baseline = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, surface.width, surface.height),
    });

    // The changing rect ends at x=9.2; with the bleed and plan-grid
    // snap the dirty edge lands at x=11 — device 16.5 at 1.5x, so the
    // clear covers the pixel spanning points [10.667, 11.333). The
    // unchanged rounded neighbor at x=11.1 feathers coverage into that
    // pixel while sitting outside the plan-aligned scissor.
    const neighbor = canvas.CanvasCommand{ .fill_rounded_rect = .{
        .id = 2,
        .rect = geometry.RectF.init(11.1, 2, 8, 8),
        .radius = canvas.Radius.all(3),
        .fill = .{ .color = canvas.Color.rgb8(148, 163, 184) },
    } };
    const changing = struct {
        fn command(color: canvas.Color) canvas.CanvasCommand {
            return .{ .fill_rect = .{
                .id = 1,
                .rect = geometry.RectF.init(2, 2, 7.2, 8),
                .fill = .{ .color = color },
            } };
        }
    }.command;

    const pixel_size = try canvas_frame_helpers.canvasSurfacePixelSize(surface, presentation_scale);
    const incremental = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(incremental);
    const full = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(full);
    const scratch = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(scratch);
    const clear_color = canvas.Color.rgb8(15, 23, 42);
    var no_gpu_commands: [0]canvas.CanvasGpuCommand = .{};
    var no_packet_bytes: [0]u8 = .{};

    const presentScaled = struct {
        fn present(h: anytype, frame_index: u64, full_repaint: bool, pixels: []u8, sc: []u8, clear: canvas.Color, gpu: []canvas.CanvasGpuCommand, packet: []u8) !canvas.CanvasFrame {
            const result = try h.runtime.presentNextCanvasFrame(1, "canvas", .{
                .frame_index = frame_index,
                .timestamp_ns = frame_index * 16_000_000,
                .surface_size = geometry.SizeF.init(32, 16),
                .full_repaint = full_repaint,
            }, canvasFrameScratchStorage(&h.runtime), gpu, packet, pixels, sc, clear, 1.5);
            return result.frame;
        }
    }.present;

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &.{ changing(canvas.Color.rgb8(255, 0, 0)), neighbor } });
    _ = try presentScaled(harness, 1, false, incremental, scratch, clear_color, &no_gpu_commands, &no_packet_bytes);

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &.{ changing(canvas.Color.rgb8(37, 99, 235)), neighbor } });
    const swapped = try presentScaled(harness, 2, false, incremental, scratch, clear_color, &no_gpu_commands, &no_packet_bytes);
    try std.testing.expect(!swapped.full_repaint);
    try std.testing.expect(swapped.dirty_bounds != null);

    _ = try presentScaled(harness, 3, true, full, scratch, clear_color, &no_gpu_commands, &no_packet_bytes);
    try std.testing.expectEqualSlices(u8, full, incremental);
}

test "device-grid re-alignment survives the float round-trip" {
    // Snapped edges live in f32 logical points: `ceil(v*s)/s` can land
    // on an f32 whose product with the scale rounds back UP past the
    // device boundary (an edge at 65 points re-snapped at 1.75x becomes
    // 65.14286, whose product is 114.00001 — ceiling to 115), so the
    // consumer would clear one pixel more than culling against the rect
    // admits — erasing an unchanged neighbor's coverage in that extra
    // pixel. The snap must pick edges whose round trip lands on the
    // intended boundary.
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-grid-roundtrip", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const surface = geometry.SizeF.init(80, 16);
    const presentation_scale: f32 = 1.75;
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.pixel_present_retained_baseline = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, surface.width, surface.height),
    });

    // Changing rect ends at x=63.9: bleed plus the plan-grid snap land
    // the dirty edge exactly on 65 points — the coordinate whose 1.75x
    // re-snap rounds badly. The unchanged rounded neighbor at x=65.3
    // paints device pixel 114, the pixel the bad round trip clears.
    const neighbor = canvas.CanvasCommand{ .fill_rounded_rect = .{
        .id = 2,
        .rect = geometry.RectF.init(65.3, 2, 8, 8),
        .radius = canvas.Radius.all(3),
        .fill = .{ .color = canvas.Color.rgb8(148, 163, 184) },
    } };
    const changing = struct {
        fn command(color: canvas.Color) canvas.CanvasCommand {
            return .{ .fill_rect = .{
                .id = 1,
                .rect = geometry.RectF.init(2, 2, 61.9, 8),
                .fill = .{ .color = color },
            } };
        }
    }.command;

    const pixel_size = try canvas_frame_helpers.canvasSurfacePixelSize(surface, presentation_scale);
    const incremental = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(incremental);
    const full = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(full);
    const scratch = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(scratch);
    const clear_color = canvas.Color.rgb8(15, 23, 42);
    var no_gpu_commands: [0]canvas.CanvasGpuCommand = .{};
    var no_packet_bytes: [0]u8 = .{};

    const presentScaled = struct {
        fn present(h: anytype, frame_index: u64, full_repaint: bool, pixels: []u8, sc: []u8, clear: canvas.Color, gpu: []canvas.CanvasGpuCommand, packet: []u8) !canvas.CanvasFrame {
            const result = try h.runtime.presentNextCanvasFrame(1, "canvas", .{
                .frame_index = frame_index,
                .timestamp_ns = frame_index * 16_000_000,
                .surface_size = geometry.SizeF.init(80, 16),
                .full_repaint = full_repaint,
            }, canvasFrameScratchStorage(&h.runtime), gpu, packet, pixels, sc, clear, 1.75);
            return result.frame;
        }
    }.present;

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &.{ changing(canvas.Color.rgb8(255, 0, 0)), neighbor } });
    _ = try presentScaled(harness, 1, false, incremental, scratch, clear_color, &no_gpu_commands, &no_packet_bytes);

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &.{ changing(canvas.Color.rgb8(37, 99, 235)), neighbor } });
    const swapped = try presentScaled(harness, 2, false, incremental, scratch, clear_color, &no_gpu_commands, &no_packet_bytes);
    try std.testing.expect(!swapped.full_repaint);
    try std.testing.expect(swapped.dirty_bounds != null);
    // The dirty edge's round trip must land on its device boundary —
    // never past it. The presented-scale rework carries one presented
    // device pixel of bleed past the plan edge's boundary (114), so
    // the reconstructed product may ceil to 115 but never beyond.
    const dirty = swapped.dirty_bounds.?;
    try std.testing.expect(@ceil(dirty.maxX() * presentation_scale) <= 115);

    _ = try presentScaled(harness, 3, true, full, scratch, clear_color, &no_gpu_commands, &no_packet_bytes);
    try std.testing.expectEqualSlices(u8, full, incremental);
}

test "bleed-aligned dirty edges round-trip onto their device boundaries" {
    // The stored rect's f32 fields must hand consumers products that
    // land exactly on the intended integer device boundaries — one
    // whole device pixel of bleed outside the input's floor/ceil — in
    // BOTH directions: the stored min edge and the RECONSTRUCTED max
    // edge (x + width). A rounded 1/scale inflation falls a whole
    // pixel short at fractional scales, and a re-encoded width can
    // push the reconstructed product past its boundary.
    const scales = [_]f32{ 1, 1.1, 1.2, 1.25, 1.3, 1.5, 1.75, 2, 2.5, 3 };
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const x: f32 = @as(f32, @floatFromInt(i)) * 0.173 + 0.07;
        const w: f32 = @as(f32, @floatFromInt(i % 37)) * 0.61 + 0.4;
        const rect = geometry.RectF.init(x, x * 0.5, w, w * 0.8);
        for (scales) |scale| {
            const aligned = canvas_frame.bleedAlignedCanvasDirtyBounds(rect, scale, 1).?;
            const min_boundary = @floor(rect.minX() * scale) - 1;
            const max_boundary = @ceil(rect.maxX() * scale) + 1;
            const min_product = aligned.minX() * scale;
            const max_product = aligned.maxX() * scale;
            try std.testing.expect(min_product >= min_boundary);
            try std.testing.expect(@floor(min_product) == min_boundary);
            try std.testing.expect(max_product <= max_boundary);
            try std.testing.expect(@ceil(max_product) == max_boundary);
        }
    }
}

test "bleed alignment stays finite for far off-screen damage" {
    // Scaling a far off-screen coordinate can floor/ceil to infinity;
    // the boundary must clamp instead of the edge search walking
    // nextAfter from infinity forever. The clamped result only needs
    // to stay finite and OUTSIDE any presentable surface — surface
    // clipping owns the rest.
    const negative = canvas_frame.bleedAlignedCanvasDirtyBounds(geometry.RectF.init(-3.0e38, -3.0e38, 1.0e38, 1.0e38), 2, 1).?;
    try std.testing.expect(std.math.isFinite(negative.minX()));
    try std.testing.expect(std.math.isFinite(negative.maxX()));
    try std.testing.expect(negative.maxX() <= 0);

    const positive = canvas_frame.bleedAlignedCanvasDirtyBounds(geometry.RectF.init(1.0e38, 1.0e38, 2.0e38, 2.0e38), 2, 1).?;
    try std.testing.expect(std.math.isFinite(positive.minX()));
    try std.testing.expect(std.math.isFinite(positive.maxX()));
    try std.testing.expect(positive.minX() >= 16_384);
}

test "reflow damage reaches a whole device pixel past changed bounds at fractional scales" {
    // The AA bleed allowance is one DEVICE pixel: at scale 1.3 a pill
    // starting at x=170 occupies device column 220, so removing it must
    // dirty column 219 too — inflating by a rounded 1/scale in logical
    // points multiplies back to exactly 220 and falls a whole pixel
    // short.
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-fractional-bleed", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const surface = geometry.SizeF.init(320, 240);
    const scale: f32 = 1.3;
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.pixel_present_retained_baseline = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, surface.width, surface.height),
    });

    const anchor = canvas.CanvasCommand{ .fill_rect = .{
        .id = 100,
        .rect = geometry.RectF.init(4, 4, 24, 12),
        .fill = .{ .color = canvas.Color.rgb8(51, 65, 85) },
    } };
    const pill = canvas.CanvasCommand{ .fill_rounded_rect = .{
        .id = 200,
        .rect = geometry.RectF.init(170, 60, 40, 24),
        .radius = canvas.Radius.all(12),
        .fill = .{ .color = canvas.Color.rgb8(148, 163, 184) },
    } };

    const pixel_size = try canvas_frame_helpers.canvasSurfacePixelSize(surface, scale);
    const pixels = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(pixels);
    const scratch = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(scratch);
    const clear_color = canvas.Color.rgb8(15, 23, 42);

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &.{ anchor, pill } });
    _ = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{
        .frame_index = 1,
        .timestamp_ns = 16_000_000,
        .surface_size = surface,
        .scale = scale,
    }, canvasFrameScratchStorage(&harness.runtime), pixels, scratch, clear_color);

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &.{anchor} });
    const removed = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{
        .frame_index = 2,
        .timestamp_ns = 32_000_000,
        .surface_size = surface,
        .scale = scale,
    }, canvasFrameScratchStorage(&harness.runtime), pixels, scratch, clear_color);
    try std.testing.expect(!removed.full_repaint);
    // The vacated pill starts in device column 220; its bleed pixel is
    // column 219, which the damage must reach.
    const dirty = removed.dirty_bounds.?;
    try std.testing.expect(@floor(dirty.minX() * scale) <= 219);
}

test "keyed subtree swap leaves no stale pixels on the summary-dirty pixel path" {
    try expectIncrementalPixelPresentMatchesFullRender("gpu-canvas-reflow-summary", false, 1);
    try expectIncrementalPixelPresentMatchesFullRender("gpu-canvas-reflow-summary-2x", false, 2);
}

test "keyed subtree swap leaves no stale pixels on the refined-dirty pixel path" {
    try expectIncrementalPixelPresentMatchesFullRender("gpu-canvas-reflow-refined", true, 1);
    try expectIncrementalPixelPresentMatchesFullRender("gpu-canvas-reflow-refined-2x", true, 2);
}

test "runtime rejects duplicate canvas ids before replacing retained scene" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-duplicate", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });

    var valid_commands: [1]canvas.CanvasCommand = undefined;
    var valid_builder = canvas.Builder.init(&valid_commands);
    try valid_builder.fillRect(.{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 40, 40),
        .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
    });
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", valid_builder.displayList());

    const duplicate_commands = [_]canvas.CanvasCommand{
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(0, 0, 40, 40), .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) } } },
        .{ .blur = .{ .id = 2, .rect = geometry.RectF.init(0, 0, 40, 40), .radius = 4 } },
    };
    try std.testing.expectError(error.DuplicateObjectId, harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &duplicate_commands }));

    const retained = try harness.runtime.canvasDisplayList(1, "canvas");
    try std.testing.expectEqual(@as(usize, 1), retained.commandCount());
    try std.testing.expectEqual(@as(?canvas.ObjectId, 1), retained.commands[0].objectId());
}

test "runtime validates canvas display list command limits" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-limits", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });

    var commands: [max_canvas_commands_per_view + 1]canvas.CanvasCommand = undefined;
    for (&commands) |*command| command.* = .pop_opacity;
    try std.testing.expectError(error.CanvasCommandLimitReached, harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands }));
}
