const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
test "compiled inline paragraphs match native rendering data and own every run" {
    try @import("surface_decoder").testInlineParagraphRecords();
}

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

pub fn expectComplete(expected: anytype, actual: @TypeOf(expected)) anyerror!void {
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

test {
    _ = @import("semantic_tree_e2e_tests.zig");
    _ = @import("virtual_extent_e2e_tests.zig");
    _ = @import("text_cache_e2e_tests.zig");
    _ = @import("glyph_atlas_e2e_tests.zig");
    _ = @import("vector_effects_e2e_tests.zig");
    _ = @import("render_resources_e2e_tests.zig");
    _ = @import("render_cache_e2e_tests.zig");
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
    compiled_tokens.grid_layout_policy = core.nativeWindowPolicy;
    compiled_tokens.container_layout_policy = core.nativeWindowPolicy;
    compiled_tokens.intrinsic_layout_policy = core.nativeWindowPolicy;
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
        try std.testing.expect(app.app().text_cache_policy == core.nativeWindowPolicy);
        try std.testing.expect(app.app().render_cache_policy == core.nativeWindowPolicy);
        try std.testing.expect(app.app().render_plan_policy == core.nativeWindowPolicy);
        try std.testing.expect(app.app().render_override_policy == core.nativeWindowPolicy);
        try std.testing.expect(app.app().render_damage_policy == core.nativeWindowPolicy);
        const tokens = app.effectiveTokens().withOverrides(.{});
        try std.testing.expect(tokens.surface_layout_policy == core.nativeWindowPolicy);
        try std.testing.expect(tokens.grid_layout_policy == core.nativeWindowPolicy);
        try std.testing.expect(tokens.container_layout_policy == core.nativeWindowPolicy);
        try std.testing.expect(tokens.intrinsic_layout_policy == core.nativeWindowPolicy);
        try std.testing.expect(tokens.measurement_coordination_policy == core.nativeWindowPolicy);
        try std.testing.expect(tokens.flow_measurement_policy == core.nativeWindowPolicy);
        try std.testing.expect(tokens.layout_coordination_policy == core.nativeWindowPolicy);
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
        const app = try App.create(std.testing.allocator, .{ .name = "surface-layout", .scene = .{}, .canvas_label = "canvas", .surface_layout_policy = Factory.policy, .intrinsic_layout_policy = core.nativeWindowPolicy, .view = Factory.view, .update = Factory.update, .tokens = if (mode == 1) .{} else null, .tokens_fn = if (mode == 2) Factory.tokens else null });
        defer app.destroy();
        try std.testing.expect(app.app().text_cache_policy == null);
        try std.testing.expect(app.app().render_cache_policy == null);
        try std.testing.expect(app.app().render_plan_policy == null);
        try std.testing.expect(app.app().render_override_policy == null);
        try std.testing.expect(app.app().render_damage_policy == null);
        const tokens = app.effectiveTokens().withOverrides(.{});
        try std.testing.expect(tokens.surface_layout_policy == Factory.policy);
        try std.testing.expect(tokens.intrinsic_layout_policy == core.nativeWindowPolicy);
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

test "compiled grids preserve all nodes semantics and display commands across column and numeric boundaries" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var children = [_]canvas.Widget{
        .{ .id = 2, .kind = .panel, .frame = .init(0.125, -0.0, 0, 0), .layout = .{ .min_size = .init(1, 2), .max_size = .init(320, 240) } },
        .{ .id = 3, .kind = .panel, .frame = .init(-8, 4, 60, 42) },
        .{ .id = 4, .kind = .panel, .frame = .init(12, -4, 400, 100) },
        .{ .id = 5, .kind = .tabs, .frame = .init(8, 2, 64, 24), .variant = .primary },
        .{ .id = 6, .kind = .dialog, .frame = .init(0, 0, 160, 80) },
        .{ .id = 7, .kind = .panel, .frame = .init(0, 0, 0, 0) },
    };
    for ([_]usize{ 0, 1, 2, 3, 8, 16777217, std.math.maxInt(usize) }) |columns| {
        for ([_]f32{ -1, -0.0, 0, 0.125, 8, 24.000002, std.math.inf(f32), std.math.nan(f32) }) |gap| {
            const root = canvas.Widget{ .id = 1, .kind = .grid, .children = &children, .layout = .{ .columns = columns, .gap = gap } };
            try expectTree(root, .init(0.125, -0.0, 800.00006, 599.99994), .{});
            core.rt.frameReset();
            var geist = canvas.DesignTokens{};
            geist.controls.tabs_indicator = .underline;
            geist.metrics.tabs_list_full_width = true;
            try expectTree(root, .init(0.125, -0.0, 800.00006, 599.99994), geist);
            core.rt.frameReset();
        }
    }
    for (samples) |sample| {
        children[0].frame.width = sample;
        children[1].layout.min_size.height = sample;
        children[2].layout.max_size.width = sample;
        try expectTree(.{ .id = 1, .kind = .grid, .children = &children, .layout = .{ .columns = 3, .gap = 8 } }, .init(0, 0, 600, 400), .{});
        core.rt.frameReset();
    }
}

test "compiled virtual grids retain row culling rubber banding measurements and complete semantics" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var children: [20]canvas.Widget = undefined;
    for (&children, 0..) |*child, i| child.* = .{ .id = @intCast(i + 2), .kind = .panel, .frame = .init(@floatFromInt(i % 3), @floatFromInt(i % 2), if (i % 2 == 0) 0 else 60, if (i % 3 == 0) 0 else 42), .layout = .{ .min_size = .init(1, 2), .max_size = .init(320, 240) } };
    for ([_]usize{ 0, 1, 3, 24, std.math.maxInt(usize) }) |columns| {
        for ([_]usize{ 0, 1, 4, 100 }) |overscan| {
            for ([_]f32{ 0, 40.000004, 80 }) |extent| {
                for ([_]f32{ -300, -0.0, 0, 30.000002, 240.00002, 3000, std.math.inf(f32), std.math.nan(f32) }) |scroll| {
                    const root = canvas.Widget{ .id = 1, .kind = .grid, .children = &children, .value = scroll, .layout = .{ .columns = columns, .gap = 8.000001, .virtualized = true, .virtual_item_extent = extent, .virtual_overscan = overscan } };
                    try expectTree(root, .init(0.125, -0.0, 600.00006, 160.00002), .{});
                    core.rt.frameReset();
                }
            }
        }
    }
    for ([_]f32{ -1, 0, 0.00001, 120 }) |height| {
        try expectTree(.{ .id = 1, .kind = .grid, .children = &children, .layout = .{ .columns = 3, .virtualized = true, .virtual_item_extent = 40 } }, .init(0, 0, 600, height), .{});
        core.rt.frameReset();
    }
}

