// Deck's fixed hardware skin. All arithmetic keeps the native f32
// evaluation order, and hidden marks retain their offscreen commands.
import { asciiBytes } from "@native-sdk/core";
import type { CanvasChromeCommand, CanvasChromeContext, CanvasColor, CanvasFill, CanvasPathElement, CanvasPoint, CanvasRect } from "@native-sdk/core/events";
import * as layout from "./layout.ts";

export interface ChromeState {
  readonly high_contrast: boolean;
  readonly now: number | null;
  readonly elapsed_ms: number;
  readonly volume_fraction: number;
}
export const prefix_commands = 46;
export const suffix_commands = 161;
function add(a: number, b: number): number { return Math.fround(Math.fround(a) + Math.fround(b)); }
function sub(a: number, b: number): number { return Math.fround(Math.fround(a) - Math.fround(b)); }
function mul(a: number, b: number): number { return Math.fround(Math.fround(a) * Math.fround(b)); }
function div(a: number, b: number): number { return Math.fround(Math.fround(a) / Math.fround(b)); }
function rgba(r: number, g: number, b: number, a: number): CanvasColor { return { r: div(r, 255), g: div(g, 255), b: div(b, 255), a: div(a, 255) }; }
function rgb(r: number, g: number, b: number): CanvasColor { return rgba(r, g, b, 255); }
function point(x: number, y: number): CanvasPoint { return { x: Math.fround(x), y: Math.fround(y) }; }
function rect(x: number, y: number, width: number, height: number): CanvasRect { return { x: Math.fround(x), y: Math.fround(y), width: Math.fround(width), height: Math.fround(height) }; }
function color(value: CanvasColor): CanvasFill { return { kind: "color", color: value }; }
function gradient(start: CanvasPoint, end: CanvasPoint, first: CanvasColor, last: CanvasColor): CanvasFill {
  return { kind: "linear_gradient", start, end, stops: [{ offset: 0, color: first }, { offset: 1, color: last }] };
}
const transparent = rgba(0, 0, 0, 0);
const bevel_light = rgba(255, 253, 244, 210), bevel_shadow = rgba(74, 66, 48, 150);
const seg_lit = rgb(62, 224, 138), seg_ghost = rgba(62, 224, 138, 24), seg_glow = rgba(62, 224, 138, 60);
const W = layout.window_width, H = layout.window_height;
const display_rect = rect(layout.pad, layout.row1_y, layout.display_width, layout.row1_height);
const art_rect = rect(layout.art_x, layout.row1_y, layout.art_size, layout.row1_height);
const seek_rect = rect(layout.pad, layout.seek_y, W - layout.pad * 2, layout.seek_height);
const bottom_center = div(add(add(layout.transport_y, layout.transport_height), H), 2);
const knob_cx = add(layout.knob_x, div(layout.knob_width, 2));
const knob_cy = add(layout.transport_y, div(layout.transport_height, 2));
const knob_radius = div(layout.knob_size, 2);
const digit_width = 18, digit_height = 28, seg_thickness = Math.fround(3.8), digit_gap = 6, colon_width = 8, shear = Math.fround(0.09);
const readout_width = 80, shear_reach = mul(digit_height, shear), offscreen = 100000;

