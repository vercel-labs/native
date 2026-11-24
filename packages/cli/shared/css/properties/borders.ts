// CSS border properties (helpers in ../borders.ts). Returns undefined for a property this module doesn't handle.

import * as P from "../../props.ts";
import { BORDER_COLORS, BORDER_RADIUS_X, BORDER_RADIUS_Y, BORDER_SIDES, BORDER_STYLE_IDS, BORDER_STYLES, BORDER_WIDTHS, borderColor, borderColors, borderRadiusShorthand, borderShorthand, borderStyles, borderWidth, borderWidths, cornerRadius, parseBorderColor, parseBorderStyle, parseBorderWidth } from "../borders.ts";
import { parseColor } from "../colors.ts";
import { colorDecl, kw, lengths, parseLength } from "../declarations.ts";
import type { Len } from "../declarations.ts";
import { splitValue } from "../fonts.ts";
import { gradientImage } from "../gradients.ts";
import { exprHasPercent } from "../length-exprs.ts";
import type { Decl, FontContext, Loc } from "../types.ts";

// A logical border side's width, colour and style ids, in the order borderShorthand reads them.
const BLOCK_START_SIDE = [P.P_BORDER_BLOCK_START_WIDTH, P.P_BORDER_BLOCK_START_COLOR, P.P_BORDER_BLOCK_START_STYLE];
const BLOCK_END_SIDE = [P.P_BORDER_BLOCK_END_WIDTH, P.P_BORDER_BLOCK_END_COLOR, P.P_BORDER_BLOCK_END_STYLE];
const INLINE_START_SIDE = [P.P_BORDER_INLINE_START_WIDTH, P.P_BORDER_INLINE_START_COLOR, P.P_BORDER_INLINE_START_STYLE];
const INLINE_END_SIDE = [P.P_BORDER_INLINE_END_WIDTH, P.P_BORDER_INLINE_END_COLOR, P.P_BORDER_INLINE_END_STYLE];

