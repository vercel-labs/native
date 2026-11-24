// CSS box-shadow. A value is a comma-separated list of shadows, each an optional `inset`, two to
// four lengths (offset-x and offset-y, then blur and spread) and an optional color; the color
// defaults to currentColor. The list is compiled into one row of ten numbers per shadow (see
// P_BOX_SHADOW) and the declaration's value is that row's id in the shadow table.

import * as P from "../props.ts";
import { parseColor } from "./colors.ts";
import { parseLength } from "./declarations.ts";
import type { Len } from "./declarations.ts";
import { exprHasPercent } from "./length-exprs.ts";
import { splitValue } from "./fonts.ts";
import { splitLayers } from "./properties/backgrounds.ts";
import { RowTable } from "./rows.ts";
import type { Decl, FontContext } from "./types.ts";

/**
 * The compiled shadow lists, ten numbers per shadow in each row. An inline style and a mixed
 * shadow register their own rows at runtime, after the build's; the build emits `all()`.
 */
export const shadowRows: RowTable = new RowTable();

/** One shadow's fields, as a flat run of ten numbers. */
const FIELDS = 10;

function pushLen(row: number[], l: Len): void {
  row.push(l.v, l.u);
}

/**
 * One shadow: `inset`? (box shadows only), two or three lengths for a text shadow or up to four
 * for a box shadow, and a color. Returns its ten numbers or an error.
 */
function shadowFields(text: string, prop: string, maxLens: number = 4, allowInset: boolean = true): number[] | string {
  const row: number[] = [];
  const lens: Len[] = [];
  let inset = false;
  // -1 is currentColor, which is also the default when no color is written.
  let color = -1;
  let hasColor = false;
  for (const part of splitValue(text)) {
    const lower = part.toLowerCase();
    if (lower === "inset" && allowInset) {
      if (inset) return `invalid value '${text}' for '${prop}': 'inset' is written twice`;
      inset = true;
      continue;
    }
    if (!hasColor) {
      if (lower === "currentcolor") {
        hasColor = true;
        color = -1;
        continue;
      }
      const c = parseColor(part);
      if (c !== null) {
        hasColor = true;
        color = c;
        continue;
      }
    }
    const l = parseLength(part, false);
    if (l === null) return `unsupported length '${part}' in '${prop}: ${text}'`;
    // Shadows take lengths only: a percentage has nothing to measure against.
    if (l.u === P.U_PCT || (l.u === P.U_EXPR && exprHasPercent(l.v))) {
      return `unsupported percentage '${part}' in '${prop}: ${text}'`;
    }
    lens.push(l);
  }
  if (lens.length < 2) return `invalid value '${text}' for '${prop}': a shadow needs an offset in both directions`;
  if (lens.length > maxLens) return `invalid value '${text}' for '${prop}': too many lengths`;
  // A negative spread is fine: it shrinks the shadow shape. A negative blur is not.
  if (lens.length >= 3 && lens[2].v < 0) return `invalid value '${text}' for '${prop}': the blur can't be negative`;
  pushLen(row, lens[0]);
  pushLen(row, lens[1]);
  pushLen(row, lens.length >= 3 ? lens[2] : { v: 0, u: P.U_PX });
  pushLen(row, lens.length >= 4 ? lens[3] : { v: 0, u: P.U_PX });
  row.push(color, inset ? 1 : 0);
  return row;
}

/**
 * `text-shadow`: `none`, or the comma-separated shadows of the glyphs, each two or three lengths
 * (the offsets and the blur) and a color, with no spread and no `inset`.
 */
export function textShadow(prop: string, value: string, out: Decl[], fonts?: FontContext): string | null {
  const text = value.trim();
  if (text.toLowerCase() === "none") {
    out.push({ p: P.P_TEXT_SHADOW, v: -1, u: P.U_LIST });
    return null;
  }
  const row: number[] = [];
  for (const layer of splitLayers(text)) {
    if (layer === "") return `invalid value '${value}' for '${prop}'`;
    const fields = shadowFields(layer, prop, 3, false);
    if (typeof fields === "string") return fields;
    for (const n of fields) row.push(n);
  }
  if (row.length === 0 || row.length % FIELDS !== 0) return `invalid value '${value}' for '${prop}'`;
  if (fonts === undefined) {
    out.push({ p: P.P_TEXT_SHADOW, v: -1, u: P.U_LIST });
    return null;
  }
  out.push({ p: P.P_TEXT_SHADOW, v: fonts.shadow(row), u: P.U_LIST });
  return null;
}

/**
 * `box-shadow`: `none`, or the comma-separated shadows. The first shadow is painted on top, as
 * the list says; the shadow table keeps the written order and the paint code walks it backwards.
 */
export function boxShadow(prop: string, value: string, out: Decl[], fonts?: FontContext): string | null {
  const text = value.trim();
  if (text.toLowerCase() === "none") {
    out.push({ p: P.P_BOX_SHADOW, v: -1, u: P.U_LIST });
    return null;
  }
  const row: number[] = [];
  for (const layer of splitLayers(text)) {
    if (layer === "") return `invalid value '${value}' for '${prop}'`;
    const fields = shadowFields(layer, prop);
    if (typeof fields === "string") return fields;
    for (const n of fields) row.push(n);
  }
  if (row.length === 0 || row.length % FIELDS !== 0) return `invalid value '${value}' for '${prop}'`;
  if (fonts === undefined) {
    out.push({ p: P.P_BOX_SHADOW, v: -1, u: P.U_LIST });
    return null;
  }
  out.push({ p: P.P_BOX_SHADOW, v: fonts.shadow(row), u: P.U_LIST });
  return null;
}
