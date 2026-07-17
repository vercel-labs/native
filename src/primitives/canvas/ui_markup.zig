//! Markup front-end for the declarative ui builder (grammar reference:
//! skill-data/native-ui/SKILL.md).
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
const builtin = @import("builtin");
const font_coverage = @import("font_coverage.zig");

/// The vocabulary registry: elements, attributes, and events with stable
/// codes, structural predicates, and rule-hook attachments — the one
/// authoritative statement every `known_*` list below derives from (see
/// ui_schema.zig).
pub const schema = @import("ui_schema.zig");

/// The expression core: grammar, bounds, type discipline, and the one
/// evaluator both engines share (see ui_markup_expr.zig).
pub const expr = @import("ui_markup_expr.zig");

/// NSUI, the canonical document's serialized form: deterministic binary
/// with registry codes, the document hash journals anchor on, and the
/// derived JSON dump (see ui_markup_binary.zig).
pub const binary = @import("ui_markup_binary.zig");

/// The model–view contract: comptime reflection of Model/Msg into a
/// serializable artifact, the check-time verifier of markup against it
/// (both directions), and the emit/parse plumbing `native check` and the
/// per-app `zig build model-contract` step share (ui_markup_contract.zig).
pub const contract = @import("ui_markup_contract.zig");

/// Minimal-diff edit operations (write-back's write half): typed ops on a
/// parsed document that change only bytes inside the target node's span,
/// validated by reparse + structural diff before any file write
/// (ui_markup_edit.zig).
pub const edit = @import("ui_markup_edit.zig");

pub const MarkupErrorInfo = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8 = "",
    /// Source file the position refers to, relative to the markup root
    /// (the root view file's directory). Empty for single-file documents;
    /// import resolution stamps it so errors inside imported component
    /// files name the right file.
    path: []const u8 = "",
};

pub const MarkupNodeKind = enum {
    element,
    text,
    for_block,
    if_block,
    else_block,
    template_block,
    use_block,
    import_block,
    slot_block,
};

/// A half-open byte range into the SOURCE FILE the owning node was parsed
/// from (`MarkupNode.src_path` names the file after import resolution).
/// Spans are the write-back anchor: a tool edits exactly these bytes and
/// nothing else. The classic line/column positions on nodes, attributes,
/// and diagnostics are derived from the same scan (`positionAt` recomputes
/// one from the other; a conformance test holds them equal).
pub const Span = struct {
    start: usize = 0,
    end: usize = 0,
};

pub const MarkupAttr = struct {
    name: []const u8,
    value: []const u8,
    line: usize,
    column: usize,
    /// Byte range of the attribute NAME in its source file.
    name_span: Span = .{},
    /// Byte range of the attribute VALUE (inside the quotes); an empty
    /// range at the name's end for value-less attributes — which is also
    /// the insertion point a writer would use.
    value_span: Span = .{},
    /// The value parsed ONCE into its typed form, stamped by the
    /// canonicalization pass (`canonicalize`/`canonicalizeComptime`).
    /// Null on a freshly parsed document; consumers go through
    /// `attrTyped`, which classifies on the fly when the pass has not
    /// run, so canonicalization changes cost, never meaning.
    typed: ?*const TypedAttrValue = null,
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
    /// Byte range of the whole node in its source file: `<` through the
    /// closing `>` for elements (self-closing included), the trimmed
    /// visible bytes for text runs.
    span: Span = .{},
    /// For text runs that interpolate (`{...}` present): the run split
    /// ONCE into literal/binding/expression segments by canonicalization.
    /// Null on a freshly parsed document or a plain-literal run.
    typed_text: ?[]const TypedTextSegment = null,
    /// Source file this node came from, relative to the markup root.
    /// Empty for single-file documents; import resolution stamps every
    /// node of every resolved file so diagnostics name the right file.
    src_path: []const u8 = "",

    pub fn attr(self: MarkupNode, name: []const u8) ?[]const u8 {
        for (self.attrs) |attribute| {
            if (std.mem.eql(u8, attribute.name, name)) return attribute.value;
        }
        return null;
    }

    pub fn attrEntry(self: MarkupNode, name: []const u8) ?MarkupAttr {
        for (self.attrs) |attribute| {
            if (std.mem.eql(u8, attribute.name, name)) return attribute;
        }
        return null;
    }
};

pub const MarkupDocument = struct {
    /// Top-level `<import src="..."/>` nodes, in file order, before the
    /// templates. Import resolution (`resolveImports` /
    /// `resolveImportsComptime`) consumes them into `templates` and leaves
    /// this empty; a non-empty list marks the document unresolved.
    imports: []const MarkupNode = &.{},
    /// Top-level `<template name="..." args="...">` definitions, in file
    /// order (after import resolution: imported templates first, in import
    /// order, then the file's own). `<use>` sites reference them by name;
    /// a use inside a template body may only reference templates defined
    /// earlier in this list (which also rules out recursion structurally).
    templates: []const MarkupNode = &.{},
    /// The view root element. Null for a component file — a file that is
    /// all templates is valid as an import target, but an app view needs
    /// a root, which the engines enforce with a teaching error.
    root: ?MarkupNode = null,

    pub fn templateIndex(self: MarkupDocument, name: []const u8) ?usize {
        for (self.templates, 0..) |template_node, index| {
            const template_name = template_node.attr("name") orelse continue;
            if (std.mem.eql(u8, template_name, name)) return index;
        }
        return null;
    }
};

/// One declared template arg: the name, and the default literal when the
/// declaration used the `name=default` form (`args="title trend=flat"`).
pub const TemplateArg = struct {
    name: []const u8,
    default: ?[]const u8 = null,
};

/// Split one `args` token into name and optional default. Defaults are
/// literals only — a default cannot see any scope — which `validate`
/// enforces with a teaching error.
pub fn parseTemplateArg(token: []const u8) TemplateArg {
    const eq = std.mem.indexOfScalar(u8, token, '=') orelse return .{ .name = token };
    return .{ .name = token[0..eq], .default = token[eq + 1 ..] };
}

/// Iterate a template's declared args (the space-separated `args`
/// attribute; each token is `name` or `name=default`). Works at runtime
/// and comptime.
pub fn templateArgs(template_node: MarkupNode) std.mem.TokenIterator(u8, .scalar) {
    return std.mem.tokenizeScalar(u8, template_node.attr("args") orelse "", ' ');
}

pub fn templateDeclaresArg(template_node: MarkupNode, name: []const u8) bool {
    var args = templateArgs(template_node);
    while (args.next()) |token| {
        if (std.mem.eql(u8, parseTemplateArg(token).name, name)) return true;
    }
    return false;
}

/// The single `<slot/>` in a template body, or null. Does not descend into
/// `<use>` children: content passed onward belongs to the inner template's
/// slot, and a literal slot there is rejected by `validate` (v1 has no
/// slot forwarding).
pub fn templateSlot(template_node: MarkupNode) ?MarkupNode {
    if (template_node.children.len != 1) return null;
    return findSlot(template_node.children[0]);
}