test "grid plans retain borrowed views and copied recursive frames until cycle collection" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const borrowed = core.rt.frameAlloc(u8, 9);
    @memcpy(borrowed, "keep\x00\xffabi");
    var view: [*]const u8 = undefined;
    var view_len: usize = 0;
    nsc_core_native_view(&view, &view_len);
    const owned = try std.testing.allocator.dupe(u8, view[0..view_len]);
    defer std.testing.allocator.free(owned);
    const root = canvas.Widget{ .id = 1, .kind = .grid, .layout = .{ .columns = 2, .gap = 8 }, .children = &.{ .{ .id = 2, .kind = .grid, .children = &.{.{ .id = 3, .kind = .panel }}, .layout = .{ .columns = 3 } }, .{ .id = 4, .kind = .panel } } };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const tree = try canvas.layoutWidgetTreeWithTokens(root, .init(0, 0, 600, 400), .{ .grid_layout_policy = core.nativeWindowPolicy }, &nodes);
    try std.testing.expectEqualSlices(u8, "keep\x00\xffabi", borrowed);
    try std.testing.expectEqualSlices(u8, owned, view[0..view_len]);
    const copied = tree.nodes[3].frame;
    core.rt.frameReset();
    try expectRect(.init(304, 0, 296, 400), copied);
}

test "grid planning cost is measured beside the native reference" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var children: [20]canvas.Widget = undefined;
    for (&children, 0..) |*child, i| child.* = .{ .id = @intCast(i + 2), .kind = .panel };
    const root = canvas.Widget{ .id = 1, .kind = .grid, .children = &children, .layout = .{ .columns = 4, .gap = 8 } };
    var nodes: [21]canvas.WidgetLayoutNode = undefined;
    var elapsed: [2]i128 = undefined;
    for (0..2) |lane| {
        const started = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
        for (0..1000) |_| {
            const tree = try canvas.layoutWidgetTreeWithTokens(root, .init(0, 0, 600, 400), .{ .grid_layout_policy = if (lane == 1) core.nativeWindowPolicy else null }, &nodes);
            std.mem.doNotOptimizeAway(tree);
            core.rt.frameReset();
        }
        elapsed[lane] = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - started;
    }
    std.debug.print("20-child grid: native {d} ns, compiled {d} ns (including enclosing reset)\n", .{ @divTrunc(elapsed[0], 1000), @divTrunc(elapsed[1], 1000) });
}

test "compiled grid view records own nodes and text with complete native construction parity" {
    try @import("surface_decoder").testGridRecords();
}

test "compiled container allocation preserves grow bounds alignment theme floors and hoisted surfaces" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .panel, .frame = .init(3, 4, 80, 40) },
        .{ .id = 3, .kind = .panel, .layout = .{ .grow = 1, .min_size = .init(24, 32), .max_size = .init(100, 70) } },
        .{ .id = 4, .kind = .panel, .layout = .{ .grow = 2, .min_size = .init(40, 60) } },
        .{ .id = 5, .kind = .tabs, .frame = .init(8, 2, 64, 24), .variant = .primary },
        .{ .id = 6, .kind = .bubble, .text = "A measured message", .layout = .{ .min_size = .init(20, 30) } },
        .{ .id = 7, .kind = .dialog, .frame = .init(0, 0, 160, 80) },
        .{ .id = 8, .kind = .tabs, .variant = .primary, .layout = .{ .grow = 1 } },
        .{ .id = 9, .kind = .bubble, .variant = .ghost, .text = "Uncapped ghost" },
        .{ .id = 10, .kind = .bubble, .text = "Bounded bubble", .layout = .{ .max_size = .init(120, 0) } },
        .{ .id = 11, .kind = .bubble, .frame = .init(0, 0, 240, 40), .text = "Authored width" },
    };
    for ([_]canvas.WidgetKind{ .row, .column }) |kind| {
        for ([_]canvas.WidgetMainAlignment{ .start, .center, .end, .space_between }) |main| {
            for ([_]canvas.WidgetCrossAlignment{ .stretch, .start, .center, .end }) |cross| {
                for ([_]f32{ 0, 0.125, 80, 300.00003, 800.00006 }) |width| {
                    for ([_]bool{ false, true }) |underline| {
                        var tokens = canvas.DesignTokens{};
                        if (underline) {
                            tokens.controls.tabs_indicator = .underline;
                            tokens.metrics.tabs_list_full_width = true;
                        }
                        try expectTree(.{ .id = 1, .kind = kind, .children = &children, .layout = .{ .main_alignment = main, .cross_alignment = cross, .gap = 8.000001 } }, .init(0.125, -0.0, width, 160.00002), tokens);
                        core.rt.frameReset();
                    }
                }
            }
        }
    }
}

