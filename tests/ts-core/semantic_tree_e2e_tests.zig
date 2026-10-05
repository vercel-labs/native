const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const expectComplete = @import("surface_layout_e2e_tests.zig").expectComplete;
extern fn nsc_core_native_view(out: *[*]const u8, len: *usize) callconv(.c) void;

fn compare(nodes: []const canvas.WidgetLayoutNode) !void {
    const native = canvas.WidgetLayoutTree{ .nodes = nodes };
    const compiled = canvas.WidgetLayoutTree{ .nodes = nodes, .semantic_policy = core.nativeWindowPolicy };
    var expected: [512]canvas.WidgetSemanticsNode = undefined;
    var actual: [512]canvas.WidgetSemanticsNode = undefined;
    try expectComplete(try native.collectSemantics(&expected), try compiled.collectSemantics(&actual));
    for (nodes, 0..) |node, i| {
        const viewport = node.frame.inset(node.widget.layout.padding).normalized();
        inline for (.{ canvas.ScrollAxis.vertical, canvas.ScrollAxis.horizontal }) |axis| {
            try expectComplete(canvas.widgetScrollAxisMetrics(native, i, canvas.virtualWidgetScrollContentExtent, axis, viewport), canvas.widgetScrollAxisMetrics(compiled, i, canvas.virtualWidgetScrollContentExtent, axis, viewport));
        }
        core.rt.frameReset();
    }
}

test "compiled semantics preserve every role state override and native text range" {
    @setEvalBranchQuota(100000);
    _ = core.initialModel();
    defer core.rt.frameReset();
    inline for (@typeInfo(canvas.WidgetKind).@"enum".fields) |field| {
        const kind: canvas.WidgetKind = @enumFromInt(field.value);
        for ([_]f32{ -1, -0.0, 0, 0.5, 1, std.math.inf(f32), std.math.nan(f32) }) |value| {
            for ([_]?bool{ null, false, true }) |expanded| {
                const widget = canvas.Widget{ .id = 1, .kind = kind, .text = "Utf8 \xc3\xa9 value", .placeholder = "Placeholder", .value = value, .state = .{ .expanded = expanded, .selected = value == 0 }, .semantics = .{ .label = "Authored label", .actions = .{ .press = true, .drop_files = true } } };
                const nodes = [_]canvas.WidgetLayoutNode{.{ .widget = widget, .frame = .init(0, 0, 240, 100), .depth = 0, .parent_index = null }};
                try compare(&nodes);
            }
        }
    }
}

test "compiled semantics preserve suppressed siblings concealed descendants and partial error output" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes = [_]canvas.WidgetLayoutNode{
        .{ .widget = .{ .id = 1, .kind = .column }, .frame = .init(0, 0, 240, 300), .depth = 0, .parent_index = null },
        .{ .widget = .{ .id = 2, .kind = .accordion }, .frame = .init(0, 0, 240, 40), .depth = 1, .parent_index = 0 },
        .{ .widget = .{ .id = 3, .kind = .button }, .frame = .init(0, 50, 240, 80), .depth = 2, .parent_index = 1 },
        .{ .widget = .{ .id = 4, .kind = .separator }, .frame = .init(0, 140, 240, 1), .depth = 1, .parent_index = 0 },
        .{ .widget = .{ .id = 5, .kind = .button }, .frame = .init(0, 150, 240, 30), .depth = 2, .parent_index = 3 },
        .{ .widget = .{ .id = 6, .kind = .text, .semantics = .{ .hidden = true } }, .frame = .init(0, 200, 240, 30), .depth = 1, .parent_index = 0 },
        .{ .widget = .{ .id = 7, .kind = .button }, .frame = .init(0, 230, 240, 30), .depth = 2, .parent_index = 5 },
    };
    try compare(&nodes);
    nodes[1].widget.state.selected = true;
    nodes[1].frame.height = 140;
    try compare(&nodes);
    const native = canvas.WidgetLayoutTree{ .nodes = &nodes };
    const compiled = canvas.WidgetLayoutTree{ .nodes = &nodes, .semantic_policy = core.nativeWindowPolicy };
    var a: [2]canvas.WidgetSemanticsNode = undefined;
    var b: [2]canvas.WidgetSemanticsNode = undefined;
    try std.testing.expectError(error.WidgetSemanticsListFull, native.collectSemantics(&a));
    try std.testing.expectError(error.WidgetSemanticsListFull, compiled.collectSemantics(&b));
    try expectComplete(a, b);
    nodes[6].depth = 32;
    var c: [16]canvas.WidgetSemanticsNode = undefined;
    var d: [16]canvas.WidgetSemanticsNode = undefined;
    try std.testing.expectError(error.WidgetDepthExceeded, native.collectSemantics(&c));
    try std.testing.expectError(error.WidgetDepthExceeded, compiled.collectSemantics(&d));
}

