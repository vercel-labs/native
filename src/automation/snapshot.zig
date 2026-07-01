const std = @import("std");
const geometry = @import("geometry");
const platform = @import("../platform/root.zig");

pub const max_windows: usize = platform.max_windows;
pub const max_views: usize = platform.max_windows + platform.max_views + platform.max_webviews;
pub const max_widgets_per_view: usize = 64;
pub const max_widgets: usize = platform.max_views * max_widgets_per_view;

pub const Window = struct {
    id: platform.WindowId = 1,
    title: []const u8,
    bounds: geometry.RectF,
    focused: bool = true,
};

pub const Diagnostics = struct {
    frame_index: u64 = 0,
    command_count: usize = 0,
    runtime_uptime_ns: u64 = 0,
};

pub const WidgetActions = struct {
    focus: bool = false,
    press: bool = false,
    toggle: bool = false,
    increment: bool = false,
    decrement: bool = false,
    set_text: bool = false,
    set_selection: bool = false,
    select: bool = false,
    drag: bool = false,
    drop_files: bool = false,
    dismiss: bool = false,

    pub fn isEmpty(self: WidgetActions) bool {
        return !self.focus and
            !self.press and
            !self.toggle and
            !self.increment and
            !self.decrement and
            !self.set_text and
            !self.set_selection and
            !self.select and
            !self.drag and
            !self.drop_files and
            !self.dismiss;
    }
};

pub const TextRange = struct {
    start: usize = 0,
    end: usize = 0,
};

pub const WidgetScroll = struct {
    present: bool = false,
    offset: f32 = 0,
    viewport_extent: f32 = 0,
    content_extent: f32 = 0,
};

pub const WidgetVirtualRange = struct {
    present: bool = false,
    start_index: u32 = 0,
    end_index: u32 = 0,
    first_visible_index: u32 = 0,
    last_visible_index: u32 = 0,
    rendered_count: u32 = 0,
};

pub const WidgetList = struct {
    present: bool = false,
    item_index: u32 = 0,
    item_count: u32 = 0,
};

