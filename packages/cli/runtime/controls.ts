// The controls the UA draws itself: a checkbox's box, a radio's dot and a range's track and
// thumb. Their lit parts take the accent colour, and `appearance: none` turns the whole widget
// off so the author's own box shows instead.

import * as P from "../shared/props.ts";
import { parseColor } from "../shared/css/colors.ts";
import { HTMLInputElement, HTMLMeterElement, HTMLProgressElement, controlKind, inDisabledFormControl, rangeSpec, snapRange, CONTROL_NONE, CONTROL_COLOR, CONTROL_RADIO, CONTROL_RANGE } from "./dom.ts";
import { hostFillPoly, hostFillRect, hostFillRing } from "./host.ts";
import { absolutePosition } from "./layout/geometry.ts";

// The UA's own colours: Chrome's accent, the edge of an empty box, the track behind a range's
// thumb, and the grey a disabled control takes instead of the accent.
const ACCENT = 0x0075ffff;
const BOX_EDGE = 0x767676ff;
const TRACK = 0xefefefff;
const TRACK_EDGE = 0xb2b2b2ff;
const WHITE = 0xffffffff;
const DISABLED = 0x999999ff;
// A meter's bar, in the colours Chrome gives its good, suboptimal and even-less-good zones.
const METER_GOOD = 0x0a8a0aff;
const METER_SUBOPTIMAL = 0xd9a400ff;
const METER_BAD = 0xcf3a2fff;

/** The colour a control's lit parts take: its accent colour, or the UA's own. */
function accentOf(el: HTMLInputElement): number {
  if (inDisabledFormControl(el)) return DISABLED;
  const declared = el.sv[P.P_ACCENT_COLOR];
  return declared < 0 ? ACCENT : declared;
}

function dim(color: number, opacity: number): number {
  if (opacity >= 1) return color;
  const a = Math.round((color & 255) * opacity);
  return color - (color & 255) + a;
}

function circle(cx: number, cy: number, r: number, color: number): void {
  if (r <= 0) return;
  hostFillRect(cx - r, cy - r, r * 2, r * 2, r, color);
}

/** A circle's outline, `width` wide, against the inside of the circle of radius `r`. */
function ring(cx: number, cy: number, r: number, width: number, color: number): void {
  if (r <= 0) return;
  hostFillRing(cx - r, cy - r, r * 2, r * 2, r, width, color);
}

/** The tick inside a checkbox, as the vertices of its thick stroke, in CSS px. */
function checkPoints(cx: number, cy: number, size: number): string {
  const s = size / 13;
  const p = [2.54, 7.38, 4.94, 9.68, 10.62, 4.62, 9.18, 3.38, 6.26, 8.32, 3.86, 6.02];
  let out = "";
  for (let i = 0; i < p.length; i += 2) {
    if (i > 0) out += " ";
    out += (cx + (p[i] - 6.5) * s).toFixed(2) + "," + (cy + (p[i + 1] - 6.5) * s).toFixed(2);
  }
  return out;
}

/** A checkbox's box or a radio's dot. */
function paintTick(el: HTMLInputElement, kind: number, x: number, y: number, opacity: number): void {
  const size = Math.max(0, Math.min(13, el.contentW, el.contentH));
  const cx = x + el.contentW / 2;
  const cy = y + el.contentH / 2;
  const accent = dim(accentOf(el), opacity);
  const edge = dim(BOX_EDGE, opacity);
  const white = dim(WHITE, opacity);
  if (kind === CONTROL_RADIO) {
    const r = size / 2;
    if (el.checked) {
      // The accent circle, a white gap and the accent dot in the middle, as Chrome draws them.
      circle(cx, cy, r, accent);
      circle(cx, cy, Math.max(0, r - 1.5), white);
      circle(cx, cy, Math.max(0, r - 2.5), accent);
    } else {
      circle(cx, cy, r, white);
      ring(cx, cy, r, 1, edge);
    }
    return;
  }
  const box = cx - size / 2;
  const top = cy - size / 2;
  if (!el.checked && !el.indeterminate) {
    hostFillRect(box, top, size, size, 2, white);
    hostFillRing(box, top, size, size, 2, 1, edge);
    return;
  }
  hostFillRect(box, top, size, size, 2, accent);
  if (el.indeterminate) {
    // Half checked: a white dash where the tick would be.
    const dashW = size * 0.5;
    const dashH = Math.max(1, size * 0.16);
    hostFillRect(cx - dashW / 2, cy - dashH / 2, dashW, dashH, dashH / 2, white);
    return;
  }
  hostFillPoly(checkPoints(cx, cy, size), white);
}

