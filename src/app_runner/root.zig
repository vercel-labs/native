const std = @import("std");
const build_options = @import("build_options");
const native_sdk = @import("native_sdk");
const app_manifest = @import("app_manifest_zon");
const manifest_shortcuts = if (@hasField(@TypeOf(app_manifest), "shortcuts")) app_manifest.shortcuts else .{};
const manifest_windows = if (@hasField(@TypeOf(app_manifest), "windows")) app_manifest.windows else .{};

pub const StdoutTraceSink = struct {
    pub fn sink(self: *StdoutTraceSink) native_sdk.trace.Sink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, record: native_sdk.trace.Record) native_sdk.trace.WriteError!void {
        _ = context;
        // Never fail on an oversized record: a trace-formatting failure
        // inside dispatch must degrade (truncated output), not become an
        // error the platform callback treats as fatal.
        var buffer: [4096]u8 = undefined;
        std.debug.print("{s}\n", .{native_sdk.trace.formatTextBounded(record, &buffer)});
    }
};

pub const FilteredTraceSink = struct {
    child: native_sdk.trace.Sink,

    pub fn sink(self: *FilteredTraceSink) native_sdk.trace.Sink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, record: native_sdk.trace.Record) native_sdk.trace.WriteError!void {
        const self: *FilteredTraceSink = @ptrCast(@alignCast(context));
        if (!shouldTrace(record)) return;
        try self.child.write(record);
    }
};

pub const RunOptions = struct {
    app_name: []const u8,
    window_title: []const u8 = "",
    bundle_id: []const u8,
    // Dev-run Dock icon file. The scaffold's one-image contract puts a
    // square PNG here; a prebuilt .icns path works too. When no file
    // exists at this path, unbundled macOS runs render the toolkit's
    // embedded default icon — the same fallback `native package` ships —
    // so apps without a custom icon carry no committed copy to go stale.
    icon_path: []const u8 = "assets/icon.png",
    default_frame: native_sdk.geometry.RectF = native_sdk.geometry.RectF.init(0, 0, 1100, 760),
    restore_state: bool = true,
    bridge: ?native_sdk.BridgeDispatcher = null,
    builtin_bridge: native_sdk.BridgePolicy = .{},
    js_window_api: bool = false,
    security: native_sdk.SecurityPolicy = .{},
    menus: []const native_sdk.Menu = &.{},
    shortcuts: ?[]const native_sdk.Shortcut = null,

    fn appInfo(self: RunOptions, buffers: *StateBuffers) native_sdk.AppInfo {
        var info: native_sdk.AppInfo = .{
            .app_name = self.app_name,
            // The identity the OS shows (application menu, Dock, About
            // panel) reads straight from app.zon at comptime, so dev
            // runs carry the same display name and version a packaged
            // bundle gets from its Info.plist.
            .display_name = manifestStringField("display_name"),
            .version = manifestStringField("version"),
            .description = manifestStringField("description"),
            .has_web_content = manifestHasWebContent(),
            .declares_tray = manifestDeclaresTrayCapability(),
            .window_title = self.window_title,
            .bundle_id = self.bundle_id,
            .icon_path = self.icon_path,
            .main_window = .{
                .id = 1,
                .label = "main",
                .title = self.window_title,
                .default_frame = self.default_frame,
                .restore_state = self.restore_state,
            },
        };
        const windows = manifestWindowOptions(buffers);
        if (windows.len > 0) {
            info.main_window = windows[0];
            info.windows = windows;
        } else {
            // Scene-first apps declare their one window under
            // `.shell.windows` — the startup window the host creates
            // adopts that declaration when the scene loads, but its
            // CHROME is fixed at create time, so the manifest's
            // titlebar style threads through here. Same for visibility:
            // a canvas-first startup window is created ordered-out and
            // shown after its first canvas frame presents, so launch
            // never flashes a blank window.
            info.main_window.titlebar = manifestShellStartupTitlebar();
            info.main_window.resizable = manifestShellStartupResizable();
            info.main_window.show = manifestShellStartupShowMode();
            // Min-size floors ride the create call like the titlebar:
            // the scene re-applies size/title later, but the window's
            // enforced floor is host state from the first frame on.
            info.main_window.min_width = manifestShellStartupMinSize("min_width");
            info.main_window.min_height = manifestShellStartupMinSize("min_height");
            // Close handling is host window state like the titlebar:
            // the manifest's declaration rides the host create.
            info.main_window.close_policy = manifestShellStartupClosePolicy();
        }
        return info;
    }

    fn resolvedShortcuts(self: RunOptions, storage: *ShortcutStorage) []const native_sdk.Shortcut {
        return self.shortcuts orelse storage.fromManifest();
    }
};

const ShortcutStorage = struct {
    shortcuts: [native_sdk.platform.max_shortcuts]native_sdk.Shortcut = undefined,

    fn fromManifest(self: *ShortcutStorage) []const native_sdk.Shortcut {
        comptime {
            if (manifest_shortcuts.len > native_sdk.platform.max_shortcuts) {
                @compileError("app.zon defines too many shortcuts");
            }
        }

        inline for (manifest_shortcuts, 0..) |shortcut, index| {
            self.shortcuts[index] = .{
                .id = shortcut.id,
                .key = shortcut.key,
                .modifiers = shortcutModifiers(shortcut),
            };
        }
        return self.shortcuts[0..manifest_shortcuts.len];
    }
};

