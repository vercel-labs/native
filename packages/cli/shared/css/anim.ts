// Transitions and animations, shared by the compiler and the runtime: the list rows and keyframe
// rows their values point into, the timing functions the engine evaluates, and the way a value
// is written back out as CSS.
//
// A transition-* or animation-* value is a row of numbers (unit U_LIST), one entry per
// comma-separated item. The rows live in one table, so identical lists share an id whichever
// property named them.

import * as P from "../props.ts";
import { RowTable } from "./rows.ts";
import {
  TK_MATRIX, TK_MATRIX_3D, TK_ROTATE, TK_ROTATE_3D, TK_SCALE, TK_SCALE_3D, TK_SCALE_X,
  TK_SCALE_Y, TK_SCALE_Z, transformRows,
} from "./transforms.ts";

/** The lists behind the transition-* and animation-* properties and their timing functions. */
export const animRows: RowTable = new RowTable();

/**
 * @keyframes blocks: one row per block, `[name id, offset, property, value, unit, ...]`. The
 * offsets are sorted by the engine, so a sheet may write them in any order; several rows share a
 * name id, and a later @keyframes of the same name replaces the earlier one when it is compiled.
 */
export const animKeyframes: RowTable = new RowTable();

/**
 * The names animation-name and @keyframes use, in id order. The build registers the ones its
 * style sheets name and the runtime reads them back; a name a script invents is added after
 * those, so it can still be round-tripped through getComputedStyle (it just has no keyframes).
 */
export class AnimNames {
  private byId: Map<number, string> = new Map();
  private ids: Map<string, number> = new Map();
  private next: number = 0;

  register(name: string): number {
    const hit = this.ids.get(name);
    if (hit !== undefined) return hit;
    const id = this.next++;
    this.byId.set(id, name);
    this.ids.set(name, id);
    return id;
  }

  load(names: readonly string[]): void {
    this.byId = new Map();
    this.ids = new Map();
    for (let i = 0; i < names.length; i++) {
      this.byId.set(i, names[i]);
      this.ids.set(names[i], i);
    }
    this.next = names.length;
  }

  /** The id for a name, or -1 when nothing has registered it. */
  id(name: string): number {
    const hit = this.ids.get(name);
    return hit === undefined ? -1 : hit;
  }

  name(id: number): string {
    const hit = this.byId.get(id);
    return hit === undefined ? "" : hit;
  }

  all(): string[] {
    const out: string[] = [];
    for (let id = 0; id < this.next; id++) {
      const name = this.byId.get(id);
      if (name !== undefined) out.push(name);
    }
    return out;
  }
}

export const animNames: AnimNames = new AnimNames();

// ---------------------------------------------------------------------------
// Composition

/**
 * How a keyframe's value combines with the value below it: replace it, add to it, or accumulate
 * it (add, counted once per iteration). A script keyframe's `composite` and a stylesheet's
 * animation-composition both name one of these.
 */
export const AC_REPLACE = 0;
export const AC_ADD = 1;
export const AC_ACCUMULATE = 2;

/**
 * The composite code rides in a keyframe row's unit, above the unit's own value, so a row stays
 * the triple `[property, value, unit]` the build writes and every reader steps by.
 */
const COMP_SHIFT = 16;

/** A row's unit with a composite code packed above it. */
export function packUnit(unit: number, comp: number): number {
  return unit | (comp << COMP_SHIFT);
}

/** The unit a packed row value carries. */
export function unitOf(packed: number): number {
  return packed & 0xffff;
}

/** The composite a packed row value carries. */
export function compositeOf(packed: number): number {
  return packed >> COMP_SHIFT;
}

/** The code a keyframe row carries for a CSS-wide keyword, under unit U_WIDE. */
export function wideCode(keyword: string): number {
  if (keyword === "inherit") return P.WK_INHERIT;
  if (keyword === "initial") return P.WK_INITIAL;
  if (keyword === "revert" || keyword === "revert-layer") return P.WK_REVERT;
  return P.WK_UNSET;
}

// ---------------------------------------------------------------------------
// Timing functions

/**
 * A timing function as a row: `[kind]` for the named curves, `[TF_CUBIC, x1, y1, x2, y2]` for
 * cubic-bezier() and `[TF_STEPS, count, jump]` for steps(). Null when the text isn't one.
 */
