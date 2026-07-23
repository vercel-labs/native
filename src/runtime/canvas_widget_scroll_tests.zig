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

test "runtime retains canvas widget design tokens" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-design-tokens", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const button = canvas.Widget{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 12, 96, 32),
        .text = "Run",
        .state = .{ .selected = true },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{button} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const tokens = canvas.DesignTokens{
        .colors = .{
            .accent = canvas.Color.rgb8(100, 20, 200),
            .accent_text = canvas.Color.rgb8(255, 250, 240),
        },
        .radius = .{ .md = 7 },
    };
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const themed = try harness.runtime.setCanvasWidgetDesignTokens(1, "canvas", tokens);
    try std.testing.expectEqual(@as(u64, 2), themed.widget_revision);
    try std.testing.expectEqualDeep(tokens, try harness.runtime.canvasWidgetDesignTokens(1, "canvas"));
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const unchanged = try harness.runtime.setCanvasWidgetDesignTokens(1, "canvas", tokens);
    try std.testing.expectEqual(@as(u64, 2), unchanged.widget_revision);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);

    _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_accent_fill = false;
    var saw_accent_text = false;
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(2, 1)) {
                    switch (fill.fill) {
                        .color => |color| try std.testing.expectEqualDeep(tokens.colors.accent, color),
                        else => return error.TestUnexpectedResult,
                    }
                    saw_accent_fill = true;
                }
            },
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualDeep(tokens.colors.accent_text, text.color);
                    saw_accent_text = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_accent_fill);
    try std.testing.expect(saw_accent_text);

    const next_tokens = canvas.DesignTokens{
        .colors = .{
            .accent = canvas.Color.rgb8(20, 120, 80),
            .accent_text = canvas.Color.rgb8(240, 255, 250),
        },
    };
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const changed = try harness.runtime.setCanvasWidgetDesignTokens(1, "canvas", next_tokens);
    try std.testing.expectEqual(@as(u64, 3), changed.widget_revision);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
    const changed_display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    for (changed_display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(2, 1)) {
                    switch (fill.fill) {
                        .color => |color| try std.testing.expectEqualDeep(next_tokens.colors.accent, color),
                        else => return error.TestUnexpectedResult,
                    }
                    return;
                }
            },
            else => {},
        }
    }
    return error.TestUnexpectedResult;
}

test "runtime dispatches canvas widget scroll events for wheel and kinetic scrolls" {
    const TestApp = struct {
        scroll_event_count: u32 = 0,
        last_id: canvas.ObjectId = 0,
        last_scroll: canvas.ScrollState = .{},

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-scroll-events", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_scroll => |scroll_event| {
                    self.scroll_event_count += 1;
                    self.last_id = scroll_event.id;
                    self.last_scroll = scroll_event.scroll;
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

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 88, 0, 32), .text = "Three" },
    };
    const scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .children = &children,
    };
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // A wheel gesture delivers one canvas_widget_scroll event carrying
    // the post-scroll state: the applied offset plus the viewport and
    // content extents an app needs to page or lazy-load.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .timestamp_ns = 1_000_000_000,
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_y = 24,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.scroll_event_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 1), app_state.last_id);
    try std.testing.expectEqual(@as(f32, 24), app_state.last_scroll.offset_y);
    try std.testing.expectEqual(@as(f32, 72), app_state.last_scroll.viewport_extent_y);
    try std.testing.expectEqual(@as(f32, 120), app_state.last_scroll.content_extent_y);
    try std.testing.expectEqual(@as(f32, 48), app_state.last_scroll.axis(.vertical).maxOffset());

    // The wheel left momentum; the first frame after input skips the
    // kinetic step (pending-input frame), the second one steps it and
    // delivers a fresh event with the advanced offset.
    try std.testing.expect(harness.runtime.views[0].widget_scroll_states[0].velocity_y > 0);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(180, 72),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_016_000_000,
        .frame_interval_ns = 16_000_000,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.scroll_event_count);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(180, 72),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 1_032_000_000,
        .frame_interval_ns = 16_000_000,
    } });
    try std.testing.expectEqual(@as(u32, 2), app_state.scroll_event_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 1), app_state.last_id);
    try std.testing.expect(app_state.last_scroll.offset_y > 24);
    try std.testing.expectEqual(
        harness.runtime.views[0].widget_layout_nodes[0].widget.value,
        app_state.last_scroll.offset_y,
    );
}

