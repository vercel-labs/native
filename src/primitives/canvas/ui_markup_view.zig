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
const ui_provenance = @import("ui_provenance.zig");
const construction = @import("ui_markup_construction.zig");
const elements = @import("ui_markup_elements.zig");
const specialized = @import("ui_markup_specialized.zig");
const value_programs = @import("ui_markup_values.zig");
const runtime_programs = @import("ui_markup_runtime.zig");
const shape_programs = @import("ui_markup_shapes.zig");

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
            return .{ .document = try markup.canonicalize(arena, document) };
        }

        pub fn initDiagnostic(arena: std.mem.Allocator, source: []const u8, diagnostic: *markup.MarkupErrorInfo) (markup.ParseError || error{OutOfMemory})!Self {
            var parser = markup.Parser.init(arena, source);
            defer diagnostic.* = parser.diagnostic;
            const document = try parser.parse();
            return .{ .document = try markup.canonicalize(arena, document) };
        }

        /// Wrap an already-resolved document (the import resolver's
        /// output, or a parsed single-file document). Canonicalize it
        /// first (`markup.canonicalize`) so attribute expressions parse
        /// once instead of per frame; an uncanonicalized document builds
        /// identically through `attrTyped`'s fallback, just slower.
        pub fn fromDocument(document: markup.MarkupDocument) Self {
            return .{ .document = document };
        }

        /// Build the view for the current model. Compatible with the
        /// hand-written `view(ui, model)` shape.
        pub fn build(self: *Self, ui: *Ui, model: *const ModelT) BuildError!Ui.Node {
            if (ui.expression_policy) |owner| return self.buildOwned(owner, ui, model);
            return self.buildReference(ui, model);
        }

        fn buildReference(self: *Self, ui: *Ui, model: *const ModelT) BuildError!Ui.Node {
            if (self.document.imports.len > 0) {
                return self.failNode(self.document.imports[0], markup.import_unresolved_message);
            }
            const root = self.document.root orelse {
                self.diagnostic = .{ .line = 1, .column = 1, .message = markup.component_file_view_message };
                return error.MarkupBuild;
            };
            var scope = Scope{ .model = model, .arena = ui.arena, .expression_policy = ui.expression_policy };
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
            defaulted: bool = false,

            const Payload = union(enum) {
                item: struct { type_index: usize, ptr: *const anyopaque },
                slice: struct { type_index: usize, ptr: *const anyopaque, len: usize },
                value: Value,
                virtual: struct { options: Ui.VirtualListOptions, range: canvas.VirtualListRange, consumed: *bool },
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
            /// The use site's template chain: slot content is authored at
            /// the use site, so its provenance restores to the consumer's
            /// chain exactly like its scope does.
            chain: []const ui_provenance.UseSite = &.{},
        };

        const max_scope_depth = 16;

        const Scope = struct {
            model: *const ModelT,
            /// The build arena, threaded to arena-taking scalar binding fns
            /// (`pub fn summary(m: *const Model, arena: std.mem.Allocator)
            /// []const u8`). Strings they produce live exactly as long as
            /// the built tree.
            arena: std.mem.Allocator,
            expression_policy: ?markup.expr.Policy = null,
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
            /// Template instantiation chain for provenance stamping: the
            /// `<use>` sites (outermost first) that put the node currently
            /// building where it is. Arena-allocated snapshots — pushed by
            /// `buildUse`, restored by `<slot/>` content — so every
            /// stamped `NodeSource` shares one immutable slice.
            source_chain: []const ui_provenance.UseSite = &.{},

            fn lookup(self: *const Scope, head: []const u8) ?*const ScopeEntry {
                if (self.expression_policy) |owner| {
                    var request = construction.Request.init(4);
                    defer request.deinit();
                    request.words(&.{ self.len, self.floor });
                    request.blob(head);
                    for (self.entries[0..self.len]) |entry| request.blob(entry.name);
                    const found = request.decision(owner);
                    if (found.action != 7 or found.fields[0] > self.len) @panic("invalid construction lookup");
                    return if (found.fields[0] == 0) null else &self.entries[found.fields[0] - 1];
                }
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

            fn slotCaptureOwned(self: *const Scope, owner: markup.expr.Policy) ?SlotCapture {
                var request = value_programs.Request.init(32);
                defer request.deinit();
                request.words(&.{ self.len, self.floor });
                for (self.entries[0..self.len]) |entry| request.word(@intFromBool(entry.payload == .slot));
                const row = request.decision(owner);
                if (row.action != 87 or row.fields[0] > self.len) @panic("invalid lexical capture capability");
                return if (row.fields[0] == 0) null else self.entries[row.fields[0] - 1].payload.slot;
            }
        };

        fn resourceAttrOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr, comptime channel: u8) BuildError!void {
            const typed = markup.attrTypedWithPolicy(owner, attribute);
            var request = value_programs.Request.init(0);
            defer request.deinit();
            request.word(channel);
            request.blob(node.name);
            request.word(@intFromBool(typed == .binding));
            const admission = request.decision(owner);
            if (admission.action == 255) return self.failVoid(node, value_programs.message(admission.code));
            if (admission.action != 1) @panic("invalid resource admission");
            const value = try self.evalBinding(scope, node, typed.binding, true);
            const action = value_programs.decide(owner, 1, &.{ channel, value_programs.kind(value), @intFromBool(value == .integer and value.integer >= 0) });
            switch (action.action) {
                2 => if (channel == 2) {
                    options.pty = @intCast(value.integer);
                } else {
                    options.image = @intCast(value.integer);
                },
                3 => if (channel == 2) {
                    options.pty_name = value.string;
                } else unreachable,
                255 => return self.failVoid(node, value_programs.message(action.code)),
                else => @panic("invalid resource publication"),
            }
        }

        fn elementAdmissionOwned(self: *Self, owner: markup.expr.Policy, node: markup.MarkupNode, family: u8) BuildError!void {
            var request = value_programs.Request.init(2);
            defer request.deinit();
            request.word(family);
            request.blob(node.name);
            switch (family) {
                0 => request.names(&markup.known_icon_attr_element_names),
                1 => request.names(&markup.known_anchor_element_names),
                2 => {
                    comptime var count = 0;
                    inline for (markup.schema.elements) |entry| {
                        if (entry.rule_hook == null and entry.hit_target) count += 1;
                    }
                    request.word(count);
                    inline for (markup.schema.elements) |entry| {
                        if (comptime entry.rule_hook == null and entry.hit_target) request.blob(entry.name);
                    }
                },
                else => @panic("invalid element family"),
            }
            const action = request.decision(owner);
            if (action.action == 255) return self.failVoid(node, value_programs.message(action.code));
            if (action.action != 1) @panic("invalid value element admission");
        }

        fn applyButtonIconAttrOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            try self.elementAdmissionOwned(owner, node, 0);
            switch (value_programs.iconValue(owner, attribute.value, markup.button_icon_message)) {
                .builtin, .app => |name| options.icon = name,
                .binding => options.icon = try self.stringAttr(scope, node, attribute, markup.button_icon_message),
                .invalid => |message| return self.failVoid(node, message),
            }
        }

        fn applyAnchorOwned(self: *Self, owner: markup.expr.Policy, node: markup.MarkupNode, options: *Ui.ElementOptions, raw: []const u8, comptime kind: u8) BuildError!void {
            try self.elementAdmissionOwned(owner, node, 1);
            const admission = value_programs.decide(owner, 3, &.{ kind, 0, @intFromBool(node.attr("anchor") != null), 1 });
            if (admission.action == 255) return self.failVoid(node, value_programs.message(admission.code));
            if (admission.action != 1) @panic("invalid anchor admission");
            const T = if (kind == 0) canvas.WidgetAnchorPlacement else if (kind == 1) canvas.WidgetAnchorAlignment else f32;
            const converted: ?T = if (kind == 2) std.fmt.parseFloat(f32, raw) catch null else enumValueOwned(T, owner, raw);
            const action = value_programs.decide(owner, 3, &.{ kind, 1, 1, @intFromBool(converted != null) });
            if (action.action == 255) return self.failVoid(node, value_programs.message(action.code));
            if (action.action != 1) @panic("invalid anchor conversion");
            if (kind == 0) options.anchor = converted.? else if (kind == 1) options.anchor_alignment = converted.? else options.anchor_offset = converted.?;
        }

        fn applyQuietHoverAttrOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            try self.elementAdmissionOwned(owner, node, 2);
            options.style.quiet_hover = markup.expr.truthyWithPolicy(owner, try self.evalAttrExpression(scope, node, attribute));
        }

        fn setOptionFieldOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, comptime field: []const u8, attribute: markup.MarkupAttr) BuildError!void {
            const T = @TypeOf(@field(options, field));
            const optional = @typeInfo(T) == .optional;
            const Target = if (optional) @typeInfo(T).optional.child else T;
            const class = comptime if (optional and @typeInfo(Target) != .bool and @typeInfo(Target) != .@"enum" and @typeInfo(Target) != .float) 0 else value_programs.typeClass(Target);
            const value = try self.evalAttrExpression(scope, node, attribute);
            const within = if (comptime class == 4) value == .integer and value.integer >= 0 and value.integer <= std.math.maxInt(Target) else false;
            const action = value_programs.decide(owner, 4, &.{ class, value_programs.kind(value), @intFromBool(within) });
            if (action.action == 255) return self.failVoid(node, value_programs.message(action.code));
            if (action.action != class) @panic("invalid option conversion capability");
            switch (comptime class) {
                1 => @field(options, field) = switch (value) {
                    .float => |v| v,
                    .integer => |v| @floatFromInt(v),
                    else => unreachable,
                },
                2 => @field(options, field) = markup.expr.truthyWithPolicy(owner, value),
                3 => @field(options, field) = enumValueOwned(Target, owner, value.string) orelse return self.failVoid(node, value_programs.message(22)),
                4 => @field(options, field) = @intCast(value.integer),
                5 => @field(options, field) = value.string,
                else => unreachable,
            }
        }

        fn constructMessageOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, expression: markup.MessageExpression, comptime drag: bool) BuildError!MsgT {
            @setEvalBranchQuota(scan_quota);
            var request = value_programs.Request.init(6);
            defer request.deinit();
            request.word(@intFromBool(drag));
            request.blob(expression.tag);
            request.word(@intFromBool(expression.payload.len != 0));
            const fields = @typeInfo(MsgT).@"union".fields;
            request.word(fields.len);
            inline for (fields) |field| request.blob(field.name);
            inline for (fields) |field| request.word(if (field.type == void) 0 else if (comptime reflect.declaredWidgetDragDropRecord(field.type)) 2 else 1);
            const action = request.decision(owner);
            if (action.action == 255) return self.failMsg(node, value_programs.message(action.code));
            inline for (fields, 0..) |field, i| if (action.fields[0] == i) {
                if (comptime drag) {
                    if (comptime reflect.declaredWidgetDragDropRecord(field.type)) {
                        if (action.action != 42) @panic("invalid drag capability");
                        const value = try self.evalBinding(scope, node, expression.payload, true);
                        var payload = std.mem.zeroes(field.type);
                        payload.sourceId = try self.coerce(scope, @FieldType(field.type, "sourceId"), node, value);
                        return @unionInit(MsgT, field.name, payload);
                    }
                } else if (comptime field.type == void) {
                    if (action.action != 40) @panic("invalid void message capability");
                    return @unionInit(MsgT, field.name, {});
                } else {
                    if (action.action != 41) @panic("invalid payload message capability");
                    const value = try self.evalBinding(scope, node, expression.payload, true);
                    return @unionInit(MsgT, field.name, try self.coerce(scope, field.type, node, value));
                }
                @panic("invalid typed message selection");
            };
            @panic("invalid message field index");
        }

        fn coerceOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, comptime T: type, node: markup.MarkupNode, value: Value) BuildError!T {
            _ = scope;
            const class = comptime value_programs.typeClass(T);
            const within = if (comptime class == 4) value == .integer and value.integer >= std.math.minInt(T) and value.integer <= std.math.maxInt(T) else false;
            const action = value_programs.decide(owner, 5, &.{ class, value_programs.kind(value), @intFromBool(within) });
            if (action.action == 255) return self.failCoerce(T, node);
            if (action.action != class) @panic("invalid payload conversion capability");
            return switch (comptime class) {
                1 => switch (value) {
                    .float => |v| @floatCast(v),
                    .integer => |v| @floatFromInt(v),
                    else => unreachable,
                },
                2 => markup.expr.truthyWithPolicy(owner, value),
                3 => enumValueOwned(T, owner, value.string) orelse self.failCoerce(T, node),
                4 => @intCast(value.integer),
                5 => value.string,
                else => unreachable,
            };
        }

        fn callbackClass(comptime T: type, comptime family: u8) usize {
            return switch (family) {
                0 => if (T == canvas.TextInputEvent) 1 else if (reflect.declaredTextInputUnion(T)) 2 else 0,
                1 => if (T == canvas.ScrollState) 1 else if (reflect.declaredScrollStateRecord(T)) 2 else 0,
                2 => if (T == canvas.TerminalState) 1 else if (reflect.declaredTerminalStateRecord(T)) 2 else 0,
                3 => if (reflect.declaredLegacyScrollStateRecord(T)) 1 else 0,
                4 => if (T == f32) 1 else if (T == f64) 2 else 0,
                5 => if (reflect.valueArmClass(T)) |class| if (class == .identity) 1 else 2 else 0,
                else => unreachable,
            };
        }

        fn callbackSelection(owner: markup.expr.Policy, tag: []const u8, comptime family: u8) elements.Record {
            @setEvalBranchQuota(scan_quota);
            var request = value_programs.Request.init(7);
            defer request.deinit();
            request.blob(tag);
            const fields = @typeInfo(MsgT).@"union".fields;
            request.word(fields.len);
            inline for (fields) |field| request.blob(field.name);
            inline for (fields) |field| request.word(comptime callbackClass(field.type, family));
            return request.decision(owner);
        }

        fn evalAttributeExpressionOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr, attribute_aware: bool) BuildError!Value {
            const typed = markup.attrTypedWithPolicy(owner, attribute);
            const kind: usize = switch (typed) {
                .literal => 0,
                .binding => 1,
                .equals => 2,
                .expression => 3,
                .message => 4,
                .invalid => 5,
            };
            var request = value_programs.Request.init(8);
            defer request.deinit();
            request.words(&.{ kind, @intFromBool(attribute_aware) });
            var program = try request.program(owner);
            defer program.deinit();
            var left: Value = undefined;
            var right: Value = undefined;
            while (program.next()) |step| switch (step.action) {
                50 => return value_programs.literal(owner, typed.literal, attribute.name),
                51 => return value_programs.literal(owner, typed.literal, null),
                52 => return self.evalBinding(scope, node, typed.binding, true),
                53 => left = try self.evalBinding(scope, node, typed.equals.left, false),
                54 => right = try self.evalBinding(scope, node, typed.equals.right, false),
                55 => return .{ .boolean = markup.expr.equalWithPolicy(owner, left, right) },
                56 => return self.evalExpressionForm(scope, node, typed.expression),
                255 => return self.failValue(node, value_programs.message(step.code)),
                else => @panic("invalid attribute evaluation capability"),
            };
            @panic("attribute program did not return");
        }

        fn evalExpressionFormOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, form: markup.TypedExprRef) BuildError!Value {
            const action = value_programs.decide(owner, 9, &.{@intFromBool(form.tree != null)});
            return switch (action.action) {
                57 => self.evalParsedTree(scope, node, form.tree.?),
                58 => self.evalExpressionTree(scope, node, form.inner),
                else => @panic("invalid expression form capability"),
            };
        }

        fn evalParsedTreeOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, tree: *const markup.expr.ExprTree) BuildError!Value {
            var request = value_programs.Request.init(10);
            defer request.deinit();
            request.word(tree.len);
            for (tree.nodes[0..tree.len]) |entry| request.words(&.{ @intFromBool(entry.kind == .binding), @intFromBool(entry.comparison_operand) });
            var program = try request.program(owner);
            defer program.deinit();
            var resolved: [markup.expr.max_expression_nodes]Value = undefined;
            while (program.next()) |step| switch (step.action) {
                59 => resolved[step.fields[0]] = try self.evalBinding(scope, node, tree.nodes[step.fields[0]].text, step.fields[1] != 0),
                60 => return switch (try markup.expr.evalWithPolicy(owner, tree, &resolved, scope.arena)) {
                    .value => |value| value,
                    .fail => |message| self.failValue(node, message),
                },
                else => @panic("invalid binding evaluation capability"),
            };
            @panic("expression program did not return");
        }

        fn bindingResultOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, comptime T: type, ptr: *const T, path: []const u8, allow_arena: bool, domain: usize, head: []const u8) BuildError!Value {
            const value = resolveOnOwned(T, owner, ptr, path, if (allow_arena) scope.arena else null);
            var action = value_programs.decide(owner, 12, &.{ domain, 0, @intFromBool(value != null), @intFromBool(allow_arena) });
            if (action.action == 67) {
                const retry = resolveOnOwned(T, owner, ptr, path, scope.arena);
                action = value_programs.decide(owner, 12, &.{ domain, 1, @intFromBool(retry != null), @intFromBool(allow_arena) });
            }
            if (action.action == 75) {
                const buffer = if (comptime T == ModelT) fieldIsTextBuffer(ModelT, head) else false;
                action = value_programs.decide(owner, 12, &.{ domain, 2, @intFromBool(buffer), @intFromBool(allow_arena) });
            }
            return switch (action.action) {
                66 => value.?,
                255 => self.failValue(node, value_programs.message(action.code)),
                else => @panic("invalid binding result capability"),
            };
        }

        fn evalBindingOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, path: []const u8, allow_arena: bool) BuildError!Value {
            @setEvalBranchQuota(scan_quota);
            var request = value_programs.Request.init(11);
            defer request.deinit();
            request.blob(path);
            request.word(scope.floor);
            request.word(scope.len);
            for (scope.entries[0..scope.len]) |entry| request.blob(entry.name);
            for (scope.entries[0..scope.len]) |entry| request.word(@intFromEnum(std.meta.activeTag(entry.payload)));
            const action = request.decision(owner);
            switch (action.action) {
                61, 62 => {
                    const entry = scope.entries[action.fields[0]].payload.item;
                    inline for (item_types, 0..) |Item, index| if (entry.type_index == index) {
                        const ptr: *const Item = @ptrCast(@alignCast(entry.ptr));
                        if (action.action == 61) return self.bindingResultOwned(owner, scope, node, Item, ptr, path[action.fields[1]..], allow_arena, 0, "");
                        const value = valueOf(Item, ptr.*);
                        const result = value_programs.decide(owner, 12, &.{ 3, 0, @intFromBool(value != null), @intFromBool(allow_arena) });
                        return switch (result.action) {
                            66 => value.?,
                            255 => self.failValue(node, value_programs.message(result.code)),
                            else => @panic("invalid item value capability"),
                        };
                    };
                    unreachable;
                },
                63 => return scope.entries[action.fields[0]].payload.value,
                64 => {
                    const window = scope.entries[action.fields[0]].payload.virtual;
                    const value = resolveOnOwned(canvas.VirtualListRange, owner, &window.range, path[action.fields[1]..], null);
                    const result = value_programs.decide(owner, 12, &.{ 2, 0, @intFromBool(value != null), 1 });
                    return switch (result.action) {
                        66 => value.?,
                        255 => self.failValue(node, value_programs.message(result.code)),
                        else => @panic("invalid virtual value capability"),
                    };
                },
                65 => return self.bindingResultOwned(owner, scope, node, ModelT, scope.model, path, allow_arena, 1, path[0..action.fields[0]]),
                255 => return self.failValue(node, value_programs.message(action.code)),
                else => @panic("invalid scope binding capability"),
            }
        }

        fn inputConstructorOwned(owner: markup.expr.Policy, tag: []const u8) ?Ui.InputMsgFn {
            @setEvalBranchQuota(scan_quota);
            const action = callbackSelection(owner, tag, 0);
            if (action.action == 0) return null;
            if (action.action != 43) @panic("invalid callback selection");
            inline for (@typeInfo(MsgT).@"union".fields, 0..) |field, i| if (action.fields[0] == i) {
                const class = comptime callbackClass(field.type, 0);
                if (action.fields[1] != class) @panic("invalid callback class");
                if (comptime class == 1) return Ui.inputMsg(@field(std.meta.Tag(MsgT), field.name));
                if (comptime class == 2) return Ui.translatedInputMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                @panic("unavailable callback capability");
            };
            @panic("invalid callback field index");
        }
        fn scrollConstructorOwned(owner: markup.expr.Policy, tag: []const u8) ?Ui.ScrollMsgFn {
            @setEvalBranchQuota(scan_quota);
            const action = callbackSelection(owner, tag, 1);
            if (action.action == 0) return null;
            if (action.action != 43) @panic("invalid callback selection");
            inline for (@typeInfo(MsgT).@"union".fields, 0..) |field, i| if (action.fields[0] == i) {
                const class = comptime callbackClass(field.type, 1);
                if (action.fields[1] != class) @panic("invalid callback class");
                if (comptime class == 1) return Ui.scrollMsg(@field(std.meta.Tag(MsgT), field.name));
                if (comptime class == 2) return Ui.translatedScrollMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                @panic("unavailable callback capability");
            };
            @panic("invalid callback field index");
        }
        fn terminalConstructorOwned(owner: markup.expr.Policy, tag: []const u8) ?Ui.TerminalMsgFn {
            @setEvalBranchQuota(scan_quota);
            const action = callbackSelection(owner, tag, 2);
            if (action.action == 0) return null;
            if (action.action != 43) @panic("invalid callback selection");
            inline for (@typeInfo(MsgT).@"union".fields, 0..) |field, i| if (action.fields[0] == i) {
                const class = comptime callbackClass(field.type, 2);
                if (action.fields[1] != class) @panic("invalid callback class");
                if (comptime class == 1) return Ui.terminalMsg(@field(std.meta.Tag(MsgT), field.name));
                if (comptime class == 2) return Ui.translatedTerminalMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                @panic("unavailable callback capability");
            };
            @panic("invalid callback field index");
        }
        fn resizeConstructorOwned(owner: markup.expr.Policy, tag: []const u8) ?Ui.ValueMsgFn {
            @setEvalBranchQuota(scan_quota);
            const action = callbackSelection(owner, tag, 4);
            if (action.action == 0) return null;
            if (action.action != 43) @panic("invalid callback selection");
            inline for (@typeInfo(MsgT).@"union".fields, 0..) |field, i| if (action.fields[0] == i) {
                const class = comptime callbackClass(field.type, 4);
                if (action.fields[1] != class) @panic("invalid callback class");
                if (comptime class == 1) return Ui.valueMsg(@field(std.meta.Tag(MsgT), field.name));
                if (comptime class == 2) return Ui.translatedValueMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                @panic("unavailable callback capability");
            };
            @panic("invalid callback field index");
        }
        fn valueConstructorOwned(owner: markup.expr.Policy, tag: []const u8) ?Ui.ValueMsgFn {
            @setEvalBranchQuota(scan_quota);
            const action = callbackSelection(owner, tag, 5);
            if (action.action == 0) return null;
            if (action.action != 43) @panic("invalid callback selection");
            inline for (@typeInfo(MsgT).@"union".fields, 0..) |field, i| if (action.fields[0] == i) {
                const class = comptime callbackClass(field.type, 5);
                if (action.fields[1] != class) @panic("invalid callback class");
                if (comptime class == 1) return Ui.valueMsg(@field(std.meta.Tag(MsgT), field.name));
                if (comptime class == 2) return Ui.translatedValueMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                @panic("unavailable callback capability");
            };
            @panic("invalid callback field index");
        }
        fn legacyScrollTagOwned(owner: markup.expr.Policy, tag: []const u8) bool {
            const action = callbackSelection(owner, tag, 3);
            return switch (action.action) {
                0 => false,
                43 => true,
                else => @panic("invalid legacy callback selection"),
            };
        }

        fn iterateModelItemsOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, comptime Item: type, scope: *Scope, each: []const u8) BuildError!?[]const Item {
            @setEvalBranchQuota(scan_quota);
            _ = self;
            const fields = @typeInfo(ModelT).@"struct".fields;
            const decls = @typeInfo(ModelT).@"struct".decls;
            var request = runtime_programs.Request.init(0);
            defer request.deinit();
            request.blob(each);
            request.word(fields.len);
            inline for (fields) |field| request.blob(field.name);
            inline for (fields) |field| request.word(comptime @intFromBool(sliceElement(field.type) != null and sliceElement(field.type).? == Item));
            request.word(decls.len);
            inline for (decls) |decl| request.blob(decl.name);
            inline for (decls) |decl| request.word(comptime collectionDeclClass(@TypeOf(@field(ModelT, decl.name)), Item));
            const action = request.decision(owner);
            if (action.action == 0) return null;
            if (action.action == 1) {
                inline for (fields, 0..) |field, i| if (action.fields[0] == i) {
                    if (comptime sliceElement(field.type) != null and sliceElement(field.type).? == Item) return asSlice(Item, &@field(scope.model, field.name));
                    @panic("unavailable collection field");
                };
            } else if (action.action == 2) {
                inline for (decls, 0..) |decl, i| if (action.fields[0] == i) {
                    const class = comptime collectionDeclClass(@TypeOf(@field(ModelT, decl.name)), Item);
                    if (action.fields[1] != class) @panic("invalid collection callback class");
                    if (comptime class == 1) return asSlice(Item, &@field(ModelT, decl.name));
                    if (comptime class == 2) return @field(ModelT, decl.name)(scope.model);
                    if (comptime class == 3) return @field(ModelT, decl.name)(scope.model, ui.arena);
                    @panic("unavailable collection declaration");
                };
            }
            @panic("invalid collection capability");
        }

        fn collectionDeclClass(comptime Decl: type, comptime Item: type) usize {
            if (comptime sliceElement(Decl) != null and sliceElement(Decl).? == Item) return 1;
            if (comptime isItemFn(Decl, Item, false)) return 2;
            if (comptime isItemFn(Decl, Item, true)) return 3;
            return 0;
        }

        fn itemKeyOwned(self: *Self, owner: markup.expr.Policy, comptime Item: type, item: *const Item, node: markup.MarkupNode, field: []const u8) BuildError!canvas.UiKey {
            const value = resolveOnOwned(Item, owner, item, field, null);
            const action = runtime_programs.decide(owner, 1, &.{ @intFromBool(value != null), if (value) |v| value_programs.kind(v) else 0 });
            return switch (action.action) {
                1 => canvas.uiKey(@as(u64, @bitCast(value.?.integer))),
                2 => canvas.uiKey(value.?.string),
                255 => self.failKey(node, runtime_programs.message(action.code)),
                else => @panic("invalid item key capability"),
            };
        }

        fn applyImageSourceAttrsOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions) BuildError!void {
            var request = runtime_programs.Request.init(2);
            defer request.deinit();
            request.node(node, false);
            var program = try request.program(owner);
            defer program.deinit();
            while (program.next()) |action| switch (action.action) {
                // Preserve native result-location writes, including the optional
                // tag and fields initialized before a later expression fails.
                20 => options.image_src = .{
                    .x = try self.imageCoordinateOwned(&program, scope, node, 0),
                    .y = try self.imageCoordinateOwned(&program, scope, node, 1),
                    .width = try self.imageCoordinateOwned(&program, scope, node, 2),
                    .height = try self.imageCoordinateOwned(&program, scope, node, 3),
                },
                22 => {},
                255 => return self.failVoid(node, runtime_programs.message(action.code)),
                else => @panic("invalid image rectangle capability"),
            };
        }

        fn imageCoordinateOwned(self: *Self, program: *@import("ui_markup_elements.zig").Program, scope: *Scope, node: markup.MarkupNode, field: usize) BuildError!f32 {
            const action = program.next() orelse @panic("missing image coordinate");
            if (action.action != 21 or action.fields[1] != field) @panic("invalid image coordinate storage");
            return self.floatAttr(scope, node, node.attrs[action.fields[0]]);
        }

        fn stringAttrOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr, message: []const u8) BuildError![]const u8 {
            const value = try self.evalAttrExpression(scope, node, attribute);
            const action = runtime_programs.decide(owner, 3, &.{ 0, value_programs.kind(value) });
            return switch (action.action) {
                1 => value.string,
                255 => self.failValue(node, message),
                else => @panic("invalid text admission"),
            };
        }

        fn floatAttrOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!f32 {
            const value = try self.evalAttrExpression(scope, node, attribute);
            const action = runtime_programs.decide(owner, 3, &.{ 1, value_programs.kind(value) });
            return switch (action.action) {
                2 => value.float,
                3 => @floatFromInt(value.integer),
                255 => self.failValue(node, runtime_programs.message(action.code)),
                else => @panic("invalid number admission"),
            };
        }

        fn richConstructorSelection(owner: markup.expr.Policy, tag: []const u8, comptime details: bool) @import("ui_markup_elements.zig").Record {
            var request = runtime_programs.Request.init(4);
            defer request.deinit();
            request.blob(tag);
            const fields = @typeInfo(MsgT).@"union".fields;
            request.word(fields.len);
            inline for (fields) |field| request.blob(field.name);
            inline for (fields) |field| request.word(comptime @intFromBool(if (details) field.type == usize or field.type == i64 else field.type == []const u8));
            return request.decision(owner);
        }

        fn linkConstructorOwned(owner: markup.expr.Policy, tag: []const u8) ?Ui.LinkMsgFn {
            @setEvalBranchQuota(scan_quota);
            const action = richConstructorSelection(owner, tag, false);
            if (action.action == 0) return null;
            if (action.action != 1) @panic("invalid link constructor selection");
            inline for (@typeInfo(MsgT).@"union".fields, 0..) |field, i| if (action.fields[0] == i) {
                if (comptime field.type == []const u8) return Ui.linkMsg(@field(std.meta.Tag(MsgT), field.name));
                @panic("unavailable link constructor");
            };
            @panic("invalid link constructor index");
        }

        fn detailsConstructorOwned(owner: markup.expr.Policy, tag: []const u8) ?*const fn (index: usize) MsgT {
            @setEvalBranchQuota(scan_quota);
            const action = richConstructorSelection(owner, tag, true);
            if (action.action == 0) return null;
            if (action.action != 1) @panic("invalid details constructor selection");
            inline for (@typeInfo(MsgT).@"union".fields, 0..) |field, i| if (action.fields[0] == i) {
                if (comptime field.type == usize or field.type == i64) return Md.detailsMsg(@field(std.meta.Tag(MsgT), field.name));
                @panic("unavailable details constructor");
            };
            @panic("invalid details constructor index");
        }

        fn interpolatedTextOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError![]const u8 {
            var request = runtime_programs.Request.init(5);
            defer request.deinit();
            request.node(node, true);
            const action = request.decision(owner);
            return switch (action.action) {
                10 => "",
                11 => self.runText(ui, scope, node, node.children[0]),
                255 => self.failText(if (action.fields[0] == 0) node else node.children[action.fields[0] - 1], runtime_programs.message(action.code)),
                else => @panic("invalid text run admission"),
            };
        }

        fn runTextOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode, run: markup.MarkupNode) BuildError![]const u8 {
            var request = runtime_programs.Request.init(6);
            defer request.deinit();
            request.blob(run.text);
            request.word(@intFromBool(run.typed_text != null));
            request.word(if (run.typed_text) |segments| segments.len else 0);
            if (run.typed_text) |segments| for (segments) |segment| request.word(switch (segment) {
                .literal => 0,
                .binding => 1,
                .expression => 2,
                .unterminated => 3,
            });
            var program = try request.program(owner);
            defer program.deinit();
            var out: std.ArrayListUnmanaged(u8) = .empty;
            while (program.next()) |action| switch (action.action) {
                40 => return run.text,
                41 => try out.appendSlice(ui.arena, run.typed_text.?[action.fields[0]].literal),
                42 => try markup.expr.appendValueWithPolicy(scope.expression_policy, &out, ui.arena, try self.evalBinding(scope, node, run.typed_text.?[action.fields[0]].binding, true)),
                43 => try markup.expr.appendValueWithPolicy(scope.expression_policy, &out, ui.arena, try self.evalExpressionForm(scope, node, run.typed_text.?[action.fields[0]].expression)),
                44 => try out.appendSlice(ui.arena, run.text[action.fields[0]..action.fields[1]]),
                45 => try markup.expr.appendValueWithPolicy(scope.expression_policy, &out, ui.arena, try self.evalBinding(scope, node, run.text[action.fields[0]..action.fields[1]], true)),
                46 => try markup.expr.appendValueWithPolicy(scope.expression_policy, &out, ui.arena, try self.evalExpressionTree(scope, node, run.text[action.fields[0]..action.fields[1]])),
                255 => return self.failText(node, runtime_programs.message(action.code)),
                else => @panic("invalid text interpolation capability"),
            };
            return out.items;
        }

        fn collectionProgram(owner: markup.expr.Policy, comptime channel: u8) error{OutOfMemory}!@import("ui_markup_elements.zig").Program {
            var request = runtime_programs.Request.init(7);
            defer request.deinit();
            request.words(&.{ channel, item_types.len });
            inline for (item_types) |Item| request.word(comptime collectionItemClass(Item));
            return request.program(owner);
        }

        fn collectionItemClass(comptime Item: type) usize {
            if (Item == f32) return 1;
            if (Item == f64) return 2;
            if (Item == []const u8) return 3;
            if (Item == bool) return 4;
            if (reflect.isMarkdownImageItem(Item)) return 5;
            return 0;
        }

        fn f32ItemsOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8) BuildError![]const f32 {
            @setEvalBranchQuota(scan_quota);
            var program = try collectionProgram(owner, 0);
            defer program.deinit();
            while (program.next()) |action| switch (action.action) {
                30 => inline for (item_types, 0..) |Item, i| {
                    if (comptime Item == f32 or Item == f64) {
                        if (action.fields[0] == i) {
                            if (action.fields[1] != comptime collectionItemClass(Item)) @panic("invalid collection item class");
                            if (try self.iterateItems(ui, Item, i, scope, path)) |items| {
                                if (comptime Item == f32) return items;
                                const narrowed = ui.arena.alloc(f32, items.len) catch return self.failText(node, markup.series_values_message);
                                for (narrowed, items) |*slot, value| slot.* = @floatCast(value);
                                return narrowed;
                            }
                        }
                    }
                },
                31 => return self.failText(node, markup.series_values_message),
                else => @panic("invalid collection selection capability"),
            };
            @panic("missing collection terminal");
        }

        fn stringItemsOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8, message: []const u8) BuildError![]const []const u8 {
            @setEvalBranchQuota(scan_quota);
            var program = try collectionProgram(owner, 1);
            defer program.deinit();
            while (program.next()) |action| switch (action.action) {
                30 => inline for (item_types, 0..) |Item, i| {
                    if (comptime Item == []const u8) {
                        if (action.fields[0] == i) {
                            if (action.fields[1] != comptime collectionItemClass(Item)) @panic("invalid collection item class");
                            if (try self.iterateItems(ui, Item, i, scope, path)) |items| {
                                return items;
                            }
                        }
                    }
                },
                31 => return self.failText(node, message),
                else => @panic("invalid collection selection capability"),
            };
            @panic("missing collection terminal");
        }

        fn boolItemsOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8) BuildError![]const bool {
            @setEvalBranchQuota(scan_quota);
            var program = try collectionProgram(owner, 2);
            defer program.deinit();
            while (program.next()) |action| switch (action.action) {
                30 => inline for (item_types, 0..) |Item, i| {
                    if (comptime Item == bool) {
                        if (action.fields[0] == i) {
                            if (action.fields[1] != comptime collectionItemClass(Item)) @panic("invalid collection item class");
                            if (try self.iterateItems(ui, Item, i, scope, path)) |items| {
                                return items;
                            }
                        }
                    }
                },
                31 => return self.failText(node, markup.markdown_details_expanded_message),
                else => @panic("invalid collection selection capability"),
            };
            @panic("missing collection terminal");
        }

        fn markdownImageItemsOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8) BuildError![]const canvas.markdown.ResolvedImage {
            @setEvalBranchQuota(scan_quota);
            var program = try collectionProgram(owner, 3);
            defer program.deinit();
            while (program.next()) |action| switch (action.action) {
                30 => inline for (item_types, 0..) |Item, i| {
                    if (comptime reflect.isMarkdownImageItem(Item)) {
                        if (action.fields[0] == i) {
                            if (action.fields[1] != comptime collectionItemClass(Item)) @panic("invalid collection item class");
                            if (try self.iterateItems(ui, Item, i, scope, path)) |items| {
                                return @import("markdown_image_binding.zig").convert(ui.arena, items) catch return self.failText(node, markup.markdown_images_message);
                            }
                        }
                    }
                },
                31 => return self.failText(node, markup.markdown_images_message),
                else => @panic("invalid collection selection capability"),
            };
            @panic("missing collection terminal");
        }

        fn buildOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, model: *const ModelT) BuildError!Ui.Node {
            const action = construction.decide(owner, 0, &.{ self.document.imports.len, @intFromBool(self.document.root != null) });
            if (action.action == 255) {
                if (action.code == 1) return self.failNode(self.document.imports[0], construction.message(action.code));
                if (action.code != 2) @panic("invalid root admission");
                self.diagnostic = .{ .line = 1, .column = 1, .message = construction.message(action.code) };
                return error.MarkupBuild;
            }
            if (action.action != 0) @panic("invalid root action");
            var scope = Scope{ .model = model, .arena = ui.arena, .expression_policy = owner };
            return self.buildNode(ui, &scope, self.document.root.?);
        }
        fn buildNodeOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            const action = construction.decide(owner, 1, &.{@intFromEnum(node.kind)});
            return switch (action.action) {
                1 => self.buildElement(ui, scope, node),
                2 => self.buildUse(ui, scope, node),
                255 => self.failNode(node, construction.message(action.code)),
                else => @panic("invalid node construction action"),
            };
        }
        fn buildChildListOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, children: []const markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
            var index: usize = 0;
            while (index < children.len) : (index += 1) {
                const child = children[index];
                const next: usize = if (index + 1 < children.len) @intFromEnum(children[index + 1].kind) else 9;
                const action = construction.decide(owner, 2, &.{ @intFromEnum(child.kind), next, @intFromBool(child.attrEntry("test") != null) });
                switch (action.action) {
                    1 => try out.append(ui.arena, try self.buildElement(ui, scope, child)),
                    2 => try out.append(ui.arena, try self.buildUse(ui, scope, child)),
                    3 => try self.buildSlot(ui, scope, child, out),
                    4 => {
                        const else_index = index + 1;
                        index += action.fields[0];
                        const count = try self.buildFor(ui, scope, child, out);
                        const branch = construction.decide(owner, 3, &.{ @intFromEnum(child.kind), action.fields[0], count });
                        if (branch.action == 6) try self.buildChildren(ui, scope, children[else_index], out) else if (branch.action != 0) @panic("invalid loop branch action");
                    },
                    5 => {
                        const condition = try self.evalAttrExpression(scope, child, child.attrEntry("test").?);
                        const branch = construction.decide(owner, 3, &.{ @intFromEnum(child.kind), @intFromBool(next == @intFromEnum(markup.MarkupNodeKind.else_block)), @intFromBool(markup.expr.truthyWithPolicy(owner, condition)) });
                        if (branch.action == 6) try self.buildChildren(ui, scope, children[index + branch.fields[0]], out) else if (branch.action != 0) @panic("invalid condition branch action");
                        index += branch.fields[1];
                    },
                    255 => return self.failVoid(child, construction.message(action.code)),
                    else => @panic("invalid child construction action"),
                }
            }
        }
        fn buildSlotOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
            var request = construction.Request.init(5);
            defer request.deinit();
            request.words(&.{ node.attrs.len, node.children.len, if (scope.template_ctx) |ctx| ctx + 1 else 0, scope.len, scope.floor });
            for (scope.entries[0..scope.len]) |entry| request.words(&.{ @intFromEnum(std.meta.activeTag(entry.payload)), if (entry.payload == .slot) entry.payload.slot.nodes.len else 0 });
            const action = request.decision(owner);
            if (action.action == 255) return self.failVoid(if (action.code == 24) node.children[0] else node, construction.message(action.code));
            if (action.action != 8 or action.fields[0] > scope.len) @panic("invalid slot action");
            if (action.fields[0] == 0) return;
            const capture = scope.entries[action.fields[0] - 1].payload.slot;
            const saved_len = scope.len;
            const saved_floor = scope.floor;
            const saved_ctx = scope.template_ctx;
            const saved_chain = scope.source_chain;
            var saved_entries: [max_scope_depth]ScopeEntry = undefined;
            @memcpy(saved_entries[0 .. saved_len - capture.len], scope.entries[capture.len..saved_len]);
            scope.len = capture.len;
            scope.floor = capture.floor;
            scope.template_ctx = capture.template_ctx;
            scope.source_chain = capture.chain;
            defer {
                @memcpy(scope.entries[capture.len..saved_len], saved_entries[0 .. saved_len - capture.len]);
                scope.len = saved_len;
                scope.floor = saved_floor;
                scope.template_ctx = saved_ctx;
                scope.source_chain = saved_chain;
            }
            try self.buildChildList(ui, scope, capture.nodes, out);
        }
        fn buildForOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!usize {
            @setEvalBranchQuota(scan_quota);
            var request = construction.Request.init(6);
            defer request.deinit();
            request.words(&.{ @intFromBool(node.attr("each") != null), @intFromBool(node.attr("as") != null), scope.len, node.children.len });
            for (node.children) |child| request.word(@intFromEnum(child.kind));
            const admission = request.decision(owner);
            if (admission.action == 255) return self.failVoid(if (admission.fields[0] == 0) node else node.children[admission.fields[0] - 1], construction.message(admission.code));
            if (admission.action != 0) @panic("invalid loop admission");
            var cursor: usize = 0;
            while (true) {
                const action = construction.decide(owner, 7, &.{ 0, cursor, item_types.len, 0 });
                if (action.action == 255) return self.failVoid(node, construction.message(action.code));
                if (action.action != 9 or action.fields[0] >= item_types.len) @panic("invalid iterable capability");
                cursor = action.fields[1];
                inline for (item_types, 0..) |Item, type_index| {
                    if (action.fields[0] == type_index) {
                        if (try self.iterateItems(ui, Item, type_index, scope, node.attr("each").?)) |items| {
                            try self.buildItemsOwned(owner, ui, Item, type_index, scope, node, items, out);
                            return items.len;
                        }
                    }
                }
            }
        }
        fn buildItemsOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, comptime Item: type, comptime type_index: usize, scope: *Scope, node: markup.MarkupNode, items: []const Item, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
            var cursor: usize = 0;
            while (true) {
                const action = construction.decide(owner, 7, &.{ 1, cursor, items.len, scope.len });
                if (action.action == 0) return;
                if (action.action != 9 or action.fields[0] >= items.len) @panic("invalid item capability");
                cursor = action.fields[1];
                const item = &items[action.fields[0]];
                scope.entries[scope.len] = .{ .name = node.attr("as").?, .payload = .{ .item = .{ .type_index = type_index, .ptr = @ptrCast(item) } } };
                scope.len = action.fields[2];
                // Pop only this iteration's entry. An early nested template
                // failure can leave published scope entries in the reference.
                defer scope.len -= action.fields[2] - action.fields[3];
                const first_emitted = out.items.len;
                try self.buildChildren(ui, scope, node, out);
                const after = construction.decide(owner, 7, &.{ 3, 0, 0, @intFromBool(node.attr("key") != null) });
                if (after.action == 14) {
                    const base = try self.itemKeyOwned(owner, Item, item, node, node.attr("key").?);
                    var slot: usize = 0;
                    const emitted = out.items[first_emitted..];
                    while (slot < emitted.len) {
                        const built = &emitted[slot];
                        const stamp = construction.decide(owner, 7, &.{ 2, slot, emitted.len, @intFromBool(built.key != null or built.global_key != null) });
                        if (stamp.action == 10) built.key = try canvas.forSlotKey(ui.arena, base, stamp.fields[0]) else if (stamp.action != 9) @panic("invalid key stamping capability");
                        slot = stamp.fields[1];
                    }
                } else if (after.action != 0) @panic("invalid post-body capability");
            }
        }
        fn iterateItemsOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, comptime Item: type, comptime type_index: usize, scope: *Scope, each: []const u8) BuildError!?[]const Item {
            @setEvalBranchQuota(scan_quota);
            const entry = scope.lookup(each);
            const action = construction.decide(owner, 8, &.{ @intFromBool(entry != null), if (entry) |e| @intFromEnum(std.meta.activeTag(e.payload)) else 0, if (entry != null and entry.?.payload == .slice) entry.?.payload.slice.type_index else 0, type_index });
            switch (action.action) {
                0 => return null,
                11 => {
                    const slice = entry.?.payload.slice;
                    const ptr: [*]const Item = @ptrCast(@alignCast(slice.ptr));
                    return ptr[0..slice.len];
                },
                12 => return self.iterateModelItems(ui, Item, scope, each),
                else => @panic("invalid model iterable capability"),
            }
        }
        fn buildUseOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var lookup = construction.Request.init(10);
            defer lookup.deinit();
            const named = node.attr("template");
            lookup.words(&.{ scope.len, scope.floor, if (scope.template_ctx) |ctx| ctx + 1 else 0, scope.use_depth, @intFromBool(named != null) });
            lookup.blob(named orelse "");
            lookup.word(self.document.templates.len);
            for (self.document.templates) |definition| {
                const name = definition.attr("name");
                lookup.word(@intFromBool(name != null));
                lookup.blob(name orelse "");
            }
            const selected = lookup.decision(owner);
            if (selected.action == 255) return self.failNode(node, construction.message(selected.code));
            if (selected.action != 20 or selected.fields[0] >= self.document.templates.len) @panic("invalid template lookup capability");
            var request = construction.Request.init(12);
            defer request.deinit();
            request.words(&.{ scope.len, scope.floor, if (scope.template_ctx) |ctx| ctx + 1 else 0, scope.use_depth, selected.fields[0] });
            request.useSite(node);
            request.node(self.document.templates[selected.fields[0]], true);
            var program = try request.program(owner);
            defer program.deinit();
            const saved_len = scope.len;
            const saved_floor = scope.floor;
            const saved_ctx = scope.template_ctx;
            const saved_chain = scope.source_chain;
            var template_index: usize = 0;
            var args_bytes: []const u8 = "";
            var forwarded_press: ?MsgT = null;
            var entry_slot: usize = 0;
            var entry_name: []const u8 = "";
            var payload: ScopeEntry.Payload = undefined;
            while (program.next()) |action| {
                const f = action.fields;
                switch (action.action) {
                    20 => {
                        template_index = f[0];
                        args_bytes = if (f[1] == 0) "" else self.document.templates[template_index].attrs[f[1] - 1].value;
                    },
                    21 => {
                        var options: Ui.ElementOptions = .{};
                        try self.applyMessageAttr(scope, node, &options, node.attrs[f[0]]);
                        forwarded_press = options.on_press;
                    },
                    22 => {
                        entry_slot = f[0];
                        entry_name = args_bytes[f[1]..f[2]];
                    },
                    23 => payload = try self.argPayload(ui, scope, node, node.attrs[f[0]]),
                    24 => payload = .{ .value = value_programs.literal(owner, args_bytes[f[0]..f[1]], null) },
                    25 => scope.entries[entry_slot] = .{ .name = entry_name, .payload = payload, .defaulted = action.code == 1 },
                    26 => scope.entries[f[0]] = .{ .name = "", .payload = .{ .slot = .{ .nodes = node.children, .len = saved_len, .floor = saved_floor, .template_ctx = saved_ctx, .chain = saved_chain } } },
                    27 => {
                        scope.len = f[0];
                        scope.floor = f[1];
                        scope.template_ctx = f[2] - 1;
                        scope.use_depth = f[3];
                    },
                    28 => if (ui.provenance_sink != null) {
                        const chain = try ui.arena.alloc(ui_provenance.UseSite, saved_chain.len + 1);
                        @memcpy(chain[0..saved_chain.len], saved_chain);
                        chain[saved_chain.len] = .{ .src_path = node.src_path, .span = node.span, .line = node.line, .column = node.column };
                        scope.source_chain = chain;
                    },
                    29 => {
                        defer {
                            scope.len = saved_len;
                            scope.floor = saved_floor;
                            scope.use_depth -= 1;
                            scope.template_ctx = saved_ctx;
                            scope.source_chain = saved_chain;
                        }
                        if (program.next() != null) @panic("trailing template capability");
                        return self.buildElementForwardedPress(ui, scope, self.document.templates[template_index].children[0], forwarded_press);
                    },
                    255 => return self.failNode(request.nodes.items[f[0]], construction.message(action.code)),
                    else => @panic("invalid template construction action"),
                }
            }
            @panic("incomplete template program");
        }
        fn argPayloadOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!ScopeEntry.Payload {
            @setEvalBranchQuota(scan_quota);
            const typed = markup.attrTypedWithPolicy(owner, attribute);
            const path = if (typed == .binding) typed.binding else "";
            const parts = if (typed == .binding) value_programs.bindingPath(owner, path) else null;
            const entry = if (parts) |binding| scope.lookup(binding.head) else null;
            const action = construction.decide(owner, 9, &.{ if (typed == .invalid) 0 else if (typed == .binding) 1 else 2, @intFromBool(entry != null), if (entry) |e| @intFromEnum(std.meta.activeTag(e.payload)) else 0, @intFromBool(parts != null and parts.?.tail != null) });
            switch (action.action) {
                255 => return self.failPayload(node, construction.message(action.code)),
                11 => return entry.?.payload,
                12 => {
                    var cursor: usize = 0;
                    while (true) {
                        var request = construction.Request.init(11);
                        defer request.deinit();
                        request.words(&.{ cursor, item_types.len });
                        inline for (item_types) |Item| request.word(@intFromBool(Item == u8));
                        const next = request.decision(owner);
                        if (next.action == 0) break;
                        if (next.action != 9 or next.fields[0] >= item_types.len) @panic("invalid argument iterable capability");
                        cursor = next.fields[1];
                        inline for (item_types, 0..) |Item, type_index| {
                            if (comptime Item != u8) {
                                if (next.fields[0] == type_index) {
                                    if (try self.iterateItems(ui, Item, type_index, scope, path)) |items| return .{ .slice = .{ .type_index = type_index, .ptr = @ptrCast(items.ptr), .len = items.len } };
                                }
                            }
                        }
                    }
                },
                13 => {},
                else => @panic("invalid argument construction action"),
            }
            return .{ .value = try self.evalUnclassifiedExpression(scope, node, attribute) };
        }

        fn iterateModelItems(self: *Self, ui: *Ui, comptime Item: type, scope: *Scope, each: []const u8) BuildError!?[]const Item {
            if (scope.expression_policy) |owner| return self.iterateModelItemsOwned(owner, ui, Item, scope, each);
            return self.iterateModelItemsReference(ui, Item, scope, each);
        }

        fn iterateModelItemsReference(self: *Self, ui: *Ui, comptime Item: type, scope: *Scope, each: []const u8) BuildError!?[]const Item {
            @setEvalBranchQuota(scan_quota);
            _ = self;
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

        /// Direct capability witnesses for differential SDK tests only.
        pub const RuntimeTest = if (@import("builtin").is_test) struct {
            pub fn text(view: *Self, ui: *Ui, model: *const ModelT, run: markup.MarkupNode) BuildError![]const u8 {
                var scope = Scope{ .model = model, .arena = ui.arena, .expression_policy = ui.expression_policy };
                return view.runText(ui, &scope, run, run);
            }
            pub fn key(view: *Self, ui: *Ui, comptime Item: type, item: *const Item, field: []const u8) BuildError!canvas.UiKey {
                const node = view.document.root.?;
                if (ui.expression_policy) |owner| return view.itemKeyOwned(owner, Item, item, node, field);
                return view.itemKey(Item, item, node, field);
            }
            pub fn link(owner: ?markup.expr.Policy, tag: []const u8) ?Ui.LinkMsgFn {
                return if (owner) |policy| linkConstructorOwned(policy, tag) else linkConstructor(tag);
            }
            pub fn details(owner: ?markup.expr.Policy, tag: []const u8) ?*const fn (index: usize) MsgT {
                return if (owner) |policy| detailsConstructorOwned(policy, tag) else detailsConstructor(tag);
            }
        } else void;

        /// Initialized scope observation for SDK differential tests only.
        pub const ConstructionTest = if (@import("builtin").is_test) struct {
            pub const Result = struct { node: ?Ui.Node = null, failure: ?BuildError = null, scope: Scope };
            pub fn run(view: *Self, ui: *Ui, model: *const ModelT, length: usize, floor: usize, depth: usize, context: ?usize) Result {
                var scope = Scope{ .model = model, .arena = ui.arena, .expression_policy = ui.expression_policy, .len = length, .floor = floor, .use_depth = depth, .template_ctx = context };
                for (&scope.entries) |*entry| entry.* = .{ .name = "retained", .payload = .{ .value = .{ .boolean = true } } };
                const built = view.buildNode(ui, &scope, view.document.root.?);
                if (built) |node| return .{ .node = node, .scope = scope } else |err| return .{ .failure = err, .scope = scope };
            }
        } else void;

        /// Observe partial attribute state and failures without element linting.
        pub const ElementTest = if (@import("builtin").is_test) struct {
            pub const Result = struct { options: Ui.ElementOptions, failure: ?BuildError = null };
            pub fn run(view: *Self, ui: *Ui, model: *const ModelT, node: markup.MarkupNode, event_only: bool) Result {
                var scope = Scope{ .model = model, .arena = ui.arena, .expression_policy = ui.expression_policy };
                var options: Ui.ElementOptions = .{};
                const result = if (event_only) view.applyMessageAttr(&scope, node, &options, node.attrs[0]) else view.applyAttrs(&scope, node, &options);
                result catch |err| return .{ .options = options, .failure = err };
                return .{ .options = options };
            }
        } else void;

        /// Borrowed byte-path capabilities for SDK differential tests.
        pub const PostprocessingTest = if (@import("builtin").is_test) struct {
            pub const bindingPath = value_programs.bindingPath;
            pub const referenceHead = pathHead;
            pub const referenceTail = pathTail;
        } else struct {};

        /// Exact borrowed literals and initialized lexical captures for SDK tests.
        pub const LiteralTest = if (@import("builtin").is_test) struct {
            pub const literal = value_programs.literal;
            pub const reference = reflect.literalValue;
            pub const referenceAttribute = reflect.literalValueForAttribute;
            pub const Capture = SlotCapture;
            pub fn capture(owner: ?markup.expr.Policy, model: *const ModelT, captures: []const ?Capture, floor: usize) ?Capture {
                std.debug.assert(captures.len <= max_scope_depth and floor <= captures.len);
                var scope = Scope{ .model = model, .arena = std.testing.allocator, .expression_policy = owner, .len = captures.len, .floor = floor };
                for (captures, 0..) |captured, index| scope.entries[index] = .{
                    .name = "",
                    .payload = if (captured) |value| .{ .slot = value } else .{ .value = .{ .boolean = false } },
                };
                return if (owner) |policy| scope.slotCaptureOwned(policy) else scope.slotCapture();
            }
        } else struct {};

        /// Direct capability observation for metadata differential tests.
        pub const MetadataTest = if (@import("builtin").is_test) struct {
            pub const iconValue = value_programs.iconValue;
            pub const language = value_programs.language;
            pub const lineNumbers = value_programs.lineNumbers;
        } else struct {};

        /// Direct capability observation for option-admission differential tests.
        pub const OptionTest = if (@import("builtin").is_test) struct {
            pub const enumValue = enumValueOwned;
            pub const seriesKind = value_programs.seriesKind;
            pub const spanScale = value_programs.spanScale;
        } else struct {};

        /// Direct numeric option capabilities for differential SDK tests.
        pub const NumericTest = if (@import("builtin").is_test) struct {
            pub const integerOption = value_programs.integerOption;
            pub const virtualExtent = value_programs.virtualExtent;
            pub const virtualAnchor = value_programs.virtualAnchor;
            pub const virtualRange = value_programs.virtualRange;
            pub const virtualExtentRequired = value_programs.virtualExtentRequired;
            pub const virtualAttribute = value_programs.virtualAttribute;
        } else struct {};

        fn virtualCountAttrOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, name: []const u8) BuildError!usize {
            const attribute = node.attrEntry(name);
            const admission = value_programs.virtualAttribute(owner, 0, name, attribute != null);
            if (admission.action == 0) return admission.fields[0];
            if (admission.action != 1) @panic("invalid virtual count attribute capability");
            const value = try self.evalUnclassifiedExpression(scope, node, attribute.?);
            const result = value_programs.integerOption(owner, 0, value, 0);
            return switch (result.action) {
                1 => @intCast(value.integer),
                255 => self.failValue(node, value_programs.message(result.code)),
                else => @panic("invalid virtual count capability"),
            };
        }

        fn virtualExtentAttrOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, name: []const u8) BuildError!f32 {
            const attribute = node.attrEntry(name);
            const admission = value_programs.virtualAttribute(owner, 1, name, attribute != null);
            if (admission.action == 0) return @floatFromInt(admission.fields[0]);
            if (admission.action != 1) @panic("invalid virtual extent attribute capability");
            const value = try self.floatAttr(scope, node, attribute.?);
            if (!value_programs.virtualExtent(owner, value)) return self.failValue(node, value_programs.message(51));
            return value;
        }

        /// Initialized lexical payload observation for differential SDK tests.
        pub const ValueTest = if (@import("builtin").is_test) struct {
            pub const Result = struct { value: ?Value = null, failure: ?BuildError = null, length: usize, floor: usize };
            pub fn run(view: *Self, ui: *Ui, model: *const ModelT, path: []const u8, allow_arena: bool, mode: u8) Result {
                var scope = Scope{ .model = model, .arena = ui.arena, .expression_policy = ui.expression_policy };
                for (&scope.entries) |*entry| entry.* = .{ .name = "retained", .payload = .{ .value = .{ .boolean = false } } };
                if (mode != 0) {
                    scope.entries[0] = .{ .name = "arg", .payload = .{ .value = .{ .boolean = true } } };
                    scope.len = 1;
                }
                if (mode == 2) scope.entries[0].payload = .{ .slice = .{ .ptr = model, .type_index = 0, .len = 0 } };
                if (mode == 3) scope.entries[0].payload = .{ .virtual = .{ .range = .{}, .options = .{ .id = "test", .item_count = 0, .item_extent = 10 }, .consumed = &ui.failed } };
                if (mode == 4) scope.floor = scope.len;
                const result = view.evalBinding(&scope, view.document.root.?, path, allow_arena);
                if (result) |value| return .{ .value = value, .length = scope.len, .floor = scope.floor } else |err| return .{ .failure = err, .length = scope.len, .floor = scope.floor };
            }
        } else void;

        /// Complete specialized values and consumed/scope state for differential tests.
        pub const SpecializedTest = if (@import("builtin").is_test) struct {
            pub const Result = struct {
                node: ?Ui.Node = null,
                series: ?canvas.ChartSeries = null,
                span: ?canvas.TextSpan = null,
                failure: ?BuildError = null,
                consumed: bool = false,
                length: usize = 0,
                floor: usize = 0,
                context: ?usize = null,
            };
            pub fn run(view: *Self, ui: *Ui, model: *const ModelT, mode: u8) Result {
                var scope = Scope{ .model = model, .arena = ui.arena, .expression_policy = ui.expression_policy };
                var consumed = false;
                if (mode == 4) {
                    const options: Ui.VirtualListOptions = .{ .id = "test", .item_count = 2, .item_extent = 10, .viewport_fallback = 100 };
                    scope.entries[0] = .{ .name = "window", .payload = .{ .virtual = .{ .options = options, .range = ui.virtualWindow(options), .consumed = &consumed } } };
                    scope.len = 1;
                }
                var result: Result = .{};
                switch (mode) {
                    1 => result.span = view.buildSpan(ui, &scope, view.document.root.?) catch |err| blk: {
                        result.failure = err;
                        break :blk null;
                    },
                    2 => result.series = view.buildSeries(ui, &scope, view.document.root.?) catch |err| blk: {
                        result.failure = err;
                        break :blk null;
                    },
                    3 => result.node = view.buildSpanParagraph(ui, &scope, view.document.root.?, .{}) catch |err| blk: {
                        result.failure = err;
                        break :blk null;
                    },
                    4 => result.node = view.buildVirtualList(ui, &scope, view.document.root.?) catch |err| blk: {
                        result.failure = err;
                        break :blk null;
                    },
                    else => result.node = view.buildNode(ui, &scope, view.document.root.?) catch |err| blk: {
                        result.failure = err;
                        break :blk null;
                    },
                }
                result.consumed = consumed;
                result.length = scope.len;
                result.floor = scope.floor;
                result.context = scope.template_ctx;
                return result;
            }
        } else void;

        fn specializedFormOwned(self: *Self, owner: markup.expr.Policy, node: markup.MarkupNode, channel: u8, typed: markup.TypedAttrValue) BuildError!u8 {
            const row = value_programs.specializedForm(owner, channel, typed);
            if (row.action == 255) return self.failVoid(node, value_programs.message(row.code));
            return row.action;
        }

        fn specializedTextOwned(self: *Self, owner: markup.expr.Policy, node: markup.MarkupNode, channel: u8, value: Value) BuildError![]const u8 {
            const row = value_programs.specializedValue(owner, channel, value);
            return switch (row.action) {
                1 => value.string,
                255 => self.failVoid(node, value_programs.message(row.code)),
                else => @panic("invalid specialized text capability"),
            };
        }

        fn codeDiffSpecOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError![]const u8 {
            // Metadata uses raw grammar before evaluation, even with a typed cache.
            const parsed = markup.parseAttrExpressionWithPolicy(owner, attribute.value);
            const typed: markup.TypedAttrValue = if (parsed) |value| switch (value) {
                .literal => |text| .{ .literal = text },
                .binding => |path| .{ .binding = path },
                .equals => |sides| .{ .equals = .{ .left = sides.left, .right = sides.right } },
                .expression => |inner| .{ .expression = .{ .inner = inner } },
            } else .invalid;
            const admission = try self.specializedFormOwned(owner, node, 13, typed);
            return switch (admission) {
                1 => typed.literal,
                2 => self.specializedTextOwned(owner, node, 3, try self.evalAttrExpression(scope, node, attribute)),
                else => @panic("invalid code metadata capability"),
            };
        }

        fn presenceFlagOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!bool {
            const row = value_programs.decide(owner, 29, &.{attribute.value.len});
            return switch (row.action) {
                1 => true,
                2 => markup.expr.truthyWithPolicy(owner, try self.evalAttrExpression(scope, node, attribute)),
                else => @panic("invalid presence flag capability"),
            };
        }

        fn buildStepperStepsOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode, options: Ui.StepperOptions) BuildError!Ui.Node {
            var selection = value_programs.Request.init(30);
            defer selection.deinit();
            selection.words(&.{ 0, node.children.len });
            selection.blob(if (node.children.len > 0) @tagName(node.children[0].kind) else "");
            const selected = selection.decision(owner);
            const capture = switch (selected.action) {
                1 => null,
                2 => blk: {
                    const captured = scope.slotCaptureOwned(owner);
                    const admission = value_programs.decide(owner, 30, &.{ 1, @intFromBool(captured != null) });
                    if (admission.action == 255) return self.failNode(node.children[0], value_programs.message(admission.code));
                    if (admission.action != 1) @panic("invalid stepper capture capability");
                    break :blk captured;
                },
                else => @panic("invalid stepper selection capability"),
            };
            const step_nodes = if (capture) |captured| captured.nodes else node.children;
            const steps = try ui.arena.alloc(Ui.StepperStep, step_nodes.len);
            var saved_entries: [max_scope_depth]ScopeEntry = undefined;
            const saved_len = scope.len;
            const saved_floor = scope.floor;
            const saved_ctx = scope.template_ctx;
            if (capture) |captured| {
                for (scope.entries[captured.len..saved_len], 0..) |entry, offset| saved_entries[offset] = entry;
                scope.len = captured.len;
                scope.floor = captured.floor;
                scope.template_ctx = captured.template_ctx;
            }
            defer if (capture) |captured| {
                for (saved_entries[0 .. saved_len - captured.len], 0..) |entry, offset| scope.entries[captured.len + offset] = entry;
                scope.len = saved_len;
                scope.floor = saved_floor;
                scope.template_ctx = saved_ctx;
            };
            for (step_nodes, 0..) |child, index| {
                var request = specialized.Request.init(14);
                defer request.deinit();
                request.node(child, true);
                request.word(@intFromEnum(child.kind));
                var program = try request.program(owner);
                defer program.deinit();
                while (program.next()) |step| switch (step.action) {
                    101 => steps[index] = .{ .label = try self.interpolatedText(ui, scope, child) },
                    255 => return self.failNode(child, specialized.message(step.code)),
                    else => @panic("invalid step capability"),
                };
            }
            return ui.stepper(options, steps);
        }

        fn buildSpanParagraphOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode, options: Ui.ElementOptions) BuildError!Ui.Node {
            var request = specialized.Request.init(12);
            defer request.deinit();
            request.node(node, true);
            var program = try request.program(owner);
            defer program.deinit();
            var spans: []canvas.TextSpan = &.{};
            while (program.next()) |step| switch (step.action) {
                100 => spans = try ui.arena.alloc(canvas.TextSpan, node.children.len),
                101 => spans[step.fields[0]] = .{ .text = try self.runText(ui, scope, node, node.children[step.fields[0]]) },
                102 => spans[step.fields[0]] = try self.buildSpan(ui, scope, node.children[step.fields[0]]),
                200 => return ui.paragraph(options, spans),
                255 => return self.failNode(if (step.fields[0] == 0) node else node.children[step.fields[0] - 1], specialized.message(step.code)),
                else => @panic("invalid paragraph capability"),
            };
            @panic("paragraph program did not publish");
        }

        fn buildSpanOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!canvas.TextSpan {
            var request = specialized.Request.init(13);
            defer request.deinit();
            request.node(node, true);
            var program = try request.program(owner);
            defer program.deinit();
            var span = canvas.TextSpan{};
            while (program.next()) |step| {
                if (step.action == 100) {
                    if (shape_programs.shape(owner, node, 1)) |info| {
                        self.diagnostic = .{ .line = info.line, .column = info.column, .message = info.message, .path = info.path };
                        return error.MarkupBuild;
                    }
                    continue;
                }
                if (step.action == 101) {
                    span.text = try self.runText(ui, scope, node, node.children[0]);
                    continue;
                }
                if (step.action == 200) return span;
                const attribute = node.attrs[step.fields[0]];
                switch (step.action) {
                    1 => {
                        const text = try self.stringAttr(scope, node, attribute, markup.span_weight_value_message);
                        span.weight = enumValueOwned(canvas.TextSpanWeight, owner, text) orelse return self.failValue(node, markup.span_weight_value_message);
                    },
                    2 => {
                        const value = try self.evalAttrExpression(scope, node, attribute);
                        const admission = value_programs.specializedValue(owner, 4, value);
                        const multiplier = switch (admission.action) {
                            1 => value.float,
                            2 => @as(f32, @floatFromInt(value.integer)),
                            255 => return self.failValue(node, value_programs.message(admission.code)),
                            else => @panic("invalid span numeric capability"),
                        };
                        if (!value_programs.spanScale(owner, multiplier)) return self.failValue(node, markup.span_scale_value_message);
                        span.scale = multiplier;
                    },
                    3 => span.monospace = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute)),
                    4 => span.italic = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute)),
                    5 => span.underline = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute)),
                    6 => span.color = enumValueOwned(canvas.TextSpanColor, owner, attribute.value) orelse return self.failValue(node, markup.unknown_color_token_message),
                    else => @panic("invalid span capability"),
                }
            }
            @panic("span program did not publish");
        }

        fn buildVirtualWindowOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            @setEvalBranchQuota(scan_quota);
            var nested = false;
            for (scope.entries[scope.floor..scope.len]) |entry| {
                if (entry.payload == .virtual) nested = true;
            }
            const identity = node.attr("id") orelse "";
            const id = canvas.globalWidgetId(.scroll_view, .{ .str = identity });
            var duplicate = false;
            for (ui.virtualWindows()) |prior| {
                if (prior.id == id) duplicate = true;
            }
            var request = specialized.Request.init(0);
            defer request.deinit();
            request.node(node, true);
            request.words(&.{ @intFromBool(nested), @intFromBool(scope.len >= max_scope_depth), @intFromBool(ui.virtualWindows().len >= canvas.max_virtual_windows), @intFromBool(duplicate) });
            var program = try request.program(owner);
            defer program.deinit();
            var options: Ui.VirtualListOptions = .{ .id = identity, .item_count = 0, .item_extent = 0 };
            var consumed: *bool = undefined;
            var built: ?Ui.Node = null;
            const saved_len = scope.len;
            defer scope.len = saved_len;
            while (program.next()) |step| switch (step.action) {
                1 => options.item_count = try self.virtualCountAttrOwned(owner, scope, node, "item-count"),
                2 => options.item_extent = try self.virtualExtentAttrOwned(owner, scope, node, "item-extent"),
                3 => options.gap = try self.virtualExtentAttrOwned(owner, scope, node, "gap"),
                4 => options.overscan = try self.virtualCountAttrOwned(owner, scope, node, "overscan"),
                5 => options.viewport_fallback = try self.virtualExtentAttrOwned(owner, scope, node, "viewport-fallback"),
                6 => {
                    options.index_base = try self.virtualCountAttrOwned(owner, scope, node, "index-base");
                    options.anchor = value_programs.virtualAnchor(Ui.VirtualListAnchor, owner, node.attr("anchor") orelse "");
                },
                7 => {
                    const estimate = node.attr("extent-estimate").?;
                    if (comptime @hasDecl(ModelT, "virtualExtentHelper") and @hasDecl(ModelT, "virtualExtentEstimate")) {
                        const helper = ModelT.virtualExtentHelper(estimate) orelse return self.failNode(node, "extent-estimate requires a numeric index helper");
                        options.extent_estimate = ModelT.virtualExtentEstimate;
                        options.extent_context = @ptrFromInt(@as(usize, helper) + 1);
                    } else return self.failNode(node, "extent-estimate requires a stable compiled helper capability");
                },
                100 => {
                    if (value_programs.virtualRange(owner, options.index_base, options.item_count)) |message| return self.failNode(node, message);
                },
                101 => {
                    if (value_programs.virtualExtentRequired(owner, options.item_extent, options.extent_estimate != null)) |message| return self.failNode(node, message);
                },
                102 => {
                    consumed = try ui.arena.create(bool);
                    consumed.* = false;
                    scope.entries[scope.len] = .{ .name = node.attr("as").?, .payload = .{ .virtual = .{ .options = options, .range = ui.virtualWindow(options), .consumed = consumed } } };
                    scope.len += 1;
                },
                103 => built = try self.buildNode(ui, scope, node.children[0]),
                200 => {
                    if (specialized.check(owner, 17, &.{ 2, @intFromBool(consumed.*) })) |message| return self.failNode(node, message);
                    return built.?;
                },
                255 => return self.failNode(node, specialized.message(step.code)),
                else => @panic("invalid virtual window capability"),
            };
            @panic("virtual window program did not publish");
        }

        fn buildVirtualListOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            @setEvalBranchQuota(scan_quota);
            var request = specialized.Request.init(1);
            defer request.deinit();
            request.node(node, true);
            request.word(@intFromBool(scope.len >= max_scope_depth));
            var program = try request.program(owner);
            defer program.deinit();
            // Only the lookup capability may populate this borrowed scope entry.
            var window: ?*const ScopeEntry = null;
            while (program.next()) |step| switch (step.action) {
                100 => {
                    window = scope.lookup(node.attr("window").?);
                    const valid = window != null and window.?.payload == .virtual;
                    const consumed = if (valid) window.?.payload.virtual.consumed.* else false;
                    if (specialized.check(owner, 18, &.{ @intFromBool(valid), @intFromBool(consumed) })) |message| return self.failNode(node, message);
                    window.?.payload.virtual.consumed.* = true;
                },
                101 => {
                    const resolved = window.?.payload.virtual;
                    const each = node.attr("each").?;
                    const name = node.attr("as").?;
                    inline for (@typeInfo(ModelT).@"struct".decls) |decl| {
                        const Decl = @TypeOf(@field(ModelT, decl.name));
                        if (comptime reflect.isVirtualItemFn(ModelT, Decl)) {
                            if (std.mem.eql(u8, decl.name, each)) {
                                const info = @typeInfo(Decl).@"fn";
                                const Parameter = info.params[1].type.?;
                                const Range = reflect.Pointee(Parameter);
                                var range: Range = undefined;
                                inline for (@typeInfo(Range).@"struct".fields) |field| {
                                    const source = @field(resolved.range, field.name);
                                    @field(range, field.name) = switch (@typeInfo(field.type)) {
                                        .int => @intCast(source),
                                        .float => if (@typeInfo(@TypeOf(source)) == .int) @floatFromInt(source) else @floatCast(source),
                                        else => unreachable,
                                    };
                                }
                                const argument = if (Parameter == Range) range else &range;
                                const items = if (comptime info.params.len == 3) @field(ModelT, decl.name)(scope.model, argument, ui.arena) else @field(ModelT, decl.name)(scope.model, argument);
                                const Item = reflect.sliceElement(info.return_type.?).?;
                                const type_index = comptime blk: {
                                    for (item_types, 0..) |candidate, index| if (candidate == Item) break :blk index;
                                    unreachable;
                                };
                                var rows: std.ArrayListUnmanaged(Ui.Node) = .empty;
                                var row_request = specialized.Request.init(15);
                                defer row_request.deinit();
                                row_request.words(&.{ items.len, resolved.range.itemCount() });
                                var row_program = try row_request.program(owner);
                                defer row_program.deinit();
                                while (row_program.next()) |row_step| switch (row_step.action) {
                                    1 => {
                                        const item = &items[row_step.fields[0]];
                                        scope.entries[scope.len] = .{ .name = name, .payload = .{ .item = .{ .type_index = type_index, .ptr = @ptrCast(item) } } };
                                        scope.len += 1;
                                        const built = self.buildNode(ui, scope, node.children[0]);
                                        scope.len -= 1;
                                        const row = try built;
                                        if (specialized.check(owner, 19, &.{@intFromBool(row.key != null or row.global_key != null)})) |message| return self.failNode(node, message);
                                        try rows.append(ui.arena, row);
                                    },
                                    100 => return self.buildVirtualProxyOwned(owner, ui, scope, node, resolved.options, resolved.range, rows.items),
                                    200 => @panic("virtual proxy did not publish"),
                                    255 => return self.failNode(node, specialized.message(row_step.code)),
                                    else => @panic("invalid virtual row capability"),
                                };
                            }
                        }
                    }
                    return self.failNode(node, "virtual-list each requires a Model-first complete range query");
                },
                255 => return self.failNode(node, specialized.message(step.code)),
                else => @panic("invalid virtual list capability"),
            };
            @panic("virtual list program did not publish");
        }

        fn buildVirtualProxyOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode, original: Ui.VirtualListOptions, range: canvas.VirtualListRange, rows: []const Ui.Node) BuildError!Ui.Node {
            var request = specialized.Request.init(16);
            defer request.deinit();
            request.node(node, false);
            var program = try request.program(owner);
            defer program.deinit();
            var attributes: std.ArrayListUnmanaged(markup.MarkupAttr) = .empty;
            var element: Ui.ElementOptions = .{};
            while (program.next()) |step| switch (step.action) {
                1 => try attributes.append(ui.arena, node.attrs[step.fields[0]]),
                100 => {
                    var proxy = node;
                    proxy.name = "scroll";
                    proxy.attrs = attributes.items;
                    try self.applyAttrs(scope, proxy, &element);
                },
                200 => {
                    var options = original;
                    options.width = element.width;
                    options.height = element.height;
                    options.min_width = element.min_width;
                    options.grow = element.grow;
                    options.padding = element.padding orelse 0;
                    options.style_tokens = element.style_tokens;
                    options.semantics = element.semantics;
                    options.overscroll = element.overscroll;
                    options.on_scroll = element.on_scroll;
                    options.on_reach_end = element.on_reach_end;
                    options.on_reach_start = element.on_reach_start;
                    return ui.virtualList(options, range, .{rows});
                },
                else => @panic("invalid virtual proxy capability"),
            };
            @panic("virtual proxy program did not publish");
        }

        fn buildMarkdownOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Md.Options = .{};
            var source_text: ?[]const u8 = null;

            var request = specialized.Request.init(2);
            defer request.deinit();
            request.node(node, true);
            var program = try request.program(owner);
            defer program.deinit();

            while (program.next()) |step| switch (step.action) {
                1 => {
                    const attribute = node.attrs[step.fields[0]];
                    const typed = markup.attrTypedWithPolicy(owner, attribute);
                    _ = try self.specializedFormOwned(owner, node, 0, typed);
                    const value = try self.evalBinding(scope, node, typed.binding, true);
                    source_text = try self.specializedTextOwned(owner, node, 0, value);
                },
                2 => {
                    const attribute = node.attrs[step.fields[0]];
                    const typed = markup.attrTypedWithPolicy(owner, attribute);
                    _ = try self.specializedFormOwned(owner, node, 1, typed);
                    options.on_link = linkConstructorOwned(owner, typed.message.tag) orelse {
                        return self.failNode(node, markup.markdown_on_link_message);
                    };
                },
                3 => {
                    const attribute = node.attrs[step.fields[0]];
                    const typed = markup.attrTypedWithPolicy(owner, attribute);
                    _ = try self.specializedFormOwned(owner, node, 2, typed);
                    options.on_details = detailsConstructorOwned(owner, typed.message.tag) orelse {
                        return self.failNode(node, markup.markdown_on_details_message);
                    };
                },
                4 => {
                    const attribute = node.attrs[step.fields[0]];
                    const typed = markup.attrTypedWithPolicy(owner, attribute);
                    _ = try self.specializedFormOwned(owner, node, 3, typed);
                    options.details_expanded = try self.boolItems(ui, scope, node, typed.binding);
                },
                5 => {
                    const attribute = node.attrs[step.fields[0]];
                    const typed = markup.attrTypedWithPolicy(owner, attribute);
                    _ = try self.specializedFormOwned(owner, node, 4, typed);
                    options.images = try self.markdownImageItems(ui, scope, node, typed.binding);
                },
                6 => {
                    const attribute = node.attrs[step.fields[0]];
                    const typed = markup.attrTypedWithPolicy(owner, attribute);
                    _ = try self.specializedFormOwned(owner, node, 5, typed);
                    const value = try self.evalAttrExpression(scope, node, attribute);
                    const admission = value_programs.specializedValue(owner, 2, value);
                    switch (admission.action) {
                        0 => {},
                        1 => options.issue_link_base = value.string,
                        255 => return self.failNode(node, value_programs.message(admission.code)),
                        else => @panic("invalid issue link base capability"),
                    }
                },
                200 => return Md.view(ui, source_text.?, options),
                255 => return self.failNode(if (step.fields[0] == 0) node else node.children[step.fields[0] - 1], specialized.message(step.code)),
                else => @panic("invalid specialized builder capability"),
            };
            @panic("specialized program did not publish");
        }

        fn buildCodeOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.CodeOptions = .{};
            var source_text: ?[]const u8 = null;
            var added_lines_storage: [canvas.code.max_diff_lines]usize = undefined;
            var removed_lines_storage: [canvas.code.max_diff_lines]usize = undefined;

            var request = specialized.Request.init(3);
            defer request.deinit();
            request.node(node, true);
            var program = try request.program(owner);
            defer program.deinit();

            while (program.next()) |step| switch (step.action) {
                1 => {
                    const attribute = node.attrs[step.fields[0]];
                    const typed = markup.attrTypedWithPolicy(owner, attribute);
                    _ = try self.specializedFormOwned(owner, node, 6, typed);
                    source_text = try self.specializedTextOwned(owner, node, 1, try self.evalBinding(scope, node, typed.binding, true));
                },
                2 => {
                    const attribute = node.attrs[step.fields[0]];
                    const typed = markup.attrTypedWithPolicy(owner, attribute);
                    _ = try self.specializedFormOwned(owner, node, 7, typed);
                    options.language = value_programs.language(owner, typed.literal) orelse
                        return self.failNode(node, markup.code_language_message);
                },
                3 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.line_numbers = try self.presenceFlagOwned(owner, scope, node, attribute);
                },
                4 => {
                    const attribute = node.attrs[step.fields[0]];
                    const spec = try self.codeDiffSpecOwned(owner, scope, node, attribute);
                    options.added_lines = value_programs.lineNumbers(owner, spec, &added_lines_storage) orelse
                        return self.failNode(node, markup.code_diff_lines_message);
                },
                5 => {
                    const attribute = node.attrs[step.fields[0]];
                    const spec = try self.codeDiffSpecOwned(owner, scope, node, attribute);
                    options.removed_lines = value_programs.lineNumbers(owner, spec, &removed_lines_storage) orelse
                        return self.failNode(node, markup.code_diff_lines_message);
                },
                6 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.editable = try self.presenceFlagOwned(owner, scope, node, attribute);
                },
                7 => {
                    const attribute = node.attrs[step.fields[0]];
                    const typed = markup.attrTypedWithPolicy(owner, attribute);
                    _ = try self.specializedFormOwned(owner, node, 8, typed);
                    options.on_input = inputConstructorOwned(owner, typed.message.tag) orelse {
                        return self.failNode(node, "on-input tag must carry a TextInputEvent payload");
                    };
                },
                8 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.wrap = try self.presenceFlagOwned(owner, scope, node, attribute);
                },
                9 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.width = try self.floatAttr(scope, node, attribute);
                },
                10 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.height = try self.floatAttr(scope, node, attribute);
                },
                11 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.min_width = try self.floatAttr(scope, node, attribute);
                },
                12 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.grow = try self.floatAttr(scope, node, attribute);
                },
                13 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.key = try self.attrKey(scope, node, attribute);
                },
                14 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.global_key = try self.attrKey(scope, node, attribute);
                },
                15 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
                },
                200 => return ui.code(options, source_text.?),
                255 => return self.failNode(if (step.fields[0] == 0) node else node.children[step.fields[0] - 1], specialized.message(step.code)),
                else => @panic("invalid specialized builder capability"),
            };
            @panic("specialized program did not publish");
        }

        fn buildStepperOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.StepperOptions = .{};

            var request = specialized.Request.init(4);
            defer request.deinit();
            request.node(node, true);
            var program = try request.program(owner);
            defer program.deinit();

            while (program.next()) |step| switch (step.action) {
                1 => {
                    const attribute = node.attrs[step.fields[0]];
                    const value = try self.evalAttrExpression(scope, node, attribute);
                    const admission = value_programs.integerOption(owner, 1, value, 0);
                    options.active = switch (admission.action) {
                        1 => @intCast(value.integer),
                        2 => 0,
                        255 => return self.failNode(node, value_programs.message(admission.code)),
                        else => @panic("invalid stepper integer capability"),
                    };
                },
                2 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.key = try self.attrKey(scope, node, attribute);
                },
                3 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.global_key = try self.attrKey(scope, node, attribute);
                },
                4 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
                },
                100 => return self.buildStepperStepsOwned(owner, ui, scope, node, options),
                255 => return self.failNode(if (step.fields[0] == 0) node else node.children[step.fields[0] - 1], specialized.message(step.code)),
                else => @panic("invalid specialized builder capability"),
            };
            @panic("specialized program did not publish");
        }

        fn buildInputGroupOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.InputGroupOptions = .{};

            var request = specialized.Request.init(5);
            defer request.deinit();
            request.node(node, true);
            var program = try request.program(owner);
            defer program.deinit();
            var entry: ?Ui.Node = null;
            var actions: ?Ui.Node = null;
            while (program.next()) |step| switch (step.action) {
                1 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
                },
                2 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.width = try self.floatAttr(scope, node, attribute);
                },
                3 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.height = try self.floatAttr(scope, node, attribute);
                },
                4 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.min_width = try self.floatAttr(scope, node, attribute);
                },
                5 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.grow = try self.floatAttr(scope, node, attribute);
                },
                6 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.key = try self.attrKey(scope, node, attribute);
                },
                7 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.global_key = try self.attrKey(scope, node, attribute);
                },
                100 => entry = try self.buildElement(ui, scope, node.children[step.fields[0]]),
                101 => actions = try self.buildInputGroupActions(ui, scope, node.children[step.fields[0]]),
                200 => return ui.inputGroup(options, entry.?, actions),
                255 => return self.failNode(if (step.fields[0] == 0) node else node.children[step.fields[0] - 1], specialized.message(step.code)),
                else => @panic("invalid specialized builder capability"),
            };
            @panic("specialized program did not publish");
        }

        fn buildInputGroupActionsOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.InputGroupActionsOptions = .{};

            var request = specialized.Request.init(6);
            defer request.deinit();
            request.node(node, true);
            var program = try request.program(owner);
            defer program.deinit();
            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            while (program.next()) |step| switch (step.action) {
                1 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.gap = try self.floatAttr(scope, node, attribute);
                },
                2 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.key = try self.attrKey(scope, node, attribute);
                },
                3 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.global_key = try self.attrKey(scope, node, attribute);
                },
                100 => try self.buildChildren(ui, scope, node, &children),
                200 => return ui.inputGroupActions(options, @as([]const Ui.Node, children.items)),
                255 => return self.failNode(if (step.fields[0] == 0) node else node.children[step.fields[0] - 1], specialized.message(step.code)),
                else => @panic("invalid specialized builder capability"),
            };
            @panic("specialized program did not publish");
        }

        fn buildTimelineOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.TimelineOptions = .{};

            var request = specialized.Request.init(7);
            defer request.deinit();
            request.node(node, true);
            var program = try request.program(owner);
            defer program.deinit();
            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            while (program.next()) |step| switch (step.action) {
                1 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.gap = try self.floatAttr(scope, node, attribute);
                },
                2 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.grow = try self.floatAttr(scope, node, attribute);
                },
                3 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.key = try self.attrKey(scope, node, attribute);
                },
                4 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.global_key = try self.attrKey(scope, node, attribute);
                },
                5 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
                },
                100 => try self.buildChildren(ui, scope, node, &children),
                200 => return ui.timeline(options, @as([]const Ui.Node, children.items)),
                255 => return self.failNode(if (step.fields[0] == 0) node else node.children[step.fields[0] - 1], specialized.message(step.code)),
                else => @panic("invalid specialized builder capability"),
            };
            @panic("specialized program did not publish");
        }

        fn buildTimelineItemOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode, forwarded_press: ?MsgT) BuildError!Ui.Node {
            var options: Ui.TimelineItemOptions = .{ .title = "" };

            var request = specialized.Request.init(8);
            defer request.deinit();
            request.node(node, true);
            var program = try request.program(owner);
            defer program.deinit();

            while (program.next()) |step| switch (step.action) {
                1 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.title = try self.stringAttr(scope, node, attribute, markup.timeline_item_text_attr_message);
                },
                2 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.description = try self.stringAttr(scope, node, attribute, markup.timeline_item_text_attr_message);
                },
                3 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.meta = try self.stringAttr(scope, node, attribute, markup.timeline_item_text_attr_message);
                },
                4 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.indicator = try self.stringAttr(scope, node, attribute, markup.timeline_item_text_attr_message);
                },
                5 => {
                    const attribute = node.attrs[step.fields[0]];
                    // Vector icon indicator: the shared icon value grammar,
                    // like every icon attribute.
                    switch (value_programs.iconValue(owner, attribute.value, markup.button_icon_message)) {
                        .builtin, .app => |name| options.icon = name,
                        .binding => options.icon = try self.stringAttr(scope, node, attribute, markup.button_icon_message),
                        .invalid => |message| return self.failVoid(node, message),
                    }
                },
                6 => {
                    const attribute = node.attrs[step.fields[0]];
                    const text = try self.stringAttr(scope, node, attribute, "expected an option name");
                    options.variant = enumValueOwned(canvas.WidgetVariant, owner, text) orelse {
                        return self.failNode(node, "unknown option value");
                    };
                },
                7 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.connector = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
                },
                8 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.selected = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
                },
                9 => {
                    const attribute = node.attrs[step.fields[0]];
                    // Reuse the full message-attr machinery (payload
                    // bindings included) through a scratch options value.
                    var scratch: Ui.ElementOptions = .{};
                    try self.applyMessageAttr(scope, node, &scratch, attribute);
                    options.on_press = scratch.on_press;
                },
                10 => {
                    return self.failNode(node, markup.timeline_item_press_only_message);
                },
                11 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.key = try self.attrKey(scope, node, attribute);
                },
                12 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.global_key = try self.attrKey(scope, node, attribute);
                },
                200 => {
                    if (value_programs.forwardedPress(owner, forwarded_press != null)) options.on_press = forwarded_press.?;
                    return ui.timelineItem(options);
                },
                255 => return self.failNode(if (step.fields[0] == 0) node else node.children[step.fields[0] - 1], specialized.message(step.code)),
                else => @panic("invalid specialized builder capability"),
            };
            @panic("specialized program did not publish");
        }

        fn buildChartOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.ChartOptions = .{};

            var request = specialized.Request.init(9);
            defer request.deinit();
            request.node(node, true);
            var program = try request.program(owner);
            defer program.deinit();
            var series: []canvas.ChartSeries = &.{};
            while (program.next()) |step| switch (step.action) {
                1 => {
                    return self.failNode(node, markup.chart_display_only_message);
                },
                2 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.y_min = try self.floatAttr(scope, node, attribute);
                },
                3 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.y_max = try self.floatAttr(scope, node, attribute);
                },
                4 => {
                    const attribute = node.attrs[step.fields[0]];
                    const value = try self.evalAttrExpression(scope, node, attribute);
                    const admission = value_programs.integerOption(owner, 2, value, std.math.maxInt(u8));
                    options.grid_lines = switch (admission.action) {
                        1 => @intCast(value.integer),
                        255 => return self.failNode(node, value_programs.message(admission.code)),
                        else => @panic("invalid chart integer capability"),
                    };
                },
                5 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.baseline = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
                },
                6 => {
                    const attribute = node.attrs[step.fields[0]];
                    const typed = markup.attrTypedWithPolicy(owner, attribute);
                    _ = try self.specializedFormOwned(owner, node, 9, typed);
                    options.x_labels = try self.stringItems(ui, scope, node, typed.binding, markup.chart_x_labels_message);
                },
                7 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.y_labels = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
                },
                8 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.hover_details = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
                },
                9 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.stroke_width = try self.floatAttr(scope, node, attribute);
                },
                10 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.width = try self.floatAttr(scope, node, attribute);
                },
                11 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.height = try self.floatAttr(scope, node, attribute);
                },
                12 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.grow = try self.floatAttr(scope, node, attribute);
                },
                13 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.padding = try self.floatAttr(scope, node, attribute);
                },
                14 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.key = try self.attrKey(scope, node, attribute);
                },
                15 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.global_key = try self.attrKey(scope, node, attribute);
                },
                16 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
                },
                100 => series = try ui.arena.alloc(canvas.ChartSeries, node.children.len),
                101 => series[step.fields[0]] = try self.buildSeries(ui, scope, node.children[step.fields[0]]),
                200 => return ui.chart(options, series),
                255 => return self.failNode(if (step.fields[0] == 0) node else node.children[step.fields[0] - 1], specialized.message(step.code)),
                else => @panic("invalid specialized builder capability"),
            };
            @panic("specialized program did not publish");
        }

        fn buildVideoOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.VideoOptions = .{};

            var request = specialized.Request.init(10);
            defer request.deinit();
            request.node(node, true);
            var program = try request.program(owner);
            defer program.deinit();

            while (program.next()) |step| switch (step.action) {
                1 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.src = try self.stringAttr(scope, node, attribute, markup.video_src_message);
                },
                2 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.controls = try self.presenceFlagOwned(owner, scope, node, attribute);
                },
                3 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.autoplay = try self.presenceFlagOwned(owner, scope, node, attribute);
                },
                4 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.loop = try self.presenceFlagOwned(owner, scope, node, attribute);
                },
                5 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.muted = try self.presenceFlagOwned(owner, scope, node, attribute);
                },
                6 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.width = try self.floatAttr(scope, node, attribute);
                },
                7 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.height = try self.floatAttr(scope, node, attribute);
                },
                8 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.grow = try self.floatAttr(scope, node, attribute);
                },
                9 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.label = try self.stringAttr(scope, node, attribute, "label expects text");
                },
                10 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.key = try self.attrKey(scope, node, attribute);
                },
                11 => {
                    const attribute = node.attrs[step.fields[0]];
                    options.global_key = try self.attrKey(scope, node, attribute);
                },
                200 => return ui.video(options),
                255 => return self.failNode(if (step.fields[0] == 0) node else node.children[step.fields[0] - 1], specialized.message(step.code)),
                else => @panic("invalid specialized builder capability"),
            };
            @panic("specialized program did not publish");
        }

        fn buildSeriesOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!canvas.ChartSeries {
            var series = canvas.ChartSeries{};

            var request = specialized.Request.init(11);
            defer request.deinit();
            request.node(node, true);
            var program = try request.program(owner);
            defer program.deinit();

            while (program.next()) |step| switch (step.action) {
                1 => {
                    const attribute = node.attrs[step.fields[0]];
                    // Closed literal vocabulary: area is the markup
                    // spelling of a filled line; band stays with the
                    // builder (it needs a paired lower edge).
                    const typed = markup.attrTypedWithPolicy(owner, attribute);
                    _ = try self.specializedFormOwned(owner, node, 10, typed);
                    const selected = value_programs.seriesKind(owner, typed.literal) orelse return self.failVoid(node, markup.series_kind_message);
                    series.kind = selected.kind;
                    // A later kind attribute does not clear an earlier area fill.
                    if (selected.fill) series.fill = true;
                },
                2 => {
                    const attribute = node.attrs[step.fields[0]];
                    const typed = markup.attrTypedWithPolicy(owner, attribute);
                    _ = try self.specializedFormOwned(owner, node, 11, typed);
                    series.values = try self.f32Items(ui, scope, node, typed.binding);
                },
                3 => {
                    const attribute = node.attrs[step.fields[0]];
                    const typed = markup.attrTypedWithPolicy(owner, attribute);
                    _ = try self.specializedFormOwned(owner, node, 12, typed);
                    series.color = enumValueOwned(canvas.ChartSeriesColor, owner, typed.literal) orelse {
                        return self.failVoid(node, markup.series_color_message);
                    };
                },
                4 => {
                    const attribute = node.attrs[step.fields[0]];
                    series.label = try self.stringAttr(scope, node, attribute, markup.series_label_message);
                },
                200 => return series,
                255 => return self.failVoid(if (step.fields[0] == 0) node else node.children[step.fields[0] - 1], specialized.message(step.code)),
                else => @panic("invalid specialized builder capability"),
            };
            @panic("specialized program did not publish");
        }

        // ------------------------------------------------------ building

        fn buildNode(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (scope.expression_policy) |owner| return self.buildNodeOwned(owner, ui, scope, node);
            return self.buildNodeReference(ui, scope, node);
        }

        fn buildNodeReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
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

        /// Build one element and, when the builder collects provenance,
        /// stamp the node's authored source (file, span, template chain)
        /// onto the built `Ui.Node`. Every element — composites included —
        /// funnels through here, so the stamp covers the whole vocabulary
        /// in one place. `finalize` pairs the stamp with the structural id.
        fn buildElement(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            return self.buildElementForwardedPress(ui, scope, node, null);
        }

        fn buildElementForwardedPress(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, forwarded_press: ?MsgT) BuildError!Ui.Node {
            if (scope.expression_policy) |owner| return self.buildElementForwardedPressOwned(owner, ui, scope, node, forwarded_press);
            return self.buildElementForwardedPressReference(ui, scope, node, forwarded_press);
        }

        fn buildElementForwardedPressOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode, forwarded_press: ?MsgT) BuildError!Ui.Node {
            var request = value_programs.Request.init(33);
            defer request.deinit();
            request.words(&.{ @intFromBool(forwarded_press != null), @intFromBool(ui.provenance_sink != null) });
            var program = try request.program(owner);
            defer program.deinit();
            var built: ?Ui.Node = null;
            while (program.next()) |step| switch (step.action) {
                88 => built = try self.buildElementInner(ui, scope, node, forwarded_press),
                89 => {
                    built.?.on_press = forwarded_press.?;
                    built.?.widget.semantics.focusable = true;
                },
                90 => {
                    const source = try ui.arena.create(ui_provenance.NodeSource);
                    source.* = .{ .src_path = node.src_path, .span = node.span, .line = node.line, .column = node.column, .chain = scope.source_chain };
                    built.?.source = source;
                },
                91 => {
                    if (program.next() != null) @panic("trailing element postprocessing capability");
                    return built orelse @panic("element postprocessing did not build a node");
                },
                else => @panic("invalid element postprocessing capability"),
            };
            @panic("incomplete element postprocessing program");
        }

        fn lowerTabsTriggersOwned(owner: markup.expr.Policy, children: []Ui.Node) BuildError!void {
            var request = value_programs.Request.init(34);
            defer request.deinit();
            request.word(children.len);
            for (children) |child| request.blob(@tagName(child.widget.kind));
            var program = try request.program(owner);
            defer program.deinit();
            while (program.next()) |step| switch (step.action) {
                92 => children[step.fields[0]].widget.kind = .segmented_control,
                else => @panic("invalid tab trigger capability"),
            };
        }

        fn buildElementForwardedPressReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, forwarded_press: ?MsgT) BuildError!Ui.Node {
            var built = try self.buildElementInner(ui, scope, node, forwarded_press);
            if (forwarded_press) |msg| {
                // A press declared on <use> belongs to the expanded root.
                // Set it after the root-specific builder has run so generic
                // template roots become interactive as well.
                built.on_press = msg;
                built.widget.semantics.focusable = true;
            }
            if (ui.provenance_sink != null) {
                const source = try ui.arena.create(ui_provenance.NodeSource);
                source.* = .{
                    .src_path = node.src_path,
                    .span = node.span,
                    .line = node.line,
                    .column = node.column,
                    .chain = scope.source_chain,
                };
                built.source = source;
            }
            return built;
        }

        fn buildElementInnerOwned(self: *Self, owner: markup.expr.Policy, ui: *Ui, scope: *Scope, node: markup.MarkupNode, forwarded_press: ?MsgT) BuildError!Ui.Node {
            var lookup = elements.Request.init(0);
            defer lookup.deinit();
            lookup.blob(node.name);
            lookup.word(element_kind_table.len);
            for (element_kind_table) |entry| lookup.blob(entry.name);
            const route = lookup.decision(owner);
            if (route.action == 255) return self.failNode(node, elements.message(route.code));
            if (route.action == 1) return switch (route.fields[0]) {
                0 => self.buildVirtualWindow(ui, scope, node),
                1 => self.buildVirtualList(ui, scope, node),
                2 => self.buildMarkdown(ui, scope, node),
                3 => self.buildCode(ui, scope, node),
                4 => self.buildStepper(ui, scope, node),
                5 => self.buildTimeline(ui, scope, node),
                6 => self.buildTimelineItem(ui, scope, node, forwarded_press),
                7 => self.buildChart(ui, scope, node),
                8 => self.buildVideo(ui, scope, node),
                9 => self.buildInputGroup(ui, scope, node),
                else => @panic("invalid specialized element capability"),
            };
            if (route.action != 0 or route.fields[0] >= element_kind_table.len) @panic("invalid element schema selection");
            const kind = element_kind_table[route.fields[0]].kind;
            const schema = markup.schema.elementByName(node.name).?;
            var request = elements.Request.init(1);
            defer request.deinit();
            request.node(node, true);
            request.blob(@tagName(kind));
            request.words(&.{ @intFromBool(canvas.widgetKindHitTarget(kind)), @intFromBool(canvas.widgetKindStacksChildren(kind)), @intFromBool(elementTakesText(kind)), @intFromBool(elementTakesChildren(kind)) });
            request.word(switch (schema.a11y_name) {
                .none => 0,
                .image => 1,
                .control => 2,
                .editable => 3,
                .radiogroup => 4,
            });
            request.words(&.{ @intFromBool(schema.takes_text), @intFromBool(markup.schema.elementHoldsChildren(schema)) });
            request.names(&markup.known_non_hit_target_element_names);
            var dead_count: usize = 0;
            for (markup.schema.events) |entry| if (entry.dead_on_non_hit_target) {
                dead_count += 1;
            };
            request.word(dead_count);
            for (markup.schema.events) |entry| if (entry.dead_on_non_hit_target) {
                request.blob(entry.name);
            };
            request.names(&markup.overflow_value_names);
            request.names(&markup.known_text_size_value_names);
            request.names(&markup.known_control_size_value_names);
            request.names(&markup.schema.role_names);
            request.names(&markup.schema.container_role_names);
            var program = try request.program(owner);
            defer program.deinit();
            var inner = node;
            var options: Ui.ElementOptions = .{};
            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            var built: ?Ui.Node = null;
            while (program.next()) |step| switch (step.action) {
                10, 11 => {
                    const child = node.children[step.fields[0]];
                    const info = shape_programs.shape(owner, child, if (step.action == 10) 0 else 2);
                    if (info) |diagnostic| {
                        self.diagnostic = .{ .line = diagnostic.line, .column = diagnostic.column, .message = diagnostic.message, .path = diagnostic.path };
                        return error.MarkupBuild;
                    }
                },
                12 => {
                    const filtered = try ui.arena.alloc(markup.MarkupNode, node.children.len);
                    var length: usize = 0;
                    for (node.children, 0..) |child, i| {
                        if (i + 1 == step.fields[0] or i + 1 == step.fields[1]) continue;
                        filtered[length] = child;
                        length += 1;
                    }
                    inner.children = filtered[0..length];
                },
                15 => try self.applyAttrs(scope, node, &options),
                16 => {
                    var menu_children: std.ArrayListUnmanaged(Ui.Node) = .empty;
                    try self.buildChildList(ui, scope, node.children[step.fields[0]].children, &menu_children);
                    options.context_menu = ui.contextMenuItemsFromNodes(menu_children.items);
                },
                20 => {
                    const name_attr = node.attrs[step.fields[0]];
                    switch (value_programs.iconValue(owner, name_attr.value, markup.icon_name_message)) {
                        .builtin => |name| {
                            var icon = ui.el(kind, options, .{});
                            icon.widget.text = name;
                            return icon;
                        },
                        .app => |spelled| options.icon = spelled,
                        .binding => options.icon = try self.stringAttr(scope, node, name_attr, markup.icon_name_message),
                        .invalid => |message| return self.failNode(node, message),
                    }
                    return ui.el(kind, options, .{});
                },
                21 => {
                    var text = ui.el(kind, options, .{});
                    if (step.fields[0] != 0) text.widget.text = try self.interpolatedText(ui, scope, inner);
                    if (step.fields[1] != 0) text.widget.image_fit = .cover;
                    return text;
                },
                22 => try self.buildChildren(ui, scope, inner, &children),
                23 => try lowerTabsTriggersOwned(owner, children.items),
                24 => built = ui.el(kind, options, @as([]const Ui.Node, children.items)),
                25 => {
                    const pill = node.children[step.fields[0]];
                    built.?.widget.text = try self.interpolatedText(ui, scope, pill);
                    built.?.widget.text_alignment = if (pill.attr("text-alignment")) |raw|
                        enumValueOwned(canvas.TextAlign, owner, raw) orelse return self.failNode(pill, markup.reactions_alignment_value_message)
                    else
                        .end;
                },
                26 => return self.buildSpanParagraph(ui, scope, inner, options),
                255 => return self.failNode(if (step.fields[0] == 0) node else node.children[step.fields[0] - 1], elements.message(step.code)),
                else => @panic("invalid element construction capability"),
            };
            return built orelse @panic("element program did not publish a node");
        }

        fn applyAttrsOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions) BuildError!void {
            var request = elements.Request.init(2);
            defer request.deinit();
            request.node(node, false);
            request.word(color_style_attr_fields.len);
            for (color_style_attr_fields) |entry| request.blob(entry.markup);
            request.word(attr_names.len);
            for (attr_names) |entry| request.blob(entry.markup);
            var program = try request.program(owner);
            defer program.deinit();
            while (program.next()) |step| {
                if (step.action == 255) return self.failVoid(node, elements.message(step.code));
                if (step.action == 20) {
                    try self.applyImageSourceAttrsOwned(owner, scope, node, options);
                    continue;
                }
                const attribute = node.attrs[step.fields[0]];
                switch (step.action) {
                    1 => try self.applyMessageAttr(scope, node, options, attribute),
                    2 => options.key = try self.attrKey(scope, node, attribute),
                    3 => options.global_key = try self.attrKey(scope, node, attribute),
                    4 => options.semantics.focusable = switch (try self.evalAttrExpression(scope, node, attribute)) {
                        .boolean => |flag| flag,
                        else => return self.failVoid(node, "focusable expects a boolean"),
                    },
                    5 => {
                        const value = try self.evalAttrExpression(scope, node, attribute);
                        const text = switch (value) {
                            .string => |text| text,
                            else => return self.failVoid(node, "role expects a role name"),
                        };
                        options.semantics.role = enumValueOwned(canvas.WidgetRole, owner, text) orelse return self.failVoid(node, "unknown role");
                    },
                    6 => options.semantics.label = switch (try self.evalAttrExpression(scope, node, attribute)) {
                        .string => |text| text,
                        else => return self.failVoid(node, "label expects text"),
                    },
                    7 => try self.applyImageAttr(scope, node, options, attribute),
                    8 => try self.applySurfaceAttr(scope, node, options, attribute),
                    9 => try self.applyPtyAttr(scope, node, options, attribute),
                    10 => try self.applyButtonIconAttr(scope, node, options, attribute),
                    11 => try self.applyAnchorOwned(owner, node, options, attribute.value, 0),
                    12 => try self.applyAnchorOwned(owner, node, options, attribute.value, 1),
                    13 => try self.applyAnchorOwned(owner, node, options, attribute.value, 2),
                    14 => try self.applyQuietHoverAttr(scope, node, options, attribute),
                    15 => {
                        const literal = markup.attrTypedWithPolicy(owner, attribute).literal;
                        if (step.fields[1] == color_style_attr_fields.len) {
                            options.style_tokens.radius = enumValueOwned(canvas.RadiusTokenName, owner, literal) orelse return self.failVoid(node, markup.unknown_radius_token_message);
                        } else {
                            var found = false;
                            inline for (color_style_attr_fields, 0..) |entry, i| if (step.fields[1] == i) {
                                @field(options.style_tokens, entry.zig) = enumValueOwned(canvas.ColorTokenName, owner, literal) orelse return self.failVoid(node, markup.unknown_color_token_message);
                                found = true;
                            };
                            if (!found) @panic("invalid style reflection capability");
                        }
                    },
                    16 => {
                        var found = false;
                        inline for (attr_names, 0..) |entry, i| if (step.fields[1] == i) {
                            try self.setOptionField(scope, node, options, entry.zig, attribute);
                            found = true;
                        };
                        if (!found) @panic("invalid option reflection capability");
                    },
                    else => @panic("invalid attribute capability"),
                }
            }
        }

        fn applyMessageAttrOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            const typed = markup.attrTypedWithPolicy(owner, attribute);
            const expression = if (typed == .message) typed.message else markup.MessageExpression{ .tag = "", .payload = "" };
            var request = elements.Request.init(3);
            defer request.deinit();
            request.word(@intFromBool(typed == .message));
            request.blob(attribute.name[3..]);
            request.blob(node.name);
            request.word(@intFromBool(expression.payload.len != 0));
            request.names(&markup.known_dismiss_element_names);
            var program = try request.program(owner);
            defer program.deinit();
            var msg: MsgT = undefined;
            while (program.next()) |step| switch (step.action) {
                1 => {
                    options.on_input = inputConstructorOwned(owner, expression.tag) orelse return self.failVoid(node, "on-input tag must carry a TextInputEvent payload");
                    return;
                },
                2 => {
                    options.on_scroll = scrollConstructorOwned(owner, expression.tag) orelse {
                        if (legacyScrollTagOwned(owner, expression.tag)) return self.failVoid(node, markup.on_scroll_legacy_payload_message);
                        return self.failVoid(node, markup.on_scroll_payload_message);
                    };
                    return;
                },
                3 => {
                    options.on_terminal = terminalConstructorOwned(owner, expression.tag) orelse return self.failVoid(node, markup.on_terminal_payload_message);
                    return;
                },
                4 => {
                    options.on_resize = resizeConstructorOwned(owner, expression.tag) orelse return self.failVoid(node, markup.on_resize_payload_message);
                    return;
                },
                5 => {
                    options.on_drag = try self.constructDragMessage(scope, node, expression);
                    return;
                },
                6 => if (valueConstructorOwned(owner, expression.tag)) |make| {
                    options.on_value = make;
                    return;
                },
                7 => msg = try self.constructMessage(scope, node, expression),
                8 => switch (step.fields[0]) {
                    0 => options.on_press = msg,
                    1 => options.on_double_press = msg,
                    2 => options.on_toggle = msg,
                    3 => options.on_change = msg,
                    4 => options.on_submit = msg,
                    5 => options.on_dismiss = msg,
                    6 => options.on_hold = msg,
                    7 => options.on_hover_enter = msg,
                    8 => options.on_hover_leave = msg,
                    9 => options.on_reach_start = msg,
                    10 => options.on_reach_end = msg,
                    else => @panic("invalid event storage capability"),
                },
                255 => return self.failVoid(node, elements.message(step.code)),
                else => @panic("invalid event capability"),
            };
        }

        fn attrKeyOwned(self: *Self, owner: markup.expr.Policy, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!?canvas.UiKey {
            const typed = markup.attrTypedWithPolicy(owner, attribute);
            var defaulted = false;
            var bare = false;
            if (typed == .binding) {
                const parts = value_programs.bindingPath(owner, typed.binding);
                if (scope.lookup(parts.head)) |entry| defaulted = entry.defaulted;
                bare = parts.tail == null;
            }
            const value = try self.evalAttrExpression(scope, node, attribute);
            const step = elements.decide(owner, 4, &.{ @intFromBool(typed == .binding), @intFromBool(defaulted), @intFromBool(bare), switch (value) {
                .integer => 0,
                .float => 1,
                .string => 2,
                .boolean => 3,
            }, @intFromBool(value == .string and value.string.len == 0) });
            return switch (step.action) {
                0 => null,
                1 => canvas.uiKey(@as(u64, @bitCast(value.integer))),
                2 => canvas.uiKey(value.string),
                255 => self.failKey(node, elements.message(step.code)),
                else => @panic("invalid key capability"),
            };
        }

        fn buildElementInner(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, forwarded_press: ?MsgT) BuildError!Ui.Node {
            if (scope.expression_policy) |owner| return self.buildElementInnerOwned(owner, ui, scope, node, forwarded_press);
            return self.buildElementInnerReference(ui, scope, node, forwarded_press);
        }

        fn buildElementInnerReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, forwarded_press: ?MsgT) BuildError!Ui.Node {
            if (std.mem.eql(u8, node.name, "virtual-window")) return self.buildVirtualWindow(ui, scope, node);
            if (std.mem.eql(u8, node.name, "virtual-list")) return self.buildVirtualList(ui, scope, node);
            if (std.mem.eql(u8, node.name, "markdown")) {
                return self.buildMarkdown(ui, scope, node);
            }
            if (std.mem.eql(u8, node.name, "code")) {
                return self.buildCode(ui, scope, node);
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
                return self.buildTimelineItem(ui, scope, node, forwarded_press);
            }
            if (std.mem.eql(u8, node.name, "chart")) {
                return self.buildChart(ui, scope, node);
            }
            if (std.mem.eql(u8, node.name, "series")) {
                // Series inside a chart are consumed by buildChart.
                return self.failNode(node, markup.series_parent_message);
            }
            if (std.mem.eql(u8, node.name, "video")) {
                return self.buildVideo(ui, scope, node);
            }
            if (std.mem.eql(u8, node.name, "context-menu")) {
                // Direct context-menu children are consumed by their host
                // element below; one reaching here is misplaced.
                return self.failNode(node, markup.context_menu_parent_message);
            }
            if (std.mem.eql(u8, node.name, "input-group")) {
                return self.buildInputGroup(ui, scope, node);
            }
            if (std.mem.eql(u8, node.name, "input-group-actions")) {
                // Actions rows inside an input-group are consumed by
                // buildInputGroup.
                return self.failNode(node, markup.input_group_actions_parent_message);
            }
            if (std.mem.eql(u8, node.name, "span")) {
                // Spans inside a text paragraph are consumed by
                // buildSpanParagraph; one reaching here has no text
                // parent.
                return self.failNode(node, markup.span_parent_message);
            }
            if (std.mem.eql(u8, node.name, "reactions")) {
                // Reactions inside a bubble are consumed by the bubble's
                // build below; one reaching here has no bubble parent.
                return self.failNode(node, markup.reactions_parent_message);
            }
            const kind = elementKind(node.name) orelse {
                return self.failNode(node, "unknown element");
            };
            // Extract a direct context-menu child: it is metadata on this
            // element (lowered to the declared platform-menu items), not
            // content, so every content rule below sees the remaining
            // children only. Mirrors the validator and the compiled
            // engine.
            var inner = node;
            var context_menu_child: ?markup.MarkupNode = null;
            for (node.children) |child| {
                if (!markup.nodeIsContextMenu(child)) continue;
                if (context_menu_child != null) return self.failNode(child, markup.context_menu_single_message);
                if (!markup.contextMenuHostEligible(node)) return self.failNode(child, markup.context_menu_host_message);
                if (markup.contextMenuShapeError(child)) |info| {
                    self.diagnostic = .{ .line = info.line, .column = info.column, .message = info.message, .path = info.path };
                    return error.MarkupBuild;
                }
                context_menu_child = child;
            }
            // Extract a direct reactions child the same way: the pill is
            // bubble CHROME (it lowers onto the bubble widget's
            // chrome-text channel), not content, so every content rule
            // below sees the remaining children only. Mirrors the
            // validator and the compiled engine.
            var reactions_child: ?markup.MarkupNode = null;
            for (node.children) |child| {
                if (!markup.nodeIsReactions(child)) continue;
                if (kind != .bubble) return self.failNode(child, markup.reactions_parent_message);
                if (reactions_child != null) return self.failNode(child, markup.reactions_single_message);
                if (markup.reactionsShapeError(child)) |info| {
                    self.diagnostic = .{ .line = info.line, .column = info.column, .message = info.message, .path = info.path };
                    return error.MarkupBuild;
                }
                reactions_child = child;
            }
            // The bubble's chrome-text channel belongs to the reaction
            // pill; a bare text attribute would silently do nothing, so
            // it is a build error. Mirrors the validator and the
            // compiled engine.
            if (kind == .bubble) {
                if (node.attrEntry("text")) |_| {
                    return self.failNode(node, markup.bubble_text_attr_message);
                }
            }
            if (context_menu_child != null or reactions_child != null) {
                const filtered = try ui.arena.alloc(markup.MarkupNode, node.children.len);
                var filtered_len: usize = 0;
                for (node.children) |child| {
                    if (markup.nodeIsContextMenu(child)) continue;
                    if (markup.nodeIsReactions(child)) continue;
                    filtered[filtered_len] = child;
                    filtered_len += 1;
                }
                inner.children = filtered[0..filtered_len];
            }
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
            // Only plain text leaves word-wrap or elide; anywhere else
            // the options are silently inert dead layout data. Mirrors
            // the validator and the compiled engine's compile error.
            if (kind != .text) {
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "wrap")) {
                        return self.failNode(node, markup.wrap_element_message);
                    }
                    if (std.mem.eql(u8, attribute.name, "overflow")) {
                        return self.failNode(node, markup.overflow_element_message);
                    }
                }
            }
            // Only textarea has a configurable Enter-vs-newline policy.
            // Mirrors validation and the compiled engine.
            if (kind != .textarea) {
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "submit-on-enter")) {
                        return self.failNode(node, markup.submit_on_enter_element_message);
                    }
                }
            }
            // The overflow policy's closed literal vocabulary. Mirrors
            // the validator and the compiled engine's compile error;
            // bindings resolve below like any enum option.
            for (node.attrs) |attribute| {
                if (!std.mem.eql(u8, attribute.name, "overflow")) continue;
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression != .literal) continue;
                if (!markup.nameInList(expression.literal, &markup.overflow_value_names)) {
                    return self.failNode(node, markup.overflow_value_message);
                }
            }
            // The size register's closed literal vocabulary: the control
            // scale everywhere, the typography rungs (heading/display) on
            // text only. Mirrors the validator and the compiled engine's
            // compile error; bindings resolve below like any enum option.
            for (node.attrs) |attribute| {
                if (!std.mem.eql(u8, attribute.name, "size")) continue;
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression != .literal) continue;
                if (markup.nameInList(expression.literal, &markup.known_text_size_value_names)) {
                    if (kind != .text) {
                        return self.failNode(node, markup.text_size_element_message);
                    }
                } else if (!markup.nameInList(expression.literal, &markup.known_control_size_value_names)) {
                    return self.failNode(node, markup.size_value_message);
                }
            }
            // Splits take exactly two static pane children (the divider
            // sits between fixed panes). Mirrors the validator and the
            // compiled engine's compile error.
            if (kind == .split) {
                var pane_count: usize = 0;
                for (inner.children) |child| {
                    switch (child.kind) {
                        .element, .use_block => pane_count += 1,
                        else => return self.failNode(child, markup.split_children_message),
                    }
                }
                if (pane_count != 2) return self.failNode(node, markup.split_children_message);
            }
            // The image leaf's static shape, mirroring the validator and
            // the compiled engine's compile error. Without its id binding
            // the leaf can never draw - statically dead markup, refused
            // here too so markup that skipped validation (hot reload)
            // fails the build instead of silently rendering nothing. And
            // it takes no children at all (icon's leaf policy): checked
            // on the ORIGINAL node, so an extracted context-menu still
            // counts as a child exactly like the validator's raw-node
            // check.
            if (kind == .image) {
                if (node.attr("image") == null) {
                    return self.failNode(node, markup.image_missing_image_message);
                }
                if (node.children.len > 0) {
                    return self.failNode(node, markup.image_children_message);
                }
            }
            // The terminal leaf's static shape, the image policy exactly:
            // without its pty binding it can never attach a session, and
            // its widget has no child slots — both refused at build so
            // markup that skipped validation (hot reload) fails instead
            // of silently rendering an unbound surface or dropping the
            // child.
            if (kind == .terminal) {
                if (node.attr("pty") == null) {
                    return self.failNode(node, markup.terminal_missing_pty_message);
                }
                if (node.children.len > 0) {
                    return self.failNode(node, markup.terminal_children_message);
                }
            }
            // The a11y lint's error half: an unnamed interactive control
            // or a misused role ships a view a screen reader user cannot
            // operate, so it fails the build like any other markup
            // mistake. Mirrors the validator and the compiled engine's
            // compile error.
            if (markup.a11yNameError(node)) |message| {
                return self.failNode(node, message);
            }
            if (markup.a11yRoleError(node)) |message| {
                return self.failNode(node, message);
            }
            var options: Ui.ElementOptions = .{};
            try self.applyAttrs(scope, node, &options);
            // The extracted context-menu lowers through the ordinary
            // element path — its menu-items build like any element
            // (structure tags, interpolation, and message typing all
            // apply) — and the built nodes become the host's declared
            // items. An empty runtime result (every if false, an empty
            // for) simply declares no menu.
            if (context_menu_child) |menu_node| {
                var menu_children: std.ArrayListUnmanaged(Ui.Node) = .empty;
                try self.buildChildList(ui, scope, menu_node.children, &menu_children);
                options.context_menu = ui.contextMenuItemsFromNodes(menu_children.items);
            }

            if (kind == .icon) {
                // The shared icon value grammar, no children. Mirrors the
                // validator and the compiled engine: a built-in literal is
                // proven here (a typo can never rot), while app: names and
                // bound names ride the explicit icon channel and degrade
                // at draw time to the missing-icon fallback plus a Debug
                // warning naming the value.
                const name_attr = node.attrEntry("name") orelse return self.failNode(node, markup.icon_missing_name_message);
                if (inner.children.len > 0) return self.failNode(node, markup.icon_children_message);
                switch (markup.iconValueOf(name_attr.value, markup.icon_name_message)) {
                    .builtin => |name| {
                        var built = ui.el(kind, options, .{});
                        built.widget.text = name;
                        return built;
                    },
                    .app => |spelled| options.icon = spelled,
                    .binding => options.icon = try self.stringAttr(scope, node, name_attr, markup.icon_name_message),
                    .invalid => |message| return self.failNode(node, message),
                }
                return ui.el(kind, options, .{});
            }

            // The span paragraph: a text element with inline <span>
            // children lowers through Ui.paragraph, exactly like a
            // builder span paragraph. Mirrors the validator and the
            // compiled engine.
            if (kind == .text and markup.nodeHasSpanChildren(inner)) {
                return self.buildSpanParagraph(ui, scope, inner, options);
            }

            // The list-row composite: a text-taking element whose content
            // is element children instead of the text run flows those
            // children inside its own chrome (mixing text and elements is
            // a teaching error; the text path below would silently drop
            // the elements). Mirrors the validator and the compiled
            // engine.
            const composite_children = elementTakesChildren(kind) and markup.nodeHasElementContent(inner);
            if (composite_children) {
                for (inner.children) |child| {
                    if (child.kind == .text) return self.failNode(child, markup.text_or_children_content_message);
                }
            }
            if (elementTakesText(kind) and !composite_children) {
                var built = ui.el(kind, options, .{});
                // Element content wins when present; an empty element
                // keeps the already-resolved text= attribute in options.
                // Checkbox/radio joined this path when they became text
                // leaves, so replacing unconditionally would regress the
                // binding-friendly attribute that already worked.
                if (inner.children.len > 0) {
                    built.widget.text = try self.interpolatedText(ui, scope, inner);
                }
                // Avatars clip their runtime image to the avatar circle,
                // exactly like `Ui.avatar` (a no-op while the id is 0 and
                // the initials fallback renders).
                if (kind == .avatar) built.widget.image_fit = .cover;
                return built;
            }

            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            try self.buildChildren(ui, scope, inner, &children);
            // Tab triggers ARE segmented controls: markup composes the
            // strip from `<button>` children (segmented-control is a
            // documented markup exclusion), and the engine lowers them to
            // the widget kind tab strips are built on — so the active
            // trigger lifts to the surface with a hairline exactly like
            // the Zig builder's tabs. Handlers ride the widget id, so
            // `selected=`/`on-press` bindings are untouched.
            if (kind == .tabs) lowerTabsTriggers(children.items);
            var built = ui.el(kind, options, @as([]const Ui.Node, children.items));
            // The extracted reactions run lands on the bubble widget's
            // chrome-text channel — the render pass draws it as the
            // docked pill — and the dock rides text_alignment (end is
            // the default: the trailing dock reactions conventionally
            // hang from). Interpolation applies to the run like any
            // text content.
            if (reactions_child) |pill_node| {
                built.widget.text = try self.interpolatedText(ui, scope, pill_node);
                built.widget.text_alignment = if (pill_node.attr("text-alignment")) |raw|
                    std.meta.stringToEnum(canvas.TextAlign, raw) orelse
                        return self.failNode(pill_node, markup.reactions_alignment_value_message)
                else
                    .end;
            }
            return built;
        }

        fn buildChildren(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
            return self.buildChildList(ui, scope, node.children, out);
        }

        fn buildChildList(self: *Self, ui: *Ui, scope: *Scope, children: []const markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
            if (scope.expression_policy) |owner| return self.buildChildListOwned(owner, ui, scope, children, out);
            return self.buildChildListReference(ui, scope, children, out);
        }

        fn buildChildListReference(self: *Self, ui: *Ui, scope: *Scope, children: []const markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
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
                        const test_attr = child.attrEntry("test") orelse {
                            return self.failVoid(child, "if requires a test attribute");
                        };
                        const condition = try self.evalAttrExpression(scope, child, test_attr);
                        var else_node: ?markup.MarkupNode = null;
                        if (index + 1 < children.len and children[index + 1].kind == .else_block) {
                            else_node = children[index + 1];
                            index += 1;
                        }
                        if (markup.expr.truthyWithPolicy(scope.expression_policy, condition)) {
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
            if (scope.expression_policy) |owner| return self.buildSlotOwned(owner, ui, scope, node, out);
            return self.buildSlotReference(ui, scope, node, out);
        }

        fn buildSlotReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
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
            const saved_chain = scope.source_chain;
            scope.len = capture.len;
            scope.floor = capture.floor;
            scope.template_ctx = capture.template_ctx;
            scope.source_chain = capture.chain;
            defer {
                for (saved_entries[0 .. saved_len - capture.len], 0..) |entry, offset| {
                    scope.entries[capture.len + offset] = entry;
                }
                scope.len = saved_len;
                scope.floor = saved_floor;
                scope.template_ctx = saved_ctx;
                scope.source_chain = saved_chain;
            }
            try self.buildChildList(ui, scope, capture.nodes, out);
        }

        /// Expands a `for` block: per item, the whole body (one or more
        /// elements, `use` expansions, and nested `for`/`if`/`else`
        /// structure) is appended to `out`. Returns the item count so the
        /// caller can render a trailing `<else>` for the empty case.
        fn virtualCountAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, name: []const u8, fallback: usize) BuildError!usize {
            const attribute = node.attrEntry(name) orelse return fallback;
            const value = try self.evalUnclassifiedExpression(scope, node, attribute);
            return switch (value) {
                .integer => |count| if (count >= 0 and count <= 9007199254740991) @intCast(count) else self.failValue(node, "virtual window count requires a nonnegative safe integer"),
                else => self.failValue(node, "virtual window count requires an integer"),
            };
        }

        fn virtualExtentAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, name: []const u8) BuildError!f32 {
            const attribute = node.attrEntry(name) orelse return 0;
            const value = try self.floatAttr(scope, node, attribute);
            if (!std.math.isFinite(value) or value < 0) return self.failValue(node, "virtual window extent requires a nonnegative finite f32");
            return value;
        }

        fn buildVirtualWindow(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (scope.expression_policy) |owner| return self.buildVirtualWindowOwned(owner, ui, scope, node);
            return self.buildVirtualWindowReference(ui, scope, node);
        }

        fn buildVirtualWindowReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            @setEvalBranchQuota(scan_quota);
            for (scope.entries[scope.floor..scope.len]) |entry| if (entry.payload == .virtual) return self.failNode(node, "virtual-window declarations cannot nest");
            if (scope.len >= max_scope_depth or node.children.len != 1 or (node.children[0].kind != .element and node.children[0].kind != .use_block)) return self.failNode(node, "virtual-window requires one root child");
            const identity = node.attr("id") orelse return self.failNode(node, "virtual-window requires id");
            const name = node.attr("as") orelse return self.failNode(node, "virtual-window requires as");
            const id = canvas.globalWidgetId(.scroll_view, .{ .str = identity });
            if (ui.virtualWindows().len >= canvas.max_virtual_windows) return self.failNode(node, "too many virtual windows");
            for (ui.virtualWindows()) |prior| if (prior.id == id) return self.failNode(node, "duplicate virtual window identity");
            var options = Ui.VirtualListOptions{
                .id = identity,
                .item_count = try self.virtualCountAttr(scope, node, "item-count", 0),
                .item_extent = try self.virtualExtentAttr(scope, node, "item-extent"),
                .gap = try self.virtualExtentAttr(scope, node, "gap"),
                .overscan = try self.virtualCountAttr(scope, node, "overscan", 4),
                .viewport_fallback = try self.virtualExtentAttr(scope, node, "viewport-fallback"),
                .index_base = try self.virtualCountAttr(scope, node, "index-base", 0),
                .anchor = if (std.mem.eql(u8, node.attr("anchor") orelse "leading", "trailing")) .trailing else .leading,
            };
            if (options.index_base > 9007199254740991 - options.item_count) return self.failNode(node, "virtual window logical range exceeds safe integers");
            if (node.attr("extent-estimate")) |estimate| {
                if (comptime @hasDecl(ModelT, "virtualExtentHelper") and @hasDecl(ModelT, "virtualExtentEstimate")) {
                    const helper = ModelT.virtualExtentHelper(estimate) orelse return self.failNode(node, "extent-estimate requires a numeric index helper");
                    options.extent_estimate = ModelT.virtualExtentEstimate;
                    options.extent_context = @ptrFromInt(@as(usize, helper) + 1);
                } else return self.failNode(node, "extent-estimate requires a stable compiled helper capability");
            }
            if (options.extent_estimate == null and options.item_extent == 0) return self.failNode(node, "virtual-window requires an extent or estimate");
            const consumed = try ui.arena.create(bool);
            consumed.* = false;
            scope.entries[scope.len] = .{ .name = name, .payload = .{ .virtual = .{ .options = options, .range = ui.virtualWindow(options), .consumed = consumed } } };
            scope.len += 1;
            defer scope.len -= 1;
            const result = try self.buildNode(ui, scope, node.children[0]);
            if (!consumed.*) return self.failNode(node, "virtual window requires exactly one list");
            return result;
        }

        fn buildVirtualList(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (scope.expression_policy) |owner| return self.buildVirtualListOwned(owner, ui, scope, node);
            return self.buildVirtualListReference(ui, scope, node);
        }

        fn buildVirtualListReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            @setEvalBranchQuota(scan_quota);
            const window = scope.lookup(node.attr("window") orelse return self.failNode(node, "virtual-list requires window")) orelse return self.failNode(node, "virtual-list requires an enclosing window");
            if (window.payload != .virtual) return self.failNode(node, "virtual-list requires an enclosing window");
            const resolved = window.payload.virtual;
            if (resolved.consumed.*) return self.failNode(node, "virtual window has more than one list");
            resolved.consumed.* = true;
            const each = node.attr("each") orelse return self.failNode(node, "virtual-list requires each");
            const name = node.attr("as") orelse return self.failNode(node, "virtual-list requires as");
            if (scope.len >= max_scope_depth or node.children.len != 1) return self.failNode(node, "virtual-list requires one keyed root per row");
            inline for (@typeInfo(ModelT).@"struct".decls) |decl| {
                const Decl = @TypeOf(@field(ModelT, decl.name));
                if (comptime reflect.isVirtualItemFn(ModelT, Decl)) {
                    if (std.mem.eql(u8, decl.name, each)) {
                        const info = @typeInfo(Decl).@"fn";
                        const Parameter = info.params[1].type.?;
                        const Range = reflect.Pointee(Parameter);
                        var range: Range = undefined;
                        inline for (@typeInfo(Range).@"struct".fields) |field| {
                            const source = @field(resolved.range, field.name);
                            @field(range, field.name) = switch (@typeInfo(field.type)) {
                                .int => @intCast(source),
                                .float => if (@typeInfo(@TypeOf(source)) == .int) @floatFromInt(source) else @floatCast(source),
                                else => unreachable,
                            };
                        }
                        const argument = if (Parameter == Range) range else &range;
                        const items = if (comptime info.params.len == 3) @field(ModelT, decl.name)(scope.model, argument, ui.arena) else @field(ModelT, decl.name)(scope.model, argument);
                        if (items.len != resolved.range.itemCount()) return self.failNode(node, "virtual-list query returned a different item count");
                        const Item = reflect.sliceElement(info.return_type.?).?;
                        const type_index = comptime blk: {
                            for (item_types, 0..) |candidate, index| if (candidate == Item) break :blk index;
                            unreachable;
                        };
                        var rows: std.ArrayListUnmanaged(Ui.Node) = .empty;
                        for (items) |*item| {
                            scope.entries[scope.len] = .{ .name = name, .payload = .{ .item = .{ .type_index = type_index, .ptr = @ptrCast(item) } } };
                            scope.len += 1;
                            const built = self.buildNode(ui, scope, node.children[0]);
                            scope.len -= 1;
                            const row = try built;
                            if (row.key == null and row.global_key == null) return self.failNode(node, "virtual-list requires one keyed root per row");
                            try rows.append(ui.arena, row);
                        }
                        var attributes: std.ArrayListUnmanaged(markup.MarkupAttr) = .empty;
                        for (node.attrs) |attribute| if (!std.mem.eql(u8, attribute.name, "window") and !std.mem.eql(u8, attribute.name, "each") and !std.mem.eql(u8, attribute.name, "as")) {
                            try attributes.append(ui.arena, attribute);
                        };
                        var proxy = node;
                        proxy.name = "scroll";
                        proxy.attrs = attributes.items;
                        var element: Ui.ElementOptions = .{};
                        try self.applyAttrs(scope, proxy, &element);
                        var options = resolved.options;
                        options.width = element.width;
                        options.height = element.height;
                        options.min_width = element.min_width;
                        options.grow = element.grow;
                        options.padding = element.padding orelse 0;
                        options.style_tokens = element.style_tokens;
                        options.semantics = element.semantics;
                        options.overscroll = element.overscroll;
                        options.on_scroll = element.on_scroll;
                        options.on_reach_end = element.on_reach_end;
                        options.on_reach_start = element.on_reach_start;
                        return ui.virtualList(options, resolved.range, .{rows.items});
                    }
                }
            }
            return self.failNode(node, "virtual-list each requires a Model-first complete range query");
        }

        fn buildFor(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!usize {
            if (scope.expression_policy) |owner| return self.buildForOwned(owner, ui, scope, node, out);
            return self.buildForReference(ui, scope, node, out);
        }

        fn buildForReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!usize {
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
            if (scope.expression_policy) |owner| return self.iterateItemsOwned(owner, ui, Item, type_index, scope, each);
            return self.iterateItemsReference(ui, Item, type_index, scope, each);
        }

        fn iterateItemsReference(self: *Self, ui: *Ui, comptime Item: type, comptime type_index: usize, scope: *Scope, each: []const u8) BuildError!?[]const Item {
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
            if (scope.expression_policy) |owner| return self.buildMarkdownOwned(owner, ui, scope, node);
            return self.buildMarkdownReference(ui, scope, node);
        }

        fn buildMarkdownReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (node.children.len != 0) {
                return self.failNode(node.children[0], markup.markdown_children_message);
            }
            var options: Md.Options = .{};
            var source_text: ?[]const u8 = null;
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "source")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .binding) return self.failNode(node, markup.markdown_source_message);
                    const value = try self.evalBinding(scope, node, typed.binding, true);
                    source_text = switch (value) {
                        .string => |text| text,
                        else => return self.failNode(node, markup.markdown_source_message),
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "on-link")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .message or typed.message.payload.len != 0) {
                        return self.failNode(node, markup.markdown_on_link_message);
                    }
                    options.on_link = linkConstructor(typed.message.tag) orelse {
                        return self.failNode(node, markup.markdown_on_link_message);
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "on-details")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .message or typed.message.payload.len != 0) {
                        return self.failNode(node, markup.markdown_on_details_message);
                    }
                    options.on_details = detailsConstructor(typed.message.tag) orelse {
                        return self.failNode(node, markup.markdown_on_details_message);
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "details-expanded")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .binding) return self.failNode(node, markup.markdown_details_expanded_message);
                    options.details_expanded = try self.boolItems(ui, scope, node, typed.binding);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "images")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .binding) return self.failNode(node, markup.markdown_images_message);
                    options.images = try self.markdownImageItems(ui, scope, node, typed.binding);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "issue-link-base")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed == .equals or typed == .invalid) {
                        return self.failNode(node, markup.markdown_issue_link_base_message);
                    }
                    const value = try self.evalAttrExpression(scope, node, attribute);
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

        // ----------------------------------------------------------- code

        fn buildCode(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (scope.expression_policy) |owner| return self.buildCodeOwned(owner, ui, scope, node);
            return self.buildCodeReference(ui, scope, node);
        }

        fn buildCodeReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (node.children.len != 0) return self.failNode(node.children[0], markup.code_children_message);
            var options: Ui.CodeOptions = .{};
            var source_text: ?[]const u8 = null;
            var added_lines_storage: [canvas.code.max_diff_lines]usize = undefined;
            var removed_lines_storage: [canvas.code.max_diff_lines]usize = undefined;
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "source")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .binding) return self.failNode(node, markup.code_source_message);
                    source_text = switch (try self.evalBinding(scope, node, typed.binding, true)) {
                        .string => |text| text,
                        else => return self.failNode(node, markup.code_source_message),
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "language")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .literal) return self.failNode(node, markup.code_language_message);
                    if (!canvas.code.isLanguageName(typed.literal)) return self.failNode(node, markup.code_language_message);
                    options.language = canvas.code.languageFromName(typed.literal);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "line-numbers")) {
                    options.line_numbers = try self.codeFlagAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "added-lines")) {
                    const typed = markup.parseAttrExpression(attribute.value) orelse
                        return self.failNode(node, markup.code_diff_lines_message);
                    const spec = if (typed == .literal)
                        typed.literal
                    else switch (try self.evalAttrExpression(scope, node, attribute)) {
                        .string => |text| text,
                        else => return self.failNode(node, markup.code_diff_lines_message),
                    };
                    options.added_lines = canvas.code.parseLineNumberSpec(spec, &added_lines_storage) orelse
                        return self.failNode(node, markup.code_diff_lines_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "removed-lines")) {
                    const typed = markup.parseAttrExpression(attribute.value) orelse
                        return self.failNode(node, markup.code_diff_lines_message);
                    const spec = if (typed == .literal)
                        typed.literal
                    else switch (try self.evalAttrExpression(scope, node, attribute)) {
                        .string => |text| text,
                        else => return self.failNode(node, markup.code_diff_lines_message),
                    };
                    options.removed_lines = canvas.code.parseLineNumberSpec(spec, &removed_lines_storage) orelse
                        return self.failNode(node, markup.code_diff_lines_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "editable")) {
                    options.editable = try self.codeFlagAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "on-input")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .message) {
                        return self.failNode(node, "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")");
                    }
                    options.on_input = inputConstructor(typed.message.tag) orelse {
                        return self.failNode(node, "on-input tag must carry a TextInputEvent payload");
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "wrap")) {
                    options.wrap = try self.codeFlagAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "width")) {
                    options.width = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "height")) {
                    options.height = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "min-width")) {
                    options.min_width = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "grow")) {
                    options.grow = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
                    continue;
                }
                return self.failNode(node, markup.code_attr_message);
            }
            return ui.code(options, source_text orelse return self.failNode(node, markup.code_source_message));
        }

        fn codeFlagAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!bool {
            if (attribute.value.len == 0) return true;
            return markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
        }

        // ------------------------------------------------ stepper/timeline

        /// `<stepper active="{stage_index}"><step>Work</step>...</stepper>`:
        /// the composite stage stepper. Steps are text leaves; their
        /// completed/active/pending states derive from position against
        /// the active index, mirroring `Ui.stepper`.
        fn buildStepper(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (scope.expression_policy) |owner| return self.buildStepperOwned(owner, ui, scope, node);
            return self.buildStepperReference(ui, scope, node);
        }

        fn buildStepperReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.StepperOptions = .{};
            var has_active = false;
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "active")) {
                    const value = try self.evalAttrExpression(scope, node, attribute);
                    options.active = switch (value) {
                        .integer => |int| if (int < 0) 0 else @intCast(int),
                        else => return self.failNode(node, markup.stepper_active_message),
                    };
                    has_active = true;
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
                    continue;
                }
                return self.failNode(node, markup.stepper_attr_message);
            }
            if (!has_active) return self.failNode(node, markup.stepper_active_message);

            const is_slotted = node.children.len == 1 and node.children[0].kind == .slot_block;
            const capture = if (is_slotted) scope.slotCapture() else null;
            if (is_slotted and capture == null) return self.failNode(node.children[0], markup.slot_outside_template_message);
            const step_nodes = if (capture) |captured| captured.nodes else node.children;
            const steps = try ui.arena.alloc(Ui.StepperStep, step_nodes.len);
            if (capture) |captured| {
                // Slot content is authored at the use site. Temporarily
                // restore that consumer scope so interpolated step labels
                // see the same loop variables as a direct stepper.
                var saved_entries: [max_scope_depth]ScopeEntry = undefined;
                const saved_len = scope.len;
                const saved_floor = scope.floor;
                const saved_ctx = scope.template_ctx;
                for (scope.entries[captured.len..saved_len], 0..) |entry, offset| saved_entries[offset] = entry;
                scope.len = captured.len;
                scope.floor = captured.floor;
                scope.template_ctx = captured.template_ctx;
                defer {
                    for (saved_entries[0 .. saved_len - captured.len], 0..) |entry, offset| scope.entries[captured.len + offset] = entry;
                    scope.len = saved_len;
                    scope.floor = saved_floor;
                    scope.template_ctx = saved_ctx;
                }
                for (step_nodes, 0..) |child, index| {
                    if (child.kind != .element or !std.mem.eql(u8, child.name, "step")) return self.failNode(child, markup.stepper_children_message);
                    for (child.attrs) |attribute| if (!std.mem.eql(u8, attribute.name, "kind")) return self.failNode(child, markup.step_attr_message);
                    steps[index] = .{ .label = try self.interpolatedText(ui, scope, child) };
                }
            } else {
                for (step_nodes, 0..) |child, index| {
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
            }
            return ui.stepper(options, steps);
        }

        /// `<input-group>` — the composer-grade grouped input: exactly
        /// one textarea child (built through the ordinary element path,
        /// so its text/placeholder/on-input/autofocus behave like any
        /// textarea) plus an optional input-group-actions row, lowered
        /// through `Ui.inputGroup` so the chrome-dissolve and
        /// focus-within treatment match Zig-built groups.
        fn buildInputGroup(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (scope.expression_policy) |owner| return self.buildInputGroupOwned(owner, ui, scope, node);
            return self.buildInputGroupReference(ui, scope, node);
        }

        fn buildInputGroupReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.InputGroupOptions = .{};
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "label")) {
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "width")) {
                    options.width = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "height")) {
                    options.height = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "min-width")) {
                    options.min_width = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "grow")) {
                    options.grow = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                return self.failNode(node, markup.input_group_attr_message);
            }
            // The child shape is static (mirrors the validator): the
            // textarea first, then at most one actions row. Conditional
            // content belongs INSIDE the actions row.
            var entry: ?Ui.Node = null;
            var actions: ?Ui.Node = null;
            for (node.children) |child| {
                if (child.kind != .element) return self.failNode(child, markup.input_group_children_message);
                if (std.mem.eql(u8, child.name, "textarea")) {
                    if (entry != null or actions != null) return self.failNode(child, markup.input_group_children_message);
                    entry = try self.buildElement(ui, scope, child);
                    continue;
                }
                if (std.mem.eql(u8, child.name, "input-group-actions")) {
                    if (entry == null) return self.failNode(child, markup.input_group_textarea_message);
                    if (actions != null) return self.failNode(child, markup.input_group_children_message);
                    actions = try self.buildInputGroupActions(ui, scope, child);
                    continue;
                }
                return self.failNode(child, markup.input_group_children_message);
            }
            const entry_node = entry orelse return self.failNode(node, markup.input_group_textarea_message);
            return ui.inputGroup(options, entry_node, actions);
        }

        /// `<input-group-actions>` — the group's accessory row; children
        /// build through the ordinary pass (structure tags work) and
        /// lower through `Ui.inputGroupActions`.
        fn buildInputGroupActions(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (scope.expression_policy) |owner| return self.buildInputGroupActionsOwned(owner, ui, scope, node);
            return self.buildInputGroupActionsReference(ui, scope, node);
        }

        fn buildInputGroupActionsReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.InputGroupActionsOptions = .{};
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "gap")) {
                    options.gap = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                return self.failNode(node, markup.input_group_actions_attr_message);
            }
            for (node.children) |child| {
                if (child.kind == .text) return self.failNode(child, markup.input_group_actions_children_message);
            }
            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            try self.buildChildren(ui, scope, node, &children);
            return ui.inputGroupActions(options, @as([]const Ui.Node, children.items));
        }

        /// `<timeline gap="4">` — a list container whose children are
        /// timeline-item elements (structure tags work); mirrors
        /// `Ui.timeline`.
        fn buildTimeline(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (scope.expression_policy) |owner| return self.buildTimelineOwned(owner, ui, scope, node);
            return self.buildTimelineReference(ui, scope, node);
        }

        fn buildTimelineReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.TimelineOptions = .{};
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "gap")) {
                    options.gap = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "grow")) {
                    options.grow = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
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
        fn buildTimelineItem(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, forwarded_press: ?MsgT) BuildError!Ui.Node {
            if (scope.expression_policy) |owner| return self.buildTimelineItemOwned(owner, ui, scope, node, forwarded_press);
            return self.buildTimelineItemReference(ui, scope, node, forwarded_press);
        }

        fn buildTimelineItemReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, forwarded_press: ?MsgT) BuildError!Ui.Node {
            if (node.children.len != 0) {
                return self.failNode(node.children[0], markup.timeline_item_children_message);
            }
            var options: Ui.TimelineItemOptions = .{ .title = "" };
            var has_title = false;
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "title")) {
                    options.title = try self.stringAttr(scope, node, attribute, markup.timeline_item_text_attr_message);
                    has_title = true;
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "description")) {
                    options.description = try self.stringAttr(scope, node, attribute, markup.timeline_item_text_attr_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "meta")) {
                    options.meta = try self.stringAttr(scope, node, attribute, markup.timeline_item_text_attr_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "indicator")) {
                    options.indicator = try self.stringAttr(scope, node, attribute, markup.timeline_item_text_attr_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "icon")) {
                    // Vector icon indicator: the shared icon value grammar,
                    // like every icon attribute.
                    switch (markup.iconValueOf(attribute.value, markup.button_icon_message)) {
                        .builtin, .app => |name| options.icon = name,
                        .binding => options.icon = try self.stringAttr(scope, node, attribute, markup.button_icon_message),
                        .invalid => |message| return self.failVoid(node, message),
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "variant")) {
                    const text = try self.stringAttr(scope, node, attribute, "expected an option name");
                    options.variant = std.meta.stringToEnum(canvas.WidgetVariant, text) orelse {
                        return self.failNode(node, "unknown option value");
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "connector")) {
                    options.connector = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "selected")) {
                    options.selected = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
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
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                return self.failNode(node, markup.timeline_item_attr_message);
            }
            if (!has_title) return self.failNode(node, markup.timeline_item_title_message);
            if (forwarded_press) |msg| options.on_press = msg;
            return ui.timelineItem(options);
        }

        // ---------------------------------------------------------- chart

        /// `<chart y-min="0" grid-lines="4"><series kind="area"
        /// values="{cpuHistory}" color="accent"/></chart>`: the
        /// data-visualization composite, lowered through `Ui.chart` so
        /// markup charts get the same downsampling, semantics summary, and
        /// invalidation as Zig-built ones. Series values bind model
        /// iterables of f32 through the SAME resolution set as `for each`
        /// (slice-valued template args included); the series set itself is
        /// static — the data varies, the plot shape does not.
        fn buildChart(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (scope.expression_policy) |owner| return self.buildChartOwned(owner, ui, scope, node);
            return self.buildChartReference(ui, scope, node);
        }

        fn buildChartReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.ChartOptions = .{};
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.startsWith(u8, attribute.name, "on-")) {
                    return self.failNode(node, markup.chart_display_only_message);
                }
                if (std.mem.eql(u8, attribute.name, "y-min")) {
                    options.y_min = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "y-max")) {
                    options.y_max = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "grid-lines")) {
                    const value = try self.evalAttrExpression(scope, node, attribute);
                    options.grid_lines = switch (value) {
                        .integer => |int| if (int < 0 or int > std.math.maxInt(u8))
                            return self.failNode(node, "expected a non-negative whole number")
                        else
                            @intCast(int),
                        else => return self.failNode(node, "expected a whole number"),
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "baseline")) {
                    options.baseline = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "x-labels")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .binding) return self.failNode(node, markup.chart_x_labels_message);
                    options.x_labels = try self.stringItems(ui, scope, node, typed.binding, markup.chart_x_labels_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "y-labels")) {
                    options.y_labels = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "hover-details")) {
                    options.hover_details = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "stroke-width")) {
                    options.stroke_width = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "width")) {
                    options.width = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "height")) {
                    options.height = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "grow")) {
                    options.grow = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "padding")) {
                    options.padding = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
                    continue;
                }
                return self.failNode(node, markup.chart_attr_message);
            }
            if (node.children.len == 0) return self.failNode(node, markup.chart_series_required_message);
            const series = try ui.arena.alloc(canvas.ChartSeries, node.children.len);
            for (node.children, 0..) |child, index| {
                if (child.kind != .element or !std.mem.eql(u8, child.name, "series")) {
                    return self.failNode(child, markup.chart_children_message);
                }
                series[index] = try self.buildSeries(ui, scope, child);
            }
            return ui.chart(options, series);
        }

        // ---------------------------------------------------------- video

        /// `<video src="assets/clips/intro.mp4" controls autoplay/>`:
        /// the video playback composite, lowered through `Ui.video` so
        /// markup videos get the same playback surface, house chrome,
        /// and declaration recording as Zig-built ones. A leaf with a
        /// closed attribute set; flags accept bare presence (the
        /// boolean-attribute convention), literals, and bindings.
        fn buildVideo(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (scope.expression_policy) |owner| return self.buildVideoOwned(owner, ui, scope, node);
            return self.buildVideoReference(ui, scope, node);
        }

        fn buildVideoReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (node.children.len > 0) {
                return self.failNode(node.children[0], markup.video_children_message);
            }
            var options: Ui.VideoOptions = .{};
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "src")) {
                    options.src = try self.stringAttr(scope, node, attribute, markup.video_src_message);
                    continue;
                }
                if (markup.videoFlagAttrName(attribute.name)) {
                    const value = try self.videoFlagAttr(scope, node, attribute);
                    if (std.mem.eql(u8, attribute.name, "controls")) {
                        options.controls = value;
                    } else if (std.mem.eql(u8, attribute.name, "autoplay")) {
                        options.autoplay = value;
                    } else if (std.mem.eql(u8, attribute.name, "loop")) {
                        options.loop = value;
                    } else {
                        options.muted = value;
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "width")) {
                    options.width = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "height")) {
                    options.height = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "grow")) {
                    options.grow = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    options.label = try self.stringAttr(scope, node, attribute, "label expects text");
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                return self.failNode(node, markup.video_attr_message);
            }
            return ui.video(options);
        }

        /// One video flag's value: bare presence declares true, a
        /// valued flag evaluates truthy like every other flag attr.
        fn videoFlagAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!bool {
            if (attribute.value.len == 0) return true;
            return markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
        }

        fn buildSeries(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!canvas.ChartSeries {
            if (scope.expression_policy) |owner| return self.buildSeriesOwned(owner, ui, scope, node);
            return self.buildSeriesReference(ui, scope, node);
        }

        fn buildSeriesReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!canvas.ChartSeries {
            if (node.children.len != 0) {
                return self.failVoid(node.children[0], markup.series_children_message);
            }
            var series = canvas.ChartSeries{};
            var has_values = false;
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) {
                    // Closed literal vocabulary: area is the markup
                    // spelling of a filled line; band stays with the
                    // builder (it needs a paired lower edge).
                    const typed = markup.attrTyped(attribute);
                    if (typed != .literal) return self.failVoid(node, markup.series_kind_message);
                    if (std.mem.eql(u8, typed.literal, "line")) {
                        series.kind = .line;
                    } else if (std.mem.eql(u8, typed.literal, "area")) {
                        series.kind = .line;
                        series.fill = true;
                    } else if (std.mem.eql(u8, typed.literal, "bar")) {
                        series.kind = .bar;
                    } else {
                        return self.failVoid(node, markup.series_kind_message);
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "values")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .binding) return self.failVoid(node, markup.series_values_message);
                    series.values = try self.f32Items(ui, scope, node, typed.binding);
                    has_values = true;
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "color")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .literal) return self.failVoid(node, markup.series_color_message);
                    series.color = std.meta.stringToEnum(canvas.ChartSeriesColor, typed.literal) orelse {
                        return self.failVoid(node, markup.series_color_message);
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    series.label = try self.stringAttr(scope, node, attribute, markup.series_label_message);
                    continue;
                }
                return self.failVoid(node, markup.series_attr_message);
            }
            if (!has_values) return self.failVoid(node, markup.series_values_message);
            return series;
        }

        /// Resolve a series `values` binding to an f32 slice through the
        /// same sources `for each` accepts (scope slice args shadow model
        /// fields, pub decls, and fns). f64 iterables resolve too, copied
        /// down into the build arena per sample: the chart pipeline is
        /// f32, but transpiled TS cores carry every number array as f64
        /// (the subset's one float class), and refusing them would leave
        /// markup charts unreachable from a TS model.
        fn f32Items(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8) BuildError![]const f32 {
            if (scope.expression_policy) |owner| return self.f32ItemsOwned(owner, ui, scope, node, path);
            return self.f32ItemsReference(ui, scope, node, path);
        }

        fn f32ItemsReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8) BuildError![]const f32 {
            @setEvalBranchQuota(scan_quota);
            inline for (item_types, 0..) |Item, type_index| {
                if (comptime (Item == f32)) {
                    if (try self.iterateItems(ui, f32, type_index, scope, path)) |items| {
                        return items;
                    }
                }
                if (comptime (Item == f64)) {
                    if (try self.iterateItems(ui, f64, type_index, scope, path)) |items| {
                        const narrowed = ui.arena.alloc(f32, items.len) catch {
                            return self.failText(node, markup.series_values_message);
                        };
                        for (narrowed, items) |*slot, value| slot.* = @floatCast(value);
                        return narrowed;
                    }
                }
            }
            return self.failText(node, markup.series_values_message);
        }

        fn stringAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr, message: []const u8) BuildError![]const u8 {
            if (scope.expression_policy) |owner| return self.stringAttrOwned(owner, scope, node, attribute, message);
            return self.stringAttrReference(scope, node, attribute, message);
        }

        fn stringAttrReference(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr, message: []const u8) BuildError![]const u8 {
            const value = try self.evalAttrExpression(scope, node, attribute);
            return switch (value) {
                .string => |text| text,
                else => self.failValue(node, message),
            };
        }

        fn floatAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!f32 {
            if (scope.expression_policy) |owner| return self.floatAttrOwned(owner, scope, node, attribute);
            return self.floatAttrReference(scope, node, attribute);
        }

        fn floatAttrReference(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!f32 {
            const value = try self.evalAttrExpression(scope, node, attribute);
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
                if (field.type == usize or field.type == i64) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Md.detailsMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
            }
            return null;
        }

        /// Resolve a string-list binding (chart `x-labels`) to a string
        /// slice through the same sources `for each` accepts (scope slice
        /// args shadow model fields, pub decls, and fns).
        fn stringItems(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8, message: []const u8) BuildError![]const []const u8 {
            if (scope.expression_policy) |owner| return self.stringItemsOwned(owner, ui, scope, node, path, message);
            return self.stringItemsReference(ui, scope, node, path, message);
        }

        fn stringItemsReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8, message: []const u8) BuildError![]const []const u8 {
            @setEvalBranchQuota(scan_quota);
            inline for (item_types, 0..) |Item, type_index| {
                if (comptime (Item == []const u8)) {
                    if (try self.iterateItems(ui, []const u8, type_index, scope, path)) |items| {
                        return items;
                    }
                }
            }
            return self.failText(node, message);
        }

        /// Resolve a `details-expanded` binding to a bool slice through the
        /// same sources `for each` accepts (scope slice args shadow model
        /// fields, pub decls, and fns).
        fn boolItems(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8) BuildError![]const bool {
            if (scope.expression_policy) |owner| return self.boolItemsOwned(owner, ui, scope, node, path);
            return self.boolItemsReference(ui, scope, node, path);
        }

        fn boolItemsReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8) BuildError![]const bool {
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

        /// Resolve Markdown's registered source-to-image mapping through the
        /// same bounded iterable reflection used by `for each`.
        fn markdownImageItems(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8) BuildError![]const canvas.markdown.ResolvedImage {
            if (scope.expression_policy) |owner| return self.markdownImageItemsOwned(owner, ui, scope, node, path);
            return self.markdownImageItemsReference(ui, scope, node, path);
        }

        fn markdownImageItemsReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8) BuildError![]const canvas.markdown.ResolvedImage {
            @setEvalBranchQuota(scan_quota);
            inline for (item_types, 0..) |Item, type_index| {
                if (comptime (reflect.isMarkdownImageItem(Item))) {
                    if (try self.iterateItems(ui, Item, type_index, scope, path)) |items| {
                        return @import("markdown_image_binding.zig").convert(ui.arena, items) catch return self.failText(node, markup.markdown_images_message);
                    }
                }
            }
            return self.failText(node, markup.markdown_images_message);
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
            if (scope.expression_policy) |owner| return self.buildUseOwned(owner, ui, scope, node);
            return self.buildUseReference(ui, scope, node);
        }

        fn buildUseReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
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
                if (std.mem.eql(u8, attribute.name, "on-press")) continue;
                if (std.mem.startsWith(u8, attribute.name, "on-")) {
                    return self.failNode(node, markup.use_forwarded_event_message);
                }
                if (!markup.templateDeclaresArg(template_node, attribute.name)) {
                    return self.failNode(node, markup.use_extra_arg_message);
                }
            }

            const forwarded_press = if (node.attrEntry("on-press")) |attribute| blk: {
                var scratch: Ui.ElementOptions = .{};
                try self.applyMessageAttr(scope, node, &scratch, attribute);
                break :blk scratch.on_press;
            } else null;

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
                const payload: ScopeEntry.Payload = if (node.attrEntry(arg.name)) |arg_attr|
                    try self.argPayload(ui, scope, node, arg_attr)
                else if (arg.default) |default| blk: {
                    // Defaults are literals only — a default cannot see
                    // any scope (validator and compiled-engine parity).
                    if (std.mem.indexOfScalar(u8, default, '{') != null) {
                        return self.failNode(template_node, markup.template_default_literal_message);
                    }
                    // Quotes are not string delimiters in a default; they
                    // would render verbatim (validator parity).
                    if (default.len > 0 and (default[0] == '\'' or default[0] == '"')) {
                        return self.failNode(template_node, markup.template_default_quoted_message);
                    }
                    break :blk .{ .value = literalValue(default) };
                } else return self.failNode(node, markup.use_missing_arg_message);
                scope.entries[saved_len + arg_count] = .{
                    .name = arg.name,
                    .payload = payload,
                    .defaulted = node.attrEntry(arg.name) == null and arg.default != null,
                };
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
                    .chain = scope.source_chain,
                } },
            };
            arg_count += 1;

            scope.len = saved_len + arg_count;
            scope.floor = saved_len;
            scope.use_depth += 1;
            scope.template_ctx = template_index;
            // Provenance: the template body's nodes report this use site
            // (appended to any outer chain) alongside their definition
            // site, so "jump to its markup" can offer both.
            const saved_chain = scope.source_chain;
            if (ui.provenance_sink != null) {
                const chain = try ui.arena.alloc(ui_provenance.UseSite, saved_chain.len + 1);
                @memcpy(chain[0..saved_chain.len], saved_chain);
                chain[saved_chain.len] = .{
                    .src_path = node.src_path,
                    .span = node.span,
                    .line = node.line,
                    .column = node.column,
                };
                scope.source_chain = chain;
            }
            defer {
                scope.len = saved_len;
                scope.floor = saved_floor;
                scope.use_depth -= 1;
                scope.template_ctx = saved_ctx;
                scope.source_chain = saved_chain;
            }
            return self.buildElementForwardedPress(ui, scope, template_node.children[0], forwarded_press);
        }

        /// A template arg's scope payload: a `{binding}` naming an iterable
        /// (in scope or on the model, the same resolution set as
        /// `for each`) binds as a slice; anything else evaluates to a
        /// `Value` at the use site.
        fn argPayload(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!ScopeEntry.Payload {
            if (scope.expression_policy) |owner| return self.argPayloadOwned(owner, ui, scope, node, attribute);
            return self.argPayloadReference(ui, scope, node, attribute);
        }

        fn argPayloadReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!ScopeEntry.Payload {
            @setEvalBranchQuota(scan_quota);
            const typed = markup.attrTyped(attribute);
            if (typed == .invalid) {
                return self.failPayload(node, markup.invalid_expression_message);
            }
            if (typed == .binding) {
                const path = typed.binding;
                if (scope.lookup(pathHead(path))) |entry| {
                    if ((entry.payload == .slice or entry.payload == .virtual) and pathTail(path) == null) {
                        // Re-pass an iterable or retained window to a nested use.
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
            return .{ .value = try self.evalUnclassifiedExpression(scope, node, attribute) };
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
                // Keys are identity, not quantities: a negative integer
                // id (an i64 database id, a -1 sentinel) is a distinct,
                // legitimate identity, so it maps bijectively into the
                // u64 key space instead of trapping in a signed cast.
                .integer => |int| canvas.uiKey(@as(u64, @bitCast(int))),
                .string => |text| canvas.uiKey(text),
                else => self.failKey(node, "key fields must be integers or strings"),
            };
        }

        // ---------------------------------------------------- attributes

        fn applyAttrs(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions) BuildError!void {
            if (scope.expression_policy) |owner| return self.applyAttrsOwned(owner, scope, node, options);
            return self.applyAttrsReference(scope, node, options);
        }

        fn applyAttrsReference(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions) BuildError!void {
            try self.applyImageSourceAttrs(scope, node, options);
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.startsWith(u8, attribute.name, "on-")) {
                    try self.applyMessageAttr(scope, node, options, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "focusable")) {
                    options.semantics.focusable = switch (try self.evalAttrExpression(scope, node, attribute)) {
                        .boolean => |flag| flag,
                        else => return self.failVoid(node, "focusable expects a boolean"),
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "role")) {
                    const value = try self.evalAttrExpression(scope, node, attribute);
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
                    const value = try self.evalAttrExpression(scope, node, attribute);
                    options.semantics.label = switch (value) {
                        .string => |text| text,
                        else => return self.failVoid(node, "label expects text"),
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "image")) {
                    try self.applyImageAttr(scope, node, options, attribute);
                    continue;
                }
                if (markup.imageSourceAttrName(attribute.name)) continue;
                if (std.mem.eql(u8, attribute.name, "surface")) {
                    try self.applySurfaceAttr(scope, node, options, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "pty")) {
                    try self.applyPtyAttr(scope, node, options, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "scrollback") and !std.mem.eql(u8, node.name, "terminal")) {
                    // Terminal-scoped (the validator's rule, enforced
                    // here too for unvalidated paths): anywhere else the
                    // option would be silently inert data.
                    return self.failVoid(node, markup.scrollback_element_message);
                }
                if (std.mem.eql(u8, attribute.name, "text") and std.mem.eql(u8, node.name, "terminal")) {
                    // The terminal's text channel is runtime-owned (the
                    // live screen); an authored value would clobber it
                    // and rename the control every frame.
                    return self.failVoid(node, markup.terminal_text_attr_message);
                }
                if (markup.videoFlagAttrName(attribute.name)) {
                    // The video element's flags, video-scoped (its own
                    // build consumed them): anywhere else they would be
                    // silently inert. Mirrors the validator and the
                    // compiled engine.
                    return self.failVoid(node, markup.video_flag_element_message);
                }
                if (std.mem.eql(u8, attribute.name, "name")) {
                    // Consumed by the icon branch in buildElement.
                    if (!std.mem.eql(u8, node.name, "icon")) {
                        return self.failVoid(node, markup.icon_name_element_message);
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "icon")) {
                    try self.applyButtonIconAttr(scope, node, options, attribute);
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
                if (std.mem.eql(u8, attribute.name, "quiet-hover")) {
                    try self.applyQuietHoverAttr(scope, node, options, attribute);
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
                    const literal = try self.styleTokenLiteral(node, attribute);
                    @field(options.style_tokens, entry.zig) = std.meta.stringToEnum(canvas.ColorTokenName, literal) orelse {
                        return self.failVoid(node, markup.unknown_color_token_message);
                    };
                    return true;
                }
            }
            if (std.mem.eql(u8, attribute.name, "radius")) {
                const literal = try self.styleTokenLiteral(node, attribute);
                options.style_tokens.radius = std.meta.stringToEnum(canvas.RadiusTokenName, literal) orelse {
                    return self.failVoid(node, markup.unknown_radius_token_message);
                };
                return true;
            }
            return false;
        }

        fn styleTokenLiteral(self: *Self, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError![]const u8 {
            return switch (markup.attrTyped(attribute)) {
                .literal => |text| text,
                else => self.failPayload(node, markup.style_token_literal_message),
            };
        }

        /// `image="{binding}"` on avatar and image: one binding
        /// producing a `u64` `canvas.ImageId` the app registered at
        /// runtime (`Cmd.imageLoad`, `fx.loadImage`,
        /// `fx.registerImageBytes`) — the id is model data, never a
        /// markup literal, and 0 draws nothing (an avatar keeps its
        /// initials fallback). Image-backed buttons remain a separate
        /// asset-lifecycle proposal.
        fn applyImageAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (scope.expression_policy) |owner| return self.resourceAttrOwned(owner, scope, node, options, attribute, 0);
            return self.applyImageAttrReference(scope, node, options, attribute);
        }

        fn applyImageAttrReference(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (!std.mem.eql(u8, node.name, "avatar") and !std.mem.eql(u8, node.name, "image")) {
                return self.failVoid(node, markup.image_binding_element_message);
            }
            const typed = markup.attrTyped(attribute);
            if (typed != .binding) return self.failVoid(node, markup.image_binding_message);
            const value = try self.evalBinding(scope, node, typed.binding, true);
            // Range-checked before the u64 cast: expression values are
            // i64, so a signed model field (`image: i64 = -1`) can
            // deliver a negative — the teaching failure, never a trap.
            options.image = switch (value) {
                .integer => |int| if (int < 0)
                    return self.failVoid(node, markup.image_binding_message)
                else
                    @intCast(int),
                else => return self.failVoid(node, markup.image_binding_message),
            };
        }

        /// The four `source-*` attributes form one optional source
        /// rectangle in decoded-image pixel coordinates. Build it before
        /// the scalar attribute walk so declaration order carries no
        /// meaning; repeat the validator's shape checks for hot-reloaded
        /// documents that reached the interpreter without validation.
        fn applyImageSourceAttrs(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions) BuildError!void {
            if (scope.expression_policy) |owner| return self.applyImageSourceAttrsOwned(owner, scope, node, options);
            return self.applyImageSourceAttrsReference(scope, node, options);
        }

        fn applyImageSourceAttrsReference(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions) BuildError!void {
            var any = false;
            for (markup.image_source_attr_names) |name| {
                if (node.attr(name) != null) any = true;
            }
            if (!any) return;
            if (!std.mem.eql(u8, node.name, "avatar") and !std.mem.eql(u8, node.name, "image")) {
                return self.failVoid(node, markup.image_source_element_message);
            }
            if (node.attr("image") == null) return self.failVoid(node, markup.image_source_binding_message);
            for (markup.image_source_attr_names) |name| {
                if (node.attr(name) == null) return self.failVoid(node, markup.image_source_complete_message);
            }
            options.image_src = .{
                .x = try self.floatAttr(scope, node, node.attrEntry("source-x").?),
                .y = try self.floatAttr(scope, node, node.attrEntry("source-y").?),
                .width = try self.floatAttr(scope, node, node.attrEntry("source-width").?),
                .height = try self.floatAttr(scope, node, node.attrEntry("source-height").?),
            };
        }

        /// `surface="{binding}"` on media-surface: the model-owned u64
        /// surface id a producer targets — media-surface-only,
        /// binding-only, integer-valued (the runtime-image-id grammar
        /// exactly). The id rides `options.image` into
        /// `Widget.image_id`, the media surface's surface-id channel.
        fn applySurfaceAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (scope.expression_policy) |owner| return self.resourceAttrOwned(owner, scope, node, options, attribute, 1);
            return self.applySurfaceAttrReference(scope, node, options, attribute);
        }

        fn applySurfaceAttrReference(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (!std.mem.eql(u8, node.name, "media-surface")) {
                return self.failVoid(node, markup.media_surface_surface_element_message);
            }
            const typed = markup.attrTyped(attribute);
            if (typed != .binding) return self.failVoid(node, markup.media_surface_surface_message);
            const value = try self.evalBinding(scope, node, typed.binding, true);
            // Range-checked before the u64 cast: expression values are
            // i64, so a signed model field (`surface: i64 = -1`) can
            // deliver a negative — the teaching failure, never a trap.
            options.image = switch (value) {
                .integer => |int| if (int < 0)
                    return self.failVoid(node, markup.media_surface_surface_message)
                else
                    @intCast(int),
                else => return self.failVoid(node, markup.media_surface_surface_message),
            };
        }

        /// `pty="{binding}"` on terminal: the model-owned u64 pty effect
        /// key whose session the terminal renders — terminal-only,
        /// binding-only, integer-valued (the media-surface `surface`
        /// grammar exactly). The key rides `options.pty` into
        /// `Widget.terminal.pty`.
        fn applyPtyAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (scope.expression_policy) |owner| return self.resourceAttrOwned(owner, scope, node, options, attribute, 2);
            return self.applyPtyAttrReference(scope, node, options, attribute);
        }

        fn applyPtyAttrReference(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (!std.mem.eql(u8, node.name, "terminal")) {
                return self.failVoid(node, markup.terminal_pty_element_message);
            }
            const typed = markup.attrTyped(attribute);
            if (typed != .binding) return self.failVoid(node, markup.terminal_pty_message);
            const value = try self.evalBinding(scope, node, typed.binding, true);
            // Range-checked before the u64 cast: expression values are
            // i64, so a signed model field can deliver a negative — the
            // teaching failure, never a trap.
            switch (value) {
                .integer => |int| options.pty = if (int < 0) return self.failVoid(node, markup.terminal_pty_message) else @intCast(int),
                .string => |name| options.pty_name = name,
                else => return self.failVoid(node, markup.terminal_pty_message),
            }
        }

        /// `icon="save"` on button, toggle-button, list-item, or
        /// menu-item: the same icon value grammar as `<icon name>` — a
        /// built-in literal can never rot silently, app:<name> and one
        /// {binding} defer to the registered set and the model — drawn
        /// inside the element so icon + label are one hit target with one
        /// tint. Mirrors the validator and the compiled engine.
        fn applyButtonIconAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (scope.expression_policy) |owner| return self.applyButtonIconAttrOwned(owner, scope, node, options, attribute);
            return self.applyButtonIconAttrReference(scope, node, options, attribute);
        }

        fn applyButtonIconAttrReference(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (!markup.iconAttrElement(node.name)) {
                return self.failVoid(node, markup.button_icon_element_message);
            }
            switch (markup.iconValueOf(attribute.value, markup.button_icon_message)) {
                .builtin, .app => |name| options.icon = name,
                .binding => options.icon = try self.stringAttr(scope, node, attribute, markup.button_icon_message),
                .invalid => |message| return self.failVoid(node, message),
            }
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

        /// `quiet-hover="true"` on a hit-target element: the quiet-surface
        /// knob (`WidgetStyle.quiet_hover`) for image-forward content
        /// tiles — silences ONLY the hover wash; press/selection fills,
        /// the focus ring, cursor intent, and hit testing keep their own
        /// channels. Applied to `options.style`, so no flat option field
        /// backs it (mirrors the validator and the compiled engine).
        fn applyQuietHoverAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (scope.expression_policy) |owner| return self.applyQuietHoverAttrOwned(owner, scope, node, options, attribute);
            return self.applyQuietHoverAttrReference(scope, node, options, attribute);
        }

        fn applyQuietHoverAttrReference(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (!markup.hitTargetElement(node.name)) {
                return self.failVoid(node, markup.quiet_hover_element_message);
            }
            const value = try self.evalAttrExpression(scope, node, attribute);
            options.style.quiet_hover = markup.expr.truthyWithPolicy(scope.expression_policy, value);
        }

        fn applyOptionAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!bool {
            inline for (attr_names) |name| {
                if (std.mem.eql(u8, attribute.name, name.markup)) {
                    try self.setOptionField(scope, node, options, name.zig, attribute);
                    return true;
                }
            }
            return false;
        }

        fn setOptionField(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, comptime field: []const u8, attribute: markup.MarkupAttr) BuildError!void {
            if (scope.expression_policy) |owner| return self.setOptionFieldOwned(owner, scope, node, options, field, attribute);
            return self.setOptionFieldReference(scope, node, options, field, attribute);
        }

        fn setOptionFieldReference(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, comptime field: []const u8, attribute: markup.MarkupAttr) BuildError!void {
            const FieldType = @TypeOf(@field(options, field));
            const value = try self.evalAttrExpression(scope, node, attribute);
            switch (@typeInfo(FieldType)) {
                .float => @field(options, field) = switch (value) {
                    .float => |float| float,
                    .integer => |int| @floatFromInt(int),
                    else => return self.failVoid(node, "expected a number"),
                },
                .bool => @field(options, field) = markup.expr.truthyWithPolicy(scope.expression_policy, value),
                .optional => |optional| switch (@typeInfo(optional.child)) {
                    .bool => @field(options, field) = markup.expr.truthyWithPolicy(scope.expression_policy, value),
                    .@"enum" => {
                        const text = switch (value) {
                            .string => |text| text,
                            else => return self.failVoid(node, "expected an option name"),
                        };
                        @field(options, field) = std.meta.stringToEnum(optional.child, text) orelse
                            return self.failVoid(node, "unknown option value");
                    },
                    .float => @field(options, field) = switch (value) {
                        .float => |float| float,
                        .integer => |int| @floatFromInt(int),
                        else => return self.failVoid(node, "expected a number"),
                    },
                    else => return self.failVoid(node, "attribute is not settable from markup"),
                },
                // Range-checked against the FIELD's own integer type
                // before the cast (the grid-lines teaching, generalized):
                // expression values are i64, so a literal or model
                // binding can deliver 2147483648 to the i32
                // tooltip-delay — an unchecked @intCast TRAPPED on it
                // instead of failing the build. The field type is the
                // honest upper bound: no semantic millisecond cap is
                // invented on top of it, matching resize-duration, whose
                // only bound is likewise its u32.
                .int => @field(options, field) = switch (value) {
                    .integer => |int| if (int < 0 or int > std.math.maxInt(FieldType))
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

        fn attrKey(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!?canvas.UiKey {
            if (scope.expression_policy) |owner| return self.attrKeyOwned(owner, scope, node, attribute);
            return self.attrKeyReference(scope, node, attribute);
        }

        fn attrKeyReference(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!?canvas.UiKey {
            const omitted_default = switch (markup.attrTyped(attribute)) {
                .binding => |path| if (scope.lookup(pathHead(path))) |entry|
                    entry.defaulted and pathTail(path) == null
                else
                    false,
                else => false,
            };
            const value = try self.evalAttrExpression(scope, node, attribute);
            return switch (value) {
                // Bijective like itemKey: a negative integer key is a
                // distinct identity, never a trap.
                .integer => |int| canvas.uiKey(@as(u64, @bitCast(int))),
                // Empty defaults are the template-language spelling for an
                // omitted optional key. This lets ejected templates forward
                // key/global-key without changing unkeyed identity.
                .string => |text| if (text.len == 0 and omitted_default) null else canvas.uiKey(text),
                else => self.failKey(node, "keys must be integers or strings"),
            };
        }

        fn applyMessageAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (scope.expression_policy) |owner| return self.applyMessageAttrOwned(owner, scope, node, options, attribute);
            return self.applyMessageAttrReference(scope, node, options, attribute);
        }

        fn applyMessageAttrReference(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            const typed = markup.attrTyped(attribute);
            if (typed != .message) {
                return self.failVoid(node, "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")");
            }
            const expression = typed.message;
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
                    // The retired one-axis record gets the migration
                    // teaching (it names the new per-axis fields) instead
                    // of the generic payload rejection.
                    if (legacyScrollTag(expression.tag)) {
                        return self.failVoid(node, markup.on_scroll_legacy_payload_message);
                    }
                    return self.failVoid(node, markup.on_scroll_payload_message);
                };
                return;
            }
            if (std.mem.eql(u8, event, "terminal")) {
                if (!std.mem.eql(u8, node.name, "terminal")) {
                    return self.failVoid(node, markup.on_terminal_element_message);
                }
                // Bare tag only: the runtime supplies the TerminalState,
                // so an authored payload would be silently discarded.
                if (expression.payload.len > 0) return self.failVoid(node, markup.on_terminal_payload_message);
                options.on_terminal = terminalConstructor(expression.tag) orelse {
                    return self.failVoid(node, markup.on_terminal_payload_message);
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
            if (std.mem.eql(u8, event, "drag")) {
                options.on_drag = try self.constructDragMessage(scope, node, expression);
                return;
            }
            // The value-payload change event: a slider's `on-change` with a
            // bare tag naming a value-carrying arm dispatches the APPLIED
            // value through the `on_value` constructor (the `on-resize`
            // fraction mechanism) instead of a static Msg. Void arms keep
            // the static form below, so `on-change="volume_changed"` on a
            // slider still means "something changed" when the arm carries
            // nothing.
            if (std.mem.eql(u8, event, "change") and std.mem.eql(u8, node.name, "slider") and expression.payload.len == 0) {
                if (valueConstructor(expression.tag)) |make| {
                    options.on_value = make;
                    return;
                }
            }
            const msg = try self.constructMessage(scope, node, expression);
            if (std.mem.eql(u8, event, "press")) {
                options.on_press = msg;
            } else if (std.mem.eql(u8, event, "double-press")) {
                options.on_double_press = msg;
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
            } else if (std.mem.eql(u8, event, "hover-enter")) {
                // Hover family: binding either edge makes any element
                // hover-hittable (never pressable), so both are legal
                // everywhere like the press family.
                options.on_hover_enter = msg;
            } else if (std.mem.eql(u8, event, "hover-leave")) {
                options.on_hover_leave = msg;
            } else if (std.mem.eql(u8, event, "reach-start") and std.mem.eql(u8, node.name, "scroll")) {
                options.on_reach_start = msg;
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
            if (scope.expression_policy) |owner| return self.constructMessageOwned(owner, scope, node, expression, false);
            return self.constructMessageReference(scope, node, expression);
        }

        fn constructMessageReference(self: *Self, scope: *Scope, node: markup.MarkupNode, expression: markup.MessageExpression) BuildError!MsgT {
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
                    return @unionInit(MsgT, field.name, try self.coerce(scope, field.type, node, value));
                }
            }
            return self.failMsg(node, "unknown message tag");
        }

        fn constructDragMessage(self: *Self, scope: *Scope, node: markup.MarkupNode, expression: markup.MessageExpression) BuildError!MsgT {
            if (scope.expression_policy) |owner| return self.constructMessageOwned(owner, scope, node, expression, true);
            return self.constructDragMessageReference(scope, node, expression);
        }

        fn constructDragMessageReference(self: *Self, scope: *Scope, node: markup.MarkupNode, expression: markup.MessageExpression) BuildError!MsgT {
            if (expression.payload.len == 0) return self.failMsg(node, markup.on_drag_payload_message);
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (std.mem.eql(u8, field.name, expression.tag)) {
                    if (comptime !reflect.declaredWidgetDragDropRecord(field.type)) return self.failMsg(node, markup.on_drag_payload_message);
                    const value = try self.evalBinding(scope, node, expression.payload, true);
                    var payload: field.type = std.mem.zeroes(field.type);
                    payload.sourceId = try self.coerce(scope, @FieldType(field.type, "sourceId"), node, value);
                    return @unionInit(MsgT, field.name, payload);
                }
            }
            return self.failMsg(node, markup.on_drag_payload_message);
        }

        fn coerce(self: *Self, scope: *Scope, comptime T: type, node: markup.MarkupNode, value: Value) BuildError!T {
            if (scope.expression_policy) |owner| return self.coerceOwned(owner, scope, T, node, value);
            return self.coerceReference(scope, T, node, value);
        }

        fn coerceReference(self: *Self, scope: *Scope, comptime T: type, node: markup.MarkupNode, value: Value) BuildError!T {
            return switch (@typeInfo(T)) {
                // Range-checked against the payload's own integer type
                // before the cast (the option-attribute pattern): a
                // binding's i64 can deliver a negative to an unsigned
                // payload or overflow a small one — the teaching
                // failure, never a trap. Signed payloads keep their
                // negative range (minInt is the honest lower bound).
                .int => switch (value) {
                    .integer => |int| if (int < std.math.minInt(T) or int > std.math.maxInt(T))
                        self.failCoerce(T, node)
                    else
                        @intCast(int),
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
                .bool => markup.expr.truthyWithPolicy(scope.expression_policy, value),
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
                } else if (comptime reflect.declaredTextInputUnion(field.type)) {
                    // A declared mirror of the event union (transpiled
                    // cores): translated at dispatch, same handler shape.
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.translatedInputMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
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
                } else if (comptime reflect.declaredScrollStateRecord(field.type)) {
                    // A declared mirror of the scroll-state record
                    // (transpiled cores): translated at dispatch, same
                    // handler shape.
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.translatedScrollMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                    }
                }
            }
            return null;
        }

        fn terminalConstructor(tag: []const u8) ?Ui.TerminalMsgFn {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (field.type == canvas.TerminalState) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.terminalMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                } else if (comptime reflect.declaredTerminalStateRecord(field.type)) {
                    // A declared mirror of the terminal-state record
                    // (transpiled cores): translated at dispatch, same
                    // handler shape.
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.translatedTerminalMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                    }
                }
            }
            return null;
        }

        /// Whether `tag` names an arm carrying the RETIRED one-axis
        /// scroll record — recognized only so the on-scroll rejection
        /// can teach the two-axis migration by field name.
        fn legacyScrollTag(tag: []const u8) bool {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (comptime reflect.declaredLegacyScrollStateRecord(field.type)) {
                    if (std.mem.eql(u8, field.name, tag)) return true;
                }
            }
            return false;
        }

        fn resizeConstructor(tag: []const u8) ?Ui.ValueMsgFn {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (field.type == f32) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.valueMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                } else if (field.type == f64) {
                    // A declared one-number float arm (transpiled cores,
                    // where f32 cannot be spelled): the fraction widens
                    // exactly at dispatch. Integer arms stay excluded —
                    // a 0..1 fraction rounded into an integer would be
                    // silently useless data.
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.translatedValueMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                    }
                }
            }
            return null;
        }

        /// The slider `on-change` value form: an arm carrying the applied
        /// 0..1 fraction as `f32` (the canvas-native shape) or the
        /// transpiled one-number float arm (`f64`, widened exactly).
        fn valueConstructor(tag: []const u8) ?Ui.ValueMsgFn {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                const class = comptime reflect.valueArmClass(field.type);
                if (comptime class != null) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return switch (comptime class.?) {
                            .identity => Ui.valueMsg(@field(std.meta.Tag(MsgT), field.name)),
                            .float => Ui.translatedValueMsg(@field(std.meta.Tag(MsgT), field.name), field.type),
                        };
                    }
                }
            }
            return null;
        }

        // --------------------------------------------------- expressions

        /// Evaluate an attribute's TYPED value: the canonicalized form
        /// classified (and its expression tree parsed) once at document
        /// level, not per frame per use — the typed-document pass's whole
        /// point for the interpreter.
        fn evalAttributeExpression(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr, attribute_aware: bool) BuildError!Value {
            if (scope.expression_policy) |owner| return self.evalAttributeExpressionOwned(owner, scope, node, attribute, attribute_aware);
            return self.evalAttributeExpressionReference(scope, node, attribute, attribute_aware);
        }

        fn evalAttributeExpressionReference(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr, attribute_aware: bool) BuildError!Value {
            return switch (markup.attrTyped(attribute)) {
                .literal => |text| if (attribute_aware)
                    literalValueForAttribute(text, attribute.name)
                else
                    literalValue(text),
                .binding => |path| try self.evalBinding(scope, node, path, true),
                // Arena-computed bindings are excluded from equality on
                // purpose: comparing freshly formatted strings is a smell —
                // compare the source fields, or bind a bool-returning fn.
                .equals => |sides| .{ .boolean = markup.expr.equalWithPolicy(
                    scope.expression_policy,
                    try self.evalBinding(scope, node, sides.left, false),
                    try self.evalBinding(scope, node, sides.right, false),
                ) },
                .expression => |form| try self.evalExpressionForm(scope, node, form),
                .message, .invalid => self.failValue(node, markup.invalid_expression_message),
            };
        }

        fn evalAttrExpression(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!Value {
            return self.evalAttributeExpression(scope, node, attribute, true);
        }

        fn evalUnclassifiedExpression(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!Value {
            return self.evalAttributeExpression(scope, node, attribute, false);
        }

        /// A typed expression: use the pre-parsed tree when the pass
        /// stamped one; a missing tree means the text does not parse (or
        /// the document was never canonicalized), and the re-parse
        /// surfaces the exact teaching diagnostic.
        fn evalExpressionForm(self: *Self, scope: *Scope, node: markup.MarkupNode, form: markup.TypedExprRef) BuildError!Value {
            if (scope.expression_policy) |owner| return self.evalExpressionFormOwned(owner, scope, node, form);
            return self.evalExpressionFormReference(scope, node, form);
        }

        fn evalExpressionFormReference(self: *Self, scope: *Scope, node: markup.MarkupNode, form: markup.TypedExprRef) BuildError!Value {
            if (form.tree) |tree| return self.evalParsedTree(scope, node, tree);
            return self.evalExpressionTree(scope, node, form.inner);
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
            if (!markup.expr.parseWithPolicy(scope.expression_policy, inner, &tree, &diagnostic)) {
                return self.failValue(node, diagnostic.message);
            }
            return self.evalParsedTree(scope, node, &tree);
        }

        fn evalParsedTree(self: *Self, scope: *Scope, node: markup.MarkupNode, tree: *const markup.expr.ExprTree) BuildError!Value {
            if (scope.expression_policy) |owner| return self.evalParsedTreeOwned(owner, scope, node, tree);
            return self.evalParsedTreeReference(scope, node, tree);
        }

        fn evalParsedTreeReference(self: *Self, scope: *Scope, node: markup.MarkupNode, tree: *const markup.expr.ExprTree) BuildError!Value {
            var values: [markup.expr.max_expression_nodes]Value = undefined;
            for (tree.nodes[0..tree.len], 0..) |expr_node, index| {
                if (expr_node.kind != .binding) continue;
                // Comparison operands reject arena-computed scalars, the
                // same teaching rule as `{a == b}`.
                values[index] = try self.evalBinding(scope, node, expr_node.text, !expr_node.comparison_operand);
            }
            return switch (try markup.expr.evalWithPolicy(scope.expression_policy, tree, &values, scope.arena)) {
                .value => |value| value,
                .fail => |message| self.failValue(node, message),
            };
        }

        /// Resolve a binding path to a `Value`. `allow_arena` gates the
        /// arena-taking scalar fn form (allowed everywhere a scalar binding
        /// is — text interpolation, attribute values, message payloads —
        /// except inside `{a == b}` equality).
        fn evalBinding(self: *Self, scope: *Scope, node: markup.MarkupNode, path: []const u8, allow_arena: bool) BuildError!Value {
            if (scope.expression_policy) |owner| return self.evalBindingOwned(owner, scope, node, path, allow_arena);
            return self.evalBindingReference(scope, node, path, allow_arena);
        }

        fn evalBindingReference(self: *Self, scope: *Scope, node: markup.MarkupNode, path: []const u8, allow_arena: bool) BuildError!Value {
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
                    .virtual => |window| {
                        const tail = pathTail(path) orelse return self.failValue(node, "virtual window requires a range field");
                        return resolveOn(canvas.VirtualListRange, &window.range, tail, null) orelse self.failValue(node, "unknown virtual range field");
                    },
                    // Slot captures carry an empty name, which no binding
                    // head can equal.
                    .slot => unreachable,
                }
            }
            if (resolveOn(ModelT, scope.model, path, arena)) |value| return value;
            if (!allow_arena and resolveOn(ModelT, scope.model, path, scope.arena) != null) {
                return self.failValue(node, markup.arena_scalar_equality_message);
            }
            if (fieldIsTextBuffer(ModelT, head)) {
                return self.failValue(node, markup.binding_text_buffer_message);
            }
            return self.failValue(node, "binding does not name a model field");
        }

        // ------------------------------------------------ span paragraphs

        /// A `<text>` with inline `<span>` children: the span paragraph.
        /// Each content child lowers to one `canvas.TextSpan` — plain runs
        /// (single-space separators the parser spliced included) keep the
        /// paragraph style, span children carry their own weight, mono,
        /// italic, and foreground — and the list lowers through
        /// `Ui.paragraph`, so byte rebasing, span-aware wrapping, and
        /// semantics match a builder span paragraph exactly: the widget
        /// announces as ONE text run (spans are visual, never semantic
        /// children). Mirrors the validator and the compiled engine.
        fn buildSpanParagraph(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, options: Ui.ElementOptions) BuildError!Ui.Node {
            if (scope.expression_policy) |owner| return self.buildSpanParagraphOwned(owner, ui, scope, node, options);
            return self.buildSpanParagraphReference(ui, scope, node, options);
        }

        fn buildSpanParagraphReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, options: Ui.ElementOptions) BuildError!Ui.Node {
            // A span paragraph always word-wraps (builder parity), so the
            // single-line policies are dead data here. Mirrors the
            // validator and the compiled engine's compile error.
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "wrap") or std.mem.eql(u8, attribute.name, "overflow")) {
                    return self.failNode(node, markup.span_paragraph_wrap_message);
                }
            }
            const spans = try ui.arena.alloc(canvas.TextSpan, node.children.len);
            var len: usize = 0;
            for (node.children) |child| {
                if (child.kind == .text) {
                    spans[len] = .{ .text = try self.runText(ui, scope, node, child) };
                    len += 1;
                    continue;
                }
                if (!markup.nodeIsSpan(child)) return self.failNode(child, markup.text_inline_children_message);
                spans[len] = try self.buildSpan(ui, scope, child);
                len += 1;
            }
            return ui.paragraph(options, spans[0..len]);
        }

        /// One `<span>`: the shared shape check (closed attribute set,
        /// exactly one run, no nesting), then the style channels resolved
        /// against the scope — weight, scale, and the flags take bindings
        /// like any option attribute, foreground stays a literal token
        /// name. A bound scale is held to the same positive-finite bound
        /// the validator pins for literals: the engine draws anything
        /// else at the base size, and a silently dead binding is worse
        /// than a diagnostic.
        fn buildSpan(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!canvas.TextSpan {
            if (scope.expression_policy) |owner| return self.buildSpanOwned(owner, ui, scope, node);
            return self.buildSpanReference(ui, scope, node);
        }

        fn buildSpanReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!canvas.TextSpan {
            if (markup.spanShapeError(node)) |info| {
                self.diagnostic = .{ .line = info.line, .column = info.column, .message = info.message, .path = info.path };
                return error.MarkupBuild;
            }
            var span = canvas.TextSpan{};
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "weight")) {
                    const text = try self.stringAttr(scope, node, attribute, markup.span_weight_value_message);
                    span.weight = std.meta.stringToEnum(canvas.TextSpanWeight, text) orelse {
                        return self.failValue(node, markup.span_weight_value_message);
                    };
                } else if (std.mem.eql(u8, attribute.name, "scale")) {
                    const multiplier = switch (try self.evalAttrExpression(scope, node, attribute)) {
                        .float => |float| float,
                        .integer => |int| @as(f32, @floatFromInt(int)),
                        else => return self.failValue(node, markup.span_scale_value_message),
                    };
                    if (!std.math.isFinite(multiplier) or multiplier <= 0) {
                        return self.failValue(node, markup.span_scale_value_message);
                    }
                    span.scale = multiplier;
                } else if (std.mem.eql(u8, attribute.name, "mono")) {
                    span.monospace = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
                } else if (std.mem.eql(u8, attribute.name, "italic")) {
                    span.italic = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
                } else if (std.mem.eql(u8, attribute.name, "underline")) {
                    span.underline = markup.expr.truthyWithPolicy(scope.expression_policy, try self.evalAttrExpression(scope, node, attribute));
                } else if (std.mem.eql(u8, attribute.name, "foreground")) {
                    span.color = std.meta.stringToEnum(canvas.TextSpanColor, attribute.value) orelse {
                        return self.failValue(node, markup.unknown_color_token_message);
                    };
                }
                // spanShapeError already rejected every other name.
            }
            span.text = try self.runText(ui, scope, node, node.children[0]);
            return span;
        }

        fn interpolatedText(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError![]const u8 {
            if (scope.expression_policy) |owner| return self.interpolatedTextOwned(owner, ui, scope, node);
            return self.interpolatedTextReference(ui, scope, node);
        }

        fn interpolatedTextReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError![]const u8 {
            if (node.children.len > 1) return self.failText(node, "text elements take a single run of text");
            for (node.children) |child| {
                if (child.kind != .text) {
                    // A span here sits inside a single-style label, not a
                    // paragraph — teach the <text> home instead of the
                    // generic message.
                    if (markup.nodeIsSpan(child)) return self.failText(child, markup.span_text_only_message);
                    return self.failText(node, "text elements may only contain text");
                }
                return self.runText(ui, scope, node, child);
            }
            return "";
        }

        /// Interpolate ONE text run (`{...}` bindings and expressions)
        /// into the build arena: the shared body behind plain text leaves
        /// and every span-paragraph run. `node` positions diagnostics.
        fn runText(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, run: markup.MarkupNode) BuildError![]const u8 {
            if (scope.expression_policy) |owner| return self.runTextOwned(owner, ui, scope, node, run);
            return self.runTextReference(ui, scope, node, run);
        }

        fn runTextReference(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, run: markup.MarkupNode) BuildError![]const u8 {
            const source = run.text;
            const segments = run.typed_text;
            if (std.mem.indexOfScalar(u8, source, '{') == null) return source;

            var out: std.ArrayListUnmanaged(u8) = .empty;
            if (segments) |typed_segments| {
                // The canonicalized fast path: the run was split (and its
                // expressions parsed) once at document level.
                for (typed_segments) |segment| {
                    switch (segment) {
                        .literal => |text| try out.appendSlice(ui.arena, text),
                        .binding => |path| try markup.expr.appendValueWithPolicy(scope.expression_policy, &out, ui.arena, try self.evalBinding(scope, node, path, true)),
                        .expression => |form| try markup.expr.appendValueWithPolicy(scope.expression_policy, &out, ui.arena, try self.evalExpressionForm(scope, node, form)),
                        .unterminated => return self.failText(node, "unterminated interpolation"),
                    }
                }
                return out.items;
            }
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
                try markup.expr.appendValueWithPolicy(scope.expression_policy, &out, ui.arena, value);
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

/// Markup attribute name → `Ui.ElementOptions` field, derived from the
/// registry (ui_schema.zig). Shared with the comptime-compiled path so
/// both engines accept exactly the same attributes; the registry is the
/// single statement of the mapping.
pub const AttrName = markup.schema.NamePair;

pub const attr_names: []const AttrName = &markup.schema.option_field_pairs;

/// Markup color style attribute → `StyleTokenRefs` field, derived from
/// the registry's style-color group. Shared with the comptime-compiled
/// path; held consistent with the token structs by a conformance test.
pub const color_style_attr_fields: []const AttrName = &markup.schema.color_style_field_pairs;

/// Model/Msg reflection predicates shared with the compiled engine and
/// the model-contract describe step (see ui_markup_reflect.zig — one
/// definition of what markup can bind, three consumers).
const reflect = @import("ui_markup_reflect.zig");
pub const typeScanQuota = reflect.typeScanQuota;
pub const Pointee = reflect.Pointee;
pub const declaredTextInputUnion = reflect.declaredTextInputUnion;
pub const declaredScrollStateRecord = reflect.declaredScrollStateRecord;
pub const declaredTerminalStateRecord = reflect.declaredTerminalStateRecord;
pub const declaredLegacyScrollStateRecord = reflect.declaredLegacyScrollStateRecord;
pub const declaredWidgetDragDropRecord = reflect.declaredWidgetDragDropRecord;
pub const valueArmClass = reflect.valueArmClass;
pub const sliceElement = reflect.sliceElement;
pub const isItemFn = reflect.isItemFn;
pub const isArenaScalarFn = reflect.isArenaScalarFn;

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
/// Runtime-only reflected access. The program owns raw path splitting and
/// field/declaration precedence; these capabilities retain native types, exact
/// scalar conversion, borrowed aliases and callback/allocator ownership.
fn scalarDeclClass(comptime T: type, comptime Decl: type) usize {
    switch (@typeInfo(Decl)) {
        .@"fn" => |info| {
            if (info.params.len == 1 and info.return_type != null and info.params[0].type == *const T) return 1;
            if (comptime isArenaScalarFn(T, Decl)) return 2;
        },
        else => {},
    }
    return 0;
}

fn resolveOnOwned(comptime T: type, owner: markup.expr.Policy, value: *const T, path: []const u8, arena: ?std.mem.Allocator) ?Value {
    @setEvalBranchQuota(comptime typeScanQuota(T));
    const class = comptime switch (@typeInfo(T)) {
        .@"struct" => 1,
        .pointer => |info| if (info.size == .one and info.is_const) 2 else 0,
        else => 0,
    };
    var request = value_programs.Request.init(13);
    defer request.deinit();
    request.word(class);
    request.blob(path);
    request.word(@intFromBool(arena != null));
    if (comptime class == 1) {
        const info = @typeInfo(T).@"struct";
        request.word(info.fields.len);
        inline for (info.fields) |field| request.blob(field.name);
        request.word(info.decls.len);
        inline for (info.decls) |decl| request.blob(decl.name);
        inline for (info.decls) |decl| request.word(comptime scalarDeclClass(T, @TypeOf(@field(T, decl.name))));
    } else request.words(&.{ 0, 0 });
    const action = request.decision(owner);
    if (action.action == 0) return null;
    if (comptime class == 2) {
        if (action.action != 70) @panic("invalid transparent pointer capability");
        return resolveOnOwned(@typeInfo(T).pointer.child, owner, value.*, path, arena);
    } else if (comptime class == 1) {
        switch (action.action) {
            68 => inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
                if (action.fields[0] == i) {
                    if (action.fields[1] != 0) return resolveOnOwned(field.type, owner, &@field(value, field.name), path[action.fields[1]..], arena);
                    return valueOf(field.type, @field(value, field.name));
                }
            },
            69 => inline for (@typeInfo(T).@"struct".decls, 0..) |decl, i| {
                if (action.fields[0] == i) {
                    const kind = comptime scalarDeclClass(T, @TypeOf(@field(T, decl.name)));
                    if (action.fields[1] != kind) @panic("invalid scalar callback class");
                    if (comptime kind == 1) return valueOf(@typeInfo(@TypeOf(@field(T, decl.name))).@"fn".return_type.?, @field(T, decl.name)(value));
                    if (comptime kind == 2) return valueOf(@typeInfo(@TypeOf(@field(T, decl.name))).@"fn".return_type.?, @field(T, decl.name)(value, arena.?));
                    @panic("unavailable scalar callback");
                }
            },
            else => @panic("invalid reflected access capability"),
        }
    }
    @panic("invalid reflected field index");
}

fn enumValueOwned(comptime T: type, owner: markup.expr.Policy, text: []const u8) ?T {
    var request = value_programs.Request.init(15);
    defer request.deinit();
    request.blob(text);
    const fields = @typeInfo(T).@"enum".fields;
    request.word(fields.len);
    inline for (fields) |field| request.blob(field.name);
    const action = request.decision(owner);
    if (action.action == 0) return null;
    if (action.action != 74) @panic("invalid enum capability");
    inline for (fields, 0..) |field, i| if (action.fields[0] == i) {
        return @field(T, field.name);
    };
    @panic("invalid enum field index");
}

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
        // Single-item const pointers are transparent (`reflect.Pointee`):
        // a `*const Row` loop item or shared model node binds like the
        // struct it points at.
        .pointer => |info| {
            if (info.size == .one and info.is_const) {
                return resolveOn(info.child, value.*, path, arena);
            }
            return null;
        },
        else => return null,
    }
}

