const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");
const validation = @import("validation.zig");
const runtime_api = @import("api.zig");
const canvas_limits = @import("canvas_limits.zig");
const canvas_frame_helpers = @import("canvas_frame.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");
const runtime_canvas_widget_display = @import("canvas_widget_display.zig");
const runtime_canvas_widget_events = @import("canvas_widget_events.zig");
const runtime_automation_widget_dispatch = @import("automation_widget_dispatch.zig");
const widget_bridge = @import("widget_bridge.zig");

const validateViewLabel = validation.validateViewLabel;
const max_canvas_widget_nodes_per_view = canvas_limits.max_canvas_widget_nodes_per_view;
const max_canvas_widget_semantics_per_view = canvas_limits.max_canvas_widget_semantics_per_view;
const max_canvas_widget_text_bytes_per_view = canvas_limits.max_canvas_widget_text_bytes_per_view;
const max_canvas_widget_invalidations_per_view = canvas_limits.max_canvas_widget_invalidations_per_view;
const CanvasWidgetControlReconcileEntry = canvas_widget_runtime.CanvasWidgetControlReconcileEntry;
const CanvasWidgetTextReconcileEntry = canvas_widget_runtime.CanvasWidgetTextReconcileEntry;
const canvasWidgetLayoutTreeWithRuntimeReconcileState = canvas_widget_runtime.canvasWidgetLayoutTreeWithRuntimeReconcileState;
const canvasWidgetEditableTextKind = canvas_widget_runtime.canvasWidgetEditableTextKind;
const canvasWidgetAccessibilityActionSupported = widget_bridge.canvasWidgetAccessibilityActionSupported;
const canvasWidgetAccessibilitySemanticAction = widget_bridge.canvasWidgetAccessibilitySemanticAction;

