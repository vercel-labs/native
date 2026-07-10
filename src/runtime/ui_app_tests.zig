const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const automation = @import("../automation/root.zig");
const zero_platform = @import("../platform/root.zig");
const null_platform_mod = @import("../platform/null_platform.zig");

const canvas_label = "counter-canvas";

const CounterModel = struct {
    count: u32 = 0,
};

const CounterMsg = union(enum) {
    increment,
    reset,
};

const CounterApp = ui_app_model.UiApp(CounterModel, CounterMsg);

fn counterUpdate(model: *CounterModel, msg: CounterMsg) void {
    switch (msg) {
        .increment => model.count += 1,
        .reset => model.count = 0,
    }
}

fn counterView(ui: *CounterApp.Ui, model: *const CounterModel) CounterApp.Ui.Node {
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.text(.{}, ui.fmt("Count {d}", .{model.count})),
        ui.button(.{ .variant = .primary, .on_press = .increment }, "Increment"),
        ui.button(.{ .on_press = .reset }, "Reset"),
    });
}

fn counterCommand(name: []const u8) ?CounterMsg {
    if (std.mem.eql(u8, name, "counter.reset")) return .reset;
    return null;
}

const counter_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const counter_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Counter",
    .width = 400,
    .height = 300,
    .views = &counter_views,
}};
const counter_scene: app_manifest.ShellConfig = .{ .windows = &counter_windows };

fn counterOptions() CounterApp.Options {
    return .{
        .name = "ui-app-counter",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = counterUpdate,
        .view = counterView,
        .on_command = counterCommand,
    };
}

fn findWidgetIdByText(tree: anytype, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
    return findIn(tree.root, kind, text);
}

fn findIn(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget.id;
    for (widget.children) |child| {
        if (findIn(child, kind, text)) |id| return id;
    }
    return null;
}

fn retainedTextExists(runtime: *core.Runtime, text: []const u8) !bool {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    for (layout.nodes) |node| {
        if (node.widget.kind == .text and std.mem.eql(u8, node.widget.text, text)) return true;
    }
    return false;
}

test "ui app owns install, dispatch, and rebuild end to end" {
    // The runtime and the app are both large structs; keep them off the
    // test thread's stack.
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, counterOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    // First gpu frame installs the widget tree and display list.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 0"));

    // Automation clicks flow through typed dispatch into update + rebuild.
    const increment_id = findWidgetIdByText(app_state.tree.?, .button, "Increment").?;
    var command_buffer: [96]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, increment_id });
    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 1"));

    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expectEqual(@as(u32, 2), app_state.model.count);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 2"));

    // Structural identity survives the rebuilds the dispatches triggered.
    try std.testing.expectEqual(increment_id, findWidgetIdByText(app_state.tree.?, .button, "Increment").?);

    // Shell command events map into messages through on_command.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "counter.reset", .window_id = 1 } });
    try std.testing.expectEqual(@as(u32, 0), app_state.model.count);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 0"));
}

// -------------------------------------- context-menu fallback fixture

const TaskRowModel = struct {
    completed: u32 = 0,
    deleted: u32 = 0,
};

const TaskRowMsg = union(enum) {
    complete,
    delete,
};

const TaskRowApp = ui_app_model.UiApp(TaskRowModel, TaskRowMsg);

fn taskRowUpdate(model: *TaskRowModel, msg: TaskRowMsg) void {
    switch (msg) {
        .complete => model.completed += 1,
        .delete => model.deleted += 1,
    }
}

fn taskRowView(ui: *TaskRowApp.Ui, model: *const TaskRowModel) TaskRowApp.Ui.Node {
    _ = model;
    var row = ui.el(.list_item, .{
        .padding = 8,
        .context_menu = &.{
            .{ .label = "Complete", .msg = .complete },
            .{ .separator = true },
            .{ .label = "Delete", .msg = .delete },
        },
    }, .{
        ui.text(.{ .grow = 1 }, "Task"),
    });
    row.widget.text = "Task";
    return ui.column(.{ .gap = 8, .padding = 12 }, .{row});
}

fn taskRowOptions() TaskRowApp.Options {
    return .{
        .name = "ui-app-task-rows",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = taskRowUpdate,
        .view = taskRowView,
    };
}

fn retainedWidgetKindExists(runtime: *core.Runtime, kind: canvas.WidgetKind) !bool {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    for (layout.nodes) |node| {
        if (node.widget.kind == kind) return true;
    }
    return false;
}

test "a declared context menu presents as the anchored fallback surface on presenter-less hosts, end to end" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    // A host without a native menu presenter (Linux GTK, Windows Win32
    // today). Service pointers are captured at init, so re-capture.
    harness.null_platform.context_menus = false;
    harness.runtime.options.platform = harness.null_platform.platform();

    const app_state = try std.testing.allocator.create(TaskRowApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = TaskRowApp.init(std.heap.page_allocator, .{}, taskRowOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    // At rest: no surface mounted, no fallback state.
    try std.testing.expect(!try retainedWidgetKindExists(&harness.runtime, .dropdown_menu));
    try std.testing.expect(app_state.tree.?.context_menu_fallback == null);

    // Right-click the row: the SAME declared menu mounts as an anchored
    // canvas surface (no native presenter to hand it to).
    const row_id = findWidgetIdByText(app_state.tree.?, .list_item, "Task").?;
    var command_buffer: [96]u8 = undefined;
    const context_press = try std.fmt.bufPrint(&command_buffer, "widget-context-press {s} {d}", .{ canvas_label, row_id });
    try harness.runtime.dispatchAutomationCommand(app, context_press);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.context_menu_request_count);
    const fallback = app_state.tree.?.context_menu_fallback orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(row_id, fallback.target_id);
    try std.testing.expectEqual(@as(usize, 3), fallback.item_ids.len);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), fallback.item_ids[1]);
    try std.testing.expect(try retainedWidgetKindExists(&harness.runtime, .dropdown_menu));
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .menu_item, "Delete") != null);

    // Clicking "Delete" routes through the target's .context_menu
    // handler — the same entry a native selection resolves — and closes
    // the surface.
    var click_buffer: [96]u8 = undefined;
    const click_delete = try std.fmt.bufPrint(&click_buffer, "widget-click {s} {d}", .{ canvas_label, fallback.item_ids[2] });
    try harness.runtime.dispatchAutomationCommand(app, click_delete);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.deleted);
    try std.testing.expectEqual(@as(u32, 0), app_state.model.completed);
    try std.testing.expect(app_state.tree.?.context_menu_fallback == null);
    try std.testing.expect(!try retainedWidgetKindExists(&harness.runtime, .dropdown_menu));

    // Reopen and dismiss (Escape/outside-click/automation all land on
    // the same dismissal machinery): the surface closes, no Msg fires.
    try harness.runtime.dispatchAutomationCommand(app, context_press);
    const reopened = app_state.tree.?.context_menu_fallback orelse return error.TestUnexpectedResult;
    var dismiss_buffer: [96]u8 = undefined;
    const dismiss = try std.fmt.bufPrint(&dismiss_buffer, "widget-action {s} {d} dismiss", .{ canvas_label, reopened.surface_id });
    try harness.runtime.dispatchAutomationCommand(app, dismiss);
    try std.testing.expect(app_state.tree.?.context_menu_fallback == null);
    try std.testing.expect(!try retainedWidgetKindExists(&harness.runtime, .dropdown_menu));
    try std.testing.expectEqual(@as(u32, 1), app_state.model.deleted);

    // The widget-context-menu verb converges on the same dispatch with
    // no surface involved at all.
    var verb_buffer: [96]u8 = undefined;
    const invoke_complete = try std.fmt.bufPrint(&verb_buffer, "widget-context-menu {s} {d} 0", .{ canvas_label, row_id });
    try harness.runtime.dispatchAutomationCommand(app, invoke_complete);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.completed);
    try std.testing.expect(app_state.tree.?.context_menu_fallback == null);
}

// ------------------------------------------------- scroll event fixture

const FeedModel = struct {
    /// Elm-style mirror of the scroll offset: on_scroll delivers the
    /// offset the runtime already applied, the model stores it, and the
    /// view echoes it back into `value` — which must never fight the
    /// scroll reconcile rule (the echoed source value equals the runtime
    /// offset).
    offset: f32 = 0,
    viewport_extent: f32 = 0,
    content_extent: f32 = 0,
    scroll_events: u32 = 0,
};

const FeedMsg = union(enum) {
    feed_scrolled: canvas.ScrollState,
};

const FeedApp = ui_app_model.UiApp(FeedModel, FeedMsg);

fn feedUpdate(model: *FeedModel, msg: FeedMsg) void {
    switch (msg) {
        .feed_scrolled => |scroll_state| {
            model.offset = scroll_state.offset;
            model.viewport_extent = scroll_state.viewport_extent;
            model.content_extent = scroll_state.content_extent;
            model.scroll_events += 1;
        },
    }
}

fn feedView(ui: *FeedApp.Ui, model: *const FeedModel) FeedApp.Ui.Node {
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.scroll(.{
            .height = 96,
            .value = model.offset,
            .on_scroll = FeedApp.Ui.scrollMsg(.feed_scrolled),
        }, ui.column(.{ .gap = 4 }, .{
            ui.text(.{ .height = 80 }, "Row one"),
            ui.text(.{ .height = 80 }, "Row two"),
            ui.text(.{ .height = 80 }, "Row three"),
            ui.text(.{ .height = 80 }, "Row four"),
        })),
        ui.text(.{}, ui.fmt("Offset {d:.0}", .{model.offset})),
    });
}

fn feedOptions() FeedApp.Options {
    return .{
        .name = "ui-app-feed",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = feedUpdate,
        .view = feedView,
    };
}

test "ui app on_scroll delivers wheel offsets and the echoed model offset survives the rebuild" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(FeedApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = FeedApp.init(std.heap.page_allocator, .{}, feedOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    const scroll_id = findWidgetIdByKind(app_state.tree.?.root, .scroll_view).?;
    var command_buffer: [96]u8 = undefined;
    const wheel = try std.fmt.bufPrint(&command_buffer, "widget-wheel {s} {d} 18", .{ canvas_label, scroll_id });
    try harness.runtime.dispatchAutomationCommand(app, wheel);

    // The wheel dispatched a typed scroll Msg carrying the applied
    // offset and the extents (content spans four 80pt rows + gaps).
    try std.testing.expectEqual(@as(u32, 1), app_state.model.scroll_events);
    try std.testing.expect(app_state.model.offset > 0);
    try std.testing.expect(app_state.model.content_extent > app_state.model.viewport_extent);

    // The dispatch rebuilt with the echoed offset; the retained runtime
    // offset agrees with the model (echoing never fights the reconcile
    // rule, because the echoed source value IS the runtime offset).
    const layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expectEqual(app_state.model.offset, layout.findById(scroll_id).?.widget.value);

    // A second wheel accumulates from the reconciled offset.
    const first_offset = app_state.model.offset;
    try harness.runtime.dispatchAutomationCommand(app, wheel);
    try std.testing.expectEqual(@as(u32, 2), app_state.model.scroll_events);
    try std.testing.expect(app_state.model.offset > first_offset);
}

test "ui app presents pixels when the packet service is unsupported" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_packets = false;

    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.testing.allocator, .{}, counterOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    // The installing frame falls back from the failing packet presenter to
    // the CPU pixel path: the widget tree installs and the reference-rendered
    // surface reaches the platform at device resolution.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try std.testing.expect(app_state.installed);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 0"));
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqual(@as(usize, 800), harness.null_platform.gpu_surface_present_width);
    try std.testing.expectEqual(@as(usize, 600), harness.null_platform.gpu_surface_present_height);
    try std.testing.expectEqual(@as(f32, 2), harness.null_platform.gpu_surface_present_scale_factor);
    try std.testing.expectEqual(@as(usize, 800 * 600 * 4), harness.null_platform.gpu_surface_present_byte_len);
    try std.testing.expectEqualStrings(
        canvas_label,
        harness.null_platform.gpu_surface_present_label_storage[0..harness.null_platform.gpu_surface_present_label_len],
    );

    // Model changes keep presenting through the pixel path.
    const increment_id = findWidgetIdByText(app_state.tree.?, .button, "Increment").?;
    var command_buffer: [96]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, increment_id });
    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 17_000_000,
    } });
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 1"));
}

const counter_markup =
    \\<column gap="8" padding="12">
    \\  <text>Count {count}</text>
    \\  <button variant="primary" on-press="increment">Increment</button>
    \\  <button on-press="reset">Reset</button>
    \\</column>
;

const counter_markup_v2 =
    \\<column gap="8" padding="12">
    \\  <text>Count {count}</text>
    \\  <button variant="primary" on-press="increment">Increment</button>
    \\  <button on-press="reset">Start over</button>
    \\</column>
;

fn markupCounterOptions() CounterApp.Options {
    return .{
        .name = "ui-app-markup-counter",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = counterUpdate,
        .markup = .{ .source = counter_markup },
        .on_command = counterCommand,
    };
}

test "markup views drive the ui app loop and hot reload preserves state" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, markupCounterOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 0"));

    // Markup-declared handlers dispatch through the same typed loop.
    const increment_id = findWidgetIdByText(app_state.tree.?, .button, "Increment").?;
    var command_buffer: [96]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, increment_id });
    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 1"));

    // Hot reload: new view source, model state kept, ids stable.
    try app_state.reloadMarkup(counter_markup_v2);
    try app_state.rebuild(&harness.runtime, 1);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 1"));
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .button, "Start over") != null);
    try std.testing.expectEqual(increment_id, findWidgetIdByText(app_state.tree.?, .button, "Increment").?);

    // A broken reload keeps the last good view and records the diagnostic.
    try std.testing.expectError(error.MarkupSyntax, app_state.reloadMarkup("<column><oops</column>"));
    try std.testing.expect(app_state.markup_diagnostic != null);
    try app_state.rebuild(&harness.runtime, 1);
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .button, "Start over") != null);
}

