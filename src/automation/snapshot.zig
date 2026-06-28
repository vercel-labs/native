const std = @import("std");
const geometry = @import("geometry");
const platform = @import("../platform/root.zig");

pub const max_windows: usize = platform.max_windows;
pub const max_views: usize = platform.max_windows + platform.max_views + platform.max_webviews;
pub const max_widgets: usize = platform.max_views * 2;

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

pub const WidgetActions = struct {
    focus: bool = false,
    press: bool = false,
    toggle: bool = false,
    increment: bool = false,
    decrement: bool = false,
    set_text: bool = false,
    select: bool = false,

    pub fn isEmpty(self: WidgetActions) bool {
        return !self.focus and
            !self.press and
            !self.toggle and
            !self.increment and
            !self.decrement and
            !self.set_text and
            !self.select;
    }
};

pub const TextRange = struct {
    start: usize = 0,
    end: usize = 0,
};

pub const Widget = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8 = "",
    id: u64 = 0,
    role: []const u8 = "",
    name: []const u8 = "",
    value: ?f32 = null,
    bounds: geometry.RectF = .{},
    focused: bool = false,
    enabled: bool = true,
    hovered: bool = false,
    pressed: bool = false,
    selected: bool = false,
    actions: WidgetActions = .{},
    text_selection: ?TextRange = null,
    text_composition: ?TextRange = null,
};

pub const Input = struct {
    windows: []const Window,
    views: []const platform.ViewInfo = &.{},
    widgets: []const Widget = &.{},
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
            try writer.print(" gpu_size={d}x{d} gpu_scale={d} gpu_frame={d} gpu_timestamp_ns={d} gpu_nonblank={any} gpu_sample=0x{x:0>8} canvas_revision={d} canvas_commands={d} canvas_frame_requires_render={any} canvas_frame_full_repaint={any} canvas_frame_batches={d} canvas_frame_resources={d} canvas_frame_uploads={d} canvas_frame_retains={d} canvas_frame_evicts={d} canvas_frame_glyphs={d} canvas_frame_changes={d}", .{
                view.gpu_size.width,
                view.gpu_size.height,
                view.gpu_scale_factor,
                view.gpu_frame_index,
                view.gpu_timestamp_ns,
                view.gpu_frame_nonblank,
                view.gpu_sample_color,
                view.canvas_revision,
                view.canvas_command_count,
                view.canvas_frame_requires_render,
                view.canvas_frame_full_repaint,
                view.canvas_frame_batch_count,
                view.canvas_frame_resource_count,
                view.canvas_frame_resource_upload_count,
                view.canvas_frame_resource_retain_count,
                view.canvas_frame_resource_evict_count,
                view.canvas_frame_glyph_atlas_entry_count,
                view.canvas_frame_change_count,
            });
            if (view.canvas_frame_dirty_bounds) |dirty| {
                try writer.print(" canvas_frame_dirty=({d},{d} {d}x{d})", .{ dirty.x, dirty.y, dirty.width, dirty.height });
            } else {
                try writer.writeAll(" canvas_frame_dirty=null");
            }
            try writer.print(" widget_revision={d} widget_nodes={d} widget_semantics={d}", .{
                view.widget_revision,
                view.widget_node_count,
                view.widget_semantics_count,
            });
            try writer.print(" widget_cursor={s}", .{@tagName(view.cursor)});
        }
        try writer.writeByte('\n');
    }
    for (input.widgets) |widget| {
        try writer.print(
            "    widget @w{d}/{s}#{d} role={s} name=\"{s}\" bounds=({d},{d} {d}x{d}) focused={any} enabled={any}",
            .{
                widget.window_id,
                widget.view_label,
                widget.id,
                widget.role,
                widget.name,
                widget.bounds.x,
                widget.bounds.y,
                widget.bounds.width,
                widget.bounds.height,
                widget.focused,
                widget.enabled,
            },
        );
        if (widget.value) |value| try writer.print(" value={d}", .{value});
        try writeWidgetState(widget, writer);
        try writeWidgetActions(widget.actions, writer);
        try writeWidgetTextRanges(widget, writer);
        try writer.writeByte('\n');
    }
    if (input.source) |source| {
        try writer.print("  source kind={s} bytes={d}\n", .{ @tagName(source.kind), source.bytes.len });
    }
}

pub fn writeA11yText(input: Input, writer: anytype) !void {
    try writer.print("a11y root=@w1 nodes={d}\n", .{input.windows.len + input.views.len + input.widgets.len});
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
    for (input.widgets) |widget| {
        try writer.print("@w{d}/{s}#{d} role={s} name=\"{s}\" bounds=({d},{d} {d}x{d})", .{
            widget.window_id,
            widget.view_label,
            widget.id,
            widget.role,
            widget.name,
            widget.bounds.x,
            widget.bounds.y,
            widget.bounds.width,
            widget.bounds.height,
        });
        if (widget.value) |value| try writer.print(" value={d}", .{value});
        try writeWidgetState(widget, writer);
        try writeWidgetActions(widget.actions, writer);
        try writeWidgetTextRanges(widget, writer);
        try writer.writeByte('\n');
    }
}

