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

test "runtime configures platform keyboard shortcuts" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shortcuts", .source = platform.WebViewSource.html("<h1>Shortcuts</h1>") };
        }
    };

    const shortcuts = [_]platform.Shortcut{
        .{ .id = "command.palette", .key = "p", .modifiers = .{ .primary = true, .shift = true } },
    };
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.shortcuts = &shortcuts;
    var app_state: TestApp = .{};
    try harness.runtime.run(app_state.app());

    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.configuredShortcuts().len);
    try std.testing.expectEqualStrings("command.palette", harness.null_platform.configuredShortcuts()[0].id);
}

test "runtime dispatches app activation lifecycle events" {
    const TestApp = struct {
        events: [4]LifecycleEvent = undefined,
        len: usize = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "activation", .source = platform.WebViewSource.html("<h1>Activation</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .lifecycle => |lifecycle| {
                    self.events[self.len] = lifecycle;
                    self.len += 1;
                },
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);
    const event_count_before = harness.null_platform.windowEventCount();
    try harness.runtime.dispatchPlatformEvent(app, .app_activated);
    try std.testing.expectEqual(event_count_before + 1, harness.null_platform.windowEventCount());
    try std.testing.expectEqual(@as(platform.WindowId, 1), harness.null_platform.lastWindowEventWindowId());
    try std.testing.expectEqualStrings("app:activate", harness.null_platform.lastWindowEventName());
    try std.testing.expectEqualStrings("{}", harness.null_platform.lastWindowEventDetail());
    try harness.runtime.dispatchPlatformEvent(app, .app_deactivated);
    try std.testing.expectEqual(event_count_before + 2, harness.null_platform.windowEventCount());
    try std.testing.expectEqualStrings("app:deactivate", harness.null_platform.lastWindowEventName());

    try std.testing.expectEqual(@as(usize, 4), app_state.len);
    try std.testing.expectEqual(LifecycleEvent.start, app_state.events[0]);
    try std.testing.expectEqual(LifecycleEvent.frame, app_state.events[1]);
    try std.testing.expectEqual(LifecycleEvent.activate, app_state.events[2]);
    try std.testing.expectEqual(LifecycleEvent.deactivate, app_state.events[3]);
}

test "runtime stores and dispatches appearance preferences" {
    const TestApp = struct {
        appearance_count: u32 = 0,
        last_appearance: platform.Appearance = .{},

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "appearance-preferences", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .appearance_changed => |appearance| {
                    self.appearance_count += 1;
                    self.last_appearance = appearance;
                },
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .appearance_changed = .{ .color_scheme = .dark, .reduce_motion = true, .high_contrast = true } });
    try std.testing.expectEqual(@as(u32, 1), app_state.appearance_count);
    try std.testing.expectEqual(platform.ColorScheme.dark, app_state.last_appearance.color_scheme);
    try std.testing.expect(app_state.last_appearance.reduce_motion);
    try std.testing.expect(app_state.last_appearance.high_contrast);
    try std.testing.expectEqual(platform.ColorScheme.dark, harness.runtime.appearance.color_scheme);
    try std.testing.expect(harness.runtime.appearance.reduce_motion);
    try std.testing.expect(harness.runtime.appearance.high_contrast);
}

