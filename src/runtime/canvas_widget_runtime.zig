const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const canvas_limits = @import("canvas_limits.zig");
const platform = @import("../platform/root.zig");

/// Scratch for `RuntimeView.copyWidgetLayoutTree`'s reconcile pass. Too
/// large for the stack at the 1024-node budget (the semantics array alone
/// is ~270 KiB); the Runtime owns one instance (`canvas_widget_copy_scratch`)
/// and the single-threaded event loop makes sharing it safe.
pub const CanvasWidgetCopyScratch = struct {
    source_semantics: [canvas_limits.max_canvas_widget_semantics_per_view]canvas.WidgetSemanticsNode = undefined,
    control_entries: [canvas_limits.max_canvas_widget_nodes_per_view]CanvasWidgetControlReconcileEntry = undefined,
    scroll_entries: [canvas_limits.max_canvas_widget_nodes_per_view]CanvasWidgetScrollReconcileEntry = undefined,
    text_entries: [canvas_limits.max_canvas_widget_nodes_per_view]CanvasWidgetTextReconcileEntry = undefined,
    text_bytes: [canvas_limits.max_canvas_widget_text_bytes_per_view]u8 = undefined,
};

const GpuSurfaceInputEvent = platform.GpuSurfaceInputEvent;

// -------------------------------------------------- reconcile id index
//
// The widget reconcile answers "what did the previous rebuild retain for
// this id?" once per node, against entry lists that scale with the view
// (control entries, source-control entries, source semantics, text
// entries). Linear scans made every rebuild O(n^2) at the 1024-node
// budget — the same shape the frame planners had before
// `plan_key_index` (see that file), and the same fix applies: an
// open-addressing probe table of entry indices whose chain preserves
// insertion order, so lookups return exactly what the scans returned
// (the lowest-index entry matching the caller's predicate). Outputs are
// byte-identical by construction; only the search cost changes.
const plan_key_index = canvas.plan_key_index;

/// Slot count sized for the per-view widget budgets (1024 nodes /
/// semantics entries) at the probe table's half-full bound.
const widget_id_index_slots = 2048;

/// Probe-table index over any entry slice keyed by an `id` field.
/// `build` decides per input whether the table pays for its reset
/// (`plan_key_index.min_entries_for_index`) and fits the half-full
/// bound; otherwise lookups keep the original linear scans, so small
/// views (the chart-tick floor) and oversized library inputs are
/// untouched.
pub fn CanvasWidgetIdIndex(comptime Entry: type) type {
    return struct {
        const Self = @This();
        const Slots = plan_key_index.HashSlots(widget_id_index_slots);

        table: Slots = .{},
        entries: []const Entry = &.{},
        indexed: bool = false,

        pub fn build(self: *Self, entries: []const Entry) void {
            self.entries = entries;
            self.indexed = entries.len >= plan_key_index.min_entries_for_index and
                plan_key_index.fitsHashSlots(widget_id_index_slots, entries.len);
            if (!self.indexed) return;
            self.table.reset();
            for (entries, 0..) |entry, index| {
                if (entry.id == 0) continue;
                var probe = Slots.probe(plan_key_index.mixHash(entry.id));
                while (self.table.next(&probe)) |_| {}
                self.table.insert(probe, @intCast(index));
            }
        }

        /// Lowest-index entry with this id — exactly the linear scan's
        /// result (probe chains preserve insertion order; id-0 entries
        /// can never match because id-0 queries return null up front,
        /// matching every existing scan's contract).
        pub fn first(self: *const Self, id: canvas.ObjectId) ?*const Entry {
            if (id == 0) return null;
            if (!self.indexed) {
                for (self.entries) |*entry| {
                    if (entry.id == id) return entry;
                }
                return null;
            }
            var probe = Slots.probe(plan_key_index.mixHash(id));
            while (self.table.next(&probe)) |candidate| {
                if (self.entries[candidate].id == id) return &self.entries[candidate];
            }
            return null;
        }

        /// Lowest-index entry matching id AND kind — the two-field scan
        /// predicate some reconcile passes use. Walks the whole probe
        /// chain, so even (invalid) duplicate-id inputs resolve exactly
        /// as the scan would.
        pub fn firstWithKind(self: *const Self, id: canvas.ObjectId, kind: canvas.WidgetKind) ?*const Entry {
            if (id == 0) return null;
            if (!self.indexed) {
                for (self.entries) |*entry| {
                    if (entry.id == id and entry.kind == kind) return entry;
                }
                return null;
            }
            var probe = Slots.probe(plan_key_index.mixHash(id));
            while (self.table.next(&probe)) |candidate| {
                const entry = &self.entries[candidate];
                if (entry.id == id and entry.kind == kind) return entry;
            }
            return null;
        }
    };
}

pub const CanvasWidgetControlEntryIndex = CanvasWidgetIdIndex(CanvasWidgetControlReconcileEntry);
pub const CanvasWidgetSourceControlEntryIndex = CanvasWidgetIdIndex(CanvasWidgetSourceControlEntry);
pub const CanvasWidgetTextEntryIndex = CanvasWidgetIdIndex(CanvasWidgetTextReconcileEntry);
pub const CanvasWidgetSemanticsIndex = CanvasWidgetIdIndex(canvas.WidgetSemanticsNode);

