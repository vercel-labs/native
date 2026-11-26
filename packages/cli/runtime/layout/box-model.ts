// Box-model helpers: lengths, padding/border/margin sums, min/max clamping, specified sizes and relative offsets.

import * as P from "../../shared/props.ts";
import { rootFontSize } from "../root-size.ts";
import { HTMLButtonElement, HTMLCanvasElement, HTMLInputElement, boxKids, buttonInputType, document } from "../dom.ts";
import type { Element, Node } from "../dom.ts";
import { hostMeasureText } from "../host.ts";
import { imageHasSize, imageObjectSize, imageRatio, imageSize, orientedImage } from "../images.ts";
import { svgViewBox } from "../svg.ts";
import { cqUnitPx, exprLength, isFlexContainer, isGridContainer, isLanesContainer, isRtl, isVerticalText, usedWritingMode } from "../style.ts";
import { viewport } from "../viewport.ts";
import { isQuirks, quirkHeight } from "../quirk.ts";
import { evalExpr } from "../../shared/css/length-exprs.ts";
import { clipMarginRows } from "../../shared/css/properties/box.ts";
import { contentMaxWidth, contentMinWidth, fontMetrics, textWidth } from "./text.ts";

export { viewport };

// ---------------------------------------------------------------------------
// Helpers

const measureCache: Map<string, number> = new Map();

/**
 * Forgets the measured widths. The key carries the element's packed font key, whose family id is
 * an index into the page's own tables (and whose feature run is the host's id for the page), so a
 * batch that renders several pages in one process must start each with an empty cache.
 */
export function resetMeasureCache(): void {
  measureCache.clear();
}

export function measure(text: string, size: number, weight: number): number {
  // A zero font size gives every glyph a zero advance. The host's font API clamps the size, so
  // measuring a space at 0 would otherwise come back with a whole font's worth of width.
  if (!(size > 0)) return 0;
  const key = `${size}|${weight}|${text}`;
  const hit = measureCache.get(key);
  if (hit !== undefined) return hit;
  const w = hostMeasureText(text, size, weight, 0, 0);
  measureCache.set(key, w);
  return w;
}

/**
 * Whether the box sits in a turned frame: its parent laid it out along a vertical inline axis, so
 * the layout's x runs down the page and its y across it. Layout code reads and writes a box's
 * length properties in the frame's own axes — its inline axis first — and these accessors map
 * them onto the physical sides the page has, so the rest of the layout never has to know.
 */
export function turned(el: Node): boolean {
  return el.inVtext !== 0;
}

/** Whether the turned frame runs right to left (vertical-rl and sideways-rl). */
function turnedRl(el: Node): boolean {
  const m = el.sv[P.P_WRITING_MODE];
  return m !== P.WM_VERTICAL_LR && m !== P.WM_SIDEWAYS_LR;
}

/**
 * The physical side a layout side turns into, as its offset in a four-side family whose members
 * run top, right, bottom, left: the layout's left is the page's top (a line starts there), the
 * frame's top starts at the page's right in a right-to-left frame and at its left in a
 * left-to-right one, and the other two follow.
 */
function turnedSide(fam: number, rl: boolean): number {
  // The id's side is read in the layout's axes: its left is the inline start, its right the
  // inline end, its top the block start and its bottom the block end. In a four-side family the
  // members run top, right, bottom, left, so `fam` is which id it is.
  if (fam === 3) return 0;
  if (fam === 1) return 2;
  if (fam === 0) return rl ? 1 : 3;
  return rl ? 3 : 1;
}

/**
 * The property a length id names for a turned box: sizes swap width and height, and each side
 * becomes the physical side the frame's axis puts it on.
 */
function turnedProp(el: Node, p: number): number {
  if (p === P.P_WIDTH) return P.P_HEIGHT;
  if (p === P.P_HEIGHT) return P.P_WIDTH;
  if (p === P.P_MIN_WIDTH) return P.P_MIN_HEIGHT;
  if (p === P.P_MIN_HEIGHT) return P.P_MIN_WIDTH;
  if (p === P.P_MAX_WIDTH) return P.P_MAX_HEIGHT;
  if (p === P.P_MAX_HEIGHT) return P.P_MAX_WIDTH;
  if (p >= P.P_MARGIN_TOP && p <= P.P_MARGIN_LEFT) return P.P_MARGIN_TOP + turnedSide(p - P.P_MARGIN_TOP, turnedRl(el));
  if (p >= P.P_PADDING_TOP && p <= P.P_PADDING_LEFT) return P.P_PADDING_TOP + turnedSide(p - P.P_PADDING_TOP, turnedRl(el));
  if (p >= P.P_BORDER_TOP_WIDTH && p <= P.P_BORDER_LEFT_WIDTH) return P.P_BORDER_TOP_WIDTH + turnedSide(p - P.P_BORDER_TOP_WIDTH, turnedRl(el));
  if (p >= P.P_TOP && p <= P.P_LEFT) return P.P_TOP + turnedSide(p - P.P_TOP, turnedRl(el));
  return p;
}

/** The unit one of the box's size properties has, read in the axes the layout uses for it. */
export function sizeUnit(el: Node, p: number): number {
  return el.su[turned(el) ? turnedProp(el, p) : p];
}

/** Resolves a length to px. Returns NaN for auto or for a percentage of an indefinite size. */
export function len(el: Node, p: number, base: number): number {
  return lenPhys(el, turned(el) ? turnedProp(el, p) : p, base);
}

/**
 * A length property on the physical side it names, whatever frame the box is laid out in: what a
 * page-space reader such as relative positioning needs.
 */
