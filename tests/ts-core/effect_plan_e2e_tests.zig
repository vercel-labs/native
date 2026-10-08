//! Complete container, backdrop, scrim and child clip effects against native.
const std = @import("std");
const sdk = @import("native_sdk");
const c = sdk.canvas;
const core = @import("ts_persist_core");
const exact = @import("component_construction_e2e_tests.zig").exact;
const Rect = sdk.geometry.RectF;
fn compiledTokens(tokens: c.DesignTokens) c.DesignTokens {
    var compiled = tokens;
    compiled.control_command_policy = core.nativeWindowPolicy;
    return compiled;
}
fn compareTree(root: c.Widget, tokens: c.DesignTokens, capacity: usize, state: c.WidgetRenderState) !void {
    const compiled = compiledTokens(tokens);
    var nodes: [24]c.WidgetLayoutNode = undefined;
    const tree = try c.layoutWidgetTree(root, .init(-4.5, -2.25, 360.5, 300.75), &nodes);
    var as: [256]c.CanvasCommand = undefined;
    var bs: [256]c.CanvasCommand = undefined;
    for ([_]bool{ false, true }) |retained| {
        var a = c.Builder.init(as[0..capacity]);
        var b = c.Builder.init(bs[0..capacity]);
        const ae: ?anyerror = if (retained) blk: {
            tree.emitDisplayListWithState(&a, tokens, state) catch |err| break :blk err;
            break :blk null;
        } else blk: {
            c.emitWidgetTree(&a, root, tokens) catch |err| break :blk err;
            break :blk null;
        };
        const be: ?anyerror = if (retained) blk: {
            tree.emitDisplayListWithState(&b, compiled, state) catch |err| break :blk err;
            break :blk null;
        } else blk: {
            c.emitWidgetTree(&b, root, compiled) catch |err| break :blk err;
            break :blk null;
        };
        try std.testing.expectEqual(ae, be);
        try exact(a.displayList().commands, b.displayList().commands);
        core.rt.frameReset();
        try exact(a.displayList().commands, b.displayList().commands);
    }
    try exact(tree.renderStateDirtyBoundsWithTokens(.{}, state, tokens), tree.renderStateDirtyBoundsWithTokens(.{}, state, compiled));
    core.rt.frameReset();
}
fn surface(kind: c.WidgetKind, id: u64, clip: bool, scrim: bool, blur: f32, token: ?c.BlurTokenRef, radius: ?f32, owner: bool, children: []const c.Widget) c.Widget {
    var widget: c.Widget = .{ .id = id, .kind = kind, .frame = .init(10.25, 12.5, 180.75, 120.5), .children = children, .scrim = scrim, .backdrop_blur = blur, .backdrop_blur_token = token };
    widget.layout.clip_content = clip;
    widget.style.radius = radius;
    if (owner) widget.appearance_policy = core.nativeWindowPolicy;
    return widget;
}
const surface_kinds = [_]c.WidgetKind{ .stack, .row, .column, .accordion, .bubble, .resizable, .alert, .card, .dialog, .drawer, .sheet, .panel, .popover, .menu_surface, .dropdown_menu, .tooltip, .scroll_view, .list };
const blurs = [_]f32{ 0, 4.5, -2, std.math.nan(f32), std.math.inf(f32), @bitCast(@as(u32, 0x7f812345)) };
const radii = [_]?f32{ null, 0, 6.25, -3, std.math.nan(f32), @bitCast(@as(u32, 0x7f812345)) };
test "compiled widget metric effects preserve surface clips backdrops and modal scrims" {
    _ = core.initialModel();
    const child = [_]c.Widget{.{ .id = 0xfedcba9876543210, .kind = .text, .text = "Clipped child", .frame = .init(0, 0, 400, 30) }};
    for (surface_kinds) |kind| for ([_]bool{ false, true }) |clip| for ([_]bool{ false, true }) |scrim| for ([_]bool{ false, true }) |owner| for (radii) |radius| {
        const root = surface(kind, std.math.maxInt(u64), clip, scrim, 0, null, radius, owner, &child);
        try compareTree(root, c.DesignTokens.theme(.{ .pack = .geist }), 256, .{});
    };
    for (surface_kinds) |kind| for (blurs) |blur| for ([_]?c.BlurTokenRef{ null, .none, .sm, .md }) |token| for ([_]f32{ 0, 4, -1, std.math.nan(f32), @bitCast(@as(u32, 0x7f812345)) }) |scrim_blur| for ([_]f32{ 0, 0.1, -0.5 }) |scrim_alpha| {
        var tokens = c.DesignTokens.theme(.{ .pack = .geist });
        tokens.blur.scrim = scrim_blur;
        tokens.colors.scrim.a = scrim_alpha;
        tokens.blur.md = -7;
        const root = surface(kind, 0x1000_0000_0000_0000, true, true, blur, token, 4, false, &child);
        try compareTree(root, tokens, 256, .{});
    };
}
test "compiled widget metric effects preserve actionable container feedback ladders" {
    _ = core.initialModel();
    const ids = [_]u64{ 0, 7, std.math.maxInt(u64) };
    const backgrounds = [_]?c.Color{ null, .rgba(0.25, 0.5, 0.75, 0.5), .rgba(1, 0, 0, 0), .rgba(0, 1, 0, -1), .rgba(0, 0, 1, std.math.nan(f32)) };
    for ([_]c.WidgetKind{ .stack, .row, .column }) |kind| for (ids) |id| for (backgrounds) |background| for (0..64) |bits| for ([_]bool{ false, true }) |owner| {
        var widget: c.Widget = .{ .id = id, .kind = kind, .frame = .init(3.5, 4.25, 90.5, 30.75) };
        widget.style.background = background;
        widget.style.radius = if (bits & 1 != 0) 5.5 else null;
        widget.semantics.actions.press = bits & 2 != 0;
        widget.semantics.actions.toggle = bits & 4 != 0 and bits & 2 == 0;
        widget.semantics.actions.drag = bits & 8 != 0 and bits & 6 == 0;
        widget.state.disabled = bits & 16 != 0;
        widget.style.quiet_hover = bits & 32 != 0;
        if (owner) widget.appearance_policy = core.nativeWindowPolicy;
        for ([_]c.WidgetRenderState{ .{}, .{ .hovered_id = id }, .{ .pressed_id = id }, .{ .hovered_id = id, .pressed_id = id } }) |state| {
            var direct = widget;
            direct.state.hovered = state.hovered_id == id and id != 0;
            direct.state.pressed = state.pressed_id == id and id != 0;
            direct.state.selected = bits & 3 == 3;
            try compareTree(direct, c.DesignTokens.theme(.{ .pack = .geist }), 16, state);
        }
    };
}
test "compiled widget metric effects preserve invalidation bounds and capacity prefixes" {
    _ = core.initialModel();
    const child = [_]c.Widget{.{ .id = 99, .kind = .text, .text = "Body", .frame = .init(0, 0, 100, 20) }};
    for ([_]c.WidgetKind{ .dialog, .drawer, .sheet, .card, .popover, .stack }) |kind| for (0..24) |capacity| {
        var root = surface(kind, 41, true, true, 3.5, .sm, 6, false, &child);
        root.style.background = .rgba(0.5, 0.5, 0.5, 1);
        root.semantics.actions.press = true;
        try compareTree(root, c.DesignTokens.theme(.{ .pack = .geist }), capacity, .{ .hovered_id = 41 });
    };
    for ([_]c.WidgetKind{ .dialog, .sheet, .popover, .stack, .card }) |kind| for (blurs) |blur| for ([_]bool{ false, true }) |scrim| {
        const tokens = c.DesignTokens.theme(.{ .pack = .geist });
        var nodes_a: [8]c.WidgetLayoutNode = undefined;
        var nodes_b: [8]c.WidgetLayoutNode = undefined;
        const before = try c.layoutWidgetTree(surface(kind, 41, true, scrim, 0, null, null, false, &child), .init(0, 0, 320, 240), &nodes_a);
        var next = surface(kind, 41, true, !scrim, blur, .md, 2, false, &child);
        next.frame.x += 5.25;
        const after = try c.layoutWidgetTree(next, .init(0, 0, 320, 240), &nodes_b);
        var ao: [64]c.WidgetInvalidation = undefined;
        var bo: [64]c.WidgetInvalidation = undefined;
        const expected = try c.WidgetLayoutTree.diffWithTokens(before, after, tokens, &ao);
        const actual = try c.WidgetLayoutTree.diffWithTokens(before, after, compiledTokens(tokens), &bo);
        try exact(expected, actual);
        core.rt.frameReset();
    };
}
