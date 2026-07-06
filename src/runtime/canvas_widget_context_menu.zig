//! Context menus: right/ctrl-click (and a touch long-press, which hosts
//! report the same way) on a canvas widget asks the platform to present
//! the OS context menu at the pointer, and dispatches the selection back
//! through typed messages. The OS menu is the DEFAULT presentation; when
//! this host has no native presenter (or presenting failed), an
//! app-declared menu presents as an anchored canvas surface instead —
//! the app loop answers `canvas_widget_context_menu_request` by mounting
//! the SAME declared items, so authors write one menu and the platform
//! decides presentation.
//!
//! Resolution order for a secondary-button press:
//! 1. the deepest widget on the hit route declaring
//!    `ElementOptions.context_menu` (app-declared, Msg-mapped items),
//! 2. an editable text target: the standard Cut / Copy / Paste /
//!    Select All menu wired to the existing clipboard actions,
//! 3. the view's live static-text selection: a Copy-only menu.
//! The zero-code defaults (2 and 3) are presenter-only: without a native
//! menu they degrade to the keyboard clipboard paths, never a synthesized
//! surface (there are no app-declared items to mount).
//!
//! Presentation is asynchronous (macOS `popUpMenuPositioningItem` runs a
//! nested tracking loop): the platform emits a `context_menu_action`
//! event later, matched here against the pending request.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");
const runtime_api = @import("api.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");
const runtime_canvas_widget_events = @import("canvas_widget_events.zig");

const context_menu_log = std.log.scoped(.zero_context_menu);

/// Reserved item ids of the zero-code default menus.
pub const default_item_cut: u32 = 1;
pub const default_item_copy: u32 = 2;
pub const default_item_paste: u32 = 3;
pub const default_item_select_all: u32 = 4;

pub const PendingCanvasWidgetContextMenu = struct {
    window_id: platform.WindowId = 1,
    token: u64 = 0,
    kind: Kind = .app,

    pub const Kind = enum {
        app,
        edit_text,
        static_copy,
    };
};