fn writeWidgetState(widget: Widget, writer: anytype) !void {
    if (!widget.hovered and !widget.pressed and !widget.selected) return;
    try writer.writeAll(" state=[");
    var wrote = false;
    try writeWidgetStateFlag(widget.hovered, "hovered", &wrote, writer);
    try writeWidgetStateFlag(widget.pressed, "pressed", &wrote, writer);
    try writeWidgetStateFlag(widget.selected, "selected", &wrote, writer);
    try writer.writeByte(']');
}

fn writeWidgetStateFlag(enabled: bool, name: []const u8, wrote: *bool, writer: anytype) !void {
    if (!enabled) return;
    if (wrote.*) try writer.writeByte(',');
    try writer.writeAll(name);
    wrote.* = true;
}

fn writeWidgetActions(actions: WidgetActions, writer: anytype) !void {
    if (actions.isEmpty()) return;
    try writer.writeAll(" actions=[");
    var wrote = false;
    try writeWidgetAction(actions.focus, "focus", &wrote, writer);
    try writeWidgetAction(actions.press, "press", &wrote, writer);
    try writeWidgetAction(actions.toggle, "toggle", &wrote, writer);
    try writeWidgetAction(actions.increment, "increment", &wrote, writer);
    try writeWidgetAction(actions.decrement, "decrement", &wrote, writer);
    try writeWidgetAction(actions.set_text, "set_text", &wrote, writer);
    try writeWidgetAction(actions.select, "select", &wrote, writer);
    try writer.writeByte(']');
}

fn writeWidgetAction(enabled: bool, name: []const u8, wrote: *bool, writer: anytype) !void {
    if (!enabled) return;
    if (wrote.*) try writer.writeByte(',');
    try writer.writeAll(name);
    wrote.* = true;
}

fn writeWidgetTextRanges(widget: Widget, writer: anytype) !void {
    if (widget.text_selection) |selection| try writer.print(" selection={d}..{d}", .{ selection.start, selection.end });
    if (widget.text_composition) |composition| try writer.print(" composition={d}..{d}", .{ composition.start, composition.end });
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
    var buffer: [1280]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const views = [_]platform.ViewInfo{.{ .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 100, 100), .gpu_size = geometry.SizeF.init(320, 180), .gpu_scale_factor = 2, .gpu_frame_index = 4, .gpu_timestamp_ns = 99, .gpu_frame_nonblank = true, .gpu_sample_color = 0xff336699, .canvas_revision = 2, .canvas_command_count = 5, .canvas_frame_requires_render = true, .canvas_frame_full_repaint = true, .canvas_frame_batch_count = 3, .canvas_frame_resource_count = 2, .canvas_frame_resource_upload_count = 1, .canvas_frame_resource_retain_count = 1, .canvas_frame_resource_evict_count = 0, .canvas_frame_glyph_atlas_entry_count = 4, .canvas_frame_change_count = 0, .canvas_frame_dirty_bounds = geometry.RectF.init(0, 0, 320, 180), .cursor = .text }};
    try writeText(.{
        .windows = &windows,
        .views = &views,
    }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_size=320x180") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_scale=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_frame=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_timestamp_ns=99") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_nonblank=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_sample=0xff336699") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_revision=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_commands=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_requires_render=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_full_repaint=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_batches=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_resources=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_uploads=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_retains=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_evicts=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_glyphs=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_changes=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_dirty=(0,0 320x180)") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "widget_cursor=text") != null);
}

test "snapshot emits widget semantics" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const views = [_]platform.ViewInfo{.{ .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 100, 100), .role = "canvas" }};
    const widgets = [_]Widget{.{
        .window_id = 1,
        .view_label = "canvas",
        .id = 42,
        .role = "button",
        .name = "Run query",
        .bounds = geometry.RectF.init(10, 12, 80, 32),
        .focused = true,
        .hovered = true,
        .pressed = true,
        .selected = true,
        .actions = .{ .focus = true, .press = true },
        .text_selection = .{ .start = 4, .end = 4 },
        .text_composition = .{ .start = 0, .end = 3 },
    }};
    try writeText(.{
        .windows = &windows,
        .views = &views,
        .widgets = &widgets,
    }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "widget @w1/canvas#42 role=button name=\"Run query\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "state=[hovered,pressed,selected]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "actions=[focus,press]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "selection=4..4") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "composition=0..3") != null);

    var a11y_buffer: [1024]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try writeA11yText(.{
        .windows = &windows,
        .views = &views,
        .widgets = &widgets,
    }, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "a11y root=@w1 nodes=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#42 role=button name=\"Run query\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "state=[hovered,pressed,selected]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "actions=[focus,press]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "selection=4..4") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "composition=0..3") != null);
}
