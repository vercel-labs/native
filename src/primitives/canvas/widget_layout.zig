const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_model = @import("text.zig");
const text_spans_model = @import("text_spans.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const event_model = @import("events.zig");
const widget_tree = @import("widget_tree.zig");
const widget_access = @import("widget_access.zig");
const widget_metrics = @import("widget_metrics.zig");
const widget_render = @import("widget_render.zig");

const Error = canvas.Error;
const Widget = widget_model.Widget;
const WidgetMainAlignment = widget_model.WidgetMainAlignment;
const WidgetCrossAlignment = widget_model.WidgetCrossAlignment;
const WidgetLayoutStyle = widget_model.WidgetLayoutStyle;
const WidgetLayoutNode = event_model.WidgetLayoutNode;
const DesignTokens = token_model.DesignTokens;
const virtualListRange = token_model.virtualListRange;
const measureTextWidthForFont = text_model.measureTextWidthForFont;

/// Text width for intrinsic sizing: the injected provider on `tokens` when
/// present, the deterministic estimator otherwise.
fn measuredTextWidth(tokens: DesignTokens, text: []const u8, size: f32) f32 {
    return measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, text, size);
}
const gridColumnCount = widget_tree.gridColumnCount;
const gridRowCount = widget_tree.gridRowCount;
const saturatingU32 = widget_tree.saturatingU32;
const booleanControlSelected = widget_access.booleanControlSelected;
const widgetButtonTextSize = widget_metrics.widgetButtonTextSize;
const widgetBodyTextSize = widget_metrics.widgetBodyTextSize;
const widgetLabelTextSize = widget_metrics.widgetLabelTextSize;
const widgetTypographySize = widget_metrics.widgetTypographySize;
const widgetLineHeight = widget_metrics.widgetLineHeight;
const widgetDefaultRowHeight = widget_metrics.widgetDefaultRowHeight;
const widgetButtonInset = widget_metrics.widgetButtonInset;
const widgetControlInset = widget_metrics.widgetControlInset;
const widgetSizedDensityValue = widget_metrics.widgetSizedDensityValue;
const densityValue = widget_metrics.densityValue;
const widgetControlHeight = widget_metrics.widgetControlHeight;
const widgetStatusBarPadding = widget_render.widgetStatusBarPadding;
const controlStrokeWidth = widget_render.controlStrokeWidth;
const componentControlVisualTokens = widget_render.componentControlVisualTokens;
const widgetTextSpanLayoutOptions = widget_metrics.widgetTextSpanLayoutOptions;

pub const max_widget_depth: usize = 32;

pub fn layoutWidgetDepth(
    widget: Widget,
    frame: geometry.RectF,
    parent_index: ?usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    tokens: DesignTokens,
) Error!usize {
    if (depth >= max_widget_depth) return error.WidgetDepthExceeded;
    if (len.* >= output.len) return error.WidgetLayoutListFull;

    const index = len.*;
    output[index] = .{
        .widget = widgetWithFrame(widget, frame),
        .frame = frame,
        .depth = depth,
        .parent_index = parent_index,
    };
    len.* += 1;

    const content = windowControlsClearedContent(frame.inset(widget.layout.padding), widget, tokens);
    switch (widget.kind) {
        .row, .breadcrumb, .pagination, .radio_group, .toggle_group => try layoutAxisChildren(widget.children, content, .horizontal, index, depth, output, len, widget.layout, tokens),
        // Button groups flow like rows but at their register's effective
        // gap: the detached register supplies its own inter-chip gap when
        // the author left the group's gap at 0.
        .button_group => try layoutAxisChildren(widget.children, content, .horizontal, index, depth, output, len, buttonGroupLayoutStyle(widget, tokens), tokens),
        // Tab strips flow the same way: the underline register supplies
        // its own inter-trigger gap when the author left the strip's gap
        // at 0 (the house pill container keeps its flush triggers).
        .tabs => try layoutAxisChildren(widget.children, content, .horizontal, index, depth, output, len, tabsLayoutStyle(widget, tokens), tokens),
        .column => try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout, tokens),
        // The grouped input flows vertically inside its own field chrome:
        // the text entry (grow-stretched by `Ui.inputGroup`) above the
        // accessory actions row.
        .input_group => try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout, tokens),
        .grid => if (widget.layout.virtualized)
            try layoutVirtualGridChildren(widget.children, content, index, depth, output, len, widget.value, widget.layout, tokens)
        else
            try layoutGridChildren(widget.children, content, index, depth, output, len, widget.layout.gap, widget.layout.columns, tokens),
        .data_grid, .table => if (widget.layout.virtualized)
            try layoutVirtualVerticalChildren(widget.children, content, index, depth, output, len, widget.value, widget.layout, tokens)
        else
            try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout, tokens),
        .data_row => try layoutAxisChildren(widget.children, content, .horizontal, index, depth, output, len, widget.layout, tokens),
        // A list row with custom content: children flow horizontally
        // (gap-consuming, like a row) inside the flat wash chrome, so
        // apps compose indicator/title/meta rows without reaching for
        // bordered card surfaces. Text/icon-only items stay leaves.
        .list_item => try layoutAxisChildren(widget.children, content, .horizontal, index, depth, output, len, widget.layout, tokens),
        .scroll_view => if (widget.layout.virtualized)
            try layoutVirtualVerticalChildren(widget.children, content, index, depth, output, len, widget.value, widget.layout, tokens)
        else
            try layoutScrollChildren(widget.children, content, index, depth, output, len, widget.value, tokens),
        .list => if (widget.layout.virtualized)
            try layoutVirtualVerticalChildren(widget.children, content, index, depth, output, len, widget.value, widget.layout, tokens)
        else
            try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout, tokens),
        .tree => try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout, tokens),
        .split => try layoutSplitChildren(widget, content, index, depth, output, len, tokens),
        .menu_surface, .dropdown_menu => try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout, tokens),
        .accordion => {
            // Disclosure contract: children lay out at FULL size whether
            // or not the item is open. A closed (or still-revealing)
            // item keeps its header-only extent — the content overflows
            // the frame, unpainted and inert until revealed — so a
            // reveal never re-wraps text mid-flight: child geometry is
            // identical in both poses and only the item's own extent
            // (plus whatever stacks below it) moves.
            const child_content = accordionContentFrame(widget, content, tokens, depth);
            for (widget.children) |child| {
                if (child.layout.anchor != null) continue;
                _ = try layoutWidgetDepth(child, stackChildFrame(child_content, child), index, depth + 1, output, len, tokens);
            }
        },
        .alert => {
            // Alert children (the description under a chrome-drawn
            // title) hang past the icon column and start under the
            // title line — the standard callout grid.
            const child_content = alertContentFrame(widget, content, tokens);
            for (widget.children) |child| {
                if (child.layout.anchor != null) continue;
                _ = try layoutWidgetDepth(child, stackChildFrame(child_content, child), index, depth + 1, output, len, tokens);
            }
        },
        .stack, .bubble, .card, .dialog, .drawer, .sheet, .resizable, .panel, .popover => {
            for (widget.children) |child| {
                if (child.layout.anchor != null) continue;
                _ = try layoutWidgetDepth(child, stackChildFrame(content, child), index, depth + 1, output, len, tokens);
            }
        },
        // Span paragraphs and span-carrying table cells share the link
        // hotspot child convention (no spans or no children is a no-op).
        .text, .data_cell => try layoutTextSpanLinkChildren(widget, content, index, depth, output, len, tokens),
        .icon, .image, .avatar, .badge, .button, .toggle_button, .icon_button, .select, .input, .text_field, .search_field, .combobox, .textarea, .tooltip, .menu_item, .status_bar, .segmented_control, .checkbox, .radio, .switch_control, .toggle, .slider, .progress, .separator, .skeleton, .spinner, .chart, .split_divider, .media_surface => {},
    }

    // Anchored floating children are excluded from every flow above (they
    // consume no parent space) and positioned here instead, against this
    // widget's resolved frame and the window (the layout root's frame).
    // Leaf trigger kinds (select, button, ...) never lay out flow
    // children, but their anchored children float all the same.
    // A drag header's anchor base is trimmed clear of the stamped
    // window-control cluster exactly like its flow content box: the
    // collision scan counts anchored descendants too, so the remedy must
    // move them or the one retry is paid for nothing. Non-drag widgets
    // pass through untouched (menus and popovers anchor everywhere).
    try layoutAnchoredChildren(widget.children, windowControlsClearedContent(frame, widget, tokens), index, depth, output, len, tokens);

    return index;
}

/// Lay a drag header's content out clear of the OS window-control
/// cluster. On hidden-titlebar windows the content extends under the
/// system's control band, and the cluster sits ON the content at one
/// end — macOS's traffic lights lead, Windows' min/max/close cluster
/// trails. A `window_drag` widget declares "this row IS the titlebar",
/// so when the runtime has stamped the cluster's frame into the tokens
/// (`DesignTokens.window_controls` — only after a build proved content
/// actually collided; see `windowDragContentUnderWindowControls`), the
/// row's content box is trimmed on the cluster's side: trailing content
/// (a right-aligned status line) stops at the cluster's leading edge
/// instead of rendering under the buttons. Rows whose own padding (or
/// an app-authored chrome spacer) already clears the cluster never
/// reach the stamping step, so they lay out byte-identically.
fn windowControlsClearedContent(content: geometry.RectF, widget: Widget, tokens: DesignTokens) geometry.RectF {
    if (!widget.window_drag) return content;
    const controls = (tokens.window_controls orelse return content).normalized();
    if (controls.width <= 0 or controls.height <= 0) return content;
    if (geometry.RectF.intersection(content, controls).isEmpty()) return content;
    var cleared = content;
    if (controls.x + controls.width / 2 >= content.x + content.width / 2) {
        // Trailing cluster (Windows caption buttons): the content box
        // ends where the cluster begins.
        cleared.width = @max(0, @min(content.maxX(), controls.x) - content.x);
    } else {
        // Leading cluster (macOS traffic lights): the content box
        // starts past the cluster.
        const start = @min(content.maxX(), @max(content.x, controls.maxX()));
        cleared.width = @max(0, content.maxX() - start);
        cleared.x = start;
    }
    return cleared;
}

/// True when a laid-out tree left CONTENT of a drag header under the
/// window-control cluster (`controls`, canvas-local): the trigger for
/// the runtime's window-control reservation. Only nodes INSIDE a
/// visible `window_drag` region count — the drag row is the declared
/// titlebar, the one place the reservation can honestly re-flow — and
/// only content-bearing leaves count: text you must read, controls you
/// must see and press. Containers and full-bleed decoration (the row's
/// own background, separators, skeletons, progress strips, cover
/// images) are EXPECTED to run under the cluster, exactly like they do
/// under macOS traffic lights, so they never trigger. Text leaves are
/// judged by their PAINTED bounds, not their frame (`tokens` carries
/// the measurement seam the layout ran with), so a grow/stretch title
/// whose glyphs sit clear never pays a retry that would visibly shift
/// it — see `windowControlContentBounds`.
pub fn windowDragContentUnderWindowControls(nodes: []const WidgetLayoutNode, controls: geometry.RectF, tokens: DesignTokens) bool {
    const cluster = controls.normalized();
    if (cluster.width <= 0 or cluster.height <= 0) return false;
    const layout = LayoutNodesView{ .nodes = nodes };
    for (nodes, 0..) |node, index| {
        if (!widget_access.isWindowDragRegion(node.widget)) continue;
        if (widget_tree.isWidgetHiddenInAncestors(layout, index)) continue;
        for (nodes, 0..) |candidate, candidate_index| {
            if (candidate_index == index) continue;
            if (!widgetIsWindowControlContent(candidate.widget)) continue;
            const painted = windowControlContentBounds(candidate.widget, candidate.frame.normalized(), tokens);
            if (geometry.RectF.intersection(painted, cluster).isEmpty()) continue;
            if (widget_tree.isWidgetHiddenInAncestors(layout, candidate_index)) continue;
            if (!layoutNodeHasAncestor(nodes, candidate_index, index)) continue;
            return true;
        }
    }
    return false;
}

/// The rect the cluster test judges for one content candidate. Controls
/// (buttons, inputs, ...) are judged by their full frame — the hit
/// surface is the control, glyphs or not. Single-line text leaves are
/// judged by their ALIGNED PAINTED BOUNDS instead: the measured line
/// width (capped at the frame — elision and clipping both keep painted
/// glyphs inside it), placed per the widget's text alignment, at the
/// frame's full height. A grow/stretch title spanning the header row
/// (the centered-title pattern) has a FRAME under the cluster while its
/// inked glyphs sit well clear; judging the frame would trigger the
/// clearance retry, and the remedy's trimmed content box would then
/// visibly shift the very title it exists to protect. Span paragraphs
/// wrap and explicit newlines stack lines with per-line extents; drag
/// headers are practically single-line, so anything that can break
/// keeps the conservative frame test.
fn windowControlContentBounds(widget: Widget, frame: geometry.RectF, tokens: DesignTokens) geometry.RectF {
    if (widget.kind != .text) return frame;
    if (widget.spans.len > 0) return frame;
    if (std.mem.indexOfScalar(u8, widget.text, '\n') != null) return frame;
    const measured = measuredTextWidth(tokens, widget.text, widgetBodyTextSize(widget, tokens));
    const width = @min(measured, frame.width);
    const dx: f32 = switch (widget.text_alignment) {
        .start => 0,
        .center => (frame.width - width) * 0.5,
        .end => frame.width - width,
    };
    return geometry.RectF.init(frame.x + dx, frame.y, width, frame.height);
}

