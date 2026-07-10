const std = @import("std");
const native_sdk = @import("native_sdk");
const model = @import("model.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

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
const max_component_widgets = model.max_component_widgets;
const component_chrome_prefix_commands = model.component_chrome_prefix_commands;
const component_chrome_suffix_commands = model.component_chrome_suffix_commands;
const catalog_grid_columns = model.catalog_grid_columns;
const catalog_card_width = model.catalog_card_width;
const catalog_card_height = model.catalog_card_height;
const catalog_card_gap_x = model.catalog_card_gap_x;
const catalog_card_gap_y = model.catalog_card_gap_y;
const catalog_preview_y = model.catalog_preview_y;
const catalog_preview_width = model.catalog_preview_width;
const refresh_command = model.refresh_command;
const themeModeCommand = model.themeModeCommand;
const themeModeTriggerId = model.themeModeTriggerId;
const environment_toggle_command = model.environment_toggle_command;
const surface_dialog_command = model.surface_dialog_command;
const surface_drawer_command = model.surface_drawer_command;
const surface_sheet_command = model.surface_sheet_command;
const surface_close_command = model.surface_close_command;
const environment_option_commands = model.environment_option_commands;
const canvas_label = model.canvas_label;
const canvas_background_id = model.canvas_background_id;
const canvas_toolbar_id = model.canvas_toolbar_id;
const canvas_toolbar_title_id = model.canvas_toolbar_title_id;
const canvas_toolbar_theme_id = model.canvas_toolbar_theme_id;
const canvas_toolbar_refresh_id = model.canvas_toolbar_refresh_id;
const canvas_toolbar_separator_id = model.canvas_toolbar_separator_id;
const canvas_sidebar_id = model.canvas_sidebar_id;
const canvas_sidebar_title_id = model.canvas_sidebar_title_id;
const canvas_sidebar_resize_line_id = model.canvas_sidebar_resize_line_id;
const canvas_sidebar_resize_handle_id = model.canvas_sidebar_resize_handle_id;
const canvas_status_text_id = model.canvas_status_text_id;
const environment_select_id = model.environment_select_id;
const environment_stack_id = model.environment_stack_id;
const environment_menu_id = model.environment_menu_id;
const content_scroll_id = model.content_scroll_id;
const surface_overlay_backdrop_id = model.surface_overlay_backdrop_id;
const surface_overlay_id = model.surface_overlay_id;
const surface_overlay_title_id = model.surface_overlay_title_id;
const surface_overlay_body_id = model.surface_overlay_body_id;
const surface_overlay_close_id = model.surface_overlay_close_id;
const surface_overlay_content_parts = model.surface_overlay_content_parts;
const surface_backdrop_layer = model.surface_backdrop_layer;
const surface_overlay_layer = model.surface_overlay_layer;
const preview_image_id = model.preview_image_id;
const environment_options = model.environment_options;
const ComponentVirtualScroll = model.ComponentVirtualScroll;
const ComponentUiState = model.ComponentUiState;
const ComponentSurfaceOverlay = model.ComponentSurfaceOverlay;
const ComponentSection = model.ComponentSection;
const ComponentThemeMode = model.ComponentThemeMode;
const environmentLabel = model.environmentLabel;
const environmentOptionId = model.environmentOptionId;
const componentSectionLabel = model.componentSectionLabel;
const componentSectionCommand = model.componentSectionCommand;
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

const preview_image_pixels = [_]u8{
    38, 99,  235, 255, 16,  185, 129, 255, 250, 204, 21,  255, 244, 63,  94,  255,
    99, 102, 241, 255, 14,  165, 233, 255, 255, 255, 255, 255, 15,  23,  42,  255,
    45, 212, 191, 255, 59,  130, 246, 255, 168, 85,  247, 255, 248, 250, 252, 255,
    15, 23,  42,  255, 100, 116, 139, 255, 226, 232, 240, 255, 248, 113, 113, 255,
};

pub const preview_images = [_]canvas.ReferenceImage{.{
    .id = preview_image_id,
    .width = 4,
    .height = 4,
    .pixels = &preview_image_pixels,
}};

const catalog_accordion_content = [_]canvas.Widget{
    .{ .id = 18102, .kind = .text, .frame = rect(0, 0, 132, 18), .text = "Open details", .size = .sm },
};
const catalog_accordion_children = [_]canvas.Widget{canvas.builtinComponentWidget(.accordion, .{
    .id = 18101,
    .frame = rect(0, catalog_preview_y, catalog_preview_width, 48),
    .text = "Details",
    .children = &catalog_accordion_content,
})};
const catalog_alert_children = [_]canvas.Widget{canvas.builtinComponentWidget(.alert, .{
    .id = 18201,
    .frame = rect(0, catalog_preview_y, catalog_preview_width, 42),
    .text = "Update available",
})};
const catalog_avatar_children = [_]canvas.Widget{canvas.builtinComponentWidget(.avatar, .{
    .id = 18301,
    .frame = rect(0, catalog_preview_y, 36, 36),
    .text = "NS",
})};
const catalog_badge_children = [_]canvas.Widget{canvas.builtinComponentWidget(.badge, .{
    .id = 18401,
    .frame = rect(0, catalog_preview_y + 6, 64, 20),
    .text = "Active",
    .variant = .secondary,
})};
const catalog_breadcrumb_items = [_]canvas.Widget{
    .{ .id = 18501, .kind = .text, .text = "Home", .size = .sm },
    .{ .id = 18502, .kind = .text, .text = "Components", .size = .sm },
};
const catalog_breadcrumb_children = [_]canvas.Widget{canvas.builtinComponentWidget(.breadcrumb, .{
    .id = 18500,
    .frame = rect(0, catalog_preview_y, catalog_preview_width, 28),
    .children = &catalog_breadcrumb_items,
})};
const catalog_bubble_content = [_]canvas.Widget{
    .{ .id = 18602, .kind = .text, .frame = rect(0, 0, 128, 18), .text = "Message bubble", .size = .sm },
};
const catalog_bubble_children = [_]canvas.Widget{canvas.builtinComponentWidget(.bubble, .{
    .id = 18601,
    .frame = rect(0, catalog_preview_y, 164, 48),
    .children = &catalog_bubble_content,
})};
const catalog_button_children = [_]canvas.Widget{canvas.builtinComponentWidget(.button, .{
    .id = 18701,
    .frame = rect(0, catalog_preview_y, 88, 34),
    .text = "Button",
})};
const catalog_button_group_items = [_]canvas.Widget{
    .{ .id = 18801, .kind = .button, .text = "One", .size = .sm, .layout = .{ .grow = 1 } },
    .{ .id = 18802, .kind = .button, .text = "Two", .size = .sm, .variant = .secondary, .layout = .{ .grow = 1 } },
};
const catalog_button_group_children = [_]canvas.Widget{canvas.builtinComponentWidget(.button_group, .{
    .id = 18800,
    .frame = rect(0, catalog_preview_y, 160, 30),
    .children = &catalog_button_group_items,
})};
const catalog_card_preview_children = [_]canvas.Widget{
    .{ .id = 18902, .kind = .badge, .frame = rect(0, 28, 56, 20), .text = "Pro", .variant = .secondary },
};
const catalog_card_children = [_]canvas.Widget{canvas.builtinComponentWidget(.card, .{
    .id = 18901,
    .frame = rect(0, catalog_preview_y, 178, 64),
    .text = "Card",
    // The catalog's fixed frames were tuned against 16px card padding;
    // the component default is now the component default of 24, so the compact inset
    // is pinned explicitly here.
    .layout = .{ .padding = geometry.InsetsF.all(16), .gap = 12, .clip_content = true },
    .children = &catalog_card_preview_children,
})};
const catalog_checkbox_children = [_]canvas.Widget{canvas.builtinComponentWidget(.checkbox, .{
    .id = 19001,
    .frame = rect(0, catalog_preview_y + 4, 118, 28),
    .text = "Selected",
    .state = .{ .selected = true },
})};
const catalog_combobox_children = [_]canvas.Widget{canvas.builtinComponentWidget(.combobox, .{
    .id = 19101,
    .frame = rect(0, catalog_preview_y, 172, 34),
    .text = "components",
})};
const catalog_dialog_children = [_]canvas.Widget{canvas.builtinComponentWidget(.dialog, .{
    .id = 19201,
    .frame = rect(0, catalog_preview_y, catalog_preview_width, 58),
    .text = "Confirm",
    // Inline catalog specimen, not an open modal: no scrim behind it.
    .scrim = false,
})};
const catalog_drawer_children = [_]canvas.Widget{canvas.builtinComponentWidget(.drawer, .{
    .id = 19301,
    .frame = rect(0, catalog_preview_y, catalog_preview_width, 58),
    .text = "Drawer",
    // Inline catalog specimen, not an open modal: no scrim behind it.
    .scrim = false,
})};
const catalog_dropdown_items = [_]canvas.Widget{
    .{ .id = 19401, .kind = .menu_item, .text = "Copy" },
};
const catalog_dropdown_children = [_]canvas.Widget{canvas.builtinComponentWidget(.dropdown_menu, .{
    .id = 19400,
    .frame = rect(0, catalog_preview_y, 164, 40),
    .children = &catalog_dropdown_items,
})};
const catalog_input_children = [_]canvas.Widget{canvas.builtinComponentWidget(.input, .{
    .id = 19501,
    .frame = rect(0, catalog_preview_y, 172, 34),
    .text = "native-sdk",
})};
// The reference pagination row: ghost chevrons for previous/next, ghost
// page numbers with the current page carrying the outline variant, and
// an ellipsis cell standing in for the collapsed range.
const catalog_pagination_items = [_]canvas.Widget{
    .{ .id = 19601, .kind = .icon_button, .icon = "chevron-left", .size = .sm, .variant = .ghost, .semantics = .{ .label = "Previous page" } },
    .{ .id = 19602, .kind = .button, .text = "1", .size = .sm, .variant = .outline, .state = .{ .selected = true } },
    .{ .id = 19603, .kind = .button, .text = "2", .size = .sm, .variant = .ghost },
    .{ .id = 19604, .kind = .icon, .icon = "ellipsis", .semantics = .{ .label = "More pages" } },
    .{ .id = 19605, .kind = .icon_button, .icon = "chevron-right", .size = .sm, .variant = .ghost, .semantics = .{ .label = "Next page" } },
};
const catalog_pagination_children = [_]canvas.Widget{canvas.builtinComponentWidget(.pagination, .{
    .id = 19600,
    .frame = rect(0, catalog_preview_y, 168, 30),
    .children = &catalog_pagination_items,
})};
const catalog_progress_children = [_]canvas.Widget{canvas.builtinComponentWidget(.progress, .{
    .id = 19701,
    .frame = rect(0, catalog_preview_y + 15, 172, 4),
    .value = 0.62,
})};
const catalog_radio_group_items = [_]canvas.Widget{
    .{ .id = 19801, .kind = .radio, .text = "A", .state = .{ .selected = true } },
    .{ .id = 19802, .kind = .radio, .text = "B" },
};
const catalog_radio_group_children = [_]canvas.Widget{canvas.builtinComponentWidget(.radio_group, .{
    .id = 19800,
    .frame = rect(0, catalog_preview_y, 124, 28),
    .children = &catalog_radio_group_items,
})};
const catalog_resizable_content = [_]canvas.Widget{
    .{ .id = 19902, .kind = .text, .frame = rect(0, 0, 106, 18), .text = "Drag edge", .size = .sm },
};
const catalog_resizable_children = [_]canvas.Widget{canvas.builtinComponentWidget(.resizable, .{
    .id = 19901,
    .frame = rect(0, catalog_preview_y, 150, 48),
    .children = &catalog_resizable_content,
})};
const catalog_select_children = [_]canvas.Widget{canvas.builtinComponentWidget(.select, .{
    .id = 20001,
    .frame = rect(0, catalog_preview_y, 172, 34),
    .text = "Production",
})};
const catalog_separator_children = [_]canvas.Widget{canvas.builtinComponentWidget(.separator, .{
    .id = 20101,
    .frame = rect(0, catalog_preview_y + 17, 172, 1),
})};
const catalog_sheet_children = [_]canvas.Widget{canvas.builtinComponentWidget(.sheet, .{
    .id = 20201,
    .frame = rect(0, catalog_preview_y, catalog_preview_width, 58),
    .text = "Sheet",
    // Inline catalog specimen, not an open modal: no scrim behind it.
    .scrim = false,
})};
const catalog_skeleton_children = [_]canvas.Widget{canvas.builtinComponentWidget(.skeleton, .{
    .id = 20301,
    .frame = rect(0, catalog_preview_y + 6, 172, 22),
})};
const catalog_slider_children = [_]canvas.Widget{canvas.builtinComponentWidget(.slider, .{
    .id = 20401,
    .frame = rect(0, catalog_preview_y + 3, 172, 28),
    .value = 0.58,
})};
const catalog_spinner_children = [_]canvas.Widget{canvas.builtinComponentWidget(.spinner, .{
    .id = 20501,
    // The compact house register: a 16px (sm) activity glyph, centered
    // on the preview row instead of dwarfing it.
    .frame = rect(0, catalog_preview_y + 9, 16, 16),
})};
const catalog_switch_children = [_]canvas.Widget{canvas.builtinComponentWidget(.switch_control, .{
    .id = 20601,
    .frame = rect(0, catalog_preview_y + 4, 106, 28),
    .text = "Live",
    .value = 1,
    .state = .{ .selected = true },
})};
const catalog_table_row_cells = [_]canvas.Widget{
    .{ .id = 20702, .kind = .data_cell, .text = "Name", .layout = .{ .grow = 1 } },
    .{ .id = 20703, .kind = .data_cell, .text = "Status", .layout = .{ .grow = 1 } },
};
const catalog_table_rows = [_]canvas.Widget{
    .{ .id = 20701, .kind = .data_row, .children = &catalog_table_row_cells },
};
const catalog_table_children = [_]canvas.Widget{canvas.builtinComponentWidget(.table, .{
    .id = 20700,
    .frame = rect(0, catalog_preview_y, catalog_preview_width, 30),
    .children = &catalog_table_rows,
})};
const catalog_tabs_items = [_]canvas.Widget{
    .{ .id = 20801, .kind = .segmented_control, .text = "One", .size = .sm, .state = .{ .selected = true } },
    .{ .id = 20802, .kind = .segmented_control, .text = "Two", .size = .sm },
};
const catalog_tabs_children = [_]canvas.Widget{canvas.builtinComponentWidget(.tabs, .{
    .id = 20800,
    .frame = rect(0, catalog_preview_y, 148, 30),
    .children = &catalog_tabs_items,
})};
const catalog_textarea_children = [_]canvas.Widget{canvas.builtinComponentWidget(.textarea, .{
    .id = 20901,
    .frame = rect(0, catalog_preview_y, catalog_preview_width, 48),
    .text = "Write a note",
})};
const catalog_toggle_children = [_]canvas.Widget{canvas.builtinComponentWidget(.toggle, .{
    .id = 21001,
    .frame = rect(0, catalog_preview_y + 2, 76, 30),
    .text = "Bold",
    .state = .{ .selected = true },
})};
const catalog_toggle_group_items = [_]canvas.Widget{
    .{ .id = 21101, .kind = .toggle_button, .text = "B", .size = .sm, .state = .{ .selected = true } },
    .{ .id = 21102, .kind = .toggle_button, .text = "I", .size = .sm },
};
const catalog_toggle_group_children = [_]canvas.Widget{canvas.builtinComponentWidget(.toggle_group, .{
    .id = 21100,
    .frame = rect(0, catalog_preview_y, 96, 30),
    .children = &catalog_toggle_group_items,
})};
const catalog_tooltip_children = [_]canvas.Widget{canvas.builtinComponentWidget(.tooltip, .{
    .id = 21201,
    .frame = rect(0, catalog_preview_y + 2, 162, 30),
    .text = "Tooltip",
})};

pub fn installComponentsCanvasModel(runtime: *native_sdk.Runtime, window_id: native_sdk.WindowId, virtual_scroll: ComponentVirtualScroll, ui_state: ComponentUiState, tokens: canvas.DesignTokens, surface_size: geometry.SizeF) anyerror!void {
    var commands: [max_component_commands]canvas.CanvasCommand = undefined;
    var nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    var builder = canvas.Builder.init(&commands);
    const layout = try buildComponentsWidgetLayoutWithStateSizeAndTokens(&nodes, virtual_scroll, ui_state, surface_size, tokens);
    try buildComponentsDisplayListForSize(&builder, layout, tokens, surface_size);
    _ = try runtime.setCanvasDisplayList(window_id, canvas_label, builder.displayList());
    _ = try runtime.setCanvasWidgetLayout(window_id, canvas_label, layout);
    _ = try runtime.emitCanvasWidgetDisplayListWithChrome(window_id, canvas_label, tokens, .{
        .prefix_command_count = component_chrome_prefix_commands,
        .suffix_command_count = component_chrome_suffix_commands,
    });
}

pub fn buildComponentsDisplayListFromWidgets(builder: *canvas.Builder) canvas.Error!void {
    try buildComponentsDisplayListFromWidgetsWithTokens(builder, componentTokens());
}

/// The same catalog scene under an arbitrary token set — the per-theme
/// reference path: the signature tests render the identical widget
/// tree under each built-in pack, so every design system the SDK ships
/// is machine-verified pixel-for-pixel, not just the default one.
pub fn buildComponentsDisplayListFromWidgetsWithTokens(builder: *canvas.Builder, tokens: canvas.DesignTokens) canvas.Error!void {
    var nodes: [max_component_widgets]canvas.WidgetLayoutNode = undefined;
    const layout = try buildComponentsWidgetLayoutWithStateSizeAndTokens(&nodes, .{}, .{}, default_canvas_size, tokens);
    try buildComponentsDisplayList(builder, layout, tokens);
}

pub fn componentSurfaceSize(size: geometry.SizeF) geometry.SizeF {
    if (size.isEmpty()) return default_canvas_size;
    return .{
        .width = @max(1, size.width),
        .height = @max(1, size.height),
    };
}

pub fn componentStatusbarHeightForSize(surface_size: geometry.SizeF) f32 {
    const size = componentSurfaceSize(surface_size);
    return @min(statusbar_height, @max(0, size.height - 1));
}

pub fn componentToolbarHeightForSize(surface_size: geometry.SizeF) f32 {
    const size = componentSurfaceSize(surface_size);
    const status_height = componentStatusbarHeightForSize(size);
    return @min(toolbar_height, @max(0, size.height - status_height - 1));
}

pub fn componentContentYForSize(surface_size: geometry.SizeF) f32 {
    return componentToolbarHeightForSize(surface_size);
}

pub fn componentContentHeightForSize(surface_size: geometry.SizeF) f32 {
    const size = componentSurfaceSize(surface_size);
    return @max(1, size.height - componentToolbarHeightForSize(size) - componentStatusbarHeightForSize(size));
}

pub fn componentOverlaySize(surface_size: geometry.SizeF) geometry.SizeF {
    const size = componentSurfaceSize(surface_size);
    return geometry.SizeF.init(size.width, componentContentHeightForSize(size));
}

pub fn componentSidebarWidthForSize(requested_width: f32, surface_size: geometry.SizeF) f32 {
    const size = componentSurfaceSize(surface_size);
    const requested = if (std.math.isFinite(requested_width) and requested_width > 0) requested_width else canvas_sidebar_width;
    const max_for_surface = @min(canvas_sidebar_max_width, @max(canvas_sidebar_min_width, size.width - canvas_sidebar_min_content_width));
    return std.math.clamp(requested, canvas_sidebar_min_width, max_for_surface);
}

pub fn componentVirtualScrollTarget(route: []const canvas.WidgetEventRouteEntry) ?canvas.ObjectId {
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

pub fn componentVirtualKeyboardScrollTarget(keyboard: canvas.WidgetKeyboardEvent, direct_target: bool) ?ComponentVirtualKeyboardScrollTarget {
    if (!direct_target) return null;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "home")) return .start;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "end")) return .end;
    return null;
}

