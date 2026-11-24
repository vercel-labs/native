// The <position> grammar shared by background-position and object-position: one or two keywords
// or lengths, or two `<edge keyword> <offset>` pairs such as `right 10px bottom 20%`.
//
// A position compiles to a row of [xv, xu, xFromRight, yv, yu, yFromBottom]; the edge flags let
// `right 10px` and `bottom 20%` measure their offset from the right and bottom edges. The row id
// is the property's value, stored with unit U_LIST.

import * as P from "../props.ts";
import { parseLength } from "./declarations.ts";
import type { Len } from "./declarations.ts";
import { splitValue } from "./fonts.ts";
import { RowTable } from "./rows.ts";

// Position rows: background layers have their own per-property tables, while object-position
// keeps its single position here.
export const positionRows: RowTable = new RowTable();

const HORIZONTAL = 0;
const VERTICAL = 1;
const EITHER = 2;

interface Pos { v: number; u: number; edge: number }

/** A keyword's axis and percentage, as [axis, value]. */
function positionKeyword(token: string): number[] | null {
  switch (token) {
    case "left": return [HORIZONTAL, 0];
    case "right": return [HORIZONTAL, 100];
    case "top": return [VERTICAL, 0];
    case "bottom": return [VERTICAL, 100];
    case "center": return [EITHER, 50];
    default: return null;
  }
}

/**
 * One <position> value as [xv, xu, xFromRight, yv, yu, yFromBottom], or an error message that
 * names `prop`.
 */
export function parsePosition(token: string, prop: string): number[] | string {
  // A calc() holds spaces of its own, so the parts split outside its parentheses.
  const parts = splitValue(token.trim().toLowerCase());
  if (parts.length < 1 || parts.length > 4) return `unsupported ${prop} '${token}'`;
  const pct = (v: number): Pos => ({ v, u: P.U_PCT, edge: 0 });
  let x: Pos | null = null;
  let y: Pos | null = null;
  if (parts.length >= 3) {
    // Three or four values are <edge keyword> <offset> pairs, in either order, with `center`
    // allowed for the other axis: `top 3px center` and `center right 25%`.
    let centers = 0;
    let i = 0;
    while (i < parts.length) {
      const kw = positionKeyword(parts[i]);
      const l = parseLength(parts[i], false);
      if (kw !== null && kw[0] !== EITHER) {
        const off = i + 1 < parts.length ? parseLength(parts[i + 1], false) : null;
        if (off === null) return `unsupported ${prop} '${token}'`;
        const p: Pos = { v: off.v, u: off.u, edge: kw[1] === 100 ? 1 : 0 };
        if (kw[0] === VERTICAL) {
          if (y !== null) return `unsupported ${prop} '${token}'`;
          y = p;
        } else {
          if (x !== null) return `unsupported ${prop} '${token}'`;
          x = p;
        }
        i += 2;
      } else if (kw !== null) {
        centers++;
        i++;
      } else if (l !== null) {
        const p: Pos = { v: l.v, u: l.u, edge: 0 };
        if (x === null) x = p;
        else if (y === null) y = p;
        else return `unsupported ${prop} '${token}'`;
        i++;
      } else {
        return `unsupported ${prop} '${token}'`;
      }
    }
    for (; centers > 0; centers--) {
      if (x === null) x = pct(50);
      else if (y === null) y = pct(50);
      else return `unsupported ${prop} '${token}'`;
    }
  } else {
    // One or two values, in axis order: the first fills the horizontal axis (unless it is a
    // vertical keyword) and the second the vertical one, so "left top", "top left", "10px
    // center", "center 10px", "bottom 10px" and "left 10px" all work. "10px left" is invalid.
    const kws = parts.map(positionKeyword);
    const lens: (Len | null)[] = parts.map((s) => parseLength(s, false));
    for (let i = 0; i < parts.length; i++) {
      const k = kws[i];
      const l = lens[i];
      if (k !== null) {
        if (k[0] === EITHER) {
          if (x === null) x = pct(50);
          else if (y === null) y = pct(50);
          else return `unsupported ${prop} '${token}'`;
        } else if (k[0] === HORIZONTAL) {
          if (x !== null) return `unsupported ${prop} '${token}'`;
          x = pct(k[1]);
        } else {
          if (y !== null) return `unsupported ${prop} '${token}'`;
          y = pct(k[1]);
        }
      } else if (l !== null) {
        const p: Pos = { v: l.v, u: l.u, edge: 0 };
        if (x === null) x = p;
        else if (y === null) y = p;
        else return `unsupported ${prop} '${token}'`;
      } else {
        return `unsupported ${prop} '${token}'`;
      }
    }
    // An axis no value named is centered, as in "bottom" or "left 10px".
    if (x === null) x = pct(50);
    if (y === null) y = pct(50);
  }
  if (x === null || y === null) return `unsupported ${prop} '${token}'`;
  return [x.v, x.u, x.edge, y.v, y.u, y.edge];
}

/** A position row's CSS text, for serializing a value that carries one. */
export function positionText(id: number): string {
  const row = positionRows.row(id);
  if (row === null || row.length < 6) return "50% 50%";
  return `${axisText(row[0], row[1], row[2], "left", "right")} ${axisText(row[3], row[4], row[5], "top", "bottom")}`;
}

export function axisText(v: number, u: number, edge: number, start: string, end: string): string {
  const text = u === P.U_PX ? `${Math.round(v * 1000) / 1000}px` : `${Math.round(v * 1000) / 1000}%`;
  if (edge === 1) return `${end} ${text}`;
  if (v === 0 && u === P.U_PCT) return start;
  if (v === 100 && u === P.U_PCT) return end;
  if (v === 50 && u === P.U_PCT) return "center";
  return text;
}
