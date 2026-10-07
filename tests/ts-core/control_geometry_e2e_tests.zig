//! Complete geometry and command-prefix parity through the shipped library.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const c = sdk.canvas;
const p = c.control_geometry_policy;
const controls = p.reference_controls;
const scroll = p.reference_scroll;
const exact = @import("component_construction_e2e_tests.zig").exact;
fn owned(tokens: c.DesignTokens) c.DesignTokens {
    var t = tokens;
    t.control_geometry_policy = core.nativeWindowPolicy;
    return t;
}
fn compare(widget: c.Widget, tokens: c.DesignTokens) !void {
    const t = owned(tokens);
    try exact(controls.checkboxWidgetBoxRect(widget, tokens), controls.checkboxWidgetBoxRect(widget, t));
    try exact(controls.radioWidgetCircleRect(widget, tokens), controls.radioWidgetCircleRect(widget, t));
    try exact(controls.toggleWidgetTrackRect(widget, tokens), controls.toggleWidgetTrackRect(widget, t));
    // The native slider asserts ordered bounds; NaN x is outside its domain.
    if (!std.math.isNan(widget.frame.x)) try exact(controls.sliderWidgetKnobRect(widget, tokens), controls.sliderWidgetKnobRect(widget, t));
    try exact(c.toggleWidgetKnobTravel(widget, tokens), c.toggleWidgetKnobTravel(widget, t));
    var underline = tokens; underline.controls.tabs_indicator = .underline;
    try exact(controls.segmentedControlUnderlineRect(widget, underline), controls.segmentedControlUnderlineRect(widget, owned(underline)));
    const copied = p.controls(widget, t, .choice);
    core.rt.frameReset();
    try exact(copied, p.controls(widget, t, .choice));
}
test "compiled control geometry preserves density size snapping and exceptional value words" {
    _ = core.initialModel();
    var widget: c.Widget = .{ .kind = .switch_control, .id = std.math.maxInt(u64), .frame = .init(-5.25, 3.75, 111.125, 27.625) };
    for (std.enums.values(c.Density)) |density| for (std.enums.values(c.WidgetSize)) |size| for ([_]f32{ 0, 1, 1.25, 2, -1, std.math.inf(f32), std.math.nan(f32) }) |scale| for ([_]u32{ 0, 0x80000000, 1, 0x3f000000, 0x3f800000, 0xbf800000, 0x40000000, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc12345, 0x7f812345, 0xff812345 }) |word| {
        var t: c.DesignTokens = .{};
        t.density = density;
        t.pixel_snap.scale = scale;
        widget.size = size;
        widget.value = @bitCast(word);
        compare(widget, t) catch |err| {
            std.debug.print("geometry density {t} size {t} scale {d} word {x}\n", .{ density, size, scale, word });
            return err;
        };
    };
}
test "compiled control geometry preserves exceptional frames and chrome metrics" {
    _ = core.initialModel();
    const words = [_]u32{ 0, 0x80000000, 1, 0x3f800000, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc12345, 0x7f812345, 0xff812345 };
    for (words) |word| for ([_]bool{ false, true }) |snapped| {
        const scalar: f32 = @bitCast(word);
        var widget: c.Widget = .{ .kind = .switch_control, .frame = .init(5.25, 6.75, 100.125, 27.625) };
        var t: c.DesignTokens = .{};
        t.pixel_snap.geometry = snapped;
        inline for (.{ "x", "y", "width", "height" }) |name| {
            const saved = widget.frame;
            @field(widget.frame, name) = scalar;
            compare(widget, t) catch |err| {
                std.debug.print("geometry frame {s} word {x} snap {}\n", .{ name, word, snapped });
                return err;
            };
            widget.frame = saved;
        }
        inline for (.{ "slider_track_height", "slider_thumb_width", "slider_thumb_height" }) |name| {
            const saved = t.metrics;
            @field(t.metrics, name) = scalar;
            compare(widget, t) catch |err| {
                std.debug.print("geometry metric {s} word {x} snap {}\n", .{ name, word, snapped });
                return err;
            };
            t.metrics = saved;
        }
    };
}
test "compiled control geometry preserves scrollbar axes corner gaps and static child metrics" {
    _ = core.initialModel();
    const frame: sdk.geometry.RectF = .init(-3.25, 6.75, 154.125, 91.625);
    var t: c.DesignTokens = .{};
    for (std.enums.values(c.Density)) |density| for ([_]f32{ 1, 1.5, 2 }) |scale| for ([_]f32{ -10, 0, 20, 999, std.math.inf(f32), std.math.nan(f32) }) |offset| for ([_]f32{ 0, 40, 100, 999, std.math.inf(f32), std.math.nan(f32) }) |content| {
        t.density = density;
        t.pixel_snap.scale = scale;
        const metric: c.WidgetScrollMetrics = .{ .present = true, .offset = offset, .viewport_extent = 40, .content_extent = content };
        for ([_]c.ScrollAxis{ .vertical, .horizontal }) |axis| for ([_]f32{ -1, 0, 9 }) |reserve| try exact(scroll.scrollViewScrollbarGeometryForAxis(frame, metric, t, axis, reserve), scroll.scrollViewScrollbarGeometryForAxis(frame, metric, owned(t), axis, reserve));
    };
    const children = [_]c.Widget{ .{ .kind = .text, .frame = .init(-1, 8, 201, 50) }, .{ .kind = .text, .frame = .init(1, 120, 300, 80) } };
    var widget: c.Widget = .{ .kind = .scroll_view, .frame = frame, .children = &children, .value = 13, .value_x = 17 };
    widget.layout.padding = .{ .left = 2, .right = 5, .top = 3, .bottom = 6 };
    for (std.enums.values(@TypeOf(widget.scroll_axes))) |axes| {
        widget.scroll_axes = axes;
        for ([_]c.ScrollAxis{ .vertical, .horizontal }) |axis| try exact(scroll.widgetScrollAxisMetricsForWidget(widget, t, axis), scroll.widgetScrollAxisMetricsForWidget(widget, owned(t), axis));
    }
    const many = [_]c.Widget{.{ .kind = .text, .frame = .init(1, 120, 300, 80) }} ** 33;
    widget.children = &many;
    try exact(scroll.widgetScrollMetricsForWidget(widget, t), scroll.widgetScrollMetricsForWidget(widget, owned(t)));
    widget.layout.virtualized = true;
    widget.layout.virtual_item_extent = 24;
    widget.layout.virtual_item_count = 100;
    widget.scroll_axes = .both;
    for ([_]c.ScrollAxis{ .vertical, .horizontal }) |axis| try exact(scroll.widgetScrollAxisMetricsForWidget(widget, t, axis), scroll.widgetScrollAxisMetricsForWidget(widget, owned(t), axis));
    for ([_]u32{ 0x7fc12345, 0xffc12345, 0x7f812345, 0xff812345 }) |word| {
        widget.value = @bitCast(word);
        try exact(scroll.widgetScrollMetricsForWidget(widget, t), scroll.widgetScrollMetricsForWidget(widget, owned(t)));
    }
    widget.layout.virtualized = false;
    widget.layout.padding.left = 999;
    try exact(scroll.widgetScrollMetricsForWidget(widget, t), scroll.widgetScrollMetricsForWidget(widget, owned(t)));
}
test "compiled control geometry preserves exceptional scrollbar fields" {
    _ = core.initialModel();
    const words = [_]u32{ 0, 0x80000000, 1, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc12345, 0x7f812345, 0xff812345 };
    const frame: sdk.geometry.RectF = .init(-3.25, 6.75, 333.125, 91.625);
    const original: c.WidgetScrollMetrics = .{ .present = true, .offset = 10, .viewport_extent = 40, .content_extent = 120 };
    for (words) |word| for ([_]c.ScrollAxis{ .vertical, .horizontal }) |axis| {
        const value: f32 = @bitCast(word);
        inline for (.{ "offset", "viewport_extent", "content_extent" }) |name| {
            var metric = original;
            @field(metric, name) = value;
            exact(scroll.scrollViewScrollbarGeometryForAxis(frame, metric, .{}, axis, 0), scroll.scrollViewScrollbarGeometryForAxis(frame, metric, owned(.{}), axis, 0)) catch |err| {
                std.debug.print("scroll field {s} word {x} axis {t}\n", .{ name, word, axis });
                return err;
            };
        }
        try exact(scroll.scrollViewScrollbarGeometryForAxis(frame, original, .{}, axis, value), scroll.scrollViewScrollbarGeometryForAxis(frame, original, owned(.{}), axis, value));
    };
}
test "compiled control geometry preserves underline measurements and grouped radius words" {
    _ = core.initialModel();
    var widget: c.Widget = .{ .kind = .segmented_control, .frame = .init(1.25, 3.75, 100.5, 27.25), .text = "Caf\xc3\xa9", .icon = "+" };
    var t: c.DesignTokens = .{};
    t.controls.tabs_indicator = .underline;
    for (std.enums.values(c.WidgetSize)) |size| for ([_]f32{ 1, 1.5, 2 }) |scale| {
        widget.size = size;
        t.pixel_snap.scale = scale;
        try exact(controls.segmentedControlUnderlineRect(widget, t), controls.segmentedControlUnderlineRect(widget, owned(t)));
    };
    widget.text = "";
    widget.icon = "";
    try exact(controls.segmentedControlUnderlineRect(widget, t), controls.segmentedControlUnderlineRect(widget, owned(t)));
    const radius: c.Radius = .{ .top_left = -0.0, .top_right = @bitCast(@as(u32, 0x7f812345)), .bottom_right = 7, .bottom_left = 9 };
    for (std.enums.values(@TypeOf(widget.group_segment))) |segment| for ([_]bool{ false, true }) |detached| {
        widget.group_segment = segment;
        const expected: c.Radius = if (detached) radius else switch (segment) {
            .none => radius,
            .first => .{ .top_left = radius.top_left, .bottom_left = radius.bottom_left },
            .middle => .{},
            .last => .{ .top_right = radius.top_right, .bottom_right = radius.bottom_right },
        };
        try exact(expected, p.segment(widget, owned(t), radius, detached));
    };
}
test "compiled control geometry preserves complete draw commands capacity errors and copied arena ownership" {
    _ = core.initialModel();
    const a = try std.testing.allocator.create(c.Builder);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(c.Builder);
    defer std.testing.allocator.destroy(b);
    var ac: [128]c.CanvasCommand = undefined;
    var bc: [128]c.CanvasCommand = undefined;
    var widget: c.Widget = .{ .kind = .slider, .id = 0x20000000000001, .frame = .init(5.25, 6.75, 120.5, 29.25), .text = "Control" };
    for ([_]c.WidgetKind{ .checkbox, .radio, .switch_control, .slider, .progress, .segmented_control, .button }) |kind| for (0..16) |flags| for ([_]f32{ -1, 0, 0.125, 0.5, 1, 2 }) |value| for ([_]usize{ 0, 1, 2, 4, 8, 16, 128 }) |capacity| {
        widget.kind = kind;
        widget.value = value;
        widget.state = .{ .selected = flags & 1 != 0, .focused = flags & 2 != 0, .disabled = flags & 4 != 0, .hovered = flags & 8 != 0 };
        a.* = c.Builder.init(ac[0..capacity]);
        b.* = c.Builder.init(bc[0..capacity]);
        const expected = c.emitWidgetTree(a, widget, .{});
        const actual = c.emitWidgetTree(b, widget, owned(.{}));
        if (expected) |_| try actual else |err| try std.testing.expectError(err, actual);
        try exact(a.commands[0..a.len], b.commands[0..b.len]);
        core.rt.frameReset();
        try exact(a.commands[0..a.len], b.commands[0..b.len]);
    };
    const metric: c.WidgetScrollMetrics = .{ .present = true, .offset = 50, .viewport_extent = 100, .content_extent = 400 };
    for (0..5) |capacity| {
        a.* = c.Builder.init(ac[0..capacity]);
        b.* = c.Builder.init(bc[0..capacity]);
        const expected = scroll.emitScrollViewScrollbars(a, widget.frame, metric, metric, .{}, widget.id);
        const actual = scroll.emitScrollViewScrollbars(b, widget.frame, metric, metric, owned(.{}), widget.id);
        if (expected) |_| try actual else |err| try std.testing.expectError(err, actual);
        try exact(a.commands[0..a.len], b.commands[0..b.len]);
    }
}
