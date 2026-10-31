//! Copied specialized builder facts and explicit typed native capabilities.
const std = @import("std");
const markup = @import("ui_markup.zig");
const elements = @import("ui_markup_elements.zig");
const scratch = std.heap.page_allocator;
pub const Request = struct {
    inner: elements.Request,
    pub fn init(mode: u8) Request {
        var inner = elements.Request.init(mode);
        inner.bytes.items[0] = 112;
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
    pub fn node(self: *Request, value: markup.MarkupNode, children: bool) void {
        self.inner.node(value, children);
    }
    pub fn program(self: *Request, owner: markup.expr.Policy) error{OutOfMemory}!elements.Program {
        self.inner.bytes.items[3] = 0;
        var sizing: [16]u8 = undefined;
        if (owner(self.inner.bytes.items, &sizing) != sizing.len) @panic("invalid specialized sizing");
        const count = header(&sizing, 0);
        const size = std.math.add(usize, 16, std.math.mul(usize, count, 48) catch return error.OutOfMemory) catch return error.OutOfMemory;
        const out = try scratch.alloc(u8, size);
        errdefer scratch.free(out);
        self.inner.bytes.items[3] = 1;
        if (owner(self.inner.bytes.items, out) != size or header(out, 1) != count) @panic("invalid specialized program");
        return .{ .bytes = out };
    }
};
fn header(bytes: []const u8, phase: u8) usize {
    if (bytes.len < 16 or bytes[0] != 112 or bytes[1] != 1 or bytes[2] != phase) @panic("invalid specialized header");
    for (bytes[3..8]) |byte| if (byte != 0) @panic("invalid specialized reserved byte");
    return elements.number(bytes, 8);
}
pub fn check(owner: markup.expr.Policy, mode: u8, facts: []const usize) ?[]const u8 {
    var request = Request.init(mode);
    defer request.deinit();
    request.words(facts);
    var program = request.program(owner) catch @panic("specialized transport allocation failed");
    defer program.deinit();
    const result = program.next() orelse @panic("missing specialized admission");
    if (program.next() != null) @panic("extra specialized admission");
    return switch (result.action) {
        0 => null,
        255 => message(result.code),
        else => @panic("invalid specialized admission"),
    };
}
pub fn message(code: u8) []const u8 {
    return switch (code) {
        1 => markup.markdown_children_message,
        2 => markup.markdown_attr_message,
        3 => markup.markdown_source_message,
        4 => markup.code_children_message,
        5 => markup.code_attr_message,
        6 => markup.code_source_message,
        7 => markup.stepper_attr_message,
        8 => markup.stepper_active_message,
        9 => markup.input_group_attr_message,
        10 => markup.input_group_children_message,
        11 => markup.input_group_textarea_message,
        12 => markup.input_group_actions_attr_message,
        13 => markup.input_group_actions_children_message,
        14 => markup.timeline_attr_message,
        15 => markup.timeline_item_children_message,
        16 => markup.timeline_item_attr_message,
        17 => markup.timeline_item_title_message,
        18 => markup.chart_attr_message,
        19 => markup.chart_series_required_message,
        20 => markup.chart_children_message,
        21 => markup.video_children_message,
        22 => markup.video_attr_message,
        23 => markup.series_children_message,
        24 => markup.series_attr_message,
        25 => markup.series_values_message,
        26 => markup.span_paragraph_wrap_message,
        27 => markup.text_inline_children_message,
        28 => markup.stepper_children_message,
        29 => markup.step_attr_message,
        30 => "virtual-window declarations cannot nest",
        31 => "virtual-window requires one root child",
        32 => "virtual-window requires id",
        33 => "virtual-window requires as",
        34 => "too many virtual windows",
        35 => "duplicate virtual window identity",
        36 => "virtual-list requires window",
        37 => "virtual-list requires each",
        38 => "virtual-list requires as",
        39 => "virtual-list requires one keyed root per row",
        40 => "virtual-list query returned a different item count",
        41 => "virtual window logical range exceeds safe integers",
        42 => "virtual-window requires an extent or estimate",
        43 => "virtual window requires exactly one list",
        44 => "virtual-list requires an enclosing window",
        45 => "virtual window has more than one list",
        else => @panic("invalid specialized diagnostic"),
    };
}
