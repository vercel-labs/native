//! deck chrome: the sculpted hardware layer, drawn through the sanctioned
//! `ChromeOptions` display-list pass (`UiApp.chrome`) — pushed to the
//! vintage rack-unit extreme on a SMALL, FIXED window (512x264,
//! resizable = false), so every coordinate below is absolute machining:
//!
//!   prefix (behind the widgets): the cream enamel chassis fill, the
//!   warm faceplate gradient with a set of near-invisible grain
//!   hairlines (honest texture: fills, lines, and gradients only — this
//!   skin ships no bitmap assets), the enamel cap band (the DECK stamp
//!   prints directly on it — no raised plate), outer bevels, a ridged
//!   grip band, four recessed corner screws, and ONE inset control well
//!   behind the transport cluster (the volume knob sits directly on the
//!   chassis enamel, unenclosed);
//!
//!   suffix (in front of the widgets): inset bevel frames around the
//!   two glass bays (the display — the deck's ONE LED section — and the
//!   art bay) and the seek fader, scanlines and a diagonal glare wash
//!   over the glass, the seven-segment elapsed readout drawn as sheared
//!   hexagon paths (ghost segments always visible — display ghosting —
//!   lit segments doubled with a translucent glow stroke), the analog
//!   volume knob face with its position dot over the volume slider
//!   (seated directly on the enamel — its slider cover re-plots the
//!   faceplate gradient so the patch vanishes into the chassis), and
//!   raised bevel edges on the transport keys and the cap band's window
//!   keys (the chromeless window's own close/minimize controls).
//!
//! The chrome contract requires an EXACT command count per build, so
//! every section emits a fixed number of commands regardless of model
//! state: state-dependent marks (lit segments, lit ladder cells) are
//! drawn offscreen when hidden instead of skipped. The counts are module
//! constants and the test suite rebuilds the chrome across model states
//! to hold them.
//!
//! Path elements and gradient stops are captured by reference until the
//! runtime deep-copies the display list at install, so runtime-computed
//! segment paths live in file-scope storage (single canvas, UI-thread
//! builds only) and gradient stops are comptime constants.
//!
//! High contrast keeps the layout of the pass (same counts) but drops
//! the decoration: grain, glare, and scanlines go transparent, bevels
//! fall back to the border token, the knob flattens to bordered
//! surface + text-colored dot, and the readouts use the high-contrast
//! text color.

