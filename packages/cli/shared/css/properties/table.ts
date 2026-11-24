// CSS table properties and the table display values. Returns undefined for a property this
// module doesn't handle.

import * as P from "../../../shared/props.ts";
import { kw, lengths, parseLength } from "../declarations.ts";
import { exprHasPercent } from "../length-exprs.ts";
import type { Decl } from "../types.ts";

/** The table display keywords; the box module handles the rest. */
export const TABLE_DISPLAY: Record<string, number> = {
  table: P.D_TABLE,
  "inline-table": P.D_INLINE_TABLE,
  "table-row-group": P.D_TABLE_ROW_GROUP,
  "table-header-group": P.D_TABLE_HEADER_GROUP,
  "table-footer-group": P.D_TABLE_FOOTER_GROUP,
  "table-row": P.D_TABLE_ROW,
  "table-cell": P.D_TABLE_CELL,
  "table-column-group": P.D_TABLE_COLUMN_GROUP,
  "table-column": P.D_TABLE_COLUMN,
  "table-caption": P.D_TABLE_CAPTION,
};

export function tableProperty(prop: string, value: string, out: Decl[]): string | null | undefined {
  switch (prop) {
    case "display":
      {
      // Only the table keywords are handled here; the other display values fall through to the
      // box module.
      const v = TABLE_DISPLAY[value.toLowerCase()];
      if (v === undefined) return undefined;
      out.push({ p: P.P_DISPLAY, v, u: P.U_NONE });
      return null;
    }
    case "table-layout":
      return kw(prop, value, { auto: P.TL_AUTO, fixed: P.TL_FIXED }, P.P_TABLE_LAYOUT, out);
    case "border-collapse":
      return kw(prop, value, { separate: P.BC_SEPARATE, collapse: P.BC_COLLAPSE }, P.P_BORDER_COLLAPSE, out);
    case "border-spacing":
      {
      const parts = value.split(/\s+/);
      if (parts.length > 2) return `'border-spacing' takes 1 or 2 values`;
      const h = parseLength(parts[0], false);
      const v = parseLength(parts[1] ?? parts[0], false);
      // `border-spacing` takes lengths only: a percentage is invalid, and the declaration is
      // ignored as a whole, so the spacing keeps whatever it was (CSS 2.1 §17.6.1).
      if (h !== null && (h.u === P.U_PCT || v !== null && v.u === P.U_PCT)) {
        return `invalid value '${value}' for 'border-spacing': it takes lengths, not percentages, so the declaration is ignored`;
      }
      if (!h || !v ||
        (h.u === P.U_EXPR && exprHasPercent(h.v)) || (v.u === P.U_EXPR && exprHasPercent(v.v))) {
        return `unsupported value '${value}' for 'border-spacing'`;
      }
      if (h.v < 0 || v.v < 0) return `invalid value '${value}' for 'border-spacing': it can't be negative, so the declaration is ignored`;
      out.push({ p: P.P_BORDER_SPACING_H, v: h.v, u: h.u }, { p: P.P_BORDER_SPACING_V, v: v.v, u: v.u });
      return null;
    }
    case "caption-side":
      return kw(prop, value, { top: P.CS_TOP, bottom: P.CS_BOTTOM }, P.P_CAPTION_SIDE, out);
    case "empty-cells":
      return kw(prop, value, { show: P.EC_SHOW, hide: P.EC_HIDE }, P.P_EMPTY_CELLS, out);
    default:
      return undefined;
  }
}
