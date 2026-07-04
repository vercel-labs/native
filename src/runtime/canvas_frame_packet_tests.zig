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

test "runtime next canvas GPU packet returns backend handoff commands" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-packet", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 128, 64),
    });

    const stops = [_]canvas.GradientStop{
        .{ .offset = 0, .color = canvas.Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = canvas.Color.rgb8(37, 99, 235) },
    };
    const commands = [_]canvas.CanvasCommand{
        .{ .fill_rect = .{
            .id = 10,
            .rect = geometry.RectF.init(0, 0, 64, 64),
            .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
        } },
        .{ .fill_rounded_rect = .{
            .id = 11,
            .rect = geometry.RectF.init(72, 8, 40, 24),
            .radius = canvas.Radius.all(8),
            .fill = .{ .linear_gradient = .{
                .start = geometry.PointF.init(72, 8),
                .end = geometry.PointF.init(112, 32),
                .stops = &stops,
            } },
        } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    const packet = try harness.runtime.nextCanvasGpuPacket(1, "canvas", .{
        .frame_index = 3,
        .timestamp_ns = 9_000,
        .surface_size = geometry.SizeF.init(128, 64),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands);

    try std.testing.expect(packet.requiresRender());
    try std.testing.expect(packet.fullyRepresentable());
    try std.testing.expectEqual(@as(u64, 3), packet.frame_index);
    try std.testing.expectEqual(@as(u64, 9_000), packet.timestamp_ns);
    try std.testing.expectEqual(canvas.CanvasRenderPassLoadAction.clear, packet.load_action);
    try std.testing.expectEqualDeep(geometry.SizeF.init(128, 64), packet.surface_size);
    try std.testing.expectEqual(@as(f32, 2), packet.scale);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 128, 64), packet.scissor.?);
    try std.testing.expectEqual(@as(usize, 2), packet.commandCount());
    try std.testing.expectEqual(@as(usize, 1), packet.cachedResourceCommandCount());
    try std.testing.expectEqual(canvas.CanvasGpuCommandKind.fill_rect_solid, packet.commands[0].kind);
    try std.testing.expectEqual(@as(?canvas.RenderPipelineKind, .solid), packet.commands[0].pipeline);
    try std.testing.expectEqual(@as(?canvas.ObjectId, 10), packet.commands[0].id);
    try std.testing.expectEqual(canvas.CanvasGpuCommandKind.fill_rounded_rect_gradient, packet.commands[1].kind);
    try std.testing.expectEqual(@as(?canvas.RenderPipelineKind, .linear_gradient), packet.commands[1].pipeline);
    try std.testing.expect(packet.commands[1].uses_resource);

    const frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(packet.commandCount(), frame.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(packet.cacheActionCount(), frame.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(packet.cachedResourceCommandCount(), frame.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(frame.canvas_frame_gpu_packet_representable);

    var clean_gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    const clean_packet = try harness.runtime.nextCanvasGpuPacket(1, "canvas", .{
        .frame_index = 4,
        .timestamp_ns = 10_000,
        .surface_size = geometry.SizeF.init(128, 64),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), &clean_gpu_commands);
    try std.testing.expect(!clean_packet.requiresRender());
    try std.testing.expect(clean_packet.fullyRepresentable());
    try std.testing.expectEqual(@as(u64, 4), clean_packet.frame_index);
    try std.testing.expectEqual(canvas.CanvasRenderPassLoadAction.skip, clean_packet.load_action);
    try std.testing.expectEqual(@as(usize, 0), clean_packet.commandCount());
}

test "runtime presents next canvas GPU packet" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-packet-present", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 41,
        .rect = geometry.RectF.init(8, 6, 32, 20),
        .fill = .{ .color = canvas.Color.rgb8(37, 99, 235) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    // Nothing has painted yet: the present path is unstamped.
    try std.testing.expectEqual(platform.GpuPresentPath.none, harness.runtime.views[0].gpu_present_path);

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    const packet = try harness.runtime.presentNextCanvasGpuPacket(1, "canvas", .{
        .frame_index = 12,
        .timestamp_ns = 44_000,
        .surface_size = geometry.SizeF.init(96, 48),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), canvas.Color.rgb8(247, 249, 252), &gpu_commands, &packet_json_buffer);

    try std.testing.expect(packet.requiresRender());
    // The successful packet present stamped the path proof.
    try std.testing.expectEqual(platform.GpuPresentPath.packet, harness.runtime.views[0].gpu_present_path);
    try std.testing.expectEqual(@as(usize, 1), packet.commandCount());
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqualStrings("canvas", harness.null_platform.gpu_surface_packet_present_label_storage[0..harness.null_platform.gpu_surface_packet_present_label_len]);
    try std.testing.expectEqual(@as(u64, 12), harness.null_platform.gpu_surface_packet_present_frame_index);
    try std.testing.expectEqual(@as(u64, 44_000), harness.null_platform.gpu_surface_packet_present_timestamp_ns);
    try std.testing.expectEqualDeep(geometry.SizeF.init(96, 48), harness.null_platform.gpu_surface_packet_present_surface_size);
    try std.testing.expectEqual(@as(f32, 2), harness.null_platform.gpu_surface_packet_present_scale_factor);
    try std.testing.expectEqualDeep([4]u8{ 247, 249, 252, 255 }, harness.null_platform.gpu_surface_packet_present_clear_color_rgba8);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_requires_render);
    try std.testing.expectEqual(packet.commandCount(), harness.null_platform.gpu_surface_packet_present_command_count);
    try std.testing.expectEqual(packet.cacheActionCount(), harness.null_platform.gpu_surface_packet_present_cache_action_count);
    try std.testing.expectEqual(packet.cachedResourceCommandCount(), harness.null_platform.gpu_surface_packet_present_cached_resource_command_count);
    try std.testing.expectEqual(packet.unsupported_command_count, harness.null_platform.gpu_surface_packet_present_unsupported_command_count);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_representable);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_json_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, packet_json_buffer[0..harness.null_platform.gpu_surface_packet_present_json_len], "\"commands\":[") != null);

    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
    try std.testing.expect(!presented_frame.canvas_frame_full_repaint);
    try std.testing.expect(presented_frame.canvas_frame_dirty_bounds == null);
}

