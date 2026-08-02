const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const runtime = @import("../runtime/root.zig");
const platform = @import("../platform/root.zig");
const types = @import("types.zig");
const host = @import("host.zig");
const ui_host = @import("ui_host.zig");
const c_api = @import("c_api.zig");
const conversions = @import("conversions.zig");

const MobileWidgetRole = types.MobileWidgetRole;
const MobileWidgetFlag = types.MobileWidgetFlag;
const MobileWidgetAction = types.MobileWidgetAction;
const MobileWidgetActionKind = types.MobileWidgetActionKind;
const MobileWidgetSemantics = types.MobileWidgetSemantics;
const MobileWidgetTextGeometry = types.MobileWidgetTextGeometry;
const MobileWidgetActionRequest = types.MobileWidgetActionRequest;
const MobileTextInputState = types.MobileTextInputState;
const MobileViewportState = types.MobileViewportState;
const MobileGpuFrameState = types.MobileGpuFrameState;
const MobileCanvasPixels = types.MobileCanvasPixels;
const EmbeddedApp = host.EmbeddedApp;
const mobileApp = host.mobileApp;
const mobile_html = host.mobile_html;
const mobile_gpu_surface_label = types.mobile_gpu_surface_label;
const mobileWidgetFlags = conversions.mobileWidgetFlags;
const mobileWidgetActions = conversions.mobileWidgetActions;
const mobileWidgetActionKindFromInt = conversions.mobileWidgetActionKindFromInt;
const native_sdk_app_create = c_api.native_sdk_app_create;
const native_sdk_app_destroy = c_api.native_sdk_app_destroy;
const native_sdk_app_start = c_api.native_sdk_app_start;
const native_sdk_app_activate = c_api.native_sdk_app_activate;
const native_sdk_app_deactivate = c_api.native_sdk_app_deactivate;
const native_sdk_app_resize = c_api.native_sdk_app_resize;
const native_sdk_app_viewport = c_api.native_sdk_app_viewport;
const native_sdk_app_viewport_state = c_api.native_sdk_app_viewport_state;
const native_sdk_app_gpu_frame_state = c_api.native_sdk_app_gpu_frame_state;
const native_sdk_app_touch = c_api.native_sdk_app_touch;
const native_sdk_app_scroll = c_api.native_sdk_app_scroll;
const native_sdk_app_key = c_api.native_sdk_app_key;
const native_sdk_app_text = c_api.native_sdk_app_text;
const native_sdk_app_ime = c_api.native_sdk_app_ime;
const native_sdk_app_command = c_api.native_sdk_app_command;
const native_sdk_app_set_asset_root = c_api.native_sdk_app_set_asset_root;
const native_sdk_app_set_asset_entry = c_api.native_sdk_app_set_asset_entry;
const native_sdk_app_last_command_count = c_api.native_sdk_app_last_command_count;
const native_sdk_app_last_command_name = c_api.native_sdk_app_last_command_name;
const native_sdk_app_last_error_name = c_api.native_sdk_app_last_error_name;
const native_sdk_app_widget_semantics_count = c_api.native_sdk_app_widget_semantics_count;
const native_sdk_app_widget_semantics_at = c_api.native_sdk_app_widget_semantics_at;
const native_sdk_app_widget_semantics_by_id = c_api.native_sdk_app_widget_semantics_by_id;
const native_sdk_app_widget_text_geometry = c_api.native_sdk_app_widget_text_geometry;
const native_sdk_app_widget_action = c_api.native_sdk_app_widget_action;

fn mobileWidgetSemanticsByIdForTest(app: ?*anyopaque, id: u64) !MobileWidgetSemantics {
    var node: MobileWidgetSemantics = .{};
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_semantics_by_id(app, id, &node));
    try std.testing.expectEqual(id, node.id);
    return node;
}

fn expectNoMobileWidgetSemanticsByIdForTest(app: ?*anyopaque, id: u64) !void {
    var node: MobileWidgetSemantics = .{};
    try std.testing.expectEqual(@as(c_int, 0), native_sdk_app_widget_semantics_by_id(app, id, &node));
}
test "embedded app starts and loads source" {
    var null_platform = platform.NullPlatform.init(.{});
    var state: u8 = 0;
    const embedded = try std.testing.allocator.create(EmbeddedApp);
    defer std.testing.allocator.destroy(embedded);
    embedded.initInPlace(.{
        .context = &state,
        .name = "embedded",
        .source = platform.WebViewSource.html("<p>Embedded</p>"),
    }, null_platform.platform());

    try embedded.start();
    try @import("std").testing.expectEqualStrings("<p>Embedded</p>", null_platform.loaded_source.?.bytes);
}

test "embedded app deinit returns registered font bytes across create-destroy cycles" {
    // A direct embedder that creates and destroys apps in one process:
    // every cycle registers a face (font bytes are the embedded
    // runtime's only heap ownership) and tears down through the public
    // `deinit` — the lifecycle end the doc comment promises. The
    // leak-checking test allocator behind the `Options.allocator` seam
    // fails this test if any cycle strands the storage, which is
    // exactly what a stop()-only teardown did.
    var cycle: usize = 0;
    while (cycle < 3) : (cycle += 1) {
        var null_platform = platform.NullPlatform.init(.{});
        var state: u8 = 0;
        const embedded = try std.testing.allocator.create(EmbeddedApp);
        defer std.testing.allocator.destroy(embedded);
        embedded.initInPlace(.{
            .context = &state,
            .name = "embedded-font-cycle",
            .source = platform.WebViewSource.html("<p>Fonts</p>"),
        }, null_platform.platform());
        defer embedded.deinit();
        // Ownership is frozen at init (`Runtime.owned_allocator`;
        // mutating `options.allocator` retargets nothing), so the test
        // re-freezes the field itself — equivalent to constructing with
        // the leak-checked allocator, safe while nothing is owned yet.
        embedded.runtime.owned_allocator = std.testing.allocator;

        try embedded.start();
        try embedded.runtime.registerCanvasFont(canvas.min_registered_font_id, canvas.font_ttf.geist_mono_bytes);
        try std.testing.expectEqual(@as(usize, 1), embedded.runtime.registeredCanvasFontCount());
        try embedded.stop();

        // Deinit returns BOTH sides of the registration: the Zig-side
        // bytes (the leak-checking allocator above) and the host-side
        // registration — the runtime must call the platform's
        // font-unregister seam per registered id, the call a macOS host
        // answers by dropping its CoreText descriptor and caches. The
        // null platform records that call; the deferred second deinit
        // stays the idempotence backstop.
        embedded.deinit();
        try std.testing.expectEqual(@as(usize, 1), null_platform.gpu_surface_font_unregister_count);
        try std.testing.expectEqual(@as(u64, canvas.min_registered_font_id), null_platform.gpu_surface_font_unregister_id);
        // The null platform's register seam is off by default, so the
        // runtime captured ownership token 0 (nothing installed
        // host-side) and the teardown call must carry exactly that.
        try std.testing.expectEqual(@as(u64, 0), null_platform.gpu_surface_font_unregister_token);
    }
}

test "embedded app deinit leaves a newer runtime's re-registration of the same font id intact" {
    // Host font state is per-process while font ids are only permanent
    // per-runtime, so two live runtimes can pass the same id through one
    // host: the later registration wins (the documented lifecycle), and
    // the OLDER runtime's deinit must return only its own already-
    // replaced registration — never the newer runtime's live face,
    // which that runtime's engine still holds and draws through. The
    // null platform's host-font mirror models the stateful host (the
    // shape of macOS's descriptor and token tables): one instance
    // stands in for the process, both runtimes register through it, and
    // the per-registration ownership token is what the unregister guard
    // matches. An id-keyed removal is exactly the regression this test
    // catches — it would empty the mirror at A's deinit and fail the
    // survives assertion below.
    var host_platform = platform.NullPlatform.init(.{});
    host_platform.gpu_surface_font_registrations = true;
    var state_a: u8 = 0;
    var state_b: u8 = 0;
    const embedded_a = try std.testing.allocator.create(EmbeddedApp);
    defer std.testing.allocator.destroy(embedded_a);
    const embedded_b = try std.testing.allocator.create(EmbeddedApp);
    defer std.testing.allocator.destroy(embedded_b);
    embedded_a.initInPlace(.{
        .context = &state_a,
        .name = "embedded-font-owner-a",
        .source = platform.WebViewSource.html("<p>A</p>"),
    }, host_platform.platform());
    defer embedded_a.deinit();
    embedded_b.initInPlace(.{
        .context = &state_b,
        .name = "embedded-font-owner-b",
        .source = platform.WebViewSource.html("<p>B</p>"),
    }, host_platform.platform());
    defer embedded_b.deinit();
    embedded_a.runtime.owned_allocator = std.testing.allocator;
    embedded_b.runtime.owned_allocator = std.testing.allocator;

    // A registers first, B re-registers the same id: last wins, each
    // runtime captured its own never-repeating ownership token.
    try embedded_a.runtime.registerCanvasFont(canvas.min_registered_font_id, canvas.font_ttf.geist_mono_bytes);
    const token_a = embedded_a.runtime.canvas_font_entries[0].host_registration_token;
    try embedded_b.runtime.registerCanvasFont(canvas.min_registered_font_id, canvas.font_ttf.geist_mono_bytes);
    const token_b = embedded_b.runtime.canvas_font_entries[0].host_registration_token;
    try std.testing.expect(token_a != 0);
    try std.testing.expect(token_b != 0);
    try std.testing.expect(token_a != token_b);
    const live = host_platform.gpuSurfaceFont(canvas.min_registered_font_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(token_b, live.token);

    // A's deinit presents its stale token: recorded and accepted (the
    // registration it owned is already gone), and provably removing
    // nothing — B's registration is still the one the host resolves.
    embedded_a.deinit();
    try std.testing.expectEqual(@as(usize, 1), host_platform.gpu_surface_font_unregister_count);
    try std.testing.expectEqual(@as(u64, canvas.min_registered_font_id), host_platform.gpu_surface_font_unregister_id);
    try std.testing.expectEqual(token_a, host_platform.gpu_surface_font_unregister_token);
    const survivor = host_platform.gpuSurfaceFont(canvas.min_registered_font_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(token_b, survivor.token);

    // B's deinit presents the live token and the host state comes out —
    // the guard blocks the wrong owner, not teardown itself.
    embedded_b.deinit();
    try std.testing.expectEqual(@as(usize, 2), host_platform.gpu_surface_font_unregister_count);
    try std.testing.expectEqual(token_b, host_platform.gpu_surface_font_unregister_token);
    try std.testing.expect(host_platform.gpuSurfaceFont(canvas.min_registered_font_id) == null);
}

test "embedded app deinit is idempotent" {
    var null_platform = platform.NullPlatform.init(.{});
    var state: u8 = 0;
    const embedded = try std.testing.allocator.create(EmbeddedApp);
    defer std.testing.allocator.destroy(embedded);
    embedded.initInPlace(.{
        .context = &state,
        .name = "embedded-deinit-twice",
        .source = platform.WebViewSource.html("<p>Fonts</p>"),
    }, null_platform.platform());
    embedded.runtime.owned_allocator = std.testing.allocator;
    try embedded.runtime.registerCanvasFont(canvas.min_registered_font_id, canvas.font_ttf.geist_mono_bytes);

    // The documented idiom is `defer embedded.deinit()`, which must
    // compose with an explicit early teardown: the second call is a
    // no-op, never a double free — and never a double host unregister
    // (the first deinit already returned the host-side registration).
    embedded.deinit();
    try std.testing.expectEqual(@as(usize, 0), embedded.runtime.registeredCanvasFontCount());
    try std.testing.expectEqual(@as(usize, 1), null_platform.gpu_surface_font_unregister_count);
    embedded.deinit();
    try std.testing.expectEqual(@as(usize, 1), null_platform.gpu_surface_font_unregister_count);
}

test "embedded app deinit returns the font registration to the platform that received it" {
    // `Runtime.options` is public and mutable, and embedders genuinely
    // swap the platform on a live runtime (tests in this repo do it
    // constantly). The host-side registration must still come back to
    // the host that RECEIVED it: each font entry captures its
    // unregistration owner at registration time (the allocator-identity
    // freeze, applied to the host seam), so a swap between registration
    // and teardown retargets nothing. A deinit reading the live options
    // instead would unregister against the swapped-in platform — the
    // wrong host, or a null seam — and strand the original host's
    // descriptor and caches for the process lifetime.
    var platform_a = platform.NullPlatform.init(.{});
    var platform_b = platform.NullPlatform.init(.{});
    var state: u8 = 0;
    const embedded = try std.testing.allocator.create(EmbeddedApp);
    defer std.testing.allocator.destroy(embedded);
    embedded.initInPlace(.{
        .context = &state,
        .name = "embedded-font-platform-swap",
        .source = platform.WebViewSource.html("<p>Fonts</p>"),
    }, platform_a.platform());
    embedded.runtime.owned_allocator = std.testing.allocator;
    try embedded.runtime.registerCanvasFont(canvas.min_registered_font_id, canvas.font_ttf.geist_mono_bytes);

    // The swap under test: platform B holds the option by teardown time,
    // but it never saw the registration.
    embedded.runtime.options.platform = platform_b.platform();
    embedded.deinit();
    try std.testing.expectEqual(@as(usize, 1), platform_a.gpu_surface_font_unregister_count);
    try std.testing.expectEqual(@as(u64, canvas.min_registered_font_id), platform_a.gpu_surface_font_unregister_id);
    try std.testing.expectEqual(@as(usize, 0), platform_b.gpu_surface_font_unregister_count);
}

test "mobile C ABI destroy returns registered font bytes through the embedded deinit" {
    const app = native_sdk_app_create() orelse return error.TestUnexpectedResult;
    errdefer native_sdk_app_destroy(app);

    const self = mobileApp(app).?;
    self.embedded.runtime.owned_allocator = std.testing.allocator;
    try self.embedded.runtime.registerCanvasFont(canvas.min_registered_font_id, canvas.font_ttf.geist_mono_bytes);
    try std.testing.expectEqual(@as(usize, 1), self.embedded.runtime.registeredCanvasFontCount());

    // `native_sdk_app_destroy` is the shim's whole teardown: it routes
    // through `EmbeddedApp.deinit` (one lifecycle owner), so the
    // leak-checked font bytes must come back here.
    native_sdk_app_destroy(app);
}

test "mobile C ABI can load packaged asset source" {
    const app = native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer native_sdk_app_destroy(app);

    const asset_root = "/tmp/native-sdk-mobile-assets";
    native_sdk_app_set_asset_root(app, asset_root, asset_root.len);
    native_sdk_app_start(app);

    const self = mobileApp(app).?;
    const source = self.null_platform.loaded_source.?;
    try std.testing.expectEqual(platform.WebViewSourceKind.assets, source.kind);
    try std.testing.expectEqualStrings("zero://app", source.bytes);
    try std.testing.expect(source.asset_options != null);
    try std.testing.expectEqualStrings(asset_root, source.asset_options.?.root_path);
    try std.testing.expectEqualStrings("index.html", source.asset_options.?.entry);
    try std.testing.expect(source.asset_options.?.spa_fallback);
    try std.testing.expectEqualStrings("", std.mem.span(native_sdk_app_last_error_name(app)));
}

test "mobile C ABI can load custom packaged asset entry" {
    const app = native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer native_sdk_app_destroy(app);

    const asset_root = "/tmp/native-sdk-mobile-assets";
    const asset_entry = "main.html";
    native_sdk_app_set_asset_root(app, asset_root, asset_root.len);
    native_sdk_app_set_asset_entry(app, asset_entry, asset_entry.len);
    native_sdk_app_start(app);

    const self = mobileApp(app).?;
    const source = self.null_platform.loaded_source.?;
    try std.testing.expectEqual(platform.WebViewSourceKind.assets, source.kind);
    try std.testing.expect(source.asset_options != null);
    try std.testing.expectEqualStrings(asset_root, source.asset_options.?.root_path);
    try std.testing.expectEqualStrings(asset_entry, source.asset_options.?.entry);
    try std.testing.expectEqualStrings("", std.mem.span(native_sdk_app_last_error_name(app)));
}

test "mobile C ABI can reset asset root before startup" {
    const app = native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer native_sdk_app_destroy(app);

    const asset_root = "/tmp/native-sdk-mobile-assets";
    native_sdk_app_set_asset_root(app, asset_root, asset_root.len);
    native_sdk_app_set_asset_root(app, asset_root, 0);
    native_sdk_app_start(app);

    const self = mobileApp(app).?;
    const source = self.null_platform.loaded_source.?;
    try std.testing.expectEqual(platform.WebViewSourceKind.html, source.kind);
    try std.testing.expectEqualStrings(mobile_html, source.bytes);
    try std.testing.expectEqualStrings("", std.mem.span(native_sdk_app_last_error_name(app)));
}

test "mobile C ABI forwards activation lifecycle through embedded runtime" {
    const app = native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer native_sdk_app_destroy(app);

    native_sdk_app_start(app);
    native_sdk_app_activate(app);
    native_sdk_app_deactivate(app);

    const self = mobileApp(app).?;
    try std.testing.expectEqual(@as(usize, 1), self.activation_count);
    try std.testing.expectEqual(@as(usize, 1), self.deactivation_count);
    try std.testing.expectEqualStrings("", std.mem.span(native_sdk_app_last_error_name(app)));
}

test "mobile C ABI forwards surface resize and touch input" {
    const app = native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer native_sdk_app_destroy(app);

    var native_surface_token: u8 = 0;
    native_sdk_app_resize(app, 390, 844, 3, &native_surface_token);

    const self = mobileApp(app).?;
    try std.testing.expectEqual(@as(usize, 1), self.mobile_surface_resize_count);
    try std.testing.expectEqual(@as(f32, 390), self.mobile_surface_width);
    try std.testing.expectEqual(@as(f32, 844), self.mobile_surface_height);
    try std.testing.expectEqual(@as(f32, 3), self.mobile_surface_scale);

    native_sdk_app_viewport(app, 390, 700, 3, &native_surface_token, 47, 0, 34, 0, 0, 0, 144, 0);
    try std.testing.expectEqual(@as(usize, 2), self.mobile_surface_resize_count);
    try std.testing.expectEqual(@as(f32, 390), self.embedded.runtime.surface.size.width);
    try std.testing.expectEqual(@as(f32, 700), self.embedded.runtime.surface.size.height);
    try std.testing.expectEqual(@as(f32, 47), self.embedded.runtime.surface.safe_area_insets.top);
    try std.testing.expectEqual(@as(f32, 34), self.embedded.runtime.surface.safe_area_insets.bottom);
    try std.testing.expectEqual(@as(f32, 144), self.embedded.runtime.surface.keyboard_insets.bottom);

    var viewport: MobileViewportState = .{};
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_viewport_state(app, &viewport));
    try std.testing.expectEqual(@as(f32, 390), viewport.width);
    try std.testing.expectEqual(@as(f32, 700), viewport.height);
    try std.testing.expectEqual(@as(f32, 3), viewport.scale);
    try std.testing.expectEqual(@as(c_int, 1), viewport.has_surface);
    try std.testing.expectEqual(@as(f32, 47), viewport.safe_top);
    try std.testing.expectEqual(@as(f32, 34), viewport.safe_bottom);
    try std.testing.expectEqual(@as(f32, 144), viewport.keyboard_bottom);
    try std.testing.expectEqual(@as(f32, 0), viewport.content_x);
    try std.testing.expectEqual(@as(f32, 47), viewport.content_y);
    try std.testing.expectEqual(@as(f32, 390), viewport.content_width);
    try std.testing.expectEqual(@as(f32, 509), viewport.content_height);
    try std.testing.expectEqualStrings("", std.mem.span(native_sdk_app_last_error_name(app)));

    try std.testing.expectEqual(@as(c_int, 0), native_sdk_app_viewport_state(app, null));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(native_sdk_app_last_error_name(app)));

    native_sdk_app_touch(app, 42, 0, 11, 22, 0.5);
    try std.testing.expectEqual(@as(usize, 1), self.touch_count);
    try std.testing.expectEqual(@as(u64, 42), self.last_touch_id);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.pointer_down, self.last_touch_kind);
    try std.testing.expect(self.last_touch_timestamp_ns > 0);
    try std.testing.expectEqual(@as(f32, 11), self.last_touch_x);
    try std.testing.expectEqual(@as(f32, 22), self.last_touch_y);
    try std.testing.expectEqual(@as(f32, 0.5), self.last_touch_pressure);
    try std.testing.expectEqualStrings("", std.mem.span(native_sdk_app_last_error_name(app)));

    native_sdk_app_touch(app, 42, 2, 13, 25, 0.75);
    try std.testing.expectEqual(@as(usize, 2), self.touch_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.pointer_drag, self.last_touch_kind);
    try std.testing.expectEqual(@as(f32, 13), self.last_touch_x);
    try std.testing.expectEqual(@as(f32, 25), self.last_touch_y);
    try std.testing.expectEqual(@as(f32, 0.75), self.last_touch_pressure);

    native_sdk_app_touch(app, 42, 3, 13, 25, 0);
    try std.testing.expectEqual(@as(usize, 3), self.touch_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.pointer_cancel, self.last_touch_kind);

    native_sdk_app_scroll(app, 42, 15, 26, -2, 18);
    try std.testing.expectEqual(@as(usize, 4), self.touch_count);
    try std.testing.expectEqual(@as(usize, 4), self.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.scroll, self.last_touch_kind);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.scroll, self.last_input_kind);
    try std.testing.expectEqual(@as(u64, 42), self.last_touch_id);
    try std.testing.expectEqual(@as(f32, 15), self.last_touch_x);
    try std.testing.expectEqual(@as(f32, 26), self.last_touch_y);
    try std.testing.expectEqual(@as(f32, -2), self.last_touch_delta_x);
    try std.testing.expectEqual(@as(f32, 18), self.last_touch_delta_y);
    try std.testing.expectEqual(@as(f32, 0), self.last_touch_pressure);
    try std.testing.expectEqualStrings("", std.mem.span(native_sdk_app_last_error_name(app)));

    native_sdk_app_touch(app, 42, 99, 13, 25, 0);
    try std.testing.expectEqual(@as(usize, 4), self.touch_count);
    try std.testing.expectEqualStrings("InvalidTouchPhase", std.mem.span(native_sdk_app_last_error_name(app)));
}

