//! Layout audit rule tests: one synthetic tree per damage class pins the
//! detection semantics (finding fired, geometry named, opt-ins and
//! by-design layering respected), and the formatter tests pin the
//! teaching voice with the widget path.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const support = @import("test_support.zig");
const layout_audit = @import("layout_audit.zig");
const text_metrics = @import("text_metrics.zig");

const Widget = canvas.Widget;
const DesignTokens = canvas.DesignTokens;

fn auditTree(
    root: Widget,
    bounds: geometry.RectF,
    tokens: DesignTokens,
    nodes: []canvas.WidgetLayoutNode,
    storage: []canvas.LayoutAuditFinding,
) !canvas.LayoutAuditIssues {
    const layout = try canvas.layoutWidgetTreeWithTokens(root, bounds, tokens, nodes);
    return canvas.auditWidgetLayout(layout, bounds, tokens, storage);
}

test "plain text re-wrapping into siblings is a text-overflow finding" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const long_text = "A deliberately long heading that cannot fit on one line";
    const root = Widget{ .kind = .column, .children = &.{
        .{ .kind = .text, .id = 7, .text = long_text },
        .{ .kind = .text, .id = 8, .text = "Below" },
    } };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 120, 200), .{}, &nodes, &storage);
    try std.testing.expect(issues.total >= 1);
    try std.testing.expectEqual(canvas.LayoutAuditRuleKind.text_overflow, issues.findings[0].rule);
    // The finding names the wrapped-lines geometry, not just "too big".
    try std.testing.expect(issues.findings[0].lines > 1);
    try std.testing.expect(issues.findings[0].overrun_y > 0);
}

test "wrap=false is the clip opt-in: no finding for the same text" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const long_text = "A deliberately long heading that cannot fit on one line";
    const root = Widget{ .kind = .column, .children = &.{
        .{ .kind = .text, .id = 7, .text = long_text, .text_no_wrap = true },
        .{ .kind = .text, .id = 8, .text = "Below" },
    } };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 120, 200), .{}, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 0), issues.total);
}

test "an unbreakable run character-wraps past its single-line frame" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    // No word-break bytes: the paint-time breaker falls back to
    // character wrapping, so the damage presents as extra painted lines
    // below the single-line frame, not as a horizontal bleed.
    const root = Widget{ .kind = .column, .children = &.{
        .{ .kind = .text, .id = 7, .text = "https://example.com/an/unbreakably/long/path/segment" },
    } };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 100, 200), .{}, &nodes, &storage);
    try std.testing.expect(issues.total >= 1);
    try std.testing.expectEqual(canvas.LayoutAuditRuleKind.text_overflow, issues.findings[0].rule);
    try std.testing.expect(issues.findings[0].lines > 1);
    try std.testing.expect(issues.findings[0].overrun_y > 0);
}

test "a control narrower than its label is a text-overflow finding" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const root = Widget{ .kind = .row, .children = &.{
        .{ .kind = .button, .id = 3, .text = "Continue with the setup", .frame = geometry.RectF.init(0, 0, 60, 36) },
    } };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 400, 100), .{}, &nodes, &storage);
    try std.testing.expect(issues.total >= 1);
    try std.testing.expectEqual(canvas.LayoutAuditRuleKind.text_overflow, issues.findings[0].rule);
    try std.testing.expect(issues.findings[0].overrun_x > 0);
    // The same button at its intrinsic size is clean.
    const fitted = Widget{ .kind = .row, .children = &.{
        .{ .kind = .button, .id = 3, .text = "Continue with the setup" },
    } };
    const clean = try auditTree(fitted, geometry.RectF.init(0, 0, 400, 100), .{}, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 0), clean.total);
}

test "span paragraphs wrap by design and reserve their height: clean in a column" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const spans = [_]canvas.TextSpan{.{ .text = "A body paragraph that wraps across several lines when the column is narrow." }};
    const root = Widget{ .kind = .column, .children = &.{
        .{ .kind = .text, .id = 5, .text = spans[0].text, .spans = &spans },
        .{ .kind = .text, .id = 6, .text = "Below" },
    } };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 160, 300), .{}, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 0), issues.total);
}

test "a span paragraph squeezed below its wrapped height is a finding" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const spans = [_]canvas.TextSpan{.{ .text = "A body paragraph that wraps across several lines when the column is narrow." }};
    const root = Widget{ .kind = .column, .children = &.{
        .{ .kind = .text, .id = 5, .text = spans[0].text, .spans = &spans, .frame = geometry.RectF.init(0, 0, 0, 18) },
    } };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 160, 300), .{}, &nodes, &storage);
    try std.testing.expect(issues.total >= 1);
    try std.testing.expectEqual(canvas.LayoutAuditRuleKind.text_overflow, issues.findings[0].rule);
    try std.testing.expect(issues.findings[0].overrun_y > 0);
}

