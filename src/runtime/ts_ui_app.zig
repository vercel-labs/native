//! `TsUiApp(core)` — the first-class UiApp adapter for compiled
//! TypeScript app cores: the committed TS model IS the app model. Where a Zig core
//! hands `UiApp` a mutable model plus `update`, a compiled TypeScript core is an
//! immutable committed graph plus a pure `update` returning the next
//! root — this adapter closes that gap with no per-app glue:
//!
//!   Model    = core.Model — the emitted struct itself. Markup views
//!              (`canvas.CompiledMarkupView(core.Model, core.Msg, src)`)
//!              and Zig builder views bind its fields directly; the
//!              binding names are the TS interface's own field names
//!              (`lastTickAt` binds as `{lastTickAt}` — the emitted
//!              struct keeps the TS spellings), and record arrays /
//!              nested records bind through markup's `*const`
//!              transparency.
//!   update   = the bridge (`TsCoreHost(core)`): every Msg runs the
//!              core's dispatch cycle — update, commit, command walk,
//!              subscription reconcile — and the UiApp-held root is
//!              refreshed to the committed value. Every pointer inside
//!              it IS the committed graph (valid until the next
//!              dispatch, exactly a view build's lifetime).
//!   init     = the core's `initialModel`: the boot model commits at
//!              construction (so `tokens_fn`, pre-install appearance /
//!              chrome dispatches, and the installing view build all
//!              read real state), and the boot command + initial
//!              subscriptions fire through `init_fx` on the installing
//!              frame — the same init semantics Zig cores get.
//!
//! THE HOST-EVENT CHANNELS are the core's own, comptime-detected from
//! its exports (export exists -> wired; a wiring that also sets the
//! seam is a teaching panic): `frameMsg(model, frame)` -> `on_frame`,
//! `keyMsg(key)` -> `on_key`, `dropMsg(drop)` -> `on_drop`, and the arm
//! exports `appearanceMsg` / `chromeMsg` -> `on_appearance`/`on_chrome`, each host event built
//! structurally by field name from the core's declared records (the
//! effects-routing rule applied to the app shell; every shape mismatch
//! is a teaching compile error re-deriving the frontend's NS1033).
//! `CoreOptions` carries the launch-boundary channels the wiring
//! resolves: `boot_images` (app.zon assets, registered on the
//! installing frame) and `env_values` (the core's `envMsgs` variables,
//! dispatched as journaled Msgs right after the boot command).
//!
//! Everything else on `UiApp.Options` is the wiring's, unchanged: view
//! or markup, scene, `on_command` maps command ids through the core's
//! `commandMsg`, `tokens_fn`/`windows_fn`/status-item callbacks derive from
//! the committed model. One model-helper convention joins that wiring:
//! an exported `themePack(model): "house" | "geist"` helper selects the
//! stock pack live through `theme_fn`, without taking ownership of the
//! system appearance axes; `themeState(model)` subsumes it with scheme and
//! accent axes through `theme_state_fn`. An exported
//! `statusItem(model): StatusItemState` helper similarly owns one complete
//! menu-bar item through `status_item_fn`; `statusItems(model)` owns a keyed
//! collection through `status_items_fn`. Both keep shell, presentation, and
//! menu live. `windows(model): readonly WindowDescriptor[]` owns the
//! model-declared secondary-window set through `windows_fn`; the launcher or
//! hand wiring supplies the statically compiled `window_view` registry. In
//! hand wiring, empty singular shell fields inherit the static `status_item`
//! options. The two
//! seams the core owns — `update_fx` and
//! `init_fx` — are stamped by this adapter and must be left null.
//!
//! `Options.sync` is deliberately unsupported: it mutates the model in
//! place, which cannot exist for a committed graph. TS apps keep
//! continuous controls model-driven (`on-change`/`on-scroll` Msgs echo
//! the value back into the model — the pattern UiApp already supports).
//!
//! Record/replay, automation, and pixel fingerprints need nothing
//! extra: the adapter rides the ordinary UiApp dispatch path, so the
//! session journal, the automation verbs, and the screenshot marks see
//! a compiled TypeScript core exactly as they see a Zig one. The
//! process contract is the bridge's: one live app per core module (two
//! apps over one core would share a committed root), and one compiled
//! archive per process (the fixed-prefix C ABI symbol set).
//!
//! Generated launchers use `TsUiAppWithFeatures` to compile the runtime
//! markup interpreter out of release and mobile artifacts while preserving
//! `TsUiApp` as the full-featured default for hand wiring and tests.

const std = @import("std");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");
const runtime_core = @import("core.zig");
const runtime_effects = @import("effects.zig");
const persist_store = @import("persist_store.zig");
const ui_app = @import("ui_app.zig");
const ts_core_host = @import("ts_core_host.zig");

const ts_ui_app_log = std.log.scoped(.zero_ts_ui_app);

/// Quota for a comptime scan of an app-authored type. TS `Msg` unions may
/// legally carry 256 arms; include total identifier bytes because
/// `std.mem.eql`'s comptime scalar path scales with the compared names.
fn typeScanQuota(comptime T: type) u32 {
    const fields = switch (@typeInfo(T)) {
        .@"struct" => |info| info.fields,
        .@"union" => |info| info.fields,
        .@"enum" => |info| info.fields,
        else => return 2_000,
    };
    var name_bytes: u64 = 0;
    for (fields) |field| name_bytes += field.name.len;
    const quota: u64 = 100_000 + @as(u64, fields.len) * 1_024 + name_bytes * 256;
    return @intCast(@min(quota, std.math.maxInt(u32)));
}

fn scaledTypeScanQuota(comptime T: type, comptime scans: usize) u32 {
    const quota = @as(u64, typeScanQuota(T)) * @max(scans, 1);
    return @intCast(@min(quota, std.math.maxInt(u32)));
}

pub fn TsUiApp(comptime core: type) type {
    return TsUiAppWithFeatures(core, .{});
}

