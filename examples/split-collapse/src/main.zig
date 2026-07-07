//! split-collapse: the smallest honest pane-collapse animation harness.
//!
//! A two-pane split whose first-pane fraction tweens between an expanded
//! and a collapsed position over 180 ms. The app exists to measure frame
//! pacing during a layout tween, so it carries BOTH driving styles:
//!
//!   - Manual (`--manual`): the historical idiom — `on_frame` returns a
//!     tick Msg carrying the presented frame's timestamp, `update` eases
//!     the fraction, the rebuild changes layout, and the changed layout
//!     requests the next frame. Every model tick is a full rebuild.
//!   - Runtime tween (default): the layout-animation primitive — one
//!     `runtime.startCanvasLayoutTween` call when the toggle flips, no
//!     per-frame Msgs, no rebuilds while the runtime drives the fraction
//!     toward the target.
//!   - Markup tween (`SPLIT_COLLAPSE_MARKUP=1`): the same primitive
//!     declared entirely in markup — `resize-duration="180"` on the
//!     split makes its bound value a tween target, so the view file is
//!     the whole animation and this Zig file supplies only model/update.
//!
//! Each presented frame during a tween logs `tween-frame dt_ms=...` on
//! stderr, so a driver (or a person) can count the visible steps of the
//! 180 ms collapse and read the real deltas between them.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const canvas_label = "split-canvas";
pub const window_width: f32 = 800;
pub const window_height: f32 = 520;

pub const expanded_fraction: f32 = 0.35;
pub const collapsed_fraction: f32 = 0.06;
pub const tween_duration_ms: u32 = 180;

// -------------------------------------------------------------------- model

pub const Tween = struct {
    from: f32,
    to: f32,
    /// First tick stamps the start; 0 means "not started yet" so the
    /// tween's clock begins on the first presented frame, not at the
    /// (earlier) input timestamp.
    start_ns: u64 = 0,
};

pub const Model = struct {
    appearance: native_sdk.Appearance = .{},
    collapsed: bool = false,
    fraction: f32 = expanded_fraction,
    tween: ?Tween = null,
    /// Presented-frame observations while a tween runs (manual mode).
    tween_frame_count: u32 = 0,
    last_frame_ns: u64 = 0,
    /// True runs the historical on_frame/Msg-tick driver; false asks the
    /// runtime to drive the fraction (the layout tween primitive).
    manual_mode: bool = false,

    /// The markup view's declared RESTING fraction: the split binds
    /// `value="{pane_fraction}"` and its `resize-duration` makes this a
    /// tween target, so flipping `collapsed` is the whole collapse.
    pub fn pane_fraction(model: *const Model) f32 {
        return if (model.collapsed) collapsed_fraction else expanded_fraction;
    }

    pub fn toggle_label(model: *const Model) []const u8 {
        return if (model.collapsed) "Expand sidebar" else "Collapse sidebar";
    }

    pub fn content_hint(model: *const Model) []const u8 {
        return if (model.collapsed)
            "The sidebar is collapsed; this pane reflowed to fill the width."
        else
            "The sidebar is expanded; drag the divider or press the button.";
    }
};

pub const Msg = union(enum) {
    toggle,
    auto_toggle: native_sdk.EffectTimer,
    frame_tick: u64,
    split_resized: f32,
    set_appearance: native_sdk.Appearance,
};

fn easeInOutCubic(t: f32) f32 {
    if (t < 0.5) return 4 * t * t * t;
    const back = -2 * t + 2;
    return 1 - (back * back * back) / 2;
}