export function bordersProperty(prop: string, value: string, out: Decl[], fonts?: FontContext,
  loc?: Loc): string | null | undefined {
  switch (prop) {
    case "border":
      return borderShorthand(prop, value, BORDER_SIDES, out);
    case "border-top":
      return borderShorthand(prop, value, [BORDER_SIDES[0]], out);
    case "border-right":
      return borderShorthand(prop, value, [BORDER_SIDES[1]], out);
    case "border-bottom":
      return borderShorthand(prop, value, [BORDER_SIDES[2]], out);
    case "border-left":
      return borderShorthand(prop, value, [BORDER_SIDES[3]], out);
    case "border-width":
      return borderWidths(prop, value, BORDER_WIDTHS, out);
    case "border-color":
      return borderColors(prop, value, BORDER_COLORS, out);
    case "border-style":
      return borderStyles(prop, value, BORDER_STYLE_IDS, out);
    case "border-top-width":
      return borderWidth(prop, value, P.P_BORDER_TOP_WIDTH, out);
    case "border-right-width":
      return borderWidth(prop, value, P.P_BORDER_RIGHT_WIDTH, out);
    case "border-bottom-width":
      return borderWidth(prop, value, P.P_BORDER_BOTTOM_WIDTH, out);
    case "border-left-width":
      return borderWidth(prop, value, P.P_BORDER_LEFT_WIDTH, out);
    case "border-top-color":
      return borderColor(prop, value, P.P_BORDER_TOP_COLOR, out);
    case "border-right-color":
      return borderColor(prop, value, P.P_BORDER_RIGHT_COLOR, out);
    case "border-bottom-color":
      return borderColor(prop, value, P.P_BORDER_BOTTOM_COLOR, out);
    case "border-left-color":
      return borderColor(prop, value, P.P_BORDER_LEFT_COLOR, out);
    case "border-top-style":
      return borderStyles(prop, value, [P.P_BORDER_TOP_STYLE], out);
    case "border-right-style":
      return borderStyles(prop, value, [P.P_BORDER_RIGHT_STYLE], out);
    case "border-bottom-style":
      return borderStyles(prop, value, [P.P_BORDER_BOTTOM_STYLE], out);
    case "border-left-style":
      return borderStyles(prop, value, [P.P_BORDER_LEFT_STYLE], out);
    // A logical border side names a side of the box's own axes; like a logical margin, which
    // physical side that is depends on the element, so the runtime settles it after the cascade
    // (see resolveLogicalSides in runtime/style.ts).
    case "border-block-start":
      return borderShorthand(prop, value, [BLOCK_START_SIDE], out);
    case "border-block-end":
      return borderShorthand(prop, value, [BLOCK_END_SIDE], out);
    case "border-inline-start":
      return borderShorthand(prop, value, [INLINE_START_SIDE], out);
    case "border-inline-end":
      return borderShorthand(prop, value, [INLINE_END_SIDE], out);
    case "border-block":
      return borderShorthand(prop, value, [BLOCK_START_SIDE, BLOCK_END_SIDE], out);
    case "border-inline":
      return borderShorthand(prop, value, [INLINE_START_SIDE, INLINE_END_SIDE], out);
    case "border-block-width":
    case "border-inline-width": {
      const ids = prop === "border-block-width" ? [P.P_BORDER_BLOCK_START_WIDTH, P.P_BORDER_BLOCK_END_WIDTH]
        : [P.P_BORDER_INLINE_START_WIDTH, P.P_BORDER_INLINE_END_WIDTH];
      const parts = splitValue(value);
      if (parts.length < 1 || parts.length > 2) return `'${prop}' takes one or two values`;
      for (let k = 0; k < 2; k++) {
        const l = parseBorderWidth(parts[Math.min(k, parts.length - 1)]);
        if (l === null) return `unsupported border width '${parts[k]}' for '${prop}'`;
        if (l.v < 0) return `invalid value '${value}' for '${prop}': a border width can't be negative`;
        out.push({ p: ids[k], v: l.v, u: l.u });
      }
      return null;
    }
    case "border-block-style":
    case "border-inline-style": {
      const ids = prop === "border-block-style" ? [P.P_BORDER_BLOCK_START_STYLE, P.P_BORDER_BLOCK_END_STYLE]
        : [P.P_BORDER_INLINE_START_STYLE, P.P_BORDER_INLINE_END_STYLE];
      const parts = splitValue(value);
      if (parts.length < 1 || parts.length > 2) return `'${prop}' takes one or two values`;
      for (let k = 0; k < 2; k++) {
        const st = parseBorderStyle(parts[Math.min(k, parts.length - 1)]);
        if (st < 0) return `unsupported border style '${parts[k]}' for '${prop}'`;
        out.push({ p: ids[k], v: st, u: P.U_NONE });
      }
      return null;
    }
    case "border-block-color":
    case "border-inline-color": {
      const ids = prop === "border-block-color" ? [P.P_BORDER_BLOCK_START_COLOR, P.P_BORDER_BLOCK_END_COLOR]
        : [P.P_BORDER_INLINE_START_COLOR, P.P_BORDER_INLINE_END_COLOR];
      const parts = splitValue(value);
      if (parts.length < 1 || parts.length > 2) return `'${prop}' takes one or two values`;
      for (let k = 0; k < 2; k++) {
        const c = parseBorderColor(parts[Math.min(k, parts.length - 1)]);
        if (c === null) return `unsupported border color '${parts[k]}' for '${prop}'`;
        out.push({ p: ids[k], v: c, u: P.U_NONE });
      }
      return null;
    }
    case "border-block-start-width":
      return borderWidth(prop, value, P.P_BORDER_BLOCK_START_WIDTH, out);
    case "border-block-end-width":
      return borderWidth(prop, value, P.P_BORDER_BLOCK_END_WIDTH, out);
    case "border-inline-start-width":
      return borderWidth(prop, value, P.P_BORDER_INLINE_START_WIDTH, out);
    case "border-inline-end-width":
      return borderWidth(prop, value, P.P_BORDER_INLINE_END_WIDTH, out);
    case "border-block-start-style":
      return borderStyles(prop, value, [P.P_BORDER_BLOCK_START_STYLE], out);
    case "border-block-end-style":
      return borderStyles(prop, value, [P.P_BORDER_BLOCK_END_STYLE], out);
    case "border-inline-start-style":
      return borderStyles(prop, value, [P.P_BORDER_INLINE_START_STYLE], out);
    case "border-inline-end-style":
      return borderStyles(prop, value, [P.P_BORDER_INLINE_END_STYLE], out);
    case "border-block-start-color":
      return borderColor(prop, value, P.P_BORDER_BLOCK_START_COLOR, out);
    case "border-block-end-color":
      return borderColor(prop, value, P.P_BORDER_BLOCK_END_COLOR, out);
    case "border-inline-start-color":
      return borderColor(prop, value, P.P_BORDER_INLINE_START_COLOR, out);
    case "border-inline-end-color":
      return borderColor(prop, value, P.P_BORDER_INLINE_END_COLOR, out);
    case "border-top-left-radius":
      return cornerRadius(prop, value, [P.P_BORDER_TOP_LEFT_RADIUS, P.P_BORDER_TOP_LEFT_RADIUS_Y], out);
    case "border-top-right-radius":
      return cornerRadius(prop, value, [P.P_BORDER_TOP_RIGHT_RADIUS, P.P_BORDER_TOP_RIGHT_RADIUS_Y], out);
    case "border-bottom-right-radius":
      return cornerRadius(prop, value, [P.P_BORDER_BOTTOM_RIGHT_RADIUS, P.P_BORDER_BOTTOM_RIGHT_RADIUS_Y], out);
    case "border-bottom-left-radius":
      return cornerRadius(prop, value, [P.P_BORDER_BOTTOM_LEFT_RADIUS, P.P_BORDER_BOTTOM_LEFT_RADIUS_Y], out);
    case "border-radius":
      return borderRadiusShorthand(prop, value, BORDER_RADIUS_X, BORDER_RADIUS_Y, out);
    case "outline-style":
      return outlineStyle(prop, value, out);
    case "outline-width": {
      const l = parseBorderWidth(value);
      if (l === null) return `unsupported outline width '${value}' for 'outline-width'`;
      if (l.v < 0) return `invalid value '${value}' for 'outline-width': it can't be negative, so the declaration is ignored`;
      out.push({ p: P.P_OUTLINE_WIDTH, v: l.v, u: l.u });
      return null;
    }
    case "outline-color": {
      const c = parseBorderColor(value);
      if (c === null) return `unsupported outline color '${value}' for 'outline-color'`;
      out.push({ p: P.P_OUTLINE_COLOR, v: c, u: P.U_NONE });
      return null;
    }
    case "outline-offset": {
      const l = parseLength(value, false);
      if (l === null || l.u === P.U_PCT || (l.u === P.U_EXPR && exprHasPercent(l.v))) {
        return `unsupported outline offset '${value}' for 'outline-offset'`;
      }
      out.push({ p: P.P_OUTLINE_OFFSET, v: l.v, u: l.u });
      return null;
    }
    case "outline":
      return outlineShorthand(prop, value, out);
    case "border-image":
      return borderImageShorthand(value, out, fonts, loc);
    case "border-image-source": {
      const r = borderImageImage(value, fonts, loc);
      if (typeof r === "string") return `unsupported ${prop} '${value}' (${r})`;
      out.push({ p: P.P_BORDER_IMAGE_SOURCE, v: r, u: P.U_NONE });
      return null;
    }
    case "border-image-slice":
      return borderImageSlice(prop, value, out, fonts);
    case "border-image-width":
      return borderImageWidth(prop, value, out, fonts);
    case "border-image-outset":
      return borderImageOutset(prop, value, out, fonts);
    case "border-image-repeat":
      return borderImageRepeat(prop, value, out, fonts);
    default:
      return undefined;
  }
}

