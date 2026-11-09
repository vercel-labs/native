//! Copied control command programs. The drawing host owns all emitted storage.
const std = @import("std");
pub const Policy = @import("surface_layout_policy.zig").Policy;
pub const Family = enum(u8) { button, icon_button, select, text_field, input_group, search, tooltip, menu_item, list_item, cell_chrome, cell, segmented, checkbox, radio, toggle, slider, progress };
pub const Opcode = enum(u32) { fill, stroke, focus, icon, text, selection, selected_glyphs, composition, caret, clip, unclip, mark, seam_clip, seam_unclip, shadow };
pub const Facts = struct {
    focused: bool = false,
    text: bool = false,
    placeholder: bool = false,
    icon: bool = false,
    selected: bool = false,
    background: bool = false,
    border: bool = false,
    clip: bool = false,
    selection: bool = false,
    selection_range: bool = false,
    composition: bool = false,
    composition_range: bool = false,
    underline: bool = false,
    bar: bool = false,
    clear: bool = false,
    chevron: bool = false,
    check: bool = false,
    seam: bool = false,
    combobox: bool = false,
    search_icon: bool = false,
    value: f32 = 0,
    stroke_width: f32 = 0,
    wash_alpha: f32 = 0,
    shadow_y: f32 = 0,
    shadow_blur: f32 = 0,
    shadow_spread: f32 = 0,
};
pub const Command = struct { opcode: Opcode, slot: u32, variant: u32 };
pub const Program = struct {
    count: usize,
    commands: [16]Command,
    pub fn init(policy: Policy, family: Family, facts: Facts) Program {
        var request: [32]u8 = @splat(0);
        request[0..4].* = .{ 45, 1, @intFromEnum(family), 0 };
        var flags: u32 = 0;
        inline for (std.meta.fields(Facts), 0..) |field, i| {
            if (field.type == bool) flags |= @as(u32, @intFromBool(@field(facts, field.name))) << @intCast(i);
        }
        std.mem.writeInt(u32, request[4..8], flags, .little);
        for ([_]f32{ facts.value, facts.stroke_width, facts.wash_alpha, facts.shadow_y, facts.shadow_blur, facts.shadow_spread }, 0..) |value, i|
            std.mem.writeInt(u32, request[8 + i * 4 ..][0..4], @bitCast(value), .little);
        var result: [200]u8 = @splat(0xa5);
        if (policy(&request, &result) != result.len or read(&result, 0) != 1 or read(&result, 4) > 16) @panic("invalid control command result");
        const count = read(&result, 4);
        if (!std.mem.allEqual(u8, result[8 + count * 12 ..], 0)) @panic("invalid control command tail");
        var program: Program = .{ .count = count, .commands = undefined };
        for (program.commands[0..count], 0..) |*command, i| {
            const at = 8 + i * 12;
            const op = read(&result, at);
            const slot = read(&result, at + 4);
            const variant = read(&result, at + 8);
            if (op > @intFromEnum(Opcode.shadow) or slot > 16) @panic("invalid control command capability");
            const valid = switch (@as(Opcode, @enumFromInt(op))) {
                .selection, .composition => variant == 256 or variant == 1034 or variant == 1037,
                .selected_glyphs => variant == 1 or variant == 4,
                .icon => variant <= 6,
                .fill => variant <= 5,
                .stroke, .text, .focus, .mark => variant <= 2,
                else => variant == 0,
            };
            if (!valid) @panic("invalid control command operands");
            command.* = .{ .opcode = @enumFromInt(op), .slot = slot, .variant = variant };
        }
        return program;
    }
};
fn read(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