const std = @import("std");
const native_sdk = @import("native_sdk");
const layout = @import("layout.zig");
const model_mod = @import("model.zig");
const theme = @import("theme.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Color = canvas.Color;
const Model = model_mod.Model;

// ------------------------------------------------------------- counts

/// Scanline comb over the display glass: the one LED section is the
/// full glass-row height now, so the comb carries more lines at the
/// same ~4px pitch the old split bays wore.
const glass_scanlines: usize = 36;
const screw_commands: usize = 3;
const ridge_pairs = 3; // comptime_int: used in both command counts and f32 machining
const grain_lines: usize = 14;
const knob_ticks: usize = 5;

// Re-derived for the unboxed round: the raised brand plate (5 — the
// DECK stamp prints directly on the cap band now) and the volume well
// (5 — the knob sits directly on the enamel) are GONE from the prefix;
// every remaining term matches one section of buildPrefix in order.
pub const prefix_commands: usize =
    1 + // chassis fill
    1 + // faceplate gradient
    grain_lines + // enamel grain hairlines
    3 + // cap band (fill + top catch-light + bottom shadow)
    4 + // window outer bevel
    ridge_pairs * 2 + // ridged grip band above the bottom edge
    4 * screw_commands + // corner screws
    5; // transport well (fill + inset bevel) — the ONE recessed pocket

pub const suffix_commands: usize =
    3 * 4 + // display + art + seek inset bevels
    glass_scanlines + // display scanlines (the art bay keeps clear glass)
    2 + // glass glare washes (display, art)
    segment_commands + // seven-segment elapsed readout
    knob_commands + // the volume knob face
    8 * 4; // raised bevels: close, minimize, prev, play, pause, stop, next, PL

const segment_commands: usize = 3 * 21 + 6; // 3 digits x (ghost+glow+lit) + colon
const knob_commands: usize = knob_ticks + 5; // ticks + slider cover + ring + face + dot glow + dot

// ---------------------------------------------------------- palette

// Decorative chrome colors live here (they are machining, not theme
// tokens); the phosphor family comes from the theme so the readouts and
// the widgets stay one hue.
const chassis = Color.rgb8(214, 207, 189);
const faceplate_top = Color.rgb8(240, 234, 220);
const faceplate_bottom = Color.rgb8(221, 214, 196);
const cap_top = Color.rgb8(247, 242, 230);
const cap_bottom = Color.rgb8(228, 221, 203);
const bevel_light = Color.rgba8(255, 253, 244, 210);
const bevel_shadow = Color.rgba8(74, 66, 48, 150);
const ridge_light = Color.rgba8(255, 253, 244, 130);
const ridge_dark = Color.rgba8(74, 66, 48, 70);
/// The enamel grain: alternating warm hairlines a few alpha steps above
/// invisible — the honest stand-in for sprayed-enamel texture.
const grain = Color.rgba8(120, 110, 85, 9);
const scanline = Color.rgba8(0, 0, 0, 46);
const glare = Color.rgba8(255, 255, 255, 9);
const steel = Color.rgb8(196, 189, 172);
const steel_dark = Color.rgb8(110, 103, 84);
const well = Color.rgb8(216, 208, 187);
const knob_rim = Color.rgb8(87, 80, 60);
const knob_top = Color.rgb8(246, 241, 229);
const knob_bottom = Color.rgb8(210, 202, 181);
const transparent = Color.rgba8(0, 0, 0, 0);

const seg_lit = theme.phosphor;
const seg_ghost = Color.rgba8(62, 224, 138, 24);
const seg_glow = Color.rgba8(62, 224, 138, 60);

const faceplate_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = faceplate_top },
    .{ .offset = 1, .color = faceplate_bottom },
};
const cap_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = cap_top },
    .{ .offset = 1, .color = cap_bottom },
};
const glare_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = glare },
    .{ .offset = 1, .color = transparent },
};
const screw_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = steel },
    .{ .offset = 1, .color = steel_dark },
};
const knob_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = knob_top },
    .{ .offset = 1, .color = knob_bottom },
};
const hc_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = transparent },
    .{ .offset = 1, .color = transparent },
};

// ------------------------------------------------------------ geometry
// Absolute machining on the fixed 512x264 chassis. Every rect below is
// spelled from the layout table (layout.zig) — the same constants the
// widget views flow — so the enamel work hugs the widgets by
// construction.

const W: f32 = layout.window_width;
const H: f32 = layout.window_height;

fn rect(x: f32, y: f32, w: f32, h: f32) geometry.RectF {
    return geometry.RectF.init(x, y, w, h);
}

/// Offscreen displacement for fixed-count commands that are hidden in
/// the current model state.
const offscreen: f32 = 100_000;

const display_rect = rect(layout.pad, layout.row1_y, layout.display_width, layout.row1_height);
const art_rect = rect(layout.art_x, layout.row1_y, layout.art_size, layout.row1_height);
const seek_rect = rect(layout.pad, layout.seek_y, W - layout.pad * 2, layout.seek_height);
const close_key = rect(layout.cap_close_x, layout.cap_key_y, layout.cap_key_size, layout.cap_key_size);
const min_key = rect(layout.cap_min_x, layout.cap_key_y, layout.cap_key_size, layout.cap_key_size);
const prev_key = rect(layout.prev_x, layout.key_y, layout.btn_prev_width, layout.key_height);
const play_key = rect(layout.play_x, layout.key_y, layout.btn_play_width, layout.key_height);
const pause_key = rect(layout.pause_x, layout.key_y, layout.btn_pause_width, layout.key_height);
const stop_key = rect(layout.stop_x, layout.key_y, layout.btn_stop_width, layout.key_height);
const next_key = rect(layout.next_x, layout.key_y, layout.btn_next_width, layout.key_height);
const pl_key = rect(layout.pl_x, layout.key_y, layout.btn_pl_width, layout.key_height);
const transport_well = rect(layout.transport_well_x, layout.well_y, layout.transport_well_width, layout.well_height);

