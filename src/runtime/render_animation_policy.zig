//! Copied render-animation lifecycle decisions. Native owns retained records,
//! command-bound providers, storage writes, and invalidation execution.
const std = @import("std");
const canvas = @import("canvas");
const geometry = @import("geometry");
pub const Policy = *const fn ([]const u8, []u8) usize;
const allocator = std.heap.page_allocator;
const word = readWord;

fn readWord(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn put(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], std.math.cast(u32, value) orelse @panic("animation fact exceeds wire range"), .little);
}
fn wide(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
fn float(bytes: []u8, at: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(value), .little);
}
fn readFloat(bytes: []const u8, at: usize) f32 {
    return @bitCast(word(bytes, at));
}
fn affine(bytes: []u8, at: usize, value: canvas.Affine) void {
    inline for (.{ "a", "b", "c", "d", "tx", "ty" }, 0..) |field, i| float(bytes, at + i * 4, @field(value, field));
}
fn rect(bytes: []u8, at: usize, value: geometry.RectF) void {
    inline for (.{ "x", "y", "width", "height" }, 0..) |field, i| float(bytes, at + i * 4, @field(value, field));
}
fn optionalRect(bytes: []const u8, at: usize) ?geometry.RectF {
    if (word(bytes, at) == 0) return null;
    return .{ .x = readFloat(bytes, at + 4), .y = readFloat(bytes, at + 8), .width = readFloat(bytes, at + 12), .height = readFloat(bytes, at + 16) };
}
fn add(a: usize, b: usize) usize {
    return std.math.add(usize, a, b) catch @panic("animation transport size overflow");
}
fn mul(a: usize, b: usize) usize {
    return std.math.mul(usize, a, b) catch @panic("animation transport size overflow");
}
fn alloc(len: usize) []u8 {
    const result = allocator.alloc(u8, len) catch @panic("animation transport allocation failed");
    @memset(result, 0);
    return result;
}
fn header(bytes: []u8, mode: u8, animations: usize, overrides: usize, commands: usize) void {
    bytes[0..4].* = .{ 72, 1, mode, 0 };
    put(bytes, 4, animations);
    put(bytes, 8, overrides);
    put(bytes, 12, commands);
}
fn animation(bytes: []u8, at: usize, value: canvas.CanvasRenderAnimation) void {
    wide(bytes, at, value.id);
    wide(bytes, at + 8, value.start_ns);
    put(bytes, at + 16, value.duration_ms);
    put(bytes, at + 20, @intFromEnum(value.loop));
    put(bytes, at + 24, @as(u32, @intFromBool(value.to_opacity != null)) |
        (@as(u32, @intFromBool(value.from_transform != null)) << 1) |
        (@as(u32, @intFromBool(value.to_transform != null)) << 2) |
        (@as(u32, @intFromBool(value.from_rotation != null or value.to_rotation != null)) << 3));
    float(bytes, at + 28, value.to_opacity orelse 0);
    affine(bytes, at + 32, value.from_transform orelse .{});
    affine(bytes, at + 56, value.to_transform orelse .{});
    float(bytes, at + 80, value.rotation_center.x);
    float(bytes, at + 84, value.rotation_center.y);
}
fn override(bytes: []u8, at: usize, value: canvas.CanvasRenderOverride) void {
    wide(bytes, at, value.id);
    put(bytes, at + 8, @as(u32, @intFromBool(value.opacity != null)) | (@as(u32, @intFromBool(value.transform != null)) << 1));
    float(bytes, at + 12, value.opacity orelse 0);
    affine(bytes, at + 16, value.transform orelse .{});
}
fn invoke(policy: Policy, request: []const u8, output: []u8) []const u8 {
    @memset(output, 0xa5);
    const len = policy(request, output);
    if (len > output.len or !resultValid(request, output[0..len])) @panic("invalid render animation decision");
    return output[0..len];
}

/// Validate copied selectors and write extents, without rerunning admission,
/// activity, retirement, target selection, or geometry policy natively.
pub fn resultValid(request: []const u8, result: []const u8) bool {
    if (request.len < 80 or request[0] != 72 or request[1] != 1 or request[2] > 3 or result.len < 32 or word(result, 0) != 1) return false;
    const mode = request[2];
    if (mode == 3) return result.len == 32 and word(result, 4) <= 2 and word(result, 8) <= 1 and
        (word(result, 4) == 0 or word(result, 8) == 0) and std.mem.allEqual(u8, result[12..], 0);
    if (mode == 2) {
        const count = @as(u64, word(request, 4)) + word(request, 8);
        const cursor = word(result, 8);
        const answer = word(request, 56) != 0xffffffff;
        if (result.len != 64 or word(result, 4) > 1 or cursor > count or cursor < word(request, 32) or
            word(result, 16) > 1 or !std.mem.allEqual(u8, result[36..], 0)) return false;
        if (word(result, 4) == 0) return cursor == count and word(result, 12) == 0xffffffff;
        return cursor < count and word(result, 12) < word(request, 12) and (!answer or cursor > word(request, 32));
    }
    const count = word(request, if (mode == 0) 4 else 8);
    if (word(result, 4) != count or word(result, 8) > 1 or word(result, 12) > 1 or
        !std.mem.allEqual(u8, result[16..32], 0) or result.len != 32 + @as(usize, count)) return false;
    var active = false;
    var pruned = false;
    for (result[32..]) |flags| {
        if (flags > 3 or flags == 2 or (mode == 1 and flags > 1)) return false;
        active = active or flags & 2 != 0;
        pruned = pruned or flags & 1 == 0;
    }
    return (word(result, 8) != 0) == active and (word(result, 12) != 0) == pruned;
}

