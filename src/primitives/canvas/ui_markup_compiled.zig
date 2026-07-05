//! Comptime-compiled markup views: parse a `.zml` source entirely at
//! comptime and emit a `build(ui, model)` whose output is identical to the
//! interpreter's (ui_markup_view.zig) for the same model — same structural
//! widget ids node for node, same handler table, same dispatch results —
//! with no parser or interpreter in the binary.
//!
//! The runtime interpreter stays the dev/hot-reload engine; this is the
//! release engine. Both share one grammar: the parser's token-level
//! helpers, the expression parsers (`parseAttrExpression`,
//! `parseMessageExpression`), the element/attribute tables, and the value
//! conversion code (`Value`, `valueOf`, `literalValue`, `appendValue`) are
//! the interpreter's own, so the engines cannot drift.
//!
//! Errors: everything the interpreter reports as a runtime `MarkupBuild`
//! failure whose cause is knowable from the source and the Model/Msg types
//! — unknown elements/attributes, malformed expressions, bindings that
//! don't name model fields, unknown message tags, payload type mismatches —
//! becomes a compile error carrying the node's line/column and the
//! interpreter's message. That is also the compile-error test strategy:
//! invalid constructs are structurally unreachable at runtime because the
//! comptime walk `@compileError`s on them while resolving the tree (Zig
//! cannot unit-test `@compileError`, so ui_markup_compiled_tests.zig covers
//! the accepting side exhaustively and the interpreter's failure tests
//! enumerate the constructs this path rejects at compile time). The only
//! failures left for runtime are value-dependent ones the interpreter also
//! discovers at runtime (an optional binding or non-tag string feeding an
//! enum), which latch `ui.failed` exactly like the builder's own sugar.

const std = @import("std");
const canvas = @import("root.zig");
const markup = @import("ui_markup.zig");
const interpreter = @import("ui_markup_view.zig");

const Value = interpreter.Value;

