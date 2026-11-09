const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const p = c.GpuPresentationPolicy;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: usize = 0;
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 74) calls += 1;
    return core.nativeWindowPolicy(request, output);
}
// Independent decisions from the native presentation path. Preserve all
// baseline predicates, failure mutations and unsigned generation behavior.
fn reference(f: p.Facts, phase: p.Phase, outcome: p.Outcome) p.Program {
    var result: p.Program = .{ .instruction = .fallback, .invalidate_baseline = false, .patch_refused = false, .adopt_baseline = false, .full_present = false, .refusal = .none, .generation = f.generation };
    switch (phase) {
        .start => {
            result.instruction = if (f.binary) .gather else if (f.json) .json else .fallback;
            if (!f.binary and !f.json) result.refusal = .missing_service;
        },
        .gathered => {
            result.instruction = if (!f.current) .binary else if (f.baseline_valid and !f.baseline_pixels and
                f.surface.width == f.baseline_surface.width and f.surface.height == f.baseline_surface.height and f.scale == f.baseline_scale) .edits else .full;
            result.invalidate_baseline = !f.current;
        },
        .edits => {
            result.instruction = if (f.upserts >= f.count) .full else .patch;
        },
        .patch => {
            if (outcome == .ok) {
                result.instruction = .done;
                result.adopt_baseline = true;
            } else {
                result.instruction = .full;
                result.invalidate_baseline = outcome == .unsupported;
                result.patch_refused = outcome == .unsupported;
            }
        },
        .full, .binary => {
            if (outcome == .ok) {
                result.instruction = .done;
                result.adopt_baseline = phase == .full;
                result.full_present = phase == .binary;
            } else {
                result.invalidate_baseline = phase == .full;
                result.instruction = if (f.json) .json else .fallback;
                if (!f.json) result.refusal = if (outcome == .overflow) .binary_overflow else .missing_service;
            }
        },
        .json => {
            if (outcome == .ok) {
                result.instruction = .done;
                result.invalidate_baseline = true;
                result.full_present = true;
            } else result.refusal = if (outcome == .overflow) .json_overflow else .original;
        },
    }
    if (result.instruction == .full) result.generation = if (f.generation == std.math.maxInt(u64)) 1 else f.generation + 1;
    return result;
}
test "compiled GPU presentation complete transitions preserve baseline predicates refusals and exact u64 generations" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    calls = 0;
    for (0..32) |flags| for (std.enums.values(p.Phase)) |phase| for (std.enums.values(p.Outcome)) |outcome| {
        if (@intFromEnum(phase) < 3 and outcome != .ok) continue;
        for ([_]u64{ 0, 0xffffffff, 0x20000000000001, 0xfffffffffffffffe, 0xffffffffffffffff }) |generation| {
            for (0..8) |variant| {
                var facts: p.Facts = .{ .binary = flags & 1 != 0, .json = flags & 2 != 0, .current = flags & 4 != 0, .baseline_valid = flags & 8 != 0, .baseline_pixels = flags & 16 != 0, .generation = generation, .count = if (variant == 0) 0 else 4, .upserts = if (variant == 1) 4 else 0, .surface = .init(800.25, 600.5), .scale = 1.75, .baseline_surface = .init(800.25, 600.5), .baseline_scale = 1.75 };
                switch (variant) {
                    2 => facts.baseline_surface.width = 800.5,
                    3 => facts.baseline_surface.height = std.math.nan(f32),
                    4 => facts.scale = std.math.nan(f32),
                    5 => {
                        facts.surface.width = -0.0;
                        facts.baseline_surface.width = 0;
                    },
                    6 => {
                        facts.scale = std.math.inf(f32);
                        facts.baseline_scale = std.math.inf(f32);
                    },
                    7 => facts.baseline_scale = 2,
                    else => {},
                }
                const actual = p.plan(facts, phase, outcome, observed);
                try exact(reference(facts, phase, outcome), actual);
                core.rt.frameReset();
                try exact(reference(facts, phase, outcome), actual);
            }
        }
    };
    try std.testing.expectEqual(@as(usize, 19200), calls);
}

