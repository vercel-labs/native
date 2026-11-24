// box-shadow: the lists compiled at build time, and resolving one against the element it paints.
//
// A value is a row id into the shadow table; each row holds ten numbers per shadow (see
// P_BOX_SHADOW). The lengths keep their units until here, since em and vw need the element and
// the viewport.

import * as P from "../shared/props.ts";
import { shadowRows } from "../shared/css/shadows.ts";
import type { Node } from "./dom.ts";
import { viewport } from "./layout/box-model.ts";
import { cqUnitPx, exprLength } from "./style.ts";
import { rootFontSize } from "./root-size.ts";
import { fontMetrics, textWidth } from "./layout/text.ts";

/** Registers one shadow list a style declared at runtime, and returns its id. */
export function registerShadow(row: number[]): number {
  return shadowRows.register(row);
}

/** One shadow, with its lengths in px. */
export interface Shadow {
  dx: number;
  dy: number;
  blur: number;
  spread: number;
  /** Packed 0xRRGGBBAA; -1 is currentColor. */
  color: number;
  inset: boolean;
}

function resolve(v: number, u: number, el: Node): number {
  if (u >= P.U_CQW && u <= P.U_CQMAX) return cqUnitPx(el, v, u);
  if (u === P.U_EXPR) return exprLength(el, v, 0, el.sv[P.P_FONT_SIZE]);
  if (u === P.U_EM) return v * el.sv[P.P_FONT_SIZE];
  if (u === P.U_REM) return v * rootFontSize();
  if (u === P.U_VW) return (v / 100) * viewport.w;
  if (u === P.U_VH) return (v / 100) * viewport.h;
  if (u === P.U_LH) return v * el.sv[P.P_LINE_HEIGHT];
  if (u === P.U_EX) return v * fontMetrics(el)[2];
  if (u === P.U_CH) return v * textWidth(el, "0");
  return v; // px, or a unitless zero
}

/** The element's shadows, in the written order (the first one is painted last, on top). */
export function boxShadows(el: Node): Shadow[] {
  return shadowList(el, el.sv[P.P_BOX_SHADOW]);
}

/** The element's text shadows, in the written order (the first one is painted on top). */
export function textShadows(el: Node): Shadow[] {
  return shadowList(el, el.sv[P.P_TEXT_SHADOW]);
}

/** The shadows behind a box-shadow value (a row id), resolved against the element. */
export function shadowList(el: Node, id: number): Shadow[] {
  if (id < 0) return [];
  const row = shadowRows.row(id);
  if (row === null) return [];
  const out: Shadow[] = [];
  for (let i = 0; i + 9 < row.length; i += 10) {
    out.push({
      dx: resolve(row[i], row[i + 1], el),
      dy: resolve(row[i + 2], row[i + 3], el),
      blur: Math.max(0, resolve(row[i + 4], row[i + 5], el)),
      spread: resolve(row[i + 6], row[i + 7], el),
      color: row[i + 8],
      inset: row[i + 9] === 1,
    });
  }
  return out;
}
