//! Machine review of a built widget tree's accessibility. The audit walks
//! the solved node array (`layoutWidgetTreeWithTokens` output) and
//! reports — with widget-path precision — what the markup lint cannot
//! see: builder-authored views that never pass a validator, and dynamic
//! labels that resolve empty at runtime. It judges widgets by the role
//! and label the accessibility bridges will actually announce
//! (`widget_semantics.semanticRole`/`semanticLabel`), so a finding here
//! is a real screen reader experience, not a markup technicality:
//!
//! - `missing_label`: an interactive widget (announced under a control
//!   role — button, checkbox, textbox, menuitem, ...) with no accessible
//!   name anywhere: no `semantics.label`, no visible text, no
//!   placeholder (text controls), and — for row-like controls that
//!   compose their announcement from content — no nonblank text on any
//!   descendant. A screen reader announces an unnamed control that
//!   cannot be operated blind. Zero-area frames are the parked-widget
//!   convention and stay quiet, matching the layout audit.
//! - `focus_unreachable`: a focusable widget keyboard traversal can
//!   never reach because a clipping ancestor (a `clip_content` surface,
//!   a virtualized container) has clipped it out entirely — the routing
//!   layer skips invisible frames, so Tab silently walks past it.
//!   Scroll viewports scroll vertically by design, so only horizontal
//!   full-clips count there; anchored floating widgets escape ancestor
//!   clips and are exempt, mirroring the routing layer's own walk.
//! - `duplicate_sibling_label`: two widgets announced under the same
//!   role AND the same nonblank name under one parent. A screen reader
//!   hears two identical controls with no way to tell them apart;
//!   labels that differ only visually (position, color) must differ in
//!   text too.
//!
//! Severity: every finding blocks or seriously degrades a screen reader
//! user, so the audit has one severity — a finding fails the sweep. The
//! markup lint's rubric (error when blocked, warning when degraded)
//! lives at markup level, where an author can still choose; here the
//! tree is what ships.
//!
//! The audit is deterministic, allocates nothing, and reads no globals —
//! the same shape as the layout audit (layout_audit.zig), and adopted
//! the same way: `expectA11yAuditSweepClean` in every example suite.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const event_model = @import("events.zig");
const layout_audit = @import("layout_audit.zig");
const widget_access = @import("widget_access.zig");
const widget_semantics = @import("widget_semantics.zig");
const widget_tree = @import("widget_tree.zig");
const widget_runtime = @import("widget_runtime.zig");

const DesignTokens = token_model.DesignTokens;
const Widget = widget_model.Widget;
const WidgetKind = widget_model.WidgetKind;
const WidgetRole = widget_model.WidgetRole;
const WidgetLayoutNode = event_model.WidgetLayoutNode;
const WidgetLayoutTree = widget_runtime.WidgetLayoutTree;

/// Findings reported per audit pass; same cap policy as the layout
/// audit — the first ones carry full detail, the total stays honest.
pub const max_a11y_audit_findings: usize = 64;

/// Node capacity the sweep lays out into: the runtime's own per-view
/// widget ceiling, shared with the layout audit.
pub const max_a11y_audit_nodes: usize = layout_audit.max_layout_audit_nodes;

pub const A11yAuditRuleKind = enum {
    missing_label,
    focus_unreachable,
    duplicate_sibling_label,
};

pub const A11yAuditFinding = struct {
    rule: A11yAuditRuleKind,
    /// Index into `layout.nodes` of the offending widget.
    node_index: usize,
    /// The other party: the duplicate's first sibling for
    /// `duplicate_sibling_label`, the clipping scope for
    /// `focus_unreachable`; null otherwise.
    other_index: ?usize = null,
};

pub const A11yAuditIssues = struct {
    findings: []const A11yAuditFinding,
    /// True finding count, which may exceed `findings.len` when capped.
    total: usize = 0,
};

/// Audit a laid-out tree's accessibility. `layout` must come from the
/// same build the app would mount (real model, real tokens), or dynamic
/// labels will not be the ones the bridges announce.
pub fn auditWidgetA11y(layout: WidgetLayoutTree, storage: []A11yAuditFinding) A11yAuditIssues {
    var sink = FindingSink{ .storage = storage };
    const node_count = @min(layout.nodes.len, max_a11y_audit_nodes);

    var index: usize = 0;
    while (index < node_count) : (index += 1) {
        if (!nodePainted(layout, index)) continue;
        auditMissingLabel(layout, index, &sink);
        auditFocusReachable(layout, index, &sink);
        auditDuplicateSiblingLabel(layout, index, node_count, &sink);
    }

    return .{ .findings = sink.storage[0..sink.len], .total = sink.total };
}

