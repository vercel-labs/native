//! deck chrome: the sculpted hardware layer, drawn through the sanctioned
//! `ChromeOptions` display-list pass (`UiApp.chrome`) — the same seam the
//! gpu-dashboard example uses for its hero gradient, pushed to the
//! Winamp-era extreme on a SMALL, FIXED window (460x180, resizable =
//! false), so every coordinate below is absolute machining:
//!
//!   prefix (behind the widgets): the chassis fill, the AI-generated
//!   brushed-plate texture (one `draw_image` of a registered 256x256
//!   asset under everything — the texture supports the chassis feel, the
//!   machining stays vector), the faceplate gradient, the gold cap band
//!   (the window's drag region wears it as a titlebar), outer bevels, a
//!   ridged grip band, corner screws, and inset control wells behind the
//!   transport cluster and the output block;
//!
//!   suffix (in front of the widgets): inset bevel frames around the VFD,
//!   the spectrum, and the seek fader, CRT scanlines and a diagonal glare
//!   wash over the glass, raised bevel edges on the three transport keys
//!   and the PL key, and a seven-segment elapsed readout drawn as sheared
//!   hexagon paths — ghost segments always visible (VFD ghosting), lit
//!   segments doubled with a translucent glow stroke.
//!
//! The chrome contract requires an EXACT command count per build, so
//! every section emits a fixed number of commands regardless of model
//! state: state-dependent marks (lit segments, the texture before its
//! image registers) are drawn offscreen when hidden instead of skipped.
//! The counts are module constants and the test suite rebuilds the chrome
//! across model states to hold them.
//!
//! Path elements and gradient stops are captured by reference until the
//! runtime deep-copies the display list at install, so runtime-computed
//! segment paths live in file-scope storage (single canvas, UI-thread
//! builds only) and gradient stops are comptime constants.
//!
//! High contrast keeps the layout of the pass (same counts) but drops
//! the decoration: the texture moves offscreen, gold and glare and
//! scanlines go transparent, bevels fall back to the border token, and
//! the segment readout uses the high-contrast text color.

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

const glass_scanlines: usize = 20;
const screw_commands: usize = 3;
const ridge_pairs = 3; // comptime_int: used in both command counts and f32 machining

pub const prefix_commands: usize =
    1 + // chassis fill
    1 + // brushed-plate texture (draw_image; offscreen until registered)
    1 + // faceplate gradient
    3 + // gold cap band (fill + top catch-light + bottom shadow)
    4 + // window outer bevel
    ridge_pairs * 2 + // ridged grip band above the bottom edge
    4 * screw_commands + // corner screws
    5 + // transport well (fill + inset bevel)
    5; // output well (fill + inset bevel)

pub const suffix_commands: usize =
    4 + 4 + 4 + // VFD + spectrum + seek inset bevels
    glass_scanlines * 2 + // VFD + spectrum scanlines
    2 + // glass glare washes (VFD, spectrum)
    segment_commands + // seven-segment elapsed readout
    4 * 4; // raised bevels: prev, play, next, PL

const segment_commands: usize = 3 * 21 + 6; // 3 digits x (ghost+glow+lit) + colon

// ---------------------------------------------------------- palette

// Decorative chrome colors live here (they are machining, not theme
// tokens); the phosphor family comes from the theme so the readout and
// the widgets stay one hue.
const chassis = Color.rgb8(9, 11, 10);
const faceplate_top = Color.rgb8(27, 33, 30);
const faceplate_bottom = Color.rgb8(13, 16, 14);
const bevel_light = Color.rgba8(255, 255, 255, 36);
const bevel_shadow = Color.rgba8(0, 0, 0, 170);
const ridge_light = Color.rgba8(255, 255, 255, 30);
const ridge_dark = Color.rgba8(0, 0, 0, 160);
const scanline = Color.rgba8(0, 0, 0, 44);
const glare = Color.rgba8(255, 255, 255, 8);
const gold_hi = Color.rgb8(224, 188, 110);
const gold_mid = Color.rgb8(166, 130, 64);
const gold_low = Color.rgb8(100, 76, 36);
const steel = Color.rgb8(52, 60, 54);
const steel_dark = Color.rgb8(18, 22, 20);
const well = Color.rgb8(11, 14, 12);
const transparent = Color.rgba8(0, 0, 0, 0);

