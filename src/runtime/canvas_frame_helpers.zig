const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");

const GpuSurfaceInputEvent = platform.GpuSurfaceInputEvent;
const max_canvas_surface_extent_pixels: f32 = 16_384;

pub const CanvasPixelSize = struct {
    width: usize,
    height: usize,
    byte_len: usize,
};

pub fn appendCanvasSummaryChange(output: []canvas.DiffChange, len: *usize, change: canvas.DiffChange) anyerror!void {
    if (len.* >= output.len) return error.DiffListFull;
    output[len.*] = change;
    len.* += 1;
}

pub fn canvasDirtyBoundsFromChanges(changes: []const canvas.DiffChange) ?geometry.RectF {
    var result: ?geometry.RectF = null;
    for (changes) |change| {
        result = unionRects(result, change.dirty_bounds);
    }
    return result;
}

pub fn canvasFrameBudgetIsUnset(budget: canvas.CanvasFrameBudget) bool {
    return budget.max_commands == 0 and
        budget.max_batches == 0 and
        budget.max_encoder_commands == 0 and
        budget.max_pipelines == 0 and
        budget.max_pipeline_uploads == 0 and
        budget.max_path_geometries == 0 and
        budget.max_path_geometry_uploads == 0 and
        budget.max_images == 0 and
        budget.max_image_uploads == 0 and
        budget.max_layers == 0 and
        budget.max_layer_uploads == 0 and
        budget.max_resources == 0 and
        budget.max_resource_uploads == 0 and
        budget.max_visual_effects == 0 and
        budget.max_visual_effect_uploads == 0 and
        budget.max_glyph_atlas_entries == 0 and
        budget.max_glyph_atlas_uploads == 0 and
        budget.max_glyph_atlas_evicts == 0 and
        budget.max_text_layouts == 0 and
        budget.max_text_layout_lines == 0 and
        budget.max_text_layout_uploads == 0 and
        budget.max_text_layout_evicts == 0 and
        budget.max_changes == 0;
}

pub fn canvasFullRepaintBounds(surface_size: geometry.SizeF, render_bounds: ?geometry.RectF) ?geometry.RectF {
    if (canvasSurfaceRect(surface_size)) |surface| return surface;
    return render_bounds;
}

pub fn sizesEqual(a: geometry.SizeF, b: geometry.SizeF) bool {
    return a.width == b.width and a.height == b.height;
}

pub fn canvasSurfacePixelSize(surface_size: geometry.SizeF, scale_factor: f32) !CanvasPixelSize {
    const scale = if (std.math.isFinite(scale_factor) and scale_factor > 0) scale_factor else 1;
    const width_f = surface_size.width * scale;
    const height_f = surface_size.height * scale;
    if (!std.math.isFinite(width_f) or !std.math.isFinite(height_f)) return error.InvalidGpuSurfacePixels;
    if (width_f <= 0 or height_f <= 0) return error.InvalidGpuSurfacePixels;
    if (width_f > max_canvas_surface_extent_pixels or height_f > max_canvas_surface_extent_pixels) return error.InvalidGpuSurfacePixels;

    const width: usize = @intFromFloat(@ceil(width_f));
    const height: usize = @intFromFloat(@ceil(height_f));
    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidGpuSurfacePixels;
    const byte_len = std.math.mul(usize, pixel_count, 4) catch return error.InvalidGpuSurfacePixels;
    return .{ .width = width, .height = height, .byte_len = byte_len };
}

pub fn normalizedCanvasPresentationScale(scale_factor: ?f32, fallback: f32) f32 {
    if (scale_factor) |scale| {
        if (std.math.isFinite(scale) and scale > 0) return scale;
    }
    if (std.math.isFinite(fallback) and fallback > 0) return fallback;
    return 1;
}

pub fn canvasFramePixelSize(frame: canvas.CanvasFrame) !CanvasPixelSize {
    return canvasSurfacePixelSize(frame.surface_size, frame.scale);
}

