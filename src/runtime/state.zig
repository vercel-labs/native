const geometry = @import("geometry");
const platform = @import("../platform/root.zig");

pub const RuntimeSourceStorage = struct {
    bytes: [platform.max_window_source_bytes]u8 = undefined,
    asset_root_path: [platform.max_window_source_bytes]u8 = undefined,
    asset_entry: [platform.max_window_source_bytes]u8 = undefined,
    asset_origin: [platform.max_window_source_bytes]u8 = undefined,
};

pub fn copySourceInto(storage: *RuntimeSourceStorage, source: platform.WebViewSource) !platform.WebViewSource {
    var copied = source;
    copied.bytes = try copyWindowSourceField(&storage.bytes, source.bytes);
    if (source.asset_options) |assets| {
        copied.asset_options = .{
            .root_path = try copyWindowSourceField(&storage.asset_root_path, assets.root_path),
            .entry = try copyWindowSourceField(&storage.asset_entry, assets.entry),
            .origin = try copyWindowSourceField(&storage.asset_origin, assets.origin),
            .spa_fallback = assets.spa_fallback,
        };
    }
    return copied;
}

pub const RuntimeWindow = struct {
    info: platform.WindowInfo = .{},
    main_view_id: platform.ViewId = 0,
    source: ?platform.WebViewSource = null,
    source_reloads_from_app: bool = false,
    main_frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    main_frame_set: bool = false,
    main_layer: i32 = 0,
    main_parent: ?[]const u8 = null,
    main_zoom: f64 = 1.0,
    main_focused: bool = false,
    label_storage: [platform.max_window_label_bytes]u8 = undefined,
    title_storage: [platform.max_window_title_bytes]u8 = undefined,
    main_parent_storage: [platform.max_view_label_bytes]u8 = undefined,
    source_storage: RuntimeSourceStorage = .{},
};

pub const RuntimeMainWebViewState = struct {
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    frame_set: bool = false,
    layer: i32 = 0,
    parent: ?[]const u8 = null,
    parent_storage: [platform.max_view_label_bytes]u8 = undefined,
};

pub const RuntimeWebView = struct {
    id: platform.ViewId = 0,
    window_id: platform.WindowId = 1,
    label: []const u8 = "",
    parent: ?[]const u8 = null,
    url: []const u8 = "",
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    local_frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    zoom: f64 = 1.0,
    transparent: bool = false,
    bridge_enabled: bool = false,
    focused: bool = false,
    open: bool = false,
    label_storage: [platform.max_webview_label_bytes]u8 = undefined,
    parent_storage: [platform.max_view_label_bytes]u8 = undefined,
    url_storage: [platform.max_webview_url_bytes]u8 = undefined,
};

pub const RuntimeTrayItem = struct {
    id: platform.TrayItemId = 0,
    command: []const u8 = "",
    command_storage: [platform.max_tray_item_command_bytes]u8 = undefined,
};

pub const ShellApplyMode = enum {
    create,
    update,
};

pub const WindowSourcePolicy = enum {
    require_source,
    allow_source_less,
};

pub const FocusTraversalDirection = enum {
    next,
    previous,
};

pub fn sourceWebViewUrl(source: ?platform.WebViewSource) []const u8 {
    const value = source orelse return "";
    return switch (value.kind) {
        .html => "zero://inline",
        .url, .assets => value.bytes,
    };
}

fn copyWindowSourceField(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.WindowSourceTooLarge;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}
