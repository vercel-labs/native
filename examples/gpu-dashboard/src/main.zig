const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const canvas = zero_native.canvas;
const geometry = zero_native.geometry;

const window_width: f32 = 1240;
const window_height: f32 = 780;
const toolbar_height: f32 = 54;
const canvas_pixel_width: usize = @intFromFloat(window_width);
const canvas_width: f32 = @floatFromInt(canvas_pixel_width);
const canvas_height: f32 = window_height;
const default_canvas_size = geometry.SizeF.init(canvas_width, canvas_height);
const statusbar_height: f32 = 34;
const dashboard_content_y: f32 = toolbar_height;
const dashboard_content_height: f32 = canvas_height - toolbar_height - statusbar_height;
const max_dashboard_pipelines: usize = 8;
const max_dashboard_commands: usize = zero_native.runtime.max_canvas_commands_per_view;
const max_dashboard_glyphs: usize = zero_native.runtime.max_canvas_glyphs_per_view;
const max_dashboard_widgets: usize = 48;
const dashboard_chrome_prefix_commands: usize = 6;
const dashboard_chrome_suffix_commands: usize = 0;
const expected_dashboard_command_count: usize = 72;
const expected_dashboard_interaction_command_count: usize = 73;
const expected_dashboard_reference_signature: u64 = 11241989199542776100;
const refresh_command = "dashboard.refresh";
const mode_command = "dashboard.mode";
const dashboard_canvas_label = "dashboard-canvas";
const dashboard_toolbar_id: canvas.ObjectId = 80;
const dashboard_toolbar_title_id: canvas.ObjectId = 81;
const dashboard_toolbar_mode_id: canvas.ObjectId = 82;
const dashboard_toolbar_refresh_id: canvas.ObjectId = 83;
const dashboard_toolbar_separator_id: canvas.ObjectId = 84;
const dashboard_content_stack_id: canvas.ObjectId = 90;
const dashboard_status_separator_id: canvas.ObjectId = 260;
const dashboard_status_text_id: canvas.ObjectId = 261;
const initial_dashboard_status_text = "Canvas scene waiting for the first GPU frame.";
const max_dashboard_status_text: usize = 192;
const live_button_fill_command_id: canvas.ObjectId = 103 * 16 + 1;
const live_button_text_command_id: canvas.ObjectId = 103 * 16 + 4;
const forecast_text_command_id: canvas.ObjectId = 131 * 16 + 4;
const forecast_composition_command_id: canvas.ObjectId = 131 * 16 + 5;
const confidence_active_command_id: canvas.ObjectId = 134 * 16 + 2;
const deployment_region_text_command_id: canvas.ObjectId = 156 * 16 + 4;
const overview_fill_command_id: canvas.ObjectId = 111 * 16 + 1;
const customers_fill_command_id: canvas.ObjectId = 112 * 16 + 1;
const activity_scroll_track_command_id: canvas.ObjectId = 120 * 16 + 2;
const activity_scroll_thumb_command_id: canvas.ObjectId = 120 * 16 + 3;
const activity_first_text_command_id: canvas.ObjectId = 121 * 16 + 3;
const filter_popover_blur_command_id: canvas.ObjectId = 140 * 16 + 12;
const dashboard_glass_blur: f32 = 14;

const bg_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = color(246, 248, 252) },
    .{ .offset = 1, .color = color(229, 241, 250) },
};
const hero_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = color(18, 24, 38) },
    .{ .offset = 0.58, .color = color(27, 72, 100) },
    .{ .offset = 1, .color = color(17, 161, 153) },
};
const accent_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = color(48, 111, 237) },
    .{ .offset = 1, .color = color(16, 185, 129) },
};
const warm_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = color(248, 113, 113) },
    .{ .offset = 1, .color = color(251, 191, 36) },
};

