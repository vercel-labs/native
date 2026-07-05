//! Markup interpreter: turns a parsed markup document into `Ui(Msg)` nodes
//! against a concrete Model/Msg pair (grammar reference:
//! skill-data/native-ui/SKILL.md).
//!
//! The document is runtime data but binding and message resolution is
//! comptime-unrolled: loop item types are collected from the Model at
//! comptime, `for` scopes carry type-erased item pointers tagged into that
//! comptime list, and paths resolve through `inline for` field/method
//! matching. A markup view builds exactly what an equivalent hand-written
//! `view(ui, model)` would: same structural ids, same handler table.

const std = @import("std");
const canvas = @import("root.zig");
const markup = @import("ui_markup.zig");

pub const BuildError = error{ MarkupBuild, OutOfMemory };

pub const BuildDiagnostic = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8 = "",
    /// Source file the position refers to (relative to the markup root),
    /// stamped by import resolution; empty for single-file documents.
    path: []const u8 = "",
};

/// A resolved binding value. Enums resolve to their tag name so equality
/// against enum-typed loop variables and literals works uniformly. Defined
/// in the expression core (ui_markup_expr.zig) and shared with the
/// comptime-compiled path so both engines convert, compare, and evaluate
/// values through the same code.
pub const Value = markup.expr.Value;