export function lenPhys(el: Node, p: number, base: number): number {
  // A table under border-collapse ignores its padding (CSS 2.1 §17.6.2); bpad holds that used 0
  // once the table is laid out. A box measured before then — the float holding the table asks for
  // its width first — has to give the same answer, which the style alone already decides.
  if (p >= P.P_PADDING_TOP && p <= P.P_PADDING_LEFT) {
    if (el.bpad.length > 0) return el.bpad[p - P.P_PADDING_TOP];
    const d = display(el);
    if ((d === P.D_TABLE || d === P.D_INLINE_TABLE) && el.sv[P.P_BORDER_COLLAPSE] === P.BC_COLLAPSE) return 0;
  }
  const v = el.sv[p];
  const u = el.su[p];
  if (u === P.U_PX || u === P.U_NONE) return v;
  if (u === P.U_PCT) return (v / 100) * base;
  if (u === P.U_VW) return (v / 100) * viewport.w;
  if (u === P.U_VH) return (v / 100) * viewport.h;
  if (u === P.U_LH) return v * el.sv[P.P_LINE_HEIGHT];
  if (u === P.U_EX) return v * fontMetrics(el)[2];
  if (u === P.U_CH) return v * textWidth(el, "0");
  if (u === P.U_EXPR) return exprLength(el, v, base, el.sv[P.P_FONT_SIZE]);
  return NaN;
}

export function zeroIfNaN(n: number): number {
  return Number.isNaN(n) ? 0 : n;
}

/**
 * overflow-clip-margin as [visual box, margin in px] (see shared/css/properties/box.ts). The
 * initial value is a zero margin around the padding box.
 */
export function clipMargin(el: Node): number[] {
  const id = el.sv[P.P_OVERFLOW_CLIP_MARGIN];
  if (el.su[P.P_OVERFLOW_CLIP_MARGIN] !== P.U_LIST || id < 0) return [P.OCM_PADDING_BOX, 0];
  const row = clipMarginRows.row(id);
  if (row === null || row.length < 3) return [P.OCM_PADDING_BOX, 0];
  return [row[0], zeroIfNaN(rowLength(el, row[1], row[2]))];
}

/** A length kept in a row, resolved to px for this element. */
export function rowLength(el: Node, v: number, u: number): number {
  if (u === P.U_PX || u === P.U_NONE) return v;
  if (u === P.U_PCT) return NaN;
  if (u === P.U_EM) return v * el.sv[P.P_FONT_SIZE];
  if (u === P.U_REM) return v * rootFontSize();
  if (u === P.U_VW) return (v / 100) * viewport.w;
  if (u === P.U_VH) return (v / 100) * viewport.h;
  if (u >= P.U_CQW && u <= P.U_CQMAX) return cqUnitPx(el, v, u);
  if (u === P.U_EX) return v * fontMetrics(el)[2];
  if (u === P.U_CH) return v * textWidth(el, "0");
  if (u === P.U_EXPR) return exprLength(el, v, 0, el.sv[P.P_FONT_SIZE]);
  return NaN;
}

export function display(el: Node): number {
  // A ::backdrop is painted by the top layer in the box its own style gives it, not laid out
  // with its element: it never takes part in the flow, as in a browser.
  if (el.pseudoKind === P.PE_BACKDROP) return P.D_NONE;
  // A box's used display is read many times by one paint or layout pass; answer once per
  // version of the box's own style, which a pass or an attribute write moves.
  if (el.dispGen === el.styleGen) return el.dispVal;
  const d = el.sv[P.P_DISPLAY];
  // A button's box follows the HTML button layout rules rather than its display value: it is an
  // inline-block when that value is inline-level and a block box otherwise (a flow root, see
  // isBfcRoot), so a table-cell or a list-item on a button draws a plain block, and display:
  // inline makes it the atomic inline box its content box is. A flex, grid or grid-lanes
  // container is the exception: those lay their content out as the value says.
  if (isButtonBox(el) && d !== P.D_NONE && d !== P.D_CONTENTS &&
    !isFlexContainer(el) && !isGridContainer(el) && !isLanesContainer(el)) {
    const out = isInlineLevel(d) || d === P.D_INLINE_TABLE ? P.D_INLINE_BLOCK : P.D_BLOCK;
    el.dispGen = el.styleGen;
    el.dispVal = out;
    return out;
  }
  // A replaced element can't be a table box: its content is its image, so it has no cells or rows
  // to take part in. Browsers lay it out as an inline-level atomic box instead, which the table
  // fixup then wraps in anonymous cells around whatever surrounds it (CSS 2.1 17.2.1).
  const out = d >= P.D_TABLE && d <= P.D_TABLE_CAPTION && isReplaced(el) ? P.D_INLINE : d;
  el.dispGen = el.styleGen;
  el.dispVal = out;
  return out;
}

/** Whether a display value puts its box in the inline flow: inline, inline-block and the
 * inline-level flex and grid containers. */
function isInlineLevel(d: number): boolean {
  return d === P.D_INLINE || d === P.D_INLINE_BLOCK || d === P.D_INLINE_FLEX ||
    d === P.D_INLINE_GRID || d === P.D_INLINE_GRID_LANES;
}

// The used border widths: the collapsed border model gives a box a half-shared grid line instead
// of its computed border (see layout/table.ts), and rows and row groups none at all.
export function borderTop(el: Node): number {
  return el.bw.length > 0 ? el.bw[0] : el.sv[P.P_BORDER_TOP_WIDTH];
}

export function borderRight(el: Node): number {
  return el.bw.length > 0 ? el.bw[1] : el.sv[P.P_BORDER_RIGHT_WIDTH];
}

export function borderBottom(el: Node): number {
  return el.bw.length > 0 ? el.bw[2] : el.sv[P.P_BORDER_BOTTOM_WIDTH];
}

