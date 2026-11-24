// list-style properties and the marker text they produce.

import * as P from "../props.ts";
import { kw } from "./declarations.ts";
import type { ContentContext, Decl, FontContext, Loc } from "./types.ts";

/** Every counter style by id, so a counter() and a list-style-type name the same one. */
export const COUNTER_STYLE_NAMES: string[] = [
  "disc", "circle", "square", "decimal", "decimal-leading-zero", "lower-alpha",
  "upper-alpha", "lower-roman", "upper-roman", "none",
];

/** The id of a counter style's name, or -1 when the style isn't one native draws. */
export function counterStyleId(name: string): number {
  const lower = name.toLowerCase();
  // The two Latin aliases name the alphabetic styles the table calls alpha.
  if (lower === "lower-latin") return P.LST_LOWER_ALPHA;
  if (lower === "upper-latin") return P.LST_UPPER_ALPHA;
  return COUNTER_STYLE_NAMES.indexOf(lower);
}

/** The name of a counter style by id, for serializing a counter() that names one. */
export function counterStyleName(id: number): string {
  return id >= 0 && id < COUNTER_STYLE_NAMES.length ? COUNTER_STYLE_NAMES[id] : "decimal";
}

const TYPES: Record<string, number> = {
  disc: P.LST_DISC,
  circle: P.LST_CIRCLE,
  square: P.LST_SQUARE,
  decimal: P.LST_DECIMAL,
  "decimal-leading-zero": P.LST_DECIMAL_LEADING_ZERO,
  "lower-alpha": P.LST_LOWER_ALPHA,
  "lower-latin": P.LST_LOWER_ALPHA,
  "upper-alpha": P.LST_UPPER_ALPHA,
  "upper-latin": P.LST_UPPER_ALPHA,
  "lower-roman": P.LST_LOWER_ROMAN,
  "upper-roman": P.LST_UPPER_ROMAN,
  none: P.LST_NONE,
};

