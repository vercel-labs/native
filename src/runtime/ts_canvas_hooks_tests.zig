const std = @import("std");
const testing = std.testing;
const canvas = @import("canvas");
const hooks = @import("ts_canvas_hooks.zig");
const Scratch = @import("view_canvas.zig").CanvasDisplayListScratch;

const Color = struct { r: f64 = 0, g: f64 = 0, b: f64 = 0, a: f64 = 1 };
const Point = struct { x: f64 = 0, y: f64 = 0 };
const Rect = struct { x: f64 = 0, y: f64 = 0, width: f64 = 10, height: f64 = 10 };
const Stop = struct { offset: f64, color: Color = .{} };
const Fill = union(enum) { color: Color, linear_gradient: struct { start: Point = .{}, end: Point = .{}, stops: []const Stop } };
const Stroke = struct { fill: Fill = .{ .color = .{} }, width: f64 = 1 };
const Radius = struct { topLeft: f64 = 0, topRight: f64 = 0, bottomRight: f64 = 0, bottomLeft: f64 = 0 };
const Element = struct { verb: canvas.PathVerb, first: Point = .{}, second: Point = .{}, third: Point = .{} };
const Command = union(enum) {
    rect: struct { id: []const u8 = "1", rect: Rect = .{}, fill: Fill = .{ .color = .{} } },
    rounded_rect: struct { id: []const u8 = "1", rect: Rect = .{}, radius: f64 = 1, fill: Fill = .{ .color = .{} } },
    stroke_rect: struct { id: []const u8 = "1", rect: Rect = .{}, radius: Radius = .{}, stroke: Stroke = .{} },
    line: struct { id: []const u8 = "1", from: Point = .{}, to: Point = .{}, stroke: Stroke = .{} },
    fill_path: struct { id: []const u8 = "1", elements: []const Element = &.{}, fill: Fill = .{ .color = .{} } },
    stroke_path: struct { id: []const u8 = "1", elements: []const Element = &.{}, stroke: Stroke = .{}, cap: canvas.LineCap = .butt },
};
const Context = struct { width: f64, height: f64, background: Color, surface: Color, border: Color, text: Color };
const Transform = struct { a: f64 = 1, b: f64 = 0, c: f64 = 0, d: f64 = 1, tx: f64 = 0, ty: f64 = 0 };
const Animation = struct {
    label: []const u8 = "target",
    index: f64 = 0,
    part: enum { fill, text } = .fill,
    durationMs: f64 = 900,
    easing: canvas.Easing = .linear,
    loop: canvas.CanvasRenderAnimationLoop = .none,
    fromOpacity: f64 = 1,
    toOpacity: f64 = 1,
    fromTransform: Transform = .{},
    toTransform: Transform = .{},
};
const Core = struct {
    pub const Msg = union(enum) { noop };
    pub const rt = struct {
        pub fn frameAllocator() std.mem.Allocator {
            return testing.allocator;
        }
    };
    pub const Model = struct {
        commands: []const Command = &.{},
        suffix_commands: []const Command = &.{},
        declarations: []const Animation = &.{},
        pub fn canvasChrome(self: *const Model, _: Context) []const Command {
            return self.commands;
        }
        pub fn canvasChromeSuffix(self: *const Model, _: Context) []const Command {
            return self.suffix_commands;
        }
        pub fn canvasAnimations(self: *const Model) []const Animation {
            return self.declarations;
        }
    };
};
const App = struct {
    pub const Ui = canvas.Ui(Core.Msg);
};
const H = hooks.Hooks(Core, Core.Model, App);

fn chrome(commands: []const Command, builder: *canvas.Builder) !void {
    try H.chrome(&.{ .commands = commands }, builder, .init(400, 300), .{});
}

test "TypeScript canvas chrome validates exact identities and bounds before native submission" {
    var output: [257]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&output);
    try chrome(&.{.{ .rect = .{ .id = "18446744073709551615" } }}, &builder);
    try testing.expectEqual(std.math.maxInt(u64), builder.displayList().commands[0].fill_rect.id);
    for ([_][]const u8{ "", "01", "-1", "1x", "18446744073709551616", "184467440737095516150" }) |id| {
        builder = canvas.Builder.init(&output);
        try testing.expectError(error.InvalidCanvasId, chrome(&.{.{ .rect = .{ .id = id } }}, &builder));
    }
    builder = canvas.Builder.init(&output);
    try testing.expectError(error.DuplicateCanvasChromeId, chrome(&.{ .{ .rect = .{} }, .{ .rounded_rect = .{} } }, &builder));
    var many: [257]Command = @splat(.{ .rect = .{} });
    builder = canvas.Builder.init(&output);
    try testing.expectError(error.CanvasChromeCommandLimit, chrome(&many, &builder));
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), std.math.floatMax(f64) }) |value| {
        builder = canvas.Builder.init(&output);
        try testing.expectError(error.InvalidCanvasScalar, chrome(&.{.{ .rect = .{ .rect = .{ .x = value } } }}, &builder));
    }
    builder = canvas.Builder.init(&output);
    try testing.expectError(error.InvalidCanvasGeometry, chrome(&.{.{ .rect = .{ .rect = .{ .width = -1 } } }}, &builder));
    builder = canvas.Builder.init(&output);
    try testing.expectError(error.InvalidCanvasColor, chrome(&.{.{ .rect = .{ .fill = .{ .color = .{ .r = 1.01 } } } }}, &builder));
    builder = canvas.Builder.init(&output);
    try testing.expectError(error.InvalidCanvasRadius, chrome(&.{.{ .rounded_rect = .{ .radius = -1 } }}, &builder));
}

