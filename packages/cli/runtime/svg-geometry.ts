// SVG path geometry: what `getTotalLength()` and `getPointAtLength()` answer for a <path>.
//
// The path's `d` attribute is parsed by the shared path grammar (shared/svg.ts), which turns
// every command, arcs included, into moves, lines, quadratics and cubics. Curves are flattened
// to polylines with the same deviation the clip-path flattener allows (0.05 px), so a length is
// the length of the flattened outline — as browsers report one, close to the exact arc length
// for any curve a page draws. Subpaths are measured one after another: the jump between them is
// not a segment, exactly as a browser measures it.

import { pathData } from "../shared/svg.ts";

/** How far a flattened curve may stray from the real one, in user units. */
const FLAT_TOL = 0.05;

function flatQuad(out: number[], x0: number, y0: number, qx: number, qy: number, x1: number, y1: number, depth: number): void {
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

/** The path's subpaths as flat runs of x,y vertices, in user space. A closed subpath's last
 *  vertex is its first: the closing line is a segment like any other. */
export function flattenPathData(d: string): number[][] {
  const ops = pathData(d);
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
      cx = ops[i + 1];
      cy = ops[i + 2];
      sx = cx;
      sy = cy;
      cur.push(cx, cy);
      i += 3;
    } else if (kind === 2) {
      cx = ops[i + 1];
      cy = ops[i + 2];
      cur.push(cx, cy);
      i += 3;
    } else if (kind === 3) {
      const qx = ops[i + 1], qy = ops[i + 2];
      const x1 = ops[i + 3], y1 = ops[i + 4];
      flatQuad(cur, cx, cy, qx, qy, x1, y1, 0);
      cx = x1;
      cy = y1;
      i += 5;
    } else if (kind === 4) {
      const x1 = ops[i + 1], y1 = ops[i + 2];
      const x2 = ops[i + 3], y2 = ops[i + 4];
      const x3 = ops[i + 5], y3 = ops[i + 6];
      flatCubic(cur, cx, cy, x1, y1, x2, y2, x3, y3, 0);
      cx = x3;
      cy = y3;
      i += 7;
    } else {
      // A close draws back to the subpath's start; the next move opens a new one.
      cur.push(sx, sy);
      flush();
      cx = sx;
      cy = sy;
      i += 1;
    }
  }
  flush();
  return polys;
}

/** The length of the whole path: the sum of every segment of every subpath. */
export function pathTotalLength(d: string): number {
  let total = 0;
  for (const poly of flattenPathData(d)) {
    for (let i = 2; i + 1 < poly.length; i += 2) {
      total += Math.hypot(poly[i] - poly[i - 2], poly[i + 1] - poly[i - 1]);
    }
  }
  return total;
}

/** The point a distance along the path, clamped to its start and its end. */
export function pathPointAtLength(d: string, distance: number): { x: number; y: number } {
  const polys = flattenPathData(d);
  let left = distance;
  let first: { x: number; y: number } | null = null;
  let last: { x: number; y: number } | null = null;
  for (const poly of polys) {
    if (first === null) first = { x: poly[0], y: poly[1] };
    last = { x: poly[poly.length - 2], y: poly[poly.length - 1] };
    for (let i = 2; i + 1 < poly.length; i += 2) {
      const x0 = poly[i - 2], y0 = poly[i - 1], x1 = poly[i], y1 = poly[i + 1];
      const seg = Math.hypot(x1 - x0, y1 - y0);
      if (seg === 0) continue;
      if (left <= seg) {
        const t = left / seg;
        return { x: x0 + (x1 - x0) * t, y: y0 + (y1 - y0) * t };
      }
      left -= seg;
    }
  }
  return last ?? first ?? { x: 0, y: 0 };
}