/// Returns true only when replacing an entirely empty, unapplied set is inert.
/// The capacity verdict precedes invalid identities, matching the reference.
pub fn admit(animations: []const canvas.CanvasRenderAnimation, old_count: usize, old_overrides: usize, capacity: usize, policy: Policy) !bool {
    const request = alloc(add(80, if (animations.len > capacity) 0 else mul(animations.len, 8)));
    defer allocator.free(request);
    header(request, 3, animations.len, old_overrides, old_count);
    put(request, 16, capacity);
    if (animations.len <= capacity) for (animations, 0..) |value, i| wide(request, 80 + i * 8, value.id);
    var output: [32]u8 = undefined;
    const result = invoke(policy, request, &output);
    switch (word(result, 4)) {
        1 => return error.RenderAnimationListFull,
        2 => return error.InvalidViewOptions,
        else => return word(result, 8) != 0,
    }
}

/// In-place storage mutation follows the copied per-slot decisions. Duplicate
/// identities and untouched tail slots behave exactly like the reference.
pub fn finishFrame(view: anytype, timestamp_ns: u64, policy: Policy) bool {
    const count = view.canvas_render_animation_count;
    const request = alloc(add(80, mul(count, 112)));
    defer allocator.free(request);
    header(request, 0, count, 0, 0);
    wide(request, 20, timestamp_ns);
    for (view.canvasRenderAnimations(), 0..) |value, i| animation(request, 80 + i * 112, value);
    const output = alloc(add(32, count));
    defer allocator.free(output);
    const result = invoke(policy, request, output);
    var retained: usize = 0;
    for (0..count) |i| {
        const value = view.canvas_render_animations[i];
        if (result[32 + i] & 1 == 0) {
            view.removeCanvasRenderAnimationDirtyBounds(value.id);
        } else {
            view.canvas_render_animations[retained] = value;
            retained += 1;
        }
    }
    view.canvas_render_animation_count = retained;
    if (word(result, 12) != 0) compactOverrides(view, policy);
    return word(result, 8) != 0;
}
fn compactOverrides(view: anytype, policy: Policy) void {
    const count = view.canvas_frame_render_override_count;
    const request = alloc(add(80, mul(count, 40)));
    defer allocator.free(request);
    header(request, 1, 0, count, 0);
    for (view.canvasFrameRenderOverrides(), 0..) |value, i| override(request, 80 + i * 40, value);
    const output = alloc(add(32, count));
    defer allocator.free(output);
    const result = invoke(policy, request, output);
    var retained: usize = 0;
    for (0..count) |i| if (result[32 + i] & 1 != 0) {
        view.canvas_frame_render_overrides[retained] = view.canvas_frame_render_overrides[i];
        retained += 1;
    };
    view.canvas_frame_render_override_count = retained;
}

/// Request each selected native bounds provider in reference order, including
/// duplicate identities. No eager measurements or memoized callback results.
pub fn schedule(view: anytype, animations: []const canvas.CanvasRenderAnimation, policy: Policy) ?geometry.RectF {
    const list = view.canvasDisplayList();
    const overrides = view.canvasFrameRenderOverrides();
    const override_at = add(80, mul(animations.len, 112));
    const command_at = add(override_at, mul(overrides.len, 40));
    const request = alloc(add(command_at, mul(list.commands.len, 16)));
    defer allocator.free(request);
    header(request, 2, animations.len, overrides.len, list.commands.len);
    request[3] = canvas.renderNumericFlags();
    put(request, 56, 0xffffffff);
    for (animations, 0..) |value, i| animation(request, 80 + i * 112, value);
    for (overrides, 0..) |value, i| override(request, override_at + i * 40, value);
    for (list.commands, 0..) |command, i| {
        const at = command_at + i * 16;
        wide(request, at, command.objectId() orelse 0);
        put(request, at + 8, @intFromBool(command.objectId() != null));
    }
    var output: [64]u8 = undefined;
    while (true) {
        const result = invoke(policy, request, &output);
        if (word(result, 4) == 0) return optionalRect(result, 16);
        const source = word(result, 12);
        const cursor = word(result, 8);
        const target_at = if (cursor < overrides.len) override_at + @as(usize, cursor) * 40 else 80 + (@as(usize, cursor) - overrides.len) * 112;
        if (!std.mem.eql(u8, request[target_at..][0..8], request[command_at + @as(usize, source) * 16 ..][0..8]) or
            word(request, command_at + @as(usize, source) * 16 + 8) == 0) @panic("invalid animation bounds selector");
        // Publish the accepted continuation before invoking an observable
        // provider; it is never called for an unselected command.
        put(request, 32, cursor);
        @memcpy(request[36..56], result[16..36]);
        put(request, 56, source);
        const bounds = list.commands[source].bounds();
        put(request, 60, @intFromBool(bounds != null));
        rect(request, 64, bounds orelse .{});
    }
}
