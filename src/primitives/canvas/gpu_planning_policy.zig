//! Copied GPU admission facts and encoder programs. Payload pointers and
//! caller buffers remain native, including text measurement contexts.
const std = @import("std");
const canvas = @import("root.zig");
const gpu = @import("gpu.zig");
const geometry = @import("geometry");
const wire = @import("glyph_atlas_policy.zig");
pub const Policy = wire.Policy;
const allocator = std.heap.page_allocator;
const word = wire.word;
const put = wire.put;
const float = wire.float;
const readFloat = wire.readFloat;
pub const Mode = enum(u8) { packet, packet_summary, encoder, encoder_summary };
pub const EncoderCounts = struct { commands: usize = 0, caches: usize = 0, binds: usize = 0, draws: usize = 0 };

fn add(a: usize, b: usize) usize {
    return std.math.add(usize, a, b) catch @panic("GPU planning size overflow");
}
fn mul(a: usize, b: usize) usize {
    return std.math.mul(usize, a, b) catch @panic("GPU planning size overflow");
}
fn alloc(size: usize) []u8 {
    return allocator.alloc(u8, size) catch @panic("GPU planning allocation failed");
}
fn rect(bytes: []u8, at: usize, value: geometry.RectF) void {
    inline for (.{ "x", "y", "width", "height" }, 0..) |field, i| float(bytes, at + i * 4, @field(value, field));
}
fn readRect(bytes: []const u8, at: usize) geometry.RectF {
    return .{ .x = readFloat(bytes, at), .y = readFloat(bytes, at + 4), .width = readFloat(bytes, at + 8), .height = readFloat(bytes, at + 12) };
}
const families = .{ "pipeline_actions", "path_geometry_actions", "image_actions", "layer_actions", "resource_actions", "visual_effect_actions", "glyph_atlas_actions", "text_layout_actions" };
fn request(pass: anytype, mode: Mode, capacity: usize) []u8 {
    const packets = mode == .packet or mode == .packet_summary;
    const commands = if (packets) pass.commands.len else 0;
    const batches = if (packets) 0 else pass.batches.len;
    var glyphs: usize = 0;
    if (packets) for (pass.commands) |command| {
        if (command.command == .draw_text) glyphs = add(glyphs, command.command.draw_text.glyphs.len);
    };
    const bytes = alloc(add(add(96, mul(commands, 64)), mul(add(glyphs, batches), 4)));
    @memset(bytes, 0);
    bytes[0..4].* = .{ 65, 1, @intFromEnum(mode), @import("render_plan_policy.zig").numericFlags() };
    put(bytes, 4, commands);
    put(bytes, 8, capacity);
    put(bytes, 12, @as(u32, @intFromBool(pass.full_repaint)) | (@as(u32, @intFromBool(pass.dirty_bounds != null)) << 1));
    put(bytes, 16, glyphs);
    put(bytes, 20, batches);
    inline for (families, 0..) |field, i| put(bytes, 24 + i * 4, @field(pass, field).len);
    if (pass.dirty_bounds) |value| rect(bytes, 56, value);
    var cursor: usize = 0;
    if (packets) {
        for (pass.commands, 0..) |command, i| {
            const at = 96 + i * 64;
            put(bytes, at, @intFromEnum(std.meta.activeTag(command.command)));
            put(bytes, at + 4, 0xffffffff);
            put(bytes, at + 12, cursor);
            rect(bytes, at + 48, command.bounds);
            switch (command.command) {
                .fill_rect => |v| {
                    put(bytes, at + 4, @intFromEnum(std.meta.activeTag(v.fill)));
                    rect(bytes, at + 32, v.rect);
                },
                .fill_rounded_rect => |v| {
                    put(bytes, at + 4, @intFromEnum(std.meta.activeTag(v.fill)));
                    rect(bytes, at + 32, v.rect);
                },
                .stroke_rect => |v| {
                    put(bytes, at + 4, @intFromEnum(std.meta.activeTag(v.stroke.fill)));
                    rect(bytes, at + 32, v.rect);
                },
                .draw_line => |v| put(bytes, at + 4, @intFromEnum(std.meta.activeTag(v.stroke.fill))),
                .fill_path => |v| put(bytes, at + 4, @intFromEnum(std.meta.activeTag(v.fill))),
                .stroke_path => |v| put(bytes, at + 4, @intFromEnum(std.meta.activeTag(v.stroke.fill))),
                .draw_image => |v| rect(bytes, at + 32, v.dst),
                .shadow => |v| rect(bytes, at + 32, v.rect),
                .blur => |v| rect(bytes, at + 32, v.rect),
                .draw_text => |v| {
                    put(bytes, at + 8, @intFromBool(v.text_layout != null));
                    put(bytes, at + 16, v.glyphs.len);
                    for (v.glyphs) |glyph| {
                        put(bytes, 96 + commands * 64 + cursor * 4, glyph.id);
                        cursor += 1;
                    }
                },
                else => {},
            }
        }
    } else {
        for (pass.batches, 0..) |batch, i| put(bytes, 96 + i * 4, @intFromEnum(batch.pipeline));
    }
    return bytes;
}

