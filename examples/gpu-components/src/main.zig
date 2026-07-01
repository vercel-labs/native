const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const canvas = zero_native.canvas;
const geometry = zero_native.geometry;

const window_width: f32 = 1180;
const window_height: f32 = 760;
const toolbar_height: f32 = 52;
const canvas_sidebar_width: f32 = 208;
const canvas_sidebar_min_width: f32 = 168;
const canvas_sidebar_max_width: f32 = 360;
const canvas_sidebar_min_content_width: f32 = 420;
const canvas_sidebar_resize_handle_width: f32 = 14;
const canvas_sidebar_resize_line_width: f32 = 1;
const statusbar_height: f32 = 32;
const canvas_width: f32 = window_width;
const canvas_height: f32 = window_height - toolbar_height;
const canvas_content_height: f32 = canvas_height - statusbar_height;
const default_canvas_size = geometry.SizeF.init(canvas_width, canvas_height);
const max_component_pipelines: usize = 8;
const max_component_commands: usize = zero_native.runtime.max_canvas_commands_per_view;
const max_component_glyphs: usize = zero_native.runtime.max_canvas_glyphs_per_view;
const max_component_widgets: usize = zero_native.runtime.max_canvas_widget_nodes_per_view;
const component_chrome_prefix_commands: usize = 2;
const component_chrome_suffix_commands: usize = 0;
const catalog_grid_columns: usize = 3;
const catalog_card_width: f32 = 238;
const catalog_card_height: f32 = 52;
const catalog_card_gap_x: f32 = 22;
const catalog_card_gap_y: f32 = 18;
const refresh_command = "components.refresh";
const theme_command = "components.theme";
const environment_toggle_command = "components.environment.toggle";
const surface_dialog_command = "components.surface.dialog";
const surface_drawer_command = "components.surface.drawer";
const surface_sheet_command = "components.surface.sheet";
const surface_close_command = "components.surface.close";
const environment_option_commands = [_][]const u8{
    "components.environment.production",
    "components.environment.preview",
    "components.environment.staging",
};
const canvas_label = "components-canvas";
const primary_button_fill_id: canvas.ObjectId = 104 * 16 + 1;
const project_static_text_id: canvas.ObjectId = 111 * 16 + 3;
const project_text_id: canvas.ObjectId = 111 * 16 + 4;
const project_selection_id: canvas.ObjectId = 111 * 16 + 3;
const project_composition_id: canvas.ObjectId = 111 * 16 + 5;
const search_text_id: canvas.ObjectId = 112 * 16 + 9;
const search_selection_id: canvas.ObjectId = 112 * 16 + 8;
const search_composition_id: canvas.ObjectId = 112 * 16 + 10;
const message_text_id: canvas.ObjectId = 171 * 16 + 4;
const scroll_track_id: canvas.ObjectId = 130 * 16 + 2;
const scroll_thumb_id: canvas.ObjectId = 130 * 16 + 3;
const menu_item_text_id: canvas.ObjectId = 142 * 16 + 3;
const data_cell_text_id: canvas.ObjectId = 156 * 16 + 4;
const environment_select_id: canvas.ObjectId = 172;
const environment_select_text_id: canvas.ObjectId = environment_select_id * 16 + 3;
const environment_menu_id: canvas.ObjectId = 216;
const environment_option_base_id: canvas.ObjectId = 21601;
const content_scroll_id: canvas.ObjectId = 90;
const content_stack_id: canvas.ObjectId = 91;
const canvas_sidebar_id: canvas.ObjectId = 92;
const canvas_sidebar_title_id: canvas.ObjectId = 93;
const section_nav_base_id: canvas.ObjectId = 94;
const canvas_sidebar_resize_line_id: canvas.ObjectId = 88;
const canvas_sidebar_resize_handle_id: canvas.ObjectId = 99;
const canvas_status_text_id: canvas.ObjectId = 261;
const canvas_status_separator_id: canvas.ObjectId = 262;
const surface_overlay_backdrop_id: canvas.ObjectId = 222;
const surface_overlay_id: canvas.ObjectId = 223;
const surface_overlay_title_id: canvas.ObjectId = 224;
const surface_overlay_body_id: canvas.ObjectId = 225;
const surface_overlay_close_id: canvas.ObjectId = 226;
const surface_backdrop_layer: i32 = 300;
const surface_overlay_layer: i32 = 301;
const max_surface_overlay_animations: usize = 12;
const popover_blur_id: canvas.ObjectId = 140 * 16 + 12;
const preview_image_id: canvas.ImageId = 42;
const preview_image_command_id: canvas.ObjectId = 118 * 16 + 1;
const environment_options = [_][]const u8{ "Production", "Preview", "Staging" };
const initial_component_status_text = "Component lab waiting for the first GPU frame.";
const max_component_status_text: usize = 192;
const section_nav_commands = [_][]const u8{
    "components.section.controls",
    "components.section.inputs",
    "components.section.data",
    "components.section.components",
    "components.section.surfaces",
};

const ComponentVirtualScroll = struct {
    page: f32 = 0,
    page_velocity: f32 = 0,
    nav: f32 = 0,
    nav_velocity: f32 = 0,
    behavior: f32 = 28,
    behavior_velocity: f32 = 0,
    data: f32 = 28,
    data_velocity: f32 = 0,
};

const ComponentUiState = struct {
    environment_select_open: bool = false,
    environment_index: usize = 0,
    surface_overlay: ComponentSurfaceOverlay = .none,
    section: ComponentSection = .controls,
    sidebar_width: f32 = canvas_sidebar_width,
    status_text: []const u8 = initial_component_status_text,
};

const ComponentSurfaceOverlay = enum {
    none,
    dialog,
    drawer,
    sheet,
};