const counter_timer_id: u64 = 42;

fn counterTimer(id: u64, timestamp_ns: u64) ?CounterMsg {
    _ = timestamp_ns;
    if (id == counter_timer_id) return .increment;
    return null;
}

test "ui app maps timer events into messages and rebuilds" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    var options = counterOptions();
    options.on_timer = counterTimer;
    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, options);
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 0"));

    // A fired timer maps through on_timer into update + rebuild.
    try harness.runtime.startTimer(counter_timer_id, 100_000_000, true);
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(counter_timer_id, 2_000_000).?);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 1"));

    // Cancelled timers stop producing events entirely.
    try harness.runtime.cancelTimer(counter_timer_id);
    try std.testing.expect(harness.null_platform.fireTimer(counter_timer_id, 3_000_000) == null);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);
}

// -------------------------------------------------------- transform channel

const SlideModel = struct {
    tick: u32 = 0,
};

const SlideMsg = union(enum) {
    tick,
};

const SlideApp = ui_app_model.UiApp(SlideModel, SlideMsg);

const slide_timer_id: u64 = 43;

fn slideUpdate(model: *SlideModel, msg: SlideMsg) void {
    switch (msg) {
        .tick => model.tick += 1,
    }
}

fn slideOffset(tick: u32) f32 {
    return @as(f32, @floatFromInt(tick)) * 8;
}

fn slideView(ui: *SlideApp.Ui, model: *const SlideModel) SlideApp.Ui.Node {
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.el(.panel, .{
            .transform = canvas.Affine.translate(slideOffset(model.tick), 0),
            .opacity = 0.9,
            .width = 80,
            .height = 40,
        }, .{
            ui.text(.{}, "Slide"),
        }),
    });
}

fn slideTimer(id: u64, timestamp_ns: u64) ?SlideMsg {
    _ = timestamp_ns;
    if (id == slide_timer_id) return .tick;
    return null;
}

fn slideOptions() SlideApp.Options {
    return .{
        .name = "ui-app-slide",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = slideUpdate,
        .view = slideView,
        .on_timer = slideTimer,
    };
}

fn retainedPanelTransform(runtime: *core.Runtime) !canvas.Affine {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    for (layout.nodes) |node| {
        if (node.widget.kind == .panel) return node.widget.transform;
    }
    return error.MissingPanel;
}

test "view-mapped transforms rebuild and invalidate per tick" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(SlideApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = SlideApp.init(std.heap.page_allocator, .{}, slideOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    // Tick 0 authors translate(0, 0): the identity default, so the retained
    // tree starts untransformed.
    try std.testing.expectEqualDeep(canvas.Affine.identity(), try retainedPanelTransform(&harness.runtime));

    // Each fired tick maps model state into a fresh view transform: the
    // rebuilt tree carries it and the dirty machinery schedules a repaint.
    try harness.runtime.startTimer(slide_timer_id, 16_000_000, true);
    harness.runtime.invalidated = false;
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(slide_timer_id, 2_000_000).?);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.tick);
    try std.testing.expectEqualDeep(canvas.Affine.translate(8, 0), try retainedPanelTransform(&harness.runtime));
    try std.testing.expect(harness.runtime.invalidated);

    harness.runtime.invalidated = false;
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(slide_timer_id, 18_000_000).?);
    try std.testing.expectEqual(@as(u32, 2), app_state.model.tick);
    try std.testing.expectEqualDeep(canvas.Affine.translate(16, 0), try retainedPanelTransform(&harness.runtime));
    try std.testing.expect(harness.runtime.invalidated);
}

// ------------------------------------------------------------------ hooks

const ThemedModel = struct {
    count: u32 = 0,
    dark: bool = false,
    high_contrast: bool = false,
    frame_reports: u32 = 0,
    slider_value: f32 = 0.5,
    /// How many times `on_change` reached update — the pointer test
    /// counts one dispatch per gesture step (down, each drag move).
    slider_changes: u32 = 0,
};

const ThemedMsg = union(enum) {
    increment,
    appearance: struct { dark: bool, high_contrast: bool },
    frame_seen,
    slider_changed,
};

const ThemedApp = ui_app_model.UiApp(ThemedModel, ThemedMsg);

const themed_light_background = canvas.Color.rgb8(240, 244, 250);
const themed_dark_background = canvas.Color.rgb8(18, 22, 30);
const themed_chrome_background_id: canvas.ObjectId = 1;
const themed_chrome_footer_id: canvas.ObjectId = 2;

fn themedUpdate(model: *ThemedModel, msg: ThemedMsg) void {
    switch (msg) {
        .increment => model.count += 1,
        .appearance => |appearance| {
            model.dark = appearance.dark;
            model.high_contrast = appearance.high_contrast;
        },
        .frame_seen => model.frame_reports += 1,
        // The value itself arrives through the `sync` hook before this
        // Msg is applied (the runtime-owned slider contract); update
        // only counts the dispatch.
        .slider_changed => model.slider_changes += 1,
    }
}

fn themedView(ui: *ThemedApp.Ui, model: *const ThemedModel) ThemedApp.Ui.Node {
    return ui.column(.{ .gap = 8, .padding = 12, .style_tokens = .{ .background = .background } }, .{
        ui.text(.{}, ui.fmt("Count {d}", .{model.count})),
        ui.button(.{ .variant = .primary, .on_press = .increment }, "Add"),
        ui.el(.slider, .{ .value = model.slider_value, .on_change = .slider_changed, .semantics = .{ .label = "Level" } }, .{}),
    });
}

fn themedTokens(model: *const ThemedModel) canvas.DesignTokens {
    var tokens = canvas.DesignTokens{};
    tokens.colors.background = if (model.dark) themed_dark_background else themed_light_background;
    tokens.pixel_snap = .{ .geometry = true, .text = true };
    return tokens;
}

fn themedChrome(model: *const ThemedModel, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    _ = model;
    // One prefix command (backdrop) and one suffix command (footer rule).
    try builder.fillRect(.{
        .id = themed_chrome_background_id,
        .rect = geometry.RectF.init(0, 0, size.width, size.height),
        .fill = .{ .color = tokens.colors.background },
    });
    try builder.fillRect(.{
        .id = themed_chrome_footer_id,
        .rect = geometry.RectF.init(0, size.height - 1, size.width, 1),
        .fill = .{ .color = tokens.colors.text },
    });
}

fn themedAnimations(model: *const ThemedModel, tree: *const ThemedApp.Ui.Tree, start_ns: u64, out: []canvas.CanvasRenderAnimation) usize {
    _ = model;
    const button_id = findIn(tree.root, .button, "Add") orelse return 0;
    if (out.len < 1) return 0;
    out[0] = .{
        .id = canvas.widgetCommandPartId(.{ .widget_id = button_id, .slot = 1 }),
        .start_ns = start_ns,
        .duration_ms = 400,
        .from_opacity = 0.6,
        .to_opacity = 1,
    };
    return 1;
}

fn themedAppearance(appearance: core.Appearance) ?ThemedMsg {
    return ThemedMsg{ .appearance = .{
        .dark = appearance.color_scheme == .dark,
        .high_contrast = appearance.high_contrast,
    } };
}

fn themedFrame(model: *const ThemedModel, frame: @import("../platform/root.zig").GpuFrame) ?ThemedMsg {
    if (model.frame_reports > 0) return null;
    if (frame.canvas_command_count == 0) return null;
    return .frame_seen;
}

fn themedSync(model: *ThemedModel, layout: canvas.WidgetLayoutTree) void {
    for (layout.nodes) |node| {
        if (node.widget.kind == .slider) model.slider_value = node.widget.value;
    }
}

fn themedOptions() ThemedApp.Options {
    return .{
        .name = "ui-app-themed",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = themedUpdate,
        .view = themedView,
        .tokens_fn = themedTokens,
        .chrome = .{ .prefix_commands = 1, .suffix_commands = 1, .build = themedChrome },
        .animations = themedAnimations,
        .on_appearance = themedAppearance,
        .on_frame = themedFrame,
        .sync = themedSync,
    };
}

fn expectChromeFillRect(display_list: canvas.DisplayList, id: canvas.ObjectId, expected_rect: geometry.RectF, expected_color: canvas.Color) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingChromeCommand;
    switch (command_ref.command) {
        .fill_rect => |fill| {
            try std.testing.expectApproxEqAbs(expected_rect.width, fill.rect.width, 0.001);
            try std.testing.expectApproxEqAbs(expected_rect.height, fill.rect.height, 0.001);
            switch (fill.fill) {
                .color => |actual| try std.testing.expectEqualDeep(expected_color, actual),
                else => return error.UnexpectedChromeCommand,
            }
        },
        else => return error.UnexpectedChromeCommand,
    }
}

test "ui app hooks drive chrome, dynamic tokens, animations, and frame reports" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(ThemedApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = ThemedApp.init(std.heap.page_allocator, .{}, themedOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    // Install: the chrome prefix and suffix wrap the widget commands, the
    // model-derived tokens are stored (with the surface scale stamped into
    // pixel snapping), and the animation hook is applied with the install
    // frame timestamp.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    var display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try std.testing.expect(display_list.commandCount() > 2);
    try expectChromeFillRect(display_list, themed_chrome_background_id, geometry.RectF.init(0, 0, 400, 300), themed_light_background);
    try std.testing.expect(display_list.findCommandById(themed_chrome_footer_id) != null);
    // The chrome prefix stays first and the suffix stays last around the
    // regenerated widget commands.
    try std.testing.expectEqual(themed_chrome_background_id, display_list.commands[0].fill_rect.id);
    try std.testing.expectEqual(themed_chrome_footer_id, display_list.commands[display_list.commands.len - 1].fill_rect.id);

    const stored_tokens = try harness.runtime.canvasWidgetDesignTokens(1, canvas_label);
    try std.testing.expectEqualDeep(themed_light_background, stored_tokens.colors.background);
    try std.testing.expectEqual(@as(f32, 2), stored_tokens.pixel_snap.scale);

    // The root's style token ref resolved against the model-derived tokens.
    try std.testing.expectEqualDeep(themed_light_background, app_state.tree.?.root.style.background.?);

    const animations = try harness.runtime.canvasRenderAnimations(1, canvas_label);
    try std.testing.expectEqual(@as(usize, 1), animations.len);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), animations[0].start_ns);
    const button_id = findIn(app_state.tree.?.root, .button, "Add").?;
    try std.testing.expectEqual(canvas.widgetCommandPartId(.{ .widget_id = button_id, .slot = 1 }), animations[0].id);

    // A dispatch-driven rebuild keeps the chrome and updates the widgets.
    var command_buffer: [96]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, button_id });
    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 1"));
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectChromeFillRect(display_list, themed_chrome_background_id, geometry.RectF.init(0, 0, 400, 300), themed_light_background);

    // Runtime-owned slider state syncs back into the model before update.
    const slider_id = blk: {
        const layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
        for (layout.nodes) |node| {
            if (node.widget.kind == .slider) break :blk node.widget.id;
        }
        return error.TestUnexpectedResult;
    };
    const increment = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} increment", .{ canvas_label, slider_id });
    try harness.runtime.dispatchAutomationCommand(app, increment);
    try std.testing.expect(app_state.model.slider_value > 0.5);

    // Appearance changes map into messages; the model-owned scheme drives
    // new tokens and a chrome rebuild.
    try harness.runtime.dispatchPlatformEvent(app, .{ .appearance_changed = .{ .color_scheme = .dark, .high_contrast = true } });
    try std.testing.expect(app_state.model.dark);
    try std.testing.expect(app_state.model.high_contrast);
    const dark_tokens = try harness.runtime.canvasWidgetDesignTokens(1, canvas_label);
    try std.testing.expectEqualDeep(themed_dark_background, dark_tokens.colors.background);
    // Style token refs re-resolve on the retheme rebuild: the same widget
    // now carries the dark token's concrete color.
    try std.testing.expectEqualDeep(themed_dark_background, app_state.tree.?.root.style.background.?);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectChromeFillRect(display_list, themed_chrome_background_id, geometry.RectF.init(0, 0, 400, 300), themed_dark_background);

    // Resizes rebuild the chrome at the new surface size.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = canvas_label,
        .frame = geometry.RectF.init(0, 0, 640, 480),
        .scale_factor = 2,
    } });
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectChromeFillRect(display_list, themed_chrome_background_id, geometry.RectF.init(0, 0, 640, 480), themed_dark_background);

    // Non-installing frames report presented gpu frames through on_frame.
    try std.testing.expectEqual(@as(u32, 0), app_state.model.frame_reports);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(640, 480),
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 1_016_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.model.frame_reports);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(640, 480),
        .scale_factor = 2,
        .frame_index = 3,
        .timestamp_ns = 1_032_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.model.frame_reports);
}

