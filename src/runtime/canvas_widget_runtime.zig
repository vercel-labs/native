const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");

const GpuSurfaceInputEvent = platform.GpuSurfaceInputEvent;

fn canvasWidgetSemanticsById(nodes: []const canvas.WidgetSemanticsNode, id: canvas.ObjectId) ?canvas.WidgetSemanticsNode {
    if (id == 0) return null;
    for (nodes) |node| {
        if (node.id == id) return node;
    }
    return null;
}

pub const WidgetTextStorageRange = struct {
    start: usize = 0,
    end: usize = 0,
};

pub const CanvasWidgetScrollReconcileEntry = struct {
    id: canvas.ObjectId = 0,
    state: canvas.ScrollState = .{},
};

pub const CanvasWidgetControlReconcileEntry = struct {
    id: canvas.ObjectId = 0,
    kind: canvas.WidgetKind = .checkbox,
    state: canvas.WidgetState = .{},
    value: f32 = 0,
};

pub const CanvasWidgetTextReconcileEntry = struct {
    id: canvas.ObjectId = 0,
    kind: canvas.WidgetKind = .text_field,
    text: []const u8 = &.{},
    source_text_len: usize = 0,
    source_text_hash: u64 = 0,
    text_selection: ?canvas.TextSelection = null,
    text_composition: ?canvas.TextRange = null,
    value: f32 = 0,
};

pub const CanvasWidgetSourceTextEntry = struct {
    id: canvas.ObjectId = 0,
    kind: canvas.WidgetKind = .text_field,
    text_len: usize = 0,
    text_hash: u64 = 0,
};

pub fn canvasWidgetInteractionTargetExists(layout: canvas.WidgetLayoutTree, id: canvas.ObjectId) bool {
    const index = canvasWidgetLayoutNodeIndexById(layout, id) orelse return false;
    if (canvasWidgetLayoutNodeHidden(layout, index)) return false;
    if (!canvasWidgetLayoutNodeFrameVisible(layout, index)) return false;
    return canvasWidgetRuntimeHitTarget(layout.nodes[index].widget);
}

pub fn canvasWidgetSelectableTargetExists(layout: canvas.WidgetLayoutTree, id: canvas.ObjectId) bool {
    const index = canvasWidgetLayoutNodeIndexById(layout, id) orelse return false;
    if (canvasWidgetLayoutNodeHidden(layout, index)) return false;
    const widget = layout.nodes[index].widget;
    if (widget.id == 0 or widget.state.disabled) return false;
    if (!canvasWidgetSelectionClearsSiblings(widget.kind)) return false;
    return canvasWidgetSelectableTargetFrameAllowed(layout, index);
}

pub fn canvasWidgetSelectableTargetFrameAllowed(layout: canvas.WidgetLayoutTree, node_index: usize) bool {
    if (node_index >= layout.nodes.len) return false;
    const frame = layout.nodes[node_index].frame.normalized();
    if (!frame.isEmpty()) return canvasWidgetLayoutNodeFrameVisible(layout, node_index);

    var current = layout.nodes[node_index].parent_index;
    while (current) |index| {
        if (index >= layout.nodes.len) return true;
        if (canvasWidgetClipsContent(layout.nodes[index].widget)) return false;
        current = layout.nodes[index].parent_index;
    }
    return true;
}

pub fn canvasWidgetLayoutNodeIndexById(layout: canvas.WidgetLayoutTree, id: canvas.ObjectId) ?usize {
    if (id == 0) return null;
    for (layout.nodes, 0..) |node, index| {
        if (node.widget.id == id) return index;
    }
    return null;
}

pub fn canvasWidgetLayoutNodeHidden(layout: canvas.WidgetLayoutTree, node_index: usize) bool {
    var current: ?usize = node_index;
    while (current) |index| {
        if (index >= layout.nodes.len) return false;
        const node = layout.nodes[index];
        if (node.widget.semantics.hidden) return true;
        current = node.parent_index;
    }
    return false;
}