const FindingSink = struct {
    storage: []A11yAuditFinding,
    len: usize = 0,
    total: usize = 0,

    fn append(self: *FindingSink, finding: A11yAuditFinding) void {
        self.total += 1;
        if (self.len >= self.storage.len) return;
        self.storage[self.len] = finding;
        self.len += 1;
    }
};

/// Announced at all: hidden subtrees and fully transparent subtrees are
/// removed from both the frame and the semantic tree, so the audit stays
/// quiet about them (the semantics collector skips them the same way).
fn nodePainted(layout: WidgetLayoutTree, node_index: usize) bool {
    var current: ?usize = node_index;
    while (current) |index| {
        const widget = layout.nodes[index].widget;
        if (widget.semantics.hidden) return false;
        if (widget.opacity <= 0) return false;
        current = layout.nodes[index].parent_index;
    }
    return true;
}

fn frameHasArea(frame: geometry.RectF) bool {
    const normalized = frame.normalized();
    return normalized.width > layout_audit.layout_audit_epsilon and normalized.height > layout_audit.layout_audit_epsilon;
}

// ---------------------------------------------------------- missing label

/// Roles whose announcement is useless without a name: the control set a
/// screen reader user OPERATES. Text/status/group/image roles either
/// carry their name as content or degrade without blocking (images are
/// the markup lint's warning); progressbars are display-only.
fn roleNeedsName(role: WidgetRole) bool {
    return switch (role) {
        .button, .textbox, .checkbox, .radio, .switch_control, .slider, .menuitem, .tab, .link, .treeitem, .listitem => true,
        else => false,
    };
}

/// A name the bridges would announce from the widget itself:
/// `semantics.label`, visible text (never for text-entry kinds, where
/// `text` is the live VALUE — hearing the content does not say what to
/// type), or the placeholder on the kinds that expose one as the
/// fallback name (`widget_semantics.semanticPlaceholder`'s set).
fn widgetOwnName(widget: Widget) bool {
    if (!allBlank(widget.semantics.label)) return true;
    if (!widget_access.widgetTextInputKind(widget.kind) and !allBlank(widget.text)) return true;
    return switch (widget.kind) {
        .select, .input, .text_field, .search_field, .combobox, .textarea => !allBlank(widget.placeholder),
        else => false,
    };
}

/// Row-like control roles compose their announcement from their content:
/// a treeitem/listitem row full of text is navigable, so descendant text
/// counts as its name. Leaf control roles (a button, a checkbox) own
/// their announcement — an icon child is not a name.
fn roleAnnouncesContent(role: WidgetRole) bool {
    return switch (role) {
        .treeitem, .listitem, .tab, .link => true,
        else => false,
    };
}

fn subtreeHasText(widget: Widget) bool {
    for (widget.children) |child| {
        if (child.semantics.hidden) continue;
        if (!allBlank(child.semantics.label) or !allBlank(child.text)) return true;
        if (subtreeHasText(child)) return true;
    }
    return false;
}

fn auditMissingLabel(layout: WidgetLayoutTree, node_index: usize, sink: *FindingSink) void {
    const widget = layout.nodes[node_index].widget;
    // id 0 never reaches the semantic tree (the collector skips it), and
    // zero-area frames are the parked-widget convention.
    if (widget.id == 0) return;
    if (!frameHasArea(layout.nodes[node_index].frame)) return;

    const role = widget_semantics.semanticRole(widget);
    if (!roleNeedsName(role)) return;
    if (widgetOwnName(widget)) return;
    if (roleAnnouncesContent(role) and subtreeHasText(widget)) return;

    sink.append(.{ .rule = .missing_label, .node_index = node_index });
}

// ------------------------------------------------------ focus reachability

/// Whether this widget clips its children at paint (same predicate the
/// layout audit and the routing layer's visibility walk use).
fn widgetClipsForAudit(widget: Widget) bool {
    return widget_tree.widgetClipsContent(widget) or widget.layout.virtualized;
}

