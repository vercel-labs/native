const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const runtime = @import("../runtime/root.zig");
const platform = @import("../platform/root.zig");
const types = @import("types.zig");

const MobileWidgetRole = types.MobileWidgetRole;
const MobileWidgetFlag = types.MobileWidgetFlag;
const MobileWidgetAction = types.MobileWidgetAction;
const MobileWidgetActionKind = types.MobileWidgetActionKind;
const MobileWidgetSemantics = types.MobileWidgetSemantics;
const MobileWidgetTextGeometry = types.MobileWidgetTextGeometry;
const MobileViewportState = types.MobileViewportState;
const MobileGpuFrameState = types.MobileGpuFrameState;

pub fn mobileViewportStateFromSurface(surface: platform.Surface) MobileViewportState {
    const content = geometry.RectF.fromSize(surface.size).deflate(combinedMobileViewportInsets(surface));
    return .{
        .width = surface.size.width,
        .height = surface.size.height,
        .scale = surface.scale_factor,
        .has_surface = if (surface.native_handle != null) 1 else 0,
        .safe_top = surface.safe_area_insets.top,
        .safe_right = surface.safe_area_insets.right,
        .safe_bottom = surface.safe_area_insets.bottom,
        .safe_left = surface.safe_area_insets.left,
        .keyboard_top = surface.keyboard_insets.top,
        .keyboard_right = surface.keyboard_insets.right,
        .keyboard_bottom = surface.keyboard_insets.bottom,
        .keyboard_left = surface.keyboard_insets.left,
        .content_x = content.x,
        .content_y = content.y,
        .content_width = content.width,
        .content_height = content.height,
    };
}

pub fn mobileGpuFrameStateFromFrame(frame: platform.GpuFrame) MobileGpuFrameState {
    return .{
        .surface_id = frame.surface_id,
        .window_id = frame.window_id,
        .width = frame.size.width,
        .height = frame.size.height,
        .scale = frame.scale_factor,
        .frame_index = frame.frame_index,
        .timestamp_ns = frame.timestamp_ns,
        .frame_interval_ns = frame.frame_interval_ns,
        .input_timestamp_ns = frame.input_timestamp_ns,
        .input_latency_ns = frame.input_latency_ns,
        .input_latency_budget_ns = frame.input_latency_budget_ns,
        .input_latency_budget_exceeded_count = frame.input_latency_budget_exceeded_count,
        .input_latency_budget_ok = if (frame.input_latency_budget_ok) 1 else 0,
        .first_frame_latency_ns = frame.first_frame_latency_ns,
        .first_frame_latency_budget_ns = frame.first_frame_latency_budget_ns,
        .first_frame_latency_budget_exceeded_count = frame.first_frame_latency_budget_exceeded_count,
        .first_frame_latency_budget_ok = if (frame.first_frame_latency_budget_ok) 1 else 0,
        .nonblank = if (frame.nonblank) 1 else 0,
        .sample_color = frame.sample_color,
        .status = @intFromEnum(frame.status),
        .vsync = if (frame.vsync) 1 else 0,
        .canvas_revision = frame.canvas_revision,
        .canvas_command_count = frame.canvas_command_count,
        .canvas_frame_requires_render = if (frame.canvas_frame_requires_render) 1 else 0,
        .canvas_frame_full_repaint = if (frame.canvas_frame_full_repaint) 1 else 0,
        .canvas_frame_batch_count = frame.canvas_frame_batch_count,
        .canvas_frame_budget_exceeded_count = frame.canvas_frame_budget_exceeded_count,
        .canvas_frame_budget_ok = if (frame.canvas_frame_budget_ok) 1 else 0,
        .widget_revision = frame.widget_revision,
        .widget_node_count = frame.widget_node_count,
        .widget_semantics_count = frame.widget_semantics_count,
    };
}

pub fn combinedMobileViewportInsets(surface: platform.Surface) geometry.InsetsF {
    return .{
        .top = @max(surface.safe_area_insets.top, surface.keyboard_insets.top),
        .right = @max(surface.safe_area_insets.right, surface.keyboard_insets.right),
        .bottom = @max(surface.safe_area_insets.bottom, surface.keyboard_insets.bottom),
        .left = @max(surface.safe_area_insets.left, surface.keyboard_insets.left),
    };
}