fn manifestWindowOptions(buffers: *StateBuffers) []const native_sdk.WindowOptions {
    comptime {
        if (manifest_windows.len > native_sdk.platform.max_windows) {
            @compileError("app.zon defines too many windows");
        }
    }

    inline for (manifest_windows, 0..) |window, index| {
        buffers.restored_windows[index] = manifestWindow(window, index);
    }
    return buffers.restored_windows[0..manifest_windows.len];
}

fn manifestWindow(comptime window: anytype, comptime index: usize) native_sdk.WindowOptions {
    return .{
        .id = index + 1,
        .label = windowLabel(window, index),
        .title = windowTitle(window),
        .default_frame = native_sdk.geometry.RectF.init(
            windowFloat(window, "x", 0),
            windowFloat(window, "y", 0),
            windowFloat(window, "width", 720),
            windowFloat(window, "height", 480),
        ),
        .resizable = windowBool(window, "resizable", true),
        .restore_state = windowBool(window, "restore_state", true),
        .restore_policy = windowRestorePolicy(window),
        .titlebar = windowTitlebarStyle(window),
        .min_width = windowMinSize(window, "min_width"),
        .min_height = windowMinSize(window, "min_height"),
        .close_policy = windowClosePolicy(window),
    };
}

/// Window-enforced content min-size floor from app.zon. Validated at
/// comptime like the titlebar style: a negative floor is an authoring
/// error, not a silent clamp.
fn windowMinSize(comptime window: anytype, comptime field: []const u8) f32 {
    const value: f32 = comptime windowFloat(window, field, 0);
    comptime {
        if (!(value >= 0)) @compileError("app.zon window " ++ field ++ " must be non-negative");
    }
    return value;
}

fn windowTitlebarStyle(comptime window: anytype) native_sdk.WindowTitlebarStyle {
    if (comptime !@hasField(@TypeOf(window), "titlebar")) return .standard;
    const value = window.titlebar;
    if (comptime std.mem.eql(u8, value, "standard")) return .standard;
    if (comptime std.mem.eql(u8, value, "hidden_inset")) return .hidden_inset;
    if (comptime std.mem.eql(u8, value, "hidden_inset_tall")) return .hidden_inset_tall;
    if (comptime std.mem.eql(u8, value, "chromeless")) return .chromeless;
    @compileError("unknown app.zon window titlebar style");
}

/// The startup window's titlebar style for scene-first apps: app.zon's
/// `.shell.windows[0].titlebar`. Chrome cannot change after the host
/// creates the window, so it must ride the create call — unlike
/// size/title, which the loading scene re-applies.
fn manifestShellStartupTitlebar() native_sdk.WindowTitlebarStyle {
    if (comptime !@hasField(@TypeOf(app_manifest), "shell")) return .standard;
    const shell = app_manifest.shell;
    if (comptime !@hasField(@TypeOf(shell), "windows")) return .standard;
    if (comptime shell.windows.len == 0) return .standard;
    return windowTitlebarStyle(shell.windows[0]);
}

/// The startup window's resizability for scene-first apps: like the
/// titlebar style, resizable is window chrome fixed at create time.
fn manifestShellStartupResizable() bool {
    if (comptime !@hasField(@TypeOf(app_manifest), "shell")) return true;
    const shell = app_manifest.shell;
    if (comptime !@hasField(@TypeOf(shell), "windows")) return true;
    if (comptime shell.windows.len == 0) return true;
    return windowBool(shell.windows[0], "resizable", true);
}

/// The startup window's close policy for scene-first apps: app.zon's
/// `.shell.windows[0].close_policy`. Like the titlebar, close handling
/// is host window state fixed at create time.
fn manifestShellStartupClosePolicy() native_sdk.WindowClosePolicy {
    if (comptime !@hasField(@TypeOf(app_manifest), "shell")) return .quit;
    const shell = app_manifest.shell;
    if (comptime !@hasField(@TypeOf(shell), "windows")) return .quit;
    if (comptime shell.windows.len == 0) return .quit;
    return windowClosePolicy(shell.windows[0]);
}

/// The startup window's content min-size floor for scene-first apps:
/// app.zon's `.shell.windows[0].min_width`/`.min_height` (0 = none).
fn manifestShellStartupMinSize(comptime field: []const u8) f32 {
    if (comptime !@hasField(@TypeOf(app_manifest), "shell")) return 0;
    const shell = app_manifest.shell;
    if (comptime !@hasField(@TypeOf(shell), "windows")) return 0;
    if (comptime shell.windows.len == 0) return 0;
    return windowMinSize(shell.windows[0], field);
}

/// Present-before-show for the STARTUP window: when app.zon's first
/// shell window hosts a canvas (`gpu_surface` view), the host creates
/// it ordered-out and it becomes visible after the first canvas frame
/// presents. Webview-first startup windows keep immediate visibility.
fn manifestShellStartupShowMode() native_sdk.WindowShowMode {
    if (comptime !@hasField(@TypeOf(app_manifest), "shell")) return .immediate;
    const shell = app_manifest.shell;
    if (comptime !@hasField(@TypeOf(shell), "windows")) return .immediate;
    if (comptime shell.windows.len == 0) return .immediate;
    const window = shell.windows[0];
    if (comptime !@hasField(@TypeOf(window), "views")) return .immediate;
    inline for (window.views) |view| {
        if (comptime @hasField(@TypeOf(view), "kind")) {
            if (comptime std.mem.eql(u8, view.kind, "gpu_surface")) return .on_first_present;
        }
    }
    return .immediate;
}

