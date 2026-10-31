//! Copied scroll capability programs. All state, identities, f32 numeric
//! operations and geometry remain native-owned; compiled code orders them.
const std = @import("std");
const canvas = @import("canvas");
const limits = @import("canvas_limits.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { axis, textarea, driver, keyboard, kinetic, finish };
pub const Kind = enum(u8) {
    viewport,
    textarea_viewport,
    region_state,
    textarea_state,
    delegate_textarea,
    wheel,
    wheel_clamped,
    discrete,
    zero_velocity,
    store_axis,
    compare_axis,
    write_axis,
    translate_axis,
    event,
    semantics,
    revision,
    dirty,
    driver_y,
    driver_x,
    target_y,
    target_x,
    store_state,
    write_both,
    translate_both,
    clear_velocities,
    probe_y,
    probe_x,
    kinetic_y,
    kinetic_x,
    zero_y,
    zero_x,
    accumulate_dirty,
};
pub fn nodeFacts(node: canvas.WidgetLayoutNode) u8 {
    var facts: u8 = 1;
    if (node.widget.kind == .scroll_view) facts |= 2;
    if (node.widget.kind == .textarea) facts |= 4;
    if (node.widget.layout.virtualized and !canvas.widgetVirtualRuntimeScrolled(node.widget)) facts |= 8;
    if (canvas.widgetScrollsAxis(node.widget, .vertical)) facts |= 16;
    if (canvas.widgetScrollsAxis(node.widget, .horizontal)) facts |= 32;
    if (node.widget.runtime_flags.native_scroll) facts |= 64;
    return facts;
}
pub const Selection = struct {
    include: [limits.max_canvas_widget_nodes_per_view]bool = undefined,
};
pub fn kineticSelection(policy: Policy, nodes: []const canvas.WidgetLayoutNode) Selection {
    comptime {
        if (limits.max_canvas_widget_nodes_per_view != 1024) @compileError("update kinetic selection wire budget");
    }
    if (nodes.len > limits.max_canvas_widget_nodes_per_view) @panic("kinetic selection exceeds node budget");
    var input: [16 + limits.max_canvas_widget_nodes_per_view]u8 = @splat(0);
    input[0] = 101;
    input[1] = 6;
    std.mem.writeInt(u32, input[8..12], @intCast(nodes.len), .little);
    for (nodes, 0..) |node, i| input[16 + i] = nodeFacts(node);
    var output: [8 + limits.max_canvas_widget_nodes_per_view]u8 = undefined;
    if (policy(input[0 .. 16 + nodes.len], &output) != 8 + nodes.len or output[0] != 101 or output[1] != 6 or
        output[2] != 0 or output[3] != 0 or std.mem.readInt(u32, output[4..8], .little) != nodes.len)
        @panic("invalid kinetic selection header");
    var result: Selection = undefined;
    for (result.include[0..nodes.len], 0..) |*include, i| {
        if (output[8 + i] > 1) @panic("invalid kinetic selection capability");
        include.* = output[8 + i] == 1;
    }
    return result;
}
pub const Program = struct {
    bytes: [24]u8,
    count: usize,
    next: u8,
    pub fn instruction(self: *const Program, index: usize) Kind {
        std.debug.assert(index < self.count);
        return @enumFromInt(self.bytes[8 + index]);
    }
};
pub fn plan(policy: Policy, mode: Mode, phase: u8, source: u8, vertical: bool, facts: u32) Program {
    var input: [16]u8 = @splat(0);
    input[0..5].* = .{ 101, @intFromEnum(mode), phase, source, @intFromBool(vertical) };
    std.mem.writeInt(u32, input[8..12], facts, .little);
    var result: Program = undefined;
    const size = policy(&input, &result.bytes);
    if (size < 8 or size > result.bytes.len or result.bytes[0] != 101 or result.bytes[1] != @intFromEnum(mode) or
        std.mem.readInt(u32, result.bytes[4..8], .little) != 0)
        @panic("invalid scroll mutation program header");
    result.count = result.bytes[3];
    result.next = result.bytes[2];
    if (size != 8 + result.count or (result.next != 255 and (result.next != phase + 1 or result.next > (if (mode == .kinetic) @as(u8, 4) else 2))) or
        (mode == .finish and result.next != 255)) @panic("invalid scroll mutation program progress");
    if (mode != .finish and ((facts & 1 == 0 and result.count != 0) or
        (phase > 1 and facts & 256 == 0 and result.count != 0))) @panic("invalid scroll mutation storage admission");
    for (result.bytes[8..size]) |kind| {
        if (kind > @intFromEnum(Kind.accumulate_dirty)) @panic("invalid scroll mutation capability");
        const capability: Kind = @enumFromInt(kind);
        // Capability admission, independent of the program's semantic choices.
        const allowed = switch (capability) {
            .viewport => phase == 0 and mode != .textarea and mode != .finish,
            .textarea_viewport => phase == 0 and mode == .textarea,
            .delegate_textarea => phase == 0 and mode == .axis,
            .region_state => phase == 1 and mode != .textarea and mode != .finish,
            .textarea_state, .compare_axis => phase == 1 and mode == .textarea,
            .wheel, .wheel_clamped, .discrete => phase == 1 and (mode == .axis or mode == .textarea),
            .zero_velocity, .store_axis => phase == 1 and mode == .axis,
            .driver_y, .driver_x => phase == 1 and mode == .driver,
            .target_y, .target_x => phase == 1 and mode == .keyboard,
            .store_state => (phase == 1 and (mode == .driver or mode == .keyboard)) or (phase == 3 and mode == .kinetic),
            .clear_velocities => phase == 1 and mode == .kinetic,
            .probe_y => phase == 1 and mode == .kinetic,
            .probe_x, .kinetic_y, .zero_y => phase == 2 and mode == .kinetic,
            .kinetic_x, .zero_x => phase == 3 and mode == .kinetic,
            .semantics, .revision => (phase == 2 and mode != .kinetic and mode != .finish) or (phase == 0 and mode == .finish),
            .write_axis => phase == 2 and (mode == .axis or mode == .textarea),
            .translate_axis => phase == 2 and mode == .axis,
            .dirty => phase == 2 and mode != .kinetic and mode != .finish,
            .event => (phase == 2 and (mode == .axis or mode == .driver or mode == .keyboard)) or (phase == 4 and mode == .kinetic),
            .write_both, .translate_both => (phase == 2 and (mode == .driver or mode == .keyboard)) or (phase == 4 and mode == .kinetic),
            .accumulate_dirty => phase == 4 and mode == .kinetic,
        };
        if (!allowed) @panic("invalid scroll mutation capability admission");
    }
    return result;
}