pub fn canvasWidgetLayoutNodeFrameVisible(layout: canvas.WidgetLayoutTree, node_index: usize) bool {
    if (node_index >= layout.nodes.len) return false;
    const frame = layout.nodes[node_index].frame.normalized();
    if (frame.isEmpty()) return false;
    var current = layout.nodes[node_index].parent_index;
    while (current) |index| {
        if (index >= layout.nodes.len) return true;
        const ancestor = layout.nodes[index];
        if (canvasWidgetClipsContent(ancestor.widget) and geometry.RectF.intersection(frame, ancestor.frame.normalized()).isEmpty()) return false;
        current = ancestor.parent_index;
    }
    return true;
}

pub fn canvasWidgetLayoutNodeClippedBounds(layout: canvas.WidgetLayoutTree, node_index: usize, bounds: geometry.RectF) ?geometry.RectF {
    if (node_index >= layout.nodes.len) return null;
    if (canvasWidgetLayoutNodeHidden(layout, node_index)) return null;

    var clipped = bounds.normalized();
    if (clipped.isEmpty()) return null;

    var current = layout.nodes[node_index].parent_index;
    while (current) |index| {
        if (index >= layout.nodes.len) return null;
        const ancestor = layout.nodes[index];
        if (canvasWidgetClipsContent(ancestor.widget)) {
            clipped = geometry.RectF.intersection(clipped, ancestor.frame.normalized());
            if (clipped.isEmpty()) return null;
        }
        current = ancestor.parent_index;
    }
    return clipped;
}

pub fn canvasWidgetClipsContent(widget: canvas.Widget) bool {
    return widget.kind == .scroll_view or widget.layout.clip_content;
}

pub fn canvasWidgetRuntimeHitTarget(widget: canvas.Widget) bool {
    if (widget.id == 0 or widget.state.disabled) return false;
    return switch (widget.kind) {
        .row, .column, .grid, .data_grid, .table, .data_row, .list, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group, .stack, .tooltip, .icon, .image, .avatar, .badge, .separator, .skeleton, .spinner => false,
        .scroll_view, .accordion, .alert, .bubble, .card, .dialog, .drawer, .sheet, .resizable, .panel, .popover, .menu_surface, .dropdown_menu, .text, .button, .toggle_button, .icon_button, .select, .input, .text_field, .search_field, .combobox, .textarea, .menu_item, .list_item, .data_cell, .status_bar, .segmented_control, .checkbox, .radio, .switch_control, .toggle, .slider, .progress => true,
    };
}

pub fn canvasWidgetDismissibleSurfaceKind(kind: canvas.WidgetKind) bool {
    return switch (kind) {
        .dialog,
        .drawer,
        .sheet,
        .popover,
        .menu_surface,
        .dropdown_menu,
        .tooltip,
        => true,
        else => false,
    };
}

pub fn canvasWidgetEditableTextKind(kind: canvas.WidgetKind) bool {
    return kind == .input or kind == .text_field or kind == .search_field or kind == .combobox or kind == .textarea;
}

pub fn canvasWidgetSingleLineTextKind(kind: canvas.WidgetKind) bool {
    return kind == .input or kind == .text_field or kind == .search_field or kind == .combobox;
}

pub fn canvasWidgetScrollableKind(kind: canvas.WidgetKind) bool {
    return kind == .scroll_view or kind == .textarea;
}

pub fn canvasWidgetRuntimeControlKind(kind: canvas.WidgetKind) bool {
    return switch (kind) {
        .accordion,
        .checkbox,
        .radio,
        .switch_control,
        .toggle,
        .toggle_button,
        .slider,
        .resizable,
        .list_item,
        .menu_item,
        .data_cell,
        .segmented_control,
        => true,
        else => false,
    };
}

pub fn canvasWidgetResizableMinWidth(widget: canvas.Widget) f32 {
    return @max(@as(f32, 48), widget.frame.height);
}