test "widget-authored transform and opacity survive into the presented packet JSON" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-packet-transform", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    // Author the transform/opacity through the Ui builder so the packet
    // carries the same channel a view function feeds: builder options ->
    // widget -> push_opacity/transform display list wrap -> per-command
    // packet state.
    const SlideMsg = union(enum) { none };
    const SlideUi = canvas.Ui(SlideMsg);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ui = SlideUi.init(arena_state.allocator());
    const tree = try ui.finalize(ui.el(.panel, .{
        .frame = geometry.RectF.init(8, 6, 48, 24),
        .transform = canvas.Affine.translate(8, 4),
        .opacity = 0.5,
    }, .{}));

    var widget_commands: [8]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&widget_commands);
    try canvas.emitWidgetTree(&builder, tree.root, .{});
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", builder.displayList());

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    const packet = try harness.runtime.presentNextCanvasGpuPacket(1, "canvas", .{
        .frame_index = 5,
        .timestamp_ns = 21_000,
        .surface_size = geometry.SizeF.init(96, 48),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), canvas.Color.rgb8(247, 249, 252), &gpu_commands, &packet_json_buffer);

    try std.testing.expect(packet.requiresRender());
    try std.testing.expect(packet.fullyRepresentable());
    try std.testing.expect(packet.commandCount() > 0);
    try std.testing.expectEqual(@as(f32, 0.5), packet.commands[0].opacity);
    try std.testing.expectEqualDeep(canvas.Affine.translate(8, 4), packet.commands[0].transform);

    const packet_json = packet_json_buffer[0..harness.null_platform.gpu_surface_packet_present_json_len];
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"opacity\":0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"transform\":[1,0,0,1,8,4]") != null);
}