test "runtime wheel input scrolls retained canvas scroll views" {
    const TestApp = struct {
        widget_pointer_count: u32 = 0,
        raw_input_count: u32 = 0,
        last_phase: canvas.WidgetPointerPhase = .hover,
        last_target_id: canvas.ObjectId = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-scroll", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_pointer => |pointer_event| {
                    self.widget_pointer_count += 1;
                    self.last_phase = pointer_event.pointer.phase;
                    self.last_target_id = if (pointer_event.target) |target| target.id else 0;
                },
                .gpu_surface_input => self.raw_input_count += 1,
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

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 88, 0, 32), .text = "Three" },
    };
    const scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .children = &children,
    };
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .timestamp_ns = 1_000_000_000,
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_y = 24,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.widget_pointer_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.raw_input_count);
    try std.testing.expectEqual(canvas.WidgetPointerPhase.wheel, app_state.last_phase);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_target_id);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 180, 72), harness.runtime.pendingDirtyRegions()[0]);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 24), retained.nodes[0].widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -24, 180, 32), retained.nodes[1].frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 20, 180, 32), retained.nodes[2].frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 64, 180, 32), retained.nodes[3].frame);
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 4), snapshot.widgets.len);
    try std.testing.expectEqual(@as(?f32, 0.5), snapshot.widgets[0].value);
    try std.testing.expect(snapshot.widgets[0].scroll.present);
    try std.testing.expectEqual(@as(f32, 24.0), snapshot.widgets[0].scroll.offset);
    try std.testing.expectEqual(@as(f32, 72.0), snapshot.widgets[0].scroll.viewport_extent);
    try std.testing.expectEqual(@as(f32, 120.0), snapshot.widgets[0].scroll.content_extent);
    try std.testing.expect(snapshot.widgets[0].actions.focus);
    try std.testing.expect(snapshot.widgets[0].actions.increment);
    try std.testing.expect(snapshot.widgets[0].actions.decrement);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, -4, 180, 32), snapshot.widgets[1].bounds);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 40, 180, 32), snapshot.widgets[2].bounds);

    var a11y_buffer: [2048]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#1 role=group") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "value=0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "scroll=[offset=24,viewport=72,content=120]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "actions=[focus,increment,decrement]") != null);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_scrolled_button = false;
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(3, 1)) {
                    try std.testing.expectEqualDeep(geometry.RectF.init(0, 20, 180, 32), fill.rect);
                    saw_scrolled_button = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_scrolled_button);

    try std.testing.expect(harness.runtime.views[0].widget_scroll_states[0].velocity_y > 0);
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    harness.null_platform.gpu_surface_frame_request_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = "canvas",
        .size = geometry.SizeF.init(180, 72),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_016_000_000,
        .frame_interval_ns = 16_000_000,
        .nonblank = true,
    } });
    var kinetic_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 24), kinetic_layout.nodes[0].widget.value);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_frame_request_count);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    harness.null_platform.gpu_surface_frame_request_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = "canvas",
        .size = geometry.SizeF.init(180, 72),
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 1_032_000_000,
        .frame_interval_ns = 16_000_000,
        .nonblank = true,
    } });
    const kinetic = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(u64, 3), kinetic.widget_revision);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 180, 72), harness.runtime.pendingDirtyRegions()[0]);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_frame_request_count);

    kinetic_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 47.04), kinetic_layout.nodes[0].widget.value, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -47.04), kinetic_layout.nodes[1].frame.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -3.04), kinetic_layout.nodes[2].frame.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40.96), kinetic_layout.nodes[3].frame.y, 0.01);
    try std.testing.expect(harness.runtime.views[0].widget_scroll_states[0].velocity_y > 0);

    const kinetic_display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_kinetic_scrolled_button = false;
    for (kinetic_display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(3, 1)) {
                    try std.testing.expectApproxEqAbs(@as(f32, -3.04), fill.rect.y, 0.01);
                    saw_kinetic_scrolled_button = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_kinetic_scrolled_button);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const clamped = try harness.runtime.stepCanvasWidgetKineticScroll(1, "canvas", 16);
    try std.testing.expectEqual(@as(u64, 4), clamped.widget_revision);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 180, 72), harness.runtime.pendingDirtyRegions()[0]);

    kinetic_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 48), kinetic_layout.nodes[0].widget.value, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -48), kinetic_layout.nodes[1].frame.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -4), kinetic_layout.nodes[2].frame.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), kinetic_layout.nodes[3].frame.y, 0.01);
    try std.testing.expectEqual(@as(f32, 0), harness.runtime.views[0].widget_scroll_states[0].velocity_y);

    var settle_frame: usize = 0;
    while (settle_frame < 48) : (settle_frame += 1) {
        harness.runtime.invalidated = false;
        harness.runtime.dirty_region_count = 0;
        _ = try harness.runtime.stepCanvasWidgetKineticScroll(1, "canvas", 16);
        kinetic_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
        if (@abs(kinetic_layout.nodes[0].widget.value - 48) <= 0.01 and harness.runtime.views[0].widget_scroll_states[0].velocity_y == 0) break;
    }

    try std.testing.expect(settle_frame < 48);
    try std.testing.expectApproxEqAbs(@as(f32, 48), kinetic_layout.nodes[0].widget.value, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -48), kinetic_layout.nodes[1].frame.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -4), kinetic_layout.nodes[2].frame.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), kinetic_layout.nodes[3].frame.y, 0.01);
    try std.testing.expectEqual(@as(f32, 0), harness.runtime.views[0].widget_scroll_states[0].velocity_y);

    const settled_revision = harness.runtime.views[0].widget_revision;
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const idle = try harness.runtime.stepCanvasWidgetKineticScroll(1, "canvas", 16);
    try std.testing.expectEqual(settled_revision, idle.widget_revision);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);
}