// Chrome-only decoration bands, snapped to the chassis grid: the bottom
// strip between the transport row and the window edge carries the four
// screws' lower pair and the ridged grip band, both centered in it.
const bottom_band_center: f32 = (layout.transport_y + layout.transport_height + H) / 2; // 258
/// Screw centers: hard against the chassis edges horizontally (one grid
/// unit of enamel between screw rim and window edge — real rack ears
/// bolt at the extremes, not at the glass line), centered in the top
/// strip (cap band to glass) and the bottom band vertically.
const screw_radius: f32 = 4;
const screw_left_x: f32 = layout.grid + screw_radius; // 8
const screw_right_x: f32 = W - layout.grid - screw_radius; // 504
const screw_top_y: f32 = (layout.cap_height + layout.row1_y) / 2; // 36
const screw_bottom_y: f32 = bottom_band_center; // 258
/// The ridge band runs between the screws with a clear grid gap.
const ridge_x0: f32 = screw_left_x + screw_radius + layout.grid * 2; // 20
const ridge_x1: f32 = screw_right_x - screw_radius - layout.grid * 2; // 492
const ridge_pitch: f32 = 3;
const ridge_y0: f32 = bottom_band_center - (ridge_pitch * (ridge_pairs - 1) + 1) / 2; // 254.5

/// The volume knob's center: the middle of the volume slider's frame
/// (layout.knob_*), which is also the middle of the volume well band.
const knob_cx: f32 = layout.knob_x + layout.knob_width / 2;
const knob_cy: f32 = layout.transport_y + layout.transport_height / 2;
const knob_radius: f32 = layout.knob_size / 2; // 17

// ------------------------------------------------------------- build

pub fn build(model: *const Model, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    _ = size; // fixed window: the machining is absolute geometry
    const hc = model.appearance.high_contrast;
    try buildPrefix(builder, tokens, hc);
    try buildSuffix(model, builder, tokens, hc);
}

fn buildPrefix(builder: *canvas.Builder, tokens: canvas.DesignTokens, hc: bool) anyerror!void {
    // Chassis fill, then the warm enamel faceplate gradient.
    try builder.fillRect(.{ .rect = rect(0, 0, W, H), .fill = .{ .color = if (hc) tokens.colors.background else chassis } });
    const faceplate = rect(0, layout.cap_height, W, H - layout.cap_height);
    try builder.fillRect(.{ .rect = faceplate, .fill = if (hc) .{ .color = tokens.colors.surface } else .{ .linear_gradient = .{
        .start = point(0, faceplate.y),
        .end = point(0, H),
        .stops = &faceplate_stops,
    } } });

    // The enamel grain: a sparse comb of near-invisible warm hairlines
    // across the faceplate — texture by honest means (no bitmap skin
    // assets anywhere in this app).
    const grain_pitch = (H - layout.cap_height - 12) / @as(f32, @floatFromInt(grain_lines - 1));
    for (0..grain_lines) |index| {
        const y = layout.cap_height + 6 + @as(f32, @floatFromInt(index)) * grain_pitch;
        try hline(builder, 2, W - 2, y, if (hc) transparent else grain, 1);
    }

    // The cap band: lighter enamel with a catch-light on its top edge
    // and a hard shadow under it — the band reads as its own plate.
    try builder.fillRect(.{ .rect = rect(0, 0, W, layout.cap_height), .fill = if (hc) .{ .color = tokens.colors.surface } else .{ .linear_gradient = .{
        .start = point(0, 0),
        .end = point(0, layout.cap_height),
        .stops = &cap_stops,
    } } });
    try hline(builder, 0, W, 0.5, if (hc) tokens.colors.border else bevel_light, 1);
    try hline(builder, 0, W, layout.cap_height + 0.5, if (hc) tokens.colors.border else bevel_shadow, 1);

    // No brand plate: the D E C K stamp (a widget paragraph in the cap
    // band's flow) prints directly on the band's enamel — lettering on
    // the finish, nothing raised, nothing boxed.

    // Window outer bevel: the whole device is one raised plate.
    try bevelOut(builder, rect(0, 0, W, H), tokens, hc);

    // The ridged grip band, centered in the bottom strip between the
    // screws (it stops a clear grid gap short of each).
    var ridge: f32 = ridge_y0;
    for (0..ridge_pairs) |_| {
        try hline(builder, ridge_x0, ridge_x1, ridge, if (hc) transparent else ridge_light, 1);
        try hline(builder, ridge_x0, ridge_x1, ridge + 1, if (hc) transparent else ridge_dark, 1);
        ridge += ridge_pitch;
    }

    // Corner screws: flush with the glass bays' outer edges, centered
    // in the top strip and the bottom band — clear of the glass frames,
    // the wells, and the ridge band.
    try screw(builder, screw_left_x, screw_top_y, hc);
    try screw(builder, screw_right_x, screw_top_y, hc);
    try screw(builder, screw_left_x, screw_bottom_y, hc);
    try screw(builder, screw_right_x, screw_bottom_y, hc);

    // The ONE inset well: the five-key transport cluster sits in a
    // recessed pocket, like keys machined into the panel. The volume
    // block gets no pocket — the knob rides the open enamel.
    try insetWell(builder, transport_well, tokens, hc);
}