pub const Widget = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8 = "",
    id: u64 = 0,
    role: []const u8 = "",
    name: []const u8 = "",
    parent_id: ?u64 = null,
    value: ?f32 = null,
    text_value: []const u8 = "",
    placeholder: []const u8 = "",
    grid_row_index: ?usize = null,
    grid_column_index: ?usize = null,
    grid_row_count: ?usize = null,
    grid_column_count: ?usize = null,
    list: WidgetList = .{},
    scroll: WidgetScroll = .{},
    virtual_range: WidgetVirtualRange = .{},
    bounds: geometry.RectF = .{},
    focused: bool = false,
    enabled: bool = true,
    hovered: bool = false,
    pressed: bool = false,
    selected: bool = false,
    expanded: ?bool = null,
    required: bool = false,
    read_only: bool = false,
    invalid: bool = false,
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
    try writer.print("ready=true frame={d} commands={d} runtime_uptime_ns={d}\n", .{ input.diagnostics.frame_index, input.diagnostics.command_count, input.diagnostics.runtime_uptime_ns });
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
            try writer.print(" gpu_size={d}x{d} gpu_scale={d} gpu_backend={s} gpu_pixel_format={s} gpu_present_mode={s} gpu_alpha_mode={s} gpu_color_space={s} gpu_vsync={any} gpu_status={s} gpu_frame={d} gpu_timestamp_ns={d} gpu_frame_interval_ns={d} gpu_input_timestamp_ns={d} gpu_input_latency_ns={d} gpu_input_latency_budget_ns={d} gpu_input_latency_budget_exceeded={d} gpu_input_latency_budget_ok={any} gpu_first_frame_latency_ns={d} gpu_first_frame_latency_budget_ns={d} gpu_first_frame_latency_budget_exceeded={d} gpu_first_frame_latency_budget_ok={any} gpu_nonblank={any} gpu_sample=0x{x:0>8}", .{
                view.gpu_size.width,
                view.gpu_size.height,
                view.gpu_scale_factor,
                @tagName(view.gpu_backend),
                @tagName(view.gpu_pixel_format),
                @tagName(view.gpu_present_mode),
                @tagName(view.gpu_alpha_mode),
                @tagName(view.gpu_color_space),
                view.gpu_vsync,
                @tagName(view.gpu_status),
                view.gpu_frame_index,
                view.gpu_timestamp_ns,
                view.gpu_frame_interval_ns,
                view.gpu_input_timestamp_ns,
                view.gpu_input_latency_ns,
                view.gpu_input_latency_budget_ns,
                view.gpu_input_latency_budget_exceeded_count,
                view.gpu_input_latency_budget_ok,
                view.gpu_first_frame_latency_ns,
                view.gpu_first_frame_latency_budget_ns,
                view.gpu_first_frame_latency_budget_exceeded_count,
                view.gpu_first_frame_latency_budget_ok,
                view.gpu_frame_nonblank,
                view.gpu_sample_color,
            });
            try writer.print(" canvas_revision={d} canvas_commands={d} canvas_frame_requires_render={any} canvas_frame_full_repaint={any} canvas_frame_batches={d} canvas_frame_encoder_commands={d} canvas_frame_encoder_cache_actions={d} canvas_frame_encoder_pipeline_binds={d} canvas_frame_encoder_draws={d} canvas_frame_pipelines={d} canvas_frame_pipeline_uploads={d} canvas_frame_pipeline_retains={d} canvas_frame_pipeline_evicts={d}", .{
                view.canvas_revision,
                view.canvas_command_count,
                view.canvas_frame_requires_render,
                view.canvas_frame_full_repaint,
                view.canvas_frame_batch_count,
                view.canvas_frame_encoder_command_count,
                view.canvas_frame_encoder_cache_action_count,
                view.canvas_frame_encoder_bind_pipeline_count,
                view.canvas_frame_encoder_draw_batch_count,
                view.canvas_frame_pipeline_count,
                view.canvas_frame_pipeline_upload_count,
                view.canvas_frame_pipeline_retain_count,
                view.canvas_frame_pipeline_evict_count,
            });
            try writer.print(" canvas_frame_path_geometries={d} canvas_frame_path_vertices={d} canvas_frame_path_indices={d} canvas_frame_path_uploads={d} canvas_frame_path_retains={d} canvas_frame_path_evicts={d} canvas_frame_images={d} canvas_frame_image_uploads={d} canvas_frame_image_retains={d} canvas_frame_image_evicts={d}", .{
                view.canvas_frame_path_geometry_count,
                view.canvas_frame_path_geometry_vertex_count,
                view.canvas_frame_path_geometry_index_count,
                view.canvas_frame_path_geometry_upload_count,
                view.canvas_frame_path_geometry_retain_count,
                view.canvas_frame_path_geometry_evict_count,
                view.canvas_frame_image_count,
                view.canvas_frame_image_upload_count,
                view.canvas_frame_image_retain_count,
                view.canvas_frame_image_evict_count,
            });
            try writer.print(" canvas_frame_layers={d} canvas_frame_opacity_layers={d} canvas_frame_clip_layers={d} canvas_frame_transform_layers={d} canvas_frame_layer_uploads={d} canvas_frame_layer_retains={d} canvas_frame_layer_evicts={d}", .{
                view.canvas_frame_layer_count,
                view.canvas_frame_layer_opacity_count,
                view.canvas_frame_layer_clip_count,
                view.canvas_frame_layer_transform_count,
                view.canvas_frame_layer_upload_count,
                view.canvas_frame_layer_retain_count,
                view.canvas_frame_layer_evict_count,
            });
            try writer.print(" canvas_frame_resources={d} canvas_frame_uploads={d} canvas_frame_retains={d} canvas_frame_evicts={d} canvas_frame_effects={d} canvas_frame_shadows={d} canvas_frame_blurs={d} canvas_frame_effect_uploads={d} canvas_frame_effect_retains={d} canvas_frame_effect_evicts={d}", .{
                view.canvas_frame_resource_count,
                view.canvas_frame_resource_upload_count,
                view.canvas_frame_resource_retain_count,
                view.canvas_frame_resource_evict_count,
                view.canvas_frame_visual_effect_count,
                view.canvas_frame_visual_effect_shadow_count,
                view.canvas_frame_visual_effect_blur_count,
                view.canvas_frame_visual_effect_upload_count,
                view.canvas_frame_visual_effect_retain_count,
                view.canvas_frame_visual_effect_evict_count,
            });
            try writer.print(" canvas_frame_glyphs={d} canvas_frame_glyph_uploads={d} canvas_frame_glyph_retains={d} canvas_frame_glyph_evicts={d} canvas_frame_text_layouts={d} canvas_frame_text_lines={d} canvas_frame_text_uploads={d} canvas_frame_text_retains={d} canvas_frame_text_evicts={d}", .{
                view.canvas_frame_glyph_atlas_entry_count,
                view.canvas_frame_glyph_atlas_upload_count,
                view.canvas_frame_glyph_atlas_retain_count,
                view.canvas_frame_glyph_atlas_evict_count,
                view.canvas_frame_text_layout_count,
                view.canvas_frame_text_layout_line_count,
                view.canvas_frame_text_layout_upload_count,
                view.canvas_frame_text_layout_retain_count,
                view.canvas_frame_text_layout_evict_count,
            });
            try writer.print(" canvas_frame_gpu_packet_commands={d} canvas_frame_gpu_packet_cache_actions={d} canvas_frame_gpu_packet_cached_resources={d} canvas_frame_gpu_packet_unsupported={d} canvas_frame_gpu_packet_representable={any}", .{
                view.canvas_frame_gpu_packet_command_count,
                view.canvas_frame_gpu_packet_cache_action_count,
                view.canvas_frame_gpu_packet_cached_resource_command_count,
                view.canvas_frame_gpu_packet_unsupported_command_count,
                view.canvas_frame_gpu_packet_representable,
            });
            try writer.print(" canvas_frame_changes={d} canvas_frame_budget_exceeded={d} canvas_frame_budget_ok={any}", .{
                view.canvas_frame_change_count,
                view.canvas_frame_budget_exceeded_count,
                view.canvas_frame_budget_ok,
            });
            if (view.canvas_frame_dirty_bounds) |dirty| {
                try writer.print(" canvas_frame_dirty=({d},{d} {d}x{d})", .{ dirty.x, dirty.y, dirty.width, dirty.height });
            } else {
                try writer.writeAll(" canvas_frame_dirty=null");
            }
            try writer.print(" canvas_frame_profile_work_units={d} canvas_frame_profile_risk={s} canvas_frame_profile_surface_area={d} canvas_frame_profile_dirty_area={d} canvas_frame_profile_dirty_ratio={d}", .{
                view.canvas_frame_profile_work_units,
                @tagName(view.canvas_frame_profile_risk),
                view.canvas_frame_profile_surface_area,
                view.canvas_frame_profile_dirty_area,
                view.canvas_frame_profile_dirty_ratio,
            });
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
        try writeWidgetParent(widget, writer);
        if (widget.value) |value| try writer.print(" value={d}", .{value});
        try writeWidgetTextValue(widget, writer);
        try writeWidgetPlaceholder(widget, writer);
        try writeWidgetGrid(widget, writer);
        try writeWidgetList(widget, writer);
        try writeWidgetScroll(widget, writer);
        try writeWidgetVirtualRange(widget, writer);
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
        try writeWidgetParent(widget, writer);
        if (widget.value) |value| try writer.print(" value={d}", .{value});
        try writeWidgetTextValue(widget, writer);
        try writeWidgetGrid(widget, writer);
        try writeWidgetList(widget, writer);
        try writeWidgetScroll(widget, writer);
        try writeWidgetVirtualRange(widget, writer);
        try writeWidgetState(widget, writer);
        try writeWidgetActions(widget.actions, writer);
        try writeWidgetTextRanges(widget, writer);
        try writer.writeByte('\n');
    }
}