fn fatalPacket(_: ?*anyopaque, _: sdk.platform.GpuSurfacePacket) anyerror!void {
    return error.PresentationFailure;
}

fn runtimeEqual(a: anytype, b: anytype) !void {
    @setEvalBranchQuota(100000);
    try exact(sdk.runtime.testing.runtimeViewInfo(a.runtime.views[0]), sdk.runtime.testing.runtimeViewInfo(b.runtime.views[0]));
    const left = &a.runtime.views[0];
    const right = &b.runtime.views[0];
    inline for (@typeInfo(@TypeOf(left.*)).@"struct".fields) |field| {
        if (comptime std.mem.startsWith(u8, field.name, "canvas_packet_") or std.mem.startsWith(u8, field.name, "gpu_present_") or
            std.mem.startsWith(u8, field.name, "present_fallback_") or std.mem.startsWith(u8, field.name, "gpu_fallback_"))
        {
            // Only the live baseline prefix has been initialized.
            if (comptime std.mem.eql(u8, field.name, "canvas_packet_baseline_keys") or std.mem.eql(u8, field.name, "canvas_packet_baseline_fingerprints") or std.mem.eql(u8, field.name, "canvas_packet_baseline_bounds"))
                try exact(@field(left.*, field.name)[0..left.canvas_packet_baseline_count], @field(right.*, field.name)[0..right.canvas_packet_baseline_count])
            else
                try exact(@field(left.*, field.name), @field(right.*, field.name));
        }
    }
    const an = &a.null_platform;
    const bn = &b.null_platform;
    inline for (@typeInfo(@TypeOf(an.*)).@"struct".fields) |field| {
        if (comptime std.mem.startsWith(u8, field.name, "gpu_surface_packet_present_") and !std.mem.endsWith(u8, field.name, "storage") and
            !std.mem.endsWith(u8, field.name, "prefix")) try exact(@field(an.*, field.name), @field(bn.*, field.name));
    }
    try exact(an.gpu_surface_packet_present_binary_storage[0..an.gpu_surface_packet_present_binary_len], bn.gpu_surface_packet_present_binary_storage[0..bn.gpu_surface_packet_present_binary_len]);
}

