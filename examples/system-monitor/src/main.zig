//! system-monitor: a live CPU / memory / process monitor built to
//! showcase the Native SDK effects channel — no library calls into the
//! kernel, no third-party services, just the OS's own commands run
//! through `fx.spawn` on an `fx.startTimer` cadence.
//!
//! The loop: a repeating 2 s timer fires -> `update` spawns `ps` and the
//! per-OS memory command in `.collect` mode -> each exit Msg delivers the
//! whole stdout -> pure parsers (`sampler.zig`, fixture-tested against
//! committed real output) turn it into stat tiles, 60-sample sparkline
//! history, and a top-CPU process table with search, sort toggles, and a
//! confirmed SIGTERM context-menu action.
//!
//! Authoring split (markup-first): the header and the three sparkline
//! charts are comptime-compiled `.native` views (each sparkline is one
//! `<chart>` binding the model's NaN-padded sample window); the tiles,
//! toolbar, table, and the confirmation overlay are Zig. See
//! `src/view.zig`.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const model_mod = @import("model.zig");
const theme = @import("theme.zig");
const view_mod = @import("view.zig");

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const update = model_mod.update;
pub const boot = model_mod.boot;
pub const rootView = view_mod.rootView;

pub const canvas_label = "monitor-canvas";
pub const window_width = view_mod.window_width;
pub const window_height = view_mod.window_height;
/// Content min-size floor the window enforces: the tile grid is machined
/// for the full content width, so shrinking below the designed size can
/// only clip it — the floor is the size itself.
pub const window_min_width: f32 = view_mod.window_width;
pub const window_min_height: f32 = view_mod.window_height;

// The model-declared settings WINDOW (dev-2's SettingsView shape):
// `.open_settings` sets the flag, `windows_fn` declares the window while
// it is set, and its canvas renders `view_mod.settingsView` from the
// same model as the main window. It opens the standard way only — the
// app-menu Settings item and its keyboard shortcut (primary+comma) both
// deliver `cmd_settings` through `command` below; there is no in-window
// settings button. Fixed-size: the content is one grouped form row, so
// the window is exactly that row plus its insets.
pub const settings_window_label = "settings";
pub const settings_canvas_label = "settings-canvas";
pub const settings_window_width: f32 = 420;
pub const settings_window_height: f32 = 76;

// ---------------------------------------------------------------- commands

/// The settings command id: registered as the primary+comma shortcut in
/// app.zon (`.shortcuts`) and shared by every settings entry point, so
/// menu and keyboard land on the same `.open_settings` dispatch.
pub const cmd_settings = "monitor.settings";

/// Shell command events (menu items, registered shortcuts) map to Msgs
/// here — one code path for every way the OS asks the app to act.
pub fn command(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, cmd_settings)) return .open_settings;
    return null;
}

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "System monitor canvas", .accessibility_label = "System monitor", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "System Monitor",
    .width = window_width,
    .height = window_height,
    // The tile grid is machined for exactly the content width, so the
    // floor is the designed size itself — proven by the layout audit
    // sweep in tests.zig, which sweeps from exactly this floor.
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    // Tall hidden-inset titlebar (declared in app.zon too, which threads
    // it through the STARTUP window create): the header bar IS the
    // titlebar — it pads its leading edge past the traffic lights via
    // `on_chrome` and is the window's drag surface (`window-drag` in
    // header.native). The settings window keeps standard chrome.
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// -------------------------------------------------------------------- app

pub const MonitorApp = native_sdk.UiApp(Model, Msg);

/// Fragment hot reload (Debug dev runs): the root view is Zig, but the
/// header and the three sparklines are compiled markup fragments —
/// registering them keeps the edit-see loop alive, so editing any of
/// these `.native` sources (or a file they import, like the header's
/// status-line component) while the app runs reloads that fragment in
/// place. Outside Debug the handles are empty and the watch compiles
/// to nothing.
const monitor_fragments = [_]canvas.MarkupFragment{
    view_mod.CompiledHeaderView.fragment("src/header.native"),
    view_mod.CpuSparkView.fragment("src/spark_cpu.native"),
    view_mod.MemSparkView.fragment("src/spark_mem.native"),
    view_mod.ProcSparkView.fragment("src/spark_proc.native"),
    view_mod.UptimeValueView.fragment("src/uptime_value.native"),
};

pub fn monitorOptions() MonitorApp.Options {
    return .{
        .name = "system-monitor",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .view = rootView,
        .windows_fn = monitorWindows,
        .window_view = monitorWindowView,
        .on_command = command,
        .tokens_fn = tokensFromModel,
        .on_appearance = onAppearance,
        .on_chrome = onChrome,
    };
}

/// The declared window set derives from the model: the settings window
/// exists exactly while `settings_open` is set. The runtime reconciles
/// after every dispatch — `.open_settings` opens it, and the user's
/// close button dispatches `.settings_closed` so the model agrees (keep
/// the flag set to veto and it comes right back).
fn monitorWindows(model: *const Model, scratch: *MonitorApp.WindowsScratch) []const MonitorApp.WindowDescriptor {
    var count: usize = 0;
    if (model.settings_open) {
        scratch.windows[count] = .{
            .label = settings_window_label,
            .canvas_label = settings_canvas_label,
            .title = "Settings",
            .width = settings_window_width,
            .height = settings_window_height,
            // A settings window is fixed-size: the content is a form
            // machined for exactly this box, so resizing could only
            // stretch or clip it.
            .resizable = false,
            .on_close = .settings_closed,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

fn monitorWindowView(ui: *MonitorApp.Ui, model: *const Model, window_label: []const u8) MonitorApp.Ui.Node {
    std.debug.assert(std.mem.eql(u8, window_label, settings_window_label));
    return view_mod.settingsView(ui, model);
}

/// Design tokens derive from the model's theme preference plus the
/// OS-reported appearance (scheme, contrast, reduced motion).
pub fn tokensFromModel(model: *const Model) canvas.DesignTokens {
    return theme.tokens(model.colorScheme(), model.appearance.high_contrast, model.appearance.reduce_motion);
}

/// System appearance changes land in the model so `tokens_fn` re-derives;
/// the `auto` theme preference follows them live.
fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return Msg{ .set_appearance = appearance };
}

/// Chrome overlay geometry flows into the model (tall hidden-inset
/// titlebar): delivered before the first view build and again when it
/// changes — entering fullscreen hides the traffic lights and this goes
/// to zero.
pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return Msg{ .chrome_changed = chrome };
}

// ------------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(MonitorApp);
    defer std.heap.page_allocator.destroy(app_state);
    var options = monitorOptions();
    options.fragment_watch = .{ .fragments = &monitor_fragments, .io = init.io };
    app_state.* = MonitorApp.init(std.heap.page_allocator, .{}, options);
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "system-monitor",
        .window_title = "System Monitor",
        .bundle_id = "dev.native_sdk.system_monitor",
        .icon_path = "assets/icon.icns",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