test "compiled container arithmetic preserves nonfinite signed zero and authored constraint fields" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]canvas.WidgetKind{ .row, .column, .stack }) |kind| {
        for (samples) |sample| {
            for (0..8) |field| {
                var child = canvas.Widget{ .id = 2, .kind = .panel, .frame = .init(0.125, -0.0, 40, 60), .layout = .{ .grow = 1, .min_size = .init(2, 3), .max_size = .init(100, 120) } };
                switch (field) {
                    0 => child.frame.x = sample,
                    1 => child.frame.y = sample,
                    2 => child.frame.width = sample,
                    3 => child.frame.height = sample,
                    4 => child.layout.min_size.width = sample,
                    5 => child.layout.max_size.height = sample,
                    6 => child.layout.grow = sample,
                    else => child.layout.min_size.height = sample,
                }
                try expectTree(.{ .id = 1, .kind = kind, .children = &.{ child, .{ .id = 3, .kind = .panel, .layout = .{ .grow = 2 } } }, .layout = .{ .gap = sample, .main_alignment = .center, .cross_alignment = .center } }, .init(0.125, -0.0, 300.00003, 160.00002), .{});
                core.rt.frameReset();
            }
        }
    }
}

test "compiled measurement widths preserve complete nested wrapped paragraphs and bubble geometry" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const paragraph = canvas.Widget{ .id = 5, .kind = .text, .spans = &.{.{ .text = "A long café paragraph wraps at the allocated width beside its growing sibling and preserves every line." }} };
    const root = canvas.Widget{ .id = 1, .kind = .column, .layout = .{ .gap = 8 }, .children = &.{
        .{ .id = 2, .kind = .row, .layout = .{ .gap = 4 }, .children = &.{
            .{ .id = 3, .kind = .column, .layout = .{ .grow = 1, .max_size = .init(180, 0) }, .children = &.{paragraph} },
            .{ .id = 4, .kind = .text, .text = "Fixed", .frame = .init(0, 0, 50, 24) },
        } },
        .{ .id = 6, .kind = .bubble, .children = &.{.{ .id = 7, .kind = .text, .spans = &.{.{ .text = "This bubble hugs its message and measures all wrapped lines within the thread width." }} }} },
    } };
    for ([_]f32{ 80, 120.00001, 240.00002, 800 }) |width| {
        try expectTree(root, .init(10, 20, width, 400), .{});
        core.rt.frameReset();
    }
}

test "compiled stacks preserve full width tabs offsets ceilings and authored overflow" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]f32{ -8, -0.0, 0.125, 80, 400.00003 }) |offset| {
        for ([_]f32{ 0, 64, 800 }) |width| {
            for ([_]f32{ 0, 120, 320 }) |ceiling| {
                var tokens = canvas.DesignTokens{};
                tokens.controls.tabs_indicator = .underline;
                tokens.metrics.tabs_list_full_width = true;
                try expectTree(.{ .id = 1, .kind = .stack, .children = &.{.{ .id = 2, .kind = .tabs, .variant = .primary, .frame = .init(offset, 2, width, 24), .layout = .{ .max_size = .init(ceiling, 0) } }} }, .init(0.125, 20, 300.00003, 160), tokens);
                core.rt.frameReset();
            }
        }
    }
}

test "container plans retain native owned frames and borrowed views across recursion and collection" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var view: [*]const u8 = undefined;
    var view_len: usize = 0;
    nsc_core_native_view(&view, &view_len);
    const saved = try std.testing.allocator.dupe(u8, view[0..view_len]);
    defer std.testing.allocator.free(saved);
    const borrowed = core.rt.frameAlloc(u8, 8);
    @memcpy(borrowed, "flow\x00abi");
    const root = canvas.Widget{ .id = 1, .kind = .row, .layout = .{ .gap = 8 }, .children = &.{
        .{ .id = 2, .kind = .stack, .layout = .{ .grow = 1 }, .children = &.{.{ .id = 4, .kind = .panel }} },
        .{ .id = 3, .kind = .panel, .layout = .{ .grow = 1 } },
    } };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const tree = try canvas.layoutWidgetTreeWithTokens(root, .init(0, 0, 600, 400), .{ .container_layout_policy = core.nativeWindowPolicy }, &nodes);
    try std.testing.expectEqualSlices(u8, saved, view[0..view_len]);
    try std.testing.expectEqualSlices(u8, "flow\x00abi", borrowed);
    const frame = tree.nodes[3].frame;
    core.rt.frameReset();
    try expectRect(.init(304, 0, 296, 400), frame);
}

