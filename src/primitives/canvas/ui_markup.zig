//! Markup front-end for the declarative ui builder (design:
//! plans/zero-native/markup-authoring.md).
//!
//! This module owns the grammar: an HTML-like element tree with kebab-case
//! element and attribute names, `{binding}` expressions, `on-*` message
//! dispatch (`msg` or `msg:{arg}`), and `for`/`if`/`else` structure tags.
//! Parsing is type-agnostic; binding and message validation against a
//! concrete Model/Msg happens in the interpreter layer.
//!
//! The parser is deliberately strict: unknown syntax is an error with a
//! line/column position, never a silent skip — fast, specific failure is
//! the feedback loop markup authors (human or agent) rely on.

const std = @import("std");
const font_coverage = @import("font_coverage.zig");

pub const MarkupErrorInfo = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8 = "",
};

pub const MarkupNodeKind = enum {
    element,
    text,
    for_block,
    if_block,
    else_block,
    template_block,
    use_block,
};

pub const MarkupAttr = struct {
    name: []const u8,
    value: []const u8,
    line: usize,
    column: usize,
};

pub const MarkupNode = struct {
    kind: MarkupNodeKind,
    /// Element name for `element` nodes ("row", "text-field", ...).
    name: []const u8 = "",
    attrs: []const MarkupAttr = &.{},
    children: []const MarkupNode = &.{},
    /// Raw text content (may contain `{...}` interpolations).
    text: []const u8 = "",
    line: usize = 0,
    column: usize = 0,

    pub fn attr(self: MarkupNode, name: []const u8) ?[]const u8 {
        for (self.attrs) |attribute| {
            if (std.mem.eql(u8, attribute.name, name)) return attribute.value;
        }
        return null;
    }
};

pub const MarkupDocument = struct {
    /// Top-level `<template name="..." args="...">` definitions, in file
    /// order. `<use>` sites reference them by name; a use may only
    /// reference templates defined earlier in the file (which also rules
    /// out recursion structurally).
    templates: []const MarkupNode = &.{},
    root: MarkupNode,

    pub fn templateIndex(self: MarkupDocument, name: []const u8) ?usize {
        for (self.templates, 0..) |template_node, index| {
            const template_name = template_node.attr("name") orelse continue;
            if (std.mem.eql(u8, template_name, name)) return index;
        }
        return null;
    }
};

/// Iterate a template's declared arg names (the space-separated `args`
/// attribute). Works at runtime and comptime.
pub fn templateArgs(template_node: MarkupNode) std.mem.TokenIterator(u8, .scalar) {
    return std.mem.tokenizeScalar(u8, template_node.attr("args") orelse "", ' ');
}

pub fn templateDeclaresArg(template_node: MarkupNode, name: []const u8) bool {
    var args = templateArgs(template_node);
    while (args.next()) |arg_name| {
        if (std.mem.eql(u8, arg_name, name)) return true;
    }
    return false;
}

pub const ParseError = error{ MarkupSyntax, OutOfMemory };

pub const Parser = struct {
    source: []const u8,
    index: usize = 0,
    line: usize = 1,
    column: usize = 1,
    arena: std.mem.Allocator,
    diagnostic: MarkupErrorInfo = .{},

    pub fn init(arena: std.mem.Allocator, source: []const u8) Parser {
        return .{ .arena = arena, .source = source };
    }

    /// Parse a document: comments and whitespace around zero or more
    /// top-level `<template>` definitions followed by exactly one root
    /// element.
    pub fn parse(self: *Parser) ParseError!MarkupDocument {
        var templates: std.ArrayListUnmanaged(MarkupNode) = .empty;
        while (true) {
            self.skipWhitespaceAndComments();
            if (self.index >= self.source.len and templates.items.len > 0) {
                return self.fail("expected a view root element after the template definitions");
            }
            const node = try self.parseElement();
            if (node.kind == .template_block) {
                try templates.append(self.arena, node);
                continue;
            }
            self.skipWhitespaceAndComments();
            if (self.index < self.source.len) {
                return self.fail("expected end of file after the root element");
            }
            return .{ .templates = templates.items, .root = node };
        }
    }

    fn parseElement(self: *Parser) ParseError!MarkupNode {
        const start_line = self.line;
        const start_column = self.column;
        if (!self.consumeByte('<')) return self.fail("expected '<' to open an element");
        const name = try self.parseName("element name");

        var attrs: std.ArrayListUnmanaged(MarkupAttr) = .empty;
        while (true) {
            self.skipWhitespace();
            const byte = self.peek() orelse return self.fail("unterminated element tag");
            if (byte == '/' or byte == '>') break;
            const attr_line = self.line;
            const attr_column = self.column;
            const attr_name = try self.parseName("attribute name");
            var value: []const u8 = "";
            self.skipWhitespace();
            if (self.consumeByte('=')) {
                self.skipWhitespace();
                value = try self.parseQuotedValue();
            }
            try attrs.append(self.arena, .{
                .name = attr_name,
                .value = value,
                .line = attr_line,
                .column = attr_column,
            });
        }

        var node = MarkupNode{
            .kind = nodeKindForName(name),
            .name = name,
            .attrs = attrs.items,
            .line = start_line,
            .column = start_column,
        };

        if (self.consumeByte('/')) {
            if (!self.consumeByte('>')) return self.fail("expected '>' after '/' in a self-closing tag");
            return node;
        }
        if (!self.consumeByte('>')) return self.fail("expected '>' to close the element tag");

        var children: std.ArrayListUnmanaged(MarkupNode) = .empty;
        while (true) {
            self.skipComments();
            const byte = self.peek() orelse return self.failAt(start_line, start_column, "element was never closed");
            if (byte == '<') {
                if (self.peekAt(1) == '/') {
                    try self.parseClosingTag(name);
                    break;
                }
                try children.append(self.arena, try self.parseElement());
                continue;
            }
            // Record the position of the run's first VISIBLE byte, so
            // messages that point into text content (the tofu guard)
            // land on the character, not the run's end.
            const text_line = self.line;
            const text_column = self.column;
            const text = self.takeText();
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len > 0) {
                var line = text_line;
                var column = text_column;
                for (text[0..textLeadingTrim(text)]) |lead_byte| {
                    if (lead_byte == '\n') {
                        line += 1;
                        column = 1;
                    } else {
                        column += 1;
                    }
                }
                try children.append(self.arena, .{
                    .kind = .text,
                    .text = trimmed,
                    .line = line,
                    .column = column,
                });
            }
        }

        node.children = children.items;
        return node;
    }

    fn parseClosingTag(self: *Parser, open_name: []const u8) ParseError!void {
        const line = self.line;
        const column = self.column;
        _ = self.consumeByte('<');
        _ = self.consumeByte('/');
        const name = try self.parseName("closing tag name");
        self.skipWhitespace();
        if (!self.consumeByte('>')) return self.fail("expected '>' in closing tag");
        if (!std.mem.eql(u8, name, open_name)) {
            return self.failAt(line, column, "closing tag does not match the open element");
        }
    }

    fn parseName(self: *Parser, what: []const u8) ParseError![]const u8 {
        const start = self.index;
        while (self.peek()) |byte| {
            const valid = (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '_';
            if (!valid) break;
            self.advance();
        }
        if (self.index == start) {
            self.diagnostic = .{ .line = self.line, .column = self.column, .message = what };
            return self.fail("expected a lowercase kebab-case name");
        }
        return self.source[start..self.index];
    }

    fn parseQuotedValue(self: *Parser) ParseError![]const u8 {
        if (!self.consumeByte('"')) return self.fail("expected '\"' to open an attribute value");
        const start = self.index;
        while (self.peek()) |byte| {
            if (byte == '"') {
                const value = self.source[start..self.index];
                self.advance();
                return value;
            }
            if (byte == '\n') return self.fail("attribute values may not contain newlines");
            self.advance();
        }
        return self.fail("unterminated attribute value");
    }

    fn takeText(self: *Parser) []const u8 {
        const start = self.index;
        while (self.peek()) |byte| {
            if (byte == '<') break;
            self.advance();
        }
        return self.source[start..self.index];
    }

    fn skipWhitespaceAndComments(self: *Parser) void {
        while (true) {
            const before = self.index;
            self.skipWhitespace();
            self.skipComments();
            if (self.index == before) return;
        }
    }

    fn skipComments(self: *Parser) void {
        while (std.mem.startsWith(u8, self.source[self.index..], "<!--")) {
            const end = std.mem.indexOfPos(u8, self.source, self.index + 4, "-->") orelse {
                // Unterminated comment: consume to EOF; parse loop reports it.
                while (self.peek() != null) self.advance();
                return;
            };
            while (self.index < end + 3) self.advance();
        }
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.peek()) |byte| {
            if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') return;
            self.advance();
        }
    }

    fn peek(self: *const Parser) ?u8 {
        if (self.index >= self.source.len) return null;
        return self.source[self.index];
    }

    fn peekAt(self: *const Parser, offset: usize) ?u8 {
        if (self.index + offset >= self.source.len) return null;
        return self.source[self.index + offset];
    }

    fn consumeByte(self: *Parser, byte: u8) bool {
        if (self.peek() == byte) {
            self.advance();
            return true;
        }
        return false;
    }

    fn advance(self: *Parser) void {
        if (self.source[self.index] == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        self.index += 1;
    }

    fn fail(self: *Parser, message: []const u8) ParseError {
        return self.failAt(self.line, self.column, message);
    }

    fn failAt(self: *Parser, line: usize, column: usize, message: []const u8) ParseError {
        self.diagnostic = .{ .line = line, .column = column, .message = message };
        return error.MarkupSyntax;
    }
};