/// Scroll scopes scroll vertically by design: content below the fold is
/// reachable after a scroll, so only a horizontal full-clip counts.
fn scopeScrollsVertically(widget: Widget) bool {
    return widget.kind == .scroll_view or widget.layout.virtualized;
}

fn auditFocusReachable(layout: WidgetLayoutTree, node_index: usize, sink: *FindingSink) void {
    const node = layout.nodes[node_index];
    if (!widget_access.isFocusable(node.widget)) return;
    // Zero-area frames are parked widgets; traversal skips them by design.
    if (!frameHasArea(node.frame)) return;

    const frame = node.frame.normalized();
    var current = node_index;
    // Once the walk crosses a vertically scrolling scope, the widget's
    // layout-space y is scroll content, not screen geometry: scrolling
    // carries it into every OUTER scope's band, so only horizontal
    // full-clips count from there up (below-the-fold rows in a long
    // scroll region — windowed virtual lists included — are reachable
    // by design; a pane column clipping the scroll's frame must not
    // re-flag them).
    var scrolls_vertically = false;
    while (true) {
        // Anchored floating widgets escape every ancestor clip (the
        // routing layer keeps focus targets inside open overlays live).
        if (widget_tree.widgetIsAnchored(layout.nodes[current].widget)) return;
        const parent_index = layout.nodes[current].parent_index orelse return;
        const parent = layout.nodes[parent_index];
        if (widgetClipsForAudit(parent.widget)) {
            const scope = parent.frame.normalized();
            const outside_x = frame.maxX() <= scope.x or frame.x >= scope.maxX();
            const outside_y = frame.maxY() <= scope.y or frame.y >= scope.maxY();
            const vertical_scroll_scope = scrolls_vertically or scopeScrollsVertically(parent.widget);
            const unreachable_here = if (vertical_scroll_scope) outside_x else (outside_x or outside_y);
            if (unreachable_here) {
                sink.append(.{ .rule = .focus_unreachable, .node_index = node_index, .other_index = parent_index });
                return;
            }
        }
        if (scopeScrollsVertically(parent.widget)) scrolls_vertically = true;
        current = parent_index;
    }
}

// ------------------------------------------------- duplicate sibling label

fn auditDuplicateSiblingLabel(layout: WidgetLayoutTree, node_index: usize, node_count: usize, sink: *FindingSink) void {
    const node = layout.nodes[node_index];
    const parent_index = node.parent_index orelse return;
    const role = widget_semantics.semanticRole(node.widget);
    if (!roleNeedsName(role)) return;
    if (node.widget.id == 0) return;
    if (!frameHasArea(node.frame)) return;
    const name = announcedName(node.widget);
    if (allBlank(name)) return;

    // Report against the FIRST same-labeled sibling, and only from the
    // later node, so each duplicate pair reports once.
    var earlier = parent_index + 1;
    while (earlier < node_index and earlier < node_count) : (earlier += 1) {
        const other = layout.nodes[earlier];
        if (other.parent_index != parent_index) continue;
        if (other.widget.id == 0) continue;
        if (!nodePainted(layout, earlier)) continue;
        if (!frameHasArea(other.frame)) continue;
        if (widget_semantics.semanticRole(other.widget) != role) continue;
        if (!std.mem.eql(u8, announcedName(other.widget), name)) continue;
        sink.append(.{ .rule = .duplicate_sibling_label, .node_index = node_index, .other_index = earlier });
        return;
    }
}

fn announcedName(widget: Widget) []const u8 {
    const label = widget_semantics.semanticLabel(widget);
    if (!allBlank(label)) return label;
    return widget.placeholder;
}

fn allBlank(text: []const u8) bool {
    for (text) |byte| {
        switch (byte) {
            ' ', '\t', '\r', '\n' => {},
            else => return false,
        }
    }
    return true;
}

// ------------------------------------------------------------ formatting