const app_permissions = [_][]const u8{ zero_native.security.permission_command, zero_native.security.permission_view };
const shell_views = [_]zero_native.ShellView{
    .{ .label = dashboard_canvas_label, .kind = .gpu_surface, .fill = true, .min_width = 720, .layer = 12, .role = "Native-rendered dashboard canvas", .accessibility_label = "Native-rendered product dashboard canvas", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]zero_native.ShellWindow{.{
    .label = "main",
    .title = "zero-native GPU Dashboard",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: zero_native.ShellConfig = .{ .windows = &shell_windows };

const GpuDashboardApp = struct {
    refresh_count: u32 = 0,
    mode_count: u32 = 0,
    color_scheme: zero_native.ColorScheme = .light,
    reduce_motion: bool = false,
    high_contrast: bool = false,
    canvas_installed: bool = false,
    reported_planned_frame: bool = false,
    status_text_storage: [max_dashboard_status_text]u8 = undefined,
    status_text_len: usize = 0,
    canvas_size: geometry.SizeF = default_canvas_size,
    pixel_snap_scale: f32 = 1,
    pixels: ?[]u8 = null,
    scratch: ?[]u8 = null,
    gpu_commands: [max_dashboard_commands]canvas.CanvasGpuCommand = undefined,
    packet_json: [zero_native.platform.max_gpu_surface_packet_json_bytes]u8 = undefined,
    render_commands: [max_dashboard_commands]canvas.RenderCommand = undefined,
    render_batches: [max_dashboard_commands]canvas.RenderBatch = undefined,
    pipeline_cache_entries: [max_dashboard_pipelines]canvas.RenderPipelineCacheEntry = undefined,
    pipeline_cache_actions: [max_dashboard_pipelines * 2]canvas.RenderPipelineCacheAction = undefined,
    layers: [max_dashboard_commands]canvas.RenderLayer = undefined,
    layer_cache_entries: [max_dashboard_commands]canvas.RenderLayerCacheEntry = undefined,
    layer_cache_actions: [max_dashboard_commands * 2]canvas.RenderLayerCacheAction = undefined,
    resources: [max_dashboard_commands]canvas.RenderResource = undefined,
    cache_entries: [max_dashboard_commands]canvas.RenderResourceCacheEntry = undefined,
    cache_actions: [max_dashboard_commands * 2]canvas.RenderResourceCacheAction = undefined,
    visual_effects: [max_dashboard_commands]canvas.VisualEffect = undefined,
    visual_effect_cache_entries: [max_dashboard_commands]canvas.VisualEffectCacheEntry = undefined,
    visual_effect_cache_actions: [max_dashboard_commands * 2]canvas.VisualEffectCacheAction = undefined,
    glyphs: [max_dashboard_glyphs]canvas.GlyphAtlasEntry = undefined,
    glyph_cache_entries: [max_dashboard_glyphs]canvas.GlyphAtlasCacheEntry = undefined,
    glyph_cache_actions: [max_dashboard_glyphs * 2]canvas.GlyphAtlasCacheAction = undefined,
    text_layout_plans: [max_dashboard_commands]canvas.TextLayoutPlan = undefined,
    text_layout_lines: [max_dashboard_glyphs]canvas.TextLine = undefined,
    text_layout_cache_entries: [max_dashboard_commands]canvas.TextLayoutCacheEntry = undefined,
    text_layout_cache_actions: [max_dashboard_commands * 2]canvas.TextLayoutCacheAction = undefined,
    changes: [max_dashboard_commands * 2 + 1]canvas.DiffChange = undefined,

    fn app(self: *@This()) zero_native.App {
        return .{
            .context = self,
            .name = "gpu-dashboard",
            .scene_fn = scene,
            .event_fn = event,
            .stop_fn = stop,
        };
    }

    fn deinit(self: *@This()) void {
        if (self.pixels) |pixels| std.heap.page_allocator.free(pixels);
        if (self.scratch) |scratch| std.heap.page_allocator.free(scratch);
        self.pixels = null;
        self.scratch = null;
    }

    fn scene(context: *anyopaque) anyerror!zero_native.ShellConfig {
        _ = context;
        return shell_scene;
    }

    fn event(context: *anyopaque, runtime: *zero_native.Runtime, event_value: zero_native.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event_value) {
            .command => |command| {
                if (std.mem.eql(u8, command.name, refresh_command)) {
                    try self.refresh(runtime, command);
                } else if (std.mem.eql(u8, command.name, mode_command)) {
                    try self.toggleMode(runtime, command);
                }
            },
            .gpu_surface_frame => |frame_event| try self.handleGpuFrame(runtime, frame_event),
            .canvas_widget_pointer => |pointer_event| try self.handleWidgetPointer(runtime, pointer_event),
            .canvas_widget_keyboard => |keyboard_event| try self.handleWidgetKeyboard(runtime, keyboard_event),
            .appearance_changed => |appearance| try self.applySystemAppearance(runtime, appearance),
            .gpu_surface_resized, .gpu_surface_input, .shortcut, .files_dropped, .canvas_widget_file_drop, .canvas_widget_drag, .lifecycle => {},
        }
    }

    fn stop(context: *anyopaque, runtime: *zero_native.Runtime) anyerror!void {
        _ = runtime;
        const self: *@This() = @ptrCast(@alignCast(context));
        self.deinit();
    }

    fn handleGpuFrame(self: *@This(), runtime: *zero_native.Runtime, frame_event: zero_native.GpuSurfaceFrameEvent) anyerror!void {
        if (!std.mem.eql(u8, frame_event.label, dashboard_canvas_label)) return;
        const first_install = !self.canvas_installed;
        const scale_changed = self.updatePixelSnapScale(frame_event.scale_factor);
        const size_changed = self.updateCanvasSize(dashboardSurfaceSize(frame_event.size));
        if (first_install or scale_changed or size_changed) {
            if (first_install) self.setStatusText("Dashboard display list presented on the GPU surface.");
            try self.installDashboardCanvas(runtime, frame_event);
            return;
        }

        _ = try self.presentDashboardCanvas(runtime, frame_event, frame_event.canvas_frame_full_repaint);
        const current_frame = try runtime.gpuSurfaceFrame(frame_event.window_id, "dashboard-canvas");
        try self.reportFrameStatus(runtime, gpuFrameEvent(current_frame));
    }

    fn handleWidgetPointer(self: *@This(), runtime: *zero_native.Runtime, pointer_event: zero_native.runtime.CanvasWidgetPointerEvent) anyerror!void {
        if (!std.mem.eql(u8, pointer_event.view_label, dashboard_canvas_label)) return;
        const target = pointer_event.target orelse return;
        const action = switch (pointer_event.pointer.phase) {
            .up => "Clicked",
            else => return,
        };
        if (target.id == dashboard_toolbar_mode_id or target.id == dashboard_toolbar_refresh_id) return;
        try self.reportWidgetInteraction(runtime, pointer_event.window_id, action, target.id);
    }

    fn handleWidgetKeyboard(self: *@This(), runtime: *zero_native.Runtime, keyboard_event: zero_native.runtime.CanvasWidgetKeyboardEvent) anyerror!void {
        if (!std.mem.eql(u8, keyboard_event.view_label, dashboard_canvas_label)) return;
        if (keyboard_event.keyboard.phase != .key_down) return;
        const target = keyboard_event.target orelse return;
        if (target.id == dashboard_toolbar_mode_id or target.id == dashboard_toolbar_refresh_id) return;
        switch (target.kind) {
            .scroll_view, .list, .data_grid, .table => return,
            else => {},
        }
        try self.reportWidgetInteraction(runtime, keyboard_event.window_id, "Keyed", target.id);
    }

    fn reportWidgetInteraction(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId, action: []const u8, id: canvas.ObjectId) anyerror!void {
        const layout = try runtime.canvasWidgetLayout(window_id, dashboard_canvas_label);
        const node = layout.findById(id) orelse return;
        const widget = node.widget;
        var status_buffer: [192]u8 = undefined;
        const status = switch (widget.kind) {
            .checkbox, .toggle => try std.fmt.bufPrint(
                &status_buffer,
                "{s} {s} #{d}: {s}.",
                .{ action, @tagName(widget.kind), id, if (widget.state.selected or widget.value >= 0.5) "on" else "off" },
            ),
            .slider, .progress => try std.fmt.bufPrint(
                &status_buffer,
                "{s} {s} #{d}: value {d}.",
                .{ action, @tagName(widget.kind), id, widget.value },
            ),
            .scroll_view, .list, .data_grid => try std.fmt.bufPrint(
                &status_buffer,
                "{s} {s} #{d}: offset {d}.",
                .{ action, @tagName(widget.kind), id, widget.value },
            ),
            .text_field, .search_field => try std.fmt.bufPrint(
                &status_buffer,
                "{s} {s} #{d}: {d} bytes.",
                .{ action, @tagName(widget.kind), id, widget.text.len },
            ),
            else => try std.fmt.bufPrint(
                &status_buffer,
                "{s} {s} #{d}{s}.",
                .{ action, @tagName(widget.kind), id, if (widget.state.selected) ": selected" else "" },
            ),
        };
        try self.updateStatus(runtime, window_id, status);
    }

    fn reportFrameStatus(self: *@This(), runtime: *zero_native.Runtime, frame_event: zero_native.GpuSurfaceFrameEvent) anyerror!void {
        if (!self.reported_planned_frame and frame_event.canvas_command_count > 0) {
            self.reported_planned_frame = true;
            var status_buffer: [192]u8 = undefined;
            const status = try dashboardFrameStatus(&status_buffer, frame_event);
            try self.updateStatus(runtime, frame_event.window_id, status);
        }
    }

    fn installDashboardCanvas(self: *@This(), runtime: *zero_native.Runtime, frame_event: zero_native.GpuSurfaceFrameEvent) anyerror!void {
        try installDashboardCanvasModelWithTokens(runtime, frame_event.window_id, self.dashboardTokens(), self.canvas_size, self.statusText());
        try self.scheduleDashboardAnimations(runtime, frame_event.window_id, frame_event.timestamp_ns);
        _ = try self.presentDashboardCanvas(runtime, frame_event, true);
        self.canvas_installed = true;
    }

    fn dashboardTokens(self: @This()) canvas.DesignTokens {
        return dashboardWidgetTokensForSchemeScaleMotionAndContrast(self.color_scheme, self.pixel_snap_scale, self.reduce_motion, self.high_contrast);
    }

    fn updatePixelSnapScale(self: *@This(), scale_factor: f32) bool {
        const next = normalizedPixelSnapScale(scale_factor);
        if (@abs(self.pixel_snap_scale - next) < 0.001) return false;
        self.pixel_snap_scale = next;
        return true;
    }

    fn updateCanvasSize(self: *@This(), size: geometry.SizeF) bool {
        if (dashboardSizesEqual(self.canvas_size, size)) return false;
        self.canvas_size = size;
        return true;
    }

    fn setStatusText(self: *@This(), text: []const u8) void {
        const len = @min(text.len, self.status_text_storage.len);
        @memcpy(self.status_text_storage[0..len], text[0..len]);
        self.status_text_len = len;
    }

    fn statusText(self: *const @This()) []const u8 {
        if (self.status_text_len == 0) return initial_dashboard_status_text;
        return self.status_text_storage[0..self.status_text_len];
    }

    fn updateDashboardCanvasModel(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId) anyerror!void {
        try installDashboardCanvasModelWithTokens(runtime, window_id, self.dashboardTokens(), self.canvas_size, self.statusText());
    }

    fn updateStatus(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId, text: []const u8) anyerror!void {
        self.setStatusText(text);
        if (self.canvas_installed) try self.updateDashboardCanvasModel(runtime, window_id);
    }

    fn refresh(self: *@This(), runtime: *zero_native.Runtime, command: zero_native.CommandEvent) anyerror!void {
        self.refresh_count += 1;
        self.reported_planned_frame = false;
        const gpu_frame = try runtime.gpuSurfaceFrame(command.window_id, dashboard_canvas_label);
        _ = self.updateCanvasSize(dashboardSurfaceSize(gpu_frame.size));
        try installDashboardCanvasModelWithTokens(runtime, command.window_id, self.dashboardTokens(), self.canvas_size, self.statusText());
        try self.scheduleDashboardAnimations(runtime, command.window_id, gpu_frame.timestamp_ns);
        _ = try self.presentDashboardCanvas(runtime, gpuFrameEvent(gpu_frame), true);

        var status_buffer: [160]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "Dashboard canvas refreshed from {s}. Count {d}.", .{ @tagName(command.source), self.refresh_count });
        try self.updateStatus(runtime, command.window_id, status);
    }

    fn toggleMode(self: *@This(), runtime: *zero_native.Runtime, command: zero_native.CommandEvent) anyerror!void {
        self.mode_count += 1;
        var status_buffer: [160]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "Dashboard mode changed from {s}. Count {d}.", .{ @tagName(command.source), self.mode_count });
        try self.updateStatus(runtime, command.window_id, status);
    }

    fn applySystemAppearance(self: *@This(), runtime: *zero_native.Runtime, appearance: zero_native.Appearance) anyerror!void {
        const scheme_changed = self.color_scheme != appearance.color_scheme;
        const motion_changed = self.reduce_motion != appearance.reduce_motion;
        const contrast_changed = self.high_contrast != appearance.high_contrast;
        if (!scheme_changed and !motion_changed and !contrast_changed) return;
        self.color_scheme = appearance.color_scheme;
        self.reduce_motion = appearance.reduce_motion;
        self.high_contrast = appearance.high_contrast;
        if (!self.canvas_installed) return;

        const gpu_frame = runtime.gpuSurfaceFrame(1, dashboard_canvas_label) catch |err| switch (err) {
            error.WindowNotFound, error.ViewNotFound, error.InvalidViewOptions => return,
            else => return err,
        };
        _ = self.updateCanvasSize(dashboardSurfaceSize(gpu_frame.size));
        try installDashboardCanvasModelWithTokens(runtime, 1, self.dashboardTokens(), self.canvas_size, self.statusText());
        try self.scheduleDashboardAnimations(runtime, 1, gpu_frame.timestamp_ns);
        _ = try self.presentDashboardCanvas(runtime, gpuFrameEvent(gpu_frame), true);

        var status_buffer: [160]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "Dashboard theme: {s} from system appearance.", .{@tagName(self.color_scheme)});
        try self.updateStatus(runtime, 1, status);
    }

    fn presentDashboardCanvas(self: *@This(), runtime: *zero_native.Runtime, frame_event: zero_native.GpuSurfaceFrameEvent, full_repaint: bool) anyerror!void {
        const surface_size = dashboardSurfaceSize(frame_event.size);
        const scale_factor = if (frame_event.scale_factor > 0) frame_event.scale_factor else 1;
        const present_scale = referencePresentScale(scale_factor);
        const packet = runtime.presentNextCanvasGpuPacketWithScale(
            frame_event.window_id,
            dashboard_canvas_label,
            .{
                .frame_index = frame_event.frame_index,
                .timestamp_ns = frame_event.timestamp_ns,
                .surface_size = surface_size,
                .scale = scale_factor,
                .full_repaint = full_repaint,
            },
            self.frameStorage(),
            color(246, 248, 252),
            &self.gpu_commands,
            &self.packet_json,
            present_scale,
        ) catch |err| switch (err) {
            error.UnsupportedService => {
                try self.presentDashboardCanvasPixels(runtime, frame_event.window_id, surface_size, scale_factor, frame_event.frame_index, frame_event.timestamp_ns, full_repaint);
                return;
            },
            else => return err,
        };
        if (!packet.fullyRepresentable()) return error.UnsupportedCommand;
    }

    fn presentDashboardCanvasPixels(
        self: *@This(),
        runtime: *zero_native.Runtime,
        window_id: zero_native.WindowId,
        surface_size: geometry.SizeF,
        scale_factor: f32,
        frame_index: u64,
        timestamp_ns: u64,
        full_repaint: bool,
    ) anyerror!void {
        const present_scale = referencePresentScale(scale_factor);
        try self.ensurePixelBuffers(surface_size, present_scale);
        _ = try runtime.presentNextCanvasFrame(
            window_id,
            dashboard_canvas_label,
            .{
                .frame_index = frame_index,
                .timestamp_ns = timestamp_ns,
                .surface_size = surface_size,
                .scale = scale_factor,
                .full_repaint = full_repaint,
            },
            self.frameStorage(),
            &self.gpu_commands,
            &self.packet_json,
            self.pixels.?,
            self.scratch.?,
            color(246, 248, 252),
            present_scale,
        );
    }

    fn referencePresentScale(scale_factor: f32) f32 {
        const normalized = if (scale_factor > 0) scale_factor else 1;
        return normalized;
    }

    fn scheduleDashboardAnimations(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId, start_ns: u64) anyerror!void {
        _ = self;
        const motion = dashboardWidgetTokens().motion;
        const animations = [_]canvas.CanvasRenderAnimation{
            motion.animation(.{
                .id = live_button_fill_command_id,
                .start_ns = start_ns,
                .duration = .slow,
                .from_opacity = 0.72,
                .to_opacity = 1,
                .from_transform = canvas.Affine.translate(0, -7),
                .to_transform = canvas.Affine.identity(),
            }),
            motion.animation(.{
                .id = live_button_text_command_id,
                .start_ns = start_ns,
                .duration = .slow,
                .from_opacity = 0.72,
                .to_opacity = 1,
                .from_transform = canvas.Affine.translate(0, -7),
                .to_transform = canvas.Affine.identity(),
            }),
        };
        _ = try runtime.setCanvasRenderAnimations(window_id, dashboard_canvas_label, &animations);
    }

    fn frameStorage(self: *@This()) canvas.CanvasFrameStorage {
        return .{
            .render_commands = &self.render_commands,
            .render_batches = &self.render_batches,
            .pipeline_cache_entries = &self.pipeline_cache_entries,
            .pipeline_cache_actions = &self.pipeline_cache_actions,
            .layers = &self.layers,
            .layer_cache_entries = &self.layer_cache_entries,
            .layer_cache_actions = &self.layer_cache_actions,
            .resources = &self.resources,
            .resource_cache_entries = &self.cache_entries,
            .resource_cache_actions = &self.cache_actions,
            .visual_effects = &self.visual_effects,
            .visual_effect_cache_entries = &self.visual_effect_cache_entries,
            .visual_effect_cache_actions = &self.visual_effect_cache_actions,
            .glyph_atlas_entries = &self.glyphs,
            .glyph_atlas_cache_entries = &self.glyph_cache_entries,
            .glyph_atlas_cache_actions = &self.glyph_cache_actions,
            .text_layout_plans = &self.text_layout_plans,
            .text_layout_lines = &self.text_layout_lines,
            .text_layout_cache_entries = &self.text_layout_cache_entries,
            .text_layout_cache_actions = &self.text_layout_cache_actions,
            .changes = &self.changes,
        };
    }

    fn ensurePixelBuffers(self: *@This(), surface_size: geometry.SizeF, scale_factor: f32) anyerror!void {
        const pixel_size = try zero_native.runtime.canvasSurfacePixelSize(surface_size, scale_factor);
        if (self.pixels == null or self.pixels.?.len < pixel_size.byte_len) {
            if (self.pixels) |pixels| std.heap.page_allocator.free(pixels);
            self.pixels = try std.heap.page_allocator.alloc(u8, pixel_size.byte_len);
        }
        if (self.scratch == null or self.scratch.?.len < pixel_size.byte_len) {
            if (self.scratch) |scratch| std.heap.page_allocator.free(scratch);
            self.scratch = try std.heap.page_allocator.alloc(u8, pixel_size.byte_len);
        }
    }
};