fn buildSuffix(model: *const Model, builder: *canvas.Builder, tokens: canvas.DesignTokens, hc: bool) anyerror!void {
    // Inset bevels: both glass bays and the seek fader are recessed
    // into the enamel.
    try bevelIn(builder, display_rect, tokens, hc);
    try bevelIn(builder, art_rect, tokens, hc);
    try bevelIn(builder, seek_rect, tokens, hc);

    // Scanlines over the printing glass (the art bay keeps clear glass:
    // it shows a photograph, not phosphor). Over the spectrum chart the
    // lines double as the classic segmented-ladder look — real bars,
    // honestly segmented by the glass in front of them.
    try scanlines(builder, display_rect, glass_scanlines, hc);

    // Diagonal glare wash: light falls across the glass from top-left.
    try glareWash(builder, display_rect, hc);
    try glareWash(builder, art_rect, hc);

    // The seven-segment elapsed readout on the display's clear glass.
    try segmentReadout(model, builder, tokens, hc);

    // The analog volume knob over the volume slider.
    try volumeKnob(model, builder, tokens, hc);

    // Raised bevel edges on the sculpted keys: the cap band's window
    // keys (the chromeless window's own close/minimize controls), the
    // transport cluster, and the PL toggle.
    try bevelOut(builder, close_key, tokens, hc);
    try bevelOut(builder, min_key, tokens, hc);
    try bevelOut(builder, prev_key, tokens, hc);
    try bevelOut(builder, play_key, tokens, hc);
    try bevelOut(builder, pause_key, tokens, hc);
    try bevelOut(builder, stop_key, tokens, hc);
    try bevelOut(builder, next_key, tokens, hc);
    try bevelOut(builder, pl_key, tokens, hc);
}

// ------------------------------------------------------------ helpers

fn point(x: f32, y: f32) geometry.PointF {
    return geometry.PointF.init(x, y);
}

fn hline(builder: *canvas.Builder, x0: f32, x1: f32, y: f32, color: Color, width: f32) anyerror!void {
    try builder.drawLine(.{ .from = point(x0, y), .to = point(x1, y), .stroke = .{ .fill = .{ .color = color }, .width = width } });
}

