// CSS background properties: the colour, and the image layer list each layer longhand holds.
//
// A layer list is compiled at build time into a flat row of numbers (see the BG_* kinds in
// shared/props.ts) and the declaration's value is that row's id. The paint code takes layer i of
// every list, cycling the shorter ones, exactly as the background layer algorithm does.

import * as P from "../../props.ts";
import { parseColor } from "../colors.ts";
import { parseLength } from "../declarations.ts";
import type { Len } from "../declarations.ts";
import { splitValue } from "../fonts.ts";
import { gradientImage } from "../gradients.ts";
import { parsePosition } from "../position.ts";
import type { Decl, FontContext, Loc } from "../types.ts";

/** Splits a value on commas that are not inside parentheses or quotes. */
export function splitLayers(value: string): string[] {
  const out: string[] = [];
  let depth = 0, quote = "", cur = "";
  for (const ch of value) {
    if (quote !== "") {
      cur += ch;
      if (ch === quote) quote = "";
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; cur += ch; continue; }
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    if (ch === "," && depth === 0) {
      out.push(cur.trim());
      cur = "";
      continue;
    }
    cur += ch;
  }
  if (cur.trim() !== "") out.push(cur.trim());
  return out;
}

/** The inside of `url(...)`, unquoted; null when the token isn't a url() function. */
export function urlOf(token: string): string | null {
  const m = /^url\(\s*(.*?)\s*\)$/i.exec(token.trim());
  if (!m) return null;
  const inner = m[1];
  if (inner.length >= 2 && (inner[0] === '"' || inner[0] === "'") && inner[inner.length - 1] === inner[0]) {
    return inner.slice(1, -1);
  }
  return inner;
}

/**
 * The image one background-image layer names, or -1 for `none`. A raster file is its IMAGE_FILES
 * id; a gradient is -(its GRADIENTS index + 2), since -1 already means `none`.
 */
export function imageLayer(token: string, fonts: FontContext | undefined, loc: Loc | undefined): number | string {
  if (/^none$/i.test(token)) return -1;
  const gradient = gradientImage(token);
  if (gradient !== null) {
    if ("error" in gradient) return gradient.error;
    return fonts === undefined ? -1 : -(fonts.gradient(gradient.encoded, gradient.source ?? "") + 2);
  }
  const url = urlOf(token);
  if (url === null) return `unsupported background image '${token}'`;
  if (fonts === undefined) return -1;
  return fonts.image(url, loc ? loc[0] : 0, loc ? loc[1] : 0);
}

// ---------------------------------------------------------------------------
// One value of each layer longhand

/** One background-repeat layer as [x, y]. */
export function repeatLayer(token: string): number[] | string {
  const parts = token.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const word = (w: string): number | null => {
    if (w === "repeat") return P.BR_REPEAT;
    if (w === "no-repeat") return P.BR_NO_REPEAT;
    if (w === "space") return P.BR_SPACE;
    if (w === "round") return P.BR_ROUND;
    return null;
  };
  if (parts.length === 1) {
    if (parts[0] === "repeat-x") return [P.BR_REPEAT, P.BR_NO_REPEAT];
    if (parts[0] === "repeat-y") return [P.BR_NO_REPEAT, P.BR_REPEAT];
  }
  if (parts.length > 2) return `unsupported background-repeat '${token}'`;
  const x = word(parts[0]);
  const y = word(parts.length === 2 ? parts[1] : parts[0]);
  if (x === null || y === null) return `unsupported background-repeat '${token}'`;
  return [x, y];
}

/** One background-position layer, in the shared <position> encoding (see shared/css/position.ts). */
export function positionLayer(token: string): number[] | string {
  return parsePosition(token, "background-position");
}

/**
 * One background-position-x or -y layer as a full position row with the other axis centred, so
 * the runtime reads the axis it needs from the same six numbers either way. parsePosition reads a
 * bare value as horizontal, so a vertical longhand's value is parsed behind a `center`.
 */