pub fn mobileSurface(width: f32, height: f32, scale: f32, surface: ?*anyopaque, safe_area_insets: geometry.InsetsF, keyboard_insets: geometry.InsetsF) platform.Surface {
    return .{
        .size = .{ .width = width, .height = height },
        .scale_factor = scale,
        .safe_area_insets = safe_area_insets,
        .keyboard_insets = keyboard_insets,
        .native_handle = surface,
    };
}
pub fn mobileTouchKindFromPhase(phase: c_int) anyerror!platform.GpuSurfaceInputKind {
    return switch (phase) {
        0, 5 => .pointer_down,
        1, 6 => .pointer_up,
        2 => .pointer_drag,
        3 => .pointer_cancel,
        else => error.InvalidTouchPhase,
    };
}

pub fn mobileKeyKindFromPhase(phase: c_int) anyerror!platform.GpuSurfaceInputKind {
    return switch (phase) {
        0 => .key_down,
        1 => .key_up,
        else => error.InvalidKeyPhase,
    };
}

pub fn mobileImeKindFromInt(kind: c_int) anyerror!platform.GpuSurfaceInputKind {
    return switch (kind) {
        0 => .ime_set_composition,
        1 => .ime_commit_composition,
        2 => .ime_cancel_composition,
        else => error.InvalidImeKind,
    };
}

pub fn mobileModifiersFromMask(mask: u32) platform.ShortcutModifiers {
    return .{
        .primary = (mask & 1) != 0,
        .command = (mask & 2) != 0,
        .control = (mask & 4) != 0,
        .option = (mask & 8) != 0,
        .shift = (mask & 16) != 0,
    };
}

pub fn mobileWidgetActionKindFromInt(value: c_int) anyerror!runtime.CanvasWidgetAccessibilityActionKind {
    return switch (value) {
        @intFromEnum(MobileWidgetActionKind.focus) => .focus,
        @intFromEnum(MobileWidgetActionKind.press) => .press,
        @intFromEnum(MobileWidgetActionKind.toggle) => .toggle,
        @intFromEnum(MobileWidgetActionKind.increment) => .increment,
        @intFromEnum(MobileWidgetActionKind.decrement) => .decrement,
        @intFromEnum(MobileWidgetActionKind.set_text) => .set_text,
        @intFromEnum(MobileWidgetActionKind.set_selection) => .set_selection,
        @intFromEnum(MobileWidgetActionKind.set_composition) => .set_composition,
        @intFromEnum(MobileWidgetActionKind.commit_composition) => .commit_composition,
        @intFromEnum(MobileWidgetActionKind.cancel_composition) => .cancel_composition,
        @intFromEnum(MobileWidgetActionKind.select) => .select,
        @intFromEnum(MobileWidgetActionKind.drag) => .drag,
        @intFromEnum(MobileWidgetActionKind.drop_files) => .drop_files,
        @intFromEnum(MobileWidgetActionKind.dismiss) => .dismiss,
        else => error.InvalidCommand,
    };
}

/// Audio event kind ordinals over the C ABI (`native_sdk_app_audio_event`),
/// matching `platform.AudioEventKind` and the macOS host's constants:
/// 0 loaded, 1 position, 2 completed, 3 failed.
pub fn mobileAudioEventKindFromInt(kind: c_int) anyerror!platform.AudioEventKind {
    return switch (kind) {
        0 => .loaded,
        1 => .position,
        2 => .completed,
        3 => .failed,
        else => error.InvalidAudioOptions,
    };
}

pub fn inputSlice(pointer: ?[*]const u8, len: usize) anyerror![]const u8 {
    if (len == 0) return "";
    const value = pointer orelse return error.InvalidCommand;
    return value[0..len];
}

pub fn copyInputText(buffer: []u8, value: []const u8) usize {
    const count = @min(buffer.len, value.len);
    @memcpy(buffer[0..count], value[0..count]);
    return count;
}

