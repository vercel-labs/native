const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var crossings: [2]usize = @splat(0);
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 63) crossings[request[2]] += 1;
    return core.nativeWindowPolicy(request, output);
}
fn comparePaths(commands: []const c.RenderCommand, capacity: usize) !void {
    const a = try std.testing.allocator.alloc(c.RenderPathGeometry, capacity);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(c.RenderPathGeometry, capacity);
    defer std.testing.allocator.free(b);
    var reference = c.RenderPathGeometryPlanner.init(a);
    var candidate = c.RenderPathGeometryPlanner.init(b);
    const plan = c.RenderPlan{ .commands = commands };
    const native = reference.build(plan);
    crossings = @splat(0);
    const compiled = candidate.buildCompiled(plan, observed);
    if (native) |value| try exact(value, try compiled) else |err| try std.testing.expectError(err, compiled);
    try exact(@as(usize, 1), crossings[0]);
    try exact(reference.len, candidate.len);
    try exact(a[0..reference.len], b[0..candidate.len]);
    const view = core.nativeView(std.testing.allocator);
    defer std.testing.allocator.free(view);
    try exact(a[0..reference.len], b[0..candidate.len]);
    core.rt.frameReset();
}
fn compareEffects(commands: []const c.CanvasCommand, capacity: usize) !void {
    const a = try std.testing.allocator.alloc(c.VisualEffect, capacity);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(c.VisualEffect, capacity);
    defer std.testing.allocator.free(b);
    var reference = c.VisualEffectPlanner.init(a);
    var candidate = c.VisualEffectPlanner.init(b);
    const list = c.DisplayList{ .commands = commands };
    const native = reference.build(list);
    crossings = @splat(0);
    const compiled = candidate.buildCompiled(list, observed);
    if (native) |value| try exact(value, try compiled) else |err| try std.testing.expectError(err, compiled);
    try exact(@as(usize, 1), crossings[1]);
    try exact(reference.len, candidate.len);
    try exact(a[0..reference.len], b[0..candidate.len]);
    const view = core.nativeView(std.testing.allocator);
    defer std.testing.allocator.free(view);
    try exact(a[0..reference.len], b[0..candidate.len]);
    core.rt.frameReset();
}
fn path(elements: []const c.PathElement, width: ?f32, transform: c.Affine, id: ?u64) c.RenderCommand {
    return .{
        .command = if (width) |value| .{ .stroke_path = .{ .elements = elements, .stroke = .{ .fill = .{ .color = .{} }, .width = value } } } else .{ .fill_path = .{ .elements = elements, .fill = .{ .color = .{} } } },
        .id = id,
        .transform = transform,
        .local_bounds = .init(-1, 2, 7, 9),
        .bounds = .init(-1, 2, 7, 9),
    };
}
test "compiled vector resources preserve every path verb ordering complete counts and failure prefixes" {
    _ = core.initialModel();
    var elements: [4]c.PathElement = undefined;
    for (0..625) |sequence| {
        var rest = sequence;
        for (&elements) |*element| {
            element.* = .{ .verb = @enumFromInt(rest % 5), .points = .{ .init(-0.0, 0.125), .init(1.25, 2.5), .init(-3.75, 4.25) } };
            rest /= 5;
        }
        const commands = [_]c.RenderCommand{ path(&elements, null, .{}, 0xf123456789abcdef), path(&.{}, null, .{}, null), path(&elements, 1.25, .{}, 0) };
        for ([_]usize{ 0, 1, 2, 4 }) |capacity| try comparePaths(&commands, capacity);
    }
    try comparePaths(&.{}, 0);
}
test "compiled vector resources preserve exact stroke arithmetic high identities and nonfinite facts" {
    _ = core.initialModel();
    const elements = [_]c.PathElement{ .{ .verb = .move_to }, .{ .verb = .line_to }, .{ .verb = .quad_to }, .{ .verb = .cubic_to }, .{ .verb = .close } };
    const samples = [_]f32{ -std.math.inf(f32), -16777216, -13.25, -0.0, 0, 0.0000001, 0.125, 1.0000001, 13.25, 16777216, std.math.inf(f32), std.math.nan(f32) };
    for (samples) |width| for (samples) |axis| {
        const commands = [_]c.RenderCommand{ path(&elements, width, .{ .a = axis, .b = -axis, .c = 0.125, .d = 1.25 }, 0xffffffffffffffff), path(&elements, null, .{}, 0x100000001) };
        for ([_]usize{ 0, 1, 3 }) |capacity| try comparePaths(&commands, capacity);
    };
}
test "compiled vector resources preserve shadow blur bounds source hashes and caller ownership" {
    _ = core.initialModel();
    const samples = [_]f32{ -16777216, -13.25, -0.0, 0, 0.0000001, 0.125, 1.0000001, 13.25, 16777216, std.math.inf(f32), std.math.nan(f32) };
    for (samples) |margin| for (samples[0..9]) |extent| {
        const commands = [_]c.CanvasCommand{
            .{ .push_opacity = 0.5 },
            .{ .shadow = .{ .id = 0xffffffffffffffff, .rect = .init(-0.0, -2.5, extent, 11.25), .radius = .{ .top_left = -0.0, .top_right = 3.25, .bottom_right = 5, .bottom_left = -1 }, .offset = .{ .dx = -0.0, .dy = 2.25 }, .blur = margin, .spread = -margin, .color = .{ .r = 0.125, .g = -0.0, .b = 0.25, .a = 0.75 } } },
            .{ .blur = .{ .id = 0, .rect = .init(1.25, -0.0, extent, -13.25), .radius = margin } },
            .{ .shadow = .{ .id = 0x100000001, .rect = .init(16777216, 1, 1, 1), .blur = 0.5, .color = .{} } },
        };
        for ([_]usize{ 0, 1, 2, 4 }) |capacity| try compareEffects(&commands, capacity);
    };
    try compareEffects(&.{}, 0);
}
test "compiled vector resources use production plan entry points and unchanged cache owners" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const elements = [_]c.PathElement{ .{ .verb = .move_to }, .{ .verb = .line_to }, .{ .verb = .line_to }, .{ .verb = .close } };
    const commands = [_]c.RenderCommand{path(&elements, null, .{}, 0x100000001)};
    var a: [1]c.RenderPathGeometry = undefined;
    var b: [1]c.RenderPathGeometry = undefined;
    const plan = c.RenderPlan{ .commands = &commands };
    const native = try plan.pathGeometryPlan(&a);
    const compiled = try plan.pathGeometryPlanWithPolicy(&b, observed);
    try exact(native, compiled);
    var old: [1]c.RenderPathGeometryCacheEntry = undefined;
    var entries: [1]c.RenderPathGeometryCacheEntry = undefined;
    var actions: [1]c.RenderPathGeometryCacheAction = undefined;
    const first = try compiled.cachePlan(&.{}, 0xffffffffffffffff, &old, &actions);
    var workspace = c.RenderCacheWorkspace.init(core.nativeWindowPolicy, 2, 1, 2);
    defer workspace.deinit();
    const retained = try compiled.cachePlanWithWorkspace(&workspace, first.entries, 0, &entries, &actions);
    try exact(@as(usize, 1), retained.retainCount());
    const effects = c.DisplayList{ .commands = &.{.{ .blur = .{ .rect = .init(2, 3, 4, 5), .radius = 1.25 } }} };
    var aa: [1]c.VisualEffect = undefined;
    var bb: [1]c.VisualEffect = undefined;
    try exact(try effects.visualEffectPlan(&aa), try effects.visualEffectPlanWithPolicy(&bb, observed));
}