fn nodeKindForName(name: []const u8) MarkupNodeKind {
    if (std.mem.eql(u8, name, "for")) return .for_block;
    if (std.mem.eql(u8, name, "if")) return .if_block;
    if (std.mem.eql(u8, name, "else")) return .else_block;
    if (std.mem.eql(u8, name, "template")) return .template_block;
    if (std.mem.eql(u8, name, "use")) return .use_block;
    return .element;
}

// ------------------------------------------------------- comptime parsing

/// Comptime counterpart of `Parser.parse` for `@embedFile`d sources: the
/// same `Parser` token-level helpers drive the scan (single source of truth
/// for the grammar), but attribute/child accumulation uses comptime slice
/// concatenation instead of an arena, and any syntax error becomes a
/// compile error carrying the line/column and message that the runtime
/// diagnostic would carry.
pub fn parseComptime(comptime source: []const u8) MarkupDocument {
    comptime {
        @setEvalBranchQuota(comptime_parse_quota_base + source.len * comptime_parse_quota_per_byte);
        var parser = Parser.init(undefined, source);
        var templates: []const MarkupNode = &.{};
        while (true) {
            parser.skipWhitespaceAndComments();
            if (parser.index >= parser.source.len and templates.len > 0) {
                failComptime(&parser, parser.fail("expected a view root element after the template definitions"));
            }
            const node = parseElementComptime(&parser);
            if (node.kind == .template_block) {
                templates = templates ++ &[_]MarkupNode{node};
                continue;
            }
            parser.skipWhitespaceAndComments();
            if (parser.index < parser.source.len) {
                failComptime(&parser, parser.fail("expected end of file after the root element"));
            }
            return .{ .templates = templates, .root = node };
        }
    }
}

/// Comptime parsing walks every byte through the shared scanner helpers, so
/// the branch quota scales with the source: a handful of comptime branches
/// per byte, with generous headroom for nesting.
const comptime_parse_quota_base = 20_000;
const comptime_parse_quota_per_byte = 200;

/// Comptime mirror of `Parser.parseElement`: identical control flow, with
/// `attrs ++`/`children ++` in place of the arena-backed lists.
fn parseElementComptime(comptime parser: *Parser) MarkupNode {
    const start_line = parser.line;
    const start_column = parser.column;
    if (!parser.consumeByte('<')) failComptime(parser, parser.fail("expected '<' to open an element"));
    const name = parser.parseName("element name") catch |err| failComptime(parser, err);

    var attrs: []const MarkupAttr = &.{};
    while (true) {
        parser.skipWhitespace();
        const byte = parser.peek() orelse failComptime(parser, parser.fail("unterminated element tag"));
        if (byte == '/' or byte == '>') break;
        const attr_line = parser.line;
        const attr_column = parser.column;
        const attr_name = parser.parseName("attribute name") catch |err| failComptime(parser, err);
        var value: []const u8 = "";
        parser.skipWhitespace();
        if (parser.consumeByte('=')) {
            parser.skipWhitespace();
            value = parser.parseQuotedValue() catch |err| failComptime(parser, err);
        }
        attrs = attrs ++ &[_]MarkupAttr{.{
            .name = attr_name,
            .value = value,
            .line = attr_line,
            .column = attr_column,
        }};
    }

    var node = MarkupNode{
        .kind = nodeKindForName(name),
        .name = name,
        .attrs = attrs,
        .line = start_line,
        .column = start_column,
    };

    if (parser.consumeByte('/')) {
        if (!parser.consumeByte('>')) failComptime(parser, parser.fail("expected '>' after '/' in a self-closing tag"));
        return node;
    }
    if (!parser.consumeByte('>')) failComptime(parser, parser.fail("expected '>' to close the element tag"));

    var children: []const MarkupNode = &.{};
    while (true) {
        parser.skipComments();
        const byte = parser.peek() orelse failComptime(parser, parser.failAt(start_line, start_column, "element was never closed"));
        if (byte == '<') {
            if (parser.peekAt(1) == '/') {
                parser.parseClosingTag(name) catch |err| failComptime(parser, err);
                break;
            }
            children = children ++ &[_]MarkupNode{parseElementComptime(parser)};
            continue;
        }
        const text_line = parser.line;
        const text_column = parser.column;
        const text = parser.takeText();
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) {
            var line = text_line;
            var column = text_column;
            for (text[0..textLeadingTrim(text)]) |lead_byte| {
                if (lead_byte == '\n') {
                    line += 1;
                    column = 1;
                } else {
                    column += 1;
                }
            }
            children = children ++ &[_]MarkupNode{.{
                .kind = .text,
                .text = trimmed,
                .line = line,
                .column = column,
            }};
        }
    }

    node.children = children;
    return node;
}

