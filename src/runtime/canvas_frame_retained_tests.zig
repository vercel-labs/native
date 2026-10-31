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

test "runtime retains canvas display lists on GPU surface views" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    var text_storage = [_]u8{ 'O', 'K' };
    var stops = [_]canvas.GradientStop{
        .{ .offset = 0, .color = canvas.Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = canvas.Color.rgb8(37, 99, 235) },
    };
    var glyphs = [_]canvas.Glyph{
        .{ .id = 42, .x = 12, .y = 24, .advance = 9 },
    };
    var path = [_]canvas.PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(1, 2), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    var commands: [4]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try builder.fillRect(.{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 320, 240),
        .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(320, 240),
            .stops = &stops,
        } },
    });
    try builder.fillPath(.{
        .id = 2,
        .elements = &path,
        .fill = .{ .color = canvas.Color.rgb8(15, 23, 42) },
    });
    try builder.drawText(.{
        .id = 3,
        .font_id = 7,
        .size = 16,
        .origin = geometry.PointF.init(16, 32),
        .color = canvas.Color.rgb8(15, 23, 42),
        .text = text_storage[0..],
        .glyphs = &glyphs,
    });

    const info = try harness.runtime.setCanvasDisplayList(1, "canvas", builder.displayList());
    try std.testing.expectEqual(@as(u64, 1), info.canvas_revision);
    try std.testing.expectEqual(@as(usize, 3), info.canvas_command_count);

    text_storage[0] = 'N';
    stops[0].offset = 0.5;
    glyphs[0].id = 900;
    path[0].points[0] = geometry.PointF.init(99, 99);

    const retained = try harness.runtime.canvasDisplayList(1, "canvas");
    try std.testing.expectEqual(@as(usize, 3), retained.commandCount());
    switch (retained.commands[0]) {
        .fill_rect => |value| switch (value.fill) {
            .linear_gradient => |gradient| {
                try std.testing.expectEqual(@as(f32, 0), gradient.stops[0].offset);
                try std.testing.expectEqual(@as(f32, 1), gradient.stops[0].color.r);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    switch (retained.commands[1]) {
        .fill_path => |value| try std.testing.expectEqual(@as(f32, 1), value.elements[0].points[0].x),
        else => return error.TestUnexpectedResult,
    }
    switch (retained.commands[2]) {
        .draw_text => |value| {
            try std.testing.expectEqualStrings("OK", value.text);
            try std.testing.expectEqual(@as(u32, 42), value.glyphs[0].id);
        },
        else => return error.TestUnexpectedResult,
    }

    const snapshot = harness.runtime.automationSnapshot("Canvas");
    const canvas_view = testViewByLabel(snapshot.views, "canvas").?;
    try std.testing.expectEqual(@as(u64, 1), canvas_view.canvas_revision);
    try std.testing.expectEqual(@as(usize, 3), canvas_view.canvas_command_count);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try automation.snapshot.writeText(snapshot, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_revision=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_commands=3") != null);
}

test "runtime builds canvas frame plans from retained GPU canvas state" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-frame", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const stops = [_]canvas.GradientStop{
        .{ .offset = 0, .color = canvas.Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = canvas.Color.rgb8(24, 24, 27) },
    };
    const commands = [_]canvas.CanvasCommand{
        .{ .fill_rounded_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(16, 16, 160, 72),
            .radius = canvas.Radius.all(12),
            .fill = .{ .linear_gradient = .{
                .start = geometry.PointF.init(16, 16),
                .end = geometry.PointF.init(176, 88),
                .stops = &stops,
            } },
        } },
        .{ .draw_text = .{
            .id = 2,
            .font_id = 5,
            .size = 14,
            .origin = geometry.PointF.init(28, 48),
            .color = canvas.Color.rgb8(15, 23, 42),
            .text = "OK",
        } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var render_commands: [4]canvas.RenderCommand = undefined;
    var render_batches: [4]canvas.RenderBatch = undefined;
    var resources: [4]canvas.RenderResource = undefined;
    var resource_cache_entries: [4]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [4]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [4]canvas.GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [4]canvas.GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [4]canvas.GlyphAtlasCacheAction = undefined;
    var changes: [4]canvas.DiffChange = undefined;
    const frame = try harness.runtime.canvasFramePlan(1, "canvas", null, .{
        .frame_index = 9,
        .timestamp_ns = 100,
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .changes = &changes,
    });

    try std.testing.expectEqual(@as(u64, 9), frame.frame_index);
    try std.testing.expectEqual(@as(u64, 100), frame.timestamp_ns);
    try std.testing.expectEqualDeep(geometry.SizeF.init(320, 240), frame.surface_size);
    try std.testing.expect(frame.full_repaint);
    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 2), frame.display_list.commandCount());
    try std.testing.expectEqual(@as(usize, 2), frame.render_plan.commandCount());
    try std.testing.expectEqual(@as(usize, 2), frame.batch_plan.batchCount());
    try std.testing.expectEqual(@as(usize, 2), frame.resource_plan.resourceCount());
    try std.testing.expectEqual(@as(usize, 2), frame.glyph_atlas_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), frame.resource_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 2), frame.resource_cache_plan.actionCount());
    try std.testing.expectEqual(canvas.RenderResourceCacheActionKind.upload, frame.resource_cache_plan.actions[0].kind);
    try std.testing.expectEqual(@as(usize, 2), frame.glyph_atlas_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 320, 240), frame.dirty_bounds.?);
}

