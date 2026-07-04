//! deck theme: the whole skin, expressed as design tokens — no widget
//! code knows it is dressed as hardware.
//!
//! Dark-only by the design brief (hardware faceplates have no light mode):
//! the OS color scheme is ignored. Chassis blacks stepped by machining
//! depth, steel hairline borders, one phosphor-green hue for everything
//! live, signal amber reserved for the queue. Square corners (1-3px
//! radii), mono-heavy small typography, compact density, and per-control
//! visual tokens (`controls.*`) that turn buttons into flat plates, the
//! slider into a thin bar with a squared thumb, and the search field into
//! a glass inset — all without touching a single widget's rendering code.
//!
//! Accessibility still beats brand: a high-contrast request abandons the
//! skin for the framework's high-contrast dark palette and stock control
//! chrome, and reduce-motion zeroes the motion tokens.

const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;
const Color = canvas.Color;

pub fn tokens(high_contrast: bool, reduce_motion: bool) canvas.DesignTokens {
    var out = canvas.DesignTokens.theme(.{
        // Dark-only: the brief's faceplate has no light mode, so the OS
        // scheme never reaches this call.
        .color_scheme = .dark,
        .contrast = if (high_contrast) .high else .standard,
        .density = .compact,
        .reduce_motion = reduce_motion,
    });
    out.pixel_snap = .{ .geometry = true, .text = true, .scale = 1 };
    if (high_contrast) return out;

    out.colors = chassis_colors;
    // Machined corners: nothing rounder than a chamfer.
    out.radius = .{ .sm = 1, .md = 2, .lg = 3, .xl = 4 };
    // Dense faceplate type; readouts go mono through paragraph spans.
    out.typography.body_size = 12;
    out.typography.label_size = 11;
    out.typography.title_size = 15;
    out.typography.button_size = 12;

    // ---- control plating -------------------------------------------
    // Flat plates: transparent fill, steel hairline, phosphor-tinted
    // glyphs. The primary transport key is the one filled control.
    out.controls.button_outline = .{
        .background = plate,
        .hover_background = plate_hover,
        .active_background = plate_pressed,
        .foreground = phosphor_dim_bright,
        .border = hairline,
    };
    out.controls.button_ghost = .{
        .hover_background = plate_hover,
        .active_background = plate_pressed,
        .foreground = phosphor_dim_bright,
    };
    out.controls.button_primary = .{
        .background = phosphor,
        .hover_background = phosphor_hot,
        .active_background = phosphor_hot,
        .foreground = Color.rgb8(4, 24, 13),
    };
    // LIB/PERF chips: engraved until selected, then lit.
    out.controls.toggle_button = .{
        .background = plate,
        .hover_background = plate_hover,
        .active_background = Color.rgb8(30, 82, 54),
        .foreground = phosphor_dim_bright,
        .border = hairline,
    };
    // Glass inset for the search field.
    out.controls.search_field = .{
        .background = glass,
        .border = hairline,
    };
    // Thin bar, squared thumb: the radius override squares the knob and
    // the phosphor border makes it read as a machined slider cap.
    out.controls.slider = .{
        .background = well,
        .active_background = phosphor,
        .foreground = Color.rgb8(214, 227, 219),
        .border = phosphor,
        .radius = 1,
    };
    out.controls.progress = .{
        .active_background = phosphor,
        .radius = 1,
    };
    out.controls.scrollbar = .{
        .background = Color.rgba8(0, 0, 0, 0),
        .foreground = Color.rgba8(120, 148, 132, 90),
    };
    out.controls.badge = .{
        .radius = 1,
    };
    return out;
}

// ---- palette -------------------------------------------------------

// Chassis blacks, stepped by machining depth.
const case_black = Color.rgb8(9, 11, 10);
const faceplate = Color.rgb8(15, 19, 17);
const plate_raised = Color.rgb8(22, 28, 25);
const plate_pressed = Color.rgb8(31, 40, 35);
const plate = Color.rgb8(18, 23, 20);
const plate_hover = Color.rgb8(26, 33, 29);
const well = Color.rgb8(26, 32, 29);
const glass = Color.rgb8(7, 12, 9);
const hairline = Color.rgb8(38, 48, 42);

// The one hue: phosphor green, dimmed for engravings. Public because
// the chrome pass (`chrome.zig`) draws its segment readout in this hue.
pub const phosphor = Color.rgb8(54, 226, 138);
const phosphor_hot = Color.rgb8(126, 247, 182);
const phosphor_dim = Color.rgb8(104, 124, 112);
const phosphor_dim_bright = Color.rgb8(158, 186, 168);

pub const chassis_colors = canvas.ColorTokens{
    .background = case_black,
    .surface = faceplate,
    .surface_subtle = plate_raised,
    .surface_pressed = plate_pressed,
    .text = Color.rgb8(214, 227, 219),
    .text_muted = phosphor_dim,
    .border = hairline,
    .accent = phosphor,
    .accent_text = Color.rgb8(4, 24, 13),
    .destructive = Color.rgb8(255, 92, 87),
    .destructive_text = Color.rgb8(31, 8, 7),
    .success = phosphor,
    .success_text = Color.rgb8(4, 24, 13),
    // Signal amber: the queue's "pending" state, the one non-green hue.
    .warning = Color.rgb8(245, 185, 66),
    .warning_text = Color.rgb8(38, 26, 4),
    .info = Color.rgb8(102, 210, 255),
    .info_text = Color.rgb8(5, 24, 32),
    .focus_ring = phosphor,
    // Emission, not elevation: nothing in this product casts a shadow.
    .shadow = Color.rgba8(0, 0, 0, 0),
    .disabled = Color.rgb8(24, 30, 27),
};