fn findSlot(node: MarkupNode) ?MarkupNode {
    if (node.kind == .slot_block) return node;
    if (node.kind == .use_block) return null;
    for (node.children) |child| {
        if (findSlot(child)) |found| return found;
    }
    return null;
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
    /// top-level `<import>` nodes, then zero or more `<template>`
    /// definitions, then at most one root element. A file that is all
    /// templates (a component file) parses with a null root — it is valid
    /// as an import target; the engines require a root for a view.
    pub fn parse(self: *Parser) ParseError!MarkupDocument {
        var imports: std.ArrayListUnmanaged(MarkupNode) = .empty;
        var templates: std.ArrayListUnmanaged(MarkupNode) = .empty;
        while (true) {
            self.skipWhitespaceAndComments();
            if (self.index >= self.source.len) {
                if (imports.items.len == 0 and templates.items.len == 0) {
                    return self.fail(empty_document_message);
                }
                return .{ .imports = imports.items, .templates = templates.items, .root = null };
            }
            const node = try self.parseElement();
            if (node.kind == .import_block) {
                if (templates.items.len > 0) {
                    return self.failAt(node.line, node.column, import_top_level_message);
                }
                try imports.append(self.arena, node);
                continue;
            }
            if (node.kind == .template_block) {
                if (templates.items.len >= max_document_templates) {
                    return self.failAt(node.line, node.column, max_templates_message);
                }
                try templates.append(self.arena, node);
                continue;
            }
            self.skipWhitespaceAndComments();
            if (self.index < self.source.len) {
                return self.fail("expected end of file after the root element");
            }
            return .{ .imports = imports.items, .templates = templates.items, .root = node };
        }
    }

    fn parseElement(self: *Parser) ParseError!MarkupNode {
        const start_line = self.line;
        const start_column = self.column;
        const start_offset = self.index;
        if (!self.consumeByte('<')) return self.fail("expected '<' to open an element");
        const name = try self.parseName("element name");

        var attrs: std.ArrayListUnmanaged(MarkupAttr) = .empty;
        while (true) {
            self.skipWhitespace();
            const byte = self.peek() orelse return self.fail("unterminated element tag");
            if (byte == '/' or byte == '>') break;
            const attr_line = self.line;
            const attr_column = self.column;
            const name_start = self.index;
            const attr_name = try self.parseName("attribute name");
            const name_end = self.index;
            var value: []const u8 = "";
            var value_span = Span{ .start = name_end, .end = name_end };
            self.skipWhitespace();
            if (self.consumeByte('=')) {
                self.skipWhitespace();
                value = try self.parseQuotedValue();
                value_span = .{ .start = self.index - value.len - 1, .end = self.index - 1 };
            }
            try attrs.append(self.arena, .{
                .name = attr_name,
                .value = value,
                .line = attr_line,
                .column = attr_column,
                .name_span = .{ .start = name_start, .end = name_end },
                .value_span = value_span,
            });
        }

        var node = MarkupNode{
            .kind = nodeKindForName(name),
            .name = name,
            .attrs = attrs.items,
            .line = start_line,
            .column = start_column,
            .span = .{ .start = start_offset, .end = start_offset },
        };

        if (self.consumeByte('/')) {
            if (!self.consumeByte('>')) return self.fail("expected '>' after '/' in a self-closing tag");
            node.span.end = self.index;
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
            const text_offset = self.index;
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
                const visible_start = text_offset + textLeadingTrim(text);
                try children.append(self.arena, .{
                    .kind = .text,
                    .text = trimmed,
                    .line = line,
                    .column = column,
                    .span = .{ .start = visible_start, .end = visible_start + trimmed.len },
                });
            }
        }

        node.children = children.items;
        if (std.mem.eql(u8, name, "text")) {
            node.children = try self.spliceInlineSeparators(node.children);
        }
        node.span.end = self.index;
        return node;
    }

    /// Whitespace between a span paragraph's inline children is STRUCTURE:
    /// the parser trims every text run, so "value <span>42</span>" would
    /// otherwise render "value42". When a <text> holds span children, any
    /// source whitespace between two adjacent content children collapses
    /// to ONE single-space text node spliced between them — materialized
    /// here, at parse time, so the spacing is ordinary text content that
    /// serializes, hashes, and round-trips like any other run (the NSUI
    /// document hash strips spans, so spacing can never live in byte
    /// gaps). Runs written with no whitespace between them abut, which is
    /// how a mono run takes trailing punctuation. Span-less text keeps
    /// the classic trim exactly as before.
    fn spliceInlineSeparators(self: *Parser, children: []const MarkupNode) ParseError![]const MarkupNode {
        if (!childrenIncludeSpan(children)) return children;
        var separators: usize = 0;
        for (children[1..], children[0 .. children.len - 1]) |next, previous| {
            if (gapHasInlineSpace(self.source, previous.span.end, next.span.start)) separators += 1;
        }
        if (separators == 0) return children;
        const out = try self.arena.alloc(MarkupNode, children.len + separators);
        var len: usize = 0;
        for (children, 0..) |child, index| {
            if (index > 0 and gapHasInlineSpace(self.source, children[index - 1].span.end, child.span.start)) {
                out[len] = inlineSeparatorNode(self.source, children[index - 1].span.end, child.span.start);
                len += 1;
            }
            out[len] = child;
            len += 1;
        }
        return out[0..len];
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

pub const Position = struct { line: usize, column: usize };

/// Line/column (1-based; columns count bytes, matching the parser) of a
/// byte offset in a source. This is the DERIVATION diagnostics rest on:
/// spans are the authoritative positions, line/column their display form,
/// and a conformance test holds the parser's stamped line/column equal to
/// `positionAt(source, span.start)` for every node and attribute.
pub fn positionAt(source: []const u8, offset: usize) Position {
    var line: usize = 1;
    var column: usize = 1;
    const clamped = @min(offset, source.len);
    for (source[0..clamped]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

fn nodeKindForName(name: []const u8) MarkupNodeKind {
    if (std.mem.eql(u8, name, "for")) return .for_block;
    if (std.mem.eql(u8, name, "if")) return .if_block;
    if (std.mem.eql(u8, name, "else")) return .else_block;
    if (std.mem.eql(u8, name, "template")) return .template_block;
    if (std.mem.eql(u8, name, "use")) return .use_block;
    if (std.mem.eql(u8, name, "import")) return .import_block;
    if (std.mem.eql(u8, name, "slot")) return .slot_block;
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
        var imports: []const MarkupNode = &.{};
        var templates: []const MarkupNode = &.{};
        while (true) {
            parser.skipWhitespaceAndComments();
            if (parser.index >= parser.source.len) {
                if (imports.len == 0 and templates.len == 0) {
                    failComptime(&parser, parser.fail(empty_document_message));
                }
                return .{ .imports = imports, .templates = templates, .root = null };
            }
            const node = parseElementComptime(&parser);
            if (node.kind == .import_block) {
                if (templates.len > 0) {
                    failComptime(&parser, parser.failAt(node.line, node.column, import_top_level_message));
                }
                imports = imports ++ &[_]MarkupNode{node};
                continue;
            }
            if (node.kind == .template_block) {
                if (templates.len >= max_document_templates) {
                    failComptime(&parser, parser.failAt(node.line, node.column, max_templates_message));
                }
                templates = templates ++ &[_]MarkupNode{node};
                continue;
            }
            parser.skipWhitespaceAndComments();
            if (parser.index < parser.source.len) {
                failComptime(&parser, parser.fail("expected end of file after the root element"));
            }
            return .{ .imports = imports, .templates = templates, .root = node };
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
    const start_offset = parser.index;
    if (!parser.consumeByte('<')) failComptime(parser, parser.fail("expected '<' to open an element"));
    const name = parser.parseName("element name") catch |err| failComptime(parser, err);

    var attrs: []const MarkupAttr = &.{};
    while (true) {
        parser.skipWhitespace();
        const byte = parser.peek() orelse failComptime(parser, parser.fail("unterminated element tag"));
        if (byte == '/' or byte == '>') break;
        const attr_line = parser.line;
        const attr_column = parser.column;
        const name_start = parser.index;
        const attr_name = parser.parseName("attribute name") catch |err| failComptime(parser, err);
        const name_end = parser.index;
        var value: []const u8 = "";
        var value_span = Span{ .start = name_end, .end = name_end };
        parser.skipWhitespace();
        if (parser.consumeByte('=')) {
            parser.skipWhitespace();
            value = parser.parseQuotedValue() catch |err| failComptime(parser, err);
            value_span = .{ .start = parser.index - value.len - 1, .end = parser.index - 1 };
        }
        attrs = attrs ++ &[_]MarkupAttr{.{
            .name = attr_name,
            .value = value,
            .line = attr_line,
            .column = attr_column,
            .name_span = .{ .start = name_start, .end = name_end },
            .value_span = value_span,
        }};
    }

    var node = MarkupNode{
        .kind = nodeKindForName(name),
        .name = name,
        .attrs = attrs,
        .line = start_line,
        .column = start_column,
        .span = .{ .start = start_offset, .end = start_offset },
    };

    if (parser.consumeByte('/')) {
        if (!parser.consumeByte('>')) failComptime(parser, parser.fail("expected '>' after '/' in a self-closing tag"));
        node.span.end = parser.index;
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
        const text_offset = parser.index;
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
            const visible_start = text_offset + textLeadingTrim(text);
            children = children ++ &[_]MarkupNode{.{
                .kind = .text,
                .text = trimmed,
                .line = line,
                .column = column,
                .span = .{ .start = visible_start, .end = visible_start + trimmed.len },
            }};
        }
    }

    node.children = children;
    if (std.mem.eql(u8, name, "text")) {
        node.children = spliceInlineSeparatorsComptime(parser.source, node.children);
    }
    node.span.end = parser.index;
    return node;
}

/// Comptime mirror of `Parser.spliceInlineSeparators`: identical gap
/// predicate and separator shape, with comptime slice concatenation in
/// place of the arena — both engines see one materialized document.
fn spliceInlineSeparatorsComptime(comptime source: []const u8, comptime children: []const MarkupNode) []const MarkupNode {
    comptime {
        if (!childrenIncludeSpan(children)) return children;
        var out: []const MarkupNode = &.{};
        for (children, 0..) |child, index| {
            if (index > 0 and gapHasInlineSpace(source, children[index - 1].span.end, child.span.start)) {
                out = out ++ &[_]MarkupNode{inlineSeparatorNode(source, children[index - 1].span.end, child.span.start)};
            }
            out = out ++ &[_]MarkupNode{child};
        }
        return out;
    }
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
    /// Any other `{...}` content: the total expression grammar
    /// (arithmetic, comparisons, boolean logic, `++` concatenation, and
    /// the closed function library — see ui_markup_expr.zig). The payload
    /// is the raw inner text; classification does not parse it, so
    /// consumers (the validator via `attrExpressionError`, the engines via
    /// their evaluators) surface the specific teaching message themselves.
    expression: []const u8,
};

/// Parse an attribute value: a plain literal, or exactly one brace-wrapped
/// expression — a bare `{path}` binding, the legacy `{a == b}` path
/// equality, or the full expression grammar. Mixed literal and binding
/// text is only allowed in text content (interpolation), not in attribute
/// values.
pub fn parseAttrExpression(value: []const u8) ?Expression {
    if (value.len == 0 or value[0] != '{') return .{ .literal = value };
    if (value[value.len - 1] != '}') return null;
    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " ");
    if (inner.len == 0) return null;
    if (std.mem.indexOf(u8, inner, "==")) |eq| {
        const left = std.mem.trim(u8, inner[0..eq], " ");
        const right = std.mem.trim(u8, inner[eq + 2 ..], " ");
        if (isBindingPath(left) and isBindingPath(right)) {
            return .{ .equals = .{ .left = left, .right = right } };
        }
    }
    if (isBindingPath(inner)) return .{ .binding = inner };
    return .{ .expression = inner };
}

/// Structural check of an attribute expression, shared by the validator
/// (what `native markup check` runs, with no model in hand): syntax,
/// bounds, function names and arity, and the type discipline over the
/// parts whose types are already known (literals and operators). Binding
/// types are the engines' job. Returns the teaching message, or null when
/// the value is fine; `fallback` is the caller's message for values that
/// do not even classify (unterminated braces, empty `{}`).
pub fn attrExpressionError(value: []const u8, fallback: []const u8) ?[]const u8 {
    const expression = parseAttrExpression(value) orelse return fallback;
    if (expression != .expression) return null;
    return expressionTextError(expression.expression);
}

/// The structural check for one expression's inner text (also used for
/// text-interpolation segments).
pub fn expressionTextError(inner: []const u8) ?[]const u8 {
    var tree: expr.ExprTree = .{};
    var diagnostic: expr.Diagnostic = .{};
    if (!expr.parse(inner, &tree, &diagnostic)) return diagnostic.message;
    const unknown: [expr.max_expression_nodes]?expr.ValueKind = @splat(null);
    _ = expr.checkTypes(&tree, &unknown, &diagnostic) catch return diagnostic.message;
    return null;
}

/// First uncovered codepoint inside an expression's STRING LITERALS: the
/// tofu guard for text an expression can inject into a rendered label
/// (`{plural(n, 'item', 'items')}`). Binding values stay the runtime
/// Debug warning's job, exactly like plain `{binding}` spans.
pub fn expressionStringCoverageError(inner: []const u8) bool {
    var tree: expr.ExprTree = .{};
    var diagnostic: expr.Diagnostic = .{};
    if (!expr.parse(inner, &tree, &diagnostic)) return false;
    for (tree.nodes[0..tree.len]) |node| {
        if (node.kind != .literal_string) continue;
        if (firstUncoveredCodepoint(node.text) != null) return true;
    }
    return false;
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

pub const isBindingPath = expr.isBindingPath;

// --------------------------------------------------- typed document pass
//
// The canonical form of an attribute value or interpolated text run: raw
// strings classified and parsed ONCE, at document level, instead of at
// every use by every engine on every frame. `canonicalize` (runtime) and
// `canonicalizeComptime` (the compiled engine's path) stamp these onto a
// parsed/resolved document; `attrTyped` is the accessor every consumer
// reads, with an on-the-fly classification fallback for documents the
// pass has not touched — canonicalization can only change cost, never
// meaning, which is what keeps the two engines' parity suites authoritative
// over this pass.

/// A full `{expression}`: the inner text plus its tree, parsed once. The
/// tree is null when the text does not parse — the engines re-run the
/// parser at the use site to surface the exact teaching diagnostic, so a
/// broken expression fails identically with or without canonicalization.
pub const TypedExprRef = struct {
    inner: []const u8,
    tree: ?*const expr.ExprTree = null,
};

pub const TypedAttrValue = union(enum) {
    literal: []const u8,
    binding: []const u8,
    equals: struct { left: []const u8, right: []const u8 },
    expression: TypedExprRef,
    /// `on-*` attributes: the message tag plus optional payload path.
    message: MessageExpression,
    /// The value did not classify (unterminated braces, empty `{}`, a
    /// malformed message expression); the engines surface their
    /// context-specific teaching message at the use site.
    invalid,
};

/// One segment of an interpolating text run.
pub const TypedTextSegment = union(enum) {
    literal: []const u8,
    binding: []const u8,
    expression: TypedExprRef,
    /// An unterminated `{`: preserved so the engines report the same
    /// "unterminated interpolation" error they always did.
    unterminated,
};

/// Classify one attribute value into its typed form (no expression-tree
/// parse; trees are the canonicalization passes' job). The attribute NAME
/// picks the grammar: `on-*` values are message expressions, everything
/// else is the attr-expression grammar — exactly the split both engines
/// already applied per use.
pub fn classifyAttrValue(name: []const u8, value: []const u8) TypedAttrValue {
    if (std.mem.startsWith(u8, name, "on-")) {
        const message = parseMessageExpression(value) orelse return .invalid;
        return .{ .message = message };
    }
    const expression = parseAttrExpression(value) orelse return .invalid;
    return switch (expression) {
        .literal => |text| .{ .literal = text },
        .binding => |path| .{ .binding = path },
        .equals => |sides| .{ .equals = .{ .left = sides.left, .right = sides.right } },
        .expression => |inner| .{ .expression = .{ .inner = inner } },
    };
}

/// The typed value of an attribute: the canonicalized form when present,
/// else an on-the-fly classification with identical semantics (minus the
/// pre-parsed tree).
pub fn attrTyped(attribute: MarkupAttr) TypedAttrValue {
    if (attribute.typed) |typed| return typed.*;
    return classifyAttrValue(attribute.name, attribute.value);
}

/// Canonicalize a parsed (and, for imports, resolved) document: every
/// attribute value and interpolating text run parses once into its typed
/// form. Nodes are copied; the input document stays valid.
pub fn canonicalize(arena: std.mem.Allocator, document: MarkupDocument) error{OutOfMemory}!MarkupDocument {
    var out = document;
    if (document.templates.len > 0) {
        const templates = try arena.alloc(MarkupNode, document.templates.len);
        for (document.templates, 0..) |template_node, index| {
            templates[index] = try canonicalizeNode(arena, template_node);
        }
        out.templates = templates;
    }
    if (document.root) |root| {
        out.root = try canonicalizeNode(arena, root);
    }
    return out;
}

fn canonicalizeNode(arena: std.mem.Allocator, node: MarkupNode) error{OutOfMemory}!MarkupNode {
    var out = node;
    if (node.attrs.len > 0) {
        const attrs = try arena.alloc(MarkupAttr, node.attrs.len);
        for (node.attrs, 0..) |attribute, index| {
            attrs[index] = attribute;
            const slot = try arena.create(TypedAttrValue);
            slot.* = typedValueOf(arena, attribute) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            attrs[index].typed = slot;
        }
        out.attrs = attrs;
    }
    if (node.kind == .text and std.mem.indexOfScalar(u8, node.text, '{') != null) {
        out.typed_text = try typedTextSegments(arena, node.text);
    }
    if (node.children.len > 0) {
        const children = try arena.alloc(MarkupNode, node.children.len);
        for (node.children, 0..) |child, index| {
            children[index] = try canonicalizeNode(arena, child);
        }
        out.children = children;
    }
    return out;
}

fn typedValueOf(arena: std.mem.Allocator, attribute: MarkupAttr) error{OutOfMemory}!TypedAttrValue {
    var typed = classifyAttrValue(attribute.name, attribute.value);
    if (typed == .expression) {
        typed.expression.tree = try parsedTree(arena, typed.expression.inner);
    }
    return typed;
}

/// Parse one expression's tree into the arena; null when it does not
/// parse (the engines re-derive the diagnostic at the use site).
fn parsedTree(arena: std.mem.Allocator, inner: []const u8) error{OutOfMemory}!?*const expr.ExprTree {
    const tree = try arena.create(expr.ExprTree);
    tree.* = .{};
    var diagnostic: expr.Diagnostic = .{};
    if (!expr.parse(inner, tree, &diagnostic)) return null;
    return tree;
}

/// Split an interpolating text run into typed segments, mirroring the
/// engines' scan byte for byte: literal chunks between braces, `{path}`
/// bindings, full expressions, and the unterminated tail case.
fn typedTextSegments(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const TypedTextSegment {
    var segments: std.ArrayListUnmanaged(TypedTextSegment) = .empty;
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        if (open > 0) try segments.append(arena, .{ .literal = rest[0..open] });
        const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse {
            try segments.append(arena, .unterminated);
            return segments.items;
        };
        const inner = std.mem.trim(u8, rest[open + 1 .. close], " ");
        if (isBindingPath(inner)) {
            try segments.append(arena, .{ .binding = inner });
        } else {
            try segments.append(arena, .{ .expression = .{ .inner = inner, .tree = try parsedTree(arena, inner) } });
        }
        rest = rest[close + 1 ..];
    }
    if (rest.len > 0) try segments.append(arena, .{ .literal = rest });
    return segments.items;
}

/// Comptime mirror of `canonicalize` for the compiled engine's documents:
/// same classification, same segment scan, with comptime consts in place
/// of arena allocations. The branch quota scales with the tree it walks.
pub fn canonicalizeComptime(comptime document: MarkupDocument) MarkupDocument {
    comptime {
        @setEvalBranchQuota(comptime_parse_quota_base +
            (documentByteSize(document) + 1) * comptime_canonicalize_quota_per_byte);
        var out = document;
        var templates: []const MarkupNode = &.{};
        for (document.templates) |template_node| {
            templates = templates ++ &[_]MarkupNode{canonicalizeNodeComptime(template_node)};
        }
        out.templates = templates;
        if (document.root) |root| out.root = canonicalizeNodeComptime(root);
        return out;
    }
}

const comptime_canonicalize_quota_per_byte = 400;

fn documentByteSize(comptime document: MarkupDocument) usize {
    comptime {
        var total: usize = 0;
        for (document.templates) |template_node| total += nodeByteSize(template_node);
        if (document.root) |root| total += nodeByteSize(root);
        return total;
    }
}

fn nodeByteSize(comptime node: MarkupNode) usize {
    comptime {
        var total: usize = node.text.len + node.name.len;
        for (node.attrs) |attribute| total += attribute.name.len + attribute.value.len;
        for (node.children) |child| total += nodeByteSize(child);
        return total;
    }
}

fn canonicalizeNodeComptime(comptime node: MarkupNode) MarkupNode {
    comptime {
        var out = node;
        if (node.attrs.len > 0) {
            var attrs: []const MarkupAttr = &.{};
            for (node.attrs) |attribute| {
                var stamped = attribute;
                const frozen: TypedAttrValue = typedValueComptime(attribute);
                stamped.typed = &frozen;
                attrs = attrs ++ &[_]MarkupAttr{stamped};
            }
            out.attrs = attrs;
        }
        if (node.kind == .text and std.mem.indexOfScalar(u8, node.text, '{') != null) {
            out.typed_text = typedTextSegmentsComptime(node.text);
        }
        if (node.children.len > 0) {
            var children: []const MarkupNode = &.{};
            for (node.children) |child| {
                children = children ++ &[_]MarkupNode{canonicalizeNodeComptime(child)};
            }
            out.children = children;
        }
        return out;
    }
}

fn typedValueComptime(comptime attribute: MarkupAttr) TypedAttrValue {
    comptime {
        var typed = classifyAttrValue(attribute.name, attribute.value);
        if (typed == .expression) {
            typed.expression.tree = parsedTreeComptime(typed.expression.inner);
        }
        return typed;
    }
}

fn parsedTreeComptime(comptime inner: []const u8) ?*const expr.ExprTree {
    comptime {
        var tree: expr.ExprTree = .{};
        var diagnostic: expr.Diagnostic = .{};
        if (!expr.parse(inner, &tree, &diagnostic)) return null;
        const frozen = tree;
        return &frozen;
    }
}

fn typedTextSegmentsComptime(comptime text: []const u8) []const TypedTextSegment {
    comptime {
        var segments: []const TypedTextSegment = &.{};
        var rest = text;
        while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
            if (open > 0) segments = segments ++ &[_]TypedTextSegment{.{ .literal = rest[0..open] }};
            const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse {
                return segments ++ &[_]TypedTextSegment{.unterminated};
            };
            const inner = std.mem.trim(u8, rest[open + 1 .. close], " ");
            if (isBindingPath(inner)) {
                segments = segments ++ &[_]TypedTextSegment{.{ .binding = inner }};
            } else {
                segments = segments ++ &[_]TypedTextSegment{.{ .expression = .{ .inner = inner, .tree = parsedTreeComptime(inner) } }};
            }
            rest = rest[close + 1 ..];
        }
        if (rest.len > 0) segments = segments ++ &[_]TypedTextSegment{.{ .literal = rest }};
        return segments;
    }
}

// ------------------------------------------------------------ validation

/// Element names the interpreter accepts, derived from the registry
/// (ui_schema.zig; the registry↔engine conformance tests live in
/// ui_markup_view_tests.zig). Covers every built-in component whose shape
/// fits the closed grammar; the deliberate exclusions (image,
/// icon-button, data-grid, popover, menu-surface, segmented-control) are
/// documented next to the widget-kind coverage test in
/// ui_markup_view_tests.zig — write those as Zig view functions.
pub const known_element_names = schema.element_names;

/// Elements whose content is a single run of text (with `{}`
/// interpolation) and that take no element children. Registry-derived;
/// held equal to the interpreter's `elementTakesText` by a conformance
/// test in ui_markup_view_tests.zig.
pub const known_text_leaf_element_names = schema.text_leaf_element_names;

/// Text-taking elements that ALSO accept element children in place of the
/// text run (the list-row composite: children flow inside the element's
/// own chrome). Registry-derived; held equal to the interpreter's
/// `elementTakesChildren` by a conformance test in
/// ui_markup_view_tests.zig.
pub const known_text_or_children_element_names = schema.text_or_children_element_names;

/// The generic option attributes (registry-derived; the order is the
/// did-you-mean/completion display order).
pub const known_option_attrs = schema.option_attr_names;

/// The event vocabulary (registry-derived; markup spells these `on-*`).
pub const known_events = schema.event_names;

pub const on_scroll_element_message = "on-scroll is only supported on scroll - the runtime emits scroll offsets for scroll containers, so the handler belongs on the scroll element itself";
pub const on_reach_end_element_message = "on-reach-end is only supported on scroll - the runtime emits the approach-end signal for scroll containers, so the handler belongs on the scroll element itself";
pub const on_scroll_payload_message = "on-scroll takes a bare Msg tag whose payload is the post-scroll state (a canvas.ScrollState variant, like activity_scrolled: canvas.ScrollState, or a declared record of its offset/velocity/viewport_extent/content_extent fields for transpiled cores)";

pub const on_resize_element_message = "on-resize is only supported on split - the runtime emits fraction changes for split dividers, so the handler belongs on the split element itself";
pub const on_resize_payload_message = "on-resize takes a bare Msg tag whose payload is the new first-pane fraction (an f32 variant, like sidebar_resized: f32; transpiled cores declare a one-number float arm)";
pub const split_children_message = "split takes exactly two element children (the panes) - put conditional or repeated content inside a pane container, and nest splits for more panes";

/// Elements the runtime's dismissal machinery closes (Escape, click
/// outside, automation/accessibility dismiss) — the markup subset of the
/// engine's dismissible-surface kinds (`canvas.widgetKindDismissibleSurface`;
/// popover/menu-surface/tooltip stay Zig views or leaves).
/// Registry-derived from the `dismissible` element predicate.
pub const known_dismiss_element_names = schema.dismiss_element_names;

pub const on_dismiss_element_message = "on-dismiss is only supported on dismissible surfaces (dialog, drawer, sheet, dropdown-menu) - Escape and click-outside dismiss those, and the Msg lets the model own the close (clear the open flag in update)";

/// Elements that may float as anchored surfaces. dropdown-menu and
/// tooltip are the markup channels; popover/menu-surface stay Zig views
/// (documented exclusions) and dialogs/drawers/sheets place themselves.
/// An anchored tooltip's visibility is RUNTIME-owned (hover intent on
/// its trigger), unlike the model-owned dropdown.
/// Registry-derived from the `anchorable` element predicate.
pub const known_anchor_element_names = schema.anchor_element_names;

pub const anchor_element_message = "anchor is only supported on dropdown-menu and tooltip - it floats the surface against its PARENT's frame (put the dropdown or tooltip beside its trigger inside a stack); dialogs, drawers, and sheets place themselves";
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
/// these elements and stay validation errors. Registry-derived from the
/// `hit_target` element predicate, which mirrors the engine's kind
/// predicate (`canvas.widgetKindHitTarget` in widget_access.zig); a
/// conformance test in ui_markup_view_tests.zig keeps the registry and
/// that predicate in lockstep so drift is impossible.
pub const known_non_hit_target_element_names = schema.non_hit_target_element_names;

/// The handlers that stay dead on layout/decoration elements: press and
/// toggle make any element pressable, scroll has its own element-scoped
/// rule (`on_scroll_element_message`), and the registry's
/// `dead_on_non_hit_target` events bind control/text behavior the element
/// does not have.
pub fn deadHandlerOnNonHitTarget(attr_name: []const u8) bool {
    if (!std.mem.startsWith(u8, attr_name, "on-")) return false;
    const entry = schema.eventByName(attr_name[3..]) orelse return false;
    return entry.dead_on_non_hit_target;
}

pub const autofocus_element_message = "autofocus is only supported on focusable controls (text fields, buttons, checkboxes, ...) - it moves keyboard focus to the element when it mounts or when the flag turns on, and nothing about this element can take focus";

pub const non_hit_target_handler_message = "on-change/on-submit/on-input never fire here: this element has no control or text behavior - put them on a control (input, checkbox, slider) inside it (on-press/on-toggle are fine anywhere: a bound press handler makes any element pressable, and clicks on plain text or icons inside it fall through to it)";

/// Elements whose widget kind layers its children on top of each other
/// (every child gets the full content box), so `gap` can never space
/// them. The validator rejects `gap` here instead of letting it silently
/// do nothing. Registry-derived from the `stacks_children` element
/// predicate, which mirrors the engine's stacking predicate
/// (`canvas.widgetKindStacksChildren` in widget_layout.zig); a
/// conformance test in ui_markup_view_tests.zig keeps the registry and
/// that predicate in lockstep so drift is impossible. (`spacer` shares
/// the stack widget kind; `scroll` and `accordion` stack children too but
/// consume `gap`, so they are excluded there and here.)
pub const known_stack_container_element_names = schema.stack_container_element_names;

pub const stack_container_gap_message = "gap does nothing here: this container layers its children on top of each other - wrap them in a column (or row) inside it for flow, or drop the gap";

pub const wrap_element_message = "wrap is only supported on text - only plain text leaves take a line policy (wrap=\"true\" word-wraps and reserves height; wrap=\"false\" and unset paint one honest line whose overflow follows the overflow attribute, trailing ellipsis by default); put wrap on the text leaf itself, or size the container so content fits (rows and columns never flow-wrap their children)";

pub const overflow_element_message = "overflow is only supported on text - it names a single-line text leaf's policy for content that does not fit (ellipsis elides behind a trailing \u{2026}, clip hard-cuts at the frame); put overflow on the text leaf itself, or size the container so content fits";

/// The `overflow` attribute's closed value vocabulary: the member names
/// of `canvas.TextOverflow`, mirrored as data here (this layer stays
/// std-only) with a lockstep test in ui_markup_view_tests.zig holding the
/// mirror equal to the live enum.
pub const overflow_value_names = [_][]const u8{ "ellipsis", "clip" };

pub const overflow_value_message = "unknown overflow value - text takes ellipsis (the default: elide overflow behind a trailing \u{2026}) or clip (hard-cut at the frame, for fixed-format content like a duration column); overflow-visible is not offered because painting past the frame is the bug class the layout audit exists to catch";

/// The `size` attribute's control-scale values (every sized element) and
/// its typography rungs (text only). Registry-derived; lockstep tests in
/// ui_markup_view_tests.zig hold the mirrors equal to `canvas.WidgetSize`.
pub const known_control_size_value_names = schema.control_size_value_names;
pub const known_text_size_value_names = schema.text_size_value_names;

pub const size_value_message = "unknown size value - controls take default, sm, lg, or icon, and text also takes heading or display (the typography rungs above title); numeric sizes are not accepted by design - retheme the typography tokens (TypographyTokenOverrides) to move the whole scale";

pub const text_size_element_message = "heading and display are typography rungs only text takes - they name themable typography token steps (heading_size, display_size), a different axis from the control scale; put the size on the text element itself, or use the control scale here (default, sm, lg, icon)";

pub const grid_columns_element_message = "columns is only supported on grid - it fixes the grid's column count (omit it for the derived near-square grid)";

pub const overscroll_element_message = "overscroll is only supported on scroll - it names a scroll region's edge behavior (none pins at the content edges, rubber_band lets the region bounce past them, default follows the ScrollPhysics.overscroll token); anywhere else it would be silently inert";

pub const quiet_hover_element_message = "quiet-hover is only supported on pressable elements (hit targets like list-item, button, panel) - it opts an image-forward content tile out of the HOVER wash while press feedback, the focus ring, cursor intent, and hit testing keep their own channels; on a non-interactive element it would be silently inert";

/// The `overscroll` attribute's closed value vocabulary: the member names
/// of `canvas.WidgetOverscroll`, mirrored as data here (this layer stays
/// std-only) with a lockstep test in ui_markup_view_tests.zig holding the
/// mirror equal to the live enum.
pub const overscroll_value_names = [_][]const u8{ "default", "none", "rubber_band" };

pub const overscroll_value_message = "unknown overscroll value - scroll takes default (follow the ScrollPhysics.overscroll token, off unless a theme flips it), none (pin at the content edges), or rubber_band (bounce past them)";

pub const resize_duration_element_message = "resize-duration is only supported on split - it declares the split's layout tween (milliseconds; 0 snaps, the default): a rebuild that moves the bound value eases the rendered fraction there instead of snapping; anywhere else it would be silently inert";

pub const resize_easing_element_message = "resize-easing is only supported on split - it names the easing curve of the split's layout tween (linear, standard, emphasized, spring); anywhere else it would be silently inert";

/// The `resize-easing` attribute's closed value vocabulary: the member
/// names of `canvas.Easing`, mirrored as data here (this layer stays
/// std-only) with a lockstep test in ui_markup_view_tests.zig holding the
/// mirror equal to the live enum.
pub const resize_easing_value_names = [_][]const u8{ "linear", "standard", "emphasized", "spring" };

pub const resize_easing_value_message = "unknown resize-easing value - split takes linear, standard (the default), emphasized, or spring";

pub const resize_easing_dependent_attr_message = "resize-easing needs a nonzero resize-duration on the same split - without a duration the split snaps and the easing is silently inert";

pub const resize_origin_element_message = "resize-origin is only supported on split - it names the fraction a freshly mounted split's pane boundary slides in from (its children keep the declared value's pose); anywhere else it would be silently inert";

pub const resize_origin_dependent_attr_message = "resize-origin needs a nonzero resize-duration on the same split - without a duration a mount lands on its value and the origin is silently inert";

pub const tooltip_delay_element_message = "tooltip-delay is only supported on tooltip - it sets the hover-intent show delay (milliseconds; 0 shows the instant the trigger is hovered) the runtime waits before showing an ANCHORED tooltip; anywhere else it would be silently inert";

pub const tooltip_delay_dependent_attr_message = "tooltip-delay needs anchor on the same tooltip - only an anchored tooltip is hover-shown by the runtime (a static tooltip paints whenever the view renders it), so without anchor the delay is silently inert";

pub const avatar_image_message = "image takes one {binding} to a u64 ImageId the app registered at runtime (fx.registerImageBytes) - runtime image ids are model data, not markup literals; 0 renders the initials fallback";
pub const avatar_image_element_message = "image is only supported on avatar - the other image-bearing widgets (image, icon-button) stay Zig views (ui.image with ElementOptions.image)";

pub const media_surface_surface_message = "surface takes one {binding} to the u64 surface id a producer targets (runtime.acquireMediaSurfaceProducer) - surface ids are model data, not markup literals; 0 leaves the surface unbound and it draws nothing";
pub const media_surface_surface_element_message = "surface is only supported on media-surface - it names the producer rendezvous of the media surface's texture channel; anywhere else it would be silently inert";
pub const media_surface_missing_surface_message = "media-surface requires surface={binding} naming the u64 surface id its producer targets - without one the surface can never show anything (dead markup, same policy as icon without name)";

/// The built-in vector icon vocabulary behind `<icon name="..."/>`.
/// Registry section mirroring `canvas.icons.known_icon_names` (the
/// comptime-parsed registry; this layer stays std-only); a test in
/// ui_markup_view_tests.zig keeps the two in lockstep so a new icon
/// cannot ship without its markup name.
pub const known_icon_names = schema.icon_names;

pub const icon_name_message = "name takes a built-in icon name (see canvas.icons.known_icon_names, e.g. search, plus, x, check, chevron-down, settings, trash), an app-registered app:<name> (canvas.icons.registerAppIcons), or one {binding} resolving to such a name";
pub const icon_name_element_message = "name is only supported on icon - it selects a built-in vector icon";
pub const icon_missing_name_message = "icon requires a name attribute selecting a built-in vector icon (e.g. <icon name=\"search\"/>)";
pub const icon_children_message = "icon is a leaf - it takes no children";

pub const button_icon_message = "icon takes a built-in icon name drawn inside the element (see canvas.icons.known_icon_names, e.g. save, plus, refresh-cw), an app-registered app:<name> (canvas.icons.registerAppIcons), or one {binding} resolving to such a name";
pub const button_icon_element_message = "icon is only supported on button, toggle-button, list-item, menu-item, and badge - it draws a vector icon inside the element as one hit target; for a bare icon use <icon name=\"...\"/>";

/// The `app:` icon namespace: the markup channel into the app's OWN
/// registered vector icons (`canvas.icons.registerAppIcons`). Bare names
/// stay the closed built-in vocabulary the engines prove at build time;
/// `app:` names are structurally accepted here (registration is a
/// boot-time act no static pass can see) and verified against the
/// registered set by `native check` through the model contract's
/// `app_icons` list.
pub const app_icon_prefix = "app:";

pub const app_icon_shape_message = "app: takes a registered icon name after the colon, spelled like a built-in (lowercase words joined by dashes, e.g. app:wave-pulse) - the name is the one the app passed to canvas.icons.registerAppIcons";
pub const icon_namespace_message = "unknown icon namespace - app: is the only one (app:<name> draws an icon the app registered with canvas.icons.registerAppIcons); built-in names are bare (see canvas.icons.known_icon_names)";

/// One icon-valued attribute, structurally classified. Shared by the
/// validator and BOTH engines (comptime-callable) so the accepted forms
/// can never drift: a bare literal must be a built-in, an `app:` literal
/// must be well-shaped (its registration is checked later, by `native
/// check` against the contract and by the draw path's missing-icon
/// fallback), and one `{binding}` defers the whole choice to model data.
pub const IconValue = union(enum) {
    /// A validated built-in name (`canvas.icons.known_icon_names`).
    builtin: []const u8,
    /// The full `app:<name>` spelling, shape-checked; carried verbatim so
    /// draw-time resolution and diagnostics name exactly what the markup
    /// said.
    app: []const u8,
    /// The raw attribute value of a `{binding}` (or richer expression)
    /// producing the icon name at view build time.
    binding: []const u8,
    /// The teaching message for a value in none of those forms.
    invalid: []const u8,
};

/// Classify an icon attribute value; `base_message` is the caller's
/// teaching message for its own attribute (name vs icon), used for the
/// generic failures (not a name at all, an unknown bare literal).
pub fn iconValueOf(raw: []const u8, base_message: []const u8) IconValue {
    const expression = parseAttrExpression(raw) orelse return .{ .invalid = base_message };
    switch (expression) {
        .literal => |literal| {
            if (std.mem.startsWith(u8, literal, app_icon_prefix)) {
                const bare = literal[app_icon_prefix.len..];
                if (!wellShapedIconName(bare)) return .{ .invalid = app_icon_shape_message };
                return .{ .app = literal };
            }
            if (std.mem.indexOfScalar(u8, literal, ':') != null) {
                return .{ .invalid = icon_namespace_message };
            }
            if (!nameInList(literal, &known_icon_names)) return .{ .invalid = base_message };
            return .{ .builtin = literal };
        },
        .binding => return .{ .binding = raw },
        // Icon choice is one name: a literal or one binding. Computed
        // names (concatenation, conditionals) belong in the model, where
        // the contract can type them.
        .equals, .expression => return .{ .invalid = base_message },
    }
}

/// The shape every icon name has (built-in and registered alike):
/// lowercase words of letters and digits joined by single dashes.
fn wellShapedIconName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '-' or name[name.len - 1] == '-') return false;
    var previous_dash = false;
    for (name) |char| {
        const word_char = (char >= 'a' and char <= 'z') or (char >= '0' and char <= '9');
        if (word_char) {
            previous_dash = false;
            continue;
        }
        if (char != '-' or previous_dash) return false;
        previous_dash = true;
    }
    return true;
}

