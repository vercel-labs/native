const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const canvas = zero_native.canvas;
const geometry = zero_native.geometry;

const window_width: f32 = 1180;
const window_height: f32 = 760;
const toolbar_height: f32 = 52;
const sidebar_width: f32 = 208;
const statusbar_height: f32 = 32;
const canvas_width: f32 = window_width - sidebar_width;
const canvas_height: f32 = window_height - toolbar_height - statusbar_height;
const default_canvas_size = geometry.SizeF.init(canvas_width, canvas_height);
const max_component_pipelines: usize = 8;
const max_component_commands: usize = zero_native.runtime.max_canvas_commands_per_view;
const max_component_glyphs: usize = zero_native.runtime.max_canvas_glyphs_per_view;
const max_component_widgets: usize = zero_native.runtime.max_canvas_widget_nodes_per_view;
const component_chrome_prefix_commands: usize = 1;
const component_chrome_suffix_commands: usize = 0;
const refresh_command = "components.refresh";
const theme_command = "components.theme";
const canvas_label = "components-canvas";
const primary_button_fill_id: canvas.ObjectId = 104 * 16 + 1;
const project_static_text_id: canvas.ObjectId = 111 * 16 + 3;
const project_text_id: canvas.ObjectId = 111 * 16 + 4;
const project_selection_id: canvas.ObjectId = 111 * 16 + 3;
const project_composition_id: canvas.ObjectId = 111 * 16 + 5;
const search_text_id: canvas.ObjectId = 112 * 16 + 9;
const search_selection_id: canvas.ObjectId = 112 * 16 + 8;
const search_composition_id: canvas.ObjectId = 112 * 16 + 10;
const scroll_track_id: canvas.ObjectId = 130 * 16 + 2;
const scroll_thumb_id: canvas.ObjectId = 130 * 16 + 3;
const menu_item_text_id: canvas.ObjectId = 142 * 16 + 3;
const data_cell_text_id: canvas.ObjectId = 156 * 16 + 4;
const popover_blur_id: canvas.ObjectId = 140 * 16 + 12;
const preview_image_id: canvas.ImageId = 42;
const preview_image_command_id: canvas.ObjectId = 118 * 16 + 1;

const ComponentVirtualScroll = struct {
    nav: f32 = 0,
    behavior: f32 = 28,
    data: f32 = 28,
    catalog: f32 = 0,
};

const ComponentThemeMode = enum {
    light,
    dark,
    high,

    fn next(self: ComponentThemeMode) ComponentThemeMode {
        return switch (self) {
            .light => .dark,
            .dark => .high,
            .high => .light,
        };
    }

    fn label(self: ComponentThemeMode) []const u8 {
        return switch (self) {
            .light => "Light",
            .dark => "Dark",
            .high => "High contrast",
        };
    }
};

const preview_image_pixels = [_]u8{
    38, 99,  235, 255, 16,  185, 129, 255, 250, 204, 21,  255, 244, 63,  94,  255,
    99, 102, 241, 255, 14,  165, 233, 255, 255, 255, 255, 255, 15,  23,  42,  255,
    45, 212, 191, 255, 59,  130, 246, 255, 168, 85,  247, 255, 248, 250, 252, 255,
    15, 23,  42,  255, 100, 116, 139, 255, 226, 232, 240, 255, 248, 113, 113, 255,
};

const preview_images = [_]canvas.ReferenceImage{.{
    .id = preview_image_id,
    .width = 4,
    .height = 4,
    .pixels = &preview_image_pixels,
}};

const html =
    \\<!doctype html>
    \\<html>
    \\<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>
    \\<body></body>
    \\</html>
;

