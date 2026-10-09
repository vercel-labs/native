const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: [4]usize = @splat(0);
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 65) calls[request[2]] += 1;
    return core.nativeWindowPolicy(request, output);
}
fn render(command: c.CanvasCommand, index: usize) c.RenderCommand {
    return .{ .command = command, .id = if (index % 3 == 0) null else if (index % 3 == 1) 0 else 0xffffffffffffffff, .opacity = -0.0, .bounds = .init(@floatFromInt(index), -2.5, 7.25, 9.5), .local_bounds = .init(-0.0, 0.125, 13.25, 17), .transform = .{ .tx = -0.0, .ty = 0.125 }, .clip = .init(0, 0, 24, 24) };
}
fn comparePackets(pass: c.CanvasRenderPass, capacity: usize, encode: bool) !void {
    const a = try std.testing.allocator.alloc(c.CanvasGpuCommand, capacity);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(c.CanvasGpuCommand, capacity);
    defer std.testing.allocator.free(b);
    @memset(a, .{ .command_index = 0xabcdef, .kind = .unsupported });
    @memset(b, .{ .command_index = 0xabcdef, .kind = .unsupported });
    var reference = c.CanvasGpuPacketPlanner.init(a);
    var candidate = c.CanvasGpuPacketPlanner.init(b);
    const native = reference.build(pass);
    calls = @splat(0);
    const compiled = candidate.buildCompiled(pass, observed);
    if (native) |value| {
        const result = try compiled;
        try exact(value, result);
        if (encode) {
            var left: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer left.deinit();
            var right: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer right.deinit();
            try value.writeJson(&left.writer);
            try result.writeJson(&right.writer);
            try std.testing.expectEqualSlices(u8, left.written(), right.written());
            left.clearRetainingCapacity();
            right.clearRetainingCapacity();
            try value.writeBinary(&left.writer);
            try result.writeBinary(&right.writer);
            try std.testing.expectEqualSlices(u8, left.written(), right.written());
        }
    } else |err| try std.testing.expectError(err, compiled);
    try exact(@as(usize, 1), calls[0]);
    try exact(reference.len, candidate.len);
    try exact(reference.unsupported_count, candidate.unsupported_count);
    try exact(a, b);
    core.rt.frameReset();
    try exact(a, b);
    var owned = pass;
    owned.gpu_plan_policy = observed;
    try exact(pass.gpuPacketSummary(), owned.gpuPacketSummary());
    try exact(@as(usize, 1), calls[1]);
    core.rt.frameReset();
}
fn compareEncoder(pass: c.CanvasRenderPass, capacity: usize) !void {
    const a = try std.testing.allocator.alloc(c.RenderEncoderCommand, capacity);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(c.RenderEncoderCommand, capacity);
    defer std.testing.allocator.free(b);
    @memset(a, .end_pass);
    @memset(b, .end_pass);
    var reference = c.RenderEncoderPlanner.init(a);
    var candidate = c.RenderEncoderPlanner.init(b);
    const native = reference.build(pass);
    calls = @splat(0);
    const compiled = candidate.buildCompiled(pass, observed);
    if (native) |value| try exact(value, try compiled) else |err| try std.testing.expectError(err, compiled);
    try exact(@as(usize, 1), calls[2]);
    try exact(reference.len, candidate.len);
    try exact(a, b);
    core.rt.frameReset();
    try exact(a, b);
    var owned = pass;
    owned.gpu_plan_policy = observed;
    try exact(pass.encoderCounts(), owned.encoderCounts());
    try exact(@as(usize, 1), calls[3]);
    core.rt.frameReset();
}
const stops = [_]c.GradientStop{ .{ .offset = -0.0, .color = .{ .r = 0.125, .g = -0.0, .b = 0.75, .a = 1 } }, .{ .offset = 1, .color = .{ .r = 1, .g = 0.25, .b = 0, .a = 0.5 } } };
const gradient = c.Fill{ .linear_gradient = .{ .start = .init(-0.0, 0.25), .end = .init(13.25, 17), .stops = &stops } };
const path = [_]c.PathElement{ .{ .verb = .move_to, .points = .{ .init(-0.0, 0.125), .init(13, 17), .init(-4, 9) } }, .{ .verb = .line_to, .points = .{ .init(7.25, 9.5), .init(-13, -17), .{} } }, .{ .verb = .quad_to }, .{ .verb = .cubic_to }, .{ .verb = .close } };
const glyphs = [_]c.Glyph{ .{ .id = 7, .font_id = 0xffffffffffffffff, .x = -0.0, .y = 0.125, .advance = 7.25, .text_start = 0, .text_len = 1 }, .{ .id = 0xffffffff, .x = 7.25, .y = -0.5, .advance = -0.0, .text_start = 1, .text_len = 2 } };
const scene = [_]c.CanvasCommand{
    .{ .push_clip = .{ .id = 0xffffffffffffffff, .rect = .init(-1, 2, 3, 4), .radius = .{ .top_left = 1.25 } } }, .pop_clip,                                                                                                                                                                                                                                    .{ .push_opacity = 0.5 },                                                                                                                                                                                                                                                                                                              .pop_opacity,                                                                                                                                                                                                                                                        .{ .transform = .{ .tx = 13.25 } },
    .{ .fill_rect = .{ .id = 0x100000001, .rect = .init(-0.0, 1, -13.25, 17), .fill = gradient } },               .{ .stroke_rect = .{ .rect = .init(-0.0, 0.125, 7.25, 9.5), .stroke = .{ .fill = gradient, .width = 1.25 }, .radius = .{ .bottom_left = -0.0, .top_right = 3 } } },                                                                           .{ .fill_rounded_rect = .{ .rect = .init(1, 2, 3, 4), .radius = .{ .top_left = 1.25 }, .fill = gradient } },                                                                                                                                                                                                                           .{ .draw_line = .{ .from = .init(1, 2), .to = .init(-3, -4), .stroke = .{ .fill = gradient, .width = 1.25 } } },                                                                                                                                                     .{ .fill_path = .{ .elements = &path, .fill = gradient } },
    .{ .stroke_path = .{ .elements = &path, .stroke = .{ .fill = gradient, .width = 0.125 }, .cap = .round } },   .{ .draw_image = .{ .id = 0xffffffffffffffff, .image_id = 0xf123456789abcdef, .src = .init(-0.0, 1, 2, 3), .dst = .init(1, -0.0, -13.25, 17), .fit = .contain, .sampling = .nearest, .opacity = 0.75, .radius = .{ .bottom_left = 1.25 } } }, .{ .draw_text = .{ .id = 0x100000001, .font_id = 0xf123456789abcdef, .size = 13.25, .origin = .init(-0.0, 17), .color = .{ .r = 0.125, .g = -0.0, .b = 0.75, .a = 0.5 }, .text = "A\x80\xff", .glyphs = &glyphs, .text_layout = .{ .max_width = 7.25, .line_height = 17, .wrap = .word, .alignment = .center, .overflow = .clip } } }, .{ .shadow = .{ .id = 0xffffffffffffffff, .rect = .init(-0.0, 1, -13.25, 17), .radius = .{ .top_left = -0.0, .bottom_right = 1.25 }, .offset = .{ .dx = -0.0, .dy = 2.5 }, .blur = 0.125, .spread = -1.25, .color = .{ .r = 1, .g = 0.5, .b = -0.0, .a = 0.25 } } }, .{ .blur = .{ .id = 0x100000001, .rect = .init(1, -0.0, 13.25, -17), .radius = 0.125 } },
};
test "compiled GPU planning preserves complete command payloads metadata summaries serialization and capacity prefixes" {
    _ = core.initialModel();
    var commands: [scene.len + 5]c.RenderCommand = undefined;
    for (scene, 0..) |command, i| commands[i] = render(command, i);
    commands[scene.len] = render(.{ .draw_text = .{ .font_id = 0xffffffffffffffff, .size = 13.25, .origin = .init(-0.0, 0.125), .text = "A\x80\xff", .glyphs = glyphs[0..1], .color = .{}, .text_layout = .{ .max_width = 24 } } }, 15);
    commands[scene.len + 1] = render(.{ .fill_rect = .{ .rect = .init(3, 4, -2, -3), .fill = .{ .color = .{} } } }, 16);
    commands[scene.len + 2] = render(.{ .stroke_rect = .{ .rect = .init(-0.0, 1, 3, 4), .stroke = .{ .width = -0.0, .fill = .{ .color = .{} } } } }, 17);
    commands[scene.len + 3] = render(.{ .fill_rounded_rect = .{ .rect = .init(1, 2, 3, 4), .fill = .{ .color = .{} }, .radius = .{ .top_left = -0.0 } } }, 18);
    commands[scene.len + 4] = render(.{ .draw_line = .{ .from = .init(-0.0, 0.125), .to = .init(-1, -2), .stroke = .{ .fill = .{ .color = .{} }, .width = -0.0 } } }, 19);
    const pass = c.CanvasRenderPass{ .commands = &commands, .full_repaint = true, .frame_index = 0xffffffffffffffff, .timestamp_ns = 0xf123456789abcdef, .surface_size = .init(320, 200), .scale = -0.0 };
    for (0..commands.len + 2) |capacity| try comparePackets(pass, capacity, false);
    try comparePackets(pass, commands.len, true);
    var clean = pass;
    clean.full_repaint = false;
    try comparePackets(clean, 0, true);
    try comparePackets(.{}, 0, true);
    for ([_]u32{ 0, 1, 65534, 65535, 65536, 0xffffffff }) |id| {
        var glyph: c.Glyph = glyphs[0];
        glyph.id = id;
        const text = render(.{ .draw_text = .{ .font_id = 0xffffffffffffffff, .size = 13.25, .origin = .init(-0.0, 0.125), .text = "A", .glyphs = &.{glyph}, .color = .{} } }, 0);
        try comparePackets(.{ .commands = &.{text}, .full_repaint = true }, 1, true);
    }
}

