// Gradient backgrounds: decoding the encoded form built at build time (shared/css/gradients.ts)
// into the geometry a tile draws, and handing the stops to the host. Stops are mixed in the
// colour space the gradient names (see shared/css/colors.ts), sampled so the host's own straight
// interpolation follows the same curve.
//
// The host draws the three shapes CoreGraphics knows: a linear gradient between two points, a
// radial one, which an ellipse is a circle under a non-uniform scale, and a conic one, a gradient
// around a centre. Everything here is CSS: where the gradient line starts and ends, how a stop's
// percentage or length lies along it, how the radius keywords of a radial gradient measure the
// box, and how a colour hint bends the mix between two stops.

import * as P from "../shared/props.ts";
import { interpolateColor } from "../shared/css/colors.ts";
import { evalExpr } from "../shared/css/length-exprs.ts";
import { hostBackingScale, hostLinearGradient, hostRadialGradient, hostConicGradient } from "./host.ts";
import { viewport } from "./viewport.ts";
import { rootFontSize } from "./root-size.ts";

/** One colour stop: a packed colour, and its position (`u` is U_NONE when it has none). */
interface Stop { color: number; v: number; u: number }

interface Length { v: number; u: number }
interface Centre { v: number; u: number; edge: number }

/** The query container's content box, which the cq units in a gradient measure. */
export interface Basis { w: number; h: number }

interface Gradient {
  kind: number; // 0 linear, 1 radial, 2 conic
  repeat: number;
  angle: number;
  cornerX: number; // a corner direction, resolved against the tile's aspect at paint time
  cornerY: number;
  shape: number; // radial: 1 circle, 0 ellipse
  rx: Length;
  ry: Length;
  cx: Centre;
  cy: Centre;
  /** The colour space its stops interpolate in, and the arc a polar space's hue takes. */
  space: number;
  hue: number;
  stops: Stop[];
}

const LINEAR = 0, RADIAL = 1, CONIC = 2, CIRCLE = 1;

/** A stop list entry for a colour hint: the position at which the stops either side are half mixed. */
const HINT = -1;
/** A stop whose colour is currentColor: the element's own colour, applied when it is painted. */
const CURRENT = -2;

const cache: Map<string, Gradient | null> = new Map();

/**
 * One stop field: `<colour>:<value>:<unit>`, the value empty when it has no position, the colour
 * `c` for currentColor; or `h:<value>:<unit>` for a colour hint.
 */
function stopOf(field: string): Stop {
  const s = field.split(":");
  if (s[0] === "h") return { color: HINT, v: Number(s[1]), u: Number(s[2]) };
  const color = s[0] === "c" ? CURRENT : Number(s[0]);
  const u = Number(s[2]);
  return { color, v: s[1] === "" ? 0 : Number(s[1]), u: s[1] === "" ? P.U_NONE : u };
}

function lengthOf(field: string): Length {
  const s = field.split(":");
  return { v: Number(s[0]), u: Number(s[1]) };
}

function centreOf(field: string): Centre {
  const s = field.split(":");
  return { v: Number(s[0]), u: Number(s[1]), edge: Number(s[2]) };
}

/** Decodes an encoded gradient (see shared/css/gradients.ts), or null for one that can't paint. */
function decode(encoded: string): Gradient | null {
  const f = encoded.split("|");
  const repeating = f[0].length === 2 ? 1 : 0;
  const kind = f[0].charAt(f[0].length - 1);
  const linear = kind === "L" ? 1 : 0;
  const stops: Stop[] = [];
  const first = linear ? 4 : kind === "C" ? 6 : 8;
  for (let i = first; i < f.length; i++) stops.push(stopOf(f[i]));
  if (stops.length < 2) return null;
  if (kind === "C") {
    return {
      kind: CONIC, repeat: repeating, angle: Number(f[1]), cornerX: 0, cornerY: 0, shape: 0,
      rx: { v: 0, u: P.U_FARTHEST_CORNER }, ry: { v: 0, u: P.U_FARTHEST_CORNER },
      cx: centreOf(f[2]), cy: centreOf(f[3]),
      space: Number(f[4]), hue: Number(f[5]),
      stops,
    };
  }
  if (linear) {
    let angle = 0, cornerX = 0, cornerY = 0;
    if (f[1].charAt(0) === "C") {
      const c = f[1].slice(1).split(":");
      cornerX = Number(c[0]);
      cornerY = Number(c[1]);
    } else angle = Number(f[1]);
    return {
      kind: LINEAR, repeat: repeating, angle, cornerX, cornerY, shape: 0,
      rx: { v: 0, u: P.U_FARTHEST_CORNER }, ry: { v: 0, u: P.U_FARTHEST_CORNER },
      cx: { v: 50, u: P.U_PCT, edge: 0 }, cy: { v: 50, u: P.U_PCT, edge: 0 },
      space: Number(f[2]), hue: Number(f[3]),
      stops,
    };
  }
  return {
    kind: RADIAL, repeat: repeating, angle: 0, cornerX: 0, cornerY: 0, shape: Number(f[1]),
    rx: lengthOf(f[2]), ry: lengthOf(f[3]),
    cx: centreOf(f[4]), cy: centreOf(f[5]),
    space: Number(f[6]), hue: Number(f[7]),
    stops,
  };
}