test "TypeScript canvas gradients outlive helper input and native copies outlive subsequent declarations" {
    var stops = [_]Stop{ .{ .offset = 0, .color = .{ .r = 0.25 } }, .{ .offset = 1 } };
    var commands = [_]Command{.{ .rect = .{ .fill = .{ .linear_gradient = .{ .stops = &stops } } } }};
    var output: [4]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&output);
    try chrome(&commands, &builder);
    stops[0].color.r = 0.75;
    try testing.expectEqual(@as(f32, 0.25), builder.displayList().commands[0].fill_rect.fill.linear_gradient.stops[0].color.r);
    const scratch = try testing.allocator.create(Scratch);
    defer testing.allocator.destroy(scratch);
    scratch.* = .{};
    const owned = try scratch.copyCanvasCommand(builder.displayList().commands[0]);
    builder = canvas.Builder.init(&output);
    try chrome(&commands, &builder);
    try testing.expectEqual(@as(f32, 0.25), owned.fill_rect.fill.linear_gradient.stops[0].color.r);
    try testing.expectEqual(@as(f32, 0.75), builder.displayList().commands[0].fill_rect.fill.linear_gradient.stops[0].color.r);
    stops[0].offset = 1.1;
    try testing.expectError(error.InvalidCanvasGradientOffset, chrome(&commands, &builder));
    var many: [17]Stop = @splat(.{ .offset = 0 });
    commands[0].rect.fill.linear_gradient.stops = &many;
    try testing.expectError(error.CanvasGradientStopLimit, chrome(&commands, &builder));
}

test "TypeScript canvas animations retain widget identities and exact clocks and reject invalid batches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = App.Ui.init(arena.allocator());
    const tree = try ui.finalize(ui.column(.{}, .{ ui.text(.{ .semantics = .{ .label = "target" } }, "first"), ui.text(.{ .semantics = .{ .label = "target" } }, "second") }));
    var declarations = [_]Animation{ .{}, .{ .index = 1, .part = .text } };
    var model = Core.Model{ .declarations = &declarations };
    var out: [4]canvas.CanvasRenderAnimation = undefined;
    try testing.expectEqual(@as(usize, 2), H.animations(&model, &tree, std.math.maxInt(u64), &out));
    try testing.expectEqual(std.math.maxInt(u64), out[0].start_ns);
    try testing.expectEqual(canvas.widgetCommandPartId(.{ .widget_id = tree.root.children[1].id, .slot = 4 }), out[1].id);
    try testing.expectEqual(@as(usize, 0), H.animations(&model, &tree, 0, out[0..1]));
    declarations[1] = declarations[0];
    try testing.expectEqual(@as(usize, 0), H.animations(&model, &tree, 0, &out));
    model.declarations = declarations[0..1];
    for ([_]f64{ -1, 0.5, 4294967296, std.math.nan(f64) }) |invalid| {
        declarations[0].index = invalid;
        try testing.expectEqual(@as(usize, 0), H.animations(&model, &tree, 0, &out));
        declarations[0].index = 0;
        declarations[0].durationMs = invalid;
        try testing.expectEqual(@as(usize, 0), H.animations(&model, &tree, 0, &out));
        declarations[0].durationMs = 900;
    }
    declarations[0].fromOpacity = 1.1;
    try testing.expectEqual(@as(usize, 0), H.animations(&model, &tree, 0, &out));
    declarations[0].fromOpacity = 1;
    declarations[0].toTransform.tx = std.math.inf(f64);
    try testing.expectEqual(@as(usize, 0), H.animations(&model, &tree, 0, &out));
    declarations[0].toTransform.tx = 0;
    declarations[0].index = 2;
    try testing.expectEqual(@as(usize, 0), H.animations(&model, &tree, 0, &out));
}