const ComponentSection = enum(u8) {
    controls,
    inputs,
    data,
    components,
    surfaces,
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

fn environmentLabel(index: usize) []const u8 {
    return environment_options[@min(index, environment_options.len - 1)];
}

fn environmentOptionId(index: usize) canvas.ObjectId {
    return environment_option_base_id + @as(canvas.ObjectId, @intCast(index));
}

fn environmentOptionIndex(id: canvas.ObjectId) ?usize {
    if (id < environment_option_base_id) return null;
    const index = id - environment_option_base_id;
    if (index >= environment_options.len) return null;
    return @intCast(index);
}

fn environmentNextIndex(index: usize) usize {
    return (@min(index, environment_options.len - 1) + 1) % environment_options.len;
}

fn environmentPreviousIndex(index: usize) usize {
    const current = @min(index, environment_options.len - 1);
    return if (current == 0) environment_options.len - 1 else current - 1;
}

fn environmentCommandIndex(command_name: []const u8) ?usize {
    for (environment_option_commands, 0..) |option_command, index| {
        if (std.mem.eql(u8, command_name, option_command)) return index;
    }
    return null;
}

fn componentSectionLabel(section: ComponentSection) []const u8 {
    return switch (section) {
        .controls => "Controls",
        .inputs => "Inputs",
        .data => "Data",
        .components => "Components",
        .surfaces => "Surfaces",
    };
}

fn componentSectionCommand(section: ComponentSection) []const u8 {
    return section_nav_commands[@intFromEnum(section)];
}

fn componentSectionFromCommand(command_name: []const u8) ?ComponentSection {
    for (section_nav_commands, 0..) |section_command, index| {
        if (std.mem.eql(u8, command_name, section_command)) return @enumFromInt(index);
    }
    return null;
}

fn componentSectionNavId(section: ComponentSection) canvas.ObjectId {
    return section_nav_base_id + @as(canvas.ObjectId, @intFromEnum(section));
}

fn surfaceOverlayLabel(overlay: ComponentSurfaceOverlay) []const u8 {
    return switch (overlay) {
        .dialog => "Confirm deployment",
        .drawer => "Project settings",
        .sheet => "Command palette",
        .none => "Surface",
    };
}

fn surfaceOverlayBody(overlay: ComponentSurfaceOverlay) []const u8 {
    return switch (overlay) {
        .dialog => "Production rollout is ready for review.",
        .drawer => "Team notifications are synced.",
        .sheet => "Recent actions are ready.",
        .none => "",
    };
}

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

const catalog_accordion_children = [_]canvas.Widget{
    .{ .id = 18101, .kind = .text, .frame = rect(10, 5, 96, 18), .text = "Accordion", .size = .sm },
};
const catalog_breadcrumb_children = [_]canvas.Widget{
    .{ .id = 18501, .kind = .text, .text = "Home", .size = .sm },
    .{ .id = 18502, .kind = .text, .text = "Components", .size = .sm },
};
const catalog_bubble_children = [_]canvas.Widget{
    .{ .id = 18601, .kind = .text, .frame = rect(10, 5, 76, 18), .text = "Bubble", .size = .sm },
};
const catalog_button_group_children = [_]canvas.Widget{
    .{ .id = 18801, .kind = .button, .text = "One", .size = .sm, .layout = .{ .grow = 1 } },
    .{ .id = 18802, .kind = .button, .text = "Two", .size = .sm, .variant = .secondary, .layout = .{ .grow = 1 } },
};
const catalog_dropdown_children = [_]canvas.Widget{
    .{ .id = 19401, .kind = .menu_item, .text = "Copy" },
};
const catalog_pagination_children = [_]canvas.Widget{
    .{ .id = 19601, .kind = .button, .text = "1", .size = .sm, .state = .{ .selected = true } },
    .{ .id = 19602, .kind = .button, .text = "2", .size = .sm, .variant = .outline },
    .{ .id = 19603, .kind = .button, .text = "Next", .size = .sm, .variant = .ghost },
};
const catalog_radio_group_children = [_]canvas.Widget{
    .{ .id = 19801, .kind = .radio, .text = "A", .state = .{ .selected = true } },
    .{ .id = 19802, .kind = .radio, .text = "B" },
};
const catalog_resizable_children = [_]canvas.Widget{
    .{ .id = 19901, .kind = .text, .frame = rect(10, 5, 86, 18), .text = "Resizable", .size = .sm },
};
const catalog_table_row_cells = [_]canvas.Widget{
    .{ .id = 20702, .kind = .data_cell, .text = "Name", .layout = .{ .grow = 1 } },
    .{ .id = 20703, .kind = .data_cell, .text = "Status", .layout = .{ .grow = 1 } },
};
const catalog_table_rows = [_]canvas.Widget{
    .{ .id = 20701, .kind = .data_row, .children = &catalog_table_row_cells },
};
const catalog_tabs_children = [_]canvas.Widget{
    .{ .id = 20801, .kind = .segmented_control, .text = "One", .size = .sm, .state = .{ .selected = true } },
    .{ .id = 20802, .kind = .segmented_control, .text = "Two", .size = .sm },
};
const catalog_toggle_group_children = [_]canvas.Widget{
    .{ .id = 21101, .kind = .toggle_button, .text = "B", .size = .sm, .state = .{ .selected = true } },
    .{ .id = 21102, .kind = .toggle_button, .text = "I", .size = .sm },
};

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
    .{ .label = canvas_label, .kind = .gpu_surface, .parent = "body", .fill = true, .min_width = 640, .layer = 12, .role = "Native-rendered component canvas", .accessibility_label = "Native-rendered component gallery canvas", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
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
        const offset = surfaceOverlayEnterOffsetForSidebar(self.canvas_size, overlay, self.sidebar_width) orelse return;
        const motion = self.componentTokens().motion;
        if (motion.durationMs(.normal) == 0) return;

        const start_ns = runtime.canvasRenderAnimationStartNs(window_id, canvas_label) catch |err| switch (err) {
            error.WindowNotFound, error.ViewNotFound, error.InvalidViewOptions => return,
            else => return err,
        };
        var animations: [max_surface_overlay_animations]canvas.CanvasRenderAnimation = undefined;
        var count: usize = 0;
        try appendSurfaceChromeSlideAnimations(&animations, &count, motion, start_ns, canvas.Affine.translate(offset.dx, offset.dy));
        try appendSurfaceContentFadeAnimations(&animations, &count, motion, start_ns);
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

fn installComponentsCanvasModel(runtime: *zero_native.Runtime, window_id: zero_native.WindowId, virtual_scroll: ComponentVirtualScroll, ui_state: ComponentUiState, tokens: canvas.DesignTokens, surface_size: geometry.SizeF) anyerror!void {
    var commands: [max_component_commands]canvas.CanvasCommand = undefined;
    var nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    var builder = canvas.Builder.init(&commands);
    const layout = try buildComponentsWidgetLayoutWithStateAndSize(&nodes, virtual_scroll, ui_state, surface_size);
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

fn componentStatusbarHeightForSize(surface_size: geometry.SizeF) f32 {
    const size = componentSurfaceSize(surface_size);
    return @min(statusbar_height, @max(0, size.height - 1));
}

fn componentContentHeightForSize(surface_size: geometry.SizeF) f32 {
    const size = componentSurfaceSize(surface_size);
    return @max(1, size.height - componentStatusbarHeightForSize(size));
}

fn componentOverlaySize(surface_size: geometry.SizeF) geometry.SizeF {
    const size = componentSurfaceSize(surface_size);
    return geometry.SizeF.init(size.width, componentContentHeightForSize(size));
}

fn componentSidebarWidthForSize(requested_width: f32, surface_size: geometry.SizeF) f32 {
    const size = componentSurfaceSize(surface_size);
    const requested = if (std.math.isFinite(requested_width) and requested_width > 0) requested_width else canvas_sidebar_width;
    const max_for_surface = @min(canvas_sidebar_max_width, @max(canvas_sidebar_min_width, size.width - canvas_sidebar_min_content_width));
    return std.math.clamp(requested, canvas_sidebar_min_width, max_for_surface);
}

fn componentVirtualScrollTarget(route: []const canvas.WidgetEventRouteEntry) ?canvas.ObjectId {
    var page_scroll: ?canvas.ObjectId = null;
    for (route) |entry| {
        switch (entry.id) {
            120, 130, 150 => return entry.id,
            content_scroll_id => page_scroll = content_scroll_id,
            else => {},
        }
    }
    return page_scroll;
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

fn componentScrollStatesEqual(a: canvas.ScrollState, b: canvas.ScrollState) bool {
    return a.offset == b.offset and
        a.velocity == b.velocity and
        a.viewport_extent == b.viewport_extent and
        a.content_extent == b.content_extent;
}

fn componentFrameIntervalMs(frame_interval_ns: u64) f32 {
    if (frame_interval_ns == 0) return 16;
    const raw = @as(f32, @floatFromInt(frame_interval_ns)) / 1_000_000.0;
    return std.math.clamp(raw, 1, 64);
}

fn componentVirtualScrollStep(widget: canvas.Widget) ?f32 {
    if (!widget.layout.virtualized) return null;
    const item_extent = if (widget.layout.virtual_item_extent > 0) widget.layout.virtual_item_extent else return null;
    const step = item_extent + @max(0, widget.layout.gap);
    return if (step > 0) step else null;
}

fn componentSurfaceCardRect(surface_size: geometry.SizeF) geometry.RectF {
    return componentSurfaceCardRectForSidebar(surface_size, canvas_sidebar_width);
}

fn componentSurfaceCardRectForSidebar(surface_size: geometry.SizeF, sidebar_width: f32) geometry.RectF {
    const size = componentSurfaceSize(surface_size);
    const resolved_sidebar_width = componentSidebarWidthForSize(sidebar_width, size);
    const content_width = @max(1, size.width - resolved_sidebar_width);
    return rect(resolved_sidebar_width + 28, 26, @max(916, content_width - 56), @max(616, componentContentHeightForSize(size) - 60));
}

fn componentSidebarWidthFromLayout(layout: canvas.WidgetLayoutTree) f32 {
    if (layout.findById(canvas_sidebar_id)) |node| return node.frame.width;
    return canvas_sidebar_width;
}

fn componentSizesEqual(a: geometry.SizeF, b: geometry.SizeF) bool {
    return a.width == b.width and a.height == b.height;
}

fn buildComponentsDisplayList(builder: *canvas.Builder, layout: canvas.WidgetLayoutTree, tokens: canvas.DesignTokens) canvas.Error!void {
    return buildComponentsDisplayListForSize(builder, layout, tokens, default_canvas_size);
}

fn buildComponentsDisplayListForSize(builder: *canvas.Builder, layout: canvas.WidgetLayoutTree, tokens: canvas.DesignTokens, surface_size: geometry.SizeF) canvas.Error!void {
    const size = componentSurfaceSize(surface_size);
    const content_height = componentContentHeightForSize(size);
    try builder.fillRect(.{ .id = canvas_status_separator_id, .rect = rect(0, content_height, size.width, 1), .fill = .{ .color = tokens.colors.border } });
    try builder.fillRoundedRect(.{ .id = 3, .rect = componentSurfaceCardRectForSidebar(surface_size, componentSidebarWidthFromLayout(layout)), .radius = canvas.Radius.all(tokens.radius.xl), .fill = .{ .color = tokens.colors.surface } });
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

fn buildComponentsWidgetLayoutWithScrollAndSize(nodes: []canvas.WidgetLayoutNode, virtual_scroll: ComponentVirtualScroll, surface_size: geometry.SizeF) canvas.Error!canvas.WidgetLayoutTree {
    return buildComponentsWidgetLayoutWithStateAndSize(nodes, virtual_scroll, .{}, surface_size);
}

fn componentCatalogItems() [canvas.builtin_component_names.len]canvas.Widget {
    var items: [canvas.builtin_component_names.len]canvas.Widget = undefined;
    for (&items, 0..) |*item, index| {
        item.* = componentCatalogItem(canvas.builtin_component_kinds[index], index);
    }
    return items;
}

fn componentCatalogItem(kind: canvas.BuiltinComponentKind, index: usize) canvas.Widget {
    const column = index % catalog_grid_columns;
    const row = index / catalog_grid_columns;
    return .{
        .id = @as(canvas.ObjectId, @intCast(181 + index)),
        .kind = .card,
        .frame = rect(
            64 + @as(f32, @floatFromInt(column)) * (catalog_card_width + catalog_card_gap_x),
            124 + @as(f32, @floatFromInt(row)) * (catalog_card_height + catalog_card_gap_y),
            catalog_card_width,
            catalog_card_height,
        ),
        .text = canvas.builtinComponentName(kind),
        .state = .{ .selected = index == 0 },
        .semantics = .{ .label = canvas.builtinComponentName(kind) },
    };
}

fn componentCatalogPreviewLayout(kind: canvas.BuiltinComponentKind) canvas.WidgetLayoutStyle {
    return switch (kind) {
        .textarea => .{ .min_size = geometry.SizeF.init(0, 28) },
        else => .{},
    };
}

fn componentCatalogPreviewChildren(kind: canvas.BuiltinComponentKind) []const canvas.Widget {
    return switch (kind) {
        .accordion => &catalog_accordion_children,
        .breadcrumb => &catalog_breadcrumb_children,
        .bubble => &catalog_bubble_children,
        .button_group => &catalog_button_group_children,
        .dropdown_menu => &catalog_dropdown_children,
        .pagination => &catalog_pagination_children,
        .radio_group => &catalog_radio_group_children,
        .resizable => &catalog_resizable_children,
        .table => &catalog_table_rows,
        .tabs => &catalog_tabs_children,
        .toggle_group => &catalog_toggle_group_children,
        else => &.{},
    };
}

fn componentCatalogGridHeight() f32 {
    const rows = (canvas.builtin_component_names.len + catalog_grid_columns - 1) / catalog_grid_columns;
    return 124 + @as(f32, @floatFromInt(rows)) * catalog_card_height + @as(f32, @floatFromInt(rows - 1)) * catalog_card_gap_y + 64;
}

fn componentSectionContentHeight(section: ComponentSection) f32 {
    return switch (section) {
        .controls => 700,
        .inputs => 560,
        .data => 360,
        .components => componentCatalogGridHeight(),
        .surfaces => 520,
    };
}

fn surfaceOverlayKind(overlay: ComponentSurfaceOverlay) canvas.BuiltinComponentKind {
    return switch (overlay) {
        .dialog => .dialog,
        .drawer => .drawer,
        .sheet => .sheet,
        .none => unreachable,
    };
}

fn surfaceOverlayFrame(surface_size: geometry.SizeF, overlay: ComponentSurfaceOverlay) geometry.RectF {
    return surfaceOverlayFrameForSidebar(surface_size, overlay, canvas_sidebar_width);
}

fn surfaceOverlayFrameForSidebar(surface_size: geometry.SizeF, overlay: ComponentSurfaceOverlay, sidebar_width: f32) geometry.RectF {
    _ = sidebar_width;
    const size = componentOverlaySize(surface_size);
    return switch (overlay) {
        .dialog => centeredWindowOverlayFrame(size, 460, 220),
        .drawer => bottomDrawerOverlayFrame(size, 260),
        .sheet => rightSheetOverlayFrame(size, 380),
        .none => unreachable,
    };
}

fn surfaceOverlayEnterOffset(surface_size: geometry.SizeF, overlay: ComponentSurfaceOverlay) ?geometry.OffsetF {
    return surfaceOverlayEnterOffsetForSidebar(surface_size, overlay, canvas_sidebar_width);
}

fn surfaceOverlayEnterOffsetForSidebar(surface_size: geometry.SizeF, overlay: ComponentSurfaceOverlay, sidebar_width: f32) ?geometry.OffsetF {
    const frame = surfaceOverlayFrameForSidebar(surface_size, overlay, sidebar_width);
    return switch (overlay) {
        .drawer => geometry.OffsetF.init(0, frame.height),
        .sheet => geometry.OffsetF.init(frame.width, 0),
        .dialog, .none => null,
    };
}

fn centeredWindowOverlayFrame(size: geometry.SizeF, preferred_width: f32, preferred_height: f32) geometry.RectF {
    const width = @min(preferred_width, @max(1, size.width - 48));
    const height = @min(preferred_height, @max(1, size.height - 48));
    return rect(
        @max(24, (size.width - width) * 0.5),
        @max(24, (size.height - height) * 0.5),
        width,
        height,
    );
}

fn bottomDrawerOverlayFrame(size: geometry.SizeF, preferred_height: f32) geometry.RectF {
    const height = @min(preferred_height, @max(1, size.height));
    return rect(0, @max(0, size.height - height), @max(1, size.width), height);
}

fn rightSheetOverlayFrame(size: geometry.SizeF, preferred_width: f32) geometry.RectF {
    const width = @min(preferred_width, @max(1, size.width));
    return rect(@max(0, size.width - width), 0, width, @max(1, size.height));
}

fn appendSurfaceChromeSlideAnimations(output: []canvas.CanvasRenderAnimation, count: *usize, motion: canvas.MotionTokens, start_ns: u64, from_transform: canvas.Affine) canvas.Error!void {
    try appendSurfaceTransformAnimation(output, count, motion, start_ns, componentCommandPartId(surface_overlay_id, 1), from_transform);
    try appendSurfaceTransformAnimation(output, count, motion, start_ns, componentCommandPartId(surface_overlay_id, 2), from_transform);
    try appendSurfaceTransformAnimation(output, count, motion, start_ns, componentCommandPartId(surface_overlay_id, 3), from_transform);
}

fn appendSurfaceContentFadeAnimations(output: []canvas.CanvasRenderAnimation, count: *usize, motion: canvas.MotionTokens, start_ns: u64) canvas.Error!void {
    try appendSurfaceOpacityAnimation(output, count, motion, start_ns, componentCommandPartId(surface_overlay_title_id, 1));
    try appendSurfaceOpacityAnimation(output, count, motion, start_ns, componentCommandPartId(surface_overlay_body_id, 1));
    try appendSurfaceOpacityAnimation(output, count, motion, start_ns, componentCommandPartId(surface_overlay_close_id, 1));
    try appendSurfaceOpacityAnimation(output, count, motion, start_ns, componentCommandPartId(surface_overlay_close_id, 2));
    try appendSurfaceOpacityAnimation(output, count, motion, start_ns, componentCommandPartId(surface_overlay_close_id, 4));
}

fn appendSurfaceOpacityAnimation(output: []canvas.CanvasRenderAnimation, count: *usize, motion: canvas.MotionTokens, start_ns: u64, id: canvas.ObjectId) canvas.Error!void {
    try appendSurfaceAnimation(output, count, motion.animation(.{
        .id = id,
        .start_ns = start_ns,
        .duration = .normal,
        .from_opacity = 0,
        .to_opacity = 1,
    }));
}

fn appendSurfaceTransformAnimation(output: []canvas.CanvasRenderAnimation, count: *usize, motion: canvas.MotionTokens, start_ns: u64, id: canvas.ObjectId, from_transform: canvas.Affine) canvas.Error!void {
    try appendSurfaceAnimation(output, count, motion.animation(.{
        .id = id,
        .start_ns = start_ns,
        .duration = .normal,
        .from_transform = from_transform,
        .to_transform = canvas.Affine.identity(),
    }));
}

fn appendSurfaceAnimation(output: []canvas.CanvasRenderAnimation, count: *usize, animation: canvas.CanvasRenderAnimation) canvas.Error!void {
    if (count.* >= output.len) return error.RenderOverrideListFull;
    output[count.*] = animation;
    count.* += 1;
}

fn appendComponentWidget(output: []canvas.Widget, count: *usize, widget: canvas.Widget) canvas.Error!void {
    if (count.* >= output.len) return error.WidgetLayoutListFull;
    output[count.*] = widget;
    count.* += 1;
}

fn buildComponentsWidgetLayoutWithStateAndSize(nodes: []canvas.WidgetLayoutNode, virtual_scroll: ComponentVirtualScroll, ui_state: ComponentUiState, surface_size: geometry.SizeF) canvas.Error!canvas.WidgetLayoutTree {
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
        .{ .id = 111, .kind = .input, .frame = rect(0, 0, 148, 34), .text = "zero-native", .semantics = .{ .label = "Project name" } },
        .{ .id = 112, .kind = .combobox, .frame = rect(166, 0, 172, 34), .text = "components", .semantics = .{ .label = "Component combobox" } },
        .{ .id = 113, .kind = .checkbox, .frame = rect(0, 52, 132, 30), .text = "Selected", .state = .{ .selected = true }, .semantics = .{ .label = "Selected checkbox" } },
        .{ .id = 114, .kind = .switch_control, .frame = rect(166, 52, 116, 30), .text = "Live", .value = 1, .state = .{ .selected = true }, .semantics = .{ .label = "Live switch" } },
        .{ .id = 215, .kind = .toggle_button, .frame = rect(292, 52, 60, 30), .text = "Bold", .state = .{ .selected = true }, .semantics = .{ .label = "Bold toggle" } },
        .{ .id = 115, .kind = .slider, .frame = rect(0, 108, 176, 28), .value = 0.62, .semantics = .{ .label = "Density slider" } },
        .{ .id = 116, .kind = .progress, .frame = rect(202, 118, 134, 8), .value = 1, .semantics = .{ .label = "Build progress" } },
        .{ .id = 167, .kind = .radio_group, .frame = rect(0, 148, 160, 28), .layout = .{ .gap = 10, .cross_alignment = .center }, .semantics = .{ .label = "Layout radio group" }, .children = &radio_controls },
        .{ .id = 168, .kind = .tabs, .frame = rect(0, 200, 148, 34), .layout = .{ .gap = 4 }, .semantics = .{ .label = "Density tabs" }, .children = &segment_controls },
        .{ .id = 118, .kind = .image, .frame = rect(190, 160, 124, 54), .image_id = preview_image_id, .image_src = rect(0, 0, 4, 4), .image_fit = .cover, .image_sampling = .nearest, .image_opacity = 0.94, .semantics = .{ .label = "GPU image preview" } },
        .{ .id = 171, .kind = .textarea, .frame = rect(0, 246, 336, 72), .text = "Compose a native-rendered message", .semantics = .{ .label = "Message textarea" } },
        .{ .id = environment_select_id, .kind = .select, .frame = rect(0, 330, 180, 34), .text = environmentLabel(ui_state.environment_index), .command = environment_toggle_command, .state = .{ .expanded = ui_state.environment_select_open }, .semantics = .{ .label = "Environment select" } },
    };
    const card_preview_children = [_]canvas.Widget{
        .{ .id = 231, .kind = .badge, .frame = rect(176, 0, 66, 24), .text = "Active", .variant = .secondary, .semantics = .{ .label = "Plan status active" } },
        .{ .id = 232, .kind = .text, .frame = rect(0, 40, 220, 28), .text = "$29 / month", .size = .lg },
        .{ .id = 233, .kind = .text, .frame = rect(0, 72, 220, 20), .text = "8 of 12 seats used", .size = .sm },
        .{ .id = 234, .kind = .progress, .frame = rect(0, 102, 244, 8), .value = 0.67, .semantics = .{ .label = "Seat usage" } },
    };
    const menu_items = [_]canvas.Widget{
        .{ .id = 142, .kind = .menu_item, .text = "Copy invite link" },
        .{ .id = 143, .kind = .menu_item, .text = "Rotate API key" },
        .{ .id = 144, .kind = .menu_item, .text = "Open audit log" },
    };
    const popover_children = [_]canvas.Widget{
        canvas.builtinComponentWidget(.dropdown_menu, .{
            .id = 141,
            .frame = rect(12, 12, 236, 100),
            .semantics = .{ .label = "Project actions menu" },
            .children = &menu_items,
        }),
    };
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
        .{ .id = 150, .kind = .table, .frame = rect(0, 0, 360, 28), .text = "Finished component behavior", .value = virtual_scroll.data, .layout = .{ .virtualized = true, .virtual_item_extent = 28, .virtual_overscan = 0 }, .children = &data_rows },
        .{ .id = 160, .kind = .tooltip, .frame = rect(392, 0, 176, 32), .text = "Tooltip rendered on GPU", .semantics = .{ .label = "GPU tooltip" } },
    };
    const environment_menu_items = [_]canvas.Widget{
        .{ .id = environmentOptionId(0), .kind = .menu_item, .text = environment_options[0], .command = environment_option_commands[0], .state = .{ .selected = ui_state.environment_index == 0 }, .semantics = .{ .label = environment_options[0] } },
        .{ .id = environmentOptionId(1), .kind = .menu_item, .text = environment_options[1], .command = environment_option_commands[1], .state = .{ .selected = ui_state.environment_index == 1 }, .semantics = .{ .label = environment_options[1] } },
        .{ .id = environmentOptionId(2), .kind = .menu_item, .text = environment_options[2], .command = environment_option_commands[2], .state = .{ .selected = ui_state.environment_index == 2 }, .semantics = .{ .label = environment_options[2] } },
    };
    const size = componentSurfaceSize(surface_size);
    const content_height_available = componentContentHeightForSize(size);
    const sidebar_width = componentSidebarWidthForSize(ui_state.sidebar_width, size);
    const sidebar_title_width = @max(1, sidebar_width - 44);
    const sidebar_item_width = @max(1, sidebar_width - 28);
    const sidebar_children = [_]canvas.Widget{
        .{ .id = canvas_sidebar_title_id, .kind = .text, .frame = rect(22, 28, sidebar_title_width, 24), .text = "Native-first kit", .size = .lg },
        .{ .id = componentSectionNavId(.controls), .kind = .list_item, .frame = rect(14, 78, sidebar_item_width, 34), .text = componentSectionLabel(.controls), .command = componentSectionCommand(.controls), .state = .{ .selected = ui_state.section == .controls }, .semantics = .{ .label = componentSectionLabel(.controls) } },
        .{ .id = componentSectionNavId(.inputs), .kind = .list_item, .frame = rect(14, 118, sidebar_item_width, 34), .text = componentSectionLabel(.inputs), .command = componentSectionCommand(.inputs), .state = .{ .selected = ui_state.section == .inputs }, .semantics = .{ .label = componentSectionLabel(.inputs) } },
        .{ .id = componentSectionNavId(.data), .kind = .list_item, .frame = rect(14, 158, sidebar_item_width, 34), .text = componentSectionLabel(.data), .command = componentSectionCommand(.data), .state = .{ .selected = ui_state.section == .data }, .semantics = .{ .label = componentSectionLabel(.data) } },
        .{ .id = componentSectionNavId(.components), .kind = .list_item, .frame = rect(14, 198, sidebar_item_width, 34), .text = componentSectionLabel(.components), .command = componentSectionCommand(.components), .state = .{ .selected = ui_state.section == .components }, .semantics = .{ .label = componentSectionLabel(.components) } },
        .{ .id = componentSectionNavId(.surfaces), .kind = .list_item, .frame = rect(14, 238, sidebar_item_width, 34), .text = componentSectionLabel(.surfaces), .command = componentSectionCommand(.surfaces), .state = .{ .selected = ui_state.section == .surfaces }, .semantics = .{ .label = componentSectionLabel(.surfaces) } },
    };
    var content_widgets: [canvas.builtin_component_names.len + 16]canvas.Widget = undefined;
    var content_widget_count: usize = 0;

    switch (ui_state.section) {
        .controls => {
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 101, .kind = .text, .frame = rect(64, 56, 240, 26), .text = "Controls", .size = .lg });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 104, .kind = .button, .frame = rect(724, 54, 118, 34), .text = "Primary", .variant = .primary, .command = refresh_command, .semantics = .{ .label = "Primary action" } });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 105, .kind = .icon_button, .frame = rect(856, 54, 34, 34), .text = "+", .size = .icon, .semantics = .{ .label = "Add component" } });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 106, .kind = .stack, .frame = rect(64, 124, 352, 374), .semantics = .{ .label = "Input controls" }, .children = &form_controls });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 120, .kind = .list, .frame = rect(456, 124, 170, 56), .value = virtual_scroll.nav, .layout = .{ .virtualized = true, .virtual_item_extent = 28, .virtual_overscan = 0 }, .semantics = .{ .label = "Component navigation" }, .children = &nav_items });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 130, .kind = .scroll_view, .frame = rect(652, 124, 186, 56), .value = virtual_scroll.behavior, .layout = .{ .virtualized = true, .virtual_item_extent = 28, .virtual_overscan = 0 }, .semantics = .{ .label = "Scrollable behavior list" }, .children = &scroll_items });
            try appendComponentWidget(&content_widgets, &content_widget_count, canvas.builtinComponentWidget(.card, .{ .id = 174, .frame = rect(456, 384, 276, 156), .text = "Team plan", .semantics = .{ .label = "Team plan card" }, .children = &card_preview_children }));
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 175, .kind = .button, .frame = rect(456, 560, 124, 40), .text = "Dialog", .variant = .outline, .command = surface_dialog_command, .semantics = .{ .label = "Open dialog" } });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 176, .kind = .button, .frame = rect(594, 560, 108, 40), .text = "Drawer", .variant = .outline, .command = surface_drawer_command, .semantics = .{ .label = "Open drawer" } });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 177, .kind = .button, .frame = rect(716, 560, 108, 40), .text = "Sheet", .variant = .outline, .command = surface_sheet_command, .semantics = .{ .label = "Open sheet" } });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 140, .kind = .popover, .frame = rect(456, 216, 260, 126), .backdrop_blur_token = .sm, .semantics = .{ .label = "Project actions popover" }, .children = &popover_children });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 149, .kind = .stack, .frame = rect(64, 628, 568, 60), .semantics = .{ .label = "Data controls" }, .children = &data_panel_children });
        },
        .inputs => {
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 101, .kind = .text, .frame = rect(64, 56, 240, 26), .text = "Inputs", .size = .lg });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 106, .kind = .stack, .frame = rect(64, 124, 352, 374), .semantics = .{ .label = "Input controls" }, .children = &form_controls });
        },
        .data => {
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 101, .kind = .text, .frame = rect(64, 56, 240, 26), .text = "Data", .size = .lg });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 120, .kind = .list, .frame = rect(64, 124, 220, 84), .value = virtual_scroll.nav, .layout = .{ .virtualized = true, .virtual_item_extent = 28, .virtual_overscan = 0 }, .semantics = .{ .label = "Component navigation" }, .children = &nav_items });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 130, .kind = .scroll_view, .frame = rect(316, 124, 240, 84), .value = virtual_scroll.behavior, .layout = .{ .virtualized = true, .virtual_item_extent = 28, .virtual_overscan = 0 }, .semantics = .{ .label = "Scrollable behavior list" }, .children = &scroll_items });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 149, .kind = .stack, .frame = rect(64, 264, 568, 60), .semantics = .{ .label = "Data controls" }, .children = &data_panel_children });
        },
        .components => {
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 101, .kind = .text, .frame = rect(64, 56, 280, 26), .text = "Built-in Components", .size = .lg });
            for (component_catalog_items) |item| {
                try appendComponentWidget(&content_widgets, &content_widget_count, item);
            }
        },
        .surfaces => {
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 101, .kind = .text, .frame = rect(64, 56, 240, 26), .text = "Surfaces", .size = .lg });
            try appendComponentWidget(&content_widgets, &content_widget_count, canvas.builtinComponentWidget(.card, .{ .id = 174, .frame = rect(64, 124, 276, 156), .text = "Team plan", .semantics = .{ .label = "Team plan card" }, .children = &card_preview_children }));
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 140, .kind = .popover, .frame = rect(384, 124, 260, 126), .backdrop_blur_token = .sm, .semantics = .{ .label = "Project actions popover" }, .children = &popover_children });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 175, .kind = .button, .frame = rect(64, 320, 170, 44), .text = "Dialog", .variant = .outline, .command = surface_dialog_command, .semantics = .{ .label = "Open dialog" } });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 176, .kind = .button, .frame = rect(248, 320, 120, 44), .text = "Drawer", .variant = .outline, .command = surface_drawer_command, .semantics = .{ .label = "Open drawer" } });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 177, .kind = .button, .frame = rect(382, 320, 120, 44), .text = "Sheet", .variant = .outline, .command = surface_sheet_command, .semantics = .{ .label = "Open sheet" } });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 160, .kind = .tooltip, .frame = rect(64, 416, 176, 32), .text = "Tooltip rendered on GPU", .semantics = .{ .label = "GPU tooltip" } });
        },
    }

    if (ui_state.environment_select_open and (ui_state.section == .controls or ui_state.section == .inputs)) {
        try appendComponentWidget(&content_widgets, &content_widget_count, .{
            .id = environment_menu_id,
            .kind = .dropdown_menu,
            .frame = rect(64, 494, 180, 104),
            .layout = canvas.builtinComponentWidget(.dropdown_menu, .{}).layout,
            .semantics = .{ .label = "Environment options" },
            .children = &environment_menu_items,
        });
    }
    const content_width = @max(1, size.width - sidebar_width);
    const content_height = @max(content_height_available, componentSectionContentHeight(ui_state.section));
    const content_children = [_]canvas.Widget{.{
        .id = content_stack_id,
        .kind = .stack,
        .frame = rect(0, 0, content_width, content_height),
        .children = content_widgets[0..content_widget_count],
    }};
    var root_widgets: [7]canvas.Widget = undefined;
    var root_widget_count: usize = 0;
    try appendComponentWidget(&root_widgets, &root_widget_count, .{
        .id = canvas_sidebar_id,
        .kind = .panel,
        .frame = rect(0, 0, sidebar_width, content_height_available),
        .style = .{ .radius = 0 },
        .semantics = .{ .label = "Component sections" },
        .children = &sidebar_children,
    });
    try appendComponentWidget(&root_widgets, &root_widget_count, .{
        .id = content_scroll_id,
        .kind = .scroll_view,
        .frame = rect(sidebar_width, 0, content_width, content_height_available),
        .value = virtual_scroll.page,
        .layout = .{ .clip_content = true },
        .semantics = .{ .label = "Component section content" },
        .children = &content_children,
    });
    try appendComponentWidget(&root_widgets, &root_widget_count, .{
        .id = canvas_sidebar_resize_line_id,
        .kind = .separator,
        .frame = sidebarResizeLineFrame(sidebar_width, content_height_available),
        .style = .{ .stroke_width = canvas_sidebar_resize_line_width },
    });
    try appendComponentWidget(&root_widgets, &root_widget_count, .{
        .id = canvas_sidebar_resize_handle_id,
        .kind = .slider,
        .frame = sidebarResizeHandleFrame(sidebar_width, content_height_available),
        .opacity = 0,
        .style = .{ .background = rgba(0, 0, 0, 0), .foreground = rgba(0, 0, 0, 0), .border = rgba(0, 0, 0, 0), .radius = 0, .stroke_width = 0 },
        .semantics = .{ .label = "Resize component sidebar" },
    });
    try appendComponentWidget(&root_widgets, &root_widget_count, .{
        .id = canvas_status_text_id,
        .kind = .text,
        .frame = rect(14, content_height_available + 7, @max(1, size.width - 28), 18),
        .text = ui_state.status_text,
        .size = .sm,
        .semantics = .{ .label = ui_state.status_text },
    });

    var surface_overlay_children_storage: [3]canvas.Widget = undefined;
    if (ui_state.surface_overlay != .none) {
        const overlay_frame = surfaceOverlayFrameForSidebar(size, ui_state.surface_overlay, sidebar_width);
        const overlay_content_width = @max(1, overlay_frame.width - 40);
        const overlay_content_height = @max(1, overlay_frame.height - 40);
        surface_overlay_children_storage = .{
            .{ .id = surface_overlay_title_id, .kind = .text, .frame = rect(0, 0, overlay_content_width, 28), .text = surfaceOverlayLabel(ui_state.surface_overlay), .size = .lg },
            .{ .id = surface_overlay_body_id, .kind = .text, .frame = rect(0, 48, overlay_content_width, 44), .text = surfaceOverlayBody(ui_state.surface_overlay), .size = .sm },
            .{ .id = surface_overlay_close_id, .kind = .button, .frame = rect(@max(0, overlay_content_width - 96), @max(104, overlay_content_height - 34), 96, 34), .text = "Close", .variant = .outline, .command = surface_close_command, .semantics = .{ .label = "Close surface" } },
        };
        try appendComponentWidget(&root_widgets, &root_widget_count, .{
            .id = surface_overlay_backdrop_id,
            .kind = .panel,
            .frame = rect(0, 0, size.width, content_height_available),
            .layer = surface_backdrop_layer,
            .style = .{ .background = rgba(0, 0, 0, 154), .border = rgba(0, 0, 0, 0), .radius = 0, .stroke_width = 0 },
            .semantics = .{ .label = "Surface backdrop" },
        });
        try appendComponentWidget(&root_widgets, &root_widget_count, canvas.builtinComponentWidget(surfaceOverlayKind(ui_state.surface_overlay), .{
            .id = surface_overlay_id,
            .frame = overlay_frame,
            .layer = surface_overlay_layer,
            .semantics = .{ .label = surfaceOverlayLabel(ui_state.surface_overlay) },
            .children = &surface_overlay_children_storage,
        }));
    }

    return canvas.layoutWidgetTree(.{ .kind = .stack, .children = root_widgets[0..root_widget_count] }, rect(0, 0, size.width, size.height), nodes);
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

