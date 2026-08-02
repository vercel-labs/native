//! NSUI: the canonical UI document's serialized form.
//!
//! One deterministic little-endian binary encoding of a resolved markup
//! document — registry CODES on the wire, never names, so a rename or
//! reorder in source can never silently change what stored artifacts mean.
//! Native markup text stays the house *authoring* projection; NSUI is a tooling
//! interchange and journal-anchor format, not something humans or agents
//! write. The derived human view is `writeJson` (`native markup dump`),
//! always produced FROM the decoded binary so the binary stays the
//! artifact of record.
//!
//! Rules inherited from the render wire format's discipline:
//! length-prefixed throughout, no field names, codes pinned independently
//! of any Zig declaration order, encode/decode golden tests, and a
//! hash-coverage test pinning that every structural field participates in
//! the document hash. Where it deliberately DIFFERS from that transport:
//! documents outlive binaries (journals, snapshots reference them), so
//! the format never hard-cuts — the header carries `schema_version`, a
//! reader refuses versions and codes it does not know with a teaching
//! message (never a silent skip), and future versions reach old artifacts
//! through document→document migrations.
//!
//! The DOCUMENT HASH is a Wyhash over the span- and provenance-stripped
//! structural encoding: two sources that differ only in whitespace,
//! formatting, or file layout hash identically; any structural change —
//! an element, an attribute name or value, text content, a template, node
//! order — changes the hash. Journals and snapshots anchor on
//! (schema_version, document hash).
//!
//! Layout:
//!   "NSUI" u8[4] | schema_version u16 | flags u16 (bit0 spans,
//!     bit1 provenance/source-path table)
//!   | [path table: count u16, paths (str16)]        (flag bit1)
//!   | template_count u16 | templates: node*
//!   | root_present u8 | [root: node]
//!   node: node_kind u8 (pinned below) | element_code u16 (0 for
//!     non-element kinds) | [path_index u16] | [span u32,u32]
//!   | text str32 (text runs; len 0 otherwise)
//!   | attr_count u16 | attrs { attr_code u16 (0 = document-defined name:
//!       str16 follows — `<use>` template-arg names, the one place the
//!       vocabulary is the document's, not the registry's; bit15 set =
//!       EVENT code, the attribute is `on-<event>`), value str16,
//!       [name_span u32,u32, value_span u32,u32] }
//!   | child_count u16 | children: node*

const std = @import("std");
const markup = @import("ui_markup.zig");
const schema = @import("ui_schema.zig");

pub const magic = "NSUI";

pub const EncodeOptions = struct {
    /// Write byte-range spans (write-back tooling wants them; the
    /// document hash never includes them).
    spans: bool = true,
    /// Write the source-path table and per-node path indices (provenance;
    /// excluded from the document hash so file layout is not structure).
    provenance: bool = true,
};

const flag_spans: u16 = 0x01;
const flag_provenance: u16 = 0x02;

/// Attr-code bit marking an EVENT code (`on-<event>` attributes live in
/// the event table, not the attr table).
const event_code_flag: u16 = 0x8000;

/// Wire codes for node kinds — pinned independently of the
/// `MarkupNodeKind` declaration order, exactly like the registry's
/// element/attr/event codes and the render wire's command-kind codes.
fn nodeKindCode(kind: markup.MarkupNodeKind) u8 {
    return switch (kind) {
        .element => 1,
        .text => 2,
        .for_block => 3,
        .if_block => 4,
        .else_block => 5,
        .template_block => 6,
        .use_block => 7,
        .import_block => 8,
        .slot_block => 9,
    };
}

fn nodeKindFromCode(code: u8) ?markup.MarkupNodeKind {
    return switch (code) {
        1 => .element,
        2 => .text,
        3 => .for_block,
        4 => .if_block,
        5 => .else_block,
        6 => .template_block,
        7 => .use_block,
        8 => .import_block,
        9 => .slot_block,
        else => null,
    };
}

