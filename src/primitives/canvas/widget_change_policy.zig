//! Copied retained-change boundary. Native transports raw values, validates
//! the complete plan, and reconstructs typed caller records. Matching and
//! change classification belong exclusively to the selected portable owner.
const std = @import("std");
const widgets = @import("widgets.zig");
const events = @import("events.zig");
const geometry = @import("geometry");
pub const Policy = @import("surface_layout_policy.zig").Policy;
const missing = std.math.maxInt(u32);
const group_count = 9;
const node_header_size = 16 + group_count * 4;
const AllocationError = std.mem.Allocator.Error;
pub fn owner(layout: anytype) ?Policy {
    const T = switch (@typeInfo(@TypeOf(layout))) {
        .pointer => |p| p.child,
        else => @TypeOf(layout),
    };
    if (comptime @hasField(T, "change_policy")) return layout.change_policy;
    return null;
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn count(value: usize) u32 {
    return std.math.cast(u32, value) orelse @panic("widget change wire capacity");
}
fn writeWord(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) AllocationError!void {
    var bytes: [4]u8 = undefined;
    put(&bytes, 0, value);
    try list.appendSlice(allocator, &bytes);
}
/// Equality facts use tagged values rather than object memory or hashes.
/// This preserves byte slices, optional presence, wide integers, all float
/// payloads, and the reference's field-wise equality without padding bytes.
fn writeValue(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) AllocationError!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try list.appendSlice(allocator, &.{ 0, @intFromBool(value) }),
        .int => {
            try list.append(allocator, 1);
            var bytes: [16]u8 = undefined;
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            std.mem.writeInt(u128, &bytes, @as(U, @bitCast(value)), .little);
            try list.appendSlice(allocator, &bytes);
        },
        .@"enum" => {
            try list.append(allocator, 2);
            try writeWord(list, allocator, @intCast(@intFromEnum(value)));
        },
        .float => {
            if (T == f32) {
                try list.append(allocator, 3);
                try writeWord(list, allocator, @bitCast(value));
            } else if (T == f64) {
                try list.append(allocator, 4);
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, @bitCast(value), .little);
                try list.appendSlice(allocator, &bytes);
            } else @compileError("unsupported widget change float");
        },
        .optional => {
            try list.appendSlice(allocator, &.{ 5, @intFromBool(value != null) });
            if (value) |present| try writeValue(list, allocator, present);
        },
        .@"struct" => |s| {
            try list.append(allocator, 6);
            try writeWord(list, allocator, s.fields.len);
            inline for (s.fields) |field| try writeValue(list, allocator, @field(value, field.name));
        },
        .array => {
            try list.append(allocator, 6);
            try writeWord(list, allocator, count(value.len));
            for (value) |item| try writeValue(list, allocator, item);
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("widget change facts cannot contain native pointers");
            try list.append(allocator, if (p.child == u8) 7 else 6);
            try writeWord(list, allocator, count(value.len));
            if (p.child == u8) try list.appendSlice(allocator, value) else for (value) |item| try writeValue(list, allocator, item);
        },
        else => @compileError("unsupported widget change fact type"),
    }
}
fn writeNode(list: *std.ArrayList(u8), allocator: std.mem.Allocator, node: events.WidgetLayoutNode) AllocationError!void {
    const w = node.widget;
    const header = list.items.len;
    try list.appendSlice(allocator, &([_]u8{0} ** node_header_size));
    std.mem.writeInt(u64, list.items[header..][0..8], w.id, .little);
    const flags: u32 = @intFromBool(node.parent_index == null) | (@as(u32, @intFromBool(w.hasCodeDiff())) << 1) |
        (@as(u32, @intFromBool(w.terminal.grid != null)) << 2) | (@as(u32, @intFromBool(w.semantics.hidden)) << 3);
    put(list.items, header + 8, flags);
    // These are the exact dependencies of the retained reference. Anchor,
    // zero_intrinsic, callbacks and other unobserved fields deliberately stay
    // outside this contract; changing it is a behavior change, not a port.
    const groups = .{
        .{ w.kind, node.depth, node.parent_index, node.frame, w.code_line_number_digits, w.layout.padding, w.layout.padding_is_kind_default, w.layout.gap, w.layout.grow, w.layout.main_alignment, w.layout.cross_alignment, w.layout.clip_content, w.layout.columns, w.layout.virtualized, w.layout.virtual_item_extent, w.layout.virtual_overscan, w.layout.virtual_item_count, w.layout.virtual_first_index, w.layout.virtual_anchor_index, w.layout.virtual_anchor_extent, w.layout.virtual_total_extent, w.layout.min_size, w.layout.max_size },
        .{ w.text, w.spans, w.code_language, w.static_text_group_id, w.codeDiffLines(), w.chart, w.placeholder, w.icon, w.value, w.value_x, w.scroll_axes, w.image_id, w.image_src, w.image_fit, w.image_sampling, w.image_opacity, w.stream_size, w.text_selection, w.text_composition, w.terminal.pty, w.terminal.scrollback },
        w.command,
        .{ w.opacity, w.transform, w.backdrop_blur, w.backdrop_blur_token, w.scrim, w.text_alignment, w.text_no_wrap, w.text_overflow, w.variant, w.size, w.style },
        w.state,
        w.semantics,
        w.layer,
        w.static_text_group_offset,
        .{ w.opacity, w.transform },
    };
    comptime std.debug.assert(@typeInfo(@TypeOf(groups)).@"struct".fields.len == group_count);
    inline for (groups, 0..) |group, i| {
        const start = list.items.len;
        try writeValue(list, allocator, group);
        put(list.items, header + 16 + i * 4, count(list.items.len - start));
    }
}
pub const Flags = struct {
    layout: bool,
    paint: bool,
    semantics: bool,
    root: bool,
    visibility: bool,
    subtree: bool,
    layer: bool,
};
pub const Entry = struct { kind: events.WidgetInvalidationKind, previous: ?usize, next: ?usize, flags: Flags };
pub const Plan = struct {
    allocator: std.mem.Allocator,
    request: []u8,
    result: []u8,
    status: u8,
    length: usize,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, previous: anytype, next: anytype, previous_root: ?geometry.RectF, next_root: ?geometry.RectF, capacity: usize) AllocationError!Plan {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);
        try list.appendSlice(allocator, &([_]u8{0} ** 64));
        list.items[0..4].* = .{ 25, 1, 0, 0 };
        put(list.items, 4, count(previous.nodes.len));
        put(list.items, 8, count(next.nodes.len));
        put(list.items, 12, count(@min(capacity, std.math.maxInt(u32))));
        put(list.items, 16, @as(u32, @intFromBool(previous_root != null)) | (@as(u32, @intFromBool(next_root != null)) << 1));
        for ([_]?geometry.RectF{ previous_root, next_root }, 0..) |maybe_rect, r| {
            if (maybe_rect) |rect| for ([_]f32{ rect.x, rect.y, rect.width, rect.height }, 0..) |value, i| put(list.items, 24 + r * 16 + i * 4, @bitCast(value));
        }
        for (previous.nodes) |node| try writeNode(&list, allocator, node);
        for (next.nodes) |node| try writeNode(&list, allocator, node);
        const request = try list.toOwnedSlice(allocator);
        errdefer allocator.free(request);
        const maximum = std.math.add(usize, previous.nodes.len, next.nodes.len) catch @panic("widget change result capacity");
        const bytes = std.math.add(usize, 16, std.math.mul(usize, @min(capacity, maximum), 16) catch @panic("widget change result capacity")) catch @panic("widget change result capacity");
        const result = try allocator.alloc(u8, bytes);
        errdefer allocator.free(result);
        @memset(result, 0xa5);
        const written = policy(request, result);
        if (written < 16 or written > result.len or result[0] != 1 or result[1] != 0 or result[2] > 2 or result[3] != 0 or word(result, 8) != 0 or word(result, 12) != 0)
            @panic("invalid compiled widget change result");
        const length = word(result, 4);
        if (length > capacity or length > maximum or written != 16 + @as(usize, length) * 16 or (result[2] == 1 and length != 0) or (result[2] == 2 and length != capacity))
            @panic("invalid compiled widget change count");
        const plan = Plan{ .allocator = allocator, .request = request, .result = result, .status = result[2], .length = length };
        var previous_index: ?usize = null;
        var next_index: ?usize = null;
        var added = false;
        // Validate the entire plan before touching caller output. Identity
        // checks here validate references; they never select or reclassify.
        for (0..length) |i| {
            const planned = plan.entry(i);
            const bits = word(result, 28 + i * 16);
            if (bits & ~@as(u32, 127) != 0 or bits & 7 == 0 or (bits & 1 != 0 and bits & 6 != 6) or (bits & 8 != 0 and bits & 1 == 0)) @panic("invalid compiled widget change flags");
            if (planned.kind == .added) {
                added = true;
                const n = planned.next orelse @panic("missing compiled added index");
                if (n >= next.nodes.len or planned.previous != null or bits != 7 or next.nodes[n].widget.id == 0 or (next_index != null and n <= next_index.?)) @panic("invalid compiled added widget");
                next_index = n;
            } else {
                const p = planned.previous orelse @panic("missing compiled previous index");
                if (added or p >= previous.nodes.len or previous.nodes[p].widget.id == 0 or (previous_index != null and p <= previous_index.?)) @panic("invalid compiled previous widget");
                previous_index = p;
                if (planned.kind == .removed) {
                    if (planned.next != null or bits != 7) @panic("invalid compiled removed widget");
                } else {
                    const n = planned.next orelse @panic("missing compiled changed index");
                    if (n >= next.nodes.len or previous.nodes[p].widget.id != next.nodes[n].widget.id) @panic("invalid compiled changed identity");
                }
            }
        }
        return plan;
    }
    pub fn deinit(self: Plan) void {
        self.allocator.free(self.request);
        self.allocator.free(self.result);
    }
    pub fn entry(self: Plan, i: usize) Entry {
        const at = 16 + i * 16;
        const previous = word(self.result, at + 4);
        const next = word(self.result, at + 8);
        const flags = word(self.result, at + 12);
        return .{ .kind = switch (word(self.result, at)) {
            0 => .removed,
            1 => .changed,
            2 => .added,
            else => @panic("invalid compiled widget change kind"),
        }, .previous = if (previous == missing) null else previous, .next = if (next == missing) null else next, .flags = .{
            .layout = flags & 1 != 0,
            .paint = flags & 2 != 0,
            .semantics = flags & 4 != 0,
            .root = flags & 8 != 0,
            .visibility = flags & 16 != 0,
            .subtree = flags & 32 != 0,
            .layer = flags & 64 != 0,
        } };
    }
};