test "runtime canvas frame plan computes incremental dirty from previous display list" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-frame-dirty", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 320, 240),
    });

    const previous_commands = [_]canvas.CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 40, 40), .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) } } },
    };
    const next_commands = [_]canvas.CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(20, 0, 40, 40), .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) } } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &next_commands });

    var render_commands: [2]canvas.RenderCommand = undefined;
    var render_batches: [1]canvas.RenderBatch = undefined;
    var resources: [0]canvas.RenderResource = .{};
    var resource_cache_entries: [0]canvas.RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]canvas.RenderResourceCacheAction = .{};
    var glyphs: [0]canvas.GlyphAtlasEntry = .{};
    var changes: [2]canvas.DiffChange = undefined;
    const frame = try harness.runtime.canvasFramePlan(1, "canvas", .{ .commands = &previous_commands }, .{}, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    try std.testing.expect(!frame.full_repaint);
    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqualDeep(geometry.SizeF.init(320, 240), frame.surface_size);
    try std.testing.expectEqual(@as(usize, 1), frame.batch_plan.batchCount());
    try std.testing.expectEqual(@as(usize, 1), frame.changes.len);
    try std.testing.expectEqual(canvas.DiffKind.changed, frame.changes[0].kind);
    try std.testing.expectEqual(@as(?canvas.ObjectId, 1), frame.changes[0].id);
    // Old extent (0,0,40,40) union new (20,0,40,40), inflated by the
    // one-device-pixel AA bleed and clipped to the surface.
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 61, 41), frame.dirty_bounds.?);
}

test "runtime next canvas frame tracks presented state and resource cache" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-next-frame", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const stops = [_]canvas.GradientStop{
        .{ .offset = 0, .color = canvas.Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = canvas.Color.rgb8(24, 24, 27) },
    };
    const first_commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 40, 40),
        .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(40, 40),
            .stops = &stops,
        } },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &first_commands });

    var render_commands: [4]canvas.RenderCommand = undefined;
    var render_batches: [4]canvas.RenderBatch = undefined;
    var resources: [4]canvas.RenderResource = undefined;
    var resource_cache_entries: [4]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [8]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [4]canvas.GlyphAtlasEntry = undefined;
    var changes: [4]canvas.DiffChange = undefined;
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
    try std.testing.expect(first_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), first_frame.resource_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(u64, 1), harness.runtime.views[0].presented_canvas_revision);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_resource_cache_count);

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 2 }, frame_storage);
    try std.testing.expect(!clean_frame.full_repaint);
    try std.testing.expect(!clean_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), clean_frame.render_plan.commandCount());
    try std.testing.expectEqual(@as(usize, 0), clean_frame.batch_plan.batchCount());
    try std.testing.expectEqual(@as(usize, 0), clean_frame.changes.len);
    try std.testing.expectEqual(@as(usize, 0), clean_frame.resource_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_resource_cache_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.views[0].canvas_frame_profile_work_units);

    const moved_commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(20, 0, 40, 40),
        .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(40, 40),
            .stops = &stops,
        } },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &moved_commands });

    const moved_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 3 }, frame_storage);
    try std.testing.expect(!moved_frame.full_repaint);
    try std.testing.expect(moved_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), moved_frame.changes.len);
    try std.testing.expectEqual(canvas.DiffKind.changed, moved_frame.changes[0].kind);
    // Both extents' union, inflated by the AA bleed and surface-clipped.
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 61, 41), moved_frame.dirty_bounds.?);
    try std.testing.expectEqual(@as(usize, 1), moved_frame.resource_cache_plan.retainCount());
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].presented_canvas_revision);
}