/// Raised edge: light catches the top and left, shadow falls bottom and
/// right. 4 commands.
fn bevelOut(builder: *canvas.Builder, r: geometry.RectF, tokens: canvas.DesignTokens, hc: bool) anyerror!void {
    const light = if (hc) tokens.colors.border else bevel_light;
    const shadow = if (hc) tokens.colors.border else bevel_shadow;
    const x1 = r.x + r.width;
    const y1 = r.y + r.height;
    try builder.drawLine(.{ .from = point(r.x, r.y + 0.5), .to = point(x1, r.y + 0.5), .stroke = .{ .fill = .{ .color = light }, .width = 1 } });
    try builder.drawLine(.{ .from = point(r.x + 0.5, r.y), .to = point(r.x + 0.5, y1), .stroke = .{ .fill = .{ .color = light }, .width = 1 } });
    try builder.drawLine(.{ .from = point(r.x, y1 - 0.5), .to = point(x1, y1 - 0.5), .stroke = .{ .fill = .{ .color = shadow }, .width = 1 } });
    try builder.drawLine(.{ .from = point(x1 - 0.5, r.y), .to = point(x1 - 0.5, y1), .stroke = .{ .fill = .{ .color = shadow }, .width = 1 } });
}

/// Recessed edge: the inverse — shadow on top/left, light on the bottom
/// lip. 4 commands.
fn bevelIn(builder: *canvas.Builder, r: geometry.RectF, tokens: canvas.DesignTokens, hc: bool) anyerror!void {
    const light = if (hc) tokens.colors.border else bevel_light;
    const shadow = if (hc) tokens.colors.border else bevel_shadow;
    const x1 = r.x + r.width;
    const y1 = r.y + r.height;
    try builder.drawLine(.{ .from = point(r.x, r.y + 0.5), .to = point(x1, r.y + 0.5), .stroke = .{ .fill = .{ .color = shadow }, .width = 1 } });
    try builder.drawLine(.{ .from = point(r.x + 0.5, r.y), .to = point(r.x + 0.5, y1), .stroke = .{ .fill = .{ .color = shadow }, .width = 1 } });
    try builder.drawLine(.{ .from = point(r.x, y1 - 0.5), .to = point(x1, y1 - 0.5), .stroke = .{ .fill = .{ .color = light }, .width = 1 } });
    try builder.drawLine(.{ .from = point(x1 - 0.5, r.y), .to = point(x1 - 0.5, y1), .stroke = .{ .fill = .{ .color = light }, .width = 1 } });
}

/// Recessed pocket: darker enamel fill + inset bevel. 5 commands.
fn insetWell(builder: *canvas.Builder, r: geometry.RectF, tokens: canvas.DesignTokens, hc: bool) anyerror!void {
    try builder.fillRect(.{ .rect = r, .fill = .{ .color = if (hc) tokens.colors.background else well } });
    try bevelIn(builder, r, tokens, hc);
}

/// One recessed screw: steel disc, slot, and a catch-light. 3 commands.
fn screw(builder: *canvas.Builder, cx: f32, cy: f32, hc: bool) anyerror!void {
    const r: f32 = screw_radius;
    try builder.fillRoundedRect(.{ .rect = rect(cx - r, cy - r, r * 2, r * 2), .radius = canvas.Radius.all(r), .fill = if (hc) .{ .color = transparent } else .{ .linear_gradient = .{
        .start = point(cx - r, cy - r),
        .end = point(cx + r, cy + r),
        .stops = &screw_stops,
    } } });
    try builder.drawLine(.{ .from = point(cx - 2.5, cy + 2.5), .to = point(cx + 2.5, cy - 2.5), .stroke = .{ .fill = .{ .color = if (hc) transparent else bevel_shadow }, .width = 1.3 } });
    try builder.drawLine(.{ .from = point(cx - 2, cy - 3), .to = point(cx + 0.5, cy - 3.8), .stroke = .{ .fill = .{ .color = if (hc) transparent else bevel_light }, .width = 1 } });
}

fn scanlines(builder: *canvas.Builder, r: geometry.RectF, count: usize, hc: bool) anyerror!void {
    const pitch = r.height / @as(f32, @floatFromInt(count));
    for (0..count) |index| {
        const y = r.y + (@as(f32, @floatFromInt(index)) + 0.5) * pitch;
        try hline(builder, r.x + 1, r.x + r.width - 1, y, if (hc) transparent else scanline, 1);
    }
}