test "packet text carries engine line breaks so tight single-line boxes never re-wrap" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-packet-text-lines", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    // A text widget whose box is exactly as wide as the engine measured
    // the text (the tight intrinsic case that used to re-wrap host-side):
    // the packet
    // must carry the engine's single unbroken line so the host draws it
    // verbatim instead of re-wrapping with its own measurement.
    const label = "Songs";
    const body_size: f32 = 14; // default TypographyTokens.body_size
    const label_width = canvas.estimateTextWidthForFont(canvas.default_sans_font_id, label, body_size);
    const TextMsg = union(enum) { none };
    const TextUi = canvas.Ui(TextMsg);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ui = TextUi.init(arena_state.allocator());
    const tree = try ui.finalize(ui.text(.{
        .frame = geometry.RectF.init(4, 4, label_width, 20),
    }, label));

    var widget_commands: [8]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&widget_commands);
    try canvas.emitWidgetTree(&builder, tree.root, .{});
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", builder.displayList());

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    const packet = try harness.runtime.presentNextCanvasGpuPacket(1, "canvas", .{
        .frame_index = 5,
        .timestamp_ns = 21_000,
        .surface_size = geometry.SizeF.init(96, 48),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), canvas.Color.rgb8(247, 249, 252), &gpu_commands, &packet_json_buffer);

    try std.testing.expect(packet.requiresRender());
    try std.testing.expect(packet.fullyRepresentable());

    const packet_json = packet_json_buffer[0..harness.null_platform.gpu_surface_packet_present_json_len];
    // The draw_text command ships explicit engine lines next to its layout
    // options...
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"lines\":[{") != null);
    // ...and the tight box stays one unbroken line ("Songs" never splits
    // into "Song" + "s").
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"text\":\"Songs\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"text\":\"Song\"") == null);
}

test "runtime presents canvas GPU packet with separate presentation scale" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-packet-presentation-scale", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 41,
        .rect = geometry.RectF.init(8, 6, 32, 20),
        .fill = .{ .color = canvas.Color.rgb8(37, 99, 235) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    const packet = try harness.runtime.presentNextCanvasGpuPacketWithScale(1, "canvas", .{
        .frame_index = 12,
        .timestamp_ns = 44_000,
        .surface_size = geometry.SizeF.init(96, 48),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), canvas.Color.rgb8(247, 249, 252), &gpu_commands, &packet_json_buffer, @as(f32, 1));

    try std.testing.expect(packet.requiresRender());
    try std.testing.expectEqual(@as(f32, 1), packet.scale);
    try std.testing.expectEqual(@as(f32, 1), harness.null_platform.gpu_surface_packet_present_scale_factor);
    try std.testing.expectEqual(@as(f32, 2), harness.runtime.views[0].presented_canvas_scale);
    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
}

test "runtime direct canvas GPU packet reports unsupported when JSON buffer is too small" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-packet-direct-buffer", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 41,
        .rect = geometry.RectF.init(8, 6, 32, 20),
        .fill = .{ .color = canvas.Color.rgb8(37, 99, 235) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [32]u8 = undefined;
    try std.testing.expectError(error.UnsupportedService, harness.runtime.presentNextCanvasGpuPacket(1, "canvas", .{
        .frame_index = 13,
        .timestamp_ns = 45_000,
        .surface_size = geometry.SizeF.init(96, 48),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), canvas.Color.rgb8(247, 249, 252), &gpu_commands, &packet_json_buffer));
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_packet_present_count);
}

test "runtime presents next canvas frame through packet presenter when available" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-auto-packet", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(4, 4, 24, 18),
        .fill = .{ .color = canvas.Color.rgb8(37, 99, 235) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    var pixels: [96 * 48 * 4]u8 = undefined;
    var scratch: [96 * 48 * 4]u8 = undefined;
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 21,
        .timestamp_ns = 88_000,
        .surface_size = geometry.SizeF.init(96, 48),
        .scale = 1,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, &packet_json_buffer, &pixels, &scratch, canvas.Color.rgb8(20, 24, 32), null);

    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, result.mode);
    try std.testing.expect(result.frame.requiresRender());
    try std.testing.expect(result.packet_representable);
    try std.testing.expectEqual(@as(usize, 1), result.packet_command_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqualDeep([4]u8{ 20, 24, 32, 255 }, harness.null_platform.gpu_surface_packet_present_clear_color_rgba8);
    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
}

