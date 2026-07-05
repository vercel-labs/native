//! Machine review of a laid-out widget tree. The audit walks the solved
//! node array (`layoutWidgetTreeWithTokens` output) and reports — with
//! widget-path precision — the classes of layout damage design review
//! keeps catching by eye:
//!
//! - `text_overflow`: text that paints past the box layout gave it. Plain
//!   `.text` leaves measure single-line but re-wrap at paint, so a
//!   width-constrained leaf paints extra lines over the content below;
//!   controls paint their label single-line with no elide, so a control
//!   narrower than its label bleeds into its neighbors. The explicit
//!   opt-in is `Widget.text_no_wrap` (`wrap="false"` in markup): "clip
//!   this to one honest line by design" — opted-in leaves are never
//!   reported. Span paragraphs wrap by design; they are reported only
//!   when their wrapped extent exceeds the frame that was reserved.
//! - `sibling_overlap`: two flow siblings of a flow container whose
//!   frames intersect. Flow layout never overlaps siblings on its own,
//!   so an intersection means explicit frame offsets/sizes or a virtual
//!   item extent smaller than the real row are fighting the container.
//!   Stacking surfaces (`widgetKindStacksChildren`), anchored floating
//!   children, and children on different paint layers are layered on
//!   purpose and exempt.
//! - `container_escape`: a widget extending past its nearest clipping
//!   scope — a scroll viewport, a `clip_content` surface, a virtualized
//!   container, or the window itself. Scroll viewports and virtualized
//!   containers scroll vertically by design, so only their horizontal
//!   axis is checked; everything else checks both axes. Only the
//!   outermost escaping widget of a subtree is reported.
//! - `hit_target`: an interactive control smaller than the minimum
//!   pointer target (`tokens.min_pointer_hit_target`, scaled by the
//!   widget's size and the density like every control metric). Split
//!   dividers (a deliberately thin grab band) and inline link hotspots
//!   (text-metric sized by convention) are exempt.
//!
//! The audit is geometry-only and deterministic: it re-uses the exact
//! measurement seam layout and paint use (`tokens.text_measure`, falling
//! back to the deterministic estimator), so what it predicts is what the
//! reference renderer inks. It allocates nothing and reads no globals —
//! fast enough to run inside every example test suite across a sweep
//! matrix of window sizes, densities, and text expansions.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const event_model = @import("events.zig");
const equality_model = @import("equality.zig");
const text_model = @import("text.zig");
const text_metrics = @import("text_metrics.zig");
const text_spans_model = @import("text_spans.zig");
const widget_tree = @import("widget_tree.zig");
const widget_layout = @import("widget_layout.zig");
const widget_metrics = @import("widget_metrics.zig");
const widget_runtime = @import("widget_runtime.zig");

const DesignTokens = token_model.DesignTokens;
const TextMeasureProvider = text_metrics.TextMeasureProvider;
const Widget = widget_model.Widget;
const WidgetKind = widget_model.WidgetKind;
const WidgetLayoutNode = event_model.WidgetLayoutNode;
const WidgetLayoutTree = widget_runtime.WidgetLayoutTree;

/// Geometry slack separating a real finding from float noise: layout
/// arithmetic is f32 and centering/fraction math produces sub-pixel
/// positions, so anything within half a point is treated as intended.
pub const layout_audit_epsilon: f32 = 0.5;

/// Wrap-simulation slack. Intrinsic sizing measures a whole run in one
/// call while the line breakers accumulate per-word measures, so an
/// exact-fit line can land one f32 ulp past its own frame (~1e-3 px) —
/// runtimes hide that under the pixel-snap wrap budget (`textWrapMaxWidth`
/// hands back up to 0.5/scale). The audit widens its simulated wrap by an
/// eighth of a point: far above accumulated float noise, below the
/// smallest real overflow (a glyph) and below the smallest runtime snap
/// budget (0.5/scale at any real scale factor), so exact-fit text stays
/// clean and genuine wraps still report.
pub const layout_audit_wrap_slack: f32 = 0.125;

/// Findings reported per audit pass. A view with more than this many
/// distinct layout defects is already unreviewable — the audit keeps the
/// first 64 with full detail and reports the true total, so the fix loop
/// still sees the damage without unbounded storage.
pub const max_layout_audit_findings: usize = 64;