/// Elements whose `icon` attribute draws an inline vector icon as part
/// of the element's OWN rendering (one hit target, one tint following
/// enabled/disabled state). Registry-derived from the `icon_attr` element
/// predicate; mirrors the engine kinds that consume `Widget.icon`:
/// buttons and toggle-buttons draw it before the label (tab strips are
/// toggle-button children, so tabs get icons through this), list items
/// and menu items draw it as a leading slot.
pub const known_icon_attr_element_names = schema.icon_attr_element_names;

pub fn iconAttrElement(name: []const u8) bool {
    return nameInList(name, &known_icon_attr_element_names);
}

pub fn anchorElement(name: []const u8) bool {
    return nameInList(name, &known_anchor_element_names);
}

/// Whether the engine hit-tests this element's widget kind — the surface
/// the hover/press wash ladder exists on, and so the scope of the
/// `quiet-hover` knob (registry `hit_target`; composites resolve through
/// their library views and are out of scope).
pub fn hitTargetElement(name: []const u8) bool {
    const entry = schema.elementByName(name) orelse return false;
    return entry.rule_hook == null and entry.hit_target;
}

pub fn dismissEventElement(name: []const u8) bool {
    return nameInList(name, &known_dismiss_element_names);
}

// ----------------------------------------------------------- a11y lint
//
// The accessible-name and role lint. Severity rubric (stated once, at the
// registry's `A11yNameRule`): a finding is an ERROR when a screen reader
// user is FULLY BLOCKED (an unnamed interactive control cannot be
// operated blind; a role that cannot mean what it says lies to the
// bridge), and a WARNING when the experience degrades but remains
// navigable (an unnamed image, a label duplicating the text it shadows).
// Which elements are controls/editables/images is registry data
// (`schema.ElementInfo.a11y_name`); the judgment about name sources and
// severities lives here. Both engines and the validator call the same
// predicates, so the lint cannot drift between check time and build time.

pub const a11y_unlabeled_control_message = "this control has no accessible name - a screen reader announces an unnamed control that cannot be operated blind; give it visible text (element content or text=\"...\") or label=\"...\" naming the action (assistive tech and automation snapshots read the label)";

pub const a11y_icon_only_message = "icon-only control: the icon name is a drawing instruction, not a label - a screen reader announces an unnamed control; add label=\"...\" naming the action (e.g. <button icon=\"trash\" label=\"Delete\"/>)";

pub const a11y_unlabeled_editable_message = "this text control has no accessible name - a screen reader user cannot tell what to type; add label=\"...\" (or placeholder=\"...\", which the accessibility bridges announce as the fallback name)";

pub const a11y_unknown_role_message = "unknown role: role takes a canvas.WidgetRole name (button, link, tree, treeitem, list, listitem, tab, checkbox, ...)";

pub const a11y_container_role_message = "this role promises child structure (rows, items, cells) that this element can never hold - put the role on the container element around it, or drop it";

pub const a11y_unlabeled_image_message = "this image has no alt-equivalent label - a screen reader announces an unnamed image; add label=\"...\" describing it, or the explicit label=\"\" to mark it decorative";

pub const a11y_redundant_label_message = "this label duplicates the element's text content - the text is already the accessible name; drop the label so the two can never drift apart";

/// The accessible-name ERROR for an element node, or null when the
/// element is named (or carries no name requirement). Name sources are
/// nonblank literals or `{bindings}` (a binding that resolves empty at
/// runtime is the tree-level audit's finding, not markup's). Shared by
/// the validator and both engines; comptime-callable.
pub fn a11yNameError(node: MarkupNode) ?[]const u8 {
    const entry = schema.elementByName(node.name) orelse return null;
    switch (entry.a11y_name) {
        .none, .image => return null,
        .control => {
            if (a11yNodeHasName(node)) return null;
            if (node.attr("icon") != null) return a11y_icon_only_message;
            return a11y_unlabeled_control_message;
        },
        .editable => {
            // On text-entry controls the `text` attribute is the live
            // VALUE, not a name (hearing the content does not say what
            // to type), so the name must be a label or a placeholder.
            // `select` is the one editable TEXT LEAF: its text channel
            // (content or `text=`) is the face it shows, so it counts.
            if (attrNonBlank(node, "label") or attrNonBlank(node, "placeholder")) return null;
            if (entry.takes_text and a11yNodeHasName(node)) return null;
            return a11y_unlabeled_editable_message;
        },
    }
}

/// The role-misuse ERROR for an element node: an unknown literal role, or
/// a container role on an element that provably cannot hold the children
/// the role promises. Dynamic role values (`role="{binding}"`) resolve at
/// runtime, where the engines still reject unknown names. Shared by the
/// validator and both engines; comptime-callable.
pub fn a11yRoleError(node: MarkupNode) ?[]const u8 {
    const entry = schema.elementByName(node.name) orelse return null;
    const value = node.attr("role") orelse return null;
    const expression = parseAttrExpression(value) orelse return null;
    if (expression != .literal) return null;
    const literal = expression.literal;
    if (!nameInList(literal, &schema.role_names)) return a11y_unknown_role_message;
    if (nameInList(literal, &schema.container_role_names) and !schema.elementHoldsChildren(entry)) {
        return a11y_container_role_message;
    }
    return null;
}

/// Whether the node carries element content (elements or structure tags,
/// as opposed to text runs) — the list-row composite discriminator.
/// Shared by the validator and both engines; comptime-callable.
/// A `context-menu` child is metadata, not content — it lowers onto the
/// PARENT's declared menu items and never renders in the parent's flow —
/// so it does not make an element "have children" here.
pub fn nodeHasElementContent(node: MarkupNode) bool {
    for (node.children) |child| {
        if (child.kind != .text and !nodeIsContextMenu(child)) return true;
    }
    return false;
}

/// A `<context-menu>` element child: consumed by its parent (lowered to
/// the parent's declared context-menu items), skipped by every content
/// rule and child build. Shared by the validator and both engines;
/// comptime-callable.
pub fn nodeIsContextMenu(node: MarkupNode) bool {
    return node.kind == .element and std.mem.eql(u8, node.name, "context-menu");
}

/// A `<span>` element child: consumed by its parent `<text>` (lowered
/// into the paragraph's flat span list, never built on its own). Shared
/// by the validator and both engines; comptime-callable.
pub fn nodeIsSpan(node: MarkupNode) bool {
    return node.kind == .element and std.mem.eql(u8, node.name, "span");
}

/// A `<reactions>` element child: consumed by its parent `<bubble>`
/// (its run lowers onto the bubble widget's chrome-text channel, never
/// built on its own). Shared by the validator and both engines;
/// comptime-callable.
pub fn nodeIsReactions(node: MarkupNode) bool {
    return node.kind == .element and std.mem.eql(u8, node.name, "reactions");
}

/// Whether a text element's content is a span paragraph (any inline
/// `<span>` child): the discriminator both engines use to pick the
/// paragraph lowering over the plain single-run path. Comptime-callable.
pub fn nodeHasSpanChildren(node: MarkupNode) bool {
    for (node.children) |child| {
        if (nodeIsSpan(child)) return true;
    }
    return false;
}

fn childrenIncludeSpan(children: []const MarkupNode) bool {
    for (children) |child| {
        if (nodeIsSpan(child)) return true;
    }
    return false;
}

/// Whether the source bytes between two adjacent inline children contain
/// whitespace (comments are transparent: their bytes never count), i.e.
/// whether the author separated the runs. Comptime-callable; both
/// parsers splice separators through this one predicate.
fn gapHasInlineSpace(source: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index < @min(end, source.len)) {
        if (std.mem.startsWith(u8, source[index..], "<!--")) {
            const close = std.mem.indexOfPos(u8, source, index + 4, "-->") orelse return false;
            index = close + 3;
            continue;
        }
        switch (source[index]) {
            ' ', '\t', '\r', '\n' => return true,
            else => index += 1,
        }
    }
    return false;
}

/// The single-space separator text node spliced between two inline
/// children whose source gap held whitespace. Its span covers the gap
/// (write-back anchors stay honest) and its position derives from the
/// gap's first byte, keeping the span↔position conformance law.
fn inlineSeparatorNode(source: []const u8, start: usize, end: usize) MarkupNode {
    const position = positionAt(source, start);
    return .{
        .kind = .text,
        .text = " ",
        .line = position.line,
        .column = position.column,
        .span = .{ .start = start, .end = end },
    };
}

