//! Complete findings parity through the production scriptc owner.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const canvas = sdk.canvas;
const bridge = canvas.widget_audit_policy;
const exact = @import("component_construction_e2e_tests.zig").exact;
const window = sdk.geometry.RectF.init(0, 0, 400, 300);
fn compare(layout: canvas.WidgetLayoutTree, tokens: canvas.DesignTokens, capacity: usize) !void {
    errdefer std.debug.print("audit parity: nodes {d}, capacity {d}\n", .{ layout.nodes.len, capacity });
    var aa: [1200]canvas.a11y.A11yAuditFinding = undefined;
    var ab: [1200]canvas.a11y.A11yAuditFinding = undefined;
    var la: [1200]canvas.LayoutAuditFinding = undefined;
    var lb: [1200]canvas.LayoutAuditFinding = undefined;
    var reference = layout;
    reference.audit_policy = null;
    var reference_tokens = tokens;
    reference_tokens.widget_audit_policy = null;
    const expected_a = canvas.a11y.auditWidgetA11y(reference, aa[0..capacity]);
    const expected_l = canvas.auditWidgetLayout(reference, window, reference_tokens, la[0..capacity]);
    const actual_a = try bridge.auditA11y(std.testing.allocator, core.nativeWindowPolicy, layout, ab[0..capacity]);
    const actual_l = try bridge.auditLayout(std.testing.allocator, core.nativeWindowPolicy, layout, window, tokens, lb[0..capacity]);
    const saved_a = try std.testing.allocator.dupe(canvas.a11y.A11yAuditFinding, actual_a.findings);
    defer std.testing.allocator.free(saved_a);
    const saved_l = try std.testing.allocator.dupe(canvas.LayoutAuditFinding, actual_l.findings);
    defer std.testing.allocator.free(saved_l);
    core.rt.frameReset();
    try exact(expected_a, actual_a);
    try exact(expected_l, actual_l);
    try exact(@as([]const canvas.a11y.A11yAuditFinding, saved_a), actual_a.findings);
    try exact(@as([]const canvas.LayoutAuditFinding, saved_l), actual_l.findings);
    // Formatting consumes copied findings and native path/name storage.
    for (expected_a.findings, actual_a.findings) |a, b| {
        var left = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer left.deinit();
        var right = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer right.deinit();
        try canvas.a11y.formatA11yAuditFinding(reference, a, &left.writer);
        try canvas.a11y.formatA11yAuditFinding(layout, b, &right.writer);
        try std.testing.expectEqualSlices(u8, left.written(), right.written());
    }
    for (expected_l.findings, actual_l.findings) |a, b| {
        var left = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer left.deinit();
        var right = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer right.deinit();
        try canvas.formatLayoutAuditFinding(reference, a, &left.writer);
        try canvas.formatLayoutAuditFinding(layout, b, &right.writer);
        try std.testing.expectEqualSlices(u8, left.written(), right.written());
    }
}

test "compiled widget audits preserve scroll axes offsets anchored scopes and nested suppression" {
    _ = core.initialModel();
    var nodes = [_]canvas.WidgetLayoutNode{
        node(.{ .kind = .panel, .layout = .{ .clip_content = true } }, .init(0, 0, 100, 100), null),
        node(.{ .kind = .scroll_view }, .init(0, 0, 80, 80), 0),
        node(.{ .kind = .column }, .init(0, 0, 70, 70), 1),
        node(.{ .kind = .button, .id = 9, .text = "same" }, .init(200, 200, 30, 30), 2),
        node(.{ .kind = .button, .id = 10, .text = "same" }, .init(205, 205, 30, 30), 2),
        node(.{ .kind = .button, .id = 11, .text = "same" }, .init(-50, -50, 30, 30), 2),
    };
    for (std.enums.values(canvas.ScrollAxes)) |axes| for ([_]f32{ -10, 0, 20, 50, 90 }) |offset| for (0..32) |flags| {
        nodes[1].widget.scroll_axes = axes;
        nodes[1].widget.value_x = offset;
        nodes[1].widget.layout.virtualized = flags & 1 != 0;
        nodes[2].widget.layout.clip_content = flags & 2 != 0;
        nodes[2].widget.layout.anchor = if (flags & 4 != 0) .{} else null;
        nodes[2].widget.kind = if (flags & 8 != 0) .dialog else .column;
        nodes[2].widget.semantics.hidden = flags & 16 != 0;
        try compare(.{ .nodes = &nodes }, .{}, 64);
    };
}

