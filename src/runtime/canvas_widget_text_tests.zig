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

test "the builder's presented-text store mirrors the per-view draw-text budget" {
    // The chart path-element lockstep's sibling: presented single-line
    // bytes persist into `Builder.text_bytes`, and the store can only
    // overflow (falling back to raw bytes under the forced clip) on a
    // frame the runtime's per-view display-list copy would refuse
    // anyway. Keep the two budgets from drifting.
    try std.testing.expectEqual(
        @import("canvas_limits.zig").max_canvas_text_bytes_per_view,
        canvas.max_display_list_text_bytes,
    );
}

test "runtime exposes retained canvas widget text geometry" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-geometry", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 240, 160),
    });

    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .text_field,
            .frame = geometry.RectF.init(12, 16, 160, 36),
            .text = "Search",
            .text_selection = canvas.TextSelection.collapsed(3),
        },
        .{
            .id = 3,
            .kind = .search_field,
            .frame = geometry.RectF.init(12, 60, 160, 36),
            .text = "Cafe",
            .text_selection = .{ .anchor = 1, .focus = 4 },
            .text_composition = canvas.TextRange.init(2, 4),
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(12, 108, 120, 32),
            .text = "Run",
        },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 240, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const caret = try harness.runtime.canvasWidgetTextGeometry(1, "canvas", 2);
    try std.testing.expect(caret.caret_bounds != null);
    try std.testing.expect(caret.selection_bounds == null);
    try std.testing.expectEqual(@as(usize, 0), caret.selection_rect_count);
    try std.testing.expect(caret.composition_bounds == null);

    const range = try harness.runtime.canvasWidgetTextGeometry(1, "canvas", 3);
    try std.testing.expect(range.caret_bounds == null);
    try std.testing.expect(range.selection_bounds != null);
    try std.testing.expectEqual(@as(usize, 1), range.selection_rect_count);
    try std.testing.expect(range.composition_bounds != null);
    try std.testing.expectEqual(@as(usize, 1), range.composition_rect_count);

    try std.testing.expectError(error.InvalidCommand, harness.runtime.canvasWidgetTextGeometry(1, "canvas", 0));
    try std.testing.expectError(error.InvalidCommand, harness.runtime.canvasWidgetTextGeometry(1, "canvas", 4));
    try std.testing.expectError(error.InvalidCommand, harness.runtime.canvasWidgetTextGeometry(1, "canvas", 99));
}

test "runtime applies text input to focused canvas text fields" {
    const TestApp = struct {
        widget_keyboard_count: u32 = 0,
        widget_text_input_count: u32 = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-edit", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_keyboard => |keyboard_event| {
                    self.widget_keyboard_count += 1;
                    if (keyboard_event.keyboard.phase == .text_input) self.widget_text_input_count += 1;
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

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Query",
        .semantics = .{ .label = "Search" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 168,
        .y = 24,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "a",
        .text = "a",
    } });
    try std.testing.expectEqual(@as(u32, 2), app_state.widget_keyboard_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_text_input_count);
    try std.testing.expectEqual(@as(u64, 3), harness.runtime.views[0].widget_revision);

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Querya", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(6), retained.nodes[1].widget.text_selection.?);
    try std.testing.expect(retained.nodes[1].widget.text_composition == null);

    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 1), snapshot.widgets.len);
    try std.testing.expectEqualStrings("Search", snapshot.widgets[0].name);
    try std.testing.expectEqualStrings("Querya", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 6, .end = 6 }, snapshot.widgets[0].text_selection.?);
    try std.testing.expect(snapshot.widgets[0].text_composition == null);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    var display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_inserted_text = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualStrings("Querya", text.text);
                    saw_inserted_text = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_inserted_text);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "b",
        .text = "b",
        .modifiers = .{ .primary = true, .command = true },
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Querya", retained.nodes[1].widget.text);
    try std.testing.expectEqual(@as(u64, 3), harness.runtime.views[0].widget_revision);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "backspace",
    } });
    try std.testing.expectEqual(@as(u64, 4), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Query", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "a",
        .text = "a",
        .modifiers = .{ .primary = true, .command = true },
    } });
    try std.testing.expectEqual(@as(u64, 5), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Query", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 5 }, retained.nodes[1].widget.text_selection.?);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Query", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 0, .end = 5 }, snapshot.widgets[0].text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "x",
        .text = "x",
    } });
    try std.testing.expectEqual(@as(u64, 6), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("x", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(1), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowleft",
        .modifiers = .{ .command = true },
    } });
    try std.testing.expectEqual(@as(u64, 7), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowright",
        .modifiers = .{ .command = true },
    } });
    try std.testing.expectEqual(@as(u64, 8), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(1), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowup",
    } });
    try std.testing.expectEqual(@as(u64, 9), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowdown",
    } });
    try std.testing.expectEqual(@as(u64, 10), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(1), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "escape",
    } });
    try std.testing.expectEqual(@as(u64, 10), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("x", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(1), retained.nodes[1].widget.text_selection.?);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_deleted_text = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualStrings("x", text.text);
                    saw_deleted_text = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_deleted_text);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Search", snapshot.widgets[0].name);
    try std.testing.expectEqualStrings("x", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(canvas.TextRange.init(1, 1), runtimeViewWidgetSemantics(&harness.runtime.views[0])[0].text_selection.?);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 1, .end = 1 }, snapshot.widgets[0].text_selection.?);
    try std.testing.expect(snapshot.widgets[0].text_composition == null);
}