/// True when `head` names a struct field whose type is a
/// `canvas.TextBuffer(N)` editor. Such a field is the EDIT MODEL, not
/// bindable text, so both engines and the contract checker turn the
/// generic missing-binding failure into a teaching message pointing at
/// the buffer's text() accessor. Comptime-callable (the compiled engine
/// runs it inside its comptime binding resolution).
pub fn fieldIsTextBuffer(comptime T: type, head: []const u8) bool {
    @setEvalBranchQuota(comptime typeScanQuota(T));
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const is_buffer = comptime (std.mem.indexOf(u8, @typeName(field.type), "TextBuffer(") != null);
        if (is_buffer and std.mem.eql(u8, field.name, head)) return true;
    }
    return false;
}

fn resolveNested(comptime T: type, ptr: anytype, path: []const u8, arena: ?std.mem.Allocator) ?Value {
    return switch (@typeInfo(T)) {
        .@"struct" => resolveOn(T, ptr, path, arena),
        // The `reflect.Pointee` transparency: traverse through a
        // single-item const pointer field into the struct it shares.
        .pointer => |info| if (info.size == .one and info.is_const)
            resolveNested(info.child, ptr.*, path, arena)
        else
            null,
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

pub const literalValue = reflect.literalValue;
pub const literalValueForAttribute = reflect.literalValueForAttribute;

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

/// One registry element resolved onto the engine's `WidgetKind`, computed
/// ONCE at comptime — resolving per lookup would re-run the enum scan per
/// element per call site and blow the comptime quota (the registry's
/// comptime-cost mitigation is single-pass derivation).
pub const ElementKindEntry = struct { name: []const u8, kind: canvas.WidgetKind, takes_text: bool, takes_children: bool };

fn widgetKindByName(comptime name: []const u8) canvas.WidgetKind {
    comptime {
        for (@typeInfo(canvas.WidgetKind).@"enum".fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return @enumFromInt(field.value);
        }
        @compileError("registry element names an unknown widget kind: " ++ name);
    }
}

/// The registry's plain elements with their kinds resolved: the one
/// name→kind table both engines dispatch through. A registry entry naming
/// a kind that does not exist is a compile error, so the mapping cannot
/// rot.
pub const element_kind_table = blk: {
    @setEvalBranchQuota(400_000);
    var count: usize = 0;
    for (markup.schema.elements) |entry| {
        if (entry.widget_kind.len > 0) count += 1;
    }
    var entries: [count]ElementKindEntry = undefined;
    var index: usize = 0;
    for (markup.schema.elements) |entry| {
        if (entry.widget_kind.len == 0) continue;
        entries[index] = .{
            .name = entry.name,
            .kind = widgetKindByName(entry.widget_kind),
            .takes_text = entry.takes_text,
            .takes_children = entry.takes_children,
        };
        index += 1;
    }
    break :blk entries;
};

pub fn elementKind(name: []const u8) ?canvas.WidgetKind {
    @setEvalBranchQuota(20_000);
    for (&element_kind_table) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.kind;
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
    // The registry's takes-text predicate projected onto widget kinds
    // (both engines and the validator's text-leaf list read the same
    // registry fact).
    @setEvalBranchQuota(20_000);
    for (&element_kind_table) |entry| {
        if (entry.takes_text and entry.kind == kind) return true;
    }
    return false;
}

pub fn elementTakesChildren(kind: canvas.WidgetKind) bool {
    // The registry's takes-children predicate projected onto widget
    // kinds: text-taking elements that ALSO accept element children in
    // place of the text run (the list-row composite).
    @setEvalBranchQuota(20_000);
    for (&element_kind_table) |entry| {
        if (entry.takes_children and entry.kind == kind) return true;
    }
    return false;
}
