//! Copied widget-motion packets. Native retains identities, buffers and
//! render samples; compiled policy cannot borrow retained-tree storage.
const std = @import("std");
const canvas = @import("canvas");
const geometry = @import("geometry");
const limits = @import("canvas_limits.zig");
const view_model = @import("view.zig");
const widget_runtime = @import("canvas_widget_runtime.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
comptime {
    const kinds = @typeInfo(canvas.WidgetKind).@"enum".fields;
    if (kinds.len != 63 or @intFromEnum(canvas.WidgetKind.accordion) != 14) @compileError("update motion kind wire");
    const easings = .{ "linear", "standard", "emphasized", "spring" };
    for (@typeInfo(canvas.Easing).@"enum".fields, easings, 0..) |field, name, i| {
        if (!std.mem.eql(u8, field.name, name) or field.value != i) @compileError("update motion easing wire");
    }
    const loops = .{ "none", "ping_pong", "wrap" };
    for (@typeInfo(canvas.CanvasRenderAnimationLoop).@"enum".fields, loops, 0..) |field, name, i| {
        if (!std.mem.eql(u8, field.name, name) or field.value != i) @compileError("update motion loop wire");
    }
    if (limits.max_canvas_widget_nodes_per_view > 1024 or limits.max_canvas_widget_disclosure_flips_per_view > 8 or limits.max_canvas_widget_disclosure_moves_per_view > 256 or limits.max_canvas_widget_drag_layout_motions_per_view > 64 or limits.max_canvas_widget_loop_animations_per_view > 64) @compileError("update motion capacity wire");
}
pub const DisclosureAction = enum { none, arm, refresh, retire };
pub const DisclosurePlan = struct {
    action: DisclosureAction = .none,
    duration_ms: u32 = 0,
    revealing_ids: [limits.max_canvas_widget_disclosure_flips_per_view]canvas.ObjectId = undefined,
    revealing_id_count: usize = 0,
    moves: [limits.max_canvas_widget_disclosure_moves_per_view]view_model.CanvasWidgetDisclosureMove = undefined,
    move_count: usize = 0,
};
pub const DragPlan = struct {
    apply: bool = false,
    motions: [limits.max_canvas_widget_drag_layout_motions_per_view]canvas.WidgetLayoutMotion = undefined,
    motion_count: usize = 0,
};
pub const Admission = struct { action: enum { none, snap, arm, retarget, invalid }, remove: bool, announce: bool, frame: bool };
pub fn admission(policy: Policy, flags: u8, duration: u32, current: f32, target: f32, active_target: f32) Admission {
    var input: [24]u8 = @splat(0);
    input[0..3].* = .{ 18, 0, flags };
    word(input[4..8], duration);
    float(input[8..12], current);
    float(input[12..16], target);
    float(input[16..20], active_target);
    var out: [4]u8 = undefined;
    run(policy, &input, &out);
    if ((out[0] > 3 and out[0] != 255) or out[1] > 1 or out[2] > 1 or out[3] > 1) @panic("invalid compiled tween admission");
    return .{ .action = if (out[0] == 255) .invalid else @enumFromInt(out[0]), .remove = out[1] == 1, .announce = out[2] == 1, .frame = out[3] == 1 };
}
pub fn source(policy: Policy, kind: canvas.WidgetKind, id: u64, pressed: bool, duration: u32, value: f32) bool {
    var input: [16]u8 = @splat(0);
    input[0..3].* = .{ 18, 1, @as(u8, @intFromBool(kind == .split)) | (@as(u8, @intFromBool(id != 0)) << 1) | (@as(u8, @intFromBool(pressed)) << 2) };
    word(input[4..8], duration);
    float(input[8..12], value);
    var out: [4]u8 = undefined;
    run(policy, &input, &out);
    if (out[0] > 1 or !std.mem.eql(u8, out[1..], &.{ 0, 0, 0 })) @panic("invalid compiled declared tween");
    return out[0] == 1;
}
pub fn disclosure(allocator: std.mem.Allocator, policy: Policy, previous: canvas.WidgetLayoutTree, next: canvas.WidgetLayoutTree, view: anytype, reduced: bool) !DisclosurePlan {
    const input = try allocator.alloc(u8, 24 + (previous.nodes.len + next.nodes.len) * 32);
    defer allocator.free(input);
    @memset(input, 0);
    input[0..4].* = .{ 18, 2, @intFromBool(view.canvas_widget_disclosure_tween.active), @intFromBool(reduced) };
    word(input[4..8], view.widget_tokens.motion.durationMs(.normal));
    word(input[8..12], @intCast(previous.nodes.len));
    word(input[12..16], @intCast(next.nodes.len));
    var plan = DisclosurePlan{};
    word(input[16..20], plan.revealing_ids.len);
    word(input[20..24], plan.moves.len);
    for (previous.nodes, 0..) |node, i| disclosureNode(input[24 + i * 32 ..][0..32], node, false);
    for (next.nodes, 0..) |node, i| disclosureNode(input[24 + (previous.nodes.len + i) * 32 ..][0..32], node, view.canvasWidgetDisclosureTogglePending(node.widget.id));
    var out: [16 + limits.max_canvas_widget_disclosure_flips_per_view * 8 + limits.max_canvas_widget_disclosure_moves_per_view * 24]u8 = undefined;
    run(policy, input, &out);
    plan.revealing_id_count = readWord(out[4..8]);
    plan.move_count = readWord(out[8..12]);
    if (out[0] > 3 or plan.revealing_id_count > plan.revealing_ids.len or plan.move_count > plan.moves.len or !std.mem.eql(u8, out[1..4], &.{ 0, 0, 0 })) @panic("invalid compiled disclosure plan");
    plan.action = @enumFromInt(out[0]);
    plan.duration_ms = readWord(out[12..16]);
    for (plan.revealing_ids[0..plan.revealing_id_count], 0..) |*id, i| id.* = readWide(out[16 + i * 8 ..][0..8]);
    for (plan.moves[0..plan.move_count], 0..) |*move, i| {
        const bytes = out[16 + plan.revealing_ids.len * 8 + i * 24 ..][0..24];
        const index = readWord(bytes[0..4]);
        if (index >= next.nodes.len or readWord(bytes[4..8]) != 0) @panic("invalid compiled disclosure node index");
        move.* = .{ .node_index = index, .from_y = readFloat(bytes[8..12]), .from_height = readFloat(bytes[12..16]), .to_y = readFloat(bytes[16..20]), .to_height = readFloat(bytes[20..24]) };
    }
    return plan;
}
fn disclosureNode(bytes: []u8, node: canvas.WidgetLayoutNode, pending: bool) void {
    wide(bytes[0..8], node.widget.id);
    bytes[8] = @intCast(@intFromEnum(node.widget.kind));
    bytes[9] = @intFromBool(widget_runtime.canvasWidgetBooleanSelected(node.widget));
    bytes[10] = @intFromBool(pending);
    inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| float(bytes[16 + i * 4 ..][0..4], @field(node.frame, name));
}
pub fn drag(allocator: std.mem.Allocator, policy: Policy, previous: canvas.WidgetLayoutTree, next: canvas.WidgetLayoutTree, view: anytype, reduced: bool) !DragPlan {
    const input = try allocator.alloc(u8, 24 + next.nodes.len * 48);
    defer allocator.free(input);
    @memset(input, 0);
    input[0..4].* = .{ 18, 3, @intFromBool(view.canvas_widget_drag_layout_motion_armed), @intFromBool(reduced) };
    const duration = view.widget_tokens.motion.durationMs(.normal);
    word(input[4..8], duration);
    word(input[8..12], @intCast(next.nodes.len));
    var plan = DragPlan{};
    word(input[12..16], plan.motions.len);
    const old = view.canvas_widget_drag_layout_motions[0..view.canvas_widget_drag_layout_motion_count];
    for (next.nodes, 0..) |node, i| {
        const bytes = input[24 + i * 48 ..][0..48];
        const id = node.widget.id;
        wide(bytes[0..8], id);
        const prev = previous.findById(id);
        const motion = findMotion(old, id);
        const landing = view.canvas_widget_drag_landing_source_id == id;
        word(bytes[8..12], @as(u32, @intFromBool(prev != null)) | (@as(u32, @intFromBool(node.widget.semantics.actions.drag)) << 1) | (@as(u32, @intFromBool(motion != null)) << 2) | (@as(u32, @intFromBool(landing)) << 3));
        const before = if (prev) |p| p.frame.normalized() else geometry.RectF{};
        const after = node.frame.normalized();
        float(bytes[12..16], before.x);
        float(bytes[16..20], before.y);
        float(bytes[20..24], after.x);
        float(bytes[24..28], after.y);
        if (motion) |m| {
            float(bytes[28..32], m.offset.dx);
            float(bytes[32..36], m.offset.dy);
        }
        float(bytes[36..40], view.canvas_widget_drag_landing_origin.x);
        float(bytes[40..44], view.canvas_widget_drag_landing_origin.y);
    }
    var out: [8 + limits.max_canvas_widget_drag_layout_motions_per_view * 16]u8 = undefined;
    run(policy, input, &out);
    plan.apply = out[0] == 1;
    plan.motion_count = readWord(out[4..8]);
    if (out[0] > 1 or plan.motion_count > plan.motions.len or !std.mem.eql(u8, out[1..4], &.{ 0, 0, 0 })) @panic("invalid compiled drag motion plan");
    for (plan.motions[0..plan.motion_count], 0..) |*motion, i| {
        const bytes = out[8 + i * 16 ..][0..16];
        const index = readWord(bytes[0..4]);
        if (index >= next.nodes.len or readWord(bytes[4..8]) > 1) @panic("invalid compiled drag motion index");
        const id = next.nodes[index].widget.id;
        if (readWord(bytes[4..8]) == 1) {
            motion.* = findMotion(old, id) orelse @panic("compiled motion lost retained owner");
        } else {
            const offset = geometry.OffsetF.init(readFloat(bytes[8..12]), readFloat(bytes[12..16]));
            motion.* = .{ .id = id, .from_offset = offset, .offset = offset, .escape_ancestor_clips = view.canvas_widget_drag_landing_source_id == id, .duration_ms = duration, .easing = .emphasized, .spring = view.widget_tokens.motion.spring };
        }
    }
    return plan;
}
fn findMotion(motions: []const canvas.WidgetLayoutMotion, id: u64) ?canvas.WidgetLayoutMotion {
    for (motions) |motion| if (motion.id == id) return motion;
    return null;
}
pub const Pose = struct { done: bool, a: f32, b: f32 };
pub fn pose(policy: Policy, mode: u8, progress: f32, a: f32, to_a: f32, b: f32, to_b: f32) Pose {
    var input: [32]u8 = @splat(0);
    input[0..4].* = .{ 18, 4, 0, mode };
    const values = [_]f32{ progress, a, to_a, b, to_b };
    for (values, 0..) |v, i| float(input[4 + i * 4 ..][0..4], v);
    var out: [12]u8 = undefined;
    run(policy, &input, &out);
    if (out[0] > 1 or !std.mem.eql(u8, out[1..4], &.{ 0, 0, 0 })) @panic("invalid compiled motion pose");
    return .{ .done = out[0] == 1, .a = readFloat(out[4..8]), .b = readFloat(out[8..12]) };
}
pub fn clock(policy: Policy, start: u64, timestamp: u64) u64 {
    var input: [24]u8 = @splat(0);
    input[0..2].* = .{ 18, 5 };
    wide(input[8..16], start);
    wide(input[16..24], timestamp);
    var out: [8]u8 = undefined;
    run(policy, &input, &out);
    return readWide(&out);
}
pub const Caret = struct { remove: bool, arm: bool, id: u64, start: u64 };
pub fn caret(policy: Policy, flags: u8, previous: u64, desired: u64, start: u64) Caret {
    var input: [40]u8 = @splat(0);
    input[0..3].* = .{ 18, 6, flags };
    wide(input[8..16], previous);
    wide(input[16..24], desired);
    wide(input[24..32], start);
    var out: [24]u8 = undefined;
    run(policy, &input, &out);
    if (out[0] > 1 or out[1] > 1 or !std.mem.eql(u8, out[2..8], &.{ 0, 0, 0, 0, 0, 0 })) @panic("invalid compiled caret plan");
    return .{ .remove = out[0] == 1, .arm = out[1] == 1, .id = readWide(out[8..16]), .start = readWide(out[16..24]) };
}
pub const Loop = struct { arm: bool, start: u64, duration: u32, easing: canvas.Easing, loop: canvas.CanvasRenderAnimationLoop, from: f32, to: f32 };
pub fn loop(policy: Policy, mode: u8, flags: u8, period: u32, count: usize, segment: usize, capacity: usize, tail: f32, existing: u64, start: u64, easing: canvas.Easing) Loop {
    var input: [48]u8 = @splat(0);
    input[0..4].* = .{ 18, 7, flags, mode };
    word(input[4..8], period);
    word(input[8..12], @intCast(count));
    word(input[12..16], @intCast(segment));
    word(input[16..20], @intCast(capacity));
    float(input[20..24], tail);
    wide(input[24..32], existing);
    wide(input[32..40], start);
    input[40] = @intCast(@intFromEnum(easing));
    var out: [32]u8 = undefined;
    run(policy, &input, &out);
    if (out[0] > 1 or out[1] > 3 or out[2] > 2 or out[3] != 0 or !std.mem.eql(u8, out[24..32], &.{ 0, 0, 0, 0, 0, 0, 0, 0 })) @panic("invalid compiled loop plan");
    return .{ .arm = out[0] == 1, .start = readWide(out[8..16]), .duration = readWord(out[4..8]), .easing = @enumFromInt(out[1]), .loop = @enumFromInt(out[2]), .from = readFloat(out[16..20]), .to = readFloat(out[20..24]) };
}
fn run(policy: Policy, input: []const u8, out: []u8) void {
    if (policy(input, out) != out.len) @panic("invalid compiled widget motion result length");
}
pub fn retireLoops(policy: Policy, previous: []const u64, desired: []const u64, removed: []u64) []const u64 {
    var input: [16 + limits.max_canvas_widget_loop_animations_per_view * 16]u8 = @splat(0);
    input[0..2].* = .{ 18, 8 };
    word(input[4..8], @intCast(previous.len));
    word(input[8..12], @intCast(desired.len));
    for (previous, 0..) |id, i| wide(input[16 + i * 8 ..][0..8], id);
    for (desired, 0..) |id, i| wide(input[16 + (previous.len + i) * 8 ..][0..8], id);
    var out: [4 + limits.max_canvas_widget_loop_animations_per_view * 4]u8 = undefined;
    run(policy, input[0 .. 16 + (previous.len + desired.len) * 8], out[0 .. 4 + previous.len * 4]);
    const count = readWord(out[0..4]);
    if (count > previous.len or count > removed.len) @panic("invalid compiled loop retirement count");
    for (removed[0..count], 0..) |*id, i| {
        const index = readWord(out[4 + i * 4 ..][0..4]);
        if (index >= previous.len) @panic("invalid compiled loop retirement index");
        id.* = previous[index];
    }
    return removed[0..count];
}
fn word(bytes: []u8, v: u32) void {
    std.mem.writeInt(u32, bytes[0..4], v, .little);
}
fn wide(bytes: []u8, v: u64) void {
    std.mem.writeInt(u64, bytes[0..8], v, .little);
}
fn float(bytes: []u8, v: f32) void {
    word(bytes, @bitCast(v));
}
fn readWord(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}
fn readWide(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}
fn readFloat(bytes: []const u8) f32 {
    return @bitCast(readWord(bytes));
}