fn installDashboardCanvasModel(runtime: *zero_native.Runtime, window_id: zero_native.WindowId) anyerror!void {
    return installDashboardCanvasModelWithTokens(runtime, window_id, dashboardWidgetTokens(), default_canvas_size, initial_dashboard_status_text);
}

fn installDashboardCanvasModelWithTokens(runtime: *zero_native.Runtime, window_id: zero_native.WindowId, tokens: canvas.DesignTokens, surface_size: geometry.SizeF, status_text: []const u8) anyerror!void {
    var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
    var nodes: [max_dashboard_widgets]canvas.WidgetLayoutNode = undefined;
    var builder = canvas.Builder.init(&commands);
    const layout = try buildDashboardWidgetLayoutForSize(&nodes, surface_size, status_text);
    try buildDashboardDisplayListForSize(&builder, layout, tokens, surface_size);
    _ = try runtime.setCanvasDisplayList(window_id, dashboard_canvas_label, builder.displayList());
    _ = try runtime.setCanvasWidgetLayout(window_id, dashboard_canvas_label, layout);
    _ = try runtime.emitCanvasWidgetDisplayListWithChrome(window_id, dashboard_canvas_label, tokens, .{
        .prefix_command_count = dashboard_chrome_prefix_commands,
        .suffix_command_count = dashboard_chrome_suffix_commands,
    });
}

fn buildDashboardDisplayListFromWidgets(builder: *canvas.Builder) canvas.Error!void {
    var nodes: [max_dashboard_widgets]canvas.WidgetLayoutNode = undefined;
    const layout = try buildDashboardWidgetLayout(&nodes);
    try buildDashboardDisplayList(builder, layout, dashboardWidgetTokens());
}

fn dashboardSurfaceSize(size: geometry.SizeF) geometry.SizeF {
    if (size.isEmpty()) return default_canvas_size;
    return .{
        .width = @max(1, size.width),
        .height = @max(1, size.height),
    };
}

fn dashboardBackdropRect(surface_size: geometry.SizeF) geometry.RectF {
    const size = dashboardSurfaceSize(surface_size);
    return rect(0, 0, size.width, size.height);
}

fn dashboardToolbarHeightForSize(surface_size: geometry.SizeF) f32 {
    const size = dashboardSurfaceSize(surface_size);
    const status_height = dashboardStatusbarHeightForSize(size);
    return @min(toolbar_height, @max(0, size.height - status_height - 1));
}

fn dashboardStatusbarHeightForSize(surface_size: geometry.SizeF) f32 {
    const size = dashboardSurfaceSize(surface_size);
    return @min(statusbar_height, @max(0, size.height - 1));
}

fn dashboardContentYForSize(surface_size: geometry.SizeF) f32 {
    return dashboardToolbarHeightForSize(surface_size);
}

fn dashboardContentHeightForSize(surface_size: geometry.SizeF) f32 {
    const size = dashboardSurfaceSize(surface_size);
    return @max(1, size.height - dashboardToolbarHeightForSize(size) - dashboardStatusbarHeightForSize(size));
}

fn dashboardHeroRect(surface_size: geometry.SizeF) geometry.RectF {
    const size = dashboardSurfaceSize(surface_size);
    return rect(38, dashboardContentYForSize(size) + 38, 168, @max(444, dashboardContentHeightForSize(size) - 76));
}

fn dashboardSizesEqual(a: geometry.SizeF, b: geometry.SizeF) bool {
    return a.width == b.width and a.height == b.height;
}

fn buildDashboardDisplayList(builder: *canvas.Builder, layout: canvas.WidgetLayoutTree, tokens: canvas.DesignTokens) canvas.Error!void {
    return buildDashboardDisplayListForSize(builder, layout, tokens, default_canvas_size);
}

fn buildDashboardDisplayListForSize(builder: *canvas.Builder, layout: canvas.WidgetLayoutTree, tokens: canvas.DesignTokens, surface_size: geometry.SizeF) canvas.Error!void {
    const size = dashboardSurfaceSize(surface_size);
    const backdrop_rect = dashboardBackdropRect(size);
    const hero_rect = dashboardHeroRect(size);
    const content_y = dashboardContentYForSize(size);
    const content_height = dashboardContentHeightForSize(size);
    try builder.fillRect(.{ .id = 1, .rect = backdrop_rect, .fill = .{ .color = tokens.colors.background } });
    try builder.fillRect(.{ .id = dashboard_toolbar_id, .rect = rect(0, 0, size.width, toolbar_height), .fill = .{ .color = tokens.colors.surface } });
    try builder.drawText(.{
        .id = dashboard_toolbar_title_id,
        .font_id = tokens.typography.font_id,
        .size = 16,
        .origin = geometry.PointF.init(18, 33),
        .color = tokens.colors.text,
        .text = "GPU Dashboard",
        .text_layout = .{
            .max_width = 220,
            .line_height = 20,
        },
    });
    try builder.fillRect(.{ .id = dashboard_toolbar_separator_id, .rect = rect(0, toolbar_height - 1, size.width, 1), .fill = .{ .color = tokens.colors.border } });
    try builder.fillRect(.{ .id = dashboard_status_separator_id, .rect = rect(0, content_y + content_height, size.width, 1), .fill = .{ .color = tokens.colors.border } });
    try builder.fillRoundedRect(.{ .id = 4, .rect = hero_rect, .radius = canvas.Radius.all(16), .fill = .{ .linear_gradient = .{ .start = hero_rect.topLeft(), .end = hero_rect.bottomRight(), .stops = &hero_stops } } });

    try layout.emitDisplayList(builder, tokens);
}

fn dashboardWidgetTokens() canvas.DesignTokens {
    return dashboardWidgetTokensForScale(1);
}

fn dashboardWidgetTokensForScale(pixel_snap_scale: f32) canvas.DesignTokens {
    return dashboardWidgetTokensForSchemeAndScale(.light, pixel_snap_scale);
}

fn dashboardWidgetTokensForSchemeAndScale(color_scheme: zero_native.ColorScheme, pixel_snap_scale: f32) canvas.DesignTokens {
    return dashboardWidgetTokensForSchemeScaleAndMotion(color_scheme, pixel_snap_scale, false);
}

fn dashboardWidgetTokensForSchemeScaleAndMotion(color_scheme: zero_native.ColorScheme, pixel_snap_scale: f32, reduce_motion: bool) canvas.DesignTokens {
    return dashboardWidgetTokensForSchemeScaleMotionAndContrast(color_scheme, pixel_snap_scale, reduce_motion, false);
}

fn dashboardWidgetTokensForSchemeScaleMotionAndContrast(color_scheme: zero_native.ColorScheme, pixel_snap_scale: f32, reduce_motion: bool, high_contrast: bool) canvas.DesignTokens {
    var tokens = canvas.DesignTokens.theme(.{ .color_scheme = switch (color_scheme) {
        .light => .light,
        .dark => .dark,
    }, .contrast = if (high_contrast) .high else .standard, .reduce_motion = reduce_motion });
    tokens.blur = .{
        .sm = 8,
        .md = dashboard_glass_blur,
    };
    if (!reduce_motion) tokens.motion = .{
        .slow_ms = 900,
        .easing = .emphasized,
    };
    tokens.pixel_snap = .{ .geometry = true, .text = true, .scale = normalizedPixelSnapScale(pixel_snap_scale) };
    return tokens;
}

fn normalizedPixelSnapScale(scale_factor: f32) f32 {
    if (!std.math.isFinite(scale_factor) or scale_factor <= 0) return 1;
    return scale_factor;
}

fn buildDashboardWidgetLayout(nodes: []canvas.WidgetLayoutNode) canvas.Error!canvas.WidgetLayoutTree {
    return buildDashboardWidgetLayoutForSize(nodes, default_canvas_size, initial_dashboard_status_text);
}