/// A top-level app.zon string field (`display_name`, `version`,
/// `description`), or "" when the manifest omits it — optional identity
/// stays optional all the way into `AppInfo`.
fn manifestStringField(comptime field: []const u8) []const u8 {
    if (comptime !@hasField(@TypeOf(app_manifest), field)) return "";
    const value = @field(app_manifest, field);
    if (comptime @TypeOf(value) == @TypeOf(null)) return "";
    return value;
}

/// The theme pack app.zon selects (`theme = "geist"`), resolved at
/// comptime so an unknown name is a build error naming the field and
/// the valid packs — never a silent fallback. Absent means the house
/// register. Apps hand this to their `UiApp` options' `theme` field;
/// the pack then composes with the live system appearance, so packed
/// apps still re-theme on the OS light/dark flip.
pub fn manifestThemePack() native_sdk.canvas.ThemePack {
    if (comptime !@hasField(@TypeOf(app_manifest), "theme")) return .house;
    const name: []const u8 = app_manifest.theme;
    return comptime native_sdk.canvas.ThemePack.fromName(name) orelse
        @compileError("unknown app.zon theme \"" ++ name ++ "\" — expected one of: house, geist");
}

/// The manifest's ONE-accent brand override (`theme_accent = "#df2670"`),
/// resolved at comptime so a malformed value is a build error naming the
/// field — never a silent fallback. Absent means the pack's own accent.
/// Apps hand this to their `UiApp` options' `theme_accent` field; the
/// runtime layers `canvas.accentOverrides` over the resolved pack (and
/// skips it under high contrast — accessibility beats brand).
pub fn manifestThemeAccent() ?native_sdk.canvas.Color {
    if (comptime !@hasField(@TypeOf(app_manifest), "theme_accent")) return null;
    const value: []const u8 = app_manifest.theme_accent;
    return comptime parseHexColor(value) orelse
        @compileError("invalid app.zon theme_accent \"" ++ value ++ "\" — expected a #rrggbb hex color");
}

fn parseHexColor(comptime value: []const u8) ?native_sdk.canvas.Color {
    comptime {
        if (value.len != 7 or value[0] != '#') return null;
        var channels: [3]u8 = undefined;
        for (&channels, 0..) |*channel, index| {
            channel.* = std.fmt.parseInt(u8, value[1 + index * 2 .. 3 + index * 2], 16) catch return null;
        }
        return native_sdk.canvas.Color.rgb8(channels[0], channels[1], channels[2]);
    }
}

/// Whether app.zon declares web content — the shared declare-to-use
/// contract (`native_sdk.app_manifest.web_layer`) over the comptime
/// manifest import: a `.frontend` block, the `"webview"` capability, a
/// `.shell` webview view, or `.web_engine = "chromium"`. Hosts build
/// honest default menus from this — web items like Reload only exist
/// when a webview can answer them, so canvas-only apps never ship dead
/// menu items.
fn manifestHasWebContent() bool {
    return manifestWebDeclaration() != null;
}

/// The first web declaration visible in app.zon, evaluated at comptime.
/// The engine input here is the MANIFEST engine: the runner never sees
/// the `-Dweb-engine` flag, so an engine resolved to Chromium by flag
/// alone is out of this boundary's reach — the standard build graph
/// (build/app.zig), which does see the flag, owns that configure-time
/// error. See the contract's module doc for the full ownership split.
fn manifestWebDeclaration() ?native_sdk.app_manifest.web_layer.Declaration {
    const engine: native_sdk.app_manifest.WebEngine = comptime blk: {
        if (!@hasField(@TypeOf(app_manifest), "web_engine")) break :blk .system;
        break :blk native_sdk.app_manifest.web_layer.parseWebEngine(app_manifest.web_engine) orelse .system;
    };
    return comptime native_sdk.app_manifest.web_layer.webDeclaration(app_manifest, engine);
}

/// Whether this build ships the embedded web layer. The standard build
/// graph (build/app.zig) infers it from app.zon and passes it through
/// build options; an options module from an older hand-rolled build.zig
/// that predates the option keeps the layer — over-inclusion is safe.
fn webLayerEnabled() bool {
    if (comptime !@hasDecl(build_options, "web_layer")) return true;
    return build_options.web_layer;
}

// The runner-side half of the reject-conflicts contract: a build that
// excludes the web layer while app.zon declares web use must fail at
// compile time here too, so a hand-rolled build graph that bypasses the
// standard configure-time error still cannot ship an app whose declared
// webviews would fail at runtime. The guard covers every declaration
// visible in the manifest; only a Chromium engine resolved from the
// `-Dweb-engine` flag is invisible here, and that conflict is already a
// configure-time error in the graph that resolved the flag.
comptime {
    if (!webLayerEnabled()) {
        if (manifestWebDeclaration()) |declaration| {
            @compileError("this build excludes the web layer (-Dweb-layer=exclude or a custom build graph) but app.zon declares web use (" ++ declaration.text() ++ "); remove the exclude or drop the web declaration");
        }
    }
}

fn windowLabel(comptime window: anytype, comptime index: usize) []const u8 {
    if (comptime @hasField(@TypeOf(window), "label")) return window.label;
    return if (index == 0) "main" else "window";
}