test "runtime auto-present packet honors presentation scale without invalidating retained frame" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-auto-packet-presentation-scale", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(4, 4, 24, 18),
        .fill = .{ .color = canvas.Color.rgb8(37, 99, 235) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    var pixels: [96 * 48 * 4]u8 = undefined;
    var scratch: [96 * 48 * 4]u8 = undefined;
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 21,
        .timestamp_ns = 88_000,
        .surface_size = geometry.SizeF.init(96, 48),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, &packet_json_buffer, &pixels, &scratch, canvas.Color.rgb8(20, 24, 32), @as(f32, 1));

    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, result.mode);
    try std.testing.expectEqual(@as(f32, 2), result.frame.scale);
    try std.testing.expectEqual(@as(f32, 1), harness.null_platform.gpu_surface_packet_present_scale_factor);
    try std.testing.expectEqual(@as(f32, 2), harness.runtime.views[0].presented_canvas_scale);
    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
}

test "runtime falls back to pixels when packet JSON buffer is too small" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-packet-buffer-fallback", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .fill = .{ .color = canvas.Color.rgb8(37, 99, 235) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [32]u8 = undefined;
    var pixels: [4 * 4 * 4]u8 = undefined;
    var scratch: [4 * 4 * 4]u8 = undefined;
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 22,
        .timestamp_ns = 89_000,
        .surface_size = geometry.SizeF.init(4, 4),
        .scale = 1,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, &packet_json_buffer, &pixels, &scratch, canvas.Color.rgb8(0, 0, 0), null);

    try std.testing.expectEqual(CanvasPresentationMode.pixels, result.mode);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_present_count);
    // The FAILED packet attempt never stamped `.packet`: only the pixel
    // present that actually painted did.
    try std.testing.expectEqual(platform.GpuPresentPath.pixels, harness.runtime.views[0].gpu_present_path);
}

test "runtime falls back to pixel presentation when packet presenter is unavailable" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-auto-pixels", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_packets = false;
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

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    var pixels: [4 * 4 * 4]u8 = undefined;
    var scratch: [4 * 4 * 4]u8 = undefined;
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 22,
        .timestamp_ns = 89_000,
        .surface_size = geometry.SizeF.init(4, 4),
        .scale = 1,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, &packet_json_buffer, &pixels, &scratch, canvas.Color.rgb8(0, 0, 0), null);

    try std.testing.expectEqual(CanvasPresentationMode.pixels, result.mode);
    try std.testing.expect(result.frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_present_count);
    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
    // Snapshot-visible proof that the pixel path painted.
    try std.testing.expectEqual(platform.GpuPresentPath.pixels, harness.runtime.views[0].gpu_present_path);
    try std.testing.expectEqual(platform.GpuPresentPath.pixels, harness.runtime.views[0].info().gpu_present_path);
}

test "runtime pixel fallback honors presentation scale without invalidating retained frame" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-auto-pixels-presentation-scale", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_packets = false;
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

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    var pixels: [4 * 4 * 4]u8 = undefined;
    var scratch: [4 * 4 * 4]u8 = undefined;
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 22,
        .timestamp_ns = 89_000,
        .surface_size = geometry.SizeF.init(4, 4),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, &packet_json_buffer, &pixels, &scratch, canvas.Color.rgb8(0, 0, 0), @as(f32, 1));

    try std.testing.expectEqual(CanvasPresentationMode.pixels, result.mode);
    try std.testing.expectEqual(@as(f32, 2), result.frame.scale);
    try std.testing.expectEqual(@as(f32, 1), harness.null_platform.gpu_surface_present_scale_factor);
    try std.testing.expectEqual(@as(f32, 2), harness.runtime.views[0].presented_canvas_scale);
    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
}