const OUTLINE_STYLES: Record<string, number> = {
  none: P.OLS_NONE, hidden: P.OLS_NONE, auto: P.OLS_AUTO, solid: P.OLS_SOLID,
  dotted: P.OLS_DOTTED, dashed: P.OLS_DASHED, double: P.OLS_DOUBLE,
  groove: P.OLS_GROOVE, ridge: P.OLS_RIDGE, inset: P.OLS_INSET, outset: P.OLS_OUTSET,
};

/** `outline-style`: every border style draws, and `auto` paints as a solid ring, as browsers do. */
function outlineStyle(prop: string, value: string, out: Decl[]): string | null {
  const v = OUTLINE_STYLES[value.trim().toLowerCase()];
  if (v === undefined) return `unsupported outline style '${value}' for '${prop}'`;
  out.push({ p: P.P_OUTLINE_STYLE, v, u: P.U_NONE });
  return null;
}

/**
 * `outline`: width, style and color in any order. As in CSS, the shorthand first resets the
 * longhands it sets, so `outline: 1px solid red` leaves nothing of an earlier outline.
 */
function outlineShorthand(prop: string, value: string, out: Decl[]): string | null {
  out.push(
    { p: P.P_OUTLINE_STYLE, v: P.OLS_NONE, u: P.U_NONE },
    { p: P.P_OUTLINE_WIDTH, v: 3, u: P.U_PX },
    { p: P.P_OUTLINE_COLOR, v: -1, u: P.U_NONE },
  );
  for (const part of splitValue(value)) {
    const lower = part.toLowerCase();
    const style = OUTLINE_STYLES[lower];
    if (style !== undefined) {
      out.push({ p: P.P_OUTLINE_STYLE, v: style, u: P.U_NONE });
      continue;
    }
    const l = parseBorderWidth(part);
    if (l !== null) {
      if (l.v < 0) return `invalid value '${value}' for '${prop}': an outline width can't be negative`;
      out.push({ p: P.P_OUTLINE_WIDTH, v: l.v, u: l.u });
      continue;
    }
    const c = parseBorderColor(part);
    if (c !== null) {
      out.push({ p: P.P_OUTLINE_COLOR, v: c, u: P.U_NONE });
      continue;
    }
    return `unsupported value '${value}' for '${prop}'`;
  }
  return null;
}