function positionAxisLayer(token: string, vertical: boolean): number[] | string {
  const prop = vertical ? "background-position-y" : "background-position-x";
  const parts = splitValue(token.trim().toLowerCase());
  const first = parts.length > 0 ? parts[0] : "";
  const offsetFromEdge = parts.length === 2 && (first === "top" || first === "bottom");
  const text = vertical && parts.length > 0 && first !== "center" && (parts.length === 1 || offsetFromEdge)
    ? "center " + token : token;
  const p = parsePosition(text, prop);
  if (typeof p === "string") return p;
  return vertical ? [50, P.U_PCT, 0, p[3], p[4], p[5]] : [p[0], p[1], p[2], 50, P.U_PCT, 0];
}

/** Clears the axis longhands, which a position that names both axes replaces. */
function resetPositionAxes(out: Decl[]): void {
  out.push({ p: P.P_BACKGROUND_POSITION_X, v: -1, u: P.U_NONE });
  out.push({ p: P.P_BACKGROUND_POSITION_Y, v: -1, u: P.U_NONE });
}

/** One background-size layer as [wv, wu, hv, hu]; auto is U_AUTO, cover and contain their units. */
export function sizeLayer(token: string): number[] | string {
  const parts = splitValue(token.trim().toLowerCase());
  if (parts.length === 1 && (parts[0] === "cover" || parts[0] === "contain")) {
    const u = parts[0] === "cover" ? P.U_COVER : P.U_CONTAIN;
    return [0, u, 0, u];
  }
  if (parts.length < 1 || parts.length > 2) return `unsupported background-size '${token}'`;
  const one = (s: string): Len | null => {
    if (s === "auto") return { v: 0, u: P.U_AUTO };
    const l = parseLength(s, false);
    return l !== null && l.v >= 0 ? l : null;
  };
  const w = one(parts[0]);
  const h = parts.length === 2 ? one(parts[1]) : ({ v: 0, u: P.U_AUTO } as Len);
  if (w === null || h === null) return `unsupported background-size '${token}'`;
  return [w.v, w.u, h.v, h.u];
}

export const BOXES: Record<string, number> = { "border-box": P.BX_BORDER, "padding-box": P.BX_PADDING, "content-box": P.BX_CONTENT };

export function boxLayer(token: string): number | string {
  const b = BOXES[token.trim().toLowerCase()];
  return b === undefined ? `unsupported background box '${token}'` : b;
}

/** One background-attachment layer: scroll (the initial value), fixed to the viewport, or local. */
function attachmentLayer(token: string): number | string {
  const w = token.trim().toLowerCase();
  if (w === "scroll") return P.BA_SCROLL;
  if (w === "fixed") return P.BA_FIXED;
  if (w === "local") return P.BA_LOCAL;
  return `unsupported background-attachment '${token}'`;
}

/** Compiles a list of per-layer values and registers the row as the declaration's value. */
export function listDecl(
  prop: string, p: number, kind: number, value: string, fonts: FontContext | undefined,
  parse: (token: string) => number[] | number | string, out: Decl[],
): string | null {
  if (fonts === undefined) return null;
  const row: number[] = [];
  for (const layer of splitLayers(value)) {
    const r = parse(layer);
    if (typeof r === "string") return `unsupported ${prop} '${value}' (${r})`;
    if (typeof r === "number") row.push(r);
    else for (const n of r) row.push(n);
  }
  if (row.length === 0) return `unsupported ${prop} '${value}'`;
  out.push({ p, v: fonts.background(kind, row), u: P.U_LIST });
  return null;
}

// ---------------------------------------------------------------------------