pub fn mobileWidgetSemanticsFromNode(nodes: []const canvas.WidgetSemanticsNode, index: usize) MobileWidgetSemantics {
    const node = nodes[index];
    const label = mobileOptionalString(node.label);
    const text = mobileOptionalString(node.text_value);
    const placeholder = mobileOptionalString(node.placeholder);
    return .{
        .id = node.id,
        .parent_id = mobileWidgetSemanticParentId(nodes, node.parent_index),
        .role = @intFromEnum(mobileWidgetRole(node.role)),
        .flags = mobileWidgetFlags(node),
        .actions = mobileWidgetActions(node.actions),
        .x = node.bounds.x,
        .y = node.bounds.y,
        .width = node.bounds.width,
        .height = node.bounds.height,
        .value = node.value orelse 0,
        .has_value = if (node.value != null) 1 else 0,
        .label = label.ptr,
        .label_len = label.len,
        .text = text.ptr,
        .text_len = text.len,
        .placeholder = placeholder.ptr,
        .placeholder_len = placeholder.len,
        .text_selection_start = mobileTextRangeStart(node.text_selection),
        .text_selection_end = mobileTextRangeEnd(node.text_selection),
        .text_composition_start = mobileTextRangeStart(node.text_composition),
        .text_composition_end = mobileTextRangeEnd(node.text_composition),
        .grid_row_index = mobileOptionalIndex(node.grid_row_index),
        .grid_column_index = mobileOptionalIndex(node.grid_column_index),
        .grid_row_count = mobileOptionalIndex(node.grid_row_count),
        .grid_column_count = mobileOptionalIndex(node.grid_column_count),
        .list_item_index = if (node.list.present) mobileU32Index(node.list.item_index) else -1,
        .list_item_count = if (node.list.present) mobileU32Index(node.list.item_count) else -1,
        .scroll_offset = node.scroll.offset,
        .scroll_viewport_extent = node.scroll.viewport_extent,
        .scroll_content_extent = node.scroll.content_extent,
        .has_scroll = if (node.scroll.present) 1 else 0,
    };
}

pub fn mobileWidgetTextGeometryFromCanvas(id: canvas.ObjectId, geometry_value: canvas.WidgetTextGeometry) MobileWidgetTextGeometry {
    var value = MobileWidgetTextGeometry{
        .id = id,
        .selection_rect_count = geometry_value.selection_rect_count,
        .composition_rect_count = geometry_value.composition_rect_count,
    };
    if (geometry_value.caret_bounds) |bounds| {
        value.has_caret_bounds = 1;
        value.caret_x = bounds.x;
        value.caret_y = bounds.y;
        value.caret_width = bounds.width;
        value.caret_height = bounds.height;
    }
    if (geometry_value.selection_bounds) |bounds| {
        value.has_selection_bounds = 1;
        value.selection_x = bounds.x;
        value.selection_y = bounds.y;
        value.selection_width = bounds.width;
        value.selection_height = bounds.height;
    }
    if (geometry_value.composition_bounds) |bounds| {
        value.has_composition_bounds = 1;
        value.composition_x = bounds.x;
        value.composition_y = bounds.y;
        value.composition_width = bounds.width;
        value.composition_height = bounds.height;
    }
    return value;
}

pub fn mobileWidgetSemanticParentId(nodes: []const canvas.WidgetSemanticsNode, parent_index: ?usize) u64 {
    const index = parent_index orelse return 0;
    if (index >= nodes.len) return 0;
    return nodes[index].id;
}

const MobileStringView = struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub fn mobileOptionalString(value: []const u8) MobileStringView {
    return .{
        .ptr = if (value.len > 0) value.ptr else null,
        .len = value.len,
    };
}