test "runtime dispatches GPU surface events" {
    const TestApp = struct {
        frame_count: u32 = 0,
        resize_count: u32 = 0,
        input_count: u32 = 0,
        last_label: []const u8 = "",
        last_input_kind: platform.GpuSurfaceInputKind = .pointer_move,
        last_gpu_backend: platform.GpuSurfaceBackend = .none,
        last_gpu_pixel_format: platform.GpuSurfacePixelFormat = .none,
        last_gpu_present_mode: platform.GpuSurfacePresentMode = .none,
        last_gpu_alpha_mode: platform.GpuSurfaceAlphaMode = .none,
        last_gpu_color_space: platform.GpuSurfaceColorSpace = .none,
        last_gpu_vsync: bool = false,
        last_gpu_status: platform.GpuSurfaceStatus = .unavailable,
        last_frame_interval_ns: u64 = 0,
        last_canvas_revision: u64 = 0,
        last_canvas_command_count: usize = 0,
        last_canvas_frame_requires_render: bool = false,
        last_canvas_frame_full_repaint: bool = false,
        last_canvas_frame_batch_count: usize = 0,
        last_canvas_frame_encoder_command_count: usize = 0,
        last_canvas_frame_encoder_cache_action_count: usize = 0,
        last_canvas_frame_encoder_bind_pipeline_count: usize = 0,
        last_canvas_frame_encoder_draw_batch_count: usize = 0,
        last_canvas_frame_resource_count: usize = 0,
        last_canvas_frame_resource_upload_count: usize = 0,
        last_canvas_frame_resource_retain_count: usize = 0,
        last_canvas_frame_resource_evict_count: usize = 0,
        last_canvas_frame_glyph_atlas_entry_count: usize = 0,
        last_canvas_frame_gpu_packet_command_count: usize = 0,
        last_canvas_frame_gpu_packet_cache_action_count: usize = 0,
        last_canvas_frame_gpu_packet_cached_resource_command_count: usize = 0,
        last_canvas_frame_gpu_packet_unsupported_command_count: usize = 0,
        last_canvas_frame_gpu_packet_representable: bool = false,
        last_canvas_frame_change_count: usize = 0,
        last_canvas_frame_budget_exceeded_count: usize = 0,
        last_canvas_frame_budget_ok: bool = true,
        last_canvas_frame_dirty_bounds: ?geometry.RectF = null,
        last_canvas_frame_profile_work_units: usize = 0,
        last_canvas_frame_profile_risk: platform.CanvasFrameProfileRisk = .idle,
        last_canvas_frame_profile_surface_area: f32 = 0,
        last_canvas_frame_profile_dirty_area: f32 = 0,
        last_canvas_frame_profile_dirty_ratio: f32 = 0,
        last_input_timestamp_ns: u64 = 0,
        last_input_latency_ns: u64 = 0,
        last_input_latency_budget_ns: u64 = 0,
        last_input_latency_budget_exceeded_count: usize = 0,
        last_input_latency_budget_ok: bool = true,
        last_first_frame_latency_ns: u64 = 0,
        last_first_frame_latency_budget_ns: u64 = 0,
        last_first_frame_latency_budget_exceeded_count: usize = 0,
        last_first_frame_latency_budget_ok: bool = true,
        last_widget_revision: u64 = 0,
        last_widget_node_count: usize = 0,
        last_widget_semantics_count: usize = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-events", .source = platform.WebViewSource.html("<h1>GPU</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .gpu_surface_frame => |frame_event| {
                    self.frame_count += 1;
                    self.last_label = frame_event.label;
                    self.last_gpu_backend = frame_event.backend;
                    self.last_gpu_pixel_format = frame_event.pixel_format;
                    self.last_gpu_present_mode = frame_event.present_mode;
                    self.last_gpu_alpha_mode = frame_event.alpha_mode;
                    self.last_gpu_color_space = frame_event.color_space;
                    self.last_gpu_vsync = frame_event.vsync;
                    self.last_gpu_status = frame_event.status;
                    self.last_frame_interval_ns = frame_event.frame_interval_ns;
                    self.last_canvas_revision = frame_event.canvas_revision;
                    self.last_canvas_command_count = frame_event.canvas_command_count;
                    self.last_canvas_frame_requires_render = frame_event.canvas_frame_requires_render;
                    self.last_canvas_frame_full_repaint = frame_event.canvas_frame_full_repaint;
                    self.last_canvas_frame_batch_count = frame_event.canvas_frame_batch_count;
                    self.last_canvas_frame_encoder_command_count = frame_event.canvas_frame_encoder_command_count;
                    self.last_canvas_frame_encoder_cache_action_count = frame_event.canvas_frame_encoder_cache_action_count;
                    self.last_canvas_frame_encoder_bind_pipeline_count = frame_event.canvas_frame_encoder_bind_pipeline_count;
                    self.last_canvas_frame_encoder_draw_batch_count = frame_event.canvas_frame_encoder_draw_batch_count;
                    self.last_canvas_frame_resource_count = frame_event.canvas_frame_resource_count;
                    self.last_canvas_frame_resource_upload_count = frame_event.canvas_frame_resource_upload_count;
                    self.last_canvas_frame_resource_retain_count = frame_event.canvas_frame_resource_retain_count;
                    self.last_canvas_frame_resource_evict_count = frame_event.canvas_frame_resource_evict_count;
                    self.last_canvas_frame_glyph_atlas_entry_count = frame_event.canvas_frame_glyph_atlas_entry_count;
                    self.last_canvas_frame_gpu_packet_command_count = frame_event.canvas_frame_gpu_packet_command_count;
                    self.last_canvas_frame_gpu_packet_cache_action_count = frame_event.canvas_frame_gpu_packet_cache_action_count;
                    self.last_canvas_frame_gpu_packet_cached_resource_command_count = frame_event.canvas_frame_gpu_packet_cached_resource_command_count;
                    self.last_canvas_frame_gpu_packet_unsupported_command_count = frame_event.canvas_frame_gpu_packet_unsupported_command_count;
                    self.last_canvas_frame_gpu_packet_representable = frame_event.canvas_frame_gpu_packet_representable;
                    self.last_canvas_frame_change_count = frame_event.canvas_frame_change_count;
                    self.last_canvas_frame_budget_exceeded_count = frame_event.canvas_frame_budget_exceeded_count;
                    self.last_canvas_frame_budget_ok = frame_event.canvas_frame_budget_ok;
                    self.last_canvas_frame_dirty_bounds = frame_event.canvas_frame_dirty_bounds;
                    self.last_canvas_frame_profile_work_units = frame_event.canvas_frame_profile_work_units;
                    self.last_canvas_frame_profile_risk = frame_event.canvas_frame_profile_risk;
                    self.last_canvas_frame_profile_surface_area = frame_event.canvas_frame_profile_surface_area;
                    self.last_canvas_frame_profile_dirty_area = frame_event.canvas_frame_profile_dirty_area;
                    self.last_canvas_frame_profile_dirty_ratio = frame_event.canvas_frame_profile_dirty_ratio;
                    self.last_input_timestamp_ns = frame_event.input_timestamp_ns;
                    self.last_input_latency_ns = frame_event.input_latency_ns;
                    self.last_input_latency_budget_ns = frame_event.input_latency_budget_ns;
                    self.last_input_latency_budget_exceeded_count = frame_event.input_latency_budget_exceeded_count;
                    self.last_input_latency_budget_ok = frame_event.input_latency_budget_ok;
                    self.last_first_frame_latency_ns = frame_event.first_frame_latency_ns;
                    self.last_first_frame_latency_budget_ns = frame_event.first_frame_latency_budget_ns;
                    self.last_first_frame_latency_budget_exceeded_count = frame_event.first_frame_latency_budget_exceeded_count;
                    self.last_first_frame_latency_budget_ok = frame_event.first_frame_latency_budget_ok;
                    self.last_widget_revision = frame_event.widget_revision;
                    self.last_widget_node_count = frame_event.widget_node_count;
                    self.last_widget_semantics_count = frame_event.widget_semantics_count;
                },
                .gpu_surface_resized => |resize_event| {
                    self.resize_count += 1;
                    self.last_label = resize_event.label;
                },
                .gpu_surface_input => |input_event| {
                    self.input_count += 1;
                    self.last_label = input_event.label;
                    self.last_input_kind = input_event.kind;
                },
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    const created = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 640, 360),
    });
    const initial_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(created.id, initial_frame.surface_id);
    try std.testing.expectEqual(platform.GpuSurfaceBackend.metal, created.gpu_backend);
    try std.testing.expectEqual(platform.GpuSurfacePixelFormat.bgra8_unorm, created.gpu_pixel_format);
    try std.testing.expectEqual(platform.GpuSurfacePresentMode.timer, created.gpu_present_mode);
    try std.testing.expectEqual(platform.GpuSurfaceAlphaMode.@"opaque", created.gpu_alpha_mode);
    try std.testing.expectEqual(platform.GpuSurfaceColorSpace.srgb, created.gpu_color_space);
    try std.testing.expect(created.gpu_vsync);
    try std.testing.expectEqual(platform.GpuSurfaceStatus.ready, created.gpu_status);
    try std.testing.expectEqual(platform.GpuSurfaceBackend.metal, initial_frame.backend);
    try std.testing.expectEqual(platform.GpuSurfacePixelFormat.bgra8_unorm, initial_frame.pixel_format);
    try std.testing.expectEqual(platform.GpuSurfacePresentMode.timer, initial_frame.present_mode);
    try std.testing.expectEqual(platform.GpuSurfaceAlphaMode.@"opaque", initial_frame.alpha_mode);
    try std.testing.expectEqual(platform.GpuSurfaceColorSpace.srgb, initial_frame.color_space);
    try std.testing.expect(initial_frame.vsync);
    try std.testing.expectEqual(platform.GpuSurfaceStatus.ready, initial_frame.status);
    try std.testing.expectEqual(@as(f32, 640), initial_frame.size.width);
    try std.testing.expectEqual(@as(f32, 360), initial_frame.size.height);
    try std.testing.expectEqual(@as(u64, 0), initial_frame.frame_index);
    try std.testing.expectEqual(platform.default_gpu_frame_interval_ns, initial_frame.frame_interval_ns);
    try std.testing.expectEqual(@as(u64, 0), initial_frame.input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 0), initial_frame.input_latency_ns);
    try std.testing.expectEqual(platform.default_gpu_frame_interval_ns, initial_frame.input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), initial_frame.input_latency_budget_exceeded_count);
    try std.testing.expect(initial_frame.input_latency_budget_ok);
    try std.testing.expectEqual(@as(u64, 0), initial_frame.first_frame_latency_ns);
    try std.testing.expectEqual(@as(u64, 150_000_000), initial_frame.first_frame_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), initial_frame.first_frame_latency_budget_exceeded_count);
    try std.testing.expect(initial_frame.first_frame_latency_budget_ok);
    try std.testing.expectEqual(@as(u64, 0), initial_frame.canvas_revision);
    try std.testing.expectEqual(@as(usize, 0), initial_frame.canvas_command_count);
    try std.testing.expectEqual(@as(u64, 0), initial_frame.widget_revision);
    try std.testing.expectEqual(@as(usize, 0), initial_frame.widget_node_count);
    const budgeted = try harness.runtime.setCanvasFrameBudget(1, "canvas", .{ .max_commands = 1 });
    try std.testing.expectEqual(@as(usize, 0), budgeted.canvas_frame_budget_exceeded_count);
    try std.testing.expect(budgeted.canvas_frame_budget_ok);

    var commands: [2]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try builder.fillRect(.{
        .id = 10,
        .rect = geometry.RectF.init(0, 0, 320, 180),
        .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
    });
    try builder.fillRect(.{
        .id = 11,
        .rect = geometry.RectF.init(320, 0, 320, 180),
        .fill = .{ .color = canvas.Color.rgb8(245, 248, 255) },
    });
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", builder.displayList());

    const widgets = [_]canvas.Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(12, 12, 96, 32),
        .text = "Run",
        .semantics = .{ .label = "Run report" },
    }};
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &widgets }, geometry.RectF.init(0, 0, 640, 360), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    harness.runtime.invalidated = false;
    harness.runtime.views[0].gpu_surface_created_timestamp_ns = 20;

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(640, 360),
        .scale_factor = 2,
        .frame_index = 7,
        .timestamp_ns = 42,
        .nonblank = true,
        .sample_color = 0xff336699,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.frame_count);
    try std.testing.expectEqualStrings("canvas", app_state.last_label);
    try std.testing.expectEqual(platform.GpuSurfaceBackend.metal, app_state.last_gpu_backend);
    try std.testing.expectEqual(platform.GpuSurfacePixelFormat.bgra8_unorm, app_state.last_gpu_pixel_format);
    try std.testing.expectEqual(platform.GpuSurfacePresentMode.timer, app_state.last_gpu_present_mode);
    try std.testing.expectEqual(platform.GpuSurfaceAlphaMode.@"opaque", app_state.last_gpu_alpha_mode);
    try std.testing.expectEqual(platform.GpuSurfaceColorSpace.srgb, app_state.last_gpu_color_space);
    try std.testing.expect(app_state.last_gpu_vsync);
    try std.testing.expectEqual(platform.GpuSurfaceStatus.ready, app_state.last_gpu_status);
    try std.testing.expectEqual(platform.default_gpu_frame_interval_ns, app_state.last_frame_interval_ns);
    try std.testing.expectEqual(@as(u64, 1), app_state.last_canvas_revision);
    try std.testing.expectEqual(@as(usize, 2), app_state.last_canvas_command_count);
    try std.testing.expect(app_state.last_canvas_frame_requires_render);
    try std.testing.expect(app_state.last_canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_batch_count);
    try std.testing.expectEqual(@as(usize, 6), app_state.last_canvas_frame_encoder_command_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_encoder_cache_action_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_encoder_bind_pipeline_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_encoder_draw_batch_count);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_resource_count);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_resource_upload_count);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_resource_retain_count);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_resource_evict_count);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_glyph_atlas_entry_count);
    try std.testing.expect(app_state.last_canvas_frame_gpu_packet_command_count > 0);
    try std.testing.expect(app_state.last_canvas_frame_gpu_packet_cache_action_count > 0);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(app_state.last_canvas_frame_gpu_packet_representable);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_change_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_budget_exceeded_count);
    try std.testing.expect(!app_state.last_canvas_frame_budget_ok);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 640, 360), app_state.last_canvas_frame_dirty_bounds.?);
    try std.testing.expect(app_state.last_canvas_frame_profile_work_units > 0);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.high, app_state.last_canvas_frame_profile_risk);
    try std.testing.expectEqual(@as(f32, 230400), app_state.last_canvas_frame_profile_surface_area);
    try std.testing.expectEqual(@as(f32, 230400), app_state.last_canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(@as(f32, 1), app_state.last_canvas_frame_profile_dirty_ratio);
    try std.testing.expectEqual(@as(u64, 1), app_state.last_widget_revision);
    try std.testing.expectEqual(@as(usize, 2), app_state.last_widget_node_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_widget_semantics_count);
    try std.testing.expectEqual(@as(u64, 22), app_state.last_first_frame_latency_ns);
    try std.testing.expectEqual(@as(u64, 150_000_000), app_state.last_first_frame_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_first_frame_latency_budget_exceeded_count);
    try std.testing.expect(app_state.last_first_frame_latency_budget_ok);
    // The first nonblank frame is an observable state transition and must
    // invalidate so automation snapshots republish; steady-state frames do
    // not (covered by "gpu surface nonblank transition invalidates the
    // runtime" below).
    try std.testing.expect(harness.runtime.invalidated);
    const frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(created.id, frame.surface_id);
    try std.testing.expectEqual(@as(platform.WindowId, 1), frame.window_id);
    try std.testing.expectEqualStrings("canvas", frame.label);
    try std.testing.expectEqual(@as(f32, 640), frame.size.width);
    try std.testing.expectEqual(@as(f32, 360), frame.size.height);
    try std.testing.expectEqual(@as(f32, 2), frame.scale_factor);
    try std.testing.expectEqual(platform.GpuSurfaceBackend.metal, frame.backend);
    try std.testing.expectEqual(platform.GpuSurfacePixelFormat.bgra8_unorm, frame.pixel_format);
    try std.testing.expectEqual(platform.GpuSurfacePresentMode.timer, frame.present_mode);
    try std.testing.expectEqual(platform.GpuSurfaceAlphaMode.@"opaque", frame.alpha_mode);
    try std.testing.expectEqual(platform.GpuSurfaceColorSpace.srgb, frame.color_space);
    try std.testing.expect(frame.vsync);
    try std.testing.expectEqual(platform.GpuSurfaceStatus.ready, frame.status);
    try std.testing.expectEqual(@as(u64, 7), frame.frame_index);
    try std.testing.expectEqual(@as(u64, 42), frame.timestamp_ns);
    try std.testing.expectEqual(platform.default_gpu_frame_interval_ns, frame.frame_interval_ns);
    try std.testing.expectEqual(@as(u64, 0), frame.input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 0), frame.input_latency_ns);
    try std.testing.expectEqual(platform.default_gpu_frame_interval_ns, frame.input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), frame.input_latency_budget_exceeded_count);
    try std.testing.expect(frame.input_latency_budget_ok);
    try std.testing.expectEqual(@as(u64, 22), frame.first_frame_latency_ns);
    try std.testing.expectEqual(@as(u64, 150_000_000), frame.first_frame_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), frame.first_frame_latency_budget_exceeded_count);
    try std.testing.expect(frame.first_frame_latency_budget_ok);
    try std.testing.expect(frame.nonblank);
    try std.testing.expectEqual(@as(u32, 0xff336699), frame.sample_color);
    try std.testing.expectEqual(@as(u64, 1), frame.canvas_revision);
    try std.testing.expectEqual(@as(usize, 2), frame.canvas_command_count);
    try std.testing.expect(frame.canvas_frame_requires_render);
    try std.testing.expect(frame.canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_batch_count);
    try std.testing.expectEqual(@as(usize, 6), frame.canvas_frame_encoder_command_count);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_encoder_cache_action_count);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_encoder_bind_pipeline_count);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_encoder_draw_batch_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_resource_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_resource_upload_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_resource_retain_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_resource_evict_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_glyph_atlas_entry_count);
    try std.testing.expectEqual(app_state.last_canvas_frame_gpu_packet_command_count, frame.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(app_state.last_canvas_frame_gpu_packet_cache_action_count, frame.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(frame.canvas_frame_gpu_packet_representable);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_change_count);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_budget_exceeded_count);
    try std.testing.expect(!frame.canvas_frame_budget_ok);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 640, 360), frame.canvas_frame_dirty_bounds.?);
    try std.testing.expect(frame.canvas_frame_profile_work_units > 0);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.high, frame.canvas_frame_profile_risk);
    try std.testing.expectEqual(@as(f32, 230400), frame.canvas_frame_profile_surface_area);
    try std.testing.expectEqual(@as(f32, 230400), frame.canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(@as(f32, 1), frame.canvas_frame_profile_dirty_ratio);
    try std.testing.expectEqual(@as(u64, 1), frame.widget_revision);
    try std.testing.expectEqual(@as(usize, 2), frame.widget_node_count);
    try std.testing.expectEqual(@as(usize, 1), frame.widget_semantics_count);
    var view_json_buffer: [8192]u8 = undefined;
    const view_json = try writeViewJson(runtimeViewInfo(harness.runtime.views[0]), &view_json_buffer);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuWidth\":640") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuHeight\":360") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuScale\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuFrame\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuTimestampNs\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuFrameIntervalNs\":16666667") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuInputTimestampNs\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuInputLatencyNs\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuInputLatencyBudgetNs\":16666667") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuInputLatencyBudgetExceededCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuInputLatencyBudgetOk\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuFirstFrameLatencyNs\":22") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuFirstFrameLatencyBudgetNs\":150000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuFirstFrameLatencyBudgetExceededCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuFirstFrameLatencyBudgetOk\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuNonblank\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuSampleColor\":4281558681") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuBackend\":\"metal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuPixelFormat\":\"bgra8_unorm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuPresentMode\":\"timer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuAlphaMode\":\"opaque\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuColorSpace\":\"srgb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuVsync\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuStatus\":\"ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameRequiresRender\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameFullRepaint\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameBatchCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameEncoderCommandCount\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameEncoderCacheActionCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameEncoderBindPipelineCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameEncoderDrawBatchCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameResourceCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameResourceUploadCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameResourceRetainCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameResourceEvictCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGlyphAtlasEntryCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketCommandCount\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketCacheActionCount\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketCachedResourceCommandCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketUnsupportedCommandCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketRepresentable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameChangeCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameBudgetExceededCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameBudgetOk\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameDirtyBounds\":{\"x\":0,\"y\":0,\"width\":640,\"height\":360}") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileWorkUnits\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileRisk\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileSurfaceArea\":230400") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileDirtyArea\":230400") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileDirtyRatio\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"cursor\":\"arrow\"") != null);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(640, 360),
        .scale_factor = 2,
        .frame_index = 8,
        .timestamp_ns = 43,
        .nonblank = true,
        .sample_color = 0xff336699,
    } });
    try std.testing.expectEqual(@as(u32, 2), app_state.frame_count);
    try std.testing.expect(app_state.last_canvas_frame_requires_render);
    try std.testing.expect(app_state.last_canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_batch_count);
    try std.testing.expectEqual(@as(usize, 6), app_state.last_canvas_frame_encoder_command_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_encoder_cache_action_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_encoder_bind_pipeline_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_encoder_draw_batch_count);
    try std.testing.expect(app_state.last_canvas_frame_gpu_packet_command_count > 0);
    try std.testing.expect(app_state.last_canvas_frame_gpu_packet_cache_action_count > 0);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(app_state.last_canvas_frame_gpu_packet_representable);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_change_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_budget_exceeded_count);
    try std.testing.expect(!app_state.last_canvas_frame_budget_ok);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 640, 360), app_state.last_canvas_frame_dirty_bounds.?);
    try std.testing.expect(app_state.last_canvas_frame_profile_work_units > 0);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.high, app_state.last_canvas_frame_profile_risk);
    try std.testing.expectEqual(@as(f32, 230400), app_state.last_canvas_frame_profile_surface_area);
    try std.testing.expectEqual(@as(f32, 230400), app_state.last_canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(@as(f32, 1), app_state.last_canvas_frame_profile_dirty_ratio);
    const preview_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(u64, 8), preview_frame.frame_index);
    try std.testing.expectEqual(@as(u64, 22), preview_frame.first_frame_latency_ns);
    try std.testing.expect(preview_frame.first_frame_latency_budget_ok);
    try std.testing.expectEqual(platform.GpuSurfaceBackend.metal, preview_frame.backend);
    try std.testing.expectEqual(platform.GpuSurfacePixelFormat.bgra8_unorm, preview_frame.pixel_format);
    try std.testing.expectEqual(platform.GpuSurfacePresentMode.timer, preview_frame.present_mode);
    try std.testing.expectEqual(platform.GpuSurfaceAlphaMode.@"opaque", preview_frame.alpha_mode);
    try std.testing.expectEqual(platform.GpuSurfaceColorSpace.srgb, preview_frame.color_space);
    try std.testing.expect(preview_frame.vsync);
    try std.testing.expectEqual(platform.GpuSurfaceStatus.ready, preview_frame.status);
    try std.testing.expectEqual(platform.default_gpu_frame_interval_ns, preview_frame.frame_interval_ns);
    try std.testing.expect(preview_frame.canvas_frame_requires_render);
    try std.testing.expect(preview_frame.canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(usize, 6), preview_frame.canvas_frame_encoder_command_count);
    try std.testing.expectEqual(@as(usize, 1), preview_frame.canvas_frame_encoder_cache_action_count);
    try std.testing.expectEqual(@as(usize, 1), preview_frame.canvas_frame_encoder_bind_pipeline_count);
    try std.testing.expectEqual(@as(usize, 1), preview_frame.canvas_frame_encoder_draw_batch_count);
    try std.testing.expectEqual(app_state.last_canvas_frame_gpu_packet_command_count, preview_frame.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(app_state.last_canvas_frame_gpu_packet_cache_action_count, preview_frame.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(@as(usize, 0), preview_frame.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), preview_frame.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(preview_frame.canvas_frame_gpu_packet_representable);
    try std.testing.expectEqual(@as(usize, 1), preview_frame.canvas_frame_budget_exceeded_count);
    try std.testing.expect(!preview_frame.canvas_frame_budget_ok);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 640, 360), preview_frame.canvas_frame_dirty_bounds.?);
    try std.testing.expect(preview_frame.canvas_frame_profile_work_units > 0);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.high, preview_frame.canvas_frame_profile_risk);
    try std.testing.expectEqual(@as(f32, 230400), preview_frame.canvas_frame_profile_surface_area);
    try std.testing.expectEqual(@as(f32, 230400), preview_frame.canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(@as(f32, 1), preview_frame.canvas_frame_profile_dirty_ratio);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = "canvas",
        .frame = geometry.RectF.init(0, 0, 800, 450),
        .scale_factor = 2,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.resize_count);
    try std.testing.expect(harness.runtime.invalidated);
    const resized_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(f32, 800), resized_frame.size.width);
    try std.testing.expectEqual(@as(f32, 450), resized_frame.size.height);
    try std.testing.expectEqual(@as(f32, 2), resized_frame.scale_factor);
    try std.testing.expectEqual(platform.GpuSurfaceBackend.metal, resized_frame.backend);
    try std.testing.expectEqual(platform.GpuSurfaceStatus.ready, resized_frame.status);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .timestamp_ns = 50_000_000,
        .x = 12,
        .y = 18,
        .button = 0,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.pointer_down, app_state.last_input_kind);
    try std.testing.expect(harness.runtime.invalidated);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(800, 450),
        .scale_factor = 2,
        .frame_index = 9,
        .timestamp_ns = 70_000_000,
        .frame_interval_ns = 8_333_333,
        .nonblank = true,
        .sample_color = 0xff336699,
    } });
    try std.testing.expectEqual(@as(u32, 3), app_state.frame_count);
    try std.testing.expectEqual(@as(u64, 50_000_000), app_state.last_input_timestamp_ns);
    // The latency stamps at the responding present's completion (or,
    // with no present in this dispatch, at the completion event AFTER
    // the app observed the frame), so the frame event that resolves a
    // pending input carries the PREVIOUS latency; the resolved value is
    // readable immediately after dispatch and rides the next event.
    try std.testing.expectEqual(@as(u64, 0), app_state.last_input_latency_ns);
    try std.testing.expectEqual(@as(u64, 8_333_333), app_state.last_input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_input_latency_budget_exceeded_count);
    try std.testing.expect(app_state.last_input_latency_budget_ok);
    try std.testing.expectEqual(@as(u64, 8_333_333), app_state.last_frame_interval_ns);

    const latency_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(u64, 8_333_333), latency_frame.frame_interval_ns);
    try std.testing.expectEqual(@as(u64, 50_000_000), latency_frame.input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 20_000_000), latency_frame.input_latency_ns);
    try std.testing.expectEqual(@as(u64, 8_333_333), latency_frame.input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 1), latency_frame.input_latency_budget_exceeded_count);
    try std.testing.expect(!latency_frame.input_latency_budget_ok);

    const latency_snapshot = harness.runtime.automationSnapshot("GPU");
    const latency_view = testViewByLabel(latency_snapshot.views, "canvas").?;
    try std.testing.expectEqual(@as(u64, 8_333_333), latency_view.gpu_frame_interval_ns);
    try std.testing.expectEqual(@as(u64, 50_000_000), latency_view.gpu_input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 20_000_000), latency_view.gpu_input_latency_ns);
    try std.testing.expectEqual(@as(u64, 8_333_333), latency_view.gpu_input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 1), latency_view.gpu_input_latency_budget_exceeded_count);
    try std.testing.expect(!latency_view.gpu_input_latency_budget_ok);
    try std.testing.expectEqual(@as(u64, 22), latency_view.gpu_first_frame_latency_ns);
    try std.testing.expectEqual(@as(u64, 150_000_000), latency_view.gpu_first_frame_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), latency_view.gpu_first_frame_latency_budget_exceeded_count);
    try std.testing.expect(latency_view.gpu_first_frame_latency_budget_ok);

    var latency_json_buffer: [8192]u8 = undefined;
    const latency_json = try writeViewJson(latency_view, &latency_json_buffer);
    try std.testing.expect(std.mem.indexOf(u8, latency_json, "\"gpuFrameIntervalNs\":8333333") != null);
    try std.testing.expect(std.mem.indexOf(u8, latency_json, "\"gpuInputTimestampNs\":50000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, latency_json, "\"gpuInputLatencyNs\":20000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, latency_json, "\"gpuInputLatencyBudgetExceededCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, latency_json, "\"gpuInputLatencyBudgetOk\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, latency_json, "\"gpuFirstFrameLatencyNs\":22") != null);

    const relaxed_budget = try harness.runtime.setGpuSurfaceInputLatencyBudget(1, "canvas", 25_000_000);
    try std.testing.expectEqual(@as(u64, 25_000_000), relaxed_budget.gpu_input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), relaxed_budget.gpu_input_latency_budget_exceeded_count);
    try std.testing.expect(relaxed_budget.gpu_input_latency_budget_ok);
    const relaxed_snapshot = harness.runtime.automationSnapshot("GPU relaxed");
    const relaxed_view = testViewByLabel(relaxed_snapshot.views, "canvas").?;
    try std.testing.expectEqual(@as(u64, 20_000_000), relaxed_view.gpu_input_latency_ns);
    try std.testing.expectEqual(@as(u64, 25_000_000), relaxed_view.gpu_input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), relaxed_view.gpu_input_latency_budget_exceeded_count);
    try std.testing.expect(relaxed_view.gpu_input_latency_budget_ok);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .timestamp_ns = 100_000_000,
        .x = 12,
        .y = 18,
        .button = 0,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(800, 450),
        .scale_factor = 2,
        .frame_index = 10,
        .timestamp_ns = 120_000_000,
        .nonblank = true,
        .sample_color = 0xff336699,
    } });
    try std.testing.expectEqual(@as(u64, 100_000_000), app_state.last_input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 20_000_000), app_state.last_input_latency_ns);
    try std.testing.expectEqual(@as(u64, 25_000_000), app_state.last_input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_input_latency_budget_exceeded_count);
    try std.testing.expect(app_state.last_input_latency_budget_ok);

    const relaxed_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(u64, 100_000_000), relaxed_frame.input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 20_000_000), relaxed_frame.input_latency_ns);
    try std.testing.expectEqual(@as(u64, 25_000_000), relaxed_frame.input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), relaxed_frame.input_latency_budget_exceeded_count);
    try std.testing.expect(relaxed_frame.input_latency_budget_ok);

    // An OCCLUDED logical completion resolves a pending input WITHOUT
    // recording a latency: its timestamp is the host's deliberate
    // occluded heartbeat (up to a second after the input), not a
    // present — stamping it would publish pacing policy as a
    // manufactured budget overrun. The previous latency and verdict
    // stand untouched.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .timestamp_ns = 200_000_000,
        .x = 12,
        .y = 18,
        .button = 0,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(800, 450),
        .scale_factor = 2,
        .frame_index = 11,
        .timestamp_ns = 1_200_000_000,
        .nonblank = true,
        .sample_color = 0xff336699,
        .occluded = true,
    } });
    const occluded_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    // The input's arrival is still recorded; only the latency stamp is
    // withheld, so the pre-occlusion measurement survives verbatim.
    try std.testing.expectEqual(@as(u64, 200_000_000), occluded_frame.input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 20_000_000), occluded_frame.input_latency_ns);
    try std.testing.expectEqual(@as(usize, 0), occluded_frame.input_latency_budget_exceeded_count);
    try std.testing.expect(occluded_frame.input_latency_budget_ok);

    // The pending input was RESOLVED (not left dangling): the next
    // visible completion carries no stale input to bill, so the whole
    // covered span can never surface as one giant latency reading.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(800, 450),
        .scale_factor = 2,
        .frame_index = 12,
        .timestamp_ns = 2_210_000_000,
        .nonblank = true,
        .sample_color = 0xff336699,
    } });
    const revealed_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(u64, 20_000_000), revealed_frame.input_latency_ns);
    try std.testing.expectEqual(@as(usize, 0), revealed_frame.input_latency_budget_exceeded_count);
    try std.testing.expect(revealed_frame.input_latency_budget_ok);

    // A fresh input against a VISIBLE completion still measures — the
    // occluded path suppresses only its own deliberately slow endpoint,
    // never real latency.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .timestamp_ns = 2_300_000_000,
        .x = 12,
        .y = 18,
        .button = 0,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(800, 450),
        .scale_factor = 2,
        .frame_index = 13,
        .timestamp_ns = 2_310_000_000,
        .nonblank = true,
        .sample_color = 0xff336699,
    } });
    const measured_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(u64, 2_300_000_000), measured_frame.input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 10_000_000), measured_frame.input_latency_ns);
}

