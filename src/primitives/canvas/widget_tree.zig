const std = @import("std");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const drawing_model = @import("drawing.zig");
const canvas = @import("root.zig");

const DesignTokens = token_model.DesignTokens;
const Widget = widget_model.Widget;
const Affine = drawing_model.Affine;
const ObjectId = canvas.ObjectId;

pub const WidgetPaintOrder = struct {
    layer: i32,
    index: usize,
};

pub fn widgetPaintLayer(widget: Widget, tokens: DesignTokens) i32 {
    if (widget.layer) |layer| return layer;
    return switch (widget.kind) {
        .popover, .menu_surface, .dropdown_menu => tokens.layer.overlay,
        .tooltip => tokens.layer.floating,
        else => tokens.layer.base,
    };
}

pub fn nextWidgetPaintChild(children: []const Widget, tokens: DesignTokens, previous: ?WidgetPaintOrder) ?usize {
    var best: ?WidgetPaintOrder = null;
    for (children, 0..) |child, index| {
        const order = WidgetPaintOrder{ .layer = widgetPaintLayer(child, tokens), .index = index };
        if (!widgetPaintOrderAfter(order, previous)) continue;
        if (best == null or widgetPaintOrderLess(order, best.?)) best = order;
    }
    return if (best) |order| order.index else null;
}

pub fn widgetLayoutDirectChildCount(layout: anytype, parent_index: ?usize) usize {
    var count: usize = 0;
    for (layout.nodes) |node| {
        if (optionalUsizeEqual(node.parent_index, parent_index)) count += 1;
    }
    return count;
}

pub fn nextWidgetLayoutPaintChild(layout: anytype, parent_index: ?usize, tokens: DesignTokens, previous: ?WidgetPaintOrder) ?usize {
    var best: ?WidgetPaintOrder = null;
    for (layout.nodes, 0..) |node, index| {
        if (!optionalUsizeEqual(node.parent_index, parent_index)) continue;
        const order = WidgetPaintOrder{ .layer = widgetPaintLayer(node.widget, tokens), .index = index };
        if (!widgetPaintOrderAfter(order, previous)) continue;
        if (best == null or widgetPaintOrderLess(order, best.?)) best = order;
    }
    return if (best) |order| order.index else null;
}

pub fn previousWidgetLayoutPaintChild(layout: anytype, parent_index: ?usize, tokens: DesignTokens, previous: ?WidgetPaintOrder) ?usize {
    var best: ?WidgetPaintOrder = null;
    for (layout.nodes, 0..) |node, index| {
        if (!optionalUsizeEqual(node.parent_index, parent_index)) continue;
        const order = WidgetPaintOrder{ .layer = widgetPaintLayer(node.widget, tokens), .index = index };
        if (!widgetPaintOrderBefore(order, previous)) continue;
        if (best == null or widgetPaintOrderLess(best.?, order)) best = order;
    }
    return if (best) |order| order.index else null;
}

fn widgetPaintOrderAfter(order: WidgetPaintOrder, previous: ?WidgetPaintOrder) bool {
    const value = previous orelse return true;
    return order.layer > value.layer or (order.layer == value.layer and order.index > value.index);
}

fn widgetPaintOrderBefore(order: WidgetPaintOrder, previous: ?WidgetPaintOrder) bool {
    const value = previous orelse return true;
    return order.layer < value.layer or (order.layer == value.layer and order.index < value.index);
}

fn widgetPaintOrderLess(a: WidgetPaintOrder, b: WidgetPaintOrder) bool {
    return a.layer < b.layer or (a.layer == b.layer and a.index < b.index);
}

fn optionalUsizeEqual(a: ?usize, b: ?usize) bool {
    if (a) |a_value| {
        return if (b) |b_value| a_value == b_value else false;
    }
    return b == null;
}

pub fn widgetTransform(widget: Widget) Affine {
    return widget.transform;
}

pub fn widgetClipsContent(widget: Widget) bool {
    return widget.kind == .scroll_view or widget.layout.clip_content;
}

/// True for anchored floating widgets (`layout.anchor` set): hoisted out
/// of the in-tree paint and hit-test walks into a late window-level pass,
/// and excluded from every ancestor clip region (window-clipped, not
/// parent-clipped). Ancestor HIDING still applies — a hidden subtree
/// hides its floating surfaces too.
pub fn widgetIsAnchored(widget: Widget) bool {
    return widget.layout.anchor != null;
}

/// True for the RUNTIME-SCROLLED virtual list: a virtualized
/// `.scroll_view` that declares its TOTAL item count
/// (`layout.virtual_item_count > 0`), so the runtime owns the scroll
/// offset — engine wheel/kinetic/keyboard scrolling applies, native
/// scroll drivers engage with the full virtual content extent, and the
/// view rebuilds only the visible window (`Ui.virtualList`). Legacy
/// virtualized containers (no declared count: children ARE the full
/// item set, layout-culled) keep their model-driven offset contract —
/// the engine refuses to scroll them, byte-identically to before.
pub fn widgetVirtualRuntimeScrolled(widget: Widget) bool {
    return widget.kind == .scroll_view and widget.layout.virtualized and widget.layout.virtual_item_count > 0;
}