/// Surface the parser's diagnostic (already positioned by the shared
/// helpers) as a compile error. The error value parameter exists so call
/// sites read like the runtime parser's `try`/`return self.fail(...)`.
fn failComptime(comptime parser: *const Parser, comptime err: ParseError) noreturn {
    _ = err;
    @compileError(std.fmt.comptimePrint("markup error at line {d}, column {d}: {s}", .{
        parser.diagnostic.line,
        parser.diagnostic.column,
        parser.diagnostic.message,
    }));
}

// ------------------------------------------------------------ expressions

pub const Expression = union(enum) {
    literal: []const u8,
    binding: []const u8,
    equals: struct { left: []const u8, right: []const u8 },
};

/// Parse an attribute value: either a plain literal or exactly one
/// sanctioned expression form — `{path}` or `{a == b}`. Mixed literal and
/// binding text is only allowed in text content (interpolation), not in
/// attribute values.
pub fn parseAttrExpression(value: []const u8) ?Expression {
    if (value.len == 0 or value[0] != '{') return .{ .literal = value };
    if (value[value.len - 1] != '}') return null;
    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " ");
    if (inner.len == 0) return null;
    if (std.mem.indexOf(u8, inner, "==")) |eq| {
        const left = std.mem.trim(u8, inner[0..eq], " ");
        const right = std.mem.trim(u8, inner[eq + 2 ..], " ");
        if (!isBindingPath(left) or !isBindingPath(right)) return null;
        return .{ .equals = .{ .left = left, .right = right } };
    }
    if (!isBindingPath(inner)) return null;
    return .{ .binding = inner };
}

pub const MessageExpression = struct {
    tag: []const u8,
    /// Binding path for the payload, empty when the message carries none.
    payload: []const u8 = "",
};

/// Parse an `on-*` attribute value: `msg` or `msg:{path}`.
pub fn parseMessageExpression(value: []const u8) ?MessageExpression {
    if (std.mem.indexOfScalar(u8, value, ':')) |colon| {
        const tag = value[0..colon];
        const payload = value[colon + 1 ..];
        if (!isBindingPath(tag)) return null;
        if (payload.len < 3 or payload[0] != '{' or payload[payload.len - 1] != '}') return null;
        const path = payload[1 .. payload.len - 1];
        if (!isBindingPath(path)) return null;
        return .{ .tag = tag, .payload = path };
    }
    if (!isBindingPath(value)) return null;
    return .{ .tag = value };
}

