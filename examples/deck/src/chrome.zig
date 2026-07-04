//! deck chrome: the sculpted hardware layer, drawn through the sanctioned
//! `ChromeOptions` display-list pass (`UiApp.chrome`) — the same seam the
//! gpu-dashboard example uses for its hero gradient, pushed to the
//! Winamp-era extreme:
//!
//!   prefix (behind the widgets): brushed chassis texture (fine repeated
//!   vertical hairlines), the machined faceplate gradient with a gold
//!   cap band, outer bevels, a ridged grip band, corner screws, the gold
//!   brand plate, and inset control wells behind the transport cluster
//!   and the output block;
//!
//!   suffix (in front of the widgets): inset bevel frames around every
//!   glass (VFD, spectrum, ledger, PERF analyzer), CRT scanlines and a
//!   diagonal glare wash over the glass, raised bevel edges on the three
//!   transport keys, the status-strip ridge with its screws, and a
//!   seven-segment elapsed readout drawn as sheared hexagon paths —
//!   ghost segments always visible (VFD ghosting), lit segments doubled
//!   with a translucent glow stroke.
//!
//! The chrome contract requires an EXACT command count per build, so
//! every section emits a fixed number of commands regardless of model
//! state: state-dependent marks (lit segments, the PERF-face frames)
//! are drawn offscreen when hidden instead of skipped. The counts are
//! module constants and the test suite rebuilds the chrome across model
//! states to hold them.
//!
//! Path elements and gradient stops are captured by reference until the
//! runtime deep-copies the display list at install, so runtime-computed
//! segment paths live in file-scope storage (single canvas, UI-thread
//! builds only) and gradient stops are comptime constants.
//!
//! High contrast keeps the layout of the pass (same counts) but drops
//! the decoration: textures, gold, glare, and scanlines go transparent,
//! bevels fall back to the border token, and the segment readout uses
//! the high-contrast text color.