pub fn MarkupView(comptime ModelT: type, comptime MsgT: type) type {
    return struct {
        const Self = @This();
        pub const Ui = canvas.Ui(MsgT);

        document: markup.MarkupDocument,
        diagnostic: BuildDiagnostic = .{},

        pub fn init(arena: std.mem.Allocator, source: []const u8) (markup.ParseError || error{OutOfMemory})!Self {
            var parser = markup.Parser.init(arena, source);
            const document = try parser.parse();
            return .{ .document = document };
        }

        pub fn initDiagnostic(arena: std.mem.Allocator, source: []const u8, diagnostic: *markup.MarkupErrorInfo) (markup.ParseError || error{OutOfMemory})!Self {
            var parser = markup.Parser.init(arena, source);
            defer diagnostic.* = parser.diagnostic;
            const document = try parser.parse();
            return .{ .document = document };
        }

        /// Wrap an already-resolved document (the import resolver's
        /// output, or a parsed single-file document).
        pub fn fromDocument(document: markup.MarkupDocument) Self {
            return .{ .document = document };
        }

        /// Build the view for the current model. Compatible with the
        /// hand-written `view(ui, model)` shape.
        pub fn build(self: *Self, ui: *Ui, model: *const ModelT) BuildError!Ui.Node {
            if (self.document.imports.len > 0) {
                return self.failNode(self.document.imports[0], markup.import_unresolved_message);
            }
            const root = self.document.root orelse {
                self.diagnostic = .{ .line = 1, .column = 1, .message = markup.component_file_view_message };
                return error.MarkupBuild;
            };
            var scope = Scope{ .model = model, .arena = ui.arena };
            return self.buildNode(ui, &scope, root);
        }

        // ------------------------------------------------------- scopes

        /// Types a `for` loop can iterate: element types of Model slice or
        /// array fields, public array/slice declarations, and public
        /// functions returning slices (optionally taking an arena).
        const item_types = collectItemTypes(ModelT);

        /// Shared eval-branch budget for this view's Model/Msg
        /// scaled comptime walks (`inline for` over model fields/decls,
        /// msg variants, and `item_types`); see `typeScanQuota`.
        const scan_quota = typeScanQuota(ModelT) + typeScanQuota(MsgT);

        /// A named value in scope: a `for` loop item (typed pointer tagged
        /// into `item_types`), a slice-valued template arg (iterable by a
        /// `for each` inside the template), a scalar template arg (usable
        /// in bindings, interpolation, and equality), or the anonymous
        /// slot capture a `<use>` with children pushes for its body.
        const ScopeEntry = struct {
            name: []const u8,
            payload: Payload,

            const Payload = union(enum) {
                item: struct { type_index: usize, ptr: *const anyopaque },
                slice: struct { type_index: usize, ptr: *const anyopaque, len: usize },
                value: Value,
                slot: SlotCapture,
            };
        };

        /// A `<use>` site's children plus the scope state they must build
        /// under: the consumer's scope, restored when the template body
        /// reaches its `<slot/>`. Pushed with an empty name (never a
        /// binding head), so lookups skip it.
        const SlotCapture = struct {
            nodes: []const markup.MarkupNode,
            len: usize,
            floor: usize,
            template_ctx: ?usize,
        };

        const max_scope_depth = 16;

        const Scope = struct {
            model: *const ModelT,
            /// The build arena, threaded to arena-taking scalar binding fns
            /// (`pub fn summary(m: *const Model, arena: std.mem.Allocator)
            /// []const u8`). Strings they produce live exactly as long as
            /// the built tree.
            arena: std.mem.Allocator,
            entries: [max_scope_depth]ScopeEntry = undefined,
            len: usize = 0,
            /// Bindings resolve entries[floor..len] then the model: a
            /// template body sees its args and its own loop variables but
            /// not the loop variables at the expansion site.
            floor: usize = 0,
            /// Template expansion depth: a hard cap on runtime recursion
            /// for documents the validator never saw. Legit nesting is
            /// bounded by define-before-use (checked per expansion via
            /// `template_ctx`) plus lexical slot-content depth.
            use_depth: usize = 0,
            /// Index of the template whose body is currently building, or
            /// null in root/consumer scope. A use inside a body may only
            /// reference earlier templates (the validator's rule, enforced
            /// again here so an unvalidated document cannot recurse).
            template_ctx: ?usize = null,

            fn lookup(self: *const Scope, head: []const u8) ?*const ScopeEntry {
                var index = self.len;
                while (index > self.floor) {
                    index -= 1;
                    if (std.mem.eql(u8, self.entries[index].name, head)) return &self.entries[index];
                }
                return null;
            }

            /// The innermost slot capture visible to the current template
            /// body (never looks below the floor: an inner template with
            /// no use-site children must not see an outer capture).
            fn slotCapture(self: *const Scope) ?SlotCapture {
                var index = self.len;
                while (index > self.floor) {
                    index -= 1;
                    if (self.entries[index].payload == .slot) return self.entries[index].payload.slot;
                }
                return null;
            }
        };

        // ------------------------------------------------------ building

        fn buildNode(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            switch (node.kind) {
                .element => return self.buildElement(ui, scope, node),
                .use_block => return self.buildUse(ui, scope, node),
                .template_block => return self.failNode(node, markup.template_top_level_message),
                .import_block => return self.failNode(node, markup.import_top_level_message),
                .slot_block => return self.failNode(node, markup.slot_outside_template_message),
                .text => return self.failNode(node, "text content is only allowed inside text-bearing elements"),
                .for_block, .if_block, .else_block => return self.failNode(node, "structure tags are only allowed inside an element"),
            }
        }

        fn buildElement(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (std.mem.eql(u8, node.name, "markdown")) {
                return self.buildMarkdown(ui, scope, node);
            }
            if (std.mem.eql(u8, node.name, "stepper")) {
                return self.buildStepper(ui, scope, node);
            }
            if (std.mem.eql(u8, node.name, "step")) {
                // Steps inside a stepper are consumed by buildStepper.
                return self.failNode(node, markup.step_parent_message);
            }
            if (std.mem.eql(u8, node.name, "timeline")) {
                return self.buildTimeline(ui, scope, node);
            }
            if (std.mem.eql(u8, node.name, "timeline-item")) {
                return self.buildTimelineItem(ui, scope, node);
            }
            const kind = elementKind(node.name) orelse {
                return self.failNode(node, "unknown element");
            };
            // Value/text handlers on non-hit-target kinds can never fire
            // (the element has no control or text behavior); reject
            // instead of silently accepting a dead handler. on-press and
            // on-toggle are exempt: a bound press handler makes any
            // element a hit target, and presses on non-interactive
            // content inside it fall through to it. Mirrors the validator
            // and the compiled engine's compile error.
            if (!canvas.widgetKindHitTarget(kind)) {
                for (node.attrs) |attribute| {
                    if (std.mem.startsWith(u8, attribute.name, "on-") and markup.deadHandlerOnNonHitTarget(attribute.name)) {
                        return self.failNode(node, markup.non_hit_target_handler_message);
                    }
                    // Autofocus can never land here: nothing about this
                    // element is focusable. Mirrors the validator and
                    // the compiled engine's compile error.
                    if (std.mem.eql(u8, attribute.name, "autofocus")) {
                        return self.failNode(node, markup.autofocus_element_message);
                    }
                }
            }
            // Stacking kinds give every child the full content box, so a
            // gap can never space them; reject the dead layout data
            // instead of silently stacking children on top of each other.
            // Mirrors the validator and the compiled engine's compile
            // error.
            if (canvas.widgetKindStacksChildren(kind)) {
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "gap")) {
                        return self.failNode(node, markup.stack_container_gap_message);
                    }
                }
            }
            // Only plain text leaves word-wrap; anywhere else the option
            // is silently inert dead layout data. Mirrors the validator
            // and the compiled engine's compile error.
            if (kind != .text) {
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "wrap")) {
                        return self.failNode(node, markup.wrap_element_message);
                    }
                }
            }
            // Splits take exactly two static pane children (the divider
            // sits between fixed panes). Mirrors the validator and the
            // compiled engine's compile error.
            if (kind == .split) {
                var pane_count: usize = 0;
                for (node.children) |child| {
                    switch (child.kind) {
                        .element, .use_block => pane_count += 1,
                        else => return self.failNode(child, markup.split_children_message),
                    }
                }
                if (pane_count != 2) return self.failNode(node, markup.split_children_message);
            }
            var options: Ui.ElementOptions = .{};
            try self.applyAttrs(scope, node, &options);

            if (kind == .icon) {
                // Closed vocabulary: a literal built-in icon name, no
                // children. Mirrors the validator and the compiled
                // engine's comptime checks.
                const raw = node.attr("name") orelse return self.failNode(node, markup.icon_missing_name_message);
                const expression = markup.parseAttrExpression(raw) orelse return self.failNode(node, markup.icon_name_message);
                if (expression != .literal) return self.failNode(node, markup.icon_name_message);
                if (canvas.icons.find(expression.literal) == null) return self.failNode(node, markup.icon_name_message);
                if (node.children.len > 0) return self.failNode(node, markup.icon_children_message);
                var built = ui.el(kind, options, .{});
                built.widget.text = expression.literal;
                return built;
            }

            if (elementTakesText(kind)) {
                const text = try self.interpolatedText(ui, scope, node);
                var built = ui.el(kind, options, .{});
                built.widget.text = text;
                // Avatars clip their runtime image to the avatar circle,
                // exactly like `Ui.avatar` (a no-op while the id is 0 and
                // the initials fallback renders).
                if (kind == .avatar) built.widget.image_fit = .cover;
                return built;
            }

            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            try self.buildChildren(ui, scope, node, &children);
            // Tab triggers ARE segmented controls: markup composes the
            // strip from `<button>` children (segmented-control is a
            // documented markup exclusion), and the engine lowers them to
            // the widget kind tab strips are built on — so the active
            // trigger lifts to the surface with a hairline exactly like
            // the Zig builder's tabs. Handlers ride the widget id, so
            // `selected=`/`on-press` bindings are untouched.
            if (kind == .tabs) lowerTabsTriggers(children.items);
            return ui.el(kind, options, @as([]const Ui.Node, children.items));
        }

        fn buildChildren(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
            return self.buildChildList(ui, scope, node.children, out);
        }

        fn buildChildList(self: *Self, ui: *Ui, scope: *Scope, children: []const markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
            var index: usize = 0;
            while (index < children.len) : (index += 1) {
                const child = children[index];
                switch (child.kind) {
                    .element => try out.append(ui.arena, try self.buildElement(ui, scope, child)),
                    .use_block => try out.append(ui.arena, try self.buildUse(ui, scope, child)),
                    .template_block => return self.failVoid(child, markup.template_top_level_message),
                    .import_block => return self.failVoid(child, markup.import_top_level_message),
                    .slot_block => try self.buildSlot(ui, scope, child, out),
                    .for_block => {
                        var else_node: ?markup.MarkupNode = null;
                        if (index + 1 < children.len and children[index + 1].kind == .else_block) {
                            else_node = children[index + 1];
                            index += 1;
                        }
                        const item_count = try self.buildFor(ui, scope, child, out);
                        if (item_count == 0) {
                            if (else_node) |else_block| {
                                try self.buildChildren(ui, scope, else_block, out);
                            }
                        }
                    },
                    .if_block => {
                        const test_value = child.attr("test") orelse {
                            return self.failVoid(child, "if requires a test attribute");
                        };
                        const condition = try self.evalAttrExpression(scope, child, test_value);
                        var else_node: ?markup.MarkupNode = null;
                        if (index + 1 < children.len and children[index + 1].kind == .else_block) {
                            else_node = children[index + 1];
                            index += 1;
                        }
                        if (condition.truthy()) {
                            try self.buildChildren(ui, scope, child, out);
                        } else if (else_node) |else_block| {
                            try self.buildChildren(ui, scope, else_block, out);
                        }
                    },
                    .else_block => return self.failVoid(child, markup.else_placement_message),
                    .text => return self.failVoid(child, "text content is only allowed inside text-bearing elements"),
                }
            }
        }

        /// `<slot/>` in a template body: build the use-site children (the
        /// slot capture) IN THE CONSUMER'S SCOPE, inline at the slot's
        /// position — the point of slots is that content sees the model
        /// paths and loop variables where the `<use>` was written. The
        /// consumer's scope state is restored around the content build
        /// (and the body's own entries saved, since the entries array is
        /// shared), so structural ids and bindings behave exactly as if
        /// the content were built at the use site and inserted here.
        fn buildSlot(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
            if (node.attrs.len > 0) return self.failVoid(node, markup.slot_attrs_message);
            if (node.children.len > 0) return self.failVoid(node.children[0], markup.slot_children_message);
            const capture = scope.slotCapture() orelse {
                if (scope.template_ctx == null) {
                    return self.failVoid(node, markup.slot_outside_template_message);
                }
                // A use with no children: the slot renders empty.
                return;
            };
            if (capture.nodes.len == 0) return;
            var saved_entries: [max_scope_depth]ScopeEntry = undefined;
            const saved_len = scope.len;
            const saved_floor = scope.floor;
            const saved_ctx = scope.template_ctx;
            for (scope.entries[capture.len..saved_len], 0..) |entry, offset| {
                saved_entries[offset] = entry;
            }
            scope.len = capture.len;
            scope.floor = capture.floor;
            scope.template_ctx = capture.template_ctx;
            defer {
                for (saved_entries[0 .. saved_len - capture.len], 0..) |entry, offset| {
                    scope.entries[capture.len + offset] = entry;
                }
                scope.len = saved_len;
                scope.floor = saved_floor;
                scope.template_ctx = saved_ctx;
            }
            try self.buildChildList(ui, scope, capture.nodes, out);
        }

        /// Expands a `for` block: per item, the whole body (one or more
        /// elements, `use` expansions, and nested `for`/`if`/`else`
        /// structure) is appended to `out`. Returns the item count so the
        /// caller can render a trailing `<else>` for the empty case.
        fn buildFor(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!usize {
            @setEvalBranchQuota(scan_quota);
            const each = node.attr("each") orelse return self.failVoid(node, "for requires an each attribute");
            const as_name = node.attr("as") orelse return self.failVoid(node, "for requires an as attribute");
            const key_field = node.attr("key");
            if (scope.len >= max_scope_depth) return self.failVoid(node, "for nesting is too deep");
            if (node.children.len == 0) return self.failVoid(node, markup.for_children_message);
            for (node.children) |child| {
                switch (child.kind) {
                    .element, .use_block, .for_block, .if_block, .else_block, .slot_block => {},
                    else => return self.failVoid(child, markup.for_children_message),
                }
            }

            inline for (item_types, 0..) |Item, type_index| {
                if (try self.iterateItems(ui, Item, type_index, scope, each)) |items| {
                    for (items) |*item| {
                        scope.entries[scope.len] = .{
                            .name = as_name,
                            .payload = .{ .item = .{ .type_index = type_index, .ptr = @ptrCast(item) } },
                        };
                        scope.len += 1;
                        defer scope.len -= 1;

                        const first_emitted = out.items.len;
                        try self.buildChildren(ui, scope, node, out);
                        if (key_field) |field| {
                            // The item key stamps every node this item
                            // emitted (unless the node claims its own
                            // identity); later slots get a slot-suffixed
                            // key so same-kind siblings stay distinct.
                            const base = try self.itemKey(Item, item, node, field);
                            for (out.items[first_emitted..], 0..) |*built, slot| {
                                if (built.key == null and built.global_key == null) {
                                    built.key = try canvas.forSlotKey(ui.arena, base, slot);
                                }
                            }
                        }
                    }
                    return items.len;
                }
            }
            return self.failVoid(node, "each does not name an iterable (a model slice, array, or fn - or a slice-valued template arg)");
        }

        /// Resolve `each` to a slice of Item: a slice-valued template arg
        /// in scope, or on the model a field, a public array declaration,
        /// or a public function (with or without arena).
        fn iterateItems(self: *Self, ui: *Ui, comptime Item: type, comptime type_index: usize, scope: *Scope, each: []const u8) BuildError!?[]const Item {
            @setEvalBranchQuota(scan_quota);
            _ = self;
            if (scope.lookup(each)) |entry| {
                switch (entry.payload) {
                    .slice => |slice_entry| {
                        if (slice_entry.type_index != type_index) return null;
                        const items: [*]const Item = @ptrCast(@alignCast(slice_entry.ptr));
                        return items[0..slice_entry.len];
                    },
                    // The name is shadowed by a non-iterable scope entry.
                    else => return null,
                }
            }
            const model = scope.model;
            inline for (@typeInfo(ModelT).@"struct".fields) |field| {
                if (comptime sliceElement(field.type) != null and sliceElement(field.type).? == Item) {
                    if (std.mem.eql(u8, field.name, each)) {
                        return asSlice(Item, &@field(model, field.name));
                    }
                }
            }
            inline for (@typeInfo(ModelT).@"struct".decls) |decl| {
                const DeclType = @TypeOf(@field(ModelT, decl.name));
                if (comptime sliceElement(DeclType) != null and sliceElement(DeclType).? == Item) {
                    if (std.mem.eql(u8, decl.name, each)) {
                        return asSlice(Item, &@field(ModelT, decl.name));
                    }
                }
                if (comptime isItemFn(DeclType, Item, false)) {
                    if (std.mem.eql(u8, decl.name, each)) {
                        return @field(ModelT, decl.name)(model);
                    }
                }
                if (comptime isItemFn(DeclType, Item, true)) {
                    if (std.mem.eql(u8, decl.name, each)) {
                        return @field(ModelT, decl.name)(model, ui.arena);
                    }
                }
            }
            return null;
        }

        // ------------------------------------------------------- markdown

        const Md = canvas.markdown.Markdown(MsgT);

        /// `<markdown source="{body}" on-link="open_url"
        /// on-details="toggle_details" details-expanded="{flags}" />`:
        /// a leaf that renders its source binding through
        /// `native_sdk.markdown.Markdown(Msg).view`. Only `source` is
        /// required; without `on-details`/`details-expanded` the details
        /// blocks render collapsed and inert (Md.view's null defaults).
        fn buildMarkdown(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (node.children.len != 0) {
                return self.failNode(node.children[0], markup.markdown_children_message);
            }
            var options: Md.Options = .{};
            var source_text: ?[]const u8 = null;
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "source")) {
                    const expression = markup.parseAttrExpression(attribute.value) orelse {
                        return self.failNode(node, markup.markdown_source_message);
                    };
                    if (expression != .binding) return self.failNode(node, markup.markdown_source_message);
                    const value = try self.evalBinding(scope, node, expression.binding, true);
                    source_text = switch (value) {
                        .string => |text| text,
                        else => return self.failNode(node, markup.markdown_source_message),
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "on-link")) {
                    const expression = markup.parseMessageExpression(attribute.value) orelse {
                        return self.failNode(node, markup.markdown_on_link_message);
                    };
                    if (expression.payload.len != 0) return self.failNode(node, markup.markdown_on_link_message);
                    options.on_link = linkConstructor(expression.tag) orelse {
                        return self.failNode(node, markup.markdown_on_link_message);
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "on-details")) {
                    const expression = markup.parseMessageExpression(attribute.value) orelse {
                        return self.failNode(node, markup.markdown_on_details_message);
                    };
                    if (expression.payload.len != 0) return self.failNode(node, markup.markdown_on_details_message);
                    options.on_details = detailsConstructor(expression.tag) orelse {
                        return self.failNode(node, markup.markdown_on_details_message);
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "details-expanded")) {
                    const expression = markup.parseAttrExpression(attribute.value) orelse {
                        return self.failNode(node, markup.markdown_details_expanded_message);
                    };
                    if (expression != .binding) return self.failNode(node, markup.markdown_details_expanded_message);
                    options.details_expanded = try self.boolItems(ui, scope, node, expression.binding);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "issue-link-base")) {
                    const expression = markup.parseAttrExpression(attribute.value) orelse {
                        return self.failNode(node, markup.markdown_issue_link_base_message);
                    };
                    if (expression == .equals) return self.failNode(node, markup.markdown_issue_link_base_message);
                    const value = try self.evalAttrExpression(scope, node, attribute.value);
                    const text = switch (value) {
                        .string => |text| text,
                        else => return self.failNode(node, markup.markdown_issue_link_base_message),
                    };
                    if (text.len > 0) options.issue_link_base = text;
                    continue;
                }
                return self.failNode(node, markup.markdown_attr_message);
            }
            const source_value = source_text orelse return self.failNode(node, markup.markdown_source_message);
            return Md.view(ui, source_value, options);
        }

        // ------------------------------------------------ stepper/timeline

        /// `<stepper active="{stage_index}"><step>Work</step>...</stepper>`:
        /// the composite stage stepper. Steps are text leaves; their
        /// completed/active/pending states derive from position against
        /// the active index, mirroring `Ui.stepper`.
        fn buildStepper(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.StepperOptions = .{};
            var has_active = false;
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "active")) {
                    const value = try self.evalAttrExpression(scope, node, attribute.value);
                    options.active = switch (value) {
                        .integer => |int| if (int < 0) 0 else @intCast(int),
                        else => return self.failNode(node, markup.stepper_active_message),
                    };
                    has_active = true;
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    options.semantics.label = try self.stringAttr(scope, node, attribute.value, "label expects text");
                    continue;
                }
                return self.failNode(node, markup.stepper_attr_message);
            }
            if (!has_active) return self.failNode(node, markup.stepper_active_message);

            const steps = try ui.arena.alloc(Ui.StepperStep, node.children.len);
            for (node.children, 0..) |child, index| {
                if (child.kind != .element or !std.mem.eql(u8, child.name, "step")) {
                    return self.failNode(child, markup.stepper_children_message);
                }
                for (child.attrs) |attribute| {
                    if (!std.mem.eql(u8, attribute.name, "kind")) {
                        return self.failNode(child, markup.step_attr_message);
                    }
                }
                steps[index] = .{ .label = try self.interpolatedText(ui, scope, child) };
            }
            return ui.stepper(options, steps);
        }

        /// `<timeline gap="4">` — a list container whose children are
        /// timeline-item elements (structure tags work); mirrors
        /// `Ui.timeline`.
        fn buildTimeline(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.TimelineOptions = .{};
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "gap")) {
                    options.gap = try self.floatAttr(scope, node, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "grow")) {
                    options.grow = try self.floatAttr(scope, node, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    options.semantics.label = try self.stringAttr(scope, node, attribute.value, "label expects text");
                    continue;
                }
                return self.failNode(node, markup.timeline_attr_message);
            }
            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            try self.buildChildren(ui, scope, node, &children);
            return ui.timeline(options, @as([]const Ui.Node, children.items));
        }

        /// `<timeline-item title="{entry.title}" description="..."
        /// meta="..." variant="primary" on-press="open_step:{entry.slot}"/>`:
        /// one composite ledger item; mirrors `Ui.timelineItem`.
        fn buildTimelineItem(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (node.children.len != 0) {
                return self.failNode(node.children[0], markup.timeline_item_children_message);
            }
            var options: Ui.TimelineItemOptions = .{ .title = "" };
            var has_title = false;
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "title")) {
                    options.title = try self.stringAttr(scope, node, attribute.value, markup.timeline_item_text_attr_message);
                    has_title = true;
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "description")) {
                    options.description = try self.stringAttr(scope, node, attribute.value, markup.timeline_item_text_attr_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "meta")) {
                    options.meta = try self.stringAttr(scope, node, attribute.value, markup.timeline_item_text_attr_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "indicator")) {
                    options.indicator = try self.stringAttr(scope, node, attribute.value, markup.timeline_item_text_attr_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "icon")) {
                    // Vector icon indicator: closed literal vocabulary,
                    // like every icon attribute.
                    const expression = markup.parseAttrExpression(attribute.value) orelse {
                        return self.failVoid(node, markup.button_icon_message);
                    };
                    if (expression != .literal) return self.failVoid(node, markup.button_icon_message);
                    if (canvas.icons.find(expression.literal) == null) return self.failVoid(node, markup.button_icon_message);
                    options.icon = expression.literal;
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "variant")) {
                    const text = try self.stringAttr(scope, node, attribute.value, "expected an option name");
                    options.variant = std.meta.stringToEnum(canvas.WidgetVariant, text) orelse {
                        return self.failNode(node, "unknown option value");
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "connector")) {
                    options.connector = (try self.evalAttrExpression(scope, node, attribute.value)).truthy();
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "selected")) {
                    options.selected = (try self.evalAttrExpression(scope, node, attribute.value)).truthy();
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "on-press")) {
                    // Reuse the full message-attr machinery (payload
                    // bindings included) through a scratch options value.
                    var scratch: Ui.ElementOptions = .{};
                    try self.applyMessageAttr(scope, node, &scratch, attribute);
                    options.on_press = scratch.on_press;
                    continue;
                }
                if (std.mem.startsWith(u8, attribute.name, "on-")) {
                    return self.failNode(node, markup.timeline_item_press_only_message);
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute.value);
                    continue;
                }
                return self.failNode(node, markup.timeline_item_attr_message);
            }
            if (!has_title) return self.failNode(node, markup.timeline_item_title_message);
            return ui.timelineItem(options);
        }

        fn stringAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, raw: []const u8, message: []const u8) BuildError![]const u8 {
            const value = try self.evalAttrExpression(scope, node, raw);
            return switch (value) {
                .string => |text| text,
                else => self.failValue(node, message),
            };
        }

        fn floatAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, raw: []const u8) BuildError!f32 {
            const value = try self.evalAttrExpression(scope, node, raw);
            return switch (value) {
                .float => |float| float,
                .integer => |int| @floatFromInt(int),
                else => self.failValue(node, "expected a number"),
            };
        }

        /// Msg constructor for markdown link presses: the tag must name a
        /// `[]const u8` variant (mirrors `Ui.linkMsg`).
        fn linkConstructor(tag: []const u8) ?Ui.LinkMsgFn {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (field.type == []const u8) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.linkMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
            }
            return null;
        }

        /// Msg constructor for markdown details toggles: the tag must name
        /// a `usize` variant (mirrors `Markdown(Msg).detailsMsg`).
        fn detailsConstructor(tag: []const u8) ?*const fn (index: usize) MsgT {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (field.type == usize) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Md.detailsMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
            }
            return null;
        }

        /// Resolve a `details-expanded` binding to a bool slice through the
        /// same sources `for each` accepts (scope slice args shadow model
        /// fields, pub decls, and fns).
        fn boolItems(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8) BuildError![]const bool {
            @setEvalBranchQuota(scan_quota);
            inline for (item_types, 0..) |Item, type_index| {
                if (comptime (Item == bool)) {
                    if (try self.iterateItems(ui, bool, type_index, scope, path)) |items| {
                        return items;
                    }
                }
            }
            return self.failText(node, markup.markdown_details_expanded_message);
        }

        // ------------------------------------------------------ templates

        /// A hard cap on template expansion nesting. Legit documents are
        /// bounded structurally (see `Scope.template_ctx`); the cap turns
        /// a hostile unvalidated document into an error, never a hang.
        const max_use_depth = 128;

        /// Build a `<use>` site: evaluate the template args against the
        /// use-site scope, push them (plus the slot capture when the use
        /// has children) as scope entries, and build the template's single
        /// element child in place — structural ids hash through the parent
        /// chain at the expansion site, exactly as if the body were
        /// written inline.
        fn buildUse(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            @setEvalBranchQuota(scan_quota);
            const template_name = node.attr("template") orelse {
                return self.failNode(node, markup.use_template_attr_message);
            };
            const template_index = self.document.templateIndex(template_name) orelse {
                return self.failNode(node, markup.use_undefined_template_message);
            };
            const template_node = self.document.templates[template_index];
            // The validator's define-before-use rule, enforced again at
            // build time: it is what makes expansion terminate, so an
            // unvalidated document must not slip past it.
            if (scope.template_ctx) |ctx_index| {
                if (template_index >= ctx_index) {
                    return self.failNode(node, markup.use_earlier_template_message);
                }
            }
            if (scope.use_depth >= max_use_depth) {
                return self.failNode(node, "template expansion nests too deeply");
            }
            if (template_node.children.len != 1 or template_node.children[0].kind != .element) {
                return self.failNode(template_node, markup.template_one_child_message);
            }
            if (markup.templateSecondSlot(template_node.children[0])) |second| {
                return self.failNode(second, markup.template_one_slot_message);
            }
            if (node.children.len != 0 and markup.templateSlot(template_node) == null) {
                return self.failNode(node.children[0], markup.use_children_without_slot_message);
            }

            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "template")) continue;
                if (!markup.templateDeclaresArg(template_node, attribute.name)) {
                    return self.failNode(node, markup.use_extra_arg_message);
                }
            }

            // Evaluate every arg against the pristine use-site scope before
            // any entry is pushed, so args cannot see each other.
            const saved_len = scope.len;
            const saved_floor = scope.floor;
            const saved_ctx = scope.template_ctx;
            var arg_count: usize = 0;
            var args = markup.templateArgs(template_node);
            while (args.next()) |token| {
                const arg = markup.parseTemplateArg(token);
                if (saved_len + arg_count >= max_scope_depth) {
                    return self.failNode(node, "template args nest too deep");
                }
                const payload: ScopeEntry.Payload = if (node.attr(arg.name)) |raw|
                    try self.argPayload(ui, scope, node, raw)
                else if (arg.default) |default| blk: {
                    // Defaults are literals only — a default cannot see
                    // any scope (validator and compiled-engine parity).
                    if (std.mem.indexOfScalar(u8, default, '{') != null) {
                        return self.failNode(template_node, markup.template_default_literal_message);
                    }
                    break :blk .{ .value = literalValue(default) };
                } else return self.failNode(node, markup.use_missing_arg_message);
                scope.entries[saved_len + arg_count] = .{ .name = arg.name, .payload = payload };
                arg_count += 1;
            }
            // The slot capture: the use-site children plus the scope state
            // to build them under, consumed by the body's <slot/>.
            if (saved_len + arg_count >= max_scope_depth) {
                return self.failNode(node, "template args nest too deep");
            }
            scope.entries[saved_len + arg_count] = .{
                .name = "",
                .payload = .{ .slot = .{
                    .nodes = node.children,
                    .len = saved_len,
                    .floor = saved_floor,
                    .template_ctx = saved_ctx,
                } },
            };
            arg_count += 1;

            scope.len = saved_len + arg_count;
            scope.floor = saved_len;
            scope.use_depth += 1;
            scope.template_ctx = template_index;
            defer {
                scope.len = saved_len;
                scope.floor = saved_floor;
                scope.use_depth -= 1;
                scope.template_ctx = saved_ctx;
            }
            return self.buildElement(ui, scope, template_node.children[0]);
        }

        /// A template arg's scope payload: a `{binding}` naming an iterable
        /// (in scope or on the model, the same resolution set as
        /// `for each`) binds as a slice; anything else evaluates to a
        /// `Value` at the use site.
        fn argPayload(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, raw: []const u8) BuildError!ScopeEntry.Payload {
            @setEvalBranchQuota(scan_quota);
            const expression = markup.parseAttrExpression(raw) orelse {
                return self.failPayload(node, markup.invalid_expression_message);
            };
            if (expression == .binding) {
                const path = expression.binding;
                if (scope.lookup(pathHead(path))) |entry| {
                    if (entry.payload == .slice and pathTail(path) == null) {
                        // Re-pass a slice arg to a nested use.
                        return entry.payload;
                    }
                } else {
                    inline for (item_types, 0..) |Item, type_index| {
                        // Strings stay scalars: a binding producing
                        // []const u8 (a field, zero-arg fn, or arena fn)
                        // binds as a value arg, never as an iterable of
                        // bytes.
                        if (comptime (Item != u8)) {
                            if (try self.iterateItems(ui, Item, type_index, scope, path)) |items| {
                                return .{ .slice = .{
                                    .type_index = type_index,
                                    .ptr = @ptrCast(items.ptr),
                                    .len = items.len,
                                } };
                            }
                        }
                    }
                }
            }
            return .{ .value = try self.evalAttrExpression(scope, node, raw) };
        }

        fn failPayload(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn itemKey(self: *Self, comptime Item: type, item: *const Item, node: markup.MarkupNode, field: []const u8) BuildError!canvas.UiKey {
            @setEvalBranchQuota(scan_quota);
            // Keys stay identity-stable data: fields and zero-arg methods
            // only, never arena-computed values.
            const value = resolveOn(Item, item, field, null) orelse {
                return self.failKey(node, "key does not name a field on the item");
            };
            return switch (value) {
                .integer => |int| canvas.uiKey(@as(u64, @intCast(int))),
                .string => |text| canvas.uiKey(text),
                else => self.failKey(node, "key fields must be integers or strings"),
            };
        }

        // ---------------------------------------------------- attributes

        fn applyAttrs(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions) BuildError!void {
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.startsWith(u8, attribute.name, "on-")) {
                    try self.applyMessageAttr(scope, node, options, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "role")) {
                    const value = try self.evalAttrExpression(scope, node, attribute.value);
                    const text = switch (value) {
                        .string => |text| text,
                        else => return self.failVoid(node, "role expects a role name"),
                    };
                    options.semantics.role = std.meta.stringToEnum(canvas.WidgetRole, text) orelse {
                        return self.failVoid(node, "unknown role");
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    const value = try self.evalAttrExpression(scope, node, attribute.value);
                    options.semantics.label = switch (value) {
                        .string => |text| text,
                        else => return self.failVoid(node, "label expects text"),
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "image")) {
                    try self.applyImageAttr(scope, node, options, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "name")) {
                    // Consumed by the icon branch in buildElement.
                    if (!std.mem.eql(u8, node.name, "icon")) {
                        return self.failVoid(node, markup.icon_name_element_message);
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "icon")) {
                    try self.applyButtonIconAttr(node, options, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "anchor")) {
                    try self.applyAnchorAttr(node, options, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "anchor-alignment")) {
                    try self.applyAnchorAlignmentAttr(node, options, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "anchor-offset")) {
                    try self.applyAnchorOffsetAttr(node, options, attribute.value);
                    continue;
                }
                if (try self.applyStyleTokenAttr(node, options, attribute)) continue;
                if (!try self.applyOptionAttr(scope, node, options, attribute)) {
                    return self.failVoid(node, "unknown attribute for this element");
                }
            }
        }

        /// Style token references (`background="surface"`, `radius="md"`):
        /// literal token names only, validated against the token FieldEnums
        /// and resolved by the builder's `finalizeWithTokens`.
        fn applyStyleTokenAttr(self: *Self, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!bool {
            inline for (color_style_attr_fields) |entry| {
                if (std.mem.eql(u8, attribute.name, entry.markup)) {
                    const literal = try self.styleTokenLiteral(node, attribute.value);
                    @field(options.style_tokens, entry.zig) = std.meta.stringToEnum(canvas.ColorTokenName, literal) orelse {
                        return self.failVoid(node, markup.unknown_color_token_message);
                    };
                    return true;
                }
            }
            if (std.mem.eql(u8, attribute.name, "radius")) {
                const literal = try self.styleTokenLiteral(node, attribute.value);
                options.style_tokens.radius = std.meta.stringToEnum(canvas.RadiusTokenName, literal) orelse {
                    return self.failVoid(node, markup.unknown_radius_token_message);
                };
                return true;
            }
            return false;
        }

        fn styleTokenLiteral(self: *Self, node: markup.MarkupNode, raw: []const u8) BuildError![]const u8 {
            const expression = markup.parseAttrExpression(raw) orelse {
                return self.failPayload(node, markup.style_token_literal_message);
            };
            if (expression != .literal) return self.failPayload(node, markup.style_token_literal_message);
            return expression.literal;
        }

        /// `image="{binding}"` on avatar: one binding producing a `u64`
        /// `canvas.ImageId` the app registered at runtime
        /// (`fx.registerImageBytes`) — the id is model data, never a
        /// markup literal, and 0 keeps the initials fallback. Scoped to
        /// avatar; the other image-bearing widgets (image, icon,
        /// icon-button) stay Zig views.
        fn applyImageAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, raw: []const u8) BuildError!void {
            if (!std.mem.eql(u8, node.name, "avatar")) {
                return self.failVoid(node, markup.avatar_image_element_message);
            }
            const expression = markup.parseAttrExpression(raw) orelse {
                return self.failVoid(node, markup.avatar_image_message);
            };
            if (expression != .binding) return self.failVoid(node, markup.avatar_image_message);
            const value = try self.evalBinding(scope, node, expression.binding, true);
            options.image = switch (value) {
                .integer => |int| @intCast(int),
                else => return self.failVoid(node, markup.avatar_image_message),
            };
        }

        /// `icon="save"` on button, toggle-button, list-item, or
        /// menu-item: the same closed literal vocabulary as `<icon name>`
        /// (a typo can never rot silently), drawn inside the element so
        /// icon + label are one hit target with one tint. Mirrors the
        /// validator and the compiled engine's compile error.
        fn applyButtonIconAttr(self: *Self, node: markup.MarkupNode, options: *Ui.ElementOptions, raw: []const u8) BuildError!void {
            if (!markup.iconAttrElement(node.name)) {
                return self.failVoid(node, markup.button_icon_element_message);
            }
            const expression = markup.parseAttrExpression(raw) orelse {
                return self.failVoid(node, markup.button_icon_message);
            };
            if (expression != .literal) return self.failVoid(node, markup.button_icon_message);
            if (canvas.icons.find(expression.literal) == null) return self.failVoid(node, markup.button_icon_message);
            options.icon = expression.literal;
        }

        /// `anchor="below|above"` on dropdown-menu: anchored floating
        /// placement — the surface floats against its parent's frame in
        /// the late window-level pass instead of the parent's flow.
        /// Literal placements only, mirroring the validator and the
        /// compiled engine's comptime resolution.
        fn applyAnchorAttr(self: *Self, node: markup.MarkupNode, options: *Ui.ElementOptions, raw: []const u8) BuildError!void {
            if (!markup.anchorElement(node.name)) {
                return self.failVoid(node, markup.anchor_element_message);
            }
            options.anchor = std.meta.stringToEnum(canvas.WidgetAnchorPlacement, raw) orelse {
                return self.failVoid(node, markup.anchor_value_message);
            };
        }

        fn applyAnchorAlignmentAttr(self: *Self, node: markup.MarkupNode, options: *Ui.ElementOptions, raw: []const u8) BuildError!void {
            if (!markup.anchorElement(node.name)) {
                return self.failVoid(node, markup.anchor_element_message);
            }
            if (node.attr("anchor") == null) return self.failVoid(node, markup.anchor_dependent_attr_message);
            options.anchor_alignment = std.meta.stringToEnum(canvas.WidgetAnchorAlignment, raw) orelse {
                return self.failVoid(node, markup.anchor_alignment_value_message);
            };
        }

        fn applyAnchorOffsetAttr(self: *Self, node: markup.MarkupNode, options: *Ui.ElementOptions, raw: []const u8) BuildError!void {
            if (!markup.anchorElement(node.name)) {
                return self.failVoid(node, markup.anchor_element_message);
            }
            if (node.attr("anchor") == null) return self.failVoid(node, markup.anchor_dependent_attr_message);
            options.anchor_offset = std.fmt.parseFloat(f32, raw) catch {
                return self.failVoid(node, markup.anchor_offset_value_message);
            };
        }

        fn applyOptionAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!bool {
            inline for (attr_names) |name| {
                if (std.mem.eql(u8, attribute.name, name.markup)) {
                    try self.setOptionField(scope, node, options, name.zig, attribute.value);
                    return true;
                }
            }
            return false;
        }

        fn setOptionField(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, comptime field: []const u8, raw: []const u8) BuildError!void {
            const FieldType = @TypeOf(@field(options, field));
            const value = try self.evalAttrExpression(scope, node, raw);
            switch (@typeInfo(FieldType)) {
                .float => @field(options, field) = switch (value) {
                    .float => |float| float,
                    .integer => |int| @floatFromInt(int),
                    else => return self.failVoid(node, "expected a number"),
                },
                .bool => @field(options, field) = value.truthy(),
                // Optional bools (`expanded`): the attribute's PRESENCE
                // makes the state non-null; the value sets it.
                .optional => @field(options, field) = value.truthy(),
                .int => @field(options, field) = switch (value) {
                    .integer => |int| if (int < 0)
                        return self.failVoid(node, "expected a non-negative whole number")
                    else
                        @intCast(int),
                    else => return self.failVoid(node, "expected a whole number"),
                },
                .@"enum" => {
                    const text = switch (value) {
                        .string => |text| text,
                        else => return self.failVoid(node, "expected an option name"),
                    };
                    @field(options, field) = std.meta.stringToEnum(FieldType, text) orelse {
                        return self.failVoid(node, "unknown option value");
                    };
                },
                .pointer => @field(options, field) = switch (value) {
                    .string => |text| text,
                    else => return self.failVoid(node, "expected text"),
                },
                else => return self.failVoid(node, "attribute is not settable from markup"),
            }
        }

        fn attrKey(self: *Self, scope: *Scope, node: markup.MarkupNode, raw: []const u8) BuildError!canvas.UiKey {
            const value = try self.evalAttrExpression(scope, node, raw);
            return switch (value) {
                .integer => |int| canvas.uiKey(@as(u64, @intCast(int))),
                .string => |text| canvas.uiKey(text),
                else => self.failKey(node, "keys must be integers or strings"),
            };
        }

        fn applyMessageAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            const expression = markup.parseMessageExpression(attribute.value) orelse {
                return self.failVoid(node, "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")");
            };
            const event = attribute.name[3..];
            if (std.mem.eql(u8, event, "input")) {
                options.on_input = inputConstructor(expression.tag) orelse {
                    return self.failVoid(node, "on-input tag must carry a TextInputEvent payload");
                };
                return;
            }
            if (std.mem.eql(u8, event, "scroll")) {
                if (!std.mem.eql(u8, node.name, "scroll")) {
                    return self.failVoid(node, markup.on_scroll_element_message);
                }
                options.on_scroll = scrollConstructor(expression.tag) orelse {
                    return self.failVoid(node, markup.on_scroll_payload_message);
                };
                return;
            }
            if (std.mem.eql(u8, event, "resize")) {
                if (!std.mem.eql(u8, node.name, "split")) {
                    return self.failVoid(node, markup.on_resize_element_message);
                }
                options.on_resize = resizeConstructor(expression.tag) orelse {
                    return self.failVoid(node, markup.on_resize_payload_message);
                };
                return;
            }
            const msg = try self.constructMessage(scope, node, expression);
            if (std.mem.eql(u8, event, "press")) {
                options.on_press = msg;
            } else if (std.mem.eql(u8, event, "toggle")) {
                options.on_toggle = msg;
            } else if (std.mem.eql(u8, event, "change")) {
                options.on_change = msg;
            } else if (std.mem.eql(u8, event, "submit")) {
                options.on_submit = msg;
            } else if (std.mem.eql(u8, event, "dismiss")) {
                // Only dismissible surfaces are ever dismissed by the
                // runtime; anywhere else the Msg could never fire.
                if (!markup.dismissEventElement(node.name)) {
                    return self.failVoid(node, markup.on_dismiss_element_message);
                }
                options.on_dismiss = msg;
            } else if (std.mem.eql(u8, event, "hold")) {
                // Press family: like on-press, a bound hold makes any
                // element pressable.
                options.on_hold = msg;
            } else if (std.mem.eql(u8, event, "reach-end")) {
                // The approach-end signal (infinite-scroll fetch) is
                // emitted for scroll containers only.
                if (!std.mem.eql(u8, node.name, "scroll")) {
                    return self.failVoid(node, markup.on_reach_end_element_message);
                }
                options.on_reach_end = msg;
            } else {
                return self.failVoid(node, "unknown event attribute");
            }
        }

        fn constructMessage(self: *Self, scope: *Scope, node: markup.MarkupNode, expression: markup.MessageExpression) BuildError!MsgT {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (std.mem.eql(u8, field.name, expression.tag)) {
                    if (field.type == void) {
                        if (expression.payload.len > 0) {
                            return self.failMsg(node, "message does not take a payload");
                        }
                        return @unionInit(MsgT, field.name, {});
                    }
                    if (expression.payload.len == 0) {
                        return self.failMsg(node, "message requires a payload");
                    }
                    const value = try self.evalBinding(scope, node, expression.payload, true);
                    return @unionInit(MsgT, field.name, try self.coerce(field.type, node, value));
                }
            }
            return self.failMsg(node, "unknown message tag");
        }

        fn coerce(self: *Self, comptime T: type, node: markup.MarkupNode, value: Value) BuildError!T {
            return switch (@typeInfo(T)) {
                .int => switch (value) {
                    .integer => |int| @intCast(int),
                    else => self.failCoerce(T, node),
                },
                .float => switch (value) {
                    .float => |float| @floatCast(float),
                    .integer => |int| @floatFromInt(int),
                    else => self.failCoerce(T, node),
                },
                .@"enum" => switch (value) {
                    .string => |text| std.meta.stringToEnum(T, text) orelse self.failCoerce(T, node),
                    else => self.failCoerce(T, node),
                },
                .pointer => switch (value) {
                    .string => |text| text,
                    else => self.failCoerce(T, node),
                },
                .bool => value.truthy(),
                else => self.failCoerce(T, node),
            };
        }

        fn failCoerce(self: *Self, comptime T: type, node: markup.MarkupNode) BuildError {
            _ = T;
            return self.failVoid(node, "payload type does not match the message");
        }

        fn inputConstructor(tag: []const u8) ?Ui.InputMsgFn {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (field.type == canvas.TextInputEvent) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.inputMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
            }
            return null;
        }

        fn scrollConstructor(tag: []const u8) ?Ui.ScrollMsgFn {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (field.type == canvas.ScrollState) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.scrollMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
            }
            return null;
        }

        fn resizeConstructor(tag: []const u8) ?Ui.ValueMsgFn {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (field.type == f32) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.valueMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
            }
            return null;
        }

        // --------------------------------------------------- expressions

        fn evalAttrExpression(self: *Self, scope: *Scope, node: markup.MarkupNode, raw: []const u8) BuildError!Value {
            const expression = markup.parseAttrExpression(raw) orelse {
                return self.failValue(node, markup.invalid_expression_message);
            };
            return switch (expression) {
                .literal => |text| literalValue(text),
                .binding => |path| try self.evalBinding(scope, node, path, true),
                // Arena-computed bindings are excluded from equality on
                // purpose: comparing freshly formatted strings is a smell —
                // compare the source fields, or bind a bool-returning fn.
                .equals => |sides| .{ .boolean = Value.eql(
                    try self.evalBinding(scope, node, sides.left, false),
                    try self.evalBinding(scope, node, sides.right, false),
                ) },
                .expression => |inner| try self.evalExpressionTree(scope, node, inner),
            };
        }

        /// Evaluate a full `{expression}`: parse it (bounded, allocation-
        /// free), resolve every binding node through the ordinary scope
        /// chain, and hand the values to the shared evaluator — the same
        /// code the compiled engine runs, so results match bit for bit.
        /// Parse, type, and value failures (division by zero, overflow)
        /// become build diagnostics carrying the evaluator's teaching
        /// message.
        fn evalExpressionTree(self: *Self, scope: *Scope, node: markup.MarkupNode, inner: []const u8) BuildError!Value {
            var tree: markup.expr.ExprTree = .{};
            var diagnostic: markup.expr.Diagnostic = .{};
            if (!markup.expr.parse(inner, &tree, &diagnostic)) {
                return self.failValue(node, diagnostic.message);
            }
            var values: [markup.expr.max_expression_nodes]Value = undefined;
            for (tree.nodes[0..tree.len], 0..) |expr_node, index| {
                if (expr_node.kind != .binding) continue;
                // Comparison operands reject arena-computed scalars, the
                // same teaching rule as `{a == b}`.
                values[index] = try self.evalBinding(scope, node, expr_node.text, !expr_node.comparison_operand);
            }
            return switch (try markup.expr.eval(&tree, &values, scope.arena)) {
                .value => |value| value,
                .fail => |message| self.failValue(node, message),
            };
        }

        /// Resolve a binding path to a `Value`. `allow_arena` gates the
        /// arena-taking scalar fn form (allowed everywhere a scalar binding
        /// is — text interpolation, attribute values, message payloads —
        /// except inside `{a == b}` equality).
        fn evalBinding(self: *Self, scope: *Scope, node: markup.MarkupNode, path: []const u8, allow_arena: bool) BuildError!Value {
            @setEvalBranchQuota(scan_quota);
            const head = pathHead(path);
            const arena: ?std.mem.Allocator = if (allow_arena) scope.arena else null;
            if (scope.lookup(head)) |entry| {
                switch (entry.payload) {
                    .item => |item_entry| {
                        inline for (item_types, 0..) |Item, type_index| {
                            if (item_entry.type_index == type_index) {
                                const item: *const Item = @ptrCast(@alignCast(item_entry.ptr));
                                if (pathTail(path)) |tail| {
                                    if (resolveOn(Item, item, tail, arena)) |value| return value;
                                    if (!allow_arena and resolveOn(Item, item, tail, scope.arena) != null) {
                                        return self.failValue(node, markup.arena_scalar_equality_message);
                                    }
                                    return self.failValue(node, "binding does not name a field on the loop item");
                                }
                                return valueOf(Item, item.*) orelse self.failValue(node, "loop items of this type cannot be used as values");
                            }
                        }
                        unreachable;
                    },
                    .value => |value| {
                        if (pathTail(path) != null) {
                            return self.failValue(node, "template arg values have no fields");
                        }
                        return value;
                    },
                    .slice => return self.failValue(node, "slice-valued template args are only usable with for each"),
                    // Slot captures carry an empty name, which no binding
                    // head can equal.
                    .slot => unreachable,
                }
            }
            if (resolveOn(ModelT, scope.model, path, arena)) |value| return value;
            if (!allow_arena and resolveOn(ModelT, scope.model, path, scope.arena) != null) {
                return self.failValue(node, markup.arena_scalar_equality_message);
            }
            return self.failValue(node, "binding does not name a model field");
        }

        fn interpolatedText(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError![]const u8 {
            if (node.children.len > 1) return self.failText(node, "text elements take a single run of text");
            var source: []const u8 = "";
            for (node.children) |child| {
                if (child.kind != .text) return self.failText(node, "text elements may only contain text");
                source = child.text;
            }
            if (std.mem.indexOfScalar(u8, source, '{') == null) return source;

            var out: std.ArrayListUnmanaged(u8) = .empty;
            var rest = source;
            while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
                try out.appendSlice(ui.arena, rest[0..open]);
                const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse {
                    return self.failText(node, "unterminated interpolation");
                };
                const inner = std.mem.trim(u8, rest[open + 1 .. close], " ");
                const value = if (markup.isBindingPath(inner))
                    try self.evalBinding(scope, node, inner, true)
                else
                    try self.evalExpressionTree(scope, node, inner);
                try appendValue(&out, ui.arena, value);
                rest = rest[close + 1 ..];
            }
            try out.appendSlice(ui.arena, rest);
            return out.items;
        }

        // -------------------------------------------------- diagnostics

        fn failNode(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError!Ui.Node {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn failVoid(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn failValue(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn failText(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn failMsg(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn failKey(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn setDiagnostic(self: *Self, node: markup.MarkupNode, message: []const u8) void {
            self.diagnostic = .{ .line = node.line, .column = node.column, .message = message, .path = node.src_path };
        }
    };
}

// ----------------------------------------------------------- reflection

/// Markup attribute name → `Ui.ElementOptions` field. Shared with the
/// comptime-compiled path so both engines accept exactly the same
/// attributes.
pub const AttrName = struct { markup: []const u8, zig: []const u8 };

pub const attr_names: []const AttrName = &.{
    .{ .markup = "text", .zig = "text" },
    .{ .markup = "placeholder", .zig = "placeholder" },
    .{ .markup = "value", .zig = "value" },
    .{ .markup = "checked", .zig = "checked" },
    .{ .markup = "selected", .zig = "selected" },
    .{ .markup = "autofocus", .zig = "autofocus" },
    .{ .markup = "disabled", .zig = "disabled" },
    .{ .markup = "variant", .zig = "variant" },
    .{ .markup = "size", .zig = "size" },
    .{ .markup = "width", .zig = "width" },
    .{ .markup = "height", .zig = "height" },
    .{ .markup = "min-width", .zig = "min_width" },
    .{ .markup = "expanded", .zig = "expanded" },
    .{ .markup = "grow", .zig = "grow" },
    .{ .markup = "gap", .zig = "gap" },
    .{ .markup = "padding", .zig = "padding" },
    .{ .markup = "main", .zig = "main" },
    .{ .markup = "cross", .zig = "cross" },
    .{ .markup = "wrap", .zig = "wrap" },
    .{ .markup = "text-alignment", .zig = "text_alignment" },
    .{ .markup = "columns", .zig = "columns" },
    .{ .markup = "virtualized", .zig = "virtualized" },
    .{ .markup = "virtual-item-extent", .zig = "virtual_item_extent" },
    .{ .markup = "window-drag", .zig = "window_drag" },
};

/// Markup color style attribute → `StyleTokenRefs` field. Shared with the
/// comptime-compiled path; kept consistent with
/// `ui_markup.known_color_style_attrs` by a test.
pub const color_style_attr_fields: []const AttrName = &.{
    .{ .markup = "background", .zig = "background" },
    .{ .markup = "foreground", .zig = "foreground" },
    .{ .markup = "accent", .zig = "accent" },
    .{ .markup = "accent-foreground", .zig = "accent_foreground" },
    .{ .markup = "border-color", .zig = "border_color" },
    .{ .markup = "focus-ring", .zig = "focus_ring" },
};

/// Comptime walks over an app's Model and Msg scale with the type's
/// field/decl count, and the default 1000-backwards-branch quota dies at
/// real app sizes (ovation: ~200 pub decls) — inside framework code the
/// app never asked to run, before it uses any markup. Every Model/Msg
/// shaped comptime walk in both markup engines derives its quota from the
/// scanned type instead of relying on the default: generous linear
/// headroom per field/decl (name compares, fn-signature checks,
/// `sliceElement` recursion) plus the item-type dedupe's worst-case
/// quadratic accumulation. Apps never raise the quota for framework
/// scans; `ui_markup_huge_model_tests.zig` is the compile-cost guard.
pub fn typeScanQuota(comptime T: type) u32 {
    const entries: u32 = switch (@typeInfo(T)) {
        .@"struct" => |info| @intCast(info.fields.len + info.decls.len),
        .@"union" => |info| @intCast(info.fields.len + info.decls.len),
        .@"enum" => |info| @intCast(info.fields.len + info.decls.len),
        else => 0,
    };
    return 2000 + entries * 64 + entries * entries;
}

fn collectItemTypes(comptime Model: type) []const type {
    comptime {
        @setEvalBranchQuota(typeScanQuota(Model));
        var types: []const type = &.{};
        for (@typeInfo(Model).@"struct".fields) |field| {
            if (sliceElement(field.type)) |Element| {
                types = appendUniqueType(types, Element);
            }
        }
        for (@typeInfo(Model).@"struct".decls) |decl| {
            const DeclType = @TypeOf(@field(Model, decl.name));
            if (sliceElement(DeclType)) |Element| {
                types = appendUniqueType(types, Element);
            }
            switch (@typeInfo(DeclType)) {
                .@"fn" => |info| {
                    if (info.return_type) |Return| {
                        if (sliceElement(Return)) |Element| {
                            types = appendUniqueType(types, Element);
                        }
                    }
                },
                else => {},
            }
        }
        return types;
    }
}

fn appendUniqueType(comptime types: []const type, comptime T: type) []const type {
    for (types) |existing| {
        if (existing == T) return types;
    }
    return types ++ &[_]type{T};
}

pub fn sliceElement(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .array => |info| info.child,
        .pointer => |info| if (info.size == .slice) info.child else if (info.size == .one) sliceElement(info.child) else null,
        else => null,
    };
}

pub fn isItemFn(comptime DeclType: type, comptime Item: type, comptime with_arena: bool) bool {
    const info = switch (@typeInfo(DeclType)) {
        .@"fn" => |fn_info| fn_info,
        else => return false,
    };
    if (info.params.len == 0 or info.params[0].type == null) return false;
    switch (@typeInfo(info.params[0].type.?)) {
        .pointer => {},
        else => return false,
    }
    const expected_params: usize = if (with_arena) 2 else 1;
    if (info.params.len != expected_params) return false;
    const Return = info.return_type orelse return false;
    if (sliceElement(Return) != Item) return false;
    if (with_arena and info.params[1].type != std.mem.Allocator) return false;
    return true;
}

pub fn asSlice(comptime Item: type, value: anytype) []const Item {
    const T = @TypeOf(value.*);
    return switch (@typeInfo(T)) {
        .array => value[0..],
        .pointer => value.*,
        else => @compileError("not a slice"),
    };
}

/// Resolve a dotted path on a value: struct fields, zero-arg methods,
/// arena-taking methods (`fn (*const T, std.mem.Allocator) V`, skipped
/// when `arena` is null), and bounded model conventions (a
/// `field_count`-style pair is the author's job; the resolver only follows
/// what exists).
fn resolveOn(comptime T: type, value: *const T, path: []const u8, arena: ?std.mem.Allocator) ?Value {
    @setEvalBranchQuota(comptime typeScanQuota(T));
    const head = pathHead(path);
    const tail = pathTail(path);
    switch (@typeInfo(T)) {
        .@"struct" => {
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, head)) {
                    if (tail) |rest| {
                        return resolveNested(field.type, &@field(value, field.name), rest, arena);
                    }
                    return valueOf(field.type, @field(value, field.name));
                }
            }
            inline for (@typeInfo(T).@"struct".decls) |decl| {
                const DeclType = @TypeOf(@field(T, decl.name));
                switch (@typeInfo(DeclType)) {
                    .@"fn" => |info| {
                        if (info.params.len == 1 and info.return_type != null and info.params[0].type == *const T) {
                            if (std.mem.eql(u8, decl.name, head) and tail == null) {
                                return valueOf(info.return_type.?, @field(T, decl.name)(value));
                            }
                        }
                        if (comptime isArenaScalarFn(T, DeclType)) {
                            if (std.mem.eql(u8, decl.name, head) and tail == null) {
                                const allocator = arena orelse return null;
                                return valueOf(info.return_type.?, @field(T, decl.name)(value, allocator));
                            }
                        }
                    },
                    else => {},
                }
            }
            return null;
        },
        else => return null,
    }
}

/// An arena-taking scalar binding fn: `fn (self: *const T,
/// arena: std.mem.Allocator) V`. The `for each` arena form returns a slice
/// of items; this form returns one value (typically a formatted
/// `[]const u8` allocated from the arena).
pub fn isArenaScalarFn(comptime T: type, comptime DeclType: type) bool {
    const info = switch (@typeInfo(DeclType)) {
        .@"fn" => |fn_info| fn_info,
        else => return false,
    };
    if (info.params.len != 2 or info.return_type == null) return false;
    if (info.params[0].type != *const T) return false;
    return info.params[1].type == std.mem.Allocator;
}

fn resolveNested(comptime T: type, ptr: anytype, path: []const u8, arena: ?std.mem.Allocator) ?Value {
    return switch (@typeInfo(T)) {
        .@"struct" => resolveOn(T, ptr, path, arena),
        else => null,
    };
}

pub fn valueOf(comptime T: type, value: T) ?Value {
    return switch (@typeInfo(T)) {
        .bool => .{ .boolean = value },
        .int => .{ .integer = @intCast(value) },
        .float => .{ .float = @floatCast(value) },
        .@"enum" => .{ .string = @tagName(value) },
        .comptime_int => .{ .integer = value },
        .pointer => |info| if (info.size == .slice and info.child == u8) .{ .string = value } else null,
        .array => |info| if (info.child == u8) null else null,
        .optional => if (value) |inner| valueOf(@TypeOf(inner), inner) else .{ .boolean = false },
        else => null,
    };
}

pub fn literalValue(text: []const u8) Value {
    if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
    if (std.fmt.parseInt(i64, text, 10)) |int| return .{ .integer = int } else |_| {}
    if (std.fmt.parseFloat(f32, text)) |float| return .{ .float = float } else |_| {}
    return .{ .string = text };
}

/// Display-text formatting for interpolation and `++` concatenation:
/// defined once in the expression core so both engines (and the evaluator
/// itself) format identically, floats included.
pub const appendValue = markup.expr.appendValue;

pub fn pathHead(path: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return path;
    return path[0..dot];
}

pub fn pathTail(path: []const u8) ?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return null;
    return path[dot + 1 ..];
}

