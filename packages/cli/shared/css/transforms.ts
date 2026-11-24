// CSS 2D transforms: `transform`, `transform-origin` and the individual `translate`, `rotate`
// and `scale` values, with the matrix each one resolves to.
//
// A value is a row of one of the two tables below (see ./rows.ts), shared by the build and the
// runtime so an inline style gets the same ids as a compiled rule. A transform list row holds
// the function count, then one record per function: its kind, the number of value/unit pairs
// that follow, and the pairs. Lengths keep their units until the matrix is built, since a
// translate() percentage resolves against the element's border box and an em against its font
// size.

import * as P from "../props.ts";
import { calcAngle, parseLength } from "./declarations.ts";
import { evalExpr, exprText } from "./length-exprs.ts";
import { splitValue } from "./fonts.ts";
import { RowTable } from "./rows.ts";

export const transformRows: RowTable = new RowTable();
export const originRows: RowTable = new RowTable();

// Transform function kinds.
export const TK_MATRIX = 0;
export const TK_TRANSLATE = 1;
export const TK_TRANSLATE_X = 2;
export const TK_TRANSLATE_Y = 3;
export const TK_SCALE = 4;
export const TK_SCALE_X = 5;
export const TK_SCALE_Y = 6;
export const TK_ROTATE = 7;
export const TK_SKEW = 8;
export const TK_SKEW_X = 9;
export const TK_SKEW_Y = 10;
// The 3D functions. They compose in a 4x4 matrix like any other and the list's matrix is
// projected at the end, so `rotatex(90deg) scale3d(2,1,2) rotatex(-90deg)` is the flat
// `scale(2,2)` it multiplies out to rather than three separate flat approximations.
export const TK_TRANSLATE_3D = 11;
export const TK_TRANSLATE_Z = 12;
export const TK_SCALE_3D = 13;
export const TK_SCALE_Z = 14;
export const TK_ROTATE_X = 15;
export const TK_ROTATE_Y = 16;
export const TK_ROTATE_Z = 17;
export const TK_ROTATE_3D = 18;
export const TK_MATRIX_3D = 19;
export const TK_PERSPECTIVE = 20;

/**
 * An angle in radians. CSS accepts deg, grad, rad and turn; a bare zero is valid too, and a
 * calc() of angles folds at build time. Null for anything else.
 */
export function parseAngle(s: string): number | null {
  const t = s.trim().toLowerCase();
  const m = /^([-+]?(?:\d+\.?\d*|\.\d+))(deg|grad|rad|turn)?$/.exec(t);
  if (m === null) return calcAngle(t);
  const n = parseFloat(m[1]);
  switch (m[2]) {
    case "deg": return (n * Math.PI) / 180;
    case "grad": return (n * Math.PI) / 200;
    case "rad": return n;
    case "turn": return n * 2 * Math.PI;
    case undefined: return n === 0 ? 0 : null;
  }
  return null;
}

/** A plain number, as scale() takes. */
function parseNumber(s: string): number | null {
  const t = s.trim().toLowerCase();
  if (!/^[-+]?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?$/.test(t)) return null;
  return parseFloat(t);
}