fn windowTitle(comptime window: anytype) []const u8 {
    if (comptime !@hasField(@TypeOf(window), "title")) return "";
    const title = window.title;
    if (comptime @TypeOf(title) == @TypeOf(null)) return "";
    return title;
}

fn windowFloat(comptime window: anytype, comptime field: []const u8, comptime default_value: f32) f32 {
    if (comptime @hasField(@TypeOf(window), field)) return @field(window, field);
    return default_value;
}

fn windowBool(comptime window: anytype, comptime field: []const u8, comptime default_value: bool) bool {
    if (comptime @hasField(@TypeOf(window), field)) return @field(window, field);
    return default_value;
}

fn windowRestorePolicy(comptime window: anytype) native_sdk.WindowRestorePolicy {
    if (comptime !@hasField(@TypeOf(window), "restore_policy")) return .clamp_to_visible_screen;
    const value = window.restore_policy;
    if (comptime std.mem.eql(u8, value, "clamp_to_visible_screen")) return .clamp_to_visible_screen;
    if (comptime std.mem.eql(u8, value, "center_on_primary")) return .center_on_primary;
    @compileError("unknown app.zon window restore_policy");
}

/// What the window's close affordance does, from app.zon. `.hide` is
/// validated against the TARGET platform at comptime: a host with no
/// affordance to bring a hidden window back (GTK has no status item;
/// windows without a declared tray, since hiding removes the taskbar
/// entry and windows has no dock) refuses the declaration here, at
/// build time, instead of stranding a hidden window at runtime.
fn windowClosePolicy(comptime window: anytype) native_sdk.WindowClosePolicy {
    if (comptime !@hasField(@TypeOf(window), "close_policy")) return .quit;
    const value = window.close_policy;
    if (comptime std.mem.eql(u8, value, "quit")) return .quit;
    if (comptime std.mem.eql(u8, value, "hide")) {
        if (comptime std.mem.eql(u8, build_options.platform, "linux")) {
            @compileError("app.zon window close_policy \"hide\" is not supported on linux: the GTK host has no status item (tray), so nothing could bring the hidden window back - declare \"quit\" (the default), or scope the .hide declaration to macos/windows builds");
        }
        if (comptime std.mem.eql(u8, build_options.platform, "windows")) {
            if (comptime !manifestDeclaresTrayCapability()) {
                @compileError("app.zon window close_policy \"hide\" on windows requires the \"tray\" capability: hiding removes the taskbar entry and windows has no dock-reopen path, so only a status item (tray) could bring the hidden window back - add \"tray\" to .capabilities and install a status item, or declare \"quit\" (the default); macos needs no capability because the dock reopen path always exists");
            }
        }
        return .hide;
    }
    @compileError("unknown app.zon window close_policy - supported values: \"quit\" (close really closes; the default) and \"hide\" (the menu-bar-app shape: close hides the window and the app keeps running)");
}

/// Whether app.zon declares the "tray" capability — the status item
/// `.hide` leans on where the OS has no built-in re-show affordance.
/// Evaluated at comptime over the manifest import, like the web scan.
fn manifestDeclaresTrayCapability() bool {
    if (comptime !@hasField(@TypeOf(app_manifest), "capabilities")) return false;
    inline for (app_manifest.capabilities) |capability| {
        const name: []const u8 = capability;
        if (comptime std.mem.eql(u8, name, "tray")) return true;
    }
    return false;
}

fn shortcutModifiers(comptime shortcut: anytype) native_sdk.ShortcutModifiers {
    const values = if (@hasField(@TypeOf(shortcut), "modifiers")) shortcut.modifiers else .{};
    var modifiers: native_sdk.ShortcutModifiers = .{};
    inline for (values) |value| {
        const modifier: []const u8 = value;
        if (comptime std.mem.eql(u8, modifier, "primary")) {
            modifiers.primary = true;
        } else if (comptime std.mem.eql(u8, modifier, "command")) {
            modifiers.command = true;
        } else if (comptime std.mem.eql(u8, modifier, "control")) {
            modifiers.control = true;
        } else if (comptime std.mem.eql(u8, modifier, "option") or std.mem.eql(u8, modifier, "alt")) {
            modifiers.option = true;
        } else if (comptime std.mem.eql(u8, modifier, "shift")) {
            modifiers.shift = true;
        } else {
            @compileError("unknown app.zon shortcut modifier");
        }
    }
    return modifiers;
}

pub fn runWithOptions(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    if (build_options.debug_overlay) {
        std.debug.print("debug-overlay=true backend={s} web-engine={s} trace={s}\n", .{ build_options.platform, build_options.web_engine, build_options.trace });
    }
    // Session replay never opens a real platform: the journal is the
    // world, and it drives a headless runtime over the null platform.
    if (init.environ_map.get("NATIVE_SDK_SESSION_REPLAY")) |journal_path| {
        return runSessionReplay(app, options, init, journal_path);
    }
    if (comptime std.mem.eql(u8, build_options.platform, "macos")) {
        try runMacos(app, options, init);
    } else if (comptime std.mem.eql(u8, build_options.platform, "linux")) {
        try runLinux(app, options, init);
    } else if (comptime std.mem.eql(u8, build_options.platform, "windows")) {
        try runWindows(app, options, init);
    } else {
        try runNull(app, options, init);
    }
}