test "mobile C ABI forwards key text and IME input" {
    const app = native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer native_sdk_app_destroy(app);

    const self = mobileApp(app).?;
    native_sdk_app_key(app, 0, "enter", "enter".len, "", 0, 17);
    try std.testing.expectEqual(@as(usize, 1), self.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.key_down, self.last_input_kind);
    try std.testing.expectEqualStrings("enter", self.last_input_key[0..self.last_input_key_len]);
    try std.testing.expect(self.last_input_modifiers.primary);
    try std.testing.expect(self.last_input_modifiers.shift);
    try std.testing.expectEqualStrings("", std.mem.span(native_sdk_app_last_error_name(app)));

    native_sdk_app_text(app, "é", "é".len);
    try std.testing.expectEqual(@as(usize, 2), self.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.text_input, self.last_input_kind);
    try std.testing.expectEqualStrings("é", self.last_input_text[0..self.last_input_text_len]);

    native_sdk_app_ime(app, 0, "かな", "かな".len, "かな".len);
    try std.testing.expectEqual(@as(usize, 3), self.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.ime_set_composition, self.last_input_kind);
    try std.testing.expectEqualStrings("かな", self.last_input_text[0..self.last_input_text_len]);
    try std.testing.expectEqual(@as(?usize, "かな".len), self.last_input_composition_cursor);

    native_sdk_app_ime(app, 1, "", 0, -1);
    try std.testing.expectEqual(@as(usize, 4), self.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.ime_commit_composition, self.last_input_kind);

    native_sdk_app_ime(app, 2, "", 0, -1);
    try std.testing.expectEqual(@as(usize, 5), self.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.ime_cancel_composition, self.last_input_kind);

    native_sdk_app_key(app, 99, "enter", "enter".len, "", 0, 0);
    try std.testing.expectEqual(@as(usize, 5), self.input_count);
    try std.testing.expectEqualStrings("InvalidKeyPhase", std.mem.span(native_sdk_app_last_error_name(app)));

    native_sdk_app_ime(app, 99, "", 0, -1);
    try std.testing.expectEqual(@as(usize, 5), self.input_count);
    try std.testing.expectEqualStrings("InvalidImeKind", std.mem.span(native_sdk_app_last_error_name(app)));
}

test "mobile C ABI exposes GPU frame state" {
    const app = native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer native_sdk_app_destroy(app);

    const self = mobileApp(app).?;
    self.null_platform.gpu_surfaces = true;
    native_sdk_app_start(app);
    const view = try self.embedded.runtime.createView(.{
        .window_id = 1,
        .label = mobile_gpu_surface_label,
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 390, 844),
    });

    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(16, 16, 120, 36),
            .text = "Continue",
            .semantics = .{ .label = "Continue" },
        },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{
        .id = 1,
        .kind = .panel,
        .children = &children,
        .semantics = .{ .label = "Mobile GPU frame" },
    }, geometry.RectF.init(0, 0, 390, 844), &nodes);
    _ = try self.embedded.runtime.setCanvasWidgetLayout(1, mobile_gpu_surface_label, layout);
    _ = try self.embedded.runtime.emitCanvasWidgetDisplayList(1, mobile_gpu_surface_label, .{});

    try self.embedded.runtime.dispatchPlatformEvent(self.embedded.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = mobile_gpu_surface_label,
        .kind = .pointer_down,
        .timestamp_ns = 1_000_000,
        .pointer_id = 9,
        .x = 22,
        .y = 28,
        .pressure = 0.75,
    } });
    try self.embedded.runtime.dispatchPlatformEvent(self.embedded.app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = mobile_gpu_surface_label,
        .size = geometry.SizeF.init(390, 844),
        .scale_factor = 3,
        .frame_index = 7,
        .timestamp_ns = 21_000_000,
        .frame_interval_ns = 8_333_333,
        .nonblank = true,
        .sample_color = 0xff3366ff,
        .status = .ready,
        .vsync = true,
    } });

    var state: MobileGpuFrameState = .{};
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_gpu_frame_state(app, &state));
    try std.testing.expectEqual(view.id, state.surface_id);
    try std.testing.expectEqual(@as(u64, 1), state.window_id);
    try std.testing.expectEqual(@as(f32, 390), state.width);
    try std.testing.expectEqual(@as(f32, 844), state.height);
    try std.testing.expectEqual(@as(f32, 3), state.scale);
    try std.testing.expectEqual(@as(u64, 7), state.frame_index);
    try std.testing.expectEqual(@as(u64, 21_000_000), state.timestamp_ns);
    try std.testing.expectEqual(@as(u64, 8_333_333), state.frame_interval_ns);
    try std.testing.expectEqual(@as(u64, 1_000_000), state.input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 20_000_000), state.input_latency_ns);
    try std.testing.expectEqual(@as(u64, 8_333_333), state.input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 1), state.input_latency_budget_exceeded_count);
    try std.testing.expectEqual(@as(c_int, 0), state.input_latency_budget_ok);
    try std.testing.expectEqual(@as(c_int, 1), state.nonblank);
    try std.testing.expectEqual(@as(u32, 0xff3366ff), state.sample_color);
    try std.testing.expectEqual(@intFromEnum(platform.GpuSurfaceStatus.ready), state.status);
    try std.testing.expectEqual(@as(c_int, 1), state.vsync);
    try std.testing.expect(state.canvas_revision > 0);
    try std.testing.expectEqual(@as(usize, 2), state.widget_node_count);
    try std.testing.expectEqual(@as(usize, 2), state.widget_semantics_count);
    try std.testing.expectEqualStrings("", std.mem.span(native_sdk_app_last_error_name(app)));

    try std.testing.expectEqual(@as(c_int, 0), native_sdk_app_gpu_frame_state(app, null));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(native_sdk_app_last_error_name(app)));
}

test "mobile C ABI exposes GPU widget accessibility semantics" {
    const app = native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer native_sdk_app_destroy(app);

    const self = mobileApp(app).?;
    self.null_platform.gpu_surfaces = true;
    native_sdk_app_start(app);
    _ = try self.embedded.runtime.createView(.{
        .window_id = 1,
        .label = mobile_gpu_surface_label,
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 180),
    });

    const scroll_children = [_]canvas.Widget{
        .{
            .id = 5,
            .kind = .button,
            .frame = geometry.RectF.init(0, 0, 0, 28),
            .text = "Top",
        },
        .{
            .id = 6,
            .kind = .button,
            .frame = geometry.RectF.init(0, 88, 0, 28),
            .text = "Bottom",
        },
    };
    const list_children = [_]canvas.Widget{
        .{
            .id = 8,
            .kind = .list_item,
            .text = "Inbox",
        },
        .{
            .id = 9,
            .kind = .list_item,
            .text = "Archive",
        },
    };
    const grid_cells = [_]canvas.Widget{
        .{
            .id = 12,
            .kind = .data_cell,
            .text = "Project",
            .layout = .{ .grow = 1 },
        },
        .{
            .id = 13,
            .kind = .data_cell,
            .text = "Status",
            .layout = .{ .grow = 1 },
        },
    };
    const grid_rows = [_]canvas.Widget{.{
        .id = 11,
        .kind = .data_row,
        .children = &grid_cells,
    }};
    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(12, 16, 96, 32),
            .text = "Run",
            .semantics = .{ .label = "Run report" },
        },
        .{
            .id = 3,
            .kind = .text_field,
            .frame = geometry.RectF.init(12, 56, 160, 32),
            .text = "Draft",
            .placeholder = "Report title placeholder",
            .text_selection = canvas.TextSelection{ .anchor = 1, .focus = 4 },
            .state = .{ .focused = true },
            .semantics = .{ .label = "Report title" },
        },
        .{
            .id = 4,
            .kind = .scroll_view,
            .frame = geometry.RectF.init(12, 96, 120, 48),
            .value = 20,
            .semantics = .{ .label = "Mobile scroll" },
            .children = &scroll_children,
        },
        .{
            .id = 7,
            .kind = .list,
            .frame = geometry.RectF.init(160, 16, 120, 68),
            .text = "Mailboxes",
            .layout = .{ .gap = 4 },
            .children = &list_children,
        },
        .{
            .id = 10,
            .kind = .data_grid,
            .frame = geometry.RectF.init(160, 96, 140, 40),
            .text = "Deployments",
            .layout = .{ .gap = 2 },
            .children = &grid_rows,
        },
    };
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{
        .id = 1,
        .kind = .stack,
        .children = &children,
        .semantics = .{ .label = "Mobile canvas widgets" },
    }, geometry.RectF.init(0, 0, 320, 180), &nodes);
    _ = try self.embedded.runtime.setCanvasWidgetLayout(1, mobile_gpu_surface_label, layout);

    try std.testing.expectEqual(@as(usize, 13), native_sdk_app_widget_semantics_count(app));

    var root_node: MobileWidgetSemantics = .{};
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_semantics_at(app, 0, &root_node));
    try std.testing.expectEqual(@as(u64, 1), root_node.id);
    try std.testing.expectEqual(@as(u64, 0), root_node.parent_id);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.group), root_node.role);
    try std.testing.expectEqualStrings("Mobile canvas widgets", root_node.label.?[0..root_node.label_len]);

    var button_node: MobileWidgetSemantics = .{};
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_semantics_at(app, 1, &button_node));
    try std.testing.expectEqual(@as(u64, 2), button_node.id);
    try std.testing.expectEqual(@as(u64, 1), button_node.parent_id);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.button), button_node.role);
    try std.testing.expectEqualStrings("Run report", button_node.label.?[0..button_node.label_len]);
    try std.testing.expect((button_node.flags & @intFromEnum(MobileWidgetFlag.focusable)) != 0);
    try std.testing.expect((button_node.actions & @intFromEnum(MobileWidgetAction.press)) != 0);
    try std.testing.expectEqual(@as(f32, 12), button_node.x);
    try std.testing.expectEqual(@as(f32, 16), button_node.y);
    try std.testing.expectEqual(@as(f32, 96), button_node.width);
    try std.testing.expectEqual(@as(f32, 32), button_node.height);

    var text_node: MobileWidgetSemantics = .{};
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_semantics_at(app, 2, &text_node));
    try std.testing.expectEqual(@as(u64, 3), text_node.id);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.textbox), text_node.role);
    try std.testing.expectEqualStrings("Report title", text_node.label.?[0..text_node.label_len]);
    try std.testing.expectEqualStrings("Draft", text_node.text.?[0..text_node.text_len]);
    try std.testing.expectEqualStrings("Report title placeholder", text_node.placeholder.?[0..text_node.placeholder_len]);
    try std.testing.expectEqual(@as(isize, 1), text_node.text_selection_start);
    try std.testing.expectEqual(@as(isize, 4), text_node.text_selection_end);
    try std.testing.expect((text_node.flags & @intFromEnum(MobileWidgetFlag.focused)) != 0);
    try std.testing.expect((text_node.actions & @intFromEnum(MobileWidgetAction.set_text)) != 0);
    try std.testing.expect((text_node.actions & @intFromEnum(MobileWidgetAction.set_selection)) != 0);

    const scroll_node = try mobileWidgetSemanticsByIdForTest(app, 4);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.group), scroll_node.role);
    try std.testing.expectEqual(@as(c_int, 1), scroll_node.has_scroll);
    try std.testing.expectEqual(@as(f32, 20), scroll_node.scroll_offset);
    try std.testing.expectEqual(@as(f32, 48), scroll_node.scroll_viewport_extent);
    try std.testing.expectEqual(@as(f32, 116), scroll_node.scroll_content_extent);
    try std.testing.expect((scroll_node.actions & @intFromEnum(MobileWidgetAction.increment)) != 0);
    try std.testing.expect((scroll_node.actions & @intFromEnum(MobileWidgetAction.decrement)) != 0);

    native_sdk_app_scroll(app, 11, 24, 112, 0, 14);
    const scrolled_node = try mobileWidgetSemanticsByIdForTest(app, 4);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.scroll, self.last_input_kind);
    try std.testing.expectEqual(@as(u64, 11), self.last_touch_id);
    try std.testing.expectEqual(@as(f32, 14), self.last_touch_delta_y);
    try std.testing.expectEqual(@as(f32, 34), scrolled_node.scroll_offset);
    try std.testing.expectEqual(@as(f32, 48), scrolled_node.scroll_viewport_extent);
    try std.testing.expectEqual(@as(f32, 116), scrolled_node.scroll_content_extent);

    const list_node = try mobileWidgetSemanticsByIdForTest(app, 7);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.list), list_node.role);
    try std.testing.expectEqualStrings("Mailboxes", list_node.label.?[0..list_node.label_len]);
    const archive_node = try mobileWidgetSemanticsByIdForTest(app, 9);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.listitem), archive_node.role);
    try std.testing.expectEqual(@as(u64, 7), archive_node.parent_id);
    try std.testing.expectEqual(@as(isize, 1), archive_node.list_item_index);
    try std.testing.expectEqual(@as(isize, 2), archive_node.list_item_count);
    try std.testing.expect((archive_node.actions & @intFromEnum(MobileWidgetAction.select)) != 0);

    const grid_node = try mobileWidgetSemanticsByIdForTest(app, 10);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.grid), grid_node.role);
    try std.testing.expectEqual(@as(isize, 1), grid_node.grid_row_count);
    try std.testing.expectEqual(@as(isize, 2), grid_node.grid_column_count);
    const status_cell = try mobileWidgetSemanticsByIdForTest(app, 13);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.gridcell), status_cell.role);
    try std.testing.expectEqual(@as(u64, 11), status_cell.parent_id);
    try std.testing.expectEqual(@as(isize, 0), status_cell.grid_row_index);
    try std.testing.expectEqual(@as(isize, 1), status_cell.grid_column_index);
    try std.testing.expectEqual(@as(isize, 1), status_cell.grid_row_count);
    try std.testing.expectEqual(@as(isize, 2), status_cell.grid_column_count);
    try std.testing.expect((status_cell.actions & @intFromEnum(MobileWidgetAction.select)) != 0);

    var text_geometry: MobileWidgetTextGeometry = .{};
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_text_geometry(app, 3, &text_geometry));
    try std.testing.expectEqual(@as(u64, 3), text_geometry.id);
    try std.testing.expectEqual(@as(c_int, 0), text_geometry.has_caret_bounds);
    try std.testing.expectEqual(@as(c_int, 1), text_geometry.has_selection_bounds);
    try std.testing.expectEqual(@as(usize, 1), text_geometry.selection_rect_count);
    try std.testing.expect(text_geometry.selection_width > 0);
    try std.testing.expectEqual(@as(c_int, 0), text_geometry.has_composition_bounds);

    try std.testing.expectEqual(@as(c_int, 0), native_sdk_app_widget_text_geometry(app, 2, &text_geometry));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(native_sdk_app_last_error_name(app)));

    try std.testing.expectEqual(@as(c_int, 0), native_sdk_app_widget_semantics_at(app, 99, &text_node));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(native_sdk_app_last_error_name(app)));

    try expectNoMobileWidgetSemanticsByIdForTest(app, 99);
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(native_sdk_app_last_error_name(app)));
    try expectNoMobileWidgetSemanticsByIdForTest(app, 0);
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(native_sdk_app_last_error_name(app)));
    try std.testing.expectEqual(@as(c_int, 0), native_sdk_app_widget_semantics_by_id(app, 2, null));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(native_sdk_app_last_error_name(app)));
}