/// Adapter so the shared ancestor-hidden walk (which reads
/// `layout.nodes`) runs over a bare node slice.
const LayoutNodesView = struct {
    nodes: []const WidgetLayoutNode,
};

fn layoutNodeHasAncestor(nodes: []const WidgetLayoutNode, node_index: usize, ancestor_index: usize) bool {
    var current: ?usize = nodes[node_index].parent_index;
    while (current) |index| {
        if (index >= nodes.len) return false;
        if (index == ancestor_index) return true;
        current = nodes[index].parent_index;
    }
    return false;
}

/// Content the window-control cluster must never cover: readable leaves
/// and interactive controls. Deliberately exhaustive so a new widget
/// kind forces the honesty call here. Containers are transparent (their
/// CHILDREN are judged, not their frames), and decorative full-bleed
/// leaves — separators, skeletons, progress strips, images (header
/// cover art composites under the OS controls on every platform) — are
/// allowed under the cluster.
fn widgetIsWindowControlContent(widget: Widget) bool {
    return switch (widget.kind) {
        // Layout and surface containers: judged through their children.
        .stack, .row, .column, .grid, .data_grid, .table, .scroll_view, .list, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group, .accordion, .bubble, .resizable, .alert, .card, .dialog, .drawer, .sheet, .panel, .popover, .menu_surface, .dropdown_menu, .list_item, .data_row, .split, .tree, .input_group => false,
        // Full-bleed decoration: expected under the cluster. Media
        // surfaces join images here — full-bleed video/preview content
        // composites under the OS controls exactly like header cover art.
        .separator, .skeleton, .progress, .image, .split_divider, .media_surface => false,
        // A text leaf with no bytes and no spans is a hit/semantics
        // overlay, not readable content.
        .text => widget.text.len > 0 or widget.spans.len > 0,
        .data_cell, .icon, .avatar, .badge, .button, .toggle_button, .icon_button, .select, .input, .text_field, .search_field, .combobox, .textarea, .tooltip, .menu_item, .status_bar, .segmented_control, .checkbox, .radio, .switch_control, .toggle, .slider, .spinner, .chart => true,
    };
}

fn layoutAnchoredChildren(
    children: []const Widget,
    anchor_rect: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    tokens: DesignTokens,
) Error!void {
    for (children) |child| {
        const anchor = child.layout.anchor orelse continue;
        const child_frame = anchoredWidgetFrame(child, anchor, anchor_rect, output[0].frame, tokens);
        _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len, tokens);
    }
}

/// Resolved frame of an anchored floating widget: sized from its explicit
/// frame or intrinsic content (`stretch` widens to at least the anchor's
/// width), placed on the preferred side of the anchor rect — flipping to
/// the other side when it does not fit and the other side has more room —
/// with height clamped to the chosen side's space and both axes clamped
/// into the window. Pure geometry, unit-testable on its own.
pub fn anchoredWidgetFrame(
    child: Widget,
    anchor: widget_model.WidgetAnchor,
    anchor_rect: geometry.RectF,
    window_rect: geometry.RectF,
    tokens: DesignTokens,
) geometry.RectF {
    const window = window_rect.normalized();
    const anchor_frame = anchor_rect.normalized();
    const intrinsic = intrinsicWidgetSize(child, tokens);

    var width = if (child.frame.width > 0) child.frame.width else intrinsic.width;
    if (anchor.alignment == .stretch) width = @max(width, anchor_frame.width);
    width = clampIntrinsicAxis(width, child.layout.min_size.width, child.layout.max_size.width);
    width = @min(width, window.width);

    var height = if (child.frame.height > 0) child.frame.height else intrinsic.height;
    height = clampIntrinsicAxis(height, child.layout.min_size.height, child.layout.max_size.height);

    const offset = nonNegative(anchor.offset);
    const space_below = window.maxY() - anchor_frame.maxY() - offset;
    const space_above = anchor_frame.y - window.y - offset;
    const preferred_space = switch (anchor.placement) {
        .below => space_below,
        .above => space_above,
    };
    const other_space = switch (anchor.placement) {
        .below => space_above,
        .above => space_below,
    };
    const flipped = height > preferred_space and other_space > preferred_space;
    const below = (anchor.placement == .below) != flipped;
    const side_space = @max(0, if (below) space_below else space_above);
    height = @min(height, side_space);

    const y = if (below) anchor_frame.maxY() + offset else anchor_frame.y - offset - height;
    var x = switch (anchor.alignment) {
        .start, .stretch => anchor_frame.x,
        .end => anchor_frame.maxX() - width,
    };
    x = std.math.clamp(x, window.x, @max(window.x, window.maxX() - width));
    const clamped_y = std.math.clamp(y, window.y, @max(window.y, window.maxY() - height));
    return geometry.RectF.init(x, clamped_y, width, height);
}

const LayoutAxis = enum {
    horizontal,
    vertical,
};

/// A button group's effective inter-member gap: the author's stated gap
/// always wins; a gap left at 0 means "the register decides" — attached
/// segments (0) under the house `.segmented` register, the pack's
/// `button_group_gap` metric under `.detached`. The default metric is 0,
/// so no-pack layout is unchanged by construction.
pub fn buttonGroupGap(widget: Widget, tokens: DesignTokens) f32 {
    const gap = nonNegative(widget.layout.gap);
    if (gap > 0 or tokens.controls.button_group_style != .detached) return gap;
    return nonNegative(tokens.metrics.button_group_gap);
}

/// The group's layout style with the register's effective gap applied —
/// what `layoutAxisChildren` receives for `.button_group` parents.
fn buttonGroupLayoutStyle(widget: Widget, tokens: DesignTokens) WidgetLayoutStyle {
    var style = widget.layout;
    style.gap = buttonGroupGap(widget, tokens);
    return style;
}

/// A tab strip's effective inter-trigger gap: the author's stated gap
/// always wins; a gap left at 0 means "the register decides" — flush
/// triggers (0) inside the house `.pill` container, the pack's
/// `tabs_gap` metric under `.underline`. The default metric is 0, so
/// no-pack layout is unchanged by construction.
pub fn tabsGap(widget: Widget, tokens: DesignTokens) f32 {
    const gap = nonNegative(widget.layout.gap);
    if (gap > 0 or tokens.controls.tabs_indicator != .underline) return gap;
    return nonNegative(tokens.metrics.tabs_gap);
}

/// The strip's layout style with the register's effective gap applied —
/// what `layoutAxisChildren` receives for `.tabs` parents.
fn tabsLayoutStyle(widget: Widget, tokens: DesignTokens) WidgetLayoutStyle {
    var style = widget.layout;
    style.gap = tabsGap(widget, tokens);
    return style;
}

fn layoutAxisChildren(
    children: []const Widget,
    content: geometry.RectF,
    axis: LayoutAxis,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    style: WidgetLayoutStyle,
    tokens: DesignTokens,
) Error!void {
    // Anchored floating children take no flow slot: they are skipped in
    // every pass here (measurement, gap counting, placement) and laid out
    // by `layoutAnchoredChildren` against the parent's frame instead.
    var flow_count: usize = 0;
    for (children) |child| {
        if (child.layout.anchor == null) flow_count += 1;
    }
    if (flow_count == 0) return;

    const available_extent = switch (axis) {
        .horizontal => content.width,
        .vertical => content.height,
    };
    const cross_extent = switch (axis) {
        .horizontal => content.height,
        .vertical => content.width,
    };
    const clamped_gap = nonNegative(style.gap);
    const total_gap = clamped_gap * @as(f32, @floatFromInt(flow_count - 1));
    var fixed_extent: f32 = 0;
    var grow_total: f32 = 0;
    for (children) |child| {
        if (child.layout.anchor != null) continue;
        const grow = nonNegative(child.layout.grow);
        if (grow > 0) {
            grow_total += grow;
        } else {
            // The bubble thread fraction binds on a row's main axis
            // (the child's width): a hug-sized bubble measures at most
            // 80% of the row, so a spacer beside it keeps real share
            // and a long message wraps instead of overflowing.
            fixed_extent += mainExtentWithBubbleCap(child, axis, available_extent, preferredMainExtentInCross(child, axis, cross_extent, style.cross_alignment, tokens));
        }
    }

    const remaining = @max(0, available_extent - fixed_extent - total_gap);
    const assigned_extent = assignedAxisChildrenExtent(children, axis, fixed_extent, grow_total, remaining);
    const used_extent = assigned_extent + total_gap;
    if (axisLayoutOverflow(available_extent, used_extent)) |overflow| {
        logAxisChildrenOverflow(output, parent_index, axis, available_extent, used_extent, overflow);
    }
    const free_extent = @max(0, available_extent - used_extent);
    var child_gap = clamped_gap;
    if (style.main_alignment == .space_between and flow_count > 1) {
        child_gap += free_extent / @as(f32, @floatFromInt(flow_count - 1));
    }
    var cursor: f32 = switch (axis) {
        .horizontal => content.x,
        .vertical => content.y,
    } + mainAxisAlignmentOffset(style.main_alignment, free_extent);

    for (children) |child| {
        if (child.layout.anchor != null) continue;
        const grow = nonNegative(child.layout.grow);
        const main_extent = if (grow > 0 and grow_total > 0)
            clampMainExtent(child, axis, remaining * grow / grow_total)
        else
            mainExtentWithBubbleCap(child, axis, available_extent, preferredMainExtentInCross(child, axis, cross_extent, style.cross_alignment, tokens));
        const cross = preferredCrossExtent(child, axis, cross_extent, style.cross_alignment, tokens);
        const cross_origin = alignedCrossAxisOrigin(content, axis, cross_extent, cross, child, style.cross_alignment);
        const child_frame = switch (axis) {
            .horizontal => geometry.RectF.init(cursor, cross_origin, main_extent, cross),
            .vertical => geometry.RectF.init(cross_origin, cursor, cross, main_extent),
        };
        _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len, tokens);
        cursor += main_extent + child_gap;
    }
}

/// Tolerance separating real layout overflow from float noise.
pub const axis_layout_overflow_epsilon: f32 = 0.5;

/// Positive overflow of the children's assigned extent past the
/// container's content extent, or null when everything fits. Grow
/// children participate with their min-size floors, fixed children with
/// their preferred (intrinsic or explicit) extents — exactly the floors
/// `layoutAxisChildren` cannot shrink below.
pub fn axisLayoutOverflow(available_extent: f32, used_extent: f32) ?f32 {
    const overflow = used_extent - available_extent;
    if (overflow <= axis_layout_overflow_epsilon) return null;
    return overflow;
}

const layout_log = std.log.scoped(.zero_canvas_layout);

/// Test seam for the overflow diagnostic below: incremented once per
/// emitted (post-suppression) diagnostic in test builds, so regression
/// tests can assert a shape stays quiet — or still warns — without
/// scraping log output. Release and debug app builds never touch it.
pub var test_axis_overflow_diagnostics: usize = 0;

/// Whether the container at `parent_index` sits inside a vertically
/// scrolling scope: a `.scroll_view` ancestor, or a virtualized
/// container ancestor (layout-culled model-driven lists/grids). Inside
/// such a scope, content taller than the viewport is the normal
/// operating mode — the scroll exists precisely to reveal it — so the
/// vertical overflow diagnostic must stay quiet there. The walk is the
/// same rule the layout audit applies (`scopeScrollsVertically`), which
/// is why the audit was already clean on these shapes. Anchored
/// floating subtrees hoist out of every ancestor scope (window-clipped,
/// not parent-clipped), so the walk stops at an anchor boundary just
/// like the audit's clip-scope walk.
fn widgetInsideVerticalScrollScope(output: []const WidgetLayoutNode, parent_index: usize) bool {
    var current: ?usize = parent_index;
    while (current) |index| {
        const widget = output[index].widget;
        if (widget.kind == .scroll_view or widget.layout.virtualized) return true;
        if (widget.layout.anchor != null) return false;
        current = output[index].parent_index;
    }
    return false;
}