test "grid children wider than their cells are a sibling-overlap finding" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const root = Widget{ .kind = .grid, .layout = .{ .columns = 2 }, .children = &.{
        .{ .kind = .stack, .id = 1, .frame = geometry.RectF.init(0, 0, 150, 40) },
        .{ .kind = .stack, .id = 2, .frame = geometry.RectF.init(0, 0, 150, 40) },
    } };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 200, 100), .{}, &nodes, &storage);
    var overlap_found = false;
    for (issues.findings) |finding| {
        if (finding.rule == .sibling_overlap) overlap_found = true;
    }
    try std.testing.expect(overlap_found);
}

test "stacking surfaces layer children on purpose: no overlap finding" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const root = Widget{ .kind = .stack, .children = &.{
        .{ .kind = .stack, .id = 1 },
        .{ .kind = .stack, .id = 2 },
    } };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 200, 100), .{}, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 0), issues.total);
}

test "a virtual item taller than its stride overlaps the next row" {
    var nodes: [32]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const root = Widget{ .kind = .list, .layout = .{ .virtualized = true, .virtual_item_extent = 20 }, .children = &.{
        .{ .kind = .stack, .id = 1, .frame = geometry.RectF.init(0, 0, 0, 32) },
        .{ .kind = .stack, .id = 2, .frame = geometry.RectF.init(0, 0, 0, 32) },
    } };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 200, 200), .{}, &nodes, &storage);
    var overlap_found = false;
    for (issues.findings) |finding| {
        if (finding.rule == .sibling_overlap) overlap_found = true;
    }
    try std.testing.expect(overlap_found);
}

test "content wider than the window is a container-escape finding, attributed once" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const root = Widget{ .kind = .column, .children = &.{
        .{ .kind = .row, .id = 4, .frame = geometry.RectF.init(0, 0, 300, 40), .children = &.{
            .{ .kind = .stack, .id = 5, .frame = geometry.RectF.init(0, 0, 300, 40) },
        } },
    } };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 200, 100), .{}, &nodes, &storage);
    var escapes: usize = 0;
    for (issues.findings) |finding| {
        if (finding.rule == .container_escape) escapes += 1;
    }
    // The row escapes; its child (same damage one level deeper) stays quiet.
    try std.testing.expectEqual(@as(usize, 1), escapes);
}

test "scroll content taller than the viewport is the normal operating mode" {
    var nodes: [32]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const rows = [_]Widget{
        .{ .kind = .stack, .id = 1, .frame = geometry.RectF.init(0, 0, 0, 60) },
        .{ .kind = .stack, .id = 2, .frame = geometry.RectF.init(0, 60, 0, 60) },
        .{ .kind = .stack, .id = 3, .frame = geometry.RectF.init(0, 120, 0, 60) },
    };
    const root = Widget{ .kind = .scroll_view, .children = &.{
        .{ .kind = .column, .id = 9, .children = &rows },
    } };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 200, 100), .{}, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 0), issues.total);
}

test "content wider than its scroll viewport still escapes horizontally" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const root = Widget{ .kind = .scroll_view, .children = &.{
        .{ .kind = .column, .id = 9, .frame = geometry.RectF.init(0, 0, 320, 40) },
    } };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 200, 100), .{}, &nodes, &storage);
    try std.testing.expect(issues.total >= 1);
    try std.testing.expectEqual(canvas.LayoutAuditRuleKind.container_escape, issues.findings[0].rule);
    try std.testing.expect(issues.findings[0].overrun_x > 0);
    try std.testing.expectEqual(@as(f32, 0), issues.findings[0].overrun_y);
}

test "a control squeezed below the pointer floor is a hit-target finding" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const root = Widget{ .kind = .row, .children = &.{
        .{ .kind = .icon_button, .id = 11, .icon = "x", .frame = geometry.RectF.init(0, 0, 10, 10) },
    } };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 200, 100), .{}, &nodes, &storage);
    try std.testing.expect(issues.total >= 1);
    try std.testing.expectEqual(canvas.LayoutAuditRuleKind.hit_target, issues.findings[0].rule);
    try std.testing.expect(issues.findings[0].overrun_x > 0);
    try std.testing.expect(issues.findings[0].overrun_y > 0);
}

test "house control registers pass the pointer floor at every density" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const root = Widget{ .kind = .row, .layout = .{ .gap = 8, .cross_alignment = .start }, .children = &.{
        .{ .kind = .checkbox, .id = 1, .text = "Done" },
        .{ .kind = .radio, .id = 2, .text = "Choice" },
        .{ .kind = .button, .id = 3, .text = "Save", .size = .sm },
        .{ .kind = .split_divider, .id = 4 },
    } };
    for ([_]canvas.Density{ .compact, .regular, .spacious }) |density| {
        var tokens = DesignTokens{};
        tokens.density = density;
        const issues = try auditTree(root, geometry.RectF.init(0, 0, 600, 100), tokens, &nodes, &storage);
        try std.testing.expectEqual(@as(usize, 0), issues.total);
    }
}

