// `clip: rect(...)` and `clip-path`: the regions a box paints inside.
//
// `clip-path` holds a row id in the clip-path table (see shared/css/clip-path.ts); the shape's
// lengths, percentages and position resolve against the box the shape names, and the result is
// pushed onto the display list as a clip the box's painting runs inside.

import * as P from "../shared/props.ts";
import { clipRows } from "../shared/css/clip.ts";
import {
  clipPathRows, SH_INSET, SH_CIRCLE, SH_ELLIPSE, SH_POLYGON, SH_PATH, SH_REF, REF_PADDING_BOX,
  REF_CONTENT_BOX, REF_MARGIN_BOX, REF_FILL_BOX, pathText,
} from "../shared/css/clip-path.ts";
import { localName, mul, parseTransform, shapePath, transformOps } from "../shared/svg.ts";
import { paintUrlAt } from "./svg-paint.ts";
import { positionRows } from "../shared/css/position.ts";
import { evalExpr } from "../shared/css/length-exprs.ts";
import { document, Element } from "./dom.ts";
import type { Node } from "./dom.ts";
import { viewport } from "./layout/box-model.ts";
import { rootFontSize } from "./root-size.ts";
import { hostClipPush, hostClipPushRound, hostClipPushEllipse, hostClipPushShape } from "./host.ts";

/**
 * The four clip sides in px: top, right, bottom and left, each measured from its border box
 * edge, or null when that side is `auto` and stays at the edge. Null when there is no clip.
 * A side may be negative: CSS Masking allows that, and a rect whose edges cross clips everything.
 */
export function clipSides(el: Node): (number | null)[] | null {
  if (el.su[P.P_CLIP] !== P.U_LIST) return null;
  const row = clipRows.row(el.sv[P.P_CLIP]);
  if (row === null) return null;
  const sides: (number | null)[] = [];
  for (let k = 0; k + 1 < row.length; k += 2) sides.push(row[k + 1] === P.U_AUTO ? null : row[k]);
  return sides;
}

/**
 * The region a positioned box's `clip: rect()` leaves, for a border box at (x, y) of size w by h,
 * as [left, top, width, height]; null when the box has no clip. A rect whose edges cross leaves
 * nothing to paint, which is a zero-size region, not no region.
 */
export function clipRect(el: Node, x: number, y: number, w: number, h: number): number[] | null {
  const pos = el.sv[P.P_POSITION];
  if (pos !== P.POS_ABSOLUTE && pos !== P.POS_FIXED) return null;
  const s = clipSides(el);
  if (s === null) return null;
  const left = s[3] === null ? x : x + s[3];
  const top = s[0] === null ? y : y + s[0];
  const right = s[1] === null ? x + w : x + s[1];
  const bottom = s[2] === null ? y + h : y + s[2];
  return [left, top, Math.max(0, right - left), Math.max(0, bottom - top)];
}

/**
 * Pushes the region a positioned box's `clip: rect()` leaves for its border box at (x, y) of size
 * w by h. Returns whether it pushed one: only an absolutely positioned box with a `clip` has one.
 */
export function pushClipRect(el: Node, x: number, y: number, w: number, h: number): boolean {
  const r = clipRect(el, x, y, w, h);
  if (r === null) return false;
  hostClipPush(el.serial, P.PK_CLIP_RECT, r[0], r[1], r[2], r[3], 0);
  return true;
}

/** Whether the element clips its painting to a `clip-path` shape. */
export function hasClipPath(el: Node): boolean {
  return el.sv[P.P_CLIP_PATH] >= 0;
}

/** A shape length in px: a percentage against `ref`, or a length against the element's font. */
function len(v: number, u: number, el: Node, ref: number): number {
  switch (u) {
    case P.U_PCT: return (v / 100) * ref;
    case P.U_EM: return v * el.sv[P.P_FONT_SIZE];
    case P.U_REM: return v * rootFontSize();
    case P.U_VW: return (v / 100) * viewport.w;
    case P.U_VH: return (v / 100) * viewport.h;
    case P.U_EXPR: return evalExpr(v, ref, viewport.w, viewport.h, el.sv[P.P_FONT_SIZE], viewport.w, viewport.h, rootFontSize(), el.sv[P.P_LINE_HEIGHT]);
    default: return v;
  }
}