pub fn canvasColorToRgba8(color: canvas.Color) [4]u8 {
    return .{
        normalizedChannelToU8(color.r),
        normalizedChannelToU8(color.g),
        normalizedChannelToU8(color.b),
        normalizedChannelToU8(color.a),
    };
}

fn normalizedChannelToU8(value: f32) u8 {
    const clamped = std.math.clamp(value, 0, 1);
    return @intFromFloat((clamped * 255.0) + 0.5);
}

pub fn clippedCanvasDirtyBounds(bounds: ?geometry.RectF, surface_size: geometry.SizeF) ?geometry.RectF {
    const dirty = bounds orelse return null;
    const normalized = dirty.normalized();
    if (canvasSurfaceRect(surface_size)) |surface| {
        const clipped = geometry.RectF.intersection(surface, normalized);
        return if (clipped.isEmpty()) null else clipped;
    }
    return if (normalized.isEmpty()) null else normalized;
}

/// One device pixel in logical points at `scale`: the anti-aliasing
/// bleed allowance incremental damage adds around changed content.
/// Host rasterizers ink up to a device pixel past a command's bounds
/// (antialiased shape edges and glyph overshoot — the packet host's
/// raster cache carries a one-pixel apron for exactly this), so a
/// damage region cut to the exact bounds strands that fringe: content
/// that shrinks, moves, or disappears leaves stale edge pixels the
/// repaint never touches. Full repaints cover the surface and need no
/// allowance.
pub fn canvasDirtyBleedInset(scale: f32) f32 {
    const normalized = if (std.math.isFinite(scale) and scale > 0) scale else 1;
    return 1.0 / normalized;
}

/// Inflate an incremental dirty rect by the AA bleed allowance (see
/// `canvasDirtyBleedInset`); null stays null so "nothing changed"
/// never becomes a repaint.
pub fn inflatedCanvasDirtyBounds(bounds: ?geometry.RectF, bleed: f32) ?geometry.RectF {
    const dirty = bounds orelse return null;
    return dirty.normalized().inflate(geometry.InsetsF.all(bleed));
}

/// Snap an incremental dirty rect OUTWARD to the device-pixel grid at
/// `scale`. Clears happen on whole pixels while command culling tests
/// the float rect, so a fractional dirty edge erases the boundary
/// pixel's antialiased coverage without redrawing the unchanged
/// neighbor that painted it — a missing fringe. With the rect on the
/// pixel grid, every command overlapping a cleared pixel overlaps the
/// rect and repaints.
pub fn deviceAlignedCanvasDirtyBounds(bounds: ?geometry.RectF, scale: f32) ?geometry.RectF {
    const dirty = bounds orelse return null;
    const normalized = dirty.normalized();
    const device = if (std.math.isFinite(scale) and scale > 0) scale else 1;
    const min_x = alignedCanvasDirtyFloorEdge(normalized.minX(), device);
    const min_y = alignedCanvasDirtyFloorEdge(normalized.minY(), device);
    const max_x = alignedCanvasDirtyCeilEdge(normalized.maxX(), device);
    const max_y = alignedCanvasDirtyCeilEdge(normalized.maxY(), device);
    return geometry.RectF.init(min_x, min_y, @max(0, max_x - min_x), @max(0, max_y - min_y));
}

/// The snapped max edge in logical points, chosen so its f32 product
/// with `device` never exceeds the ceil boundary: `@ceil(v*s)/s` can
/// round UP past the boundary (an edge at 5 points re-snapped at 1.5x
/// becomes 5.3333335, whose product ceils to 9), and a consumer
/// re-deriving pixels from the product would then clear one pixel more
/// than culling against the rect admits — a missing fringe. Nudged
/// down ulp by ulp until the round trip lands on the boundary; never
/// below the original value, so the snap stays outward.
fn alignedCanvasDirtyCeilEdge(value: f32, device: f32) f32 {
    const boundary = @ceil(value * device);
    var edge = boundary / device;
    while (edge * device > boundary) edge = std.math.nextAfter(f32, edge, -std.math.inf(f32));
    return @max(edge, value);
}