test "slider pointer gestures dispatch on_change: rail click commits, drag scrubs" {
    // Regression: the pointer path applied slider values as the visual
    // echo but never dispatched the app's `on_change` — a rail click
    // moved the thumb on screen while the model heard nothing, so a
    // model-driven slider (a transport scrubber) snapped back on its
    // next source rebuild. Pointer changes now drain into
    // `canvas_widget_change` events; this pins the full pipeline:
    // platform pointer input -> runtime echo -> change drain -> the
    // slider's Msg -> `sync` reading the applied value into the model.
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(ThemedApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = ThemedApp.init(std.heap.page_allocator, .{}, themedOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    // The slider's laid-out rail, straight from the runtime's layout.
    const rail = blk: {
        const layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
        for (layout.nodes) |node| {
            if (node.widget.kind == .slider) break :blk node.frame.normalized();
        }
        return error.TestUnexpectedResult;
    };
    const rail_y = rail.y + rail.height / 2;

    // Rail click: pressing at 3/4 along the rail (nowhere near the
    // thumb, which sits at the initial 0.5) commits the proportional
    // value in ONE dispatch — the standard native scrubber jump.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .x = rail.x + rail.width * 0.75,
        .y = rail_y,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.model.slider_changes);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), app_state.model.slider_value, 0.01);

    // Click-then-drag scrubs continuously: the same gesture keeps
    // dispatching as the pointer moves, and the model follows live.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_drag,
        .x = rail.x + rail.width * 0.25,
        .y = rail_y,
    } });
    try std.testing.expectEqual(@as(u32, 2), app_state.model.slider_changes);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), app_state.model.slider_value, 0.01);

    // Releasing where the drag ended applies no new value: one gesture
    // never double-commits its final position.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_up,
        .x = rail.x + rail.width * 0.25,
        .y = rail_y,
    } });
    try std.testing.expectEqual(@as(u32, 2), app_state.model.slider_changes);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), app_state.model.slider_value, 0.01);

    // Keyboard steps are UNCHANGED: they dispatch through the keyboard
    // path exactly once — the pointer-change drain must not add a
    // second delivery for the same step.
    const slider_id = blk: {
        const layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
        for (layout.nodes) |node| {
            if (node.widget.kind == .slider) break :blk node.widget.id;
        }
        return error.TestUnexpectedResult;
    };
    var command_buffer: [96]u8 = undefined;
    const increment = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} increment", .{ canvas_label, slider_id });
    try harness.runtime.dispatchAutomationCommand(app, increment);
    try std.testing.expectEqual(@as(u32, 3), app_state.model.slider_changes);
    try std.testing.expectApproxEqAbs(@as(f32, 0.30), app_state.model.slider_value, 0.01);
}

test "unthemed apps follow the system appearance live; explicit tokens opt out" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    // The counter sets neither `tokens` nor `tokens_fn`: the stock theme
    // follows the system appearance.
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, counterOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    // An appearance delivered BEFORE the install (the platform emits one
    // right after start) makes the very first build dark.
    try harness.runtime.dispatchPlatformEvent(app, .{ .appearance_changed = .{ .color_scheme = .dark } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    const dark = canvas.DesignTokens.theme(.{ .color_scheme = .dark });
    var stored = try harness.runtime.canvasWidgetDesignTokens(1, canvas_label);
    try std.testing.expectEqualDeep(dark.colors.background, stored.colors.background);
    try std.testing.expectEqual(@as(f32, 2), stored.pixel_snap.scale);

    // Flipping the OS setting re-themes the RUNNING app: no restart, no
    // app wiring.
    try harness.runtime.dispatchPlatformEvent(app, .{ .appearance_changed = .{ .color_scheme = .light } });
    const light = canvas.DesignTokens.theme(.{ .color_scheme = .light });
    stored = try harness.runtime.canvasWidgetDesignTokens(1, canvas_label);
    try std.testing.expectEqualDeep(light.colors.background, stored.colors.background);

    // Reduce-motion and high-contrast ride the same channel.
    try harness.runtime.dispatchPlatformEvent(app, .{ .appearance_changed = .{ .color_scheme = .dark, .high_contrast = true, .reduce_motion = true } });
    stored = try harness.runtime.canvasWidgetDesignTokens(1, canvas_label);
    const dark_hc = canvas.DesignTokens.theme(.{ .color_scheme = .dark, .contrast = .high, .reduce_motion = true });
    try std.testing.expectEqualDeep(dark_hc.colors.background, stored.colors.background);
    try std.testing.expectEqualDeep(dark_hc.colors.focus_ring, stored.colors.focus_ring);
    try std.testing.expectEqual(@as(u32, 0), stored.motion.normal_ms);

    // Explicit static tokens OPT OUT: the app owns its look and an
    // appearance flip never restyles it.
    const fixed_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(fixed_state);
    var fixed_options = counterOptions();
    fixed_options.name = "ui-app-counter-fixed";
    fixed_options.tokens = canvas.DesignTokens.theme(.{ .color_scheme = .light });
    fixed_state.* = CounterApp.init(std.heap.page_allocator, .{}, fixed_options);
    defer fixed_state.deinit();
    try std.testing.expectEqualDeep(light.colors.background, fixed_state.effectiveTokens().colors.background);
    fixed_state.system_appearance = .{ .color_scheme = .dark };
    try std.testing.expectEqualDeep(light.colors.background, fixed_state.effectiveTokens().colors.background);
}

test "static tokens carry the surface scale and re-snap on a scale change" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    // The app pins its look with static tokens (geometry snapping on,
    // scale 1 inside — the app never knows the monitor).
    var options = counterOptions();
    var static_tokens = canvas.DesignTokens.theme(.{ .color_scheme = .light });
    static_tokens.pixel_snap = .{ .geometry = true, .text = true };
    options.tokens = static_tokens;
    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, options);
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    // Install on a 2x surface: the effective tokens are a stamped COPY —
    // the app owns the appearance, the runtime owns the device scale —
    // and the stored tokens carry the real density, so hairlines snap
    // against the physical grid instead of scale 1.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    try std.testing.expectEqual(@as(f32, 2), app_state.effectiveTokens().pixel_snap.scale);
    var stored = try harness.runtime.canvasWidgetDesignTokens(1, canvas_label);
    try std.testing.expectEqual(@as(f32, 2), stored.pixel_snap.scale);
    try std.testing.expectEqualDeep(static_tokens.colors.background, stored.colors.background);

    // A frame at a new density (the window dragged to a 1x monitor)
    // rebuilds and re-emits for a static-token app too: the stored
    // tokens re-snap to the new grid without any app involvement. The
    // model is poked directly (no dispatch) so the refreshed retained
    // text proves the FRAME triggered the rebuild.
    app_state.model.count = 5;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 2_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 5"));
    try std.testing.expectEqual(@as(f32, 1), app_state.effectiveTokens().pixel_snap.scale);
    stored = try harness.runtime.canvasWidgetDesignTokens(1, canvas_label);
    try std.testing.expectEqual(@as(f32, 1), stored.pixel_snap.scale);
    try std.testing.expectEqualDeep(static_tokens.colors.background, stored.colors.background);
}

test "a resize carrying a new density re-stamps and re-emits at the unchanged logical size" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    // Static tokens make this the strict case: ordinary rebuilds skip
    // the redundant emission, so a re-stamped stored copy below proves
    // the stale-scale re-emit fired.
    var options = counterOptions();
    var static_tokens = canvas.DesignTokens.theme(.{ .color_scheme = .light });
    static_tokens.pixel_snap = .{ .geometry = true, .text = true };
    options.tokens = static_tokens;
    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, options);
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    var stored = try harness.runtime.canvasWidgetDesignTokens(1, canvas_label);
    try std.testing.expectEqual(@as(f32, 2), stored.pixel_snap.scale);

    // A DPI-only monitor move arrives as a resize whose LOGICAL size is
    // unchanged — only the event's scale differs. The resize path must
    // adopt the density before rebuilding, and the rebuild must re-emit
    // even though the layout inputs are identical: without both, the
    // stored tokens keep snapping against the old grid until the next
    // input. The model is poked directly (no dispatch) so the refreshed
    // retained text proves the RESIZE triggered the rebuild.
    app_state.model.count = 7;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = canvas_label,
        .frame = geometry.RectF.init(0, 0, 400, 300),
        .scale_factor = 1,
    } });
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 7"));
    try std.testing.expectEqual(@as(f32, 1), app_state.effectiveTokens().pixel_snap.scale);
    stored = try harness.runtime.canvasWidgetDesignTokens(1, canvas_label);
    try std.testing.expectEqual(@as(f32, 1), stored.pixel_snap.scale);
    try std.testing.expectEqualDeep(static_tokens.colors.background, stored.colors.background);
}

test "markup watch polls from the reserved runtime timer" {
    const io = std.testing.io;
    const watch_path = ".zig-cache/ui-app-markup-watch-test.native";
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = watch_path, .data = counter_markup });
    defer cwd.deleteFile(io, watch_path) catch {};

    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    var options = markupCounterOptions();
    options.markup = .{ .source = counter_markup, .watch_path = watch_path, .io = io };
    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, options);
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    // Install started the reserved repeating watch timer.
    const watch_timer = harness.null_platform.startedTimer(CounterApp.markup_watch_timer_id).?;
    try std.testing.expect(watch_timer.active);
    try std.testing.expect(watch_timer.repeats);
    try std.testing.expectEqual(@as(u64, 500_000_000), watch_timer.interval_ns);

    // An idle poll (file unchanged) issues no frame-chain keepalive request.
    const frame_requests_after_install = harness.null_platform.gpu_surface_frame_request_count;
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 1_500_000).?);
    try std.testing.expectEqual(frame_requests_after_install, harness.null_platform.gpu_surface_frame_request_count);

    // Advance model state, then hot swap the file: the timer poll reloads
    // the markup, rebuilds, and keeps model state.
    const increment_id = findWidgetIdByText(app_state.tree.?, .button, "Increment").?;
    var command_buffer: [96]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, increment_id });
    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);

    try cwd.writeFile(io, .{ .sub_path = watch_path, .data = counter_markup_v2 });
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 2_000_000).?);

    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .button, "Start over") != null);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 1"));
}

const watch_import_root_markup =
    \\<import src="ui-app-markup-watch-parts.native"/>
    \\<column gap="8" padding="12">
    \\  <text>Count {count}</text>
    \\  <use template="actions" />
    \\</column>
;

const watch_import_parts_markup =
    \\<template name="actions">
    \\  <column gap="4">
    \\    <button variant="primary" on-press="increment">Increment</button>
    \\    <button on-press="reset">Reset</button>
    \\  </column>
    \\</template>
;

const watch_import_parts_markup_v2 =
    \\<template name="actions">
    \\  <column gap="4">
    \\    <button variant="primary" on-press="increment">Increment</button>
    \\    <button on-press="reset">Start over</button>
    \\  </column>
    \\</template>
;

test "the markup watch reloads when an IMPORTED file changes on disk" {
    const io = std.testing.io;
    const watch_path = ".zig-cache/ui-app-markup-watch-import-test.native";
    const parts_path = ".zig-cache/ui-app-markup-watch-parts.native";
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = watch_path, .data = watch_import_root_markup });
    defer cwd.deleteFile(io, watch_path) catch {};
    try cwd.writeFile(io, .{ .sub_path = parts_path, .data = watch_import_parts_markup });
    defer cwd.deleteFile(io, parts_path) catch {};

    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    // The embedded source set mirrors the on-disk closure (paths relative
    // to the root file's directory), so the first build and the disk poll
    // agree until something actually changes.
    var options = markupCounterOptions();
    options.markup = .{
        .source = watch_import_root_markup,
        .sources = &.{
            .{ .path = "ui-app-markup-watch-parts.native", .source = watch_import_parts_markup },
        },
        .watch_path = watch_path,
        .io = io,
    };
    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, options);
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    // The imported template built into the view.
    const increment_id = findWidgetIdByText(app_state.tree.?, .button, "Increment").?;

    // An idle poll (closure unchanged) swaps nothing.
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 1_500_000).?);
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .button, "Reset") != null);

    // Advance model state, then edit only the IMPORTED file: the poll
    // covers the whole closure, so the change reloads and rebuilds while
    // model state and ids hold.
    var command_buffer: [96]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, increment_id });
    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);

    try cwd.writeFile(io, .{ .sub_path = parts_path, .data = watch_import_parts_markup_v2 });
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 2_000_000).?);

    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .button, "Start over") != null);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);
    try std.testing.expectEqual(increment_id, findWidgetIdByText(app_state.tree.?, .button, "Increment").?);

    // A broken edit to the imported file keeps the last good view and
    // records a diagnostic naming the imported file.
    try cwd.writeFile(io, .{ .sub_path = parts_path, .data = "<template name=\"actions\"><column><oops</column></template>" });
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 2_500_000).?);
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .button, "Start over") != null);
    try std.testing.expect(app_state.markup_diagnostic != null);
    try std.testing.expect(std.mem.indexOf(u8, app_state.markup_diagnostic.?.path, "ui-app-markup-watch-parts.native") != null);
}

const watch_import_sources = [_]canvas.ui_markup.SourceFile{
    .{ .path = "ui-app-markup-watch-import-baseline.native", .source = watch_import_root_markup },
    .{ .path = "ui-app-markup-watch-parts.native", .source = watch_import_parts_markup },
};

const CompiledImportCounterView = canvas.CompiledMarkupImports(
    CounterModel,
    CounterMsg,
    "ui-app-markup-watch-import-baseline.native",
    &watch_import_sources,
);