pub fn RuntimeCanvasWidgetState(comptime Runtime: type) type {
    return struct {
        pub fn setCanvasWidgetLayout(self: *Runtime, window_id: platform.WindowId, label: []const u8, layout: canvas.WidgetLayoutTree) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            if (layout.nodes.len > max_canvas_widget_nodes_per_view) return error.WidgetNodeLimitReached;

            const previous_layout = self.views[index].widgetLayoutTree();
            var source_semantics_buffer: [max_canvas_widget_semantics_per_view]canvas.WidgetSemanticsNode = undefined;
            const source_semantics = try layout.collectSemantics(&source_semantics_buffer);
            var reconciled_nodes: [max_canvas_widget_nodes_per_view]canvas.WidgetLayoutNode = undefined;
            var previous_control_entries: [max_canvas_widget_nodes_per_view]CanvasWidgetControlReconcileEntry = undefined;
            var previous_text_entries: [max_canvas_widget_nodes_per_view]CanvasWidgetTextReconcileEntry = undefined;
            var previous_text_bytes: [max_canvas_widget_text_bytes_per_view]u8 = undefined;
            const tokens = self.views[index].widget_tokens;
            const reconciled_layout = try canvasWidgetLayoutTreeWithRuntimeReconcileState(
                previous_layout,
                layout,
                source_semantics,
                self.views[index].widgetSourceTextEntries(),
                &reconciled_nodes,
                &previous_control_entries,
                &previous_text_entries,
                &previous_text_bytes,
                tokens,
            );
            var widget_invalidations: [max_canvas_widget_invalidations_per_view]canvas.WidgetInvalidation = undefined;
            const invalidations = try canvas.WidgetLayoutTree.diffWithTokens(previous_layout, reconciled_layout, tokens, &widget_invalidations);
            const previous_render_state = self.views[index].canvasWidgetRenderState();
            const next_render_state = CanvasWidgetEventMethods(Runtime).canvasWidgetRenderStateAfterLayout(previous_render_state, reconciled_layout);
            const render_state_changed = !CanvasWidgetEventMethods(Runtime).canvasWidgetRenderStatesEqual(previous_render_state, next_render_state);
            const render_state_dirty = if (render_state_changed)
                previous_layout.renderStateDirtyBoundsWithTokens(previous_render_state, next_render_state, tokens)
            else
                null;
            const previous_cursor = self.views[index].canvas_widget_cursor;
            const previous_widget_revision = self.views[index].widget_revision;
            try self.views[index].copyWidgetLayoutTree(reconciled_layout);
            try self.views[index].copyCanvasWidgetSourceText(layout);
            const widget_revision_changed = self.views[index].widget_revision != previous_widget_revision;
            if (previous_cursor != self.views[index].canvas_widget_cursor) try CanvasWidgetEventMethods(Runtime).syncCanvasWidgetCursorForView(self, index);
            CanvasWidgetEventMethods(Runtime).invalidateForWidgetInvalidations(self, self.views[index].frame, invalidations);
            if (render_state_changed) CanvasWidgetEventMethods(Runtime).invalidateForCanvasWidgetRenderStateDirty(self, index, render_state_dirty);
            const layout_dirty = invalidations.len > 0 or render_state_changed;
            const requested_frame = try CanvasWidgetDisplayMethods(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, index);
            if ((layout_dirty or widget_revision_changed) and !requested_frame) try CanvasFrameMethods(Runtime).requestCanvasFrameForView(self, index);
            return self.views[index].info();
        }

        pub fn canvasWidgetLayout(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror!canvas.WidgetLayoutTree {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            return self.views[index].widgetLayoutTree();
        }

        pub fn canvasWidgetSemantics(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror![]const canvas.WidgetSemanticsNode {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            return self.views[index].widgetSemantics();
        }

        pub fn dispatchCanvasWidgetAccessibilityAction(
            self: *Runtime,
            app: runtime_api.App(Runtime),
            window_id: platform.WindowId,
            label: []const u8,
            action: runtime_api.CanvasWidgetAccessibilityAction,
        ) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            if (action.id == 0) return error.InvalidCommand;
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            const actions = AutomationWidgetMethods(Runtime).canvasWidgetActionsForId(self, index, action.id) orelse return error.InvalidCommand;
            if (!canvasWidgetAccessibilityActionSupported(actions, action.action)) return error.InvalidCommand;

            if (canvasWidgetAccessibilitySemanticAction(action.action)) |semantic_action| {
                if (try AutomationWidgetMethods(Runtime).dispatchCanvasWidgetSemanticControlAction(self, app, index, action.id, semantic_action, actions)) {
                    return self.views[index].info();
                }
            }

            switch (action.action) {
                .focus => try AutomationWidgetMethods(Runtime).focusAutomationCanvasWidget(self, index, action.id),
                .press => try AutomationWidgetMethods(Runtime).dispatchAutomationWidgetKey(self, app, index, action.id, "enter"),
                .toggle => try AutomationWidgetMethods(Runtime).dispatchAutomationWidgetKey(self, app, index, action.id, "space"),
                .increment => try AutomationWidgetMethods(Runtime).dispatchAutomationWidgetKey(self, app, index, action.id, self.views[index].canvasWidgetStepKey(action.id, .increment)),
                .decrement => try AutomationWidgetMethods(Runtime).dispatchAutomationWidgetKey(self, app, index, action.id, self.views[index].canvasWidgetStepKey(action.id, .decrement)),
                .set_text => try AutomationWidgetMethods(Runtime).setAutomationCanvasWidgetText(self, index, action.id, action.text),
                .set_selection => try AutomationWidgetMethods(Runtime).editAutomationCanvasWidgetText(self, index, action.id, .{ .set_selection = action.selection orelse return error.InvalidCommand }),
                .set_composition => try AutomationWidgetMethods(Runtime).editAutomationCanvasWidgetText(self, index, action.id, .{ .set_composition = .{ .text = action.text } }),
                .commit_composition => try AutomationWidgetMethods(Runtime).editAutomationCanvasWidgetText(self, index, action.id, .commit_composition),
                .cancel_composition => try AutomationWidgetMethods(Runtime).editAutomationCanvasWidgetText(self, index, action.id, .cancel_composition),
                .select => try AutomationWidgetMethods(Runtime).selectAutomationCanvasWidget(self, index, action.id),
                .drag => try AutomationWidgetMethods(Runtime).dispatchAutomationCanvasWidgetDrag(self, app, index, action.id, action.text),
                .drop_files => try AutomationWidgetMethods(Runtime).dispatchAutomationCanvasWidgetFileDrop(self, app, index, action.id, action.text),
                .dismiss => try AutomationWidgetMethods(Runtime).dismissAutomationCanvasWidget(self, index, action.id),
            }
            return self.views[index].info();
        }

        pub fn stepCanvasWidgetKineticScroll(self: *Runtime, window_id: platform.WindowId, label: []const u8, dt_ms: f32) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;

            const dirty = try self.views[index].stepCanvasWidgetKineticScroll(dt_ms) orelse return self.views[index].info();
            const previous_cursor = self.views[index].canvas_widget_cursor;
            self.views[index].reconcileCanvasWidgetRenderStateAfterScroll(null);
            if (previous_cursor != self.views[index].canvas_widget_cursor) try CanvasWidgetEventMethods(Runtime).syncCanvasWidgetCursorForView(self, index);
            try CanvasWidgetEventMethods(Runtime).invalidateForCanvasWidgetDirty(self, index, dirty);
            _ = try CanvasWidgetDisplayMethods(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, index);
            return self.views[index].info();
        }

        pub fn setCanvasWidgetDesignTokens(self: *Runtime, window_id: platform.WindowId, label: []const u8, tokens: canvas.DesignTokens) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            if (std.meta.eql(self.views[index].widget_tokens, tokens)) return self.views[index].info();
            self.views[index].widget_tokens = tokens;
            self.views[index].widget_revision += 1;
            if (self.views[index].canvas_display_list_widget_owned) {
                _ = try CanvasWidgetDisplayMethods(Runtime).refreshCanvasWidgetDisplayList(self, index);
            }
            return self.views[index].info();
        }

        pub fn canvasWidgetDesignTokens(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror!canvas.DesignTokens {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            return self.views[index].widget_tokens;
        }

        pub fn canvasWidgetTextGeometry(self: *const Runtime, window_id: platform.WindowId, label: []const u8, id: canvas.ObjectId) anyerror!canvas.WidgetTextGeometry {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            if (id == 0) return error.InvalidCommand;
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            const node = self.views[index].widgetLayoutTree().findById(id) orelse return error.InvalidCommand;
            if (!canvasWidgetEditableTextKind(node.widget.kind)) return error.InvalidCommand;
            return canvas.textGeometryForWidget(node.widget, self.views[index].widget_tokens);
        }

        pub fn editCanvasWidgetText(self: *Runtime, window_id: platform.WindowId, label: []const u8, id: canvas.ObjectId, edit: canvas.TextInputEvent) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            if (id == 0) return error.InvalidCommand;
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            if (!self.views[index].canEditCanvasWidgetText(id)) return error.InvalidCommand;

            const dirty = try self.views[index].applyCanvasWidgetTextEdit(id, edit) orelse return self.views[index].info();
            try CanvasWidgetEventMethods(Runtime).invalidateForCanvasWidgetDirty(self, index, dirty);
            _ = try CanvasWidgetDisplayMethods(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, index);
            return self.views[index].info();
        }
    };
}