test "container planning cost is measured beside the native reference" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var children: [20]canvas.Widget = undefined;
    for (&children, 0..) |*child, i| child.* = .{ .id = @intCast(i + 2), .kind = .panel, .layout = .{ .grow = 1 } };
    var nodes: [21]canvas.WidgetLayoutNode = undefined;
    var elapsed: [2]i128 = undefined;
    for (0..2) |lane| {
        const started = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
        for (0..1000) |_| {
            _ = try canvas.layoutWidgetTreeWithTokens(.{ .id = 1, .kind = .row, .children = &children, .layout = .{ .gap = 8 } }, .init(0, 0, 600, 400), .{ .container_layout_policy = if (lane == 1) core.nativeWindowPolicy else null }, &nodes);
            core.rt.frameReset();
        }
        elapsed[lane] = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - started;
    }
    std.debug.print("20-child row: native {d} ns, compiled {d} ns (including enclosing reset)\n", .{ @divTrunc(elapsed[0], 1000), @divTrunc(elapsed[1], 1000) });
}

test "compiled container batches exceed stack scratch without losing complete node ownership" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var children: [128]canvas.Widget = undefined;
    for (&children, 0..) |*child, i| child.* = .{ .id = @intCast(i + 2), .kind = .panel, .layout = .{ .grow = @floatFromInt(1 + i % 3), .min_size = .init(2, 1) } };
    const root = canvas.Widget{ .id = 1, .kind = .row, .children = &children, .layout = .{ .gap = 0.125, .main_alignment = .center } };
    const expected_nodes = try std.testing.allocator.alloc(canvas.WidgetLayoutNode, 129);
    defer std.testing.allocator.free(expected_nodes);
    const actual_nodes = try std.testing.allocator.alloc(canvas.WidgetLayoutNode, 129);
    defer std.testing.allocator.free(actual_nodes);
    const expected = try canvas.layoutWidgetTreeWithTokens(root, .init(0.125, -0.0, 1024.0001, 80), .{}, expected_nodes);
    const actual = try canvas.layoutWidgetTreeWithTokens(root, .init(0.125, -0.0, 1024.0001, 80), .{ .container_layout_policy = core.nativeWindowPolicy }, actual_nodes);
    try expectComplete(expected.nodes, actual.nodes);
    const last = actual.nodes[128].frame;
    core.rt.frameReset();
    try expectRect(expected.nodes[128].frame, last);
}

fn expectIntrinsic(widget: canvas.Widget, tokens: canvas.DesignTokens) !void {
    const expected = canvas.intrinsicWidgetSize(widget, tokens);
    var compiled = tokens;
    compiled.intrinsic_layout_policy = core.nativeWindowPolicy;
    compiled.container_layout_policy = core.nativeWindowPolicy;
    compiled.grid_layout_policy = core.nativeWindowPolicy;
    try expectComplete(expected, canvas.intrinsicWidgetSize(widget, compiled));
}

test "compiled intrinsic composition preserves every container and decorated surface kind" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .text, .text = "Measured café", .layout = .{ .min_size = .init(3, 4), .max_size = .init(180, 40) } },
        .{ .id = 3, .kind = .separator },
        .{ .id = 4, .kind = .panel, .frame = .init(0, 0, 70, 55), .layout = .{ .min_size = .init(5, 6) } },
        .{ .id = 5, .kind = .dialog, .text = "Hoisted", .frame = .init(0, 0, 900, 700) },
    };
    for ([_]canvas.WidgetKind{ .row, .column, .stack, .grid, .list, .table, .tabs, .button_group, .data_cell, .card, .dialog, .drawer, .sheet, .alert, .accordion, .bubble, .panel, .scroll_view }) |kind| {
        for ([_]bool{ false, true }) |titled| {
            const widget = canvas.Widget{ .id = 1, .kind = kind, .text = if (titled) "Intrinsic title" else "", .value = 1, .children = &children, .scroll_axes = .horizontal, .layout = .{ .padding = .{ .left = 3, .right = 5, .top = 7, .bottom = 11 }, .gap = 2.125, .columns = 2, .min_size = .init(20, 10) } };
            try expectIntrinsic(widget, .{});
            try expectTree(widget, .init(0.125, 0, 640, 480), .{});
            core.rt.frameReset();
        }
    }
}