fn isBindingPath(text: []const u8) bool {
    if (text.len == 0) return false;
    var segment_start = true;
    for (text) |byte| {
        if (segment_start) {
            if (!std.ascii.isAlphabetic(byte) and byte != '_') return false;
            segment_start = false;
            continue;
        }
        if (byte == '.') {
            segment_start = true;
            continue;
        }
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return !segment_start;
}

// ------------------------------------------------------------ validation

/// Element names the interpreter accepts (kept in sync by a test in
/// ui_markup_view_tests.zig). Covers every built-in component whose shape
/// fits the closed grammar; the deliberate exclusions (image,
/// icon-button, data-grid, popover, menu-surface, segmented-control) are
/// documented next to the widget-kind coverage test in
/// ui_markup_view_tests.zig — write those as Zig view functions.
pub const known_element_names =
    // Flex, overlay, and scrolling containers.
    [_][]const u8{ "row", "column", "stack", "panel", "scroll", "list", "grid", "card" } ++
    // Row containers (children flow along the horizontal main axis).
    [_][]const u8{ "breadcrumb", "button-group", "pagination", "radio-group", "tabs", "toggle-group" } ++
    // Vertical containers.
    [_][]const u8{ "table", "table-row", "dropdown-menu" } ++
    // Overlay/surface containers (title via the text attribute).
    [_][]const u8{ "accordion", "alert", "bubble", "dialog", "drawer", "sheet", "resizable" } ++
    // Text-bearing leaves (label is the element content).
    [_][]const u8{ "text", "badge", "button", "toggle", "list-item", "menu-item", "status-bar" } ++
    [_][]const u8{ "avatar", "select", "switch", "table-cell", "toggle-button", "tooltip" } ++
    // Value controls and text entry.
    [_][]const u8{ "checkbox", "radio", "slider", "progress" } ++
    [_][]const u8{ "text-field", "search-field", "textarea", "input", "combobox" } ++
    // Plain leaves.
    [_][]const u8{ "separator", "spacer", "skeleton", "spinner", "icon" };

/// Elements whose content is a single run of text (with `{}`
/// interpolation) and that take no element children. Kept in sync with the
/// interpreter's `elementTakesText` by a test in ui_markup_view_tests.zig.
pub const known_text_leaf_element_names = [_][]const u8{
    "text",       "badge",         "button",  "toggle", "list-item",
    "menu-item",  "status-bar",    "avatar",  "select", "switch",
    "table-cell", "toggle-button", "tooltip",
};

pub const known_option_attrs = [_][]const u8{
    "text",           "placeholder", "value",       "checked",             "selected", "disabled",
    "variant",        "size",        "width",       "height",              "grow",     "gap",
    "padding",        "main",        "cross",       "wrap",                "key",      "global-key",
    "text-alignment", "columns",     "virtualized", "virtual-item-extent", "role",     "label",
    "autofocus",
};

pub const known_events = [_][]const u8{ "press", "toggle", "change", "submit", "input", "scroll", "dismiss", "hold" };

pub const on_scroll_element_message = "on-scroll is only supported on scroll - the runtime emits scroll offsets for scroll containers, so the handler belongs on the scroll element itself";
pub const on_scroll_payload_message = "on-scroll takes a bare Msg tag whose payload is the post-scroll state (a canvas.ScrollState variant, like activity_scrolled: canvas.ScrollState)";

/// Elements the runtime's dismissal machinery closes (Escape, click
/// outside, automation/accessibility dismiss) — the markup subset of the
/// engine's dismissible-surface kinds (`canvas.widgetKindDismissibleSurface`;
/// popover/menu-surface/tooltip stay Zig views or leaves).
pub const known_dismiss_element_names = [_][]const u8{ "dialog", "drawer", "sheet", "dropdown-menu" };

pub const on_dismiss_element_message = "on-dismiss is only supported on dismissible surfaces (dialog, drawer, sheet, dropdown-menu) - Escape and click-outside dismiss those, and the Msg lets the model own the close (clear the open flag in update)";

/// Elements that may float as anchored surfaces. dropdown-menu is the
/// markup channel; popover/menu-surface stay Zig views (documented
/// exclusions) and dialogs/drawers/sheets place themselves.
pub const known_anchor_element_names = [_][]const u8{"dropdown-menu"};

pub const anchor_element_message = "anchor is only supported on dropdown-menu - it floats the surface against its PARENT's frame (put the dropdown beside its trigger inside a stack); dialogs, drawers, and sheets place themselves";
pub const anchor_value_message = "anchor takes a literal placement: below or above (either side flips automatically when the surface does not fit and the other side has more room)";
pub const anchor_alignment_value_message = "anchor-alignment takes a literal alignment: start, end, or stretch (stretch also widens the surface to at least the anchor's width)";
pub const anchor_offset_value_message = "anchor-offset takes a literal number: the gap in points between the anchor edge and the surface";
pub const anchor_dependent_attr_message = "anchor-alignment and anchor-offset only apply together with anchor - add anchor=\"below\" (or \"above\") to float this surface";

/// Elements whose widget KIND the engine never hit-tests: layout and
/// decoration only. A bound `on-press`/`on-toggle` makes any element a
/// hit target (widget-level: the handler stamps the press/toggle action,
/// and presses on non-interactive content inside it fall through to it),
/// so those two are legal everywhere; the remaining value/text handlers
/// (`on-change`/`on-submit`/`on-input`) have no behavior to bind to on
/// these elements and stay validation errors. Derived from the engine's
/// kind predicate (`canvas.widgetKindHitTarget` in widget_access.zig); a
/// test in ui_markup_view_tests.zig keeps this name list and that
/// predicate in lockstep so drift is impossible.
pub const known_non_hit_target_element_names = [_][]const u8{
    "row",        "column",      "stack",     "spacer",       "grid",
    "list",       "table",       "table-row", "breadcrumb",   "button-group",
    "pagination", "radio-group", "tabs",      "toggle-group", "tooltip",
    "avatar",     "badge",       "separator", "skeleton",     "spinner",
    "icon",
};

/// The handlers that stay dead on layout/decoration elements: press and
/// toggle make any element pressable, scroll has its own element-scoped
/// rule (`on_scroll_element_message`), and these three bind control/text
/// behavior the element does not have.
pub fn deadHandlerOnNonHitTarget(attr_name: []const u8) bool {
    return std.mem.eql(u8, attr_name, "on-change") or
        std.mem.eql(u8, attr_name, "on-submit") or
        std.mem.eql(u8, attr_name, "on-input");
}

pub const autofocus_element_message = "autofocus is only supported on focusable controls (text fields, buttons, checkboxes, ...) - it moves keyboard focus to the element when it mounts or when the flag turns on, and nothing about this element can take focus";

pub const non_hit_target_handler_message = "on-change/on-submit/on-input never fire here: this element has no control or text behavior - put them on a control (input, checkbox, slider) inside it (on-press/on-toggle are fine anywhere: a bound press handler makes any element pressable, and clicks on plain text or icons inside it fall through to it)";

/// Elements whose widget kind layers its children on top of each other
/// (every child gets the full content box), so `gap` can never space
/// them. The validator rejects `gap` here instead of letting it silently
/// do nothing. Derived from the engine's stacking predicate
/// (`canvas.widgetKindStacksChildren` in widget_layout.zig); a test in
/// ui_markup_view_tests.zig keeps this name list and that predicate in
/// lockstep so drift is impossible. (`spacer` shares the stack widget
/// kind; `scroll` and `accordion` stack children too but consume `gap`,
/// so they are excluded there and here.)
pub const known_stack_container_element_names = [_][]const u8{
    "stack",  "panel",  "card",   "spacer", "alert",
    "bubble", "dialog", "drawer", "sheet",  "resizable",
};

pub const stack_container_gap_message = "gap does nothing here: this container layers its children on top of each other - wrap them in a column (or row) inside it for flow, or drop the gap";

pub const grid_columns_element_message = "columns is only supported on grid - it fixes the grid's column count (omit it for the derived near-square grid)";

pub const avatar_image_message = "image takes one {binding} to a u64 ImageId the app registered at runtime (fx.registerImageBytes) - runtime image ids are model data, not markup literals; 0 renders the initials fallback";
pub const avatar_image_element_message = "image is only supported on avatar - the other image-bearing widgets (image, icon-button) stay Zig views (ui.image with ElementOptions.image)";

/// The built-in vector icon vocabulary behind `<icon name="..."/>`.
/// std-only mirror of `canvas.icons.known_icon_names` (the comptime-parsed
/// registry); a test in ui_markup_view_tests.zig keeps the two in
/// lockstep so a new icon cannot ship without its markup name.
pub const known_icon_names = [_][]const u8{
    "alert",       "archive",       "arrow-down",   "arrow-right",      "arrow-up",
    "check",       "check-circle",  "chevron-down", "chevron-left",     "chevron-right",
    "chevron-up",  "circle-dot",    "clock",        "copy",             "download",
    "edit",        "external-link", "eye",          "file-text",        "folder",
    "folder-open", "git-branch",    "git-merge",    "git-pull-request", "info",
    "menu",        "moon",          "music",        "pause",            "play",
    "plus",        "refresh-cw",    "repeat",       "save",             "search",
    "send",        "settings",      "shuffle",      "skip-back",        "skip-forward",
    "sun",         "trash",         "volume",       "x",                "x-circle",
};

pub const icon_name_message = "name takes a literal built-in icon name (see canvas.icons.known_icon_names, e.g. search, plus, x, check, chevron-down, settings, trash)";
pub const icon_name_element_message = "name is only supported on icon - it selects a built-in vector icon";
pub const icon_missing_name_message = "icon requires a name attribute selecting a built-in vector icon (e.g. <icon name=\"search\"/>)";
pub const icon_children_message = "icon is a leaf - it takes no children";

pub const button_icon_message = "icon takes a literal built-in icon name drawn inside the element (see canvas.icons.known_icon_names, e.g. save, plus, refresh-cw)";
pub const button_icon_element_message = "icon is only supported on button, toggle-button, list-item, menu-item, and badge - it draws a vector icon inside the element as one hit target; for a bare icon use <icon name=\"...\"/>";

/// Elements whose `icon` attribute draws an inline vector icon as part
/// of the element's OWN rendering (one hit target, one tint following
/// enabled/disabled state). Mirrors the engine kinds that consume
/// `Widget.icon`: buttons and toggle-buttons draw it before the label
/// (tab strips are toggle-button children, so tabs get icons through
/// this), list items and menu items draw it as a leading slot.
pub const known_icon_attr_element_names = [_][]const u8{ "button", "toggle-button", "list-item", "menu-item", "badge" };

pub fn iconAttrElement(name: []const u8) bool {
    return nameInList(name, &known_icon_attr_element_names);
}

pub fn anchorElement(name: []const u8) bool {
    return nameInList(name, &known_anchor_element_names);
}

pub fn dismissEventElement(name: []const u8) bool {
    return nameInList(name, &known_dismiss_element_names);
}

pub const font_coverage_message = "this text contains a character outside the bundled font's coverage - it renders as a tofu box on the reference/screenshot and mobile paths; use a vector icon (<icon name=\"...\"/> or the icon attribute) or plain words";

pub const UncoveredCodepoint = struct {
    /// Byte offset of the codepoint within the scanned literal.
    offset: usize,
    /// The codepoint's bytes (a slice of the scanned literal).
    bytes: []const u8,
    codepoint: u21,
};

/// First codepoint in a markup literal that the bundled face cannot
/// render (#98): the tofu guard's shared predicate. `{...}` binding
/// spans are skipped — dynamic values are the runtime Debug warning's
/// job — and control characters are layout, not glyphs. Invalid UTF-8
/// reports as U+FFFD at the offending byte. Comptime-callable, so the
/// compiled engine names the character in its compile error.
pub fn firstUncoveredCodepoint(text: []const u8) ?UncoveredCodepoint {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '{') {
            const close = std.mem.indexOfScalarPos(u8, text, index + 1, '}') orelse text.len;
            index = @min(text.len, close + 1);
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            return .{ .offset = index, .bytes = text[index .. index + 1], .codepoint = 0xFFFD };
        };
        if (index + len > text.len) {
            return .{ .offset = index, .bytes = text[index..], .codepoint = 0xFFFD };
        }
        const codepoint = std.unicode.utf8Decode(text[index .. index + len]) catch {
            return .{ .offset = index, .bytes = text[index .. index + len], .codepoint = 0xFFFD };
        };
        if (codepoint >= 0x20 and codepoint != 0x7F and !font_coverage.covers(codepoint)) {
            return .{ .offset = index, .bytes = text[index .. index + len], .codepoint = codepoint };
        }
        index += len;
    }
    return null;
}

