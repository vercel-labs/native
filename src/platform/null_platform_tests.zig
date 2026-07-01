const std = @import("std");
const geometry = @import("geometry");
const types = @import("types.zig");
const null_backend = @import("null_platform.zig");
const default_gpu_frame_interval_ns = types.default_gpu_frame_interval_ns;
const default_gpu_first_frame_latency_budget_ns = types.default_gpu_first_frame_latency_budget_ns;
const Error = types.Error;
const WebEngine = types.WebEngine;
const PlatformFeature = types.PlatformFeature;
const WebViewSourceKind = types.WebViewSourceKind;
const WebViewAssetSource = types.WebViewAssetSource;
const WebViewSource = types.WebViewSource;
const WindowId = types.WindowId;
const ViewId = types.ViewId;
const max_windows = types.max_windows;
const max_window_label_bytes = types.max_window_label_bytes;
const max_window_title_bytes = types.max_window_title_bytes;
const max_window_source_bytes = types.max_window_source_bytes;
const max_webviews = types.max_webviews;
const max_webview_label_bytes = types.max_webview_label_bytes;
const max_webview_url_bytes = types.max_webview_url_bytes;
const max_external_url_bytes = types.max_external_url_bytes;
const max_reveal_path_bytes = types.max_reveal_path_bytes;
const max_recent_document_path_bytes = types.max_recent_document_path_bytes;
const max_notification_title_bytes = types.max_notification_title_bytes;
const max_notification_subtitle_bytes = types.max_notification_subtitle_bytes;
const max_notification_body_bytes = types.max_notification_body_bytes;
const max_clipboard_mime_type_bytes = types.max_clipboard_mime_type_bytes;
const max_clipboard_data_bytes = types.max_clipboard_data_bytes;
const max_credential_service_bytes = types.max_credential_service_bytes;
const max_credential_account_bytes = types.max_credential_account_bytes;
const max_credential_secret_bytes = types.max_credential_secret_bytes;
const max_tray_items = types.max_tray_items;
const max_tray_icon_path_bytes = types.max_tray_icon_path_bytes;
const max_tray_tooltip_bytes = types.max_tray_tooltip_bytes;
const max_tray_item_label_bytes = types.max_tray_item_label_bytes;
const max_tray_item_command_bytes = types.max_tray_item_command_bytes;
const max_drop_paths_bytes = types.max_drop_paths_bytes;
const max_drop_paths = types.max_drop_paths;
const max_window_event_name_bytes = types.max_window_event_name_bytes;
const max_window_event_detail_bytes = types.max_window_event_detail_bytes;
const max_views = types.max_views;
const max_view_label_bytes = types.max_view_label_bytes;
const max_view_role_bytes = types.max_view_role_bytes;
const max_view_accessibility_label_bytes = types.max_view_accessibility_label_bytes;
const max_view_text_bytes = types.max_view_text_bytes;
const max_view_command_bytes = types.max_view_command_bytes;
const max_menus = types.max_menus;
const max_menu_items = types.max_menu_items;
const max_menu_title_bytes = types.max_menu_title_bytes;
const max_menu_item_label_bytes = types.max_menu_item_label_bytes;
const max_menu_command_bytes = types.max_menu_command_bytes;
const max_menu_key_bytes = types.max_menu_key_bytes;
const max_shortcuts = types.max_shortcuts;
const max_shortcut_id_bytes = types.max_shortcut_id_bytes;
const max_shortcut_key_bytes = types.max_shortcut_key_bytes;
const max_widget_accessibility_nodes = types.max_widget_accessibility_nodes;
const max_gpu_surface_packet_json_bytes = types.max_gpu_surface_packet_json_bytes;
const ShortcutModifiers = types.ShortcutModifiers;
const Shortcut = types.Shortcut;
const ShortcutEvent = types.ShortcutEvent;
const Menu = types.Menu;
const MenuItem = types.MenuItem;
const validateShortcut = types.validateShortcut;
const validateMenus = types.validateMenus;
const validateMenuItem = types.validateMenuItem;
const isValidShortcutKey = types.isValidShortcutKey;
const WindowRestorePolicy = types.WindowRestorePolicy;
const WindowOptions = types.WindowOptions;
const WindowState = types.WindowState;
const WindowInfo = types.WindowInfo;
const WindowCreateOptions = types.WindowCreateOptions;
const WebViewOptions = types.WebViewOptions;
const WebViewInfo = types.WebViewInfo;
const ViewKind = types.ViewKind;
const GpuSurfaceBackend = types.GpuSurfaceBackend;
const GpuSurfacePixelFormat = types.GpuSurfacePixelFormat;
const GpuSurfacePresentMode = types.GpuSurfacePresentMode;
const GpuSurfaceAlphaMode = types.GpuSurfaceAlphaMode;
const GpuSurfaceColorSpace = types.GpuSurfaceColorSpace;
const GpuSurfaceStatus = types.GpuSurfaceStatus;
const CanvasFrameProfileRisk = types.CanvasFrameProfileRisk;
const GpuSurfaceOptions = types.GpuSurfaceOptions;
const ViewOptions = types.ViewOptions;
const ViewPatch = types.ViewPatch;
const Cursor = types.Cursor;
const ViewInfo = types.ViewInfo;
const AppInfo = types.AppInfo;
const Surface = types.Surface;
const BridgeMessage = types.BridgeMessage;
const max_dialog_path_bytes = types.max_dialog_path_bytes;
const max_dialog_paths_bytes = types.max_dialog_paths_bytes;
const max_dialog_title_bytes = types.max_dialog_title_bytes;
const max_dialog_message_bytes = types.max_dialog_message_bytes;
const max_dialog_button_bytes = types.max_dialog_button_bytes;
const max_dialog_filter_name_bytes = types.max_dialog_filter_name_bytes;
const max_dialog_filter_bytes = types.max_dialog_filter_bytes;
const FileFilter = types.FileFilter;
const OpenDialogOptions = types.OpenDialogOptions;
const OpenDialogResult = types.OpenDialogResult;
const SaveDialogOptions = types.SaveDialogOptions;
const MessageDialogStyle = types.MessageDialogStyle;
const MessageDialogResult = types.MessageDialogResult;
const MessageDialogOptions = types.MessageDialogOptions;
const NotificationOptions = types.NotificationOptions;
const CredentialKey = types.CredentialKey;
const Credential = types.Credential;
const TrayItemId = types.TrayItemId;
const TrayOptions = types.TrayOptions;
const TrayMenuItem = types.TrayMenuItem;
const NativeCommandEvent = types.NativeCommandEvent;
const MenuCommandEvent = types.MenuCommandEvent;
const FileDropEvent = types.FileDropEvent;
const GpuFrame = types.GpuFrame;
const GpuSurfaceFrameEvent = types.GpuSurfaceFrameEvent;
const GpuSurfaceResizeEvent = types.GpuSurfaceResizeEvent;
const GpuSurfaceInputKind = types.GpuSurfaceInputKind;
const GpuSurfaceInputEvent = types.GpuSurfaceInputEvent;
const GpuSurfacePixels = types.GpuSurfacePixels;
const GpuSurfacePacket = types.GpuSurfacePacket;
const WidgetAccessibilityRole = types.WidgetAccessibilityRole;
const WidgetAccessibilityActions = types.WidgetAccessibilityActions;
const WidgetAccessibilityTextRange = types.WidgetAccessibilityTextRange;
const WidgetAccessibilityNode = types.WidgetAccessibilityNode;
const WidgetAccessibilitySnapshot = types.WidgetAccessibilitySnapshot;
const WidgetAccessibilityActionKind = types.WidgetAccessibilityActionKind;
const WidgetAccessibilityActionEvent = types.WidgetAccessibilityActionEvent;
const ClipboardData = types.ClipboardData;
const ColorScheme = types.ColorScheme;
const Appearance = types.Appearance;
const Event = types.Event;
const splitDropPaths = types.splitDropPaths;
const EventHandler = types.EventHandler;
const PlatformServices = types.PlatformServices;
const Platform = types.Platform;
const Backend = types.Backend;
const NullPlatform = null_backend.NullPlatform;