test "compiled widget audits preserve paint layer opacity transforms and exact f32 thresholds" {
    _ = core.initialModel();
    const edges = [_]f32{ -0.0, 0, 0.49999997, 0.5, 0.50000006, 15.249999, 17.5, 17.500002, 18, 20.25, 100.50001, 400.5 };
    var nodes = [_]canvas.WidgetLayoutNode{ node(.{ .kind = .row }, window, null), node(.{ .kind = .button, .id = 1, .text = "\xff\x00label", .text_overflow = .clip }, .init(0, 0, 20, 20), 0), node(.{ .kind = .button, .id = 2, .text = "\xff\x00label" }, .init(0, 0, 20, 20), 0) };
    for (edges) |extent| for (0..32) |flags| {
        nodes[1].frame = .init(390, 280, if (flags & 1 != 0) -extent else extent, extent);
        nodes[2].frame = .init(395, 285, extent, extent);
        nodes[0].widget.opacity = if (flags & 2 != 0) 0 else 1;
        nodes[1].widget.transform = if (flags & 4 != 0) .translate(0.00001, 0) else .{};
        nodes[1].widget.layer = if (flags & 8 != 0) -100 else null;
        nodes[2].widget.semantics.role = if (flags & 16 != 0) .link else .none;
        try compare(.{ .nodes = &nodes }, .{}, 64);
    };
}