/// Markup attributes whose literal values are rendered as text (so the
/// tofu guard applies): labels, placeholders, control text, and the
/// timeline item's copy channels.
pub const known_text_attr_names = [_][]const u8{ "text", "placeholder", "label", "value", "title", "description", "meta", "indicator" };

fn textNodeCoverageError(node: MarkupNode) ?MarkupErrorInfo {
    const found = firstUncoveredCodepoint(node.text) orelse return null;
    var line = node.line;
    var column = node.column;
    for (node.text[0..found.offset]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column, .message = font_coverage_message };
}

fn attrCoverageError(attribute: MarkupAttr) ?MarkupErrorInfo {
    if (!nameInList(attribute.name, &known_text_attr_names)) return null;
    const expression = parseAttrExpression(attribute.value) orelse return null;
    if (expression != .literal) return null;
    if (firstUncoveredCodepoint(expression.literal) == null) return null;
    return .{ .line = attribute.line, .column = attribute.column, .message = font_coverage_message };
}

/// Markup attributes that reference a color design token by name. Values
/// must be literal `ColorTokens` field names (`known_color_token_names`);
/// the builder resolves them against live tokens in `finalizeWithTokens`.
/// `border-color` (not bare `border`) keeps the name free for a future
/// border-width shorthand.
pub const known_color_style_attrs = [_][]const u8{
    "background", "foreground", "accent", "accent-foreground", "border-color", "focus-ring",
};

/// The field names of `canvas.ColorTokens`, kept in sync by a test in
/// ui_markup_view_tests.zig (this module stays std-only).
pub const known_color_token_names = [_][]const u8{
    "background",   "surface",     "surface_subtle",   "surface_pressed",
    "text",         "text_muted",  "border",           "accent",
    "accent_text",  "destructive", "destructive_text", "success",
    "success_text", "warning",     "warning_text",     "info",
    "info_text",    "focus_ring",  "shadow",           "disabled",
};

/// The field names of `canvas.RadiusTokens` (same sync test).
pub const known_radius_token_names = [_][]const u8{ "sm", "md", "lg", "xl" };

pub const style_token_literal_message = "style token attributes take a literal token name - dynamic styling stays in Zig";
pub const unknown_color_token_message = "unknown color token: color style attributes take a canvas ColorTokens field name (background, surface, surface_subtle, surface_pressed, text, text_muted, border, accent, accent_text, destructive, destructive_text, success, success_text, warning, warning_text, info, info_text, focus_ring, shadow, disabled)";
pub const unknown_radius_token_message = "unknown radius token: radius takes a canvas RadiusTokens field name (sm, md, lg, xl)";

pub const for_children_message = "for takes one or more element children (elements, use, if/else, or a nested for) - text content is only allowed inside text-bearing elements";
pub const else_placement_message = "else must directly follow an if (renders when the test is false) or a for (renders when the iterable is empty)";

pub const invalid_expression_message = "invalid expression: values are a literal, one {binding}, or one {a == b} equality - no other operators or calls (put logic in a model function)";
pub const arena_scalar_equality_message = "arena-computed bindings cannot be compared with == - compare the source fields directly, or bind a pub fn returning bool";
pub const markdown_source_message = "markdown requires a source attribute with one {binding} naming the markdown text (a []const u8 field or fn - arena fns work)";
pub const markdown_children_message = "markdown takes no children or text content - the source binding provides the markdown";
pub const markdown_attr_message = "unknown attribute for markdown - it takes source, on-link, on-details, details-expanded, and issue-link-base";
pub const markdown_issue_link_base_message = "issue-link-base takes a literal URL prefix or one {binding} producing it - '#123' refs become links to base ++ number (like ghissue:// or https://github.com/owner/repo/issues/)";
pub const markdown_on_link_message = "on-link takes a bare Msg tag whose payload is the pressed link URL (a []const u8 variant, like open_url: []const u8)";
pub const markdown_on_details_message = "on-details takes a bare Msg tag whose payload is the details block index (a usize variant, like toggle_details: usize)";
pub const markdown_details_expanded_message = "details-expanded takes one {binding} naming a []const bool iterable (a model field, pub decl, or fn - the same sources for each accepts)";
pub const stepper_active_message = "stepper requires an active attribute (a number or one {binding}) naming the active step index";
pub const stepper_attr_message = "unknown attribute for stepper - it takes active, key, global-key, and label";
pub const stepper_children_message = "stepper takes only step children (each step is a text leaf: <step>Work</step>)";
pub const step_parent_message = "step is only allowed inside a stepper";
pub const step_attr_message = "step takes no attributes - its content is the label text";
pub const timeline_attr_message = "unknown attribute for timeline - it takes gap, grow, key, global-key, and label";
pub const timeline_item_parent_message = "timeline-item is only allowed inside a timeline (structure tags in between are fine)";
pub const timeline_item_title_message = "timeline-item requires a title attribute (a literal or one {binding})";
pub const timeline_item_attr_message = "unknown attribute for timeline-item - it takes title, description, meta, indicator, icon, variant, connector, selected, on-press, key, and global-key";
pub const timeline_item_text_attr_message = "title, description, meta, and indicator expect text (a literal or one {binding})";
pub const timeline_item_children_message = "timeline-item takes no children - the title, description, and meta attributes provide the content";
pub const timeline_item_press_only_message = "timeline-item dispatches presses only - use on-press (other on-* events have no surface here)";
pub const text_leaf_children_message = "this element takes text content only - wrap element children in a container (row, column, stack)";
pub const text_leaf_single_run_message = "text elements take a single run of text";
pub const table_row_parent_message = "table-row is only allowed inside a table (structure tags in between are fine)";
pub const table_cell_parent_message = "table-cell is only allowed inside a table-row (structure tags in between are fine)";
pub const template_top_level_message = "template definitions are only allowed at the top of the file, before the view root";
pub const template_name_message = "template requires a name attribute";
pub const template_unique_name_message = "template names must be unique";
pub const template_args_message = "template args must be space-separated names (args=\"title cards\")";
pub const template_attrs_message = "template takes only name and args attributes";
pub const template_one_child_message = "template takes exactly one element child (wrap siblings in a container)";
pub const use_template_attr_message = "use requires a template attribute naming a template defined at the top of the file";
pub const use_undefined_template_message = "use references an undefined template (define <template name=\"...\"> before the view root)";
pub const use_earlier_template_message = "use may only reference templates defined earlier in the file";
pub const use_missing_arg_message = "use is missing an argument the template declares in args";
pub const use_extra_arg_message = "use passes an argument the template does not declare in args";
pub const use_no_children_message = "use takes no children (the template body is built in its place)";