/// Feature-selectable counterpart used by generated wiring: Debug desktop
/// apps keep the runtime markup interpreter for hot reload, while release and
/// mobile apps compile it out after installing the same comptime view.
pub fn TsUiAppWithFeatures(comptime core: type, comptime features: ui_app.UiAppFeatures) type {
    return struct {
        /// The effect bridge — shared with any direct `TsCoreHost(core)`
        /// instantiation (comptime memoization), so harnesses can read
        /// `Host.model()` and tests can name the bridge's key bases.
        pub const Host = ts_core_host.TsCoreHost(core);
        pub const Model = core.Model;
        pub const Msg = core.Msg;
        pub const view_backend = if (@hasDecl(core, "nativeView")) "typescript" else "zig";
        pub const App = ui_app.UiAppWithFeatures(Model, Msg, features);
        pub const Options = App.Options;
        pub const Effects = App.Effects;
        pub const Ui = App.Ui;
        /// Shared with generated launchers that perform their own Msg scans.
        pub const msg_scan_quota = typeScanQuota(Msg);
        pub const persist_route_scan_quota = scaledTypeScanQuota(Msg, 3);

        /// Internal keyed-channel namespace for persistence write failures
        /// ("TSPR"). It never shares an app-authored TS bridge index.
        const persist_outcome_channel_key: u64 = 0x5453_5052_0000_0001;

        /// One boot-registered image: the wiring reads the encoded bytes
        /// (app.zon's `.assets.images` paths) and the adapter registers
        /// them on the installing frame — `fx.registerImageBytes`, the
        /// Zig apps' `init_fx` convention. A failed decode skips the
        /// entry: views keep their fallback (avatar initials), a bad
        /// asset never breaks presentation.
        pub const BootImage = struct {
            id: u64,
            bytes: []const u8,
        };

        /// One launch-time environment override (the core's `envMsgs`
        /// channel): `msg` names the core's one-bytes-field arm, `value`
        /// the variable's bytes. Dispatched as ordinary Msgs right after
        /// the boot command on the installing frame — each delivery is
        /// journaled (an `.env` effect record), so replay feeds the
        /// recorded values and never re-reads the environment (see
        /// `dispatchEnvValues`).
        pub const EnvValue = struct {
            msg: []const u8,
            value: []const u8,
        };

        pub const PersistRoutes = struct {
            ok: []const u8,
            none: []const u8,
            err: []const u8,
        };

        pub const PersistRestore = struct {
            outcome: persist_store.Outcome,
            bytes: []const u8 = "",
            migration_from_version: ?u64 = null,
        };

        pub const PersistOptions = struct {
            binding: runtime_effects.HostCallBinding,
            routes: PersistRoutes,
            restore: PersistRestore,
            /// Runner-owned slot populated during install. The store worker
            /// posts failed writes through it, gaining ordinary effect wake,
            /// ordering, journaling, and replay semantics.
            outcome_handle: ?*runtime_effects.ChannelHandle = null,
        };

        /// One effects host binding must carry both app services and the
        /// framework-owned persistence verbs when an app enables both. The
        /// reserved persistence names route to that binding; every other
        /// command and the worker completion lifecycle stay with the app
        /// service carrier.
        const HostCallMux = struct {
            primary: runtime_effects.HostCallBinding,
            persist: runtime_effects.HostCallBinding,

            fn binding(self: *HostCallMux) runtime_effects.HostCallBinding {
                return .{
                    .context = self,
                    .send_fn = send,
                    .request_fn = request,
                    .cancel_fn = cancel,
                    .reject_duplicate_keys = self.primary.reject_duplicate_keys,
                    .poll_fn = poll,
                    .pending_fn = pending,
                    .bind_services_fn = bindServices,
                    .bind_channels_fn = bindChannels,
                    .shutdown_fn = shutdown,
                };
            }

            fn targets(operation: u8, name: []const u8) [2]u8 {
                if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                    var inline_request: [256]u8 = undefined;
                    const request_bytes = if (name.len <= inline_request.len - 3) inline_request[0 .. 3 + name.len] else std.heap.page_allocator.alloc(u8, 3 + name.len) catch @panic("service carrier request allocation failed");
                    defer if (name.len > inline_request.len - 3) std.heap.page_allocator.free(request_bytes);
                    request_bytes[0..3].* = .{ 18, 7, operation };
                    @memcpy(request_bytes[3..], name);
                    const plan = compiledLifecycle(request_bytes);
                    if (plan[0] == 0 or plan[0] > 2 or plan[1] > 2 or (operation < 5 and plan[1] != 0))
                        @panic("invalid compiled service carrier plan");
                    for (plan[2..]) |byte| if (byte != 0) @panic("invalid compiled service carrier reserved byte");
                    return plan[0..2].*;
                }
                return if (operation < 2 and (std.mem.eql(u8, name, "core.persist") or std.mem.eql(u8, name, "core.persist.flush")))
                    .{ 2, 0 }
                else if (operation >= 5) .{ 1, 2 } else .{ 1, 0 };
            }

            fn carrier(self: *HostCallMux, target: u8) runtime_effects.HostCallBinding {
                return switch (target) {
                    1 => self.primary,
                    2 => self.persist,
                    else => @panic("invalid service carrier target"),
                };
            }

            fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                const target = self.carrier(targets(0, name)[0]);
                target.send_fn(target.context, name, payload);
            }

            fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                const target = self.carrier(targets(1, name)[0]);
                target.request_fn(target.context, name, key, payload);
            }

            fn cancel(context: *anyopaque, key: u64) void {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                const target = self.carrier(targets(2, "")[0]);
                if (target.cancel_fn) |cancel_fn| cancel_fn(target.context, key);
            }

            fn poll(context: *anyopaque) ?runtime_effects.HostCallCompletion {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                const target = self.carrier(targets(3, "")[0]);
                const poll_fn = target.poll_fn orelse return null;
                return poll_fn(target.context);
            }

            fn pending(context: *anyopaque) bool {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                const target = self.carrier(targets(4, "")[0]);
                const pending_fn = target.pending_fn orelse return false;
                return pending_fn(target.context);
            }

            fn bindServices(context: *anyopaque, services: *const platform.PlatformServices) void {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                for (targets(5, "")) |selection| {
                    if (selection == 0) break;
                    const target = self.carrier(selection);
                    if (target.bind_services_fn) |bind_fn| bind_fn(target.context, services);
                }
            }

            fn bindChannels(context: *anyopaque, channels: runtime_effects.HostChannelBinding) void {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                for (targets(6, "")) |selection| {
                    if (selection == 0) break;
                    const target = self.carrier(selection);
                    if (target.bind_channels_fn) |bind_fn| bind_fn(target.context, channels);
                }
            }

            fn shutdown(context: *anyopaque) void {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                for (targets(7, "")) |selection| {
                    if (selection == 0) break;
                    const target = self.carrier(selection);
                    if (target.shutdown_fn) |shutdown_fn| shutdown_fn(target.context);
                }
            }
        };

        /// Build-time manifest/wire fence for the three persistence routes.
        /// The generated runner calls this with app.zon's comptime strings so
        /// a typo or payload mismatch fails during `native build`, before a
        /// first boot can reach the dynamic dispatch path below.
        pub fn validatePersistRoutes(comptime routes: PersistRoutes) void {
            @setEvalBranchQuota(persist_route_scan_quota);
            validatePersistRoute(routes.ok, void, "ok");
            validatePersistRoute(routes.none, void, "none");
            validatePersistRoute(routes.err, []const u8, "err");
        }

        fn validatePersistRoute(comptime route: []const u8, comptime Payload: type, comptime role: []const u8) void {
            @setEvalBranchQuota(msg_scan_quota);
            inline for (@typeInfo(Msg).@"union".fields) |arm| {
                if (comptime std.mem.eql(u8, arm.name, route)) {
                    if (arm.type != Payload) {
                        @compileError(std.fmt.comptimePrint(
                            "persistence restore route `{s}` ({s}) has the wrong Msg payload; ok/none must be void and err must carry one Uint8Array field",
                            .{ route, role },
                        ));
                    }
                    return;
                }
            }
            @compileError(std.fmt.comptimePrint(
                "persistence restore route `{s}` ({s}) names no Msg arm",
                .{ route, role },
            ));
        }

        /// Adapter-owned configuration — the knobs that exist because
        /// the core is TypeScript, kept separate from `App.Options` so
        /// the wiring surface reads as ordinary UiApp wiring.
        pub const CoreOptions = struct {
            /// Platform caches directory for URL audio playback: when a
            /// core's `Cmd.audioPlay` names a URL with no cachePath, the
            /// bridge derives the engine's conventional content-addressed
            /// path under this directory (soundboard's convention,
            /// resolved by the wiring at boot via `app_dirs` — never
            /// read from the environment inside update). Empty disables
            /// derivation: URL playback still works, it just re-streams.
            audio_cache_dir: []const u8 = "",
            /// Platform caches directory for URL image loads —
            /// `audio_cache_dir`'s twin for `Cmd.imageLoad`: a URL
            /// record with no cachePath loads under the conventional
            /// content-addressed path in this directory. Empty disables
            /// derivation: URL loads still work, they just re-fetch.
            image_cache_dir: []const u8 = "",
            /// Images registered at install, before the first view build
            /// (see `BootImage`). The slices must outlive install (the
            /// wiring reads them into launch-lifetime buffers).
            boot_images: []const BootImage = &.{},
            /// Launch-time environment overrides (see `EnvValue`), only
            /// meaningful for cores exporting `envMsgs`. The slices must
            /// outlive install.
            env_values: []const EnvValue = &.{},
            /// Generated service registry/carrier for Cmd.host/request. Null
            /// preserves the existing embedding-host behavior.
            host_calls: ?runtime_effects.HostCallBinding = null,
            /// Typed service result projection generated from the same
            /// sidecar as `host_calls`. Null keeps raw Cmd.request byte
            /// routing for embedders and apps without services.
            service_results: ?Host.ServiceResultBinding = null,
            persist: ?PersistOptions = null,
        };

        /// Construct the UiApp over the committed TS model. `options`
        /// carries the wiring seams only — `update`, `update_fx`, and
        /// `init_fx` belong to the core and must be null; `sync` cannot
        /// exist for a committed model (see the module doc).
        pub fn init(backing: std.mem.Allocator, core_options: CoreOptions, options: Options) App {
            const stamped = stampOptions(options);
            Host.boot();
            applyCoreOptions(core_options);
            return App.init(backing, Host.model().*, stamped);
        }

        /// Mobile counterpart of `init`/`create`: the embed host
        /// (`native_sdk.embed.UiAppHost`) owns App construction, so this
        /// resolves the adapter's stamped options and applies the core
        /// options — the boot model commits here, and the generated mobile
        /// wiring's `initModel` reads `Host.model()` afterwards. The embed
        /// host then drives the same stamped `init_fx`/`update_fx` seams
        /// the desktop wiring gets.
        pub fn mobileOptions(core_options: CoreOptions, options: Options) Options {
            const stamped = stampOptions(options);
            Host.boot();
            applyCoreOptions(core_options);
            return stamped;
        }

        /// Heap counterpart of `init`, mirroring `UiApp.create`: the app
        /// struct (and any real model) is multi-MB, so construct it in
        /// place on the heap — the shape generated wiring and `main`
        /// functions use. Pair with `App.destroy`.
        pub fn create(backing: std.mem.Allocator, core_options: CoreOptions, options: Options) error{OutOfMemory}!*App {
            const stamped = stampOptions(options);
            Host.boot();
            applyCoreOptions(core_options);
            const self = try backing.create(App);
            App.initInPlace(self, backing, stamped);
            self.model = Host.model().*;
            return self;
        }

        /// Adapter-held install state (container-level like the bridge's
        /// tables — one live app per core module is the v1 contract):
        /// `initFx` is a plain fn pointer, so the boot images and env
        /// values it performs ride here between construction and the
        /// installing frame.
        var boot_images_store: []const BootImage = &.{};
        var env_values_store: []const EnvValue = &.{};
        var host_calls_store: ?runtime_effects.HostCallBinding = null;
        var persist_options_store: ?PersistOptions = null;
        var host_call_mux_store: ?HostCallMux = null;
        var lifecycle_store: ?*const fn (event: runtime_core.LifecycleEvent) ?Msg = null;
        var command_store: ?*const fn (name: []const u8) ?Msg = null;
        var lifecycle_flush_after_update = false;

        fn applyCoreOptions(core_options: CoreOptions) void {
            Host.setAudioCacheDir(core_options.audio_cache_dir);
            Host.setImageCacheDir(core_options.image_cache_dir);
            Host.bindServiceResults(core_options.service_results);
            boot_images_store = core_options.boot_images;
            env_values_store = core_options.env_values;
            host_calls_store = core_options.host_calls;
            persist_options_store = core_options.persist;
            host_call_mux_store = if (core_options.host_calls != null and core_options.persist != null) .{
                .primary = core_options.host_calls.?,
                .persist = core_options.persist.?.binding,
            } else null;
            if (core_options.env_values.len > 0 and comptime !@hasDecl(core, "envMsgs")) {
                @panic("TsUiApp received env_values but the core exports no envMsgs channel - declare `export const envMsgs = [{ env: \"NAME\", msg: \"<arm>\" }] as const` in core.ts");
            }
            if (core_options.persist != null and comptime !@hasDecl(core, "restoreModel")) {
                @panic("TsUiApp received persistence wiring but the generated core exposes no restoreModel entry - rebuild with core ABI version 2");
            }
        }

        fn stampOptions(options: Options) Options {
            if (options.update != null or options.update_fx != null) {
                @panic("TsUiApp owns update: the TypeScript core is the update loop - remove the wiring's update/update_fx");
            }
            if (options.init_fx != null) {
                @panic("TsUiApp owns init_fx: the core's initialModel boots the app - remove the wiring's init_fx");
            }
            if (options.sync != null) {
                @panic("TsUiApp does not support Options.sync: a committed model cannot be mutated in place - echo widget state through on-change/on-scroll Msgs instead");
            }
            var stamped = options;
            if (options.pty_key_resolver != null) @panic("TsUiApp owns pty_key_resolver - remove custom PTY identity wiring");
            stamped.pty_key_resolver = Host.resolvePtyKey;
            if (comptime @hasDecl(core, "nativeWindowPolicy")) {
                if (options.construction_policy != null) @panic("TsUiApp owns construction_policy - remove custom construction wiring");
                stamped.construction_policy = core.nativeWindowPolicy;
                if (options.composition_policy != null) @panic("TsUiApp owns composition_policy - remove custom composition wiring");
                stamped.composition_policy = core.nativeWindowPolicy;
                if (options.surface_layout_policy != null) @panic("TsUiApp owns surface_layout_policy - remove custom surface layout wiring");
                stamped.surface_layout_policy = core.nativeWindowPolicy;
                if (options.grid_layout_policy != null) @panic("TsUiApp owns grid_layout_policy - remove custom grid layout wiring");
                stamped.grid_layout_policy = core.nativeWindowPolicy;
                if (options.container_layout_policy != null) @panic("TsUiApp owns container_layout_policy - remove custom container layout wiring");
                stamped.container_layout_policy = core.nativeWindowPolicy;
                if (options.intrinsic_layout_policy != null) @panic("TsUiApp owns intrinsic_layout_policy - remove custom intrinsic layout wiring");
                stamped.intrinsic_layout_policy = core.nativeWindowPolicy;
                if (options.widget_motion_policy != null) @panic("TsUiApp owns widget_motion_policy - remove custom motion wiring");
                stamped.widget_motion_policy = core.nativeWindowPolicy;
            }
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                if (options.app_dispatch_policy != null) @panic("TsUiApp owns app_dispatch_policy - remove custom dispatch wiring");
                stamped.app_dispatch_policy = core.nativeEffectPolicy;
                if (options.replay_policy != null) @panic("TsUiApp owns replay_policy - remove custom replay wiring");
                stamped.replay_policy = core.nativeEffectPolicy;
                if (options.component_policy != null) @panic("TsUiApp owns component_policy - remove custom component wiring");
                stamped.component_policy = core.nativeEffectPolicy;
            }
            command_store = stamped.on_command;
            lifecycle_store = stamped.on_lifecycle;
            lifecycle_flush_after_update = false;
            stamped.on_lifecycle = lifecycleAdapter;
            stamped.init_fx = initFx;
            stamped.update_fx = updateFx;
            if (comptime @hasDecl(core, "nativeWindowPolicy")) {
                if (options.shell_layout_policy != null) @panic("TsUiApp owns shell_layout_policy - remove custom shell layout wiring");
                stamped.shell_layout_policy = core.nativeWindowPolicy;
                if (options.text_cache_policy != null) @panic("TsUiApp owns text_cache_policy - remove custom text cache wiring");
                stamped.text_cache_policy = core.nativeWindowPolicy;
                if (options.render_cache_policy != null) @panic("TsUiApp owns render_cache_policy - remove custom render cache wiring");
                stamped.render_cache_policy = core.nativeWindowPolicy;
                if (options.render_plan_policy != null) @panic("TsUiApp owns render_plan_policy - remove custom render plan wiring");
                stamped.render_plan_policy = core.nativeWindowPolicy;
                if (options.render_override_policy != null) @panic("TsUiApp owns render_override_policy - remove custom render override wiring");
                stamped.render_override_policy = core.nativeWindowPolicy;
                if (options.render_damage_policy != null) @panic("TsUiApp owns render_damage_policy - remove custom render damage wiring");
                stamped.render_damage_policy = core.nativeWindowPolicy;
            }
            if (comptime @hasDecl(core, "nativeTabFocusPolicy")) {
                if (options.tab_focus_policy != null) @panic("TsUiApp owns tab_focus_policy - remove custom focus policy wiring");
                stamped.tab_focus_policy = core.nativeTabFocusPolicy;
            }
            if (comptime @hasDecl(core, "nativeSurfaceScopePolicy")) {
                if (options.surface_scope_policy != null) @panic("TsUiApp owns surface_scope_policy - remove custom surface policy wiring");
                stamped.surface_scope_policy = core.nativeSurfaceScopePolicy;
            }
            if (comptime @hasDecl(core, "nativeFocusReturnPolicy")) {
                if (options.focus_return_policy != null) @panic("TsUiApp owns focus_return_policy - remove custom focus return wiring");
                stamped.focus_return_policy = core.nativeFocusReturnPolicy;
            }
            if (comptime @hasDecl(core, "nativeTooltipPolicy")) {
                if (options.tooltip_policy != null) @panic("TsUiApp owns tooltip_policy - remove custom tooltip policy wiring");
                stamped.tooltip_policy = core.nativeTooltipPolicy;
            }
            if (comptime @hasDecl(core, "nativePressHoldPolicy")) {
                if (options.press_hold_policy != null) @panic("TsUiApp owns press_hold_policy - remove custom hold policy wiring");
                stamped.press_hold_policy = core.nativePressHoldPolicy;
            }
            // A TypeScript core can select a built-in pack from ordinary
            // model state without ejecting the generated launcher. The
            // exported single-model helper emits as a Model method, so it
            // is equally visible on direct compiler output and the
            // external-core mirror. The app owns only the pack; UiApp's
            // stock-token path keeps following the OS appearance.
            if (comptime @hasDecl(core, "nativeThemePolicy")) {
                if (options.theme_policy != null) @panic("TsUiApp owns theme_policy - remove custom theme policy wiring");
                stamped.theme_policy = core.nativeThemePolicy;
            }
            if (comptime @hasDecl(Model, "themePack")) {
                if (comptime @hasDecl(Model, "themeState")) {
                    @compileError("TsUiApp: export either themePack or themeState, not both");
                }
                if (options.theme_fn != null) {
                    @panic("TsUiApp wires theme_fn from the core's themePack helper - remove the wiring's theme_fn");
                }
                comptime validateThemePackHelper();
                stamped.theme_fn = themePackAdapter;
            }
            if (comptime @hasDecl(Model, "themeState")) {
                if (options.theme_state_fn != null or options.theme_fn != null) {
                    @panic("TsUiApp wires theme_state_fn from the core's themeState helper - remove the wiring's theme_state_fn/theme_fn");
                }
                comptime validateThemeStateHelper();
                stamped.theme_state_fn = themeStateAdapter;
            }
            if (comptime @hasDecl(Model, "tokenOverrides")) {
                if (options.token_overrides_fn != null) @panic("TsUiApp owns token_overrides_fn from tokenOverrides");
                stamped.token_overrides_fn = tokenOverridesAdapter;
            }
            if (comptime @hasDecl(core, "nativeStatusPolicy")) {
                if (options.status_policy != null) @panic("TsUiApp owns status_policy - remove custom status policy wiring");
                stamped.status_policy = core.nativeStatusPolicy;
            }
            // A statusItem helper is the TS app's model-derived shell
            // declaration. UiApp installs it on the first frame and
            // independently patches shell/presentation/menu after each
            // committed rebuild; empty fields inherit custom static
            // status_item options in hand wiring.
            if (comptime @hasDecl(Model, "statusItem")) {
                if (options.status_item_fn != null) {
                    @panic("TsUiApp wires status_item_fn from the core's statusItem helper - remove the wiring's status_item_fn");
                }
                comptime validateStatusItemHelper();
                stamped.status_item_fn = statusItemAdapter;
            }
            if (comptime @hasDecl(Model, "statusItems")) {
                if (comptime @hasDecl(Model, "statusItem")) {
                    @compileError("TsUiApp: export either statusItem or statusItems, not both");
                }
                if (options.status_items_fn != null or options.status_item != null or options.status_item_fn != null) {
                    @panic("TsUiApp wires status_items_fn from the core's statusItems helper - remove singular/custom status-item wiring");
                }
                comptime validateStatusItemsHelper();
                stamped.status_items_fn = statusItemsAdapter;
            }
            if (comptime @hasDecl(Model, "windows")) {
                if (options.windows_fn != null) {
                    @panic("TsUiApp wires windows_fn from the core's windows helper - remove the wiring's windows_fn");
                }
                if (options.window_view == null) {
                    @panic("TsUiApp windows(model) requires a window_view registry - default apps provide src/windows/<label>.native; hand wiring must set Options.window_view");
                }
                comptime validateWindowsHelper();
                stamped.windows_fn = windowsAdapter;
                if (comptime @hasDecl(core, "nativeWindowPolicy")) {
                    if (options.window_policy != null) @panic("TsUiApp wires window_policy from the compiled core");
                    stamped.window_policy = core.nativeWindowPolicy;
                }
            }
            if (comptime @hasDecl(Model, "webPanes")) {
                if (options.web_panes != null) @panic("TsUiApp owns web_panes from webPanes - remove custom pane wiring");
                comptime validateWebPanesHelper();
                stamped.web_panes = webPanesAdapter;
            }
            // The core's host-event channels, comptime-detected from its
            // exports (export exists -> wired; every shape mismatch is a
            // teaching compile error in the adapter below). A wiring that
            // also set the seam would silently shadow the core's channel,
            // so that conflict is a loud teaching panic.
            if (comptime @hasDecl(core, "frameMsg")) {
                if (options.on_frame != null) {
                    @panic("TsUiApp wires on_frame from the core's frameMsg export - remove the wiring's on_frame");
                }
                stamped.on_frame = frameMsgAdapter;
            }
            if (comptime @hasDecl(core, "keyMsg")) {
                if (options.on_key != null) {
                    @panic("TsUiApp wires on_key from the core's keyMsg export - remove the wiring's on_key");
                }
                stamped.on_key = keyMsgAdapter;
            }
            if (comptime @hasDecl(core, "pinchMsg")) {
                if (options.on_pinch != null) {
                    @panic("TsUiApp wires on_pinch from the core's pinchMsg export - remove the wiring's on_pinch");
                }
                stamped.on_pinch = pinchMsgAdapter;
            }
            if (comptime @hasDecl(core, "dropMsg")) {
                if (options.on_drop != null) {
                    @panic("TsUiApp wires on_drop from the core's dropMsg export - remove the wiring's on_drop");
                }
                stamped.on_drop = dropMsgAdapter;
            }
            if (comptime @hasDecl(core, "appearanceMsg")) {
                if (options.on_appearance != null) {
                    @panic("TsUiApp wires on_appearance from the core's appearanceMsg export - remove the wiring's on_appearance");
                }
                stamped.on_appearance = appearanceMsgAdapter;
            }
            if (comptime @hasDecl(core, "chromeMsg")) {
                if (options.on_chrome != null) {
                    @panic("TsUiApp wires on_chrome from the core's chromeMsg export - remove the wiring's on_chrome");
                }
                stamped.on_chrome = chromeMsgAdapter;
            }
            return stamped;
        }

        fn lifecycleAdapter(event: runtime_core.LifecycleEvent) ?Msg {
            const mapped = if (lifecycle_store) |map| map(event) else null;
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                const plan = compiledFlush(@intCast(@intFromEnum(event)), mapped != null);
                lifecycle_flush_after_update = plan[0] == 1;
                if (plan[1] == 1) flushPersistence();
                return mapped;
            }
            if (event != .deactivate and event != .stop) return mapped;
            if (mapped != null) {
                // UiApp dispatches the mapped Msg after this callback returns.
                // Delay the flush until updateFx has committed that cycle, so
                // a Cmd.persist issued by the lifecycle update is included.
                lifecycle_flush_after_update = true;
            } else {
                flushPersistence();
            }
            return mapped;
        }

        fn flushPersistence() void {
            if (persist_options_store) |persist| {
                persist.binding.send_fn(persist.binding.context, "core.persist.flush", "");
            }
        }

        fn compiledLifecycle(request: []const u8) [32]u8 {
            var plan: [32]u8 = undefined;
            if (core.nativeEffectPolicy(request, &plan) != plan.len)
                @panic("invalid compiled app lifecycle plan size");
            return plan;
        }

        fn compiledFlush(event: u8, mapped: bool) [32]u8 {
            const plan = compiledLifecycle(&.{ 18, 0, event, @intFromBool(mapped), @intFromBool(lifecycle_flush_after_update), 0 });
            if (plan[0] > 1 or plan[1] > 1) @panic("invalid compiled lifecycle flush plan");
            for (plan[2..]) |byte| if (byte != 0) @panic("invalid compiled lifecycle flush reserved byte");
            return plan;
        }

        fn themePackAdapter(model: *const Model) canvas.ThemePack {
            const pack = model.themePack();
            return canvas.ThemePack.fromName(@tagName(pack)).?;
        }

        fn validateThemePackHelper() void {
            const teaching = "TsUiApp: themePack must be exported from core.ts as themePack(model: Model): ThemePack, where ThemePack is exactly \"house\" | \"geist\"";
            const helper_info = @typeInfo(@TypeOf(Model.themePack));
            if (helper_info != .@"fn") @compileError(teaching);
            const function = helper_info.@"fn";
            if (function.params.len != 1 or function.params[0].type == null or function.params[0].type.? != *const Model) {
                @compileError(teaching);
            }
            const Pack = function.return_type orelse @compileError(teaching);
            const pack_info = @typeInfo(Pack);
            if (pack_info != .@"enum" or pack_info.@"enum".fields.len != 2 or
                !@hasField(Pack, "house") or !@hasField(Pack, "geist"))
            {
                @compileError(teaching);
            }
        }

        fn tokenOverridesAdapter(model: *const Model) canvas.DesignTokenOverrides {
            const params = @typeInfo(@TypeOf(Model.tokenOverrides)).@"fn".params;
            const raw = if (comptime params.len == 1) model.tokenOverrides() else model.tokenOverrides(core.rt.frameAllocator());
            return tokenOverrideValue(canvas.DesignTokenOverrides, raw);
        }

        /// Copy the complete typed declaration by value before the next core
        /// call. No text, pointers or behavior can survive as token data.
        fn tokenOverrideValue(comptime Target: type, raw: anytype) Target {
            const Raw = @TypeOf(raw);
            if (comptime @typeInfo(Raw) == .pointer) return tokenOverrideValue(Target, raw.*);
            switch (@typeInfo(Target)) {
                .optional => |info| {
                    if (comptime @typeInfo(Raw) != .optional) @compileError("token override members must be optional");
                    return if (raw) |value| tokenOverrideValue(info.child, value) else null;
                },
                .@"struct" => |info| {
                    if (comptime @typeInfo(Raw) == .optional) return if (raw) |value| tokenOverrideValue(Target, value) else .{};
                    if (comptime @typeInfo(Raw) != .@"struct" or @typeInfo(Raw).@"struct".fields.len != info.fields.len) @compileError("token override record must match the complete canonical register");
                    var result: Target = undefined;
                    inline for (info.fields) |field| {
                        if (comptime !@hasField(Raw, field.name)) @compileError("token override record is missing " ++ field.name);
                        @field(result, field.name) = tokenOverrideValue(field.type, @field(raw, field.name));
                    }
                    if (comptime Target == canvas.Color) {
                        inline for (.{ "r", "g", "b", "a" }) |field| {
                            const value = @field(result, field);
                            if (value < 0 or value > 1) @panic("token color channels require normalized RGBA");
                        }
                    }
                    return result;
                },
                .float => {
                    const value: Target = if (comptime @typeInfo(Raw) == .float) @floatCast(raw) else @floatFromInt(raw);
                    if (!std.math.isFinite(value)) @panic("token override must be finite");
                    return value;
                },
                .int => {
                    const value: f64 = if (comptime @typeInfo(Raw) == .float) @floatCast(raw) else @floatFromInt(raw);
                    if (!std.math.isFinite(value) or value != @trunc(value) or value < -9_007_199_254_740_991 or value > 9_007_199_254_740_991 or value < @as(f64, @floatFromInt(std.math.minInt(Target))) or value > @as(f64, @floatFromInt(std.math.maxInt(Target)))) @panic("token override integer is out of range");
                    return @intFromFloat(value);
                },
                .@"enum" => return std.meta.stringToEnum(Target, @tagName(raw)) orelse @panic("invalid token override enum"),
                .bool => return raw,
                else => @compileError("unsupported token override ABI field"),
            }
        }

        fn themeStateAdapter(model: *const Model) App.ThemeState {
            const params = @typeInfo(@TypeOf(Model.themeState)).@"fn".params;
            const raw_state = if (comptime params.len == 1)
                model.themeState()
            else
                model.themeState(core.rt.frameAllocator());
            const state = if (comptime @typeInfo(@TypeOf(raw_state)) == .pointer) raw_state.* else raw_state;
            const accent = if (state.accent) |value| parseThemeAccent(value) else null;
            return .{
                .pack = if (state.pack) |pack| canvas.ThemePack.fromName(@tagName(pack)).? else null,
                .color_scheme = if (state.colorScheme) |scheme| themeColorScheme(scheme) else .system,
                .accent = accent,
                .invalid_accent = if (state.accent != null and accent == null) state.accent else null,
            };
        }

        fn themeColorScheme(value: anytype) App.ThemeColorScheme {
            const name = @tagName(value);
            inline for (std.meta.fields(App.ThemeColorScheme)) |field| {
                if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
            }
            unreachable;
        }

        fn parseThemeAccent(value: []const u8) ?canvas.Color {
            if (comptime @hasDecl(core, "nativeThemePolicy")) {
                const request = core.rt.frameAllocator().alloc(u8, value.len + 1) catch @panic("out of memory preparing theme accent");
                request[0] = 0;
                @memcpy(request[1..], value);
                var result: [4]u8 = undefined;
                if (core.nativeThemePolicy(request, &result) != result.len or result[0] > 1) @panic("invalid compiled theme accent result");
                return if (result[0] == 1) canvas.Color.rgb8(result[1], result[2], result[3]) else null;
            }
            if (value.len != 7 or value[0] != '#') return null;
            const r = themeHexByte(value[1], value[2]) orelse return null;
            const g = themeHexByte(value[3], value[4]) orelse return null;
            const b = themeHexByte(value[5], value[6]) orelse return null;
            return canvas.Color.rgb8(r, g, b);
        }

        fn themeHexByte(hi: u8, lo: u8) ?u8 {
            const h = themeHexNibble(hi) orelse return null;
            const l = themeHexNibble(lo) orelse return null;
            return h * 16 + l;
        }

        fn themeHexNibble(byte: u8) ?u8 {
            return switch (byte) {
                '0'...'9' => byte - '0',
                'a'...'f' => byte - 'a' + 10,
                'A'...'F' => byte - 'A' + 10,
                else => null,
            };
        }

        fn validateThemeStateHelper() void {
            const teaching = "TsUiApp: themeState must be exported from core.ts as themeState(model: Model): ThemeState; import ThemeState from @native-sdk/core/events";
            const helper_info = @typeInfo(@TypeOf(Model.themeState));
            if (helper_info != .@"fn") @compileError(teaching);
            const function = helper_info.@"fn";
            if ((function.params.len != 1 and function.params.len != 2) or function.params[0].type == null or function.params[0].type.? != *const Model) {
                @compileError(teaching);
            }
            if (function.params.len == 2) {
                if (function.params[1].type == null or function.params[1].type.? != std.mem.Allocator or
                    !@hasDecl(core, "rt") or !@hasDecl(core.rt, "frameAllocator"))
                {
                    @compileError(teaching);
                }
            }
            const RawState = function.return_type orelse @compileError(teaching);
            const State = statusItemRecordType(RawState, teaching);
            const info = @typeInfo(State).@"struct";
            if (info.fields.len != 3 or !@hasField(State, "pack") or !@hasField(State, "colorScheme") or !@hasField(State, "accent")) {
                @compileError(teaching);
            }
            if (!optionalEnumType(@FieldType(State, "pack"), &.{ "house", "geist" }) or
                !optionalEnumType(@FieldType(State, "colorScheme"), &.{ "light", "dark", "system" }) or
                @FieldType(State, "accent") != ?[]const u8)
            {
                @compileError(teaching);
            }
        }

        /// Convert the compiled core's canonical status-item records into
        /// the platform rows UiApp already knows how to validate, copy,
        /// hash, install, and patch. Interface records cross the core ABI
        /// by pointer; value records are accepted too so hand-assembled
        /// compiler fixtures exercise the same seam.
        fn statusItemAdapter(model: *const Model, scratch: *App.StatusItemScratch) App.StatusItemState {
            const params = @typeInfo(@TypeOf(Model.statusItem)).@"fn".params;
            const raw_state = if (comptime params.len == 1)
                model.statusItem()
            else
                model.statusItem(core.rt.frameAllocator());
            const state = if (comptime @typeInfo(@TypeOf(raw_state)) == .pointer) raw_state.* else raw_state;
            if (state.items.len > scratch.items.len) {
                // The callback cannot return an error. Feed UiApp one
                // deliberately invalid actionable row so the ordinary
                // tray validator rejects the over-capacity declaration
                // loudly instead of silently truncating it.
                scratch.items[0] = .{ .id = 0, .label = "status item has more than 32 rows", .command = "status-item-overflow" };
                return statusItemState(state, scratch.items[0..1]);
            }
            for (state.items, 0..) |raw_item, index| {
                const item = if (comptime @typeInfo(@TypeOf(raw_item)) == .pointer) raw_item.* else raw_item;
                const segment_start = index * platform.max_tray_segment_options;
                const chart_start = index * platform.max_tray_chart_values;
                scratch.items[index] = statusItemMenuItem(
                    item,
                    scratch.segment_options[segment_start .. segment_start + platform.max_tray_segment_options],
                    scratch.chart_values[chart_start .. chart_start + platform.max_tray_chart_values],
                );
            }
            return statusItemState(state, scratch.items[0..state.items.len]);
        }

        fn statusItemsAdapter(model: *const Model, scratch: *App.StatusItemsScratch) []const App.StatusItemDescriptor {
            const params = @typeInfo(@TypeOf(Model.statusItems)).@"fn".params;
            const raw_states = if (comptime params.len == 1)
                model.statusItems()
            else
                model.statusItems(core.rt.frameAllocator());
            if (raw_states.len > scratch.status_items.len) {
                scratch.status_items[0] = .{ .id = 0 };
                return scratch.status_items[0..1];
            }
            for (raw_states, 0..) |raw_state, status_index| {
                const state = if (comptime @typeInfo(@TypeOf(raw_state)) == .pointer) raw_state.* else raw_state;
                const row_start = status_index * platform.max_tray_items;
                const row_storage = scratch.items[row_start .. row_start + platform.max_tray_items];
                if (state.items.len > row_storage.len) {
                    row_storage[0] = .{ .id = 0, .label = "status item has more than 32 rows", .command = "status-item-overflow" };
                    scratch.status_items[status_index] = .{
                        .id = statusItemId(state.id),
                        .visible = state.visible,
                        .state = statusItemState(state, row_storage[0..1]),
                    };
                    continue;
                }
                for (state.items, 0..) |raw_item, item_index| {
                    const item = if (comptime @typeInfo(@TypeOf(raw_item)) == .pointer) raw_item.* else raw_item;
                    const flat_row_index = row_start + item_index;
                    const segment_start = flat_row_index * platform.max_tray_segment_options;
                    const chart_start = flat_row_index * platform.max_tray_chart_values;
                    row_storage[item_index] = statusItemMenuItem(
                        item,
                        scratch.segment_options[segment_start .. segment_start + platform.max_tray_segment_options],
                        scratch.chart_values[chart_start .. chart_start + platform.max_tray_chart_values],
                    );
                }
                scratch.status_items[status_index] = .{
                    .id = statusItemId(state.id),
                    .visible = state.visible,
                    .state = statusItemState(state, row_storage[0..state.items.len]),
                };
            }
            return scratch.status_items[0..raw_states.len];
        }

        const PaneStrings = struct {
            label: [64]u8 = undefined,
            anchor: [256]u8 = undefined,
            url: [platform.max_webview_url_bytes]u8 = undefined,
        };
        // The helper's frame may expire as soon as the next compiled call
        // runs. OS reconciliation receives only bounded native-owned bytes.
        var pane_strings: [@import("ui_app.zig").max_web_panes]PaneStrings = undefined;

        fn paneBytes(out: []u8, source: []const u8) []const u8 {
            if (source.len > out.len) @panic("TsUiApp: webPanes text exceeds the native pane budget");
            @memcpy(out[0..source.len], source);
            return out[0..source.len];
        }

        fn paneNumber(value: anytype) f64 {
            return switch (@typeInfo(@TypeOf(value))) {
                .int => @floatFromInt(value),
                .float => @floatCast(value),
                else => unreachable,
            };
        }

        fn paneCoordinate(value: anytype) error{InvalidWebPane}!f32 {
            const number = paneNumber(value);
            if (!std.math.isFinite(number) or @abs(number) > std.math.floatMax(f32)) return error.InvalidWebPane;
            return @floatCast(number);
        }

        fn paneDimension(value: anytype) error{InvalidWebPane}!f32 {
            const number = try paneCoordinate(value);
            if (number < 0) return error.InvalidWebPane;
            return number;
        }

        fn paneReloadToken(value: anytype) error{InvalidWebPane}!u64 {
            if (comptime @TypeOf(value) == []const u8) {
                if (value.len == 0 or value.len > 20) return error.InvalidWebPane;
                for (value) |byte| if (byte < '0' or byte > '9') return error.InvalidWebPane;
                return std.fmt.parseInt(u64, value, 10) catch error.InvalidWebPane;
            }
            const number = paneNumber(value);
            if (!std.math.isFinite(number) or number < 0 or number > 9007199254740991 or @floor(number) != number) return error.InvalidWebPane;
            return @intFromFloat(number);
        }

        fn webPanesAdapter(model: *const Model, out: []App.WebViewPane) usize {
            const params = @typeInfo(@TypeOf(Model.webPanes)).@"fn".params;
            const raw = if (comptime params.len == 1) model.webPanes() else model.webPanes(core.rt.frameAllocator());
            const count = @min(raw.len, @min(out.len, pane_strings.len));
            if (raw.len > pane_strings.len) ts_ui_app_log.warn("webPanes declared {d} panes; the budget is {d}; excess panes are ignored", .{ raw.len, count });
            for (raw[0..count], 0..) |raw_pane, index| {
                const pane = if (comptime @typeInfo(@TypeOf(raw_pane)) == .pointer) raw_pane.* else raw_pane;
                const token = paneReloadToken(pane.reloadToken) catch @panic("TsUiApp: webPanes reloadToken must be a nonnegative safe integer or decimal u64 bytes");
                const width = paneDimension(pane.width) catch @panic("TsUiApp: webPanes dimensions must be nonnegative finite f32 points");
                const height = paneDimension(pane.height) catch @panic("TsUiApp: webPanes dimensions must be nonnegative finite f32 points");
                out[index] = .{
                    .label = paneBytes(&pane_strings[index].label, pane.label),
                    .anchor = if (pane.anchor) |anchor| paneBytes(&pane_strings[index].anchor, anchor) else null,
                    .url = paneBytes(&pane_strings[index].url, pane.url),
                    .frame = @import("geometry").RectF.init(paneCoordinate(pane.x) catch @panic("TsUiApp: invalid pane x"), paneCoordinate(pane.y) catch @panic("TsUiApp: invalid pane y"), width, height),
                    .reload_token = token,
                };
            }
            return count;
        }

        fn validateWebPanesHelper() void {
            const teaching = "TsUiApp: export webPanes(model: Model): readonly WebViewPane[] or readonly ExactWebViewPane[]; import the descriptor from @native-sdk/core/events";
            const info = @typeInfo(@TypeOf(Model.webPanes));
            if (info != .@"fn") @compileError(teaching);
            const function = info.@"fn";
            if ((function.params.len != 1 and function.params.len != 2) or function.params[0].type != *const Model) @compileError(teaching);
            if (function.params.len == 2 and function.params[1].type != std.mem.Allocator) @compileError(teaching);
            const returned = @typeInfo(function.return_type orelse @compileError(teaching));
            if (returned != .pointer or returned.pointer.size != .slice or !returned.pointer.is_const) @compileError(teaching);
            const Pane = statusItemRecordType(returned.pointer.child, teaching);
            if (@typeInfo(Pane).@"struct".fields.len != 8) @compileError(teaching);
            inline for (.{ "label", "url" }) |name| {
                if (!@hasField(Pane, name) or @FieldType(Pane, name) != []const u8) @compileError(teaching);
            }
            if (!@hasField(Pane, "reloadToken") or (!statusItemNumericType(@FieldType(Pane, "reloadToken")) and @FieldType(Pane, "reloadToken") != []const u8)) @compileError(teaching);
            if (!@hasField(Pane, "anchor") or @FieldType(Pane, "anchor") != ?[]const u8) @compileError(teaching);
            inline for (.{ "x", "y", "width", "height" }) |name| {
                if (!@hasField(Pane, name) or !statusItemNumericType(@FieldType(Pane, name))) @compileError(teaching);
            }
        }

        fn windowsAdapter(model: *const Model, scratch: *App.WindowsScratch) []const App.WindowDescriptor {
            const params = @typeInfo(@TypeOf(Model.windows)).@"fn".params;
            const raw_windows = if (comptime params.len == 1)
                model.windows()
            else
                model.windows(core.rt.frameAllocator());
            if (raw_windows.len > scratch.windows.len) {
                ts_ui_app_log.warn(
                    "windows(model) declared {d} windows; the budget is {d} (canvas_limits.max_ui_app_windows) - the excess is ignored",
                    .{ raw_windows.len, scratch.windows.len },
                );
            }
            const kept = raw_windows[0..@min(raw_windows.len, scratch.windows.len)];
            for (kept, 0..) |raw_window, index| {
                const window = if (comptime @typeInfo(@TypeOf(raw_window)) == .pointer) raw_window.* else raw_window;
                const close_policy = windowClosePolicy(window.closePolicy);
                scratch.windows[index] = .{
                    .label = window.label,
                    .canvas_label = window.canvasLabel,
                    .title = window.title,
                    .width = statusItemFloat(window.width),
                    .height = statusItemFloat(window.height),
                    .x = optionalWindowFloat(window.x),
                    .y = optionalWindowFloat(window.y),
                    .resizable = window.resizable,
                    .restore_policy = windowRestorePolicy(window.restorePolicy),
                    .min_width = statusItemFloat(window.minWidth),
                    .min_height = statusItemFloat(window.minHeight),
                    .titlebar = windowTitlebar(window.titlebar),
                    .transparent = window.transparent,
                    .always_on_top = window.alwaysOnTop,
                    .click_through = window.clickThrough,
                    .activate_on_show = window.activateOnShow,
                    .allows_fullscreen = window.allowsFullscreen,
                    .close_policy = close_policy,
                    // A hide never closes and therefore never routes its
                    // command. A real close must map a non-empty command
                    // now, before the window is created, so the adapter
                    // cannot install a dead callback that lets the model
                    // resurrect the just-closed window later.
                    .on_close = if (close_policy == .quit) requireWindowCloseMsg(window.onCloseCommand) else null,
                };
            }
            return scratch.windows[0..kept.len];
        }

        fn optionalWindowFloat(value: anytype) ?f32 {
            return if (value) |present| statusItemFloat(present) else null;
        }

        fn windowTitlebar(value: anytype) @import("app_manifest").WindowTitlebarStyle {
            const Target = @import("app_manifest").WindowTitlebarStyle;
            inline for (std.meta.fields(Target)) |field| {
                if (std.mem.eql(u8, @tagName(value), field.name)) return @enumFromInt(field.value);
            }
            unreachable;
        }

        fn windowRestorePolicy(value: anytype) @import("app_manifest").WindowRestorePolicy {
            const Target = @import("app_manifest").WindowRestorePolicy;
            inline for (std.meta.fields(Target)) |field| {
                if (std.mem.eql(u8, @tagName(value), field.name)) return @enumFromInt(field.value);
            }
            unreachable;
        }

        fn windowClosePolicy(value: anytype) @import("app_manifest").WindowClosePolicy {
            const Target = @import("app_manifest").WindowClosePolicy;
            inline for (std.meta.fields(Target)) |field| {
                if (std.mem.eql(u8, @tagName(value), field.name)) return @enumFromInt(field.value);
            }
            unreachable;
        }

        const WindowCloseCommandError = error{
            MissingCommandMapper,
            UnmappedCommand,
        };

        fn windowCloseMsg(command: []const u8) WindowCloseCommandError!?Msg {
            if (command.len == 0) return null;
            const map = command_store orelse return error.MissingCommandMapper;
            return map(command) orelse error.UnmappedCommand;
        }

        fn requireWindowCloseMsg(command: []const u8) ?Msg {
            return windowCloseMsg(command) catch |err| {
                ts_ui_app_log.err(
                    "window onCloseCommand '{s}' cannot be installed: {s}; map every quit-close command through Options.on_command (the default launcher wires exported commandMsg)",
                    .{ command, @errorName(err) },
                );
                @panic("TsUiApp: a non-empty quit-close onCloseCommand must map through Options.on_command");
            };
        }

        fn statusItemMenuItem(item: anytype, segment_storage: []platform.TraySegmentOption, chart_storage: []f32) platform.TrayMenuItem {
            var result = platform.TrayMenuItem{
                .id = statusItemId(item.id),
                .label = item.label,
                .command = item.command,
                .separator = item.separator,
                .enabled = item.enabled,
                .detail = item.detail,
                .role = statusItemRole(item.role),
                .key = item.key,
                .modifiers = .{
                    .primary = item.modifiers.primary,
                    .command = item.modifiers.command,
                    .control = item.modifiers.control,
                    .option = item.modifiers.option,
                    .shift = item.modifiers.shift,
                },
            };
            if (@hasField(@TypeOf(item), "segmented")) if (item.segmented) |raw_segmented| {
                const segmented = if (comptime @typeInfo(@TypeOf(raw_segmented)) == .pointer) raw_segmented.* else raw_segmented;
                if (segmented.options.len <= segment_storage.len) {
                    for (segmented.options, 0..) |raw_option, index| {
                        const option = if (comptime @typeInfo(@TypeOf(raw_option)) == .pointer) raw_option.* else raw_option;
                        segment_storage[index] = .{
                            .id = statusItemId(option.id),
                            .label = option.label,
                            .command = option.command,
                            .selected = option.selected,
                            .enabled = option.enabled,
                        };
                    }
                    result.segmented = .{ .options = segment_storage[0..segmented.options.len] };
                } else {
                    result.segmented = .{};
                }
            };
            if (@hasField(@TypeOf(item), "metric")) if (item.metric) |raw_metric| {
                const metric = if (comptime @typeInfo(@TypeOf(raw_metric)) == .pointer) raw_metric.* else raw_metric;
                result.metric = .{
                    .primary_text = metric.primaryText,
                    .secondary_text = metric.secondaryText,
                    .accessibility_label = metric.accessibilityLabel,
                };
            };
            if (@hasField(@TypeOf(item), "chart")) if (item.chart) |raw_chart| {
                const chart = if (comptime @typeInfo(@TypeOf(raw_chart)) == .pointer) raw_chart.* else raw_chart;
                if (chart.values.len <= chart_storage.len) {
                    for (chart.values, 0..) |value, index| chart_storage[index] = statusItemFloat(value);
                    result.chart = .{
                        .values = chart_storage[0..chart.values.len],
                        .min_value = statusItemFloat(chart.minValue),
                        .max_value = statusItemFloat(chart.maxValue),
                        .leading_caption = chart.leadingCaption,
                        .trailing_summary = chart.trailingSummary,
                        .accessibility_label = chart.accessibilityLabel,
                    };
                } else {
                    result.chart = .{};
                }
            };
            return result;
        }

        fn statusItemState(state: anytype, items: []const platform.TrayMenuItem) App.StatusItemState {
            const presentation = if (comptime @typeInfo(@TypeOf(state.presentation)) == .pointer) state.presentation.* else state.presentation;
            return .{
                .presentation = .{
                    .title = presentation.title,
                    .width = statusItemFloat(presentation.width),
                    .tone = statusItemTone(presentation.tone),
                    .icon_opacity = statusItemFloat(presentation.iconOpacity),
                    .monospaced = presentation.monospaced,
                    .font_size = if (presentation.fontSize) |value| statusItemFloat(value) else 0,
                    .font_weight = if (presentation.fontWeight) |value| statusItemFontWeight(value) else .regular,
                },
                .icon_path = state.iconPath,
                .tooltip = state.tooltip,
                .activation_command = state.activationCommand,
                .alternate_activation_command = state.alternateActivationCommand,
                .open_command = state.openCommand,
                .items = items,
            };
        }

        /// JavaScript `number` slots may infer as integer or float in the
        /// compiled core. Tray ids are u32; a negative, fractional,
        /// non-finite, or overflowing value maps to zero so the runtime's
        /// existing actionable-row validation produces the rejection.
        fn statusItemId(value: anytype) u32 {
            const number: f64 = switch (@typeInfo(@TypeOf(value))) {
                .int => @floatFromInt(value),
                .float => @floatCast(value),
                else => unreachable,
            };
            if (!std.math.isFinite(number) or number < 0 or number > @as(f64, @floatFromInt(std.math.maxInt(u32))) or @floor(number) != number) return 0;
            return @intFromFloat(number);
        }

        fn statusItemFloat(value: anytype) f32 {
            return switch (@typeInfo(@TypeOf(value))) {
                .int => @floatFromInt(value),
                .float => @floatCast(value),
                else => unreachable,
            };
        }

        fn statusItemTone(value: anytype) platform.TrayTone {
            const name = @tagName(value);
            inline for (std.meta.fields(platform.TrayTone)) |field| {
                if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
            }
            unreachable;
        }

        fn statusItemFontWeight(value: anytype) platform.TrayFontWeight {
            const name = @tagName(value);
            inline for (std.meta.fields(platform.TrayFontWeight)) |field| {
                if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
            }
            unreachable;
        }

        fn statusItemRole(value: anytype) platform.TrayItemRole {
            const name = @tagName(value);
            inline for (std.meta.fields(platform.TrayItemRole)) |field| {
                if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
            }
            unreachable;
        }

        /// Teaching re-derivation of frontend NS1033 for hand-assembled
        /// cores. The nested records stay flat and exact so their ABI
        /// projection is deterministic and arrays need no tagged union.
        fn validateStatusItemHelper() void {
            const teaching = "TsUiApp: statusItem must be exported from core.ts as statusItem(model: Model): StatusItemState; import StatusItemState from @native-sdk/core/events";
            const helper_info = @typeInfo(@TypeOf(Model.statusItem));
            if (helper_info != .@"fn") @compileError(teaching);
            const function = helper_info.@"fn";
            if ((function.params.len != 1 and function.params.len != 2) or function.params[0].type == null or function.params[0].type.? != *const Model) {
                @compileError(teaching);
            }
            if (function.params.len == 2) {
                if (function.params[1].type == null or function.params[1].type.? != std.mem.Allocator or
                    !@hasDecl(core, "rt") or !@hasDecl(core.rt, "frameAllocator"))
                {
                    @compileError(teaching);
                }
            }
            const RawState = function.return_type orelse @compileError(teaching);
            const State = statusItemRecordType(RawState, teaching);
            const state_info = @typeInfo(State).@"struct";
            if (state_info.fields.len != 7 or !@hasField(State, "iconPath") or !@hasField(State, "tooltip") or
                !@hasField(State, "activationCommand") or !@hasField(State, "alternateActivationCommand") or
                !@hasField(State, "openCommand") or !@hasField(State, "presentation") or !@hasField(State, "items"))
            {
                @compileError(teaching);
            }
            if (@FieldType(State, "iconPath") != []const u8 or @FieldType(State, "tooltip") != []const u8 or
                @FieldType(State, "activationCommand") != []const u8 or @FieldType(State, "alternateActivationCommand") != []const u8 or
                @FieldType(State, "openCommand") != []const u8)
            {
                @compileError(teaching);
            }
            const Presentation = statusItemRecordType(@FieldType(State, "presentation"), teaching);
            const presentation_info = @typeInfo(Presentation).@"struct";
            if (presentation_info.fields.len != 7 or !@hasField(Presentation, "title") or !@hasField(Presentation, "width") or
                !@hasField(Presentation, "tone") or !@hasField(Presentation, "iconOpacity") or !@hasField(Presentation, "monospaced") or
                !@hasField(Presentation, "fontSize") or !@hasField(Presentation, "fontWeight"))
            {
                @compileError(teaching);
            }
            if (@FieldType(Presentation, "title") != []const u8 or !statusItemNumericType(@FieldType(Presentation, "width")) or
                !statusItemEnumType(@FieldType(Presentation, "tone"), &.{ "normal", "warning", "critical" }) or
                !statusItemNumericType(@FieldType(Presentation, "iconOpacity")) or @FieldType(Presentation, "monospaced") != bool or
                !optionalNumericType(@FieldType(Presentation, "fontSize")) or
                !optionalEnumType(@FieldType(Presentation, "fontWeight"), &.{ "regular", "medium", "semibold", "bold" }))
            {
                @compileError(teaching);
            }
            const items_info = @typeInfo(@FieldType(State, "items"));
            if (items_info != .pointer or items_info.pointer.size != .slice or !items_info.pointer.is_const) @compileError(teaching);
            const Item = statusItemRecordType(items_info.pointer.child, teaching);
            const item_info = @typeInfo(Item).@"struct";
            if (item_info.fields.len != 12 or !@hasField(Item, "id") or !@hasField(Item, "label") or
                !@hasField(Item, "command") or !@hasField(Item, "separator") or !@hasField(Item, "enabled") or
                !@hasField(Item, "detail") or !@hasField(Item, "role") or !@hasField(Item, "key") or !@hasField(Item, "modifiers") or
                !@hasField(Item, "segmented") or !@hasField(Item, "metric") or !@hasField(Item, "chart"))
            {
                @compileError(teaching);
            }
            if (!statusItemNumericType(@FieldType(Item, "id"))) @compileError(teaching);
            if (@FieldType(Item, "label") != []const u8 or @FieldType(Item, "command") != []const u8 or
                @FieldType(Item, "separator") != bool or @FieldType(Item, "enabled") != bool or
                @FieldType(Item, "detail") != []const u8 or
                !statusItemEnumType(@FieldType(Item, "role"), &.{ "command", "info", "header", "hero", "agent", "context", "segmented", "chart" }) or
                @FieldType(Item, "key") != []const u8)
            {
                @compileError(teaching);
            }
            const Modifiers = statusItemRecordType(@FieldType(Item, "modifiers"), teaching);
            const modifiers_info = @typeInfo(Modifiers).@"struct";
            if (modifiers_info.fields.len != 5 or !@hasField(Modifiers, "primary") or !@hasField(Modifiers, "command") or
                !@hasField(Modifiers, "control") or !@hasField(Modifiers, "option") or !@hasField(Modifiers, "shift") or
                @FieldType(Modifiers, "primary") != bool or @FieldType(Modifiers, "command") != bool or
                @FieldType(Modifiers, "control") != bool or @FieldType(Modifiers, "option") != bool or @FieldType(Modifiers, "shift") != bool)
            {
                @compileError(teaching);
            }
            validateStatusItemRichTypes(Item, teaching);
        }

        fn validateStatusItemsHelper() void {
            const teaching = "TsUiApp: statusItems must be exported from core.ts as statusItems(model: Model): readonly StatusItemDescriptor[]; import StatusItemDescriptor from @native-sdk/core/events";
            const helper_info = @typeInfo(@TypeOf(Model.statusItems));
            if (helper_info != .@"fn") @compileError(teaching);
            const function = helper_info.@"fn";
            if ((function.params.len != 1 and function.params.len != 2) or function.params[0].type == null or function.params[0].type.? != *const Model) {
                @compileError(teaching);
            }
            if (function.params.len == 2) {
                if (function.params[1].type == null or function.params[1].type.? != std.mem.Allocator or
                    !@hasDecl(core, "rt") or !@hasDecl(core.rt, "frameAllocator"))
                {
                    @compileError(teaching);
                }
            }
            const Return = function.return_type orelse @compileError(teaching);
            const return_info = @typeInfo(Return);
            if (return_info != .pointer or return_info.pointer.size != .slice or !return_info.pointer.is_const) @compileError(teaching);
            const State = statusItemRecordType(return_info.pointer.child, teaching);
            const info = @typeInfo(State).@"struct";
            if (info.fields.len != 9 or !@hasField(State, "id") or !@hasField(State, "visible") or
                !@hasField(State, "iconPath") or !@hasField(State, "tooltip") or !@hasField(State, "activationCommand") or
                !@hasField(State, "alternateActivationCommand") or !@hasField(State, "openCommand") or
                !@hasField(State, "presentation") or !@hasField(State, "items") or
                !statusItemNumericType(@FieldType(State, "id")) or @FieldType(State, "visible") != bool or
                @FieldType(State, "iconPath") != []const u8 or @FieldType(State, "tooltip") != []const u8 or
                @FieldType(State, "activationCommand") != []const u8 or @FieldType(State, "alternateActivationCommand") != []const u8 or
                @FieldType(State, "openCommand") != []const u8)
            {
                @compileError(teaching);
            }
            const Presentation = statusItemRecordType(@FieldType(State, "presentation"), teaching);
            const presentation_info = @typeInfo(Presentation).@"struct";
            if (presentation_info.fields.len != 7 or !@hasField(Presentation, "title") or !@hasField(Presentation, "width") or
                !@hasField(Presentation, "tone") or !@hasField(Presentation, "iconOpacity") or !@hasField(Presentation, "monospaced") or
                !@hasField(Presentation, "fontSize") or !@hasField(Presentation, "fontWeight") or
                @FieldType(Presentation, "title") != []const u8 or !statusItemNumericType(@FieldType(Presentation, "width")) or
                !statusItemEnumType(@FieldType(Presentation, "tone"), &.{ "normal", "warning", "critical" }) or
                !statusItemNumericType(@FieldType(Presentation, "iconOpacity")) or @FieldType(Presentation, "monospaced") != bool or
                !optionalNumericType(@FieldType(Presentation, "fontSize")) or
                !optionalEnumType(@FieldType(Presentation, "fontWeight"), &.{ "regular", "medium", "semibold", "bold" }))
            {
                @compileError(teaching);
            }
            const items_info = @typeInfo(@FieldType(State, "items"));
            if (items_info != .pointer or items_info.pointer.size != .slice or !items_info.pointer.is_const) @compileError(teaching);
            const Item = statusItemRecordType(items_info.pointer.child, teaching);
            const item_info = @typeInfo(Item).@"struct";
            if (item_info.fields.len != 12 or !@hasField(Item, "id") or !@hasField(Item, "label") or
                !@hasField(Item, "command") or !@hasField(Item, "separator") or !@hasField(Item, "enabled") or
                !@hasField(Item, "detail") or !@hasField(Item, "role") or !@hasField(Item, "key") or
                !@hasField(Item, "modifiers") or !@hasField(Item, "segmented") or !@hasField(Item, "metric") or !@hasField(Item, "chart") or
                !statusItemNumericType(@FieldType(Item, "id")) or
                @FieldType(Item, "label") != []const u8 or @FieldType(Item, "command") != []const u8 or
                @FieldType(Item, "separator") != bool or @FieldType(Item, "enabled") != bool or
                @FieldType(Item, "detail") != []const u8 or
                !statusItemEnumType(@FieldType(Item, "role"), &.{ "command", "info", "header", "hero", "agent", "context", "segmented", "chart" }) or
                @FieldType(Item, "key") != []const u8)
            {
                @compileError(teaching);
            }
            validateStatusItemRichTypes(Item, teaching);
            const Modifiers = statusItemRecordType(@FieldType(Item, "modifiers"), teaching);
            const modifiers_info = @typeInfo(Modifiers).@"struct";
            if (modifiers_info.fields.len != 5 or !@hasField(Modifiers, "primary") or !@hasField(Modifiers, "command") or
                !@hasField(Modifiers, "control") or !@hasField(Modifiers, "option") or !@hasField(Modifiers, "shift") or
                @FieldType(Modifiers, "primary") != bool or @FieldType(Modifiers, "command") != bool or
                @FieldType(Modifiers, "control") != bool or @FieldType(Modifiers, "option") != bool or
                @FieldType(Modifiers, "shift") != bool)
            {
                @compileError(teaching);
            }
        }

        fn validateWindowsHelper() void {
            const teaching = "TsUiApp: windows must be exported from core.ts as windows(model: Model): readonly WindowDescriptor[]; import WindowDescriptor from @native-sdk/core/events and construct entries with windowDescriptor(...)";
            const helper_info = @typeInfo(@TypeOf(Model.windows));
            if (helper_info != .@"fn") @compileError(teaching);
            const function = helper_info.@"fn";
            if ((function.params.len != 1 and function.params.len != 2) or function.params[0].type == null or function.params[0].type.? != *const Model) @compileError(teaching);
            if (function.params.len == 2) {
                if (function.params[1].type == null or function.params[1].type.? != std.mem.Allocator or
                    !@hasDecl(core, "rt") or !@hasDecl(core.rt, "frameAllocator")) @compileError(teaching);
            }
            const Return = function.return_type orelse @compileError(teaching);
            const return_info = @typeInfo(Return);
            if (return_info != .pointer or return_info.pointer.size != .slice or !return_info.pointer.is_const) @compileError(teaching);
            const Window = statusItemRecordType(return_info.pointer.child, teaching);
            const info = @typeInfo(Window).@"struct";
            if (info.fields.len != 19 or !@hasField(Window, "label") or !@hasField(Window, "canvasLabel") or
                !@hasField(Window, "title") or !@hasField(Window, "width") or !@hasField(Window, "height") or
                !@hasField(Window, "x") or !@hasField(Window, "y") or !@hasField(Window, "resizable") or
                !@hasField(Window, "restorePolicy") or
                !@hasField(Window, "minWidth") or !@hasField(Window, "minHeight") or !@hasField(Window, "titlebar") or
                !@hasField(Window, "transparent") or !@hasField(Window, "alwaysOnTop") or !@hasField(Window, "clickThrough") or
                !@hasField(Window, "activateOnShow") or !@hasField(Window, "allowsFullscreen") or
                !@hasField(Window, "closePolicy") or !@hasField(Window, "onCloseCommand")) @compileError(teaching);
            if (@FieldType(Window, "label") != []const u8 or @FieldType(Window, "canvasLabel") != []const u8 or
                @FieldType(Window, "title") != []const u8 or !statusItemNumericType(@FieldType(Window, "width")) or
                !statusItemNumericType(@FieldType(Window, "height")) or !optionalNumericType(@FieldType(Window, "x")) or
                !optionalNumericType(@FieldType(Window, "y")) or @FieldType(Window, "resizable") != bool or
                !statusItemEnumType(@FieldType(Window, "restorePolicy"), &.{ "clamp_to_visible_screen", "center_on_primary" }) or
                !statusItemNumericType(@FieldType(Window, "minWidth")) or !statusItemNumericType(@FieldType(Window, "minHeight")) or
                !statusItemEnumType(@FieldType(Window, "titlebar"), &.{ "standard", "hidden_inset", "hidden_inset_tall", "chromeless" }) or
                @FieldType(Window, "transparent") != bool or @FieldType(Window, "alwaysOnTop") != bool or
                @FieldType(Window, "clickThrough") != bool or @FieldType(Window, "activateOnShow") != bool or
                @FieldType(Window, "allowsFullscreen") != bool or
                !statusItemEnumType(@FieldType(Window, "closePolicy"), &.{ "quit", "hide" }) or
                @FieldType(Window, "onCloseCommand") != []const u8) @compileError(teaching);
        }

        fn optionalNumericType(comptime T: type) bool {
            const info = @typeInfo(T);
            return info == .optional and statusItemNumericType(info.optional.child);
        }

        fn optionalEnumType(comptime T: type, comptime expected: []const []const u8) bool {
            const info = @typeInfo(T);
            return info == .optional and statusItemEnumType(info.optional.child, expected);
        }

        fn validateStatusItemRichTypes(comptime Item: type, comptime teaching: []const u8) void {
            const segmented_info = @typeInfo(@FieldType(Item, "segmented"));
            const metric_info = @typeInfo(@FieldType(Item, "metric"));
            const chart_info = @typeInfo(@FieldType(Item, "chart"));
            if (segmented_info != .optional or metric_info != .optional or chart_info != .optional) @compileError(teaching);

            const Segmented = statusItemRecordType(segmented_info.optional.child, teaching);
            const segmented_fields = @typeInfo(Segmented).@"struct".fields;
            if (segmented_fields.len != 1 or !@hasField(Segmented, "options")) @compileError(teaching);
            const options_info = @typeInfo(@FieldType(Segmented, "options"));
            if (options_info != .pointer or options_info.pointer.size != .slice or !options_info.pointer.is_const) @compileError(teaching);
            const Option = statusItemRecordType(options_info.pointer.child, teaching);
            const option_info = @typeInfo(Option).@"struct";
            if (option_info.fields.len != 5 or !@hasField(Option, "id") or !@hasField(Option, "label") or
                !@hasField(Option, "command") or !@hasField(Option, "selected") or !@hasField(Option, "enabled") or
                !statusItemNumericType(@FieldType(Option, "id")) or @FieldType(Option, "label") != []const u8 or
                @FieldType(Option, "command") != []const u8 or @FieldType(Option, "selected") != bool or
                @FieldType(Option, "enabled") != bool) @compileError(teaching);

            const Metric = statusItemRecordType(metric_info.optional.child, teaching);
            const metric_fields = @typeInfo(Metric).@"struct".fields;
            if (metric_fields.len != 3 or !@hasField(Metric, "primaryText") or !@hasField(Metric, "secondaryText") or
                !@hasField(Metric, "accessibilityLabel") or @FieldType(Metric, "primaryText") != []const u8 or
                @FieldType(Metric, "secondaryText") != []const u8 or @FieldType(Metric, "accessibilityLabel") != []const u8) @compileError(teaching);

            const Chart = statusItemRecordType(chart_info.optional.child, teaching);
            const chart_fields = @typeInfo(Chart).@"struct".fields;
            if (chart_fields.len != 6 or !@hasField(Chart, "values") or !@hasField(Chart, "minValue") or
                !@hasField(Chart, "maxValue") or !@hasField(Chart, "leadingCaption") or
                !@hasField(Chart, "trailingSummary") or !@hasField(Chart, "accessibilityLabel")) @compileError(teaching);
            const values_info = @typeInfo(@FieldType(Chart, "values"));
            if (values_info != .pointer or values_info.pointer.size != .slice or !values_info.pointer.is_const or
                !statusItemNumericType(values_info.pointer.child) or !statusItemNumericType(@FieldType(Chart, "minValue")) or
                !statusItemNumericType(@FieldType(Chart, "maxValue")) or @FieldType(Chart, "leadingCaption") != []const u8 or
                @FieldType(Chart, "trailingSummary") != []const u8 or @FieldType(Chart, "accessibilityLabel") != []const u8) @compileError(teaching);
        }

        fn statusItemNumericType(comptime T: type) bool {
            return @typeInfo(T) == .int or @typeInfo(T) == .float;
        }

        fn statusItemEnumType(comptime T: type, comptime expected: []const []const u8) bool {
            const info = @typeInfo(T);
            if (info != .@"enum" or info.@"enum".fields.len != expected.len) return false;
            inline for (expected) |name| {
                var found = false;
                inline for (info.@"enum".fields) |field| {
                    if (std.mem.eql(u8, name, field.name)) found = true;
                }
                if (!found) return false;
            }
            return true;
        }

        fn statusItemRecordType(comptime Raw: type, comptime teaching: []const u8) type {
            const Record = switch (@typeInfo(Raw)) {
                .pointer => |pointer| if (pointer.size == .one and pointer.is_const) pointer.child else @compileError(teaching),
                else => Raw,
            };
            if (@typeInfo(Record) != .@"struct") @compileError(teaching);
            return Record;
        }

        /// `Options.init_fx`: register the wiring's boot images, perform
        /// the boot command and initial subscriptions on the installing
        /// frame (the boot model itself committed in `init`), dispatch
        /// the launch environment overrides as ordinary journaled Msgs,
        /// then refresh the app-held root.
        fn initFx(model: *Model, fx: *Effects) void {
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                compiledInitFx(model, fx);
                return;
            }
            if (host_call_mux_store) |*mux| {
                fx.bindHostCalls(mux.binding());
            } else if (host_calls_store) |binding| {
                fx.bindHostCalls(binding);
            } else if (persist_options_store) |persist| {
                fx.bindHostCalls(persist.binding);
            }
            for (boot_images_store) |image| {
                // Registration is synchronous; a failed decode leaves the
                // views on their fallback (avatar initials) — a bad asset
                // never breaks presentation (the Zig apps' convention).
                _ = fx.registerImageBytes(image.id, image.bytes) catch continue;
            }
            if (persist_options_store) |persist| {
                if (persist.outcome_handle) |handle| {
                    handle.* = fx.openChannel(.{
                        .key = persist_outcome_channel_key,
                        .on_event = persistOutcomeMsg,
                        .max_pending = 8,
                    });
                }
            }
            const persist_outcome = preparePersistRestore(fx);
            Host.performBoot(fx);
            if (persist_outcome) |outcome| dispatchPersistOutcome(fx, outcome);
            dispatchEnvValues(fx);
            model.* = Host.model().*;
        }

        fn compiledInitFx(model: *Model, fx: *Effects) void {
            const plan = compiledLifecycle(&.{ 18, 1, @intFromBool(host_call_mux_store != null), @intFromBool(host_calls_store != null), @intFromBool(persist_options_store != null), @intFromBool(if (persist_options_store) |persist| persist.outcome_handle != null else false) });
            var outcome: ?persist_store.Outcome = null;
            for (plan) |action| switch (action) {
                0 => break,
                1 => fx.bindHostCalls(host_call_mux_store.?.binding()),
                2 => fx.bindHostCalls(host_calls_store.?),
                3 => fx.bindHostCalls(persist_options_store.?.binding),
                4 => for (boot_images_store) |image| {
                    _ = fx.registerImageBytes(image.id, image.bytes) catch continue;
                },
                5 => persist_options_store.?.outcome_handle.?.* = fx.openChannel(.{
                    .key = persist_outcome_channel_key,
                    .on_event = persistOutcomeMsg,
                    .max_pending = 8,
                }),
                6 => outcome = preparePersistRestore(fx),
                7 => Host.performBoot(fx),
                8 => if (outcome) |value| {
                    dispatchPersistOutcome(fx, value);
                },
                9 => dispatchEnvValues(fx),
                10 => model.* = Host.model().*,
                else => @panic("invalid compiled installation action"),
            };
        }

        /// Resolve the boot snapshot entirely at the effect boundary. Live
        /// launches journal the runner-provided result; replay consumes the
        /// recorded result and never consults the current app-data directory.
        fn preparePersistRestore(fx: *Effects) ?persist_store.Outcome {
            if (comptime @hasDecl(core, "nativeEffectPolicy")) return compiledPreparePersistRestore(fx);
            const persist = persist_options_store orelse return null;
            const restore = if (fx.replay) fx.takeReplayPersist() orelse return null else blk: {
                if (persist.restore.migration_from_version) |from_version| {
                    if (Host.migrateSnapshot(persist.restore.bytes, from_version, std.heap.page_allocator)) |migrated| {
                        defer std.heap.page_allocator.free(migrated);
                        if (migrated.len > persist_store.max_snapshot_bytes) {
                            fx.journalPersistRestore(.rejected, "");
                            return .rejected;
                        }
                        Host.restoreSnapshot(migrated);
                        persist.binding.send_fn(persist.binding.context, "core.persist", migrated);
                        fx.journalPersistRestore(.ok, migrated);
                        return .ok;
                    }
                    fx.journalPersistRestore(.migrate_failed, "");
                    return .migrate_failed;
                }
                fx.journalPersistRestore(persist.restore.outcome, persist.restore.bytes);
                break :blk runtime_effects.ReplayPersistEntry{ .outcome = persist.restore.outcome, .bytes = persist.restore.bytes };
            };
            if (restore.outcome == .ok) Host.restoreSnapshot(restore.bytes);
            return restore.outcome;
        }

        fn compiledPreparePersistRestore(fx: *Effects) ?persist_store.Outcome {
            const start = compiledLifecycle(&.{ 18, 2, @intFromBool(persist_options_store != null), @intFromBool(fx.replay), @intFromBool(if (persist_options_store) |persist| persist.restore.migration_from_version != null else false) });
            var migrated: ?[]u8 = null;
            defer if (migrated) |bytes| std.heap.page_allocator.free(bytes);
            var source: u8 = 0;
            var entry: ?runtime_effects.ReplayPersistEntry = null;
            switch (start[0]) {
                0 => return null,
                1 => entry = fx.takeReplayPersist(),
                2 => {
                    source = 2;
                    const persist = persist_options_store.?;
                    migrated = Host.migrateSnapshot(persist.restore.bytes, persist.restore.migration_from_version.?, std.heap.page_allocator);
                    entry = .{ .outcome = .ok, .bytes = migrated orelse "" };
                },
                3 => {
                    source = 1;
                    const restore = persist_options_store.?.restore;
                    entry = .{ .outcome = restore.outcome, .bytes = restore.bytes };
                },
                else => @panic("invalid compiled restore source"),
            }
            var request: [16]u8 = @splat(0);
            request[0..6].* = .{ 18, 3, source, @intFromBool(entry != null), @intFromBool(migrated != null), @intFromEnum(if (entry) |value| value.outcome else persist_store.Outcome.none) };
            std.mem.writeInt(u64, request[8..16], if (entry) |value| value.bytes.len else 0, .little);
            const plan = compiledLifecycle(&request);
            if (plan[0] == 255) return null;
            const outcome = std.enums.fromInt(persist_store.Outcome, plan[0]) orelse @panic("invalid compiled restore outcome");
            if (plan[5] > 1) @panic("invalid compiled restore payload source");
            const bytes = if (plan[5] == 1) entry.?.bytes else "";
            for (plan[1..5]) |action| switch (action) {
                0 => break,
                1 => Host.restoreSnapshot(bytes),
                2 => {
                    const binding = persist_options_store.?.binding;
                    binding.send_fn(binding.context, "core.persist", bytes);
                },
                3 => fx.journalPersistRestore(outcome, bytes),
                else => @panic("invalid compiled restore action"),
            };
            return outcome;
        }

        fn dispatchPersistOutcome(fx: *Effects, outcome: persist_store.Outcome) void {
            const routes = persist_options_store.?.routes;
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                const plan = compiledLifecycle(&.{ 18, 4, @intFromEnum(outcome) });
                switch (plan[0]) {
                    1 => dispatchPersistVoid(fx, routes.ok),
                    2 => dispatchPersistVoid(fx, routes.none),
                    3 => dispatchPersistError(fx, routes.err, compiledReason(&plan)),
                    else => @panic("invalid compiled persistence route"),
                }
                return;
            }
            switch (outcome) {
                .ok => dispatchPersistVoid(fx, routes.ok),
                .none => dispatchPersistVoid(fx, routes.none),
                .corrupt, .version_unknown, .migrate_failed, .io_failed, .rejected => dispatchPersistError(fx, routes.err, @tagName(outcome)),
            }
        }

        fn persistOutcomeMsg(event: runtime_effects.EffectChannelEvent) Msg {
            @setEvalBranchQuota(msg_scan_quota);
            var plan: [32]u8 = undefined;
            const reason: []const u8 = if (comptime @hasDecl(core, "nativeEffectPolicy")) blk: {
                plan = compiledLifecycle(&.{ 18, 5, @intFromEnum(event.kind) });
                if (plan[0] == 0) break :blk event.bytes;
                if (plan[0] != 1) @panic("invalid compiled persistence channel payload");
                const bytes = compiledReason(&plan);
                const copy = core.rt.frameAlloc(u8, bytes.len);
                @memcpy(copy, bytes);
                break :blk copy;
            } else switch (event.kind) {
                .data => event.bytes,
                .rejected => "rejected",
                .closed => "io_failed",
            };
            const route = persist_options_store.?.routes.err;
            inline for (@typeInfo(Msg).@"union".fields) |arm| {
                if (comptime arm.type == []const u8) {
                    if (std.mem.eql(u8, arm.name, route)) return @unionInit(Msg, arm.name, reason);
                }
            }
            @panic("TsUiApp persistence err route does not name a one-Uint8Array-field Msg arm");
        }

        fn compiledReason(plan: *const [32]u8) []const u8 {
            if (plan[1] > 30) @panic("invalid compiled persistence reason length");
            return plan[2..][0..plan[1]];
        }

        fn dispatchPersistVoid(fx: *Effects, route: []const u8) void {
            @setEvalBranchQuota(msg_scan_quota);
            inline for (@typeInfo(Msg).@"union".fields) |arm| {
                if (comptime arm.type == void) {
                    if (std.mem.eql(u8, arm.name, route)) {
                        Host.dispatch(fx, @unionInit(Msg, arm.name, {}));
                        return;
                    }
                }
            }
            @panic("TsUiApp persistence route does not name a void Msg arm");
        }

        fn dispatchPersistError(fx: *Effects, route: []const u8, reason: []const u8) void {
            @setEvalBranchQuota(msg_scan_quota);
            inline for (@typeInfo(Msg).@"union".fields) |arm| {
                if (comptime arm.type == []const u8) {
                    if (std.mem.eql(u8, arm.name, route)) {
                        const copy = core.rt.frameAlloc(u8, reason.len);
                        @memcpy(copy, reason);
                        Host.dispatch(fx, @unionInit(Msg, arm.name, copy));
                        return;
                    }
                }
            }
            @panic("TsUiApp persistence err route does not name a one-Uint8Array-field Msg arm");
        }

        /// The `envMsgs` channel's delivery: each launch-resolved value
        /// dispatches its named one-bytes-field arm — a full core cycle
        /// per value, in declaration order, right after the boot command.
        ///
        /// Record/replay is the channel's whole point, so the values are
        /// JOURNALED at record time (one `.env` effect record per
        /// delivery, written during the installing frame's dispatch) and
        /// FED from the journal under replay — zero env reads, so a
        /// recording replays byte-identically even when the variables
        /// are unset or changed at replay launch. Backward compatibility:
        /// a journal with NO `.env` records (an older recording, or a
        /// launch with no variables set) re-derives from the launch
        /// configuration exactly as before.
        fn dispatchEnvValues(fx: *Effects) void {
            if (comptime !@hasDecl(core, "envMsgs")) return;
            comptime validateEnvMsgs();
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                var request: [32]u8 = @splat(0);
                request[0..3].* = .{ 18, 6, @intFromBool(fx.replay) };
                // Capture the replay count before consuming entries; an empty
                // older journal uses launch values, but a drained new one does
                // not switch sources halfway through installation.
                std.mem.writeInt(u64, request[8..16], fx.replay_env_len, .little);
                std.mem.writeInt(u64, request[16..24], env_values_store.len, .little);
                while (true) {
                    const plan = compiledLifecycle(&request);
                    if (plan[0] == 0) return;
                    if (plan[1] > 1) @panic("invalid compiled environment journal flag");
                    const index = std.mem.readInt(u64, plan[8..16], .little);
                    const entry: EnvValue = switch (plan[0]) {
                        1 => env_values_store[@intCast(index)],
                        2 => blk: {
                            const recorded = fx.takeReplayEnv() orelse return;
                            break :blk .{ .msg = recorded.msg, .value = recorded.value };
                        },
                        else => @panic("invalid compiled environment source"),
                    };
                    if (plan[1] == 1) fx.journalEnvValue(@intCast(index), entry.msg, entry.value);
                    dispatchOneEnvValue(fx, entry.msg, entry.value);
                    @memcpy(request[24..32], plan[16..24]);
                }
            }
            if (fx.replay and fx.replay_env_len > 0) {
                while (fx.takeReplayEnv()) |entry| dispatchOneEnvValue(fx, entry.msg, entry.value);
                return;
            }
            for (env_values_store, 0..) |entry, index| {
                fx.journalEnvValue(index, entry.msg, entry.value);
                dispatchOneEnvValue(fx, entry.msg, entry.value);
            }
        }

        /// One env delivery: resolve the arm by name and dispatch the
        /// value through a full core cycle.
        fn dispatchOneEnvValue(fx: *Effects, msg: []const u8, value: []const u8) void {
            @setEvalBranchQuota(msg_scan_quota);
            inline for (@typeInfo(Msg).@"union".fields) |arm| {
                if (comptime arm.type == []const u8) {
                    if (std.mem.eql(u8, arm.name, msg)) {
                        // The value copies into the core's frame arena
                        // first, like every routed bytes payload: the
                        // commit walkers copy frame-resident bytes the
                        // model keeps into the heap.
                        const copy = core.rt.frameAlloc(u8, value.len);
                        @memcpy(copy, value);
                        Host.dispatch(fx, @unionInit(Msg, arm.name, copy));
                    }
                }
            }
        }

        /// Teaching re-derivation of the frontend's NS1033 for
        /// hand-assembled cores: every `envMsgs` entry must name a Msg
        /// arm carrying exactly one bytes payload.
        fn validateEnvMsgs() void {
            @setEvalBranchQuota(scaledTypeScanQuota(Msg, core.envMsgs.len));
            for (core.envMsgs) |entry| {
                var found = false;
                for (@typeInfo(Msg).@"union".fields) |arm| {
                    if (std.mem.eql(u8, arm.name, entry.msg)) {
                        if (arm.type != []const u8) {
                            @compileError("TsUiApp: envMsgs entry '" ++ entry.env ++ "' targets Msg arm '" ++ entry.msg ++ "', whose payload is not one Uint8Array field");
                        }
                        found = true;
                    }
                }
                if (!found) {
                    @compileError("TsUiApp: envMsgs entry '" ++ entry.env ++ "' names '" ++ entry.msg ++ "', which is not an arm of Msg");
                }
            }
        }

        /// Widen one host number into a channel record's declared field
        /// class: floats take the value exactly, integer-classed fields
        /// round to the nearest whole number.
        fn channelNum(comptime N: type, value: f64) N {
            return if (@typeInfo(N) == .float) @floatCast(value) else @intFromFloat(@round(value));
        }

        /// `Options.on_frame` over the core's `frameMsg(model, frame)`
        /// export: the emitted FrameEvent record — `width`/`height`
        /// (canvas points) plus `timestampMs`/`intervalMs` (fractional
        /// milliseconds, the timer-fire clock; emitted fields keep their
        /// TS names) — built by field NAME from
        /// the presented frame. The core's return gates the channel
        /// exactly like a Zig `on_frame` (null while idle keeps the idle
        /// law: no Msg, no rebuild, the frame channel starves on its own).
        fn frameMsgAdapter(model: *const Model, frame: platform.GpuFrame) ?Msg {
            const params = @typeInfo(@TypeOf(core.frameMsg)).@"fn".params;
            if (comptime (params.len != 2 or params[0].type != *const Model)) {
                @compileError("TsUiApp: frameMsg must take (model: Model, frame: FrameEvent) - regenerate the core");
            }
            const FrameArg = params[1].type.?;
            comptime validateChannelRecord(FrameArg, &.{ "width", "height", "timestampMs", "intervalMs" }, "frameMsg's FrameEvent", &.{});
            var arg: FrameArg = undefined;
            inline for (@typeInfo(FrameArg).@"struct".fields) |field| {
                const value: f64 = if (comptime std.mem.eql(u8, field.name, "width"))
                    frame.size.width
                else if (comptime std.mem.eql(u8, field.name, "height"))
                    frame.size.height
                else if (comptime std.mem.eql(u8, field.name, "timestampMs"))
                    @as(f64, @floatFromInt(frame.timestamp_ns)) / std.time.ns_per_ms
                else
                    @as(f64, @floatFromInt(frame.frame_interval_ns)) / std.time.ns_per_ms;
                @field(arg, field.name) = channelNum(field.type, value);
            }
            return core.frameMsg(model, arg);
        }

        /// `Options.on_key` over the core's `keyMsg(key)` export: the
        /// emitted KeyEvent record — the key NAME (lowercased, so
        /// `key.key === "space"` compares the way the Zig examples'
        /// case-insensitive checks do) plus the four modifier booleans.
        /// The UiApp precedence rule applies before this fires: focused
        /// widgets consume their own keys, editable text keeps typing.
        fn keyMsgAdapter(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
            const params = @typeInfo(@TypeOf(core.keyMsg)).@"fn".params;
            if (comptime params.len != 1) {
                @compileError("TsUiApp: keyMsg must take one KeyEvent parameter - regenerate the core");
            }
            const KeyArg = params[0].type.?;
            comptime {
                const fields = @typeInfo(KeyArg).@"struct".fields;
                if (fields.len != 5 or !@hasField(KeyArg, "key") or !@hasField(KeyArg, "shift") or
                    !@hasField(KeyArg, "control") or !@hasField(KeyArg, "alt") or !@hasField(KeyArg, "super"))
                {
                    @compileError("TsUiApp: keyMsg's KeyEvent must be exactly { key: string; shift: boolean; control: boolean; alt: boolean; super: boolean }");
                }
            }
            // The key name copies lowercased into the core's frame arena:
            // the arena is empty between dispatches, and a Msg the core
            // builds from it commits like every routed bytes payload.
            const lowered = core.rt.frameAlloc(u8, keyboard.key.len);
            for (keyboard.key, 0..) |c, index| lowered[index] = std.ascii.toLower(c);
            var arg: KeyArg = undefined;
            arg.key = lowered;
            arg.shift = keyboard.modifiers.shift;
            arg.control = keyboard.modifiers.control;
            arg.alt = keyboard.modifiers.alt;
            arg.super = keyboard.modifiers.super;
            return core.keyMsg(arg);
        }

        /// `Options.on_pinch` over the core's `pinchMsg(pinch)` export:
        /// the emitted PinchEvent record — `windowId`/`label` (the
        /// source identity: `x`/`y` are view-local, so a coordinate
        /// without its view is not a position; multi-window cores tell
        /// pinches apart by these), `phase` (the declared
        /// begin/change/end alias, matched by member name), `scale` (the
        /// magnification DELTA on "change" — multiplicative, so the
        /// cumulative gesture scale is the product of `1 + scale`,
        /// applied memorylessly), and the `x`/`y` pointer anchor
        /// in view-local canvas points. The core's return gates the channel
        /// exactly like a Zig `on_pinch` (null drops the event).
        fn pinchMsgAdapter(pinch: platform.PinchEvent) ?Msg {
            const params = @typeInfo(@TypeOf(core.pinchMsg)).@"fn".params;
            if (comptime params.len != 1) {
                @compileError("TsUiApp: pinchMsg must take one PinchEvent parameter - regenerate the core");
            }
            const PinchArg = params[0].type.?;
            comptime {
                const fields = @typeInfo(PinchArg).@"struct".fields;
                if (fields.len != 6 or !@hasField(PinchArg, "windowId") or !@hasField(PinchArg, "label") or
                    !@hasField(PinchArg, "phase") or !@hasField(PinchArg, "scale") or
                    !@hasField(PinchArg, "x") or !@hasField(PinchArg, "y"))
                {
                    @compileError("TsUiApp: pinchMsg's PinchEvent must be exactly { windowId: number; label: string; phase: \"begin\" | \"change\" | \"end\"; scale: number; x: number; y: number }");
                }
                const Phase = @FieldType(PinchArg, "phase");
                const phase_info = @typeInfo(Phase);
                if (phase_info != .@"enum" or phase_info.@"enum".fields.len != 3 or
                    !@hasField(Phase, "begin") or !@hasField(Phase, "change") or !@hasField(Phase, "end"))
                {
                    @compileError("TsUiApp: pinchMsg's PinchEvent.phase must be the named \"begin\" | \"change\" | \"end\" alias");
                }
            }
            var arg: PinchArg = undefined;
            const Phase = @FieldType(PinchArg, "phase");
            arg.phase = switch (pinch.phase) {
                inline else => |phase| @field(Phase, @tagName(phase)),
            };
            // The label slice stays borrowed exactly through the core
            // call, like the Zig channel's contract: a Msg built from it
            // commits (copies) on dispatch like every routed bytes
            // payload.
            arg.windowId = channelNum(@FieldType(PinchArg, "windowId"), @floatFromInt(pinch.window_id));
            arg.label = pinch.label;
            arg.scale = channelNum(@FieldType(PinchArg, "scale"), pinch.scale);
            arg.x = channelNum(@FieldType(PinchArg, "x"), pinch.x);
            arg.y = channelNum(@FieldType(PinchArg, "y"), pinch.y);
            return core.pinchMsg(arg);
        }

        /// `Options.on_drop` over the core's `dropMsg(drop)` export: the
        /// emitted FileDropEvent record carries the source window/view,
        /// optional view-local point, and every path as byte text. The
        /// slices stay borrowed through the channel call; a Msg that keeps
        /// one is committed through the ordinary core dispatch immediately
        /// after this mapper returns.
        fn dropMsgAdapter(drop: platform.FileDropEvent) ?Msg {
            const params = @typeInfo(@TypeOf(core.dropMsg)).@"fn".params;
            if (comptime params.len != 1) {
                @compileError("TsUiApp: dropMsg must take one FileDropEvent parameter - regenerate the core");
            }
            const DropArg = params[0].type.?;
            comptime validateDropEvent(DropArg);
            const PointArg = @typeInfo(@FieldType(DropArg, "point")).optional.child;
            var arg: DropArg = undefined;
            arg.windowId = channelNum(@FieldType(DropArg, "windowId"), @floatFromInt(drop.window_id));
            arg.viewLabel = drop.view_label;
            arg.point = if (drop.point) |point| blk: {
                var out: PointArg = undefined;
                out.x = channelNum(@FieldType(PointArg, "x"), point.x);
                out.y = channelNum(@FieldType(PointArg, "y"), point.y);
                break :blk out;
            } else null;
            arg.paths = drop.paths;
            return core.dropMsg(arg);
        }

        /// `Options.on_appearance` over the core's `appearanceMsg` arm
        /// export: the appearance record — `colorScheme` (a declared
        /// light/dark enum, matched by member name), `reduceMotion`,
        /// `highContrast` — built by field NAME (emitted fields keep
        /// their TS names), always dispatched (the channel exists so the
        /// MODEL owns appearance state).
        fn appearanceMsgAdapter(appearance: platform.Appearance) ?Msg {
            const arm_index = comptime channelArmIndex(core.appearanceMsg, "appearanceMsg");
            const arm = @typeInfo(Msg).@"union".fields[arm_index];
            comptime validateAppearanceArm(arm.type);
            var payload: arm.type = undefined;
            payload.reduceMotion = appearance.reduce_motion;
            payload.highContrast = appearance.high_contrast;
            const Scheme = @FieldType(arm.type, "colorScheme");
            payload.colorScheme = switch (appearance.color_scheme) {
                inline else => |scheme| @field(Scheme, @tagName(scheme)),
            };
            return @unionInit(Msg, arm.name, payload);
        }

        /// `Options.on_chrome` over the core's `chromeMsg` arm export:
        /// the chrome record — `insets` (top/right/bottom/left), `buttons`
        /// (x/y/width/height), `tabsProjected` — built by field NAME from
        /// the window-chrome geometry, delivered before the first view
        /// build and again whenever it changes.
        fn chromeMsgAdapter(chrome: platform.WindowChrome) ?Msg {
            const arm_index = comptime channelArmIndex(core.chromeMsg, "chromeMsg");
            const arm = @typeInfo(Msg).@"union".fields[arm_index];
            comptime validateChromeArm(arm.type);
            var payload: arm.type = undefined;
            const Insets = @FieldType(arm.type, "insets");
            payload.insets = .{
                .top = channelNum(@FieldType(Insets, "top"), chrome.insets.top),
                .right = channelNum(@FieldType(Insets, "right"), chrome.insets.right),
                .bottom = channelNum(@FieldType(Insets, "bottom"), chrome.insets.bottom),
                .left = channelNum(@FieldType(Insets, "left"), chrome.insets.left),
            };
            const Buttons = @FieldType(arm.type, "buttons");
            payload.buttons = .{
                .x = channelNum(@FieldType(Buttons, "x"), chrome.buttons.x),
                .y = channelNum(@FieldType(Buttons, "y"), chrome.buttons.y),
                .width = channelNum(@FieldType(Buttons, "width"), chrome.buttons.width),
                .height = channelNum(@FieldType(Buttons, "height"), chrome.buttons.height),
            };
            payload.tabsProjected = chrome.tabs_projected;
            return @unionInit(Msg, arm.name, payload);
        }

        /// The Msg arm index a channel export names, with the teaching
        /// error the frontend's NS1033 re-derives for hand-written
        /// cores.
        fn channelArmIndex(comptime tag: []const u8, comptime channel: []const u8) usize {
            @setEvalBranchQuota(msg_scan_quota);
            for (@typeInfo(Msg).@"union".fields, 0..) |arm, index| {
                if (std.mem.eql(u8, arm.name, tag)) return index;
            }
            @compileError("TsUiApp: " ++ channel ++ " names '" ++ tag ++ "', which is not an arm of Msg");
        }

        /// `signed_names` lists the fields the host supplies signed
        /// (positions in content coordinates): those may not take the
        /// unsigned class, while extents, sizes, and clocks — always
        /// non-negative from the host — take any numeric class.
        fn validateChannelRecord(comptime T: type, comptime names: []const []const u8, comptime what: []const u8, comptime signed_names: []const []const u8) void {
            const info = @typeInfo(T);
            if (info != .@"struct" or info.@"struct".fields.len != names.len) {
                @compileError("TsUiApp: " ++ what ++ " record has the wrong field set");
            }
            for (names) |name| {
                if (!@hasField(T, name)) {
                    @compileError("TsUiApp: " ++ what ++ " record is missing field '" ++ name ++ "'");
                }
            }
            for (info.@"struct".fields) |field| {
                if (field.type == u64) {
                    for (signed_names) |signed| {
                        if (std.mem.eql(u8, field.name, signed)) {
                            @compileError("TsUiApp: " ++ what ++ " field '" ++ field.name ++ "' rides signed content coordinates, which u64 cannot carry - declare it i64 or f64");
                        }
                    }
                }
                if (field.type != i64 and field.type != u64 and field.type != f64 and field.type != f32) {
                    @compileError("TsUiApp: " ++ what ++ " field '" ++ field.name ++ "' must be a number");
                }
            }
        }

        fn validateDropEvent(comptime T: type) void {
            const teaching = "TsUiApp: dropMsg's FileDropEvent must be exactly { windowId: number; viewLabel: string; point: { x: number; y: number } | null; paths: readonly Uint8Array[] }";
            const info = @typeInfo(T);
            if (info != .@"struct" or info.@"struct".fields.len != 4) @compileError(teaching);
            if (!@hasField(T, "windowId") or !@hasField(T, "viewLabel") or !@hasField(T, "point") or !@hasField(T, "paths")) @compileError(teaching);
            validateChannelRecord(struct { windowId: @FieldType(T, "windowId") }, &.{"windowId"}, "dropMsg's FileDropEvent", &.{});
            if (@FieldType(T, "viewLabel") != []const u8) @compileError(teaching);

            const Point = switch (@typeInfo(@FieldType(T, "point"))) {
                .optional => |optional| optional.child,
                else => @compileError(teaching),
            };
            validateChannelRecord(Point, &.{ "x", "y" }, "dropMsg's FileDropEvent.point", &.{ "x", "y" });

            const paths = @typeInfo(@FieldType(T, "paths"));
            if (paths != .pointer or paths.pointer.size != .slice) @compileError(teaching);
            const path = @typeInfo(paths.pointer.child);
            if (path != .pointer or path.pointer.size != .slice or path.pointer.child != u8 or !path.pointer.is_const) @compileError(teaching);
        }

        fn validateAppearanceArm(comptime T: type) void {
            const teaching = "TsUiApp: appearanceMsg's arm must carry exactly { colorScheme: a named light/dark alias; reduceMotion: boolean; highContrast: boolean }";
            const info = @typeInfo(T);
            if (info != .@"struct" or info.@"struct".fields.len != 3) @compileError(teaching);
            if (!@hasField(T, "colorScheme") or !@hasField(T, "reduceMotion") or !@hasField(T, "highContrast")) @compileError(teaching);
            const Scheme = @FieldType(T, "colorScheme");
            const scheme_info = @typeInfo(Scheme);
            if (scheme_info != .@"enum" or scheme_info.@"enum".fields.len != 2 or
                !@hasField(Scheme, "light") or !@hasField(Scheme, "dark")) @compileError(teaching);
            if (@FieldType(T, "reduceMotion") != bool or @FieldType(T, "highContrast") != bool) @compileError(teaching);
        }

        fn validateChromeArm(comptime T: type) void {
            const teaching = "TsUiApp: chromeMsg's arm must carry exactly { insets: top/right/bottom/left numbers; buttons: x/y/width/height numbers; tabsProjected: boolean }";
            const info = @typeInfo(T);
            if (info != .@"struct" or info.@"struct".fields.len != 3) @compileError(teaching);
            if (!@hasField(T, "insets") or !@hasField(T, "buttons") or !@hasField(T, "tabsProjected")) @compileError(teaching);
            if (@FieldType(T, "tabsProjected") != bool) @compileError(teaching);
            validateChannelRecord(@FieldType(T, "insets"), &.{ "top", "right", "bottom", "left" }, "chromeMsg's insets", &.{});
            validateChannelRecord(@FieldType(T, "buttons"), &.{ "x", "y", "width", "height" }, "chromeMsg's buttons", &.{ "x", "y" });
        }

        /// `Options.update_fx`: one full core dispatch cycle, then the
        /// app-held root becomes the new committed value. The incoming
        /// model pointer is the previous root value — the bridge holds
        /// the authoritative one, so it is overwritten, never read.
        fn updateFx(model: *Model, msg: Msg, fx: *Effects) void {
            Host.dispatch(fx, msg);
            model.* = Host.model().*;
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                const plan = compiledFlush(5, false);
                lifecycle_flush_after_update = plan[0] == 1;
                if (plan[1] == 1) flushPersistence();
                return;
            }
            if (lifecycle_flush_after_update) {
                lifecycle_flush_after_update = false;
                flushPersistence();
            }
        }
    };
}