test "intrinsic composition keeps complete f32 child constraints padding gap and numeric boundaries" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]canvas.WidgetKind{ .row, .column, .stack, .grid, .card, .dialog, .alert, .accordion }) |kind| {
        var values = [_]f32{ 40, 20, 4, 3, 120, 80, 0.125, 2, 5 };
        for (0..values.len) |lane| {
            const original = values[lane];
            for (samples) |value| {
                values[lane] = value;
                const widget = canvas.Widget{ .id = 1, .kind = kind, .text = "Title", .value = 1, .layout = .{ .gap = values[6], .padding = .{ .left = values[7], .right = values[8], .top = 1, .bottom = 3 }, .columns = 2 }, .children = &.{
                    .{ .id = 2, .kind = .panel, .frame = .init(0, 0, values[0], values[1]), .layout = .{ .min_size = .init(values[2], values[3]), .max_size = .init(values[4], values[5]) } },
                    .{ .id = 3, .kind = .separator },
                } };
                expectIntrinsic(widget, .{}) catch |err| {
                    std.debug.print("intrinsic kind={t} lane={d} value={d}\n", .{ kind, lane, value });
                    return err;
                };
                core.rt.frameReset();
            }
            values[lane] = original;
        }
    }
}

test "intrinsic grids preserve exact large declarations and native conversion facts" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]usize{ 0, 1, 2, 3, 16777217, 9007199254740993, std.math.maxInt(usize) }) |columns| {
        try expectIntrinsic(.{ .id = 1, .kind = .grid, .layout = .{ .columns = columns, .gap = 0.125 }, .children = &.{ .{ .id = 2, .kind = .panel, .frame = .init(0, 0, 7, 9) }, .{ .id = 3, .kind = .panel, .frame = .init(0, 0, 11, 13) } } }, .{});
        core.rt.frameReset();
    }
}

test "intrinsic empty hoisted virtual zero and depth limited containers preserve their own contracts" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]canvas.WidgetKind{ .row, .column, .stack, .grid, .list, .card, .accordion, .scroll_view }) |kind| {
        const root = canvas.Widget{ .id = 1, .kind = kind, .scroll_axes = .horizontal, .layout = .{ .padding = .all(4), .min_size = .init(3, 5) } };
        try expectIntrinsic(root, .{});
        var hoisted = root;
        hoisted.children = &.{.{ .id = 2, .kind = .dialog }};
        try expectIntrinsic(hoisted, .{});
        var zero = hoisted;
        zero.layout.zero_intrinsic = true;
        try expectIntrinsic(zero, .{});
        var virtual = hoisted;
        virtual.layout.virtualized = true;
        try expectIntrinsic(virtual, .{});
        core.rt.frameReset();
    }
    var chain: [80]canvas.Widget = undefined;
    for (&chain, 0..) |*widget, i| widget.* = .{ .id = @intCast(i + 1), .kind = .column, .layout = .{ .padding = .all(1), .min_size = .init(2, 3) } };
    for (0..chain.len - 1) |i| chain[i].children = chain[i + 1 .. i + 2];
    try expectIntrinsic(chain[0], .{});
}

test "intrinsic scroll measurement retains unwrapped multiline spans and native metrics" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const root = canvas.Widget{ .id = 1, .kind = .scroll_view, .scroll_axes = .horizontal, .layout = .{ .padding = .all(3) }, .children = &.{.{ .id = 2, .kind = .column, .children = &.{.{ .id = 3, .kind = .text, .spans = &.{.{ .text = "First café line\nSecond line retains its full height" }} }} }} };
    try expectIntrinsic(root, .{});
    try expectTree(root, .init(0, 0, 240, 160), .{});
}

test "intrinsic large batches retain copied measurements and borrowed ABI data across recursion" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var children: [128]canvas.Widget = undefined;
    for (&children, 0..) |*child, i| child.* = .{ .id = @intCast(i + 2), .kind = .stack, .children = &.{.{ .id = 500, .kind = .text, .text = "Nested" }}, .layout = .{ .padding = .all(0.125) } };
    const borrowed = core.rt.frameAlloc(u8, 8);
    @memcpy(borrowed, "size\x00abi");
    var view: [*]const u8 = undefined;
    var view_len: usize = 0;
    nsc_core_native_view(&view, &view_len);
    const saved = try std.testing.allocator.dupe(u8, view[0..view_len]);
    defer std.testing.allocator.free(saved);
    const widget = canvas.Widget{ .id = 1, .kind = .row, .children = &children, .layout = .{ .gap = 0.125 } };
    try expectIntrinsic(widget, .{});
    const result = canvas.intrinsicWidgetSize(widget, .{ .intrinsic_layout_policy = core.nativeWindowPolicy });
    try std.testing.expectEqualSlices(u8, "size\x00abi", borrowed);
    try std.testing.expectEqualSlices(u8, saved, view[0..view_len]);
    core.rt.frameReset();
    try expectComplete(canvas.intrinsicWidgetSize(widget, .{}), result);
}

test "intrinsic composition cost is measured beside the native reference" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var children: [20]canvas.Widget = undefined;
    for (&children, 0..) |*child, i| child.* = .{ .id = @intCast(i + 2), .kind = .panel, .frame = .init(0, 0, 40, 30) };
    const widget = canvas.Widget{ .id = 1, .kind = .row, .children = &children, .layout = .{ .gap = 8 } };
    var elapsed: [2]i128 = undefined;
    for (0..2) |lane| {
        const started = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
        for (0..1000) |_| {
            std.mem.doNotOptimizeAway(canvas.intrinsicWidgetSize(widget, .{ .intrinsic_layout_policy = if (lane == 1) core.nativeWindowPolicy else null }));
            core.rt.frameReset();
        }
        elapsed[lane] = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - started;
    }
    std.debug.print("20-child intrinsic row: native {d} ns, compiled {d} ns (including enclosing reset)\n", .{ @divTrunc(elapsed[0], 1000), @divTrunc(elapsed[1], 1000) });
}

