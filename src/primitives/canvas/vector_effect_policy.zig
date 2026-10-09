//! Copied vector/effect facts and checked result ownership. Source commands,
//! buffers and GPU resources stay native; portable planning uses operation 63.
const std = @import("std");
const wire = @import("glyph_atlas_policy.zig");
pub const Policy = wire.Policy;
const word = wire.word;
const put = wire.put;
const float = wire.float;
const integer = wire.integer;
const readFloat = wire.readFloat;
const builtin = @import("builtin");
// Zig 0.16 optimized x86 preserves the shadow output's zero operand. The
// separately lowered backdrop-blur output canonicalizes that clamp to +0.
const nonnegative_zero: u8 = if ((builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) and builtin.mode != .Debug) 16 else 0;
const zero_rules: u8 = nonnegative_zero | switch (builtin.cpu.arch) {
    .aarch64, .aarch64_be => 3,
    else => 5,
};

fn bytes(base: usize, count: usize, stride: usize) usize {
    return std.math.add(usize, base, std.math.mul(usize, count, stride) catch @panic("vector resource size overflow")) catch @panic("vector resource size overflow");
}
fn alloc(size: usize) []u8 {
    return std.heap.page_allocator.alloc(u8, size) catch @panic("vector resource allocation failed");
}
fn header(request: []u8, mode: u8, count: usize, capacity: usize) void {
    @memset(request, 0);
    request[0..4].* = .{ 63, 1, mode, zero_rules };
    put(request, 4, count);
    put(request, 8, capacity);
}
fn rect(out: []u8, at: usize, value: anytype) void {
    inline for (.{ "x", "y", "width", "height" }, 0..) |field, i| float(out, at + i * 4, @field(value, field));
}
fn readRect(raw: []const u8, at: usize) @import("geometry").RectF {
    return .{ .x = readFloat(raw, at), .y = readFloat(raw, at + 4), .width = readFloat(raw, at + 8), .height = readFloat(raw, at + 12) };
}

pub fn resultValid(request: []const u8, result: []const u8, capacity: usize) bool {
    if (request.len < 16 or result.len < 16 or request[2] > 1) return false;
    const mode = request[2];
    const request_stride: usize = if (mode == 0) 72 else 80;
    const stride: usize = if (mode == 0) 88 else 80;
    const facts: usize = word(request, 4);
    const count: usize = word(result, 0);
    if (facts > (request.len - 16) / request_stride or count > facts or count > capacity or
        count > (result.len - 16) / stride or result.len != 16 + count * stride or
        word(result, 4) > 1 or word(result, 8) != 0 or word(result, 12) != 0 or
        (word(result, 4) == 1 and count != capacity)) return false;
    var source: usize = 0;
    for (0..count) |i| {
        const at = 16 + i * stride;
        const index = word(result, at);
        while (source < facts and word(request, 16 + source * request_stride) < index) source += 1;
        if (source >= facts) return false;
        const origin = 16 + source * request_stride;
        const prefix: usize = if (mode == 0) 40 else 16;
        if (!std.mem.eql(u8, request[origin..][0..prefix], result[at..][0..prefix])) return false;
        if (mode == 0) {
            const elements: u64 = word(request, origin + 68);
            if (elements == 0 or word(result, at + 40) != elements or word(result, at + 64) == 0 or word(result, at + 68) == 0 or word(result, at + 76) != 0) return false;
            // Check conservative storage ceilings, without deriving the plan.
            // Each source verb contributes at most twelve reference segments.
            for (0..4) |field| if (word(result, at + 44 + field * 4) > elements) return false;
            if (word(result, at + 60) > elements * 12 or word(result, at + 64) > elements * 48 or word(result, at + 68) > elements * 72) return false;
        } else if (word(result, at + 72) != 0 or word(result, at + 76) != 0) return false;
        source += 1;
    }
    return true;
}