fn LifecycleProbeCore(comptime identity: u8) type {
    return struct {
        pub const Model = struct { count: usize = identity, reason: []const u8 = "" };
        pub const Msg = union(enum) { ok, none, err: []const u8, env: []const u8, increment };
        pub const envMsgs = [_]struct { env: []const u8, msg: []const u8 }{.{ .env = "LIFECYCLE_VALUE", .msg = "env" }};
        pub const rt = struct {
            var arena: [4096]u8 align(16) = undefined;
            var at: usize = 0;
            pub fn resetAll() void {
                at = 0;
            }
            pub fn frameReset() void {
                at = 0;
            }
            pub fn frameAlloc(comptime T: type, count: usize) []T {
                at = std.mem.alignForward(usize, at, @alignOf(T));
                const start = at;
                at += count * @sizeOf(T);
                std.debug.assert(at <= arena.len);
                const pointer: [*]T = @ptrCast(@alignCast(arena[start..].ptr));
                return pointer[0..count];
            }
        };
        var root: Model = .{};
        var owned: [1024]u8 = undefined;
        var override_mode: u8 = 255;
        var forced_plan: [32]u8 = @splat(0);
        var calls: [8]usize = @splat(0);
        pub fn nativeEffectPolicy(request: []const u8, output: []u8) usize {
            std.debug.assert(request[0] == 18 and request[1] < calls.len);
            calls[request[1]] += 1;
            const plan = if (request[1] == override_mode and !(override_mode == 6 and calls[6] > 1)) forced_plan else if (override_mode == 6 and request[1] == 6) @as([32]u8, @splat(0)) else @import("lifecycle_policy_test_reference.zig").plan(request);
            @memcpy(output[0..plan.len], &plan);
            return plan.len;
        }
        pub fn initialModel() *const Model {
            root = .{};
            return &root;
        }
        pub fn commitModelRoot(value: *const Model) *const Model {
            return value;
        }
        pub const UpdateResult = struct { model: *const Model, cmd: []const u8 };
        pub fn update(_: *const Model, msg: Msg) UpdateResult {
            switch (msg) {
                .ok => root.count += 10,
                .none => root.count += 20,
                .increment => root.count += 1,
                .err, .env => |bytes| {
                    @memcpy(owned[0..bytes.len], bytes);
                    root.reason = owned[0..bytes.len];
                    root.count += 1;
                },
            }
            return .{ .model = &root, .cmd = "" };
        }
        pub fn restoreModel(bytes: []const u8) *const Model {
            root.count = if (bytes.len > 0) bytes[0] else 0;
            return &root;
        }
    };
}