export function borderLeft(el: Node): number {
  return el.bw.length > 0 ? el.bw[3] : el.sv[P.P_BORDER_LEFT_WIDTH];
}

/**
 * A border width in the device pixels it covers. CSS floors the used width, so a 1.9px border
 * is drawn 1px wide; here one CSS pixel is one device pixel. The painted boxes beside a border
 * (its background's padding box, say) use the same floored widths, so their edges meet the
 * painted border without a seam.
 */
export function borderPx(w: number): number {
  return w > 0 ? Math.floor(w) : 0;
}

/** The used border on the box's inline-start side: its left border, or the top one when turned. */
export function inlineStartBorder(el: Node): number {
  return turned(el) ? borderTop(el) : borderLeft(el);
}

/** The used border on the box's inline-end side: its right border, or the bottom one when turned. */
export function inlineEndBorder(el: Node): number {
  return turned(el) ? borderBottom(el) : borderRight(el);
}

/**
 * The used border on the box's block-start side: its top border, or in a turned frame the right
 * border of a right-to-left frame and the left border of a left-to-right one.
 */
export function blockStartBorder(el: Node): number {
  if (!turned(el)) return borderTop(el);
  return turnedRl(el) ? borderRight(el) : borderLeft(el);
}

export function blockEndBorder(el: Node): number {
  if (!turned(el)) return borderBottom(el);
  return turnedRl(el) ? borderLeft(el) : borderRight(el);
}

export function padH(el: Node, cbW: number): number {
  return zeroIfNaN(len(el, P.P_PADDING_LEFT, cbW)) + zeroIfNaN(len(el, P.P_PADDING_RIGHT, cbW)) + inlineStartBorder(el) + inlineEndBorder(el);
}

export function padV(el: Node, cbW: number): number {
  // Padding percentages resolve against the containing block's inline size, which arrives here as
  // cbW, on every side (CSS 2.1 8.4).
  return zeroIfNaN(len(el, P.P_PADDING_TOP, cbW)) + zeroIfNaN(len(el, P.P_PADDING_BOTTOM, cbW)) + blockStartBorder(el) + blockEndBorder(el);
}

export function marginH(el: Node, cbW: number): number {
  return zeroIfNaN(len(el, P.P_MARGIN_LEFT, cbW)) + zeroIfNaN(len(el, P.P_MARGIN_RIGHT, cbW));
}

export function marginV(el: Node, cbW: number): number {
  return zeroIfNaN(len(el, P.P_MARGIN_TOP, cbW)) + zeroIfNaN(len(el, P.P_MARGIN_BOTTOM, cbW));
}

/** Whether a width or height property holds one of the intrinsic sizing keywords. */
export function isIntrinsicSize(u: number): boolean {
  return u === P.U_MIN_CONTENT || u === P.U_MAX_CONTENT || u === P.U_FIT_CONTENT;
}

/**
 * The aspect ratio an image or canvas has of its own, or 0 when it has none. A replaced box has a
 * preferred aspect ratio even where `aspect-ratio` doesn't apply: its image is the ratio.
 */
function naturalRatio(el: Node): number {
  if (!isReplaced(el)) return 0;
  // An inline <svg>'s ratio is its viewBox's, whatever its width and height attributes say.
  if (isSvgElement(el)) {
    const view = svgViewBox(el as Element);
    if (view !== null) return view[2] / view[3];
    // Without a viewBox the attributes give a ratio only when both of them state a size; the
    // 300-by-150 size an <svg> falls back to is a default, not a ratio of its own.
    const e = el as Element;
    const w = svgLengthAttr(e, "width", viewport.w);
    const h = svgLengthAttr(e, "height", viewport.h);
    return w !== null && h !== null && w > 0 && h > 0 ? w / h : 0;
  }
  const s = intrinsicSize(el);
  if (s[0] > 0 && s[1] > 0) return s[0] / s[1];
  // An image with a ratio and no size of its own has its ratio without an intrinsic size.
  return imageRatio(el.imagePath);
}

/**
 * Whether a replaced box's image has a size of its own. An SVG file that only has a viewBox has
 * just a ratio: an auto width then fills the space the image is given, as CSS sizes an image
 * with a ratio and no intrinsic size, and the ratio gives it a height.
 */
export function hasNaturalSize(el: Node): boolean {
  if (!isReplaced(el) || el.localName === "canvas" || el.localName === "video") return true;
  // An inline <svg> has a size of its own only when both of its root width and height
  // attributes are absolute lengths: a missing one is the 100% default, which is no size.
  if (isSvgElement(el)) {
    const e = el as Element;
    const w = e.getAttribute("width");
    const h = e.getAttribute("height");
    return w !== null && h !== null && !w.trim().endsWith("%") && !h.trim().endsWith("%");
  }
  return imageHasSize(el.imagePath);
}

/**
 * The size an image is fitted into its content box at (object-fit): its own size, or the default
 * object size of 300 by 150 fitted to its ratio when it only has a ratio to go on.
 */
export function objectSize(el: Node, oriented: boolean): number[] {
  if (!isReplaced(el) || isSvgElement(el) || el.localName === "canvas" || el.localName === "video") return intrinsicSize(el);
  return imageObjectSize(el.imagePath, oriented);
}

/**
 * The preferred aspect ratio (width / height) the box has, or 0 when it has none: the
 * aspect-ratio property, or for a replaced box the image's own ratio when the property leaves the
 * choice to `auto`. A ratio given by the property doesn't apply to inline boxes or table parts.
 */
