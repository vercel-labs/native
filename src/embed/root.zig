const std = @import("std");
const types = @import("types.zig");
const host = @import("host.zig");
const ui_host = @import("ui_host.zig");
const c_api = @import("c_api.zig");

pub const MobileWidgetRole = types.MobileWidgetRole;
pub const MobileWidgetFlag = types.MobileWidgetFlag;
pub const MobileWidgetAction = types.MobileWidgetAction;
pub const MobileWidgetActionKind = types.MobileWidgetActionKind;
pub const MobileWidgetSemantics = types.MobileWidgetSemantics;
pub const MobileWidgetTextGeometry = types.MobileWidgetTextGeometry;
pub const MobileWidgetActionRequest = types.MobileWidgetActionRequest;
pub const MobileTextInputState = types.MobileTextInputState;
pub const MobileViewportState = types.MobileViewportState;
pub const MobileGpuFrameState = types.MobileGpuFrameState;
pub const MobileCanvasPixels = types.MobileCanvasPixels;
pub const mobile_gpu_surface_label = types.mobile_gpu_surface_label;

pub const EmbeddedApp = host.EmbeddedApp;
pub const MobileHostApp = host.MobileHostApp;
pub const UiAppHost = ui_host.UiAppHost;
pub const mobile_shell_scene = ui_host.mobile_shell_scene;
pub const MobileCApi = c_api.MobileCApi;
pub const exportMobileCApi = c_api.exportMobileCApi;

pub const zero_native_app_create = c_api.zero_native_app_create;
pub const zero_native_app_destroy = c_api.zero_native_app_destroy;
pub const zero_native_app_start = c_api.zero_native_app_start;
pub const zero_native_app_activate = c_api.zero_native_app_activate;
pub const zero_native_app_deactivate = c_api.zero_native_app_deactivate;
pub const zero_native_app_stop = c_api.zero_native_app_stop;
pub const zero_native_app_resize = c_api.zero_native_app_resize;
pub const zero_native_app_viewport = c_api.zero_native_app_viewport;
pub const zero_native_app_viewport_state = c_api.zero_native_app_viewport_state;
pub const zero_native_app_gpu_frame_state = c_api.zero_native_app_gpu_frame_state;
pub const zero_native_app_text_input_state = c_api.zero_native_app_text_input_state;
pub const zero_native_app_set_automation_dir = c_api.zero_native_app_set_automation_dir;
pub const zero_native_app_touch = c_api.zero_native_app_touch;
pub const zero_native_app_scroll = c_api.zero_native_app_scroll;
pub const zero_native_app_key = c_api.zero_native_app_key;
pub const zero_native_app_text = c_api.zero_native_app_text;
pub const zero_native_app_ime = c_api.zero_native_app_ime;
pub const zero_native_app_command = c_api.zero_native_app_command;
pub const zero_native_app_frame = c_api.zero_native_app_frame;
pub const zero_native_app_set_asset_root = c_api.zero_native_app_set_asset_root;
pub const zero_native_app_set_asset_entry = c_api.zero_native_app_set_asset_entry;
pub const zero_native_app_last_command_count = c_api.zero_native_app_last_command_count;
pub const zero_native_app_last_command_name = c_api.zero_native_app_last_command_name;
pub const zero_native_app_last_error_name = c_api.zero_native_app_last_error_name;
pub const zero_native_app_widget_semantics_count = c_api.zero_native_app_widget_semantics_count;
pub const zero_native_app_widget_semantics_at = c_api.zero_native_app_widget_semantics_at;
pub const zero_native_app_widget_semantics_by_id = c_api.zero_native_app_widget_semantics_by_id;
pub const zero_native_app_widget_text_geometry = c_api.zero_native_app_widget_text_geometry;
pub const zero_native_app_widget_action = c_api.zero_native_app_widget_action;
pub const zero_native_app_render_pixel_size = c_api.zero_native_app_render_pixel_size;
pub const zero_native_app_render_pixels = c_api.zero_native_app_render_pixels;

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