test "hidden subtrees and anchored floating surfaces stay out of the audit" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const root = Widget{ .kind = .column, .children = &.{
        // Hidden: would otherwise re-wrap into the sibling below.
        .{ .kind = .text, .id = 7, .text = "A deliberately long heading that cannot fit on one line", .semantics = .{ .hidden = true } },
        // Anchored: floats out of flow, window-clamped by the layout pass.
        .{ .kind = .stack, .id = 8, .children = &.{
            .{ .kind = .menu_surface, .id = 9, .layout = .{ .anchor = .{} }, .children = &.{
                .{ .kind = .menu_item, .id = 10, .text = "Open" },
            } },
        } },
    } };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 120, 200), .{}, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 0), issues.total);
}

test "the injected measurement seam drives the audit (pseudo-locale expansion)" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const label = "Continue with the setup";
    const width = text_metrics.estimateTextWidth(label, 14);
    _ = width;
    // A button given exactly its intrinsic width is clean with authored
    // strings and overflows once every measured run widens 1.35x — the
    // long-content sweep point catches designs with zero slack.
    const intrinsic = canvas.intrinsicWidgetSize(.{ .kind = .button, .text = label }, .{});
    const root = Widget{ .kind = .row, .children = &.{
        .{ .kind = .button, .id = 3, .text = label, .frame = geometry.RectF.init(0, 0, intrinsic.width, intrinsic.height) },
    } };
    const clean = try auditTree(root, geometry.RectF.init(0, 0, 600, 100), .{}, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 0), clean.total);

    const Expansion = struct {
        fn measure(context: ?*anyopaque, font_id: canvas.FontId, size: f32, text: []const u8) f32 {
            _ = context;
            return text_metrics.estimateTextWidthForFont(font_id, text, size) * canvas.pseudo_locale_text_expansion;
        }
    };
    const provider = support.TextMeasureProvider{ .measure_fn = Expansion.measure };
    var tokens = DesignTokens{};
    tokens.text_measure = &provider;
    const expanded = try auditTree(root, geometry.RectF.init(0, 0, 600, 100), tokens, &nodes, &storage);
    try std.testing.expect(expanded.total >= 1);
    try std.testing.expectEqual(canvas.LayoutAuditRuleKind.text_overflow, expanded.findings[0].rule);
}

test "findings format with the widget path and the sweep geometry" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]canvas.LayoutAuditFinding = undefined;
    const root = Widget{ .kind = .column, .children = &.{
        .{ .kind = .row, .children = &.{
            .{ .kind = .button, .id = 3, .text = "Continue with the setup", .frame = geometry.RectF.init(0, 0, 60, 36) },
        } },
        .{ .kind = .text, .id = 8, .text = "Below" },
    } };
    const bounds = geometry.RectF.init(0, 0, 400, 100);
    const layout = try canvas.layoutWidgetTreeWithTokens(root, bounds, .{}, &nodes);
    const issues = canvas.auditWidgetLayout(layout, bounds, .{}, &storage);
    try std.testing.expect(issues.total >= 1);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try canvas.formatLayoutAuditFinding(layout, issues.findings[0], &writer);
    const message = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, message, "text-overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "column > row") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "button \"Continue with the setup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "(id 3)") != null);
}

test "the sweep harness passes a clean tree across the whole matrix" {
    const root = Widget{ .kind = .column, .layout = .{ .gap = 8, .cross_alignment = .start }, .children = &.{
        .{ .kind = .button, .id = 1, .text = "Save" },
        .{ .kind = .text, .id = 2, .text = "Short status" },
    } };
    try canvas.expectLayoutAuditSweepClean(std.testing.allocator, root, .{
        .min_size = geometry.SizeF.init(320, 240),
        .default_size = geometry.SizeF.init(640, 480),
    });
}

test "finding storage caps loudly with the true total" {
    var findings = layout_audit.LayoutAuditIssues{ .findings = &.{}, .total = 0 };
    _ = &findings;
    var nodes: [64]canvas.WidgetLayoutNode = undefined;
    var storage: [2]canvas.LayoutAuditFinding = undefined;
    var buttons: [8]Widget = undefined;
    for (&buttons, 0..) |*button, index| {
        button.* = .{ .kind = .icon_button, .id = @intCast(index + 1), .frame = geometry.RectF.init(0, 0, 8, 8) };
    }
    const root = Widget{ .kind = .column, .layout = .{ .gap = 4, .cross_alignment = .start }, .children = &buttons };
    const issues = try auditTree(root, geometry.RectF.init(0, 0, 200, 400), .{}, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 2), issues.findings.len);
    try std.testing.expect(issues.total > issues.findings.len);
}

