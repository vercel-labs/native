const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
test "compiled modal view records match native construction" {
    try @import("surface_decoder").testModalRecords();
}
extern fn nsc_core_native_view(out: *[*]const u8, len: *usize) callconv(.c) void;

const samples = [_]f32{ -std.math.inf(f32), -16777216, -240.00002, -1, -0.0, 0, 0.000001, 1.0000001, 23.999998, 24, 24.000002, 239.99998, 240, 240.00002, 16777216, std.math.inf(f32), std.math.nan(f32) };

fn expectRect(expected: geometry.RectF, actual: geometry.RectF) !void {
    inline for (.{ "x", "y", "width", "height" }) |field| {
        const left = @field(expected, field);
        const right = @field(actual, field);
        if (std.math.isNan(left)) try std.testing.expect(std.math.isNan(right)) else try std.testing.expectEqual(@as(u32, @bitCast(left)), @as(u32, @bitCast(right)));
    }
}

fn expectComplete(expected: anytype, actual: @TypeOf(expected)) anyerror!void {
    const T = @TypeOf(expected);
    switch (@typeInfo(T)) {
        .float => if (std.math.isNan(expected)) try std.testing.expect(std.math.isNan(actual)) else try std.testing.expectEqual(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(expected)), @as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(actual))),
        .@"struct" => |info| inline for (info.fields) |field| try expectComplete(@field(expected, field.name), @field(actual, field.name)),
        .optional => {
            try std.testing.expectEqual(expected != null, actual != null);
            if (expected) |value| try expectComplete(value, actual.?);
        },
        .pointer => |info| if (info.size == .slice) {
            try std.testing.expectEqual(expected.len, actual.len);
            for (expected, actual) |left, right| try expectComplete(left, right);
        } else try std.testing.expectEqual(expected, actual),
        .array => for (expected, actual) |left, right| try expectComplete(left, right),
        .@"union" => |info| if (info.tag_type != null) {
            try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
            switch (expected) {
                inline else => |value, tag| try expectComplete(value, @field(actual, @tagName(tag))),
            }
        } else @compileError("untagged value in layout evidence"),
        else => try std.testing.expectEqual(expected, actual),
    }
}

test "compiled modal defaults and f32 boundaries match the native reference" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]canvas.BuiltinComponentKind{ .dialog, .drawer, .sheet, .card }) |kind| {
        var values = [_]f32{ -0.0, 0.125, 800.00006, 599.99994, 320.00003, 160.00002, 24 };
        for (0..values.len) |axis| {
            const original = values[axis];
            for (samples) |sample| {
                values[axis] = sample;
                const options = canvas.BuiltinSurfacePlacementOptions{ .bounds = .init(values[0], values[1], values[2], values[3]), .preferred_size = .init(values[4], values[5]), .margin = values[6] };
                var compiled_options = options;
                compiled_options.surface_layout_policy = core.nativeWindowPolicy;
                const expected = canvas.builtinSurfaceFrame(kind, options);
                const actual = canvas.builtinSurfaceFrame(kind, compiled_options);
                try std.testing.expectEqual(expected != null, actual != null);
                if (expected) |value| try expectRect(value, actual.?);
                core.rt.frameReset();
            }
            values[axis] = original;
        }
    }
}