test "mobile C ABI maps widget state and dismiss action flags" {
    const expanded_node = canvas.WidgetSemanticsNode{
        .id = 1,
        .role = .button,
        .label = "Menu",
        .bounds = geometry.RectF.init(0, 0, 120, 32),
        .state = .{ .expanded = true, .required = true, .read_only = true, .invalid = true },
        .actions = .{ .dismiss = true },
    };
    try std.testing.expect((mobileWidgetFlags(expanded_node) & @intFromEnum(MobileWidgetFlag.expanded)) != 0);
    try std.testing.expect((mobileWidgetFlags(expanded_node) & @intFromEnum(MobileWidgetFlag.collapsed)) == 0);
    try std.testing.expect((mobileWidgetFlags(expanded_node) & @intFromEnum(MobileWidgetFlag.required)) != 0);
    try std.testing.expect((mobileWidgetFlags(expanded_node) & @intFromEnum(MobileWidgetFlag.read_only)) != 0);
    try std.testing.expect((mobileWidgetFlags(expanded_node) & @intFromEnum(MobileWidgetFlag.invalid)) != 0);
    try std.testing.expect((mobileWidgetActions(expanded_node.actions) & @intFromEnum(MobileWidgetAction.dismiss)) != 0);
    try std.testing.expectEqual(runtime.CanvasWidgetAccessibilityActionKind.dismiss, try mobileWidgetActionKindFromInt(@intFromEnum(MobileWidgetActionKind.dismiss)));

    const collapsed_node = canvas.WidgetSemanticsNode{
        .id = 2,
        .role = .button,
        .label = "Menu",
        .bounds = geometry.RectF.init(0, 0, 120, 32),
        .state = .{ .expanded = false },
    };
    try std.testing.expect((mobileWidgetFlags(collapsed_node) & @intFromEnum(MobileWidgetFlag.collapsed)) != 0);
    try std.testing.expect((mobileWidgetFlags(collapsed_node) & @intFromEnum(MobileWidgetFlag.expanded)) == 0);
}

test "mobile C ABI dispatches GPU widget accessibility actions" {
    const app = native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer native_sdk_app_destroy(app);

    const self = mobileApp(app).?;
    self.null_platform.gpu_surfaces = true;
    native_sdk_app_start(app);
    _ = try self.embedded.runtime.createView(.{
        .window_id = 1,
        .label = mobile_gpu_surface_label,
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 360, 220),
    });

    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(12, 16, 96, 32),
            .text = "Run",
            .command = "widget.run",
            .semantics = .{ .label = "Run report" },
        },
        .{
            .id = 3,
            .kind = .checkbox,
            .frame = geometry.RectF.init(12, 56, 144, 28),
            .text = "Enabled",
        },
        .{
            .id = 4,
            .kind = .slider,
            .frame = geometry.RectF.init(12, 92, 160, 32),
            .value = 0.5,
            .semantics = .{ .label = "Confidence" },
        },
        .{
            .id = 5,
            .kind = .text_field,
            .frame = geometry.RectF.init(12, 136, 180, 32),
            .text = "Draft",
            .semantics = .{ .label = "Report title" },
        },
        .{
            .id = 6,
            .kind = .list_item,
            .frame = geometry.RectF.init(210, 16, 120, 32),
            .text = "Inbox",
        },
        .{
            .id = 7,
            .kind = .button,
            .frame = geometry.RectF.init(210, 56, 120, 32),
            .text = "Drag",
            .semantics = .{ .actions = .{ .drag = true } },
        },
        .{
            .id = 8,
            .kind = .button,
            .frame = geometry.RectF.init(210, 96, 120, 32),
            .text = "Drop",
            .semantics = .{ .actions = .{ .drop_files = true } },
        },
    };
    var nodes: [10]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{
        .id = 1,
        .kind = .panel,
        .children = &children,
        .semantics = .{ .label = "Mobile action widgets" },
    }, geometry.RectF.init(0, 0, 360, 220), &nodes);
    _ = try self.embedded.runtime.setCanvasWidgetLayout(1, mobile_gpu_surface_label, layout);

    var action = MobileWidgetActionRequest{ .id = 2, .action = @intFromEnum(MobileWidgetActionKind.press) };
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_action(app, &action));
    try std.testing.expectEqual(@as(usize, 1), native_sdk_app_last_command_count(app));
    try std.testing.expectEqualStrings("widget.run", std.mem.span(native_sdk_app_last_command_name(app)));
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), self.embedded.runtime.views[0].canvas_widget_focused_id);
    // The press rides the key-driven activation (the automation press
    // verb's route): the surface saw a real enter key_down, so widgets
    // wired through message handlers actuate exactly like commanded
    // ones — a direct-command shortcut would silently no-op for them.
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.key_down, self.last_input_kind);
    try std.testing.expectEqualStrings("enter", self.last_input_key[0..self.last_input_key_len]);

    action = .{ .id = 3, .action = @intFromEnum(MobileWidgetActionKind.toggle) };
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_action(app, &action));
    const checkbox = try mobileWidgetSemanticsByIdForTest(app, 3);
    try std.testing.expectEqual(@as(c_int, 1), checkbox.has_value);
    try std.testing.expectEqual(@as(f32, 1), checkbox.value);
    try std.testing.expect((checkbox.flags & @intFromEnum(MobileWidgetFlag.selected)) != 0);

    action = .{ .id = 4, .action = @intFromEnum(MobileWidgetActionKind.increment) };
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_action(app, &action));
    const slider = try mobileWidgetSemanticsByIdForTest(app, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), slider.value, 0.001);

    const title = "Hello world";
    action = .{
        .id = 5,
        .action = @intFromEnum(MobileWidgetActionKind.set_text),
        .text = title,
        .text_len = title.len,
    };
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_action(app, &action));
    var text_field = try mobileWidgetSemanticsByIdForTest(app, 5);
    try std.testing.expectEqualStrings(title, text_field.text.?[0..text_field.text_len]);
    try std.testing.expectEqual(@as(isize, @intCast(title.len)), text_field.text_selection_start);
    try std.testing.expectEqual(@as(isize, @intCast(title.len)), text_field.text_selection_end);

    const composition = "!";
    action = .{
        .id = 5,
        .action = @intFromEnum(MobileWidgetActionKind.set_composition),
        .text = composition,
        .text_len = composition.len,
    };
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_action(app, &action));
    text_field = try mobileWidgetSemanticsByIdForTest(app, 5);
    try std.testing.expectEqualStrings("Hello world!", text_field.text.?[0..text_field.text_len]);
    try std.testing.expectEqual(@as(isize, @intCast(title.len)), text_field.text_composition_start);
    try std.testing.expectEqual(@as(isize, @intCast(title.len + composition.len)), text_field.text_composition_end);

    action = .{ .id = 5, .action = @intFromEnum(MobileWidgetActionKind.commit_composition) };
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_action(app, &action));
    text_field = try mobileWidgetSemanticsByIdForTest(app, 5);
    try std.testing.expectEqualStrings("Hello world!", text_field.text.?[0..text_field.text_len]);
    try std.testing.expectEqual(@as(isize, -1), text_field.text_composition_start);
    try std.testing.expectEqual(@as(isize, -1), text_field.text_composition_end);

    action = .{
        .id = 5,
        .action = @intFromEnum(MobileWidgetActionKind.set_selection),
        .selection_anchor = 0,
        .selection_focus = 5,
        .has_selection = 1,
    };
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_action(app, &action));
    text_field = try mobileWidgetSemanticsByIdForTest(app, 5);
    try std.testing.expectEqual(@as(isize, 0), text_field.text_selection_start);
    try std.testing.expectEqual(@as(isize, 5), text_field.text_selection_end);

    action = .{ .id = 6, .action = @intFromEnum(MobileWidgetActionKind.select) };
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_action(app, &action));
    const list_item = try mobileWidgetSemanticsByIdForTest(app, 6);
    try std.testing.expectEqual(@as(c_int, 1), list_item.has_value);
    try std.testing.expectEqual(@as(f32, 1), list_item.value);
    try std.testing.expect((list_item.flags & @intFromEnum(MobileWidgetFlag.selected)) != 0);

    const drag_delta = "6 2";
    action = .{
        .id = 7,
        .action = @intFromEnum(MobileWidgetActionKind.drag),
        .text = drag_delta,
        .text_len = drag_delta.len,
    };
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_action(app, &action));
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.pointer_drag, self.last_input_kind);
    try std.testing.expectApproxEqAbs(@as(f32, 276), self.last_touch_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 74), self.last_touch_y, 0.001);

    const drop_paths = "/tmp/mobile-report.csv";
    action = .{
        .id = 8,
        .action = @intFromEnum(MobileWidgetActionKind.drop_files),
        .text = drop_paths,
        .text_len = drop_paths.len,
    };
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_app_widget_action(app, &action));
    try std.testing.expectEqualStrings("drop:files", self.null_platform.lastWindowEventName());
    try std.testing.expect(std.mem.indexOf(u8, self.null_platform.lastWindowEventDetail(), "\"paths\":[\"/tmp/mobile-report.csv\"]") != null);

    action = .{ .id = 99, .action = @intFromEnum(MobileWidgetActionKind.press) };
    try std.testing.expectEqual(@as(c_int, 0), native_sdk_app_widget_action(app, &action));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(native_sdk_app_last_error_name(app)));

    action = .{ .id = 5, .action = @intFromEnum(MobileWidgetActionKind.set_selection) };
    try std.testing.expectEqual(@as(c_int, 0), native_sdk_app_widget_action(app, &action));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(native_sdk_app_last_error_name(app)));

    action = .{ .id = 2, .action = 999 };
    try std.testing.expectEqual(@as(c_int, 0), native_sdk_app_widget_action(app, &action));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(native_sdk_app_last_error_name(app)));
}

// ------------------------------------------------------------- UiApp host
//
// M1 end-to-end: a user UiApp compiled into the embed host answers the same
// C ABI the mobile shims call — create, viewport, host-pumped frames that
// render pixels, touch that mutates the model, and IME text that lands in a
// textbox — with NullPlatform standing in for the (M2) real surface.

const MobileCounterDef = struct {
    pub const Model = struct {
        count: u32 = 0,
        draft: canvas.TextBuffer(64) = .{},
    };

    pub const Msg = union(enum) {
        increment,
        draft_edit: canvas.TextInputEvent,
    };

    const App = runtime.UiApp(Model, Msg);

    pub fn initModel() Model {
        return .{};
    }

    pub fn mobileOptions() App.Options {
        return .{
            .name = "mobile-counter",
            .scene = ui_host.mobile_shell_scene,
            .canvas_label = mobile_gpu_surface_label,
            .update = update,
            .view = view,
        };
    }

    fn update(model: *Model, msg: Msg) void {
        switch (msg) {
            .increment => model.count += 1,
            .draft_edit => |edit| model.draft.apply(edit),
        }
    }

    fn view(ui: *App.Ui, model: *const Model) App.Ui.Node {
        return ui.column(.{ .gap = 8, .padding = 12 }, .{
            ui.text(.{}, ui.fmt("Count {d}", .{model.count})),
            ui.button(.{ .variant = .primary, .on_press = .increment }, "Increment"),
            ui.textField(.{
                .text = model.draft.text(),
                .placeholder = "Note",
                .on_input = App.Ui.inputMsg(.draft_edit),
            }),
        });
    }
};

const MobileCounterHost = ui_host.UiAppHost(MobileCounterDef);
const MobileCounterApi = c_api.MobileCApi(MobileCounterHost);

fn expectNoUiHostError(app: ?*anyopaque) !void {
    try std.testing.expectEqualStrings("", std.mem.span(MobileCounterApi.native_sdk_app_last_error_name(app)));
}

fn findMobileSemanticsByRole(app: ?*anyopaque, role: MobileWidgetRole) !MobileWidgetSemantics {
    const count = MobileCounterApi.native_sdk_app_widget_semantics_count(app);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        var node: MobileWidgetSemantics = .{};
        try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_widget_semantics_at(app, index, &node));
        if (node.role == @intFromEnum(role)) return node;
    }
    return error.TestUnexpectedResult;
}

