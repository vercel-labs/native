// CSS transforms: the matrix an element paints with and is hit tested by.
//
// `transform` and the individual `translate`/`rotate`/`scale` properties share one matrix per
// element. The individual ones are applied first (scale, then rotate, then translate), the
// `transform` list innermost, and the whole thing turns about `transform-origin`, which is the
// centre of the border box unless the property says otherwise.

import * as P from "../shared/props.ts";
import type { Node } from "./dom.ts";
import { isReplaced, viewport } from "./layout/box-model.ts";
import { fontMetrics, textWidth } from "./layout/text.ts";
import { rootFontSize } from "./root-size.ts";
import { containerBasis } from "./style.ts";
import { positionRows } from "../shared/css/position.ts";
import {
  TK_MATRIX, inverseMatrix, listCss, listMatrix, listHasFunctions, listMatrix4, matrixText, mulMatrix4, mul, originDepth,
  originPoint, originRows, perspectiveMatrix, projectMatrix4, projectQuad4, transformRows, translation4,
} from "../shared/css/transforms.ts";
import type { Matrix, Matrix4, TransformContext } from "../shared/css/transforms.ts";

/**
 * The box a transform's percentages and its origin resolve against: transform-box's box, which
 * is the content box when it says so, and the border box for every other value on an HTML box.
 */
function referenceBox(el: Node): number[] {
  // An element with a CSS layout box has no fill or stroke box: the used value of fill-box is its
  // content box, and every other value is its border box.
  const tb = el.sv[P.P_TRANSFORM_BOX];
  if (tb === P.TB_CONTENT_BOX || tb === P.TB_FILL_BOX) {
    return [el.contentX, el.contentY, el.contentW, el.contentH];
  }
  return [0, 0, el.w, el.h];
}

/** Whether a list row (its functions' value/unit pairs) or an origin row (value/unit pairs from
 *  the start) has a length in `ex` or `ch`, the two units that need the element's font measured. */
function listUsesFontUnits(row: readonly number[] | null): boolean {
  if (row === null) return false;
  const n = row[0] | 0;
  let at = 1;
  for (let i = 0; i < n; i++) {
    if (at + 2 > row.length) return true; // a row cut short: measure, as before
    const np = row[at + 1] | 0;
    for (let k = 0; k < np; k++) {
      const u = row[at + 3 + k * 2];
      if (u === P.U_EX || u === P.U_CH) return true;
    }
    at += 2 + np * 2;
  }
  return false;
}

function pairsUseFontUnits(row: readonly number[] | null): boolean {
  if (row === null) return false;
  for (let k = 1; k < row.length; k += 2) if (row[k] === P.U_EX || row[k] === P.U_CH) return true;
  return false;
}

/**
 * The lengths a transform resolves against. `ex` and `ch` measure the element's font, which costs
 * a text shape: with `font` false they are left at 0, for a caller that has checked its rows use
 * neither unit.
 */
function contextOf(el: Node, font: boolean = true): TransformContext {
  const b = referenceBox(el);
  return {
    w: b[2], h: b[3], fontSize: el.sv[P.P_FONT_SIZE], lh: el.sv[P.P_LINE_HEIGHT],
    rem: rootFontSize(), ex: font ? fontMetrics(el)[2] : 0, ch: font ? textWidth(el, "0") : 0,
    viewportW: viewport.w, viewportH: viewport.h,
    cqw: containerBasis(el, false), cqh: containerBasis(el, true),
  };
}

/** The transform list row one property holds, or null when it holds none. */
function listRow(el: Node, p: number): readonly number[] | null {
  if (el.su[p] !== P.U_LIST) return null;
  const id = el.sv[p];
  return id < 0 ? null : transformRows.row(id);
}

/** The identity matrix, for the `none` a transform list can mix with. */
const IDENTITY: Matrix = { a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 };

/**
 * The flat matrix a transform list row stands for in this element's box — its lengths resolved
 * against the box as they paint — or the identity when the list is `none`.
 */
export function rowMatrix(el: Node, id: number): Matrix {
  const row = id < 0 ? null : transformRows.row(id);
  const m = row === null ? null : listMatrix(row, contextOf(el));
  return m === null ? IDENTITY : m;
}

/** A transform list row holding one matrix, which is what an interpolated transform becomes. */
export function matrixRow(m: Matrix): number {
  return transformRows.register([
    1, TK_MATRIX, 6,
    m.a, P.U_NONE, m.b, P.U_NONE, m.c, P.U_NONE, m.d, P.U_NONE, m.e, P.U_NONE, m.f, P.U_NONE,
  ]);
}

/** The transform-origin row the element holds, or null when it holds none. */
function originRowOf(el: Node): readonly number[] | null {
  if (el.su[P.P_TRANSFORM_ORIGIN] !== P.U_LIST) return null;
  const id = el.sv[P.P_TRANSFORM_ORIGIN];
  return id < 0 ? null : originRows.row(id);
}

