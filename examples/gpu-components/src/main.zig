const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const canvas = zero_native.canvas;
const geometry = zero_native.geometry;

const model = @import("model.zig");
const component_scene = @import("scene.zig");
const test_support = @import("test_support.zig");

const window_width = model.window_width;
const window_height = model.window_height;
const toolbar_height = model.toolbar_height;
const canvas_sidebar_width = model.canvas_sidebar_width;
const canvas_sidebar_min_width = model.canvas_sidebar_min_width;
const canvas_sidebar_max_width = model.canvas_sidebar_max_width;
const canvas_sidebar_min_content_width = model.canvas_sidebar_min_content_width;
const canvas_sidebar_resize_handle_width = model.canvas_sidebar_resize_handle_width;
const canvas_sidebar_resize_line_width = model.canvas_sidebar_resize_line_width;
const statusbar_height = model.statusbar_height;
const canvas_width = model.canvas_width;
const canvas_height = model.canvas_height;
const canvas_content_y = model.canvas_content_y;
const canvas_content_height = model.canvas_content_height;
const default_canvas_size = model.default_canvas_size;
const max_component_pipelines = model.max_component_pipelines;
const max_component_commands = model.max_component_commands;
const max_component_glyphs = model.max_component_glyphs;
const max_component_widgets = model.max_component_widgets;
const component_chrome_prefix_commands = model.component_chrome_prefix_commands;
const component_chrome_suffix_commands = model.component_chrome_suffix_commands;
const catalog_card_width = model.catalog_card_width;
const catalog_card_height = model.catalog_card_height;
const refresh_command = model.refresh_command;
const theme_command = model.theme_command;
const environment_toggle_command = model.environment_toggle_command;
const surface_dialog_command = model.surface_dialog_command;
const surface_drawer_command = model.surface_drawer_command;
const surface_sheet_command = model.surface_sheet_command;
const surface_close_command = model.surface_close_command;
const canvas_label = model.canvas_label;
const primary_button_fill_id = model.primary_button_fill_id;
const project_static_text_id = model.project_static_text_id;
const project_text_id = model.project_text_id;
const project_selection_id = model.project_selection_id;
const project_composition_id = model.project_composition_id;
const search_text_id = model.search_text_id;
const search_selection_id = model.search_selection_id;
const search_composition_id = model.search_composition_id;
const message_text_id = model.message_text_id;
const scroll_track_id = model.scroll_track_id;
const scroll_thumb_id = model.scroll_thumb_id;
const menu_item_text_id = model.menu_item_text_id;
const data_cell_text_id = model.data_cell_text_id;
const environment_select_id = model.environment_select_id;
const environment_select_text_id = model.environment_select_text_id;
const environment_menu_id = model.environment_menu_id;
const environment_option_base_id = model.environment_option_base_id;
const content_scroll_id = model.content_scroll_id;
const canvas_sidebar_id = model.canvas_sidebar_id;
const section_nav_base_id = model.section_nav_base_id;
const canvas_background_id = model.canvas_background_id;
const canvas_toolbar_id = model.canvas_toolbar_id;
const canvas_toolbar_title_id = model.canvas_toolbar_title_id;
const canvas_toolbar_theme_id = model.canvas_toolbar_theme_id;
const canvas_toolbar_refresh_id = model.canvas_toolbar_refresh_id;
const canvas_toolbar_separator_id = model.canvas_toolbar_separator_id;
const canvas_sidebar_resize_line_id = model.canvas_sidebar_resize_line_id;
const canvas_sidebar_resize_handle_id = model.canvas_sidebar_resize_handle_id;
const canvas_status_text_id = model.canvas_status_text_id;
const canvas_status_separator_id = model.canvas_status_separator_id;
const surface_overlay_backdrop_id = model.surface_overlay_backdrop_id;
const surface_overlay_id = model.surface_overlay_id;
const surface_overlay_title_id = model.surface_overlay_title_id;
const surface_overlay_body_id = model.surface_overlay_body_id;
const surface_overlay_close_id = model.surface_overlay_close_id;
const surface_overlay_content_parts = model.surface_overlay_content_parts;
const surface_backdrop_layer = model.surface_backdrop_layer;
const surface_overlay_layer = model.surface_overlay_layer;
const max_surface_overlay_animations = model.max_surface_overlay_animations;
const popover_blur_id = model.popover_blur_id;
const preview_image_id = model.preview_image_id;
const preview_images = component_scene.preview_images;
const environment_options = model.environment_options;
const initial_component_status_text = model.initial_component_status_text;
const max_component_status_text = model.max_component_status_text;
const ComponentVirtualScroll = model.ComponentVirtualScroll;
const ComponentUiState = model.ComponentUiState;
const ComponentSurfaceOverlay = model.ComponentSurfaceOverlay;
const ComponentSection = model.ComponentSection;
const ComponentThemeMode = model.ComponentThemeMode;
const environmentLabel = model.environmentLabel;
const environmentOptionId = model.environmentOptionId;
const environmentOptionIndex = model.environmentOptionIndex;
const environmentNextIndex = model.environmentNextIndex;
const environmentPreviousIndex = model.environmentPreviousIndex;
const environmentCommandIndex = model.environmentCommandIndex;
const componentSectionLabel = model.componentSectionLabel;
const componentSectionCommand = model.componentSectionCommand;
const componentSectionFromCommand = model.componentSectionFromCommand;
const componentSectionNavId = model.componentSectionNavId;
const surfaceOverlayLabel = model.surfaceOverlayLabel;
const surfaceOverlayBody = model.surfaceOverlayBody;
const color = model.color;
const rgba = model.rgba;
const rect = model.rect;
const contentRect = model.contentRect;
const contentRectForSidebar = model.contentRectForSidebar;
const sidebarResizeHandleFrame = model.sidebarResizeHandleFrame;
const sidebarResizeLineFrame = model.sidebarResizeLineFrame;
const componentCommandPartId = model.componentCommandPartId;
const pt = model.pt;

const installComponentsCanvasModel = component_scene.installComponentsCanvasModel;
const buildComponentsDisplayListFromWidgets = component_scene.buildComponentsDisplayListFromWidgets;
const componentSurfaceSize = component_scene.componentSurfaceSize;
const componentStatusbarHeightForSize = component_scene.componentStatusbarHeightForSize;
const componentToolbarHeightForSize = component_scene.componentToolbarHeightForSize;
const componentContentYForSize = component_scene.componentContentYForSize;
const componentContentHeightForSize = component_scene.componentContentHeightForSize;
const componentOverlaySize = component_scene.componentOverlaySize;
const componentSidebarWidthForSize = component_scene.componentSidebarWidthForSize;
const componentVirtualScrollTarget = component_scene.componentVirtualScrollTarget;
const ComponentVirtualKeyboardScrollTarget = component_scene.ComponentVirtualKeyboardScrollTarget;
const componentVirtualKeyboardScrollTarget = component_scene.componentVirtualKeyboardScrollTarget;
const componentVirtualKeyboardScrollDelta = component_scene.componentVirtualKeyboardScrollDelta;
const snapComponentVirtualScrollOffset = component_scene.snapComponentVirtualScrollOffset;
const clampComponentVirtualScrollOffset = component_scene.clampComponentVirtualScrollOffset;
const componentScrollStatesEqual = component_scene.componentScrollStatesEqual;
const componentFrameIntervalMs = component_scene.componentFrameIntervalMs;
const componentVirtualScrollStep = component_scene.componentVirtualScrollStep;
const componentSizesEqual = component_scene.componentSizesEqual;
const buildComponentsDisplayList = component_scene.buildComponentsDisplayList;
const buildComponentsDisplayListForSize = component_scene.buildComponentsDisplayListForSize;
const componentTokens = component_scene.componentTokens;
const componentTokensFor = component_scene.componentTokensFor;
const componentTokensForScale = component_scene.componentTokensForScale;
const componentTokensForScaleAndMotion = component_scene.componentTokensForScaleAndMotion;
const componentTokensForScaleMotionAndContrast = component_scene.componentTokensForScaleMotionAndContrast;
const componentThemeModeForAppearance = component_scene.componentThemeModeForAppearance;
const normalizedPixelSnapScale = component_scene.normalizedPixelSnapScale;
const transparentContentStyle = component_scene.transparentContentStyle;
const buildComponentsWidgetLayout = component_scene.buildComponentsWidgetLayout;
const buildComponentsWidgetLayoutWithScroll = component_scene.buildComponentsWidgetLayoutWithScroll;
const buildComponentsWidgetLayoutWithScrollAndSize = component_scene.buildComponentsWidgetLayoutWithScrollAndSize;
const componentCatalogItems = component_scene.componentCatalogItems;
const componentCatalogItem = component_scene.componentCatalogItem;
const componentCatalogItemFrame = component_scene.componentCatalogItemFrame;
const componentCatalogItemVisible = component_scene.componentCatalogItemVisible;
const componentCatalogPreviewLayout = component_scene.componentCatalogPreviewLayout;
const componentCatalogPreviewChildren = component_scene.componentCatalogPreviewChildren;
const componentCatalogGridHeight = component_scene.componentCatalogGridHeight;
const componentSectionContentHeight = component_scene.componentSectionContentHeight;
const surfaceOverlayKind = component_scene.surfaceOverlayKind;
const surfaceOverlayFrame = component_scene.surfaceOverlayFrame;
const surfaceOverlayFrameForSidebar = component_scene.surfaceOverlayFrameForSidebar;
const appendComponentWidget = component_scene.appendComponentWidget;
const buildComponentsWidgetLayoutWithStateAndSize = component_scene.buildComponentsWidgetLayoutWithStateAndSize;
const componentFrame = component_scene.componentFrame;
const componentFrameStorage = component_scene.componentFrameStorage;
const gpuFrameEvent = component_scene.gpuFrameEvent;
const componentFrameStatus = component_scene.componentFrameStatus;

