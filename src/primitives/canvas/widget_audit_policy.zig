//! Owned audit boundary. Only raw widget facts and native font/paragraph
//! measurements cross into the portable rule owner. Results are validated
//! completely before any caller storage is modified; no native fallback.
const std = @import("std");
const geometry = @import("geometry");
const widgets = @import("widgets.zig");
const events = @import("events.zig");
const tokens_model = @import("tokens.zig");
const metrics = @import("widget_metrics.zig");
const spans_model = @import("text_spans.zig");
const text_model = @import("text.zig");
const text_metrics = @import("text_metrics.zig");
const layout_model = @import("widget_layout.zig");
const layout_audit = @import("layout_audit.zig");
const a11y_audit = @import("a11y_audit.zig");
const runtime = @import("widget_runtime.zig");
pub const Policy = @import("surface_layout_policy.zig").Policy;
const header_size = 56;
const node_size = 128;
const finding_size = 24;
const missing = std.math.maxInt(u32);
const a11y_rules = [_]a11y_audit.A11yAuditRuleKind{ .missing_label, .focus_unreachable, .duplicate_sibling_label };
const layout_rules = [_]layout_audit.LayoutAuditRuleKind{ .text_overflow, .sibling_overlap, .container_escape, .hit_target };
const roles = [_]widgets.WidgetRole{ .none, .group, .text, .link, .image, .button, .textbox, .tooltip, .dialog, .menu, .menuitem, .list, .listitem, .row, .grid, .gridcell, .tab, .checkbox, .radio, .radiogroup, .switch_control, .slider, .progressbar, .chart, .tree, .treeitem, .separator };
const sizes = [_]widgets.WidgetSize{ .sm, .default, .lg, .icon, .heading, .display };
comptime {
    if (a11y_rules.len != @typeInfo(a11y_audit.A11yAuditRuleKind).@"enum".fields.len or layout_rules.len != @typeInfo(layout_audit.LayoutAuditRuleKind).@"enum".fields.len) @compileError("update widget audit rule codes");
    if (roles.len != @typeInfo(widgets.WidgetRole).@"enum".fields.len or sizes.len != @typeInfo(widgets.WidgetSize).@"enum".fields.len)
        @compileError("update widget audit wire codes");
}
fn code(comptime T: type, values: []const T, value: T) u32 {
    for (values, 0..) |candidate, i| if (candidate == value) return @intCast(i);
    unreachable;
}
fn word(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn float(bytes: []u8, at: usize, value: f32) void {
    word(bytes, at, @bitCast(value));
}
fn read(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn readFloat(bytes: []const u8, at: usize) f32 {
    return @bitCast(read(bytes, at));
}
fn wireCount(value: usize) !u32 {
    return std.math.cast(u32, value) orelse error.AuditCapacityExceeded;
}
fn add(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch error.AuditCapacityExceeded;
}
fn descendantsSize(widget: widgets.Widget, length: *usize, count: *usize) !void {
    for (widget.children) |child| {
        length.* = try add(length.*, try add(16, try add(child.semantics.label.len, child.text.len)));
        count.* = try add(count.*, 1);
        try descendantsSize(child, length, count);
    }
}
fn copyBytes(request: []u8, at: *usize, bytes: []const u8) void {
    @memcpy(request[at.*..][0..bytes.len], bytes);
    at.* += bytes.len;
}
fn writeDescendants(request: []u8, at: *usize, widget: widgets.Widget, parent: u32, ordinal: *u32) !void {
    for (widget.children) |child| {
        const index = ordinal.*;
        ordinal.* += 1;
        const bytes = request[at.*..][0..16];
        word(bytes, 0, parent);
        word(bytes, 4, @intFromBool(child.semantics.hidden));
        word(bytes, 8, try wireCount(child.semantics.label.len));
        word(bytes, 12, try wireCount(child.text.len));
        at.* += 16;
        copyBytes(request, at, child.semantics.label);
        copyBytes(request, at, child.text);
        try writeDescendants(request, at, child, index, ordinal);
    }
}
const Measurement = struct { width: f32 = 0, height: f32 = 0, available_width: f32 = 0, available_height: f32 = 0, lines: usize = 0 };
/// This is the font/layout capability: return measured extents, never an
/// overflow verdict. The portable owner applies elision, epsilon and rules.
fn measure(widget: widgets.Widget, raw_frame: geometry.RectF, tokens: tokens_model.DesignTokens) Measurement {
    const frame = raw_frame.normalized();
    if (widget.spans.len > 0 and (widget.kind == .text or widget.kind == .data_cell)) {
        var framed = widget;
        framed.frame = frame;
        const content = metrics.widgetTextSpanContentFrame(framed, tokens).normalized();
        var runs: [spans_model.max_text_span_runs_per_paragraph]spans_model.TextSpanRun = undefined;
        const paragraph = spans_model.layoutTextSpans(widget.spans, metrics.widgetTextSpanLayoutOptions(widget, tokens, content.width + layout_audit.layout_audit_wrap_slack), &runs);
        return .{ .width = paragraph.size.width, .height = paragraph.size.height, .available_width = content.width, .available_height = content.height, .lines = paragraph.line_count };
    }
    if (widget.text.len == 0) return .{};
    if (widget.kind != .text) return .{ .width = layout_model.intrinsicWidgetSize(widget, tokens).width, .lines = 1 };
    const text_size = metrics.widgetBodyTextSize(widget, tokens);
    const line_height = metrics.widgetLineHeightWithTokens(text_size, tokens);
    var measured = Measurement{};
    var start: usize = 0;
    while (start <= widget.text.len) {
        const end = text_model.nextTextLineEnd(widget.text, start, tokens.typography.font_id, text_size, .{
            .max_width = frame.width + layout_audit.layout_audit_wrap_slack,
            .line_height = line_height,
            .wrap = .none,
            .alignment = widget.text_alignment,
            .text_run_policy = tokens.text_run_policy,
            .measure = tokens.text_measure,
        });
        measured.lines += 1;
        measured.width = @max(measured.width, text_metrics.measureTextWidthForFontWithPolicy(tokens.text_measure, tokens.text_run_policy, tokens.typography.font_id, widget.text[start..end], text_size));
        if (end >= widget.text.len) break;
        start = end;
        if (start < widget.text.len and widget.text[start] == '\n') start += 1;
    }
    measured.height = @as(f32, @floatFromInt(measured.lines)) * line_height;
    return measured;
}
pub const Plan = struct {
    allocator: std.mem.Allocator,
    policy: Policy,
    request: []u8,
    result: []u8,
    family: u8,
    node_count: usize,
    capacity: usize,
    result_length: usize = 0,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, layout: runtime.WidgetLayoutTree, window: geometry.RectF, tokens: tokens_model.DesignTokens, family: u8, capacity: usize) !Plan {
        if (family > 1) return error.InvalidAuditFamily;
        const node_count = layout.nodes.len;
        var length = try add(header_size, std.math.mul(usize, node_count, node_size) catch return error.AuditCapacityExceeded);
        for (layout.nodes) |node| {
            length = try add(length, try add(node.widget.semantics.label.len, try add(node.widget.text.len, node.widget.placeholder.len)));
            if (family == 0) {
                var count: usize = 0;
                try descendantsSize(node.widget, &length, &count);
                _ = try wireCount(count);
            }
        }
        _ = try wireCount(node_count);
        // No arbitrary 64-finding cap: allocate up to the caller's capacity,
        // bounded only by the maximum number of rules this pass can emit.
        const inspected: usize = @min(node_count, layout_audit.max_layout_audit_nodes);
        const possible = if (family == 0) inspected * 3 else inspected * 3 + inspected * (inspected -| 1) / 2;
        const output_capacity = @min(capacity, possible);
        const request = try allocator.alloc(u8, length);
        errdefer allocator.free(request);
        const result = try allocator.alloc(u8, 16 + @max(output_capacity, if (family == 1) inspected else 0) * finding_size);
        errdefer allocator.free(result);
        @memset(request, 0);
        request[0..4].* = .{ 23, 1, family, @import("surface_layout_policy.zig").anchorFlags(0, false) >> 3 };
        word(request, 4, try wireCount(node_count));
        word(request, 8, try wireCount(output_capacity));
        for ([_]f32{ window.x, window.y, window.width, window.height, tokens_model.min_pointer_hit_target }, 0..) |value, i| float(request, 16 + i * 4, value);
        for ([_]i32{ tokens.layer.base, tokens.layer.floating, tokens.layer.overlay, tokens.layer.modal }, 0..) |value, i| word(request, 36 + i * 4, @bitCast(value));
        word(request, 52, switch (tokens.density) {
            .compact => 0,
            .regular => 1,
            .spacious => 2,
        });
        var at: usize = header_size;
        for (layout.nodes) |node| {
            const widget = node.widget;
            const bytes = request[at..][0..node_size];
            word(bytes, 0, if (node.parent_index) |p| try wireCount(p) else missing);
            word(bytes, 4, widgets.widgetKindCode(widget.kind));
            word(bytes, 8, code(widgets.WidgetRole, &roles, widget.semantics.role));
            const flags: u32 = @as(u32, if (widget.semantics.hidden) 1 else 0) | @as(u32, if (widget.layout.virtualized) 2 else 0) |
                @as(u32, if (widget.layout.anchor != null) 4 else 0) | @as(u32, if (widget.layout.clip_content) 8 else 0) |
                @as(u32, if (widget.scroll_axes.scrollsHorizontally()) 16 else 0) | @as(u32, if (widget.scroll_axes.scrollsVertically()) 32 else 0) |
                @as(u32, if (widget.state.disabled) 64 else 0) | @as(u32, if (widget.semantics.focusable) 128 else 0) |
                @as(u32, if (widget.semantics.actions.focus) 256 else 0) | @as(u32, if (widget.interaction_policy != null) 512 else 0) |
                @as(u32, if (widget.interaction_policy != null and events.defaultFocusable(widget)) 1024 else 0) | @as(u32, if (widget.layer != null) 2048 else 0);
            word(bytes, 12, flags);
            std.mem.writeInt(u64, bytes[16..24], widget.id, .little);
            float(bytes, 24, widget.opacity);
            float(bytes, 28, widget.value_x);
            for ([_]f32{ widget.transform.a, widget.transform.b, widget.transform.c, widget.transform.d, widget.transform.tx, widget.transform.ty, node.frame.x, node.frame.y, node.frame.width, node.frame.height }, 0..) |value, i| float(bytes, 32 + i * 4, value);
            word(bytes, 72, code(widgets.WidgetSize, &sizes, widget.size));
            word(bytes, 76, @intFromBool(widget.text_overflow == .clip));
            word(bytes, 80, try wireCount(widget.children.len));
            word(bytes, 84, try wireCount(widget.spans.len));
            word(bytes, 88, @bitCast(widget.layer orelse 0));
            word(bytes, 92, try wireCount(widget.semantics.label.len));
            word(bytes, 96, try wireCount(widget.text.len));
            word(bytes, 100, try wireCount(widget.placeholder.len));
            var descendant_length: usize = 0;
            var descendant_count: usize = 0;
            if (family == 0) try descendantsSize(widget, &descendant_length, &descendant_count);
            word(bytes, 104, try wireCount(descendant_count));
            at += node_size;
            copyBytes(request, &at, widget.semantics.label);
            copyBytes(request, &at, widget.text);
            copyBytes(request, &at, widget.placeholder);
            if (family == 0) {
                var ordinal: u32 = 0;
                try writeDescendants(request, &at, widget, missing, &ordinal);
            }
        }
        std.debug.assert(at == request.len);
        var plan = Plan{ .allocator = allocator, .policy = policy, .request = request, .result = result, .family = family, .node_count = node_count, .capacity = output_capacity };
        if (family == 1) try plan.fillMeasurements(layout, tokens);
        return plan;
    }
    pub fn deinit(self: Plan) void {
        self.allocator.free(self.result);
        self.allocator.free(self.request);
    }
    fn fillMeasurements(self: *Plan, layout: runtime.WidgetLayoutTree, tokens: tokens_model.DesignTokens) !void {
        self.request[3] |= 2;
        defer self.request[3] &= ~@as(u8, 2);
        @memset(self.result, 0xa5);
        const length = self.policy(self.request, self.result);
        const inspected: usize = @min(self.node_count, layout_audit.max_layout_audit_nodes);
        if (length < 16 or length > self.result.len or !std.mem.eql(u8, self.result[0..4], &.{ 1, 1, 2, 0 }) or read(self.result, 12) != 0) return error.InvalidAuditResult;
        const count = read(self.result, 4);
        if (count > inspected or read(self.result, 8) != count or length != 16 + @as(usize, count) * finding_size) return error.InvalidAuditResult;
        var previous: ?u32 = null;
        // Check the whole query list before executing any measurement.
        for (0..count) |i| {
            const bytes = self.result[16 + i * finding_size ..][0..finding_size];
            const mode = read(bytes, 0);
            const index = read(bytes, 4);
            if (mode > 2 or index >= inspected or (previous != null and index <= previous.?) or read(bytes, 8) != missing or read(bytes, 12) != 0 or read(bytes, 16) != 0 or read(bytes, 20) != 0) return error.InvalidAuditResult;
            const widget = layout.nodes[index].widget;
            if (mode == 0 and (widget.kind != .text or widget.spans.len != 0)) return error.InvalidAuditResult;
            if (mode == 1 and (widget.spans.len == 0 or (widget.kind != .text and widget.kind != .data_cell))) return error.InvalidAuditResult;
            if (mode == 2 and (widget.kind == .text or (widget.kind == .data_cell and widget.spans.len > 0))) return error.InvalidAuditResult;
            previous = index;
        }
        var offset: usize = header_size;
        var next_node: usize = 0;
        for (0..count) |i| {
            const index = read(self.result, 16 + i * finding_size + 4);
            while (next_node < index) : (next_node += 1) {
                const bytes = self.request[offset..][0..node_size];
                offset += node_size + read(bytes, 92) + read(bytes, 96) + read(bytes, 100);
            }
            const measured = measure(layout.nodes[index].widget, layout.nodes[index].frame, tokens);
            const bytes = self.request[offset..][0..node_size];
            for ([_]f32{ measured.width, measured.height, measured.available_width, measured.available_height }, 0..) |value, field| float(bytes, 108 + field * 4, value);
            word(bytes, 124, try wireCount(measured.lines));
        }
    }
    pub fn run(self: *Plan) !void {
        @memset(self.result, 0xa5);
        const length = self.policy(self.request, self.result);
        if (length < 16 or length > self.result.len or self.result[0] != 1 or self.result[1] != self.family or self.result[2] != 0 or self.result[3] != 0 or read(self.result, 12) != 0) return error.InvalidAuditResult;
        const count = read(self.result, 4);
        const total = read(self.result, 8);
        if (count > self.capacity or count != @min(total, self.capacity) or length != 16 + @as(usize, count) * finding_size) return error.InvalidAuditResult;
        const inspected: usize = @min(self.node_count, layout_audit.max_layout_audit_nodes);
        const possible = if (self.family == 0) inspected * 3 else inspected * 3 + inspected * (inspected -| 1) / 2;
        if (total > possible) return error.InvalidAuditResult;
        for (0..count) |i| {
            const bytes = self.result[16 + i * finding_size ..][0..finding_size];
            const rule = read(bytes, 0);
            const node = read(bytes, 4);
            const other = read(bytes, 8);
            if (rule > (if (self.family == 0) @as(u32, 2) else 3) or node >= inspected or (other != missing and other >= self.node_count)) return error.InvalidAuditResult;
            if (self.family == 0) {
                if (rule == 2 and other >= node) return error.InvalidAuditResult;
                if ((rule == 0 and other != missing) or (rule != 0 and other == missing) or read(bytes, 12) != 0 or read(bytes, 16) != 0 or read(bytes, 20) != 0) return error.InvalidAuditResult;
            } else {
                if ((rule == 0 or rule == 3) and other != missing) return error.InvalidAuditResult;
                if (rule == 1 and (other == missing or other >= node)) return error.InvalidAuditResult;
                const x = readFloat(bytes, 12);
                const y = readFloat(bytes, 16);
                if (std.math.isNan(x) or std.math.isNan(y) or x < 0 or y < 0 or (x <= 0 and y <= 0) or (rule != 0 and read(bytes, 20) != 0)) return error.InvalidAuditResult;
            }
        }
        self.result_length = length;
    }
};
pub fn auditA11y(allocator: std.mem.Allocator, policy: Policy, layout: runtime.WidgetLayoutTree, storage: []a11y_audit.A11yAuditFinding) !a11y_audit.A11yAuditIssues {
    var plan = try Plan.init(allocator, policy, layout, .{}, .{}, 0, storage.len);
    defer plan.deinit();
    try plan.run();
    const count = read(plan.result, 4);
    for (storage[0..count], 0..) |*finding, i| {
        const bytes = plan.result[16 + i * finding_size ..][0..finding_size];
        finding.* = .{ .rule = a11y_rules[read(bytes, 0)], .node_index = read(bytes, 4), .other_index = if (read(bytes, 8) == missing) null else read(bytes, 8) };
    }
    return .{ .findings = storage[0..count], .total = read(plan.result, 8) };
}
pub fn auditLayout(allocator: std.mem.Allocator, policy: Policy, layout: runtime.WidgetLayoutTree, window: geometry.RectF, tokens: tokens_model.DesignTokens, storage: []layout_audit.LayoutAuditFinding) !layout_audit.LayoutAuditIssues {
    var plan = try Plan.init(allocator, policy, layout, window, tokens, 1, storage.len);
    defer plan.deinit();
    try plan.run();
    const count = read(plan.result, 4);
    for (storage[0..count], 0..) |*finding, i| {
        const bytes = plan.result[16 + i * finding_size ..][0..finding_size];
        finding.* = .{ .rule = layout_rules[read(bytes, 0)], .node_index = read(bytes, 4), .other_index = if (read(bytes, 8) == missing) null else read(bytes, 8), .overrun_x = readFloat(bytes, 12), .overrun_y = readFloat(bytes, 16), .lines = read(bytes, 20) };
    }
    return .{ .findings = storage[0..count], .total = read(plan.result, 8) };
}
