//! Language Server Protocol server for `.zml` markup views, spoken over
//! stdio by `zero-native markup lsp`.
//!
//! v1 scope (model-agnostic, mirrors `zero-native markup check`):
//! - publishDiagnostics on didOpen/didChange via the shared parser and
//!   `ui_markup.validate` (line/column + teaching messages).
//! - completion: element names after `<`, attribute/event names inside a tag.
//! - hover: one-line docs for element and attribute names.
//!
//! Binding paths and message tags are NOT validated here — that requires the
//! app's concrete Model/Msg types, which only exist when the app builds.
//! Documented future work: a build-integrated mode that loads the app's
//! compiled binding metadata to check `{path}` and `on-*` tags.
//!
//! The protocol layer is hand-rolled on std only: Content-Length framing
//! over `std.Io.Reader`/`std.Io.Writer` (injectable, so tests drive the
//! whole server through fixed buffers) and `std.json` for messages.

const std = @import("std");
const ui_markup = @import("ui_markup");

pub const server_name = "zero-native-markup-lsp";
pub const server_version = "0.1.0";

// --------------------------------------------------------------- framing

pub const FrameError = error{
    InvalidFrame,
    EndOfStream,
    ReadFailed,
    StreamTooLong,
    OutOfMemory,
};

/// Read one LSP frame: `Content-Length: N` headers, a blank line, then a
/// body of exactly N bytes. Returns the body, owned by `allocator`.
pub fn readFrame(allocator: std.mem.Allocator, in: *std.Io.Reader) FrameError![]u8 {
    var content_length: ?usize = null;
    while (true) {
        const raw = try in.takeDelimiterInclusive('\n');
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) break;
        const prefix = "content-length:";
        if (line.len > prefix.len and std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix)) {
            const value = std.mem.trim(u8, line[prefix.len..], " \t");
            content_length = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidFrame;
        }
    }
    const length = content_length orelse return error.InvalidFrame;
    const body = try allocator.alloc(u8, length);
    errdefer allocator.free(body);
    try in.readSliceAll(body);
    return body;
}

fn sendFrame(out: *std.Io.Writer, body: []const u8) !void {
    try out.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try out.writeAll(body);
    try out.flush();
}

// ---------------------------------------------------------------- server

