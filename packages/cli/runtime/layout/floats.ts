// Floats: the space they leave in a block formatting context, and where the next one goes.

import * as P from "../../shared/props.ts";
import { Node } from "../dom.ts";

/** The margin box of a float, in the coordinates of the block formatting context it lives in. */
export class FloatBox {
  x = 0; // left edge
  y = 0; // top edge
  w = 0;
  h = 0;
  side = P.FL_LEFT;
  owner: Node | null = null; // the floated element, for finding floats in the same box
  /**
   * The outline `shape-outside` gives the float, as a polygon in the context's coordinates
   * (grown by `shape-margin`), or null for the plain rectangle its box makes.
   */
  shape: number[] | null = null;
  constructor(x: number, y: number, w: number, h: number, side: number) {
    this.x = x;
    this.y = y;
    this.w = w;
    this.h = h;
    this.side = side;
  }
}

/** The floats of one block formatting context, in the order they were placed. */
export class FloatCtx {
  boxes: FloatBox[] = [];
}

/**
 * A block laid out inside a float context, and where its content box sits in that context's
 * coordinates: line boxes and nested floats are placed against the floats recorded there.
 */
export class Flow {
  ctx: FloatCtx;
  x: number; // left edge of the content box
  y: number; // top edge of the content box
  // The margin that is collapsed above this box's top border edge from outside it (CSS 2.1
  // 8.3.1), as the largest positive and most negative part. A margin escaping this box's top edge
  // joins it, which is what decides whether a cleared box inside is pushed below a float.
  mgP = 0;
  mgN = 0;
  constructor(ctx: FloatCtx, x: number, y: number, mgP = 0, mgN = 0) {
    this.ctx = ctx;
    this.x = x;
    this.y = y;
    this.mgP = mgP;
    this.mgN = mgN;
  }
}

/**
 * The horizontal space left between floats for a box whose vertical range is y to y + h:
 * [left, right] in the context's coordinates. A box at y that only overlaps a float for part of
 * its height still has to avoid it, as a line box does.
 */
export function floatSlot(ctx: FloatCtx, y: number, h: number, left: number, width: number): number[] {
  let l = left;
  let r = left + width;
  const bottom = y + h;
  for (const f of ctx.boxes) {
    const fb = f.y + f.h;
    if (fb <= y + 0.01 || f.y >= bottom - 0.01) continue;
    const e = floatExtent(f, y, bottom);
    if (e === null) continue;
    if (f.side === P.FL_LEFT) {
      if (e[1] > l) l = e[1];
    } else if (e[0] < r) {
      r = e[0];
    }
  }
  if (r < l) r = l;
  return [l, r];
}

/**
 * The horizontal range a float excludes over the rows y to `bottom`: its box, or the widest
 * stretch of its shape inside those rows — a line box clears the shape across its whole height.
 * Null when the shape doesn't reach the rows at all.
 */