pub fn stateBits(state: widgets.WidgetState) u32 {
    return @intFromBool(state.hovered) | (@as(u32, @intFromBool(state.pressed)) << 1) |
        (@as(u32, @intFromBool(state.focused)) << 2) | (@as(u32, @intFromBool(state.disabled)) << 3) |
        (@as(u32, @intFromBool(state.selected)) << 4) | (@as(u32, @intFromBool(state.expanded != null)) << 5) |
        (@as(u32, @intFromBool(state.expanded orelse false)) << 6) | (@as(u32, @intFromBool(state.required)) << 7) |
        (@as(u32, @intFromBool(state.read_only)) << 8) | (@as(u32, @intFromBool(state.invalid)) << 9);
}
fn writeRenderState(bytes: []u8, state: widgets.WidgetRenderState) void {
    var flags: u32 = @as(u32, @intFromBool(state.keyboard_active)) << 7;
    for ([_]?u64{ state.focused_id, state.focus_visible_id, state.hovered_id, state.pressed_id, state.drag_preview_id }, 0..) |id, i| {
        flags |= @as(u32, @intFromBool(id != null)) << @intCast(i);
        std.mem.writeInt(u64, bytes[8 + i * 8 ..][0..8], id orelse 0, .little);
    }
    flags |= (@as(u32, @intFromBool(state.hover_point != null)) << 5) | (@as(u32, @intFromBool(state.drag_preview_origin != null)) << 6);
    put(bytes, 0, flags);
    const hover = state.hover_point orelse geometry.PointF.zero();
    const drag = state.drag_preview_origin orelse geometry.PointF.zero();
    for ([_]f32{ hover.x, hover.y, drag.x, drag.y, state.drag_preview_offset.dx, state.drag_preview_offset.dy }, 0..) |value, i| put(bytes, 48 + i * 4, @bitCast(value));
}
pub const RenderEntry = struct { node_index: usize, terminal: bool, state: bool, previous: u32, next: u32 };
pub const RenderPlan = struct {
    allocator: std.mem.Allocator,
    request: []u8,
    result: []u8,
    length: usize,
    group_lengths: [2]usize,
    chart: bool,
    drag: bool,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, layout: anytype, previous: widgets.WidgetRenderState, next: widgets.WidgetRenderState) AllocationError!RenderPlan {
        const node_count = layout.nodes.len;
        const request_size = std.math.add(usize, 160, std.math.mul(usize, node_count, 24) catch @panic("render change capacity")) catch @panic("render change capacity");
        const request = try allocator.alloc(u8, request_size);
        errdefer allocator.free(request);
        @memset(request, 0);
        request[0..4].* = .{ 25, 1, 1, 0 };
        put(request, 4, count(node_count));
        writeRenderState(request[16..88], previous);
        writeRenderState(request[88..160], next);
        for (layout.nodes, 0..) |node, i| {
            const at = 160 + i * 24;
            put(request, at, widgets.widgetKindCode(node.widget.kind));
            put(request, at + 4, if (node.parent_index) |p| (std.math.cast(u32, p) orelse missing) else missing);
            std.mem.writeInt(u64, request[at + 8 ..][0..8], node.widget.id, .little);
            put(request, at + 16, stateBits(node.widget.state));
            const grid = node.widget.terminal.grid;
            put(request, at + 20, @intFromBool(grid != null) | (@as(u32, @intFromBool(if (grid) |g| g.running else false)) << 1) |
                (@as(u32, @intFromBool(if (grid) |g| g.cursor != null else false)) << 2));
        }
        const result_size = std.math.add(usize, 160, std.math.mul(usize, node_count, 24) catch @panic("render change result capacity")) catch @panic("render change result capacity");
        const result = try allocator.alloc(u8, result_size);
        errdefer allocator.free(result);
        @memset(result, 0xa5);
        const written = policy(request, result);
        if (written < 32 or written > result.len or !std.mem.eql(u8, result[0..4], &.{ 1, 1, 0, 0 }) or word(result, 16) > 3 or word(result, 20) != 0 or word(result, 24) != 0 or word(result, 28) != 0)
            @panic("invalid compiled render change result");
        const length = word(result, 4);
        const groups = [2]usize{ word(result, 8), word(result, 12) };
        if (length > node_count + 8 or groups[0] > node_count or groups[1] > node_count or written != 32 + @as(usize, length) * 16 + (groups[0] + groups[1]) * 4)
            @panic("invalid compiled render change count");
        const plan = RenderPlan{ .allocator = allocator, .request = request, .result = result, .length = length, .group_lengths = groups, .chart = word(result, 16) & 1 != 0, .drag = word(result, 16) & 2 != 0 };
        for (0..length) |i| {
            const item = plan.entry(i);
            const flags = word(result, 36 + i * 16);
            if (item.node_index >= node_count or flags == 0 or flags > 3 or item.previous > 1023 or item.next > 1023 or
                (item.previous & ~@as(u32, 7)) != (stateBits(layout.nodes[item.node_index].widget.state) & ~@as(u32, 7)) or
                (item.next & ~@as(u32, 7)) != (stateBits(layout.nodes[item.node_index].widget.state) & ~@as(u32, 7))) @panic("invalid compiled render change entry");
        }
        for (0..2) |g| for (0..groups[g]) |i| {
            const index = plan.groupIndex(g, i);
            if (index >= node_count or layout.nodes[index].widget.kind != .input_group) @panic("invalid compiled focus group");
        };
        return plan;
    }
    pub fn deinit(self: RenderPlan) void {
        self.allocator.free(self.request);
        self.allocator.free(self.result);
    }
    pub fn entry(self: RenderPlan, i: usize) RenderEntry {
        const at = 32 + i * 16;
        return .{ .node_index = word(self.result, at), .state = word(self.result, at + 4) & 1 != 0, .terminal = word(self.result, at + 4) & 2 != 0, .previous = word(self.result, at + 8), .next = word(self.result, at + 12) };
    }
    pub fn groupIndex(self: RenderPlan, g: usize, i: usize) usize {
        return word(self.result, 32 + self.length * 16 + (i + if (g == 1) self.group_lengths[0] else @as(usize, 0)) * 4);
    }
};
