//! Native context menu tests: a secondary-button press asks the
//! platform to present the OS menu (recorded by the null platform), the
//! platform's `context_menu_action` event resolves to a
//! `.canvas_widget_context_menu` runtime event for app-declared menus,
//! and the zero-code defaults (editable-text Cut/Copy/Paste/Select All,
//! static-selection Copy) drive the existing clipboard actions.

const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const canvas = support.canvas;
const platform = support.platform;
const automation = support.automation;
const App = support.App;
const Runtime = support.Runtime;
const Event = support.Event;
const TestHarness = support.TestHarness;
const canvas_limits = @import("canvas_limits.zig");

const MenuTestApp = struct {
    pointer_count: u32 = 0,
    raw_input_count: u32 = 0,
    menu_count: u32 = 0,
    last_menu_target: canvas.ObjectId = 0,
    last_menu_item_index: usize = 0,
    request_count: u32 = 0,
    last_request_target: canvas.ObjectId = 0,
    last_edit_insert: [64]u8 = undefined,
    last_edit_insert_len: usize = 0,
    saw_truncated: bool = false,

    fn app(self: *@This()) App {
        return .{ .context = self, .name = "context-menus", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
    }

    fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
        _ = runtime;
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event_value) {
            .canvas_widget_pointer => self.pointer_count += 1,
            .gpu_surface_input => self.raw_input_count += 1,
            .canvas_widget_context_menu => |menu_event| {
                self.menu_count += 1;
                self.last_menu_target = menu_event.target_id;
                self.last_menu_item_index = menu_event.item_index;
            },
            .canvas_widget_context_menu_request => |request_event| {
                self.request_count += 1;
                self.last_request_target = request_event.target_id;
            },
            .canvas_widget_keyboard => |keyboard_event| {
                if (keyboard_event.keyboard.edit_truncated) self.saw_truncated = true;
                if (keyboard_event.keyboard.edit) |edit| switch (edit) {
                    .insert_text => |text| {
                        const len = @min(text.len, self.last_edit_insert.len);
                        @memcpy(self.last_edit_insert[0..len], text[0..len]);
                        self.last_edit_insert_len = len;
                    },
                    else => {},
                };
            },
            else => {},
        }
    }
};

fn rightClick(x: f32, y: f32) platform.Event {
    return .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .button = 1,
        .x = x,
        .y = y,
        .timestamp_ns = 1_000_000_000,
    } };
}

fn menuAction(token: u64, item_id: u32) platform.Event {
    return .{ .context_menu_action = .{
        .window_id = 1,
        .view_label = "canvas",
        .token = token,
        .item_id = item_id,
    } };
}

fn createMenuHarness(app: App) !*TestHarness() {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 200),
    });
    return harness;
}

test "right click over a widget with a declared menu presents it natively and dispatches the selection" {
    var app_state: MenuTestApp = .{};
    const app = app_state.app();
    const harness = try createMenuHarness(app);
    defer harness.destroy(std.testing.allocator);

    const items = [_]canvas.WidgetContextMenuItem{
        .{ .label = "Complete" },
        .{ .separator = true },
        .{ .label = "Delete" },
    };
    const row = canvas.Widget{
        .id = 2,
        .kind = .list_item,
        .frame = geometry.RectF.init(10, 10, 200, 40),
        .text = "Task",
        .context_menu = &items,
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{row} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, rightClick(50, 20));

    // The platform was asked to present at the pointer with the declared
    // items (ids are 1-based item indices; separators stay separators).
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.context_menu_request_count);
    try std.testing.expectEqualStrings("canvas", harness.null_platform.contextMenuLabel());
    try std.testing.expectEqual(@as(u64, 2), harness.null_platform.context_menu_token);
    try std.testing.expectEqualDeep(geometry.PointF.init(50, 20), harness.null_platform.context_menu_point);
    const recorded = harness.null_platform.contextMenuItems();
    try std.testing.expectEqual(@as(usize, 3), recorded.len);
    try std.testing.expectEqual(@as(u32, 1), recorded[0].id);
    try std.testing.expectEqualStrings("Complete", recorded[0].label);
    try std.testing.expect(recorded[1].separator);
    try std.testing.expectEqual(@as(u32, 3), recorded[2].id);
    try std.testing.expectEqualStrings("Delete", recorded[2].label);

    // The right press never acted as a primary press; the raw input event
    // stayed observable.
    try std.testing.expectEqual(@as(u32, 0), app_state.pointer_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.raw_input_count);

    // Selecting "Delete" dispatches the typed context-menu event.
    try harness.runtime.dispatchPlatformEvent(app, menuAction(2, 3));
    try std.testing.expectEqual(@as(u32, 1), app_state.menu_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_menu_target);
    try std.testing.expectEqual(@as(usize, 2), app_state.last_menu_item_index);

    // A dismissal (item 0) resolves silently.
    try harness.runtime.dispatchPlatformEvent(app, rightClick(50, 20));
    try harness.runtime.dispatchPlatformEvent(app, menuAction(2, 0));
    try std.testing.expectEqual(@as(u32, 1), app_state.menu_count);
}

