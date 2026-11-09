const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const policy = c.GpuPacketPreparationPolicy;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: [2]usize = @splat(0);
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 71) calls[request[2]] += 1;
    return core.nativeWindowPolicy(request, output);
}
const stops = [_]c.GradientStop{ .{ .offset = -0.0, .color = .{ .r = 0.125, .g = -0.0, .b = 0.75, .a = 1 } }, .{ .offset = 1, .color = .{ .r = 1, .g = 0.25, .b = 0, .a = 0.5 } } };
const path = [_]c.PathElement{ .{ .verb = .move_to, .points = .{ .init(-0.0, 0.125), .init(13, 17), .init(-4, 9) } }, .{ .verb = .line_to, .points = .{ .init(7.25, 9.5), .init(-13, -17), .{} } }, .{ .verb = .quad_to }, .{ .verb = .cubic_to }, .{ .verb = .close } };
const glyphs = [_]c.Glyph{ .{ .id = 7, .font_id = 0xffffffffffffffff, .x = -0.0, .y = 0.125, .advance = 7.25, .text_start = 0, .text_len = 1 }, .{ .id = 0xffffffff, .font_id = 0x20000000000001, .x = 7.25, .y = -0.5, .advance = -0.0, .text_start = 0x20000000000001, .text_len = 0xf123456789abcdef } };
const base: c.CanvasGpuCommand = .{
    .command_index = 0x20000000000001,
    .kind = .draw_text,
    .id = 0xf123456789abcdef,
    .bounds = .init(-0.0, 1.25, 3.5, 7.75),
    .opacity = -0.0,
    .stroke_width = 0.125,
    .cap = .round,
    .clip = .init(1, 2, 3, 4),
    .transform = .{ .a = 1.25, .b = -0.0, .c = 0.5, .d = -2, .tx = 4.5, .ty = 6.75 },
    .shape = .{ .path = &path },
    .paint = .{ .linear_gradient = .{ .start = .init(-0.0, 3), .end = .init(7, 11), .stops = &stops } },
    .image = .{ .image_id = 0xffffffffffffffff, .src = .init(-0.0, 1, 2, 3), .dst = .init(1, 2, 3, 4), .opacity = -0.0, .fit = .cover, .sampling = .nearest, .radius = .{ .top_left = -0.0, .bottom_left = 7 } },
    .text = .{ .font_id = 0xf123456789abcdef, .size = 13.25, .origin = .init(-0.0, 17), .color = .{ .r = 0.125, .g = -0.0, .b = 0.75, .a = 0.5 }, .text = "A\x00\x80\xff", .glyphs = &glyphs, .text_layout = .{ .max_width = 7.25, .line_height = 17, .wrap = .word, .alignment = .center, .overflow = .clip } },
    .effect = .{ .shadow = .{ .rect = .init(-0.0, 1, -13.25, 17), .radius = .{ .top_left = -0.0, .bottom_right = 1.25 }, .offset = .{ .dx = -0.0, .dy = 2.5 }, .blur = 0.125, .spread = -1.25, .color = .{ .r = 1, .g = 0.5, .b = -0.0, .a = 0.25 } } },
};
fn compare(command: c.CanvasGpuCommand) !void {
    var result: [1]policy.Identity = undefined;
    const fingerprint = c.canvasGpuCommandFingerprint(command);
    const expected: policy.Identity = .{ .fingerprint = fingerprint, .key = c.canvasGpuPacketCommandKey(command, fingerprint) };
    try std.testing.expect(policy.identities(&.{command}, &result, false, observed));
    try exact(expected, result[0]);
    core.rt.frameReset();
    try exact(expected, result[0]);
}
test "compiled GPU packet preparation preserves every fingerprint field and exact u64 retain keys" {
    _ = core.initialModel();
    calls = @splat(0);
    for (std.enums.values(c.CanvasGpuCommandKind)) |kind| {
        var command = base;
        command.kind = kind;
        for ([_]?u64{ null, 0, 0x20000000000001, 0xffffffffffffffff }) |id| {
            command.id = id;
            try compare(command);
        }
    }
    const shapes = [_]c.CanvasGpuShape{ .none, .{ .rect = .init(-0.0, 1, 3, 4) }, .{ .rounded_rect = .{ .rect = .init(1, 2, 3, 4), .radius = .{ .bottom_left = -0.0, .top_right = 7 } } }, .{ .stroke_rect = .{ .rect = .init(1, 2, 3, 4), .radius = .{ .bottom_right = 1.25 }, .width = -0.0 } }, .{ .line = .{ .from = .init(-1.25, -0.0), .to = .init(3.5, 7), .width = 0.125 } }, .{ .path = &path } };
    for (shapes) |shape| {
        var command = base;
        command.shape = shape;
        try compare(command);
    }
    for ([_]c.CanvasGpuPaint{ .none, .{ .color = .{ .r = -0.0, .g = 0.125, .b = 1, .a = 0.75 } }, base.paint }) |paint| {
        var command = base;
        command.paint = paint;
        try compare(command);
    }
    var command = base;
    command.image = null;
    try compare(command);
    command = base;
    command.image.?.src = null;
    try compare(command);
    for (std.enums.values(c.ImageFit)) |fit| {
        command = base;
        command.image.?.fit = fit;
        try compare(command);
    }
    for (std.enums.values(c.ImageSampling)) |sampling| {
        command = base;
        command.image.?.sampling = sampling;
        try compare(command);
    }
    command = base;
    command.text = null;
    try compare(command);
    command = base;
    command.text.?.text_layout = null;
    try compare(command);
    for (std.enums.values(c.TextWrap)) |wrap| for (std.enums.values(c.TextAlign)) |alignment| for (std.enums.values(c.TextOverflow)) |overflow| {
        command = base;
        command.text.?.text_layout.?.wrap = wrap;
        command.text.?.text_layout.?.alignment = alignment;
        command.text.?.text_layout.?.overflow = overflow;
        try compare(command);
    };
    for ([_]f32{ -std.math.inf(f32), -1, -0.0, 0, 0.125, std.math.inf(f32), @bitCast(@as(u32, 0x7fc12345)) }) |value| {
        command = base;
        command.text.?.text_layout.?.max_width = value;
        command.text.?.text_layout.?.line_height = value;
        try compare(command);
        command = base;
        command.opacity = value;
        command.bounds.x = value;
        command.stroke_width = value;
        try compare(command);
    }
    command = base;
    command.effect = .none;
    try compare(command);
    command = base;
    command.effect = .{ .blur = .{ .rect = .init(-0.0, 3, 7, 11), .radius = 1.25 } };
    try compare(command);
    command = base;
    command.clip = null;
    command.cap = .butt;
    try compare(command);
    command = base;
    command.shape = .{ .path = &.{} };
    command.text.?.text = "";
    command.text.?.glyphs = &.{};
    try compare(command);
    try std.testing.expect(calls[0] >= 100);
}
test "compiled GPU packet preparation complete duplicate admission and owned outputs" {
    _ = core.initialModel();
    var commands = [_]c.CanvasGpuCommand{ base, base, base };
    var identities: [3]policy.Identity = undefined;
    try std.testing.expect(!policy.identities(&commands, &identities, true, observed));
    for (&commands, 0..) |*command, i| command.id = 0xffffffffffffffff - i;
    try std.testing.expect(policy.identities(&commands, &identities, true, observed));
    const retained = identities;
    @memset(&commands, .{ .command_index = 0, .kind = .unsupported });
    core.rt.frameReset();
    try exact(retained, identities);
    var empty: [0]policy.Identity = .{};
    try std.testing.expect(policy.identities(&.{}, &empty, true, observed));
    commands = .{ base, base, base };
    for (&commands, 0..) |*command, i| {
        command.id = null;
        command.command_index = 0x20000000000001 + i;
    }
    try std.testing.expect(policy.identities(&commands, &identities, true, observed));
    commands[2].command_index = commands[0].command_index;
    try std.testing.expect(!policy.identities(&commands, &identities, true, observed));
}
test "compiled GPU packet preparation complete edit flags match retained native identities across permutations" {
    _ = core.initialModel();
    var keys: [33]u64 = undefined;
    var fingerprints: [33]u64 = undefined;
    for (&keys, &fingerprints, 0..) |*key, *fingerprint, i| {
        key.* = 0xffffffffffffffff - i * 0x100000001;
        fingerprint.* = 0x20000000000001 + i;
    }
    var current: [34]policy.Identity = undefined;
    var matched: [33]bool = undefined;
    var upserts: [34]bool = undefined;
    for (0..34) |baseline_count| for (0..35) |current_count| {
        for (current[0..current_count], 0..) |*entry, i| entry.* = .{ .key = if (i < 33) keys[32 - i] else 0, .fingerprint = if (i < 33) fingerprints[32 - i] + (i % 2) else 9 };
        var expected_matched: [33]bool = @splat(false);
        var expected_upserts: [34]bool = @splat(false);
        var upsert_count: usize = 0;
        for (current[0..current_count], 0..) |entry, i| {
            expected_upserts[i] = true;
            for (keys[0..baseline_count], 0..) |key, j| if (key == entry.key) {
                expected_matched[j] = true;
                expected_upserts[i] = fingerprints[j] != entry.fingerprint;
                break;
            };
            upsert_count += @intFromBool(expected_upserts[i]);
        }
        var evict_count: usize = 0;
        for (expected_matched[0..baseline_count]) |flag| evict_count += @intFromBool(!flag);
        @memset(&matched, true);
        @memset(&upserts, true);
        const edits = policy.edits(current[0..current_count], keys[0..baseline_count], fingerprints[0..baseline_count], matched[0..baseline_count], upserts[0..current_count], observed);
        try exact(policy.Edits{ .upsert_count = upsert_count, .evict_count = evict_count }, edits);
        try exact(expected_matched[0..baseline_count], matched[0..baseline_count]);
        try exact(expected_upserts[0..current_count], upserts[0..current_count]);
        for (matched[baseline_count..]) |flag| try std.testing.expect(flag);
        for (upserts[current_count..]) |flag| try std.testing.expect(flag);
        core.rt.frameReset();
        try exact(expected_matched[0..baseline_count], matched[0..baseline_count]);
        try exact(expected_upserts[0..current_count], upserts[0..current_count]);
    };
}
const Current = struct { key: u64, fingerprint: u64, render_index: u32, bounds: sdk.geometry.RectF };
test "compiled GPU packet preparation gathers the complete supported list and refuses duplicate keys and exhausted storage" {
    _ = core.initialModel();
    const colors = [_]c.RenderCommand{
        .{ .command = .{ .fill_rect = .{ .rect = .init(0, 0, 8, 8), .fill = .{ .color = .{ .r = 1 } } } }, .bounds = .init(0, 0, 8, 8), .local_bounds = .init(0, 0, 8, 8), .id = 0xffffffffffffffff },
        .{ .command = .{ .fill_rect = .{ .rect = .init(10, 0, 8, 8), .fill = .{ .color = .{ .g = 1 } } } }, .bounds = .init(10, 0, 8, 8), .local_bounds = .init(10, 0, 8, 8) },
    };
    var output: [2]Current = undefined;
    const bounds: sdk.geometry.RectF = .init(0, 0, 20, 20);
    try std.testing.expectEqual(@as(?usize, 2), policy.gather(&colors, bounds, &output, observed));
    for (colors, output, 0..) |command, result, index| {
        const native = c.canvasGpuCommandFromRenderCommand(command, index);
        const fingerprint = c.canvasGpuCommandFingerprint(native);
        try exact(Current{ .key = c.canvasGpuPacketCommandKey(native, fingerprint), .fingerprint = fingerprint, .render_index = @intCast(index), .bounds = command.bounds }, result);
    }
    try std.testing.expectEqual(@as(?usize, null), policy.gather(&colors, bounds, output[0..1], observed));
    var duplicate = colors;
    duplicate[1].id = duplicate[0].id;
    try std.testing.expectEqual(@as(?usize, null), policy.gather(&duplicate, bounds, &output, observed));
    var unsupported = colors;
    unsupported[1].command = .{ .draw_text = .{ .size = 12, .origin = .{}, .color = .{}, .glyphs = &glyphs } };
    try std.testing.expectEqual(@as(?usize, null), policy.gather(&unsupported, bounds, &output, observed));
    unsupported[1].bounds = .init(100, 100, 4, 4);
    try std.testing.expectEqual(@as(?usize, 1), policy.gather(&unsupported, bounds, &output, observed));
    try std.testing.expectEqual(@as(?usize, 0), policy.gather(&.{}, bounds, output[0..0], observed));
}