export function timingRow(text: string): number[] | null {
  const s = text.trim().toLowerCase();
  if (s === "linear") return [P.TF_LINEAR];
  if (s === "ease") return [P.TF_EASE];
  if (s === "ease-in") return [P.TF_EASE_IN];
  if (s === "ease-out") return [P.TF_EASE_OUT];
  if (s === "ease-in-out") return [P.TF_EASE_IN_OUT];
  if (s === "step-start") return [P.TF_STEPS, 1, P.STEPS_START];
  if (s === "step-end") return [P.TF_STEPS, 1, P.STEPS_END];
  const cb = /^cubic-bezier\(([^()]*)\)$/.exec(s);
  if (cb !== null) {
    const parts = cb[1].split(",");
    if (parts.length !== 4) return null;
    const n: number[] = [];
    for (const part of parts) {
      const v = Number(part.trim());
      if (!Number.isFinite(v)) return null;
      n.push(v);
    }
    // The x coordinates must stay in [0, 1] for the curve to be a function of time.
    if (n[0] < 0 || n[0] > 1 || n[2] < 0 || n[2] > 1) return null;
    return [P.TF_CUBIC, n[0], n[1], n[2], n[3]];
  }
  const st = /^steps\(([^()]*)\)$/.exec(s);
  if (st !== null) {
    const parts = st[1].split(",");
    if (parts.length < 1 || parts.length > 2) return null;
    const count = Number(parts[0].trim());
    if (!Number.isInteger(count) || count < 1) return null;
    let jump = P.STEPS_END;
    if (parts.length === 2) {
      const pos = parts[1].trim();
      if (pos === "start" || pos === "jump-start") jump = P.STEPS_START;
      else if (pos === "end" || pos === "jump-end") jump = P.STEPS_END;
      else if (pos === "jump-none") jump = P.STEPS_NONE;
      else if (pos === "jump-both") jump = P.STEPS_BOTH;
      else return null;
    }
    // jump-none needs a step to hold at each end.
    if (jump === P.STEPS_NONE && count < 2) return null;
    return [P.TF_STEPS, count, jump];
  }
  return null;
}

/** A timing function row as CSS text. */
export function timingText(row: readonly number[]): string {
  const kind = row.length > 0 ? row[0] : P.TF_EASE;
  if (kind === P.TF_LINEAR) return "linear";
  if (kind === P.TF_EASE_IN) return "ease-in";
  if (kind === P.TF_EASE_OUT) return "ease-out";
  if (kind === P.TF_EASE_IN_OUT) return "ease-in-out";
  if (kind === P.TF_CUBIC && row.length >= 5) {
    return "cubic-bezier(" + num(row[1]) + ", " + num(row[2]) + ", " + num(row[3]) + ", " + num(row[4]) + ")";
  }
  if (kind === P.TF_STEPS && row.length >= 3) {
    const jump = row[2];
    const pos = jump === P.STEPS_START ? ", start" : jump === P.STEPS_NONE ? ", jump-none" : jump === P.STEPS_BOTH ? ", jump-both" : "";
    return "steps(" + num(row[1]) + pos + ")";
  }
  return "ease";
}

// The cubic-bezier control points of the named curves (CSS Easing 1).
const EASE: number[] = [0.25, 0.1, 0.25, 1];
const EASE_IN: number[] = [0.42, 0, 1, 1];
const EASE_OUT: number[] = [0, 0, 0.58, 1];
const EASE_IN_OUT: number[] = [0.42, 0, 0.58, 1];

function curveOf(row: readonly number[]): number[] {
  const kind = row.length > 0 ? row[0] : P.TF_EASE;
  if (kind === P.TF_LINEAR) return [0, 0, 1, 1];
  if (kind === P.TF_EASE_IN) return EASE_IN;
  if (kind === P.TF_EASE_OUT) return EASE_OUT;
  if (kind === P.TF_EASE_IN_OUT) return EASE_IN_OUT;
  if (kind === P.TF_CUBIC && row.length >= 5) return [row[1], row[2], row[3], row[4]];
  return EASE;
}

function bezier(a: number, b: number, t: number): number {
  // A cubic Bézier with the end points fixed at 0 and 1.
  const u = 1 - t;
  return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t;
}

function bezierSlope(a: number, b: number, t: number): number {
  const u = 1 - t;
  return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b);
}

