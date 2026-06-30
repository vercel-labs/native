const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");
const app_manifest = @import("app_manifest_zon");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const manifest_file_associations = if (@hasField(@TypeOf(app_manifest), "file_associations")) app_manifest.file_associations else .{};
const manifest_url_schemes = if (@hasField(@TypeOf(app_manifest), "url_schemes")) app_manifest.url_schemes else .{};

const window_width: f32 = 900;
const window_height: f32 = 620;
const statusbar_height: f32 = 34;

const html =
    \\<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    \\<meta http-equiv="Content-Security-Policy" content="default-src 'self';script-src 'self' 'unsafe-inline';style-src 'self' 'unsafe-inline'">
    \\<style>:root{color-scheme:light dark}body{margin:0;padding:32px;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",Segoe UI,system-ui,sans-serif;background:#f8f9fb;color:#18181b}h1{margin:0 0 10px;font-size:30px;letter-spacing:0}.actions{display:grid;grid-template-columns:repeat(2,minmax(170px,1fr));gap:10px;max-width:740px;margin:20px 0}button{min-height:40px;border:1px solid #d8dde4;border-radius:7px;padding:9px 13px;font:inherit;font-weight:590;text-align:left;background:white}.primary{color:white;background:#18181b;border-color:#18181b}pre{max-width:760px;min-height:140px;padding:14px 16px;overflow:auto;border:1px solid #dde2e8;border-radius:7px;background:white;color:#374151;font-size:13px;line-height:1.45}@media(prefers-color-scheme:dark){body{background:#101214;color:#f4f4f5}button,pre{color:#f4f4f5;background:#171a20;border-color:#2b3038}.primary{color:#101214;background:#f4f4f5}}</style>
    \\<h1>Capabilities</h1><p>Trusted WebView code can call native OS services only after explicit permissions and command policies.</p><div class="actions"><button class="primary" id="notify">Send Notification</button><button id="support">Check Support</button><button id="open">Open URL</button><button id="reveal">Reveal Path</button><button id="recent">Recent Documents</button><button id="clipboard">Clipboard Round Trip</button><button id="message">Show Message</button><button id="credentials">Credential Round Trip</button></div><pre id="output">Ready.</pre>
    \\<script>const q=s=>document.querySelector(s),out=q("#output"),show=v=>out.textContent=JSON.stringify(v,null,2),fail=e=>out.textContent=(e.code||"error")+": "+e.message,inv=(c,p)=>window.zero.invoke(c,p),doc="/tmp/zero-native-example.txt",recent="/tmp/recent-zero-native-example.txt";q("#notify").onclick=async()=>{try{show(await inv("zero-native.os.showNotification",{title:"Capabilities",subtitle:"zero-native",body:"Notification bridge succeeded."}))}catch(e){fail(e)}};q("#support").onclick=async()=>{try{let r={},f=["open_url","reveal_path","recent_documents","notifications","dialogs","clipboard_text","clipboard_rich_data","credentials","file_drops","app_activation_events"];for(const x of f)r[x]=await inv("zero-native.platform.supports",{feature:x});show(r)}catch(e){fail(e)}};q("#open").onclick=async()=>{try{show({opened:await inv("zero-native.os.openUrl",{url:"https://example.com/docs/start"})})}catch(e){fail(e)}};q("#reveal").onclick=async()=>{try{show({revealed:await inv("zero-native.os.revealPath",{path:doc})})}catch(e){fail(e)}};q("#recent").onclick=async()=>{try{await inv("zero-native.os.addRecentDocument",{path:recent});show({cleared:await inv("zero-native.os.clearRecentDocuments",{})})}catch(e){fail(e)}};q("#clipboard").onclick=async()=>{try{await inv("zero-native.clipboard.writeText",{text:"Copied from zero-native"});show({text:await inv("zero-native.clipboard.readText",{})})}catch(e){fail(e)}};q("#message").onclick=async()=>{try{show(await inv("zero-native.dialog.showMessage",{style:"info",title:"Capabilities",message:"Native dialog bridge succeeded.",primaryButton:"OK"}))}catch(e){fail(e)}};q("#credentials").onclick=async()=>{try{const key={service:"dev.zero-native.capabilities",account:"demo"};await inv("zero-native.credentials.set",{...key,secret:"demo-token"});show({token:await inv("zero-native.credentials.get",key),deleted:await inv("zero-native.credentials.delete",key)})}catch(e){fail(e)}};window.addEventListener("zero-native:drop:files",e=>show(e.detail));if(window.zero&&window.zero.on){window.zero.on("app:activate",d=>show({event:"app:activate",detail:d}));window.zero.on("app:deactivate",d=>show({event:"app:deactivate",detail:d}))}</script>
;

const app_permissions = [_][]const u8{
    zero_native.security.permission_window,
    zero_native.security.permission_network,
    zero_native.security.permission_filesystem,
    zero_native.security.permission_notifications,
    zero_native.security.permission_dialog,
    zero_native.security.permission_clipboard,
    zero_native.security.permission_credentials,
};
const bridge_origins = [_][]const u8{ "zero://inline", "zero://app" };
const platform_permission = [_][]const u8{zero_native.security.permission_window};
const network_permission = [_][]const u8{zero_native.security.permission_network};
const filesystem_permission = [_][]const u8{zero_native.security.permission_filesystem};
const notification_permission = [_][]const u8{zero_native.security.permission_notifications};
const dialog_permission = [_][]const u8{zero_native.security.permission_dialog};
const clipboard_permission = [_][]const u8{zero_native.security.permission_clipboard};
const credential_permission = [_][]const u8{zero_native.security.permission_credentials};
const builtin_policies = [_]zero_native.BridgeCommandPolicy{
    .{ .name = "zero-native.platform.supports", .permissions = &platform_permission, .origins = &bridge_origins },
    .{ .name = "zero-native.os.openUrl", .permissions = &network_permission, .origins = &bridge_origins },
    .{ .name = "zero-native.os.showNotification", .permissions = &notification_permission, .origins = &bridge_origins },
    .{ .name = "zero-native.os.revealPath", .permissions = &filesystem_permission, .origins = &bridge_origins },
    .{ .name = "zero-native.os.addRecentDocument", .permissions = &filesystem_permission, .origins = &bridge_origins },
    .{ .name = "zero-native.os.clearRecentDocuments", .permissions = &filesystem_permission, .origins = &bridge_origins },
    .{ .name = "zero-native.dialog.showMessage", .permissions = &dialog_permission, .origins = &bridge_origins },
    .{ .name = "zero-native.clipboard.readText", .permissions = &clipboard_permission, .origins = &bridge_origins },
    .{ .name = "zero-native.clipboard.writeText", .permissions = &clipboard_permission, .origins = &bridge_origins },
    .{ .name = "zero-native.clipboard.read", .permissions = &clipboard_permission, .origins = &bridge_origins },
    .{ .name = "zero-native.clipboard.write", .permissions = &clipboard_permission, .origins = &bridge_origins },
    .{ .name = "zero-native.credentials.set", .permissions = &credential_permission, .origins = &bridge_origins },
    .{ .name = "zero-native.credentials.get", .permissions = &credential_permission, .origins = &bridge_origins },
    .{ .name = "zero-native.credentials.delete", .permissions = &credential_permission, .origins = &bridge_origins },
};
const shell_views = [_]zero_native.ShellView{
    .{ .label = "main", .kind = .webview, .url = "zero://inline", .fill = true },
    .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = statusbar_height, .layer = 20, .role = "Status" },
    .{ .label = "status-label", .kind = .label, .parent = "statusbar", .x = 14, .y = 8, .width = 640, .height = 18, .layer = 21, .text = "Ready." },
};
const shell_windows = [_]zero_native.ShellWindow{.{
    .label = "main",
    .title = "zero-native Capabilities",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: zero_native.ShellConfig = .{ .windows = &shell_windows };

const CapabilitiesApp = struct {
    drop_count: u32 = 0,
    activation_count: u32 = 0,
    deactivation_count: u32 = 0,
    last_drop_paths: []const []const u8 = &.{},

    fn app(self: *@This()) zero_native.App {
        return .{
            .context = self,
            .name = "capabilities",
            .source = zero_native.WebViewSource.html(html),
            .scene_fn = scene,
            .event_fn = event,
        };
    }

    fn scene(context: *anyopaque) anyerror!zero_native.ShellConfig {
        _ = context;
        return shell_scene;
    }

    fn event(context: *anyopaque, runtime: *zero_native.Runtime, event_value: zero_native.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event_value) {
            .files_dropped => |drop| {
                self.drop_count += 1;
                self.last_drop_paths = drop.paths;
                var status_buffer: [160]u8 = undefined;
                const first_path = if (drop.paths.len > 0) drop.paths[0] else "";
                const status = try std.fmt.bufPrint(&status_buffer, "Received file drop {d}: {d} file(s): {s}", .{ self.drop_count, drop.paths.len, first_path });
                _ = try runtime.updateView(drop.window_id, "status-label", .{ .text = status });
            },
            .lifecycle => |lifecycle| switch (lifecycle) {
                .activate => {
                    self.activation_count += 1;
                    _ = try runtime.updateView(1, "status-label", .{ .text = "App activated." });
                },
                .deactivate => {
                    self.deactivation_count += 1;
                    _ = try runtime.updateView(1, "status-label", .{ .text = "App deactivated." });
                },
                else => {},
            },
            .appearance_changed, .command, .shortcut, .gpu_surface_frame, .gpu_surface_resized, .gpu_surface_input, .canvas_widget_pointer, .canvas_widget_keyboard, .canvas_widget_file_drop, .canvas_widget_drag => {},
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var app = CapabilitiesApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "capabilities",
        .window_title = "zero-native Capabilities",
        .bundle_id = "dev.zero_native.capabilities",
        .icon_path = "assets/icon.icns",
        .default_frame = zero_native.geometry.RectF.init(0, 0, window_width, window_height),
        .builtin_bridge = .{ .enabled = true, .commands = &builtin_policies },
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{
                .allowed_origins = &bridge_origins,
                .external_links = .{
                    .action = .open_system_browser,
                    .allowed_urls = &.{"https://example.com/docs/*"},
                },
            },
        },
    }, init);
}