/** A cq unit in px: the share of the query container's content box it names, or of the viewport
 *  on an axis the nearest container doesn't measure. */
function cqOf(v: number, u: number, basis: Basis): number {
  const w = (v / 100) * basis.w;
  const h = (v / 100) * basis.h;
  if (u === P.U_CQW || u === P.U_CQI) return w;
  if (u === P.U_CQH || u === P.U_CQB) return h;
  if (u === P.U_CQMIN) return Math.min(w, h);
  return Math.max(w, h);
}

/** A length of the gradient line as a fraction of it: percentages directly, others in px. */
function fractionOf(s: Stop, len: number, fontSize: number, basis: Basis): number {
  if (s.u === P.U_EXPR) return evalExpr(s.v, len, viewport.w, viewport.h, fontSize, viewport.w, viewport.h, rootFontSize()) / len;
  if (s.u === P.U_PCT) return s.v / 100;
  if (s.u === P.U_EM) return (s.v * fontSize) / len;
  if (s.u === P.U_REM) return (s.v * rootFontSize()) / len;
  if (s.u >= P.U_CQW && s.u <= P.U_CQMAX) return cqOf(s.v, s.u, basis) / len;
  return s.v / len;
}

/**
 * The colour stops of a gradient line `len` px long, as positions in 0..1, with the colour hints
 * pulled out: `hints[i]` is the fraction of the way from stop i to stop i + 1 at which they are
 * half mixed, or NaN for a segment without a hint. A stop without a position is placed evenly
 * between its neighbours (the first at 0, the last at 1), and every position is clamped to the one
 * before it and to the line, as CSS's colour stop fixup does.
 */
function stopPositions(stops: Stop[], len: number, fontSize: number, basis: Basis): { colors: Stop[]; pos: number[]; hints: number[] } {
  const colors: Stop[] = [];
  const hintAt: number[] = [];
  for (const s of stops) {
    if (s.color === HINT) {
      const k = colors.length - 1;
      // A hint before the first colour stop has nothing to mix, so it is dropped.
      if (k >= 0) hintAt[k] = s.u === P.U_NONE ? NaN : fractionOf(s, len, fontSize, basis);
      continue;
    }
    colors.push(s);
    hintAt.push(NaN);
  }
  const n = colors.length;
  const pos: number[] = [];
  for (const s of colors) pos.push(s.u === P.U_NONE ? NaN : fractionOf(s, len, fontSize, basis));
  if (Number.isNaN(pos[0])) pos[0] = 0;
  if (Number.isNaN(pos[n - 1])) pos[n - 1] = 1;
  let i = 1;
  while (i < n) {
    if (Number.isNaN(pos[i])) {
      let j = i;
      while (j < n && Number.isNaN(pos[j])) j++;
      const a = pos[i - 1], b = pos[j];
      for (let k = i; k < j; k++) pos[k] = a + ((b - a) * (k - i + 1)) / (j - i + 1);
      i = j;
    } else i++;
  }
  let prev = 0;
  for (let k = 0; k < n; k++) {
    if (pos[k] < prev) pos[k] = prev;
    if (pos[k] > 1) pos[k] = 1;
    prev = pos[k];
  }
  // A hint is a position along the line; what the mix needs is how far into its segment it is.
  const hints: number[] = [];
  for (let k = 0; k < n; k++) {
    const h = hintAt[k], a = pos[k], b = k + 1 < n ? pos[k + 1] : NaN;
    if (Number.isNaN(h) || !(b > a)) hints.push(NaN);
    else hints.push(Math.min(Math.max((h - a) / (b - a), 0.0001), 0.9999));
  }
  return { colors, pos, hints };
}