fn glareWash(builder: *canvas.Builder, r: geometry.RectF, hc: bool) anyerror!void {
    try builder.fillRect(.{ .rect = r, .fill = .{ .linear_gradient = .{
        .start = point(r.x, r.y),
        .end = point(r.x + r.width * 0.7, r.y + r.height),
        .stops = if (hc) &hc_stops else &glare_stops,
    } } });
}

// ------------------------------------------------------- volume knob

/// The analog volume knob: drawn OVER the volume slider widget (the
/// slider is the real control — drag, arrow keys, automation, focus
/// ring — and the knob is its analog face). The position dot's angle
/// derives from the same `volume_fraction` the slider syncs into the
/// model, sweeping 270 degrees from min (down-left) to max
/// (down-right) like every amplifier dial ever cast.
fn volumeKnob(model: *const Model, builder: *canvas.Builder, tokens: canvas.DesignTokens, hc: bool) anyerror!void {
    const r = knob_radius;
    // Position ticks at 0/25/50/75/100 percent, engraved on the chassis
    // enamel around the knob (part of the dial, not an enclosure).
    for (0..knob_ticks) |index| {
        const fraction = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(knob_ticks - 1));
        const theta = knobAngle(fraction);
        try builder.drawLine(.{
            .from = point(knob_cx + @cos(theta) * (r - 1), knob_cy + @sin(theta) * (r - 1)),
            .to = point(knob_cx + @cos(theta) * (r + 2), knob_cy + @sin(theta) * (r + 2)),
            .stroke = .{ .fill = .{ .color = if (hc) transparent else bevel_shadow }, .width = 1 },
        });
    }
    // A cover over the slider's own track and thumb: the slider stays
    // the live control underneath (hits, focus, keys), but the knob is
    // the only thing the eye gets. The fill re-plots the faceplate
    // gradient over the faceplate's own y-range (the rect clips it), so
    // the patch is byte-identical to the enamel behind it — the knob
    // sits directly on the chassis, no well, no box. High contrast
    // keeps the cover transparent so the stock slider shows honestly.
    try builder.fillRect(.{ .rect = rect(layout.knob_x, layout.key_y, layout.knob_width, layout.key_height), .fill = if (hc) .{ .color = transparent } else .{ .linear_gradient = .{
        .start = point(0, layout.cap_height),
        .end = point(0, H),
        .stops = &faceplate_stops,
    } } });
    // The dark rim ring, then the enamel face lit from the top.
    try builder.fillRoundedRect(.{ .rect = rect(knob_cx - r, knob_cy - r, r * 2, r * 2), .radius = canvas.Radius.all(r), .fill = .{ .color = if (hc) tokens.colors.border else knob_rim } });
    const face = r - 2;
    try builder.fillRoundedRect(.{ .rect = rect(knob_cx - face, knob_cy - face, face * 2, face * 2), .radius = canvas.Radius.all(face), .fill = if (hc) .{ .color = tokens.colors.surface } else .{ .linear_gradient = .{
        .start = point(knob_cx, knob_cy - face),
        .end = point(knob_cx, knob_cy + face),
        .stops = &knob_stops,
    } } });
    // The position dot with a phosphor glow halo (transparent in high
    // contrast; the dot itself flips to the text color).
    const theta = knobAngle(std.math.clamp(model.volume_fraction, 0, 1));
    const dot_r: f32 = 2.2;
    const dot_x = knob_cx + @cos(theta) * (face - 4.5);
    const dot_y = knob_cy + @sin(theta) * (face - 4.5);
    try builder.fillRoundedRect(.{ .rect = rect(dot_x - dot_r - 1.5, dot_y - dot_r - 1.5, (dot_r + 1.5) * 2, (dot_r + 1.5) * 2), .radius = canvas.Radius.all(dot_r + 1.5), .fill = .{ .color = if (hc) transparent else seg_glow } });
    try builder.fillRoundedRect(.{ .rect = rect(dot_x - dot_r, dot_y - dot_r, dot_r * 2, dot_r * 2), .radius = canvas.Radius.all(dot_r), .fill = .{ .color = if (hc) tokens.colors.text else seg_lit } });
}

