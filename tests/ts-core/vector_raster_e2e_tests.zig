const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const v = c.vector;
const wire = c.VectorRasterPolicy;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: [4]usize = @splat(0);
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 66) calls[request[2]] += 1;
    return core.nativeWindowPolicy(request, output);
}
const Pixel = struct { x: i32, y: i32, coverage: f32 };
const Sink = struct {
    values: std.ArrayList(Pixel) = .empty,
    pub fn pixel(self: *@This(), x: i32, y: i32, coverage: f32) void {
        self.values.append(std.testing.allocator, .{ .x = x, .y = y, .coverage = coverage }) catch @panic("test allocation failed");
    }
    fn deinit(self: *@This()) void {
        self.values.deinit(std.testing.allocator);
    }
};
fn compareResult(expected: v.Error!void, actual: v.Error!void) !void {
    if (expected) |_| try actual else |err| try std.testing.expectError(err, actual);
}
fn compareRaster(left: anytype, right: @TypeOf(left)) !void {
    try exact(left.edge_count, right.edge_count);
    try exact(left.min_x, right.min_x);
    try exact(left.min_y, right.min_y);
    try exact(left.max_x, right.max_x);
    try exact(left.max_y, right.max_y);
    try exact(left.edges[0..left.edge_count], right.edges[0..right.edge_count]);
}
fn compareSweep(left: anytype, right: @TypeOf(left), rule: v.FillRule, clip: v.ClipRect) !void {
    var a = Sink{};
    defer a.deinit();
    var b = Sink{};
    defer b.deinit();
    calls[2] = 0;
    calls[3] = 0;
    try compareResult(left.sweep(rule, clip, &a), right.sweep(rule, clip, &b));
    try exact(a.values.items, b.values.items);
    try std.testing.expectEqual(@as(usize, 1), calls[2]);
    const before = try std.testing.allocator.dupe(Pixel, b.values.items);
    defer std.testing.allocator.free(before);
    core.rt.frameReset();
    try exact(before, b.values.items);
}
fn buildPath(seed: usize) v.PathBuilder(32) {
    var builder = v.PathBuilder(32){};
    const shift: f32 = @as(f32, @floatFromInt(seed % 7)) * 0.125;
    builder.moveTo(.init(-2.25 + shift, -0.0)) catch unreachable;
    builder.lineTo(.init(8.375, 1.25 + shift)) catch unreachable;
    builder.quadTo(.init(17.875, 21.25), .init(1.75, 13.125)) catch unreachable;
    builder.cubicTo(.init(-8.25, 3.75), .init(20.25, -3.5), .init(-2.25 + shift, -0.0)) catch unreachable;
    if (seed % 2 == 0) builder.close() catch unreachable;
    builder.moveTo(.init(1.25, 1.25)) catch unreachable;
    builder.lineTo(.init(1.25, 5.75)) catch unreachable;
    builder.lineTo(.init(5.75, 5.75)) catch unreachable;
    builder.lineTo(.init(5.75, 1.25)) catch unreachable;
    builder.close() catch unreachable;
    return builder;
}

test "compiled vector raster complete flattened edges strokes and coverage match native" {
    const transforms = [_]c.Affine{ .{}, .{ .a = 0.75, .b = 0.125, .c = -0.25, .d = 1.25, .tx = 5.375, .ty = 2.25 }, .{ .a = -1, .d = -0.75, .tx = 16.25, .ty = 18.125 } };
    const tolerances = [_]f32{ 0, 0.01, 0.25, 1, std.math.nan(f32) };
    const clip = v.ClipRect{ .x0 = -6, .y0 = -5, .x1 = 25, .y1 = 25 };
    for (transforms, 0..) |transform, seed| for (tolerances) |tolerance| {
        var builder = buildPath(seed);
        var left = v.Rasterizer{};
        var right = v.Rasterizer{ .policy = observed };
        calls = @splat(0);
        try compareResult(v.accumulateFillEdges(&left, builder.slice(), transform, tolerance), v.accumulateFillEdges(&right, builder.slice(), transform, tolerance));
        try compareRaster(&left, &right);
        try std.testing.expectEqual(@as(usize, 1), calls[0]);
        try compareSweep(&left, &right, .nonzero, clip);
        try compareSweep(&left, &right, .even_odd, clip);
        for ([_]v.LineCap{ .butt, .round }) |cap| for ([_]v.LineJoin{ .miter, .round }) |join| for ([_]f32{ 1, 4 }) |miter| {
            left.resetEdges();
            right.resetEdges();
            const style = v.StrokeStyle{ .width = 2.25, .cap = cap, .join = join, .miter_limit = miter };
            calls = @splat(0);
            try compareResult(v.accumulateStrokeEdges(&left, builder.slice(), transform, style, tolerance), v.accumulateStrokeEdges(&right, builder.slice(), transform, style, tolerance));
            try compareRaster(&left, &right);
            try std.testing.expectEqual(@as(usize, 1), calls[1]);
            try compareSweep(&left, &right, .nonzero, clip);
        };
    };
}