fn componentStatusText(runtime: *const zero_native.Runtime) ![]const u8 {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    const node = layout.findById(canvas_status_text_id) orelse return error.TestUnexpectedResult;
    return node.widget.text;
}

fn expectComponentStatusContains(runtime: *const zero_native.Runtime, text: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, try componentStatusText(runtime), text) != null);
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
    try dispatchComponentPointerClickAtTimestamp(runtime, app, id, 0);
}

fn dispatchComponentPointerClickAtTimestamp(runtime: *zero_native.Runtime, app: zero_native.App, id: canvas.ObjectId, timestamp_ns: u64) !void {
    const point = try componentWidgetCenter(runtime, id);
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .timestamp_ns = timestamp_ns,
        .x = point.x,
        .y = point.y,
        .button = 0,
    } });
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_up,
        .timestamp_ns = timestamp_ns,
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
    try dispatchComponentPointerDragPoints(runtime, app, start, end);
}

fn dispatchComponentPointerDragByDelta(runtime: *zero_native.Runtime, app: zero_native.App, id: canvas.ObjectId, delta_x: f32) !void {
    const point = try componentWidgetCenter(runtime, id);
    try dispatchComponentPointerDragPoints(runtime, app, point, geometry.PointF.init(point.x + delta_x, point.y));
}