test "TypeScript canvas markup surfaces preserve bound blur grids anchors and dismissal in both native engines" {
    const Model = struct { blur: enum { none, sm, md } = .md };
    const Msg = union(enum) { dismiss };
    const Ui = canvas.Ui(Msg);
    const source =
        \\<column>
        \\  <stack>
        \\    <text>Trigger</text>
        \\    <popover anchor="below" backdrop-blur="{blur}" on-dismiss="dismiss">
        \\      <menu-surface on-dismiss="dismiss"><menu-item on-press="dismiss">Open</menu-item></menu-surface>
        \\    </popover>
        \\  </stack>
        \\  <data-grid text="Rows"><table-row><table-cell>Cell</table-cell></table-row></data-grid>
        \\</column>
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interpreted = try canvas.MarkupView(Model, Msg).init(arena.allocator(), source);
    const Compiled = canvas.CompiledMarkupView(Model, Msg, source);
    for ([_]@FieldType(Model, "blur"){ .none, .sm, .md }) |blur| {
        const model = Model{ .blur = blur };
        var left = Ui.init(arena.allocator());
        var right = Ui.init(arena.allocator());
        const a = try left.finalize(try interpreted.build(&left, &model));
        const b = try right.finalize(Compiled.build(&right, &model));
        try testing.expectEqualDeep(a.root, b.root);
        const popup = b.root.children[0].children[1];
        try testing.expectEqual(canvas.WidgetKind.popover, popup.kind);
        try testing.expectEqual(canvas.WidgetAnchorPlacement.below, popup.layout.anchor.?.placement);
        try testing.expectEqual(Msg.dismiss, b.msgForDismiss(popup.id).?);
        try testing.expectEqual(canvas.WidgetKind.menu_surface, popup.children[0].kind);
        try testing.expectEqual(Msg.dismiss, b.msgForDismiss(popup.children[0].id).?);
        try testing.expectEqual(canvas.WidgetKind.data_grid, b.root.children[1].kind);
    }
    for ([_][]const u8{ "<popover backdrop-blur=\"lg\" />", "<popover backdrop-blur=\"3\" />" }) |invalid| {
        var view = try canvas.MarkupView(Model, Msg).init(arena.allocator(), invalid);
        var ui = Ui.init(arena.allocator());
        try testing.expectError(error.MarkupBuild, view.build(&ui, &.{}));
    }
}