test "runtime wheel over virtualized scroll does not bubble to parent scroll view" {
    const TestApp = struct {
        widget_pointer_count: u32 = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-virtual-scroll-bubble", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_pointer => |pointer_event| if (pointer_event.pointer.phase == .wheel) {
                    self.widget_pointer_count += 1;
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

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 180, 72),
    });

    const virtual_children = [_]canvas.Widget{
        .{ .id = 3, .kind = .list_item, .text = "One" },
        .{ .id = 4, .kind = .list_item, .text = "Two" },
        .{ .id = 5, .kind = .list_item, .text = "Three" },
        .{ .id = 6, .kind = .list_item, .text = "Four" },
    };
    const parent_children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .scroll_view,
            .frame = geometry.RectF.init(0, 0, 180, 40),
            .layout = .{ .virtualized = true, .virtual_item_extent = 20 },
            .children = &virtual_children,
        },
        .{ .id = 20, .kind = .button, .frame = geometry.RectF.init(0, 120, 0, 32), .text = "Below" },
    };
    const parent_scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .children = &parent_children,
    };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(parent_scroll, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const initial_revision = harness.runtime.views[0].widget_revision;
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .timestamp_ns = 1_000_000_000,
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_y = 24,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.widget_pointer_count);
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0), retained.findById(1).?.widget.value);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(2).?.widget.value);
    try std.testing.expectEqual(initial_revision, harness.runtime.views[0].widget_revision);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);
}

test "runtime automation widget wheel timestamps retained canvas scroll input" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-wheel-automation", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 180, 64),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 40, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 80, 0, 32), .text = "Three" },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .scroll_view, .children = &children }, geometry.RectF.init(0, 0, 180, 64), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchAutomationCommand(app, "widget-wheel canvas 1 18");
    try std.testing.expect(harness.runtime.views[0].gpu_input_timestamp_ns > 0);
    try std.testing.expectEqual(harness.runtime.views[0].gpu_input_timestamp_ns, harness.runtime.views[0].gpu_pending_input_timestamp_ns);
    try std.testing.expect(harness.runtime.invalidated);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 18), retained.findById(1).?.widget.value);
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);
}

test "runtime automation widget key inputs route to focused canvas widgets" {
    const TestApp = struct {
        command_count: u32 = 0,
        last_command: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_view_label: []const u8 = "",

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-key-automation", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    self.command_count += 1;
                    self.last_command = command.name;
                    self.last_source = command.source;
                    self.last_view_label = command.view_label;
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

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 120),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .text_field, .frame = geometry.RectF.init(12, 16, 160, 36), .text = "Draft" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(12, 64, 96, 32), .text = "Run", .command = "app.run" },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchAutomationCommand(app, "widget-action canvas 2 focus");
    try harness.runtime.dispatchAutomationCommand(app, "widget-key canvas a a");

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqualStrings("Drafta", retained.findById(2).?.widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(6), retained.findById(2).?.widget.text_selection.?);

    try harness.runtime.dispatchAutomationCommand(app, "widget-key canvas tab");
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);
    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(!snapshot.widgets[0].focused);
    try std.testing.expect(snapshot.widgets[1].focused);

    try harness.runtime.dispatchAutomationCommand(app, "widget-key canvas enter");
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("app.run", app_state.last_command);
    try std.testing.expectEqual(CommandSource.native_view, app_state.last_source);
    try std.testing.expectEqualStrings("canvas", app_state.last_view_label);
}