test "compiled widget audits preserve paragraph and explicit newline font measurements and callback order" {
    _ = core.initialModel();
    const Provider = struct {
        const Call = struct { font: canvas.FontId, size: f32, text: [128]u8, length: usize };
        calls: std.ArrayList(Call) = .empty,
        fn width(context: ?*anyopaque, font: canvas.FontId, size: f32, text: []const u8) f32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            var copied: [128]u8 = @splat(0);
            std.debug.assert(text.len <= copied.len);
            @memcpy(copied[0..text.len], text);
            self.calls.append(std.testing.allocator, .{ .font = font, .size = size, .text = copied, .length = text.len }) catch @panic("measurement log allocation");
            return @as(f32, @floatFromInt(text.len)) * size * 0.731;
        }
    };
    var provider_state = Provider{};
    defer provider_state.calls.deinit(std.testing.allocator);
    const provider = canvas.TextMeasureProvider{ .context = &provider_state, .measure_fn = Provider.width };
    const spans = [_]canvas.TextSpan{ .{ .text = "Bold raw\xff ", .weight = .bold }, .{ .text = "and longer words\n", .italic = true }, .{ .text = "tail\x00", .monospace = true } };
    var nodes = [_]canvas.WidgetLayoutNode{ node(.{ .kind = .column }, window, null), node(.{ .kind = .text, .id = 1, .text = "\nfirst\r\n\xff\x00\n" }, .init(0, 0, 30, 20), 0), node(.{ .kind = .text, .id = 2, .spans = &spans }, .init(0, 0, 40, 20), 0), node(.{ .kind = .button, .id = 3, .text = "Control", .text_overflow = .clip }, .init(0, 0, 30, 20), 0) };
    for ([_]f32{ 1, 18, 40, 100, 320 }) |width| for (0..4) |flags| {
        nodes[1].widget.text_overflow = if (flags & 1 != 0) .clip else .ellipsis;
        nodes[2].widget.kind = if (flags & 2 != 0) .data_cell else .text;
        nodes[1].frame.width = width;
        nodes[2].frame.width = width;
        const tokens = canvas.DesignTokens{ .text_measure = &provider };
        var reference: [64]canvas.LayoutAuditFinding = undefined;
        var compiled: [64]canvas.LayoutAuditFinding = undefined;
        provider_state.calls.clearRetainingCapacity();
        canvas.bumpTextMeasureGeneration();
        const expected = canvas.auditWidgetLayout(.{ .nodes = &nodes }, window, tokens, &reference);
        const calls = try std.testing.allocator.dupe(Provider.Call, provider_state.calls.items);
        defer std.testing.allocator.free(calls);
        provider_state.calls.clearRetainingCapacity();
        canvas.bumpTextMeasureGeneration();
        const actual = try bridge.auditLayout(std.testing.allocator, core.nativeWindowPolicy, .{ .nodes = &nodes }, window, tokens, &compiled);
        try exact(expected, actual);
        try exact(@as([]const Provider.Call, calls), provider_state.calls.items);
        core.rt.frameReset();
    };
}
fn node(widget: canvas.Widget, frame: sdk.geometry.RectF, parent: ?usize) canvas.WidgetLayoutNode {
    return .{ .widget = widget, .frame = frame, .parent_index = parent, .depth = if (parent == null) 0 else 1 };
}
test "compiled widget audits preserve complete findings for every kind role size and density" {
    _ = core.initialModel();
    const labels = [_][]const u8{ "", " \t\r\n", "value", "\x00\xff\xc0\xaf", "\xc2\xa0" };
    var nodes = [_]canvas.WidgetLayoutNode{ node(.{ .kind = .row }, window, null), node(.{ .kind = .button, .id = 1 }, .init(10, 10, 16, 16), 0), node(.{ .kind = .button, .id = 2 }, .init(12, 12, 16, 16), 0) };
    for (std.enums.values(canvas.WidgetKind)) |kind| for (std.enums.values(canvas.WidgetRole)) |role| for (labels) |label| {
        nodes[1].widget.kind = kind;
        nodes[1].widget.semantics.role = role;
        nodes[1].widget.semantics.label = label;
        nodes[2].widget = nodes[1].widget;
        nodes[2].widget.id = 0xfedc_ba98_7654_3210;
        try compare(.{ .nodes = &nodes }, .{}, 8);
    };
    for (std.enums.values(canvas.WidgetKind)) |kind| for (std.enums.values(canvas.WidgetSize)) |size| for (std.enums.values(canvas.Density)) |density| {
        nodes[1].widget = .{ .kind = kind, .id = 1, .text = "Wide label\nSecond\n", .size = size, .text_overflow = .clip };
        nodes[2].widget = nodes[1].widget;
        nodes[2].widget.id = 2;
        try compare(.{ .nodes = &nodes }, .{ .density = density }, 8);
    };
}
test "compiled widget audits preserve caps true totals and the inspected node prefix" {
    _ = core.initialModel();
    const nodes = try std.testing.allocator.alloc(canvas.WidgetLayoutNode, 1030);
    defer std.testing.allocator.free(nodes);
    for (nodes, 0..) |*n, i| n.* = node(.{ .kind = if (i == 0) .stack else .button, .id = @intCast(i), .text = "" }, .init(@floatFromInt(i * 20), 0, 10, 10), if (i == 0) null else 0);
    for ([_]usize{ 0, 1, 2, 63, 64, 65, 1200 }) |capacity| try compare(.{ .nodes = nodes }, .{}, capacity);
    // The inspected prefix is capped, but its ancestor walks are not.
    nodes[1].parent_index = 1029;
    nodes[1029].widget.layout.clip_content = true;
    nodes[1029].frame = .init(0, 0, 5, 5);
    try compare(.{ .nodes = nodes }, .{}, 1200);
    nodes[1029].widget.opacity = 0;
    try compare(.{ .nodes = nodes }, .{}, 1200);
}

