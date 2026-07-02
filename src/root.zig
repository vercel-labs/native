pub const geometry = @import("geometry");
pub const assets = @import("assets");
pub const app_dirs = @import("app_dirs");
pub const app_manifest = @import("app_manifest");
pub const trace = @import("trace");
pub const diagnostics = @import("diagnostics");
pub const platform_info = @import("platform_info");
pub const canvas = @import("canvas");

pub const runtime = @import("runtime/root.zig");
pub const platform = @import("platform/root.zig");
pub const window_state = @import("window_state/root.zig");
pub const asset_server = @import("assets/root.zig");
pub const debug = @import("debug/root.zig");
pub const automation = @import("automation/root.zig");
pub const embed = @import("embed/root.zig");
pub const extensions = @import("extensions/root.zig");
pub const js = @import("js/root.zig");
pub const bridge = @import("bridge/root.zig");
pub const frontend = @import("frontend/root.zig");
pub const security = @import("security/root.zig");

pub const Runtime = runtime.Runtime;
pub const RuntimeOptions = runtime.Options;
pub const App = runtime.App;
pub const Event = runtime.Event;
pub const LifecycleEvent = runtime.LifecycleEvent;
pub const Command = runtime.Command;
pub const CommandEvent = runtime.CommandEvent;
pub const CommandSource = runtime.CommandSource;
pub const TestHarness = runtime.TestHarness;
pub const UiApp = runtime.UiApp;
pub const ShellConfig = app_manifest.ShellConfig;
pub const ShellWindow = app_manifest.ShellWindow;
pub const ShellView = app_manifest.ShellView;
pub const ShellEdge = app_manifest.ShellEdge;
pub const ShellAxis = app_manifest.ShellAxis;

pub const WebViewSource = platform.WebViewSource;
pub const WebViewSourceKind = platform.WebViewSourceKind;
pub const WebViewAssetSource = platform.WebViewAssetSource;
pub const WebEngine = platform.WebEngine;
pub const PlatformFeature = platform.PlatformFeature;
pub const ViewKind = platform.ViewKind;
pub const ViewOptions = platform.ViewOptions;
pub const ViewPatch = platform.ViewPatch;
pub const ViewInfo = platform.ViewInfo;
pub const GpuFrame = platform.GpuFrame;
pub const GpuSurfaceOptions = platform.GpuSurfaceOptions;
pub const GpuSurfaceBackend = platform.GpuSurfaceBackend;
pub const GpuSurfacePixelFormat = platform.GpuSurfacePixelFormat;
pub const GpuSurfacePresentMode = platform.GpuSurfacePresentMode;
pub const GpuSurfaceAlphaMode = platform.GpuSurfaceAlphaMode;
pub const GpuSurfaceColorSpace = platform.GpuSurfaceColorSpace;
pub const GpuSurfaceStatus = platform.GpuSurfaceStatus;
pub const CanvasFrameProfileRisk = platform.CanvasFrameProfileRisk;
pub const AppInfo = platform.AppInfo;
pub const Platform = platform.Platform;
pub const NullPlatform = platform.NullPlatform;
pub const WindowId = platform.WindowId;
pub const WindowOptions = platform.WindowOptions;
pub const WindowCreateOptions = platform.WindowCreateOptions;
pub const WindowInfo = platform.WindowInfo;
pub const WindowState = platform.WindowState;
pub const WindowRestorePolicy = platform.WindowRestorePolicy;
pub const Menu = platform.Menu;
pub const MenuItem = platform.MenuItem;
pub const Shortcut = platform.Shortcut;
pub const ShortcutModifiers = platform.ShortcutModifiers;
pub const ShortcutEvent = platform.ShortcutEvent;
pub const ColorScheme = platform.ColorScheme;
pub const Appearance = platform.Appearance;
pub const GpuSurfaceFrameEvent = platform.GpuSurfaceFrameEvent;
pub const GpuSurfaceResizeEvent = platform.GpuSurfaceResizeEvent;
pub const GpuSurfaceInputKind = platform.GpuSurfaceInputKind;
pub const GpuSurfaceInputEvent = platform.GpuSurfaceInputEvent;
pub const FileFilter = platform.FileFilter;
pub const OpenDialogOptions = platform.OpenDialogOptions;
pub const OpenDialogResult = platform.OpenDialogResult;
pub const SaveDialogOptions = platform.SaveDialogOptions;
pub const MessageDialogStyle = platform.MessageDialogStyle;
pub const MessageDialogResult = platform.MessageDialogResult;
pub const MessageDialogOptions = platform.MessageDialogOptions;
pub const TrayItemId = platform.TrayItemId;
pub const TrayOptions = platform.TrayOptions;
pub const TrayMenuItem = platform.TrayMenuItem;
pub const BridgeDispatcher = bridge.Dispatcher;
pub const BridgePolicy = bridge.Policy;
pub const BridgeCommandPolicy = bridge.CommandPolicy;
pub const BridgeHandler = bridge.Handler;
pub const BridgeRegistry = bridge.Registry;
pub const SecurityPolicy = security.Policy;
pub const NavigationPolicy = security.NavigationPolicy;
pub const ExternalLinkPolicy = security.ExternalLinkPolicy;
pub const ExternalLinkAction = security.ExternalLinkAction;

test {
    @import("std").testing.refAllDecls(@This());
}

