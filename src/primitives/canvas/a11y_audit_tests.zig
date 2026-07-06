//! A11y audit rule tests: one synthetic tree per damage class pins the
//! detection semantics (finding fired, exemptions respected) and the
//! formatter tests pin the teaching voice with the widget path.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const a11y_audit = @import("a11y_audit.zig");

const Widget = canvas.Widget;

fn auditTree(
    root: Widget,
    bounds: geometry.RectF,
    nodes: []canvas.WidgetLayoutNode,
    storage: []a11y_audit.A11yAuditFinding,
) !a11y_audit.A11yAuditIssues {
    const layout = try canvas.layoutWidgetTreeWithTokens(root, bounds, .{}, nodes);
    return a11y_audit.auditWidgetA11y(layout, storage);
}

const window = geometry.RectF.init(0, 0, 400, 300);

test "an unlabeled button is a missing-label finding; text or a label clears it" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]a11y_audit.A11yAuditFinding = undefined;

    const unlabeled = Widget{ .kind = .row, .children = &.{
        .{ .kind = .icon_button, .id = 3, .icon = "trash" },
    } };
    const issues = try auditTree(unlabeled, window, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 1), issues.total);
    try std.testing.expectEqual(a11y_audit.A11yAuditRuleKind.missing_label, issues.findings[0].rule);

    const labeled = Widget{ .kind = .row, .children = &.{
        .{ .kind = .icon_button, .id = 3, .icon = "trash", .semantics = .{ .label = "Delete" } },
        .{ .kind = .button, .id = 4, .text = "Save" },
    } };
    const clean = try auditTree(labeled, window, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 0), clean.total);
}

test "a text field's value is not its name; a placeholder or label is" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]a11y_audit.A11yAuditFinding = undefined;

    // A prefilled value announces content, not purpose.
    const value_only = Widget{ .kind = .row, .children = &.{
        .{ .kind = .text_field, .id = 3, .text = "already typed" },
    } };
    const issues = try auditTree(value_only, window, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 1), issues.total);
    try std.testing.expectEqual(a11y_audit.A11yAuditRuleKind.missing_label, issues.findings[0].rule);

    const named = Widget{ .kind = .row, .children = &.{
        .{ .kind = .text_field, .id = 3, .placeholder = "Search notes" },
        .{ .kind = .textarea, .id = 4, .semantics = .{ .label = "Body" } },
    } };
    const clean = try auditTree(named, window, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 0), clean.total);
}

test "row-like control roles announce their content: a treeitem row with text is named" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]a11y_audit.A11yAuditFinding = undefined;

    const named_row = Widget{ .kind = .column, .children = &.{
        .{ .kind = .panel, .id = 3, .semantics = .{ .role = .treeitem }, .children = &.{
            .{ .kind = .text, .id = 4, .text = "Documents" },
        } },
    } };
    const clean = try auditTree(named_row, window, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 0), clean.total);

    // The same row with no text anywhere announces as an unnamed row.
    const empty_row = Widget{ .kind = .column, .children = &.{
        .{ .kind = .panel, .id = 3, .semantics = .{ .role = .treeitem }, .children = &.{
            .{ .kind = .icon, .id = 4, .icon = "folder" },
        } },
    } };
    const issues = try auditTree(empty_row, window, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 1), issues.total);
    try std.testing.expectEqual(a11y_audit.A11yAuditRuleKind.missing_label, issues.findings[0].rule);
}

test "hidden and zero-area widgets never report: they are not announced" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]a11y_audit.A11yAuditFinding = undefined;

    const root = Widget{ .kind = .column, .children = &.{
        .{ .kind = .icon_button, .id = 3, .icon = "x", .semantics = .{ .hidden = true } },
        .{ .kind = .icon_button, .id = 4, .icon = "x" },
    } };
    const layout = try canvas.layoutWidgetTreeWithTokens(root, window, .{}, &nodes);
    // Park the second control the way the ENGINE parks surplus widgets
    // (surplus link hotspots, degraded split panes): a zero-area frame,
    // which is never hit-testable or focusable, so never announced.
    for (nodes[0..layout.nodes.len]) |*node| {
        if (node.widget.id == 4) node.frame = geometry.RectF.init(0, 0, 0, 32);
    }
    const issues = a11y_audit.auditWidgetA11y(layout, &storage);
    try std.testing.expectEqual(@as(usize, 0), issues.total);
}

test "identical sibling labels under one role report once per pair" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]a11y_audit.A11yAuditFinding = undefined;

    const ambiguous = Widget{ .kind = .row, .children = &.{
        .{ .kind = .button, .id = 3, .text = "Delete" },
        .{ .kind = .button, .id = 4, .text = "Delete" },
    } };
    const issues = try auditTree(ambiguous, window, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 1), issues.total);
    try std.testing.expectEqual(a11y_audit.A11yAuditRuleKind.duplicate_sibling_label, issues.findings[0].rule);
    try std.testing.expect(issues.findings[0].other_index != null);

    // The same labels under DIFFERENT parents are unambiguous (each row
    // scopes its own actions).
    const scoped = Widget{ .kind = .column, .children = &.{
        .{ .kind = .row, .children = &.{.{ .kind = .button, .id = 3, .text = "Delete" }} },
        .{ .kind = .row, .children = &.{.{ .kind = .button, .id = 4, .text = "Delete" }} },
    } };
    const clean = try auditTree(scoped, window, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 0), clean.total);
}