pub fn collectCanvasWidgetControlReconcileEntries(
    nodes: []const canvas.WidgetLayoutNode,
    output: []CanvasWidgetControlReconcileEntry,
) []const CanvasWidgetControlReconcileEntry {
    var len: usize = 0;
    for (nodes) |node| {
        if (node.widget.id == 0 or !canvasWidgetRuntimeControlKind(node.widget.kind)) continue;
        if (len >= output.len) break;
        output[len] = .{
            .id = node.widget.id,
            .kind = node.widget.kind,
            .state = node.widget.state,
            .value = if (node.widget.kind == .resizable) node.frame.width else node.widget.value,
        };
        len += 1;
    }
    return output[0..len];
}

pub fn collectCanvasWidgetScrollReconcileEntries(
    nodes: []const canvas.WidgetLayoutNode,
    states: []const canvas.ScrollState,
    output: []CanvasWidgetScrollReconcileEntry,
) []const CanvasWidgetScrollReconcileEntry {
    var len: usize = 0;
    const count = @min(nodes.len, states.len);
    for (nodes[0..count], 0..) |node, index| {
        if (node.widget.kind != .scroll_view or node.widget.id == 0) continue;
        if (len >= output.len) break;
        output[len] = .{ .id = node.widget.id, .state = states[index] };
        len += 1;
    }
    return output[0..len];
}

pub fn canvasWidgetScrollStateForLayoutNode(
    node: canvas.WidgetLayoutNode,
    previous: []const CanvasWidgetScrollReconcileEntry,
) canvas.ScrollState {
    var state = canvas.ScrollState{ .offset = node.widget.value };
    if (node.widget.kind != .scroll_view or node.widget.id == 0) return state;
    for (previous) |entry| {
        if (entry.id == node.widget.id) {
            state.velocity = entry.state.velocity;
            return state;
        }
    }
    return state;
}

pub fn collectCanvasWidgetTextReconcileEntries(
    nodes: []const canvas.WidgetLayoutNode,
    source_entries: []const CanvasWidgetSourceTextEntry,
    output: []CanvasWidgetTextReconcileEntry,
    text_storage: []u8,
    text_len: *usize,
) anyerror![]const CanvasWidgetTextReconcileEntry {
    var len: usize = 0;
    for (nodes) |node| {
        if (node.widget.id == 0 or !canvasWidgetEditableTextKind(node.widget.kind)) continue;
        if (len >= output.len) break;
        const text_range = try appendWidgetTextStorageRange(text_storage, text_len, node.widget.text);
        const source_text = canvasWidgetSourceTextByIdKind(source_entries, node.widget.id, node.widget.kind) orelse canvasWidgetSourceTextFingerprint(node.widget.text);
        output[len] = .{
            .id = node.widget.id,
            .kind = node.widget.kind,
            .text = text_storage[text_range.start..text_range.end],
            .source_text_len = source_text.len,
            .source_text_hash = source_text.hash,
            .text_selection = node.widget.text_selection,
            .text_composition = node.widget.text_composition,
            .value = node.widget.value,
        };
        len += 1;
    }
    return output[0..len];
}

pub const CanvasWidgetSourceTextFingerprint = struct {
    len: usize = 0,
    hash: u64 = 0,
};

pub fn canvasWidgetSourceTextFingerprint(text: []const u8) CanvasWidgetSourceTextFingerprint {
    return .{
        .len = text.len,
        .hash = std.hash.Wyhash.hash(0, text),
    };
}

pub fn canvasWidgetSourceTextByIdKind(
    entries: []const CanvasWidgetSourceTextEntry,
    id: canvas.ObjectId,
    kind: canvas.WidgetKind,
) ?CanvasWidgetSourceTextFingerprint {
    for (entries) |entry| {
        if (entry.id != id or entry.kind != kind) continue;
        return .{
            .len = entry.text_len,
            .hash = entry.text_hash,
        };
    }
    return null;
}

