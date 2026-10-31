//! Bounded copies for portable descriptor admission; native retains storage.
const std = @import("std");
const manifest = @import("app_manifest");
const platform = @import("../platform/root.zig");
const geometry = @import("geometry");
const reference = @import("validation.zig");
const comparison = @import("shell_coordination_policy.zig");
pub const Policy = comparison.Policy;
pub const Mode = enum(u8) { field, window, view, hierarchy, scene, chrome, chrome_item, duplicate_window, runtime_view, runtime_patch, label, frame };
const Field = enum(u32) { name, view_label, role, accessibility, text, command, url, chrome_label, chrome_icon, runtime_command };
comptime {
    if (manifest.max_shell_windows != 16 or manifest.max_shell_views_per_window != 128 or manifest.max_shell_tabs != 5 or manifest.max_view_label_bytes != 64 or manifest.max_view_role_bytes != 64 or manifest.max_view_accessibility_label_bytes != 256 or manifest.max_command_id_bytes != 128 or manifest.max_shell_chrome_label_bytes != 128 or manifest.max_shell_chrome_icon_bytes != 64 or platform.max_view_label_bytes != 64 or platform.max_webview_label_bytes != 64 or platform.max_view_role_bytes != 64 or platform.max_view_accessibility_label_bytes != 256 or platform.max_view_text_bytes != 1024 or @bitSizeOf(usize) > 64 or @intFromEnum(platform.ViewKind.gpu_surface) != 17 or @intFromEnum(platform.ViewKind.webview) != 0 or @intFromEnum(platform.GpuSurfaceBackend.metal) != 1 or @intFromEnum(platform.GpuSurfaceBackend.software) != 3 or @intFromEnum(platform.GpuSurfacePixelFormat.bgra8_unorm) != 1 or @intFromEnum(platform.GpuSurfacePresentMode.timer) != 1 or @intFromEnum(platform.GpuSurfaceAlphaMode.@"opaque") != 1 or @intFromEnum(platform.GpuSurfaceAlphaMode.premultiplied) != 2 or @intFromEnum(platform.GpuSurfaceColorSpace.srgb) != 1) @compileError("update shell admission wire constants");
}
pub const Program = struct {
    status: u32,
    state: u32,
    pub fn admit(self: Program) !void {
        switch (self.status) {
            0 => {},
            1 => return error.InvalidName,
            2 => return error.InvalidLayout,
            3 => return error.DuplicateView,
            4 => return error.DuplicateWindow,
            5 => return error.InvalidDimension,
            6 => return error.InvalidCommand,
            7 => return error.DuplicateCommand,
            8 => return error.InvalidUrl,
            9 => return error.MissingRequiredField,
            10 => return error.InvalidViewKind,
            11 => return error.InvalidViewOptions,
            12 => return error.ViewLabelTooLarge,
            13 => return error.ViewRoleTooLarge,
            14 => return error.ViewAccessibilityLabelTooLarge,
            15 => return error.ViewTextTooLarge,
            16 => return error.UnsupportedViewKind,
            17 => return error.InvalidWindowOptions,
            18 => return error.InvalidWebViewOptions,
            19 => return error.WebViewLabelTooLarge,
            20 => return error.ReservedWebViewLabel,
            else => unreachable,
        }
    }
};
pub const put = comparison.put;
fn wide(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
fn scalar(bytes: []u8, at: usize, value: f32) void {
    put(bytes, at, @bitCast(value));
}
pub fn request(mode: Mode) [64]u8 {
    var bytes: [64]u8 = @splat(0);
    bytes[0..3].* = .{ 85, 1, @intFromEnum(mode) };
    return bytes;
}
pub fn plan(policy: Policy, bytes: []const u8) Program {
    var output: [16]u8 = @splat(0xa5);
    if (policy(bytes, &output) != output.len or std.mem.readInt(u32, output[0..4], .little) != 1 or std.mem.readInt(u32, output[4..8], .little) != bytes[2]) @panic("invalid compiled shell admission header");
    const program = Program{ .status = std.mem.readInt(u32, output[8..12], .little), .state = std.mem.readInt(u32, output[12..16], .little) };
    if (program.status > 20 or program.state > 15 or (bytes[2] != @intFromEnum(Mode.field) and program.state != 0)) @panic("invalid compiled shell admission result");
    return program;
}
fn field(policy: Policy, kind: Field, value: []const u8) u32 {
    var bytes: [320]u8 = @splat(0);
    bytes[0..64].* = request(.field);
    put(&bytes, 4, @intFromEnum(kind));
    wide(&bytes, 16, value.len);
    @memcpy(bytes[48..][0..@min(value.len, 8)], value[0..@min(value.len, 8)]);
    var at: usize = 0;
    while (true) {
        const count: usize = @min(value.len - at, 256);
        wide(&bytes, 24, at);
        put(&bytes, 32, @intCast(count));
        put(&bytes, 36, @intFromBool(at + count == value.len));
        @memcpy(bytes[64..][0..count], value[at..][0..count]);
        const program = plan(policy, bytes[0 .. 64 + count]);
        if (at + count == value.len) return program.status;
        put(&bytes, 12, program.state);
        at += count;
    }
}
fn optionalField(policy: Policy, kind: Field, value: ?[]const u8) u32 {
    return if (value) |bytes| field(policy, kind, bytes) else 0;
}
fn capacity(policy: Policy, mode: Mode, count: usize) !void {
    var bytes = request(mode);
    wide(&bytes, 16, count);
    try plan(policy, &bytes).admit();
}
pub fn scene(policy: Policy, shell: manifest.ShellConfig, compatibility: []const manifest.Window) !void {
    try capacity(policy, .scene, shell.windows.len);
    for (shell.windows, 0..) |window, index| {
        var bytes = request(.window);
        put(&bytes, 4, field(policy, .name, window.label));
        put(&bytes, 8, optionalField(policy, .name, window.title));
        wide(&bytes, 16, window.views.len);
        scalar(&bytes, 32, window.width);
        scalar(&bytes, 36, window.height);
        try plan(policy, &bytes).admit();
        try views(policy, window.views);
        var duplicate = false;
        for (compatibility) |prior| if (comparison.equal(policy, prior.label, window.label)) {
            duplicate = true;
        };
        for (shell.windows[0..index]) |prior| if (comparison.equal(policy, prior.label, window.label)) {
            duplicate = true;
        };
        bytes = request(.duplicate_window);
        put(&bytes, 4, @intFromBool(duplicate));
        try plan(policy, &bytes).admit();
    }
    try chrome(policy, shell.chrome);
}
fn views(policy: Policy, descriptors: []const manifest.ShellView) !void {
    var graph: [64 + 128 * 4]u8 = @splat(0);
    graph[0..64].* = request(.hierarchy);
    wide(&graph, 16, descriptors.len);
    for (descriptors, 0..) |view, index| {
        var bytes: [160]u8 = @splat(0);
        bytes[0..64].* = request(.view);
        put(&bytes, 16, field(policy, .view_label, view.label));
        var duplicate = false;
        for (descriptors[0..index]) |prior| if (comparison.equal(policy, prior.label, view.label)) {
            duplicate = true;
        };
        put(&bytes, 8, @intFromBool(duplicate));
        var flags: u32 = 0;
        var parent_slot: u32 = std.math.maxInt(u32);
        if (view.parent) |parent| {
            flags |= 64;
            put(&bytes, 20, field(policy, .name, parent));
            for (descriptors, 0..) |candidate, slot| {
                if (comparison.equal(policy, candidate.label, parent)) {
                    parent_slot = @intCast(slot);
                    break;
                }
            }
        }
        put(&bytes, 12, parent_slot);
        put(&graph, 64 + index * 4, parent_slot);
        for ([_]?f32{ view.width, view.height, view.min_width, view.min_height, view.max_width, view.max_height }, 0..) |value, slot| if (value) |number| {
            flags |= @as(u32, 1) << @intCast(slot);
            scalar(&bytes, 48 + slot * 4, number);
        };
        for ([_]u32{ optionalField(policy, .role, view.role), optionalField(policy, .accessibility, view.accessibility_label), optionalField(policy, .text, view.text), optionalField(policy, .command, view.command), optionalField(policy, .url, view.url) }, 0..) |status, slot| put(&bytes, 24 + slot * 4, status);
        if (view.url != null) flags |= 128;
        put(&bytes, 4, flags);
        put(&bytes, 80, @intFromEnum(view.kind));
        put(&bytes, 84, @as(u32, @intFromBool(view.gpu_backend != null)) | (@as(u32, @intFromBool(view.gpu_pixel_format != null)) << 1) | (@as(u32, @intFromBool(view.gpu_present_mode != null)) << 2) | (@as(u32, @intFromBool(view.gpu_alpha_mode != null)) << 3) | (@as(u32, @intFromBool(view.gpu_color_space != null)) << 4) | (@as(u32, @intFromBool(view.gpu_vsync != null)) << 5));
        put(&bytes, 88, @intCast(index));
        try plan(policy, &bytes).admit();
    }
    try plan(policy, graph[0 .. 64 + descriptors.len * 4]).admit();
}
fn chromeItem(policy: Policy, id: []const u8, caption: []const u8, icon: []const u8, duplicate: bool) !void {
    var bytes = request(.chrome_item);
    put(&bytes, 4, @intFromBool(duplicate));
    put(&bytes, 16, field(policy, .command, id));
    put(&bytes, 20, field(policy, .chrome_label, caption));
    put(&bytes, 24, field(policy, .chrome_icon, icon));
    try plan(policy, &bytes).admit();
}
fn chrome(policy: Policy, value: manifest.ShellChrome) !void {
    try capacity(policy, .chrome, value.tabs.len);
    for (value.tabs, 0..) |tab, index| {
        var duplicate = false;
        for (value.tabs[0..index]) |prior| if (comparison.equal(policy, prior.id, tab.id)) {
            duplicate = true;
        };
        try chromeItem(policy, tab.id, tab.label, tab.icon, duplicate);
    }
    if (value.primary_action) |action| {
        var duplicate = false;
        for (value.tabs) |tab| if (comparison.equal(policy, tab.id, action.id)) {
            duplicate = true;
        };
        try chromeItem(policy, action.id, action.label, action.icon, duplicate);
    }
}
pub fn label(policy: ?Policy, category: u32, value: []const u8) !void {
    const compiled = policy orelse return switch (category) {
        0 => reference.validateViewLabel(value),
        1 => reference.validateWebViewLabel(value),
        2 => reference.validateChildWebViewLabel(value),
        else => unreachable,
    };
    var bytes = request(.label);
    put(&bytes, 4, category);
    wide(&bytes, 16, value.len);
    @memcpy(bytes[40..][0..@min(value.len, 4)], value[0..@min(value.len, 4)]);
    try plan(compiled, &bytes).admit();
}
pub fn frame(policy: ?Policy, category: u32, value: geometry.RectF) !void {
    const compiled = policy orelse return switch (category) {
        0 => reference.validateViewFrame(value),
        1 => reference.validateWindowFrame(value),
        2 => if (!reference.isValidWebViewFrame(value)) error.InvalidWebViewOptions else {},
        else => unreachable,
    };
    var bytes = request(.frame);
    put(&bytes, 4, category);
    for ([_]f32{ value.x, value.y, value.width, value.height }, 0..) |number, i| scalar(&bytes, 16 + i * 4, number);
    try plan(compiled, &bytes).admit();
}
pub fn runtimeView(policy: ?Policy, options: platform.ViewOptions) !void {
    const compiled = policy orelse return reference.validateViewOptions(options);
    var bytes: [160]u8 = @splat(0);
    bytes[0..64].* = request(.runtime_view);
    put(&bytes, 4, @intFromEnum(options.kind));
    put(&bytes, 8, @intFromBool(options.parent != null));
    bytes[16..22].* = .{ @intFromEnum(options.gpu_surface.backend), @intFromEnum(options.gpu_surface.pixel_format), @intFromEnum(options.gpu_surface.present_mode), @intFromEnum(options.gpu_surface.alpha_mode), @intFromEnum(options.gpu_surface.color_space), @intFromBool(options.gpu_surface.vsync) };
    for ([_]f32{ options.frame.x, options.frame.y, options.frame.width, options.frame.height }, 0..) |number, i| scalar(&bytes, 32 + i * 4, number);
    for ([_][]const u8{ options.label, options.parent orelse "", options.role, options.accessibility_label, options.text, options.command, options.url }, 0..) |value, i| wide(&bytes, 64 + i * 8, value.len);
    put(&bytes, 120, field(compiled, .runtime_command, options.command));
    try plan(compiled, &bytes).admit();
}
pub fn runtimePatch(policy: Policy, value: []const u8, patch: platform.ViewPatch) !void {
    var bytes: [160]u8 = @splat(0);
    bytes[0..64].* = request(.runtime_patch);
    put(&bytes, 8, @intFromBool(patch.frame != null));
    if (patch.frame) |rect| for ([_]f32{ rect.x, rect.y, rect.width, rect.height }, 0..) |number, i| scalar(&bytes, 32 + i * 4, number);
    for ([_][]const u8{ value, "", patch.role orelse "", patch.accessibility_label orelse "", patch.text orelse "", patch.command orelse "", patch.url orelse "" }, 0..) |text, i| wide(&bytes, 64 + i * 8, text.len);
    put(&bytes, 120, field(policy, .runtime_command, patch.command orelse ""));
    try plan(policy, &bytes).admit();
}
