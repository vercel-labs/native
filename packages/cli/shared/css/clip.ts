// The rectangles `clip: rect(top, right, bottom, left)` names, as rows of [v, u] pairs. The
// value a property holds is the row's id, stored with unit U_LIST; a row id of -1 is `auto`.

import * as P from "../props.ts";
import { RowTable } from "./rows.ts";

export const clipRows: RowTable = new RowTable();

/** A clip rectangle's CSS text, for serializing a value that carries one. */
export function clipText(id: number): string {
  const row = clipRows.row(id);
  if (row === null || row.length < 8) return "auto";
  const sides: string[] = [];
  for (let k = 0; k < 8; k += 2) {
    sides.push(row[k + 1] === P.U_AUTO ? "auto" : String(Math.round(row[k] * 1000) / 1000) + "px");
  }
  return `rect(${sides[0]}, ${sides[1]}, ${sides[2]}, ${sides[3]})`;
}