var invalid_case: u8 = 0;
fn malformed(request: []const u8, output: []u8) usize {
    @memset(output, 0);
    const family = request[2];
    if (request[3] & 2 != 0) {
        output[0..4].* = .{ 1, 1, 2, 0 };
        if (invalid_case != 12) return 16;
        std.mem.writeInt(u32, output[4..8], 1, .little);
        std.mem.writeInt(u32, output[8..12], 1, .little);
        std.mem.writeInt(u32, output[16..20], 3, .little); // invalid capability selector
        return 40;
    }
    output[0..4].* = .{ 1, family, 0, 0 };
    std.mem.writeInt(u32, output[4..8], 1, .little);
    std.mem.writeInt(u32, output[8..12], 1, .little);
    std.mem.writeInt(u32, output[16..20], if (family == 0) 0 else 3, .little);
    std.mem.writeInt(u32, output[20..24], 1, .little);
    std.mem.writeInt(u32, output[24..28], 0xffffffff, .little);
    if (family == 1) std.mem.writeInt(u32, output[28..32], @bitCast(@as(f32, 1)), .little);
    switch (invalid_case) {
        0 => return 0,
        1 => output[0] = 2,
        2 => output[1] = 2,
        3 => output[2] = 1,
        4 => std.mem.writeInt(u32, output[4..8], 10, .little),
        5 => std.mem.writeInt(u32, output[8..12], 1000000, .little),
        6 => std.mem.writeInt(u32, output[12..16], 1, .little),
        7 => std.mem.writeInt(u32, output[16..20], 4, .little),
        8 => std.mem.writeInt(u32, output[20..24], 2000, .little),
        9 => std.mem.writeInt(u32, output[24..28], 2000, .little),
        10 => std.mem.writeInt(u32, output[28..32], 0x7fc00000, .little),
        11 => std.mem.writeInt(u32, output[36..40], 1, .little),
        else => {},
    }
    return 40;
}
test "compiled widget audits reject invalid complete results before modifying caller storage" {
    var nodes = [_]canvas.WidgetLayoutNode{ node(.{ .kind = .row }, window, null), node(.{ .kind = .button, .id = 1 }, .init(0, 0, 10, 10), 0) };
    var a11y = [_]canvas.a11y.A11yAuditFinding{.{ .rule = .missing_label, .node_index = 999 }} ** 8;
    var layout = [_]canvas.LayoutAuditFinding{.{ .rule = .text_overflow, .node_index = 999, .overrun_x = 33 }} ** 8;
    const a = a11y;
    const b = layout;
    for (0..12) |case| {
        invalid_case = @intCast(case);
        try std.testing.expectError(error.InvalidAuditResult, bridge.auditA11y(std.testing.allocator, malformed, .{ .nodes = &nodes }, &a11y));
        try std.testing.expectError(error.InvalidAuditResult, bridge.auditLayout(std.testing.allocator, malformed, .{ .nodes = &nodes }, window, .{}, &layout));
        try exact(a, a11y);
        try exact(b, layout);
    }
    invalid_case = 12;
    try std.testing.expectError(error.InvalidAuditResult, bridge.auditLayout(std.testing.allocator, malformed, .{ .nodes = &nodes }, window, .{}, &layout));
    try exact(b, layout);
}

test "compiled widget audits propagate explicit ownership through solved layouts and public APIs" {
    _ = core.initialModel();
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const tokens = canvas.DesignTokens{ .widget_audit_policy = core.nativeWindowPolicy };
    const layout = try canvas.layoutWidgetTreeWithTokens(.{ .kind = .column, .children = &.{.{ .kind = .button, .id = 7, .frame = .init(0, 0, 10, 10) }} }, window, tokens, &nodes);
    try std.testing.expectEqual(@as(?bridge.Policy, core.nativeWindowPolicy), layout.audit_policy);
    var expected_a: [8]canvas.a11y.A11yAuditFinding = undefined;
    var actual_a: [8]canvas.a11y.A11yAuditFinding = undefined;
    var expected_l: [8]canvas.LayoutAuditFinding = undefined;
    var actual_l: [8]canvas.LayoutAuditFinding = undefined;
    var reference = layout;
    reference.audit_policy = null;
    try exact(canvas.a11y.auditWidgetA11y(reference, &expected_a), canvas.a11y.auditWidgetA11y(layout, &actual_a));
    try exact(canvas.auditWidgetLayout(reference, window, .{}, &expected_l), canvas.auditWidgetLayout(layout, window, tokens, &actual_l));
    // Tokens can explicitly select audits for a manually supplied layout.
    try exact(canvas.auditWidgetLayout(reference, window, .{}, &expected_l), canvas.auditWidgetLayout(reference, window, tokens, &actual_l));
    core.rt.frameReset();
}

