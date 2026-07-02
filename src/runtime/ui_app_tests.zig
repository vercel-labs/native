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

// ------------------------------------------------------------------ hooks

const ThemedModel = struct {
    count: u32 = 0,
    dark: bool = false,
    high_contrast: bool = false,
    frame_reports: u32 = 0,
    slider_value: f32 = 0.5,
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
        .slider_changed => {},
    }
}

fn themedView(ui: *ThemedApp.Ui, model: *const ThemedModel) ThemedApp.Ui.Node {
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
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

test "markup watch polls from the reserved runtime timer" {
    const io = std.testing.io;
    const watch_path = ".zig-cache/ui-app-markup-watch-test.zml";
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
