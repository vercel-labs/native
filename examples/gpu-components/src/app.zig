const std = @import("std");
const native_sdk = @import("native_sdk");
const model = @import("model.zig");
const component_scene = @import("scene.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const window_width = model.window_width;
const window_height = model.window_height;
const canvas_sidebar_width = model.canvas_sidebar_width;
const default_canvas_size = model.default_canvas_size;
const max_component_pipelines = model.max_component_pipelines;
const max_component_commands = model.max_component_commands;
const max_component_glyphs = model.max_component_glyphs;
const max_component_widgets = model.max_component_widgets;
const component_chrome_prefix_commands = model.component_chrome_prefix_commands;
const component_chrome_suffix_commands = model.component_chrome_suffix_commands;
const refresh_command = model.refresh_command;
const themeModeFromCommand = model.themeModeFromCommand;
const environment_toggle_command = model.environment_toggle_command;
const surface_dialog_command = model.surface_dialog_command;
const surface_drawer_command = model.surface_drawer_command;
const surface_sheet_command = model.surface_sheet_command;
const surface_close_command = model.surface_close_command;
const canvas_label = model.canvas_label;
const environment_select_id = model.environment_select_id;
const content_scroll_id = model.content_scroll_id;
const canvas_toolbar_theme_id = model.canvas_toolbar_theme_id;
const canvas_toolbar_refresh_id = model.canvas_toolbar_refresh_id;
const canvas_sidebar_resize_handle_id = model.canvas_sidebar_resize_handle_id;
const surface_overlay_backdrop_id = model.surface_overlay_backdrop_id;
const surface_overlay_id = model.surface_overlay_id;
const surface_overlay_close_id = model.surface_overlay_close_id;
const surface_overlay_content_parts = model.surface_overlay_content_parts;
const max_surface_overlay_animations = model.max_surface_overlay_animations;
const preview_images = component_scene.preview_images;
const environment_options = model.environment_options;
const environment_menu_id = model.environment_menu_id;
const initial_component_status_text = model.initial_component_status_text;
const max_component_status_text = model.max_component_status_text;
const ComponentVirtualScroll = model.ComponentVirtualScroll;
const ComponentUiState = model.ComponentUiState;
const ComponentSurfaceOverlay = model.ComponentSurfaceOverlay;
const ComponentSection = model.ComponentSection;
const ComponentThemeMode = model.ComponentThemeMode;
const environmentLabel = model.environmentLabel;
const environmentOptionIndex = model.environmentOptionIndex;
const environmentCommandIndex = model.environmentCommandIndex;
const componentSectionLabel = model.componentSectionLabel;
const componentSectionFromCommand = model.componentSectionFromCommand;
const surfaceOverlayLabel = model.surfaceOverlayLabel;

const installComponentsCanvasModel = component_scene.installComponentsCanvasModel;
const componentSurfaceSize = component_scene.componentSurfaceSize;
const componentSidebarWidthForSize = component_scene.componentSidebarWidthForSize;
const componentVirtualScrollTarget = component_scene.componentVirtualScrollTarget;
const componentVirtualKeyboardScrollTarget = component_scene.componentVirtualKeyboardScrollTarget;
const componentVirtualKeyboardScrollDelta = component_scene.componentVirtualKeyboardScrollDelta;
const snapComponentVirtualScrollOffset = component_scene.snapComponentVirtualScrollOffset;
const componentScrollStatesEqual = component_scene.componentScrollStatesEqual;
const componentFrameIntervalMs = component_scene.componentFrameIntervalMs;
const componentSizesEqual = component_scene.componentSizesEqual;
const componentTokensForScaleMotionAndContrast = component_scene.componentTokensForScaleMotionAndContrast;
const componentThemeModeForAppearance = component_scene.componentThemeModeForAppearance;
const normalizedPixelSnapScale = component_scene.normalizedPixelSnapScale;
const buildComponentsWidgetLayoutWithStateSizeAndTokens = component_scene.buildComponentsWidgetLayoutWithStateSizeAndTokens;
const surfaceOverlayKind = component_scene.surfaceOverlayKind;
const surfaceOverlayFrameForSidebar = component_scene.surfaceOverlayFrameForSidebar;
const gpuFrameEvent = component_scene.gpuFrameEvent;
const componentFrameStatus = component_scene.componentFrameStatus;

pub const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
pub const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .min_width = 640, .layer = 12, .role = "Native-rendered component canvas", .accessibility_label = "Native-rendered component gallery canvas", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
pub const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK GPU Components",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub const GpuComponentsApp = struct {
    refresh_count: u32 = 0,
    theme_count: u32 = 0,
    theme_mode: ComponentThemeMode = .light,
    theme_overridden: bool = false,
    reduce_motion: bool = false,
    high_contrast: bool = false,
    canvas_installed: bool = false,
    reported_planned_frame: bool = false,
    virtual_scroll: ComponentVirtualScroll = .{},
    environment_select_open: bool = false,
    environment_index: usize = 0,
    surface_overlay: ComponentSurfaceOverlay = .none,
    section: ComponentSection = .controls,
    sidebar_width: f32 = canvas_sidebar_width,
    canvas_size: geometry.SizeF = default_canvas_size,
    pixel_snap_scale: f32 = 1,
    status_text_storage: [max_component_status_text]u8 = [_]u8{0} ** max_component_status_text,
    status_text_len: usize = 0,
    pixels: ?[]u8 = null,
    scratch: ?[]u8 = null,
    gpu_commands: [max_component_commands]canvas.CanvasGpuCommand = undefined,
    packet_json: [native_sdk.platform.max_gpu_surface_packet_json_bytes]u8 = undefined,
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

    pub fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "gpu-components",
            .scene_fn = scene,
            .event_fn = event,
            .stop_fn = stop,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.pixels) |pixels| std.heap.page_allocator.free(pixels);
        if (self.scratch) |scratch| std.heap.page_allocator.free(scratch);
        self.pixels = null;
        self.scratch = null;
    }

    fn scene(context: *anyopaque) anyerror!native_sdk.ShellConfig {
        _ = context;
        return shell_scene;
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event_value) {
            .command => |command| {
                if (std.mem.eql(u8, command.name, environment_toggle_command)) {
                    try self.toggleEnvironmentSelect(runtime, command);
                } else if (environmentCommandIndex(command.name)) |index| {
                    try self.selectEnvironment(runtime, command, index);
                } else if (std.mem.eql(u8, command.name, surface_dialog_command)) {
                    try self.openSurfaceOverlay(runtime, command, .dialog);
                } else if (std.mem.eql(u8, command.name, surface_drawer_command)) {
                    try self.openSurfaceOverlay(runtime, command, .drawer);
                } else if (std.mem.eql(u8, command.name, surface_sheet_command)) {
                    try self.openSurfaceOverlay(runtime, command, .sheet);
                } else if (std.mem.eql(u8, command.name, surface_close_command)) {
                    try self.closeSurfaceOverlay(runtime, command);
                } else if (std.mem.eql(u8, command.name, refresh_command)) {
                    try self.refresh(runtime, command);
                } else if (themeModeFromCommand(command.name)) |mode| {
                    try self.changeTheme(runtime, command, mode);
                } else if (componentSectionFromCommand(command.name)) |section| {
                    try self.changeSection(runtime, command, section);
                }
            },
            .gpu_surface_frame => |frame_event| try self.handleGpuFrame(runtime, frame_event),
            .canvas_widget_pointer => |pointer_event| try self.handleWidgetPointer(runtime, pointer_event),
            .canvas_widget_keyboard => |keyboard_event| try self.handleWidgetKeyboard(runtime, keyboard_event),
            .canvas_widget_dismiss => |dismiss_event| try self.handleWidgetDismiss(runtime, dismiss_event),
            .appearance_changed => |appearance| try self.applySystemAppearance(runtime, appearance),
            .gpu_surface_resized, .gpu_surface_input, .shortcut, .timer, .effects_wake, .audio, .files_dropped, .canvas_widget_scroll, .canvas_widget_file_drop, .canvas_widget_drag, .canvas_widget_context_menu, .canvas_widget_context_menu_request, .canvas_widget_context_press, .canvas_widget_resize, .canvas_widget_change, .window_closed, .automation_provenance, .lifecycle => {},
        }
    }

    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        _ = runtime;
        const self: *@This() = @ptrCast(@alignCast(context));
        self.deinit();
    }

    fn handleGpuFrame(self: *@This(), runtime: *native_sdk.Runtime, frame_event: native_sdk.GpuSurfaceFrameEvent) anyerror!void {
        if (!std.mem.eql(u8, frame_event.label, canvas_label)) return;
        const first_install = !self.canvas_installed;
        const scale_changed = self.updatePixelSnapScale(frame_event.scale_factor);
        const size_changed = self.updateCanvasSize(componentSurfaceSize(frame_event.size));
        if (first_install or scale_changed or size_changed) {
            if (first_install) self.setStatusText("Component lab display list presented on the GPU surface.");
            try installComponentsCanvasModel(runtime, frame_event.window_id, self.virtual_scroll, self.componentUiState(), self.componentTokens(), self.canvas_size);
            _ = try self.presentComponentsCanvas(runtime, frame_event, true);
            self.canvas_installed = true;
            return;
        }

        const scrolled = try self.stepComponentVirtualScrollForFrame(runtime, frame_event);
        _ = try self.presentComponentsCanvas(runtime, frame_event, frame_event.canvas_frame_full_repaint or scrolled);
        const current_frame = try runtime.gpuSurfaceFrame(frame_event.window_id, canvas_label);
        try self.reportFrameStatus(runtime, gpuFrameEvent(current_frame));
    }

    fn handleWidgetPointer(self: *@This(), runtime: *native_sdk.Runtime, pointer_event: native_sdk.runtime.CanvasWidgetPointerEvent) anyerror!void {
        if (!std.mem.eql(u8, pointer_event.view_label, canvas_label)) return;
        const target = pointer_event.target orelse return;
        switch (pointer_event.pointer.phase) {
            .move => {
                if (target.id == canvas_sidebar_resize_handle_id) {
                    try self.resizeSidebar(runtime, pointer_event);
                    return;
                }
            },
            .up => {
                if (target.id == canvas_sidebar_resize_handle_id) return;
                if (target.id == surface_overlay_backdrop_id and self.surface_overlay != .none) {
                    self.surface_overlay = .none;
                    _ = runtime.clearCanvasRenderAnimations(pointer_event.window_id, canvas_label) catch {};
                    try self.updateComponentsCanvasModel(runtime, pointer_event.window_id);
                    try self.updateStatus(runtime, pointer_event.window_id, "Surface closed.");
                    return;
                }
                if (target.id == environment_select_id or
                    target.id == canvas_toolbar_theme_id or
                    target.id == model.themeModeTriggerId(.light) or
                    target.id == model.themeModeTriggerId(.dark) or
                    target.id == model.themeModeTriggerId(.high) or
                    target.id == canvas_toolbar_refresh_id or
                    environmentOptionIndex(target.id) != null or
                    target.id == 175 or
                    target.id == 176 or
                    target.id == 177 or
                    target.id == surface_overlay_close_id) return;
                if (self.environment_select_open) {
                    self.environment_select_open = false;
                    try self.updateComponentsCanvasModel(runtime, pointer_event.window_id);
                    try self.updateStatus(runtime, pointer_event.window_id, "Environment menu closed.");
                    return;
                }
                try self.reportWidgetInteraction(runtime, pointer_event.window_id, "Clicked", target.id);
            },
            .wheel => {
                _ = try self.scrollVirtualWidget(runtime, pointer_event);
            },
            else => {},
        }
    }

    fn resizeSidebar(self: *@This(), runtime: *native_sdk.Runtime, pointer_event: native_sdk.runtime.CanvasWidgetPointerEvent) anyerror!void {
        const next_width = componentSidebarWidthForSize(self.sidebar_width + pointer_event.pointer.delta.dx, self.canvas_size);
        if (@abs(next_width - self.sidebar_width) < 0.001) return;
        self.sidebar_width = next_width;
        try installComponentsCanvasModel(runtime, pointer_event.window_id, self.virtual_scroll, self.componentUiState(), self.componentTokens(), self.canvas_size);
    }

    fn handleWidgetKeyboard(self: *@This(), runtime: *native_sdk.Runtime, keyboard_event: native_sdk.runtime.CanvasWidgetKeyboardEvent) anyerror!void {
        if (!std.mem.eql(u8, keyboard_event.view_label, canvas_label)) return;
        if (keyboard_event.keyboard.phase != .key_down) return;
        const target = keyboard_event.target orelse return;
        const scrolled_id = try self.scrollVirtualWidgetFromKeyboard(runtime, keyboard_event) orelse target.id;
        try self.reportWidgetInteraction(runtime, keyboard_event.window_id, "Keyed", scrolled_id);
    }

    /// The engine's dismissal (Escape, outside click, automation) hands
    /// the surface id back so the MODEL closes it — the app clears the
    /// open flag and rebuilds, agreeing with the optimistic hide.
    fn handleWidgetDismiss(self: *@This(), runtime: *native_sdk.Runtime, dismiss_event: native_sdk.runtime.CanvasWidgetDismissEvent) anyerror!void {
        if (!std.mem.eql(u8, dismiss_event.view_label, canvas_label)) return;
        if (dismiss_event.id != environment_menu_id) return;
        if (!self.environment_select_open) return;
        self.environment_select_open = false;
        try self.updateComponentsCanvasModel(runtime, dismiss_event.window_id);
        try self.updateStatus(runtime, dismiss_event.window_id, "Environment menu closed.");
    }

    fn reportWidgetInteraction(self: *@This(), runtime: *native_sdk.Runtime, window_id: native_sdk.WindowId, action: []const u8, id: canvas.ObjectId) anyerror!void {
        const layout = try runtime.canvasWidgetLayout(window_id, canvas_label);
        const node = layout.findById(id) orelse return;
        const widget = node.widget;
        var status_buffer: [192]u8 = undefined;
        const status = switch (widget.kind) {
            .checkbox, .radio, .switch_control, .toggle, .toggle_button => try std.fmt.bufPrint(
                &status_buffer,
                "{s} {s} #{d}: {s}.",
                .{ action, @tagName(widget.kind), id, if (widget.state.selected or widget.value >= 0.5) "on" else "off" },
            ),
            .slider, .progress => try std.fmt.bufPrint(
                &status_buffer,
                "{s} {s} #{d}: value {d:.2}.",
                .{ action, @tagName(widget.kind), id, widget.value },
            ),
            .scroll_view, .list, .data_grid, .table => try std.fmt.bufPrint(
                &status_buffer,
                "{s} {s} #{d}: offset {d}.",
                .{ action, @tagName(widget.kind), id, widget.value },
            ),
            .input, .text_field, .search_field, .combobox, .textarea => try std.fmt.bufPrint(
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

    fn scrollVirtualWidget(self: *@This(), runtime: *native_sdk.Runtime, pointer_event: native_sdk.runtime.CanvasWidgetPointerEvent) anyerror!?canvas.ObjectId {
        const id = componentVirtualScrollTarget(pointer_event.route) orelse return null;
        const layout = try runtime.canvasWidgetLayout(pointer_event.window_id, canvas_label);
        const node = layout.findById(id) orelse return null;
        if (!node.widget.layout.virtualized) return null;

        const viewport = node.frame.inset(node.widget.layout.padding).normalized();
        if (viewport.isEmpty()) return null;

        const max_offset = @max(0, canvas.virtualWidgetScrollContentExtent(node.widget, viewport.height) - viewport.height);
        const current = self.componentVirtualScrollState(id, viewport.height, viewport.height + max_offset) orelse return null;
        const next = current.applyWheel(pointer_event.pointer.delta.dy, self.componentTokens().scroll);
        if (componentScrollStatesEqual(current, next)) return id;

        try self.setComponentVirtualScrollState(id, next);
        try self.updateComponentsCanvasModel(runtime, pointer_event.window_id);
        return id;
    }

    fn scrollVirtualWidgetFromKeyboard(self: *@This(), runtime: *native_sdk.Runtime, keyboard_event: native_sdk.runtime.CanvasWidgetKeyboardEvent) anyerror!?canvas.ObjectId {
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

        try self.setComponentVirtualScrollState(id, .{
            .offset = next,
            .velocity = 0,
            .viewport_extent = viewport.height,
            .content_extent = viewport.height + max_offset,
        });
        try self.updateComponentsCanvasModel(runtime, keyboard_event.window_id);
        return id;
    }

    fn stepComponentVirtualScrollForFrame(self: *@This(), runtime: *native_sdk.Runtime, frame_event: native_sdk.GpuSurfaceFrameEvent) anyerror!bool {
        const layout = try runtime.canvasWidgetLayout(frame_event.window_id, canvas_label);
        var changed = false;
        const ids = [_]canvas.ObjectId{ 120, 130, 150 };
        for (ids) |id| {
            const node = layout.findById(id) orelse continue;
            if (!node.widget.layout.virtualized) continue;
            const viewport = node.frame.inset(node.widget.layout.padding).normalized();
            if (viewport.isEmpty()) continue;

            const content_extent = canvas.virtualWidgetScrollContentExtent(node.widget, viewport.height);
            const current = self.componentVirtualScrollState(id, viewport.height, content_extent) orelse continue;
            if (!current.needsKineticStep(self.componentTokens().scroll)) {
                if (current.velocity != 0) {
                    var settled = current;
                    settled.velocity = 0;
                    try self.setComponentVirtualScrollState(id, settled);
                }
                continue;
            }

            const next = current.stepKinetic(componentFrameIntervalMs(frame_event.frame_interval_ns), self.componentTokens().scroll);
            if (componentScrollStatesEqual(current, next)) continue;
            try self.setComponentVirtualScrollState(id, next);
            changed = true;
        }

        if (changed) try self.updateComponentsCanvasModel(runtime, frame_event.window_id);
        return changed;
    }

    fn refresh(self: *@This(), runtime: *native_sdk.Runtime, command: native_sdk.CommandEvent) anyerror!void {
        self.refresh_count += 1;
        self.virtual_scroll = .{};
        self.environment_select_open = false;
        self.surface_overlay = .none;
        self.section = .controls;
        _ = runtime.clearCanvasRenderAnimations(command.window_id, canvas_label) catch {};
        const gpu_frame = try runtime.gpuSurfaceFrame(command.window_id, canvas_label);
        _ = self.updateCanvasSize(componentSurfaceSize(gpu_frame.size));
        try installComponentsCanvasModel(runtime, command.window_id, self.virtual_scroll, self.componentUiState(), self.componentTokens(), self.canvas_size);
        _ = try self.presentComponentsCanvas(runtime, gpuFrameEvent(gpu_frame), true);

        var status_buffer: [160]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "Component lab refreshed from {s}. Count {d}.", .{ @tagName(command.source), self.refresh_count });
        try self.updateStatus(runtime, command.window_id, status);
    }

    fn changeSection(self: *@This(), runtime: *native_sdk.Runtime, command: native_sdk.CommandEvent, section: ComponentSection) anyerror!void {
        self.section = section;
        self.environment_select_open = false;
        self.surface_overlay = .none;
        self.virtual_scroll.page = 0;
        _ = runtime.clearCanvasRenderAnimations(command.window_id, canvas_label) catch {};
        try self.updateComponentsCanvasModel(runtime, command.window_id);

        var status_buffer: [96]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "Showing {s}.", .{componentSectionLabel(section)});
        try self.updateStatus(runtime, command.window_id, status);
    }

    fn toggleEnvironmentSelect(self: *@This(), runtime: *native_sdk.Runtime, command: native_sdk.CommandEvent) anyerror!void {
        self.environment_select_open = !self.environment_select_open;
        try self.updateComponentsCanvasModel(runtime, command.window_id);
        try self.updateStatus(runtime, command.window_id, if (self.environment_select_open) "Environment menu opened." else "Environment menu closed.");
    }

    fn selectEnvironment(self: *@This(), runtime: *native_sdk.Runtime, command: native_sdk.CommandEvent, index: usize) anyerror!void {
        self.environment_index = @min(index, environment_options.len - 1);
        self.environment_select_open = false;
        try self.updateComponentsCanvasModel(runtime, command.window_id);
        try self.updateEnvironmentSelectedStatus(runtime, command.window_id);
    }

    fn updateEnvironmentSelectedStatus(self: *@This(), runtime: *native_sdk.Runtime, window_id: native_sdk.WindowId) anyerror!void {
        var status_buffer: [96]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "Environment selected: {s}.", .{environmentLabel(self.environment_index)});
        try self.updateStatus(runtime, window_id, status);
    }

    fn openSurfaceOverlay(self: *@This(), runtime: *native_sdk.Runtime, command: native_sdk.CommandEvent, overlay: ComponentSurfaceOverlay) anyerror!void {
        self.environment_select_open = false;
        self.surface_overlay = overlay;
        try self.updateComponentsCanvasModel(runtime, command.window_id);
        try self.scheduleSurfaceOverlayAnimation(runtime, command.window_id, overlay);

        var status_buffer: [96]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "{s} surface opened.", .{surfaceOverlayLabel(overlay)});
        try self.updateStatus(runtime, command.window_id, status);
    }

    fn closeSurfaceOverlay(self: *@This(), runtime: *native_sdk.Runtime, command: native_sdk.CommandEvent) anyerror!void {
        if (self.surface_overlay == .none) return;
        self.surface_overlay = .none;
        _ = runtime.clearCanvasRenderAnimations(command.window_id, canvas_label) catch {};
        try self.updateComponentsCanvasModel(runtime, command.window_id);
        try self.updateStatus(runtime, command.window_id, "Surface closed.");
    }

    fn scheduleSurfaceOverlayAnimation(self: *@This(), runtime: *native_sdk.Runtime, window_id: native_sdk.WindowId, overlay: ComponentSurfaceOverlay) anyerror!void {
        const motion = self.componentTokens().motion;

        const start_ns = runtime.canvasRenderAnimationStartNs(window_id, canvas_label) catch |err| switch (err) {
            error.WindowNotFound, error.ViewNotFound, error.InvalidViewOptions => return,
            else => return err,
        };
        var animations: [max_surface_overlay_animations]canvas.CanvasRenderAnimation = undefined;
        var count: usize = 0;
        try canvas.appendBuiltinSurfaceEnterAnimations(surfaceOverlayKind(overlay), .{
            .surface_id = surface_overlay_id,
            .frame = surfaceOverlayFrameForSidebar(self.canvas_size, overlay, self.sidebar_width),
            .motion = motion,
            .start_ns = start_ns,
            .content = &surface_overlay_content_parts,
        }, &animations, &count);
        if (count == 0) return;
        _ = try runtime.setCanvasRenderAnimations(window_id, canvas_label, animations[0..count]);
    }

    fn changeTheme(self: *@This(), runtime: *native_sdk.Runtime, command: native_sdk.CommandEvent, mode: ComponentThemeMode) anyerror!void {
        self.theme_count += 1;
        self.theme_overridden = true;
        self.theme_mode = mode;
        const gpu_frame = try runtime.gpuSurfaceFrame(command.window_id, canvas_label);
        _ = self.updateCanvasSize(componentSurfaceSize(gpu_frame.size));
        try installComponentsCanvasModel(runtime, command.window_id, self.virtual_scroll, self.componentUiState(), self.componentTokens(), self.canvas_size);
        _ = try self.presentComponentsCanvas(runtime, gpuFrameEvent(gpu_frame), true);

        var status_buffer: [160]u8 = undefined;
        const status = try std.fmt.bufPrint(
            &status_buffer,
            "GPU component theme: {s} from {s}. Count {d}.",
            .{ self.theme_mode.label(), @tagName(command.source), self.theme_count },
        );
        try self.updateStatus(runtime, command.window_id, status);
    }

    fn applySystemAppearance(self: *@This(), runtime: *native_sdk.Runtime, appearance: native_sdk.Appearance) anyerror!void {
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
        try installComponentsCanvasModel(runtime, 1, self.virtual_scroll, self.componentUiState(), self.componentTokens(), self.canvas_size);
        _ = try self.presentComponentsCanvas(runtime, gpuFrameEvent(gpu_frame), true);

        var status_buffer: [160]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "GPU component theme: {s} from system appearance.", .{self.theme_mode.label()});
        try self.updateStatus(runtime, 1, status);
    }

    fn presentComponentsCanvas(self: *@This(), runtime: *native_sdk.Runtime, frame_event: native_sdk.GpuSurfaceFrameEvent, full_repaint: bool) anyerror!void {
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
        runtime: *native_sdk.Runtime,
        window_id: native_sdk.WindowId,
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

    pub fn setStatusText(self: *@This(), text: []const u8) void {
        const len = @min(text.len, self.status_text_storage.len);
        @memcpy(self.status_text_storage[0..len], text[0..len]);
        self.status_text_len = len;
    }

    fn statusText(self: *const @This()) []const u8 {
        if (self.status_text_len == 0) return initial_component_status_text;
        return self.status_text_storage[0..self.status_text_len];
    }

    fn updateStatus(self: *@This(), runtime: *native_sdk.Runtime, window_id: native_sdk.WindowId, text: []const u8) anyerror!void {
        self.setStatusText(text);
        if (self.canvas_installed) try self.updateComponentsCanvasModel(runtime, window_id);
    }

    fn reportFrameStatus(self: *@This(), runtime: *native_sdk.Runtime, frame_event: native_sdk.GpuSurfaceFrameEvent) anyerror!void {
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

    pub fn updateComponentsCanvasModel(self: *@This(), runtime: *native_sdk.Runtime, window_id: native_sdk.WindowId) anyerror!void {
        var nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
        // Layout under the SAME tokens the display list is emitted
        // with: under geometry pixel snapping, label-hugging intrinsic
        // widths ceil to the snap grid, and only a token-matched layout
        // keeps the renderer's edge snapping from shaving those widths
        // below their labels (eliding text that fits unsnapped).
        const layout = try buildComponentsWidgetLayoutWithStateSizeAndTokens(&nodes, self.virtual_scroll, self.componentUiState(), self.canvas_size, self.componentTokens());
        _ = try runtime.setCanvasWidgetLayout(window_id, canvas_label, layout);
        _ = try runtime.emitCanvasWidgetDisplayListWithStoredTokensAndChrome(window_id, canvas_label, .{
            .prefix_command_count = component_chrome_prefix_commands,
            .suffix_command_count = component_chrome_suffix_commands,
        });
    }

    pub fn componentUiState(self: *const @This()) ComponentUiState {
        return .{
            .theme_mode = self.theme_mode,
            .environment_select_open = self.environment_select_open,
            .environment_index = self.environment_index,
            .surface_overlay = self.surface_overlay,
            .section = self.section,
            .sidebar_width = self.sidebar_width,
            .status_text = self.statusText(),
        };
    }

    fn componentTokens(self: *const @This()) canvas.DesignTokens {
        return componentTokensForScaleMotionAndContrast(self.theme_mode, self.pixel_snap_scale, self.reduce_motion, self.high_contrast);
    }

    fn updatePixelSnapScale(self: *@This(), scale_factor: f32) bool {
        const next = normalizedPixelSnapScale(scale_factor);
        if (@abs(self.pixel_snap_scale - next) < 0.001) return false;
        self.pixel_snap_scale = next;
        return true;
    }

    fn updateCanvasSize(self: *@This(), size: geometry.SizeF) bool {
        const next_sidebar_width = componentSidebarWidthForSize(self.sidebar_width, size);
        const sidebar_changed = @abs(next_sidebar_width - self.sidebar_width) >= 0.001;
        if (sidebar_changed) self.sidebar_width = next_sidebar_width;
        if (componentSizesEqual(self.canvas_size, size)) return sidebar_changed;
        self.canvas_size = size;
        return true;
    }

    fn componentVirtualScrollValue(self: *@This(), id: canvas.ObjectId) ?f32 {
        return switch (id) {
            120 => self.virtual_scroll.nav,
            130 => self.virtual_scroll.behavior,
            150 => self.virtual_scroll.data,
            content_scroll_id => self.virtual_scroll.page,
            else => null,
        };
    }

    fn componentVirtualScrollVelocity(self: *@This(), id: canvas.ObjectId) ?f32 {
        return switch (id) {
            120 => self.virtual_scroll.nav_velocity,
            130 => self.virtual_scroll.behavior_velocity,
            150 => self.virtual_scroll.data_velocity,
            content_scroll_id => self.virtual_scroll.page_velocity,
            else => null,
        };
    }

    fn componentVirtualScrollState(self: *@This(), id: canvas.ObjectId, viewport_extent: f32, content_extent: f32) ?canvas.ScrollState {
        const offset = self.componentVirtualScrollValue(id) orelse return null;
        const velocity = self.componentVirtualScrollVelocity(id) orelse return null;
        return .{
            .offset = offset,
            .velocity = velocity,
            .viewport_extent = viewport_extent,
            .content_extent = @max(viewport_extent, content_extent),
        };
    }

    fn setComponentVirtualScrollValue(self: *@This(), id: canvas.ObjectId, value: f32) anyerror!void {
        switch (id) {
            120 => {
                self.virtual_scroll.nav = value;
                self.virtual_scroll.nav_velocity = 0;
            },
            130 => {
                self.virtual_scroll.behavior = value;
                self.virtual_scroll.behavior_velocity = 0;
            },
            150 => {
                self.virtual_scroll.data = value;
                self.virtual_scroll.data_velocity = 0;
            },
            content_scroll_id => {
                self.virtual_scroll.page = value;
                self.virtual_scroll.page_velocity = 0;
            },
            else => return error.InvalidCommand,
        }
    }

    fn setComponentVirtualScrollState(self: *@This(), id: canvas.ObjectId, state: canvas.ScrollState) anyerror!void {
        switch (id) {
            120 => {
                self.virtual_scroll.nav = state.offset;
                self.virtual_scroll.nav_velocity = state.velocity;
            },
            130 => {
                self.virtual_scroll.behavior = state.offset;
                self.virtual_scroll.behavior_velocity = state.velocity;
            },
            150 => {
                self.virtual_scroll.data = state.offset;
                self.virtual_scroll.data_velocity = state.velocity;
            },
            content_scroll_id => {
                self.virtual_scroll.page = state.offset;
                self.virtual_scroll.page_velocity = state.velocity;
            },
            else => return error.InvalidCommand,
        }
    }

    fn ensurePixelBuffers(self: *@This(), surface_size: geometry.SizeF, scale_factor: f32) anyerror!void {
        const pixel_size = try native_sdk.runtime.canvasSurfacePixelSize(surface_size, scale_factor);
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