/** Bijective base-26 letters: 1 → a, 26 → z, 27 → aa. */
function alpha(n: number, upper: boolean): string {
  if (n <= 0) return String(n);
  let s = "";
  while (n > 0) {
    const r = (n - 1) % 26;
    s = String.fromCharCode((upper ? 65 : 97) + r) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

const ROMAN: [number, string][] = [
  [1000, "M"], [900, "CM"], [500, "D"], [400, "CD"], [100, "C"], [90, "XC"], [50, "L"],
  [40, "XL"], [10, "X"], [9, "IX"], [5, "V"], [4, "IV"], [1, "I"],
];

/** Roman numerals, upper or lower; a number outside 1-3999 falls back to decimal. */
function roman(n: number, upper: boolean): string {
  if (n <= 0 || n > 3999) return String(n);
  let s = "";
  for (const [v, c] of ROMAN) {
    while (n >= v) {
      s += c;
      n -= v;
    }
  }
  return upper ? s : s.toLowerCase();
}

/** The text a counter with the given style has at value `n` (CSS Counter Styles §2). */
export function counterText(style: number, n: number): string {
  switch (style) {
    case P.LST_DISC: return "•";
    case P.LST_CIRCLE: return "◦";
    case P.LST_SQUARE: return "▪";
    case P.LST_DECIMAL: return String(n);
    case P.LST_DECIMAL_LEADING_ZERO: return (n >= 0 && n < 10 ? "0" : "") + n;
    case P.LST_LOWER_ALPHA: return alpha(n, false);
    case P.LST_UPPER_ALPHA: return alpha(n, true);
    case P.LST_LOWER_ROMAN: return roman(n, false);
    case P.LST_UPPER_ROMAN: return roman(n, true);
    default: return "";
  }
}

/**
 * The text a marker shows for an item of the given list-style-type at the given ordinal: the
 * counter's text, and for the numeric styles the period a browser's default `::marker` content
 * (`counter(list-item) ". "`) adds. `none` produces nothing, and the marker box is hidden.
 */
export function markerText(type: number, n: number): string {
  const t = counterText(type, n);
  if (t === "") return "";
  if (type === P.LST_DISC || type === P.LST_CIRCLE || type === P.LST_SQUARE) return t;
  return t + ".";
}

/** A counter style's name, as an identifier, or null when the value isn't one. */
export function readCounterStyleName(text: string): string | null {
  const t = text.trim();
  return /^-?[_a-zA-Z\u0080-\uffff][-_a-zA-Z0-9\u0080-\uffff]*$/.test(t) ? t.toLowerCase() : null;
}

/** A counter a counter-reset/-increment/-set declaration names. */
export interface ParsedCounter {
  name: string;
  value: number;
  /** `reversed(name)`: the counter counts down, and without a value its start is computed. */
  reversed?: boolean;
  /** The reversed counter named no value, so its initial value comes from its scope. */
  auto?: boolean;
}

/** The name and value of each counter in an encoded list (see `listStyleProperty`). */
export function parseCounterList(encoded: string): ParsedCounter[] {
  const out: ParsedCounter[] = [];
  for (const item of encoded.split(";")) {
    if (item === "") continue;
    if (item.startsWith("reversed(")) {
      // `reversed(name)` has no initial value yet; `reversed(name)=10` names one.
      const close = item.indexOf(")");
      if (close > 0) {
        const name = item.slice("reversed(".length, close);
        const rest = item.slice(close + 1);
        const eq = rest.lastIndexOf("=");
        const value = eq < 0 ? 0 : parseInt(rest.slice(eq + 1), 10);
        out.push({ name, value: Number.isNaN(value) ? 0 : value, reversed: true, auto: eq < 0 });
        continue;
      }
    }
    const eq = item.lastIndexOf("=");
    const name = eq < 0 ? item : item.slice(0, eq);
    const value = eq < 0 ? 0 : parseInt(item.slice(eq + 1), 10);
    out.push({ name, value: Number.isNaN(value) ? 0 : value });
  }
  return out;
}

export function listStyleProperty(prop: string, value: string, out: Decl[], _fonts?: FontContext, _loc?: Loc,
  content?: ContentContext): string | null | undefined {
  switch (prop) {
    case "counter-reset":
    case "counter-increment":
    case "counter-set": {
      const p = prop === "counter-reset" ? P.P_COUNTER_RESET
        : prop === "counter-increment" ? P.P_COUNTER_INCREMENT : P.P_COUNTER_SET;
      // The value a name without a number takes: resets and sets start at 0, increments by 1.
      const base = prop === "counter-increment" ? 1 : 0;
      const text = value.trim();
      if (text.toLowerCase() === "none") {
        out.push({ p, v: -1, u: P.U_NONE });
        return null;
      }
      const parts = text.split(/\s+/);
      const items: string[] = [];
      for (let i = 0; i < parts.length; i++) {
        let name = parts[i];
        // `reversed(name)` marks the counter as counting down; only a reset may do that, and
        // without a value its initial value is worked out from the increments in its scope.
        let reversed = false;
        const rev = /^reversed\(\s*([-_a-zA-Z\u0080-￿][-_a-zA-Z0-9\u0080-￿]*)\s*\)$/i.exec(name);
        if (rev !== null) {
          if (prop !== "counter-reset") return `'${rev[0]}' is not a '${prop}' value`;
          reversed = true;
          name = rev[1];
        }
        if (!/^-?[_a-zA-Z\u0080-￿][-_a-zA-Z0-9\u0080-￿]*$/.test(name)) {
          return `invalid counter name '${name}' in '${prop}'`;
        }
        let v = base;
        let explicit = false;
        const next = parts[i + 1];
        if (next !== undefined && /^[-+]?\d+$/.test(next)) {
          v = parseInt(next, 10);
          explicit = true;
          i++;
        }
        items.push(reversed ? (explicit ? `reversed(${name})=${v}` : `reversed(${name})`) : `${name}=${v}`);
      }
      if (items.length === 0) return `invalid value '${value}' for '${prop}'`;
      if (content === undefined || content.counter === undefined) {
        return `'${prop}' isn't supported here`;
      }
      out.push({ p, v: content.counter(items.join(";")), u: P.U_NONE });
      return null;
    }
    case "list-style-type": {
      const lower = value.toLowerCase();
      const v = TYPES[lower];
      if (v !== undefined) {
        out.push({ p: P.P_LIST_STYLE_TYPE, v, u: P.U_NONE });
        return null;
      }
      // A name an @counter-style rule defines is stored as -2 - its index in the style names.
      const styleName = readCounterStyleName(value);
      if (styleName !== null && content !== undefined && content.counterStyle !== undefined) {
        out.push({ p: P.P_LIST_STYLE_TYPE, v: -2 - content.counterStyle(styleName), u: P.U_NONE });
        return null;
      }
      return `unsupported value '${value}' for 'list-style-type'`;
    }
    case "list-style-position":
      return kw(prop, value, { outside: P.LSP_OUTSIDE, inside: P.LSP_INSIDE }, P.P_LIST_STYLE_POSITION, out);
    case "list-style-image":
      if (value.toLowerCase() === "none") {
        out.push({ p: P.P_LIST_STYLE_IMAGE, v: 0, u: P.U_AUTO });
        return null;
      }
      return `'list-style-image' isn't supported yet; the marker uses the list-style-type`;
    case "list-style": {
      // The shorthand resets every longhand, whatever order its parts come in.
      out.push(
        { p: P.P_LIST_STYLE_TYPE, v: P.LST_DISC, u: P.U_NONE },
        { p: P.P_LIST_STYLE_POSITION, v: P.LSP_OUTSIDE, u: P.U_NONE },
        { p: P.P_LIST_STYLE_IMAGE, v: 0, u: P.U_AUTO },
      );
      let sawType = false;
      for (const part of value.split(/\s+/)) {
        const lower = part.toLowerCase();
        if (lower === "inside" || lower === "outside") {
          out.push({ p: P.P_LIST_STYLE_POSITION, v: lower === "inside" ? P.LSP_INSIDE : P.LSP_OUTSIDE, u: P.U_NONE });
          continue;
        }
        if (lower === "none") {
          // As in a browser, `none` turns off both the type and the image.
          if (!sawType) out.push({ p: P.P_LIST_STYLE_TYPE, v: P.LST_NONE, u: P.U_NONE });
          sawType = true;
          continue;
        }
        if (/^url\(/i.test(part)) return `'list-style-image' isn't supported yet; the marker uses the list-style-type`;
        const v = TYPES[lower];
        if (v !== undefined) {
          sawType = true;
          out.push({ p: P.P_LIST_STYLE_TYPE, v, u: P.U_NONE });
          continue;
        }
        // A shorthand takes a <counter-style-name> wherever the longhand does.
        const styleName = readCounterStyleName(part);
        if (styleName !== null && content !== undefined && content.counterStyle !== undefined) {
          sawType = true;
          out.push({ p: P.P_LIST_STYLE_TYPE, v: -2 - content.counterStyle(styleName), u: P.U_NONE });
          continue;
        }
        return `unsupported value '${value}' for 'list-style'`;
      }
      return null;
    }
    default:
      return undefined;
  }
}
