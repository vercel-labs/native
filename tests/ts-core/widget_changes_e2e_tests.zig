//! Complete retained invalidations compared against the unchanged native
//! classifier through the production scriptc library, including write prefixes.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const canvas = sdk.canvas;
const exact = @import("component_construction_e2e_tests.zig").exact;
const Tree = canvas.WidgetLayoutTree;
fn node(widget: canvas.Widget, frame: sdk.geometry.RectF, parent: ?usize, depth: usize) canvas.WidgetLayoutNode {
    return .{ .widget = widget, .frame = frame, .parent_index = parent, .depth = depth };
}
fn owned(reference: Tree) Tree {
    var result = reference;
    result.change_policy = core.nativeWindowPolicy;
    return result;
}
fn compare(previous: Tree, next: Tree, tokens: canvas.DesignTokens, capacity: usize) !void {
    var a: [2048]canvas.WidgetInvalidation = undefined;
    var b: [2048]canvas.WidgetInvalidation = undefined;
    const sentinel: canvas.WidgetInvalidation = .{ .kind = .changed, .id = 0xdeadbeef, .previous_index = 73, .next_index = 91, .dirty_bounds = .init(1, 2, 3, 4) };
    @memset(&a, sentinel);
    @memset(&b, sentinel);
    const expected = Tree.diffWithTokens(previous, next, tokens, a[0..capacity]);
    const actual = Tree.diffWithTokens(owned(previous), owned(next), tokens, b[0..capacity]);
    if (expected) |value| {
        try exact(value, try actual);
    } else |err| try std.testing.expectError(err, actual);
    // Compare both the written prefix and every untouched caller slot.
    try exact(a, b);
    const saved = b;
    core.rt.frameReset();
    try exact(saved, b);
}
test "compiled widget changes preserve complete ordered changes and caller capacity prefixes" {
    _ = core.initialModel();
    var before = [_]canvas.WidgetLayoutNode{
        node(.{ .kind = .row, .id = 0 }, .init(0, 0, 300, 200), null, 0),
        node(.{ .kind = .button, .id = std.math.maxInt(u64), .text = "old\xff\x00" }, .init(5, 5, 60, 30), 0, 1),
        node(.{ .kind = .text, .id = 0x20000000000001, .text = "removed" }, .init(5, 40, 60, 30), 0, 1),
    };
    var after = [_]canvas.WidgetLayoutNode{
        before[0],
        node(.{ .kind = .button, .id = 0x20000000000002, .text = "added" }, .init(5, 5, 60, 30), 0, 1),
        node(.{ .kind = .button, .id = std.math.maxInt(u64), .text = "new\x00\xff" }, .init(5, 40, 60, 30), 0, 1),
    };
    for (0..6) |capacity| try compare(.{ .nodes = &before }, .{ .nodes = &after }, .{}, capacity);
    try compare(.{}, .{}, .{}, 0);
    try compare(.{ .nodes = &before }, .{}, .{}, 3);
    try compare(.{}, .{ .nodes = &after }, .{}, 3);
    after[1].widget.id = std.math.maxInt(u64);
    for (0..4) |capacity| try compare(.{ .nodes = &before }, .{ .nodes = &after }, .{}, capacity);
    before[2].widget.id = before[1].widget.id;
    try compare(.{ .nodes = &before }, .{}, .{}, 0);
}
test "compiled widget changes preserve all kinds root bounds visibility transforms and paint geometry" {
    _ = core.initialModel();
    for (std.enums.values(canvas.WidgetKind)) |kind| for (0..64) |flags| {
        var before = [_]canvas.WidgetLayoutNode{
            node(.{ .kind = .scroll_view, .id = 1 }, .init(0, 0, 150, 100), null, 0),
            node(.{ .kind = kind, .id = 2, .frame = .init(80, 70, 40, 30), .text = "content" }, .init(80, 70, 40, 30), 0, 1),
            node(.{ .kind = .button, .id = 3, .frame = .init(110, 90, 60, 30) }, .init(110, 90, 60, 30), 1, 2),
        };
        var after = before;
        after[1].widget.semantics.hidden = flags & 1 != 0;
        after[1].widget.opacity = if (flags & 2 != 0) 0.5 else 1;
        after[1].widget.transform = if (flags & 4 != 0) .{ .a = 1, .b = 0.25, .c = -0.5, .d = 0.75, .tx = 7.5, .ty = -2.25 } else .{};
        after[1].widget.layer = if (flags & 8 != 0) -10 else null;
        after[1].widget.layout.anchor = if (flags & 16 != 0) .{} else null;
        after[0].widget.semantics.hidden = flags & 32 != 0;
        try compare(.{ .nodes = &before, .root_bounds = .init(0, 0, 150, 100) }, .{ .nodes = &after, .root_bounds = .init(0, 0, 160, 120) }, .{}, 4);
    };
}

