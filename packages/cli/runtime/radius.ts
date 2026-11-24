// Corner radii: CSS gives each corner a horizontal and a vertical radius, so a box's curve is
// eight numbers. They are resolved to px against the border box and scaled down together when
// opposite corners would overlap, as CSS's corner shaping says.

import * as P from "../shared/props.ts";
import { Node } from "./dom.ts";
import { borderPx, len, zeroIfNaN } from "./layout/box-model.ts";

/** [top-left x, top-left y, top-right x, top-right y, bottom-right x, bottom-right y,
 * bottom-left x, bottom-left y], in CSS's corner order. */
export type Radii = number[];

/**
 * The border box's corner radii in px, scaled down when adjacent corners would overlap. A piece
 * of a sliced inline box squares off the corners at its break (see `first`/`last`) before the
 * scaling, since the break's edges are the piece's own.
 */
export function borderRadii(el: Node, w: number, h: number, first = true, last = true): Radii {
  const r: Radii = [
    zeroIfNaN(len(el, P.P_BORDER_TOP_LEFT_RADIUS, w)),
    zeroIfNaN(len(el, P.P_BORDER_TOP_LEFT_RADIUS_Y, h)),
    zeroIfNaN(len(el, P.P_BORDER_TOP_RIGHT_RADIUS, w)),
    zeroIfNaN(len(el, P.P_BORDER_TOP_RIGHT_RADIUS_Y, h)),
    zeroIfNaN(len(el, P.P_BORDER_BOTTOM_RIGHT_RADIUS, w)),
    zeroIfNaN(len(el, P.P_BORDER_BOTTOM_RIGHT_RADIUS_Y, h)),
    zeroIfNaN(len(el, P.P_BORDER_BOTTOM_LEFT_RADIUS, w)),
    zeroIfNaN(len(el, P.P_BORDER_BOTTOM_LEFT_RADIUS_Y, h)),
  ];
  if (!first) r[0] = r[1] = r[6] = r[7] = 0;
  if (!last) r[2] = r[3] = r[4] = r[5] = 0;
  // A corner with a zero radius in either direction is square, not a flattened curve (CSS
  // Backgrounds 3, the border-radius property): `25px 0` rounds nothing.
  for (let i = 0; i < 8; i += 2) if (!(r[i] > 0) || !(r[i + 1] > 0)) r[i] = r[i + 1] = 0;
  // f = min(1, w / (left radii along the top), …), per CSS's overlap rule; a box with no size
  // takes the whole scale, so the radii shrink to nothing with it.
  let f = 1;
  const fit = (sum: number, size: number) => (sum > 0 ? Math.max(0, size) / sum : 1);
  f = Math.min(f, fit(r[0] + r[2], w), fit(r[6] + r[4], w), fit(r[1] + r[7], h), fit(r[3] + r[5], h));
  if (f < 1) for (let i = 0; i < 8; i++) r[i] *= f;
  return r;
}

/** The radii of a box inset by a border or padding: each corner's curve nests inside the outer one. */
export function insetRadii(r: Radii, left: number, top: number, right: number, bottom: number): Radii {
  return [
    Math.max(0, r[0] - left), Math.max(0, r[1] - top),
    Math.max(0, r[2] - right), Math.max(0, r[3] - top),
    Math.max(0, r[4] - right), Math.max(0, r[5] - bottom),
    Math.max(0, r[6] - left), Math.max(0, r[7] - bottom),
  ];
}

/** The radii of a box inset by the element's border (`andPadding` adds its padding too). */
export function innerRadii(el: Node, r: Radii, andPadding: boolean): Radii {
  const bl = borderPx(el.sv[P.P_BORDER_LEFT_WIDTH]), br = borderPx(el.sv[P.P_BORDER_RIGHT_WIDTH]);
  const bt = borderPx(el.sv[P.P_BORDER_TOP_WIDTH]), bb = borderPx(el.sv[P.P_BORDER_BOTTOM_WIDTH]);
  let left = bl, top = bt, right = br, bottom = bb;
  if (andPadding) {
    left += zeroIfNaN(len(el, P.P_PADDING_LEFT, el.w));
    right += zeroIfNaN(len(el, P.P_PADDING_RIGHT, el.w));
    top += zeroIfNaN(len(el, P.P_PADDING_TOP, el.w));
    bottom += zeroIfNaN(len(el, P.P_PADDING_BOTTOM, el.w));
  }
  return insetRadii(r, left, top, right, bottom);
}

/** Whether any corner is rounded (the square fast paths are cheaper). */
export function rounded(r: Radii): boolean {
  for (let i = 0; i < r.length; i++) if (r[i] > 0) return true;
  return false;
}