/**
 * A hard stop leaves two stops at the same position, and CoreGraphics needs them to climb
 * strictly, so an equal run is spread over a hair of the line — far below a device pixel.
 */
function spreadEqual(pos: number[]): void {
  const n = pos.length;
  let k = 0;
  while (k < n) {
    let m = k;
    while (m + 1 < n && pos[m + 1] === pos[k]) m++;
    if (m > k) {
      const v = pos[k], count = m - k + 1;
      // A run this near the end of the line has no room above it for the hair, and a position
      // past the end is one the host can't take, so that run is spread below 1 instead.
      const low = v + 0.00001 > 1;
      for (let i = k; i <= m; i++) {
        const t = (i - k + 1) / count;
        pos[i] = low ? 1 - (1 - t) * 0.00001 : v + t * 0.00001;
      }
    }
    k = m + 1;
  }
}

/** One colour, interpolated towards another in the gradient's space, as CSS mixes them. */
function mix(c0: number, c1: number, t: number, space: number, hue: number): number {
  return interpolateColor(c0, c1, t, space, hue);
}

// The host keeps this many stops (host/macos.m MAX_STOPS, and eight fewer here so the string
// has room for the subdivisions below), and each segment between two CSS stops is sampled a few
// times so a premultiplied mix is approximated closely. A repeating pattern stretches the budget
// over every copy of itself, which is what makes a ring pattern a few pixels wide draw at all.
const MAX_STOPS = 4088;
const SEGMENT_STEPS = 12;

/** The colour a stop list shows at `x` (0..1), mixed in the gradient's space. */
function colorAt(colors: number[], pos: number[], x: number, space: number, hue: number): number {
  const n = pos.length;
  if (x <= pos[0]) return colors[0];
  if (x >= pos[n - 1]) return colors[n - 1];
  let i = 0;
  while (i + 1 < n && pos[i + 1] < x) i++;
  const f0 = pos[i], f1 = pos[i + 1];
  if (!(f1 > f0)) return colors[i + 1];
  return mix(colors[i], colors[i + 1], (x - f0) / (f1 - f0), space, hue);
}

/**
 * A repeating gradient's stops tiled across the line: one copy per period from before the start
 * to after the end, clipped to 0..1. A period too short for the host's stop budget (a few pixels
 * at most) fades into its average colour instead.
 */
function repeatStops(colors: number[], pos: number[], space: number, hue: number): { colors: number[]; pos: number[] } {
  const n = pos.length;
  const first = pos[0], last = pos[n - 1];
  const period = last - first;
  if (!(period > 0)) return { colors: [colors[n - 1], colors[n - 1]], pos: [0, 1] };
  const k0 = Math.floor((0 - first) / period) - 1;
  const k1 = Math.ceil((1 - first) / period) + 1;
  if ((k1 - k0 + 1) * n > MAX_STOPS - 8) {
    // Average one period in premultiplied alpha, sampling the middle of small slices of it.
    let ar = 0, ag = 0, ab = 0, aa = 0;
    const samples = 24;
    for (let s = 0; s < samples; s++) {
      const c = colorAt(colors, pos, first + (period * (s + 0.5)) / samples, space, hue);
      const a = (c & 255) / 255;
      ar += ((c >>> 24) & 255) * a;
      ag += ((c >>> 16) & 255) * a;
      ab += ((c >>> 8) & 255) * a;
      aa += a;
    }
    let avg = 0;
    if (aa > 0) {
      const a = aa / samples;
      avg = ((Math.round(ar / aa) << 24) | (Math.round(ag / aa) << 16) |
             (Math.round(ab / aa) << 8) | Math.round(a * 255)) >>> 0;
    }
    return { colors: [avg, avg], pos: [0, 1] };
  }
  // Where the line starts and ends inside the pattern, which wraps around the period.
  const at = (x: number): number => {
    const t = first + ((x - first) % period + period) % period;
    return colorAt(colors, pos, t, space, hue);
  };
  const outC: number[] = [at(0)];
  const outP: number[] = [0];
  for (let k = k0; k <= k1; k++) {
    for (let i = 0; i < n; i++) {
      const p = pos[i] + k * period;
      if (p <= 0 || p > 1) continue;
      // Where one copy ends the next begins, so two stops share a position: the hard stop the
      // pattern jumps back to its first colour with.
      outP.push(p);
      outC.push(colors[i]);
    }
  }
  // A copy that ends exactly at the end of the line has its own last stop there; only a line that
  // ends inside a period needs the colour at its end worked out.
  if (!(outP[outP.length - 1] >= 1)) {
    outP.push(1);
    outC.push(at(1));
  }
  return { colors: outC, pos: outP };
}