const seg_lit = theme.phosphor;
const seg_ghost = Color.rgba8(54, 226, 138, 24);
const seg_glow = Color.rgba8(54, 226, 138, 60);

/// The brushed-plate texture rides UNDER the machining at reduced
/// opacity: it tones the gradient, it never reads as an image.
const plate_texture_opacity: f32 = 0.5;

const faceplate_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = faceplate_top },
    .{ .offset = 1, .color = faceplate_bottom },
};
const gold_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = gold_hi },
    .{ .offset = 0.45, .color = gold_mid },
    .{ .offset = 1, .color = gold_low },
};
const glare_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = glare },
    .{ .offset = 1, .color = transparent },
};
const screw_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = steel },
    .{ .offset = 1, .color = steel_dark },
};
const hc_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = transparent },
    .{ .offset = 1, .color = transparent },
};

// ------------------------------------------------------------ geometry
// Absolute machining on the fixed 460x180 chassis. Every rect below is
// spelled from the layout table (layout.zig) — the same constants the
// widget views flow — so the metalwork hugs the widgets by construction.

const W: f32 = layout.window_width;
const H: f32 = layout.window_height;

fn rect(x: f32, y: f32, w: f32, h: f32) geometry.RectF {
    return geometry.RectF.init(x, y, w, h);
}

/// Offscreen displacement for fixed-count commands that are hidden in
/// the current model state.
const offscreen: f32 = 100_000;

const vfd_rect = rect(layout.pad, layout.row1_y, layout.vfd_width, layout.row1_height);
const spectrum_rect = rect(layout.pad + layout.vfd_width + layout.gap, layout.row1_y, layout.spectrum_width, layout.row1_height);
const seek_rect = rect(layout.pad, layout.seek_y, W - layout.pad * 2, layout.seek_height);
const prev_key = rect(layout.prev_x, layout.key_y, layout.btn_prev_width, layout.key_height);
const play_key = rect(layout.play_x, layout.key_y, layout.btn_play_width, layout.key_height);
const next_key = rect(layout.next_x, layout.key_y, layout.btn_next_width, layout.key_height);
const pl_key = rect(layout.pl_x, layout.key_y, layout.btn_pl_width, layout.key_height);
const transport_well = rect(layout.transport_well_x, layout.well_y, layout.transport_well_width, layout.well_height);
const output_well = rect(layout.output_well_x, layout.well_y, layout.output_well_width, layout.well_height);

// Chrome-only decoration bands, snapped to the chassis grid: the bottom
// strip between the transport row and the window edge carries the four
// screws' lower pair and the ridged grip band, both centered in it.
const bottom_band_center: f32 = (layout.transport_y + layout.transport_height + H) / 2; // 174
/// Screw centers: flush with the glass panels' outer edges horizontally,
/// centered in the top strip (cap band to glass) and the bottom band.
const screw_radius: f32 = 4;
const screw_left_x: f32 = layout.pad + screw_radius; // 16
const screw_right_x: f32 = W - layout.pad - screw_radius; // 444
const screw_top_y: f32 = (layout.cap_height + layout.row1_y) / 2; // 34
const screw_bottom_y: f32 = bottom_band_center; // 174
/// The ridge band runs between the screws with a clear grid gap.
const ridge_x0: f32 = screw_left_x + screw_radius + layout.grid * 2; // 28
const ridge_x1: f32 = screw_right_x - screw_radius - layout.grid * 2; // 432
const ridge_pitch: f32 = 3;
const ridge_y0: f32 = bottom_band_center - (ridge_pitch * (ridge_pairs - 1) + 1) / 2; // 170.5

// ------------------------------------------------------------- build

pub fn build(model: *const Model, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    _ = size; // fixed window: the machining is absolute geometry
    const hc = model.appearance.high_contrast;
    try buildPrefix(model, builder, tokens, hc);
    try buildSuffix(model, builder, tokens, hc);
}