test "with imports the compiled view stays the baseline until the watched closure changes" {
    const io = std.testing.io;
    const watch_path = ".zig-cache/ui-app-markup-watch-import-baseline.native";
    const parts_path = ".zig-cache/ui-app-markup-watch-parts.native";
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = watch_path, .data = watch_import_root_markup });
    defer cwd.deleteFile(io, watch_path) catch {};
    try cwd.writeFile(io, .{ .sub_path = parts_path, .data = watch_import_parts_markup });
    defer cwd.deleteFile(io, parts_path) catch {};

    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    var options = markupCounterOptions();
    options.view = CompiledImportCounterView.build;
    options.markup = .{
        .source = watch_import_root_markup,
        .sources = &watch_import_sources,
        .watch_path = watch_path,
        .io = io,
    };
    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, options);
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    try std.testing.expect(app_state.markup_view == null);

    // The disk closure matches the embedded one (the baseline hash covers
    // imports in the same root-relative path space), so an idle poll never
    // phantom-swaps to the interpreter.
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 1_500_000).?);
    try std.testing.expect(app_state.markup_view == null);

    // An edit to the IMPORTED file flips the baseline to the interpreter.
    try cwd.writeFile(io, .{ .sub_path = parts_path, .data = watch_import_parts_markup_v2 });
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 2_000_000).?);
    try std.testing.expect(app_state.markup_view != null);
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .button, "Start over") != null);
}

const CompiledCounterView = canvas.CompiledMarkupView(CounterModel, CounterMsg, counter_markup);

test "a compiled markup view drives the ui app with the runtime markup engine compiled out" {
    const LeanApp = ui_app_model.UiAppWithFeatures(CounterModel, CounterMsg, .{ .runtime_markup = false });

    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(LeanApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = LeanApp.init(std.heap.page_allocator, .{}, .{
        .name = "ui-app-compiled-counter",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = counterUpdate,
        .view = CompiledCounterView.build,
        .on_command = counterCommand,
    });
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 0"));

    // Compiled-markup handlers dispatch through the same typed loop.
    const increment_id = findWidgetIdByText(app_state.tree.?, .button, "Increment").?;
    var command_buffer: [96]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, increment_id });
    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 1"));
    try std.testing.expectEqual(increment_id, findWidgetIdByText(app_state.tree.?, .button, "Increment").?);

    // The runtime engine is compiled out: no watch timer, no reload path.
    try std.testing.expect(harness.null_platform.startedTimer(LeanApp.markup_watch_timer_id) == null);
    try std.testing.expectError(error.MarkupEngineDisabled, app_state.reloadMarkup(counter_markup_v2));
}

test "with view and markup both set the compiled view renders until the watched file changes" {
    const io = std.testing.io;
    const watch_path = ".zig-cache/ui-app-compiled-watch-test.native";
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = watch_path, .data = counter_markup });
    defer cwd.deleteFile(io, watch_path) catch {};

    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    var options = markupCounterOptions();
    options.view = CompiledCounterView.build;
    options.markup = .{ .source = counter_markup, .watch_path = watch_path, .io = io };
    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, options);
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 0"));

    // The compiled view rendered: the interpreter never parsed anything.
    try std.testing.expect(app_state.markup_view == null);

    // An idle poll (file matches the embedded source) keeps it that way.
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 1_500_000).?);
    try std.testing.expect(app_state.markup_view == null);

    // Advance model state, then edit the file: the interpreter takes over
    // with the new source, keeping model state and structural ids.
    const increment_id = findWidgetIdByText(app_state.tree.?, .button, "Increment").?;
    var command_buffer: [96]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, increment_id });
    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);

    try cwd.writeFile(io, .{ .sub_path = watch_path, .data = counter_markup_v2 });
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 2_000_000).?);

    try std.testing.expect(app_state.markup_view != null);
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .button, "Start over") != null);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 1"));
    try std.testing.expectEqual(increment_id, findWidgetIdByText(app_state.tree.?, .button, "Increment").?);
}

// ------------------------------------------------- fragment hot reload
// A HYBRID root: a Zig builder view embedding compiled markup fragments.
// The fragment watch (Options.fragment_watch) is what keeps the edit-see
// loop alive for these apps — without it, editing a fragment's .native
// source in dev does nothing because the fragment was compiled at
// comptime.

const fragment_actions_markup =
    \\<column gap="4">
    \\  <button variant="primary" on-press="increment">Increment</button>
    \\  <button on-press="reset">Reset</button>
    \\</column>
;

const fragment_actions_markup_v2 =
    \\<column gap="4">
    \\  <button variant="primary" on-press="increment">Increment</button>
    \\  <button on-press="reset">Start over</button>
    \\</column>
;

const fragment_actions_path = ".zig-cache/ui-app-fragment-actions.native";

const FragmentActionsView = canvas.CompiledMarkupView(CounterModel, CounterMsg, fragment_actions_markup);

fn hybridCounterView(ui: *CounterApp.Ui, model: *const CounterModel) CounterApp.Ui.Node {
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.text(.{}, ui.fmt("Count {d}", .{model.count})),
        FragmentActionsView.build(ui, model),
    });
}

const hybrid_counter_fragments = [_]canvas.MarkupFragment{
    FragmentActionsView.fragment(fragment_actions_path),
};

fn hybridCounterOptions(io: std.Io) CounterApp.Options {
    var options = counterOptions();
    options.name = "ui-app-hybrid-counter";
    options.view = hybridCounterView;
    options.fragment_watch = .{ .fragments = &hybrid_counter_fragments, .io = io };
    return options;
}

/// Install the app on the harness and drive the first gpu frame (the
/// installing frame, which also arms the markup watch).
fn installCounterApp(harness: anytype, app: core.App) !void {
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
}

test "the fragment watch reloads a compiled fragment embedded in a Zig view" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = fragment_actions_path, .data = fragment_actions_markup });
    defer cwd.deleteFile(io, fragment_actions_path) catch {};

    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, hybridCounterOptions(io));
    defer app_state.deinit();
    const app = app_state.app();
    try installCounterApp(harness, app);
    try std.testing.expect(app_state.installed);

    // Registered fragments arm the watch — the same reserved repeating
    // timer as the single-root watch — and the armed state is honest in
    // the automation snapshot bit even though the app has no markup root.
    try std.testing.expect(harness.null_platform.startedTimer(CounterApp.markup_watch_timer_id) != null);
    try std.testing.expect(harness.runtime.markup_watch_armed);

    // An idle poll (file matches the embedded baseline) keeps the
    // comptime-compiled path: no override document is adopted.
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 1_500_000).?);
    try std.testing.expect(app_state.markup_fragment_slots[0].document == null);
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .button, "Reset") != null);

    // Advance model state, then edit the fragment's file: the poll
    // reloads THAT fragment through the interpreter and rebuilds while
    // model state and structural ids hold.
    const increment_id = findWidgetIdByText(app_state.tree.?, .button, "Increment").?;
    var command_buffer: [96]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, increment_id });
    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);

    try cwd.writeFile(io, .{ .sub_path = fragment_actions_path, .data = fragment_actions_markup_v2 });
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 2_000_000).?);
    try std.testing.expect(app_state.markup_fragment_slots[0].document != null);
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .button, "Start over") != null);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "Count 1"));
    try std.testing.expectEqual(increment_id, findWidgetIdByText(app_state.tree.?, .button, "Increment").?);

    // Reverting the file byte for byte drops the override: back to the
    // comptime-compiled path, the release-identical one.
    try cwd.writeFile(io, .{ .sub_path = fragment_actions_path, .data = fragment_actions_markup });
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 2_500_000).?);
    try std.testing.expect(app_state.markup_fragment_slots[0].document == null);
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .button, "Reset") != null);
}

test "a broken fragment save keeps the last good view and the next good save recovers" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = fragment_actions_path, .data = fragment_actions_markup });
    defer cwd.deleteFile(io, fragment_actions_path) catch {};

    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, hybridCounterOptions(io));
    defer app_state.deinit();
    const app = app_state.app();
    try installCounterApp(harness, app);
    try std.testing.expect(app_state.installed);

    // A save that does not parse: the fragment keeps its last good view,
    // the app keeps running, and the teaching diagnostic names the file.
    try cwd.writeFile(io, .{ .sub_path = fragment_actions_path, .data = "<column><oops</column>" });
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 1_500_000).?);
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .button, "Reset") != null);
    try std.testing.expect(app_state.markup_diagnostic != null);
    try std.testing.expect(std.mem.indexOf(u8, app_state.markup_diagnostic.?.path, "ui-app-fragment-actions.native") != null);

    // A save that parses but cannot build against the Model (a binding
    // naming no model field — what the compiled engine rejects at
    // comptime): the frame aborts, the last good tree stays up, and the
    // diagnostic reports through the same channel.
    try cwd.writeFile(io, .{ .sub_path = fragment_actions_path, .data = "<column><text>{missing_field}</text></column>" });
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 2_000_000).?);
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .button, "Reset") != null);
    try std.testing.expect(app_state.markup_diagnostic != null);

    // The next good save recovers in place.
    try cwd.writeFile(io, .{ .sub_path = fragment_actions_path, .data = fragment_actions_markup_v2 });
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 2_500_000).?);
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .button, "Start over") != null);
    try std.testing.expect(app_state.markup_diagnostic == null);
}

// Two fragments importing ONE shared component file: the import-closure
// propagation rule is that editing the shared file reloads every fragment
// whose closure reaches it, in the same poll.

const fragment_badge_a_markup =
    \\<import src="ui-app-fragment-parts.native"/>
    \\<row gap="4">
    \\  <text>Badge A</text>
    \\  <use template="chip" />
    \\</row>
;

const fragment_badge_b_markup =
    \\<import src="ui-app-fragment-parts.native"/>
    \\<row gap="4">
    \\  <text>Badge B</text>
    \\  <use template="chip" />
    \\</row>
;

const fragment_parts_markup =
    \\<template name="chip">
    \\  <text>Alpha</text>
    \\</template>
;

const fragment_parts_markup_v2 =
    \\<template name="chip">
    \\  <text>Beta</text>
    \\</template>
;

const fragment_badge_a_path = ".zig-cache/ui-app-fragment-badge-a.native";
const fragment_badge_b_path = ".zig-cache/ui-app-fragment-badge-b.native";
const fragment_parts_path = ".zig-cache/ui-app-fragment-parts.native";

const fragment_badge_a_sources = [_]canvas.ui_markup.SourceFile{
    .{ .path = "ui-app-fragment-badge-a.native", .source = fragment_badge_a_markup },
    .{ .path = "ui-app-fragment-parts.native", .source = fragment_parts_markup },
};
const fragment_badge_b_sources = [_]canvas.ui_markup.SourceFile{
    .{ .path = "ui-app-fragment-badge-b.native", .source = fragment_badge_b_markup },
    .{ .path = "ui-app-fragment-parts.native", .source = fragment_parts_markup },
};

const FragmentBadgeAView = canvas.CompiledMarkupImports(CounterModel, CounterMsg, "ui-app-fragment-badge-a.native", &fragment_badge_a_sources);
const FragmentBadgeBView = canvas.CompiledMarkupImports(CounterModel, CounterMsg, "ui-app-fragment-badge-b.native", &fragment_badge_b_sources);

fn badgesCounterView(ui: *CounterApp.Ui, model: *const CounterModel) CounterApp.Ui.Node {
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        FragmentBadgeAView.build(ui, model),
        FragmentBadgeBView.build(ui, model),
    });
}

const badges_counter_fragments = [_]canvas.MarkupFragment{
    FragmentBadgeAView.fragment(fragment_badge_a_path),
    FragmentBadgeBView.fragment(fragment_badge_b_path),
};

fn countTextIn(widget: canvas.Widget, text: []const u8) usize {
    var count: usize = 0;
    if (widget.kind == .text and std.mem.eql(u8, widget.text, text)) count += 1;
    for (widget.children) |child| count += countTextIn(child, text);
    return count;
}

test "editing a shared imported file reloads every fragment whose imports reach it" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = fragment_badge_a_path, .data = fragment_badge_a_markup });
    defer cwd.deleteFile(io, fragment_badge_a_path) catch {};
    try cwd.writeFile(io, .{ .sub_path = fragment_badge_b_path, .data = fragment_badge_b_markup });
    defer cwd.deleteFile(io, fragment_badge_b_path) catch {};
    try cwd.writeFile(io, .{ .sub_path = fragment_parts_path, .data = fragment_parts_markup });
    defer cwd.deleteFile(io, fragment_parts_path) catch {};

    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    var options = counterOptions();
    options.name = "ui-app-badges-counter";
    options.view = badgesCounterView;
    options.fragment_watch = .{ .fragments = &badges_counter_fragments, .io = io };
    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, options);
    defer app_state.deinit();
    const app = app_state.app();
    try installCounterApp(harness, app);
    try std.testing.expect(app_state.installed);

    // Both compiled fragments rendered the shared template.
    try std.testing.expectEqual(@as(usize, 2), countTextIn(app_state.tree.?.root, "Alpha"));

    // An idle poll leaves both fragments compiled: the embedded baseline
    // hash covers the whole import closure, so nothing phantom-reloads.
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 1_500_000).?);
    try std.testing.expect(app_state.markup_fragment_slots[0].document == null);
    try std.testing.expect(app_state.markup_fragment_slots[1].document == null);

    // Editing only the SHARED imported file reloads BOTH fragments in
    // one poll — a file may serve several fragments, and every one of
    // its dependents rebuilds fresh.
    try cwd.writeFile(io, .{ .sub_path = fragment_parts_path, .data = fragment_parts_markup_v2 });
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 2_000_000).?);
    try std.testing.expectEqual(@as(usize, 2), countTextIn(app_state.tree.?.root, "Beta"));
    try std.testing.expectEqual(@as(usize, 0), countTextIn(app_state.tree.?.root, "Alpha"));

    // Editing one fragment's ROOT file reloads only that fragment; the
    // other keeps its current view.
    const badge_a_v2 = try std.mem.concat(std.testing.allocator, u8, &.{ fragment_badge_a_markup, "\n" });
    defer std.testing.allocator.free(badge_a_v2);
    try cwd.writeFile(io, .{ .sub_path = fragment_badge_a_path, .data = badge_a_v2 });
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.fireTimer(CounterApp.markup_watch_timer_id, 2_500_000).?);
    try std.testing.expect(app_state.markup_fragment_slots[0].document != null);
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .text, "Badge A") != null);
    try std.testing.expect(findWidgetIdByText(app_state.tree.?, .text, "Badge B") != null);
}