/// The structure-node spellings the decoder restores (`MarkupNode.name`
/// carries them for parsed documents; codes carry them on the wire).
fn structureName(kind: markup.MarkupNodeKind) []const u8 {
    return switch (kind) {
        .element, .text => "",
        .for_block => "for",
        .if_block => "if",
        .else_block => "else",
        .template_block => "template",
        .use_block => "use",
        .import_block => "import",
        .slot_block => "slot",
    };
}

pub const EncodeError = error{ OutOfMemory, DocumentEncode };
pub const DecodeError = error{ OutOfMemory, DocumentDecode };

pub const CodecDiagnostic = struct {
    message: []const u8 = "",
};

pub const unresolved_imports_message = "this document has unresolved imports - resolve them (resolveImports) before encoding; NSUI carries the merged closure, not import references";
pub const unknown_element_message = "element is not in the schema registry - NSUI carries registry codes, so only registry vocabulary serializes (validate the document first)";
pub const unknown_attr_message = "attribute is not in the schema registry - NSUI carries registry codes, so only registry vocabulary serializes (validate the document first)";
pub const bad_magic_message = "not an NSUI document (bad magic)";
pub const bad_version_message = "this NSUI document carries a schema version this toolchain does not know - migrate it with a matching toolchain (if the document is newer than this binary, rebuild `native` from the current checkout and compare `native version`)";
pub const truncated_message = "truncated NSUI document";
pub const unknown_code_message = "this NSUI document uses a registry code this toolchain does not know - it was produced by a newer toolchain (rebuild `native` from the current checkout and compare `native version`); unknown codes are refused, never skipped";
pub const depth_message = "NSUI document nests too deeply";

/// Documents deeper than this refuse to decode: hostile input must never
/// exhaust the stack. Legitimate views sit far below (the engines' own
/// scope depth is 16).
pub const max_decode_depth = 64;

// ------------------------------------------------------------------ encode

const Encoder = struct {
    arena: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8) = .empty,
    options: EncodeOptions,
    paths: std.ArrayListUnmanaged([]const u8) = .empty,
    diagnostic: *CodecDiagnostic,

    fn fail(self: *Encoder, message: []const u8) EncodeError {
        self.diagnostic.message = message;
        return error.DocumentEncode;
    }

    fn byte(self: *Encoder, value: u8) error{OutOfMemory}!void {
        try self.out.append(self.arena, value);
    }

    fn int(self: *Encoder, comptime T: type, value: T) error{OutOfMemory}!void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        try self.out.appendSlice(self.arena, &bytes);
    }

    fn str16(self: *Encoder, text: []const u8) EncodeError!void {
        if (text.len > std.math.maxInt(u16)) return self.fail("string too long for NSUI (u16 length)");
        try self.int(u16, @intCast(text.len));
        try self.out.appendSlice(self.arena, text);
    }

    fn str32(self: *Encoder, text: []const u8) EncodeError!void {
        if (text.len > std.math.maxInt(u32)) return self.fail("string too long for NSUI (u32 length)");
        try self.int(u32, @intCast(text.len));
        try self.out.appendSlice(self.arena, text);
    }

    fn pathIndex(self: *Encoder, path: []const u8) error{OutOfMemory}!u16 {
        for (self.paths.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, path)) return @intCast(index);
        }
        try self.paths.append(self.arena, path);
        return @intCast(self.paths.items.len - 1);
    }

    fn span(self: *Encoder, value: markup.Span) EncodeError!void {
        if (value.start > std.math.maxInt(u32) or value.end > std.math.maxInt(u32)) {
            return self.fail("span offset too large for NSUI (u32)");
        }
        try self.int(u32, @intCast(value.start));
        try self.int(u32, @intCast(value.end));
    }

    fn node(self: *Encoder, value: markup.MarkupNode) EncodeError!void {
        try self.byte(nodeKindCode(value.kind));
        var element_code: u16 = 0;
        if (value.kind == .element) {
            const entry = schema.elementByName(value.name) orelse return self.fail(unknown_element_message);
            element_code = entry.code;
        }
        try self.int(u16, element_code);
        if (self.options.provenance) {
            try self.int(u16, try self.pathIndex(value.src_path));
        }
        if (self.options.spans) {
            try self.span(value.span);
        }
        try self.str32(if (value.kind == .text) value.text else "");
        if (value.attrs.len > std.math.maxInt(u16)) return self.fail("too many attributes for NSUI");
        try self.int(u16, @intCast(value.attrs.len));
        for (value.attrs) |attribute| {
            if (std.mem.startsWith(u8, attribute.name, "on-")) {
                const entry = schema.eventByName(attribute.name[3..]) orelse return self.fail(unknown_attr_message);
                try self.int(u16, event_code_flag | entry.code);
            } else if (schema.attrByName(attribute.name)) |entry| {
                try self.int(u16, entry.code);
            } else if (value.kind == .use_block) {
                // Template-arg names are document-defined vocabulary
                // (declared by the template's `args`), so they ride by
                // name — the only inline names on the wire.
                try self.int(u16, 0);
                try self.str16(attribute.name);
            } else {
                return self.fail(unknown_attr_message);
            }
            try self.str16(attribute.value);
            if (self.options.spans) {
                try self.span(attribute.name_span);
                try self.span(attribute.value_span);
            }
        }
        if (value.children.len > std.math.maxInt(u16)) return self.fail("too many children for NSUI");
        try self.int(u16, @intCast(value.children.len));
        for (value.children) |child| {
            try self.node(child);
        }
    }
};