fn buildDashboardWidgetLayoutForSize(nodes: []canvas.WidgetLayoutNode, surface_size: geometry.SizeF, status_text: []const u8) canvas.Error!canvas.WidgetLayoutTree {
    const metric_items = [_]canvas.Widget{
        .{ .id = 105, .kind = .list_item, .text = "ARR $12.8M, up 18.4%" },
        .{ .id = 106, .kind = .list_item, .text = "Activation 74.2%, up 6.1%" },
    };
    const nav_items = [_]canvas.Widget{
        .{ .id = 111, .kind = .list_item, .text = "Overview", .state = .{ .selected = true } },
        .{ .id = 112, .kind = .list_item, .text = "Customers" },
        .{ .id = 113, .kind = .list_item, .text = "Latency" },
    };
    const activity_items = [_]canvas.Widget{
        .{ .id = 121, .kind = .list_item, .frame = rect(0, 0, 0, 32), .text = "Signed enterprise renewal" },
        .{ .id = 122, .kind = .list_item, .frame = rect(0, 36, 0, 32), .text = "Usage spike in EU region" },
        .{ .id = 123, .kind = .list_item, .frame = rect(0, 72, 0, 32), .text = "Latency budget recovered" },
        .{ .id = 124, .kind = .list_item, .frame = rect(0, 108, 0, 32), .text = "Queued invoice batch" },
    };
    const form_fields = [_]canvas.Widget{
        .{
            .id = 131,
            .kind = .text_field,
            .frame = rect(14, 16, 116, 30),
            .text = "$13.4M",
            .semantics = .{ .label = "Forecast amount" },
        },
        .{
            .id = 132,
            .kind = .search_field,
            .frame = rect(144, 16, 128, 30),
            .text = "enterprise",
            .semantics = .{ .label = "Segment search" },
        },
        .{
            .id = 133,
            .kind = .toggle,
            .frame = rect(286, 17, 94, 28),
            .text = "Auto",
            .value = 1,
            .state = .{ .selected = true },
            .semantics = .{ .label = "Auto refresh" },
        },
        .{
            .id = 134,
            .kind = .slider,
            .frame = rect(446, 19, 78, 24),
            .value = 0.62,
            .semantics = .{ .label = "Confidence threshold" },
        },
    };
    const filter_items = [_]canvas.Widget{
        .{ .id = 142, .kind = .menu_item, .text = "Last 30 days" },
        .{ .id = 143, .kind = .menu_item, .text = "Enterprise" },
        .{ .id = 144, .kind = .menu_item, .text = "High intent" },
    };
    const filter_menu = [_]canvas.Widget{.{
        .id = 141,
        .kind = .menu_surface,
        .frame = rect(12, 12, 172, 92),
        .layout = .{ .gap = 2 },
        .semantics = .{ .label = "Filter options" },
        .children = &filter_items,
    }};
    const deployment_cells = [_]canvas.Widget{
        .{ .id = 156, .kind = .data_cell, .text = "iad1 8.6ms P95", .command = "deployment.open", .layout = .{ .grow = 1 } },
    };
    const deployment_rows = [_]canvas.Widget{
        .{ .id = 155, .kind = .data_row, .frame = rect(0, 0, 0, 28), .children = &deployment_cells },
    };
    const trend_widgets = [_]canvas.Widget{
        .{
            .id = 116,
            .kind = .text,
            .frame = rect(24, 20, 180, 18),
            .text = "Conversion trend",
        },
        .{
            .id = 150,
            .kind = .data_grid,
            .frame = rect(24, 58, 284, 28),
            .text = "Deployment latency",
            .children = &deployment_rows,
        },
    };
    const dashboard_widgets = [_]canvas.Widget{
        .{
            .id = 101,
            .kind = .text,
            .frame = rect(236, 54, 240, 28),
            .text = "Revenue pulse",
        },
        .{
            .id = 102,
            .kind = .text,
            .frame = rect(236, 88, 280, 18),
            .text = "Retained canvas dashboard",
        },
        .{
            .id = 103,
            .kind = .button,
            .frame = rect(688, 50, 122, 34),
            .text = "Live render",
            .command = mode_command,
            .semantics = .{ .label = "Live render status" },
        },
        .{
            .id = 104,
            .kind = .grid,
            .frame = rect(236, 128, 332, 76),
            .layout = .{ .columns = 2, .gap = 8 },
            .semantics = .{ .role = .list, .label = "Dashboard metrics" },
            .children = &metric_items,
        },
        .{
            .id = 108,
            .kind = .panel,
            .frame = rect(236, 248, 332, 164),
            .semantics = .{ .label = "Conversion trend" },
            .children = &trend_widgets,
        },
        .{
            .id = 109,
            .kind = .progress,
            .frame = rect(236, 216, 332, 10),
            .value = 0.68,
            .semantics = .{ .label = "Conversion progress" },
        },
        .{
            .id = 110,
            .kind = .list,
            .frame = rect(54, 136, 136, 120),
            .layout = .{ .gap = 8 },
            .semantics = .{ .label = "Dashboard navigation" },
            .children = &nav_items,
        },
        .{
            .id = 120,
            .kind = .scroll_view,
            .frame = rect(596, 238, 196, 112),
            .value = 18,
            .semantics = .{ .label = "Recent activity" },
            .children = &activity_items,
        },
        .{
            .id = 130,
            .kind = .panel,
            .frame = rect(236, 426, 556, 64),
            .semantics = .{ .label = "Forecast form" },
            .children = &form_fields,
        },
        .{
            .id = 140,
            .kind = .popover,
            .frame = rect(596, 92, 196, 118),
            .backdrop_blur_token = .md,
            .semantics = .{ .label = "Revenue filter popover" },
            .children = &filter_menu,
        },
    };
    const size = dashboardSurfaceSize(surface_size);
    const content_y = dashboardContentYForSize(size);
    const content_height = dashboardContentHeightForSize(size);
    const root_widgets = [_]canvas.Widget{
        .{
            .id = dashboard_toolbar_mode_id,
            .kind = .segmented_control,
            .frame = rect(252, 12, 214, 30),
            .text = "Overview|Revenue|Latency",
            .command = mode_command,
            .semantics = .{ .label = "Dashboard mode" },
        },
        .{
            .id = dashboard_toolbar_refresh_id,
            .kind = .button,
            .frame = rect(484, 12, 86, 30),
            .text = "Refresh",
            .variant = .secondary,
            .command = refresh_command,
            .semantics = .{ .label = "Refresh dashboard" },
        },
        .{
            .id = dashboard_content_stack_id,
            .kind = .stack,
            .frame = rect(0, content_y, size.width, content_height),
            .children = &dashboard_widgets,
        },
        .{
            .id = dashboard_status_text_id,
            .kind = .text,
            .frame = rect(14, content_y + content_height + 8, @max(1, size.width - 28), 18),
            .text = status_text,
            .size = .sm,
            .semantics = .{ .label = status_text },
        },
    };
    return canvas.layoutWidgetTree(.{ .kind = .stack, .children = &root_widgets }, rect(0, 0, size.width, size.height), nodes);
}

fn dashboardFrame(display_list: canvas.DisplayList, previous: ?canvas.DisplayList, options: canvas.CanvasFrameOptions, storage: canvas.CanvasFrameStorage) canvas.Error!canvas.CanvasFrame {
    return display_list.framePlan(previous, options, storage);
}

fn dashboardFrameStorage(
    render_commands: []canvas.RenderCommand,
    render_batches: []canvas.RenderBatch,
    pipeline_cache_entries: []canvas.RenderPipelineCacheEntry,
    pipeline_cache_actions: []canvas.RenderPipelineCacheAction,
    layers: []canvas.RenderLayer,
    layer_cache_entries: []canvas.RenderLayerCacheEntry,
    layer_cache_actions: []canvas.RenderLayerCacheAction,
    resources: []canvas.RenderResource,
    cache_entries: []canvas.RenderResourceCacheEntry,
    cache_actions: []canvas.RenderResourceCacheAction,
    visual_effects: []canvas.VisualEffect,
    visual_effect_cache_entries: []canvas.VisualEffectCacheEntry,
    visual_effect_cache_actions: []canvas.VisualEffectCacheAction,
    glyphs: []canvas.GlyphAtlasEntry,
    glyph_cache_entries: []canvas.GlyphAtlasCacheEntry,
    glyph_cache_actions: []canvas.GlyphAtlasCacheAction,
    text_layout_plans: []canvas.TextLayoutPlan,
    text_layout_lines: []canvas.TextLine,
    text_layout_cache_entries: []canvas.TextLayoutCacheEntry,
    text_layout_cache_actions: []canvas.TextLayoutCacheAction,
    changes: []canvas.DiffChange,
) canvas.CanvasFrameStorage {
    return .{
        .render_commands = render_commands,
        .render_batches = render_batches,
        .pipeline_cache_entries = pipeline_cache_entries,
        .pipeline_cache_actions = pipeline_cache_actions,
        .layers = layers,
        .layer_cache_entries = layer_cache_entries,
        .layer_cache_actions = layer_cache_actions,
        .resources = resources,
        .resource_cache_entries = cache_entries,
        .resource_cache_actions = cache_actions,
        .visual_effects = visual_effects,
        .visual_effect_cache_entries = visual_effect_cache_entries,
        .visual_effect_cache_actions = visual_effect_cache_actions,
        .glyph_atlas_entries = glyphs,
        .glyph_atlas_cache_entries = glyph_cache_entries,
        .glyph_atlas_cache_actions = glyph_cache_actions,
        .text_layout_plans = text_layout_plans,
        .text_layout_lines = text_layout_lines,
        .text_layout_cache_entries = text_layout_cache_entries,
        .text_layout_cache_actions = text_layout_cache_actions,
        .changes = changes,
    };
}

fn gpuFrameEvent(frame: zero_native.platform.GpuFrame) zero_native.GpuSurfaceFrameEvent {
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

fn dashboardFrameStatus(buffer: []u8, frame_event: zero_native.GpuSurfaceFrameEvent) std.fmt.BufPrintError![]u8 {
    return std.fmt.bufPrint(
        buffer,
        "Canvas frame: {s} risk, {d} work units, {d} commands, {d} batches, packet {s}, dirty {d}%.",
        .{
            @tagName(frame_event.canvas_frame_profile_risk),
            frame_event.canvas_frame_profile_work_units,
            frame_event.canvas_command_count,
            frame_event.canvas_frame_batch_count,
            if (frame_event.canvas_frame_gpu_packet_representable) "ok" else "fallback",
            dashboardDirtyPercent(frame_event.canvas_frame_profile_dirty_ratio),
        },
    );
}

fn dashboardDirtyPercent(ratio: f32) u32 {
    return @as(u32, @intFromFloat(@round(std.math.clamp(ratio, 0, 1) * 100.0)));
}

fn dashboardSnapshotWidget(snapshot: zero_native.automation.snapshot.Input, id: u64) ?zero_native.automation.snapshot.Widget {
    for (snapshot.widgets) |widget| {
        if (widget.id == id and std.mem.eql(u8, widget.view_label, "dashboard-canvas")) return widget;
    }
    return null;
}

fn expectDashboardTextCommand(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: []const u8) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingDashboardCommand;
    switch (command_ref.command) {
        .draw_text => |text| try std.testing.expectEqualStrings(expected, text.text),
        else => return error.UnexpectedDashboardCommand,
    }
}

fn dashboardTextCommandOriginY(display_list: canvas.DisplayList, id: canvas.ObjectId) !f32 {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingDashboardCommand;
    return switch (command_ref.command) {
        .draw_text => |text| text.origin.y,
        else => error.UnexpectedDashboardCommand,
    };
}

fn dashboardRoundedRectCommandWidth(display_list: canvas.DisplayList, id: canvas.ObjectId) !f32 {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingDashboardCommand;
    return switch (command_ref.command) {
        .fill_rounded_rect => |rounded| rounded.rect.width,
        else => error.UnexpectedDashboardCommand,
    };
}

fn expectDashboardFillRectFrame(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: geometry.RectF) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingDashboardCommand;
    switch (command_ref.command) {
        .fill_rect => |fill| try expectDashboardRect(fill.rect, expected),
        else => return error.UnexpectedDashboardCommand,
    }
}

fn expectDashboardFillRectColor(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: canvas.Color) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingDashboardCommand;
    switch (command_ref.command) {
        .fill_rect => |fill| switch (fill.fill) {
            .color => |actual| try std.testing.expectEqualDeep(expected, actual),
            else => return error.UnexpectedDashboardCommand,
        },
        else => return error.UnexpectedDashboardCommand,
    }
}

fn expectDashboardRoundedRectFrame(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: geometry.RectF) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingDashboardCommand;
    switch (command_ref.command) {
        .fill_rounded_rect => |rounded| try expectDashboardRect(rounded.rect, expected),
        else => return error.UnexpectedDashboardCommand,
    }
}

fn expectDashboardRoundedRectColor(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: canvas.Color) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingDashboardCommand;
    switch (command_ref.command) {
        .fill_rounded_rect => |rounded| switch (rounded.fill) {
            .color => |actual| try std.testing.expectEqualDeep(expected, actual),
            else => return error.UnexpectedDashboardCommand,
        },
        else => return error.UnexpectedDashboardCommand,
    }
}

fn resetDashboardDirty(runtime: *zero_native.Runtime) void {
    runtime.invalidated = false;
    runtime.dirty_region_count = 0;
}

fn expectCompactDashboardDirty(runtime: *const zero_native.Runtime, max_width: f32, max_height: f32) !void {
    const regions = runtime.pendingDirtyRegions();
    try std.testing.expect(regions.len > 0);

    var dirty_area: f32 = 0;
    for (regions) |region| {
        const dirty = region.normalized();
        try std.testing.expect(dirty.width > 0);
        try std.testing.expect(dirty.height > 0);
        dirty_area += dirty.width * dirty.height;
    }
    try std.testing.expect(dirty_area < max_width * max_height);
}

