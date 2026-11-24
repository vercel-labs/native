// CSS compositing: `filter` and `backdrop-filter`, `mix-blend-mode` and `isolation`. Returns
// undefined for a property this module doesn't handle.

import * as P from "../../props.ts";
import { kw, parseLength, single } from "../declarations.ts";
import { BOXES, boxLayer, imageLayer, listDecl, repeatLayer, positionLayer, sizeLayer, splitLayers, urlOf } from "./backgrounds.ts";
import { parsePosition, positionRows } from "../position.ts";
import { splitValue } from "../fonts.ts";
import { filterList } from "../filters.ts";
import { clipPath } from "../clip-path.ts";
import type { Decl, FontContext, Loc } from "../types.ts";

/**
 * The mask longhands. `mask-image` holds what a background image layer holds, and the other
 * longhands hold the rows a background layer list holds (see BG_*); `mask` sets them all.
 */
function maskProperty(prop: string, value: string, out: Decl[], fonts?: FontContext, loc?: Loc): string | null | undefined {
  const images = (token: string): number | string => imageLayer(token, fonts, loc);
  switch (prop) {
    case "mask-image":
    case "-webkit-mask-image":
      return listDecl(prop, P.P_MASK_IMAGE, P.BG_IMAGE, value, fonts, images, out);
    case "mask-repeat":
    case "-webkit-mask-repeat":
      return listDecl(prop, P.P_MASK_REPEAT, P.BG_REPEAT, value, fonts, repeatLayer, out);
    case "mask-position":
    case "-webkit-mask-position":
    case "mask-position-x":
    case "mask-position-y":
      return listDecl(prop, P.P_MASK_POSITION, P.BG_POSITION, value, fonts, positionLayer, out);
    case "mask-size":
    case "-webkit-mask-size":
      return listDecl(prop, P.P_MASK_SIZE, P.BG_SIZE, value, fonts, sizeLayer, out);
    case "mask-origin":
    case "-webkit-mask-origin":
      return listDecl(prop, P.P_MASK_ORIGIN, P.BG_ORIGIN, value, fonts, boxLayer, out);
    case "mask-clip":
    case "-webkit-mask-clip":
      return listDecl(prop, P.P_MASK_CLIP, P.BG_CLIP, value, fonts, boxLayer, out);
    case "mask":
    case "-webkit-mask":
      return maskShorthand(value, out, fonts, loc);
    default:
      return undefined;
  }
}

/**
 * The `mask` shorthand: layers separated by commas, each an image with a repeat, a
 * position[/size] and up to two boxes. It resets every mask longhand, so all of them are written.
 * Mask mode and mask composite stay at their initial values.
 */
