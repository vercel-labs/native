//! Experimental declarative authoring layer over the retained widget tree.
//!
//! `Ui(Msg)` builds widget trees without hand-assigned object ids, absolute
//! frames, or string command dispatch:
//!
//! - Identity is structural: each widget id is derived from its parent id,
//!   kind, and key (explicit in `each`, sibling index otherwise), so ids stay
//!   stable across rebuilds and keyed reorders without author bookkeeping.
//!   Structural identity is parent-scoped: a keyed item that moves to a
//!   different parent gets a new id. Items that migrate between containers
//!   (board columns, tab pages) should set `global_key`, which pins identity
//!   to (kind, key) independent of position in the tree.
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
const global_id_seed: u64 = 0x5eed_2e70_a11c_e002;
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
    input,
};

/// A color design token referenced by name (the fields of
/// `canvas.ColorTokens`). Markup style attributes (`background="surface"`)
/// parse into these; `finalizeWithTokens` resolves them against live
/// tokens, so themed apps re-resolve on retheme rebuilds.
pub const ColorTokenName = std.meta.FieldEnum(canvas.ColorTokens);

/// A radius design token referenced by name (the fields of
/// `canvas.RadiusTokens`).
pub const RadiusTokenName = std.meta.FieldEnum(canvas.RadiusTokens);

/// Token references for the style a widget should resolve at finalize
/// time. Each maps to the matching `WidgetStyle` field and only applies
/// when the author has not already set that field explicitly
/// (`border_color` maps to `WidgetStyle.border`; the markup attribute is
/// `border-color`, keeping bare `border` free for a future width
/// shorthand).
pub const StyleTokenRefs = struct {
    background: ?ColorTokenName = null,
    foreground: ?ColorTokenName = null,
    accent: ?ColorTokenName = null,
    accent_foreground: ?ColorTokenName = null,
    border_color: ?ColorTokenName = null,
    focus_ring: ?ColorTokenName = null,
    radius: ?RadiusTokenName = null,
};

fn colorTokenValue(colors: canvas.ColorTokens, ref: ColorTokenName) canvas.Color {
    return switch (ref) {
        inline else => |tag| @field(colors, @tagName(tag)),
    };
}

fn radiusTokenValue(radius: canvas.RadiusTokens, ref: RadiusTokenName) f32 {
    return switch (ref) {
        inline else => |tag| @field(radius, @tagName(tag)),
    };
}

/// Resolve token references into concrete style values, keeping any style
/// field the author already set explicitly.
fn applyStyleTokens(style: *canvas.WidgetStyle, refs: StyleTokenRefs, tokens: *const canvas.DesignTokens) void {
    if (refs.background) |ref| {
        if (style.background == null) style.background = colorTokenValue(tokens.colors, ref);
    }
    if (refs.foreground) |ref| {
        if (style.foreground == null) style.foreground = colorTokenValue(tokens.colors, ref);
    }
    if (refs.accent) |ref| {
        if (style.accent == null) style.accent = colorTokenValue(tokens.colors, ref);
    }
    if (refs.accent_foreground) |ref| {
        if (style.accent_foreground == null) style.accent_foreground = colorTokenValue(tokens.colors, ref);
    }
    if (refs.border_color) |ref| {
        if (style.border == null) style.border = colorTokenValue(tokens.colors, ref);
    }
    if (refs.focus_ring) |ref| {
        if (style.focus_ring == null) style.focus_ring = colorTokenValue(tokens.colors, ref);
    }
    if (refs.radius) |ref| {
        if (style.radius == null) style.radius = radiusTokenValue(tokens.radius, ref);
    }
}

