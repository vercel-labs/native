const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const event_model = @import("events.zig");
const widget_layout = @import("widget_layout.zig");
const widget_metrics = @import("widget_metrics.zig");
const widget_render_style = @import("widget_render_style.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const Builder = canvas.Builder;
const Radius = drawing_model.Radius;
const DesignTokens = token_model.DesignTokens;
const Widget = widget_model.Widget;
const WidgetScrollMetrics = event_model.WidgetScrollMetrics;

const colorFill = widget_render_style.colorFill;
const colorWithAlpha = widget_render_style.colorWithAlpha;
const densityValue = widget_metrics.densityValue;

pub const ScrollbarGeometry = struct {
    track: geometry.RectF,
    thumb: geometry.RectF,
};

/// Emit the engine scrollbars for one scroll region: the vertical bar
/// on the right edge (part slots 2/3, exactly as before) and the
/// horizontal bar along the bottom edge (part slots 4/5), each drawn
/// only when its axis has scrollable range. When BOTH are visible each
/// track ends short of the shared corner by the other bar's thickness
/// plus the inset — the standard scroller corner gap, so the thumbs
/// never overlap.
pub fn emitScrollViewScrollbars(builder: *Builder, frame: geometry.RectF, vertical: WidgetScrollMetrics, horizontal: WidgetScrollMetrics, tokens: DesignTokens, id: ObjectId) Error!void {
    const corner = scrollbarCornerReserve(frame, vertical, horizontal, tokens);
    try emitScrollViewScrollbarAxis(builder, frame, vertical, tokens, id, .vertical, corner, 2);
    try emitScrollViewScrollbarAxis(builder, frame, horizontal, tokens, id, .horizontal, corner, 4);
}

/// The corner gap each track reserves when both bars are visible: the
/// bar thickness plus the edge inset, 0 when either bar is absent.
fn scrollbarCornerReserve(frame: geometry.RectF, vertical: WidgetScrollMetrics, horizontal: WidgetScrollMetrics, tokens: DesignTokens) f32 {
    if (!scrollbarAxisVisible(vertical) or !scrollbarAxisVisible(horizontal)) return 0;
    const inset = densityValue(tokens, 3);
    return scrollbarThickness(frame, tokens) + inset;
}

fn scrollbarAxisVisible(metrics: WidgetScrollMetrics) bool {
    const viewport = nonNegative(metrics.viewport_extent);
    const content = nonNegative(metrics.content_extent);
    return metrics.present and viewport > 0 and content > viewport;
}

/// One thickness for both bars, derived from the region's smaller
/// dimension so a wide flat shelf and a tall narrow list wear the same
/// visual weight.
fn scrollbarThickness(frame: geometry.RectF, tokens: DesignTokens) f32 {
    const reference = @min(frame.width, frame.height);
    return @min(@max(densityValue(tokens, 3), reference * 0.0125), densityValue(tokens, 6));
}

fn emitScrollViewScrollbarAxis(builder: *Builder, frame: geometry.RectF, metrics: WidgetScrollMetrics, tokens: DesignTokens, id: ObjectId, axis: token_model.ScrollAxis, reserved_end: f32, track_slot: ObjectId) Error!void {
    const scrollbar = scrollViewScrollbarGeometryForAxis(frame, metrics, tokens, axis, reserved_end) orelse return;
    const track = pixelSnapGeometryRect(tokens, scrollbar.track);
    const thumb = pixelSnapGeometryRect(tokens, scrollbar.thumb);
    const visual = tokens.controls.scrollbar;
    const bar_thickness = if (axis == .vertical) track.width else track.height;
    const radius = Radius.all(if (visual.radius) |value| nonNegative(value) else bar_thickness * 0.5);
    const track_fill = visual.background orelse colorWithAlpha(tokens.colors.border, @min(tokens.colors.border.a, 0.22));
    const thumb_fill = visual.foreground orelse visual.active_background orelse colorWithAlpha(tokens.colors.text_muted, 0.55);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(id, track_slot),
        .rect = track,
        .radius = radius,
        .fill = colorFill(track_fill),
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(id, track_slot + 1),
        .rect = thumb,
        .radius = radius,
        .fill = colorFill(thumb_fill),
    });
}

pub fn scrollViewScrollbarGeometry(frame: geometry.RectF, metrics: WidgetScrollMetrics, tokens: DesignTokens) ?ScrollbarGeometry {
    return scrollViewScrollbarGeometryForAxis(frame, metrics, tokens, .vertical, 0);
}

