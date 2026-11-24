// Multi-column layout properties: column-count, column-width, the `columns` shorthand,
// column-fill, column-span and the column rule (CSS Multicol 1). Column-gap is the same
// `column-gap` property flex and grid use, and is handled with them.

import * as P from "../../props.ts";
import { parseBorderColor, parseBorderStyle } from "../borders.ts";
import { parseLength, kw } from "../declarations.ts";
import { splitValue } from "../fonts.ts";
import type { Decl, FontContext } from "../types.ts";

/** A non-negative length, or null: what column-width takes. */
function columnLength(v: string): { v: number; u: number } | null {
  const l = parseLength(v, false);
  if (l === null || l.u === P.U_PCT || l.u === P.U_AUTO || l.v < 0) return null;
  return l;
}

/** The `columns` shorthand: a width, a count, or both in either order, and a column height
 *  after a slash. */
function columnsShorthand(value: string, out: Decl[]): string | null {
  const unsupported = `unsupported value '${value}' for 'columns'`;
  // `<count or width> / <column-height>`: the height follows a slash (CSS Multicol 2).
  const slash = value.indexOf("/");
  if (slash >= 0 && value.indexOf("/", slash + 1) >= 0) return unsupported;
  const head = slash >= 0 ? value.slice(0, slash) : value;
  const tail = slash >= 0 ? value.slice(slash + 1).trim().toLowerCase() : null;
  const parts = splitValue(head);
  if (parts.length < 1 || parts.length > 2) return unsupported;
  let width: { v: number; u: number } | null = null;
  let count = 0;
  let sawWidth = false;
  let sawCount = false;
  for (const part of parts) {
    const t = part.trim().toLowerCase();
    if (t === "auto") continue;
    if (/^\d+$/.test(t)) {
      const n = Number(t);
      if (n < 1 || sawCount) return unsupported;
      count = n;
      sawCount = true;
      continue;
    }
    const l = columnLength(t);
    if (l === null || sawWidth) return unsupported;
    width = l;
    sawWidth = true;
  }
  let height: { v: number; u: number } | null = null;
  if (tail !== null && tail !== "auto") {
    height = columnLength(tail);
    if (height === null) return unsupported;
  }
  // The shorthand resets all its longhands, as a shorthand does.
  out.push(width === null ? { p: P.P_COLUMN_WIDTH, v: 0, u: P.U_AUTO } : { p: P.P_COLUMN_WIDTH, v: width.v, u: width.u });
  out.push(sawCount ? { p: P.P_COLUMN_COUNT, v: count, u: P.U_NONE } : { p: P.P_COLUMN_COUNT, v: 0, u: P.U_AUTO });
  out.push(height === null ? { p: P.P_COLUMN_HEIGHT, v: 0, u: P.U_AUTO } : { p: P.P_COLUMN_HEIGHT, v: height.v, u: height.u });
  // CSS Multicol 2 makes the shorthand reset column-wrap too.
  out.push({ p: P.P_COLUMN_WRAP, v: P.CW_AUTO, u: P.U_NONE });
  return null;
}

/** The `column-rule` shorthand: a width, a style and a colour in any order. */
function columnRuleShorthand(value: string, out: Decl[]): string | null {
  const unsupported = `unsupported value '${value}' for 'column-rule'`;
  let width: { v: number; u: number } | null = null;
  let style = -1;
  let color = -1;
  for (const part of splitValue(value)) {
    const t = part.trim();
    const s = parseBorderStyle(t);
    if (s >= 0 && style < 0) { style = s; continue; }
    const l = columnLength(t);
    if (l !== null && width === null) { width = l; continue; }
    const c = parseBorderColor(t);
    if (c !== null && color === -1) { color = c; continue; }
    return unsupported;
  }
  out.push(width === null ? { p: P.P_COLUMN_RULE_WIDTH, v: 3, u: P.U_PX }
    : { p: P.P_COLUMN_RULE_WIDTH, v: width.v, u: width.u });
  out.push({ p: P.P_COLUMN_RULE_STYLE, v: style < 0 ? P.BRS_NONE : style, u: P.U_NONE });
  out.push({ p: P.P_COLUMN_RULE_COLOR, v: color, u: P.U_NONE });
  return null;
}

export function multicolProperty(prop: string, value: string, out: Decl[], fonts?: FontContext): string | null | undefined {
  switch (prop) {
    case "column-count": {
      const t = value.trim().toLowerCase();
      if (t === "auto") { out.push({ p: P.P_COLUMN_COUNT, v: 0, u: P.U_AUTO }); return null; }
      if (!/^\d+$/.test(t) || Number(t) < 1) return `unsupported value '${value}' for 'column-count'`;
      out.push({ p: P.P_COLUMN_COUNT, v: Number(t), u: P.U_NONE });
      return null;
    }
    case "column-width": {
      const t = value.trim().toLowerCase();
      if (t === "auto") { out.push({ p: P.P_COLUMN_WIDTH, v: 0, u: P.U_AUTO }); return null; }
      const l = columnLength(t);
      if (l === null) return `unsupported value '${value}' for 'column-width'`;
      out.push({ p: P.P_COLUMN_WIDTH, v: l.v, u: l.u });
      return null;
    }
    case "columns":
      return columnsShorthand(value, out);
    case "column-fill":
      return kw(prop, value, { auto: P.CF_AUTO, balance: P.CF_BALANCE, "balance-all": P.CF_BALANCE_ALL },
        P.P_COLUMN_FILL, out);
    case "column-span":
      return kw(prop, value, { none: P.CS_NONE, all: P.CS_ALL }, P.P_COLUMN_SPAN, out);
    case "column-height": {
      const t = value.trim().toLowerCase();
      if (t === "auto") { out.push({ p: P.P_COLUMN_HEIGHT, v: 0, u: P.U_AUTO }); return null; }
      const l = columnLength(t);
      if (l === null) return `unsupported value '${value}' for 'column-height'`;
      out.push({ p: P.P_COLUMN_HEIGHT, v: l.v, u: l.u });
      return null;
    }
    case "column-wrap":
      return kw(prop, value, { auto: P.CW_AUTO, wrap: P.CW_WRAP, nowrap: P.CW_NOWRAP },
        P.P_COLUMN_WRAP, out);
    case "column-rule":
      return columnRuleShorthand(value, out);
    case "column-rule-width": {
      const l = columnLength(value.trim());
      if (l === null) return `unsupported border width '${value}' for 'column-rule-width'`;
      out.push({ p: P.P_COLUMN_RULE_WIDTH, v: l.v, u: l.u });
      return null;
    }
    case "column-rule-style": {
      const s = parseBorderStyle(value);
      if (s < 0) return `invalid border style '${value}' for 'column-rule-style'`;
      out.push({ p: P.P_COLUMN_RULE_STYLE, v: s, u: P.U_NONE });
      return null;
    }
    case "column-rule-color": {
      const c = parseBorderColor(value);
      if (c === null) return `unsupported border color '${value}' for 'column-rule-color'`;
      out.push({ p: P.P_COLUMN_RULE_COLOR, v: c, u: P.U_NONE });
      return null;
    }
    default:
      return undefined;
  }
}