/// A markup view compiled against a concrete Model/Msg pair. `source` is
/// parsed at comptime (no parser in the binary) and `build` unrolls binding
/// and message resolution to direct field/method access — what an
/// equivalent hand-written `view(ui, model)` compiles to.
pub fn CompiledMarkupView(comptime ModelT: type, comptime MsgT: type, comptime source: []const u8) type {
    return struct {
        pub const Ui = canvas.Ui(MsgT);

        pub const document = markup.parseComptime(source);

        /// Loop variables and template args in scope at a point in the
        /// tree. Names, kinds, and item types are comptime; the runtime
        /// value is a nested struct with one payload per entry: a
        /// `*const Item` for `for` items, a `Value` for scalar template
        /// args, and a `[]const Item` for slice-valued template args.
        const ScopeEntry = struct {
            name: []const u8,
            kind: Kind,
            Item: type = void,
            /// For value args: the comptime-known Value variant of the
            /// use-site expression (null when only runtime-known, e.g. a
            /// binding through an optional).
            variant: ?ValueVariant = null,

            const Kind = enum { item, value_arg, slice_arg };
        };

        fn EntryPayload(comptime entry: ScopeEntry) type {
            return switch (entry.kind) {
                .item => *const entry.Item,
                .value_arg => Value,
                .slice_arg => []const entry.Item,
            };
        }

        // Runtime scopes are anonymous `{ parent, item }` chains passed as
        // `anytype`: one link per entry, innermost last, so a link's type
        // never depends on comptime slice identity (a child list created
        // with `entries ++ ...` re-slices a fresh array, which would not
        // unify with the parent's `entries` under generic instantiation).

        const no_entries: []const ScopeEntry = &.{};

        /// Build the view for the current model. Signature-compatible with
        /// a hand-written view, so it slots into `UiApp.Options.view`
        /// directly. Markup mistakes are compile errors; the only runtime
        /// failures latch `ui.failed` (surfaced by `finalize`) exactly like
        /// the builder's own sugar (`ui.fmt`, `ui.each`).
        pub fn build(ui: *Ui, model: *const ModelT) Ui.Node {
            comptime {
                checkTemplates();
                switch (document.root.kind) {
                    .element, .use_block => {},
                    .template_block => fail(document.root, markup.template_top_level_message),
                    .text => fail(document.root, "text content is only allowed inside text-bearing elements"),
                    .for_block, .if_block, .else_block => fail(document.root, "structure tags are only allowed inside an element"),
                }
            }
            if (comptime (document.root.kind == .use_block)) {
                return buildUse(document.root, no_entries, ui, model, .{});
            }
            return buildElement(document.root, no_entries, ui, model, .{});
        }

        /// Comptime template wiring checks, mirroring the validator: a
        /// name, exactly one element child, and uses inside template
        /// bodies referencing only earlier templates — which also
        /// guarantees comptime expansion terminates.
        fn checkTemplates() void {
            comptime {
                @setEvalBranchQuota(10_000);
                for (document.templates, 0..) |template_node, index| {
                    const name = template_node.attr("name") orelse fail(template_node, markup.template_name_message);
                    for (document.templates[0..index]) |earlier| {
                        const earlier_name = earlier.attr("name") orelse continue;
                        if (std.mem.eql(u8, earlier_name, name)) fail(template_node, markup.template_unique_name_message);
                    }
                    if (template_node.children.len != 1 or template_node.children[0].kind != .element) {
                        fail(template_node, markup.template_one_child_message);
                    }
                    checkUseOrder(template_node.children[0], index);
                }
            }
        }

        fn checkUseOrder(comptime node: markup.MarkupNode, comptime limit: usize) void {
            comptime {
                if (node.kind == .use_block) {
                    const name = node.attr("template") orelse fail(node, markup.use_template_attr_message);
                    const index = document.templateIndex(name) orelse fail(node, markup.use_undefined_template_message);
                    if (index >= limit) fail(node, markup.use_earlier_template_message);
                }
                for (node.children) |child| checkUseOrder(child, limit);
            }
        }

        // ------------------------------------------------------ building

        fn buildElement(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            if (comptime std.mem.eql(u8, node.name, "markdown")) {
                return buildMarkdown(node, entries, ui, model, scope);
            }
            if (comptime std.mem.eql(u8, node.name, "stepper")) {
                return buildStepper(node, entries, ui, model, scope);
            }
            if (comptime std.mem.eql(u8, node.name, "step")) {
                // Steps inside a stepper are consumed by buildStepper.
                comptime fail(node, markup.step_parent_message);
            }
            if (comptime std.mem.eql(u8, node.name, "timeline")) {
                return buildTimeline(node, entries, ui, model, scope);
            }
            if (comptime std.mem.eql(u8, node.name, "timeline-item")) {
                return buildTimelineItem(node, entries, ui, model, scope);
            }
            const kind = comptime (interpreter.elementKind(node.name) orelse fail(node, "unknown element"));
            comptime {
                // Interpreter parity: value/text handlers on
                // non-hit-target kinds can never fire, so a dead handler
                // is a compile error here. on-press/on-toggle are exempt
                // — a bound press handler makes any element a hit target
                // and presses fall through to it.
                if (!canvas.widgetKindHitTarget(kind)) {
                    for (node.attrs) |attribute| {
                        if (std.mem.startsWith(u8, attribute.name, "on-") and markup.deadHandlerOnNonHitTarget(attribute.name)) {
                            fail(node, markup.non_hit_target_handler_message);
                        }
                        // Autofocus can never land here: nothing about
                        // this element is focusable.
                        if (std.mem.eql(u8, attribute.name, "autofocus")) {
                            fail(node, markup.autofocus_element_message);
                        }
                    }
                }
                // Interpreter parity: stacking kinds give every child the
                // full content box, so a gap can never space them — dead
                // layout data is a compile error here.
                if (canvas.widgetKindStacksChildren(kind)) {
                    for (node.attrs) |attribute| {
                        if (std.mem.eql(u8, attribute.name, "gap")) {
                            fail(node, markup.stack_container_gap_message);
                        }
                    }
                }
                // Interpreter parity: only plain text leaves word-wrap;
                // anywhere else the option is silently inert dead layout
                // data — a compile error here.
                if (kind != .text) {
                    for (node.attrs) |attribute| {
                        if (std.mem.eql(u8, attribute.name, "wrap")) {
                            fail(node, markup.wrap_element_message);
                        }
                    }
                }
                // Interpreter parity: splits take exactly two static
                // pane children (the divider sits between fixed panes).
                if (kind == .split) {
                    var pane_count: usize = 0;
                    for (node.children) |child| {
                        switch (child.kind) {
                            .element, .use_block => pane_count += 1,
                            else => fail(child, markup.split_children_message),
                        }
                    }
                    if (pane_count != 2) fail(node, markup.split_children_message);
                }
            }
            var options: Ui.ElementOptions = .{};
            applyAttrs(node, entries, ui, model, scope, &options);

            if (comptime (kind == .icon)) {
                // Closed vocabulary, resolved at comptime: a typo in an
                // icon name is a compile error, and icons take no
                // children.
                const icon_name = comptime blk: {
                    const raw = node.attr("name") orelse fail(node, markup.icon_missing_name_message);
                    const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.icon_name_message);
                    if (expression != .literal) fail(node, markup.icon_name_message);
                    if (canvas.icons.find(expression.literal) == null) fail(node, markup.icon_name_message);
                    if (node.children.len > 0) fail(node, markup.icon_children_message);
                    break :blk expression.literal;
                };
                var built = ui.el(kind, options, .{});
                built.widget.text = icon_name;
                return built;
            }

            if (comptime interpreter.elementTakesText(kind)) {
                var built = ui.el(kind, options, .{});
                built.widget.text = interpolatedText(node, entries, ui, model, scope);
                // Avatars clip their runtime image to the avatar circle,
                // exactly like `Ui.avatar` and the interpreter (a no-op
                // while the id is 0 and the initials fallback renders).
                if (comptime (kind == .avatar)) built.widget.image_fit = .cover;
                return built;
            }

            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            buildChildren(node, entries, ui, model, scope, &children);
            // Interpreter parity: tab triggers ARE segmented controls -
            // `<button>` children of a `<tabs>` strip lower to the
            // widget kind tab strips are built on (see
            // `interpreter.lowerTabsTriggers`).
            if (comptime (kind == .tabs)) interpreter.lowerTabsTriggers(children.items);
            return ui.el(kind, options, @as([]const Ui.Node, children.items));
        }

        /// One runtime step per child: elements and `use` expansions append
        /// a node, `for` blocks append per item (with an adjacent `else`
        /// paired at comptime for the empty case), and an `if` (with its
        /// adjacent `else` paired at comptime) branches on the test binding.
        const ChildStep = union(enum) {
            element: markup.MarkupNode,
            use: markup.MarkupNode,
            for_block: struct { node: markup.MarkupNode, else_block: ?markup.MarkupNode },
            conditional: struct { if_block: markup.MarkupNode, else_block: ?markup.MarkupNode },
        };

        fn childSteps(comptime node: markup.MarkupNode) []const ChildStep {
            comptime {
                @setEvalBranchQuota(10_000);
                var steps: []const ChildStep = &.{};
                var index: usize = 0;
                while (index < node.children.len) : (index += 1) {
                    const child = node.children[index];
                    switch (child.kind) {
                        .element => steps = steps ++ &[_]ChildStep{.{ .element = child }},
                        .use_block => steps = steps ++ &[_]ChildStep{.{ .use = child }},
                        .template_block => fail(child, markup.template_top_level_message),
                        .for_block => {
                            var else_block: ?markup.MarkupNode = null;
                            if (index + 1 < node.children.len and node.children[index + 1].kind == .else_block) {
                                else_block = node.children[index + 1];
                                index += 1;
                            }
                            steps = steps ++ &[_]ChildStep{.{ .for_block = .{ .node = child, .else_block = else_block } }};
                        },
                        .if_block => {
                            var else_block: ?markup.MarkupNode = null;
                            if (index + 1 < node.children.len and node.children[index + 1].kind == .else_block) {
                                else_block = node.children[index + 1];
                                index += 1;
                            }
                            steps = steps ++ &[_]ChildStep{.{ .conditional = .{ .if_block = child, .else_block = else_block } }};
                        },
                        .else_block => fail(child, markup.else_placement_message),
                        .text => fail(child, "text content is only allowed inside text-bearing elements"),
                    }
                }
                return steps;
            }
        }

        fn buildChildren(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, out: *std.ArrayListUnmanaged(Ui.Node)) void {
            const steps = comptime childSteps(node);
            inline for (0..steps.len) |index| {
                const step = comptime steps[index];
                if (comptime (step == .element)) {
                    const built = buildElement(comptime step.element, entries, ui, model, scope);
                    out.append(ui.arena, built) catch {
                        ui.failed = true;
                        return;
                    };
                } else if (comptime (step == .use)) {
                    const built = buildUse(comptime step.use, entries, ui, model, scope);
                    out.append(ui.arena, built) catch {
                        ui.failed = true;
                        return;
                    };
                } else if (comptime (step == .for_block)) {
                    const item_count = buildFor(comptime step.for_block.node, entries, ui, model, scope, out);
                    if (comptime (step.for_block.else_block != null)) {
                        if (item_count == 0) {
                            buildChildren(comptime step.for_block.else_block.?, entries, ui, model, scope, out);
                        }
                    }
                } else {
                    const conditional = comptime step.conditional;
                    const test_value = comptime (conditional.if_block.attr("test") orelse fail(conditional.if_block, "if requires a test attribute"));
                    const condition = evalExpr(conditional.if_block, entries, test_value, ui, model, scope);
                    if (condition.truthy()) {
                        buildChildren(conditional.if_block, entries, ui, model, scope, out);
                    } else if (comptime (conditional.else_block != null)) {
                        buildChildren(comptime conditional.else_block.?, entries, ui, model, scope, out);
                    }
                }
            }
        }

        /// Expands a `for` block; returns the item count so the caller can
        /// render a trailing `<else>` for the empty case.
        fn buildFor(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, out: *std.ArrayListUnmanaged(Ui.Node)) usize {
            const each = comptime (node.attr("each") orelse fail(node, "for requires an each attribute"));
            comptime {
                _ = node.attr("as") orelse fail(node, "for requires an as attribute");
                if (node.children.len == 0) fail(node, markup.for_children_message);
                for (node.children) |child| {
                    switch (child.kind) {
                        .element, .use_block, .for_block, .if_block, .else_block => {},
                        else => fail(child, markup.for_children_message),
                    }
                }
            }
            // Comptime mirror of the interpreter's `each` resolution:
            // slice-valued template args in scope shadow model iterables.
            const scope_index_opt = comptime scopeIndex(entries, each);
            if (comptime (scope_index_opt != null)) {
                const scope_index = comptime scope_index_opt.?;
                comptime {
                    if (entries[scope_index].kind != .slice_arg) {
                        fail(node, "each does not name an iterable (a model slice, array, or fn - or a slice-valued template arg)");
                    }
                }
                const items = scopePayload(entries, scope_index, scope);
                buildForItems(comptime entries[scope_index].Item, node, entries, items, ui, model, scope, out);
                return items.len;
            }
            const info = comptime (eachInfo(each) orelse fail(node, "each does not name an iterable (a model slice, array, or fn - or a slice-valued template arg)"));
            const items = eachItems(info, ui, model);
            buildForItems(info.Item, node, entries, items, ui, model, scope, out);
            return items.len;
        }

        fn buildForItems(comptime ItemT: type, comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, items: []const ItemT, ui: *Ui, model: *const ModelT, scope: anytype, out: *std.ArrayListUnmanaged(Ui.Node)) void {
            const as_name = comptime node.attr("as").?;
            const child_entries = comptime (entries ++ &[_]ScopeEntry{.{ .name = as_name, .kind = .item, .Item = ItemT }});
            for (items) |*item| {
                const child_scope = .{ .parent = scope, .item = @as(*const ItemT, item) };
                const first_emitted = out.items.len;
                buildChildren(node, child_entries, ui, model, child_scope, out);
                if (comptime (node.attr("key") != null)) {
                    // Mirror of the interpreter: the item key stamps every
                    // node this item emitted (unless the node claims its
                    // own identity); later slots get a slot-suffixed key.
                    const base = itemKey(ItemT, node, comptime node.attr("key").?, ui, item);
                    for (out.items[first_emitted..], 0..) |*built, slot| {
                        if (built.key == null and built.global_key == null) {
                            built.key = canvas.forSlotKey(ui.arena, base, slot) catch {
                                ui.failed = true;
                                return;
                            };
                        }
                    }
                }
            }
        }

        // ------------------------------------------------------- markdown

        const Md = canvas.markdown.Markdown(MsgT);

        /// Comptime mirror of the interpreter's `buildMarkdown`: attrs,
        /// message tags, and the details-expanded source resolve at
        /// comptime; only the source string and expanded flags are read at
        /// runtime. Misuse fails compilation with the interpreter's
        /// message.
        fn buildMarkdown(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            comptime {
                if (node.children.len != 0) fail(node.children[0], markup.markdown_children_message);
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "kind")) continue;
                    if (std.mem.eql(u8, attribute.name, "source")) continue;
                    if (std.mem.eql(u8, attribute.name, "on-link")) continue;
                    if (std.mem.eql(u8, attribute.name, "on-details")) continue;
                    if (std.mem.eql(u8, attribute.name, "details-expanded")) continue;
                    if (std.mem.eql(u8, attribute.name, "issue-link-base")) continue;
                    fail(node, markup.markdown_attr_message);
                }
            }
            const source_path = comptime blk: {
                const raw = node.attr("source") orelse fail(node, markup.markdown_source_message);
                const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.markdown_source_message);
                if (expression != .binding) fail(node, markup.markdown_source_message);
                break :blk expression.binding;
            };
            comptime requireVariant(pathVariant(node, entries, source_path, true), &.{.string}, node, markup.markdown_source_message);
            const source_text = switch (bindingValue(node, entries, source_path, ui, model, scope, true)) {
                .string => |text| text,
                else => runtimeFail([]const u8, ui),
            };

            var options: Md.Options = .{};
            if (comptime (node.attr("on-link") != null)) {
                options.on_link = comptime markdownLinkConstructor(node, node.attr("on-link").?);
            }
            if (comptime (node.attr("on-details") != null)) {
                options.on_details = comptime markdownDetailsConstructor(node, node.attr("on-details").?);
            }
            if (comptime (node.attr("details-expanded") != null)) {
                options.details_expanded = detailsExpandedItems(node, entries, comptime node.attr("details-expanded").?, ui, model, scope);
            }
            if (comptime (node.attr("issue-link-base") != null)) {
                const raw = comptime node.attr("issue-link-base").?;
                comptime {
                    const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.markdown_issue_link_base_message);
                    if (expression == .equals) fail(node, markup.markdown_issue_link_base_message);
                }
                comptime requireVariant(exprVariant(node, entries, raw), &.{.string}, node, markup.markdown_issue_link_base_message);
                const base = switch (evalExpr(node, entries, raw, ui, model, scope)) {
                    .string => |text| text,
                    else => runtimeFail([]const u8, ui),
                };
                if (base.len > 0) options.issue_link_base = base;
            }
            return Md.view(ui, source_text, options);
        }

        fn markdownLinkConstructor(comptime node: markup.MarkupNode, comptime raw: []const u8) Ui.LinkMsgFn {
            comptime {
                @setEvalBranchQuota(10_000);
                const expression = markup.parseMessageExpression(raw) orelse fail(node, markup.markdown_on_link_message);
                if (expression.payload.len != 0) fail(node, markup.markdown_on_link_message);
                for (@typeInfo(MsgT).@"union".fields) |field| {
                    if (field.type == []const u8 and std.mem.eql(u8, field.name, expression.tag)) {
                        return Ui.linkMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
                fail(node, markup.markdown_on_link_message);
            }
        }

        fn markdownDetailsConstructor(comptime node: markup.MarkupNode, comptime raw: []const u8) *const fn (index: usize) MsgT {
            comptime {
                @setEvalBranchQuota(10_000);
                const expression = markup.parseMessageExpression(raw) orelse fail(node, markup.markdown_on_details_message);
                if (expression.payload.len != 0) fail(node, markup.markdown_on_details_message);
                for (@typeInfo(MsgT).@"union".fields) |field| {
                    if (field.type == usize and std.mem.eql(u8, field.name, expression.tag)) {
                        return Md.detailsMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
                fail(node, markup.markdown_on_details_message);
            }
        }

        /// Resolve `details-expanded` through the same sources `for each`
        /// accepts (scope slice args shadow model iterables), requiring a
        /// bool element type at comptime.
        fn detailsExpandedItems(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) []const bool {
            const path = comptime blk: {
                const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.markdown_details_expanded_message);
                if (expression != .binding) fail(node, markup.markdown_details_expanded_message);
                break :blk expression.binding;
            };
            const scope_index_opt = comptime scopeIndex(entries, path);
            if (comptime (scope_index_opt != null)) {
                const scope_index = comptime scope_index_opt.?;
                comptime {
                    if (entries[scope_index].kind != .slice_arg or entries[scope_index].Item != bool) {
                        fail(node, markup.markdown_details_expanded_message);
                    }
                }
                return scopePayload(entries, scope_index, scope);
            }
            const info = comptime (eachInfo(path) orelse fail(node, markup.markdown_details_expanded_message));
            comptime {
                if (info.Item != bool) fail(node, markup.markdown_details_expanded_message);
            }
            return eachItems(info, ui, model);
        }

        // ------------------------------------------------ stepper/timeline

        /// Comptime mirror of the interpreter's `buildStepper`: attrs and
        /// step structure resolve at comptime; the active index and step
        /// labels are read at runtime. Misuse fails compilation with the
        /// interpreter's message.
        fn buildStepper(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            comptime {
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "kind")) continue;
                    if (std.mem.eql(u8, attribute.name, "active")) continue;
                    if (std.mem.eql(u8, attribute.name, "key")) continue;
                    if (std.mem.eql(u8, attribute.name, "global-key")) continue;
                    if (std.mem.eql(u8, attribute.name, "label")) continue;
                    fail(node, markup.stepper_attr_message);
                }
                if (node.attr("active") == null) fail(node, markup.stepper_active_message);
                for (node.children) |child| {
                    if (child.kind != .element or !std.mem.eql(u8, child.name, "step")) {
                        fail(child, markup.stepper_children_message);
                    }
                    for (child.attrs) |attribute| {
                        if (!std.mem.eql(u8, attribute.name, "kind")) fail(child, markup.step_attr_message);
                    }
                }
            }
            var options: Ui.StepperOptions = .{};
            const active_raw = comptime node.attr("active").?;
            comptime requireVariant(exprVariant(node, entries, active_raw), &.{.integer}, node, markup.stepper_active_message);
            options.active = switch (evalExpr(node, entries, active_raw, ui, model, scope)) {
                .integer => |int| if (int < 0) 0 else @intCast(int),
                else => runtimeFail(usize, ui),
            };
            if (comptime (node.attr("key") != null)) {
                options.key = attrKey(node, entries, comptime node.attr("key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("global-key") != null)) {
                options.global_key = attrKey(node, entries, comptime node.attr("global-key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("label") != null)) {
                options.semantics.label = stringAttr(node, entries, comptime node.attr("label").?, ui, model, scope, "label expects text");
            }
            const steps = ui.arena.alloc(Ui.StepperStep, node.children.len) catch {
                ui.failed = true;
                return ui.el(.row, .{}, .{});
            };
            inline for (0..node.children.len) |index| {
                steps[index] = .{ .label = interpolatedText(comptime node.children[index], entries, ui, model, scope) };
            }
            return ui.stepper(options, steps);
        }

        /// Comptime mirror of the interpreter's `buildTimeline`.
        fn buildTimeline(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            comptime {
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "kind")) continue;
                    if (std.mem.eql(u8, attribute.name, "gap")) continue;
                    if (std.mem.eql(u8, attribute.name, "grow")) continue;
                    if (std.mem.eql(u8, attribute.name, "key")) continue;
                    if (std.mem.eql(u8, attribute.name, "global-key")) continue;
                    if (std.mem.eql(u8, attribute.name, "label")) continue;
                    fail(node, markup.timeline_attr_message);
                }
            }
            var options: Ui.TimelineOptions = .{};
            if (comptime (node.attr("gap") != null)) {
                options.gap = floatAttr(node, entries, comptime node.attr("gap").?, ui, model, scope);
            }
            if (comptime (node.attr("grow") != null)) {
                options.grow = floatAttr(node, entries, comptime node.attr("grow").?, ui, model, scope);
            }
            if (comptime (node.attr("key") != null)) {
                options.key = attrKey(node, entries, comptime node.attr("key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("global-key") != null)) {
                options.global_key = attrKey(node, entries, comptime node.attr("global-key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("label") != null)) {
                options.semantics.label = stringAttr(node, entries, comptime node.attr("label").?, ui, model, scope, "label expects text");
            }
            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            buildChildren(node, entries, ui, model, scope, &children);
            return ui.timeline(options, @as([]const Ui.Node, children.items));
        }

        /// Comptime mirror of the interpreter's `buildTimelineItem`.
        fn buildTimelineItem(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            comptime {
                if (node.children.len != 0) fail(node.children[0], markup.timeline_item_children_message);
                if (node.attr("title") == null) fail(node, markup.timeline_item_title_message);
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "kind")) continue;
                    if (std.mem.eql(u8, attribute.name, "title")) continue;
                    if (std.mem.eql(u8, attribute.name, "description")) continue;
                    if (std.mem.eql(u8, attribute.name, "meta")) continue;
                    if (std.mem.eql(u8, attribute.name, "indicator")) continue;
                    if (std.mem.eql(u8, attribute.name, "icon")) continue;
                    if (std.mem.eql(u8, attribute.name, "variant")) continue;
                    if (std.mem.eql(u8, attribute.name, "connector")) continue;
                    if (std.mem.eql(u8, attribute.name, "selected")) continue;
                    if (std.mem.eql(u8, attribute.name, "on-press")) continue;
                    if (std.mem.startsWith(u8, attribute.name, "on-")) fail(node, markup.timeline_item_press_only_message);
                    if (std.mem.eql(u8, attribute.name, "key")) continue;
                    if (std.mem.eql(u8, attribute.name, "global-key")) continue;
                    fail(node, markup.timeline_item_attr_message);
                }
            }
            var options: Ui.TimelineItemOptions = .{ .title = "" };
            options.title = stringAttr(node, entries, comptime node.attr("title").?, ui, model, scope, markup.timeline_item_text_attr_message);
            if (comptime (node.attr("description") != null)) {
                options.description = stringAttr(node, entries, comptime node.attr("description").?, ui, model, scope, markup.timeline_item_text_attr_message);
            }
            if (comptime (node.attr("meta") != null)) {
                options.meta = stringAttr(node, entries, comptime node.attr("meta").?, ui, model, scope, markup.timeline_item_text_attr_message);
            }
            if (comptime (node.attr("indicator") != null)) {
                options.indicator = stringAttr(node, entries, comptime node.attr("indicator").?, ui, model, scope, markup.timeline_item_text_attr_message);
            }
            if (comptime (node.attr("icon") != null)) {
                // Vector icon indicator: closed literal vocabulary,
                // resolved at comptime like every icon attribute.
                options.icon = comptime blk: {
                    const expression = markup.parseAttrExpression(node.attr("icon").?) orelse fail(node, markup.button_icon_message);
                    if (expression != .literal) fail(node, markup.button_icon_message);
                    if (canvas.icons.find(expression.literal) == null) fail(node, markup.button_icon_message);
                    break :blk expression.literal;
                };
            }
            if (comptime (node.attr("variant") != null)) {
                const raw = comptime node.attr("variant").?;
                comptime requireVariant(exprVariant(node, entries, raw), &.{.string}, node, "expected an option name");
                const expression = comptime markup.parseAttrExpression(raw).?;
                if (comptime (expression == .literal)) {
                    options.variant = comptime (std.meta.stringToEnum(canvas.WidgetVariant, expression.literal) orelse fail(node, "unknown option value"));
                } else {
                    const text = switch (evalExpr(node, entries, raw, ui, model, scope)) {
                        .string => |text| text,
                        else => runtimeFail([]const u8, ui),
                    };
                    options.variant = std.meta.stringToEnum(canvas.WidgetVariant, text) orelse runtimeFail(canvas.WidgetVariant, ui);
                }
            }
            if (comptime (node.attr("connector") != null)) {
                options.connector = evalExpr(node, entries, comptime node.attr("connector").?, ui, model, scope).truthy();
            }
            if (comptime (node.attr("selected") != null)) {
                options.selected = evalExpr(node, entries, comptime node.attr("selected").?, ui, model, scope).truthy();
            }
            if (comptime (node.attr("on-press") != null)) {
                // Reuse the full message-attr machinery (payload bindings
                // included) through a scratch options value.
                const press_index = comptime blk: {
                    for (node.attrs, 0..) |attribute, index| {
                        if (std.mem.eql(u8, attribute.name, "on-press")) break :blk index;
                    }
                    unreachable;
                };
                var scratch: Ui.ElementOptions = .{};
                applyMessageAttr(node, comptime node.attrs[press_index], entries, ui, model, scope, &scratch);
                options.on_press = scratch.on_press;
            }
            if (comptime (node.attr("key") != null)) {
                options.key = attrKey(node, entries, comptime node.attr("key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("global-key") != null)) {
                options.global_key = attrKey(node, entries, comptime node.attr("global-key").?, ui, model, scope, "keys must be integers or strings");
            }
            return ui.timelineItem(options);
        }

        fn stringAttr(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype, comptime message: []const u8) []const u8 {
            comptime requireVariant(exprVariant(node, entries, raw), &.{.string}, node, message);
            return switch (evalExpr(node, entries, raw, ui, model, scope)) {
                .string => |text| text,
                else => runtimeFail([]const u8, ui),
            };
        }

        fn floatAttr(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) f32 {
            comptime requireVariant(exprVariant(node, entries, raw), &.{ .float, .integer }, node, "expected a number");
            return switch (evalExpr(node, entries, raw, ui, model, scope)) {
                .float => |float| float,
                .integer => |int| @floatFromInt(int),
                else => runtimeFail(f32, ui),
            };
        }

        // ------------------------------------------------------ templates

        /// A `<use>` arg as resolved at comptime against the use site: a
        /// scalar `Value` (literal, equality, or scalar binding) or a
        /// slice (a model iterable path, or a slice arg re-passed from an
        /// enclosing template).
        const ArgSpec = struct {
            name: []const u8,
            raw: []const u8,
            kind: Kind,
            Item: type = void,
            variant: ?ValueVariant = null,
            each: ?EachInfo = null,
            site_index: ?usize = null,

            const Kind = enum { value, slice };
        };

        /// Expand a `<use>` site: resolve the template, check its declared
        /// args against the use attributes, evaluate the args against the
        /// use-site scope, and inline the template's single element child
        /// in place — structural ids hash through the parent chain at the
        /// expansion site, exactly as if the body were written inline. The
        /// body's scope holds only the args (plus the model), never the
        /// use site's loop variables.
        fn buildUse(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            const template_name = comptime (node.attr("template") orelse fail(node, markup.use_template_attr_message));
            const template_index = comptime (document.templateIndex(template_name) orelse fail(node, markup.use_undefined_template_message));
            const template_node = comptime document.templates[template_index];
            comptime {
                if (template_node.children.len != 1 or template_node.children[0].kind != .element) {
                    fail(template_node, markup.template_one_child_message);
                }
                if (node.children.len != 0) fail(node, markup.use_no_children_message);
            }
            const specs = comptime useArgSpecs(node, template_node, entries);
            const body_entries = comptime argEntries(specs);
            const body_scope = buildArgScope(specs, entries, node, ui, model, scope);
            return buildElement(comptime template_node.children[0], body_entries, ui, model, body_scope);
        }

        fn useArgSpecs(comptime node: markup.MarkupNode, comptime template_node: markup.MarkupNode, comptime site_entries: []const ScopeEntry) []const ArgSpec {
            comptime {
                @setEvalBranchQuota(10_000);
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "template")) continue;
                    if (!markup.templateDeclaresArg(template_node, attribute.name)) {
                        fail(node, markup.use_extra_arg_message);
                    }
                }
                var specs: []const ArgSpec = &.{};
                var args = markup.templateArgs(template_node);
                while (args.next()) |arg_name| {
                    const raw = node.attr(arg_name) orelse fail(node, markup.use_missing_arg_message);
                    specs = specs ++ &[_]ArgSpec{argSpec(node, site_entries, arg_name, raw)};
                }
                return specs;
            }
        }

        /// Comptime mirror of the interpreter's `argPayload` resolution
        /// order: scope entries shadow model iterables; a binding naming
        /// an iterable becomes a slice arg, anything else a value arg.
        fn argSpec(comptime node: markup.MarkupNode, comptime site_entries: []const ScopeEntry, comptime arg_name: []const u8, comptime raw: []const u8) ArgSpec {
            comptime {
                const expression = markup.parseAttrExpression(raw) orelse fail(node, invalid_expression_message);
                if (expression == .binding) {
                    const path = expression.binding;
                    const head = interpreter.pathHead(path);
                    if (scopeIndex(site_entries, head)) |index| {
                        if (site_entries[index].kind == .slice_arg and interpreter.pathTail(path) == null) {
                            return .{ .name = arg_name, .raw = raw, .kind = .slice, .Item = site_entries[index].Item, .site_index = index };
                        }
                    } else if (eachInfo(path)) |info| {
                        // Strings stay scalars (interpreter parity): a
                        // binding producing []const u8 binds as a value
                        // arg, never as an iterable of bytes.
                        if (info.Item != u8) {
                            return .{ .name = arg_name, .raw = raw, .kind = .slice, .Item = info.Item, .each = info };
                        }
                    }
                }
                return .{ .name = arg_name, .raw = raw, .kind = .value, .variant = exprVariant(node, site_entries, raw) };
            }
        }

        fn argEntries(comptime specs: []const ArgSpec) []const ScopeEntry {
            comptime {
                var entries: []const ScopeEntry = &.{};
                for (specs) |spec| {
                    entries = entries ++ &[_]ScopeEntry{switch (spec.kind) {
                        .value => .{ .name = spec.name, .kind = .value_arg, .variant = spec.variant },
                        .slice => .{ .name = spec.name, .kind = .slice_arg, .Item = spec.Item },
                    }};
                }
                return entries;
            }
        }

        fn ArgPayload(comptime spec: ArgSpec) type {
            return switch (spec.kind) {
                .value => Value,
                .slice => []const spec.Item,
            };
        }

        /// The scope chain type for a template body: one link per arg,
        /// nothing from the use site — a template sees the model and its
        /// args, never the loop variables where it is used.
        fn ArgScope(comptime specs: []const ArgSpec) type {
            if (specs.len == 0) return struct {};
            return struct {
                parent: ArgScope(specs[0 .. specs.len - 1]),
                item: ArgPayload(specs[specs.len - 1]),
            };
        }

        fn buildArgScope(comptime specs: []const ArgSpec, comptime site_entries: []const ScopeEntry, comptime node: markup.MarkupNode, ui: *Ui, model: *const ModelT, site_scope: anytype) ArgScope(specs) {
            if (comptime (specs.len == 0)) return .{};
            return .{
                .parent = buildArgScope(comptime specs[0 .. specs.len - 1], site_entries, node, ui, model, site_scope),
                .item = argPayloadValue(comptime specs[specs.len - 1], site_entries, node, ui, model, site_scope),
            };
        }

        fn argPayloadValue(comptime spec: ArgSpec, comptime site_entries: []const ScopeEntry, comptime node: markup.MarkupNode, ui: *Ui, model: *const ModelT, site_scope: anytype) ArgPayload(spec) {
            if (comptime (spec.kind == .slice)) {
                if (comptime (spec.site_index != null)) {
                    return scopePayload(site_entries, comptime spec.site_index.?, site_scope);
                }
                return eachItems(comptime spec.each.?, ui, model);
            }
            return evalExpr(node, site_entries, spec.raw, ui, model, site_scope);
        }

        // -------------------------------------------------- `for` sources

        const EachKind = enum { field, decl_slice, decl_fn, decl_fn_arena };
        const EachInfo = struct { Item: type, kind: EachKind, name: []const u8 };

        /// Comptime mirror of the interpreter's `iterateItems` resolution:
        /// a Model slice/array field, a public array/slice declaration, or
        /// a public function returning a slice (optionally taking an
        /// arena).
        fn eachInfo(comptime each: []const u8) ?EachInfo {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(ModelT).@"struct".fields) |field| {
                    if (!std.mem.eql(u8, field.name, each)) continue;
                    if (interpreter.sliceElement(field.type)) |Element| {
                        return .{ .Item = Element, .kind = .field, .name = field.name };
                    }
                }
                for (@typeInfo(ModelT).@"struct".decls) |decl| {
                    if (!std.mem.eql(u8, decl.name, each)) continue;
                    const DeclType = @TypeOf(@field(ModelT, decl.name));
                    if (interpreter.sliceElement(DeclType)) |Element| {
                        return .{ .Item = Element, .kind = .decl_slice, .name = decl.name };
                    }
                    switch (@typeInfo(DeclType)) {
                        .@"fn" => |fn_info| {
                            const Return = fn_info.return_type orelse continue;
                            const Element = interpreter.sliceElement(Return) orelse continue;
                            if (interpreter.isItemFn(DeclType, Element, false)) {
                                return .{ .Item = Element, .kind = .decl_fn, .name = decl.name };
                            }
                            if (interpreter.isItemFn(DeclType, Element, true)) {
                                return .{ .Item = Element, .kind = .decl_fn_arena, .name = decl.name };
                            }
                        },
                        else => {},
                    }
                }
                return null;
            }
        }

        fn eachItems(comptime info: EachInfo, ui: *Ui, model: *const ModelT) []const info.Item {
            return switch (comptime info.kind) {
                .field => interpreter.asSlice(info.Item, &@field(model, info.name)),
                .decl_slice => interpreter.asSlice(info.Item, &@field(ModelT, info.name)),
                .decl_fn => @field(ModelT, info.name)(model),
                .decl_fn_arena => @field(ModelT, info.name)(model, ui.arena),
            };
        }

        fn itemKey(comptime Item: type, comptime node: markup.MarkupNode, comptime field_path: []const u8, ui: *Ui, item: *const Item) canvas.UiKey {
            // Keys stay identity-stable data: fields and zero-arg
            // methods only, never arena-computed values (the interpreter
            // resolves keys with a null arena for the same reason).
            const Leaf = comptime (OnType(Item, field_path, false) orelse fail(node, "key does not name a field on the item"));
            comptime requireVariant(bindingVariant(Leaf), &.{ .integer, .string }, node, "key fields must be integers or strings");
            const value = interpreter.valueOf(Leaf, valueOn(Item, field_path, item, ui.arena)) orelse unreachable;
            return uiKeyFromValue(value, ui);
        }

        // ---------------------------------------------------- attributes

        fn applyAttrs(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, options: *Ui.ElementOptions) void {
            inline for (0..node.attrs.len) |attr_index| {
                const attribute = comptime node.attrs[attr_index];
                if (comptime std.mem.eql(u8, attribute.name, "kind")) {
                    // Engine hint for tooling; the interpreter skips it too.
                } else if (comptime std.mem.startsWith(u8, attribute.name, "on-")) {
                    applyMessageAttr(node, attribute, entries, ui, model, scope, options);
                } else if (comptime std.mem.eql(u8, attribute.name, "key")) {
                    options.key = attrKey(node, entries, attribute.value, ui, model, scope, "keys must be integers or strings");
                } else if (comptime std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = attrKey(node, entries, attribute.value, ui, model, scope, "keys must be integers or strings");
                } else if (comptime std.mem.eql(u8, attribute.name, "role")) {
                    options.semantics.role = roleValue(node, entries, attribute.value, ui, model, scope);
                } else if (comptime std.mem.eql(u8, attribute.name, "label")) {
                    comptime requireVariant(exprVariant(node, entries, attribute.value), &.{.string}, node, "label expects text");
                    options.semantics.label = switch (evalExpr(node, entries, attribute.value, ui, model, scope)) {
                        .string => |text| text,
                        else => runtimeFail([]const u8, ui),
                    };
                } else if (comptime std.mem.eql(u8, attribute.name, "image")) {
                    applyImageAttr(node, attribute.value, entries, ui, model, scope, options);
                } else if (comptime std.mem.eql(u8, attribute.name, "name")) {
                    // Consumed by the icon branch in buildElement; a
                    // compile error on any other element (interpreter and
                    // validator parity).
                    comptime if (!std.mem.eql(u8, node.name, "icon")) fail(node, markup.icon_name_element_message);
                } else if (comptime std.mem.eql(u8, attribute.name, "icon")) {
                    // Inline icon scoped to the labeled interactive
                    // elements (button, toggle-button, list-item,
                    // menu-item): the same closed literal vocabulary as
                    // <icon name>, resolved at comptime so a typo is a
                    // compile error (interpreter and validator parity).
                    options.icon = comptime blk: {
                        if (!markup.iconAttrElement(node.name)) fail(node, markup.button_icon_element_message);
                        const expression = markup.parseAttrExpression(attribute.value) orelse fail(node, markup.button_icon_message);
                        if (expression != .literal) fail(node, markup.button_icon_message);
                        if (canvas.icons.find(expression.literal) == null) fail(node, markup.button_icon_message);
                        break :blk expression.literal;
                    };
                } else if (comptime std.mem.eql(u8, attribute.name, "anchor")) {
                    // Anchored floating placement, dropdown-menu-scoped:
                    // a literal side resolved at comptime (interpreter
                    // and validator parity).
                    options.anchor = comptime blk: {
                        if (!markup.anchorElement(node.name)) fail(node, markup.anchor_element_message);
                        break :blk std.meta.stringToEnum(canvas.WidgetAnchorPlacement, attribute.value) orelse
                            fail(node, markup.anchor_value_message);
                    };
                } else if (comptime std.mem.eql(u8, attribute.name, "anchor-alignment")) {
                    options.anchor_alignment = comptime blk: {
                        if (!markup.anchorElement(node.name)) fail(node, markup.anchor_element_message);
                        if (node.attr("anchor") == null) fail(node, markup.anchor_dependent_attr_message);
                        break :blk std.meta.stringToEnum(canvas.WidgetAnchorAlignment, attribute.value) orelse
                            fail(node, markup.anchor_alignment_value_message);
                    };
                } else if (comptime std.mem.eql(u8, attribute.name, "anchor-offset")) {
                    options.anchor_offset = comptime blk: {
                        if (!markup.anchorElement(node.name)) fail(node, markup.anchor_element_message);
                        if (node.attr("anchor") == null) fail(node, markup.anchor_dependent_attr_message);
                        break :blk std.fmt.parseFloat(f32, attribute.value) catch
                            fail(node, markup.anchor_offset_value_message);
                    };
                } else if (comptime (colorStyleField(attribute.name) != null)) {
                    // Style token refs resolve entirely at comptime: a typo
                    // in a token name is a compile error.
                    @field(options.style_tokens, colorStyleField(attribute.name).?) =
                        comptime colorTokenRef(node, attribute.value);
                } else if (comptime std.mem.eql(u8, attribute.name, "radius")) {
                    options.style_tokens.radius = comptime radiusTokenRef(node, attribute.value);
                } else {
                    setOption(node, comptime optionFieldName(node, attribute.name), attribute.value, entries, ui, model, scope, options);
                }
            }
        }

        /// Comptime mirror of the interpreter's `applyImageAttr`:
        /// `image="{binding}"` on avatar resolves to a `u64` ImageId the
        /// app registered at runtime — avatar-only, binding-only, and the
        /// binding must produce an integer, all checked at comptime with
        /// the interpreter's messages.
        fn applyImageAttr(comptime node: markup.MarkupNode, comptime raw: []const u8, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, options: *Ui.ElementOptions) void {
            comptime {
                if (!std.mem.eql(u8, node.name, "avatar")) fail(node, markup.avatar_image_element_message);
                const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.avatar_image_message);
                if (expression != .binding) fail(node, markup.avatar_image_message);
            }
            const path = comptime markup.parseAttrExpression(raw).?.binding;
            comptime requireVariant(pathVariant(node, entries, path, true), &.{.integer}, node, markup.avatar_image_message);
            options.image = switch (bindingValue(node, entries, path, ui, model, scope, true)) {
                .integer => |int| @intCast(int),
                else => runtimeFail(canvas.ImageId, ui),
            };
        }

        fn colorStyleField(comptime attr_name: []const u8) ?[]const u8 {
            comptime {
                @setEvalBranchQuota(10_000);
                for (interpreter.color_style_attr_fields) |entry| {
                    if (std.mem.eql(u8, attr_name, entry.markup)) return entry.zig;
                }
                return null;
            }
        }

        fn styleTokenLiteral(comptime node: markup.MarkupNode, comptime raw: []const u8) []const u8 {
            comptime {
                const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.style_token_literal_message);
                if (expression != .literal) fail(node, markup.style_token_literal_message);
                return expression.literal;
            }
        }

        fn colorTokenRef(comptime node: markup.MarkupNode, comptime raw: []const u8) canvas.ColorTokenName {
            comptime {
                return std.meta.stringToEnum(canvas.ColorTokenName, styleTokenLiteral(node, raw)) orelse
                    fail(node, markup.unknown_color_token_message);
            }
        }

        fn radiusTokenRef(comptime node: markup.MarkupNode, comptime raw: []const u8) canvas.RadiusTokenName {
            comptime {
                return std.meta.stringToEnum(canvas.RadiusTokenName, styleTokenLiteral(node, raw)) orelse
                    fail(node, markup.unknown_radius_token_message);
            }
        }

        fn optionFieldName(comptime node: markup.MarkupNode, comptime attr_name: []const u8) []const u8 {
            comptime {
                @setEvalBranchQuota(10_000);
                for (interpreter.attr_names) |name| {
                    if (std.mem.eql(u8, attr_name, name.markup)) return name.zig;
                }
                fail(node, "unknown attribute for this element");
            }
        }

        fn setOption(comptime node: markup.MarkupNode, comptime zig_field: []const u8, comptime raw: []const u8, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, options: *Ui.ElementOptions) void {
            const FieldType = @FieldType(Ui.ElementOptions, zig_field);
            const variant = comptime exprVariant(node, entries, raw);
            switch (comptime @typeInfo(FieldType)) {
                .float => {
                    comptime requireVariant(variant, &.{ .float, .integer }, node, "expected a number");
                    @field(options, zig_field) = switch (evalExpr(node, entries, raw, ui, model, scope)) {
                        .float => |float| float,
                        .integer => |int| @floatFromInt(int),
                        else => runtimeFail(FieldType, ui),
                    };
                },
                .bool => @field(options, zig_field) = evalExpr(node, entries, raw, ui, model, scope).truthy(),
                // Optional bools (`expanded`): the attribute's PRESENCE
                // makes the state non-null; the value sets it.
                .optional => @field(options, zig_field) = evalExpr(node, entries, raw, ui, model, scope).truthy(),
                .int => {
                    comptime requireVariant(variant, &.{.integer}, node, "expected a whole number");
                    @field(options, zig_field) = switch (evalExpr(node, entries, raw, ui, model, scope)) {
                        .integer => |int| if (int < 0) runtimeFail(FieldType, ui) else @intCast(int),
                        else => runtimeFail(FieldType, ui),
                    };
                },
                .@"enum" => {
                    comptime requireVariant(variant, &.{.string}, node, "expected an option name");
                    const expression = comptime markup.parseAttrExpression(raw).?;
                    if (comptime (expression == .literal)) {
                        // Literal option names resolve at comptime: a typo
                        // is a compile error, not a failed rebuild.
                        @field(options, zig_field) = comptime (std.meta.stringToEnum(FieldType, expression.literal) orelse fail(node, "unknown option value"));
                    } else {
                        const text = switch (evalExpr(node, entries, raw, ui, model, scope)) {
                            .string => |text| text,
                            else => runtimeFail([]const u8, ui),
                        };
                        @field(options, zig_field) = std.meta.stringToEnum(FieldType, text) orelse runtimeFail(FieldType, ui);
                    }
                },
                .pointer => {
                    comptime requireVariant(variant, &.{.string}, node, "expected text");
                    @field(options, zig_field) = switch (evalExpr(node, entries, raw, ui, model, scope)) {
                        .string => |text| text,
                        else => runtimeFail(FieldType, ui),
                    };
                },
                else => comptime fail(node, "attribute is not settable from markup"),
            }
        }

        fn attrKey(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype, comptime message: []const u8) canvas.UiKey {
            comptime requireVariant(exprVariant(node, entries, raw), &.{ .integer, .string }, node, message);
            return uiKeyFromValue(evalExpr(node, entries, raw, ui, model, scope), ui);
        }

        fn uiKeyFromValue(value: Value, ui: *Ui) canvas.UiKey {
            return switch (value) {
                .integer => |int| canvas.uiKey(@as(u64, @intCast(int))),
                .string => |text| canvas.uiKey(text),
                else => blk: {
                    ui.failed = true;
                    break :blk canvas.uiKey(@as(u64, 0));
                },
            };
        }

        fn roleValue(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) canvas.WidgetRole {
            comptime requireVariant(exprVariant(node, entries, raw), &.{.string}, node, "role expects a role name");
            const expression = comptime (markup.parseAttrExpression(raw) orelse fail(node, invalid_expression_message));
            if (comptime (expression == .literal)) {
                return comptime (std.meta.stringToEnum(canvas.WidgetRole, expression.literal) orelse fail(node, "unknown role"));
            }
            const text = switch (evalExpr(node, entries, raw, ui, model, scope)) {
                .string => |text| text,
                else => runtimeFail([]const u8, ui),
            };
            return std.meta.stringToEnum(canvas.WidgetRole, text) orelse runtimeFail(canvas.WidgetRole, ui);
        }

        // ------------------------------------------------------ messages

        fn applyMessageAttr(comptime node: markup.MarkupNode, comptime attribute: markup.MarkupAttr, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, options: *Ui.ElementOptions) void {
            const expression = comptime (markup.parseMessageExpression(attribute.value) orelse fail(node, "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")"));
            const event = comptime attribute.name[3..];
            if (comptime std.mem.eql(u8, event, "input")) {
                options.on_input = comptime (inputConstructor(expression.tag) orelse fail(node, "on-input tag must carry a TextInputEvent payload"));
                return;
            }
            if (comptime std.mem.eql(u8, event, "scroll")) {
                comptime {
                    if (!std.mem.eql(u8, node.name, "scroll")) fail(node, markup.on_scroll_element_message);
                }
                options.on_scroll = comptime (scrollConstructor(expression.tag) orelse fail(node, markup.on_scroll_payload_message));
                return;
            }
            if (comptime std.mem.eql(u8, event, "resize")) {
                comptime {
                    if (!std.mem.eql(u8, node.name, "split")) fail(node, markup.on_resize_element_message);
                }
                options.on_resize = comptime (resizeConstructor(expression.tag) orelse fail(node, markup.on_resize_payload_message));
                return;
            }
            const msg = constructMessage(node, expression, entries, ui, model, scope);
            if (comptime std.mem.eql(u8, event, "press")) {
                options.on_press = msg;
            } else if (comptime std.mem.eql(u8, event, "toggle")) {
                options.on_toggle = msg;
            } else if (comptime std.mem.eql(u8, event, "change")) {
                options.on_change = msg;
            } else if (comptime std.mem.eql(u8, event, "submit")) {
                options.on_submit = msg;
            } else if (comptime std.mem.eql(u8, event, "dismiss")) {
                // Only dismissible surfaces are ever dismissed by the
                // runtime (interpreter and validator parity).
                comptime {
                    if (!markup.dismissEventElement(node.name)) fail(node, markup.on_dismiss_element_message);
                }
                options.on_dismiss = msg;
            } else if (comptime std.mem.eql(u8, event, "hold")) {
                // Press family: like on-press, a bound hold makes any
                // element pressable.
                options.on_hold = msg;
            } else if (comptime std.mem.eql(u8, event, "reach-end")) {
                // The approach-end signal (infinite-scroll fetch) is
                // emitted for scroll containers only (interpreter and
                // validator parity).
                comptime {
                    if (!std.mem.eql(u8, node.name, "scroll")) fail(node, markup.on_reach_end_element_message);
                }
                options.on_reach_end = msg;
            } else {
                comptime fail(node, "unknown event attribute");
            }
        }

        fn inputConstructor(comptime tag: []const u8) ?Ui.InputMsgFn {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(MsgT).@"union".fields) |field| {
                    if (field.type == canvas.TextInputEvent and std.mem.eql(u8, field.name, tag)) {
                        return Ui.inputMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
                return null;
            }
        }

        fn scrollConstructor(comptime tag: []const u8) ?Ui.ScrollMsgFn {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(MsgT).@"union".fields) |field| {
                    if (field.type == canvas.ScrollState and std.mem.eql(u8, field.name, tag)) {
                        return Ui.scrollMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
                return null;
            }
        }

        fn resizeConstructor(comptime tag: []const u8) ?Ui.ValueMsgFn {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(MsgT).@"union".fields) |field| {
                    if (field.type == f32 and std.mem.eql(u8, field.name, tag)) {
                        return Ui.valueMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
                return null;
            }
        }

        fn msgTagIndex(comptime tag: []const u8) ?usize {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(MsgT).@"union".fields, 0..) |field, index| {
                    if (std.mem.eql(u8, field.name, tag)) return index;
                }
                return null;
            }
        }

        fn constructMessage(comptime node: markup.MarkupNode, comptime expression: markup.MessageExpression, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) MsgT {
            const tag_index = comptime (msgTagIndex(expression.tag) orelse fail(node, "unknown message tag"));
            const field = comptime @typeInfo(MsgT).@"union".fields[tag_index];
            if (comptime (field.type == void)) {
                comptime {
                    if (expression.payload.len > 0) fail(node, "message does not take a payload");
                }
                return @unionInit(MsgT, field.name, {});
            }
            comptime {
                if (expression.payload.len == 0) fail(node, "message requires a payload");
            }
            const variant = comptime pathVariant(node, entries, expression.payload, true);
            const value = bindingValue(node, entries, expression.payload, ui, model, scope, true);
            return @unionInit(MsgT, field.name, coerce(field.type, node, variant, ui, value));
        }

        /// Runtime mirror of the interpreter's `coerce`, with the
        /// type-determined mismatches promoted to compile errors. Only
        /// value-dependent conversions (optional bindings, enum tags from
        /// arbitrary strings) can still fail, latching `ui.failed`.
        fn coerce(comptime T: type, comptime node: markup.MarkupNode, comptime variant: ?ValueVariant, ui: *Ui, value: Value) T {
            switch (comptime @typeInfo(T)) {
                .int => {
                    comptime requireVariant(variant, &.{.integer}, node, "payload type does not match the message");
                    return switch (value) {
                        .integer => |int| @intCast(int),
                        else => runtimeFail(T, ui),
                    };
                },
                .float => {
                    comptime requireVariant(variant, &.{ .float, .integer }, node, "payload type does not match the message");
                    return switch (value) {
                        .float => |float| @floatCast(float),
                        .integer => |int| @floatFromInt(int),
                        else => runtimeFail(T, ui),
                    };
                },
                .@"enum" => {
                    comptime requireVariant(variant, &.{.string}, node, "payload type does not match the message");
                    return switch (value) {
                        .string => |text| std.meta.stringToEnum(T, text) orelse runtimeFail(T, ui),
                        else => runtimeFail(T, ui),
                    };
                },
                .pointer => {
                    comptime requireVariant(variant, &.{.string}, node, "payload type does not match the message");
                    return switch (value) {
                        .string => |text| text,
                        else => runtimeFail(T, ui),
                    };
                },
                .bool => return value.truthy(),
                else => comptime fail(node, "payload type does not match the message"),
            }
        }

        // --------------------------------------------------- expressions

        const invalid_expression_message = markup.invalid_expression_message;

        fn evalExpr(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) Value {
            const expression = comptime (markup.parseAttrExpression(raw) orelse fail(node, invalid_expression_message));
            if (comptime (expression == .literal)) {
                return comptime interpreter.literalValue(expression.literal);
            }
            if (comptime (expression == .binding)) {
                return bindingValue(node, entries, comptime expression.binding, ui, model, scope, true);
            }
            // Arena-computed bindings are excluded from equality on
            // purpose (same rule as the interpreter): comparing freshly
            // formatted strings is a smell — compare source fields, or
            // bind a bool-returning fn.
            const sides = comptime expression.equals;
            return .{ .boolean = Value.eql(
                bindingValue(node, entries, sides.left, ui, model, scope, false),
                bindingValue(node, entries, sides.right, ui, model, scope, false),
            ) };
        }

        /// The comptime-known `Value` variant an expression produces, or
        /// null when it is only runtime-known (a binding through an
        /// optional). Used to promote type mismatches to compile errors.
        fn exprVariant(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8) ?ValueVariant {
            comptime {
                const expression = markup.parseAttrExpression(raw) orelse fail(node, invalid_expression_message);
                return switch (expression) {
                    .literal => |text| @as(ValueVariant, switch (interpreter.literalValue(text)) {
                        .string => .string,
                        .integer => .integer,
                        .float => .float,
                        .boolean => .boolean,
                    }),
                    .binding => |path| pathVariant(node, entries, path, true),
                    .equals => .boolean,
                };
            }
        }

        /// Innermost scope entry whose name matches `head`.
        fn scopeIndex(comptime entries: []const ScopeEntry, comptime head: []const u8) ?usize {
            comptime {
                @setEvalBranchQuota(10_000);
                var index = entries.len;
                while (index > 0) {
                    index -= 1;
                    if (std.mem.eql(u8, entries[index].name, head)) return index;
                }
                return null;
            }
        }

        fn scopePayload(comptime entries: []const ScopeEntry, comptime index: usize, scope: anytype) EntryPayload(entries[index]) {
            if (comptime (index == entries.len - 1)) return scope.item;
            return scopePayload(entries[0 .. entries.len - 1], index, scope.parent);
        }

        /// Comptime mirror of the interpreter's `evalBinding` resolution
        /// for loop items and model paths: the Zig type a binding path
        /// resolves to, or a compile error with the interpreter's message.
        /// Value args have no leaf type; `pathVariant` handles them.
        /// `allow_arena` gates arena-taking scalar fns (allowed everywhere
        /// except inside `{a == b}` equality, with a teaching error).
        fn BindingLeaf(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime path: []const u8, comptime allow_arena: bool) type {
            comptime {
                const head = interpreter.pathHead(path);
                if (scopeIndex(entries, head)) |index| {
                    const entry = entries[index];
                    if (entry.kind == .slice_arg) fail(node, "slice-valued template args are only usable with for each");
                    if (entry.kind == .value_arg) fail(node, "template arg values have no fields");
                    const Item = entry.Item;
                    if (interpreter.pathTail(path)) |tail| {
                        return OnType(Item, tail, allow_arena) orelse {
                            if (!allow_arena and OnType(Item, tail, true) != null) {
                                fail(node, markup.arena_scalar_equality_message);
                            }
                            fail(node, "binding does not name a field on the loop item");
                        };
                    }
                    if (!supportedValue(Item)) fail(node, "loop items of this type cannot be used as values");
                    return Item;
                }
                return OnType(ModelT, path, allow_arena) orelse {
                    if (!allow_arena and OnType(ModelT, path, true) != null) {
                        fail(node, markup.arena_scalar_equality_message);
                    }
                    fail(node, "binding does not name a model field");
                };
            }
        }

        /// The comptime-known Value variant a binding path produces:
        /// template value args carry their use-site variant, loop items
        /// and model paths derive it from the resolved leaf type.
        fn pathVariant(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime path: []const u8, comptime allow_arena: bool) ?ValueVariant {
            comptime {
                const head = interpreter.pathHead(path);
                if (scopeIndex(entries, head)) |index| {
                    if (entries[index].kind == .value_arg) {
                        if (interpreter.pathTail(path) != null) fail(node, "template arg values have no fields");
                        return entries[index].variant;
                    }
                }
                return bindingVariant(BindingLeaf(node, entries, path, allow_arena));
            }
        }

        fn bindingValue(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime path: []const u8, ui: *Ui, model: *const ModelT, scope: anytype, comptime allow_arena: bool) Value {
            const head = comptime interpreter.pathHead(path);
            const index_opt = comptime scopeIndex(entries, head);
            if (comptime (index_opt != null)) {
                const index = comptime index_opt.?;
                const entry = comptime entries[index];
                if (comptime (entry.kind == .value_arg)) {
                    comptime {
                        if (interpreter.pathTail(path) != null) fail(node, "template arg values have no fields");
                    }
                    return scopePayload(entries, index, scope);
                }
                if (comptime (entry.kind == .slice_arg)) {
                    comptime fail(node, "slice-valued template args are only usable with for each");
                }
                const Leaf = comptime BindingLeaf(node, entries, path, allow_arena);
                const item = scopePayload(entries, index, scope);
                if (comptime (interpreter.pathTail(path) != null)) {
                    const tail = comptime interpreter.pathTail(path).?;
                    return interpreter.valueOf(Leaf, valueOn(entry.Item, tail, item, ui.arena)) orelse unreachable;
                }
                return interpreter.valueOf(Leaf, item.*) orelse unreachable;
            }
            const Leaf = comptime BindingLeaf(node, entries, path, allow_arena);
            return interpreter.valueOf(Leaf, valueOn(ModelT, path, model, ui.arena)) orelse unreachable;
        }

        // ----------------------------------------------- path resolution

        /// Comptime mirror of the interpreter's `resolveOn`: the type a
        /// dotted path resolves to on T — struct fields, zero-arg methods,
        /// and (when `allow_arena`) arena-taking scalar methods — or null
        /// when the path names nothing `valueOf` can represent (which is
        /// exactly when the interpreter fails).
        fn OnType(comptime T: type, comptime path: []const u8, comptime allow_arena: bool) ?type {
            comptime {
                @setEvalBranchQuota(10_000);
                if (@typeInfo(T) != .@"struct") return null;
                const head = interpreter.pathHead(path);
                const tail_opt = interpreter.pathTail(path);
                for (@typeInfo(T).@"struct".fields) |field| {
                    if (!std.mem.eql(u8, field.name, head)) continue;
                    if (tail_opt) |tail| {
                        if (@typeInfo(field.type) != .@"struct") return null;
                        return OnType(field.type, tail, allow_arena);
                    }
                    if (!supportedValue(field.type)) return null;
                    return field.type;
                }
                for (@typeInfo(T).@"struct".decls) |decl| {
                    const DeclType = @TypeOf(@field(T, decl.name));
                    switch (@typeInfo(DeclType)) {
                        .@"fn" => |fn_info| {
                            if (fn_info.params.len == 1 and fn_info.return_type != null and fn_info.params[0].type == *const T) {
                                if (std.mem.eql(u8, decl.name, head) and tail_opt == null) {
                                    if (!supportedValue(fn_info.return_type.?)) return null;
                                    return fn_info.return_type.?;
                                }
                            }
                            if (allow_arena and interpreter.isArenaScalarFn(T, DeclType)) {
                                if (std.mem.eql(u8, decl.name, head) and tail_opt == null) {
                                    if (!supportedValue(fn_info.return_type.?)) return null;
                                    return fn_info.return_type.?;
                                }
                            }
                        },
                        else => {},
                    }
                }
                return null;
            }
        }

        /// Direct access for a path `OnType` resolved: field chains compile
        /// to member access, method leaves to a direct call (arena-taking
        /// leaves receive the build arena).
        fn valueOn(comptime T: type, comptime path: []const u8, ptr: *const T, arena: std.mem.Allocator) (OnType(T, path, true).?) {
            const head = comptime interpreter.pathHead(path);
            if (comptime (interpreter.pathTail(path) != null)) {
                const tail = comptime interpreter.pathTail(path).?;
                return valueOn(@FieldType(T, head), tail, &@field(ptr, head), arena);
            }
            if (comptime hasField(T, head)) return @field(ptr, head);
            if (comptime interpreter.isArenaScalarFn(T, @TypeOf(@field(T, head)))) {
                return @field(T, head)(ptr, arena);
            }
            return @field(T, head)(ptr);
        }

        fn hasField(comptime T: type, comptime name: []const u8) bool {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(T).@"struct".fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) return true;
                }
                return false;
            }
        }

        // --------------------------------------------------------- text

        const TextSegment = union(enum) {
            literal: []const u8,
            binding: []const u8,
        };

        fn textSegments(comptime node: markup.MarkupNode, comptime text: []const u8) []const TextSegment {
            comptime {
                @setEvalBranchQuota(comptime_text_quota_base + text.len * comptime_text_quota_per_byte);
                var segments: []const TextSegment = &.{};
                var rest = text;
                while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
                    segments = segments ++ &[_]TextSegment{.{ .literal = rest[0..open] }};
                    const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse fail(node, "unterminated interpolation");
                    segments = segments ++ &[_]TextSegment{.{ .binding = std.mem.trim(u8, rest[open + 1 .. close], " ") }};
                    rest = rest[close + 1 ..];
                }
                segments = segments ++ &[_]TextSegment{.{ .literal = rest }};
                return segments;
            }
        }

        const comptime_text_quota_base = 2_000;
        const comptime_text_quota_per_byte = 100;

        fn interpolatedText(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) []const u8 {
            const text = comptime blk: {
                if (node.children.len > 1) fail(node, "text elements take a single run of text");
                var content: []const u8 = "";
                for (node.children) |child| {
                    if (child.kind != .text) fail(node, "text elements may only contain text");
                    content = child.text;
                }
                break :blk content;
            };
            if (comptime (std.mem.indexOfScalar(u8, text, '{') == null)) return text;

            var out: std.ArrayListUnmanaged(u8) = .empty;
            const segments = comptime textSegments(node, text);
            inline for (0..segments.len) |index| {
                const segment = comptime segments[index];
                if (comptime (segment == .literal)) {
                    out.appendSlice(ui.arena, comptime segment.literal) catch return runtimeFail([]const u8, ui);
                } else {
                    const value = bindingValue(node, entries, comptime segment.binding, ui, model, scope, true);
                    interpreter.appendValue(&out, ui.arena, value) catch return runtimeFail([]const u8, ui);
                }
            }
            return out.items;
        }

        // ------------------------------------------------------- values

        const ValueVariant = enum { string, integer, float, boolean };

        /// Types `valueOf` can represent, mirroring the interpreter's
        /// runtime acceptance (unsupported types make it return null, which
        /// the interpreter reports as an unresolvable binding).
        fn supportedValue(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .bool, .int, .float, .comptime_int, .@"enum" => true,
                .pointer => |info| info.size == .slice and info.child == u8,
                .optional => |info| supportedValue(info.child),
                else => false,
            };
        }

        /// The `Value` variant a leaf type produces, or null for optionals
        /// (none resolves to boolean, some to the child's variant — only
        /// known at runtime).
        fn bindingVariant(comptime T: type) ?ValueVariant {
            return switch (@typeInfo(T)) {
                .bool => .boolean,
                .int, .comptime_int => .integer,
                .float => .float,
                .@"enum" => .string,
                .pointer => .string,
                .optional => null,
                else => null,
            };
        }

        fn requireVariant(comptime variant: ?ValueVariant, comptime allowed: []const ValueVariant, comptime node: markup.MarkupNode, comptime message: []const u8) void {
            comptime {
                const known = variant orelse return; // runtime-known: checked when the value flows
                for (allowed) |candidate| {
                    if (known == candidate) return;
                }
                fail(node, message);
            }
        }

        /// A runtime conversion the interpreter would fail the build on:
        /// latch `ui.failed` (finalize surfaces it) and produce an inert
        /// placeholder that never escapes the failed build.
        fn runtimeFail(comptime T: type, ui: *Ui) T {
            ui.failed = true;
            return zeroValue(T);
        }

        fn zeroValue(comptime T: type) T {
            return switch (comptime @typeInfo(T)) {
                .int, .float => 0,
                .bool => false,
                .@"enum" => |info| @field(T, info.fields[0].name),
                .pointer => "",
                else => comptime @compileError("no placeholder for " ++ @typeName(T)),
            };
        }

        // -------------------------------------------------- diagnostics

        fn fail(comptime node: markup.MarkupNode, comptime message: []const u8) noreturn {
            @compileError(std.fmt.comptimePrint("markup error at line {d}, column {d}: {s}", .{
                node.line,
                node.column,
                message,
            }));
        }
    };
}