test "compiled content surface records preserve defaults captions nested content and owned bytes" {
    try @import("surface_decoder").testContentSurfaceRecords();
}

test "wrapped measurement preserves complete nested paragraph geometry semantics and display commands" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const paragraph = canvas.Widget{ .id = 4, .kind = .text, .spans = &.{.{ .text = "Measured café words wrap at their actual child width.\nA second line survives composition." }} };
    const children = [_]canvas.Widget{
        .{ .id = 3, .kind = .column, .layout = .{ .grow = 1, .padding = .all(0.125) }, .children = &.{paragraph} },
        .{ .id = 5, .kind = .text, .spans = &.{.{ .text = "An explicitly sized paragraph measures independently." }}, .frame = .init(0, 0, 72, 0) },
        .{ .id = 6, .kind = .dialog, .text = "Hoisted" },
    };
    for ([_]canvas.WidgetKind{ .column, .list, .data_grid, .table, .menu_surface, .dropdown_menu, .stack, .panel, .card, .bubble, .resizable, .popover, .alert, .accordion, .row, .data_row, .data_cell, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group }) |kind| {
        for ([_]bool{ false, true }) |open| {
            for ([_]f32{ 72, 240.00002, 640 }) |width| {
                const nested = canvas.Widget{ .id = 2, .kind = kind, .text = "Measured title", .value = if (open) 1 else 0, .children = &children, .layout = .{ .padding = .{ .left = 3, .right = 5, .top = 7, .bottom = 11 }, .gap = 2.125 } };
                const root = canvas.Widget{ .id = 1, .kind = .column, .children = &.{nested} };
                expectTree(root, .init(0.125, -0.0, width, 480), .{}) catch |err| {
                    std.debug.print("wrapped kind={t} open={} width={d}\n", .{ kind, open, width });
                    return err;
                };
                core.rt.frameReset();
            }
        }
    }
}

test "wrapped authored heights numeric bounds padding and gaps retain native f32 ordering" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]canvas.WidgetKind{ .column, .stack, .alert, .accordion, .row }) |kind| {
        var values = [_]f32{ 0, 3, 300, 2.125, 3, 5, 7, 11 };
        for (0..values.len) |lane| {
            const original = values[lane];
            for (samples) |sample| {
                values[lane] = sample;
                const nested = canvas.Widget{ .id = 2, .kind = kind, .text = "Title", .value = 1, .frame = .init(0, 0, 0, values[0]), .layout = .{ .min_size = .init(0, values[1]), .max_size = .init(0, values[2]), .gap = values[3], .padding = .{ .left = values[4], .right = values[5], .top = values[6], .bottom = values[7] } }, .children = &.{.{ .id = 3, .kind = .text, .spans = &.{.{ .text = "Width-aware measured words with a newline.\nMore words." }} }} };
                const root = canvas.Widget{ .id = 1, .kind = .column, .children = &.{nested} };
                expectTree(root, .init(0, 0, 240, 480), .{}) catch |err| {
                    std.debug.print("wrapped kind={t} lane={d} value={d}\n", .{ kind, lane, sample });
                    return err;
                };
                core.rt.frameReset();
            }
            values[lane] = original;
        }
    }
}

test "wrapped empty virtualized and authored short circuits preserve full trees" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]canvas.WidgetKind{ .column, .list, .data_grid, .table, .stack, .alert, .accordion, .data_cell }) |kind| {
        for ([_]bool{ false, true }) |virtual| {
            for ([_]f32{ 0, 1.0000001, 80 }) |height| {
                const nested = canvas.Widget{ .id = 2, .kind = kind, .value = 1, .frame = .init(0, 0, 0, height), .layout = .{ .virtualized = virtual, .padding = .all(4), .min_size = .init(3, 5) } };
                try expectTree(.{ .id = 1, .kind = .column, .children = &.{nested} }, .init(0, 0, 240, 480), .{});
                core.rt.frameReset();
            }
        }
    }
}

test "variable virtual list rows compose full width-aware geometry around their anchor" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const rows = [_]canvas.Widget{
        .{ .id = 2, .kind = .list_item, .layout = .{ .padding = .all(3) }, .children = &.{.{ .id = 3, .kind = .text, .spans = &.{.{ .text = "First row wraps across a constrained virtual viewport." }} }} },
        .{ .id = 4, .kind = .list_item, .children = &.{.{ .id = 5, .kind = .column, .layout = .{ .grow = 1 }, .children = &.{.{ .id = 6, .kind = .text, .spans = &.{.{ .text = "Second row has more words and another line.\nIts measured height changes the anchor neighbors." }} }} }} },
    };
    for ([_]f32{ 80, 240.00002, 480 }) |width| {
        for ([_]f32{ -20, 0, 30, 100 }) |offset| {
            const root = canvas.Widget{ .id = 1, .kind = .list, .value = offset, .layout = .{ .virtualized = true, .virtual_first_index = 3, .virtual_item_count = 10, .virtual_anchor_index = 4, .virtual_anchor_extent = 100, .virtual_total_extent = 500, .gap = 2.125 }, .children = &rows };
            try expectTree(root, .init(0.125, -0.0, width, 240), .{});
            core.rt.frameReset();
        }
    }
}

