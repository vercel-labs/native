// `mask-image`: what an element paints keeps as much of its alpha as the mask has at each pixel.
//
// The value holds what a background image layer holds (see runtime/background.ts): -1 is `none`
// and a gradient is -(its gradient id + 2). The other mask longhands hold the rows a background
// layer list holds, and a shorter list repeats, as the background layer algorithm says. The mask
// image is positioned in mask-origin's box and clipped to mask-clip's box, which start as the
// border box; the rest starts as the background layer's own initial values, except that a mask
// repeats and sits in the middle of its box. Mask mode is match-source's alpha, the rule for a
// CSS image.

import * as P from "../shared/props.ts";
import type { Node } from "./dom.ts";
import { bg, boxRect, field, gradientOf, pxOf, rowOf } from "./background.ts";
import { paintGradientTile } from "./gradient.ts";
import { drawImageFile, imageFileAxes, orientedImage } from "./images.ts";
import { smoothImage } from "./image-fit.ts";
import { containerBasis } from "./style.ts";
import { hostClipPop, hostClipPush, hostMaskPush, hostMaskSplit } from "./host.ts";

/** Whether the element paints through a mask image. */
export function hasMask(el: Node): boolean {
  const images = rowOf(el, P.P_MASK_IMAGE, bg.images, P.BG_IMAGE);
  if (images === null) return false;
  for (const id of images) if (id !== -1) return true;
  return false;
}

/**
 * Pushes the element's mask over the box [x, y, w, h] and paints the mask image into it. The
 * caller paints the content after this, and pops the layer with hostMaskPop. Returns false when
 * the element has no mask, so the caller has nothing to pop.
 */
export function pushMask(el: Node, x: number, y: number, w: number, h: number): boolean {
  if (!hasMask(el)) return false;
  hostMaskPush(el.serial, P.PK_MASK, x, y, w, h);
  paintMaskLayers(el, x, y, w, h);
  hostMaskSplit();
  return true;
}

