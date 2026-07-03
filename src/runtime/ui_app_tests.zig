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
    const watch_path = ".zig-cache/ui-app-compiled-watch-test.zml";
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
    // Friction #39: `widget-action <id> set_text` used to write the
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

// -------------------------------------------------- layout capacity (#56)

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
    // Friction #56: a rebuild that blew max_canvas_widget_nodes_per_view
    // on an effects-wake drain used to vanish into the #38 ring — the
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

    // Production policy: the same failure degrades — recorded in the #38
    // ring, never fatal.
    harness.runtime.dispatch_error_policy = .degrade;
    app_state.model.row_count = 4;
    try app_state.dispatch(&harness.runtime, 1, .start);
    try app_state.effects.feedExit(capacity_key, 0);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try std.testing.expectEqual(@as(usize, 2), harness.runtime.dispatchErrors().len);
    try std.testing.expectEqualStrings("WidgetLayoutListFull", harness.runtime.dispatchErrors()[1].error_name);
}

// ---------------------------------------------- automation degrade (#61)

test "a stale automation widget click degrades instead of killing the frame callback" {
    // Friction #61: `frame()` used to `try` the consumed automation
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
    const command_path = try std.fmt.bufPrint(&command_path_buffer, "{s}/command.txt", .{directory});
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

// ---------------------------------------------------------- webview panes

const preview_canvas_label = "preview-canvas";
const preview_pane_anchor = "preview-pane";
const example_url = "https://example.com/";
const docs_url = "https://zero-native.dev/";

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
const preview_origins = [_][]const u8{ "https://example.com", "https://zero-native.dev", "zero://app", "zero://inline" };

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
            .title = "ZN",
            .tooltip = "zero-native status",
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
    try std.testing.expectEqualStrings("ZN", harness.null_platform.lastTrayTitle());
    try std.testing.expectEqualStrings("zero-native status", harness.null_platform.lastTrayTooltip());
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
