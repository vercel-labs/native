const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const r = sdk.runtime.testing.widget_retention_runtime;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: usize = 0;
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 93) calls += 1;
    return core.nativeWindowPolicy(input, output);
}
fn compare(nodes: []const c.WidgetLayoutNode, controls: []const r.CanvasWidgetControlReconcileEntry, sources: []const r.CanvasWidgetSourceControlEntry, texts: []const r.CanvasWidgetTextReconcileEntry) !void {
    var ci = r.CanvasWidgetControlEntryIndex{};
    var si = r.CanvasWidgetSourceControlEntryIndex{};
    var ti = r.CanvasWidgetTextEntryIndex{};
    ci.build(controls);
    si.build(sources);
    ti.build(texts);
    const tree = c.WidgetLayoutTree{ .nodes = nodes };
    const plan = r.canvasWidgetReconcilePlan(observed, tree, &ci, &si, &ti).?;
    core.rt.frameReset(); // Results must outlive the compiler's result arena.
    for (nodes, 0..) |node, i| {
        const expected_text = r.canvasWidgetLayoutNodeWithTextReconcileState(node, tree, i, &ti);
        const actual_text = r.canvasWidgetLayoutNodeWithPlannedText(node, plan.entries[i], &ti);
        try exact(expected_text, actual_text);
        try exact(r.canvasWidgetLayoutNodeWithControlReconcileState(expected_text, tree, i, &ci, &si), r.canvasWidgetLayoutNodeWithPlannedControl(actual_text, plan.entries[i]));
    }
}
fn makeNode(kind: c.WidgetKind, id: u64) c.WidgetLayoutNode {
    return .{ .widget = .{ .kind = kind, .id = id, .text = "a\xc3\xa9\x00\xff", .value = 0.25, .frame = .init(1, 2, 90, 31) }, .frame = .init(1.25, -0.0, 90, 31), .depth = 0 };
}
test "compiled widget reconciliation complete controls all kinds source flips pressed disabled hidden and identities" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes: [63]c.WidgetLayoutNode = undefined;
    var controls: [63]r.CanvasWidgetControlReconcileEntry = undefined;
    var sources: [63]r.CanvasWidgetSourceControlEntry = undefined;
    for ([_]u64{ 0, 9007199254740993, std.math.maxInt(u64) }) |id| for (0..32) |bits| {
        inline for (std.meta.tags(c.WidgetKind), 0..) |kind, i| {
            nodes[i] = makeNode(kind, id);
            nodes[i].widget.state.selected = bits & 1 != 0;
            nodes[i].widget.state.disabled = bits & 16 != 0;
            controls[i] = .{ .id = id, .kind = kind, .state = .{ .selected = bits & 2 != 0, .pressed = bits & 8 != 0 }, .value = if (kind == .resizable) 73.125 else 0.75 };
            sources[i] = .{ .id = id, .kind = kind, .selected = bits & 4 != 0, .value = if (bits & 4 != 0) 0.25 else 0.5 };
        }
        try compare(&nodes, &controls, &sources, &.{});
        try compare(&nodes, &controls, &.{}, &.{});
        try compare(&nodes, &.{}, &sources, &.{});
        nodes[0].widget.semantics.hidden = true;
        for (nodes[1..]) |*n| n.parent_index = 0;
        try compare(&nodes, &controls, &sources, &.{});
    };
    for ([_]c.WidgetKind{ .slider, .resizable }) |kind| for ([_]f32{ -std.math.inf(f32), -0.0, 0.125, 1.25, std.math.inf(f32), std.math.nan(f32) }) |value| {
        var n = makeNode(kind, 9007199254740993);
        n.widget.value = value;
        const retained = r.CanvasWidgetControlReconcileEntry{ .id = n.widget.id, .kind = kind, .value = value };
        try compare(&.{n}, &.{retained}, &.{}, &.{});
    };
    try compare(&.{}, &.{}, &.{}, &.{});
    try std.testing.expect(calls >= 385);
}
test "compiled widget reconciliation complete text source divergence affinity composition and code cache ownership" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const kinds = [_]c.WidgetKind{ .text, .input, .text_field, .search_field, .combobox, .textarea };
    for (kinds) |kind| for (0..128) |bits| {
        var n = makeNode(kind, std.math.maxInt(u64));
        n.widget.runtime_flags.code_editor = bits & 1 != 0;
        n.widget.code_line_number_digits = if (bits & 2 != 0) 0x80 else 0;
        n.widget.text_selection = if (bits & 4 != 0) .{ .anchor = 1, .focus = 3, .affinity = if (bits & 8 != 0) .downstream else .upstream } else null;
        n.widget.text_composition = if (bits & 16 != 0) .{ .start = 1, .end = 3 } else null;
        n.widget.static_text_group_id = if (bits & 32 != 0) std.math.maxInt(u64) else 0;
        const fingerprint = r.canvasWidgetSourceTextFingerprint(if (bits & 64 != 0) "different source" else n.widget.text);
        var entry = r.CanvasWidgetTextReconcileEntry{ .id = n.widget.id, .kind = kind, .text = n.widget.text, .static_text_group_id = std.math.maxInt(u64), .source_text_len = fingerprint.len, .source_text_hash = fingerprint.hash, .text_selection = .{ .anchor = 1, .focus = 3, .affinity = .downstream }, .source_text_selection = .{ .anchor = 0, .focus = 0, .affinity = .upstream }, .text_composition = .{ .start = 1, .end = 4 }, .value = 19.125, .value_x = -0.0, .code_content_width = 73.25, .code_content_width_generation = std.math.maxInt(u64), .code_content_width_font_id = 9007199254740993, .code_content_width_size_bits = 0x3f800001 };
        try compare(&.{n}, &.{}, &.{}, &.{entry});
        entry.text = "retained replacement\x00\xff";
        try compare(&.{n}, &.{}, &.{}, &.{entry});
        entry.source_text_selection = null;
        try compare(&.{n}, &.{}, &.{}, &.{entry});
        entry.text_selection = null;
        try compare(&.{n}, &.{}, &.{}, &.{entry});
        n.widget.state.disabled = true;
        try compare(&.{n}, &.{}, &.{}, &.{entry});
    };
}
test "compiled widget reconciliation full budget and first kind matching retain exact records" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes: [1024]c.WidgetLayoutNode = undefined;
    for (&nodes, 0..) |*n, i| n.* = makeNode(.radio, 9007199254740993 + i);
    const controls = [_]r.CanvasWidgetControlReconcileEntry{
        .{ .id = nodes[0].widget.id, .kind = .checkbox, .value = 0 },
        .{ .id = nodes[0].widget.id, .kind = .radio, .value = 1 },
        .{ .id = nodes[0].widget.id, .kind = .radio, .value = 0 },
    };
    try compare(&nodes, &controls, &.{}, &.{});
}