// --- border-image -----------------------------------------------------------
//
// The source is an image layer value, like a background layer's: -1 for `none`, a raster file's
// id, or -(gradient id + 2). The slice, width, outset and repeat longhands compile to rows in the
// border-image table (see runtime/border-image.ts for their layout).

const BORDER_IMAGE_REPEAT: Record<string, number> = {
  stretch: P.BI_STRETCH, repeat: P.BI_REPEAT, round: P.BI_ROUND, space: P.BI_SPACE,
};

/** A unitless number, which a slice, width or outset counts in its own way. */
function bareNumber(token: string): number | null {
  const m = /^([-+]?(?:\d+\.?\d*|\.\d+))$/.exec(token.trim());
  return m === null ? null : parseFloat(m[1]);
}

/** The image a border-image-source token names: -1 for none, or a message for a bad image. */
function borderImageImage(token: string, fonts: FontContext | undefined, loc: Loc | undefined): number | string {
  if (/^none$/i.test(token)) return -1;
  const gradient = gradientImage(token);
  if (gradient !== null) {
    if ("error" in gradient) return gradient.error;
    return fonts === undefined ? -1 : -(fonts.gradient(gradient.encoded, gradient.source ?? "") + 2);
  }
  const m = /^url\(\s*(.*?)\s*\)$/i.exec(token.trim());
  if (m === null) return `unsupported border-image source '${token}'`;
  let url = m[1];
  if (url.length >= 2 && (url[0] === '"' || url[0] === "'") && url[url.length - 1] === url[0]) {
    url = url.slice(1, -1);
  }
  return fonts === undefined ? -1 : fonts.image(url, loc ? loc[0] : 0, loc ? loc[1] : 0);
}