/// Write one finding in the teaching-error voice: the widget path, the
/// announced role, and what to change.
pub fn formatA11yAuditFinding(layout: WidgetLayoutTree, finding: A11yAuditFinding, writer: *std.Io.Writer) !void {
    const node = layout.nodes[finding.node_index];
    switch (finding.rule) {
        .missing_label => {
            try writer.print("missing-label: ", .{});
            try layout_audit.writeNodePath(layout, finding.node_index, writer);
            try writer.print(" is announced as an unnamed {s} - a screen reader user cannot operate a control with no name; set semantics.label (label=\"...\" in markup) or give it visible text", .{@tagName(widget_semantics.semanticRole(node.widget))});
        },
        .focus_unreachable => {
            try writer.print("focus-unreachable: ", .{});
            try layout_audit.writeNodePath(layout, finding.node_index, writer);
            try writer.print(" is focusable but fully clipped out of its {s} - keyboard traversal skips invisible frames, so Tab can never reach it; unclip it, or hide it while it is out of the flow", .{if (finding.other_index) |other| @tagName(layout.nodes[other].widget.kind) else "clip scope"});
        },
        .duplicate_sibling_label => {
            try writer.print("duplicate-label: ", .{});
            try layout_audit.writeNodePath(layout, finding.node_index, writer);
            try writer.print(" and its sibling ", .{});
            if (finding.other_index) |other| try layout_audit.writeNodePath(layout, other, writer);
            try writer.print(" are both announced as \"{s}\" ({s}) - a screen reader hears two identical controls; make the labels differ in text, not just position", .{ announcedName(node.widget), @tagName(widget_semantics.semanticRole(node.widget)) });
        },
    }
}

// ----------------------------------------------------------------- sweep

pub const A11yAuditSweepOptions = struct {
    /// The app's real theme tokens, so layout (and therefore focus
    /// reachability) matches what ships.
    tokens: DesignTokens = .{},
    /// The window's declared content min-size floor.
    min_size: geometry.SizeF,
    /// The declared default window size.
    default_size: geometry.SizeF,
    /// A generous desktop size; null derives 1.5x the default.
    large_size: ?geometry.SizeF = null,
};

/// Lay out and audit `root` at the window floor, the default size, and a
/// generous size (labels do not vary with density or locale, but focus
/// reachability varies with geometry), printing every finding in the
/// teaching voice and failing the test when any point is dirty. Same
/// adoption pattern as `expectLayoutAuditSweepClean`.
pub fn expectA11yAuditSweepClean(
    allocator: std.mem.Allocator,
    root: Widget,
    options: A11yAuditSweepOptions,
) !void {
    const nodes = try allocator.alloc(WidgetLayoutNode, max_a11y_audit_nodes);
    defer allocator.free(nodes);

    var dirty_points: usize = 0;
    const sizes = [_]geometry.SizeF{ options.min_size, options.default_size, options.large_size orelse geometry.SizeF.init(options.default_size.width * 1.5, options.default_size.height * 1.5) };
    for (sizes, 0..) |size, size_index| {
        if (duplicateSize(sizes[0..size_index], size)) continue;
        dirty_points += @intFromBool(!sweepPointClean(root, options.tokens, size, nodes));
    }
    if (dirty_points > 0) return error.A11yAuditFindings;
}

fn duplicateSize(previous: []const geometry.SizeF, size: geometry.SizeF) bool {
    for (previous) |value| {
        if (value.width == size.width and value.height == size.height) return true;
    }
    return false;
}

fn sweepPointClean(root: Widget, tokens: DesignTokens, size: geometry.SizeF, nodes: []WidgetLayoutNode) bool {
    const bounds = geometry.RectF.init(0, 0, size.width, size.height);
    const layout = widget_runtime.layoutWidgetTreeWithTokens(root, bounds, tokens, nodes) catch |err| {
        std.debug.print("a11y audit: layout failed with {s} at {d:.0}x{d:.0}\n", .{ @errorName(err), size.width, size.height });
        return false;
    };

    var storage: [max_a11y_audit_findings]A11yAuditFinding = undefined;
    const issues = auditWidgetA11y(layout, &storage);
    if (issues.total == 0) return true;

    std.debug.print("a11y audit: {d} finding(s) at {d:.0}x{d:.0}\n", .{ issues.total, size.width, size.height });
    for (issues.findings) |finding| {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        formatA11yAuditFinding(layout, finding, &writer) catch {};
        std.debug.print("  - {s}\n", .{writer.buffered()});
    }
    if (issues.total > issues.findings.len) {
        std.debug.print("  ... and {d} more past the {d}-finding report cap\n", .{ issues.total - issues.findings.len, max_a11y_audit_findings });
    }
    return false;
}