test "runtime starts, fires, and cancels platform timers" {
    const TestApp = struct {
        timer_count: usize = 0,
        last_timer_id: u64 = 0,
        last_timer_timestamp_ns: u64 = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "timers", .source = platform.WebViewSource.html("<h1>Timers</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .timer => |timer_event| {
                    self.timer_count += 1;
                    self.last_timer_id = timer_event.id;
                    self.last_timer_timestamp_ns = timer_event.timestamp_ns;
                },
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.startTimer(11, 250_000_000, true);
    try std.testing.expect(harness.null_platform.startedTimer(11) != null);

    if (harness.null_platform.fireTimer(11, 77_000)) |event_value| {
        try harness.runtime.dispatchPlatformEvent(app, event_value);
    }
    try std.testing.expectEqual(@as(usize, 1), app_state.timer_count);
    try std.testing.expectEqual(@as(u64, 11), app_state.last_timer_id);
    try std.testing.expectEqual(@as(u64, 77_000), app_state.last_timer_timestamp_ns);

    // Cancelled timers stop synthesizing events, so the app hears nothing.
    try harness.runtime.cancelTimer(11);
    try std.testing.expect(harness.null_platform.fireTimer(11, 78_000) == null);
    try std.testing.expectEqual(@as(usize, 1), app_state.timer_count);
}

test "gpu surface nonblank transition invalidates the runtime" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-nonblank", .source = platform.WebViewSource.html("<h1>GPU</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = context;
            _ = runtime;
            _ = event_value;
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
        .frame = geometry.RectF.init(0, 0, 640, 360),
    });

    // A blank frame on an idle runtime must not invalidate: the per-frame
    // tick would otherwise republish observable state 60 times a second.
    harness.runtime.invalidated = false;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(640, 360),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 16,
        .nonblank = false,
    } });
    try std.testing.expect(!harness.runtime.invalidated);

    // The first nonblank frame is an observable state change with no other
    // invalidation source on an idle boot (no resize, no input); it must
    // invalidate so automation snapshots republish gpu_nonblank=true.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(640, 360),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 32,
        .nonblank = true,
    } });
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect((try harness.runtime.gpuSurfaceFrame(1, "canvas")).nonblank);

    // Steady-state nonblank frames carry no new fact and stay quiet.
    harness.runtime.invalidated = false;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(640, 360),
        .scale_factor = 1,
        .frame_index = 3,
        .timestamp_ns = 48,
        .nonblank = true,
    } });
    try std.testing.expect(!harness.runtime.invalidated);
}