/// Whether an element can HOST a context-menu: right-click resolution
/// walks the hit route, so the host must be a hit target — or carry a
/// bound on-press/on-hold, which makes any element pressable. Shared by
/// the validator and both engines; comptime-callable.
pub fn contextMenuHostEligible(node: MarkupNode) bool {
    if (!nameInList(node.name, &known_non_hit_target_element_names)) return true;
    return node.attr("on-press") != null or node.attr("on-hold") != null;
}

fn a11yNodeHasName(node: MarkupNode) bool {
    if (attrNonBlank(node, "label")) return true;
    if (attrNonBlank(node, "text")) return true;
    return nodeTextContentNonBlank(node);
}

fn nodeTextContentNonBlank(node: MarkupNode) bool {
    for (node.children) |child| {
        if (child.kind == .text and !allBlank(child.text)) return true;
    }
    return false;
}

fn attrNonBlank(node: MarkupNode, name: []const u8) bool {
    const value = node.attr(name) orelse return false;
    return !allBlank(value);
}

fn allBlank(text: []const u8) bool {
    for (text) |byte| {
        switch (byte) {
            ' ', '\t', '\r', '\n' => {},
            else => return false,
        }
    }
    return true;
}

/// Findings reported per warnings pass; a document with more distinct
/// a11y warnings than this is already unreviewable, so the collector
/// keeps the first ones and the count stays honest via the slice length.
pub const max_a11y_warnings = 64;

/// The a11y WARNINGS for a document (see the severity rubric above):
/// unnamed images and redundant labels. Callers that surface warnings
/// (`native markup check`, the LSP) run this after `validate` is green;
/// the engines stay silent about warnings because they have no channel
/// that is not a build failure.
pub fn collectA11yWarnings(document: MarkupDocument, storage: []MarkupErrorInfo) []const MarkupErrorInfo {
    var len: usize = 0;
    for (document.templates) |template_node| {
        collectNodeA11yWarnings(template_node, storage, &len);
    }
    if (document.root) |root| {
        collectNodeA11yWarnings(root, storage, &len);
    }
    return storage[0..len];
}

fn collectNodeA11yWarnings(node: MarkupNode, storage: []MarkupErrorInfo, len: *usize) void {
    if (node.kind == .element) {
        if (a11yImageWarning(node)) |message| {
            appendWarning(storage, len, errorAt(node, message));
        }
        if (a11yRedundantLabel(node)) |attribute| {
            appendWarning(storage, len, attrError(node, attribute, a11y_redundant_label_message));
        }
    }
    for (node.children) |child| {
        collectNodeA11yWarnings(child, storage, len);
    }
}

/// The a11y ERRORS for a document, all of them: the same findings
/// `validate` fails on one at a time (unnamed controls, icon-only
/// controls, unnamed text entry, and role misuse), collected per node so
/// a checker can report every offender in one pass instead of one per
/// re-run. Positions match `validate`'s emission exactly: the element
/// for name errors, the role attribute for role errors.
pub fn collectA11yErrors(document: MarkupDocument, storage: []MarkupErrorInfo) []const MarkupErrorInfo {
    var len: usize = 0;
    for (document.templates) |template_node| {
        collectNodeA11yErrors(template_node, storage, &len);
    }
    if (document.root) |root| {
        collectNodeA11yErrors(root, storage, &len);
    }
    return storage[0..len];
}

fn collectNodeA11yErrors(node: MarkupNode, storage: []MarkupErrorInfo, len: *usize) void {
    if (node.kind == .element) {
        if (a11yNameError(node)) |message| {
            appendWarning(storage, len, errorAt(node, message));
        }
        if (a11yRoleError(node)) |message| {
            appendWarning(storage, len, attrError(node, node.attrEntry("role").?, message));
        }
    }
    for (node.children) |child| {
        collectNodeA11yErrors(child, storage, len);
    }
}

fn appendWarning(storage: []MarkupErrorInfo, len: *usize, info: MarkupErrorInfo) void {
    if (len.* >= storage.len) return;
    storage[len.*] = info;
    len.* += 1;
}

fn a11yImageWarning(node: MarkupNode) ?[]const u8 {
    const entry = schema.elementByName(node.name) orelse return null;
    if (entry.a11y_name != .image) return null;
    // An explicit label attribute — even the empty decorative marker —
    // is a declaration; only its ABSENCE is the unnamed-image warning.
    if (node.attrEntry("label") != null) return null;
    if (a11yNodeHasName(node)) return null;
    return a11y_unlabeled_image_message;
}

/// The `label` attribute when its literal value duplicates the element's
/// literal name from content or `text` (dynamic values never compare).
fn a11yRedundantLabel(node: MarkupNode) ?MarkupAttr {
    const attribute = node.attrEntry("label") orelse return null;
    const label = trimBlank(attribute.value);
    if (label.len == 0) return null;
    if (std.mem.indexOfScalar(u8, label, '{') != null) return null;
    if (node.attr("text")) |text| {
        if (std.mem.eql(u8, label, trimBlank(text))) return attribute;
    }
    for (node.children) |child| {
        if (child.kind != .text) continue;
        if (std.mem.indexOfScalar(u8, child.text, '{') != null) continue;
        if (std.mem.eql(u8, label, trimBlank(child.text))) return attribute;
    }
    return null;
}

fn trimBlank(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
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
/// render: the tofu guard's shared predicate. `{...}` binding
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
/// timeline item's copy channels. Registry-derived from the
/// `rendered_text` attribute flag.
pub const known_text_attr_names = schema.rendered_text_attr_names;

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
    return .{ .line = line, .column = column, .message = font_coverage_message, .path = node.src_path };
}

fn attrCoverageError(node: MarkupNode, attribute: MarkupAttr) ?MarkupErrorInfo {
    if (!nameInList(attribute.name, &known_text_attr_names)) return null;
    const expression = parseAttrExpression(attribute.value) orelse return null;
    switch (expression) {
        .literal => |literal| {
            if (firstUncoveredCodepoint(literal) == null) return null;
            return attrError(node, attribute, font_coverage_message);
        },
        // Expression string literals are markup-authored text too: they
        // can land in a rendered label, so they ride the same guard.
        .expression => |inner| {
            if (!expressionStringCoverageError(inner)) return null;
            return attrError(node, attribute, font_coverage_message);
        },
        else => return null,
    }
}

/// Structural check of a text run's `{...}` interpolations: unterminated
/// braces, and every non-path segment through the expression grammar
/// (syntax, bounds, function names/arity, literal type discipline) plus
/// the tofu guard over expression string literals. Positions point at the
/// segment's opening brace.
fn textInterpolationError(node: MarkupNode) ?MarkupErrorInfo {
    var rest = node.text;
    var consumed: usize = 0;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse {
            return textErrorAtOffset(node, consumed + open, unterminated_interpolation_message);
        };
        const inner = std.mem.trim(u8, rest[open + 1 .. close], " ");
        if (!isBindingPath(inner)) {
            if (expressionTextError(inner)) |message| {
                return textErrorAtOffset(node, consumed + open, message);
            }
            if (expressionStringCoverageError(inner)) {
                return textErrorAtOffset(node, consumed + open, font_coverage_message);
            }
        }
        consumed += close + 1;
        rest = rest[close + 1 ..];
    }
    return null;
}

/// An error positioned at a byte offset within a text run (mirrors the
/// tofu guard's position walk).
fn textErrorAtOffset(node: MarkupNode, offset: usize, message: []const u8) MarkupErrorInfo {
    var line = node.line;
    var column = node.column;
    for (node.text[0..offset]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column, .message = message, .path = node.src_path };
}

/// Markup attributes that reference a color design token by name. Values
/// must be literal `ColorTokens` field names (`known_color_token_names`);
/// the builder resolves them against live tokens in `finalizeWithTokens`.
/// `border-color` (not bare `border`) keeps the name free for a future
/// border-width shorthand. Registry-derived from the style-color group.
pub const known_color_style_attrs = schema.color_style_attr_names;

/// The field names of `canvas.ColorTokens` (registry token section; kept
/// in sync by a test in ui_markup_view_tests.zig — this module stays
/// std-only).
pub const known_color_token_names = schema.color_token_names;

/// The field names of `canvas.RadiusTokens` (same sync test).
pub const known_radius_token_names = schema.radius_token_names;

pub const style_token_literal_message = "style token attributes take a literal token name - dynamic styling stays in Zig";
pub const unknown_color_token_message = "unknown color token: color style attributes take a canvas ColorTokens field name (background, surface, surface_subtle, surface_pressed, text, text_muted, border, accent, accent_text, destructive, destructive_text, success, success_text, warning, warning_text, info, info_text, focus_ring, shadow, scrim, disabled)";
pub const unknown_radius_token_message = "unknown radius token: radius takes a canvas RadiusTokens field name (sm, md, lg, xl)";

pub const for_children_message = "for takes one or more element children (elements, use, if/else, or a nested for) - text content is only allowed inside text-bearing elements";
pub const else_placement_message = "else must directly follow an if (renders when the test is false) or a for (renders when the iterable is empty)";

pub const invalid_expression_message = "invalid expression: values are a literal or one {expression} - a binding path, arithmetic, comparisons, and/or/not, ++ concatenation, and the built-in formatting functions (stateful logic stays a model function)";
pub const if_test_expression_message = "invalid expression: test takes one {expression} - a binding, a comparison, or boolean logic";
pub const unterminated_interpolation_message = "unterminated interpolation";
pub const arena_scalar_equality_message = "arena-computed bindings cannot be compared with == - compare the source fields directly, or bind a pub fn returning bool";
pub const binding_text_buffer_message = "this binding names a TextBuffer field - the buffer is the edit model, not the text; bind a pub fn returning its text (pub fn draft(model: *const Model) []const u8 { return model.draft_buffer.text(); })";
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
pub const chart_attr_message = "unknown attribute for chart - it takes y-min, y-max, grid-lines, baseline, x-labels, y-labels, hover-details, stroke-width, width, height, grow, padding, key, global-key, and label";
pub const chart_x_labels_message = "chart x-labels expects a {binding} naming a model iterable of strings (one category label per sample, oldest first)";
pub const chart_children_message = "chart takes only series children - one <series values=\"{binding}\"/> per plotted series; the series set is static (vary the DATA through bindings), and dynamic series composition stays with the Zig builder (ui.chart)";
pub const chart_series_required_message = "chart requires at least one series child (<series values=\"{history}\"/>)";
pub const chart_display_only_message = "chart is display-only - presses fall through it like text, so on-* handlers have no surface here; put on-press on a container around it";
pub const series_parent_message = "series is only allowed inside a chart";
pub const series_attr_message = "unknown attribute for series - it takes kind, values, color, and label";
pub const series_kind_message = "series kind takes a literal: line, area, or bar (area is a line filled to the baseline; band envelopes need a paired lower-edge slice per point and stay with the Zig builder, ui.chart)";
pub const series_values_message = "series requires a values attribute with one {binding} naming a []const f32 or []const f64 iterable (a model field, pub decl, or fn - the same sources for each accepts; transpiled TS number arrays are f64); pad the window's leading gap with NaN samples, which draw nothing";
pub const series_color_message = "series color takes a literal color token name (a canvas ColorTokens field, e.g. accent, info, success, text_muted)";
pub const series_label_message = "series label expects text (a literal or one {binding}) - it names the series in the chart's semantics summary";
pub const series_children_message = "series is a leaf - it takes no children; the values binding carries its data";
pub const context_menu_parent_message = "context-menu must be a DIRECT child of the element whose right-click it answers - a conditional menu goes inside: wrap the menu-items in if/else, not the context-menu itself";
pub const context_menu_host_message = "context-menu attaches to the element that takes the right-click, and this element is never a hit target - put the menu on the pressable element (list-item, button, panel, ...) or bind on-press on this one";
pub const context_menu_single_message = "an element takes at most one context-menu - one right-click, one menu; swap its items with if/else INSIDE the menu";
pub const context_menu_attrs_message = "context-menu takes no attributes - presentation belongs to the platform (the OS menu where the host has one, the anchored fallback surface elsewhere)";
pub const context_menu_children_message = "context-menu takes menu-item and separator children (if/else/for around them are fine) - the items present through the platform's menu, so other elements cannot render there";
pub const context_menu_empty_message = "context-menu requires at least one menu-item child";
pub const context_menu_item_press_message = "every menu-item in a context-menu needs on-press - selecting the item dispatches that Msg, and an item without one is dead";
pub const context_menu_item_attr_message = "unknown attribute for a context-menu menu-item - it takes on-press and disabled; the platform menu renders labels, separators, and enabled state only";
pub const context_menu_item_label_message = "a context-menu menu-item's content is its label - give it one run of text";
pub const context_menu_separator_message = "separator inside a context-menu is a bare divider - it takes no attributes or children";
pub const input_group_attr_message = "unknown attribute for input-group - it takes label, width, height, min-width, grow, key, and global-key";
pub const input_group_children_message = "input-group wraps exactly one textarea, then an optional input-group-actions row - other content lives outside the group";
pub const input_group_textarea_message = "input-group requires a textarea child (the text entry the group wraps) before any input-group-actions";
pub const input_group_actions_parent_message = "input-group-actions is only allowed inside an input-group, after its textarea";
pub const input_group_actions_attr_message = "unknown attribute for input-group-actions - it takes gap, key, and global-key";
pub const input_group_actions_children_message = "input-group-actions takes element children (buttons, spacers - if/else/for around them are fine) - text content is only allowed inside text-bearing elements";
pub const text_leaf_children_message = "this element takes text content only - wrap element children in a container (row, column, stack)";
pub const text_leaf_single_run_message = "text elements take a single run of text";
pub const text_inline_children_message = "text takes one run of text and inline span children only - wrap other elements in a container (row, column, stack)";
pub const span_parent_message = "span is only allowed inside text - it styles one run of the enclosing paragraph, so it needs a <text> parent";
pub const span_text_only_message = "span is only supported inside text - the other text-bearing elements draw one single-style label; put the styled runs in a <text> paragraph composed next to this element";
pub const span_attr_message = "unknown attribute for span - it takes weight (regular, medium, bold), mono, italic, scale, underline, and foreground; spans are visual runs, so events, keys, and layout stay on the enclosing text";
pub const span_weight_value_message = "unknown weight value - span takes regular, medium (the semibold rung), or bold";
pub const span_scale_value_message = "scale takes a positive number - the run draws at the paragraph's base size (the text element's size rung included) times this multiplier, so 1.5 reads half again as large; zero, negative, and non-finite multipliers have no rendering - drop the attribute to inherit the base size";
pub const span_content_message = "span takes a single run of text (a literal, {bindings}, or both) - spans do not nest and hold no element children (the paragraph lowers to one flat run list)";
pub const span_paragraph_wrap_message = "wrap and overflow do not apply to a span paragraph - inline spans always word-wrap and the paragraph reserves its wrapped height; drop the attribute (or the spans)";

/// The span `weight` attribute's closed value vocabulary: the member
/// names of `canvas.TextSpanWeight`, mirrored as data here (this layer
/// stays std-only) with a lockstep test in ui_markup_view_tests.zig
/// holding the mirror equal to the live enum. `medium` is the semibold
/// rung: the reserved medium sans face sits between regular and bold.
pub const span_weight_value_names = [_][]const u8{ "regular", "medium", "bold" };

pub const reactions_parent_message = "reactions is only allowed inside bubble - it is the enclosing chat bubble's reaction pill (docked on the bubble's bottom edge), so it needs a <bubble> parent";
pub const reactions_single_message = "a bubble takes at most one reactions child - it draws ONE pill; put every reaction in that pill's text run";
pub const reactions_attr_message = "unknown attribute for reactions - it takes text-alignment only (start, center, or end; end is the default trailing dock); the pill is bubble chrome, so events, keys, and layout stay on the enclosing bubble";
pub const reactions_alignment_value_message = "unknown text-alignment value for reactions - the pill docks at the bubble's start, center, or end (end is the default: the trailing dock reactions conventionally hang from); a literal name, so the dock is a static design choice";
pub const reactions_content_message = "reactions takes a single run of text (a literal, {bindings}, or both) - it draws ONE pill and holds no element children";
pub const bubble_text_attr_message = "text does nothing on bubble - the message is the bubble's children, and the reaction pill is declared with a <reactions> child (its run lands on the bubble's chrome-text channel); for an accessible name use label";

/// The reactions `text-alignment` vocabulary: where the pill docks along
/// the bubble's bottom edge. The names are the `canvas.TextAlign`
/// members on purpose — the pill is the bubble's chrome text, so its
/// dock rides the existing text-alignment attribute (code 19) instead
/// of minting a new one.
pub const reactions_alignment_value_names = [_][]const u8{ "start", "center", "end" };
pub const text_or_children_content_message = "this element takes either one run of text or element children - not both; move the text into a <text> child (and keep label= for the accessible name)";
pub const table_row_parent_message = "table-row is only allowed inside a table (structure tags in between are fine)";
pub const table_cell_parent_message = "table-cell is only allowed inside a table-row (structure tags in between are fine)";
pub const template_top_level_message = "template definitions are only allowed at the top of the file, before the view root";
pub const template_name_message = "template requires a name attribute";
pub const template_unique_name_message = "template names must be unique";
pub const template_args_message = "template args must be space-separated names, each optionally with a literal default (args=\"title cards trend=flat\")";
pub const template_default_literal_message = "template arg defaults are literals only - a default cannot see any scope ({bindings} are rejected); pass the value at the use site instead";
pub const template_default_quoted_message = "quotes are literal in template arg defaults - write args=\"name=fallback\" (bare name= declares an empty-string default)";
pub const template_attrs_message = "template takes only name and args attributes";
pub const template_one_child_message = "template takes exactly one element child (wrap siblings in a container)";
pub const template_one_slot_message = "a template body takes at most one <slot/> (one unnamed slot; named slots are not supported yet)";
pub const use_template_attr_message = "use requires a template attribute naming a template defined at the top of the file";
pub const use_undefined_template_message = "use references an undefined template (define <template name=\"...\"> before the view root, or import the file that defines it)";
pub const use_earlier_template_message = "use may only reference templates defined earlier in the file";
pub const use_missing_arg_message = "use is missing an argument the template declares in args (only args declared with a default, like trend=flat, may be omitted)";
pub const use_extra_arg_message = "use passes an argument the template does not declare in args";
pub const use_children_without_slot_message = "this template has no <slot/> - use-site children need an insertion point; add <slot/> to the template body or remove the children";
pub const slot_outside_template_message = "slot is only allowed inside a template body - it marks where use-site children are inserted";
pub const slot_in_use_children_message = "a slot cannot sit inside use-site children - slot forwarding is not supported; each template body declares its own slot";
pub const slot_attrs_message = "slot takes no attributes (one unnamed slot; named slots are not supported yet)";
pub const slot_children_message = "slot is a leaf - it takes no children; the use site provides the content";
pub const empty_document_message = "markup file is empty - define templates (a component file), a view root, or both";
pub const component_file_view_message = "this file defines templates only (a component file) - a view needs a root element after the templates; import this file from a view instead";
pub const import_top_level_message = "import is only allowed at the top of the file, before the template definitions and the view root";
pub const import_src_message = "import requires a src attribute naming a .native file, relative to this file (subdirectories allowed)";
pub const import_attrs_message = "import takes only a src attribute";
pub const import_children_message = "import is a leaf - it takes no children";
pub const import_src_extension_message = "import src must name a .native file";
pub const import_src_absolute_message = "import src must be a relative path (resolved against the importing file) - absolute paths are rejected so markup stays portable";
pub const import_src_separator_message = "import src uses forward slashes only";
pub const import_src_escape_message = "import src escapes the markup root (the root view file's directory) - keep component files under it";
pub const import_src_too_long_message = "import src is too long (over 200 bytes)";
pub const import_view_root_message = "imported files define templates only - this file has a view root element; move the view to its own file and import just the templates";
pub const import_depth_message = "imports nest too deeply (over 8 levels) - flatten the component hierarchy";
pub const import_count_message = "too many imported files (over 32)";
pub const import_unresolved_message = "this markup imports other files - resolve imports before building (the app runtime, native markup check, and CompiledMarkupImports all do; a bare MarkupView needs resolveImports first)";
pub const max_templates_message = "too many templates (over 256 in one document, imports included) - split the view or drop generated definitions";