fn uiHostRetainedTextExists(self: *MobileCounterHost, text: []const u8) !bool {
    const layout = try self.embedded.runtime.canvasWidgetLayout(1, mobile_gpu_surface_label);
    for (layout.nodes) |node| {
        if (node.widget.kind == .text and std.mem.eql(u8, node.widget.text, text)) return true;
    }
    return false;
}

fn tapMobileWidget(app: ?*anyopaque, node: MobileWidgetSemantics) !void {
    const x = node.x + node.width / 2;
    const y = node.y + node.height / 2;
    MobileCounterApi.native_sdk_app_touch(app, 1, 0, x, y, 1);
    try expectNoUiHostError(app);
    MobileCounterApi.native_sdk_app_touch(app, 1, 1, x, y, 0);
    try expectNoUiHostError(app);
}

test "mobile C ABI drives a user UiApp canvas scene end to end" {
    const app = MobileCounterApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileCounterApi.native_sdk_app_destroy(app);
    const self: *MobileCounterHost = @ptrCast(@alignCast(app));

    MobileCounterApi.native_sdk_app_start(app);
    try expectNoUiHostError(app);

    // Host-reported viewport: window and mobile-surface view take the size.
    var surface_token: u8 = 0;
    MobileCounterApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 0, 0, 0, 0, 0, 0, 0, 0);
    try expectNoUiHostError(app);
    var viewport: MobileViewportState = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_viewport_state(app, &viewport));
    try std.testing.expectEqual(@as(f32, 390), viewport.width);
    try std.testing.expectEqual(@as(f32, 844), viewport.height);

    // First host-pumped frame installs the widget tree and presents pixels.
    MobileCounterApi.native_sdk_app_frame(app);
    try expectNoUiHostError(app);
    try std.testing.expect(self.ui.installed);
    try std.testing.expect(try uiHostRetainedTextExists(self, "Count 0"));
    try std.testing.expectEqual(@as(usize, 1), self.null_platform.gpu_surface_present_count);

    // The next frame reports the presented pixels: nonblank with a sample.
    MobileCounterApi.native_sdk_app_frame(app);
    try expectNoUiHostError(app);
    var frame_state: MobileGpuFrameState = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_gpu_frame_state(app, &frame_state));
    try std.testing.expectEqual(@as(f32, 390), frame_state.width);
    try std.testing.expectEqual(@as(f32, 844), frame_state.height);
    try std.testing.expectEqual(@as(c_int, 1), frame_state.nonblank);
    try std.testing.expect(frame_state.sample_color != 0);
    try std.testing.expect(frame_state.widget_node_count > 0);
    try std.testing.expect(frame_state.widget_semantics_count > 0);

    // Pixels are retrievable over the ABI and are not blank.
    var pixel_info: MobileCanvasPixels = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_render_pixel_size(app, 1, &pixel_info));
    try std.testing.expectEqual(@as(usize, 390), pixel_info.width);
    try std.testing.expectEqual(@as(usize, 844), pixel_info.height);
    try std.testing.expectEqual(@as(usize, 390 * 844 * 4), pixel_info.byte_len);
    const pixels = try std.testing.allocator.alloc(u8, pixel_info.byte_len);
    defer std.testing.allocator.free(pixels);
    var rendered: MobileCanvasPixels = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_render_pixels(app, 1, pixels.ptr, pixels.len, &rendered));
    try std.testing.expectEqual(pixel_info.byte_len, rendered.byte_len);
    var nonblank_pixels = false;
    for (pixels) |byte| {
        if (byte != 0) {
            nonblank_pixels = true;
            break;
        }
    }
    try std.testing.expect(nonblank_pixels);

    // Before any input lands nothing is focused: the platform keyboard
    // must stay hidden.
    var text_input: MobileTextInputState = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_text_input_state(app, &text_input));
    try std.testing.expectEqual(@as(c_int, 0), text_input.active);
    try std.testing.expectEqual(@as(u64, 0), text_input.widget_id);

    // A tap on the button (located through the semantics exports) flows
    // through typed dispatch into update + rebuild.
    const button = try findMobileSemanticsByRole(app, .button);
    try std.testing.expect(button.width > 0 and button.height > 0);
    try tapMobileWidget(app, button);
    try std.testing.expectEqual(@as(u32, 1), self.ui.model.count);
    try std.testing.expect(try uiHostRetainedTextExists(self, "Count 1"));
    try std.testing.expectEqual(button.id, (try findMobileSemanticsByRole(app, .button)).id);

    // The button takes focus but is not editable text: still no keyboard.
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_text_input_state(app, &text_input));
    try std.testing.expectEqual(@as(c_int, 0), text_input.active);
    try std.testing.expectEqual(button.id, text_input.widget_id);

    // Tap the textbox to focus it, then type and compose through the same
    // IME path desktop uses; the edits land in the model's text buffer.
    const textbox = try findMobileSemanticsByRole(app, .textbox);
    try tapMobileWidget(app, textbox);

    // Textbox focus is IME intent: the state the shim keys the system
    // keyboard's show/hide on, with the widget's frame for caret tracking.
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_text_input_state(app, &text_input));
    try std.testing.expectEqual(@as(c_int, 1), text_input.active);
    try std.testing.expectEqual(textbox.id, text_input.widget_id);
    try std.testing.expectEqual(textbox.x, text_input.x);
    try std.testing.expectEqual(textbox.y, text_input.y);
    try std.testing.expectEqual(textbox.width, text_input.width);
    try std.testing.expectEqual(textbox.height, text_input.height);
    try std.testing.expectEqual(@as(c_int, 0), MobileCounterApi.native_sdk_app_text_input_state(app, null));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(MobileCounterApi.native_sdk_app_last_error_name(app)));

    MobileCounterApi.native_sdk_app_text(app, "hi", "hi".len);
    try expectNoUiHostError(app);
    try std.testing.expectEqualStrings("hi", self.ui.model.draft.text());
    MobileCounterApi.native_sdk_app_ime(app, 0, "ho", "ho".len, "ho".len);
    try expectNoUiHostError(app);
    MobileCounterApi.native_sdk_app_ime(app, 1, "ho", "ho".len, -1);
    try expectNoUiHostError(app);
    try std.testing.expectEqualStrings("hiho", self.ui.model.draft.text());
    var textbox_after: MobileWidgetSemantics = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_widget_semantics_by_id(app, textbox.id, &textbox_after));
    try std.testing.expectEqualStrings("hiho", textbox_after.text.?[0..textbox_after.text_len]);

    // Tapping the (non-editable) button again moves focus away from the
    // textbox: IME intent clears and the shim hides the keyboard.
    try tapMobileWidget(app, button);
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_text_input_state(app, &text_input));
    try std.testing.expectEqual(@as(c_int, 0), text_input.active);
    try std.testing.expectEqual(button.id, text_input.widget_id);

    // The model-driven UI keeps presenting through host-pumped frames.
    MobileCounterApi.native_sdk_app_frame(app);
    try expectNoUiHostError(app);
    try std.testing.expect(self.null_platform.gpu_surface_present_count >= 2);
}

test "mobile UiApp host insets widget layout by safe-area and keyboard viewport chrome" {
    const app = MobileCounterApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileCounterApi.native_sdk_app_destroy(app);

    MobileCounterApi.native_sdk_app_start(app);
    try expectNoUiHostError(app);

    // Portrait with a notch and home indicator: widget layout starts below
    // the top inset and ends above the bottom one while the canvas itself
    // keeps the full surface size (chrome/clear paint edge to edge).
    var surface_token: u8 = 0;
    MobileCounterApi.native_sdk_app_viewport(app, 390, 844, 3, &surface_token, 59, 0, 34, 0, 0, 0, 0, 0);
    MobileCounterApi.native_sdk_app_frame(app);
    try expectNoUiHostError(app);

    var root: MobileWidgetSemantics = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_widget_semantics_at(app, 0, &root));
    try std.testing.expectEqual(@as(f32, 0), root.x);
    try std.testing.expectEqual(@as(f32, 59), root.y);
    try std.testing.expectEqual(@as(f32, 390), root.width);
    try std.testing.expectEqual(@as(f32, 844 - 59 - 34), root.height);
    const button = try findMobileSemanticsByRole(app, .button);
    try std.testing.expect(button.y >= 59);

    // The canvas stays surface-sized and device pixels honor the viewport
    // scale end to end: 390x844 points at 3x renders 1170x2532 pixels.
    var frame_state: MobileGpuFrameState = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_gpu_frame_state(app, &frame_state));
    try std.testing.expectEqual(@as(f32, 390), frame_state.width);
    try std.testing.expectEqual(@as(f32, 844), frame_state.height);
    try std.testing.expectEqual(@as(f32, 3), frame_state.scale);
    var pixel_info: MobileCanvasPixels = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_render_pixel_size(app, 3, &pixel_info));
    try std.testing.expectEqual(@as(usize, 1170), pixel_info.width);
    try std.testing.expectEqual(@as(usize, 2532), pixel_info.height);

    // Rotation: landscape swaps the size and moves the notch to the sides;
    // the viewport resize relayouts against the new insets.
    MobileCounterApi.native_sdk_app_viewport(app, 844, 390, 3, &surface_token, 0, 59, 21, 59, 0, 0, 0, 0);
    MobileCounterApi.native_sdk_app_frame(app);
    try expectNoUiHostError(app);
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_widget_semantics_at(app, 0, &root));
    try std.testing.expectEqual(@as(f32, 59), root.x);
    try std.testing.expectEqual(@as(f32, 0), root.y);
    try std.testing.expectEqual(@as(f32, 844 - 59 - 59), root.width);
    try std.testing.expectEqual(@as(f32, 390 - 21), root.height);

    // System keyboard: its inset combines edge-wise with the safe areas so
    // content is laid out above it.
    MobileCounterApi.native_sdk_app_viewport(app, 390, 844, 3, &surface_token, 59, 0, 34, 0, 0, 0, 336, 0);
    MobileCounterApi.native_sdk_app_frame(app);
    try expectNoUiHostError(app);
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_widget_semantics_at(app, 0, &root));
    try std.testing.expectEqual(@as(f32, 59), root.y);
    try std.testing.expectEqual(@as(f32, 844 - 59 - 336), root.height);

    // Removing the insets restores the desktop-identical full-bounds
    // layout (desktop surfaces report zero insets, so this is the layout
    // golden tests cover).
    MobileCounterApi.native_sdk_app_viewport(app, 390, 844, 3, &surface_token, 0, 0, 0, 0, 0, 0, 0, 0);
    MobileCounterApi.native_sdk_app_frame(app);
    try expectNoUiHostError(app);
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_widget_semantics_at(app, 0, &root));
    try std.testing.expectEqual(@as(f32, 0), root.x);
    try std.testing.expectEqual(@as(f32, 0), root.y);
    try std.testing.expectEqual(@as(f32, 390), root.width);
    try std.testing.expectEqual(@as(f32, 844), root.height);
}

// Chrome-subscribed app: `on_chrome` maps the window-chrome channel into
// the model, and the view pads by the delivered insets — the identical
// code path a desktop hidden-titlebar app pads its header with.
const MobileChromeDef = struct {
    pub const Model = struct {
        chrome: platform.WindowChrome = .{},
        chrome_deliveries: u32 = 0,
    };

    pub const Msg = union(enum) {
        chrome_changed: platform.WindowChrome,
    };

    const App = runtime.UiApp(Model, Msg);

    pub fn initModel() Model {
        return .{};
    }

    pub fn mobileOptions() App.Options {
        return .{
            .name = "mobile-chrome",
            .scene = ui_host.mobile_shell_scene,
            .canvas_label = mobile_gpu_surface_label,
            .update = update,
            .view = view,
            .on_chrome = onChrome,
        };
    }

    fn onChrome(chrome: platform.WindowChrome) ?Msg {
        return .{ .chrome_changed = chrome };
    }

    fn update(model: *Model, msg: Msg) void {
        switch (msg) {
            .chrome_changed => |chrome| {
                model.chrome = chrome;
                model.chrome_deliveries += 1;
            },
        }
    }

    fn view(ui: *App.Ui, model: *const Model) App.Ui.Node {
        // Fixed-height bands sized by the delivered chrome stand in for
        // the safe-area padding a real app derives the same way.
        return ui.column(.{}, .{
            ui.el(.column, .{ .height = model.chrome.insets.top }, .{}),
            ui.text(.{}, "Safe content"),
            ui.spacer(1),
            ui.el(.column, .{ .height = model.chrome.insets.bottom }, .{}),
        });
    }
};

const MobileChromeHost = ui_host.UiAppHost(MobileChromeDef);
const MobileChromeApi = c_api.MobileCApi(MobileChromeHost);

test "mobile UiApp host delivers safe areas through the window-chrome channel" {
    const app = MobileChromeApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileChromeApi.native_sdk_app_destroy(app);
    const self: *MobileChromeHost = @ptrCast(@alignCast(app));

    MobileChromeApi.native_sdk_app_start(app);
    try std.testing.expectEqualStrings("", std.mem.span(MobileChromeApi.native_sdk_app_last_error_name(app)));

    // Portrait with a notch and home indicator: the chrome Msg arrives
    // before the first view build carrying exactly the safe-area insets,
    // and — because the app subscribed — widget layout keeps the FULL
    // surface bounds (the app's own padding is the inset now).
    var surface_token: u8 = 0;
    MobileChromeApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 59, 0, 34, 0, 0, 0, 0, 0);
    MobileChromeApi.native_sdk_app_frame(app);
    try std.testing.expectEqualStrings("", std.mem.span(MobileChromeApi.native_sdk_app_last_error_name(app)));
    try std.testing.expectEqual(@as(f32, 59), self.ui.model.chrome.insets.top);
    try std.testing.expectEqual(@as(f32, 34), self.ui.model.chrome.insets.bottom);
    try std.testing.expectEqual(@as(f32, 0), self.ui.model.chrome.insets.left);
    const deliveries_after_install = self.ui.model.chrome_deliveries;
    try std.testing.expect(deliveries_after_install >= 1);

    var root: MobileWidgetSemantics = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileChromeApi.native_sdk_app_widget_semantics_at(app, 0, &root));
    try std.testing.expectEqual(@as(f32, 0), root.x);
    try std.testing.expectEqual(@as(f32, 0), root.y);
    try std.testing.expectEqual(@as(f32, 390), root.width);
    try std.testing.expectEqual(@as(f32, 844), root.height);

    // The view's model-derived padding places content below the notch —
    // the app-owned equivalent of the unsubscribed automatic inset.
    const text = try mobileChromeSemanticsByRole(app, .text);
    try std.testing.expect(text.y >= 59);

    // An identical viewport re-report does not re-deliver (change-gated,
    // same dedupe the macOS fullscreen transitions rely on).
    MobileChromeApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 59, 0, 34, 0, 0, 0, 0, 0);
    MobileChromeApi.native_sdk_app_frame(app);
    try std.testing.expectEqual(deliveries_after_install, self.ui.model.chrome_deliveries);

    // The keyboard is not chrome: it must not change the report, and the
    // runtime keeps insetting layout by its residual overlap beyond the
    // app-owned safe area (336 keyboard - 34 home indicator = 302).
    MobileChromeApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 59, 0, 34, 0, 0, 0, 336, 0);
    MobileChromeApi.native_sdk_app_frame(app);
    try std.testing.expectEqual(@as(f32, 34), self.ui.model.chrome.insets.bottom);
    try std.testing.expectEqual(deliveries_after_install, self.ui.model.chrome_deliveries);
    try std.testing.expectEqual(@as(c_int, 1), MobileChromeApi.native_sdk_app_widget_semantics_at(app, 0, &root));
    try std.testing.expectEqual(@as(f32, 0), root.y);
    try std.testing.expectEqual(@as(f32, 844 - 302), root.height);

    // Rotation moves the notch to the sides: one new delivery with the
    // landscape insets.
    MobileChromeApi.native_sdk_app_viewport(app, 844, 390, 1, &surface_token, 0, 59, 21, 59, 0, 0, 0, 0);
    MobileChromeApi.native_sdk_app_frame(app);
    try std.testing.expectEqual(deliveries_after_install + 1, self.ui.model.chrome_deliveries);
    try std.testing.expectEqual(@as(f32, 0), self.ui.model.chrome.insets.top);
    try std.testing.expectEqual(@as(f32, 59), self.ui.model.chrome.insets.left);
    try std.testing.expectEqual(@as(f32, 59), self.ui.model.chrome.insets.right);
    try std.testing.expectEqual(@as(f32, 21), self.ui.model.chrome.insets.bottom);
}

