//! The embed C ABI, generic over the host that answers it.
//!
//! `MobileCApi(Host)` produces the full `native_sdk_app_*` function set
//! for a host type: the fixed WebView shell (`MobileHostApp`, this module's
//! re-exported default) or a user-app canvas host
//! (`ui_host.UiAppHost(AppDef)` in libs built via `addMobileLib`). A host
//! must expose `create`/`destroy`/`start`/`frame`, an `embedded`
//! `EmbeddedApp`, and the error/command/asset bookkeeping fields both
//! hosts share. `exportMobileCApi(Host)` exports every function under its
//! canonical symbol name for a static library root.

const std = @import("std");
const geometry = @import("geometry");
const types = @import("types.zig");
const host = @import("host.zig");
const chrome = @import("chrome.zig");
const conversions = @import("conversions.zig");

const MobileHostApp = host.MobileHostApp;
const MobileTextInputState = types.MobileTextInputState;
const MobileWidgetSemantics = types.MobileWidgetSemantics;
const MobileWidgetTextGeometry = types.MobileWidgetTextGeometry;
const MobileWidgetActionRequest = types.MobileWidgetActionRequest;
const MobileViewportState = types.MobileViewportState;
const MobileGpuFrameState = types.MobileGpuFrameState;
const MobileCanvasPixels = types.MobileCanvasPixels;
const mobile_gpu_surface_label = types.mobile_gpu_surface_label;
const recordError = host.recordError;
const mobileSurface = conversions.mobileSurface;
const mobileViewportStateFromSurface = conversions.mobileViewportStateFromSurface;
const mobileGpuFrameStateFromFrame = conversions.mobileGpuFrameStateFromFrame;
const inputSlice = conversions.inputSlice;
const mobileWidgetSemanticsFromNode = conversions.mobileWidgetSemanticsFromNode;
const mobileWidgetTextGeometryFromCanvas = conversions.mobileWidgetTextGeometryFromCanvas;
const mobileWidgetActionKindFromInt = conversions.mobileWidgetActionKindFromInt;

fn hostApp(comptime Host: type, raw: ?*anyopaque) ?*Host {
    const pointer = raw orelse return null;
    return @ptrCast(@alignCast(pointer));
}

/// Export every `MobileCApi(Host)` function under its own name. Call from
/// a `comptime` block in a static library's root module.
pub fn exportMobileCApi(comptime Host: type) void {
    const Api = MobileCApi(Host);
    inline for (@typeInfo(Api).@"struct".decls) |decl| {
        @export(&@field(Api, decl.name), .{ .name = decl.name });
    }
}