/// Debug-build diagnostic for silent flex overflow: when the children's
/// minimum extents exceed the container, the extra pixels spill past the
/// content box with no visual cue at authoring time. Logged at .debug so
/// debug app runs surface it while release builds and test runs stay
/// quiet. Two carve-outs keep it honest:
///
/// - Vertical overflow inside a vertically scrolling scope is expected,
///   never damage (see `widgetInsideVerticalScrollScope`): a tracked or
///   virtualized scroll's content wrapper is sized to the viewport and
///   its children legitimately extend past it on every rebuild, which
///   used to repeat this line hundreds of times for a perfectly correct
///   layout. Horizontal overflow still warns there — nothing scrolls
///   sideways to reveal it.
/// - The line names the concrete widget (root-first kind path, label
///   snippet, id — the same identity the layout audit prints), because
///   a bare kind like "column" is unactionable in any real tree.
fn logAxisChildrenOverflow(output: []const WidgetLayoutNode, parent_index: usize, axis: LayoutAxis, available_extent: f32, used_extent: f32, overflow: f32) void {
    if (axis == .vertical and widgetInsideVerticalScrollScope(output, parent_index)) return;
    if (builtin.is_test) test_axis_overflow_diagnostics += 1;
    if (builtin.mode != .Debug) return;
    var path_buffer: [256]u8 = undefined;
    layout_log.debug(
        "{s} children overflow the {s} axis by {d:.1}px (need {d:.1}px, have {d:.1}px): intrinsic/min sizes exceed the container - shrink the content, or give siblings grow factors or definite width/height that fit",
        .{ axisOverflowWidgetPath(&path_buffer, output, parent_index), @tagName(axis), overflow, used_extent, available_extent },
    );
}

/// The offending container's identity for the overflow diagnostic: the
/// root-first kind chain plus the container's label snippet and id
/// (`column > card > column "Inbox" (id 42)`), assembled into the
/// caller's buffer. Ancestors already have their layout nodes by the
/// time a container lays out its children, so the parent chain is
/// complete; a full audit-style path with sibling ordinals would need
/// the finished tree, which does not exist mid-layout. Truncation on a
/// deep tree keeps the prefix — the leaf id still lands via the audit.
fn axisOverflowWidgetPath(buffer: []u8, output: []const WidgetLayoutNode, parent_index: usize) []const u8 {
    var chain: [max_widget_depth]usize = undefined;
    var chain_len: usize = 0;
    var current: ?usize = parent_index;
    while (current) |index| {
        if (chain_len >= chain.len) break;
        chain[chain_len] = index;
        chain_len += 1;
        current = output[index].parent_index;
    }

    var writer = std.Io.Writer.fixed(buffer);
    var position = chain_len;
    while (position > 0) {
        position -= 1;
        if (position != chain_len - 1) writer.print(" > ", .{}) catch break;
        writer.print("{s}", .{@tagName(output[chain[position]].widget.kind)}) catch break;
    }
    const widget = output[parent_index].widget;
    const label = if (widget.text.len > 0) widget.text else widget.semantics.label;
    if (label.len > 0) {
        // Longest clean UTF-8 prefix of at most 24 bytes: never split a
        // multi-byte sequence mid-codepoint in the log line.
        var snippet_len: usize = @min(label.len, 24);
        while (snippet_len > 0 and snippet_len < label.len and text_model.isUtf8ContinuationByte(label[snippet_len])) snippet_len -= 1;
        writer.print(" \"{s}\"", .{label[0..snippet_len]}) catch {};
    }
    if (widget.id != 0) writer.print(" (id {d})", .{widget.id}) catch {};
    return writer.buffered();
}

/// Floor `value` with the widget's `min_size` for the axis and cap it at
/// `max_size` when set (0 = unbounded). Explicit author sizes write both
/// bounds, making the extent definite.
fn clampMainExtent(widget: Widget, axis: LayoutAxis, value: f32) f32 {
    return @max(minMainExtent(widget, axis), boundedByMax(value, maxMainExtent(widget, axis)));
}

fn maxMainExtent(widget: Widget, axis: LayoutAxis) f32 {
    return switch (axis) {
        .horizontal => widget.layout.max_size.width,
        .vertical => widget.layout.max_size.height,
    };
}

fn boundedByMax(value: f32, max: f32) f32 {
    return if (max > 0) @min(value, max) else value;
}

/// Main extent of a non-growing flex child, given the cross-axis space it
/// will be offered. Identical to `preferredMainExtent` unless the child's
/// subtree contains span paragraphs and the axis is vertical: those
/// reserve their wrapped height at the width they will receive, so
/// stacked markdown blocks do not overlap. Trees without spans keep the
/// classic single-pass behavior byte-for-byte.
fn preferredMainExtentInCross(
    child: Widget,
    axis: LayoutAxis,
    cross_extent: f32,
    alignment: WidgetCrossAlignment,
    tokens: DesignTokens,
) f32 {
    if (axis == .vertical and child.frame.height <= 0 and widgetSubtreeHasTextSpans(child, 0)) {
        const width = preferredCrossExtent(child, axis, cross_extent, alignment, tokens);
        return clampMainExtent(child, axis, wrappedVerticalExtentForWidth(child, width, tokens, 0));
    }
    return preferredMainExtent(child, axis, tokens);
}

/// Kinds whose `spans` field drives a span-paragraph text layout: plain
/// paragraphs and table cells (markdown tables put inline-styled runs in
/// `data_cell` widgets).
fn widgetIsSpanParagraph(widget: Widget) bool {
    return (widget.kind == .text or widget.kind == .data_cell) and widget.spans.len > 0;
}

fn widgetSubtreeHasTextSpans(widget: Widget, depth: usize) bool {
    if (depth >= max_widget_depth) return false;
    if (widgetIsSpanParagraph(widget)) return true;
    for (widget.children) |child| {
        if (widgetSubtreeHasTextSpans(child, depth + 1)) return true;
    }
    return false;
}

/// Wrapped vertical extent of a widget when it is laid out at `width`.
/// This is the width-aware twin of `intrinsicWidgetSize` that span
/// paragraphs need; it recurses through the container kinds markdown
/// content composes from and falls back to the classic intrinsic extent
/// everywhere else.
fn wrappedVerticalExtentForWidth(widget: Widget, width: f32, tokens: DesignTokens, depth: usize) f32 {
    if (depth >= max_widget_depth) return preferredMainExtent(widget, .vertical, tokens);
    if (widget.frame.height > 0) return clampMainExtent(widget, .vertical, widget.frame.height);
    const padding = widget.layout.padding;
    const inner_width = @max(0, width - padding.left - padding.right);
    const content_height: f32 = switch (widget.kind) {
        .text, .data_cell => if (widget.spans.len > 0)
            spanParagraphHeight(widget, inner_width, tokens)
        else
            return preferredMainExtent(widget, .vertical, tokens),
        .column, .list, .data_grid, .table, .menu_surface, .dropdown_menu => blk: {
            if (widget.layout.virtualized) return preferredMainExtent(widget, .vertical, tokens);
            var sum: f32 = 0;
            var flow_count: usize = 0;
            for (widget.children) |child| {
                if (child.layout.anchor != null) continue;
                // A column-direct bubble hugs up to the thread fraction
                // (the cross-extent seam), so its wrapped height must
                // measure at that same capped width.
                const child_width = if (child.frame.width > 0)
                    child.frame.width
                else if (bubbleThreadCapEligible(child))
                    bubbleThreadWidthCap(child, inner_width, @min(inner_width, intrinsicWidgetSizeDepth(child, tokens, depth + 1).width))
                else
                    inner_width;
                sum += wrappedVerticalExtentForWidth(child, child_width, tokens, depth + 1);
                flow_count += 1;
            }
            if (flow_count > 1) {
                sum += nonNegative(widget.layout.gap) * @as(f32, @floatFromInt(flow_count - 1));
            }
            break :blk sum;
        },
        .stack, .panel, .card, .bubble, .resizable, .popover => blk: {
            var max_height: f32 = 0;
            for (widget.children) |child| {
                if (child.layout.anchor != null) continue;
                const child_width = if (child.frame.width > 0) child.frame.width else inner_width;
                max_height = @max(max_height, wrappedVerticalExtentForWidth(child, child_width, tokens, depth + 1));
            }
            break :blk max_height;
        },
        // Alert children hang past the icon column and start under the
        // title line (`alertContentFrame`), so wrapped descriptions
        // measure at the indented width with the title's line reserved.
        .alert => blk: {
            const text_size = widgetBodyTextSize(widget, tokens);
            const inset = widgetControlInset(widget, tokens, tokens.spacing.lg);
            const icon_size = widgetSizedDensityValue(widget, tokens, 16);
            const text_gap = widgetControlInset(widget, tokens, tokens.spacing.md);
            const indent = if (widget.text.len > 0) icon_size + text_gap else 0;
            var max_height: f32 = 0;
            for (widget.children) |child| {
                if (child.layout.anchor != null) continue;
                const child_width = if (child.frame.width > 0) child.frame.width else @max(0, inner_width - indent);
                max_height = @max(max_height, wrappedVerticalExtentForWidth(child, child_width, tokens, depth + 1));
            }
            var content = max_height;
            if (widget.text.len > 0) {
                const title_gap = widgetControlInset(widget, tokens, tokens.spacing.xs);
                content = widgetLineHeight(text_size) + (if (max_height > 0) title_gap + max_height else 0);
            }
            // The same floor `intrinsicAlertWidgetSize` keeps, so wrapped
            // and intrinsic measurements agree for short alerts.
            const chrome_floor = @max(widgetSizedDensityValue(widget, tokens, 52), widgetLineHeight(text_size) + inset * 2);
            break :blk @max(content, chrome_floor - padding.top - padding.bottom);
        },
        // Accordion content sits below the header band; wrapped content
        // measures at the item's width so an expanded item reserves its
        // real wrapped height.
        .accordion => blk: {
            const header_height = accordionHeaderHeight(widget, tokens);
            if (!accordionChildrenVisible(widget)) break :blk header_height;
            var max_height: f32 = 0;
            for (widget.children) |child| {
                if (child.layout.anchor != null) continue;
                const child_width = if (child.frame.width > 0) child.frame.width else inner_width;
                max_height = @max(max_height, wrappedVerticalExtentForWidth(child, child_width, tokens, depth + 1));
            }
            const gap = if (max_height > 0) nonNegative(widget.layout.gap) else 0;
            break :blk header_height + gap + max_height;
        },
        .row, .data_row, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group => blk: {
            var max_height: f32 = 0;
            for (widget.children, 0..) |child, index| {
                if (child.layout.anchor != null) continue;
                max_height = @max(max_height, wrappedVerticalExtentForWidth(
                    child,
                    rowChildWidth(widget, inner_width, index, tokens),
                    tokens,
                    depth + 1,
                ));
            }
            break :blk max_height;
        },
        else => return preferredMainExtent(widget, .vertical, tokens),
    };
    return clampMainExtent(widget, .vertical, content_height + padding.top + padding.bottom);
}

/// The width the `index`-th child of a horizontal container receives —
/// the same fixed-vs-grow split `layoutAxisChildren` performs, replayed
/// so wrapped heights inside rows (blockquotes, list items) are computed
/// against real widths.
fn rowChildWidth(row: Widget, available_width: f32, index: usize, tokens: DesignTokens) f32 {
    const children = row.children;
    if (children.len == 0) return available_width;
    var flow_count: usize = 0;
    var fixed_extent: f32 = 0;
    var grow_total: f32 = 0;
    for (children) |child| {
        if (child.layout.anchor != null) continue;
        flow_count += 1;
        const grow = nonNegative(child.layout.grow);
        if (grow > 0) {
            grow_total += grow;
        } else {
            fixed_extent += bubbleThreadWidthCap(child, available_width, preferredMainExtent(child, .horizontal, tokens));
        }
    }
    if (flow_count == 0) return available_width;
    // Button groups and tab strips replay their register's effective gap
    // (see `buttonGroupGap`/`tabsGap`), matching what `layoutAxisChildren`
    // used.
    const row_gap = switch (row.kind) {
        .button_group => buttonGroupGap(row, tokens),
        .tabs => tabsGap(row, tokens),
        else => nonNegative(row.layout.gap),
    };
    const total_gap = row_gap * @as(f32, @floatFromInt(flow_count - 1));
    const remaining = @max(0, available_width - fixed_extent - total_gap);
    const child = children[index];
    const grow = nonNegative(child.layout.grow);
    if (grow > 0 and grow_total > 0) return clampMainExtent(child, .horizontal, remaining * grow / grow_total);
    // The same bubble thread cap `layoutAxisChildren` applies, replayed
    // here so wrapped heights measure at the width the bubble will
    // actually receive.
    return bubbleThreadWidthCap(child, available_width, preferredMainExtent(child, .horizontal, tokens));
}

fn spanParagraphHeight(widget: Widget, width: f32, tokens: DesignTokens) f32 {
    return text_spans_model.textSpansWrappedHeight(
        widget.spans,
        widgetTextSpanLayoutOptions(widget, tokens, width),
    );
}

