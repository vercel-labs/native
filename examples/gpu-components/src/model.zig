const std = @import("std");
pub const zero_native = @import("zero-native");
pub const canvas = zero_native.canvas;
pub const geometry = zero_native.geometry;

pub const window_width: f32 = 1180;
pub const window_height: f32 = 760;
pub const toolbar_height: f32 = 52;
pub const canvas_sidebar_width: f32 = 208;
pub const canvas_sidebar_min_width: f32 = 168;
pub const canvas_sidebar_max_width: f32 = 360;
pub const canvas_sidebar_min_content_width: f32 = 420;
pub const canvas_sidebar_resize_handle_width: f32 = 14;
pub const canvas_sidebar_resize_line_width: f32 = 1;
pub const statusbar_height: f32 = 32;
pub const canvas_width: f32 = window_width;
pub const canvas_height: f32 = window_height;
pub const canvas_content_y: f32 = toolbar_height;
pub const canvas_content_height: f32 = canvas_height - toolbar_height - statusbar_height;
pub const default_canvas_size = geometry.SizeF.init(canvas_width, canvas_height);
pub const max_component_pipelines: usize = 8;
pub const max_component_commands: usize = zero_native.runtime.max_canvas_commands_per_view;
pub const max_component_glyphs: usize = zero_native.runtime.max_canvas_glyphs_per_view;
pub const max_component_widgets: usize = zero_native.runtime.max_canvas_widget_nodes_per_view;
pub const component_chrome_prefix_commands: usize = 4;
pub const component_chrome_suffix_commands: usize = 0;
pub const catalog_grid_columns: usize = 3;
pub const catalog_card_width: f32 = 256;
pub const catalog_card_height: f32 = 132;
pub const catalog_card_gap_x: f32 = 22;
pub const catalog_card_gap_y: f32 = 18;
pub const catalog_preview_y: f32 = 40;
pub const catalog_preview_width: f32 = catalog_card_width - 32;
pub const refresh_command = "components.refresh";
pub const theme_command = "components.theme";
pub const environment_toggle_command = "components.environment.toggle";
pub const surface_dialog_command = "components.surface.dialog";
pub const surface_drawer_command = "components.surface.drawer";
pub const surface_sheet_command = "components.surface.sheet";
pub const surface_close_command = "components.surface.close";
pub const environment_option_commands = [_][]const u8{
    "components.environment.production",
    "components.environment.preview",
    "components.environment.staging",
};
pub const canvas_label = "components-canvas";
pub const primary_button_fill_id: canvas.ObjectId = 104 * 16 + 1;
pub const project_static_text_id: canvas.ObjectId = 111 * 16 + 3;
pub const project_text_id: canvas.ObjectId = 111 * 16 + 4;
pub const project_selection_id: canvas.ObjectId = 111 * 16 + 3;
pub const project_composition_id: canvas.ObjectId = 111 * 16 + 5;
pub const search_text_id: canvas.ObjectId = 112 * 16 + 9;
pub const search_selection_id: canvas.ObjectId = 112 * 16 + 8;
pub const search_composition_id: canvas.ObjectId = 112 * 16 + 10;
pub const message_text_id: canvas.ObjectId = 171 * 16 + 4;
pub const scroll_track_id: canvas.ObjectId = 130 * 16 + 2;
pub const scroll_thumb_id: canvas.ObjectId = 130 * 16 + 3;
pub const menu_item_text_id: canvas.ObjectId = 142 * 16 + 3;
pub const data_cell_text_id: canvas.ObjectId = 156 * 16 + 4;
pub const environment_select_id: canvas.ObjectId = 172;
pub const environment_select_text_id: canvas.ObjectId = environment_select_id * 16 + 3;
pub const environment_menu_id: canvas.ObjectId = 216;
pub const environment_option_base_id: canvas.ObjectId = 21601;
pub const content_scroll_id: canvas.ObjectId = 90;
pub const canvas_sidebar_id: canvas.ObjectId = 92;
pub const canvas_sidebar_title_id: canvas.ObjectId = 93;
pub const section_nav_base_id: canvas.ObjectId = 94;
pub const canvas_background_id: canvas.ObjectId = 79;
pub const canvas_toolbar_id: canvas.ObjectId = 80;
pub const canvas_toolbar_title_id: canvas.ObjectId = 81;
pub const canvas_toolbar_theme_id: canvas.ObjectId = 82;
pub const canvas_toolbar_refresh_id: canvas.ObjectId = 83;
pub const canvas_toolbar_separator_id: canvas.ObjectId = 84;
pub const canvas_sidebar_resize_line_id: canvas.ObjectId = 88;
pub const canvas_sidebar_resize_handle_id: canvas.ObjectId = 99;
pub const canvas_status_text_id: canvas.ObjectId = 261;
pub const canvas_status_separator_id: canvas.ObjectId = canvas_status_text_id * 16 + 2;
pub const surface_overlay_backdrop_id: canvas.ObjectId = 222;
pub const surface_overlay_id: canvas.ObjectId = 223;
pub const surface_overlay_title_id: canvas.ObjectId = 224;
pub const surface_overlay_body_id: canvas.ObjectId = 225;
pub const surface_overlay_close_id: canvas.ObjectId = 226;
pub const surface_overlay_content_parts = [_]canvas.WidgetCommandPart{
    .{ .widget_id = surface_overlay_title_id, .slot = 1 },
    .{ .widget_id = surface_overlay_body_id, .slot = 1 },
    .{ .widget_id = surface_overlay_close_id, .slot = 1 },
    .{ .widget_id = surface_overlay_close_id, .slot = 2 },
    .{ .widget_id = surface_overlay_close_id, .slot = 4 },
};
pub const surface_backdrop_layer: i32 = 300;
pub const surface_overlay_layer: i32 = 301;
pub const max_surface_overlay_animations: usize = 12;
pub const popover_blur_id: canvas.ObjectId = 140 * 16 + 12;
pub const preview_image_id: canvas.ImageId = 42;
pub const environment_options = [_][]const u8{ "Production", "Preview", "Staging" };
pub const initial_component_status_text = "Component lab waiting for the first GPU frame.";
pub const max_component_status_text: usize = 192;
pub const section_nav_commands = [_][]const u8{
    "components.section.controls",
    "components.section.inputs",
    "components.section.data",
    "components.section.components",
    "components.section.surfaces",
};

