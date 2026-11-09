const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const canvas = sdk.canvas;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const runtime = sdk.runtime.testing.widget_retention_runtime;
const policy = sdk.runtime.testing.widget_retention_policy;
var calls: usize = 0;
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 92) calls += 1;
    return core.nativeWindowPolicy(input, output);
}
fn node(kind: canvas.WidgetKind, id: u64) canvas.WidgetLayoutNode {
    return .{ .widget = .{ .kind = kind, .id = id, .text = "a\xc3\xa9\x00\xff", .text_selection = .{ .anchor = 1, .focus = 4 }, .value = 0.5, .value_x = -0.0, .static_text_group_id = std.math.maxInt(u64), .code_content_width = 51.25, .code_content_width_generation = std.math.maxInt(u64), .code_content_width_font_id = 9007199254740993, .code_content_width_size_bits = 0x3f800001 }, .frame = .init(1.25, -0.0, 77.125, 20), .depth = 0 };
}
test "compiled widget retention all kinds identities capacities complete native records and owned text" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes: [63]canvas.WidgetLayoutNode = undefined;
    inline for (std.meta.tags(canvas.WidgetKind), 0..) |kind, i| nodes[i] = node(kind, @as(u64, i) + 9007199254740993);
    var sources = [_]runtime.CanvasWidgetSourceTextEntry{
        .{ .id = nodes[35].widget.id, .kind = .text_field, .text_len = 91, .text_hash = 19 },
        .{ .id = nodes[35].widget.id, .kind = .input, .text_len = 92, .text_hash = std.math.maxInt(u64), .text_selection = .{ .anchor = 3, .focus = 4 } },
        .{ .id = nodes[35].widget.id, .kind = .input, .text_len = 93, .text_hash = 21 },
    };
    var states: [63]canvas.ScrollState = undefined;
    for (&states, 0..) |*state, i| state.* = .{ .offset_y = @floatFromInt(i), .offset_x = -0.0, .velocity_y = 0.125, .velocity_x = -15.5 };
    for ([_]u64{ 0, 9007199254740993, std.math.maxInt(u64) }) |id| {
        nodes[0].widget.id = id;
        for ([_]usize{ 0, 1, 3, 63 }) |capacity| {
            var a_scroll: [63]runtime.CanvasWidgetSourceScrollEntry = undefined;
            var b_scroll: [63]runtime.CanvasWidgetSourceScrollEntry = undefined;
            try exact(runtime.collectCanvasWidgetScrollOffsetEntries(&nodes, a_scroll[0..capacity]), runtime.collectCanvasWidgetScrollOffsetEntriesWithPolicy(observed, &nodes, b_scroll[0..capacity]));
            var a_source: [63]runtime.CanvasWidgetSourceControlEntry = undefined;
            var b_source: [63]runtime.CanvasWidgetSourceControlEntry = undefined;
            try exact(runtime.collectCanvasWidgetSourceControlEntries(&nodes, a_source[0..capacity]), runtime.collectCanvasWidgetSourceControlEntriesWithPolicy(observed, &nodes, b_source[0..capacity]));
            var a_control: [63]runtime.CanvasWidgetControlReconcileEntry = undefined;
            var b_control: [63]runtime.CanvasWidgetControlReconcileEntry = undefined;
            try exact(runtime.collectCanvasWidgetControlReconcileEntries(&nodes, a_control[0..capacity]), runtime.collectCanvasWidgetControlReconcileEntriesWithPolicy(observed, &nodes, b_control[0..capacity]));
            var a_state: [63]runtime.CanvasWidgetScrollReconcileEntry = undefined;
            var b_state: [63]runtime.CanvasWidgetScrollReconcileEntry = undefined;
            try exact(runtime.collectCanvasWidgetScrollReconcileEntries(&nodes, states[0..7], a_state[0..capacity]), runtime.collectCanvasWidgetScrollReconcileEntriesWithPolicy(observed, &nodes, states[0..7], b_state[0..capacity]));
            var a_text: [63]runtime.CanvasWidgetTextReconcileEntry = undefined;
            var b_text: [63]runtime.CanvasWidgetTextReconcileEntry = undefined;
            var a_bytes: [1024]u8 = @splat(0xaa);
            var b_bytes = a_bytes;
            var a_len: usize = 5;
            var b_len = a_len;
            const expected = try runtime.collectCanvasWidgetTextReconcileEntries(&nodes, &sources, a_text[0..capacity], &a_bytes, &a_len);
            const actual = try runtime.collectCanvasWidgetTextReconcileEntriesWithPolicy(observed, &nodes, &sources, b_text[0..capacity], &b_bytes, &b_len);
            try exact(expected, actual);
            try exact(a_len, b_len);
            try exact(a_bytes, b_bytes);
            core.rt.frameReset();
            try exact(expected, actual); // Copied records outlive the result arena.
        }
    }
    try std.testing.expect(calls == 60);
    // First admitted text copy succeeds, second fails: preserve its prefix,
    // exact length and storage writes rather than pre-rejecting the whole batch.
    var a: [63]runtime.CanvasWidgetTextReconcileEntry = undefined;
    var b: [63]runtime.CanvasWidgetTextReconcileEntry = undefined;
    var aa: [8]u8 = @splat(0xaa);
    var bb = aa;
    var al: usize = 0;
    var bl: usize = 0;
    try std.testing.expectError(error.WidgetTextTooLarge, runtime.collectCanvasWidgetTextReconcileEntries(&nodes, &sources, &a, &aa, &al));
    try std.testing.expectError(error.WidgetTextTooLarge, runtime.collectCanvasWidgetTextReconcileEntriesWithPolicy(observed, &nodes, &sources, &b, &bb, &bl));
    try exact(al, bl);
    try exact(aa, bb);
    try exact(a[0], b[0]);
}
test "compiled widget retention autofocus level held removal remount duplicate and over tracking budget" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const View = sdk.runtime.testing.widget_retention_view;
    const reference = try std.testing.allocator.create(View);
    defer std.testing.allocator.destroy(reference);
    const candidate = try std.testing.allocator.create(View);
    defer std.testing.allocator.destroy(candidate);
    reference.* = .{};
    candidate.* = .{};
    var nodes: [24]canvas.WidgetLayoutNode = undefined;
    for (&nodes, 0..) |*value, i| {
        value.* = node(.text_field, @as(u64, i) + 9007199254740993);
        value.widget.autofocus = true;
    }
    nodes[0].widget.id = 0;
    nodes[23].widget.id = std.math.maxInt(u64);
    for ([_]usize{ 24, 24, 8, 0, 24, 24 }) |count| {
        const plain = canvas.WidgetLayoutTree{ .nodes = nodes[0..count] };
        var compiled = plain;
        compiled.retention_policy = observed;
        try exact(reference.canvasWidgetAutofocusTarget(plain), candidate.canvasWidgetAutofocusTarget(compiled));
        try exact(reference.widget_autofocus_ids[0..reference.widget_autofocus_count], candidate.widget_autofocus_ids[0..candidate.widget_autofocus_count]);
        try reference.copyCanvasWidgetSourceText(plain);
        try candidate.copyCanvasWidgetSourceText(compiled);
        try exact(reference.widgetSourceTextEntries(), candidate.widgetSourceTextEntries());
        core.rt.frameReset();
    }
    // Already tracked duplicates must not take focus; the first new request
    // still wins when it lies outside the tracked prefix on the next rebuild.
    nodes[17].widget.id = nodes[1].widget.id;
    const plain = canvas.WidgetLayoutTree{ .nodes = &nodes };
    var compiled = plain;
    compiled.retention_policy = observed;
    try exact(reference.canvasWidgetAutofocusTarget(plain), candidate.canvasWidgetAutofocusTarget(compiled));
}
