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
    /// Per-request generation, minted when the request is armed and
    /// echoed back by the platform on the action event. Menus can be
    /// superseded while a dismissal is still in flight (GTK tears the
    /// old popover down one loop turn after the successor presents), so
    /// the token must name the REQUEST, not the widget: a stale token's
    /// event must never resolve — or clear — a successor's pending
    /// request, even when both menus target the same widget.
    token: u64 = 0,
    /// The widget the menu was presented for (selections dispatch
    /// against it; the token above no longer doubles as its id).
    target_id: canvas.ObjectId = 0,
    kind: Kind = .app,
    /// The presented view's label, copied into the request so a
    /// superseded menu's dismissal notice can still name its canvas —
    /// the view may be gone (window closed) by the time the request
    /// resolves, and per-canvas menu state in a raw app needs the
    /// correlation.
    view_label_storage: [platform.max_view_label_bytes]u8 = undefined,
    view_label_len: usize = 0,

    pub fn viewLabel(self: *const PendingCanvasWidgetContextMenu) []const u8 {
        return self.view_label_storage[0..self.view_label_len];
    }

    pub fn setViewLabel(self: *PendingCanvasWidgetContextMenu, label: []const u8) void {
        const len = @min(label.len, self.view_label_storage.len);
        @memcpy(self.view_label_storage[0..len], label[0..len]);
        self.view_label_len = len;
    }

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
                    switch (try showMenu(self, app, index, .{
                        .window_id = input_event.window_id,
                        .target_id = widget.id,
                        .kind = .app,
                    }, point, items[0..count])) {
                        .shown => |shown| {
                            // Presentation is asynchronous on GTK (and the
                            // snapshot is harmless where the presenter blocks):
                            // tell the app WHAT is on the glass, keyed by the
                            // request's token, so the eventual selection
                            // resolves against the shown items' dispatch
                            // payloads — never a tree that rebuilt (reordering
                            // or re-mapping items) while the menu was open.
                            // The event's fields come from the returned request
                            // itself, never `self.views[index]` re-read here:
                            // `showMenu` ran the superseded menu's dismissal
                            // notice — arbitrary app code that may have closed
                            // views and compacted their indices.
                            try self.dispatchEvent(app, .{ .canvas_widget_context_menu_shown = .{
                                .window_id = shown.window_id,
                                .view_label = shown.viewLabel(),
                                .target_id = widget.id,
                                .token = shown.token,
                                .item_count = count,
                            } });
                            return;
                        },
                        // The dismissal notice's app code presented a
                        // successor that replaced this request (the
                        // successor already announced itself), or closed
                        // the presenting view outright: announce NOTHING
                        // here — and never the anchored fallback, which
                        // would mount a surface under the successor's
                        // native menu or on a view that no longer exists.
                        .superseded, .view_closed => return,
                        .refused => {},
                    }
                }
                try self.dispatchEvent(app, .{ .canvas_widget_context_menu_request = .{
                    .window_id = input_event.window_id,
                    .view_label = self.views[index].label,
                    .target_id = widget.id,
                    .point = point,
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
                    _ = try showMenu(self, app, index, .{
                        .window_id = input_event.window_id,
                        .target_id = target.id,
                        .kind = .edit_text,
                    }, point, items[0..5]);
                    return;
                }

                // 3. Static text with a live selection: Copy only.
                const selected_id = self.views[index].canvas_widget_selected_text_id;
                if (selected_id != 0 and selected_id == target.id) {
                    if (!has_presenter) return;
                    items[0] = .{ .id = default_item_copy, .label = "Copy" };
                    _ = try showMenu(self, app, index, .{
                        .window_id = input_event.window_id,
                        .target_id = target.id,
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

        /// A NEW presentation or dispatch replaced the pending request.
        /// An app menu's pending has state beyond the runtime's gate —
        /// UiApp holds a token-keyed snapshot and a pinned build
        /// generation for it, and a raw app may track per-canvas menu
        /// state — and the superseded token can never arrive (the gate
        /// would swallow it), so tell the app the old menu is gone,
        /// named by the view it was presented on. This runs for EVERY
        /// superseding kind: app over app, a default edit/copy menu
        /// over an app menu, and the automation verb's direct dispatch.
        /// Call it AFTER committing the replacement pending: the notice
        /// dispatch is fallible, and the runtime's bookkeeping must
        /// already match the menu the platform accepted.
        pub fn notifySupersededPending(self: *Runtime, app: runtime_api.App(Runtime), superseded: ?PendingCanvasWidgetContextMenu) anyerror!void {
            const pending = superseded orelse return;
            if (pending.kind != .app) return;
            try self.dispatchEvent(app, .{ .canvas_widget_context_menu_dismissed = .{
                .window_id = pending.window_id,
                .view_label = pending.viewLabel(),
                .token = pending.token,
            } });
        }

        const ShowMenuOutcome = union(enum) {
            /// The platform accepted and the request is still the
            /// pending truth: announce it
            /// (`canvas_widget_context_menu_shown`).
            shown: PendingCanvasWidgetContextMenu,
            /// The platform refused — not fatal (app-declared menus
            /// fall back to the anchored canvas surface, the zero-code
            /// defaults degrade to their keyboard paths). The old
            /// pending (and its popover, if any) is still the truth.
            refused,
            /// The platform accepted, but the superseded menu's
            /// dismissal notice synchronously presented a SUCCESSOR
            /// that replaced this request. The successor is the truth
            /// and already announced itself: announcing this request
            /// late would overwrite the successor's snapshot with a
            /// menu whose token the action gate no longer accepts,
            /// stranding the successor on live-tree resolution and the
            /// stale pin unreleased.
            superseded,
            /// The platform accepted, but the superseded menu's
            /// dismissal notice CLOSED the presenting view. The request
            /// can never resolve (its action would clear the token and
            /// silently drop on the view lookup — or never arrive at
            /// all if the window died with it), so it is disarmed here:
            /// announce nothing, mount nothing.
            view_closed,
        };

        /// Present `request` natively. Callers must describe the
        /// presented menu from the returned `.shown` request, not from
        /// `self.views[view_index]`: the superseded menu's dismissal
        /// notice below runs arbitrary app code that may close views
        /// and compact their indices — or present a successor menu
        /// (see `ShowMenuOutcome.superseded`).
        fn showMenu(self: *Runtime, app: runtime_api.App(Runtime), view_index: usize, request: PendingCanvasWidgetContextMenu, point: geometry.PointF, items: []const platform.ContextMenuItem) anyerror!ShowMenuOutcome {
            var pending = request;
            pending.token = nextContextMenuToken(self);
            pending.setViewLabel(self.views[view_index].label);
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
                // Presentation refused: nothing superseded — the old
                // pending (and its popover, if any) is still the truth.
                return .refused;
            };
            // The platform accepted: commit the replacement BEFORE the
            // fallible superseded-notice dispatch, so the runtime's
            // expected token always matches the menu on the glass.
            const superseded = self.canvas_widget_context_menu_pending;
            self.canvas_widget_context_menu_pending = pending;
            try notifySupersededPending(self, app, superseded);
            const still_armed = if (self.canvas_widget_context_menu_pending) |current| current.token == pending.token else false;
            if (!still_armed) return .superseded;
            // Still armed, but the notice may have closed the view the
            // menu presented on: disarm the unresolvable request.
            if (runtimeFindViewIndex(self, pending.window_id, pending.viewLabel()) == null) {
                self.canvas_widget_context_menu_pending = null;
                return .view_closed;
            }
            return .{ .shown = pending };
        }

        /// The platform reported the menu outcome: resolve the pending
        /// request. App menus dispatch a `.canvas_widget_context_menu`
        /// runtime event (UiApp maps it through the tree's handler
        /// table); the default menus perform the clipboard action
        /// directly through the same paths the keyboard shortcuts use.
        pub fn dispatchContextMenuAction(self: *Runtime, app: runtime_api.App(Runtime), event: platform.ContextMenuActionEvent) anyerror!void {
            const pending = self.canvas_widget_context_menu_pending orelse return;
            // Token gate BEFORE the clear: an event carrying a stale
            // token belongs to a superseded request (its deferred
            // dismissal outlived a re-click's replacement menu) and is
            // swallowed — it must never clear, let alone resolve, the
            // successor's pending request. Windows cannot produce a
            // stale event (TrackPopupMenu blocks the loop thread and
            // emits inline from the moved-out request, so a second
            // request never dispatches mid-menu); macOS cannot either
            // (each presentation block captures its own token and
            // popUpMenuPositioningItem's nested tracking loop blocks
            // the main queue); GTK popovers are asynchronous and CAN.
            if (pending.window_id != event.window_id or pending.token != event.token) return;
            self.canvas_widget_context_menu_pending = null;
            if (event.item_id == 0) {
                // Dismissed without a selection. App menus tell the app:
                // UiApp disarms the token's presented-items snapshot and
                // releases the build storage pinned under it.
                if (pending.kind == .app) {
                    try self.dispatchEvent(app, .{ .canvas_widget_context_menu_dismissed = .{
                        .window_id = event.window_id,
                        .view_label = event.view_label,
                        .token = pending.token,
                    } });
                }
                return;
            }
            const index = runtimeFindViewIndex(self, event.window_id, event.view_label) orelse return;

            switch (pending.kind) {
                .app => try self.dispatchEvent(app, .{ .canvas_widget_context_menu = .{
                    .window_id = event.window_id,
                    .view_label = self.views[index].label,
                    .target_id = pending.target_id,
                    .item_index = event.item_id - 1,
                    // The shown snapshot's key: UiApp resolves the
                    // selection from what was presented under this token.
                    .token = pending.token,
                } }),
                .edit_text => try applyDefaultEditAction(self, app, index, pending.target_id, event.item_id),
                .static_copy => {
                    if (event.item_id != default_item_copy) return;
                    const text = self.views[index].canvasWidgetCopyText() orelse return;
                    self.writeClipboard(text) catch return;
                },
            }
        }

        /// Mint the next per-request correlation token. Never zero, so a
        /// zero-token event can never match an armed request.
        pub fn nextContextMenuToken(self: *Runtime) u64 {
            self.canvas_widget_context_menu_token +%= 1;
            if (self.canvas_widget_context_menu_token == 0) self.canvas_widget_context_menu_token = 1;
            return self.canvas_widget_context_menu_token;
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
            var event = keyboard_event;
            // No gpu-surface input cycle wraps a context-menu edit: mark
            // it standalone so the ui-app hover drain runs at its tail.
            event.standalone = true;
            try CanvasWidgetEventMethods().updateCanvasWidgetTextFromKeyboard(self, &event);
            try self.dispatchEvent(app, .{ .canvas_widget_keyboard = event });
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