/// Encode a RESOLVED document (imports merged; `markup.validate` green —
/// unregistered vocabulary refuses loudly). Deterministic: the same
/// document encodes to the same bytes, always.
pub fn encode(
    arena: std.mem.Allocator,
    document: markup.MarkupDocument,
    options: EncodeOptions,
    diagnostic: *CodecDiagnostic,
) EncodeError![]const u8 {
    if (document.imports.len > 0) {
        diagnostic.message = unresolved_imports_message;
        return error.DocumentEncode;
    }
    var encoder = Encoder{ .arena = arena, .options = options, .diagnostic = diagnostic };

    // Body first: the path table is collected while encoding and written
    // into the header section afterwards.
    var body = Encoder{ .arena = arena, .options = options, .diagnostic = diagnostic };
    if (document.templates.len > std.math.maxInt(u16)) return body.fail("too many templates for NSUI");
    try body.int(u16, @intCast(document.templates.len));
    for (document.templates) |template_node| {
        try body.node(template_node);
    }
    try body.byte(if (document.root != null) 1 else 0);
    if (document.root) |root| {
        try body.node(root);
    }

    try encoder.out.appendSlice(arena, magic);
    try encoder.int(u16, schema.schema_version);
    var flags: u16 = 0;
    if (options.spans) flags |= flag_spans;
    if (options.provenance) flags |= flag_provenance;
    try encoder.int(u16, flags);
    if (options.provenance) {
        if (body.paths.items.len > std.math.maxInt(u16)) return encoder.fail("too many source paths for NSUI");
        try encoder.int(u16, @intCast(body.paths.items.len));
        for (body.paths.items) |path| {
            try encoder.str16(path);
        }
    }
    try encoder.out.appendSlice(arena, body.out.items);
    return encoder.out.items;
}

/// The document hash journals and snapshots anchor on: Wyhash over the
/// span- and provenance-stripped structural encoding. Reformatting a
/// source or moving files never changes it; any structural edit does.
pub fn documentHash(arena: std.mem.Allocator, document: markup.MarkupDocument) EncodeError!u64 {
    var diagnostic = CodecDiagnostic{};
    const bytes = try encode(arena, document, .{ .spans = false, .provenance = false }, &diagnostic);
    return std.hash.Wyhash.hash(0, bytes);
}

// ------------------------------------------------------------------ decode