test "a handler error degrades: dispatch continues, the error ring records it, snapshots publish it" {
    // One erroring update arm used to exit the whole app
    // (the platform callback saw the error, set `failed`, and stopped
    // the run loop as CallbackFailed).
    const TestApp = struct {
        command_count: u32 = 0,
        fail_next: bool = false,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "degrader", .source = platform.WebViewSource.html("<h1>Degrade</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => {
                    self.command_count += 1;
                    if (self.fail_next) {
                        self.fail_next = false;
                        return error.UpdateArmBlewUp;
                    }
                },
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    // This test exercises the production degrade-not-die path; the
    // harness defaults to `.propagate`.
    harness.runtime.dispatch_error_policy = .degrade;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.dispatchErrors().len);

    // The erroring dispatch does NOT propagate (no CallbackFailed path).
    app_state.fail_next = true;
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "boom", .window_id = 1 } });
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);

    // The error is recorded and queryable...
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.dispatchErrors().len);
    try std.testing.expectEqual(@as(u64, 1), harness.runtime.dispatchErrorTotal());
    try std.testing.expectEqualStrings("command", harness.runtime.dispatchErrors()[0].event);
    try std.testing.expectEqualStrings("UpdateArmBlewUp", harness.runtime.dispatchErrors()[0].error_name);

    // ...traced at error level...
    var traced = false;
    for (harness.trace_sink.written()) |record| {
        if (std.mem.eql(u8, record.name, "dispatch.error")) {
            try std.testing.expectEqual(trace.Level.err, record.level);
            try std.testing.expectEqualStrings("UpdateArmBlewUp", record.message.?);
            traced = true;
        }
    }
    try std.testing.expect(traced);

    // ...and published in the automation snapshot text.
    var snapshot_buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&snapshot_buffer);
    try automation.snapshot.writeText(harness.runtime.automationSnapshot("Degrade"), &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "dispatch_errors=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "error event=command name=UpdateArmBlewUp") != null);

    // The app keeps running: later dispatches still reach it.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "next", .window_id = 1 } });
    try std.testing.expectEqual(@as(u32, 2), app_state.command_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.dispatchErrors().len);
}