/** Solves the curve's x for `t` (a cubic-bezier is a function of x through a parameter). */
function solveT(x1: number, x2: number, x: number): number {
  let t = x;
  for (let i = 0; i < 8; i++) {
    const err = bezier(x1, x2, t) - x;
    if (Math.abs(err) < 0.00001) return t;
    const d = bezierSlope(x1, x2, t);
    if (Math.abs(d) < 0.00001) break;
    t -= err / d;
  }
  // Newton's method can leave the bracket; fall back to bisection, which always converges here.
  let lo = 0, hi = 1;
  t = x;
  for (let i = 0; i < 24; i++) {
    const v = bezier(x1, x2, t);
    if (Math.abs(v - x) < 0.00001) break;
    if (v < x) lo = t;
    else hi = t;
    t = (lo + hi) / 2;
  }
  return t;
}

/**
 * The eased progress for a timing function at fraction `t` of the way through an interval. A
 * step function holds the value of its step until the next one starts.
 */
export function ease(row: readonly number[], t: number): number {
  const kind = row.length > 0 ? row[0] : P.TF_EASE;
  if (kind === P.TF_STEPS && row.length >= 3) {
    const n = row[1];
    const jump = row[2];
    // `start` jumps at the beginning (one step ahead), `end` at the next step; jump-none holds
    // 0 and n/n-1 at the ends (clamped to 1), and jump-both jumps at both.
    if (jump === P.STEPS_START) return clamp01((Math.floor(t * n) + 1) / n);
    if (jump === P.STEPS_BOTH) return clamp01((Math.floor(t * n) + 1) / (n + 1));
    if (jump === P.STEPS_NONE) return clamp01(Math.floor(t * n) / (n - 1));
    return clamp01(Math.floor(t * n) / n);
  }
  if (t <= 0) return 0;
  if (t >= 1) return 1;
  const c = curveOf(row);
  if (c[0] === 0 && c[1] === 0 && c[2] === 1 && c[3] === 1) return t;
  return bezier(c[1], c[3], solveT(c[0], c[2], t));
}

function clamp01(v: number): number {
  return v < 0 ? 0 : v > 1 ? 1 : v;
}

/** A colour channel as a fraction of 255, rounded into 0..255. */
function byte(v: number): number {
  const n = Math.round(v * 255);
  return n < 0 ? 0 : n > 255 ? 255 : n;
}

// ---------------------------------------------------------------------------
// Time values

/** A <time> in milliseconds, or null. A bare zero is accepted, as for every other length. */
export function timeMs(text: string): number | null {
  const s = text.trim().toLowerCase();
  const m = /^([-+]?(?:\d+\.?\d*|\.\d+))(s|ms)$/.exec(s);
  if (m === null) return s === "0" ? 0 : null;
  const n = parseFloat(m[1]);
  return m[2] === "s" ? n * 1000 : n;
}

/** Milliseconds as CSS writes them: in seconds, with no trailing zeros. */
export function timeText(ms: number): string {
  return num(ms / 1000) + "s";
}

/** A number as CSS writes it: no exponent, and no trailing zeros. */
export function num(n: number): string {
  const r = Math.round(n * 1000) / 1000;
  return r === 0 ? "0" : String(r);
}

/**
 * The length `text-decoration-inset: auto` uses at a font size: the browser's own line metric,
 * one pixel at the default size and growing to two from 40px up (as Chrome computes it).
 */
export function autoInsetPx(fontSize: number): number {
  const v = fontSize / 20;
  return v < 1 ? 1 : v > 2 ? 2 : v;
}

// ---------------------------------------------------------------------------
// Animatable properties

/** The color properties, interpolated per channel. */
const COLOR_PROPS: number[] = [
  P.P_COLOR, P.P_BACKGROUND_COLOR, P.P_BORDER_TOP_COLOR, P.P_BORDER_RIGHT_COLOR,
  P.P_BORDER_BOTTOM_COLOR, P.P_BORDER_LEFT_COLOR, P.P_OUTLINE_COLOR,
  // The other colours that hold a packed colour with the -1 currentColor sentinel: a keyframe's
  // currentColor reaches for the element's own colour like any other, rather than being mixed as
  // a number.
  P.P_COLUMN_RULE_COLOR, P.P_TEXT_DECORATION_COLOR, P.P_TEXT_EMPHASIS_COLOR, P.P_CARET_COLOR,
  P.P_FLOOD_COLOR, P.P_LIGHTING_COLOR,
];