/// The dial sweep in y-down screen radians: fraction 0 sits down-left
/// (135 degrees), fraction 1 down-right (405 == 45 degrees), turning
/// clockwise through the top.
fn knobAngle(fraction: f32) f32 {
    const degrees = 135.0 + fraction * 270.0;
    return degrees * std.math.pi / 180.0;
}

// ----------------------------------------------------- seven-segment

// Segment order: A top, B top-right, C bottom-right, D bottom, E
// bottom-left, F top-left, G middle. Classic sheared display, sized for
// the display bay's clear glass (`layout.segment_area_width`).
const digit_width: f32 = 18;
const digit_height: f32 = 28;
const seg_thickness: f32 = 3.8;
const digit_gap: f32 = 6;
const colon_width: f32 = 8;
const shear: f32 = 0.09;
pub const readout_width: f32 = digit_width * 3 + digit_gap * 3 + colon_width;
/// The shear leans the glyph box right of x0+readout_width by this much
/// at its top row; the centering math folds it in so the leaned readout
/// sits optically centered in the clear glass.
const shear_reach: f32 = digit_height * shear;

const segments_for_digit = [10][7]bool{
    .{ true, true, true, true, true, true, false }, // 0
    .{ false, true, true, false, false, false, false }, // 1
    .{ true, true, false, true, true, false, true }, // 2
    .{ true, true, true, true, false, false, true }, // 3
    .{ false, true, true, false, false, true, true }, // 4
    .{ true, false, true, true, false, true, true }, // 5
    .{ true, false, true, true, true, true, true }, // 6
    .{ true, true, true, false, false, false, false }, // 7
    .{ true, true, true, true, true, true, true }, // 8
    .{ true, true, true, true, false, true, true }, // 9
};

/// Path storage referenced by the display list until the runtime's
/// deep copy at install (single canvas, UI-thread builds only).
var ghost_paths: [3][7][7]canvas.PathElement = undefined;
var lit_paths: [3][7][7]canvas.PathElement = undefined;

fn segmentReadout(model: *const Model, builder: *canvas.Builder, tokens: canvas.DesignTokens, hc: bool) anyerror!void {
    // Dead-centered in the clear glass the display reserves at its
    // top-left: vertically in the display's top row (the spectrum chart
    // rides beside it), horizontally in the segment area (accounting
    // for the shear lean).
    const x0 = display_rect.x + layout.glass_inset + (layout.segment_area_width - readout_width - shear_reach) / 2;
    const y0 = display_rect.y + layout.glass_inset + (layout.display_top_row_height - digit_height) / 2;

    // Digits: M : S S. Idle shows dashes (G segments), the classic
    // no-signal readout.
    const elapsed_s = model.elapsed_ms / 1000;
    const idle = model.now == null;
    const digits = [3]?u8{
        if (idle) null else @intCast(@min(9, elapsed_s / 60)),
        if (idle) null else @intCast((elapsed_s % 60) / 10),
        if (idle) null else @intCast(elapsed_s % 10),
    };
    const digit_x = [3]f32{
        x0,
        x0 + digit_width + digit_gap + colon_width + digit_gap,
        x0 + digit_width * 2 + digit_gap * 2 + colon_width + digit_gap,
    };

    const ghost = if (hc) transparent else seg_ghost;
    const lit = if (hc) tokens.colors.text else seg_lit;
    const glow = if (hc) transparent else seg_glow;

    for (digits, digit_x, 0..) |digit, dx, slot| {
        for (0..7) |seg| {
            const on = if (digit) |d| segments_for_digit[d][seg] else seg == 6;
            // Ghost pass: every segment, always on-screen.
            segmentPath(&ghost_paths[slot][seg], dx, y0, @intCast(seg), 0);
            try builder.fillPath(.{ .elements = &ghost_paths[slot][seg], .fill = .{ .color = ghost } });
            // Glow + lit passes: offscreen when the segment is dark.
            const shift: f32 = if (on) 0 else offscreen;
            segmentPath(&lit_paths[slot][seg], dx, y0, @intCast(seg), shift);
            try builder.strokePath(.{ .elements = &lit_paths[slot][seg], .stroke = .{ .fill = .{ .color = glow }, .width = 3.2 } });
            try builder.fillPath(.{ .elements = &lit_paths[slot][seg], .fill = .{ .color = lit } });
        }
    }

    // Colon: two square dots, ghost + glow + lit (lit hidden when idle).
    const cx = x0 + digit_width + digit_gap + shearAt(y0, y0 + digit_height * 0.5);
    const dot_shift: f32 = if (idle) offscreen else 0;
    const dot_ys = [2]f32{ y0 + digit_height * 0.30, y0 + digit_height * 0.64 };
    for (dot_ys) |dy| {
        try builder.fillRect(.{ .rect = rect(cx, dy, 3.5, 3.5), .fill = .{ .color = ghost } });
        try builder.strokeRect(.{ .rect = rect(cx + dot_shift, dy, 3.5, 3.5), .stroke = .{ .fill = .{ .color = glow }, .width = 2.6 } });
        try builder.fillRect(.{ .rect = rect(cx + dot_shift, dy, 3.5, 3.5), .fill = .{ .color = lit } });
    }
}