/// Node capacity the sweep lays out into: the same 1024-widget ceiling
/// the runtime retains per view, so any tree a real view can mount is
/// sweepable and anything larger fails the same way it would in the app.
pub const max_layout_audit_nodes: usize = 1024;

/// Width multiplier for the long-content sweep point: measured text
/// extents grow ~1.35x, the classic German/Finnish-length expansion for
/// short English UI strings. Injected through `tokens.text_measure` — the
/// same seam platform text engines use — so intrinsic sizing, wrapping,
/// and the audit's paint predictions all see the longer content
/// coherently while string bytes (and goldens) stay untouched.
pub const pseudo_locale_text_expansion: f32 = 1.35;

pub const LayoutAuditRuleKind = enum {
    text_overflow,
    sibling_overlap,
    container_escape,
    hit_target,
};

pub const LayoutAuditFinding = struct {
    rule: LayoutAuditRuleKind,
    /// Index into `layout.nodes` of the offending widget.
    node_index: usize,
    /// The other party: overlap partner for `sibling_overlap`, the clip
    /// scope for `container_escape`; null otherwise.
    other_index: ?usize = null,
    /// Per-axis magnitude in points (0 = that axis is fine):
    /// text_overflow — how far painted text overruns the frame;
    /// sibling_overlap — the intersection extents;
    /// container_escape — the overrun past the scope;
    /// hit_target — the shortfall below the minimum target.
    overrun_x: f32 = 0,
    overrun_y: f32 = 0,
    /// Painted line count for wrapped `text_overflow` findings.
    lines: usize = 0,
};

pub const LayoutAuditIssues = struct {
    /// The findings that fit `storage` (first `max_layout_audit_findings`).
    findings: []const LayoutAuditFinding,
    /// True finding count, which may exceed `findings.len` when capped.
    total: usize = 0,
};

/// Audit a laid-out tree. `window` must be the bounds the tree was laid
/// out against (the clip scope of last resort); `tokens` must be the same
/// tokens layout ran with, or text predictions will not match paint.
pub fn auditWidgetLayout(
    layout: WidgetLayoutTree,
    window: geometry.RectF,
    tokens: DesignTokens,
    storage: []LayoutAuditFinding,
) LayoutAuditIssues {
    var sink = FindingSink{ .storage = storage };
    const node_count = @min(layout.nodes.len, max_layout_audit_nodes);

    // Escape findings attribute to the outermost offender: once a widget
    // is reported, its descendants stay quiet about the same damage.
    var escape_flagged = [_]bool{false} ** max_layout_audit_nodes;

    var index: usize = 0;
    while (index < node_count) : (index += 1) {
        const node = layout.nodes[index];
        if (!nodePainted(layout, index)) continue;
        if (nodeTransformed(layout, index)) continue;

        auditNodeTextOverflow(layout, index, tokens, &sink);
        auditNodeHitTarget(node, index, tokens, &sink);
        if (auditNodeContainerEscape(layout, index, window, &escape_flagged)) |finding| {
            sink.append(finding);
        }
        auditChildOverlap(layout, index, node_count, tokens, &sink);
    }

    return .{ .findings = sink.storage[0..sink.len], .total = sink.total };
}

const FindingSink = struct {
    storage: []LayoutAuditFinding,
    len: usize = 0,
    total: usize = 0,

    fn append(self: *FindingSink, finding: LayoutAuditFinding) void {
        self.total += 1;
        if (self.len >= self.storage.len) return;
        self.storage[self.len] = finding;
        self.len += 1;
    }
};

// ------------------------------------------------------------ visibility

/// Painted at all: a hidden or fully transparent ancestor (or self)
/// removes the subtree from the frame, so its geometry cannot mislead a
/// reviewer and the audit stays quiet about it.
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

/// A transform anywhere on the ancestor path moves painted pixels away
/// from the laid-out frames, so axis-aligned frame math would report
/// phantom geometry — transformed subtrees are out of audit scope.
fn nodeTransformed(layout: WidgetLayoutTree, node_index: usize) bool {
    var current: ?usize = node_index;
    while (current) |index| {
        if (!equality_model.affinesEqual(layout.nodes[index].widget.transform, canvas.Affine.identity())) return true;
        current = layout.nodes[index].parent_index;
    }
    return false;
}