/** The properties holding a plain number, interpolated arithmetically. */
const NUMBER_PROPS: number[] = [
  P.P_OPACITY, P.P_FONT_WEIGHT, P.P_LINE_HEIGHT, P.P_FLEX_GROW, P.P_FLEX_SHRINK,
  P.P_ORDER, P.P_Z_INDEX, P.P_TAB_SIZE,
];

/** The properties holding a length, interpolated when both ends share a unit. */
const LENGTH_PROPS: number[] = [
  P.P_WIDTH, P.P_HEIGHT, P.P_MIN_WIDTH, P.P_MAX_WIDTH, P.P_MIN_HEIGHT, P.P_MAX_HEIGHT,
  P.P_MARGIN_TOP, P.P_MARGIN_RIGHT, P.P_MARGIN_BOTTOM, P.P_MARGIN_LEFT,
  P.P_PADDING_TOP, P.P_PADDING_RIGHT, P.P_PADDING_BOTTOM, P.P_PADDING_LEFT,
  P.P_BORDER_TOP_WIDTH, P.P_BORDER_RIGHT_WIDTH, P.P_BORDER_BOTTOM_WIDTH, P.P_BORDER_LEFT_WIDTH,
  P.P_BORDER_TOP_LEFT_RADIUS, P.P_BORDER_TOP_LEFT_RADIUS_Y, P.P_BORDER_TOP_RIGHT_RADIUS,
  P.P_BORDER_TOP_RIGHT_RADIUS_Y, P.P_BORDER_BOTTOM_RIGHT_RADIUS, P.P_BORDER_BOTTOM_RIGHT_RADIUS_Y,
  P.P_BORDER_BOTTOM_LEFT_RADIUS, P.P_BORDER_BOTTOM_LEFT_RADIUS_Y,
  P.P_ROW_GAP, P.P_COLUMN_GAP, P.P_TOP, P.P_RIGHT, P.P_BOTTOM, P.P_LEFT,
  P.P_FONT_SIZE, P.P_LETTER_SPACING, P.P_WORD_SPACING, P.P_TEXT_INDENT,
  P.P_OUTLINE_WIDTH, P.P_OUTLINE_OFFSET, P.P_BORDER_SPACING_H, P.P_BORDER_SPACING_V,
  P.P_FLEX_BASIS, P.P_VERTICAL_ALIGN,
];

/** Every property a transition or an animation can move. A transform list mixes function by
 *  function, or through the matrices the two lists resolve to (see listMix and mixMatrix). */
export const ANIMATABLE: number[] = COLOR_PROPS.concat(NUMBER_PROPS).concat(LENGTH_PROPS)
  .concat([P.P_TRANSFORM, P.P_TEXT_SHADOW, P.P_BOX_SHADOW, P.P_DISPLAY,
    P.P_TEXT_DECORATION_INSET, P.P_TEXT_DECORATION_INSET_END]);

export function isAnimatable(p: number): boolean {
  return ANIMATABLE.indexOf(p) >= 0;
}

/** Whether a property's values interpolate only when both ends share a unit; other pairs are discrete. */
export function needsSameUnit(p: number): boolean {
  return NUMBER_PROPS.indexOf(p) >= 0 || LENGTH_PROPS.indexOf(p) >= 0;
}

export function isColorProperty(p: number): boolean {
  return COLOR_PROPS.indexOf(p) >= 0;
}

/**
 * A value part of the way between two others: colors mix per channel (a -1 is currentColor,
 * resolved from `current`), two numbers of the same unit interpolate arithmetically, and
 * anything else flips at the halfway point, as CSS does with discrete values. The result is
 * [value, unit]; a color keeps unit U_NONE.
 */
