//! Complete control command streams through the production scriptc ABI.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const c = sdk.canvas;
const policy = c.control_command_policy;
const exact = @import("component_construction_e2e_tests.zig").exact;
const kinds = [_]c.WidgetKind{ .button, .toggle_button, .input, .icon_button, .select, .text_field, .textarea, .input_group, .search_field, .combobox, .tooltip, .menu_item, .list_item, .data_cell, .segmented_control, .checkbox, .radio, .toggle, .slider, .progress };
fn compare(widget: c.Widget, t: c.DesignTokens, retained: bool, capacity: usize, geometry_owner: bool) !void {
    var reference = t;
    if (geometry_owner) reference.control_geometry_policy = core.nativeWindowPolicy;
    var compiled_tokens = reference;
    compiled_tokens.control_command_policy = core.nativeWindowPolicy;
    var a_storage: [1024]c.CanvasCommand = undefined;
    var b_storage: [1024]c.CanvasCommand = undefined;
    var a = c.Builder.init(a_storage[0..capacity]);
    var b = c.Builder.init(b_storage[0..capacity]);
    const nodes = [_]c.WidgetLayoutNode{.{ .widget = widget, .frame = widget.frame, .depth = 0, .parent_index = null }};
    const tree: c.WidgetLayoutTree = .{ .nodes = &nodes, .root_bounds = widget.frame };
    const a_error: ?anyerror = if (retained) blk: {
        tree.emitDisplayListWithState(&a, reference, .{}) catch |err| break :blk err;
        break :blk null;
    } else blk: {
        c.emitWidgetTree(&a, widget, reference) catch |err| break :blk err;
        break :blk null;
    };
    const b_error: ?anyerror = if (retained) blk: {
        tree.emitDisplayListWithState(&b, compiled_tokens, .{}) catch |err| break :blk err;
        break :blk null;
    } else blk: {
        c.emitWidgetTree(&b, widget, compiled_tokens) catch |err| break :blk err;
        break :blk null;
    };
    try std.testing.expectEqual(a_error, b_error);
    try exact(a.displayList().commands, b.displayList().commands);
    core.rt.frameReset();
    try exact(a.displayList().commands, b.displayList().commands);
}
test "compiled widget metric control command programs preserve every control and theme register" {
    _ = core.initialModel();
    for (kinds) |kind| for (0..64) |flags| for ([_]c.ThemePack{ .house, .geist }) |pack| {
        const widget: c.Widget = .{ .id = 0x123456789abcdef0, .kind = kind, .frame = .init(3.125, 5.25, 253.5, 47.75), .text = if (flags & 16 != 0) "" else "Control\xff\x00", .icon = if (flags & 32 != 0) "missing-icon-fixture" else "", .value = if (flags & 4 != 0) 0.75 else 0, .state = .{ .focused = flags & 1 != 0, .disabled = flags & 2 != 0, .selected = flags & 8 != 0, .hovered = flags & 4 != 0, .pressed = flags & 8 != 0 } };
        var t = c.DesignTokens.theme(.{ .pack = pack });
        t.pixel_snap = .{ .geometry = flags & 8 != 0, .text = flags & 8 != 0, .scale = 1.25 };
        for ([_]bool{ false, true }) |retained| compare(widget, t, retained, 1024, flags & 1 != 0) catch |err| {
            std.debug.print("control {t} flags {d} pack {t} retained {}\n", .{ kind, flags, pack, retained });
            return err;
        };
    };
}
test "compiled widget metric control command programs preserve complete capacity prefixes and owned text paths" {
    _ = core.initialModel();
    for (kinds) |kind| for (0..25) |capacity| {
        const widget: c.Widget = .{ .id = 27, .kind = kind, .frame = .init(0, 0, 94.25, 32.5), .text = "Long editing\xff\x00 text\nsecond line", .icon = "check", .value = 0.5, .state = .{ .focused = true, .selected = true, .hovered = true }, .group_segment = .last };
        for ([_]bool{ false, true }) |retained| try compare(widget, .{}, retained, capacity, true);
    };
}
test "compiled widget metric control command programs preserve numeric admission and raw identities" {
    _ = core.initialModel();
    for ([_]c.WidgetKind{ .checkbox, .radio, .toggle, .slider, .progress, .segmented_control }) |kind|
        for ([_]u32{ 0, 0x80000000, 0x3effffff, 0x3f000000, 0x3f800000, 0x7f800000, 0xff800000, 0x7fc12345, 0x7f812345 }) |bits|
            for ([_]bool{ false, true }) |selected|
                for ([_]u64{ 0, 1, 0xffffffffffffffff }) |id| {
                    const widget: c.Widget = .{ .id = id, .kind = kind, .frame = .init(-2.25, 4.5, 180.25, 32.5), .text = "Numeric", .value = @bitCast(bits), .state = .{ .focused = true, .selected = selected } };
                    for ([_]bool{ false, true }) |geometry_owner| try compare(widget, .{}, false, 1024, geometry_owner);
                };
}
test "compiled widget metric control command programs preserve complete editing placeholder clip and caret sequences" {
    _ = core.initialModel();
    const texts = [_][]const u8{ "", "\n", "Caf\xc3\xa9 long retained value\xff\x00\nsecond line\nthird line" };
    for ([_]c.WidgetKind{ .input, .text_field, .textarea, .search_field, .combobox }) |kind|
        for (texts) |text|
            for (0..8) |pose|
                for ([_]f32{ 0, 52.25, 320.5 }) |width| {
                    const widget: c.Widget = .{ .id = 0x1000000000000001, .kind = kind, .frame = .init(1.25, 2.5, width, 61.5), .text = text, .placeholder = "Placeholder\xff\x00", .value = 12.25, .value_x = 6.5, .state = .{ .focused = pose & 1 != 0, .disabled = pose & 2 != 0 }, .text_selection = if (pose & 4 != 0) .{ .anchor = 0, .focus = 5 } else .{ .anchor = 0, .focus = 0 }, .text_composition = .{ .start = 0, .end = if (pose & 4 != 0) 5 else 0 } };
                    for ([_]usize{ 0, 1, 2, 3, 8, 16, 64, 1024 }) |capacity| try compare(widget, .{}, false, capacity, true);
                    try compare(widget, c.DesignTokens.theme(.{ .pack = .geist }), true, 1024, false);
                };
}
test "compiled widget metric control command programs preserve span cell chrome and empty tab geometry" {
    _ = core.initialModel();
    const spans = [_]c.TextSpan{ .{ .text = "Rich\xff\x00 ", .scale = 1.125 }, .{ .text = "cell", .monospace = true } };
    for ([_]c.WidgetKind{ .data_cell, .segmented_control }) |kind|
        for ([_]f32{ 0, -4, 73.25 }) |width|
            for ([_]bool{ false, true }) |selected| {
                const widget: c.Widget = .{ .id = 41, .kind = kind, .frame = .init(-1.25, 3.5, width, 32.5), .text = "", .spans = &spans, .icon = "check", .state = .{ .focused = true, .selected = selected }, .style = .{ .border = c.Color.rgb8(9, 28, 53), .stroke_width = 0.5, .radius = 2.5 } };
                for ([_]c.ThemePack{ .house, .geist }) |pack| for ([_]bool{ false, true }) |retained| for ([_]usize{ 0, 1, 2, 3, 8, 1024 }) |capacity| try compare(widget, c.DesignTokens.theme(.{ .pack = pack }), retained, capacity, true);
            };
}
test "compiled widget metric copied control programs survive nested policy calls and preserve caller tails" {
    _ = core.initialModel();
    const facts: policy.Facts = .{ .focused = true, .text = true, .selection = true, .selection_range = true, .composition = true, .composition_range = true, .clip = true };
    const program = policy.Program.init(core.nativeWindowPolicy, .text_field, facts);
    const copy = program;
    _ = policy.Program.init(core.nativeWindowPolicy, .button, .{ .icon = true, .stroke_width = 1, .seam = true });
    core.rt.frameReset();
    try exact(copy.commands[0..copy.count], program.commands[0..program.count]);
    var request: [32]u8 = @splat(0);
    request[0..4].* = .{ 45, 1, @intFromEnum(policy.Family.checkbox), 0 };
    var result: [216]u8 = @splat(0xa5);
    try std.testing.expectEqual(200, core.nativeWindowPolicy(&request, &result));
    const saved = result;
    _ = policy.Program.init(core.nativeWindowPolicy, .slider, .{ .bar = true });
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, &saved, &result);
    try std.testing.expect(std.mem.allEqual(u8, result[200..], 0xa5));
}

