//! Native scroll drivers: per-scrollable-region invisible OS
//! scrollers (macOS `NSScrollView`) own scroll input and physics —
//! momentum, overlay scrollbars, and rubber-band for regions that opt
//! into it — while the engine keeps rendering the content. The runtime:
//!
//! - stamps `widget.native_scroll` on every non-virtualized `.scroll_view`
//!   (and every RUNTIME-SCROLLED virtual list — a virtualized scroll_view
//!   with a declared item count, whose driver content size is the full
//!   virtual extent) so engine scrollbars and engine kinetic physics
//!   stand down,
//! - pushes the full desired driver set (region frames, content extents,
//!   offsets) on every widget-layout install AND every presented frame —
//!   the self-healing reconcile lesson: anything owning host
//!   view state must reconcile against live truth per frame,
//! - applies driver-reported offsets through the same retained scroll
//!   path wheel input uses, so `widget.value` stays the single offset of
//!   record and the existing "runtime offset wins until the source
//!   changes" rebuild reconciliation keeps working unchanged.
//!
//! `set_offset` is only forced when the runtime's offset diverged from
//! the last driver-reported offset (keyboard scroll, automation wheel,
//! source-side programmatic scroll, clamp after content shrink): pushing
//! unconditionally would snap the OS scroller back mid-gesture.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");
const runtime_api = @import("api.zig");
const runtime_canvas_widget_display = @import("canvas_widget_display.zig");
const runtime_canvas_widget_events = @import("canvas_widget_events.zig");
const runtime_gpu_surface_events = @import("gpu_surface_events.zig");

const scroll_driver_log = std.log.scoped(.zero_scroll_drivers);

/// Offsets within half a point are the same offset (echo suppression).
pub const scroll_driver_offset_epsilon: f32 = 0.5;

pub fn RuntimeCanvasWidgetScrollDrivers(comptime Runtime: type) type {
    return struct {
        pub fn canvasWidgetScrollDriversSupported(self: *const Runtime) bool {
            return self.options.platform.services.set_gpu_surface_scroll_drivers_fn != null and
                self.options.platform.supports(.gpu_surface_scroll_drivers);
        }

        /// Mark every runtime-scrollable region as natively driven so the
        /// engine's drawn scrollbar and kinetic stepper stand down. Runs
        /// on the reconciled nodes before they are copied into the view,
        /// so rebuild-time clamping sees the flag too.
        pub fn stampCanvasWidgetNativeScroll(self: *const Runtime, nodes: []canvas.WidgetLayoutNode) void {
            if (!canvasWidgetScrollDriversSupported(self)) return;
            for (nodes) |*node| {
                if (canvasWidgetScrollDriverEligible(node.*)) node.widget.native_scroll = true;
            }
        }

        /// Push the full desired driver set for a view to the platform:
        /// one driver per eligible scroll region with its frame, content
        /// extent, and offset. Idempotent — called from
        /// `setCanvasWidgetLayout` and from every presented frame.
        pub fn syncCanvasWidgetScrollDriversForView(self: *Runtime, view_index: usize) void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface or !self.views[view_index].open) return;
            if (!canvasWidgetScrollDriversSupported(self)) return;
            const view = &self.views[view_index];

            var drivers: [platform.max_gpu_surface_scroll_drivers]platform.GpuSurfaceScrollDriver = undefined;
            var ids: [platform.max_gpu_surface_scroll_drivers]u64 = undefined;
            var offsets: [platform.max_gpu_surface_scroll_drivers]f32 = undefined;
            var count: usize = 0;
            for (view.widget_layout_nodes[0..view.widget_layout_node_count], 0..) |*node, node_index| {
                if (!canvasWidgetScrollDriverEligible(node.*)) continue;
                node.widget.native_scroll = true;
                if (count >= drivers.len) continue;

                const viewport = node.frame.inset(node.widget.layout.padding).normalized();
                if (viewport.isEmpty()) continue;
                const frame = node.frame.normalized();
                const content_extent = view.canvasWidgetScrollContentExtent(node_index, viewport);
                // Content extent is viewport-relative; rebase it onto the
                // full region frame so the native max offset
                // (content_height - frame.height) matches the engine's
                // (content_extent - viewport.height).
                const content_height = frame.height + @max(0, content_extent - viewport.height);
                const offset = node.widget.value;
                const tracked = trackedScrollDriverOffset(view, node.widget.id);
                const push = tracked == null or @abs(tracked.? - offset) > scroll_driver_offset_epsilon;

                drivers[count] = .{
                    .id = node.widget.id,
                    .frame = frame,
                    .content_size = .{ .width = frame.width, .height = content_height },
                    .offset_y = offset,
                    .set_offset = push,
                    // Per-region edge behavior, resolved the same way the
                    // engine physics resolve it (region override onto the
                    // scroll-physics token): off pins the OS scroller at
                    // the content edges, on lets it bounce.
                    .rubber_band = canvas.widgetScrollPhysics(node.widget, view.widget_tokens.scroll).overscroll == .rubber_band,
                };
                ids[count] = node.widget.id;
                offsets[count] = offset;
                count += 1;
            }

            self.options.platform.services.setGpuSurfaceScrollDrivers(view.window_id, view.label, drivers[0..count]) catch |err| {
                if (err != error.UnsupportedService) {
                    scroll_driver_log.warn("scroll driver sync failed for view '{s}': {s}", .{ view.label, @errorName(err) });
                }
                return;
            };
            @memcpy(view.scroll_driver_ids[0..count], ids[0..count]);
            @memcpy(view.scroll_driver_offsets[0..count], offsets[0..count]);
            view.scroll_driver_count = count;
        }

        /// A native driver reported a new content offset: apply it through
        /// the retained scroll path (translate descendants, refresh
        /// semantics, invalidate, refresh the display list) — the same
        /// motions wheel input performs, minus engine physics.
        pub fn dispatchGpuSurfaceScrollDriver(self: *Runtime, app: runtime_api.App(Runtime), event: platform.GpuSurfaceScrollDriverEvent) anyerror!void {
            const index = runtimeFindViewIndex(self, event.window_id, event.label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;
            self.views[index].recordGpuSurfaceInputTimestamp(event.timestamp_ns);
            recordScrollDriverOffset(&self.views[index], event.driver_id, event.offset_y);

            const node_index = self.views[index].canvasWidgetNodeIndexById(event.driver_id) orelse return;
            const dirty = try self.views[index].applyCanvasWidgetScrollDriverOffset(node_index, event.offset_y) orelse return;

            const previous_cursor = self.views[index].canvas_widget_cursor;
            self.views[index].reconcileCanvasWidgetRenderStateAfterScroll(null);
            if (previous_cursor != self.views[index].canvas_widget_cursor) {
                try CanvasWidgetEventMethods().syncCanvasWidgetCursorForView(self, index);
            }
            if (canvasDirtyRegionForView(self.views[index].frame, dirty)) |dirty_region| {
                self.invalidateFor(.state, dirty_region);
            } else {
                self.invalidateFor(.state, self.views[index].frame);
            }
            _ = try CanvasWidgetDisplayMethods().refreshCanvasWidgetDisplayListIfOwnedSkippingAccessibility(self, index);
            // Driver offsets are user-driven scrolls: deliver the pending
            // `canvas_widget_scroll` observation so `on_scroll` fires the
            // same way it does for engine wheel and kinetic motion.
            try runtime_gpu_surface_events.RuntimeGpuSurfaceEvents(Runtime).dispatchPendingCanvasWidgetScrollEvents(self, app, index);
        }

        fn CanvasWidgetDisplayMethods() type {
            return runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime);
        }

        fn CanvasWidgetEventMethods() type {
            return runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(Runtime);
        }
    };
}

