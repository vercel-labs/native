//! Runtime grammar action transport. The compiled owner chooses syntax,
//! spans, positions, document order, inline separators and failure timing.
//! Native retains borrowed source slices and the original arena operations.
const std = @import("std");
const m = @import("ui_markup.zig");

pub fn parse(owner: m.expr.Policy, parser: *m.Parser) m.ParseError!m.MarkupDocument {
    // Scratch transport never consumes the document allocator: replay keeps
    // its original append/resize/alloc sequence, including on syntax failure.
    const scratch = std.heap.page_allocator;
    const request = try scratch.alloc(u8, std.math.add(usize, 32, parser.source.len) catch return error.OutOfMemory);
    defer scratch.free(request);
    @memset(request[0..32], 0);
    request[0] = 107;
    request[1] = 1;
    put(request, 8, parser.index);
    put(request, 16, parser.line);
    put(request, 24, parser.column);
    @memcpy(request[32..], parser.source);
    var header: [16]u8 = undefined;
    if (owner(request, &header) != 16 or header[0] != 107 or header[1] != 1 or header[2] != 0)
        @panic("invalid document sizing response");
    for (header[3..8]) |b| if (b != 0) @panic("invalid document sizing reserved bytes");
    const count = number(&header, 8);
    if (count == 0) @panic("empty compiled document tape");
    const size = std.math.add(usize, 16, std.math.mul(usize, count, 96) catch return error.OutOfMemory) catch return error.OutOfMemory;
    const tape = try scratch.alloc(u8, size);
    defer scratch.free(tape);
    request[2] = 1;
    if (owner(request, tape) != size or tape[0] != 107 or tape[1] != 1 or tape[2] != 1 or number(tape, 8) != count)
        @panic("invalid compiled document tape");
    for (tape[3..8]) |b| if (b != 0) @panic("invalid document tape reserved bytes");
    var reader: Reader = .{ .parser = parser, .tape = tape[16..] };
    return reader.document();
}

