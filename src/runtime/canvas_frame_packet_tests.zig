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
    const packet = try harness.runtime.presentNextCanvasGpuPacket(1, "canvas", .{
        .frame_index = 12,
        .timestamp_ns = 44_000,
        .surface_size = geometry.SizeF.init(96, 48),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), canvas.Color.rgb8(247, 249, 252), &gpu_commands, &packet_json_buffer);

    try std.testing.expect(packet.requiresRender());
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

test "runtime presents canvas GPU packet with separate presentation scale" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-packet-presentation-scale", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
}

test "runtime falls back to pixel presentation when packet presenter is unavailable" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-auto-pixels", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
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
}

test "runtime pixel fallback honors presentation scale without invalidating retained frame" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-auto-pixels-presentation-scale", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
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

test "runtime pixel fallback renders provided canvas image resources" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-image-pixels", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
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