pub export fn zero_native_app_create() ?*anyopaque {
    return embed.zero_native_app_create();
}

pub export fn zero_native_app_destroy(app: ?*anyopaque) void {
    embed.zero_native_app_destroy(app);
}

pub export fn zero_native_app_start(app: ?*anyopaque) void {
    embed.zero_native_app_start(app);
}

pub export fn zero_native_app_activate(app: ?*anyopaque) void {
    embed.zero_native_app_activate(app);
}

pub export fn zero_native_app_deactivate(app: ?*anyopaque) void {
    embed.zero_native_app_deactivate(app);
}

pub export fn zero_native_app_stop(app: ?*anyopaque) void {
    embed.zero_native_app_stop(app);
}

pub export fn zero_native_app_resize(app: ?*anyopaque, width: f32, height: f32, scale: f32, surface: ?*anyopaque) void {
    embed.zero_native_app_resize(app, width, height, scale, surface);
}

pub export fn zero_native_app_viewport(
    app: ?*anyopaque,
    width: f32,
    height: f32,
    scale: f32,
    surface: ?*anyopaque,
    safe_top: f32,
    safe_right: f32,
    safe_bottom: f32,
    safe_left: f32,
    keyboard_top: f32,
    keyboard_right: f32,
    keyboard_bottom: f32,
    keyboard_left: f32,
) void {
    embed.zero_native_app_viewport(app, width, height, scale, surface, safe_top, safe_right, safe_bottom, safe_left, keyboard_top, keyboard_right, keyboard_bottom, keyboard_left);
}

pub export fn zero_native_app_viewport_state(app: ?*anyopaque, out: ?*embed.MobileViewportState) c_int {
    return embed.zero_native_app_viewport_state(app, out);
}

pub export fn zero_native_app_gpu_frame_state(app: ?*anyopaque, out: ?*embed.MobileGpuFrameState) c_int {
    return embed.zero_native_app_gpu_frame_state(app, out);
}

pub export fn zero_native_app_touch(app: ?*anyopaque, id: u64, phase: c_int, x: f32, y: f32, pressure: f32) void {
    embed.zero_native_app_touch(app, id, phase, x, y, pressure);
}

pub export fn zero_native_app_scroll(app: ?*anyopaque, id: u64, x: f32, y: f32, delta_x: f32, delta_y: f32) void {
    embed.zero_native_app_scroll(app, id, x, y, delta_x, delta_y);
}

pub export fn zero_native_app_key(app: ?*anyopaque, phase: c_int, key: ?[*]const u8, key_len: usize, text: ?[*]const u8, text_len: usize, modifiers_mask: u32) void {
    embed.zero_native_app_key(app, phase, key, key_len, text, text_len, modifiers_mask);
}

pub export fn zero_native_app_text(app: ?*anyopaque, text: ?[*]const u8, len: usize) void {
    embed.zero_native_app_text(app, text, len);
}

pub export fn zero_native_app_ime(app: ?*anyopaque, kind: c_int, text: ?[*]const u8, len: usize, cursor: isize) void {
    embed.zero_native_app_ime(app, kind, text, len, cursor);
}

pub export fn zero_native_app_command(app: ?*anyopaque, name: ?[*]const u8, len: usize) void {
    embed.zero_native_app_command(app, name, len);
}

pub export fn zero_native_app_frame(app: ?*anyopaque) void {
    embed.zero_native_app_frame(app);
}

pub export fn zero_native_app_set_asset_root(app: ?*anyopaque, path: [*]const u8, len: usize) void {
    embed.zero_native_app_set_asset_root(app, path, len);
}

pub export fn zero_native_app_set_asset_entry(app: ?*anyopaque, path: [*]const u8, len: usize) void {
    embed.zero_native_app_set_asset_entry(app, path, len);
}

pub export fn zero_native_app_last_command_count(app: ?*anyopaque) usize {
    return embed.zero_native_app_last_command_count(app);
}

pub export fn zero_native_app_last_command_name(app: ?*anyopaque) [*:0]const u8 {
    return embed.zero_native_app_last_command_name(app);
}

pub export fn zero_native_app_last_error_name(app: ?*anyopaque) [*:0]const u8 {
    return embed.zero_native_app_last_error_name(app);
}

pub export fn zero_native_app_widget_semantics_count(app: ?*anyopaque) usize {
    return embed.zero_native_app_widget_semantics_count(app);
}

pub export fn zero_native_app_widget_semantics_at(app: ?*anyopaque, index: usize, out: ?*embed.MobileWidgetSemantics) c_int {
    return embed.zero_native_app_widget_semantics_at(app, index, out);
}

pub export fn zero_native_app_widget_semantics_by_id(app: ?*anyopaque, id: u64, out: ?*embed.MobileWidgetSemantics) c_int {
    return embed.zero_native_app_widget_semantics_by_id(app, id, out);
}

pub export fn zero_native_app_widget_text_geometry(app: ?*anyopaque, id: u64, out: ?*embed.MobileWidgetTextGeometry) c_int {
    return embed.zero_native_app_widget_text_geometry(app, id, out);
}

pub export fn zero_native_app_widget_action(app: ?*anyopaque, action: ?*const embed.MobileWidgetActionRequest) c_int {
    return embed.zero_native_app_widget_action(app, action);
}
