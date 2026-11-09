//! Runtime markup facts and explicit native storage/callback capabilities.
const std = @import("std");
const markup = @import("ui_markup.zig");
const elements = @import("ui_markup_elements.zig");
const scratch = std.heap.page_allocator;
pub const Request = struct {
    inner: elements.Request,
    pub fn init(mode: u8) Request {
        var inner = elements.Request.init(mode);
        inner.bytes.items[0] = 114;
        return .{ .inner = inner };
    }
    pub fn deinit(self: *Request) void {
        self.inner.deinit();
    }
    pub fn word(self: *Request, value: usize) void {
        self.inner.word(value);
    }
    pub fn words(self: *Request, values: []const usize) void {
        self.inner.words(values);
    }
    pub fn blob(self: *Request, value: []const u8) void {
        self.inner.blob(value);
    }
    pub fn names(self: *Request, value: []const []const u8) void {
        self.inner.names(value);
    }
    pub fn node(self: *Request, value: markup.MarkupNode, children: bool) void {
        self.inner.node(value, children);
    }
    pub fn decision(self: *Request, owner: markup.expr.Policy) elements.Record {
        var result = self.program(owner) catch @panic("runtime markup transport allocation failed");
        defer result.deinit();
        const row = result.next() orelse @panic("missing runtime markup decision");
        if (result.next() != null) @panic("extra runtime markup decision");
        return row;
    }
    pub fn program(self: *Request, owner: markup.expr.Policy) error{OutOfMemory}!elements.Program {
        self.inner.bytes.items[3] = 0;
        var sizing: [16]u8 = undefined;
        if (owner(self.inner.bytes.items, &sizing) != sizing.len) @panic("invalid runtime markup sizing");
        const count = header(&sizing, 0);
        const size = std.math.add(usize, 16, std.math.mul(usize, count, 48) catch return error.OutOfMemory) catch return error.OutOfMemory;
        const out = try scratch.alloc(u8, size);
        errdefer scratch.free(out);
        self.inner.bytes.items[3] = 1;
        if (owner(self.inner.bytes.items, out) != size or header(out, 1) != count) @panic("invalid runtime markup program");
        return .{ .bytes = out };
    }
};
fn header(bytes: []const u8, phase: u8) usize {
    if (bytes.len < 16 or bytes[0] != 114 or bytes[1] != 1 or bytes[2] != phase) @panic("invalid runtime markup header");
    for (bytes[3..8]) |byte| if (byte != 0) @panic("invalid runtime markup reserved byte");
    return elements.number(bytes, 8);
}
pub fn decide(owner: markup.expr.Policy, mode: u8, facts: []const usize) elements.Record {
    var request = Request.init(mode);
    defer request.deinit();
    request.words(facts);
    return request.decision(owner);
}
pub fn message(code: u8) []const u8 {
    return switch (code) {
        1 => "key does not name a field on the item",
        2 => "key fields must be integers or strings",
        3 => markup.image_source_element_message,
        4 => markup.image_source_binding_message,
        5 => markup.image_source_complete_message,
        7 => "expected a number",
        8 => "text elements take a single run of text",
        9 => markup.span_text_only_message,
        10 => "text elements may only contain text",
        11 => "unterminated interpolation",
        else => @panic("invalid runtime markup diagnostic"),
    };
}