fn writeWidgetParent(widget: Widget, writer: anytype) !void {
    if (widget.parent_id) |parent_id| try writer.print(" parent=#{d}", .{parent_id});
}

fn writeWidgetTextValue(widget: Widget, writer: anytype) !void {
    if (widget.text_value.len == 0) return;
    try writer.print(" text=\"{s}\"", .{widget.text_value});
}

fn writeWidgetPlaceholder(widget: Widget, writer: anytype) !void {
    if (widget.placeholder.len == 0) return;
    try writer.print(" placeholder=\"{s}\"", .{widget.placeholder});
}

fn writeWidgetGrid(widget: Widget, writer: anytype) !void {
    if (widget.grid_row_index == null and
        widget.grid_column_index == null and
        widget.grid_row_count == null and
        widget.grid_column_count == null) return;

    try writer.writeAll(" grid=[");
    var wrote = false;
    try writeWidgetGridValue("row_index", widget.grid_row_index, &wrote, writer);
    try writeWidgetGridValue("column_index", widget.grid_column_index, &wrote, writer);
    try writeWidgetGridValue("row_count", widget.grid_row_count, &wrote, writer);
    try writeWidgetGridValue("column_count", widget.grid_column_count, &wrote, writer);
    try writer.writeByte(']');
}

fn writeWidgetGridValue(name: []const u8, value: ?usize, wrote: *bool, writer: anytype) !void {
    const unwrapped = value orelse return;
    if (wrote.*) try writer.writeByte(',');
    try writer.print("{s}={d}", .{ name, unwrapped });
    wrote.* = true;
}

