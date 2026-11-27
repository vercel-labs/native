// CSS filters: `filter` and `backdrop-filter`. A value is `none`, or a space-separated list of
// filter functions, compiled into one row of eight numbers per function (see P_FILTER in
// shared/props.ts) and the declaration's value is that row's id in the filter table.
//
//   [kind, aV, aU, bV, bU, cV, cU, color]
//
// Blur has one length in a; the colour functions one number (a percentage written as a fraction)
// in a; hue-rotate its angle in radians in a; and drop-shadow three lengths (its offsets and
// blur) with its colour, -1 standing for currentColor.

import * as P from "../props.ts";
import { parseColor } from "./colors.ts";
import { parseLength } from "./declarations.ts";
import type { Len } from "./declarations.ts";
import { exprHasPercent } from "./length-exprs.ts";
import { splitValue } from "./fonts.ts";
import { parseAngle } from "./transforms.ts";
import type { Decl, FontContext } from "./types.ts";

/** The numbers each filter function takes in the row. */
export const FILTER_FIELDS = 8;

/** Splits a filter list on top-level whitespace: the arguments of a function stay together. */
function splitFunctions(text: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let cur = "";
  for (const ch of text) {
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    if (depth === 0 && (ch === " " || ch === "\t" || ch === "\n")) {
      if (cur !== "") out.push(cur);
      cur = "";
      continue;
    }
    cur += ch;
  }
  if (cur !== "") out.push(cur);
  return out;
}

/** A clamped `<number> | <percentage>`: the colour functions all take one. */
function numberArg(text: string): number | null {
  const t = text.trim().toLowerCase();
  const pct = t.endsWith("%");
  const body = pct ? t.slice(0, -1) : t;
  if (!/^[-+]?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?$/.test(body)) return null;
  const n = parseFloat(body);
  return pct ? n / 100 : n;
}

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

/** One group of the row with its fields filled in. */
function fields(kind: number, a: number, au: number, b: number = 0, bu: number = 0, c: number = 0,
  cu: number = 0, color: number = 0): number[] {
  return [kind, a, au, b, bu, c, cu, color];
}

/** A length inside blur(): a percentage has nothing to measure against. */
function blurLength(arg: string): Len | null {
  const l = parseLength(arg, false);
  if (l === null || l.u === P.U_PCT || (l.u === P.U_EXPR && exprHasPercent(l.v))) return null;
  return l;
}

/**
 * One filter function as its eight numbers, or a message. `colorFunctions` clamps the number to
 * the range CSS gives each one.
 */