test "runtime keeps frames with registered images on the packet path" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-image-packet", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 256, 160),
    });

    // A 128px avatar: 64 KiB of RGBA. Serialized as JSON byte arrays this
    // used to blow the 128 KiB packet JSON bound and evict the WHOLE
    // frame to the software pixel path (block glyphs live); as an id +
    // fingerprint reference over the binary upload side-channel it stays
    // on the packet path.
    const avatar_side: usize = 128;
    const avatar_bytes = avatar_side * avatar_side * 4;
    const avatar = try std.testing.allocator.alloc(u8, avatar_bytes);
    defer std.testing.allocator.free(avatar);
    var offset: usize = 0;
    while (offset < avatar.len) : (offset += 4) {
        avatar[offset] = 200;
        avatar[offset + 1] = 64;
        avatar[offset + 2] = 32;
        avatar[offset + 3] = 255;
    }
    try harness.runtime.registerCanvasImage(42, avatar_side, avatar_side, avatar);

    const commands = [_]canvas.CanvasCommand{
        .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 256, 160),
            .fill = .{ .color = canvas.Color.rgb8(20, 24, 32) },
        } },
        .{ .draw_image = .{
            .id = 2,
            .image_id = 42,
            .dst = geometry.RectF.init(8, 8, 32, 32),
        } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    const packet_json_buffer = try std.testing.allocator.alloc(u8, platform.max_gpu_surface_packet_json_bytes);
    defer std.testing.allocator.free(packet_json_buffer);
    const pixels = try std.testing.allocator.alloc(u8, 256 * 160 * 4);
    defer std.testing.allocator.free(pixels);
    const scratch = try std.testing.allocator.alloc(u8, 256 * 160 * 4);
    defer std.testing.allocator.free(scratch);
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 30,
        .timestamp_ns = 91_000,
        .surface_size = geometry.SizeF.init(256, 160),
        .scale = 1,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, packet_json_buffer, pixels, scratch, canvas.Color.rgb8(0, 0, 0), null);

    // The frame presented as a packet — never the pixel fallback.
    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, result.mode);
    try std.testing.expect(result.packet_representable);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_present_count);

    // The packet JSON stayed far below the transport bound and carries no
    // pixel payload — only the id + fingerprint reference.
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_json_len <= platform.max_gpu_surface_packet_json_bytes);
    const presented_json = packet_json_buffer[0..harness.null_platform.gpu_surface_packet_present_json_len];
    try std.testing.expect(std.mem.indexOf(u8, presented_json, "\"pixels\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, presented_json, "\"imageId\":42") != null);

    // The pixel bytes rode the binary side-channel instead.
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_image_upload_count);
    try std.testing.expectEqual(@as(u64, 42), harness.null_platform.gpu_surface_image_upload_id);
    try std.testing.expectEqual(avatar_side, harness.null_platform.gpu_surface_image_upload_width);
    try std.testing.expectEqual(avatar_side, harness.null_platform.gpu_surface_image_upload_height);
    try std.testing.expectEqual(avatar_bytes, harness.null_platform.gpu_surface_image_upload_byte_len);
    try std.testing.expectEqualDeep([4]u8{ 200, 64, 32, 255 }, harness.null_platform.gpuSurfaceImage(42).?.sample_rgba);

    // A clean second frame retains the image (no re-upload) and skips.
    const second = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 31,
        .timestamp_ns = 92_000,
        .surface_size = geometry.SizeF.init(256, 160),
        .scale = 1,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, packet_json_buffer, pixels, scratch, canvas.Color.rgb8(0, 0, 0), null);
    try std.testing.expectEqual(CanvasPresentationMode.skipped, second.mode);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_image_upload_count);
    // An idle skip keeps the last painted path: still `.packet`.
    try std.testing.expectEqual(platform.GpuPresentPath.packet, harness.runtime.views[0].gpu_present_path);
}