test "compiled GPU planning culling preserves negative rectangles nonfinite values signed zeros and selected source indices" {
    _ = core.initialModel();
    const samples = [_]f32{ -std.math.inf(f32), -16777216, -13.25, -0.0, 0, 0.000001, 0.125, 13.25, 16777216, std.math.inf(f32), std.math.nan(f32) };
    for (samples) |value| for (0..4) |axis| {
        var commands = [_]c.RenderCommand{ render(scene[5], 0), render(scene[12], 1), render(scene[11], 2), render(scene[13], 3) };
        for (&commands) |*command| {
            var coordinates = [_]f32{ -0.0, 0.125, 7.25, 9.5 };
            coordinates[axis] = value;
            command.bounds = .init(coordinates[0], coordinates[1], coordinates[2], coordinates[3]);
            command.command = .{ .fill_rect = .{ .rect = command.bounds, .fill = gradient } };
        }
        for ([_]sdk.geometry.RectF{ .init(-0.0, -0.0, 24, 24), .init(0.125, 0.125, -24, -24), .init(value, -0.0, 7.25, 9.5), .init(-0.0, 0.125, value, 9.5), .{} }) |dirty|
            for (0..6) |capacity| try comparePackets(.{ .commands = &commands, .dirty_bounds = dirty, .full_repaint = true }, capacity, false);
    };
}
fn action(comptime T: type) T {
    var value: T = std.mem.zeroes(T);
    value.kind = .evict;
    value.cache_index = 0xf123456789abcdef;
    if (comptime @hasField(T, "key")) {
        if (comptime @hasField(@TypeOf(value.key), "fingerprint")) value.key.fingerprint = 0xffffffffffffffff;
    }
    return value;
}