test "runtime applies text input to canvas textareas" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-textarea-edit", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 260, 160),
    });

    const textarea = canvas.Widget{
        .id = 2,
        .kind = .textarea,
        .frame = geometry.RectF.init(12, 16, 180, 84),
        .text = "First",
        .semantics = .{ .label = "Message" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{textarea} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 188,
        .y = 28,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "!",
        .text = "!",
    } });
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("First!", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(6), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
        .modifiers = .{ .shift = true },
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("First!\n", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(7), retained.nodes[1].widget.text_selection.?);
    const newline_geometry = try harness.runtime.canvasWidgetTextGeometry(1, "canvas", 2);
    try std.testing.expect(newline_geometry.caret_bounds.?.y > textarea.frame.y + 24);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowleft",
        .modifiers = .{ .command = true },
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowright",
        .modifiers = .{ .command = true },
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(7), retained.nodes[1].widget.text_selection.?);

    const textarea_revision = harness.runtime.views[0].widget_revision;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowup",
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowdown",
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(u64, textarea_revision), harness.runtime.views[0].widget_revision);
    try std.testing.expectEqualStrings("First!\n", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(7), retained.nodes[1].widget.text_selection.?);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .insert_text = "Second" });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("First!\nSecond", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(13), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(13, 13), runtimeViewWidgetSemantics(&harness.runtime.views[0])[0].text_selection.?);

    const text_geometry = try harness.runtime.canvasWidgetTextGeometry(1, "canvas", 2);
    try std.testing.expect(text_geometry.caret_bounds != null);
    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Message", snapshot.widgets[0].name);
    try std.testing.expectEqualStrings("First!\nSecond", snapshot.widgets[0].text_value);
    try std.testing.expect(snapshot.widgets[0].actions.set_text);
    try std.testing.expect(snapshot.widgets[0].actions.set_selection);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_textarea_text = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualStrings("First!\nSecond", text.text);
                    try std.testing.expect(text.text_layout != null);
                    try std.testing.expectEqual(canvas.TextWrap.word, text.text_layout.?.wrap);
                    saw_textarea_text = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_textarea_text);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .insert_text = "\nThird\nFourth\nFifth\nSixth\nSeventh\nEighth" });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.nodes[1].widget.value > 0);
    try std.testing.expect(canvas.textInputMaxScrollOffsetForWidget(retained.nodes[1].widget, .{}) > 0);
    const scrolled_viewport = canvas.textInputViewportForWidget(retained.nodes[1].widget, .{}).?;
    const scrolled_geometry = try harness.runtime.canvasWidgetTextGeometry(1, "canvas", 2);
    const scrolled_caret = scrolled_geometry.caret_bounds.?;
    try std.testing.expect(scrolled_caret.y >= scrolled_viewport.y - 0.001);
    try std.testing.expect(scrolled_caret.maxY() <= scrolled_viewport.maxY() + 0.001);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const scrolled_display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_textarea_clip = false;
    for (scrolled_display_list.commands) |command| {
        switch (command) {
            .push_clip => |clip| {
                if (clip.id == testCanvasWidgetPartId(2, 16)) {
                    try std.testing.expectEqualDeep(scrolled_viewport, clip.rect);
                    saw_textarea_clip = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_textarea_clip);
}

test "plain Enter inserts a newline in a canvas textarea; chorded Enter never edits" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-textarea-enter", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 260, 160),
    });

    const textarea = canvas.Widget{
        .id = 2,
        .kind = .textarea,
        .frame = geometry.RectF.init(12, 16, 180, 84),
        .text = "First",
        .semantics = .{ .label = "Message" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{textarea} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 188,
        .y = 28,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);

    // A multi-line editor treats plain Enter as an EDIT (the macOS host
    // delivers Return as a bare `enter` keydown with no text payload).
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
    } });
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("First\n", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(6), retained.nodes[1].widget.text_selection.?);

    // The primary chord (submit) and the alt variant never edit the text.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
        .modifiers = .{ .command = true },
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
        .modifiers = .{ .option = true },
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("First\n", retained.nodes[1].widget.text);
}

test "Enter in a single-line input never inserts, even when the host stuffs a newline into the key event" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-input-enter", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 260, 160),
    });

    const input = canvas.Widget{
        .id = 2,
        .kind = .input,
        .frame = geometry.RectF.init(12, 16, 180, 32),
        .text = "Draft",
        .semantics = .{ .label = "Title" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{input} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 100,
        .y = 30,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "a",
        .modifiers = .{ .primary = true, .command = true },
    } });

    // The macOS-host shape: Return as a bare `enter` keydown. Enter in a
    // single-line field submits; it is NOT an edit.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
    } });
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Draft", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 5 }, retained.nodes[1].widget.text_selection.?);

    // A host that stuffs the newline into the key event's text payload
    // still edits nothing: the sanitized insert strips to empty and
    // suppresses — the live selection is not deleted.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
        .text = "\n",
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
        .text = "\r",
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Draft", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 5 }, retained.nodes[1].widget.text_selection.?);
}

test "automation set_text with line breaks lands sanitized in single-line fields and raw in textareas" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-set-text-breaks", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 220),
    });

    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .search_field,
            .frame = geometry.RectF.init(12, 16, 200, 36),
            .text = "",
            .semantics = .{ .label = "Query" },
        },
        .{
            .id = 3,
            .kind = .textarea,
            .frame = geometry.RectF.init(12, 64, 280, 100),
            .text = "",
            .semantics = .{ .label = "Notes" },
        },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 220), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Automation set_text rides the REAL text-input event path, so its
    // line breaks sanitize at the same seam a paste does.
    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 2, .action = .set_text, .value = "edge\ncustomers\r\nfirst" });
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("edgecustomersfirst", retained.nodes[1].widget.text);

    // The textarea takes the same payload verbatim.
    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 3, .action = .set_text, .value = "edge\ncustomers\r\nfirst" });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("edge\ncustomers\r\nfirst", retained.nodes[2].widget.text);
}

test "ime composition with a newline sanitizes into single-line fields before commit" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-ime-newline", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 260, 120),
    });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 180, 36),
        .text = "Cafe",
        .semantics = .{ .label = "Name" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 260, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 100,
        .y = 30,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);

    // A composition PREVIEW carrying a newline sanitizes at the same
    // seam every insert does — the preview in the retained editor holds
    // the stripped bytes, so the COMMIT (which lands whatever the
    // preview holds) can never commit a line break.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .ime_set_composition,
        .text = " au\nlait",
        .composition_cursor = 8,
    } });
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Cafe aulait", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextRange.init(4, 11), retained.nodes[1].widget.text_composition.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .ime_commit_composition,
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Cafe aulait", retained.nodes[1].widget.text);
    try std.testing.expect(retained.nodes[1].widget.text_composition == null);
}