pub fn RuntimeCanvasWidgetContextMenu(comptime Runtime: type) type {
    return struct {
        /// True when the input event belongs to the secondary button and
        /// must be consumed by the context-menu path instead of the
        /// primary pointer pipeline (a right-click must never act as a
        /// press).
        pub fn canvasWidgetContextPointerInput(input_event: platform.GpuSurfaceInputEvent) bool {
            if (input_event.button != 1) return false;
            return switch (input_event.kind) {
                .pointer_down, .pointer_up, .pointer_drag, .pointer_move, .pointer_cancel => true,
                else => false,
            };
        }

        /// Present the context menu for a secondary-button press: hit-test
        /// the point, pick the menu (app-declared, editable-text default,
        /// or static-selection copy), and hand it to the platform. An
        /// app-declared menu the platform cannot present natively becomes
        /// a `canvas_widget_context_menu_request` — the app loop mounts
        /// the same items as an anchored canvas surface. When NOTHING
        /// under the pointer offers a menu, the press is delivered to the
        /// app instead as a `canvas_widget_context_press` with the
        /// resolved press target: the desktop alternative for
        /// press-and-hold (`on_hold`). Declared context menus always win
        /// over hold handlers.
        pub fn presentCanvasWidgetContextMenuFromPointer(self: *Runtime, app: runtime_api.App(Runtime), input_event: platform.GpuSurfaceInputEvent) anyerror!void {
            const routed = CanvasWidgetEventMethods().routeCanvasWidgetPointerInput(self, input_event, &self.widget_event_route_entries) catch |err| switch (err) {
                error.WindowNotFound, error.ViewNotFound, error.InvalidViewOptions => return,
                else => return err,
            };
            const pointer_event = routed orelse return;
            const index = runtimeFindViewIndex(self, input_event.window_id, input_event.label) orelse return;
            const point = geometry.PointF.init(input_event.x, input_event.y);

            var items: [platform.max_context_menu_items]platform.ContextMenuItem = undefined;
            const has_presenter = self.options.platform.services.show_context_menu_fn != null;

            // 1. Deepest app-declared menu on the route wins. When the
            // platform cannot present it (no native presenter on this
            // host, or the presenter call failed), the SAME declared menu
            // presents as an anchored canvas surface instead: the app
            // loop answers the request event by mounting it — one
            // authored menu, platform-appropriate presentation.
            if (deepestContextMenuRouteNode(self, index, pointer_event.route)) |node_index| {
                const widget = self.views[index].widget_layout_nodes[node_index].widget;
                const count = @min(widget.context_menu.len, items.len);
                if (count == 0) return;
                if (has_presenter) {
                    for (widget.context_menu[0..count], 0..) |item, item_index| {
                        items[item_index] = .{
                            .id = @intCast(item_index + 1),
                            .label = item.label,
                            .enabled = item.enabled,
                            .separator = item.separator,
                        };
                    }
                    if (try showMenu(self, index, .{
                        .window_id = input_event.window_id,
                        .token = widget.id,
                        .kind = .app,
                    }, point, items[0..count])) return;
                }
                try self.dispatchEvent(app, .{ .canvas_widget_context_menu_request = .{
                    .window_id = input_event.window_id,
                    .view_label = self.views[index].label,
                    .target_id = widget.id,
                } });
                return;
            }

            // 2. Editable text target: the standard edit menu, wired to
            // the existing clipboard actions. Focus the field first so
            // paste lands where the user clicked (macOS behavior).
            if (pointer_event.target) |target| {
                const node_index = self.views[index].canvasWidgetNodeIndexById(target.id) orelse return;
                const widget = self.views[index].widget_layout_nodes[node_index].widget;
                if (canvas_widget_runtime.canvasWidgetEditableTextKind(widget.kind) and !widget.state.disabled) {
                    if (!has_presenter) return;
                    try CanvasWidgetEventMethods().updateCanvasWidgetFocusFromPointer(self, pointer_event);
                    const has_selection = if (canvas.widgetTextSelectionRange(widget)) |range| !range.isCollapsed(widget.text.len) else false;
                    items[0] = .{ .id = default_item_cut, .label = "Cut", .enabled = has_selection };
                    items[1] = .{ .id = default_item_copy, .label = "Copy", .enabled = has_selection };
                    items[2] = .{ .id = default_item_paste, .label = "Paste" };
                    items[3] = .{ .separator = true };
                    items[4] = .{ .id = default_item_select_all, .label = "Select All", .enabled = widget.text.len > 0 };
                    _ = try showMenu(self, index, .{
                        .window_id = input_event.window_id,
                        .token = target.id,
                        .kind = .edit_text,
                    }, point, items[0..5]);
                    return;
                }

                // 3. Static text with a live selection: Copy only.
                const selected_id = self.views[index].canvas_widget_selected_text_id;
                if (selected_id != 0 and selected_id == target.id) {
                    if (!has_presenter) return;
                    items[0] = .{ .id = default_item_copy, .label = "Copy" };
                    _ = try showMenu(self, index, .{
                        .window_id = input_event.window_id,
                        .token = target.id,
                        .kind = .static_copy,
                    }, point, items[0..1]);
                    return;
                }
            }

            // 4. No menu anywhere on the route: the press-and-hold
            // alternative. Deliver the context press so `UiApp` can
            // dispatch the press target's `on_hold` Msg.
            try self.dispatchEvent(app, .{ .canvas_widget_context_press = .{
                .window_id = input_event.window_id,
                .view_label = self.views[index].label,
                .press_target = pointer_event.press_target,
            } });
        }

        /// Returns whether the platform accepted the presentation; a
        /// refusal is not fatal (app-declared menus fall back to the
        /// anchored canvas surface, the zero-code defaults degrade to
        /// their keyboard paths).
        fn showMenu(self: *Runtime, view_index: usize, pending: PendingCanvasWidgetContextMenu, point: geometry.PointF, items: []const platform.ContextMenuItem) anyerror!bool {
            self.options.platform.services.showContextMenu(.{
                .window_id = pending.window_id,
                .view_label = self.views[view_index].label,
                .point = point,
                .token = pending.token,
                .items = items,
            }) catch |err| {
                if (err != error.UnsupportedService) {
                    context_menu_log.warn("context menu presentation failed: {s}", .{@errorName(err)});
                }
                return false;
            };
            self.canvas_widget_context_menu_pending = pending;
            return true;
        }

        /// The platform reported the menu outcome: resolve the pending
        /// request. App menus dispatch a `.canvas_widget_context_menu`
        /// runtime event (UiApp maps it through the tree's handler
        /// table); the default menus perform the clipboard action
        /// directly through the same paths the keyboard shortcuts use.
        pub fn dispatchContextMenuAction(self: *Runtime, app: runtime_api.App(Runtime), event: platform.ContextMenuActionEvent) anyerror!void {
            const pending = self.canvas_widget_context_menu_pending orelse return;
            self.canvas_widget_context_menu_pending = null;
            if (pending.window_id != event.window_id or pending.token != event.token) return;
            if (event.item_id == 0) return; // dismissed
            const index = runtimeFindViewIndex(self, event.window_id, event.view_label) orelse return;

            switch (pending.kind) {
                .app => try self.dispatchEvent(app, .{ .canvas_widget_context_menu = .{
                    .window_id = event.window_id,
                    .view_label = self.views[index].label,
                    .target_id = pending.token,
                    .item_index = event.item_id - 1,
                } }),
                .edit_text => try applyDefaultEditAction(self, app, index, pending.token, event.item_id),
                .static_copy => {
                    if (event.item_id != default_item_copy) return;
                    const text = self.views[index].canvasWidgetCopyText() orelse return;
                    self.writeClipboard(text) catch return;
                },
            }
        }

        fn applyDefaultEditAction(self: *Runtime, app: runtime_api.App(Runtime), view_index: usize, target_id: canvas.ObjectId, item_id: u32) anyerror!void {
            switch (item_id) {
                default_item_copy => {
                    const text = editableSelectionText(self, view_index, target_id) orelse return;
                    self.writeClipboard(text) catch return;
                },
                default_item_cut => {
                    var keyboard_event = editKeyboardEvent(self, view_index, target_id) orelse return;
                    const text = editableSelectionText(self, view_index, target_id) orelse return;
                    // Never delete text that did not make it onto the
                    // clipboard (same rule as the cmd+X shortcut).
                    self.writeClipboard(text) catch return;
                    keyboard_event.keyboard.edit = .{ .insert_text = "" };
                    try applyEditKeyboardEvent(self, app, keyboard_event);
                },
                default_item_paste => {
                    var keyboard_event = editKeyboardEvent(self, view_index, target_id) orelse return;
                    const node_index = self.views[view_index].canvasWidgetNodeIndexById(target_id) orelse return;
                    const widget = self.views[view_index].widget_layout_nodes[node_index].widget;
                    if (!canvas_widget_runtime.canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled) return;
                    var paste_buffer: [platform.max_clipboard_data_bytes]u8 = undefined;
                    const text = self.readClipboard(&paste_buffer) catch return;
                    if (text.len == 0) return;
                    const clamp = canvas_widget_runtime.clampCanvasWidgetPasteText(widget, self.views[view_index].widget_text_len, text);
                    keyboard_event.keyboard.edit_truncated = clamp.truncated;
                    if (clamp.text.len == 0) return;
                    keyboard_event.keyboard.edit = .{ .insert_text = clamp.text };
                    try applyEditKeyboardEvent(self, app, keyboard_event);
                },
                default_item_select_all => {
                    var keyboard_event = editKeyboardEvent(self, view_index, target_id) orelse return;
                    // Resolves through the same select-all text-edit path
                    // as the cmd+A shortcut.
                    keyboard_event.keyboard.key = "a";
                    keyboard_event.keyboard.modifiers = .{ .super = true };
                    try applyEditKeyboardEvent(self, app, keyboard_event);
                },
                else => {},
            }
        }

        /// A synthesized key-down keyboard event addressed at the editable
        /// widget, shaped like the routed events the clipboard shortcuts
        /// stamp their edits onto.
        fn editKeyboardEvent(self: *Runtime, view_index: usize, target_id: canvas.ObjectId) ?runtime_api.CanvasWidgetKeyboardEvent {
            const target = self.views[view_index].widgetLayoutTree().focusTargetById(target_id) orelse return null;
            return .{
                .window_id = self.views[view_index].window_id,
                .view_label = self.views[view_index].label,
                .keyboard = .{ .phase = .key_down, .focused_id = target_id },
                .target = target,
            };
        }

        /// Run the stamped edit through the runtime text state and hand
        /// the event to the app — the same two motions keyboard-driven
        /// edits perform, so runtime widget and app model stay in sync.
        fn applyEditKeyboardEvent(self: *Runtime, app: runtime_api.App(Runtime), keyboard_event: runtime_api.CanvasWidgetKeyboardEvent) anyerror!void {
            try CanvasWidgetEventMethods().updateCanvasWidgetTextFromKeyboard(self, keyboard_event);
            try self.dispatchEvent(app, .{ .canvas_widget_keyboard = keyboard_event });
        }

        fn editableSelectionText(self: *Runtime, view_index: usize, target_id: canvas.ObjectId) ?[]const u8 {
            const node_index = self.views[view_index].canvasWidgetNodeIndexById(target_id) orelse return null;
            const widget = self.views[view_index].widget_layout_nodes[node_index].widget;
            if (!canvas_widget_runtime.canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled) return null;
            const range = canvas.widgetTextSelectionRange(widget) orelse return null;
            if (range.isCollapsed(widget.text.len)) return null;
            return widget.text[range.start..range.end];
        }

        /// The deepest node on the pointer route carrying an app-declared
        /// context menu.
        fn deepestContextMenuRouteNode(self: *const Runtime, view_index: usize, route: []const canvas.WidgetEventRouteEntry) ?usize {
            var result: ?usize = null;
            var result_depth: usize = 0;
            for (route) |entry| {
                if (entry.node_index >= self.views[view_index].widget_layout_node_count) continue;
                const node = self.views[view_index].widget_layout_nodes[entry.node_index];
                if (node.widget.context_menu.len == 0 or node.widget.state.disabled) continue;
                if (result == null or node.depth >= result_depth) {
                    result = entry.node_index;
                    result_depth = node.depth;
                }
            }
            return result;
        }

        fn CanvasWidgetEventMethods() type {
            return runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(Runtime);
        }
    };
}

fn runtimeFindViewIndex(self: anytype, window_id: platform.WindowId, label: []const u8) ?usize {
    for (self.views[0..self.view_count], 0..) |*view, index| {
        if (view.open and view.window_id == window_id and std.mem.eql(u8, view.label, label)) return index;
    }
    return null;
}
