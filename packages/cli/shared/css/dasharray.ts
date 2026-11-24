// stroke-dasharray: the dash pattern a stroke is broken into, as a row of [v, u] length pairs.
// The value a property holds is the row's id, stored with unit U_LIST; -1 is `none`, the
// property's initial value.
//
// An SVG attribute may give bare numbers, which are user units even though CSS wants a length, so
// the parsers here take both. A pattern with an odd number of lengths repeats to make it even,
// which the painter leaves to the host: CoreGraphics cycles the pattern it is given.

import * as P from "../props.ts";
import { parseLength } from "./declarations.ts";
import type { Len } from "./declarations.ts";
import { RowTable } from "./rows.ts";

export const dashRows: RowTable = new RowTable();

const BARE = /^[-+]?(?:\d+\.?\d*|\.\d+)$/;

/** A dash length: a bare number is user units (`U_PX`), anything else is a CSS length. */
export function dashLen(token: string): Len | null {
  const s = token.trim();
  if (BARE.test(s)) return { v: parseFloat(s), u: P.U_PX };
  return parseLength(s, false);
}

/** A dash pattern as its [v, u] pairs, or an error message that names the property. */
export function parseDashArray(value: string): number[] | string {
  const row: number[] = [];
  for (const token of value.trim().split(/[\s,]+/)) {
    if (token === "") continue;
    const len = dashLen(token);
    if (len === null) return `unsupported length '${token}' in 'stroke-dasharray'`;
    if (len.v < 0) return `'stroke-dasharray' takes lengths that can't be negative ('${token}')`;
    row.push(len.v, len.u);
  }
  return row;
}

/** A dash pattern's CSS text, for serializing a value that carries one. */
export function dashText(id: number): string {
  const row = id < 0 ? null : dashRows.row(id);
  if (row === null) return "none";
  const parts: string[] = [];
  for (let i = 0; i + 1 < row.length; i += 2) parts.push(lengthText(row[i], row[i + 1]));
  return parts.join(", ");
}

/** One length as CSS text, the way a computed value serializes it. */
function lengthText(v: number, u: number): string {
  const n = Math.round(v * 1000) / 1000;
  if (u === P.U_PCT) return `${n}%`;
  return `${n}px`;
}
