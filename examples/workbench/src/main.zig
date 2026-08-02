//! workbench: a live terminal beside a browser, one resizable split.
//!
//! The terminal is the `<terminal>` markup element end to end: the model
//! owns a pty effect key (`fx.ptySpawn` names it in `boot`) and the
//! RUNTIME owns the emulator session behind it — output feeds, focused
//! keyboard and IME text, wheel scrollback, and the layout-derived
//! `ptyResize` all happen inside the toolkit; this file carries no
//! emulator wiring at all. Record a session and it replays offline: the
//! journaled output batches ARE the terminal.
//!
//! The browser is the webview view machinery: a scene webview snapped to
//! the pane anchored in the markup, navigated by setting the pane's URL
//! (the app-owned history array behind back/forward) and reloaded by
//! bumping the pane's reload token.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const canvas_label = "workbench-canvas";
pub const web_view_label = "workbench-web";
pub const web_pane_anchor = "web-pane";
pub const window_width: f32 = 1280;
pub const window_height: f32 = 800;
pub const window_min_width: f32 = 900;
pub const window_min_height: f32 = 560;

/// The pty key the `<terminal>` binds — ordinary model data, the same id
/// `fx.ptySpawn` names.
pub const shell_effect_key: u64 = 1;

pub const home_url = "https://ziglang.org";
pub const max_url_bytes = 1024;
pub const max_history = 32;

/// The default interactive shell per platform — a deterministic pick so
/// a replayed session issues the identical spawn (reading $SHELL would
/// be nondeterminism outside the effect boundary).
pub const default_shell_argv: []const []const u8 = if (builtin.os.tag == .macos)
    &.{ "/bin/zsh", "-i" }
else if (builtin.os.tag == .windows)
    &.{"cmd.exe"}
else
    &.{ "/bin/sh", "-i" };

// ------------------------------------------------------------------ model

pub const Model = struct {
    /// The split's first-pane fraction, model-owned (the controlled
    /// pattern): divider drags echo through `split_resized` and land
    /// back here. The terminal takes the left third by default.
    split_fraction: f32 = 1.0 / 3.0,
    /// The terminal's scrollback echo (`on-terminal` reports it, the
    /// binding hands it back), so the runtime-owned position survives
    /// rebuilds — the scroll `value` source-wins pattern.
    term_scrollback: u32 = 0,
    /// Hidden-inset chrome band height (traffic lights), via on_chrome.
    chrome_top: f32 = 0,
    /// The address bar's edit buffer (`boot` seeds it with the home URL).
    address_field: canvas.TextBuffer(max_url_bytes) = .{},
    /// App-owned navigation history: back/forward walk COMMITTED
    /// entries (there is deliberately no per-page history event from
    /// the webview — the model is the source of truth the pane URL
    /// derives from).
    history: [max_history]canvas.TextBuffer(max_url_bytes) = @splat(.{}),
    history_count: usize = 0,
    history_index: usize = 0,
    /// Bumped by Reload: the pane re-navigates the same URL.
    reload_token: u64 = 0,
    /// Shell session accounting for tests (the runtime owns the screen).
    shell_live: bool = false,
    shell_exited: bool = false,
    output_batches: u64 = 0,

    pub fn shell_key(model: *const Model) u64 {
        _ = model;
        return shell_effect_key;
    }

    pub fn address(model: *const Model) []const u8 {
        return model.address_field.text();
    }

    pub fn back_disabled(model: *const Model) bool {
        return model.history_index == 0;
    }

    pub fn forward_disabled(model: *const Model) bool {
        return model.history_count == 0 or model.history_index + 1 >= model.history_count;
    }

    /// The terminal pane's titlebar band: clears the traffic lights
    /// under hidden-inset chrome, with a floor for the first pre-chrome
    /// build (and fullscreen, where the lights hide and the band keeps
    /// the terminal from jumping).
    pub fn titlebar_band(model: *const Model) f32 {
        return @max(38, model.chrome_top + 8);
    }

    /// The URL the web pane shows: the committed history entry, never
    /// the address bar's in-progress edit.
    pub fn currentUrl(model: *const Model) []const u8 {
        if (model.history_count == 0) return home_url;
        return model.history[model.history_index].text();
    }
};

pub const Msg = union(enum) {
    shell: native_sdk.EffectPtyEvent,
    split_resized: f32,
    term_state: canvas.TerminalState,
    address_edit: canvas.TextInputEvent,
    navigate,
    go_back,
    go_forward,
    reload,
    chrome_changed: native_sdk.WindowChrome,
};

const WorkbenchApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = builtin.mode == .Debug });
pub const Effects = WorkbenchApp.Effects;

/// TEA init: seed the history with the home page and spawn the shell —
/// the `<terminal>` element renders the session the moment output flows.
pub fn boot(model: *Model, fx: *Effects) void {
    if (model.history_count == 0) {
        model.history[0].set(home_url);
        model.history_count = 1;
        model.history_index = 0;
        model.address_field.set(home_url);
    }
    fx.ptySpawn(.{
        .key = shell_effect_key,
        .argv = default_shell_argv,
        .cols = 80,
        .rows = 24,
        .on_event = Effects.ptyMsg(.shell),
    });
}

