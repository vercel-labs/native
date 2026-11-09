const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const canvas = sdk.canvas;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const Workspace = canvas.RenderCacheWorkspace;
const draw = canvas.CanvasCommand{ .fill_rect = .{ .id = 9007199254740993, .rect = .init(-2, 1, 17, 13), .fill = .{ .color = canvas.Color.rgb8(30, 80, 130) } } };
const sentinel = canvas.RenderCommand{ .command = draw, .id = 99, .opacity = 0.125, .clip = .init(99, 98, 97, 96), .transform = .translate(93, 94), .local_bounds = .init(95, 94, 93, 92), .bounds = .init(91, 90, 89, 88) };

fn stateParity(commands: []const canvas.CanvasCommand, capacity: usize) !void {
    const a = try std.testing.allocator.alloc(canvas.RenderCommand, capacity);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(canvas.RenderCommand, capacity);
    defer std.testing.allocator.free(b);
    @memset(a, sentinel);
    @memset(b, sentinel);
    var native = canvas.RenderPlanner.init(a);
    var compiled = canvas.RenderPlanner.init(b);
    native.clip_stack = .{sdk.geometry.RectF.init(41, 42, 43, 44)} ** 32;
    compiled.clip_stack = native.clip_stack;
    native.opacity_stack = .{0.125} ** 32;
    compiled.opacity_stack = native.opacity_stack;
    var workspace = Workspace.initPlanning(core.nativeWindowPolicy, commands.len, capacity);
    defer workspace.deinit();
    const list = canvas.DisplayList{ .commands = commands };
    const expected = native.build(list);
    const actual = compiled.buildCompiled(list, core.nativeWindowPolicy, &workspace);
    if (expected) |value| try exact(value, try actual) else |err| try std.testing.expectError(err, actual);
    try exact(native.len, compiled.len);
    try exact(native.state, compiled.state);
    try exact(native.bounds_value, compiled.bounds_value);
    try exact(native.clip_stack_len, compiled.clip_stack_len);
    try exact(native.opacity_stack_len, compiled.opacity_stack_len);
    try exact(native.clip_stack, compiled.clip_stack);
    try exact(native.opacity_stack, compiled.opacity_stack);
    try exact(a, b);
}

fn batchParity(commands: []const canvas.RenderCommand, capacity: usize, bounds: ?sdk.geometry.RectF) !void {
    const a = try std.testing.allocator.alloc(canvas.RenderBatch, capacity);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(canvas.RenderBatch, capacity);
    defer std.testing.allocator.free(b);
    const initial = canvas.RenderBatch{ .pipeline = .shadow, .command_start = 37, .command_count = 41, .bounds = .init(99, 98, 97, 96) };
    @memset(a, initial);
    @memset(b, initial);
    var native = canvas.RenderBatchPlanner.init(a);
    var compiled = canvas.RenderBatchPlanner.init(b);
    var workspace = Workspace.initPlanning(core.nativeWindowPolicy, commands.len, capacity);
    defer workspace.deinit();
    const plan = canvas.RenderPlan{ .commands = commands, .bounds = bounds };
    const expected = native.build(plan);
    const actual = compiled.buildCompiled(plan, core.nativeWindowPolicy, &workspace);
    if (expected) |value| try exact(value, try actual) else |err| try std.testing.expectError(err, actual);
    try exact(native.len, compiled.len);
    try exact(a, b);
}

const samples = [_]f32{ -16777216, -240.00002, -1, -0.0, 0, 0.000001, 1.0000001, 23.999998, 24.000002, 16777216, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) };
test "compiled render stacks preserve every f32 state command bound and written or untouched slot" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var commands = [_]canvas.CanvasCommand{
        .{ .transform = .{ .a = 0.9, .b = -0.2, .c = 0.3, .d = 1.1, .tx = 1.125, .ty = -0.125 } },
        .{ .push_clip = .{ .rect = .init(40, 30, -80, -60) } },
        .{ .push_opacity = 0.75 },
        draw,
        .{ .transform = .{ .a = 0.5, .b = 0.125, .c = -0.25, .d = 0.5, .tx = 2.1, .ty = -3.2 } },
        .{ .push_clip = .{ .rect = .init(-10, -8, 25, 21) } },
        .{ .push_opacity = 0.5 },
        draw,
        .pop_clip,
        .pop_opacity,
        draw,
        .pop_opacity,
        .pop_clip,
        draw,
    };
    for ([_]usize{ 0, 1, 2, 20 }) |capacity| try stateParity(&commands, capacity);
    for (0..6) |axis| {
        const original = commands[0].transform;
        for (samples) |sample| {
            if (builtin.mode != .ReleaseFast and !std.math.isFinite(sample)) continue;
            switch (axis) {
                0 => commands[0].transform.a = sample,
                1 => commands[0].transform.b = sample,
                2 => commands[0].transform.c = sample,
                3 => commands[0].transform.d = sample,
                4 => commands[0].transform.tx = sample,
                else => commands[0].transform.ty = sample,
            }
            try stateParity(&commands, 20);
            core.rt.frameReset();
        }
        commands[0].transform = original;
    }
    for (samples) |sample| {
        commands[2].push_opacity = sample;
        try stateParity(&commands, 20);
        core.rt.frameReset();
    }
}

