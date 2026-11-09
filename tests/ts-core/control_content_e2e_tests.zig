//! Complete native-reference content plans and drawing prefixes.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const c = sdk.canvas;
const p = c.control_content_policy;
const controls = p.reference_controls;
const style = p.reference_style;
const exact = @import("component_construction_e2e_tests.zig").exact;
fn owned(tokens: c.DesignTokens) c.DesignTokens {
    var t = tokens;
    t.control_geometry_policy = core.nativeWindowPolicy;
    return t;
}
test "compiled control content preserves text bounds alignment glyph sizing and copied ownership" {
    _ = core.initialModel();
    var widget: c.Widget = .{ .kind = .icon_button, .id = std.math.maxInt(u64), .frame = .init(-5.25, 3.75, 111.125, 27.625), .text = "Caf\xc3\xa9" };
    for (std.enums.values(c.Density)) |density| for (std.enums.values(c.WidgetSize)) |size| for ([_]f32{ -10, 0, 4.125, 99 }) |inset| {
        var t: c.DesignTokens = .{};
        t.density = density;
        widget.size = size;
        try exact(controls.textOrigin(widget.frame, 14.125, inset, t), controls.textOrigin(widget.frame, 14.125, inset, owned(t)));
        try exact(controls.boundedTextOrigin(widget.frame, 14.125, inset, t), controls.boundedTextOrigin(widget.frame, 14.125, inset, owned(t)));
        try exact(controls.labelFrameForControl(widget.frame, inset, t), controls.labelFrameForControl(widget.frame, inset, owned(t)));
        try exact(controls.iconGlyphSize(widget, t), controls.iconGlyphSize(widget, owned(t)));
        for (std.enums.values(c.TextAlign)) |alignment| {
            try exact(controls.alignedTextOrigin(widget.frame, widget.text, 14.125, inset, alignment, t), controls.alignedTextOrigin(widget.frame, widget.text, 14.125, inset, alignment, owned(t)));
            for (std.enums.values(c.TextWrap)) |wrap| for (std.enums.values(c.TextOverflow)) |overflow| try exact(controls.boundedTextLayout(widget.frame, 14.125, inset, alignment, wrap, overflow, t), controls.boundedTextLayout(widget.frame, 14.125, inset, alignment, wrap, overflow, owned(t)));
        }
        const copied = controls.iconLabelFrames(widget, owned(t), 16, 6, 70.125, inset, true);
        core.rt.frameReset();
        try exact(copied, controls.iconLabelFrames(widget, owned(t), 16, 6, 70.125, inset, true));
    };
}
test "compiled control content preserves icon slots narrow labels and f32 grouping" {
    _ = core.initialModel();
    var widget: c.Widget = .{ .kind = .button, .text = "Label" };
    for ([_]f32{ -20, 0, 1, 17.125, 123.625, 100000 }) |width| for ([_]f32{ -31.25, 0, 0.000001, 100000 }) |x| for ([_]f32{ 0, 1, 12.125, 500 }) |measured| for (std.enums.values(@TypeOf(widget.icon_placement))) |placement| for ([_]bool{ false, true }) |grouped| {
        widget.frame = .init(x, 3.125, width, 27.625);
        widget.icon_placement = placement;
        try exact(controls.iconLabelFrames(widget, .{}, 16.25, 6.125, measured, 8.25, grouped), controls.iconLabelFrames(widget, owned(.{}), 16.25, 6.125, measured, 8.25, grouped));
        widget.text = "";
        try exact(controls.iconLabelFrames(widget, .{}, 16.25, 6.125, measured, 8.25, grouped), controls.iconLabelFrames(widget, owned(.{}), 16.25, 6.125, measured, 8.25, grouped));
        widget.text = "Label";
    };
}
test "compiled control content preserves grid rounding focus offsets and hairline boundaries" {
    _ = core.initialModel();
    for ([_]f32{ -1, 0, 1, 1.25, 1.5, 2, std.math.inf(f32), std.math.nan(f32) }) |scale| for ([_]bool{ false, true }) |snap| for ([_]f32{ -10, 0, 0.5, 1, 1.25, 1.5, 2, 3, 99 }) |width| for ([_]f32{ -1, 0, 2.125 }) |offset| {
        var t: c.DesignTokens = .{};
        t.pixel_snap = .{ .geometry = snap, .text = snap, .scale = scale };
        t.stroke.focus_offset = offset;
        t.stroke.regular = width;
        const frame: sdk.geometry.RectF = .init(-5.5, 3.25, 111.125, 27.625);
        const radius: c.Radius = .{ .top_left = 0, .top_right = 1.125, .bottom_right = 5.25, .bottom_left = 9.75 };
        try exact(controls.pixelSnapGeometryRect(t, frame), controls.pixelSnapGeometryRect(owned(t), frame));
        const point: sdk.geometry.PointF = .init(-0.5, 3.25);
        try exact(controls.pixelSnapGeometryPoint(t, point), controls.pixelSnapGeometryPoint(owned(t), point));
        try exact(controls.pixelSnapTextPoint(t, point), controls.pixelSnapTextPoint(owned(t), point));
        try exact(style.focusRingRect(frame, t), style.focusRingRect(frame, owned(t)));
        try exact(style.focusRingRadius(radius, t), style.focusRingRadius(radius, owned(t)));
        const stroke: c.StrokeRect = .{ .id = 0x20000000000001, .rect = frame, .radius = radius, .stroke = .{ .fill = .{ .color = .rgba(0.125, 0.25, 0.5, 0.75) }, .width = width } };
        try exact(style.snapHairlineStrokeRect(t, stroke), style.snapHairlineStrokeRect(owned(t), stroke));
        try exact(controls.compositionLineRect(frame, t), controls.compositionLineRect(frame, owned(t)));
    };
}
test "compiled control content preserves exceptional stored frame point and radius words" {
    _ = core.initialModel();
    const words = [_]u32{ 0, 0x80000000, 1, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc12345, 0x7f812345, 0xff812345 };
    for (words) |word| for ([_]bool{ false, true }) |snap| {
        var t: c.DesignTokens = .{};
        t.pixel_snap.geometry = snap;
        t.pixel_snap.text = snap;
        const value: f32 = @bitCast(word);
        const point: sdk.geometry.PointF = .init(value, value);
        try exact(controls.pixelSnapGeometryPoint(t, point), controls.pixelSnapGeometryPoint(owned(t), point));
        try exact(controls.pixelSnapTextPoint(t, point), controls.pixelSnapTextPoint(owned(t), point));
        const radius: c.Radius = .all(value);
        try exact(style.focusRingRadius(radius, t), style.focusRingRadius(radius, owned(t)));
        const stroke: c.StrokeRect = .{ .rect = .init(5.25, 3.75, 111.125, 27.625), .radius = radius, .stroke = .{ .fill = .{ .color = .rgba(0, 0, 0, 1) }, .width = value } };
        exact(style.snapHairlineStrokeRect(t, stroke), style.snapHairlineStrokeRect(owned(t), stroke)) catch |err| {
            std.debug.print("content hairline word {x} snap {}\n", .{ word, snap });
            return err;
        };
        var frame: sdk.geometry.RectF = .init(5.25, 3.75, 111.125, 27.625);
        inline for (.{ "x", "y", "width", "height" }) |name| {
            const saved = frame;
            @field(frame, name) = value;
            exact(controls.pixelSnapGeometryRect(t, frame), controls.pixelSnapGeometryRect(owned(t), frame)) catch |err| {
                std.debug.print("content frame {s} word {x} snap {}\n", .{ name, word, snap });
                return err;
            };
            try exact(controls.boundedTextOrigin(frame, 14, 8, t), controls.boundedTextOrigin(frame, 14, 8, owned(t)));
            frame = saved;
        }
    };
}
test "compiled control content preserves complete drawing prefixes editing ranges and arena lifetimes" {
    _ = core.initialModel();
    const a = try std.testing.allocator.create(c.Builder);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(c.Builder);
    defer std.testing.allocator.destroy(b);
    var ac: [128]c.CanvasCommand = undefined;
    var bc: [128]c.CanvasCommand = undefined;
    var widget: c.Widget = .{ .id = 0x20000000000001, .kind = .button, .frame = .init(5.25, 6.75, 180.5, 29.25), .text = "Caf\xc3\xa9 label", .icon = "chevron-right" };
    for ([_]c.WidgetKind{ .button, .icon_button, .segmented_control, .checkbox, .radio, .switch_control, .select, .text_field, .search_field, .textarea, .tooltip, .menu_item, .list_item, .data_cell }) |kind| for (0..16) |flags| for ([_]usize{ 0, 1, 2, 4, 8, 16, 128 }) |capacity| {
        var t: c.DesignTokens = .{};
        t.controls.tabs_indicator = .underline;
        widget.kind = kind;
        widget.state = .{ .selected = flags & 1 != 0, .focused = flags & 2 != 0, .disabled = flags & 4 != 0, .hovered = flags & 8 != 0 };
        widget.text_selection = .{ .anchor = 0, .focus = 5 };
        widget.text_composition = .{ .start = 0, .end = 5 };
        a.* = c.Builder.init(ac[0..capacity]);
        b.* = c.Builder.init(bc[0..capacity]);
        const expected = c.emitWidgetTree(a, widget, t);
        const actual = c.emitWidgetTree(b, widget, owned(t));
        if (expected) |_| try actual else |err| try std.testing.expectError(err, actual);
        try exact(a.commands[0..a.len], b.commands[0..b.len]);
        core.rt.frameReset();
        try exact(a.commands[0..a.len], b.commands[0..b.len]);
    };
}