test "runtime next canvas frame repaints when retained surface size changes" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-next-frame-resize", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 40, 40),
        .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var render_commands: [2]canvas.RenderCommand = undefined;
    var render_batches: [2]canvas.RenderBatch = undefined;
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
    }, frame_storage);
    try std.testing.expect(first_frame.full_repaint);

    const resized_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 2,
        .surface_size = geometry.SizeF.init(640, 360),
    }, frame_storage);
    try std.testing.expect(resized_frame.full_repaint);
    try std.testing.expect(resized_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), resized_frame.render_plan.commandCount());
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 640, 360), resized_frame.dirty_bounds.?);
}

test "runtime next canvas frame retains renderer cache families" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-render-caches", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 96, 48),
    });

    const path_elements = [_]canvas.PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(4, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(24, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(14, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const commands = [_]canvas.CanvasCommand{
        .{ .fill_path = .{
            .id = 1,
            .elements = &path_elements,
            .fill = .{ .color = canvas.Color.rgb8(14, 165, 233) },
        } },
        .{ .draw_image = .{
            .id = 2,
            .image_id = 42,
            .dst = geometry.RectF.init(32, 4, 18, 18),
        } },
        .{ .shadow = .{
            .id = 3,
            .rect = geometry.RectF.init(58, 8, 20, 14),
            .radius = canvas.Radius.all(5),
            .blur = 8,
            .color = canvas.Color.rgba8(15, 23, 42, 80),
        } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    const overrides = [_]canvas.CanvasRenderOverride{.{
        .id = 1,
        .opacity = 0.5,
    }};
    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 1,
        .surface_size = geometry.SizeF.init(96, 48),
        .render_overrides = &overrides,
    }, canvasFrameScratchStorage(&harness.runtime));
    const first_gpu_packet_summary = first_frame.gpuPacketSummary();
    try std.testing.expect(first_frame.full_repaint);
    try std.testing.expectEqual(@as(usize, 1), first_frame.path_geometry_plan.geometryCount());
    try std.testing.expect(first_frame.path_geometry_plan.vertexCount() > 0);
    try std.testing.expect(first_frame.path_geometry_plan.indexCount() > 0);
    try std.testing.expectEqual(@as(usize, 1), first_frame.path_geometry_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.image_plan.imageCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.image_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.layer_plan.layerCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.layer_plan.opacityLayerCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.layer_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.visual_effect_plan.effectCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.visual_effect_plan.shadowCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.visual_effect_cache_plan.uploadCount());

    const first_info = runtimeViewInfo(harness.runtime.views[0]);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_path_geometry_count);
    try std.testing.expect(first_info.canvas_frame_path_geometry_vertex_count > 0);
    try std.testing.expect(first_info.canvas_frame_path_geometry_index_count > 0);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_path_geometry_upload_count);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_image_count);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_image_upload_count);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_layer_count);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_layer_upload_count);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_visual_effect_count);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_visual_effect_upload_count);
    try std.testing.expectEqual(first_gpu_packet_summary.command_count, first_info.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(first_gpu_packet_summary.cache_action_count, first_info.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(first_gpu_packet_summary.cached_resource_command_count, first_info.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), first_info.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(first_info.canvas_frame_gpu_packet_representable);
    try std.testing.expect(first_info.canvas_frame_profile_work_units > 0);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.high, first_info.canvas_frame_profile_risk);
    try std.testing.expectEqual(@as(f32, 4608), first_info.canvas_frame_profile_surface_area);
    try std.testing.expectEqual(@as(f32, 4608), first_info.canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(@as(f32, 1), first_info.canvas_frame_profile_dirty_ratio);

    const first_gpu_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(usize, 1), first_gpu_frame.canvas_frame_path_geometry_count);
    try std.testing.expectEqual(@as(usize, 1), first_gpu_frame.canvas_frame_image_count);
    try std.testing.expectEqual(@as(usize, 1), first_gpu_frame.canvas_frame_layer_count);
    try std.testing.expectEqual(@as(usize, 1), first_gpu_frame.canvas_frame_visual_effect_count);
    try std.testing.expectEqual(first_gpu_packet_summary.command_count, first_gpu_frame.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(first_gpu_packet_summary.cache_action_count, first_gpu_frame.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(first_gpu_packet_summary.cached_resource_command_count, first_gpu_frame.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), first_gpu_frame.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(first_gpu_frame.canvas_frame_gpu_packet_representable);
    try std.testing.expect(first_gpu_frame.canvas_frame_profile_work_units > 0);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.high, first_gpu_frame.canvas_frame_profile_risk);
    try std.testing.expectEqual(@as(f32, 4608), first_gpu_frame.canvas_frame_profile_surface_area);
    try std.testing.expectEqual(@as(f32, 4608), first_gpu_frame.canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(@as(f32, 1), first_gpu_frame.canvas_frame_profile_dirty_ratio);

    var view_json_buffer: [8192]u8 = undefined;
    const view_json = try writeViewJson(first_info, &view_json_buffer);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFramePathGeometryCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameImageCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameLayerCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameVisualEffectCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketCommandCount\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketCacheActionCount\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketCachedResourceCommandCount\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketUnsupportedCommandCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketRepresentable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileWorkUnits\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileRisk\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileSurfaceArea\":4608") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileDirtyArea\":4608") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileDirtyRatio\":1") != null);

    const retained_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 2,
        .surface_size = geometry.SizeF.init(96, 48),
        .render_overrides = &overrides,
    }, canvasFrameScratchStorage(&harness.runtime));
    try std.testing.expect(!retained_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), retained_frame.path_geometry_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), retained_frame.path_geometry_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), retained_frame.image_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), retained_frame.image_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), retained_frame.layer_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), retained_frame.layer_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), retained_frame.visual_effect_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), retained_frame.visual_effect_cache_plan.retainCount());

    const retained_info = runtimeViewInfo(harness.runtime.views[0]);
    try std.testing.expectEqual(@as(usize, 1), retained_info.canvas_frame_path_geometry_retain_count);
    try std.testing.expectEqual(@as(usize, 1), retained_info.canvas_frame_image_retain_count);
    try std.testing.expectEqual(@as(usize, 1), retained_info.canvas_frame_layer_retain_count);
    try std.testing.expectEqual(@as(usize, 1), retained_info.canvas_frame_visual_effect_retain_count);
    try std.testing.expectEqual(@as(usize, 0), retained_info.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(@as(usize, 0), retained_info.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(@as(usize, 0), retained_info.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), retained_info.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(retained_info.canvas_frame_gpu_packet_representable);
    try std.testing.expectEqual(@as(usize, 0), retained_info.canvas_frame_profile_work_units);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.idle, retained_info.canvas_frame_profile_risk);
}