test "compiled widget metric payload programs preserve custom color overrides disabled swaps and complete error prefixes" {
    _ = core.initialModel();
    for (kinds) |kind| for (0..16) |flags| for ([_]c.ThemePack{ .house, .geist }) |pack| {
        var tokens = c.DesignTokens.theme(.{ .pack = pack });
        const swap = c.Color.rgba(0.125, 0.375, 0.625, 0.75);
        if (flags & 1 != 0) tokens.controls.slider.disabled_background = swap;
        if (flags & 2 != 0) tokens.controls.slider.disabled_foreground = swap;
        const widget: c.Widget = .{ .id = 0xfffffffffffff001, .kind = kind, .frame = .init(-3.125, 2.375, 113.25, 31.25), .text = "Caf\xc3\xa9\xff\x00", .icon = "check", .value = if (flags & 4 != 0) 0.5 else 0.49999997, .group_segment = .last, .state = .{ .disabled = true, .focused = true, .hovered = true, .selected = flags & 8 != 0 }, .style = .{ .background = if (flags & 1 != 0) swap else null, .foreground = if (flags & 2 != 0) swap else null, .border = if (flags & 4 != 0) swap else null, .quiet_hover = true } };
        for ([_]bool{ false, true }) |retained| for ([_]usize{ 0, 1, 2, 3, 4, 8, 1024 }) |capacity| try compare(widget, tokens, retained, capacity, flags & 1 != 0);
    };
}

