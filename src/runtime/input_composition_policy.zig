//! Copies OS observations to the composition owner and installs its bounded
//! result. Raw event bytes and all retained storage remain native capabilities.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform/root.zig");
const canvas = @import("canvas");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { normalize, keys, resolve, routed, claim, fallback, buffer, retire, target, paste, escape, delivery, claim_probe, key_delivery };
pub const Facts = struct {
    valid_view: bool = false,
    owner_present: bool = false,
    owner_kind: ?canvas.WidgetKind = null,
    focused_kind: ?canvas.WidgetKind = null,
    dismissed: bool = false,
    composition_keys: bool = false,
    claimed: bool = false,
    focused: bool = false,
    latch: bool = false,
    grace: u8 = 0,
    claim: u8 = 0,
    owner: u64 = 0,
    focused_id: u64 = 0,
    routed_id: u64 = 0,
    preedit_len: usize = 0,
    preedit_window: u64 = 0,
    preedit_label: []const u8 = "",
};
pub const Program = struct {
    pointer: u32,
    keyboard: u32,
    edit: u32,
    modifiers: u32,
    decisions: u32,
    owner: u64,
    grace: u8,
    claim: u8,
    source: u32,
    target: u64,
    pub fn has(self: Program, bit: u32) bool {
        return self.decisions & bit != 0;
    }
    pub fn keyboardModifiers(self: Program) canvas.WidgetKeyboardModifiers {
        return .{ .shift = self.modifiers & 1 != 0, .control = self.modifiers & 2 != 0, .alt = self.modifiers & 4 != 0, .super = self.modifiers & 8 != 0 };
    }
};
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn wide(bytes: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}
pub fn resultValid(bytes: []const u8) bool {
    return bytes.len == 64 and word(bytes, 0) == 1 and word(bytes, 4) <= 6 and word(bytes, 8) <= 2 and
        word(bytes, 12) <= 4 and word(bytes, 16) <= 15 and word(bytes, 20) <= 32767 and
        word(bytes, 32) <= 2 and word(bytes, 36) <= 2 and word(bytes, 40) <= 3 and
        word(bytes, 44) == 0 and wide(bytes, 56) == 0;
}
pub fn plan(policy: Policy, mode: Mode, input: platform.GpuSurfaceInputEvent, facts: Facts) ?Program {
    const callback = policy orelse return null;
    var bytes: [256]u8 = @splat(0);
    bytes[0..8].* = .{ 78, 1, @intFromEnum(mode), @intFromEnum(input.kind), modifiers(input.modifiers), @intFromBool(builtin.os.tag == .windows), facts.grace, facts.claim };
    var flags: u32 = 0;
    inline for (.{ "valid_view", "owner_present", "dismissed", "composition_keys", "claimed", "focused", "latch" }, 0..) |field, i|
        flags |= @as(u32, @intFromBool(@field(facts, field))) << @intCast(i);
    std.mem.writeInt(u32, bytes[8..12], flags, .little);
    std.mem.writeInt(u32, bytes[12..16], if (facts.owner_kind) |kind| canvas.widgetKindCode(kind) else 63, .little);
    std.mem.writeInt(u32, bytes[240..244], if (facts.focused_kind) |kind| canvas.widgetKindCode(kind) else 63, .little);
    const fields = [_]u64{ input.key.len, input.text.len, input.window_id, facts.preedit_window, facts.owner, facts.focused_id, facts.routed_id, facts.preedit_len, input.label.len, facts.preedit_label.len };
    for (fields, 0..) |value, i| std.mem.writeInt(u64, bytes[16 + i * 8 ..][0..8], value, .little);
    const key_len = @min(input.key.len, 8);
    @memcpy(bytes[96..][0..key_len], input.key[0..key_len]);
    const text_len = @min(input.text.len, 2);
    @memcpy(bytes[104..][0..text_len], input.text[0..text_len]);
    const label_len = @min(input.label.len, 64);
    @memcpy(bytes[112..][0..label_len], input.label[0..label_len]);
    const pre_label_len = @min(facts.preedit_label.len, 64);
    @memcpy(bytes[176..][0..pre_label_len], facts.preedit_label[0..pre_label_len]);
    var output: [64]u8 = @splat(0xa5);
    const length = callback(&bytes, &output);
    if (length > output.len or !resultValid(output[0..length])) @panic("invalid compiled input composition result");
    return .{ .pointer = word(&output, 4), .keyboard = word(&output, 8), .edit = word(&output, 12), .modifiers = word(&output, 16), .decisions = word(&output, 20), .owner = wide(&output, 24), .grace = @intCast(word(&output, 32)), .claim = @intCast(word(&output, 36)), .source = word(&output, 40), .target = wide(&output, 48) };
}
fn modifiers(m: platform.ShortcutModifiers) u8 {
    return @as(u8, @intFromBool(m.shift)) | (@as(u8, @intFromBool(m.control)) << 1) | (@as(u8, @intFromBool(m.option)) << 2) | (@as(u8, @intFromBool(m.command)) << 3) | (@as(u8, @intFromBool(m.primary)) << 4);
}
pub fn observations(runtime: anytype, view: anytype) Facts {
    const tree = view.widgetLayoutTree();
    const owner = if (view.canvas_widget_ime_owner_id != 0) tree.findById(view.canvas_widget_ime_owner_id) else null;
    const focused = if (view.canvas_widget_focused_id != 0) tree.findById(view.canvas_widget_focused_id) else null;
    return .{ .valid_view = view.kind == .gpu_surface, .owner_present = owner != null, .owner_kind = if (owner) |node| node.widget.kind else null, .focused_kind = if (focused) |node| node.widget.kind else null, .owner = view.canvas_widget_ime_owner_id, .grace = @intFromEnum(view.canvas_widget_ime_commit_grace), .claim = @intFromEnum(view.canvas_widget_claimed_key_grace), .focused_id = view.canvas_widget_focused_id, .focused = view.focused, .preedit_len = runtime.targetless_ime_preedit_len, .preedit_window = runtime.targetless_ime_preedit_window, .preedit_label = runtime.targetless_ime_preedit_label[0..runtime.targetless_ime_preedit_label_len], .latch = runtime.targetless_ime_commit_grace };
}
pub fn installWidget(view: anytype, program: Program) void {
    view.canvas_widget_ime_owner_id = program.owner;
    view.canvas_widget_ime_commit_grace = @enumFromInt(program.grace);
    view.canvas_widget_claimed_key_grace = @enumFromInt(program.claim);
}
pub fn pointerEvent(program: Program, input: platform.GpuSurfaceInputEvent) ?canvas.WidgetPointerEvent {
    const phase: canvas.WidgetPointerPhase = switch (program.pointer) {
        0 => return null,
        1 => .down,
        2 => .up,
        3 => .cancel,
        4 => .hover,
        5 => .move,
        6 => .wheel,
        else => unreachable,
    };
    return .{ .phase = phase, .point = .{ .x = input.x, .y = input.y }, .delta = .{ .dx = input.delta_x, .dy = input.delta_y }, .scroll_is_detented = input.scroll_is_detented, .pointer_id = input.pointer_id, .button = input.button, .modifiers = program.keyboardModifiers() };
}
pub fn keyboardEvent(program: Program, input: platform.GpuSurfaceInputEvent, focused_id: u64, text: bool) ?canvas.WidgetKeyboardEvent {
    const edit: ?canvas.TextInputEvent = switch (program.edit) {
        0 => null,
        1 => .{ .insert_text = input.text },
        2 => .{ .set_composition = .{ .text = input.text, .cursor = input.composition_cursor } },
        3 => .commit_composition,
        4 => .cancel_composition,
        else => unreachable,
    };
    const phase: canvas.WidgetKeyboardPhase = if (text) if (edit != null) .text_input else return null else switch (program.keyboard) {
        0 => return null,
        1 => .key_down,
        2 => .key_up,
        else => unreachable,
    };
    return .{ .phase = phase, .focused_id = focused_id, .key = input.key, .text = input.text, .edit = if (text) edit else null, .modifiers = program.keyboardModifiers() };
}

test "input composition transport rejects incomplete results and unclaimed fields" {
    var bytes: [64]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 1, .little);
    try std.testing.expect(resultValid(&bytes));
    for (0..bytes.len) |len| try std.testing.expect(!resultValid(bytes[0..len]));
    for ([_]usize{ 0, 4, 8, 12, 16, 20, 32, 36, 40, 44, 56, 60 }) |at| {
        var bad = bytes;
        std.mem.writeInt(u32, bad[at..][0..4], 0xffffffff, .little);
        try std.testing.expect(!resultValid(&bad));
    }
}