pub fn canvasWidgetLayoutNodeWithControlReconcileState(
    node: canvas.WidgetLayoutNode,
    layout: canvas.WidgetLayoutTree,
    node_index: usize,
    previous: []const CanvasWidgetControlReconcileEntry,
) canvas.WidgetLayoutNode {
    var copy = node;
    if (copy.widget.id == 0 or !canvasWidgetRuntimeControlKind(copy.widget.kind)) return copy;
    if (copy.widget.state.disabled or canvasWidgetLayoutNodeHidden(layout, node_index)) return copy;

    for (previous) |entry| {
        if (entry.id != copy.widget.id or entry.kind != copy.widget.kind) continue;
        switch (copy.widget.kind) {
            .accordion, .checkbox, .switch_control, .toggle, .toggle_button => {
                const selected = entry.state.selected or entry.value >= 0.5;
                copy.widget.state.selected = selected;
                copy.widget.value = if (selected) 1 else 0;
            },
            .slider => {
                copy.widget.value = std.math.clamp(entry.value, 0, 1);
            },
            .resizable => {
                const width = @max(canvasWidgetResizableMinWidth(copy.widget), entry.value);
                copy.frame.width = width;
                copy.widget.frame.width = width;
            },
            .radio, .list_item, .menu_item, .data_cell, .segmented_control => {
                const selected = entry.state.selected or entry.value >= 0.5;
                copy.widget.state.selected = selected;
                copy.widget.value = if (selected) 1 else 0;
            },
            else => {},
        }
        break;
    }
    return copy;
}

pub fn canvasWidgetLayoutNodeWithTextReconcileState(
    node: canvas.WidgetLayoutNode,
    layout: canvas.WidgetLayoutTree,
    node_index: usize,
    previous: []const CanvasWidgetTextReconcileEntry,
) canvas.WidgetLayoutNode {
    var copy = node;
    if (copy.widget.id == 0 or !canvasWidgetEditableTextKind(copy.widget.kind)) return copy;
    if (copy.widget.state.disabled or canvasWidgetLayoutNodeHidden(layout, node_index)) return copy;

    for (previous) |entry| {
        if (entry.id != copy.widget.id or entry.kind != copy.widget.kind) continue;
        const next_source_text = canvasWidgetSourceTextFingerprint(copy.widget.text);
        const source_unchanged = entry.source_text_len == next_source_text.len and entry.source_text_hash == next_source_text.hash;
        const source_matches_runtime_text = std.mem.eql(u8, entry.text, copy.widget.text);
        if (!source_unchanged and !source_matches_runtime_text) continue;
        if (source_unchanged) copy.widget.text = entry.text;
        if (copy.widget.kind == .textarea) copy.widget.value = entry.value;
        if (copy.widget.text_selection == null and copy.widget.text_composition == null) {
            copy.widget.text_selection = entry.text_selection;
            copy.widget.text_composition = entry.text_composition;
        }
        break;
    }
    return copy;
}

pub fn canvasWidgetLayoutTreeWithRuntimeReconcileState(
    previous: canvas.WidgetLayoutTree,
    next: canvas.WidgetLayoutTree,
    source_semantics: []const canvas.WidgetSemanticsNode,
    previous_source_text_entries: []const CanvasWidgetSourceTextEntry,
    node_buffer: []canvas.WidgetLayoutNode,
    control_entries: []CanvasWidgetControlReconcileEntry,
    text_entries: []CanvasWidgetTextReconcileEntry,
    text_storage: []u8,
    tokens: canvas.DesignTokens,
) anyerror!canvas.WidgetLayoutTree {
    if (next.nodes.len > node_buffer.len) return error.WidgetNodeLimitReached;

    const previous_control_states = collectCanvasWidgetControlReconcileEntries(
        previous.nodes,
        control_entries,
    );
    var text_len: usize = 0;
    const previous_text_states = try collectCanvasWidgetTextReconcileEntries(
        previous.nodes,
        previous_source_text_entries,
        text_entries,
        text_storage,
        &text_len,
    );

    for (next.nodes, 0..) |node, index| {
        const text_copy = canvasWidgetLayoutNodeWithTextReconcileState(node, next, index, previous_text_states);
        const control_copy = canvasWidgetLayoutNodeWithControlReconcileState(text_copy, next, index, previous_control_states);
        node_buffer[index] = canvasWidgetLayoutNodeWithSourceSemantics(control_copy, source_semantics);
    }
    const reconciled = node_buffer[0..next.nodes.len];
    clampCanvasWidgetLayoutScrollOffsets(reconciled, null);
    clampCanvasWidgetLayoutTextOffsets(reconciled, tokens);
    return .{ .nodes = reconciled };
}