/**
 * The stop list with each hinted segment sampled along its hinted curve: at fraction t of the
 * segment the mix is t^(log .5 / log h), so the hint's position is where the two stops are half
 * mixed and the mix is otherwise lopsided towards the nearer one.
 */
function hintedStops(colors: number[], pos: number[], hints: number[], steps: number, space: number,
  hue: number): { colors: number[]; pos: number[] } {
  const outC: number[] = [colors[0]];
  const outP: number[] = [pos[0]];
  for (let i = 0; i + 1 < colors.length; i++) {
    const c0 = colors[i], c1 = colors[i + 1], f0 = pos[i], f1 = pos[i + 1], h = hints[i];
    if (Number.isNaN(h) || !(f1 > f0) || c0 === c1) {
      outC.push(c1);
      outP.push(f1);
      continue;
    }
    const k = Math.log(0.5) / Math.log(h);
    for (let s = 1; s < steps; s++) {
      const t = s / steps;
      outC.push(mix(c0, c1, Math.pow(t, k), space, hue));
      outP.push(f0 + (f1 - f0) * t);
    }
    outC.push(c1);
    outP.push(f1);
  }
  return { colors: outC, pos: outP };
}

/**
 * The stop list in the host's form: `<colour>,<position>;…`, positions in 0..1. CoreGraphics
 * interpolates in straight (non-premultiplied) RGB, which shows at a transparent stop, so each
 * segment is split into a few steps mixed the way CSS mixes them.
 */
function stopsText(g: Gradient, len: number, fontSize: number, basis: Basis, currentColor: number): string {
  const fixed = stopPositions(g.stops, len, fontSize, basis);
  let pos = fixed.pos;
  let n = pos.length;
  // A see-through stop contributes nothing to a premultiplied mix, so its own colour is what
  // matters only if it is interpolated straight, as CoreGraphics does: give it the colour of a
  // neighbour that can be seen, and the faint end of the ramp stays the right hue.
  let colors: number[] = [];
  for (let i = 0; i < n; i++) colors.push(fixed.colors[i].color === CURRENT ? currentColor : fixed.colors[i].color);
  for (let i = 0; i < n; i++) {
    if ((colors[i] & 255) !== 0) continue;
    let j = i - 1;
    while (j >= 0 && (colors[j] & 255) === 0) j--;
    if (j < 0) {
      j = i + 1;
      while (j < n && (colors[j] & 255) === 0) j++;
    }
    if (j >= 0 && j < n) colors[i] = (colors[j] & 0xFFFFFF00) >>> 0;
  }
  // A colour hint bends the mix inside its segment; sampling the curve here leaves the rest of the
  // list — tiling, and the host's own steps — plain linear mixes.
  let hinted = 0;
  for (const h of fixed.hints) if (!Number.isNaN(h)) hinted++;
  if (hinted > 0) {
    // The samples are stops of their own, so as many hints as the list has they have to share the
    // room the host keeps for stops.
    const steps = Math.max(2, Math.min(SEGMENT_STEPS, Math.floor((MAX_STOPS - 8 - n) / hinted) + 1));
    const bent = hintedStops(colors, pos, fixed.hints, steps, g.space, g.hue);
    colors = bent.colors;
    pos = bent.pos;
    n = pos.length;
  }
  if (g.repeat !== 0) {
    const tiled = repeatStops(colors, pos, g.space, g.hue);
    for (let i = 0; i < tiled.colors.length; i++) colors[i] = tiled.colors[i];
    colors.length = tiled.colors.length;
    pos = tiled.pos;
    n = colors.length;
  }
  spreadEqual(pos);
  // A segment needs only as many steps as it has device pixels to show them in: a repeating
  // pattern whose period is a few pixels has hundreds of short segments, and subdividing each of
  // them twelve times would spend the room the pattern's own stops need.
  const pxLen = len > 0 ? len * hostBackingScale() : 0;
  let text = "";
  let count = 0;
  const add = (color: number, p: number): void => {
    if (count > 0) text += ";";
    // Seven decimals of a 0..1 fraction is well inside a device pixel for any sane box, and keeps
    // the hair a hard stop's equal positions are pulled apart by; scriptc has no toFixed, so the
    // rounding is done with arithmetic.
    text += `${color},${Math.round(p * 10000000) / 10000000}`;
    count++;
  };
  for (let i = 0; i < n; i++) {
    add(colors[i], pos[i]);
    if (i + 1 >= n || count >= MAX_STOPS - SEGMENT_STEPS) continue;
    const c0 = colors[i], c1 = colors[i + 1];
    const f0 = pos[i], f1 = pos[i + 1];
    if (c0 === c1 || !(f1 > f0)) continue;
    const segPx = (f1 - f0) * pxLen;
    let steps = segPx < SEGMENT_STEPS ? Math.max(2, Math.round(segPx)) : SEGMENT_STEPS;
    steps = Math.min(steps, MAX_STOPS - count);
    for (let s = 1; s < steps; s++) {
      const t = s / steps;
      add(mix(c0, c1, t, g.space, g.hue), f0 + (f1 - f0) * t);
    }
  }
  return text;
}