export function aspectRatio(el: Node): number {
  const r = el.sv[P.P_ASPECT_RATIO];
  if (isReplaced(el)) {
    const natural = naturalRatio(el);
    if (!(r > 0)) return natural;
    return el.sv[P.P_ASPECT_RATIO_AUTO] === 1 && natural > 0 ? natural : r;
  }
  if (!(r > 0)) return 0;
  const d = display(el);
  if (d === P.D_INLINE || (d >= P.D_TABLE_ROW_GROUP && d <= P.D_TABLE_CAPTION)) return 0;
  return r;
}

/**
 * Whether a box's preferred aspect ratio relates the box `box-sizing` sizes: a bare <ratio> does,
 * while `auto <ratio>` works on the content box the way a replaced box's own ratio does.
 */
function ratioOnBorderBox(el: Node): boolean {
  return el.sv[P.P_BOX_SIZING] === P.BS_BORDER && el.sv[P.P_ASPECT_RATIO_AUTO] !== 1;
}

/**
 * The border-box height a box with a preferred aspect ratio takes when its border-box width is
 * `w`: the ratio relates the box the sizing properties size, so a content-box box takes its
 * padding and border on top of the ratio's height.
 */
export function aspectH(el: Node, w: number, cbW: number): number {
  const r = aspectRatio(el);
  // A turned box's inline size is its height and its block size its width, so the ratio runs the
  // other way round there: the block size is the ratio times the inline one.
  if (turned(el)) return ratioOnBorderBox(el) ? w * r : (w - padH(el, cbW)) * r + padV(el, cbW);
  if (ratioOnBorderBox(el)) return w / r;
  return (w - padH(el, cbW)) / r + padV(el, cbW);
}

/** The border-box width a box with a preferred aspect ratio takes when its border-box height is `h`. */
export function aspectW(el: Node, h: number, cbW: number): number {
  const r = aspectRatio(el);
  if (turned(el)) return ratioOnBorderBox(el) ? h / r : (h - padV(el, cbW)) / r + padH(el, cbW);
  if (ratioOnBorderBox(el)) return h * r;
  return (h - padV(el, cbW)) * r + padH(el, cbW);
}

/**
 * The block size a box's max-height makes definite, for a preferred aspect ratio to transfer to
 * the inline size, or NaN when the box has no max-height. A max-height leaves the content no more
 * than its value, and never less than the box's own padding.
 */
export function boundedRatioH(el: Node, cbW: number, cbH: number): number {
  const adj = el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : padV(el, cbW);
  const max = len(el, P.P_MAX_HEIGHT, cbH);
  if (Number.isNaN(max)) return NaN;
  let h = Math.max(padV(el, cbW), max + adj);
  const min = len(el, P.P_MIN_HEIGHT, cbH);
  if (!Number.isNaN(min) && h < min + adj) h = min + adj;
  return h;
}

/**
 * The border-box width an intrinsic keyword asks for: `min-content` measures the content with no
 * room to spare, `max-content` without wrapping, and `fit-content` clamps max-content to the space
 * available but never below min-content.
 */
export function intrinsicBoxW(el: Node, u: number, cbW: number, cbH: number = NaN, ownH: number = NaN): number {
  // A table measures its own width through the same clamping that asks this question, so a
  // second visit to the same box means that came back round: it asks for nothing.
  if (el.measuringW) return NaN;
  el.measuringW = true;
  const max = contentMaxWidth(el, cbW, cbH, ownH);
  let out = max;
  if (u !== P.U_MAX_CONTENT) {
    const min = contentMinWidth(el, cbW, true, cbH, ownH);
    out = u === P.U_MIN_CONTENT ? min : Math.min(max, Math.max(min, cbW - marginH(el, cbW)));
  }
  el.measuringW = false;
  return out;
}

/**
 * A width property's value as `clampW` and `specW` use it: a content-box length, or NaN for auto.
 * A keyword resolves to the border-box width it names, less the padding when the box's sizing puts
 * the specified width around the content only.
 */
function sizeLenW(el: Node, p: number, cbW: number, cbH: number = NaN): number {
  const u = sizeUnit(el, p);
  if (u === P.U_STRETCH) {
    const fill = stretchFill(el, true, cbW);
    return Number.isNaN(fill) ? NaN : el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? fill : fill - padH(el, cbW);
  }
  if (!isIntrinsicSize(u)) return len(el, p, cbW);
  const bw = intrinsicBoxW(el, u, cbW, cbH);
  return el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? bw : bw - padH(el, cbW);
}

export function clampW(el: Node, w: number, cbW: number): number {
  const adj = el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : padH(el, cbW);
  const max = sizeLenW(el, P.P_MAX_WIDTH, cbW);
  const min = sizeLenW(el, P.P_MIN_WIDTH, cbW);
  if (!Number.isNaN(max) && w > max + adj) w = max + adj;
  if (!Number.isNaN(min) && w < min + adj) w = min + adj;
  return Math.max(w, padH(el, cbW));
}

/**
 * The edge a self-alignment value settles on. native lays pages out left to right, so self-start
 * and left are the start edge, self-end and right the end edge (CSS Align 4). The ids stay apart
 * in the computed value, but the layout has one start and one end.
 */
export function alignEdge(v: number): number {
  if (v === P.A_SELF_START || v === P.A_LEFT || v === P.A_FLEX_START) return P.A_START;
  if (v === P.A_SELF_END || v === P.A_RIGHT || v === P.A_FLEX_END) return P.A_END;
  return v;
}