test "compiled anchors preserve every placement alignment point constraint and f32 field" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]canvas.WidgetAnchorPlacement{ .below, .above }) |placement| {
        for ([_]canvas.WidgetAnchorAlignment{ .start, .end, .stretch }) |alignment| {
            for ([_]bool{ false, true }) |point| {
                var values = [_]f32{ -0.0, 0.125, 800.00006, 599.99994, 700, 560, 72, 24, 160.00002, 80.00001, 0.25, 0.125, 320, 240, 4, 790, 590 };
                for (0..values.len) |axis| {
                    const original = values[axis];
                    for (samples) |sample| {
                        // Safety builds assert finite clamp bounds. ReleaseFast
                        // compares nonfinite native arithmetic as well.
                        if ((builtin.mode == .Debug or builtin.mode == .ReleaseSafe) and !std.math.isFinite(sample)) continue;
                        values[axis] = sample;
                        const child = canvas.Widget{ .id = 1, .kind = .popover, .frame = .init(0, 0, values[8], values[9]), .layout = .{ .min_size = .init(values[10], values[11]), .max_size = .init(values[12], values[13]) } };
                        const anchor = canvas.WidgetAnchor{ .placement = placement, .alignment = alignment, .offset = values[14], .point = if (point) .init(values[15], values[16]) else null };
                        const window = geometry.RectF.init(values[0], values[1], values[2], values[3]);
                        const anchor_rect = geometry.RectF.init(values[4], values[5], values[6], values[7]);
                        const expected = canvas.anchoredWidgetFrame(child, anchor, anchor_rect, window, .{});
                        const actual = canvas.anchoredWidgetFrame(child, anchor, anchor_rect, window, .{ .surface_layout_policy = core.nativeWindowPolicy });
                        expectRect(expected, actual) catch |err| {
                            std.debug.print("anchor placement={t} alignment={t} point={} axis={d} sample={d}; native={any} compiled={any}\n", .{ placement, alignment, point, axis, sample, expected, actual });
                            return err;
                        };
                        core.rt.frameReset();
                    }
                    values[axis] = original;
                }
            }
        }
    }
}

fn expectTree(widget: canvas.Widget, bounds: geometry.RectF, tokens: canvas.DesignTokens) !void {
    var reference_nodes: [32]canvas.WidgetLayoutNode = undefined;
    var compiled_nodes: [32]canvas.WidgetLayoutNode = undefined;
    const expected = try canvas.layoutWidgetTreeWithTokens(widget, bounds, tokens, &reference_nodes);
    var compiled_tokens = tokens;
    compiled_tokens.surface_layout_policy = core.nativeWindowPolicy;
    const actual = try canvas.layoutWidgetTreeWithTokens(widget, bounds, compiled_tokens, &compiled_nodes);
    try std.testing.expectEqual(expected.nodes.len, actual.nodes.len);
    for (expected.nodes, actual.nodes) |left, right| {
        try std.testing.expectEqual(left.parent_index, right.parent_index);
        try std.testing.expectEqual(left.depth, right.depth);
        try expectRect(left.frame, right.frame);
        try expectRect(left.widget.frame, right.widget.frame);
        var authored_left = left.widget;
        var authored_right = right.widget;
        authored_left.frame = .{};
        authored_right.frame = .{};
        try expectComplete(authored_left, authored_right);
    }
    var expected_semantics: [32]canvas.WidgetSemanticsNode = undefined;
    var actual_semantics: [32]canvas.WidgetSemanticsNode = undefined;
    try expectComplete(try expected.collectSemantics(&expected_semantics), try actual.collectSemantics(&actual_semantics));
    var expected_commands: [512]canvas.CanvasCommand = undefined;
    var actual_commands: [512]canvas.CanvasCommand = undefined;
    var expected_builder = canvas.Builder.init(&expected_commands);
    var actual_builder = canvas.Builder.init(&actual_commands);
    try expected.emitDisplayList(&expected_builder, tokens);
    try actual.emitDisplayList(&actual_builder, compiled_tokens);
    try expectComplete(expected_builder.displayList().commands, actual_builder.displayList().commands);
}

test "compiled tree placement preserves nested modals anchors and leading trailing caption clearance" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const anchor_child = canvas.Widget{ .id = 8, .kind = .dropdown_menu, .frame = .init(0, 0, 180, 100), .layout = .{ .anchor = .{ .alignment = .end } }, .children = &.{.{ .id = 9, .kind = .menu_item, .text = "Item" }} };
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .text = "Leading", .children = &.{anchor_child} },
        .{ .id = 3, .kind = .text, .text = "Trailing", .layout = .{ .grow = 1 } },
        .{ .id = 4, .kind = .dialog, .frame = .init(0, 0, 240, 120), .children = &.{.{ .id = 7, .kind = .text, .text = "Modal" }} },
        .{ .id = 5, .kind = .drawer, .frame = .init(0, 0, 180, 100) },
        .{ .id = 6, .kind = .sheet, .frame = .init(0, 0, 160, 80) },
    };
    const root = canvas.Widget{ .id = 1, .kind = .row, .window_drag = true, .children = &children };
    for ([_]f32{ 0, 1.0000001, 24.000002, 240.00002, 800.00006 }) |width| {
        for ([_]?geometry.RectF{ null, .init(0, 0, 80, 30), .init(width - 80, 0, 80, 30), .init(-10, -10, -80, -30), .init(2000, 0, 80, 30) }) |controls| {
            try expectTree(root, .init(10, 20, width, 400), .{ .window_controls = controls });
            core.rt.frameReset();
        }
    }
    for ([_]canvas.WidgetKind{ .dialog, .drawer, .sheet }) |kind| {
        for (samples) |sample| {
            const modal_widget = canvas.Widget{ .id = 1, .kind = kind, .frame = .init(0, 0, sample, sample), .layout = .{ .min_size = .init(0.25, 0.5), .max_size = .init(320, 240) }, .children = &.{.{ .id = 2, .kind = .text, .text = "Measured native text" }} };
            try expectTree(modal_widget, .init(0.125, -0.0, 800.00006, 599.99994), .{});
            core.rt.frameReset();
        }
    }
}