const LifecycleCarrierProbe = struct {
    id: u8,
    log: *std.ArrayList(u8),
    sends: usize = 0,
    fn binding(self: *LifecycleCarrierProbe) runtime_effects.HostCallBinding {
        return .{ .context = self, .send_fn = send, .request_fn = request, .cancel_fn = cancel, .poll_fn = poll, .pending_fn = pending, .bind_services_fn = services, .bind_channels_fn = channels, .shutdown_fn = shutdown };
    }
    fn mark(context: *anyopaque) *LifecycleCarrierProbe {
        const self: *LifecycleCarrierProbe = @ptrCast(@alignCast(context));
        self.log.append(std.testing.allocator, self.id) catch @panic("test allocation failed");
        return self;
    }
    fn send(context: *anyopaque, _: []const u8, _: []const u8) void {
        mark(context).sends += 1;
    }
    fn request(context: *anyopaque, _: []const u8, _: u64, _: []const u8) void {
        _ = mark(context);
    }
    fn cancel(context: *anyopaque, _: u64) void {
        _ = mark(context);
    }
    fn poll(context: *anyopaque) ?runtime_effects.HostCallCompletion {
        _ = mark(context);
        return null;
    }
    fn pending(context: *anyopaque) bool {
        _ = mark(context);
        return true;
    }
    fn services(context: *anyopaque, _: *const platform.PlatformServices) void {
        _ = mark(context);
    }
    fn channels(context: *anyopaque, _: runtime_effects.HostChannelBinding) void {
        _ = mark(context);
    }
    fn shutdown(context: *anyopaque) void {
        _ = mark(context);
    }
};