test "compiled widget metric payload results survive nested policy calls and frame resets" {
    _ = core.initialModel();
    var tokens: c.DesignTokens = .{};
    tokens.control_command_policy = core.nativeWindowPolicy;
    const payload = c.control_payload_policy;
    const saved = payload.frames(.checkmark, .init(1.25, -3.75, 17.25, 17.25), .{ 0, 0, 0, 0 }, .init(0, 0, 0, 0), tokens);
    _ = payload.color(.{ .id = 1, .kind = .slider, .frame = .init(0, 0, 10, 10) }, tokens, .{}, .slider, .fill);
    core.rt.frameReset();
    try exact(saved, payload.frames(.checkmark, .init(1.25, -3.75, 17.25, 17.25), .{ 0, 0, 0, 0 }, .init(0, 0, 0, 0), tokens));
    var request: [128]u8 = @splat(0);
    request[0..4].* = .{ 46, 1, 0, 0 };
    var result: [80]u8 = @splat(0xa5);
    try std.testing.expectEqual(64, core.nativeWindowPolicy(&request, &result));
    try std.testing.expect(std.mem.allEqual(u8, result[64..], 0xa5));
}

test "compiled widget metric payload geometry preserves native float words across every operation" {
    _ = core.initialModel();
    var tokens: c.DesignTokens = .{};
    tokens.control_command_policy = core.nativeWindowPolicy;
    const payload = c.control_payload_policy;
    for (std.enums.values(payload.Operation)) |op| for ([_]u32{ 0, 0x80000000, 1, 0x3f800000, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc12345, 0x7f812345 }) |word| for (0..12) |channel| {
        var inputs = [_]f32{ -3.25, 2.5, 113.25, 31.25, 12.25, 8.5, 4.25, 0.5, -4.25, 1.5, 9.25, 10.5 };
        inputs[channel] = @bitCast(word);
        const x = inputs[0];
        const y = inputs[1];
        const width = inputs[2];
        const height = inputs[3];
        const size = inputs[4];
        const inset = inputs[5];
        const gap = inputs[6];
        const stroke = inputs[7];
        const frame = sdk.geometry.RectF.init(x, y, width, height);
        const aux = sdk.geometry.RectF.init(inputs[8], inputs[9], inputs[10], inputs[11]);
        var expected = [_]sdk.geometry.RectF{ .init(0, 0, 0, 0), .init(0, 0, 0, 0), .init(0, 0, 0, 0) };
        switch (op) {
            .seam => {
                const left = aux.x + size * 0.5;
                expected[0] = .init(left, y - stroke, @max(0, x + width + stroke - left), height + stroke * 2);
            },
            .select => {
                expected[0] = .init(x + inset, y, @max(1, width - inset * 2 - (size + inset)), height);
                expected[1] = .init(x + width - inset - size, y + (height - size) * 0.5, size, size);
            },
            .centered_icon => {
                expected[0] = .init(x + (width - size) * 0.5, y + (height - size) * 0.5, size, size);
            },
            .search_icon => {
                const extent = @max(8, size - 2);
                expected[0] = .init(x + inset, y + @max(0, (height - extent) * 0.5), extent, extent);
            },
            .menu => {
                expected[0] = .init(x, y, @max(1, width - size - gap), height);
                expected[1] = .init(x + inset, y + (height - size) * 0.5, size, size);
                expected[2] = .init(x + width - inset - size, y + (height - size) * 0.5, size, size);
            },
            .list, .shifted_label => {
                const shift = size + gap;
                expected[0] = .init(x + shift, y, @max(1, width - shift), height);
                if (op == .list) expected[1] = .init(x + inset, y + (height - size) * 0.5, size, size);
            },
            .checkmark => {
                expected[0] = .init(x + width * 0.26, y + height * 0.54, 0, 0);
                expected[1] = .init(x + width * 0.43, y + height * 0.70, 0, 0);
                expected[2] = .init(x + width * 0.76, y + height * 0.32, 0, 0);
            },
            .radio_dot => {
                const dot = @max(0, height * 0.5);
                expected[0] = .init(x + (width - dot) * 0.5, y + (height - dot) * 0.5, dot, dot);
            },
            .progress_radius => {
                expected[0] = .init(@min(size, height * 0.5), 0, 0, 0);
            },
            .slider_radius => {
                expected[0] = .init(height * 0.5, @min(aux.width, aux.height) * 0.5, 0, 0);
            },
            .label_x => {
                expected[0] = .init(x + width + inset, 0, 0, 0);
            },
        }
        exact(expected, payload.frames(op, frame, .{ size, inset, gap, stroke }, aux, tokens)) catch |err| {
            std.debug.print("payload geometry mismatch op={t} word={x} channel={d}\n", .{ op, word, channel });
            return err;
        };
    };
}