test "surface plans copy outputs without collecting borrowed core data" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const borrowed = core.rt.frameAlloc(u8, 9);
    @memcpy(borrowed, "keep\x00\xffabi");
    var view: [*]const u8 = undefined;
    var view_len: usize = 0;
    nsc_core_native_view(&view, &view_len);
    try std.testing.expect(view_len > 0);
    const owned_view = try std.testing.allocator.dupe(u8, view[0..view_len]);
    defer std.testing.allocator.free(owned_view);
    const first = canvas.builtinSurfaceFrame(.dialog, .{ .bounds = .init(0, 0, 640, 480), .surface_layout_policy = core.nativeWindowPolicy }).?;
    _ = canvas.builtinSurfaceFrame(.sheet, .{ .bounds = .init(0, 0, 320, 240), .surface_layout_policy = core.nativeWindowPolicy });
    try std.testing.expectEqualSlices(u8, "keep\x00\xffabi", borrowed);
    try std.testing.expectEqualSlices(u8, owned_view, view[0..view_len]);
    core.rt.frameReset();
    try expectRect(.init(110, 130, 420, 220), first);
}

test "caption clearance matches native intersection with nonfinite and rounded geometry" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const root = canvas.Widget{ .id = 1, .kind = .row, .window_drag = true, .children = &.{.{ .id = 2, .kind = .panel, .layout = .{ .grow = 1 } }} };
    var values = [_]f32{ -0.0, 0.125, 800.00006, 40.000004, 0, 0, 80.00001, 30 };
    for (0..values.len) |axis| {
        const original = values[axis];
        for (samples) |sample| {
            values[axis] = sample;
            try expectTree(root, .init(values[0], values[1], values[2], values[3]), .{ .window_controls = .init(values[4], values[5], values[6], values[7]) });
            core.rt.frameReset();
        }
        values[axis] = original;
    }
}

test "TypeScript app adapter supplies placement through every theme path" {
    const Adapter = native_sdk.TsUiApp(core);
    const Factory = struct {
        fn tokens(_: *const core.Model) canvas.DesignTokens {
            return .{};
        }
        fn view(ui: *Adapter.App.Ui, _: *const core.Model) Adapter.App.Ui.Node {
            return ui.spacer(1);
        }
        fn windowView(ui: *Adapter.App.Ui, model: *const core.Model, _: []const u8) Adapter.App.Ui.Node {
            return view(ui, model);
        }
    };
    for (0..3) |mode| {
        const app = try Adapter.create(std.testing.allocator, .{}, .{ .name = "surface-layout", .scene = .{}, .canvas_label = "canvas", .view = Factory.view, .window_view = Factory.windowView, .tokens = if (mode == 1) .{} else null, .tokens_fn = if (mode == 2) Factory.tokens else null });
        defer app.destroy();
        const tokens = app.effectiveTokens().withOverrides(.{});
        try std.testing.expect(tokens.surface_layout_policy == core.nativeWindowPolicy);
    }
}