test "capabilities bridge gates native services and dispatches file drops" {
    var harness: zero_native.TestHarness() = undefined;
    harness.init(.{ .size = zero_native.geometry.SizeF.init(window_width, window_height) });
    harness.runtime.options.builtin_bridge = .{ .enabled = true, .commands = &builtin_policies };
    harness.runtime.options.security = .{
        .permissions = &app_permissions,
        .navigation = .{
            .allowed_origins = &bridge_origins,
            .external_links = .{
                .action = .open_system_browser,
                .allowed_urls = &.{"https://example.com/docs/*"},
            },
        },
    };

    var app_state = CapabilitiesApp{};
    const app = app_state.app();
    try harness.start(app);

    try dispatchBridge(&harness, app, "{\"id\":\"notify\",\"command\":\"zero-native.os.showNotification\",\"payload\":{\"title\":\"Capabilities\",\"subtitle\":\"zero-native\",\"body\":\"Done\"}}");
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.notificationCount());
    try std.testing.expectEqualStrings("Capabilities", harness.null_platform.lastNotificationTitle());

    try dispatchBridge(&harness, app, "{\"id\":\"support\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"notifications\"}}");
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":true") != null);
    try dispatchBridge(&harness, app, "{\"id\":\"support-recent\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"recentDocuments\"}}");
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":true") != null);

    try dispatchBridge(&harness, app, "{\"id\":\"open\",\"command\":\"zero-native.os.openUrl\",\"payload\":{\"url\":\"https://example.com/docs/start\"}}");
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqualStrings("https://example.com/docs/start", harness.null_platform.lastExternalUrl());

    try dispatchBridge(&harness, app, "{\"id\":\"reveal\",\"command\":\"zero-native.os.revealPath\",\"payload\":{\"path\":\"/tmp/zero-native-example.txt\"}}");
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqualStrings("/tmp/zero-native-example.txt", harness.null_platform.lastRevealedPath());

    try dispatchBridge(&harness, app, "{\"id\":\"recent\",\"command\":\"zero-native.os.addRecentDocument\",\"payload\":{\"path\":\"/tmp/recent-zero-native-example.txt\"}}");
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqualStrings("/tmp/recent-zero-native-example.txt", harness.null_platform.lastRecentDocumentPath());
    try dispatchBridge(&harness, app, "{\"id\":\"clear-recent\",\"command\":\"zero-native.os.clearRecentDocuments\",\"payload\":{}}");
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.recentDocumentsClearedCount());

    try dispatchBridge(&harness, app, "{\"id\":\"write\",\"command\":\"zero-native.clipboard.writeText\",\"payload\":{\"text\":\"plain text\"}}");
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqualStrings("plain text", harness.null_platform.lastClipboardData());
    try dispatchBridge(&harness, app, "{\"id\":\"read\",\"command\":\"zero-native.clipboard.readText\",\"payload\":{}}");
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":\"plain text\"") != null);

    try dispatchBridge(&harness, app, "{\"id\":\"set\",\"command\":\"zero-native.credentials.set\",\"payload\":{\"service\":\"dev.zero-native.capabilities\",\"account\":\"demo\",\"secret\":\"demo-token\"}}");
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.credentialSetCount());
    try dispatchBridge(&harness, app, "{\"id\":\"get\",\"command\":\"zero-native.credentials.get\",\"payload\":{\"service\":\"dev.zero-native.capabilities\",\"account\":\"demo\"}}");
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":\"demo-token\"") != null);
    try dispatchBridge(&harness, app, "{\"id\":\"delete\",\"command\":\"zero-native.credentials.delete\",\"payload\":{\"service\":\"dev.zero-native.capabilities\",\"account\":\"demo\"}}");
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":true") != null);

    const dropped_paths = [_][]const u8{ "/tmp/one\nname.txt", "/tmp/two.txt" };
    try harness.runtime.dispatchPlatformEvent(app, .{ .files_dropped = .{
        .window_id = 1,
        .paths = &dropped_paths,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.drop_count);
    try std.testing.expectEqual(@as(usize, 2), app_state.last_drop_paths.len);
    try std.testing.expectEqualStrings("/tmp/one\nname.txt", app_state.last_drop_paths[0]);
    try std.testing.expectEqualStrings("/tmp/two.txt", app_state.last_drop_paths[1]);
    try std.testing.expectEqualStrings("drop:files", harness.null_platform.lastWindowEventName());

    try harness.runtime.dispatchPlatformEvent(app, .app_activated);
    try std.testing.expectEqual(@as(u32, 1), app_state.activation_count);
    try std.testing.expectEqualStrings("app:activate", harness.null_platform.lastWindowEventName());
    try harness.runtime.dispatchPlatformEvent(app, .app_deactivated);
    try std.testing.expectEqual(@as(u32, 1), app_state.deactivation_count);
    try std.testing.expectEqualStrings("app:deactivate", harness.null_platform.lastWindowEventName());
}

test "capabilities manifest declares package integration metadata" {
    try std.testing.expectEqual(@as(usize, 1), manifest_file_associations.len);
    try std.testing.expectEqualStrings("zero-native Capability Document", manifest_file_associations[0].name);
    try std.testing.expectEqualStrings("viewer", manifest_file_associations[0].role);
    try std.testing.expectEqualStrings("zncap", manifest_file_associations[0].extensions[0]);
    try std.testing.expectEqualStrings("application/vnd.zero-native.capability+json", manifest_file_associations[0].mime_types[0]);
    try std.testing.expectEqualStrings("assets/icon.icns", manifest_file_associations[0].icon);

    try std.testing.expectEqual(@as(usize, 1), manifest_url_schemes.len);
    try std.testing.expectEqualStrings("zero-native-capabilities", manifest_url_schemes[0].scheme);
}

fn dispatchBridge(harness: *zero_native.TestHarness(), app: zero_native.App, bytes: []const u8) !void {
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = bytes,
        .origin = "zero://inline",
        .window_id = 1,
        .webview_label = "main",
    } });
}
