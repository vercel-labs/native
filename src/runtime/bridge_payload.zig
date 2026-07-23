const std = @import("std");
const geometry = @import("geometry");
const json = @import("json");
const platform = @import("../platform/root.zig");

pub fn jsonStringField(payload: []const u8, field: []const u8, storage: *json.StringStorage) ?[]const u8 {
    return json.stringField(payload, field, storage);
}

pub fn webViewWindowIdFromJson(payload: []const u8, default_window_id: platform.WindowId) !platform.WindowId {
    if (json.fieldValue(payload, "windowId") == null) return default_window_id;
    const window_id = jsonIntegerField(payload, "windowId") orelse return error.InvalidWebViewWindowId;
    if (window_id != default_window_id) return error.CrossWindowWebViewDenied;
    return window_id;
}

pub fn viewWindowIdFromJson(payload: []const u8, default_window_id: platform.WindowId) !platform.WindowId {
    if (json.fieldValue(payload, "windowId") == null) return default_window_id;
    const window_id = jsonIntegerField(payload, "windowId") orelse return error.InvalidViewWindowId;
    if (window_id != default_window_id) return error.CrossWindowViewDenied;
    return window_id;
}

pub fn viewKindFromString(value: []const u8) ?platform.ViewKind {
    inline for (@typeInfo(platform.ViewKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @field(platform.ViewKind, field.name);
    }
    if (std.mem.eql(u8, value, "titlebarAccessory")) return .titlebar_accessory;
    if (std.mem.eql(u8, value, "iconButton")) return .icon_button;
    if (std.mem.eql(u8, value, "listItem")) return .list_item;
    if (std.mem.eql(u8, value, "segmentedControl")) return .segmented_control;
    if (std.mem.eql(u8, value, "textField")) return .text_field;
    if (std.mem.eql(u8, value, "searchField")) return .search_field;
    if (std.mem.eql(u8, value, "gpuSurface")) return .gpu_surface;
    if (std.mem.eql(u8, value, "progressIndicator")) return .progress_indicator;
    return null;
}

pub fn gpuSurfaceOptionsFromJson(payload: []const u8, storage: *json.StringStorage) !platform.GpuSurfaceOptions {
    var options = platform.GpuSurfaceOptions{};
    if (jsonStringField(payload, "gpuBackend", storage) orelse jsonStringField(payload, "gpu_backend", storage)) |value| {
        options.backend = gpuSurfaceBackendFromString(value) orelse return error.UnsupportedViewKind;
    }
    if (jsonStringField(payload, "gpuPixelFormat", storage) orelse jsonStringField(payload, "gpu_pixel_format", storage)) |value| {
        options.pixel_format = gpuSurfacePixelFormatFromString(value) orelse return error.UnsupportedViewKind;
    }
    if (jsonStringField(payload, "gpuPresentMode", storage) orelse jsonStringField(payload, "gpu_present_mode", storage)) |value| {
        options.present_mode = gpuSurfacePresentModeFromString(value) orelse return error.UnsupportedViewKind;
    }
    if (jsonStringField(payload, "gpuAlphaMode", storage) orelse jsonStringField(payload, "gpu_alpha_mode", storage)) |value| {
        options.alpha_mode = gpuSurfaceAlphaModeFromString(value) orelse return error.UnsupportedViewKind;
    }
    if (jsonStringField(payload, "gpuColorSpace", storage) orelse jsonStringField(payload, "gpu_color_space", storage)) |value| {
        options.color_space = gpuSurfaceColorSpaceFromString(value) orelse return error.UnsupportedViewKind;
    }
    if (jsonBoolField(payload, "gpuVsync") orelse jsonBoolField(payload, "gpu_vsync")) |value| {
        options.vsync = value;
    }
    return options;
}

fn gpuSurfaceBackendFromString(value: []const u8) ?platform.GpuSurfaceBackend {
    inline for (@typeInfo(platform.GpuSurfaceBackend).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @field(platform.GpuSurfaceBackend, field.name);
    }
    return null;
}

fn gpuSurfacePixelFormatFromString(value: []const u8) ?platform.GpuSurfacePixelFormat {
    inline for (@typeInfo(platform.GpuSurfacePixelFormat).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @field(platform.GpuSurfacePixelFormat, field.name);
    }
    return null;
}

fn gpuSurfacePresentModeFromString(value: []const u8) ?platform.GpuSurfacePresentMode {
    inline for (@typeInfo(platform.GpuSurfacePresentMode).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @field(platform.GpuSurfacePresentMode, field.name);
    }
    return null;
}

fn gpuSurfaceAlphaModeFromString(value: []const u8) ?platform.GpuSurfaceAlphaMode {
    inline for (@typeInfo(platform.GpuSurfaceAlphaMode).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @field(platform.GpuSurfaceAlphaMode, field.name);
    }
    return null;
}

fn gpuSurfaceColorSpaceFromString(value: []const u8) ?platform.GpuSurfaceColorSpace {
    inline for (@typeInfo(platform.GpuSurfaceColorSpace).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @field(platform.GpuSurfaceColorSpace, field.name);
    }
    return null;
}

pub fn platformFeatureFromString(value: []const u8) ?platform.PlatformFeature {
    inline for (@typeInfo(platform.PlatformFeature).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @field(platform.PlatformFeature, field.name);
    }
    if (std.mem.eql(u8, value, "mainWebView")) return .main_webview;
    if (std.mem.eql(u8, value, "childWebViews")) return .child_webviews;
    if (std.mem.eql(u8, value, "nativeViews")) return .native_views;
    if (std.mem.eql(u8, value, "nativeControlCommands")) return .native_control_commands;
    if (std.mem.eql(u8, value, "clipboardText")) return .clipboard_text;
    if (std.mem.eql(u8, value, "clipboardRichData")) return .clipboard_rich_data;
    if (std.mem.eql(u8, value, "openUrl")) return .open_url;
    if (std.mem.eql(u8, value, "revealPath")) return .reveal_path;
    if (std.mem.eql(u8, value, "recentDocuments")) return .recent_documents;
    if (std.mem.eql(u8, value, "fileDrops")) return .file_drops;
    if (std.mem.eql(u8, value, "appActivationEvents")) return .app_activation_events;
    if (std.mem.eql(u8, value, "gpuSurfaces")) return .gpu_surfaces;
    if (std.mem.eql(u8, value, "gpuSurfaceScrollDrivers")) return .gpu_surface_scroll_drivers;
    if (std.mem.eql(u8, value, "contextMenus")) return .context_menus;
    if (std.mem.eql(u8, value, "viewSurfaceAdoption")) return .view_surface_adoption;
    if (std.mem.eql(u8, value, "audioPlayback")) return .audio_playback;
    if (std.mem.eql(u8, value, "audioStreaming")) return .audio_streaming;
    if (std.mem.eql(u8, value, "audioSpectrum")) return .audio_spectrum;
    if (std.mem.eql(u8, value, "windowHideOnClose")) return .window_hide_on_close;
    if (std.mem.eql(u8, value, "videoPlayback")) return .video_playback;
    return null;
}

pub fn viewFrameFromJson(payload: []const u8, required: bool) !?geometry.RectF {
    const frame_payload = json.fieldValue(payload, "frame") orelse {
        if (required) return error.InvalidViewOptions;
        return null;
    };
    const width = jsonNumberField(frame_payload, "width") orelse return error.InvalidViewOptions;
    const height = jsonNumberField(frame_payload, "height") orelse return error.InvalidViewOptions;
    const frame = geometry.RectF.init(
        jsonNumberField(frame_payload, "x") orelse 0,
        jsonNumberField(frame_payload, "y") orelse 0,
        width,
        height,
    );
    if (frame.x < 0 or frame.y < 0 or frame.width < 0 or frame.height < 0) return error.InvalidViewOptions;
    return frame;
}

pub fn viewLayerFromJson(payload: []const u8) !?i32 {
    if (json.fieldValue(payload, "layer") == null) return null;
    const layer_bytes = json.fieldValue(payload, "layer") orelse return error.InvalidViewOptions;
    const layer_value = std.fmt.parseFloat(f64, layer_bytes) catch return error.InvalidViewOptions;
    if (!std.math.isFinite(layer_value)) return error.InvalidViewOptions;
    if (@trunc(layer_value) != layer_value) return error.InvalidViewOptions;
    const max_layer: f64 = @floatFromInt(std.math.maxInt(i32));
    const min_layer: f64 = @floatFromInt(std.math.minInt(i32));
    if (layer_value > max_layer or layer_value < min_layer) return error.InvalidViewOptions;
    return @as(i32, @intFromFloat(layer_value));
}

pub fn webViewFrameFromJson(payload: []const u8) !geometry.RectF {
    const frame_payload = json.fieldValue(payload, "frame") orelse payload;
    const width = jsonNumberField(frame_payload, "width") orelse return error.InvalidWebViewOptions;
    const height = jsonNumberField(frame_payload, "height") orelse return error.InvalidWebViewOptions;
    const frame = geometry.RectF.init(
        jsonNumberField(frame_payload, "x") orelse 0,
        jsonNumberField(frame_payload, "y") orelse 0,
        width,
        height,
    );
    if (frame.x < 0 or frame.y < 0 or frame.width <= 0 or frame.height <= 0) return error.InvalidWebViewOptions;
    return frame;
}

pub fn webViewLayerFromJson(payload: []const u8) !i32 {
    if (json.fieldValue(payload, "layer") == null) return 0;
    const layer_bytes = json.fieldValue(payload, "layer") orelse return error.InvalidWebViewOptions;
    const layer_value = std.fmt.parseFloat(f64, layer_bytes) catch return error.InvalidWebViewOptions;
    if (!std.math.isFinite(layer_value)) return error.InvalidWebViewOptions;
    if (@trunc(layer_value) != layer_value) return error.InvalidWebViewOptions;
    const max_layer: f64 = @floatFromInt(std.math.maxInt(i32));
    const min_layer: f64 = @floatFromInt(std.math.minInt(i32));
    if (layer_value > max_layer or layer_value < min_layer) return error.InvalidWebViewOptions;
    return @as(i32, @intFromFloat(layer_value));
}

pub fn webViewUrlOrigin(url: []const u8, buffer: []u8) ![]const u8 {
    if (std.mem.startsWith(u8, url, "about:")) return "about://local";
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidWebViewOptions;
    const host_start = scheme_end + 3;
    if (host_start >= url.len) return error.InvalidWebViewOptions;
    var host_end = host_start;
    while (host_end < url.len and url[host_end] != '/' and url[host_end] != '?' and url[host_end] != '#') : (host_end += 1) {}
    if (host_end == host_start) return error.InvalidWebViewOptions;
    if (host_end > buffer.len) return error.InvalidWebViewOptions;
    @memcpy(buffer[0..host_end], url[0..host_end]);
    return buffer[0..host_end];
}

pub fn jsonNumberField(payload: []const u8, field: []const u8) ?f32 {
    return json.numberField(payload, field);
}

pub fn jsonIntegerField(payload: []const u8, field: []const u8) ?platform.WindowId {
    return json.unsignedField(platform.WindowId, payload, field);
}

pub fn jsonBoolField(payload: []const u8, field: []const u8) ?bool {
    return json.boolField(payload, field);
}