test "compiled GPU presentation runtime preserves full patch refusal resync JSON fallback and complete baseline ownership" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const Storage = @import("render_cache_e2e_tests.zig").Storage;
    var storage_a = try Storage.init();
    defer storage_a.deinit();
    var storage_b = try Storage.init();
    defer storage_b.deinit();
    const pixels = try std.testing.allocator.alloc(u8, 64 * 48 * 4 * 4);
    defer std.testing.allocator.free(pixels);
    const transport = try std.testing.allocator.alloc(u8, sdk.platform.max_gpu_surface_packet_binary_bytes * 2);
    defer std.testing.allocator.free(transport);
    var packets_a: [32]c.CanvasGpuCommand = undefined;
    var packets_b: [32]c.CanvasGpuCommand = undefined;
    for (0..20) |scenario| {
        @memset(pixels, 0xa5);
        const a = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
        defer a.destroy(std.testing.allocator);
        const b = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
        defer b.destroy(std.testing.allocator);
        var context: u8 = 0;
        for ([_]@TypeOf(a){ a, b }, 0..) |h, lane| {
            h.null_platform.gpu_surfaces = true;
            h.null_platform.gpu_surface_packet_binary = true;
            h.runtime.options.pixel_present_retained_baseline = scenario == 16;
            try h.start(.{ .context = &context, .name = "gpu-presentation-parity", .source = sdk.platform.WebViewSource.html(""), .render_cache_policy = if (lane == 1 and scenario != 18) observed else null });
            _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 64, 48) });
            if (scenario == 6) h.runtime.views[0].canvas_packet_generation = 0xffffffffffffffff;
            if (scenario == 12) h.runtime.views[0].gpu_requested_backend = .software;
            if (scenario == 16 or scenario == 17) {
                h.runtime.options.platform.services.present_gpu_surface_packet_fn = null;
                h.runtime.options.platform.services.present_gpu_surface_packet_binary_fn = null;
            }
        }
        for (0..4) |step| {
            errdefer std.debug.print("presentation scenario {d}, step {d}\n", .{ scenario, step });
            for ([_]@TypeOf(a){ a, b }) |h| {
                if (step > 0) switch (scenario) {
                    1 => h.null_platform.gpu_surface_packet_binary_patch = false,
                    2 => h.null_platform.gpu_surface_packet_binary = false,
                    3 => h.runtime.options.platform.services.present_gpu_surface_packet_binary_fn = null,
                    4 => h.runtime.views[0].canvas_packet_baseline_pixels = true,
                    5 => h.runtime.views[0].canvas_packet_baseline_scale = 2,
                    9 => h.runtime.options.platform.services.present_gpu_surface_packet_binary_fn = fatalPacket,
                    10 => {
                        h.null_platform.gpu_surface_packet_binary = false;
                        h.null_platform.gpu_surface_packets = false;
                    },
                    11 => h.runtime.options.platform.services.present_gpu_surface_packet_fn = null,
                    19 => h.null_platform.gpu_surface_packet_binary = step % 2 == 0,
                    else => {},
                };
            }
            var scene = [_]c.CanvasCommand{
                .{ .fill_rect = .{ .id = 1, .rect = .init(2, 2, 8, 8), .fill = .{ .color = c.Color.rgb8(if (step % 2 == 0) 20 else 80, 30, 40) } } },
                .{ .fill_rect = .{ .id = if (scenario == 7) 0 else 2, .rect = .init(20, 2, 8, 8), .fill = .{ .color = c.Color.rgb8(30, 40, 50) } } },
            };
            if (scenario == 7) {
                // Unique authored ids can still collide with a synthesized
                // key. Reach the retained refusal without bypassing the
                // display-list validator's duplicate-object guard.
                const render = c.RenderCommand{ .command = scene[1], .bounds = .init(20, 2, 8, 8), .local_bounds = .init(20, 2, 8, 8) };
                const command = c.canvasGpuCommandFromRenderCommand(render, 1);
                scene[0].fill_rect.id = c.canvasGpuPacketCommandKey(command, c.canvasGpuCommandFingerprint(command));
            }
            for ([_]@TypeOf(a){ a, b }) |h| _ = try h.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &scene });
            const options = c.CanvasFrameOptions{ .frame_index = step + 1, .timestamp_ns = (step + 1) * 16000, .surface_size = .init(64, 48) };
            const byte_limit = if ((scenario == 8 or scenario == 11) and step > 0) 16 else sdk.platform.max_gpu_surface_packet_binary_bytes;
            var compiled_options = options;
            if (scenario == 18) compiled_options.render_cache_policy = observed;
            const ar = a.runtime.presentNextCanvasFrame(1, "canvas", options, storage_a.value, packets_a[0..if (scenario == 13) 0 else packets_a.len], transport[0..if (scenario == 14) 0 else byte_limit], pixels[0 .. 64 * 48 * 4], pixels[64 * 48 * 4 ..][0..if (scenario == 15) 0 else 64 * 48 * 4], c.Color.rgb8(1, 2, 3), null);
            const br = b.runtime.presentNextCanvasFrame(1, "canvas", compiled_options, storage_b.value, packets_b[0..if (scenario == 13) 0 else packets_b.len], transport[sdk.platform.max_gpu_surface_packet_binary_bytes..][0..if (scenario == 14) 0 else byte_limit], pixels[64 * 48 * 4 * 2 .. 64 * 48 * 4 * 3], pixels[64 * 48 * 4 * 3 ..][0..if (scenario == 15) 0 else 64 * 48 * 4], c.Color.rgb8(1, 2, 3), null);
            if (ar) |value| {
                const actual = try br;
                try @import("render_cache_e2e_tests.zig").frameEqual(value.frame, actual.frame, observed);
                inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
                    if (comptime !std.mem.eql(u8, field.name, "frame")) try exact(@field(value, field.name), @field(actual, field.name));
                }
                if (value.mode == .pixels) try std.testing.expectEqualSlices(u8, pixels[0 .. 64 * 48 * 4], pixels[64 * 48 * 4 * 2 .. 64 * 48 * 4 * 3]);
            } else |err| try std.testing.expectError(err, br);
            try runtimeEqual(a, b);
            core.rt.frameReset();
            try runtimeEqual(a, b);
        }
    }
}

