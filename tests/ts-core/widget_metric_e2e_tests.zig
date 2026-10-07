//! Shared registers and leaf dimensions through the production compiled ABI.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const c = sdk.canvas;
const m = @import("native_sdk").canvas.widget_metric_policy;
const reference = m.reference;
const layout = c;
const exact = @import("component_construction_e2e_tests.zig").exact;
fn owned(tokens: c.DesignTokens) c.DesignTokens {
    var t = tokens;
    t.control_geometry_policy = core.nativeWindowPolicy;
    return t;
}
fn ownedIntrinsic(tokens: c.DesignTokens) c.DesignTokens {
    var t = owned(tokens);
    t.intrinsic_layout_policy = core.nativeWindowPolicy;
    return t;
}

test "compiled widget metric container coordination preserves complete sizes and measurement order" {
    _ = core.initialModel();
    var trace: Measures = .{};
    const provider: c.TextMeasureProvider = .{ .context = &trace, .measure_fn = measured };
    const spans_ = [_]c.TextSpan{ .{ .text = "First\xff\x00 line\n", .scale = 1.125 }, .{ .text = "monospace second", .monospace = true } };
    const descendants = [_]c.Widget{ .{ .kind = .text, .text = "paragraph", .spans = &spans_ }, .{ .kind = .button, .text = "nested button" } };
    const children = [_]c.Widget{
        .{ .kind = .column, .children = &descendants, .layout = .{ .gap = 2.25, .padding = .{ .left = 1.125, .right = 2.25, .top = 3.5, .bottom = 4.75 } } },
        .{ .kind = .separator },
        .{ .kind = .text, .text = "last\xff\x00 label", .frame = .init(0, 0, 12.25, 0), .layout = .{ .min_size = .init(7.25, 11.5), .max_size = .init(40.25, 55.125) } },
        .{ .kind = .popover, .text = "out of flow", .children = &descendants },
    };
    var widget: c.Widget = .{ .kind = .column, .text = "Title\xff\x00", .children = &children, .layout = .{ .gap = 3.125, .padding = .{ .left = 3.25, .right = 7.5, .top = 5.125, .bottom = 9.25 }, .min_size = .init(15.25, 17.5) } };
    for (std.enums.values(c.WidgetKind)) |kind| for ([_]c.WidgetSize{ .default, .sm, .lg }) |size| for (std.enums.values(c.Density)) |density| for ([_]u8{ 0, 1, 2, 4, 7 }) |flags| {
        var t: c.DesignTokens = .{ .text_measure = &provider, .density = density };
        t.controls.tabs_indicator = if (flags & 1 != 0) .underline else .pill;
        t.controls.button_group_style = .detached;
        t.metrics.button_group_gap = 5.125;
        t.metrics.tabs_gap = 7.25;
        widget.kind = kind;
        widget.size = size;
        widget.text = if (flags & 2 != 0) "" else "Title\xff\x00";
        widget.state.selected = flags & 1 != 0;
        widget.scroll_axes = if (flags & 1 != 0) .horizontal else .vertical;
        widget.layout.padding_is_kind_default = flags & 2 != 0;
        widget.layout.virtualized = flags & 4 != 0;
        widget.layout.columns = if (flags & 2 != 0) std.math.maxInt(usize) else 2;
        c.bumpTextMeasureGeneration();
        trace.count = 0;
        const expected = c.intrinsicWidgetSize(widget, t);
        const count = trace.count;
        const observations = trace.observations;
        c.bumpTextMeasureGeneration();
        trace.count = 0;
        const actual = c.intrinsicWidgetSize(widget, ownedIntrinsic(t));
        exact(expected, actual) catch |err| {
            std.debug.print("container kind {t} size {t} density {t} flags {d}\n", .{ kind, size, density, flags });
            return err;
        };
        try std.testing.expectEqual(count, trace.count);
        try exact(observations[0..count], trace.observations[0..trace.count]);
        core.rt.frameReset();
    };
}

