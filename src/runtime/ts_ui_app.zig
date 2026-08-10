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
//! system appearance axes. The two seams the core owns — `update_fx` and
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

        fn applyCoreOptions(core_options: CoreOptions) void {
            Host.setAudioCacheDir(core_options.audio_cache_dir);
            Host.setImageCacheDir(core_options.image_cache_dir);
            boot_images_store = core_options.boot_images;
            env_values_store = core_options.env_values;
            if (core_options.env_values.len > 0 and comptime !@hasDecl(core, "envMsgs")) {
                @panic("TsUiApp received env_values but the core exports no envMsgs channel - declare `export const envMsgs = [{ env: \"NAME\", msg: \"<arm>\" }] as const` in core.ts");
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

        /// `Options.init_fx`: register the wiring's boot images, perform
        /// the boot command and initial subscriptions on the installing
        /// frame (the boot model itself committed in `init`), dispatch
        /// the launch environment overrides as ordinary journaled Msgs,
        /// then refresh the app-held root.
        fn initFx(model: *Model, fx: *Effects) void {
            for (boot_images_store) |image| {
                // Registration is synchronous; a failed decode leaves the
                // views on their fallback (avatar initials) — a bad asset
                // never breaks presentation (the Zig apps' convention).
                _ = fx.registerImageBytes(image.id, image.bytes) catch continue;
            }
            Host.performBoot(fx);
            dispatchEnvValues(fx);
            model.* = Host.model().*;
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
        }
    };
}