test "null platform emits deterministic lifecycle events" {
    const Recorder = struct {
        names: [6][]const u8 = undefined,
        len: usize = 0,

        fn handle(context: *anyopaque, event: Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.names[self.len] = event.name();
            self.len += 1;
        }
    };

    var null_platform = NullPlatform.init(.{});
    var recorder: Recorder = .{};
    try null_platform.platform().run(Recorder.handle, &recorder);

    try std.testing.expectEqual(@as(usize, 6), recorder.len);
    try std.testing.expectEqualStrings("app_start", recorder.names[0]);
    try std.testing.expectEqualStrings("appearance_changed", recorder.names[1]);
    try std.testing.expectEqualStrings("surface_resized", recorder.names[2]);
    try std.testing.expectEqualStrings("window_frame_changed", recorder.names[3]);
    try std.testing.expectEqualStrings("frame_requested", recorder.names[4]);
    try std.testing.expectEqualStrings("app_shutdown", recorder.names[5]);
}

test "null platform records loaded webview source" {
    var null_platform = NullPlatform.initWithOptions(.{}, .chromium, .{ .app_name = "Demo", .window_title = "Demo Window" });
    try null_platform.platform().services.loadWebView(WebViewSource.html("<h1>Hello</h1>"));

    try std.testing.expectEqual(WebEngine.chromium, null_platform.web_engine);
    try std.testing.expectEqualStrings("Demo Window", null_platform.app_info.resolvedWindowTitle());
    try std.testing.expectEqual(WebViewSourceKind.html, null_platform.loaded_source.?.kind);
    try std.testing.expectEqualStrings("<h1>Hello</h1>", null_platform.loaded_source.?.bytes);
}