test "the dispatch error ring stays bounded and keeps the newest records plus the lifetime total" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "ring", .source = platform.WebViewSource.html("<h1>Ring</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = context;
            _ = runtime;
            if (event_value == .command) return error.AlwaysFails;
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    // Exercises the production degrade-not-die path; the harness
    // defaults to `.propagate`.
    harness.runtime.dispatch_error_policy = .degrade;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    var index: usize = 0;
    while (index < runtime_module.max_dispatch_errors + 5) : (index += 1) {
        try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "boom", .window_id = 1 } });
    }
    try std.testing.expectEqual(runtime_module.max_dispatch_errors, harness.runtime.dispatchErrors().len);
    try std.testing.expectEqual(@as(u64, runtime_module.max_dispatch_errors + 5), harness.runtime.dispatchErrorTotal());
    for (harness.runtime.dispatchErrors()) |record| {
        try std.testing.expectEqualStrings("AlwaysFails", record.error_name);
    }
}

test "a full trace sink never fails dispatch; the loss is counted and published" {
    // A degrade-not-die shape: the TestHarness BufferSink holds 64
    // records; dispatch used to fail with OutOfSpace once it filled.
    const TestApp = struct {
        command_count: u32 = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "chatty", .source = platform.WebViewSource.html("<h1>Chatty</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            if (event_value == .command) self.command_count += 1;
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    // Far more events than the sink holds: every one must dispatch.
    var index: u32 = 0;
    while (index < 200) : (index += 1) {
        try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "tick", .window_id = 1 } });
    }
    try std.testing.expectEqual(@as(u32, 200), app_state.command_count);
    try std.testing.expect(harness.runtime.dropped_trace_records > 0);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.dispatchErrorTotal());

    var snapshot_buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&snapshot_buffer);
    try automation.snapshot.writeText(harness.runtime.automationSnapshot("Chatty"), &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "dropped_trace_records=") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "dropped_trace_records=0") == null);
}