fn expectDashboardWidgetFrame(layout: canvas.WidgetLayoutTree, id: canvas.ObjectId, expected: geometry.RectF) !void {
    const node = layout.findById(id) orelse return error.TestUnexpectedResult;
    try expectDashboardRect(node.frame, expected);
}

fn dashboardContentRect(x: f32, y: f32, width: f32, height: f32) geometry.RectF {
    return rect(x, dashboard_content_y + y, width, height);
}

fn expectDashboardWidgetsDoNotOverlap(layout: canvas.WidgetLayoutTree, a_id: canvas.ObjectId, b_id: canvas.ObjectId) !void {
    const a = layout.findById(a_id) orelse return error.TestUnexpectedResult;
    const b = layout.findById(b_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(geometry.RectF.intersection(a.frame.normalized(), b.frame.normalized()).isEmpty());
}

fn expectDashboardRect(actual: geometry.RectF, expected: geometry.RectF) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 0.001);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 0.001);
    try std.testing.expectApproxEqAbs(expected.width, actual.width, 0.001);
    try std.testing.expectApproxEqAbs(expected.height, actual.height, 0.001);
}

fn color(r: u8, g: u8, b: u8) canvas.Color {
    return canvas.Color.rgb8(r, g, b);
}

fn rgba(r: u8, g: u8, b: u8, a: u8) canvas.Color {
    return canvas.Color.rgba8(r, g, b, a);
}

fn rect(x: f32, y: f32, width: f32, height: f32) geometry.RectF {
    return geometry.RectF.init(x, y, width, height);
}

fn pt(x: f32, y: f32) geometry.PointF {
    return geometry.PointF.init(x, y);
}

pub fn main(init: std.process.Init) !void {
    var app = GpuDashboardApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "gpu-dashboard",
        .window_title = "zero-native GPU Dashboard",
        .bundle_id = "dev.zero_native.gpu_dashboard",
        .icon_path = "assets/icon.icns",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test "gpu dashboard scene declares one full-window zero-native canvas" {
    try std.testing.expectEqual(@as(usize, 1), shell_views.len);
    try std.testing.expect(shell_views[0].kind == .gpu_surface);
    try std.testing.expect(shell_views[0].parent == null);
    try std.testing.expect(shell_views[0].fill);
    try std.testing.expect(shell_views[0].gpu_backend.? == .metal);
    try std.testing.expect(shell_views[0].gpu_pixel_format.? == .bgra8_unorm);
    try std.testing.expect(shell_views[0].gpu_present_mode.? == .timer);
    try std.testing.expect(shell_views[0].gpu_alpha_mode.? == .@"opaque");
    try std.testing.expect(shell_views[0].gpu_color_space.? == .srgb);
    try std.testing.expect(shell_views[0].gpu_vsync.?);
}

test "gpu dashboard display list builds a complete canvas scene" {
    var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildDashboardDisplayListFromWidgets(&builder);
    const display_list = builder.displayList();

    try std.testing.expectEqual(@as(usize, expected_dashboard_command_count), display_list.commandCount());
    try std.testing.expect(display_list.findCommandById(1) != null);
    try std.testing.expect(display_list.findCommandById(2) == null);
    try std.testing.expect(display_list.findCommandById(3) == null);
    try std.testing.expect(display_list.findCommandById(deployment_region_text_command_id) != null);
    try std.testing.expect(display_list.findCommandById(live_button_fill_command_id) != null);
    try std.testing.expect(display_list.findCommandById(activity_scroll_track_command_id) != null);
    try std.testing.expect(display_list.findCommandById(activity_scroll_thumb_command_id) != null);
    try std.testing.expect(display_list.findCommandById(filter_popover_blur_command_id) != null);
    const bounds = display_list.bounds().?;
    try std.testing.expect(bounds.x <= 0);
    try std.testing.expect(bounds.y <= 0);
    try std.testing.expect(bounds.width >= canvas_width);
    try std.testing.expect(bounds.height >= canvas_height);
}

test "gpu dashboard layout keeps controls visually separated" {
    var nodes: [max_dashboard_widgets]canvas.WidgetLayoutNode = undefined;
    const layout = try buildDashboardWidgetLayout(&nodes);

    try std.testing.expect(layout.findById(dashboard_toolbar_id) == null);
    try std.testing.expect(layout.findById(dashboard_toolbar_title_id) == null);
    try expectDashboardWidgetFrame(layout, dashboard_toolbar_mode_id, rect(252, 12, 214, 30));
    try expectDashboardWidgetFrame(layout, dashboard_toolbar_refresh_id, rect(484, 12, 86, 30));
    try std.testing.expect(layout.findById(dashboard_toolbar_separator_id) == null);
    try expectDashboardWidgetFrame(layout, dashboard_content_stack_id, rect(0, dashboard_content_y, canvas_width, dashboard_content_height));
    try expectDashboardWidgetFrame(layout, dashboard_status_text_id, rect(14, dashboard_content_y + dashboard_content_height + 8, canvas_width - 28, 18));
    try expectDashboardWidgetFrame(layout, 103, dashboardContentRect(688, 50, 122, 34));
    try expectDashboardWidgetFrame(layout, 104, dashboardContentRect(236, 128, 332, 76));
    try expectDashboardWidgetFrame(layout, 108, dashboardContentRect(236, 248, 332, 164));
    try expectDashboardWidgetFrame(layout, 109, dashboardContentRect(236, 216, 332, 10));
    try expectDashboardWidgetFrame(layout, 120, dashboardContentRect(596, 238, 196, 112));
    try expectDashboardWidgetFrame(layout, 130, dashboardContentRect(236, 426, 556, 64));
    try expectDashboardWidgetFrame(layout, 140, dashboardContentRect(596, 92, 196, 118));
    try expectDashboardWidgetFrame(layout, 150, dashboardContentRect(260, 306, 284, 28));
    try expectDashboardWidgetFrame(layout, 131, dashboardContentRect(250, 442, 116, 30));
    try expectDashboardWidgetFrame(layout, 132, dashboardContentRect(380, 442, 128, 30));
    try expectDashboardWidgetFrame(layout, 133, dashboardContentRect(522, 443, 94, 28));
    try expectDashboardWidgetFrame(layout, 134, dashboardContentRect(682, 445, 78, 24));

    try expectDashboardWidgetsDoNotOverlap(layout, 103, 140);
    try expectDashboardWidgetsDoNotOverlap(layout, 104, 140);
    try expectDashboardWidgetsDoNotOverlap(layout, 104, 109);
    try expectDashboardWidgetsDoNotOverlap(layout, 109, 108);
    try expectDashboardWidgetsDoNotOverlap(layout, 108, 120);
    try expectDashboardWidgetsDoNotOverlap(layout, 108, 130);
    try expectDashboardWidgetsDoNotOverlap(layout, 120, 130);
    try expectDashboardWidgetsDoNotOverlap(layout, 131, 132);
    try expectDashboardWidgetsDoNotOverlap(layout, 132, 133);
    try expectDashboardWidgetsDoNotOverlap(layout, 133, 134);
}

test "gpu dashboard display list renders through the reference surface" {
    var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildDashboardDisplayListFromWidgets(&builder);
    const display_list = builder.displayList();

    var render_commands: [max_dashboard_commands]canvas.RenderCommand = undefined;
    var render_batches: [max_dashboard_commands]canvas.RenderBatch = undefined;
    var pipeline_cache_entries: [max_dashboard_pipelines]canvas.RenderPipelineCacheEntry = undefined;
    var pipeline_cache_actions: [max_dashboard_pipelines * 2]canvas.RenderPipelineCacheAction = undefined;
    var layers: [max_dashboard_commands]canvas.RenderLayer = undefined;
    var layer_cache_entries: [max_dashboard_commands]canvas.RenderLayerCacheEntry = undefined;
    var layer_cache_actions: [max_dashboard_commands * 2]canvas.RenderLayerCacheAction = undefined;
    var resources: [max_dashboard_commands]canvas.RenderResource = undefined;
    var cache_entries: [max_dashboard_commands]canvas.RenderResourceCacheEntry = undefined;
    var cache_actions: [max_dashboard_commands * 2]canvas.RenderResourceCacheAction = undefined;
    var visual_effects: [max_dashboard_commands]canvas.VisualEffect = undefined;
    var visual_effect_cache_entries: [max_dashboard_commands]canvas.VisualEffectCacheEntry = undefined;
    var visual_effect_cache_actions: [max_dashboard_commands * 2]canvas.VisualEffectCacheAction = undefined;
    var glyphs: [zero_native.runtime.max_canvas_glyphs_per_view]canvas.GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [zero_native.runtime.max_canvas_glyphs_per_view]canvas.GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [zero_native.runtime.max_canvas_glyphs_per_view * 2]canvas.GlyphAtlasCacheAction = undefined;
    var text_layout_plans: [max_dashboard_commands]canvas.TextLayoutPlan = undefined;
    var text_layout_lines: [zero_native.runtime.max_canvas_glyphs_per_view]canvas.TextLine = undefined;
    var text_layout_cache_entries: [max_dashboard_commands]canvas.TextLayoutCacheEntry = undefined;
    var text_layout_cache_actions: [max_dashboard_commands * 2]canvas.TextLayoutCacheAction = undefined;
    var changes: [max_dashboard_commands * 2 + 1]canvas.DiffChange = undefined;
    const frame = try dashboardFrame(display_list, null, .{
        .surface_size = geometry.SizeF.init(canvas_width, canvas_height),
        .full_repaint = true,
    }, dashboardFrameStorage(&render_commands, &render_batches, &pipeline_cache_entries, &pipeline_cache_actions, &layers, &layer_cache_entries, &layer_cache_actions, &resources, &cache_entries, &cache_actions, &visual_effects, &visual_effect_cache_entries, &visual_effect_cache_actions, &glyphs, &glyph_cache_entries, &glyph_cache_actions, &text_layout_plans, &text_layout_lines, &text_layout_cache_entries, &text_layout_cache_actions, &changes));

    try std.testing.expect(frame.requiresRender());
    try std.testing.expect(frame.batch_plan.batchCount() >= 8);
    try std.testing.expect(frame.pipeline_cache_plan.entryCount() >= 4);
    try std.testing.expect(frame.pipeline_cache_plan.uploadCount() >= 4);
    try std.testing.expectEqual(@as(usize, 1), frame.layer_plan.layerCount());
    try std.testing.expectEqual(@as(usize, 1), frame.layer_cache_plan.uploadCount());
    try std.testing.expect(frame.resource_plan.resourceCount() >= 8);
    try std.testing.expect(frame.visual_effect_plan.effectCount() >= 4);
    try std.testing.expect(frame.visual_effect_plan.shadowCount() >= 3);
    try std.testing.expect(frame.visual_effect_plan.blurCount() >= 1);
    try std.testing.expect(frame.visual_effect_cache_plan.uploadCount() >= 4);
    try std.testing.expect(frame.text_layout_plan.planCount() >= 10);
    var encoder_commands: [max_dashboard_glyphs + max_dashboard_commands * 3]canvas.RenderEncoderCommand = undefined;
    const encoder_plan = try frame.renderPass().encoderPlan(&encoder_commands);
    try std.testing.expectEqual(frame.batch_plan.batchCount(), encoder_plan.drawBatchCount());
    try std.testing.expect(encoder_plan.cacheActionCount() >= frame.pipeline_cache_plan.actionCount());

    const pixel_count = canvas_pixel_width * @as(usize, @intFromFloat(canvas_height)) * 4;
    const pixels = try std.testing.allocator.alloc(u8, pixel_count);
    defer std.testing.allocator.free(pixels);
    const scratch = try std.testing.allocator.alloc(u8, pixel_count);
    defer std.testing.allocator.free(scratch);
    @memset(pixels, 0);
    const surface = try canvas.ReferenceRenderSurface.initWithScratch(canvas_pixel_width, @intFromFloat(canvas_height), pixels, scratch);
    try surface.renderPass(frame.renderPass(), color(0, 0, 0));

    try std.testing.expectEqual(@as(u64, expected_dashboard_reference_signature), referenceSurfaceSignature(pixels));
    try expectVisiblePixel(surface.pixelRgba8(8, 8));
    try expectVisiblePixel(surface.pixelRgba8(64, 64));
    try expectVisiblePixel(surface.pixelRgba8(240, 140));
    try std.testing.expectEqual(@as(u8, 255), surface.pixelRgba8(236, 134)[3]);
}

test "gpu dashboard render overrides animate without rebuilding commands" {
    var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildDashboardDisplayListFromWidgets(&builder);
    const display_list = builder.displayList();

    const motion = dashboardWidgetTokens().motion;
    const animations = [_]canvas.CanvasRenderAnimation{motion.animation(.{
        .id = live_button_fill_command_id,
        .start_ns = 1_000_000_000,
        .duration = .slow,
        .from_opacity = 0.72,
        .to_opacity = 1,
        .from_transform = canvas.Affine.translate(0, -6),
        .to_transform = canvas.Affine.identity(),
    })};
    try std.testing.expectEqual(@as(u32, 900), animations[0].duration_ms);
    try std.testing.expectEqual(canvas.Easing.emphasized, animations[0].easing);
    var overrides: [1]canvas.CanvasRenderOverride = undefined;
    const sampled = try canvas.sampleCanvasRenderAnimations(&animations, 1_400_000_000, &overrides);
    try std.testing.expectEqual(@as(usize, 1), sampled.len);

    var render_commands: [max_dashboard_commands]canvas.RenderCommand = undefined;
    var render_batches: [max_dashboard_commands]canvas.RenderBatch = undefined;
    var pipeline_cache_entries: [max_dashboard_pipelines]canvas.RenderPipelineCacheEntry = undefined;
    var pipeline_cache_actions: [max_dashboard_pipelines * 2]canvas.RenderPipelineCacheAction = undefined;
    var layers: [max_dashboard_commands]canvas.RenderLayer = undefined;
    var layer_cache_entries: [max_dashboard_commands]canvas.RenderLayerCacheEntry = undefined;
    var layer_cache_actions: [max_dashboard_commands * 2]canvas.RenderLayerCacheAction = undefined;
    var resources: [max_dashboard_commands]canvas.RenderResource = undefined;
    var cache_entries: [max_dashboard_commands]canvas.RenderResourceCacheEntry = undefined;
    var cache_actions: [max_dashboard_commands * 2]canvas.RenderResourceCacheAction = undefined;
    var visual_effects: [max_dashboard_commands]canvas.VisualEffect = undefined;
    var visual_effect_cache_entries: [max_dashboard_commands]canvas.VisualEffectCacheEntry = undefined;
    var visual_effect_cache_actions: [max_dashboard_commands * 2]canvas.VisualEffectCacheAction = undefined;
    var glyphs: [zero_native.runtime.max_canvas_glyphs_per_view]canvas.GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [zero_native.runtime.max_canvas_glyphs_per_view]canvas.GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [zero_native.runtime.max_canvas_glyphs_per_view * 2]canvas.GlyphAtlasCacheAction = undefined;
    var text_layout_plans: [max_dashboard_commands]canvas.TextLayoutPlan = undefined;
    var text_layout_lines: [zero_native.runtime.max_canvas_glyphs_per_view]canvas.TextLine = undefined;
    var text_layout_cache_entries: [max_dashboard_commands]canvas.TextLayoutCacheEntry = undefined;
    var text_layout_cache_actions: [max_dashboard_commands * 2]canvas.TextLayoutCacheAction = undefined;
    var changes: [max_dashboard_commands * 2 + 1]canvas.DiffChange = undefined;
    var gpu_commands: [max_dashboard_commands]canvas.CanvasGpuCommand = undefined;

    const frame = try dashboardFrame(display_list, display_list, .{
        .surface_size = geometry.SizeF.init(canvas_width, canvas_height),
        .render_overrides = sampled,
    }, dashboardFrameStorage(&render_commands, &render_batches, &pipeline_cache_entries, &pipeline_cache_actions, &layers, &layer_cache_entries, &layer_cache_actions, &resources, &cache_entries, &cache_actions, &visual_effects, &visual_effect_cache_entries, &visual_effect_cache_actions, &glyphs, &glyph_cache_entries, &glyph_cache_actions, &text_layout_plans, &text_layout_lines, &text_layout_cache_entries, &text_layout_cache_actions, &changes));

    try std.testing.expect(frame.requiresRender());
    try std.testing.expect(frame.pipeline_cache_plan.entryCount() >= 4);
    try std.testing.expectEqual(@as(usize, 2), frame.layer_plan.layerCount());
    try std.testing.expectEqual(@as(usize, 2), frame.layer_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), frame.renderPass().layerActionCount());
    try std.testing.expect(frame.visual_effect_plan.effectCount() >= 4);
    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try std.testing.expect(frame.dirty_bounds != null);

    const packet = try frame.gpuPacket(&gpu_commands);
    try std.testing.expect(packet.requiresRender());
    try std.testing.expect(packet.fullyRepresentable());
    var found_transformed_live_button = false;
    for (packet.commands) |command| {
        if (command.id) |id| {
            if (id == live_button_fill_command_id) {
                try std.testing.expect(command.transform.ty < 0);
                found_transformed_live_button = true;
            }
        }
    }
    try std.testing.expect(found_transformed_live_button);
}