test "compiled render failure precedence includes both stacks invisible draws and capacity partial writes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var commands: [35]canvas.CanvasCommand = undefined;
    for ([_]bool{ false, true }) |opacity| {
        @memset(&commands, if (opacity) .{ .push_opacity = 0.5 } else .{ .push_clip = .{ .rect = .init(0, 0, 30, 30) } });
        commands[0] = draw;
        for ([_]usize{ 0, 1, 9 }) |capacity| {
            try stateParity(&commands, capacity);
            core.rt.frameReset();
        }
        @memset(&commands, if (opacity) .pop_opacity else .pop_clip);
        commands[0] = draw;
        try stateParity(&commands, 9);
        core.rt.frameReset();
    }
    try stateParity(&.{ .{ .push_opacity = -1 }, draw, .pop_clip }, 0);
    core.rt.frameReset();
    try stateParity(&.{ .{ .push_clip = .{ .rect = .init(90, 90, 10, 10) } }, draw, .pop_clip, .{ .fill_path = .{ .elements = &.{}, .fill = .{ .color = canvas.Color.rgb8(1, 2, 3) } } } }, 0);
    core.rt.frameReset();
    try stateParity(&.{}, 0);
}

test "compiled batching chooses all pipelines and preserves full successful and partial batch storage" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const stops = [_]canvas.GradientStop{ .{ .offset = 0, .color = canvas.Color.rgb8(10, 20, 30) }, .{ .offset = 1, .color = canvas.Color.rgb8(30, 20, 10) } };
    const gradient = canvas.Fill{ .linear_gradient = .{ .start = .init(0, 0), .end = .init(4, 4), .stops = &stops } };
    const kinds = [_]canvas.CanvasCommand{
        draw,                                                                                          .{ .stroke_rect = .{ .rect = .init(1, 1, 9, 9), .stroke = .{ .fill = .{ .color = canvas.Color.rgb8(1, 2, 3) }, .width = 1 } } },
        .{ .fill_rounded_rect = .{ .rect = .init(1, 1, 9, 9), .radius = .all(2), .fill = gradient } }, .{ .draw_line = .{ .from = .init(1, 1), .to = .init(4, 4), .stroke = .{ .fill = gradient, .width = 1 } } },
        .{ .fill_path = .{ .elements = &.{}, .fill = gradient } },                                     .{ .stroke_path = .{ .elements = &.{}, .stroke = .{ .fill = gradient, .width = 1 } } },
        .{ .draw_image = .{ .image_id = 9007199254740993, .dst = .init(0, 0, 5, 5) } },                .{ .draw_text = .{ .text = "text", .origin = .init(0, 0), .size = 12, .color = canvas.Color.rgb8(1, 2, 3) } },
        .{ .shadow = .{ .rect = .init(0, 0, 5, 5), .color = canvas.Color.rgb8(1, 2, 3) } },            .{ .blur = .{ .rect = .init(0, 0, 5, 5), .radius = 2 } },
        .{ .push_clip = .{ .rect = .init(0, 0, 5, 5) } },                                              .pop_clip,
        .{ .push_opacity = 0.5 },                                                                      .pop_opacity,
        .{ .transform = .{} },
    };
    var commands: [kinds.len]canvas.RenderCommand = undefined;
    for (kinds, 0..) |command, i| {
        commands[i] = sentinel;
        commands[i].command = command;
        commands[i].opacity = 0.5;
        commands[i].clip = null;
        commands[i].bounds = .init(@floatFromInt(i), 2, 10, 4);
    }
    for ([_]usize{ 0, 1, 2, 6, 32 }) |capacity| {
        try batchParity(&commands, capacity, .init(-0.0, 0.125, 100, 50));
        core.rt.frameReset();
    }
    for (samples) |sample| {
        commands[1].opacity = sample;
        commands[1].clip = .init(sample, -0.0, 17, 13);
        commands[2].clip = commands[1].clip;
        try batchParity(&commands, 32, null);
        core.rt.frameReset();
    }
    try batchParity(&.{}, 0, .init(99, 98, -3, 4));
}