pub fn paths(planner: anytype, plan: anytype, policy: Policy) @import("root.zig").Error!@import("render_paths.zig").RenderPathGeometryPlan {
    planner.reset();
    var count: usize = 0;
    var elements: usize = 0;
    for (plan.commands) |command| switch (command.command) {
        inline .fill_path, .stroke_path => |value| {
            count += 1;
            elements = bytes(elements, value.elements.len, 28);
        },
        else => {},
    };
    const start = bytes(16, count, 72);
    const request = alloc(bytes(start, elements, 1));
    defer std.heap.page_allocator.free(request);
    const result = alloc(bytes(16, @min(count, planner.geometries.len), 88));
    defer std.heap.page_allocator.free(result);
    header(request, 0, count, planner.geometries.len);
    var fact: usize = 0;
    var payload = start;
    for (plan.commands, 0..) |command, index| switch (command.command) {
        inline .fill_path, .stroke_path => |value| {
            const at = 16 + fact * 72;
            const stroke = command.command == .stroke_path;
            put(request, at, index);
            put(request, at + 4, @intFromBool(stroke));
            put(request, at + 8, @intFromBool(command.id != null));
            integer(request, at + 16, command.id orelse 0);
            rect(request, at + 24, command.bounds);
            inline for (.{ "a", "b", "c", "d", "tx", "ty" }, 0..) |field, i| float(request, at + 40 + i * 4, @field(command.transform, field));
            float(request, at + 64, if (stroke) command.command.stroke_path.stroke.width else 0);
            put(request, at + 68, value.elements.len);
            for (value.elements) |element| {
                put(request, payload, @intFromEnum(element.verb));
                for (element.points, 0..) |point, i| {
                    float(request, payload + 4 + i * 8, point.x);
                    float(request, payload + 8 + i * 8, point.y);
                }
                payload += 28;
            }
            fact += 1;
        },
        else => {},
    };
    const length = policy(request, result);
    if (length > result.len or !resultValid(request, result[0..length], planner.geometries.len)) @panic("invalid compiled vector geometry result");
    planner.len = word(result, 0);
    for (planner.geometries[0..planner.len], 0..) |*item, i| {
        const at = 16 + i * 88;
        item.* = .{
            .kind = @enumFromInt(word(result, at + 4)),
            .command_index = word(result, at),
            .id = if (word(result, at + 8) != 0) std.mem.readInt(u64, result[at + 16 ..][0..8], .little) else null,
            .bounds = readRect(result, at + 24),
            .element_count = word(result, at + 40),
            .contour_count = word(result, at + 44),
            .line_segment_count = word(result, at + 48),
            .quadratic_segment_count = word(result, at + 52),
            .cubic_segment_count = word(result, at + 56),
            .flattened_segment_count = word(result, at + 60),
            .vertex_count = word(result, at + 64),
            .index_count = word(result, at + 68),
            .stroke_width = readFloat(result, at + 72),
            .fingerprint = std.mem.readInt(u64, result[at + 80 ..][0..8], .little),
        };
    }
    if (word(result, 4) != 0) return error.PathGeometryListFull;
    return .{ .geometries = planner.geometries[0..planner.len] };
}