/// Shared per-pass index scratch (~8 KiB of slots per table). The two
/// reconcile passes per rebuild (the staged reconcile, then the retained
/// copy) run back-to-back on the single-threaded event loop and each
/// rebuilds every table it uses, so one per-thread set serves both —
/// the same pattern as the planners' probe-table scratch. Lazily
/// heap-allocated (~32 KiB) on a thread's first reconcile, so threads
/// that never reconcile widgets never carry it in their static TLS
/// block.
pub const canvas_widget_reconcile_index_scratch = canvas.lazy_tls.LazyTls(CanvasWidgetReconcileIndexScratch);

pub const CanvasWidgetReconcileIndexScratch = struct {
    controls: CanvasWidgetControlEntryIndex = .{},
    source_controls: CanvasWidgetSourceControlEntryIndex = .{},
    texts: CanvasWidgetTextEntryIndex = .{},
    semantics: CanvasWidgetSemanticsIndex = .{},
};

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

pub const CanvasWidgetSourceScrollEntry = struct {
    id: canvas.ObjectId = 0,
    value: f32 = 0,
};

pub fn canvasWidgetSourceScrollById(entries: []const CanvasWidgetSourceScrollEntry, id: canvas.ObjectId) ?f32 {
    for (entries) |entry| {
        if (entry.id == id) return entry.value;
    }
    return null;
}

/// Scroll offsets and split fractions share the entry shape (id +
/// value) and the source-wins reconcile rule, so one collector serves
/// both.
pub fn canvasWidgetSourceValueKind(kind: canvas.WidgetKind) bool {
    return kind == .scroll_view or kind == .split;
}

pub fn collectCanvasWidgetScrollOffsetEntries(
    nodes: []const canvas.WidgetLayoutNode,
    output: []CanvasWidgetSourceScrollEntry,
) []const CanvasWidgetSourceScrollEntry {
    var len: usize = 0;
    for (nodes) |node| {
        if (!canvasWidgetSourceValueKind(node.widget.kind) or node.widget.id == 0) continue;
        if (len >= output.len) break;
        output[len] = .{ .id = node.widget.id, .value = node.widget.value };
        len += 1;
    }
    return output[0..len];
}

/// Scroll offsets follow the text-editing reconcile rule: the runtime-owned
/// offset (user scrolling) survives rebuilds as long as the SOURCE offset is
/// unchanged; a source-side change (programmatic scroll) wins. Runs as a
/// staged pass over the laid-out nodes because restoring the offset must
/// also TRANSLATE the region's descendants: the flex pass laid them out at
/// the source offset, and a value-only restore would render one whole
/// rebuild at the wrong scroll position (content snapped to the source
/// offset while the offset of record — and the scrollbar — stayed put).
pub fn restoreCanvasWidgetLayoutScrollOffsets(
    nodes: []canvas.WidgetLayoutNode,
    previous_runtime_offsets: []const CanvasWidgetSourceScrollEntry,
    previous_source_offsets: []const CanvasWidgetSourceScrollEntry,
) void {
    for (nodes, 0..) |node, index| {
        if (node.widget.kind != .scroll_view or node.widget.id == 0) continue;
        const previous_runtime = canvasWidgetSourceScrollById(previous_runtime_offsets, node.widget.id) orelse continue;
        const previous_source = canvasWidgetSourceScrollById(previous_source_offsets, node.widget.id) orelse continue;
        if (node.widget.value != previous_source) continue;
        if (node.widget.value == previous_runtime) continue;
        const laid_out = node.widget.value;
        nodes[index].widget.value = previous_runtime;
        translateCanvasWidgetLayoutScrollDescendants(nodes, index, -(previous_runtime - laid_out));
    }
}

pub const CanvasWidgetSourceTextEntry = struct {
    id: canvas.ObjectId = 0,
    kind: canvas.WidgetKind = .text_field,
    text_len: usize = 0,
    text_hash: u64 = 0,
};

/// The SOURCE-side selected state (and value, for sliders) of one
/// control on the previous rebuild, kept per view so the control
/// reconcile can tell a model-driven (controlled) widget from an
/// uncontrolled one.
pub const CanvasWidgetSourceControlEntry = struct {
    id: canvas.ObjectId = 0,
    kind: canvas.WidgetKind = .toggle_button,
    selected: bool = false,
    value: f32 = 0,
};