test "right click on editable text presents the default edit menu wired to clipboard actions" {
    var app_state: MenuTestApp = .{};
    const app = app_state.app();
    const harness = try createMenuHarness(app);
    defer harness.destroy(std.testing.allocator);

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 200, 36),
        .text = "Query",
        .semantics = .{ .label = "Search" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Select "Query" through the keyboard select-all path, then right-click.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 100,
        .y = 30,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "a",
        .modifiers = .{ .primary = true, .command = true },
    } });
    try harness.runtime.dispatchPlatformEvent(app, rightClick(100, 30));

    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.context_menu_request_count);
    const recorded = harness.null_platform.contextMenuItems();
    try std.testing.expectEqual(@as(usize, 5), recorded.len);
    try std.testing.expectEqualStrings("Cut", recorded[0].label);
    try std.testing.expect(recorded[0].enabled);
    try std.testing.expectEqualStrings("Copy", recorded[1].label);
    try std.testing.expectEqualStrings("Paste", recorded[2].label);
    try std.testing.expect(recorded[3].separator);
    try std.testing.expectEqualStrings("Select All", recorded[4].label);

    // Copy through the menu: clipboard captures the selection, text stays.
    try harness.runtime.dispatchPlatformEvent(app, menuAction(2, 2));
    var clipboard_buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Query", try harness.runtime.readClipboard(&clipboard_buffer));
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Query", retained.nodes[1].widget.text);

    // Cut through the menu: clipboard keeps the selection, field empties.
    try harness.runtime.dispatchPlatformEvent(app, rightClick(100, 30));
    try harness.runtime.dispatchPlatformEvent(app, menuAction(2, 1));
    try std.testing.expectEqualStrings("Query", try harness.runtime.readClipboard(&clipboard_buffer));
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("", retained.nodes[1].widget.text);

    // Paste through the menu: the clipboard lands at the caret.
    try harness.runtime.dispatchPlatformEvent(app, rightClick(100, 30));
    try harness.runtime.dispatchPlatformEvent(app, menuAction(2, 3));
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Query", retained.nodes[1].widget.text);

    // Select All through the menu re-selects everything.
    try harness.runtime.dispatchPlatformEvent(app, rightClick(100, 30));
    try harness.runtime.dispatchPlatformEvent(app, menuAction(2, 4));
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 5 }, retained.nodes[1].widget.text_selection.?);
}

test "a near-capacity multi-line context-menu paste sanitizes before it clamps" {
    var app_state: MenuTestApp = .{};
    const app = app_state.app();
    const harness = try createMenuHarness(app);
    defer harness.destroy(std.testing.allocator);

    // Same boundary as the cmd+V shortcut test: exactly three free bytes
    // in the view's shared widget-text storage, clipboard "a\nbc". The
    // context menu's Paste flows through the same sanitize-then-clamp
    // helper, so the sanitized "abc" lands whole instead of the raw
    // clamp's "a\nb" -> "ab".
    const fill_len = canvas_limits.max_canvas_widget_text_bytes_per_view - 3;
    const fill = try std.testing.allocator.alloc(u8, fill_len);
    defer std.testing.allocator.free(fill);
    @memset(fill, 'x');
    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 200, 36),
        .text = fill,
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try std.testing.expectEqual(fill_len, harness.runtime.views[0].widget_text_len);

    try harness.runtime.writeClipboard("a\nbc");
    try harness.runtime.dispatchPlatformEvent(app, rightClick(100, 30));
    // Paste is the default edit menu's third item.
    try harness.runtime.dispatchPlatformEvent(app, menuAction(2, 3));

    // Retained editor and the app's stamped edit hear the same whole
    // sanitized suffix, with no false truncation flag.
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    const text = retained.nodes[1].widget.text;
    try std.testing.expectEqual(fill_len + 3, text.len);
    try std.testing.expectEqualStrings("abc", text[text.len - 3 ..]);
    try std.testing.expectEqualStrings("abc", app_state.last_edit_insert[0..app_state.last_edit_insert_len]);
    try std.testing.expect(!app_state.saw_truncated);
}