test "null platform records bridge response window routing" {
    var null_platform = NullPlatform.init(.{});
    try null_platform.platform().services.completeWindowBridge(7, "{\"ok\":true}");

    try std.testing.expectEqual(@as(WindowId, 7), null_platform.lastBridgeResponseWindowId());
    try std.testing.expectEqualStrings("{\"ok\":true}", null_platform.lastBridgeResponse());
}

test "null platform records OS actions" {
    var null_platform = NullPlatform.init(.{});
    const services = null_platform.platform().services;

    try services.showNotification(.{
        .title = "Build finished",
        .subtitle = "zero-native",
        .body = "All checks passed.",
    });
    try services.openExternalUrl("https://example.com/docs");
    try services.revealPath("/tmp/example.txt");
    try services.addRecentDocument("/tmp/recent.txt");
    try services.writeClipboard("plain text");
    try services.setCredential(.{ .service = "dev.zero-native.test", .account = "alice", .secret = "secret-token" });
    try services.createTray(.{
        .icon_path = "/tmp/tray.png",
        .tooltip = "zero-native",
        .items = &.{
            .{ .id = 1, .label = "Open" },
            .{ .separator = true },
            .{ .id = 2, .label = "Quit", .enabled = false },
        },
    });

    try std.testing.expectEqual(@as(usize, 1), null_platform.notificationCount());
    try std.testing.expectEqualStrings("Build finished", null_platform.lastNotificationTitle());
    try std.testing.expectEqualStrings("zero-native", null_platform.lastNotificationSubtitle());
    try std.testing.expectEqualStrings("All checks passed.", null_platform.lastNotificationBody());
    try std.testing.expectEqualStrings("https://example.com/docs", null_platform.lastExternalUrl());
    try std.testing.expectEqualStrings("/tmp/example.txt", null_platform.lastRevealedPath());
    try std.testing.expectEqualStrings("/tmp/recent.txt", null_platform.lastRecentDocumentPath());
    try std.testing.expectEqual(@as(usize, 1), null_platform.clipboardWriteCount());
    try std.testing.expectEqualStrings("text/plain", null_platform.lastClipboardMimeType());
    try std.testing.expectEqualStrings("plain text", null_platform.lastClipboardData());
    var clipboard_buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("plain text", try services.readClipboard(&clipboard_buffer));

    try services.writeClipboardData(.{ .mime_type = "text/html", .bytes = "<strong>bold</strong>" });
    try std.testing.expectEqual(@as(usize, 2), null_platform.clipboardWriteCount());
    try std.testing.expectEqualStrings("text/html", null_platform.lastClipboardMimeType());
    try std.testing.expectEqualStrings("<strong>bold</strong>", try services.readClipboardData("text/html", &clipboard_buffer));
    try std.testing.expectError(error.UnsupportedService, services.readClipboardData("text/plain", &clipboard_buffer));

    try std.testing.expectEqual(@as(usize, 1), null_platform.credentialSetCount());
    try std.testing.expectEqualStrings("dev.zero-native.test", null_platform.lastCredentialService());
    try std.testing.expectEqualStrings("alice", null_platform.lastCredentialAccount());
    try std.testing.expectEqualStrings("secret-token", null_platform.lastCredentialSecret());
    try std.testing.expectEqual(@as(usize, 1), null_platform.trayCreateCount());
    try std.testing.expectEqualStrings("/tmp/tray.png", null_platform.lastTrayIconPath());
    try std.testing.expectEqualStrings("zero-native", null_platform.lastTrayTooltip());
    try std.testing.expectEqual(@as(usize, 3), null_platform.trayItems().len);
    try std.testing.expectEqual(@as(TrayItemId, 1), null_platform.trayItems()[0].id);
    try std.testing.expectEqualStrings("Open", null_platform.trayItems()[0].label);
    try std.testing.expect(null_platform.trayItems()[1].separator);
    try std.testing.expectEqual(@as(TrayItemId, 2), null_platform.trayItems()[2].id);
    try std.testing.expect(!null_platform.trayItems()[2].enabled);

    var credential_buffer: [64]u8 = undefined;
    const secret = try services.getCredential(.{ .service = "dev.zero-native.test", .account = "alice" }, &credential_buffer);
    try std.testing.expectEqualStrings("secret-token", secret);
    try std.testing.expectError(error.CredentialNotFound, services.getCredential(.{ .service = "dev.zero-native.test", .account = "bob" }, &credential_buffer));
    try services.deleteCredential(.{ .service = "dev.zero-native.test", .account = "alice" });
    try std.testing.expectEqual(@as(usize, 1), null_platform.credentialDeleteCount());
    try std.testing.expectError(error.CredentialNotFound, services.getCredential(.{ .service = "dev.zero-native.test", .account = "alice" }, &credential_buffer));

    try services.clearRecentDocuments();
    try std.testing.expectEqual(@as(usize, 1), null_platform.recentDocumentsClearedCount());
    try std.testing.expectEqualStrings("", null_platform.lastRecentDocumentPath());

    try services.updateTrayMenu(&.{.{ .id = 3, .label = "Settings" }});
    try std.testing.expectEqual(@as(usize, 2), null_platform.trayUpdateCount());
    try std.testing.expectEqual(@as(usize, 1), null_platform.trayItems().len);
    try std.testing.expectEqualStrings("Settings", null_platform.trayItems()[0].label);
    try services.removeTray();
    try std.testing.expectEqual(@as(usize, 1), null_platform.trayRemoveCount());
    try std.testing.expectEqual(@as(usize, 0), null_platform.trayItems().len);
}