/// Model-agnostic structural validation: unknown elements or attributes,
/// malformed expressions, misshapen structure tags, and template/use
/// wiring. Binding paths and message tags are checked against the concrete
/// Model/Msg by the interpreter; this pass is what
/// `native markup check` runs.
pub fn validate(document: MarkupDocument) ?MarkupErrorInfo {
    for (document.templates, 0..) |template_node, index| {
        if (validateTemplate(document, template_node, index)) |info| return info;
    }
    return validateNode(document, document.root, null, document.templates.len);
}

fn validateTemplate(document: MarkupDocument, node: MarkupNode, index: usize) ?MarkupErrorInfo {
    const name = node.attr("name") orelse return errorAt(node, template_name_message);
    if (!isTemplateName(name)) return errorAt(node, template_name_message);
    for (document.templates[0..index]) |earlier| {
        const earlier_name = earlier.attr("name") orelse continue;
        if (std.mem.eql(u8, earlier_name, name)) return errorAt(node, template_unique_name_message);
    }
    for (node.attrs) |attribute| {
        if (std.mem.eql(u8, attribute.name, "name")) continue;
        if (std.mem.eql(u8, attribute.name, "args")) {
            var args = templateArgs(node);
            while (args.next()) |arg_name| {
                if (!isBindingName(arg_name)) {
                    return .{ .line = attribute.line, .column = attribute.column, .message = template_args_message };
                }
            }
            continue;
        }
        return .{ .line = attribute.line, .column = attribute.column, .message = template_attrs_message };
    }
    if (node.children.len != 1 or node.children[0].kind != .element) {
        return errorAt(node, template_one_child_message);
    }
    // The body sees templates defined before this one, which also rules
    // out recursion. The body root has no known parent element, so
    // parent-scoped rules (table-row in table) are checked at use sites of
    // the surrounding markup, not here.
    return validateNode(document, node.children[0], null, index);
}

fn validateUse(document: MarkupDocument, node: MarkupNode, template_limit: usize) ?MarkupErrorInfo {
    const name = node.attr("template") orelse return errorAt(node, use_template_attr_message);
    const index = document.templateIndex(name) orelse return errorAt(node, use_undefined_template_message);
    if (index >= template_limit) return errorAt(node, use_earlier_template_message);
    if (node.children.len != 0) return errorAt(node, use_no_children_message);
    const template_node = document.templates[index];
    var args = templateArgs(template_node);
    while (args.next()) |arg_name| {
        if (node.attr(arg_name) == null) return errorAt(node, use_missing_arg_message);
    }
    for (node.attrs) |attribute| {
        if (std.mem.eql(u8, attribute.name, "template")) continue;
        if (!templateDeclaresArg(template_node, attribute.name)) {
            return .{ .line = attribute.line, .column = attribute.column, .message = use_extra_arg_message };
        }
        if (parseAttrExpression(attribute.value) == null) {
            return .{ .line = attribute.line, .column = attribute.column, .message = invalid_expression_message };
        }
    }
    return null;
}

/// `<markdown>` is a leaf whose content comes entirely from its `source`
/// binding: no children, a closed attribute set, and bare message tags for
/// `on-link`/`on-details` (the runtime supplies their payloads). Whether
/// the bindings and tags exist on the concrete Model/Msg is the engines'
/// check, exactly like ordinary bindings.
fn validateMarkdown(node: MarkupNode) ?MarkupErrorInfo {
    for (node.children) |child| {
        return errorAt(child, markdown_children_message);
    }
    var has_source = false;
    for (node.attrs) |attribute| {
        if (std.mem.eql(u8, attribute.name, "source")) {
            has_source = true;
            const expression = parseAttrExpression(attribute.value);
            if (expression == null or expression.? != .binding) {
                return .{ .line = attribute.line, .column = attribute.column, .message = markdown_source_message };
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "on-link")) {
            const expression = parseMessageExpression(attribute.value);
            if (expression == null or expression.?.payload.len != 0) {
                return .{ .line = attribute.line, .column = attribute.column, .message = markdown_on_link_message };
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "on-details")) {
            const expression = parseMessageExpression(attribute.value);
            if (expression == null or expression.?.payload.len != 0) {
                return .{ .line = attribute.line, .column = attribute.column, .message = markdown_on_details_message };
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "details-expanded")) {
            const expression = parseAttrExpression(attribute.value);
            if (expression == null or expression.? != .binding) {
                return .{ .line = attribute.line, .column = attribute.column, .message = markdown_details_expanded_message };
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "issue-link-base")) {
            const expression = parseAttrExpression(attribute.value);
            if (expression == null or expression.? == .equals) {
                return .{ .line = attribute.line, .column = attribute.column, .message = markdown_issue_link_base_message };
            }
            continue;
        }
        return .{ .line = attribute.line, .column = attribute.column, .message = markdown_attr_message };
    }
    if (!has_source) return errorAt(node, markdown_source_message);
    return null;
}

/// `<stepper active="{index}">` takes only `<step>` text-leaf children:
/// each step's state (completed/active/pending) derives from its position
/// against the active index, so steps carry no attributes of their own.
fn validateStepper(node: MarkupNode) ?MarkupErrorInfo {
    var has_active = false;
    for (node.attrs) |attribute| {
        if (std.mem.eql(u8, attribute.name, "active")) {
            has_active = true;
            if (parseAttrExpression(attribute.value) == null) {
                return .{ .line = attribute.line, .column = attribute.column, .message = stepper_active_message };
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "key") or std.mem.eql(u8, attribute.name, "global-key") or std.mem.eql(u8, attribute.name, "label")) {
            if (parseAttrExpression(attribute.value) == null) {
                return .{ .line = attribute.line, .column = attribute.column, .message = invalid_expression_message };
            }
            continue;
        }
        return .{ .line = attribute.line, .column = attribute.column, .message = stepper_attr_message };
    }
    if (!has_active) return errorAt(node, stepper_active_message);
    for (node.children) |child| {
        if (child.kind != .element or !std.mem.eql(u8, child.name, "step")) {
            return errorAt(child, stepper_children_message);
        }
        for (child.attrs) |attribute| {
            return .{ .line = attribute.line, .column = attribute.column, .message = step_attr_message };
        }
        var text_runs: usize = 0;
        for (child.children) |run| {
            if (run.kind != .text) return errorAt(run, text_leaf_children_message);
            text_runs += 1;
            if (text_runs > 1) return errorAt(run, text_leaf_single_run_message);
            if (textNodeCoverageError(run)) |info| return info;
        }
    }
    return null;
}

