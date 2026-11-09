//! Typed-document action transport and borrowed storage capabilities.
const std = @import("std");
const m = @import("ui_markup.zig");
const scratch = std.heap.page_allocator;

const Packet = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    fn word(self: *Packet, value: usize) !void {
        if (value > 9007199254740991) @panic("canonical integer exceeds exact transport range");
        var raw: [8]u8 = undefined;
        std.mem.writeInt(u64, &raw, @bitCast(@as(f64, @floatFromInt(value))), .little);
        try self.bytes.appendSlice(scratch, &raw);
    }
    fn blob(self: *Packet, bytes: []const u8) !void {
        try self.word(bytes.len);
        try self.bytes.appendSlice(scratch, bytes);
    }
    fn node(self: *Packet, value: m.MarkupNode) error{OutOfMemory}!void {
        try self.word(@intFromEnum(value.kind));
        try self.word(value.attrs.len);
        for (value.attrs) |attribute| {
            try self.blob(attribute.name);
            try self.blob(attribute.value);
        }
        try self.blob(value.text);
        try self.word(value.children.len);
        for (value.children) |child| try self.node(child);
    }
};
fn number(bytes: []const u8, at: usize) usize {
    const value: f64 = @bitCast(std.mem.readInt(u64, bytes[at..][0..8], .little));
    if (!std.math.isFinite(value) or value < 0 or value > 9007199254740991 or value != @trunc(value) or value >= @as(f64, @floatFromInt(std.math.maxInt(usize))))
        @panic("invalid compiled canonical integer");
    return @intFromFloat(value);
}

fn classify(owner: m.expr.Policy, name: []const u8, value: []const u8, channel: u8) m.TypedAttrValue {
    var request: Packet = .{};
    defer request.bytes.deinit(scratch);
    request.bytes.appendSlice(scratch, &.{ 109, 1, 1, channel }) catch @panic("attribute transport allocation failed");
    request.blob(name) catch @panic("attribute transport allocation failed");
    request.blob(value) catch @panic("attribute transport allocation failed");
    var out: [64]u8 = undefined;
    if (owner(request.bytes.items, &out) != out.len or out[0] != 109 or out[1] != 1 or out[2] != 1 or number(&out, 8) != 1)
        @panic("invalid compiled attribute classification");
    for (out[3..8]) |byte| if (byte != 0) @panic("invalid attribute reserved byte");
    var reader: Reader = .{ .owner = owner, .arena = scratch, .tape = out[16..] };
    const action = reader.next();
    const f = action.fields;
    if (action.action != 11 or f[0] != 0) @panic("invalid attribute action");
    return switch (action.code) {
        1 => .{ .literal = Reader.span(value, f[1], f[2]) },
        2 => .{ .binding = Reader.span(value, f[1], f[2]) },
        3 => .{ .equals = .{ .left = Reader.span(value, f[1], f[2]), .right = Reader.span(value, f[3], f[4]) } },
        4 => .{ .expression = .{ .inner = Reader.span(value, f[1], f[2]) } },
        5 => .{ .message = .{ .tag = Reader.span(value, f[1], f[2]), .payload = if (f[3] == f[4]) "" else Reader.span(value, f[3], f[4]) } },
        6 => .invalid,
        else => @panic("invalid attribute kind"),
    };
}

pub fn typedAttribute(owner: m.expr.Policy, input: m.MarkupAttr) m.TypedAttrValue {
    if (input.typed) |typed| return typed.*;
    return classify(owner, input.name, input.value, 2);
}