fn dispatchComponentPointerDragPoints(runtime: *zero_native.Runtime, app: zero_native.App, start: geometry.PointF, end: geometry.PointF) !void {
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

fn contentRect(x: f32, y: f32, width: f32, height: f32) geometry.RectF {
    return contentRectForSidebar(canvas_sidebar_width, x, y, width, height);
}

fn contentRectForSidebar(sidebar_width: f32, x: f32, y: f32, width: f32, height: f32) geometry.RectF {
    return rect(sidebar_width + x, y, width, height);
}

fn sidebarResizeHandleFrame(sidebar_width: f32, surface_height: f32) geometry.RectF {
    return rect(sidebar_width - canvas_sidebar_resize_handle_width * 0.5, 0, canvas_sidebar_resize_handle_width, @max(1, surface_height));
}

fn sidebarResizeLineFrame(sidebar_width: f32, surface_height: f32) geometry.RectF {
    return rect(sidebar_width - canvas_sidebar_resize_line_width * 0.5, 0, canvas_sidebar_resize_line_width, @max(1, surface_height));
}

fn componentCommandPartId(id: canvas.ObjectId, slot: canvas.ObjectId) canvas.ObjectId {
    return id * 16 + slot;
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
    try std.testing.expect(shell_views[5].kind == .gpu_surface);
    try std.testing.expectEqualStrings("body", shell_views[5].parent.?);
    try std.testing.expect(shell_views[5].gpu_backend.? == .metal);
    try std.testing.expect(shell_views[5].gpu_pixel_format.? == .bgra8_unorm);
    try std.testing.expect(shell_views[5].gpu_present_mode.? == .timer);
    try std.testing.expect(shell_views[5].gpu_alpha_mode.? == .@"opaque");
    try std.testing.expect(shell_views[5].gpu_color_space.? == .srgb);
    try std.testing.expect(shell_views[5].gpu_vsync.?);
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

    try std.testing.expect(display_list.commandCount() >= 54);
    try std.testing.expect(display_list.commandCount() <= max_component_commands);
    try std.testing.expect(display_list.findCommandById(canvas_status_separator_id) != null);
    try std.testing.expect(display_list.findCommandById(3) != null);
    try std.testing.expect(display_list.findCommandById(primary_button_fill_id) != null);
    try std.testing.expect(display_list.findCommandById(project_static_text_id) != null);
    try std.testing.expect(display_list.findCommandById(search_text_id) != null);
    try expectComponentTextCommand(display_list, environment_select_text_id, "Production");
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

    try expectComponentWidgetFrame(layout, canvas_sidebar_id, rect(0, 0, canvas_sidebar_width, canvas_content_height));
    try std.testing.expectEqual(@as(?f32, 0), layout.findById(canvas_sidebar_id).?.widget.style.radius);
    try expectComponentWidgetFrame(layout, canvas_sidebar_resize_line_id, sidebarResizeLineFrame(canvas_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, canvas_sidebar_resize_handle_id, sidebarResizeHandleFrame(canvas_sidebar_width, canvas_content_height));
    try std.testing.expectEqual(canvas.WidgetCursor.resize_horizontal, layout.cursorForHit(layout.hitTest(pt(canvas_sidebar_width, 12))));
    try std.testing.expectEqual(canvas.WidgetCursor.resize_horizontal, layout.cursorForHit(layout.hitTest(sidebarResizeHandleFrame(canvas_sidebar_width, canvas_content_height).center())));
    try std.testing.expectEqual(canvas.WidgetCursor.resize_horizontal, layout.cursorForHit(layout.hitTest(pt(canvas_sidebar_width, canvas_content_height - 12))));
    try expectComponentWidgetFrame(layout, content_scroll_id, rect(canvas_sidebar_width, 0, canvas_width - canvas_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, canvas_status_text_id, rect(14, canvas_content_height + 7, canvas_width - 28, 18));
    try std.testing.expectEqualStrings(initial_component_status_text, layout.findById(canvas_status_text_id).?.widget.text);
    try expectComponentWidgetFrame(layout, componentSectionNavId(.controls), rect(14, 78, 180, 34));
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
    try expectComponentWidgetFrame(layout, 118, contentRect(254, 284, 124, 54));
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
    try expectComponentWidgetsDoNotOverlap(layout, 167, 118);
    try expectComponentWidgetsDoNotOverlap(layout, 168, 118);
    try expectComponentWidgetsDoNotOverlap(layout, 171, 168);
    try expectComponentWidgetsDoNotOverlap(layout, 171, 118);
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
    try expectComponentWidgetFrame(catalog_layout, 182, contentRect(324, 124, catalog_card_width, catalog_card_height));
    try expectComponentWidgetFrame(catalog_layout, 184, contentRect(64, 194, catalog_card_width, catalog_card_height));
    try std.testing.expect(catalog_layout.findById(180) == null);

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
    try expectComponentWidgetFrame(dialog_layout, surface_overlay_backdrop_id, rect(0, 0, canvas_width, canvas_content_height));
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
    try std.testing.expectEqual(canvas_content_height, drawer_frame.y + drawer_frame.height);

    var sheet_nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const sheet_layout = try buildComponentsWidgetLayoutWithStateAndSize(&sheet_nodes, .{}, .{
        .surface_overlay = .sheet,
    }, default_canvas_size);
    const sheet_frame = surfaceOverlayFrame(default_canvas_size, .sheet);
    try expectComponentWidgetFrame(sheet_layout, surface_overlay_id, sheet_frame);
    try std.testing.expectEqual(canvas_width, sheet_frame.x + sheet_frame.width);
    try std.testing.expectEqual(@as(f32, 0), sheet_frame.y);
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

    try expectComponentWidgetFrame(layout, canvas_sidebar_id, rect(0, 0, resized_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, content_scroll_id, rect(resized_sidebar_width, 0, canvas_width - resized_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, canvas_sidebar_resize_handle_id, sidebarResizeHandleFrame(resized_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, componentSectionNavId(.controls), rect(14, 78, resized_sidebar_width - 28, 34));
    try expectComponentWidgetFrame(layout, 111, contentRectForSidebar(resized_sidebar_width, 64, 124, 148, 34));
    try std.testing.expectEqual(canvas.WidgetCursor.resize_horizontal, layout.cursorForHit(layout.hitTest(sidebarResizeHandleFrame(resized_sidebar_width, canvas_content_height).center())));

    var commands: [max_component_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildComponentsDisplayListForSize(&builder, layout, componentTokens(), default_canvas_size);
    try expectComponentRoundedRectFrame(builder.displayList(), 3, componentSurfaceCardRectForSidebar(default_canvas_size, resized_sidebar_width));

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

    try std.testing.expectEqual(@as(u64, 3860118020799347774), referenceSurfaceSignature(pixels));
    try expectVisiblePixel(surface.pixelRgba8(36, 36));
    try expectVisiblePixel(surface.pixelRgba8(92, 88));
    try expectVisiblePixel(surface.pixelRgba8(330, 160));
    try std.testing.expectEqual(@as(u8, 255), surface.pixelRgba8(288, 190)[3]);
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

    try std.testing.expectEqual(@as(usize, 2), componentCatalogPreviewChildren(.button_group).len);
    try std.testing.expectEqual(@as(usize, 3), componentCatalogPreviewChildren(.pagination).len);
    try std.testing.expectEqual(@as(usize, 1), componentCatalogPreviewChildren(.table).len);
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
        .frame = geometry.RectF.init(0, toolbar_height, canvas_width + 320, canvas_height),
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
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action components-canvas 150 increment");
    snapshot = harness.runtime.automationSnapshot("Components");
    const keyed_grid = componentSnapshotWidget(snapshot, 150).?;
    try std.testing.expectApproxEqAbs(@as(f32, 56), keyed_grid.scroll.offset, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 56), app.virtual_scroll.data, 0.001);
    try expectComponentStatusContains(&harness.runtime, "Keyed table #150: offset 56");

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
    try expectComponentStatusContains(&harness.runtime, "GPU component theme: Dark from toolbar");

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
    try expectComponentStatusContains(&harness.runtime, "GPU component theme: High contrast from toolbar");

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
    try dispatchComponentPointerClick(&harness.runtime, app_handle, environment_select_id);
    try std.testing.expectEqual(@as(u32, 0), app.refresh_count);
    try std.testing.expect(app.environment_select_open);
    var snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expect(componentSnapshotWidget(snapshot, environment_menu_id) != null);
    try expectComponentStatusContains(&harness.runtime, "Environment menu opened.");

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
    try expectComponentWidgetFrame(layout, surface_overlay_backdrop_id, rect(0, 0, canvas_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, surface_overlay_id, surfaceOverlayFrame(default_canvas_size, .dialog));
    try std.testing.expectEqualStrings("Confirm deployment", layout.findById(surface_overlay_title_id).?.widget.text);
    var snapshot = harness.runtime.automationSnapshot("Components");
    try std.testing.expectEqualStrings("dialog", componentSnapshotWidget(snapshot, surface_overlay_id).?.role);
    try std.testing.expect(componentSnapshotWidget(snapshot, surface_overlay_close_id).?.actions.press);
    try expectComponentStatusContains(&harness.runtime, "Confirm deployment surface opened.");

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
    var animations = try harness.runtime.canvasRenderAnimations(1, canvas_label);
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
        .y = 20,
    } });
    try std.testing.expectEqual(zero_native.platform.Cursor.resize_horizontal, harness.null_platform.view_cursor);

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerDragByDelta(&harness.runtime, app_handle, canvas_sidebar_resize_handle_id, 60);
    const widened_sidebar_width = canvas_sidebar_width + 60;
    try std.testing.expectApproxEqAbs(widened_sidebar_width, app.sidebar_width, 0.001);
    var layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try expectComponentWidgetFrame(layout, canvas_sidebar_id, rect(0, 0, widened_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, content_scroll_id, rect(widened_sidebar_width, 0, canvas_width - widened_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, canvas_sidebar_resize_line_id, sidebarResizeLineFrame(widened_sidebar_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, canvas_sidebar_resize_handle_id, sidebarResizeHandleFrame(widened_sidebar_width, canvas_content_height));
    var display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentRoundedRectFrame(display_list, 3, componentSurfaceCardRectForSidebar(default_canvas_size, widened_sidebar_width));
    try std.testing.expect(harness.runtime.invalidated);

    resetComponentDirty(&harness.runtime);
    try dispatchComponentPointerDragByDelta(&harness.runtime, app_handle, canvas_sidebar_resize_handle_id, -120);
    try std.testing.expectApproxEqAbs(canvas_sidebar_min_width, app.sidebar_width, 0.001);
    layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    try expectComponentWidgetFrame(layout, canvas_sidebar_id, rect(0, 0, canvas_sidebar_min_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, content_scroll_id, rect(canvas_sidebar_min_width, 0, canvas_width - canvas_sidebar_min_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, canvas_sidebar_resize_line_id, sidebarResizeLineFrame(canvas_sidebar_min_width, canvas_content_height));
    try expectComponentWidgetFrame(layout, canvas_sidebar_resize_handle_id, sidebarResizeHandleFrame(canvas_sidebar_min_width, canvas_content_height));
    display_list = try harness.runtime.canvasDisplayList(1, canvas_label);
    try expectComponentRoundedRectFrame(display_list, 3, componentSurfaceCardRectForSidebar(default_canvas_size, canvas_sidebar_min_width));

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

fn expectSurfaceTransformAnimation(animations: []const canvas.CanvasRenderAnimation, id: canvas.ObjectId, tx: f32, ty: f32) !void {
    for (animations) |animation| {
        if (animation.id != id) continue;
        try std.testing.expectEqualDeep(canvas.Affine.identity(), animation.to_transform.?);
        try std.testing.expectApproxEqAbs(tx, animation.from_transform.?.tx, 0.001);
        try std.testing.expectApproxEqAbs(ty, animation.from_transform.?.ty, 0.001);
        return;
    }
    return error.TestUnexpectedResult;
}

fn expectSurfaceAnimationStart(animations: []const canvas.CanvasRenderAnimation, id: canvas.ObjectId, start_ns: u64) !void {
    for (animations) |animation| {
        if (animation.id != id) continue;
        try std.testing.expectEqual(start_ns, animation.start_ns);
        return;
    }
    return error.TestUnexpectedResult;
}

fn expectSurfaceOpacityAnimation(animations: []const canvas.CanvasRenderAnimation, id: canvas.ObjectId) !void {
    for (animations) |animation| {
        if (animation.id != id) continue;
        try std.testing.expectEqual(@as(f32, 0), animation.from_opacity.?);
        try std.testing.expectEqual(@as(f32, 1), animation.to_opacity.?);
        try std.testing.expect(animation.from_transform == null);
        try std.testing.expect(animation.to_transform == null);
        return;
    }
    return error.TestUnexpectedResult;
}

fn expectNoSurfaceAnimation(animations: []const canvas.CanvasRenderAnimation, id: canvas.ObjectId) !void {
    for (animations) |animation| {
        if (animation.id == id) return error.TestUnexpectedResult;
    }
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