test "lifecycle host consumes flush plans and retains independent instance state" {
    const First = LifecycleProbeCore(1);
    const Second = LifecycleProbeCore(2);
    const A = TsUiApp(First);
    const B = TsUiApp(Second);
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    var carrier: LifecycleCarrierProbe = .{ .id = 1, .log = &log };
    A.applyCoreOptions(.{ .persist = .{ .binding = carrier.binding(), .routes = .{ .ok = "ok", .none = "none", .err = "err" }, .restore = .{ .outcome = .none } } });
    B.applyCoreOptions(.{});
    First.override_mode = 0;
    First.forced_plan = @splat(0);
    First.forced_plan[0] = 1;
    // Force an ordinary activation to delay a flush: native must consume it.
    _ = A.lifecycleAdapter(.activate);
    try std.testing.expect(A.lifecycle_flush_after_update);
    try std.testing.expect(!B.lifecycle_flush_after_update);
    First.forced_plan[0..2].* = .{ 0, 1 };
    A.Host.boot();
    var effects = A.Effects.init(std.testing.allocator);
    defer effects.deinit();
    var model = A.Host.model().*;
    A.updateFx(&model, .increment, &effects);
    try std.testing.expectEqual(@as(usize, 2), model.count);
    try std.testing.expectEqual(@as(usize, 1), carrier.sends);
    try std.testing.expect(!A.lifecycle_flush_after_update);
    A.lifecycle_flush_after_update = true;
    _ = A.stampOptions(.{ .name = "lifecycle-probe", .scene = .{ .windows = &.{} }, .canvas_label = "canvas" });
    try std.testing.expect(!A.lifecycle_flush_after_update);
    try std.testing.expect(!B.lifecycle_flush_after_update);
}