pub fn expression(owner: m.expr.Policy, value: []const u8) ?m.Expression {
    return switch (classify(owner, "", value, 1)) {
        .literal => |text| .{ .literal = text },
        .binding => |path| .{ .binding = path },
        .equals => |sides| .{ .equals = .{ .left = sides.left, .right = sides.right } },
        .expression => |form| .{ .expression = form.inner },
        .invalid => null,
        .message => @panic("message returned for raw expression"),
    };
}
pub fn canonicalize(owner: m.expr.Policy, arena: std.mem.Allocator, document: m.MarkupDocument) error{OutOfMemory}!m.MarkupDocument {
    var request: Packet = .{};
    defer request.bytes.deinit(scratch);
    try request.bytes.appendSlice(scratch, &.{ 109, 1, 0, 0 });
    try request.word(document.templates.len);
    try request.word(@intFromBool(document.root != null));
    for (document.templates) |node| try request.node(node);
    if (document.root) |node| try request.node(node);
    var header: [16]u8 = undefined;
    if (owner(request.bytes.items, &header) != 16 or header[0] != 109 or header[1] != 1 or header[2] != 0)
        @panic("invalid canonical sizing response");
    for (header[3..8]) |b| if (b != 0) @panic("invalid canonical sizing reserved bytes");
    const count = number(&header, 8);
    if (count == 0) @panic("empty canonical tape");
    const size = std.math.add(usize, 16, std.math.mul(usize, count, 48) catch return error.OutOfMemory) catch return error.OutOfMemory;
    const tape = try scratch.alloc(u8, size);
    defer scratch.free(tape);
    request.bytes.items[2] = 1;
    if (owner(request.bytes.items, tape) != size or tape[0] != 109 or tape[1] != 1 or tape[2] != 1 or number(tape, 8) != count)
        @panic("invalid canonical tape");
    for (tape[3..8]) |b| if (b != 0) @panic("invalid canonical tape reserved bytes");
    var reader: Reader = .{ .owner = owner, .arena = arena, .tape = tape[16..] };
    return reader.document(document);
}
const Record = struct { action: u8, code: u8, fields: [5]usize };
const Reader = struct {
    owner: m.expr.Policy,
    arena: std.mem.Allocator,
    tape: []const u8,
    cursor: usize = 0,

    fn next(self: *Reader) Record {
        if (self.cursor >= self.tape.len) @panic("truncated canonical tape");
        const raw = self.tape[self.cursor..][0..48];
        self.cursor += 48;
        for (raw[2..8]) |b| if (b != 0) @panic("invalid canonical record reserved bytes");
        var result: Record = .{ .action = raw[0], .code = raw[1], .fields = undefined };
        for (&result.fields, 0..) |*field, i| field.* = number(raw, 8 + i * 8);
        return result;
    }
    fn span(bytes: []const u8, start: usize, end: usize) []const u8 {
        if (start > end or end > bytes.len) @panic("invalid compiled canonical span");
        return bytes[start..end];
    }
    fn parsedTree(self: *Reader, inner: []const u8) !?*const m.expr.ExprTree {
        const tree = try self.arena.create(m.expr.ExprTree);
        tree.* = .{};
        var diagnostic: m.expr.Diagnostic = .{};
        if (!m.expr.parseWithPolicy(self.owner, inner, tree, &diagnostic)) return null;
        return tree;
    }
    fn document(self: *Reader, input: m.MarkupDocument) error{OutOfMemory}!m.MarkupDocument {
        var out = input;
        var templates: []m.MarkupNode = &.{};
        var next_template: usize = 0;
        var root_stored = false;
        while (true) {
            const action = self.next();
            switch (action.action) {
                1 => {
                    if (templates.len != 0 or action.fields[0] == 0 or action.fields[0] != input.templates.len) @panic("invalid canonical templates allocation");
                    templates = try self.arena.alloc(m.MarkupNode, action.fields[0]);
                    out.templates = templates;
                },
                2 => {
                    if (action.fields[0] != next_template or next_template >= templates.len) @panic("invalid canonical template selection");
                    templates[next_template] = try self.node(input.templates[next_template]);
                    next_template += 1;
                },
                3 => {
                    if (root_stored or next_template != templates.len) @panic("invalid canonical root selection");
                    out.root = try self.node(input.root orelse @panic("missing canonical root"));
                    root_stored = true;
                },
                4 => {
                    if (self.cursor != self.tape.len or next_template != input.templates.len or root_stored != (input.root != null)) @panic("incomplete canonical document");
                    return out;
                },
                else => @panic("invalid canonical document action"),
            }
        }
    }
    fn node(self: *Reader, input: m.MarkupNode) error{OutOfMemory}!m.MarkupNode {
        var out = input;
        var attrs: []m.MarkupAttr = &.{};
        var children: []m.MarkupNode = &.{};
        var segments: std.ArrayListUnmanaged(m.TypedTextSegment) = .empty;
        var next_attr: usize = 0;
        var next_child: usize = 0;
        var text_open = false;
        while (true) {
            const action = self.next();
            const f = action.fields;
            switch (action.action) {
                10 => {
                    if (attrs.len != 0 or f[0] == 0 or f[0] != input.attrs.len) @panic("invalid canonical attributes allocation");
                    attrs = try self.arena.alloc(m.MarkupAttr, f[0]);
                    out.attrs = attrs;
                },
                11 => {
                    if (f[0] != next_attr or next_attr >= attrs.len) @panic("invalid canonical attribute selection");
                    const attribute = input.attrs[next_attr];
                    attrs[next_attr] = attribute;
                    const slot = try self.arena.create(m.TypedAttrValue);
                    slot.* = switch (action.code) {
                        1 => .{ .literal = span(attribute.value, f[1], f[2]) },
                        2 => .{ .binding = span(attribute.value, f[1], f[2]) },
                        3 => .{ .equals = .{ .left = span(attribute.value, f[1], f[2]), .right = span(attribute.value, f[3], f[4]) } },
                        4 => blk: {
                            const inner = span(attribute.value, f[1], f[2]);
                            break :blk .{ .expression = .{ .inner = inner, .tree = try self.parsedTree(inner) } };
                        },
                        5 => .{ .message = .{ .tag = span(attribute.value, f[1], f[2]), .payload = if (f[3] == f[4]) "" else span(attribute.value, f[3], f[4]) } },
                        6 => .invalid,
                        else => @panic("invalid compiled attribute kind"),
                    };
                    attrs[next_attr].typed = slot;
                    next_attr += 1;
                },
                12 => {
                    if (text_open) @panic("duplicate canonical text open");
                    text_open = true;
                },
                13 => {
                    if (!text_open) @panic("canonical segment outside text");
                    const segment: m.TypedTextSegment = switch (action.code) {
                        1 => .{ .literal = span(input.text, f[0], f[1]) },
                        2 => .{ .binding = span(input.text, f[0], f[1]) },
                        3 => blk: {
                            const inner = span(input.text, f[0], f[1]);
                            break :blk .{ .expression = .{ .inner = inner, .tree = try self.parsedTree(inner) } };
                        },
                        4 => .unterminated,
                        else => @panic("invalid compiled text segment kind"),
                    };
                    try segments.append(self.arena, segment);
                },
                14 => {
                    if (!text_open) @panic("canonical text close without open");
                    out.typed_text = segments.items;
                    text_open = false;
                },
                15 => {
                    if (children.len != 0 or f[0] == 0 or f[0] != input.children.len) @panic("invalid canonical children allocation");
                    children = try self.arena.alloc(m.MarkupNode, f[0]);
                    out.children = children;
                },
                16 => {
                    if (f[0] != next_child or next_child >= children.len) @panic("invalid canonical child selection");
                    children[next_child] = try self.node(input.children[next_child]);
                    next_child += 1;
                },
                17 => {
                    if (text_open or next_attr != input.attrs.len or next_child != input.children.len) @panic("incomplete canonical node");
                    return out;
                },
                else => @panic("invalid canonical node action"),
            }
        }
    }
};