// -------------------------------------------------------------- elements

pub fn elementKind(name: []const u8) ?canvas.WidgetKind {
    const map = .{
        .{ "row", canvas.WidgetKind.row },
        .{ "column", canvas.WidgetKind.column },
        .{ "stack", canvas.WidgetKind.stack },
        .{ "panel", canvas.WidgetKind.panel },
        .{ "scroll", canvas.WidgetKind.scroll_view },
        .{ "list", canvas.WidgetKind.list },
        .{ "grid", canvas.WidgetKind.grid },
        .{ "split", canvas.WidgetKind.split },
        .{ "tree", canvas.WidgetKind.tree },
        .{ "card", canvas.WidgetKind.card },
        .{ "text", canvas.WidgetKind.text },
        .{ "button", canvas.WidgetKind.button },
        .{ "checkbox", canvas.WidgetKind.checkbox },
        .{ "radio", canvas.WidgetKind.radio },
        .{ "toggle", canvas.WidgetKind.toggle },
        .{ "slider", canvas.WidgetKind.slider },
        .{ "progress", canvas.WidgetKind.progress },
        .{ "text-field", canvas.WidgetKind.text_field },
        .{ "search-field", canvas.WidgetKind.search_field },
        .{ "textarea", canvas.WidgetKind.textarea },
        .{ "list-item", canvas.WidgetKind.list_item },
        .{ "menu-item", canvas.WidgetKind.menu_item },
        .{ "status-bar", canvas.WidgetKind.status_bar },
        .{ "separator", canvas.WidgetKind.separator },
        .{ "badge", canvas.WidgetKind.badge },
        .{ "spacer", canvas.WidgetKind.stack },
        // Row containers.
        .{ "breadcrumb", canvas.WidgetKind.breadcrumb },
        .{ "button-group", canvas.WidgetKind.button_group },
        .{ "pagination", canvas.WidgetKind.pagination },
        .{ "radio-group", canvas.WidgetKind.radio_group },
        .{ "tabs", canvas.WidgetKind.tabs },
        .{ "toggle-group", canvas.WidgetKind.toggle_group },
        // Vertical containers.
        .{ "table", canvas.WidgetKind.table },
        .{ "table-row", canvas.WidgetKind.data_row },
        .{ "dropdown-menu", canvas.WidgetKind.dropdown_menu },
        // Overlay/surface containers (title via the text attribute).
        .{ "accordion", canvas.WidgetKind.accordion },
        .{ "alert", canvas.WidgetKind.alert },
        .{ "bubble", canvas.WidgetKind.bubble },
        .{ "dialog", canvas.WidgetKind.dialog },
        .{ "drawer", canvas.WidgetKind.drawer },
        .{ "sheet", canvas.WidgetKind.sheet },
        .{ "resizable", canvas.WidgetKind.resizable },
        // Text-bearing leaves.
        .{ "avatar", canvas.WidgetKind.avatar },
        .{ "select", canvas.WidgetKind.select },
        .{ "switch", canvas.WidgetKind.switch_control },
        .{ "table-cell", canvas.WidgetKind.data_cell },
        .{ "toggle-button", canvas.WidgetKind.toggle_button },
        .{ "tooltip", canvas.WidgetKind.tooltip },
        // Text entry leaves.
        .{ "input", canvas.WidgetKind.input },
        .{ "combobox", canvas.WidgetKind.combobox },
        // Plain leaves.
        .{ "skeleton", canvas.WidgetKind.skeleton },
        .{ "spinner", canvas.WidgetKind.spinner },
        .{ "icon", canvas.WidgetKind.icon },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// Tab triggers ARE segmented controls: markup composes the strip from
/// `<button>` children (segmented-control is a documented markup
/// exclusion), and both engines lower them to the widget kind the
/// engine's tab strips are built on, so the active trigger lifts to the
/// surface with a hairline exactly like the Zig builder's tabs.
/// Handlers ride the widget id, so bindings are untouched; toggle-button
/// children keep their kind (their on-toggle contract is different).
pub fn lowerTabsTriggers(children: anytype) void {
    for (children) |*child| {
        if (child.widget.kind == .button) child.widget.kind = .segmented_control;
    }
}

pub fn elementTakesText(kind: canvas.WidgetKind) bool {
    return switch (kind) {
        .text, .button, .list_item, .menu_item, .status_bar, .badge, .toggle => true,
        .avatar, .select, .switch_control, .data_cell, .toggle_button, .tooltip => true,
        else => false,
    };
}