test "compiled widget metric container continuation packets survive nested calls and arena resets" {
    _ = core.initialModel();
    const child: c.Widget = .{ .kind = .button, .text = "owned child" };
    const widget: c.Widget = .{ .kind = .scroll_view, .scroll_axes = .horizontal, .children = &.{child} };
    const tokens = ownedIntrinsic(.{});
    const plan = try c.intrinsic_measure_policy.Plan.init(std.testing.allocator, widget, tokens, 0, 32, false);
    defer plan.deinit();
    plan.setChild(0, child, true);
    const first = plan.run();
    const first_bytes = first.bytes;
    try std.testing.expectEqual(c.intrinsic_measure_policy.Action.child, first.action());
    const size = c.intrinsicWidgetSize(child, tokens);
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, &first_bytes, &first.bytes);
    plan.reply(first, size);
    const second = plan.run();
    try std.testing.expectEqual(c.intrinsic_measure_policy.Action.wrapped, second.action());
    const second_bytes = second.bytes;
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, &second_bytes, &second.bytes);
    plan.reply(second, .init(0, size.height));
    const final = plan.run();
    try std.testing.expectEqual(c.intrinsic_measure_policy.Action.done, final.action());
    const expected: @TypeOf(size) = .init(0, size.height);
    try exact(expected, final.size());
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, &first_bytes, &first.bytes);
    try std.testing.expectEqualSlices(u8, &second_bytes, &second.bytes);
}

test "compiled widget metric container continuations preserve the recursive depth boundary" {
    _ = core.initialModel();
    var nodes: [36]c.Widget = undefined;
    for (&nodes) |*node| node.* = .{ .kind = .column, .layout = .{ .padding = .{ .left = 1.125, .right = 2.25, .top = 3.5, .bottom = 4.75 }, .min_size = .init(5.5, 7.25) } };
    nodes[nodes.len - 1] = .{ .kind = .button, .text = "depth leaf" };
    for (0..nodes.len - 1) |i| nodes[i].children = nodes[i + 1 .. i + 2];
    for ([_]c.WidgetKind{ .column, .row, .grid, .stack, .scroll_view, .accordion, .card, .alert, .dialog, .list_item, .data_cell }) |kind| {
        for (nodes[0 .. nodes.len - 1]) |*node| {
            node.kind = kind;
            node.state.selected = true;
            node.scroll_axes = .vertical;
        }
        try exact(c.intrinsicWidgetSize(nodes[0], .{}), c.intrinsicWidgetSize(nodes[0], ownedIntrinsic(.{})));
        core.rt.frameReset();
    }
    for (nodes[0 .. nodes.len - 1]) |*node| node.kind = .column;
    nodes[32].kind = .scroll_view;
    nodes[32].scroll_axes = .horizontal;
    try exact(c.intrinsicWidgetSize(nodes[0], .{}), c.intrinsicWidgetSize(nodes[0], ownedIntrinsic(.{})));
    core.rt.frameReset();
}