/** The arguments of a function `name(...)`, or null when the text isn't that function. */
function fnArgs(value: string, name: string): string[] | null {
  if (!value.startsWith(name + "(") || !value.endsWith(")")) return null;
  const inner = value.slice(name.length + 1, value.length - 1).trim();
  if (inner === "") return [];
  // Split on top-level commas or spaces: translate(x y) and translate(x, y) both count.
  const args: string[] = [];
  let depth = 0, start = -1;
  for (let i = 0; i < inner.length; i++) {
    const ch = inner[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    if (depth === 0 && (ch === "," || /\s/.test(ch))) {
      if (start >= 0) args.push(inner.slice(start, i));
      start = -1;
    } else if (start < 0) start = i;
  }
  if (start >= 0) args.push(inner.slice(start));
  return args;
}

/** Splits a transform list into its top-level function tokens. */
function fnTokens(value: string): string[] | null {
  const out: string[] = [];
  let depth = 0, start = -1;
  for (let i = 0; i < value.length; i++) {
    const ch = value[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    if (depth === 0 && /\s/.test(ch)) {
      if (start >= 0) out.push(value.slice(start, i));
      start = -1;
    } else if (start < 0) start = i;
  }
  if (start >= 0) out.push(value.slice(start));
  for (const t of out) if (!t.endsWith(")")) return null;
  return out;
}

const FUNCTIONS: [string, number][] = [
  ["matrix", TK_MATRIX], ["translate", TK_TRANSLATE], ["translatex", TK_TRANSLATE_X],
  ["translatey", TK_TRANSLATE_Y], ["scale", TK_SCALE], ["scalex", TK_SCALE_X],
  ["scaley", TK_SCALE_Y], ["rotate", TK_ROTATE], ["skew", TK_SKEW], ["skewx", TK_SKEW_X],
  ["skewy", TK_SKEW_Y], ["translate3d", TK_TRANSLATE_3D], ["translatez", TK_TRANSLATE_Z],
  ["scale3d", TK_SCALE_3D], ["scalez", TK_SCALE_Z], ["rotatex", TK_ROTATE_X],
  ["rotatey", TK_ROTATE_Y], ["rotatez", TK_ROTATE_Z], ["rotate3d", TK_ROTATE_3D],
  ["matrix3d", TK_MATRIX_3D], ["perspective", TK_PERSPECTIVE],
];

/**
 * How many value/unit pairs a function's record holds. A record is
 * `[kind, pairCount, value0, unit0, value1, unit1, …]`.
 */
function pairCount(kind: number): number {
  switch (kind) {
    case TK_MATRIX: return 6;
    case TK_TRANSLATE:
    case TK_SCALE:
    case TK_SKEW: return 2;
    case TK_TRANSLATE_3D:
    case TK_SCALE_3D: return 3;
    case TK_ROTATE_3D: return 4;
    case TK_MATRIX_3D: return 16;
  }
  return 1;
}

/** One function's record, trimmed from the padded row of pairs a branch fills in. */
function record(rec: readonly number[], np: number): number[] {
  const out: number[] = [rec[0], np];
  for (let k = 0; k < np * 2; k++) out.push(rec[1 + k]);
  return out;
}

/** One transform function as a row record: the kind, then six value/unit pairs. */
function fnRecord(token: string): number[] | null {
  const t = token.trim().toLowerCase();
  for (const [name, kind] of FUNCTIONS) {
    const args = fnArgs(t, name);
    if (args === null) continue;
    const np = pairCount(kind);
    const rec = [kind, 0, P.U_NONE, 0, P.U_NONE, 0, P.U_NONE, 0, P.U_NONE, 0, P.U_NONE, 0, P.U_NONE];
    const len = (s: string, at: number): boolean => {
      const l = parseLength(s, false);
      if (l === null) return false;
      rec[at] = l.v;
      rec[at + 1] = l.u;
      return true;
    };
    const num = (s: string, at: number): boolean => {
      const n = parseNumber(s);
      if (n === null) return false;
      rec[at] = n;
      rec[at + 1] = P.U_NONE;
      return true;
    };
    const ang = (s: string, at: number): boolean => {
      const a = parseAngle(s);
      if (a === null) return false;
      rec[at] = a;
      rec[at + 1] = P.U_NONE;
      return true;
    };
    if (kind === TK_MATRIX) {
      if (args.length !== 6) return null;
      for (let k = 0; k < 6; k++) if (!num(args[k], 1 + k * 2)) return null;
      return record(rec, np);
    }
    if (kind === TK_TRANSLATE) {
      if (args.length < 1 || args.length > 2) return null;
      if (!len(args[0], 1)) return null;
      if (args.length > 1) { if (!len(args[1], 3)) return null; }
      return record(rec, np);
    }
    if (kind === TK_TRANSLATE_X || kind === TK_TRANSLATE_Y) {
      if (args.length !== 1) return null;
      return len(args[0], 1) ? record(rec, np) : null;
    }
    if (kind === TK_PERSPECTIVE) {
      // A perspective distance is a non-negative length (not a percentage); a negative one is
      // invalid, and a distance under 1px draws as 1px without changing the computed value.
      if (args.length !== 1 || !len(args[0], 1) || rec[2] === P.U_PCT || rec[1] < 0) return null;
      return record(rec, np);
    }
    if (kind === TK_SCALE) {
      if (args.length < 1 || args.length > 2) return null;
      if (!num(args[0], 1)) return null;
      if (args.length > 1) { if (!num(args[1], 3)) return null; }
      else { rec[3] = rec[1]; rec[4] = P.U_NONE; }
      return record(rec, np);
    }
    if (kind === TK_SCALE_X || kind === TK_SCALE_Y) {
      if (args.length !== 1) return null;
      return num(args[0], 1) ? record(rec, np) : null;
    }
    if (kind === TK_ROTATE || kind === TK_SKEW_X || kind === TK_SKEW_Y) {
      if (args.length !== 1) return null;
      return ang(args[0], 1) ? record(rec, np) : null;
    }
    if (kind === TK_TRANSLATE_3D) {
      if (args.length !== 3) return null;
      if (!len(args[0], 1) || !len(args[1], 3) || !len(args[2], 5)) return null;
      return record(rec, np);
    }
    if (kind === TK_TRANSLATE_Z) {
      if (args.length !== 1) return null;
      return len(args[0], 1) ? record(rec, np) : null;
    }
    if (kind === TK_SCALE_3D) {
      if (args.length !== 3) return null;
      if (!num(args[0], 1) || !num(args[1], 3) || !num(args[2], 5)) return null;
      return record(rec, np);
    }
    if (kind === TK_SCALE_Z) {
      if (args.length !== 1) return null;
      return num(args[0], 1) ? record(rec, np) : null;
    }
    if (kind === TK_ROTATE_X || kind === TK_ROTATE_Y || kind === TK_ROTATE_Z) {
      if (args.length !== 1) return null;
      return ang(args[0], 1) ? record(rec, np) : null;
    }
    if (kind === TK_ROTATE_3D) {
      if (args.length !== 4) return null;
      if (!num(args[0], 1) || !num(args[1], 3) || !num(args[2], 5)) return null;
      if (!ang(args[3], 7)) return null;
      return record(rec, np);
    }
    if (kind === TK_MATRIX_3D) {
      if (args.length !== 16) return null;
      // All sixteen go in: a matrix that isn't flat yet can still compose with other 3D
      // functions into one that is, and the list's matrix is what gets projected.
      const m = [kind, np];
      for (const a of args) {
        const n = parseNumber(a);
        if (n === null) return null;
        m.push(n, P.U_NONE);
      }
      return m;
    }
    // skew(x[, y])
    if (args.length < 1 || args.length > 2) return null;
    if (!ang(args[0], 1)) return null;
    if (args.length > 1) { if (!ang(args[1], 3)) return null; }
    return record(rec, np);
  }
  return null;
}

/** A transform list row, or null when the value isn't one this build understands. */
export function parseTransformList(value: string): number[] | null {
  const tokens = fnTokens(value.trim());
  if (tokens === null || tokens.length === 0) return null;
  const row: number[] = [tokens.length];
  for (const t of tokens) {
    const rec = fnRecord(t);
    if (rec === null) return null;
    for (const n of rec) row.push(n);
  }
  return row;
}

/** One transform-origin token: which axis it sets, and the length it is (if any). */
interface OriginToken { axis: number; v: number; u: number } // axis 0 both, 1 x, 2 y, 3 z

function originToken(s: string): OriginToken | null {
  switch (s) {
    case "left": return { axis: 1, v: 0, u: P.U_PCT };
    case "right": return { axis: 1, v: 100, u: P.U_PCT };
    case "top": return { axis: 2, v: 0, u: P.U_PCT };
    case "bottom": return { axis: 2, v: 100, u: P.U_PCT };
    case "center": return { axis: 0, v: 50, u: P.U_PCT };
  }
  const l = parseLength(s, false);
  return l === null ? null : { axis: 0, v: l.v, u: l.u };
}

/**
 * A transform-origin row: x and y as value/unit pairs (percentages of the border box), then a
 * z value/unit pair that 2D painting ignores. A missing component is the centre.
 */
export function parseTransformOrigin(value: string): number[] | null {
  const parts = splitValue(value.trim().toLowerCase());
  if (parts.length < 1 || parts.length > 3) return null;
  const toks: OriginToken[] = [];
  for (const p of parts) {
    const t = originToken(p);
    if (t === null) return null;
    toks.push(t);
  }
  const half = 50;
  let x: OriginToken = { axis: 1, v: half, u: P.U_PCT };
  let y: OriginToken = { axis: 2, v: half, u: P.U_PCT };
  let z: OriginToken = { axis: 3, v: 0, u: P.U_PX };
  const t0 = toks[0];
  // One value names the horizontal position, unless it is a vertical keyword.
  if (t0.axis === 2) y = t0;
  else x = t0;
  if (toks.length >= 2) {
    const t1 = toks[1];
    if (t0.axis === 2) {
      // `top 10px`: the first is the vertical one, so the second is horizontal.
      if (t1.axis === 2) return null;
      x = t1;
    } else if (t1.axis === 1) {
      // `center left`: the first centred both axes, so the second can still name x.
      if (t0.axis !== 0) return null;
      y = t0;
      x = t1;
    } else {
      if (t1.axis !== 0 && t1.axis !== 2) return null;
      y = t1;
    }
  }
  if (toks.length === 3) {
    if (toks[2].axis === 1 || toks[2].axis === 2) return null;
    z = toks[2];
  }
  return [x.v, x.u, y.v, y.u, z.v, z.u];
}

/** A 2D affine matrix as CSS writes it: x' = a·x + c·y + e, y' = b·x + d·y + f. */
export interface Matrix { a: number; b: number; c: number; d: number; e: number; f: number }

/** `first` applied, then `second`. */
export function mul(first: Matrix, second: Matrix): Matrix {
  return {
    a: first.a * second.a + first.b * second.c,
    b: first.a * second.b + first.b * second.d,
    c: first.c * second.a + first.d * second.c,
    d: first.c * second.b + first.d * second.d,
    e: first.e * second.a + first.f * second.c + second.e,
    f: first.e * second.b + first.f * second.d + second.f,
  };
}

export function identityMatrix(): Matrix {
  return { a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 };
}

/** The inverse of a matrix, or null when it has no area. */
export function inverseMatrix(m: Matrix): Matrix | null {
  const det = m.a * m.d - m.b * m.c;
  if (det === 0 || !Number.isFinite(det)) return null;
  const a = m.d / det, b = -m.b / det, c = -m.c / det, d = m.a / det;
  return { a, b, c, d, e: -(m.e * a + m.f * c), f: -(m.e * b + m.f * d) };
}

/** What resolving a row needs to know about the element and the viewport. */
export interface TransformContext {
  /** The border box the percentages resolve against. */
  w: number;
  h: number;
  /** The element's font size, for em lengths, and its used line height, for lh lengths. */
  fontSize: number;
  lh: number;
  /** The root's font size, for rem lengths. */
  rem: number;
  /** The font's x-height and the width of "0", for ex and ch lengths. */
  ex: number;
  ch: number;
  viewportW: number;
  viewportH: number;
  /** The element's nearest query container's content box, for cq units (the viewport if none). */
  cqw: number;
  cqh: number;
}

function lengthPx(v: number, u: number, ctx: TransformContext, vertical: boolean): number {
  if (u === P.U_EXPR) return evalExpr(v, vertical ? ctx.h : ctx.w, ctx.viewportW, ctx.viewportH, ctx.fontSize, ctx.cqw, ctx.cqh);
  if (u === P.U_CQW || u === P.U_CQI) return (v / 100) * ctx.cqw;
  if (u === P.U_CQH || u === P.U_CQB) return (v / 100) * ctx.cqh;
  if (u === P.U_CQMIN) return (v / 100) * Math.min(ctx.cqw, ctx.cqh);
  if (u === P.U_CQMAX) return (v / 100) * Math.max(ctx.cqw, ctx.cqh);
  if (u === P.U_PCT) return (v / 100) * (vertical ? ctx.h : ctx.w);
  if (u === P.U_EM) return v * ctx.fontSize;
  if (u === P.U_REM) return v * ctx.rem;
  if (u === P.U_LH) return v * ctx.lh;
  if (u === P.U_EX) return v * ctx.ex;
  if (u === P.U_CH) return v * ctx.ch;
  if (u === P.U_VW) return (v / 100) * ctx.viewportW;
  if (u === P.U_VH) return (v / 100) * ctx.viewportH;
  return v;
}

/**
 * A cosine or sine rounded to the exact 0 or ±1 it means: cos(90deg) is 6.1e-17, and a matrix
 * that is that far off a quarter turn leaves antialiased edges where the box has whole pixels.
 */
function snapUnit(v: number): number {
  if (Math.abs(v) < 1e-12) return 0;
  if (Math.abs(v - 1) < 1e-12) return 1;
  if (Math.abs(v + 1) < 1e-12) return -1;
  return v;
}

/** A 4x4 matrix, in the order matrix3d writes it: column by column, p' = M·p. Typed, so a
 * read of a column is a plain load rather than the bounds-checked union read a `number[]` takes. */
export type Matrix4 = Float64Array;

function id4(): Matrix4 {
  return new Float64Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
}

export function identity4(): Matrix4 {
  return id4();
}

/** A move in page space, including the z that only shows once something turns the result. */
export function translation4(x: number, y: number, z: number): Matrix4 {
  const m = id4();
  m[12] = x;
  m[13] = y;
  m[14] = z;
  return m;
}

/** `first` applied, then `second`: their product, with `first` on the right. */
export function mulMatrix4(first: Matrix4, second: Matrix4): Matrix4 {
  const out = new Float64Array(16);
  for (let c = 0; c < 4; c++) {
    for (let r = 0; r < 4; r++) {
      let s = 0;
      for (let k = 0; k < 4; k++) s += second[k * 4 + r] * first[c * 4 + k];
      out[c * 4 + r] = s;
    }
  }
  return out;
}

/**
 * The matrix the `perspective` property puts over what its box holds: a distance `d` maps a
 * point at depth z to w = 1 - z/d, and the vantage point is `ox`, `oy` in the box's coordinates,
 * so the projection turns about that point (perspective-origin).
 */
export function perspectiveMatrix(dist: number, ox: number, oy: number): Matrix4 {
  const p = id4();
  p[11] = -1 / dist;
  return mulMatrix4(mulMatrix4(translation4(-ox, -oy, 0), p), translation4(ox, oy, 0));
}

/**
 * A point through a full 4x4, divided by w: [x, y] on the page. Null when w is at or past zero,
 * where the plane has been projected onto the viewer and nothing of it is drawn (a box whose
 * plane reaches the eye vanishes, as perspective-split-by-zero-w expects).
 */
export function projectPoint4(m: Matrix4, x: number, y: number, z: number): number[] | null {
  const X = m[0] * x + m[4] * y + m[8] * z + m[12];
  const Y = m[1] * x + m[5] * y + m[9] * z + m[13];
  const W = m[3] * x + m[7] * y + m[11] * z + m[15];
  if (!(W > 1e-6)) return null;
  return [X / W, Y / W];
}

/**
 * A box's four corners through a 4x4, clockwise from its top-left: [x0, y0, x1, y1, x2, y2,
 * x3, y3]. Null when any corner's w is at or past zero.
 */
export function projectQuad4(m: Matrix4, w: number, h: number): number[] | null {
  const a = projectPoint4(m, 0, 0, 0);
  const b = projectPoint4(m, w, 0, 0);
  const c = projectPoint4(m, w, h, 0);
  const d = projectPoint4(m, 0, h, 0);
  if (a === null || b === null || c === null || d === null) return null;
  return [a[0], a[1], b[0], b[1], c[0], c[1], d[0], d[1]];
}

/** A 4x4 matrix's determinant, expanded along its first row. */
function det4(m: Matrix4): number {
  const at = (r: number, c: number): number => m[c * 4 + r];
  const m3 = (r0: number, r1: number, r2: number, c0: number, c1: number, c2: number): number =>
    at(r0, c0) * (at(r1, c1) * at(r2, c2) - at(r1, c2) * at(r2, c1))
      - at(r0, c1) * (at(r1, c0) * at(r2, c2) - at(r1, c2) * at(r2, c0))
      + at(r0, c2) * (at(r1, c0) * at(r2, c1) - at(r1, c1) * at(r2, c0));
  return at(0, 0) * m3(1, 2, 3, 1, 2, 3) - at(0, 1) * m3(1, 2, 3, 0, 2, 3)
    + at(0, 2) * m3(1, 2, 3, 0, 1, 3) - at(0, 3) * m3(1, 2, 3, 0, 1, 2);
}

/**
 * The 2D matrix the page paints with. Only the element's own plane is drawn, so only the
 * columns that map x and y matter: whatever the matrix does to z is dropped there.
 */
export function projectMatrix4(m: Matrix4): Matrix {
  // A matrix with no volume has flattened its space onto a plane, and CSS doesn't render an
  // element whose transform can't be inverted: scale3d(2,2,0) covers nothing.
  if (Math.abs(det4(m)) < 1e-12) return { a: 0, b: 0, c: 0, d: 0, e: 0, f: 0 };
  // w is what the result is divided by. Over the element's plane it is constant unless the
  // matrix's w row leans on x or y, and a constant divide is just a scale, which an affine
  // matrix can hold: matrix3d(…, 0,0,0,2) paints everything at half size. A divide that does
  // vary across the plane is a perspective, which no display list can draw; it is dropped.
  const w = m[15];
  if (Math.abs(m[3]) < 1e-12 && Math.abs(m[7]) < 1e-12 && Math.abs(w) > 1e-12) {
    return { a: m[0] / w, b: m[1] / w, c: m[4] / w, d: m[5] / w, e: m[12] / w, f: m[13] / w };
  }
  return { a: m[0], b: m[1], c: m[4], d: m[5], e: m[12], f: m[13] };
}

/**
 * A right-handed rotation about an axis, as matrix3d stores it. A rotate3d about a zero axis
 * turns nothing, so it is the identity.
 */
function rot4(angle: number, ax: number, ay: number, az: number): Matrix4 {
  const len = Math.sqrt(ax * ax + ay * ay + az * az);
  const m = id4();
  if (len === 0) return m;
  const x = ax / len, y = ay / len, z = az / len;
  const c = snapUnit(Math.cos(angle)), s = snapUnit(Math.sin(angle)), t = 1 - c;
  m[0] = c + x * x * t;
  m[1] = x * y * t + z * s;
  m[2] = x * z * t - y * s;
  m[4] = x * y * t - z * s;
  m[5] = c + y * y * t;
  m[6] = y * z * t + x * s;
  m[8] = x * z * t + y * s;
  m[9] = y * z * t - x * s;
  m[10] = c + z * z * t;
  return m;
}

/**
 * One transform function's matrix. The z axis is real here: a `translatez` or `scalez` moves the
 * element in depth, which only shows once another function tumbles the result flat.
 */
function fnMatrix4(f: Fn, ctx: TransformContext): Matrix4 {
  const v = (i: number): number => f.v[i * 2];
  const u = (i: number): number => f.v[i * 2 + 1];
  const m = id4();
  switch (f.kind) {
    case TK_MATRIX:
      m[0] = v(0); m[1] = v(1); m[4] = v(2); m[5] = v(3); m[12] = v(4); m[13] = v(5);
      return m;
    case TK_MATRIX_3D:
      for (let k = 0; k < 16; k++) m[k] = v(k);
      return m;
    case TK_PERSPECTIVE: {
      // perspective(d) puts -1/d in the w row's z: w' = 1 - z/d. A distance under 1px draws as
      // 1px (the computed value stays what it was).
      const d = lengthPx(v(0), u(0), ctx, false);
      m[11] = -1 / (d < 1 ? 1 : d);
      return m;
    }
    case TK_TRANSLATE:
      m[12] = lengthPx(v(0), u(0), ctx, false);
      m[13] = lengthPx(v(1), u(1), ctx, true);
      return m;
    case TK_TRANSLATE_X:
      m[12] = lengthPx(v(0), u(0), ctx, false);
      return m;
    case TK_TRANSLATE_Y:
      m[13] = lengthPx(v(0), u(0), ctx, true);
      return m;
    case TK_TRANSLATE_3D:
      m[12] = lengthPx(v(0), u(0), ctx, false);
      m[13] = lengthPx(v(1), u(1), ctx, true);
      m[14] = lengthPx(v(2), u(2), ctx, false);
      return m;
    case TK_TRANSLATE_Z:
      m[14] = lengthPx(v(0), u(0), ctx, false);
      return m;
    case TK_SCALE:
      m[0] = v(0); m[5] = v(1);
      return m;
    case TK_SCALE_X:
      m[0] = v(0);
      return m;
    case TK_SCALE_Y:
      m[5] = v(0);
      return m;
    case TK_SCALE_3D:
      m[0] = v(0); m[5] = v(1); m[10] = v(2);
      return m;
    case TK_SCALE_Z:
      m[10] = v(0);
      return m;
    case TK_ROTATE:
    case TK_ROTATE_Z:
      return rot4(v(0), 0, 0, 1);
    case TK_ROTATE_X:
      return rot4(v(0), 1, 0, 0);
    case TK_ROTATE_Y:
      return rot4(v(0), 0, 1, 0);
    case TK_ROTATE_3D:
      return rot4(v(3), v(0), v(1), v(2));
    case TK_SKEW:
      m[1] = Math.tan(v(1));
      m[4] = Math.tan(v(0));
      return m;
    case TK_SKEW_X:
      m[4] = Math.tan(v(0));
      return m;
    case TK_SKEW_Y:
      m[1] = Math.tan(v(0));
      return m;
  }
  return m;
}

/** One function of a list row: its kind and its value/unit pairs. */
interface Fn { kind: number; v: readonly number[] }

/** The functions a list row holds, or null when the row is cut short. */
function rowFns(row: readonly number[]): Fn[] | null {
  const n = row[0] | 0;
  const out: Fn[] = [];
  let at = 1;
  for (let i = 0; i < n; i++) {
    if (at + 2 > row.length) return null;
    const np = row[at + 1] | 0;
    if (np < 0 || at + 2 + np * 2 > row.length) return null;
    out.push({ kind: row[at], v: row.slice(at + 2, at + 2 + np * 2) });
    at += 2 + np * 2;
  }
  return out;
}

/** Whether a list row holds at least one function: what makes listMatrix4 answer a matrix rather
 *  than null, worked out without resolving a length or building one. */
export function listHasFunctions(row: readonly number[]): boolean {
  const n = row[0] | 0;
  if (n <= 0) return false;
  let at = 1;
  for (let i = 0; i < n; i++) {
    if (at + 2 > row.length) return false;
    const np = row[at + 1] | 0;
    if (np < 0 || at + 2 + np * 2 > row.length) return false;
    at += 2 + np * 2;
  }
  return true;
}

/**
 * The matrix a transform list row stands for before it is projected, or null for no transform.
 * The functions apply one after another from left to right, so the leftmost one is the
 * outermost: the rightmost one shapes the element first, as the CSS Transforms spec says.
 */
export function listMatrix4(row: readonly number[], ctx: TransformContext): Matrix4 | null {
  const fns = rowFns(row);
  if (fns === null || fns.length === 0) return null;
  let m = id4();
  for (let i = fns.length - 1; i >= 0; i--) m = mulMatrix4(m, fnMatrix4(fns[i], ctx));
  return m;
}

/** The flat matrix a transform list row stands for, or null for no transform. */
export function listMatrix(row: readonly number[], ctx: TransformContext): Matrix | null {
  const m = listMatrix4(row, ctx);
  return m === null ? null : projectMatrix4(m);
}

/** The transform-origin row's point, in the border box's coordinates. */
export function originPoint(row: readonly number[], ctx: TransformContext): number[] {
  const x = row.length >= 2 ? lengthPx(row[0], row[1], ctx, false) : ctx.w / 2;
  const y = row.length >= 4 ? lengthPx(row[2], row[3], ctx, true) : ctx.h / 2;
  return [x, y];
}

/**
 * The transform-origin row's depth. It changes nothing until a rotation or a perspective puts
 * the element's plane somewhere other than z = 0, but then it decides where the plane sits.
 */
export function originDepth(row: readonly number[], ctx: TransformContext): number {
  return row.length >= 6 ? lengthPx(row[4], row[5], ctx, false) : 0;
}

/** A number without trailing zeros, for serializing a value. */
function numText(n: number): string {
  return String(Math.round(n * 10000) / 10000);
}

/** A length as CSS writes it, with the unit it was written in. */
export function lengthText(v: number, u: number): string {
  const n = numText(v);
  switch (u) {
    case P.U_PCT: return n + "%";
    case P.U_EM: return n + "em";
    case P.U_REM: return n + "rem";
    case P.U_LH: return n + "lh";
    case P.U_EX: return n + "ex";
    case P.U_CH: return n + "ch";
    case P.U_VW: return n + "vw";
    case P.U_VH: return n + "vh";
    case P.U_CQW: return n + "cqw";
    case P.U_CQH: return n + "cqh";
    case P.U_CQI: return n + "cqi";
    case P.U_CQB: return n + "cqb";
    case P.U_CQMIN: return n + "cqmin";
    case P.U_CQMAX: return n + "cqmax";
    case P.U_NONE: return n;
  }
  return n + "px";
}

/**
 * A length as Chrome's computed style writes it: percentages stay as they are, and the other
 * relative lengths resolve against the element, so `calc(0.25rem * 4)` reads back as 16px.
 */
function computedLengthText(v: number, u: number, ctx: TransformContext, vertical: boolean): string {
  if (u === P.U_PCT) return numText(v) + "%";
  if (u === P.U_NONE) return numText(v);
  // A calc() mixing a percentage and a length keeps its expression, as Chrome serializes it.
  if (u === P.U_EXPR) return exprText(v);
  return numText(lengthPx(v, u, ctx, vertical)) + "px";
}

function angleText(rad: number): string {
  return numText((rad * 180) / Math.PI) + "deg";
}

/**
 * One transform list as CSS function text. With a context it is the computed form, with the
 * element's relative lengths resolved; without one it is the list as the declaration wrote it.
 */
export function listCss(row: readonly number[], ctx?: TransformContext): string {
  const fns = rowFns(row);
  if (fns === null) return "none";
  const out: string[] = [];
  const len = (v: number, u: number, vertical = false): string =>
    ctx === undefined ? lengthText(v, u) : computedLengthText(v, u, ctx, vertical);
  for (const f of fns) {
    const val = (i: number): number => f.v[i * 2];
    const unit = (i: number): number => f.v[i * 2 + 1];
    const kind = f.kind;
    if (kind === TK_MATRIX) {
      const args: string[] = [];
      for (let k = 0; k < 6; k++) args.push(numText(val(k)));
      out.push(`matrix(${args.join(", ")})`);
    } else if (kind === TK_MATRIX_3D) {
      const args: string[] = [];
      for (let k = 0; k < 16; k++) args.push(numText(val(k)));
      out.push(`matrix3d(${args.join(", ")})`);
    } else if (kind === TK_TRANSLATE) out.push(`translate(${len(val(0), unit(0))}, ${len(val(1), unit(1), true)})`);
    else if (kind === TK_TRANSLATE_X) out.push(`translateX(${len(val(0), unit(0))})`);
    else if (kind === TK_TRANSLATE_Y) out.push(`translateY(${len(val(0), unit(0), true)})`);
    else if (kind === TK_TRANSLATE_3D) out.push(`translate3d(${len(val(0), unit(0))}, ${len(val(1), unit(1), true)}, ${len(val(2), unit(2))})`);
    else if (kind === TK_TRANSLATE_Z) out.push(`translateZ(${len(val(0), unit(0))})`);
    else if (kind === TK_SCALE) out.push(`scale(${numText(val(0))}, ${numText(val(1))})`);
    else if (kind === TK_SCALE_X) out.push(`scaleX(${numText(val(0))})`);
    else if (kind === TK_SCALE_Y) out.push(`scaleY(${numText(val(0))})`);
    else if (kind === TK_SCALE_3D) out.push(`scale3d(${numText(val(0))}, ${numText(val(1))}, ${numText(val(2))})`);
    else if (kind === TK_SCALE_Z) out.push(`scaleZ(${numText(val(0))})`);
    else if (kind === TK_ROTATE || kind === TK_ROTATE_Z) out.push(`rotate(${angleText(val(0))})`);
    else if (kind === TK_ROTATE_X) out.push(`rotateX(${angleText(val(0))})`);
    else if (kind === TK_ROTATE_Y) out.push(`rotateY(${angleText(val(0))})`);
    else if (kind === TK_ROTATE_3D) out.push(`rotate3d(${numText(val(0))}, ${numText(val(1))}, ${numText(val(2))}, ${angleText(val(3))})`);
    else if (kind === TK_SKEW) out.push(`skew(${angleText(val(0))}, ${angleText(val(1))})`);
    else if (kind === TK_SKEW_X) out.push(`skewX(${angleText(val(0))})`);
    else if (kind === TK_SKEW_Y) out.push(`skewY(${angleText(val(0))})`);
    else if (kind === TK_PERSPECTIVE) out.push(`perspective(${len(val(0), unit(0))})`);
    else out.push(`transform(${numText(kind)})`);
  }
  return out.join(" ");
}

/** A serialized matrix, as getComputedStyle reports a transform. */
export function matrixText(m: Matrix): string {
  const r = (n: number): string => {
    const v = Math.round(n * 1000000) / 1000000;
    return String(v === 0 ? 0 : v);
  };
  return `matrix(${r(m.a)}, ${r(m.b)}, ${r(m.c)}, ${r(m.d)}, ${r(m.e)}, ${r(m.f)})`;
}