test "runtime applies stored design token scroll physics" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-token-scroll", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 88, 0, 32), .text = "Three" },
    };
    const scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .children = &children,
    };
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const tokens = canvas.DesignTokens{
        .scroll = .{
            .wheel_multiplier = 0.5,
            .wheel_velocity_scale = 4,
            .deceleration_per_second = 1,
            .stop_velocity = 0,
        },
    };
    _ = try harness.runtime.setCanvasWidgetDesignTokens(1, "canvas", tokens);
    try std.testing.expectEqualDeep(tokens, try harness.runtime.canvasWidgetDesignTokens(1, "canvas"));

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_y = 40,
    } });

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 20), retained.nodes[0].widget.value);
    try std.testing.expectEqual(@as(f32, -20), retained.nodes[1].frame.y);
    try std.testing.expectEqual(@as(f32, 80), harness.runtime.views[0].widget_scroll_states[0].velocity_y);

    _ = try harness.runtime.stepCanvasWidgetKineticScroll(1, "canvas", 16);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 21.28), retained.nodes[0].widget.value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -21.28), retained.nodes[1].frame.y, 0.001);
    try std.testing.expectEqual(@as(f32, 80), harness.runtime.views[0].widget_scroll_states[0].velocity_y);
}

test "runtime refreshes hovered canvas widget after scroll clipping" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-scroll-hover", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 160, 40),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Two" },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &children },
        geometry.RectF.init(0, 0, 160, 40),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_move,
        .x = 12,
        .y = 12,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_hovered_id);
    // Buttons show the native arrow; the hover id above is the state
    // this test actually pins across the scroll.
    try std.testing.expectEqual(platform.Cursor.arrow, harness.runtime.views[0].canvas_widget_cursor);

    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[1].hovered);
    try std.testing.expect(!snapshot.widgets[2].hovered);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = 12,
        .y = 12,
        .delta_y = 40,
    } });

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -40, 160, 32), retained.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 8, 160, 32), retained.findById(3).?.frame);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(platform.Cursor.arrow, harness.runtime.views[0].canvas_widget_cursor);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 160, 40), harness.runtime.pendingDirtyRegions()[0]);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(!snapshot.widgets[1].hovered);
    try std.testing.expect(snapshot.widgets[2].hovered);
}

test "runtime clears focused canvas widget after scroll clipping" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-scroll-focus", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 160, 40),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Two" },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &children },
        geometry.RectF.init(0, 0, 160, 40),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 2;
    harness.runtime.views[0].canvas_widget_focus_visible_id = 2;
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    var route_buffer: [4]canvas.WidgetEventRouteEntry = undefined;
    const initial_route = try harness.runtime.routeCanvasWidgetKeyboardInput(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
    }, &route_buffer);
    try std.testing.expect(initial_route != null);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), initial_route.?.target.?.id);

    var display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_focus_ring = false;
    for (display_list.commands) |command| {
        if (command.objectId()) |id| {
            if (id == testCanvasWidgetPartId(2, 3)) saw_focus_ring = true;
        }
    }
    try std.testing.expect(saw_focus_ring);

    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[1].focused);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = 12,
        .y = 12,
        .delta_y = 40,
    } });

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -40, 160, 32), retained.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 8, 160, 32), retained.findById(3).?.frame);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expect(try harness.runtime.routeCanvasWidgetKeyboardInput(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
    }, &route_buffer) == null);

    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    saw_focus_ring = false;
    for (display_list.commands) |command| {
        if (command.objectId()) |id| {
            if (id == testCanvasWidgetPartId(2, 3)) saw_focus_ring = true;
        }
    }
    try std.testing.expect(!saw_focus_ring);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(!snapshot.widgets[1].focused);
    try std.testing.expect(!snapshot.widgets[2].focused);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 160, 40), harness.runtime.pendingDirtyRegions()[0]);
}

test "runtime clears focused canvas widget after kinetic scroll clipping" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-kinetic-focus", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 160, 40),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Two" },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &children },
        geometry.RectF.init(0, 0, 160, 40),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 2;
    harness.runtime.views[0].widget_scroll_states[0].velocity_y = 2500;
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const frame = try harness.runtime.stepCanvasWidgetKineticScroll(1, "canvas", 16);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(u64, 2), frame.widget_revision);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 160, 40), harness.runtime.pendingDirtyRegions()[0]);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 40), retained.findById(1).?.widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -40, 160, 32), retained.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 8, 160, 32), retained.findById(3).?.frame);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(!snapshot.widgets[1].focused);
    try std.testing.expect(!snapshot.widgets[2].focused);

    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    for (display_list.commands) |command| {
        if (command.objectId()) |id| {
            try std.testing.expect(id != testCanvasWidgetPartId(2, 3));
        }
    }
}