pub fn MobileCApi(comptime Host: type) type {
    return struct {
        pub fn native_sdk_app_create() callconv(.c) ?*anyopaque {
            const self = Host.create() catch return null;
            return self;
        }

        pub fn native_sdk_app_destroy(app: ?*anyopaque) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.destroy();
        }

        pub fn native_sdk_app_start(app: ?*anyopaque) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.start() catch |err| recordError(self, err);
        }

        pub fn native_sdk_app_activate(app: ?*anyopaque) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.embedded.activate() catch |err| recordError(self, err);
        }

        pub fn native_sdk_app_deactivate(app: ?*anyopaque) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.embedded.deactivate() catch |err| recordError(self, err);
        }

        pub fn native_sdk_app_stop(app: ?*anyopaque) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.embedded.stop() catch |err| recordError(self, err);
        }

        pub fn native_sdk_app_resize(app: ?*anyopaque, width: f32, height: f32, scale: f32, surface: ?*anyopaque) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            host.publishViewportChrome(self, .{});
            self.embedded.resize(mobileSurface(width, height, scale, surface, .{}, .{})) catch |err| recordError(self, err);
        }

        pub fn native_sdk_app_viewport(
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
        ) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            const safe_area = geometry.InsetsF.init(safe_top, safe_right, safe_bottom, safe_left);
            // Safe areas ride the window-chrome channel too (see
            // host.publishViewportChrome) before the resize dispatch, so
            // the chrome re-query the resize triggers reads fresh insets.
            host.publishViewportChrome(self, safe_area);
            self.embedded.resize(mobileSurface(
                width,
                height,
                scale,
                surface,
                safe_area,
                geometry.InsetsF.init(keyboard_top, keyboard_right, keyboard_bottom, keyboard_left),
            )) catch |err| recordError(self, err);
        }

        pub fn native_sdk_app_viewport_state(app: ?*anyopaque, out: ?*MobileViewportState) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            output.* = mobileViewportStateFromSurface(self.embedded.runtime.surface);
            self.last_error = null;
            return 1;
        }

        pub fn native_sdk_app_gpu_frame_state(app: ?*anyopaque, out: ?*MobileGpuFrameState) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            const frame = self.embedded.gpuFrameState() catch |err| {
                recordError(self, err);
                return 0;
            };
            output.* = mobileGpuFrameStateFromFrame(frame);
            self.last_error = null;
            return 1;
        }

        /// Focus / IME-intent state after input dispatch: `out.active` is
        /// nonzero while an editable text widget owns focus. Platform shims
        /// key the system keyboard's show/hide on it (UIKit first
        /// responder, Android InputMethodManager).
        pub fn native_sdk_app_text_input_state(app: ?*anyopaque, out: ?*MobileTextInputState) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            output.* = self.embedded.textInputState();
            self.last_error = null;
            return 1;
        }

        /// Register (or clear, with a null callback) the platform's text
        /// measurement for layout — the embed counterpart of the desktop
        /// `measure_text_fn` platform service (CoreText on macOS). Call it
        /// before `native_sdk_app_start` so the installing layout already
        /// measures with real font metrics; without it layout stays on the
        /// deterministic estimator.
        pub fn native_sdk_app_set_text_measure(app: ?*anyopaque, measure: ?types.MobileTextMeasureFn, context: ?*anyopaque) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            host.setTextMeasure(self, measure, context);
            self.last_error = null;
            return 1;
        }

        /// Enable the automation harness inside the embedded runtime,
        /// writing `snapshot.txt` (and consuming the `command-<n>.txt` queue) under
        /// `path` — an absolute directory inside the app's data container
        /// on device. The mobile counterpart of the desktop runners'
        /// `-Dautomation=true`.
        /// Register (or clear, with a null/empty table) the shim's
        /// platform audio service — the mobile counterpart of the desktop
        /// hosts' `audio_*_fn` platform services. Registration flips the
        /// host's `audio_playback`/`audio_streaming` capability answers to
        /// match the table; without a registration the host declines audio
        /// and `fx.playAudio` degrades to one explicit failed Msg. Register
        /// before `native_sdk_app_start`. Asynchronous player reports come
        /// back through `native_sdk_app_audio_event`.
        pub fn native_sdk_app_set_audio_service(app: ?*anyopaque, service: ?*const types.MobileAudioService, context: ?*anyopaque) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const table: types.MobileAudioService = if (service) |value| value.* else .{};
            host.setAudioService(self, table, context) catch |err| {
                recordError(self, err);
                return 0;
            };
            self.last_error = null;
            return 1;
        }

        /// One report from the shim's audio player (kind ordinals: 0
        /// loaded, 1 position, 2 completed, 3 failed), dispatched into the
        /// embedded runtime exactly like a desktop platform's `.audio`
        /// event. Call from the shim's loop thread between runtime entry
        /// points, never from inside an audio service callback — the same
        /// next-turn discipline the macOS host keeps.
        pub fn native_sdk_app_audio_event(app: ?*anyopaque, kind: c_int, position_ms: u64, duration_ms: u64, playing: c_int, buffering: c_int) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.embedded.audioEvent(kind, position_ms, duration_ms, playing != 0, buffering != 0) catch |err| {
                recordError(self, err);
                return;
            };
            self.last_error = null;
        }

        /// Register (or clear, with a null/empty table) the shim's
        /// platform image decoder — the mobile counterpart of the desktop
        /// hosts' `decode_image_fn` platform service (CGImageSource on
        /// macOS/iOS, BitmapFactory on Android). While registered,
        /// `fx.registerImageBytes` decodes encoded bytes through the shim
        /// callback synchronously; without a registration the host
        /// declines with `error.UnsupportedService` and image/avatar
        /// widgets keep their fallback. Register before
        /// `native_sdk_app_start` so a boot-effect registration already
        /// sees the codec.
        pub fn native_sdk_app_set_image_service(app: ?*anyopaque, service: ?*const types.MobileImageService, context: ?*anyopaque) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const table: types.MobileImageService = if (service) |value| value.* else .{};
            host.setImageService(self, table, context);
            self.last_error = null;
            return 1;
        }

        pub fn native_sdk_app_set_automation_dir(app: ?*anyopaque, path: ?[*]const u8, len: usize) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const dir = inputSlice(path, len) catch |err| {
                recordError(self, err);
                return 0;
            };
            host.enableAutomation(self, dir) catch |err| {
                recordError(self, err);
                return 0;
            };
            self.last_error = null;
            return 1;
        }

        pub fn native_sdk_app_touch(app: ?*anyopaque, id: u64, phase: c_int, x: f32, y: f32, pressure: f32) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.embedded.touch(id, phase, x, y, pressure) catch |err| {
                recordError(self, err);
                return;
            };
            self.last_error = null;
        }

        pub fn native_sdk_app_scroll(app: ?*anyopaque, id: u64, x: f32, y: f32, delta_x: f32, delta_y: f32) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.embedded.scroll(id, x, y, delta_x, delta_y) catch |err| {
                recordError(self, err);
                return;
            };
            self.last_error = null;
        }

        pub fn native_sdk_app_key(app: ?*anyopaque, phase: c_int, key: ?[*]const u8, key_len: usize, text: ?[*]const u8, text_len: usize, modifiers_mask: u32) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            const key_value = inputSlice(key, key_len) catch |err| {
                recordError(self, err);
                return;
            };
            const text_value = inputSlice(text, text_len) catch |err| {
                recordError(self, err);
                return;
            };
            self.embedded.key(phase, key_value, text_value, modifiers_mask) catch |err| {
                recordError(self, err);
                return;
            };
            self.last_error = null;
        }

        pub fn native_sdk_app_text(app: ?*anyopaque, text: ?[*]const u8, len: usize) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            const text_value = inputSlice(text, len) catch |err| {
                recordError(self, err);
                return;
            };
            self.embedded.text(text_value) catch |err| {
                recordError(self, err);
                return;
            };
            self.last_error = null;
        }

        pub fn native_sdk_app_ime(app: ?*anyopaque, kind: c_int, text: ?[*]const u8, len: usize, cursor: isize) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            const text_value = inputSlice(text, len) catch |err| {
                recordError(self, err);
                return;
            };
            self.embedded.ime(kind, text_value, cursor) catch |err| {
                recordError(self, err);
                return;
            };
            self.last_error = null;
        }

        pub fn native_sdk_app_command(app: ?*anyopaque, name: ?[*]const u8, len: usize) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            const ptr = name orelse {
                recordError(self, error.InvalidCommand);
                return;
            };
            self.embedded.command(ptr[0..len]) catch |err| {
                recordError(self, err);
                return;
            };
            self.last_error = null;
        }

        pub fn native_sdk_app_frame(app: ?*anyopaque) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.frame() catch |err| recordError(self, err);
        }

        // ------------------------------------------- declared platform chrome
        //
        // The read side of `ShellConfig.chrome`: a projecting host
        // queries the declared tab set and primary action once at
        // startup, builds REAL native controls from them, then polls the
        // selected index each frame to keep the bar a projection of the
        // model. Taps dispatch back through `native_sdk_app_command`
        // with the declared ids — the same command path the mobile
        // shell's native header buttons use — so selection state lives
        // in the model and replays deterministically.

        /// Number of declared platform-chrome tabs (0 when the app
        /// declares none — the host projects no bar).
        pub fn native_sdk_app_chrome_tab_count(app: ?*anyopaque) callconv(.c) usize {
            const self = hostApp(Host, app) orelse return 0;
            return self.chromeTabs().len;
        }

        /// One declared tab by index. The returned strings reference the
        /// app's static shell metadata (valid for the app's lifetime).
        pub fn native_sdk_app_chrome_tab_at(app: ?*anyopaque, index: usize, out: ?*chrome.MobileChromeItem) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            const tabs = self.chromeTabs();
            if (index >= tabs.len) {
                recordError(self, error.InvalidCommand);
                return 0;
            }
            output.* = chrome.chromeItemFromTab(tabs[index]);
            self.last_error = null;
            return 1;
        }

        /// The declared primary floating action: 1 with `out` filled
        /// when the app declared one, 0 when it did not (not an error).
        pub fn native_sdk_app_chrome_primary_action(app: ?*anyopaque, out: ?*chrome.MobileChromeItem) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            const action = self.chromePrimaryAction() orelse return 0;
            output.* = chrome.chromeItemFromAction(action);
            self.last_error = null;
            return 1;
        }

        /// The declared index of the tab the MODEL currently selects
        /// (the app's `selected_tab_fn` derivation), or -1 when the
        /// selection names no declared tab. The host's per-frame
        /// projection poll: when this differs from the native bar's
        /// selected item, the bar moves — never the other way around.
        pub fn native_sdk_app_chrome_selected_tab(app: ?*anyopaque) callconv(.c) isize {
            const self = hostApp(Host, app) orelse return -1;
            return chrome.selectedTabIndex(self.chromeTabs(), self.chromeSelectedTab());
        }

        /// The model's current navigation depth (the app's
        /// `navigation_depth_fn` derivation: 0 = the root page, 1 = one
        /// push in, ...), or -1 when the app declares no navigation
        /// projection (or before the first rebuild derives one). The
        /// host's per-tick poll for platform push/pop transitions: depth
        /// grew since the last poll = present a push, shrank = present a
        /// pop, and a poll that also moved the selected tab is a lateral
        /// tab switch (reconcile with no transition). Presentation only —
        /// the model owns navigation state and this is a pure derivation
        /// of it.
        pub fn native_sdk_app_chrome_navigation_depth(app: ?*anyopaque) callconv(.c) isize {
            const self = hostApp(Host, app) orelse return -1;
            return self.chromeNavigationDepth();
        }

        /// The declared back command the platform back gesture
        /// dispatches through `native_sdk_app_command` when it completes:
        /// 1 with `out.id` filled when the app declares one (static app
        /// data, valid for the app's lifetime), 0 when it does not — the
        /// host must not arm the interactive back gesture without it. A
        /// cancelled gesture dispatches nothing.
        pub fn native_sdk_app_chrome_navigation_back_command(app: ?*anyopaque, out: ?*chrome.MobileChromeItem) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            const command = self.chromeNavigationBackCommand();
            if (command.len == 0) return 0;
            output.* = .{ .id = command.ptr, .id_len = command.len };
            self.last_error = null;
            return 1;
        }

        /// Rasterize a declared icon-vocabulary glyph (a tab's or the
        /// primary action's `icon`) into the caller's tightly packed
        /// `size_px` x `size_px` RGBA8 buffer as premultiplied white on
        /// transparent — the template image shape system controls tint.
        /// Renders through the same vector core the canvas draws with;
        /// an unresolvable name renders the honest missing glyph.
        pub fn native_sdk_app_chrome_icon_pixels(app: ?*anyopaque, name: ?[*]const u8, name_len: usize, size_px: usize, pixels: ?[*]u8, pixels_len: usize) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const name_value = inputSlice(name, name_len) catch |err| {
                recordError(self, err);
                return 0;
            };
            const buffer = pixels orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            chrome.renderIconPixels(name_value, size_px, buffer[0..pixels_len]) catch |err| {
                recordError(self, err);
                return 0;
            };
            self.last_error = null;
            return 1;
        }

        /// Record the host-reported form factor (0 unknown, 1 compact,
        /// 2 regular) on the window-chrome channel: it rides the next
        /// chrome delivery into the app's `on_chrome` Msg, beside the
        /// safe-area insets, so apps switch shells on a host-reported
        /// field with width derivation as their fallback. Standing
        /// state — later viewport pushes keep it.
        pub fn native_sdk_app_set_form_factor(app: ?*anyopaque, form_factor: c_int) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            host.setFormFactor(self, chrome.formFactorFromInt(form_factor));
            self.last_error = null;
            return 1;
        }

        /// Record whether the host projects the declared chrome tabs as
        /// real native controls (nonzero = projected). Rides the chrome
        /// channel like the form factor, so an app's canvas tab switcher
        /// can yield to the native bar exactly while one exists.
        pub fn native_sdk_app_set_chrome_tabs_projected(app: ?*anyopaque, projected: c_int) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            host.setChromeTabsProjected(self, projected != 0);
            self.last_error = null;
            return 1;
        }

        pub fn native_sdk_app_set_asset_root(app: ?*anyopaque, path: [*]const u8, len: usize) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            if (len > self.asset_root.len) {
                recordError(self, error.WindowSourceTooLarge);
                return;
            }
            if (len == 0) {
                self.asset_root_len = 0;
                self.last_error = null;
                return;
            }
            @memcpy(self.asset_root[0..len], path[0..len]);
            self.asset_root_len = len;
            self.last_error = null;
        }

        pub fn native_sdk_app_set_asset_entry(app: ?*anyopaque, path: [*]const u8, len: usize) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            if (len > self.asset_entry.len) {
                recordError(self, error.WindowSourceTooLarge);
                return;
            }
            if (len == 0) {
                self.asset_entry_len = 0;
                self.last_error = null;
                return;
            }
            @memcpy(self.asset_entry[0..len], path[0..len]);
            self.asset_entry_len = len;
            self.last_error = null;
        }

        pub fn native_sdk_app_last_command_count(app: ?*anyopaque) callconv(.c) usize {
            const self = hostApp(Host, app) orelse return 0;
            return self.command_count;
        }

        pub fn native_sdk_app_last_command_name(app: ?*anyopaque) callconv(.c) [*:0]const u8 {
            const self = hostApp(Host, app) orelse return "";
            return @ptrCast(&self.last_command_name);
        }

        pub fn native_sdk_app_last_error_name(app: ?*anyopaque) callconv(.c) [*:0]const u8 {
            const self = hostApp(Host, app) orelse return "";
            const err = self.last_error orelse return "";
            return @errorName(err);
        }

        pub fn native_sdk_app_widget_semantics_count(app: ?*anyopaque) callconv(.c) usize {
            const self = hostApp(Host, app) orelse return 0;
            const semantics = self.embedded.widgetSemantics() catch return 0;
            return semantics.len;
        }

        pub fn native_sdk_app_widget_semantics_at(app: ?*anyopaque, index: usize, out: ?*MobileWidgetSemantics) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            const semantics = self.embedded.widgetSemantics() catch |err| {
                recordError(self, err);
                return 0;
            };
            if (index >= semantics.len) {
                recordError(self, error.InvalidCommand);
                return 0;
            }
            output.* = mobileWidgetSemanticsFromNode(semantics, index);
            self.last_error = null;
            return 1;
        }

        pub fn native_sdk_app_widget_semantics_by_id(app: ?*anyopaque, id: u64, out: ?*MobileWidgetSemantics) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            if (id == 0) {
                recordError(self, error.InvalidCommand);
                return 0;
            }
            const semantics = self.embedded.widgetSemantics() catch |err| {
                recordError(self, err);
                return 0;
            };
            for (semantics, 0..) |node, index| {
                if (node.id != id) continue;
                output.* = mobileWidgetSemanticsFromNode(semantics, index);
                self.last_error = null;
                return 1;
            }
            recordError(self, error.InvalidCommand);
            return 0;
        }

        pub fn native_sdk_app_widget_text_geometry(app: ?*anyopaque, id: u64, out: ?*MobileWidgetTextGeometry) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            if (id == 0) {
                recordError(self, error.InvalidCommand);
                return 0;
            }
            const geometry_value = self.embedded.widgetTextGeometry(id) catch |err| {
                recordError(self, err);
                return 0;
            };
            output.* = mobileWidgetTextGeometryFromCanvas(id, geometry_value);
            self.last_error = null;
            return 1;
        }

        pub fn native_sdk_app_widget_action(app: ?*anyopaque, request: ?*const MobileWidgetActionRequest) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const value = request orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            const kind = mobileWidgetActionKindFromInt(value.action) catch |err| {
                recordError(self, err);
                return 0;
            };
            const text_value = inputSlice(value.text, value.text_len) catch |err| {
                recordError(self, err);
                return 0;
            };
            if (kind == .set_selection and value.has_selection == 0) {
                recordError(self, error.InvalidCommand);
                return 0;
            }
            self.embedded.widgetAction(.{
                .id = value.id,
                .action = kind,
                .text = text_value,
                .selection = if (value.has_selection != 0) .{
                    .anchor = value.selection_anchor,
                    .focus = value.selection_focus,
                } else null,
            }) catch |err| {
                recordError(self, err);
                return 0;
            };
            self.last_error = null;
            return 1;
        }

        pub fn native_sdk_app_render_pixel_size(app: ?*anyopaque, scale: f32, out: ?*MobileCanvasPixels) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            const size = self.embedded.runtime.canvasScreenshotPixelSize(1, mobile_gpu_surface_label, renderScale(scale)) catch |err| {
                recordError(self, err);
                return 0;
            };
            output.* = .{ .width = size.width, .height = size.height, .byte_len = size.byte_len };
            self.last_error = null;
            return 1;
        }

        /// Render the mobile surface's retained canvas scene through the
        /// deterministic CPU reference renderer into the caller's RGBA8
        /// buffer (`native_sdk_app_render_pixel_size` gives the byte
        /// length). `scale <= 0` renders at scale 1.
        pub fn native_sdk_app_render_pixels(app: ?*anyopaque, scale: f32, pixels: ?[*]u8, pixels_len: usize, out: ?*MobileCanvasPixels) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            const buffer_ptr = pixels orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            const allocator = std.heap.page_allocator;
            const scratch = allocator.alloc(u8, pixels_len) catch |err| {
                recordError(self, err);
                return 0;
            };
            defer allocator.free(scratch);
            const screenshot = self.embedded.runtime.renderCanvasScreenshot(
                1,
                mobile_gpu_surface_label,
                renderScale(scale),
                buffer_ptr[0..pixels_len],
                scratch,
            ) catch |err| {
                recordError(self, err);
                return 0;
            };
            output.* = .{
                .width = screenshot.width,
                .height = screenshot.height,
                .byte_len = screenshot.rgba8.len,
            };
            self.last_error = null;
            return 1;
        }

        /// Incremental sibling of `native_sdk_app_render_pixels` for a
        /// host that keeps `pixels` RETAINED across calls (one buffer,
        /// one consumer). The fast path copies only the pixels the
        /// frames since the previous call changed — captured off the
        /// runtime's own dirty-scissored pixel present, so no second
        /// raster happens — and `out` reports that region in device
        /// pixels (an empty damage rect means the buffer already shows
        /// the current frame; skip the upload). The first call, a
        /// surface size or scale change, or the absence of a captured
        /// present fall back to a full render with full damage. The old
        /// entry keeps its render-every-call contract unchanged.
        pub fn native_sdk_app_render_pixels_damage(app: ?*anyopaque, scale: f32, pixels: ?[*]u8, pixels_len: usize, out: ?*types.MobileCanvasPixelsDamage) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            const buffer_ptr = pixels orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            const effective_scale = renderScale(scale) orelse 1;
            if (host.deliverPresentedPixels(self, effective_scale, buffer_ptr[0..pixels_len], output)) {
                // The buffer reflects everything the runtime has
                // PRESENTED (or planned as no visual change); a change
                // still waiting for its present reports the old revision
                // so the host calls again next tick.
                output.revision = self.embedded.canvasRevisions().presented;
                self.last_error = null;
                return 1;
            }
            // No matching capture: render the retained scene in full
            // (exactly the render-every-call sibling) and report the
            // whole surface damaged. Any pending capture delivery state
            // is reset so the next fast-path delivery re-syncs with a
            // full copy rather than trusting a buffer this full render
            // may have written at another scale.
            self.presented.delivered_epoch = 0;
            const allocator = std.heap.page_allocator;
            const scratch = allocator.alloc(u8, pixels_len) catch |err| {
                recordError(self, err);
                return 0;
            };
            defer allocator.free(scratch);
            const screenshot = self.embedded.runtime.renderCanvasScreenshot(
                1,
                mobile_gpu_surface_label,
                renderScale(scale),
                buffer_ptr[0..pixels_len],
                scratch,
            ) catch |err| {
                recordError(self, err);
                return 0;
            };
            output.* = .{
                .width = screenshot.width,
                .height = screenshot.height,
                .byte_len = screenshot.rgba8.len,
                .damage_x = 0,
                .damage_y = 0,
                .damage_width = screenshot.width,
                .damage_height = screenshot.height,
                // The full render painted the CURRENT retained scene.
                .revision = self.embedded.canvasRevisions().current,
            };
            self.last_error = null;
            return 1;
        }
    };
}

