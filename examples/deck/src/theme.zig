//! deck theme: the whole skin, expressed as design tokens — no widget
//! code knows it is dressed as hardware.
//!
//! THIS SKIN IS CUSTOM BY DESIGN. It deliberately does not follow the
//! framework's theme packs or the OS color scheme: the deck is a piece
//! of vintage rack hardware, and hardware has exactly one finish — warm
//! cream/putty enamel chassis panels around dark smoked-glass display
//! bays that print in phosphor green. Every value below is this
//! product's identity, not a restatement of the house register; apps
//! that want the house look should start from `DesignTokens.theme` and
//! stop there.
//!
//! The palette is split across two physical materials, and the token
//! table allocates its slots by MATERIAL rather than by the house
//! semantics:
//!   - enamel (the chassis): `surface` is the enamel, `text` is the
//!     silkscreened ink, `text_muted` the lighter engraving gray,
//!     `border` the putty hairline between plates.
//!   - glass (the display bays): `background` is the smoked glass —
//!     every bay fills with it — `accent` is the LIVE phosphor,
//!     `success` the pale phosphor a readout prints in at rest, and
//!     `info` the dim phosphor of engraved-on-glass captions (this app
//!     has no informational-violet surface, so the slot is spent on the
//!     third phosphor register; a teaching trade, stated here).
//! Signal amber (`warning`) is reserved for the queue and the failure
//! stamps — the one non-green hue on the glass.
//!
//! Accessibility still beats brand: a high-contrast request abandons the
//! skin for the framework's high-contrast light palette and stock
//! control chrome, and reduce-motion zeroes the motion tokens.

const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;
const Color = canvas.Color;

/// The deck's primary text face: Geist Pixel (the Vercel pixel family,
/// Square cut), registered at boot through `UiApp.Options.fonts` (see
/// main.zig; the committed TTF and its OFL license live in src/fonts/).
/// One registered face fills BOTH typography slots below — every span
/// on the fascia, mono-flagged or not, prints in the pixel face; only
/// the seven-segment clock stays custom-drawn chrome.
pub const primary_font_id: canvas.FontId = canvas.min_registered_font_id;

/// Geist Pixel's design grid: every outline coordinate in the face is a
/// multiple of 38/1000 em, so ONE font-pixel is exactly one device
/// pixel when the em size is 1000/38 px. All deck type sits on this
/// grid — the body/readout size at the HALF grid (font-pixels land on
/// half-pixel boundaries at 1x and exactly on device pixels at 2x) and
/// the marquee at the FULL grid (pixel-perfect everywhere) — so the
/// pixel face renders as blocks, never as anti-aliased mush.
pub const pixel_grid_em: f32 = 1000.0 / 38.0; // ~26.32
pub const pixel_grid_half_em: f32 = pixel_grid_em / 2.0; // ~13.16

/// Paragraph base size (the typography token below): the pixel face's
/// half-grid size. Public because the views derive their display scales
/// from it (marquee = 2.0 => the full grid).
pub const body_size: f32 = pixel_grid_half_em;