export function floatExtent(f: FloatBox, y: number, bottom: number): number[] | null {
  if (f.shape === null) return [f.x, f.x + f.w];
  const poly = f.shape;
  const n = poly.length / 2;
  // The shape is sampled at the rows' ends, at nine rows across, and at each vertex inside the
  // band, so a narrow waist between vertices is not missed.
  const rows: number[] = [y, bottom];
  for (let k = 1; k < 9; k++) rows.push(y + ((bottom - y) * k) / 9);
  for (let i = 0; i < n; i++) {
    const vy = poly[2 * i + 1];
    if (vy > y && vy < bottom) rows.push(vy);
  }
  let l = Infinity;
  let r = -Infinity;
  for (const sy of rows) {
    let minX = Infinity;
    let maxX = -Infinity;
    for (let i = 0; i < n; i++) {
      const ax = poly[2 * i], ay = poly[2 * i + 1];
      const bx = poly[2 * ((i + 1) % n)], by = poly[2 * ((i + 1) % n) + 1];
      if ((ay <= sy && by > sy) || (by <= sy && ay > sy)) {
        const x = ax + ((bx - ax) * (sy - ay)) / (by - ay);
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
    }
    if (minX === Infinity) continue;
    if (minX < l) l = minX;
    if (maxX > r) r = maxX;
  }
  return l === Infinity ? null : [l, r];
}

/**
 * Whether a float of each side faces the band y to y + h, as [left, right]. A float of zero width
 * counts: its edge still bounds the space a box beside it may use.
 */
export function floatSides(ctx: FloatCtx, y: number, h: number): boolean[] {
  let left = false;
  let right = false;
  const bottom = y + h;
  for (const f of ctx.boxes) {
    if (f.y + f.h <= y + 0.01 || f.y >= bottom - 0.01) continue;
    if (f.side === P.FL_LEFT) left = true;
    else right = true;
  }
  return [left, right];
}

/**
 * The lowest bottom edge among the floats `clear` applies to (CSS 2.1 9.5.2), or -Infinity when
 * there are none. A float with clear is placed below them too.
 */
export function clearBottom(ctx: FloatCtx, side: number): number {
  let b = -Infinity;
  for (const f of ctx.boxes) {
    const clears = side === P.CL_BOTH || (side === P.CL_LEFT && f.side === P.FL_LEFT) ||
      (side === P.CL_RIGHT && f.side === P.FL_RIGHT);
    if (!clears) continue;
    const fb = f.y + f.h;
    if (fb > b) b = fb;
  }
  return b;
}

/**
 * The y at or below `y` where a float of one `side`, whose margin box is w × h, fits beside the
 * floats of the context: it slides under the nearest float that is in its way (CSS 2.1 9.5.1,
 * rules 3 and 8). A float is held to the edge of its containing block and may stick out of it on
 * the other side, but not past a float of the other side (rule 3), and not past the far edge at
 * all when a float of its own side is already beside it (rule 7).
 */
export function floatFitY(ctx: FloatCtx, left: number, right: number, y: number, w: number, h: number,
  side: number): number {
  let yy = y;
  // A float may not go above a float placed before it in the document, of either side
  // (CSS 2.1 9.5.1, rule 6), even when the two would not touch.
  for (const f of ctx.boxes) {
    if (f.y > yy) yy = f.y;
  }
  for (let guard = 0; guard < 64; guard++) {
    const s = floatSlot(ctx, yy, h, left, right - left);
    const near = side === P.FL_LEFT ? s[0] : s[1] - w;
    let beside = false;
    let blocked = false;
    let next = Infinity;
    // The top of a float of the other side that starts within the band and holds the slot's edge
    // there: this float may not be placed above it, as rule 6 says for floats beside one another.
    let split = Infinity;
    for (const f of ctx.boxes) {
      const fb = f.y + f.h;
      if (fb <= yy + 0.01 || f.y >= yy + h - 0.01) continue;
      if (f.side === side) beside = true;
      // The slot already keeps clear of floats of the same side; one of the other side is in the
      // way when it starts before this box ends.
      const inWay = f.x < near + w - 0.01 && f.x + f.w > near + 0.01;
      if (f.side !== side && inWay) blocked = true;
      // The float goes below the first float beside it that ends, wherever that float sits: the
      // space may open up there, and the probe is only kept if the float fits at that y.
      if (fb < next) next = fb;
      if (f.side !== side && f.y > yy + 0.01) {
        const bounds = f.side === P.FL_RIGHT ? f.x <= s[1] + 0.01 : f.x + f.w >= s[0] - 0.01;
        if (bounds && f.y < split) split = f.y;
      }
    }
    // Rule 7: a float with one of its own side beside it can't stick out of its containing block.
    const sticksOut = side === P.FL_LEFT ? near + w > right + 0.01 : near < left - 0.01;
    if (!blocked && !(beside && sticksOut) && split === Infinity) return yy;
    if (split < next) next = split;
    if (sticksOut) {
      // Going below the floats of its own side it is next to is the only other place for it.
      for (const f of ctx.boxes) {
        const fb = f.y + f.h;
        if (f.side !== side || fb <= yy + 0.01 || f.y >= yy + h - 0.01) continue;
        if (fb < next) next = fb;
      }
    }
    if (next === Infinity || !(next > yy)) return yy;
    yy = next;
  }
  return yy;
}

/** The bottom of the lowest float in the context, or -Infinity when it holds none. */
export function floatBottom(ctx: FloatCtx): number {
  let b = -Infinity;
  for (const f of ctx.boxes) {
    const fb = f.y + f.h;
    if (fb > b) b = fb;
  }
  return b;
}

/**
 * The y at or below `y` where a line box holding content w wide sits clear of the floats: a line
 * box is shortened by the floats beside it, and one that is too small to hold its content is
 * shifted down until it fits or there are no floats left (CSS 2.1 9.5).
 */
export function lineFitY(ctx: FloatCtx, y: number, h: number, left: number, bw: number, w: number): number {
  let yy = y;
  for (let guard = 0; guard < 64; guard++) {
    const s = floatSlot(ctx, yy, h, left, bw);
    if (s[1] - s[0] >= w - 0.01) return yy;
    // Move below the float that ends first among those beside it: the space may open up there.
    let next = Infinity;
    for (const f of ctx.boxes) {
      const fb = f.y + f.h;
      if (fb <= yy + 0.01 || f.y >= yy + h - 0.01) continue;
      if (fb < next) next = fb;
    }
    if (next === Infinity || !(next > yy)) return yy;
    yy = next;
  }
  return yy;
}