test "right click on selected static text presents a copy-only menu" {
    var app_state: MenuTestApp = .{};
    const app = app_state.app();
    const harness = try createMenuHarness(app);
    defer harness.destroy(std.testing.allocator);

    const text = canvas.Widget{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(12, 16, 200, 20),
        .text = "Release notes",
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Establish the view's live static selection the way click-drag does.
    harness.runtime.views[0].canvas_widget_selected_text_id = 2;
    harness.runtime.views[0].widget_layout_nodes[1].widget.text_selection = .{ .anchor = 0, .focus = 7 };

    try harness.runtime.dispatchPlatformEvent(app, rightClick(50, 24));
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.context_menu_request_count);
    const recorded = harness.null_platform.contextMenuItems();
    try std.testing.expectEqual(@as(usize, 1), recorded.len);
    try std.testing.expectEqualStrings("Copy", recorded[0].label);

    try harness.runtime.dispatchPlatformEvent(app, menuAction(2, 2));
    var clipboard_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Release", try harness.runtime.readClipboard(&clipboard_buffer));
}

test "right click with no menu target presents nothing" {
    var app_state: MenuTestApp = .{};
    const app = app_state.app();
    const harness = try createMenuHarness(app);
    defer harness.destroy(std.testing.allocator);

    const button = canvas.Widget{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 96, 32),
        .text = "Run",
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{button} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, rightClick(50, 20));
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.context_menu_request_count);
    try std.testing.expectEqual(@as(u32, 0), app_state.pointer_count);

    // A stray action event with no pending request is a no-op.
    try harness.runtime.dispatchPlatformEvent(app, menuAction(2, 1));
    try std.testing.expectEqual(@as(u32, 0), app_state.menu_count);
}

test "a declared menu on a presenter-less host becomes a fallback request, not a lost click" {
    var app_state: MenuTestApp = .{};
    const app = app_state.app();
    const harness = try TestHarness().create(std.testing.allocator, .{});
    harness.null_platform.gpu_surfaces = true;
    // Model a host without a native menu presenter (Linux GTK, Windows
    // Win32 today): the service is null and the feature reports false.
    // Service POINTERS are captured at init, so re-capture after the
    // flip (feature FLAGS like gpu_surfaces read live through context).
    harness.null_platform.context_menus = false;
    harness.runtime.options.platform = harness.null_platform.platform();
    try harness.start(app);
    defer harness.destroy(std.testing.allocator);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 200),
    });

    const items = [_]canvas.WidgetContextMenuItem{
        .{ .label = "Complete" },
        .{ .label = "Delete" },
    };
    const row = canvas.Widget{
        .id = 2,
        .kind = .list_item,
        .frame = geometry.RectF.init(10, 10, 200, 40),
        .text = "Task",
        .context_menu = &items,
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{row} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Right-click: nothing to present natively, so the app loop is asked
    // to mount the anchored fallback surface for the declared target.
    try harness.runtime.dispatchPlatformEvent(app, rightClick(50, 20));
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.context_menu_request_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.request_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_request_target);
    // Never the hold alternative: a declared menu consumed the press.
    try std.testing.expectEqual(@as(u32, 0), app_state.pointer_count);

    // The automation verb still drives the SAME selection dispatch — no
    // presenter required (the OS tracking loop is skipped on macOS too).
    try harness.runtime.dispatchAutomationCommand(app, "widget-context-menu canvas 2 1");
    try std.testing.expectEqual(@as(u32, 1), app_state.menu_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_menu_target);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_menu_item_index);
}

test "the widget-context-menu verb dispatches selections through context_menu_action and refuses dead items by name" {
    var app_state: MenuTestApp = .{};
    const app = app_state.app();
    const harness = try createMenuHarness(app);
    defer harness.destroy(std.testing.allocator);

    const items = [_]canvas.WidgetContextMenuItem{
        .{ .label = "Complete" },
        .{ .separator = true },
        .{ .label = "Delete" },
        .{ .label = "Archive", .enabled = false },
    };
    const row = canvas.Widget{
        .id = 2,
        .kind = .list_item,
        .frame = geometry.RectF.init(10, 10, 200, 40),
        .text = "Task",
        .context_menu = &items,
    };
    const plain = canvas.Widget{
        .id = 3,
        .kind = .list_item,
        .frame = geometry.RectF.init(10, 60, 200, 40),
        .text = "Bare",
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{ row, plain } }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Invoking "Delete" (index 2) takes the same dispatch a real pick
    // does: a context_menu_action platform event resolved against the
    // pending request the verb armed.
    try harness.runtime.dispatchAutomationCommand(app, "widget-context-menu canvas 2 2");
    try std.testing.expectEqual(@as(u32, 1), app_state.menu_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_menu_target);
    try std.testing.expectEqual(@as(usize, 2), app_state.last_menu_item_index);
    // The verb never asked the platform to present: the OS menu's
    // tracking loop cannot be driven programmatically.
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.context_menu_request_count);

    // Dead invocations fail by name instead of silently doing nothing.
    try std.testing.expectError(error.ContextMenuUndeclared, harness.runtime.dispatchAutomationCommand(app, "widget-context-menu canvas 3 0"));
    try std.testing.expectError(error.ContextMenuItemOutOfRange, harness.runtime.dispatchAutomationCommand(app, "widget-context-menu canvas 2 4"));
    try std.testing.expectError(error.ContextMenuItemSeparator, harness.runtime.dispatchAutomationCommand(app, "widget-context-menu canvas 2 1"));
    try std.testing.expectError(error.ContextMenuItemDisabled, harness.runtime.dispatchAutomationCommand(app, "widget-context-menu canvas 2 3"));
    try std.testing.expectEqual(@as(u32, 1), app_state.menu_count);
}

