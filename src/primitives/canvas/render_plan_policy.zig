const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const cache = @import("render_cache_policy.zig");
const Affine = @import("drawing.zig").Affine;
comptime {
    const fields = @typeInfo(canvas.CanvasCommand).@"union".fields;
    const names = .{ "push_clip", "pop_clip", "push_opacity", "pop_opacity", "transform", "fill_rect", "stroke_rect", "fill_rounded_rect", "draw_line", "fill_path", "stroke_path", "draw_image", "draw_text", "shadow", "blur" };
    if (fields.len != names.len) @compileError("update the compiled render command wire tags");
    for (names, 0..) |name, i| if (!std.mem.eql(u8, name, fields[i].name)) @compileError("compiled render command wire tag changed");
}

/// Native supplies pure drawing bounds and primitive representation facts.
/// The compiled owner controls visibility, stacks, transforms and batching.
/// Only copied numeric facts cross the boundary; command payloads and resource
/// identities remain borrowed natively, with no arena collection here.
pub fn buildRender(comptime Result: type, planner: anytype, list: canvas.DisplayList, policy: cache.Policy, workspace: *cache.Workspace) canvas.Error!Result {
    planner.reset();
    const facts_length = 16 + list.commands.len * 48;
    const request = workspace.request[0..facts_length];
    @memset(request, 0);
    request[0] = 13;
    request[2] = numericFlags();
    putWord(request, 4, list.commands.len);
    putWord(request, 8, @min(list.commands.len, planner.commands.len));
    for (list.commands, 0..) |command, i| {
        const at = 16 + i * 48;
        putWord(request, at, @intFromEnum(std.meta.activeTag(command)));
        switch (command) {
            .push_clip => |clip| putRect(request, at + 8, clip.rect),
            .push_opacity => |opacity| putFloat(request, at + 8, opacity),
            .transform => |transform| putAffine(request, at + 24, transform),
            .pop_clip, .pop_opacity => {},
            .draw_text => |text| {
                const provider = if (text.text_layout) |options| options.measure orelse text.measure else text.measure;
                if (provider != null) {
                    // Provider calls are observable capabilities. Defer them
                    // until the compiled walk reaches this visible draw.
                    putWord(request, at + 4, 2);
                } else if (command.bounds()) |bounds| {
                    putWord(request, at + 4, 1);
                    putRect(request, at + 8, bounds);
                }
            },
            else => if (command.bounds()) |bounds| {
                putWord(request, at + 4, 1);
                putRect(request, at + 8, bounds);
            },
        }
    }
    const result = workspace.result[0 .. 864 + @min(list.commands.len, planner.commands.len) * 68];
    var request_length = facts_length;
    var length: usize = 0;
    var previous_pending: ?usize = null;
    var failed: u32 = 0;
    while (true) {
        length = policy(workspace.request[0..request_length], result);
        if (length < 864 or length > result.len) @panic("truncated compiled render state");
        failed = applyRenderState(planner, list, request, result[0..length]);
        if (failed != 4) break;
        const pending = word(result, 860);
        if (pending >= list.commands.len or (previous_pending != null and pending <= previous_pending.?) or word(request, 16 + @as(usize, pending) * 48) != 12 or word(request, 20 + @as(usize, pending) * 48) != 2) @panic("invalid compiled native bounds request");
        const at = 16 + @as(usize, pending) * 48;
        const bounds = list.commands[pending].bounds();
        putWord(request, at + 4, @intFromBool(bounds != null));
        putRect(request, at + 8, bounds orelse .{});
        if (facts_length + length > workspace.request.len) @panic("render continuation workspace too small");
        @memcpy(workspace.request[facts_length..][0..length], result[0..length]);
        putWord(request, 12, length);
        request_length = facts_length + length;
        previous_pending = pending;
    }
    switch (failed) {
        1 => return error.RenderStackOverflow,
        2 => return error.RenderStackUnderflow,
        3 => return error.RenderListFull,
        else => return .{ .commands = planner.commands[0..planner.len], .bounds = planner.bounds_value },
    }
}

// Publish each accepted prefix before invoking the next native capability.
// Providers can observe retained planner state through their native context.
fn applyRenderState(planner: anytype, list: canvas.DisplayList, request: []const u8, result: []const u8) u32 {
    const count = word(result, 0);
    const failed = word(result, 4);
    const clip_len = word(result, 8);
    const opacity_len = word(result, 12);
    const clip_written = word(result, 16);
    const opacity_written = word(result, 20);
    if (count > @min(list.commands.len, planner.commands.len) or failed > 4 or clip_written > 32 or opacity_written > 32 or clip_len > clip_written or opacity_len > opacity_written or result.len != 864 + @as(usize, count) * 68) @panic("invalid compiled render state");
    planner.state = .{ .opacity = float(result, 24), .clip = optionalRect(result, 28), .transform = affine(result, 48) };
    planner.bounds_value = optionalRect(result, 72);
    planner.clip_stack_len = clip_len;
    planner.opacity_stack_len = opacity_len;
    for (0..clip_written) |i| planner.clip_stack[i] = optionalRect(result, 92 + i * 20);
    for (0..opacity_written) |i| planner.opacity_stack[i] = float(result, 732 + i * 4);
    var previous: ?usize = null;
    for (0..count) |i| {
        const at = 864 + i * 68;
        const source = word(result, at);
        if (source >= list.commands.len or (previous != null and source <= previous.?) or word(request, 16 + @as(usize, source) * 48) < 5 or word(request, 20 + @as(usize, source) * 48) != 1) @panic("invalid compiled render command source");
        const command = list.commands[source];
        planner.commands[i] = .{
            .command = command,
            .id = command.objectId(),
            .opacity = float(result, at + 4),
            .clip = optionalRect(result, at + 8),
            .transform = affine(result, at + 28),
            .local_bounds = rect(request, 24 + @as(usize, source) * 48),
            .bounds = rect(result, at + 52),
        };
        previous = source;
    }
    planner.len = count;
    return failed;
}