const app_permissions = [_][]const u8{ zero_native.security.permission_command, zero_native.security.permission_view };
const shell_views = [_]zero_native.ShellView{
    .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = toolbar_height, .layer = 30, .role = "Toolbar" },
    .{ .label = "toolbar-title", .kind = .label, .parent = "toolbar", .x = 18, .y = 16, .width = 260, .height = 20, .layer = 31, .text = "GPU Components" },
    .{ .label = "theme-mode", .kind = .segmented_control, .parent = "toolbar", .x = 292, .y = 11, .width = 174, .height = 30, .layer = 31, .text = "Light|Dark|High", .command = theme_command },
    .{ .label = "refresh", .kind = .button, .parent = "toolbar", .x = 482, .y = 11, .width = 86, .height = 30, .layer = 31, .text = "Refresh", .command = refresh_command },
    .{ .label = "body", .kind = .split, .fill = true, .axis = .row },
    .{ .label = "sidebar", .kind = .sidebar, .parent = "body", .width = sidebar_width, .min_width = 188, .max_width = 244, .layer = 10, .role = "Navigation" },
    .{ .label = "sidebar-title", .kind = .label, .parent = "sidebar", .x = 18, .y = 22, .width = 164, .height = 20, .layer = 11, .text = "Native-first kit" },
    .{ .label = "nav-controls", .kind = .list_item, .parent = "sidebar", .x = 14, .y = 64, .width = 178, .height = 32, .layer = 11, .text = "Controls" },
    .{ .label = "nav-inputs", .kind = .list_item, .parent = "sidebar", .x = 14, .y = 102, .width = 178, .height = 32, .layer = 11, .text = "Inputs" },
    .{ .label = "nav-data", .kind = .list_item, .parent = "sidebar", .x = 14, .y = 140, .width = 178, .height = 32, .layer = 11, .text = "Data" },
    .{ .label = canvas_label, .kind = .gpu_surface, .parent = "body", .fill = true, .min_width = 640, .layer = 12, .role = "Native-rendered component canvas", .accessibility_label = "Native-rendered component gallery canvas", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
    .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = statusbar_height, .layer = 30, .role = "Status" },
    .{ .label = "status-label", .kind = .label, .parent = "statusbar", .x = 14, .y = 7, .width = 820, .height = 18, .layer = 31, .text = "Component lab waiting for the first GPU frame." },
};
const shell_windows = [_]zero_native.ShellWindow{.{
    .label = "main",
    .title = "zero-native GPU Components",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: zero_native.ShellConfig = .{ .windows = &shell_windows };

const GpuComponentsApp = struct {
    refresh_count: u32 = 0,
    theme_count: u32 = 0,
    theme_mode: ComponentThemeMode = .light,
    theme_overridden: bool = false,
    reduce_motion: bool = false,
    high_contrast: bool = false,
    canvas_installed: bool = false,
    reported_planned_frame: bool = false,
    virtual_scroll: ComponentVirtualScroll = .{},
    canvas_size: geometry.SizeF = default_canvas_size,
    pixel_snap_scale: f32 = 1,
    pixels: ?[]u8 = null,
    scratch: ?[]u8 = null,
    gpu_commands: [max_component_commands]canvas.CanvasGpuCommand = undefined,
    packet_json: [zero_native.platform.max_gpu_surface_packet_json_bytes]u8 = undefined,
    render_commands: [max_component_commands]canvas.RenderCommand = undefined,
    render_batches: [max_component_commands]canvas.RenderBatch = undefined,
    images: [max_component_commands]canvas.RenderImage = undefined,
    image_cache_entries: [max_component_commands]canvas.RenderImageCacheEntry = undefined,
    image_cache_actions: [max_component_commands * 2]canvas.RenderImageCacheAction = undefined,
    pipeline_cache_entries: [max_component_pipelines]canvas.RenderPipelineCacheEntry = undefined,
    pipeline_cache_actions: [max_component_pipelines * 2]canvas.RenderPipelineCacheAction = undefined,
    layers: [max_component_commands]canvas.RenderLayer = undefined,
    layer_cache_entries: [max_component_commands]canvas.RenderLayerCacheEntry = undefined,
    layer_cache_actions: [max_component_commands * 2]canvas.RenderLayerCacheAction = undefined,
    resources: [max_component_commands]canvas.RenderResource = undefined,
    cache_entries: [max_component_commands]canvas.RenderResourceCacheEntry = undefined,
    cache_actions: [max_component_commands * 2]canvas.RenderResourceCacheAction = undefined,
    visual_effects: [max_component_commands]canvas.VisualEffect = undefined,
    visual_effect_cache_entries: [max_component_commands]canvas.VisualEffectCacheEntry = undefined,
    visual_effect_cache_actions: [max_component_commands * 2]canvas.VisualEffectCacheAction = undefined,
    glyphs: [max_component_glyphs]canvas.GlyphAtlasEntry = undefined,
    glyph_cache_entries: [max_component_glyphs]canvas.GlyphAtlasCacheEntry = undefined,
    glyph_cache_actions: [max_component_glyphs * 2]canvas.GlyphAtlasCacheAction = undefined,
    text_layout_plans: [max_component_commands]canvas.TextLayoutPlan = undefined,
    text_layout_lines: [max_component_glyphs]canvas.TextLine = undefined,
    text_layout_cache_entries: [max_component_commands]canvas.TextLayoutCacheEntry = undefined,
    text_layout_cache_actions: [max_component_commands * 2]canvas.TextLayoutCacheAction = undefined,
    changes: [max_component_commands * 2 + 1]canvas.DiffChange = undefined,

    fn app(self: *@This()) zero_native.App {
        return .{
            .context = self,
            .name = "gpu-components",
            .source = zero_native.WebViewSource.html(html),
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
                } else if (std.mem.eql(u8, command.name, theme_command)) {
                    try self.changeTheme(runtime, command);
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
        if (!std.mem.eql(u8, frame_event.label, canvas_label)) return;
        const first_install = !self.canvas_installed;
        const scale_changed = self.updatePixelSnapScale(frame_event.scale_factor);
        const size_changed = self.updateCanvasSize(componentSurfaceSize(frame_event.size));
        if (first_install or scale_changed or size_changed) {
            try installComponentsCanvasModel(runtime, frame_event.window_id, self.virtual_scroll, self.componentTokens(), self.canvas_size);
            _ = try self.presentComponentsCanvas(runtime, frame_event, true);
            if (first_install) {
                try self.updateStatus(runtime, frame_event.window_id, "Component lab display list presented on the GPU surface.");
            }
            self.canvas_installed = true;
            return;
        }

        _ = try self.presentComponentsCanvas(runtime, frame_event, frame_event.canvas_frame_full_repaint);
        const current_frame = try runtime.gpuSurfaceFrame(frame_event.window_id, canvas_label);
        try self.reportFrameStatus(runtime, gpuFrameEvent(current_frame));
    }

    fn handleWidgetPointer(self: *@This(), runtime: *zero_native.Runtime, pointer_event: zero_native.runtime.CanvasWidgetPointerEvent) anyerror!void {
        if (!std.mem.eql(u8, pointer_event.view_label, canvas_label)) return;
        const target = pointer_event.target orelse return;
        switch (pointer_event.pointer.phase) {
            .up => try self.reportWidgetInteraction(runtime, pointer_event.window_id, "Clicked", target.id),
            .wheel => {
                _ = try self.scrollVirtualWidget(runtime, pointer_event);
            },
            else => {},
        }
    }

    fn handleWidgetKeyboard(self: *@This(), runtime: *zero_native.Runtime, keyboard_event: zero_native.runtime.CanvasWidgetKeyboardEvent) anyerror!void {
        if (!std.mem.eql(u8, keyboard_event.view_label, canvas_label)) return;
        if (keyboard_event.keyboard.phase != .key_down) return;
        const target = keyboard_event.target orelse return;
        const scrolled_id = try self.scrollVirtualWidgetFromKeyboard(runtime, keyboard_event) orelse target.id;
        try self.reportWidgetInteraction(runtime, keyboard_event.window_id, "Keyed", scrolled_id);
    }

    fn reportWidgetInteraction(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId, action: []const u8, id: canvas.ObjectId) anyerror!void {
        const layout = try runtime.canvasWidgetLayout(window_id, canvas_label);
        const node = layout.findById(id) orelse return;
        const widget = node.widget;
        var status_buffer: [192]u8 = undefined;
        const status = switch (widget.kind) {
            .checkbox, .radio, .toggle => try std.fmt.bufPrint(
                &status_buffer,
                "{s} {s} #{d}: {s}.",
                .{ action, @tagName(widget.kind), id, if (widget.state.selected or widget.value >= 0.5) "on" else "off" },
            ),
            .slider, .progress => try std.fmt.bufPrint(
                &status_buffer,
                "{s} {s} #{d}: value {d:.2}.",
                .{ action, @tagName(widget.kind), id, widget.value },
            ),
            .scroll_view, .list, .data_grid => try std.fmt.bufPrint(
                &status_buffer,
                "{s} {s} #{d}: offset {d}.",
                .{ action, @tagName(widget.kind), id, widget.value },
            ),
            .text_field, .search_field, .textarea => try std.fmt.bufPrint(
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

    fn scrollVirtualWidget(self: *@This(), runtime: *zero_native.Runtime, pointer_event: zero_native.runtime.CanvasWidgetPointerEvent) anyerror!?canvas.ObjectId {
        const id = componentVirtualScrollTarget(pointer_event.route) orelse return null;
        const layout = try runtime.canvasWidgetLayout(pointer_event.window_id, canvas_label);
        const node = layout.findById(id) orelse return null;
        if (!node.widget.layout.virtualized) return null;

        const viewport = node.frame.inset(node.widget.layout.padding).normalized();
        if (viewport.isEmpty()) return null;

        const max_offset = @max(0, canvas.virtualWidgetScrollContentExtent(node.widget, viewport.height) - viewport.height);
        const current = self.componentVirtualScrollValue(id) orelse return null;
        const delta = pointer_event.pointer.delta.dy * self.componentTokens().scroll.wheel_multiplier;
        const next = clampComponentVirtualScrollOffset(current + delta, max_offset, current);
        if (next == current) return id;

        try self.setComponentVirtualScrollValue(id, next);
        try self.updateComponentsCanvasModel(runtime, pointer_event.window_id);
        return id;
    }

    fn scrollVirtualWidgetFromKeyboard(self: *@This(), runtime: *zero_native.Runtime, keyboard_event: zero_native.runtime.CanvasWidgetKeyboardEvent) anyerror!?canvas.ObjectId {
        if (keyboard_event.keyboard.modifiers.hasNavigationModifier()) return null;
        const target = keyboard_event.target orelse return null;
        const id = componentVirtualScrollTarget(keyboard_event.route) orelse return null;
        const layout = try runtime.canvasWidgetLayout(keyboard_event.window_id, canvas_label);
        const node = layout.findById(id) orelse return null;
        if (!node.widget.layout.virtualized) return null;

        const viewport = node.frame.inset(node.widget.layout.padding).normalized();
        if (viewport.isEmpty()) return null;

        const direct_target = target.id == id;
        const max_offset = @max(0, canvas.virtualWidgetScrollContentExtent(node.widget, viewport.height) - viewport.height);
        const current = self.componentVirtualScrollValue(id) orelse return null;
        const raw_next = if (componentVirtualKeyboardScrollTarget(keyboard_event.keyboard, direct_target)) |scroll_target| switch (scroll_target) {
            .start => 0,
            .end => max_offset,
        } else if (componentVirtualKeyboardScrollDelta(viewport.height, keyboard_event.keyboard, direct_target)) |delta|
            std.math.clamp(current + delta, 0, max_offset)
        else
            return null;
        const next = snapComponentVirtualScrollOffset(node.widget, current, raw_next, max_offset);
        if (next == current) return id;

        try self.setComponentVirtualScrollValue(id, next);
        try self.updateComponentsCanvasModel(runtime, keyboard_event.window_id);
        return id;
    }

    fn refresh(self: *@This(), runtime: *zero_native.Runtime, command: zero_native.CommandEvent) anyerror!void {
        self.refresh_count += 1;
        self.virtual_scroll = .{};
        const gpu_frame = try runtime.gpuSurfaceFrame(command.window_id, canvas_label);
        _ = self.updateCanvasSize(componentSurfaceSize(gpu_frame.size));
        try installComponentsCanvasModel(runtime, command.window_id, self.virtual_scroll, self.componentTokens(), self.canvas_size);
        _ = try self.presentComponentsCanvas(runtime, gpuFrameEvent(gpu_frame), true);

        var status_buffer: [160]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "Component lab refreshed from {s}. Count {d}.", .{ @tagName(command.source), self.refresh_count });
        try self.updateStatus(runtime, command.window_id, status);
    }

    fn changeTheme(self: *@This(), runtime: *zero_native.Runtime, command: zero_native.CommandEvent) anyerror!void {
        self.theme_count += 1;
        self.theme_overridden = true;
        self.theme_mode = self.theme_mode.next();
        const gpu_frame = try runtime.gpuSurfaceFrame(command.window_id, canvas_label);
        _ = self.updateCanvasSize(componentSurfaceSize(gpu_frame.size));
        try installComponentsCanvasModel(runtime, command.window_id, self.virtual_scroll, self.componentTokens(), self.canvas_size);
        _ = try self.presentComponentsCanvas(runtime, gpuFrameEvent(gpu_frame), true);

        var status_buffer: [160]u8 = undefined;
        const status = try std.fmt.bufPrint(
            &status_buffer,
            "GPU component theme: {s} from {s}. Count {d}.",
            .{ self.theme_mode.label(), @tagName(command.source), self.theme_count },
        );
        try self.updateStatus(runtime, command.window_id, status);
    }

    fn applySystemAppearance(self: *@This(), runtime: *zero_native.Runtime, appearance: zero_native.Appearance) anyerror!void {
        const motion_changed = self.reduce_motion != appearance.reduce_motion;
        const contrast_changed = self.high_contrast != appearance.high_contrast;
        self.reduce_motion = appearance.reduce_motion;
        self.high_contrast = appearance.high_contrast;
        const next = componentThemeModeForAppearance(appearance);
        const theme_changed = !self.theme_overridden and self.theme_mode != next;
        if (theme_changed) self.theme_mode = next;
        if (!theme_changed and !motion_changed and !contrast_changed) return;
        if (!self.canvas_installed) return;

        const gpu_frame = runtime.gpuSurfaceFrame(1, canvas_label) catch |err| switch (err) {
            error.WindowNotFound, error.ViewNotFound, error.InvalidViewOptions => return,
            else => return err,
        };
        _ = self.updateCanvasSize(componentSurfaceSize(gpu_frame.size));
        try installComponentsCanvasModel(runtime, 1, self.virtual_scroll, self.componentTokens(), self.canvas_size);
        _ = try self.presentComponentsCanvas(runtime, gpuFrameEvent(gpu_frame), true);

        var status_buffer: [160]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "GPU component theme: {s} from system appearance.", .{self.theme_mode.label()});
        try self.updateStatus(runtime, 1, status);
    }

    fn presentComponentsCanvas(self: *@This(), runtime: *zero_native.Runtime, frame_event: zero_native.GpuSurfaceFrameEvent, full_repaint: bool) anyerror!void {
        const surface_size = componentSurfaceSize(frame_event.size);
        const scale_factor = if (frame_event.scale_factor > 0) frame_event.scale_factor else 1;
        const present_scale = referencePresentScale(scale_factor);
        const packet = runtime.presentNextCanvasGpuPacketWithScale(
            frame_event.window_id,
            canvas_label,
            .{
                .frame_index = frame_event.frame_index,
                .timestamp_ns = frame_event.timestamp_ns,
                .surface_size = surface_size,
                .scale = scale_factor,
                .full_repaint = full_repaint,
                .image_resources = &preview_images,
            },
            self.frameStorage(),
            self.componentTokens().colors.background,
            &self.gpu_commands,
            &self.packet_json,
            present_scale,
        ) catch |err| switch (err) {
            error.UnsupportedService => {
                try self.presentComponentsCanvasPixels(runtime, frame_event.window_id, surface_size, scale_factor, frame_event.frame_index, frame_event.timestamp_ns, full_repaint);
                return;
            },
            else => return err,
        };
        if (!packet.fullyRepresentable()) return error.UnsupportedCommand;
    }

    fn presentComponentsCanvasPixels(
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
            canvas_label,
            .{
                .frame_index = frame_index,
                .timestamp_ns = timestamp_ns,
                .surface_size = surface_size,
                .scale = scale_factor,
                .full_repaint = full_repaint,
                .image_resources = &preview_images,
            },
            self.frameStorage(),
            &self.gpu_commands,
            &self.packet_json,
            self.pixels.?,
            self.scratch.?,
            self.componentTokens().colors.background,
            present_scale,
        );
    }

    fn referencePresentScale(scale_factor: f32) f32 {
        const normalized = if (scale_factor > 0) scale_factor else 1;
        return normalized;
    }

    fn updateStatus(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId, text: []const u8) anyerror!void {
        _ = self;
        _ = try runtime.updateView(window_id, "status-label", .{ .text = text });
    }

    fn reportFrameStatus(self: *@This(), runtime: *zero_native.Runtime, frame_event: zero_native.GpuSurfaceFrameEvent) anyerror!void {
        if (self.reported_planned_frame or frame_event.canvas_command_count == 0) return;
        self.reported_planned_frame = true;
        var status_buffer: [160]u8 = undefined;
        const status = try componentFrameStatus(&status_buffer, frame_event);
        try self.updateStatus(runtime, frame_event.window_id, status);
    }

    fn frameStorage(self: *@This()) canvas.CanvasFrameStorage {
        return .{
            .render_commands = &self.render_commands,
            .render_batches = &self.render_batches,
            .images = &self.images,
            .image_cache_entries = &self.image_cache_entries,
            .image_cache_actions = &self.image_cache_actions,
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

    fn updateComponentsCanvasModel(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId) anyerror!void {
        var nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
        const layout = try buildComponentsWidgetLayoutWithScrollAndSize(&nodes, self.virtual_scroll, self.canvas_size);
        _ = try runtime.setCanvasWidgetLayout(window_id, canvas_label, layout);
    }

    fn componentTokens(self: @This()) canvas.DesignTokens {
        return componentTokensForScaleMotionAndContrast(self.theme_mode, self.pixel_snap_scale, self.reduce_motion, self.high_contrast);
    }

    fn updatePixelSnapScale(self: *@This(), scale_factor: f32) bool {
        const next = normalizedPixelSnapScale(scale_factor);
        if (@abs(self.pixel_snap_scale - next) < 0.001) return false;
        self.pixel_snap_scale = next;
        return true;
    }

    fn updateCanvasSize(self: *@This(), size: geometry.SizeF) bool {
        if (componentSizesEqual(self.canvas_size, size)) return false;
        self.canvas_size = size;
        return true;
    }

    fn componentVirtualScrollValue(self: *@This(), id: canvas.ObjectId) ?f32 {
        return switch (id) {
            120 => self.virtual_scroll.nav,
            130 => self.virtual_scroll.behavior,
            150 => self.virtual_scroll.data,
            180 => self.virtual_scroll.catalog,
            else => null,
        };
    }

    fn setComponentVirtualScrollValue(self: *@This(), id: canvas.ObjectId, value: f32) anyerror!void {
        switch (id) {
            120 => self.virtual_scroll.nav = value,
            130 => self.virtual_scroll.behavior = value,
            150 => self.virtual_scroll.data = value,
            180 => self.virtual_scroll.catalog = value,
            else => return error.InvalidCommand,
        }
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

fn installComponentsCanvasModel(runtime: *zero_native.Runtime, window_id: zero_native.WindowId, virtual_scroll: ComponentVirtualScroll, tokens: canvas.DesignTokens, surface_size: geometry.SizeF) anyerror!void {
    var commands: [max_component_commands]canvas.CanvasCommand = undefined;
    var nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    var builder = canvas.Builder.init(&commands);
    const layout = try buildComponentsWidgetLayoutWithScrollAndSize(&nodes, virtual_scroll, surface_size);
    try buildComponentsDisplayListForSize(&builder, layout, tokens, surface_size);
    _ = try runtime.setCanvasDisplayList(window_id, canvas_label, builder.displayList());
    _ = try runtime.setCanvasWidgetLayout(window_id, canvas_label, layout);
    _ = try runtime.emitCanvasWidgetDisplayListWithChrome(window_id, canvas_label, tokens, .{
        .prefix_command_count = component_chrome_prefix_commands,
        .suffix_command_count = component_chrome_suffix_commands,
    });
}

fn buildComponentsDisplayListFromWidgets(builder: *canvas.Builder) canvas.Error!void {
    var nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const layout = try buildComponentsWidgetLayout(&nodes);
    try buildComponentsDisplayList(builder, layout, componentTokens());
}

fn componentSurfaceSize(size: geometry.SizeF) geometry.SizeF {
    if (size.isEmpty()) return default_canvas_size;
    return .{
        .width = @max(1, size.width),
        .height = @max(1, size.height),
    };
}

fn componentVirtualScrollTarget(route: []const canvas.WidgetEventRouteEntry) ?canvas.ObjectId {
    for (route) |entry| {
        switch (entry.id) {
            120, 130, 150, 180 => return entry.id,
            else => {},
        }
    }
    return null;
}

const ComponentVirtualKeyboardScrollTarget = enum {
    start,
    end,
};

fn componentVirtualKeyboardScrollTarget(keyboard: canvas.WidgetKeyboardEvent, direct_target: bool) ?ComponentVirtualKeyboardScrollTarget {
    if (!direct_target) return null;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "home")) return .start;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "end")) return .end;
    return null;
}

fn componentVirtualKeyboardScrollDelta(viewport_extent: f32, keyboard: canvas.WidgetKeyboardEvent, direct_target: bool) ?f32 {
    const line_step = @max(24, viewport_extent * 0.35);
    const page_step = @max(line_step, viewport_extent);
    if (direct_target and (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowup"))) {
        return -line_step;
    }
    if (direct_target and (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown"))) {
        return line_step;
    }
    if (std.ascii.eqlIgnoreCase(keyboard.key, "pageup")) return -page_step;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "pagedown")) return page_step;
    return null;
}

fn snapComponentVirtualScrollOffset(widget: canvas.Widget, current: f32, raw_next: f32, max_offset: f32) f32 {
    const clamped = clampComponentVirtualScrollOffset(raw_next, max_offset, current);
    if (clamped == current or max_offset <= 0) return clamped;

    const step = componentVirtualScrollStep(widget) orelse return clamped;
    const scaled = clamped / step;
    const snapped = if (clamped > current)
        @ceil(scaled) * step
    else
        @floor(scaled) * step;
    return std.math.clamp(snapped, 0, max_offset);
}

fn clampComponentVirtualScrollOffset(raw_next: f32, max_offset: f32, fallback: f32) f32 {
    if (!std.math.isFinite(raw_next)) return fallback;
    return std.math.clamp(@max(0, raw_next), 0, @max(0, max_offset));
}

fn componentVirtualScrollStep(widget: canvas.Widget) ?f32 {
    if (!widget.layout.virtualized) return null;
    const item_extent = if (widget.layout.virtual_item_extent > 0) widget.layout.virtual_item_extent else return null;
    const step = item_extent + @max(0, widget.layout.gap);
    return if (step > 0) step else null;
}

fn componentSurfaceCardRect(surface_size: geometry.SizeF) geometry.RectF {
    const size = componentSurfaceSize(surface_size);
    return rect(28, 26, @max(916, size.width - 56), @max(616, size.height - 60));
}

fn componentSizesEqual(a: geometry.SizeF, b: geometry.SizeF) bool {
    return a.width == b.width and a.height == b.height;
}

fn buildComponentsDisplayList(builder: *canvas.Builder, layout: canvas.WidgetLayoutTree, tokens: canvas.DesignTokens) canvas.Error!void {
    return buildComponentsDisplayListForSize(builder, layout, tokens, default_canvas_size);
}

fn buildComponentsDisplayListForSize(builder: *canvas.Builder, layout: canvas.WidgetLayoutTree, tokens: canvas.DesignTokens, surface_size: geometry.SizeF) canvas.Error!void {
    try builder.fillRoundedRect(.{ .id = 3, .rect = componentSurfaceCardRect(surface_size), .radius = canvas.Radius.all(tokens.radius.xl), .fill = .{ .color = tokens.colors.surface } });
    try layout.emitDisplayList(builder, tokens);
}

fn componentTokens() canvas.DesignTokens {
    return componentTokensFor(.light);
}

fn componentTokensFor(mode: ComponentThemeMode) canvas.DesignTokens {
    return componentTokensForScale(mode, 1);
}

fn componentTokensForScale(mode: ComponentThemeMode, pixel_snap_scale: f32) canvas.DesignTokens {
    return componentTokensForScaleAndMotion(mode, pixel_snap_scale, false);
}

fn componentTokensForScaleAndMotion(mode: ComponentThemeMode, pixel_snap_scale: f32, reduce_motion: bool) canvas.DesignTokens {
    return componentTokensForScaleMotionAndContrast(mode, pixel_snap_scale, reduce_motion, false);
}

fn componentTokensForScaleMotionAndContrast(mode: ComponentThemeMode, pixel_snap_scale: f32, reduce_motion: bool, high_contrast: bool) canvas.DesignTokens {
    var tokens = canvas.DesignTokens.theme(.{
        .color_scheme = switch (mode) {
            .light => .light,
            .dark, .high => .dark,
        },
        .contrast = if (mode == .high or high_contrast) .high else .standard,
        .reduce_motion = reduce_motion,
    });
    tokens.blur = .{
        .sm = 5,
        .md = 12,
    };
    if (!reduce_motion) tokens.motion = .{ .normal_ms = 180, .slow_ms = 520, .easing = .emphasized };
    tokens.scroll = .{ .wheel_multiplier = 1.1, .wheel_velocity_scale = 72, .deceleration_per_second = 0.88, .stop_velocity = 4 };
    tokens.pixel_snap = .{ .geometry = true, .text = true, .scale = normalizedPixelSnapScale(pixel_snap_scale) };
    return tokens;
}

fn componentThemeModeForAppearance(appearance: zero_native.Appearance) ComponentThemeMode {
    return switch (appearance.color_scheme) {
        .light => .light,
        .dark => .dark,
    };
}

fn normalizedPixelSnapScale(scale_factor: f32) f32 {
    if (!std.math.isFinite(scale_factor) or scale_factor <= 0) return 1;
    return scale_factor;
}

fn buildComponentsWidgetLayout(nodes: []canvas.WidgetLayoutNode) canvas.Error!canvas.WidgetLayoutTree {
    return buildComponentsWidgetLayoutWithScroll(nodes, .{});
}

fn buildComponentsWidgetLayoutWithScroll(nodes: []canvas.WidgetLayoutNode, virtual_scroll: ComponentVirtualScroll) canvas.Error!canvas.WidgetLayoutTree {
    return buildComponentsWidgetLayoutWithScrollAndSize(nodes, virtual_scroll, default_canvas_size);
}

fn componentCatalogItems() [canvas.builtin_component_names.len]canvas.Widget {
    var items: [canvas.builtin_component_names.len]canvas.Widget = undefined;
    for (&items, 0..) |*item, index| {
        item.* = .{
            .id = @as(canvas.ObjectId, @intCast(181 + index)),
            .kind = .list_item,
            .text = canvas.builtin_component_names[index],
            .state = .{ .selected = index == 0 },
        };
    }
    return items;
}

fn buildComponentsWidgetLayoutWithScrollAndSize(nodes: []canvas.WidgetLayoutNode, virtual_scroll: ComponentVirtualScroll, surface_size: geometry.SizeF) canvas.Error!canvas.WidgetLayoutTree {
    const nav_items = [_]canvas.Widget{
        .{ .id = 121, .kind = .list_item, .text = "Controls", .state = .{ .selected = true } },
        .{ .id = 122, .kind = .list_item, .text = "Inputs" },
        .{ .id = 123, .kind = .list_item, .text = "Data" },
        .{ .id = 124, .kind = .list_item, .text = "Virtualized" },
        .{ .id = 125, .kind = .list_item, .text = "Performance" },
        .{ .id = 126, .kind = .list_item, .text = "A11y" },
    };
    const scroll_items = [_]canvas.Widget{
        .{ .id = 131, .kind = .list_item, .text = "Pointer routing" },
        .{ .id = 132, .kind = .list_item, .text = "Focus traversal" },
        .{ .id = 133, .kind = .list_item, .text = "Scroll physics" },
        .{ .id = 134, .kind = .list_item, .text = "Logical ranges" },
        .{ .id = 135, .kind = .list_item, .text = "Dirty bounds" },
    };
    const component_catalog_items = componentCatalogItems();
    const segment_controls = [_]canvas.Widget{
        .{ .id = 117, .kind = .segmented_control, .text = "Small", .size = .sm, .state = .{ .selected = true }, .semantics = .{ .label = "Small density" } },
        .{ .id = 119, .kind = .segmented_control, .text = "Large", .size = .lg, .semantics = .{ .label = "Large density" } },
    };
    const radio_controls = [_]canvas.Widget{
        .{ .id = 169, .kind = .radio, .text = "Card", .state = .{ .selected = true }, .semantics = .{ .label = "Card layout" } },
        .{ .id = 170, .kind = .radio, .text = "List", .semantics = .{ .label = "List layout" } },
    };
    const form_controls = [_]canvas.Widget{
        .{ .id = 111, .kind = .text_field, .frame = rect(0, 0, 148, 34), .text = "zero-native", .semantics = .{ .label = "Project name" } },
        .{ .id = 112, .kind = .search_field, .frame = rect(166, 0, 172, 34), .text = "components", .semantics = .{ .label = "Component search" } },
        .{ .id = 113, .kind = .checkbox, .frame = rect(0, 52, 132, 30), .text = "Selected", .state = .{ .selected = true }, .semantics = .{ .label = "Selected checkbox" } },
        .{ .id = 114, .kind = .toggle, .frame = rect(166, 52, 116, 30), .text = "Live", .value = 1, .state = .{ .selected = true }, .semantics = .{ .label = "Live toggle" } },
        .{ .id = 115, .kind = .slider, .frame = rect(0, 108, 176, 28), .value = 0.62, .semantics = .{ .label = "Density slider" } },
        .{ .id = 116, .kind = .progress, .frame = rect(202, 118, 134, 8), .value = 1, .semantics = .{ .label = "Build progress" } },
        .{ .id = 167, .kind = .row, .frame = rect(0, 148, 160, 28), .layout = .{ .gap = 10, .cross_alignment = .center }, .semantics = .{ .label = "Layout radio group" }, .children = &radio_controls },
        .{ .id = 168, .kind = .row, .frame = rect(0, 200, 148, 34), .layout = .{ .gap = 4 }, .semantics = .{ .label = "Density segments" }, .children = &segment_controls },
        .{ .id = 118, .kind = .image, .frame = rect(190, 160, 124, 54), .image_id = preview_image_id, .image_src = rect(0, 0, 4, 4), .image_fit = .cover, .image_sampling = .nearest, .image_opacity = 0.94, .semantics = .{ .label = "GPU image preview" } },
        .{ .id = 171, .kind = .textarea, .frame = rect(0, 246, 336, 72), .text = "Compose a native-rendered message", .semantics = .{ .label = "Message textarea" } },
        .{ .id = 172, .kind = .select, .frame = rect(0, 330, 180, 34), .text = "Production", .command = refresh_command, .semantics = .{ .label = "Environment select" } },
    };
    const menu_items = [_]canvas.Widget{
        .{ .id = 142, .kind = .menu_item, .text = "Copy token" },
    };
    const popover_children = [_]canvas.Widget{.{
        .id = 141,
        .kind = .menu_surface,
        .frame = rect(12, 12, 150, 64),
        .layout = .{ .gap = 2 },
        .semantics = .{ .label = "Component actions" },
        .children = &menu_items,
    }};
    const row0_cells = [_]canvas.Widget{
        .{ .id = 154, .kind = .data_cell, .text = "Focus ring", .layout = .{ .grow = 1 } },
        .{ .id = 155, .kind = .data_cell, .text = "Ready", .layout = .{ .grow = 1 } },
    };
    const row1_cells = [_]canvas.Widget{
        .{ .id = 156, .kind = .data_cell, .text = "Wheel/Home/End", .command = "components.open", .layout = .{ .grow = 1 } },
        .{ .id = 157, .kind = .data_cell, .text = "Covered", .layout = .{ .grow = 1 } },
    };
    const row2_cells = [_]canvas.Widget{
        .{ .id = 158, .kind = .data_cell, .text = "Virtual range", .layout = .{ .grow = 1 } },
        .{ .id = 159, .kind = .data_cell, .text = "Visible", .layout = .{ .grow = 1 } },
    };
    const row3_cells = [_]canvas.Widget{
        .{ .id = 161, .kind = .data_cell, .text = "Cached text", .layout = .{ .grow = 1 } },
        .{ .id = 162, .kind = .data_cell, .text = "Warm", .layout = .{ .grow = 1 } },
    };
    const row4_cells = [_]canvas.Widget{
        .{ .id = 163, .kind = .data_cell, .text = "GPU batches", .layout = .{ .grow = 1 } },
        .{ .id = 164, .kind = .data_cell, .text = "Stable", .layout = .{ .grow = 1 } },
    };
    const data_rows = [_]canvas.Widget{
        .{ .id = 151, .kind = .data_row, .frame = rect(0, 0, 0, 28), .children = &row0_cells },
        .{ .id = 152, .kind = .data_row, .frame = rect(0, 0, 0, 28), .children = &row1_cells },
        .{ .id = 153, .kind = .data_row, .frame = rect(0, 0, 0, 28), .children = &row2_cells },
        .{ .id = 165, .kind = .data_row, .frame = rect(0, 0, 0, 28), .children = &row3_cells },
        .{ .id = 166, .kind = .data_row, .frame = rect(0, 0, 0, 28), .children = &row4_cells },
    };
    const data_panel_children = [_]canvas.Widget{
        .{ .id = 150, .kind = .data_grid, .frame = rect(0, 0, 360, 28), .text = "Finished component behavior", .value = virtual_scroll.data, .layout = .{ .virtualized = true, .virtual_item_extent = 28, .virtual_overscan = 0 }, .children = &data_rows },
        .{ .id = 160, .kind = .tooltip, .frame = rect(392, 0, 176, 32), .text = "Tooltip rendered on GPU", .semantics = .{ .label = "GPU tooltip" } },
    };
    const top_widgets = [_]canvas.Widget{
        .{ .id = 101, .kind = .text, .frame = rect(64, 56, 240, 26), .text = "Finished Components", .size = .lg },
        .{ .id = 104, .kind = .button, .frame = rect(724, 54, 118, 34), .text = "Primary", .variant = .primary, .command = refresh_command, .semantics = .{ .label = "Primary action" } },
        .{ .id = 105, .kind = .icon_button, .frame = rect(856, 54, 34, 34), .text = "+", .size = .icon, .semantics = .{ .label = "Add component" } },
        .{ .id = 106, .kind = .stack, .frame = rect(64, 124, 352, 374), .semantics = .{ .label = "Input controls" }, .children = &form_controls },
        .{ .id = 120, .kind = .list, .frame = rect(456, 124, 170, 56), .value = virtual_scroll.nav, .layout = .{ .virtualized = true, .virtual_item_extent = 28, .virtual_overscan = 0 }, .semantics = .{ .label = "Component navigation" }, .children = &nav_items },
        .{ .id = 130, .kind = .scroll_view, .frame = rect(652, 124, 186, 56), .value = virtual_scroll.behavior, .layout = .{ .virtualized = true, .virtual_item_extent = 28, .virtual_overscan = 0 }, .semantics = .{ .label = "Scrollable behavior list" }, .children = &scroll_items },
        .{ .id = 179, .kind = .text, .frame = rect(652, 210, 186, 22), .text = "Built-in components", .size = .sm },
        .{ .id = 180, .kind = .list, .frame = rect(652, 238, 186, 112), .value = virtual_scroll.catalog, .layout = .{ .virtualized = true, .virtual_item_extent = 28, .virtual_overscan = 0 }, .semantics = .{ .label = "Shadcn-style built-in component catalog" }, .children = &component_catalog_items },
        .{ .id = 173, .kind = .alert, .frame = rect(652, 374, 238, 70), .text = "Web-inspired. Native-rendered.", .semantics = .{ .label = "Built-in alert" } },
        .{ .id = 174, .kind = .card, .frame = rect(456, 374, 170, 70), .text = "Card primitive", .semantics = .{ .label = "Built-in card" } },
        .{ .id = 140, .kind = .popover, .frame = rect(456, 248, 174, 88), .backdrop_blur_token = .sm, .semantics = .{ .label = "Actions popover" }, .children = &popover_children },
        .{ .id = 149, .kind = .stack, .frame = rect(64, 540, 620, 60), .semantics = .{ .label = "Data controls" }, .children = &data_panel_children },
    };
    const size = componentSurfaceSize(surface_size);
    return canvas.layoutWidgetTree(.{ .kind = .stack, .children = &top_widgets }, rect(0, 0, size.width, size.height), nodes);
}

fn componentFrame(display_list: canvas.DisplayList, previous: ?canvas.DisplayList, options: canvas.CanvasFrameOptions, storage: canvas.CanvasFrameStorage) canvas.Error!canvas.CanvasFrame {
    return display_list.framePlan(previous, options, storage);
}

fn componentFrameStorage(
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
    images: []canvas.RenderImage,
    image_cache_entries: []canvas.RenderImageCacheEntry,
    image_cache_actions: []canvas.RenderImageCacheAction,
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
        .images = images,
        .image_cache_entries = image_cache_entries,
        .image_cache_actions = image_cache_actions,
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

fn componentFrameStatus(buffer: []u8, frame_event: zero_native.GpuSurfaceFrameEvent) std.fmt.BufPrintError![]u8 {
    return std.fmt.bufPrint(
        buffer,
        "Component frame: {s} risk, {d} commands, {d} batches, packet {s}, {d} semantics nodes.",
        .{
            @tagName(frame_event.canvas_frame_profile_risk),
            frame_event.canvas_command_count,
            frame_event.canvas_frame_batch_count,
            if (frame_event.canvas_frame_gpu_packet_representable) "ok" else "fallback",
            frame_event.widget_semantics_count,
        },
    );
}

fn componentSnapshotWidget(snapshot: zero_native.automation.snapshot.Input, id: u64) ?zero_native.automation.snapshot.Widget {
    for (snapshot.widgets) |widget| {
        if (widget.id == id and std.mem.eql(u8, widget.view_label, canvas_label)) return widget;
    }
    return null;
}

fn componentViewByLabel(runtime: *const zero_native.Runtime, label: []const u8) ?zero_native.ViewInfo {
    var views_buffer: [zero_native.platform.max_views + zero_native.platform.max_webviews + 1]zero_native.ViewInfo = undefined;
    const views = runtime.listViews(1, &views_buffer);
    for (views) |view| {
        if (std.mem.eql(u8, view.label, label)) return view;
    }
    return null;
}

fn resetComponentDirty(runtime: *zero_native.Runtime) void {
    runtime.invalidated = false;
    runtime.dirty_region_count = 0;
}

fn componentWidgetCenter(runtime: *const zero_native.Runtime, id: canvas.ObjectId) !geometry.PointF {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    const node = layout.findById(id) orelse return error.TestUnexpectedResult;
    return node.frame.center();
}

fn dispatchComponentPointerClick(runtime: *zero_native.Runtime, app: zero_native.App, id: canvas.ObjectId) !void {
    const point = try componentWidgetCenter(runtime, id);
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .x = point.x,
        .y = point.y,
        .button = 0,
    } });
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_up,
        .x = point.x,
        .y = point.y,
        .button = 0,
    } });
}