test "automation snapshots list each widget's declared context-menu items in invocable order" {
    var app_state: MenuTestApp = .{};
    const app = app_state.app();
    const harness = try createMenuHarness(app);
    defer harness.destroy(std.testing.allocator);

    const items = [_]canvas.WidgetContextMenuItem{
        .{ .label = "Complete" },
        .{ .separator = true },
        .{ .label = "Archive", .enabled = false },
    };
    const row = canvas.Widget{
        .id = 2,
        .kind = .list_item,
        .frame = geometry.RectF.init(10, 10, 200, 40),
        .text = "Task",
        .context_menu = &items,
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{row} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    var buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try automation.snapshot.writeText(harness.runtime.automationSnapshot("Menus"), &writer);
    // List position = the widget-context-menu item index; separators
    // keep their slots and disabled items say so.
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "context_menu=[\"Complete\",separator,\"Archive\"(disabled)]") != null);
}

test "automation snapshots report per-view context-menu item headroom" {
    var app_state: MenuTestApp = .{};
    const app = app_state.app();
    const harness = try createMenuHarness(app);
    defer harness.destroy(std.testing.allocator);

    const items = [_]canvas.WidgetContextMenuItem{
        .{ .label = "Complete" },
        .{ .separator = true },
        .{ .label = "Delete" },
    };
    const row = canvas.Widget{
        .id = 2,
        .kind = .list_item,
        .frame = geometry.RectF.init(10, 10, 200, 40),
        .text = "Task",
        .context_menu = &items,
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{row} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    const info = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Separators count against the budget: they occupy retained slots.
    try std.testing.expectEqual(@as(usize, 3), info.widget_context_menu_item_count);

    // The gpu_surface view line reports declared/budget headroom so
    // authors watch the cliff without overflowing.
    var buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try automation.snapshot.writeText(harness.runtime.automationSnapshot("Menus"), &writer);
    const expected = std.fmt.comptimePrint("context_menu_items=3/{d}", .{canvas_limits.max_canvas_widget_context_menu_items_per_view});
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), expected) != null);
}

test "context-menu declarations sum across widgets to the budget and overflow loudly one past it" {
    const budget = canvas_limits.max_canvas_widget_context_menu_items_per_view;
    var app_state: MenuTestApp = .{};
    const app = app_state.app();
    const harness = try createMenuHarness(app);
    defer harness.destroy(std.testing.allocator);

    const bulk = [_]canvas.WidgetContextMenuItem{.{ .label = "Op" }} ** (budget - 1);
    const pair = [_]canvas.WidgetContextMenuItem{ .{ .label = "A" }, .{ .label = "B" } };
    var nodes = [_]canvas.WidgetLayoutNode{
        .{
            .widget = .{ .id = 2, .kind = .list_item, .text = "Bulk", .context_menu = &bulk },
            .frame = geometry.RectF.init(0, 0, 200, 40),
            .depth = 0,
        },
        .{
            .widget = .{ .id = 3, .kind = .list_item, .text = "Tail", .context_menu = pair[0..1] },
            .frame = geometry.RectF.init(0, 40, 200, 40),
            .depth = 0,
        },
    };

    // Exactly at the budget: the layout retains every declared item.
    const info = try harness.runtime.setCanvasWidgetLayout(1, "canvas", .{ .nodes = &nodes });
    try std.testing.expectEqual(budget, info.widget_context_menu_item_count);

    // One extra declared item anywhere in the view overflows loudly.
    nodes[1].widget.context_menu = &pair;
    try std.testing.expectError(error.WidgetContextMenuLimitReached, harness.runtime.setCanvasWidgetLayout(1, "canvas", .{ .nodes = &nodes }));
}
