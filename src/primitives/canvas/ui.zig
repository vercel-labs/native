//! Experimental declarative authoring layer over the retained widget tree.
//!
//! `Ui(Msg)` builds widget trees without hand-assigned object ids, absolute
//! frames, or string command dispatch:
//!
//! - Identity is structural: each widget id is derived from its parent id,
//!   kind, and key (explicit in `each`, sibling index otherwise), so ids stay
//!   stable across rebuilds and keyed reorders without author bookkeeping.
//! - Event handlers are typed `Msg` values collected into a handler table,
//!   so dispatch is compiler-checked instead of string-matched.
//! - Flex layout fields are the authoring default; `frame` is the escape
//!   hatch for absolutely positioned regions.
//!
//! Build failures (arena exhaustion) latch on the builder and surface as an
//! error from `finalize`, keeping view code free of per-node `try`.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");

const ObjectId = canvas.ObjectId;
const Widget = canvas.Widget;
const WidgetKind = canvas.WidgetKind;

const root_id_seed: u64 = 0x5eed_2e70_a11c_e001;
const zero_id_fallback: ObjectId = 0x9e37_79b9_7f4a_7c15;

pub const UiKey = union(enum) {
    index: usize,
    int: u64,
    str: []const u8,
};

pub const UiHandlerEvent = enum {
    press,
    toggle,
    change,
    submit,
};