/// Position a span paragraph's link hit-area children. By convention the
/// children of a `.text` widget with spans are its link hotspots, one per
/// link span in order (`Ui.paragraph` builds them). Each child gets the
/// union frame of its span's laid-out runs; surplus children collapse to
/// an empty frame (never hit-testable).
fn layoutTextSpanLinkChildren(
    widget: Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    tokens: DesignTokens,
) Error!void {
    if (widget.children.len == 0) return;
    if (widget.spans.len == 0) return;

    var runs: [text_spans_model.max_text_span_runs_per_paragraph]text_spans_model.TextSpanRun = undefined;
    const layout = text_spans_model.layoutTextSpans(
        widget.spans,
        widgetTextSpanLayoutOptions(widget, tokens, content.width),
        &runs,
    );

    var child_index: usize = 0;
    for (widget.spans, 0..) |span, span_index| {
        if (span.link.len == 0) continue;
        if (child_index >= widget.children.len) break;
        const child = widget.children[child_index];
        child_index += 1;
        if (child.layout.anchor != null) continue;
        const frame = if (text_spans_model.textSpanBounds(layout, span_index)) |bounds|
            geometry.RectF.init(content.x + bounds.x, content.y + bounds.y, bounds.width, bounds.height)
        else
            geometry.RectF.init(content.x, content.y, 0, 0);
        _ = try layoutWidgetDepth(child, frame, parent_index, depth + 1, output, len, tokens);
    }
    while (child_index < widget.children.len) : (child_index += 1) {
        if (widget.children[child_index].layout.anchor != null) continue;
        _ = try layoutWidgetDepth(widget.children[child_index], geometry.RectF.init(content.x, content.y, 0, 0), parent_index, depth + 1, output, len, tokens);
    }
}

fn assignedAxisChildrenExtent(children: []const Widget, axis: LayoutAxis, fixed_extent: f32, grow_total: f32, remaining: f32) f32 {
    if (grow_total <= 0) return fixed_extent;
    var assigned = fixed_extent;
    for (children) |child| {
        if (child.layout.anchor != null) continue;
        const grow = nonNegative(child.layout.grow);
        if (grow <= 0) continue;
        assigned += clampMainExtent(child, axis, remaining * grow / grow_total);
    }
    return assigned;
}

fn mainAxisAlignmentOffset(alignment: WidgetMainAlignment, free_extent: f32) f32 {
    return switch (alignment) {
        .start, .space_between => 0,
        .center => free_extent * 0.5,
        .end => free_extent,
    };
}

fn alignedCrossAxisOrigin(
    content: geometry.RectF,
    axis: LayoutAxis,
    available_extent: f32,
    child_extent: f32,
    child: Widget,
    alignment: WidgetCrossAlignment,
) f32 {
    const start = switch (axis) {
        .horizontal => content.y,
        .vertical => content.x,
    };
    const offset = switch (axis) {
        .horizontal => child.frame.y,
        .vertical => child.frame.x,
    };
    return start + offset + switch (alignment) {
        .stretch, .start => 0,
        // Centering keeps its promise when the child is BIGGER than the
        // band: the free extent goes negative and the overflow splits
        // evenly across both edges — a taller-than-the-row child sits
        // optically centered instead of pinning to the top and pushing
        // its whole overflow past the bottom edge.
        .center => (available_extent - child_extent) * 0.5,
        .end => @max(0, available_extent - child_extent),
    };
}

fn layoutGridChildren(
    children: []const Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    gap: f32,
    requested_columns: usize,
    tokens: DesignTokens,
) Error!void {
    if (children.len == 0) return;

    const columns = gridColumnCount(children.len, requested_columns);
    const rows = gridRowCount(children.len, columns);
    const clamped_gap = nonNegative(gap);
    const total_column_gap = clamped_gap * @as(f32, @floatFromInt(columns - 1));
    const total_row_gap = clamped_gap * @as(f32, @floatFromInt(rows - 1));
    const cell_width = if (columns > 0) @max(0, content.width - total_column_gap) / @as(f32, @floatFromInt(columns)) else 0;
    const fallback_cell_height = if (rows > 0) @max(0, content.height - total_row_gap) / @as(f32, @floatFromInt(rows)) else 0;

    for (children, 0..) |child, child_index| {
        // Anchored floating children keep their grid slot empty.
        if (child.layout.anchor != null) continue;
        const column = child_index % columns;
        const row = child_index / columns;
        const x = content.x + @as(f32, @floatFromInt(column)) * (cell_width + clamped_gap);
        const y = content.y + @as(f32, @floatFromInt(row)) * (fallback_cell_height + clamped_gap);
        const width = clampIntrinsicAxis(if (child.frame.width > 0) child.frame.width else cell_width, child.layout.min_size.width, child.layout.max_size.width);
        const height = clampIntrinsicAxis(if (child.frame.height > 0) child.frame.height else fallback_cell_height, child.layout.min_size.height, child.layout.max_size.height);
        const child_frame = geometry.RectF.init(
            x + child.frame.x,
            y + child.frame.y,
            width,
            height,
        );
        _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len, tokens);
    }
}

fn layoutVirtualGridChildren(
    children: []const Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    scroll_y: f32,
    style: WidgetLayoutStyle,
    tokens: DesignTokens,
) Error!void {
    if (children.len == 0) return;

    const columns = gridColumnCount(children.len, style.columns);
    const rows = gridRowCount(children.len, columns);
    if (columns == 0 or rows == 0) return;

    const clamped_gap = nonNegative(style.gap);
    const total_column_gap = clamped_gap * @as(f32, @floatFromInt(columns - 1));
    const cell_width = @max(0, content.width - total_column_gap) / @as(f32, @floatFromInt(columns));
    const item_extent = if (style.virtual_item_extent > 0)
        style.virtual_item_extent
    else
        preferredGridRowExtent(children, columns, tokens);
    const range = virtualListRange(.{
        .item_count = rows,
        .item_extent = item_extent,
        .item_gap = clamped_gap,
        .viewport_extent = content.height,
        .scroll_offset = scroll_y,
        .overscan = style.virtual_overscan,
    });
    output[parent_index].widget.layout.virtual_item_extent = range.item_extent;
    output[parent_index].widget.semantics.list_item_count = saturatingU32(rows);
    if (range.isEmpty()) return;

    const stride = range.item_extent + range.item_gap;
    var row = range.start_index;
    while (row < range.end_index) : (row += 1) {
        var column: usize = 0;
        while (column < columns) : (column += 1) {
            const child_index = row * columns + column;
            if (child_index >= children.len) break;
            if (children[child_index].layout.anchor != null) continue;

            var child = children[child_index];
            child.semantics.list_item_index = saturatingU32(child_index);
            child.semantics.list_item_count = saturatingU32(children.len);
            const x = content.x + @as(f32, @floatFromInt(column)) * (cell_width + clamped_gap);
            const y = content.y + @as(f32, @floatFromInt(row)) * stride - range.layout_offset + child.frame.y;
            const width = clampIntrinsicAxis(if (child.frame.width > 0) child.frame.width else cell_width, child.layout.min_size.width, child.layout.max_size.width);
            const height = clampIntrinsicAxis(if (child.frame.height > 0) child.frame.height else range.item_extent, child.layout.min_size.height, child.layout.max_size.height);
            const child_frame = geometry.RectF.init(
                x + child.frame.x,
                y,
                width,
                height,
            );
            _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len, tokens);
        }
    }
}

fn preferredGridRowExtent(children: []const Widget, columns: usize, tokens: DesignTokens) f32 {
    if (children.len == 0 or columns == 0) return 0;
    var max_height: f32 = 0;
    var index: usize = 0;
    while (index < children.len and index < columns) : (index += 1) {
        max_height = @max(max_height, preferredMainExtent(children[index], .vertical, tokens));
    }
    return max_height;
}

fn layoutScrollChildren(
    children: []const Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    scroll_y: f32,
    tokens: DesignTokens,
) Error!void {
    const scrolled_content = content.translate(geometry.OffsetF.init(0, -scroll_y));
    for (children) |child| {
        if (child.layout.anchor != null) continue;
        _ = try layoutWidgetDepth(child, stackChildFrame(scrolled_content, child), parent_index, depth + 1, output, len, tokens);
    }
}

fn layoutVirtualVerticalChildren(
    children: []const Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    scroll_y: f32,
    style: WidgetLayoutStyle,
    tokens: DesignTokens,
) Error!void {
    if (children.len == 0) return;

    // A VARIABLE-extent windowed virtual list (`virtual_total_extent >
    // 0`): the window's offset table already priced everything outside
    // the built slice — `virtual_anchor_extent` is the anchor row's
    // absolute leading edge and `virtual_total_extent` the scroll
    // content extent. Inside the window the rows stack at their
    // INTRINSIC heights (the width-aware wrapped extent) around the
    // anchor, so the content under the user's eyes never carries
    // estimate error; the measure step reads these frames back to
    // correct the table for the unmounted ranges.
    if (style.virtual_total_extent > 0 and style.virtual_item_count > 0) {
        return layoutVariableVirtualChildren(children, content, parent_index, depth, output, len, scroll_y, style, tokens);
    }

    // A windowed virtual list (`virtual_item_count > 0`) holds only the
    // built slice in `children`: `first_index` names the virtual index of
    // children[0], the declared count drives the range math (content
    // extent, scrollbar, list_item_count semantics), and each built child
    // lands at its ABSOLUTE virtual offset. The legacy contract (no
    // declared count: children are the full item set) is byte-identical.
    const first_index = style.virtual_first_index;
    const item_count = if (style.virtual_item_count > 0)
        @max(style.virtual_item_count, first_index + children.len)
    else
        children.len;
    const item_extent = if (style.virtual_item_extent > 0)
        style.virtual_item_extent
    else
        preferredMainExtent(children[0], .vertical, tokens);
    const range = virtualListRange(.{
        .item_count = item_count,
        .item_extent = item_extent,
        .item_gap = style.gap,
        .viewport_extent = content.height,
        .scroll_offset = scroll_y,
        .overscan = style.virtual_overscan,
    });
    output[parent_index].widget.layout.virtual_item_extent = range.item_extent;
    output[parent_index].widget.semantics.list_item_count = saturatingU32(item_count);
    if (range.isEmpty()) return;

    const stride = range.item_extent + range.item_gap;
    var index = @max(range.start_index, first_index);
    const end_index = @min(range.end_index, first_index + children.len);
    while (index < end_index) : (index += 1) {
        if (children[index - first_index].layout.anchor != null) continue;
        var child = children[index - first_index];
        child.semantics.list_item_index = saturatingU32(index);
        child.semantics.list_item_count = saturatingU32(item_count);
        const y = content.y + @as(f32, @floatFromInt(index)) * stride - range.layout_offset + child.frame.y;
        const width = clampIntrinsicAxis(if (child.frame.width > 0) child.frame.width else content.width, child.layout.min_size.width, child.layout.max_size.width);
        const height = clampIntrinsicAxis(if (child.frame.height > 0) child.frame.height else range.item_extent, child.layout.min_size.height, child.layout.max_size.height);
        const child_frame = geometry.RectF.init(
            content.x + child.frame.x,
            y,
            width,
            height,
        );
        _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len, tokens);
    }
}

/// The variable-extent windowed virtual list's layout: the ANCHOR row
/// (the first visible one at the offset the window was computed for)
/// lands exactly at the offset table's leading edge for it, and the
/// other built rows stack around it at their intrinsic (width-aware
/// wrapped) heights — downward below the anchor, upward above it. The
/// asymmetry is the point: rows entering the window from above are
/// priced by ESTIMATES until the measure step corrects the table, and
/// upward stacking puts that pricing error off-screen above the anchor
/// instead of displacing the content under the user's eyes. The scroll
/// offset clamps against the table's total extent — the same value the
/// scrollbar and the native driver's content size report — with the
/// uniform path's rubber-band band on the layout offset.
fn layoutVariableVirtualChildren(
    children: []const Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    scroll_y: f32,
    style: WidgetLayoutStyle,
    tokens: DesignTokens,
) Error!void {
    const first_index = style.virtual_first_index;
    const item_count = @max(style.virtual_item_count, first_index + children.len);
    const gap = nonNegative(style.gap);
    const total_extent = @max(0, style.virtual_total_extent);
    const max_offset = @max(0, total_extent - content.height);
    const raw_offset = if (std.math.isFinite(scroll_y)) scroll_y else 0;
    const layout_offset = std.math.clamp(raw_offset, -content.height, max_offset + content.height);

    output[parent_index].widget.semantics.list_item_count = saturatingU32(item_count);

    const anchor_child = std.math.clamp(style.virtual_anchor_index -| first_index, 0, children.len - 1);
    const anchor_y = content.y + @max(0, style.virtual_anchor_extent) - layout_offset;

    // Pre-pass: back the start edge out of the anchor position by the
    // above-anchor rows' intrinsic extents (the upward stack), then
    // emit every row in window order so layout-node order — which
    // semantics and hit routing walk — matches the source order.
    var y = anchor_y;
    for (children[0..anchor_child]) |child| {
        y -= variableVirtualChildExtent(child, content.width, tokens, depth) + gap;
    }
    for (children, 0..) |child, offset| {
        const height = variableVirtualChildExtent(child, content.width, tokens, depth);
        if (child.layout.anchor == null) {
            try layoutVariableVirtualChild(child, content, y, height, first_index + offset, item_count, parent_index, depth, output, len, tokens);
        }
        y += height + gap;
    }
}

