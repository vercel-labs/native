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
//! `commandMsg`, `tokens_fn`/`windows_fn`/`status_item_fn` derive from
//! the committed model. One model-helper convention joins that wiring:
//! an exported `themePack(model): "house" | "geist"` helper selects the
//! stock pack live through `theme_fn`, without taking ownership of the
//! system appearance axes. An exported
//! `statusItem(model): StatusItemState` helper similarly owns the complete
//! menu-bar item through `status_item_fn`: install-time icon/tooltip/click
//! hooks plus the live presentation and menu. In hand wiring, empty
//! install-time fields inherit the static `status_item` options. The two
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

const std = @import("std");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");
const runtime_core = @import("core.zig");
const runtime_effects = @import("effects.zig");
const persist_store = @import("persist_store.zig");
const ui_app = @import("ui_app.zig");
const ts_core_host = @import("ts_core_host.zig");

pub fn TsUiApp(comptime core: type) type {
    return struct {
        /// The effect bridge — shared with any direct `TsCoreHost(core)`
        /// instantiation (comptime memoization), so harnesses can read
        /// `Host.model()` and tests can name the bridge's key bases.
        pub const Host = ts_core_host.TsCoreHost(core);
        pub const Model = core.Model;
        pub const Msg = core.Msg;
        pub const App = ui_app.UiApp(Model, Msg);
        pub const Options = App.Options;
        pub const Effects = App.Effects;
        pub const Ui = App.Ui;

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

            fn persistenceName(name: []const u8) bool {
                return std.mem.eql(u8, name, "core.persist") or std.mem.eql(u8, name, "core.persist.flush");
            }

            fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                const target = if (persistenceName(name)) self.persist else self.primary;
                target.send_fn(target.context, name, payload);
            }

            fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                const target = if (persistenceName(name)) self.persist else self.primary;
                target.request_fn(target.context, name, key, payload);
            }

            fn cancel(context: *anyopaque, key: u64) void {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                if (self.primary.cancel_fn) |cancel_fn| cancel_fn(self.primary.context, key);
            }

            fn poll(context: *anyopaque) ?runtime_effects.HostCallCompletion {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                const poll_fn = self.primary.poll_fn orelse return null;
                return poll_fn(self.primary.context);
            }

            fn pending(context: *anyopaque) bool {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                const pending_fn = self.primary.pending_fn orelse return false;
                return pending_fn(self.primary.context);
            }

            fn bindServices(context: *anyopaque, services: *const platform.PlatformServices) void {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                if (self.primary.bind_services_fn) |bind_fn| bind_fn(self.primary.context, services);
                if (self.persist.bind_services_fn) |bind_fn| bind_fn(self.persist.context, services);
            }

            fn bindChannels(context: *anyopaque, channels: runtime_effects.HostChannelBinding) void {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                if (self.primary.bind_channels_fn) |bind_fn| bind_fn(self.primary.context, channels);
                if (self.persist.bind_channels_fn) |bind_fn| bind_fn(self.persist.context, channels);
            }

            fn shutdown(context: *anyopaque) void {
                const self: *HostCallMux = @ptrCast(@alignCast(context));
                if (self.primary.shutdown_fn) |shutdown_fn| shutdown_fn(self.primary.context);
                if (self.persist.shutdown_fn) |shutdown_fn| shutdown_fn(self.persist.context);
            }
        };

        /// Build-time manifest/wire fence for the three persistence routes.
        /// The generated runner calls this with app.zon's comptime strings so
        /// a typo or payload mismatch fails during `native build`, before a
        /// first boot can reach the dynamic dispatch path below.
        pub fn validatePersistRoutes(comptime routes: PersistRoutes) void {
            validatePersistRoute(routes.ok, void, "ok");
            validatePersistRoute(routes.none, void, "none");
            validatePersistRoute(routes.err, []const u8, "err");
        }

        fn validatePersistRoute(comptime route: []const u8, comptime Payload: type, comptime role: []const u8) void {
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
            lifecycle_store = stamped.on_lifecycle;
            lifecycle_flush_after_update = false;
            stamped.on_lifecycle = lifecycleAdapter;
            stamped.init_fx = initFx;
            stamped.update_fx = updateFx;
            // A TypeScript core can select a built-in pack from ordinary
            // model state without ejecting the generated launcher. The
            // exported single-model helper emits as a Model method, so it
            // is equally visible on direct compiler output and the
            // external-core mirror. The app owns only the pack; UiApp's
            // stock-token path keeps following the OS appearance.
            if (comptime @hasDecl(Model, "themePack")) {
                if (options.theme_fn != null) {
                    @panic("TsUiApp wires theme_fn from the core's themePack helper - remove the wiring's theme_fn");
                }
                comptime validateThemePackHelper();
                stamped.theme_fn = themePackAdapter;
            }
            // A statusItem helper is the TS app's model-derived shell
            // declaration. UiApp installs it on the first frame and
            // independently patches presentation/menu after each
            // committed rebuild; empty install fields inherit custom
            // static status_item options in hand wiring.
            if (comptime @hasDecl(Model, "statusItem")) {
                if (options.status_item_fn != null) {
                    @panic("TsUiApp wires status_item_fn from the core's statusItem helper - remove the wiring's status_item_fn");
                }
                comptime validateStatusItemHelper();
                stamped.status_item_fn = statusItemAdapter;
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
                scratch.items[index] = .{
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
            }
            return statusItemState(state, scratch.items[0..state.items.len]);
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
            if (presentation_info.fields.len != 5 or !@hasField(Presentation, "title") or !@hasField(Presentation, "width") or
                !@hasField(Presentation, "tone") or !@hasField(Presentation, "iconOpacity") or !@hasField(Presentation, "monospaced"))
            {
                @compileError(teaching);
            }
            if (@FieldType(Presentation, "title") != []const u8 or !statusItemNumericType(@FieldType(Presentation, "width")) or
                !statusItemEnumType(@FieldType(Presentation, "tone"), &.{ "normal", "warning", "critical" }) or
                !statusItemNumericType(@FieldType(Presentation, "iconOpacity")) or @FieldType(Presentation, "monospaced") != bool)
            {
                @compileError(teaching);
            }
            const items_info = @typeInfo(@FieldType(State, "items"));
            if (items_info != .pointer or items_info.pointer.size != .slice or !items_info.pointer.is_const) @compileError(teaching);
            const Item = statusItemRecordType(items_info.pointer.child, teaching);
            const item_info = @typeInfo(Item).@"struct";
            if (item_info.fields.len != 9 or !@hasField(Item, "id") or !@hasField(Item, "label") or
                !@hasField(Item, "command") or !@hasField(Item, "separator") or !@hasField(Item, "enabled") or
                !@hasField(Item, "detail") or !@hasField(Item, "role") or !@hasField(Item, "key") or !@hasField(Item, "modifiers"))
            {
                @compileError(teaching);
            }
            if (!statusItemNumericType(@FieldType(Item, "id"))) @compileError(teaching);
            if (@FieldType(Item, "label") != []const u8 or @FieldType(Item, "command") != []const u8 or
                @FieldType(Item, "separator") != bool or @FieldType(Item, "enabled") != bool or
                @FieldType(Item, "detail") != []const u8 or
                !statusItemEnumType(@FieldType(Item, "role"), &.{ "command", "info", "header", "hero", "agent", "context" }) or
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

        /// Resolve the boot snapshot entirely at the effect boundary. Live
        /// launches journal the runner-provided result; replay consumes the
        /// recorded result and never consults the current app-data directory.
        fn preparePersistRestore(fx: *Effects) ?persist_store.Outcome {
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

        fn dispatchPersistOutcome(fx: *Effects, outcome: persist_store.Outcome) void {
            const routes = persist_options_store.?.routes;
            switch (outcome) {
                .ok => dispatchPersistVoid(fx, routes.ok),
                .none => dispatchPersistVoid(fx, routes.none),
                .corrupt, .version_unknown, .migrate_failed, .io_failed, .rejected => dispatchPersistError(fx, routes.err, @tagName(outcome)),
            }
        }

        fn persistOutcomeMsg(event: runtime_effects.EffectChannelEvent) Msg {
            const reason: []const u8 = switch (event.kind) {
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

        fn dispatchPersistVoid(fx: *Effects, route: []const u8) void {
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
            if (lifecycle_flush_after_update) {
                lifecycle_flush_after_update = false;
                flushPersistence();
            }
        }
    };
}
