//! Complete leaf streams against the independent native renderer.
const std = @import("std");
const sdk = @import("native_sdk");
const c = sdk.canvas;
const core = @import("ts_persist_core");
const exact = @import("component_construction_e2e_tests.zig").exact;
const kinds = [_]c.WidgetKind{ .image, .avatar, .badge, .separator, .split_divider, .status_bar, .skeleton, .data_row };
fn compare(widget: c.Widget, tokens: c.DesignTokens, retained: bool, capacity: usize) !void {
    var compiled = tokens;
    compiled.control_command_policy = core.nativeWindowPolicy;
    var a_storage: [128]c.CanvasCommand = undefined;
    var b_storage: [128]c.CanvasCommand = undefined;
    var a = c.Builder.init(a_storage[0..capacity]);
    var b = c.Builder.init(b_storage[0..capacity]);
    var reference_error: ?anyerror = null;
    var compiled_error: ?anyerror = null;
    const nodes = [_]c.WidgetLayoutNode{.{ .widget = widget, .frame = widget.frame, .depth = 0, .parent_index = null }};
    const tree: c.WidgetLayoutTree = .{ .nodes = &nodes, .root_bounds = widget.frame };
    Trace.count = 0;
    if (retained) tree.emitDisplayListWithState(&a, tokens, .{}) catch |err| {
        reference_error = err;
    } else c.emitWidgetTree(&a, widget, tokens) catch |err| {
        reference_error = err;
    };
    const observed = Trace.count;
    const saved = Trace.requests;
    Trace.count = 0;
    if (retained) tree.emitDisplayListWithState(&b, compiled, .{}) catch |err| {
        compiled_error = err;
    } else c.emitWidgetTree(&b, widget, compiled) catch |err| {
        compiled_error = err;
    };
    try std.testing.expectEqual(reference_error, compiled_error);
    try std.testing.expectEqual(observed, Trace.count);
    try exact(saved[0..observed], Trace.requests[0..Trace.count]);
    try exact(a.displayList().commands, b.displayList().commands);
    core.rt.frameReset();
    try exact(a.displayList().commands, b.displayList().commands);
}
const Trace = struct {
    var count: usize = 0;
    var scalar_word: ?u32 = null;
    var requests: [64][512]u8 = undefined;
    fn callback(input: []const u8, output: []u8) usize {
        std.debug.assert(count < requests.len and input.len <= 508);
        @memset(&requests[count], 0);
        std.mem.writeInt(u32, requests[count][0..4], @intCast(input.len), .little);
        @memcpy(requests[count][4..][0..input.len], input);
        count += 1;
        if (scalar_word) |bits| {
            if (input.len == 496 and output.len == 4) {
                std.mem.writeInt(u32, output[0..4], bits, .little);
                return 4;
            }
        }
        return core.nativeWindowPolicy(input, output);
    }
};
test "compiled widget metric leaf programs preserve complete family commands and custom callback order" {
    _ = core.initialModel();
    for (kinds) |kind| for (0..32) |flags| for ([_]c.ThemePack{ .house, .geist }) |pack| {
        var t = c.DesignTokens.theme(.{ .pack = pack });
        t.control_geometry_policy = Trace.callback;
        t.pixel_snap = .{ .geometry = flags & 8 != 0, .text = flags & 16 != 0, .scale = 1.25 };
        const widget: c.Widget = .{ .id = 0xf123456789abcdef, .kind = kind, .frame = .init(-3.125, 7.375, 98.25, 31.75), .text = if (flags & 1 != 0) "" else "Leaf\xff\x00", .icon = if (flags & 2 != 0) "check" else "", .image_id = if (flags & 4 != 0) 0xfedcba9876543210 else 0, .image_src = if (flags & 2 != 0) .init(1.25, 2.5, 16.5, 17.25) else null, .image_fit = if (flags & 8 != 0) .cover else .contain, .image_sampling = .linear, .image_opacity = 0.625, .appearance_policy = Trace.callback, .state = .{ .focused = true, .hovered = flags & 2 != 0, .pressed = flags & 4 != 0, .selected = flags & 8 != 0, .disabled = flags & 16 != 0 } };
        for ([_]bool{ false, true }) |retained| compare(widget, t, retained, 128) catch |err| {
            std.debug.print("leaf {t} flags {d} pack {t} retained {}\n", .{ kind, flags, pack, retained });
            return err;
        };
    };
}
test "compiled widget metric leaf programs preserve every capacity failure prefix and callback admission" {
    _ = core.initialModel();
    for (kinds) |kind| for (0..12) |capacity| for ([_]bool{ false, true }) |retained| {
        var t = c.DesignTokens{};
        t.control_geometry_policy = Trace.callback;
        const widget: c.Widget = .{ .id = std.math.maxInt(u64), .kind = kind, .frame = .init(-1.25, 3.5, 75.5, 28.25), .text = "Full\xff\x00", .icon = "missing-fixture-icon", .image_id = 7, .image_fit = .cover, .appearance_policy = Trace.callback, .state = .{ .focused = true, .hovered = true, .selected = true }, .style = .{ .radius = 7.25, .stroke_width = 1.5, .background = c.Color.rgba(0.125, 0.25, 0.375, 0.625) } };
        compare(widget, t, retained, capacity) catch |err| {
            std.debug.print("leaf prefix {t} capacity {d} retained {}\n", .{ kind, capacity, retained });
            return err;
        };
    };
}
test "compiled widget metric leaf programs preserve negative empty geometry padding styles and exact ids" {
    _ = core.initialModel();
    for (kinds) |kind| for ([_]f32{ -31.25, -0.0, 0, 0.125, 17.5, 92.25 }) |width| for ([_]u64{ 0, 1, 0x1000000000000000, std.math.maxInt(u64) }) |id| for ([_]c.WidgetSize{ .sm, .default, .lg }) |size| {
        var t = c.DesignTokens{};
        t.pixel_snap = .{ .geometry = true, .text = true, .scale = 1.5 };
        const widget: c.Widget = .{ .id = id, .kind = kind, .size = size, .frame = .init(-2.25, -0.0, width, 9.75), .text = "A", .image_id = 3, .icon = "check", .state = .{ .selected = true, .hovered = true }, .layout = .{ .padding = .{ .top = 7.125, .left = 15.5, .right = -0.5, .bottom = 2.125 } }, .style = .{ .radius = -0.0, .stroke_width = 0.25, .foreground = c.Color.rgba(-0.0, 0.625, 1, 0.75) } };
        try compare(widget, t, false, 128);
    };
}
test "compiled widget metric leaf table plans preserve hidden nested and last row selection with clip prefixes" {
    _ = core.initialModel();
    const children = [_]c.Widget{ .{ .id = 10, .kind = .data_row, .frame = .init(1.25, 2.5, 70.25, 12.5) }, .{ .id = 11, .kind = .text }, .{ .id = 12, .kind = .data_row, .semantics = .{ .hidden = true } }, .{ .id = 13, .kind = .data_row, .frame = .init(1.25, 15, -70.25, 12.5) }, .{ .id = 14, .kind = .data_row, .frame = .init(1.25, 27.5, 70.25, 12.5) } };
    var reference = c.DesignTokens{};
    reference.control_geometry_policy = core.nativeWindowPolicy;
    var compiled = reference;
    compiled.control_command_policy = core.nativeWindowPolicy;
    for (0..16) |capacity| for ([_]bool{ false, true }) |clip| {
        const table: c.Widget = .{ .id = 27, .kind = .table, .frame = .init(0, 0, 110, 65), .children = &children, .layout = .{ .clip_content = clip } };
        try compare(table, reference, false, capacity);
        var nodes: [7]c.WidgetLayoutNode = undefined;
        nodes[0] = .{ .widget = table, .frame = table.frame, .parent_index = null, .depth = 0 };
        for (children, 1..) |child, i| nodes[i] = .{ .widget = child, .frame = child.frame, .parent_index = 0, .depth = 1 };
        nodes[6] = .{ .widget = .{ .id = 99, .kind = .data_row }, .frame = .init(0, 0, 20, 20), .parent_index = 1, .depth = 2 };
        const tree: c.WidgetLayoutTree = .{ .nodes = &nodes, .root_bounds = table.frame };
        var as: [128]c.CanvasCommand = undefined;
        var bs: [128]c.CanvasCommand = undefined;
        var a = c.Builder.init(as[0..capacity]);
        var b = c.Builder.init(bs[0..capacity]);
        var ae: ?anyerror = null;
        var be: ?anyerror = null;
        tree.emitDisplayListWithState(&a, reference, .{}) catch |err| {
            ae = err;
        };
        tree.emitDisplayListWithState(&b, compiled, .{}) catch |err| {
            be = err;
        };
        try std.testing.expectEqual(ae, be);
        try exact(a.displayList().commands, b.displayList().commands);
    };
}
test "compiled widget metric leaf copied plans survive nested calls frame reset and preserve caller tails" {
    _ = core.initialModel();
    var t = c.DesignTokens{};
    t.control_command_policy = core.nativeWindowPolicy;
    const leaf = c.leaf_plan_policy;
    const program = leaf.Program.init(t, .avatar, 0, .{ .kind = .avatar, .id = std.math.maxInt(u64) }, .{ .image = true });
    const copy = program;
    const payload = leaf.payload(t, .badge_content, .init(1.25, 2.5, 32.25, 17.5), .{ 12.5, 4, 3.25, 0, 0, 0, 0, 0 }, 1, .nearest);
    const saved = payload;
    _ = leaf.Program.init(t, .image, 0, .{ .kind = .image }, .{});
    core.rt.frameReset();
    try exact(copy.commands[0..copy.count], program.commands[0..program.count]);
    try exact(saved, payload);
    var request: [40]u8 = @splat(0);
    request[0..6].* = .{ 49, 0, 1, 1, 0, 2 };
    var result: [120]u8 = @splat(0xa5);
    try std.testing.expectEqual(104, core.nativeWindowPolicy(&request, &result));
    const saved_bytes = result;
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, &saved_bytes, &result);
    try std.testing.expect(std.mem.allEqual(u8, result[104..], 0xa5));
}