fn pathType(comptime T: type, comptime path: []const []const u8) type {
    if (path.len == 0) return T;
    return pathType(@FieldType(T, path[0]), path[1..]);
}
fn getAt(value: anytype, comptime path: []const []const u8) pathType(@TypeOf(value), path) {
    if (path.len == 0) return value;
    return getAt(@field(value, path[0]), path[1..]);
}
fn setAt(value: anytype, comptime path: []const []const u8, replacement: pathType(@TypeOf(value.*), path)) void {
    if (path.len == 1) @field(value.*, path[0]) = replacement else setAt(&@field(value.*, path[0]), path[1..], replacement);
}
fn compareWidget(before: canvas.Widget, after: canvas.Widget) !void {
    const frame = sdk.geometry.RectF.init(20, 10, 80, 40);
    const previous = [_]canvas.WidgetLayoutNode{node(before, frame, null, 0)};
    const next = [_]canvas.WidgetLayoutNode{node(after, frame, null, 0)};
    try compare(.{ .nodes = &previous, .root_bounds = .init(0, 0, 300, 200) }, .{ .nodes = &next, .root_bounds = .init(0, 0, 300, 200) }, .{}, 4);
}
fn variantAt(before: canvas.Widget, comptime path: []const []const u8, replacement: pathType(canvas.Widget, path)) !void {
    var after = before;
    setAt(&after, path, replacement);
    errdefer std.debug.print("change field parity: {s}\n", .{path[path.len - 1]});
    try compareWidget(before, after);
}
fn mutateFields(before: canvas.Widget, comptime path: []const []const u8) anyerror!void {
    const T = pathType(canvas.Widget, path);
    const value = getAt(before, path);
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.fields) |field| try mutateFields(before, path ++ .{field.name}),
        .bool => try variantAt(before, path, !value),
        .int => |info| {
            try variantAt(before, path, value +% 1);
            try variantAt(before, path, std.math.maxInt(T));
            if (info.bits >= 64) try variantAt(before, path, 9_007_199_254_740_993);
        },
        .float => try variantAt(before, path, value + 1.25),
        .@"enum" => inline for (std.enums.values(T)) |replacement| try variantAt(before, path, replacement),
        .optional => |opt| switch (@typeInfo(opt.child)) {
            .bool => {
                try variantAt(before, path, false);
                try variantAt(before, path, true);
            },
            .int => {
                try variantAt(before, path, 0);
                try variantAt(before, path, std.math.maxInt(opt.child));
            },
            .float => {
                try variantAt(before, path, 0);
                try variantAt(before, path, 1.25);
            },
            .@"enum" => inline for (std.enums.values(opt.child)) |replacement| try variantAt(before, path, replacement),
            .@"struct" => try variantAt(before, path, std.mem.zeroes(opt.child)),
            else => {},
        },
        .pointer => |p| if (p.size == .slice and p.child == u8) {
            try variantAt(before, path, "raw\xff\x00bytes");
            try variantAt(before, path, "bytes\x00\xffraw");
        },
        else => {},
    }
}
test "compiled widget changes preserve each observed and unobserved scalar field independently" {
    @setEvalBranchQuota(100_000);
    _ = core.initialModel();
    try mutateFields(.{ .kind = .button, .id = 0xfedcba9876543210, .frame = .init(20, 10, 80, 40) }, &.{});
}
test "compiled widget changes preserve raw spans chart series code masks terminal bindings and float equality" {
    _ = core.initialModel();
    const base: canvas.Widget = .{ .kind = .text, .id = 1, .frame = .init(20, 10, 80, 40), .text = "raw\xff\x00text" };
    const words = [_]u32{ 0, 0x80000000, 0x3f800000, 0x3f800001, 0x7f800000, 0xff800000, 0x7fc00037 };
    for (words) |a| for (words) |b| {
        var before = base;
        var after = base;
        before.value = @bitCast(a);
        after.value = @bitCast(b);
        try compareWidget(before, after);
        before.value = 0;
        after.value = 0;
        before.semantics.value = @bitCast(a);
        after.semantics.value = @bitCast(b);
        try compareWidget(before, after);
        const a_values = [_]f32{ @bitCast(a), 3 };
        const b_values = [_]f32{ @bitCast(b), 3 };
        const a_series = [_]canvas.ChartSeries{.{ .values = &a_values, .low = &a_values, .label = "\xff\x00label" }};
        const b_series = [_]canvas.ChartSeries{.{ .values = &b_values, .low = &b_values, .label = "\xff\x00label" }};
        before.chart = .{ .series = &a_series, .x_labels = &.{ "\xff\x00", "\x00\xff" } };
        after.chart = .{ .series = &b_series, .x_labels = &.{ "\xff\x00", "\x00\xff" } };
        try compareWidget(before, after);
        const a_spans = [_]canvas.TextSpan{.{ .text = base.text, .link = "\xff\x00link", .scale = @bitCast(a), .underline = true }};
        const b_spans = [_]canvas.TextSpan{.{ .text = base.text, .link = "\xff\x00link", .scale = @bitCast(b), .underline = true }};
        before.spans = &a_spans;
        after.spans = &b_spans;
        try compareWidget(before, after);
    };
    const masks = [_]u128{ 0, 1, 0x80000000000000000000000000000000, std.math.maxInt(u128) };
    for (masks) |a| for (masks) |b| {
        var before = base;
        var after = base;
        before.setCodeDiffLines(.{ .added = a, .removed = b });
        after.setCodeDiffLines(.{ .added = b, .removed = a });
        try compareWidget(before, after);
        try compareWidget(before, before);
    };
    var grid: canvas.TerminalGrid = .{ .background = .{}, .foreground = .{}, .cursor_color = .{}, .selection_color = .{} };
    for (0..4) |presence| {
        var before = base;
        var after = base;
        before.terminal = .{ .pty = 0xfedcba9876543210, .scrollback = std.math.maxInt(u32), .grid = if (presence & 1 != 0) &grid else null };
        after.terminal = .{ .pty = before.terminal.pty, .scrollback = before.terminal.scrollback, .grid = if (presence & 2 != 0) &grid else null };
        try compareWidget(before, after);
    }
}
test "compiled widget changes preserve full view budgets reorder keyed zero identities and borrowed policy arenas" {
    _ = core.initialModel();
    var before: [1024]canvas.WidgetLayoutNode = undefined;
    var after: [1024]canvas.WidgetLayoutNode = undefined;
    for (&before, 0..) |*n, i| n.* = node(.{ .kind = .text, .id = if (i % 17 == 0) 0 else 0x20000000000000 + i, .text = "\xff\x00row" }, .init(0, @floatFromInt(i * 10), 40, 10), null, 0);
    for (&after, 0..) |*n, i| {
        n.* = before[before.len - 1 - i];
        if (i % 5 == 0) n.widget.text = "changed\x00\xff";
    }
    for ([_]usize{ 0, 1, 31, 32, 33, 512, 1024 }) |capacity| try compare(.{ .nodes = &before }, .{ .nodes = &after }, .{}, capacity);
    var plan = try canvas.widget_change_policy.Plan.init(std.testing.allocator, core.nativeWindowPolicy, Tree{ .nodes = &before }, Tree{ .nodes = &after }, null, null, 2048);
    defer plan.deinit();
    const request = try std.testing.allocator.dupe(u8, plan.request);
    defer std.testing.allocator.free(request);
    const result = try std.testing.allocator.dupe(u8, plan.result);
    defer std.testing.allocator.free(result);
    for (0..16) |_| {
        _ = core.initialModel();
        core.rt.frameReset();
        try std.testing.expectEqualSlices(u8, request, plan.request);
        try std.testing.expectEqualSlices(u8, result, plan.result);
    }
}