test "a focusable widget fully clipped out of a clipping surface is unreachable" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]a11y_audit.A11yAuditFinding = undefined;

    // A clip_content panel with a button positioned past its right edge:
    // the routing layer skips invisible frames, so Tab never lands there.
    var panel_layout = canvas.WidgetLayoutStyle{};
    panel_layout.clip_content = true;
    const root = Widget{ .kind = .column, .children = &.{
        .{ .kind = .panel, .id = 2, .layout = panel_layout, .frame = geometry.RectF.init(0, 0, 100, 100), .children = &.{
            .{ .kind = .button, .id = 3, .text = "Ghost", .frame = geometry.RectF.init(200, 10, 80, 30) },
        } },
    } };
    const issues = try auditTree(root, window, &nodes, &storage);
    try std.testing.expect(issues.total >= 1);
    var found = false;
    for (issues.findings) |finding| {
        if (finding.rule == .focus_unreachable) found = true;
    }
    try std.testing.expect(found);
}

test "content below a scroll viewport's fold is reachable by design: no finding" {
    var nodes: [32]canvas.WidgetLayoutNode = undefined;
    var storage: [8]a11y_audit.A11yAuditFinding = undefined;

    const root = Widget{ .kind = .column, .children = &.{
        .{ .kind = .scroll_view, .id = 2, .frame = geometry.RectF.init(0, 0, 400, 80), .children = &.{
            .{ .kind = .column, .children = &.{
                .{ .kind = .button, .id = 3, .text = "Visible", .frame = geometry.RectF.init(0, 0, 380, 60) },
                .{ .kind = .button, .id = 4, .text = "Below the fold", .frame = geometry.RectF.init(0, 70, 380, 60) },
                .{ .kind = .button, .id = 5, .text = "Far below", .frame = geometry.RectF.init(0, 140, 380, 60) },
            } },
        } },
    } };
    const issues = try auditTree(root, window, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 0), issues.total);
}

test "below-the-fold scroll content stays reachable through OUTER clip scopes" {
    var nodes: [32]canvas.WidgetLayoutNode = undefined;
    var storage: [8]a11y_audit.A11yAuditFinding = undefined;

    // The scroll region sits inside a clipping pane column. Rows below
    // the fold live at layout-space content offsets past BOTH frames —
    // scrolling carries them into the pane's band, so the outer clip
    // must not re-flag what the scroll scope already forgave. A row
    // past the pane's RIGHT edge stays a finding (scrolling is
    // vertical; nothing ever brings it into view).
    var pane_layout = canvas.WidgetLayoutStyle{};
    pane_layout.clip_content = true;
    const root = Widget{ .kind = .column, .id = 1, .layout = pane_layout, .frame = geometry.RectF.init(0, 0, 400, 100), .children = &.{
        .{ .kind = .scroll_view, .id = 2, .frame = geometry.RectF.init(0, 0, 400, 80), .children = &.{
            .{ .kind = .column, .children = &.{
                .{ .kind = .button, .id = 3, .text = "Visible", .frame = geometry.RectF.init(0, 0, 380, 60) },
                .{ .kind = .button, .id = 4, .text = "Past the pane's fold", .frame = geometry.RectF.init(0, 150, 380, 60) },
                .{ .kind = .button, .id = 5, .text = "Past the pane's edge", .frame = geometry.RectF.init(500, 150, 80, 30) },
            } },
        } },
    } };
    const issues = try auditTree(root, window, &nodes, &storage);
    try std.testing.expectEqual(@as(usize, 1), issues.total);
    try std.testing.expectEqual(a11y_audit.A11yAuditRuleKind.focus_unreachable, issues.findings[0].rule);
}

test "the formatter names the path, the role, and the fix" {
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    var storage: [8]a11y_audit.A11yAuditFinding = undefined;

    const root = Widget{ .kind = .row, .children = &.{
        .{ .kind = .icon_button, .id = 9, .icon = "trash" },
    } };
    const layout = try canvas.layoutWidgetTreeWithTokens(root, window, .{}, &nodes);
    const issues = a11y_audit.auditWidgetA11y(layout, &storage);
    try std.testing.expectEqual(@as(usize, 1), issues.total);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try a11y_audit.formatA11yAuditFinding(layout, issues.findings[0], &writer);
    const message = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, message, "missing-label") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "icon_button") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "semantics.label") != null);
}

test "the sweep helper is clean on a fully named tree" {
    const root = Widget{ .kind = .column, .children = &.{
        .{ .kind = .text_field, .id = 2, .placeholder = "New task" },
        .{ .kind = .row, .children = &.{
            .{ .kind = .button, .id = 3, .text = "Add" },
            .{ .kind = .icon_button, .id = 4, .icon = "x", .semantics = .{ .label = "Clear" } },
        } },
    } };
    try canvas.expectA11yAuditSweepClean(std.testing.allocator, root, .{
        .min_size = geometry.SizeF.init(320, 240),
        .default_size = geometry.SizeF.init(640, 480),
    });
}