test "lifecycle host consumes installation restore and outcome plans with owned reasons" {
    const Core = LifecycleProbeCore(3);
    const Adapter = TsUiApp(Core);
    Core.override_mode = 1;
    Core.forced_plan = @splat(0);
    Core.forced_plan[0] = 10; // Root refresh only: suppress all boot coordination.
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    var carrier: LifecycleCarrierProbe = .{ .id = 1, .log = &log };
    Adapter.Host.boot();
    Adapter.applyCoreOptions(.{ .persist = .{ .binding = carrier.binding(), .routes = .{ .ok = "ok", .none = "none", .err = "err" }, .restore = .{ .outcome = .none } } });
    var fx = Adapter.Effects.init(std.testing.allocator);
    defer fx.deinit();
    var model: Core.Model = .{};
    Adapter.initFx(&model, &fx);
    try std.testing.expectEqual(@as(usize, 3), model.count);
    try std.testing.expectEqual(@as(usize, 0), Core.calls[2]);
    Core.override_mode = 2;
    Core.forced_plan = @splat(0); // Refuse an otherwise available restoration.
    try std.testing.expectEqual(@as(?persist_store.Outcome, null), Adapter.preparePersistRestore(&fx));
    // Select recorded bytes even though the native live fact is false.
    try fx.pushReplayPersist(.ok, "*");
    Core.forced_plan[0] = 1;
    try std.testing.expectEqual(persist_store.Outcome.ok, Adapter.preparePersistRestore(&fx).?);
    try std.testing.expectEqual(@as(usize, 42), Adapter.Host.model().count);
    Core.override_mode = 4;
    Core.forced_plan[0..2].* = .{ 3, 6 };
    @memcpy(Core.forced_plan[2..8], "forced");
    Adapter.dispatchPersistOutcome(&fx, .ok);
    try std.testing.expectEqualStrings("forced", Adapter.Host.model().reason);
    Core.override_mode = 5;
    Core.forced_plan[0] = 1;
    const msg = Adapter.persistOutcomeMsg(.{ .key = 1, .kind = .data, .bytes = "original" });
    @memset(Core.forced_plan[2..8], 'x');
    try std.testing.expectEqualStrings("forced", msg.err);
    Core.override_mode = 3;
    Core.forced_plan = @splat(0);
    Core.forced_plan[0] = 6; // Live none becomes rejected with no restore.
    try std.testing.expectEqual(persist_store.Outcome.rejected, Adapter.preparePersistRestore(&fx).?);
    Adapter.persist_options_store.?.restore.bytes = "*";
    Core.forced_plan[0..6].* = .{ 0, 1, 2, 3, 0, 1 };
    try std.testing.expectEqual(persist_store.Outcome.ok, Adapter.preparePersistRestore(&fx).?);
    try std.testing.expectEqual(@as(usize, 42), Adapter.Host.model().count);
    try std.testing.expectEqual(@as(usize, 1), carrier.sends);
}