const Decoder = struct {
    arena: std.mem.Allocator,
    bytes: []const u8,
    offset: usize = 0,
    spans: bool = false,
    provenance: bool = false,
    paths: []const []const u8 = &.{},
    diagnostic: *CodecDiagnostic,

    fn fail(self: *Decoder, message: []const u8) DecodeError {
        self.diagnostic.message = message;
        return error.DocumentDecode;
    }

    fn take(self: *Decoder, count: usize) DecodeError![]const u8 {
        if (self.bytes.len - self.offset < count) return self.fail(truncated_message);
        const slice = self.bytes[self.offset .. self.offset + count];
        self.offset += count;
        return slice;
    }

    fn byte(self: *Decoder) DecodeError!u8 {
        return (try self.take(1))[0];
    }

    fn int(self: *Decoder, comptime T: type) DecodeError!T {
        const slice = try self.take(@sizeOf(T));
        return std.mem.readInt(T, slice[0..@sizeOf(T)], .little);
    }

    fn str16(self: *Decoder) DecodeError![]const u8 {
        const len = try self.int(u16);
        return self.take(len);
    }

    fn str32(self: *Decoder) DecodeError![]const u8 {
        const len = try self.int(u32);
        return self.take(len);
    }

    fn span(self: *Decoder) DecodeError!markup.Span {
        const start = try self.int(u32);
        const end = try self.int(u32);
        return .{ .start = start, .end = end };
    }

    fn node(self: *Decoder, depth: usize) DecodeError!markup.MarkupNode {
        if (depth > max_decode_depth) return self.fail(depth_message);
        const kind_code = try self.byte();
        const kind = nodeKindFromCode(kind_code) orelse return self.fail(unknown_code_message);
        const element_code = try self.int(u16);
        var out = markup.MarkupNode{ .kind = kind };
        if (kind == .element) {
            const entry = schema.elementByCode(element_code) orelse return self.fail(unknown_code_message);
            out.name = entry.name;
        } else {
            if (element_code != 0) return self.fail(unknown_code_message);
            out.name = structureName(kind);
        }
        if (self.provenance) {
            const path_index = try self.int(u16);
            if (path_index >= self.paths.len) return self.fail(truncated_message);
            out.src_path = self.paths[path_index];
        }
        if (self.spans) {
            out.span = try self.span();
        }
        out.text = try self.str32();
        const attr_count = try self.int(u16);
        if (attr_count > 0) {
            const attrs = try self.arena.alloc(markup.MarkupAttr, attr_count);
            for (attrs) |*attribute| {
                const attr_code = try self.int(u16);
                var attr_name: []const u8 = undefined;
                if (attr_code == 0) {
                    if (kind != .use_block) return self.fail(unknown_code_message);
                    attr_name = try self.str16();
                } else if (attr_code & event_code_flag != 0) {
                    attr_name = schema.eventAttrNameByCode(attr_code & ~event_code_flag) orelse
                        return self.fail(unknown_code_message);
                } else {
                    const entry = schema.attrByCode(attr_code) orelse return self.fail(unknown_code_message);
                    attr_name = entry.name;
                }
                attribute.* = .{ .name = attr_name, .value = try self.str16(), .line = 0, .column = 0 };
                if (self.spans) {
                    attribute.name_span = try self.span();
                    attribute.value_span = try self.span();
                }
            }
            out.attrs = attrs;
        }
        const child_count = try self.int(u16);
        if (child_count > 0) {
            const children = try self.arena.alloc(markup.MarkupNode, child_count);
            for (children) |*child| {
                child.* = try self.node(depth + 1);
            }
            out.children = children;
        }
        return out;
    }
};

/// Decode an NSUI document. Refuses unknown versions and codes loudly
/// (never a silent skip) and hostile depth/length input safely. The
/// result is CANONICALIZED (typed values stamped), ready for either
/// engine or further tooling; line/column positions are derived from the
/// carried spans when present.
pub fn decode(arena: std.mem.Allocator, bytes: []const u8, diagnostic: *CodecDiagnostic) DecodeError!markup.MarkupDocument {
    var decoder = Decoder{ .arena = arena, .bytes = bytes, .diagnostic = diagnostic };
    const header = try decoder.take(magic.len);
    if (!std.mem.eql(u8, header, magic)) return decoder.fail(bad_magic_message);
    const version = try decoder.int(u16);
    if (version != schema.schema_version) return decoder.fail(bad_version_message);
    const flags = try decoder.int(u16);
    decoder.spans = flags & flag_spans != 0;
    decoder.provenance = flags & flag_provenance != 0;
    if (decoder.provenance) {
        const count = try decoder.int(u16);
        const paths = try arena.alloc([]const u8, count);
        for (paths) |*path| {
            path.* = try decoder.str16();
        }
        decoder.paths = paths;
    }
    const template_count = try decoder.int(u16);
    if (template_count > markup.max_document_templates) return decoder.fail(markup.max_templates_message);
    const templates = try arena.alloc(markup.MarkupNode, template_count);
    for (templates) |*template_node| {
        template_node.* = try decoder.node(0);
    }
    // `source_bytes` sizes the tree for quota scaling; the artifact
    // carries every node's text/names/attrs, so its length is the honest
    // stand-in for the source this document no longer has.
    var document = markup.MarkupDocument{ .templates = templates, .source_bytes = bytes.len };
    if (try decoder.byte() != 0) {
        document.root = try decoder.node(0);
    }
    if (decoder.offset != bytes.len) return decoder.fail("trailing bytes after the NSUI document - refusing (framing disagreement)");
    return markup.canonicalize(arena, document);
}