/// Floor-side twin of `alignedCanvasDirtyCeilEdge`: the product must
/// not round below the floor boundary, or the consumer clears one
/// extra pixel on the leading edge.
fn alignedCanvasDirtyFloorEdge(value: f32, device: f32) f32 {
    const boundary = @floor(value * device);
    var edge = boundary / device;
    while (edge * device < boundary) edge = std.math.nextAfter(f32, edge, std.math.inf(f32));
    return @min(edge, value);
}

fn canvasSurfaceRect(surface_size: geometry.SizeF) ?geometry.RectF {
    const rect = geometry.RectF.fromSize(surface_size).normalized();
    return if (rect.isEmpty()) null else rect;
}

pub fn unionRects(a: ?geometry.RectF, b: ?geometry.RectF) ?geometry.RectF {
    if (a) |rect_a| {
        if (b) |rect_b| return geometry.RectF.unionWith(rect_a.normalized(), rect_b.normalized());
        return rect_a.normalized();
    }
    if (b) |rect_b| return rect_b.normalized();
    return null;
}

pub fn canvasWidgetPointerEventFromGpuInput(input_event: GpuSurfaceInputEvent) ?canvas.WidgetPointerEvent {
    const phase: canvas.WidgetPointerPhase = switch (input_event.kind) {
        .pointer_down => .down,
        .pointer_up => .up,
        .pointer_cancel => .cancel,
        .pointer_move => .hover,
        .pointer_drag => .move,
        .scroll => .wheel,
        .key_down,
        .key_up,
        .text_input,
        .ime_set_composition,
        .ime_commit_composition,
        .ime_cancel_composition,
        // Pinch is not a widget pointer gesture: it reaches the app as
        // the raw `gpu_surface_input` event (timeline/canvas zoom is an
        // app-level concern, not a widget press/scroll).
        .pinch_begin,
        .pinch_change,
        .pinch_end,
        => return null,
    };
    return .{
        .phase = phase,
        .point = geometry.PointF.init(input_event.x, input_event.y),
        .delta = geometry.OffsetF.init(input_event.delta_x, input_event.delta_y),
    };
}

pub fn canvasWidgetInputBatchesDisplayListRefresh(kind: platform.GpuSurfaceInputKind) bool {
    return switch (kind) {
        .pointer_down,
        .pointer_up,
        .pointer_cancel,
        .pointer_move,
        .pointer_drag,
        .scroll,
        .key_down,
        .key_up,
        .text_input,
        .ime_set_composition,
        .ime_commit_composition,
        .ime_cancel_composition,
        .pinch_begin,
        .pinch_change,
        .pinch_end,
        => true,
    };
}

pub fn canvasWidgetKeyboardEventFromGpuInput(input_event: GpuSurfaceInputEvent, focused_id: canvas.ObjectId) ?canvas.WidgetKeyboardEvent {
    const phase: canvas.WidgetKeyboardPhase = switch (input_event.kind) {
        .key_down => .key_down,
        .key_up => .key_up,
        .pointer_down,
        .pointer_up,
        .pointer_cancel,
        .pointer_move,
        .pointer_drag,
        .scroll,
        .text_input,
        .ime_set_composition,
        .ime_commit_composition,
        .ime_cancel_composition,
        .pinch_begin,
        .pinch_change,
        .pinch_end,
        => return null,
    };
    return .{
        .phase = phase,
        .focused_id = focused_id,
        .key = input_event.key,
        .text = input_event.text,
        .modifiers = canvasWidgetKeyboardModifiers(input_event.modifiers),
    };
}

pub fn canvasWidgetTextInputEventFromGpuInput(input_event: GpuSurfaceInputEvent, focused_id: canvas.ObjectId) ?canvas.WidgetKeyboardEvent {
    const edit = canvasWidgetTextEditEventFromGpuInput(input_event) orelse return null;
    return .{
        .phase = .text_input,
        .focused_id = focused_id,
        .key = input_event.key,
        .text = input_event.text,
        .edit = edit,
        .modifiers = canvasWidgetKeyboardModifiers(input_event.modifiers),
    };
}