test "compiled vector raster accumulation no-op malformed geometry and error prefixes" {
    var builder = buildPath(0);
    var left = v.Rasterizer{};
    var right = v.Rasterizer{ .policy = observed };
    for (0..3) |_| {
        try v.accumulateFillEdges(&left, builder.slice(), .{}, 0.25);
        try v.accumulateFillEdges(&right, builder.slice(), .{}, 0.25);
        try compareRaster(&left, &right);
    }
    for ([_]f32{ 0, -1, std.math.nan(f32) }) |width| {
        try v.accumulateStrokeEdges(&left, builder.slice(), .{}, .{ .width = width }, 0.25);
        try v.accumulateStrokeEdges(&right, builder.slice(), .{}, .{ .width = width }, 0.25);
        try compareRaster(&left, &right);
    }
    const stray = [_]c.PathElement{
        .{ .verb = .quad_to, .points = .{ .init(1, 2), .init(3, 4), .zero() } },
        .{ .verb = .cubic_to, .points = .{ .init(5, 6), .init(7, 8), .init(9, 10) } },
        .{ .verb = .line_to, .points = .{ .init(-0.0, 0), .zero(), .zero() } },
        .{ .verb = .line_to, .points = .{ .init(std.math.nan(f32), 2), .zero(), .zero() } },
        .{ .verb = .close },
        .{ .verb = .move_to, .points = .{ .init(1, 2), .zero(), .zero() } },
        .{ .verb = .line_to, .points = .{ .init(1, 2), .zero(), .zero() } },
        .{ .verb = .close },
    };
    left.resetEdges();
    right.resetEdges();
    try v.accumulateFillEdges(&left, &stray, .{}, 0.25);
    try v.accumulateFillEdges(&right, &stray, .{}, 0.25);
    try compareRaster(&left, &right);
    const edge: @TypeOf(left.edges[0]) = .{ .x0 = @as(f32, 0), .y0 = @as(f32, 0), .x1 = @as(f32, 1), .y1 = @as(f32, 1), .dir = @as(f32, 1) };
    @memset(&left.edges, edge);
    @memset(&right.edges, edge);
    left.edge_count = left.edges.len - 1;
    right.edge_count = right.edges.len - 1;
    try compareResult(v.accumulateFillEdges(&left, builder.slice(), .{}, 0.25), v.accumulateFillEdges(&right, builder.slice(), .{}, 0.25));
    try compareRaster(&left, &right);
    var long = v.PathBuilder(520){};
    try long.moveTo(.init(0, 0));
    for (0..513) |i| try long.lineTo(.init(@floatFromInt(i % 5), @floatFromInt(i + 1)));
    left.resetEdges();
    right.resetEdges();
    try compareResult(v.accumulateStrokeEdges(&left, long.slice(), .{}, .{ .width = 1, .cap = .round }, 0.25), v.accumulateStrokeEdges(&right, long.slice(), .{}, .{ .width = 1, .cap = .round }, 0.25));
    try compareRaster(&left, &right);
    core.rt.frameReset();
    try compareRaster(&left, &right);
}

