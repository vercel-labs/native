// CSS flexbox properties. Returns undefined for a property this module doesn't handle.

import * as P from "../../props.ts";
import { BORDER_COLORS, BORDER_SIDES, BORDER_WIDTHS, borderColor, borderColors, borderShorthand, borderStyles, borderWidth, borderWidths } from "../borders.ts";
import { parseColor } from "../colors.ts";
import { colorDecl, kw, lengths, parseLength, single } from "../declarations.ts";
import type { Len } from "../declarations.ts";
import { splitValue } from "../fonts.ts";
import type { Decl } from "../types.ts";
import { CONTENT_BASELINE, CONTENT_DISTRIBUTION, CONTENT_INVALID, CONTENT_POSITION, ITEMS_INVALID, ITEMS_WORDS, NO_AUTO, SELF_INVALID, SELF_POSITION, SELF_WORDS, alignValue, placeValues } from "./alignment.ts";

// align-content and justify-content share the packing keywords but not their `normal` value:
// align-content's normal stretches the tracks, justify-content's leaves them at their start.
// `stretch` is the same as each one's normal.
const ALIGN_CONTENT_WORDS: Record<string, number> = {
  normal: P.AC_NORMAL, stretch: P.AC_STRETCH, ...CONTENT_POSITION, ...CONTENT_DISTRIBUTION, ...CONTENT_BASELINE,
};

const JUSTIFY_CONTENT_WORDS: Record<string, number> = {
  normal: P.J_NORMAL, stretch: P.J_STRETCH, ...CONTENT_POSITION, ...CONTENT_DISTRIBUTION, ...CONTENT_BASELINE,
  left: P.J_LEFT, right: P.J_RIGHT,
};

/** justify-content's positions, which also take the physical edges left and right. */
const JUSTIFY_CONTENT_POSITION: Record<string, number> = { ...CONTENT_POSITION, left: P.J_LEFT, right: P.J_RIGHT };

