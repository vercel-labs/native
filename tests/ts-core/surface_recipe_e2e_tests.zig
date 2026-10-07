//! Complete recipes through the production compiled library and native reference.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const c = sdk.canvas;
const p = c.surface_recipe_policy;
const native = p.reference;
const exact = @import("component_construction_e2e_tests.zig").exact;
fn owned(tokens: c.DesignTokens) c.DesignTokens {
    var t = tokens;
    t.control_geometry_policy = core.nativeWindowPolicy;
    return t;
}
fn compare(widget: c.Widget, tokens: c.DesignTokens, capacity: usize) !void {
    const a = try std.testing.allocator.create(c.Builder);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(c.Builder);
    defer std.testing.allocator.destroy(b);
    var ac: [128]c.CanvasCommand = undefined;
    var bc: [128]c.CanvasCommand = undefined;
    a.* = c.Builder.init(ac[0..capacity]);
    b.* = c.Builder.init(bc[0..capacity]);
    const expected = c.emitWidgetTree(a, widget, tokens);
    const actual = c.emitWidgetTree(b, widget, owned(tokens));
    if (expected) |_| try actual else |err| try std.testing.expectError(err, actual);
    exact(a.commands[0..a.len], b.commands[0..b.len]) catch |err| {
        std.debug.print("surface kind {t} variant {t} capacity {d}\n", .{ widget.kind, widget.variant, capacity });
        return err;
    };
    core.rt.frameReset();
    try exact(a.commands[0..a.len], b.commands[0..b.len]);
}
test "compiled surface recipe preserves complete chrome order capacity prefixes and copied storage" {
    _ = core.initialModel();
    var widget: c.Widget = .{ .kind = .card, .id = std.math.maxInt(u64), .frame = .init(-5.25, 3.75, 180.5, 79.25), .text = "Caf\xc3\xa9\x00\xff retained surface", .layout = .{ .padding = .all(6.125) } };
    for ([_]c.WidgetKind{ .alert, .card, .dialog, .drawer, .sheet, .panel, .resizable, .bubble, .accordion, .tabs, .popover, .menu_surface, .dropdown_menu }) |kind| for (std.enums.values(c.WidgetVariant)) |variant| for (0..4) |flags| for ([_]usize{ 0, 1, 2, 3, 4, 5, 8, 16, 128 }) |capacity| {
        var t: c.DesignTokens = .{};
        t.controls.tabs_indicator = if (flags & 1 != 0) .underline else .pill;
        widget.kind = kind;
        widget.variant = variant;
        widget.state.focused = flags & 1 != 0;
        widget.state.selected = flags & 2 != 0;
        try compare(widget, t, capacity);
    };
}
test "compiled surface recipe preserves optional styles themes density and empty admission" {
    _ = core.initialModel();
    var widget: c.Widget = .{ .kind = .card, .id = 0x20000000000001, .frame = .init(4.25, 5.75, 117.25, 41.125), .text = "Measured", .layout = .{ .padding = .{ .top = 7, .right = 13, .bottom = 9, .left = 17 } } };
    for ([_]c.WidgetKind{ .alert, .card, .dialog, .sheet, .panel, .resizable, .accordion, .tabs, .popover, .menu_surface }) |kind| for (std.enums.values(c.Density)) |density| for (std.enums.values(c.WidgetSize)) |size| for (0..4) |flags| {
        var t: c.DesignTokens = .{};
        t.density = density;
        t.pixel_snap = .{ .geometry = flags & 1 != 0, .text = flags & 2 != 0, .scale = 1.5 };
        t.controls.tabs_indicator = .underline;
        widget.kind = kind;
        widget.size = size;
        widget.style.background = if (flags & 1 != 0) .rgba(0.2, 0.3, 0.4, 0.75) else null;
        widget.style.border = if (flags & 2 != 0) .rgba(0.8, 0.7, 0.6, 1) else null;
        widget.style.radius = -3.125;
        try compare(widget, t, 128);
        const saved = widget.frame;
        widget.frame.height = 0;
        try compare(widget, t, 128);
        widget.frame = saved;
    };
}
test "compiled surface recipe preserves bubble variants descendant ink and measured reaction docking" {
    _ = core.initialModel();
    var widget: c.Widget = .{ .kind = .bubble, .id = 0x20000000000001, .frame = .init(-7.125, 3.625, 124.5, 61.25), .text = "Caf\xc3\xa9 reactions" };
    for (std.enums.values(c.WidgetVariant)) |variant| for (std.enums.values(c.TextAlign)) |alignment| for (0..8) |flags| {
        var t: c.DesignTokens = .{};
        widget.variant = variant;
        widget.text_alignment = alignment;
        widget.style.background = if (flags & 1 != 0) .rgba(0.1, 0.2, 0.3, 0.4) else null;
        widget.style.accent_foreground = if (flags & 2 != 0) .rgba(0.7, 0.6, 0.5, 0.4) else null;
        t.controls.bubble.foreground = if (flags & 4 != 0) .rgba(0.2, 0.3, 0.4, 0.5) else null;
        try exact(native.bubbleWidgetRadius(widget, t), native.bubbleWidgetRadius(widget, owned(t)));
        var content = native.bubbleContentTokens(widget, owned(t));
        content.control_geometry_policy = null;
        try exact(native.bubbleContentTokens(widget, t), content);
        try exact(native.bubbleWidgetReactionsPillRect(widget, t), native.bubbleWidgetReactionsPillRect(widget, owned(t)));
        try compare(widget, t, 128);
        const copied = p.plan(.reactions, widget, owned(t), .{}, 0);
        const saved = copied.bytes;
        core.rt.frameReset();
        try std.testing.expectEqualSlices(u8, &saved, &copied.bytes);
    };
}
test "compiled surface recipe preserves exceptional numeric frames radii strokes and palette octets" {
    _ = core.initialModel();
    var widget: c.Widget = .{ .kind = .card, .frame = .init(-5.25, 3.75, 117.5, 71.25), .text = "" };
    for ([_]u32{ 0, 0x80000000, 1, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc12345, 0x7f812345, 0xff812345 }) |word_| for ([_]bool{ false, true }) |snap| {
        const value: f32 = @bitCast(word_);
        var t: c.DesignTokens = .{};
        t.pixel_snap.geometry = snap;
        t.pixel_snap.scale = 1.5;
        widget.style.background = .{ .r = value, .g = value, .b = value, .a = value };
        widget.style.radius = value;
        widget.style.stroke_width = value;
        try compare(widget, t, 128);
        widget.style.radius = null;
        widget.style.stroke_width = null;
        inline for (.{ "x", "y", "width", "height" }) |name| {
            const saved = widget.frame;
            @field(widget.frame, name) = value;
            try compare(widget, t, 128);
            widget.frame = saved;
        }
    };
}