/** A circle's or ellipse's radius, whose keywords measure in from the box's sides. */
function radiusPx(v: number, u: number, el: Node, ref: number, at: number, side: number): number {
  if (u === P.U_CLOSEST_SIDE) return Math.max(0, Math.min(at, side - at));
  if (u === P.U_FARTHEST_SIDE) return Math.max(at, side - at);
  return Math.max(0, len(v, u, el, ref));
}

// ---------------------------------------------------------------------------
// Path flattening

/** How far a flattened curve may stray from the real one, in CSS px. */
const FLAT_TOL = 0.05;

function flatQuad(out: number[], x0: number, y0: number, qx: number, qy: number, x1: number, y1: number, depth: number): void {
  // The quadratic's deviation from its chord: the control point's distance to the midpoint.
  const mx = (x0 + x1) / 2, my = (y0 + y1) / 2;
  const dx = qx - mx, dy = qy - my;
  if (depth > 12 || dx * dx + dy * dy <= FLAT_TOL * FLAT_TOL * 4) {
    out.push(x1, y1);
    return;
  }
  const ax = (x0 + qx) / 2, ay = (y0 + qy) / 2;
  const bx = (qx + x1) / 2, by = (qy + y1) / 2;
  const cx = (ax + bx) / 2, cy = (ay + by) / 2;
  flatQuad(out, x0, y0, ax, ay, cx, cy, depth + 1);
  flatQuad(out, cx, cy, bx, by, x1, y1, depth + 1);
}

function flatCubic(out: number[], x0: number, y0: number, x1: number, y1: number, x2: number, y2: number, x3: number, y3: number, depth: number): void {
  // Both control points near the chord is flat enough.
  const d1 = Math.abs((x1 - x0) * (y3 - y0) - (x3 - x0) * (y1 - y0));
  const d2 = Math.abs((x2 - x0) * (y3 - y0) - (x3 - x0) * (y2 - y0));
  const chord = Math.hypot(x3 - x0, y3 - y0);
  const tol = FLAT_TOL * (chord > 0 ? chord : 1);
  if (depth > 12 || (d1 <= tol && d2 <= tol)) {
    out.push(x3, y3);
    return;
  }
  const abx = (x0 + x1) / 2, aby = (y0 + y1) / 2;
  const bcx = (x1 + x2) / 2, bcy = (y1 + y2) / 2;
  const cdx = (x2 + x3) / 2, cdy = (y2 + y3) / 2;
  const abcX = (abx + bcx) / 2, abcY = (aby + bcy) / 2;
  const bcdX = (bcx + cdx) / 2, bcdY = (bcy + cdy) / 2;
  const midX = (abcX + bcdX) / 2, midY = (abcY + bcdY) / 2;
  flatCubic(out, x0, y0, abx, aby, abcX, abcY, midX, midY, depth + 1);
  flatCubic(out, midX, midY, bcdX, bcdY, cdx, cdy, x3, y3, depth + 1);
}

/** A path's operations as closed polygons, each a flat run of x,y vertices. */
function flattenPath(ops: readonly number[], ox: number, oy: number): number[][] {
  const polys: number[][] = [];
  let cur: number[] = [];
  let cx = 0, cy = 0, sx = 0, sy = 0;
  const flush = (): void => {
    if (cur.length >= 4) polys.push(cur);
    cur = [];
  };
  for (let i = 0; i < ops.length;) {
    const kind = ops[i];
    if (kind === 1) {
      flush();
      cx = ox + ops[i + 1];
      cy = oy + ops[i + 2];
      sx = cx;
      sy = cy;
      cur.push(cx, cy);
      i += 3;
    } else if (kind === 2) {
      cx = ox + ops[i + 1];
      cy = oy + ops[i + 2];
      cur.push(cx, cy);
      i += 3;
    } else if (kind === 3) {
      const qx = ox + ops[i + 1], qy = oy + ops[i + 2];
      const x1 = ox + ops[i + 3], y1 = oy + ops[i + 4];
      flatQuad(cur, cx, cy, qx, qy, x1, y1, 0);
      cx = x1;
      cy = y1;
      i += 5;
    } else if (kind === 4) {
      const x1 = ox + ops[i + 1], y1 = oy + ops[i + 2];
      const x2 = ox + ops[i + 3], y2 = oy + ops[i + 4];
      const x3 = ox + ops[i + 5], y3 = oy + ops[i + 6];
      flatCubic(cur, cx, cy, x1, y1, x2, y2, x3, y3, 0);
      cx = x3;
      cy = y3;
      i += 7;
    } else {
      // A close joins the subpath back to its start; the clip closes every subpath anyway.
      flush();
      cx = sx;
      cy = sy;
      i += 1;
    }
  }
  flush();
  return polys;
}