fn shearAt(y0: f32, y: f32) f32 {
    // Positive shear leans the display to the right, like every
    // segment display ever.
    return (y0 + digit_height - y) * shear;
}

/// Writes one segment's sheared hexagon into `out` (7 elements:
/// move + 5 lines + close).
fn segmentPath(out: *[7]canvas.PathElement, dx: f32, dy: f32, segment: u3, shift: f32) void {
    const t = seg_thickness;
    const ht = t / 2;
    const w = digit_width;
    const h = digit_height;
    // Segment center-lines in unsheared digit space.
    var horizontal = true;
    var cx: f32 = w / 2;
    var cy: f32 = 0;
    var half: f32 = w / 2 - ht - 0.6;
    switch (segment) {
        0 => cy = ht, // A
        1 => {
            horizontal = false;
            cx = w - ht;
            cy = h * 0.25 + ht * 0.5;
            half = h * 0.25 - ht - 0.6;
        }, // B
        2 => {
            horizontal = false;
            cx = w - ht;
            cy = h * 0.75 - ht * 0.5;
            half = h * 0.25 - ht - 0.6;
        }, // C
        3 => cy = h - ht, // D
        4 => {
            horizontal = false;
            cx = ht;
            cy = h * 0.75 - ht * 0.5;
            half = h * 0.25 - ht - 0.6;
        }, // E
        5 => {
            horizontal = false;
            cx = ht;
            cy = h * 0.25 + ht * 0.5;
            half = h * 0.25 - ht - 0.6;
        }, // F
        6 => cy = h / 2, // G
        7 => unreachable,
    }

    var points: [6][2]f32 = undefined;
    if (horizontal) {
        points = .{
            .{ cx - half, cy },
            .{ cx - half + ht, cy - ht },
            .{ cx + half - ht, cy - ht },
            .{ cx + half, cy },
            .{ cx + half - ht, cy + ht },
            .{ cx - half + ht, cy + ht },
        };
    } else {
        points = .{
            .{ cx, cy - half },
            .{ cx + ht, cy - half + ht },
            .{ cx + ht, cy + half - ht },
            .{ cx, cy + half },
            .{ cx - ht, cy + half - ht },
            .{ cx - ht, cy - half + ht },
        };
    }

    for (points, 0..) |p, index| {
        const sheared_x = dx + p[0] + (h - p[1]) * shear + shift;
        const y = dy + p[1];
        out[index] = .{
            .verb = if (index == 0) .move_to else .line_to,
            .points = .{ point(sheared_x, y), point(0, 0), point(0, 0) },
        };
    }
    out[6] = .{ .verb = .close };
}