test "compiled widget metric container recipes preserve exceptional f32 words" {
    _ = core.initialModel();
    const children = [_]c.Widget{ .{ .kind = .button, .text = "Exceptional" }, .{ .kind = .separator } };
    for ([_]c.WidgetKind{ .row, .column, .stack, .grid, .card, .dialog, .alert, .accordion, .list_item }) |kind| for ([_]u32{ 0, 0x80000000, 1, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc12345, 0x7f812345, 0xff812345 }) |word_| {
        const value: f32 = @bitCast(word_);
        const widget: c.Widget = .{ .kind = kind, .text = "Title", .children = &children, .state = .{ .selected = true }, .layout = .{ .gap = value, .padding = .{ .left = value, .right = 3.25, .top = 5.5, .bottom = 7.125 }, .min_size = .init(value, value) } };
        const expected = c.intrinsicWidgetSize(widget, .{});
        const actual = c.intrinsicWidgetSize(widget, ownedIntrinsic(.{}));
        exact(expected, actual) catch |err| {
            std.debug.print("container exceptional kind {t} word {x}\n", .{ kind, word_ });
            return err;
        };
        core.rt.frameReset();
    };
}
fn scalar(op: m.Operation, widget: c.Widget, t: c.DesignTokens, base: f32) f32 {
    return switch (op) {
        .button => reference.widgetButtonTextSize(widget, t),
        .body => reference.widgetBodyTextSize(widget, t),
        .label => reference.widgetLabelTextSize(widget, t),
        .badge => reference.widgetBadgeTextSize(widget, t),
        .typography => reference.widgetTypographySize(widget, base),
        .line => reference.widgetLineHeight(base),
        .wrap => reference.textWrapMaxWidth(t, base),
        .gutter => reference.widgetCodeLineNumberGutterWidth(widget, t),
        .height => reference.widgetControlHeight(widget, t),
        .button_icon => reference.widgetButtonIconExtent(widget, t),
        .button_gap => reference.widgetButtonIconGap(widget, t),
        .badge_icon => reference.widgetBadgeIconExtent(widget, t),
        .badge_gap => reference.widgetBadgeIconGap(widget, t),
        .row_icon => reference.widgetRowIconExtent(widget, t),
        .row_gap => reference.widgetRowIconGap(widget, t),
        .row_height => reference.widgetDefaultRowHeight(widget, t),
        .button_inset => reference.widgetButtonInset(widget, t),
        .inset => reference.widgetControlInset(widget, t, base),
        .alert_inset => reference.widgetAlertInset(widget, t),
        .tab_text => reference.widgetTabTriggerTextSize(widget, t),
        .tab_height => reference.widgetTabTriggerHeight(widget, t),
        .tab_inset => reference.widgetTabTriggerInset(widget, t),
        .tab_icon => reference.widgetTabTriggerIconExtent(widget, t),
        .tab_gap => reference.widgetTabTriggerIconGap(t),
        .tab_list => reference.underlineTabsListInset(t),
        .sized_density => reference.widgetSizedDensityValue(widget, t, base),
        .sized_token => reference.widgetSizedTokenValue(widget, t, base),
        .size_scale => reference.widgetSizeScale(widget),
        .density => reference.densityValue(t, base),
        .density_scale => reference.densityScale(t.density),
        else => unreachable,
    };
}
test "compiled widget metric preserves every shared register across kinds size density and tabs" {
    _ = core.initialModel();
    var widget: c.Widget = .{ .kind = .text, .text = "Caf\xc3\xa9\xff\x00", .icon = "check", .frame = .init(3.25, 4.5, 180.125, 42.75) };
    for (std.enums.values(c.WidgetKind)) |kind| for (std.enums.values(c.WidgetSize)) |size| for (std.enums.values(c.Density)) |density| for ([_]bool{ false, true }) |underline| {
        var t: c.DesignTokens = .{};
        t.density = density;
        t.controls.tabs_indicator = if (underline) .underline else .pill;
        t.pixel_snap = .{ .geometry = true, .scale = 1.5 };
        widget.kind = kind;
        widget.size = size;
        for (std.enums.values(m.Operation)) |op| {
            if (op == .aligned_frame or op == .content_frame or op == .intrinsic) continue;
            const expected = scalar(op, widget, t, 17.125);
            const actual = m.scalar(op, widget, owned(t), 17.125);
            exact(expected, actual) catch |err| {
                std.debug.print("metric {t} kind {t} size {t} density {t}\n", .{ op, kind, size, density });
                return err;
            };
        }
        core.rt.frameReset();
    };
}
test "compiled widget metric preserves complete intrinsic sizes empty and icon-only admission" {
    _ = core.initialModel();
    var widget: c.Widget = .{ .kind = .button, .text = "Caf\xc3\xa9\xff\x00", .frame = .init(2.5, 4.5, 180.25, 80.5), .layout = .{ .padding = .{ .left = 3.125, .right = 7.25, .top = 5.5, .bottom = 9.75 } } };
    for (std.enums.values(c.WidgetKind)) |kind| for (std.enums.values(c.WidgetSize)) |size| for (std.enums.values(c.Density)) |density| for (0..8) |flags| {
        var t: c.DesignTokens = .{};
        t.density = density;
        t.controls.tabs_indicator = if (flags & 1 != 0) .underline else .pill;
        t.pixel_snap = .{ .geometry = flags & 2 != 0, .scale = 1.5 };
        widget.kind = kind;
        widget.size = size;
        widget.text = if (flags & 4 != 0) "" else "Caf\xc3\xa9\xff\x00";
        widget.icon = if (flags & 2 != 0) "check" else "";
        const expected = layout.intrinsicWidgetSize(widget, t);
        const actual = layout.intrinsicWidgetSize(widget, owned(t));
        exact(expected, actual) catch |err| {
            std.debug.print("intrinsic kind {t} size {t} density {t} flags {d}\n", .{ kind, size, density, flags });
            return err;
        };
        const request = m.Request.init(.intrinsic, widget, owned(t), 0);
        const copied = request.run(widget, owned(t));
        const saved = copied.bytes;
        core.rt.frameReset();
        try std.testing.expectEqualSlices(u8, &saved, &copied.bytes);
        widget.layout.zero_intrinsic = true;
        try exact(layout.intrinsicWidgetSize(widget, t), layout.intrinsicWidgetSize(widget, owned(t)));
        widget.layout.zero_intrinsic = false;
    };
}
test "compiled widget metric preserves exceptional scalar words and raw passthrough" {
    _ = core.initialModel();
    var widget: c.Widget = .{ .kind = .button };
    for ([_]u32{ 0, 0x80000000, 1, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc12345, 0x7f812345, 0xff812345 }) |word_| for (std.enums.values(c.WidgetSize)) |size| {
        const value: f32 = @bitCast(word_);
        widget.size = size;
        var t: c.DesignTokens = .{};
        t.typography.body_size = value;
        t.typography.label_size = value;
        t.typography.button_size = value;
        t.metrics.tabs_trigger_height = value;
        for ([_]m.Operation{ .button, .body, .label, .badge, .typography, .line, .wrap, .tab_height, .sized_density, .sized_token, .density }) |op| {
            const expected = scalar(op, widget, t, value);
            const actual = m.scalar(op, widget, owned(t), value);
            exact(expected, actual) catch |err| {
                std.debug.print("metric exceptional op {t} size {t} word {x}\n", .{ op, size, word_ });
                return err;
            };
        }
        core.rt.frameReset();
    };
}

