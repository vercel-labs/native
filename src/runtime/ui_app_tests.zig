const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");

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

fn findWidgetIdByText(tree: CounterApp.Ui.Tree, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
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
    const harness = try std.testing.allocator.create(core.TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{ .size = geometry.SizeF.init(400, 300) });
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