/// `<timeline>` is a list container with a closed attribute set; its
/// children (timeline-item elements, plus structure tags) validate
/// through the ordinary pass so `for`/`if` work inside it.
fn validateTimeline(document: MarkupDocument, node: MarkupNode, template_limit: usize) ?MarkupErrorInfo {
    for (node.attrs) |attribute| {
        const known = std.mem.eql(u8, attribute.name, "gap") or
            std.mem.eql(u8, attribute.name, "grow") or
            std.mem.eql(u8, attribute.name, "key") or
            std.mem.eql(u8, attribute.name, "global-key") or
            std.mem.eql(u8, attribute.name, "label");
        if (!known) {
            return .{ .line = attribute.line, .column = attribute.column, .message = timeline_attr_message };
        }
        if (parseAttrExpression(attribute.value) == null) {
            return .{ .line = attribute.line, .column = attribute.column, .message = invalid_expression_message };
        }
    }
    var previous_kind: ?MarkupNodeKind = null;
    for (node.children) |child| {
        if (child.kind == .else_block and previous_kind != .if_block and previous_kind != .for_block) {
            return errorAt(child, else_placement_message);
        }
        if (validateNode(document, child, "timeline", template_limit)) |info| return info;
        previous_kind = child.kind;
    }
    return null;
}

/// `<timeline-item>` is a leaf: attributes carry the content (title,
/// description, meta, indicator) and the one supported event is on-press.
fn validateTimelineItem(node: MarkupNode) ?MarkupErrorInfo {
    for (node.children) |child| {
        return errorAt(child, timeline_item_children_message);
    }
    var has_title = false;
    for (node.attrs) |attribute| {
        if (std.mem.eql(u8, attribute.name, "title")) {
            has_title = true;
            if (parseAttrExpression(attribute.value) == null) {
                return .{ .line = attribute.line, .column = attribute.column, .message = timeline_item_title_message };
            }
            if (attrCoverageError(attribute)) |info| return info;
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "on-press")) {
            if (parseMessageExpression(attribute.value) == null) {
                return .{ .line = attribute.line, .column = attribute.column, .message = "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")" };
            }
            continue;
        }
        if (std.mem.startsWith(u8, attribute.name, "on-")) {
            return .{ .line = attribute.line, .column = attribute.column, .message = timeline_item_press_only_message };
        }
        if (std.mem.eql(u8, attribute.name, "icon")) {
            // Vector icon indicator: the same closed literal vocabulary
            // as <icon name> (#96/#98 — symbols belong on the icon
            // channel, not in text glyphs).
            const expression = parseAttrExpression(attribute.value);
            const literal = if (expression) |value|
                (if (value == .literal) value.literal else null)
            else
                null;
            if (literal == null or !nameInList(literal.?, &known_icon_names)) {
                return .{ .line = attribute.line, .column = attribute.column, .message = button_icon_message };
            }
            continue;
        }
        const known = std.mem.eql(u8, attribute.name, "description") or
            std.mem.eql(u8, attribute.name, "meta") or
            std.mem.eql(u8, attribute.name, "indicator") or
            std.mem.eql(u8, attribute.name, "variant") or
            std.mem.eql(u8, attribute.name, "connector") or
            std.mem.eql(u8, attribute.name, "selected") or
            std.mem.eql(u8, attribute.name, "key") or
            std.mem.eql(u8, attribute.name, "global-key");
        if (!known) {
            return .{ .line = attribute.line, .column = attribute.column, .message = timeline_item_attr_message };
        }
        if (parseAttrExpression(attribute.value) == null) {
            return .{ .line = attribute.line, .column = attribute.column, .message = invalid_expression_message };
        }
        if (attrCoverageError(attribute)) |info| return info;
    }
    if (!has_title) return errorAt(node, timeline_item_title_message);
    return null;
}