fn dispatchComponentPointerWheel(runtime: *zero_native.Runtime, app: zero_native.App, id: canvas.ObjectId, delta_y: f32) !void {
    const point = try componentWidgetCenter(runtime, id);
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .scroll,
        .x = point.x,
        .y = point.y,
        .delta_y = delta_y,
    } });
}

fn dispatchComponentPointerDrag(runtime: *zero_native.Runtime, app: zero_native.App, id: canvas.ObjectId, start_ratio: f32, end_ratio: f32) !void {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    const node = layout.findById(id) orelse return error.TestUnexpectedResult;
    const start = geometry.PointF.init(node.frame.x + node.frame.width * start_ratio, node.frame.center().y);
    const end = geometry.PointF.init(node.frame.x + node.frame.width * end_ratio, node.frame.center().y);
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .x = start.x,
        .y = start.y,
        .button = 0,
    } });
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_drag,
        .x = end.x,
        .y = end.y,
        .delta_x = end.x - start.x,
        .delta_y = end.y - start.y,
        .button = 0,
    } });
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_up,
        .x = end.x,
        .y = end.y,
        .button = 0,
    } });
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
    var app = GpuComponentsApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "gpu-components",
        .window_title = "zero-native GPU Components",
        .bundle_id = "dev.zero_native.gpu_components",
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