test "null platform records configured shortcuts" {
    const shortcuts = [_]Shortcut{
        .{ .id = "command.palette", .key = "p", .modifiers = .{ .primary = true, .shift = true } },
    };
    var null_platform = NullPlatform.init(.{});
    try null_platform.platform().services.configureShortcuts(&shortcuts);

    try std.testing.expectEqual(@as(usize, 1), null_platform.configuredShortcuts().len);
    try std.testing.expectEqualStrings("command.palette", null_platform.configuredShortcuts()[0].id);
    try std.testing.expect(null_platform.configuredShortcuts()[0].modifiers.primary);
    try std.testing.expect(null_platform.configuredShortcuts()[0].modifiers.shift);

    const long_key = [_]u8{'x'} ** (max_shortcut_key_bytes + 1);
    const invalid = [_]Shortcut{.{ .id = "invalid", .key = long_key[0..] }};
    try std.testing.expectError(error.InvalidShortcut, null_platform.platform().services.configureShortcuts(&invalid));

    const invalid_key = [_]Shortcut{.{ .id = "invalid", .key = "@" }};
    try std.testing.expectError(error.InvalidShortcut, null_platform.platform().services.configureShortcuts(&invalid_key));

    const unmodified_text_key = [_]Shortcut{.{ .id = "text", .key = "p" }};
    try std.testing.expectError(error.InvalidShortcut, null_platform.platform().services.configureShortcuts(&unmodified_text_key));
}

