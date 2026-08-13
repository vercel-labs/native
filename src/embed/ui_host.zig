//! Mobile embed host that drives a user `UiApp` (Model/Msg/update/view)
//! behind the same C ABI the fixed WebView shell answers.
//!
//! `UiAppHost(AppDef)` is the mobile equivalent of the desktop app runner:
//! the static library is compiled *with* the app. `AppDef` is the app's
//! root module (wired as the `"app"` import by `native_sdk.addMobileLib`)
//! and must declare:
//!
//! - `pub const Model` / `pub const Msg`
//! - `pub fn initModel() Model`
//! - `pub fn mobileOptions() native_sdk.UiApp(Model, Msg).Options` — the
//!   same options a desktop `UiApp` takes. The scene must contain a
//!   `gpu_surface` view labeled `mobile-surface` in the first window and
//!   `canvas_label` must be `mobile-surface` (use `mobile_shell_scene` /
//!   `mobile_gpu_surface_label` for the canonical single-surface scene).
//! - optional `pub const features: native_sdk.UiAppFeatures`
//!
//! The host owns a `NullPlatform` runtime (M1: no real surface — M2 adds
//! presentation) and pumps the `UiApp` loop from the shim's frame callback:
//! `native_sdk_app_frame` synthesizes the `gpu_surface_frame` event a
//! desktop platform's display link would deliver, which installs the widget
//! tree on the first tick and re-presents afterwards. Frames render through
//! the CPU reference renderer; the presented pixels are retrievable over
//! the ABI via `native_sdk_app_render_pixels`.

const std = @import("std");
const app_manifest = @import("app_manifest");
const canvas = @import("canvas");
const runtime = @import("../runtime/root.zig");
const platform = @import("../platform/root.zig");
const security = @import("../security/root.zig");
const types = @import("types.zig");
const host = @import("host.zig");
const conversions = @import("conversions.zig");

const EmbeddedApp = host.EmbeddedApp;
const mobile_gpu_surface_label = types.mobile_gpu_surface_label;
const max_mobile_command_name_bytes = types.max_mobile_command_name_bytes;
const max_mobile_asset_root_bytes = types.max_mobile_asset_root_bytes;
const max_mobile_asset_entry_bytes = types.max_mobile_asset_entry_bytes;
const nowNanoseconds = conversions.nowNanoseconds;

/// Canonical mobile scene: one window, one gpu_surface view labeled
/// `mobile-surface` filling it. Apps that need nothing else point their
/// `Options.scene` here.
pub const mobile_shell_views = [_]app_manifest.ShellView{.{
    .label = mobile_gpu_surface_label,
    .kind = .gpu_surface,
    .fill = true,
    .gpu_backend = .metal,
}};

pub const mobile_shell_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .views = &mobile_shell_views,
}};

pub const mobile_shell_scene: app_manifest.ShellConfig = .{ .windows = &mobile_shell_windows };

pub fn UiAppHost(comptime AppDef: type) type {
    return UiAppHostWithStorage(AppDef, false, false, &.{});
}

/// Capability-specialized mobile host. The boolean is comptime so a mobile
/// artifact without `store` never analyzes SQLite open/deinit and carries no
/// database symbols; `build/app.zig` supplies the manifest-inferred value.
pub fn UiAppHostWithRecordStore(comptime AppDef: type, comptime record_store_enabled: bool) type {
    return UiAppHostWithStorage(AppDef, record_store_enabled, false, &.{});
}

/// Capability-specialized mobile host for the two SQLite-backed storage
/// tiers. Both databases use the OS-owned data root but remain separate files.
pub fn UiAppHostWithStorage(
    comptime AppDef: type,
    comptime record_store_enabled: bool,
    comptime relational_store_enabled: bool,
    comptime relational_migrations: []const runtime.relational_store.Migration,
) type {
    return UiAppHostWithStorageAndCredentials(
        AppDef,
        record_store_enabled,
        relational_store_enabled,
        relational_migrations,
        false,
        false,
        "dev.native_sdk.app",
    );
}