test "a model-set single-line value with a newline paints one line inside the field" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-value-newline", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 120),
    });

    // A Zig core can put a newline into a field's VALUE today; the
    // sanitize seam only guards EDITS. The retained value keeps the raw
    // bytes (semantics and automation report honestly), but the painted
    // text presents the breaks as spaces on ONE line, under a forced
    // content-rect clip — nothing escapes the rounded border.
    const input = canvas.Widget{
        .id = 2,
        .kind = .input,
        .frame = geometry.RectF.init(12, 16, 200, 32),
        .text = "one\ntwo",
        .semantics = .{ .label = "Title" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{input} }, geometry.RectF.init(0, 0, 320, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_presented_text = false;
    var saw_clip = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 3)) {
                    try std.testing.expectEqualStrings("one two", text.text);
                    saw_presented_text = true;
                }
            },
            .push_clip => |clip| {
                if (clip.id == testCanvasWidgetPartId(2, 16)) saw_clip = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_presented_text);
    try std.testing.expect(saw_clip);

    // Semantics (and therefore automation and assistive tech) still read
    // the RAW model value: presentation never rewrites the model.
    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("one\ntwo", snapshot.widgets[0].text_value);
}

test "runtime applies ime composition edits to canvas text fields" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-ime", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(20, 30, 240, 120),
    });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Cafe",
        .semantics = .{ .label = "Name" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_selection = .{ .anchor = 3, .focus = 4 } });
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);
    var display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_selected_text = false;
    var saw_selection_fill = false;
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(2, 3)) saw_selection_fill = true;
            },
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualStrings("Cafe", text.text);
                    saw_selected_text = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_selected_text);
    try std.testing.expect(saw_selection_fill);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_composition = .{ .text = "\xc3\xa9", .cursor = 2 } });
    try std.testing.expectEqual(@as(u64, 3), harness.runtime.views[0].widget_revision);

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(3, 5), retained.nodes[1].widget.text_composition.?);
    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_composed_text = false;
    var saw_composition_underline = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualStrings("Caf\xc3\xa9", text.text);
                    saw_composed_text = true;
                }
            },
            .fill_rect => |bar| {
                if (bar.id == testCanvasWidgetPartId(2, 5)) saw_composition_underline = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_composed_text);
    try std.testing.expect(saw_composition_underline);

    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Name", snapshot.widgets[0].name);
    try std.testing.expectEqualStrings("Caf\xc3\xa9", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 5, .end = 5 }, snapshot.widgets[0].text_selection.?);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 3, .end = 5 }, snapshot.widgets[0].text_composition.?);

    var a11y_buffer: [1024]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "text=\"Caf\xc3\xa9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "composition=3..5") != null);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .commit_composition);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expect(retained.nodes[1].widget.text_composition == null);
    try std.testing.expectEqual(@as(u64, 4), harness.runtime.views[0].widget_revision);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_composition = .{ .text = " noir", .cursor = 5 } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9 noir", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextRange.init(5, 10), retained.nodes[1].widget.text_composition.?);
    try std.testing.expectEqual(@as(u64, 5), harness.runtime.views[0].widget_revision);

    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 2;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "escape",
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);
    try std.testing.expect(retained.nodes[1].widget.text_composition == null);
    try std.testing.expectEqual(@as(u64, 6), harness.runtime.views[0].widget_revision);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", snapshot.widgets[0].text_value);
    try std.testing.expect(snapshot.widgets[0].text_composition == null);

    try std.testing.expectError(error.InvalidCommand, harness.runtime.editCanvasWidgetText(1, "canvas", 99, .commit_composition));
}

test "runtime clips canvas widget text edit dirty bounds to scroll ancestors" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-clipped-text-dirty", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 160, 48),
    });

    const partially_visible_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(0, 40, 0, 32),
        .text = "Draft",
    }};
    var partially_visible_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const partially_visible_layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &partially_visible_children },
        geometry.RectF.init(0, 0, 160, 48),
        &partially_visible_nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", partially_visible_layout);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .insert_text = "!" });
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 60, 160, 8), harness.runtime.pendingDirtyRegions()[0]);

    const fully_clipped_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(0, 64, 0, 32),
        .text = "Draft",
    }};
    var fully_clipped_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const fully_clipped_layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &fully_clipped_children },
        geometry.RectF.init(0, 0, 160, 48),
        &fully_clipped_nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", fully_clipped_layout);

    try std.testing.expectError(error.InvalidCommand, harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .insert_text = "!" }));
}

test "runtime clips canvas widget control dirty bounds to scroll ancestors" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-clipped-control-dirty", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 160, 48),
    });

    const children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .list_item,
        .frame = geometry.RectF.init(0, 40, 0, 32),
        .text = "Partially visible",
    }};
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &children },
        geometry.RectF.init(0, 0, 160, 48),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const dirty = try runtimeViewSetCanvasWidgetSelected(&harness.runtime.views[0], 2, true);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 40, 160, 8), dirty.?);
}

test "runtime reconciles canvas text edit state across layout replacement" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-reconcile", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(20, 30, 260, 140),
    });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Cafe",
        .semantics = .{ .label = "Name" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 260, 140), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_selection = .{ .anchor = 1, .focus = 4 } });

    const moved_text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(20, 24, 180, 36),
        .text = "Cafe",
        .semantics = .{ .label = "Name" },
    };
    var moved_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const moved_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{moved_text_field} }, geometry.RectF.init(0, 0, 260, 140), &moved_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", moved_layout);

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Cafe", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 1, .focus = 4 }, retained.nodes[1].widget.text_selection.?);
    try std.testing.expect(retained.nodes[1].widget.text_composition == null);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_composition = .{ .text = "af\xc3\xa9", .cursor = 4 } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(1, 5), retained.nodes[1].widget.text_composition.?);

    const composed_text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(24, 28, 184, 36),
        .text = "Caf\xc3\xa9",
        .semantics = .{ .label = "Name" },
    };
    var composed_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const composed_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{composed_text_field} }, geometry.RectF.init(0, 0, 260, 140), &composed_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", composed_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(1, 5), retained.nodes[1].widget.text_composition.?);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 5, .end = 5 }, snapshot.widgets[0].text_selection.?);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 1, .end = 5 }, snapshot.widgets[0].text_composition.?);

    const replaced_text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(24, 28, 184, 36),
        .text = "Reset",
        .semantics = .{ .label = "Name" },
    };
    var replaced_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const replaced_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{replaced_text_field} }, geometry.RectF.init(0, 0, 260, 140), &replaced_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", replaced_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Reset", retained.nodes[1].widget.text);
    try std.testing.expect(retained.nodes[1].widget.text_selection == null);
    try std.testing.expect(retained.nodes[1].widget.text_composition == null);
}