fn frameHasArea(frame: geometry.RectF) bool {
    const normalized = frame.normalized();
    return normalized.width > layout_audit_epsilon and normalized.height > layout_audit_epsilon;
}

// --------------------------------------------------------- text overflow

fn auditNodeTextOverflow(layout: WidgetLayoutTree, node_index: usize, tokens: DesignTokens, sink: *FindingSink) void {
    const widget = layout.nodes[node_index].widget;
    const frame = layout.nodes[node_index].frame.normalized();

    if (widget.spans.len > 0 and (widget.kind == .text or widget.kind == .data_cell)) {
        return auditSpanParagraphOverflow(widget, frame, node_index, tokens, sink);
    }

    switch (widget.kind) {
        .text => auditPlainTextOverflow(widget, frame, node_index, tokens, sink),
        // Controls whose intrinsic width measures their label with the
        // same seam paint draws it with. Their labels paint single-line
        // and never elide, so a frame narrower than the intrinsic width
        // means visible truncation or bleed. (`select`, inputs, and
        // textareas are exempt: their content scrolls or is placeholder
        // text by design.)
        .button, .toggle_button => {
            if (widget.size == .icon) return;
            auditControlLabelOverflow(widget, frame, node_index, tokens, sink);
        },
        .badge, .checkbox, .radio, .switch_control, .toggle, .segmented_control, .tooltip, .menu_item, .status_bar => {
            auditControlLabelOverflow(widget, frame, node_index, tokens, sink);
        },
        // Text-leaf list items and classic (span-less) table cells paint
        // their `text` like row controls; composite list items measure
        // their children, which are audited on their own.
        .list_item => {
            if (widget.children.len > 0) return;
            auditControlLabelOverflow(widget, frame, node_index, tokens, sink);
        },
        .data_cell => auditControlLabelOverflow(widget, frame, node_index, tokens, sink),
        else => {},
    }
}

fn auditSpanParagraphOverflow(widget: Widget, frame: geometry.RectF, node_index: usize, tokens: DesignTokens, sink: *FindingSink) void {
    const content = frame.inset(widget.layout.padding).normalized();
    var runs: [text_spans_model.max_text_span_runs_per_paragraph]text_spans_model.TextSpanRun = undefined;
    const span_layout = text_spans_model.layoutTextSpans(
        widget.spans,
        widget_metrics.widgetTextSpanLayoutOptions(widget, tokens, content.width + layout_audit_wrap_slack),
        &runs,
    );
    const overrun_x = overrunPast(span_layout.size.width, content.width);
    const overrun_y = overrunPast(span_layout.size.height, content.height);
    if (overrun_x <= 0 and overrun_y <= 0) return;
    sink.append(.{
        .rule = .text_overflow,
        .node_index = node_index,
        .overrun_x = overrun_x,
        .overrun_y = overrun_y,
        .lines = span_layout.line_count,
    });
}

fn auditPlainTextOverflow(widget: Widget, frame: geometry.RectF, node_index: usize, tokens: DesignTokens, sink: *FindingSink) void {
    if (widget.text.len == 0) return;
    // The explicit opt-in: `wrap="false"` paints one line clipped to the
    // frame — truncation by design, never a finding.
    if (widget.text_no_wrap) return;

    const text_size = widget_metrics.widgetBodyTextSize(widget, tokens);
    const line_height = widget_metrics.widgetLineHeight(text_size);
    const options = text_model.TextLayoutOptions{
        .max_width = frame.width + layout_audit_wrap_slack,
        .line_height = line_height,
        .wrap = .word,
        .alignment = widget.text_alignment,
        .measure = tokens.text_measure,
    };

    // Replay the paint-time line breaker (the exact `nextTextLineEnd`
    // walk `layoutTextRun` performs) without a line buffer: the audit
    // needs counts and the widest line, not run geometry.
    var line_count: usize = 0;
    var max_line_width: f32 = 0;
    var start: usize = 0;
    while (start <= widget.text.len and widget.text.len > 0) {
        const end = text_model.nextTextLineEnd(widget.text, start, tokens.typography.font_id, text_size, options);
        line_count += 1;
        const line_width = text_metrics.measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, widget.text[start..end], text_size);
        max_line_width = @max(max_line_width, line_width);
        if (end >= widget.text.len) break;
        start = end;
        if (start < widget.text.len and widget.text[start] == '\n') start += 1;
        while (start < widget.text.len and text_model.isTextBreakByte(widget.text[start])) start += 1;
    }
    if (line_count == 0) return;

    const painted_height = @as(f32, @floatFromInt(line_count)) * line_height;
    const overrun_x = overrunPast(max_line_width, frame.width);
    const overrun_y = if (line_count > 1) overrunPast(painted_height, frame.height) else 0;
    if (overrun_x <= 0 and overrun_y <= 0) return;
    sink.append(.{
        .rule = .text_overflow,
        .node_index = node_index,
        .overrun_x = overrun_x,
        .overrun_y = overrun_y,
        .lines = line_count,
    });
}