test "gpu dashboard scheduled animations render without display list rebuild" {
    var harness: zero_native.TestHarness() = undefined;
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    var app = GpuDashboardApp{};
    defer app.deinit();
    try harness.start(app.app());

    const start_ns: u64 = 1_000_000_000;
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = start_ns,
        .nonblank = true,
    } });
    try std.testing.expect(app.canvas_installed);
    const initial_frame = try harness.runtime.gpuSurfaceFrame(1, "dashboard-canvas");
    try std.testing.expect(initial_frame.canvas_revision > 0);
    try std.testing.expectEqual(@as(usize, expected_dashboard_command_count), initial_frame.canvas_command_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);

    const animation_frame = try harness.runtime.nextCanvasFrame(1, "dashboard-canvas", .{
        .frame_index = 2,
        .timestamp_ns = start_ns + 450_000_000,
        .surface_size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale = 2,
    }, app.frameStorage());
    const animation_view_frame = try harness.runtime.gpuSurfaceFrame(1, "dashboard-canvas");
    try std.testing.expectEqual(initial_frame.canvas_revision, animation_view_frame.canvas_revision);
    try std.testing.expectEqual(@as(usize, expected_dashboard_command_count), animation_frame.display_list.commandCount());
    try std.testing.expect(animation_frame.requiresRender());
    try std.testing.expect(!animation_frame.full_repaint);
    try std.testing.expectEqual(@as(usize, 0), animation_frame.changes.len);
    try std.testing.expect(animation_frame.dirty_bounds != null);
    try std.testing.expect(animation_frame.layer_plan.opacityLayerCount() > 0);
    try std.testing.expect(animation_frame.layer_plan.transformLayerCount() > 0);
    try std.testing.expect(animation_frame.layer_cache_plan.uploadCount() > 0);
    try std.testing.expectEqual(@as(usize, 0), animation_frame.pipeline_cache_plan.uploadCount());
    try std.testing.expect(animation_frame.text_layout_plan.planCount() >= 10);
    try std.testing.expectEqual(@as(usize, 0), animation_frame.text_layout_cache_plan.uploadCount());
    try std.testing.expect(animation_frame.text_layout_cache_plan.retainCount() >= 10);
    try std.testing.expectEqual(@as(usize, 0), animation_frame.text_layout_cache_plan.evictCount());

    var gpu_commands: [max_dashboard_commands]canvas.CanvasGpuCommand = undefined;
    const packet = try animation_frame.gpuPacket(&gpu_commands);
    try std.testing.expect(packet.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), packet.unsupported_command_count);
    try std.testing.expect(packet.fullyRepresentable());
}