test "runtime preserves canvas text edits across unchanged source layout replacement" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-source-reconcile", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(20, 30, 260, 140),
    });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Draft",
        .semantics = .{ .label = "Name" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 260, 140), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_selection = canvas.TextSelection.collapsed(5) });
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .insert_text = " updated" });

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Draft updated", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(13), retained.nodes[1].widget.text_selection.?);

    const moved_text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(24, 28, 184, 36),
        .text = "Draft",
        .semantics = .{ .label = "Name" },
    };
    var moved_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const moved_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{moved_text_field} }, geometry.RectF.init(0, 0, 260, 140), &moved_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", moved_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Draft updated", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(13), retained.nodes[1].widget.text_selection.?);

    const replaced_text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(24, 28, 184, 36),
        .text = "Reset",
        .semantics = .{ .label = "Name" },
    };
    var replaced_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const replaced_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{replaced_text_field} }, geometry.RectF.init(0, 0, 260, 140), &replaced_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", replaced_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Reset", retained.nodes[1].widget.text);
    try std.testing.expect(retained.nodes[1].widget.text_selection == null);
}

test "runtime avoids dirty regions for reconciled canvas text edit layout replacement" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-reconcile-dirty", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(20, 30, 260, 140),
    });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Cafe",
        .semantics = .{ .label = "Name" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 260, 140), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_selection = .{ .anchor = 1, .focus = 4 } });
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_composition = .{ .text = "af\xc3\xa9", .cursor = 4 } });

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(1, 5), retained.nodes[1].widget.text_composition.?);

    const refreshed_text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Caf\xc3\xa9",
        .semantics = .{ .label = "Name" },
    };
    var refreshed_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const refreshed_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{refreshed_text_field} }, geometry.RectF.init(0, 0, 260, 140), &refreshed_nodes);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", refreshed_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(1, 5), retained.nodes[1].widget.text_composition.?);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);
}

test "runtime drops canvas text edit state when layout replacement disables text field" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-disabled-text-reconcile", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(20, 30, 260, 140),
    });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Cafe",
        .semantics = .{ .label = "Name" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 260, 140), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    harness.runtime.views[0].canvas_widget_focused_id = 2;
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_selection = .{ .anchor = 1, .focus = 4 } });
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_composition = .{ .text = "af\xc3\xa9", .cursor = 4 } });

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(1, 5), retained.nodes[1].widget.text_composition.?);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);

    const disabled_text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(24, 28, 184, 36),
        .text = "Caf\xc3\xa9",
        .state = .{ .disabled = true },
        .semantics = .{ .label = "Name" },
    };
    var disabled_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const disabled_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{disabled_text_field} }, geometry.RectF.init(0, 0, 260, 140), &disabled_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", disabled_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expect(retained.nodes[1].widget.text_selection == null);
    try std.testing.expect(retained.nodes[1].widget.text_composition == null);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 1), snapshot.widgets.len);
    try std.testing.expectEqualStrings("Caf\xc3\xa9", snapshot.widgets[0].text_value);
    try std.testing.expect(!snapshot.widgets[0].enabled);
    try std.testing.expect(!snapshot.widgets[0].focused);
    try std.testing.expect(snapshot.widgets[0].text_selection == null);
    try std.testing.expect(snapshot.widgets[0].text_composition == null);
}

test "runtime applies pointer selection to canvas text fields" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-pointer-selection", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Query",
        .semantics = .{ .label = "Search" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 24,
    } });
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(0, 0), runtimeViewWidgetSemantics(&harness.runtime.views[0])[0].text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_drag,
        .x = 47,
        .y = 24,
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 3 }, retained.nodes[1].widget.text_selection.?);
    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Query", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 0, .end = 3 }, snapshot.widgets[0].text_selection.?);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const selected_display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_selection_fill = false;
    for (selected_display_list.commands) |command| {
        switch (command) {
            .fill_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(2, 3)) saw_selection_fill = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_selection_fill);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "X",
        .text = "X",
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Xry", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(1), retained.nodes[1].widget.text_selection.?);
    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Xry", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 1, .end = 1 }, snapshot.widgets[0].text_selection.?);
}

test "runtime maps canvas text pointer selection with stored design tokens" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-pointer-token-selection", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Query",
        .semantics = .{ .label = "Search" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const tokens = canvas.DesignTokens{
        .typography = .{ .body_size = 20 },
    };
    _ = try harness.runtime.setCanvasWidgetDesignTokens(1, "canvas", tokens);

    const point = geometry.PointF.init(47, 24);
    const expected = canvas.textSelectionForWidgetPoint(text_field, point, null, tokens).?;
    const default_selection = canvas.textSelectionForWidgetPoint(text_field, point, null, .{}).?;
    try std.testing.expect(expected.focus != default_selection.focus);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = point.x,
        .y = point.y,
    } });

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(expected, retained.nodes[1].widget.text_selection.?);
}