pub const ComponentVirtualScroll = struct {
    page: f32 = 0,
    page_velocity: f32 = 0,
    nav: f32 = 0,
    nav_velocity: f32 = 0,
    behavior: f32 = 28,
    behavior_velocity: f32 = 0,
    data: f32 = 28,
    data_velocity: f32 = 0,
};

pub const ComponentUiState = struct {
    environment_select_open: bool = false,
    environment_index: usize = 0,
    surface_overlay: ComponentSurfaceOverlay = .none,
    section: ComponentSection = .controls,
    sidebar_width: f32 = canvas_sidebar_width,
    status_text: []const u8 = initial_component_status_text,
};

pub const ComponentSurfaceOverlay = enum {
    none,
    dialog,
    drawer,
    sheet,
};

pub const ComponentSection = enum(u8) {
    controls,
    inputs,
    data,
    components,
    surfaces,
};

pub const ComponentThemeMode = enum {
    light,
    dark,
    high,

    pub fn next(self: ComponentThemeMode) ComponentThemeMode {
        return switch (self) {
            .light => .dark,
            .dark => .high,
            .high => .light,
        };
    }

    pub fn label(self: ComponentThemeMode) []const u8 {
        return switch (self) {
            .light => "Light",
            .dark => "Dark",
            .high => "High contrast",
        };
    }
};

pub fn environmentLabel(index: usize) []const u8 {
    return environment_options[@min(index, environment_options.len - 1)];
}

pub fn environmentOptionId(index: usize) canvas.ObjectId {
    return environment_option_base_id + @as(canvas.ObjectId, @intCast(index));
}