test "a hybrid app with no registered fragments keeps the markup watch off" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, counterOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try installCounterApp(harness, app);
    try std.testing.expect(app_state.installed);

    // No markup root, no fragments: the watch never arms and the
    // automation snapshot bit honestly reports off.
    try std.testing.expect(harness.null_platform.startedTimer(CounterApp.markup_watch_timer_id) == null);
    try std.testing.expect(!harness.runtime.markup_watch_armed);
}

const RosterModel = struct {
    row_count: usize = 70,

    pub fn rows(model: *const RosterModel, arena: std.mem.Allocator) []const usize {
        const out = arena.alloc(usize, model.row_count) catch return &.{};
        for (out, 0..) |*slot, index| slot.* = index;
        return out[0..model.row_count];
    }
};

const RosterMsg = union(enum) { noop };
const RosterApp = ui_app_model.UiApp(RosterModel, RosterMsg);

fn rosterUpdate(model: *RosterModel, msg: RosterMsg) void {
    _ = model;
    _ = msg;
}

fn rosterKey(index: *const usize) canvas.UiKey {
    return canvas.uiKey(@as(u64, index.*));
}

fn rosterRow(ui: *RosterApp.Ui, index: *const usize) RosterApp.Ui.Node {
    return ui.row(.{ .gap = 4 }, .{
        ui.checkbox(.{ .on_toggle = .noop }),
        ui.text(.{ .grow = 1 }, ui.fmt("Row {d}", .{index.*})),
    });
}

fn rosterView(ui: *RosterApp.Ui, model: *const RosterModel) RosterApp.Ui.Node {
    return ui.column(.{ .gap = 2 }, ui.each(model.rows(ui.arena), rosterKey, rosterRow));
}

test "widget trees beyond the old 64-node cap install and reconcile" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 2000) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(RosterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = RosterApp.init(std.heap.page_allocator, .{}, .{
        .name = "ui-app-roster",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = rosterUpdate,
        .view = rosterView,
    });
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 2000),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    // 70 keyed rows x (row + checkbox + text) + root column = 211 nodes.
    const layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expect(layout.nodes.len > 64);
    try std.testing.expectEqual(@as(usize, 211), layout.nodes.len);

    // A rebuild through the reconcile path holds at that size.
    try app_state.rebuild(&harness.runtime, 1);
    try std.testing.expectEqual(@as(usize, 211), (try harness.runtime.canvasWidgetLayout(1, canvas_label)).nodes.len);
}

// ---------------------------------------------------------------- set_text

const mirror_canvas_label = "mirror-canvas";

const MirrorModel = struct {
    draft: canvas.TextBuffer(64) = .{},
    edit_count: u32 = 0,
    submit_count: u32 = 0,
};

const MirrorMsg = union(enum) {
    draft_edit: canvas.TextInputEvent,
    submit,
};

const MirrorApp = ui_app_model.UiApp(MirrorModel, MirrorMsg);

fn mirrorUpdate(model: *MirrorModel, msg: MirrorMsg) void {
    switch (msg) {
        .draft_edit => |edit| {
            model.draft.apply(edit);
            model.edit_count += 1;
        },
        .submit => model.submit_count += 1,
    }
}

fn mirrorView(ui: *MirrorApp.Ui, model: *const MirrorModel) MirrorApp.Ui.Node {
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.textField(.{
            .text = model.draft.text(),
            .placeholder = "Message",
            .on_input = MirrorApp.Ui.inputMsg(.draft_edit),
            .on_submit = .submit,
        }),
        ui.text(.{}, if (model.draft.isEmpty()) "Send disabled" else "Send enabled"),
    });
}

const mirror_views = [_]app_manifest.ShellView{
    .{ .label = mirror_canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const mirror_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Mirror",
    .width = 400,
    .height = 300,
    .views = &mirror_views,
}};
const mirror_scene: app_manifest.ShellConfig = .{ .windows = &mirror_windows };

fn findWidgetIdByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.ObjectId {
    if (widget.kind == kind) return widget.id;
    for (widget.children) |child| {
        if (findWidgetIdByKind(child, kind)) |id| return id;
    }
    return null;
}

test "automation set_text routes through the input path so the elm mirror stays consistent" {
    // `widget-action <id> set_text` used to write the
    // runtime editor state directly and never dispatch `on_input`, so a
    // TEA app's model still saw an empty buffer (Send stayed disabled
    // while the field visibly held text — a state no real user can
    // produce).
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(MirrorApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = MirrorApp.init(std.heap.page_allocator, .{}, .{
        .name = "ui-app-mirror",
        .scene = mirror_scene,
        .canvas_label = mirror_canvas_label,
        .update = mirrorUpdate,
        .view = mirrorView,
    });
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = mirror_canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    const field_id = findWidgetIdByKind(app_state.tree.?.root, .text_field).?;

    // set_text lands in the runtime editor AND the model mirror.
    try core.testing.dispatchAutomationWidgetAction(&harness.runtime, app, .{
        .view_label = mirror_canvas_label,
        .id = field_id,
        .action = .set_text,
        .value = "ship the fix",
    });
    try std.testing.expectEqualStrings("ship the fix", app_state.model.draft.text());
    try std.testing.expect(app_state.model.edit_count > 0);
    const layout = try harness.runtime.canvasWidgetLayout(1, mirror_canvas_label);
    try std.testing.expectEqualStrings("ship the fix", layout.findById(field_id).?.widget.text);

    // The dependent view state follows the model, not just the editor.
    var found_enabled = false;
    for (layout.nodes) |node| {
        if (node.widget.kind == .text and std.mem.eql(u8, node.widget.text, "Send enabled")) found_enabled = true;
    }
    try std.testing.expect(found_enabled);

    // Replacing existing text keeps model and editor in lockstep.
    try core.testing.dispatchAutomationWidgetAction(&harness.runtime, app, .{
        .view_label = mirror_canvas_label,
        .id = field_id,
        .action = .set_text,
        .value = "second draft",
    });
    try std.testing.expectEqualStrings("second draft", app_state.model.draft.text());
    const replaced_layout = try harness.runtime.canvasWidgetLayout(1, mirror_canvas_label);
    try std.testing.expectEqualStrings("second draft", replaced_layout.findById(field_id).?.widget.text);

    // Clearing through set_text "" also flows through the input path.
    try core.testing.dispatchAutomationWidgetAction(&harness.runtime, app, .{
        .view_label = mirror_canvas_label,
        .id = field_id,
        .action = .set_text,
        .value = "",
    });
    try std.testing.expectEqualStrings("", app_state.model.draft.text());
    const cleared_layout = try harness.runtime.canvasWidgetLayout(1, mirror_canvas_label);
    try std.testing.expectEqualStrings("", cleared_layout.findById(field_id).?.widget.text);

    // The automation snapshot agrees with both.
    const snapshot = harness.runtime.automationSnapshot("Mirror");
    for (snapshot.widgets) |widget| {
        if (widget.id == field_id) try std.testing.expectEqualStrings("", widget.text_value);
    }
}

// ------------------------------------------------- autofocus (notes flow)

const autofocus_canvas_label = "autofocus-canvas"; // shell scene label below

const AutofocusModel = struct {
    editing: bool = false,
    draft: canvas.TextBuffer(64) = .{},
    edit_count: u32 = 0,
};

const AutofocusMsg = union(enum) {
    begin_edit,
    draft_edit: canvas.TextInputEvent,
};

const AutofocusApp = ui_app_model.UiApp(AutofocusModel, AutofocusMsg);

fn autofocusUpdate(model: *AutofocusModel, msg: AutofocusMsg) void {
    switch (msg) {
        .begin_edit => model.editing = true,
        .draft_edit => |edit| {
            model.draft.apply(edit);
            model.edit_count += 1;
        },
    }
}

/// The notes shape: Cmd-N-style command mounts an inline editor that
/// must receive the keyboard without a click.
fn autofocusView(ui: *AutofocusApp.Ui, model: *const AutofocusModel) AutofocusApp.Ui.Node {
    if (!model.editing) {
        return ui.column(.{ .gap = 8, .padding = 12 }, .{
            ui.button(.{ .on_press = AutofocusMsg.begin_edit }, "New note"),
        });
    }
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.button(.{ .on_press = AutofocusMsg.begin_edit }, "New note"),
        ui.textField(.{
            .autofocus = true,
            .text = model.draft.text(),
            .on_input = AutofocusApp.Ui.inputMsg(.draft_edit),
        }),
    });
}

fn autofocusCommand(name: []const u8) ?AutofocusMsg {
    if (std.mem.eql(u8, name, "note.new")) return .begin_edit;
    return null;
}

const autofocus_views = [_]app_manifest.ShellView{
    .{ .label = autofocus_canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const autofocus_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Autofocus",
    .width = 400,
    .height = 300,
    .views = &autofocus_views,
}};
const autofocus_scene: app_manifest.ShellConfig = .{ .windows = &autofocus_windows };

test "ui app autofocus moves the keyboard to a freshly mounted editor through the real dispatch path" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(AutofocusApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = AutofocusApp.init(std.heap.page_allocator, .{}, .{
        .name = "ui-app-autofocus",
        .scene = autofocus_scene,
        .canvas_label = autofocus_canvas_label,
        .update = autofocusUpdate,
        .view = autofocusView,
        .on_command = autofocusCommand,
    });
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = autofocus_canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    var view_index: usize = 0;
    for (harness.runtime.views[0..harness.runtime.view_count], 0..) |view, index| {
        if (std.mem.eql(u8, view.label, autofocus_canvas_label)) view_index = index;
    }
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[view_index].canvas_widget_focused_id);

    // The Cmd-N-shaped command mounts the editor; the rebuild's
    // autofocus edge moves keyboard focus to it — no click.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "note.new", .window_id = 1 } });
    try std.testing.expect(app_state.model.editing);
    const field_id = findWidgetIdByKind(app_state.tree.?.root, .text_field).?;
    try std.testing.expectEqual(field_id, harness.runtime.views[view_index].canvas_widget_focused_id);

    // Typing lands in the model through the ordinary input path.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = autofocus_canvas_label,
        .kind = .text_input,
        .text = "Groceries",
    } });
    try std.testing.expectEqualStrings("Groceries", app_state.model.draft.text());
    try std.testing.expect(app_state.model.edit_count > 0);

    // A later rebuild with the flag still true never re-steals focus:
    // click the button (its press dispatches begin_edit and rebuilds).
    const button_id = findWidgetIdByKind(app_state.tree.?.root, .button).?;
    var command_buffer: [96]u8 = undefined;
    const click_command = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ autofocus_canvas_label, button_id });
    try harness.runtime.dispatchAutomationCommand(app, click_command);
    try std.testing.expectEqual(button_id, harness.runtime.views[view_index].canvas_widget_focused_id);
}

// -------------------------------------------------------- layout capacity

const CapacityModel = struct {
    row_count: usize = 4,

    pub fn rows(model: *const CapacityModel, arena: std.mem.Allocator) []const usize {
        const out = arena.alloc(usize, model.row_count) catch return &.{};
        for (out, 0..) |*slot, index| slot.* = index;
        return out;
    }
};

const CapacityMsg = union(enum) {
    start,
    grew: effects_mod.EffectExit,
};

const CapacityApp = ui_app_model.UiApp(CapacityModel, CapacityMsg);
const CapacityEffects = CapacityApp.Effects;
const capacity_key: u64 = 77;

fn capacityUpdate(model: *CapacityModel, msg: CapacityMsg, fx: *CapacityEffects) void {
    switch (msg) {
        .start => fx.spawn(.{
            .key = capacity_key,
            .argv = &.{"grow"},
            .on_exit = CapacityEffects.exitMsg(.grew),
        }),
        // The grown roster far exceeds the per-view widget budget.
        .grew => model.row_count = core.max_canvas_widget_nodes_per_view + 40,
    }
}

fn capacityKey(index: *const usize) canvas.UiKey {
    return canvas.uiKey(@as(u64, index.*));
}

fn capacityRow(ui: *CapacityApp.Ui, index: *const usize) CapacityApp.Ui.Node {
    return ui.text(.{}, ui.fmt("Row {d}", .{index.*}));
}

fn capacityView(ui: *CapacityApp.Ui, model: *const CapacityModel) CapacityApp.Ui.Node {
    return ui.column(.{ .gap = 2 }, ui.each(model.rows(ui.arena), capacityKey, capacityRow));
}