fn variableVirtualChildExtent(child: Widget, width: f32, tokens: DesignTokens, depth: usize) f32 {
    return clampIntrinsicAxis(
        if (child.frame.height > 0) child.frame.height else variableVirtualRowExtent(child, width, tokens, depth + 1),
        child.layout.min_size.height,
        child.layout.max_size.height,
    );
}

fn layoutVariableVirtualChild(
    child_source: Widget,
    content: geometry.RectF,
    y: f32,
    height: f32,
    item_index: usize,
    item_count: usize,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    tokens: DesignTokens,
) Error!void {
    var child = child_source;
    child.semantics.list_item_index = saturatingU32(item_index);
    child.semantics.list_item_count = saturatingU32(item_count);
    const width = clampIntrinsicAxis(if (child.frame.width > 0) child.frame.width else content.width, child.layout.min_size.width, child.layout.max_size.width);
    const child_frame = geometry.RectF.init(
        content.x + child.frame.x,
        y + child.frame.y,
        width,
        height,
    );
    _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len, tokens);
}

/// Intrinsic height of one variable-extent virtual row at the window
/// width. `.list_item` rows measure like the `.row` family — the max of
/// their children's WIDTH-AWARE wrapped heights at their real widths —
/// because their children flow horizontally and routinely hold wrapped
/// paragraph columns. Scoped to the variable virtual path so every
/// non-virtual list_item keeps its classic intrinsic sizing
/// byte-identically.
fn variableVirtualRowExtent(child: Widget, width: f32, tokens: DesignTokens, depth: usize) f32 {
    if (child.kind != .list_item) return wrappedVerticalExtentForWidth(child, width, tokens, depth);
    if (depth >= max_widget_depth) return preferredMainExtent(child, .vertical, tokens);
    if (child.frame.height > 0) return clampMainExtent(child, .vertical, child.frame.height);
    const padding = child.layout.padding;
    const inner_width = @max(0, width - padding.left - padding.right);
    var max_height: f32 = 0;
    for (child.children, 0..) |grand, index| {
        if (grand.layout.anchor != null) continue;
        max_height = @max(max_height, wrappedVerticalExtentForWidth(
            grand,
            rowChildWidth(child, inner_width, index, tokens),
            tokens,
            depth + 1,
        ));
    }
    return clampMainExtent(child, .vertical, max_height + padding.top + padding.bottom);
}

/// Width of a split's divider band (the hit target; the painted line is
/// thinner). `layout.gap` overrides it, so markup `gap` on a split means
/// "divider band thickness" — the one flow gap a splitter has.
pub fn splitDividerExtent(widget: Widget) f32 {
    const gap = nonNegative(widget.layout.gap);
    return if (gap > 0) gap else 9;
}

/// The fraction band a split's divider may occupy, derived from the
/// panes' `min_size.width` floors against the width left for panes.
/// Degenerate spaces (mins exceed the available width) collapse to the
/// proportional midpoint so layout never inverts.
pub const SplitFractionBounds = struct {
    low: f32,
    high: f32,
};

pub fn splitFractionBounds(available: f32, first_min: f32, second_min: f32) SplitFractionBounds {
    if (available <= 0) return .{ .low = 0, .high = 1 };
    const low = std.math.clamp(nonNegative(first_min) / available, 0, 1);
    const high = std.math.clamp(1 - nonNegative(second_min) / available, 0, 1);
    if (low > high) {
        const mid = low / @max(low + (1 - high), 0.0001);
        return .{ .low = mid, .high = mid };
    }
    return .{ .low = low, .high = high };
}

/// The effective first-pane fraction a split lays out at: the authored /
/// reconciled `value` (0 = unset lays out at 0.5) clamped into the
/// panes' min-width band. Shared with the runtime's divider drag so the
/// two can never disagree about clamping.
pub fn splitEffectiveFraction(value: f32, available: f32, first_min: f32, second_min: f32) f32 {
    const base = if (!std.math.isFinite(value) or value <= 0) 0.5 else @min(value, 1);
    const bounds = splitFractionBounds(available, first_min, second_min);
    return std.math.clamp(base, bounds.low, bounds.high);
}

/// Split layout: [pane 1][divider][pane 2] along the horizontal axis.
/// The divider is the builder-synthesized `.split_divider` child; panes
/// are the remaining flow children (exactly two by the validator's
/// rule — extras degrade to zero-width frames rather than failing). The
/// first pane takes `splitEffectiveFraction` of the width left after
/// the divider band; both panes stretch the full height.
fn layoutSplitChildren(
    widget: Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    tokens: DesignTokens,
) Error!void {
    var panes: [2]?Widget = .{ null, null };
    var divider: ?Widget = null;
    var extra_start: ?usize = null;
    for (widget.children, 0..) |child, child_index| {
        if (child.layout.anchor != null) continue;
        if (child.kind == .split_divider) {
            if (divider == null) divider = child;
            continue;
        }
        if (panes[0] == null) {
            panes[0] = child;
        } else if (panes[1] == null) {
            panes[1] = child;
        } else if (extra_start == null) {
            extra_start = child_index;
        }
    }

    const divider_extent = if (divider != null) splitDividerExtent(widget) else 0;
    const available = @max(0, content.width - divider_extent);
    const first_min = if (panes[0]) |pane| nonNegative(pane.layout.min_size.width) else 0;
    const second_min = if (panes[1]) |pane| nonNegative(pane.layout.min_size.width) else 0;
    const fraction = splitEffectiveFraction(widget.value, available, first_min, second_min);
    const first_width = if (panes[1] == null) available else available * fraction;

    var cursor = content.x;
    if (panes[0]) |pane| {
        _ = try layoutWidgetDepth(pane, geometry.RectF.init(cursor, content.y, first_width, content.height), parent_index, depth + 1, output, len, tokens);
        cursor += first_width;
    }
    if (divider) |handle| {
        // The handle mirrors the EFFECTIVE fraction so keyboard steps and
        // separator semantics read the position layout actually used.
        var handle_copy = handle;
        handle_copy.value = fraction;
        _ = try layoutWidgetDepth(handle_copy, geometry.RectF.init(cursor, content.y, divider_extent, content.height), parent_index, depth + 1, output, len, tokens);
        cursor += divider_extent;
    }
    if (panes[1]) |pane| {
        const second_width = @max(0, content.maxX() - cursor);
        _ = try layoutWidgetDepth(pane, geometry.RectF.init(cursor, content.y, second_width, content.height), parent_index, depth + 1, output, len, tokens);
    }
    // Panes past the first two never happen through the builder/markup
    // (the validator enforces exactly two); raw trees degrade to empty
    // frames so the node count still matches the source tree.
    if (extra_start) |start| {
        for (widget.children[start..]) |child| {
            if (child.layout.anchor != null or child.kind == .split_divider) continue;
            _ = try layoutWidgetDepth(child, geometry.RectF.init(content.maxX(), content.y, 0, 0), parent_index, depth + 1, output, len, tokens);
        }
    }
}

/// Re-run a split node's child layout IN PLACE over an already-laid
/// node buffer: the runtime reconcile restores a runtime-owned fraction
/// after the source laid out at its own value, and the same children
/// produce the same node sequence, so only frames (and the handle's
/// mirrored value) change. `widget` must still carry its source
/// children (the reconcile runs while the app's build arena is alive);
/// callers pass the node's laid frame and depth.
pub fn relayoutSplitChildren(
    widget: Widget,
    frame: geometry.RectF,
    node_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    tokens: DesignTokens,
) Error!void {
    var len: usize = node_index + 1;
    const content = frame.inset(widget.layout.padding);
    try layoutSplitChildren(widget, content, node_index, depth, output, &len, tokens);
    try layoutAnchoredChildren(widget.children, frame, node_index, depth, output, &len, tokens);
}

/// Slide a laid split's pane boundary to `fraction` GEOMETRICALLY, over
/// an already-laid node buffer: pane frames move, the second pane's
/// subtree translates with its leading edge, and NO child re-lays —
/// every descendant keeps the wrap the source layout gave it. This is
/// the reveal-under-clip half of the split layout tween (the disclosure
/// doctrine, horizontal): the source lays panes out ONCE at the tween's
/// TARGET fraction, this slide restores the mid-flight boundary, and
/// the pane's built-in content clip crops the overflowing side while
/// the tween walks the boundary to the already-laid pose. Contrast
/// `relayoutSplitChildren`, which re-runs child layout at the restored
/// fraction — the honest shape for a settled runtime-owned fraction,
/// and exactly the per-step re-wrap a tween must never pay.
pub fn slideSplitChildren(
    frame: geometry.RectF,
    fraction: f32,
    node_index: usize,
    nodes: []WidgetLayoutNode,
) void {
    const split_depth = nodes[node_index].depth;
    var pane_indices: [2]?usize = .{ null, null };
    var divider_index: ?usize = null;
    var child = node_index + 1;
    while (child < nodes.len and nodes[child].depth > split_depth) : (child += 1) {
        if (nodes[child].parent_index != node_index) continue;
        if (nodes[child].widget.layout.anchor != null) continue;
        if (nodes[child].widget.kind == .split_divider) {
            if (divider_index == null) divider_index = child;
        } else if (pane_indices[0] == null) {
            pane_indices[0] = child;
        } else if (pane_indices[1] == null) {
            pane_indices[1] = child;
        }
    }
    const first_index = pane_indices[0] orelse return;
    const second_index = pane_indices[1] orelse return;
    const handle_index = divider_index orelse return;

    const content = frame.inset(nodes[node_index].widget.layout.padding).normalized();
    const divider_extent = nodes[handle_index].frame.width;
    const available = @max(0, content.width - divider_extent);
    const first_min = @max(0, nodes[first_index].widget.layout.min_size.width);
    const second_min = @max(0, nodes[second_index].widget.layout.min_size.width);
    // The same clamp family the runtime's drag echo applies: a
    // sub-epsilon fraction stays a sliver instead of falling into the
    // `<= 0` unset sentinel, and pane min widths bound the boundary.
    const effective = splitEffectiveFraction(@max(fraction, 0.0001), available, first_min, second_min);

    const first_width = available * effective;
    const divider_x = content.x + first_width;
    const dx = divider_x - nodes[handle_index].frame.x;

    nodes[node_index].widget.value = effective;
    nodes[handle_index].widget.value = effective;
    nodes[first_index].frame.width = first_width;
    nodes[first_index].widget.frame = nodes[first_index].frame;
    nodes[handle_index].frame.x = divider_x;
    nodes[handle_index].widget.frame = nodes[handle_index].frame;
    const second_x = divider_x + divider_extent;
    nodes[second_index].frame.x = second_x;
    nodes[second_index].frame.width = @max(0, content.maxX() - second_x);
    nodes[second_index].widget.frame = nodes[second_index].frame;
    if (dx == 0) return;
    // The second pane's content rides its leading edge: translate the
    // whole subtree (frames only — wraps and sizes stand).
    const second_depth = nodes[second_index].depth;
    var index = second_index + 1;
    while (index < nodes.len and nodes[index].depth > second_depth) : (index += 1) {
        nodes[index].frame.x += dx;
        nodes[index].widget.frame = nodes[index].frame;
    }
}

/// Widget kinds whose layout gives every child the full content box
/// (the `stackChildFrame` arm in `layoutWidgetDepth` — keep the two in
/// lockstep): children layer on top of each other, so `layout.gap` can
/// never space them. This is the source of truth for the builder's Debug
/// gap diagnostic and (via a name list kept in sync by a test in
/// ui_markup_view_tests.zig) the markup validator's stack-container list.
/// `scroll_view` and `accordion` also stack children but consume `gap`
/// (virtualized item spacing; header-to-content spacing), so they are
/// excluded on purpose.
pub fn widgetKindStacksChildren(kind: widget_model.WidgetKind) bool {
    return switch (kind) {
        .stack, .alert, .bubble, .card, .dialog, .drawer, .sheet, .resizable, .panel, .popover => true,
        else => false,
    };
}

fn stackChildFrame(content: geometry.RectF, child: Widget) geometry.RectF {
    const width = if (child.frame.width > 0) child.frame.width else content.width;
    const height = if (child.frame.height > 0) child.frame.height else content.height;
    return geometry.RectF.init(
        content.x + child.frame.x,
        content.y + child.frame.y,
        clampIntrinsicAxis(width, child.layout.min_size.width, child.layout.max_size.width),
        clampIntrinsicAxis(height, child.layout.min_size.height, child.layout.max_size.height),
    );
}

/// Whether the accordion's EXTENT includes its content: only while
/// open. This gates measurement (a closed item stacks at header height)
/// but NOT child layout — children lay out at full size regardless, so
/// the runtime's disclosure tween can reveal or conceal them without a
/// single mid-flight re-wrap.
fn accordionChildrenVisible(widget: Widget) bool {
    return widget.kind != .accordion or booleanControlSelected(widget);
}