fn auditControlLabelOverflow(widget: Widget, frame: geometry.RectF, node_index: usize, tokens: DesignTokens, sink: *FindingSink) void {
    if (widget.text.len == 0) return;
    const intrinsic = widget_layout.intrinsicWidgetSize(widget, tokens);
    const overrun_x = overrunPast(intrinsic.width, frame.width);
    if (overrun_x <= 0) return;
    sink.append(.{
        .rule = .text_overflow,
        .node_index = node_index,
        .overrun_x = overrun_x,
        .lines = 1,
    });
}

fn overrunPast(extent: f32, available: f32) f32 {
    const overrun = extent - available;
    return if (overrun > layout_audit_epsilon) overrun else 0;
}

// ------------------------------------------------------- sibling overlap

/// Containers whose children FLOW (each child owns its own slot): an
/// intersection between two of their painted flow children is damage.
/// Stacking surfaces, scroll viewports (non-virtualized: children layer
/// at the viewport box by contract), and text leaves (link hotspot
/// children share the paragraph box) are layered on purpose.
fn widgetKindFlowsChildren(widget: Widget) bool {
    return switch (widget.kind) {
        .row, .column, .grid, .data_grid, .table, .list, .tree, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group, .data_row, .list_item, .menu_surface, .dropdown_menu, .split => true,
        .scroll_view => widget.layout.virtualized,
        else => false,
    };
}

fn auditChildOverlap(layout: WidgetLayoutTree, parent_index: usize, node_count: usize, tokens: DesignTokens, sink: *FindingSink) void {
    const parent = layout.nodes[parent_index].widget;
    if (!widgetKindFlowsChildren(parent)) return;

    var first = parent_index + 1;
    while (first < node_count) : (first += 1) {
        if (!nodeIsOverlapCandidate(layout, first, parent_index)) continue;
        const first_frame = layout.nodes[first].frame.normalized();
        var second = first + 1;
        while (second < node_count) : (second += 1) {
            if (!nodeIsOverlapCandidate(layout, second, parent_index)) continue;
            if (widget_tree.widgetPaintLayer(layout.nodes[first].widget, tokens) != widget_tree.widgetPaintLayer(layout.nodes[second].widget, tokens)) continue;
            const intersection = geometry.RectF.intersection(first_frame, layout.nodes[second].frame.normalized());
            if (intersection.width <= layout_audit_epsilon or intersection.height <= layout_audit_epsilon) continue;
            sink.append(.{
                .rule = .sibling_overlap,
                .node_index = second,
                .other_index = first,
                .overrun_x = intersection.width,
                .overrun_y = intersection.height,
            });
        }
    }
}

fn nodeIsOverlapCandidate(layout: WidgetLayoutTree, node_index: usize, parent_index: usize) bool {
    const node = layout.nodes[node_index];
    if (node.parent_index != parent_index) return false;
    const widget = node.widget;
    if (widget.layout.anchor != null) return false;
    if (widget.semantics.hidden) return false;
    if (widget.opacity <= 0) return false;
    if (!equality_model.affinesEqual(widget.transform, canvas.Affine.identity())) return false;
    return frameHasArea(node.frame);
}

