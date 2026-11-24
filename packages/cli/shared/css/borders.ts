// Border properties and shorthands.

import * as P from "../props.ts";
import { parseColor } from "./colors.ts";
import { parseLength } from "./declarations.ts";
import { exprHasPercent } from "./length-exprs.ts";
import type { Len } from "./declarations.ts";
import { splitValue } from "./fonts.ts";
import type { Decl } from "./types.ts";

// Each border side's width and color property, in CSS's top, right, bottom, left order.
export const BORDER_SIDES: number[][] = [
  [P.P_BORDER_TOP_WIDTH, P.P_BORDER_TOP_COLOR],
  [P.P_BORDER_RIGHT_WIDTH, P.P_BORDER_RIGHT_COLOR],
  [P.P_BORDER_BOTTOM_WIDTH, P.P_BORDER_BOTTOM_COLOR],
  [P.P_BORDER_LEFT_WIDTH, P.P_BORDER_LEFT_COLOR],
];

export const BORDER_WIDTHS = BORDER_SIDES.map((side) => side[0]);

export const BORDER_COLORS = BORDER_SIDES.map((side) => side[1]);

// In BRS_* order: a style's id is its index here.
export const BORDER_STYLES = ["none", "hidden", "solid", "dotted", "dashed", "double", "groove", "ridge", "inset", "outset"];

// Each corner's horizontal and vertical radius property, in CSS's corner order: top-left,
// top-right, bottom-right, bottom-left.
export const BORDER_RADIUS_X = [P.P_BORDER_TOP_LEFT_RADIUS, P.P_BORDER_TOP_RIGHT_RADIUS, P.P_BORDER_BOTTOM_RIGHT_RADIUS, P.P_BORDER_BOTTOM_LEFT_RADIUS];

export const BORDER_RADIUS_Y = [P.P_BORDER_TOP_LEFT_RADIUS_Y, P.P_BORDER_TOP_RIGHT_RADIUS_Y, P.P_BORDER_BOTTOM_RIGHT_RADIUS_Y, P.P_BORDER_BOTTOM_LEFT_RADIUS_Y];

export const BORDER_STYLE_IDS = [P.P_BORDER_TOP_STYLE, P.P_BORDER_RIGHT_STYLE, P.P_BORDER_BOTTOM_STYLE, P.P_BORDER_LEFT_STYLE];

/** The style id of each of the given sides, which are [width, color] property pairs. */
function styleIdsFor(sides: number[][]): number[] {
  const out: number[] = [];
  for (const side of sides) {
    for (let k = 0; k < BORDER_WIDTHS.length; k++) {
      if (BORDER_WIDTHS[k] === side[0]) out.push(BORDER_STYLE_IDS[k]);
    }
  }
  return out;
}

/** The BRS_* id of a border style keyword, or -1 if it isn't one. */
export function parseBorderStyle(s: string): number {
  return BORDER_STYLES.indexOf(s.trim().toLowerCase());
}

/** A border width: a length, or one of the three width keywords. Null if it isn't one. */
export function parseBorderWidth(s: string): Len | null {
  s = s.trim().toLowerCase();
  if (s === "thin") return { v: 1, u: P.U_PX };
  if (s === "medium") return { v: 3, u: P.U_PX };
  if (s === "thick") return { v: 5, u: P.U_PX };
  const l = parseLength(s, false);
  return l !== null && l.u !== P.U_PCT && !(l.u === P.U_EXPR && exprHasPercent(l.v)) ? l : null;
}

/** A border color, with `currentColor` as the -1 sentinel the runtime understands. */
export function parseBorderColor(s: string): number | null {
  return s.trim().toLowerCase() === "currentcolor" ? -1 : parseColor(s);
}

export function borderWidth(prop: string, value: string, p: number, out: Decl[]): string | null {
  const l = parseBorderWidth(value);
  if (l === null) return `unsupported border width '${value}' for '${prop}'`;
  if (l.v < 0) return `invalid value '${value}' for '${prop}': it can't be negative, so the declaration is ignored`;
  out.push({ p, v: l.v, u: l.u });
  return null;
}

export function borderColor(prop: string, value: string, p: number, out: Decl[]): string | null {
  const c = parseBorderColor(value);
  if (c === null) return `unsupported border color '${value}' for '${prop}'`;
  out.push({ p, v: c, u: P.U_NONE });
  return null;
}

/** Expands CSS's one to four side values (top, right, bottom, left). */
function fourSides<T>(parts: T[]): T[] {
  const [t, r = t, b = t, l = r] = parts;
  return [t, r, b, l];
}

export function borderWidths(prop: string, value: string, props: number[], out: Decl[]): string | null {
  const parts = splitValue(value);
  if (parts.length < 1 || parts.length > 4) return `'${prop}' takes 1 to 4 values`;
  const ls: Len[] = [];
  for (const part of parts) {
    const l = parseBorderWidth(part);
    if (l === null) return `unsupported border width '${part}' for '${prop}'`;
    if (l.v < 0) return `invalid value '${part}' for '${prop}': it can't be negative, so the declaration is ignored`;
    ls.push(l);
  }
  const sides = fourSides(ls);
  for (let k = 0; k < sides.length; k++) out.push({ p: props[k], v: sides[k].v, u: sides[k].u });
  return null;
}