test "runtime reconciles canvas widget render state after keyboard scroll clipping" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-keyboard-scroll-state", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 160, 40),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Two" },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &children },
        geometry.RectF.init(0, 0, 160, 40),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 1;
    harness.runtime.views[0].canvas_widget_hovered_id = 2;
    // Seed a non-arrow cursor (only a link hover produces this in the
    // wild) so the reset back to arrow below is observable.
    harness.runtime.views[0].canvas_widget_cursor = .pointing_hand;
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "pagedown",
    } });

    try std.testing.expectEqual(@as(canvas.ObjectId, 1), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(platform.Cursor.arrow, harness.runtime.views[0].canvas_widget_cursor);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 160, 40), harness.runtime.pendingDirtyRegions()[0]);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 34), retained.findById(1).?.widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -34, 160, 32), retained.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 14, 160, 32), retained.findById(3).?.frame);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[0].focused);
    try std.testing.expect(!snapshot.widgets[1].hovered);
    try std.testing.expect(!snapshot.widgets[2].hovered);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "end",
    } });
    var keyboard_scrolled = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 40), keyboard_scrolled.findById(1).?.widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -40, 160, 32), keyboard_scrolled.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 8, 160, 32), keyboard_scrolled.findById(3).?.frame);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "home",
    } });
    keyboard_scrolled = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0), keyboard_scrolled.findById(1).?.widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 160, 32), keyboard_scrolled.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 48, 160, 32), keyboard_scrolled.findById(3).?.frame);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
}

test "runtime reconciles canvas widget scroll momentum across layout replacement" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-scroll-reconcile", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 220, 96),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 88, 0, 32), .text = "Three" },
    };
    const scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .frame = geometry.RectF.init(0, 0, 180, 72),
        .children = &children,
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_y = 24,
    } });
    try std.testing.expect(harness.runtime.views[0].widget_scroll_states[0].velocity_y > 0);

    const scrolled = try harness.runtime.canvasWidgetLayout(1, "canvas");
    const current_offset = scrolled.findById(1).?.widget.value;
    try std.testing.expectEqual(@as(f32, 24), current_offset);

    const refreshed_scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .frame = geometry.RectF.init(24, 12, 180, 72),
        .value = current_offset,
        .children = &children,
    };
    const refreshed_widgets = [_]canvas.Widget{
        .{ .id = 10, .kind = .text, .frame = geometry.RectF.init(8, 0, 120, 12), .text = "Activity" },
        refreshed_scroll,
    };
    var refreshed_nodes: [6]canvas.WidgetLayoutNode = undefined;
    const refreshed_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &refreshed_widgets }, geometry.RectF.init(0, 0, 220, 96), &refreshed_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", refreshed_layout);

    const refreshed = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 24), refreshed.findById(1).?.widget.value);
    try std.testing.expect(harness.runtime.views[0].widget_scroll_states[2].velocity_y > 0);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const kinetic = try harness.runtime.stepCanvasWidgetKineticScroll(1, "canvas", 16);
    try std.testing.expectEqual(@as(u64, 4), kinetic.widget_revision);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    try std.testing.expectEqualDeep(geometry.RectF.init(34, 32, 180, 72), harness.runtime.pendingDirtyRegions()[0]);

    const kinetic_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 47.04), kinetic_layout.findById(1).?.widget.value, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -35.04), kinetic_layout.findById(2).?.frame.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8.96), kinetic_layout.findById(3).?.frame.y, 0.01);
}

test "runtime clamps canvas scroll offset after layout replacement shrinks content" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-scroll-clamp-replacement", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 220, 96),
    });

    const full_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 88, 0, 32), .text = "Three" },
    };
    const full_scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .frame = geometry.RectF.init(0, 0, 180, 72),
        .value = 48,
        .children = &full_children,
    };
    var full_nodes: [4]canvas.WidgetLayoutNode = undefined;
    const full_layout = try canvas.layoutWidgetTree(full_scroll, geometry.RectF.init(0, 0, 180, 72), &full_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", full_layout);

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 48), retained.findById(1).?.widget.value);
    try std.testing.expectEqual(@as(f32, -48), retained.findById(2).?.frame.y);

    const short_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
    };
    const short_scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .frame = geometry.RectF.init(0, 0, 180, 72),
        .value = 48,
        .children = &short_children,
    };
    var short_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const short_layout = try canvas.layoutWidgetTree(short_scroll, geometry.RectF.init(0, 0, 180, 72), &short_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", short_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0), retained.findById(1).?.widget.value);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(2).?.frame.y);
    try std.testing.expectEqual(@as(f32, 0), harness.runtime.views[0].widget_scroll_states[0].offset_y);
    try std.testing.expectEqual(@as(f32, 0), harness.runtime.views[0].widget_scroll_states[0].velocity_y);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 2), snapshot.widgets.len);
    try std.testing.expect(snapshot.widgets[0].scroll.present);
    try std.testing.expectEqual(@as(f32, 0), snapshot.widgets[0].scroll.offset);
    try std.testing.expectEqual(@as(f32, 72), snapshot.widgets[0].scroll.viewport_extent);
    try std.testing.expectEqual(@as(f32, 72), snapshot.widgets[0].scroll.content_extent);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 180, 32), snapshot.widgets[1].bounds);
}