test "lifecycle host consumes carrier targets ordering and exact environment indices" {
    const Core = LifecycleProbeCore(4);
    const Adapter = TsUiApp(Core);
    Core.override_mode = 7;
    Core.forced_plan = @splat(0);
    Core.forced_plan[0..2].* = .{ 2, 1 };
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    var first: LifecycleCarrierProbe = .{ .id = 1, .log = &log };
    var second: LifecycleCarrierProbe = .{ .id = 2, .log = &log };
    var mux: Adapter.HostCallMux = .{ .primary = first.binding(), .persist = second.binding() };
    const binding = mux.binding();
    binding.shutdown_fn.?(binding.context);
    try std.testing.expectEqualSlices(u8, &.{ 2, 1 }, log.items);
    Core.forced_plan[1] = 0;
    binding.send_fn(binding.context, "ordinary.service", "bytes");
    binding.request_fn(binding.context, "ordinary.service", std.math.maxInt(u64), "bytes");
    binding.cancel_fn.?(binding.context, std.math.maxInt(u64));
    _ = binding.poll_fn.?(binding.context);
    try std.testing.expect(binding.pending_fn.?(binding.context));
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 2, 2, 2, 2, 2 }, log.items);
    Core.override_mode = 6;
    Core.forced_plan = @splat(0);
    Core.forced_plan[0] = 1;
    std.mem.writeInt(u64, Core.forced_plan[8..16], 1, .little);
    std.mem.writeInt(u64, Core.forced_plan[16..24], 2, .little);
    Adapter.Host.boot();
    Adapter.applyCoreOptions(.{ .env_values = &.{ .{ .msg = "env", .value = "first" }, .{ .msg = "env", .value = "second" } } });
    var fx = Adapter.Effects.init(std.testing.allocator);
    defer fx.deinit();
    // The probe returns one selected value, then a terminal plan.
    Core.calls[6] = 0;
    Adapter.dispatchEnvValues(&fx);
    try std.testing.expectEqualStrings("second", Adapter.Host.model().reason);
}

