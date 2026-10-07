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
    result.paint_policy = core.nativeWindowPolicy;
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
    const paint = try canvas.widget_paint_policy.Plan.diff(std.testing.allocator, core.nativeWindowPolicy, Tree{ .nodes = &before }, Tree{ .nodes = &after }, .{}, null, null, plan);
    defer paint.deinit();
    const paint_request = try std.testing.allocator.dupe(u8, paint.request);
    defer std.testing.allocator.free(paint_request);
    const paint_result = try std.testing.allocator.dupe(u8, paint.result);
    defer std.testing.allocator.free(paint_result);
    const request = try std.testing.allocator.dupe(u8, plan.request);
    defer std.testing.allocator.free(request);
    const result = try std.testing.allocator.dupe(u8, plan.result);
    defer std.testing.allocator.free(result);
    for (0..16) |_| {
        _ = core.initialModel();
        core.rt.frameReset();
        try std.testing.expectEqualSlices(u8, request, plan.request);
        try std.testing.expectEqualSlices(u8, result, plan.result);
        try std.testing.expectEqualSlices(u8, paint_request, paint.request);
        try std.testing.expectEqualSlices(u8, paint_result, paint.result);
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

test "compiled widget changes paint geometry preserves all chrome sizes densities token overrides and snapping" {
    _ = core.initialModel();
    for (std.enums.values(canvas.WidgetKind)) |kind| for (std.enums.values(canvas.WidgetSize)) |size| for (std.enums.values(canvas.Density)) |density| for (0..8) |flags| {
        var tokens: canvas.DesignTokens = .{ .density = density };
        tokens.pixel_snap = .{ .geometry = flags & 1 != 0, .scale = if (flags & 2 != 0) 1.5 else 2.25 };
        tokens.controls.tabs_indicator = if (flags & 4 != 0) .underline else .pill;
        tokens.controls.button_group_style = if (flags & 4 != 0) .detached else .segmented;
        tokens.controls.panel.stroke_width = 3.125;
        tokens.controls.button_outline.stroke_width = 0.625;
        tokens.controls.toggle_button.stroke_width = 4.25;
        tokens.controls.checkbox.stroke_width = -0.0;
        tokens.stroke.focus = 2.75;
        tokens.stroke.focus_offset = 1.375;
        tokens.metrics.size_inset_step = 3.625;
        tokens.metrics.tabs_trigger_inset = 7.75;
        tokens.metrics.tabs_label_size_step = 2.125;
        tokens.shadow.sm = .{ .y = -2.625, .blur = 3.375, .spread = -1.125 };
        tokens.shadow.md = .{ .y = 4.125, .blur = 6.625, .spread = -2.875 };
        var before = [_]canvas.WidgetLayoutNode{
            node(.{ .kind = .row, .id = 1, .layout = .{ .clip_content = true } }, .init(-20.5, -30.25, 260.75, 230.5), null, 0),
            node(.{ .kind = kind, .size = size, .id = 0xfedcba9876543210, .text = "raw\xff\x00label", .icon = "check", .frame = .init(-4.75, -6.5, 73.375, 34.125), .variant = .outline, .group_segment = .first, .backdrop_blur_token = .sm, .state = .{ .focused = true } }, .init(-3.625, -5.25, 74.125, 33.375), 0, 1),
            node(.{ .kind = .bubble, .id = 3, .text = "reaction", .text_alignment = .center }, .init(5.125, 23.625, 60.75, 25.5), 1, 2),
        };
        var after = before;
        after[1].frame = .init(-7.25, 10.75, 90.375, 43.125);
        after[1].widget.transform = .{ .a = 0.875, .b = 0.25, .c = -0.125, .d = 1.125, .tx = -0.0, .ty = 5.375 };
        after[1].widget.style.stroke_width = if (flags & 2 != 0) -1 else 4.125;
        after[1].widget.text_alignment = if (flags & 2 != 0) .start else .end;
        errdefer std.debug.print("paint geometry kind {t} size {t} density {t} flags {d}\n", .{ kind, size, density, flags });
        try compare(.{ .nodes = &before }, .{ .nodes = &after }, tokens, 4);
        const layout: Tree = .{ .nodes = &before };
        try exact(layout.renderStateDirtyBoundsWithTokens(.{}, .{ .hovered_id = before[1].widget.id, .focus_visible_id = before[1].widget.id }, tokens), owned(layout).renderStateDirtyBoundsWithTokens(.{}, .{ .hovered_id = before[1].widget.id, .focus_visible_id = before[1].widget.id }, tokens));
        core.rt.frameReset();
    };
}

test "compiled widget changes paint measurement requests preserve raw text font sizes and callback order" {
    _ = core.initialModel();
    const Provider = struct {
        const Call = struct { font: canvas.FontId, size: f32, text: [32]u8, length: usize };
        calls: std.ArrayList(Call) = .empty,
        fn width(context: ?*anyopaque, font: canvas.FontId, size: f32, text: []const u8) f32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            var bytes: [32]u8 = @splat(0);
            @memcpy(bytes[0..text.len], text);
            self.calls.append(std.testing.allocator, .{ .font = font, .size = size, .text = bytes, .length = text.len }) catch @panic("measurement log allocation");
            return @as(f32, @floatFromInt(text.len)) * size * 0.713;
        }
    };
    var state = Provider{};
    defer state.calls.deinit(std.testing.allocator);
    const provider = canvas.TextMeasureProvider{ .context = &state, .measure_fn = Provider.width };
    var tokens: canvas.DesignTokens = .{ .text_measure = &provider };
    tokens.controls.tabs_indicator = .underline;
    const before = [_]canvas.WidgetLayoutNode{
        node(.{ .kind = .bubble, .id = 1, .text = "before\xff\x00", .size = .sm, .text_alignment = .end }, .init(0, 0, 30, 20), null, 0),
        node(.{ .kind = .segmented_control, .id = 2, .text = "tab-before", .icon = "check", .size = .lg }, .init(0, 50, 70, 30), null, 0),
    };
    var after = before;
    after[0].widget.text = "after\x00\xff";
    after[0].frame.height = 31.75;
    after[1].widget.text = "tab-after";
    after[1].frame.width = 100.25;
    for (0..4) |capacity| {
        var a: [4]canvas.WidgetInvalidation = undefined;
        var b: [4]canvas.WidgetInvalidation = undefined;
        state.calls.clearRetainingCapacity();
        canvas.bumpTextMeasureGeneration();
        const expected = Tree.diffWithTokens(.{ .nodes = &before }, .{ .nodes = &after }, tokens, a[0..capacity]);
        const calls = try std.testing.allocator.dupe(Provider.Call, state.calls.items);
        defer std.testing.allocator.free(calls);
        state.calls.clearRetainingCapacity();
        canvas.bumpTextMeasureGeneration();
        const actual = Tree.diffWithTokens(owned(.{ .nodes = &before }), owned(.{ .nodes = &after }), tokens, b[0..capacity]);
        if (expected) |v| try exact(v, try actual) else |err| try std.testing.expectError(err, actual);
        try exact(@as([]const Provider.Call, calls), state.calls.items);
        core.rt.frameReset();
    }
}