/// Validate every selector before borrowing a payload or indexing caller
/// storage. This checks transport envelopes, not the planning decisions.
pub fn resultValid(bytes: []const u8, result: []const u8) bool {
    if (bytes.len < 96 or result.len < 32 or bytes[0] != 65 or bytes[1] != 1 or bytes[2] > 3 or bytes[3] > 15 or word(bytes, 12) > 3 or word(result, 0) != 1 or word(result, 8) > 1 or word(result, 12) > 2 or word(result, 28) != 0) return false;
    const mode: Mode = @enumFromInt(bytes[2]);
    const count = word(result, 4);
    const sources = word(bytes, 4);
    const capacity = word(bytes, 8);
    const packets = mode == .packet or mode == .packet_summary;
    if ((!packets and (sources != 0 or word(bytes, 16) != 0)) or (packets and word(bytes, 20) != 0)) return false;
    if (sources > (bytes.len - 96) / 64) return false;
    const tail = bytes.len - 96 - @as(usize, sources) * 64;
    const tail_words = if (packets) word(bytes, 16) else word(bytes, 20);
    if (tail % 4 != 0 or tail / 4 != tail_words) return false;
    if (mode == .packet_summary or mode == .encoder_summary) return result.len == 32 and word(result, 8) == 0 and (mode != .packet_summary or (count <= sources and word(result, 16) <= count and word(result, 20) <= count));
    const stride: usize = if (mode == .packet) 32 else 8;
    if (count > capacity or (mode == .packet and count > sources) or result.len != 32 + @as(usize, count) * stride) return false;
    if (mode == .packet) {
        if (word(result, 16) > count or word(result, 20) > count) return false;
        var previous: ?u32 = null;
        for (0..count) |i| {
            const at = 32 + i * 32;
            const source = word(result, at);
            if (source >= sources or (previous != null and source <= previous.?) or word(result, at + 4) > 14 or (word(result, at + 8) != 0xffffffff and word(result, at + 8) > 6) or word(result, at + 12) > 63) return false;
            // A supported payload must select a drawable source union arm.
            const tag = word(bytes, 96 + @as(usize, source) * 64);
            if (word(result, at + 4) != 14 and (tag < 5 or tag > 14)) return false;
            previous = source;
        }
    } else for (0..count) |i| {
        const at = 32 + i * 8;
        const opcode = word(result, at);
        const arg = word(result, at + 4);
        if (opcode > 12) return false;
        if (opcode == 1 and word(bytes, 12) & 2 == 0) return false;
        if (opcode >= 2 and opcode <= 9) {
            if (arg >= word(bytes, 24 + (opcode - 2) * 4)) return false;
        } else if (opcode == 10) {
            if (arg > 6) return false;
        } else if (opcode == 11) {
            if (arg >= word(bytes, 20)) return false;
        } else if (arg != 0) return false;
    }
    return true;
}
fn invoke(pass: anytype, mode: Mode, capacity: usize, policy: Policy) []u8 {
    const bytes = request(pass, mode, capacity);
    defer allocator.free(bytes);
    const stride: usize = switch (mode) {
        .packet => 32,
        .encoder => 8,
        else => 0,
    };
    const result = alloc(add(32, mul(capacity, stride)));
    const length = policy(bytes, result);
    if (length > result.len or !resultValid(bytes, result[0..length])) @panic("invalid compiled GPU planning result");
    // Keep the allocation's original extent for free; consumers use count.
    return result;
}
fn paint(fill: anytype) gpu.CanvasGpuPaint {
    return switch (fill) {
        .color => |v| .{ .color = v },
        .linear_gradient => |v| .{ .linear_gradient = v },
    };
}
fn materialize(command: canvas.RenderCommand, result: []const u8, at: usize) gpu.CanvasGpuCommand {
    const flags = word(result, at + 12);
    var output: gpu.CanvasGpuCommand = .{
        .command_index = word(result, at),
        .id = command.id,
        .kind = @enumFromInt(word(result, at + 4)),
        .pipeline = if (word(result, at + 8) == 0xffffffff) null else @enumFromInt(word(result, at + 8)),
        .bounds = command.bounds,
        .clip = command.clip,
        .opacity = command.opacity,
        .transform = command.transform,
        .uses_path_geometry = flags & 1 != 0,
        .uses_image = flags & 2 != 0,
        .uses_resource = flags & 4 != 0,
        .uses_visual_effect = flags & 8 != 0,
        .uses_glyph_atlas = flags & 16 != 0,
        .uses_text_layout = flags & 32 != 0,
    };
    if (output.kind == .unsupported) return output;
    const normalized = readRect(result, at + 16);
    switch (command.command) {
        .fill_rect => |v| {
            output.shape = .{ .rect = normalized };
            output.paint = paint(v.fill);
        },
        .fill_rounded_rect => |v| {
            output.shape = .{ .rounded_rect = .{ .rect = normalized, .radius = v.radius } };
            output.paint = paint(v.fill);
        },
        .stroke_rect => |v| {
            output.shape = .{ .stroke_rect = .{ .rect = normalized, .radius = v.radius, .width = v.stroke.width } };
            output.paint = paint(v.stroke.fill);
            output.stroke_width = v.stroke.width;
        },
        .draw_line => |v| {
            output.shape = .{ .line = .{ .from = v.from, .to = v.to, .width = v.stroke.width } };
            output.paint = paint(v.stroke.fill);
            output.stroke_width = v.stroke.width;
        },
        .fill_path => |v| {
            output.shape = .{ .path = v.elements };
            output.paint = paint(v.fill);
        },
        .stroke_path => |v| {
            output.shape = .{ .path = v.elements };
            output.paint = paint(v.stroke.fill);
            output.stroke_width = v.stroke.width;
            output.cap = v.cap;
        },
        .draw_image => |v| output.image = .{ .image_id = v.image_id, .src = v.src, .dst = normalized, .opacity = v.opacity, .fit = v.fit, .sampling = v.sampling, .radius = v.radius },
        .draw_text => |v| {
            output.paint = .{ .color = v.color };
            output.text = .{ .font_id = v.font_id, .size = v.size, .origin = v.origin, .color = v.color, .text = v.text, .glyphs = v.glyphs, .measure = v.measure, .text_layout = v.text_layout };
        },
        .shadow => |v| output.effect = .{ .shadow = .{ .rect = normalized, .radius = v.radius, .offset = v.offset, .blur = v.blur, .spread = v.spread, .color = v.color } },
        .blur => |v| output.effect = .{ .blur = .{ .rect = normalized, .radius = v.radius } },
        else => @panic("invalid GPU payload source"),
    }
    return output;
}
pub fn packet(planner: anytype, pass: anytype, policy: Policy) canvas.Error!gpu.CanvasGpuPacket {
    planner.reset();
    const result = invoke(pass, .packet, @min(pass.commands.len, planner.commands.len), policy);
    defer allocator.free(result);
    const count = word(result, 4);
    for (0..count) |i| planner.commands[i] = materialize(pass.commands[word(result, 32 + i * 32)], result, 32 + i * 32);
    planner.len = count;
    planner.unsupported_count = word(result, 16);
    if (word(result, 8) != 0) return error.CanvasGpuCommandListFull;
    var output: gpu.CanvasGpuPacket = .{ .frame_index = pass.frame_index, .timestamp_ns = pass.timestamp_ns, .surface_size = pass.surface_size, .scale = pass.scale, .load_action = @enumFromInt(word(result, 12)) };
    if (output.load_action == .skip) return output;
    output.scissor = pass.dirty_bounds;
    output.images = pass.images;
    output.image_actions = pass.image_actions;
    output.commands = planner.commands[0..count];
    output.unsupported_command_count = planner.unsupported_count;
    output.batch_count = pass.batches.len;
    output.pipeline_action_count = pass.pipeline_actions.len;
    output.path_geometry_count = pass.path_geometries.len;
    output.path_geometry_action_count = pass.path_geometry_actions.len;
    output.image_count = pass.images.len;
    output.image_action_count = pass.image_actions.len;
    output.layer_count = pass.layers.len;
    output.layer_action_count = pass.layer_actions.len;
    output.resource_count = pass.resources.len;
    output.resource_action_count = pass.resource_actions.len;
    output.visual_effect_count = pass.visual_effects.len;
    output.visual_effect_action_count = pass.visual_effect_actions.len;
    output.glyph_atlas_entry_count = pass.glyph_atlas_entries.len;
    output.glyph_atlas_action_count = pass.glyph_atlas_actions.len;
    output.text_layout_count = pass.text_layouts.len;
    output.text_layout_line_count = pass.textLayoutLineCount();
    output.text_layout_action_count = pass.text_layout_actions.len;
    return output;
}
pub fn summary(pass: anytype, policy: Policy) gpu.CanvasGpuPacketSummary {
    const result = invoke(pass, .packet_summary, 0, policy);
    defer allocator.free(result);
    return .{ .load_action = @enumFromInt(word(result, 12)), .command_count = word(result, 4), .cache_action_count = word(result, 24), .cached_resource_command_count = word(result, 20), .unsupported_command_count = word(result, 16) };
}
pub fn encoderCounts(pass: anytype, policy: Policy) EncoderCounts {
    const result = invoke(pass, .encoder_summary, 0, policy);
    defer allocator.free(result);
    return .{ .commands = word(result, 4), .caches = word(result, 16), .binds = word(result, 20), .draws = word(result, 24) };
}
pub fn encoder(planner: anytype, pass: anytype, policy: Policy) canvas.Error!gpu.RenderEncoderPlan {
    planner.reset();
    const result = invoke(pass, .encoder, planner.commands.len, policy);
    defer allocator.free(result);
    const count = word(result, 4);
    for (0..count) |i| {
        const at = 32 + i * 8;
        const arg = word(result, at + 4);
        planner.commands[i] = switch (word(result, at)) {
            0 => .{ .begin_pass = .{ .load_action = @enumFromInt(word(result, 12)), .surface_size = pass.surface_size, .scale = pass.scale, .dirty_bounds = pass.dirty_bounds } },
            1 => .{ .set_scissor = pass.dirty_bounds orelse @panic("absent encoder scissor") },
            2 => .{ .pipeline_cache = pass.pipeline_actions[arg] },
            3 => .{ .path_geometry_cache = pass.path_geometry_actions[arg] },
            4 => .{ .image_cache = pass.image_actions[arg] },
            5 => .{ .layer_cache = pass.layer_actions[arg] },
            6 => .{ .resource_cache = pass.resource_actions[arg] },
            7 => .{ .visual_effect_cache = pass.visual_effect_actions[arg] },
            8 => .{ .glyph_atlas_cache = pass.glyph_atlas_actions[arg] },
            9 => .{ .text_layout_cache = pass.text_layout_actions[arg] },
            10 => .{ .bind_pipeline = @enumFromInt(arg) },
            11 => .{ .draw_batch = pass.batches[arg] },
            12 => .end_pass,
            else => unreachable,
        };
    }
    planner.len = count;
    if (word(result, 8) != 0) return error.RenderEncoderListFull;
    return .{ .commands = planner.commands[0..count] };
}