/** The host's point list: each polygon as "x,y x,y …", subpaths separated by ";". */
function shapeText(polys: number[][]): string {
  const parts: string[] = [];
  for (const p of polys) {
    const v: string[] = [];
    for (let i = 0; i + 1 < p.length; i += 2) v.push(`${p[i]},${p[i + 1]}`);
    if (v.length > 0) parts.push(v.join(" "));
  }
  return parts.join(";");
}

// ---------------------------------------------------------------------------
// clip-path

/**
 * Pushes the element's `clip-path` shape as a clip. `border`, `padding` and `content` are the
 * three reference boxes in paint coordinates, each [x, y, w, h]. Returns false when the element
 * has no shape, so the caller has nothing to pop.
 */
export function pushClipPath(el: Node, border: number[], padding: number[], content: number[]): boolean {
  const id = el.sv[P.P_CLIP_PATH];
  if (el.su[P.P_CLIP_PATH] !== P.U_LIST || id < 0) return false;
  const row = clipPathRows.row(id);
  if (row === null || row.length < 3) return false;
  // A CSS layout box has no fill or stroke box: fill-box is its content box, and stroke-box and
  // view-box are its border box.
  const box = row[1] === REF_PADDING_BOX ? padding
    : row[1] === REF_CONTENT_BOX || row[1] === REF_FILL_BOX ? content
    : border;
  const bx = box[0], by = box[1], bw = box[2], bh = box[3];
  const kind = row[0];
  if (kind === SH_INSET) {
    const top = len(row[3], row[4], el, bh);
    const right = len(row[5], row[6], el, bw);
    const bottom = len(row[7], row[8], el, bh);
    const left = len(row[9], row[10], el, bw);
    const x = bx + left, y = by + top;
    const w = Math.max(0, bw - left - right), h = Math.max(0, bh - top - bottom);
    // The eight corner radii follow the sides: for each corner a horizontal radius and a vertical
    // one, in CSS's order — top-left, top-right, bottom-right, bottom-left.
    const radii = [0, 0, 0, 0, 0, 0, 0, 0];
    let rounded = false;
    if (row.length >= 27) {
      for (let c = 0; c < 4; c++) {
        radii[c * 2] = Math.max(0, len(row[11 + c * 4], row[12 + c * 4], el, w));
        radii[c * 2 + 1] = Math.max(0, len(row[13 + c * 4], row[14 + c * 4], el, h));
        if (radii[c * 2] > 0 || radii[c * 2 + 1] > 0) rounded = true;
      }
    }
    if (rounded) {
      hostClipPushRound(el.serial, P.PK_CLIP_RECT, x, y, w, h, radii[0], radii[1], radii[2], radii[3], radii[4], radii[5], radii[6], radii[7]);
    } else {
      hostClipPush(el.serial, P.PK_CLIP_RECT, x, y, w, h, 0);
    }
    return true;
  }
  if (kind === SH_CIRCLE || kind === SH_ELLIPSE) {
    const pos = kind === SH_CIRCLE ? row[5] : row[7];
    const prow = positionRows.row(pos);
    let px = 0.5, py = 0.5;
    if (prow !== null && prow.length >= 6) {
      const xv = len(prow[0], prow[1], el, bw);
      const yv = len(prow[3], prow[4], el, bh);
      px = prow[2] === 1 ? bw - xv : xv;
      py = prow[5] === 1 ? bh - yv : yv;
    } else {
      px = bw / 2;
      py = bh / 2;
    }
    const cx = bx + px, cy = by + py;
    let rx: number, ry: number;
    if (kind === SH_CIRCLE) {
      const ru = row[4];
      if (ru === P.U_CLOSEST_SIDE) {
        rx = ry = Math.max(0, Math.min(px, bw - px, py, bh - py));
      } else if (ru === P.U_FARTHEST_SIDE) {
        rx = ry = Math.max(px, bw - px, py, bh - py);
      } else {
        rx = ry = Math.max(0, len(row[3], ru, el, Math.sqrt((bw * bw + bh * bh) / 2)));
      }
    } else {
      rx = radiusPx(row[3], row[4], el, bw, px, bw);
      ry = radiusPx(row[5], row[6], el, bh, py, bh);
    }
    hostClipPushEllipse(el.serial, P.PK_CLIP_ELLIPSE, cx, cy, rx, ry);
    return true;
  }
  const evenOdd = row[2] === P.FR_EVENODD;
  if (kind === SH_POLYGON) {
    const poly: number[] = [];
    for (let k = 3; k + 3 < row.length; k += 4) {
      poly.push(bx + len(row[k], row[k + 1], el, bw));
      poly.push(by + len(row[k + 2], row[k + 3], el, bh));
    }
    hostClipPushShape(el.serial, P.PK_CLIP_SHAPE, shapeText([poly]), evenOdd ? 1 : 0);
    return true;
  }
  if (kind === SH_PATH) {
    const ops: number[] = [];
    for (let k = 3; k < row.length; k++) ops.push(row[k]);
    hostClipPushShape(el.serial, P.PK_CLIP_SHAPE, shapeText(flattenPath(ops, bx, by)), evenOdd ? 1 : 0);
    return true;
  }
  if (kind === SH_REF) {
    // `url(#id)`: the clip path element it names draws the shapes, in its own user space or in
    // the reference box's unit square, which is the element's box mapped to 0..1 on each axis.
    const ref = row.length > 3 ? paintUrlAt(row[3]) : null;
    const target = ref === null ? null : document.getElementById(ref);
    if (target === null || localName(target.localName) !== "clippath") return false;
    const units = (target.getAttribute("clipPathUnits") ?? target.getAttribute("clippathunits") ?? "")
      .trim().toLowerCase();
    const unitSquare = units === "objectboundingbox";
    const m = unitSquare ? [bw, 0, 0, bh, bx, by] : [1, 0, 0, 1, bx, by];
    const ops = clipRefOps(target, unitSquare ? 1 : bw, unitSquare ? 1 : bh, m);
    if (ops.length === 0) return false;
    const rule = (target.getAttribute("clip-rule") ?? "").trim().toLowerCase() === "evenodd";
    hostClipPushShape(el.serial, P.PK_CLIP_SHAPE, pathText(ops), rule || evenOdd ? 1 : 0);
    return true;
  }
  return false;
}