test "null platform records configured menus" {
    const items = [_]MenuItem{
        .{ .label = "Refresh", .command = "app.refresh", .key = "r", .modifiers = .{ .primary = true } },
        .{ .separator = true },
        .{ .label = "Command Palette", .command = "app.palette", .key = "p", .modifiers = .{ .primary = true, .shift = true } },
    };
    const menus = [_]Menu{.{ .title = "App", .items = &items }};
    var null_platform = NullPlatform.init(.{});
    try null_platform.platform().services.configureMenus(&menus);

    try std.testing.expectEqual(@as(usize, 1), null_platform.configuredMenus().len);
    try std.testing.expectEqualStrings("App", null_platform.configuredMenus()[0].title);
    try std.testing.expectEqual(@as(usize, 3), null_platform.configuredMenus()[0].items.len);
    try std.testing.expectEqualStrings("app.refresh", null_platform.configuredMenus()[0].items[0].command);
    try std.testing.expect(null_platform.configuredMenus()[0].items[1].separator);

    const invalid_item = [_]MenuItem{.{ .label = "Missing Command" }};
    const invalid_menu = [_]Menu{.{ .title = "Invalid", .items = &invalid_item }};
    try std.testing.expectError(error.InvalidCommand, null_platform.platform().services.configureMenus(&invalid_menu));

    const unmodified_key_item = [_]MenuItem{.{ .label = "Refresh", .command = "app.refresh", .key = "r" }};
    const unmodified_key_menu = [_]Menu{.{ .title = "Invalid", .items = &unmodified_key_item }};
    try std.testing.expectError(error.InvalidShortcut, null_platform.platform().services.configureMenus(&unmodified_key_menu));
}

test "webview bridge fallback only routes main responses" {
    const Recorder = struct {
        window_id: WindowId = 0,
        response: []const u8 = "",

        fn completeWindow(context: ?*anyopaque, window_id: WindowId, response: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.window_id = window_id;
            self.response = response;
        }
    };

    var recorder: Recorder = .{};
    const services = PlatformServices{
        .context = &recorder,
        .complete_window_bridge_fn = Recorder.completeWindow,
    };

    try services.completeWebViewBridge(3, "main", "{\"ok\":true}");
    try std.testing.expectEqual(@as(WindowId, 3), recorder.window_id);
    try std.testing.expectEqualStrings("{\"ok\":true}", recorder.response);
    try std.testing.expectError(error.UnsupportedService, services.completeWebViewBridge(3, "preview", "{\"ok\":true}"));
}

