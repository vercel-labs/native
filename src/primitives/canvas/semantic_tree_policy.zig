const std = @import("std");
const geometry = @import("geometry");
const widgets = @import("widgets.zig");
const events = @import("events.zig");
const access = @import("widget_access.zig");
const tree = @import("widget_tree.zig");
const surface = @import("surface_layout_policy.zig");

// Stable semantic role codes, independent of enum declaration order.
const roles = [_]widgets.WidgetRole{ .none, .group, .text, .link, .image, .button, .textbox, .tooltip, .dialog, .menu, .menuitem, .list, .listitem, .row, .grid, .gridcell, .tab, .checkbox, .radio, .radiogroup, .switch_control, .slider, .progressbar, .chart, .tree, .treeitem, .separator };
comptime {
    if (roles.len != @typeInfo(widgets.WidgetRole).@"enum".fields.len) @compileError("update semantic role wire codes");
}
fn roleCode(role: widgets.WidgetRole) u32 {
    for (roles, 0..) |candidate, index| if (role == candidate) return @intCast(index);
    unreachable;
}

/// The adapter owns both byte buffers while compiled code reduces measured
/// tree facts. No callback collects an arena or retains native pointers.
pub const Plan = struct {
    allocator: std.mem.Allocator,
    policy: surface.Policy,
    request: []u8,
    result: []u8,
    pub fn init(allocator: std.mem.Allocator, policy: surface.Policy, layout: anytype, query: ?usize, capacity: usize, viewport: ?geometry.RectF, virtual_content_extent_fn: anytype, vertical_extent: bool) !Plan {
        const count = layout.nodes.len;
        const request = try allocator.alloc(u8, 16 + count * 128);
        errdefer allocator.free(request);
        const result = try allocator.alloc(u8, 16 + (if (query != null) @as(usize, 1) else count) * 144);
        @memset(request, 0);
        request[0] = 9;
        request[1] = if (query != null) 1 else 0;
        request[2] = surface.anchorFlags(0, false) >> 3;
        putWord(request, 4, std.math.cast(u32, count) orelse @panic("semantic tree exceeds wire count"));
        putWord(request, 8, @intCast(query orelse 0));
        putWord(request, 12, std.math.cast(u32, capacity) orelse std.math.maxInt(u32));
        for (layout.nodes, 0..) |node, i| {
            const widget = node.widget;
            // A metrics query emits only its target's semantic record. Other
            // nodes supply geometry and tree facts for the extent walk.
            const actions: @TypeOf(events.semanticActionsAndFocusable(widget)) = if (query == null or query == i)
                events.semanticActionsAndFocusable(widget)
            else
                .{ .actions = widgets.WidgetActions{}, .focusable = false };
            const bytes = request[16 + i * 128 ..][0..128];
            const bounds = if (query == i and viewport != null) viewport.? else node.frame.inset(widget.layout.padding).normalized();
            const chart_value: ?f32 = if (widget.chart.series.len > 0 and widget.chart.series[0].values.len > 0) widget.chart.series[0].values[widget.chart.series[0].values.len - 1] else null;
            const flags = @as(u32, if (widget.semantics.hidden) 1 else 0) | @as(u32, if (widget.id == 0) 2 else 0) |
                @as(u32, if (widget.layout.virtualized) 4 else 0) | @as(u32, if (widget.layout.anchor != null) 8 else 0) |
                @as(u32, if (widget.layout.clip_content) 16 else 0) | @as(u32, if (widget.scroll_axes.scrollsHorizontally()) 32 else 0) |
                @as(u32, if (widget.scroll_axes.scrollsVertically()) 64 else 0) | @as(u32, if (widget.kind == .accordion and tree.disclosureSettledOpen(layout, i)) 128 else 0) |
                @as(u32, if (widget.semantics.label.len > 0) 256 else 0) | @as(u32, if (widget.semantics.value != null) 512 else 0) |
                @as(u32, if (chart_value != null) 1024 else 0) | @as(u32, if (widget.semantics.list_item_index != null) 2048 else 0) |
                @as(u32, if (widget.semantics.list_item_count != null) 4096 else 0) | @as(u32, if (widget.semantics.focusable or widget.semantics.actions.focus) 8192 else 0) |
                @as(u32, if (actions.focusable) 16384 else 0);
            for ([_]u32{ widgets.widgetKindCode(widget.kind), roleCode(widget.semantics.role), @intCast(node.depth), if (node.parent_index) |p| (if (p < count) @as(u32, @intCast(p)) else std.math.maxInt(u32)) else std.math.maxInt(u32), flags, stateBits(widget.state), events.semanticActionBits(actions.actions), widget.semantics.list_item_count orelse 0, widget.semantics.list_item_index orelse 0 }, 0..) |value, field| putWord(bytes, field * 4, value);
            std.mem.writeInt(u64, bytes[36..44], widget.layout.columns, .little);
            std.mem.writeInt(u64, bytes[44..52], widget.children.len, .little);
            // A previously compiled virtual-flow operation supplies the
            // virtual extent. This plan's native buffers survive that call.
            const virtual_extent = if (!vertical_extent or !widget.layout.virtualized or (query != null and query != i)) 0 else if (comptime virtual_content_extent_fn == @import("widget_layout.zig").virtualWidgetScrollContentExtent)
                @import("widget_layout.zig").virtualWidgetScrollContentExtentWithTokens(widget, bounds.height, .{ .intrinsic_layout_policy = policy })
            else
                virtual_content_extent_fn(widget, bounds.height);
            const values = [_]f32{ node.frame.x, node.frame.y, node.frame.width, node.frame.height, bounds.x, bounds.y, bounds.width, bounds.height, widget.value, widget.value_x, widget.semantics.value orelse 0, chart_value orelse 0, virtual_extent };
            for (values, 0..) |value, field| putFloat(bytes, 52 + field * 4, value);
        }
        return .{ .allocator = allocator, .policy = policy, .request = request, .result = result };
    }
    pub fn deinit(self: Plan) void {
        self.allocator.free(self.result);
        self.allocator.free(self.request);
    }
    pub fn run(self: Plan) void {
        if (self.policy(self.request, self.result) != self.result.len or readWord(self.result, 0) > (self.result.len - 16) / 144 or readWord(self.result, 4) > 2) @panic("invalid compiled semantic tree result");
    }
    pub fn axis(self: Plan, horizontal: bool) events.WidgetScrollMetrics {
        return metric(self.result[16..][0..144], if (horizontal) 116 else 100);
    }
    pub fn scroll(self: Plan) @import("widget_semantics.zig").WidgetScrollSemantics {
        const bytes = self.result[16..][0..144];
        const primary = metric(bytes, 76);
        return .{ .metrics = primary, .value = if (primary.present) readFloat(bytes, 92) else null, .scrollable = readWord(bytes, 96) != 0 };
    }
    pub fn copy(self: Plan, layout: anytype, output: []events.WidgetSemanticsNode) @import("root.zig").Error![]const events.WidgetSemanticsNode {
        const count = readWord(self.result, 0);
        if (count > output.len) @panic("compiled semantics exceeded output capacity");
        for (output[0..count], 0..) |*target, i| {
            const bytes = self.result[16 + i * 144 ..][0..144];
            const source = readWord(bytes, 0);
            if (source >= layout.nodes.len or readWord(bytes, 8) >= roles.len) @panic("invalid compiled semantic source");
            const node = layout.nodes[source];
            const widget = node.widget;
            const fields = readWord(bytes, 12);
            const grid = readWord(bytes, 40);
            target.* = .{
                .id = widget.id,
                .role = roles[readWord(bytes, 8)],
                .label = if (fields & 1 != 0) widget.semantics.label else widget.text,
                .text_value = if (fields & 2 != 0) widget.text else "",
                .placeholder = if (fields & 4 != 0) widget.placeholder else "",
                .focusable = fields & 8 != 0,
                .value = if (fields & 16 != 0) readFloat(bytes, 24) else null,
                .state = stateFromBits(readWord(bytes, 16)),
                .actions = events.semanticActionsFromBits(@intCast(readWord(bytes, 20))),
                .grid_row_index = optionalInteger(bytes, grid & 1 != 0, 44),
                .grid_column_index = optionalInteger(bytes, grid & 2 != 0, 52),
                .grid_row_count = optionalInteger(bytes, grid & 4 != 0, 60),
                .grid_column_count = optionalInteger(bytes, grid & 8 != 0, 68),
                .list = .{ .present = readWord(bytes, 28) != 0, .item_index = readWord(bytes, 32), .item_count = readWord(bytes, 36) },
                .scroll = metric(bytes, 76),
                .bounds = node.frame,
                .parent_index = if (readWord(bytes, 4) == std.math.maxInt(u32)) null else readWord(bytes, 4),
                .text_selection = access.widgetTextSelectionRange(widget),
                .text_composition = access.widgetTextCompositionRange(widget),
            };
        }
        switch (readWord(self.result, 4)) {
            1 => return error.WidgetDepthExceeded,
            2 => return error.WidgetSemanticsListFull,
            else => return output[0..count],
        }
    }
};
const state_fields = [_][]const u8{ "hovered", "pressed", "focused", "disabled", "selected", "required", "read_only", "invalid" };
fn stateBits(state: widgets.WidgetState) u32 {
    var bits: u32 = 0;
    inline for (state_fields, 0..) |field, i| if (@field(state, field)) {
        bits |= @as(u32, 1) << @intCast(i);
    };
    if (state.expanded) |expanded| bits |= 256 | @as(u32, if (expanded) 512 else 0);
    return bits;
}
fn stateFromBits(bits: u32) widgets.WidgetState {
    var state = widgets.WidgetState{};
    inline for (state_fields, 0..) |field, i| @field(state, field) = bits & (@as(u32, 1) << @intCast(i)) != 0;
    state.expanded = if (bits & 256 != 0) bits & 512 != 0 else null;
    return state;
}
fn optionalInteger(bytes: []const u8, present: bool, at: usize) ?usize {
    return if (present) std.math.cast(usize, std.mem.readInt(u64, bytes[at..][0..8], .little)) orelse @panic("semantic integer exceeds native width") else null;
}
fn metric(bytes: []const u8, at: usize) events.WidgetScrollMetrics {
    return .{ .present = readWord(bytes, at) != 0, .offset = readFloat(bytes, at + 4), .viewport_extent = readFloat(bytes, at + 8), .content_extent = readFloat(bytes, at + 12) };
}
fn putWord(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn readWord(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn putFloat(bytes: []u8, at: usize, value: f32) void {
    putWord(bytes, at, @bitCast(value));
}
fn readFloat(bytes: []const u8, at: usize) f32 {
    return @bitCast(readWord(bytes, at));
}