pub fn buildBatch(comptime Result: type, planner: anytype, plan: canvas.RenderPlan, policy: cache.Policy, workspace: *cache.Workspace) canvas.Error!Result {
    planner.reset();
    const request = workspace.request[0 .. 32 + plan.commands.len * 48];
    @memset(request, 0);
    request[0] = 13;
    request[1] = 1;
    request[2] = numericFlags();
    putWord(request, 4, plan.commands.len);
    putWord(request, 8, @min(plan.commands.len, planner.batches.len));
    putOptional(request, 12, plan.bounds);
    for (plan.commands, 0..) |command, i| {
        const at = 32 + i * 48;
        putWord(request, at, @intFromEnum(std.meta.activeTag(command.command)));
        // These are fill representation tags, not pipeline decisions.
        const fill = switch (command.command) {
            .fill_rect => |value| value.fill,
            .stroke_rect => |value| value.stroke.fill,
            .fill_rounded_rect => |value| value.fill,
            .draw_line => |value| value.stroke.fill,
            else => null,
        };
        if (fill) |value| putWord(request, at + 4, @intFromEnum(std.meta.activeTag(value)));
        putFloat(request, at + 8, command.opacity);
        putOptional(request, at + 12, command.clip);
        putRect(request, at + 32, command.bounds);
    }
    const result = workspace.result[0 .. 32 + @min(plan.commands.len, planner.batches.len) * 52];
    const length = policy(request, result);
    if (length < 32 or length > result.len) @panic("truncated compiled render batches");
    const count = word(result, 0);
    const failed = word(result, 4);
    if (count > @min(plan.commands.len, planner.batches.len) or (failed != 0 and failed != 4) or word(result, 28) != 0 or length != 32 + @as(usize, count) * 52) @panic("invalid compiled render batches");
    var end: usize = 0;
    for (0..count) |i| {
        const at = 32 + i * 52;
        const pipeline = word(result, at);
        const start = word(result, at + 4);
        const commands = word(result, at + 8);
        if (pipeline > 6 or start != end or commands == 0 or start > plan.commands.len or commands > plan.commands.len - start) @panic("invalid compiled render batch range");
        planner.batches[i] = .{ .pipeline = @enumFromInt(pipeline), .command_start = start, .command_count = commands, .opacity = float(result, at + 12), .clip = optionalRect(result, at + 16), .bounds = rect(result, at + 36) };
        end = @as(usize, start) + commands;
    }
    if (failed == 0 and end != plan.commands.len) @panic("incomplete compiled render batches");
    planner.len = count;
    if (failed == 4) return error.RenderBatchListFull;
    return .{ .batches = planner.batches[0..count], .bounds = optionalRect(result, 8) };
}

/// Native f32 extrema have target-specific signs for opposite zero operands.
/// Runtime probes expose only that numeric capability, never render decisions.
fn numericFlags() u8 {
    var zeros = [_]f32{ -0.0, 0.0 };
    std.mem.doNotOptimizeAway(&zeros);
    const values = [_]f32{ @min(zeros[0], zeros[1]), @min(zeros[1], zeros[0]), @max(zeros[0], zeros[1]), @max(zeros[1], zeros[0]) };
    var flags: u8 = 0;
    for (values, 0..) |v, i| if (@as(u32, @bitCast(v)) == 0x80000000) {
        flags |= @as(u8, 1) << @intCast(i);
    };
    return flags;
}
fn putWord(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], std.math.cast(u32, value) orelse @panic("render planning wire integer overflow"), .little);
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn putFloat(bytes: []u8, at: usize, value: f32) void {
    putWord(bytes, at, @as(u32, @bitCast(value)));
}
fn float(bytes: []const u8, at: usize) f32 {
    return @bitCast(word(bytes, at));
}
fn putRect(bytes: []u8, at: usize, value: geometry.RectF) void {
    inline for (.{ "x", "y", "width", "height" }, 0..) |field, i| putFloat(bytes, at + i * 4, @field(value, field));
}
fn rect(bytes: []const u8, at: usize) geometry.RectF {
    return .init(float(bytes, at), float(bytes, at + 4), float(bytes, at + 8), float(bytes, at + 12));
}
fn putOptional(bytes: []u8, at: usize, value: ?geometry.RectF) void {
    putWord(bytes, at, @intFromBool(value != null));
    putRect(bytes, at + 4, value orelse .{});
}
fn optionalRect(bytes: []const u8, at: usize) ?geometry.RectF {
    const present = word(bytes, at);
    if (present > 1) @panic("invalid compiled render bounds presence");
    return if (present == 1) rect(bytes, at + 4) else null;
}
fn putAffine(bytes: []u8, at: usize, value: Affine) void {
    inline for (.{ "a", "b", "c", "d", "tx", "ty" }, 0..) |field, i| putFloat(bytes, at + i * 4, @field(value, field));
}
fn affine(bytes: []const u8, at: usize) Affine {
    return .{ .a = float(bytes, at), .b = float(bytes, at + 4), .c = float(bytes, at + 8), .d = float(bytes, at + 12), .tx = float(bytes, at + 16), .ty = float(bytes, at + 20) };
}