test "wrapped recursive results and large native scratch retain borrowed core and view bytes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var children: [256]canvas.Widget = undefined;
    for (&children, 0..) |*child, i| child.* = .{ .id = @intCast(i + 2), .kind = .column, .children = &.{.{ .id = 500, .kind = .text, .spans = &.{.{ .text = "One line\nTwo lines" }} }} };
    const borrowed = core.rt.frameAlloc(u8, 8);
    @memcpy(borrowed, "wrap\x00abi");
    var view: [*]const u8 = undefined;
    var view_len: usize = 0;
    nsc_core_native_view(&view, &view_len);
    const saved = try std.testing.allocator.dupe(u8, view[0..view_len]);
    defer std.testing.allocator.free(saved);
    const root = canvas.Widget{ .id = 1, .kind = .scroll_view, .scroll_axes = .horizontal, .children = &.{.{ .id = 600, .kind = .column, .children = &children, .layout = .{ .gap = 0.125 } }} };
    const expected = canvas.intrinsicWidgetSize(root, .{});
    const actual = canvas.intrinsicWidgetSize(root, .{ .intrinsic_layout_policy = core.nativeWindowPolicy, .container_layout_policy = core.nativeWindowPolicy });
    try expectComplete(expected, actual);
    try std.testing.expectEqualSlices(u8, "wrap\x00abi", borrowed);
    try std.testing.expectEqualSlices(u8, saved, view[0..view_len]);
    core.rt.frameReset();
    try expectComplete(expected, actual);
}

test "compiled virtual vertical flow preserves complete uniform windows hoisted children and declared counts" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .list_item, .frame = .init(0.125, -0.0, 0, 0), .children = &.{.{ .id = 3, .kind = .text, .text = "First" }} },
        .{ .id = 4, .kind = .popover, .frame = .init(0, 0, 40, 20) },
        .{ .id = 5, .kind = .list_item, .frame = .init(-0.0, 2.125, 120, 27), .layout = .{ .min_size = .init(100, 30) }, .children = &.{.{ .id = 6, .kind = .text, .text = "Second" }} },
        .{ .id = 7, .kind = .list_item, .children = &.{.{ .id = 8, .kind = .text, .text = "Third" }} },
    };
    for ([_]canvas.WidgetKind{ .list, .scroll_view }) |kind| {
        for ([_]usize{ 0, 10, 16777219, 4294967298, 9007199254740995 }) |declared| {
            for ([_]usize{ 0, 3 }) |first| {
                for ([_]usize{ 0, 1, 10 }) |overscan| {
                    for ([_]f32{ -400, -0.0, 0, 31.000002, 90, 999999, std.math.inf(f32), std.math.nan(f32) }) |offset| {
                        const root = canvas.Widget{ .id = 1, .kind = kind, .value = offset, .children = &children, .layout = .{ .virtualized = true, .virtual_first_index = first, .virtual_item_count = declared, .virtual_item_extent = 31.000002, .virtual_overscan = overscan, .gap = 2.125 } };
                        try expectTree(root, .init(0.125, -0.0, 240.00002, 100), .{});
                        core.rt.frameReset();
                    }
                }
            }
        }
    }
}

test "compiled virtual flow retains exact uint64 indices above number precision" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const rows = [_]canvas.Widget{ .{ .id = 2, .kind = .list_item, .frame = .init(0, 0, 0, 30) }, .{ .id = 3, .kind = .list_item, .frame = .init(0, 0, 0, 40) } };
    for ([_]usize{ 16777219, 4294967298, 9007199254740993, 18446744073709551500 }) |first| {
        const count = first + rows.len;
        const root = canvas.Widget{ .id = 1, .kind = .list, .children = &rows, .layout = .{ .virtualized = true, .virtual_first_index = first, .virtual_item_count = count, .virtual_item_extent = 30.000002, .virtual_overscan = first, .gap = 2.125 } };
        try expectTree(root, .init(0.125, -0.0, 240, 100), .{});
        core.rt.frameReset();
    }
}

test "compiled variable flow clamps anchors and composes measured rows in source order" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const rows = [_]canvas.Widget{
        .{ .id = 2, .kind = .list_item, .layout = .{ .padding = .all(3), .min_size = .init(20, 30) }, .children = &.{.{ .id = 3, .kind = .text, .spans = &.{.{ .text = "Wrapped words before the anchor depend on viewport width." }} }} },
        .{ .id = 4, .kind = .popover, .frame = .init(0, 0, 40, 20) },
        .{ .id = 5, .kind = .list_item, .frame = .init(0, 2.125, 120, 50), .layout = .{ .max_size = .init(100, 40) } },
        .{ .id = 6, .kind = .column, .children = &.{.{ .id = 7, .kind = .text, .spans = &.{.{ .text = "After the anchor\nSecond line with enough words to wrap." }} }} },
    };
    for ([_]usize{ 0, 10, 11, 12, 999 }) |anchor| {
        for ([_]f32{ 80, 240.00002, 480 }) |width| {
            for ([_]f32{ -999, -0.0, 0, 100, 300, 999, std.math.inf(f32), std.math.nan(f32) }) |offset| {
                const root = canvas.Widget{ .id = 1, .kind = .list, .value = offset, .layout = .{ .virtualized = true, .virtual_first_index = 10, .virtual_item_count = 100, .virtual_anchor_index = anchor, .virtual_anchor_extent = 120.00001, .virtual_total_extent = 500.00003, .gap = 2.125 }, .children = &rows };
                try expectTree(root, .init(0.125, -0.0, width, 100), .{});
                core.rt.frameReset();
            }
        }
    }
}