fn accordionContentFrame(widget: Widget, content: geometry.RectF, tokens: DesignTokens, depth: usize) geometry.RectF {
    if (widget.kind != .accordion) return content;
    const header_height = accordionHeaderHeight(widget, tokens);
    const gap = nonNegative(widget.layout.gap);
    const y = content.y + header_height + gap;
    // An open item's frame reserves the content box below the header; a
    // closed item's header-only frame reserves nothing, so the content
    // box sizes itself from the children's own wrapped extent — the
    // same measurement the open pose's extent is built from, which is
    // what keeps child geometry identical across both poses.
    const remaining = content.maxY() - y;
    const height = if (remaining > 0) remaining else accordionOpenContentExtent(widget, content.width, tokens, depth);
    return geometry.RectF.init(content.x, y, content.width, height);
}

/// The content height an OPEN pose grants: the tallest in-flow child at
/// its wrapped width — the same per-child measurement the accordion's
/// vertical extent uses, replayed so a closed pose can hand children
/// full-size frames.
fn accordionOpenContentExtent(widget: Widget, width: f32, tokens: DesignTokens, depth: usize) f32 {
    var max_height: f32 = 0;
    for (widget.children) |child| {
        if (child.layout.anchor != null) continue;
        const child_width = if (child.frame.width > 0) child.frame.width else width;
        max_height = @max(max_height, wrappedVerticalExtentForWidth(child, child_width, tokens, depth + 1));
    }
    return max_height;
}

pub fn accordionHeaderHeight(widget: Widget, tokens: DesignTokens) f32 {
    // The house trigger band: the label line with py-4 — a spacing.lg
    // inset above and below it (density/size scaled).
    const text_size = widgetBodyTextSize(widget, tokens);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.lg);
    return @max(widgetControlHeight(widget, tokens), widgetLineHeight(text_size) + inset * 2);
}

/// Alert children start under the chrome-drawn title line and hang past
/// the icon column (the standard callout grid: icon in column one, title and
/// description stacked in column two). Text-less alerts keep the full
/// content box.
fn alertContentFrame(widget: Widget, content: geometry.RectF, tokens: DesignTokens) geometry.RectF {
    if (widget.kind != .alert or widget.text.len == 0) return content;
    const text_size = widgetBodyTextSize(widget, tokens);
    const icon_size = widgetSizedDensityValue(widget, tokens, 16);
    const text_gap = widgetControlInset(widget, tokens, tokens.spacing.md);
    const title_gap = widgetControlInset(widget, tokens, tokens.spacing.xs);
    const indent = @min(content.width, icon_size + text_gap);
    const y = @min(content.maxY(), content.y + widgetLineHeight(text_size) + title_gap);
    return geometry.RectF.init(
        content.x + indent,
        y,
        @max(0, content.width - indent),
        @max(0, content.maxY() - y),
    );
}

pub fn intrinsicWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    return intrinsicWidgetSizeDepth(widget, tokens, 0);
}

fn intrinsicWidgetSizeDepth(widget: Widget, tokens: DesignTokens, depth: usize) geometry.SizeF {
    return switch (widget.kind) {
        .text => intrinsicTextWidgetSize(widget, tokens, widgetBodyTextSize(widget, tokens)),
        .icon => geometry.SizeF.init(intrinsicIconExtent(widget, tokens), intrinsicIconExtent(widget, tokens)),
        .avatar => intrinsicAvatarWidgetSize(widget, tokens),
        .badge => intrinsicBadgeWidgetSize(widget, tokens),
        .button, .toggle_button, .toggle => intrinsicButtonWidgetSize(widget, tokens),
        .icon_button => intrinsicSquareControlSize(widget, tokens),
        .select => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 200), widgetControlHeight(widget, tokens)),
        .input, .text_field => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 160), widgetControlHeight(widget, tokens)),
        .search_field, .combobox => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 200), widgetControlHeight(widget, tokens)),
        .textarea => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 200), widgetSizedDensityValue(widget, tokens, 80)),
        .tooltip => intrinsicPaddedTextWidgetSize(widget, tokens, widgetLabelTextSize(widget, tokens), widgetControlInset(widget, tokens, tokens.spacing.sm)),
        // Menu rows measure like list rows PLUS the trailing checkmark
        // slot every option reserves (committed or not, so commit moves
        // never reflow labels), on the menu's comfortable row band.
        .menu_item => blk: {
            const base = intrinsicRowTextWidgetSize(widget, tokens);
            const check_reserve = widget_metrics.widgetRowIconExtent(widget, tokens) + widget_metrics.widgetRowIconGap(widget, tokens);
            // The fractional check reserve can pull the total off the
            // snap grid again; ceil the final width so edge snapping
            // never shaves the label region (`pixelSnapCeil`).
            break :blk geometry.SizeF.init(pixelSnapCeil(tokens, base.width + check_reserve), widgetSizedDensityValue(widget, tokens, 32));
        },
        .list_item => blk: {
            const base = intrinsicRowTextWidgetSize(widget, tokens);
            if (widget.children.len == 0) break :blk base;
            const flow = intrinsicAxisChildrenSize(widget, tokens, .horizontal, depth);
            // A child flow only fractionally wider than the label-exact
            // base sits off the snap grid; ceil the winner so edge
            // snapping cannot land the row below its own label
            // (`pixelSnapCeil`).
            break :blk geometry.SizeF.init(pixelSnapCeil(tokens, @max(base.width, flow.width)), @max(base.height, flow.height));
        },
        // A span-carrying cell (markdown tables) measures like a padded
        // span paragraph; classic cells keep the single-line row metric.
        .data_cell => if (widget.spans.len > 0)
            paddedIntrinsicSize(widget, intrinsicTextWidgetSize(widget, tokens, widgetBodyTextSize(widget, tokens)))
        else
            intrinsicRowTextWidgetSize(widget, tokens),
        // Table rows sit taller than list rows: the comfortable row
        // band with tight cell padding, the reference table rhythm.
        .data_row => geometry.SizeF.init(0, widgetSizedDensityValue(widget, tokens, 36)),
        .status_bar => intrinsicStatusBarWidgetSize(widget, tokens),
        .segmented_control => intrinsicSegmentedControlSize(widget, tokens),
        .checkbox => intrinsicCheckboxWidgetSize(widget, tokens),
        .radio => intrinsicRadioWidgetSize(widget, tokens),
        .switch_control => intrinsicToggleWidgetSize(widget, tokens),
        .slider => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 160), @max(widgetSizedDensityValue(widget, tokens, 28), widgetSizedDensityValue(widget, tokens, 20))),
        // A 4px rail: the display-only bar is half the slider track so a
        // read-out never outweighs the control that edits the value.
        .progress => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 160), widgetSizedDensityValue(widget, tokens, 4)),
        .separator => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 160), controlStrokeWidth(widget, componentControlVisualTokens(widget, tokens), tokens.stroke.hairline)),
        .skeleton => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 120), widgetSizedDensityValue(widget, tokens, 20)),
        .spinner => intrinsicSpinnerWidgetSize(widget, tokens),
        // A plot has no natural content size; the default is a small
        // sparkline-friendly box, and definite `width`/`height` (or flex
        // grow) size real charts.
        .chart => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 160), widgetSizedDensityValue(widget, tokens, 48)),
        .alert => intrinsicAlertWidgetSize(widget, tokens, depth),
        .card => intrinsicCardWidgetSize(widget, tokens, depth),
        .accordion => intrinsicAccordionWidgetSize(widget, tokens, depth),
        .dialog, .drawer, .sheet => intrinsicModalSurfaceWidgetSize(widget, tokens, depth),
        // Containers measure their children (matching the stacking axis the
        // layout pass uses), bounded by the widget depth cap. Scroll
        // viewports and virtualized containers stay zero: their content is
        // allowed to overflow the space they're given.
        .row, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group => intrinsicAxisChildrenSize(widget, tokens, .horizontal, depth),
        .column, .menu_surface, .dropdown_menu, .input_group => intrinsicAxisChildrenSize(widget, tokens, .vertical, depth),
        .list, .data_grid, .table => if (widget.layout.virtualized)
            geometry.SizeF.zero()
        else
            intrinsicAxisChildrenSize(widget, tokens, .vertical, depth),
        .grid => if (widget.layout.virtualized)
            geometry.SizeF.zero()
        else
            intrinsicGridChildrenSize(widget, tokens, depth),
        .stack, .bubble, .resizable, .panel, .popover => intrinsicOverlayChildrenSize(widget, tokens, depth),
        .tree => intrinsicAxisChildrenSize(widget, tokens, .vertical, depth),
        // The divider band is thin along the row and cross-sized by the
        // panes it divides (like a bare separator in a row).
        .split_divider => geometry.SizeF.init(splitDividerExtent(widget), 0),
        // A split fills the space it is given (panes partition it);
        // like scroll viewports it reports no intrinsic size of its own.
        // Media surfaces measure like images: the texture is external
        // content with no natural layout size — definite width/height
        // (or flex grow) size the surface, exactly like an image leaf.
        .scroll_view, .image, .split, .media_surface => geometry.SizeF.zero(),
    };
}

fn intrinsicChildSize(child: Widget, tokens: DesignTokens, depth: usize) geometry.SizeF {
    const intrinsic = intrinsicWidgetSizeDepth(child, tokens, depth);
    return geometry.SizeF.init(
        clampIntrinsicAxis(@max(intrinsic.width, nonNegative(child.frame.width)), child.layout.min_size.width, child.layout.max_size.width),
        clampIntrinsicAxis(@max(intrinsic.height, nonNegative(child.frame.height)), child.layout.min_size.height, child.layout.max_size.height),
    );
}

fn clampIntrinsicAxis(value: f32, min: f32, max: f32) f32 {
    return @max(min, boundedByMax(value, max));
}

/// Child contribution to a flex container's intrinsic size. A bare
/// separator inside a horizontal container is a divider: it contributes
/// its stroke thickness on both axes (thin along the row, cross-sized by
/// the siblings it divides) instead of its default horizontal-rule
/// length. Vertical containers keep the classic contribution.
fn intrinsicChildSizeInAxis(child: Widget, tokens: DesignTokens, depth: usize, axis: LayoutAxis) geometry.SizeF {
    const size = intrinsicChildSize(child, tokens, depth);
    if (child.kind == .separator and axis == .horizontal and child.frame.width <= 0) {
        const thin = @min(size.width, size.height);
        return geometry.SizeF.init(
            @max(nonNegative(child.layout.min_size.width), thin),
            @max(nonNegative(child.layout.min_size.height), thin),
        );
    }
    return size;
}

fn intrinsicAxisChildrenSize(widget: Widget, tokens: DesignTokens, axis: LayoutAxis, depth: usize) geometry.SizeF {
    if (depth >= max_widget_depth or widget.children.len == 0) return intrinsicOwnMinSize(widget);
    var flow_count: usize = 0;
    var main_sum: f32 = 0;
    var cross_max: f32 = 0;
    for (widget.children) |child| {
        // Anchored floating children never grow their parent.
        if (child.layout.anchor != null) continue;
        flow_count += 1;
        const size = intrinsicChildSizeInAxis(child, tokens, depth + 1, axis);
        switch (axis) {
            .horizontal => {
                main_sum += size.width;
                cross_max = @max(cross_max, size.height);
            },
            .vertical => {
                main_sum += size.height;
                cross_max = @max(cross_max, size.width);
            },
        }
    }
    if (flow_count == 0) return intrinsicOwnMinSize(widget);
    // Button groups and tab strips measure at their register's effective
    // gap (see `buttonGroupGap`/`tabsGap`), so intrinsic sizing agrees
    // with placement.
    const child_gap = switch (widget.kind) {
        .button_group => buttonGroupGap(widget, tokens),
        .tabs => tabsGap(widget, tokens),
        else => nonNegative(widget.layout.gap),
    };
    const gap = child_gap * @as(f32, @floatFromInt(flow_count - 1));
    return paddedIntrinsicSize(widget, switch (axis) {
        .horizontal => geometry.SizeF.init(main_sum + gap, cross_max),
        .vertical => geometry.SizeF.init(cross_max, main_sum + gap),
    });
}

fn intrinsicOverlayChildrenSize(widget: Widget, tokens: DesignTokens, depth: usize) geometry.SizeF {
    if (depth >= max_widget_depth or widget.children.len == 0) return intrinsicOwnMinSize(widget);
    var width_max: f32 = 0;
    var height_max: f32 = 0;
    for (widget.children) |child| {
        if (child.layout.anchor != null) continue;
        const size = intrinsicChildSize(child, tokens, depth + 1);
        width_max = @max(width_max, size.width);
        height_max = @max(height_max, size.height);
    }
    return paddedIntrinsicSize(widget, geometry.SizeF.init(width_max, height_max));
}