fn runNull(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    var app_info = options.appInfo(&buffers);
    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    const session_recorder = setupSessionRecorder(init, app_info);
    // Heap wrapper, latch-gated free: worker threads hold this address
    // as the channel wake context and an abandoned wake call may
    // dereference it after this frame unwinds (see
    // `NullPlatform.createWithOptions`/`destroy`).
    const null_platform = try native_sdk.NullPlatform.createWithOptions(.{}, webEngine(), app_info);
    defer null_platform.destroy();
    var trace_sink = StdoutTraceSink{};
    var log_buffers: native_sdk.debug.LogPathBuffers = .{};
    const log_setup = native_sdk.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    if (log_setup) |setup| native_sdk.debug.installPanicCapture(init.io, setup.paths);
    var file_trace_sink: native_sdk.debug.FileTraceSink = undefined;
    var fanout_sinks: [2]native_sdk.trace.Sink = undefined;
    var fanout_sink: native_sdk.debug.FanoutTraceSink = undefined;
    var runtime_trace_sink = trace_sink.sink();
    if (log_setup) |setup| {
        file_trace_sink = native_sdk.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
        fanout_sink = .{ .sinks = &fanout_sinks };
        runtime_trace_sink = fanout_sink.sink();
    }
    var filtered_trace_sink: FilteredTraceSink = .{ .child = runtime_trace_sink };
    runtime_trace_sink = filtered_trace_sink.sink();
    var shortcut_storage: ShortcutStorage = .{};
    const shortcuts = options.resolvedShortcuts(&shortcut_storage);
    // The Runtime is multi-megabyte; Linux's default 8 MB main-thread
    // stack overflows on a stack instance, so construct it on the heap.
    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    // Fonts registered at startup and media-surface texture buffers
    // adopted during the run are heap-owned by the runtime; return them
    // (and disarm the producer wake bindings) before the runtime
    // storage itself goes.
    defer runtime.deinit();
    native_sdk.Runtime.initAt(runtime, .{
        .platform = null_platform.platform(),
        .trace_sink = runtime_trace_sink,
        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .js_window_api = options.js_window_api,
        .web_layer = webLayerEnabled(),
        .gpu_surface_frame_diagnostics = false,
        .security = options.security,
        .menus = options.menus,
        .shortcuts = shortcuts,
        .automation = if (build_options.automation) native_sdk.automation.Server.init(init.io, ".zig-cache/native-sdk-automation", app_info.resolvedWindowTitle()) else null,
        .window_state_store = store,
        .environ = init.minimal.environ,
        .session_recorder = session_recorder,
    });

    try runtime.run(app);
    finishSessionRecorder(session_recorder);
}

fn runMacos(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    // Launch-to-glass laps (NATIVE_SDK_WINDOW_TIMING): runner entry is the
    // first in-process stamp — spawn-to-here is exec + dyld + zig init.
    native_sdk.runtime.launch_timing.lap("runner_main");
    var buffers: StateBuffers = undefined;
    var app_info = options.appInfo(&buffers);
    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    const session_recorder = setupSessionRecorder(init, app_info);
    // Heap wrapper, latch-gated free: worker threads hold this address
    // as the channel wake context and an abandoned wake call may
    // dereference it after this frame unwinds (see
    // `MacPlatform.createWithOptions`/`destroy`).
    const mac_platform = try native_sdk.platform.macos.MacPlatform.createWithOptions(native_sdk.geometry.SizeF.init(720, 480), webEngine(), app_info);
    defer mac_platform.destroy();
    native_sdk.runtime.launch_timing.lap("host_ready");
    var trace_sink = StdoutTraceSink{};
    var log_buffers: native_sdk.debug.LogPathBuffers = .{};
    const log_setup = native_sdk.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    if (log_setup) |setup| native_sdk.debug.installPanicCapture(init.io, setup.paths);
    var file_trace_sink: native_sdk.debug.FileTraceSink = undefined;
    var fanout_sinks: [2]native_sdk.trace.Sink = undefined;
    var fanout_sink: native_sdk.debug.FanoutTraceSink = undefined;
    var runtime_trace_sink = trace_sink.sink();
    if (log_setup) |setup| {
        file_trace_sink = native_sdk.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
        fanout_sink = .{ .sinks = &fanout_sinks };
        runtime_trace_sink = fanout_sink.sink();
    }
    var filtered_trace_sink: FilteredTraceSink = .{ .child = runtime_trace_sink };
    runtime_trace_sink = filtered_trace_sink.sink();
    var shortcut_storage: ShortcutStorage = .{};
    const shortcuts = options.resolvedShortcuts(&shortcut_storage);
    // The Runtime is multi-megabyte; Linux's default 8 MB main-thread
    // stack overflows on a stack instance, so construct it on the heap.
    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    // Fonts registered at startup and media-surface texture buffers
    // adopted during the run are heap-owned by the runtime; return them
    // (and disarm the producer wake bindings) before the runtime
    // storage itself goes.
    defer runtime.deinit();
    native_sdk.Runtime.initAt(runtime, .{
        .platform = mac_platform.platform(),
        .trace_sink = runtime_trace_sink,
        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .js_window_api = options.js_window_api,
        .web_layer = webLayerEnabled(),
        .gpu_surface_frame_diagnostics = false,
        .security = options.security,
        .menus = options.menus,
        .shortcuts = shortcuts,
        .automation = if (build_options.automation) native_sdk.automation.Server.init(init.io, ".zig-cache/native-sdk-automation", app_info.resolvedWindowTitle()) else null,
        .window_state_store = store,
        .environ = init.minimal.environ,
        .session_recorder = session_recorder,
    });
    native_sdk.runtime.launch_timing.lap("runtime_ready");

    try runtime.run(app);
    finishSessionRecorder(session_recorder);
}

