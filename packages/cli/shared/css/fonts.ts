// Font properties and the font shorthand, shared by the compiler and the runtime.

import * as P from "../props.ts";
import { calcNumber, parseLength } from "./declarations.ts";
import { exprHasPercent } from "./length-exprs.ts";
import type { Len } from "./declarations.ts";
import { GENERIC_FAMILIES, genericFamily } from "./types.ts";
import type { Decl, FontContext } from "./types.ts";

const FONT_SIZE_KEYWORDS: Record<string, number> = { small: 13, large: 18, "x-large": 24, "xx-large": 32 };

/** A font-size token: a length, a percentage (of the inherited size) or a size keyword. */
export function sizeLen(s: string): Len | null {
  // `medium` is a size the font family decides (see P_FIXED_FONT), so it is resolved at style time.
  if (s === "medium") return { v: 0, u: P.U_MEDIUM };
  const named = FONT_SIZE_KEYWORDS[s];
  if (named !== undefined) return { v: named, u: P.U_PX };
  // A relative keyword, resolved against the parent's size at style time.
  if (s === "smaller" || s === "larger") return { v: 0, u: s === "smaller" ? P.U_SMALLER : P.U_LARGER };
  const l = parseLength(s, false);
  if (!l || l.u === P.U_VW || l.u === P.U_VH) return null;
  // A font-size in lh would rest on the line height this very size decides.
  if (l.u === P.U_LH) return null;
  if (l.u === P.U_PCT) return { v: l.v / 100, u: P.U_EM };
  // A calc() that mixes units stays an expression; the runtime resolves its percentages
  // against the parent's size, where every length-percentage in font-size resolves.
  return l;
}

/** One family in a font-family list: its name, and whether CSS gave it as a quoted string. */
export interface FamilyItem {
  name: string;
  // A quoted name is a family name whatever it spells: `"fantasy"` is not the fantasy keyword.
  quoted: boolean;
}

/** Splits a font-family list on commas outside quotes, lowercasing and unquoting each name. */
export function splitFamilyItems(value: string): FamilyItem[] {
  const out: FamilyItem[] = [];
  let cur = "", quote = "", quoted = false, first = true;
  for (const ch of value) {
    if (quote !== "") {
      if (ch === quote) quote = "";
      else cur += ch;
      continue;
    }
    if (ch === '"' || ch === "'") {
      if (first) quoted = true;
      first = false;
      quote = ch;
      continue;
    }
    if (ch === ",") {
      if (cur.trim() !== "") out.push({ name: cur, quoted });
      cur = "";
      quoted = false;
      first = true;
      continue;
    }
    if (ch !== " " && ch !== "\t" && ch !== "\n") first = false;
    cur += ch;
  }
  if (cur.trim() !== "") out.push({ name: cur, quoted });
  return out.map((f) => ({ name: f.name.replace(/\s+/g, " ").trim().toLowerCase(), quoted: f.quoted }));
}

/** Splits a font-family list on commas outside quotes, lowercasing and unquoting each name. */
export function splitFamilies(value: string): string[] {
  return splitFamilyItems(value).map((f) => f.name);
}

/** The first family in a font-family list, the one whose font would be used. */
export function firstFamily(value: string): string | null {
  const list = splitFamilies(value);
  return list.length > 0 ? list[0] : null;
}

/**
 * The family a font-family list uses: CSS walks the list in order and takes the first family that
 * exists, so a missing font falls through to the next rather than straight to the system font.
 */
export function usableFamily(value: string, fonts?: FontContext): string | null {
  const list = splitFamilies(value);
  if (list.length === 0) return null;
  if (fonts !== undefined) {
    for (const name of list) if (fonts.available(name)) return name;
  }
  return list[0];
}

/**
 * True when a font-family value is just the generic `monospace`. Browsers give that one family a
 * smaller `medium` size (13px rather than 16px), and only the bare keyword gets it: a list around
 * it, or a named fixed-pitch font, keeps the usual size.
 */
function fixedFamily(value: string): boolean {
  return value.trim().toLowerCase() === "monospace";
}

/**
 * The families a list names, in order, as their ids. A family the build has no face for may still
 * be one the system has, so it keeps its place: the host falls back at draw time.
 */
function familyIds(value: string, fonts?: FontContext): number[] {
  const out: number[] = [];
  for (const item of splitFamilyItems(value)) {
    if (fonts) out.push(fonts.family(item.name, item.quoted));
    else out.push(item.quoted ? P.FF_SYSTEM : (genericFamily(item.name) ?? P.FF_SYSTEM));
  }
  return out;
}

/** The family-list row for a list's ids: an index into FONT_FAMILY_LISTS (stored + 1), or 0. */
function familyListDecl(ids: number[], out: Decl[], fonts?: FontContext): void {
  if (ids.length > 1 && fonts !== undefined && fonts.familyList !== undefined) {
    out.push({ p: P.P_FONT_FAMILY_LIST, v: fonts.familyList(ids) + 1, u: P.U_NONE });
  } else {
    out.push({ p: P.P_FONT_FAMILY_LIST, v: 0, u: P.U_NONE });
  }
}

