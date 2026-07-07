const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const app_permissions = [_][]const u8{native_sdk.security.permission_window};
const bridge_origins = [_][]const u8{"zero://app"};
const window_permission = [_][]const u8{native_sdk.security.permission_window};
const builtin_policies = [_]native_sdk.BridgeCommandPolicy{
    .{ .name = "native-sdk.window.list", .permissions = &window_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.webview.create", .permissions = &window_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.webview.list", .permissions = &window_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.webview.setFrame", .permissions = &window_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.webview.navigate", .permissions = &window_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.webview.setZoom", .permissions = &window_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.webview.setLayer", .permissions = &window_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.webview.close", .permissions = &window_permission, .origins = &bridge_origins },
};

const BrowserApp = struct {
    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "browser",
            .source = native_sdk.frontend.productionSource(.{
                .dist = "frontend",
                .entry = "index.html",
                .origin = "zero://app",
                .spa_fallback = false,
            }),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var app = BrowserApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "Zero Browser",
        .window_title = "Zero Browser",
        .bundle_id = "dev.native_sdk.browser",
        .builtin_bridge = .{ .enabled = true, .commands = &builtin_policies },
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{
                .allowed_origins = &.{"*"},
                .external_links = .{ .action = .deny },
            },
        },
    }, init);
}

test "browser app serves static frontend assets" {
    var state = BrowserApp{};
    const app = state.app();
    try std.testing.expectEqualStrings("browser", app.name);
    try std.testing.expectEqual(native_sdk.WebViewSourceKind.assets, app.source.kind);
    try std.testing.expectEqualStrings("frontend", app.source.asset_options.?.root_path);
    try std.testing.expectEqualStrings("index.html", app.source.asset_options.?.entry);
}