test "compiled widget metric leaf payloads preserve custom scalar words and raw image color style fields" {
    _ = core.initialModel();
    defer Trace.scalar_word = null;
    for ([_]u32{ 0, 0x80000000, 0xc1200000, 0x3f800000, 0x7f800000, 0xff800000, 0x7fc12345, 0x7f812345, 0xff812345 }) |bits| {
        Trace.scalar_word = bits;
        for ([_]c.WidgetKind{ .avatar, .badge, .separator, .split_divider, .skeleton }) |kind| {
            const widget: c.Widget = .{ .id = std.math.maxInt(u64), .kind = kind, .frame = .init(1.25, 2.5, 40.25, 31.5), .text = "", .image_id = 3, .image_opacity = @bitCast(bits), .appearance_policy = Trace.callback, .state = .{ .hovered = true }, .style = .{ .radius = 3.5, .stroke_width = 0.625, .background = c.Color.rgba(@bitCast(bits), -0.0, 0.75, 1) } };
            compare(widget, .{}, false, 128) catch |err| {
                std.debug.print("leaf scalar kind {t} bits {x}\n", .{ kind, bits });
                return err;
            };
        }
    }
}

test "compiled widget metric leaf geometry retains passthrough words and independent text arithmetic" {
    _ = core.initialModel();
    var t = c.DesignTokens{};
    t.control_command_policy = core.nativeWindowPolicy;
    const leaf = c.leaf_plan_policy;
    for ([_]u32{ 0, 0x80000000, 0x3f800000, 0x7f800000, 0xff800000, 0x7fc12345, 0x7f812345 }) |bits| {
        var value: f32 = @bitCast(bits);
        std.mem.doNotOptimizeAway(&value);
        const frame = sdk.geometry.RectF.init(value, value, value, value);
        try exact(frame, leaf.copiedFrame(t, frame));
        const box = leaf.payload(t, .badge_content, frame, .{ 12.25, 3.125, 2.5, 0, 0, 0, 0, 0 }, 1, .nearest);
        try exact(value, box.rects[1].y);
        try exact(value, box.rects[1].height);
        const text_frame = sdk.geometry.RectF.init(1.25, 2.5, 70.25, 31.5);
        const result = leaf.payload(t, .text, text_frame, .{ value, 3.125, 0, 0, 0, 0, 0, 0 }, 0, .nearest);
        const line = value * 1.25;
        const baseline = text_frame.y + @max(value, (text_frame.height - line) * 0.5 + value);
        try exact(line, result.line_height);
        try exact(baseline, result.points[0].y);
    }
}