// ------------------------------------------------------ container escape

/// Whether this widget clips its children at paint: scroll viewports,
/// `clip_content` surfaces, and virtualized containers (their scrollable
/// child pass pushes the same frame clip a scroll viewport does).
fn widgetClipsForAudit(widget: Widget) bool {
    return widget_tree.widgetClipsContent(widget) or widget.layout.virtualized;
}

/// Whether the clip scope scrolls vertically by design, making vertical
/// overhang the normal operating mode rather than damage.
fn scopeScrollsVertically(widget: Widget) bool {
    return widget.kind == .scroll_view or widget.layout.virtualized;
}

/// Nearest ancestor whose clip bounds this node: the first clipping
/// ancestor, or the window (node 0's scope) when none clips. Anchored
/// floating widgets hoist out of every ancestor clip and are clipped by
/// the window alone, so the walk stops at an anchor boundary.
fn clipScopeIndex(layout: WidgetLayoutTree, node_index: usize) ?usize {
    if (layout.nodes[node_index].widget.layout.anchor != null) return null;
    var current = layout.nodes[node_index].parent_index;
    while (current) |index| {
        if (widgetClipsForAudit(layout.nodes[index].widget)) return index;
        if (layout.nodes[index].widget.layout.anchor != null) return null;
        current = layout.nodes[index].parent_index;
    }
    return null;
}

fn auditNodeContainerEscape(
    layout: WidgetLayoutTree,
    node_index: usize,
    window: geometry.RectF,
    escape_flagged: *[max_layout_audit_nodes]bool,
) ?LayoutAuditFinding {
    if (node_index == 0) return null;
    const node = layout.nodes[node_index];
    if (!frameHasArea(node.frame)) return null;

    const scope_index = clipScopeIndex(layout, node_index);
    const scope = if (scope_index) |index| layout.nodes[index].frame.normalized() else window.normalized();
    const vertical_checked = if (scope_index) |index| !scopeScrollsVertically(layout.nodes[index].widget) else true;

    // Attribute the escape to the outermost offender: if any ancestor
    // inside the same scope is already reported, this node's overhang is
    // the same damage seen one level deeper.
    var ancestor = node.parent_index;
    while (ancestor) |index| {
        if (scope_index != null and index == scope_index.?) break;
        if (index < max_layout_audit_nodes and escape_flagged[index]) return null;
        ancestor = layout.nodes[index].parent_index;
    }

    const frame = node.frame.normalized();
    var overrun_x: f32 = 0;
    overrun_x = @max(overrun_x, overrunPast(frame.maxX(), scope.maxX()));
    overrun_x = @max(overrun_x, overrunPast(scope.x, frame.x));
    var overrun_y: f32 = 0;
    if (vertical_checked) {
        overrun_y = @max(overrun_y, overrunPast(frame.maxY(), scope.maxY()));
        overrun_y = @max(overrun_y, overrunPast(scope.y, frame.y));
    }
    if (overrun_x <= 0 and overrun_y <= 0) return null;

    if (node_index < max_layout_audit_nodes) escape_flagged[node_index] = true;
    return .{
        .rule = .container_escape,
        .node_index = node_index,
        .other_index = scope_index,
        .overrun_x = overrun_x,
        .overrun_y = overrun_y,
    };
}

// ------------------------------------------------------------ hit target

/// The control kinds a pointer must land on directly (leaf interactive
/// controls). Containers, rows resolved through press fall-through, and
/// display-only widgets are not pointer floors. `split_divider` is
/// deliberately thin (its 9pt band is the house divider convention) and
/// inline link hotspots follow text metrics by convention; both exempt.
fn widgetKindIsPointerTarget(kind: WidgetKind) bool {
    return switch (kind) {
        .button, .toggle_button, .icon_button, .select, .combobox, .input, .text_field, .search_field, .textarea, .checkbox, .radio, .switch_control, .toggle, .slider, .menu_item, .segmented_control, .list_item => true,
        else => false,
    };
}