const Adapter = sdk.TsUiApp(core);
fn auditView(ui: *Adapter.Ui, _: *const core.Model) Adapter.Ui.Node {
    return ui.column(.{}, .{ui.button(.{ .on_press = .increment_and_persist }, "")});
}
fn auditTokens(_: *const core.Model) canvas.DesignTokens {
    return .{ .density = .spacious };
}
test "compiled widget audits retain their owner in runtime views with custom static and model tokens" {
    const views = [_]sdk.ShellView{.{ .label = "canvas", .kind = .gpu_surface, .fill = true }};
    const windows = [_]sdk.ShellWindow{.{ .label = "main", .title = "Audits", .width = 400, .height = 300, .views = &views }};
    const scene = sdk.ShellConfig{ .windows = &windows };
    for ([_]bool{ false, true }) |dynamic| {
        const h = try sdk.TestHarness().create(std.testing.allocator, .{});
        defer h.destroy(std.testing.allocator);
        h.null_platform.gpu_surfaces = true;
        var state = Adapter.init(std.testing.allocator, .{}, .{ .name = "audit-ownership", .scene = scene, .canvas_label = "canvas", .view = auditView, .tokens = .{ .density = .compact }, .tokens_fn = if (dynamic) auditTokens else null });
        defer state.deinit();
        const app = state.app();
        try h.start(app);
        try h.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{ .label = "canvas", .size = .init(400, 300), .timestamp_ns = 1000000 } });
        for (0..2) |turn| {
            const v = &h.runtime.views[0];
            try std.testing.expectEqual(@as(?bridge.Policy, core.nativeWindowPolicy), v.widget_tokens.widget_audit_policy);
            const layout = v.widgetLayoutTree();
            try std.testing.expectEqual(@as(?bridge.Policy, core.nativeWindowPolicy), layout.audit_policy);
            try compare(layout, v.widget_tokens, 64);
            if (turn == 0) try state.dispatch(&h.runtime, state.canvas_window_id, .increment_and_persist);
        }
    }
}
test "compiled widget audits retain unsolved descendant names and borrowed raw byte storage" {
    _ = core.initialModel();
    var descendants = [_]canvas.Widget{ .{ .kind = .text, .opacity = 0, .text = "\x00\xff" }, .{ .kind = .column, .semantics = .{ .hidden = true }, .children = &.{.{ .kind = .text, .text = "concealed" }} } };
    var nodes = [_]canvas.WidgetLayoutNode{ node(.{ .kind = .row }, window, null), node(.{ .kind = .panel, .id = 0xffff_ffff_ffff_ffff, .semantics = .{ .role = .treeitem }, .children = &descendants }, .init(0, 0, 30, 30), 0) };
    for (0..4) |facts| {
        descendants[0].semantics.hidden = facts & 1 != 0;
        descendants[1].semantics.hidden = facts & 2 != 0;
        try compare(.{ .nodes = &nodes }, .{}, 8);
    }
    var plan = try bridge.Plan.init(std.testing.allocator, core.nativeWindowPolicy, .{ .nodes = &nodes }, window, .{}, 0, 8);
    defer plan.deinit();
    const frozen = try std.testing.allocator.dupe(u8, plan.request);
    defer std.testing.allocator.free(frozen);
    try plan.run();
    try std.testing.expectEqualSlices(u8, frozen, plan.request);
    const output = try std.testing.allocator.dupe(u8, plan.result[0..plan.result_length]);
    defer std.testing.allocator.free(output);
    @memset(plan.request, 0xa5);
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, output, plan.result[0..plan.result_length]);
}