const Observation = struct { font: c.FontId, size: u32, length: usize, hash: u64 };
const Measures = struct { observations: [512]Observation = undefined, count: usize = 0 };
fn measured(context: ?*anyopaque, font: c.FontId, size: f32, bytes: []const u8) f32 {
    const trace: *Measures = @ptrCast(@alignCast(context.?));
    std.debug.assert(trace.count < trace.observations.len);
    trace.observations[trace.count] = .{ .font = font, .size = @bitCast(size), .length = bytes.len, .hash = std.hash.Wyhash.hash(0, bytes) };
    trace.count += 1;
    return @as(f32, @floatFromInt(bytes.len)) * size * 0.45;
}
test "compiled widget metric preserves native measurement arguments admission and order" {
    _ = core.initialModel();
    var trace: Measures = .{};
    const provider: c.TextMeasureProvider = .{ .context = &trace, .measure_fn = measured };
    var t: c.DesignTokens = .{ .text_measure = &provider };
    t.typography.font_id = 0x20000000000001;
    t.typography.button_font_id = std.math.maxInt(u64);
    var widget: c.Widget = .{ .kind = .button, .text = "Measured\xff\x00 bytes" };
    for (std.enums.values(c.WidgetKind)) |kind| for (0..8) |flags| {
        widget.kind = kind;
        widget.text = if (flags & 1 != 0) "" else "Measured\xff\x00 bytes";
        widget.icon = if (flags & 2 != 0) "check" else "";
        widget.layout.zero_intrinsic = flags & 4 != 0;
        c.bumpTextMeasureGeneration();
        trace.count = 0;
        const expected = c.intrinsicWidgetSize(widget, t);
        const count = trace.count;
        const observations = trace.observations;
        c.bumpTextMeasureGeneration();
        trace.count = 0;
        const actual = c.intrinsicWidgetSize(widget, owned(t));
        try exact(expected, actual);
        try std.testing.expectEqual(count, trace.count);
        try exact(observations[0..count], trace.observations[0..trace.count]);
        core.rt.frameReset();
    };
}
test "compiled widget metric preserves decorated paragraph gutters frames and ordered measurements" {
    _ = core.initialModel();
    var trace: Measures = .{};
    const provider: c.TextMeasureProvider = .{ .context = &trace, .measure_fn = measured };
    const styled = [_]c.TextSpan{ .{ .text = "Caf\xc3\xa9 ", .weight = .bold, .scale = 1.125 }, .{ .text = "\xff\x00 code", .monospace = true }, .{ .text = " wrapped table cell" } };
    var widget: c.Widget = .{ .kind = .data_cell, .text = "Caf\xc3\xa9 \xff\x00 code wrapped table cell", .spans = &styled, .frame = .init(3.125, 5.25, 140.5, 71.25), .layout = .{ .padding = .{ .left = 4.25, .right = 7.125, .top = 3.5, .bottom = 6.25 } } };
    const t: c.DesignTokens = .{ .text_measure = &provider };
    for ([_]c.WidgetKind{ .text, .data_cell, .tooltip, .status_bar }) |kind| for ([_]u8{ 0, 1, 3, 20, 127, 128, 129, 255 }) |digits| for (std.enums.values(c.TextAlign)) |alignment| for ([_]bool{ false, true }) |nowrap| {
        widget.kind = kind;
        widget.code_line_number_digits = digits;
        widget.text_alignment = alignment;
        widget.text_no_wrap = nowrap;
        c.bumpTextMeasureGeneration();
        trace.count = 0;
        const expected = reference.widgetTextSpanContentFrame(widget, t);
        const count = trace.count;
        const observations = trace.observations;
        c.bumpTextMeasureGeneration();
        trace.count = 0;
        const actual = reference.widgetTextSpanContentFrame(widget, owned(t));
        try exact(expected, actual);
        try std.testing.expectEqual(count, trace.count);
        try exact(observations[0..count], trace.observations[0..trace.count]);
        c.bumpTextMeasureGeneration();
        trace.count = 0;
        const size = c.intrinsicWidgetSize(widget, t);
        const intrinsic_count = trace.count;
        const intrinsic_observations = trace.observations;
        c.bumpTextMeasureGeneration();
        trace.count = 0;
        try exact(size, c.intrinsicWidgetSize(widget, owned(t)));
        try std.testing.expectEqual(intrinsic_count, trace.count);
        try exact(intrinsic_observations[0..intrinsic_count], trace.observations[0..trace.count]);
        core.rt.frameReset();
    };
}

