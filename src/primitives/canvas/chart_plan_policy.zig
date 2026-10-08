//! Copied chart continuations. Native supplies font measurements, palette facts,
//! drawing capabilities and owned buffers; portable decisions stay in the plan.
const std = @import("std");
const geometry = @import("geometry");
const widgets = @import("widgets.zig");
const tokens = @import("tokens.zig");
const drawing = @import("drawing.zig");
const text_spans = @import("text_spans.zig");
pub const Mode = enum(u8) { render, plot, hover_index, hover_detail, hover_draw };
pub const Action = enum(u32) { done, measure, fill_rect, fill_round, text, fill_path, stroke_path, shadow, stroke_rect };
pub const Detail = struct { index: usize, plot: geometry.RectF, sample_x: f32, card: geometry.RectF };
fn word(b: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, b[at..][0..4], std.math.cast(u32, value) orelse @panic("chart plan integer exceeds wire range"), .little);
}
fn read(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn put(b: []u8, at: usize, value: f32) void {
    std.mem.writeInt(u32, b[at..][0..4], @bitCast(value), .little);
}
fn get(b: []const u8, at: usize) f32 {
    return @bitCast(read(b, at));
}
fn putRect(b: []u8, at: usize, value: geometry.RectF) void {
    inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| put(b, at + i * 4, @field(value, name));
}
fn rect(b: []const u8, at: usize) geometry.RectF {
    return .init(get(b, at), get(b, at + 4), get(b, at + 8), get(b, at + 12));
}
fn putColor(b: []u8, at: usize, color: drawing.Color) void {
    inline for (.{ "r", "g", "b", "a" }, 0..) |name, i| put(b, at + i * 4, @field(color, name));
}
// A numerical ABI probe, like the existing extrema flags. The input is fixed
// and unrelated to a chart. OS math and the compiler runtime differ at a few
// float32 log boundaries; neither supplies framework or rendering decisions.
pub fn logarithmMode() u8 {
    var value: f32 = @bitCast(@as(u32, 507307245));
    std.mem.doNotOptimizeAway(&value);
    return @intFromBool(@floor(std.math.log10(value)) == -21);
}
pub const Plan = struct {
    bytes: []u8,
    output: []u8,
    length: usize = 0,
    widget: widgets.Widget,
    token: tokens.DesignTokens,
    saved_label: ?[]const u8 = null,
    pub fn init(widget: widgets.Widget, token: tokens.DesignTokens, mode: Mode, bounds: geometry.RectF, point: geometry.PointF, supplied_detail: ?Detail) Plan {
        var length: usize = 480;
        for (widget.chart.series) |row| {
            const samples = std.math.add(usize, row.values.len, row.low.len) catch @panic("chart source size overflow");
            const sample_bytes = std.math.mul(usize, samples, 4) catch @panic("chart source size overflow");
            const header_label = std.math.add(usize, 40, row.label.len) catch @panic("chart source size overflow");
            const row_bytes = std.math.add(usize, header_label, sample_bytes) catch @panic("chart source size overflow");
            length = std.math.add(usize, length, row_bytes) catch @panic("chart source size overflow");
        }
        for (widget.chart.x_labels) |label| {
            const label_bytes = std.math.add(usize, 4, label.len) catch @panic("chart source size overflow");
            length = std.math.add(usize, length, label_bytes) catch @panic("chart source size overflow");
        }
        const bytes = std.heap.page_allocator.alloc(u8, length) catch @panic("chart source allocation failed");
        @memset(bytes, 0);
        bytes[0..6].* = .{ 50, 1, @intFromEnum(mode), @import("render_plan_policy.zig").numericFlags(), logarithmMode(), @as(u8, @intFromBool(token.pixel_snap.geometry)) | (@as(u8, @intFromBool(token.pixel_snap.text)) << 1) };
        word(bytes, 8, widget.chart.series.len);
        word(bytes, 12, widget.chart.x_labels.len);
        std.mem.writeInt(u64, bytes[16..24], widget.id, .little);
        putRect(bytes, 24, widget.frame);
        inline for (.{ "top", "right", "bottom", "left" }, 0..) |name, i| put(bytes, 40 + i * 4, @field(widget.layout.padding, name));
        putRect(bytes, 56, bounds);
        for ([_]f32{ token.typography.label_size, token.stroke.hairline, widget.style.stroke_width orelse 0, token.radius.md, token.shadow.sm.y, token.shadow.sm.blur, token.shadow.sm.spread, token.pixel_snap.scale }, 0..) |value, i| put(bytes, 72 + i * 4, value);
        word(bytes, 104, @as(u32, @intFromBool(widget.chart.baseline)) | (@as(u32, @intFromBool(widget.chart.y_labels)) << 1) | (@as(u32, @intFromBool(widget.chart.hover_details)) << 2) | (@as(u32, @intFromBool(widget.chart.y_min != null)) << 3) | (@as(u32, @intFromBool(widget.chart.y_max != null)) << 4) | (@as(u32, @intFromBool(widget.style.stroke_width != null)) << 5) | (@as(u32, @intFromBool(widget.kind == .chart)) << 6));
        word(bytes, 108, widget.chart.grid_lines);
        put(bytes, 112, widget.chart.y_min orelse 0);
        put(bytes, 116, widget.chart.y_max orelse 0);
        if (supplied_detail) |d| {
            word(bytes, 120, d.index);
            putRect(bytes, 124, d.plot);
            put(bytes, 140, d.sample_x);
            putRect(bytes, 144, d.card);
        }
        for ([_]drawing.Color{ token.colors.border, token.colors.text_muted, token.colors.text, token.colors.surface, token.colors.shadow }, 0..) |color, i| putColor(bytes, 160 + i * 16, color);
        put(bytes, 420, point.x);
        put(bytes, 424, point.y);
        var at: usize = 480;
        for (widget.chart.series) |row| {
            word(bytes, at, switch (row.kind) {
                .line => 0,
                .bar => 1,
                .band => 2,
            });
            word(bytes, at + 4, @intFromBool(row.fill));
            word(bytes, at + 8, row.values.len);
            word(bytes, at + 12, row.low.len);
            word(bytes, at + 16, row.label.len);
            putColor(bytes, at + 24, text_spans.textSpanColorValue(token.colors, row.color));
            at += 40;
            @memcpy(bytes[at..][0..row.label.len], row.label);
            at += row.label.len;
            for (row.values) |value| {
                put(bytes, at, value);
                at += 4;
            }
            for (row.low) |value| {
                put(bytes, at, value);
                at += 4;
            }
        }
        for (widget.chart.x_labels) |label| {
            word(bytes, at, label.len);
            at += 4;
            @memcpy(bytes[at..][0..label.len], label);
            at += label.len;
        }
        std.debug.assert(at == length);
        const capacity = std.math.add(usize, 288, std.math.mul(usize, length, 7) catch @panic("chart result size overflow")) catch @panic("chart result size overflow");
        return .{ .bytes = bytes, .output = std.heap.page_allocator.alloc(u8, capacity) catch @panic("chart result allocation failed"), .widget = widget, .token = token };
    }
    pub fn deinit(self: Plan) void {
        std.heap.page_allocator.free(self.bytes);
        std.heap.page_allocator.free(self.output);
    }
    pub fn run(self: *Plan) Action {
        @memset(self.output, 0xa5);
        const policy = self.token.control_command_policy orelse @panic("missing chart plan owner");
        self.length = policy(self.bytes, self.output);
        if (self.length < 288 or self.length > self.output.len or read(self.output, 0) != 1 or read(self.output, 4) > @intFromEnum(Action.stroke_rect) or read(self.output, 8) > 1 or read(self.output, 12) != 0) @panic("invalid chart result header");
        const action: Action = @enumFromInt(read(self.output, 4));
        const payload_count = read(self.output, 252);
        const stride: usize = if (action == .fill_path or action == .stroke_path) 28 else 1;
        if (payload_count > (self.length - 288) / stride or self.length != 288 + @as(usize, payload_count) * stride or read(self.output, 256) > 5 or read(self.output, 268) > 1 or !std.mem.allEqual(u8, self.output[272..288], 0)) @panic("invalid chart result shape");
        if (action == .fill_path or action == .stroke_path) for (0..payload_count) |i| {
            const at = 288 + i * 28;
            if (read(self.output, at) > 2 or !std.mem.allEqual(u8, self.output[at + 12 ..][0..16], 0)) @panic("invalid chart path element");
        };
        @memcpy(self.bytes[240..416], self.output[16..192]);
        return action;
    }
    pub fn reply(self: *Plan, width: f32) void {
        put(self.bytes, 416, width);
    }
    pub fn admitted(self: Plan) bool {
        return read(self.output, 8) == 1;
    }
    pub fn scalar(self: Plan, at: usize) f32 {
        return get(self.output, at);
    }
    pub fn commandId(self: Plan) u64 {
        return std.mem.readInt(u64, self.output[192..200], .little);
    }
    pub fn commandRect(self: Plan) geometry.RectF {
        return rect(self.output, 200);
    }
    pub fn commandOrigin(self: Plan) geometry.PointF {
        return .init(get(self.output, 216), get(self.output, 220));
    }
    pub fn commandColor(self: Plan) drawing.Color {
        return .rgba(get(self.output, 236), get(self.output, 240), get(self.output, 244), get(self.output, 248));
    }
    pub fn count(self: Plan) usize {
        return read(self.output, 252);
    }
    pub fn allocateText(self: Plan) bool {
        return read(self.output, 268) != 0;
    }
    pub fn text(self: Plan) []const u8 {
        const row = read(self.output, 260);
        const ordinal = read(self.output, 264);
        return switch (read(self.output, 256)) {
            1 => if (ordinal < self.widget.chart.x_labels.len) self.widget.chart.x_labels[ordinal] else @panic("invalid chart label resource"),
            2 => if (row < self.widget.chart.series.len) self.widget.chart.series[row].label else @panic("invalid chart series resource"),
            3 => if (row < self.widget.chart.series.len) @tagName(self.widget.chart.series[row].kind) else @panic("invalid chart name resource"),
            4 => self.output[288..self.length],
            5 => self.saved_label orelse @panic("missing allocated chart label"),
            else => @panic("invalid chart text capability"),
        };
    }
    pub fn pathElement(self: Plan, ordinal: usize) drawing.PathElement {
        std.debug.assert(ordinal < self.count());
        const at = 288 + ordinal * 28;
        return .{ .verb = switch (read(self.output, at)) {
            0 => .move_to,
            1 => .line_to,
            2 => .close,
            else => unreachable,
        }, .points = .{ .init(get(self.output, at + 4), get(self.output, at + 8)), .zero(), .zero() } };
    }
    pub fn plot(self: Plan) geometry.RectF {
        return rect(self.output, 48);
    }
    pub fn index(self: Plan) usize {
        return read(self.output, 28);
    }
    pub fn detail(self: Plan) Detail {
        return .{ .index = self.index(), .plot = self.plot(), .sample_x = get(self.output, 108), .card = rect(self.output, 112) };
    }
};
