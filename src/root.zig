pub const geometry = @import("geometry");
pub const assets = @import("assets");
pub const app_dirs = @import("app_dirs");
pub const app_manifest = @import("app_manifest");
pub const trace = @import("trace");
pub const diagnostics = @import("diagnostics");
pub const platform_info = @import("platform_info");

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
pub const CommandEvent = runtime.CommandEvent;
pub const TestHarness = runtime.TestHarness;

pub const WebViewSource = platform.WebViewSource;
pub const WebViewSourceKind = platform.WebViewSourceKind;
pub const WebViewAssetSource = platform.WebViewAssetSource;
pub const WebEngine = platform.WebEngine;
pub const AppInfo = platform.AppInfo;
pub const Platform = platform.Platform;
pub const NullPlatform = platform.NullPlatform;
pub const WindowId = platform.WindowId;
pub const WindowOptions = platform.WindowOptions;
pub const WindowCreateOptions = platform.WindowCreateOptions;
pub const WindowInfo = platform.WindowInfo;
pub const WindowState = platform.WindowState;
pub const WindowRestorePolicy = platform.WindowRestorePolicy;
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
pub const BridgeResourceRegistry = bridge.resources.Registry;
pub const BridgeResourceOptions = bridge.resources.Options;
pub const BridgeResourceDescriptor = bridge.resources.Descriptor;
pub const BridgeResourceStreamProvider = bridge.resources.StreamProvider;
pub const BridgeResourceCloseReason = bridge.resources.CloseReason;
pub const BridgeResourceDefaultTtlNs = bridge.resources.default_ttl_ns;
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

pub export fn zero_native_app_stop(app: ?*anyopaque) void {
    embed.zero_native_app_stop(app);
}

pub export fn zero_native_app_resize(app: ?*anyopaque, width: f32, height: f32, scale: f32, surface: ?*anyopaque) void {
    embed.zero_native_app_resize(app, width, height, scale, surface);
}

pub export fn zero_native_app_touch(app: ?*anyopaque, id: u64, phase: c_int, x: f32, y: f32, pressure: f32) void {
    embed.zero_native_app_touch(app, id, phase, x, y, pressure);
}

pub export fn zero_native_app_frame(app: ?*anyopaque) void {
    embed.zero_native_app_frame(app);
}

pub export fn zero_native_app_set_asset_root(app: ?*anyopaque, path: [*]const u8, len: usize) void {
    embed.zero_native_app_set_asset_root(app, path, len);
}

pub export fn zero_native_app_last_command_count(app: ?*anyopaque) usize {
    return embed.zero_native_app_last_command_count(app);
}

pub export fn zero_native_app_last_error_name(app: ?*anyopaque) [*:0]const u8 {
    return embed.zero_native_app_last_error_name(app);
}