pub fn scrollViewScrollbarGeometryForAxis(frame: geometry.RectF, metrics: WidgetScrollMetrics, tokens: DesignTokens, axis: token_model.ScrollAxis, reserved_end: f32) ?ScrollbarGeometry {
    if (!metrics.present) return null;
    const viewport = nonNegative(metrics.viewport_extent);
    const content = nonNegative(metrics.content_extent);
    const max_offset = @max(0, content - viewport);
    if (frame.isEmpty() or viewport <= 0 or content <= viewport or max_offset <= 0) return null;

    const inset = densityValue(tokens, 3);
    const thickness = scrollbarThickness(frame, tokens);
    const track_extent = @max(0, (if (axis == .vertical) frame.height else frame.width) - inset * 2 - nonNegative(reserved_end));
    if (track_extent <= 0 or thickness <= 0) return null;

    const track = switch (axis) {
        .vertical => geometry.RectF.init(
            frame.x + frame.width - inset - thickness,
            frame.y + inset,
            thickness,
            track_extent,
        ),
        .horizontal => geometry.RectF.init(
            frame.x + inset,
            frame.y + frame.height - inset - thickness,
            track_extent,
            thickness,
        ),
    };
    const thumb_ratio = std.math.clamp(viewport / content, 0, 1);
    const min_thumb = @min(track_extent, densityValue(tokens, 18));
    const thumb_extent = @min(track_extent, @max(min_thumb, track_extent * thumb_ratio));
    const travel = @max(0, track_extent - thumb_extent);
    const offset_ratio = std.math.clamp(nonNegative(metrics.offset) / max_offset, 0, 1);
    return .{
        .track = track,
        .thumb = switch (axis) {
            .vertical => geometry.RectF.init(track.x, track.y + travel * offset_ratio, track.width, thumb_extent),
            .horizontal => geometry.RectF.init(track.x + travel * offset_ratio, track.y, thumb_extent, track.height),
        },
    };
}

pub fn widgetScrollMetricsForWidget(widget: Widget, tokens: DesignTokens) WidgetScrollMetrics {
    return widgetScrollAxisMetricsForWidget(widget, tokens, .vertical);
}

/// Per-axis metrics for a WIDGET-walk scroll view (static trees, docs
/// scenes — children carry their own frames). `present = false` on an
/// axis the region does not grant, mirroring the layout-walk metrics.
pub fn widgetScrollAxisMetricsForWidget(widget: Widget, tokens: DesignTokens, axis: token_model.ScrollAxis) WidgetScrollMetrics {
    if (widget.kind != .scroll_view) return .{};

    const viewport = widget.frame.inset(widget.layout.padding).normalized();
    if (viewport.isEmpty()) return .{};

    switch (axis) {
        .vertical => {
            if (!widget.layout.virtualized and !widget.scroll_axes.scrollsVertically()) return .{};
            const content_extent = widgetScrollContentExtentForWidget(widget, viewport, tokens);
            const max_offset = @max(0, content_extent - viewport.height);
            return .{
                .present = true,
                .offset = std.math.clamp(nonNegative(widget.value), 0, max_offset),
                .viewport_extent = viewport.height,
                .content_extent = content_extent,
            };
        },
        .horizontal => {
            if (widget.layout.virtualized or !widget.scroll_axes.scrollsHorizontally()) return .{};
            const offset = widget.value_x;
            var right = viewport.maxX();
            for (widget.children) |child| {
                right = @max(right, child.frame.maxX() + offset);
            }
            const content_extent = @max(0, right - viewport.x);
            const max_offset = @max(0, content_extent - viewport.width);
            return .{
                .present = true,
                .offset = std.math.clamp(nonNegative(widget.value_x), 0, max_offset),
                .viewport_extent = viewport.width,
                .content_extent = content_extent,
            };
        },
    }
}

fn widgetScrollContentExtentForWidget(widget: Widget, viewport: geometry.RectF, tokens: DesignTokens) f32 {
    if (widget.layout.virtualized) {
        return @max(viewport.height, widget_layout.virtualWidgetScrollContentExtentWithTokens(widget, viewport.height, tokens));
    }

    const offset = widget.value;
    var bottom = viewport.maxY();
    for (widget.children) |child| {
        bottom = @max(bottom, child.frame.maxY() + offset);
    }
    return @max(0, bottom - viewport.y);
}

fn pixelSnapGeometryRect(tokens: DesignTokens, rect: geometry.RectF) geometry.RectF {
    const scale = pixelSnapScale(tokens) orelse return rect;
    return geometry.RectF.init(
        pixelSnapValueWithScale(rect.x, scale),
        pixelSnapValueWithScale(rect.y, scale),
        pixelSnapValueWithScale(rect.width, scale),
        pixelSnapValueWithScale(rect.height, scale),
    );
}

fn pixelSnapScale(tokens: DesignTokens) ?f32 {
    if (!tokens.pixel_snap.geometry) return null;
    const scale = tokens.pixel_snap.scale;
    if (!std.math.isFinite(scale) or scale <= 0) return null;
    return scale;
}

fn pixelSnapValueWithScale(value: f32, scale: f32) f32 {
    return @round(value * scale) / scale;
}

fn widgetPartId(id: ObjectId, slot: ObjectId) ObjectId {
    return widget_model.widgetCommandPartId(.{ .widget_id = id, .slot = slot });
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