/** Expands one to four sides to four, as CSS repeats the shorter lists. */
function fourSides(tokens: string[]): string[] | null {
  if (tokens.length === 1) return [tokens[0], tokens[0], tokens[0], tokens[0]];
  if (tokens.length === 2) return [tokens[0], tokens[1], tokens[0], tokens[1]];
  if (tokens.length === 3) return [tokens[0], tokens[1], tokens[2], tokens[1]];
  return tokens.length === 4 ? tokens : null;
}

/** One border-image-slice value as (value, unit): a number is image pixels, or a percentage. */
function sliceSide(token: string): number[][] | null {
  const n = bareNumber(token);
  if (n !== null) return n < 0 ? null : [[n, P.U_NONE]];
  const l = parseLength(token, false);
  return l !== null && l.u === P.U_PCT && l.v >= 0 ? [[l.v, l.u]] : null;
}

/** One border-image-width value as (value, unit): auto, a number of border widths, or a length. */
function widthSide(token: string): number[][] | null {
  const t = token.trim().toLowerCase();
  if (t === "auto") return [[0, P.U_AUTO]];
  const n = bareNumber(t);
  if (n !== null) return n < 0 ? null : [[n, P.U_NONE]];
  const l = parseLength(t, false);
  return l !== null && l.v >= 0 ? [[l.v, l.u]] : null;
}

/** One border-image-outset value as (value, unit): a number of border widths or a length. */
function outsetSide(token: string): number[][] | null {
  const n = bareNumber(token);
  if (n !== null) return n < 0 ? null : [[n, P.U_NONE]];
  const l = parseLength(token, false);
  return l !== null && l.u !== P.U_PCT && l.v >= 0 ? [[l.v, l.u]] : null;
}

/** Registers one border-image longhand row and gives it the declaration's value. */
function borderImageRow(prop: string, row: number[], out: Decl[], fonts: FontContext | undefined): string | null {
  if (fonts === undefined || fonts.borderImage === undefined) return null;
  out.push({ p: rowProperty(prop), v: fonts.borderImage(row), u: P.U_LIST });
  return null;
}

/** The property id a border-image longhand name belongs to. */
function rowProperty(prop: string): number {
  if (prop === "border-image-width") return P.P_BORDER_IMAGE_WIDTH;
  if (prop === "border-image-outset") return P.P_BORDER_IMAGE_OUTSET;
  if (prop === "border-image-repeat") return P.P_BORDER_IMAGE_REPEAT;
  return P.P_BORDER_IMAGE_SLICE;
}

/** Compiles a list of one to four sides into a border-image row. */
function sidesRow(prop: string, tokens: string[], out: Decl[], fonts: FontContext | undefined,
  parse: (token: string) => number[][] | null): string | null {
  const sides = fourSides(tokens);
  if (sides === null) return `unsupported ${prop} '${tokens.join(" ")}'`;
  const values: number[] = [], units: number[] = [];
  for (const side of sides) {
    const r = parse(side);
    if (r === null) return `unsupported ${prop} value '${side}'`;
    values.push(r[0][0]);
    units.push(r[0][1]);
  }
  return borderImageRow(prop, [...values, ...units], out, fonts);
}

/**
 * `border-image-slice`: one to four numbers or percentages, and `fill` to paint the middle.
 * Registers the row as [top, right, bottom, left, their units..., fill].
 */
function borderImageSlice(prop: string, value: string, out: Decl[], fonts: FontContext | undefined): string | null {
  const tokens: string[] = [];
  let fill = 0;
  for (const token of splitValue(value)) {
    if (token.trim().toLowerCase() === "fill") { fill = 1; continue; }
    tokens.push(token);
  }
  if (tokens.length === 0) return `unsupported ${prop} '${value}'`;
  const sides = fourSides(tokens);
  if (sides === null) return `unsupported ${prop} '${value}'`;
  const values: number[] = [], units: number[] = [];
  for (const side of sides) {
    const r = sliceSide(side);
    if (r === null) return `unsupported ${prop} value '${side}'`;
    values.push(r[0][0]);
    units.push(r[0][1]);
  }
  return borderImageRow(prop, [...values, ...units, fill], out, fonts);
}