test "android-shaped insets ride the same viewport and chrome contracts" {
    // The chrome channel and keyboard residual are host-agnostic: the
    // Android host reports status-bar/cutout/gesture-nav bands as the
    // safe area and the IME inset as the keyboard, in density-independent
    // points, exactly like the iOS host reports notch and home-indicator
    // bands — pinned here with Android-shaped geometry (412x915 @2.625,
    // 28pt status band over a cutout, 24pt gesture nav, 322pt IME).
    var surface_token: u8 = 0;

    // Unsubscribed app: the automatic runtime inset keeps layout clear of
    // the bands and combines the keyboard edge-wise, byte-identically to
    // the iOS-shaped run above.
    const counter_app = MobileCounterApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileCounterApi.native_sdk_app_destroy(counter_app);
    MobileCounterApi.native_sdk_app_start(counter_app);
    MobileCounterApi.native_sdk_app_viewport(counter_app, 412, 915, 2.625, &surface_token, 28, 0, 24, 0, 0, 0, 0, 0);
    MobileCounterApi.native_sdk_app_frame(counter_app);
    try expectNoUiHostError(counter_app);
    var root: MobileWidgetSemantics = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_widget_semantics_at(counter_app, 0, &root));
    try std.testing.expectEqual(@as(f32, 28), root.y);
    try std.testing.expectEqual(@as(f32, 915 - 28 - 24), root.height);
    MobileCounterApi.native_sdk_app_viewport(counter_app, 412, 915, 2.625, &surface_token, 28, 0, 24, 0, 0, 0, 322, 0);
    MobileCounterApi.native_sdk_app_frame(counter_app);
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_widget_semantics_at(counter_app, 0, &root));
    try std.testing.expectEqual(@as(f32, 915 - 28 - 322), root.height);

    // Chrome-subscribed app: the safe area arrives over the window-chrome
    // channel, the IME stays out of the report, and the runtime insets
    // layout by the keyboard's residual overlap beyond the app-owned
    // gesture-nav band (322 - 24 = 298).
    const chrome_app = MobileChromeApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileChromeApi.native_sdk_app_destroy(chrome_app);
    const chrome_self: *MobileChromeHost = @ptrCast(@alignCast(chrome_app));
    MobileChromeApi.native_sdk_app_start(chrome_app);
    MobileChromeApi.native_sdk_app_viewport(chrome_app, 412, 915, 2.625, &surface_token, 28, 0, 24, 0, 0, 0, 322, 0);
    MobileChromeApi.native_sdk_app_frame(chrome_app);
    try std.testing.expectEqual(@as(f32, 28), chrome_self.ui.model.chrome.insets.top);
    try std.testing.expectEqual(@as(f32, 24), chrome_self.ui.model.chrome.insets.bottom);
    try std.testing.expectEqual(@as(c_int, 1), MobileChromeApi.native_sdk_app_widget_semantics_at(chrome_app, 0, &root));
    try std.testing.expectEqual(@as(f32, 0), root.y);
    try std.testing.expectEqual(@as(f32, 915 - 298), root.height);

    // Rotation with a corner cutout: landscape moves the cutout band to
    // one side only (Android reports asymmetric cutout insets).
    MobileChromeApi.native_sdk_app_viewport(chrome_app, 915, 412, 2.625, &surface_token, 0, 0, 24, 28, 0, 0, 0, 0);
    MobileChromeApi.native_sdk_app_frame(chrome_app);
    try std.testing.expectEqual(@as(f32, 28), chrome_self.ui.model.chrome.insets.left);
    try std.testing.expectEqual(@as(f32, 0), chrome_self.ui.model.chrome.insets.right);
    try std.testing.expectEqual(@as(f32, 24), chrome_self.ui.model.chrome.insets.bottom);
}

fn mobileChromeSemanticsByRole(app: ?*anyopaque, role: MobileWidgetRole) !MobileWidgetSemantics {
    const count = MobileChromeApi.native_sdk_app_widget_semantics_count(app);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        var node: MobileWidgetSemantics = .{};
        try std.testing.expectEqual(@as(c_int, 1), MobileChromeApi.native_sdk_app_widget_semantics_at(app, index, &node));
        if (node.role == @intFromEnum(role)) return node;
    }
    return error.TestUnexpectedResult;
}

/// Fake shim text measurement: every UTF-8 byte is `size` wide — far wider
/// than any estimator advance factor (max 0.91), so measured layout
/// visibly diverges from the estimator baseline. Counts calls through the
/// context pointer to prove the provider (not the estimator) measured.
fn fakeMobileMeasureText(context: ?*anyopaque, font_id: u64, size: f64, text: ?[*]const u8, text_len: usize) callconv(.c) f64 {
    _ = font_id;
    _ = text;
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    return size * @as(f64, @floatFromInt(text_len));
}

// Row-based view: a row child's main-axis extent is its intrinsic width,
// which goes through the tokens' text-measure seam — so a registered
// provider directly changes the text widget's laid-out bounds.
const MobileMeasureDef = struct {
    pub const Model = struct { pressed: u32 = 0 };

    pub const Msg = union(enum) { press };

    const App = runtime.UiApp(Model, Msg);

    pub fn initModel() Model {
        return .{};
    }

    pub fn mobileOptions() App.Options {
        return .{
            .name = "mobile-measure",
            .scene = ui_host.mobile_shell_scene,
            .canvas_label = mobile_gpu_surface_label,
            .update = update,
            .view = view,
        };
    }

    fn update(model: *Model, msg: Msg) void {
        switch (msg) {
            .press => model.pressed += 1,
        }
    }

    fn view(ui: *App.Ui, model: *const Model) App.Ui.Node {
        _ = model;
        return ui.row(.{ .gap = 8, .padding = 12 }, .{
            ui.text(.{}, "Measured run"),
            ui.button(.{ .on_press = .press }, "OK"),
        });
    }
};

const MobileMeasureApi = c_api.MobileCApi(ui_host.UiAppHost(MobileMeasureDef));

fn measureTestTextWidth(app: ?*anyopaque) !f32 {
    const count = MobileMeasureApi.native_sdk_app_widget_semantics_count(app);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        var node: MobileWidgetSemantics = .{};
        try std.testing.expectEqual(@as(c_int, 1), MobileMeasureApi.native_sdk_app_widget_semantics_at(app, index, &node));
        if (node.role == @intFromEnum(MobileWidgetRole.text)) return node.width;
    }
    return error.TestUnexpectedResult;
}

test "mobile C ABI text measure provider changes embed text layout" {
    var surface_token: u8 = 0;

    // Baseline: no provider, deterministic estimator metrics.
    const baseline_app = MobileMeasureApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    MobileMeasureApi.native_sdk_app_start(baseline_app);
    MobileMeasureApi.native_sdk_app_viewport(baseline_app, 390, 844, 1, &surface_token, 0, 0, 0, 0, 0, 0, 0, 0);
    MobileMeasureApi.native_sdk_app_frame(baseline_app);
    const baseline_width = try measureTestTextWidth(baseline_app);
    try std.testing.expect(baseline_width > 0);
    MobileMeasureApi.native_sdk_app_destroy(baseline_app);

    // Registering a measure callback before start makes the installing
    // layout measure through it: the text widget's bounds change.
    const app = MobileMeasureApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileMeasureApi.native_sdk_app_destroy(app);
    const self: *ui_host.UiAppHost(MobileMeasureDef) = @ptrCast(@alignCast(app));
    var measure_calls: usize = 0;
    try std.testing.expectEqual(@as(c_int, 1), MobileMeasureApi.native_sdk_app_set_text_measure(app, fakeMobileMeasureText, &measure_calls));
    try std.testing.expect(self.embedded.runtime.textMeasureProvider() != null);
    MobileMeasureApi.native_sdk_app_start(app);
    MobileMeasureApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 0, 0, 0, 0, 0, 0, 0, 0);
    MobileMeasureApi.native_sdk_app_frame(app);
    try std.testing.expect(measure_calls > 0);
    const measured_width = try measureTestTextWidth(app);
    try std.testing.expect(measured_width > baseline_width);
    // "Measured run" is 12 bytes at one `size` per byte; the estimator's
    // widest advance factor is 0.91, so the fake at least ~10% wider.
    try std.testing.expect(measured_width >= baseline_width * 1.1);

    // Clearing the callback falls back to the estimator on the next
    // rebuild (a viewport resize here): baseline layout returns. The
    // runtime-side provider stays installed — retained display-list
    // commands carry its pointer for the runtime's lifetime — but the
    // bridge reports no measurement, which is the estimator path.
    try std.testing.expectEqual(@as(c_int, 1), MobileMeasureApi.native_sdk_app_set_text_measure(app, null, null));
    try std.testing.expect(self.embedded.runtime.textMeasureProvider() != null);
    MobileMeasureApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 0, 0, 0, 0, 0, 0, 0, 0);
    MobileMeasureApi.native_sdk_app_frame(app);
    const restored_width = try measureTestTextWidth(app);
    try std.testing.expectEqual(baseline_width, restored_width);
}

test "mobile C ABI publishes automation snapshots into a host-set directory" {
    const app = MobileCounterApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileCounterApi.native_sdk_app_destroy(app);
    const self: *MobileCounterHost = @ptrCast(@alignCast(app));

    const dir = ".zig-cache/test-mobile-embed-automation";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    MobileCounterApi.native_sdk_app_start(app);
    try expectNoUiHostError(app);
    try std.testing.expectEqual(@as(c_int, 0), MobileCounterApi.native_sdk_app_set_automation_dir(app, "", 0));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(MobileCounterApi.native_sdk_app_last_error_name(app)));
    try std.testing.expectEqual(@as(c_int, 1), MobileCounterApi.native_sdk_app_set_automation_dir(app, dir, dir.len));
    try expectNoUiHostError(app);
    try std.testing.expect(self.embedded.runtime.options.automation != null);

    var surface_token: u8 = 0;
    MobileCounterApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 0, 0, 0, 0, 0, 0, 0, 0);
    MobileCounterApi.native_sdk_app_frame(app);
    try expectNoUiHostError(app);

    var buffer: [16 * 1024]u8 = undefined;
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, dir ++ "/snapshot.txt", .{});
    defer file.close(std.testing.io);
    const snapshot = buffer[0..try file.readPositionalAll(std.testing.io, &buffer, 0)];
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "mobile-surface") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Increment") != null);
}

test "mobile C ABI dispatches native commands through embedded runtime" {
    const app = native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer native_sdk_app_destroy(app);

    native_sdk_app_command(app, "mobile.refresh", "mobile.refresh".len);
    try std.testing.expectEqual(@as(usize, 1), native_sdk_app_last_command_count(app));
    try std.testing.expectEqualStrings("mobile.refresh", std.mem.span(native_sdk_app_last_command_name(app)));
    try std.testing.expectEqualStrings("", std.mem.span(native_sdk_app_last_error_name(app)));

    native_sdk_app_command(app, "", 0);
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(native_sdk_app_last_error_name(app)));

    native_sdk_app_command(app, "mobile.open", "mobile.open".len);
    try std.testing.expectEqual(@as(usize, 2), native_sdk_app_last_command_count(app));
    try std.testing.expectEqualStrings("mobile.open", std.mem.span(native_sdk_app_last_command_name(app)));
    try std.testing.expectEqualStrings("", std.mem.span(native_sdk_app_last_error_name(app)));
}

// ------------------------------------------------------------ audio service
//
// The embed audio seam end to end: hosts decline audio until the shim
// registers a real service (`native_sdk_app_set_audio_service`), a
// registered callback table receives the fx.playAudio family through the
// same PlatformServices seam AVAudioPlayer serves on macOS, and shim
// reports (`native_sdk_app_audio_event`) land as the app's `on_event` Msg
// with the runtime's playback mirrors updated. A position report with
// playing=0 is the exact shape the iOS host emits from an audio-session
// interruption, so its state flip is pinned here.

const MobileAudioDef = struct {
    pub const Model = struct {
        event_count: usize = 0,
        last_kind: ?runtime.EffectAudioEventKind = null,
        last_position_ms: u64 = 0,
        last_duration_ms: u64 = 0,
        last_playing: bool = false,
        last_buffering: bool = false,
    };

    pub const Msg = union(enum) {
        play,
        play_stream,
        pause,
        seek,
        quiet,
        audio_event: runtime.EffectAudio,
    };

    const App = runtime.UiApp(Model, Msg);

    pub fn initModel() Model {
        return .{};
    }

    pub fn mobileOptions() App.Options {
        return .{
            .name = "mobile-audio",
            .scene = ui_host.mobile_shell_scene,
            .canvas_label = mobile_gpu_surface_label,
            .update_fx = update,
            .view = view,
        };
    }

    fn update(model: *Model, msg: Msg, fx: *App.Effects) void {
        switch (msg) {
            .play => fx.playAudio(.{
                .key = 7,
                .path = "/tmp/mobile-audio-track.mp3",
                .on_event = App.Effects.audioMsg(.audio_event),
            }),
            .play_stream => fx.playAudio(.{
                .key = 8,
                .url = "https://music.example.test/pack/track.mp3",
                .cache_path = "/tmp/mobile-audio-caches/audio/track.mp3",
                .expected_bytes = 2_048,
                .on_event = App.Effects.audioMsg(.audio_event),
            }),
            .pause => fx.pauseAudio(),
            .seek => fx.seekAudio(12_000),
            .quiet => fx.setAudioVolume(0.25),
            .audio_event => |event| {
                model.event_count += 1;
                model.last_kind = event.kind;
                model.last_position_ms = event.position_ms;
                model.last_duration_ms = event.duration_ms;
                model.last_playing = event.playing;
                model.last_buffering = event.buffering;
            },
        }
    }

    fn view(ui: *App.Ui, model: *const Model) App.Ui.Node {
        return ui.column(.{ .gap = 8, .padding = 12 }, .{
            ui.text(.{}, ui.fmt("{d} events", .{model.event_count})),
            ui.button(.{ .on_press = .play }, "Play"),
            ui.button(.{ .on_press = .play_stream }, "Stream"),
            ui.button(.{ .on_press = .pause }, "Pause"),
            ui.button(.{ .on_press = .seek }, "Seek"),
            ui.button(.{ .on_press = .quiet }, "Quiet"),
        });
    }
};

const MobileAudioHost = ui_host.UiAppHost(MobileAudioDef);
const MobileAudioApi = c_api.MobileCApi(MobileAudioHost);

/// What the fake shim service records — the mobile mirror of the null
/// platform's call counters, held by the test and reached through the
/// registered context pointer.
const MobileAudioRecorder = struct {
    load_count: usize = 0,
    load_url_count: usize = 0,
    play_count: usize = 0,
    pause_count: usize = 0,
    stop_count: usize = 0,
    seek_count: usize = 0,
    volume_count: usize = 0,
    last_path: [256]u8 = undefined,
    last_path_len: usize = 0,
    last_url: [256]u8 = undefined,
    last_url_len: usize = 0,
    last_cache_path: [256]u8 = undefined,
    last_cache_path_len: usize = 0,
    last_expected_bytes: u64 = 0,
    last_seek_ms: u64 = 0,
    last_volume: f64 = 1.0,
    load_result: c_int = 0,
    load_url_result: c_int = 0,

    fn from(context: ?*anyopaque) *MobileAudioRecorder {
        return @ptrCast(@alignCast(context.?));
    }
};

fn recorderAudioLoad(context: ?*anyopaque, path: ?[*]const u8, path_len: usize) callconv(.c) c_int {
    const recorder = MobileAudioRecorder.from(context);
    recorder.load_count += 1;
    recorder.last_path_len = conversions.copyInputText(&recorder.last_path, if (path) |value| value[0..path_len] else "");
    return recorder.load_result;
}

fn recorderAudioLoadUrl(context: ?*anyopaque, url: ?[*]const u8, url_len: usize, cache_path: ?[*]const u8, cache_path_len: usize, expected_bytes: u64) callconv(.c) c_int {
    const recorder = MobileAudioRecorder.from(context);
    recorder.load_url_count += 1;
    recorder.last_url_len = conversions.copyInputText(&recorder.last_url, if (url) |value| value[0..url_len] else "");
    recorder.last_cache_path_len = conversions.copyInputText(&recorder.last_cache_path, if (cache_path) |value| value[0..cache_path_len] else "");
    recorder.last_expected_bytes = expected_bytes;
    return recorder.load_url_result;
}

fn recorderAudioPlay(context: ?*anyopaque) callconv(.c) c_int {
    MobileAudioRecorder.from(context).play_count += 1;
    return 1;
}

fn recorderAudioPause(context: ?*anyopaque) callconv(.c) c_int {
    MobileAudioRecorder.from(context).pause_count += 1;
    return 1;
}