/** Paints one tile of a linear gradient, over the box (x, y, w, h) it fills. */
function paintLinear(g: Gradient, x: number, y: number, w: number, h: number, fontSize: number, basis: Basis, alpha: number,
  currentColor: number): void {
  // A corner direction is perpendicular to the diagonal between the two other corners, so its
  // angle depends on the box: `to right bottom` on a wide box leans towards the right side.
  const angle = g.cornerX !== 0 || g.cornerY !== 0
    ? (Math.atan2(g.cornerX * h, -g.cornerY * w) * 180) / Math.PI
    : g.angle;
  const rad = (angle * Math.PI) / 180;
  const dx = Math.sin(rad), dy = -Math.cos(rad);
  // The gradient line through the centre is as long as the box's projection on its direction:
  // its ends are where the two lines through two corners meet it.
  const len = Math.abs(w * dx) + Math.abs(h * dy);
  if (!(len > 0)) return;
  const mx = x + w / 2, my = y + h / 2;
  const x0 = mx - (dx * len) / 2, y0 = my - (dy * len) / 2;
  const x1 = mx + (dx * len) / 2, y1 = my + (dy * len) / 2;
  hostLinearGradient(x, y, w, h, x0, y0, x1, y1, stopsText(g, len, fontSize, basis, currentColor), alpha);
}

/** A radial length against a percentage base, for explicit lengths only. */
function pxOf(v: number, u: number, base: number, fontSize: number, basis: Basis): number {
  if (u === P.U_EXPR) return evalExpr(v, base, viewport.w, viewport.h, fontSize, viewport.w, viewport.h, rootFontSize());
  if (u === P.U_PCT) return (base * v) / 100;
  if (u === P.U_EM) return v * fontSize;
  if (u === P.U_REM) return v * rootFontSize();
  if (u >= P.U_CQW && u <= P.U_CQMAX) return cqOf(v, u, basis);
  return v;
}

