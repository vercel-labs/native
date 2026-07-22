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

/// Snap an incremental dirty rect OUTWARD to the device-pixel grid at
/// `scale`, folding in `bleed_pixels` whole device pixels of
/// anti-aliasing bleed allowance on every side. The allowance covers
/// the PAINTED extent of changed content — host rasterizers ink up to
/// a device pixel past a command's bounds (antialiased shape edges and
/// glyph overshoot; the packet host's raster cache carries a one-pixel
/// apron for exactly this) — so content that shrinks, moves, or
/// disappears cannot strand a stale fringe. The snap keeps the CULL
/// region identical to the CLEARED pixels: clears land on whole pixels
/// while culling tests the float rect, so a fractional dirty edge would
/// erase the boundary pixel's antialiased coverage without redrawing
/// the unchanged neighbor that painted it.
///
/// Which pixels are cleared is decided on INTEGER device boundaries
/// (floor/ceil of the input edges, moved by whole `bleed_pixels` —
/// never by a rounded `1/scale` in logical points, which can fall a
/// whole pixel short at fractional scales). The logical edges are then
/// chosen so the STORED rect (x, y, width, height in f32) hands
/// consumers back products that land exactly on those boundaries: the
/// min edges are the smallest representable values whose product
/// reaches their boundary, and the spans the largest whose
/// RECONSTRUCTED max edge (`x + width`, the f32 a stored rect yields)
/// stays on theirs — so consumers re-deriving pixels clear exactly the
/// pixels command culling admits, in both directions.
pub fn bleedAlignedCanvasDirtyBounds(bounds: ?geometry.RectF, scale: f32, bleed_pixels: f32) ?geometry.RectF {
    const dirty = bounds orelse return null;
    const normalized = dirty.normalized();
    const device = if (std.math.isFinite(scale) and scale > 0) scale else 1;
    const x_edges = canvasDirtyAxisEdges(@floor(normalized.minX() * device) - bleed_pixels, @ceil(normalized.maxX() * device) + bleed_pixels, device);
    const y_edges = canvasDirtyAxisEdges(@floor(normalized.minY() * device) - bleed_pixels, @ceil(normalized.maxY() * device) + bleed_pixels, device);
    return geometry.RectF.init(x_edges.min, y_edges.min, x_edges.span, y_edges.span);
}

const CanvasDirtyAxisEdges = struct { min: f32, span: f32 };

/// Logical edges for one axis of the bleed-aligned damage. Boundaries
/// within f32's exact-integer range (2^24 — presentable surfaces reach
/// at most `max_canvas_surface_extent_pixels`, far below it) take the
/// exact edge walks; anything beyond (a far off-screen change, an
/// overflowed product) keeps a finite, NON-COLLAPSED superset instead:
/// no host can ever clear a pixel out there, so cull/clear exactness is
/// moot, but the damage must survive as a repaint region for callers
/// with no clipping surface, and the walks must not start from
/// infinity (they would never terminate).
fn canvasDirtyAxisEdges(min_boundary: f32, max_boundary: f32, device: f32) CanvasDirtyAxisEdges {
    const walk_limit: f32 = 16_777_216;
    const walkable = min_boundary >= -walk_limit and min_boundary <= walk_limit and
        max_boundary >= -walk_limit and max_boundary <= walk_limit;
    if (!walkable) {
        const min_edge = nudgedFiniteCanvasDirtyEdge(min_boundary / device, -2);
        const max_edge = nudgedFiniteCanvasDirtyEdge(max_boundary / device, 2);
        return .{ .min = min_edge, .span = @max(0, nudgedFiniteCanvasDirtyEdge(max_edge - min_edge, 2)) };
    }
    const min_edge = canvasDirtyEdgeForFloorBoundary(min_boundary, device);
    return .{ .min = min_edge, .span = canvasDirtySpanForCeilBoundary(min_edge, max_boundary, device) };
}

/// Finite value for the superset fallback: NaN degenerates to zero,
/// infinities clamp inside f32's range, and `ulps` outward steps absorb
/// the division/subtraction rounding so the fallback stays a superset.
fn nudgedFiniteCanvasDirtyEdge(value: f32, ulps: i8) f32 {
    var result = value;
    if (std.math.isNan(result)) return 0;
    result = std.math.clamp(result, -3.0e37, 3.0e37);
    var remaining: i8 = if (ulps < 0) -ulps else ulps;
    const toward: f32 = if (ulps < 0) -std.math.inf(f32) else std.math.inf(f32);
    while (remaining > 0) : (remaining -= 1) result = std.math.nextAfter(f32, result, toward);
    return result;
}

/// Smallest representable logical coordinate whose product with
/// `device` reaches `boundary`. Consumers floor the product to pick the
/// first cleared pixel — a product below the boundary clears one extra
/// pixel culling excludes — and culling must admit every command
/// painting into the cleared region, which the MINIMAL such edge
/// guarantees: anything smaller has a product below the boundary and
/// paints only uncleared pixels. Products are judged in f64, which is
/// EXACT for f32 operands: retained hosts recompute the wire rect in
/// double precision, so an edge whose f32 product merely rounds onto
/// the boundary while its exact product sits past it would still clear
/// an extra pixel host-side. Exactness in f64 implies the f32 result
/// too (the boundary is representable in both).
fn canvasDirtyEdgeForFloorBoundary(boundary: f32, device: f32) f32 {
    const b: f64 = boundary;
    const d: f64 = device;
    var edge = boundary / device;
    while (@as(f64, edge) * d >= b) edge = std.math.nextAfter(f32, edge, -std.math.inf(f32));
    while (@as(f64, edge) * d < b) edge = std.math.nextAfter(f32, edge, std.math.inf(f32));
    return edge;
}

/// Largest span whose RECONSTRUCTED max edge (`min_edge + span`, the
/// f32 a stored rect hands back) keeps its product with `device` at or
/// under `boundary` — judged in f64 like the floor edge, since retained
/// hosts reconstruct `x + width` and scale it in double precision.
/// Consumers ceil that product to pick the last cleared pixel — one ulp
/// past the maximum clears a pixel culling refuses to repaint — and the
/// maximal such span admits every command painting into the cleared
/// region: anything larger has a product past the boundary. The walk
/// steps the EDGE value, never the span: an edge's ulp is proportional
/// to its magnitude so the walk is a few steps, while span steps can
/// crawl through denormals without moving the sum when the min edge
/// dominates it.
fn canvasDirtySpanForCeilBoundary(min_edge: f32, boundary: f32, device: f32) f32 {
    const b: f64 = boundary;
    const d: f64 = device;
    var target = boundary / device;
    while (@as(f64, target) * d <= b) target = std.math.nextAfter(f32, target, std.math.inf(f32));
    while (@as(f64, target) * d > b) target = std.math.nextAfter(f32, target, -std.math.inf(f32));
    if (target <= min_edge) return 0;
    // Re-encode as the stored span; shrink while the exact
    // reconstruction overshoots the target, giving up the sub-ulp
    // sliver when a step no longer moves the sum.
    var span = target - min_edge;
    while (span > 0 and @as(f64, min_edge) + @as(f64, span) > @as(f64, target)) {
        const next = std.math.nextAfter(f32, span, -std.math.inf(f32));
        if (next == span) return 0;
        span = next;
    }
    return @max(0, span);
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