test "compiled widget metric primitive identities match exact native wrapping and Wyhash" {
    _ = core.initialModel();
    var tokens: c.DesignTokens = .{};
    tokens.control_command_policy = core.nativeWindowPolicy;
    const ids = [_]u64{ 0, 1, 0xffffffff, 0x100000000, 0x1000000000000000, 0x8000000000000000, 0xffffffffffffffff };
    for (ids) |id| for (ids) |slot| {
        const value = id *% 16 +% slot;
        try std.testing.expectEqual(if (id == 0) 0 else if (value == 0) id else value, c.control_primitive_policy.partId(tokens, id, slot));
    };
    for ([_]u64{ 0, 0xffffffffffffffff, 0x5eed59a200000005, 0x5eed59a200000006 }) |seed| for (0..200) |i| {
        const id = @as(u64, i) *% 0x9e3779b97f4a7c15;
        const ordinal = @as(u64, i) *% 0xd6e8feb86659fd93;
        var hash = std.hash.Wyhash.init(seed);
        hash.update(std.mem.asBytes(&id));
        hash.update(std.mem.asBytes(&ordinal));
        const expected = hash.final();
        try std.testing.expectEqual(if (expected == 0) 1 else expected, c.control_primitive_policy.overlayId(tokens, seed, id, ordinal));
    };
}