test "GPU planning copied transport rejects truncated and invalid selectors" {
    var bytes: [160]u8 = @splat(0);
    bytes[0..4].* = .{ 65, 1, 0, 0 };
    put(&bytes, 4, 1);
    put(&bytes, 8, 1);
    var result: [64]u8 = @splat(0);
    put(&result, 0, 1);
    put(&result, 4, 1);
    put(&result, 36, 14);
    put(&result, 40, 0xffffffff);
    try std.testing.expect(resultValid(&bytes, &result));
    try std.testing.expect(!resultValid(&bytes, result[0..63]));
    put(&result, 32, 1);
    try std.testing.expect(!resultValid(&bytes, &result));
    put(&result, 32, 0);
    put(&result, 36, 15);
    try std.testing.expect(!resultValid(&bytes, &result));
    put(&result, 36, 14);
    put(&result, 40, 7);
    try std.testing.expect(!resultValid(&bytes, &result));
    put(&result, 40, 0xffffffff);
    put(&result, 44, 64);
    try std.testing.expect(!resultValid(&bytes, &result));
    put(&result, 44, 0);
    put(&result, 28, 1);
    try std.testing.expect(!resultValid(&bytes, &result));
}

test "GPU planning copied transport bounds every encoder family and rejects absent scissors and malformed envelopes" {
    var bytes: [104]u8 = @splat(0);
    bytes[0..4].* = .{ 65, 1, 2, 0 };
    put(&bytes, 8, 1);
    put(&bytes, 20, 2);
    inline for (0..8) |i| put(&bytes, 24 + i * 4, 1);
    var result: [40]u8 = @splat(0);
    put(&result, 0, 1);
    put(&result, 4, 1);
    for (2..10) |opcode| {
        put(&result, 32, opcode);
        put(&result, 36, 0);
        try std.testing.expect(resultValid(&bytes, &result));
        put(&result, 36, 1);
        try std.testing.expect(!resultValid(&bytes, &result));
    }
    put(&result, 32, 11);
    put(&result, 36, 1);
    try std.testing.expect(resultValid(&bytes, &result));
    put(&result, 36, 2);
    try std.testing.expect(!resultValid(&bytes, &result));
    put(&result, 32, 10);
    put(&result, 36, 6);
    try std.testing.expect(resultValid(&bytes, &result));
    put(&result, 36, 7);
    try std.testing.expect(!resultValid(&bytes, &result));
    put(&result, 32, 1);
    put(&result, 36, 0);
    try std.testing.expect(!resultValid(&bytes, &result));
    put(&bytes, 12, 2);
    try std.testing.expect(resultValid(&bytes, &result));
    put(&result, 36, 1);
    try std.testing.expect(!resultValid(&bytes, &result));
    put(&result, 36, 0);
    for (0..result.len) |length| try std.testing.expect(!resultValid(&bytes, result[0..length]));
    put(&bytes, 4, 0xffffffff);
    try std.testing.expect(!resultValid(&bytes, &result));
    put(&bytes, 4, 0);
    put(&bytes, 20, 0xffffffff);
    try std.testing.expect(!resultValid(&bytes, &result));
}