pub fn Ui(comptime Msg: type) type {
    return struct {
        const Self = @This();

        arena: std.mem.Allocator,
        failed: bool = false,

        pub const ElementOptions = struct {
            key: ?UiKey = null,
            frame: geometry.RectF = .{},
            placeholder: []const u8 = "",
            value: f32 = 0,
            checked: bool = false,
            selected: bool = false,
            disabled: bool = false,
            variant: canvas.WidgetVariant = .default,
            size: canvas.WidgetSize = .default,
            width: f32 = 0,
            height: f32 = 0,
            grow: f32 = 0,
            gap: f32 = 0,
            padding: f32 = 0,
            main: canvas.WidgetMainAlignment = .start,
            cross: canvas.WidgetCrossAlignment = .stretch,
            virtualized: bool = false,
            virtual_item_extent: f32 = 0,
            style: canvas.WidgetStyle = .{},
            semantics: canvas.WidgetSemantics = .{},
            on_press: ?Msg = null,
            on_toggle: ?Msg = null,
            on_change: ?Msg = null,
            on_submit: ?Msg = null,
        };

        pub const Node = struct {
            widget: Widget = .{ .kind = .stack },
            key: ?UiKey = null,
            on_press: ?Msg = null,
            on_toggle: ?Msg = null,
            on_change: ?Msg = null,
            on_submit: ?Msg = null,
            nodes: []const Node = &.{},
        };

        pub const Handler = struct {
            id: ObjectId,
            event: UiHandlerEvent,
            msg: Msg,
        };

        pub const Tree = struct {
            root: Widget,
            handlers: []const Handler,

            pub fn msgFor(self: Tree, id: ObjectId, event: UiHandlerEvent) ?Msg {
                for (self.handlers) |handler| {
                    if (handler.id == id and handler.event == event) return handler.msg;
                }
                return null;
            }

            pub fn findWidget(self: Tree, id: ObjectId) ?Widget {
                return findWidgetIn(self.root, id);
            }

            /// Typed dispatch for pointer events: a released press over a
            /// widget resolves through the engine's semantic intent model
            /// (press, then toggle, then select) to the matching handler.
            pub fn msgForPointer(self: Tree, target_id: ObjectId, phase: canvas.WidgetPointerPhase) ?Msg {
                if (phase != .up) return null;
                const widget = self.findWidget(target_id) orelse return null;
                const semantic_actions = [_]canvas.WidgetSemanticAction{ .press, .toggle, .select };
                for (semantic_actions) |action| {
                    const intent = canvas.widgetSemanticControlIntent(widget, action) orelse continue;
                    if (self.msgForIntent(target_id, intent)) |msg| return msg;
                }
                return null;
            }

            /// Typed dispatch for keyboard events: engine control intents
            /// (activation keys, slider steps) plus enter-to-submit on text
            /// entry widgets.
            pub fn msgForKeyboard(self: Tree, target_id: ObjectId, keyboard: canvas.WidgetKeyboardEvent) ?Msg {
                const widget = self.findWidget(target_id) orelse return null;
                if (canvas.widgetKeyboardControlIntent(widget, keyboard)) |intent| {
                    if (self.msgForIntent(target_id, intent)) |msg| return msg;
                }
                if (isSubmitKeyboard(widget, keyboard)) {
                    if (self.msgFor(target_id, .submit)) |msg| return msg;
                }
                return null;
            }

            fn msgForIntent(self: Tree, id: ObjectId, intent: canvas.WidgetControlIntent) ?Msg {
                return switch (intent.kind) {
                    .press => self.msgFor(id, .press),
                    .toggle => self.msgFor(id, .toggle),
                    .select => self.msgFor(id, .press),
                    .set_value => self.msgFor(id, .change),
                    .scroll_by, .scroll_to_start, .scroll_to_end => null,
                };
            }
        };

        pub fn init(arena: std.mem.Allocator) Self {
            return .{ .arena = arena };
        }

        pub fn el(self: *Self, kind: WidgetKind, options: ElementOptions, children: anytype) Node {
            return .{
                .widget = widgetFromOptions(kind, options),
                .key = options.key,
                .on_press = options.on_press,
                .on_toggle = options.on_toggle,
                .on_change = options.on_change,
                .on_submit = options.on_submit,
                .nodes = self.childNodes(children),
            };
        }

        pub fn row(self: *Self, options: ElementOptions, children: anytype) Node {
            return self.el(.row, options, children);
        }

        pub fn column(self: *Self, options: ElementOptions, children: anytype) Node {
            return self.el(.column, options, children);
        }

        pub fn stack(self: *Self, options: ElementOptions, children: anytype) Node {
            return self.el(.stack, options, children);
        }

        pub fn panel(self: *Self, options: ElementOptions, children: anytype) Node {
            return self.el(.panel, options, children);
        }

        pub fn scroll(self: *Self, options: ElementOptions, children: anytype) Node {
            return self.el(.scroll_view, options, children);
        }

        pub fn list(self: *Self, options: ElementOptions, children: anytype) Node {
            return self.el(.list, options, children);
        }

        /// The engine renders a status bar's own `text`; it does not lay out
        /// status bar children, so the builder models it as a text leaf.
        pub fn statusBar(self: *Self, options: ElementOptions, status_text: []const u8) Node {
            var node = self.el(.status_bar, options, .{});
            node.widget.text = status_text;
            return node;
        }

        pub fn text(self: *Self, options: ElementOptions, content: []const u8) Node {
            var node = self.el(.text, options, .{});
            node.widget.text = content;
            return node;
        }

        pub fn button(self: *Self, options: ElementOptions, label: []const u8) Node {
            var node = self.el(.button, options, .{});
            node.widget.text = label;
            return node;
        }

        pub fn listItem(self: *Self, options: ElementOptions, label: []const u8) Node {
            var node = self.el(.list_item, options, .{});
            node.widget.text = label;
            return node;
        }

        pub fn checkbox(self: *Self, options: ElementOptions) Node {
            return self.el(.checkbox, options, .{});
        }

        pub fn textField(self: *Self, options: ElementOptions) Node {
            return self.el(.text_field, options, .{});
        }

        pub fn separator(self: *Self, options: ElementOptions) Node {
            return self.el(.separator, options, .{});
        }

        /// Flexible empty space between siblings.
        pub fn spacer(self: *Self, grow: f32) Node {
            return self.el(.stack, .{ .grow = grow }, .{});
        }

        /// Keyed list projection: one node per item, keyed by `key_fn` unless
        /// the item view assigned its own key.
        pub fn each(self: *Self, items: anytype, comptime key_fn: anytype, comptime view_fn: anytype) []const Node {
            const nodes = self.arena.alloc(Node, items.len) catch {
                self.failed = true;
                return &.{};
            };
            for (items, 0..) |*item, index| {
                var node = view_fn(self, item);
                if (node.key == null) node.key = key_fn(item);
                nodes[index] = node;
            }
            return nodes;
        }

        /// Keyed list projection with caller context, for item views that
        /// need surrounding state (Zig has no closures to capture it).
        pub fn eachCtx(self: *Self, context: anytype, items: anytype, comptime key_fn: anytype, comptime view_fn: anytype) []const Node {
            const nodes = self.arena.alloc(Node, items.len) catch {
                self.failed = true;
                return &.{};
            };
            for (items, 0..) |*item, index| {
                var node = view_fn(self, context, item);
                if (node.key == null) node.key = key_fn(item);
                nodes[index] = node;
            }
            return nodes;
        }

        /// Arena-allocated formatted text for widget content.
        pub fn fmt(self: *Self, comptime format: []const u8, args: anytype) []const u8 {
            return std.fmt.allocPrint(self.arena, format, args) catch {
                self.failed = true;
                return "";
            };
        }

        /// Assign structural ids, materialize widget children, measure
        /// container minimum sizes, and collect the typed handler table.
        pub fn finalize(self: *Self, node: Node) error{OutOfMemory}!Tree {
            return self.finalizeWithTokens(node, .{});
        }

        pub fn finalizeWithTokens(self: *Self, node: Node, tokens: canvas.DesignTokens) error{OutOfMemory}!Tree {
            if (self.failed) return error.OutOfMemory;
            const handler_capacity = countHandlers(node);
            const handlers = try self.arena.alloc(Handler, handler_capacity);
            var handler_len: usize = 0;
            const root_key = node.key orelse UiKey{ .index = 0 };
            const root = try self.finalizeNode(node, root_id_seed, root_key, tokens, handlers, &handler_len);
            return .{ .root = root, .handlers = handlers[0..handler_len] };
        }

        fn finalizeNode(
            self: *Self,
            node: Node,
            parent_id: ObjectId,
            key: UiKey,
            tokens: canvas.DesignTokens,
            handlers: []Handler,
            handler_len: *usize,
        ) error{OutOfMemory}!Widget {
            var widget = node.widget;
            widget.id = structuralId(parent_id, widget.kind, key);
            if (node.nodes.len > 0) {
                const child_widgets = try self.arena.alloc(Widget, node.nodes.len);
                for (node.nodes, 0..) |child, index| {
                    const child_key = child.key orelse UiKey{ .index = index };
                    child_widgets[index] = try self.finalizeNode(child, widget.id, child_key, tokens, handlers, handler_len);
                }
                widget.children = child_widgets;
            }
            stampContainerMinSize(&widget, tokens);
            appendHandler(handlers, handler_len, widget.id, .press, node.on_press);
            appendHandler(handlers, handler_len, widget.id, .toggle, node.on_toggle);
            appendHandler(handlers, handler_len, widget.id, .change, node.on_change);
            appendHandler(handlers, handler_len, widget.id, .submit, node.on_submit);
            return widget;
        }

        fn appendHandler(handlers: []Handler, handler_len: *usize, id: ObjectId, event: UiHandlerEvent, msg: ?Msg) void {
            const value = msg orelse return;
            handlers[handler_len.*] = .{ .id = id, .event = event, .msg = value };
            handler_len.* += 1;
        }

        fn countHandlers(node: Node) usize {
            var total: usize = 0;
            if (node.on_press != null) total += 1;
            if (node.on_toggle != null) total += 1;
            if (node.on_change != null) total += 1;
            if (node.on_submit != null) total += 1;
            for (node.nodes) |child| total += countHandlers(child);
            return total;
        }

        fn childNodes(self: *Self, children: anytype) []const Node {
            const Children = @TypeOf(children);
            if (Children == Node) {
                const nodes = self.arena.alloc(Node, 1) catch {
                    self.failed = true;
                    return &.{};
                };
                nodes[0] = children;
                return nodes;
            }
            if (Children == []const Node or Children == []Node) return children;
            const info = @typeInfo(Children);
            if (info != .@"struct" or !info.@"struct".is_tuple) {
                @compileError("children must be a Node, a []const Node, or a tuple of those");
            }
            var total: usize = 0;
            inline for (children) |child| {
                total += if (@TypeOf(child) == Node) 1 else child.len;
            }
            if (total == 0) return &.{};
            const nodes = self.arena.alloc(Node, total) catch {
                self.failed = true;
                return &.{};
            };
            var index: usize = 0;
            inline for (children) |child| {
                if (@TypeOf(child) == Node) {
                    nodes[index] = child;
                    index += 1;
                } else {
                    for (child) |entry| {
                        nodes[index] = entry;
                        index += 1;
                    }
                }
            }
            return nodes;
        }

        fn widgetFromOptions(kind: WidgetKind, options: ElementOptions) Widget {
            return .{
                .kind = kind,
                .frame = options.frame,
                .placeholder = options.placeholder,
                .value = options.value,
                .variant = options.variant,
                .size = options.size,
                .state = .{
                    .selected = options.checked or options.selected,
                    .disabled = options.disabled,
                },
                .layout = .{
                    .padding = .{
                        .top = options.padding,
                        .right = options.padding,
                        .bottom = options.padding,
                        .left = options.padding,
                    },
                    .gap = options.gap,
                    .grow = options.grow,
                    .main_alignment = options.main,
                    .cross_alignment = options.cross,
                    .virtualized = options.virtualized,
                    .virtual_item_extent = options.virtual_item_extent,
                    .min_size = .{ .width = options.width, .height = options.height },
                },
                .style = options.style,
                .semantics = options.semantics,
            };
        }
    };
}