export function backgroundsProperty(prop: string, value: string, out: Decl[], fonts?: FontContext, loc?: Loc): string | null | undefined {
  switch (prop) {
    case "background":
      return backgroundShorthand(value, out, fonts, loc);
    case "background-color": {
      // currentColor is the element's own colour, kept as the -1 sentinel the style pass resolves.
      if (value.trim().toLowerCase() === "currentcolor") {
        out.push({ p: P.P_BACKGROUND_COLOR, v: -1, u: 0 });
        return null;
      }
      const c = parseColor(value);
      if (c === null) return `unsupported ${prop} '${value}' (only solid colors are supported)`;
      out.push({ p: P.P_BACKGROUND_COLOR, v: c, u: 0 });
      return null;
    }
    case "background-image": {
      if (fonts === undefined) return null;
      const row: number[] = [];
      for (const layer of splitLayers(value)) {
        const r = imageLayer(layer, fonts, loc);
        if (typeof r === "string") return `unsupported ${prop} '${value}' (${r})`;
        row.push(r);
      }
      if (row.length === 0) return `unsupported ${prop} '${value}'`;
      out.push({ p: P.P_BACKGROUND_IMAGE, v: fonts.background(P.BG_IMAGE, row), u: P.U_LIST });
      return null;
    }
    case "background-repeat":
      return listDecl(prop, P.P_BACKGROUND_REPEAT, P.BG_REPEAT, value, fonts, repeatLayer, out);
    case "background-position": {
      // The two-value position names both axes, which the axis longhands no longer add to.
      const r = listDecl(prop, P.P_BACKGROUND_POSITION, P.BG_POSITION, value, fonts, positionLayer, out);
      if (r === null) resetPositionAxes(out);
      return r;
    }
    case "background-position-x":
      return listDecl(prop, P.P_BACKGROUND_POSITION_X, P.BG_POSITION, value, fonts,
        (token) => positionAxisLayer(token, false), out);
    case "background-position-y":
      return listDecl(prop, P.P_BACKGROUND_POSITION_Y, P.BG_POSITION, value, fonts,
        (token) => positionAxisLayer(token, true), out);
    case "background-size":
      return listDecl(prop, P.P_BACKGROUND_SIZE, P.BG_SIZE, value, fonts, sizeLayer, out);
    case "background-origin":
      return listDecl(prop, P.P_BACKGROUND_ORIGIN, P.BG_ORIGIN, value, fonts, boxLayer, out);
    case "background-clip":
      return listDecl(prop, P.P_BACKGROUND_CLIP, P.BG_CLIP, value, fonts, boxLayer, out);
    case "background-attachment":
      return listDecl(prop, P.P_BACKGROUND_ATTACHMENT, P.BG_ATTACHMENT, value, fonts, attachmentLayer, out);
    default:
      return undefined;
  }
}

/**
 * The `background` shorthand: layers separated by commas, with a colour allowed in the last one.
 * Each layer is a set of image, repeat, position[/size], box and attachment values. The shorthand
 * resets every background longhand, so all of them are written.
 */