const std = @import("std");
const native_sdk = @import("native_sdk");
const model_mod = @import("model.zig");
const theme = @import("theme.zig");
const view = @import("view.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Color = canvas.Color;
const Model = model_mod.Model;

// ------------------------------------------------------------- counts

const brush_lines: usize = 170;
const glass_scanlines: usize = 32;
const perf_scanlines: usize = 96;
const screw_commands: usize = 3;

pub const prefix_commands: usize =
    1 + // chassis fill
    brush_lines + // brushed texture
    1 + // faceplate gradient
    2 + // gold cap band (fill + shadow line)
    4 + // faceplate outer bevel
    8 + // ridged grip band (4 light/dark pairs)
    4 * screw_commands + // faceplate corner screws
    5 + // gold brand plate (fill + bevel)
    5 + // transport well (fill + inset bevel)
    5; // output well (fill + inset bevel)

pub const suffix_commands: usize =
    4 + 4 + // VFD + spectrum inset bevels
    4 + // ledger glass bevel (offscreen on the PERF face)
    4 + // PERF analyzer bevel (offscreen on the library face)
    glass_scanlines * 2 + // VFD + spectrum scanlines
    perf_scanlines + // PERF analyzer scanlines (offscreen on library)
    3 + // glass glare washes (VFD, spectrum, PERF)
    segment_commands + // seven-segment elapsed readout
    3 * 4 + // raised bevels on the three transport keys
    2 + 2 * screw_commands; // status-strip ridge + screws

const segment_commands: usize = 3 * 21 + 6; // 3 digits x (ghost+glow+lit) + colon

// ---------------------------------------------------------- palette

// Decorative chrome colors live here (they are machining, not theme
// tokens); the phosphor family comes from the theme so the readout and
// the widgets stay one hue.
const chassis = Color.rgb8(9, 11, 10);
const brush_light = Color.rgba8(255, 255, 255, 5);
const brush_dark = Color.rgba8(0, 0, 0, 58);
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

fn rect(x: f32, y: f32, w: f32, h: f32) geometry.RectF {
    return geometry.RectF.init(x, y, w, h);
}

/// Offscreen displacement for fixed-count commands that are hidden in
/// the current model state.
const offscreen: f32 = 100_000;

fn vfdRect(size: geometry.SizeF) geometry.RectF {
    const x = view.faceplate_pad + view.brand_width + view.panel_gap;
    return rect(x, view.faceplate_pad, size.width - x - view.panel_gap - view.spectrum_width - view.faceplate_pad, view.row1_height);
}

fn spectrumRect(size: geometry.SizeF) geometry.RectF {
    return rect(size.width - view.faceplate_pad - view.spectrum_width, view.faceplate_pad, view.spectrum_width, view.row1_height);
}

fn ledgerRect(size: geometry.SizeF) geometry.RectF {
    const y = view.faceplate_height;
    return rect(view.rail_width + 1, y, size.width - view.rail_width - 1, size.height - y - view.statusbar_height);
}

fn perfRect(size: geometry.SizeF) geometry.RectF {
    const y = view.faceplate_height + 14;
    return rect(14, y, size.width - 28, size.height - view.statusbar_height - y - 10 - view.perf_queue_height - 14);
}

// ------------------------------------------------------------- build

pub fn build(model: *const Model, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    const hc = model.appearance.high_contrast;
    try buildPrefix(builder, size, tokens, hc);
    try buildSuffix(model, builder, size, tokens, hc);
}

fn buildPrefix(builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens, hc: bool) anyerror!void {
    // Chassis: base fill plus the brushed-metal texture (fine vertical
    // hairlines, alternating light/dark, pitch derived from the width so
    // the fixed line count always covers the window).
    try builder.fillRect(.{ .rect = rect(0, 0, size.width, size.height), .fill = .{ .color = if (hc) tokens.colors.background else chassis } });
    const pitch = size.width / @as(f32, @floatFromInt(brush_lines));
    for (0..brush_lines) |index| {
        const x = (@as(f32, @floatFromInt(index)) + 0.5) * pitch;
        const color = if (hc) transparent else if (index % 2 == 0) brush_dark else brush_light;
        try builder.drawLine(.{ .from = point(x, 0), .to = point(x, size.height), .stroke = .{ .fill = .{ .color = color }, .width = 1 } });
    }

    // The faceplate: machined gradient, gold cap band, outer bevel, and
    // the ridged grip band above its bottom edge.
    const faceplate = rect(0, 0, size.width, view.faceplate_height);
    try builder.fillRect(.{ .rect = faceplate, .fill = if (hc) .{ .color = tokens.colors.surface } else .{ .linear_gradient = .{
        .start = point(0, 0),
        .end = point(0, view.faceplate_height),
        .stops = &faceplate_stops,
    } } });
    try builder.fillRect(.{ .rect = rect(0, 0, size.width, 3), .fill = if (hc) .{ .color = tokens.colors.border } else .{ .linear_gradient = .{
        .start = point(0, 0),
        .end = point(size.width, 0),
        .stops = &gold_stops,
    } } });
    try hline(builder, 0, size.width, 3.5, if (hc) transparent else bevel_shadow, 1);
    try bevelOut(builder, faceplate, tokens, hc);
    var ridge: f32 = 162;
    for (0..4) |_| {
        try hline(builder, 10, size.width - 10, ridge, if (hc) transparent else ridge_light, 1);
        try hline(builder, 10, size.width - 10, ridge + 1, if (hc) transparent else ridge_dark, 1);
        ridge += 3;
    }
    try screw(builder, 12, 13, hc);
    try screw(builder, size.width - 12, 13, hc);
    try screw(builder, 12, 168, hc);
    try screw(builder, size.width - 12, 168, hc);

    // The gold brand plate behind the DECK engraving.
    const brand = rect(view.faceplate_pad, view.faceplate_pad, view.brand_width, 28);
    try builder.fillRect(.{ .rect = brand, .fill = if (hc) .{ .color = tokens.colors.surface } else .{ .linear_gradient = .{
        .start = point(brand.x, brand.y),
        .end = point(brand.x, brand.y + brand.height),
        .stops = &gold_stops,
    } } });
    try bevelOut(builder, brand, tokens, hc);

    // Inset wells: the transport cluster and the output block sit in
    // recessed pockets, like keys machined into the panel.
    try insetWell(builder, rect(8, view.transport_y - 6, 174, view.transport_height + 12), tokens, hc);
    try insetWell(builder, rect(size.width - 206, view.transport_y - 6, 198, view.transport_height + 12), tokens, hc);
}

fn buildSuffix(model: *const Model, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens, hc: bool) anyerror!void {
    const library = model.view == .library;
    const vfd = vfdRect(size);
    const spectrum = spectrumRect(size);
    const ledger = if (library) ledgerRect(size) else ledgerRect(size).translate(geometry.OffsetF.init(offscreen, 0));
    const perf = if (library) perfRect(size).translate(geometry.OffsetF.init(offscreen, 0)) else perfRect(size);

    // Inset bevels: every glass is recessed into the faceplate/chassis.
    try bevelIn(builder, vfd, tokens, hc);
    try bevelIn(builder, spectrum, tokens, hc);
    try bevelIn(builder, ledger, tokens, hc);
    try bevelIn(builder, perf, tokens, hc);

    // CRT scanlines over the faceplate glass and the PERF analyzer; the
    // fixed line count spreads over each glass height.
    try scanlines(builder, vfd, glass_scanlines, hc);
    try scanlines(builder, spectrum, glass_scanlines, hc);
    try scanlines(builder, perf, perf_scanlines, hc);

    // Diagonal glare wash: light falls across the glass from top-left.
    try glareWash(builder, vfd, hc);
    try glareWash(builder, spectrum, hc);
    try glareWash(builder, perf, hc);

    // The seven-segment elapsed readout on the VFD.
    try segmentReadout(model, builder, vfd, tokens, hc);

    // Raised bevel edges on the transport keys (prev / play / next).
    const key_y = view.transport_y;
    try bevelOut(builder, rect(view.faceplate_pad, key_y, view.btn_prev_width, view.transport_height), tokens, hc);
    try bevelOut(builder, rect(view.faceplate_pad + view.btn_prev_width + 10, key_y, view.btn_play_width, view.transport_height), tokens, hc);
    try bevelOut(builder, rect(view.faceplate_pad + view.btn_prev_width + view.btn_play_width + 20, key_y, view.btn_next_width, view.transport_height), tokens, hc);

    // The status strip's ridge and screws.
    try hline(builder, 0, size.width, size.height - 44, if (hc) transparent else ridge_light, 1);
    try hline(builder, 0, size.width, size.height - 43, if (hc) transparent else ridge_dark, 1);
    try screw(builder, 12, size.height - 19, hc);
    try screw(builder, size.width - 12, size.height - 19, hc);
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
    const r: f32 = 4.5;
    try builder.fillRoundedRect(.{ .rect = rect(cx - r, cy - r, r * 2, r * 2), .radius = canvas.Radius.all(r), .fill = if (hc) .{ .color = transparent } else .{ .linear_gradient = .{
        .start = point(cx - r, cy - r),
        .end = point(cx + r, cy + r),
        .stops = &screw_stops,
    } } });
    try builder.drawLine(.{ .from = point(cx - 2.8, cy + 2.8), .to = point(cx + 2.8, cy - 2.8), .stroke = .{ .fill = .{ .color = if (hc) transparent else bevel_shadow }, .width = 1.4 } });
    try builder.drawLine(.{ .from = point(cx - 2.2, cy - 3.4), .to = point(cx + 0.6, cy - 4.2), .stroke = .{ .fill = .{ .color = if (hc) transparent else bevel_light }, .width = 1 } });
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
// bottom-left, F top-left, G middle. Classic sheared display.
const digit_width: f32 = 20;
const digit_height: f32 = 36;
const seg_thickness: f32 = 4.2;
const digit_gap: f32 = 7;
const colon_width: f32 = 8;
const shear: f32 = 0.09;
pub const readout_width: f32 = digit_width * 3 + digit_gap * 3 + colon_width;

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

fn segmentReadout(model: *const Model, builder: *canvas.Builder, vfd: geometry.RectF, tokens: canvas.DesignTokens, hc: bool) anyerror!void {
    const x0 = vfd.x + vfd.width - 14 - readout_width;
    const y0 = vfd.y + 14;

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
            try builder.strokePath(.{ .elements = &lit_paths[slot][seg], .stroke = .{ .fill = .{ .color = glow }, .width = 3.5 } });
            try builder.fillPath(.{ .elements = &lit_paths[slot][seg], .fill = .{ .color = lit } });
        }
    }

    // Colon: two square dots, ghost + glow + lit (lit hidden when idle).
    const cx = x0 + digit_width + digit_gap + shearAt(y0, y0 + digit_height * 0.5);
    const dot_shift: f32 = if (idle) offscreen else 0;
    const dot_ys = [2]f32{ y0 + digit_height * 0.30, y0 + digit_height * 0.64 };
    for (dot_ys) |dy| {
        try builder.fillRect(.{ .rect = rect(cx, dy, 4, 4), .fill = .{ .color = ghost } });
        try builder.strokeRect(.{ .rect = rect(cx + dot_shift, dy, 4, 4), .stroke = .{ .fill = .{ .color = glow }, .width = 3 } });
        try builder.fillRect(.{ .rect = rect(cx + dot_shift, dy, 4, 4), .fill = .{ .color = lit } });
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