fn auditNodeHitTarget(node: WidgetLayoutNode, node_index: usize, tokens: DesignTokens, sink: *FindingSink) void {
    const widget = node.widget;
    if (!widgetKindIsPointerTarget(widget.kind)) return;
    if (widget.semantics.role == .link) return;
    // Zero-area frames are the parked-widget convention (surplus link
    // hotspots, degraded extra split panes): never hit-testable, so not
    // a target that could be too small.
    if (!frameHasArea(node.frame)) return;

    const floor = widget_metrics.widgetSizedDensityValue(widget, tokens, token_model.min_pointer_hit_target);
    const frame = node.frame.normalized();
    const shortfall_x = overrunPast(floor, frame.width);
    const shortfall_y = overrunPast(floor, frame.height);
    if (shortfall_x <= 0 and shortfall_y <= 0) return;
    sink.append(.{
        .rule = .hit_target,
        .node_index = node_index,
        .overrun_x = shortfall_x,
        .overrun_y = shortfall_y,
    });
}

// ------------------------------------------------------------ formatting

/// Write one finding in the teaching-error voice: the widget path, the
/// geometry, and what to change. The caller prefixes sweep-point context
/// (window size, density, text expansion) — the audit itself is one
/// deterministic pass over one layout.
pub fn formatLayoutAuditFinding(layout: WidgetLayoutTree, finding: LayoutAuditFinding, writer: *std.Io.Writer) !void {
    const node = layout.nodes[finding.node_index];
    switch (finding.rule) {
        .text_overflow => {
            try writer.print("text-overflow: ", .{});
            try writeNodePath(layout, finding.node_index, writer);
            try writeFrame(node.frame, writer);
            if (node.widget.spans.len > 0) {
                try writer.print(" wraps to {d} line(s) that overrun the reserved box by", .{finding.lines});
                try writeOverrun(finding, writer);
                try writer.print(" - the paragraph needs the width layout measured it at: let it grow, widen the container, or shorten the content", .{});
            } else if (node.widget.kind == .text) {
                if (finding.lines > 1) {
                    try writer.print(" re-wraps at paint into {d} lines, overrunning its single-line frame by", .{finding.lines});
                } else {
                    try writer.print(" paints an unbreakable run past its frame by", .{});
                }
                try writeOverrun(finding, writer);
                try writer.print(" - plain text measures single-line: make it a paragraph (wrap=\"true\") so layout reserves the wrapped height, clip to one honest line with wrap=\"false\", or give the leaf room", .{});
            } else {
                try writer.print(" needs", .{});
                try writeOverrun(finding, writer);
                try writer.print(" more than its frame for the label, which paints single-line and never elides - widen the control, shorten the label, or let a flexible sibling shrink instead", .{});
            }
        },
        .sibling_overlap => {
            try writer.print("sibling-overlap: ", .{});
            try writeNodePath(layout, finding.node_index, writer);
            try writeFrame(node.frame, writer);
            try writer.print(" overlaps its sibling ", .{});
            if (finding.other_index) |other| {
                try writeNodePath(layout, other, writer);
                try writeFrame(layout.nodes[other].frame, writer);
            }
            try writer.print(" by {d:.1}x{d:.1}px - flow siblings never overlap on their own: check explicit frame offsets/sizes, or a virtual item extent smaller than the real row", .{ finding.overrun_x, finding.overrun_y });
        },
        .container_escape => {
            try writer.print("container-escape: ", .{});
            try writeNodePath(layout, finding.node_index, writer);
            try writeFrame(node.frame, writer);
            try writer.print(" extends", .{});
            try writeOverrun(finding, writer);
            if (finding.other_index) |other| {
                try writer.print(" past its clipping {s} ", .{@tagName(layout.nodes[other].widget.kind)});
                try writeFrame(layout.nodes[other].frame, writer);
            } else {
                try writer.print(" past the window", .{});
            }
            try writer.print(" - the clipped pixels are invisible at this size: shrink or wrap the content, give siblings grow factors that fit, or raise the window's min-size floor", .{});
        },
        .hit_target => {
            try writer.print("hit-target: ", .{});
            try writeNodePath(layout, finding.node_index, writer);
            try writeFrame(node.frame, writer);
            try writer.print(" is", .{});
            try writeOverrun(finding, writer);
            try writer.print(" below the {d:.0}px minimum pointer target for its size and density - give the control its intrinsic size back (drop the squeezing width/height) or make the container large enough to hold it", .{token_model.min_pointer_hit_target});
        },
    }
}