test "runtime re-registration and unregister drive the image upload side-channel" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-image-lifecycle", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 8, 8),
    });

    const commands = [_]canvas.CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 9,
        .dst = geometry.RectF.init(0, 0, 4, 4),
        .sampling = .nearest,
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    var pixels: [8 * 8 * 4]u8 = undefined;
    var scratch: [8 * 8 * 4]u8 = undefined;

    const present = struct {
        fn frame(h: anytype, gpu: []canvas.CanvasGpuCommand, json_buffer: []u8, px: []u8, sc: []u8, frame_index: u64) !CanvasPresentationResult {
            return h.runtime.presentNextCanvasFrame(1, "canvas", .{
                .frame_index = frame_index,
                .timestamp_ns = frame_index * 1_000,
                .surface_size = geometry.SizeF.init(8, 8),
                .scale = 1,
            }, canvasFrameScratchStorage(&h.runtime), gpu, json_buffer, px, sc, canvas.Color.rgb8(0, 0, 0), null);
        }
    };

    // Frame before registration: the draw references an absent id — the
    // frame still presents as a packet (absent images skip, they never
    // fail presentation) and nothing is uploaded.
    const before = try present.frame(harness, &gpu_commands, &packet_json_buffer, &pixels, &scratch, 40);
    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, before.mode);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_image_upload_count);

    // Register: the next frame's upload action pushes the bytes.
    const red = [_]u8{ 255, 0, 0, 255 };
    try harness.runtime.registerCanvasImage(9, 1, 1, &red);
    _ = try present.frame(harness, &gpu_commands, &packet_json_buffer, &pixels, &scratch, 41);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_image_upload_count);
    try std.testing.expectEqualDeep([4]u8{ 255, 0, 0, 255 }, harness.null_platform.gpuSurfaceImage(9).?.sample_rgba);

    // Re-register with new pixels (the LRU-churn shape): the content
    // fingerprint changes, so the next frame re-uploads.
    const blue = [_]u8{ 0, 0, 255, 255 };
    try harness.runtime.registerCanvasImage(9, 1, 1, &blue);
    _ = try present.frame(harness, &gpu_commands, &packet_json_buffer, &pixels, &scratch, 42);
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.gpu_surface_image_upload_count);
    try std.testing.expectEqualDeep([4]u8{ 0, 0, 255, 255 }, harness.null_platform.gpuSurfaceImage(9).?.sample_rgba);

    // Unregister drops the platform-side entry; the next frame (stale
    // tree still referencing the id) stays on the packet path with the
    // absent-image skip and uploads nothing new.
    try std.testing.expect(harness.runtime.unregisterCanvasImage(9));
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_image_remove_count);
    try std.testing.expect(harness.null_platform.gpuSurfaceImage(9) == null);
    const after = try present.frame(harness, &gpu_commands, &packet_json_buffer, &pixels, &scratch, 43);
    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, after.mode);
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.gpu_surface_image_upload_count);

    // Unregistering an absent id never reaches the platform.
    try std.testing.expect(!harness.runtime.unregisterCanvasImage(9));
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_image_remove_count);
}

test "runtime falls back to pixels when the platform lacks the image upload seam" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-image-no-seam", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_image_uploads = false;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 2, 2),
    });

    const commands = [_]canvas.CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 5,
        .dst = geometry.RectF.init(0, 0, 1, 1),
        .sampling = .nearest,
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });
    const green = [_]u8{ 0, 200, 0, 255 };
    try harness.runtime.registerCanvasImage(5, 1, 1, &green);

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    var pixels: [2 * 2 * 4]u8 = undefined;
    var scratch: [2 * 2 * 4]u8 = undefined;
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 50,
        .timestamp_ns = 95_000,
        .surface_size = geometry.SizeF.init(2, 2),
        .scale = 1,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, &packet_json_buffer, &pixels, &scratch, canvas.Color.rgb8(0, 0, 0), null);

    // A packet host that cannot receive the pixels must not present a
    // frame that references them: the software path renders the image.
    try std.testing.expectEqual(CanvasPresentationMode.pixels, result.mode);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqualDeep([4]u8{ 0, 200, 0, 255 }, harness.null_platform.gpu_surface_present_sample_rgba);
}

test "runtime pixel fallback renders provided canvas image resources" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-image-pixels", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_packets = false;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 2, 2),
    });

    const commands = [_]canvas.CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(0, 0, 1, 1),
        .sampling = .nearest,
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    const image_pixels = [_]u8{ 11, 22, 33, 255 };
    const image_resources = [_]canvas.ReferenceImage{.{
        .id = 42,
        .width = 1,
        .height = 1,
        .pixels = &image_pixels,
    }};
    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    var pixels: [2 * 2 * 4]u8 = undefined;
    var scratch: [2 * 2 * 4]u8 = undefined;
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 23,
        .timestamp_ns = 90_000,
        .surface_size = geometry.SizeF.init(2, 2),
        .scale = 1,
        .image_resources = &image_resources,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, &packet_json_buffer, &pixels, &scratch, canvas.Color.rgb8(0, 0, 0), null);

    try std.testing.expectEqual(CanvasPresentationMode.pixels, result.mode);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqualDeep([4]u8{ 11, 22, 33, 255 }, harness.null_platform.gpu_surface_present_sample_rgba);
    try std.testing.expectEqual(@as(usize, 1), result.frame.image_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), result.frame.image_plan.images[0].width);
    try std.testing.expectEqual(@as(usize, 1), result.frame.image_plan.images[0].height);
    try std.testing.expectEqualSlices(u8, &image_pixels, result.frame.image_plan.images[0].pixels);
}