export function mixValue(p: number, av: number, au: number, bv: number, bu: number, t: number, current: number): number[] {
  if (isColorProperty(p) && au === P.U_NONE && bu === P.U_NONE) {
    const a = av < 0 ? current : av;
    const b = bv < 0 ? current : bv;
    const ar = (a >>> 24) & 255, ag = (a >>> 16) & 255, ab = (a >>> 8) & 255, aa = a & 255;
    const br = (b >>> 24) & 255, bg = (b >>> 16) & 255, bb = (b >>> 8) & 255, ba = b & 255;
    // Colours interpolate premultiplied by alpha (CSS Color 4), so a colour fading in from
    // transparent keeps its hue instead of darkening toward black; the result is divided back.
    const alF = aa + (ba - aa) * t;
    const w = alF < 0 ? 0 : alF > 255 ? 1 : alF / 255;
    const pre = (ac: number, bc: number): number => {
      if (w === 0) return 0;
      const va = (ac / 255) * (aa / 255);
      const vb = (bc / 255) * (ba / 255);
      return (va + (vb - va) * t) / w;
    };
    const r = byte(pre(ar, br));
    const g = byte(pre(ag, bg));
    const bl = byte(pre(ab, bb));
    const al = Math.round(alF < 0 ? 0 : alF > 255 ? 255 : alF);
    return [((r << 24) | (g << 16) | (bl << 8) | al) >>> 0, P.U_NONE];
  }
  if (p === P.P_DISPLAY) {
    // display flips at the end of the interval when it becomes none, at the start when it leaves
    // none, and at the halfway point between any other two values.
    const aNone = av === P.D_NONE;
    const bNone = bv === P.D_NONE;
    if (aNone && !bNone) return t <= 0 ? [av, au] : [bv, bu];
    if (!aNone && bNone) return t < 1 ? [av, au] : [bv, bu];
    return t < 0.5 ? [av, au] : [bv, bu];
  }
  if (au === bu && au !== P.U_AUTO && au !== P.U_NORMAL && au !== P.U_EXPR) {
    const v = av + (bv - av) * t;
    // z-index is an integer: a browser rounds the interpolated value at each sample.
    return [p === P.P_Z_INDEX ? Math.round(v) : v, au];
  }
  return t < 0.5 ? [av, au] : [bv, bu];
}

// ---------------------------------------------------------------------------
// Transform lists

/** The value a function's parameters take when the list stands for no transform at all. */
function identityPair(kind: number, k: number): number {
  if (kind === TK_MATRIX) return k === 0 || k === 3 ? 1 : 0;
  if (kind === TK_MATRIX_3D) return k % 5 === 0 ? 1 : 0;
  if (kind === TK_SCALE || kind === TK_SCALE_X || kind === TK_SCALE_Y || kind === TK_SCALE_3D ||
    kind === TK_SCALE_Z) return 1;
  return 0;
}

/** A transform list row with the same functions at their identity values, keeping their units. */
function identityRow(row: readonly number[]): number[] {
  const out: number[] = [row[0]];
  let at = 1;
  for (let i = 0; i < (row[0] | 0); i++) {
    const kind = row[at];
    const np = row[at + 1] | 0;
    out.push(kind, np);
    for (let k = 0; k < np; k++) {
      // A rotate3d keeps its axis and turns it nothing, the only identity it has.
      const v = kind === TK_ROTATE_3D && k < np - 1 ? row[at + 2 + k * 2] : identityPair(kind, k);
      out.push(v, row[at + 3 + k * 2]);
    }
    at += 2 + np * 2;
  }
  return out;
}

/**
 * A transform list a share of the way to another, function by function. The two lists must name
 * the same functions in the same order, and each parameter must have the same unit at both ends
 * (angles and scales are unitless). `none` mixes as the identity of the other list's functions.
 * Null when the two lists can't be mixed that way, so the matrices they resolve to stand in.
 */
export function listMix(av: number, bv: number, t: number): number | null {
  const rowA = av < 0 ? null : transformRows.row(av);
  const rowB = bv < 0 ? null : transformRows.row(bv);
  if (rowA === null && rowB === null) return -1;
  const a = rowA === null ? identityRow(rowB as readonly number[]) : rowA;
  const b = rowB === null ? identityRow(rowA as readonly number[]) : rowB;
  if (a[0] !== b[0]) return null;
  const out: number[] = [a[0]];
  let at = 1;
  for (let i = 0; i < (a[0] | 0); i++) {
    const kind = a[at];
    const np = a[at + 1] | 0;
    if (kind !== b[at] || np !== (b[at + 1] | 0)) return null;
    out.push(kind, np);
    for (let k = 0; k < np; k++) {
      const av2 = a[at + 2 + k * 2], au = a[at + 3 + k * 2];
      const bv2 = b[at + 2 + k * 2], bu = b[at + 3 + k * 2];
      if (au !== bu || au === P.U_EXPR) return null;
      out.push(av2 + (bv2 - av2) * t, au);
    }
    at += 2 + np * 2;
  }
  return transformRows.register(out);
}

