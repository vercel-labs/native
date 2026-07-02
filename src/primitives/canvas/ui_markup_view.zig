//! Markup interpreter: turns a parsed markup document into `Ui(Msg)` nodes
//! against a concrete Model/Msg pair (design:
//! plans/zero-native/markup-authoring.md).
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
};

/// A resolved binding value. Enums resolve to their tag name so equality
/// against enum-typed loop variables and literals works uniformly. Shared
/// with the comptime-compiled path (ui_markup_compiled.zig) so both engines
/// convert and compare values through the same code.
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f32,
    boolean: bool,

    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .string => |sa| b == .string and std.mem.eql(u8, sa, b.string),
            .integer => |ia| b == .integer and ia == b.integer,
            .float => |fa| b == .float and fa == b.float,
            .boolean => |ba| b == .boolean and ba == b.boolean,
        };
    }

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .boolean => |value| value,
            .integer => |value| value != 0,
            .float => |value| value != 0,
            .string => |value| value.len > 0,
        };
    }
};

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

        /// Build the view for the current model. Compatible with the
        /// hand-written `view(ui, model)` shape.
        pub fn build(self: *Self, ui: *Ui, model: *const ModelT) BuildError!Ui.Node {
            var scope = Scope{ .model = model };
            return self.buildNode(ui, &scope, self.document.root);
        }

        // ------------------------------------------------------- scopes

        /// Types a `for` loop can iterate: element types of Model slice or
        /// array fields, public array/slice declarations, and public
        /// functions returning slices (optionally taking an arena).
        const item_types = collectItemTypes(ModelT);

        /// A named value in scope: a `for` loop item (typed pointer tagged
        /// into `item_types`), a slice-valued template arg (iterable by a
        /// `for each` inside the template), or a scalar template arg
        /// (usable in bindings, interpolation, and equality).
        const ScopeEntry = struct {
            name: []const u8,
            payload: Payload,

            const Payload = union(enum) {
                item: struct { type_index: usize, ptr: *const anyopaque },
                slice: struct { type_index: usize, ptr: *const anyopaque, len: usize },
                value: Value,
            };
        };

        const max_scope_depth = 8;

        const Scope = struct {
            model: *const ModelT,
            entries: [max_scope_depth]ScopeEntry = undefined,
            len: usize = 0,
            /// Bindings resolve entries[floor..len] then the model: a
            /// template body sees its args and its own loop variables but
            /// not the loop variables at the expansion site.
            floor: usize = 0,
            /// Template expansion depth, bounding runtime recursion on
            /// documents the validator would reject (uses may only
            /// reference templates defined earlier in the file).
            use_depth: usize = 0,

            fn lookup(self: *const Scope, head: []const u8) ?*const ScopeEntry {
                var index = self.len;
                while (index > self.floor) {
                    index -= 1;
                    if (std.mem.eql(u8, self.entries[index].name, head)) return &self.entries[index];
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
                .text => return self.failNode(node, "text content is only allowed inside text-bearing elements"),
                .for_block, .if_block, .else_block => return self.failNode(node, "structure tags are only allowed inside an element"),
            }
        }

        fn buildElement(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            const kind = elementKind(node.name) orelse {
                return self.failNode(node, "unknown element");
            };
            var options: Ui.ElementOptions = .{};
            try self.applyAttrs(scope, node, &options);

            if (elementTakesText(kind)) {
                const text = try self.interpolatedText(ui, scope, node);
                var built = ui.el(kind, options, .{});
                built.widget.text = text;
                return built;
            }

            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            try self.buildChildren(ui, scope, node, &children);
            return ui.el(kind, options, @as([]const Ui.Node, children.items));
        }

        fn buildChildren(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
            var index: usize = 0;
            while (index < node.children.len) : (index += 1) {
                const child = node.children[index];
                switch (child.kind) {
                    .element => try out.append(ui.arena, try self.buildElement(ui, scope, child)),
                    .use_block => try out.append(ui.arena, try self.buildUse(ui, scope, child)),
                    .template_block => return self.failVoid(child, markup.template_top_level_message),
                    .for_block => try self.buildFor(ui, scope, child, out),
                    .if_block => {
                        const test_value = child.attr("test") orelse {
                            return self.failVoid(child, "if requires a test attribute");
                        };
                        const condition = try self.evalAttrExpression(scope, child, test_value);
                        var else_node: ?markup.MarkupNode = null;
                        if (index + 1 < node.children.len and node.children[index + 1].kind == .else_block) {
                            else_node = node.children[index + 1];
                            index += 1;
                        }
                        if (condition.truthy()) {
                            try self.buildChildren(ui, scope, child, out);
                        } else if (else_node) |else_block| {
                            try self.buildChildren(ui, scope, else_block, out);
                        }
                    },
                    .else_block => return self.failVoid(child, "else must directly follow an if"),
                    .text => return self.failVoid(child, "text content is only allowed inside text-bearing elements"),
                }
            }
        }

        fn buildFor(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
            const each = node.attr("each") orelse return self.failVoid(node, "for requires an each attribute");
            const as_name = node.attr("as") orelse return self.failVoid(node, "for requires an as attribute");
            const key_field = node.attr("key");
            if (scope.len >= max_scope_depth) return self.failVoid(node, "for nesting is too deep");
            if (node.children.len != 1 or (node.children[0].kind != .element and node.children[0].kind != .use_block)) {
                return self.failVoid(node, "for takes exactly one element child");
            }
            const template = node.children[0];

            inline for (item_types, 0..) |Item, type_index| {
                if (try self.iterateItems(ui, Item, type_index, scope, each)) |items| {
                    for (items) |*item| {
                        scope.entries[scope.len] = .{
                            .name = as_name,
                            .payload = .{ .item = .{ .type_index = type_index, .ptr = @ptrCast(item) } },
                        };
                        scope.len += 1;
                        defer scope.len -= 1;

                        var built = try self.buildNode(ui, scope, template);
                        if (built.key == null and built.global_key == null) {
                            if (key_field) |field| {
                                built.key = try self.itemKey(Item, item, template, field);
                            }
                        }
                        try out.append(ui.arena, built);
                    }
                    return;
                }
            }
            return self.failVoid(node, "each does not name an iterable (a model slice, array, or fn - or a slice-valued template arg)");
        }

        /// Resolve `each` to a slice of Item: a slice-valued template arg
        /// in scope, or on the model a field, a public array declaration,
        /// or a public function (with or without arena).
        fn iterateItems(self: *Self, ui: *Ui, comptime Item: type, comptime type_index: usize, scope: *Scope, each: []const u8) BuildError!?[]const Item {
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

        // ------------------------------------------------------ templates

        /// Build a `<use>` site: evaluate the template args against the
        /// use-site scope, push them as scope entries, and build the
        /// template's single element child in place — structural ids hash
        /// through the parent chain at the expansion site, exactly as if
        /// the body were written inline.
        fn buildUse(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            const template_name = node.attr("template") orelse {
                return self.failNode(node, markup.use_template_attr_message);
            };
            const template_index = self.document.templateIndex(template_name) orelse {
                return self.failNode(node, markup.use_undefined_template_message);
            };
            const template_node = self.document.templates[template_index];
            if (scope.use_depth >= self.document.templates.len) {
                return self.failNode(node, markup.use_earlier_template_message);
            }
            if (template_node.children.len != 1 or template_node.children[0].kind != .element) {
                return self.failNode(template_node, markup.template_one_child_message);
            }
            if (node.children.len != 0) {
                return self.failNode(node, markup.use_no_children_message);
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
            var arg_count: usize = 0;
            var args = markup.templateArgs(template_node);
            while (args.next()) |arg_name| {
                const raw = node.attr(arg_name) orelse {
                    return self.failNode(node, markup.use_missing_arg_message);
                };
                if (saved_len + arg_count >= max_scope_depth) {
                    return self.failNode(node, "template args nest too deep");
                }
                scope.entries[saved_len + arg_count] = .{
                    .name = arg_name,
                    .payload = try self.argPayload(ui, scope, node, raw),
                };
                arg_count += 1;
            }

            scope.len = saved_len + arg_count;
            scope.floor = saved_len;
            scope.use_depth += 1;
            defer {
                scope.len = saved_len;
                scope.floor = saved_floor;
                scope.use_depth -= 1;
            }
            return self.buildElement(ui, scope, template_node.children[0]);
        }

        /// A template arg's scope payload: a `{binding}` naming an iterable
        /// (in scope or on the model, the same resolution set as
        /// `for each`) binds as a slice; anything else evaluates to a
        /// `Value` at the use site.
        fn argPayload(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, raw: []const u8) BuildError!ScopeEntry.Payload {
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
            return .{ .value = try self.evalAttrExpression(scope, node, raw) };
        }

        fn failPayload(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn itemKey(self: *Self, comptime Item: type, item: *const Item, node: markup.MarkupNode, field: []const u8) BuildError!canvas.UiKey {
            const value = resolveOn(Item, item, field) orelse {
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
            const msg = try self.constructMessage(scope, node, expression);
            if (std.mem.eql(u8, event, "press")) {
                options.on_press = msg;
            } else if (std.mem.eql(u8, event, "toggle")) {
                options.on_toggle = msg;
            } else if (std.mem.eql(u8, event, "change")) {
                options.on_change = msg;
            } else if (std.mem.eql(u8, event, "submit")) {
                options.on_submit = msg;
            } else {
                return self.failVoid(node, "unknown event attribute");
            }
        }

        fn constructMessage(self: *Self, scope: *Scope, node: markup.MarkupNode, expression: markup.MessageExpression) BuildError!MsgT {
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
                    const value = try self.evalBinding(scope, node, expression.payload);
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
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (field.type == canvas.TextInputEvent) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.inputMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
            }
            return null;
        }

        // --------------------------------------------------- expressions

        fn evalAttrExpression(self: *Self, scope: *Scope, node: markup.MarkupNode, raw: []const u8) BuildError!Value {
            const expression = markup.parseAttrExpression(raw) orelse {
                return self.failValue(node, "invalid expression: values are a literal, one {binding}, or one {a == b} equality - no other operators or calls (put logic in a model function)");
            };
            return switch (expression) {
                .literal => |text| literalValue(text),
                .binding => |path| try self.evalBinding(scope, node, path),
                .equals => |sides| .{ .boolean = Value.eql(
                    try self.evalBinding(scope, node, sides.left),
                    try self.evalBinding(scope, node, sides.right),
                ) },
            };
        }

        fn evalBinding(self: *Self, scope: *Scope, node: markup.MarkupNode, path: []const u8) BuildError!Value {
            const head = pathHead(path);
            if (scope.lookup(head)) |entry| {
                switch (entry.payload) {
                    .item => |item_entry| {
                        inline for (item_types, 0..) |Item, type_index| {
                            if (item_entry.type_index == type_index) {
                                const item: *const Item = @ptrCast(@alignCast(item_entry.ptr));
                                if (pathTail(path)) |tail| {
                                    return resolveOn(Item, item, tail) orelse self.failValue(node, "binding does not name a field on the loop item");
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
                }
            }
            return resolveOn(ModelT, scope.model, path) orelse self.failValue(node, "binding does not name a model field");
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
                const path = std.mem.trim(u8, rest[open + 1 .. close], " ");
                const value = try self.evalBinding(scope, node, path);
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
            self.diagnostic = .{ .line = node.line, .column = node.column, .message = message };
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
    .{ .markup = "disabled", .zig = "disabled" },
    .{ .markup = "variant", .zig = "variant" },
    .{ .markup = "size", .zig = "size" },
    .{ .markup = "width", .zig = "width" },
    .{ .markup = "height", .zig = "height" },
    .{ .markup = "grow", .zig = "grow" },
    .{ .markup = "gap", .zig = "gap" },
    .{ .markup = "padding", .zig = "padding" },
    .{ .markup = "main", .zig = "main" },
    .{ .markup = "cross", .zig = "cross" },
    .{ .markup = "virtualized", .zig = "virtualized" },
    .{ .markup = "virtual-item-extent", .zig = "virtual_item_extent" },
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

fn collectItemTypes(comptime Model: type) []const type {
    comptime {
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

/// Resolve a dotted path on a value: struct fields, zero-arg methods, and
/// bounded model conventions (a `field_count`-style pair is the author's
/// job; the resolver only follows what exists).
fn resolveOn(comptime T: type, value: *const T, path: []const u8) ?Value {
    const head = pathHead(path);
    const tail = pathTail(path);
    switch (@typeInfo(T)) {
        .@"struct" => {
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, head)) {
                    if (tail) |rest| {
                        return resolveNested(field.type, &@field(value, field.name), rest);
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
                    },
                    else => {},
                }
            }
            return null;
        },
        else => return null,
    }
}

fn resolveNested(comptime T: type, ptr: anytype, path: []const u8) ?Value {
    return switch (@typeInfo(T)) {
        .@"struct" => resolveOn(T, ptr, path),
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

pub fn appendValue(out: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, value: Value) error{OutOfMemory}!void {
    var buffer: [64]u8 = undefined;
    switch (value) {
        .string => |text| try out.appendSlice(arena, text),
        .integer => |int| try out.appendSlice(arena, std.fmt.bufPrint(&buffer, "{d}", .{int}) catch return error.OutOfMemory),
        .float => |float| try out.appendSlice(arena, std.fmt.bufPrint(&buffer, "{d}", .{float}) catch return error.OutOfMemory),
        .boolean => |boolean| try out.appendSlice(arena, if (boolean) "true" else "false"),
    }
}

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
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

pub fn elementTakesText(kind: canvas.WidgetKind) bool {
    return switch (kind) {
        .text, .button, .list_item, .menu_item, .status_bar, .badge, .toggle => true,
        else => false,
    };
}