fn renderScale(scale: f32) ?f32 {
    if (!std.math.isFinite(scale) or scale <= 0) return null;
    return scale;
}

/// The default fixed WebView shell ABI (the host `zig build lib` produces).
const FixedShellApi = MobileCApi(MobileHostApp);

pub const native_sdk_app_create = FixedShellApi.native_sdk_app_create;
pub const native_sdk_app_destroy = FixedShellApi.native_sdk_app_destroy;
pub const native_sdk_app_start = FixedShellApi.native_sdk_app_start;
pub const native_sdk_app_activate = FixedShellApi.native_sdk_app_activate;
pub const native_sdk_app_deactivate = FixedShellApi.native_sdk_app_deactivate;
pub const native_sdk_app_stop = FixedShellApi.native_sdk_app_stop;
pub const native_sdk_app_resize = FixedShellApi.native_sdk_app_resize;
pub const native_sdk_app_viewport = FixedShellApi.native_sdk_app_viewport;
pub const native_sdk_app_viewport_state = FixedShellApi.native_sdk_app_viewport_state;
pub const native_sdk_app_gpu_frame_state = FixedShellApi.native_sdk_app_gpu_frame_state;
pub const native_sdk_app_text_input_state = FixedShellApi.native_sdk_app_text_input_state;
pub const native_sdk_app_set_text_measure = FixedShellApi.native_sdk_app_set_text_measure;
pub const native_sdk_app_set_audio_service = FixedShellApi.native_sdk_app_set_audio_service;
pub const native_sdk_app_audio_event = FixedShellApi.native_sdk_app_audio_event;
pub const native_sdk_app_set_image_service = FixedShellApi.native_sdk_app_set_image_service;
pub const native_sdk_app_set_automation_dir = FixedShellApi.native_sdk_app_set_automation_dir;
pub const native_sdk_app_touch = FixedShellApi.native_sdk_app_touch;
pub const native_sdk_app_scroll = FixedShellApi.native_sdk_app_scroll;
pub const native_sdk_app_key = FixedShellApi.native_sdk_app_key;
pub const native_sdk_app_text = FixedShellApi.native_sdk_app_text;
pub const native_sdk_app_ime = FixedShellApi.native_sdk_app_ime;
pub const native_sdk_app_command = FixedShellApi.native_sdk_app_command;
pub const native_sdk_app_frame = FixedShellApi.native_sdk_app_frame;
pub const native_sdk_app_chrome_tab_count = FixedShellApi.native_sdk_app_chrome_tab_count;
pub const native_sdk_app_chrome_tab_at = FixedShellApi.native_sdk_app_chrome_tab_at;
pub const native_sdk_app_chrome_primary_action = FixedShellApi.native_sdk_app_chrome_primary_action;
pub const native_sdk_app_chrome_selected_tab = FixedShellApi.native_sdk_app_chrome_selected_tab;
pub const native_sdk_app_chrome_navigation_depth = FixedShellApi.native_sdk_app_chrome_navigation_depth;
pub const native_sdk_app_chrome_navigation_back_command = FixedShellApi.native_sdk_app_chrome_navigation_back_command;
pub const native_sdk_app_chrome_icon_pixels = FixedShellApi.native_sdk_app_chrome_icon_pixels;
pub const native_sdk_app_set_form_factor = FixedShellApi.native_sdk_app_set_form_factor;
pub const native_sdk_app_set_chrome_tabs_projected = FixedShellApi.native_sdk_app_set_chrome_tabs_projected;
pub const native_sdk_app_set_asset_root = FixedShellApi.native_sdk_app_set_asset_root;
pub const native_sdk_app_set_asset_entry = FixedShellApi.native_sdk_app_set_asset_entry;
pub const native_sdk_app_last_command_count = FixedShellApi.native_sdk_app_last_command_count;
pub const native_sdk_app_last_command_name = FixedShellApi.native_sdk_app_last_command_name;
pub const native_sdk_app_last_error_name = FixedShellApi.native_sdk_app_last_error_name;
pub const native_sdk_app_widget_semantics_count = FixedShellApi.native_sdk_app_widget_semantics_count;
pub const native_sdk_app_widget_semantics_at = FixedShellApi.native_sdk_app_widget_semantics_at;
pub const native_sdk_app_widget_semantics_by_id = FixedShellApi.native_sdk_app_widget_semantics_by_id;
pub const native_sdk_app_widget_text_geometry = FixedShellApi.native_sdk_app_widget_text_geometry;
pub const native_sdk_app_widget_action = FixedShellApi.native_sdk_app_widget_action;
pub const native_sdk_app_render_pixel_size = FixedShellApi.native_sdk_app_render_pixel_size;
pub const native_sdk_app_render_pixels = FixedShellApi.native_sdk_app_render_pixels;
pub const native_sdk_app_render_pixels_damage = FixedShellApi.native_sdk_app_render_pixels_damage;
