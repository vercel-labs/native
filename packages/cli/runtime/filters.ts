// filter and backdrop-filter: the lists compiled at build time, and resolving one against the
// element it paints.
//
// A value is a row id into the filter table; each row holds eight numbers per filter function
// (see shared/css/filters.ts). The lengths keep their units until here, since em and vw need the
// element and the viewport.

import * as P from "../shared/props.ts";
import type { Node } from "./dom.ts";
import { viewport } from "./layout/box-model.ts";
import { rootFontSize } from "./root-size.ts";
import { evalExpr } from "../shared/css/length-exprs.ts";

export class FilterTables {
  rows: number[][] = [];
  /** Rows an inline style registers at runtime, by synthetic id. */
  extras: Map<number, number[]> = new Map();
  extraKeys: Map<string, number> = new Map();
}

export const filterTables: FilterTables = new FilterTables();

/** Rows registered at runtime start above every compiled row id. */
const RUNTIME_BASE = 1000000;

/** Registers one filter list an inline style declared, and returns its id. */
export function registerFilter(row: number[]): number {
  const key = row.join(",");
  const hit = filterTables.extraKeys.get(key);
  if (hit !== undefined) return hit;
  const id = RUNTIME_BASE + filterTables.extras.size;
  filterTables.extras.set(id, row);
  filterTables.extraKeys.set(key, id);
  return id;
}

/** One filter function of a list, with its lengths in px. */
export interface FilterOp {
  kind: number;
  /** The length or number the function takes: the blur, the colour factor or the angle. */
  a: number;
  /** drop-shadow's offsets and blur. */
  dx: number;
  dy: number;
  blur: number;
  /** drop-shadow's colour, packed 0xRRGGBBAA; -1 is currentColor. */
  color: number;
}

function resolve(v: number, u: number, el: Node): number {
  if (u === P.U_EXPR) return evalExpr(v, 0, viewport.w, viewport.h, el.sv[P.P_FONT_SIZE], viewport.w, viewport.h, rootFontSize(), el.sv[P.P_LINE_HEIGHT]);
  if (u === P.U_EM) return v * el.sv[P.P_FONT_SIZE];
  if (u === P.U_REM) return v * rootFontSize();
  if (u === P.U_VW) return (v / 100) * viewport.w;
  if (u === P.U_VH) return (v / 100) * viewport.h;
  return v; // px, or a unitless zero
}

/** The filter list behind a `filter` value (a row id), resolved against the element. */
export function filterList(el: Node, id: number): FilterOp[] {
  if (id < 0) return [];
  const row = id >= RUNTIME_BASE ? filterTables.extras.get(id) : filterTables.rows[id];
  if (row === undefined) return [];
  const out: FilterOp[] = [];
  for (let i = 0; i + 7 < row.length; i += 8) {
    const kind = row[i];
    const op: FilterOp = { kind, a: 0, dx: 0, dy: 0, blur: 0, color: -1 };
    if (kind === P.FK_DROP_SHADOW) {
      op.dx = resolve(row[i + 1], row[i + 2], el);
      op.dy = resolve(row[i + 3], row[i + 4], el);
      op.blur = Math.max(0, resolve(row[i + 5], row[i + 6], el));
      op.color = row[i + 7];
    } else if (kind === P.FK_BLUR) {
      op.a = Math.max(0, resolve(row[i + 1], row[i + 2], el));
    } else {
      // The colour functions and hue-rotate take a plain number or an angle.
      op.a = row[i + 1];
    }
    out.push(op);
  }
  return out;
}

/** The element's `filter` list. */
export function elementFilter(el: Node): FilterOp[] {
  return filterList(el, el.sv[P.P_FILTER]);
}

/** The element's `backdrop-filter` list. */
export function elementBackdropFilter(el: Node): FilterOp[] {
  return filterList(el, el.sv[P.P_BACKDROP_FILTER]);
}

/**
 * Whether the element carries a filter, which makes it a containing block for its absolutely and
 * fixed positioned descendants (CSS Filter Effects).
 */
export function hasFilterContext(el: Node): boolean {
  return el.sv[P.P_FILTER] >= 0 || el.sv[P.P_BACKDROP_FILTER] >= 0;
}