fn recorderAudioStop(context: ?*anyopaque) callconv(.c) c_int {
    MobileAudioRecorder.from(context).stop_count += 1;
    return 1;
}

fn recorderAudioSeek(context: ?*anyopaque, position_ms: u64) callconv(.c) c_int {
    const recorder = MobileAudioRecorder.from(context);
    recorder.seek_count += 1;
    recorder.last_seek_ms = position_ms;
    return 1;
}

fn recorderAudioSetVolume(context: ?*anyopaque, volume: f64) callconv(.c) c_int {
    const recorder = MobileAudioRecorder.from(context);
    recorder.volume_count += 1;
    recorder.last_volume = volume;
    return 1;
}

fn recorderAudioService() types.MobileAudioService {
    return .{
        .load = recorderAudioLoad,
        .load_url = recorderAudioLoadUrl,
        .play = recorderAudioPlay,
        .pause = recorderAudioPause,
        .stop = recorderAudioStop,
        .seek = recorderAudioSeek,
        .set_volume = recorderAudioSetVolume,
    };
}

fn pressAudioButton(app: ?*anyopaque, label: []const u8) !void {
    const count = MobileAudioApi.native_sdk_app_widget_semantics_count(app);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        var node: MobileWidgetSemantics = .{};
        try std.testing.expectEqual(@as(c_int, 1), MobileAudioApi.native_sdk_app_widget_semantics_at(app, index, &node));
        if (node.role != @intFromEnum(MobileWidgetRole.button)) continue;
        const node_label = if (node.label) |ptr| ptr[0..node.label_len] else "";
        if (!std.mem.eql(u8, node_label, label)) continue;
        // A synthesized tap at the button's center — the same touch path
        // the shim forwards — flows through typed dispatch into update.
        const x = node.x + node.width / 2;
        const y = node.y + node.height / 2;
        MobileAudioApi.native_sdk_app_touch(app, 1, 0, x, y, 1);
        MobileAudioApi.native_sdk_app_touch(app, 1, 1, x, y, 0);
        try std.testing.expectEqualStrings("", std.mem.span(MobileAudioApi.native_sdk_app_last_error_name(app)));
        return;
    }
    return error.TestUnexpectedResult;
}

fn startAudioHost(app: ?*anyopaque) !void {
    MobileAudioApi.native_sdk_app_start(app);
    var surface_token: u8 = 0;
    MobileAudioApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 0, 0, 0, 0, 0, 0, 0, 0);
    MobileAudioApi.native_sdk_app_frame(app);
    try std.testing.expectEqualStrings("", std.mem.span(MobileAudioApi.native_sdk_app_last_error_name(app)));
}

test "mobile hosts decline audio until the shim registers a service" {
    const app = MobileAudioApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileAudioApi.native_sdk_app_destroy(app);
    const self: *MobileAudioHost = @ptrCast(@alignCast(app));

    // No registered service: the capability answers are honest noes and
    // the runtime's service table carries no audio entries.
    try std.testing.expect(!self.embedded.runtime.options.platform.supports(.audio_playback));
    try std.testing.expect(!self.embedded.runtime.options.platform.supports(.audio_streaming));
    try std.testing.expect(self.embedded.runtime.options.platform.services.audio_load_fn == null);

    try startAudioHost(app);

    // fx.playAudio degrades to exactly one explicit failed Msg (delivered
    // on the next effects drain — a pumped frame), never silence.
    try pressAudioButton(app, "Play");
    MobileAudioApi.native_sdk_app_frame(app);
    try std.testing.expectEqual(@as(usize, 1), self.ui.model.event_count);
    try std.testing.expectEqual(runtime.EffectAudioEventKind.failed, self.ui.model.last_kind.?);

    // Audio events from a shim that never registered still resolve
    // against an idle channel: swallowed without error, no Msg.
    MobileAudioApi.native_sdk_app_audio_event(app, 1, 500, 30_000, 1, 0);
    try std.testing.expectEqual(@as(usize, 1), self.ui.model.event_count);
}

test "mobile audio service bridges effects out and events back" {
    const app = MobileAudioApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileAudioApi.native_sdk_app_destroy(app);
    const self: *MobileAudioHost = @ptrCast(@alignCast(app));

    var recorder = MobileAudioRecorder{};
    const service = recorderAudioService();
    try std.testing.expectEqual(@as(c_int, 1), MobileAudioApi.native_sdk_app_set_audio_service(app, &service, &recorder));
    try std.testing.expect(self.embedded.runtime.options.platform.supports(.audio_playback));
    try std.testing.expect(self.embedded.runtime.options.platform.supports(.audio_streaming));

    try startAudioHost(app);

    // playAudio resolves the local path through the registered load and
    // starts the transport through play.
    try pressAudioButton(app, "Play");
    try std.testing.expectEqual(@as(usize, 1), recorder.load_count);
    try std.testing.expectEqualStrings("/tmp/mobile-audio-track.mp3", recorder.last_path[0..recorder.last_path_len]);
    try std.testing.expectEqual(@as(usize, 1), recorder.play_count);

    // The shim's loaded acknowledgment lands as the app's on_event Msg
    // with the real decoded duration.
    MobileAudioApi.native_sdk_app_audio_event(app, 0, 0, 30_000, 1, 0);
    try std.testing.expectEqual(@as(usize, 1), self.ui.model.event_count);
    try std.testing.expectEqual(runtime.EffectAudioEventKind.loaded, self.ui.model.last_kind.?);
    try std.testing.expectEqual(@as(u64, 30_000), self.ui.model.last_duration_ms);

    // Position ticks update the model and the runtime's honest mirrors.
    MobileAudioApi.native_sdk_app_audio_event(app, 1, 1_500, 30_000, 1, 0);
    try std.testing.expectEqual(runtime.EffectAudioEventKind.position, self.ui.model.last_kind.?);
    try std.testing.expectEqual(@as(u64, 1_500), self.ui.model.last_position_ms);
    try std.testing.expect(self.ui.model.last_playing);
    try std.testing.expect(self.ui.effects.audioSnapshot().playing);

    // A position report with playing=0 is the audio-session interruption
    // shape the iOS host emits (the OS paused the route): the app and the
    // playback mirrors flip to paused, honestly, without a pause command.
    MobileAudioApi.native_sdk_app_audio_event(app, 1, 2_000, 30_000, 0, 0);
    try std.testing.expect(!self.ui.model.last_playing);
    try std.testing.expect(!self.ui.effects.audioSnapshot().playing);
    try std.testing.expectEqual(@as(usize, 0), recorder.pause_count);

    // Transport commands reach the service: pause, seek, volume.
    try pressAudioButton(app, "Pause");
    try std.testing.expectEqual(@as(usize, 1), recorder.pause_count);
    try pressAudioButton(app, "Seek");
    try std.testing.expectEqual(@as(usize, 1), recorder.seek_count);
    try std.testing.expectEqual(@as(u64, 12_000), recorder.last_seek_ms);
    try pressAudioButton(app, "Quiet");
    try std.testing.expectEqual(@as(usize, 1), recorder.volume_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), recorder.last_volume, 0.0001);

    // Exactly one completion at natural end, carrying the terminal
    // position.
    MobileAudioApi.native_sdk_app_audio_event(app, 2, 30_000, 30_000, 0, 0);
    try std.testing.expectEqual(runtime.EffectAudioEventKind.completed, self.ui.model.last_kind.?);
    try std.testing.expectEqual(@as(u64, 30_000), self.ui.model.last_position_ms);
    try std.testing.expect(!self.ui.effects.audioSnapshot().playing);
    try std.testing.expectEqual(@as(u64, 30_000), self.ui.effects.audioSnapshot().position_ms);

    // An out-of-range event kind is refused loudly.
    MobileAudioApi.native_sdk_app_audio_event(app, 9, 0, 0, 0, 0);
    try std.testing.expectEqualStrings("InvalidAudioOptions", std.mem.span(MobileAudioApi.native_sdk_app_last_error_name(app)));
}

test "mobile audio streams resolve through the registered load_url" {
    const app = MobileAudioApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileAudioApi.native_sdk_app_destroy(app);
    const self: *MobileAudioHost = @ptrCast(@alignCast(app));

    var recorder = MobileAudioRecorder{};
    const service = recorderAudioService();
    try std.testing.expectEqual(@as(c_int, 1), MobileAudioApi.native_sdk_app_set_audio_service(app, &service, &recorder));
    try startAudioHost(app);

    // load_url answering 0 is a started stream: buffering starts true
    // optimistically until the loaded acknowledgment.
    try pressAudioButton(app, "Stream");
    try std.testing.expectEqual(@as(usize, 1), recorder.load_url_count);
    try std.testing.expectEqualStrings("https://music.example.test/pack/track.mp3", recorder.last_url[0..recorder.last_url_len]);
    try std.testing.expectEqualStrings("/tmp/mobile-audio-caches/audio/track.mp3", recorder.last_cache_path[0..recorder.last_cache_path_len]);
    try std.testing.expectEqual(@as(u64, 2_048), recorder.last_expected_bytes);
    try std.testing.expectEqual(runtime.EffectAudioSource.stream, self.ui.effects.audioSnapshot().source);
    try std.testing.expect(self.ui.effects.audioSnapshot().buffering);

    // load_url answering 1 is a verified cache hit: local playback, no
    // buffering.
    recorder.load_url_result = 1;
    try pressAudioButton(app, "Stream");
    try std.testing.expectEqual(@as(usize, 2), recorder.load_url_count);
    try std.testing.expectEqual(runtime.EffectAudioSource.cache, self.ui.effects.audioSnapshot().source);
    try std.testing.expect(!self.ui.effects.audioSnapshot().buffering);
}

test "mobile audio service registration is all-or-nothing per tier" {
    const app = MobileAudioApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileAudioApi.native_sdk_app_destroy(app);
    const self: *MobileAudioHost = @ptrCast(@alignCast(app));

    var recorder = MobileAudioRecorder{};

    // A partial playback table is refused whole; the host keeps declining.
    var partial = types.MobileAudioService{};
    partial.load = recorderAudioLoad;
    partial.play = recorderAudioPlay;
    try std.testing.expectEqual(@as(c_int, 0), MobileAudioApi.native_sdk_app_set_audio_service(app, &partial, &recorder));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(MobileAudioApi.native_sdk_app_last_error_name(app)));
    try std.testing.expect(!self.embedded.runtime.options.platform.supports(.audio_playback));

    // The playback tier without load_url registers playback but declines
    // streaming.
    var local_only = recorderAudioService();
    local_only.load_url = null;
    try std.testing.expectEqual(@as(c_int, 1), MobileAudioApi.native_sdk_app_set_audio_service(app, &local_only, &recorder));
    try std.testing.expect(self.embedded.runtime.options.platform.supports(.audio_playback));
    try std.testing.expect(!self.embedded.runtime.options.platform.supports(.audio_streaming));
    try std.testing.expect(self.embedded.runtime.options.platform.services.audio_load_url_fn == null);

    // A null (or all-null) table clears the registration: back to the
    // honest decline.
    try std.testing.expectEqual(@as(c_int, 1), MobileAudioApi.native_sdk_app_set_audio_service(app, null, null));
    try std.testing.expect(!self.embedded.runtime.options.platform.supports(.audio_playback));
    try std.testing.expect(self.embedded.runtime.options.platform.services.audio_load_fn == null);
}

// ------------------------------------------------------------ image service
//
// The embed image-decode seam end to end: hosts decline
// `fx.registerImageBytes` until the shim registers a codec
// (`native_sdk_app_set_image_service`) — the pinned degrade behind the
// avatar-initials fallback on phones — and a registered callback receives
// the encoded bytes through the same `decode_image_fn` seam the desktop
// platform codecs serve, with the shim-reported result codes mapping
// exactly like the macOS host's (1 decoded / -1 too large / else failed)
// and the reported dimensions re-validated before any pixels are trusted.

const MobileImageDef = struct {
    pub const Model = struct {
        cover: u64 = 0,
        width: usize = 0,
        height: usize = 0,
        register_error: ?anyerror = null,
    };

    pub const Msg = union(enum) {
        register,
    };

    const App = runtime.UiApp(Model, Msg);

    pub fn initModel() Model {
        return .{};
    }

    pub fn mobileOptions() App.Options {
        return .{
            .name = "mobile-image",
            .scene = ui_host.mobile_shell_scene,
            .canvas_label = mobile_gpu_surface_label,
            .update_fx = update,
            .view = view,
        };
    }

    // The soundboard boot shape: decode-and-register committed encoded
    // bytes synchronously, store the id in the model only on success so a
    // failed decode leaves the avatar on its initials fallback.
    fn update(model: *Model, msg: Msg, fx: *App.Effects) void {
        switch (msg) {
            .register => {
                model.register_error = null;
                const registered = fx.registerImageBytes(7, "encoded-cover-bytes") catch |err| {
                    model.register_error = err;
                    return;
                };
                model.cover = 7;
                model.width = registered.width;
                model.height = registered.height;
            },
        }
    }

    fn view(ui: *App.Ui, model: *const Model) App.Ui.Node {
        return ui.column(.{ .gap = 8, .padding = 12 }, .{
            ui.text(.{}, ui.fmt("cover {d}", .{model.cover})),
            ui.button(.{ .on_press = .register }, "Register"),
        });
    }
};

const MobileImageHost = ui_host.UiAppHost(MobileImageDef);
const MobileImageApi = c_api.MobileCApi(MobileImageHost);

/// What the fake shim codec records — the mobile mirror of the null
/// platform's decode counter, held by the test and reached through the
/// registered context pointer. `result`/`width`/`height` script the next
/// answer so every shim result code is exercised.
const MobileImageRecorder = struct {
    decode_count: usize = 0,
    last_bytes: [64]u8 = undefined,
    last_bytes_len: usize = 0,
    last_pixels_len: usize = 0,
    result: c_int = 1,
    width: usize = 2,
    height: usize = 2,
    fill: u8 = 0xAB,

    fn from(context: ?*anyopaque) *MobileImageRecorder {
        return @ptrCast(@alignCast(context.?));
    }
};

fn recorderImageDecode(
    context: ?*anyopaque,
    bytes: ?[*]const u8,
    bytes_len: usize,
    pixels: ?[*]u8,
    pixels_len: usize,
    out_width: ?*usize,
    out_height: ?*usize,
) callconv(.c) c_int {
    const recorder = MobileImageRecorder.from(context);
    recorder.decode_count += 1;
    recorder.last_bytes_len = conversions.copyInputText(&recorder.last_bytes, if (bytes) |value| value[0..bytes_len] else "");
    recorder.last_pixels_len = pixels_len;
    if (recorder.result != 1) return recorder.result;
    out_width.?.* = recorder.width;
    out_height.?.* = recorder.height;
    const byte_len = recorder.width *% recorder.height *% 4;
    if (pixels != null and byte_len <= pixels_len) {
        @memset(pixels.?[0..byte_len], recorder.fill);
    }
    return 1;
}

fn startImageHost(app: ?*anyopaque) !void {
    MobileImageApi.native_sdk_app_start(app);
    var surface_token: u8 = 0;
    MobileImageApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 0, 0, 0, 0, 0, 0, 0, 0);
    MobileImageApi.native_sdk_app_frame(app);
    try std.testing.expectEqualStrings("", std.mem.span(MobileImageApi.native_sdk_app_last_error_name(app)));
}

fn pressRegisterButton(app: ?*anyopaque) !void {
    const count = MobileImageApi.native_sdk_app_widget_semantics_count(app);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        var node: MobileWidgetSemantics = .{};
        try std.testing.expectEqual(@as(c_int, 1), MobileImageApi.native_sdk_app_widget_semantics_at(app, index, &node));
        if (node.role != @intFromEnum(MobileWidgetRole.button)) continue;
        const node_label = if (node.label) |ptr| ptr[0..node.label_len] else "";
        if (!std.mem.eql(u8, node_label, "Register")) continue;
        const x = node.x + node.width / 2;
        const y = node.y + node.height / 2;
        MobileImageApi.native_sdk_app_touch(app, 1, 0, x, y, 1);
        MobileImageApi.native_sdk_app_touch(app, 1, 1, x, y, 0);
        try std.testing.expectEqualStrings("", std.mem.span(MobileImageApi.native_sdk_app_last_error_name(app)));
        return;
    }
    return error.TestUnexpectedResult;
}