test "compiled virtual content extents preserve empty semantic grid and exact large count selection" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const rows = [_]canvas.Widget{ .{ .id = 2, .kind = .list_item, .frame = .init(0, 0, 0, 30) }, .{ .id = 3, .kind = .list_item, .frame = .init(0, 0, 0, 40) }, .{ .id = 4, .kind = .popover } };
    for ([_]canvas.WidgetKind{ .list, .scroll_view, .grid }) |kind| {
        for ([_][]const canvas.Widget{ &.{}, &rows }) |children| {
            for ([_]usize{ 0, 1, 10, 16777219, 4294967298, 9007199254740995 }) |declared| {
                for ([_]f32{ 0, 30.000002 }) |extent| {
                    for ([_]f32{ 0, 100, 999 }) |total| {
                        const root = canvas.Widget{ .id = 1, .kind = kind, .children = children, .semantics = .{ .list_item_count = 7 }, .layout = .{ .virtualized = true, .columns = 2, .virtual_first_index = 3, .virtual_item_count = declared, .virtual_item_extent = extent, .virtual_total_extent = total, .gap = 2.125 } };
                        for ([_]f32{ 0, 100, 240.00002 }) |viewport| {
                            const expected = canvas.virtualWidgetScrollContentExtentWithTokens(root, viewport, .{});
                            const actual = canvas.virtualWidgetScrollContentExtentWithTokens(root, viewport, .{ .intrinsic_layout_policy = core.nativeWindowPolicy });
                            try expectComplete(expected, actual);
                            core.rt.frameReset();
                        }
                    }
                }
            }
        }
    }
}

test "compiled scroll flow preserves axis grants authored widths and natural horizontal measurement" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .row, .children = &.{.{ .id = 3, .kind = .text, .text = "An unwrapped horizontal line extends beyond the viewport" }} },
        .{ .id = 4, .kind = .text, .text = "Authored width", .frame = .init(2.125, -0.0, 160, 40) },
        .{ .id = 5, .kind = .popover, .frame = .init(0, 0, 40, 20) },
    };
    for ([_]canvas.ScrollAxes{ .vertical, .horizontal, .both }) |axes| {
        for ([_]f32{ -80, -0.0, 0, 50.000004, 999 }) |x| {
            for ([_]f32{ -80, -0.0, 0, 50.000004, 999 }) |y| {
                try expectTree(.{ .id = 1, .kind = .scroll_view, .scroll_axes = axes, .value_x = x, .value = y, .children = &children }, .init(0.125, -0.0, 240, 100), .{});
                core.rt.frameReset();
            }
        }
    }
}

test "large virtual flow plans own copied frames across recursive calls and borrowed views" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var rows: [256]canvas.Widget = undefined;
    for (&rows, 0..) |*row, i| row.* = .{ .id = @intCast(i + 2), .kind = .list_item, .frame = .init(0, 0, 0, 30), .children = &.{.{ .id = 500, .kind = .text, .text = "Recursive row" }} };
    const root = canvas.Widget{ .id = 1, .kind = .list, .children = &rows, .layout = .{ .virtualized = true, .virtual_first_index = 10, .virtual_item_count = 1000, .virtual_anchor_index = 100, .virtual_anchor_extent = 3000, .virtual_total_extent = 30000, .gap = 0.125 } };
    const borrowed = core.rt.frameAlloc(u8, 8);
    @memcpy(borrowed, "flow\x00abi");
    var view: [*]const u8 = undefined;
    var view_len: usize = 0;
    nsc_core_native_view(&view, &view_len);
    const saved = try std.testing.allocator.dupe(u8, view[0..view_len]);
    defer std.testing.allocator.free(saved);
    var native_nodes: [1024]canvas.WidgetLayoutNode = undefined;
    var compiled_nodes: [1024]canvas.WidgetLayoutNode = undefined;
    const expected = try canvas.layoutWidgetTreeWithTokens(root, .init(0, 0, 240, 100), .{}, &native_nodes);
    const actual = try canvas.layoutWidgetTreeWithTokens(root, .init(0, 0, 240, 100), .{ .intrinsic_layout_policy = core.nativeWindowPolicy, .container_layout_policy = core.nativeWindowPolicy }, &compiled_nodes);
    try expectComplete(expected.nodes, actual.nodes);
    try std.testing.expectEqualSlices(u8, "flow\x00abi", borrowed);
    try std.testing.expectEqualSlices(u8, saved, view[0..view_len]);
    core.rt.frameReset();
    try expectComplete(expected.nodes, actual.nodes);
}

test {
    _ = @import("render_plan_e2e_tests.zig");
}

test {
    _ = @import("render_override_e2e_tests.zig");
}

test {
    _ = @import("render_damage_e2e_tests.zig");
}