/** The packing a content-alignment value settles on: left and right are its start and end. */
export function contentEdge(v: number): number {
  // align-content's `normal` grows the auto tracks, which is what `stretch` does.
  if (v === P.AC_NORMAL) return P.AC_STRETCH;
  // justify-content's `stretch` is its `normal`: the auto tracks grow.
  if (v === P.J_STRETCH) return P.J_NORMAL;
  if (v === P.J_LEFT || v === P.J_FLEX_START) return P.J_START;
  if (v === P.J_RIGHT || v === P.J_FLEX_END) return P.J_END;
  // A content baseline packs the track set on its fallback edge: the start one for a first
  // baseline, the end one for a last (CSS Align 9.3). A single container has one group, so
  // there is nothing to shift the set against.
  if (v === P.J_BASELINE) return P.J_START;
  if (v === P.J_LAST_BASELINE) return P.J_END;
  return v;
}

/**
 * A box's offset inside its area for one alignment mode, in the value `alignEdge` settles on. A
 * `safe` position that would overflow the area falls back to its start edge; an `unsafe` one
 * keeps its offset, so the box overflows both edges (CSS Align 4).
 */
export function alignOffset(mode: number, free: number, safe: boolean): number {
  if (safe && free < 0) return 0;
  if (mode === P.A_CENTER) return free / 2;
  if (mode === P.A_END) return free;
  return 0;
}

/**
 * The clamp an intrinsic contribution takes. A percentage min/max-width is cyclic when the box's
 * containing block is the box being measured: it resolves against zero (`min-width`) or counts as
 * `none` (CSS Sizing 3 §5.2.1). Where the containing block width is already known the percentage
 * resolves against it as usual.
 */
export function clampContributionW(el: Node, w: number, cbW: number, cyclic = true, zeroMaxPct = false): number {
  const adj = el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : padH(el, cbW);
  // A replaced box's min-content contribution resolves a cyclic percentage max-width against
  // zero instead of treating it as `none`.
  const max = cyclic && sizeUnit(el, P.P_MAX_WIDTH) === P.U_PCT ? (zeroMaxPct ? 0 : NaN) : sizeLenW(el, P.P_MAX_WIDTH, cbW);
  const min = cyclic && sizeUnit(el, P.P_MIN_WIDTH) === P.U_PCT ? 0 : sizeLenW(el, P.P_MIN_WIDTH, cbW);
  if (!Number.isNaN(max) && w > max + adj) w = max + adj;
  if (!Number.isNaN(min) && w < min + adj) w = min + adj;
  return Math.max(w, padH(el, cbW));
}

export function clampH(el: Node, h: number, cbW: number, cbH: number): number {
  const adj = el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : padV(el, cbW);
  const fill = stretchFill(el, false, cbH);
  // A stretch clamp is the fill-available height, which the comparison below reads as content.
  const clamp = (p: number): number => {
    if (sizeUnit(el, p) === P.U_STRETCH) return Number.isNaN(fill) ? NaN : fill - adj;
    return len(el, p, el.su[p] === P.U_PCT && isQuirks() ? quirkHeight(el, cbH) : cbH);
  };
  const max = clamp(P.P_MAX_HEIGHT);
  const min = clamp(P.P_MIN_HEIGHT);
  if (!Number.isNaN(max) && h > max + adj) h = max + adj;
  if (!Number.isNaN(min) && h < min + adj) h = min + adj;
  return Math.max(h, padV(el, cbW));
}

/**
 * The fill-available size a `stretch` value asks for: what is left of `avail` once the box's own
 * margins are taken out, with an auto margin counting as zero (CSS Sizing 4 §5). NaN when the
 * space is indefinite, which leaves `stretch` behaving as auto.
 */
function stretchFill(el: Node, horizontal: boolean, avail: number): number {
  if (Number.isNaN(avail)) return NaN;
  // The block-axis margins of a stretched box count as zero: they may collapse out of the box,
  // so the fill size doesn't reserve room for them (CSS Sizing 4 §5, and the css-sizing/stretch
  // block-height tests). In the inline axis only the auto margins are zero.
  if (!horizontal) {
    // A block-axis margin counts for the stretch size only where it cannot collapse with the
    // containing block's edge: a border or padding on that side, or a formatting context root,
    // keeps it; otherwise it collapses out and the size reserves no room for it (CSS 2.1 8.3.1,
    // CSS Sizing 4 §5, and the css-sizing/stretch block-height tests).
    const parent = el.parentElement;
    if (parent === null) return Math.max(0, avail);
    const m = (p: number): number => (sizeUnit(el, p) === P.U_AUTO ? 0 : zeroIfNaN(len(el, p, avail)));
    const keepTop = isBfcRoot(parent) || borderTop(parent) !== 0 || zeroIfNaN(len(parent, P.P_PADDING_TOP, avail)) > 0;
    const keepBottom = isBfcRoot(parent) || borderBottom(parent) !== 0 || zeroIfNaN(len(parent, P.P_PADDING_BOTTOM, avail)) > 0;
    return Math.max(0, avail - (keepTop ? m(P.P_MARGIN_TOP) : 0) - (keepBottom ? m(P.P_MARGIN_BOTTOM) : 0));
  }
  const a = horizontal ? P.P_MARGIN_LEFT : P.P_MARGIN_TOP;
  const b = horizontal ? P.P_MARGIN_RIGHT : P.P_MARGIN_BOTTOM;
  const m1 = sizeUnit(el, a) === P.U_AUTO ? 0 : zeroIfNaN(len(el, a, avail));
  const m2 = sizeUnit(el, b) === P.U_AUTO ? 0 : zeroIfNaN(len(el, b, avail));
  return Math.max(0, avail - m1 - m2);
}

/** Whether the box is a block-level box that normal flow sizes by filling its parent. */
function fillsByAuto(el: Node): boolean {
  const d = display(el);
  return d === P.D_BLOCK || d === P.D_FLOW_ROOT || d === P.D_LIST_ITEM ||
    d === P.D_FLEX || d === P.D_GRID || d === P.D_GRID_LANES;
}