/**
 * A 2D matrix [a, b, c, d, e, f] a share of the way between two others: each is decomposed into
 * its translation, rotation, scale and skew, the parts are interpolated (the rotation the short
 * way round), and the result is composed again, as CSS Transforms 2 interpolates matrices.
 */
export function mixMatrix(av: readonly number[], bv: readonly number[], t: number): number[] {
  const da = decompose2(av);
  const db = decompose2(bv);
  if (da === null || db === null) {
    // A degenerate or mirrored matrix has no decomposition; its entries go straight across.
    const flat: number[] = [];
    for (let i = 0; i < 6; i++) flat.push(av[i] + (bv[i] - av[i]) * t);
    return flat;
  }
  let turn = db[2] - da[2];
  while (turn > Math.PI) turn -= 2 * Math.PI;
  while (turn < -Math.PI) turn += 2 * Math.PI;
  const parts: number[] = [
    da[0] + (db[0] - da[0]) * t,
    da[1] + (db[1] - da[1]) * t,
    da[2] + turn * t,
    da[3] + (db[3] - da[3]) * t,
    da[4] + (db[4] - da[4]) * t,
    da[5] + (db[5] - da[5]) * t,
  ];
  return compose2(parts);
}

/** [translate x, translate y, rotation, scale x, scale y, skew] of a matrix, or null if it has no
 *  inverse or turns the plane over, which the caller interpolates entry by entry instead. */
function decompose2(m: readonly number[]): number[] | null {
  let a = m[0], b = m[1], c = m[2], d = m[3];
  const det = a * d - b * c;
  if (!(det > 0) || !Number.isFinite(det)) return null;
  const sx = Math.hypot(a, b);
  if (sx === 0) return null;
  a /= sx;
  b /= sx;
  const shear = a * c + b * d;
  c -= a * shear;
  d -= b * shear;
  const sy = Math.hypot(c, d);
  if (sy === 0) return null;
  return [m[4], m[5], Math.atan2(b, a), sx, sy, shear / sy];
}

/** The matrix [rotate, skew, scale, translate] names, in that order, as the decomposition above. */
function compose2(p: readonly number[]): number[] {
  const cos = Math.cos(p[2]);
  const sin = Math.sin(p[2]);
  const s = p[5];
  return [
    p[3] * cos,
    p[3] * sin,
    p[4] * (s * cos - sin),
    p[4] * (s * sin + cos),
    p[0],
    p[1],
  ];
}

// ---------------------------------------------------------------------------
// Serializing values

/** The numbers behind a list property, with its initial value when nothing set it. */
export function valueList(p: number, v: number, u: number): number[] {
  if (u === P.U_LIST) {
    const row = animRows.row(v);
    if (row !== null && row.length > 0) return copyOf(row);
  }
  const one: number[] = [initialItem(p)];
  return one;
}

/** The single item a list property starts with, when it isn't set. */
export function initialItem(p: number): number {
  if (p === P.P_TRANSITION_PROPERTY || p === P.P_ANIMATION_NAME) return -1; // all / none
  if (p === P.P_TRANSITION_TIMING_FUNCTION || p === P.P_ANIMATION_TIMING_FUNCTION) return P.TF_EASE;
  if (p === P.P_TRANSITION_BEHAVIOR) return P.TB_NORMAL;
  if (p === P.P_ANIMATION_ITERATION_COUNT) return 1;
  if (p === P.P_ANIMATION_DIRECTION) return P.AD_NORMAL;
  if (p === P.P_ANIMATION_FILL_MODE) return P.AF_NONE;
  if (p === P.P_ANIMATION_PLAY_STATE) return P.APS_RUNNING;
  if (p === P.P_ANIMATION_COMPOSITION) return AC_REPLACE;
  return 0; // a time
}

function copyOf(row: readonly number[]): number[] {
  const out: number[] = [];
  for (const n of row) out.push(n);
  return out;
}

export const DIRECTION_NAMES: string[] = ["normal", "reverse", "alternate", "alternate-reverse"];
export const FILL_MODE_NAMES: string[] = ["none", "forwards", "backwards", "both"];
export const PLAY_STATE_NAMES: string[] = ["running", "paused"];
export const COMPOSITION_NAMES: string[] = ["replace", "add", "accumulate"];