pub fn canvasWidgetLayoutNodeWithSourceSemantics(
    node: canvas.WidgetLayoutNode,
    source_semantics: []const canvas.WidgetSemanticsNode,
) canvas.WidgetLayoutNode {
    var copy = node;
    if (canvasWidgetSemanticsById(source_semantics, node.widget.id)) |semantic_node| {
        if (semantic_node.list.present) {
            copy.widget.semantics.list_item_index = semantic_node.list.item_index;
            copy.widget.semantics.list_item_count = semantic_node.list.item_count;
        }
    }
    return copy;
}

pub fn applyCanvasWidgetSourceScrollSemantics(
    nodes: []canvas.WidgetSemanticsNode,
    source_semantics: []const canvas.WidgetSemanticsNode,
) void {
    for (nodes) |*node| {
        const source = canvasWidgetSemanticsById(source_semantics, node.id) orelse continue;
        if (!source.scroll.present) continue;
        node.value = source.value;
        node.scroll = source.scroll;
        node.actions = source.actions;
        node.focusable = source.focusable;
    }
}

pub fn clampCanvasWidgetLayoutScrollOffsets(nodes: []canvas.WidgetLayoutNode, states: ?[]canvas.ScrollState) void {
    for (nodes, 0..) |node, index| {
        if (node.widget.kind != .scroll_view or node.widget.layout.virtualized) continue;

        const viewport = node.frame.inset(node.widget.layout.padding).normalized();
        if (viewport.isEmpty()) continue;

        const content_extent = canvasWidgetLayoutScrollContentExtent(nodes, index, viewport);
        const max_offset = @max(0, content_extent - viewport.height);
        const current_offset = node.widget.value;
        const next_offset = std.math.clamp(@max(0, current_offset), 0, max_offset);
        if (next_offset == current_offset) continue;

        const offset_delta = next_offset - current_offset;
        nodes[index].widget.value = next_offset;
        translateCanvasWidgetLayoutScrollDescendants(nodes, index, -offset_delta);
        if (states) |scroll_states| {
            if (index < scroll_states.len) {
                scroll_states[index].offset = next_offset;
                scroll_states[index].velocity = 0;
                scroll_states[index].viewport_extent = viewport.height;
                scroll_states[index].content_extent = content_extent;
            }
        }
    }
}

pub fn clampCanvasWidgetLayoutTextOffsets(nodes: []canvas.WidgetLayoutNode, tokens: canvas.DesignTokens) void {
    for (nodes) |*node| {
        if (node.widget.kind != .textarea) continue;
        node.widget.value = canvas.clampedTextInputScrollOffsetForWidget(node.widget, tokens, node.widget.value);
    }
}

pub fn canvasWidgetLayoutScrollContentExtent(nodes: []const canvas.WidgetLayoutNode, scroll_index: usize, viewport: geometry.RectF) f32 {
    if (scroll_index >= nodes.len) return 0;
    const scroll_node = nodes[scroll_index];
    if (scroll_node.widget.layout.virtualized) {
        return @max(viewport.height, canvas.virtualWidgetScrollContentExtent(scroll_node.widget, viewport.height));
    }
    const scroll_depth = scroll_node.depth;
    const offset = scroll_node.widget.value;
    var bottom = viewport.maxY();
    var index = scroll_index + 1;
    while (index < nodes.len and nodes[index].depth > scroll_depth) : (index += 1) {
        bottom = @max(bottom, nodes[index].frame.maxY() + offset);
    }
    return @max(0, bottom - viewport.y);
}

pub fn translateCanvasWidgetLayoutScrollDescendants(nodes: []canvas.WidgetLayoutNode, scroll_index: usize, dy: f32) void {
    if (scroll_index >= nodes.len) return;
    const scroll_depth = nodes[scroll_index].depth;
    var index = scroll_index + 1;
    while (index < nodes.len and nodes[index].depth > scroll_depth) : (index += 1) {
        nodes[index].frame = nodes[index].frame.translate(geometry.OffsetF.init(0, dy));
        nodes[index].widget.frame = nodes[index].frame;
    }
}

