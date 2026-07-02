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

test "runtime presents next canvas frame pixels" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-present-next-frame", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
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

test "runtime rejects duplicate canvas ids before replacing retained scene" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-duplicate", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });

    var commands: [max_canvas_commands_per_view + 1]canvas.CanvasCommand = undefined;
    for (&commands) |*command| command.* = .pop_opacity;
    try std.testing.expectError(error.CanvasCommandLimitReached, harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands }));
}
