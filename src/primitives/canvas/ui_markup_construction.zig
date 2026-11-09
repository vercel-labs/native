//! Copied construction facts and borrowed native storage capabilities.
const std = @import("std");
const m = @import("ui_markup.zig");
const scratch = std.heap.page_allocator;

pub const Record = struct { action: u8, code: u8, fields: [5]usize };
pub fn number(bytes: []const u8, at: usize) usize {
    if (bytes.len -| at < 8) @panic("short construction number");
    const n: f64 = @bitCast(std.mem.readInt(u64, bytes[at..][0..8], .little));
    if (!std.math.isFinite(n) or n < 0 or n > 9007199254740991 or n != @trunc(n) or n >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) @panic("invalid construction number");
    return @intFromFloat(n);
}
fn header(bytes: []const u8, mode: u8) usize {
    if (bytes.len < 16 or bytes[0] != 110 or bytes[1] != 1 or bytes[2] != mode) @panic("invalid construction response");
    for (bytes[3..8]) |b| if (b != 0) @panic("invalid construction reserved byte");
    return number(bytes, 8);
}
fn record(bytes: []const u8) Record {
    if (bytes.len != 48) @panic("invalid construction record");
    for (bytes[2..8]) |b| if (b != 0) @panic("invalid construction reserved byte");
    var out: Record = .{ .action = bytes[0], .code = bytes[1], .fields = undefined };
    for (&out.fields, 0..) |*field, i| field.* = number(bytes, 8 + i * 8);
    return out;
}
pub const Program = struct {
    bytes: []u8,
    at: usize = 16,
    pub fn deinit(self: *Program) void {
        scratch.free(self.bytes);
    }
    pub fn next(self: *Program) ?Record {
        if (self.at == self.bytes.len) return null;
        if (self.bytes.len - self.at < 48) @panic("truncated construction program");
        const out = record(self.bytes[self.at..][0..48]);
        self.at += 48;
        return out;
    }
};
pub const Request = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    nodes: std.ArrayListUnmanaged(m.MarkupNode) = .empty,
    pub fn init(mode: u8) Request {
        var out: Request = .{};
        out.bytes.appendSlice(scratch, &.{ 110, 1, mode, 1 }) catch @panic("construction transport allocation failed");
        return out;
    }
    pub fn deinit(self: *Request) void {
        self.bytes.deinit(scratch);
        self.nodes.deinit(scratch);
    }
    pub fn word(self: *Request, value: usize) void {
        if (value > 9007199254740991) @panic("construction word exceeds exact range");
        var raw: [8]u8 = undefined;
        std.mem.writeInt(u64, &raw, @bitCast(@as(f64, @floatFromInt(value))), .little);
        self.bytes.appendSlice(scratch, &raw) catch @panic("construction transport allocation failed");
    }
    pub fn words(self: *Request, values: []const usize) void {
        for (values) |value| self.word(value);
    }
    pub fn blob(self: *Request, value: []const u8) void {
        self.word(value.len);
        self.bytes.appendSlice(scratch, value) catch @panic("construction transport allocation failed");
    }
    pub fn node(self: *Request, value: m.MarkupNode, descend: bool) void {
        self.word(self.nodes.items.len);
        self.nodes.append(scratch, value) catch @panic("construction transport allocation failed");
        self.words(&.{ @intFromEnum(value.kind), value.attrs.len });
        for (value.attrs) |attr| {
            self.blob(attr.name);
            self.blob(attr.value);
        }
        self.word(if (descend) value.children.len else 0);
        if (descend) for (value.children) |child| self.node(child, child.kind != .use_block and child.kind != .slot_block);
    }
    pub fn useSite(self: *Request, value: m.MarkupNode) void {
        // Only the first child is a structural witness. Consumer content is
        // visited later under the captured scope, never in this preflight.
        self.word(self.nodes.items.len);
        self.nodes.append(scratch, value) catch @panic("construction transport allocation failed");
        self.words(&.{ @intFromEnum(value.kind), value.attrs.len });
        for (value.attrs) |attr| {
            self.blob(attr.name);
            self.blob(attr.value);
        }
        self.word(@intFromBool(value.children.len != 0));
        if (value.children.len != 0) self.node(value.children[0], false);
    }
    pub fn decision(self: *Request, owner: m.expr.Policy) Record {
        var out: [64]u8 = undefined;
        if (owner(self.bytes.items, &out) != out.len or header(&out, 1) != 1) @panic("invalid construction decision");
        return record(out[16..]);
    }
    pub fn program(self: *Request, owner: m.expr.Policy) error{OutOfMemory}!Program {
        self.bytes.items[3] = 0;
        var sizing: [16]u8 = undefined;
        if (owner(self.bytes.items, &sizing) != sizing.len) @panic("invalid construction sizing");
        const count = header(&sizing, 0);
        const size = std.math.add(usize, 16, std.math.mul(usize, count, 48) catch return error.OutOfMemory) catch return error.OutOfMemory;
        const out = try scratch.alloc(u8, size);
        errdefer scratch.free(out);
        self.bytes.items[3] = 1;
        if (owner(self.bytes.items, out) != size or header(out, 1) != count) @panic("invalid construction program");
        return .{ .bytes = out };
    }
};
pub fn decide(owner: m.expr.Policy, mode: u8, values: []const usize) Record {
    var request = Request.init(mode);
    defer request.deinit();
    request.words(values);
    return request.decision(owner);
}
pub fn message(code: u8) []const u8 {
    return switch (code) {
        1 => m.import_unresolved_message,
        2 => m.component_file_view_message,
        3 => m.template_top_level_message,
        4 => m.import_top_level_message,
        5 => m.slot_outside_template_message,
        6 => "text content is only allowed inside text-bearing elements",
        7 => "structure tags are only allowed inside an element",
        8 => "if requires a test attribute",
        9 => m.else_placement_message,
        10 => m.use_template_attr_message,
        11 => m.use_undefined_template_message,
        12 => m.use_earlier_template_message,
        13 => "template expansion nests too deeply",
        14 => m.template_one_child_message,
        15 => m.template_one_slot_message,
        16 => m.use_children_without_slot_message,
        17 => m.use_forwarded_event_message,
        18 => m.use_extra_arg_message,
        19 => "template args nest too deep",
        20 => m.template_default_literal_message,
        21 => m.template_default_quoted_message,
        22 => m.use_missing_arg_message,
        23 => m.slot_attrs_message,
        24 => m.slot_children_message,
        25 => "for requires an each attribute",
        26 => "for requires an as attribute",
        27 => "for nesting is too deep",
        28 => m.for_children_message,
        29 => m.invalid_expression_message,
        30 => "each does not name an iterable (a model slice, array, or fn - or a slice-valued template arg)",
        else => @panic("invalid construction diagnostic"),
    };
}