pub fn effects(planner: anytype, list: anytype, policy: Policy) @import("root.zig").Error!@import("render_effects.zig").VisualEffectPlan {
    planner.reset();
    var count: usize = 0;
    for (list.commands) |command| switch (command) {
        .shadow, .blur => count += 1,
        else => {},
    };
    const request = alloc(bytes(16, count, 80));
    defer std.heap.page_allocator.free(request);
    const result = alloc(bytes(16, @min(count, planner.effects.len), 80));
    defer std.heap.page_allocator.free(result);
    header(request, 1, count, planner.effects.len);
    var fact: usize = 0;
    for (list.commands, 0..) |command, index| switch (command) {
        inline .shadow, .blur => |value| {
            const at = 16 + fact * 80;
            put(request, at, index);
            put(request, at + 4, @intFromBool(command == .blur));
            integer(request, at + 8, value.id);
            rect(request, at + 16, value.rect);
            switch (command) {
                .shadow => |shadow| {
                    inline for (.{ "top_left", "top_right", "bottom_right", "bottom_left" }, 0..) |field, i| float(request, at + 32 + i * 4, @field(shadow.radius, field));
                    float(request, at + 48, shadow.offset.dx);
                    float(request, at + 52, shadow.offset.dy);
                    float(request, at + 56, shadow.blur);
                    float(request, at + 60, shadow.spread);
                    inline for (.{ "r", "g", "b", "a" }, 0..) |field, i| float(request, at + 64 + i * 4, @field(shadow.color, field));
                },
                .blur => |blur| float(request, at + 56, blur.radius),
                else => unreachable,
            }
            fact += 1;
        },
        else => {},
    };
    const length = policy(request, result);
    if (length > result.len or !resultValid(request, result[0..length], planner.effects.len)) @panic("invalid compiled vector effect result");
    planner.len = word(result, 0);
    for (planner.effects[0..planner.len], 0..) |*item, i| {
        const at = 16 + i * 80;
        const id = std.mem.readInt(u64, result[at + 8 ..][0..8], .little);
        item.* = .{
            .kind = @enumFromInt(word(result, at + 4)),
            .command_index = word(result, at),
            .id = if (id == 0) null else id,
            .bounds = readRect(result, at + 16),
            .radius = .{ .top_left = readFloat(result, at + 32), .top_right = readFloat(result, at + 36), .bottom_right = readFloat(result, at + 40), .bottom_left = readFloat(result, at + 44) },
            .offset = .{ .dx = readFloat(result, at + 48), .dy = readFloat(result, at + 52) },
            .blur = readFloat(result, at + 56),
            .spread = readFloat(result, at + 60),
            .fingerprint = std.mem.readInt(u64, result[at + 64 ..][0..8], .little),
        };
    }
    if (word(result, 4) != 0) return error.VisualEffectListFull;
    return .{ .effects = planner.effects[0..planner.len] };
}

test "vector resource copied transport bounds counts sources padding and complete failure prefixes" {
    var request: [160]u8 = undefined;
    header(&request, 0, 2, 2);
    put(&request, 16, 3);
    put(&request, 88, 9);
    put(&request, 84, 3);
    put(&request, 156, 3);
    var result: [192]u8 = @splat(0);
    put(&result, 0, 2);
    @memcpy(result[16..56], request[16..56]);
    @memcpy(result[104..144], request[88..128]);
    for ([_]usize{ 16, 104 }) |at| {
        put(&result, at + 40, 3);
        put(&result, at + 64, 3);
        put(&result, at + 68, 3);
    }
    try std.testing.expect(resultValid(&request, &result, 2));
    try std.testing.expect(!resultValid(&request, &result, 1));
    for ([_]usize{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 80, 84, 92, 104, 180 }) |at| {
        const saved = word(&result, at);
        put(&result, at, 0xffffffff);
        try std.testing.expect(!resultValid(&request, &result, 2));
        put(&result, at, saved);
    }
    for (0..192) |length| try std.testing.expect(!resultValid(&request, result[0..length], 2));
    put(&result, 0, 1);
    put(&result, 4, 1);
    try std.testing.expect(resultValid(&request, result[0..104], 1));
    try std.testing.expect(!resultValid(&request, result[0..104], 2));
    header(&request, 1, 1, 1);
    put(&request, 16, 7);
    @memset(&result, 0);
    put(&result, 0, 1);
    @memcpy(result[16..32], request[16..32]);
    try std.testing.expect(resultValid(request[0..96], result[0..96], 1));
    put(&result, 88, 1);
    try std.testing.expect(!resultValid(request[0..96], result[0..96], 1));
}