test "compiled GPU planning encoder preserves every cache family ordered payload repeated pipelines metadata and capacity prefixes" {
    _ = core.initialModel();
    const pipelines = [_]c.RenderPipelineCacheAction{ .{ .kind = .upload, .pipeline = .solid, .batch_index = 0 }, action(c.RenderPipelineCacheAction) };
    const paths = [_]c.RenderPathGeometryCacheAction{action(c.RenderPathGeometryCacheAction)};
    const images = [_]c.RenderImageCacheAction{action(c.RenderImageCacheAction)};
    const layers = [_]c.RenderLayerCacheAction{action(c.RenderLayerCacheAction)};
    const resources = [_]c.RenderResourceCacheAction{action(c.RenderResourceCacheAction)};
    const effects = [_]c.VisualEffectCacheAction{action(c.VisualEffectCacheAction)};
    const atlas = [_]c.GlyphAtlasCacheAction{action(c.GlyphAtlasCacheAction)};
    const layouts = [_]c.TextLayoutCacheAction{action(c.TextLayoutCacheAction)};
    var batches: [10]c.RenderBatch = undefined;
    for (&batches, 0..) |*batch, i| batch.* = .{ .pipeline = @enumFromInt((i / 2) % 7), .command_start = i * 3, .command_count = i, .bounds = .init(-0.0, 0.125, 7.25, 9.5) };
    const pass = c.CanvasRenderPass{ .full_repaint = true, .dirty_bounds = .init(-0.0, 0.125, 24, 24), .surface_size = .init(320, 200), .scale = -0.0, .batches = &batches, .pipeline_actions = &pipelines, .path_geometry_actions = &paths, .image_actions = &images, .layer_actions = &layers, .resource_actions = &resources, .visual_effect_actions = &effects, .glyph_atlas_actions = &atlas, .text_layout_actions = &layouts };
    for (0..pass.encoderCommandCount() + 2) |capacity| try compareEncoder(pass, capacity);
    var clean = pass;
    clean.full_repaint = false;
    clean.dirty_bounds = null;
    try compareEncoder(clean, 0);
    try compareEncoder(.{ .full_repaint = true }, 2);
    try compareEncoder(.{ .dirty_bounds = .{} }, 3);
    for (0..batches.len + 1) |length| {
        var partial = pass;
        partial.batches = batches[0..length];
        try compareEncoder(partial, 64);
    }
}