fn CanvasFrameMethods(comptime Runtime: type) type {
    return canvas_frame_helpers.RuntimeCanvasFrames(Runtime);
}

fn CanvasWidgetDisplayMethods(comptime Runtime: type) type {
    return runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime);
}

fn CanvasWidgetEventMethods(comptime Runtime: type) type {
    return runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(Runtime);
}

fn AutomationWidgetMethods(comptime Runtime: type) type {
    return runtime_automation_widget_dispatch.RuntimeAutomationWidgetDispatch(Runtime);
}

fn validateRuntimeViewParent(self: anytype, window_id: platform.WindowId) !void {
    const index = runtimeFindWindowIndexById(self, window_id) orelse return error.WindowNotFound;
    if (!self.windows[index].info.open) return error.WindowNotFound;
}

fn runtimeFindWindowIndexById(self: anytype, id: platform.WindowId) ?usize {
    for (self.windows[0..self.window_count], 0..) |window, index| {
        if (window.info.id == id) return index;
    }
    return null;
}

fn runtimeFindViewIndex(self: anytype, window_id: platform.WindowId, label: []const u8) ?usize {
    for (self.views[0..self.view_count], 0..) |view, index| {
        if (view.open and view.window_id == window_id and std.mem.eql(u8, view.label, label)) return index;
    }
    return null;
}