/// Bound on templates per document (also enforced across the resolved
/// import closure), so a hostile file cannot drive the validator's
/// quadratic duplicate-name scan or comptime expansion checks unbounded.
pub const max_document_templates = 256;

/// Where a `<slot/>` node is legal at the current validation position.
/// Template bodies allow one; use-site children forbid it (no slot
/// forwarding); everywhere else it is outside any template.
const SlotRule = enum { forbidden, template_body, use_children };

/// Model-agnostic structural validation: unknown elements or attributes,
/// malformed expressions, misshapen structure tags, and template/use/slot
/// wiring. Binding paths and message tags are checked against the concrete
/// Model/Msg by the interpreter; this pass is what
/// `native markup check` runs. On a document with UNRESOLVED imports
/// (per-file checking) references to templates the imports may provide are
/// not flagged; the resolved (merged) document gets the strict pass.
pub fn validate(document: MarkupDocument) ?MarkupErrorInfo {
    for (document.imports) |import_node| {
        if (validateImport(import_node)) |info| return info;
    }
    for (document.templates, 0..) |template_node, index| {
        if (validateTemplate(document, template_node, index)) |info| return info;
    }
    const root = document.root orelse return null;
    return validateNode(document, root, null, document.templates.len, .forbidden);
}

/// Shape-only import checks; existence, cycles, and duplicates are the
/// resolver's job (it has the other files).
fn validateImport(node: MarkupNode) ?MarkupErrorInfo {
    if (node.children.len > 0) return errorAt(node.children[0], import_children_message);
    var has_src = false;
    for (node.attrs) |attribute| {
        if (!std.mem.eql(u8, attribute.name, "src")) {
            return attrError(node, attribute, import_attrs_message);
        }
        has_src = true;
        if (importSrcShapeError(attribute.value)) |message| {
            return attrError(node, attribute, message);
        }
    }
    if (!has_src) return errorAt(node, import_src_message);
    return null;
}

/// Path-shape rules a src must satisfy before resolution even starts.
/// Escapes past the markup root need the importing file's directory and
/// are checked during resolution.
pub fn importSrcShapeError(src: []const u8) ?[]const u8 {
    if (src.len == 0) return import_src_message;
    if (src.len > max_import_path_len) return import_src_too_long_message;
    if (src[0] == '/') return import_src_absolute_message;
    if (std.mem.indexOfScalar(u8, src, ':') != null) return import_src_absolute_message;
    if (std.mem.indexOfScalar(u8, src, '\\') != null) return import_src_separator_message;
    if (!hasMarkupExtension(src)) return import_src_extension_message;
    return null;
}

/// The Native markup file extension.
pub const markup_extension = ".native";

/// True for the one markup extension.
pub fn hasMarkupExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, markup_extension);
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
            while (args.next()) |token| {
                const arg = parseTemplateArg(token);
                if (!isBindingName(arg.name)) {
                    return attrError(node, attribute, template_args_message);
                }
                if (arg.default) |default| {
                    // Literals only: a default evaluates in no scope, so a
                    // binding (or equality) there could never resolve.
                    if (std.mem.indexOfScalar(u8, default, '{') != null) {
                        return attrError(node, attribute, template_default_literal_message);
                    }
                    // Quotes are not string delimiters here - the default
                    // is already text, so quote characters would render
                    // verbatim in the expanded template.
                    if (default.len > 0 and (default[0] == '\'' or default[0] == '"')) {
                        return attrError(node, attribute, template_default_quoted_message);
                    }
                }
            }
            continue;
        }
        return attrError(node, attribute, template_attrs_message);
    }
    if (node.children.len != 1 or node.children[0].kind != .element) {
        return errorAt(node, template_one_child_message);
    }
    if (templateSecondSlot(node.children[0])) |second| {
        return errorAt(second, template_one_slot_message);
    }
    // The body sees templates defined before this one, which also rules
    // out recursion. The body root has no known parent element, so
    // parent-scoped rules (table-row in table) are checked at use sites of
    // the surrounding markup, not here.
    return validateNode(document, node.children[0], null, index, .template_body);
}

/// The second `<slot/>` in a template body, if any: the one-slot rule's
/// witness, shared by the validator and both engines (comptime-callable).
pub fn templateSecondSlot(body: MarkupNode) ?MarkupNode {
    var count: usize = 0;
    return secondSlot(body, &count);
}

/// Slots inside use children are rejected by their own error instead.
fn secondSlot(node: MarkupNode, count: *usize) ?MarkupNode {
    if (node.kind == .slot_block) {
        count.* += 1;
        if (count.* > 1) return node;
        return null;
    }
    if (node.kind == .use_block) return null;
    for (node.children) |child| {
        if (secondSlot(child, count)) |found| return found;
    }
    return null;
}

fn validateUse(document: MarkupDocument, node: MarkupNode, template_limit: usize) ?MarkupErrorInfo {
    const name = node.attr("template") orelse return errorAt(node, use_template_attr_message);
    const index = document.templateIndex(name) orelse {
        // Unresolved imports may provide the template; the resolved pass
        // and the engines still catch a genuinely undefined name.
        if (document.imports.len > 0) return validateUseChildren(document, node, template_limit);
        return errorAt(node, use_undefined_template_message);
    };
    if (index >= template_limit) return errorAt(node, use_earlier_template_message);
    const template_node = document.templates[index];
    if (node.children.len != 0 and templateSlot(template_node) == null) {
        return errorAt(node.children[0], use_children_without_slot_message);
    }
    var args = templateArgs(template_node);
    while (args.next()) |token| {
        const arg = parseTemplateArg(token);
        if (node.attr(arg.name) == null and arg.default == null) {
            return errorAt(node, use_missing_arg_message);
        }
    }
    for (node.attrs) |attribute| {
        if (std.mem.eql(u8, attribute.name, "template")) continue;
        if (!templateDeclaresArg(template_node, attribute.name)) {
            return attrError(node, attribute, use_extra_arg_message);
        }
        if (attrExpressionError(attribute.value, invalid_expression_message)) |message| {
            return attrError(node, attribute, message);
        }
    }
    return validateUseChildren(document, node, template_limit);
}

/// Use-site children (slot content) build in the consumer's scope, so they
/// validate like the surrounding markup — except a literal `<slot/>` is
/// rejected (no forwarding), which `.use_children` teaches. The insertion
/// point's parent element is template-side and unknown here, so
/// parent-scoped rules (table-row in table) are not checked.
fn validateUseChildren(document: MarkupDocument, node: MarkupNode, template_limit: usize) ?MarkupErrorInfo {
    var previous_kind: ?MarkupNodeKind = null;
    for (node.children) |child| {
        if (child.kind == .else_block and previous_kind != .if_block and previous_kind != .for_block) {
            return errorAt(child, else_placement_message);
        }
        if (child.kind == .text) {
            return errorAt(child, "text content is only allowed inside text-bearing elements");
        }
        if (validateNode(document, child, null, template_limit, .use_children)) |info| return info;
        previous_kind = child.kind;
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
                return attrError(node, attribute, markdown_source_message);
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "on-link")) {
            const expression = parseMessageExpression(attribute.value);
            if (expression == null or expression.?.payload.len != 0) {
                return attrError(node, attribute, markdown_on_link_message);
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "on-details")) {
            const expression = parseMessageExpression(attribute.value);
            if (expression == null or expression.?.payload.len != 0) {
                return attrError(node, attribute, markdown_on_details_message);
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "details-expanded")) {
            const expression = parseAttrExpression(attribute.value);
            if (expression == null or expression.? != .binding) {
                return attrError(node, attribute, markdown_details_expanded_message);
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "issue-link-base")) {
            const expression = parseAttrExpression(attribute.value);
            if (expression == null or expression.? == .equals) {
                return attrError(node, attribute, markdown_issue_link_base_message);
            }
            continue;
        }
        return attrError(node, attribute, markdown_attr_message);
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
            if (attrExpressionError(attribute.value, stepper_active_message)) |message| {
                return attrError(node, attribute, message);
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "key") or std.mem.eql(u8, attribute.name, "global-key") or std.mem.eql(u8, attribute.name, "label")) {
            if (attrExpressionError(attribute.value, invalid_expression_message)) |message| {
                return attrError(node, attribute, message);
            }
            continue;
        }
        return attrError(node, attribute, stepper_attr_message);
    }
    if (!has_active) return errorAt(node, stepper_active_message);
    for (node.children) |child| {
        if (child.kind != .element or !std.mem.eql(u8, child.name, "step")) {
            return errorAt(child, stepper_children_message);
        }
        for (child.attrs) |attribute| {
            return attrError(child, attribute, step_attr_message);
        }
        var text_runs: usize = 0;
        for (child.children) |run| {
            if (run.kind != .text) return errorAt(run, text_leaf_children_message);
            text_runs += 1;
            if (text_runs > 1) return errorAt(run, text_leaf_single_run_message);
            if (textInterpolationError(run)) |info| return info;
            if (textNodeCoverageError(run)) |info| return info;
        }
    }
    return null;
}

/// `<timeline>` is a list container with a closed attribute set; its
/// children (timeline-item elements, plus structure tags) validate
/// through the ordinary pass so `for`/`if` work inside it.
fn validateTimeline(document: MarkupDocument, node: MarkupNode, template_limit: usize, slot_rule: SlotRule) ?MarkupErrorInfo {
    for (node.attrs) |attribute| {
        const known = std.mem.eql(u8, attribute.name, "gap") or
            std.mem.eql(u8, attribute.name, "grow") or
            std.mem.eql(u8, attribute.name, "key") or
            std.mem.eql(u8, attribute.name, "global-key") or
            std.mem.eql(u8, attribute.name, "label");
        if (!known) {
            return attrError(node, attribute, timeline_attr_message);
        }
        if (attrExpressionError(attribute.value, invalid_expression_message)) |message| {
            return attrError(node, attribute, message);
        }
    }
    var previous_kind: ?MarkupNodeKind = null;
    for (node.children) |child| {
        if (child.kind == .else_block and previous_kind != .if_block and previous_kind != .for_block) {
            return errorAt(child, else_placement_message);
        }
        if (validateNode(document, child, "timeline", template_limit, slot_rule)) |info| return info;
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
            if (attrExpressionError(attribute.value, timeline_item_title_message)) |message| {
                return attrError(node, attribute, message);
            }
            if (attrCoverageError(node, attribute)) |info| return info;
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "on-press")) {
            if (parseMessageExpression(attribute.value) == null) {
                return attrError(node, attribute, "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")");
            }
            continue;
        }
        if (std.mem.startsWith(u8, attribute.name, "on-")) {
            return attrError(node, attribute, timeline_item_press_only_message);
        }
        if (std.mem.eql(u8, attribute.name, "icon")) {
            // Vector icon indicator: the shared icon value grammar
            // (built-in literal, app:<name>, or one {binding}) — symbols
            // belong on the icon channel, not in text glyphs.
            switch (iconValueOf(attribute.value, button_icon_message)) {
                .invalid => |message| return attrError(node, attribute, message),
                else => {},
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
            return attrError(node, attribute, timeline_item_attr_message);
        }
        if (attrExpressionError(attribute.value, invalid_expression_message)) |message| {
            return attrError(node, attribute, message);
        }
        if (attrCoverageError(node, attribute)) |info| return info;
    }
    if (!has_title) return errorAt(node, timeline_item_title_message);
    return null;
}

/// The series kinds the markup `<chart>` accepts, in teaching order.
/// `area` is the markup spelling of a filled line (`ChartSeries.fill` on a
/// `.line` series — one blessed spelling, no separate fill flag); `band`
/// needs a paired lower-edge slice per point and stays with the Zig
/// builder (`ui.chart`). Shared by the validator and both engines.
pub const chart_series_kind_names = [_][]const u8{ "line", "area", "bar" };

/// `<chart>` is the data-visualization composite: a closed attribute set
/// mirroring `Ui.ChartOptions`, and only `<series>` children whose values
/// bind model iterables of f32. The series SET is static — data varies
/// through bindings — so structure tags inside a chart are a teaching
/// error naming the Zig builder as the home for dynamic composition.
/// One `<context-menu>` on its host element: attribute-less, holding
/// menu-item and separator children (structure tags around them are
/// transparent, so a menu can swap or repeat items). The host's
/// eligibility (hit target or bound press) is checked at the host, where
/// the parent node is in hand. Pub and comptime-callable: the validator
/// and BOTH engines run this one shape check, so the closed item
/// vocabulary is stated once.
pub fn contextMenuShapeError(node: MarkupNode) ?MarkupErrorInfo {
    for (node.attrs) |attribute| {
        return attrError(node, attribute, context_menu_attrs_message);
    }
    var item_count: usize = 0;
    if (validateContextMenuChildren(node, &item_count)) |info| return info;
    if (item_count == 0) return errorAt(node, context_menu_empty_message);
    return null;
}

/// The context-menu content walk, transparent through structure tags:
/// `for`/`if`/`else` keep their generic shape rules, and every element
/// they can ever produce is a menu-item or separator.
fn validateContextMenuChildren(node: MarkupNode, item_count: *usize) ?MarkupErrorInfo {
    var previous_kind: ?MarkupNodeKind = null;
    for (node.children) |child| {
        switch (child.kind) {
            .element => {
                if (std.mem.eql(u8, child.name, "menu-item")) {
                    item_count.* += 1;
                    if (validateContextMenuItem(child)) |info| return info;
                } else if (std.mem.eql(u8, child.name, "separator")) {
                    if (child.attrs.len > 0 or child.children.len > 0) {
                        return errorAt(child, context_menu_separator_message);
                    }
                    item_count.* += 1;
                } else {
                    return errorAt(child, context_menu_children_message);
                }
            },
            .for_block => {
                if (child.attr("each") == null) return errorAt(child, "for requires an each attribute");
                if (child.attr("as") == null) return errorAt(child, "for requires an as attribute");
                if (child.children.len == 0) return errorAt(child, for_children_message);
                // Repeated items count as content even though the model
                // may produce none at runtime (same optimism as the
                // engines' empty-menu handling).
                var repeated: usize = 0;
                if (validateContextMenuChildren(child, &repeated)) |info| return info;
                if (repeated == 0) return errorAt(child, context_menu_children_message);
                item_count.* += repeated;
            },
            .if_block => {
                const test_value = child.attr("test") orelse return errorAt(child, "if requires a test attribute");
                if (attrExpressionError(test_value, if_test_expression_message)) |message| {
                    return errorAt(child, message);
                }
                if (validateContextMenuChildren(child, item_count)) |info| return info;
            },
            .else_block => {
                if (previous_kind != .if_block and previous_kind != .for_block) {
                    return errorAt(child, else_placement_message);
                }
                if (validateContextMenuChildren(child, item_count)) |info| return info;
            },
            else => return errorAt(child, context_menu_children_message),
        }
        previous_kind = child.kind;
    }
    return null;
}

/// One `<menu-item>` inside a context-menu: a closed attribute set
/// (on-press and disabled — the platform item carries label, enabled
/// state, and separators only) around one run of label text.
fn validateContextMenuItem(node: MarkupNode) ?MarkupErrorInfo {
    var has_press = false;
    for (node.attrs) |attribute| {
        if (std.mem.eql(u8, attribute.name, "on-press")) {
            has_press = true;
            if (parseMessageExpression(attribute.value) == null) {
                return attrError(node, attribute, "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")");
            }
        } else if (std.mem.eql(u8, attribute.name, "disabled")) {
            if (attrExpressionError(attribute.value, invalid_expression_message)) |message| {
                return attrError(node, attribute, message);
            }
        } else {
            return attrError(node, attribute, context_menu_item_attr_message);
        }
    }
    if (!has_press) return errorAt(node, context_menu_item_press_message);
    var text_runs: usize = 0;
    for (node.children) |child| {
        if (child.kind != .text) return errorAt(child, context_menu_item_label_message);
        text_runs += 1;
        if (text_runs > 1) return errorAt(child, text_leaf_single_run_message);
        if (textInterpolationError(child)) |info| return info;
        if (textNodeCoverageError(child)) |info| return info;
    }
    if (text_runs == 0) return errorAt(node, context_menu_item_label_message);
    return null;
}