test "shortcut configuration requires backend support for non-empty lists" {
    const services = PlatformServices{};
    try services.configureShortcuts(&.{});

    const shortcuts = [_]Shortcut{
        .{ .id = "command.palette", .key = "p", .modifiers = .{ .primary = true } },
    };
    try std.testing.expectError(error.UnsupportedService, services.configureShortcuts(&shortcuts));
}

test "OS actions require backend support" {
    const services = PlatformServices{};

    try std.testing.expectError(error.UnsupportedService, services.showNotification(.{ .title = "Hello" }));
    try std.testing.expectError(error.UnsupportedService, services.openExternalUrl("https://example.com"));
    try std.testing.expectError(error.UnsupportedService, services.revealPath("/tmp/example.txt"));
    try std.testing.expectError(error.UnsupportedService, services.addRecentDocument("/tmp/example.txt"));
    try std.testing.expectError(error.UnsupportedService, services.clearRecentDocuments());
    var buffer: [32]u8 = undefined;
    try std.testing.expectError(error.UnsupportedService, services.readClipboard(&buffer));
    try std.testing.expectError(error.UnsupportedService, services.writeClipboard("plain"));
    try std.testing.expectError(error.UnsupportedService, services.readClipboardData("text/html", &buffer));
    try std.testing.expectError(error.UnsupportedService, services.writeClipboardData(.{ .mime_type = "text/html", .bytes = "<b>x</b>" }));
    try std.testing.expectError(error.UnsupportedService, services.setCredential(.{ .service = "service", .account = "account", .secret = "secret" }));
    try std.testing.expectError(error.UnsupportedService, services.getCredential(.{ .service = "service", .account = "account" }, &buffer));
    try std.testing.expectError(error.UnsupportedService, services.deleteCredential(.{ .service = "service", .account = "account" }));
}

test "null platform records webview lifecycle" {
    var null_platform = NullPlatform.init(.{});
    const services = null_platform.platform().services;

    try services.createWebView(.{
        .label = "preview",
        .url = "https://example.com",
        .frame = geometry.RectF.init(10, 20, 300, 200),
    });
    try std.testing.expectEqual(@as(usize, 1), null_platform.webview_count);
    try std.testing.expectEqualStrings("preview", null_platform.webviews[0].label);
    try std.testing.expectError(error.DuplicateWebViewLabel, services.createWebView(.{
        .label = "preview",
        .url = "https://example.org",
        .frame = geometry.RectF.init(10, 20, 300, 200),
    }));

    try services.setWebViewFrame(1, "preview", geometry.RectF.init(11, 22, 333, 222));
    try std.testing.expectEqual(@as(f32, 333), null_platform.webviews[0].frame.width);
    try services.navigateWebView(1, "preview", "https://example.org");
    try std.testing.expectEqualStrings("https://example.org", null_platform.webviews[0].url);
    try services.closeWebView(1, "preview");
    try std.testing.expectEqual(@as(usize, 0), null_platform.webview_count);
}

test "null platform rejects invalid native view parents" {
    var null_platform = NullPlatform.init(.{});
    const services = null_platform.platform().services;

    try std.testing.expectError(error.ViewNotFound, services.createView(.{
        .label = "orphan",
        .kind = .button,
        .parent = "missing",
        .frame = geometry.RectF.init(0, 0, 96, 32),
    }));
    try std.testing.expectError(error.InvalidViewOptions, services.createView(.{
        .label = "self",
        .kind = .stack,
        .parent = "self",
        .frame = geometry.RectF.init(0, 0, 120, 80),
    }));
    try std.testing.expectEqual(@as(usize, 0), null_platform.view_count);

    try services.createView(.{
        .label = "toolbar",
        .kind = .toolbar,
        .frame = geometry.RectF.init(0, 0, 640, 44),
    });
    try services.createView(.{
        .label = "action",
        .kind = .button,
        .parent = "toolbar",
        .frame = geometry.RectF.init(8, 8, 96, 32),
    });
    try std.testing.expectEqual(@as(usize, 2), null_platform.view_count);
    try std.testing.expectEqualStrings("toolbar", null_platform.views[1].parent.?);
}