pub fn canvasWidgetScrollDriverEligible(node: canvas.WidgetLayoutNode) bool {
    if (node.widget.kind != .scroll_view or node.widget.id == 0) return false;
    // Runtime-scrolled virtual lists (declared item count) ride the
    // native driver too: their content extent is the VIRTUAL total
    // (`canvasWidgetScrollContentExtent`'s virtualized branch), so the
    // OS scroller's bar spans the whole list while only the built
    // window mounts. Legacy virtualized containers stay model-driven.
    if (node.widget.layout.virtualized) return canvas.widgetVirtualRuntimeScrolled(node.widget);
    return true;
}

fn trackedScrollDriverOffset(view: anytype, driver_id: u64) ?f32 {
    for (view.scroll_driver_ids[0..view.scroll_driver_count], 0..) |id, index| {
        if (id == driver_id) return view.scroll_driver_offsets[index];
    }
    return null;
}

fn recordScrollDriverOffset(view: anytype, driver_id: u64, offset: f32) void {
    for (view.scroll_driver_ids[0..view.scroll_driver_count], 0..) |id, index| {
        if (id != driver_id) continue;
        view.scroll_driver_offsets[index] = offset;
        return;
    }
    if (view.scroll_driver_count >= view.scroll_driver_ids.len) return;
    view.scroll_driver_ids[view.scroll_driver_count] = driver_id;
    view.scroll_driver_offsets[view.scroll_driver_count] = offset;
    view.scroll_driver_count += 1;
}

/// Same clipping + translation as `window_storage.canvasDirtyRegionForView`
/// (a mixin static; duplicated here to avoid instantiating the mixin).
fn canvasDirtyRegionForView(view_frame: geometry.RectF, local_dirty: geometry.RectF) ?geometry.RectF {
    const normalized_view = view_frame.normalized();
    const surface_bounds = geometry.RectF.init(0, 0, normalized_view.width, normalized_view.height);
    const clipped = geometry.RectF.intersection(surface_bounds, local_dirty.normalized());
    if (clipped.isEmpty()) return null;
    return clipped.translate(.{ .dx = normalized_view.x, .dy = normalized_view.y });
}

fn runtimeFindViewIndex(self: anytype, window_id: platform.WindowId, label: []const u8) ?usize {
    for (self.views[0..self.view_count], 0..) |*view, index| {
        if (view.open and view.window_id == window_id and std.mem.eql(u8, view.label, label)) return index;
    }
    return null;
}