/// Which control kinds track their SOURCE state across rebuilds.
/// `toggle_button`: chips are the one boolean control whose retained
/// toggle fights model-driven exclusive groups. `slider`: the one
/// continuous control whose retained value fights a model-driven value
/// (progress-style sliders) — it follows the scroll reconcile rule
/// (source-side change wins, otherwise the retained drag survives).
/// The exclusive selectables (list/menu/data/segment rows, radios —
/// tree rows included when they are one of these kinds) follow the
/// slider rule for their SELECTED bool: a source-side flip wins (an
/// explicit `selected = false` after the model moved its selection
/// clears the retained wash), while a static source keeps the retained
/// (pointer-driven) selection. Toggles/checkboxes keep the
/// retained-wins contract locked by the control reconcile tests.
pub fn canvasWidgetSourceControlKind(kind: canvas.WidgetKind) bool {
    // `accordion`: disclosure state tracks its source so a model-driven
    // open/close (a flip, not a replay) wins reconcile — and arms the
    // disclosure tween.
    return kind == .toggle_button or kind == .slider or kind == .accordion or canvasWidgetSelectionClearsSiblings(kind);
}

pub fn collectCanvasWidgetSourceControlEntries(
    nodes: []const canvas.WidgetLayoutNode,
    output: []CanvasWidgetSourceControlEntry,
) []const CanvasWidgetSourceControlEntry {
    var len: usize = 0;
    for (nodes) |node| {
        if (node.widget.id == 0 or !canvasWidgetSourceControlKind(node.widget.kind)) continue;
        if (len >= output.len) break;
        output[len] = .{
            .id = node.widget.id,
            .kind = node.widget.kind,
            .selected = canvasWidgetBooleanSelected(node.widget),
            .value = node.widget.value,
        };
        len += 1;
    }
    return output[0..len];
}

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
    var current: usize = node_index;
    while (true) {
        // Anchored floating widgets escape ancestor clip regions (they
        // render in the hoisted window-level pass).
        if (canvas.widgetIsAnchored(layout.nodes[current].widget)) return true;
        const index = layout.nodes[current].parent_index orelse return true;
        if (index >= layout.nodes.len) return true;
        const ancestor = layout.nodes[index];
        if (canvasWidgetClipsContent(ancestor.widget) and geometry.RectF.intersection(frame, ancestor.frame.normalized()).isEmpty()) return false;
        current = index;
    }
}

pub fn canvasWidgetLayoutNodeClippedBounds(layout: canvas.WidgetLayoutTree, node_index: usize, bounds: geometry.RectF) ?geometry.RectF {
    if (node_index >= layout.nodes.len) return null;
    if (canvasWidgetLayoutNodeHidden(layout, node_index)) return null;

    var clipped = bounds.normalized();
    if (clipped.isEmpty()) return null;

    var current: usize = node_index;
    while (true) {
        // Anchored floating widgets escape ancestor clip regions, so
        // dirty bounds under them clip to the window only.
        if (canvas.widgetIsAnchored(layout.nodes[current].widget)) break;
        const index = layout.nodes[current].parent_index orelse break;
        if (index >= layout.nodes.len) return null;
        const ancestor = layout.nodes[index];
        if (canvasWidgetClipsContent(ancestor.widget)) {
            clipped = geometry.RectF.intersection(clipped, ancestor.frame.normalized());
            if (clipped.isEmpty()) return null;
        }
        current = index;
    }
    return clipped;
}

pub fn canvasWidgetClipsContent(widget: canvas.Widget) bool {
    return widget.kind == .scroll_view or widget.layout.clip_content;
}

pub fn canvasWidgetRuntimeHitTarget(widget: canvas.Widget) bool {
    // Widget-level hit-target-ness lives in one place (canvas
    // widget_access.zig: kind predicate plus bound press/toggle handlers)
    // so the runtime, the engines' hit test, and the markup validation of
    // pointer handlers can never drift.
    return canvas.widgetIsHitTarget(widget);
}

/// A dismissed floating/dismissible surface: the structural id (for the
/// `canvas_widget_dismiss` app event that lets a TEA model own the close)
/// plus the dirty bounds to invalidate. The engine-side hide is the
/// optimistic echo; the source tree is truth on the next rebuild.
pub const CanvasWidgetSurfaceDismissal = struct {
    id: canvas.ObjectId,
    dirty: geometry.RectF,
};

pub fn canvasWidgetDismissibleSurfaceKind(kind: canvas.WidgetKind) bool {
    // Single source of truth in canvas widget_access.zig, shared with the
    // semantics layer's `dismiss` action and the builder's on_dismiss
    // teaching warning.
    return canvas.widgetKindDismissibleSurface(kind);
}

pub fn canvasWidgetEditableTextKind(kind: canvas.WidgetKind) bool {
    return kind == .input or kind == .text_field or kind == .search_field or kind == .combobox or kind == .textarea;
}

/// Clipboard paste text sanitized for the target kind and then clamped
/// to what the view's shared widget text storage can absorb (the bytes
/// the edit replaces are freed first). Clamping lands on a UTF-8
/// boundary; `truncated` is the loud flag the runtime forwards to apps
/// on the keyboard event.
pub const CanvasWidgetPasteClamp = struct {
    text: []const u8 = "",
    truncated: bool = false,
};