/** Paints one tile of a radial gradient, over the box (x, y, w, h) it fills. */
function paintRadial(g: Gradient, x: number, y: number, w: number, h: number, fontSize: number, basis: Basis, alpha: number,
  currentColor: number): void {
  const off = (l: Centre, base: number): number => {
    const o = pxOf(l.v, l.u, base, fontSize, basis);
    return l.edge === 1 ? base - o : o;
  };
  let cx = x + off(g.cx, w), cy = y + off(g.cy, h);
  const dl = cx - x, dr = x + w - cx, dt = cy - y, db = y + h - cy;

  // The size keywords measure from the centre to the box's sides (side keywords) or corners.
  const corners: number[][] = [[dl, dt], [dr, dt], [dl, db], [dr, db]];
  let far = corners[0], near = corners[0];
  for (const k of corners.slice(1)) {
    const dk = k[0] * k[0] + k[1] * k[1];
    if (dk > far[0] * far[0] + far[1] * far[1]) far = k;
    if (dk < near[0] * near[0] + near[1] * near[1]) near = k;
  }
  const minH = Math.min(dl, dr), maxH = Math.max(dl, dr);
  const minV = Math.min(dt, db), maxV = Math.max(dt, db);

  let rx = 0, ry = 0;
  const circle = g.shape === CIRCLE;
  const u = g.rx.u;
  // A corner keyword sizes the ellipse so that it meets that corner, keeping the box's aspect
  // ratio: the corner is at (dx, dy), so rx = sqrt(dx² + (w/h · dy)²) and ry = rx · h/w. A
  // circle instead reaches the corner itself.
  if (u === P.U_FARTHEST_CORNER || u === P.U_CLOSEST_CORNER) {
    const c = u === P.U_FARTHEST_CORNER ? far : near;
    const r = Math.sqrt(c[0] * c[0] + c[1] * c[1]);
    if (circle || !(h > 0)) {
      rx = r;
      ry = r;
    } else {
      rx = Math.sqrt(c[0] * c[0] + (w / h) * (w / h) * c[1] * c[1]);
      ry = (rx * h) / w;
    }
  } else if (u === P.U_FARTHEST_SIDE) {
    rx = circle ? Math.max(maxH, maxV) : maxH;
    ry = circle ? rx : maxV;
  } else if (u === P.U_CLOSEST_SIDE) {
    rx = circle ? Math.min(minH, minV) : minH;
    ry = circle ? rx : minV;
  } else {
    rx = pxOf(g.rx.v, g.rx.u, w, fontSize, basis);
    ry = circle ? rx : pxOf(g.ry.v, g.ry.u, h, fontSize, basis);
  }
  // A centre outside the box, or a degenerate size, leaves nothing to draw the shape with; the
  // line then has no length and the tile is the last stop's colour, which the host paints by
  // extending a hair-long gradient over the whole tile.
  if (!(rx > 0)) rx = 0.001;
  if (!(ry > 0)) ry = 0.001;
  // A centre far outside the box (CSS allows any percentage, however extreme) would give
  // CoreGraphics coordinates too large to work with; scaling the whole shape about the tile keeps
  // the same picture, since the tile then spans a vanishing share of the radius.
  let extent = Math.abs(cx - x);
  if (Math.abs(cy - y) > extent) extent = Math.abs(cy - y);
  if (rx > extent) extent = rx;
  if (ry > extent) extent = ry;
  if (extent > 1000000) {
    const s = 1000000 / extent;
    cx = x + (cx - x) * s;
    cy = y + (cy - y) * s;
    rx *= s;
    ry *= s;
  }
  // A stop's length runs along the radius, which for an ellipse is its horizontal one.
  hostRadialGradient(x, y, w, h, cx, cy, rx, ry, stopsText(g, rx, fontSize, basis, currentColor), alpha);
}

/** Paints one tile of a conic gradient, over the box (x, y, w, h) it fills. */
function paintConic(g: Gradient, x: number, y: number, w: number, h: number, fontSize: number, basis: Basis, alpha: number,
  currentColor: number): void {
  const off = (l: Centre, base: number): number => {
    const o = pxOf(l.v, l.u, base, fontSize, basis);
    return l.edge === 1 ? base - o : o;
  };
  const cx = x + off(g.cx, w), cy = y + off(g.cy, h);
  // A stop's length runs along the turn, so it is measured on the circle through the farthest
  // corner: a full turn there is 2πr.
  let r = 0;
  const corners: number[][] = [[x, y], [x + w, y], [x, y + h], [x + w, y + h]];
  for (const c of corners) {
    const dx = c[0] - cx, dy = c[1] - cy;
    const d = Math.sqrt(dx * dx + dy * dy);
    if (d > r) r = d;
  }
  // CSS measures the angle clockwise from the top; CoreGraphics measures it from the positive x
  // axis towards the positive y axis, and the user space here is y down, so the turn starts a
  // quarter back.
  const angle = ((g.angle - 90) * Math.PI) / 180;
  const len = 2 * Math.PI * (r > 0 ? r : 1);
  hostConicGradient(x, y, w, h, cx, cy, angle, stopsText(g, len, fontSize, basis, currentColor), alpha);
}

/** Paints one tile of a gradient image over the box (x, y, w, h) it fills. */
export function paintGradientTile(encoded: string, x: number, y: number, w: number, h: number,
  fontSize: number, basis: Basis, alpha: number, currentColor: number): void {
  let g = cache.get(encoded);
  if (g === undefined) {
    g = decode(encoded);
    cache.set(encoded, g);
  }
  if (g === null) return;
  if (g.kind === LINEAR) paintLinear(g, x, y, w, h, fontSize, basis, alpha, currentColor);
  else if (g.kind === RADIAL) paintRadial(g, x, y, w, h, fontSize, basis, alpha, currentColor);
  else paintConic(g, x, y, w, h, fontSize, basis, alpha, currentColor);
}