test "null platform records gpu surface pixel presentation" {
    var null_platform = NullPlatform.init(.{});
    null_platform.gpu_surfaces = true;
    const services = null_platform.platform().services;

    try services.createView(.{
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 180),
    });
    const pixels = [_]u8{
        12, 34, 56, 255,
        78, 90, 12, 255,
    };
    try services.presentGpuSurfacePixels(.{
        .label = "canvas",
        .width = 2,
        .height = 1,
        .scale_factor = 2,
        .dirty_bounds = geometry.RectF.init(0.5, 0, 0.5, 0.5),
        .rgba8 = &pixels,
    });

    try std.testing.expectEqual(@as(usize, 1), null_platform.gpu_surface_present_count);
    try std.testing.expectEqualStrings("canvas", null_platform.gpu_surface_present_label_storage[0..null_platform.gpu_surface_present_label_len]);
    try std.testing.expectEqual(@as(usize, 2), null_platform.gpu_surface_present_width);
    try std.testing.expectEqual(@as(usize, 1), null_platform.gpu_surface_present_height);
    try std.testing.expectEqual(@as(f32, 2), null_platform.gpu_surface_present_scale_factor);
    try std.testing.expectEqualDeep(geometry.RectF.init(0.5, 0, 0.5, 0.5), null_platform.gpu_surface_present_dirty_bounds.?);
    try std.testing.expectEqual(@as(usize, pixels.len), null_platform.gpu_surface_present_byte_len);
    try std.testing.expectEqualDeep([4]u8{ 12, 34, 56, 255 }, null_platform.gpu_surface_present_sample_rgba);
    try std.testing.expectError(error.InvalidGpuSurfacePixels, services.presentGpuSurfacePixels(.{
        .label = "canvas",
        .width = 2,
        .height = 1,
        .rgba8 = pixels[0..4],
    }));
}

test "null platform records gpu surface packet presentation" {
    var null_platform = NullPlatform.init(.{});
    null_platform.gpu_surfaces = true;
    const services = null_platform.platform().services;

    try services.createView(.{
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 180),
    });

    const packet_json =
        \\{"frame":7,"commands":[{"kind":"fill_rect_solid"}]}
    ;
    try services.presentGpuSurfacePacket(.{
        .label = "canvas",
        .frame_index = 7,
        .timestamp_ns = 42_000,
        .surface_size = geometry.SizeF.init(320, 180),
        .scale_factor = 2,
        .clear_color_rgba8 = .{ 247, 249, 252, 255 },
        .requires_render = true,
        .command_count = 1,
        .cache_action_count = 2,
        .cached_resource_command_count = 1,
        .unsupported_command_count = 0,
        .representable = true,
        .json = packet_json,
    });

    try std.testing.expectEqual(@as(usize, 1), null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqualStrings("canvas", null_platform.gpu_surface_packet_present_label_storage[0..null_platform.gpu_surface_packet_present_label_len]);
    try std.testing.expectEqual(@as(u64, 7), null_platform.gpu_surface_packet_present_frame_index);
    try std.testing.expectEqual(@as(u64, 42_000), null_platform.gpu_surface_packet_present_timestamp_ns);
    try std.testing.expectEqualDeep(geometry.SizeF.init(320, 180), null_platform.gpu_surface_packet_present_surface_size);
    try std.testing.expectEqual(@as(f32, 2), null_platform.gpu_surface_packet_present_scale_factor);
    try std.testing.expectEqualDeep([4]u8{ 247, 249, 252, 255 }, null_platform.gpu_surface_packet_present_clear_color_rgba8);
    try std.testing.expect(null_platform.gpu_surface_packet_present_requires_render);
    try std.testing.expectEqual(@as(usize, 1), null_platform.gpu_surface_packet_present_command_count);
    try std.testing.expectEqual(@as(usize, 2), null_platform.gpu_surface_packet_present_cache_action_count);
    try std.testing.expectEqual(@as(usize, 1), null_platform.gpu_surface_packet_present_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), null_platform.gpu_surface_packet_present_unsupported_command_count);
    try std.testing.expect(null_platform.gpu_surface_packet_present_representable);
    try std.testing.expectEqual(@as(usize, packet_json.len), null_platform.gpu_surface_packet_present_json_len);
    try std.testing.expectError(error.InvalidGpuSurfacePacket, services.presentGpuSurfacePacket(.{
        .label = "canvas",
        .json = "",
    }));
}