test "mobile hosts decline image decode until the shim registers a codec" {
    const app = MobileImageApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileImageApi.native_sdk_app_destroy(app);
    const self: *MobileImageHost = @ptrCast(@alignCast(app));

    try startImageHost(app);

    // No registered service: registerImageBytes reports the honest
    // decline synchronously, the id never reaches the model, and the
    // registry stays empty — the initials-fallback shape the soundboard
    // suite pins on the null platform, unchanged by the new seam.
    try pressRegisterButton(app);
    try std.testing.expectEqual(error.UnsupportedService, self.ui.model.register_error.?);
    try std.testing.expectEqual(@as(u64, 0), self.ui.model.cover);
    try std.testing.expectEqual(@as(usize, 0), self.embedded.runtime.registeredCanvasImageCount());
}

test "mobile image service decodes registerImageBytes through the shim codec" {
    const app = MobileImageApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileImageApi.native_sdk_app_destroy(app);
    const self: *MobileImageHost = @ptrCast(@alignCast(app));

    var recorder = MobileImageRecorder{};
    const service = types.MobileImageService{ .decode = recorderImageDecode };
    try std.testing.expectEqual(@as(c_int, 1), MobileImageApi.native_sdk_app_set_image_service(app, &service, &recorder));

    try startImageHost(app);

    // The encoded bytes reach the shim callback verbatim and the decoded
    // pixels land in the runtime's image registry with the shim-reported
    // dimensions; the model stores the id only after that success.
    try pressRegisterButton(app);
    try std.testing.expectEqual(@as(usize, 1), recorder.decode_count);
    try std.testing.expectEqualStrings("encoded-cover-bytes", recorder.last_bytes[0..recorder.last_bytes_len]);
    try std.testing.expect(self.ui.model.register_error == null);
    try std.testing.expectEqual(@as(u64, 7), self.ui.model.cover);
    try std.testing.expectEqual(@as(usize, 2), self.ui.model.width);
    try std.testing.expectEqual(@as(usize, 2), self.ui.model.height);
    const registered = self.embedded.runtime.registeredCanvasImage(7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), registered.width);
    try std.testing.expectEqual(@as(usize, 2), registered.height);
    const resources = self.embedded.runtime.registeredCanvasImages();
    try std.testing.expectEqual(@as(usize, 1), resources.len);
    try std.testing.expectEqual(@as(u8, 0xAB), resources[0].pixels[0]);

    // The decode happens once per registration: nothing about presenting
    // frames re-decodes (the registry holds the pixels).
    MobileImageApi.native_sdk_app_frame(app);
    MobileImageApi.native_sdk_app_frame(app);
    try std.testing.expectEqual(@as(usize, 1), recorder.decode_count);
}

test "mobile image decode failures map to the macOS host's result codes" {
    const app = MobileImageApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileImageApi.native_sdk_app_destroy(app);
    const self: *MobileImageHost = @ptrCast(@alignCast(app));

    var recorder = MobileImageRecorder{};
    const service = types.MobileImageService{ .decode = recorderImageDecode };
    try std.testing.expectEqual(@as(c_int, 1), MobileImageApi.native_sdk_app_set_image_service(app, &service, &recorder));
    try startImageHost(app);

    // 0 (undecodable bytes) → ImageDecodeFailed, nothing registered.
    recorder.result = 0;
    try pressRegisterButton(app);
    try std.testing.expectEqual(error.ImageDecodeFailed, self.ui.model.register_error.?);
    try std.testing.expectEqual(@as(u64, 0), self.ui.model.cover);

    // -1 (decoded pixels over the buffer) → ImageTooLarge.
    recorder.result = -1;
    try pressRegisterButton(app);
    try std.testing.expectEqual(error.ImageTooLarge, self.ui.model.register_error.?);

    // A shim that answers success with dimensions the buffer cannot hold
    // is refused before any pixel slice is formed: decode failed, never
    // an out-of-bounds read.
    recorder.result = 1;
    recorder.width = 100_000;
    recorder.height = 100_000;
    try pressRegisterButton(app);
    try std.testing.expectEqual(error.ImageDecodeFailed, self.ui.model.register_error.?);

    // Zero dimensions on a success answer are refused the same way.
    recorder.width = 0;
    recorder.height = 0;
    try pressRegisterButton(app);
    try std.testing.expectEqual(error.ImageDecodeFailed, self.ui.model.register_error.?);
    try std.testing.expectEqual(@as(usize, 0), self.embedded.runtime.registeredCanvasImageCount());
}

test "clearing the mobile image service returns to the honest decline" {
    const app = MobileImageApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileImageApi.native_sdk_app_destroy(app);
    const self: *MobileImageHost = @ptrCast(@alignCast(app));

    var recorder = MobileImageRecorder{};
    const service = types.MobileImageService{ .decode = recorderImageDecode };
    try std.testing.expectEqual(@as(c_int, 1), MobileImageApi.native_sdk_app_set_image_service(app, &service, &recorder));
    try std.testing.expect(self.embedded.runtime.options.platform.services.decode_image_fn != null);

    // A null (or all-null) table clears the registration: the service
    // entry empties and registerImageBytes declines again.
    try std.testing.expectEqual(@as(c_int, 1), MobileImageApi.native_sdk_app_set_image_service(app, null, null));
    try std.testing.expect(self.embedded.runtime.options.platform.services.decode_image_fn == null);

    try startImageHost(app);
    try pressRegisterButton(app);
    try std.testing.expectEqual(error.UnsupportedService, self.ui.model.register_error.?);
    try std.testing.expectEqual(@as(usize, 0), recorder.decode_count);
}

// ------------------------------------------------------ declared platform chrome
//
// The declared-chrome seam end to end: the shell metadata's tab set and
// primary action read back over the ABI, the model's selected_tab_fn
// derivation projects as a declared index the host polls, taps dispatch
// the declared command ids through the ordinary command path into
// update, the host chrome reports (form factor, tabs-projected) ride
// the window-chrome channel into on_chrome Msgs, icons rasterize as
// template pixels through the canvas vector core, and the whole loop
// replays deterministically — the same sequence into two fresh hosts
// lands the same model and the same projected selection.

const MobileTabsDef = struct {
    pub const Model = struct {
        tab: enum { feed, library } = .feed,
        /// One page deep on the feed tab (the soundboard's album-detail
        /// shape): the navigation projection derives depth from it.
        open_item: bool = false,
        action_count: u32 = 0,
        chrome_form_factor: platform.FormFactor = .unknown,
        chrome_tabs_projected: bool = false,
        chrome_bottom: f32 = 0,
    };

    pub const Msg = union(enum) {
        show_feed,
        show_library,
        open_item,
        close_item,
        act,
        chrome_changed: platform.WindowChrome,
    };

    const App = runtime.UiApp(Model, Msg);

    const tabs = [_]@import("app_manifest").ShellTab{
        .{ .id = "tabs.feed", .label = "Feed", .icon = "menu" },
        .{ .id = "tabs.library", .label = "Library", .icon = "music" },
    };

    const scene: @import("app_manifest").ShellConfig = .{
        .windows = ui_host.mobile_shell_scene.windows,
        .chrome = .{
            .tabs = &tabs,
            .primary_action = .{ .id = "action.act", .label = "Act", .icon = "plus" },
        },
    };

    pub fn initModel() Model {
        return .{};
    }

    pub fn mobileOptions() App.Options {
        return .{
            .name = "mobile-tabs",
            .scene = scene,
            .canvas_label = mobile_gpu_surface_label,
            .update = update,
            .view = view,
            .on_command = onCommand,
            .on_chrome = onChrome,
            .selected_tab_fn = selectedTab,
            .navigation_depth_fn = navigationDepth,
            .navigation_back_command = "nav.back",
        };
    }

    fn update(model: *Model, msg: Msg) void {
        switch (msg) {
            .show_feed => model.tab = .feed,
            .show_library => model.tab = .library,
            .open_item => model.open_item = true,
            .close_item => model.open_item = false,
            .act => model.action_count += 1,
            .chrome_changed => |chrome_state| {
                model.chrome_form_factor = chrome_state.form_factor;
                model.chrome_tabs_projected = chrome_state.tabs_projected;
                model.chrome_bottom = chrome_state.insets.bottom;
            },
        }
    }

    fn onCommand(name: []const u8) ?Msg {
        if (std.mem.eql(u8, name, "tabs.feed")) return .show_feed;
        if (std.mem.eql(u8, name, "tabs.library")) return .show_library;
        if (std.mem.eql(u8, name, "item.open")) return .open_item;
        if (std.mem.eql(u8, name, "nav.back")) return .close_item;
        if (std.mem.eql(u8, name, "action.act")) return .act;
        return null;
    }

    fn onChrome(chrome_state: platform.WindowChrome) ?Msg {
        return .{ .chrome_changed = chrome_state };
    }

    fn selectedTab(model: *const Model) []const u8 {
        return switch (model.tab) {
            .feed => "tabs.feed",
            .library => "tabs.library",
        };
    }

    /// Depth follows the VISIBLE page stack (the soundboard rule): the
    /// open item counts only while the feed tab shows it, so a tab
    /// switch with an item open reads as lateral, never as a pop.
    fn navigationDepth(model: *const Model) usize {
        return if (model.tab == .feed and model.open_item) 1 else 0;
    }

    fn view(ui: *App.Ui, model: *const Model) App.Ui.Node {
        return ui.column(.{ .gap = 8, .padding = 12 }, .{
            ui.text(.{}, switch (model.tab) {
                .feed => "Feed page",
                .library => "Library page",
            }),
            ui.text(.{}, ui.fmt("Acted {d}", .{model.action_count})),
        });
    }
};

const MobileTabsHost = ui_host.UiAppHost(MobileTabsDef);
const MobileTabsApi = c_api.MobileCApi(MobileTabsHost);
const MobileChromeItem = @import("chrome.zig").MobileChromeItem;

fn chromeItemString(pointer: ?[*]const u8, len: usize) []const u8 {
    const bytes = pointer orelse return "";
    return bytes[0..len];
}

test "mobile C ABI exposes declared platform chrome and mirrors model selection" {
    const app = MobileTabsApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileTabsApi.native_sdk_app_destroy(app);
    const self: *MobileTabsHost = @ptrCast(@alignCast(app));

    // The declaration reads back exactly as the scene states it.
    try std.testing.expectEqual(@as(usize, 2), MobileTabsApi.native_sdk_app_chrome_tab_count(app));
    var tab: MobileChromeItem = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileTabsApi.native_sdk_app_chrome_tab_at(app, 0, &tab));
    try std.testing.expectEqualStrings("tabs.feed", chromeItemString(tab.id, tab.id_len));
    try std.testing.expectEqualStrings("Feed", chromeItemString(tab.label, tab.label_len));
    try std.testing.expectEqualStrings("menu", chromeItemString(tab.icon, tab.icon_len));
    try std.testing.expectEqual(@as(c_int, 0), MobileTabsApi.native_sdk_app_chrome_tab_at(app, 2, &tab));
    var action: MobileChromeItem = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileTabsApi.native_sdk_app_chrome_primary_action(app, &action));
    try std.testing.expectEqualStrings("action.act", chromeItemString(action.id, action.id_len));

    // Before the first rebuild no selection has been derived: the host
    // projects "no selected item" honestly.
    try std.testing.expectEqual(@as(isize, -1), MobileTabsApi.native_sdk_app_chrome_selected_tab(app));

    MobileTabsApi.native_sdk_app_start(app);
    var surface_token: u8 = 0;
    MobileTabsApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 0, 0, 0, 0, 0, 0, 0, 0);
    MobileTabsApi.native_sdk_app_frame(app);
    try std.testing.expect(self.ui.installed);

    // The installing rebuild derived the model's selection.
    try std.testing.expectEqual(@as(isize, 0), MobileTabsApi.native_sdk_app_chrome_selected_tab(app));

    // A projected tap dispatches the declared command id through the
    // ordinary command path; update moves the model and the projection
    // follows on the same dispatch (synchronous).
    MobileTabsApi.native_sdk_app_command(app, "tabs.library", "tabs.library".len);
    try std.testing.expectEqual(.library, self.ui.model.tab);
    try std.testing.expectEqual(@as(isize, 1), MobileTabsApi.native_sdk_app_chrome_selected_tab(app));

    // The primary action dispatches like any command; selection holds.
    MobileTabsApi.native_sdk_app_command(app, "action.act", "action.act".len);
    try std.testing.expectEqual(@as(u32, 1), self.ui.model.action_count);
    try std.testing.expectEqual(@as(isize, 1), MobileTabsApi.native_sdk_app_chrome_selected_tab(app));

    // A programmatic Msg (no bar involved) moves the model; the next
    // projection poll reads the new selection — the bar is downstream.
    try self.embedded.runtime.dispatchCommand(self.embedded.app, .{ .name = "tabs.feed", .source = .menu, .window_id = 1 });
    try std.testing.expectEqual(.feed, self.ui.model.tab);
    try std.testing.expectEqual(@as(isize, 0), MobileTabsApi.native_sdk_app_chrome_selected_tab(app));
}

test "mobile host chrome reports ride the window-chrome channel" {
    const app = MobileTabsApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileTabsApi.native_sdk_app_destroy(app);
    const self: *MobileTabsHost = @ptrCast(@alignCast(app));

    // The host files its standing reports before start (the iOS host's
    // order): the pre-install chrome delivery already carries them.
    try std.testing.expectEqual(@as(c_int, 1), MobileTabsApi.native_sdk_app_set_form_factor(app, 1));
    try std.testing.expectEqual(@as(c_int, 1), MobileTabsApi.native_sdk_app_set_chrome_tabs_projected(app, 1));

    MobileTabsApi.native_sdk_app_start(app);
    var surface_token: u8 = 0;
    MobileTabsApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 47, 0, 34, 0, 0, 0, 0, 0);
    MobileTabsApi.native_sdk_app_frame(app);
    try std.testing.expect(self.ui.installed);

    // Both reports landed in the model as one on_chrome Msg, beside the
    // safe-area insets the same channel always carried.
    try std.testing.expectEqual(platform.FormFactor.compact, self.ui.model.chrome_form_factor);
    try std.testing.expect(self.ui.model.chrome_tabs_projected);
    try std.testing.expectEqual(@as(f32, 34), self.ui.model.chrome_bottom);

    // A viewport push never erases the standing reports.
    MobileTabsApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 47, 0, 40, 0, 0, 0, 0, 0);
    MobileTabsApi.native_sdk_app_frame(app);
    try std.testing.expectEqual(platform.FormFactor.compact, self.ui.model.chrome_form_factor);
    try std.testing.expect(self.ui.model.chrome_tabs_projected);
    try std.testing.expectEqual(@as(f32, 40), self.ui.model.chrome_bottom);

    // The size-class flip arrives as a fresh chrome Msg with the next
    // viewport-driven re-query (an iPad rotation's trait change).
    try std.testing.expectEqual(@as(c_int, 1), MobileTabsApi.native_sdk_app_set_form_factor(app, 2));
    MobileTabsApi.native_sdk_app_viewport(app, 1024, 768, 1, &surface_token, 24, 0, 20, 0, 0, 0, 0, 0);
    MobileTabsApi.native_sdk_app_frame(app);
    try std.testing.expectEqual(platform.FormFactor.regular, self.ui.model.chrome_form_factor);
}

test "chrome icon pixels rasterize declared vocabulary glyphs as templates" {
    const app = MobileTabsApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileTabsApi.native_sdk_app_destroy(app);

    const size: usize = 48;
    var pixels: [size * size * 4]u8 = undefined;

    // A built-in glyph inks alpha; color channels are premultiplied
    // white (never exceeding alpha, equal at full coverage).
    try std.testing.expectEqual(@as(c_int, 1), MobileTabsApi.native_sdk_app_chrome_icon_pixels(app, "plus", "plus".len, size, &pixels, pixels.len));
    var ink: usize = 0;
    var index: usize = 0;
    while (index < pixels.len) : (index += 4) {
        const alpha = pixels[index + 3];
        if (alpha > 0) ink += 1;
        try std.testing.expectEqual(alpha, pixels[index]);
        try std.testing.expectEqual(alpha, pixels[index + 1]);
        try std.testing.expectEqual(alpha, pixels[index + 2]);
    }
    try std.testing.expect(ink > 40);

    // Determinism: the same request renders identical bytes.
    var second: [size * size * 4]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 1), MobileTabsApi.native_sdk_app_chrome_icon_pixels(app, "plus", "plus".len, size, &second, second.len));
    try std.testing.expectEqualSlices(u8, &pixels, &second);

    // An unresolvable name renders the honest missing glyph — visible,
    // never an empty image.
    try std.testing.expectEqual(@as(c_int, 1), MobileTabsApi.native_sdk_app_chrome_icon_pixels(app, "no-such-glyph", "no-such-glyph".len, size, &pixels, pixels.len));
    ink = 0;
    index = 3;
    while (index < pixels.len) : (index += 4) {
        if (pixels[index] > 0) ink += 1;
    }
    try std.testing.expect(ink > 40);

    // Structurally invalid requests are refused loudly.
    try std.testing.expectEqual(@as(c_int, 0), MobileTabsApi.native_sdk_app_chrome_icon_pixels(app, "plus", "plus".len, 0, &pixels, pixels.len));
    try std.testing.expectEqualStrings("InvalidIconRequest", std.mem.span(MobileTabsApi.native_sdk_app_last_error_name(app)));
    try std.testing.expectEqual(@as(c_int, 0), MobileTabsApi.native_sdk_app_chrome_icon_pixels(app, "plus", "plus".len, size, &pixels, pixels.len - 1));
    try std.testing.expectEqual(@as(c_int, 0), MobileTabsApi.native_sdk_app_chrome_icon_pixels(app, "", 0, size, &pixels, pixels.len));
}