function fillRect(rectangle: CanvasRect, fill: CanvasFill): CanvasChromeCommand {
  return { kind: "rect", id: asciiBytes("0"), rect: rectangle, fill };
}
function rounded(rectangle: CanvasRect, radius: number, fill: CanvasFill): CanvasChromeCommand {
  return { kind: "rounded_rect", id: asciiBytes("0"), rect: rectangle, radius: Math.fround(radius), fill };
}
function line(from: CanvasPoint, to: CanvasPoint, fill: CanvasColor, width: number): CanvasChromeCommand {
  return { kind: "line", id: asciiBytes("0"), from, to, stroke: { fill: color(fill), width: Math.fround(width) } };
}
function hline(x0: number, x1: number, y: number, fill: CanvasColor): CanvasChromeCommand {
  return line(point(x0, y), point(x1, y), fill, 1);
}
function bevel(r: CanvasRect, context: CanvasChromeContext, hc: boolean, inset: boolean): readonly CanvasChromeCommand[] {
  const out: CanvasChromeCommand[] = [];
  const light = hc ? context.border : bevel_light, shadow = hc ? context.border : bevel_shadow;
  const first = inset ? shadow : light, last = inset ? light : shadow;
  const x1 = add(r.x, r.width), y1 = add(r.y, r.height);
  out.push(line(point(r.x, add(r.y, 0.5)), point(x1, add(r.y, 0.5)), first, 1));
  out.push(line(point(add(r.x, 0.5), r.y), point(add(r.x, 0.5), y1), first, 1));
  out.push(line(point(r.x, sub(y1, 0.5)), point(x1, sub(y1, 0.5)), last, 1));
  out.push(line(point(sub(x1, 0.5), r.y), point(sub(x1, 0.5), y1), last, 1));
  return out;
}
function screw(cx: number, cy: number, hc: boolean): readonly CanvasChromeCommand[] {
  const out: CanvasChromeCommand[] = [];
  out.push(rounded(rect(sub(cx, 4), sub(cy, 4), 8, 8), 4, hc ? color(transparent) : gradient(point(sub(cx, 4), sub(cy, 4)), point(add(cx, 4), add(cy, 4)), rgb(196, 189, 172), rgb(110, 103, 84))));
  out.push(line(point(sub(cx, 2.5), add(cy, 2.5)), point(add(cx, 2.5), sub(cy, 2.5)), hc ? transparent : bevel_shadow, 1.3));
  out.push(line(point(sub(cx, 2), sub(cy, 3)), point(add(cx, 0.5), sub(cy, 3.8)), hc ? transparent : bevel_light, 1));
  return out;
}
function faceplate(): CanvasFill { return gradient(point(0, layout.cap_height), point(0, H), rgb(240, 234, 220), rgb(221, 214, 196)); }
export function prefix(model: ChromeState, context: CanvasChromeContext): readonly CanvasChromeCommand[] {
  const hc = model.high_contrast, out: CanvasChromeCommand[] = [];
  out.push(fillRect(rect(0, 0, W, H), color(hc ? context.background : rgb(214, 207, 189))));
  out.push(fillRect(rect(0, layout.cap_height, W, H - layout.cap_height), hc ? color(context.surface) : faceplate()));
  const grain_pitch = div(sub(sub(H, layout.cap_height), 12), 13);
  for (let i = 0; i < 14; i++) out.push(hline(2, W - 2, add(add(layout.cap_height, 6), mul(i, grain_pitch)), hc ? transparent : rgba(120, 110, 85, 9)));
  out.push(fillRect(rect(0, 0, W, layout.cap_height), hc ? color(context.surface) : gradient(point(0, 0), point(0, layout.cap_height), rgb(247, 242, 230), rgb(228, 221, 203))));
  out.push(hline(0, W, 0.5, hc ? context.border : bevel_light));
  out.push(hline(0, W, add(layout.cap_height, 0.5), hc ? context.border : bevel_shadow));
  for (const command of bevel(rect(0, 0, W, H), context, hc, false)) out.push(command);
  let ridge = sub(bottom_center, div(add(mul(3, 2), 1), 2));
  for (let i = 0; i < 3; i++) {
    out.push(hline(20, 492, ridge, hc ? transparent : rgba(255, 253, 244, 130)));
    out.push(hline(20, 492, add(ridge, 1), hc ? transparent : rgba(74, 66, 48, 70)));
    ridge = add(ridge, 3);
  }
  const top = div(add(layout.cap_height, layout.row1_y), 2);
  for (const command of screw(8, top, hc)) out.push(command); for (const command of screw(504, top, hc)) out.push(command);
  for (const command of screw(8, bottom_center, hc)) out.push(command); for (const command of screw(504, bottom_center, hc)) out.push(command);
  const well = rect(layout.transport_well_x, layout.well_y, layout.transport_well_width, layout.well_height);
  out.push(fillRect(well, color(hc ? context.background : rgb(216, 208, 187))));
  for (const command of bevel(well, context, hc, true)) out.push(command);
  return out;
}

function knobAngle(fraction: number): number { return div(mul(add(135, mul(fraction, 270)), Math.PI), 180); }
function cos(theta: number): number { return Math.fround(Math.cos(theta)); }
function sin(theta: number): number { return Math.fround(Math.sin(theta)); }
function volumeKnob(model: ChromeState, context: CanvasChromeContext): readonly CanvasChromeCommand[] {
  const out: CanvasChromeCommand[] = [];
  const hc = model.high_contrast, r = knob_radius;
  for (let i = 0; i < 5; i++) {
    const theta = knobAngle(div(i, 4));
    out.push(line(point(add(knob_cx, mul(cos(theta), sub(r, 1))), add(knob_cy, mul(sin(theta), sub(r, 1)))), point(add(knob_cx, mul(cos(theta), add(r, 2))), add(knob_cy, mul(sin(theta), add(r, 2)))), hc ? transparent : bevel_shadow, 1));
  }
  out.push(fillRect(rect(layout.knob_x, layout.key_y, layout.knob_width, layout.key_height), hc ? color(transparent) : faceplate()));
  out.push(rounded(rect(sub(knob_cx, r), sub(knob_cy, r), mul(r, 2), mul(r, 2)), r, color(hc ? context.border : rgb(87, 80, 60))));
  const face = sub(r, 2);
  out.push(rounded(rect(sub(knob_cx, face), sub(knob_cy, face), mul(face, 2), mul(face, 2)), face, hc ? color(context.surface) : gradient(point(knob_cx, sub(knob_cy, face)), point(knob_cx, add(knob_cy, face)), rgb(246, 241, 229), rgb(210, 202, 181))));
  const theta = knobAngle(Math.max(0, Math.min(1, model.volume_fraction))), dot_r = Math.fround(2.2);
  const dot_x = add(knob_cx, mul(cos(theta), sub(face, 4.5))), dot_y = add(knob_cy, mul(sin(theta), sub(face, 4.5)));
  out.push(rounded(rect(sub(sub(dot_x, dot_r), 1.5), sub(sub(dot_y, dot_r), 1.5), mul(add(dot_r, 1.5), 2), mul(add(dot_r, 1.5), 2)), add(dot_r, 1.5), color(hc ? transparent : seg_glow)));
  out.push(rounded(rect(sub(dot_x, dot_r), sub(dot_y, dot_r), mul(dot_r, 2), mul(dot_r, 2)), dot_r, color(hc ? context.text : seg_lit)));
  return out;
}

