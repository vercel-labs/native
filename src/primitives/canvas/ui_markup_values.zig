//! Copied markup value builder facts and explicit typed native capabilities.
const std = @import("std");
const markup = @import("ui_markup.zig");
const elements = @import("ui_markup_elements.zig");
const code_model = @import("code.zig");
const chart = @import("chart.zig");
const scratch = std.heap.page_allocator;
pub const Request = struct {
    inner: elements.Request,
    pub fn init(mode: u8) Request {
        var inner = elements.Request.init(mode);
        inner.bytes.items[0] = 113;
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
        var result = self.program(owner) catch @panic("markup value transport allocation failed");
        defer result.deinit();
        const row = result.next() orelse @panic("missing markup value decision");
        if (result.next() != null) @panic("extra markup value decision");
        return row;
    }
    pub fn program(self: *Request, owner: markup.expr.Policy) error{OutOfMemory}!elements.Program {
        self.inner.bytes.items[3] = 0;
        var sizing: [16]u8 = undefined;
        if (owner(self.inner.bytes.items, &sizing) != sizing.len) @panic("invalid markup value sizing");
        const count = header(&sizing, 0);
        const size = std.math.add(usize, 16, std.math.mul(usize, count, 48) catch return error.OutOfMemory) catch return error.OutOfMemory;
        const out = try scratch.alloc(u8, size);
        errdefer scratch.free(out);
        self.inner.bytes.items[3] = 1;
        if (owner(self.inner.bytes.items, out) != size or header(out, 1) != count) @panic("invalid markup value program");
        return .{ .bytes = out };
    }
};
fn header(bytes: []const u8, phase: u8) usize {
    if (bytes.len < 16 or bytes[0] != 113 or bytes[1] != 1 or bytes[2] != phase) @panic("invalid markup value header");
    for (bytes[3..8]) |byte| if (byte != 0) @panic("invalid markup value reserved byte");
    return elements.number(bytes, 8);
}
pub fn decide(owner: markup.expr.Policy, mode: u8, facts: []const usize) elements.Record {
    var request = Request.init(mode);
    defer request.deinit();
    request.words(facts);
    return request.decision(owner);
}
pub const BindingPath = struct { head: []const u8, tail: ?[]const u8 };
/// Borrowed offsets selected by the portable byte-path program.
pub fn bindingPath(owner: markup.expr.Policy, path: []const u8) BindingPath {
    var request = Request.init(35);
    defer request.deinit();
    request.blob(path);
    const row = request.decision(owner);
    if (row.action != 93 or row.fields[0] > path.len or row.fields[1] > path.len) @panic("invalid binding path capability");
    return .{ .head = path[0..row.fields[0]], .tail = if (row.fields[1] == 0) null else path[row.fields[1]..] };
}
/// Literal precedence is portable; native conversion retains exact i64/f32
/// values and the original borrowed string. Neither number crosses the wire.
pub fn literal(owner: markup.expr.Policy, raw: []const u8, attribute: ?[]const u8) markup.expr.Value {
    var request = Request.init(31);
    defer request.deinit();
    request.word(0);
    request.blob(raw);
    request.word(@intFromBool(attribute != null));
    request.blob(attribute orelse "");
    const text_names = comptime blk: {
        var count: usize = 0;
        for (markup.schema.attrs) |info| if (info.class == .text) {
            count += 1;
        };
        var names: [count][]const u8 = undefined;
        var index: usize = 0;
        for (markup.schema.attrs) |info| if (info.class == .text) {
            names[index] = info.name;
            index += 1;
        };
        break :blk names;
    };
    request.names(&text_names);
    var row = request.decision(owner);
    var integer: ?i64 = null;
    var float: ?f32 = null;
    var phase: u8 = 0;
    while (true) switch (row.action) {
        81 => return .{ .string = raw },
        82 => {
            if (phase != 0 or row.code > 1) @panic("invalid literal boolean capability");
            return .{ .boolean = row.code == 1 };
        },
        83 => {
            if (phase != 0) @panic("invalid literal integer parse capability");
            integer = std.fmt.parseInt(i64, raw, 10) catch null;
            phase = 1;
            row = decide(owner, 31, &.{ phase, @intFromBool(integer != null) });
        },
        84 => {
            if (phase != 1) @panic("invalid literal integer publication");
            return .{ .integer = integer orelse @panic("missing literal integer") };
        },
        85 => {
            if (phase != 1) @panic("invalid literal float parse capability");
            float = std.fmt.parseFloat(f32, raw) catch null;
            phase = 2;
            row = decide(owner, 31, &.{ phase, @intFromBool(float != null) });
        },
        86 => {
            if (phase != 2) @panic("invalid literal float publication");
            return .{ .float = float orelse @panic("missing literal float") };
        },
        else => @panic("invalid literal inference capability"),
    };
}
/// Transport the actual classified form, including cached forms, and payload size.
pub fn specializedForm(owner: markup.expr.Policy, channel: u8, typed: markup.TypedAttrValue) elements.Record {
    const form: usize = switch (typed) {
        .literal => 0,
        .binding => 1,
        .equals => 2,
        .expression => 3,
        .message => 4,
        .invalid => 5,
    };
    return decide(owner, 27, &.{ channel, form, if (typed == .message) typed.message.payload.len else 0 });
}
pub fn specializedValue(owner: markup.expr.Policy, channel: u8, value: markup.expr.Value) elements.Record {
    return decide(owner, 28, &.{ channel, kind(value), if (value == .string) value.string.len else 0 });
}
pub fn iconValue(owner: markup.expr.Policy, raw: []const u8, base_message: []const u8) markup.IconValue {
    var request = Request.init(14);
    defer request.deinit();
    request.blob(raw);
    request.names(&markup.known_icon_names);
    const row = request.decision(owner);
    return switch (row.action) {
        72 => if (row.code == 0) .{ .builtin = raw } else if (row.code == 1) .{ .app = raw } else @panic("invalid icon kind"),
        73 => .{ .binding = raw },
        255 => .{ .invalid = if (row.code == 42) base_message else message(row.code) },
        else => @panic("invalid icon capability"),
    };
}
pub fn language(owner: markup.expr.Policy, raw: []const u8) ?code_model.Language {
    var request = Request.init(16);
    defer request.deinit();
    request.blob(raw);
    const fields = @typeInfo(code_model.Language).@"enum".fields;
    request.word(fields.len);
    inline for (fields) |field| request.blob(field.name);
    const row = request.decision(owner);
    if (row.action == 255 and row.code == 45) return null;
    if (row.action != 76 or row.fields[0] >= fields.len) @panic("invalid code language capability");
    inline for (fields, 0..) |field, i| if (row.fields[0] == i) return @enumFromInt(field.value);
    unreachable;
}
pub const SeriesKind = struct { kind: chart.ChartSeriesKind, fill: bool };
pub fn seriesKind(owner: markup.expr.Policy, raw: []const u8) ?SeriesKind {
    var request = Request.init(19);
    defer request.deinit();
    request.blob(raw);
    const fields = @typeInfo(chart.ChartSeriesKind).@"enum".fields;
    request.word(fields.len);
    inline for (fields) |field| request.blob(field.name);
    const row = request.decision(owner);
    if (row.action == 255 and row.code == 47) return null;
    if (row.action != 79 or row.code > 1) @panic("invalid chart kind capability");
    inline for (fields, 0..) |field, i| if (row.fields[0] == i) return .{ .kind = @enumFromInt(field.value), .fill = row.code == 1 };
    @panic("invalid chart kind field index");
}
pub fn spanScale(owner: markup.expr.Policy, multiplier: f32) bool {
    const row = decide(owner, 20, &.{@as(u32, @bitCast(multiplier))});
    if (row.action == 255 and row.code == 48) return false;
    if (row.action != 1) @panic("invalid span scale capability");
    return true;
}
pub fn integerOption(owner: markup.expr.Policy, channel: u8, value: markup.expr.Value, capacity: u8) elements.Record {
    const bits: u64 = if (value == .integer) @bitCast(value.integer) else 0;
    return decide(owner, 21, &.{ channel, kind(value), @as(u32, @truncate(bits)), @as(u32, @truncate(bits >> 32)), capacity });
}
pub fn virtualExtent(owner: markup.expr.Policy, value: f32) bool {
    const row = decide(owner, 22, &.{@as(u32, @bitCast(value))});
    if (row.action == 255 and row.code == 51) return false;
    if (row.action != 1) @panic("invalid virtual extent capability");
    return true;
}
pub fn virtualAnchor(comptime T: type, owner: markup.expr.Policy, raw: []const u8) T {
    var request = Request.init(23);
    defer request.deinit();
    request.blob(raw);
    const fields = @typeInfo(T).@"enum".fields;
    request.word(fields.len);
    inline for (fields) |field| request.blob(field.name);
    const row = request.decision(owner);
    if (row.action != 80) @panic("invalid virtual anchor capability");
    inline for (fields, 0..) |field, i| if (row.fields[0] == i) return @enumFromInt(field.value);
    @panic("invalid virtual anchor index");
}
fn virtualAdmission(row: elements.Record) ?[]const u8 {
    return switch (row.action) {
        0 => null,
        255 => message(row.code),
        else => @panic("invalid virtual admission capability"),
    };
}
pub fn virtualRange(owner: markup.expr.Policy, base: usize, count: usize) ?[]const u8 {
    return virtualAdmission(decide(owner, 24, &.{ base, count }));
}
pub fn virtualExtentRequired(owner: markup.expr.Policy, extent: f32, estimator: bool) ?[]const u8 {
    return virtualAdmission(decide(owner, 25, &.{ @as(u32, @bitCast(extent)), @intFromBool(estimator) }));
}
pub fn virtualAttribute(owner: markup.expr.Policy, channel: u8, name: []const u8, present: bool) elements.Record {
    var request = Request.init(26);
    defer request.deinit();
    request.word(channel);
    request.blob(name);
    request.word(@intFromBool(present));
    return request.decision(owner);
}
pub fn lineNumbers(owner: markup.expr.Policy, raw: []const u8, storage: *[code_model.max_diff_lines]usize) ?[]const usize {
    var request = Request.init(17);
    defer request.deinit();
    request.blob(raw);
    var pieces = request.program(owner) catch @panic("code line transport allocation failed");
    defer pieces.deinit();
    var len: usize = 0;
    while (pieces.next()) |piece| switch (piece.action) {
        77 => {
            const f = piece.fields;
            if (f[0] > f[1] or f[1] > raw.len or f[2] > f[3] or f[3] > raw.len) @panic("invalid code line span");
            const first = std.fmt.parseInt(usize, raw[f[0]..f[1]], 10) catch null;
            // Preserve conversion order and transport no inexact native integers.
            const last = if (first != null) std.fmt.parseInt(usize, raw[f[2]..f[3]], 10) catch null else null;
            var range = Request.init(18);
            defer range.deinit();
            for ([_]?usize{ first, last }) |value| {
                const within = if (value) |number| number <= storage.len else false;
                range.words(&.{ @intFromBool(value != null), @intFromBool(within), if (within) value.? else 0 });
            }
            range.words(&.{ storage.len, len });
            range.words(storage[0..len]);
            var writes = range.program(owner) catch @panic("code line transport allocation failed");
            defer writes.deinit();
            while (writes.next()) |write| switch (write.action) {
                78 => {
                    if (write.fields[0] != len or len >= storage.len or write.fields[1] == 0 or write.fields[1] > storage.len) @panic("invalid code line write");
                    storage[len] = write.fields[1];
                    len += 1;
                },
                255 => return null,
                else => @panic("invalid code line range capability"),
            };
        },
        200 => return storage[0..len],
        255 => return null,
        else => @panic("invalid code line piece capability"),
    };
    @panic("code line program did not publish");
}
pub fn kind(value: markup.expr.Value) usize {
    return switch (value) {
        .integer => 0,
        .float => 1,
        .boolean => 2,
        .string => 3,
    };
}
pub fn typeClass(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .float => 1,
        .bool => 2,
        .@"enum" => 3,
        .int => 4,
        .pointer => 5,
        else => 0,
    };
}
pub fn message(code: u8) []const u8 {
    return switch (code) {
        1 => markup.image_binding_element_message,
        2 => markup.image_binding_message,
        3 => markup.media_surface_surface_element_message,
        4 => markup.media_surface_surface_message,
        5 => markup.terminal_pty_element_message,
        6 => markup.terminal_pty_message,
        7 => markup.button_icon_element_message,
        8 => markup.anchor_element_message,
        9 => markup.quiet_hover_element_message,
        10 => markup.anchor_dependent_attr_message,
        11 => markup.anchor_value_message,
        12 => markup.anchor_alignment_value_message,
        13 => markup.anchor_offset_value_message,
        20 => "expected a number",
        21 => "expected an option name",
        22 => "unknown option value",
        23 => "expected a non-negative whole number",
        24 => "expected a whole number",
        25 => "attribute is not settable from markup",
        26 => "expected text",
        27 => "payload type does not match the message",
        28 => "message does not take a payload",
        29 => "message requires a payload",
        30 => "unknown message tag",
        31 => markup.on_drag_payload_message,
        32 => markup.invalid_expression_message,
        33 => markup.arena_scalar_equality_message,
        34 => "binding does not name a field on the loop item",
        35 => "loop items of this type cannot be used as values",
        36 => "slice-valued template args are only usable with for each",
        37 => "template arg values have no fields",
        38 => markup.binding_text_buffer_message,
        39 => "binding does not name a model field",
        40 => "unknown virtual range field",
        41 => "virtual window requires a range field",
        42 => markup.button_icon_message,
        43 => markup.app_icon_shape_message,
        44 => markup.icon_namespace_message,
        45 => markup.code_language_message,
        46 => markup.code_diff_lines_message,
        47 => markup.series_kind_message,
        48 => markup.span_scale_value_message,
        49 => "virtual window count requires a nonnegative safe integer",
        50 => "virtual window count requires an integer",
        51 => "virtual window extent requires a nonnegative finite f32",
        52 => markup.stepper_active_message,
        53 => "expected a whole number",
        54 => "expected a non-negative whole number",
        55 => "virtual window logical range exceeds safe integers",
        56 => "virtual-window requires an extent or estimate",
        57 => markup.markdown_source_message,
        58 => markup.markdown_on_link_message,
        59 => markup.markdown_on_details_message,
        60 => markup.markdown_details_expanded_message,
        61 => markup.markdown_images_message,
        62 => markup.markdown_issue_link_base_message,
        63 => markup.code_source_message,
        64 => "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")",
        65 => markup.chart_x_labels_message,
        66 => markup.series_values_message,
        67 => markup.series_color_message,
        68 => markup.slot_outside_template_message,
        else => @panic("invalid markup value diagnostic"),
    };
}

/// The compiled program selects whether a forwarded root handler replaces the local handler.
pub fn forwardedPress(owner: markup.expr.Policy, present: bool) bool {
    const row = decide(owner, 36, &.{@intFromBool(present)});
    return switch (row.action) {
        0 => false,
        1 => true,
        else => @panic("invalid forwarded press capability"),
    };
}