test "TypeScript canvas layers preserve complete path and stroke payloads with disjoint native storage" {
    var elements = [_]Element{
        .{ .verb = .move_to, .first = .{ .x = 1.25, .y = -2 }, .second = .{ .x = 7 } },
        .{ .verb = .line_to, .first = .{ .x = 5, .y = 9 } },
        .{ .verb = .quad_to, .first = .{ .x = 2 }, .second = .{ .y = 4 } },
        .{ .verb = .cubic_to, .first = .{ .x = 3 }, .second = .{ .y = 5 }, .third = .{ .x = 8 } },
        .{ .verb = .close },
    };
    var stops = [_]Stop{ .{ .offset = 0.125, .color = .{ .r = 0.375 } }, .{ .offset = 0.875, .color = .{ .a = 0.625 } } };
    const paint: Fill = .{ .linear_gradient = .{ .start = .{ .x = 2, .y = 3 }, .end = .{ .x = 11, .y = 13 }, .stops = &stops } };
    var first = [_]Command{
        .{ .stroke_rect = .{ .id = "18446744073709551615", .rect = .{ .x = 0.25, .y = 2, .width = 7, .height = 11 }, .radius = .{ .topLeft = 1, .topRight = 2, .bottomRight = 3, .bottomLeft = 4 }, .stroke = .{ .fill = paint, .width = 1.75 } } },
        .{ .line = .{ .id = "2", .from = .{ .x = -1.5, .y = 2.75 }, .to = .{ .x = 11, .y = 17 }, .stroke = .{ .fill = paint, .width = 2.25 } } },
        .{ .fill_path = .{ .id = "3", .elements = &elements, .fill = paint } },
    };
    const last = [_]Command{.{ .stroke_path = .{ .id = "4", .elements = &elements, .stroke = .{ .fill = paint, .width = 3.5 }, .cap = .round } }};
    var model = Core.Model{ .commands = &first, .suffix_commands = &last };
    var output: [4]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&output);
    try H.chrome(&model, &builder, .init(400, 300), .{});
    elements[0].first.x = 99;
    stops[0].color.r = 0.75;
    try H.suffix(&model, &builder, .init(400, 300), .{});
    const list = builder.displayList();
    const rectangle = list.commands[0].stroke_rect;
    try testing.expectEqualDeep(canvas.Radius{ .top_left = 1, .top_right = 2, .bottom_right = 3, .bottom_left = 4 }, rectangle.radius);
    try testing.expectEqual(@as(f32, 1.75), rectangle.stroke.width);
    try testing.expectEqual(@as(f32, 0.375), rectangle.stroke.fill.linear_gradient.stops[0].color.r);
    try testing.expectEqualDeep(@import("geometry").PointF.init(-1.5, 2.75), list.commands[1].draw_line.from);
    const prefix = list.commands[2].fill_path;
    const suffix = list.commands[3].stroke_path;
    try testing.expectEqual(@as(f32, 1.25), prefix.elements[0].points[0].x);
    try testing.expectEqual(@as(f32, 99), suffix.elements[0].points[0].x);
    try testing.expectEqual(canvas.LineCap.round, suffix.cap);
    try testing.expectEqual(@as(f32, 3.5), suffix.stroke.width);
    try testing.expectEqual(@as(f32, 0.75), suffix.stroke.fill.linear_gradient.stops[0].color.r);
    for (prefix.elements, elements) |actual, original| {
        try testing.expectEqual(original.verb, actual.verb);
        try testing.expectEqual(@as(f32, @floatCast(original.second.x)), actual.points[1].x);
        try testing.expectEqual(@as(f32, @floatCast(original.third.x)), actual.points[2].x);
    }
    const scratch = try testing.allocator.create(Scratch);
    defer testing.allocator.destroy(scratch);
    scratch.* = .{};
    const owned_prefix = try scratch.copyCanvasCommand(list.commands[2]);
    const owned_suffix = try scratch.copyCanvasCommand(list.commands[3]);
    elements[0].first.x = 123;
    stops[0].color.r = 0.875;
    builder = canvas.Builder.init(&output);
    try H.chrome(&model, &builder, .init(400, 300), .{});
    try H.suffix(&model, &builder, .init(400, 300), .{});
    try testing.expectEqual(@as(f32, 1.25), owned_prefix.fill_path.elements[0].points[0].x);
    try testing.expectEqual(@as(f32, 99), owned_suffix.stroke_path.elements[0].points[0].x);
    try testing.expectEqual(@as(f32, 0.375), owned_prefix.fill_path.fill.linear_gradient.stops[0].color.r);
    try testing.expectEqual(@as(f32, 0.75), owned_suffix.stroke_path.stroke.fill.linear_gradient.stops[0].color.r);
    model.suffix_commands = &.{.{ .rect = .{ .id = "3" } }};
    builder = canvas.Builder.init(&output);
    try H.chrome(&model, &builder, .init(400, 300), .{});
    try testing.expectError(error.DuplicateCanvasChromeId, H.suffix(&model, &builder, .init(400, 300), .{}));
    try testing.expectEqual(@as(usize, 3), builder.len);
}

test "TypeScript canvas layers reject whole invalid batches and enforce path and command bounds" {
    var output: [256]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&output);
    var many: [256]Command = @splat(.{ .rect = .{ .id = "0" } });
    try chrome(&many, &builder);
    try testing.expectEqual(@as(usize, 256), builder.len);
    builder = canvas.Builder.init(output[0..255]);
    try testing.expectError(error.DisplayListFull, chrome(&many, &builder));
    try testing.expectEqual(@as(usize, 0), builder.len);
    var elements: [65]Element = @splat(.{ .verb = .line_to });
    builder = canvas.Builder.init(&output);
    try testing.expectError(error.CanvasPathElementLimit, chrome(&.{ .{ .rect = .{} }, .{ .fill_path = .{ .id = "2", .elements = &elements } } }, &builder));
    try testing.expectEqual(@as(usize, 0), builder.len);
    try chrome(&.{.{ .stroke_path = .{ .elements = elements[0..64] } }}, &builder);
    try testing.expectEqual(@as(usize, 64), builder.displayList().commands[0].stroke_path.elements.len);
    for ([_]f64{ -1, std.math.nan(f64), std.math.inf(f64) }) |invalid| {
        builder = canvas.Builder.init(&output);
        const wanted = if (invalid == -1) error.InvalidCanvasStrokeWidth else error.InvalidCanvasScalar;
        try testing.expectError(wanted, chrome(&.{ .{ .rect = .{} }, .{ .line = .{ .id = "2", .stroke = .{ .width = invalid } } } }, &builder));
        try testing.expectEqual(@as(usize, 0), builder.len);
    }
    builder = canvas.Builder.init(&output);
    try testing.expectError(error.InvalidCanvasRadius, chrome(&.{.{ .stroke_rect = .{ .radius = .{ .bottomLeft = -1 } } }}, &builder));
    elements[0].third.x = std.math.nan(f64);
    try testing.expectError(error.InvalidCanvasScalar, chrome(&.{.{ .fill_path = .{ .elements = elements[0..1] } }}, &builder));
    try testing.expectEqual(@as(usize, 0), builder.len);
}