test "compiled widget metric primitive radii match optional precedence size steps and raw numeric words" {
    _ = core.initialModel();
    const words = [_]u32{ 0, 0x80000000, 0x3f800000, 0x40800000, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc12345, 0x7f812345 };
    var tokens: c.DesignTokens = .{};
    tokens.control_command_policy = core.nativeWindowPolicy;
    for ([_]c.WidgetSize{ .default, .sm, .lg, .icon, .heading, .display }) |size|
        for (words) |bits|
            for (0..8) |presence|
                for ([_]bool{ false, true }) |owner| {
                    var widget: c.Widget = .{ .id = 1, .kind = .radio, .frame = .init(0, 0, 30, 30), .size = size };
                    widget.style.radius = if (presence & 1 != 0) @bitCast(bits) else null;
                    if (owner) widget.appearance_policy = core.nativeWindowPolicy;
                    const visual: c.ControlVisualTokens = .{ .radius = if (presence & 2 != 0) @bitCast(bits) else null };
                    const fallback: f32 = @bitCast(bits);
                    const reference = if (presence & 3 != 0) c.WidgetAppearance.controlRadius(widget, visual, fallback) else c.Radius.all(@max(0, fallback));
                    const actual = c.control_primitive_policy.radius(.selection, widget, visual, fallback, tokens);
                    exact(reference, actual) catch |err| {
                        std.debug.print("selection radius size {t} bits {x} presence {d} owner {}\n", .{ size, bits, presence, owner });
                        return err;
                    };
                    for ([_]bool{ false, true }) |underline| {
                        tokens.controls.tabs_indicator = if (underline) .underline else .pill;
                        tokens.controls.tabs.radius = if (presence & 4 != 0) @bitCast(bits) else null;
                        tokens.radius.lg = fallback;
                        const expected = if (widget.style.radius) |v| @max(0, v) else if (visual.radius) |v| @max(0, c.WidgetAppearance.widgetSizedRadiusValue(widget, v)) else if (underline) 0 else @max(0, c.WidgetAppearance.widgetSizedRadiusValue(widget, tokens.controls.tabs.radius orelse tokens.radius.lg) - 3);
                        const tab = c.control_primitive_policy.radius(.tab, widget, visual, fallback, tokens);
                        exact(c.Radius.all(expected), tab) catch |err| {
                            std.debug.print("tab radius size {t} bits {x} presence {d} owner {} underline {}\n", .{ size, bits, presence, owner, underline });
                            return err;
                        };
                    }
                };
}

test "compiled widget metric vector plans preserve complete path commands style words and capacity prefixes" {
    _ = core.initialModel();
    const elements = [_]c.PathElement{ .{ .verb = .move_to, .points = .{ .init(1, 2), .{}, .{} } }, .{ .verb = .line_to, .points = .{ .init(7, 4), .{}, .{} } }, .{ .verb = .close } };
    const frames = [_]sdk.geometry.RectF{ .init(3.125, -5.25, 27.5, 13.25), .init(10, 20, -40, -30), .init(0, 0, 0, 10), .init(0, 0, 0.001, 0.001), .init(-0.0, 0, 72, 72) };
    const current = c.Color.rgba(@bitCast(@as(u32, 0x7f812345)), -0.0, 0.75, 1);
    const literal = c.Color.rgba(0.125, 0.5, @bitCast(@as(u32, 0x7fc12345)), 0.625);
    var compiled: c.DesignTokens = .{};
    compiled.control_command_policy = core.nativeWindowPolicy;
    const paints = [_]c.svg_icon.Paint{ .none, .current_color, .{ .color = literal } };
    for (paints) |fill| for (paints) |stroke| for ([_]c.LineCap{ .butt, .round }) |cap| for ([_]f32{ -1, 0, 0.5, std.math.inf(f32), std.math.nan(f32) }) |width| {
        const shapes = [_]c.svg_icon.IconShape{ .{ .start = 0, .len = 3, .style = .{ .fill = fill, .stroke = stroke, .stroke_width = width, .linecap = cap } }, .{ .start = 1, .len = 1, .style = .{ .fill = stroke, .stroke = fill, .stroke_width = 1.25, .linecap = cap } } };
        const icon: c.svg_icon.Icon = .{ .view_box = .init(1.25, -2.5, 20.5, 17.25), .elements = &elements, .shapes = &shapes };
        for (frames) |frame| for (0..9) |capacity| {
            var a_storage: [12]c.CanvasCommand = undefined;
            var b_storage: [12]c.CanvasCommand = undefined;
            var a = c.Builder.init(a_storage[0..capacity]);
            var b = c.Builder.init(b_storage[0..capacity]);
            const a_error: ?anyerror = blk: {
                c.emitVectorIcon(&a, 0xffffffffffffffff, 3, frame, current, &icon, .{}) catch |err| break :blk err;
                break :blk null;
            };
            const b_error: ?anyerror = blk: {
                c.emitVectorIcon(&b, 0xffffffffffffffff, 3, frame, current, &icon, compiled) catch |err| break :blk err;
                break :blk null;
            };
            try std.testing.expectEqual(a_error, b_error);
            try exact(a.displayList().commands, b.displayList().commands);
            core.rt.frameReset();
            try exact(a.displayList().commands, b.displayList().commands);
        };
    };
}