fn measured(context: ?*anyopaque, _: c.FontId, _: f32, _: []const u8) f32 {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    return 37.125;
}

test "compiled surface recipe preserves bubble radius and reaction scalar boundaries" {
    _ = core.initialModel();
    var widget: c.Widget = .{ .kind = .bubble, .id = 0x20000000000001, .frame = .init(-5.25, 3.75, 117.5, 71.25), .text = "" };
    for ([_]u32{ 0, 0x80000000, 1, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc12345, 0x7f812345, 0xff812345 }) |word_| {
        const value: f32 = @bitCast(word_);
        var t: c.DesignTokens = .{};
        widget.style.radius = value;
        try exact(native.bubbleWidgetRadius(widget, t), native.bubbleWidgetRadius(widget, owned(t)));
        widget.style.radius = null;
        t.radius.lg = value;
        try exact(native.bubbleWidgetRadius(widget, t), native.bubbleWidgetRadius(widget, owned(t)));
    }
    widget.text = "Reaction";
    for ([_]f32{ -8.25, -0.0, 0, 1.125, 100000 }) |size| for ([_]f32{ -12, 0, 5.25, 100000 }) |width| for (std.enums.values(c.TextAlign)) |alignment| {
        var t: c.DesignTokens = .{};
        t.typography.label_size = size;
        widget.frame.width = width;
        widget.text_alignment = alignment;
        try exact(native.bubbleWidgetReactionsPillRect(widget, t), native.bubbleWidgetReactionsPillRect(widget, owned(t)));
    };
}
test "compiled surface recipe preserves native measurement admission and failing draw prefixes" {
    _ = core.initialModel();
    var calls: usize = 0;
    const provider: c.TextMeasureProvider = .{ .context = &calls, .measure_fn = measured };
    const t: c.DesignTokens = .{ .text_measure = &provider };
    var widget: c.Widget = .{ .kind = .bubble, .id = 0xffffffffffffffff, .frame = .init(-5.25, 3.75, 110.5, 37.25), .text = "\xff\x00 measured" };
    const a = try std.testing.allocator.create(c.Builder);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(c.Builder);
    defer std.testing.allocator.destroy(b);
    var ac: [4]c.CanvasCommand = undefined;
    var bc: [4]c.CanvasCommand = undefined;
    for (0..4) |pose| for (0..5) |capacity| {
        widget.kind = if (pose == 1) .panel else .bubble;
        widget.text = if (pose == 2) "" else "\xff\x00 measured";
        widget.frame.height = if (pose == 3) 0 else 37.25;
        a.* = c.Builder.init(ac[0..capacity]);
        b.* = c.Builder.init(bc[0..capacity]);
        calls = 0;
        const expected = native.emitBubbleWidgetReactions(a, widget, t);
        const reference_calls = calls;
        calls = 0;
        const actual = native.emitBubbleWidgetReactions(b, widget, owned(t));
        if (expected) |_| try actual else |err| try std.testing.expectError(err, actual);
        try std.testing.expectEqual(reference_calls, calls);
        try std.testing.expectEqual(@as(usize, if (pose == 0) 1 else 0), calls);
        core.rt.frameReset();
        try exact(a.commands[0..a.len], b.commands[0..b.len]);
    };
}