test "runtime applies text input to focused canvas search fields" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-search-edit", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const search_field = canvas.Widget{
        .id = 2,
        .kind = .search_field,
        .frame = geometry.RectF.init(12, 16, 180, 36),
        .text = "Query",
        .semantics = .{ .label = "Search" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{search_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Mid-field, past the text's end but clear of the trailing
    // clear-affordance zone (which consumes presses instead of
    // placing the caret).
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 120,
        .y = 24,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "x",
        .text = "x",
    } });
    try std.testing.expectEqual(@as(u64, 3), harness.runtime.views[0].widget_revision);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Queryx", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(6), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(6, 6), runtimeViewWidgetSemantics(&harness.runtime.views[0])[0].text_selection.?);
    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Queryx", snapshot.widgets[0].text_value);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_search_icon = false;
    var saw_inserted_text = false;
    for (display_list.commands) |command| {
        switch (command) {
            // The magnifier is the vector `search` icon now: the circle
            // strokes as a path in the icon's first stroke slot.
            .stroke_path => |path| {
                if (path.id == testCanvasWidgetPartId(2, 4)) {
                    saw_search_icon = true;
                }
            },
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 9)) {
                    try std.testing.expectEqualStrings("Queryx", text.text);
                    saw_inserted_text = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_search_icon);
    try std.testing.expect(saw_inserted_text);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_composition = .{ .text = "ing", .cursor = 3 } });
    try std.testing.expectEqual(@as(u64, 4), harness.runtime.views[0].widget_revision);

    const composing = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Queryxing", composing.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(9), composing.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(6, 9), composing.nodes[1].widget.text_composition.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "escape",
    } });
    try std.testing.expectEqual(@as(u64, 5), harness.runtime.views[0].widget_revision);

    const restored = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Queryx", restored.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(6), restored.nodes[1].widget.text_selection.?);
    try std.testing.expect(restored.nodes[1].widget.text_composition == null);
    const restored_snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Queryx", restored_snapshot.widgets[0].text_value);
    try std.testing.expect(restored_snapshot.widgets[0].text_composition == null);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "escape",
    } });
    try std.testing.expectEqual(@as(u64, 6), harness.runtime.views[0].widget_revision);

    const cleared = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("", cleared.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), cleared.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(0, 0), runtimeViewWidgetSemantics(&harness.runtime.views[0])[0].text_selection.?);
    const cleared_snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("", cleared_snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 0, .end = 0 }, cleared_snapshot.widgets[0].text_selection.?);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const cleared_display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_search_placeholder = false;
    for (cleared_display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 9)) {
                    try std.testing.expectEqualStrings("Search", text.text);
                    saw_search_placeholder = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_search_placeholder);
}

test "search field clear affordance: press clears through the text-edit path" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-search-clear", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const search_field = canvas.Widget{
        .id = 2,
        .kind = .search_field,
        .frame = geometry.RectF.init(12, 16, 180, 36),
        .text = "Query",
        .semantics = .{ .label = "Search" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{search_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    const tokens = try harness.runtime.canvasWidgetDesignTokens(1, "canvas");

    // The x renders inside the field whenever it holds text — the icon
    // rect and the (wider) hit rect share geometry.
    const live = try harness.runtime.canvasWidgetLayout(1, "canvas");
    const icon_rect = canvas.textInputClearButtonRect(live.nodes[1].widget, tokens).?;
    const hit_rect = canvas.textInputClearButtonHitRect(live.nodes[1].widget, tokens).?;
    try std.testing.expect(hit_rect.containsRect(icon_rect));
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    var display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_clear_icon = false;
    for (display_list.commands) |command| {
        switch (command) {
            .stroke_path => |path| {
                // The x is two stroke shapes from slot 15: strokes land
                // on part slots 16 and 18.
                if (path.id == testCanvasWidgetPartId(2, 16)) saw_clear_icon = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_clear_icon);

    // Pressing inside the clear region clears the field through the
    // standard text-edit path — no caret placement, selection reset.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = icon_rect.x + icon_rect.width * 0.5,
        .y = icon_rect.y + icon_rect.height * 0.5,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = icon_rect.x + icon_rect.width * 0.5,
        .y = icon_rect.y + icon_rect.height * 0.5,
    } });
    const cleared = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("", cleared.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), cleared.nodes[1].widget.text_selection.?);

    // Empty field: no affordance, and a press at the same point places
    // the caret like any other in-field click instead of clearing.
    try std.testing.expect(canvas.textInputClearButtonRect(cleared.nodes[1].widget, tokens) == null);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    for (display_list.commands) |command| {
        switch (command) {
            .stroke_path => |path| try std.testing.expect(path.id != testCanvasWidgetPartId(2, 16)),
            else => {},
        }
    }

    // A disabled search field with text shows no affordance either.
    var disabled_field = search_field;
    disabled_field.state = .{ .disabled = true };
    try std.testing.expect(canvas.textInputClearButtonRect(disabled_field, tokens) == null);
    // Text fields and comboboxes never grow one (the combobox trailing
    // slot is the chevron's).
    var plain_field = search_field;
    plain_field.kind = .text_field;
    try std.testing.expect(canvas.textInputClearButtonRect(plain_field, tokens) == null);
    var combo_field = search_field;
    combo_field.kind = .combobox;
    try std.testing.expect(canvas.textInputClearButtonRect(combo_field, tokens) == null);
}

test "runtime click focus shows caret, ring, and blink; blur drops them" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-caret-affordances", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    // EMPTY field: the caret must appear even though the click's
    // computed selection equals the implied default (the short-circuit
    // that used to leave a clicked empty field caretless).
    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .placeholder = "Search",
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .timestamp_ns = 1_000_000_000,
        .x = 90,
        .y = 34,
    } });

    // Pointer focus on an editable renders the full focus affordances
    // (the :focus-visible contract text inputs have on every platform).
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focus_visible_id);

    var saw_caret = false;
    var saw_ring = false;
    var display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rect => |bar| {
                if (bar.id == testCanvasWidgetPartId(2, 6)) saw_caret = true;
            },
            .stroke_rect => |stroke| {
                if (stroke.id == testCanvasWidgetPartId(2, 7)) saw_ring = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_caret);
    try std.testing.expect(saw_ring);

    // The caret carries a LOOPING blink animation: still active far in
    // the future (frame scheduling keeps sampling it), fading between
    // full and zero opacity across a cycle.
    const view = &harness.runtime.views[0];
    try std.testing.expectEqual(testCanvasWidgetPartId(2, 6), view.canvas_widget_caret_blink_id);
    try std.testing.expect(view.canvasRenderAnimationsActive(1_000_000_000));
    try std.testing.expect(view.canvasRenderAnimationsActive(1_000_000_000 + 60 * std.time.ns_per_s));
    var overrides: [4]canvas.CanvasRenderOverride = undefined;
    // Solid through the post-activity hold...
    const held = try view.sampleCanvasRenderAnimations(1_000_000_000 + 400 * std.time.ns_per_ms, &overrides);
    try std.testing.expectEqual(@as(usize, 1), held.len);
    try std.testing.expectEqual(@as(f32, 1), held[0].opacity.?);
    // ...fully faded one sweep after the hold ends.
    const faded = try view.sampleCanvasRenderAnimations(1_000_000_000 + 1000 * std.time.ns_per_ms, &overrides);
    try std.testing.expectEqual(@as(usize, 1), faded.len);
    try std.testing.expectEqual(@as(f32, 0), faded[0].opacity.?);

    // View blur removes the blink animation and the focus affordances,
    // so the view can go idle (the wasm preview's park condition).
    view.focused = false;
    _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), view.canvas_widget_caret_blink_id);
    try std.testing.expectEqual(@as(usize, 0), view.canvas_render_animation_count);
    saw_caret = false;
    saw_ring = false;
    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rect => |bar| {
                if (bar.id == testCanvasWidgetPartId(2, 6)) saw_caret = true;
            },
            .stroke_rect => |stroke| {
                if (stroke.id == testCanvasWidgetPartId(2, 7)) saw_ring = true;
            },
            else => {},
        }
    }
    try std.testing.expect(!saw_caret);
    try std.testing.expect(!saw_ring);
}