test "an effects-wake rebuild past the widget budget fails tests loudly and degrades in production" {
    // A rebuild that blew max_canvas_widget_nodes_per_view
    // on an effects-wake drain used to vanish into the dispatch-error ring — the
    // test saw a passing dispatch and a silently stale frame.
    // The failing layout warns through std.log (the teaching diagnostic
    // under test would otherwise fail the build runner's stderr check).
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;

    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 2000) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(CapacityApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CapacityApp.init(std.heap.page_allocator, .{}, .{
        .name = "ui-app-capacity",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update_fx = capacityUpdate,
        .view = capacityView,
    });
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 2000),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    // A fake spawn exit flips the model past the budget; the wake drain's
    // rebuild fails — and under the harness's `.propagate` default the
    // error reaches the test instead of leaving a stale frame.
    try app_state.dispatch(&harness.runtime, 1, .start);
    try app_state.effects.feedExit(capacity_key, 0);
    try std.testing.expectError(
        error.WidgetLayoutListFull,
        harness.runtime.dispatchPlatformEvent(app, .wake),
    );
    // Recording still happened before the propagate.
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.dispatchErrors().len);
    try std.testing.expectEqualStrings("effects_wake", harness.runtime.dispatchErrors()[0].event);
    try std.testing.expectEqualStrings("WidgetLayoutListFull", harness.runtime.dispatchErrors()[0].error_name);

    // Production policy: the same failure degrades — recorded in the
    // dispatch-error ring, never fatal.
    harness.runtime.dispatch_error_policy = .degrade;
    app_state.model.row_count = 4;
    try app_state.dispatch(&harness.runtime, 1, .start);
    try app_state.effects.feedExit(capacity_key, 0);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try std.testing.expectEqual(@as(usize, 2), harness.runtime.dispatchErrors().len);
    try std.testing.expectEqualStrings("WidgetLayoutListFull", harness.runtime.dispatchErrors()[1].error_name);
}

// --------------------------------------------------- automation degrade

test "a stale automation widget click degrades instead of killing the frame callback" {
    // `frame()` used to `try` the consumed automation
    // command, so a widget-click on an unmounted id escaped the
    // frame_requested platform callback and stopped the whole app
    // (CallbackFailed). Automation misuse always degrades — even under
    // the harness's `.propagate` policy.
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, counterOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    // Wire a file-backed automation server and inject a click on a
    // widget id that is not mounted.
    const io = std.testing.io;
    const directory = ".zig-cache/test-ui-app-automation-degrade";
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, directory) catch {};
    try cwd.createDirPath(io, directory);
    defer cwd.deleteTree(io, directory) catch {};
    harness.runtime.options.automation = automation.Server.init(io, directory, "Degrade");
    var command_path_buffer: [128]u8 = undefined;
    const command_path = try std.fmt.bufPrint(&command_path_buffer, "{s}/command-1.txt", .{directory});
    try cwd.writeFile(io, .{ .sub_path = command_path, .data = "widget-click counter-canvas 999999\n" });

    // The frame pump consumes the command without propagating.
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    const errors = harness.runtime.dispatchErrors();
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqualStrings("automation.widget_click", errors[0].event);
    try std.testing.expectEqualStrings("InvalidCommand", errors[0].error_name);

    // The app is still alive: a real click keeps dispatching.
    const increment_id = findWidgetIdByText(app_state.tree.?, .button, "Increment").?;
    var command_buffer: [96]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, increment_id });
    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);
}

test "rapid-fire automation commands all dispatch, one per frame turn" {
    // The field reproduction for the queued dropbox: three commands land
    // back-to-back BEFORE the app drains any of them (the old
    // single-entry slot lost one of these to an overwrite). Zero may be
    // lost, and the drain must stay one-command-per-`frame_requested`
    // turn — the recorded event boundary replay determinism hangs on.
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(CounterApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = CounterApp.init(std.heap.page_allocator, .{}, counterOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    const io = std.testing.io;
    const directory = ".zig-cache/test-ui-app-automation-rapid-fire";
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, directory) catch {};
    try cwd.createDirPath(io, directory);
    defer cwd.deleteTree(io, directory) catch {};
    harness.runtime.options.automation = automation.Server.init(io, directory, "RapidFire");

    // Three increments queued before a single frame runs.
    const increment_id = findWidgetIdByText(app_state.tree.?, .button, "Increment").?;
    var sequence: u64 = 1;
    while (sequence <= 3) : (sequence += 1) {
        var command_path_buffer: [128]u8 = undefined;
        var command_buffer: [128]u8 = undefined;
        try cwd.writeFile(io, .{
            .sub_path = try std.fmt.bufPrint(&command_path_buffer, "{s}/command-{d}.txt", .{ directory, sequence }),
            .data = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}\n", .{ canvas_label, increment_id }),
        });
    }

    // Each frame turn consumes exactly one queued command — never two,
    // never zero — until the queue is drained.
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.count);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try std.testing.expectEqual(@as(u32, 2), app_state.model.count);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try std.testing.expectEqual(@as(u32, 3), app_state.model.count);
    // Drained: further frames dispatch nothing and no errors were
    // recorded along the way.
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try std.testing.expectEqual(@as(u32, 3), app_state.model.count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.dispatchErrors().len);
}

// ---------------------------------------------------------- webview panes

const preview_canvas_label = "preview-canvas";
const preview_pane_anchor = "preview-pane";
const example_url = "https://example.com/";
const docs_url = "https://native-sdk.dev/";

const PreviewModel = struct {
    show_docs: bool = false,
    reload_token: u64 = 0,

    fn url(model: *const PreviewModel) []const u8 {
        return if (model.show_docs) docs_url else example_url;
    }
};

const PreviewMsg = union(enum) {
    show_docs,
    show_example,
    reload,
};

const PreviewApp = ui_app_model.UiApp(PreviewModel, PreviewMsg);

fn previewUpdate(model: *PreviewModel, msg: PreviewMsg) void {
    switch (msg) {
        .show_docs => model.show_docs = true,
        .show_example => model.show_docs = false,
        .reload => model.reload_token += 1,
    }
}

fn previewView(ui: *PreviewApp.Ui, model: *const PreviewModel) PreviewApp.Ui.Node {
    _ = model;
    return ui.row(.{ .gap = 0 }, .{
        ui.column(.{ .width = 200, .padding = 12, .gap = 8 }, .{
            ui.button(.{ .on_press = .show_docs }, "Docs"),
            ui.button(.{ .on_press = .show_example }, "Example"),
            ui.button(.{ .on_press = .reload }, "Reload"),
        }),
        // The empty panel that reserves the webview region: the pane
        // anchor resolves to this widget's layout frame.
        ui.panel(.{ .grow = 1, .semantics = .{ .label = preview_pane_anchor } }, .{}),
    });
}

fn previewPanes(model: *const PreviewModel, out: []PreviewApp.WebViewPane) usize {
    out[0] = .{
        .label = "preview",
        .anchor = preview_pane_anchor,
        .url = model.url(),
        .reload_token = model.reload_token,
    };
    return 1;
}

const preview_views = [_]app_manifest.ShellView{
    .{ .label = preview_canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
    .{ .label = "preview", .kind = .webview, .parent = preview_canvas_label, .url = example_url, .x = 200, .y = 0, .width = 440, .height = 480 },
};
const preview_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Preview",
    .width = 640,
    .height = 480,
    .views = &preview_views,
}};
const preview_scene: app_manifest.ShellConfig = .{ .windows = &preview_windows };
const preview_origins = [_][]const u8{ "https://example.com", "https://native-sdk.dev", "zero://app", "zero://inline" };

fn previewOptions() PreviewApp.Options {
    return .{
        .name = "ui-app-preview",
        .scene = preview_scene,
        .canvas_label = preview_canvas_label,
        .update = previewUpdate,
        .view = previewView,
        .web_panes = previewPanes,
    };
}

fn previewHarnessAndApp(app_state: *PreviewApp) !*core.TestHarness() {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(640, 480) });
    errdefer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &preview_origins;

    app_state.* = PreviewApp.init(std.heap.page_allocator, .{}, previewOptions());
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = preview_canvas_label,
        .size = geometry.SizeF.init(640, 480),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    return harness;
}

fn previewNullWebView(harness: *core.TestHarness()) !null_platform_mod.NullWebView {
    for (harness.null_platform.webviews[0..harness.null_platform.webview_count]) |webview| {
        if (std.mem.eql(u8, webview.label, "preview")) return webview;
    }
    return error.TestUnexpectedResult;
}

test "ui app scene with a child webview stays main-webview-free" {
    const app_state = try std.testing.allocator.create(PreviewApp);
    defer std.testing.allocator.destroy(app_state);
    const harness = try previewHarnessAndApp(app_state);
    defer harness.destroy(std.testing.allocator);
    defer app_state.deinit();

    // The canvas-first scene never grows an implicit main webview: the
    // loaded source stays null and only the declared views exist.
    try std.testing.expect(harness.runtime.loaded_source == null);
    var views_buffer: [8]zero_platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 2), views.len);
    for (views) |view| {
        try std.testing.expect(!std.mem.eql(u8, view.label, "main"));
    }
}

test "ui app webview pane snaps the webview to the anchor widget frame" {
    const app_state = try std.testing.allocator.create(PreviewApp);
    defer std.testing.allocator.destroy(app_state);
    const harness = try previewHarnessAndApp(app_state);
    defer harness.destroy(std.testing.allocator);
    defer app_state.deinit();

    try std.testing.expect(app_state.installed);
    const webview = try previewNullWebView(harness);
    try std.testing.expect(webview.open);
    try std.testing.expectEqualStrings(example_url, webview.url);

    // The pane frame is the anchor widget's layout frame: the row's
    // remaining width after the 200pt sidebar column.
    const layout = try harness.runtime.canvasWidgetLayout(1, preview_canvas_label);
    var anchor_frame: ?geometry.RectF = null;
    for (layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, preview_pane_anchor)) anchor_frame = node.frame;
    }
    try std.testing.expect(anchor_frame != null);
    try std.testing.expect(anchor_frame.?.width > 0);
    try std.testing.expectApproxEqAbs(anchor_frame.?.x, webview.frame.x, 0.5);
    try std.testing.expectApproxEqAbs(anchor_frame.?.y, webview.frame.y, 0.5);
    try std.testing.expectApproxEqAbs(anchor_frame.?.width, webview.frame.width, 0.5);
    try std.testing.expectApproxEqAbs(anchor_frame.?.height, webview.frame.height, 0.5);

    // A resize rebuild follows the anchor to its new frame.
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_resized = .{
        .label = preview_canvas_label,
        .window_id = 1,
        .frame = geometry.RectF.init(0, 0, 900, 600),
        .scale_factor = 1,
    } });
    const resized = try previewNullWebView(harness);
    try std.testing.expectApproxEqAbs(@as(f32, 900 - 200), resized.frame.width, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 600), resized.frame.height, 0.5);
}

test "ui app webview pane navigates on url change and reloads on token bump" {
    const app_state = try std.testing.allocator.create(PreviewApp);
    defer std.testing.allocator.destroy(app_state);
    const harness = try previewHarnessAndApp(app_state);
    defer harness.destroy(std.testing.allocator);
    defer app_state.deinit();

    const navigations_after_install = harness.null_platform.webview_navigate_count;

    // A model-driven URL change navigates the webview.
    try app_state.dispatch(&harness.runtime, 1, .show_docs);
    var webview = try previewNullWebView(harness);
    try std.testing.expectEqualStrings(docs_url, webview.url);
    try std.testing.expectEqual(navigations_after_install + 1, harness.null_platform.webview_navigate_count);

    // A rebuild without a URL change does not renavigate.
    try app_state.dispatch(&harness.runtime, 1, .show_docs);
    try std.testing.expectEqual(navigations_after_install + 1, harness.null_platform.webview_navigate_count);

    // Bumping the reload token renavigates the same URL.
    try app_state.dispatch(&harness.runtime, 1, .reload);
    webview = try previewNullWebView(harness);
    try std.testing.expectEqualStrings(docs_url, webview.url);
    try std.testing.expectEqual(navigations_after_install + 2, harness.null_platform.webview_navigate_count);
}

// ----------------------------------------------------------- status item

const StatusModel = struct {
    refresh_count: u32 = 0,
};

const StatusMsg = union(enum) {
    refresh,
};

const StatusApp = ui_app_model.UiApp(StatusModel, StatusMsg);

fn statusUpdate(model: *StatusModel, msg: StatusMsg) void {
    switch (msg) {
        .refresh => model.refresh_count += 1,
    }
}

fn statusView(ui: *StatusApp.Ui, model: *const StatusModel) StatusApp.Ui.Node {
    return ui.column(.{ .padding = 12 }, .{
        ui.text(.{}, ui.fmt("Refreshed {d}", .{model.refresh_count})),
    });
}

fn statusCommand(name: []const u8) ?StatusMsg {
    if (std.mem.eql(u8, name, "app.refresh")) return .refresh;
    return null;
}

const status_items = [_]zero_platform.TrayMenuItem{
    .{ .id = 1, .label = "Refresh", .command = "app.refresh" },
    .{ .separator = true },
    .{ .id = 2, .label = "About" },
};

test "ui app status item installs a tray and dispatches its commands" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(StatusApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = StatusApp.init(std.heap.page_allocator, .{}, .{
        .name = "ui-app-status",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = statusUpdate,
        .view = statusView,
        .on_command = statusCommand,
        .status_item = .{
            .title = "NS",
            .tooltip = "native-sdk status",
            .items = &status_items,
        },
    });
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.trayCreateCount());

    // The installing frame creates the status item exactly once.
    const frame_event = zero_platform.GpuSurfaceFrameEvent{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    };
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = frame_event });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.trayCreateCount());
    try std.testing.expectEqualStrings("NS", harness.null_platform.lastTrayTitle());
    try std.testing.expectEqualStrings("native-sdk status", harness.null_platform.lastTrayTooltip());
    try std.testing.expectEqual(@as(usize, 3), harness.null_platform.trayItems().len);
    var second_frame = frame_event;
    second_frame.frame_index = 2;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = second_frame });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.trayCreateCount());

    // Selecting the item dispatches its command through on_command.
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try std.testing.expectEqual(@as(u32, 1), app_state.model.refresh_count);
    // Items without commands fall back to the generic name and map to
    // no Msg here.
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 2 });
    try std.testing.expectEqual(@as(u32, 1), app_state.model.refresh_count);
}