pub fn tokens(high_contrast: bool, reduce_motion: bool) canvas.DesignTokens {
    var out = canvas.DesignTokens.theme(.{
        // One finish: the OS scheme never reaches this call. The light
        // base keeps the framework's light-scheme control washes under
        // the cream enamel overrides below.
        .color_scheme = .light,
        .contrast = if (high_contrast) .high else .standard,
        .density = .compact,
        .reduce_motion = reduce_motion,
    });
    out.pixel_snap = .{ .geometry = true, .text = true, .scale = 1 };
    if (high_contrast) return out;

    out.colors = chassis_colors;
    // Softly beveled hardware: chunkier than machined chamfers, still
    // nothing close to a pill.
    out.radius = .{ .sm = 2, .md = 3, .lg = 4, .xl = 5 };
    // The pixel face is the PRIMARY type: both slots point at the
    // registered Geist Pixel face, so mono-flagged readouts and plain
    // text alike print in it (high contrast returned above with the
    // toolkit's stock faces — accessibility beats brand). The face is
    // proportional, so nothing below assumes a fixed pitch; alignment
    // rides fixed column widths and text alignment instead.
    out.typography.font_id = primary_font_id;
    out.typography.mono_font_id = primary_font_id;
    // Every size sits on the face's half-grid (see `pixel_grid_half_em`)
    // so the blocks stay square; hierarchy comes from the phosphor
    // registers and the marquee's full-grid scale, not from size steps
    // the grid cannot honor.
    out.typography.body_size = body_size;
    out.typography.label_size = pixel_grid_half_em;
    out.typography.title_size = pixel_grid_em;
    out.typography.button_size = pixel_grid_half_em;
    // The long-travel fader: a slim track with a squared cap, stated as
    // metric tokens so both engines cut the same thumb.
    out.metrics.slider_track_height = 4;
    out.metrics.slider_thumb_width = 10;
    out.metrics.slider_thumb_height = 16;

    // ---- control plating -------------------------------------------
    // Chunky enamel keys with dark glyphs; the chrome pass adds the 3D
    // bevel edges on the transport plates, so the tokens only state the
    // fills and inks.
    out.controls.button_outline = .{
        .background = key_face,
        .hover_background = key_hover,
        .active_background = key_pressed,
        .foreground = ink,
        .border = key_edge,
    };
    out.controls.button_ghost = .{
        .hover_background = key_hover,
        .active_background = key_pressed,
        .foreground = ink,
    };
    // No filled-primary control exists on this faceplate; keep the slot
    // on the enamel register so any stray primary reads as hardware.
    out.controls.button_primary = .{
        .background = key_face,
        .hover_background = key_hover,
        .active_background = key_pressed,
        .foreground = ink,
        .border = key_edge,
    };
    // The PL key: a latching hardware toggle — pressed-in enamel while
    // the playlist rack is out.
    out.controls.toggle_button = .{
        .background = key_face,
        .hover_background = key_hover,
        .active_background = key_latched,
        .foreground = ink,
        .border = key_edge,
    };
    // The search field is a small glass inset in the rack's enamel
    // status strip: smoked fill, phosphor print.
    out.controls.search_field = .{
        .background = glass,
        .foreground = phosphor_pale,
        .border = hairline,
    };
    // Faders: putty groove, phosphor filled range, enamel cap with a
    // dark rim (the radius squares the cap into a hardware slider).
    out.controls.slider = .{
        .background = groove,
        .active_background = phosphor,
        .foreground = key_face,
        .border = ink,
        .radius = 1,
    };
    out.controls.scrollbar = .{
        .background = Color.rgba8(0, 0, 0, 0),
        .foreground = Color.rgba8(94, 125, 104, 110),
    };
    out.controls.badge = .{
        .radius = 1,
    };
    // Default panels paint NOTHING — no fill, no stroke: every visible
    // surface in this app states its material explicitly
    // (`style_tokens`), the glass bays are framed by the chrome pass's
    // bevels (not widget borders), and the panel family that leans on
    // the default — the playlist bay's ledger rows — is bare glass by
    // design: single hairline dividers between rows, no per-row plates.
    out.controls.panel = .{
        .background = Color.rgba8(0, 0, 0, 0),
        .border = Color.rgba8(0, 0, 0, 0),
    };
    return out;
}

// ---- palette -------------------------------------------------------

// The enamel family: warm cream/putty, stepped by machining depth.
const enamel = Color.rgb8(231, 225, 209);
const enamel_bright = Color.rgb8(243, 238, 224);
const key_face = Color.rgb8(238, 232, 217);
const key_hover = Color.rgb8(245, 240, 227);
const key_pressed = Color.rgb8(212, 204, 184);
const key_latched = Color.rgb8(205, 197, 176);
const key_edge = Color.rgb8(158, 150, 128);
const groove = Color.rgb8(186, 178, 155);
const ink = Color.rgb8(44, 40, 32);
const engraving = Color.rgb8(110, 102, 82);
const putty_line = Color.rgb8(169, 161, 138);
const disabled_wash = Color.rgb8(222, 215, 198);

// The glass family: smoked near-black with a green cast, and the one
// phosphor hue at three registers. Public because the chrome pass draws
// its segment readout and band ladders in the same phosphor.
pub const glass = Color.rgb8(12, 16, 13);
const glass_lifted = Color.rgb8(24, 40, 30);
pub const phosphor = Color.rgb8(62, 224, 138);
const phosphor_pale = Color.rgb8(168, 216, 180);
const phosphor_dim = Color.rgb8(96, 128, 106);
const hairline = Color.rgb8(56, 68, 58);

pub const chassis_colors = canvas.ColorTokens{
    // Glass register: every display bay fills with `background`.
    .background = glass,
    .surface = enamel,
    // The lifted-glass wash under the loaded ledger row (glass, not
    // enamel: the playlist bay is a display on this machine).
    .surface_subtle = glass_lifted,
    .surface_pressed = key_pressed,
    .text = ink,
    .text_muted = engraving,
    .border = putty_line,
    .accent = phosphor,
    .accent_text = Color.rgb8(7, 21, 13),
    .destructive = Color.rgb8(196, 60, 46),
    .destructive_text = Color.rgb8(250, 246, 236),
    // Pale phosphor: what a readout prints in at rest.
    .success = phosphor_pale,
    .success_text = Color.rgb8(7, 21, 13),
    // Signal amber: the queue's "pending" state and the failure stamps,
    // the one non-green hue on the glass.
    .warning = Color.rgb8(236, 178, 74),
    .warning_text = Color.rgb8(43, 30, 7),
    // Dim phosphor: engraved-on-glass captions (see the module doc for
    // why the info slot carries it).
    .info = phosphor_dim,
    .info_text = Color.rgb8(7, 21, 13),
    // A phosphor focus ring on cream enamel reads as the powered-on
    // cursor of the machine.
    .focus_ring = phosphor,
    // Depth on this product is machined (chrome bevels), never cast.
    .shadow = Color.rgba8(0, 0, 0, 0),
    .disabled = disabled_wash,
};