function segmentOn(digit: number, segment: number): boolean {
  if (segment === 0) return digit === 0 || digit === 2 || digit === 3 || digit === 5 || digit === 6 || digit === 7 || digit === 8 || digit === 9;
  if (segment === 1) return digit === 0 || digit === 1 || digit === 2 || digit === 3 || digit === 4 || digit === 7 || digit === 8 || digit === 9;
  if (segment === 2) return digit !== 2;
  if (segment === 3) return digit === 0 || digit === 2 || digit === 3 || digit === 5 || digit === 6 || digit === 8 || digit === 9;
  if (segment === 4) return digit === 0 || digit === 2 || digit === 6 || digit === 8;
  if (segment === 5) return digit === 0 || digit === 4 || digit === 5 || digit === 6 || digit === 8 || digit === 9;
  return digit === 2 || digit === 3 || digit === 4 || digit === 5 || digit === 6 || digit === 8 || digit === 9;
}
function segmentPath(dx: number, dy: number, segment: number, shift: number): readonly CanvasPathElement[] {
  const ht = div(seg_thickness, 2), w = digit_width, h = digit_height;
  let horizontal = true, cx = div(w, 2), cy = 0, half = sub(sub(div(w, 2), ht), 0.6);
  if (segment === 0) cy = ht;
  else if (segment === 3) cy = sub(h, ht);
  else if (segment === 6) cy = div(h, 2);
  else {
    horizontal = false; cx = segment === 1 || segment === 2 ? sub(w, ht) : ht;
    cy = segment === 1 || segment === 5 ? add(mul(h, 0.25), mul(ht, 0.5)) : sub(mul(h, 0.75), mul(ht, 0.5));
    half = sub(sub(mul(h, 0.25), ht), 0.6);
  }
  const points: CanvasPoint[] = horizontal ? [point(sub(cx, half), cy), point(add(sub(cx, half), ht), sub(cy, ht)), point(sub(add(cx, half), ht), sub(cy, ht)), point(add(cx, half), cy), point(sub(add(cx, half), ht), add(cy, ht)), point(add(sub(cx, half), ht), add(cy, ht))] : [point(cx, sub(cy, half)), point(add(cx, ht), add(sub(cy, half), ht)), point(add(cx, ht), sub(add(cy, half), ht)), point(cx, add(cy, half)), point(sub(cx, ht), sub(add(cy, half), ht)), point(sub(cx, ht), add(sub(cy, half), ht))];
  const out: CanvasPathElement[] = [];
  for (let i = 0; i < points.length; i++) {
    const p = points[i];
    if (p !== undefined) out.push({ verb: i === 0 ? "move_to" : "line_to", first: point(add(add(add(dx, p.x), mul(sub(h, p.y), shear)), shift), add(dy, p.y)), second: point(0, 0), third: point(0, 0) });
  }
  out.push({ verb: "close", first: point(0, 0), second: point(0, 0), third: point(0, 0) });
  return out;
}
function segmentReadout(model: ChromeState, context: CanvasChromeContext): readonly CanvasChromeCommand[] {
  const out: CanvasChromeCommand[] = [];
  const hc = model.high_contrast, idle = model.now === null;
  const x0 = add(add(display_rect.x, layout.glass_inset), div(sub(sub(layout.segment_area_width, readout_width), shear_reach), 2));
  const y0 = add(add(display_rect.y, layout.glass_inset), div(sub(layout.display_top_row_height, digit_height), 2));
  const elapsed_s = Math.floor(model.elapsed_ms / 1000);
  const digits = [Math.min(9, Math.floor(elapsed_s / 60)), Math.floor((elapsed_s % 60) / 10), elapsed_s % 10];
  const xs = [x0, add(add(add(add(x0, digit_width), digit_gap), colon_width), digit_gap), add(add(add(add(x0, mul(digit_width, 2)), mul(digit_gap, 2)), colon_width), digit_gap)];
  const ghost = hc ? transparent : seg_ghost, lit = hc ? context.text : seg_lit, glow = hc ? transparent : seg_glow;
  for (let slot = 0; slot < 3; slot++) {
    const digit = digits[slot], dx = xs[slot];
    if (digit === undefined || dx === undefined) continue;
    for (let seg = 0; seg < 7; seg++) {
      const on = idle ? seg === 6 : segmentOn(digit, seg);
      const ghost_path = segmentPath(dx, y0, seg, 0), lit_path = segmentPath(dx, y0, seg, on ? 0 : offscreen);
      out.push({ kind: "fill_path", id: asciiBytes("0"), elements: ghost_path, fill: color(ghost) });
      out.push({ kind: "stroke_path", id: asciiBytes("0"), elements: lit_path, stroke: { fill: color(glow), width: Math.fround(3.2) }, cap: "butt" });
      out.push({ kind: "fill_path", id: asciiBytes("0"), elements: lit_path, fill: color(lit) });
    }
  }
  const half_y = add(y0, mul(digit_height, 0.5));
  const cx = add(add(add(x0, digit_width), digit_gap), mul(sub(add(y0, digit_height), half_y), shear));
  for (let i = 0; i < 2; i++) {
    const dy = add(y0, mul(digit_height, i === 0 ? 0.30 : 0.64)), shift = idle ? offscreen : 0;
    out.push(fillRect(rect(cx, dy, 3.5, 3.5), color(ghost)));
    out.push({ kind: "stroke_rect", id: asciiBytes("0"), rect: rect(add(cx, shift), dy, 3.5, 3.5), radius: { topLeft: 0, topRight: 0, bottomRight: 0, bottomLeft: 0 }, stroke: { fill: color(glow), width: Math.fround(2.6) } });
    out.push(fillRect(rect(add(cx, shift), dy, 3.5, 3.5), color(lit)));
  }
  return out;
}