test "gpu components scene declares native shell and gpu canvas" {
    try std.testing.expect(shell_views[0].kind == .toolbar);
    try std.testing.expect(shell_views[5].kind == .sidebar);
    try std.testing.expect(shell_views[10].kind == .gpu_surface);
    try std.testing.expect(shell_views[11].kind == .statusbar);
    try std.testing.expectEqualStrings("body", shell_views[10].parent.?);
    try std.testing.expect(shell_views[10].gpu_backend.? == .metal);
    try std.testing.expect(shell_views[10].gpu_pixel_format.? == .bgra8_unorm);
    try std.testing.expect(shell_views[10].gpu_present_mode.? == .timer);
    try std.testing.expect(shell_views[10].gpu_alpha_mode.? == .@"opaque");
    try std.testing.expect(shell_views[10].gpu_color_space.? == .srgb);
    try std.testing.expect(shell_views[10].gpu_vsync.?);
}

test "gpu components display list covers finished live controls" {
    var commands: [max_component_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildComponentsDisplayListFromWidgets(&builder);
    const display_list = builder.displayList();

    try std.testing.expect(display_list.commandCount() >= 54);
    try std.testing.expect(display_list.commandCount() <= max_component_commands);
    try std.testing.expect(display_list.findCommandById(3) != null);
    try std.testing.expect(display_list.findCommandById(primary_button_fill_id) != null);
    try std.testing.expect(display_list.findCommandById(project_static_text_id) != null);
    try std.testing.expect(display_list.findCommandById(search_text_id) != null);
    try std.testing.expect(display_list.findCommandById(scroll_track_id) != null);
    try std.testing.expect(display_list.findCommandById(scroll_thumb_id) != null);
    try std.testing.expect(display_list.findCommandById(preview_image_command_id) != null);
    try std.testing.expect(display_list.findCommandById(popover_blur_id) != null);
    try std.testing.expect(display_list.findCommandById(menu_item_text_id) != null);
    try std.testing.expect(display_list.findCommandById(data_cell_text_id) != null);
    const bounds = display_list.bounds().?;
    try std.testing.expect(bounds.x <= 28);
    try std.testing.expect(bounds.y <= 26);
    try std.testing.expect(bounds.width >= 916);
    try std.testing.expect(bounds.height >= 616);
}

test "gpu components layout keeps finished controls visually separated" {
    var nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const layout = try buildComponentsWidgetLayoutWithScroll(&nodes, .{});

    try expectComponentWidgetFrame(layout, 111, rect(64, 124, 148, 34));
    try expectComponentWidgetFrame(layout, 112, rect(230, 124, 172, 34));
    try expectComponentWidgetFrame(layout, 113, rect(64, 176, 132, 30));
    try expectComponentWidgetFrame(layout, 114, rect(230, 176, 116, 30));
    try expectComponentWidgetFrame(layout, 115, rect(64, 232, 176, 28));
    try expectComponentWidgetFrame(layout, 116, rect(266, 242, 134, 8));
    try expectComponentWidgetFrame(layout, 167, rect(64, 272, 160, 28));
    try expectComponentWidgetFrame(layout, 168, rect(64, 324, 148, 34));
    try expectComponentWidgetFrame(layout, 118, rect(254, 284, 124, 54));
    try expectComponentWidgetFrame(layout, 171, rect(64, 370, 336, 72));
    try expectComponentWidgetFrame(layout, 172, rect(64, 454, 180, 34));
    try expectComponentWidgetFrame(layout, 120, rect(456, 124, 170, 56));
    try expectComponentWidgetFrame(layout, 130, rect(652, 124, 186, 56));
    try expectComponentWidgetFrame(layout, 179, rect(652, 210, 186, 22));
    try expectComponentWidgetFrame(layout, 180, rect(652, 238, 186, 112));
    try expectComponentWidgetFrame(layout, 181, rect(652, 238, 186, 28));
    try expectComponentWidgetFrame(layout, 184, rect(652, 322, 186, 28));
    try expectComponentWidgetFrame(layout, 173, rect(652, 374, 238, 70));
    try expectComponentWidgetFrame(layout, 174, rect(456, 374, 170, 70));
    try expectComponentWidgetFrame(layout, 140, rect(456, 248, 174, 88));
    try expectComponentWidgetsDoNotOverlap(layout, 111, 112);
    try expectComponentWidgetsDoNotOverlap(layout, 113, 114);
    try expectComponentWidgetsDoNotOverlap(layout, 115, 116);
    try expectComponentWidgetsDoNotOverlap(layout, 167, 118);
    try expectComponentWidgetsDoNotOverlap(layout, 168, 118);
    try expectComponentWidgetsDoNotOverlap(layout, 171, 168);
    try expectComponentWidgetsDoNotOverlap(layout, 171, 118);
    try expectComponentWidgetsDoNotOverlap(layout, 172, 171);
    try expectComponentWidgetsDoNotOverlap(layout, 106, 120);
    try expectComponentWidgetsDoNotOverlap(layout, 120, 130);
    try expectComponentWidgetsDoNotOverlap(layout, 130, 140);
    try expectComponentWidgetsDoNotOverlap(layout, 130, 180);
    try expectComponentWidgetsDoNotOverlap(layout, 140, 180);
    try expectComponentWidgetsDoNotOverlap(layout, 173, 180);
    try expectComponentWidgetsDoNotOverlap(layout, 173, 140);
    try expectComponentWidgetsDoNotOverlap(layout, 174, 173);
    try expectComponentWidgetsDoNotOverlap(layout, 174, 140);

    try std.testing.expect(layout.findById(151) == null);
    try expectComponentWidgetFrame(layout, 150, rect(64, 540, 360, 28));
    try expectComponentWidgetFrame(layout, 152, rect(64, 540, 360, 28));
    try expectComponentWidgetFrame(layout, 156, rect(64, 540, 180, 28));
    try expectComponentWidgetFrame(layout, 157, rect(244, 540, 180, 28));
    try expectComponentWidgetFrame(layout, 160, rect(456, 540, 176, 32));
    try expectComponentWidgetsDoNotOverlap(layout, 150, 160);
    try expectComponentWidgetsDoNotOverlap(layout, 140, 149);

    var scrolled_nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const scrolled_layout = try buildComponentsWidgetLayoutWithScroll(&scrolled_nodes, .{
        .nav = 28,
        .behavior = 56,
        .data = 56,
        .catalog = 84,
    });
    try std.testing.expect(scrolled_layout.findById(121) == null);
    try expectComponentWidgetFrame(scrolled_layout, 122, rect(456, 124, 170, 28));
    try expectComponentWidgetFrame(scrolled_layout, 123, rect(456, 152, 170, 28));
    try std.testing.expect(scrolled_layout.findById(132) == null);
    try expectComponentWidgetFrame(scrolled_layout, 133, rect(652, 124, 186, 28));
    try expectComponentWidgetFrame(scrolled_layout, 134, rect(652, 152, 186, 28));
    try std.testing.expect(scrolled_layout.findById(152) == null);
    try expectComponentWidgetFrame(scrolled_layout, 153, rect(64, 540, 360, 28));
    try expectComponentWidgetFrame(scrolled_layout, 158, rect(64, 540, 180, 28));
    try expectComponentWidgetFrame(scrolled_layout, 159, rect(244, 540, 180, 28));
    try std.testing.expect(scrolled_layout.findById(181) == null);
    try expectComponentWidgetFrame(scrolled_layout, 184, rect(652, 238, 186, 28));
    try expectComponentWidgetFrame(scrolled_layout, 187, rect(652, 322, 186, 28));

    var smooth_scrolled_nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const smooth_scrolled_layout = try buildComponentsWidgetLayoutWithScroll(&smooth_scrolled_nodes, .{
        .behavior = 11,
    });
    try expectComponentWidgetFrame(smooth_scrolled_layout, 131, rect(652, 113, 186, 28));
    try expectComponentWidgetFrame(smooth_scrolled_layout, 132, rect(652, 141, 186, 28));
    try expectComponentWidgetFrame(smooth_scrolled_layout, 133, rect(652, 169, 186, 28));
}

test "gpu components combined virtual scroll state stays within display budget" {
    var commands: [max_component_commands]canvas.CanvasCommand = undefined;
    var nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    var builder = canvas.Builder.init(&commands);
    const layout = try buildComponentsWidgetLayoutWithScroll(&nodes, .{
        .nav = 28,
        .behavior = 56,
        .data = 56,
        .catalog = 84,
    });
    try buildComponentsDisplayList(&builder, layout, componentTokens());
    const display_list = builder.displayList();

    try std.testing.expect(display_list.commandCount() <= max_component_commands);
    try std.testing.expect(display_list.findCommandById(scroll_track_id) != null);
    try std.testing.expect(display_list.findCommandById(scroll_thumb_id) != null);
    try std.testing.expect(layout.findById(120).?.widget.value == 28);
    try std.testing.expect(layout.findById(130).?.widget.value == 56);
    try std.testing.expect(layout.findById(150).?.widget.value == 56);
    try std.testing.expect(layout.findById(180).?.widget.value == 84);
}

test "gpu components frame plan stays within runtime budgets" {
    var commands: [max_component_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildComponentsDisplayListFromWidgets(&builder);
    const display_list = builder.displayList();

    var render_commands: [max_component_commands]canvas.RenderCommand = undefined;
    var render_batches: [max_component_commands]canvas.RenderBatch = undefined;
    var pipeline_cache_entries: [max_component_pipelines]canvas.RenderPipelineCacheEntry = undefined;
    var pipeline_cache_actions: [max_component_pipelines * 2]canvas.RenderPipelineCacheAction = undefined;
    var layers: [max_component_commands]canvas.RenderLayer = undefined;
    var layer_cache_entries: [max_component_commands]canvas.RenderLayerCacheEntry = undefined;
    var layer_cache_actions: [max_component_commands * 2]canvas.RenderLayerCacheAction = undefined;
    var resources: [max_component_commands]canvas.RenderResource = undefined;
    var cache_entries: [max_component_commands]canvas.RenderResourceCacheEntry = undefined;
    var cache_actions: [max_component_commands * 2]canvas.RenderResourceCacheAction = undefined;
    var images: [max_component_commands]canvas.RenderImage = undefined;
    var image_cache_entries: [max_component_commands]canvas.RenderImageCacheEntry = undefined;
    var image_cache_actions: [max_component_commands * 2]canvas.RenderImageCacheAction = undefined;
    var visual_effects: [max_component_commands]canvas.VisualEffect = undefined;
    var visual_effect_cache_entries: [max_component_commands]canvas.VisualEffectCacheEntry = undefined;
    var visual_effect_cache_actions: [max_component_commands * 2]canvas.VisualEffectCacheAction = undefined;
    var glyphs: [max_component_glyphs]canvas.GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [max_component_glyphs]canvas.GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [max_component_glyphs * 2]canvas.GlyphAtlasCacheAction = undefined;
    var text_layout_plans: [max_component_commands]canvas.TextLayoutPlan = undefined;
    var text_layout_lines: [max_component_glyphs]canvas.TextLine = undefined;
    var text_layout_cache_entries: [max_component_commands]canvas.TextLayoutCacheEntry = undefined;
    var text_layout_cache_actions: [max_component_commands * 2]canvas.TextLayoutCacheAction = undefined;
    var changes: [max_component_commands * 2 + 1]canvas.DiffChange = undefined;
    const frame = try componentFrame(display_list, null, .{
        .surface_size = geometry.SizeF.init(canvas_width, canvas_height),
        .full_repaint = true,
        .image_resources = &preview_images,
    }, componentFrameStorage(&render_commands, &render_batches, &pipeline_cache_entries, &pipeline_cache_actions, &layers, &layer_cache_entries, &layer_cache_actions, &resources, &cache_entries, &cache_actions, &images, &image_cache_entries, &image_cache_actions, &visual_effects, &visual_effect_cache_entries, &visual_effect_cache_actions, &glyphs, &glyph_cache_entries, &glyph_cache_actions, &text_layout_plans, &text_layout_lines, &text_layout_cache_entries, &text_layout_cache_actions, &changes));

    try std.testing.expect(frame.requiresRender());
    try std.testing.expect(frame.batch_plan.batchCount() >= 8);
    try std.testing.expect(frame.pipeline_cache_plan.entryCount() >= 4);
    try std.testing.expectEqual(@as(usize, 1), frame.image_plan.imageCount());
    try std.testing.expectEqual(@as(usize, 1), frame.image_cache_plan.uploadCount());
    try std.testing.expect(frame.visual_effect_plan.effectCount() >= 3);
    try std.testing.expect(frame.text_layout_plan.planCount() >= 12);
    try std.testing.expect(frame.profile().work_units > 0);
    try std.testing.expect(frame.profile().surface_area > 0);
}

test "gpu components display list renders stable reference snapshot" {
    var commands: [max_component_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildComponentsDisplayListFromWidgets(&builder);
    const display_list = builder.displayList();

    var render_commands: [max_component_commands]canvas.RenderCommand = undefined;
    var render_batches: [max_component_commands]canvas.RenderBatch = undefined;
    var pipeline_cache_entries: [max_component_pipelines]canvas.RenderPipelineCacheEntry = undefined;
    var pipeline_cache_actions: [max_component_pipelines * 2]canvas.RenderPipelineCacheAction = undefined;
    var layers: [max_component_commands]canvas.RenderLayer = undefined;
    var layer_cache_entries: [max_component_commands]canvas.RenderLayerCacheEntry = undefined;
    var layer_cache_actions: [max_component_commands * 2]canvas.RenderLayerCacheAction = undefined;
    var resources: [max_component_commands]canvas.RenderResource = undefined;
    var cache_entries: [max_component_commands]canvas.RenderResourceCacheEntry = undefined;
    var cache_actions: [max_component_commands * 2]canvas.RenderResourceCacheAction = undefined;
    var images: [max_component_commands]canvas.RenderImage = undefined;
    var image_cache_entries: [max_component_commands]canvas.RenderImageCacheEntry = undefined;
    var image_cache_actions: [max_component_commands * 2]canvas.RenderImageCacheAction = undefined;
    var visual_effects: [max_component_commands]canvas.VisualEffect = undefined;
    var visual_effect_cache_entries: [max_component_commands]canvas.VisualEffectCacheEntry = undefined;
    var visual_effect_cache_actions: [max_component_commands * 2]canvas.VisualEffectCacheAction = undefined;
    var glyphs: [max_component_glyphs]canvas.GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [max_component_glyphs]canvas.GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [max_component_glyphs * 2]canvas.GlyphAtlasCacheAction = undefined;
    var text_layout_plans: [max_component_commands]canvas.TextLayoutPlan = undefined;
    var text_layout_lines: [max_component_glyphs]canvas.TextLine = undefined;
    var text_layout_cache_entries: [max_component_commands]canvas.TextLayoutCacheEntry = undefined;
    var text_layout_cache_actions: [max_component_commands * 2]canvas.TextLayoutCacheAction = undefined;
    var changes: [max_component_commands * 2 + 1]canvas.DiffChange = undefined;
    const frame = try componentFrame(display_list, null, .{
        .surface_size = geometry.SizeF.init(canvas_width, canvas_height),
        .full_repaint = true,
        .image_resources = &preview_images,
    }, componentFrameStorage(&render_commands, &render_batches, &pipeline_cache_entries, &pipeline_cache_actions, &layers, &layer_cache_entries, &layer_cache_actions, &resources, &cache_entries, &cache_actions, &images, &image_cache_entries, &image_cache_actions, &visual_effects, &visual_effect_cache_entries, &visual_effect_cache_actions, &glyphs, &glyph_cache_entries, &glyph_cache_actions, &text_layout_plans, &text_layout_lines, &text_layout_cache_entries, &text_layout_cache_actions, &changes));

    const pixel_count = @as(usize, @intFromFloat(canvas_width)) * @as(usize, @intFromFloat(canvas_height)) * 4;
    const pixels = try std.testing.allocator.alloc(u8, pixel_count);
    defer std.testing.allocator.free(pixels);
    const scratch = try std.testing.allocator.alloc(u8, pixel_count);
    defer std.testing.allocator.free(scratch);
    @memset(pixels, 0);
    const surface = (try canvas.ReferenceRenderSurface.initWithScratch(@intFromFloat(canvas_width), @intFromFloat(canvas_height), pixels, scratch)).withImages(&preview_images);
    try surface.renderPass(frame.renderPass(), color(247, 249, 252));

    try std.testing.expectEqual(@as(u64, 11237215035017349299), referenceSurfaceSignature(pixels));
    try expectVisiblePixel(surface.pixelRgba8(36, 36));
    try expectVisiblePixel(surface.pixelRgba8(92, 88));
    try expectVisiblePixel(surface.pixelRgba8(330, 160));
    try std.testing.expectEqual(@as(u8, 255), surface.pixelRgba8(288, 190)[3]);
}

test "gpu components frame event adapter preserves packet status" {
    const frame = zero_native.platform.GpuFrame{
        .window_id = 1,
        .label = canvas_label,
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 9,
        .timestamp_ns = 1_000,
        .canvas_command_count = 54,
        .canvas_frame_batch_count = 9,
        .canvas_frame_gpu_packet_command_count = 54,
        .canvas_frame_gpu_packet_cache_action_count = 12,
        .canvas_frame_gpu_packet_cached_resource_command_count = 8,
        .canvas_frame_gpu_packet_unsupported_command_count = 1,
        .canvas_frame_gpu_packet_representable = false,
        .canvas_frame_profile_risk = .low,
        .widget_semantics_count = 17,
    };
    const event_value = gpuFrameEvent(frame);

    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_command_count, event_value.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_cache_action_count, event_value.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_cached_resource_command_count, event_value.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_unsupported_command_count, event_value.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_representable, event_value.canvas_frame_gpu_packet_representable);

    var status_buffer: [128]u8 = undefined;
    const status = try componentFrameStatus(&status_buffer, event_value);
    try std.testing.expectEqualStrings("Component frame: low risk, 54 commands, 9 batches, packet fallback, 17 semantics nodes.", status);
}

test "gpu components semantics cover retained widget families" {
    var nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const layout = try buildComponentsWidgetLayout(&nodes);
    var semantics_buffer: [max_component_widgets]canvas.WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);

    try expectSemanticRole(semantics, 104, .button);
    try expectSemanticRole(semantics, 105, .button);
    try expectSemanticRole(semantics, 106, .group);
    try expectSemanticRole(semantics, 111, .textbox);
    try expectSemanticRole(semantics, 112, .textbox);
    try expectSemanticRole(semantics, 113, .checkbox);
    try expectSemanticRole(semantics, 114, .switch_control);
    try expectSemanticRole(semantics, 115, .slider);
    try expectSemanticRole(semantics, 116, .progressbar);
    try expectSemanticRole(semantics, 117, .tab);
    try expectSemanticRole(semantics, 118, .image);
    try expectSemanticRole(semantics, 119, .tab);
    try expectSemanticRole(semantics, 120, .list);
    try expectSemanticRole(semantics, 121, .listitem);
    try expectSemanticRole(semantics, 130, .group);
    try expectSemanticRole(semantics, 140, .dialog);
    try expectSemanticRole(semantics, 141, .menu);
    try expectSemanticRole(semantics, 142, .menuitem);
    try expectSemanticRole(semantics, 149, .group);
    try expectSemanticRole(semantics, 150, .grid);
    try expectSemanticRole(semantics, 152, .row);
    try expectSemanticRole(semantics, 156, .gridcell);
    try expectSemanticRole(semantics, 160, .tooltip);
    try expectSemanticRole(semantics, 167, .group);
    try expectSemanticRole(semantics, 168, .group);
    try expectSemanticRole(semantics, 169, .radio);
    try expectSemanticRole(semantics, 170, .radio);
    try expectSemanticRole(semantics, 171, .textbox);
    try expectSemanticRole(semantics, 172, .button);
    try expectSemanticRole(semantics, 173, .group);
    try expectSemanticRole(semantics, 174, .group);
    try expectSemanticRole(semantics, 180, .list);
    try expectSemanticRole(semantics, 181, .listitem);

    const slider = expectSemantic(semantics, 115);
    try std.testing.expectEqual(@as(?f32, 0.62), slider.value);
    try std.testing.expect(slider.actions.increment);
    try std.testing.expect(slider.actions.decrement);
    const nav_list = expectSemantic(semantics, 120);
    try std.testing.expect(nav_list.scroll.present);
    try std.testing.expect(nav_list.actions.increment);
    try std.testing.expect(nav_list.actions.decrement);
    const scroll = expectSemantic(semantics, 130);
    try std.testing.expect(scroll.scroll.present);
    try std.testing.expect(scroll.actions.increment);
    try std.testing.expect(scroll.actions.decrement);
    const selected_nav = expectSemantic(semantics, 121);
    try std.testing.expect(selected_nav.state.selected);
    try std.testing.expect(selected_nav.list.present);
    try std.testing.expectEqual(@as(u32, 6), selected_nav.list.item_count);
    const data_grid = expectSemantic(semantics, 150);
    try std.testing.expect(data_grid.scroll.present);
    try std.testing.expect(data_grid.actions.increment);
    try std.testing.expect(data_grid.actions.decrement);
    try std.testing.expectEqual(@as(?usize, 5), data_grid.grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), data_grid.grid_column_count);
    try std.testing.expectEqual(@as(?usize, 1), expectSemantic(semantics, 156).grid_row_index);
    const catalog = expectSemantic(semantics, 180);
    try std.testing.expect(catalog.scroll.present);
    try std.testing.expect(catalog.actions.increment);
    try std.testing.expect(catalog.actions.decrement);
    const first_catalog_item = expectSemantic(semantics, 181);
    try std.testing.expect(first_catalog_item.state.selected);
    try std.testing.expectEqual(@as(u32, canvas.builtin_component_names.len), first_catalog_item.list.item_count);
    try std.testing.expectEqualStrings(canvas.builtin_component_names[0], first_catalog_item.label);
    try std.testing.expectEqual(@as(?usize, 0), expectSemantic(semantics, 156).grid_column_index);
}