test "typing into a textarea seeded with a long document survives dispatch" {
    // Live-crash regression: a textarea holding more wrapped lines than
    // the render-side caret query once buffered (16) killed the whole
    // app on the first keystroke — the caret emission failed with
    // TextLayoutLineListFull, the error escaped `dispatchGpuSurfaceInput`,
    // and the platform callback latched CallbackFailed. The harness's
    // `.propagate` policy makes any such escape fail this test.
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-textarea-long-doc", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 260, 160),
    });

    // ~40 source lines that wrap into even more layout lines at 180px.
    const doc = "The quick brown fox jumps over the lazy dog.\n" ** 40;
    const textarea = canvas.Widget{
        .id = 2,
        .kind = .textarea,
        .frame = geometry.RectF.init(12, 16, 180, 84),
        .text = doc,
        .semantics = .{ .label = "Markdown source" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{textarea} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Click into the document (focus + caret placement), then type.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 100,
        .y = 30,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "x",
        .text = "x",
    } });

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(doc.len + 1, retained.nodes[1].widget.text.len);
    try std.testing.expect(retained.nodes[1].widget.text_selection != null);

    // The emitted display list carries the caret for the focused,
    // collapsed-selection textarea (part 6 of the widget) — this exact
    // emission is what failed pre-fix.
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_caret = false;
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rect => |bar| {
                if (bar.id == testCanvasWidgetPartId(2, 6)) saw_caret = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_caret);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.dispatchErrors().len);
}

test "a widget text budget overflow on input degrades instead of exiting" {
    // Degrade-semantics regression: a runtime-side capacity error on a
    // keystroke (here the per-view widget text budget) must land in the
    // dispatch-error ring and refuse the edit — never escape
    // `dispatchPlatformEvent`, which would latch the platform callback's
    // failure flag and exit the app.
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-textarea-budget", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    // Production policy: errors degrade (the harness default propagates
    // so ordinary tests fail loud).
    harness.runtime.dispatch_error_policy = .degrade;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 260, 160),
    });

    // Fill the view's widget text storage to within 512 bytes of the
    // budget, so a 510-byte insert overflows the storage rewrite while
    // still fitting the edit-apply scratch.
    const filler = [_]u8{'a'} ** (runtime_module.max_canvas_widget_text_bytes_per_view - 512);
    const textarea = canvas.Widget{
        .id = 2,
        .kind = .textarea,
        .frame = geometry.RectF.init(12, 16, 180, 84),
        .text = &filler,
        .semantics = .{ .label = "Message" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{textarea} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 100,
        .y = 30,
    } });

    const burst = [_]u8{'b'} ** 510;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "b",
        .text = &burst,
    } });

    // The edit was refused, the error recorded, the app still running.
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(filler.len, retained.nodes[1].widget.text.len);
    const errors = harness.runtime.dispatchErrors();
    try std.testing.expect(errors.len >= 1);
    try std.testing.expectEqualStrings("gpu_surface_input", errors[errors.len - 1].event);
    try std.testing.expectEqualStrings("WidgetTextTooLarge", errors[errors.len - 1].error_name);

    // The next interaction dispatches clean.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowleft",
    } });
}

/// Scan the widget's frame for a pointer location whose caret offset is
/// exactly `target`, so multi-click tests aim at text offsets without
/// hard-coding font metrics.
fn pointForTextOffset(widget: canvas.Widget, tokens: canvas.DesignTokens, target: usize) ?geometry.PointF {
    var y: f32 = widget.frame.y + 2;
    while (y < widget.frame.y + widget.frame.height) : (y += 4) {
        var x: f32 = widget.frame.x + 1;
        while (x < widget.frame.x + widget.frame.width) : (x += 0.5) {
            const point = geometry.PointF.init(x, y);
            const offset = canvas.textOffsetForWidgetPoint(widget, point, tokens) orelse continue;
            if (offset == target) return point;
        }
    }
    return null;
}

fn dispatchTimedPointer(harness: *TestHarness(), app: App, kind: platform.GpuSurfaceInputKind, point: geometry.PointF, timestamp_ns: u64) !void {
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = kind,
        .timestamp_ns = timestamp_ns,
        .x = point.x,
        .y = point.y,
    } });
}

fn retainedTextSelection(harness: *TestHarness(), node_index: usize) !canvas.TextSelection {
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    return retained.nodes[node_index].widget.text_selection orelse error.TestExpectedSelection;
}