test "runtime chains wheel input from saturated nested canvas scroll views" {
    const TestApp = struct {
        widget_pointer_count: u32 = 0,
        last_phase: canvas.WidgetPointerPhase = .hover,
        last_target_id: canvas.ObjectId = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-scroll-chain", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_pointer => |pointer_event| {
                    self.widget_pointer_count += 1;
                    self.last_phase = pointer_event.pointer.phase;
                    self.last_target_id = if (pointer_event.target) |target| target.id else 0;
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

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 80),
    });

    const inner_children = [_]canvas.Widget{
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "Inner one" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Inner two" },
    };
    const outer_children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .scroll_view,
            .frame = geometry.RectF.init(0, 0, 0, 40),
            .value = 36,
            .children = &inner_children,
        },
        .{ .id = 5, .kind = .button, .frame = geometry.RectF.init(0, 120, 0, 32), .text = "Outer footer" },
    };
    const outer = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .children = &outer_children,
    };

    var nodes: [6]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(outer, geometry.RectF.init(0, 0, 180, 80), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_y = 24,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.widget_pointer_count);
    try std.testing.expectEqual(canvas.WidgetPointerPhase.wheel, app_state.last_phase);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), app_state.last_target_id);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 180, 80), harness.runtime.pendingDirtyRegions()[0]);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 24), retained.nodes[0].widget.value);
    try std.testing.expectEqual(@as(f32, 36), retained.nodes[1].widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -24, 180, 40), retained.nodes[1].frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -60, 180, 32), retained.nodes[2].frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -16, 180, 32), retained.nodes[3].frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 96, 180, 32), retained.nodes[4].frame);
    try std.testing.expect(harness.runtime.views[0].widget_scroll_states[0].velocity_y > 0);
    try std.testing.expectEqual(@as(f32, 0), harness.runtime.views[0].widget_scroll_states[1].velocity_y);
}

test "runtime leaves virtualized canvas scroll views app driven" {
    const TestApp = struct {
        widget_pointer_count: u32 = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-virtual-scroll", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_pointer => self.widget_pointer_count += 1,
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

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 160, 48),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Zero" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "One" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Two" },
        .{ .id = 5, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Three" },
    };
    const scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .layout = .{
            .virtualized = true,
            .virtual_item_extent = 20,
            .virtual_overscan = 1,
        },
        .children = &children,
    };
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 160, 48), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    const retained_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(usize, 0), retained_layout.nodes[0].widget.children.len);
    try std.testing.expectEqual(@as(?u32, 4), retained_layout.nodes[0].widget.semantics.list_item_count);
    try std.testing.expectEqual(@as(f32, 20), retained_layout.nodes[0].widget.layout.virtual_item_extent);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = 12,
        .y = 12,
        .delta_y = 20,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.widget_pointer_count);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0), retained.nodes[0].widget.value);
    try std.testing.expectEqualDeep(layout.nodes[1].frame, retained.nodes[1].frame);
    try std.testing.expectEqual(@as(u64, 1), harness.runtime.views[0].widget_revision);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 5), snapshot.widgets.len);
    try std.testing.expect(snapshot.widgets[0].scroll.present);
    try std.testing.expectEqual(@as(f32, 0), snapshot.widgets[0].scroll.offset);
    try std.testing.expectEqual(@as(f32, 48), snapshot.widgets[0].scroll.viewport_extent);
    try std.testing.expectEqual(@as(f32, 80), snapshot.widgets[0].scroll.content_extent);
    try std.testing.expect(snapshot.widgets[0].actions.focus);
    try std.testing.expect(snapshot.widgets[0].actions.increment);
    try std.testing.expect(snapshot.widgets[0].actions.decrement);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const kinetic = try harness.runtime.stepCanvasWidgetKineticScroll(1, "canvas", 16);
    try std.testing.expectEqual(@as(u64, 1), kinetic.widget_revision);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);
}