fn put(bytes: []u8, at: usize, value: usize) void {
    if (value > 9007199254740991) @panic("document position exceeds exact transport range");
    std.mem.writeInt(u64, bytes[at..][0..8], @bitCast(@as(f64, @floatFromInt(value))), .little);
}
fn number(bytes: []const u8, at: usize) usize {
    const value: f64 = @bitCast(std.mem.readInt(u64, bytes[at..][0..8], .little));
    if (!std.math.isFinite(value) or value < 0 or value > 9007199254740991 or value != @trunc(value) or value >= @as(f64, @floatFromInt(std.math.maxInt(usize))))
        @panic("invalid compiled document integer");
    return @intFromFloat(value);
}
const Record = struct {
    action: u8,
    code: u8,
    fields: [8]usize,
};
const Reader = struct {
    parser: *m.Parser,
    tape: []const u8,
    cursor: usize = 0,

    fn next(self: *Reader) m.ParseError!Record {
        if (self.cursor >= self.tape.len) @panic("truncated compiled document tape");
        const raw = self.tape[self.cursor..][0..96];
        self.cursor += 96;
        for (raw[2..8]) |b| if (b != 0) @panic("invalid document record reserved bytes");
        const index = number(raw, 8);
        const line = number(raw, 16);
        const column = number(raw, 24);
        if (index < self.parser.index or index > self.parser.source.len or line == 0 or column == 0)
            @panic("invalid compiled document cursor");
        self.parser.index = index;
        self.parser.line = line;
        self.parser.column = column;
        var record: Record = .{ .action = raw[0], .code = raw[1], .fields = undefined };
        for (&record.fields, 0..) |*field, i| field.* = number(raw, 32 + i * 8);
        if (record.action == 12) {
            if (record.fields[0] == 0 or record.fields[1] == 0) @panic("invalid document diagnostic position");
            self.parser.diagnostic = .{ .line = record.fields[0], .column = record.fields[1], .message = message(record.code) };
            return error.MarkupSyntax;
        }
        return record;
    }
    fn span(self: *Reader, start: usize, end: usize) []const u8 {
        if (start > end or end > self.parser.source.len) @panic("invalid compiled document span");
        return self.parser.source[start..end];
    }
    fn done(self: *Reader) void {
        if (self.cursor != self.tape.len) @panic("trailing compiled document actions");
    }
    fn document(self: *Reader) m.ParseError!m.MarkupDocument {
        var imports: std.ArrayListUnmanaged(m.MarkupNode) = .empty;
        var templates: std.ArrayListUnmanaged(m.MarkupNode) = .empty;
        while (true) {
            const first = try self.next();
            if (first.action == 11) {
                self.done();
                return .{ .imports = imports.items, .templates = templates.items, .source_bytes = self.parser.source.len };
            }
            const node = try self.element(first);
            const action = try self.next();
            switch (action.action) {
                8 => try imports.append(self.parser.arena, node),
                9 => try templates.append(self.parser.arena, node),
                10 => {
                    self.done();
                    return .{ .imports = imports.items, .templates = templates.items, .root = node, .source_bytes = self.parser.source.len };
                },
                else => @panic("invalid document storage action"),
            }
        }
    }
    fn element(self: *Reader, first: Record) m.ParseError!m.MarkupNode {
        if (first.action != 1 or first.code > @intFromEnum(m.MarkupNodeKind.slot_block)) @panic("invalid document element action");
        var attrs: std.ArrayListUnmanaged(m.MarkupAttr) = .empty;
        var header: Record = undefined;
        while (true) {
            const action = try self.next();
            if (action.action != 2) {
                header = action;
                break;
            }
            const f = action.fields;
            if (action.code > 1) @panic("invalid document attribute action");
            try attrs.append(self.parser.arena, .{
                .name = self.span(f[0], f[1]),
                .value = if (action.code == 0) "" else self.span(f[2], f[3]),
                .line = f[4],
                .column = f[5],
                .name_span = .{ .start = f[0], .end = f[1] },
                .value_span = .{ .start = f[2], .end = f[3] },
            });
        }
        var node: m.MarkupNode = .{
            .kind = @enumFromInt(first.code),
            .name = self.span(first.fields[3], first.fields[4]),
            .attrs = attrs.items,
            .line = first.fields[1],
            .column = first.fields[2],
            .span = .{ .start = first.fields[0], .end = self.parser.index },
        };
        if (header.action == 3) return node;
        if (header.action != 4) @panic("invalid document header action");
        var children: std.ArrayListUnmanaged(m.MarkupNode) = .empty;
        while (true) {
            const action = try self.next();
            if (action.action == 6) {
                node.children = children.items;
                const separators = action.fields[0];
                if (separators > 0) {
                    if (separators >= children.items.len) @panic("invalid document separator count");
                    const out = try self.parser.arena.alloc(m.MarkupNode, children.items.len + separators);
                    var copied: usize = 0;
                    for (0..separators) |i| {
                        const separator = try self.next();
                        const f = separator.fields;
                        if (separator.action != 7 or f[0] <= copied or f[0] >= children.items.len)
                            @panic("invalid document separator action");
                        @memcpy(out[copied + i .. f[0] + i], children.items[copied..f[0]]);
                        _ = self.span(f[1], f[2]);
                        out[f[0] + i] = .{ .kind = .text, .text = " ", .line = f[3], .column = f[4], .span = .{ .start = f[1], .end = f[2] } };
                        copied = f[0];
                    }
                    @memcpy(out[copied + separators ..], children.items[copied..]);
                    node.children = out;
                }
                node.span.end = self.parser.index;
                return node;
            }
            const child: m.MarkupNode = if (action.action == 5) .{
                .kind = .text,
                .text = self.span(action.fields[0], action.fields[1]),
                .line = action.fields[2],
                .column = action.fields[3],
                .span = .{ .start = action.fields[0], .end = action.fields[1] },
            } else try self.element(action);
            try children.append(self.parser.arena, child);
        }
    }
};

fn message(code: u8) []const u8 {
    return switch (code) {
        1 => m.empty_document_message,
        2 => "expected end of file after the root element",
        3 => "expected '<' to open an element",
        4 => "unterminated element tag",
        5 => "expected '>' after '/' in a self-closing tag",
        6 => "expected '>' to close the element tag",
        7 => "expected '>' in closing tag",
        8 => "expected a lowercase kebab-case name",
        9 => "expected '\"' to open an attribute value",
        10 => "attribute values may not contain newlines",
        11 => "unterminated attribute value",
        12 => "closing tag does not match the open element",
        13 => m.import_top_level_message,
        14 => m.max_templates_message,
        15 => "element was never closed",
        else => @panic("invalid compiled document diagnostic"),
    };
}