test "null platform preserves shifted webview storage after close" {
    var null_platform = NullPlatform.init(.{});
    const services = null_platform.platform().services;

    try services.createWebView(.{
        .label = "first",
        .url = "https://example.com/first",
        .frame = geometry.RectF.init(10, 20, 300, 200),
    });
    try services.createWebView(.{
        .label = "second",
        .url = "https://example.com/second",
        .frame = geometry.RectF.init(10, 20, 300, 200),
    });

    try services.closeWebView(1, "first");
    try std.testing.expectEqual(@as(usize, 1), null_platform.webview_count);
    try std.testing.expectEqualStrings("second", null_platform.webviews[0].label);
    try std.testing.expectEqualStrings("https://example.com/second", null_platform.webviews[0].url);

    try services.createWebView(.{
        .label = "third",
        .url = "https://example.com/third",
        .frame = geometry.RectF.init(10, 20, 300, 200),
    });
    try std.testing.expectEqualStrings("second", null_platform.webviews[0].label);
    try std.testing.expectEqualStrings("https://example.com/second", null_platform.webviews[0].url);
    try std.testing.expectEqualStrings("third", null_platform.webviews[1].label);
    try std.testing.expectEqualStrings("https://example.com/third", null_platform.webviews[1].url);
}

test "null platform requires an open main window for main webview operations" {
    var null_platform = NullPlatform.init(.{});
    const services = null_platform.platform().services;

    try std.testing.expectError(error.WindowNotFound, services.setWebViewFrame(1, "main", geometry.RectF.init(0, 0, 320, 240)));
    try std.testing.expectError(error.WindowNotFound, services.setWebViewZoom(1, "main", 1.25));
    try std.testing.expectError(error.WindowNotFound, services.setWebViewLayer(1, "main", 10));

    _ = try services.createWindow(.{ .id = 1, .label = "main" });
    try services.setWebViewFrame(1, "main", geometry.RectF.init(0, 0, 320, 240));
    try services.setWebViewZoom(1, "main", 1.25);
    try services.setWebViewLayer(1, "main", 10);
}

test "webview asset source records production bundle options" {
    const source = WebViewSource.assets(.{ .root_path = "dist", .entry = "index.html" });

    try std.testing.expectEqual(WebViewSourceKind.assets, source.kind);
    try std.testing.expectEqualStrings("zero://app", source.bytes);
    try std.testing.expectEqualStrings("dist", source.asset_options.?.root_path);
    try std.testing.expect(source.asset_options.?.spa_fallback);
}

test "file drop path splitter preserves embedded newlines" {
    var output: [max_drop_paths][]const u8 = undefined;
    const paths = splitDropPaths("/tmp/one\nname.txt\x00/tmp/two.txt", output[0..]);

    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("/tmp/one\nname.txt", paths[0]);
    try std.testing.expectEqualStrings("/tmp/two.txt", paths[1]);
}