// ------------------------------------------------ model-driven status item

const TrayStateModel = struct {
    open_count: u32 = 3,
    selected_issue: u32 = 0,
    issues: [2][]const u8 = .{ "Fix crash on resize", "Adopt the tray seam" },
};

const TrayStateMsg = union(enum) {
    refresh,
    select_issue: u32,
};

const TrayStateApp = ui_app_model.UiApp(TrayStateModel, TrayStateMsg);

fn trayStateUpdate(model: *TrayStateModel, msg: TrayStateMsg) void {
    switch (msg) {
        .refresh => model.open_count += 1,
        .select_issue => |index| model.selected_issue = index,
    }
}

fn trayStateView(ui: *TrayStateApp.Ui, model: *const TrayStateModel) TrayStateApp.Ui.Node {
    return ui.column(.{ .padding = 12 }, .{
        ui.text(.{}, ui.fmt("Selected {d}", .{model.selected_issue})),
    });
}

fn trayStateCommand(name: []const u8) ?TrayStateMsg {
    if (std.mem.eql(u8, name, "app.refresh")) return .refresh;
    if (std.mem.eql(u8, name, "issue.select.0")) return .{ .select_issue = 0 };
    if (std.mem.eql(u8, name, "issue.select.1")) return .{ .select_issue = 1 };
    return null;
}

/// A desktop issues-client menu-bar extra shape: an open-count badge in
/// the title and the latest issues in the dropdown, each row selecting
/// its issue.
fn trayStateStatusItem(model: *const TrayStateModel, scratch: *TrayStateApp.StatusItemScratch) TrayStateApp.StatusItemState {
    const title = std.fmt.bufPrint(&scratch.title_buffer, "ZN {d}", .{model.open_count}) catch "ZN";
    scratch.items[0] = .{ .id = 1, .label = "Refresh", .command = "app.refresh" };
    scratch.items[1] = .{ .separator = true };
    const commands = [_][]const u8{ "issue.select.0", "issue.select.1" };
    for (model.issues, 0..) |issue_title, index| {
        scratch.items[2 + index] = .{
            .id = @intCast(10 + index),
            .label = issue_title,
            .command = commands[index],
            // The selected row reads as such (also exercises menu-change
            // detection when the selection moves).
            .enabled = model.selected_issue != index,
        };
    }
    return .{ .title = title, .items = scratch.items[0..4] };
}

test "ui app status_item_fn drives the tray title and menu from the model" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(TrayStateApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = TrayStateApp.init(std.heap.page_allocator, .{}, .{
        .name = "ui-app-tray-state",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = trayStateUpdate,
        .view = trayStateView,
        .on_command = trayStateCommand,
        .status_item = .{ .tooltip = "issue tracker" },
        .status_item_fn = trayStateStatusItem,
    });
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    // The installing frame creates the tray FROM THE MODEL: derived
    // title, derived dropdown, static tooltip.
    const frame_event = zero_platform.GpuSurfaceFrameEvent{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    };
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = frame_event });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.trayCreateCount());
    try std.testing.expectEqualStrings("ZN 3", harness.null_platform.lastTrayTitle());
    try std.testing.expectEqualStrings("issue tracker", harness.null_platform.lastTrayTooltip());
    try std.testing.expectEqual(@as(usize, 4), harness.null_platform.trayItems().len);
    try std.testing.expectEqualStrings("Fix crash on resize", harness.null_platform.trayItems()[2].label);
    const updates_after_install = harness.null_platform.trayUpdateCount();
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.trayTitleUpdateCount());

    // A model change that only affects the TITLE re-titles the live
    // button without rebuilding the menu or re-creating the item.
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try std.testing.expectEqual(@as(u32, 4), app_state.model.open_count);
    try std.testing.expectEqualStrings("ZN 4", harness.null_platform.lastTrayTitle());
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.trayTitleUpdateCount());
    try std.testing.expectEqual(updates_after_install, harness.null_platform.trayUpdateCount());
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.trayCreateCount());

    // Selecting a dropdown row closes the loop: tray action -> command ->
    // Msg -> model, and the menu (not the title) re-applies.
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 11 });
    try std.testing.expectEqual(@as(u32, 1), app_state.model.selected_issue);
    try std.testing.expectEqual(updates_after_install + 1, harness.null_platform.trayUpdateCount());
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.trayTitleUpdateCount());
    try std.testing.expect(!harness.null_platform.trayItems()[3].enabled);

    // A rebuild whose tray output is unchanged touches nothing (the
    // repeat selection Msg still rebuilds the view).
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 11 });
    try std.testing.expectEqual(updates_after_install + 1, harness.null_platform.trayUpdateCount());
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.trayTitleUpdateCount());
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.trayCreateCount());
}

test "ui app tray state rides automation snapshots and tray-action drives a row" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(TrayStateApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = TrayStateApp.init(std.heap.page_allocator, .{}, .{
        .name = "ui-app-tray-automation",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = trayStateUpdate,
        .view = trayStateView,
        .on_command = trayStateCommand,
        .status_item = .{ .tooltip = "issue tracker" },
        .status_item_fn = trayStateStatusItem,
    });
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    // Before the tray installs, snapshots carry no tray lines.
    {
        var buffer: [32768]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try automation.snapshot.writeText(harness.runtime.automationSnapshot("Tray"), &writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "tray title=") == null);
    }

    const frame_event = zero_platform.GpuSurfaceFrameEvent{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    };
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = frame_event });

    // The snapshot exposes the applied tray: model-derived title, every
    // dropdown row with id/label/command/enabled, and separators —
    // the menu bar is outside every window capture, so this is the only
    // automation-visible evidence the model-driven tray exists.
    {
        var buffer: [32768]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try automation.snapshot.writeText(harness.runtime.automationSnapshot("Tray"), &writer);
        const text = writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, text, "tray title=\"ZN 3\" items=4\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "  tray-item #1 label=\"Refresh\" command=\"app.refresh\" enabled=true\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "  tray-item separator\n") != null);
        // The fixture disables the SELECTED row (initially issue 0).
        try std.testing.expect(std.mem.indexOf(u8, text, "  tray-item #10 label=\"Fix crash on resize\" command=\"issue.select.0\" enabled=false\n") != null);
    }

    // `tray-action <id>` drives a dropdown row through the same platform
    // event a real NSStatusItem menu click emits: command -> Msg -> model,
    // and the re-derived tray re-applies.
    try harness.runtime.dispatchAutomationCommand(app, "tray-action 11");
    try std.testing.expectEqual(@as(u32, 1), app_state.model.selected_issue);
    {
        var buffer: [32768]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try automation.snapshot.writeText(harness.runtime.automationSnapshot("Tray"), &writer);
        const text = writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, text, "  tray-item #11 label=\"Adopt the tray seam\" command=\"issue.select.1\" enabled=false\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "  tray-item #10 label=\"Fix crash on resize\" command=\"issue.select.0\" enabled=true\n") != null);
    }

    // Unknown or malformed item ids are loud driver misuse, never a
    // silent no-op or a fallback command dispatch.
    try std.testing.expectError(error.InvalidCommand, harness.runtime.dispatchAutomationCommand(app, "tray-action 99"));
    try std.testing.expectError(error.InvalidCommand, harness.runtime.dispatchAutomationCommand(app, "tray-action open"));
    try std.testing.expectEqual(@as(u32, 1), app_state.model.selected_issue);
}

const TaskModel = struct {
    completed: u32 = 0,
    deleted: u32 = 0,
};

const TaskMsg = union(enum) {
    complete,
    delete,
};

const TaskApp = ui_app_model.UiApp(TaskModel, TaskMsg);

fn taskUpdate(model: *TaskModel, msg: TaskMsg) void {
    switch (msg) {
        .complete => model.completed += 1,
        .delete => model.deleted += 1,
    }
}

fn taskView(ui: *TaskApp.Ui, model: *const TaskModel) TaskApp.Ui.Node {
    _ = model;
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.el(.list_item, .{
            .text = "Ship the release",
            .context_menu = &.{
                .{ .label = "Complete", .msg = .complete },
                .{ .separator = true },
                .{ .label = "Delete", .msg = .delete },
            },
        }, .{}),
    });
}

test "ui app dispatches native context menu selections as typed messages" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(TaskApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = TaskApp.init(std.heap.page_allocator, .{}, .{
        .name = "ui-app-context-menu",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = taskUpdate,
        .view = taskView,
    });
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    // Right-click inside the row's retained frame.
    const row_id = findIn(app_state.tree.?.root, .list_item, "Ship the release").?;
    const layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    var row_frame: geometry.RectF = .{};
    for (layout.nodes) |node| {
        if (node.widget.id == row_id) row_frame = node.frame;
    }
    try std.testing.expect(!row_frame.isEmpty());
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .button = 1,
        .x = row_frame.x + 4,
        .y = row_frame.y + 4,
        .timestamp_ns = 2_000_000,
    } });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.context_menu_request_count);
    try std.testing.expectEqual(@as(u64, row_id), harness.null_platform.context_menu_token);
    try std.testing.expectEqual(@as(usize, 3), harness.null_platform.contextMenuItems().len);

    // Selecting "Delete" (item id 3 = third declared entry) dispatches
    // the declared Msg through update.
    try harness.runtime.dispatchPlatformEvent(app, .{ .context_menu_action = .{
        .window_id = 1,
        .view_label = canvas_label,
        .token = row_id,
        .item_id = 3,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.model.deleted);
    try std.testing.expectEqual(@as(u32, 0), app_state.model.completed);
}

// ------------------------------------------------- press fall-through fixture

const RowsModel = struct {
    picked: u32 = 0,
    picks: u32 = 0,
    button_hits: u32 = 0,
};

const RowsMsg = union(enum) {
    pick: u32,
    button_hit,
};

const RowsApp = ui_app_model.UiApp(RowsModel, RowsMsg);

fn rowsUpdate(model: *RowsModel, msg: RowsMsg) void {
    switch (msg) {
        .pick => |id| {
            model.picked = id;
            model.picks += 1;
        },
        .button_hit => model.button_hits += 1,
    }
}

fn rowsView(ui: *RowsApp.Ui, model: *const RowsModel) RowsApp.Ui.Node {
    _ = model;
    // The showcase row shape the press fall-through exists for: pressable
    // panels whose visible content is plain (selectable) text — no
    // empty-text overlays, no duplicated handlers on the text leaves.
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.panel(.{ .on_press = RowsMsg{ .pick = 1 }, .height = 48 }, .{
            ui.row(.{ .gap = 8, .padding = 8 }, .{
                ui.text(.{ .grow = 1 }, "Alpha row label"),
            }),
        }),
        ui.panel(.{ .on_press = RowsMsg{ .pick = 2 }, .height = 48 }, .{
            ui.row(.{ .gap = 8, .padding = 8 }, .{
                ui.text(.{ .grow = 1 }, "Beta row label"),
                ui.button(.{ .on_press = .button_hit }, "Open"),
            }),
        }),
    });
}

fn rowsOptions() RowsApp.Options {
    return .{
        .name = "ui-app-rows",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = rowsUpdate,
        .view = rowsView,
    };
}

fn rowsWidgetCenter(runtime: *core.Runtime, id: canvas.ObjectId) !geometry.PointF {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    return layout.findById(id).?.frame.normalized().center();
}

fn rowsPointer(kind: zero_platform.GpuSurfaceInputKind, point: geometry.PointF, timestamp_ns: u64) zero_platform.Event {
    return .{ .gpu_surface_input = .{
        .label = canvas_label,
        .kind = kind,
        .timestamp_ns = timestamp_ns,
        .x = point.x,
        .y = point.y,
    } };
}

fn rowsTextSelection(runtime: *core.Runtime, id: canvas.ObjectId) !?canvas.TextSelection {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    return layout.findById(id).?.widget.text_selection;
}

test "presses on a pressable row's plain text land on the row, live and via automation" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(RowsApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = RowsApp.init(std.heap.page_allocator, .{}, rowsOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    const tree = app_state.tree.?;
    const alpha_row_id = tree.root.children[0].id;
    const alpha_text_id = findIn(tree.root, .text, "Alpha row label").?;
    const button_id = findIn(tree.root, .button, "Open").?;

    // A live click on the row's plain text lands on the row's on_press.
    const text_center = try rowsWidgetCenter(&harness.runtime, alpha_text_id);
    try harness.runtime.dispatchPlatformEvent(app, rowsPointer(.pointer_down, text_center, 2_000_000));
    try harness.runtime.dispatchPlatformEvent(app, rowsPointer(.pointer_up, text_center, 2_100_000));
    try std.testing.expectEqual(@as(u32, 1), app_state.model.picks);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.picked);

    // A button inside a pressable row claims its own press — the button
    // wins, the row does not fire.
    const button_center = try rowsWidgetCenter(&harness.runtime, button_id);
    try harness.runtime.dispatchPlatformEvent(app, rowsPointer(.pointer_down, button_center, 3_000_000));
    try harness.runtime.dispatchPlatformEvent(app, rowsPointer(.pointer_up, button_center, 3_100_000));
    try std.testing.expectEqual(@as(u32, 1), app_state.model.button_hits);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.picks);

    // The automation click path agrees with the live hit test: clicking
    // the row id (whose center is covered by its text) and clicking the
    // text id both land on the row.
    var command_buffer: [96]u8 = undefined;
    const row_click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, alpha_row_id });
    try harness.runtime.dispatchAutomationCommand(app, row_click);
    try std.testing.expectEqual(@as(u32, 2), app_state.model.picks);
    var text_command_buffer: [96]u8 = undefined;
    const text_click = try std.fmt.bufPrint(&text_command_buffer, "widget-click {s} {d}", .{ canvas_label, alpha_text_id });
    try harness.runtime.dispatchAutomationCommand(app, text_click);
    try std.testing.expectEqual(@as(u32, 3), app_state.model.picks);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.button_hits);
}