/**
 * A transition-* or animation-* value as CSS text, or null for a property this module doesn't
 * serialize.
 */
export function animValueText(p: number, v: number, u: number): string | null {
  if (p !== P.P_TRANSITION_PROPERTY && p !== P.P_TRANSITION_DURATION && p !== P.P_TRANSITION_TIMING_FUNCTION &&
    p !== P.P_TRANSITION_DELAY && p !== P.P_TRANSITION_BEHAVIOR && p !== P.P_ANIMATION_NAME && p !== P.P_ANIMATION_DURATION &&
    p !== P.P_ANIMATION_TIMING_FUNCTION && p !== P.P_ANIMATION_DELAY && p !== P.P_ANIMATION_ITERATION_COUNT &&
    p !== P.P_ANIMATION_DIRECTION && p !== P.P_ANIMATION_FILL_MODE && p !== P.P_ANIMATION_PLAY_STATE &&
    p !== P.P_ANIMATION_COMPOSITION) return null;
  const items = valueList(p, v, u);
  let s = "";
  for (let i = 0; i < items.length; i++) {
    if (i > 0) s += ", ";
    s += itemText(p, items[i]);
  }
  return s;
}

/**
 * A transition-property name that isn't one of the longhands this build knows, kept by name:
 * a shorthand, an unsupported property, or a custom property. CSS allows any <custom-ident>
 * there, and only the ones the engine can interpolate ever start a transition.
 */
export function transitionNameItem(name: string): number {
  return -(animNames.register(name) + 3);
}

/** One item of a list value as CSS text. */
export function itemText(p: number, item: number): string {
  if (p === P.P_TRANSITION_PROPERTY) {
    if (item === -1) return "all";
    if (item === -2) return "none";
    if (item <= -3) return animNames.name(-item - 3);
    return item >= 0 && item < P.PROPERTY_NAMES.length ? P.PROPERTY_NAMES[item] : "";
  }
  if (p === P.P_TRANSITION_DURATION || p === P.P_TRANSITION_DELAY ||
    p === P.P_ANIMATION_DURATION || p === P.P_ANIMATION_DELAY) return timeText(item);
  if (p === P.P_TRANSITION_TIMING_FUNCTION || p === P.P_ANIMATION_TIMING_FUNCTION) {
    const row = animRows.row(item);
    return row === null ? "ease" : timingText(row);
  }
  if (p === P.P_ANIMATION_NAME) return item < 0 ? "none" : animNames.name(item);
  if (p === P.P_ANIMATION_ITERATION_COUNT) return item < 0 ? "infinite" : num(item);
  if (p === P.P_ANIMATION_DIRECTION) return item >= 0 && item < DIRECTION_NAMES.length ? DIRECTION_NAMES[item] : "normal";
  if (p === P.P_ANIMATION_FILL_MODE) return item >= 0 && item < FILL_MODE_NAMES.length ? FILL_MODE_NAMES[item] : "none";
  if (p === P.P_ANIMATION_PLAY_STATE) return item >= 0 && item < PLAY_STATE_NAMES.length ? PLAY_STATE_NAMES[item] : "running";
  if (p === P.P_ANIMATION_COMPOSITION) return item >= 0 && item < COMPOSITION_NAMES.length ? COMPOSITION_NAMES[item] : "replace";
  if (p === P.P_TRANSITION_BEHAVIOR) return item === P.TB_ALLOW_DISCRETE ? "allow-discrete" : "normal";
  return "";
}

/** The longhand ids of the `transition` shorthand, in the order the shorthand writes them. */
export const TRANSITION_LONGHANDS: number[] = [
  P.P_TRANSITION_PROPERTY, P.P_TRANSITION_DURATION, P.P_TRANSITION_TIMING_FUNCTION, P.P_TRANSITION_DELAY,
  P.P_TRANSITION_BEHAVIOR,
];

/** The longhand ids of the `animation` shorthand, in the order the shorthand writes them. */
export const ANIMATION_LONGHANDS: number[] = [
  P.P_ANIMATION_DURATION, P.P_ANIMATION_TIMING_FUNCTION, P.P_ANIMATION_DELAY, P.P_ANIMATION_ITERATION_COUNT,
  P.P_ANIMATION_DIRECTION, P.P_ANIMATION_FILL_MODE, P.P_ANIMATION_PLAY_STATE, P.P_ANIMATION_NAME,
];