pub fn mobileWidgetRole(role: canvas.WidgetRole) MobileWidgetRole {
    return switch (role) {
        .none => .none,
        .group => .group,
        .text => .text,
        // The mobile ABI predates the link role; expose links as pressable
        // text until the ABI grows a dedicated value.
        .link => .text,
        .image => .image,
        .button => .button,
        .textbox => .textbox,
        .tooltip => .tooltip,
        .dialog => .dialog,
        .menu => .menu,
        .menuitem => .menuitem,
        .list => .list,
        .listitem => .listitem,
        .row => .row,
        .grid => .grid,
        .gridcell => .gridcell,
        .tab => .tab,
        .checkbox => .checkbox,
        .radio => .radio,
        .switch_control => .switch_control,
        .slider => .slider,
        .progressbar => .progressbar,
        // The mobile ABI predates the chart role; expose charts as images
        // carrying the series-summary label.
        .chart => .image,
        // The mobile ABI predates the tree/treeitem/separator roles;
        // trees expose as lists (rows as list items) and the split
        // divider as a group whose value carries the fraction.
        .tree => .list,
        .treeitem => .listitem,
        .separator => .group,
    };
}

pub fn mobileWidgetFlags(node: canvas.WidgetSemanticsNode) u32 {
    var flags: u32 = 0;
    if (node.state.focused) flags |= @intFromEnum(MobileWidgetFlag.focused);
    if (node.state.hovered) flags |= @intFromEnum(MobileWidgetFlag.hovered);
    if (node.state.pressed) flags |= @intFromEnum(MobileWidgetFlag.pressed);
    if (node.state.selected) flags |= @intFromEnum(MobileWidgetFlag.selected);
    if (node.state.disabled) flags |= @intFromEnum(MobileWidgetFlag.disabled);
    if (node.focusable) flags |= @intFromEnum(MobileWidgetFlag.focusable);
    if (node.state.expanded) |expanded| {
        flags |= @intFromEnum(if (expanded) MobileWidgetFlag.expanded else MobileWidgetFlag.collapsed);
    }
    if (node.state.required) flags |= @intFromEnum(MobileWidgetFlag.required);
    if (node.state.read_only) flags |= @intFromEnum(MobileWidgetFlag.read_only);
    if (node.state.invalid) flags |= @intFromEnum(MobileWidgetFlag.invalid);
    return flags;
}

pub fn mobileWidgetActions(actions: canvas.WidgetActions) u32 {
    var flags: u32 = 0;
    if (actions.focus) flags |= @intFromEnum(MobileWidgetAction.focus);
    if (actions.press) flags |= @intFromEnum(MobileWidgetAction.press);
    if (actions.toggle) flags |= @intFromEnum(MobileWidgetAction.toggle);
    if (actions.increment) flags |= @intFromEnum(MobileWidgetAction.increment);
    if (actions.decrement) flags |= @intFromEnum(MobileWidgetAction.decrement);
    if (actions.set_text) flags |= @intFromEnum(MobileWidgetAction.set_text);
    if (actions.set_selection) flags |= @intFromEnum(MobileWidgetAction.set_selection);
    if (actions.select) flags |= @intFromEnum(MobileWidgetAction.select);
    if (actions.drag) flags |= @intFromEnum(MobileWidgetAction.drag);
    if (actions.drop_files) flags |= @intFromEnum(MobileWidgetAction.drop_files);
    if (actions.dismiss) flags |= @intFromEnum(MobileWidgetAction.dismiss);
    return flags;
}

pub fn mobileOptionalIndex(value: ?usize) isize {
    const index = value orelse return -1;
    if (index > @as(usize, @intCast(std.math.maxInt(isize)))) return std.math.maxInt(isize);
    return @intCast(index);
}

pub fn mobileU32Index(value: u32) isize {
    return @intCast(value);
}

pub fn mobileTextRangeStart(range: ?canvas.TextRange) isize {
    const value = range orelse return -1;
    return mobileOptionalIndex(value.start);
}

pub fn mobileTextRangeEnd(range: ?canvas.TextRange) isize {
    const value = range orelse return -1;
    return mobileOptionalIndex(value.end);
}
/// Wall-clock nanoseconds for embed input timestamps, through the
/// runtime clock seam (which covers Windows via the NT precise system
/// time and degrades to 0 only on targets without a readable clock).
pub fn nowNanoseconds() u64 {
    const ns = runtime.nowNanoseconds();
    return if (ns > 0) @intCast(ns) else 0;
}