test "double-click selects the word run under the pointer; a slow second click only moves the caret" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-double-click-word", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 200),
    });

    // "hello, world" pins all three run classes in one field:
    // word (0..5), punctuation (5..6), whitespace (6..7), word (7..12).
    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 240, 36),
        .text = "hello, world",
        .semantics = .{ .label = "Message" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    const widget = (try harness.runtime.canvasWidgetLayout(1, "canvas")).nodes[1].widget;

    const ms = std.time.ns_per_ms;
    const in_word = pointForTextOffset(widget, .{}, 2).?;
    const on_comma = pointForTextOffset(widget, .{}, 5).?;
    const on_space = pointForTextOffset(widget, .{}, 6).?;
    const past_end = pointForTextOffset(widget, .{}, 12).?;

    // The chain's first click is a plain caret placement...
    try dispatchTimedPointer(harness, app, .pointer_down, in_word, 1_000 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(2), try retainedTextSelection(harness, 1));
    try dispatchTimedPointer(harness, app, .pointer_up, in_word, 1_030 * ms);
    // ...and the rapid second click selects the whole word.
    try dispatchTimedPointer(harness, app, .pointer_down, in_word, 1_200 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 5 }, try retainedTextSelection(harness, 1));
    try dispatchTimedPointer(harness, app, .pointer_up, in_word, 1_230 * ms);

    // Double-click on punctuation selects the punctuation cluster.
    try dispatchTimedPointer(harness, app, .pointer_down, on_comma, 3_000 * ms);
    try dispatchTimedPointer(harness, app, .pointer_up, on_comma, 3_030 * ms);
    try dispatchTimedPointer(harness, app, .pointer_down, on_comma, 3_100 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 5, .focus = 6 }, try retainedTextSelection(harness, 1));
    try dispatchTimedPointer(harness, app, .pointer_up, on_comma, 3_130 * ms);

    // Double-click on whitespace selects the gap, not a neighbor word.
    try dispatchTimedPointer(harness, app, .pointer_down, on_space, 5_000 * ms);
    try dispatchTimedPointer(harness, app, .pointer_up, on_space, 5_030 * ms);
    try dispatchTimedPointer(harness, app, .pointer_down, on_space, 5_100 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 6, .focus = 7 }, try retainedTextSelection(harness, 1));
    try dispatchTimedPointer(harness, app, .pointer_up, on_space, 5_130 * ms);

    // Double-click at (or past) the end of the text selects the
    // trailing run.
    try dispatchTimedPointer(harness, app, .pointer_down, past_end, 7_000 * ms);
    try dispatchTimedPointer(harness, app, .pointer_up, past_end, 7_030 * ms);
    try dispatchTimedPointer(harness, app, .pointer_down, past_end, 7_100 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 7, .focus = 12 }, try retainedTextSelection(harness, 1));
    try dispatchTimedPointer(harness, app, .pointer_up, past_end, 7_130 * ms);

    // A second click OUTSIDE the double-click window never chains: the
    // caret just moves, the platform single-click contract.
    try dispatchTimedPointer(harness, app, .pointer_down, in_word, 9_000 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(2), try retainedTextSelection(harness, 1));
    try dispatchTimedPointer(harness, app, .pointer_up, in_word, 9_030 * ms);
}

test "double-click never splits multibyte codepoints when selecting words" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-double-click-utf8", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 200),
    });

    // "héllo wörld": é and ö are two-byte codepoints, so byte runs are
    // héllo = 0..6, space = 6..7, wörld = 7..13.
    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 240, 36),
        .text = "h\xc3\xa9llo w\xc3\xb6rld",
        .semantics = .{ .label = "Message" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    const widget = (try harness.runtime.canvasWidgetLayout(1, "canvas")).nodes[1].widget;

    const ms = std.time.ns_per_ms;
    // Caret offset 8 sits between 'w' and 'ö', inside the second word.
    const in_accented_word = pointForTextOffset(widget, .{}, 8).?;
    try dispatchTimedPointer(harness, app, .pointer_down, in_accented_word, 1_000 * ms);
    try dispatchTimedPointer(harness, app, .pointer_up, in_accented_word, 1_030 * ms);
    try dispatchTimedPointer(harness, app, .pointer_down, in_accented_word, 1_100 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 7, .focus = 13 }, try retainedTextSelection(harness, 1));
    try dispatchTimedPointer(harness, app, .pointer_up, in_accented_word, 1_130 * ms);
}

test "double-click drag extends the selection by whole words in both directions" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-word-drag", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 360, 200),
    });

    // "alpha beta gamma": alpha = 0..5, beta = 6..10, gamma = 11..16.
    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 300, 36),
        .text = "alpha beta gamma",
        .semantics = .{ .label = "Message" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 360, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    const widget = (try harness.runtime.canvasWidgetLayout(1, "canvas")).nodes[1].widget;

    const ms = std.time.ns_per_ms;
    const in_beta = pointForTextOffset(widget, .{}, 8).?;
    const in_gamma = pointForTextOffset(widget, .{}, 13).?;
    const in_alpha = pointForTextOffset(widget, .{}, 2).?;

    // Double-click selects the anchor word.
    try dispatchTimedPointer(harness, app, .pointer_down, in_beta, 1_000 * ms);
    try dispatchTimedPointer(harness, app, .pointer_up, in_beta, 1_030 * ms);
    try dispatchTimedPointer(harness, app, .pointer_down, in_beta, 1_100 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 6, .focus = 10 }, try retainedTextSelection(harness, 1));

    // Dragging forward swallows gamma whole; the anchor word's start
    // holds the selection's anchor.
    try dispatchTimedPointer(harness, app, .pointer_drag, in_gamma, 1_150 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 6, .focus = 16 }, try retainedTextSelection(harness, 1));

    // Dragging back before the anchor word flips direction: the anchor
    // word's END anchors, the focus lands at alpha's start — the whole
    // anchor word stays selected.
    try dispatchTimedPointer(harness, app, .pointer_drag, in_alpha, 1_200 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 10, .focus = 0 }, try retainedTextSelection(harness, 1));

    // Returning inside the anchor word restores exactly the anchor word.
    try dispatchTimedPointer(harness, app, .pointer_drag, in_beta, 1_250 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 6, .focus = 10 }, try retainedTextSelection(harness, 1));
    try dispatchTimedPointer(harness, app, .pointer_up, in_beta, 1_300 * ms);
}