pub fn appendWidgetTextStorageRange(buffer: []u8, len: *usize, value: []const u8) anyerror!WidgetTextStorageRange {
    const end = len.* + value.len;
    if (end > buffer.len) return error.WidgetTextTooLarge;
    const start = len.*;
    @memcpy(buffer[start..end], value);
    len.* = end;
    return .{ .start = start, .end = end };
}

pub fn canvasWidgetTextEditUnchanged(previous: canvas.TextEditState, next: canvas.TextEditState) bool {
    return std.mem.eql(u8, previous.text, next.text) and
        canvasTextSelectionsEqual(previous.selection, next.selection) and
        optionalCanvasTextRangesEqual(previous.composition, next.composition);
}

pub fn canvasTextSelectionsEqual(a: canvas.TextSelection, b: canvas.TextSelection) bool {
    return a.anchor == b.anchor and a.focus == b.focus;
}

pub fn textSelectionCollapsedAt(selection: ?canvas.TextSelection, offset: usize) bool {
    const value = selection orelse return true;
    return value.anchor == offset and value.focus == offset;
}

pub fn optionalCanvasTextRangesEqual(a: ?canvas.TextRange, b: ?canvas.TextRange) bool {
    if (a) |left| {
        if (b) |right| return left.start == right.start and left.end == right.end;
        return false;
    }
    return b == null;
}

pub fn canvasWidgetCommandable(kind: canvas.WidgetKind) bool {
    return switch (kind) {
        .accordion, .button, .toggle_button, .icon_button, .select, .combobox, .menu_item, .list_item, .data_cell, .segmented_control, .checkbox, .radio, .switch_control, .toggle => true,
        else => false,
    };
}

pub fn canvasWidgetCommandFiresOnPointerDown(kind: canvas.WidgetKind) bool {
    return switch (kind) {
        .select, .combobox => true,
        else => false,
    };
}

pub fn canvasWidgetBooleanSelected(widget: canvas.Widget) bool {
    return widget.state.selected or widget.value >= 0.5;
}

pub fn canvasWidgetSwitchControlKind(kind: canvas.WidgetKind) bool {
    return kind == .switch_control or kind == .toggle;
}

pub fn canvasWidgetSelectableSelected(widget: canvas.Widget) bool {
    return widget.state.selected or widget.value >= 0.5;
}

pub fn canvasWidgetSelectionClearsSiblings(kind: canvas.WidgetKind) bool {
    return switch (kind) {
        .list_item, .menu_item, .data_cell, .segmented_control, .radio => true,
        else => false,
    };
}

pub fn canvasWidgetKineticScrollFrameMs(frame_interval_ns: u64) f32 {
    const normalized = if (frame_interval_ns > 0) frame_interval_ns else platform.default_gpu_frame_interval_ns;
    return @as(f32, @floatFromInt(normalized)) / 1_000_000.0;
}

pub const CanvasWidgetScrollKeyboardTarget = enum {
    start,
    end,
};

pub const CanvasWidgetStepDirection = enum {
    increment,
    decrement,
};

pub const CanvasWidgetGroupFocusEdge = enum {
    first,
    last,
};

pub fn canvasWidgetGroupFocusEdgeFromInput(input_event: GpuSurfaceInputEvent) ?CanvasWidgetGroupFocusEdge {
    if (input_event.kind != .key_down) return null;
    if (input_event.modifiers.control or input_event.modifiers.option or input_event.modifiers.command or input_event.modifiers.primary or input_event.modifiers.shift) return null;
    if (std.ascii.eqlIgnoreCase(input_event.key, "home")) return .first;
    if (std.ascii.eqlIgnoreCase(input_event.key, "end")) return .last;
    return null;
}