test "gpu components image widget exposes image semantics and display command" {
    const image = canvas.Widget{
        .id = 190,
        .kind = .image,
        .frame = rect(12, 14, 86, 54),
        .image_id = preview_image_id,
        .image_src = rect(0, 0, 320, 192),
        .image_fit = .cover,
        .image_sampling = .nearest,
        .image_opacity = 0.82,
        .semantics = .{ .label = "Preview image" },
    };
    var nodes: [1]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(image, image.frame, &nodes);
    var semantics_buffer: [1]canvas.WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(canvas.WidgetRole.image, semantics[0].role);
    try std.testing.expectEqualStrings("Preview image", semantics[0].label);

    var commands: [1]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try layout.emitDisplayList(&builder, componentTokens());
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 1), display_list.commandCount());
    switch (display_list.commands[0]) {
        .draw_image => |draw| {
            try std.testing.expectEqual(@as(canvas.ObjectId, 190 * 16 + 1), draw.id);
            try std.testing.expectEqual(@as(canvas.ImageId, preview_image_id), draw.image_id);
            try std.testing.expectEqual(canvas.ImageFit.cover, draw.fit);
            try std.testing.expectEqual(canvas.ImageSampling.nearest, draw.sampling);
            try std.testing.expectEqual(@as(f32, 0.82), draw.opacity);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "gpu components app registers component lab on first gpu frame" {
    var harness: zero_native.TestHarness() = undefined;
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    var app = GpuComponentsApp{};
    defer app.deinit();
    try harness.start(app.app());

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app.canvas_installed);

    var display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try std.testing.expect(display_list.commandCount() <= max_component_commands);
    try std.testing.expect(display_list.findCommandById(primary_button_fill_id) != null);
    try std.testing.expect(display_list.findCommandById(scroll_thumb_id) != null);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqualDeep(geometry.SizeF.init(canvas_width, canvas_height), harness.null_platform.gpu_surface_packet_present_surface_size);
    try std.testing.expectEqual(@as(f32, 2), harness.null_platform.gpu_surface_packet_present_scale_factor);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_representable);
    try std.testing.expect(app.pixels == null);
    try std.testing.expect(app.scratch == null);
    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, canvas_label);
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
    try std.testing.expect(!presented_frame.canvas_frame_full_repaint);
    try std.testing.expectEqual(zero_native.platform.CanvasFrameProfileRisk.idle, presented_frame.canvas_frame_profile_risk);
    try std.testing.expectEqual(@as(usize, 0), presented_frame.canvas_frame_profile_work_units);

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 1_016_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_present_count);
    const clean_frame = try harness.runtime.gpuSurfaceFrame(1, canvas_label);
    try std.testing.expect(!clean_frame.canvas_frame_requires_render);
    try std.testing.expect(!clean_frame.canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(usize, 0), clean_frame.canvas_frame_profile_work_units);

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = canvas_label,
        .frame = geometry.RectF.init(sidebar_width, toolbar_height, canvas_width + 320, canvas_height),
        .scale_factor = 2,
    } });
    const packet_count_before_resize_frame = harness.null_platform.gpu_surface_packet_present_count;
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(canvas_width + 320, canvas_height),
        .scale_factor = 2,
        .frame_index = 3,
        .timestamp_ns = 1_032_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqual(packet_count_before_resize_frame + 1, harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqualDeep(geometry.SizeF.init(canvas_width + 320, canvas_height), harness.null_platform.gpu_surface_packet_present_surface_size);
    const resized_frame = try harness.runtime.gpuSurfaceFrame(1, canvas_label);
    try std.testing.expect(!resized_frame.canvas_frame_requires_render);
    try std.testing.expect(!resized_frame.canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(f32, canvas_width + 320), resized_frame.size.width);
    try std.testing.expectEqual(@as(f32, canvas_height), resized_frame.size.height);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentRoundedRectFrame(display_list, 3, componentSurfaceCardRect(geometry.SizeF.init(canvas_width + 320, canvas_height)));

    const widget_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expect(widget_layout.nodeCount() >= 26);
    try std.testing.expectEqualStrings("Input controls", widget_layout.findById(106).?.widget.semantics.label);
    try std.testing.expect(widget_layout.findById(151) == null);
    try std.testing.expect(widget_layout.findById(152) != null);

    var snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(componentSnapshotWidget(snapshot, 104).?.actions.press);
    const project_name = componentSnapshotWidget(snapshot, 111).?;
    try std.testing.expectEqualStrings("textbox", project_name.role);
    try std.testing.expectEqualStrings("Project name", project_name.name);
    try std.testing.expectEqualStrings("zero-native", project_name.text_value);
    try std.testing.expect(project_name.actions.set_text);
    try std.testing.expect(project_name.actions.set_selection);
    const component_search = componentSnapshotWidget(snapshot, 112).?;
    try std.testing.expectEqualStrings("textbox", component_search.role);
    try std.testing.expectEqualStrings("Component search", component_search.name);
    try std.testing.expectEqualStrings("components", component_search.text_value);
    try std.testing.expect(component_search.actions.set_text);
    try std.testing.expect(component_search.actions.set_selection);
    try std.testing.expect(componentSnapshotWidget(snapshot, 113).?.actions.toggle);
    try std.testing.expect(componentSnapshotWidget(snapshot, 114).?.selected);
    try std.testing.expect(componentSnapshotWidget(snapshot, 115).?.actions.increment);
    try std.testing.expectEqualStrings("progressbar", componentSnapshotWidget(snapshot, 116).?.role);
    try std.testing.expectApproxEqAbs(@as(f32, 1), componentSnapshotWidget(snapshot, 116).?.value.?, 0.001);
    try std.testing.expectEqualStrings("tab", componentSnapshotWidget(snapshot, 117).?.role);
    const selected_radio = componentSnapshotWidget(snapshot, 169).?;
    try std.testing.expectEqualStrings("radio", selected_radio.role);
    try std.testing.expect(selected_radio.selected);
    try std.testing.expect(selected_radio.actions.select);
    try std.testing.expect(!selected_radio.actions.toggle);
    const unselected_radio = componentSnapshotWidget(snapshot, 170).?;
    try std.testing.expectEqualStrings("radio", unselected_radio.role);
    try std.testing.expect(!unselected_radio.selected);
    try std.testing.expect(unselected_radio.actions.select);
    const textarea = componentSnapshotWidget(snapshot, 171).?;
    try std.testing.expectEqualStrings("textbox", textarea.role);
    try std.testing.expectEqualStrings("Message textarea", textarea.name);
    try std.testing.expect(textarea.actions.set_text);
    try std.testing.expect(textarea.actions.set_selection);
    const select = componentSnapshotWidget(snapshot, 172).?;
    try std.testing.expectEqualStrings("button", select.role);
    try std.testing.expectEqualStrings("Environment select", select.name);
    try std.testing.expect(select.actions.press);
    const snapshot_nav_list = componentSnapshotWidget(snapshot, 120).?;
    try std.testing.expect(snapshot_nav_list.scroll.present);
    try std.testing.expect(snapshot_nav_list.actions.increment);
    try std.testing.expect(snapshot_nav_list.actions.decrement);
    try std.testing.expect(componentSnapshotWidget(snapshot, 130).?.scroll.present);
    try std.testing.expectEqual(@as(f32, 56), componentSnapshotWidget(snapshot, 130).?.scroll.viewport_extent);
    try std.testing.expect(componentSnapshotWidget(snapshot, 130).?.scroll.content_extent > 56);
    const menu_item = componentSnapshotWidget(snapshot, 142).?;
    try std.testing.expectEqualStrings("menuitem", menu_item.role);
    try std.testing.expect(menu_item.bounds.width > 0);
    try std.testing.expect(menu_item.bounds.height >= 28);
    const snapshot_data_grid = componentSnapshotWidget(snapshot, 150).?;
    try std.testing.expect(snapshot_data_grid.scroll.present);
    try std.testing.expect(snapshot_data_grid.actions.increment);
    try std.testing.expect(snapshot_data_grid.actions.decrement);
    try std.testing.expectEqual(@as(?usize, 5), snapshot_data_grid.grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), snapshot_data_grid.grid_column_count);
    try std.testing.expectEqualStrings("gridcell", componentSnapshotWidget(snapshot, 156).?.role);
    try std.testing.expectEqual(@as(?usize, 1), componentSnapshotWidget(snapshot, 156).?.grid_row_index);
    try std.testing.expectEqual(@as(?usize, 0), componentSnapshotWidget(snapshot, 156).?.grid_column_index);
    try std.testing.expectEqualStrings("tooltip", componentSnapshotWidget(snapshot, 160).?.role);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 111 focus");
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-key components-canvas z z");
    snapshot = harness.runtime.automationSnapshot("Components");
    var keyed_project = componentSnapshotWidget(snapshot, 111).?;
    try std.testing.expect(keyed_project.focused);
    try std.testing.expectEqualStrings("zero-nativez", keyed_project.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 12, .end = 12 }, keyed_project.text_selection.?);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentTextCommand(display_list, project_text_id, "zero-nativez");

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-key components-canvas tab");
    snapshot = harness.runtime.automationSnapshot("Components");
    keyed_project = componentSnapshotWidget(snapshot, 111).?;
    try std.testing.expect(!keyed_project.focused);
    try std.testing.expect(componentSnapshotWidget(snapshot, 112).?.focused);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 111 set-text zero-canvas");
    snapshot = harness.runtime.automationSnapshot("Components");
    var edited_project = componentSnapshotWidget(snapshot, 111).?;
    try std.testing.expectEqualStrings("zero-canvas", edited_project.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 11, .end = 11 }, edited_project.text_selection.?);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentTextCommand(display_list, project_text_id, "zero-canvas");

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 111 set-selection 4 10");
    snapshot = harness.runtime.automationSnapshot("Components");
    edited_project = componentSnapshotWidget(snapshot, 111).?;
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 4, .end = 10 }, edited_project.text_selection.?);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try std.testing.expect(display_list.findCommandById(project_selection_id) != null);
    try expectComponentTextCommand(display_list, project_text_id, "zero-canvas");

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 111 set-selection 11 11");
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 111 set-composition ++");
    snapshot = harness.runtime.automationSnapshot("Components");
    edited_project = componentSnapshotWidget(snapshot, 111).?;
    try std.testing.expectEqualStrings("zero-canvas++", edited_project.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 13, .end = 13 }, edited_project.text_selection.?);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 11, .end = 13 }, edited_project.text_composition.?);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentTextCommand(display_list, project_text_id, "zero-canvas++");
    try std.testing.expect(display_list.findCommandById(project_composition_id) != null);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 111 cancel-composition");
    snapshot = harness.runtime.automationSnapshot("Components");
    edited_project = componentSnapshotWidget(snapshot, 111).?;
    try std.testing.expectEqualStrings("zero-canvas", edited_project.text_value);
    try std.testing.expect(edited_project.text_composition == null);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentTextCommand(display_list, project_text_id, "zero-canvas");
    try std.testing.expect(display_list.findCommandById(project_composition_id) == null);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 112 set-text controls");
    snapshot = harness.runtime.automationSnapshot("Components");
    var edited_search = componentSnapshotWidget(snapshot, 112).?;
    try std.testing.expectEqualStrings("controls", edited_search.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 8, .end = 8 }, edited_search.text_selection.?);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentTextCommand(display_list, search_text_id, "controls");

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 112 set-selection 0 8");
    snapshot = harness.runtime.automationSnapshot("Components");
    edited_search = componentSnapshotWidget(snapshot, 112).?;
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 0, .end = 8 }, edited_search.text_selection.?);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try std.testing.expect(display_list.findCommandById(search_selection_id) != null);
    try expectComponentTextCommand(display_list, search_text_id, "controls");

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 112 set-selection 8 8");
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 112 set-composition -native");
    snapshot = harness.runtime.automationSnapshot("Components");
    edited_search = componentSnapshotWidget(snapshot, 112).?;
    try std.testing.expectEqualStrings("controls-native", edited_search.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 15, .end = 15 }, edited_search.text_selection.?);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 8, .end = 15 }, edited_search.text_composition.?);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentTextCommand(display_list, search_text_id, "controls-native");
    try std.testing.expect(display_list.findCommandById(search_composition_id) != null);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 112 cancel-composition");
    snapshot = harness.runtime.automationSnapshot("Components");
    edited_search = componentSnapshotWidget(snapshot, 112).?;
    try std.testing.expectEqualStrings("controls", edited_search.text_value);
    try std.testing.expect(edited_search.text_composition == null);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentTextCommand(display_list, search_text_id, "controls");
    try std.testing.expect(display_list.findCommandById(search_composition_id) == null);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 112 set-composition ++");
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 112 commit-composition");
    snapshot = harness.runtime.automationSnapshot("Components");
    edited_search = componentSnapshotWidget(snapshot, 112).?;
    try std.testing.expectEqualStrings("controls++", edited_search.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 10, .end = 10 }, edited_search.text_selection.?);
    try std.testing.expect(edited_search.text_composition == null);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentTextCommand(display_list, search_text_id, "controls++");

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 104 press");
    try std.testing.expectEqual(@as(u32, 1), app.refresh_count);
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(componentSnapshotWidget(snapshot, 104).?.focused);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 113 toggle");
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(!componentSnapshotWidget(snapshot, 113).?.selected);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 115 increment");
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expectApproxEqAbs(@as(f32, 0.67), componentSnapshotWidget(snapshot, 115).?.value.?, 0.001);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try std.testing.expect(display_list.findCommandById(primary_button_fill_id) != null);

    const status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "Keyed slider #115") != null);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 130 increment");
    snapshot = harness.runtime.automationSnapshot("Components");
    const keyed_scroll = componentSnapshotWidget(snapshot, 130).?;
    try std.testing.expectApproxEqAbs(@as(f32, 84), keyed_scroll.scroll.offset, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 84), app.virtual_scroll.behavior, 0.001);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try std.testing.expect(display_list.findCommandById(scroll_track_id) != null);

    const scroll_status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, scroll_status_view.text, "Keyed scroll_view #130: offset 84") != null);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 120 increment");
    snapshot = harness.runtime.automationSnapshot("Components");
    const keyed_list = componentSnapshotWidget(snapshot, 120).?;
    try std.testing.expectApproxEqAbs(@as(f32, 56), keyed_list.scroll.offset, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 56), app.virtual_scroll.nav, 0.001);
    const list_status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, list_status_view.text, "Keyed list #120: offset 56") != null);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 150 increment");
    snapshot = harness.runtime.automationSnapshot("Components");
    const keyed_grid = componentSnapshotWidget(snapshot, 150).?;
    try std.testing.expectApproxEqAbs(@as(f32, 56), keyed_grid.scroll.offset, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 56), app.virtual_scroll.data, 0.001);
    const grid_status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, grid_status_view.text, "Keyed data_grid #150: offset 56") != null);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 142 select");
    snapshot = harness.runtime.automationSnapshot("Components");
    const selected_menu_item = componentSnapshotWidget(snapshot, 142).?;
    try std.testing.expect(selected_menu_item.focused);
    try std.testing.expectApproxEqAbs(@as(f32, 1), selected_menu_item.value.?, 0.001);
}