const componentSnapshotWidget = test_support.componentSnapshotWidget;
const componentStatusText = test_support.componentStatusText;
const expectComponentStatusContains = test_support.expectComponentStatusContains;
const resetComponentDirty = test_support.resetComponentDirty;
const componentWidgetCenter = test_support.componentWidgetCenter;
const dispatchComponentPointerClick = test_support.dispatchComponentPointerClick;
const dispatchComponentPointerClickAtTimestamp = test_support.dispatchComponentPointerClickAtTimestamp;
const dispatchComponentPointerWheel = test_support.dispatchComponentPointerWheel;
const dispatchComponentPointerDrag = test_support.dispatchComponentPointerDrag;
const dispatchComponentPointerDragByDelta = test_support.dispatchComponentPointerDragByDelta;
const dispatchComponentPointerDragPoints = test_support.dispatchComponentPointerDragPoints;
const expectSurfaceTransformAnimation = test_support.expectSurfaceTransformAnimation;
const expectSurfaceAnimationStart = test_support.expectSurfaceAnimationStart;
const expectSurfaceOpacityAnimation = test_support.expectSurfaceOpacityAnimation;
const expectNoSurfaceAnimation = test_support.expectNoSurfaceAnimation;
const expectComponentTextCommand = test_support.expectComponentTextCommand;
const expectComponentRoundedRectFrame = test_support.expectComponentRoundedRectFrame;
const expectComponentFillRectFrame = test_support.expectComponentFillRectFrame;
const expectComponentFillRoundedRectColor = test_support.expectComponentFillRoundedRectColor;
const expectNoSurfaceChrome = test_support.expectNoSurfaceChrome;
const expectNoContentScrollContainerChrome = test_support.expectNoContentScrollContainerChrome;
const rectLooksLikeMainContentContainer = test_support.rectLooksLikeMainContentContainer;
const expectSemanticRole = test_support.expectSemanticRole;
const expectSemantic = test_support.expectSemantic;
const expectComponentWidgetFrame = test_support.expectComponentWidgetFrame;
const expectComponentWidgetIndex = test_support.expectComponentWidgetIndex;
const expectComponentWidgetsDoNotOverlap = test_support.expectComponentWidgetsDoNotOverlap;
const expectComponentRect = test_support.expectComponentRect;
const expectVisiblePixel = test_support.expectVisiblePixel;
const referenceSurfaceSignature = test_support.referenceSurfaceSignature;