/** Specified border-box width, or NaN if auto. */
export function specW(el: Node, cbW: number, cbH: number = NaN, ownH: number = NaN): number {
  const u = sizeUnit(el, P.P_WIDTH);
  if (u === P.U_STRETCH) {
    // A block-level box in normal flow already fills its containing block, floats and all; a
    // single fill size would miss the room a float leaves. Stretch only changes the boxes whose
    // auto size shrinks to fit or comes from content: flex and grid items, floats, inline-level
    // boxes, tables and out-of-flow boxes.
    const parent = el.parentElement;
    // Only a horizontal block-level box in normal flow fills its block the way `auto` does; a
    // vertical one's block size shrinks to its content when auto, so its stretch has to be the
    // fill size itself.
    if (parent !== null && !isOutOfFlow(el) && !isFloat(el) && fillsByAuto(el) && !isVerticalText(el) &&
      !isFlexContainer(parent) && !isGridContainer(parent) && !isLanesContainer(parent)) return NaN;
    return stretchFill(el, true, cbW);
  }
  if (isIntrinsicSize(u)) return intrinsicBoxW(el, u, cbW, cbH, ownH);
  const w = len(el, P.P_WIDTH, cbW);
  if (Number.isNaN(w)) return NaN;
  return el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? w : w + padH(el, cbW);
}

/** Specified border-box height, or NaN if auto or indefinite. */
export function specH(el: Node, cbW: number, cbH: number): number {
  // A stretch height counts on the containing block's definite height; an indefinite one leaves
  // the box to its content, as auto does.
  if (sizeUnit(el, P.P_HEIGHT) === P.U_STRETCH) return stretchFill(el, false, cbH);
  // Quirks mode resolves a percentage height against an ancestor's when the containing block has
  // no height of its own; a length is unaffected.
  const base = el.su[P.P_HEIGHT] === P.U_PCT ? quirkHeight(el, cbH) : cbH;
  const h = len(el, P.P_HEIGHT, base);
  if (Number.isNaN(h)) return NaN;
  return el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? h : h + padV(el, cbW);
}

/**
 * The children a box actually lays out: a `display: contents` child generates no box, so its own
 * children take its place, in order, however deep the chain goes.
 */
export function flattenContents(kids: Node[]): Node[] {
  let plain = true;
  for (const c of kids) if (display(c) === P.D_CONTENTS) plain = false;
  if (plain) return kids;
  const out: Node[] = [];
  for (const c of kids) {
    if (display(c) === P.D_CONTENTS) {
      for (const g of flattenContents(boxKids(c))) out.push(g);
    } else out.push(c);
  }
  return out;
}

export function visibleChildren(el: Node): Node[] {
  const out: Node[] = [];
  for (const c of flattenContents(boxKids(el))) if (display(c) !== P.D_NONE && !isOutOfFlow(c)) out.push(c);
  return out;
}

/** Every rendered child, in document order, including the out-of-flow ones. */
export function allChildren(el: Node): Node[] {
  const out: Node[] = [];
  for (const c of flattenContents(boxKids(el))) if (display(c) !== P.D_NONE) out.push(c);
  return out;
}

/** An out-of-flow box takes no room in the flow: absolute and fixed boxes are positioned later. */
export function isOutOfFlow(el: Node): boolean {
  const p = el.sv[P.P_POSITION];
  return p === P.POS_ABSOLUTE || p === P.POS_FIXED;
}

/** True when the box floats in its block formatting context. `float` has no effect on a flex or
 * grid item: both are blockified and placed by their container. */
export function isFloat(el: Node): boolean {
  if (el.sv[P.P_FLOAT] === P.FL_NONE) return false;
  const p = el.parentElement;
  return p === null || (!isFlexContainer(p) && !isGridContainer(p) && !isLanesContainer(p));
}

/** Whether the element lays out as a button box: a button, or an input of a button type. */
export function isButtonBox(el: Node): boolean {
  return el instanceof HTMLButtonElement ||
    (el instanceof HTMLInputElement && buttonInputType(el.type));
}

/**
 * True when the box establishes a block formatting context, so margins don't collapse across its
 * edges and its floats are its own: a float, an out-of-flow box, a flex or grid container, an inline
 * or inline-block box, a table box or cell, a scroll container, a flex or grid item, or the root
 * element.
 */
export function isBfcRoot(el: Node): boolean {
  if (el.isTextNode) return true;
  if (isOutOfFlow(el) || isFloat(el)) return true;
  // A button's box is a flow root whatever its display says: the HTML button layout rules lay it
  // out as an inline-block does, so a float inside it stays inside.
  if (isButtonBox(el)) return true;
  const d = display(el);
  if (d === P.D_INLINE || d === P.D_INLINE_BLOCK) return true;
  if (d === P.D_FLOW_ROOT) return true;
  if (isFlexContainer(el) || isGridContainer(el) || isLanesContainer(el)) return true;
  // Table boxes and table cells establish a block formatting context too.
  if (d === P.D_TABLE || d === P.D_INLINE_TABLE || d === P.D_TABLE_CELL || d === P.D_TABLE_CAPTION) return true;
  // Body's overflow went to the viewport, so its used value is visible: it roots no context.
  if ((clipsX(el) || clipsY(el)) && !propagatesBodyOverflow(el)) return true;
  // Containment makes the box the root of its own formatting: its floats and margins stay inside.
  if ((el.sv[P.P_CONTAIN] & P.CONTAIN_LAYOUT) !== 0) return true;
  if (el.parentElement === null) return true;
  const parent = el.parentElement;
  if (isFlexContainer(parent) || isGridContainer(parent) || isLanesContainer(parent)) return true;
  // An orthogonal flow — a box whose writing mode runs across its containing block's — establishes
  // an independent formatting context, so its margins stay inside it (CSS Writing Modes 3 3.1).
  return isVerticalText(el) !== isVerticalText(parent);
}