test "gpu components native theme command updates retained design tokens" {
    var harness: zero_native.TestHarness() = undefined;
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    var app = GpuComponentsApp{};
    defer app.deinit();
    const app_handle = app.app();
    try harness.start(app_handle);

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqualDeep(componentTokensForScale(.light, 2), try harness.runtime.canvasWidgetDesignTokens(1, canvas_label));
    var display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentFillRoundedRectColor(display_list, 3, componentTokensForScale(.light, 2).colors.surface);
    try expectComponentFillRoundedRectColor(display_list, primary_button_fill_id, componentTokensForScale(.light, 2).colors.accent);

    resetComponentDirty(&harness.runtime);
    const packet_count_before_dark = harness.null_platform.gpu_surface_packet_present_count;
    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .native_command = .{
        .name = theme_command,
        .window_id = 1,
        .view_label = "theme-mode",
    } });

    try std.testing.expectEqual(ComponentThemeMode.dark, app.theme_mode);
    try std.testing.expectEqual(@as(u32, 1), app.theme_count);
    try std.testing.expectEqualDeep(componentTokensForScale(.dark, 2), try harness.runtime.canvasWidgetDesignTokens(1, canvas_label));
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_count > packet_count_before_dark);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentFillRoundedRectColor(display_list, 3, componentTokensForScale(.dark, 2).colors.surface);
    try expectComponentFillRoundedRectColor(display_list, primary_button_fill_id, componentTokensForScale(.dark, 2).colors.accent);
    var status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "GPU component theme: Dark from toolbar") != null);

    const packet_count_before_high = harness.null_platform.gpu_surface_packet_present_count;
    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .native_command = .{
        .name = theme_command,
        .window_id = 1,
        .view_label = "theme-mode",
    } });

    try std.testing.expectEqual(ComponentThemeMode.high, app.theme_mode);
    try std.testing.expectEqual(@as(u32, 2), app.theme_count);
    try std.testing.expectEqualDeep(componentTokensForScale(.high, 2), try harness.runtime.canvasWidgetDesignTokens(1, canvas_label));
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_count > packet_count_before_high);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentFillRoundedRectColor(display_list, 3, componentTokensForScale(.high, 2).colors.surface);
    try expectComponentFillRoundedRectColor(display_list, primary_button_fill_id, componentTokensForScale(.high, 2).colors.accent);
    status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "GPU component theme: High contrast from toolbar") != null);

    const themed_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try expectComponentWidgetFrame(themed_layout, 111, rect(64, 124, 148, 34));
    try expectComponentWidgetFrame(themed_layout, 160, rect(456, 540, 176, 32));
}