export function flexProperty(prop: string, value: string, out: Decl[]): string | null | undefined {
  if (P.WEBKIT_FLEX_ALIASES.has(prop)) prop = prop.slice("-webkit-".length);
  switch (prop) {
    case "flex-direction":
      return kw(prop, value, {
        row: P.FD_ROW, column: P.FD_COLUMN, "row-reverse": P.FD_ROW_REVERSE, "column-reverse": P.FD_COLUMN_REVERSE,
      }, P.P_FLEX_DIRECTION, out);
    case "flex-wrap":
      return kw(prop, value, { nowrap: P.FW_NOWRAP, wrap: P.FW_WRAP, "wrap-reverse": P.FW_WRAP_REVERSE },
        P.P_FLEX_WRAP, out);
    case "flex-flow": {
      // The direction and the wrap value, in either order.
      const dirs: Record<string, number> = { row: P.FD_ROW, column: P.FD_COLUMN, "row-reverse": P.FD_ROW_REVERSE, "column-reverse": P.FD_COLUMN_REVERSE };
      const wraps: Record<string, number> = { nowrap: P.FW_NOWRAP, wrap: P.FW_WRAP, "wrap-reverse": P.FW_WRAP_REVERSE };
      let dir = -1, wrap = -1;
      for (const part of value.split(/\s+/)) {
        if (dir < 0 && dirs[part] !== undefined) dir = dirs[part];
        else if (wrap < 0 && wraps[part] !== undefined) wrap = wraps[part];
        else return `unsupported value '${value}' for 'flex-flow'`;
      }
      if (dir >= 0) out.push({ p: P.P_FLEX_DIRECTION, v: dir, u: P.U_NONE });
      if (wrap >= 0) out.push({ p: P.P_FLEX_WRAP, v: wrap, u: P.U_NONE });
      return null;
    }
    case "place-content": {
      // The block-axis value, then the inline-axis one, which defaults to the first.
      const pair = placeValues(value);
      if (pair === null) return `invalid value '${value}' for 'place-content'`;
      const decls: Decl[] = [];
      const err = alignValue(prop, pair[0], ALIGN_CONTENT_WORDS, CONTENT_POSITION, CONTENT_INVALID, P.P_ALIGN_CONTENT, decls);
      if (err !== null) return err;
      const err2 = alignValue(prop, pair[1], JUSTIFY_CONTENT_WORDS, JUSTIFY_CONTENT_POSITION, NO_AUTO, P.P_JUSTIFY_CONTENT, decls);
      if (err2 !== null) return err2;
      for (const d of decls) out.push(d);
      return null;
    }
    case "align-content":
      return alignValue(prop, value, ALIGN_CONTENT_WORDS, CONTENT_POSITION, CONTENT_INVALID, P.P_ALIGN_CONTENT, out);
    case "order": {
      if (!/^[-+]?\d+$/.test(value)) return `invalid value '${value}' for 'order'`;
      out.push({ p: P.P_ORDER, v: parseInt(value, 10), u: P.U_NONE });
      return null;
    }
    case "justify-content":
      return alignValue(prop, value, JUSTIFY_CONTENT_WORDS, JUSTIFY_CONTENT_POSITION, NO_AUTO, P.P_JUSTIFY_CONTENT, out);
    case "align-items":
      return alignValue(prop, value, ITEMS_WORDS, SELF_POSITION, ITEMS_INVALID, P.P_ALIGN_ITEMS, out);
    case "align-self":
      return alignValue(prop, value, SELF_WORDS, SELF_POSITION, SELF_INVALID, P.P_ALIGN_SELF, out);
    case "gap":
    case "grid-gap":
      {
      // A calc() holds spaces of its own, so the parts split outside its parentheses.
      const parts = splitValue(value);
      const part = (t: string): { v: number; u: number } | null => t.toLowerCase() === "normal"
        ? { v: 0, u: P.U_NORMAL } : parseLength(t, false);
      const r = part(parts[0]);
      const c = part(parts[1] ?? parts[0]);
      if (!r || !c || parts.length > 2) return `unsupported value '${value}' for '${prop}'`;
      out.push({ p: P.P_ROW_GAP, v: r.v, u: r.u }, { p: P.P_COLUMN_GAP, v: c.v, u: c.u });
      return null;
    }
    case "row-gap":
    case "grid-row-gap":
      if (value.trim().toLowerCase() === "normal") { out.push({ p: P.P_ROW_GAP, v: 0, u: P.U_NORMAL }); return null; }
      return single(prop, value, P.P_ROW_GAP, false, out, true);
    case "column-gap":
    case "grid-column-gap":
      if (value.trim().toLowerCase() === "normal") { out.push({ p: P.P_COLUMN_GAP, v: 0, u: P.U_NORMAL }); return null; }
      return single(prop, value, P.P_COLUMN_GAP, false, out, true);
    case "flex-grow":
    case "flex-shrink":
      {
      const n = Number(value);
      if (!Number.isFinite(n) || n < 0) return `'${prop}' must be a non-negative number`;
      out.push({ p: prop === "flex-grow" ? P.P_FLEX_GROW : P.P_FLEX_SHRINK, v: n, u: P.U_NONE });
      return null;
    }
    case "flex-basis":
      // The basis takes the intrinsic keywords and the fill-available one (CSS Flexbox 4.5).
      return single(prop, value, P.P_FLEX_BASIS, true, out, true, true);
    case "flex":
      {
      const parts = value.split(/\s+/);
      if (value === "none") {
        out.push({ p: P.P_FLEX_GROW, v: 0, u: 0 }, { p: P.P_FLEX_SHRINK, v: 0, u: 0 }, { p: P.P_FLEX_BASIS, v: 0, u: P.U_AUTO });
        return null;
      }
      if (value === "auto") {
        out.push({ p: P.P_FLEX_GROW, v: 1, u: 0 }, { p: P.P_FLEX_SHRINK, v: 1, u: 0 }, { p: P.P_FLEX_BASIS, v: 0, u: P.U_AUTO });
        return null;
      }
      // `flex: <grow> <shrink>? || <basis>`: the basis is optional and comes either side of the
      // two factors, and a factor left out is 1. A bare number fills the factor slots, in order;
      // a factor left out of `flex: <number>` is `0%`, not zero pixels (CSS Flexbox 7.1.1). A
      // third number, or a second basis, makes the declaration invalid.
      let grow = 1;
      let shrink = 1;
      let growSet = false;
      let shrinkSet = false;
      let basis: Len = { v: 0, u: P.U_PCT };
      let basisSet = false;
      for (const part of parts) {
        const l = parseLength(part, true, true);
        const numeric = /^[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$/.test(part);
        // A bare zero is a factor while a factor slot is free, and the basis `0` once both are
        // taken: the grammar reads it as a length only where no factor can go.
        if (numeric && !(growSet && shrinkSet && !basisSet && l !== null)) {
          const n = Number(part);
          // A negative factor, a third one, or a second basis is invalid CSS, which drops the
          // declaration; a token that is neither a number nor a length is a value this build
          // doesn't know and keeps its diagnostic.
          if (!(n >= 0)) return null;
          if (!growSet) { grow = n; growSet = true; }
          else if (!shrinkSet) { shrink = n; shrinkSet = true; }
          else return null;
        } else if (l !== null) {
          if (basisSet) return null;
          basis = l;
          basisSet = true;
        } else return `unsupported value '${value}' for 'flex'`;
      }
      out.push({ p: P.P_FLEX_GROW, v: grow, u: 0 }, { p: P.P_FLEX_SHRINK, v: shrink, u: 0 }, { p: P.P_FLEX_BASIS, v: basis.v, u: basis.u });
      return null;
    }
    default:
      return undefined;
  }
}