/** The element's transform-origin, in its border box's coordinates. */
function originOf(el: Node, ctx: TransformContext): number[] {
  const b = referenceBox(el);
  const row = originRowOf(el);
  if (row === null) return [b[0] + ctx.w / 2, b[1] + ctx.h / 2, 0];
  const p = originPoint(row, ctx);
  return [b[0] + p[0], b[1] + p[1], originDepth(row, ctx)];
}

/**
 * The element's transform without its origin, in full: `transform` and the individual
 * properties composed. Null when it has none.
 */
function localMatrix4(el: Node): Matrix4 | null {
  const list = listRow(el, P.P_TRANSFORM);
  const scale = listRow(el, P.P_SCALE);
  const rotate = listRow(el, P.P_ROTATE);
  const move = listRow(el, P.P_TRANSLATE);
  // Most boxes have no transform: the context (the box, its fonts, the viewport) is only worked
  // out for a box that has a list to resolve against it.
  if (list === null && scale === null && rotate === null && move === null) return null;
  const ctx = contextOf(el, listUsesFontUnits(list) || listUsesFontUnits(scale) ||
    listUsesFontUnits(rotate) || listUsesFontUnits(move));
  let m: Matrix4 | null = null;
  if (list !== null) m = listMatrix4(list, ctx);
  // Each individual property lands outside the one before it: scale, then rotate, then translate.
  // `mulMatrix4(a, b)` applies `a` first, so the new one goes on the outside.
  for (const row of [scale, rotate, move]) {
    if (row === null) continue;
    const mm = listMatrix4(row, ctx);
    if (mm !== null) m = m === null ? mm : mulMatrix4(m, mm);
  }
  return m;
}

/**
 * The element's transform without its origin: `transform` and the individual properties
 * composed. Null when it has none.
 */
export function localMatrix(el: Node): Matrix | null {
  const m = localMatrix4(el);
  return m === null ? null : projectMatrix4(m);
}

/**
 * True when a transform has turned the element's plane so its back faces the viewer. The plane's
 * normal (0, 0, 1) maps to the matrix's third column, and the viewer is on the +z side. A
 * preserve-3d ancestor's transform turns the element with it, so the ancestor matrices compose
 * into the orientation the viewer sees.
 */
export function isBackFacing(el: Node): boolean {
  let m = localMatrix4(el);
  let p = el.parentElement;
  while (p !== null && p.sv[P.P_TRANSFORM_STYLE] === P.TS_PRESERVE_3D) {
    const pm = localMatrix4(p);
    if (pm !== null) m = m === null ? pm : mulMatrix4(pm, m);
    p = p.parentElement;
  }
  return m !== null && m[10] < 0;
}

/** A node's position on the page, summed from the box offsets paintBox accumulates. */
function pagePosition(el: Node): number[] {
  let x = 0, y = 0;
  let n: Node | null = el;
  while (n !== null) {
    x += n.x;
    y += n.y;
    n = n.parentElement;
  }
  return [x, y];
}

/**
 * The element's perspective-origin in its border box's coordinates: what its `perspective` turns
 * about. The value lives in the position table (like object-position), and is the box's centre
 * until the property says otherwise.
 */
function perspectiveOriginOf(el: Node): number[] {
  const b = referenceBox(el);
  if (el.su[P.P_PERSPECTIVE_ORIGIN] === P.U_LIST) {
    const row = positionRows.row(el.sv[P.P_PERSPECTIVE_ORIGIN]);
    if (row !== null && row.length >= 6) {
      // A percentage is of the box; a length is from the left/top edge, or the right/bottom one
      // when the value named that edge.
      const axis = (v: number, u: number, edge: number, size: number): number => {
        const amount = u === P.U_PCT ? (size * v) / 100 : v;
        return edge === 1 ? size - amount : amount;
      };
      return [b[0] + axis(row[0], row[1], row[2], el.w), b[1] + axis(row[3], row[4], row[5], el.h)];
    }
  }
  return [b[0] + el.w / 2, b[1] + el.h / 2];
}

/**
 * The four page-space corners a box paints with when a perspective ancestor projects it — TL, TR,
 * BR, BL — or null when the ordinary affine path draws it exactly: no perspective above it, no
 * transform of its own, a plane that stays at z = 0, or a plane that has reached the viewer.
 */