/** A range's track and thumb. */
function paintRange(el: HTMLInputElement, x: number, y: number, opacity: number): void {
  const accent = dim(accentOf(el), opacity);
  const track = dim(TRACK, opacity);
  const w = el.contentW;
  const h = el.contentH;
  const trackH = Math.max(0, Math.min(8, h));
  const mid = y + h / 2;
  const thumb = rangeThumbCenter(el);
  // The track is a strip with a hairline edge, as Chrome draws it.
  const top = mid - trackH / 2;
  hostFillRect(x, top, w, trackH, trackH / 2, dim(TRACK_EDGE, opacity));
  if (trackH > 2 && w > 2) {
    hostFillRect(x + 1, top + 1, w - 2, trackH - 2, Math.max(0, trackH / 2 - 1), track);
  }
  // The part of the track the thumb has passed is the accent colour, rounded like the track.
  const filled = Math.max(thumb, trackH);
  if (filled > 0) hostFillRect(x, top, Math.min(filled, w), trackH, trackH / 2, accent);
  circle(x + thumb, mid, rangeThumbRadius(el), accent);
}

/** A colour field's swatch: the colour it holds, filling its content box inside a hairline edge. */
function paintSwatch(el: HTMLInputElement, x: number, y: number, opacity: number): void {
  const w = el.contentW;
  const h = el.contentH;
  if (w <= 0 || h <= 0) return;
  const color = parseColor(el.value);
  hostFillRect(x, y, w, h, 2, dim(BOX_EDGE, opacity));
  if (w > 2 && h > 2) hostFillRect(x + 1, y + 1, w - 2, h - 2, 1, dim(color ?? 0x000000ff, opacity));
}

/** Paints the widget an <input> of a drawn type is. */
export function paintControl(el: HTMLInputElement, x: number, y: number, opacity: number): void {
  const kind = controlKind(el.type);
  if (kind === CONTROL_NONE) return;
  // `appearance: none` hands the control's box to the author, and no part of the widget is drawn.
  if (el.sv[P.P_APPEARANCE] === P.AP_NONE) return;
  // A background or border the author declares takes the box away the same way: the swatch is the
  // UA's own painting, and it stops where the author's own painting begins.
  const cx = x + el.contentX;
  const cy = y + el.contentY;
  if (kind === CONTROL_COLOR) {
    if (!el.faceDeclared) paintSwatch(el, cx, cy, opacity);
  } else if (kind === CONTROL_RANGE) paintRange(el, cx, cy, opacity);
  else paintTick(el, kind, cx, cy, opacity);
}

/** The box and bar a meter draws while its appearance is the UA's. */
export function paintMeter(el: HTMLMeterElement, x: number, y: number, opacity: number): void {
  if (el.sv[P.P_APPEARANCE] === P.AP_NONE) return;
  const w = el.contentW;
  const h = el.contentH;
  if (w <= 0 || h <= 0) return;
  const cx = x + el.contentX;
  const cy = y + el.contentY;
  const r = Math.min(3, h / 2);
  hostFillRect(cx, cy, w, h, r, dim(TRACK, opacity));
  hostFillRing(cx, cy, w, h, r, 1, dim(TRACK_EDGE, opacity));
  const min = el.min;
  const max = el.max;
  const span = max > min ? max - min : 0;
  const frac = span > 0 ? Math.min(1, Math.max(0, (el.value - min) / span)) : 0;
  const innerW = Math.max(0, w - 4);
  const innerH = Math.max(0, h - 4);
  if (frac > 0 && innerW > 0 && innerH > 0) {
    hostFillRect(cx + 2, cy + 2, innerW * frac, innerH, Math.max(0, Math.min(2, innerH / 2)), dim(meterBarColor(el), opacity));
  }
}