pub const Server = struct {
    allocator: std.mem.Allocator,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    /// uri -> current document text; both allocated with `allocator`.
    documents: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, in: *std.Io.Reader, out: *std.Io.Writer) Server {
        return .{ .allocator = allocator, .in = in, .out = out };
    }

    pub fn deinit(self: *Server) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.documents.deinit(self.allocator);
    }

    /// Serve until the client sends `exit` or the input stream ends.
    pub fn run(self: *Server) !void {
        while (true) {
            const body = readFrame(self.allocator, self.in) catch |err| switch (err) {
                error.EndOfStream => return,
                error.InvalidFrame => continue,
                else => return err,
            };
            defer self.allocator.free(body);
            if (try self.handleMessage(body)) return;
        }
    }

    /// Returns true when the client asked the server to exit.
    fn handleMessage(self: *Server, body: []const u8) !bool {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return false;
        if (root != .object) return false;
        const id = root.object.get("id");
        const method_value = root.object.get("method") orelse return false;
        if (method_value != .string) return false;
        const method = method_value.string;
        const params: std.json.Value = root.object.get("params") orelse .null;

        if (std.mem.eql(u8, method, "initialize")) {
            try self.respondInitialize(arena, id);
        } else if (std.mem.eql(u8, method, "initialized")) {
            // nothing to do
        } else if (std.mem.eql(u8, method, "shutdown")) {
            try self.respondNull(arena, id);
        } else if (std.mem.eql(u8, method, "exit")) {
            return true;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            const text_document = member(params, "textDocument") orelse return false;
            const uri = stringMember(text_document, "uri") orelse return false;
            const text = stringMember(text_document, "text") orelse return false;
            const stored = try self.setDocument(uri, text);
            try self.publishDiagnostics(arena, uri, stored);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            const text_document = member(params, "textDocument") orelse return false;
            const uri = stringMember(text_document, "uri") orelse return false;
            const changes = member(params, "contentChanges") orelse return false;
            if (changes != .array) return false;
            var new_text: ?[]const u8 = null;
            for (changes.array.items) |change| {
                // Full-document sync only (we advertise sync kind 1); skip
                // any incremental change a client sends anyway.
                if (member(change, "range") != null) continue;
                if (stringMember(change, "text")) |text| new_text = text;
            }
            if (new_text) |text| {
                const stored = try self.setDocument(uri, text);
                try self.publishDiagnostics(arena, uri, stored);
            }
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            const text_document = member(params, "textDocument") orelse return false;
            const uri = stringMember(text_document, "uri") orelse return false;
            self.removeDocument(uri);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.respondCompletion(arena, id, params);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.respondHover(arena, id, params);
        } else if (id != null) {
            try self.respondMethodNotFound(arena, id, method);
        }
        return false;
    }

    fn setDocument(self: *Server, uri: []const u8, text: []const u8) ![]const u8 {
        const key = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(value);
        const gop = try self.documents.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(key);
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = value;
        return value;
    }

    fn removeDocument(self: *Server, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
    }

    fn respondInitialize(self: *Server, arena: std.mem.Allocator, id: ?std.json.Value) !void {
        var body: std.Io.Writer.Allocating = .init(arena);
        var js: std.json.Stringify = .{ .writer = &body.writer };
        try js.beginObject();
        try beginResponse(&js, id);
        try js.objectField("result");
        try js.beginObject();
        try js.objectField("capabilities");
        try js.beginObject();
        try js.objectField("textDocumentSync");
        try js.write(1); // full-document sync
        try js.objectField("completionProvider");
        try js.beginObject();
        try js.objectField("triggerCharacters");
        try js.write(&[_][]const u8{ "<", " " });
        try js.endObject();
        try js.objectField("hoverProvider");
        try js.write(true);
        try js.endObject();
        try js.objectField("serverInfo");
        try js.beginObject();
        try js.objectField("name");
        try js.write(server_name);
        try js.objectField("version");
        try js.write(server_version);
        try js.endObject();
        try js.endObject();
        try js.endObject();
        try sendFrame(self.out, body.written());
    }

    fn respondNull(self: *Server, arena: std.mem.Allocator, id: ?std.json.Value) !void {
        var body: std.Io.Writer.Allocating = .init(arena);
        var js: std.json.Stringify = .{ .writer = &body.writer };
        try js.beginObject();
        try beginResponse(&js, id);
        try js.objectField("result");
        try js.write(null);
        try js.endObject();
        try sendFrame(self.out, body.written());
    }

    fn respondMethodNotFound(self: *Server, arena: std.mem.Allocator, id: ?std.json.Value, method: []const u8) !void {
        var body: std.Io.Writer.Allocating = .init(arena);
        var js: std.json.Stringify = .{ .writer = &body.writer };
        try js.beginObject();
        try beginResponse(&js, id);
        try js.objectField("error");
        try js.beginObject();
        try js.objectField("code");
        try js.write(-32601);
        try js.objectField("message");
        try js.write(try std.fmt.allocPrint(arena, "method not found: {s}", .{method}));
        try js.endObject();
        try js.endObject();
        try sendFrame(self.out, body.written());
    }

    fn publishDiagnostics(self: *Server, arena: std.mem.Allocator, uri: []const u8, text: []const u8) !void {
        const finding = analyze(arena, text);
        var body: std.Io.Writer.Allocating = .init(arena);
        var js: std.json.Stringify = .{ .writer = &body.writer };
        try js.beginObject();
        try js.objectField("jsonrpc");
        try js.write("2.0");
        try js.objectField("method");
        try js.write("textDocument/publishDiagnostics");
        try js.objectField("params");
        try js.beginObject();
        try js.objectField("uri");
        try js.write(uri);
        try js.objectField("diagnostics");
        try js.beginArray();
        if (finding) |info| {
            const line = if (info.line > 0) info.line - 1 else 0;
            const character = if (info.column > 0) info.column - 1 else 0;
            const end_character = diagnosticEndCharacter(text, line, character);
            try js.beginObject();
            try js.objectField("range");
            try writeRange(&js, line, character, line, end_character);
            try js.objectField("severity");
            try js.write(1); // Error
            try js.objectField("source");
            try js.write("zml");
            try js.objectField("message");
            try js.write(info.message);
            try js.endObject();
        }
        try js.endArray();
        try js.endObject();
        try js.endObject();
        try sendFrame(self.out, body.written());
    }

    fn respondCompletion(self: *Server, arena: std.mem.Allocator, id: ?std.json.Value, params: std.json.Value) !void {
        var context: CompletionContext = .none;
        if (self.documentForParams(params)) |text| {
            if (positionFromParams(params)) |position| {
                context = completionContext(text, offsetForPosition(text, position.line, position.character));
            }
        }

        var body: std.Io.Writer.Allocating = .init(arena);
        var js: std.json.Stringify = .{ .writer = &body.writer };
        try js.beginObject();
        try beginResponse(&js, id);
        try js.objectField("result");
        try js.beginObject();
        try js.objectField("isIncomplete");
        try js.write(false);
        try js.objectField("items");
        try js.beginArray();
        switch (context) {
            .none => {},
            .elements => {
                for (element_docs) |doc| try writeCompletionItem(&js, doc.name, .class, "zml element", doc.doc);
                for (structure_docs) |doc| try writeCompletionItem(&js, doc.name, .keyword, "zml structure tag", doc.doc);
            },
            .attributes => |element_name| {
                if (std.mem.eql(u8, element_name, "for")) {
                    for (for_attr_docs) |doc| try writeCompletionItem(&js, doc.name, .property, "for attribute", doc.doc);
                } else if (std.mem.eql(u8, element_name, "if")) {
                    for (if_attr_docs) |doc| try writeCompletionItem(&js, doc.name, .property, "if attribute", doc.doc);
                } else if (std.mem.eql(u8, element_name, "else")) {
                    // else takes no attributes
                } else {
                    for (attribute_docs) |doc| try writeCompletionItem(&js, doc.name, .property, "zml attribute", doc.doc);
                    for (event_docs) |doc| try writeCompletionItem(&js, doc.name, .event, "zml event", doc.doc);
                }
            },
        }
        try js.endArray();
        try js.endObject();
        try js.endObject();
        try sendFrame(self.out, body.written());
    }

    fn respondHover(self: *Server, arena: std.mem.Allocator, id: ?std.json.Value, params: std.json.Value) !void {
        var hover: ?HoverResult = null;
        if (self.documentForParams(params)) |text| {
            if (positionFromParams(params)) |position| {
                hover = hoverAt(text, offsetForPosition(text, position.line, position.character));
            }
        }

        var body: std.Io.Writer.Allocating = .init(arena);
        var js: std.json.Stringify = .{ .writer = &body.writer };
        try js.beginObject();
        try beginResponse(&js, id);
        try js.objectField("result");
        if (hover) |result| {
            const value = try std.fmt.allocPrint(arena, "**{s}** — {s}", .{ result.name, result.doc });
            try js.beginObject();
            try js.objectField("contents");
            try js.beginObject();
            try js.objectField("kind");
            try js.write("markdown");
            try js.objectField("value");
            try js.write(value);
            try js.endObject();
            try js.endObject();
        } else {
            try js.write(null);
        }
        try js.endObject();
        try sendFrame(self.out, body.written());
    }

    fn documentForParams(self: *Server, params: std.json.Value) ?[]const u8 {
        const text_document = member(params, "textDocument") orelse return null;
        const uri = stringMember(text_document, "uri") orelse return null;
        return self.documents.get(uri);
    }
};