test "compiled grid and list semantics retain every unsigned column index and count bit" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const children = [_]canvas.Widget{ .{ .kind = .text }, .{ .kind = .text }, .{ .kind = .text } };
    var nodes = [_]canvas.WidgetLayoutNode{
        .{ .widget = .{ .id = 1, .kind = .grid, .children = &children, .semantics = .{ .role = .grid } }, .frame = .init(0, 0, 240, 100), .depth = 0, .parent_index = null },
        .{ .widget = .{ .id = 2, .kind = .data_cell, .semantics = .{ .list_item_index = std.math.maxInt(u32) } }, .frame = .init(0, 0, 80, 30), .depth = 1, .parent_index = 0 },
    };
    for ([_]usize{ 0, 1, 3, 16777219, 4294967298, 9007199254740993, std.math.maxInt(usize) }) |columns| {
        nodes[0].widget.layout.columns = columns;
        try compare(&nodes);
    }
    nodes[0].widget.kind = .list;
    nodes[1].widget.kind = .text;
    nodes[1].widget.semantics.list_item_count = 0;
    try compare(&nodes);
    nodes[1].widget.kind = .list_item;
    nodes[1].widget.semantics = .{};
    try compare(&nodes);
}

test "compiled table reduction preserves uneven rows authored ordinals and nested semantic grouping" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes: [7]canvas.WidgetLayoutNode = undefined;
    const kinds = [_]canvas.WidgetKind{ .table, .data_row, .data_cell, .text, .data_row, .data_cell, .data_cell };
    const parents = [_]?usize{ null, 0, 1, 1, 0, 4, 4 };
    const depths = [_]usize{ 0, 1, 2, 2, 1, 2, 2 };
    for (&nodes, 0..) |*node, i| node.* = .{ .widget = .{ .id = @intCast(i + 1), .kind = kinds[i] }, .frame = .init(0, 0, 240, 30), .depth = depths[i], .parent_index = parents[i] };
    try compare(&nodes);
    nodes[4].widget.semantics.list_item_index = std.math.maxInt(u32);
    nodes[0].widget.semantics.list_item_count = std.math.maxInt(u32);
    try compare(&nodes);
}

test "compiled scroll observations preserve each axis exclusion primary rule and numeric boundary" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes = [_]canvas.WidgetLayoutNode{
        .{ .widget = .{ .id = 1, .kind = .scroll_view }, .frame = .init(0, 0, 240, 100), .depth = 0, .parent_index = null },
        .{ .widget = .{ .id = 2, .kind = .dialog }, .frame = .init(0, 0, 900, 900), .depth = 1, .parent_index = 0 },
        .{ .widget = .{ .id = 3, .kind = .text }, .frame = .init(0, 0, 1000, 1000), .depth = 2, .parent_index = 1 },
        .{ .widget = .{ .id = 4, .kind = .popover, .layout = .{ .anchor = .{} } }, .frame = .init(0, 0, 800, 800), .depth = 1, .parent_index = 0 },
        .{ .widget = .{ .id = 5, .kind = .accordion }, .frame = .init(0, 0, 300, 120), .depth = 1, .parent_index = 0 },
        .{ .widget = .{ .id = 6, .kind = .text }, .frame = .init(0, 0, 700, 700), .depth = 2, .parent_index = 4 },
        .{ .widget = .{ .id = 7, .kind = .text }, .frame = .init(0, 0, 320, 150), .depth = 1, .parent_index = 0 },
    };
    for ([_]canvas.ScrollAxes{ .vertical, .horizontal, .both }) |axes| {
        for ([_]f32{ -999, -0.0, 0, 25.000002, 999, std.math.inf(f32), std.math.nan(f32) }) |offset| {
            nodes[0].widget.scroll_axes = axes;
            nodes[0].widget.value = offset;
            nodes[0].widget.value_x = offset;
            try compare(&nodes);
            nodes[4].widget.state.selected = true;
            nodes[4].frame.height = 700;
            try compare(&nodes);
            nodes[4].widget.layout.clip_content = true;
            try compare(&nodes);
            nodes[4].widget.state.selected = false;
            nodes[4].frame.height = 120;
            nodes[4].widget.layout.clip_content = false;
        }
    }
}