/// The effective scroll physics for one scroll region: the shared
/// `ScrollPhysics` token with the region's `Widget.overscroll` override
/// resolved onto `physics.overscroll` (`.default` keeps the token's
/// global default). Both scroll paths resolve through this — the
/// engine's wheel/kinetic stepping and the native scroll driver sync —
/// so a region's edge behavior has exactly one derivation.
pub fn widgetScrollPhysics(widget: Widget, base: token_model.ScrollPhysics) token_model.ScrollPhysics {
    var physics = base;
    switch (widget.overscroll) {
        .default => {},
        .none => physics.overscroll = .none,
        .rubber_band => physics.overscroll = .rubber_band,
    }
    return physics;
}

pub fn widgetIndexById(layout: anytype, id: ObjectId) ?usize {
    if (id == 0) return null;
    for (layout.nodes, 0..) |node, index| {
        if (node.widget.id == id) return index;
    }
    return null;
}

pub fn isWidgetHiddenInAncestors(layout: anytype, node_index: usize) bool {
    var current: ?usize = node_index;
    while (current) |index| {
        if (index >= layout.nodes.len) return false;
        const node = layout.nodes[index];
        if (node.widget.semantics.hidden) return true;
        current = node.parent_index;
    }
    return false;
}

/// The DISCLOSURE family: collapsible widgets whose content lays out at
/// full size and REVEALS — the widget's own extent grows toward (or
/// shrinks away from) the content's, while the content itself never
/// re-wraps. Today that is the accordion; collapsible rows and
/// expandable cards join by adding their kind here and giving layout
/// the same "children always laid out, extent follows the disclosed
/// state" shape the accordion has.
pub fn widgetKindDisclosureAnimated(kind: widget_model.WidgetKind) bool {
    return kind == .accordion;
}

/// A pixel of slack for the settled-open comparison below: the frame an
/// ancestor stack hands a disclosure widget and the bottom its content
/// reaches are computed by different additions, so exact float equality
/// is too brittle a settle test while half a pixel is far tighter than
/// any real mid-reveal pose.
const disclosure_settle_slack: f32 = 0.5;

/// The bottom edge the disclosure widget's content REACHES: the deepest
/// maxY among its in-flow children's subtrees. Anchored children float
/// outside the flow (window-positioned) and never count.
pub fn disclosureContentBottom(layout: anytype, node_index: usize) f32 {
    const node = layout.nodes[node_index];
    var bottom = -std.math.inf(f32);
    var index = node_index + 1;
    while (index < layout.nodes.len and layout.nodes[index].depth > node.depth) : (index += 1) {
        const child = layout.nodes[index];
        if (widgetIsAnchored(child.widget)) continue;
        bottom = @max(bottom, child.frame.normalized().maxY());
    }
    return bottom;
}

/// Whether a disclosure widget is SETTLED OPEN: its state says open and
/// its frame has grown to hold everything its content reaches. Both
/// halves matter — mid-reveal the state is already open but the frame
/// still trails the content, and mid-conceal the state is already
/// closed while content is still sliding away. Interaction surfaces
/// (hit testing, focus, semantics) gate on this, so partially revealed
/// content stays inert until the reveal lands.
pub fn disclosureSettledOpen(layout: anytype, node_index: usize) bool {
    const widget = layout.nodes[node_index].widget;
    // The boolean-control "open" register (`booleanControlSelected`):
    // either state channel asserts it.
    if (!(widget.state.selected or widget.value >= 0.5)) return false;
    const bottom = disclosureContentBottom(layout, node_index);
    if (bottom == -std.math.inf(f32)) return true;
    return bottom <= layout.nodes[node_index].frame.normalized().maxY() + disclosure_settle_slack;
}

/// Whether any ANCESTOR disclosure widget conceals this node: the
/// ancestor is closed, closing, or still revealing. Content under a
/// concealed subtree lays out (at full size, ready to reveal) and may
/// even paint clipped mid-reveal, but it never hit-tests, focuses, or
/// appears in semantics — the interaction twin of
/// `isWidgetHiddenInAncestors`.
pub fn isWidgetConcealedByDisclosure(layout: anytype, node_index: usize) bool {
    if (node_index >= layout.nodes.len) return false;
    var current = layout.nodes[node_index].parent_index;
    while (current) |index| {
        if (index >= layout.nodes.len) return false;
        const node = layout.nodes[index];
        if (widgetKindDisclosureAnimated(node.widget.kind) and !disclosureSettledOpen(layout, index)) return true;
        current = node.parent_index;
    }
    return false;
}

/// The column count a grid lays out, measures, and reports: the DECLARED
/// count when one is set — even when fewer children remain (a filtered
/// grid keeps its column-slot geometry; children fill the leading slots
/// and the trailing slots stay empty, they never stretch to fill missing
/// columns) — and one column per child when unset (the single-row grid).
pub fn gridColumnCount(child_count: usize, requested_columns: usize) usize {
    if (child_count == 0) return 0;
    return if (requested_columns > 0) requested_columns else child_count;
}

pub fn gridRowCount(child_count: usize, columns: usize) usize {
    if (child_count == 0 or columns == 0) return 0;
    return (child_count + columns - 1) / columns;
}

pub fn saturatingU32(value: usize) u32 {
    return if (value > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(value);
}