test "app token paths retain adapter placement and consume supplied frames" {
    const Model = struct { count: u8 = 0 };
    const Msg = union(enum) { tick: void };
    const App = native_sdk.UiApp(Model, Msg);
    const Factory = struct {
        fn tokens(_: *const Model) canvas.DesignTokens {
            return .{};
        }
        fn view(ui: *App.Ui, _: *const Model) App.Ui.Node {
            return ui.spacer(1);
        }
        fn update(_: *Model, _: Msg) void {}
        fn policy(_: []const u8, output: []u8) usize {
            output[0] = 1;
            for ([_]f32{ 11, 13, 17, 19 }, 0..) |value, i| std.mem.writeInt(u32, output[1 + i * 4 ..][0..4], @bitCast(value), .little);
            return 17;
        }
    };
    for (0..3) |mode| {
        const app = try App.create(std.testing.allocator, .{ .name = "surface-layout", .scene = .{}, .canvas_label = "canvas", .surface_layout_policy = Factory.policy, .view = Factory.view, .update = Factory.update, .tokens = if (mode == 1) .{} else null, .tokens_fn = if (mode == 2) Factory.tokens else null });
        defer app.destroy();
        const tokens = app.effectiveTokens().withOverrides(.{});
        try std.testing.expect(tokens.surface_layout_policy == Factory.policy);
        var nodes: [1]canvas.WidgetLayoutNode = undefined;
        const tree = try canvas.layoutWidgetTreeWithTokens(.{ .id = 1, .kind = .dialog }, .init(0, 0, 640, 480), tokens, &nodes);
        try expectRect(.init(11, 13, 17, 19), tree.nodes[0].frame);
    }
}

test "nested anchors relayout against retained scrolled parents and window bounds" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const tooltip = canvas.Widget{ .id = 4, .kind = .tooltip, .frame = .init(0, 0, 180, 40), .layout = .{ .anchor = .{ .placement = .above, .alignment = .end } } };
    const menu = canvas.Widget{ .id = 3, .kind = .dropdown_menu, .frame = .init(0, 0, 240, 140), .layout = .{ .anchor = .{ .alignment = .stretch } }, .children = &.{tooltip} };
    const root = canvas.Widget{ .id = 1, .kind = .stack, .children = &.{.{ .id = 2, .kind = .button, .frame = .init(200, 300, 160, 24), .children = &.{menu} }} };
    for ([_]f32{ -300.00003, -24.000002, 0, 30.000002, 300.00003 }) |offset| {
        var reference_nodes: [4]canvas.WidgetLayoutNode = undefined;
        var compiled_nodes: [4]canvas.WidgetLayoutNode = undefined;
        const expected = try canvas.layoutWidgetTreeWithTokens(root, .init(0, 0, 640, 480), .{}, &reference_nodes);
        const tokens = canvas.DesignTokens{ .surface_layout_policy = core.nativeWindowPolicy };
        const actual = try canvas.layoutWidgetTreeWithTokens(root, .init(0, 0, 640, 480), tokens, &compiled_nodes);
        reference_nodes[1].frame.y += offset;
        compiled_nodes[1].frame.y += offset;
        try canvas.relayoutAnchoredChildrenWithRootBounds(reference_nodes[0..expected.nodes.len], .init(0, 0, 600, 400), .{});
        try canvas.relayoutAnchoredChildrenWithRootBounds(compiled_nodes[0..actual.nodes.len], .init(0, 0, 600, 400), tokens);
        try expectComplete(expected.nodes, actual.nodes);
        core.rt.frameReset();
    }
}

test "surface planning bounded call cost is measured beside the native reference" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var elapsed: [2]i128 = undefined;
    for (0..2) |lane| {
        const started = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
        for (0..1000) |i| {
            const anchor_rect = geometry.RectF.init(@floatFromInt(i % 640), 360, 80, 24);
            const result = canvas.anchoredWidgetFrame(.{ .id = 1, .kind = .popover, .frame = .init(0, 0, 240, 120) }, .{}, anchor_rect, .init(0, 0, 640, 480), .{ .surface_layout_policy = if (lane == 1) core.nativeWindowPolicy else null });
            std.mem.doNotOptimizeAway(result);
            core.rt.frameReset();
        }
        elapsed[lane] = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - started;
    }
    std.debug.print("surface anchored call: native {d} ns, compiled {d} ns (including enclosing reset)\n", .{ @divTrunc(elapsed[0], 1000), @divTrunc(elapsed[1], 1000) });
}