test "gpu components follow system appearance until toolbar theme override" {
    var harness: zero_native.TestHarness() = undefined;
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    var app = GpuComponentsApp{};
    defer app.deinit();
    const app_handle = app.app();
    try harness.start(app_handle);

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .appearance_changed = .{ .color_scheme = .dark, .reduce_motion = true, .high_contrast = true } });
    try std.testing.expectEqual(ComponentThemeMode.dark, app.theme_mode);
    try std.testing.expect(app.reduce_motion);
    try std.testing.expect(app.high_contrast);

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqualDeep(componentTokensForScaleMotionAndContrast(.dark, 2, true, true), try harness.runtime.canvasWidgetDesignTokens(1, canvas_label));

    const packet_count_before_light = harness.null_platform.gpu_surface_packet_present_count;
    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .appearance_changed = .{ .color_scheme = .light } });
    try std.testing.expectEqual(ComponentThemeMode.light, app.theme_mode);
    try std.testing.expect(!app.reduce_motion);
    try std.testing.expect(!app.high_contrast);
    try std.testing.expectEqualDeep(componentTokensForScale(.light, 2), try harness.runtime.canvasWidgetDesignTokens(1, canvas_label));
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_count > packet_count_before_light);
    const status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "GPU component theme: Light from system appearance.") != null);

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .native_command = .{
        .name = theme_command,
        .window_id = 1,
        .view_label = "theme-mode",
    } });
    try std.testing.expect(app.theme_overridden);
    try std.testing.expectEqual(ComponentThemeMode.dark, app.theme_mode);

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .appearance_changed = .{ .color_scheme = .light, .reduce_motion = true, .high_contrast = true } });
    try std.testing.expectEqual(ComponentThemeMode.dark, app.theme_mode);
    try std.testing.expect(app.reduce_motion);
    try std.testing.expect(app.high_contrast);
    try std.testing.expectEqualDeep(componentTokensForScaleMotionAndContrast(.dark, 2, true, true), try harness.runtime.canvasWidgetDesignTokens(1, canvas_label));
}