function backgroundShorthand(value: string, out: Decl[], fonts?: FontContext, loc?: Loc): string | null {
  const layers = splitLayers(value);
  if (layers.length === 0) return `unsupported background '${value}'`;
  const images: number[] = [];
  const repeats: number[] = [];
  const positions: number[] = [];
  const sizes: number[] = [];
  const origins: number[] = [];
  const clips: number[] = [];
  const attachments: number[] = [];
  let color: number | null = null;

  for (const layer of layers) {
    let image: number | null = null;
    let repeat: number[] = [P.BR_REPEAT, P.BR_REPEAT];
    let size: number[] = [0, P.U_AUTO, 0, P.U_AUTO];
    const boxes: number[] = [];
    let attachment = P.BA_SCROLL;
    const posToks: string[] = [];
    const sizeToks: string[] = [];
    let afterSlash = false;
    for (const token of splitValue(layer)) {
      const low = token.toLowerCase();
      if (low === "/") { afterSlash = true; continue; }
      if (urlOf(token) !== null || low === "none" || /gradient\(/i.test(token)) {
        const r = imageLayer(token, fonts, loc);
        if (typeof r === "string") return `unsupported background '${layer}' (${r})`;
        if (image !== null) return `unsupported background '${layer}' (more than one image)`;
        image = r;
        continue;
      }
      const c = low === "currentcolor" ? -1 : parseColor(token);
      if (c !== null) {
        if (color !== null) return `unsupported background '${value}' (more than one color)`;
        color = c;
        continue;
      }
      if (/^(repeat|repeat-x|repeat-y|no-repeat|space|round)$/i.test(low)) {
        const r = repeatLayer(low);
        if (typeof r === "string") return `unsupported background '${layer}' (${r})`;
        repeat = r;
        continue;
      }
      if (/^(scroll|fixed|local)$/i.test(low)) {
        const a = attachmentLayer(low);
        if (typeof a === "string") return `unsupported background '${layer}' (${a})`;
        attachment = a;
        continue;
      }
      if (BOXES[low] !== undefined) {
        if (boxes.length === 2) return `unsupported background '${layer}' (more than two boxes)`;
        boxes.push(BOXES[low]);
        continue;
      }
      // "center/cover" without spaces: the size follows the slash within the same token. The
      // image and colour checks come first, since a url() has slashes of its own.
      const slash = token.indexOf("/");
      if (slash > 0 && token.length > slash + 1) {
        posToks.push(token.slice(0, slash));
        afterSlash = true;
        sizeToks.push(token.slice(slash + 1));
        continue;
      }
      if (afterSlash || /^(cover|contain|auto)$/i.test(low)) {
        if (sizeToks.length === 2) return `unsupported background '${layer}' (more than two size values)`;
        sizeToks.push(token);
        continue;
      }
      if (posToks.length === 4) return `unsupported background '${layer}' (more than four position values)`;
      posToks.push(token);
    }
    if (posToks.length === 0 && sizeToks.length > 0) return `unsupported background '${layer}' (a size needs a position)`;
    const pos = positionLayer(posToks.length > 0 ? posToks.join(" ") : "0% 0%");
    if (typeof pos === "string") return `unsupported background '${layer}' (${pos})`;
    if (sizeToks.length > 0) {
      const sz = sizeLayer(sizeToks.join(" "));
      if (typeof sz === "string") return `unsupported background '${layer}' (${sz})`;
      size = sz;
    }
    images.push(image ?? -1);
    repeats.push(repeat[0], repeat[1]);
    for (const n of pos) positions.push(n);
    for (const n of size) sizes.push(n);
    // One box sets origin and clip together; two set them in order.
    origins.push(boxes.length > 0 ? boxes[0] : P.BX_PADDING);
    clips.push(boxes.length > 1 ? boxes[1] : (boxes.length > 0 ? boxes[0] : P.BX_BORDER));
    attachments.push(attachment);
  }

  out.push({ p: P.P_BACKGROUND_COLOR, v: color ?? 0, u: 0 });
  if (fonts === undefined) return null;
  const decl = (p: number, kind: number, row: number[]) => out.push({ p, v: fonts.background(kind, row), u: P.U_LIST });
  decl(P.P_BACKGROUND_IMAGE, P.BG_IMAGE, images);
  decl(P.P_BACKGROUND_REPEAT, P.BG_REPEAT, repeats);
  decl(P.P_BACKGROUND_POSITION, P.BG_POSITION, positions);
  resetPositionAxes(out);
  decl(P.P_BACKGROUND_SIZE, P.BG_SIZE, sizes);
  decl(P.P_BACKGROUND_ORIGIN, P.BG_ORIGIN, origins);
  decl(P.P_BACKGROUND_CLIP, P.BG_CLIP, clips);
  decl(P.P_BACKGROUND_ATTACHMENT, P.BG_ATTACHMENT, attachments);
  return null;
}