test "compiled widget metric primitive radii preserve custom appearance calls and exact scalar results" {
    _ = core.initialModel();
    const Owner = struct {
        var result_word: u32 = 0;
        var calls: usize = 0;
        var request: [496]u8 = @splat(0);
        fn callback(input: []const u8, output: []u8) usize {
            std.debug.assert(input.len == request.len and output.len == 4);
            @memcpy(&request, input);
            calls += 1;
            std.mem.writeInt(u32, output[0..4], result_word, .little);
            return 4;
        }
    };
    for ([_]u32{ 0xc1200000, 0x80000000, 0, 0x41a20000, 0x7fc12345, 0x7f812345 }) |bits|
        for (0..6) |size|
            for (0..4) |presence|
                for ([_]bool{ false, true }) |underline|
                    for ([_]bool{ false, true }) |container| {
                        var widget: c.Widget = .{ .kind = .segmented_control, .size = @enumFromInt(size), .appearance_policy = Owner.callback };
                        if (presence & 1 != 0) widget.style.radius = 7.25;
                        const visual: c.ControlVisualTokens = .{ .radius = if (presence & 2 != 0) 9.5 else null };
                        var tokens = c.DesignTokens{};
                        tokens.control_command_policy = core.nativeWindowPolicy;
                        tokens.radius.lg = 29;
                        tokens.controls.tabs.radius = if (container) 17 else null;
                        tokens.controls.tabs_indicator = if (underline) .underline else .pill;
                        Owner.result_word = bits;
                        for ([_]c.control_primitive_policy.RadiusKind{ .selection, .tab }) |kind| {
                            Owner.calls = 0;
                            const expected = if (kind == .selection)
                                if (presence != 0) c.WidgetAppearance.controlRadius(widget, visual, 12.5) else c.Radius.all(12.5)
                            else c.Radius.all(if (widget.style.radius) |v| @max(0, v) else if (visual.radius) |v| @max(0, c.WidgetAppearance.widgetSizedRadiusValue(widget, v)) else if (underline) 0 else @max(0, c.WidgetAppearance.widgetSizedRadiusValue(widget, tokens.controls.tabs.radius orelse tokens.radius.lg) - 3));
                            const expected_calls: usize = @intFromBool(if (kind == .selection) presence != 0 else presence & 1 == 0 and (presence & 2 != 0 or !underline));
                            try std.testing.expectEqual(expected_calls, Owner.calls);
                            const expected_request = Owner.request;
                            if (expected_calls != 0) {
                                try std.testing.expectEqual(@as(u8, if (kind == .selection) 19 else 22), expected_request[1]);
                                // Radius helpers pass the default token register, even when
                                // the enclosing tab supplies a different container radius.
                                const default_tokens = c.DesignTokens{};
                                try std.testing.expectEqual(@as(u32, @bitCast(default_tokens.radius.lg)), std.mem.readInt(u32, expected_request[440..444], .little));
                            }
                            Owner.calls = 0;
                            const actual = c.control_primitive_policy.radius(kind, widget, visual, 12.5, tokens);
                            try std.testing.expectEqual(expected_calls, Owner.calls);
                            if (expected_calls != 0) try std.testing.expectEqualSlices(u8, &expected_request, &Owner.request);
                            try exact(expected, actual);
                            core.rt.frameReset();
                            try exact(expected, actual);
                        }
                    };
}

