//! Rebuild decisions over copied facts. Exact keyed storage lookups, byte
//! equality and fingerprinting stay native; the compiled planner owns admission
//! and restoration. Every result is copied before another callback can run.
const std = @import("std");
const canvas = @import("canvas");
const limits = @import("canvas_limits.zig");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Action = struct { flags: u32, value: f32 };
pub const Plan = struct { entries: [limits.max_canvas_widget_nodes_per_view]Action = undefined };

pub fn build(policy: Policy, layout: canvas.WidgetLayoutTree, controls: anytype, sources: anytype, texts: anytype, comptime hidden: anytype, comptime fingerprint: anytype, comptime minimumWidth: anytype) ?Plan {
    const callback = policy orelse return null;
    if (layout.nodes.len > limits.max_canvas_widget_nodes_per_view) @panic("widget reconcile exceeds view budget");
    var input: [8 + limits.max_canvas_widget_nodes_per_view * 64]u8 = undefined;
    const bytes = input[0 .. 8 + layout.nodes.len * 64];
    @memset(bytes, 0);
    bytes[0] = 93;
    std.mem.writeInt(u32, bytes[4..8], @intCast(layout.nodes.len), .little);
    for (layout.nodes, 0..) |node, i| {
        const w = node.widget;
        const fact = bytes[8 + i * 64 ..][0..64];
        const control = controls.firstWithKind(w.id, w.kind);
        const source = sources.firstWithKind(w.id, w.kind);
        const text = texts.firstWithKind(w.id, w.kind);
        fact[0] = @intCast(canvas.widgetKindCode(w.kind));
        fact[1] = bit(w.id != 0, 0) | bit(w.state.disabled, 1) | bit(hidden(layout, i), 2) |
            bit(control != null, 3) | bit(source != null, 4) | bit(text != null, 5) |
            bit(w.runtime_flags.code_editor, 6) | bit(w.hasCodeDiff(), 7);
        fact[2] = bit(w.state.selected or w.value >= 0.5, 0) |
            bit(if (source) |entry| entry.selected else false, 1) |
            bit(if (control) |entry| entry.state.selected or entry.value >= 0.5 else false, 2) |
            bit(if (control) |entry| entry.state.pressed else false, 3);
        float(fact[4..8], w.value);
        float(fact[8..12], if (source) |entry| entry.value else 0);
        float(fact[12..16], if (control) |entry| entry.value else 0);
        float(fact[16..20], minimumWidth(w));
        fact[20] = bit(w.text_selection != null, 0) | bit(w.text_composition != null, 1) |
            bit(if (w.text_selection) |selection| selection.affinity == .downstream else false, 2);
        if (w.text_selection) |selection| {
            wide(fact[24..32], selection.anchor);
            wide(fact[32..40], selection.focus);
        }
        if (text) |entry| {
            const source_text = fingerprint(w.text);
            fact[2] |= bit(std.mem.eql(u8, w.text, entry.text), 4) | bit(w.static_text_group_id == entry.static_text_group_id, 5) |
                bit(source_text.len == entry.source_text_len and source_text.hash == entry.source_text_hash, 6);
            fact[20] |= bit(entry.text_selection != null, 3) |
                bit(if (entry.text_selection) |selection| selection.affinity == .downstream else false, 4) |
                bit(entry.source_text_selection != null, 5) |
                bit(if (entry.source_text_selection) |selection| selection.affinity == .downstream else false, 6);
            if (entry.text_selection) |selection| {
                wide(fact[40..48], selection.anchor);
                wide(fact[48..56], selection.focus);
            }
        }
    }
    var output: [8 + limits.max_canvas_widget_nodes_per_view * 8]u8 = undefined;
    const size = callback(bytes, &output);
    if (size != 8 + layout.nodes.len * 8 or output[0] != 93 or output[1] != 0 or output[2] != 0 or output[3] != 0 or
        std.mem.readInt(u32, output[4..8], .little) != layout.nodes.len) @panic("invalid compiled widget reconcile header");
    var plan = Plan{};
    for (plan.entries[0..layout.nodes.len], 0..) |*action, i| {
        const at = 8 + i * 8;
        const flags = std.mem.readInt(u32, output[at..][0..4], .little);
        if (flags > 2047 or (flags & 2 != 0 and flags & 1 == 0) or (flags & (16 | 128 | 256 | 512) != 0 and flags & 32 == 0) or
            (flags & 512 != 0 and flags & 256 == 0) or (flags & (1 | 4 | 8) != 0 and controls.firstWithKind(layout.nodes[i].widget.id, layout.nodes[i].widget.kind) == null) or
            (flags & (16 | 32 | 64 | 128 | 256 | 512) != 0 and texts.firstWithKind(layout.nodes[i].widget.id, layout.nodes[i].widget.kind) == null))
            @panic("invalid compiled widget reconcile action");
        action.* = .{ .flags = flags, .value = @bitCast(std.mem.readInt(u32, output[at + 4 ..][0..4], .little)) };
    }
    return plan;
}
fn bit(value: bool, shift: u3) u8 {
    return @as(u8, @intFromBool(value)) << shift;
}
fn float(bytes: *[4]u8, value: f32) void {
    std.mem.writeInt(u32, bytes, @bitCast(value), .little);
}
fn wide(bytes: *[8]u8, value: usize) void {
    std.mem.writeInt(u64, bytes, @intCast(value), .little);
}
