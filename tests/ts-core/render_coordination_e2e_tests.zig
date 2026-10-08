//! Complete display lists through the production scriptc policy ABI.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const c = sdk.canvas;
const p = c.render_coordination_policy;
const exact = @import("component_construction_e2e_tests.zig").exact;
fn owned(t: c.DesignTokens) c.DesignTokens {
    var result = t;
    result.render_coordination_policy = core.nativeWindowPolicy;
    return result;
}
fn compare(widget: c.Widget, t: c.DesignTokens, state: c.WidgetRenderState, retained: bool, capacity: usize) !void {
    var native_commands: [2048]c.CanvasCommand = undefined;
    var compiled_commands: [2048]c.CanvasCommand = undefined;
    var native = c.Builder.init(native_commands[0..capacity]);
    var compiled = c.Builder.init(compiled_commands[0..capacity]);
    var nodes: [128]c.WidgetLayoutNode = undefined;
    var len: usize = 0;
    append(widget, null, 0, &nodes, &len);
    const tree: c.WidgetLayoutTree = .{ .nodes = nodes[0..len], .root_bounds = .init(0, 0, 360, 240) };
    const native_error: ?anyerror = if (retained) blk: {
        tree.emitDisplayListWithState(&native, t, state) catch |err| break :blk err;
        break :blk null;
    } else blk: {
        c.emitWidgetTree(&native, widget, t) catch |err| break :blk err;
        break :blk null;
    };
    const compiled_error: ?anyerror = if (retained) blk: {
        tree.emitDisplayListWithState(&compiled, owned(t), state) catch |err| break :blk err;
        break :blk null;
    } else blk: {
        c.emitWidgetTree(&compiled, widget, owned(t)) catch |err| break :blk err;
        break :blk null;
    };
    try std.testing.expectEqual(native_error, compiled_error);
    // Compare every initialized command and all retained slices, including
    // complete prefixes when a capability exhausts the builder's capacity.
    try exact(native.displayList().commands, compiled.displayList().commands);
    core.rt.frameReset();
    try exact(native.displayList().commands, compiled.displayList().commands);
}
fn append(widget: c.Widget, parent: ?usize, depth: usize, nodes: []c.WidgetLayoutNode, len: *usize) void {
    const index = len.*;
    nodes[index] = .{ .widget = widget, .frame = widget.frame, .depth = depth, .parent_index = parent };
    len.* += 1;
    for (widget.children) |child| append(child, index, depth + 1, nodes, len);
}
test "compiled widget metric render recipes preserve every kind complete tree and retained commands" {
    _ = core.initialModel();
    const children = [_]c.Widget{
        .{ .id = 2, .kind = .button, .text = "Child\xff\x00", .frame = .init(13.25, 41.5, 70.125, 33.75), .state = .{ .focused = true }, .layer = 2 },
        .{ .id = 3, .kind = .text, .text = "Second", .frame = .init(97.25, 45.5, 110.125, 25.75), .layer = -2 },
    };
    const spans = [_]c.TextSpan{ .{ .text = "Rich\xff\x00 ", .scale = 1.125 }, .{ .text = "bytes", .monospace = true } };
    for (std.enums.values(c.WidgetKind)) |kind| for (0..32) |flags| for ([_]c.ThemePack{ .house, .geist }) |pack| {
        var widget: c.Widget = .{ .id = 1, .kind = kind, .text = "Root\xff\x00", .icon = "check", .children = &children, .frame = .init(3.125, 5.25, 250.5, 130.75), .value = 0.37, .backdrop_blur = 1.25, .layout = .{ .clip_content = flags & 1 != 0, .virtualized = flags & 2 != 0, .gap = if (flags & 4 != 0) 3.25 else 0 }, .state = .{ .selected = flags & 4 != 0, .hovered = true, .pressed = flags & 8 != 0 }, .runtime_flags = .{ .native_scroll = flags & 8 != 0, .code_editor = flags & 16 != 0 } };
        if ((kind == .text or kind == .data_cell) and flags & 16 != 0) widget.spans = &spans;
        var t = c.DesignTokens.theme(.{ .pack = pack });
        t.controls.button_group_style = if (flags & 16 != 0) .detached else .segmented;
        for ([_]bool{ false, true }) |retained| compare(widget, t, .{}, retained, 2048) catch |err| {
            std.debug.print("paint kind {t} flags {d} pack {t} retained {}\n", .{ kind, flags, pack, retained });
            return err;
        };
    };
}
test "compiled widget metric render recipes preserve nested cascades segment stamps disclosure and focus chrome" {
    _ = core.initialModel();
    const buttons = [_]c.Widget{
        .{ .id = 4, .kind = .button, .text = "First", .frame = .init(22, 90, 70, 32), .layer = 8 },
        .{ .id = 5, .kind = .button, .text = "Hidden", .frame = .init(92, 90, 70, 32), .semantics = .{ .hidden = true } },
        .{ .id = 6, .kind = .button, .text = "Last", .frame = .init(92, 90, 70, 32), .state = .{ .focused = true }, .layer = -8 },
    };
    const groups = [_]c.Widget{.{ .id = 3, .kind = .button_group, .frame = .init(15, 85, 200, 45), .children = &buttons, .layout = .{ .clip_content = true } }};
    for ([_]bool{ false, true }) |selected| for ([_]f32{ 50, 150 }) |height| for ([_]bool{ false, true }) |revealing| {
        const disclosures = [_]c.Widget{.{ .id = 2, .kind = .accordion, .text = "Details", .frame = .init(10, 35, 250, height), .children = &groups, .state = .{ .selected = selected }, .layout = .{ .clip_content = true } }};
        const widget: c.Widget = .{ .id = 1, .kind = .bubble, .frame = .init(0, 0, 300, 230), .children = &disclosures, .state = .{ .selected = true }, .layout = .{ .clip_content = true }, .text = "Cascade" };
        const state: c.WidgetRenderState = .{ .focus_visible_id = 6, .focused_id = 6, .revealing_disclosure_ids = if (revealing) &.{2} else &.{} };
        for ([_]bool{ false, true }) |retained| try compare(widget, .{}, state, retained, 2048);
    };
}
test "compiled widget metric render recipes preserve numeric accordion disclosure and capacity prefixes" {
    _ = core.initialModel();
    const children = [_]c.Widget{.{ .id = 2, .kind = .text, .text = "Numeric disclosure child", .frame = .init(12, 48, 180, 28) }};
    for ([_]bool{ false, true }) |selected| for ([_]f32{ 0, 0.49999997, 0.5, 1, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) }) |value| {
        const widget: c.Widget = .{ .id = 1, .kind = .accordion, .text = "Details", .value = value, .state = .{ .selected = selected }, .frame = .init(0, 0, 250, 140), .children = &children, .layout = .{ .clip_content = true } };
        for ([_]bool{ false, true }) |retained| for ([_]usize{ 0, 1, 2, 3, 8, 32, 2048 }) |capacity| try compare(widget, .{}, .{}, retained, capacity);
    };
}
test "compiled widget metric render recipes preserve complete capacity failure prefixes" {
    _ = core.initialModel();
    const children = [_]c.Widget{.{ .id = 2, .kind = .button, .text = "Child", .frame = .init(10, 45, 100, 30) }};
    for ([_]c.WidgetKind{ .bubble, .dialog, .accordion, .button_group, .table, .scroll_view, .input_group, .spinner, .text }) |kind| for (0..20) |capacity| {
        const widget: c.Widget = .{ .id = 1, .kind = kind, .frame = .init(0, 0, 250, 140), .children = &children, .text = "Prefix", .backdrop_blur = 2, .layout = .{ .virtualized = true, .clip_content = true }, .state = .{ .selected = true }, .opacity = 0.5, .transform = .{ .tx = 2.25, .ty = 3.5 } };
        for ([_]bool{ false, true }) |retained| try compare(widget, .{}, .{}, retained, capacity);
    };
}
test "compiled widget metric direct render recipes preserve depth before hidden suppression" {
    _ = core.initialModel();
    var widgets: [36]c.Widget = undefined;
    for (&widgets, 0..) |*widget, i| widget.* = .{ .id = i + 1, .kind = .column, .frame = .init(0, 0, 100, 50) };
    for (0..widgets.len - 1) |i| widgets[i].children = widgets[i + 1 .. i + 2];
    for ([_]usize{ 30, 31, 32, 33 }) |hidden| {
        widgets[hidden].semantics.hidden = true;
        try compare(widgets[0], .{}, .{}, false, 2048);
        widgets[hidden].semantics.hidden = false;
    }
    try compare(widgets[0], .{}, .{}, false, 2048);
}
test "compiled widget metric direct sibling programs preserve exact layers source ties segments and owned buffers" {
    _ = core.initialModel();
    var children: [63]c.Widget = undefined;
    for (std.enums.values(c.WidgetKind), 0..) |kind, i| children[i] = .{ .kind = kind, .id = i + 1, .semantics = .{ .hidden = i % 3 == 0 }, .layer = if (i % 4 == 0) std.math.minInt(i32) else if (i % 4 == 1) std.math.maxInt(i32) else null };
    var t: c.DesignTokens = .{};
    t.layer = .{ .base = 7, .modal = -20, .overlay = 7, .floating = 30 };
    const plan = try p.ChildPlan.init(std.testing.allocator, core.nativeWindowPolicy, &children, t, true);
    defer plan.deinit();
    const copy = try std.testing.allocator.dupe(u8, plan.result);
    defer std.testing.allocator.free(copy);
    var previous: ?c.WidgetPaintOrder = null;
    var visible: usize = 0;
    for (children) |child| if (!child.semantics.hidden) {
        visible += 1;
    };
    for (0..children.len) |i| {
        const index = p.reference.nextWidgetPaintChild(&children, t, previous).?;
        try std.testing.expectEqual(index, plan.index(i));
        var ordinal: usize = 0;
        if (!children[index].semantics.hidden) for (children[0..index]) |child| {
            if (!child.semantics.hidden) ordinal += 1;
        };
        const expected: @TypeOf(children[0].group_segment) = if (visible <= 1) .none else if (ordinal == 0) .first else if (ordinal == visible - 1) .last else .middle;
        try std.testing.expectEqual(expected, plan.segment(i));
        previous = .{ .layer = p.reference.widgetPaintLayer(children[index], t), .index = index };
        _ = p.Recipe.init(core.nativeWindowPolicy, .tree, children[index], t, i, 0, false);
        core.rt.frameReset();
        try std.testing.expectEqualSlices(u8, copy, plan.result);
    }
}
test "compiled widget metric recipe buffers preserve caller tails and survive nested calls and arena resets" {
    _ = core.initialModel();
    for ([_]u32{ 0, 0x80000000, 1, 0x7f800000, 0xff800000, 0x7fc12345, 0x7f812345 }) |gap| {
        const widget: c.Widget = .{ .kind = .button_group, .layout = .{ .gap = @bitCast(gap) } };
        const recipe = p.Recipe.init(core.nativeWindowPolicy, .tree, widget, .{}, 0, 0, false);
        _ = p.Recipe.init(core.nativeWindowPolicy, .retained, .{ .kind = .dialog }, .{}, 0, 0, false);
        core.rt.frameReset();
        const stamp = @as(f32, @bitCast(gap)) <= 0;
        try std.testing.expectEqual(@as(u32, if (stamp) 512 else 0), recipe.commands[1].arg);
    }
    var request: [32]u8 = @splat(0);
    request[0..4].* = .{ 43, 1, 1, 0 };
    std.mem.writeInt(u32, request[20..24], @intFromEnum(c.WidgetKind.bubble), .little);
    var result: [80]u8 = @splat(0xa5);
    try std.testing.expectEqual(64, core.nativeWindowPolicy(&request, &result));
    const copy = result;
    _ = p.Recipe.init(core.nativeWindowPolicy, .tree, .{ .kind = .text }, .{}, 0, 0, false);
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, &copy, &result);
    try std.testing.expect(std.mem.allEqual(u8, result[64..], 0xa5));
}