test "mobile C ABI projects navigation depth and dispatches the back command" {
    const app = MobileTabsApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileTabsApi.native_sdk_app_destroy(app);
    const self: *MobileTabsHost = @ptrCast(@alignCast(app));

    // The static half reads back before start: the declared back
    // command is what a completed platform back gesture dispatches.
    var back: MobileChromeItem = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileTabsApi.native_sdk_app_chrome_navigation_back_command(app, &back));
    try std.testing.expectEqualStrings("nav.back", chromeItemString(back.id, back.id_len));

    // Before the first rebuild no depth has been derived: hosts read -1
    // and present no transitions.
    try std.testing.expectEqual(@as(isize, -1), MobileTabsApi.native_sdk_app_chrome_navigation_depth(app));

    MobileTabsApi.native_sdk_app_start(app);
    var surface_token: u8 = 0;
    MobileTabsApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 0, 0, 0, 0, 0, 0, 0, 0);
    MobileTabsApi.native_sdk_app_frame(app);
    try std.testing.expect(self.ui.installed);

    // The installing rebuild derived the root depth.
    try std.testing.expectEqual(@as(isize, 0), MobileTabsApi.native_sdk_app_chrome_navigation_depth(app));

    // A Msg that opens a page moves the projection to 1 — the host
    // reads the change on its next poll and presents the push.
    MobileTabsApi.native_sdk_app_command(app, "item.open", "item.open".len);
    try std.testing.expect(self.ui.model.open_item);
    try std.testing.expectEqual(@as(isize, 1), MobileTabsApi.native_sdk_app_chrome_navigation_depth(app));

    // A tab switch with the page open is LATERAL: the depth drops with
    // the selected tab in the same poll (the host reconciles without a
    // transition), and switching back restores it the same way — the
    // model state never moved.
    MobileTabsApi.native_sdk_app_command(app, "tabs.library", "tabs.library".len);
    try std.testing.expectEqual(@as(isize, 0), MobileTabsApi.native_sdk_app_chrome_navigation_depth(app));
    try std.testing.expectEqual(@as(isize, 1), MobileTabsApi.native_sdk_app_chrome_selected_tab(app));
    try std.testing.expect(self.ui.model.open_item);
    MobileTabsApi.native_sdk_app_command(app, "tabs.feed", "tabs.feed".len);
    try std.testing.expectEqual(@as(isize, 1), MobileTabsApi.native_sdk_app_chrome_navigation_depth(app));

    // The completed gesture's dispatch: the declared back command rides
    // the ordinary command path, update closes the page, and the
    // projection answers 0 on the same dispatch — exactly once.
    MobileTabsApi.native_sdk_app_command(app, back.id, back.id_len);
    try std.testing.expect(!self.ui.model.open_item);
    try std.testing.expectEqual(@as(isize, 0), MobileTabsApi.native_sdk_app_chrome_navigation_depth(app));
}

test "apps without a navigation projection answer the honest zeros" {
    // The damage def declares no navigation_depth_fn: depth stays -1
    // forever (hosts present no transitions, never arm the gesture) and
    // no back command exists.
    const app = MobileDamageApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileDamageApi.native_sdk_app_destroy(app);

    try std.testing.expectEqual(@as(isize, -1), MobileDamageApi.native_sdk_app_chrome_navigation_depth(app));
    var back: MobileChromeItem = .{};
    try std.testing.expectEqual(@as(c_int, 0), MobileDamageApi.native_sdk_app_chrome_navigation_back_command(app, &back));

    MobileDamageApi.native_sdk_app_start(app);
    var surface_token: u8 = 0;
    MobileDamageApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 0, 0, 0, 0, 0, 0, 0, 0);
    MobileDamageApi.native_sdk_app_frame(app);
    try std.testing.expectEqual(@as(isize, -1), MobileDamageApi.native_sdk_app_chrome_navigation_depth(app));
    try std.testing.expectEqual(@as(c_int, 0), MobileDamageApi.native_sdk_app_chrome_navigation_back_command(app, &back));
}

test "declared chrome projection replays deterministically" {
    // One driving sequence into two fresh hosts: identical model state
    // and identical projected selection AND navigation depth at every
    // step — both projections are pure functions of the Msg journal, so
    // record/replay holds for the native bar and the push/pop stack
    // exactly as it does for the canvas.
    var selected_a: [12]isize = undefined;
    var selected_b: [12]isize = undefined;
    var depth_a: [10]isize = undefined;
    var depth_b: [10]isize = undefined;
    var model_a: MobileTabsDef.Model = undefined;
    var model_b: MobileTabsDef.Model = undefined;

    for (0..2) |round| {
        const app = MobileTabsApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
        defer MobileTabsApi.native_sdk_app_destroy(app);
        const self: *MobileTabsHost = @ptrCast(@alignCast(app));
        const selected = if (round == 0) &selected_a else &selected_b;
        const depth = if (round == 0) &depth_a else &depth_b;

        _ = MobileTabsApi.native_sdk_app_set_form_factor(app, 1);
        _ = MobileTabsApi.native_sdk_app_set_chrome_tabs_projected(app, 1);
        MobileTabsApi.native_sdk_app_start(app);
        var surface_token: u8 = 0;
        MobileTabsApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 47, 0, 34, 0, 0, 0, 0, 0);
        MobileTabsApi.native_sdk_app_frame(app);
        selected[0] = MobileTabsApi.native_sdk_app_chrome_selected_tab(app);
        depth[0] = MobileTabsApi.native_sdk_app_chrome_navigation_depth(app);

        // Tab moves, a push, a lateral switch away and back over the
        // open page, the gesture's back dispatch, and a repeat push —
        // the sequence a stress session produces.
        const journal = [_][]const u8{ "tabs.library", "action.act", "tabs.feed", "item.open", "tabs.library", "tabs.feed", "nav.back", "item.open", "action.act" };
        for (journal, 1..) |command_name, step| {
            MobileTabsApi.native_sdk_app_command(app, command_name.ptr, command_name.len);
            selected[step] = MobileTabsApi.native_sdk_app_chrome_selected_tab(app);
            depth[step] = MobileTabsApi.native_sdk_app_chrome_navigation_depth(app);
        }
        selected[journal.len + 1] = MobileTabsApi.native_sdk_app_chrome_selected_tab(app);
        selected[journal.len + 2] = @intCast(self.ui.model.action_count);
        if (round == 0) model_a = self.ui.model else model_b = self.ui.model;
    }

    try std.testing.expectEqualSlices(isize, &selected_a, &selected_b);
    try std.testing.expectEqualSlices(isize, &depth_a, &depth_b);
    try std.testing.expectEqualDeep(model_a, model_b);
}

// ------------------------------------------------------- damage render ABI
//
// The incremental pixel seam mobile hosts upload from: the runtime's frame
// dispatch presents changed frames through the dirty-scissored CPU raster
// (packet presenters dropped, pixel-present retained baseline on — see
// `host.installPresentCapture`), the host captures each present, and
// `native_sdk_app_render_pixels_damage` copies only the damaged region
// into the shim's retained buffer and names it, so a keystroke's upload is
// the field, not the surface.

const MobileDamageDef = struct {
    pub const Model = struct {
        count: u32 = 0,
    };

    pub const Msg = union(enum) {
        increment,
    };

    const App = runtime.UiApp(Model, Msg);

    pub fn initModel() Model {
        return .{};
    }

    pub fn mobileOptions() App.Options {
        return .{
            .name = "mobile-damage",
            .scene = ui_host.mobile_shell_scene,
            .canvas_label = mobile_gpu_surface_label,
            .update = update,
            .view = view,
        };
    }

    fn update(model: *Model, msg: Msg) void {
        switch (msg) {
            .increment => model.count += 1,
        }
    }

    fn rowKey(index: *const usize) canvas.UiKey {
        return canvas.uiKey(@as(u64, index.*));
    }

    fn rowView(ui: *App.Ui, index: *const usize) App.Ui.Node {
        return ui.text(.{}, ui.fmt("row {d}", .{index.*}));
    }

    fn indices(arena: std.mem.Allocator) []const usize {
        const items = arena.alloc(usize, 20) catch return &.{};
        for (items, 0..) |*item, item_index| item.* = item_index;
        return items;
    }

    fn view(ui: *App.Ui, model: *const Model) App.Ui.Node {
        // Deliberately UNDER the packet hosts' small-list gate: the
        // pixel-adopted baseline refines dirty bounds at any command
        // count (a full window would mean a full raster AND a full
        // upload on mobile). The CHANGING content is pinned to the top
        // of the surface so refined damage stays a small band.
        return ui.column(.{ .gap = 2, .padding = 8 }, .{
            ui.text(.{}, ui.fmt("Count {d}", .{model.count})),
            ui.button(.{ .variant = .primary, .on_press = .increment }, "Increment"),
            ui.column(.{ .gap = 2 }, ui.each(indices(ui.arena), rowKey, rowView)),
        });
    }
};

const MobileDamageHost = ui_host.UiAppHost(MobileDamageDef);
const MobileDamageApi = c_api.MobileCApi(MobileDamageHost);

fn findDamageSemanticsByRole(app: ?*anyopaque, role: MobileWidgetRole) !MobileWidgetSemantics {
    const count = MobileDamageApi.native_sdk_app_widget_semantics_count(app);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        var node: MobileWidgetSemantics = .{};
        try std.testing.expectEqual(@as(c_int, 1), MobileDamageApi.native_sdk_app_widget_semantics_at(app, index, &node));
        if (node.role == @intFromEnum(role)) return node;
    }
    return error.TestUnexpectedResult;
}

test "mobile damage render copies only changed regions from the presented capture" {
    const app = MobileDamageApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileDamageApi.native_sdk_app_destroy(app);
    const self: *MobileDamageHost = @ptrCast(@alignCast(app));

    MobileDamageApi.native_sdk_app_start(app);
    var surface_token: u8 = 0;
    MobileDamageApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 0, 0, 0, 0, 0, 0, 0, 0);
    MobileDamageApi.native_sdk_app_frame(app);
    try std.testing.expectEqualStrings("", std.mem.span(MobileDamageApi.native_sdk_app_last_error_name(app)));
    try std.testing.expectEqual(@as(usize, 1), self.null_platform.gpu_surface_present_count);

    var info: MobileCanvasPixels = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileDamageApi.native_sdk_app_render_pixel_size(app, 1, &info));
    const retained = try std.testing.allocator.alloc(u8, info.byte_len);
    defer std.testing.allocator.free(retained);

    // First delivery: the whole surface with full damage.
    var damage: types.MobileCanvasPixelsDamage = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileDamageApi.native_sdk_app_render_pixels_damage(app, 1, retained.ptr, retained.len, &damage));
    try std.testing.expectEqual(info.width, damage.width);
    try std.testing.expectEqual(info.height, damage.height);
    try std.testing.expectEqual(info.byte_len, damage.byte_len);
    try std.testing.expectEqual(@as(usize, 0), damage.damage_x);
    try std.testing.expectEqual(@as(usize, 0), damage.damage_y);
    try std.testing.expectEqual(info.width, damage.damage_width);
    try std.testing.expectEqual(info.height, damage.damage_height);
    var nonblank = false;
    for (retained) |byte| {
        if (byte != 0) {
            nonblank = true;
            break;
        }
    }
    try std.testing.expect(nonblank);

    // Idle frame: nothing presents, and the next delivery reports EMPTY
    // damage — the host skips its upload entirely.
    MobileDamageApi.native_sdk_app_frame(app);
    try std.testing.expectEqual(@as(usize, 1), self.null_platform.gpu_surface_present_count);
    try std.testing.expectEqual(@as(c_int, 1), MobileDamageApi.native_sdk_app_render_pixels_damage(app, 1, retained.ptr, retained.len, &damage));
    try std.testing.expectEqual(@as(usize, 0), damage.damage_width);
    try std.testing.expectEqual(@as(usize, 0), damage.damage_height);

    // A model change presents INCREMENTALLY: the dirty region refines to
    // the changed commands (the counter text and the button's state, both
    // pinned near the top), never the whole window. Between the change
    // and its present, a delivery must report the OLD revision with
    // empty damage — the host's signal to call again next tick (the
    // gate-on-sightings race that once stranded a boot relayout off the
    // glass).
    const revision_before_tap = damage.revision;
    const button = try findDamageSemanticsByRole(app, .button);
    const tap_x = button.x + button.width / 2;
    const tap_y = button.y + button.height / 2;
    MobileDamageApi.native_sdk_app_touch(app, 1, 0, tap_x, tap_y, 1);
    MobileDamageApi.native_sdk_app_touch(app, 1, 1, tap_x, tap_y, 0);
    try std.testing.expectEqual(@as(u32, 1), self.ui.model.count);
    var frame_state: MobileGpuFrameState = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileDamageApi.native_sdk_app_gpu_frame_state(app, &frame_state));
    try std.testing.expect(frame_state.canvas_revision > revision_before_tap);
    try std.testing.expectEqual(@as(c_int, 1), MobileDamageApi.native_sdk_app_render_pixels_damage(app, 1, retained.ptr, retained.len, &damage));
    try std.testing.expectEqual(@as(usize, 0), damage.damage_width);
    try std.testing.expectEqual(revision_before_tap, damage.revision);
    try std.testing.expect(damage.revision < frame_state.canvas_revision);
    MobileDamageApi.native_sdk_app_frame(app);
    try std.testing.expectEqual(@as(usize, 2), self.null_platform.gpu_surface_present_count);
    try std.testing.expectEqual(@as(c_int, 1), MobileDamageApi.native_sdk_app_render_pixels_damage(app, 1, retained.ptr, retained.len, &damage));
    try std.testing.expect(damage.damage_width > 0);
    try std.testing.expect(damage.damage_height > 0);
    try std.testing.expect(damage.damage_height < info.height / 2);
    try std.testing.expectEqual(frame_state.canvas_revision, damage.revision);

    // Anti-tearing invariant: after the incremental copy the retained
    // buffer is byte-identical to a fresh full-surface render of the
    // same retained scene.
    const full = try std.testing.allocator.alloc(u8, info.byte_len);
    defer std.testing.allocator.free(full);
    var rendered: MobileCanvasPixels = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileDamageApi.native_sdk_app_render_pixels(app, 1, full.ptr, full.len, &rendered));
    try std.testing.expectEqualSlices(u8, full, retained);
}

test "mobile damage render falls back to a full render without a capture" {
    const app = MobileDamageApi.native_sdk_app_create() orelse return error.TestUnexpectedResult;
    defer MobileDamageApi.native_sdk_app_destroy(app);

    MobileDamageApi.native_sdk_app_start(app);
    var surface_token: u8 = 0;
    MobileDamageApi.native_sdk_app_viewport(app, 390, 844, 1, &surface_token, 0, 0, 0, 0, 0, 0, 0, 0);
    // No frame pumped: nothing has presented, so the damage entry takes
    // the full-render fallback with full damage — exactly the plain
    // render_pixels contract plus an honest damage report.
    var info: MobileCanvasPixels = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileDamageApi.native_sdk_app_render_pixel_size(app, 1, &info));
    const buffer = try std.testing.allocator.alloc(u8, info.byte_len);
    defer std.testing.allocator.free(buffer);
    var damage: types.MobileCanvasPixelsDamage = .{};
    try std.testing.expectEqual(@as(c_int, 1), MobileDamageApi.native_sdk_app_render_pixels_damage(app, 1, buffer.ptr, buffer.len, &damage));
    try std.testing.expectEqual(info.width, damage.damage_width);
    try std.testing.expectEqual(info.height, damage.damage_height);
}