/** The `d` operations a `<clipPath>` draws, its subtree's shapes mapped by `base`. */
function clipRefOps(target: Element, vw: number, vh: number, base: number[]): number[] {
  const ops: number[] = [];
  const walk = (node: Node, m: number[]): void => {
    if (!node.isElementNode) return;
    const el = node as Element;
    if (el.sv[P.P_DISPLAY] === P.D_NONE) return;
    const name = localName(el.localName);
    const t = el.getAttribute("transform");
    const m2 = t !== null && t.trim() !== "" ? mul(m, parseTransform(t)) : m;
    if (name === "g" || name === "a") {
      for (const kid of el.kids) walk(kid, m2);
      return;
    }
    const shape = shapePath(name, (attr) => el.getAttribute(attr), vw, vh);
    if (shape.length > 0) for (const n of transformOps(shape, m2)) ops.push(n);
  };
  for (const kid of target.kids) walk(kid, base);
  return ops;
}

// ---------------------------------------------------------------------------
// shape-outside

/** The reference boxes a float's shape can be taken against, in BFC coordinates. */
export interface ShapeBoxes {
  margin: number[];
  border: number[];
  padding: number[];
  content: number[];
}

/**
 * A float's `shape-outside` as a polygon in the formatting context's coordinates: the points of
 * its basic shape, resolved against the reference box it names and grown by `shape-margin`, or
 * null when the float has no shape. A polygon is what the line fitting wants: it can ask for the
 * shape's extent across the rows of a line box.
 */