pub fn canvasWidgetSpatialFocusDirection(input_event: GpuSurfaceInputEvent) ?canvas.WidgetFocusDirection {
    if (input_event.kind != .key_down) return null;
    if (input_event.modifiers.control or input_event.modifiers.option or input_event.modifiers.command or input_event.modifiers.primary) return null;
    if (std.ascii.eqlIgnoreCase(input_event.key, "arrowleft")) return .left;
    if (std.ascii.eqlIgnoreCase(input_event.key, "arrowright")) return .right;
    if (std.ascii.eqlIgnoreCase(input_event.key, "arrowup")) return .up;
    if (std.ascii.eqlIgnoreCase(input_event.key, "arrowdown")) return .down;
    return null;
}

pub fn canvasWidgetSpatialFocusAllowed(layout: canvas.WidgetLayoutTree, focused: canvas.WidgetFocusTarget, target: canvas.WidgetFocusTarget, direction: canvas.WidgetFocusDirection) bool {
    if (focused.kind != target.kind) return false;
    const same_parent = canvasWidgetFocusTargetsShareParent(layout, focused, target);
    return switch (focused.kind) {
        .data_cell => true,
        .list_item, .menu_item => same_parent and (direction == .up or direction == .down),
        .segmented_control => same_parent and (direction == .left or direction == .right),
        .radio => same_parent,
        .button, .icon_button => same_parent and canvasWidgetParentAllowsHorizontalButtonFocus(canvasWidgetFocusParentKind(layout, focused)) and (direction == .left or direction == .right),
        .toggle_button => same_parent and canvasWidgetParentAllowsHorizontalToggleFocus(canvasWidgetFocusParentKind(layout, focused)) and (direction == .left or direction == .right),
        else => false,
    };
}

pub fn canvasWidgetFocusTargetsShareParent(layout: canvas.WidgetLayoutTree, a: canvas.WidgetFocusTarget, b: canvas.WidgetFocusTarget) bool {
    if (a.index >= layout.nodes.len or b.index >= layout.nodes.len) return false;
    return layout.nodes[a.index].parent_index == layout.nodes[b.index].parent_index;
}

pub fn canvasWidgetFocusParentKind(layout: canvas.WidgetLayoutTree, target: canvas.WidgetFocusTarget) ?canvas.WidgetKind {
    if (target.index >= layout.nodes.len) return null;
    const parent_index = layout.nodes[target.index].parent_index orelse return null;
    if (parent_index >= layout.nodes.len) return null;
    return layout.nodes[parent_index].widget.kind;
}

pub fn canvasWidgetParentAllowsHorizontalButtonFocus(kind: ?canvas.WidgetKind) bool {
    return switch (kind orelse return false) {
        .button_group, .pagination, .breadcrumb => true,
        else => false,
    };
}

pub fn canvasWidgetParentAllowsHorizontalToggleFocus(kind: ?canvas.WidgetKind) bool {
    return switch (kind orelse return false) {
        .button_group, .toggle_group => true,
        else => false,
    };
}

pub fn canvasWidgetGroupHomeEndFocusKind(layout: canvas.WidgetLayoutTree, target: canvas.WidgetFocusTarget) bool {
    const kind = target.kind;
    return switch (kind) {
        .list_item, .menu_item, .data_cell, .segmented_control, .radio => true,
        .button, .icon_button => canvasWidgetParentAllowsHorizontalButtonFocus(canvasWidgetFocusParentKind(layout, target)),
        .toggle_button => canvasWidgetParentAllowsHorizontalToggleFocus(canvasWidgetFocusParentKind(layout, target)),
        else => false,
    };
}

pub const CanvasWidgetGroupDirection = enum {
    previous,
    next,
};

pub fn canvasWidgetGroupDirectionalFocusTarget(layout: canvas.WidgetLayoutTree, focused: canvas.WidgetFocusTarget, direction: canvas.WidgetFocusDirection) ?canvas.WidgetFocusTarget {
    if (focused.index >= layout.nodes.len) return null;
    const parent_index = layout.nodes[focused.index].parent_index orelse return null;
    if (parent_index >= layout.nodes.len) return null;
    const parent_kind = layout.nodes[parent_index].widget.kind;
    const group_direction = canvasWidgetGroupDirectionForFocus(parent_kind, focused.kind, direction) orelse return null;
    return canvasWidgetAdjacentGroupFocusTarget(layout, parent_index, focused, group_direction) orelse focused;
}