const app_permissions = [_][]const u8{ zero_native.security.permission_command, zero_native.security.permission_view };
const shell_views = [_]zero_native.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .min_width = 640, .layer = 12, .role = "Native-rendered component canvas", .accessibility_label = "Native-rendered component gallery canvas", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
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
                } else if (std.mem.eql(u8, command.name, theme_command)) {
                    try self.changeTheme(runtime, command);
                } else if (componentSectionFromCommand(command.name)) |section| {
                    try self.changeSection(runtime, command, section);
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

    fn handleWidgetPointer(self: *@This(), runtime: *zero_native.Runtime, pointer_event: zero_native.runtime.CanvasWidgetPointerEvent) anyerror!void {
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

    fn resizeSidebar(self: *@This(), runtime: *zero_native.Runtime, pointer_event: zero_native.runtime.CanvasWidgetPointerEvent) anyerror!void {
        const next_width = componentSidebarWidthForSize(self.sidebar_width + pointer_event.pointer.delta.dx, self.canvas_size);
        if (@abs(next_width - self.sidebar_width) < 0.001) return;
        self.sidebar_width = next_width;
        try installComponentsCanvasModel(runtime, pointer_event.window_id, self.virtual_scroll, self.componentUiState(), self.componentTokens(), self.canvas_size);
    }

    fn handleWidgetKeyboard(self: *@This(), runtime: *zero_native.Runtime, keyboard_event: zero_native.runtime.CanvasWidgetKeyboardEvent) anyerror!void {
        if (!std.mem.eql(u8, keyboard_event.view_label, canvas_label)) return;
        if (keyboard_event.keyboard.phase != .key_down) return;
        if (try self.handleEnvironmentKeyboard(runtime, keyboard_event)) return;
        const target = keyboard_event.target orelse return;
        const scrolled_id = try self.scrollVirtualWidgetFromKeyboard(runtime, keyboard_event) orelse target.id;
        try self.reportWidgetInteraction(runtime, keyboard_event.window_id, "Keyed", scrolled_id);
    }

    fn handleEnvironmentKeyboard(self: *@This(), runtime: *zero_native.Runtime, keyboard_event: zero_native.runtime.CanvasWidgetKeyboardEvent) anyerror!bool {
        const key = keyboard_event.keyboard.key;
        if (std.ascii.eqlIgnoreCase(key, "tab")) {
            if (!self.environment_select_open) return false;
            self.environment_select_open = false;
            try self.updateComponentsCanvasModel(runtime, keyboard_event.window_id);
            try self.updateStatus(runtime, keyboard_event.window_id, "Environment menu closed.");
            return true;
        }

        if (std.ascii.eqlIgnoreCase(key, "escape")) {
            if (!self.environment_select_open) return false;
            self.environment_select_open = false;
            try self.updateComponentsCanvasModel(runtime, keyboard_event.window_id);
            try self.updateStatus(runtime, keyboard_event.window_id, "Environment menu closed.");
            return true;
        }

        const target = keyboard_event.target orelse return false;
        if (target.id != environment_select_id and environmentOptionIndex(target.id) == null) return false;

        if (std.ascii.eqlIgnoreCase(key, "arrowdown")) {
            try self.moveEnvironmentSelection(runtime, keyboard_event.window_id, environmentNextIndex(self.environment_index));
            return true;
        }

        if (std.ascii.eqlIgnoreCase(key, "arrowup")) {
            try self.moveEnvironmentSelection(runtime, keyboard_event.window_id, environmentPreviousIndex(self.environment_index));
            return true;
        }

        return false;
    }

    fn reportWidgetInteraction(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId, action: []const u8, id: canvas.ObjectId) anyerror!void {
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

    fn scrollVirtualWidget(self: *@This(), runtime: *zero_native.Runtime, pointer_event: zero_native.runtime.CanvasWidgetPointerEvent) anyerror!?canvas.ObjectId {
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

        try self.setComponentVirtualScrollState(id, .{
            .offset = next,
            .velocity = 0,
            .viewport_extent = viewport.height,
            .content_extent = viewport.height + max_offset,
        });
        try self.updateComponentsCanvasModel(runtime, keyboard_event.window_id);
        return id;
    }

    fn stepComponentVirtualScrollForFrame(self: *@This(), runtime: *zero_native.Runtime, frame_event: zero_native.GpuSurfaceFrameEvent) anyerror!bool {
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

    fn refresh(self: *@This(), runtime: *zero_native.Runtime, command: zero_native.CommandEvent) anyerror!void {
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

    fn changeSection(self: *@This(), runtime: *zero_native.Runtime, command: zero_native.CommandEvent, section: ComponentSection) anyerror!void {
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

    fn toggleEnvironmentSelect(self: *@This(), runtime: *zero_native.Runtime, command: zero_native.CommandEvent) anyerror!void {
        self.environment_select_open = !self.environment_select_open;
        try self.updateComponentsCanvasModel(runtime, command.window_id);
        try self.updateStatus(runtime, command.window_id, if (self.environment_select_open) "Environment menu opened." else "Environment menu closed.");
    }

    fn selectEnvironment(self: *@This(), runtime: *zero_native.Runtime, command: zero_native.CommandEvent, index: usize) anyerror!void {
        self.environment_index = @min(index, environment_options.len - 1);
        self.environment_select_open = false;
        try self.updateComponentsCanvasModel(runtime, command.window_id);
        try self.updateEnvironmentSelectedStatus(runtime, command.window_id);
    }

    fn moveEnvironmentSelection(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId, index: usize) anyerror!void {
        if (self.environment_select_open) {
            self.environment_select_open = false;
            try self.updateComponentsCanvasModel(runtime, window_id);
        }
        self.environment_index = @min(index, environment_options.len - 1);
        self.environment_select_open = true;
        try self.updateComponentsCanvasModel(runtime, window_id);
        try self.updateEnvironmentSelectedStatus(runtime, window_id);
    }

    fn updateEnvironmentSelectedStatus(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId) anyerror!void {
        var status_buffer: [96]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "Environment selected: {s}.", .{environmentLabel(self.environment_index)});
        try self.updateStatus(runtime, window_id, status);
    }

    fn openSurfaceOverlay(self: *@This(), runtime: *zero_native.Runtime, command: zero_native.CommandEvent, overlay: ComponentSurfaceOverlay) anyerror!void {
        self.environment_select_open = false;
        self.surface_overlay = overlay;
        try self.updateComponentsCanvasModel(runtime, command.window_id);
        try self.scheduleSurfaceOverlayAnimation(runtime, command.window_id, overlay);

        var status_buffer: [96]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "{s} surface opened.", .{surfaceOverlayLabel(overlay)});
        try self.updateStatus(runtime, command.window_id, status);
    }

    fn closeSurfaceOverlay(self: *@This(), runtime: *zero_native.Runtime, command: zero_native.CommandEvent) anyerror!void {
        if (self.surface_overlay == .none) return;
        self.surface_overlay = .none;
        _ = runtime.clearCanvasRenderAnimations(command.window_id, canvas_label) catch {};
        try self.updateComponentsCanvasModel(runtime, command.window_id);
        try self.updateStatus(runtime, command.window_id, "Surface closed.");
    }

    fn scheduleSurfaceOverlayAnimation(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId, overlay: ComponentSurfaceOverlay) anyerror!void {
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

    fn changeTheme(self: *@This(), runtime: *zero_native.Runtime, command: zero_native.CommandEvent) anyerror!void {
        self.theme_count += 1;
        self.theme_overridden = true;
        self.theme_mode = self.theme_mode.next();
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
        try installComponentsCanvasModel(runtime, 1, self.virtual_scroll, self.componentUiState(), self.componentTokens(), self.canvas_size);
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

    fn setStatusText(self: *@This(), text: []const u8) void {
        const len = @min(text.len, self.status_text_storage.len);
        @memcpy(self.status_text_storage[0..len], text[0..len]);
        self.status_text_len = len;
    }

    fn statusText(self: *const @This()) []const u8 {
        if (self.status_text_len == 0) return initial_component_status_text;
        return self.status_text_storage[0..self.status_text_len];
    }

    fn updateStatus(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId, text: []const u8) anyerror!void {
        self.setStatusText(text);
        if (self.canvas_installed) try self.updateComponentsCanvasModel(runtime, window_id);
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
        const layout = try buildComponentsWidgetLayoutWithStateAndSize(&nodes, self.virtual_scroll, self.componentUiState(), self.canvas_size);
        _ = try runtime.setCanvasWidgetLayout(window_id, canvas_label, layout);
        _ = try runtime.emitCanvasWidgetDisplayListWithStoredTokensAndChrome(window_id, canvas_label, .{
            .prefix_command_count = component_chrome_prefix_commands,
            .suffix_command_count = component_chrome_suffix_commands,
        });
    }

    fn componentUiState(self: *const @This()) ComponentUiState {
        return .{
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

test "gpu components status text state keeps app-owned storage" {
    var app = GpuComponentsApp{};
    defer app.deinit();

    app.setStatusText("Canvas installed.");
    const ui_state = app.componentUiState();

    try std.testing.expectEqualStrings("Canvas installed.", ui_state.status_text);
    try std.testing.expectEqual(@intFromPtr(app.status_text_storage[0..].ptr), @intFromPtr(ui_state.status_text.ptr));
}

test "gpu components display list covers finished live controls" {
    var commands: [max_component_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildComponentsDisplayListFromWidgets(&builder);
    const display_list = builder.displayList();

    try std.testing.expect(display_list.commandCount() >= 53);
    try std.testing.expect(display_list.commandCount() <= max_component_commands);
    try std.testing.expect(display_list.findCommandById(canvas_toolbar_id) != null);
    try std.testing.expect(display_list.findCommandById(canvas_toolbar_title_id) != null);
    try std.testing.expect(display_list.findCommandById(canvas_toolbar_separator_id) != null);
    try std.testing.expect(display_list.findCommandById(canvas_status_separator_id) != null);
    try std.testing.expect(display_list.findCommandById(primary_button_fill_id) != null);
    try std.testing.expect(display_list.findCommandById(project_static_text_id) != null);
    try std.testing.expect(display_list.findCommandById(search_text_id) != null);
    try expectComponentTextCommand(display_list, environment_select_text_id, "Production");
    try std.testing.expect(display_list.findCommandById(scroll_track_id) != null);
    try std.testing.expect(display_list.findCommandById(scroll_thumb_id) != null);
    try std.testing.expect(display_list.findCommandById(popover_blur_id) != null);
    try std.testing.expect(display_list.findCommandById(menu_item_text_id) != null);
    try std.testing.expect(display_list.findCommandById(data_cell_text_id) != null);
    try expectNoContentScrollContainerChrome(display_list);
    try expectComponentFillRectFrame(display_list, canvas_background_id, rect(0, 0, canvas_width, canvas_height));
    const bounds = display_list.bounds().?;
    try std.testing.expect(bounds.x <= 28);
    try std.testing.expect(bounds.y <= 26);
    try std.testing.expect(bounds.width >= 916);
    try std.testing.expect(bounds.height >= 616);
}

test "gpu components layout keeps finished controls visually separated" {
    var nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const layout = try buildComponentsWidgetLayoutWithScroll(&nodes, .{});

    try std.testing.expect(layout.findById(canvas_toolbar_id) == null);
    try std.testing.expect(layout.findById(canvas_toolbar_title_id) == null);
    try expectComponentWidgetFrame(layout, canvas_toolbar_theme_id, rect(292, 11, 174, 30));
    try expectComponentWidgetFrame(layout, canvas_toolbar_refresh_id, rect(482, 11, 86, 30));
    try std.testing.expect(layout.findById(canvas_toolbar_separator_id) == null);
    try expectComponentWidgetFrame(layout, canvas_sidebar_id, rect(0, canvas_content_y, canvas_sidebar_width, canvas_content_height));
    try std.testing.expectEqual(@as(?f32, 0), layout.findById(canvas_sidebar_id).?.widget.style.radius);
    try expectComponentWidgetFrame(layout, canvas_sidebar_resize_line_id, sidebarResizeLineFrame(canvas_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, canvas_sidebar_resize_handle_id, sidebarResizeHandleFrame(canvas_sidebar_width, canvas_content_height));
    try std.testing.expectEqual(canvas.WidgetCursor.resize_horizontal, layout.cursorForHit(layout.hitTest(pt(canvas_sidebar_width, canvas_content_y + 12))));
    try std.testing.expectEqual(canvas.WidgetCursor.resize_horizontal, layout.cursorForHit(layout.hitTest(sidebarResizeHandleFrame(canvas_sidebar_width, canvas_content_height).center())));
    try std.testing.expectEqual(canvas.WidgetCursor.resize_horizontal, layout.cursorForHit(layout.hitTest(pt(canvas_sidebar_width, canvas_content_y + canvas_content_height - 12))));
    try expectComponentWidgetFrame(layout, content_scroll_id, rect(canvas_sidebar_width, canvas_content_y, canvas_width - canvas_sidebar_width, canvas_content_height));
    const transparent_content_style = transparentContentStyle();
    const content_scroll = layout.findById(content_scroll_id).?.widget;
    try std.testing.expectEqualDeep(transparent_content_style.background, content_scroll.style.background);
    try std.testing.expectEqualDeep(transparent_content_style.border, content_scroll.style.border);
    try std.testing.expectEqual(transparent_content_style.radius, content_scroll.style.radius);
    try std.testing.expectEqual(transparent_content_style.stroke_width, content_scroll.style.stroke_width);
    const content_scroll_index = try expectComponentWidgetIndex(layout, content_scroll_id);
    try std.testing.expectEqual(content_scroll_index, layout.findById(101).?.parent_index.?);
    try expectComponentWidgetFrame(layout, canvas_status_text_id, rect(0, canvas_content_y + canvas_content_height, canvas_width, statusbar_height));
    try std.testing.expectEqual(canvas.WidgetKind.status_bar, layout.findById(canvas_status_text_id).?.widget.kind);
    try std.testing.expectEqualStrings(initial_component_status_text, layout.findById(canvas_status_text_id).?.widget.text);
    try expectComponentWidgetFrame(layout, componentSectionNavId(.controls), rect(14, canvas_content_y + 78, 180, 34));
    try std.testing.expect(layout.findById(componentSectionNavId(.controls)).?.widget.state.selected);
    try expectComponentWidgetFrame(layout, 111, contentRect(64, 124, 148, 34));
    try expectComponentWidgetFrame(layout, 112, contentRect(230, 124, 172, 34));
    try expectComponentWidgetFrame(layout, 113, contentRect(64, 176, 132, 30));
    try expectComponentWidgetFrame(layout, 114, contentRect(230, 176, 116, 30));
    try expectComponentWidgetFrame(layout, 215, contentRect(356, 176, 60, 30));
    try expectComponentWidgetFrame(layout, 115, contentRect(64, 232, 176, 28));
    try expectComponentWidgetFrame(layout, 116, contentRect(266, 242, 134, 8));
    try expectComponentWidgetFrame(layout, 167, contentRect(64, 272, 160, 28));
    try expectComponentWidgetFrame(layout, 168, contentRect(64, 324, 148, 34));
    try expectComponentWidgetFrame(layout, 171, contentRect(64, 370, 336, 72));
    try expectComponentWidgetFrame(layout, 172, contentRect(64, 454, 180, 34));
    try std.testing.expect(layout.findById(environment_menu_id) == null);
    try std.testing.expect(layout.findById(environmentOptionId(0)) == null);
    try expectComponentWidgetFrame(layout, 120, contentRect(456, 124, 170, 56));
    try expectComponentWidgetFrame(layout, 130, contentRect(652, 124, 186, 56));
    try std.testing.expect(layout.findById(179) == null);
    try std.testing.expect(layout.findById(180) == null);
    try std.testing.expect(layout.findById(181) == null);
    try std.testing.expect(layout.findById(173) == null);
    try std.testing.expect(layout.findById(178) == null);
    try std.testing.expect(layout.findById(213) == null);
    try std.testing.expect(layout.findById(214) == null);
    try expectComponentWidgetFrame(layout, 174, contentRect(456, 384, 276, 156));
    try expectComponentWidgetFrame(layout, 175, contentRect(456, 560, 124, 40));
    try expectComponentWidgetFrame(layout, 176, contentRect(594, 560, 108, 40));
    try expectComponentWidgetFrame(layout, 177, contentRect(716, 560, 108, 40));
    try expectComponentWidgetFrame(layout, 140, contentRect(456, 216, 260, 126));
    try std.testing.expectEqualStrings("Team plan", layout.findById(174).?.widget.text);
    try std.testing.expectEqualStrings("$29 / month", layout.findById(232).?.widget.text);
    try std.testing.expectEqualStrings("Copy invite link", layout.findById(142).?.widget.text);
    try expectComponentWidgetsDoNotOverlap(layout, 111, 112);
    try expectComponentWidgetsDoNotOverlap(layout, 113, 114);
    try expectComponentWidgetsDoNotOverlap(layout, 114, 215);
    try expectComponentWidgetsDoNotOverlap(layout, 115, 116);
    try expectComponentWidgetsDoNotOverlap(layout, 171, 168);
    try expectComponentWidgetsDoNotOverlap(layout, 172, 171);
    try expectComponentWidgetsDoNotOverlap(layout, 106, 120);
    try expectComponentWidgetsDoNotOverlap(layout, 120, 130);
    try expectComponentWidgetsDoNotOverlap(layout, 130, 140);
    try expectComponentWidgetsDoNotOverlap(layout, 174, 140);
    try expectComponentWidgetsDoNotOverlap(layout, 175, 174);
    try expectComponentWidgetsDoNotOverlap(layout, 175, 176);
    try expectComponentWidgetsDoNotOverlap(layout, 176, 177);
    try expectComponentWidgetsDoNotOverlap(layout, 175, 149);
    try expectComponentWidgetsDoNotOverlap(layout, 176, 149);
    try expectComponentWidgetsDoNotOverlap(layout, 177, 149);

    try std.testing.expect(layout.findById(151) == null);
    try expectComponentWidgetFrame(layout, 150, contentRect(64, 628, 360, 28));
    try expectComponentWidgetFrame(layout, 152, contentRect(64, 628, 360, 28));
    try expectComponentWidgetFrame(layout, 156, contentRect(64, 628, 180, 28));
    try expectComponentWidgetFrame(layout, 157, contentRect(244, 628, 180, 28));
    try expectComponentWidgetFrame(layout, 160, contentRect(456, 628, 176, 32));
    try expectComponentWidgetsDoNotOverlap(layout, 150, 160);
    try expectComponentWidgetsDoNotOverlap(layout, 140, 149);

    var catalog_nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const catalog_layout = try buildComponentsWidgetLayoutWithStateAndSize(&catalog_nodes, .{}, .{ .section = .components }, default_canvas_size);
    try std.testing.expect(!catalog_layout.findById(componentSectionNavId(.controls)).?.widget.state.selected);
    try std.testing.expect(catalog_layout.findById(componentSectionNavId(.components)).?.widget.state.selected);
    try expectComponentWidgetFrame(catalog_layout, 181, contentRect(64, 124, catalog_card_width, catalog_card_height));
    try expectComponentWidgetFrame(catalog_layout, 182, contentRect(342, 124, catalog_card_width, catalog_card_height));
    try expectComponentWidgetFrame(catalog_layout, 184, contentRect(64, 274, catalog_card_width, catalog_card_height));
    try std.testing.expect(catalog_layout.findById(180) == null);
    try std.testing.expect(catalog_layout.findById(212) == null);
    try std.testing.expect(catalog_layout.findById(18101) != null);

    var open_nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const open_layout = try buildComponentsWidgetLayoutWithStateAndSize(&open_nodes, .{}, .{
        .environment_select_open = true,
        .environment_index = 1,
    }, default_canvas_size);
    const open_select = open_layout.findById(environment_select_id).?.widget;
    try std.testing.expectEqualStrings("Preview", open_select.text);
    try std.testing.expectEqual(@as(?bool, true), open_select.state.expanded);
    try expectComponentWidgetFrame(open_layout, environment_menu_id, contentRect(64, 494, 180, 104));
    try expectComponentWidgetFrame(open_layout, environmentOptionId(0), contentRect(68, 498, 172, 28));
    try expectComponentWidgetFrame(open_layout, environmentOptionId(1), contentRect(68, 528, 172, 28));
    try expectComponentWidgetFrame(open_layout, environmentOptionId(2), contentRect(68, 558, 172, 28));
    try std.testing.expect(!open_layout.findById(environmentOptionId(0)).?.widget.state.selected);
    try std.testing.expect(open_layout.findById(environmentOptionId(1)).?.widget.state.selected);
    try std.testing.expect(!open_layout.findById(environmentOptionId(2)).?.widget.state.selected);

    var dialog_nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const dialog_layout = try buildComponentsWidgetLayoutWithStateAndSize(&dialog_nodes, .{}, .{
        .surface_overlay = .dialog,
    }, default_canvas_size);
    const dialog_frame = surfaceOverlayFrame(default_canvas_size, .dialog);
    try expectComponentWidgetFrame(dialog_layout, surface_overlay_backdrop_id, rect(0, canvas_content_y, canvas_width, canvas_content_height));
    try expectComponentWidgetFrame(dialog_layout, surface_overlay_id, dialog_frame);
    try expectComponentWidgetFrame(dialog_layout, surface_overlay_title_id, rect(dialog_frame.x + 20, dialog_frame.y + 20, dialog_frame.width - 40, 28));
    try expectComponentWidgetFrame(dialog_layout, surface_overlay_body_id, rect(dialog_frame.x + 20, dialog_frame.y + 68, dialog_frame.width - 40, 44));
    try expectComponentWidgetFrame(dialog_layout, surface_overlay_close_id, rect(dialog_frame.x + dialog_frame.width - 116, dialog_frame.y + dialog_frame.height - 54, 96, 34));
    try std.testing.expectEqual(@as(i32, surface_backdrop_layer), dialog_layout.findById(surface_overlay_backdrop_id).?.widget.layer.?);
    try std.testing.expectEqual(@as(i32, surface_overlay_layer), dialog_layout.findById(surface_overlay_id).?.widget.layer.?);
    try std.testing.expect(dialog_layout.findById(surface_overlay_id).?.widget.layout.clip_content);

    var dialog_commands: [max_component_commands]canvas.CanvasCommand = undefined;
    var dialog_builder = canvas.Builder.init(&dialog_commands);
    try dialog_layout.emitDisplayList(&dialog_builder, componentTokens());
    const dialog_display_list = dialog_builder.displayList();
    const popover_fill = dialog_display_list.findCommandById(140 * 16 + 2).?;
    const backdrop_fill = dialog_display_list.findCommandById(surface_overlay_backdrop_id * 16 + 2).?;
    const dialog_fill = dialog_display_list.findCommandById(surface_overlay_id * 16 + 2).?;
    try std.testing.expect(backdrop_fill.index > popover_fill.index);
    try std.testing.expect(dialog_fill.index > backdrop_fill.index);

    var drawer_nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const drawer_layout = try buildComponentsWidgetLayoutWithStateAndSize(&drawer_nodes, .{}, .{
        .surface_overlay = .drawer,
    }, default_canvas_size);
    const drawer_frame = surfaceOverlayFrame(default_canvas_size, .drawer);
    try expectComponentWidgetFrame(drawer_layout, surface_overlay_id, drawer_frame);
    try std.testing.expectEqual(@as(f32, 0), drawer_frame.x);
    try std.testing.expectEqual(canvas_width, drawer_frame.width);
    try std.testing.expectEqual(canvas_content_y + canvas_content_height, drawer_frame.y + drawer_frame.height);

    var sheet_nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const sheet_layout = try buildComponentsWidgetLayoutWithStateAndSize(&sheet_nodes, .{}, .{
        .surface_overlay = .sheet,
    }, default_canvas_size);
    const sheet_frame = surfaceOverlayFrame(default_canvas_size, .sheet);
    try expectComponentWidgetFrame(sheet_layout, surface_overlay_id, sheet_frame);
    try std.testing.expectEqual(canvas_width, sheet_frame.x + sheet_frame.width);
    try std.testing.expectEqual(canvas_content_y, sheet_frame.y);
    try std.testing.expectEqual(canvas_content_height, sheet_frame.height);

    var scrolled_nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const scrolled_layout = try buildComponentsWidgetLayoutWithScroll(&scrolled_nodes, .{
        .nav = 28,
        .behavior = 56,
        .data = 56,
    });
    try std.testing.expect(scrolled_layout.findById(121) == null);
    try expectComponentWidgetFrame(scrolled_layout, 122, contentRect(456, 124, 170, 28));
    try expectComponentWidgetFrame(scrolled_layout, 123, contentRect(456, 152, 170, 28));
    try std.testing.expect(scrolled_layout.findById(132) == null);
    try expectComponentWidgetFrame(scrolled_layout, 133, contentRect(652, 124, 186, 28));
    try expectComponentWidgetFrame(scrolled_layout, 134, contentRect(652, 152, 186, 28));
    try std.testing.expect(scrolled_layout.findById(152) == null);
    try expectComponentWidgetFrame(scrolled_layout, 153, contentRect(64, 628, 360, 28));
    try expectComponentWidgetFrame(scrolled_layout, 158, contentRect(64, 628, 180, 28));
    try expectComponentWidgetFrame(scrolled_layout, 159, contentRect(244, 628, 180, 28));

    var smooth_scrolled_nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const smooth_scrolled_layout = try buildComponentsWidgetLayoutWithScroll(&smooth_scrolled_nodes, .{
        .behavior = 11,
    });
    try expectComponentWidgetFrame(smooth_scrolled_layout, 131, contentRect(652, 113, 186, 28));
    try expectComponentWidgetFrame(smooth_scrolled_layout, 132, contentRect(652, 141, 186, 28));
    try expectComponentWidgetFrame(smooth_scrolled_layout, 133, contentRect(652, 169, 186, 28));
}

test "gpu components layout supports resized sidebar width" {
    const resized_sidebar_width: f32 = 280;
    var nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const layout = try buildComponentsWidgetLayoutWithStateAndSize(&nodes, .{}, .{
        .sidebar_width = resized_sidebar_width,
    }, default_canvas_size);

    try expectComponentWidgetFrame(layout, canvas_sidebar_id, rect(0, canvas_content_y, resized_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, content_scroll_id, rect(resized_sidebar_width, canvas_content_y, canvas_width - resized_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, canvas_sidebar_resize_handle_id, sidebarResizeHandleFrame(resized_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, componentSectionNavId(.controls), rect(14, canvas_content_y + 78, resized_sidebar_width - 28, 34));
    try expectComponentWidgetFrame(layout, 111, contentRectForSidebar(resized_sidebar_width, 64, 124, 148, 34));
    try std.testing.expectEqual(canvas.WidgetCursor.resize_horizontal, layout.cursorForHit(layout.hitTest(sidebarResizeHandleFrame(resized_sidebar_width, canvas_content_height).center())));

    var commands: [max_component_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildComponentsDisplayListForSize(&builder, layout, componentTokens(), default_canvas_size);
    try std.testing.expect(builder.displayList().findCommandById(3) == null);

    var dialog_nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const dialog_layout = try buildComponentsWidgetLayoutWithStateAndSize(&dialog_nodes, .{}, .{
        .surface_overlay = .dialog,
        .sidebar_width = resized_sidebar_width,
    }, default_canvas_size);
    const resized_dialog_frame = surfaceOverlayFrameForSidebar(default_canvas_size, .dialog, resized_sidebar_width);
    try expectComponentWidgetFrame(dialog_layout, surface_overlay_id, resized_dialog_frame);
    try std.testing.expectApproxEqAbs(canvas_width * 0.5, resized_dialog_frame.center().x, 0.001);

    var drawer_nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const drawer_layout = try buildComponentsWidgetLayoutWithStateAndSize(&drawer_nodes, .{}, .{
        .surface_overlay = .drawer,
        .sidebar_width = resized_sidebar_width,
    }, default_canvas_size);
    const resized_drawer_frame = surfaceOverlayFrameForSidebar(default_canvas_size, .drawer, resized_sidebar_width);
    try expectComponentWidgetFrame(drawer_layout, surface_overlay_id, resized_drawer_frame);
    try std.testing.expectEqual(@as(f32, 0), resized_drawer_frame.x);
    try std.testing.expectEqual(canvas_width, resized_drawer_frame.width);
}

test "gpu components combined virtual scroll state stays within display budget" {
    var commands: [max_component_commands]canvas.CanvasCommand = undefined;
    var nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    var builder = canvas.Builder.init(&commands);
    const layout = try buildComponentsWidgetLayoutWithScroll(&nodes, .{
        .page = 24,
        .nav = 28,
        .behavior = 56,
        .data = 56,
    });
    try buildComponentsDisplayList(&builder, layout, componentTokens());
    const display_list = builder.displayList();

    try std.testing.expect(display_list.commandCount() <= max_component_commands);
    try std.testing.expect(display_list.findCommandById(scroll_track_id) != null);
    try std.testing.expect(display_list.findCommandById(scroll_thumb_id) != null);
    try std.testing.expect(layout.findById(content_scroll_id).?.widget.value == 24);
    try std.testing.expect(layout.findById(120).?.widget.value == 28);
    try std.testing.expect(layout.findById(130).?.widget.value == 56);
    try std.testing.expect(layout.findById(150).?.widget.value == 56);
    try std.testing.expect(layout.findById(180) == null);
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
    try std.testing.expectEqual(@as(usize, 0), frame.image_plan.imageCount());
    try std.testing.expectEqual(@as(usize, 0), frame.image_cache_plan.uploadCount());
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

    try std.testing.expectEqual(@as(u64, 4024187964698946890), referenceSurfaceSignature(pixels));
    try expectVisiblePixel(surface.pixelRgba8(36, 36));
    try expectVisiblePixel(surface.pixelRgba8(92, 88));
    try expectVisiblePixel(surface.pixelRgba8(330, 160));
}

test "gpu components catalog previews use canonical built-in foundations" {
    const items = componentCatalogItems();
    try std.testing.expectEqual(canvas.builtin_component_kinds.len, items.len);

    for (items, 0..) |item, index| {
        const kind = canvas.builtin_component_kinds[index];
        const descriptor = canvas.builtinComponentDescriptor(kind);
        try std.testing.expectEqual(@as(canvas.ObjectId, @intCast(181 + index)), item.id);
        try std.testing.expectEqual(canvas.WidgetKind.card, item.kind);
        try std.testing.expectEqualStrings(descriptor.name, item.text);
        try std.testing.expectEqualStrings(descriptor.name, item.semantics.label);
    }

    for (canvas.builtin_component_kinds) |kind| {
        try std.testing.expect(componentCatalogPreviewChildren(kind).len > 0);
    }
    try std.testing.expectEqual(@as(usize, 1), componentCatalogPreviewChildren(.button_group).len);
    try std.testing.expectEqual(canvas.WidgetKind.button_group, componentCatalogPreviewChildren(.button_group)[0].kind);
    try std.testing.expectEqual(@as(usize, 1), componentCatalogPreviewChildren(.pagination).len);
    try std.testing.expectEqual(canvas.WidgetKind.pagination, componentCatalogPreviewChildren(.pagination)[0].kind);
    try std.testing.expectEqual(@as(usize, 1), componentCatalogPreviewChildren(.table).len);
    try std.testing.expectEqual(canvas.WidgetKind.table, componentCatalogPreviewChildren(.table)[0].kind);
    try std.testing.expectEqual(@as(f32, 28), componentCatalogPreviewLayout(.textarea).min_size.height);
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

    try expectSemanticRole(semantics, content_scroll_id, .group);
    try expectSemanticRole(semantics, canvas_toolbar_theme_id, .tab);
    try expectSemanticRole(semantics, canvas_toolbar_refresh_id, .button);
    try expectSemanticRole(semantics, canvas_sidebar_id, .group);
    try expectSemanticRole(semantics, componentSectionNavId(.controls), .listitem);
    try expectSemanticRole(semantics, componentSectionNavId(.components), .listitem);
    try expectSemanticRole(semantics, 104, .button);
    try expectSemanticRole(semantics, 105, .button);
    try expectSemanticRole(semantics, 106, .group);
    try expectSemanticRole(semantics, 111, .textbox);
    try expectSemanticRole(semantics, 112, .textbox);
    try expectSemanticRole(semantics, 113, .checkbox);
    try expectSemanticRole(semantics, 114, .switch_control);
    try expectSemanticRole(semantics, 215, .button);
    try expectSemanticRole(semantics, 115, .slider);
    try expectSemanticRole(semantics, 116, .progressbar);
    try expectSemanticRole(semantics, 117, .tab);
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
    try expectSemanticRole(semantics, 174, .group);
    try expectSemanticRole(semantics, 175, .button);
    try expectSemanticRole(semantics, 176, .button);
    try expectSemanticRole(semantics, 177, .button);

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
    try std.testing.expectEqual(@as(?usize, 0), expectSemantic(semantics, 156).grid_column_index);

    var catalog_nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const catalog_layout = try buildComponentsWidgetLayoutWithStateAndSize(&catalog_nodes, .{}, .{ .section = .components }, default_canvas_size);
    var catalog_semantics_buffer: [max_component_widgets]canvas.WidgetSemanticsNode = undefined;
    const catalog_semantics = try catalog_layout.collectSemantics(&catalog_semantics_buffer);
    try expectSemanticRole(catalog_semantics, 181, .group);
    const first_catalog_item = expectSemantic(catalog_semantics, 181);
    try std.testing.expect(first_catalog_item.state.selected);
    try std.testing.expectEqualStrings(canvas.builtin_component_names[0], first_catalog_item.label);
    try expectSemanticRole(catalog_semantics, 189, .group);
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

    var commands: [3]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try layout.emitDisplayList(&builder, componentTokens());
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), display_list.commandCount());
    switch (display_list.commands[0]) {
        .push_clip => |clip| {
            try std.testing.expectEqual(@as(canvas.ObjectId, 190 * 16 + 2), clip.id);
            try std.testing.expectEqualDeep(rect(12, 14, 86, 54), clip.rect);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .draw_image => |draw| {
            try std.testing.expectEqual(@as(canvas.ObjectId, 190 * 16 + 1), draw.id);
            try std.testing.expectEqual(@as(canvas.ImageId, preview_image_id), draw.image_id);
            try std.testing.expectEqual(canvas.ImageFit.cover, draw.fit);
            try std.testing.expectEqual(canvas.ImageSampling.nearest, draw.sampling);
            try std.testing.expectEqual(@as(f32, 0.82), draw.opacity);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(display_list.commands[2] == .pop_clip);
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
        .frame = geometry.RectF.init(0, 0, canvas_width + 320, canvas_height),
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
    try std.testing.expect(display_list.findCommandById(3) == null);

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
    const component_combobox = componentSnapshotWidget(snapshot, 112).?;
    try std.testing.expectEqualStrings("textbox", component_combobox.role);
    try std.testing.expectEqualStrings("Component combobox", component_combobox.name);
    try std.testing.expectEqualStrings("components", component_combobox.text_value);
    try std.testing.expect(component_combobox.actions.set_text);
    try std.testing.expect(component_combobox.actions.set_selection);
    try std.testing.expect(componentSnapshotWidget(snapshot, 113).?.actions.toggle);
    try std.testing.expect(componentSnapshotWidget(snapshot, 114).?.selected);
    const bold_toggle = componentSnapshotWidget(snapshot, 215).?;
    try std.testing.expectEqualStrings("button", bold_toggle.role);
    try std.testing.expect(bold_toggle.selected);
    try std.testing.expect(bold_toggle.actions.toggle);
    try std.testing.expect(!bold_toggle.actions.press);
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
    try std.testing.expectEqual(@as(?bool, false), select.expanded);
    try std.testing.expect(select.actions.press);
    try std.testing.expect(componentSnapshotWidget(snapshot, environment_menu_id) == null);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 172 press");
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(app.environment_select_open);
    const open_select = componentSnapshotWidget(snapshot, environment_select_id).?;
    try std.testing.expectEqual(@as(?bool, true), open_select.expanded);
    const environment_menu = componentSnapshotWidget(snapshot, environment_menu_id).?;
    try std.testing.expectEqualStrings("menu", environment_menu.role);
    const production_option = componentSnapshotWidget(snapshot, environmentOptionId(0)).?;
    try std.testing.expectEqualStrings("menuitem", production_option.role);
    try std.testing.expect(production_option.selected);
    try std.testing.expect(production_option.actions.press);
    try std.testing.expect(production_option.actions.select);

    resetComponentDirty(&harness.runtime);
    var environment_option_action_buffer: [80]u8 = undefined;
    const environment_option_action = try std.fmt.bufPrint(&environment_option_action_buffer, "widget-action components-canvas {d} press", .{environmentOptionId(2)});
    try harness.runtime.dispatchAutomationCommand(app.app(), environment_option_action);
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(!app.environment_select_open);
    try std.testing.expectEqual(@as(usize, 2), app.environment_index);
    try std.testing.expect(componentSnapshotWidget(snapshot, environment_menu_id) == null);
    try std.testing.expectEqual(@as(?bool, false), componentSnapshotWidget(snapshot, environment_select_id).?.expanded);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentTextCommand(display_list, environment_select_text_id, "Staging");
    try expectComponentStatusContains(&harness.runtime, "Environment selected: Staging.");
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
    try std.testing.expect(componentSnapshotWidget(snapshot, 180) == null);
    try std.testing.expect(componentSnapshotWidget(snapshot, 181) == null);
    const dialog_launcher = componentSnapshotWidget(snapshot, 175).?;
    try std.testing.expectEqualStrings("button", dialog_launcher.role);
    try std.testing.expect(dialog_launcher.actions.press);
    const drawer_launcher = componentSnapshotWidget(snapshot, 176).?;
    try std.testing.expectEqualStrings("button", drawer_launcher.role);
    try std.testing.expect(drawer_launcher.actions.press);
    const sheet_launcher = componentSnapshotWidget(snapshot, 177).?;
    try std.testing.expectEqualStrings("button", sheet_launcher.role);
    try std.testing.expect(sheet_launcher.actions.press);

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

    try expectComponentStatusContains(&harness.runtime, "Keyed slider #115");

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 130 increment");
    snapshot = harness.runtime.automationSnapshot("Components");
    const keyed_scroll = componentSnapshotWidget(snapshot, 130).?;
    try std.testing.expectApproxEqAbs(@as(f32, 84), keyed_scroll.scroll.offset, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 84), app.virtual_scroll.behavior, 0.001);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try std.testing.expect(display_list.findCommandById(scroll_track_id) != null);

    try expectComponentStatusContains(&harness.runtime, "Keyed scroll_view #130: offset 84");

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 120 increment");
    snapshot = harness.runtime.automationSnapshot("Components");
    const keyed_list = componentSnapshotWidget(snapshot, 120).?;
    try std.testing.expectApproxEqAbs(@as(f32, 56), keyed_list.scroll.offset, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 56), app.virtual_scroll.nav, 0.001);
    try expectComponentStatusContains(&harness.runtime, "Keyed list #120: offset 56");

    resetComponentDirty(&harness.runtime);
    const table_packet_count = harness.null_platform.gpu_surface_packet_present_count;
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 150 increment");
    snapshot = harness.runtime.automationSnapshot("Components");
    const keyed_grid = componentSnapshotWidget(snapshot, 150).?;
    try std.testing.expectApproxEqAbs(@as(f32, 56), keyed_grid.scroll.offset, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 56), app.virtual_scroll.data, 0.001);
    try std.testing.expect(harness.runtime.invalidated);
    try expectComponentStatusContains(&harness.runtime, "Keyed table #150: offset 56");
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 3,
        .timestamp_ns = 1_032_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqual(table_packet_count + 1, harness.null_platform.gpu_surface_packet_present_count);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 142 select");
    snapshot = harness.runtime.automationSnapshot("Components");
    const selected_menu_item = componentSnapshotWidget(snapshot, 142).?;
    try std.testing.expect(selected_menu_item.focused);
    try std.testing.expectApproxEqAbs(@as(f32, 1), selected_menu_item.value.?, 0.001);

    resetComponentDirty(&harness.runtime);
    var section_action_buffer: [80]u8 = undefined;
    const section_action = try std.fmt.bufPrint(&section_action_buffer, "widget-action components-canvas {d} press", .{componentSectionNavId(.components)});
    try harness.runtime.dispatchAutomationCommand(app.app(), section_action);
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expectEqual(ComponentSection.components, app.section);
    try std.testing.expect(componentSnapshotWidget(snapshot, 111) == null);
    try std.testing.expect(componentSnapshotWidget(snapshot, 181) != null);
    try std.testing.expect(componentSnapshotWidget(snapshot, 189) != null);
}

test "gpu components keeps textarea text when opening inputs dropdown" {
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

    var inputs_section_action_buffer: [80]u8 = undefined;
    const inputs_section_action = try std.fmt.bufPrint(&inputs_section_action_buffer, "widget-action components-canvas {d} press", .{componentSectionNavId(.inputs)});
    try harness.runtime.dispatchAutomationCommand(app.app(), inputs_section_action);
    var snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expectEqual(ComponentSection.inputs, app.section);
    try std.testing.expect(componentSnapshotWidget(snapshot, 171) != null);

    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 171 set-text Typed textarea draft");
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expectEqualStrings("Typed textarea draft", componentSnapshotWidget(snapshot, 171).?.text_value);
    var display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentTextCommand(display_list, message_text_id, "Typed textarea draft");

    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 172 press");
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(app.environment_select_open);
    try std.testing.expectEqual(@as(?bool, true), componentSnapshotWidget(snapshot, environment_select_id).?.expanded);
    try std.testing.expectEqualStrings("Typed textarea draft", componentSnapshotWidget(snapshot, 171).?.text_value);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentTextCommand(display_list, message_text_id, "Typed textarea draft");
}

test "gpu components virtual scroll clamps at edges" {
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
        .frame_interval_ns = 16_000_000,
        .nonblank = true,
    } });

    app.virtual_scroll.behavior = 0;
    app.virtual_scroll.behavior_velocity = 0;
    try app.updateComponentsCanvasModel(&harness.runtime, 1);
    try dispatchComponentPointerWheel(&harness.runtime, app_handle, 130, -40);
    try std.testing.expectEqual(@as(f32, 0), app.virtual_scroll.behavior);
    try std.testing.expectEqual(@as(f32, 0), app.virtual_scroll.behavior_velocity);

    var snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expectEqual(@as(f32, 0), componentSnapshotWidget(snapshot, 130).?.scroll.offset);
    var layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try expectComponentWidgetFrame(layout, 131, contentRect(652, 124, 186, 28));

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 1_016_000_000,
        .frame_interval_ns = 16_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqual(@as(f32, 0), app.virtual_scroll.behavior);
    try std.testing.expectEqual(@as(f32, 0), app.virtual_scroll.behavior_velocity);
    layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try expectComponentWidgetFrame(layout, 131, contentRect(652, 124, 186, 28));

    const max_behavior_offset: f32 = 84;
    app.virtual_scroll.behavior = max_behavior_offset;
    app.virtual_scroll.behavior_velocity = 0;
    try app.updateComponentsCanvasModel(&harness.runtime, 1);
    try dispatchComponentPointerWheel(&harness.runtime, app_handle, 130, 40);
    try std.testing.expectEqual(max_behavior_offset, app.virtual_scroll.behavior);
    try std.testing.expectEqual(@as(f32, 0), app.virtual_scroll.behavior_velocity);

    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expectEqual(max_behavior_offset, componentSnapshotWidget(snapshot, 130).?.scroll.offset);
    layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    const bottom_range = layout.virtualRangeById(130).?;
    try std.testing.expectEqual(max_behavior_offset, bottom_range.scroll_offset);
    try std.testing.expectEqual(max_behavior_offset, bottom_range.layout_offset);
    try expectComponentWidgetFrame(layout, 134, contentRect(652, 124, 186, 28));

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 40,
        .timestamp_ns = 1_640_000_000,
        .frame_interval_ns = 16_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqual(max_behavior_offset, app.virtual_scroll.behavior);
    try std.testing.expectEqual(@as(f32, 0), app.virtual_scroll.behavior_velocity);
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
    try expectComponentFillRoundedRectColor(display_list, primary_button_fill_id, componentTokensForScale(.light, 2).colors.accent);

    resetComponentDirty(&harness.runtime);
    const packet_count_before_dark = harness.null_platform.gpu_surface_packet_present_count;
    try dispatchComponentPointerClick(&harness.runtime, app_handle, canvas_toolbar_theme_id);

    try std.testing.expectEqual(ComponentThemeMode.dark, app.theme_mode);
    try std.testing.expectEqual(@as(u32, 1), app.theme_count);
    try std.testing.expectEqualDeep(componentTokensForScale(.dark, 2), try harness.runtime.canvasWidgetDesignTokens(1, canvas_label));
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_count > packet_count_before_dark);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentFillRoundedRectColor(display_list, primary_button_fill_id, componentTokensForScale(.dark, 2).colors.accent);
    try expectComponentStatusContains(&harness.runtime, "GPU component theme: Dark from native_view");

    const packet_count_before_high = harness.null_platform.gpu_surface_packet_present_count;
    try dispatchComponentPointerClick(&harness.runtime, app_handle, canvas_toolbar_theme_id);

    try std.testing.expectEqual(ComponentThemeMode.high, app.theme_mode);
    try std.testing.expectEqual(@as(u32, 2), app.theme_count);
    try std.testing.expectEqualDeep(componentTokensForScale(.high, 2), try harness.runtime.canvasWidgetDesignTokens(1, canvas_label));
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_count > packet_count_before_high);
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentFillRoundedRectColor(display_list, primary_button_fill_id, componentTokensForScale(.high, 2).colors.accent);
    try expectComponentStatusContains(&harness.runtime, "GPU component theme: High contrast from native_view");

    const themed_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try expectComponentWidgetFrame(themed_layout, 111, contentRect(64, 124, 148, 34));
    try expectComponentWidgetFrame(themed_layout, 160, contentRect(456, 628, 176, 32));
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
    try expectComponentStatusContains(&harness.runtime, "GPU component theme: Light from system appearance.");

    try dispatchComponentPointerClick(&harness.runtime, app_handle, canvas_toolbar_theme_id);
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
    try expectComponentStatusContains(&harness.runtime, "Clicked checkbox #113: off.");

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
    try expectComponentStatusContains(&harness.runtime, "Clicked switch_control #114: off.");

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
    try expectComponentStatusContains(&harness.runtime, "Clicked slider #115");

    resetComponentDirty(&harness.runtime);
    var before_scroll_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    const before_nav_scroll = before_scroll_layout.findById(120).?.widget.value;
    try dispatchComponentPointerWheel(&harness.runtime, app_handle, 120, 20);
    var scrolled_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expectApproxEqAbs(before_nav_scroll + 22, scrolled_layout.findById(120).?.widget.value, 0.001);
    try std.testing.expect(harness.runtime.invalidated);
    try expectComponentStatusContains(&harness.runtime, "Clicked slider #115");
    try std.testing.expect(std.mem.indexOf(u8, try componentStatusText(&harness.runtime), "Scrolled") == null);

    resetComponentDirty(&harness.runtime);
    before_scroll_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    const before_behavior_scroll = before_scroll_layout.findById(130).?.widget.value;
    try dispatchComponentPointerWheel(&harness.runtime, app_handle, 130, 20);
    scrolled_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expectApproxEqAbs(before_behavior_scroll + 22, scrolled_layout.findById(130).?.widget.value, 0.001);
    try std.testing.expect(harness.runtime.invalidated);
    try expectComponentStatusContains(&harness.runtime, "Clicked slider #115");
    try std.testing.expect(std.mem.indexOf(u8, try componentStatusText(&harness.runtime), "Scrolled") == null);

    resetComponentDirty(&harness.runtime);
    before_scroll_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    const before_data_scroll = before_scroll_layout.findById(150).?.widget.value;
    try dispatchComponentPointerWheel(&harness.runtime, app_handle, 150, 20);
    scrolled_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expectApproxEqAbs(before_data_scroll + 22, scrolled_layout.findById(150).?.widget.value, 0.001);
    try std.testing.expect(harness.runtime.invalidated);
    try expectComponentStatusContains(&harness.runtime, "Clicked slider #115");
    try std.testing.expect(std.mem.indexOf(u8, try componentStatusText(&harness.runtime), "Scrolled") == null);

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerClick(&harness.runtime, app_handle, 158);
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(componentSnapshotWidget(snapshot, 158).?.selected);

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerClick(&harness.runtime, app_handle, 142);
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expectApproxEqAbs(@as(f32, 1), componentSnapshotWidget(snapshot, 142).?.value.?, 0.001);
    try std.testing.expect(harness.runtime.invalidated);
    try expectComponentStatusContains(&harness.runtime, "Clicked menu_item #142: selected.");

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerClick(&harness.runtime, app_handle, 104);
    try std.testing.expectEqual(@as(u32, 1), app.refresh_count);
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(componentSnapshotWidget(snapshot, 104).?.focused);
    const refreshed_layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expectEqual(@as(f32, 0), refreshed_layout.findById(120).?.widget.value);
    try std.testing.expectEqual(@as(f32, 28), refreshed_layout.findById(130).?.widget.value);
    try std.testing.expectEqual(@as(f32, 28), refreshed_layout.findById(150).?.widget.value);
}

test "gpu components pointer opens and selects environment dropdown options" {
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

    resetComponentDirty(&harness.runtime);
    const select_point = try componentWidgetCenter(&harness.runtime, environment_select_id);
    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .x = select_point.x,
        .y = select_point.y,
        .button = 0,
    } });
    try std.testing.expectEqual(@as(u32, 0), app.refresh_count);
    try std.testing.expect(app.environment_select_open);
    var snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(componentSnapshotWidget(snapshot, environment_menu_id) != null);
    try expectComponentStatusContains(&harness.runtime, "Environment menu opened.");
    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_up,
        .x = select_point.x,
        .y = select_point.y,
        .button = 0,
    } });
    try std.testing.expect(app.environment_select_open);

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerClick(&harness.runtime, app_handle, environmentOptionId(1));
    try std.testing.expectEqual(@as(usize, 1), app.environment_index);
    try std.testing.expect(!app.environment_select_open);
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(componentSnapshotWidget(snapshot, environment_menu_id) == null);
    const display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentTextCommand(display_list, environment_select_text_id, "Preview");
    try expectComponentStatusContains(&harness.runtime, "Environment selected: Preview.");
}

test "gpu components keyboard navigates and dismisses environment dropdown" {
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

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app_handle, "widget-action components-canvas 172 focus");
    try harness.runtime.dispatchAutomationCommand(app_handle, "widget-action components-canvas 172 press");
    var snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(app.environment_select_open);
    try std.testing.expect(componentSnapshotWidget(snapshot, environment_select_id).?.focused);
    try std.testing.expectEqual(@as(?bool, true), componentSnapshotWidget(snapshot, environment_select_id).?.expanded);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app_handle, "widget-key components-canvas arrowdown");
    snapshot = harness.runtime.automationSnapshot("Components");
    var layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expect(app.environment_select_open);
    try std.testing.expectEqual(@as(usize, 1), app.environment_index);
    try std.testing.expect(layout.findById(environmentOptionId(1)).?.widget.state.selected);
    try std.testing.expect(componentSnapshotWidget(snapshot, environment_select_id).?.focused);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app_handle, "widget-key components-canvas arrowup");
    snapshot = harness.runtime.automationSnapshot("Components");
    layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expect(app.environment_select_open);
    try std.testing.expectEqual(@as(usize, 0), app.environment_index);
    try std.testing.expect(layout.findById(environmentOptionId(0)).?.widget.state.selected);
    try std.testing.expect(componentSnapshotWidget(snapshot, environment_select_id).?.focused);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app_handle, "widget-key components-canvas escape");
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(!app.environment_select_open);
    try std.testing.expect(componentSnapshotWidget(snapshot, environment_menu_id) == null);
    try std.testing.expectEqual(@as(?bool, false), componentSnapshotWidget(snapshot, environment_select_id).?.expanded);
    try std.testing.expect(componentSnapshotWidget(snapshot, environment_select_id).?.focused);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app_handle, "widget-key components-canvas arrowdown");
    snapshot = harness.runtime.automationSnapshot("Components");
    layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expect(app.environment_select_open);
    try std.testing.expectEqual(@as(usize, 1), app.environment_index);
    try std.testing.expect(layout.findById(environmentOptionId(1)).?.widget.state.selected);

    resetComponentDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app_handle, "widget-key components-canvas tab");
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(!app.environment_select_open);
    try std.testing.expect(componentSnapshotWidget(snapshot, environment_menu_id) == null);
    const select = componentSnapshotWidget(snapshot, environment_select_id).?;
    try std.testing.expectEqual(@as(?bool, false), select.expanded);
    try std.testing.expect(!select.focused);
}