/** The overflow a box uses on its horizontal axis. */
export function overflowX(el: Node): number {
  return el.sv[P.P_OVERFLOW_X];
}

/** The overflow a box uses on its vertical axis. */
export function overflowY(el: Node): number {
  return el.sv[P.P_OVERFLOW_Y];
}

/** True when the box clips that axis: every value but `visible` does. */
export function clipsX(el: Node): boolean {
  // Paint containment clips the box's contents to its padding box, as overflow does.
  return el.sv[P.P_OVERFLOW_X] !== P.OV_VISIBLE || (el.sv[P.P_CONTAIN] & P.CONTAIN_PAINT) !== 0;
}

export function clipsY(el: Node): boolean {
  return el.sv[P.P_OVERFLOW_Y] !== P.OV_VISIBLE || (el.sv[P.P_CONTAIN] & P.CONTAIN_PAINT) !== 0;
}

/** True when that axis scrolls under a wheel: `auto` and `scroll` do, `hidden` and `clip` don't. */
export function wheelScrollsX(el: Node): boolean {
  const v = el.sv[P.P_OVERFLOW_X];
  return v === P.OV_AUTO || v === P.OV_SCROLL;
}

export function wheelScrollsY(el: Node): boolean {
  const v = el.sv[P.P_OVERFLOW_Y];
  return v === P.OV_AUTO || v === P.OV_SCROLL;
}

/** True when script can set that axis's offset: `hidden`, `auto` and `scroll` can; `clip` and `visible` can't. */
export function scriptScrollsX(el: Node): boolean {
  const v = el.sv[P.P_OVERFLOW_X];
  return v === P.OV_HIDDEN || v === P.OV_AUTO || v === P.OV_SCROLL;
}

export function scriptScrollsY(el: Node): boolean {
  const v = el.sv[P.P_OVERFLOW_Y];
  return v === P.OV_HIDDEN || v === P.OV_AUTO || v === P.OV_SCROLL;
}

/** A box that can be scrolled, by script or by pointing device: any axis but `visible` or `clip`. */
export function isScroller(el: Node): boolean {
  return scriptScrollsX(el) || scriptScrollsY(el);
}

/**
 * Does the box ignore its content when sizing its inline axis? `container-type: inline-size` and
 * `size` both contain the inline axis, so the box's content adds nothing to its intrinsic width.
 */
export function containsInline(el: Node): boolean {
  if (el.isTextNode) return false;
  return el.sv[P.P_CONTAINER_TYPE] !== P.CT_NORMAL || hasSizeContainment(el) ||
    (el.sv[P.P_CONTAIN] & P.CONTAIN_INLINE_SIZE) !== 0;
}

/**
 * Does the box ignore its content when sizing its block axis? A size container or `contain: size`
 * does: its contents make it no taller.
 */
export function containsBlock(el: Node): boolean {
  if (el.isTextNode) return false;
  return el.sv[P.P_CONTAINER_TYPE] === P.CT_SIZE || hasSizeContainment(el) ||
    (el.sv[P.P_CONTAIN] & P.CONTAIN_BLOCK_SIZE) !== 0;
}

/**
 * With the root's overflow visible in both axes, body's overflow goes to the viewport, so body
 * itself doesn't scroll or clip and its children's margins collapse through it as usual (CSS
 * Overflow 3 §3.3: the body's values are used only when the root's are visible on both axes).
 */
export function propagatesBodyOverflow(el: Node): boolean {
  const p = el.parentElement;
  return el.tagName === "BODY" && p !== null && p.parentElement === null &&
    p.sv[P.P_OVERFLOW_X] === P.OV_VISIBLE && p.sv[P.P_OVERFLOW_Y] === P.OV_VISIBLE;
}

/**
 * The overflow the viewport itself uses on an axis: the root element's, or the body's when the
 * root's is visible on both axes, since that is the one that propagates to the viewport (CSS
 * Overflow 3 §3.3).
 */
export function viewportOverflowX(): number {
  const root = document.documentElement;
  const ov = root.sv[P.P_OVERFLOW_X];
  if (ov !== P.OV_VISIBLE || root.sv[P.P_OVERFLOW_Y] !== P.OV_VISIBLE) return ov;
  const body = document.body;
  return body !== null ? body.sv[P.P_OVERFLOW_X] : P.OV_VISIBLE;
}

export function viewportOverflowY(): number {
  const root = document.documentElement;
  const ov = root.sv[P.P_OVERFLOW_Y];
  if (ov !== P.OV_VISIBLE || root.sv[P.P_OVERFLOW_X] !== P.OV_VISIBLE) return ov;
  const body = document.body;
  return body !== null ? body.sv[P.P_OVERFLOW_Y] : P.OV_VISIBLE;
}

/** True when the page can scroll on that axis: the viewport clips its overflow but doesn't scroll it. */
export function viewportScrollsX(): boolean {
  const ov = viewportOverflowX();
  return ov !== P.OV_HIDDEN && ov !== P.OV_CLIP;
}

export function viewportScrollsY(): boolean {
  const ov = viewportOverflowY();
  return ov !== P.OV_HIDDEN && ov !== P.OV_CLIP;
}

/** Whether the box contains its own size: its contents don't make it any bigger. */
export function hasSizeContainment(el: Node): boolean {
  return (el.sv[P.P_CONTAIN] & P.CONTAIN_SIZE) !== 0;
}