pub fn componentVirtualKeyboardScrollDelta(viewport_extent: f32, keyboard: canvas.WidgetKeyboardEvent, direct_target: bool) ?f32 {
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

pub fn snapComponentVirtualScrollOffset(widget: canvas.Widget, current: f32, raw_next: f32, max_offset: f32) f32 {
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

pub fn clampComponentVirtualScrollOffset(raw_next: f32, max_offset: f32, fallback: f32) f32 {
    if (!std.math.isFinite(raw_next)) return fallback;
    return std.math.clamp(@max(0, raw_next), 0, @max(0, max_offset));
}

pub fn componentScrollStatesEqual(a: canvas.ScrollState, b: canvas.ScrollState) bool {
    return a.offset == b.offset and
        a.velocity == b.velocity and
        a.viewport_extent == b.viewport_extent and
        a.content_extent == b.content_extent;
}

pub fn componentFrameIntervalMs(frame_interval_ns: u64) f32 {
    if (frame_interval_ns == 0) return 16;
    const raw = @as(f32, @floatFromInt(frame_interval_ns)) / 1_000_000.0;
    return std.math.clamp(raw, 1, 64);
}

pub fn componentVirtualScrollStep(widget: canvas.Widget) ?f32 {
    if (!widget.layout.virtualized) return null;
    const item_extent = if (widget.layout.virtual_item_extent > 0) widget.layout.virtual_item_extent else return null;
    const step = item_extent + @max(0, widget.layout.gap);
    return if (step > 0) step else null;
}

pub fn componentSizesEqual(a: geometry.SizeF, b: geometry.SizeF) bool {
    return a.width == b.width and a.height == b.height;
}

pub fn buildComponentsDisplayList(builder: *canvas.Builder, layout: canvas.WidgetLayoutTree, tokens: canvas.DesignTokens) canvas.Error!void {
    return buildComponentsDisplayListForSize(builder, layout, tokens, default_canvas_size);
}

pub fn buildComponentsDisplayListForSize(builder: *canvas.Builder, layout: canvas.WidgetLayoutTree, tokens: canvas.DesignTokens, surface_size: geometry.SizeF) canvas.Error!void {
    const size = componentSurfaceSize(surface_size);
    try builder.fillRect(.{ .id = canvas_background_id, .rect = rect(0, 0, size.width, size.height), .fill = .{ .color = tokens.colors.background } });
    // The band carries only the app's real controls (theme strip +
    // refresh): a window never labels itself with its own name.
    try builder.fillRect(.{ .id = canvas_toolbar_id, .rect = rect(0, 0, size.width, toolbar_height), .fill = .{ .color = tokens.colors.surface } });
    try builder.fillRect(.{ .id = canvas_toolbar_separator_id, .rect = rect(0, toolbar_height - 1, size.width, 1), .fill = .{ .color = tokens.colors.border } });
    try layout.emitDisplayList(builder, tokens);
}

pub fn componentTokens() canvas.DesignTokens {
    return componentTokensFor(.light);
}

pub fn componentTokensFor(mode: ComponentThemeMode) canvas.DesignTokens {
    return componentTokensForScale(mode, 1);
}

pub fn componentTokensForScale(mode: ComponentThemeMode, pixel_snap_scale: f32) canvas.DesignTokens {
    return componentTokensForScaleAndMotion(mode, pixel_snap_scale, false);
}

pub fn componentTokensForScaleAndMotion(mode: ComponentThemeMode, pixel_snap_scale: f32, reduce_motion: bool) canvas.DesignTokens {
    return componentTokensForScaleMotionAndContrast(mode, pixel_snap_scale, reduce_motion, false);
}

pub fn componentTokensForScaleMotionAndContrast(mode: ComponentThemeMode, pixel_snap_scale: f32, reduce_motion: bool, high_contrast: bool) canvas.DesignTokens {
    return componentTokensForPackScaleMotionAndContrast(.house, mode, pixel_snap_scale, reduce_motion, high_contrast);
}

/// The catalog tokens under a named theme pack: the same surface tuning
/// (blur, motion, scroll physics, pixel snap) over whichever register
/// the pack resolves — the per-theme reference renders and their pinned
/// signatures build their tokens here so every pack is exercised
/// through one code path.
pub fn componentTokensForPack(pack: canvas.ThemePack, mode: ComponentThemeMode) canvas.DesignTokens {
    return componentTokensForPackScaleMotionAndContrast(pack, mode, 1, false, false);
}

pub fn componentTokensForPackScaleMotionAndContrast(pack: canvas.ThemePack, mode: ComponentThemeMode, pixel_snap_scale: f32, reduce_motion: bool, high_contrast: bool) canvas.DesignTokens {
    var tokens = canvas.DesignTokens.theme(.{
        .color_scheme = switch (mode) {
            .light => .light,
            .dark, .high => .dark,
        },
        .contrast = if (mode == .high or high_contrast) .high else .standard,
        .reduce_motion = reduce_motion,
        .pack = pack,
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

pub fn componentThemeModeForAppearance(appearance: native_sdk.Appearance) ComponentThemeMode {
    return switch (appearance.color_scheme) {
        .light => .light,
        .dark => .dark,
    };
}

pub fn normalizedPixelSnapScale(scale_factor: f32) f32 {
    if (!std.math.isFinite(scale_factor) or scale_factor <= 0) return 1;
    return scale_factor;
}

pub fn transparentContentStyle() canvas.WidgetStyle {
    return .{
        .background = rgba(0, 0, 0, 0),
        .border = rgba(0, 0, 0, 0),
        .radius = 0,
        .stroke_width = 0,
    };
}

pub fn buildComponentsWidgetLayout(nodes: []canvas.WidgetLayoutNode) canvas.Error!canvas.WidgetLayoutTree {
    return buildComponentsWidgetLayoutWithScroll(nodes, .{});
}

pub fn buildComponentsWidgetLayoutWithScroll(nodes: []canvas.WidgetLayoutNode, virtual_scroll: ComponentVirtualScroll) canvas.Error!canvas.WidgetLayoutTree {
    return buildComponentsWidgetLayoutWithScrollAndSize(nodes, virtual_scroll, default_canvas_size);
}

pub fn buildComponentsWidgetLayoutWithScrollAndSize(nodes: []canvas.WidgetLayoutNode, virtual_scroll: ComponentVirtualScroll, surface_size: geometry.SizeF) canvas.Error!canvas.WidgetLayoutTree {
    return buildComponentsWidgetLayoutWithStateAndSize(nodes, virtual_scroll, .{}, surface_size);
}

pub fn componentCatalogItems() [canvas.builtin_component_names.len]canvas.Widget {
    var items: [canvas.builtin_component_names.len]canvas.Widget = undefined;
    for (&items, 0..) |*item, index| {
        item.* = componentCatalogItem(canvas.builtin_component_kinds[index], index);
    }
    return items;
}

pub fn componentCatalogItem(kind: canvas.BuiltinComponentKind, index: usize) canvas.Widget {
    return canvas.builtinComponentWidget(.card, .{
        .id = @as(canvas.ObjectId, @intCast(181 + index)),
        .frame = componentCatalogItemFrame(index),
        .text = canvas.builtinComponentName(kind),
        .state = .{ .selected = index == 0 },
        // Fixed-geometry catalog cards keep the compact 16px inset the
        // preview frames were tuned against (the component default is
        // the component default of 24).
        .layout = .{ .padding = geometry.InsetsF.all(16), .gap = 12, .clip_content = true },
        .semantics = .{ .label = canvas.builtinComponentName(kind) },
        .children = componentCatalogPreviewChildren(kind),
    });
}

pub fn componentCatalogItemFrame(index: usize) geometry.RectF {
    const column = index % catalog_grid_columns;
    const row = index / catalog_grid_columns;
    return rect(
        64 + @as(f32, @floatFromInt(column)) * (catalog_card_width + catalog_card_gap_x),
        124 + @as(f32, @floatFromInt(row)) * (catalog_card_height + catalog_card_gap_y),
        catalog_card_width,
        catalog_card_height,
    );
}

pub fn componentCatalogItemVisible(frame: geometry.RectF, scroll_y: f32, viewport_height: f32) bool {
    const overscan = catalog_card_gap_y;
    const top = @max(0, scroll_y - overscan);
    const bottom = scroll_y + viewport_height + overscan;
    return frame.maxY() >= top and frame.y <= bottom;
}

pub fn componentCatalogPreviewLayout(kind: canvas.BuiltinComponentKind) canvas.WidgetLayoutStyle {
    return switch (kind) {
        .textarea => .{ .min_size = geometry.SizeF.init(0, 28) },
        else => .{},
    };
}

pub fn componentCatalogPreviewChildren(kind: canvas.BuiltinComponentKind) []const canvas.Widget {
    return switch (kind) {
        .accordion => &catalog_accordion_children,
        .alert => &catalog_alert_children,
        .avatar => &catalog_avatar_children,
        .badge => &catalog_badge_children,
        .breadcrumb => &catalog_breadcrumb_children,
        .bubble => &catalog_bubble_children,
        .button => &catalog_button_children,
        .button_group => &catalog_button_group_children,
        .card => &catalog_card_children,
        .checkbox => &catalog_checkbox_children,
        .combobox => &catalog_combobox_children,
        .dialog => &catalog_dialog_children,
        .drawer => &catalog_drawer_children,
        .dropdown_menu => &catalog_dropdown_children,
        .input => &catalog_input_children,
        .pagination => &catalog_pagination_children,
        .progress => &catalog_progress_children,
        .radio_group => &catalog_radio_group_children,
        .resizable => &catalog_resizable_children,
        .select => &catalog_select_children,
        .separator => &catalog_separator_children,
        .sheet => &catalog_sheet_children,
        .skeleton => &catalog_skeleton_children,
        .slider => &catalog_slider_children,
        .spinner => &catalog_spinner_children,
        .switch_control => &catalog_switch_children,
        .table => &catalog_table_children,
        .tabs => &catalog_tabs_children,
        .textarea => &catalog_textarea_children,
        .toggle => &catalog_toggle_children,
        .toggle_group => &catalog_toggle_group_children,
        .tooltip => &catalog_tooltip_children,
    };
}

pub fn componentCatalogGridHeight() f32 {
    const rows = (canvas.builtin_component_names.len + catalog_grid_columns - 1) / catalog_grid_columns;
    return 124 + @as(f32, @floatFromInt(rows)) * catalog_card_height + @as(f32, @floatFromInt(rows - 1)) * catalog_card_gap_y + 64;
}

pub fn componentSectionContentHeight(section: ComponentSection) f32 {
    return switch (section) {
        .controls => 700,
        .inputs => 560,
        .data => 360,
        .components => componentCatalogGridHeight(),
        .surfaces => 520,
    };
}

pub fn surfaceOverlayKind(overlay: ComponentSurfaceOverlay) canvas.BuiltinComponentKind {
    return switch (overlay) {
        .dialog => .dialog,
        .drawer => .drawer,
        .sheet => .sheet,
        .none => unreachable,
    };
}

pub fn surfaceOverlayFrame(surface_size: geometry.SizeF, overlay: ComponentSurfaceOverlay) geometry.RectF {
    return surfaceOverlayFrameForSidebar(surface_size, overlay, canvas_sidebar_width);
}

pub fn surfaceOverlayFrameForSidebar(surface_size: geometry.SizeF, overlay: ComponentSurfaceOverlay, sidebar_width: f32) geometry.RectF {
    _ = sidebar_width;
    const size = componentSurfaceSize(surface_size);
    return canvas.builtinSurfaceFrame(surfaceOverlayKind(overlay), .{
        .bounds = rect(0, componentContentYForSize(size), size.width, componentContentHeightForSize(size)),
        .preferred_size = switch (overlay) {
            .dialog => geometry.SizeF.init(460, 220),
            .drawer => geometry.SizeF.init(size.width, 260),
            .sheet => geometry.SizeF.init(380, componentContentHeightForSize(size)),
            .none => unreachable,
        },
    }).?;
}

pub fn appendComponentWidget(output: []canvas.Widget, count: *usize, widget: canvas.Widget) canvas.Error!void {
    if (count.* >= output.len) return error.WidgetLayoutListFull;
    output[count.*] = widget;
    count.* += 1;
}

pub fn buildComponentsWidgetLayoutWithStateAndSize(nodes: []canvas.WidgetLayoutNode, virtual_scroll: ComponentVirtualScroll, ui_state: ComponentUiState, surface_size: geometry.SizeF) canvas.Error!canvas.WidgetLayoutTree {
    return buildComponentsWidgetLayoutWithStateSizeAndTokens(nodes, virtual_scroll, ui_state, surface_size, componentTokens());
}

/// Layout under an explicit token set — REQUIRED to be the same tokens
/// the display list is emitted with. Layout and render must agree on
/// `pixel_snap`: under geometry snapping, intrinsic label-hugging
/// widths ceil to the snap grid (a grid-aligned width survives the
/// renderer's per-edge rounding at any position), while a layout
/// computed under non-snapping tokens keeps exact fractional widths
/// that render-time edge snapping can shave below the label — eliding
/// text that fits unsnapped. The wrappers above default to the
/// catalog's stock tokens; any caller rendering under other tokens
/// (theme packs, dark scheme, surface scale) must lay out here with
/// those same tokens.
pub fn buildComponentsWidgetLayoutWithStateSizeAndTokens(nodes: []canvas.WidgetLayoutNode, virtual_scroll: ComponentVirtualScroll, ui_state: ComponentUiState, surface_size: geometry.SizeF, tokens: canvas.DesignTokens) canvas.Error!canvas.WidgetLayoutTree {
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
    const segment_controls = [_]canvas.Widget{
        .{ .id = 117, .kind = .segmented_control, .text = "Small", .size = .sm, .state = .{ .selected = true }, .semantics = .{ .label = "Small density" } },
        .{ .id = 119, .kind = .segmented_control, .text = "Large", .size = .lg, .semantics = .{ .label = "Large density" } },
    };
    const radio_controls = [_]canvas.Widget{
        .{ .id = 169, .kind = .radio, .text = "Card", .state = .{ .selected = true }, .semantics = .{ .label = "Card layout" } },
        .{ .id = 170, .kind = .radio, .text = "List", .semantics = .{ .label = "List layout" } },
    };
    const environment_menu_items = [_]canvas.Widget{
        .{ .id = environmentOptionId(0), .kind = .menu_item, .text = environment_options[0], .command = environment_option_commands[0], .state = .{ .selected = ui_state.environment_index == 0 }, .semantics = .{ .label = environment_options[0] } },
        .{ .id = environmentOptionId(1), .kind = .menu_item, .text = environment_options[1], .command = environment_option_commands[1], .state = .{ .selected = ui_state.environment_index == 1 }, .semantics = .{ .label = environment_options[1] } },
        .{ .id = environmentOptionId(2), .kind = .menu_item, .text = environment_options[2], .command = environment_option_commands[2], .state = .{ .selected = ui_state.environment_index == 2 }, .semantics = .{ .label = environment_options[2] } },
    };
    // The house select composition: the trigger and its anchored menu
    // are siblings in a stack, the menu floating below the trigger and
    // stretched to its width, mounted only while the model holds it
    // open — so the engine's open-select keymap (arrows walk in, Enter
    // commits, Escape dismisses back to the trigger) applies as-is.
    const environment_select_trigger = canvas.Widget{ .id = environment_select_id, .kind = .select, .frame = rect(0, 0, 180, 34), .text = environmentLabel(ui_state.environment_index), .command = environment_toggle_command, .state = .{ .expanded = ui_state.environment_select_open }, .semantics = .{ .label = "Environment select" } };
    const environment_closed_children = [_]canvas.Widget{environment_select_trigger};
    const environment_open_children = [_]canvas.Widget{ environment_select_trigger, canvas.builtinComponentWidget(.dropdown_menu, .{
        .id = environment_menu_id,
        // 3 rows on the menu's comfortable 32px band + the surface's
        // 4px padding and 2px gaps.
        .frame = rect(0, 0, 180, 108),
        .layout = .{ .anchor = .{ .placement = .below, .alignment = .stretch } },
        .semantics = .{ .label = "Environment options" },
        .children = &environment_menu_items,
    }) };
    const form_controls = [_]canvas.Widget{
        .{ .id = 111, .kind = .input, .frame = rect(0, 0, 148, 34), .text = "native-sdk", .semantics = .{ .label = "Project name" } },
        .{ .id = 112, .kind = .combobox, .frame = rect(166, 0, 172, 34), .text = "components", .semantics = .{ .label = "Component combobox" } },
        .{ .id = 113, .kind = .checkbox, .frame = rect(0, 52, 132, 30), .text = "Selected", .state = .{ .selected = true }, .semantics = .{ .label = "Selected checkbox" } },
        .{ .id = 114, .kind = .switch_control, .frame = rect(166, 52, 116, 30), .text = "Live", .value = 1, .state = .{ .selected = true }, .semantics = .{ .label = "Live switch" } },
        .{ .id = 215, .kind = .toggle_button, .frame = rect(292, 52, 60, 30), .text = "Bold", .state = .{ .selected = true }, .semantics = .{ .label = "Bold toggle" } },
        .{ .id = 115, .kind = .slider, .frame = rect(0, 108, 176, 28), .value = 0.62, .semantics = .{ .label = "Density slider" } },
        .{ .id = 116, .kind = .progress, .frame = rect(202, 120, 134, 4), .value = 1, .semantics = .{ .label = "Build progress" } },
        .{ .id = 167, .kind = .radio_group, .frame = rect(0, 148, 160, 28), .layout = .{ .gap = 10, .cross_alignment = .center }, .semantics = .{ .label = "Layout radio group" }, .children = &radio_controls },
        // The house TabsList hug: triggers sit 3px inside the container
        // (raw widget trees bypass the builder defaults, so the inset is
        // spelled out) and carry no gap — the selected trigger's corners
        // stay concentric with the container's rounding.
        .{ .id = 168, .kind = .tabs, .frame = rect(0, 200, 148, 34), .layout = .{ .padding = .{ .top = 3, .right = 3, .bottom = 3, .left = 3 } }, .semantics = .{ .label = "Density tabs" }, .children = &segment_controls },
        .{ .id = 171, .kind = .textarea, .frame = rect(0, 246, 336, 72), .text = "Compose a native-rendered message", .semantics = .{ .label = "Message textarea" } },
        .{ .id = environment_stack_id, .kind = .stack, .frame = rect(0, 330, 180, 34), .children = if (ui_state.environment_select_open) &environment_open_children else &environment_closed_children },
    };
    const card_preview_children = [_]canvas.Widget{
        .{ .id = 231, .kind = .badge, .frame = rect(186, 0, 56, 20), .text = "Active", .variant = .secondary, .semantics = .{ .label = "Plan status active" } },
        .{ .id = 232, .kind = .text, .frame = rect(0, 40, 220, 28), .text = "$29 / month", .size = .lg },
        .{ .id = 233, .kind = .text, .frame = rect(0, 72, 220, 20), .text = "8 of 12 seats used", .size = .sm },
        .{ .id = 234, .kind = .progress, .frame = rect(0, 104, 244, 4), .value = 0.67, .semantics = .{ .label = "Seat usage" } },
    };
    const menu_items = [_]canvas.Widget{
        .{ .id = 142, .kind = .menu_item, .text = "Copy invite link" },
        .{ .id = 143, .kind = .menu_item, .text = "Rotate API key" },
        .{ .id = 144, .kind = .menu_item, .text = "Open audit log" },
    };
    const popover_children = [_]canvas.Widget{
        canvas.builtinComponentWidget(.dropdown_menu, .{
            .id = 141,
            // 3 rows on the menu's comfortable 32px band + the
            // surface's 4px padding and 2px gaps.
            .frame = rect(12, 12, 236, 108),
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
    const size = componentSurfaceSize(surface_size);
    const content_y = componentContentYForSize(size);
    const content_height_available = componentContentHeightForSize(size);
    const statusbar_height_available = componentStatusbarHeightForSize(size);
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
            try appendComponentWidget(&content_widgets, &content_widget_count, canvas.builtinComponentWidget(.card, .{ .id = 174, .frame = rect(456, 384, 276, 156), .text = "Team plan", .layout = .{ .padding = geometry.InsetsF.all(16), .gap = 12, .clip_content = true }, .semantics = .{ .label = "Team plan card" }, .children = &card_preview_children }));
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
            for (canvas.builtin_component_kinds, 0..) |kind, index| {
                const item = componentCatalogItem(kind, index);
                if (componentCatalogItemVisible(item.frame, virtual_scroll.page, content_height_available)) {
                    try appendComponentWidget(&content_widgets, &content_widget_count, item);
                }
            }
        },
        .surfaces => {
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 101, .kind = .text, .frame = rect(64, 56, 240, 26), .text = "Surfaces", .size = .lg });
            try appendComponentWidget(&content_widgets, &content_widget_count, canvas.builtinComponentWidget(.card, .{ .id = 174, .frame = rect(64, 124, 276, 156), .text = "Team plan", .layout = .{ .padding = geometry.InsetsF.all(16), .gap = 12, .clip_content = true }, .semantics = .{ .label = "Team plan card" }, .children = &card_preview_children }));
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 140, .kind = .popover, .frame = rect(384, 124, 260, 126), .backdrop_blur_token = .sm, .semantics = .{ .label = "Project actions popover" }, .children = &popover_children });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 175, .kind = .button, .frame = rect(64, 320, 170, 44), .text = "Dialog", .variant = .outline, .command = surface_dialog_command, .semantics = .{ .label = "Open dialog" } });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 176, .kind = .button, .frame = rect(248, 320, 120, 44), .text = "Drawer", .variant = .outline, .command = surface_drawer_command, .semantics = .{ .label = "Open drawer" } });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 177, .kind = .button, .frame = rect(382, 320, 120, 44), .text = "Sheet", .variant = .outline, .command = surface_sheet_command, .semantics = .{ .label = "Open sheet" } });
            try appendComponentWidget(&content_widgets, &content_widget_count, .{ .id = 160, .kind = .tooltip, .frame = rect(64, 416, 176, 32), .text = "Tooltip rendered on GPU", .semantics = .{ .label = "GPU tooltip" } });
        },
    }

    const content_width = @max(1, size.width - sidebar_width);
    const content_height = @max(content_height_available, componentSectionContentHeight(ui_state.section));
    var content_children: [canvas.builtin_component_names.len + 17]canvas.Widget = undefined;
    content_children[0] = .{
        .kind = .stack,
        .frame = rect(0, 0, content_width, content_height),
        .style = transparentContentStyle(),
        .semantics = .{ .hidden = true },
    };
    for (content_widgets[0..content_widget_count], 0..) |widget, index| {
        content_children[index + 1] = widget;
    }
    const theme_triggers = [_]canvas.Widget{
        .{ .id = themeModeTriggerId(.light), .kind = .segmented_control, .text = "Light", .size = .sm, .command = themeModeCommand(.light), .state = .{ .selected = ui_state.theme_mode == .light }, .semantics = .{ .label = "Light theme" } },
        .{ .id = themeModeTriggerId(.dark), .kind = .segmented_control, .text = "Dark", .size = .sm, .command = themeModeCommand(.dark), .state = .{ .selected = ui_state.theme_mode == .dark }, .semantics = .{ .label = "Dark theme" } },
        .{ .id = themeModeTriggerId(.high), .kind = .segmented_control, .text = "High", .size = .sm, .command = themeModeCommand(.high), .state = .{ .selected = ui_state.theme_mode == .high }, .semantics = .{ .label = "High contrast theme" } },
    };
    var root_widgets: [9]canvas.Widget = undefined;
    var root_widget_count: usize = 0;
    // The theme choice is mutually exclusive, so it renders as a REAL
    // segmented strip (the house TabsList hug) whose selected trigger is
    // the active theme — each trigger dispatches its own mode command.
    try appendComponentWidget(&root_widgets, &root_widget_count, .{
        .id = canvas_toolbar_theme_id,
        .kind = .tabs,
        .frame = rect(292, 11, 174, 30),
        .layout = .{ .padding = .{ .top = 3, .right = 3, .bottom = 3, .left = 3 } },
        .semantics = .{ .label = "Theme mode" },
        .children = &theme_triggers,
    });
    try appendComponentWidget(&root_widgets, &root_widget_count, .{
        .id = canvas_toolbar_refresh_id,
        .kind = .button,
        .frame = rect(482, 11, 86, 30),
        .text = "Refresh",
        .variant = .secondary,
        .command = refresh_command,
        .semantics = .{ .label = "Refresh components" },
    });
    try appendComponentWidget(&root_widgets, &root_widget_count, .{
        .id = canvas_sidebar_id,
        .kind = .panel,
        .frame = rect(0, content_y, sidebar_width, content_height_available),
        .style = .{ .radius = 0 },
        .semantics = .{ .label = "Component sections" },
        .children = &sidebar_children,
    });
    try appendComponentWidget(&root_widgets, &root_widget_count, .{
        .id = content_scroll_id,
        .kind = .scroll_view,
        .frame = rect(sidebar_width, content_y, content_width, content_height_available),
        .value = virtual_scroll.page,
        .layout = .{ .clip_content = true },
        .style = transparentContentStyle(),
        .semantics = .{ .label = "Component section content" },
        .children = content_children[0 .. content_widget_count + 1],
    });
    try appendComponentWidget(&root_widgets, &root_widget_count, .{
        .id = canvas_sidebar_resize_line_id,
        .kind = .separator,
        .frame = sidebarResizeLineFrame(sidebar_width, content_height_available),
        .style = .{ .stroke_width = canvas_sidebar_resize_line_width },
    });
    // The invisible grab strip along the sidebar's edge. It is a
    // split_divider, not a slider: the native cursor register keeps
    // sliders on the arrow, while a resizable EDGE advertises itself
    // with the resize cursor — and this strip is an edge (the app reads
    // raw pointer moves in resizeSidebar; no slider value mechanics are
    // involved).
    try appendComponentWidget(&root_widgets, &root_widget_count, .{
        .id = canvas_sidebar_resize_handle_id,
        .kind = .split_divider,
        .frame = sidebarResizeHandleFrame(sidebar_width, content_height_available),
        .opacity = 0,
        .style = .{ .background = rgba(0, 0, 0, 0), .foreground = rgba(0, 0, 0, 0), .border = rgba(0, 0, 0, 0), .radius = 0, .stroke_width = 0 },
        .semantics = .{ .label = "Resize component sidebar" },
    });
    try appendComponentWidget(&root_widgets, &root_widget_count, canvas.builtinStatusBarWidget(.{
        .id = canvas_status_text_id,
        .frame = rect(0, content_y + content_height_available, size.width, statusbar_height_available),
        .text = ui_state.status_text,
        .semantics = .{ .label = ui_state.status_text },
    }));

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
        try appendComponentWidget(&root_widgets, &root_widget_count, canvas.builtinSurfaceBackdropWidget(.{
            .id = surface_overlay_backdrop_id,
            .frame = rect(0, content_y, size.width, content_height_available),
            .layer = surface_backdrop_layer,
        }));
        try appendComponentWidget(&root_widgets, &root_widget_count, canvas.builtinComponentWidget(surfaceOverlayKind(ui_state.surface_overlay), .{
            .id = surface_overlay_id,
            .frame = overlay_frame,
            .layer = surface_overlay_layer,
            .semantics = .{ .label = surfaceOverlayLabel(ui_state.surface_overlay) },
            .children = &surface_overlay_children_storage,
        }));
    }

    return canvas.layoutWidgetTreeWithTokens(.{ .kind = .stack, .children = root_widgets[0..root_widget_count] }, rect(0, 0, size.width, size.height), tokens, nodes);
}

pub fn componentFrame(display_list: canvas.DisplayList, previous: ?canvas.DisplayList, options: canvas.CanvasFrameOptions, storage: canvas.CanvasFrameStorage) canvas.Error!canvas.CanvasFrame {
    return display_list.framePlan(previous, options, storage);
}

pub fn componentFrameStorage(
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

pub fn gpuFrameEvent(frame: native_sdk.platform.GpuFrame) native_sdk.GpuSurfaceFrameEvent {
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

pub fn componentFrameStatus(buffer: []u8, frame_event: native_sdk.GpuSurfaceFrameEvent) std.fmt.BufPrintError![]u8 {
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