fn buildPrefix(model: *const Model, builder: *canvas.Builder, tokens: canvas.DesignTokens, hc: bool) anyerror!void {
    // Chassis fill, then the machined faceplate gradient.
    try builder.fillRect(.{ .rect = rect(0, 0, W, H), .fill = .{ .color = if (hc) tokens.colors.background else chassis } });
    const faceplate = rect(0, layout.cap_height, W, H - layout.cap_height);
    try builder.fillRect(.{ .rect = faceplate, .fill = if (hc) .{ .color = tokens.colors.surface } else .{ .linear_gradient = .{
        .start = point(0, faceplate.y),
        .end = point(0, H),
        .stops = &faceplate_stops,
    } } });

    // The brushed-plate texture over the gradient at reduced opacity —
    // real grain where v1 faked 170 hairlines. Offscreen until the boot
    // effect registers the image (and in high contrast).
    const texture_shift: f32 = if (hc or model.texture_plate == 0) offscreen else 0;
    try builder.drawImage(.{
        .image_id = model.texture_plate,
        .dst = faceplate.translate(geometry.OffsetF.init(texture_shift, 0)),
        .opacity = plate_texture_opacity,
        .fit = .cover,
    });

    // The gold cap band: the window's titlebar, machined. A catch-light
    // on its top edge, a hard shadow under it.
    try builder.fillRect(.{ .rect = rect(0, 0, W, layout.cap_height), .fill = if (hc) .{ .color = tokens.colors.surface } else .{ .linear_gradient = .{
        .start = point(0, 0),
        .end = point(0, layout.cap_height),
        .stops = &gold_stops,
    } } });
    try hline(builder, 0, W, 0.5, if (hc) tokens.colors.border else Color.rgba8(255, 236, 190, 90), 1);
    try hline(builder, 0, W, layout.cap_height + 0.5, if (hc) tokens.colors.border else bevel_shadow, 1);

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

    // Corner screws: flush with the glass panels' outer edges, centered
    // in the top strip and the bottom band — clear of the glass frames,
    // the wells, and the ridge band.
    try screw(builder, screw_left_x, screw_top_y, hc);
    try screw(builder, screw_right_x, screw_top_y, hc);
    try screw(builder, screw_left_x, screw_bottom_y, hc);
    try screw(builder, screw_right_x, screw_bottom_y, hc);

    // Inset wells: the transport cluster and the output block sit in
    // recessed pockets, like keys machined into the panel.
    try insetWell(builder, transport_well, tokens, hc);
    try insetWell(builder, output_well, tokens, hc);
}

fn buildSuffix(model: *const Model, builder: *canvas.Builder, tokens: canvas.DesignTokens, hc: bool) anyerror!void {
    // Inset bevels: every glass is recessed into the faceplate.
    try bevelIn(builder, vfd_rect, tokens, hc);
    try bevelIn(builder, spectrum_rect, tokens, hc);
    try bevelIn(builder, seek_rect, tokens, hc);

    // CRT scanlines over the glass.
    try scanlines(builder, vfd_rect, glass_scanlines, hc);
    try scanlines(builder, spectrum_rect, glass_scanlines, hc);

    // Diagonal glare wash: light falls across the glass from top-left.
    try glareWash(builder, vfd_rect, hc);
    try glareWash(builder, spectrum_rect, hc);

    // The seven-segment elapsed readout on the VFD's clear glass.
    try segmentReadout(model, builder, tokens, hc);

    // Raised bevel edges on the sculpted keys.
    try bevelOut(builder, prev_key, tokens, hc);
    try bevelOut(builder, play_key, tokens, hc);
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

/// Recessed pocket: dark fill + inset bevel. 5 commands.
fn insetWell(builder: *canvas.Builder, r: geometry.RectF, tokens: canvas.DesignTokens, hc: bool) anyerror!void {
    try builder.fillRect(.{ .rect = r, .fill = .{ .color = if (hc) tokens.colors.background else well } });
    try bevelIn(builder, r, tokens, hc);
}

/// One machined screw: steel disc, slot, and a catch-light. 3 commands.
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

// ----------------------------------------------------- seven-segment

// Segment order: A top, B top-right, C bottom-right, D bottom, E
// bottom-left, F top-left, G middle. Classic sheared display, sized for
// the small VFD's clear glass (`layout.segment_area_width`).
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
    // Dead-centered in the clear glass the VFD reserves at its left:
    // vertically in the full glass height, horizontally in the segment
    // area (accounting for the shear lean).
    const x0 = vfd_rect.x + layout.glass_inset + (layout.segment_area_width - readout_width - shear_reach) / 2;
    const y0 = vfd_rect.y + (layout.row1_height - digit_height) / 2;

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
    // Positive shear leans the display to the right, like every VFD ever.
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