const StatusItemsAdapterTestCore = struct {
    const Tone = enum { normal, warning, critical };
    const Role = enum { command, info, header, hero, agent, context, segmented, chart };
    const Modifiers = struct {
        primary: bool,
        command: bool,
        control: bool,
        option: bool,
        shift: bool,
    };
    const Presentation = struct {
        title: []const u8,
        width: f64,
        tone: Tone,
        iconOpacity: f64,
        monospaced: bool,
        fontSize: ?f64,
        fontWeight: ?enum { regular, medium, semibold, bold },
    };
    const SegmentOption = struct {
        id: f64,
        label: []const u8,
        command: []const u8,
        selected: bool,
        enabled: bool,
    };
    const Segmented = struct { options: []const SegmentOption };
    const Metric = struct {
        primaryText: []const u8,
        secondaryText: []const u8,
        accessibilityLabel: []const u8,
    };
    const Chart = struct {
        values: []const f64,
        minValue: f64,
        maxValue: f64,
        leadingCaption: []const u8,
        trailingSummary: []const u8,
        accessibilityLabel: []const u8,
    };
    const Item = struct {
        id: f64,
        label: []const u8,
        command: []const u8,
        separator: bool,
        enabled: bool,
        detail: []const u8,
        role: Role,
        key: []const u8,
        modifiers: Modifiers,
        segmented: ?Segmented,
        metric: ?Metric,
        chart: ?Chart,
    };
    const Descriptor = struct {
        id: f64,
        visible: bool,
        iconPath: []const u8,
        tooltip: []const u8,
        activationCommand: []const u8,
        alternateActivationCommand: []const u8,
        openCommand: []const u8,
        presentation: Presentation,
        items: []const Item,
    };

    const rows = [_]Item{.{
        .id = 3,
        .label = "Refresh",
        .command = "spend.refresh",
        .separator = false,
        .enabled = true,
        .detail = "$7",
        .role = .command,
        .key = "r",
        .modifiers = .{ .primary = true, .command = false, .control = false, .option = false, .shift = false },
        .segmented = null,
        .metric = null,
        .chart = null,
    }};
    const descriptors = [_]Descriptor{.{
        .id = 7,
        .visible = false,
        .iconPath = "spend.png",
        .tooltip = "Vercel spend",
        .activationCommand = "spend.open",
        .alternateActivationCommand = "",
        .openCommand = "spend.refresh",
        .presentation = .{ .title = "$7", .width = 52, .tone = .warning, .iconOpacity = 0.75, .monospaced = true, .fontSize = null, .fontWeight = null },
        .items = &rows,
    }};

    pub const Msg = union(enum) { noop };
    pub const Model = struct {
        pub fn statusItems(_: *const Model) []const Descriptor {
            return &descriptors;
        }
    };
};

test "TypeScript statusItems adapter validates and projects canonical descriptors" {
    const Adapter = TsUiApp(StatusItemsAdapterTestCore);
    comptime Adapter.validateStatusItemsHelper();
    var model = StatusItemsAdapterTestCore.Model{};
    var scratch = Adapter.App.StatusItemsScratch{};
    const descriptors = Adapter.statusItemsAdapter(&model, &scratch);
    try std.testing.expectEqual(@as(usize, 1), descriptors.len);
    try std.testing.expectEqual(@as(platform.StatusItemId, 7), descriptors[0].id);
    try std.testing.expect(!descriptors[0].visible);
    try std.testing.expectEqualStrings("$7", descriptors[0].state.presentation.title);
    try std.testing.expectEqual(@as(f32, 0), descriptors[0].state.presentation.font_size);
    try std.testing.expectEqual(platform.TrayFontWeight.regular, descriptors[0].state.presentation.font_weight);
    try std.testing.expectEqualStrings("spend.png", descriptors[0].state.icon_path);
    try std.testing.expectEqual(@as(usize, 1), descriptors[0].state.items.len);
    try std.testing.expectEqual(@as(platform.TrayItemId, 3), descriptors[0].state.items[0].id);
    try std.testing.expect(descriptors[0].state.items[0].modifiers.primary);
}

const WindowsAdapterTestCore = struct {
    const Titlebar = enum { standard, hidden_inset, hidden_inset_tall, chromeless };
    const RestorePolicy = enum { clamp_to_visible_screen, center_on_primary };
    const ClosePolicy = enum { quit, hide };
    const Descriptor = struct {
        label: []const u8,
        canvasLabel: []const u8,
        title: []const u8,
        width: f64,
        height: f64,
        x: ?f64,
        y: ?f64,
        resizable: bool,
        restorePolicy: RestorePolicy,
        minWidth: f64,
        minHeight: f64,
        titlebar: Titlebar,
        transparent: bool,
        alwaysOnTop: bool,
        clickThrough: bool,
        activateOnShow: bool,
        allowsFullscreen: bool,
        closePolicy: ClosePolicy,
        onCloseCommand: []const u8,
    };

    const descriptors = [_]Descriptor{
        .{ .label = "one", .canvasLabel = "one-canvas", .title = "", .width = 100, .height = 100, .x = null, .y = null, .resizable = true, .restorePolicy = .center_on_primary, .minWidth = 0, .minHeight = 0, .titlebar = .chromeless, .transparent = true, .alwaysOnTop = false, .clickThrough = false, .activateOnShow = true, .allowsFullscreen = true, .closePolicy = .quit, .onCloseCommand = "" },
        .{ .label = "two", .canvasLabel = "two-canvas", .title = "", .width = 100, .height = 100, .x = null, .y = null, .resizable = true, .restorePolicy = .clamp_to_visible_screen, .minWidth = 0, .minHeight = 0, .titlebar = .standard, .transparent = false, .alwaysOnTop = false, .clickThrough = false, .activateOnShow = true, .allowsFullscreen = true, .closePolicy = .quit, .onCloseCommand = "" },
        .{ .label = "three", .canvasLabel = "three-canvas", .title = "", .width = 100, .height = 100, .x = null, .y = null, .resizable = true, .restorePolicy = .clamp_to_visible_screen, .minWidth = 0, .minHeight = 0, .titlebar = .standard, .transparent = false, .alwaysOnTop = false, .clickThrough = false, .activateOnShow = true, .allowsFullscreen = true, .closePolicy = .quit, .onCloseCommand = "" },
        .{ .label = "four", .canvasLabel = "four-canvas", .title = "", .width = 100, .height = 100, .x = null, .y = null, .resizable = true, .restorePolicy = .clamp_to_visible_screen, .minWidth = 0, .minHeight = 0, .titlebar = .standard, .transparent = false, .alwaysOnTop = false, .clickThrough = false, .activateOnShow = true, .allowsFullscreen = true, .closePolicy = .quit, .onCloseCommand = "" },
        .{ .label = "excess", .canvasLabel = "excess-canvas", .title = "", .width = 100, .height = 100, .x = null, .y = null, .resizable = true, .restorePolicy = .clamp_to_visible_screen, .minWidth = 0, .minHeight = 0, .titlebar = .standard, .transparent = false, .alwaysOnTop = false, .clickThrough = false, .activateOnShow = true, .allowsFullscreen = true, .closePolicy = .quit, .onCloseCommand = "" },
    };

    pub const Msg = union(enum) { noop };
    pub const Model = struct {
        pub fn windows(_: *const Model) []const Descriptor {
            return &descriptors;
        }
    };
};

const ThemeStateAdapterTestCore = struct {
    const Pack = enum { house, geist };
    const Scheme = enum { light, dark, system };
    const State = struct {
        pack: ?Pack,
        colorScheme: ?Scheme,
        accent: ?[]const u8,
    };

    pub const Msg = union(enum) { noop };
    pub const Model = struct {
        bad: bool = false,

        pub fn themeState(self: *const Model) State {
            return .{
                .pack = .geist,
                .colorScheme = .dark,
                .accent = if (self.bad) "hot-pink" else "#Df2670",
            };
        }
    };
};

test "TypeScript themeState adapter validates, parses hex, and preserves malformed accent teaching" {
    const Adapter = TsUiApp(ThemeStateAdapterTestCore);
    comptime Adapter.validateThemeStateHelper();
    var model = ThemeStateAdapterTestCore.Model{};
    var state = Adapter.themeStateAdapter(&model);
    try std.testing.expectEqual(canvas.ThemePack.geist, state.pack.?);
    try std.testing.expectEqual(Adapter.App.ThemeColorScheme.dark, state.color_scheme);
    try std.testing.expectEqual(canvas.Color.rgb8(0xdf, 0x26, 0x70), state.accent.?);
    try std.testing.expect(state.invalid_accent == null);

    model.bad = true;
    state = Adapter.themeStateAdapter(&model);
    try std.testing.expect(state.accent == null);
    try std.testing.expectEqualStrings("hot-pink", state.invalid_accent.?);
}

test "TypeScript windows adapter keeps the declared prefix on overflow and projects chromeless" {
    const Adapter = TsUiApp(WindowsAdapterTestCore);
    comptime Adapter.validateWindowsHelper();
    var model = WindowsAdapterTestCore.Model{};
    var scratch = Adapter.App.WindowsScratch{};
    const descriptors = Adapter.windowsAdapter(&model, &scratch);
    try std.testing.expectEqual(Adapter.App.max_ui_windows, descriptors.len);
    try std.testing.expectEqualStrings("one", descriptors[0].label);
    try std.testing.expectEqual(@import("app_manifest").WindowTitlebarStyle.chromeless, descriptors[0].titlebar);
    try std.testing.expectEqual(@import("app_manifest").WindowRestorePolicy.center_on_primary, descriptors[0].restore_policy);
    try std.testing.expect(descriptors[0].transparent);
    try std.testing.expectEqualStrings("four", descriptors[3].label);
}

const WindowCloseCommandTestCore = struct {
    pub const Msg = union(enum) { closed, noop };
    pub const Model = struct {};
};

fn mappedWindowCloseCommand(name: []const u8) ?WindowCloseCommandTestCore.Msg {
    return if (std.mem.eql(u8, name, "settings.closed")) .closed else null;
}

test "TypeScript window close commands refuse missing and unmapped command callbacks" {
    const Adapter = TsUiApp(WindowCloseCommandTestCore);
    Adapter.command_store = null;
    try std.testing.expectError(error.MissingCommandMapper, Adapter.windowCloseMsg("settings.closed"));
    try std.testing.expect((try Adapter.windowCloseMsg("")) == null);

    Adapter.command_store = mappedWindowCloseCommand;
    try std.testing.expectError(error.UnmappedCommand, Adapter.windowCloseMsg("settings.missing"));
    try std.testing.expectEqual(WindowCloseCommandTestCore.Msg.closed, (try Adapter.windowCloseMsg("settings.closed")).?);
}

const WebPanesAdapterTestCore = struct {
    const Pane = struct { label: []const u8, anchor: ?[]const u8, url: []const u8, x: f64, y: f64, width: f64, height: f64, reloadToken: f64 };
    var label = [_]u8{ 'p', 'a', 'n', 'e' };
    var anchor = [_]u8{ 's', 'l', 'o', 't' };
    var url = [_]u8{ 'z', 'e', 'r', 'o', ':', '/', '/', 'a', 'p', 'p' };
    var panes = [_]Pane{.{ .label = &label, .anchor = &anchor, .url = &url, .x = -2.125, .y = 4.5, .width = 100.25, .height = 48.5, .reloadToken = 9007199254740991 }} ** 5;
    pub const Msg = union(enum) { noop };
    pub const Model = struct {
        pub fn webPanes(_: *const Model) []const Pane {
            return &panes;
        }
    };
};

test "TypeScript pane adapter copies result bytes and preserves bounded fractional geometry" {
    const Adapter = TsUiApp(WebPanesAdapterTestCore);
    comptime Adapter.validateWebPanesHelper();
    const model = WebPanesAdapterTestCore.Model{};
    var panes: [4]Adapter.App.WebViewPane = undefined;
    try std.testing.expectEqual(@as(usize, 4), Adapter.webPanesAdapter(&model, &panes));
    const saved = panes[0];
    WebPanesAdapterTestCore.label[0] = 'x';
    WebPanesAdapterTestCore.anchor[0] = 'x';
    WebPanesAdapterTestCore.url[0] = 'x';
    defer {
        WebPanesAdapterTestCore.label[0] = 'p';
        WebPanesAdapterTestCore.anchor[0] = 's';
        WebPanesAdapterTestCore.url[0] = 'z';
    }
    try std.testing.expectEqualStrings("pane", saved.label);
    try std.testing.expectEqualStrings("slot", saved.anchor.?);
    try std.testing.expectEqualStrings("zero://app", saved.url);
    try std.testing.expectEqual(@import("geometry").RectF.init(-2.125, 4.5, 100.25, 48.5), saved.frame);
    try std.testing.expectEqual(@as(u64, 9007199254740991), saved.reload_token);
    try std.testing.expectEqual(@as(usize, 1), Adapter.webPanesAdapter(&model, panes[0..1]));
    WebPanesAdapterTestCore.panes[0].anchor = null;
    defer WebPanesAdapterTestCore.panes[0].anchor = &WebPanesAdapterTestCore.anchor;
    _ = Adapter.webPanesAdapter(&model, &panes);
    try std.testing.expect(panes[0].anchor == null);
}

test "TypeScript pane boundary rejects invalid coordinates dimensions and reload tokens" {
    const Adapter = TsUiApp(WebPanesAdapterTestCore);
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 3.5e38 }) |value|
        try std.testing.expectError(error.InvalidWebPane, Adapter.paneCoordinate(value));
    try std.testing.expectError(error.InvalidWebPane, Adapter.paneDimension(@as(f64, -0.25)));
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -1, 0.125, 9007199254740992 }) |value|
        try std.testing.expectError(error.InvalidWebPane, Adapter.paneReloadToken(value));
    try std.testing.expectEqual(@as(f32, 0), try Adapter.paneDimension(@as(f64, 0)));
}

test "web pane exact decimal reload tokens retain every u64 and refuse alternate spellings" {
    const Adapter = TsUiApp(WebPanesAdapterTestCore);
    try std.testing.expectEqual(@as(u64, 0), try Adapter.paneReloadToken(@as([]const u8, "0")));
    try std.testing.expectEqual(@as(u64, 9007199254740992), try Adapter.paneReloadToken(@as([]const u8, "9007199254740992")));
    try std.testing.expectEqual(std.math.maxInt(u64), try Adapter.paneReloadToken(@as([]const u8, "18446744073709551615")));
    for ([_][]const u8{ "", "+1", "-0", "1.0", "1e2", " 1", "1\x00", "18446744073709551616", "123456789012345678901" }) |text|
        try std.testing.expectError(error.InvalidWebPane, Adapter.paneReloadToken(text));
}