fn validateChart(node: MarkupNode) ?MarkupErrorInfo {
    for (node.attrs) |attribute| {
        if (std.mem.startsWith(u8, attribute.name, "on-")) {
            return attrError(node, attribute, chart_display_only_message);
        }
        if (std.mem.eql(u8, attribute.name, "x-labels")) {
            // Like series values: the data channel is a binding, never
            // a literal — labels vary with the model.
            const expression = parseAttrExpression(attribute.value);
            if (expression == null or expression.? != .binding) {
                return attrError(node, attribute, chart_x_labels_message);
            }
            continue;
        }
        const known = std.mem.eql(u8, attribute.name, "y-min") or
            std.mem.eql(u8, attribute.name, "y-max") or
            std.mem.eql(u8, attribute.name, "grid-lines") or
            std.mem.eql(u8, attribute.name, "baseline") or
            std.mem.eql(u8, attribute.name, "y-labels") or
            std.mem.eql(u8, attribute.name, "hover-details") or
            std.mem.eql(u8, attribute.name, "stroke-width") or
            std.mem.eql(u8, attribute.name, "width") or
            std.mem.eql(u8, attribute.name, "height") or
            std.mem.eql(u8, attribute.name, "grow") or
            std.mem.eql(u8, attribute.name, "padding") or
            std.mem.eql(u8, attribute.name, "key") or
            std.mem.eql(u8, attribute.name, "global-key") or
            std.mem.eql(u8, attribute.name, "label");
        if (!known) {
            return attrError(node, attribute, chart_attr_message);
        }
        if (attrExpressionError(attribute.value, invalid_expression_message)) |message| {
            return attrError(node, attribute, message);
        }
        if (attrCoverageError(node, attribute)) |info| return info;
    }
    var series_count: usize = 0;
    for (node.children) |child| {
        if (child.kind != .element or !std.mem.eql(u8, child.name, "series")) {
            return errorAt(child, chart_children_message);
        }
        if (validateSeries(child)) |info| return info;
        series_count += 1;
    }
    if (series_count == 0) return errorAt(node, chart_series_required_message);
    return null;
}

/// One `<series>` inside a chart: a leaf whose data is the `values`
/// binding. Kind and color are closed literal vocabularies (a typo can
/// never rot silently), label is ordinary text.
fn validateSeries(node: MarkupNode) ?MarkupErrorInfo {
    for (node.children) |child| {
        return errorAt(child, series_children_message);
    }
    var has_values = false;
    for (node.attrs) |attribute| {
        if (std.mem.eql(u8, attribute.name, "kind")) {
            const expression = parseAttrExpression(attribute.value);
            const literal = if (expression) |value|
                (if (value == .literal) value.literal else null)
            else
                null;
            if (literal == null or !nameInList(literal.?, &chart_series_kind_names)) {
                return attrError(node, attribute, series_kind_message);
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "values")) {
            has_values = true;
            const expression = parseAttrExpression(attribute.value);
            if (expression == null or expression.? != .binding) {
                return attrError(node, attribute, series_values_message);
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "color")) {
            const expression = parseAttrExpression(attribute.value);
            const literal = if (expression) |value|
                (if (value == .literal) value.literal else null)
            else
                null;
            if (literal == null or !nameInList(literal.?, &known_color_token_names)) {
                return attrError(node, attribute, series_color_message);
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "label")) {
            if (attrExpressionError(attribute.value, series_label_message)) |message| {
                return attrError(node, attribute, message);
            }
            continue;
        }
        return attrError(node, attribute, series_attr_message);
    }
    if (!has_values) return errorAt(node, series_values_message);
    return null;
}

/// `<input-group>` — the composer-grade grouped input: ONE bordered
/// field wrapping exactly one `<textarea>` (first, so document order is
/// focus order) plus an optional `<input-group-actions>` accessory row.
/// The group's own attribute set is closed and small — the text entry's
/// behavior (text, placeholder, on-input, autofocus, ...) belongs to the
/// textarea child, which validates through the ordinary pass.
fn validateInputGroup(document: MarkupDocument, node: MarkupNode, template_limit: usize, slot_rule: SlotRule) ?MarkupErrorInfo {
    for (node.attrs) |attribute| {
        const known = std.mem.eql(u8, attribute.name, "label") or
            std.mem.eql(u8, attribute.name, "width") or
            std.mem.eql(u8, attribute.name, "height") or
            std.mem.eql(u8, attribute.name, "min-width") or
            std.mem.eql(u8, attribute.name, "grow") or
            std.mem.eql(u8, attribute.name, "key") or
            std.mem.eql(u8, attribute.name, "global-key");
        if (!known) {
            return attrError(node, attribute, input_group_attr_message);
        }
        if (attrExpressionError(attribute.value, invalid_expression_message)) |message| {
            return attrError(node, attribute, message);
        }
        if (attrCoverageError(node, attribute)) |info| return info;
    }
    // The child shape is static: the textarea first, then at most one
    // actions row. Conditional/repeated content belongs INSIDE the
    // actions row (structure tags work there), never at the group level.
    var textarea_count: usize = 0;
    var actions_count: usize = 0;
    for (node.children) |child| {
        if (child.kind != .element) return errorAt(child, input_group_children_message);
        if (std.mem.eql(u8, child.name, "textarea")) {
            if (textarea_count > 0 or actions_count > 0) return errorAt(child, input_group_children_message);
            textarea_count += 1;
            if (validateNode(document, child, "input-group", template_limit, slot_rule)) |info| return info;
            continue;
        }
        if (std.mem.eql(u8, child.name, "input-group-actions")) {
            if (textarea_count == 0) return errorAt(child, input_group_textarea_message);
            if (actions_count > 0) return errorAt(child, input_group_children_message);
            actions_count += 1;
            if (validateInputGroupActions(document, child, template_limit, slot_rule)) |info| return info;
            continue;
        }
        return errorAt(child, input_group_children_message);
    }
    if (textarea_count == 0) return errorAt(node, input_group_textarea_message);
    return null;
}

/// `<input-group-actions>` — the accessory row pinned inside the group's
/// border, under the textarea: a closed attribute set around ordinary
/// row content (buttons, spacers; `for`/`if` work), validated through
/// the generic pass.
fn validateInputGroupActions(document: MarkupDocument, node: MarkupNode, template_limit: usize, slot_rule: SlotRule) ?MarkupErrorInfo {
    for (node.attrs) |attribute| {
        const known = std.mem.eql(u8, attribute.name, "gap") or
            std.mem.eql(u8, attribute.name, "key") or
            std.mem.eql(u8, attribute.name, "global-key");
        if (!known) {
            return attrError(node, attribute, input_group_actions_attr_message);
        }
        if (attrExpressionError(attribute.value, invalid_expression_message)) |message| {
            return attrError(node, attribute, message);
        }
    }
    var previous_kind: ?MarkupNodeKind = null;
    for (node.children) |child| {
        if (child.kind == .text) return errorAt(child, input_group_actions_children_message);
        if (child.kind == .else_block and previous_kind != .if_block and previous_kind != .for_block) {
            return errorAt(child, else_placement_message);
        }
        if (validateNode(document, child, "input-group-actions", template_limit, slot_rule)) |info| return info;
        previous_kind = child.kind;
    }
    return null;
}

/// One `<span>` inside a text paragraph: a closed attribute set (weight,
/// mono, italic, scale, underline, foreground — the span model's markup
/// channels) around exactly one run of text. Spans do not nest: the
/// engine's paragraph is a FLAT run list, so nesting would invent a
/// cascade the renderer does not have. Pub and comptime-callable: the
/// validator and BOTH engines run this one shape check, so the closed
/// vocabulary is stated once.
pub fn spanShapeError(node: MarkupNode) ?MarkupErrorInfo {
    for (node.attrs) |attribute| {
        if (std.mem.eql(u8, attribute.name, "weight")) {
            // Closed literal vocabulary; bindings resolve at build, where
            // the engines enforce the same set.
            if (parseAttrExpression(attribute.value)) |expression| {
                if (expression == .literal and !nameInList(expression.literal, &span_weight_value_names)) {
                    return attrError(node, attribute, span_weight_value_message);
                }
            }
            if (attrExpressionError(attribute.value, invalid_expression_message)) |message| {
                return attrError(node, attribute, message);
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "scale")) {
            // The engine only scales for positive finite multipliers
            // (anything else silently draws at the base size), so markup
            // requires exactly that instead of letting a dead value rot.
            // Literals are checked here; bindings resolve at build, where
            // the engines enforce the same bound.
            if (parseAttrExpression(attribute.value)) |expression| {
                if (expression == .literal) {
                    const multiplier = std.fmt.parseFloat(f32, expression.literal) catch {
                        return attrError(node, attribute, span_scale_value_message);
                    };
                    if (!std.math.isFinite(multiplier) or multiplier <= 0) {
                        return attrError(node, attribute, span_scale_value_message);
                    }
                }
            }
            if (attrExpressionError(attribute.value, invalid_expression_message)) |message| {
                return attrError(node, attribute, message);
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "mono") or std.mem.eql(u8, attribute.name, "italic") or std.mem.eql(u8, attribute.name, "underline")) {
            if (attrExpressionError(attribute.value, invalid_expression_message)) |message| {
                return attrError(node, attribute, message);
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "foreground")) {
            // The existing color token channel: a literal ColorTokens
            // field name, exactly like foreground anywhere else.
            if (!nameInList(attribute.value, &known_color_token_names)) {
                const message = if (parseAttrExpression(attribute.value)) |expression|
                    (if (expression == .literal) unknown_color_token_message else style_token_literal_message)
                else
                    style_token_literal_message;
                return attrError(node, attribute, message);
            }
            continue;
        }
        return attrError(node, attribute, span_attr_message);
    }
    var text_runs: usize = 0;
    for (node.children) |child| {
        if (child.kind != .text) return errorAt(child, span_content_message);
        text_runs += 1;
        if (text_runs > 1) return errorAt(child, text_leaf_single_run_message);
    }
    if (text_runs == 0) return errorAt(node, span_content_message);
    return null;
}

/// The validator's span pass: the shared shape check plus the source-text
/// guards (interpolation grammar and tofu) over the span's run.
fn validateSpan(node: MarkupNode) ?MarkupErrorInfo {
    if (spanShapeError(node)) |info| return info;
    for (node.children) |child| {
        if (textInterpolationError(child)) |info| return info;
        if (textNodeCoverageError(child)) |info| return info;
    }
    return null;
}

/// One `<reactions>` inside a bubble: a closed attribute set (only a
/// literal `text-alignment` naming the dock — the pill is a static
/// design choice, like anchor placement) around one run of pill text.
/// Pub and comptime-callable: the validator and BOTH engines run this
/// one shape check, so the pill's closed shape is stated once.
pub fn reactionsShapeError(node: MarkupNode) ?MarkupErrorInfo {
    for (node.attrs) |attribute| {
        if (std.mem.eql(u8, attribute.name, "text-alignment")) {
            if (!nameInList(attribute.value, &reactions_alignment_value_names)) {
                return attrError(node, attribute, reactions_alignment_value_message);
            }
            continue;
        }
        return attrError(node, attribute, reactions_attr_message);
    }
    var text_runs: usize = 0;
    for (node.children) |child| {
        if (child.kind != .text) return errorAt(child, reactions_content_message);
        text_runs += 1;
        if (text_runs > 1) return errorAt(child, text_leaf_single_run_message);
    }
    if (text_runs == 0) return errorAt(node, reactions_content_message);
    return null;
}

/// The validator's reactions pass (run at the HOST bubble, where the
/// parent node is in hand): the shared shape check plus the source-text
/// guards (interpolation grammar and tofu) over the pill's run — the
/// same pairing spans get.
fn validateReactions(node: MarkupNode) ?MarkupErrorInfo {
    if (reactionsShapeError(node)) |info| return info;
    for (node.children) |child| {
        if (textInterpolationError(child)) |info| return info;
        if (textNodeCoverageError(child)) |info| return info;
    }
    return null;
}

/// The rule hooks the composite registry entries name. A registry entry
/// whose hook this table does not implement is a compile error (below),
/// so attachment and implementation can never drift.
const rule_hook_names = [_][]const u8{ "markdown", "stepper", "step", "timeline", "timeline-item", "chart", "series", "context-menu", "input-group", "input-group-actions", "span", "reactions" };

comptime {
    for (schema.elements) |entry| {
        const hook = entry.rule_hook orelse continue;
        var known = false;
        for (rule_hook_names) |name| {
            if (std.mem.eql(u8, name, hook)) known = true;
        }
        if (!known) @compileError("registry rule hook has no validator: " ++ hook);
    }
}

/// Composite-element validation, dispatched by the registry's rule-hook
/// name. Vocabulary is data; judgment stays code: forcing these shapes
/// (markdown's closed attribute set, the stepper's step children, the
/// timeline's parent scoping) into declarative registry data would breed
/// a worse inner language than plain Zig.
fn validateRuleHook(hook: []const u8, document: MarkupDocument, node: MarkupNode, parent_element: ?[]const u8, template_limit: usize, slot_rule: SlotRule) ?MarkupErrorInfo {
    if (std.mem.eql(u8, hook, "markdown")) return validateMarkdown(node);
    if (std.mem.eql(u8, hook, "stepper")) return validateStepper(node);
    if (std.mem.eql(u8, hook, "step")) {
        // Steps inside a stepper are consumed by validateStepper; one
        // reaching the generic pass sits outside a stepper.
        return errorAt(node, step_parent_message);
    }
    if (std.mem.eql(u8, hook, "timeline")) return validateTimeline(document, node, template_limit, slot_rule);
    if (std.mem.eql(u8, hook, "timeline-item")) {
        if (parent_element) |parent_name| {
            if (!std.mem.eql(u8, parent_name, "timeline")) {
                return errorAt(node, timeline_item_parent_message);
            }
        }
        return validateTimelineItem(node);
    }
    if (std.mem.eql(u8, hook, "chart")) return validateChart(node);
    if (std.mem.eql(u8, hook, "series")) {
        // Series inside a chart are consumed by validateChart; one
        // reaching the generic pass sits outside a chart.
        return errorAt(node, series_parent_message);
    }
    if (std.mem.eql(u8, hook, "context-menu")) {
        // Direct context-menu element children are consumed by their
        // host element's validation; one reaching the generic pass sits
        // at the root or behind a structure tag.
        return errorAt(node, context_menu_parent_message);
    }
    if (std.mem.eql(u8, hook, "input-group")) return validateInputGroup(document, node, template_limit, slot_rule);
    if (std.mem.eql(u8, hook, "input-group-actions")) {
        // Actions rows inside an input-group are consumed by
        // validateInputGroup; one reaching the generic pass sits outside
        // an input-group.
        return errorAt(node, input_group_actions_parent_message);
    }
    if (std.mem.eql(u8, hook, "span")) {
        // Spans inside a text paragraph are consumed by the text leaf's
        // content pass; one reaching the generic pass sits outside a
        // text leaf.
        return errorAt(node, span_parent_message);
    }
    if (std.mem.eql(u8, hook, "reactions")) {
        // Reactions inside a bubble are consumed by the bubble's host
        // pass; one reaching the generic pass sits outside a bubble.
        return errorAt(node, reactions_parent_message);
    }
    // The comptime check above proves every registry hook lands in one of
    // the branches; a name reaching here is not a registry hook at all.
    unreachable;
}