test "compiled widget changes paint geometry preserves bounded transforms hidden ancestors and escaped clips" {
    _ = core.initialModel();
    var before: [40]canvas.WidgetLayoutNode = undefined;
    for (&before, 0..) |*n, i| n.* = node(.{ .kind = .panel, .id = i + 1, .frame = .init(0, 0, 100, 100), .transform = .{ .a = 0.9375, .d = 1.0625, .tx = 1.125, .ty = -0.375 }, .layout = .{ .clip_content = i % 3 == 0 } }, .init(@floatFromInt(i), 0, 100, 100), if (i == 0) null else i - 1, i);
    for (0..8) |flags| {
        var after = before;
        after[0].widget.opacity = 0.5;
        after[33].widget.semantics.hidden = flags & 1 != 0;
        after[35].widget.layout.anchor = if (flags & 2 != 0) .{} else null;
        after[36].widget.kind = if (flags & 4 != 0) .dialog else .panel;
        try compare(.{ .nodes = &before }, .{ .nodes = &after }, .{}, 40);
    }
}

test "compiled widget changes paint geometry preserves exceptional scalar words and signed zero extrema" {
    _ = core.initialModel();
    const words = [_]u32{ 0, 0x80000000, 0x3f400000, 0xbf400000, 0x7f800000, 0xff800000, 0x7fc00037 };
    for ([_]canvas.WidgetKind{ .button, .checkbox, .slider, .panel, .bubble }) |kind| for (words) |a| for (words) |b| {
        var before = [_]canvas.WidgetLayoutNode{node(.{ .kind = kind, .id = 1, .frame = .init(-0.0, 0, 100, 32), .value = @bitCast(a), .style = .{ .stroke_width = @bitCast(a) } }, .init(-0.0, 0, 100, 32), null, 0)};
        var after = before;
        after[0].widget.state.focused = true;
        after[0].widget.value = @bitCast(b);
        after[0].widget.style.stroke_width = @bitCast(b);
        var tokens: canvas.DesignTokens = .{};
        tokens.stroke.focus = @bitCast(a);
        tokens.stroke.focus_offset = @bitCast(b);
        errdefer std.debug.print("paint scalar words {t} {x}/{x}\n", .{ kind, a, b });
        try compare(.{ .nodes = &before }, .{ .nodes = &after }, tokens, 2);
    };
}

test "compiled widget changes paint subtree comparisons preserve full width depth words" {
    _ = core.initialModel();
    var before = [_]canvas.WidgetLayoutNode{
        node(.{ .kind = .panel, .id = 1 }, .init(0, 0, 100, 100), null, std.math.maxInt(usize) - 2),
        node(.{ .kind = .bubble, .id = 2, .text = "wide" }, .init(5, 5, 30, 20), 0, std.math.maxInt(usize) - 1),
        node(.{ .kind = .button, .id = 3 }, .init(5, 30, 20, 20), 0, std.math.maxInt(usize)),
    };
    var after = before;
    after[0].widget.opacity = 0.5;
    after[1].widget.semantics.hidden = true;
    try compare(.{ .nodes = &before }, .{ .nodes = &after }, .{}, 4);
}
