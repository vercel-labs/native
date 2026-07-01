const std = @import("std");
const geometry = @import("geometry");
const platform = @import("../platform/root.zig");
const runtime_api = @import("api.zig");
const canvas_frame_helpers = @import("canvas_frame.zig");
const runtime_canvas_widget_display = @import("canvas_widget_display.zig");
const runtime_canvas_widget_events = @import("canvas_widget_events.zig");

const canvasWidgetInputBatchesDisplayListRefresh = canvas_frame_helpers.canvasWidgetInputBatchesDisplayListRefresh;
const gpuSurfaceFrameEventFromGpuFrame = canvas_frame_helpers.gpuSurfaceFrameEventFromGpuFrame;
const platformCanvasFrameProfileRisk = canvas_frame_helpers.platformCanvasFrameProfileRisk;
const sizesEqual = canvas_frame_helpers.sizesEqual;

pub fn RuntimeGpuSurfaceEvents(comptime Runtime: type) type {
    return struct {
        pub fn dispatchGpuSurfaceFrame(self: *Runtime, app: runtime_api.App(Runtime), frame_event: platform.GpuSurfaceFrameEvent) anyerror!void {
            var enriched_frame_event = frame_event;
            if (runtimeFindViewIndex(self, frame_event.window_id, frame_event.label)) |index| {
                const had_pending_input = self.views[index].gpu_pending_input_timestamp_ns != 0;
                if (!sizesEqual(self.views[index].gpu_size, frame_event.size) or self.views[index].gpu_scale_factor != frame_event.scale_factor) {
                    self.views[index].presented_canvas_valid = false;
                }
                self.views[index].gpu_size = frame_event.size;
                self.views[index].gpu_scale_factor = frame_event.scale_factor;
                self.views[index].gpu_frame_index = frame_event.frame_index;
                self.views[index].gpu_timestamp_ns = frame_event.timestamp_ns;
                self.views[index].recordGpuSurfaceFrameInterval(frame_event.frame_interval_ns);
                self.views[index].recordGpuSurfaceFirstFrameLatency(frame_event.timestamp_ns);
                self.views[index].recordGpuSurfaceInputLatencyForFrame(frame_event.timestamp_ns);
                try CanvasWidgetDisplayMethods().advanceCanvasWidgetKineticScrollForFrame(self, index, frame_event.frame_interval_ns, had_pending_input);
                self.views[index].gpu_frame_nonblank = frame_event.nonblank;
                self.views[index].gpu_sample_color = frame_event.sample_color;
                self.views[index].gpu_backend = frame_event.backend;
                self.views[index].gpu_pixel_format = frame_event.pixel_format;
                self.views[index].gpu_present_mode = frame_event.present_mode;
                self.views[index].gpu_alpha_mode = frame_event.alpha_mode;
                self.views[index].gpu_color_space = frame_event.color_space;
                self.views[index].gpu_vsync = frame_event.vsync;
                self.views[index].gpu_status = frame_event.status;
                if (self.options.gpu_surface_frame_diagnostics) {
                    try enrichGpuSurfaceFrameDiagnostics(self, index, &enriched_frame_event);
                } else if (self.views[index].info().gpuFrame()) |gpu_frame| {
                    enriched_frame_event = gpuSurfaceFrameEventFromGpuFrame(gpu_frame);
                }
            }
            try self.dispatchEvent(app, .{ .gpu_surface_frame = enriched_frame_event });
        }

        pub fn dispatchGpuSurfaceResized(self: *Runtime, app: runtime_api.App(Runtime), resize_event: platform.GpuSurfaceResizeEvent) anyerror!void {
            if (runtimeFindViewIndex(self, resize_event.window_id, resize_event.label)) |index| {
                const previous_frame = self.views[index].frame;
                const previous_size = self.views[index].gpu_size;
                const previous_scale = self.views[index].gpu_scale_factor;
                const next_size = resize_event.frame.size();
                const frame_changed = !rectsEqual(previous_frame, resize_event.frame);
                const surface_changed = !sizesEqual(previous_size, next_size) or previous_scale != resize_event.scale_factor;
                self.views[index].frame = resize_event.frame;
                self.views[index].gpu_size = next_size;
                self.views[index].gpu_scale_factor = resize_event.scale_factor;
                if (surface_changed) self.views[index].presented_canvas_valid = false;
                if (self.views[index].gpu_status == .unavailable) self.views[index].gpu_status = .ready;
                if (frame_changed or surface_changed) self.invalidateFor(.surface_resize, resize_event.frame);
            }
            try self.dispatchEvent(app, .{ .gpu_surface_resized = resize_event });
        }

        pub fn dispatchGpuSurfaceInput(self: *Runtime, app: runtime_api.App(Runtime), input_event: platform.GpuSurfaceInputEvent) anyerror!void {
            var canvas_widget_refresh_batch_active = canvasWidgetInputBatchesDisplayListRefresh(input_event.kind);
            if (canvas_widget_refresh_batch_active) CanvasWidgetDisplayMethods().beginCanvasWidgetDisplayListRefreshBatch(self);
            errdefer {
                if (canvas_widget_refresh_batch_active) CanvasWidgetDisplayMethods().cancelCanvasWidgetDisplayListRefreshBatch(self);
            }

            if (runtimeFindViewIndex(self, input_event.window_id, input_event.label)) |index| {
                self.views[index].recordGpuSurfaceInputTimestamp(input_event.timestamp_ns);
            }
            switch (input_event.kind) {
                .pointer_down,
                .key_down,
                => {
                    try setFocusedView(self, input_event.window_id, input_event.label);
                    self.invalidated = true;
                },
                else => {},
            }
            const widget_pointer_event = CanvasWidgetEventMethods().routeCanvasWidgetPointerInput(self, input_event, &self.widget_event_route_entries) catch |err| switch (err) {
                error.WindowNotFound,
                error.ViewNotFound,
                error.InvalidViewOptions,
                => null,
                else => return err,
            };
            if (widget_pointer_event) |pointer_event| {
                _ = try CanvasWidgetEventMethods().dismissCanvasWidgetSurfaceFromPointerInput(self, pointer_event);
                try CanvasWidgetEventMethods().updateCanvasWidgetControlFromPointer(self, pointer_event);
                try CanvasWidgetEventMethods().updateCanvasWidgetInteractionFromPointer(self, pointer_event);
                try CanvasWidgetEventMethods().updateCanvasWidgetTextFromPointer(self, pointer_event);
                try CanvasWidgetEventMethods().updateCanvasWidgetScrollFromPointer(self, pointer_event);
                try CanvasWidgetEventMethods().updateCanvasWidgetFocusFromPointer(self, pointer_event);
            }
            const widget_drag_event = CanvasWidgetEventMethods().routeCanvasWidgetDragInput(self, input_event, &self.widget_event_route_entries) catch |err| switch (err) {
                error.WindowNotFound,
                error.ViewNotFound,
                error.InvalidViewOptions,
                => null,
                else => return err,
            };
            const widget_surface_dismissed = try CanvasWidgetEventMethods().dismissCanvasWidgetSurfaceFromKeyboardInput(self, input_event);
            if (!widget_surface_dismissed) try CanvasWidgetEventMethods().updateCanvasWidgetFocusFromKeyboardInput(self, input_event);
            const widget_keyboard_event = if (widget_surface_dismissed)
                null
            else
                CanvasWidgetEventMethods().routeCanvasWidgetKeyboardInput(self, input_event, &self.widget_event_route_entries) catch |err| switch (err) {
                    error.WindowNotFound,
                    error.ViewNotFound,
                    error.InvalidViewOptions,
                    => null,
                    else => return err,
                };
            if (widget_keyboard_event) |keyboard_event| {
                try CanvasWidgetEventMethods().updateCanvasWidgetControlFromKeyboard(self, keyboard_event);
                try CanvasWidgetEventMethods().updateCanvasWidgetTextFromKeyboard(self, keyboard_event);
            }
            const widget_text_input_event = if (widget_surface_dismissed)
                null
            else
                CanvasWidgetEventMethods().routeCanvasWidgetTextInput(self, input_event, &self.widget_event_route_entries) catch |err| switch (err) {
                    error.WindowNotFound,
                    error.ViewNotFound,
                    error.InvalidViewOptions,
                    => null,
                    else => return err,
                };
            if (widget_text_input_event) |text_input_event| {
                try CanvasWidgetEventMethods().updateCanvasWidgetTextFromKeyboard(self, text_input_event);
            }
            if (canvas_widget_refresh_batch_active) {
                try CanvasWidgetDisplayMethods().endCanvasWidgetDisplayListRefreshBatch(self);
                canvas_widget_refresh_batch_active = false;
            }
            if (widget_pointer_event) |pointer_event| {
                try CanvasWidgetEventMethods().dispatchCanvasWidgetCommandFromPointer(self, app, pointer_event);
                try self.dispatchEvent(app, .{ .canvas_widget_pointer = pointer_event });
            }
            if (widget_drag_event) |drag_event| {
                try self.dispatchEvent(app, .{ .canvas_widget_drag = drag_event });
            }
            if (widget_keyboard_event) |keyboard_event| {
                try CanvasWidgetEventMethods().dispatchCanvasWidgetCommandFromKeyboard(self, app, keyboard_event);
                try self.dispatchEvent(app, .{ .canvas_widget_keyboard = keyboard_event });
            }
            if (widget_text_input_event) |text_input_event| {
                try self.dispatchEvent(app, .{ .canvas_widget_keyboard = text_input_event });
            }
            try self.dispatchEvent(app, .{ .gpu_surface_input = input_event });
        }

        fn enrichGpuSurfaceFrameDiagnostics(self: *Runtime, index: usize, enriched_frame_event: *platform.GpuSurfaceFrameEvent) anyerror!void {
            const preview_frame = try CanvasFrameMethods().planCanvasFrameForView(self, index, .{
                .frame_index = enriched_frame_event.frame_index,
                .timestamp_ns = enriched_frame_event.timestamp_ns,
                .surface_size = enriched_frame_event.size,
                .scale = enriched_frame_event.scale_factor,
            }, CanvasFrameMethods().canvasFrameScratchStorage(self), false);
            const preview_render_pass = preview_frame.renderPass();
            const preview_gpu_packet_summary = preview_frame.gpuPacketSummary();
            const preview_budget_status = preview_frame.budgetStatus();
            enriched_frame_event.canvas_revision = self.views[index].canvas_revision;
            enriched_frame_event.frame_interval_ns = self.views[index].gpu_frame_interval_ns;
            enriched_frame_event.input_timestamp_ns = self.views[index].gpu_input_timestamp_ns;
            enriched_frame_event.input_latency_ns = self.views[index].gpu_input_latency_ns;
            enriched_frame_event.input_latency_budget_ns = self.views[index].gpu_input_latency_budget_ns;
            enriched_frame_event.input_latency_budget_exceeded_count = self.views[index].gpu_input_latency_budget_exceeded_count;
            enriched_frame_event.input_latency_budget_ok = self.views[index].gpu_input_latency_budget_ok;
            enriched_frame_event.first_frame_latency_ns = self.views[index].gpu_first_frame_latency_ns;
            enriched_frame_event.first_frame_latency_budget_ns = self.views[index].gpu_first_frame_latency_budget_ns;
            enriched_frame_event.first_frame_latency_budget_exceeded_count = self.views[index].gpu_first_frame_latency_budget_exceeded_count;
            enriched_frame_event.first_frame_latency_budget_ok = self.views[index].gpu_first_frame_latency_budget_ok;
            enriched_frame_event.canvas_command_count = self.views[index].canvas_command_count;
            enriched_frame_event.canvas_frame_requires_render = preview_frame.requiresRender();
            enriched_frame_event.canvas_frame_full_repaint = preview_frame.full_repaint;
            enriched_frame_event.canvas_frame_batch_count = preview_frame.batch_plan.batchCount();
            enriched_frame_event.canvas_frame_encoder_command_count = preview_render_pass.encoderCommandCount();
            enriched_frame_event.canvas_frame_encoder_cache_action_count = preview_render_pass.encoderCacheActionCount();
            enriched_frame_event.canvas_frame_encoder_bind_pipeline_count = preview_render_pass.encoderBindPipelineCount();
            enriched_frame_event.canvas_frame_encoder_draw_batch_count = preview_render_pass.encoderDrawBatchCount();
            enriched_frame_event.canvas_frame_pipeline_count = preview_frame.pipeline_cache_plan.entryCount();
            enriched_frame_event.canvas_frame_pipeline_upload_count = preview_frame.pipeline_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_pipeline_retain_count = preview_frame.pipeline_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_pipeline_evict_count = preview_frame.pipeline_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_path_geometry_count = preview_frame.path_geometry_plan.geometryCount();
            enriched_frame_event.canvas_frame_path_geometry_vertex_count = preview_frame.path_geometry_plan.vertexCount();
            enriched_frame_event.canvas_frame_path_geometry_index_count = preview_frame.path_geometry_plan.indexCount();
            enriched_frame_event.canvas_frame_path_geometry_upload_count = preview_frame.path_geometry_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_path_geometry_retain_count = preview_frame.path_geometry_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_path_geometry_evict_count = preview_frame.path_geometry_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_image_count = preview_frame.image_plan.imageCount();
            enriched_frame_event.canvas_frame_image_upload_count = preview_frame.image_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_image_retain_count = preview_frame.image_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_image_evict_count = preview_frame.image_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_layer_count = preview_frame.layer_plan.layerCount();
            enriched_frame_event.canvas_frame_layer_opacity_count = preview_frame.layer_plan.opacityLayerCount();
            enriched_frame_event.canvas_frame_layer_clip_count = preview_frame.layer_plan.clipLayerCount();
            enriched_frame_event.canvas_frame_layer_transform_count = preview_frame.layer_plan.transformLayerCount();
            enriched_frame_event.canvas_frame_layer_upload_count = preview_frame.layer_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_layer_retain_count = preview_frame.layer_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_layer_evict_count = preview_frame.layer_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_resource_count = preview_frame.resource_plan.resourceCount();
            enriched_frame_event.canvas_frame_resource_upload_count = preview_frame.resource_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_resource_retain_count = preview_frame.resource_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_resource_evict_count = preview_frame.resource_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_visual_effect_count = preview_frame.visual_effect_plan.effectCount();
            enriched_frame_event.canvas_frame_visual_effect_shadow_count = preview_frame.visual_effect_plan.shadowCount();
            enriched_frame_event.canvas_frame_visual_effect_blur_count = preview_frame.visual_effect_plan.blurCount();
            enriched_frame_event.canvas_frame_visual_effect_upload_count = preview_frame.visual_effect_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_visual_effect_retain_count = preview_frame.visual_effect_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_visual_effect_evict_count = preview_frame.visual_effect_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_glyph_atlas_entry_count = preview_frame.glyph_atlas_plan.entryCount();
            enriched_frame_event.canvas_frame_glyph_atlas_upload_count = preview_frame.glyph_atlas_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_glyph_atlas_retain_count = preview_frame.glyph_atlas_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_glyph_atlas_evict_count = preview_frame.glyph_atlas_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_text_layout_count = preview_frame.text_layout_plan.planCount();
            enriched_frame_event.canvas_frame_text_layout_line_count = preview_frame.text_layout_plan.lineCount();
            enriched_frame_event.canvas_frame_text_layout_upload_count = preview_frame.text_layout_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_text_layout_retain_count = preview_frame.text_layout_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_text_layout_evict_count = preview_frame.text_layout_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_gpu_packet_command_count = preview_gpu_packet_summary.command_count;
            enriched_frame_event.canvas_frame_gpu_packet_cache_action_count = preview_gpu_packet_summary.cache_action_count;
            enriched_frame_event.canvas_frame_gpu_packet_cached_resource_command_count = preview_gpu_packet_summary.cached_resource_command_count;
            enriched_frame_event.canvas_frame_gpu_packet_unsupported_command_count = preview_gpu_packet_summary.unsupported_command_count;
            enriched_frame_event.canvas_frame_gpu_packet_representable = preview_gpu_packet_summary.fullyRepresentable();
            enriched_frame_event.canvas_frame_change_count = preview_frame.changes.len;
            enriched_frame_event.canvas_frame_budget_exceeded_count = preview_budget_status.exceededCount();
            enriched_frame_event.canvas_frame_budget_ok = preview_budget_status.ok();
            enriched_frame_event.canvas_frame_dirty_bounds = preview_frame.dirty_bounds;
            const preview_profile = preview_frame.profile();
            enriched_frame_event.canvas_frame_profile_work_units = preview_profile.work_units;
            enriched_frame_event.canvas_frame_profile_risk = platformCanvasFrameProfileRisk(preview_profile.risk);
            enriched_frame_event.canvas_frame_profile_surface_area = preview_profile.surface_area;
            enriched_frame_event.canvas_frame_profile_dirty_area = preview_profile.dirty_area;
            enriched_frame_event.canvas_frame_profile_dirty_ratio = preview_profile.dirty_ratio;
            enriched_frame_event.widget_revision = self.views[index].widget_revision;
            enriched_frame_event.widget_node_count = self.views[index].widget_layout_node_count;
            enriched_frame_event.widget_semantics_count = self.views[index].widget_semantics_node_count;
        }

        fn CanvasFrameMethods() type {
            return canvas_frame_helpers.RuntimeCanvasFrames(Runtime);
        }

        fn CanvasWidgetDisplayMethods() type {
            return runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime);
        }

        fn CanvasWidgetEventMethods() type {
            return runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(Runtime);
        }
    };
}