test "gpu dashboard app registers canvas display list on first gpu frame" {
    var harness: zero_native.TestHarness() = undefined;
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    var app = GpuDashboardApp{};
    defer app.deinit();
    try harness.start(app.app());

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app.canvas_installed);
    try std.testing.expectEqualDeep(dashboardWidgetTokensForScale(2), try harness.runtime.canvasWidgetDesignTokens(1, "dashboard-canvas"));

    var display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(usize, expected_dashboard_command_count), display_list.commandCount());
    try std.testing.expect(display_list.findCommandById(1) != null);
    try std.testing.expect(display_list.findCommandById(deployment_region_text_command_id) != null);
    try std.testing.expect(display_list.findCommandById(activity_scroll_track_command_id) != null);
    try std.testing.expect(display_list.findCommandById(activity_scroll_thumb_command_id) != null);
    try std.testing.expect(display_list.findCommandById(overview_fill_command_id) != null);
    try std.testing.expect(display_list.findCommandById(customers_fill_command_id) == null);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqualDeep(geometry.SizeF.init(canvas_width, canvas_height), harness.null_platform.gpu_surface_packet_present_surface_size);
    try std.testing.expectEqual(@as(f32, 2), harness.null_platform.gpu_surface_packet_present_scale_factor);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_representable);
    try std.testing.expect(app.pixels == null);
    try std.testing.expect(app.scratch == null);
    const animations = try harness.runtime.canvasRenderAnimations(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(usize, 2), animations.len);
    try std.testing.expectEqual(live_button_fill_command_id, animations[0].id);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), animations[0].start_ns);

    const widget_layout = try harness.runtime.canvasWidgetLayout(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(usize, 36), widget_layout.nodeCount());
    try std.testing.expectEqualStrings("Dashboard metrics", widget_layout.findById(104).?.widget.semantics.label);

    var snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expectEqual(@as(usize, 35), snapshot.widgets.len);

    const toolbar_mode = dashboardSnapshotWidget(snapshot, dashboard_toolbar_mode_id).?;
    try std.testing.expectEqualStrings("tab", toolbar_mode.role);
    try std.testing.expectEqualStrings("Dashboard mode", toolbar_mode.name);
    try std.testing.expect(toolbar_mode.actions.press);
    try std.testing.expect(toolbar_mode.actions.select);

    const toolbar_refresh = dashboardSnapshotWidget(snapshot, dashboard_toolbar_refresh_id).?;
    try std.testing.expectEqualStrings("button", toolbar_refresh.role);
    try std.testing.expectEqualStrings("Refresh dashboard", toolbar_refresh.name);
    try std.testing.expect(toolbar_refresh.actions.press);

    const initial_status = dashboardSnapshotWidget(snapshot, dashboard_status_text_id).?;
    try std.testing.expectEqualStrings("text", initial_status.role);
    try std.testing.expectEqualStrings("Dashboard display list presented on the GPU surface.", initial_status.name);

    const live_render = dashboardSnapshotWidget(snapshot, 103).?;
    try std.testing.expectEqualStrings("button", live_render.role);
    try std.testing.expectEqualStrings("Live render status", live_render.name);
    try std.testing.expect(live_render.actions.press);

    const progress = dashboardSnapshotWidget(snapshot, 109).?;
    try std.testing.expectEqualStrings("progressbar", progress.role);
    try std.testing.expectEqualStrings("Conversion progress", progress.name);

    const nav_list = dashboardSnapshotWidget(snapshot, 110).?;
    try std.testing.expectEqualStrings("list", nav_list.role);
    try std.testing.expectEqualStrings("Dashboard navigation", nav_list.name);

    const overview = dashboardSnapshotWidget(snapshot, 111).?;
    try std.testing.expectEqualStrings("listitem", overview.role);
    try std.testing.expect(overview.selected);
    try std.testing.expect(overview.list.present);
    try std.testing.expectEqual(@as(u32, 0), overview.list.item_index);
    try std.testing.expectEqual(@as(u32, 3), overview.list.item_count);

    const recent = dashboardSnapshotWidget(snapshot, 120).?;
    try std.testing.expectEqualStrings("group", recent.role);
    try std.testing.expectEqualStrings("Recent activity", recent.name);
    try std.testing.expect(recent.scroll.present);
    try std.testing.expect(recent.scroll.content_extent > recent.scroll.viewport_extent);
    try std.testing.expect(recent.actions.increment);
    try std.testing.expect(recent.actions.decrement);

    const forecast = dashboardSnapshotWidget(snapshot, 131).?;
    try std.testing.expectEqualStrings("textbox", forecast.role);
    try std.testing.expectEqualStrings("Forecast amount", forecast.name);
    try std.testing.expectEqualStrings("$13.4M", forecast.text_value);
    try std.testing.expect(forecast.actions.set_text);
    try std.testing.expect(forecast.actions.set_selection);

    const search = dashboardSnapshotWidget(snapshot, 132).?;
    try std.testing.expectEqualStrings("textbox", search.role);
    try std.testing.expectEqualStrings("Segment search", search.name);
    try std.testing.expectEqualStrings("enterprise", search.text_value);

    const auto_refresh = dashboardSnapshotWidget(snapshot, 133).?;
    try std.testing.expectEqualStrings("switch", auto_refresh.role);
    try std.testing.expectEqualStrings("Auto refresh", auto_refresh.name);
    try std.testing.expectEqual(@as(?f32, 1), auto_refresh.value);
    try std.testing.expect(auto_refresh.selected);
    try std.testing.expect(auto_refresh.actions.toggle);

    const confidence = dashboardSnapshotWidget(snapshot, 134).?;
    try std.testing.expectEqualStrings("slider", confidence.role);
    try std.testing.expectEqualStrings("Confidence threshold", confidence.name);
    try std.testing.expectApproxEqAbs(@as(f32, 0.62), confidence.value.?, 0.001);
    try std.testing.expect(confidence.actions.increment);
    try std.testing.expect(confidence.actions.decrement);

    const popover = dashboardSnapshotWidget(snapshot, 140).?;
    try std.testing.expectEqualStrings("dialog", popover.role);
    try std.testing.expectEqualStrings("Revenue filter popover", popover.name);

    const menu = dashboardSnapshotWidget(snapshot, 141).?;
    try std.testing.expectEqualStrings("menu", menu.role);
    try std.testing.expectEqualStrings("Filter options", menu.name);

    const menu_item = dashboardSnapshotWidget(snapshot, 142).?;
    try std.testing.expectEqualStrings("menuitem", menu_item.role);
    try std.testing.expectEqualStrings("Last 30 days", menu_item.name);

    const deployment_grid = dashboardSnapshotWidget(snapshot, 150).?;
    try std.testing.expectEqualStrings("grid", deployment_grid.role);
    try std.testing.expectEqualStrings("Deployment latency", deployment_grid.name);
    try std.testing.expectEqual(@as(?usize, 1), deployment_grid.grid_row_count);
    try std.testing.expectEqual(@as(?usize, 1), deployment_grid.grid_column_count);

    const deployment_cell = dashboardSnapshotWidget(snapshot, 156).?;
    try std.testing.expectEqualStrings("gridcell", deployment_cell.role);
    try std.testing.expectEqualStrings("iad1 8.6ms P95", deployment_cell.name);
    try std.testing.expectEqual(@as(?usize, 0), deployment_cell.grid_row_index);
    try std.testing.expectEqual(@as(?usize, 0), deployment_cell.grid_column_index);
    try std.testing.expect(deployment_cell.actions.select);
    try std.testing.expect(deployment_cell.actions.press);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 103 press");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, dashboard_content_height);
    try std.testing.expectEqual(@as(u32, 1), app.mode_count);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(dashboardSnapshotWidget(snapshot, 103).?.focused);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "dashboard-canvas",
        .kind = .key_down,
        .key = "tab",
    } });
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, dashboard_content_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(!dashboardSnapshotWidget(snapshot, 103).?.focused);
    try std.testing.expect(dashboardSnapshotWidget(snapshot, 105).?.focused);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "dashboard-canvas",
        .kind = .key_down,
        .key = "tab",
        .modifiers = .{ .shift = true },
    } });
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, dashboard_content_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(dashboardSnapshotWidget(snapshot, 103).?.focused);
    try std.testing.expect(!dashboardSnapshotWidget(snapshot, 105).?.focused);

    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 112 select");
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(!dashboardSnapshotWidget(snapshot, 111).?.selected);
    try std.testing.expect(dashboardSnapshotWidget(snapshot, 112).?.selected);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try std.testing.expect(display_list.findCommandById(1) != null);
    try std.testing.expect(display_list.findCommandById(deployment_region_text_command_id) != null);
    try std.testing.expect(display_list.findCommandById(overview_fill_command_id) == null);
    try std.testing.expect(display_list.findCommandById(customers_fill_command_id) != null);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 156 select");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, dashboard_content_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(dashboardSnapshotWidget(snapshot, 156).?.selected);
    try std.testing.expect(dashboardSnapshotWidget(snapshot, 156).?.focused);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 131 set-text $14.1M");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, dashboard_content_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const updated_forecast = dashboardSnapshotWidget(snapshot, 131).?;
    try std.testing.expectEqualStrings("$14.1M", updated_forecast.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 6, .end = 6 }, updated_forecast.text_selection.?);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardTextCommand(display_list, forecast_text_command_id, "$14.1M");
    const activity_y_before_scroll = try dashboardTextCommandOriginY(display_list, activity_first_text_command_id);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 131 set-composition est");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, dashboard_content_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const composing_forecast = dashboardSnapshotWidget(snapshot, 131).?;
    try std.testing.expectEqualStrings("$14.1Mest", composing_forecast.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 9, .end = 9 }, composing_forecast.text_selection.?);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 6, .end = 9 }, composing_forecast.text_composition.?);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardTextCommand(display_list, forecast_text_command_id, "$14.1Mest");
    try std.testing.expect(display_list.findCommandById(forecast_composition_command_id) != null);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 131 cancel-composition");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, dashboard_content_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const canceled_forecast = dashboardSnapshotWidget(snapshot, 131).?;
    try std.testing.expectEqualStrings("$14.1M", canceled_forecast.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 6, .end = 6 }, canceled_forecast.text_selection.?);
    try std.testing.expect(canceled_forecast.text_composition == null);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardTextCommand(display_list, forecast_text_command_id, "$14.1M");
    try std.testing.expect(display_list.findCommandById(forecast_composition_command_id) == null);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 131 set-composition !");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, dashboard_content_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const final_composing_forecast = dashboardSnapshotWidget(snapshot, 131).?;
    try std.testing.expectEqualStrings("$14.1M!", final_composing_forecast.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 6, .end = 7 }, final_composing_forecast.text_composition.?);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 131 commit-composition");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, dashboard_content_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const committed_forecast = dashboardSnapshotWidget(snapshot, 131).?;
    try std.testing.expectEqualStrings("$14.1M!", committed_forecast.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 7, .end = 7 }, committed_forecast.text_selection.?);
    try std.testing.expect(committed_forecast.text_composition == null);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardTextCommand(display_list, forecast_text_command_id, "$14.1M!");
    try std.testing.expect(display_list.findCommandById(forecast_composition_command_id) == null);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 133 toggle");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, dashboard_content_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const disabled_auto_refresh = dashboardSnapshotWidget(snapshot, 133).?;
    try std.testing.expectEqual(@as(?f32, 0), disabled_auto_refresh.value);
    try std.testing.expect(!disabled_auto_refresh.selected);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 134 increment");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, dashboard_content_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const updated_confidence = dashboardSnapshotWidget(snapshot, 134).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.67), updated_confidence.value.?, 0.001);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 52.5), try dashboardRoundedRectCommandWidth(display_list, confidence_active_command_id), 0.001);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 120 increment");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, dashboard_content_height);
    var scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(f32, 28), scrolled_layout.findById(120).?.widget.value);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expectEqual(@as(f32, 28), dashboardSnapshotWidget(snapshot, 120).?.scroll.offset);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    const activity_y_after_increment = try dashboardTextCommandOriginY(display_list, activity_first_text_command_id);
    try std.testing.expect(activity_y_after_increment < activity_y_before_scroll);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 120 decrement");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, dashboard_content_height);
    scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(f32, 0), scrolled_layout.findById(120).?.widget.value);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expectEqual(@as(f32, 0), dashboardSnapshotWidget(snapshot, 120).?.scroll.offset);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    const activity_y_after_decrement = try dashboardTextCommandOriginY(display_list, activity_first_text_command_id);
    try std.testing.expect(activity_y_after_decrement > activity_y_after_increment);

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 1_016_000_000,
        .nonblank = true,
    } });
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const status_widget = dashboardSnapshotWidget(snapshot, dashboard_status_text_id).?;
    try std.testing.expect(std.mem.indexOf(u8, status_widget.name, "Canvas frame:") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_widget.name, "risk") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_widget.name, "work units") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_widget.name, "dirty") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_widget.name, "idle risk") != null);

    const frame = try harness.runtime.gpuSurfaceFrame(1, "dashboard-canvas");
    try std.testing.expect(frame.canvas_revision > 1);
    try std.testing.expectEqual(@as(usize, expected_dashboard_interaction_command_count), frame.canvas_command_count);
    try std.testing.expect(!frame.canvas_frame_requires_render);
    try std.testing.expect(!frame.canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_change_count);
    try std.testing.expect(frame.canvas_frame_dirty_bounds == null);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_batch_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_encoder_command_count);
    try std.testing.expectEqual(frame.canvas_frame_batch_count, frame.canvas_frame_encoder_draw_batch_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_pipeline_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_pipeline_retain_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_profile_work_units);
    try std.testing.expectEqual(zero_native.platform.CanvasFrameProfileRisk.idle, frame.canvas_frame_profile_risk);
}