fn applyToggle(model: *Model) void {
    model.collapsed = !model.collapsed;
    if (model.manual_mode) {
        const target: f32 = if (model.collapsed) collapsed_fraction else expanded_fraction;
        model.tween = .{ .from = model.fraction, .to = target };
        model.tween_frame_count = 0;
        model.last_frame_ns = 0;
    }
    // Runtime-driven mode changes NOTHING else: the collapsed flag is
    // the resting truth, `layoutTweens` declares the target fraction,
    // and the runtime moves the divider (the on_resize echo keeps
    // `model.fraction` — the declared `value` — in step).
}

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .toggle => applyToggle(model),
        .auto_toggle => applyToggle(model),
        .frame_tick => |timestamp_ns| {
            const tween = &(model.tween orelse return);
            if (tween.start_ns == 0) tween.start_ns = timestamp_ns;
            if (model.last_frame_ns != 0) {
                const dt_ns = timestamp_ns -| model.last_frame_ns;
                std.debug.print("tween-frame dt_ms={d:.1} fraction={d:.3}\n", .{
                    @as(f64, @floatFromInt(dt_ns)) / 1_000_000.0,
                    model.fraction,
                });
            } else {
                std.debug.print("tween-frame dt_ms=start fraction={d:.3}\n", .{model.fraction});
            }
            model.last_frame_ns = timestamp_ns;
            model.tween_frame_count += 1;
            const elapsed_ns = timestamp_ns -| tween.start_ns;
            const duration_ns: u64 = @as(u64, tween_duration_ms) * 1_000_000;
            if (elapsed_ns >= duration_ns) {
                model.fraction = tween.to;
                model.tween = null;
                std.debug.print("tween-done frames={d}\n", .{model.tween_frame_count});
                return;
            }
            const t = @as(f32, @floatFromInt(elapsed_ns)) / @as(f32, @floatFromInt(duration_ns));
            model.fraction = tween.from + (tween.to - tween.from) * easeInOutCubic(t);
        },
        .split_resized => |fraction| {
            // The controlled-split echo: divider drags AND runtime
            // layout-tween steps both land here. A running MANUAL tween
            // owns the fraction, so ignore echoes then; in runtime mode
            // every echo is truth (each tween step logs its arrival
            // cadence, the same measurement the manual mode takes).
            if (model.tween != null) return;
            if (!model.manual_mode and fraction != model.fraction) {
                std.debug.print("tween-echo fraction={d:.3}\n", .{fraction});
            }
            model.fraction = fraction;
        },
        .set_appearance => |appearance| model.appearance = appearance,
    }
}

// --------------------------------------------------------------------- view

pub const Ui = canvas.Ui(Msg);

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        headerView(ui, model),
        ui.split(.{
            .grow = 1,
            .value = model.fraction,
            .on_resize = Ui.valueMsg(.split_resized),
        }, .{
            sidebarPane(ui, model),
            contentPane(ui, model),
        }),
    });
}

fn headerView(ui: *Ui, model: *const Model) Ui.Node {
    return ui.row(.{ .height = 48, .padding = 8, .gap = 8, .cross = .center }, .{
        ui.button(.{
            .on_press = .toggle,
            .semantics = .{ .label = "Toggle sidebar" },
        }, if (model.collapsed) "Expand sidebar" else "Collapse sidebar"),
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, if (model.manual_mode) "manual ticks" else "runtime tween"),
    });
}

fn sidebarPane(ui: *Ui, model: *const Model) Ui.Node {
    _ = model;
    return ui.column(.{ .padding = 12, .gap = 8, .style_tokens = .{ .background = .surface } }, .{
        ui.text(.{}, "Sidebar"),
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Inbox"),
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Drafts"),
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Archive"),
    });
}

fn contentPane(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{ .padding = 16, .gap = 8 }, .{
        ui.text(.{ .size = .lg }, "Content"),
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, if (model.collapsed)
            "The sidebar is collapsed; this pane reflowed to fill the width."
        else
            "The sidebar is expanded; drag the divider or press the button."),
        // The web pane's anchor: a growing panel whose layout frame the
        // embedded webview snaps to every presented frame — the shape
        // where a collapsing neighbor makes the webview reflow live.
        ui.column(.{ .grow = 1, .semantics = .{ .label = web_pane_anchor } }, .{}),
    });
}

pub const web_pane_label = "content-web";
pub const web_pane_anchor = "content-web-pane";

/// SPLIT_COLLAPSE_WEB=1 declares a live webview snapped to the content
/// pane, reflowing through the whole tween (the heavy field shape).
var web_pane_enabled = false;

fn webPanes(model: *const Model, out: []SplitCollapseApp.WebViewPane) usize {
    _ = model;
    out[0] = .{
        .label = web_pane_label,
        .anchor = web_pane_anchor,
        .url = "https://example.com",
    };
    return 1;
}

// ------------------------------------------------------------- markup mode

/// SPLIT_COLLAPSE_MARKUP=1: the markup-only twin of the runtime tween.
/// The whole animation is declared in the view — `resize-duration` on
/// the split — so this mode sets NO on_frame and NO layout_tweens hook;
/// the on-resize echoes still land in `update` as `split_resized`, so
/// the same tween-echo cadence log measures the markup path.
pub const markup_source = @embedFile("split_collapse.native");
pub const CompiledSplitView = canvas.CompiledMarkupView(Model, Msg, markup_source);