fn canvasWidgetTextEditEventFromGpuInput(input_event: GpuSurfaceInputEvent) ?canvas.TextInputEvent {
    return switch (input_event.kind) {
        .key_down => blk: {
            if (input_event.text.len == 0 or gpuInputHasTextCommandModifier(input_event)) break :blk null;
            break :blk .{ .insert_text = input_event.text };
        },
        .text_input => if (input_event.text.len > 0 and !gpuInputHasTextCommandModifier(input_event)) .{ .insert_text = input_event.text } else null,
        .ime_set_composition => .{ .set_composition = .{ .text = input_event.text, .cursor = input_event.composition_cursor } },
        .ime_commit_composition => .commit_composition,
        .ime_cancel_composition => .cancel_composition,
        .key_up,
        .pointer_down,
        .pointer_up,
        .pointer_cancel,
        .pointer_move,
        .pointer_drag,
        .scroll,
        .pinch_begin,
        .pinch_change,
        .pinch_end,
        => null,
    };
}

pub fn canvasWidgetEscapeKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "escape") or std.ascii.eqlIgnoreCase(key, "esc");
}

fn gpuInputHasTextCommandModifier(input_event: GpuSurfaceInputEvent) bool {
    return input_event.modifiers.primary or input_event.modifiers.command or input_event.modifiers.control;
}

pub fn canvasWidgetKeyboardModifiers(modifiers: platform.ShortcutModifiers) canvas.WidgetKeyboardModifiers {
    return .{
        .shift = modifiers.shift,
        .control = modifiers.control,
        .alt = modifiers.option,
        .super = modifiers.command or modifiers.primary,
    };
}

pub fn mergeCanvasRenderOverrides(
    scheduled: []const canvas.CanvasRenderOverride,
    explicit: []const canvas.CanvasRenderOverride,
    output: []canvas.CanvasRenderOverride,
) ![]const canvas.CanvasRenderOverride {
    var len: usize = 0;
    for (scheduled) |override| {
        if (len >= output.len) return error.RenderOverrideListFull;
        output[len] = override;
        len += 1;
    }
    for (explicit) |override| {
        if (findCanvasRenderOverrideIndex(output[0..len], override.id)) |index| {
            output[index] = override;
            continue;
        }
        if (len >= output.len) return error.RenderOverrideListFull;
        output[len] = override;
        len += 1;
    }
    return output[0..len];
}

pub fn findCanvasRenderOverrideIndex(overrides: []const canvas.CanvasRenderOverride, id: canvas.ObjectId) ?usize {
    for (overrides, 0..) |override, index| {
        if (override.id == id) return index;
    }
    return null;
}

pub fn canvasRenderOverrideNoop(override: canvas.CanvasRenderOverride) bool {
    return canvasRenderOverrideOpacityNoop(override.opacity) and canvasRenderOverrideTransformNoop(override.transform);
}

pub fn canvasRenderAnimationFinalOverrideNoop(animation: canvas.CanvasRenderAnimation) bool {
    return canvasRenderOverrideOpacityNoop(animation.to_opacity) and canvasRenderOverrideTransformNoop(animation.to_transform);
}

fn canvasRenderOverrideOpacityNoop(opacity: ?f32) bool {
    return opacity == null or opacity.? == 1;
}

fn canvasRenderOverrideTransformNoop(transform: ?canvas.Affine) bool {
    return transform == null or canvasAffinesEqual(transform.?, canvas.Affine.identity());
}

fn canvasAffinesEqual(a: canvas.Affine, b: canvas.Affine) bool {
    return a.a == b.a and
        a.b == b.b and
        a.c == b.c and
        a.d == b.d and
        a.tx == b.tx and
        a.ty == b.ty;
}

pub fn canvasRenderAnimationActive(animation: canvas.CanvasRenderAnimation, timestamp_ns: u64) bool {
    if (animation.id == 0 or animation.duration_ms == 0) return false;
    // Looping animations (caret blink, spinner rotation) never complete:
    // they stay active until explicitly removed, so frame scheduling
    // keeps sampling them.
    if (animation.loop != .none) return true;
    if (timestamp_ns <= animation.start_ns) return true;
    const duration_ns = @as(u64, animation.duration_ms) * 1_000_000;
    return timestamp_ns - animation.start_ns < duration_ns;
}