test "gpu dashboard follows system appearance tokens" {
    var harness: zero_native.TestHarness() = undefined;
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    var app = GpuDashboardApp{};
    defer app.deinit();
    const app_handle = app.app();
    try harness.start(app_handle);

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = default_canvas_size,
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqualDeep(dashboardWidgetTokensForSchemeAndScale(.light, 2), try harness.runtime.canvasWidgetDesignTokens(1, "dashboard-canvas"));
    var display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardFillRectColor(display_list, 1, dashboardWidgetTokensForSchemeAndScale(.light, 2).colors.background);
    try std.testing.expect(display_list.findCommandById(3) == null);

    const packet_count_before_dark = harness.null_platform.gpu_surface_packet_present_count;
    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .appearance_changed = .{ .color_scheme = .dark, .reduce_motion = true, .high_contrast = true } });
    try std.testing.expectEqual(zero_native.ColorScheme.dark, app.color_scheme);
    try std.testing.expect(app.reduce_motion);
    try std.testing.expect(app.high_contrast);
    try std.testing.expectEqualDeep(dashboardWidgetTokensForSchemeScaleMotionAndContrast(.dark, 2, true, true), try harness.runtime.canvasWidgetDesignTokens(1, "dashboard-canvas"));
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_count > packet_count_before_dark);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardFillRectColor(display_list, 1, dashboardWidgetTokensForSchemeScaleMotionAndContrast(.dark, 2, true, true).colors.background);
    try std.testing.expect(display_list.findCommandById(3) == null);
    const snapshot = harness.runtime.automationSnapshot("Dashboard");
    const status_widget = dashboardSnapshotWidget(snapshot, dashboard_status_text_id).?;
    try std.testing.expect(std.mem.indexOf(u8, status_widget.name, "Dashboard theme: dark from system appearance.") != null);
}

test "gpu dashboard app rebuilds retained scene for resized gpu surfaces" {
    var harness: zero_native.TestHarness() = undefined;
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    var app = GpuDashboardApp{};
    defer app.deinit();
    const app_handle = app.app();
    try harness.start(app_handle);

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = default_canvas_size,
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app.canvas_installed);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);

    const resized_size = geometry.SizeF.init(canvas_width + 240, canvas_height + 160);
    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = "dashboard-canvas",
        .frame = geometry.RectF.init(0, 0, resized_size.width, resized_size.height),
        .scale_factor = 2,
    } });
    const packet_count_before_resize_frame = harness.null_platform.gpu_surface_packet_present_count;
    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = resized_size,
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 1_016_000_000,
        .nonblank = true,
    } });

    try std.testing.expectEqual(packet_count_before_resize_frame + 1, harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqualDeep(resized_size, harness.null_platform.gpu_surface_packet_present_surface_size);
    const resized_frame = try harness.runtime.gpuSurfaceFrame(1, "dashboard-canvas");
    try std.testing.expect(!resized_frame.canvas_frame_requires_render);
    try std.testing.expect(!resized_frame.canvas_frame_full_repaint);
    try std.testing.expectEqualDeep(resized_size, resized_frame.size);

    const display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardFillRectFrame(display_list, 1, dashboardBackdropRect(resized_size));
    try std.testing.expect(display_list.findCommandById(3) == null);
    try expectDashboardRoundedRectFrame(display_list, 4, dashboardHeroRect(resized_size));

    const widget_layout = try harness.runtime.canvasWidgetLayout(1, "dashboard-canvas");
    try expectDashboardWidgetFrame(widget_layout, 103, dashboardContentRect(688, 50, 122, 34));
}

test "gpu dashboard frame event adapter preserves renderer diagnostics" {
    const frame = zero_native.platform.GpuFrame{
        .window_id = 7,
        .label = "dashboard-canvas",
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 42,
        .timestamp_ns = 1234,
        .first_frame_latency_ns = 54,
        .first_frame_latency_budget_ns = 150,
        .first_frame_latency_budget_exceeded_count = 0,
        .first_frame_latency_budget_ok = true,
        .nonblank = true,
        .sample_color = 0xff112233,
        .backend = .metal,
        .pixel_format = .bgra8_unorm,
        .present_mode = .timer,
        .alpha_mode = .@"opaque",
        .color_space = .srgb,
        .vsync = true,
        .status = .ready,
        .canvas_revision = 3,
        .canvas_command_count = 62,
        .canvas_frame_requires_render = true,
        .canvas_frame_full_repaint = false,
        .canvas_frame_batch_count = 12,
        .canvas_frame_encoder_command_count = 18,
        .canvas_frame_encoder_cache_action_count = 4,
        .canvas_frame_encoder_bind_pipeline_count = 5,
        .canvas_frame_encoder_draw_batch_count = 12,
        .canvas_frame_pipeline_count = 5,
        .canvas_frame_pipeline_upload_count = 1,
        .canvas_frame_pipeline_retain_count = 4,
        .canvas_frame_pipeline_evict_count = 0,
        .canvas_frame_path_geometry_count = 2,
        .canvas_frame_path_geometry_vertex_count = 36,
        .canvas_frame_path_geometry_index_count = 54,
        .canvas_frame_path_geometry_upload_count = 1,
        .canvas_frame_path_geometry_retain_count = 1,
        .canvas_frame_path_geometry_evict_count = 0,
        .canvas_frame_image_count = 3,
        .canvas_frame_image_upload_count = 1,
        .canvas_frame_image_retain_count = 2,
        .canvas_frame_image_evict_count = 0,
        .canvas_frame_layer_count = 2,
        .canvas_frame_layer_opacity_count = 1,
        .canvas_frame_layer_clip_count = 0,
        .canvas_frame_layer_transform_count = 1,
        .canvas_frame_layer_upload_count = 1,
        .canvas_frame_layer_retain_count = 1,
        .canvas_frame_layer_evict_count = 0,
        .canvas_frame_resource_count = 8,
        .canvas_frame_resource_upload_count = 2,
        .canvas_frame_resource_retain_count = 6,
        .canvas_frame_resource_evict_count = 0,
        .canvas_frame_visual_effect_count = 4,
        .canvas_frame_visual_effect_shadow_count = 3,
        .canvas_frame_visual_effect_blur_count = 1,
        .canvas_frame_visual_effect_upload_count = 1,
        .canvas_frame_visual_effect_retain_count = 3,
        .canvas_frame_visual_effect_evict_count = 0,
        .canvas_frame_glyph_atlas_entry_count = 16,
        .canvas_frame_glyph_atlas_upload_count = 2,
        .canvas_frame_glyph_atlas_retain_count = 14,
        .canvas_frame_glyph_atlas_evict_count = 0,
        .canvas_frame_text_layout_count = 10,
        .canvas_frame_text_layout_line_count = 10,
        .canvas_frame_text_layout_upload_count = 1,
        .canvas_frame_text_layout_retain_count = 9,
        .canvas_frame_text_layout_evict_count = 0,
        .canvas_frame_gpu_packet_command_count = 62,
        .canvas_frame_gpu_packet_cache_action_count = 14,
        .canvas_frame_gpu_packet_cached_resource_command_count = 11,
        .canvas_frame_gpu_packet_unsupported_command_count = 0,
        .canvas_frame_gpu_packet_representable = true,
        .canvas_frame_change_count = 0,
        .canvas_frame_budget_exceeded_count = 0,
        .canvas_frame_budget_ok = true,
        .canvas_frame_dirty_bounds = rect(10, 20, 30, 40),
        .canvas_frame_profile_work_units = 88,
        .canvas_frame_profile_risk = .moderate,
        .canvas_frame_profile_surface_area = 374400,
        .canvas_frame_profile_dirty_area = 1200,
        .canvas_frame_profile_dirty_ratio = 0.003205128,
        .widget_revision = 2,
        .widget_node_count = 10,
        .widget_semantics_count = 9,
    };
    const event_value = gpuFrameEvent(frame);

    try std.testing.expectEqual(frame.window_id, event_value.window_id);
    try std.testing.expectEqualStrings(frame.label, event_value.label);
    try std.testing.expectEqualDeep(frame.size, event_value.size);
    try std.testing.expectEqual(frame.present_mode, event_value.present_mode);
    try std.testing.expectEqual(frame.alpha_mode, event_value.alpha_mode);
    try std.testing.expectEqual(frame.color_space, event_value.color_space);
    try std.testing.expectEqual(frame.vsync, event_value.vsync);
    try std.testing.expectEqual(frame.first_frame_latency_ns, event_value.first_frame_latency_ns);
    try std.testing.expectEqual(frame.first_frame_latency_budget_ns, event_value.first_frame_latency_budget_ns);
    try std.testing.expectEqual(frame.first_frame_latency_budget_exceeded_count, event_value.first_frame_latency_budget_exceeded_count);
    try std.testing.expectEqual(frame.first_frame_latency_budget_ok, event_value.first_frame_latency_budget_ok);
    try std.testing.expectEqual(frame.canvas_frame_path_geometry_count, event_value.canvas_frame_path_geometry_count);
    try std.testing.expectEqual(frame.canvas_frame_path_geometry_vertex_count, event_value.canvas_frame_path_geometry_vertex_count);
    try std.testing.expectEqual(frame.canvas_frame_image_count, event_value.canvas_frame_image_count);
    try std.testing.expectEqual(frame.canvas_frame_layer_transform_count, event_value.canvas_frame_layer_transform_count);
    try std.testing.expectEqual(frame.canvas_frame_visual_effect_shadow_count, event_value.canvas_frame_visual_effect_shadow_count);
    try std.testing.expectEqual(frame.canvas_frame_text_layout_retain_count, event_value.canvas_frame_text_layout_retain_count);
    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_command_count, event_value.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_cache_action_count, event_value.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_cached_resource_command_count, event_value.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_unsupported_command_count, event_value.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_representable, event_value.canvas_frame_gpu_packet_representable);
    try std.testing.expectEqualDeep(frame.canvas_frame_dirty_bounds.?, event_value.canvas_frame_dirty_bounds.?);
    try std.testing.expectEqual(frame.canvas_frame_profile_work_units, event_value.canvas_frame_profile_work_units);
    try std.testing.expectEqual(frame.canvas_frame_profile_risk, event_value.canvas_frame_profile_risk);
    try std.testing.expectEqual(frame.canvas_frame_profile_surface_area, event_value.canvas_frame_profile_surface_area);
    try std.testing.expectEqual(frame.canvas_frame_profile_dirty_area, event_value.canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(frame.canvas_frame_profile_dirty_ratio, event_value.canvas_frame_profile_dirty_ratio);
    try std.testing.expectEqual(frame.widget_semantics_count, event_value.widget_semantics_count);

    var status_buffer: [128]u8 = undefined;
    const status = try dashboardFrameStatus(&status_buffer, event_value);
    try std.testing.expectEqualStrings("Canvas frame: moderate risk, 88 work units, 62 commands, 12 batches, packet ok, dirty 0%.", status);
}

fn expectVisiblePixel(pixel: [4]u8) !void {
    try std.testing.expect(pixel[3] > 0);
    try std.testing.expect(pixel[0] != 0 or pixel[1] != 0 or pixel[2] != 0);
}

fn referenceSurfaceSignature(pixels: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (pixels) |byte| {
        hash = (hash ^ byte) *% 1099511628211;
    }
    return hash;
}