// --------------------------------------------------------------- JSON dump

/// The derived human view (`native markup dump`): JSON produced from a
/// document — in the dump verb, always the DECODED binary, so what you
/// inspect is what the artifact says, not what the source said. Purely
/// derived: nothing parses JSON back; the binary stays canonical.
pub fn writeJson(document: markup.MarkupDocument, document_hash: u64, writer: anytype) !void {
    try writer.print("{{\"schemaVersion\":{d},\"documentHash\":\"{x:0>16}\"", .{ schema.schema_version, document_hash });
    try writer.writeAll(",\"templates\":[");
    for (document.templates, 0..) |template_node, index| {
        if (index > 0) try writer.writeByte(',');
        try writeNodeJson(template_node, writer);
    }
    try writer.writeAll("]");
    if (document.root) |root| {
        try writer.writeAll(",\"root\":");
        try writeNodeJson(root, writer);
    }
    try writer.writeAll("}\n");
}

fn writeNodeJson(node: markup.MarkupNode, writer: anytype) !void {
    if (node.kind == .text) {
        try writer.writeAll("{\"text\":");
        try writeJsonString(node.text, writer);
        try writeSpanJson(node.span, writer);
        try writer.writeByte('}');
        return;
    }
    try writer.writeAll("{\"node\":");
    try writeJsonString(node.name, writer);
    if (node.kind == .element) {
        if (schema.elementByName(node.name)) |entry| {
            try writer.print(",\"code\":{d}", .{entry.code});
        }
    }
    if (node.src_path.len > 0) {
        try writer.writeAll(",\"src\":");
        try writeJsonString(node.src_path, writer);
    }
    try writeSpanJson(node.span, writer);
    if (node.attrs.len > 0) {
        try writer.writeAll(",\"attrs\":[");
        for (node.attrs, 0..) |attribute, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try writeJsonString(attribute.name, writer);
            if (schema.attrByName(attribute.name)) |entry| {
                try writer.print(",\"code\":{d}", .{entry.code});
            }
            try writer.writeAll(",\"value\":");
            try writeJsonString(attribute.value, writer);
            try writer.print(",\"typed\":\"{s}\"", .{@tagName(markup.attrTyped(attribute))});
            try writer.writeByte('}');
        }
        try writer.writeAll("]");
    }
    if (node.children.len > 0) {
        try writer.writeAll(",\"children\":[");
        for (node.children, 0..) |child, index| {
            if (index > 0) try writer.writeByte(',');
            try writeNodeJson(child, writer);
        }
        try writer.writeAll("]");
    }
    try writer.writeByte('}');
}

fn writeSpanJson(span: markup.Span, writer: anytype) !void {
    if (span.start == 0 and span.end == 0) return;
    try writer.print(",\"span\":[{d},{d}]", .{ span.start, span.end });
}

fn writeJsonString(text: []const u8, writer: anytype) !void {
    try writer.writeByte('"');
    for (text) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (char < 0x20) {
                    try writer.print("\\u{x:0>4}", .{char});
                } else {
                    try writer.writeByte(char);
                }
            },
        }
    }
    try writer.writeByte('"');
}