fn setFocusedView(self: anytype, window_id: platform.WindowId, label: []const u8) !void {
    if (runtimeFindWindowIndexById(self, window_id)) |window_index| {
        self.windows[window_index].main_focused = std.mem.eql(u8, label, "main");
    }
    for (self.views[0..self.view_count], 0..) |*view, view_index| {
        if (view.window_id != window_id) continue;
        const previous_state = view.canvasWidgetRenderState();
        view.focused = std.mem.eql(u8, view.label, label);
        const next_state = view.canvasWidgetRenderState();
        if (!runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(@TypeOf(self.*)).canvasWidgetRenderStatesEqual(previous_state, next_state)) {
            try runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(@TypeOf(self.*)).invalidateForCanvasWidgetRenderStateChange(self, view_index, previous_state, next_state);
        }
    }
    for (self.webviews[0..self.webview_count]) |*webview| {
        if (webview.window_id == window_id) webview.focused = std.mem.eql(u8, webview.label, label);
    }
}

fn runtimeFindWindowIndexById(self: anytype, id: platform.WindowId) ?usize {
    for (self.windows[0..self.window_count], 0..) |window, index| {
        if (window.info.id == id) return index;
    }
    return null;
}

fn runtimeFindViewIndex(self: anytype, window_id: platform.WindowId, label: []const u8) ?usize {
    for (self.views[0..self.view_count], 0..) |view, index| {
        if (view.open and view.window_id == window_id and std.mem.eql(u8, view.label, label)) return index;
    }
    return null;
}

fn rectsEqual(a: geometry.RectF, b: geometry.RectF) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}