export function borderColors(prop: string, value: string, props: number[], out: Decl[]): string | null {
  const parts = splitValue(value);
  if (parts.length < 1 || parts.length > 4) return `'${prop}' takes 1 to 4 values`;
  const cs: number[] = [];
  for (const part of parts) {
    const c = parseBorderColor(part);
    if (c === null) return `unsupported border color '${part}' for '${prop}'`;
    cs.push(c);
  }
  const sides = fourSides(cs);
  for (let k = 0; k < sides.length; k++) out.push({ p: props[k], v: sides[k], u: P.U_NONE });
  return null;
}

/** One to four corner radii, as a slash-separated `border-radius` component list holds them. */
function radiusValues(prop: string, text: string): Len[] | string {
  const parts = splitValue(text);
  if (parts.length < 1 || parts.length > 4) return `'${prop}' takes 1 to 4 values`;
  const ls: Len[] = [];
  for (const part of parts) {
    const l = parseLength(part, false);
    if (l === null) return `unsupported length '${part}' for '${prop}'`;
    if (l.v < 0) return `invalid value '${part}' for '${prop}': it can't be negative, so the declaration is ignored`;
    ls.push(l);
  }
  return ls;
}

/**
 * `border-top-left-radius` and its peers: the corner's horizontal radius, then its vertical
 * one, which an omitted value repeats. Percentages resolve against the box's width and height.
 */
export function cornerRadius(prop: string, value: string, props: number[], out: Decl[]): string | null {
  const parts = splitValue(value);
  if (parts.length < 1 || parts.length > 2) return `'${prop}' takes 1 or 2 values`;
  const ls: Len[] = [];
  for (const part of parts) {
    const l = parseLength(part, false);
    if (l === null) return `unsupported length '${part}' for '${prop}'`;
    if (l.v < 0) return `invalid value '${part}' for '${prop}': it can't be negative, so the declaration is ignored`;
    ls.push(l);
  }
  const y = ls.length > 1 ? ls[1] : ls[0];
  out.push({ p: props[0], v: ls[0].v, u: ls[0].u });
  out.push({ p: props[1], v: y.v, u: y.u });
  return null;
}

/**
 * `border-radius`: one to four values for the four corners, or two slash-separated lists for
 * their horizontal and vertical radii.
 */
export function borderRadiusShorthand(prop: string, value: string, xs: number[], ys: number[], out: Decl[]): string | null {
  const slash = value.split("/");
  if (slash.length > 2) return `'${prop}' takes at most one '/'`;
  const h = radiusValues(prop, slash[0]);
  if (typeof h === "string") return h;
  const v = slash.length > 1 ? radiusValues(prop, slash[1]) : h;
  if (typeof v === "string") return v;
  const hx = fourSides(h);
  const vy = fourSides(v);
  for (let k = 0; k < 4; k++) {
    out.push({ p: xs[k], v: hx[k].v, u: hx[k].u });
    out.push({ p: ys[k], v: vy[k].v, u: vy[k].u });
  }
  return null;
}

export function borderStyles(prop: string, value: string, styleProps: number[], out: Decl[]): string | null {
  const parts = splitValue(value);
  if (parts.length < 1 || parts.length > 4) return `'${prop}' takes 1 to 4 values`;
  const styles: number[] = [];
  for (const part of parts) {
    const st = parseBorderStyle(part);
    if (st < 0) return `unsupported border style '${part}' for '${prop}'`;
    styles.push(st);
  }
  const sides = fourSides(styles);
  // A longhand (border-top-style) takes the first side; the shorthand sets all four.
  for (let k = 0; k < styleProps.length && k < sides.length; k++) out.push({ p: styleProps[k], v: sides[k], u: P.U_NONE });
  return null;
}

/** `border`, `border-top`, …: width, style and color for one or all sides. */
export function borderShorthand(prop: string, value: string, sides: number[][], out: Decl[]): string | null {
  let width: Len | null = null;
  let color: number | null = null;
  let style = -1;
  for (const part of splitValue(value)) {
    const l = parseBorderWidth(part);
    if (l !== null) {
      if (l.v < 0) return `invalid value '${value}' for '${prop}': a border width can't be negative`;
      width = l;
      continue;
    }
    const st = parseBorderStyle(part);
    if (st >= 0) { style = st; continue; }
    const c = parseBorderColor(part);
    if (c !== null) { color = c; continue; }
    return `unsupported border value '${part}' for '${prop}'`;
  }
  // The shorthand resets what it doesn't set: an omitted style is `none`, an omitted color is
  // currentColor, and an omitted width is medium. The width is kept even when the style comes out
  // none: a later `border-style` brings it back, so only the used width is zero (see
  // computeStyles in runtime/style.ts).
  const st = style < 0 ? P.BRS_NONE : style;
  const w = width ?? { v: 3, u: P.U_PX };
  const styleIds = styleIdsFor(sides);
  for (let k = 0; k < sides.length; k++) {
    const side = sides[k];
    // A side may name its style id itself: a logical side's isn't next to its width in the table.
    out.push({ p: side[0], v: w.v, u: w.u });
    out.push({ p: side[1], v: color === null ? -1 : color, u: P.U_NONE });
    out.push({ p: side.length > 2 ? side[2] : styleIds[k], v: st, u: P.U_NONE });
  }
  return null;
}