fn runLinux(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    var app_info = options.appInfo(&buffers);
    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    const session_recorder = setupSessionRecorder(init, app_info);
    // Heap wrapper, latch-gated free: worker threads hold this address
    // as the channel wake context and an abandoned wake call may
    // dereference it after this frame unwinds (see
    // `LinuxPlatform.createWithOptions`/`destroy`).
    const linux_platform = try native_sdk.platform.linux.LinuxPlatform.createWithOptions(native_sdk.geometry.SizeF.init(720, 480), webEngine(), app_info);
    defer linux_platform.destroy();
    var trace_sink = StdoutTraceSink{};
    var log_buffers: native_sdk.debug.LogPathBuffers = .{};
    const log_setup = native_sdk.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    if (log_setup) |setup| native_sdk.debug.installPanicCapture(init.io, setup.paths);
    var file_trace_sink: native_sdk.debug.FileTraceSink = undefined;
    var fanout_sinks: [2]native_sdk.trace.Sink = undefined;
    var fanout_sink: native_sdk.debug.FanoutTraceSink = undefined;
    var runtime_trace_sink = trace_sink.sink();
    if (log_setup) |setup| {
        file_trace_sink = native_sdk.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
        fanout_sink = .{ .sinks = &fanout_sinks };
        runtime_trace_sink = fanout_sink.sink();
    }
    var filtered_trace_sink: FilteredTraceSink = .{ .child = runtime_trace_sink };
    runtime_trace_sink = filtered_trace_sink.sink();
    var shortcut_storage: ShortcutStorage = .{};
    const shortcuts = options.resolvedShortcuts(&shortcut_storage);
    // The Runtime is multi-megabyte; Linux's default 8 MB main-thread
    // stack overflows on a stack instance, so construct it on the heap.
    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    // Fonts registered at startup and media-surface texture buffers
    // adopted during the run are heap-owned by the runtime; return them
    // (and disarm the producer wake bindings) before the runtime
    // storage itself goes.
    defer runtime.deinit();
    native_sdk.Runtime.initAt(runtime, .{
        .platform = linux_platform.platform(),
        .trace_sink = runtime_trace_sink,
        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .js_window_api = options.js_window_api,
        .web_layer = webLayerEnabled(),
        .gpu_surface_frame_diagnostics = false,
        .security = options.security,
        .menus = options.menus,
        .shortcuts = shortcuts,
        .automation = if (build_options.automation) native_sdk.automation.Server.init(init.io, ".zig-cache/native-sdk-automation", app_info.resolvedWindowTitle()) else null,
        .window_state_store = store,
        .environ = init.minimal.environ,
        .session_recorder = session_recorder,
    });

    try runtime.run(app);
    finishSessionRecorder(session_recorder);
}

fn runWindows(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    var app_info = options.appInfo(&buffers);
    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    const session_recorder = setupSessionRecorder(init, app_info);
    // Heap wrapper, latch-gated free: worker threads hold this address
    // as the channel wake context and an abandoned wake call may
    // dereference it after this frame unwinds (see
    // `WindowsPlatform.createWithOptions`/`destroy`).
    const windows_platform = try native_sdk.platform.windows.WindowsPlatform.createWithOptions(native_sdk.geometry.SizeF.init(720, 480), webEngine(), app_info);
    defer windows_platform.destroy();
    var trace_sink = StdoutTraceSink{};
    var log_buffers: native_sdk.debug.LogPathBuffers = .{};
    const log_setup = native_sdk.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    if (log_setup) |setup| native_sdk.debug.installPanicCapture(init.io, setup.paths);
    var file_trace_sink: native_sdk.debug.FileTraceSink = undefined;
    var fanout_sinks: [2]native_sdk.trace.Sink = undefined;
    var fanout_sink: native_sdk.debug.FanoutTraceSink = undefined;
    var runtime_trace_sink = trace_sink.sink();
    if (log_setup) |setup| {
        file_trace_sink = native_sdk.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
        fanout_sink = .{ .sinks = &fanout_sinks };
        runtime_trace_sink = fanout_sink.sink();
    }
    var filtered_trace_sink: FilteredTraceSink = .{ .child = runtime_trace_sink };
    runtime_trace_sink = filtered_trace_sink.sink();
    var shortcut_storage: ShortcutStorage = .{};
    const shortcuts = options.resolvedShortcuts(&shortcut_storage);
    // The Runtime is multi-megabyte; Linux's default 8 MB main-thread
    // stack overflows on a stack instance, so construct it on the heap.
    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    // Fonts registered at startup and media-surface texture buffers
    // adopted during the run are heap-owned by the runtime; return them
    // (and disarm the producer wake bindings) before the runtime
    // storage itself goes.
    defer runtime.deinit();
    native_sdk.Runtime.initAt(runtime, .{
        .platform = windows_platform.platform(),
        .trace_sink = runtime_trace_sink,
        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .js_window_api = options.js_window_api,
        .web_layer = webLayerEnabled(),
        .gpu_surface_frame_diagnostics = false,
        .security = options.security,
        .menus = options.menus,
        .shortcuts = shortcuts,
        .automation = if (build_options.automation) native_sdk.automation.Server.init(init.io, ".zig-cache/native-sdk-automation", app_info.resolvedWindowTitle()) else null,
        .window_state_store = store,
        .environ = init.minimal.environ,
        .session_recorder = session_recorder,
    });

    try runtime.run(app);
    finishSessionRecorder(session_recorder);
}