test "compiled GPU presentation retains complete materialized commands and borrowed native payloads through frame reset" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const glyphs = [_]c.Glyph{.{ .id = 65535, .font_id = 0xffffffffffffffff, .x = -0.0, .y = 0.125, .advance = 7.25, .text_start = 0, .text_len = 1 }};
    const stops = [_]c.GradientStop{ .{ .offset = -0.0, .color = .{ .r = 0.125, .a = 1 } }, .{ .offset = 1, .color = .{ .b = 0.75, .a = 0.5 } } };
    const authored = [_]c.CanvasCommand{
        .{ .fill_rect = .{ .rect = .init(2, 4, -8, 7), .fill = .{ .linear_gradient = .{ .start = .init(-0.0, 0.25), .end = .init(8, 7), .stops = &stops } } } },
        .{ .draw_image = .{ .image_id = 0xffffffffffffffff, .src = .init(-0.0, 1, 2, 3), .dst = .init(2, 4, -8, 7), .fit = .contain, .sampling = .nearest, .opacity = -0.0 } },
        .{ .draw_text = .{ .font_id = 0xffffffffffffffff, .size = 13.25, .origin = .init(-0.0, 17), .text = "A\x00\x80\xff", .glyphs = &glyphs, .text_layout = .{ .max_width = 24 }, .color = .{ .r = 0.125, .b = -0.0, .a = 0.5 } } },
    };
    var source: [authored.len]c.RenderCommand = undefined;
    for (&source, authored, 0..) |*slot, command, i| slot.* = .{ .command = command, .id = 0xffffffffffffffff - i, .bounds = .init(@floatFromInt(i * 16), 0, 12, 20), .local_bounds = .init(-0.0, 0.125, 13.25, 17), .opacity = -0.0, .transform = .{ .tx = -0.0, .ty = 0.125 }, .clip = .init(0, 0, 64, 48) };
    const Current = struct { key: u64, fingerprint: u64, render_index: u32, bounds: sdk.geometry.RectF };
    var entries: [3]Current = undefined;
    const sentinel = c.CanvasGpuCommand{ .command_index = 0xabcdef, .kind = .unsupported };
    var actual: [4]c.CanvasGpuCommand = @splat(sentinel);
    try std.testing.expectEqual(@as(?usize, 3), c.GpuPacketPreparationPolicy.gatherMaterialized(&source, .init(0, 0, 64, 48), &entries, &actual, observed));
    for (source, actual[0..3], 0..) |command, result, i| try exact(c.canvasGpuCommandFromRenderCommand(command, i), result);
    try exact(sentinel, actual[3]);
    try std.testing.expect(actual[0].paint.linear_gradient.stops.ptr == &stops);
    try std.testing.expect(actual[2].text.?.glyphs.ptr == &glyphs);
    core.rt.frameReset();
    for (source, actual[0..3], 0..) |command, result, i| try exact(c.canvasGpuCommandFromRenderCommand(command, i), result);
}
