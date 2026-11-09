const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: [3]usize = @splat(0);
var pixel_bytes: usize = 0;
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 64) {
        calls[request[2]] += 1;
        if (request[2] == 0) pixel_bytes += std.mem.readInt(u32, request[28..][0..4], .little);
    }
    return core.nativeWindowPolicy(request, output);
}
fn compareImages(commands: []const c.RenderCommand, refs: []const c.ReferenceImage, capacity: usize) !void {
    const a = try std.testing.allocator.alloc(c.RenderImage, capacity);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(c.RenderImage, capacity);
    defer std.testing.allocator.free(b);
    var reference = c.RenderImagePlanner.init(a);
    reference.image_resources = refs;
    var candidate = c.RenderImagePlanner.init(b);
    candidate.image_resources = refs;
    const plan = c.RenderPlan{ .commands = commands };
    const native = reference.build(plan);
    calls = @splat(0);
    pixel_bytes = 0;
    const compiled = candidate.buildCompiled(plan, observed);
    if (native) |value| try exact(value, try compiled) else |err| try std.testing.expectError(err, compiled);
    try exact(reference.len, candidate.len);
    try exact(a[0..reference.len], b[0..candidate.len]);
    for (a[0..reference.len], b[0..candidate.len]) |left, right| try std.testing.expect(left.pixels.ptr == right.pixels.ptr);
    core.rt.frameReset();
    try exact(a[0..reference.len], b[0..candidate.len]);
}
fn compareLayers(commands: []const c.RenderCommand, capacity: usize) !void {
    const a = try std.testing.allocator.alloc(c.RenderLayer, capacity);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(c.RenderLayer, capacity);
    defer std.testing.allocator.free(b);
    var reference = c.RenderLayerPlanner.init(a);
    var candidate = c.RenderLayerPlanner.init(b);
    const plan = c.RenderPlan{ .commands = commands };
    const native = reference.build(plan);
    calls = @splat(0);
    const compiled = candidate.buildCompiled(plan, observed);
    if (native) |value| try exact(value, try compiled) else |err| try std.testing.expectError(err, compiled);
    try exact(@as(usize, 1), calls[1]);
    try exact(reference.len, candidate.len);
    try exact(a[0..reference.len], b[0..candidate.len]);
    core.rt.frameReset();
    try exact(a[0..reference.len], b[0..candidate.len]);
}
fn compareResources(commands: []const c.CanvasCommand, capacity: usize) !void {
    const a = try std.testing.allocator.alloc(c.RenderResource, capacity);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(c.RenderResource, capacity);
    defer std.testing.allocator.free(b);
    var reference = c.RenderResourcePlanner.init(a);
    var candidate = c.RenderResourcePlanner.init(b);
    const list = c.DisplayList{ .commands = commands };
    const native = reference.build(list);
    calls = @splat(0);
    const compiled = candidate.buildCompiled(list, observed);
    if (native) |value| try exact(value, try compiled) else |err| try std.testing.expectError(err, compiled);
    try exact(reference.len, candidate.len);
    try exact(a[0..reference.len], b[0..candidate.len]);
    core.rt.frameReset();
    try exact(a[0..reference.len], b[0..candidate.len]);
}
fn render(command: c.CanvasCommand, index: usize) c.RenderCommand {
    return .{ .command = command, .id = if (index % 3 == 0) null else if (index % 3 == 1) 0 else 0xffffffffffffffff, .opacity = 0.5, .bounds = .init(@floatFromInt(index), -2.5, 7.25, 9.5), .local_bounds = .init(-0.0, 0.125, 13.25, 17) };
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
test "compiled render resources preserve all raw command fields complete hashes order and capacity prefixes" {
    _ = core.initialModel();
    var commands: [scene.len]c.RenderCommand = undefined;
    for (scene, 0..) |command, i| commands[i] = render(command, i);
    for (0..scene.len + 2) |capacity| {
        try compareLayers(&commands, capacity);
        try compareResources(&scene, capacity);
    }
    try compareLayers(&.{}, 0);
    try compareResources(&.{}, 0);
}
test "compiled render resources image windows preserve first resource u64 dimensions source pixels and aggregation" {
    _ = core.initialModel();
    const pixels = try std.testing.allocator.alloc(u8, 131073);
    defer std.testing.allocator.free(pixels);
    for (pixels, 0..) |*byte, i| byte.* = @truncate(i *% 37);
    const id: u64 = 0xf123456789abcdef;
    const refs = [_]c.ReferenceImage{ .{ .id = id, .width = 0xf123456789abcdef, .height = 0xffffffffffffffff, .pixels = pixels }, .{ .id = id, .width = 1, .height = 1, .pixels = &.{ 255, 0, 0, 255 }, .content_fingerprint = 0xffffffffffffffff }, .{ .id = 7, .width = 2, .height = 3, .pixels = &.{1}, .content_fingerprint = 0xf123456789abcdef } };
    var commands = [_]c.RenderCommand{ render(scene[11], 0), render(scene[5], 1), render(scene[11], 2), render(.{ .draw_image = .{ .image_id = 7, .dst = .init(1, 2, 3, 4) } }, 3), render(.{ .draw_image = .{ .image_id = 0xffffffffffffffff, .dst = .init(1, 2, 3, 4) } }, 4), render(scene[11], 5) };
    for (0..5) |capacity| try compareImages(&commands, &refs, capacity);
    try std.testing.expect(pixel_bytes >= pixels.len * 3);
    commands[2].id = null;
    commands[5].id = null;
    for (0..4) |capacity| try compareImages(&commands, &refs, capacity);
    try compareImages(&.{}, &refs, 0);
    try compareImages(&commands, &.{}, 4);
}
test "compiled render resources layers retain gaps exact numeric ties empty bounds and optional identities" {
    _ = core.initialModel();
    for ([_]f32{ -16777216, -13.25, -0.0, 0, 0.000001, 0.125, 1, 13.25, 16777216 }) |x| for ([_]f32{ -0.0, 0, 0.5, 1 }) |opacity| {
        var commands = [_]c.RenderCommand{ render(scene[5], 0), render(scene[11], 0), render(scene[9], 0), render(scene[14], 0), render(scene[5], 0) };
        for (&commands, 0..) |*command, i| {
            command.opacity = opacity;
            command.bounds = .init(x, -0.0, if (i % 2 == 0) -13.25 else 7.25, if (i == 2) 0 else 9.5);
            command.id = if (i < 2) 0xffffffffffffffff else null;
            command.clip = if (i < 3) .init(x, -0.0, 7.25, 9.5) else null;
            command.transform.tx = if (i == 4) -0.0 else 0;
        }
        for (0..6) |capacity| try compareLayers(&commands, capacity);
    };
}
test "compiled render resources general bounds preserve raw gradients paths empty text and signed zero" {
    _ = core.initialModel();
    for ([_]f32{ -13.25, -0.0, 0, 0.125, 13.25, 16777216 }) |sample| {
        var commands = scene;
        commands[6].stroke_rect.stroke.width = sample;
        commands[8].draw_line.stroke.width = sample;
        commands[13].shadow.blur = sample;
        commands[13].shadow.spread = -sample;
        commands[14].blur.radius = sample;
        commands[12].draw_text.text_layout.?.max_width = sample;
        commands[12].draw_text.text_layout.?.line_height = sample;
        for ([_]usize{ 0, 1, 5, 8, 16 }) |capacity| try compareResources(&commands, capacity);
    }
    for ([_][]const u8{ "", "A café 🙂 界", "\x80\xffA" }) |text| {
        const command = c.CanvasCommand{ .draw_text = .{ .text = text, .size = 13.25, .origin = .init(-0.0, 17), .color = .{} } };
        for (0..3) |capacity| try compareResources(&.{ command, command }, capacity);
    }
}

const CapabilityRecord = struct { kind: u8 = 0, prefix: usize = 0, font: u64 = 0, size: f32 = 0, length: usize = 0, text: [32]u8 = @splat(0) };
const CapabilityContext = struct {
    planner: *c.RenderResourcePlanner,
    records: [128]CapabilityRecord = @splat(.{}),
    len: usize = 0,
    fn log(self: *@This(), kind: u8, font: u64, size: f32, text: []const u8) void {
        var record = CapabilityRecord{ .kind = kind, .prefix = self.planner.len, .font = font, .size = size, .length = text.len };
        @memcpy(record.text[0..text.len], text);
        self.records[self.len] = record;
        self.len += 1;
    }
    fn width(raw: ?*anyopaque, font: u64, size: f32, text: []const u8) f32 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.log(1, font, size, text);
        return @as(f32, @floatFromInt(text.len)) * 1.25;
    }
    fn ink(raw: ?*anyopaque, font: u64, size: f32, text: []const u8, metrics: *c.TextInkMetrics) bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.log(2, font, size, text);
        metrics.* = .{ .min_x = -1.25, .max_x = 7.25, .min_y = -2.5, .max_y = 13.25 };
        return true;
    }
};
test "compiled render resources publish complete prefixes before identical text capability calls" {
    _ = core.initialModel();
    for (0..6) |capacity| {
        var a: [5]c.RenderResource = undefined;
        var b: [5]c.RenderResource = undefined;
        var reference = c.RenderResourcePlanner.init(a[0..capacity]);
        var candidate = c.RenderResourcePlanner.init(b[0..capacity]);
        var left = CapabilityContext{ .planner = &reference };
        var right = CapabilityContext{ .planner = &candidate };
        const providers = [_]c.TextMeasureProvider{ .{ .context = &left, .measure_fn = CapabilityContext.width, .measure_ink_fn = CapabilityContext.ink }, .{ .context = &right, .measure_fn = CapabilityContext.width, .measure_ink_fn = CapabilityContext.ink } };
        var commands = [_]c.CanvasCommand{ scene[5], .{ .draw_text = .{ .font_id = 0xf123456789abcdef, .size = 13.25, .origin = .init(-0.0, 17), .color = .{}, .text = "A\x80" } }, scene[14], .{ .draw_text = .{ .font_id = 0xffffffffffffffff, .size = 7.25, .origin = .init(1.25, 9.5), .color = .{}, .text = "café" } }, scene[11] };
        commands[1].draw_text.measure = &providers[0];
        commands[3].draw_text.measure = &providers[0];
        const native = reference.build(c.DisplayList{ .commands = &commands });
        commands[1].draw_text.measure = &providers[1];
        commands[3].draw_text.measure = &providers[1];
        const compiled = candidate.buildCompiled(c.DisplayList{ .commands = &commands }, observed);
        if (native) |value| try exact(value, try compiled) else |err| try std.testing.expectError(err, compiled);
        try exact(left.records[0..left.len], right.records[0..right.len]);
        try exact(reference.len, candidate.len);
        try exact(a[0..reference.len], b[0..candidate.len]);
        core.rt.frameReset();
    }
}