export function floatShapePolygon(el: Element, boxes: ShapeBoxes): number[] | null {
  const id = el.sv[P.P_SHAPE_OUTSIDE];
  if (el.su[P.P_SHAPE_OUTSIDE] !== P.U_LIST || id < 0) return null;
  const row = clipPathRows.row(id);
  if (row === null || row.length < 3) return null;
  const box = row[1] === REF_PADDING_BOX ? boxes.padding : row[1] === REF_CONTENT_BOX ? boxes.content
    : row[1] === REF_MARGIN_BOX ? boxes.margin : boxes.border;
  const bx = box[0], by = box[1], bw = box[2], bh = box[3];
  const kind = row[0];
  // shape-margin grows the shape outward, away from the float; an inset's sides move out by it
  // exactly, the other shapes' outlines away from their centre.
  const margin = el.su[P.P_SHAPE_MARGIN] === P.U_PX ? el.sv[P.P_SHAPE_MARGIN]
    : el.sv[P.P_SHAPE_MARGIN] * bw / 100;
  const grow = margin > 0 ? margin : 0;
  const pts: number[] = [];
  if (kind === SH_INSET) {
    const top = len(row[3], row[4], el, bh);
    const right = len(row[5], row[6], el, bw);
    const bottom = len(row[7], row[8], el, bh);
    const left = len(row[9], row[10], el, bw);
    const x0 = bx + left - grow, y0 = by + top - grow;
    const x1 = bx + bw - right + grow, y1 = by + bh - bottom + grow;
    // The corner radii are left square: the extent of each row of the shape is what the lines
    // read, and a rounded inset's corners only cut it at the very ends.
    pts.push(x0, y0, x1, y0, x1, y1, x0, y1);
  } else if (kind === SH_CIRCLE || kind === SH_ELLIPSE) {
    const pos = kind === SH_CIRCLE ? row[5] : row[7];
    const prow = positionRows.row(pos);
    let px = bw / 2, py = bh / 2;
    if (prow !== null && prow.length >= 6) {
      const xv = len(prow[0], prow[1], el, bw);
      const yv = len(prow[3], prow[4], el, bh);
      px = prow[2] === 1 ? bw - xv : xv;
      py = prow[5] === 1 ? bh - yv : yv;
    }
    let rx: number, ry: number;
    if (kind === SH_CIRCLE) {
      const ru = row[4];
      if (ru === P.U_CLOSEST_SIDE) rx = ry = Math.max(0, Math.min(px, bw - px, py, bh - py));
      else if (ru === P.U_FARTHEST_SIDE) rx = ry = Math.max(px, bw - px, py, bh - py);
      else rx = ry = Math.max(0, len(row[3], ru, el, Math.sqrt((bw * bw + bh * bh) / 2)));
    } else {
      rx = radiusPx(row[3], row[4], el, bw, px, bw);
      ry = radiusPx(row[5], row[6], el, bh, py, bh);
    }
    const cx = bx + px, cy = by + py;
    const steps = 32;
    for (let k = 0; k < steps; k++) {
      const t = (k / steps) * 2 * Math.PI;
      pts.push(cx + rx * Math.cos(t), cy + ry * Math.sin(t));
    }
  } else if (kind === SH_POLYGON) {
    for (let k = 3; k + 3 < row.length; k += 4) {
      pts.push(bx + len(row[k], row[k + 1], el, bw), by + len(row[k + 2], row[k + 3], el, bh));
    }
  } else {
    // A path() or a url() shape is more than the line fitting takes on: the float keeps its box.
    return null;
  }
  if (pts.length < 6) return null;
  return kind === SH_INSET || grow === 0 ? pts : growPolygon(pts, grow);
}

/** Grows a polygon away from its centre by `d`: exact for a circle, near enough for the rest. */
function growPolygon(pts: number[], d: number): number[] {
  const n = pts.length / 2;
  let cx = 0, cy = 0;
  for (let i = 0; i < n; i++) {
    cx += pts[2 * i];
    cy += pts[2 * i + 1];
  }
  cx /= n;
  cy /= n;
  const out: number[] = [];
  for (let i = 0; i < n; i++) {
    const dx = pts[2 * i] - cx, dy = pts[2 * i + 1] - cy;
    const l = Math.hypot(dx, dy) || 1;
    out.push(pts[2 * i] + (dx / l) * d, pts[2 * i + 1] + (dy / l) * d);
  }
  return out;
}