test "user scroll offsets survive rebuilds until the source offset changes" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-scroll-reconcile", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 180, 64),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 40, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 80, 0, 32), .text = "Three" },
    };
    const source_root = canvas.Widget{ .id = 1, .kind = .scroll_view, .children = &children };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(source_root, geometry.RectF.init(0, 0, 180, 64), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // The user scrolls: runtime owns the offset.
    try harness.runtime.dispatchAutomationCommand(app, "widget-wheel canvas 1 18");
    try std.testing.expectEqual(@as(f32, 18), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(1).?.widget.value);

    // An elm-style rebuild with an unchanged source offset must not reset
    // the user's scroll position.
    var rebuild_nodes: [4]canvas.WidgetLayoutNode = undefined;
    const rebuild_layout = try canvas.layoutWidgetTree(source_root, geometry.RectF.init(0, 0, 180, 64), &rebuild_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", rebuild_layout);
    try std.testing.expectEqual(@as(f32, 18), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(1).?.widget.value);

    // A source-side offset change (programmatic scroll) wins over the
    // runtime offset.
    var scrolled_root = source_root;
    scrolled_root.value = 6;
    var programmatic_nodes: [4]canvas.WidgetLayoutNode = undefined;
    const programmatic_layout = try canvas.layoutWidgetTree(scrolled_root, geometry.RectF.init(0, 0, 180, 64), &programmatic_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", programmatic_layout);
    try std.testing.expectEqual(@as(f32, 6), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(1).?.widget.value);

    // And the runtime owns it again from the new baseline.
    var final_nodes: [4]canvas.WidgetLayoutNode = undefined;
    const final_layout = try canvas.layoutWidgetTree(scrolled_root, geometry.RectF.init(0, 0, 180, 64), &final_nodes);
    try harness.runtime.dispatchAutomationCommand(app, "widget-wheel canvas 1 12");
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", final_layout);
    try std.testing.expectEqual(@as(f32, 18), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(1).?.widget.value);
}

test "engine wheel scrolls a windowed virtual list against its declared extent" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-virtual-window-scroll", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 180, 64),
    });

    // A 1000-item windowed virtual list mounting a four-row window.
    // Legacy virtualized containers refuse engine scrolling (their offset
    // is model-driven); the DECLARED count makes this one runtime-owned.
    const window = [_]canvas.Widget{
        .{ .id = 2, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 0" },
        .{ .id = 3, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 1" },
        .{ .id = 4, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 2" },
        .{ .id = 5, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 3" },
    };
    const list = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .layout = .{
            .virtualized = true,
            .virtual_item_extent = 20,
            .virtual_overscan = 1,
            .virtual_item_count = 1000,
        },
        .children = &window,
    };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(list, geometry.RectF.init(0, 0, 180, 64), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Wheel input applies through the ordinary engine scroll path.
    try harness.runtime.dispatchAutomationCommand(app, "widget-wheel canvas 1 30");
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 30), retained.findById(1).?.widget.value);

    // The scroll state reports the DECLARED virtual extent (1000 x 20),
    // not the four mounted rows.
    const state = harness.runtime.views[0].canvasWidgetScrollStateById(1).?;
    try std.testing.expectEqual(@as(f32, 20_000), state.content_extent_y);
    try std.testing.expectEqual(@as(f32, 64), state.viewport_extent_y);

    // A rebuild whose source offset overshoots the end clamps against
    // the virtual extent (max offset 20_000 - 64).
    var overshoot = list;
    overshoot.value = 30_000;
    var overshoot_nodes: [8]canvas.WidgetLayoutNode = undefined;
    const overshoot_layout = try canvas.layoutWidgetTree(overshoot, geometry.RectF.init(0, 0, 180, 64), &overshoot_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", overshoot_layout);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 19_936), retained.findById(1).?.widget.value);
}

test "runtime wheel delta_x scrolls a horizontal scroll view and quiets its vertical axis" {
    const TestApp = struct {
        scroll_event_count: u32 = 0,
        last_scroll: canvas.ScrollState = .{},

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-horizontal-scroll", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_scroll => |scroll_event| {
                    self.scroll_event_count += 1;
                    self.last_scroll = scroll_event.scroll;
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

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });

    // A shelf: three fixed-width tiles in a row, reaching x = 460 inside
    // a 180-wide viewport (max horizontal offset 280).
    const tiles = [_]canvas.Widget{
        .{ .id = 2, .kind = .panel, .frame = geometry.RectF.init(0, 0, 140, 60) },
        .{ .id = 3, .kind = .panel, .frame = geometry.RectF.init(160, 0, 140, 60) },
        .{ .id = 4, .kind = .panel, .frame = geometry.RectF.init(320, 0, 140, 60) },
    };
    const shelf = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .scroll_axes = .horizontal,
        .children = &tiles,
    };
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(shelf, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // A diagonal wheel: delta_x scrolls the shelf, delta_y dies (the
    // region grants no vertical axis).
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .timestamp_ns = 1_000_000_000,
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_x = 24,
        .delta_y = 16,
    } });

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 24), retained.findById(1).?.widget.value_x);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(1).?.widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(-24, 0, 140, 60), retained.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(136, 0, 140, 60), retained.findById(3).?.frame);

    // The observation delivers the two-axis state: a live horizontal
    // axis and a QUIET vertical one (content pinned to the viewport).
    try std.testing.expectEqual(@as(u32, 1), app_state.scroll_event_count);
    try std.testing.expectEqual(@as(f32, 24), app_state.last_scroll.offset_x);
    try std.testing.expectEqual(@as(f32, 180), app_state.last_scroll.viewport_extent_x);
    try std.testing.expectEqual(@as(f32, 460), app_state.last_scroll.content_extent_x);
    try std.testing.expectEqual(@as(f32, 0), app_state.last_scroll.offset_y);
    try std.testing.expectEqual(@as(f32, 72), app_state.last_scroll.content_extent_y);
    try std.testing.expectEqual(@as(f32, 0), app_state.last_scroll.axis(.vertical).maxOffset());

    // The wheel left horizontal momentum for the kinetic stepper.
    try std.testing.expect(harness.runtime.views[0].widget_scroll_states[0].velocity_x > 0);
    try std.testing.expectEqual(@as(f32, 0), harness.runtime.views[0].widget_scroll_states[0].velocity_y);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(180, 72),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_016_000_000,
        .frame_interval_ns = 16_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(180, 72),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 1_032_000_000,
        .frame_interval_ns = 16_000_000,
    } });
    const stepped = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(stepped.findById(1).?.widget.value_x > 24);
    try std.testing.expectEqual(@as(f32, 0), stepped.findById(1).?.widget.value);
}