fn framePlanning(expected: c.CanvasFrame, actual: c.CanvasFrame) !void {
    try std.testing.expect(expected.gpu_plan_policy == null);
    try std.testing.expect(actual.gpu_plan_policy == observed);
    try std.testing.expect(actual.renderPass().gpu_plan_policy == observed);
    inline for (@typeInfo(c.CanvasFrame).@"struct".fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "dirty_rects") and !std.mem.eql(u8, field.name, "gpu_plan_policy"))
            try exact(@field(expected, field.name), @field(actual, field.name));
    }
    try exact(expected.dirtyRects(), actual.dirtyRects());
    calls = @splat(0);
    var a: [64]c.CanvasGpuCommand = undefined;
    var b: [64]c.CanvasGpuCommand = undefined;
    try exact(try expected.gpuPacket(&a), try actual.gpuPacket(&b));
    var aa: [128]c.RenderEncoderCommand = undefined;
    var bb: [128]c.RenderEncoderCommand = undefined;
    try exact(try expected.renderPass().encoderPlan(&aa), try actual.renderPass().encoderPlan(&bb));
    try exact(expected.gpuPacketSummary(), actual.gpuPacketSummary());
    try exact(expected.renderPass().encoderCounts(), actual.renderPass().encoderCounts());
    try exact([_]usize{ 1, 1, 1, 1 }, calls);
    const summary = actual.gpuPacketSummary();
    const encoder = actual.renderPass().encoderCounts();
    const before = calls;
    try exact(expected.budgetStatus(), actual.budgetStatusFromPlanningSummaries(summary, encoder));
    try exact(before, calls);
    try exact(expected.diagnostics(), actual.diagnostics());
    try exact(expected.budgetStatus(), actual.budgetStatus());
    core.rt.frameReset();
    // The result payloads borrow native frame data, never the policy arena.
    try exact(a[0..expected.gpuPacketSummary().command_count], b[0..expected.gpuPacketSummary().command_count]);
    try exact(aa[0..expected.renderPass().encoderCommandCount()], bb[0..expected.renderPass().encoderCommandCount()]);
}

test "compiled GPU planning propagates through display lists and both runtime frame APIs with complete diagnostics and budgets" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const reference = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
    defer reference.destroy(std.testing.allocator);
    const compiled = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
    defer compiled.destroy(std.testing.allocator);
    var context: u8 = 0;
    for ([_]@TypeOf(reference){ reference, compiled }, 0..) |h, lane| {
        h.null_platform.gpu_surfaces = true;
        try h.start(.{ .context = &context, .name = "gpu-planning-parity", .source = sdk.platform.WebViewSource.html(""), .render_cache_policy = if (lane == 1) observed else null });
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 160, 120) });
    }
    const Storage = @import("render_cache_e2e_tests.zig").Storage;
    var a = try Storage.init();
    defer a.deinit();
    var b = try Storage.init();
    defer b.deinit();
    var initial = scene;
    initial[0].push_clip.id = 1;
    initial[5].fill_rect.id = 5;
    initial[11].draw_image.id = 11;
    initial[12].draw_text.id = 12;
    initial[13].shadow.id = 13;
    initial[14].blur.id = 14;
    var changed = initial;
    changed[11].draw_image.image_id = 18;
    const options = c.CanvasFrameOptions{ .full_repaint = true, .surface_size = .init(160, 120), .frame_index = 0xffffffffffffffff, .timestamp_ns = 0xf123456789abcdef, .budget = .{ .max_commands = 1, .max_batches = 1, .max_encoder_commands = 1, .max_resources = 1 } };
    for ([_][]const c.CanvasCommand{ &initial, &initial, &changed, &.{} }) |commands| {
        const list = c.DisplayList{ .commands = commands };
        var owned_options = options;
        owned_options.render_cache_policy = observed;
        try framePlanning(try list.framePlan(null, options, a.value), try list.framePlan(null, owned_options, b.value));
        for ([_]@TypeOf(reference){ reference, compiled }) |h| _ = try h.runtime.setCanvasDisplayList(1, "canvas", list);
        try framePlanning(try reference.runtime.canvasFramePlan(1, "canvas", null, options, a.value), try compiled.runtime.canvasFramePlan(1, "canvas", null, options, b.value));
        try framePlanning(try reference.runtime.nextCanvasFrame(1, "canvas", options, a.value), try compiled.runtime.nextCanvasFrame(1, "canvas", options, b.value));
    }
    const list = c.DisplayList{ .commands = scene[5..8] };
    try framePlanning(try list.framePlan(list, .{}, a.value), try list.framePlan(list, .{ .render_cache_policy = observed }, b.value));
}