test "compiled widget metric primitive result copies preserve caller tails nested calls and frame reset ownership" {
    _ = core.initialModel();
    var request: [32]u8 = @splat(0);
    request[0..3].* = .{ 47, 1, 1 };
    std.mem.writeInt(u64, request[8..16], 0x5eed59a200000005, .little);
    std.mem.writeInt(u64, request[16..24], 0xffffffffffffffff, .little);
    std.mem.writeInt(u64, request[24..32], 0x100000000, .little);
    const saved_request = request;
    var result: [24]u8 = @splat(0xa5);
    try std.testing.expectEqual(8, core.nativeWindowPolicy(&request, &result));
    const copy = result;
    var tokens: c.DesignTokens = .{};
    tokens.control_command_policy = core.nativeWindowPolicy;
    const plan = c.control_primitive_policy.transform(.init(1.25, 3.5, 17, 31), .init(0, 0, 24, 24), tokens).?;
    const saved_plan = plan;
    request[1] = 0;
    std.mem.writeInt(u64, request[24..32], 0, .little);
    _ = core.nativeWindowPolicy(&request, &result);
    core.rt.frameReset();
    try exact(plan, saved_plan);
    try std.testing.expect(std.mem.allEqual(u8, result[8..], 0xa5));
    try std.testing.expectEqual(8, core.nativeWindowPolicy(&saved_request, &result));
    try std.testing.expectEqualSlices(u8, &copy, &result);
}

test "compiled widget metric vector transforms preserve numeric words and determinant admission" {
    _ = core.initialModel();
    var tokens: c.DesignTokens = .{};
    tokens.control_command_policy = core.nativeWindowPolicy;
    var words = [_]u32{ 0, 0x80000000, 0x3a800000, 0x3f800000, 0xbf800000, 0x42000000, 0x7f800000, 0xff800000, 0x7fc12345, 0x7f812345 };
    std.mem.doNotOptimizeAway(&words);
    for (0..8) |field| for (words) |bits| {
        var frame: sdk.geometry.RectF = .init(3.125, -5.25, 27.5, 13.25);
        var box: sdk.geometry.RectF = .init(1.25, -2.5, 20.5, 17.25);
        const value: f32 = @bitCast(bits);
        switch (field) {
            0 => frame.x = value,
            1 => frame.y = value,
            2 => frame.width = value,
            3 => frame.height = value,
            4 => box.x = value,
            5 => box.y = value,
            6 => box.width = value,
            7 => box.height = value,
            else => unreachable,
        }
        const normalized = frame.normalized();
        const scale = @min(normalized.width / box.width, normalized.height / box.height);
        const expected: ?c.control_primitive_policy.Transform = blk: {
            if (normalized.isEmpty() or !(scale > 0)) break :blk null;
            const forward: c.Affine = .{ .a = scale, .b = 0, .c = 0, .d = scale, .tx = normalized.x + (normalized.width - box.width * scale) * 0.5 - box.x * scale, .ty = normalized.y + (normalized.height - box.height * scale) * 0.5 - box.y * scale };
            break :blk .{ .forward = forward, .inverse = forward.inverse() orelse break :blk null };
        };
        exact(expected, c.control_primitive_policy.transform(frame, box, tokens)) catch |err| {
            std.debug.print("vector transform field {d} bits {x}\n", .{ field, bits });
            return err;
        };
        core.rt.frameReset();
    };
}