export function hasOwnText(el: Node): boolean {
  if (el.ownText === "") return false;
  // A style carrier — a ::first-line, ::first-letter or ::backdrop box — is no content: the
  // element's own text is still its own.
  for (const c of boxKids(el)) {
    if (c.pseudoKind !== P.PE_FIRST_LINE && c.pseudoKind !== P.PE_FIRST_LETTER &&
      c.pseudoKind !== P.PE_BACKDROP && c.pseudoKind !== P.PE_SELECTION &&
      c.pseudoKind !== P.PE_HIGHLIGHT && c.pseudoKind !== P.PE_TARGET_TEXT) return false;
  }
  return true;
}

/** True for an <svg> element, namespace prefix or not: the box an inline SVG paints as. */
export function isSvgElement(el: Node): boolean {
  const name = el.localName;
  const cut = name.lastIndexOf(":");
  return (cut < 0 ? name : name.slice(cut + 1)) === "svg";
}

/** A replaced element: its content is an image, with its own intrinsic size. */
export function isReplaced(el: Node): boolean {
  return el.localName === "img" || el.localName === "canvas" || el.localName === "video" || isSvgElement(el) ||
    // An <embed> or an <object> holding a picture is replaced by it, as an <img> is.
    ((el.localName === "embed" || el.localName === "object") && el.imagePath !== "");
}

/** A length attribute's px value, a percentage resolved against `base`. */
function svgLengthAttr(el: Element, name: string, base: number): number | null {
  const raw = el.getAttribute(name);
  if (raw === null) return null;
  const s = raw.trim();
  const n = parseFloat(s);
  if (!Number.isFinite(n)) return null;
  return s.endsWith("%") ? base * n / 100 : n;
}

/** Intrinsic content size [width, height] of a replaced element; [0, 0] when it has no image. */
export function intrinsicSize(el: Node): number[] {
  // A video is as big as its picture, 300 by 150 before there is one.
  if (el.localName === "video") {
    const v = el as any;
    return [v.videoWidth > 0 ? v.videoWidth : 300, v.videoHeight > 0 ? v.videoHeight : 150];
  }
  // A canvas is sized by its width and height attributes, 300 by 150 by default.
  if (el.localName === "canvas") return [(el as HTMLCanvasElement).width, (el as HTMLCanvasElement).height];
  // An inline <svg> takes its intrinsic size from its width and height attributes, and is 300 by
  // 150 without them, as SVG says; a length of zero is an intrinsic size of zero.
  if (isSvgElement(el)) {
    const e = el as Element;
    const w = svgLengthAttr(e, "width", viewport.w);
    const h = svgLengthAttr(e, "height", viewport.h);
    return [w === null ? 300 : w, h === null ? 150 : h];
  }
  return imageSize(el.imagePath, orientedImage(el));
}

/**
 * Relative-positioning shift for an element laid out in a cbW × cbH containing block.
 * `left` wins over `right` (and `top` over `bottom`), as in LTR CSS.
 */
export function relativeOffset(el: Node, cbW: number, cbH: number): number[] {
  if (el.sv[P.P_POSITION] !== P.POS_RELATIVE) return [0, 0];
  if (turned(el)) {
    // The offsets are physical, so they resolve against the physical axis they move along: left
    // and right against the width, top and bottom against the height. The shift then turns into
    // the layout's axes, where a move to the right walks back along the block axis.
    const l = lenPhys(el, P.P_LEFT, cbH);
    const r = lenPhys(el, P.P_RIGHT, cbH);
    const t = lenPhys(el, P.P_TOP, cbW);
    const b = lenPhys(el, P.P_BOTTOM, cbW);
    const px = !Number.isNaN(l) ? l : !Number.isNaN(r) ? -r : 0;
    const py = !Number.isNaN(t) ? t : !Number.isNaN(b) ? -b : 0;
    return [py, turnedRl(el) ? -px : px];
  }
  const l = len(el, P.P_LEFT, cbW);
  const r = len(el, P.P_RIGHT, cbW);
  const t = len(el, P.P_TOP, cbH);
  const b = len(el, P.P_BOTTOM, cbH);
  return [
    !Number.isNaN(l) ? l : !Number.isNaN(r) ? -r : 0,
    !Number.isNaN(t) ? t : !Number.isNaN(b) ? -b : 0,
  ];
}

/**
 * Relative shift of `e` and of the inline boxes around it up to the block container `stop`: a
 * relatively positioned inline box moves its text and its inline descendants with it.
 */
export function relativeOffsetSum(e: Node | null, stop: Node, cbW: number, cbH: number = NaN): number[] {
  let x = 0;
  let y = 0;
  let a = e;
  while (a !== null && a !== stop) {
    const off = relativeOffset(a, cbW, cbH);
    x += off[0];
    y += off[1];
    // A text run has no box of its own; keep walking through the inlines that hold it.
    if (!a.isTextNode && a.sv[P.P_DISPLAY] !== P.D_INLINE) break;
    a = a.parentElement;
  }
  return [x, y];
}

/** Applies the element's relative shift after its normal-flow position is set. */
export function place(el: Node): void {
  el.x += el.relX;
  el.y += el.relY;
}

/** Whether an element's inline direction runs against the frame's — the direction a vertical
 *  box lays its inline axis down the page. A right-to-left direction turns it around, and
 *  sideways-lr starts from the bottom rather than the top (CSS Writing Modes 4). */
export function inlineMirrored(el: Node): boolean {
  const wm = usedWritingMode(el);
  return wm === P.WM_SIDEWAYS_LR ? !isRtl(el) : isRtl(el);
}
