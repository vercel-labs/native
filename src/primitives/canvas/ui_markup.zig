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
    root: MarkupNode,
};

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

    /// Parse a document: comments and whitespace around exactly one root
    /// element.
    pub fn parse(self: *Parser) ParseError!MarkupDocument {
        self.skipWhitespaceAndComments();
        const root = try self.parseElement();
        self.skipWhitespaceAndComments();
        if (self.index < self.source.len) {
            return self.fail("expected end of file after the root element");
        }
        return .{ .root = root };
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
            const text = self.takeText();
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len > 0) {
                try children.append(self.arena, .{
                    .kind = .text,
                    .text = trimmed,
                    .line = self.line,
                    .column = self.column,
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
    return .element;
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
/// ui_markup_view_tests.zig).
pub const known_element_names = [_][]const u8{
    "row",       "column",       "stack",    "panel",  "scroll",   "list",
    "grid",      "card",         "text",     "button", "checkbox", "radio",
    "toggle",    "slider",       "progress", "text-field", "search-field",
    "textarea",  "list-item",    "menu-item", "status-bar", "separator",
    "badge",     "spacer",
};

pub const known_option_attrs = [_][]const u8{
    "placeholder", "value",    "checked", "selected",    "disabled",
    "variant",     "size",     "width",   "height",      "grow",
    "gap",         "padding",  "main",    "cross",       "virtualized",
    "virtual-item-extent",     "key",     "global-key",  "role",
    "label",
};

pub const known_events = [_][]const u8{ "press", "toggle", "change", "submit", "input" };

/// Model-agnostic structural validation: unknown elements or attributes,
/// malformed expressions, and misshapen structure tags. Binding paths and
/// message tags are checked against the concrete Model/Msg by the
/// interpreter; this pass is what `zero-native markup check` runs.
pub fn validate(document: MarkupDocument) ?MarkupErrorInfo {
    return validateNode(document.root, false);
}

fn validateNode(node: MarkupNode, parent_is_element: bool) ?MarkupErrorInfo {
    switch (node.kind) {
        .text => return null,
        .element => {
            if (!nameInList(node.name, &known_element_names)) {
                return errorAt(node, "unknown element");
            }
            for (node.attrs) |attribute| {
                if (std.mem.startsWith(u8, attribute.name, "on-")) {
                    if (!nameInList(attribute.name[3..], &known_events)) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = "unknown event attribute" };
                    }
                    if (parseMessageExpression(attribute.value) == null) {
                        return .{ .line = attribute.line, .column = attribute.column, .message = "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")" };
                    }
                    continue;
                }
                if (!nameInList(attribute.name, &known_option_attrs)) {
                    return .{ .line = attribute.line, .column = attribute.column, .message = "unknown attribute" };
                }
                if (parseAttrExpression(attribute.value) == null) {
                    return .{ .line = attribute.line, .column = attribute.column, .message = "invalid expression: values are a literal, one {binding}, or one {a == b} equality - no other operators or calls (put logic in a model function)" };
                }
            }
        },
        .for_block => {
            if (!parent_is_element) return errorAt(node, "for is only allowed inside an element");
            if (node.attr("each") == null) return errorAt(node, "for requires an each attribute");
            if (node.attr("as") == null) return errorAt(node, "for requires an as attribute");
            if (node.children.len != 1 or node.children[0].kind != .element) {
                return errorAt(node, "for takes exactly one element child");
            }
        },
        .if_block => {
            if (!parent_is_element) return errorAt(node, "if is only allowed inside an element");
            const test_value = node.attr("test") orelse return errorAt(node, "if requires a test attribute");
            if (parseAttrExpression(test_value) == null) return errorAt(node, "invalid expression: test takes one {binding} or {a == b} equality");
        },
        .else_block => {},
    }
    var previous_kind: ?MarkupNodeKind = null;
    for (node.children) |child| {
        if (child.kind == .else_block and previous_kind != .if_block) {
            return errorAt(child, "else must directly follow an if");
        }
        if (validateNode(child, node.kind == .element or node.kind == .for_block or node.kind == .if_block or node.kind == .else_block)) |info| {
            return info;
        }
        previous_kind = child.kind;
    }
    return null;
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