fn writeOverrun(finding: LayoutAuditFinding, writer: *std.Io.Writer) !void {
    if (finding.overrun_x > 0) try writer.print(" {d:.1}px horizontally", .{finding.overrun_x});
    if (finding.overrun_x > 0 and finding.overrun_y > 0) try writer.print(" and", .{});
    if (finding.overrun_y > 0) try writer.print(" {d:.1}px vertically", .{finding.overrun_y});
}

fn writeFrame(frame: geometry.RectF, writer: *std.Io.Writer) !void {
    try writer.print(" ({d:.0},{d:.0} {d:.0}x{d:.0})", .{ frame.x, frame.y, frame.width, frame.height });
}

/// The widget path from the root: kind names with sibling ordinals, the
/// leaf annotated with its text/label snippet and id so the finding names
/// one concrete widget (`column > row[2] > button "7" (id 42)`).
pub fn writeNodePath(layout: WidgetLayoutTree, node_index: usize, writer: *std.Io.Writer) !void {
    var chain: [widget_layout.max_widget_depth]usize = undefined;
    var chain_len: usize = 0;
    var current: ?usize = node_index;
    while (current) |index| {
        if (chain_len >= chain.len) break;
        chain[chain_len] = index;
        chain_len += 1;
        current = layout.nodes[index].parent_index;
    }

    var position = chain_len;
    while (position > 0) {
        position -= 1;
        const index = chain[position];
        const node = layout.nodes[index];
        if (position != chain_len - 1) try writer.print(" > ", .{});
        try writer.print("{s}", .{@tagName(node.widget.kind)});
        if (node.parent_index != null) {
            const ordinal = siblingOrdinal(layout, index);
            if (ordinal) |value| try writer.print("[{d}]", .{value});
        }
    }

    const leaf = layout.nodes[node_index].widget;
    const label = if (leaf.text.len > 0) leaf.text else leaf.semantics.label;
    if (label.len > 0) {
        const snippet = label[0..snippetLength(label)];
        try writer.print(" \"{s}{s}\"", .{ snippet, if (snippet.len < label.len) "..." else "" });
    }
    if (leaf.id != 0) try writer.print(" (id {d})", .{leaf.id});
}

/// Ordinal among same-parent siblings, printed only when the parent has
/// more than one child (a sole child needs no disambiguation).
fn siblingOrdinal(layout: WidgetLayoutTree, node_index: usize) ?usize {
    const parent = layout.nodes[node_index].parent_index orelse return null;
    var ordinal: usize = 0;
    var count: usize = 0;
    for (layout.nodes, 0..) |node, index| {
        if (node.parent_index != parent) continue;
        if (index < node_index) ordinal += 1;
        count += 1;
    }
    return if (count > 1) ordinal else null;
}

/// Longest clean UTF-8 prefix of at most 24 bytes.
fn snippetLength(text: []const u8) usize {
    if (text.len <= 24) return text.len;
    var length: usize = 24;
    while (length > 0 and text_model.isUtf8ContinuationByte(text[length])) length -= 1;
    return length;
}

// ----------------------------------------------------------------- sweep

/// One cell of the sweep matrix: a window size, a density variant, and a
/// text expansion factor (1.0 = the authored strings; the pseudo-locale
/// factor widens every measured run).
pub const LayoutAuditSweepPoint = struct {
    size: geometry.SizeF,
    density: token_model.Density,
    text_expansion: f32 = 1,
};

pub const LayoutAuditSweepOptions = struct {
    /// The app's real theme tokens: density is overridden per point and
    /// text measurement is wrapped per expansion; everything else (type
    /// scale, spacing overrides) audits as the app ships it.
    tokens: DesignTokens = .{},
    /// The window's declared content min-size floor. A resizable app
    /// without a floor should declare one (the window enforces it, macOS
    /// `contentMinSize`) and sweep from it — the audit at the floor is
    /// the proof the floor is honest.
    min_size: geometry.SizeF,
    /// The declared default window size.
    default_size: geometry.SizeF,
    /// A generous desktop size; null derives 1.5x the default. Fixed-size
    /// windows pass min == default and the duplicate points collapse.
    large_size: ?geometry.SizeF = null,
    densities: []const token_model.Density = &.{ .compact, .regular, .spacious },
    text_expansions: []const f32 = &.{ 1, pseudo_locale_text_expansion },
};