pub fn platformCanvasFrameProfileRisk(risk: canvas.CanvasFrameProfileRisk) platform.CanvasFrameProfileRisk {
    return switch (risk) {
        .idle => .idle,
        .low => .low,
        .moderate => .moderate,
        .high => .high,
    };
}

pub fn gpuSurfaceFrameEventFromGpuFrame(frame: platform.GpuFrame) platform.GpuSurfaceFrameEvent {
    return .{
        .window_id = frame.window_id,
        .label = frame.label,
        .size = frame.size,
        .scale_factor = frame.scale_factor,
        .frame_index = frame.frame_index,
        .timestamp_ns = frame.timestamp_ns,
        .frame_interval_ns = frame.frame_interval_ns,
        .input_timestamp_ns = frame.input_timestamp_ns,
        .input_latency_ns = frame.input_latency_ns,
        .input_latency_budget_ns = frame.input_latency_budget_ns,
        .input_latency_budget_exceeded_count = frame.input_latency_budget_exceeded_count,
        .input_latency_budget_ok = frame.input_latency_budget_ok,
        .first_frame_latency_ns = frame.first_frame_latency_ns,
        .first_frame_latency_budget_ns = frame.first_frame_latency_budget_ns,
        .first_frame_latency_budget_exceeded_count = frame.first_frame_latency_budget_exceeded_count,
        .first_frame_latency_budget_ok = frame.first_frame_latency_budget_ok,
        .nonblank = frame.nonblank,
        .sample_color = frame.sample_color,
        .backend = frame.backend,
        .pixel_format = frame.pixel_format,
        .present_mode = frame.present_mode,
        .alpha_mode = frame.alpha_mode,
        .color_space = frame.color_space,
        .vsync = frame.vsync,
        .status = frame.status,
        .canvas_revision = frame.canvas_revision,
        .canvas_command_count = frame.canvas_command_count,
        .canvas_frame_requires_render = frame.canvas_frame_requires_render,
        .canvas_frame_full_repaint = frame.canvas_frame_full_repaint,
        .canvas_frame_batch_count = frame.canvas_frame_batch_count,
        .canvas_frame_encoder_command_count = frame.canvas_frame_encoder_command_count,
        .canvas_frame_encoder_cache_action_count = frame.canvas_frame_encoder_cache_action_count,
        .canvas_frame_encoder_bind_pipeline_count = frame.canvas_frame_encoder_bind_pipeline_count,
        .canvas_frame_encoder_draw_batch_count = frame.canvas_frame_encoder_draw_batch_count,
        .canvas_frame_pipeline_count = frame.canvas_frame_pipeline_count,
        .canvas_frame_pipeline_upload_count = frame.canvas_frame_pipeline_upload_count,
        .canvas_frame_pipeline_retain_count = frame.canvas_frame_pipeline_retain_count,
        .canvas_frame_pipeline_evict_count = frame.canvas_frame_pipeline_evict_count,
        .canvas_frame_path_geometry_count = frame.canvas_frame_path_geometry_count,
        .canvas_frame_path_geometry_vertex_count = frame.canvas_frame_path_geometry_vertex_count,
        .canvas_frame_path_geometry_index_count = frame.canvas_frame_path_geometry_index_count,
        .canvas_frame_path_geometry_upload_count = frame.canvas_frame_path_geometry_upload_count,
        .canvas_frame_path_geometry_retain_count = frame.canvas_frame_path_geometry_retain_count,
        .canvas_frame_path_geometry_evict_count = frame.canvas_frame_path_geometry_evict_count,
        .canvas_frame_image_count = frame.canvas_frame_image_count,
        .canvas_frame_image_upload_count = frame.canvas_frame_image_upload_count,
        .canvas_frame_image_retain_count = frame.canvas_frame_image_retain_count,
        .canvas_frame_image_evict_count = frame.canvas_frame_image_evict_count,
        .canvas_frame_layer_count = frame.canvas_frame_layer_count,
        .canvas_frame_layer_opacity_count = frame.canvas_frame_layer_opacity_count,
        .canvas_frame_layer_clip_count = frame.canvas_frame_layer_clip_count,
        .canvas_frame_layer_transform_count = frame.canvas_frame_layer_transform_count,
        .canvas_frame_layer_upload_count = frame.canvas_frame_layer_upload_count,
        .canvas_frame_layer_retain_count = frame.canvas_frame_layer_retain_count,
        .canvas_frame_layer_evict_count = frame.canvas_frame_layer_evict_count,
        .canvas_frame_resource_count = frame.canvas_frame_resource_count,
        .canvas_frame_resource_upload_count = frame.canvas_frame_resource_upload_count,
        .canvas_frame_resource_retain_count = frame.canvas_frame_resource_retain_count,
        .canvas_frame_resource_evict_count = frame.canvas_frame_resource_evict_count,
        .canvas_frame_visual_effect_count = frame.canvas_frame_visual_effect_count,
        .canvas_frame_visual_effect_shadow_count = frame.canvas_frame_visual_effect_shadow_count,
        .canvas_frame_visual_effect_blur_count = frame.canvas_frame_visual_effect_blur_count,
        .canvas_frame_visual_effect_upload_count = frame.canvas_frame_visual_effect_upload_count,
        .canvas_frame_visual_effect_retain_count = frame.canvas_frame_visual_effect_retain_count,
        .canvas_frame_visual_effect_evict_count = frame.canvas_frame_visual_effect_evict_count,
        .canvas_frame_glyph_atlas_entry_count = frame.canvas_frame_glyph_atlas_entry_count,
        .canvas_frame_glyph_atlas_upload_count = frame.canvas_frame_glyph_atlas_upload_count,
        .canvas_frame_glyph_atlas_retain_count = frame.canvas_frame_glyph_atlas_retain_count,
        .canvas_frame_glyph_atlas_evict_count = frame.canvas_frame_glyph_atlas_evict_count,
        .canvas_frame_text_layout_count = frame.canvas_frame_text_layout_count,
        .canvas_frame_text_layout_line_count = frame.canvas_frame_text_layout_line_count,
        .canvas_frame_text_layout_upload_count = frame.canvas_frame_text_layout_upload_count,
        .canvas_frame_text_layout_retain_count = frame.canvas_frame_text_layout_retain_count,
        .canvas_frame_text_layout_evict_count = frame.canvas_frame_text_layout_evict_count,
        .canvas_frame_gpu_packet_command_count = frame.canvas_frame_gpu_packet_command_count,
        .canvas_frame_gpu_packet_cache_action_count = frame.canvas_frame_gpu_packet_cache_action_count,
        .canvas_frame_gpu_packet_cached_resource_command_count = frame.canvas_frame_gpu_packet_cached_resource_command_count,
        .canvas_frame_gpu_packet_unsupported_command_count = frame.canvas_frame_gpu_packet_unsupported_command_count,
        .canvas_frame_gpu_packet_representable = frame.canvas_frame_gpu_packet_representable,
        .canvas_frame_change_count = frame.canvas_frame_change_count,
        .canvas_frame_budget_exceeded_count = frame.canvas_frame_budget_exceeded_count,
        .canvas_frame_budget_ok = frame.canvas_frame_budget_ok,
        .canvas_frame_dirty_bounds = frame.canvas_frame_dirty_bounds,
        .canvas_frame_profile_work_units = frame.canvas_frame_profile_work_units,
        .canvas_frame_profile_risk = frame.canvas_frame_profile_risk,
        .canvas_frame_profile_surface_area = frame.canvas_frame_profile_surface_area,
        .canvas_frame_profile_dirty_area = frame.canvas_frame_profile_dirty_area,
        .canvas_frame_profile_dirty_ratio = frame.canvas_frame_profile_dirty_ratio,
        .widget_revision = frame.widget_revision,
        .widget_node_count = frame.widget_node_count,
        .widget_semantics_count = frame.widget_semantics_count,
    };
}