// ------------------------------------------------- session record/replay

/// Positional file sink behind the session recorder. Process-lifetime:
/// allocated once at launch and never freed (the recorder outlives every
/// dispatch).
const SessionRecordContext = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,

    fn sink(self: *SessionRecordContext) native_sdk.runtime.SessionRecorderSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *SessionRecordContext = @ptrCast(@alignCast(context));
        try self.file.writePositionalAll(self.io, bytes, self.offset);
        self.offset += bytes.len;
    }
};

/// The blob directory beside a session journal: `blobs/` in the
/// journal's directory — large effect payloads (an image load's source
/// bytes) live there content-addressed, referenced from journal
/// records by hash + length (see session_blobs.zig).
fn sessionBlobStore(io: std.Io, journal_path: []const u8) ?*native_sdk.runtime.SessionBlobDirStore {
    var dir_buffer: [1024]u8 = undefined;
    const parent = std.fs.path.dirname(journal_path) orelse ".";
    const blob_dir = std.fmt.bufPrint(&dir_buffer, "{s}/blobs", .{parent}) catch return null;
    const store = std.heap.page_allocator.create(native_sdk.runtime.SessionBlobDirStore) catch return null;
    store.* = native_sdk.runtime.SessionBlobDirStore.init(io, blob_dir) catch {
        std.heap.page_allocator.destroy(store);
        return null;
    };
    return store;
}

/// `NATIVE_SDK_SESSION_RECORD=<path>`: create the journal file and a
/// recorder that streams the session into it from the very first
/// dispatched event (init determinism needs init-time effect results).
/// Failures disable recording loudly and never block the app.
fn setupSessionRecorder(init: std.process.Init, app_info: native_sdk.AppInfo) ?*native_sdk.runtime.SessionRecorder {
    const path = init.environ_map.get("NATIVE_SDK_SESSION_RECORD") orelse return null;
    const file = std.Io.Dir.cwd().createFile(init.io, path, .{ .truncate = true }) catch |err| {
        std.debug.print("session recording disabled: cannot create {s}: {s}\n", .{ path, @errorName(err) });
        return null;
    };
    const context = std.heap.page_allocator.create(SessionRecordContext) catch return null;
    context.* = .{ .io = init.io, .file = file };
    const recorder = std.heap.page_allocator.create(native_sdk.runtime.SessionRecorder) catch return null;
    recorder.* = native_sdk.runtime.SessionRecorder.init(context.sink());
    if (sessionBlobStore(init.io, path)) |store| recorder.blob_sink = store.sink();
    recorder.begin(native_sdk.runtime.sessionHeaderNow(
        native_sdk.runtime.sessionPlatformName(),
        app_info.app_name,
        app_info.main_window.default_frame.width,
        app_info.main_window.default_frame.height,
    ));
    std.debug.print("session recording to {s}\n", .{path});
    return recorder;
}

/// Seal the journal on clean exit. A crashed or killed app leaves no
/// end record, and replay refuses the file as truncated — honest by
/// construction.
fn finishSessionRecorder(recorder: ?*native_sdk.runtime.SessionRecorder) void {
    const active = recorder orelse return;
    active.finish();
    if (!active.failed) {
        std.debug.print("session journal sealed: {d} events, {d} effect results, {d} checkpoints, {d} screenshots, {d} bytes\n", .{
            active.event_count,
            active.effect_count,
            active.checkpoint_count,
            active.screenshot_count,
            active.bytes_written,
        });
    }
}