test "compiled widget metric preserves custom token registers snap scales and child-bearing fallbacks" {
    _ = core.initialModel();
    const children = [_]c.Widget{ .{ .kind = .text, .text = "flow text" }, .{ .kind = .button, .text = "flow button", .icon = "check" } };
    var widget: c.Widget = .{ .kind = .button, .text = "Label\xff\x00", .icon = "check", .children = &children, .frame = .init(3.125, 5.25, 41.5, 22.75), .layout = .{ .gap = 3.125, .padding = .{ .left = 4.25, .right = 7.125, .top = 3.5, .bottom = 6.25 }, .min_size = .init(11.125, 14.25) } };
    for ([_]c.ThemePack{ .house, .geist }) |pack| for ([_]bool{ false, true }) |custom| for ([_]f32{ 0, -1, 1, 1.25, 1.5, 2, 3, std.math.inf(f32), std.math.nan(f32) }) |scale| {
        var t = c.DesignTokens.theme(.{ .pack = pack });
        t.pixel_snap = .{ .geometry = true, .scale = scale };
        if (custom) {
            t.typography = .{ .body_size = 17.25, .label_size = 12.125, .button_size = 15.5, .heading_size = 32.25, .display_size = 51.125, .title_size = 25.75 };
            inline for (@typeInfo(@TypeOf(t.metrics)).@"struct".fields, 0..) |field, i| if (field.type == f32) {
                @field(t.metrics, field.name) = @as(f32, @floatFromInt(i)) * 0.75 - 3.125;
            };
            t.spacing = .{ .xs = 1.25, .sm = 5.125, .md = 9.75, .lg = 17.125 };
        }
        for (std.enums.values(c.WidgetSize)) |size| for (std.enums.values(c.Density)) |density| for (std.enums.values(c.WidgetKind)) |kind| {
            widget.size = size;
            widget.kind = kind;
            t.density = density;
            for (std.enums.values(m.Operation)) |op| {
                if (op == .aligned_frame or op == .content_frame or op == .intrinsic) continue;
                exact(scalar(op, widget, t, 17.125), m.scalar(op, widget, owned(t), 17.125)) catch |err| {
                    std.debug.print("custom metric {t} kind {t} size {t} density {t} pack {t} custom {} scale {d}\n", .{ op, kind, size, density, pack, custom, scale });
                    return err;
                };
            }
            for ([_]bool{ false, true }) |virtualized| {
                widget.layout.virtualized = virtualized;
                c.bumpTextMeasureGeneration();
                const expected = c.intrinsicWidgetSize(widget, t);
                c.bumpTextMeasureGeneration();
                exact(expected, c.intrinsicWidgetSize(widget, owned(t))) catch |err| {
                    std.debug.print("custom intrinsic kind {t} size {t} density {t} pack {t} custom {} scale {d} virtual {}\n", .{ kind, size, density, pack, custom, scale, virtualized });
                    return err;
                };
            }
            core.rt.frameReset();
        };
    };
}