test "nested regions route each wheel axis to the nearest ancestor scrolling that axis" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-nested-axis-routing", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });

    // The reported nested shape: a HORIZONTAL timeline (id 1) holding a
    // VERTICAL list (id 2) whose rows overflow its height. The wheel
    // lands over the list.
    const rows = [_]canvas.Widget{
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 0, 120, 32), .text = "One" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 44, 120, 32), .text = "Two" },
        .{ .id = 5, .kind = .button, .frame = geometry.RectF.init(0, 88, 120, 32), .text = "Three" },
    };
    const inner = canvas.Widget{
        .id = 2,
        .kind = .scroll_view,
        .frame = geometry.RectF.init(0, 0, 120, 72),
        .children = &rows,
    };
    const spacer = canvas.Widget{ .id = 6, .kind = .panel, .frame = geometry.RectF.init(130, 0, 300, 60) };
    const timeline = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .scroll_axes = .horizontal,
        .children = &.{ inner, spacer },
    };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(timeline, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // One diagonal gesture over the inner list: delta_y scrolls the
    // LIST (the nearest vertical scrollable), delta_x passes through it
    // to the TIMELINE (the nearest horizontal scrollable).
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .timestamp_ns = 1_000_000_000,
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_x = 30,
        .delta_y = 24,
    } });

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 24), retained.findById(2).?.widget.value);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(2).?.widget.value_x);
    try std.testing.expectEqual(@as(f32, 30), retained.findById(1).?.widget.value_x);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(1).?.widget.value);
    // The list's rows moved UP by the consumed delta_y AND left by the
    // timeline's consumed delta_x (the list itself rides the timeline).
    try std.testing.expectEqualDeep(geometry.RectF.init(-30, -24, 120, 32), retained.findById(3).?.frame);

    // A purely horizontal follow-up over the same point keeps the list
    // still and moves only the timeline.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .timestamp_ns = 1_032_000_000,
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_x = 10,
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 24), retained.findById(2).?.widget.value);
    try std.testing.expectEqual(@as(f32, 40), retained.findById(1).?.widget.value_x);
}

test "horizontal-only scroll views take the whole keymap on their one axis" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-horizontal-keymap", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });

    const tiles = [_]canvas.Widget{
        .{ .id = 2, .kind = .panel, .frame = geometry.RectF.init(0, 0, 140, 60) },
        .{ .id = 3, .kind = .panel, .frame = geometry.RectF.init(160, 0, 140, 60) },
        .{ .id = 4, .kind = .panel, .frame = geometry.RectF.init(320, 0, 140, 60) },
    };
    const shelf = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .scroll_axes = .horizontal,
        .children = &tiles,
    };
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(shelf, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 1;

    // ArrowRight steps a line on the ONE axis the region grants: the
    // viewport-width-derived step (max(24, 180 * 0.35) = 63).
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowright",
    } });
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 63), retained.findById(1).?.widget.value_x);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(1).?.widget.value);

    // End jumps to the horizontal terminus (content 460 - viewport 180).
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "end",
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 280), retained.findById(1).?.widget.value_x);
    try std.testing.expectEqualDeep(geometry.RectF.init(-280, 0, 140, 60), retained.findById(2).?.frame);

    // Home returns to the origin.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "home",
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0), retained.findById(1).?.widget.value_x);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 140, 60), retained.findById(2).?.frame);
}