/** `border-image-repeat`: one keyword, or the horizontal and vertical ones. */
function borderImageRepeat(prop: string, value: string, out: Decl[], fonts: FontContext | undefined): string | null {
  const tokens = splitValue(value);
  if (tokens.length < 1 || tokens.length > 2) return `unsupported ${prop} '${value}'`;
  const h = BORDER_IMAGE_REPEAT[tokens[0].trim().toLowerCase()];
  const v = tokens.length === 2 ? BORDER_IMAGE_REPEAT[tokens[1].trim().toLowerCase()] : h;
  if (h === undefined || v === undefined) return `unsupported ${prop} '${value}'`;
  return borderImageRow(prop, [h, v], out, fonts);
}

/**
 * `border-image`: the source, the slice, and optionally `/ width` and `/ outset` after it, plus
 * the repeat keywords, in any order. Like every shorthand it resets the longhands it sets.
 */
function borderImageShorthand(value: string, out: Decl[], fonts: FontContext | undefined, loc: Loc | undefined): string | null {
  let image: number | string | null = null;
  const slice: string[] = [];
  const width: string[] = [];
  const outset: string[] = [];
  const repeats: string[] = [];
  let fill = 0;
  let part = 0; // 0 for the slice, 1 for the width after a `/`, 2 for the outset after the next
  for (const token of splitValue(value)) {
    const low = token.trim().toLowerCase();
    if (low === "/") { part++; continue; }
    if (BORDER_IMAGE_REPEAT[low] !== undefined) { repeats.push(low); continue; }
    if (low === "fill") { fill = 1; continue; }
    if (/gradient\(/i.test(token) || /^url\(/i.test(token) || low === "none") {
      const r = borderImageImage(token, fonts, loc);
      if (typeof r === "string") return `unsupported ${"border-image"} '${value}' (${r})`;
      if (image !== null) return `unsupported border-image '${value}' (more than one source)`;
      image = r;
      continue;
    }
    if (part === 0) { slice.push(token); continue; }
    if (part === 1) { width.push(token); continue; }
    outset.push(token);
  }
  if (image === null) return `unsupported border-image '${value}' (no source)`;
  // The shorthand writes every longhand it resets, so an earlier border-image leaves nothing.
  out.push({ p: P.P_BORDER_IMAGE_SOURCE, v: image, u: P.U_NONE });
  const sliceTokens = slice.length === 0 ? ["100%"] : slice;
  const sliceErr = borderImageSlice("border-image-slice", sliceTokens.join(" ") + (fill !== 0 ? " fill" : ""),
    out, fonts);
  if (sliceErr !== null) return `unsupported border-image '${value}' (${sliceErr})`;
  // An omitted width is the longhand's initial value, 1 border width, not `auto` (the slice's
  // own size): the shorthand resets it, and the initial value is what it resets it to.
  const widthErr = borderImageWidth("border-image-width", width.length === 0 ? "1" : width.join(" "), out, fonts);
  if (widthErr !== null) return `unsupported border-image '${value}' (${widthErr})`;
  const outsetErr = borderImageOutset("border-image-outset", outset.length === 0 ? "0" : outset.join(" "), out, fonts);
  if (outsetErr !== null) return `unsupported border-image '${value}' (${outsetErr})`;
  const repeatErr = borderImageRepeat("border-image-repeat", repeats.length === 0 ? "stretch" : repeats.join(" "),
    out, fonts);
  if (repeatErr !== null) return `unsupported border-image '${value}' (${repeatErr})`;
  return null;
}

/** `border-image-width`: one to four of auto, a number of border widths, a length or a percentage. */
function borderImageWidth(prop: string, value: string, out: Decl[], fonts: FontContext | undefined): string | null {
  return sidesRow(prop, splitValue(value), out, fonts, widthSide);
}

/** `border-image-outset`: one to four numbers of border widths or lengths. */
function borderImageOutset(prop: string, value: string, out: Decl[], fonts: FontContext | undefined): string | null {
  return sidesRow(prop, splitValue(value), out, fonts, outsetSide);
}