fn intrinsicGridChildrenSize(widget: Widget, tokens: DesignTokens, depth: usize) geometry.SizeF {
    if (depth >= max_widget_depth or widget.children.len == 0) return intrinsicOwnMinSize(widget);
    var cell_width: f32 = 0;
    var cell_height: f32 = 0;
    for (widget.children) |child| {
        if (child.layout.anchor != null) continue;
        const size = intrinsicChildSize(child, tokens, depth + 1);
        cell_width = @max(cell_width, size.width);
        cell_height = @max(cell_height, size.height);
    }
    const columns = gridColumnCount(widget.children.len, widget.layout.columns);
    // `gridRowCount`, not the additive ceil-div: declared columns are
    // engine input, and `children.len + columns` overflows in safe
    // builds when a parent intrinsically measures a maxInt-columns grid.
    const rows = gridRowCount(widget.children.len, columns);
    const gap = nonNegative(widget.layout.gap);
    return paddedIntrinsicSize(widget, geometry.SizeF.init(
        cell_width * @as(f32, @floatFromInt(columns)) + gap * @as(f32, @floatFromInt(columns - 1)),
        cell_height * @as(f32, @floatFromInt(rows)) + gap * @as(f32, @floatFromInt(rows - 1)),
    ));
}

fn intrinsicOwnMinSize(widget: Widget) geometry.SizeF {
    return geometry.SizeF.init(nonNegative(widget.layout.min_size.width), nonNegative(widget.layout.min_size.height));
}

fn paddedIntrinsicSize(widget: Widget, content: geometry.SizeF) geometry.SizeF {
    const padding = widget.layout.padding;
    return geometry.SizeF.init(
        @max(content.width + padding.left + padding.right, widget.layout.min_size.width),
        @max(content.height + padding.top + padding.bottom, widget.layout.min_size.height),
    );
}

fn intrinsicTextWidgetSize(widget: Widget, tokens: DesignTokens, text_size: f32) geometry.SizeF {
    if (widgetIsSpanParagraph(widget)) {
        const options = widgetTextSpanLayoutOptions(widget, tokens, 0);
        return geometry.SizeF.init(
            text_spans_model.textSpansIntrinsicWidth(widget.spans, options),
            widgetLineHeight(text_size * text_spans_model.textSpansMaxScale(widget.spans)),
        );
    }
    return geometry.SizeF.init(
        measuredTextWidth(tokens, widget.text, text_size),
        widgetLineHeight(text_size),
    );
}

fn intrinsicPaddedTextWidgetSize(widget: Widget, tokens: DesignTokens, text_size: f32, inset: f32) geometry.SizeF {
    const text = intrinsicTextWidgetSize(widget, tokens, text_size);
    // Ceil to the snap grid (`pixelSnapCeil`): the tooltip capsule hugs
    // its measured label exactly, so render-time edge snapping must not
    // shave it into eliding.
    return geometry.SizeF.init(pixelSnapCeil(tokens, text.width + inset * 2), @max(widgetControlHeight(widget, tokens), text.height + widgetSizedDensityValue(widget, tokens, 8)));
}

fn intrinsicStatusBarWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const text_size = widgetBodyTextSize(widget, tokens);
    const text = intrinsicTextWidgetSize(widget, tokens, text_size);
    const padding = widgetStatusBarPadding(widget);
    // Ceil to the snap grid (`pixelSnapCeil`): a hug-sized status bar
    // is label-exact and its text elides at the frame edge, the same
    // cliff every measured-label chip rides.
    return geometry.SizeF.init(pixelSnapCeil(tokens, text.width + padding.horizontal()), @max(widgetSizedDensityValue(widget, tokens, 32), text.height + padding.vertical()));
}

fn intrinsicAlertWidgetSize(widget: Widget, tokens: DesignTokens, depth: usize) geometry.SizeF {
    const text_size = widgetBodyTextSize(widget, tokens);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.lg);
    // The chrome's fixed 16px icon (`emitAlertWidgetChrome`).
    const icon_size = widgetSizedDensityValue(widget, tokens, 16);
    const text_gap = widgetControlInset(widget, tokens, tokens.spacing.md);
    const text = intrinsicTextWidgetSize(widget, tokens, text_size);
    var size = geometry.SizeF.init(
        @max(widgetSizedDensityValue(widget, tokens, 240), text.width + inset * 2 + icon_size + text_gap),
        @max(widgetSizedDensityValue(widget, tokens, 52), widgetLineHeight(text_size) + inset * 2),
    );
    // A description column under the title (`alertContentFrame`) grows
    // the alert instead of overflowing it.
    const children = intrinsicStackedChildrenSize(widget, tokens, depth);
    if (children.height > 0 and widget.text.len > 0) {
        const title_gap = widgetControlInset(widget, tokens, tokens.spacing.xs);
        size.height = @max(size.height, widgetLineHeight(text_size) + title_gap + children.height + inset * 2);
        size.width = @max(size.width, children.width + icon_size + text_gap + inset * 2);
    } else if (children.height > 0) {
        size.height = @max(size.height, children.height + inset * 2);
        size.width = @max(size.width, children.width + inset * 2);
    }
    return size;
}

/// The overlay max of a stacking surface's flow children, WITHOUT the
/// widget's own padding or min-size floors (callers fold those in).
fn intrinsicStackedChildrenSize(widget: Widget, tokens: DesignTokens, depth: usize) geometry.SizeF {
    if (depth >= max_widget_depth) return geometry.SizeF.zero();
    var width_max: f32 = 0;
    var height_max: f32 = 0;
    for (widget.children) |child| {
        if (child.layout.anchor != null) continue;
        const size = intrinsicChildSize(child, tokens, depth + 1);
        width_max = @max(width_max, size.width);
        height_max = @max(height_max, size.height);
    }
    return geometry.SizeF.init(width_max, height_max);
}

fn intrinsicAccordionWidgetSize(widget: Widget, tokens: DesignTokens, depth: usize) geometry.SizeF {
    // Header band always; expanded content (plus the header-to-content
    // gap the accordion consumes) only while disclosed — so accordion
    // items size themselves and a toggle reflows the column around them.
    const header_height = accordionHeaderHeight(widget, tokens);
    var content = geometry.SizeF.zero();
    if (accordionChildrenVisible(widget)) {
        content = intrinsicStackedChildrenSize(widget, tokens, depth);
    }
    const gap = if (content.height > 0) nonNegative(widget.layout.gap) else 0;
    return paddedIntrinsicSize(widget, geometry.SizeF.init(content.width, header_height + gap + content.height));
}

fn intrinsicCardWidgetSize(widget: Widget, tokens: DesignTokens, depth: usize) geometry.SizeF {
    const title_size = widgetTypographySize(widget, tokens.typography.body_size + 1);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.lg);
    const text = intrinsicTextWidgetSize(widget, tokens, title_size);
    var size = geometry.SizeF.init(
        @max(widgetSizedDensityValue(widget, tokens, 240), text.width + inset * 2),
        @max(widgetSizedDensityValue(widget, tokens, 120), if (widget.text.len > 0) widgetLineHeight(title_size) + inset * 2 else 0),
    );
    // Content-bearing cards grow around their children plus the card's
    // own padding (the default 24px house inset) instead of clipping
    // them against the 120pt floor.
    const children = intrinsicStackedChildrenSize(widget, tokens, depth);
    if (children.height > 0) {
        const padding = widget.layout.padding;
        size.height = @max(size.height, children.height + padding.top + padding.bottom);
        size.width = @max(size.width, children.width + padding.left + padding.right);
    }
    return size;
}

fn intrinsicModalSurfaceWidgetSize(widget: Widget, tokens: DesignTokens, depth: usize) geometry.SizeF {
    const title_size = widgetTypographySize(widget, tokens.typography.title_size);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.xl);
    const text = intrinsicTextWidgetSize(widget, tokens, title_size);
    const default_size = switch (widget.kind) {
        .drawer => geometry.SizeF.init(360, 280),
        .sheet => geometry.SizeF.init(320, 420),
        else => geometry.SizeF.init(420, 220),
    };
    var size = geometry.SizeF.init(
        @max(widgetSizedDensityValue(widget, tokens, default_size.width), text.width + inset * 2),
        @max(widgetSizedDensityValue(widget, tokens, default_size.height), if (widget.text.len > 0) widgetLineHeight(title_size) + inset * 2 else 0),
    );
    // Content-bearing modal surfaces hug their children plus their own
    // padding, like cards. The fixed default height is a placeholder for
    // childless surfaces, NOT a floor: content shorter than the default
    // would otherwise leave the surplus stacked below the last child, so
    // a dialog's inset under its button row breaks symmetry with the
    // insets its padding declares on the other three sides.
    const children = intrinsicStackedChildrenSize(widget, tokens, depth);
    if (children.height > 0) {
        const padding = widget.layout.padding;
        size.height = children.height + padding.top + padding.bottom;
        if (widget.text.len > 0) size.height = @max(size.height, widgetLineHeight(title_size) + inset * 2);
        size.width = @max(size.width, children.width + padding.left + padding.right);
    }
    return size;
}

fn intrinsicButtonWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const height = widgetControlHeight(widget, tokens);
    if (widget.size == .icon) return geometry.SizeF.init(height, height);
    // An inline icon (`widget.icon`) widens the button: icon + gap before
    // the label, or a square control when the label is empty. The extent
    // and gap are the shared render metrics, so measured width matches
    // painted pixels.
    if (widget.icon.len > 0 and widget.text.len == 0) return geometry.SizeF.init(height, height);
    const icon_width = if (widget.icon.len > 0)
        widget_metrics.widgetButtonIconExtent(widget, tokens) + widget_metrics.widgetButtonIconGap(widget, tokens)
    else
        0;
    // Measured with the button-label face (not the body face) so the
    // medium advances the render draws are the widths layout reserves.
    const text_width = measureTextWidthForFont(tokens.text_measure, tokens.typography.buttonFontId(), widget.text, widgetButtonTextSize(widget, tokens));
    // Ceil to the snap grid (`pixelSnapCeil`): a button or toggle chip
    // sized exactly to its measured label ("PID" in a sort-chip row)
    // must not lose a fraction of a pixel to render-time edge snapping
    // and elide its own label.
    const width = pixelSnapCeil(tokens, @max(widgetSizedDensityValue(widget, tokens, 44), icon_width + text_width + widgetButtonInset(widget, tokens) * 2));
    return geometry.SizeF.init(width, height);
}

fn intrinsicAvatarWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const size = widgetSizedDensityValue(widget, tokens, 40);
    return geometry.SizeF.init(size, size);
}

fn intrinsicBadgeWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const min_width = widgetSizedDensityValue(widget, tokens, 24);
    const height = widgetSizedDensityValue(widget, tokens, 20);
    // An ICON-ONLY badge carries no text insets: the renderer centers
    // the glyph, so it takes the same minimum chip width a single-digit
    // badge gets — a timeline's completed check and its numbered
    // neighbors stay the same capsule instead of the icon one widening
    // by the text insets.
    if (widget.icon.len > 0 and widget.text.len == 0) {
        const icon_extent = widget_metrics.widgetBadgeIconExtent(widget, tokens);
        return geometry.SizeF.init(@max(min_width, icon_extent + tokens.spacing.xs * 2), height);
    }
    const text_width = measuredTextWidth(tokens, widget.text, widget_metrics.widgetBadgeTextSize(widget, tokens));
    const inset = widgetControlInset(widget, tokens, tokens.spacing.sm);
    // An inline icon widens the badge by the same shared metrics
    // the renderer paints with (gap only when a label follows).
    const icon_width = if (widget.icon.len > 0)
        widget_metrics.widgetBadgeIconExtent(widget, tokens) + widget_metrics.widgetBadgeIconGap(widget, tokens)
    else
        0;
    // The compact chip: a 20px band (the reference badge height) with
    // the tight 8px side insets. Under geometry pixel snapping the
    // fractional exact-fit width rides a cliff: render snaps the chip's
    // frame edges to the pixel grid, which can shave up to one snap
    // step off the box the label was measured to fill exactly — and the
    // elision pass then swaps real glyphs for an ellipsis. Rounding the
    // intrinsic width UP to the snap grid keeps the snapped chip at
    // least label-wide; themes without geometry snapping keep the exact
    // measurement, bit-identical to before.
    return geometry.SizeF.init(pixelSnapCeil(tokens, @max(min_width, icon_width + text_width + inset * 2)), height);
}

/// True exactly when the renderer's geometry snapping is live — the
/// same guard its rect snapping applies (geometry on, usable scale) —
/// so intrinsic sizing and painting agree about whether edges move.
fn pixelSnapGeometryActive(tokens: DesignTokens) bool {
    return tokens.pixel_snap.geometry and std.math.isFinite(tokens.pixel_snap.scale) and tokens.pixel_snap.scale > 0;
}

/// Round a length UP to the pixel-snap grid when geometry snapping is
/// on (no-op otherwise): intrinsic boxes sized from measured text must
/// survive the renderer's edge snapping without losing content width.
/// A width on the snap grid is preserved exactly by edge snapping at
/// ANY position (both edges move by the same rounding), so the snapped
/// box is never narrower than the label it was measured for.
fn pixelSnapCeil(tokens: DesignTokens, value: f32) f32 {
    if (!pixelSnapGeometryActive(tokens)) return value;
    const scale = tokens.pixel_snap.scale;
    return @ceil(value * scale) / scale;
}

fn intrinsicSquareControlSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const height = widgetControlHeight(widget, tokens);
    return geometry.SizeF.init(height, height);
}