test "compiled control content preserves input wrapping clipping scroll origins clear hit targets and shaping" {
    _ = core.initialModel();
    const input = p.reference_input;
    var widget: c.Widget = .{ .kind = .search_field, .frame = .init(-5.25, 3.75, 111.125, 27.625), .text = "Caf\xc3\xa9 long retained input value\nsecond line", .value = 17, .value_x = 11, .text_selection = .{ .anchor = 0, .focus = 5 }, .text_composition = .{ .start = 0, .end = 5 } };
    for ([_]c.WidgetKind{ .input, .text_field, .search_field, .combobox, .textarea }) |kind| for ([_]f32{ 0, 1, 27.625, 99 }) |height| for (0..8) |flags| for ([_]f32{ 0, 8.125, 99 }) |inset| {
        widget.kind = kind;
        widget.frame.height = height;
        widget.runtime_flags.code_editor = flags & 1 != 0;
        widget.text_no_wrap = flags & 2 != 0;
        widget.state.disabled = flags & 4 != 0;
        const t: c.DesignTokens = .{};
        const reference = input.widgetTextInputLayoutOptions(widget, t, 14.125, inset);
        const compiled = input.widgetTextInputLayoutOptions(widget, owned(t), 14.125, inset);
        try exact(reference, compiled);
        try exact(input.widgetTextInputClipRect(widget, t, 14.125, inset, reference), input.widgetTextInputClipRect(widget, owned(t), 14.125, inset, compiled));
        try exact(input.widgetTextInputOrigin(widget, t, 14.125, inset, reference), input.widgetTextInputOrigin(widget, owned(t), 14.125, inset, compiled));
        try exact(input.textInputClearButtonRect(widget, t), input.textInputClearButtonRect(widget, owned(t)));
        try exact(input.textInputClearButtonHitRect(widget, t), input.textInputClearButtonHitRect(widget, owned(t)));
        try exact(input.textGeometryForWidget(widget, t), input.textGeometryForWidget(widget, owned(t)));
    };
}