fn beginResponse(js: *std.json.Stringify, id: ?std.json.Value) !void {
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(id orelse @as(std.json.Value, .null));
}

const CompletionKind = enum(u8) {
    keyword = 14,
    class = 7,
    property = 10,
    event = 23,
};

fn writeCompletionItem(js: *std.json.Stringify, label: []const u8, kind: CompletionKind, detail: []const u8, documentation: []const u8) !void {
    try js.beginObject();
    try js.objectField("label");
    try js.write(label);
    try js.objectField("kind");
    try js.write(@intFromEnum(kind));
    try js.objectField("detail");
    try js.write(detail);
    try js.objectField("documentation");
    try js.write(documentation);
    try js.endObject();
}

fn writeRange(js: *std.json.Stringify, start_line: usize, start_character: usize, end_line: usize, end_character: usize) !void {
    try js.beginObject();
    try js.objectField("start");
    try writePosition(js, start_line, start_character);
    try js.objectField("end");
    try writePosition(js, end_line, end_character);
    try js.endObject();
}

fn writePosition(js: *std.json.Stringify, line: usize, character: usize) !void {
    try js.beginObject();
    try js.objectField("line");
    try js.write(line);
    try js.objectField("character");
    try js.write(character);
    try js.endObject();
}

fn member(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn stringMember(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = member(value, name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

const Position = struct { line: usize, character: usize };

fn positionFromParams(params: std.json.Value) ?Position {
    const position = member(params, "position") orelse return null;
    const line = member(position, "line") orelse return null;
    const character = member(position, "character") orelse return null;
    if (line != .integer or character != .integer) return null;
    if (line.integer < 0 or character.integer < 0) return null;
    return .{ .line = @intCast(line.integer), .character = @intCast(character.integer) };
}

// --------------------------------------------------------------- analysis

/// Parse + structurally validate a document; returns the first finding or
/// null when the markup is clean. Messages are static strings, so the
/// result outlives `arena`.
pub fn analyze(arena: std.mem.Allocator, source: []const u8) ?ui_markup.MarkupErrorInfo {
    var parser = ui_markup.Parser.init(arena, source);
    const document = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => return .{ .line = 1, .column = 1, .message = "out of memory while parsing" },
        error.MarkupSyntax => return parser.diagnostic,
    };
    return ui_markup.validate(document);
}

/// Byte offset for a 0-based LSP position, clamped to the line's end.
/// Positions are treated as byte columns; `.zml` markup is ASCII in
/// practice (UTF-16 column mapping is documented future work).
pub fn offsetForPosition(text: []const u8, line: usize, character: usize) usize {
    var current_line: usize = 0;
    var index: usize = 0;
    while (current_line < line) {
        const newline = std.mem.indexOfScalarPos(u8, text, index, '\n') orelse return text.len;
        index = newline + 1;
        current_line += 1;
    }
    const line_end = std.mem.indexOfScalarPos(u8, text, index, '\n') orelse text.len;
    return @min(index + character, line_end);
}

/// End of the diagnostic range: extend across the name under the position
/// (element findings point at the `<`, attribute findings at the name) so
/// editors underline the whole identifier, not one character.
fn diagnosticEndCharacter(text: []const u8, line: usize, character: usize) usize {
    const offset = offsetForPosition(text, line, character);
    var end = offset;
    if (end < text.len and text[end] == '<') end += 1;
    if (end < text.len and text[end] == '/') end += 1;
    while (end < text.len and isNameChar(text[end])) end += 1;
    if (end == offset) return character + 1;
    return character + (end - offset);
}

fn isNameChar(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or byte == '-' or byte == '_';
}

// ------------------------------------------------------------- completion

pub const CompletionContext = union(enum) {
    none,
    /// Right after `<` (possibly mid element name): offer element names.
    elements,
    /// Inside a tag after the element name: offer attributes/events.
    /// Payload is the element name.
    attributes: []const u8,
};

pub fn completionContext(text: []const u8, offset: usize) CompletionContext {
    const open = lastTagOpen(text, offset) orelse return .none;
    if (insideQuotes(text, open, offset)) return .none;
    var index = open + 1;
    if (index < offset and text[index] == '/') index += 1;
    const name_start = index;
    while (index < offset and isNameChar(text[index])) index += 1;
    if (index == offset) return .elements;
    return .{ .attributes = text[name_start..index] };
}

/// Index of the `<` of the tag containing `offset`, or null when the
/// position is in text content (a `>` closes the nearest tag first).
fn lastTagOpen(text: []const u8, offset: usize) ?usize {
    var index = @min(offset, text.len);
    while (index > 0) {
        index -= 1;
        switch (text[index]) {
            '<' => return index,
            '>' => return null,
            else => {},
        }
    }
    return null;
}

fn insideQuotes(text: []const u8, from: usize, to: usize) bool {
    var quotes: usize = 0;
    for (text[from..@min(to, text.len)]) |byte| {
        if (byte == '"') quotes += 1;
    }
    return quotes % 2 == 1;
}

// ------------------------------------------------------------------ hover

pub const HoverResult = struct {
    name: []const u8,
    doc: []const u8,
};

pub fn hoverAt(text: []const u8, offset: usize) ?HoverResult {
    if (text.len == 0) return null;
    const clamped = @min(offset, text.len - 1);
    var start = clamped + @intFromBool(isNameChar(text[clamped]));
    while (start > 0 and isNameChar(text[start - 1])) start -= 1;
    var end = start;
    while (end < text.len and isNameChar(text[end])) end += 1;
    if (start == end) return null;
    const word = text[start..end];

    const is_element = (start >= 1 and text[start - 1] == '<') or
        (start >= 2 and text[start - 1] == '/' and text[start - 2] == '<');
    if (is_element) {
        const doc = elementDoc(word) orelse return null;
        return .{ .name = word, .doc = doc };
    }
    const open = lastTagOpen(text, start) orelse return null;
    if (insideQuotes(text, open, start)) return null;
    const doc = attributeDoc(word) orelse return null;
    return .{ .name = word, .doc = doc };
}

// ---------------------------------------------------------- documentation
// One-line docs sourced from skill-data/native-ui/SKILL.md (Elements /
// Attributes / Expressions / Structure tags tables).

pub const Doc = struct {
    name: []const u8,
    doc: []const u8,
};

pub const element_docs = [_]Doc{
    .{ .name = "row", .doc = "Flex container; children flow along the horizontal main axis." },
    .{ .name = "column", .doc = "Flex container; children flow along the vertical main axis." },
    .{ .name = "stack", .doc = "Overlay container; children stack on top of each other." },
    .{ .name = "panel", .doc = "Overlay container panel; children stack on top of each other." },
    .{ .name = "card", .doc = "Overlay container card; children stack on top of each other." },
    .{ .name = "scroll", .doc = "Scroll view; wrap multiple children in a single column inside it." },
    .{ .name = "list", .doc = "Vertical stack of items; supports virtualized and virtual-item-extent." },
    .{ .name = "grid", .doc = "Cell grid container." },
    .{ .name = "text", .doc = "Text leaf; content supports {} interpolation." },
    .{ .name = "badge", .doc = "Text leaf badge; content supports {} interpolation." },
    .{ .name = "button", .doc = "Text-bearing control; the label is the text content. Dispatch with on-press." },
    .{ .name = "checkbox", .doc = "Value control; bind checked, dispatch with on-toggle." },
    .{ .name = "radio", .doc = "Value control; bind checked or selected, dispatch with on-toggle." },
    .{ .name = "toggle", .doc = "Text-bearing toggle control; the label is the text content." },
    .{ .name = "slider", .doc = "Value control; bind value, dispatch with on-change." },
    .{ .name = "progress", .doc = "Value control; bind value." },
    .{ .name = "text-field", .doc = "Text entry; placeholder and text binding, edits via on-input, enter via on-submit." },
    .{ .name = "search-field", .doc = "Text entry styled for search; edits via on-input." },
    .{ .name = "textarea", .doc = "Multi-line text entry; edits via on-input." },
    .{ .name = "list-item", .doc = "Text-bearing item control; the label is the text content." },
    .{ .name = "menu-item", .doc = "Text-bearing menu control; the label is the text content." },
    .{ .name = "status-bar", .doc = "Status bar text leaf: content only, no children." },
    .{ .name = "separator", .doc = "Separator line." },
    .{ .name = "spacer", .doc = "Flexible space; give it a grow." },
};

pub const structure_docs = [_]Doc{
    .{ .name = "for", .doc = "Structure tag: repeats its single element child over each; requires each and as, key names an item field." },
    .{ .name = "if", .doc = "Structure tag: renders children when test={binding} or {a == b} is true." },
    .{ .name = "else", .doc = "Structure tag: must directly follow an if." },
};

pub const attribute_docs = [_]Doc{
    .{ .name = "text", .doc = "Text value for text-bearing elements; a literal or one {binding}." },
    .{ .name = "placeholder", .doc = "Hint text shown while a text entry is empty." },
    .{ .name = "value", .doc = "Value for slider/progress/text entry; a literal or one {binding}." },
    .{ .name = "checked", .doc = "Checked state for checkbox/toggle; true/false or a {binding}." },
    .{ .name = "selected", .doc = "Selected state; often a {a == b} equality." },
    .{ .name = "disabled", .doc = "Disables the control; true/false or a {binding}." },
    .{ .name = "variant", .doc = "Visual variant: default|primary|secondary|outline|ghost|destructive." },
    .{ .name = "size", .doc = "Control size: default|sm|lg|icon." },
    .{ .name = "width", .doc = "Fixed width (plain number)." },
    .{ .name = "height", .doc = "Fixed height (plain number)." },
    .{ .name = "grow", .doc = "Flex grow factor; give spacer one." },
    .{ .name = "gap", .doc = "Spacing between children (plain number)." },
    .{ .name = "padding", .doc = "Uniform padding (plain number)." },
    .{ .name = "main", .doc = "Main-axis alignment: start|center|end|space_between." },
    .{ .name = "cross", .doc = "Cross-axis alignment: stretch|start|center|end." },
    .{ .name = "virtualized", .doc = "Enable list virtualization (true/false)." },
    .{ .name = "virtual-item-extent", .doc = "Fixed item extent for virtualized lists (plain number)." },
    .{ .name = "key", .doc = "Sibling-scoped identity key; on for, names an item field." },
    .{ .name = "global-key", .doc = "Parent-independent identity: ids survive reparenting between containers." },
    .{ .name = "role", .doc = "Accessibility role (listitem, button, ...)." },
    .{ .name = "label", .doc = "Accessible name." },
};

pub const for_attr_docs = [_]Doc{
    .{ .name = "each", .doc = "for: Model field, pub decl, or model fn producing the slice to iterate." },
    .{ .name = "as", .doc = "for: name of the loop variable bindings use." },
    .{ .name = "key", .doc = "for: item field that keys identity across reorders." },
};

pub const if_attr_docs = [_]Doc{
    .{ .name = "test", .doc = "if: one {binding} or one {a == b} equality." },
};

pub const event_docs = [_]Doc{
    .{ .name = "on-press", .doc = "Dispatch a Msg on press: tag or tag:{payload}." },
    .{ .name = "on-toggle", .doc = "Dispatch a Msg on toggle: tag or tag:{payload}." },
    .{ .name = "on-change", .doc = "Dispatch a Msg on change: tag or tag:{payload}." },
    .{ .name = "on-submit", .doc = "Dispatch a Msg on enter in a text field: tag or tag:{payload}." },
    .{ .name = "on-input", .doc = "Names a Msg variant with canvas.TextInputEvent payload; delivers each text edit." },
};

pub fn elementDoc(name: []const u8) ?[]const u8 {
    if (findDoc(&element_docs, name)) |doc| return doc;
    return findDoc(&structure_docs, name);
}

pub fn attributeDoc(name: []const u8) ?[]const u8 {
    if (findDoc(&attribute_docs, name)) |doc| return doc;
    if (findDoc(&event_docs, name)) |doc| return doc;
    if (findDoc(&for_attr_docs, name)) |doc| return doc;
    return findDoc(&if_attr_docs, name);
}

fn findDoc(list: []const Doc, name: []const u8) ?[]const u8 {
    for (list) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.doc;
    }
    return null;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn frame(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

test "readFrame parses Content-Length framing" {
    const allocator = testing.allocator;
    const input = "Content-Length: 7\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{\"a\":1}content-length: 7\r\n\r\n{\"b\":2}";
    var reader = std.Io.Reader.fixed(input);

    const first = try readFrame(allocator, &reader);
    defer allocator.free(first);
    try testing.expectEqualStrings("{\"a\":1}", first);

    const second = try readFrame(allocator, &reader);
    defer allocator.free(second);
    try testing.expectEqualStrings("{\"b\":2}", second);

    try testing.expectError(error.EndOfStream, readFrame(allocator, &reader));
}

test "readFrame rejects a frame without Content-Length" {
    const allocator = testing.allocator;
    var reader = std.Io.Reader.fixed("Content-Type: application/json\r\n\r\n{}");
    try testing.expectError(error.InvalidFrame, readFrame(allocator, &reader));
}

test "serve: initialize, didOpen with broken markup, publishDiagnostics round trip" {
    const allocator = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // <bogus /> sits at line 2, column 3 (1-based) -> LSP line 1, character 2.
    const broken =
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{" ++
        "\"uri\":\"file:///tmp/app.zml\",\"languageId\":\"zml\",\"version\":1," ++
        "\"text\":\"<column>\\n  <bogus />\\n</column>\\n\"}}}";
    const valid_doc =
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{" ++
        "\"uri\":\"file:///tmp/app.zml\",\"version\":2},\"contentChanges\":[{" ++
        "\"text\":\"<row gap=\\\"8\\\"><text>hi</text></row>\"}]}}";

    var input: std.Io.Writer.Allocating = .init(arena);
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}",
        broken,
        valid_doc,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file:///tmp/app.zml\"},\"position\":{\"line\":0,\"character\":5}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///tmp/app.zml\"},\"position\":{\"line\":0,\"character\":2}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"shutdown\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    }) |body| {
        const framed = try frame(arena, body);
        try input.writer.writeAll(framed);
    }

    var reader = std.Io.Reader.fixed(input.written());
    var output: std.Io.Writer.Allocating = .init(arena);
    var server = Server.init(allocator, &reader, &output.writer);
    defer server.deinit();
    try server.run();

    // Re-read the server's own frames.
    var out_reader = std.Io.Reader.fixed(output.written());
    var bodies: std.ArrayList([]u8) = .empty;
    while (true) {
        const body = readFrame(arena, &out_reader) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try bodies.append(arena, body);
    }
    // initialize response, diagnostics (broken), diagnostics (clean),
    // completion, hover, shutdown.
    try testing.expectEqual(@as(usize, 6), bodies.items.len);

    try testing.expect(std.mem.indexOf(u8, bodies.items[0], "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, bodies.items[0], "\"capabilities\"") != null);
    try testing.expect(std.mem.indexOf(u8, bodies.items[0], "\"hoverProvider\":true") != null);

    // Broken document: one diagnostic at line 1, character 2..8 ("<bogus").
    const diag = try std.json.parseFromSliceLeaky(std.json.Value, arena, bodies.items[1], .{});
    const params = diag.object.get("params").?;
    try testing.expectEqualStrings("textDocument/publishDiagnostics", diag.object.get("method").?.string);
    try testing.expectEqualStrings("file:///tmp/app.zml", params.object.get("uri").?.string);
    const diagnostics = params.object.get("diagnostics").?.array.items;
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqualStrings("unknown element", diagnostics[0].object.get("message").?.string);
    const range = diagnostics[0].object.get("range").?;
    try testing.expectEqual(@as(i64, 1), range.object.get("start").?.object.get("line").?.integer);
    try testing.expectEqual(@as(i64, 2), range.object.get("start").?.object.get("character").?.integer);
    try testing.expectEqual(@as(i64, 8), range.object.get("end").?.object.get("character").?.integer);

    // Clean document clears diagnostics.
    try testing.expect(std.mem.indexOf(u8, bodies.items[2], "\"diagnostics\":[]") != null);

    // Completion inside `<row ` offers attributes and events.
    try testing.expect(std.mem.indexOf(u8, bodies.items[3], "\"label\":\"gap\"") != null);
    try testing.expect(std.mem.indexOf(u8, bodies.items[3], "\"label\":\"on-press\"") != null);
    try testing.expect(std.mem.indexOf(u8, bodies.items[3], "\"label\":\"row\"") == null);

    // Hover over `row` returns the element doc.
    try testing.expect(std.mem.indexOf(u8, bodies.items[4], "Flex container") != null);

    // Shutdown response.
    try testing.expect(std.mem.indexOf(u8, bodies.items[5], "\"id\":4") != null);
    try testing.expect(std.mem.indexOf(u8, bodies.items[5], "\"result\":null") != null);
}

test "analyze reports parser and validation findings with positions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(@as(?ui_markup.MarkupErrorInfo, null), analyze(arena, "<row><text>hi</text></row>"));

    const syntax = analyze(arena, "<row").?;
    try testing.expectEqualStrings("unterminated element tag", syntax.message);

    const unknown = analyze(arena, "<row>\n  <widget />\n</row>").?;
    try testing.expectEqualStrings("unknown element", unknown.message);
    try testing.expectEqual(@as(usize, 2), unknown.line);
    try testing.expectEqual(@as(usize, 3), unknown.column);
}

test "completionContext classifies positions" {
    try testing.expect(completionContext("<", 1) == .elements);
    try testing.expect(completionContext("<ro", 3) == .elements);
    try testing.expect(completionContext("</ro", 4) == .elements);
    try testing.expect(completionContext("hello", 3) == .none);
    try testing.expect(completionContext("<row>x", 6) == .none);

    const attrs = completionContext("<row ", 5);
    try testing.expectEqualStrings("row", attrs.attributes);
    const mid_attr = completionContext("<text-field placeholder=\"x\" gr", 30);
    try testing.expectEqualStrings("text-field", mid_attr.attributes);
    const for_attrs = completionContext("<for ", 5);
    try testing.expectEqualStrings("for", for_attrs.attributes);

    // Inside an attribute value string: no completions.
    try testing.expect(completionContext("<row gap=\"", 10) == .none);
}

test "hoverAt resolves element and attribute docs" {
    const source = "<row gap=\"4\"><button on-press=\"add\">Add</button></row>";
    const row = hoverAt(source, 2).?;
    try testing.expectEqualStrings("row", row.name);
    const gap = hoverAt(source, 5).?;
    try testing.expectEqualStrings("gap", gap.name);
    const on_press = hoverAt(source, 23).?;
    try testing.expectEqualStrings("on-press", on_press.name);
    // Text content has no hover; neither does a string value.
    try testing.expect(hoverAt(source, 37) == null);
    try testing.expect(hoverAt(source, 32) == null);
    // Closing tag name hovers like the opening one.
    const closing = hoverAt(source, 45).?;
    try testing.expectEqualStrings("button", closing.name);
}

test "doc tables cover every known element, attribute, and event" {
    for (ui_markup.known_element_names) |name| {
        try testing.expect(elementDoc(name) != null);
    }
    for ([_][]const u8{ "for", "if", "else" }) |name| {
        try testing.expect(elementDoc(name) != null);
    }
    for (ui_markup.known_option_attrs) |name| {
        try testing.expect(attributeDoc(name) != null);
    }
    for (ui_markup.known_events) |event| {
        var buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "on-{s}", .{event});
        try testing.expect(attributeDoc(name) != null);
    }
}