pub fn Ui(comptime Msg: type) type {
    return struct {
        const Self = @This();

        arena: std.mem.Allocator,
        failed: bool = false,

        pub const ElementOptions = struct {
            /// Sibling-scoped identity: the widget id hashes the parent
            /// chain plus this key, so it survives reorders among siblings
            /// but NOT moving to a different parent.
            key: ?UiKey = null,
            /// Parent-independent identity: the widget id hashes only the
            /// kind and this key, so it survives reparenting (e.g. an item
            /// moving between board columns). The author guarantees each
            /// (kind, global_key) pair is unique within the tree.
            global_key: ?UiKey = null,
            frame: geometry.RectF = .{},
            /// Widget text (text-field contents, initial control labels).
            /// Text-bearing sugar methods (`text`, `button`, ...) override
            /// this with their content argument.
            text: []const u8 = "",
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
            /// Named token references resolved against design tokens in
            /// `finalizeWithTokens`; explicit `style` values win.
            style_tokens: StyleTokenRefs = .{},
            semantics: canvas.WidgetSemantics = .{},
            on_press: ?Msg = null,
            on_toggle: ?Msg = null,
            on_change: ?Msg = null,
            on_submit: ?Msg = null,
            /// Message constructor for text edits: called with each
            /// `TextInputEvent` on text-entry widgets. Pair with `inputMsg`.
            on_input: ?InputMsgFn = null,
            /// Message constructor for value changes carrying the new value
            /// (slider steps, accessibility set-value). Pair with `valueMsg`.
            on_value: ?ValueMsgFn = null,
        };

        pub const InputMsgFn = *const fn (edit: canvas.TextInputEvent) Msg;
        pub const ValueMsgFn = *const fn (value: f32) Msg;

        pub const Node = struct {
            widget: Widget = .{ .kind = .stack },
            key: ?UiKey = null,
            global_key: ?UiKey = null,
            style_tokens: StyleTokenRefs = .{},
            on_press: ?Msg = null,
            on_toggle: ?Msg = null,
            on_change: ?Msg = null,
            on_submit: ?Msg = null,
            on_input: ?InputMsgFn = null,
            on_value: ?ValueMsgFn = null,
            nodes: []const Node = &.{},
        };

        pub const Handler = struct {
            id: ObjectId,
            event: UiHandlerEvent,
            action: Action,

            pub const Action = union(enum) {
                message: Msg,
                input: InputMsgFn,
                value: ValueMsgFn,
            };
        };

        /// Comptime message constructor for `on_input`: `inputMsg(.draft)`
        /// yields a function building `Msg{ .draft = edit }`.
        pub fn inputMsg(comptime tag: std.meta.Tag(Msg)) InputMsgFn {
            return struct {
                fn make(edit: canvas.TextInputEvent) Msg {
                    return @unionInit(Msg, @tagName(tag), edit);
                }
            }.make;
        }

        /// Comptime message constructor for `on_value`: `valueMsg(.confidence)`
        /// yields a function building `Msg{ .confidence = value }`.
        pub fn valueMsg(comptime tag: std.meta.Tag(Msg)) ValueMsgFn {
            return struct {
                fn make(value: f32) Msg {
                    return @unionInit(Msg, @tagName(tag), value);
                }
            }.make;
        }

        pub const Tree = struct {
            root: Widget,
            handlers: []const Handler,

            pub fn msgFor(self: Tree, id: ObjectId, event: UiHandlerEvent) ?Msg {
                for (self.handlers) |handler| {
                    if (handler.id == id and handler.event == event and handler.action == .message) {
                        return handler.action.message;
                    }
                }
                return null;
            }

            /// Typed dispatch for text edits: builds the message through the
            /// widget's `on_input` constructor.
            pub fn msgForTextEdit(self: Tree, id: ObjectId, edit: canvas.TextInputEvent) ?Msg {
                for (self.handlers) |handler| {
                    if (handler.id == id and handler.event == .input and handler.action == .input) {
                        return handler.action.input(edit);
                    }
                }
                return null;
            }

            /// Typed dispatch for value changes: builds the message through
            /// the widget's `on_value` constructor.
            pub fn msgForValue(self: Tree, id: ObjectId, value: f32) ?Msg {
                for (self.handlers) |handler| {
                    if (handler.id == id and handler.event == .change and handler.action == .value) {
                        return handler.action.value(value);
                    }
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
                if (isTextEntryWidget(widget) and !widget.state.disabled) {
                    if (keyboard.textEditEvent()) |edit| {
                        if (self.msgForTextEdit(target_id, edit)) |msg| return msg;
                    }
                }
                return null;
            }

            fn msgForIntent(self: Tree, id: ObjectId, intent: canvas.WidgetControlIntent) ?Msg {
                return switch (intent.kind) {
                    .press => self.msgFor(id, .press),
                    .toggle => self.msgFor(id, .toggle),
                    .select => self.msgFor(id, .press),
                    .set_value => blk: {
                        if (intent.value) |value| {
                            if (self.msgForValue(id, value)) |msg| break :blk msg;
                        }
                        break :blk self.msgFor(id, .change);
                    },
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
                .global_key = options.global_key,
                .style_tokens = options.style_tokens,
                .on_press = options.on_press,
                .on_toggle = options.on_toggle,
                .on_change = options.on_change,
                .on_submit = options.on_submit,
                .on_input = options.on_input,
                .on_value = options.on_value,
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

        /// Assign structural ids, materialize widget children, and collect
        /// the typed handler table. Container sizing is measured by the
        /// engine's `intrinsicWidgetSize` at layout time. Style token
        /// references resolve against the default tokens; themed apps use
        /// `finalizeWithTokens`.
        pub fn finalize(self: *Self, node: Node) error{OutOfMemory}!Tree {
            return self.finalizeWithTokens(node, .{});
        }

        /// `finalize` against live design tokens: node `style_tokens`
        /// references (markup `background="surface"`, `radius="md"`, ...)
        /// resolve into concrete `widget.style` values here, unless the
        /// author already set the style field explicitly. `UiApp` calls
        /// this with `effectiveTokens()` on every rebuild, so token refs
        /// re-resolve when the theme changes.
        pub fn finalizeWithTokens(self: *Self, node: Node, tokens: canvas.DesignTokens) error{OutOfMemory}!Tree {
            if (self.failed) return error.OutOfMemory;
            const handler_capacity = countHandlers(node);
            const handlers = try self.arena.alloc(Handler, handler_capacity);
            var handler_len: usize = 0;
            const root_key = node.key orelse UiKey{ .index = 0 };
            const root = try self.finalizeNode(node, root_id_seed, root_key, handlers, &handler_len, &tokens);
            return .{ .root = root, .handlers = handlers[0..handler_len] };
        }

        fn finalizeNode(
            self: *Self,
            node: Node,
            parent_id: ObjectId,
            key: UiKey,
            handlers: []Handler,
            handler_len: *usize,
            tokens: *const canvas.DesignTokens,
        ) error{OutOfMemory}!Widget {
            var widget = node.widget;
            applyStyleTokens(&widget.style, node.style_tokens, tokens);
            widget.id = if (node.global_key) |global_key|
                structuralId(global_id_seed, widget.kind, global_key)
            else
                structuralId(parent_id, widget.kind, key);
            // Typed handlers imply the matching accessibility actions, the
            // same way a stringly `command` does for engine-owned dispatch.
            if (node.on_press != null) widget.semantics.actions.press = true;
            if (node.on_toggle != null) widget.semantics.actions.toggle = true;
            if (node.on_input != null) widget.semantics.actions.set_text = true;
            if (widget.kind == .slider and (node.on_value != null or node.on_change != null)) {
                widget.semantics.actions.increment = true;
                widget.semantics.actions.decrement = true;
            }
            if (node.nodes.len > 0) {
                const child_widgets = try self.arena.alloc(Widget, node.nodes.len);
                for (node.nodes, 0..) |child, index| {
                    const child_key = child.key orelse UiKey{ .index = index };
                    child_widgets[index] = try self.finalizeNode(child, widget.id, child_key, handlers, handler_len, tokens);
                }
                widget.children = child_widgets;
            }
            appendHandler(handlers, handler_len, widget.id, .press, node.on_press);
            appendHandler(handlers, handler_len, widget.id, .toggle, node.on_toggle);
            appendHandler(handlers, handler_len, widget.id, .change, node.on_change);
            appendHandler(handlers, handler_len, widget.id, .submit, node.on_submit);
            if (node.on_input) |make| {
                handlers[handler_len.*] = .{ .id = widget.id, .event = .input, .action = .{ .input = make } };
                handler_len.* += 1;
            }
            if (node.on_value) |make| {
                handlers[handler_len.*] = .{ .id = widget.id, .event = .change, .action = .{ .value = make } };
                handler_len.* += 1;
            }
            return widget;
        }

        fn appendHandler(handlers: []Handler, handler_len: *usize, id: ObjectId, event: UiHandlerEvent, msg: ?Msg) void {
            const value = msg orelse return;
            handlers[handler_len.*] = .{ .id = id, .event = event, .action = .{ .message = value } };
            handler_len.* += 1;
        }

        fn countHandlers(node: Node) usize {
            var total: usize = 0;
            if (node.on_press != null) total += 1;
            if (node.on_toggle != null) total += 1;
            if (node.on_change != null) total += 1;
            if (node.on_submit != null) total += 1;
            if (node.on_input != null) total += 1;
            if (node.on_value != null) total += 1;
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
            if (Children == []const Node or Children == []Node) {
                // Copy rather than alias: callers may pass slices of locals
                // that would not outlive finalize.
                if (children.len == 0) return &.{};
                const nodes = self.arena.alloc(Node, children.len) catch {
                    self.failed = true;
                    return &.{};
                };
                @memcpy(nodes, children);
                return nodes;
            }
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
                .text = options.text,
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

fn findWidgetIn(widget: Widget, id: ObjectId) ?Widget {
    if (widget.id == id) return widget;
    for (widget.children) |child| {
        if (findWidgetIn(child, id)) |found| return found;
    }
    return null;
}

fn isTextEntryWidget(widget: Widget) bool {
    return switch (widget.kind) {
        .input, .text_field, .search_field, .combobox, .textarea => true,
        else => false,
    };
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