/// The spinner is an inline activity glyph, not a control box: it sizes
/// to the icon register — 16 (sm) / 20 (default) / 24 (lg), density
/// scaled — so it sits flush in a row of compact controls instead of
/// claiming a 36px control square.
fn intrinsicSpinnerWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const base: f32 = switch (widget.size) {
        .sm => 16,
        // heading/display are text-leaf typography rungs; the spinner
        // glyph sits at the default register.
        .default, .icon, .heading, .display => 20,
        .lg => 24,
    };
    const extent = densityValue(tokens, base);
    return geometry.SizeF.init(extent, extent);
}

fn intrinsicSegmentedControlSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const text_width = measuredTextWidth(tokens, widget.text, widgetLabelTextSize(widget, tokens));
    // Ceil to the snap grid (`pixelSnapCeil`): a segment / tabs trigger
    // sized exactly to its measured label must survive render-time edge
    // snapping without eliding.
    const width = pixelSnapCeil(tokens, @max(widgetSizedDensityValue(widget, tokens, 44), text_width + widgetControlInset(widget, tokens, tokens.spacing.md) * 2));
    return geometry.SizeF.init(width, widgetControlHeight(widget, tokens));
}

fn intrinsicRowTextWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const text_size = widgetBodyTextSize(widget, tokens);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    const text_width = measuredTextWidth(tokens, widget.text, text_size);
    // A leading icon widens the row by the same shared metrics the
    // renderer paints with, so measured widths and pixels agree.
    const icon_width = if (widget.icon.len > 0)
        widget_metrics.widgetRowIconExtent(widget, tokens) + widget_metrics.widgetRowIconGap(widget, tokens)
    else
        0;
    // Ceil to the snap grid (`pixelSnapCeil`): list rows and table
    // cells hug their measured label exactly, so render-time edge
    // snapping must not shave the label below its own width and elide.
    return geometry.SizeF.init(pixelSnapCeil(tokens, icon_width + text_width + inset * 2), widgetDefaultRowHeight(widget, tokens));
}

fn intrinsicCheckboxWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const box_size = widgetSizedDensityValue(widget, tokens, 18);
    const label_size = widgetLabelTextSize(widget, tokens);
    const label_width = measuredTextWidth(tokens, widget.text, label_size);
    const gap = if (widget.text.len > 0) widgetControlInset(widget, tokens, tokens.spacing.sm) else 0;
    // Ceil to the snap grid (`pixelSnapCeil`): the label tail after the
    // box is measured exactly, and render-time edge snapping must not
    // shave it into eliding.
    return geometry.SizeF.init(pixelSnapCeil(tokens, box_size + gap + label_width), @max(box_size, widgetLineHeight(label_size)));
}

fn intrinsicRadioWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const circle_size = widgetSizedDensityValue(widget, tokens, 18);
    const label_size = widgetLabelTextSize(widget, tokens);
    const label_width = measuredTextWidth(tokens, widget.text, label_size);
    const gap = if (widget.text.len > 0) widgetControlInset(widget, tokens, tokens.spacing.sm) else 0;
    // Same label-exact tail as the checkbox: ceil so snapping cannot
    // elide the label (`pixelSnapCeil`).
    return geometry.SizeF.init(pixelSnapCeil(tokens, circle_size + gap + label_width), @max(circle_size, widgetLineHeight(label_size)));
}

fn intrinsicToggleWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    // Matches the rendered 44x24 switch track.
    const track_width = widgetSizedDensityValue(widget, tokens, 44);
    const track_height = widgetSizedDensityValue(widget, tokens, 24);
    const label_size = widgetLabelTextSize(widget, tokens);
    const label_width = measuredTextWidth(tokens, widget.text, label_size);
    const gap = if (widget.text.len > 0) widgetControlInset(widget, tokens, tokens.spacing.sm) else 0;
    const height = @max(track_height, widgetLineHeight(label_size));
    // The renderer widens the track to 1.75x a tall row's height and
    // snaps the track RECT itself to the pixel grid, where nearest-
    // rounding can grow it past a fractional reserve (a 38.5px sm track
    // paints 39px wide at scale 1) and push the label into eliding.
    // With snapping live, reserve the ceiled render extent and ceil the
    // total like every measured-label chip; non-snapping themes keep
    // the classic reserve bit-identically.
    const track_reserve = if (pixelSnapGeometryActive(tokens))
        pixelSnapCeil(tokens, @max(track_width, height * 1.75))
    else
        track_width;
    return geometry.SizeF.init(pixelSnapCeil(tokens, track_reserve + gap + label_width), height);
}

fn intrinsicIconExtent(widget: Widget, tokens: DesignTokens) f32 {
    return widgetSizedDensityValue(widget, tokens, 18);
}

/// The chat bubble's thread fraction: a bubble with no explicit width
/// caps at 80% of the content width its container offers — the measured
/// reference treatment — so one long message wraps into a readable
/// column instead of spanning the whole thread. Ghost bubbles are
/// exempt (the reference lets the chrome-less variant run full width:
/// its content carries the message).
pub const bubble_max_width_fraction: f32 = 0.8;

/// Cap a bubble child's inline extent at the thread fraction. `value`
/// is the width the container's math chose, `available` the container's
/// content width. Only hug-sized bubbles participate: an explicit
/// `width` (definite through the frame channel), an author `max_size`,
/// or a ghost variant leaves the classic result untouched, and a
/// container that offers no definite space (hug measurement) cannot
/// name a fraction of it. An author min-width floor still wins over the
/// cap, the same precedence `clampIntrinsicAxis` keeps everywhere.
/// The row main-axis seam of the bubble thread cap: the main extent of
/// a horizontal container's child is its width, so hug-sized bubbles
/// cap at the thread fraction there. Vertical containers pass through —
/// their main axis is height; the cross-extent seam in
/// `preferredCrossExtent` owns the width there.
fn mainExtentWithBubbleCap(child: Widget, axis: LayoutAxis, available: f32, value: f32) f32 {
    if (axis != .horizontal) return value;
    return bubbleThreadWidthCap(child, available, value);
}

fn bubbleThreadCapEligible(child: Widget) bool {
    if (child.kind != .bubble or child.variant == .ghost) return false;
    return child.frame.width <= 0 and child.layout.max_size.width <= 0;
}

fn bubbleThreadWidthCap(child: Widget, available: f32, value: f32) f32 {
    if (!bubbleThreadCapEligible(child) or available <= 0) return value;
    return @min(value, @max(available * bubble_max_width_fraction, nonNegative(child.layout.min_size.width)));
}

fn preferredMainExtent(widget: Widget, axis: LayoutAxis, tokens: DesignTokens) f32 {
    const value = switch (axis) {
        .horizontal => widget.frame.width,
        .vertical => widget.frame.height,
    };
    return clampMainExtent(widget, axis, if (value > 0) value else intrinsicMainExtent(widget, axis, tokens));
}

fn preferredCrossExtent(widget: Widget, axis: LayoutAxis, available: f32, alignment: WidgetCrossAlignment, tokens: DesignTokens) f32 {
    const value = switch (axis) {
        .horizontal => widget.frame.height,
        .vertical => widget.frame.width,
    };
    const min_value = switch (axis) {
        .horizontal => widget.layout.min_size.height,
        .vertical => widget.layout.min_size.width,
    };
    const max_value = switch (axis) {
        .horizontal => widget.layout.max_size.height,
        .vertical => widget.layout.max_size.width,
    };
    if (value > 0) return @max(min_value, boundedByMax(value, max_value));
    // The cross axis of a vertical container is the child's WIDTH, so
    // the bubble thread contract applies here: a bubble directly in a
    // column HUGS its message up to the thread fraction — even under
    // the default stretch alignment, because a stretched message
    // surface is exactly the shape the reference bubble never takes
    // (fit-content, capped at 80% of the thread).
    if (axis == .vertical and bubbleThreadCapEligible(widget) and available > 0) {
        const fitted = @min(available, intrinsicCrossExtent(widget, axis, tokens));
        return @max(min_value, boundedByMax(bubbleThreadWidthCap(widget, available, fitted), max_value));
    }
    if (alignment == .stretch) return @max(min_value, boundedByMax(available, max_value));
    const intrinsic = intrinsicCrossExtent(widget, axis, tokens);
    // A cross-CENTERED child of a horizontal container keeps its
    // intrinsic HEIGHT even past the band, so the centering rule above
    // (`alignedCrossAxisOrigin`) can split the overflow across both
    // edges — clamping here handed an oversized stack a band-sized
    // frame whose inner flow then spilled past the bottom edge only
    // (top-heavy rows: a two-line text stack inside a fixed-height list
    // row). Explicit heights already pass through unclamped (the
    // `value` branch above); this extends the same honesty to intrinsic
    // ones. The WIDTH cross axis (vertical containers) keeps the clamp:
    // the offered width is what drives text wrap, and an unclamped
    // width would un-wrap centered paragraphs.
    if (axis == .horizontal and alignment == .center) {
        return @max(min_value, boundedByMax(intrinsic, max_value));
    }
    return @max(min_value, boundedByMax(@min(available, intrinsic), max_value));
}

fn minMainExtent(widget: Widget, axis: LayoutAxis) f32 {
    return switch (axis) {
        .horizontal => nonNegative(widget.layout.min_size.width),
        .vertical => nonNegative(widget.layout.min_size.height),
    };
}

fn intrinsicMainExtent(widget: Widget, axis: LayoutAxis, tokens: DesignTokens) f32 {
    const size = orientedIntrinsicWidgetSize(widget, tokens, axis);
    return switch (axis) {
        .horizontal => size.width,
        .vertical => size.height,
    };
}

fn intrinsicCrossExtent(widget: Widget, axis: LayoutAxis, tokens: DesignTokens) f32 {
    const size = orientedIntrinsicWidgetSize(widget, tokens, axis);
    return switch (axis) {
        .horizontal => size.height,
        .vertical => size.width,
    };
}

/// Axis-aware intrinsic size. A separator's intrinsic size is authored as
/// a horizontal rule (default length x stroke width); inside a horizontal
/// container the rule runs vertically, so the components swap — the
/// separator stays hairline-thin along the row's main axis (a pane
/// divider) instead of eating its default length from the row. Explicit
/// `width`/`frame` values still win through the min/frame channels.
fn orientedIntrinsicWidgetSize(widget: Widget, tokens: DesignTokens, axis: LayoutAxis) geometry.SizeF {
    const size = intrinsicWidgetSize(widget, tokens);
    if (widget.kind == .separator and axis == .horizontal) {
        return geometry.SizeF.init(size.height, size.width);
    }
    return size;
}

pub fn virtualWidgetScrollContentExtent(widget: Widget, viewport_extent: f32) f32 {
    return virtualWidgetScrollContentExtentWithTokens(widget, viewport_extent, .{});
}

pub fn virtualWidgetScrollContentExtentWithTokens(widget: Widget, viewport_extent: f32, tokens: DesignTokens) f32 {
    // A variable-extent windowed virtual list DECLARES its content
    // extent: the window's offset table already summed estimates plus
    // measured corrections plus gaps, and stamping it here is what
    // keeps the engine scrollbar, the scroll semantics, and the native
    // driver's content size telling the same (converging) truth.
    if (widget.layout.virtual_total_extent > 0 and widget.layout.virtual_item_count > 0) {
        return widget.layout.virtual_total_extent;
    }
    const item_count = virtualWidgetScrollItemCount(widget);
    if (item_count == 0) return 0;
    const item_extent = if (widget.layout.virtual_item_extent > 0)
        widget.layout.virtual_item_extent
    else if (widget.kind == .grid and widget.children.len > 0)
        preferredGridRowExtent(widget.children, gridColumnCount(widget.children.len, widget.layout.columns), tokens)
    else if (widget.children.len > 0)
        preferredMainExtent(widget.children[0], .vertical, tokens)
    else
        return 0;
    return virtualListRange(.{
        .item_count = item_count,
        .item_extent = item_extent,
        .item_gap = widget.layout.gap,
        .viewport_extent = viewport_extent,
        .scroll_offset = widget.value,
    }).content_extent;
}

fn virtualWidgetScrollItemCount(widget: Widget) usize {
    // A windowed virtual list's extent comes from its DECLARED count:
    // children hold only the built window, so counting them would
    // collapse the scrollbar (and the native driver's content size) to
    // the window.
    if (widget.layout.virtual_item_count > 0) {
        return @max(widget.layout.virtual_item_count, widget.layout.virtual_first_index + widget.children.len);
    }
    if (widget.kind == .grid and widget.children.len > 0) {
        const columns = gridColumnCount(widget.children.len, widget.layout.columns);
        return gridRowCount(widget.children.len, columns);
    }
    if (widget.children.len > 0) return widget.children.len;
    if (widget.semantics.list_item_count) |count| return @intCast(count);
    return 0;
}

fn widgetWithFrame(widget: Widget, frame: geometry.RectF) Widget {
    var copy = widget;
    copy.frame = frame;
    return copy;
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