test "triple-click selects all in a single-line input and the clicked line in a textarea" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-triple-click", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 240, 36),
        .text = "hello world",
        .semantics = .{ .label = "Title" },
    };
    // "first line" = 0..10, '\n' at 10, "second line" = 11..22.
    const textarea = canvas.Widget{
        .id = 3,
        .kind = .textarea,
        .frame = geometry.RectF.init(12, 70, 240, 96),
        .text = "first line\nsecond line",
        .semantics = .{ .label = "Body" },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{ text_field, textarea } }, geometry.RectF.init(0, 0, 320, 240), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    const field_widget = retained.nodes[1].widget;
    const area_widget = retained.nodes[2].widget;

    const ms = std.time.ns_per_ms;

    // Triple-click in the single-line field selects the entire text.
    const in_field = pointForTextOffset(field_widget, .{}, 2).?;
    try dispatchTimedPointer(harness, app, .pointer_down, in_field, 1_000 * ms);
    try dispatchTimedPointer(harness, app, .pointer_up, in_field, 1_030 * ms);
    try dispatchTimedPointer(harness, app, .pointer_down, in_field, 1_100 * ms);
    try dispatchTimedPointer(harness, app, .pointer_up, in_field, 1_130 * ms);
    try dispatchTimedPointer(harness, app, .pointer_down, in_field, 1_200 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 11 }, try retainedTextSelection(harness, 1));
    try dispatchTimedPointer(harness, app, .pointer_up, in_field, 1_230 * ms);

    // Triple-click on the textarea's SECOND line selects that line's
    // text (the hard newline stays outside the selection).
    const in_second_line = pointForTextOffset(area_widget, .{}, 13).?;
    try dispatchTimedPointer(harness, app, .pointer_down, in_second_line, 3_000 * ms);
    try dispatchTimedPointer(harness, app, .pointer_up, in_second_line, 3_030 * ms);
    try dispatchTimedPointer(harness, app, .pointer_down, in_second_line, 3_100 * ms);
    try dispatchTimedPointer(harness, app, .pointer_up, in_second_line, 3_130 * ms);
    try dispatchTimedPointer(harness, app, .pointer_down, in_second_line, 3_200 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 11, .focus = 22 }, try retainedTextSelection(harness, 2));

    // Triple-click drag extends line-wise: dragging up onto the first
    // line selects both lines, anchored at the clicked line's end.
    const in_first_line = pointForTextOffset(area_widget, .{}, 2).?;
    try dispatchTimedPointer(harness, app, .pointer_drag, in_first_line, 3_250 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 22, .focus = 0 }, try retainedTextSelection(harness, 2));
    try dispatchTimedPointer(harness, app, .pointer_up, in_first_line, 3_300 * ms);
}

test "word selection feeds the shared selection state: copy and shift-arrow just work" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-word-select-interplay", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 200),
    });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 240, 36),
        .text = "hello world",
        .semantics = .{ .label = "Message" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    const widget = (try harness.runtime.canvasWidgetLayout(1, "canvas")).nodes[1].widget;

    const ms = std.time.ns_per_ms;
    const in_word = pointForTextOffset(widget, .{}, 2).?;
    try dispatchTimedPointer(harness, app, .pointer_down, in_word, 1_000 * ms);
    try dispatchTimedPointer(harness, app, .pointer_up, in_word, 1_030 * ms);
    try dispatchTimedPointer(harness, app, .pointer_down, in_word, 1_100 * ms);
    try dispatchTimedPointer(harness, app, .pointer_up, in_word, 1_130 * ms);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 5 }, try retainedTextSelection(harness, 1));

    // Copy reads the word selection through the same clipboard path
    // every selection uses.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "c",
        .modifiers = .{ .primary = true, .command = true },
    } });
    var clipboard_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try harness.runtime.readClipboard(&clipboard_buffer));

    // Shift-arrow extends from the word selection's focus — no special
    // casing, the selection is ordinary anchor/focus state.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowright",
        .modifiers = .{ .shift = true },
    } });
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 6 }, try retainedTextSelection(harness, 1));
}

test "runtime scrolls single-line fields horizontally to keep the caret visible" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-field-scroll", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 260, 160),
    });

    const field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 120, 32),
        .semantics = .{ .label = "Name" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{field} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 30,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);

    // A short value never scrolls: the offset channel stays at zero.
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .insert_text = "short" });
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0), retained.nodes[1].widget.value);

    // Typing past the field's span scrolls forward so the caret stays
    // inside the visible span; the emitted stream clips at the border.
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .insert_text = " value far too long for this narrow field to show" });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.nodes[1].widget.value > 0);
    try std.testing.expect(canvas.textInputMaxHorizontalScrollOffsetForWidget(retained.nodes[1].widget, .{}) > 0);
    const viewport = canvas.textInputViewportForWidget(retained.nodes[1].widget, .{}).?;
    const scrolled_geometry = try harness.runtime.canvasWidgetTextGeometry(1, "canvas", 2);
    const scrolled_caret = scrolled_geometry.caret_bounds.?;
    try std.testing.expect(scrolled_caret.x >= viewport.x - 0.001);
    try std.testing.expect(scrolled_caret.maxX() <= viewport.maxX() + 0.001);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_field_clip = false;
    for (display_list.commands) |command| {
        switch (command) {
            .push_clip => |clip| {
                if (clip.id == testCanvasWidgetPartId(2, 16)) {
                    try std.testing.expectEqualDeep(viewport, clip.rect);
                    saw_field_clip = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_field_clip);

    // The retained offset survives a source rebuild (the reconcile pass
    // restores it alongside the text), and the clamp pass re-checks the
    // caret against the new geometry.
    var rebuild_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const rebuild = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{field} }, geometry.RectF.init(0, 0, 260, 160), &rebuild_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", rebuild);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.nodes[1].widget.value > 0);

    // Home: the caret returns to byte zero and the field scrolls all the
    // way back.
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .move_caret = .{ .direction = .start } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqual(@as(f32, 0), retained.nodes[1].widget.value);

    // Deleting the overflow clamps the offset back to zero — the field
    // never shows trailing emptiness while text could fill it.
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .move_caret = .{ .direction = .end } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.nodes[1].widget.value > 0);
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_selection = .{ .anchor = 5, .focus = 55 } });
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .delete_backward);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("short", retained.nodes[1].widget.text);
    try std.testing.expectEqual(@as(f32, 0), retained.nodes[1].widget.value);
}