test "compiled widget metric preserves copied and calculated exceptional frame words" {
    _ = core.initialModel();
    for ([_]u32{ 0, 0x80000000, 1, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc12345, 0x7f812345, 0xff812345 }) |word_| for (0..8) |field| {
        var words = [4]u32{ @bitCast(@as(f32, 3.125)), @bitCast(@as(f32, 5.25)), @bitCast(@as(f32, 31.125)), @bitCast(@as(f32, 41.5)) };
        var padding = [4]u32{ 0, 0, 0, 0 };
        if (field < 4) words[field] = word_ else padding[field - 4] = word_;
        const widget: c.Widget = .{ .kind = .text, .frame = .init(@bitCast(words[0]), @bitCast(words[1]), @bitCast(words[2]), @bitCast(words[3])), .layout = .{ .padding = .{ .left = @bitCast(padding[0]), .right = @bitCast(padding[1]), .top = @bitCast(padding[2]), .bottom = @bitCast(padding[3]) } } };
        const t: c.DesignTokens = .{};
        for ([_]m.Operation{ .aligned_frame, .content_frame }) |op| {
            // Insetting requires normalized sizes; direct alignment also
            // accepts negative heights and leaves those rectangles unchanged.
            if (op == .content_frame and field >= 2 and field < 4 and word_ == 0xff800000) continue;
            const expected = if (op == .aligned_frame) reference.widgetTextSpanAlignedContentFrame(widget, widget.frame, t) else reference.widgetTextSpanContentFrame(widget, t);
            const actual = if (op == .aligned_frame) reference.widgetTextSpanAlignedContentFrame(widget, widget.frame, owned(t)) else reference.widgetTextSpanContentFrame(widget, owned(t));
            exact(expected, actual) catch |err| {
                std.debug.print("frame op {t} field {d} word {x}\n", .{ op, field, word_ });
                return err;
            };
            core.rt.frameReset();
        }
    };
}

test "compiled widget metric ABI preserves complete copied results caller tails and arena ownership" {
    _ = core.initialModel();
    const widget: c.Widget = .{ .kind = .button, .text = "Measured label" };
    const t: c.DesignTokens = .{};
    for ([_]m.Operation{ .body, .intrinsic, .aligned_frame, .content_frame }) |op| {
        const request = m.Request.init(op, widget, owned(t), 0);
        var expected: [32]u8 = @splat(0xa5);
        try std.testing.expectEqual(32, core.nativeWindowPolicy(&request.bytes, &expected));
        // The copied window-policy ABI requires a full result buffer.
        // Its generated wrapper traps for undersized output storage.
        for (32..41) |capacity| {
            var output: [40]u8 = @splat(0xa5);
            const length = core.nativeWindowPolicy(&request.bytes, output[0..capacity]);
            try std.testing.expectEqual(expected.len, length);
            try std.testing.expectEqualSlices(u8, &expected, output[0..expected.len]);
            try std.testing.expect(std.mem.allEqual(u8, output[expected.len..], 0xa5));
            core.rt.frameReset();
            try std.testing.expectEqualSlices(u8, &expected, output[0..expected.len]);
        }
    }
}

test "compiled widget metric preserves exceptional padded paragraph minimum words" {
    _ = core.initialModel();
    const styled = [_]c.TextSpan{.{ .text = "Scaled bytes\xff\x00", .scale = 1.125 }};
    var widget: c.Widget = .{ .kind = .data_cell, .text = "Scaled bytes\xff\x00", .spans = &styled, .layout = .{ .padding = .{ .left = 3.125, .right = 4.25, .top = 5.125, .bottom = 6.25 } } };
    for ([_]u32{ 0, 0x80000000, 1, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc12345, 0x7f812345, 0xff812345 }) |word_| for ([_]bool{ false, true }) |vertical| {
        const value: f32 = @bitCast(word_);
        widget.layout.min_size = if (vertical) .init(0, value) else .init(value, 0);
        const t: c.DesignTokens = .{};
        c.bumpTextMeasureGeneration();
        const expected = c.intrinsicWidgetSize(widget, t);
        c.bumpTextMeasureGeneration();
        exact(expected, c.intrinsicWidgetSize(widget, owned(t))) catch |err| {
            std.debug.print("paragraph minimum vertical {} word {x}\n", .{ vertical, word_ });
            return err;
        };
        core.rt.frameReset();
    };
}