test "compiled widget changes preserve complete render state damage with focus groups terminals chart and drag chrome" {
    _ = core.initialModel();
    var grid: canvas.TerminalGrid = .{ .background = .{}, .foreground = .{}, .cursor_color = .{}, .selection_color = .{}, .cursor = .{} };
    var nodes = [_]canvas.WidgetLayoutNode{
        node(.{ .kind = .scroll_view, .id = 1 }, .init(0, 0, 240, 180), null, 0),
        node(.{ .kind = .input_group, .id = 2 }, .init(10, 10, 180, 60), 0, 1),
        node(.{ .kind = .input_group, .id = 3 }, .init(20, 20, 160, 40), 1, 2),
        node(.{ .kind = .text_field, .id = 0xffffffffffffffff }, .init(25, 25, 100, 30), 2, 3),
        node(.{ .kind = .menu_item, .id = 0x20000000000001 }, .init(10, 80, 100, 30), 0, 1),
        node(.{ .kind = .terminal, .id = 0x20000000000002, .terminal = .{ .grid = &grid } }, .init(10, 120, 100, 40), 0, 1),
    };
    const ids = [_]?u64{ null, 0, nodes[3].widget.id, nodes[4].widget.id, nodes[5].widget.id, 0x20000000000003 };
    for (ids) |a| for (ids) |b| for (0..64) |flags| {
        const previous: canvas.WidgetRenderState = .{ .focused_id = a, .focus_visible_id = if (flags & 1 != 0) a else null, .hovered_id = if (flags & 2 != 0) a else null, .pressed_id = if (flags & 4 != 0) a else null, .keyboard_active = flags & 8 != 0, .drag_preview_id = if (flags & 16 != 0) a else null, .hover_point = if (flags & 32 != 0) .init(13.25, 81.75) else null };
        const next: canvas.WidgetRenderState = .{ .focused_id = b, .focus_visible_id = if (flags & 1 != 0) b else null, .hovered_id = if (flags & 2 != 0) b else null, .pressed_id = if (flags & 4 != 0) b else null, .keyboard_active = flags & 8 == 0, .drag_preview_id = if (flags & 16 != 0) b else null, .hover_point = if (flags & 32 != 0) .init(14.25, 82.75) else null };
        const layout: Tree = .{ .nodes = &nodes, .root_bounds = .init(0, 0, 240, 180) };
        errdefer std.debug.print("render parity ids {?d}/{?d} flags {d}: expected {any} actual {any}\n", .{ a, b, flags, layout.renderStateDirtyBoundsWithTokens(previous, next, .{}), owned(layout).renderStateDirtyBoundsWithTokens(previous, next, .{}) });
        try exact(layout.renderStateDirtyBoundsWithTokens(previous, next, .{}), owned(layout).renderStateDirtyBoundsWithTokens(previous, next, .{}));
        core.rt.frameReset();
    };
    // Baked focus, ended sessions and absent cursors have distinct damage.
    for (0..16) |flags| {
        grid.running = flags & 1 != 0;
        grid.cursor = if (flags & 2 != 0) .{} else null;
        nodes[5].widget.state.focused = flags & 4 != 0;
        nodes[0].widget.semantics.hidden = flags & 8 != 0;
        const layout: Tree = .{ .nodes = &nodes };
        try exact(layout.renderStateDirtyBoundsWithTokens(.{ .keyboard_active = false }, .{ .keyboard_active = true }, .{}), owned(layout).renderStateDirtyBoundsWithTokens(.{ .keyboard_active = false }, .{ .keyboard_active = true }, .{}));
        core.rt.frameReset();
    }
}