export function suffix(model: ChromeState, context: CanvasChromeContext): readonly CanvasChromeCommand[] {
  const hc = model.high_contrast, out: CanvasChromeCommand[] = [];
  for (const command of bevel(display_rect, context, hc, true)) out.push(command); for (const command of bevel(art_rect, context, hc, true)) out.push(command); for (const command of bevel(seek_rect, context, hc, true)) out.push(command);
  const pitch = div(display_rect.height, 36);
  for (let i = 0; i < 36; i++) out.push(hline(add(display_rect.x, 1), sub(add(display_rect.x, display_rect.width), 1), add(display_rect.y, mul(add(i, 0.5), pitch)), hc ? transparent : rgba(0, 0, 0, 46)));
  const glare = hc ? transparent : rgba(255, 255, 255, 9);
  out.push(fillRect(display_rect, gradient(point(display_rect.x, display_rect.y), point(add(display_rect.x, mul(display_rect.width, 0.7)), add(display_rect.y, display_rect.height)), glare, transparent)));
  out.push(fillRect(art_rect, gradient(point(art_rect.x, art_rect.y), point(add(art_rect.x, mul(art_rect.width, 0.7)), add(art_rect.y, art_rect.height)), glare, transparent)));
  for (const command of segmentReadout(model, context)) out.push(command); for (const command of volumeKnob(model, context)) out.push(command);
  for (const command of bevel(rect(layout.cap_close_x, layout.cap_key_y, layout.cap_key_size, layout.cap_key_size), context, hc, false)) out.push(command);
  for (const command of bevel(rect(layout.cap_min_x, layout.cap_key_y, layout.cap_key_size, layout.cap_key_size), context, hc, false)) out.push(command);
  for (const command of bevel(rect(layout.prev_x, layout.key_y, layout.btn_prev_width, layout.key_height), context, hc, false)) out.push(command);
  for (const command of bevel(rect(layout.play_x, layout.key_y, layout.btn_play_width, layout.key_height), context, hc, false)) out.push(command);
  for (const command of bevel(rect(layout.pause_x, layout.key_y, layout.btn_pause_width, layout.key_height), context, hc, false)) out.push(command);
  for (const command of bevel(rect(layout.stop_x, layout.key_y, layout.btn_stop_width, layout.key_height), context, hc, false)) out.push(command);
  for (const command of bevel(rect(layout.next_x, layout.key_y, layout.btn_next_width, layout.key_height), context, hc, false)) out.push(command);
  for (const command of bevel(rect(layout.pl_x, layout.key_y, layout.btn_pl_width, layout.key_height), context, hc, false)) out.push(command);
  return out;
}