export function familyDecl(prop: string, value: string, out: Decl[], fonts?: FontContext): string | null {
  const ids = familyIds(value, fonts);
  if (ids.length === 0) return `font-family '${value}' has no family name`;
  // An unavailable family falls back to the system font, as a browser would.
  out.push({ p: P.P_FONT_FAMILY, v: ids[0], u: P.U_NONE });
  familyListDecl(ids, out, fonts);
  out.push({ p: P.P_FIXED_FONT, v: fixedFamily(value) ? 1 : 0, u: P.U_NONE });
  return null;
}

/**
 * The `font` shorthand: style, weight and variant keywords, then size[/line-height], then the
 * family list. It sets all five longhands, as the shorthand does.
 */
// The keyword percentages the font shorthand takes for a font-stretch.
const SHORTHAND_STRETCH: Record<string, number> = {
  "ultra-condensed": 50, "extra-condensed": 62.5, condensed: 75, "semi-condensed": 87.5,
  normal: 100, "semi-expanded": 112.5, expanded: 125, "extra-expanded": 150, "ultra-expanded": 200,
};

export function fontShorthand(value: string, out: Decl[], fonts?: FontContext): string | null {
  const parts = splitValue(value);
  let sizeAt = -1;
  let size: Len | null = null;
  let lineHeight: Len | null = null;
  for (let i = 0; i < parts.length; i++) {
    const slash = parts[i].indexOf("/");
    if (slash >= 0) {
      const sz = sizeLen(parts[i].slice(0, slash).toLowerCase());
      if (!sz) continue;
      const lhText = parts[i].slice(slash + 1).toLowerCase();
      const lhNum = /^\d*\.?\d+$/.test(lhText) ? Number(lhText) : calcNumber(lhText);
      const lh: Len | null = lhText === "normal" ? { v: 0, u: P.U_NORMAL }
        : lhNum !== null ? { v: lhNum, u: P.U_NONE }
        : parseLength(lhText, false);
      if (!lh || lh.u === P.U_VW || lh.u === P.U_VH || lh.u === P.U_AUTO ||
        (lh.u === P.U_EXPR && exprHasPercent(lh.v))) return `unsupported line-height '${lhText}' in font shorthand`;
      size = sz; lineHeight = lh; sizeAt = i; break;
    }
    const sz = sizeLen(parts[i].toLowerCase());
    if (sz) { size = sz; sizeAt = i; break; }
  }
  if (size === null || sizeAt < 0) {
    if (/^(caption|icon|menu|message-box|small-caption|status-bar)$/i.test(value.trim())) {
      return `the system font '${value.trim()}' isn't supported yet`;
    }
    return `unsupported font '${value}' (a font-size is required)`;
  }
  let italic = false, weight = 400, weightUnit = P.U_NONE;
  let stretch = 100;
  for (let i = 0; i < sizeAt; i++) {
    const t = parts[i].toLowerCase();
    if (t === "normal") continue;
    const st = SHORTHAND_STRETCH[t];
    if (st !== undefined) { stretch = st; continue; }
    if (t === "italic" || t === "oblique") { italic = true; continue; }
    if (t === "small-caps") return `font-variant: small-caps isn't supported yet`;
    if (t === "bold") { weight = 700; weightUnit = P.U_NONE; continue; }
    if (t === "bolder" || t === "lighter") {
      weight = 0;
      weightUnit = t === "bolder" ? P.U_BOLDER : P.U_LIGHTER;
      continue;
    }
    const n = Number(t);
    if (Number.isFinite(n) && n >= 100 && n <= 900) { weight = n; weightUnit = P.U_NONE; continue; }
    return `unsupported font value '${parts[i]}'`;
  }
  const rest = parts.slice(sizeAt + 1).join(" ");
  const ids = familyIds(rest, fonts);
  if (ids.length === 0) return `unsupported font '${value}' (a font-family is required)`;
  out.push({ p: P.P_FONT_STYLE, v: italic ? P.FS_ITALIC : P.FS_NORMAL, u: P.U_NONE });
  out.push({ p: P.P_FONT_WEIGHT, v: weight, u: weightUnit });
  out.push({ p: P.P_FONT_SIZE, v: size.v, u: size.u });
  out.push({ p: P.P_FONT_STRETCH, v: stretch, u: P.U_NONE });
  // The shorthand resets line-height to normal when it doesn't give one.
  out.push({ p: P.P_LINE_HEIGHT, v: lineHeight ? lineHeight.v : 0, u: lineHeight ? lineHeight.u : P.U_NORMAL });
  out.push({ p: P.P_FONT_FAMILY, v: ids[0], u: P.U_NONE });
  familyListDecl(ids, out, fonts);
  out.push({ p: P.P_FIXED_FONT, v: fixedFamily(rest) ? 1 : 0, u: P.U_NONE });
  return null;
}

export function splitValue(value: string): string[] {
  // Split on whitespace outside parentheses: "1px solid rgb(0, 0, 0)". A function token ends at
  // its closing parenthesis even when the next token touches it: Tailwind's ring shadow writes
  // "calc(1px + var(--ring))#color", and the calc and the color are two tokens.
  const parts: string[] = [];
  let depth = 0, cur = "";
  for (const ch of value.trim()) {
    if (ch === "(") {
      depth++;
      cur += ch;
      continue;
    }
    if (ch === ")") {
      depth--;
      cur += ch;
      if (depth === 0) {
        parts.push(cur);
        cur = "";
      }
      continue;
    }
    if (/\s/.test(ch) && depth === 0) {
      if (cur) parts.push(cur);
      cur = "";
    } else cur += ch;
  }
  if (cur) parts.push(cur);
  return parts;
}