fn writeWidgetList(widget: Widget, writer: anytype) !void {
    if (!widget.list.present) return;
    try writer.print(" list=[index={d},count={d}]", .{ widget.list.item_index, widget.list.item_count });
}

fn writeWidgetScroll(widget: Widget, writer: anytype) !void {
    if (!widget.scroll.present) return;
    try writer.print(" scroll=[offset={d},viewport={d},content={d}]", .{
        widget.scroll.offset,
        widget.scroll.viewport_extent,
        widget.scroll.content_extent,
    });
}

fn writeWidgetVirtualRange(widget: Widget, writer: anytype) !void {
    if (!widget.virtual_range.present) return;
    try writer.print(" virtual=[start={d},end={d},first={d},last={d},rendered={d}]", .{
        widget.virtual_range.start_index,
        widget.virtual_range.end_index,
        widget.virtual_range.first_visible_index,
        widget.virtual_range.last_visible_index,
        widget.virtual_range.rendered_count,
    });
}

fn writeWidgetState(widget: Widget, writer: anytype) !void {
    if (!widget.focused and
        widget.enabled and
        !widget.hovered and
        !widget.pressed and
        !widget.selected and
        widget.expanded == null and
        !widget.required and
        !widget.read_only and
        !widget.invalid) return;
    try writer.writeAll(" state=[");
    var wrote = false;
    try writeWidgetStateFlag(widget.focused, "focused", &wrote, writer);
    try writeWidgetStateFlag(!widget.enabled, "disabled", &wrote, writer);
    try writeWidgetStateFlag(widget.hovered, "hovered", &wrote, writer);
    try writeWidgetStateFlag(widget.pressed, "pressed", &wrote, writer);
    try writeWidgetStateFlag(widget.selected, "selected", &wrote, writer);
    if (widget.expanded) |expanded| {
        try writeWidgetStateFlag(true, if (expanded) "expanded" else "collapsed", &wrote, writer);
    }
    try writeWidgetStateFlag(widget.required, "required", &wrote, writer);
    try writeWidgetStateFlag(widget.read_only, "read_only", &wrote, writer);
    try writeWidgetStateFlag(widget.invalid, "invalid", &wrote, writer);
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
    try writeWidgetAction(actions.set_selection, "set_selection", &wrote, writer);
    try writeWidgetAction(actions.select, "select", &wrote, writer);
    try writeWidgetAction(actions.drag, "drag", &wrote, writer);
    try writeWidgetAction(actions.drop_files, "drop_files", &wrote, writer);
    try writeWidgetAction(actions.dismiss, "dismiss", &wrote, writer);
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
        .diagnostics = .{ .runtime_uptime_ns = 42 },
        .source = platform.WebViewSource.html("<h1>Hello</h1>"),
    }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ready=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "runtime_uptime_ns=42") != null);
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
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const views = [_]platform.ViewInfo{.{
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 100, 100),
        .gpu_size = geometry.SizeF.init(320, 180),
        .gpu_scale_factor = 2,
        .gpu_backend = .metal,
        .gpu_pixel_format = .bgra8_unorm,
        .gpu_present_mode = .timer,
        .gpu_alpha_mode = .@"opaque",
        .gpu_color_space = .srgb,
        .gpu_vsync = true,
        .gpu_status = .ready,
        .gpu_frame_index = 4,
        .gpu_timestamp_ns = 99,
        .gpu_frame_interval_ns = 8,
        .gpu_input_timestamp_ns = 80,
        .gpu_input_latency_ns = 19,
        .gpu_input_latency_budget_ns = 16,
        .gpu_input_latency_budget_exceeded_count = 1,
        .gpu_input_latency_budget_ok = false,
        .gpu_first_frame_latency_ns = 24,
        .gpu_first_frame_latency_budget_ns = 150,
        .gpu_first_frame_latency_budget_exceeded_count = 0,
        .gpu_first_frame_latency_budget_ok = true,
        .gpu_frame_nonblank = true,
        .gpu_sample_color = 0xff336699,
        .canvas_revision = 2,
        .canvas_command_count = 5,
        .canvas_frame_requires_render = true,
        .canvas_frame_full_repaint = true,
        .canvas_frame_batch_count = 3,
        .canvas_frame_encoder_command_count = 8,
        .canvas_frame_encoder_cache_action_count = 2,
        .canvas_frame_encoder_bind_pipeline_count = 3,
        .canvas_frame_encoder_draw_batch_count = 3,
        .canvas_frame_pipeline_count = 2,
        .canvas_frame_pipeline_upload_count = 1,
        .canvas_frame_pipeline_retain_count = 1,
        .canvas_frame_pipeline_evict_count = 0,
        .canvas_frame_path_geometry_count = 3,
        .canvas_frame_path_geometry_vertex_count = 18,
        .canvas_frame_path_geometry_index_count = 24,
        .canvas_frame_path_geometry_upload_count = 2,
        .canvas_frame_path_geometry_retain_count = 1,
        .canvas_frame_path_geometry_evict_count = 0,
        .canvas_frame_image_count = 2,
        .canvas_frame_image_upload_count = 1,
        .canvas_frame_image_retain_count = 1,
        .canvas_frame_image_evict_count = 0,
        .canvas_frame_layer_count = 3,
        .canvas_frame_layer_opacity_count = 1,
        .canvas_frame_layer_clip_count = 1,
        .canvas_frame_layer_transform_count = 1,
        .canvas_frame_layer_upload_count = 2,
        .canvas_frame_layer_retain_count = 1,
        .canvas_frame_layer_evict_count = 0,
        .canvas_frame_resource_count = 2,
        .canvas_frame_resource_upload_count = 1,
        .canvas_frame_resource_retain_count = 1,
        .canvas_frame_resource_evict_count = 0,
        .canvas_frame_visual_effect_count = 3,
        .canvas_frame_visual_effect_shadow_count = 2,
        .canvas_frame_visual_effect_blur_count = 1,
        .canvas_frame_visual_effect_upload_count = 2,
        .canvas_frame_visual_effect_retain_count = 1,
        .canvas_frame_visual_effect_evict_count = 0,
        .canvas_frame_glyph_atlas_entry_count = 4,
        .canvas_frame_glyph_atlas_upload_count = 2,
        .canvas_frame_glyph_atlas_retain_count = 2,
        .canvas_frame_glyph_atlas_evict_count = 0,
        .canvas_frame_text_layout_count = 2,
        .canvas_frame_text_layout_line_count = 4,
        .canvas_frame_text_layout_upload_count = 1,
        .canvas_frame_text_layout_retain_count = 1,
        .canvas_frame_text_layout_evict_count = 0,
        .canvas_frame_gpu_packet_command_count = 5,
        .canvas_frame_gpu_packet_cache_action_count = 7,
        .canvas_frame_gpu_packet_cached_resource_command_count = 4,
        .canvas_frame_gpu_packet_unsupported_command_count = 0,
        .canvas_frame_gpu_packet_representable = true,
        .canvas_frame_change_count = 0,
        .canvas_frame_budget_exceeded_count = 2,
        .canvas_frame_budget_ok = false,
        .canvas_frame_dirty_bounds = geometry.RectF.init(0, 0, 320, 180),
        .canvas_frame_profile_work_units = 42,
        .canvas_frame_profile_risk = .high,
        .canvas_frame_profile_surface_area = 57600,
        .canvas_frame_profile_dirty_area = 32000,
        .canvas_frame_profile_dirty_ratio = 0.5555556,
        .cursor = .text,
    }};
    try writeText(.{
        .windows = &windows,
        .views = &views,
    }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_size=320x180") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_scale=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_backend=metal") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_pixel_format=bgra8_unorm") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_present_mode=timer") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_alpha_mode=opaque") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_color_space=srgb") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_vsync=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_status=ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_frame=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_timestamp_ns=99") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_frame_interval_ns=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_input_timestamp_ns=80") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_input_latency_ns=19") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_input_latency_budget_ns=16") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_input_latency_budget_exceeded=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_input_latency_budget_ok=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_first_frame_latency_ns=24") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_first_frame_latency_budget_ns=150") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_first_frame_latency_budget_exceeded=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_first_frame_latency_budget_ok=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_nonblank=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_sample=0xff336699") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_revision=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_commands=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_requires_render=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_full_repaint=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_batches=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_encoder_commands=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_encoder_pipeline_binds=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_pipelines=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_pipeline_uploads=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_path_geometries=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_path_vertices=18") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_path_indices=24") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_path_uploads=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_path_retains=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_images=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_image_uploads=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_image_retains=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_layers=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_opacity_layers=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_clip_layers=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_transform_layers=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_layer_uploads=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_resources=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_uploads=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_retains=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_evicts=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_effects=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_shadows=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_blurs=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_effect_uploads=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_effect_retains=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_glyphs=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_glyph_uploads=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_glyph_retains=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_text_layouts=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_text_lines=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_text_uploads=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_text_retains=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_gpu_packet_commands=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_gpu_packet_cache_actions=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_gpu_packet_cached_resources=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_gpu_packet_unsupported=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_gpu_packet_representable=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_changes=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_budget_exceeded=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_budget_ok=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_dirty=(0,0 320x180)") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_profile_work_units=42") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_profile_risk=high") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_profile_surface_area=57600") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_profile_dirty_area=32000") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "widget_cursor=text") != null);
}