test "compiled semantic buffers preserve borrowed views text and core allocations across large plans" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes: [256]canvas.WidgetLayoutNode = undefined;
    const text = core.rt.frameAlloc(u8, 8);
    @memcpy(text, "tree\x00abi");
    var view: [*]const u8 = undefined;
    var view_len: usize = 0;
    nsc_core_native_view(&view, &view_len);
    const saved = try std.testing.allocator.dupe(u8, view[0..view_len]);
    defer std.testing.allocator.free(saved);
    for (&nodes, 0..) |*node, i| node.* = .{ .widget = .{ .id = @intCast(i + 1), .kind = .text, .text = text }, .frame = .init(0, @floatFromInt(i), 240, 30), .depth = 0, .parent_index = null };
    const native = canvas.WidgetLayoutTree{ .nodes = &nodes };
    const compiled = canvas.WidgetLayoutTree{ .nodes = &nodes, .semantic_policy = core.nativeWindowPolicy };
    var a: [256]canvas.WidgetSemanticsNode = undefined;
    var b: [256]canvas.WidgetSemanticsNode = undefined;
    const expected = try native.collectSemantics(&a);
    const actual = try compiled.collectSemantics(&b);
    try expectComplete(expected, actual);
    try std.testing.expectEqualSlices(u8, "tree\x00abi", text);
    try std.testing.expectEqualSlices(u8, saved, view[0..view_len]);
    core.rt.frameReset();
    // Numeric records remain owned after collection. Borrowed text is read
    // only before the enclosing consumer ends its frame lifetime.
    for (expected, actual) |left, right| {
        try expectComplete(left.bounds, right.bounds);
        try std.testing.expectEqual(left.id, right.id);
    }
}

test "compiled semantics preserve authored roles all state bits values chart data and unicode ranges" {
    @setEvalBranchQuota(100000);
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes = [_]canvas.WidgetLayoutNode{.{
        .widget = .{ .id = 1, .kind = .text_field, .text = "a\xc3\xa9b", .placeholder = "Edit", .text_selection = .{ .anchor = 2, .focus = 4 }, .text_composition = .{ .start = 1, .end = 3 }, .chart = .{ .series = &.{.{ .values = &.{ -1, 37.25 } }} } },
        .frame = .init(0, 0, 240, 100),
        .depth = 0,
        .parent_index = null,
    }};
    for ([_]canvas.WidgetKind{ .text_field, .chart, .checkbox, .scroll_view, .terminal }) |kind| {
        nodes[0].widget.kind = kind;
        inline for (@typeInfo(canvas.WidgetRole).@"enum".fields) |field| {
            nodes[0].widget.semantics.role = @enumFromInt(field.value);
            for (0..256) |bits| {
                nodes[0].widget.state = .{ .hovered = bits & 1 != 0, .pressed = bits & 2 != 0, .focused = bits & 4 != 0, .disabled = bits & 8 != 0, .selected = bits & 16 != 0, .required = bits & 32 != 0, .read_only = bits & 64 != 0, .invalid = bits & 128 != 0 };
                nodes[0].widget.semantics.value = if (bits & 1 != 0) -0.0 else null;
                nodes[0].widget.semantics.focusable = bits & 2 != 0;
                try compare(&nodes);
            }
        }
    }
}

fn customVirtualExtent(_: canvas.Widget, viewport: f32) f32 {
    return viewport + 512.25;
}
test "compiled axis queries honor custom virtual extent callbacks and supplied viewports" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const nodes = [_]canvas.WidgetLayoutNode{.{ .widget = .{ .id = 1, .kind = .list, .value = 101.125, .layout = .{ .virtualized = true } }, .frame = .init(0, 0, 240, 100), .depth = 0, .parent_index = null }};
    const native = canvas.WidgetLayoutTree{ .nodes = &nodes };
    const compiled = canvas.WidgetLayoutTree{ .nodes = &nodes, .semantic_policy = core.nativeWindowPolicy };
    const viewport = geometry.RectF.init(12, 17, 200, 61.25);
    inline for (.{ canvas.ScrollAxis.vertical, canvas.ScrollAxis.horizontal }) |axis| try expectComplete(canvas.widgetScrollAxisMetrics(native, 0, customVirtualExtent, axis, viewport), canvas.widgetScrollAxisMetrics(compiled, 0, customVirtualExtent, axis, viewport));
}