/// Capability-specialized mobile host including the OS credential-store
/// gate and the app identity used as its service namespace.
pub fn UiAppHostWithStorageAndCredentials(
    comptime AppDef: type,
    comptime record_store_enabled: bool,
    comptime relational_store_enabled: bool,
    comptime relational_migrations: []const runtime.relational_store.Migration,
    comptime credentials_enabled: bool,
    comptime credentials_permitted: bool,
    comptime credentials_service: []const u8,
) type {
    const features: runtime.UiAppFeatures = if (@hasDecl(AppDef, "features")) AppDef.features else .{};
    const RecordStoreType = if (record_store_enabled) runtime.RecordStore else void;
    const RelationalStoreType = if (relational_store_enabled) runtime.RelationalStore else void;
    return struct {
        const Self = @This();

        pub const MobileUi = runtime.UiAppWithFeatures(AppDef.Model, AppDef.Msg, features);

        null_platform: platform.NullPlatform,
        ui: MobileUi,
        /// The UiApp's own runtime.App (typed dispatch into update/view);
        /// the host wraps it so ABI-facing counters observe every event.
        inner_app: runtime.App,
        embedded: EmbeddedApp,
        record_store: RecordStoreType = undefined,
        record_store_open: bool = false,
        relational_store: RelationalStoreType = undefined,
        relational_store_open: bool = false,
        started: bool = false,
        frame_index: u64 = 0,
        last_error: ?anyerror = null,
        command_count: usize = 0,
        last_command_name: [max_mobile_command_name_bytes + 1]u8 = [_]u8{0} ** (max_mobile_command_name_bytes + 1),
        asset_root: [max_mobile_asset_root_bytes]u8 = undefined,
        asset_root_len: usize = 0,
        asset_entry: [max_mobile_asset_entry_bytes]u8 = undefined,
        asset_entry_len: usize = 0,
        automation_dir: [max_mobile_asset_root_bytes]u8 = undefined,
        automation_dir_len: usize = 0,
        automation_io: ?*std.Io.Threaded = null,
        text_measure: host.MobileTextMeasure = .{},
        audio: host.MobileAudio = .{},
        credentials: host.MobileCredentials = .{},
        // Image decode stays declined until the shim registers a real
        // codec (`native_sdk_app_set_image_service`): the null platform's
        // strict test decoder is opt-in (`image_decode`, default off), so
        // with no registration `fx.registerImageBytes` reports
        // UnsupportedService and image/avatar widgets keep their fallback.
        image: host.MobileImage = .{},
        /// Standing host chrome reports (see `host.setFormFactor` /
        /// `host.setChromeTabsProjected`): composed into every
        /// viewport-driven chrome publish.
        form_factor: platform.FormFactor = .unknown,
        chrome_tabs_projected: bool = false,
        /// Presented-pixel capture behind
        /// `native_sdk_app_render_pixels_damage` (see
        /// `host.installPresentCapture`): the last present's borrowed
        /// pixels plus accumulated damage, and the chained platform
        /// pixel presenter the capture bridge forwards to.
        presented: host.MobilePresentedCanvas = .{},
        present_pixels_chain: ?host.MobilePresentPixelsFn = null,
        /// Render memo for the pixel present path (heavyweight command
        /// replay + scale-once image panels); attached to the runtime by
        /// `host.installPresentCapture`, freed on destroy.
        render_memo: canvas.ReferenceRenderMemo = undefined,

        pub fn create() !*Self {
            const allocator = std.heap.page_allocator;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const options = AppDef.mobileOptions();
            if (!std.mem.eql(u8, options.canvas_label, mobile_gpu_surface_label)) return error.InvalidViewOptions;
            if (!sceneHasMobileSurface(options.scene)) return error.ViewNotFound;
            self.null_platform = platform.NullPlatform.initWithOptions(.{}, .system, .{
                .app_name = options.name,
                .bundle_id = credentials_service,
            });
            self.null_platform.gpu_surfaces = true;
            // Audio is declined until the shim registers a real service
            // (`native_sdk_app_set_audio_service`): without one,
            // `fx.playAudio` degrades to one explicit `.failed` Msg
            // instead of the null platform's hermetic fake player
            // pretending to play. Cleared before `platform()` is
            // snapshotted below.
            self.null_platform.audio_playback = false;
            self.null_platform.audio_streaming = false;
            self.null_platform.microphone_capture = false;
            self.null_platform.system_audio_capture = false;
            // The null packet presenter records only counts; disabling it
            // routes presentation through the CPU pixel path so frames
            // produce real pixels (the buffer M2's surface blit consumes).
            self.null_platform.gpu_surface_packets = false;
            self.started = false;
            self.record_store_open = false;
            self.relational_store_open = false;
            self.frame_index = 0;
            self.last_error = null;
            self.command_count = 0;
            self.last_command_name = [_]u8{0} ** (max_mobile_command_name_bytes + 1);
            self.asset_root = undefined;
            self.asset_root_len = 0;
            self.asset_entry = undefined;
            self.asset_entry_len = 0;
            self.automation_dir = undefined;
            self.automation_dir_len = 0;
            self.automation_io = null;
            self.text_measure = .{};
            self.audio = .{};
            self.credentials = .{};
            self.image = .{};
            self.form_factor = .unknown;
            self.chrome_tabs_projected = false;
            self.presented = .{};
            self.present_pixels_chain = null;
            // In-place init + pointer-targeted model assignment:
            // `initModel()`'s result writes straight into the heap
            // struct via result-location semantics, so a multi-MB Model
            // never materializes on this stack frame.
            MobileUi.initInPlace(&self.ui, allocator, options);
            self.ui.model = AppDef.initModel();
            self.inner_app = self.ui.app();
            self.embedded.initInPlace(.{
                .context = self,
                .name = options.name,
                .scene_fn = hostScene,
                .event_fn = hostEvent,
                .stop_fn = hostStop,
            }, self.null_platform.platform());
            // The NullPlatform map is for native test only. Installed mobile
            // apps start with no backing until the UIKit/Android shim
            // registers its OS credential service.
            try host.setCredentialService(self, .{}, null);
            self.embedded.runtime.options.credentials_enabled = credentials_enabled;
            self.embedded.runtime.options.security.permissions = if (credentials_permitted)
                &.{security.permission_credentials}
            else
                &.{};
            // The damage seam: capture pixel presents (chained through
            // the null platform's recording present, so nonblank
            // sampling keeps working), drop the packet presenters no
            // mobile shim consumes, and keep the keyed baseline alive
            // across pixel presents so changed frames raster only their
            // dirty region.
            host.installPresentCapture(self);
            return self;
        }

        /// Returns true when teardown deliberately preserves the host because
        /// an abandoned platform callback may still enter it. Mobile shims
        /// use the companion C ABI result to preserve their callback context
        /// under the same condition.
        pub fn destroy(self: *Self) bool {
            host.disableAutomation(self);
            self.render_memo.deinit();
            self.ui.deinit();
            // One lifecycle owner: the embedded app's own deinit returns
            // its heap-owned registrations (registered canvas font
            // bytes) before the host storage goes.
            self.embedded.deinit();
            if (comptime record_store_enabled) {
                if (self.record_store_open) self.record_store.deinit();
            }
            if (comptime relational_store_enabled) {
                if (self.relational_store_open) self.relational_store.deinit();
            }
            // The embedded null platform lives inside `self`, so freeing
            // `self` IS this path's platform destruction — and an
            // abandoned platform call may still enter that platform
            // at any later time (see
            // `PlatformServices.note_channel_wake_abandoned_fn`; the
            // null platform's own enqueue-only wake never triggers it,
            // but a shim-registered service could). Consult the latch
            // like every first-party destroy path: skip the free and
            // leak the host storage, process-lived, with one loud line.
            if (self.null_platform.channel_wake_abandoned.load(.seq_cst)) {
                std.debug.print("mobile ui host teardown: an abandoned platform call may still enter the embedded platform; skipping the host free and leaking it, process-lived, so the stale call stays safe\n", .{});
                return true;
            }
            std.heap.page_allocator.destroy(self);
            return false;
        }

        pub fn start(self: *Self) anyerror!void {
            if (comptime record_store_enabled) {
                if (!self.record_store_open) return error.StoreDataDirUnavailable;
            }
            if (comptime relational_store_enabled) {
                if (!self.relational_store_open) return error.SqliteDataDirUnavailable;
            }
            self.started = true;
            try self.embedded.start();
        }

        /// Install the OS-owned app-data directory before start. iOS passes
        /// Library/Application Support and Android passes files/, exactly the
        /// `.data` directories resolved by `app_dirs` on those platforms.
        pub fn setDataRoot(self: *Self, data_root: []const u8) !void {
            if (comptime !record_store_enabled and !relational_store_enabled) return;
            if (self.started) return error.AppAlreadyStarted;
            if (data_root.len == 0 or data_root.len > max_mobile_asset_root_bytes) return error.InvalidStoreDataDir;
            if (comptime record_store_enabled) {
                if (self.record_store_open) {
                    self.record_store.deinit();
                    self.record_store_open = false;
                    self.embedded.runtime.options.record_store = null;
                }
                self.record_store = try runtime.RecordStore.open(std.heap.page_allocator, data_root);
                self.record_store_open = true;
                self.embedded.runtime.options.record_store = self.record_store.binding();
            }
            if (comptime relational_store_enabled) {
                if (self.relational_store_open) {
                    self.relational_store.deinit();
                    self.relational_store_open = false;
                    self.embedded.runtime.options.relational_store = null;
                }
                const opened = try runtime.RelationalStore.openMigrated(std.heap.page_allocator, data_root, relational_migrations);
                self.relational_store = switch (opened.outcome) {
                    .ok => opened.database.?,
                    .migrate_failed => return error.SqliteMigrationFailed,
                    .version_unknown => return error.SqliteVersionUnknown,
                };
                self.relational_store_open = true;
                self.embedded.runtime.options.relational_store = self.relational_store.binding();
            }
        }

        /// Host-pumped frame step: the shim's display-link (or test) tick.
        /// Synthesizes the `gpu_surface_frame` event a platform loop would
        /// deliver for the mobile surface — first tick installs the widget
        /// tree, later ticks re-present — then runs the runtime frame
        /// (automation, diagnostics). `nonblank`/`sample_color` report the
        /// previously presented pixels, mirroring how real platforms report
        /// the surface's current contents.
        pub fn frame(self: *Self) anyerror!void {
            const surface = self.embedded.runtime.surface;
            if (self.started and surface.size.width > 0 and surface.size.height > 0) {
                self.frame_index += 1;
                const presented = self.null_platform.gpu_surface_present_count > 0;
                const sample = self.null_platform.gpu_surface_present_sample_rgba;
                const sample_color = (@as(u32, sample[0]) << 24) |
                    (@as(u32, sample[1]) << 16) |
                    (@as(u32, sample[2]) << 8) |
                    @as(u32, sample[3]);
                try self.embedded.runtime.dispatchPlatformEvent(self.embedded.app, .{ .gpu_surface_frame = .{
                    .window_id = 1,
                    .label = mobile_gpu_surface_label,
                    .size = surface.size,
                    .scale_factor = surface.scale_factor,
                    .frame_index = self.frame_index,
                    .timestamp_ns = nowNanoseconds(),
                    .nonblank = presented and sample_color != 0,
                    .sample_color = sample_color,
                    .status = .ready,
                } });
            }
            try self.embedded.frame();
        }

        fn hostScene(context: *anyopaque) anyerror!app_manifest.ShellConfig {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.ui.options.scene;
        }

        /// The app's declared platform-chrome tab set — the shell
        /// metadata a projecting host builds a REAL native tab bar
        /// from. Static manifest data, valid for the app's lifetime.
        pub fn chromeTabs(self: *const Self) []const app_manifest.ShellTab {
            return self.ui.options.scene.chrome.tabs;
        }

        /// The declared primary floating action, when the app declared
        /// one beside its tab set.
        pub fn chromePrimaryAction(self: *const Self) ?app_manifest.ShellPrimaryAction {
            return self.ui.options.scene.chrome.primary_action;
        }

        /// The model's current selected tab id (the UiApp's
        /// `selected_tab_fn` derivation, re-derived after every
        /// rebuild) — what the projected bar mirrors.
        pub fn chromeSelectedTab(self: *const Self) []const u8 {
            return self.ui.chromeSelectedTab();
        }

        /// The model's current navigation depth (the UiApp's
        /// `navigation_depth_fn` derivation, re-derived after every
        /// rebuild), or -1 when the app declares none — what a
        /// projecting host polls to present push/pop transitions.
        pub fn chromeNavigationDepth(self: *const Self) isize {
            return self.ui.chromeNavigationDepth();
        }

        /// The declared back command the platform back gesture
        /// dispatches on completion ("" when the app declares no
        /// navigation projection). Static app data.
        pub fn chromeNavigationBackCommand(self: *const Self) []const u8 {
            return self.ui.chromeNavigationBackCommand();
        }

        fn hostEvent(context: *anyopaque, runtime_value: *runtime.Runtime, event: runtime.Event) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(context));
            switch (event) {
                .command => |command_event| {
                    self.command_count += 1;
                    const count = @min(command_event.name.len, max_mobile_command_name_bytes);
                    @memcpy(self.last_command_name[0..count], command_event.name[0..count]);
                    self.last_command_name[count] = 0;
                },
                else => {},
            }
            try self.inner_app.event(runtime_value, event);
        }

        /// Forward the stop hook to the inner UiApp: a shim-driven
        /// shutdown (`native_sdk_app_stop` dispatching `.app_shutdown`)
        /// tears the effects channel down while the host's service
        /// table is alive, so the later `destroy` → `ui.deinit` repeats
        /// nothing against the platform.
        fn hostStop(context: *anyopaque, runtime_value: *runtime.Runtime) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.inner_app.stop(runtime_value);
        }
    };
}

fn sceneHasMobileSurface(scene: app_manifest.ShellConfig) bool {
    if (scene.windows.len == 0) return false;
    for (scene.windows[0].views) |view| {
        if (view.kind == .gpu_surface and std.mem.eql(u8, view.label, mobile_gpu_surface_label)) return true;
    }
    return false;
}