pub fn canvasWidgetGroupDirectionForFocus(parent_kind: canvas.WidgetKind, child_kind: canvas.WidgetKind, direction: canvas.WidgetFocusDirection) ?CanvasWidgetGroupDirection {
    return switch (parent_kind) {
        .button_group, .pagination, .breadcrumb => if (child_kind == .button or child_kind == .icon_button)
            canvasWidgetHorizontalGroupDirection(direction)
        else
            null,
        .toggle_group => if (child_kind == .toggle_button)
            canvasWidgetHorizontalGroupDirection(direction)
        else
            null,
        .tabs => if (child_kind == .segmented_control)
            canvasWidgetHorizontalGroupDirection(direction)
        else
            null,
        .radio_group => if (child_kind == .radio)
            canvasWidgetAnyAxisGroupDirection(direction)
        else
            null,
        .list => if (child_kind == .list_item)
            canvasWidgetVerticalGroupDirection(direction)
        else
            null,
        .menu_surface, .dropdown_menu => if (child_kind == .menu_item)
            canvasWidgetVerticalGroupDirection(direction)
        else
            null,
        else => null,
    };
}

pub fn canvasWidgetHorizontalGroupDirection(direction: canvas.WidgetFocusDirection) ?CanvasWidgetGroupDirection {
    return switch (direction) {
        .left => .previous,
        .right => .next,
        .up, .down, .forward, .backward => null,
    };
}

pub fn canvasWidgetVerticalGroupDirection(direction: canvas.WidgetFocusDirection) ?CanvasWidgetGroupDirection {
    return switch (direction) {
        .up => .previous,
        .down => .next,
        .left, .right, .forward, .backward => null,
    };
}

pub fn canvasWidgetAnyAxisGroupDirection(direction: canvas.WidgetFocusDirection) ?CanvasWidgetGroupDirection {
    return switch (direction) {
        .left, .up => .previous,
        .right, .down => .next,
        .forward, .backward => null,
    };
}

pub fn canvasWidgetAdjacentGroupFocusTarget(
    layout: canvas.WidgetLayoutTree,
    parent_index: usize,
    focused: canvas.WidgetFocusTarget,
    direction: CanvasWidgetGroupDirection,
) ?canvas.WidgetFocusTarget {
    var previous: ?canvas.WidgetFocusTarget = null;
    var saw_focused = false;
    for (layout.nodes) |node| {
        if (node.parent_index != parent_index or node.widget.kind != focused.kind) continue;
        const target = layout.focusTargetById(node.widget.id) orelse continue;
        if (saw_focused) return target;
        if (target.id == focused.id) {
            if (direction == .previous) return previous;
            saw_focused = true;
        } else {
            previous = target;
        }
    }
    return null;
}

pub fn canvasWidgetGroupFocusEdgeTarget(layout: canvas.WidgetLayoutTree, focused: canvas.WidgetFocusTarget, edge: CanvasWidgetGroupFocusEdge) ?canvas.WidgetFocusTarget {
    if (!canvasWidgetGroupHomeEndFocusKind(layout, focused)) return null;
    if (focused.index >= layout.nodes.len) return null;
    const parent_index = layout.nodes[focused.index].parent_index;
    switch (edge) {
        .first => {
            for (layout.nodes) |node| {
                if (node.parent_index != parent_index or node.widget.kind != focused.kind) continue;
                if (layout.focusTargetById(node.widget.id)) |target| return target;
            }
        },
        .last => {
            var index = layout.nodes.len;
            while (index > 0) {
                index -= 1;
                const node = layout.nodes[index];
                if (node.parent_index != parent_index or node.widget.kind != focused.kind) continue;
                if (layout.focusTargetById(node.widget.id)) |target| return target;
            }
        },
    }
    return null;
}