function maskShorthand(value: string, out: Decl[], fonts?: FontContext, loc?: Loc): string | null {
  const layers = splitLayers(value);
  if (layers.length === 0) return `unsupported mask '${value}'`;
  const images: number[] = [];
  const repeats: number[] = [];
  const positions: number[] = [];
  const sizes: number[] = [];
  const origins: number[] = [];
  const clips: number[] = [];
  for (const layer of layers) {
    let image: number | null = null;
    let repeat: number[] = [P.BR_REPEAT, P.BR_REPEAT];
    let size: number[] = [0, P.U_AUTO, 0, P.U_AUTO];
    const boxes: number[] = [];
    const posToks: string[] = [];
    const sizeToks: string[] = [];
    let afterSlash = false;
    for (const token of splitValue(layer)) {
      const low = token.toLowerCase();
      if (low === "/") { afterSlash = true; continue; }
      const slash = token.indexOf("/");
      if (slash > 0 && token.length > slash + 1) {
        posToks.push(token.slice(0, slash));
        afterSlash = true;
        sizeToks.push(token.slice(slash + 1));
        continue;
      }
      if (urlOf(token) !== null || low === "none" || /gradient\(/i.test(token)) {
        const r = imageLayer(token, fonts, loc);
        if (typeof r === "string") return `unsupported mask '${layer}' (${r})`;
        if (image !== null) return `unsupported mask '${layer}' (more than one image)`;
        image = r;
        continue;
      }
      if (/^(repeat|repeat-x|repeat-y|no-repeat|space|round)$/i.test(low)) {
        const r = repeatLayer(low);
        if (typeof r === "string") return `unsupported mask '${layer}' (${r})`;
        repeat = r;
        continue;
      }
      if (BOXES[low] !== undefined) {
        if (boxes.length === 2) return `unsupported mask '${layer}' (more than two boxes)`;
        boxes.push(BOXES[low]);
        continue;
      }
      if (afterSlash || /^(cover|contain|auto)$/i.test(low)) {
        if (sizeToks.length === 2) return `unsupported mask '${layer}' (more than two size values)`;
        sizeToks.push(token);
        continue;
      }
      if (posToks.length === 4) return `unsupported mask '${layer}' (more than four position values)`;
      posToks.push(token);
    }
    if (posToks.length === 0 && sizeToks.length > 0) return `unsupported mask '${layer}' (a size needs a position)`;
    const pos = positionLayer(posToks.length > 0 ? posToks.join(" ") : "center");
    if (typeof pos === "string") return `unsupported mask '${layer}' (${pos})`;
    if (sizeToks.length > 0) {
      const sz = sizeLayer(sizeToks.join(" "));
      if (typeof sz === "string") return `unsupported mask '${layer}' (${sz})`;
      size = sz;
    }
    images.push(image ?? -1);
    repeats.push(repeat[0], repeat[1]);
    for (const n of pos) positions.push(n);
    for (const n of size) sizes.push(n);
    // One box sets origin and clip together; two set them in order.
    origins.push(boxes.length > 0 ? boxes[0] : P.BX_BORDER);
    clips.push(boxes.length > 1 ? boxes[1] : (boxes.length > 0 ? boxes[0] : P.BX_BORDER));
  }
  if (fonts === undefined) return null;
  const decl = (p: number, kind: number, row: number[]) => out.push({ p, v: fonts.background(kind, row), u: P.U_LIST });
  decl(P.P_MASK_IMAGE, P.BG_IMAGE, images);
  decl(P.P_MASK_REPEAT, P.BG_REPEAT, repeats);
  decl(P.P_MASK_POSITION, P.BG_POSITION, positions);
  decl(P.P_MASK_SIZE, P.BG_SIZE, sizes);
  decl(P.P_MASK_ORIGIN, P.BG_ORIGIN, origins);
  decl(P.P_MASK_CLIP, P.BG_CLIP, clips);
  return null;
}

export function effectsProperty(prop: string, value: string, out: Decl[], fonts?: FontContext, loc?: Loc): string | null | undefined {
  switch (prop) {
    case "filter":
      return filterList(prop, value, out, P.P_FILTER, fonts);
    case "backdrop-filter":
    case "-webkit-backdrop-filter":
      return filterList(prop, value, out, P.P_BACKDROP_FILTER, fonts);
    case "mix-blend-mode":
      return kw(prop, value, {
        normal: P.MB_NORMAL, multiply: P.MB_MULTIPLY, screen: P.MB_SCREEN, overlay: P.MB_OVERLAY,
        darken: P.MB_DARKEN, lighten: P.MB_LIGHTEN, "color-dodge": P.MB_COLOR_DODGE,
        "color-burn": P.MB_COLOR_BURN, "hard-light": P.MB_HARD_LIGHT, "soft-light": P.MB_SOFT_LIGHT,
        difference: P.MB_DIFFERENCE, exclusion: P.MB_EXCLUSION, hue: P.MB_HUE,
        saturation: P.MB_SATURATION, color: P.MB_COLOR, luminosity: P.MB_LUMINOSITY,
        "plus-lighter": P.MB_PLUS_LIGHTER,
      }, P.P_MIX_BLEND_MODE, out);
    case "background-blend-mode": {
      const raw = value.trim().toLowerCase();
      if (raw.indexOf(",") >= 0) return `unsupported background-blend-mode '${value}' (a list isn't supported yet)`;
      return kw(prop, raw, {
        normal: P.MB_NORMAL, multiply: P.MB_MULTIPLY, screen: P.MB_SCREEN, overlay: P.MB_OVERLAY,
        darken: P.MB_DARKEN, lighten: P.MB_LIGHTEN, "color-dodge": P.MB_COLOR_DODGE,
        "color-burn": P.MB_COLOR_BURN, "hard-light": P.MB_HARD_LIGHT, "soft-light": P.MB_SOFT_LIGHT,
        difference: P.MB_DIFFERENCE, exclusion: P.MB_EXCLUSION, hue: P.MB_HUE,
        saturation: P.MB_SATURATION, color: P.MB_COLOR, luminosity: P.MB_LUMINOSITY,
        "plus-lighter": P.MB_PLUS_LIGHTER,
      }, P.P_BACKGROUND_BLEND_MODE, out);
    }
    case "perspective": {
      if (value.trim().toLowerCase() === "none") {
        out.push({ p: P.P_PERSPECTIVE, v: -1, u: P.U_NONE });
        return null;
      }
      return single(prop, value, P.P_PERSPECTIVE, false, out, true);
    }
    case "perspective-origin": {
      const split = parsePosition(value, prop);
      if (typeof split === "string") return split;
      out.push({ p: P.P_PERSPECTIVE_ORIGIN, v: positionRows.register(split), u: P.U_LIST });
      return null;
    }
    case "backface-visibility":
      return kw(prop, value, { visible: P.BFV_VISIBLE, hidden: P.BFV_HIDDEN }, P.P_BACKFACE_VISIBILITY, out);
    case "isolation":
      return kw(prop, value, { auto: P.ISO_AUTO, isolate: P.ISO_ISOLATE }, P.P_ISOLATION, out);
    case "clip-path":
    case "-webkit-clip-path":
      return clipPath(prop, value, out, fonts, P.P_CLIP_PATH, false, true);
    case "shape-outside":
      // A float's shape: the same basic shapes, taken against its margin box unless it says
      // otherwise.
      return clipPath(prop, value, out, fonts, P.P_SHAPE_OUTSIDE, true);
    case "shape-margin": {
      const l = parseLength(value.trim(), false);
      if (l === null || l.v < 0) return `unsupported '${value}' for 'shape-margin'`;
      out.push({ p: P.P_SHAPE_MARGIN, v: l.v, u: l.u });
      return null;
    }
    case "mask":
    case "-webkit-mask":
    case "mask-image":
    case "-webkit-mask-image":
    case "mask-repeat":
    case "-webkit-mask-repeat":
    case "mask-position":
    case "-webkit-mask-position":
    case "mask-position-x":
    case "mask-position-y":
    case "mask-size":
    case "-webkit-mask-size":
    case "mask-origin":
    case "-webkit-mask-origin":
    case "mask-clip":
    case "-webkit-mask-clip":
      return maskProperty(prop, value, out, fonts, loc);
    default:
      return undefined;
  }
}