function filterFunction(fn: string, prop: string): number[] | string {
  const m = /^([a-z-]+)\((.*)\)$/.exec(fn);
  if (m === null) return `invalid value '${fn}' for '${prop}': not a filter function`;
  const name = m[1];
  const arg = m[2].trim();
  switch (name) {
    case "blur": {
      if (arg === "") return fields(P.FK_BLUR, 0, P.U_PX);
      const l = blurLength(arg);
      if (l === null) return `invalid length '${arg}' in '${prop}: ${fn}'`;
      if (l.v < 0) return `invalid value '${fn}' for '${prop}': the blur can't be negative`;
      return fields(P.FK_BLUR, l.v, l.u);
    }
    case "brightness":
    case "contrast":
    case "saturate": {
      if (arg === "") return fields(kindOf(name), 1, P.U_NONE);
      const n = numberArg(arg);
      if (n === null) return `invalid value '${fn}' for '${prop}'`;
      return fields(kindOf(name), Math.max(0, n), P.U_NONE);
    }
    case "grayscale":
    case "invert":
    case "opacity":
    case "sepia": {
      if (arg === "") return fields(kindOf(name), 1, P.U_NONE);
      const n = numberArg(arg);
      if (n === null) return `invalid value '${fn}' for '${prop}'`;
      return fields(kindOf(name), clamp(n, 0, 1), P.U_NONE);
    }
    case "hue-rotate": {
      if (arg === "") return fields(P.FK_HUE_ROTATE, 0, P.U_NONE);
      const a = parseAngle(arg);
      if (a === null) return `invalid angle '${arg}' in '${prop}: ${fn}'`;
      return fields(P.FK_HUE_ROTATE, a, P.U_NONE);
    }
    case "drop-shadow": {
      // A shadow as text-shadow writes one: two or three lengths and a colour, in either order.
      const lens: Len[] = [];
      let color = -1;
      let hasColor = false;
      for (const part of splitValue(arg)) {
        if (!hasColor) {
          if (part.toLowerCase() === "currentcolor") {
            hasColor = true;
            continue;
          }
          const c = parseColor(part);
          if (c !== null) {
            hasColor = true;
            color = c;
            continue;
          }
        }
        const l = blurLength(part);
        if (l === null) return `unsupported length '${part}' in '${prop}: ${fn}'`;
        lens.push(l);
      }
      if (lens.length < 2) return `invalid value '${fn}' for '${prop}': a drop-shadow needs an offset in both directions`;
      if (lens.length > 3) return `invalid value '${fn}' for '${prop}': too many lengths`;
      if (lens.length === 3 && lens[2].v < 0) return `invalid value '${fn}' for '${prop}': the blur can't be negative`;
      return fields(P.FK_DROP_SHADOW, lens[0].v, lens[0].u, lens[1].v, lens[1].u,
        lens.length === 3 ? lens[2].v : 0, lens.length === 3 ? lens[2].u : P.U_PX, color);
    }
    default:
      return `unsupported filter function '${name}()' in '${prop}'`;
  }
}

function kindOf(name: string): number {
  switch (name) {
    case "brightness": return P.FK_BRIGHTNESS;
    case "contrast": return P.FK_CONTRAST;
    case "grayscale": return P.FK_GRAYSCALE;
    case "invert": return P.FK_INVERT;
    case "opacity": return P.FK_OPACITY;
    case "saturate": return P.FK_SATURATE;
    default: return P.FK_SEPIA;
  }
}

/**
 * `filter` and `backdrop-filter`: `none`, or the filter functions in order. Later functions in
 * the list apply to the output of earlier ones.
 */
export function filterList(prop: string, value: string, out: Decl[], p: number, fonts?: FontContext): string | null {
  const text = value.trim();
  if (text.toLowerCase() === "none") {
    out.push({ p, v: -1, u: P.U_NONE });
    return null;
  }
  if (text === "") return `invalid value '${value}' for '${prop}'`;
  const row: number[] = [];
  let note: string | null = null;
  for (const fn of splitFunctions(text)) {
    // A reference filter keeps its id: an id is case-sensitive, unlike a function's name.
    const ref = /^url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)$/i.exec(fn);
    if (ref !== null) {
      const url = (ref[1] ?? ref[2] ?? ref[3] ?? "").trim();
      if (!url.startsWith("#") || url.length < 2) return `unsupported filter reference '${fn}' in '${prop}'`;
      if (prop === "backdrop-filter") return `unsupported filter function 'url()' in '${prop}'`;
      if (fonts === undefined) {
        out.push({ p, v: -1, u: P.U_NONE });
        return null;
      }
      row.push(...fields(P.FK_URL, fonts.paint(url.slice(1)), P.U_NONE));
      // The SVG painter runs the chain; a reference filter on an HTML box is not drawn yet.
      if (note === null) note = "note: filter: url() renders on an element inside an inline <svg>; an HTML box ignores it for now";
      continue;
    }
    // Lower-casing the whole function would break a colour keyword's case only in ways CSS
    // ignores, and filter function names are case-insensitive: parse the lower-cased text.
    const f = filterFunction(fn.toLowerCase(), prop);
    if (typeof f === "string") return f;
    for (const n of f) row.push(n);
  }
  if (row.length === 0) return `invalid value '${value}' for '${prop}'`;
  if (fonts === undefined) {
    out.push({ p, v: -1, u: P.U_NONE });
    return null;
  }
  out.push({ p, v: fonts.filter(row), u: P.U_LIST });
  return note;
}
