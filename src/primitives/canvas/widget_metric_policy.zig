//! Copied metric plans; font and paragraph measurement are explicit capabilities.
const std = @import("std");
const geometry = @import("geometry");
const tokens_model = @import("tokens.zig");
const widgets = @import("widgets.zig");
const text = @import("text.zig");
const spans = @import("text_spans.zig");
pub const reference = @import("widget_metrics.zig");
pub const Operation = enum(u8) { button, body, label, badge, typography, line, wrap, gutter, aligned_frame, content_frame, height, button_icon, button_gap, badge_icon, badge_gap, row_icon, row_gap, row_height, button_inset, inset, alert_inset, tab_text, tab_height, tab_inset, tab_icon, tab_gap, tab_list, sized_density, sized_token, size_scale, density, density_scale, intrinsic };
fn word(b: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], value, .little);
}
fn read(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn float(b: []const u8, at: usize) f32 {
    return @bitCast(read(b, at));
}
pub const Result = struct {
    bytes: [32]u8,
    pub fn scalar(self: Result) f32 {
        return float(&self.bytes, 8);
    }
    pub fn size(self: Result) ?geometry.SizeF {
        return if (read(&self.bytes, 4) == 4) null else .init(float(&self.bytes, 12), float(&self.bytes, 16));
    }
    pub fn rect(self: Result) geometry.RectF {
        return .init(float(&self.bytes, 8), float(&self.bytes, 12), float(&self.bytes, 16), float(&self.bytes, 20));
    }
};
pub const Request = struct {
    bytes: [224]u8 = @splat(0),
    pub fn init(op: Operation, widget: widgets.Widget, tokens: tokens_model.DesignTokens, base: f32) Request {
        var self: Request = .{};
        self.bytes[0..9].* = .{ 32, 1, @intFromEnum(op), @import("render_plan_policy.zig").numericFlags(), @intFromEnum(widget.size), @intFromEnum(tokens.density), @intFromEnum(tokens.controls.tabs_indicator), @intFromEnum(widget.kind), @import("control_geometry_policy.zig").signalingFlags() };
        const flags: u32 = @as(u32, @intFromBool(widget.text.len > 0)) | (@as(u32, @intFromBool(widget.icon.len > 0)) << 1) | (@as(u32, @intFromBool(widget.spans.len > 0)) << 2) | (@as(u32, @intFromBool(widget.layout.zero_intrinsic)) << 3) | (@as(u32, @intFromBool(widget.hasCodeDiff())) << 4) | (@as(u32, @intFromBool(tokens.pixel_snap.geometry)) << 7);
        word(&self.bytes, 12, flags);
        self.put(16, base);
        inline for (.{ "body_size", "label_size", "button_size", "heading_size", "display_size", "title_size" }, 0..) |name, i| self.put(20 + i * 4, @field(tokens.typography, name));
        inline for (.{ "control_height_sm", "control_height", "control_height_lg", "button_inset_sm", "button_inset", "button_inset_lg", "button_label_sm_step", "button_label_lg_step", "button_icon_gap", "icon_text_step", "row_extent", "size_inset_step", "tabs_label_size_step", "tabs_trigger_height", "tabs_trigger_inset", "tabs_list_inset" }, 0..) |name, i| self.put(44 + i * 4, @field(tokens.metrics, name));
        inline for (.{ "sm", "md", "lg", "xs" }, 0..) |name, i| self.put(108 + i * 4, @field(tokens.spacing, name));
        self.put(124, tokens.pixel_snap.scale);
        self.frame(widget.frame);
        inline for (.{ "left", "right", "top", "bottom" }, 0..) |name, i| self.put(152 + i * 4, @field(widget.layout.padding, name));
        word(&self.bytes, 176, widget.codeLineNumberDigits());
        word(&self.bytes, 180, std.math.cast(u32, widget.children.len) orelse @panic("widget metric child count exceeds wire range"));
        self.put(188, widget.layout.min_size.width);
        self.put(192, widget.layout.min_size.height);
        self.put(196, widget.layout.gap);
        return self;
    }
    pub fn put(self: *Request, at: usize, value: f32) void {
        word(&self.bytes, at, @bitCast(value));
    }
    pub fn frame(self: *Request, value: geometry.RectF) void {
        inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| self.put(128 + i * 4, @field(value, name));
    }
    pub fn run(self_: Request, widget: widgets.Widget, tokens: tokens_model.DesignTokens) Result {
        var self = self_;
        const policy = tokens.control_geometry_policy orelse @panic("missing widget metric owner");
        for (0..3) |_| {
            var copied: Result = .{ .bytes = @splat(0xa5) };
            if (policy(&self.bytes, &copied.bytes) != copied.bytes.len or read(&copied.bytes, 0) != 1) @panic("invalid compiled widget metric length");
            const mode = read(&copied.bytes, 4);
            const ranges: []const [2]usize = switch (mode) {
                1 => &.{.{ 12, 32 }},
                2 => &.{ .{ 8, 12 }, .{ 20, 32 } },
                3 => &.{ .{ 8, 12 }, .{ 16, 20 } },
                4 => &.{.{ 8, 32 }},
                5 => &.{.{ 24, 32 }},
                else => @panic("invalid compiled widget metric presence"),
            };
            for (ranges) |range| if (!std.mem.allEqual(u8, copied.bytes[range[0]..range[1]], 0)) @panic("invalid compiled absent widget metric fields");
            const op: Operation = @enumFromInt(self.bytes[2]);
            if (mode != 3) {
                const expected: u32 = switch (op) {
                    .intrinsic => if (mode == 4) 4 else 2,
                    .aligned_frame, .content_frame => 5,
                    else => 1,
                };
                if (mode != expected) @panic("invalid compiled widget metric operation result");
                return copied;
            }
            const capability = read(&copied.bytes, 20);
            const count = read(&copied.bytes, 28);
            const size = float(&copied.bytes, 24);
            const flags = read(&self.bytes, 12);
            if (capability != 3 and !std.mem.allEqual(u8, copied.bytes[12..16], 0)) @panic("invalid absent measurement width");
            if (capability > 4 or (capability != 4 and count != 0) or (capability == 4 and (count == 0 or count > 20))) @panic("invalid widget measurement descriptor");
            if (capability == 3) {
                if ((op != .aligned_frame and op != .content_frame) or flags & 64 != 0) @panic("invalid widget paragraph continuation");
                var runs: [spans.max_text_span_runs_per_paragraph]spans.TextSpanRun = undefined;
                const laid = spans.layoutTextSpans(widget.spans, .{ .size = size, .max_width = float(&copied.bytes, 12), .wrap = if (widget.text_no_wrap) .none else .word, .alignment = widget.text_alignment, .typography = tokens.typography, .measure = tokens.text_measure, .text_run_policy = tokens.text_run_policy }, &runs);
                self.put(148, laid.size.height);
                word(&self.bytes, 12, flags | 64);
            } else {
                if (flags & 32 != 0 or (op != .intrinsic and op != .gutter and op != .content_frame) or (capability != 4 and op != .intrinsic)) @panic("invalid widget font continuation");
                if (capability == 2) {
                    self.put(144, spans.textSpansIntrinsicWidth(widget.spans, .{ .size = size, .max_width = 0, .wrap = if (widget.text_no_wrap) .none else .word, .alignment = widget.text_alignment, .typography = tokens.typography, .measure = tokens.text_measure, .text_run_policy = tokens.text_run_policy }));
                    self.put(172, spans.textSpansMaxScale(widget.spans));
                    self.put(168, @import("widget_metrics.zig").widgetCodeLineNumberGutterWidth(widget, tokens));
                } else {
                    const zeros: [20]u8 = @splat('0');
                    const font = if (capability == 1) tokens.typography.buttonFontId() else if (capability == 4) tokens.typography.mono_font_id else tokens.typography.font_id;
                    self.put(144, text.measureTextWidthForFontWithPolicy(tokens.text_measure, tokens.text_run_policy, font, if (capability == 4) zeros[0..count] else widget.text, size));
                }
                word(&self.bytes, 12, flags | 32);
            }
        }
        @panic("incomplete widget metric measurement");
    }
};
pub fn scalar(op: Operation, widget: widgets.Widget, tokens: tokens_model.DesignTokens, base: f32) f32 {
    return Request.init(op, widget, tokens, base).run(widget, tokens).scalar();
}
pub fn frame(op: Operation, widget: widgets.Widget, tokens: tokens_model.DesignTokens, value: geometry.RectF) geometry.RectF {
    if (op == .content_frame) std.debug.assert(!value.hasNegativeSize());
    var request = Request.init(op, widget, tokens, 0);
    request.frame(value);
    return request.run(widget, tokens).rect();
}
pub fn intrinsic(widget: widgets.Widget, tokens: tokens_model.DesignTokens) ?geometry.SizeF {
    var request = Request.init(.intrinsic, widget, tokens, 0);
    if (widget.kind == .separator) request.put(184, @import("widget_render_style.zig").controlStrokeWidth(widget, @import("widget_render_style.zig").componentControlVisualTokens(widget, tokens), tokens.stroke.hairline));
    return request.run(widget, tokens).size();
}