test "selection drag inside a pressable row selects without pressing; a click still presses" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(RowsApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = RowsApp.init(std.heap.page_allocator, .{}, rowsOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });

    const alpha_text_id = findIn(app_state.tree.?.root, .text, "Alpha row label").?;
    const layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    const text_frame = layout.findById(alpha_text_id).?.frame.normalized();
    const start = geometry.PointF.init(text_frame.x + 2, text_frame.center().y);
    const end = geometry.PointF.init(text_frame.x + text_frame.width * 0.7, text_frame.center().y);

    // Down + drag + up: the gesture selects text within the row and
    // presses NOTHING — dragging selects, clicking presses.
    try harness.runtime.dispatchPlatformEvent(app, rowsPointer(.pointer_down, start, 2_000_000));
    try harness.runtime.dispatchPlatformEvent(app, rowsPointer(.pointer_drag, end, 2_050_000));
    try harness.runtime.dispatchPlatformEvent(app, rowsPointer(.pointer_up, end, 2_100_000));
    const selection = (try rowsTextSelection(&harness.runtime, alpha_text_id)).?;
    try std.testing.expect(!selection.isCollapsed("Alpha row label".len));
    try std.testing.expectEqual(@as(u32, 0), app_state.model.picks);

    // A plain click on the same text collapses the selection on the way
    // down and the press lands on the row.
    const center = try rowsWidgetCenter(&harness.runtime, alpha_text_id);
    try harness.runtime.dispatchPlatformEvent(app, rowsPointer(.pointer_down, center, 3_000_000));
    try harness.runtime.dispatchPlatformEvent(app, rowsPointer(.pointer_up, center, 3_100_000));
    try std.testing.expectEqual(@as(u32, 1), app_state.model.picks);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.picked);
}

// --------------------------------------------------------------- on_chrome

const ChromeInsetModel = struct {
    leading: f32 = 0,
    top: f32 = 0,
    /// The traffic-light cluster's vertical centerline — what a header
    /// centers its controls against in the tall band.
    buttons_center_y: f32 = 0,
    deliveries: u32 = 0,
};

const ChromeInsetMsg = union(enum) {
    chrome: zero_platform.WindowChrome,
};

const ChromeInsetApp = ui_app_model.UiApp(ChromeInsetModel, ChromeInsetMsg);

fn chromeInsetUpdate(model: *ChromeInsetModel, msg: ChromeInsetMsg) void {
    switch (msg) {
        .chrome => |chrome| {
            model.leading = chrome.insets.left;
            model.top = chrome.insets.top;
            model.buttons_center_y = chrome.buttons.y + chrome.buttons.height / 2;
            model.deliveries += 1;
        },
    }
}

fn chromeInsetView(ui: *ChromeInsetApp.Ui, model: *const ChromeInsetModel) ChromeInsetApp.Ui.Node {
    return ui.column(.{ .gap = 8 }, .{
        ui.row(.{ .window_drag = true, .height = 40 }, .{
            ui.el(.stack, .{ .width = model.leading }, .{}),
            ui.text(.{}, "Header"),
        }),
        ui.text(.{}, ui.fmt("leading {d}", .{model.leading})),
    });
}

fn chromeInsetMap(chrome: zero_platform.WindowChrome) ?ChromeInsetMsg {
    return .{ .chrome = chrome };
}

test "ui app delivers chrome overlay geometry before install and on change" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    // Model a tall hidden-titlebar macOS host: unified band 52pt tall,
    // traffic lights ending 78pt in and vertically centered in the band.
    harness.null_platform.window_chrome = .{
        .insets = .{ .top = 52, .left = 78 },
        .buttons = geometry.RectF.init(12, 19, 54, 14),
    };

    const app_state = try std.testing.allocator.create(ChromeInsetApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = ChromeInsetApp.init(std.heap.page_allocator, .{}, .{
        .name = "ui-app-chrome",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = chromeInsetUpdate,
        .view = chromeInsetView,
        .on_chrome = chromeInsetMap,
    });
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    // The insets land in the model BEFORE the first view build, so the
    // installing frame already renders the padded header.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.deliveries);
    try std.testing.expectEqual(@as(f32, 78), app_state.model.leading);
    try std.testing.expectEqual(@as(f32, 52), app_state.model.top);
    // The buttons frame carries the vertical truth: centerline at
    // 19 + 14/2 = 26, the tall band's midpoint.
    try std.testing.expectEqual(@as(f32, 26), app_state.model.buttons_center_y);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "leading 78"));

    // A resize with unchanged insets dispatches nothing extra.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = canvas_label,
        .frame = geometry.RectF.init(0, 0, 640, 480),
        .scale_factor = 2,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.model.deliveries);

    // Fullscreen hides the chrome: the resize that accompanies the
    // transition re-queries and delivers the zeroed geometry.
    harness.null_platform.window_chrome = .{};
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = canvas_label,
        .frame = geometry.RectF.init(0, 0, 1440, 900),
        .scale_factor = 2,
    } });
    try std.testing.expectEqual(@as(u32, 2), app_state.model.deliveries);
    try std.testing.expectEqual(@as(f32, 0), app_state.model.leading);
    try std.testing.expectEqual(@as(f32, 0), app_state.model.buttons_center_y);
    try std.testing.expect(try retainedTextExists(&harness.runtime, "leading 0"));
}

// -------------------------------------- windowed virtual list fixture

const VirtualFeedModel = struct {
    /// Items currently loaded; `load_more` appends batches to a cap.
    loaded: usize = 400,
    /// Every reach-end dispatch, including the ones past the cap.
    fetches: u32 = 0,
};

const VirtualFeedMsg = union(enum) {
    load_more,
};

const VirtualFeedApp = ui_app_model.UiApp(VirtualFeedModel, VirtualFeedMsg);

const virtual_feed_batch: usize = 100;
const virtual_feed_cap: usize = 600;
const virtual_row_extent: f32 = 24;

fn virtualFeedUpdate(model: *VirtualFeedModel, msg: VirtualFeedMsg) void {
    switch (msg) {
        .load_more => {
            model.fetches += 1;
            if (model.loaded < virtual_feed_cap) model.loaded += virtual_feed_batch;
        },
    }
}

fn virtualFeedOptions(model: *const VirtualFeedModel) VirtualFeedApp.Ui.VirtualListOptions {
    return .{
        .id = "vfeed",
        .item_count = model.loaded,
        .item_extent = virtual_row_extent,
        .overscan = 2,
        .grow = 1,
        .on_reach_end = .load_more,
    };
}

/// The windowed pattern: ask for the visible range, build ONLY those
/// rows from the model, hand both to `virtualList`. Deliberately no
/// `on_scroll` binding — the runtime re-derives the view on scroll for
/// mounted virtual lists on its own.
fn virtualFeedView(ui: *VirtualFeedApp.Ui, model: *const VirtualFeedModel) VirtualFeedApp.Ui.Node {
    const options = virtualFeedOptions(model);
    const window = ui.virtualWindow(options);
    const rows = ui.arena.alloc(VirtualFeedApp.Ui.Node, window.itemCount()) catch {
        ui.failed = true;
        return ui.column(.{}, .{});
    };
    for (rows, 0..) |*row, offset| {
        const index = window.start_index + offset;
        var node = ui.listItem(.{}, ui.fmt("Item {d}", .{index}));
        node.key = .{ .int = @intCast(index) };
        row.* = node;
    }
    return ui.virtualList(options, window, .{rows});
}

fn virtualFeedAppOptions() VirtualFeedApp.Options {
    return .{
        .name = "ui-app-virtual-feed",
        .scene = counter_scene,
        .canvas_label = canvas_label,
        .update = virtualFeedUpdate,
        .view = virtualFeedView,
    };
}

test "windowed virtual list scrolls, re-windows, budgets to the viewport, and fires reach-end with hysteresis" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(VirtualFeedApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = VirtualFeedApp.init(std.heap.page_allocator, .{}, virtualFeedAppOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    // The first build materialized only the first window (300pt viewport
    // at 24pt rows + 2 overscan = 15 rows), never the 400 loaded items.
    const list_id = canvas.globalWidgetId(.scroll_view, .{ .str = "vfeed" });
    try std.testing.expectEqual(list_id, app_state.tree.?.root.id);
    try std.testing.expectEqual(@as(usize, 15), app_state.tree.?.root.children.len);
    try std.testing.expectEqual(@as(usize, 0), app_state.tree.?.root.layout.virtual_first_index);

    // A wheel scroll with NO on_scroll binding still re-windows the
    // view: the runtime owns the offset, the scroll observation itself
    // triggers the re-derivation.
    var command_buffer: [96]u8 = undefined;
    var wheel = try std.fmt.bufPrint(&command_buffer, "widget-wheel {s} {d} 240", .{ canvas_label, list_id });
    try harness.runtime.dispatchAutomationCommand(app, wheel);
    try std.testing.expectEqual(@as(usize, 8), app_state.tree.?.root.layout.virtual_first_index);
    try std.testing.expect(findIn(app_state.tree.?.root, .list_item, "Item 8") != null);
    try std.testing.expect(findIn(app_state.tree.?.root, .list_item, "Item 0") == null);
    const retained = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expectEqual(@as(f32, 240), retained.findById(list_id).?.widget.value);

    // Row identity is the item, not the slot: item 10 was in both
    // windows and kept its structural id across the shift.
    // (The id is derived from the list id and the item key alone.)
    try std.testing.expect(findIn(app_state.tree.?.root, .list_item, "Item 10") != null);

    // Scroll to the end of the loaded 400 items (content 9600, viewport
    // 300, max offset 9300): the approach-end signal fires ONCE and the
    // model appends a batch.
    try std.testing.expectEqual(@as(u32, 0), app_state.model.fetches);
    wheel = try std.fmt.bufPrint(&command_buffer, "widget-wheel {s} {d} 9060", .{ canvas_label, list_id });
    try harness.runtime.dispatchAutomationCommand(app, wheel);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.fetches);
    try std.testing.expectEqual(@as(usize, 500), app_state.model.loaded);

    // The appended batch grew the extent (12_000), pulling the offset
    // out of the band — the next small scroll re-arms, no fire.
    wheel = try std.fmt.bufPrint(&command_buffer, "widget-wheel {s} {d} 24", .{ canvas_label, list_id });
    try harness.runtime.dispatchAutomationCommand(app, wheel);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.fetches);

    // Ride to the new end: fires again (offset 9324 + 2376 = 11_700 =
    // the new max), appends to the 600 cap.
    wheel = try std.fmt.bufPrint(&command_buffer, "widget-wheel {s} {d} 2376", .{ canvas_label, list_id });
    try harness.runtime.dispatchAutomationCommand(app, wheel);
    try std.testing.expectEqual(@as(u32, 2), app_state.model.fetches);
    try std.testing.expectEqual(@as(usize, 600), app_state.model.loaded);

    // At the cap the model stops appending, so the extent stops
    // growing — riding the end must NOT dispatch a fetch storm.
    wheel = try std.fmt.bufPrint(&command_buffer, "widget-wheel {s} {d} 24", .{ canvas_label, list_id });
    try harness.runtime.dispatchAutomationCommand(app, wheel);
    wheel = try std.fmt.bufPrint(&command_buffer, "widget-wheel {s} {d} 2376", .{ canvas_label, list_id });
    try harness.runtime.dispatchAutomationCommand(app, wheel);
    try std.testing.expectEqual(@as(u32, 3), app_state.model.fetches);
    wheel = try std.fmt.bufPrint(&command_buffer, "widget-wheel {s} {d} -24", .{ canvas_label, list_id });
    try harness.runtime.dispatchAutomationCommand(app, wheel);
    wheel = try std.fmt.bufPrint(&command_buffer, "widget-wheel {s} {d} 24", .{ canvas_label, list_id });
    try harness.runtime.dispatchAutomationCommand(app, wheel);
    try std.testing.expectEqual(@as(u32, 3), app_state.model.fetches);

    // Budget stays viewport-sized throughout: ~19 mounted rows against
    // 600 loaded items, and the scroll semantics report the full extent.
    const final_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expect(final_layout.nodes.len < 40);
    const scroll_state = harness.runtime.views[0].canvasWidgetScrollStateById(list_id).?;
    try std.testing.expectEqual(@as(f32, 600 * virtual_row_extent), scroll_state.content_extent);

    // A window-growing resize converges within ONE rebuild: the first
    // build pass reads the stale 300pt viewport, the coverage check sees
    // the fresh 600pt geometry under-covered, and the retry pass builds
    // the wider window against it.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = canvas_label,
        .frame = geometry.RectF.init(0, 0, 400, 600),
        .scale_factor = 2,
    } });
    const root = app_state.tree.?.root;
    const first_index = root.layout.virtual_first_index;
    const mounted = root.children.len;
    // Offset clamps to the new max (14_400 - 600 = 13_800): visible rows
    // 575..600 must all be inside the built window.
    try std.testing.expect(first_index <= 575);
    try std.testing.expectEqual(@as(usize, 600), first_index + mounted);
    try std.testing.expect(mounted >= 25);
}
