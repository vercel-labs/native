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

test "runtime exposes retained canvas widget text geometry" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-geometry", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
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

    var harness: TestHarness() = undefined;
    harness.init(.{});
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
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);

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
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "backspace",
    } });
    try std.testing.expectEqual(@as(u64, 3), harness.runtime.views[0].widget_revision);
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
    try std.testing.expectEqual(@as(u64, 4), harness.runtime.views[0].widget_revision);
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
    try std.testing.expectEqual(@as(u64, 5), harness.runtime.views[0].widget_revision);
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
    try std.testing.expectEqual(@as(u64, 6), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowright",
        .modifiers = .{ .command = true },
    } });
    try std.testing.expectEqual(@as(u64, 7), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(1), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowup",
    } });
    try std.testing.expectEqual(@as(u64, 8), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowdown",
    } });
    try std.testing.expectEqual(@as(u64, 9), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(1), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "escape",
    } });
    try std.testing.expectEqual(@as(u64, 9), harness.runtime.views[0].widget_revision);
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

    var harness: TestHarness() = undefined;
    harness.init(.{});
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

test "runtime applies ime composition edits to canvas text fields" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-ime", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
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
            .fill_rounded_rect => |fill| {
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
            .draw_line => |line| {
                if (line.id == testCanvasWidgetPartId(2, 5)) saw_composition_underline = true;
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

    var harness: TestHarness() = undefined;
    harness.init(.{});
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

    var harness: TestHarness() = undefined;
    harness.init(.{});
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

    var harness: TestHarness() = undefined;
    harness.init(.{});
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

    var harness: TestHarness() = undefined;
    harness.init(.{});
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

    var harness: TestHarness() = undefined;
    harness.init(.{});
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

    var harness: TestHarness() = undefined;
    harness.init(.{});
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

    var harness: TestHarness() = undefined;
    harness.init(.{});
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
            .fill_rounded_rect => |fill| {
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

    var harness: TestHarness() = undefined;
    harness.init(.{});
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

    var harness: TestHarness() = undefined;
    harness.init(.{});
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

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 188,
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
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);

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
            .draw_line => |line| {
                if (line.id == testCanvasWidgetPartId(2, 3)) {
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
    try std.testing.expectEqual(@as(u64, 3), harness.runtime.views[0].widget_revision);

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
    try std.testing.expectEqual(@as(u64, 4), harness.runtime.views[0].widget_revision);

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
    try std.testing.expectEqual(@as(u64, 5), harness.runtime.views[0].widget_revision);

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