test "gpu components surface launchers open and close overlays" {
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

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerClick(&harness.runtime, app_handle, 175);
    try std.testing.expectEqual(ComponentSurfaceOverlay.dialog, app.surface_overlay);
    var layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try expectComponentWidgetFrame(layout, surface_overlay_backdrop_id, rect(0, canvas_content_y, canvas_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, surface_overlay_id, surfaceOverlayFrame(default_canvas_size, .dialog));
    try std.testing.expectEqualStrings("Confirm deployment", layout.findById(surface_overlay_title_id).?.widget.text);
    var snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expectEqualStrings("dialog", componentSnapshotWidget(snapshot, surface_overlay_id).?.role);
    try std.testing.expect(componentSnapshotWidget(snapshot, surface_overlay_backdrop_id).?.actions.dismiss);
    try std.testing.expect(componentSnapshotWidget(snapshot, surface_overlay_close_id).?.actions.press);
    try expectComponentStatusContains(&harness.runtime, "Confirm deployment surface opened.");
    var animations = try harness.runtime.canvasRenderAnimations(1, canvas_label);
    try std.testing.expectEqual(@as(usize, 8), animations.len);
    try expectNoSurfaceAnimation(animations, componentCommandPartId(surface_overlay_backdrop_id, 2));
    try expectSurfaceOpacityAnimation(animations, componentCommandPartId(surface_overlay_id, 2));
    try expectSurfaceOpacityAnimation(animations, componentCommandPartId(surface_overlay_title_id, 1));

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerClick(&harness.runtime, app_handle, surface_overlay_close_id);
    try std.testing.expectEqual(ComponentSurfaceOverlay.none, app.surface_overlay);
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(componentSnapshotWidget(snapshot, surface_overlay_id) == null);

    resetComponentDirty(&harness.runtime);
    const drawer_click_timestamp_ns: u64 = 1_420_000_000;
    try dispatchComponentPointerClickAtTimestamp(&harness.runtime, app_handle, 176, drawer_click_timestamp_ns);
    try std.testing.expectEqual(ComponentSurfaceOverlay.drawer, app.surface_overlay);
    layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    const drawer_frame = surfaceOverlayFrame(default_canvas_size, .drawer);
    try expectComponentWidgetFrame(layout, surface_overlay_id, drawer_frame);
    try std.testing.expectEqualStrings("Project settings", layout.findById(surface_overlay_title_id).?.widget.text);
    animations = try harness.runtime.canvasRenderAnimations(1, canvas_label);
    try std.testing.expectEqual(@as(usize, 8), animations.len);
    try expectNoSurfaceAnimation(animations, componentCommandPartId(surface_overlay_backdrop_id, 2));
    try expectSurfaceTransformAnimation(animations, componentCommandPartId(surface_overlay_id, 2), 0, drawer_frame.height);
    try expectSurfaceAnimationStart(animations, componentCommandPartId(surface_overlay_id, 2), drawer_click_timestamp_ns);
    try expectSurfaceOpacityAnimation(animations, componentCommandPartId(surface_overlay_title_id, 1));

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerClickAtTimestamp(&harness.runtime, app_handle, surface_overlay_backdrop_id, 1_440_000_000);
    try std.testing.expectEqual(ComponentSurfaceOverlay.none, app.surface_overlay);
    snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(componentSnapshotWidget(snapshot, surface_overlay_id) == null);

    resetComponentDirty(&harness.runtime);
    const sheet_click_timestamp_ns: u64 = 1_460_000_000;
    try dispatchComponentPointerClickAtTimestamp(&harness.runtime, app_handle, 177, sheet_click_timestamp_ns);
    try std.testing.expectEqual(ComponentSurfaceOverlay.sheet, app.surface_overlay);
    layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    const sheet_frame = surfaceOverlayFrame(default_canvas_size, .sheet);
    try expectComponentWidgetFrame(layout, surface_overlay_id, sheet_frame);
    try std.testing.expectEqualStrings("Command palette", layout.findById(surface_overlay_title_id).?.widget.text);
    animations = try harness.runtime.canvasRenderAnimations(1, canvas_label);
    try std.testing.expectEqual(@as(usize, 8), animations.len);
    try expectNoSurfaceAnimation(animations, componentCommandPartId(surface_overlay_backdrop_id, 2));
    try expectSurfaceTransformAnimation(animations, componentCommandPartId(surface_overlay_id, 2), sheet_frame.width, 0);
    try expectSurfaceAnimationStart(animations, componentCommandPartId(surface_overlay_id, 2), sheet_click_timestamp_ns);
    try expectSurfaceOpacityAnimation(animations, componentCommandPartId(surface_overlay_close_id, 4));
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
    try expectComponentStatusContains(&harness.runtime, "Clicked slider #115: value 0.82");

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

test "gpu components sidebar handle drag resizes retained layout" {
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

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_move,
        .x = canvas_sidebar_width,
        .y = canvas_content_y + 20,
    } });
    try std.testing.expectEqual(zero_native.platform.Cursor.resize_horizontal, harness.null_platform.view_cursor);

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerDragByDelta(&harness.runtime, app_handle, canvas_sidebar_resize_handle_id, 60);
    const widened_sidebar_width = canvas_sidebar_width + 60;
    try std.testing.expectApproxEqAbs(widened_sidebar_width, app.sidebar_width, 0.001);
    var layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try expectComponentWidgetFrame(layout, canvas_sidebar_id, rect(0, canvas_content_y, widened_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, content_scroll_id, rect(widened_sidebar_width, canvas_content_y, canvas_width - widened_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, canvas_sidebar_resize_line_id, sidebarResizeLineFrame(widened_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, canvas_sidebar_resize_handle_id, sidebarResizeHandleFrame(widened_sidebar_width, canvas_content_height));
    var display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try std.testing.expect(display_list.findCommandById(3) == null);
    try std.testing.expect(harness.runtime.invalidated);

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerDragByDelta(&harness.runtime, app_handle, canvas_sidebar_resize_handle_id, -120);
    try std.testing.expectApproxEqAbs(canvas_sidebar_min_width, app.sidebar_width, 0.001);
    layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try expectComponentWidgetFrame(layout, canvas_sidebar_id, rect(0, canvas_content_y, canvas_sidebar_min_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, content_scroll_id, rect(canvas_sidebar_min_width, canvas_content_y, canvas_width - canvas_sidebar_min_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, canvas_sidebar_resize_line_id, sidebarResizeLineFrame(canvas_sidebar_min_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, canvas_sidebar_resize_handle_id, sidebarResizeHandleFrame(canvas_sidebar_min_width, canvas_content_height));
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try std.testing.expect(display_list.findCommandById(3) == null);

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerClick(&harness.runtime, app_handle, 175);
    layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    const dialog_frame = surfaceOverlayFrame(default_canvas_size, .dialog);
    try expectComponentWidgetFrame(layout, surface_overlay_id, dialog_frame);
    try std.testing.expectApproxEqAbs(canvas_width * 0.5, dialog_frame.center().x, 0.001);

    try dispatchComponentPointerClick(&harness.runtime, app_handle, surface_overlay_close_id);
    try dispatchComponentPointerClick(&harness.runtime, app_handle, 176);
    layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    const drawer_frame = surfaceOverlayFrame(default_canvas_size, .drawer);
    try expectComponentWidgetFrame(layout, surface_overlay_id, drawer_frame);
    try std.testing.expectEqual(@as(f32, 0), drawer_frame.x);
    try std.testing.expectEqual(canvas_width, drawer_frame.width);
}