pub fn environmentOptionIndex(id: canvas.ObjectId) ?usize {
    if (id < environment_option_base_id) return null;
    const index = id - environment_option_base_id;
    if (index >= environment_options.len) return null;
    return @intCast(index);
}

pub fn environmentNextIndex(index: usize) usize {
    return (@min(index, environment_options.len - 1) + 1) % environment_options.len;
}

pub fn environmentPreviousIndex(index: usize) usize {
    const current = @min(index, environment_options.len - 1);
    return if (current == 0) environment_options.len - 1 else current - 1;
}

pub fn environmentCommandIndex(command_name: []const u8) ?usize {
    for (environment_option_commands, 0..) |option_command, index| {
        if (std.mem.eql(u8, command_name, option_command)) return index;
    }
    return null;
}

pub fn componentSectionLabel(section: ComponentSection) []const u8 {
    return switch (section) {
        .controls => "Controls",
        .inputs => "Inputs",
        .data => "Data",
        .components => "Components",
        .surfaces => "Surfaces",
    };
}

pub fn componentSectionCommand(section: ComponentSection) []const u8 {
    return section_nav_commands[@intFromEnum(section)];
}

pub fn componentSectionFromCommand(command_name: []const u8) ?ComponentSection {
    for (section_nav_commands, 0..) |section_command, index| {
        if (std.mem.eql(u8, command_name, section_command)) return @enumFromInt(index);
    }
    return null;
}

pub fn componentSectionNavId(section: ComponentSection) canvas.ObjectId {
    return section_nav_base_id + @as(canvas.ObjectId, @intFromEnum(section));
}

pub fn surfaceOverlayLabel(overlay: ComponentSurfaceOverlay) []const u8 {
    return switch (overlay) {
        .dialog => "Confirm deployment",
        .drawer => "Project settings",
        .sheet => "Command palette",
        .none => "Surface",
    };
}

pub fn surfaceOverlayBody(overlay: ComponentSurfaceOverlay) []const u8 {
    return switch (overlay) {
        .dialog => "Production rollout is ready for review.",
        .drawer => "Team notifications are synced.",
        .sheet => "Recent actions are ready.",
        .none => "",
    };
}

pub fn color(r: u8, g: u8, b: u8) canvas.Color {
    return canvas.Color.rgb8(r, g, b);
}

pub fn rgba(r: u8, g: u8, b: u8, a: u8) canvas.Color {
    return canvas.Color.rgba8(r, g, b, a);
}

pub fn rect(x: f32, y: f32, width: f32, height: f32) geometry.RectF {
    return geometry.RectF.init(x, y, width, height);
}

pub fn contentRect(x: f32, y: f32, width: f32, height: f32) geometry.RectF {
    return contentRectForSidebar(canvas_sidebar_width, x, y, width, height);
}

pub fn contentRectForSidebar(sidebar_width: f32, x: f32, y: f32, width: f32, height: f32) geometry.RectF {
    return rect(sidebar_width + x, canvas_content_y + y, width, height);
}

pub fn sidebarResizeHandleFrame(sidebar_width: f32, surface_height: f32) geometry.RectF {
    return rect(sidebar_width - canvas_sidebar_resize_handle_width * 0.5, canvas_content_y, canvas_sidebar_resize_handle_width, @max(1, surface_height));
}

pub fn sidebarResizeLineFrame(sidebar_width: f32, surface_height: f32) geometry.RectF {
    return rect(sidebar_width - canvas_sidebar_resize_line_width * 0.5, canvas_content_y, canvas_sidebar_resize_line_width, @max(1, surface_height));
}

pub fn componentCommandPartId(id: canvas.ObjectId, slot: canvas.ObjectId) canvas.ObjectId {
    return canvas.widgetCommandPartId(.{ .widget_id = id, .slot = slot });
}

pub fn pt(x: f32, y: f32) geometry.PointF {
    return geometry.PointF.init(x, y);
}