pub fn uiKey(value: anytype) UiKey {
    const Value = @TypeOf(value);
    return switch (@typeInfo(Value)) {
        .int, .comptime_int => .{ .int = @intCast(value) },
        .pointer => .{ .str = value },
        else => @compileError("uiKey supports integers and byte slices"),
    };
}

/// The engine gives plain containers zero intrinsic size, so a flex-first
/// tree with no explicit frames would collapse. Measure children bottom-up
/// (finalize recursion is post-order) and record the result as the
/// container's minimum size. Scroll viewports are exempt: their content is
/// allowed to overflow.
fn stampContainerMinSize(widget: *Widget, tokens: canvas.DesignTokens) void {
    const axis: enum { horizontal, vertical, overlay } = switch (widget.kind) {
        .row => .horizontal,
        .column => .vertical,
        .stack, .panel => .overlay,
        else => return,
    };
    if (widget.children.len == 0) return;

    const gap = @max(0, widget.layout.gap) * @as(f32, @floatFromInt(widget.children.len - 1));
    var main_sum: f32 = 0;
    var cross_max: f32 = 0;
    var width_max: f32 = 0;
    var height_max: f32 = 0;
    for (widget.children) |child| {
        const size = measuredChildSize(child, tokens);
        width_max = @max(width_max, size.width);
        height_max = @max(height_max, size.height);
        switch (axis) {
            .horizontal => {
                main_sum += size.width;
                cross_max = @max(cross_max, size.height);
            },
            .vertical => {
                main_sum += size.height;
                cross_max = @max(cross_max, size.width);
            },
            .overlay => {},
        }
    }
    const padding = widget.layout.padding;
    const measured: geometry.SizeF = switch (axis) {
        .horizontal => .{ .width = main_sum + gap, .height = cross_max },
        .vertical => .{ .width = cross_max, .height = main_sum + gap },
        .overlay => .{ .width = width_max, .height = height_max },
    };
    widget.layout.min_size = .{
        .width = @max(widget.layout.min_size.width, measured.width + padding.left + padding.right),
        .height = @max(widget.layout.min_size.height, measured.height + padding.top + padding.bottom),
    };
}