test "runtime GPU surface frame event exposes renderer cache family counters" {
    const TestApp = struct {
        frame_count: u32 = 0,
        last_path_geometry_count: usize = 0,
        last_path_geometry_upload_count: usize = 0,
        last_image_count: usize = 0,
        last_image_upload_count: usize = 0,
        last_layer_count: usize = 0,
        last_layer_upload_count: usize = 0,
        last_visual_effect_count: usize = 0,
        last_visual_effect_upload_count: usize = 0,
        last_gpu_packet_command_count: usize = 0,
        last_gpu_packet_cache_action_count: usize = 0,
        last_gpu_packet_cached_resource_command_count: usize = 0,
        last_gpu_packet_unsupported_command_count: usize = 0,
        last_gpu_packet_representable: bool = false,

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .gpu_surface_frame => |frame_event| {
                    self.frame_count += 1;
                    self.last_path_geometry_count = frame_event.canvas_frame_path_geometry_count;
                    self.last_path_geometry_upload_count = frame_event.canvas_frame_path_geometry_upload_count;
                    self.last_image_count = frame_event.canvas_frame_image_count;
                    self.last_image_upload_count = frame_event.canvas_frame_image_upload_count;
                    self.last_layer_count = frame_event.canvas_frame_layer_count;
                    self.last_layer_upload_count = frame_event.canvas_frame_layer_upload_count;
                    self.last_visual_effect_count = frame_event.canvas_frame_visual_effect_count;
                    self.last_visual_effect_upload_count = frame_event.canvas_frame_visual_effect_upload_count;
                    self.last_gpu_packet_command_count = frame_event.canvas_frame_gpu_packet_command_count;
                    self.last_gpu_packet_cache_action_count = frame_event.canvas_frame_gpu_packet_cache_action_count;
                    self.last_gpu_packet_cached_resource_command_count = frame_event.canvas_frame_gpu_packet_cached_resource_command_count;
                    self.last_gpu_packet_unsupported_command_count = frame_event.canvas_frame_gpu_packet_unsupported_command_count;
                    self.last_gpu_packet_representable = frame_event.canvas_frame_gpu_packet_representable;
                },
                else => {},
            }
        }

        fn app(self: *@This()) App {
            return .{
                .context = self,
                .name = "gpu-canvas-frame-event-render-caches",
                .source = platform.WebViewSource.html("<h1>Hello</h1>"),
                .event_fn = event,
            };
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
        .frame = geometry.RectF.init(0, 0, 96, 48),
    });

    const path_elements = [_]canvas.PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(4, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(24, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(14, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const commands = [_]canvas.CanvasCommand{
        .{ .fill_path = .{
            .id = 1,
            .elements = &path_elements,
            .fill = .{ .color = canvas.Color.rgb8(14, 165, 233) },
        } },
        .{ .draw_image = .{
            .id = 2,
            .image_id = 42,
            .dst = geometry.RectF.init(32, 4, 18, 18),
        } },
        .{ .shadow = .{
            .id = 3,
            .rect = geometry.RectF.init(58, 8, 20, 14),
            .radius = canvas.Radius.all(5),
            .blur = 8,
            .color = canvas.Color.rgba8(15, 23, 42, 80),
        } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });
    const animations = [_]canvas.CanvasRenderAnimation{.{
        .id = 1,
        .start_ns = 0,
        .duration_ms = 1000,
        .from_opacity = 0.5,
        .to_opacity = 1,
    }};
    _ = try harness.runtime.setCanvasRenderAnimations(1, "canvas", &animations);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(96, 48),
        .scale_factor = 1,
        .frame_index = 7,
        .timestamp_ns = 500_000_000,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.frame_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_path_geometry_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_path_geometry_upload_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_image_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_image_upload_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_layer_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_layer_upload_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_visual_effect_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_visual_effect_upload_count);
    try std.testing.expect(app_state.last_gpu_packet_command_count > 0);
    try std.testing.expect(app_state.last_gpu_packet_cache_action_count > 0);
    try std.testing.expect(app_state.last_gpu_packet_cached_resource_command_count > 0);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_gpu_packet_unsupported_command_count);
    try std.testing.expect(app_state.last_gpu_packet_representable);

    const frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_path_geometry_count);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_image_count);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_layer_count);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_visual_effect_count);
    try std.testing.expectEqual(app_state.last_gpu_packet_command_count, frame.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(app_state.last_gpu_packet_cache_action_count, frame.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(app_state.last_gpu_packet_cached_resource_command_count, frame.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(frame.canvas_frame_gpu_packet_representable);
}