/// `NATIVE_SDK_SESSION_REPLAY=<path>`: replay the journal headlessly
/// (null platform — no windows, no timers, no effects; the journal is
/// the world), verify fingerprint and screenshot checkpoints unless
/// `NATIVE_SDK_SESSION_VERIFY=0`, print the report, and exit non-zero
/// on any mismatch.
fn runSessionReplay(app: native_sdk.App, options: RunOptions, init: std.process.Init, journal_path: []const u8) !void {
    const journal_bytes = readSessionJournal(init.io, journal_path) catch |err| {
        std.debug.print("session replay: cannot read {s}: {s}\n", .{ journal_path, @errorName(err) });
        return err;
    };

    var buffers: StateBuffers = undefined;
    const app_info = options.appInfo(&buffers);
    // Heap wrapper, latch-gated free: worker threads hold this address
    // as the channel wake context and an abandoned wake call may
    // dereference it after this frame unwinds (see
    // `NullPlatform.createWithOptions`/`destroy`).
    const null_platform = try native_sdk.NullPlatform.createWithOptions(.{}, webEngine(), app_info);
    defer null_platform.destroy();
    null_platform.gpu_surfaces = true;
    var replay_platform = null_platform.platform();
    // Same-platform replay must mirror the RECORDING host's rendering
    // capabilities, or pixel checkpoints catch the honest difference:
    // - text measures through the SAME host seam (macOS: CoreText + the
    //   bundled faces) — engine fallback metrics differ by fractions of
    //   a pixel;
    // - native scroll drivers exist (macOS overlay scrollers), so the
    //   engine's drawn scrollbar stands down exactly like it did live.
    if (comptime std.mem.eql(u8, build_options.platform, "macos")) {
        native_sdk.platform.macos.installHeadlessTextServices(&replay_platform.services);
        null_platform.gpu_surface_scroll_drivers = true;
    }
    // Replayed image loads decode too: successful `.image` records feed
    // their journaled blob-store bytes back through decode+register, so
    // the codec must be the recording host's own or every replayed load
    // (and every replayed screenshot with an image in it) drops its
    // pixels. Journaled bytes stay the only input — the codec is a pure
    // bytes-to-pixels call and the network stays absent.
    native_sdk.platform.installHeadlessImageCodec(build_options.platform, null_platform, &replay_platform.services);
    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    // Fonts registered at startup and media-surface texture buffers
    // adopted during the run are heap-owned by the runtime; return them
    // (and disarm the producer wake bindings) before the runtime
    // storage itself goes.
    defer runtime.deinit();
    // Bridge policy and security must match what the recording ran
    // under (they gate replayed bridge_message dispatch); automation,
    // window-state restore, and tracing stay off — replay consumes only
    // the journal and restores nothing.
    native_sdk.Runtime.initAt(runtime, .{
        .platform = replay_platform,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .js_window_api = options.js_window_api,
        .web_layer = webLayerEnabled(),
        .security = options.security,
        .menus = options.menus,
    });

    const verify = if (init.environ_map.get("NATIVE_SDK_SESSION_VERIFY")) |value|
        !std.mem.eql(u8, value, "0")
    else
        true;
    const blob_store = sessionBlobStore(init.io, journal_path);
    const report = native_sdk.runtime.replaySession(runtime, app, journal_bytes, .{
        .verify = verify,
        .blobs = if (blob_store) |store| store.source() else null,
    }) catch |err| {
        switch (err) {
            error.JournalBadMagic,
            error.JournalUnsupportedVersion,
            error.JournalTruncated,
            error.JournalCorrupt,
            error.JournalRecordOverBudget,
            error.JournalMissingHeader,
            error.JournalCountMismatch,
            => std.debug.print("session replay refused {s}: {s}\n", .{ journal_path, native_sdk.runtime.session_journal.describeError(@errorCast(err)) }),
            else => {},
        }
        return err;
    };
    std.debug.print("session replay: {d} events, {d} effect results fed ({d} regenerated), {d} fingerprint checkpoints, {d} screenshot marks\n", .{
        report.events_replayed,
        report.effects_fed,
        report.effects_skipped,
        report.checkpoints_verified,
        report.screenshots_verified,
    });
    if (!report.ok()) {
        const detail_count: usize = @intCast(@min(report.mismatch_count, report.mismatches.len));
        for (report.mismatches[0..detail_count]) |mismatch| {
            std.debug.print("session replay mismatch: {s} after event {d} (frame {d}): recorded {x} vs replayed {x}\n", .{
                @tagName(mismatch.kind),
                mismatch.event_ordinal,
                mismatch.frame_index,
                mismatch.expected,
                mismatch.actual,
            });
        }
        std.debug.print("session replay FAILED verification: {d} mismatching checkpoint(s)\n", .{report.mismatch_count});
        return error.SessionReplayMismatch;
    }
    std.debug.print("session replay verified: deterministic\n", .{});
}

fn readSessionJournal(io: std.Io, path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(
        std.heap.page_allocator,
        .limited(native_sdk.runtime.max_session_journal_bytes),
    );
}

fn shouldTrace(record: native_sdk.trace.Record) bool {
    if (comptime std.mem.eql(u8, build_options.trace, "off")) return false;
    if (comptime std.mem.eql(u8, build_options.trace, "all")) return true;
    if (comptime std.mem.eql(u8, build_options.trace, "events")) return std.mem.eql(u8, record.name, "runtime.event");
    return std.mem.indexOf(u8, record.name, build_options.trace) != null;
}

fn webEngine() native_sdk.WebEngine {
    if (comptime std.mem.eql(u8, build_options.web_engine, "chromium")) return .chromium;
    return .system;
}

const StateBuffers = struct {
    state_dir: [1024]u8 = undefined,
    file_path: [1200]u8 = undefined,
    read: [8192]u8 = undefined,
    restored_windows: [native_sdk.platform.max_windows]native_sdk.WindowOptions = undefined,
};

fn prepareStateStore(io: std.Io, env_map: *std.process.Environ.Map, app_info: *native_sdk.AppInfo, buffers: *StateBuffers) ?native_sdk.window_state.Store {
    const paths = native_sdk.window_state.defaultPaths(&buffers.state_dir, &buffers.file_path, app_info.bundle_id, native_sdk.debug.envFromMap(env_map)) catch return null;
    const store = native_sdk.window_state.Store.init(io, paths.state_dir, paths.file_path);
    if (app_info.windows.len > 0) {
        const restored_windows = buffers.restored_windows[0..app_info.windows.len];
        for (restored_windows, 0..) |*window, index| {
            if (!window.restore_state) continue;
            if (store.loadWindow(window.label, &buffers.read) catch null) |saved| {
                window.default_frame = saved.frame;
                if (index == 0) app_info.main_window.default_frame = saved.frame;
            }
        }
    } else if (app_info.main_window.restore_state) {
        if (store.loadWindow(app_info.main_window.label, &buffers.read) catch null) |saved| {
            app_info.main_window.default_frame = saved.frame;
        }
    }
    return store;
}