fn measuredChildSize(child: Widget, tokens: canvas.DesignTokens) geometry.SizeF {
    const intrinsic = canvas.intrinsicWidgetSize(child, tokens);
    return .{
        .width = @max(intrinsic.width, @max(child.layout.min_size.width, child.frame.width)),
        .height = @max(intrinsic.height, @max(child.layout.min_size.height, child.frame.height)),
    };
}

fn findWidgetIn(widget: Widget, id: ObjectId) ?Widget {
    if (widget.id == id) return widget;
    for (widget.children) |child| {
        if (findWidgetIn(child, id)) |found| return found;
    }
    return null;
}

fn isSubmitKeyboard(widget: Widget, keyboard: canvas.WidgetKeyboardEvent) bool {
    const submits_on_enter = switch (widget.kind) {
        .text_field, .search_field, .input, .combobox => true,
        else => false,
    };
    if (!submits_on_enter or widget.state.disabled) return false;
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return false;
    return std.ascii.eqlIgnoreCase(keyboard.key, "enter");
}

fn structuralId(parent_id: ObjectId, kind: WidgetKind, key: UiKey) ObjectId {
    var hasher = std.hash.Wyhash.init(parent_id);
    hasher.update(std.mem.asBytes(&@as(u16, @intFromEnum(kind))));
    switch (key) {
        .index => |index| {
            hasher.update(&[_]u8{0});
            hasher.update(std.mem.asBytes(&@as(u64, index)));
        },
        .int => |value| {
            hasher.update(&[_]u8{1});
            hasher.update(std.mem.asBytes(&value));
        },
        .str => |value| {
            hasher.update(&[_]u8{2});
            hasher.update(value);
        },
    }
    const value = hasher.final();
    return if (value == 0) zero_id_fallback else value;
}