/// Commit the address bar's text as a navigation: normalize (a bare
/// host gets https://), drop the forward tail, append, and point the
/// pane at it. An empty address is a no-op.
fn commitNavigation(model: *Model) void {
    var normalized: [max_url_bytes]u8 = undefined;
    const raw = std.mem.trim(u8, model.address_field.text(), " ");
    if (raw.len == 0) return;
    const url = normalize: {
        if (std.mem.indexOf(u8, raw, "://") != null) break :normalize raw;
        const prefix = "https://";
        if (raw.len + prefix.len > normalized.len) break :normalize raw;
        @memcpy(normalized[0..prefix.len], prefix);
        @memcpy(normalized[prefix.len .. prefix.len + raw.len], raw);
        break :normalize normalized[0 .. prefix.len + raw.len];
    };
    // Navigating from mid-history drops the forward entries — the
    // browser convention: the new page becomes the newest.
    if (model.history_count > 0) {
        model.history_index += 1;
    }
    if (model.history_index >= max_history) {
        // The table is full: shift the oldest entry off so navigation
        // never dead-ends (32 entries deep is beyond the demo's reach).
        std.mem.copyForwards(
            canvas.TextBuffer(max_url_bytes),
            model.history[0 .. max_history - 1],
            model.history[1..max_history],
        );
        model.history_index = max_history - 1;
    }
    model.history[model.history_index].set(url);
    model.history_count = model.history_index + 1;
    model.address_field.set(url);
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    _ = fx;
    switch (msg) {
        // The runtime owns the emulator behind the bound key; the app
        // keeps only honest accounting (and could restart on exit).
        .shell => |event| switch (event.kind) {
            .output => {
                model.shell_live = true;
                model.output_batches += 1;
            },
            .exit => {
                model.shell_live = false;
                model.shell_exited = true;
            },
            .write => unreachable,
        },
        // The controlled-split echo: store the applied fraction, the
        // next rebuild lays panes at exactly this value.
        .split_resized => |fraction| model.split_fraction = fraction,
        // The terminal view-state echo: hand the applied scrollback
        // back through the binding and wheel scrollback survives
        // rebuilds.
        .term_state => |state| model.term_scrollback = state.scrollback,
        .address_edit => |edit| model.address_field.apply(edit),
        .navigate => commitNavigation(model),
        .go_back => {
            if (model.history_index == 0) return;
            model.history_index -= 1;
            model.address_field.set(model.history[model.history_index].text());
        },
        .go_forward => {
            if (model.history_count == 0 or model.history_index + 1 >= model.history_count) return;
            model.history_index += 1;
            model.address_field.set(model.history[model.history_index].text());
        },
        .reload => model.reload_token +%= 1,
        .chrome_changed => |chrome| model.chrome_top = chrome.insets.top,
    }
}

// ------------------------------------------------------------------- view

pub const workbench_markup = @embedFile("workbench.native");
pub const CompiledWorkbenchView = canvas.CompiledMarkupView(Model, Msg, workbench_markup);

/// The web pane: snapped to the markup's anchor column every presented
/// frame — the split divider reflows live web content. Setting `url`
/// navigates; bumping `reload_token` reloads the same URL.
pub fn webPanes(model: *const Model, out: []WorkbenchApp.WebViewPane) usize {
    out[0] = .{
        .label = web_view_label,
        .anchor = web_pane_anchor,
        .url = model.currentUrl(),
        .reload_token = model.reload_token,
    };
    return 1;
}

pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

// ------------------------------------------------------------------ scene

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Workbench canvas", .accessibility_label = "Workbench", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
    // The browser pane's webview, parented to the canvas: `webPanes`
    // snaps it to the anchor column's frame every presented frame.
    .{ .label = web_view_label, .kind = .webview, .parent = canvas_label, .url = home_url, .x = 0, .y = 0, .width = 1, .height = 1, .layer = 20 },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Workbench",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    // The Ghostty-clean chrome: hidden-inset titlebar, no status bar —
    // the traffic lights float over the terminal pane's own band.
    .titlebar = .hidden_inset,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub fn appOptions(io: std.Io) WorkbenchApp.Options {
    return .{
        .name = "workbench",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .view = CompiledWorkbenchView.build,
        .markup = if (builtin.mode == .Debug)
            .{ .source = workbench_markup, .watch_path = "src/workbench.native", .io = io }
        else
            null,
        .on_chrome = onChrome,
        .web_panes = webPanes,
    };
}

// ------------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(WorkbenchApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = WorkbenchApp.init(std.heap.page_allocator, .{}, appOptions(init.io));
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "workbench",
        .window_title = "Workbench",
        .bundle_id = "dev.native_sdk.workbench",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app", "*" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