extern fn nsc_core_native_view(out: *[*]const u8, len: *usize) callconv(.c) void;
test "shared render planning buffers preserve borrowed commands core bytes and view ABI data" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const borrowed = core.rt.frameAlloc(u8, 10);
    @memcpy(borrowed, "render\x00abi");
    var view: [*]const u8 = undefined;
    var view_len: usize = 0;
    nsc_core_native_view(&view, &view_len);
    const saved = try std.testing.allocator.dupe(u8, view[0..view_len]);
    defer std.testing.allocator.free(saved);
    const commands = [_]canvas.CanvasCommand{ draw, .{ .draw_text = .{ .id = 0xffffffffffffffff, .text = borrowed, .origin = .init(0, 0), .size = 12, .color = canvas.Color.rgb8(1, 2, 3) } }, draw };
    var rendered: [8]canvas.RenderCommand = undefined;
    var batches: [8]canvas.RenderBatch = undefined;
    var workspace = Workspace.initPlanning(core.nativeWindowPolicy, commands.len, batches.len);
    defer workspace.deinit();
    const plan = try (canvas.DisplayList{ .commands = &commands }).renderPlanWithWorkspace(&rendered, core.nativeWindowPolicy, &workspace);
    const retained = try std.testing.allocator.dupe(canvas.RenderCommand, plan.commands);
    defer std.testing.allocator.free(retained);
    _ = try plan.batchPlanWithWorkspace(&batches, core.nativeWindowPolicy, &workspace);
    try exact(@as([]const canvas.RenderCommand, retained), plan.commands);
    try std.testing.expectEqualSlices(u8, "render\x00abi", borrowed);
    try std.testing.expectEqualSlices(u8, saved, view[0..view_len]);
    try std.testing.expectEqual(@as(?u64, 0xffffffffffffffff), plan.commands[1].id);
    try std.testing.expect(plan.commands[1].command.draw_text.text.ptr == borrowed.ptr);
    core.rt.frameReset();
    // Native command storage survives collection; borrowed payloads are not
    // dereferenced after their owning frame ends.
    try exact(retained[0], plan.commands[0]);
}

var measurement_calls: usize = 0;
fn orderedMeasure(_: ?*anyopaque, _: canvas.FontId, _: f32, _: []const u8) f32 {
    measurement_calls += 1;
    return @as(f32, @floatFromInt(measurement_calls)) * 7;
}
test "render continuations preserve observable measurement order visibility and failure precedence" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const provider = canvas.TextMeasureProvider{ .measure_fn = orderedMeasure };
    const text = canvas.CanvasCommand{ .draw_text = .{ .id = 9007199254740993, .size = 12, .color = canvas.Color.rgb8(10, 20, 30), .origin = .init(0, 20), .text = "measure", .measure = &provider } };
    const cases = [_][]const canvas.CanvasCommand{
        &.{ text, text, text },
        &.{ .{ .push_opacity = 0 }, text, .pop_opacity, text },
        &.{ draw, .pop_clip, text },
        &.{ draw, text, text },
        &.{ .{ .push_clip = .{ .rect = .init(1000, 1000, 1, 1) } }, text, .pop_clip, text },
    };
    for (cases) |commands| for ([_]usize{ 0, 1, 4 }) |capacity| {
        var a: [4]canvas.RenderCommand = .{sentinel} ** 4;
        var b = a;
        var native = canvas.RenderPlanner.init(a[0..capacity]);
        var compiled = canvas.RenderPlanner.init(b[0..capacity]);
        var workspace = Workspace.initPlanning(core.nativeWindowPolicy, commands.len, 4);
        defer workspace.deinit();
        measurement_calls = 0;
        const expected = native.build(.{ .commands = commands });
        const calls = measurement_calls;
        measurement_calls = 0;
        const actual = compiled.buildCompiled(.{ .commands = commands }, core.nativeWindowPolicy, &workspace);
        if (expected) |value| try exact(value, try actual) else |err| try std.testing.expectError(err, actual);
        try std.testing.expectEqual(calls, measurement_calls);
        try exact(native.len, compiled.len);
        try exact(native.state, compiled.state);
        try exact(native.bounds_value, compiled.bounds_value);
        try exact(a, b);
        core.rt.frameReset();
    };
}

test "native measurement callbacks observe the same accepted planner prefix during continuations" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const Context = struct {
        planner: *canvas.RenderPlanner,
        fn measure(pointer: ?*anyopaque, _: canvas.FontId, _: f32, _: []const u8) f32 {
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            return 11 + @as(f32, @floatFromInt(self.planner.len)) + self.planner.state.opacity + @as(f32, @floatFromInt(self.planner.clip_stack_len));
        }
    };
    var a: [4]canvas.RenderCommand = .{sentinel} ** 4;
    var b = a;
    var native = canvas.RenderPlanner.init(&a);
    var compiled = canvas.RenderPlanner.init(&b);
    var context = Context{ .planner = &native };
    const provider = canvas.TextMeasureProvider{ .context = &context, .measure_fn = Context.measure };
    const text = canvas.CanvasCommand{ .draw_text = .{ .size = 12, .origin = .init(0, 20), .color = canvas.Color.rgb8(10, 20, 30), .text = "prefix", .text_layout = .{ .wrap = .none, .measure = &provider } } };
    const list = canvas.DisplayList{ .commands = &.{ draw, .{ .push_opacity = 0.5 }, .{ .push_clip = .{ .rect = .init(0, 0, 100, 100) } }, text, text, .pop_clip, .pop_opacity } };
    const expected = try native.build(list);
    context.planner = &compiled;
    var workspace = Workspace.initPlanning(core.nativeWindowPolicy, list.commands.len, 4);
    defer workspace.deinit();
    try exact(expected, try compiled.buildCompiled(list, core.nativeWindowPolicy, &workspace));
    try exact(a, b);
}