/// Lay out and audit `root` across the sweep matrix, printing every
/// finding (with its sweep point) in the teaching voice and failing the
/// test when any point is dirty. Layout node storage is heap-allocated
/// (the 1024-node view ceiling is too large for a test stack frame).
pub fn expectLayoutAuditSweepClean(
    allocator: std.mem.Allocator,
    root: Widget,
    options: LayoutAuditSweepOptions,
) !void {
    const nodes = try allocator.alloc(WidgetLayoutNode, max_layout_audit_nodes);
    defer allocator.free(nodes);

    var dirty_points: usize = 0;
    const sizes = [_]geometry.SizeF{ options.min_size, options.default_size, options.large_size orelse geometry.SizeF.init(options.default_size.width * 1.5, options.default_size.height * 1.5) };
    for (sizes, 0..) |size, size_index| {
        if (duplicateSize(sizes[0..size_index], size)) continue;
        for (options.densities) |density| {
            for (options.text_expansions) |expansion| {
                const point = LayoutAuditSweepPoint{ .size = size, .density = density, .text_expansion = expansion };
                dirty_points += @intFromBool(!sweepPointClean(root, options.tokens, point, nodes));
            }
        }
    }
    if (dirty_points > 0) return error.LayoutAuditFindings;
}

fn duplicateSize(previous: []const geometry.SizeF, size: geometry.SizeF) bool {
    for (previous) |value| {
        if (value.width == size.width and value.height == size.height) return true;
    }
    return false;
}

fn sweepPointClean(root: Widget, base_tokens: DesignTokens, point: LayoutAuditSweepPoint, nodes: []WidgetLayoutNode) bool {
    var tokens = base_tokens;
    tokens.density = point.density;

    // The pseudo-locale expansion rides the injected-measurement seam, so
    // it must live through both the layout and the audit below.
    var expansion_context = ExpandedMeasureContext{ .factor = point.text_expansion, .inner = base_tokens.text_measure };
    const expansion_provider = TextMeasureProvider{ .context = &expansion_context, .measure_fn = expandedMeasureWidth };
    if (point.text_expansion != 1) tokens.text_measure = &expansion_provider;

    const bounds = geometry.RectF.init(0, 0, point.size.width, point.size.height);
    const layout = widget_runtime.layoutWidgetTreeWithTokens(root, bounds, tokens, nodes) catch |err| {
        std.debug.print("layout audit: layout failed with {s} at ", .{@errorName(err)});
        printSweepPoint(point);
        return false;
    };

    var storage: [max_layout_audit_findings]LayoutAuditFinding = undefined;
    const issues = auditWidgetLayout(layout, bounds, tokens, &storage);
    if (issues.total == 0) return true;

    std.debug.print("layout audit: {d} finding(s) at ", .{issues.total});
    printSweepPoint(point);
    for (issues.findings) |finding| {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        formatLayoutAuditFinding(layout, finding, &writer) catch {};
        std.debug.print("  - {s}\n", .{writer.buffered()});
    }
    if (issues.total > issues.findings.len) {
        std.debug.print("  ... and {d} more past the {d}-finding report cap\n", .{ issues.total - issues.findings.len, max_layout_audit_findings });
    }
    return false;
}

fn printSweepPoint(point: LayoutAuditSweepPoint) void {
    std.debug.print("{d:.0}x{d:.0}, {s} density, text expansion x{d:.2}\n", .{ point.size.width, point.size.height, @tagName(point.density), point.text_expansion });
}

const ExpandedMeasureContext = struct {
    factor: f32,
    inner: ?*const TextMeasureProvider,
};

fn expandedMeasureWidth(context: ?*anyopaque, font_id: canvas.FontId, size: f32, text: []const u8) f32 {
    const state: *const ExpandedMeasureContext = @ptrCast(@alignCast(context.?));
    return text_metrics.measureTextWidthForFont(state.inner, font_id, text, size) * state.factor;
}