/// `parent_element` is the name of the nearest enclosing element, looking
/// through structure tags (`for`/`if`/`else`), or null at the view root and
/// at a template body root.
fn validateNode(document: MarkupDocument, node: MarkupNode, parent_element: ?[]const u8, template_limit: usize, slot_rule: SlotRule) ?MarkupErrorInfo {
    switch (node.kind) {
        // Literal text content rides the tofu guard (a codepoint the
        // bundled face cannot render is a teaching error at its exact
        // position) and the interpolation check (every `{...}` segment
        // is a path or a valid expression).
        .text => {
            if (textInterpolationError(node)) |info| return info;
            return textNodeCoverageError(node);
        },
        .template_block => return errorAt(node, template_top_level_message),
        .import_block => return errorAt(node, import_top_level_message),
        .use_block => return validateUse(document, node, template_limit),
        .slot_block => {
            switch (slot_rule) {
                .forbidden => return errorAt(node, slot_outside_template_message),
                .use_children => return errorAt(node, slot_in_use_children_message),
                .template_body => {},
            }
            for (node.attrs) |attribute| {
                return attrError(node, attribute, slot_attrs_message);
            }
            if (node.children.len > 0) return errorAt(node.children[0], slot_children_message);
            return null;
        },
        .element => {
            // Composite elements: the registry states WHICH elements
            // carry bespoke rules (their rule-hook attachment is data);
            // the rules themselves stay code, dispatched by hook name.
            if (schema.elementByName(node.name)) |entry| {
                if (entry.rule_hook) |hook| {
                    return validateRuleHook(hook, document, node, parent_element, template_limit, slot_rule);
                }
            }
            if (!nameInList(node.name, &known_element_names)) {
                return errorAt(node, "unknown element");
            }
            // Direct context-menu children attach to THIS element (the
            // rule hook rejects any other placement), so the host's
            // eligibility — right-click resolution walks the hit route —
            // is checked here, where the host node is in hand.
            var context_menu_count: usize = 0;
            for (node.children) |child| {
                if (!nodeIsContextMenu(child)) continue;
                context_menu_count += 1;
                if (context_menu_count > 1) return errorAt(child, context_menu_single_message);
                if (!contextMenuHostEligible(node)) return errorAt(child, context_menu_host_message);
                if (contextMenuShapeError(child)) |info| return info;
            }
            // Direct reactions children attach to THIS element the same
            // way (the pill is bubble chrome, not content), so the
            // bubble-scoped checks run here, where the host node is in
            // hand. Off a bubble the placement error lands immediately
            // instead of waiting for the rule-hook pass.
            var reactions_count: usize = 0;
            for (node.children) |child| {
                if (!nodeIsReactions(child)) continue;
                reactions_count += 1;
                if (!std.mem.eql(u8, node.name, "bubble")) return errorAt(child, reactions_parent_message);
                if (reactions_count > 1) return errorAt(child, reactions_single_message);
                if (validateReactions(child)) |info| return info;
            }
            if (std.mem.eql(u8, node.name, "bubble")) {
                // The bubble's chrome-text channel belongs to the
                // reaction pill (declared with a <reactions> child); a
                // bare text attribute would silently do nothing, so it
                // is a teaching error (same policy as gap on stacking
                // containers).
                if (node.attrEntry("text")) |attribute| {
                    return attrError(node, attribute, bubble_text_attr_message);
                }
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
                // Elements that also take children (the list-row
                // composite) hold EITHER one text run OR element
                // children; mixing the two is a teaching error. Pure
                // text keeps the classic single-run rule — except the
                // text element itself, whose runs may interleave with
                // inline <span> children (the span paragraph).
                const is_text = std.mem.eql(u8, node.name, "text");
                const has_spans = is_text and nodeHasSpanChildren(node);
                const takes_children = nameInList(node.name, &known_text_or_children_element_names);
                const has_elements = takes_children and nodeHasElementContent(node);
                var text_runs: usize = 0;
                for (node.children) |child| {
                    if (child.kind != .text) {
                        // A context-menu child is metadata on the host,
                        // not content: it never renders in the flow, so
                        // the content-model rules look through it.
                        if (nodeIsContextMenu(child)) continue;
                        if (nodeIsSpan(child)) {
                            // Inline spans belong to the text paragraph;
                            // the other single-style labels cannot split
                            // their run. Text-or-children hosts
                            // (list-item) flow spans to the generic child
                            // walk, whose placement hook teaches the
                            // <text> home — the same path both engines
                            // take.
                            if (is_text) {
                                if (validateSpan(child)) |info| return info;
                                continue;
                            }
                            if (!takes_children) return errorAt(child, span_text_only_message);
                            continue;
                        }
                        if (is_text) return errorAt(child, text_inline_children_message);
                        if (!takes_children) return errorAt(child, text_leaf_children_message);
                        continue;
                    }
                    if (has_elements) return errorAt(child, text_or_children_content_message);
                    text_runs += 1;
                    if (text_runs > 1 and !has_spans) return errorAt(child, text_leaf_single_run_message);
                }
                if (has_spans) {
                    // A span paragraph always word-wraps (builder parity),
                    // so the single-line policies are dead data here —
                    // rejected instead of silently inert.
                    for (node.attrs) |attribute| {
                        if (std.mem.eql(u8, attribute.name, "wrap") or std.mem.eql(u8, attribute.name, "overflow")) {
                            return attrError(node, attribute, span_paragraph_wrap_message);
                        }
                    }
                }
            }
            if (std.mem.eql(u8, node.name, "icon")) {
                if (node.attr("name") == null) return errorAt(node, icon_missing_name_message);
                if (node.children.len > 0) return errorAt(node.children[0], icon_children_message);
            }
            if (std.mem.eql(u8, node.name, "media-surface")) {
                // A media surface without a producer rendezvous can never
                // show anything: statically dead markup, refused with a
                // teaching (the icon-without-name policy).
                if (node.attr("surface") == null) return errorAt(node, media_surface_missing_surface_message);
            }
            if (std.mem.eql(u8, node.name, "split")) {
                // Exactly two pane children, statically: the divider sits
                // between fixed panes, so conditional/repeated content
                // belongs inside a pane container.
                var pane_count: usize = 0;
                for (node.children) |child| {
                    if (nodeIsContextMenu(child)) continue;
                    switch (child.kind) {
                        .element, .use_block => pane_count += 1,
                        else => return errorAt(child, split_children_message),
                    }
                }
                if (pane_count != 2) return errorAt(node, split_children_message);
            }
            // The a11y lint's error half: unnamed interactive controls
            // and role misuse block a screen reader user outright, so
            // they are validation errors (the warning half rides
            // `collectA11yWarnings`). Mirrored by both engines.
            if (a11yNameError(node)) |message| return errorAt(node, message);
            if (a11yRoleError(node)) |message| {
                return attrError(node, node.attrEntry("role").?, message);
            }
            for (node.attrs) |attribute| {
                if (std.mem.startsWith(u8, attribute.name, "on-")) {
                    if (!nameInList(attribute.name[3..], &known_events)) {
                        return attrError(node, attribute, "unknown event attribute");
                    }
                    if (std.mem.eql(u8, attribute.name, "on-scroll")) {
                        // The runtime emits scroll offsets for scroll
                        // containers only; anywhere else the handler could
                        // never fire.
                        if (!std.mem.eql(u8, node.name, "scroll")) {
                            return attrError(node, attribute, on_scroll_element_message);
                        }
                    } else if (std.mem.eql(u8, attribute.name, "on-dismiss")) {
                        // Only dismissible surfaces are ever dismissed by
                        // the runtime; anywhere else the Msg could never
                        // fire.
                        if (!nameInList(node.name, &known_dismiss_element_names)) {
                            return attrError(node, attribute, on_dismiss_element_message);
                        }
                    } else if (std.mem.eql(u8, attribute.name, "on-reach-end")) {
                        // The approach-end signal (infinite-scroll fetch)
                        // is emitted for scroll containers only.
                        if (!std.mem.eql(u8, node.name, "scroll")) {
                            return attrError(node, attribute, on_reach_end_element_message);
                        }
                    } else if (std.mem.eql(u8, attribute.name, "on-resize")) {
                        // The runtime emits fraction changes for split
                        // dividers only; anywhere else the handler could
                        // never fire.
                        if (!std.mem.eql(u8, node.name, "split")) {
                            return attrError(node, attribute, on_resize_element_message);
                        }
                    } else if (nameInList(node.name, &known_non_hit_target_element_names) and deadHandlerOnNonHitTarget(attribute.name)) {
                        return attrError(node, attribute, non_hit_target_handler_message);
                    }
                    if (parseMessageExpression(attribute.value) == null) {
                        return attrError(node, attribute, "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")");
                    }
                    continue;
                }
                if (nameInList(attribute.name, &known_color_style_attrs)) {
                    if (!nameInList(attribute.value, &known_color_token_names)) {
                        const message = if (parseAttrExpression(attribute.value)) |expression|
                            (if (expression == .literal) unknown_color_token_message else style_token_literal_message)
                        else
                            style_token_literal_message;
                        return attrError(node, attribute, message);
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "radius")) {
                    if (!nameInList(attribute.value, &known_radius_token_names)) {
                        const message = if (parseAttrExpression(attribute.value)) |expression|
                            (if (expression == .literal) unknown_radius_token_message else style_token_literal_message)
                        else
                            style_token_literal_message;
                        return attrError(node, attribute, message);
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "name")) {
                    // Vector icon selector, icon-scoped: the shared icon
                    // value grammar — built-in literals never rot (a
                    // closed vocabulary), app:<name> and {binding} defer
                    // to the registered set and the model.
                    if (!std.mem.eql(u8, node.name, "icon")) {
                        return attrError(node, attribute, icon_name_element_message);
                    }
                    switch (iconValueOf(attribute.value, icon_name_message)) {
                        .invalid => |message| return attrError(node, attribute, message),
                        else => {},
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "autofocus")) {
                    // A focus request needs a focusable element; layout
                    // and decoration kinds can never take the keyboard.
                    if (nameInList(node.name, &known_non_hit_target_element_names)) {
                        return attrError(node, attribute, autofocus_element_message);
                    }
                    if (attrExpressionError(attribute.value, invalid_expression_message)) |message| {
                        return attrError(node, attribute, message);
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "icon")) {
                    // Inline vector icon, scoped to the labeled
                    // interactive elements that render it themselves
                    // (`known_icon_attr_element_names`): the same icon
                    // value grammar as <icon name>, drawn inside the
                    // element so icon + label are one hit target with one
                    // tint.
                    if (!iconAttrElement(node.name)) {
                        return attrError(node, attribute, button_icon_element_message);
                    }
                    switch (iconValueOf(attribute.value, button_icon_message)) {
                        .invalid => |message| return attrError(node, attribute, message),
                        else => {},
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "image")) {
                    // Runtime image binding, avatar-scoped: ids are model
                    // data the app registered, never markup literals.
                    if (!std.mem.eql(u8, node.name, "avatar")) {
                        return attrError(node, attribute, avatar_image_element_message);
                    }
                    const expression = parseAttrExpression(attribute.value);
                    if (expression == null or expression.? != .binding) {
                        return attrError(node, attribute, avatar_image_message);
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "surface")) {
                    // The media-surface producer rendezvous, media-surface
                    // scoped: surface ids are model data a producer
                    // targets, never markup literals (the runtime-image-id
                    // grammar exactly).
                    if (!std.mem.eql(u8, node.name, "media-surface")) {
                        return attrError(node, attribute, media_surface_surface_element_message);
                    }
                    const expression = parseAttrExpression(attribute.value);
                    if (expression == null or expression.? != .binding) {
                        return attrError(node, attribute, media_surface_surface_message);
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "anchor")) {
                    // Anchored floating placement, dropdown-menu-scoped:
                    // a literal side so the compiled engine resolves it
                    // at comptime (flip is automatic either way).
                    if (!nameInList(node.name, &known_anchor_element_names)) {
                        return attrError(node, attribute, anchor_element_message);
                    }
                    if (!std.mem.eql(u8, attribute.value, "below") and !std.mem.eql(u8, attribute.value, "above")) {
                        return attrError(node, attribute, anchor_value_message);
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "anchor-alignment")) {
                    if (!nameInList(node.name, &known_anchor_element_names)) {
                        return attrError(node, attribute, anchor_element_message);
                    }
                    if (node.attr("anchor") == null) {
                        return attrError(node, attribute, anchor_dependent_attr_message);
                    }
                    if (!std.mem.eql(u8, attribute.value, "start") and !std.mem.eql(u8, attribute.value, "end") and !std.mem.eql(u8, attribute.value, "stretch")) {
                        return attrError(node, attribute, anchor_alignment_value_message);
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "anchor-offset")) {
                    if (!nameInList(node.name, &known_anchor_element_names)) {
                        return attrError(node, attribute, anchor_element_message);
                    }
                    if (node.attr("anchor") == null) {
                        return attrError(node, attribute, anchor_dependent_attr_message);
                    }
                    _ = std.fmt.parseFloat(f32, attribute.value) catch {
                        return attrError(node, attribute, anchor_offset_value_message);
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "gap") and nameInList(node.name, &known_stack_container_element_names)) {
                    return attrError(node, attribute, stack_container_gap_message);
                }
                if (std.mem.eql(u8, attribute.name, "columns") and !std.mem.eql(u8, node.name, "grid")) {
                    // Only the grid layout reads a column count; anywhere
                    // else it would silently do nothing (same policy as
                    // gap on stacking containers).
                    return attrError(node, attribute, grid_columns_element_message);
                }
                if (std.mem.eql(u8, attribute.name, "wrap") and !std.mem.eql(u8, node.name, "text")) {
                    // Only plain text leaves word-wrap; on a container the
                    // option is silently inert and has shipped with
                    // comments asserting wrapping that never happened
                    // (same policy as gap on stacking containers).
                    return attrError(node, attribute, wrap_element_message);
                }
                if (std.mem.eql(u8, attribute.name, "overflow")) {
                    // Overflow policy exists only where a single line can
                    // overflow: a plain text leaf. Anywhere else the
                    // option is silently inert (same policy as wrap).
                    if (!std.mem.eql(u8, node.name, "text")) {
                        return attrError(node, attribute, overflow_element_message);
                    }
                    // The closed value vocabulary, checked on literals
                    // here so the teaching error lands at validation
                    // (bindings resolve at build, where the engines
                    // enforce the same set).
                    if (parseAttrExpression(attribute.value)) |expression| {
                        if (expression == .literal and !nameInList(expression.literal, &overflow_value_names)) {
                            return attrError(node, attribute, overflow_value_message);
                        }
                    }
                }
                if (std.mem.eql(u8, attribute.name, "overscroll")) {
                    // Edge behavior exists only where the runtime scrolls:
                    // anywhere but a scroll container the option is
                    // silently inert (same policy as columns off grid).
                    if (!std.mem.eql(u8, node.name, "scroll")) {
                        return attrError(node, attribute, overscroll_element_message);
                    }
                    // The closed value vocabulary, checked on literals
                    // here so the teaching error lands at validation
                    // (bindings resolve at build, where the engines
                    // enforce the same set).
                    if (parseAttrExpression(attribute.value)) |expression| {
                        if (expression == .literal and !nameInList(expression.literal, &overscroll_value_names)) {
                            return attrError(node, attribute, overscroll_value_message);
                        }
                    }
                }
                if (std.mem.eql(u8, attribute.name, "quiet-hover")) {
                    // The hover wash exists only on hit-tested elements:
                    // anywhere else the knob is silently inert (same
                    // policy as overscroll off scroll).
                    if (!hitTargetElement(node.name)) {
                        return attrError(node, attribute, quiet_hover_element_message);
                    }
                }
                if (std.mem.eql(u8, attribute.name, "resize-duration")) {
                    // The layout tween exists only where a fraction can
                    // move: anywhere but a split the option is silently
                    // inert (same policy as overscroll off scroll).
                    if (!std.mem.eql(u8, node.name, "split")) {
                        return attrError(node, attribute, resize_duration_element_message);
                    }
                }
                if (std.mem.eql(u8, attribute.name, "resize-easing")) {
                    if (!std.mem.eql(u8, node.name, "split")) {
                        return attrError(node, attribute, resize_easing_element_message);
                    }
                    // Easing shapes a ramp that exists only while a
                    // nonzero duration declares one: easing alone (or
                    // beside a literal 0 duration) is silently inert, so
                    // it is a teaching error (same policy as
                    // anchor-alignment without anchor). A binding-valued
                    // duration resolves at build and stays legal here.
                    const duration_raw = node.attr("resize-duration") orelse {
                        return attrError(node, attribute, resize_easing_dependent_attr_message);
                    };
                    if (parseAttrExpression(duration_raw)) |duration_expression| {
                        if (duration_expression == .literal) {
                            const duration = std.fmt.parseInt(u32, duration_expression.literal, 10) catch 1;
                            if (duration == 0) {
                                return attrError(node, attribute, resize_easing_dependent_attr_message);
                            }
                        }
                    }
                    // The closed value vocabulary, checked on literals
                    // here so the teaching error lands at validation
                    // (bindings resolve at build, where the engines
                    // enforce the same set).
                    if (parseAttrExpression(attribute.value)) |expression| {
                        if (expression == .literal and !nameInList(expression.literal, &resize_easing_value_names)) {
                            return attrError(node, attribute, resize_easing_value_message);
                        }
                    }
                }
                if (std.mem.eql(u8, attribute.name, "resize-origin")) {
                    if (!std.mem.eql(u8, node.name, "split")) {
                        return attrError(node, attribute, resize_origin_element_message);
                    }
                    // An origin shapes an enter slide that exists only
                    // while a nonzero duration declares one: origin
                    // alone (or beside a literal 0 duration) is
                    // silently inert, so it is a teaching error — the
                    // resize-easing dependency policy exactly.
                    const duration_raw = node.attr("resize-duration") orelse {
                        return attrError(node, attribute, resize_origin_dependent_attr_message);
                    };
                    if (parseAttrExpression(duration_raw)) |duration_expression| {
                        if (duration_expression == .literal) {
                            const duration = std.fmt.parseInt(u32, duration_expression.literal, 10) catch 1;
                            if (duration == 0) {
                                return attrError(node, attribute, resize_origin_dependent_attr_message);
                            }
                        }
                    }
                }
                if (std.mem.eql(u8, attribute.name, "tooltip-delay")) {
                    // Hover intent exists only where the runtime owns
                    // visibility: anywhere but a tooltip the delay is
                    // silently inert (same policy as resize-duration
                    // off split).
                    if (!std.mem.eql(u8, node.name, "tooltip")) {
                        return attrError(node, attribute, tooltip_delay_element_message);
                    }
                    // The delay shapes a hover-show that exists only on
                    // an ANCHORED tooltip: a static tooltip paints
                    // whenever the view renders it, so a delay beside
                    // no anchor is silently inert — a teaching error
                    // (the anchor-alignment-without-anchor policy).
                    if (node.attr("anchor") == null) {
                        return attrError(node, attribute, tooltip_delay_dependent_attr_message);
                    }
                }
                if (std.mem.eql(u8, attribute.name, "size")) {
                    // The size register's closed literal vocabulary
                    // (bindings resolve at build): the control scale
                    // everywhere, plus the typography rungs on text only
                    // - two axes one attribute names, kept apart with a
                    // teaching error instead of a silently inert option.
                    // Numeric literals are refused on purpose: type
                    // sizes are themable token steps, never per-element
                    // numbers.
                    if (parseAttrExpression(attribute.value)) |expression| {
                        if (expression == .literal) {
                            if (nameInList(expression.literal, &known_text_size_value_names)) {
                                if (!std.mem.eql(u8, node.name, "text")) {
                                    return attrError(node, attribute, text_size_element_message);
                                }
                            } else if (!nameInList(expression.literal, &known_control_size_value_names)) {
                                return attrError(node, attribute, size_value_message);
                            }
                        }
                    }
                }
                if (!nameInList(attribute.name, &known_option_attrs)) {
                    return attrError(node, attribute, "unknown attribute");
                }
                if (attrExpressionError(attribute.value, invalid_expression_message)) |message| {
                    return attrError(node, attribute, message);
                }
                if (attrCoverageError(node, attribute)) |info| return info;
            }
        },
        .for_block => {
            if (parent_element == null) return errorAt(node, "for is only allowed inside an element");
            if (node.attr("each") == null) return errorAt(node, "for requires an each attribute");
            if (node.attr("as") == null) return errorAt(node, "for requires an as attribute");
            if (node.children.len == 0) return errorAt(node, for_children_message);
            for (node.children) |child| {
                switch (child.kind) {
                    .element, .use_block, .for_block, .if_block, .else_block, .slot_block => {},
                    else => return errorAt(child, for_children_message),
                }
            }
        },
        .if_block => {
            if (parent_element == null) return errorAt(node, "if is only allowed inside an element");
            const test_value = node.attr("test") orelse return errorAt(node, "if requires a test attribute");
            if (attrExpressionError(test_value, if_test_expression_message)) |message| {
                return errorAt(node, message);
            }
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
        // A direct context-menu child was already validated by its host
        // element above; recursing would fire the placement hook. Span
        // children of a text paragraph were consumed by the text leaf's
        // content pass the same way.
        if (node.kind == .element and nodeIsContextMenu(child)) {
            previous_kind = child.kind;
            continue;
        }
        if (node.kind == .element and std.mem.eql(u8, node.name, "text") and nodeIsSpan(child)) {
            previous_kind = child.kind;
            continue;
        }
        // Reactions children of a bubble were consumed by the bubble's
        // host pass the same way.
        if (node.kind == .element and std.mem.eql(u8, node.name, "bubble") and nodeIsReactions(child)) {
            previous_kind = child.kind;
            continue;
        }
        if (validateNode(document, child, child_parent, template_limit, slot_rule)) |info| {
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

/// Membership in a name-list vocabulary (comptime-callable; both engines
/// reuse it for the shared closed vocabularies).
pub fn nameInList(name: []const u8, list: []const []const u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn errorAt(node: MarkupNode, message: []const u8) MarkupErrorInfo {
    return .{ .line = node.line, .column = node.column, .message = message, .path = node.src_path };
}

/// An error positioned at an attribute; the enclosing node carries the
/// source path (attributes do not).
fn attrError(node: MarkupNode, attribute: MarkupAttr, message: []const u8) MarkupErrorInfo {
    return .{ .line = attribute.line, .column = attribute.column, .message = message, .path = node.src_path };
}

// ---------------------------------------------------------------- imports
//
// THE RESOLVER SEAM. An import maps a root-relative path to markup source
// text; everything else — grammar, ordering, cycles, duplicates, merging —
// lives here once, and each engine supplies only the mapping:
//
//   - compiled engine (`canvas.CompiledMarkupImports`): a comptime source
//     set the app assembles with `@embedFile` -> `resolveImportsComptime`.
//   - runtime interpreter (ui_app): the same embedded set for the first
//     build of a markup-only app, and the file system rooted at the
//     watched file's directory for hot reload -> `resolveImports` with the
//     matching `ImportLoader`.
//   - `native markup check`: the file system rooted at the checked file's
//     directory -> `resolveImports`.
//
// Resolution splices imported templates BEFORE the importing file's own,
// depth-first in import order (a file's transitive imports land before its
// own templates) — exactly as if each imported file were pasted at its
// import site. The merged document is a plain single-file document
// (`imports` empty), so the engines' template machinery — define-before-use
// ordering, expansion, structural ids — is untouched: widget ids hash as
// if every template were defined locally, and the two engines stay in
// parity by construction. Every node is stamped with its source path so
// diagnostics name the right file.

/// One markup file in an embedded source set: `path` is relative to the
/// markup root (the root view file's directory), forward slashes.
pub const SourceFile = struct {
    path: []const u8,
    source: []const u8,
};

/// Registration handle for the runtime's fragment hot-reload watch: a
/// hybrid app (Zig builder root embedding compiled markup fragments)
/// hands the runtime one of these per fragment — obtained from the
/// compiled type's `fragment(path)` — so editing that fragment's
/// `.native` source in a dev run reloads it in place. Debug-shaped on
/// purpose: outside Debug the struct is empty and `fragment(path)`
/// returns nothing, so release binaries carry no source paths, no
/// embedded-baseline references, and no watch plumbing.
pub const MarkupFragment = if (builtin.mode == .Debug) struct {
    /// Identity of the compiled fragment type (the address of its
    /// comptime document), matched by the engine's build-time override
    /// lookup — registration and lookup derive it from the same type,
    /// so they cannot disagree. A pointer, not an integer, so a
    /// registration list can live in a file-scope const (global
    /// addresses are comptime-representable; their integer values are
    /// not).
    key: ?*const anyopaque = null,
    /// On-disk source file to watch, relative to the process cwd (the
    /// dev flow runs apps from the app root). Imports resolve against
    /// this file's directory, exactly like the single-root watch.
    path: []const u8 = "",
    /// The embedded root source the fragment was compiled from — the
    /// baseline the watched file is compared against, so an unchanged
    /// disk file never triggers a phantom reload.
    source: []const u8 = "",
    /// The embedded import closure (`CompiledMarkupImports` source set);
    /// empty for single-file fragments.
    sources: []const SourceFile = &.{},
} else struct {};

/// Runtime source access for `resolveImports`: returns the source for a
/// root-relative path, or null when it cannot be read (the resolver turns
/// that into a teaching error at the import site).
pub const ImportLoader = struct {
    context: *const anyopaque,
    load: *const fn (context: *const anyopaque, arena: std.mem.Allocator, path: []const u8) ?[]const u8,
};

/// Loader over an embedded source set (the runtime mirror of the compiled
/// engine's comptime lookup). Keep the struct alive for the duration of
/// the resolve call; `loader()` captures a pointer to it.
pub const SourceSetLoader = struct {
    set: []const SourceFile,

    pub fn loader(self: *const SourceSetLoader) ImportLoader {
        return .{ .context = @ptrCast(self), .load = load };
    }

    fn load(context: *const anyopaque, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
        _ = arena;
        const self: *const SourceSetLoader = @ptrCast(@alignCast(context));
        for (self.set) |file| {
            if (std.mem.eql(u8, file.path, path)) return file.source;
        }
        return null;
    }
};

pub const max_import_path_len = 200;
pub const max_import_path_segments = 24;
pub const max_import_depth = 8;
pub const max_imported_files = 32;

pub const ResolveError = error{ MarkupSyntax, MarkupImport, OutOfMemory };

/// Resolve a root document's import closure into one merged document.
/// `root_name` names the root file for diagnostics AND anchors relative
/// resolution: imports resolve against the importing file's directory, and
/// nothing may escape `dirname(root_name)` (the markup root). Failures set
/// `diagnostic` — position, message, and the source path of the file the
/// position refers to.
pub fn resolveImports(
    arena: std.mem.Allocator,
    root_name: []const u8,
    root_source: []const u8,
    loader: ImportLoader,
    diagnostic: *MarkupErrorInfo,
) ResolveError!MarkupDocument {
    var resolver = ImportResolver{
        .arena = arena,
        .root_dir = dirnamePath(root_name),
        .loader = loader,
        .diagnostic = diagnostic,
    };
    const root = try resolver.visit(root_name, root_source, 0);
    return .{ .imports = &.{}, .templates = resolver.templates.items, .root = root };
}

const ImportResolver = struct {
    arena: std.mem.Allocator,
    root_dir: []const u8,
    loader: ImportLoader,
    diagnostic: *MarkupErrorInfo,
    templates: std.ArrayListUnmanaged(MarkupNode) = .empty,
    /// Fully resolved files (dedupe: two files importing the same
    /// component resolve it once, so its templates splice once).
    visited: std.ArrayListUnmanaged([]const u8) = .empty,
    /// The in-progress import chain, for cycle reporting.
    chain: [max_import_depth][]const u8 = undefined,
    file_count: usize = 0,

    /// Parse one file, resolve its imports depth-first, splice its
    /// templates, and return its stamped view root (null for a component
    /// file). Only the root file (depth 0) may have a view root.
    fn visit(self: *ImportResolver, path: []const u8, source: []const u8, depth: usize) ResolveError!?MarkupNode {
        self.chain[depth] = path;
        var parser = Parser.init(self.arena, source);
        const document = parser.parse() catch |err| {
            if (err == error.MarkupSyntax) {
                self.diagnostic.* = parser.diagnostic;
                self.diagnostic.path = path;
            }
            return err;
        };
        for (document.imports) |import_node| {
            if (validateImport(import_node)) |info| {
                self.diagnostic.* = info;
                self.diagnostic.path = path;
                return error.MarkupImport;
            }
            const src = import_node.attr("src").?;
            var buffer: [max_import_path_len]u8 = undefined;
            const resolved = switch (resolveImportPath(self.root_dir, path, src, &buffer)) {
                .path => |normalized| try self.arena.dupe(u8, normalized),
                .message => |message| return self.fail(path, import_node, message),
            };
            var cycle_start: ?usize = null;
            for (self.chain[0 .. depth + 1], 0..) |ancestor, index| {
                if (std.mem.eql(u8, ancestor, resolved)) cycle_start = index;
            }
            if (cycle_start) |start| {
                return self.fail(path, import_node, try self.cycleMessage(start, depth, resolved));
            }
            if (self.wasVisited(resolved)) continue;
            if (depth + 1 >= max_import_depth) return self.fail(path, import_node, import_depth_message);
            self.file_count += 1;
            if (self.file_count > max_imported_files) return self.fail(path, import_node, import_count_message);
            const child_source = self.loader.load(self.loader.context, self.arena, resolved) orelse {
                const message = try std.fmt.allocPrint(self.arena, "unable to read imported file \"{s}\"", .{resolved});
                return self.fail(path, import_node, message);
            };
            _ = try self.visit(resolved, child_source, depth + 1);
            try self.visited.append(self.arena, resolved);
        }
        for (document.templates) |template_node| {
            if (self.templates.items.len >= max_document_templates) {
                return self.fail(path, template_node, max_templates_message);
            }
            if (template_node.attr("name")) |name| {
                for (self.templates.items) |existing| {
                    const existing_name = existing.attr("name") orelse continue;
                    if (std.mem.eql(u8, existing_name, name)) {
                        const message = try std.fmt.allocPrint(
                            self.arena,
                            "duplicate template name \"{s}\" - also defined at {s}:{d}:{d}; template names are document-wide once imports resolve, so rename one (imports never shadow silently)",
                            .{ name, existing.src_path, existing.line, existing.column },
                        );
                        return self.fail(path, template_node, message);
                    }
                }
            }
            try self.templates.append(self.arena, try stampSourcePath(self.arena, template_node, path));
        }
        if (document.root) |root_node| {
            if (depth > 0) {
                self.diagnostic.* = .{
                    .line = root_node.line,
                    .column = root_node.column,
                    .message = import_view_root_message,
                    .path = path,
                };
                return error.MarkupImport;
            }
            return try stampSourcePath(self.arena, root_node, path);
        }
        return null;
    }

    fn fail(self: *ImportResolver, path: []const u8, node: MarkupNode, message: []const u8) ResolveError {
        self.diagnostic.* = .{ .line = node.line, .column = node.column, .message = message, .path = path };
        return error.MarkupImport;
    }

    fn wasVisited(self: *const ImportResolver, path: []const u8) bool {
        for (self.visited.items) |seen| {
            if (std.mem.eql(u8, seen, path)) return true;
        }
        return false;
    }

    /// "import cycle: a.native -> b.native -> a.native" — the chain from the first
    /// occurrence of the re-imported file down to the import that closes
    /// the loop.
    fn cycleMessage(self: *ImportResolver, start: usize, depth: usize, resolved: []const u8) error{OutOfMemory}![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(self.arena, "import cycle: ");
        for (self.chain[start .. depth + 1]) |link| {
            try out.appendSlice(self.arena, link);
            try out.appendSlice(self.arena, " -> ");
        }
        try out.appendSlice(self.arena, resolved);
        return out.items;
    }
};

fn stampSourcePath(arena: std.mem.Allocator, node: MarkupNode, path: []const u8) error{OutOfMemory}!MarkupNode {
    // An anonymous root (single-file resolution) keeps diagnostics
    // path-less, exactly like the unresolved parse — no copy needed.
    if (path.len == 0) return node;
    var out = node;
    out.src_path = path;
    if (node.children.len > 0) {
        const children = try arena.alloc(MarkupNode, node.children.len);
        for (node.children, 0..) |child, index| {
            children[index] = try stampSourcePath(arena, child, path);
        }
        out.children = children;
    }
    return out;
}

pub const ImportPathResult = union(enum) {
    path: []const u8,
    message: []const u8,
};

/// Lexically join `src` against the importing file's directory and
/// normalize it: "." segments drop, ".." pops, subdirectories stay. The
/// result must remain under `root_dir` (the markup root — the root view
/// file's directory); escapes and absolute paths come back as teaching
/// messages. Comptime-callable; the returned path slices `buffer`.
pub fn resolveImportPath(root_dir: []const u8, importer_path: []const u8, src: []const u8, buffer: []u8) ImportPathResult {
    if (importSrcShapeError(src)) |message| return .{ .message = message };
    // Tokenizing drops the leading "/" of an absolute importer path, so
    // remember it and restore it when the path is rebuilt below. Without
    // this, checking a view by absolute path rebuilds imports as relative
    // strings, and the escape check against the absolute markup root
    // rejects every import (and the loader would read the wrong file).
    const absolute = importer_path.len > 0 and importer_path[0] == '/';
    var segments: [max_import_path_segments][]const u8 = undefined;
    var count: usize = 0;
    var dir_it = std.mem.tokenizeScalar(u8, dirnamePath(importer_path), '/');
    while (dir_it.next()) |segment| {
        if (count >= segments.len) return .{ .message = import_src_too_long_message };
        segments[count] = segment;
        count += 1;
    }
    var src_it = std.mem.tokenizeScalar(u8, src, '/');
    while (src_it.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (count == 0) return .{ .message = import_src_escape_message };
            count -= 1;
            continue;
        }
        if (count >= segments.len) return .{ .message = import_src_too_long_message };
        segments[count] = segment;
        count += 1;
    }
    var len: usize = 0;
    if (absolute) {
        if (buffer.len == 0) return .{ .message = import_src_too_long_message };
        buffer[0] = '/';
        len = 1;
    }
    for (segments[0..count], 0..) |segment, index| {
        const extra = segment.len + @intFromBool(index > 0);
        if (len + extra > buffer.len) return .{ .message = import_src_too_long_message };
        if (index > 0) {
            buffer[len] = '/';
            len += 1;
        }
        @memcpy(buffer[len .. len + segment.len], segment);
        len += segment.len;
    }
    const path = buffer[0..len];
    if (!pathWithinRoot(root_dir, path)) return .{ .message = import_src_escape_message };
    return .{ .path = path };
}

fn pathWithinRoot(root_dir: []const u8, path: []const u8) bool {
    if (root_dir.len == 0) return true;
    if (!std.mem.startsWith(u8, path, root_dir)) return false;
    return path.len > root_dir.len and path[root_dir.len] == '/';
}

fn dirnamePath(path: []const u8) []const u8 {
    const index = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..index];
}

// ------------------------------------------------ comptime import resolve

/// Comptime mirror of `resolveImports` for the compiled engine: the source
/// mapping is an embedded set the app assembles with `@embedFile` (paths
/// relative to the root file's directory), and every resolution failure is
/// a compile error carrying the same teaching message the runtime resolver
/// would report, prefixed with the offending file.
pub fn resolveImportsComptime(comptime root_name: []const u8, comptime sources: []const SourceFile) MarkupDocument {
    comptime {
        var total_len: usize = 0;
        for (sources) |file| total_len += file.source.len;
        @setEvalBranchQuota(comptime_parse_quota_base + total_len * comptime_parse_quota_per_byte + (sources.len + 1) * 50_000);
        const root_source = findSourceComptime(sources, root_name) orelse
            @compileError("markup import: no embedded source for the root file \"" ++ root_name ++
                "\" - the source set passed to CompiledMarkupImports must contain it (.{ .path = \"" ++ root_name ++ "\", .source = @embedFile(\"" ++ root_name ++ "\") })");
        var templates: []const MarkupNode = &.{};
        var visited: []const []const u8 = &.{};
        const root = visitComptime(root_name, root_source, sources, dirnamePath(root_name), &templates, &visited, &.{});
        return .{ .imports = &.{}, .templates = templates, .root = root };
    }
}

fn visitComptime(
    comptime path: []const u8,
    comptime source: []const u8,
    comptime sources: []const SourceFile,
    comptime root_dir: []const u8,
    comptime templates: *[]const MarkupNode,
    comptime visited: *[]const []const u8,
    comptime chain: []const []const u8,
) ?MarkupNode {
    comptime {
        const document = parseComptime(source);
        for (document.imports) |import_node| {
            if (validateImport(import_node)) |info| failResolveComptime(path, info.line, info.column, info.message);
            const src = import_node.attr("src").?;
            var buffer: [max_import_path_len]u8 = undefined;
            const resolved = switch (resolveImportPath(root_dir, path, src, &buffer)) {
                .path => |normalized| freezePathComptime(normalized),
                .message => |message| failResolveComptime(path, import_node.line, import_node.column, message),
            };
            var cycle_start: ?usize = null;
            const full_chain = chain ++ &[_][]const u8{path};
            for (full_chain, 0..) |ancestor, index| {
                if (std.mem.eql(u8, ancestor, resolved)) cycle_start = index;
            }
            if (cycle_start) |start| {
                var message: []const u8 = "import cycle: ";
                for (full_chain[start..]) |link| message = message ++ link ++ " -> ";
                failResolveComptime(path, import_node.line, import_node.column, message ++ resolved);
            }
            if (containsPathComptime(visited.*, resolved)) continue;
            if (chain.len + 1 >= max_import_depth) failResolveComptime(path, import_node.line, import_node.column, import_depth_message);
            if (visited.len >= max_imported_files) failResolveComptime(path, import_node.line, import_node.column, import_count_message);
            const child_source = findSourceComptime(sources, resolved) orelse
                @compileError("markup import: no embedded source for \"" ++ resolved ++
                    "\" (imported by " ++ path ++ ") - add .{ .path = \"" ++ resolved ++ "\", .source = @embedFile(\"" ++ resolved ++ "\") } to the markup source set");
            _ = visitComptime(resolved, child_source, sources, root_dir, templates, visited, full_chain);
            visited.* = visited.* ++ &[_][]const u8{resolved};
        }
        for (document.templates) |template_node| {
            if (templates.len >= max_document_templates) {
                failResolveComptime(path, template_node.line, template_node.column, max_templates_message);
            }
            if (template_node.attr("name")) |name| {
                for (templates.*) |existing| {
                    const existing_name = existing.attr("name") orelse continue;
                    if (std.mem.eql(u8, existing_name, name)) {
                        failResolveComptime(path, template_node.line, template_node.column, std.fmt.comptimePrint(
                            "duplicate template name \"{s}\" - also defined at {s}:{d}:{d}; template names are document-wide once imports resolve, so rename one (imports never shadow silently)",
                            .{ name, existing.src_path, existing.line, existing.column },
                        ));
                    }
                }
            }
            templates.* = templates.* ++ &[_]MarkupNode{stampSourcePathComptime(template_node, path)};
        }
        if (document.root) |root_node| {
            if (chain.len > 0) {
                failResolveComptime(path, root_node.line, root_node.column, import_view_root_message);
            }
            return stampSourcePathComptime(root_node, path);
        }
        return null;
    }
}

fn findSourceComptime(comptime sources: []const SourceFile, comptime path: []const u8) ?[]const u8 {
    comptime {
        for (sources) |file| {
            if (std.mem.eql(u8, file.path, path)) return file.source;
        }
        return null;
    }
}

fn containsPathComptime(comptime paths: []const []const u8, comptime path: []const u8) bool {
    comptime {
        for (paths) |candidate| {
            if (std.mem.eql(u8, candidate, path)) return true;
        }
        return false;
    }
}

/// Copy a buffer-backed comptime path into interned comptime memory (the
/// scratch buffer it slices is mutated by the next resolution).
fn freezePathComptime(comptime path: []const u8) []const u8 {
    comptime {
        var out: [path.len]u8 = undefined;
        @memcpy(&out, path);
        const frozen = out;
        return &frozen;
    }
}

fn stampSourcePathComptime(comptime node: MarkupNode, comptime path: []const u8) MarkupNode {
    comptime {
        if (path.len == 0) return node;
        var out = node;
        out.src_path = path;
        if (node.children.len > 0) {
            var children: []const MarkupNode = &.{};
            for (node.children) |child| {
                children = children ++ &[_]MarkupNode{stampSourcePathComptime(child, path)};
            }
            out.children = children;
        }
        return out;
    }
}

fn failResolveComptime(comptime path: []const u8, comptime line: usize, comptime column: usize, comptime message: []const u8) noreturn {
    @compileError(std.fmt.comptimePrint("markup error in {s} at line {d}, column {d}: {s}", .{ path, line, column, message }));
}
