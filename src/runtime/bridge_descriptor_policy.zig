//! Descriptor decisions over decoded facts; native owns JSON and borrowed bytes.
const std = @import("std");
const geometry = @import("geometry");
const json = @import("json");
const platform = @import("../platform/root.zig");
const reference = @import("bridge_payload.zig");
pub const StringStorage = json.StringStorage;
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { choice, gpu, window, frame, layer, origin };
pub const Family = enum(u8) { view, titlebar, backend, pixel_format, present_mode, alpha_mode, color_space, feature };
fn request(mode: Mode) [96]u8 {
    var bytes: [96]u8 = @splat(0);
    bytes[0..3].* = .{ 87, 1, @intFromEnum(mode) };
    return bytes;
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn wide(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
fn number(bytes: []u8, at: usize, value: f64) void {
    wide(bytes, at, @bitCast(value));
}
pub const Program = struct {
    bytes: [64]u8,
    pub fn word(self: *const Program, at: usize) u32 {
        return std.mem.readInt(u32, self.bytes[at..][0..4], .little);
    }
    pub fn wide(self: *const Program, at: usize) u64 {
        return std.mem.readInt(u64, self.bytes[at..][0..8], .little);
    }
    pub fn number(self: *const Program, at: usize) f64 {
        return @bitCast(self.wide(at));
    }
    fn admit(self: *const Program) !void {
        return switch (self.word(8)) {
            0 => {},
            1 => error.InvalidWebViewWindowId,
            2 => error.CrossWindowWebViewDenied,
            3 => error.InvalidViewWindowId,
            4 => error.CrossWindowViewDenied,
            5 => error.InvalidViewOptions,
            6 => error.InvalidWebViewOptions,
            8 => error.UnsupportedViewKind,
            else => @panic("invalid compiled bridge descriptor status"),
        };
    }
};
pub fn plan(policy: Policy, bytes: []const u8) Program {
    var result = Program{ .bytes = @splat(0xa5) };
    if (policy(bytes, &result.bytes) != result.bytes.len or result.word(0) != 1 or result.word(4) != bytes[2]) @panic("invalid compiled bridge descriptor header");
    return result;
}
fn enumType(comptime family: Family) type {
    return switch (family) {
        .view => platform.ViewKind,
        .titlebar => platform.WindowTitlebarStyle,
        .backend => platform.GpuSurfaceBackend,
        .pixel_format => platform.GpuSurfacePixelFormat,
        .present_mode => platform.GpuSurfacePresentMode,
        .alpha_mode => platform.GpuSurfaceAlphaMode,
        .color_space => platform.GpuSurfaceColorSpace,
        .feature => platform.PlatformFeature,
    };
}
comptime {
    // Keep ordinal transport tied to the independently tested native vocabulary.
    for (.{ .view, .titlebar, .backend, .pixel_format, .present_mode, .alpha_mode, .color_space, .feature }, .{ 19, 4, 4, 2, 2, 3, 3, 29 }) |family, count| {
        if (@typeInfo(enumType(family)).@"enum".fields.len != count) @compileError("update bridge descriptor vocabulary");
    }
}
pub fn choice(policy: Policy, comptime family: Family, value: []const u8) ?enumType(family) {
    var bytes: [160]u8 = @splat(0);
    bytes[0..96].* = request(.choice);
    bytes[3] = @intFromEnum(family);
    wide(&bytes, 8, value.len);
    const count: usize = @min(value.len, 64);
    @memcpy(bytes[96..][0..count], value[0..count]);
    const result = plan(policy, bytes[0 .. 96 + count]);
    result.admit() catch @panic("invalid compiled bridge choice");
    const ordinal = result.word(16);
    if (ordinal > @typeInfo(enumType(family)).@"enum".fields.len) @panic("invalid compiled bridge enum ordinal");
    return if (ordinal == 0) null else @enumFromInt(ordinal - 1);
}
pub fn viewKindFromString(policy: ?Policy, value: []const u8) ?platform.ViewKind {
    return if (policy) |compiled| choice(compiled, .view, value) else reference.viewKindFromString(value);
}
pub fn windowTitlebarStyleFromString(policy: ?Policy, value: []const u8) ?platform.WindowTitlebarStyle {
    return if (policy) |compiled| choice(compiled, .titlebar, value) else reference.windowTitlebarStyleFromString(value);
}
pub fn platformFeatureFromString(policy: ?Policy, value: []const u8) ?platform.PlatformFeature {
    return if (policy) |compiled| choice(compiled, .feature, value) else reference.platformFeatureFromString(value);
}
pub fn gpuSurfaceOptionsFromJson(policy: ?Policy, payload: []const u8, storage: *json.StringStorage) !platform.GpuSurfaceOptions {
    const compiled = policy orelse return reference.gpuSurfaceOptionsFromJson(payload, storage);
    var bytes = request(.gpu);
    inline for (0..5) |i| put(&bytes, 16 + i * 4, std.math.maxInt(u32));
    inline for (.{ .backend, .pixel_format, .present_mode, .alpha_mode, .color_space }, .{ "gpuBackend", "gpuPixelFormat", "gpuPresentMode", "gpuAlphaMode", "gpuColorSpace" }, .{ "gpu_backend", "gpu_pixel_format", "gpu_present_mode", "gpu_alpha_mode", "gpu_color_space" }, 0..) |family, camel, snake, i| {
        const value = reference.jsonStringField(payload, camel, storage) orelse reference.jsonStringField(payload, snake, storage);
        put(&bytes, 16 + i * 4, if (value) |name| if (choice(compiled, family, name)) |selected| @as(u32, @intFromEnum(selected)) + 1 else 0 else std.math.maxInt(u32));
        const prefix = plan(compiled, &bytes);
        try prefix.admit();
    }
    const vsync = reference.jsonBoolField(payload, "gpuVsync") orelse reference.jsonBoolField(payload, "gpu_vsync");
    bytes[4] = if (vsync) |value| if (value) 2 else 1 else 0;
    const result = plan(compiled, &bytes);
    try result.admit();
    inline for (.{ 4, 2, 2, 3, 3, 2 }, 0..) |count, i| if (result.word(16 + i * 4) >= count) @panic("invalid compiled GPU descriptor");
    return .{ .backend = @enumFromInt(result.word(16)), .pixel_format = @enumFromInt(result.word(20)), .present_mode = @enumFromInt(result.word(24)), .alpha_mode = @enumFromInt(result.word(28)), .color_space = @enumFromInt(result.word(32)), .vsync = result.word(36) != 0 };
}
fn window(policy: Policy, payload: []const u8, default: platform.WindowId, web: bool) !platform.WindowId {
    var bytes = request(.window);
    bytes[3] = @intFromBool(web);
    bytes[4] = @intFromBool(json.fieldValue(payload, "windowId") != null);
    const value = reference.jsonIntegerField(payload, "windowId");
    bytes[5] = @intFromBool(value != null);
    wide(&bytes, 16, default);
    wide(&bytes, 24, value orelse 0);
    const result = plan(policy, &bytes);
    try result.admit();
    if (result.wide(16) != default) @panic("invalid compiled bridge window owner");
    return result.wide(16);
}
pub fn webViewWindowIdFromJson(policy: ?Policy, payload: []const u8, default: platform.WindowId) !platform.WindowId {
    return if (policy) |compiled| window(compiled, payload, default, true) else reference.webViewWindowIdFromJson(payload, default);
}
pub fn viewWindowIdFromJson(policy: ?Policy, payload: []const u8, default: platform.WindowId) !platform.WindowId {
    return if (policy) |compiled| window(compiled, payload, default, false) else reference.viewWindowIdFromJson(payload, default);
}
fn frame(policy: Policy, payload: []const u8, required: bool, web: bool) !?geometry.RectF {
    var bytes = request(.frame);
    bytes[3] = @intFromBool(web);
    bytes[4] = @intFromBool(required);
    const value = json.fieldValue(payload, "frame");
    bytes[5] = @intFromBool(value != null);
    const source = value orelse if (web) payload else "";
    inline for (.{ "x", "y", "width", "height" }, .{ 8, 9, 6, 7 }, 0..) |field, flag, i| {
        const decoded = reference.jsonNumberField(source, field);
        bytes[flag] = @intFromBool(decoded != null);
        number(&bytes, 16 + i * 8, decoded orelse 0);
    }
    const result = plan(policy, &bytes);
    try result.admit();
    if (result.word(12) > 1) @panic("invalid compiled bridge frame presence");
    return if (result.word(12) == 0) null else geometry.RectF.init(@floatCast(result.number(16)), @floatCast(result.number(24)), @floatCast(result.number(32)), @floatCast(result.number(40)));
}
pub fn viewFrameFromJson(policy: ?Policy, payload: []const u8, required: bool) !?geometry.RectF {
    return if (policy) |compiled| frame(compiled, payload, required, false) else reference.viewFrameFromJson(payload, required);
}
pub fn webViewFrameFromJson(policy: ?Policy, payload: []const u8) !geometry.RectF {
    const compiled = policy orelse return reference.webViewFrameFromJson(payload);
    return (try frame(compiled, payload, true, true)) orelse @panic("missing compiled WebView frame");
}
fn layer(policy: Policy, payload: []const u8, web: bool) !?i32 {
    var bytes = request(.layer);
    bytes[3] = @intFromBool(web);
    const raw = json.fieldValue(payload, "layer");
    bytes[4] = @intFromBool(raw != null);
    const value = if (raw) |text| std.fmt.parseFloat(f64, text) catch null else null;
    bytes[5] = @intFromBool(value != null);
    number(&bytes, 16, value orelse 0);
    const result = plan(policy, &bytes);
    try result.admit();
    const selected = result.number(16);
    if (result.word(12) > 1 or !std.math.isFinite(selected) or @trunc(selected) != selected or selected < std.math.minInt(i32) or selected > std.math.maxInt(i32)) @panic("invalid compiled bridge layer");
    return if (result.word(12) == 0) null else @intFromFloat(selected);
}
pub fn viewLayerFromJson(policy: ?Policy, payload: []const u8) !?i32 {
    return if (policy) |compiled| layer(compiled, payload, false) else reference.viewLayerFromJson(payload);
}
pub fn webViewLayerFromJson(policy: ?Policy, payload: []const u8) !i32 {
    const compiled = policy orelse return reference.webViewLayerFromJson(payload);
    return (try layer(compiled, payload, true)) orelse @panic("missing compiled WebView layer");
}
pub fn webViewUrlOrigin(policy: ?Policy, url: []const u8, buffer: []u8) ![]const u8 {
    const compiled = policy orelse return reference.webViewUrlOrigin(url, buffer);
    var bytes: [96 + 256]u8 = @splat(0);
    bytes[0..96].* = request(.origin);
    wide(&bytes, 16, url.len);
    wide(&bytes, 32, buffer.len);
    const prefix = @min(url.len, 6);
    @memcpy(bytes[48..][0..prefix], url[0..prefix]);
    var offset: usize = 0;
    while (true) {
        const count = @min(url.len - offset, 256);
        bytes[3] = @intFromBool(offset + count == url.len);
        put(&bytes, 8, @intCast(count));
        wide(&bytes, 24, offset);
        @memcpy(bytes[96..][0..count], url[offset..][0..count]);
        const result = plan(compiled, bytes[0 .. 96 + count]);
        if (result.word(8) == 2) {
            if (count == 0 or result.word(24) > 4) @panic("invalid compiled origin continuation");
            put(&bytes, 40, result.word(24));
            offset += count;
            continue;
        }
        try result.admit();
        if (result.word(12) > 1) @panic("invalid compiled origin kind");
        if (result.word(12) == 1) return "about://local";
        const end = result.wide(16);
        if (end > url.len or end > buffer.len) @panic("invalid compiled origin borrowed extent");
        @memcpy(buffer[0..@intCast(end)], url[0..@intCast(end)]);
        return buffer[0..@intCast(end)];
    }
}