test "gpu components pointer clicks update retained controls" {
    var harness: zero_native.TestHarness() = undefined;
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    var app = GpuComponentsApp{};
    defer app.deinit();
    const app_handle = app.app();
    try harness.start(app_handle);

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });

    var snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(componentSnapshotWidget(snapshot, 113).?.selected);
    try std.testing.expect(componentSnapshotWidget(snapshot, 114).?.selected);
    try std.testing.expectApproxEqAbs(@as(f32, 0.62), componentSnapshotWidget(snapshot, 115).?.value.?, 0.001);
    try std.testing.expect(componentSnapshotWidget(snapshot, 121).?.selected);
    try std.testing.expect(!componentSnapshotWidget(snapshot, 156).?.selected);

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerClick(&harness.runtime, app_handle, 113);
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(!componentSnapshotWidget(snapshot, 113).?.selected);
    try std.testing.expect(harness.runtime.invalidated);
    var status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "Clicked checkbox #113: off.") != null);

    const present_count = harness.null_platform.gpu_surface_packet_present_count;
    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 1_016_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqual(present_count + 1, harness.null_platform.gpu_surface_packet_present_count);
    const clean_frame = try harness.runtime.gpuSurfaceFrame(1, canvas_label);
    try std.testing.expect(!clean_frame.canvas_frame_requires_render);

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerClick(&harness.runtime, app_handle, 114);
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(!componentSnapshotWidget(snapshot, 114).?.selected);
    try std.testing.expectEqual(@as(?f32, 0), componentSnapshotWidget(snapshot, 114).?.value);
    status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "Clicked toggle #114: off.") != null);

    const slider = (try harness.runtime.canvasWidgetLayout(1, canvas_label)).findById(115).?;
    const slider_point = geometry.PointF.init(slider.frame.x + slider.frame.width * 0.25, slider.frame.center().y);
    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .x = slider_point.x,
        .y = slider_point.y,
        .button = 0,
    } });
    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_up,
        .x = slider_point.x,
        .y = slider_point.y,
        .button = 0,
    } });
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), componentSnapshotWidget(snapshot, 115).?.value.?, 0.001);
    status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "Clicked slider #115") != null);

    resetComponentDirty(&harness.runtime);
    var before_scroll_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    const before_nav_scroll = before_scroll_layout.findById(120).?.widget.value;
    try dispatchComponentPointerWheel(&harness.runtime, app_handle, 120, 20);
    var scrolled_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expectApproxEqAbs(before_nav_scroll + 22, scrolled_layout.findById(120).?.widget.value, 0.001);
    try std.testing.expect(harness.runtime.invalidated);
    status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "Clicked slider #115") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "Scrolled") == null);

    resetComponentDirty(&harness.runtime);
    before_scroll_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    const before_behavior_scroll = before_scroll_layout.findById(130).?.widget.value;
    try dispatchComponentPointerWheel(&harness.runtime, app_handle, 130, 20);
    scrolled_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expectApproxEqAbs(before_behavior_scroll + 22, scrolled_layout.findById(130).?.widget.value, 0.001);
    try std.testing.expect(harness.runtime.invalidated);
    status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "Clicked slider #115") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "Scrolled") == null);

    resetComponentDirty(&harness.runtime);
    before_scroll_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    const before_data_scroll = before_scroll_layout.findById(150).?.widget.value;
    try dispatchComponentPointerWheel(&harness.runtime, app_handle, 150, 20);
    scrolled_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expectApproxEqAbs(before_data_scroll + 22, scrolled_layout.findById(150).?.widget.value, 0.001);
    try std.testing.expect(harness.runtime.invalidated);
    status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "Clicked slider #115") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "Scrolled") == null);

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerClick(&harness.runtime, app_handle, 158);
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(componentSnapshotWidget(snapshot, 158).?.selected);

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerClick(&harness.runtime, app_handle, 142);
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expectApproxEqAbs(@as(f32, 1), componentSnapshotWidget(snapshot, 142).?.value.?, 0.001);
    try std.testing.expect(harness.runtime.invalidated);
    status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "Clicked menu_item #142: selected.") != null);

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerClick(&harness.runtime, app_handle, 104);
    try std.testing.expectEqual(@as(u32, 1), app.refresh_count);
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(componentSnapshotWidget(snapshot, 104).?.focused);
    const refreshed_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expectEqual(@as(f32, 0), refreshed_layout.findById(120).?.widget.value);
    try std.testing.expectEqual(@as(f32, 28), refreshed_layout.findById(130).?.widget.value);
    try std.testing.expectEqual(@as(f32, 28), refreshed_layout.findById(150).?.widget.value);

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerClick(&harness.runtime, app_handle, 172);
    try std.testing.expectEqual(@as(u32, 2), app.refresh_count);
}

test "gpu components slider drag presents incremental cached frame" {
    var harness: zero_native.TestHarness() = undefined;
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    var app = GpuComponentsApp{};
    defer app.deinit();
    const app_handle = app.app();
    try harness.start(app_handle);

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });
    const initial_frame = try harness.runtime.gpuSurfaceFrame(1, canvas_label);
    try std.testing.expect(!initial_frame.canvas_frame_requires_render);
    try std.testing.expect(initial_frame.canvas_frame_gpu_packet_representable);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);

    resetComponentDirty(&harness.runtime);
    const packet_count_before = harness.null_platform.gpu_surface_packet_present_count;
    try dispatchComponentPointerDrag(&harness.runtime, app_handle, 115, 0.25, 0.82);

    var snapshot = harness.runtime.automationSnapshot("Components");
    const dragged_slider = componentSnapshotWidget(snapshot, 115).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.82), dragged_slider.value.?, 0.001);
    try std.testing.expect(dragged_slider.focused);
    try std.testing.expect(!dragged_slider.pressed);
    try std.testing.expect(harness.runtime.invalidated);
    const status_view = componentViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "Clicked slider #115: value 0.82") != null);

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 1_016_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqual(packet_count_before + 1, harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(u64, 2), harness.null_platform.gpu_surface_packet_present_frame_index);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_requires_render);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_command_count > 0);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_cache_action_count > 0);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_cached_resource_command_count > 0);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_packet_present_unsupported_command_count);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_representable);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_json_len > 0);

    const drag_frame = try harness.runtime.gpuSurfaceFrame(1, canvas_label);
    try std.testing.expect(!drag_frame.canvas_frame_requires_render);
    try std.testing.expect(!drag_frame.canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(usize, 0), drag_frame.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(drag_frame.canvas_frame_gpu_packet_representable);
    try std.testing.expect(drag_frame.canvas_frame_budget_ok);

    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expectApproxEqAbs(@as(f32, 0.82), componentSnapshotWidget(snapshot, 115).?.value.?, 0.001);
}

fn expectComponentTextCommand(display_list: canvas.DisplayList, id: canvas.ObjectId, text: []const u8) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.TestUnexpectedResult;
    switch (command_ref.command) {
        .draw_text => |draw| try std.testing.expectEqualStrings(text, draw.text),
        else => return error.TestUnexpectedResult,
    }
}

fn expectComponentRoundedRectFrame(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: geometry.RectF) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.TestUnexpectedResult;
    switch (command_ref.command) {
        .fill_rounded_rect => |rounded| try expectComponentRect(rounded.rect, expected),
        else => return error.TestUnexpectedResult,
    }
}

fn expectComponentFillRoundedRectColor(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: canvas.Color) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.TestUnexpectedResult;
    switch (command_ref.command) {
        .fill_rounded_rect => |fill| switch (fill.fill) {
            .color => |actual| try std.testing.expectEqualDeep(expected, actual),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

fn expectSemanticRole(semantics: []const canvas.WidgetSemanticsNode, id: canvas.ObjectId, role: canvas.WidgetRole) !void {
    const semantic = expectSemantic(semantics, id);
    try std.testing.expectEqual(role, semantic.role);
}

fn expectSemantic(semantics: []const canvas.WidgetSemanticsNode, id: canvas.ObjectId) canvas.WidgetSemanticsNode {
    for (semantics) |semantic| {
        if (semantic.id == id) return semantic;
    }
    @panic("missing semantic node");
}

fn expectComponentWidgetFrame(layout: canvas.WidgetLayoutTree, id: canvas.ObjectId, expected: geometry.RectF) !void {
    const node = layout.findById(id) orelse return error.TestUnexpectedResult;
    try expectComponentRect(node.frame, expected);
}

fn expectComponentWidgetsDoNotOverlap(layout: canvas.WidgetLayoutTree, a_id: canvas.ObjectId, b_id: canvas.ObjectId) !void {
    const a = layout.findById(a_id) orelse return error.TestUnexpectedResult;
    const b = layout.findById(b_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(geometry.RectF.intersection(a.frame.normalized(), b.frame.normalized()).isEmpty());
}

fn expectComponentRect(actual: geometry.RectF, expected: geometry.RectF) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 0.001);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 0.001);
    try std.testing.expectApproxEqAbs(expected.width, actual.width, 0.001);
    try std.testing.expectApproxEqAbs(expected.height, actual.height, 0.001);
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
