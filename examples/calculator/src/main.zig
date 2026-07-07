//! calculator: a real four-function calculator showcasing precision
//! Native SDK layout — the classic keypad grid, a live expression +
//! result display, keyboard input, and a chromeless hidden-inset window
//! in the house register: pure neutrals, one action-blue accent.
//!
//! Authoring split (markup-first): the entire keypad is a `.native` view
//! compiled at comptime; the Zig views are the drag band (the
//! hidden-inset titlebar's drag region, deliberately empty) and the
//! display block, whose right-aligned mono result paragraph needs
//! monospace and weight spans markup does not carry (its size is the
//! display typography rung markup shares). See `src/view.zig`.
//!
//! Keyboard: the expression line is a real `text_field` — click it (or
//! Tab to it) and digits, operators, backspace, and enter flow through
//! the widget keyboard path as calculator keys. Escape is a chrome
//! shortcut (`clear`) so AC works from anywhere, focused or not; plain
//! character keys cannot be chrome shortcuts by design, which is why the
//! text-entry seam carries them.
//!
//! Update is the plain TEA form: no effects, no timers, no I/O — the
//! smallest real Native SDK app shape.

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
pub const rootView = view_mod.rootView;

pub const canvas_label = "calc-canvas";
pub const window_width: f32 = 320;
pub const window_height: f32 = 490;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Calculator canvas", .accessibility_label = "Calculator", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Calculator",
    .width = window_width,
    .height = window_height,
    // Precision layout: the keypad grid is sized in points, so the
    // window is fixed (like every calculator worth using). No titlebar:
    // the in-canvas drag band carries the window (see view.zig), and
    // app.zon's startup window declares the same style.
    .resizable = false,
    .restore_state = false,
    .titlebar = .hidden_inset,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

/// Chrome shortcuts: Escape clears from anywhere (no widget focus
/// needed). Character keys deliberately cannot be unmodified chrome
/// shortcuts, so digits/operators ride the expression field instead.
pub const app_shortcuts = [_]native_sdk.Shortcut{
    .{ .id = "clear", .key = "escape" },
};

pub fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "clear")) return .clear;
    return null;
}

// -------------------------------------------------------------------- app

pub const CalculatorApp = native_sdk.UiApp(Model, Msg);

/// App-registered fonts (the registered-font seam): the display face
/// behind `theme.display_font_id`, registered on the installing frame so
/// the first layout already measures with it. The bytes are the
/// SDK-bundled Geist Mono face — a real app would `@embedFile` its own
/// asset here; the registration path is identical.
const app_fonts = [_]CalculatorApp.FontRegistration{.{
    .id = theme.display_font_id,
    .name = "GeistMono-Regular.ttf",
    .ttf = canvas.font_ttf.geist_mono_bytes,
}};

pub fn calculatorOptions() CalculatorApp.Options {
    return .{
        .name = "calculator",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .view = rootView,
        .tokens_fn = tokensFromModel,
        .fonts = &app_fonts,
        .on_appearance = onAppearance,
        .on_command = onCommand,
    };
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

// ----------------------------------------------------------------- mobile

/// Mobile embed seam (compiled when a build wires this app through the
/// framework's `addMobileLib` helper — see examples/ui-inbox for a build
/// that keeps such a `lib` step): the same Model/Msg/update/view compiled
/// into the embed static library with the canonical single-surface mobile
/// scene.
pub fn initModel() Model {
    return .{};
}

pub fn mobileOptions() CalculatorApp.Options {
    return .{
        .name = "calculator",
        .scene = native_sdk.embed.mobile_shell_scene,
        .canvas_label = native_sdk.embed.mobile_gpu_surface_label,
        .update = update,
        .view = rootView,
        .tokens_fn = tokensFromModel,
        .fonts = &app_fonts,
        .on_appearance = onAppearance,
        .on_command = onCommand,
    };
}

// ------------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(CalculatorApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = CalculatorApp.init(std.heap.page_allocator, .{}, calculatorOptions());
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "calculator",
        .window_title = "Calculator",
        .bundle_id = "dev.native_sdk.calculator",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .shortcuts = &app_shortcuts,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
