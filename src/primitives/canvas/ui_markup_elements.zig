//! Copied element/schema facts and explicit native builder capabilities.
const std = @import("std");
const m = @import("ui_markup.zig");
const scratch = std.heap.page_allocator;

pub const Record = struct { action: u8, code: u8, fields: [5]usize };
pub fn number(bytes: []const u8, at: usize) usize {
    if (bytes.len -| at < 8) @panic("short element number");
    const n: f64 = @bitCast(std.mem.readInt(u64, bytes[at..][0..8], .little));
    if (!std.math.isFinite(n) or n < 0 or n > 9007199254740991 or n != @trunc(n) or n >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) @panic("invalid element number");
    return @intFromFloat(n);
}
fn header(bytes: []const u8, mode: u8) usize {
    if (bytes.len < 16 or bytes[0] != 111 or bytes[1] != 1 or bytes[2] != mode) @panic("invalid element response");
    for (bytes[3..8]) |b| if (b != 0) @panic("invalid element reserved byte");
    return number(bytes, 8);
}
fn record(bytes: []const u8) Record {
    if (bytes.len != 48) @panic("invalid element record");
    for (bytes[2..8]) |b| if (b != 0) @panic("invalid element reserved byte");
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
        if (self.bytes.len - self.at < 48) @panic("truncated element program");
        const out = record(self.bytes[self.at..][0..48]);
        self.at += 48;
        return out;
    }
};
pub const Request = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    pub fn init(mode: u8) Request {
        var out: Request = .{};
        out.bytes.appendSlice(scratch, &.{ 111, 1, mode, 1 }) catch @panic("element transport allocation failed");
        return out;
    }
    pub fn deinit(self: *Request) void {
        self.bytes.deinit(scratch);
    }
    pub fn word(self: *Request, value: usize) void {
        if (value > 9007199254740991) @panic("element word exceeds exact range");
        var raw: [8]u8 = undefined;
        std.mem.writeInt(u64, &raw, @bitCast(@as(f64, @floatFromInt(value))), .little);
        self.bytes.appendSlice(scratch, &raw) catch @panic("element transport allocation failed");
    }
    pub fn words(self: *Request, values: []const usize) void {
        for (values) |value| self.word(value);
    }
    pub fn blob(self: *Request, value: []const u8) void {
        self.word(value.len);
        self.bytes.appendSlice(scratch, value) catch @panic("element transport allocation failed");
    }
    pub fn names(self: *Request, values: []const []const u8) void {
        self.word(values.len);
        for (values) |value| self.blob(value);
    }
    pub fn node(self: *Request, value: m.MarkupNode, children: bool) void {
        self.blob(value.name);
        self.word(value.attrs.len);
        for (value.attrs) |attribute| {
            self.blob(attribute.name);
            self.blob(attribute.value);
            // Only cached storage metadata crosses this boundary. The
            // compiled owner derives raw and name-aware literal admission.
            self.word(if (attribute.typed) |typed| @as(usize, @intFromEnum(typed.*)) + 1 else 0);
        }
        self.word(if (children) value.children.len else 0);
        if (children) for (value.children) |child| {
            self.word(@intFromEnum(child.kind));
            self.blob(child.name);
            self.blob(child.text);
        };
    }
    pub fn decision(self: *Request, owner: m.expr.Policy) Record {
        var out: [64]u8 = undefined;
        if (owner(self.bytes.items, &out) != out.len or header(&out, 1) != 1) @panic("invalid element decision");
        return record(out[16..]);
    }
    pub fn program(self: *Request, owner: m.expr.Policy) error{OutOfMemory}!Program {
        self.bytes.items[3] = 0;
        var sizing: [16]u8 = undefined;
        if (owner(self.bytes.items, &sizing) != sizing.len) @panic("invalid element sizing");
        const count = header(&sizing, 0);
        const size = std.math.add(usize, 16, std.math.mul(usize, count, 48) catch return error.OutOfMemory) catch return error.OutOfMemory;
        const out = try scratch.alloc(u8, size);
        errdefer scratch.free(out);
        self.bytes.items[3] = 1;
        if (owner(self.bytes.items, out) != size or header(out, 1) != count) @panic("invalid element program");
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
        3 => m.step_parent_message,
        4 => m.series_parent_message,
        5 => m.context_menu_parent_message,
        6 => m.input_group_actions_parent_message,
        7 => m.span_parent_message,
        8 => m.reactions_parent_message,
        9 => "unknown element",
        10 => m.context_menu_single_message,
        11 => m.context_menu_host_message,
        12 => m.reactions_single_message,
        13 => m.bubble_text_attr_message,
        14 => m.non_hit_target_handler_message,
        15 => m.autofocus_element_message,
        16 => m.stack_container_gap_message,
        17 => m.wrap_element_message,
        18 => m.overflow_element_message,
        19 => m.submit_on_enter_element_message,
        20 => m.overflow_value_message,
        21 => m.text_size_element_message,
        22 => m.size_value_message,
        23 => m.split_children_message,
        24 => m.image_missing_image_message,
        25 => m.image_children_message,
        26 => m.terminal_missing_pty_message,
        27 => m.terminal_children_message,
        28 => m.a11y_unlabeled_radiogroup_message,
        29 => m.a11y_icon_only_message,
        30 => m.a11y_unlabeled_control_message,
        31 => m.a11y_unlabeled_editable_message,
        32 => m.a11y_unknown_role_message,
        33 => m.a11y_container_role_message,
        34 => m.icon_missing_name_message,
        35 => m.icon_children_message,
        36 => m.text_or_children_content_message,
        40 => m.image_source_element_message,
        41 => m.image_source_binding_message,
        42 => m.image_source_complete_message,
        43 => m.scrollback_element_message,
        44 => m.terminal_text_attr_message,
        45 => m.video_flag_element_message,
        46 => m.icon_name_element_message,
        47 => "unknown attribute for this element",
        48 => m.style_token_literal_message,
        50 => "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")",
        51 => m.on_scroll_element_message,
        52 => m.on_terminal_element_message,
        53 => m.on_terminal_payload_message,
        54 => m.on_resize_element_message,
        55 => m.on_dismiss_element_message,
        56 => m.on_reach_end_element_message,
        57 => "unknown event attribute",
        58 => "keys must be integers or strings",
        else => @panic("invalid element diagnostic"),
    };
}