/// How the collapse is driven: the historical per-frame Msg idiom, the
/// Zig `layout_tweens` hook, or the markup-declared `resize-duration`.
pub const Mode = enum { manual, runtime, markup };

// ---------------------------------------------------------------------- app

pub const SplitCollapseApp = native_sdk.UiApp(Model, Msg);
pub const Effects = SplitCollapseApp.Effects;

fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (model.tween != null) return Msg{ .frame_tick = frame.timestamp_ns };
    return null;
}

/// The layout-tween declaration (runtime mode): the split's target
/// fraction derives from the resting collapsed flag; the runtime eases
/// the rendered fraction toward it whenever they diverge. No per-frame
/// Msgs, no manual clock — and reduced motion snaps inside the runtime.
fn layoutTweens(model: *const Model, tree: *const Ui.Tree, out: []canvas.CanvasWidgetLayoutTween) usize {
    const split = findWidgetByKind(tree.root, .split) orelse return 0;
    out[0] = .{
        .id = split.id,
        .to = if (model.collapsed) collapsed_fraction else expanded_fraction,
        .duration_ms = tween_duration_ms,
        .easing = .standard,
    };
    return 1;
}

fn findWidgetByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findWidgetByKind(child, kind)) |found| return found;
    }
    return null;
}

/// SPLIT_COLLAPSE_AUTO_MS=<interval> arms a repeating toggle so the
/// tween can be observed live without automation (no polling timers in
/// the host, exactly the field shape).
var auto_toggle_interval_ms: u64 = 0;

fn initFx(model: *Model, fx: *Effects) void {
    _ = model;
    if (auto_toggle_interval_ms == 0) return;
    fx.startTimer(.{
        .key = 1,
        .interval_ms = auto_toggle_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.auto_toggle),
    });
}

fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return Msg{ .set_appearance = appearance };
}

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Split canvas", .accessibility_label = "Split collapse", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
    // A live scene webview parented to the canvas: `webPanes` snaps it
    // to the content pane's anchor every presented frame, so the split
    // tween reflows real web content (the heavy field shape).
    .{ .label = web_pane_label, .kind = .webview, .parent = canvas_label, .url = "https://example.com", .x = 0, .y = 0, .width = 1, .height = 1, .layer = 20 },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Split Collapse",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub fn appOptions(mode: Mode) SplitCollapseApp.Options {
    return .{
        .name = "split-collapse",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        // Markup mode renders the compiled markup view; the tween is
        // declared IN the view (resize-duration), so neither Zig hook
        // exists there.
        .view = if (mode == .markup) CompiledSplitView.build else rootView,
        .init_fx = initFx,
        .on_appearance = onAppearance,
        .on_frame = if (mode == .manual) onFrame else null,
        .layout_tweens = if (mode == .runtime) layoutTweens else null,
        .web_panes = if (web_pane_enabled) webPanes else null,
    };
}

pub fn initModel(manual: bool) Model {
    return .{ .manual_mode = manual };
}

// --------------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    // SPLIT_COLLAPSE_MANUAL=1 selects the historical on_frame/Msg-tick
    // driver; SPLIT_COLLAPSE_MARKUP=1 the markup-declared tween
    // (resize-duration in the view, no Zig hooks); the default runs the
    // Zig-declared runtime layout tween.
    const manual = if (init.environ_map.get("SPLIT_COLLAPSE_MANUAL")) |value|
        !std.mem.eql(u8, value, "0")
    else
        false;
    const markup_mode = if (init.environ_map.get("SPLIT_COLLAPSE_MARKUP")) |value|
        !std.mem.eql(u8, value, "0")
    else
        false;
    const mode: Mode = if (markup_mode) .markup else if (manual) .manual else .runtime;
    if (init.environ_map.get("SPLIT_COLLAPSE_AUTO_MS")) |value| {
        auto_toggle_interval_ms = std.fmt.parseInt(u64, value, 10) catch 0;
    }
    if (init.environ_map.get("SPLIT_COLLAPSE_WEB")) |value| {
        web_pane_enabled = !std.mem.eql(u8, value, "0");
    }

    const app_state = try std.heap.page_allocator.create(SplitCollapseApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = SplitCollapseApp.init(std.heap.page_allocator, initModel(mode == .manual), appOptions(mode));
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "split-collapse",
        .window_title = "Split Collapse",
        .bundle_id = "dev.native_sdk.split_collapse",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app", "https://example.com" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