test "compiled vector raster glyph budgets crossing failures clipping and complete emitted rows" {
    const left = try std.testing.allocator.create(v.GlyphRasterizer);
    defer std.testing.allocator.destroy(left);
    const right = try std.testing.allocator.create(v.GlyphRasterizer);
    defer std.testing.allocator.destroy(right);
    left.* = .{};
    right.* = .{ .policy = observed };
    for ([_]*const c.font_ttf.Face{ &c.font_ttf.geist_regular, &c.font_ttf.geist_mono }) |face| for ([_]u21{ 'A', 'g', 0xe9, 0x2122 }) |cp| {
        var builder = v.PathBuilder(1408){};
        try face.glyphOutline(face.glyphIndex(cp), .{ .a = 0.02125, .d = -0.02125, .tx = 2.25, .ty = 25.75 }, &builder);
        var a = Sink{};
        defer a.deinit();
        var b = Sink{};
        defer b.deinit();
        const clip = v.ClipRect{ .x0 = 0, .y0 = 0, .x1 = 40, .y1 = 40 };
        try compareResult(v.fillGlyphPath(left, builder.slice(), .{}, .nonzero, 0.25, clip, &a), v.fillGlyphPath(right, builder.slice(), .{}, .nonzero, 0.25, clip, &b));
        try compareRaster(left, right);
        try exact(a.values.items, b.values.items);
    };
    var a = v.RasterizerType(8, 1){};
    var b = v.RasterizerType(8, 1){ .policy = observed };
    const points = [_]sdk.geometry.PointF{ .init(0, 0), .init(0, 1), .init(0, 2), .init(3, 2), .init(3, 1), .init(3, 0) };
    for (0..points.len) |i| {
        try a.addEdge(points[i], points[(i + 1) % points.len]);
        try b.addEdge(points[i], points[(i + 1) % points.len]);
    }
    // Row zero has two crossings and fails before any pixel is emitted.
    try compareSweep(&a, &b, .nonzero, .{ .x0 = -1, .y0 = -1, .x1 = 4, .y1 = 4 });
    var wide_a = v.RasterizerType(8, 8){};
    var wide_b = v.RasterizerType(8, 8){ .policy = observed };
    try wide_a.addEdge(.init(0, 0), .init(9000, 2));
    try wide_b.addEdge(.init(0, 0), .init(9000, 2));
    try compareSweep(&wide_a, &wide_b, .even_odd, .{ .x0 = 0, .y0 = 0, .x1 = 10000, .y1 = 3 });
    // Clipping narrows that same shape into an admitted sweep.
    try compareSweep(&wide_a, &wide_b, .even_odd, .{ .x0 = 12, .y0 = 0, .x1 = 22, .y1 = 3 });
    var prefix_a = v.RasterizerType(8, 2){};
    var prefix_b = v.RasterizerType(8, 2){ .policy = observed };
    const starts = [_]sdk.geometry.PointF{ .init(0, 0), .init(3, 3), .init(1, 1), .init(2, 2) };
    const ends = [_]sdk.geometry.PointF{ .init(0, 3), .init(3, 0), .init(1, 2), .init(2, 1) };
    for (starts, ends) |start, end| {
        try prefix_a.addEdge(start, end);
        try prefix_b.addEdge(start, end);
    }
    const prefix_clip = v.ClipRect{ .x0 = 0, .y0 = 0, .x1 = 3, .y1 = 3 };
    var prefix = Sink{};
    defer prefix.deinit();
    try std.testing.expectError(error.VectorPathTooComplex, prefix_a.sweep(.nonzero, prefix_clip, &prefix));
    try std.testing.expectEqual(@as(usize, 3), prefix.values.items.len);
    try compareSweep(&prefix_a, &prefix_b, .nonzero, prefix_clip);
}

test "compiled vector raster admits complete dense glyph geometry at derived budgets" {
    var builder = v.PathBuilder(1408){};
    for (0..128) |contour| {
        const x: f32 = @floatFromInt(contour % 8);
        try builder.moveTo(.init(x, -20));
        for (0..8) |i| try builder.quadTo(.init(x + 64, if (i % 2 == 0) 96 else -96), .init(x, if (i % 2 == 0) 32 else -32));
        try builder.close();
    }
    const a = try std.testing.allocator.create(v.GlyphRasterizer);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(v.GlyphRasterizer);
    defer std.testing.allocator.destroy(b);
    a.* = .{};
    b.* = .{ .policy = observed };
    var left = Sink{};
    defer left.deinit();
    var right = Sink{};
    defer right.deinit();
    const clip = v.ClipRect{ .x0 = 0, .y0 = 0, .x1 = 8, .y1 = 8 };
    try v.fillGlyphPath(a, builder.slice(), .{}, .nonzero, 0.01, clip, &left);
    try v.fillGlyphPath(b, builder.slice(), .{}, .nonzero, 0.01, clip, &right);
    try std.testing.expect(a.edge_count > v.max_edges and a.edge_count <= v.max_glyph_fill_edges);
    try compareRaster(a, b);
    try exact(left.values.items, right.values.items);
}

test "compiled vector raster render pass retains static ownership and complete pixels" {
    var builder = buildPath(1);
    const commands = [_]c.RenderCommand{ .{
        .command = .{ .fill_path = .{ .id = 1, .elements = builder.slice(), .fill = .{ .color = .rgba(0.2, 0.3, 0.7, 0.75) } } },
        .bounds = .init(0, 0, 32, 32),
        .local_bounds = .init(0, 0, 32, 32),
        .opacity = 0.75,
    }, .{
        .command = .{ .stroke_path = .{ .id = 2, .elements = builder.slice(), .stroke = .{ .width = 2.25, .fill = .{ .color = .rgba(0.5, 0.1, 0.3, 0.9) } }, .cap = .round } },
        .bounds = .init(0, 0, 32, 32),
        .local_bounds = .init(0, 0, 32, 32),
        .opacity = 0.5,
    } };
    const pass = c.CanvasRenderPass{ .commands = &commands, .full_repaint = true };
    var compiled = pass;
    compiled.gpu_plan_policy = observed;
    var a: [32 * 32 * 4]u8 = undefined;
    var b: [32 * 32 * 4]u8 = undefined;
    const left = try c.ReferenceRenderSurface.init(32, 32, &a);
    const right = try c.ReferenceRenderSurface.init(32, 32, &b);
    calls = @splat(0);
    try left.renderPass(pass, .rgba(1, 1, 1, 1));
    try right.renderPass(compiled, .rgba(1, 1, 1, 1));
    try std.testing.expectEqualSlices(u8, &a, &b);
    for (calls) |count| try std.testing.expect(count > 0);
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, &a, &b);
}