export function pageQuad(el: Node, x: number, y: number): number[] | null {
  let m = localMatrix4(el);
  if (m === null) return null;
  const o = originOf(el, contextOf(el, pairsUseFontUnits(originRowOf(el))));
  m = mulMatrix4(mulMatrix4(translation4(-o[0], -o[1], -o[2]), m), translation4(o[0], o[1], o[2]));
  let p = el.parentElement;
  let projected = false;
  const ep = pagePosition(el);
  while (p !== null) {
    if (p.sv[P.P_PERSPECTIVE] >= 0) {
      // The vantage point is the ancestor's perspective-origin, in the element's own coordinates:
      // the ancestor's page position and the element's give the offset between them.
      const po = perspectiveOriginOf(p);
      const ap = pagePosition(p);
      const dist = p.sv[P.P_PERSPECTIVE] < 1 ? 1 : p.sv[P.P_PERSPECTIVE];
      const pm = perspectiveMatrix(dist, po[0] + ap[0] - ep[0], po[1] + ap[1] - ep[1]);
      m = mulMatrix4(m, pm);
      projected = true;
      break;
    }
    // A perspective reaches this element through its parent; one further up reaches it only when
    // the boxes between are in the same 3D rendering context (preserve-3d). Otherwise the box is
    // flattened and its ancestor's perspective doesn't touch it.
    if (p.sv[P.P_TRANSFORM_STYLE] !== P.TS_PRESERVE_3D) break;
    p = p.parentElement;
  }
  if (!projected) return null;
  const q = projectQuad4(m, el.w, el.h);
  if (q === null) return null;
  // A plane that stays at z = 0 divides by w = 1: the affine path is exact and cheaper.
  if (Math.abs(q[0]) < 1e-6 && Math.abs(q[1]) < 1e-6 && Math.abs(q[2] - el.w) < 1e-6 &&
    Math.abs(q[3]) < 1e-6 && Math.abs(q[4] - el.w) < 1e-6 && Math.abs(q[5] - el.h) < 1e-6 &&
    Math.abs(q[6]) < 1e-6 && Math.abs(q[7] - el.h) < 1e-6) return null;
  return [q[0] + x, q[1] + y, q[2] + x, q[3] + y, q[4] + x, q[5] + y, q[6] + x, q[7] + y];
}

/** The element's transform about its origin, in its border box's coordinates. */export function boxMatrix(el: Node): Matrix | null {
  const m = localMatrix4(el);
  if (m === null) return null;
  const o = originOf(el, contextOf(el, pairsUseFontUnits(originRowOf(el))));
  const about = mulMatrix4(mulMatrix4(translation4(-o[0], -o[1], -o[2]), m), translation4(o[0], o[1], o[2]));
  return projectMatrix4(about);
}

/**
 * A transform doesn't apply to a non-replaced inline box, as in CSS. A replaced inline such as an
 * `<img>` is not an inline box for this purpose: it transforms like any block.
 */
export function hasTransform(el: Node): boolean {
  if (el.sv[P.P_DISPLAY] === P.D_INLINE && !isReplaced(el)) return false;
  // localMatrix answers a matrix exactly when one of the four lists holds a function: asking that
  // directly saves resolving the box's lengths and multiplying its matrices, which the paint walk
  // would otherwise do for every box it visits.
  for (const p of [P.P_TRANSFORM, P.P_SCALE, P.P_ROTATE, P.P_TRANSLATE]) {
    const row = listRow(el, p);
    if (row !== null && listHasFunctions(row)) return true;
  }
  return false;
}

function translate(x: number, y: number): Matrix {
  return { a: 1, b: 0, c: 0, d: 1, e: x, f: y };
}

/**
 * The matrix the host multiplies its user space by, which is in page coordinates: drawing keeps
 * using page coordinates, so the box's own transform has to be carried to where the box sits,
 * T(-x, -y) M T(x, y). This is the inverse of toLocalPoint.
 */
export function pageMatrix(el: Node, x: number, y: number): Matrix | null {
  const m = boxMatrix(el);
  if (m === null) return null;
  return mul(mul(translate(-x, -y), m), translate(x, y));
}

/**
 * A page point in the element's own (untransformed) coordinates, or null when the transform is
 * degenerate and covers no pixel at all.
 */
export function toLocalPoint(el: Node, px: number, py: number, x: number, y: number): number[] | null {
  const m = boxMatrix(el);
  if (m === null) return [px, py];
  const inv = inverseMatrix(m);
  if (inv === null) return null;
  const lx = px - x, ly = py - y;
  return [x + lx * inv.a + ly * inv.c + inv.e, y + lx * inv.b + ly * inv.d + inv.f];
}

/** The element's computed transform, as a matrix. */
export function transformCss(el: Node): string {
  const m = localMatrix(el);
  return m === null ? "none" : matrixText(m);
}

/** The element's computed transform-origin, resolved to pixels. */
export function originCss(el: Node): string {
  const o = originOf(el, contextOf(el));
  const r = (n: number): number => Math.round(n * 1000) / 1000;
  return `${r(o[0])}px ${r(o[1])}px`;
}

/**
 * The element's computed `translate`, `rotate` or `scale`: the list as written, with the relative
 * lengths resolved to pixels, which is how a browser reports it.
 */
export function individualCss(el: Node, p: number): string {
  if (el.su[p] !== P.U_LIST) return "none";
  const id = el.sv[p];
  const row = id < 0 ? null : transformRows.row(id);
  return row === null ? "none" : listCss(row, contextOf(el));
}