/** The bar colour for a meter's value: green in the optimum's zone, red in the worst one. */
function meterBarColor(el: HTMLMeterElement): number {
  const low = el.low;
  const high = el.high;
  const optimum = el.optimum;
  const value = el.value;
  // A meter's zones are the spec's three ranges, and the boundary between two of them belongs to
  // the one the optimum is in: with the optimum below low the low range runs through low, with it
  // above high the high range starts at high, and with it in the band the band includes both low
  // and high. So a meter whose value sits on the optimum's edge draws its optimum green.
  const belowLow = optimum < low;
  const aboveHigh = optimum > high;
  const zone = (v: number): number => {
    if (belowLow) return v <= low ? 0 : v <= high ? 1 : 2;
    if (aboveHigh) return v < low ? 0 : v < high ? 1 : 2;
    return v < low ? 0 : v <= high ? 1 : 2;
  };
  const good = zone(optimum);
  const at = zone(value);
  if (at === good) return METER_GOOD;
  // The middle zone is suboptimal; the far side from the optimum is the worst.
  if (at === 1 || Math.abs(at - good) === 1) return METER_SUBOPTIMAL;
  return METER_BAD;
}

/** The box and bar a progress element draws while its appearance is the UA's. */
export function paintProgress(el: HTMLProgressElement, x: number, y: number, opacity: number): void {
  if (el.sv[P.P_APPEARANCE] === P.AP_NONE) return;
  const w = el.contentW;
  const h = el.contentH;
  if (w <= 0 || h <= 0) return;
  const cx = x + el.contentX;
  const cy = y + el.contentY;
  const r = Math.min(3, h / 2);
  hostFillRect(cx, cy, w, h, r, dim(TRACK, opacity));
  hostFillRing(cx, cy, w, h, r, 1, dim(TRACK_EDGE, opacity));
  const p = el.position;
  if (p < 0) return;
  const innerW = Math.max(0, w - 4);
  const innerH = Math.max(0, h - 4);
  if (p <= 0 || innerW <= 0 || innerH <= 0) return;
  const declared = el.sv[P.P_ACCENT_COLOR];
  const accent = declared < 0 ? ACCENT : declared;
  hostFillRect(cx + 2, cy + 2, innerW * Math.min(1, p), innerH, Math.max(0, Math.min(2, innerH / 2)), dim(accent, opacity));
}

/** The radius of a range's thumb: as tall as the field allows, up to 8px. */
export function rangeThumbRadius(el: HTMLInputElement): number {
  return Math.max(0, Math.min(8, el.contentH / 2, el.contentW / 2));
}

/** Where a range's thumb centre sits, in content-box pixels from the content edge. */
export function rangeThumbCenter(el: HTMLInputElement): number {
  const spec = rangeSpec(el);
  const r = rangeThumbRadius(el);
  const t = spec.max > spec.min ? (spec.value - spec.min) / (spec.max - spec.min) : 0;
  return r + t * Math.max(0, el.contentW - 2 * r);
}

/** The value a press at a viewport x gives a range field: the thumb goes where the pointer is. */
export function rangeValueAt(el: HTMLInputElement, viewportX: number): number {
  const spec = rangeSpec(el);
  const r = rangeThumbRadius(el);
  const span = Math.max(1, el.contentW - 2 * r);
  let t = (viewportX - absolutePosition(el)[0] - el.contentX - r) / span;
  if (t < 0) t = 0;
  if (t > 1) t = 1;
  return snapRange(spec.min + t * (spec.max - spec.min), spec.min, spec.max, spec.step);
}
