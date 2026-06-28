const std = @import("std");
const geometry = @import("geometry");
const platform = @import("../platform/root.zig");

pub const max_windows: usize = platform.max_windows;
pub const max_views: usize = platform.max_windows + platform.max_views + platform.max_webviews;

pub const Window = struct {
    id: platform.WindowId = 1,
    title: []const u8,
    bounds: geometry.RectF,
    focused: bool = true,
};

pub const Diagnostics = struct {
    frame_index: u64 = 0,
    command_count: usize = 0,
};

pub const Input = struct {
    windows: []const Window,
    views: []const platform.ViewInfo = &.{},
    diagnostics: Diagnostics = .{},
    source: ?platform.WebViewSource = null,
};

pub fn writeText(input: Input, writer: anytype) !void {
    try writer.print("ready=true frame={d} commands={d}\n", .{ input.diagnostics.frame_index, input.diagnostics.command_count });
    for (input.windows) |window| {
        try writer.print(
            "window @w{d} \"{s}\" bounds=({d},{d} {d}x{d}) focused={any} frame={d} commands={d}\n",
            .{
                window.id,
                window.title,
                window.bounds.x,
                window.bounds.y,
                window.bounds.width,
                window.bounds.height,
                window.focused,
                input.diagnostics.frame_index,
                input.diagnostics.command_count,
            },
        );
    }
    for (input.views) |view| {
        try writer.print(
            "  view @w{d}/{s} kind={s} role=\"{s}\" accessibility_label=\"{s}\" text=\"{s}\" bounds=({d},{d} {d}x{d}) layer={d} visible={any} enabled={any} focused={any} open={any}",
            .{
                view.window_id,
                view.label,
                @tagName(view.kind),
                view.role,
                view.accessibility_label,
                view.text,
                view.frame.x,
                view.frame.y,
                view.frame.width,
                view.frame.height,
                view.layer,
                view.visible,
                view.enabled,
                view.focused,
                view.open,
            },
        );
        if (view.kind == .gpu_surface) {
            try writer.print(" gpu_frame={d} gpu_nonblank={any} gpu_sample=0x{x:0>8} canvas_revision={d} canvas_commands={d}", .{
                view.gpu_frame_index,
                view.gpu_frame_nonblank,
                view.gpu_sample_color,
                view.canvas_revision,
                view.canvas_command_count,
            });
        }
        try writer.writeByte('\n');
    }
    if (input.source) |source| {
        try writer.print("  source kind={s} bytes={d}\n", .{ @tagName(source.kind), source.bytes.len });
    }
}

pub fn writeA11yText(input: Input, writer: anytype) !void {
    try writer.print("a11y root=@w1 nodes={d}\n", .{input.windows.len + input.views.len});
    for (input.windows) |window| {
        try writer.print("@w{d} role=window name=\"{s}\" bounds=({d},{d} {d}x{d})\n", .{
            window.id,
            window.title,
            window.bounds.x,
            window.bounds.y,
            window.bounds.width,
            window.bounds.height,
        });
    }
    for (input.views) |view| {
        const role = if (view.role.len > 0) view.role else @tagName(view.kind);
        const name = if (view.accessibility_label.len > 0) view.accessibility_label else if (view.text.len > 0) view.text else view.label;
        try writer.print("@w{d}/{s} role={s} name=\"{s}\" bounds=({d},{d} {d}x{d})\n", .{
            view.window_id,
            view.label,
            role,
            name,
            view.frame.x,
            view.frame.y,
            view.frame.width,
            view.frame.height,
        });
    }
}

test "snapshot emits window and source" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const views = [_]platform.ViewInfo{.{ .label = "main", .kind = .webview, .frame = geometry.RectF.init(0, 0, 100, 100), .role = "webview", .text = "Main content", .focused = true }};
    try writeText(.{
        .windows = &windows,
        .views = &views,
        .source = platform.WebViewSource.html("<h1>Hello</h1>"),
    }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ready=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "@w1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "view @w1/main kind=webview") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "accessibility_label=\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "text=\"Main content\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "focused=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "source kind=html") != null);
}

test "accessibility snapshot uses visible view text as name" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const views = [_]platform.ViewInfo{.{ .label = "status", .kind = .statusbar, .frame = geometry.RectF.init(0, 80, 100, 20), .role = "status", .text = "Ready" }};
    try writeA11yText(.{
        .windows = &windows,
        .views = &views,
    }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "@w1/status role=status name=\"Ready\"") != null);
}

test "accessibility snapshot prefers explicit accessibility label" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const views = [_]platform.ViewInfo{.{ .label = "refresh-icon", .kind = .icon_button, .frame = geometry.RectF.init(0, 0, 30, 30), .role = "button", .accessibility_label = "Refresh workspace", .text = "R" }};
    try writeA11yText(.{
        .windows = &windows,
        .views = &views,
    }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "@w1/refresh-icon role=button name=\"Refresh workspace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "name=\"R\"") == null);
}

test "snapshot emits GPU surface frame proof" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const views = [_]platform.ViewInfo{.{ .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 100, 100), .gpu_frame_index = 4, .gpu_frame_nonblank = true, .gpu_sample_color = 0xff336699, .canvas_revision = 2, .canvas_command_count = 5 }};
    try writeText(.{
        .windows = &windows,
        .views = &views,
    }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_frame=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_nonblank=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_sample=0xff336699") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_revision=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_commands=5") != null);
}
