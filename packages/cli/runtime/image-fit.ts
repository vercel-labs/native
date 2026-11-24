// object-fit and object-position: where a replaced element's content (its image or canvas
// bitmap) is drawn inside its content box, and whether the host may interpolate it when it
// scales (image-rendering).

import * as P from "../shared/props.ts";
import { positionRows } from "../shared/css/position.ts";
import { evalExpr } from "../shared/css/length-exprs.ts";
import type { Node } from "./dom.ts";
import { viewport } from "./layout/box-model.ts";
import { cqUnitPx } from "./style.ts";
import { rootFontSize } from "./root-size.ts";
import { fontMetrics, textWidth } from "./layout/text.ts";

/** A length on one axis of the free space, resolved against `base` (the space left over). */
function pxOf(el: Node, v: number, u: number, base: number, fontSize: number): number {
  if (u >= P.U_CQW && u <= P.U_CQMAX) return cqUnitPx(el, v, u);
  if (u === P.U_EXPR) {
    return evalExpr(v, base, viewport.w, viewport.h, fontSize, cqUnitPx(el, 100, P.U_CQW), cqUnitPx(el, 100, P.U_CQH), rootFontSize(), el.sv[P.P_LINE_HEIGHT]);
  }
  if (u === P.U_PCT) return (base * v) / 100;
  if (u === P.U_EM) return v * fontSize;
  if (u === P.U_REM) return v * rootFontSize();
  if (u === P.U_LH) return v * el.sv[P.P_LINE_HEIGHT];
  if (u === P.U_EX) return v * fontMetrics(el)[2];
  if (u === P.U_CH) return v * textWidth(el, "0");
  if (u === P.U_VW) return (viewport.w * v) / 100;
  if (u === P.U_VH) return (viewport.h * v) / 100;
  return v;
}

/**
 * The rect the content is drawn in: `[x, y, w, h]` inside the content box at (x, y, w, h), with
 * the content's intrinsic size (iw, ih) fitted per object-fit and moved per object-position. A
 * broken image (no intrinsic size) fills the box, as a browser leaves it empty.
 */
export function contentRect(el: Node, x: number, y: number, w: number, h: number, iw: number, ih: number, fontSize: number): number[] {
  const fit = el.sv[P.P_OBJECT_FIT];
  let dw = w, dh = h;
  if (fit !== P.OF_FILL && iw > 0 && ih > 0) {
    const sx = w / iw, sy = h / ih;
    let s = fit === P.OF_COVER ? Math.max(sx, sy) : Math.min(sx, sy);
    // `none` keeps the intrinsic size, and `scale-down` takes whichever is smaller of that and
    // the contain size.
    if (fit === P.OF_NONE) s = 1;
    else if (fit === P.OF_SCALE_DOWN && s > 1) s = 1;
    dw = iw * s;
    dh = ih * s;
  }

  let xv = 50, xu = P.U_PCT, xEdge = 0, yv = 50, yu = P.U_PCT, yEdge = 0;
  if (el.su[P.P_OBJECT_POSITION] === P.U_LIST) {
    const row = positionRows.row(el.sv[P.P_OBJECT_POSITION]);
    if (row !== null && row.length >= 6) {
      xv = row[0]; xu = row[1]; xEdge = row[2];
      yv = row[3]; yu = row[4]; yEdge = row[5];
    }
  }
  // A percentage moves the content across the space left over; a length is an offset from the
  // left/top edge, or from the right/bottom one when the keyword said so.
  const freeX = w - dw, freeY = h - dh;
  const offX = pxOf(el, xv, xu, freeX, fontSize);
  const offY = pxOf(el, yv, yu, freeY, fontSize);
  return [
    xEdge === 1 ? x + freeX - offX : x + offX,
    yEdge === 1 ? y + freeY - offY : y + offY,
    dw, dh,
  ];
}

/** Whether the host should leave the image's pixels sharp when it scales it (image-rendering). */
export function smoothImage(el: Node): number {
  const ir = el.sv[P.P_IMAGE_RENDERING];
  return ir === P.IR_PIXELATED || ir === P.IR_CRISP_EDGES ? 0 : 1;
}