pub fn clampCanvasWidgetPasteText(widget: canvas.Widget, view_text_len: usize, text: []const u8) CanvasWidgetPasteClamp {
    // Sanitize BEFORE clamping — the shared step for BOTH paste entry
    // points (the cmd+V shortcut and the context-menu Paste). A
    // single-line target strips \r/\n at the edit-derivation seam
    // anyway, so capacity must be measured against the bytes that
    // actually land: clamping the raw clipboard first discarded valid
    // suffix text near the limit ("a\nbc" into 3 free bytes clamped to
    // "a\nb" and then sanitized to "ab", when the sanitized "abc" fits
    // whole). The stamped edit is the post-clamp bytes, so the retained
    // editor and the app's `on_input` mirror still hear identically —
    // the seam's re-sanitize is a no-op on already-stripped text. A
    // paste that sanitizes to nothing clamps to nothing; that is the
    // sanitize rule speaking, NOT capacity, so `truncated` stays false.
    const sanitized = if (canvas.sanitizedSingleLineTextInputEvent(widget.kind, .{ .insert_text = text })) |event|
        event.insert_text
    else
        return .{};
    const capacity = @import("canvas_limits.zig").max_canvas_widget_text_bytes_per_view;
    const replaced_len = blk: {
        if (widget.text_composition) |composition| break :blk composition.byteLen(widget.text.len);
        if (canvas.widgetTextSelectionRange(widget)) |range| break :blk range.byteLen(widget.text.len);
        break :blk 0;
    };
    const used = view_text_len -| replaced_len;
    const available = capacity -| used;
    if (sanitized.len <= available) return .{ .text = sanitized };
    const clamped = canvas.snapTextOffset(sanitized, available);
    return .{ .text = sanitized[0..clamped], .truncated = true };
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
        if (node.widget.id == 0 or !canvasWidgetTextReconcileKind(node.widget)) continue;
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

/// Which widgets the text reconcile pass tracks across rebuilds: every
/// editable text input, plus static `.text` widgets that currently carry
/// a selection (bounded to the view's single static selection, so the
/// reconcile text storage never inflates for text-heavy views).
fn canvasWidgetTextReconcileKind(widget: canvas.Widget) bool {
    if (canvasWidgetEditableTextKind(widget.kind)) return true;
    if (widget.kind != .text) return false;
    const selection = widget.text_selection orelse return false;
    return !selection.isCollapsed(widget.text.len);
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
    previous: *const CanvasWidgetControlEntryIndex,
    previous_source_controls: *const CanvasWidgetSourceControlEntryIndex,
) canvas.WidgetLayoutNode {
    var copy = node;
    if (copy.widget.id == 0 or !canvasWidgetRuntimeControlKind(copy.widget.kind)) return copy;
    if (copy.widget.state.disabled or canvasWidgetLayoutNodeHidden(layout, node_index)) return copy;

    if (previous.firstWithKind(copy.widget.id, copy.widget.kind)) |entry| {
        switch (copy.widget.kind) {
            .toggle_button => {
                // Chips: a toggle-button whose SOURCE asserts
                // selected — on this rebuild, or on the previous one
                // (tracked in the view's source control entries) — is
                // model-driven, and the source wins over the retained
                // toggle, so an exclusive chip group shows exactly the
                // model's selection instead of every chip ever pressed.
                // Only a toggle-button whose source has stayed
                // unselected keeps the retained (uncontrolled) state.
                const source_selected = canvasWidgetBooleanSelected(copy.widget);
                const previously_selected = if (previous_source_controls.firstWithKind(copy.widget.id, copy.widget.kind)) |source_entry|
                    source_entry.selected
                else
                    false;
                const selected = if (source_selected or previously_selected)
                    source_selected
                else
                    entry.state.selected or entry.value >= 0.5;
                copy.widget.state.selected = selected;
                copy.widget.value = if (selected) 1 else 0;
            },
            .checkbox, .switch_control, .toggle => {
                const selected = entry.state.selected or entry.value >= 0.5;
                copy.widget.state.selected = selected;
                copy.widget.value = if (selected) 1 else 0;
            },
            .accordion => {
                // Disclosure state follows the exclusive-selectable
                // reconcile rule: a source-side FLIP wins — a model
                // that opens or closes a section programmatically (an
                // "expand all" affordance, deep-link restore) must see
                // it land — while a source replaying the same value
                // keeps the retained (pointer-driven) state, so
                // uncontrolled accordions keep working with zero app
                // wiring. The flip is also what arms the default-on
                // disclosure tween in `setCanvasWidgetLayout`.
                const source_selected = canvasWidgetBooleanSelected(copy.widget);
                const previous_source = previous_source_controls.firstWithKind(copy.widget.id, copy.widget.kind);
                const source_moved = if (previous_source) |source_entry| source_selected != source_entry.selected else false;
                const selected = if (source_moved)
                    source_selected
                else
                    entry.state.selected or entry.value >= 0.5;
                copy.widget.state.selected = selected;
                copy.widget.value = if (selected) 1 else 0;
            },
            .slider => {
                // Sliders follow the scroll reconcile rule: the
                // runtime-owned value (a user drag) survives rebuilds
                // only while the SOURCE value is unchanged; a
                // source-side move (a model-driven value — playback
                // progress, a synced setting) wins. A slider whose
                // source never moves keeps the retained (uncontrolled)
                // contract, and a LIVE drag always keeps the thumb —
                // a mid-gesture source tick must not yank it.
                const previous_source = previous_source_controls.firstWithKind(copy.widget.id, copy.widget.kind);
                const source_moved = if (previous_source) |source_entry|
                    copy.widget.value != source_entry.value
                else
                    false;
                if (!source_moved or entry.state.pressed) copy.widget.value = entry.value;
                copy.widget.value = std.math.clamp(copy.widget.value, 0, 1);
            },
            .resizable => {
                const width = @max(canvasWidgetResizableMinWidth(copy.widget), entry.value);
                copy.frame.width = width;
                copy.widget.frame.width = width;
            },
            .radio, .list_item, .menu_item, .data_cell, .segmented_control => {
                // Exclusive selectables follow the slider/scroll
                // reconcile rule on their selected bool: a source-side
                // FLIP wins — a model that moved its selection clears
                // the old row's retained wash with an explicit
                // `selected = false` and lights the new one — while a
                // source that replays the same value keeps the retained
                // (pointer-driven) selection, so uncontrolled lists and
                // trees keep working with zero app wiring.
                const source_selected = canvasWidgetBooleanSelected(copy.widget);
                const previous_source = previous_source_controls.firstWithKind(copy.widget.id, copy.widget.kind);
                const source_moved = if (previous_source) |source_entry| source_selected != source_entry.selected else false;
                const selected = if (source_moved)
                    source_selected
                else
                    entry.state.selected or entry.value >= 0.5;
                copy.widget.state.selected = selected;
                copy.widget.value = if (selected) 1 else 0;
            },
            else => {},
        }
    }
    return copy;
}

pub fn canvasWidgetLayoutNodeWithTextReconcileState(
    node: canvas.WidgetLayoutNode,
    layout: canvas.WidgetLayoutTree,
    node_index: usize,
    previous: *const CanvasWidgetTextEntryIndex,
) canvas.WidgetLayoutNode {
    var copy = node;
    if (copy.widget.id == 0) return copy;
    if (copy.widget.state.disabled or canvasWidgetLayoutNodeHidden(layout, node_index)) return copy;

    if (copy.widget.kind == .text) {
        // Static text selections survive rebuilds only while the source
        // text is byte-identical; changed text drops the selection.
        if (previous.firstWithKind(copy.widget.id, copy.widget.kind)) |entry| {
            if (copy.widget.text_selection == null and std.mem.eql(u8, entry.text, copy.widget.text)) {
                copy.widget.text_selection = entry.text_selection;
            }
        }
        return copy;
    }
    if (!canvasWidgetEditableTextKind(copy.widget.kind)) return copy;

    // NOTE: this pass's scan predicate has a third clause (the
    // source-changed-and-text-diverged entry is SKIPPED, not matched), so
    // the id/kind lookup alone is not the match — but retained trees hold
    // at most one entry per (id, kind) (unique widget ids), so "first
    // id/kind match, then apply the clause" resolves identically to the
    // scan's "first entry passing all clauses".
    if (previous.firstWithKind(copy.widget.id, copy.widget.kind)) |entry| {
        const next_source_text = canvasWidgetSourceTextFingerprint(copy.widget.text);
        const source_unchanged = entry.source_text_len == next_source_text.len and entry.source_text_hash == next_source_text.hash;
        const source_matches_runtime_text = std.mem.eql(u8, entry.text, copy.widget.text);
        if (!source_unchanged and !source_matches_runtime_text) return copy;
        if (source_unchanged) copy.widget.text = entry.text;
        // The retained scroll offset rides `value` for every editable
        // text kind: the textarea's vertical offset and the single-line
        // field's horizontal one both survive rebuilds through this
        // restore (and re-clamp in `clampCanvasWidgetLayoutTextOffsets`
        // right after, so a resized or re-texted field never keeps a
        // stale offset).
        if (canvasWidgetEditableTextKind(copy.widget.kind)) copy.widget.value = entry.value;
        if (copy.widget.text_selection == null and copy.widget.text_composition == null) {
            copy.widget.text_selection = entry.text_selection;
            copy.widget.text_composition = entry.text_composition;
        }
    }
    return copy;
}

fn objectIdInList(ids: []const canvas.ObjectId, id: canvas.ObjectId) bool {
    for (ids) |candidate| {
        if (candidate == id) return true;
    }
    return false;
}

pub fn canvasWidgetLayoutTreeWithRuntimeReconcileState(
    previous: canvas.WidgetLayoutTree,
    next: canvas.WidgetLayoutTree,
    source_semantics: []const canvas.WidgetSemanticsNode,
    previous_source_text_entries: []const CanvasWidgetSourceTextEntry,
    previous_source_scroll_entries: []const CanvasWidgetSourceScrollEntry,
    previous_source_control_entries: []const CanvasWidgetSourceControlEntry,
    node_buffer: []canvas.WidgetLayoutNode,
    control_entries: []CanvasWidgetControlReconcileEntry,
    scroll_offset_entries: []CanvasWidgetSourceScrollEntry,
    text_entries: []CanvasWidgetTextReconcileEntry,
    text_storage: []u8,
    tokens: canvas.DesignTokens,
    armed_split_tween_ids: []const canvas.ObjectId,
    pressed_split_id: canvas.ObjectId,
) anyerror!canvas.WidgetLayoutTree {
    if (next.nodes.len > node_buffer.len) return error.WidgetNodeLimitReached;

    const previous_control_states = collectCanvasWidgetControlReconcileEntries(
        previous.nodes,
        control_entries,
    );
    const previous_runtime_offsets = collectCanvasWidgetScrollOffsetEntries(
        previous.nodes,
        scroll_offset_entries,
    );
    var text_len: usize = 0;
    const previous_text_states = try collectCanvasWidgetTextReconcileEntries(
        previous.nodes,
        previous_source_text_entries,
        text_entries,
        text_storage,
        &text_len,
    );

    // Split fractions reconcile FIRST, as a staged copy of the laid-out
    // tree, so the per-node passes below see final geometry. Outer
    // splits restore before nested ones (ascending node order), so a
    // nested split re-laid (or slid) by its ancestor still restores its
    // own fraction afterwards. Two restore shapes:
    //   - SETTLED runtime-owned fraction (a past drag, no tween in
    //     flight): re-run the split's child layout in place — content
    //     honestly wraps at the restored width;
    //   - TWEEN in flight (armed already, or arming on this rebuild
    //     because the source moved with a nonzero duration): keep the
    //     source's child layout — it is laid at the tween's TARGET
    //     fraction — and slide the pane boundary back geometrically.
    //     Content never re-wraps mid-flight; the pane clip crops the
    //     overflowing side and the tween reveals it one presented
    //     frame at a time (the disclosure doctrine, horizontal).
    const staged_nodes = node_buffer[0..next.nodes.len];
    @memcpy(staged_nodes, next.nodes);
    for (staged_nodes, 0..) |node, index| {
        if (node.widget.kind != .split or node.widget.id == 0) continue;
        const tween_armed = objectIdInList(armed_split_tween_ids, node.widget.id);
        const previous_runtime = canvasWidgetSourceScrollById(previous_runtime_offsets, node.widget.id) orelse {
            // A FRESH split (no retained fraction): a declared enter
            // origin slides the first layout's boundary to the origin
            // pose — children keep the declared value's (target) wrap —
            // so the tween armed right after this reconcile eases it in
            // instead of the mount popping to its value.
            if (node.widget.resize_duration_ms != 0 and node.widget.resize_origin >= 0 and node.widget.children.len != 0) {
                canvas.slideSplitChildren(node.frame, node.widget.resize_origin, index, staged_nodes);
            }
            continue;
        };
        const previous_source = canvasWidgetSourceScrollById(previous_source_scroll_entries, node.widget.id) orelse continue;
        // Source-wins: the runtime-owned fraction survives rebuilds only
        // while the SOURCE fraction is unchanged; a source-side change
        // (the model echoing or driving the fraction) wins — UNLESS the
        // split declares a layout tween (`resize_duration_ms` nonzero)
        // or one is already in flight: then the moved source value is a
        // TARGET, the rendered fraction stays where it is, and the
        // runtime's tween lowering (armed right after this reconcile
        // lands, in setCanvasWidgetLayout) eases it there one presented
        // frame at a time. Reduced motion still snaps: the tween
        // lowering's snap path applies the target through this same
        // mutation family in the same rebuild.
        const source_moved = node.widget.value != previous_source;
        if (source_moved and node.widget.resize_duration_ms == 0 and !tween_armed) continue;
        if (node.widget.value == previous_runtime) continue;
        staged_nodes[index].widget.value = previous_runtime;
        // Retained trees clear children; a split without them keeps the
        // value restore only (frames follow on the next full layout).
        if (node.widget.children.len == 0) continue;
        // A pressed divider is a live drag: its echo rebuilds must keep
        // re-wrapping at the dragged width (the pinned drag behavior),
        // so the slide shape only applies to tween-owned motion.
        const dragging = pressed_split_id != 0 and node.widget.id == pressed_split_id;
        if (!dragging and (tween_armed or (source_moved and node.widget.resize_duration_ms != 0))) {
            canvas.slideSplitChildren(node.frame, previous_runtime, index, staged_nodes);
        } else {
            try canvas.relayoutSplitChildren(staged_nodes[index].widget, node.frame, index, node.depth, node_buffer, tokens);
        }
    }

    // Scroll restore is staged too (after splits, so translated frames
    // are final geometry): the retained offset comes back WITH its
    // descendants translated to match. Engine-side clamping happens at
    // the caller AFTER native scroll drivers are stamped — a rebuild
    // mid-rubber-band must not clamp an offset the OS scroller owns.
    restoreCanvasWidgetLayoutScrollOffsets(staged_nodes, previous_runtime_offsets, previous_source_scroll_entries);

    const index_scratch = canvas_widget_reconcile_index_scratch.get();
    index_scratch.controls.build(previous_control_states);
    index_scratch.source_controls.build(previous_source_control_entries);
    index_scratch.texts.build(previous_text_states);
    index_scratch.semantics.build(source_semantics);

    const staged = canvas.WidgetLayoutTree{ .nodes = staged_nodes };
    for (staged_nodes, 0..) |node, index| {
        const text_copy = canvasWidgetLayoutNodeWithTextReconcileState(node, staged, index, &index_scratch.texts);
        const control_copy = canvasWidgetLayoutNodeWithControlReconcileState(text_copy, staged, index, &index_scratch.controls, &index_scratch.source_controls);
        node_buffer[index] = canvasWidgetLayoutNodeWithSourceSemantics(control_copy, &index_scratch.semantics);
    }
    const reconciled = node_buffer[0..next.nodes.len];
    clampCanvasWidgetLayoutTextOffsets(reconciled, tokens);
    return .{ .nodes = reconciled };
}

pub fn canvasWidgetLayoutNodeWithSourceSemantics(
    node: canvas.WidgetLayoutNode,
    source_semantics: *const CanvasWidgetSemanticsIndex,
) canvas.WidgetLayoutNode {
    var copy = node;
    if (source_semantics.first(node.widget.id)) |semantic_node| {
        if (semantic_node.list.present) {
            copy.widget.semantics.list_item_index = semantic_node.list.item_index;
            copy.widget.semantics.list_item_count = semantic_node.list.item_count;
        }
    }
    return copy;
}

pub fn applyCanvasWidgetSourceScrollSemantics(
    nodes: []canvas.WidgetSemanticsNode,
    source_semantics: *const CanvasWidgetSemanticsIndex,
) void {
    for (nodes) |*node| {
        const source = source_semantics.first(node.id) orelse continue;
        if (!source.scroll.present) continue;
        node.value = source.value;
        node.scroll = source.scroll;
        node.actions = source.actions;
        node.focusable = source.focusable;
    }
}

pub fn clampCanvasWidgetLayoutScrollOffsets(nodes: []canvas.WidgetLayoutNode, states: ?[]canvas.ScrollState) void {
    for (nodes, 0..) |node, index| {
        if (node.widget.kind != .scroll_view) continue;
        // Legacy virtualized containers are model-driven: the source
        // offset is the only channel, so the engine never clamps it.
        // Runtime-scrolled virtual lists (declared item count) clamp
        // like plain scroll views, against the VIRTUAL content extent.
        if (node.widget.layout.virtualized and !canvas.widgetVirtualRuntimeScrolled(node.widget)) continue;
        // Native scroll drivers own clamping: the OS scroller constrains
        // its own contentOffset (including mid-rubber-band rebuilds, which
        // an engine clamp here would fight) and reports the settled offset
        // back through the driver event.
        if (node.widget.native_scroll) continue;

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
        if (node.widget.kind == .textarea) {
            node.widget.value = canvas.clampedTextInputScrollOffsetForWidget(node.widget, tokens, node.widget.value);
            continue;
        }
        if (!canvasWidgetSingleLineTextKind(node.widget.kind)) continue;
        // Single-line fields clamp their horizontal offset against the
        // just-reconciled text and frame, and a field holding a caret
        // also keeps it inside the visible span — this is where a layout
        // width change (a resized window narrowing the field) is first
        // known, so the caret never strands outside the clip after a
        // resize. Deterministic in retained state: the offset only moves
        // when the clamp or the caret demands it.
        node.widget.value = if (node.widget.text_selection != null)
            canvas.textInputCaretVisibleScrollOffsetForWidget(node.widget, tokens, node.widget.value)
        else
            canvas.clampedTextInputHorizontalScrollOffsetForWidget(node.widget, tokens, node.widget.value);
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
    return kind == .switch_control;
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

// ---------------------------------------------------------- tree focus
//
// The ARIA tree's roving focus: rows are widgets carrying
// `role = .treeitem` at ANY depth under the nearest `.tree` ancestor,
// walked in node (DFS) order. Collapsed subtrees are model-owned — the
// view does not render them — so "visible rows" is simply every row in
// the layout that can take focus.

/// Index of the nearest `.tree` ancestor of `node_index`, or null when
/// the node sits outside any tree.
pub fn canvasWidgetTreeScopeIndex(layout: canvas.WidgetLayoutTree, node_index: usize) ?usize {
    if (node_index >= layout.nodes.len) return null;
    var current = layout.nodes[node_index].parent_index;
    while (current) |index| {
        if (index >= layout.nodes.len) return null;
        // A `.tree` container, or any container DECLARING the tree role
        // (a windowed virtual list whose rows are treeitems declares
        // `role = .tree` on the scroll container — there is no room for
        // a nested flow container between the virtualized scroll region
        // and its absolutely-placed rows).
        if (layout.nodes[index].widget.kind == .tree or layout.nodes[index].widget.semantics.role == .tree) return index;
        current = layout.nodes[index].parent_index;
    }
    return null;
}

fn canvasWidgetTreeRowFocusTarget(layout: canvas.WidgetLayoutTree, node_index: usize) ?canvas.WidgetFocusTarget {
    if (layout.nodes[node_index].widget.semantics.role != .treeitem) return null;
    return layout.focusTargetById(layout.nodes[node_index].widget.id);
}

/// The tree keymap's focus moves. Up/Down walk the scope's rows in node
/// order; Home/End jump to its edges; Left moves to the PARENT row when
/// the focused row is a leaf or collapsed (an expanded row collapses
/// instead — no focus move, the routed toggle intent handles it); Right
/// moves to the FIRST CHILD row when the focused row is expanded (a
/// collapsed row expands instead). Null = no tree move (the caller
/// falls through to group/spatial focus).
pub fn canvasWidgetTreeDirectionalFocusTarget(
    layout: canvas.WidgetLayoutTree,
    focused: canvas.WidgetFocusTarget,
    direction: canvas.WidgetFocusDirection,
) ?canvas.WidgetFocusTarget {
    if (focused.index >= layout.nodes.len) return null;
    if (layout.nodes[focused.index].widget.semantics.role != .treeitem) return null;
    const tree_index = canvasWidgetTreeScopeIndex(layout, focused.index) orelse return null;
    return switch (direction) {
        .up => canvasWidgetTreeAdjacentRow(layout, tree_index, focused.index, .previous) orelse focused,
        .down => canvasWidgetTreeAdjacentRow(layout, tree_index, focused.index, .next) orelse focused,
        .left => blk: {
            const expanded = layout.nodes[focused.index].widget.state.expanded orelse false;
            if (expanded) break :blk null; // collapse intent, not a move
            break :blk canvasWidgetTreeParentRow(layout, tree_index, focused.index) orelse focused;
        },
        .right => blk: {
            const expanded = layout.nodes[focused.index].widget.state.expanded orelse false;
            if (!expanded) break :blk null; // expand intent (or leaf no-op)
            break :blk canvasWidgetTreeFirstChildRow(layout, focused.index) orelse focused;
        },
        .forward, .backward => null,
    };
}

/// Home/End inside a tree: the scope's first/last focusable row.
pub fn canvasWidgetTreeFocusEdgeTarget(
    layout: canvas.WidgetLayoutTree,
    focused: canvas.WidgetFocusTarget,
    edge: CanvasWidgetGroupFocusEdge,
) ?canvas.WidgetFocusTarget {
    if (focused.index >= layout.nodes.len) return null;
    if (layout.nodes[focused.index].widget.semantics.role != .treeitem) return null;
    const tree_index = canvasWidgetTreeScopeIndex(layout, focused.index) orelse return null;
    switch (edge) {
        .first => {
            var index = tree_index + 1;
            while (index < layout.nodes.len and layout.nodes[index].depth > layout.nodes[tree_index].depth) : (index += 1) {
                if (canvasWidgetTreeRowFocusTarget(layout, index)) |target| return target;
            }
        },
        .last => {
            var last: ?canvas.WidgetFocusTarget = null;
            var index = tree_index + 1;
            while (index < layout.nodes.len and layout.nodes[index].depth > layout.nodes[tree_index].depth) : (index += 1) {
                if (canvasWidgetTreeRowFocusTarget(layout, index)) |target| last = target;
            }
            return last;
        },
    }
    return null;
}

fn canvasWidgetTreeAdjacentRow(
    layout: canvas.WidgetLayoutTree,
    tree_index: usize,
    focused_index: usize,
    direction: CanvasWidgetGroupDirection,
) ?canvas.WidgetFocusTarget {
    const tree_depth = layout.nodes[tree_index].depth;
    var previous: ?canvas.WidgetFocusTarget = null;
    var saw_focused = false;
    var index = tree_index + 1;
    while (index < layout.nodes.len and layout.nodes[index].depth > tree_depth) : (index += 1) {
        if (index == focused_index) {
            if (direction == .previous) return previous;
            saw_focused = true;
            continue;
        }
        const target = canvasWidgetTreeRowFocusTarget(layout, index) orelse continue;
        if (saw_focused) return target;
        previous = target;
    }
    return null;
}

fn canvasWidgetTreeParentRow(layout: canvas.WidgetLayoutTree, tree_index: usize, focused_index: usize) ?canvas.WidgetFocusTarget {
    var current = layout.nodes[focused_index].parent_index;
    while (current) |index| {
        if (index >= layout.nodes.len or index == tree_index) return null;
        if (canvasWidgetTreeRowFocusTarget(layout, index)) |target| return target;
        current = layout.nodes[index].parent_index;
    }
    return null;
}

fn canvasWidgetTreeFirstChildRow(layout: canvas.WidgetLayoutTree, focused_index: usize) ?canvas.WidgetFocusTarget {
    const row_depth = layout.nodes[focused_index].depth;
    var index = focused_index + 1;
    while (index < layout.nodes.len and layout.nodes[index].depth > row_depth) : (index += 1) {
        if (canvasWidgetTreeRowFocusTarget(layout, index)) |target| return target;
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