/** Paints every mask image layer into the layer hostMaskPush started. */
function paintMaskLayers(el: Node, x: number, y: number, w: number, h: number): void {
  const images = rowOf(el, P.P_MASK_IMAGE, bg.images, P.BG_IMAGE);
  if (images === null || images.length === 0) return;
  const repeats = rowOf(el, P.P_MASK_REPEAT, bg.repeats, P.BG_REPEAT);
  const positions = rowOf(el, P.P_MASK_POSITION, bg.positions, P.BG_POSITION);
  const sizes = rowOf(el, P.P_MASK_SIZE, bg.sizes, P.BG_SIZE);
  const origins = rowOf(el, P.P_MASK_ORIGIN, bg.origins, P.BG_ORIGIN);
  const clips = rowOf(el, P.P_MASK_CLIP, bg.clips, P.BG_CLIP);
  const fontSize = el.sv[P.P_FONT_SIZE];
  // cq units in a mask's size and position resolve against the element's query container.
  const cqw = containerBasis(el, false), cqh = containerBasis(el, true);
  // The last layer is painted first, so the first one ends up on top, as the mask layer
  // algorithm composites them with `add`.
  for (let layer = images.length - 1; layer >= 0; layer--) {
    const id = images[layer];
    if (id === -1) continue;
    const gradient = gradientOf(id);
    let iw = 0, ih = 0;
    // A file's own axes: a size, one axis with a ratio, or just a ratio.
    const axes = gradient === null ? imageFileAxes(id, orientedImage(el)) : null;
    if (axes !== null) {
      iw = axes.w;
      ih = axes.h;
    }
    const origin = field(origins, layer, 0, 1);
    const clip = field(clips, layer, 0, 1);
    const area = boxRect(el, x, y, w, h, Number.isNaN(origin) ? P.BX_BORDER : origin);
    const painted = boxRect(el, x, y, w, h, Number.isNaN(clip) ? P.BX_BORDER : clip);
    if (gradient !== null) { iw = area[2]; ih = area[3]; }
    // A file with no size at all has nothing to lay out; a gradient's zero area may still be
    // fixed by a definite used size below.
    if (gradient === null && (!(iw > 0) || !(ih > 0))) continue;

    // Used size: a length or percentage per axis, auto following the intrinsic ratio (a
    // gradient's auto axis is the whole positioning area), and cover/contain fitting.
    const sw = field(sizes, layer, 0, 4), swu = field(sizes, layer, 1, 4);
    const sh = field(sizes, layer, 2, 4), shu = field(sizes, layer, 3, 4);
    let tw = NaN, th = NaN;
    const ratio = axes === null || axes.ratio <= 0 ? 0 : axes.ratio;
    if (swu === P.U_COVER || swu === P.U_CONTAIN) {
      if (ratio > 0) {
        const sx = area[2] / iw, sy = area[3] / ih;
        const s = swu === P.U_COVER ? Math.max(sx, sy) : Math.min(sx, sy);
        tw = iw * s;
        th = ih * s;
      } else {
        tw = area[2];
        th = area[3];
      }
    } else {
      tw = pxOf(el, sw, swu, area[2], fontSize, cqw, cqh);
      th = pxOf(el, sh, shu, area[3], fontSize, cqw, cqh);
      if (Number.isNaN(tw) && Number.isNaN(th)) {
        // Both auto: the image's own size, the ratio fitted into the positioning area, or the
        // whole area for an image with neither.
        if (axes !== null && axes.has === 3) { tw = iw; th = ih; }
        else if (axes !== null && (axes.has & 2) !== 0) { tw = iw; th = area[3]; }
        else if (axes !== null && (axes.has & 1) !== 0) { th = ih; tw = area[2]; }
        else if (gradient === null && ratio > 0) {
          const s = Math.min(area[2] / iw, area[3] / ih);
          tw = iw * s;
          th = ih * s;
        } else { tw = area[2]; th = area[3]; }
      } else if (Number.isNaN(tw)) {
        tw = ratio > 0 ? th * ratio : axes !== null && (axes.has & 2) !== 0 ? iw : area[2];
      } else if (Number.isNaN(th)) {
        th = ratio > 0 ? tw / ratio : axes !== null && (axes.has & 1) !== 0 ? ih : area[3];
      }
    }
    if (!(tw > 0) || !(th > 0)) continue;

    // Position: mask-position starts at `center`, which moves the image half way across the
    // space left over.
    const freeX = area[2] - tw, freeY = area[3] - th;
    let tx = area[0] + freeX / 2, ty = area[1] + freeY / 2;
    if (positions !== null) {
      const xv = field(positions, layer, 0, 6), xu = field(positions, layer, 1, 6), xEdge = field(positions, layer, 2, 6);
      const yv = field(positions, layer, 3, 6), yu = field(positions, layer, 4, 6), yEdge = field(positions, layer, 5, 6);
      const offX = pxOf(el, xv, xu, freeX, fontSize, cqw, cqh);
      const offY = pxOf(el, yv, yu, freeY, fontSize, cqw, cqh);
      tx = xEdge === 1 ? area[0] + area[2] - tw - offX : area[0] + offX;
      ty = yEdge === 1 ? area[1] + area[3] - th - offY : area[1] + offY;
    }

    // A mask repeats unless mask-repeat says otherwise, the other way round from backgrounds.
    const repX = repeats === null || field(repeats, layer, 0, 2) === P.BR_REPEAT;
    const repY = repeats === null || field(repeats, layer, 1, 2) === P.BR_REPEAT;

    // Tiles are clipped to mask-clip's box; the layer's own bitmap drops whatever falls outside
    // the border box anyway.
    const clipping = Number.isNaN(clip) ? P.BX_BORDER : clip;
    const clipped = clipping !== P.BX_BORDER;
    if (clipped) hostClipPush(el.serial, P.PK_CLIP_RECT, painted[0], painted[1], painted[2], painted[3], 0);
    const basis = { w: area[2], h: area[3] };
    let sy0 = ty;
    if (repY) sy0 = ty - Math.ceil((ty - painted[1]) / th) * th;
    for (let sy = sy0; sy < painted[1] + painted[3]; sy += th) {
      let sx0 = tx;
      if (repX) sx0 = tx - Math.ceil((tx - painted[0]) / tw) * tw;
      for (let sx = sx0; sx < painted[0] + painted[2]; sx += tw) {
        if (gradient !== null) paintGradientTile(gradient, sx, sy, tw, th, fontSize, basis, 1, el.sv[P.P_COLOR]);
        else drawImageFile(id, orientedImage(el), sx, sy, tw, th, 1, smoothImage(el));
        if (!repX) break;
      }
      if (!repY) break;
    }
    if (clipped) hostClipPop();
  }
}