test "snapshot emits widget semantics" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const views = [_]platform.ViewInfo{.{ .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 100, 100), .role = "canvas" }};
    const widgets = [_]Widget{
        .{
            .window_id = 1,
            .view_label = "canvas",
            .id = 42,
            .role = "button",
            .name = "Run query",
            .parent_id = 7,
            .text_value = "deploy",
            .placeholder = "Search deployments",
            .grid_row_index = 1,
            .grid_column_index = 2,
            .grid_row_count = 4,
            .grid_column_count = 5,
            .list = .{
                .present = true,
                .item_index = 3,
                .item_count = 9,
            },
            .scroll = .{
                .present = true,
                .offset = 12.0,
                .viewport_extent = 80.0,
                .content_extent = 180.0,
            },
            .virtual_range = .{
                .present = true,
                .start_index = 2,
                .end_index = 7,
                .first_visible_index = 3,
                .last_visible_index = 5,
                .rendered_count = 5,
            },
            .bounds = geometry.RectF.init(10, 12, 80, 32),
            .focused = true,
            .hovered = true,
            .pressed = true,
            .selected = true,
            .expanded = true,
            .required = true,
            .read_only = true,
            .invalid = true,
            .actions = .{ .focus = true, .press = true, .set_selection = true, .drag = true, .drop_files = true, .dismiss = true },
            .text_selection = .{ .start = 4, .end = 4 },
            .text_composition = .{ .start = 0, .end = 3 },
        },
        .{
            .window_id = 1,
            .view_label = "canvas",
            .id = 43,
            .role = "button",
            .name = "Disabled",
            .bounds = geometry.RectF.init(10, 48, 80, 32),
            .enabled = false,
            .expanded = false,
        },
    };
    try writeText(.{
        .windows = &windows,
        .views = &views,
        .widgets = &widgets,
    }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "widget @w1/canvas#42 role=button name=\"Run query\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "parent=#7") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "text=\"deploy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "placeholder=\"Search deployments\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "grid=[row_index=1,column_index=2,row_count=4,column_count=5]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "list=[index=3,count=9]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "scroll=[offset=12,viewport=80,content=180]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "virtual=[start=2,end=7,first=3,last=5,rendered=5]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "state=[focused,hovered,pressed,selected,expanded,required,read_only,invalid]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "@w1/canvas#43 role=button name=\"Disabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "state=[disabled,collapsed]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "actions=[focus,press,set_selection,drag,drop_files,dismiss]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "selection=4..4") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "composition=0..3") != null);

    var a11y_buffer: [2048]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try writeA11yText(.{
        .windows = &windows,
        .views = &views,
        .widgets = &widgets,
    }, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "a11y root=@w1 nodes=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#42 role=button name=\"Run query\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "parent=#7") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "text=\"deploy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "grid=[row_index=1,column_index=2,row_count=4,column_count=5]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "list=[index=3,count=9]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "scroll=[offset=12,viewport=80,content=180]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "state=[focused,hovered,pressed,selected,expanded,required,read_only,invalid]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#43 role=button name=\"Disabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "state=[disabled,collapsed]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "actions=[focus,press,set_selection,drag,drop_files,dismiss]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "selection=4..4") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "composition=0..3") != null);
}