/// `parent_element` is the name of the nearest enclosing element, looking
/// through structure tags (`for`/`if`/`else`), or null at the view root and
/// at a template body root.
fn validateNode(document: MarkupDocument, node: MarkupNode, parent_element: ?[]const u8, template_limit: usize) ?MarkupErrorInfo {
    switch (node.kind) {
        // Literal text content rides the tofu guard (#98): a codepoint
        // the bundled face cannot render is a teaching error at its
        // exact position.
        .text => return textNodeCoverageError(node),
        .template_block => return errorAt(node, template_top_level_message),
        .use_block => return validateUse(document, node, template_limit),
        .element => {
            if (std.mem.eql(u8, node.name, "markdown")) {
                return validateMarkdown(node);
            }
            if (std.mem.eql(u8, node.name, "stepper")) {
                return validateStepper(node);
            }
            if (std.mem.eql(u8, node.name, "step")) {
                // Steps inside a stepper are consumed by validateStepper;
                // one reaching the generic pass sits outside a stepper.
                return errorAt(node, step_parent_message);
            }
            if (std.mem.eql(u8, node.name, "timeline")) {
                return validateTimeline(document, node, template_limit);
            }
            if (std.mem.eql(u8, node.name, "timeline-item")) {
                if (parent_element) |parent_name| {
                    if (!std.mem.eql(u8, parent_name, "timeline")) {
                        return errorAt(node, timeline_item_parent_message);
                    }
                }
                return validateTimelineItem(node);
            }
            if (!nameInList(node.name, &known_element_names)) {
                return errorAt(node, "unknown element");
            }
            if (std.mem.eql(u8, node.name, "table-row")) {
                if (parent_element) |parent_name| {
                    if (!std.mem.eql(u8, parent_name, "table")) return errorAt(node, table_row_parent_message);
                }
            }
            if (std.mem.eql(u8, node.name, "table-cell")) {
                if (parent_element) |parent_name| {
                    if (!std.mem.eql(u8, parent_name, "table-row")) return errorAt(node, table_cell_parent_message);
                }
            }
            if (nameInList(node.name, &known_text_leaf_element_names)) {
                var text_runs: usize = 0;
                for (node.children) |child| {
                    if (child.kind != .text) return errorAt(child, text_leaf_children_message);
                    text_runs += 1;
                    if (text_runs > 1) return errorAt(child, text_leaf_single_run_message);
                }
            }
            if (std.mem.eql(u8, node.name, "icon")) {
                if (node.attr("name") == null) return errorAt(node, icon_missing_name_message);
                if (node.children.len > 0) return errorAt(node.children[0], icon_children_message);
            }
            for (node.attrs) |attribute| {
                if (std.mem.startsWith(u8, attribute.name, "on-")) {
                    if (!nameInList(attribute.name[3..], &known_events)) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = "unknown event attribute" };
                    }
                    if (std.mem.eql(u8, attribute.name, "on-scroll")) {
                        // The runtime emits scroll offsets for scroll
                        // containers only; anywhere else the handler could
                        // never fire.
                        if (!std.mem.eql(u8, node.name, "scroll")) {
                            return .{ .line = attribute.line, .column = attribute.column, .message = on_scroll_element_message };
                        }
                    } else if (std.mem.eql(u8, attribute.name, "on-dismiss")) {
                        // Only dismissible surfaces are ever dismissed by
                        // the runtime; anywhere else the Msg could never
                        // fire.
                        if (!nameInList(node.name, &known_dismiss_element_names)) {
                            return .{ .line = attribute.line, .column = attribute.column, .message = on_dismiss_element_message };
                        }
                    } else if (nameInList(node.name, &known_non_hit_target_element_names) and deadHandlerOnNonHitTarget(attribute.name)) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = non_hit_target_handler_message };
                    }
                    if (parseMessageExpression(attribute.value) == null) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")" };
                    }
                    continue;
                }
                if (nameInList(attribute.name, &known_color_style_attrs)) {
                    if (!nameInList(attribute.value, &known_color_token_names)) {
                        const message = if (parseAttrExpression(attribute.value)) |expression|
                            (if (expression == .literal) unknown_color_token_message else style_token_literal_message)
                        else
                            style_token_literal_message;
                        return .{ .line = attribute.line, .column = attribute.column, .message = message };
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "radius")) {
                    if (!nameInList(attribute.value, &known_radius_token_names)) {
                        const message = if (parseAttrExpression(attribute.value)) |expression|
                            (if (expression == .literal) unknown_radius_token_message else style_token_literal_message)
                        else
                            style_token_literal_message;
                        return .{ .line = attribute.line, .column = attribute.column, .message = message };
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "name")) {
                    // Built-in vector icon selector, icon-scoped: a closed
                    // literal vocabulary so icon references never rot.
                    if (!std.mem.eql(u8, node.name, "icon")) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = icon_name_element_message };
                    }
                    const expression = parseAttrExpression(attribute.value);
                    const literal = if (expression) |value|
                        (if (value == .literal) value.literal else null)
                    else
                        null;
                    if (literal == null or !nameInList(literal.?, &known_icon_names)) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = icon_name_message };
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "autofocus")) {
                    // A focus request needs a focusable element; layout
                    // and decoration kinds can never take the keyboard.
                    if (nameInList(node.name, &known_non_hit_target_element_names)) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = autofocus_element_message };
                    }
                    if (parseAttrExpression(attribute.value) == null) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = invalid_expression_message };
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "icon")) {
                    // Inline vector icon, scoped to the labeled
                    // interactive elements that render it themselves
                    // (`known_icon_attr_element_names`): the same closed
                    // literal vocabulary as <icon name>, drawn inside the
                    // element so icon + label are one hit target with one
                    // tint.
                    if (!iconAttrElement(node.name)) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = button_icon_element_message };
                    }
                    const expression = parseAttrExpression(attribute.value);
                    const literal = if (expression) |value|
                        (if (value == .literal) value.literal else null)
                    else
                        null;
                    if (literal == null or !nameInList(literal.?, &known_icon_names)) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = button_icon_message };
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "image")) {
                    // Runtime image binding, avatar-scoped: ids are model
                    // data the app registered, never markup literals.
                    if (!std.mem.eql(u8, node.name, "avatar")) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = avatar_image_element_message };
                    }
                    const expression = parseAttrExpression(attribute.value);
                    if (expression == null or expression.? != .binding) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = avatar_image_message };
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "anchor")) {
                    // Anchored floating placement, dropdown-menu-scoped:
                    // a literal side so the compiled engine resolves it
                    // at comptime (flip is automatic either way).
                    if (!nameInList(node.name, &known_anchor_element_names)) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = anchor_element_message };
                    }
                    if (!std.mem.eql(u8, attribute.value, "below") and !std.mem.eql(u8, attribute.value, "above")) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = anchor_value_message };
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "anchor-alignment")) {
                    if (!nameInList(node.name, &known_anchor_element_names)) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = anchor_element_message };
                    }
                    if (node.attr("anchor") == null) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = anchor_dependent_attr_message };
                    }
                    if (!std.mem.eql(u8, attribute.value, "start") and !std.mem.eql(u8, attribute.value, "end") and !std.mem.eql(u8, attribute.value, "stretch")) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = anchor_alignment_value_message };
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "anchor-offset")) {
                    if (!nameInList(node.name, &known_anchor_element_names)) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = anchor_element_message };
                    }
                    if (node.attr("anchor") == null) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = anchor_dependent_attr_message };
                    }
                    _ = std.fmt.parseFloat(f32, attribute.value) catch {
                        return .{ .line = attribute.line, .column = attribute.column, .message = anchor_offset_value_message };
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "gap") and nameInList(node.name, &known_stack_container_element_names)) {
                    return .{ .line = attribute.line, .column = attribute.column, .message = stack_container_gap_message };
                }
                if (std.mem.eql(u8, attribute.name, "columns") and !std.mem.eql(u8, node.name, "grid")) {
                    // Only the grid layout reads a column count; anywhere
                    // else it would silently do nothing (same policy as
                    // gap on stacking containers).
                    return .{ .line = attribute.line, .column = attribute.column, .message = grid_columns_element_message };
                }
                if (!nameInList(attribute.name, &known_option_attrs)) {
                    return .{ .line = attribute.line, .column = attribute.column, .message = "unknown attribute" };
                }
                if (parseAttrExpression(attribute.value) == null) {
                    return .{ .line = attribute.line, .column = attribute.column, .message = invalid_expression_message };
                }
                if (attrCoverageError(attribute)) |info| return info;
            }
        },
        .for_block => {
            if (parent_element == null) return errorAt(node, "for is only allowed inside an element");
            if (node.attr("each") == null) return errorAt(node, "for requires an each attribute");
            if (node.attr("as") == null) return errorAt(node, "for requires an as attribute");
            if (node.children.len == 0) return errorAt(node, for_children_message);
            for (node.children) |child| {
                switch (child.kind) {
                    .element, .use_block, .for_block, .if_block, .else_block => {},
                    else => return errorAt(child, for_children_message),
                }
            }
        },
        .if_block => {
            if (parent_element == null) return errorAt(node, "if is only allowed inside an element");
            const test_value = node.attr("test") orelse return errorAt(node, "if requires a test attribute");
            if (parseAttrExpression(test_value) == null) return errorAt(node, "invalid expression: test takes one {binding} or {a == b} equality");
        },
        .else_block => {},
    }
    // Structure tags are transparent for parent-scoped rules: their
    // children still sit inside the enclosing element.
    const child_parent: ?[]const u8 = switch (node.kind) {
        .element => node.name,
        .for_block, .if_block, .else_block => parent_element,
        else => null,
    };
    var previous_kind: ?MarkupNodeKind = null;
    for (node.children) |child| {
        if (child.kind == .else_block and previous_kind != .if_block and previous_kind != .for_block) {
            return errorAt(child, else_placement_message);
        }
        if (validateNode(document, child, child_parent, template_limit)) |info| {
            return info;
        }
        previous_kind = child.kind;
    }
    return null;
}

/// A single undotted binding-path segment: template arg names (they must
/// be resolvable as binding heads).
fn isBindingName(text: []const u8) bool {
    return isBindingPath(text) and std.mem.indexOfScalar(u8, text, '.') == null;
}

/// A lowercase kebab-case name, like element names: template names
/// ("board-column") are referenced by `use`, never by bindings.
fn isTemplateName(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!(text[0] >= 'a' and text[0] <= 'z')) return false;
    for (text) |byte| {
        const valid = (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '_';
        if (!valid) return false;
    }
    return true;
}

/// Length of the leading whitespace `std.mem.trim` removes from a text
/// run (comptime-callable; the comptime parser cannot do pointer math).
fn textLeadingTrim(text: []const u8) usize {
    var lead: usize = 0;
    while (lead < text.len) : (lead += 1) {
        switch (text[lead]) {
            ' ', '\t', '\r', '\n' => {},
            else => break,
        }
    }
    return lead;
}

fn nameInList(name: []const u8, list: []const []const u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn errorAt(node: MarkupNode, message: []const u8) MarkupErrorInfo {
    return .{ .line = node.line, .column = node.column, .message = message };
}
