// Font metrics, intrinsic (max-content) widths and wrapping of an element's own text.

import * as P from "../../shared/props.ts";
import { rootFontSize } from "../root-size.ts";
import { Node, Element, HTMLInputElement, HTMLOptionElement, HTMLSelectElement, HTMLTextAreaElement, controlKind, CONTROL_CHECKBOX, CONTROL_RADIO, CONTROL_RANGE, buttonInputType, boxKids } from "../dom.ts";
import { exprLength, isFlexContainer, isGridContainer, isLanesContainer, isRowDirection, isVerticalText, lineHeightPx, fontKey, fontDeviceMetrics, lineAlign, lastLineAlign } from "../style.ts";
import { hostBackingScale, hostFontXHeight, hostMeasureText } from "../host.ts";
import { isQuirks, quirkHeight } from "../quirk.ts";
import { evalExpr } from "../../shared/css/length-exprs.ts";
import { capitalizeText } from "../../shared/css/case.ts";
import { alignEdge, aspectH, aspectRatio, aspectW, clampContributionW, clampH, clampW, clipsX, containsInline, display, hasOwnText, intrinsicSize, isFloat, isIntrinsicSize, isOutOfFlow, isReplaced, len, marginH, measure, padH, padV, specH, specW, viewport, visibleChildren, zeroIfNaN } from "./box-model.ts";
import { Piece, autoClamp, balanceLines, breakLines, breaksAnywhere, hasInlineContent, inlineMaxContent, inlineMinContent, isInlineLevel, itemTextSpacing, measurePieces, piecesMaxContent, piecesMinContent, prettyLines, pushText, splitFlow, trailingSeparators } from "./inline.ts";
import { hasTableInternalChild, isIgnorableWhitespace, isTableDisplay, isTableInternal, tableMaxContentWidth, tableRunContentWidth } from "./table.ts";
import { gridIntrinsicWidth } from "./grid.ts";
import { verticalContentWidth } from "./box.ts";
import { incremental, layoutEpoch } from "../invalidation.ts";

// ---------------------------------------------------------------------------
// Intrinsic sizes

const metricsCache: Map<string, number[]> = new Map();

// Text widths measured with letter and word spacing, keyed the same way (see textWidth).
const spacedCache: Map<string, number> = new Map();

/**
 * Forgets the font boxes and text widths measured for a font key: its family id is numbered anew
 * by each page, so a batch that renders several pages in one process starts each with an empty
 * cache. A stale hit would measure a page's text with the previous page's face.
 */
export function resetMetricsCache(): void {
  metricsCache.clear();
  spacedCache.clear();
}

/** [ascent, descent, x-height] of the font an element's text uses. */
export function fontMetrics(el: Node): number[] {
  const size = el.sv[P.P_FONT_SIZE];
  const key = fontKey(el);
  const scale = hostBackingScale();
  const k = `${size}|${key}|${scale}`;
  const hit = metricsCache.get(k);
  if (hit !== undefined) return hit;
  // Ascent and descent are whole device pixels (see fontDeviceMetrics); x-height isn't a line
  // metric and stays as the font reports it.
  const m = fontDeviceMetrics(size, key);
  const out = size > 0
    ? [m[0] / scale, m[1] / scale, hostFontXHeight(size, key)]
    : [0, 0, 0];
  metricsCache.set(k, out);
  return out;
}

/**
 * Distance from the top of an element's line-height box to its baseline. The leading is split
 * above and below the font's box, and Chrome floors the upper half when it isn't a whole device
 * pixel, so the baseline lands on a device pixel like the ascent does.
 */
export function baselineOffset(el: Node): number {
  const m = fontDeviceMetrics(el.sv[P.P_FONT_SIZE], fontKey(el));
  const scale = hostBackingScale();
  const room = lineHeightPx(el) * scale - m[0] - m[1];
  return (m[0] + Math.floor(room / 2)) / scale;
}

/**
 * The content-box height a box's descendants resolve their percentage heights against, or NaN
 * when it has none: its own definite height, or the one its preferred aspect ratio gives it at a
 * definite width. `cbH` is the containing block the box's own percentage height resolves against.
 */
/**
 * The definite height a column-wrap container's flex lines are packed within: its own, or the
 * maximum it takes when that is all it has (CSS Flexbox 9.9.1). NaN when neither is definite.
 */
function wrapBasis(el: Node, cbW: number, cbH: number): number {
  const h = heightBasis(el, cbW, cbH);
  if (!Number.isNaN(h)) return h;
  const max = len(el, P.P_MAX_HEIGHT, cbH);
  return Number.isNaN(max) ? NaN : max;
}

function heightBasis(el: Node, cbW: number, cbH: number): number {
  let h = specH(el, cbW, cbH);
  if (Number.isNaN(h) && aspectRatio(el) > 0) {
    const w = specW(el, cbW);
    if (!Number.isNaN(w)) h = aspectH(el, w, cbW);
  }
  // A row item with an auto height stretches to fill its line, and that height is what its
  // content's percentage heights resolve against.
  if (Number.isNaN(h) && (stretchedInRow(el, cbH) || stretchedInGrid(el, cbH))) h = cbH;
  // Quirks mode passes an auto height down from the nearest ancestor that has one.
  if (Number.isNaN(h) && isQuirks()) h = quirkHeight(el, cbH);
  return Number.isNaN(h) ? NaN : Math.max(0, h - padV(el, cbW));
}

/** Whether a box's auto height is the height of the grid area it stretches into. */
function stretchedInGrid(el: Node, cbH: number): boolean {
  if (Number.isNaN(cbH) || el.su[P.P_HEIGHT] !== P.U_AUTO) return false;
  const parent = el.parentElement;
  if (parent === null || !isGridContainer(parent)) return false;
  const self = el.sv[P.P_ALIGN_SELF];
  let mode = self === P.A_AUTO ? parent.sv[P.P_ALIGN_ITEMS] : self;
  // `normal` stretches a box that has no preferred aspect ratio of its own (CSS Align 5.2).
  if (mode === P.A_NORMAL) mode = isReplaced(el) || aspectRatio(el) > 0 ? P.A_START : P.A_STRETCH;
  if (alignEdge(mode) !== P.A_STRETCH) return false;
  if (el.su[P.P_MARGIN_TOP] === P.U_AUTO || el.su[P.P_MARGIN_BOTTOM] === P.U_AUTO) return false;
  return true;
}

/** Whether a box's auto height is the height of the flex line it stretches into. */
function stretchedInRow(el: Node, cbH: number): boolean {
  if (Number.isNaN(cbH) || el.su[P.P_HEIGHT] !== P.U_AUTO) return false;
  const parent = el.parentElement;
  if (parent === null || !isFlexContainer(parent) || !isRowDirection(parent.sv[P.P_FLEX_DIRECTION])) return false;
  const self = el.sv[P.P_ALIGN_SELF];
  const mode = alignEdge(self === P.A_AUTO ? parent.sv[P.P_ALIGN_ITEMS] : self);
  if (mode !== P.A_STRETCH && mode !== P.A_NORMAL) return false;
  if (el.su[P.P_MARGIN_TOP] === P.U_AUTO || el.su[P.P_MARGIN_BOTTOM] === P.U_AUTO) return false;
  return true;
}

/**
 * The content width a replaced box takes from a percentage height, resolved against the height
 * `cbH` of its containing block, or NaN when its height isn't one.
 */
function replacedHeightWidth(el: Node, cbW: number, cbH: number): number {
  if (el.su[P.P_HEIGHT] !== P.U_PCT) return NaN;
  const h = specH(el, cbW, cbH);
  if (Number.isNaN(h)) return NaN;
  return aspectW(el, h, cbW) - padH(el, cbW);
}

/**
 * The intrinsic inline sizes already worked out for a box. A box's min-content and max-content
 * widths depend only on its style, its content and the sizes it asks about, and nested containers
 * ask the same questions again and again — a grid or flex measures a child for its contribution
 * and then lays it out, at every level of nesting — so the answers are kept, which is where the
 * exponential cost of deeply nested containers came from.
 *
 * The answers live on the node as numbers (`szK`, SZ_STRIDE per entry: the kind with its flags,
 * the three sizes asked about, the answer). Without incremental layout they last one layout
 * pass: the pass counter is bumped by layoutRoot, and nothing survives a style, DOM or viewport
 * change. With it they last until the box or something inside it is marked dirty, which empties
 * the box's list and its ancestors' (markLayoutDirty), or until the layout epoch moves.
 */
let sizeGeneration = 0;
export function bumpSizeCache(): void {
  sizeGeneration++;
}
const SZ_STRIDE = 5;
/** Entries a box keeps before it starts over; a box is asked a handful of distinct questions. */
const SZ_MAX = 24;
const SZ_MAX_W = 1;
const SZ_CMAX_W = 2;
const SZ_IMAX_W = 3;
const SZ_IMIN_W = 4;
const SZ_MIN_W = 5;
const SZ_CMIN_W = 6;
function sizeFlags(a: boolean, b: boolean, c: boolean, d: boolean): number {
  return (a ? 8 : 0) | (b ? 16 : 0) | (c ? 32 : 0) | (d ? 64 : 0);
}
function sameSize(a: number, b: number): boolean {
  return a === b || (a !== a && b !== b);
}
/** The generation a box's entries must carry to be current. */
function sizeEpoch(): number {
  return incremental.on ? -1 - layoutEpoch.n : sizeGeneration;
}
/** Index of the entry for this question in the box's list, or -1. */
function sizeAt(el: Node, key: number, w: number, h: number, own: number): number {
  if (el.szEpoch !== sizeEpoch()) {
    el.szEpoch = sizeEpoch();
    el.szN = 0;
    return -1;
  }
  const k = el.szK;
  for (let i = 0, at = 0; i < el.szN; i++, at += SZ_STRIDE) {
    if (k[at] === key && sameSize(k[at + 1], w) && sameSize(k[at + 2], h) && sameSize(k[at + 3], own)) return at + 4;
  }
  return -1;
}
function sizeKeep(el: Node, key: number, w: number, h: number, own: number, v: number): number {
  // The answer may have been worked out while an inner question emptied the list (a new epoch),
  // so it goes in against the current one.
  if (el.szEpoch !== sizeEpoch()) {
    el.szEpoch = sizeEpoch();
    el.szN = 0;
  }
  if (el.szN >= SZ_MAX) el.szN = 0;
  const at = el.szN * SZ_STRIDE;
  const k = el.szK;
  if (k.length < at + SZ_STRIDE) {
    k.push(key, w, h, own, v);
  } else {
    k[at] = key;
    k[at + 1] = w;
    k[at + 2] = h;
    k[at + 3] = own;
    k[at + 4] = v;
  }
  el.szN++;
  return v;
}

/**
 * Asks a box's intrinsic size question again from a kept entry, for a relayout root comparing
 * its answers after its content changed. The key is the kind and flags sizeAt kept.
 */
export function sizeAgain(el: Node, key: number, w: number, h: number, own: number): number {
  const kind = key & 7;
  const a = (key & 8) !== 0;
  const b = (key & 16) !== 0;
  const c = (key & 32) !== 0;
  const d = (key & 64) !== 0;
  if (kind === SZ_MAX_W) return maxContentWidth(el, w, h, own, a, b, c);
  if (kind === SZ_CMAX_W) return contentMaxWidth(el, w, h, own, a, c);
  if (kind === SZ_IMAX_W) return intrinsicMaxWidth(el, w, h);
  if (kind === SZ_IMIN_W) return intrinsicMinWidth(el, w, h);
  if (kind === SZ_MIN_W) return minContentWidth(el, w, h, own, a, b, c);
  return contentMinWidth(el, w, d, h, own, a, c);
}

/** The current generation of a box's intrinsic size entries. */
export function sizeGenerationNow(): number {
  return sizeEpoch();
}
export const SIZE_STRIDE = SZ_STRIDE;

/** Max-content border-box width (no wrapping). */
export function maxContentWidth(el: Node, cbW: number, cbH: number = NaN, ownH: number = NaN, transfer = true, cyclic = false, along = false): number {
  const key = SZ_MAX_W | sizeFlags(transfer, cyclic, along, false);
  const at = sizeAt(el, key, cbW, cbH, ownH);
  if (at >= 0) return el.szK[at];
  return sizeKeep(el, key, cbW, cbH, ownH, maxContentWidthInner(el, cbW, cbH, ownH, transfer, cyclic, along));
}

function maxContentWidthInner(el: Node, cbW: number, cbH: number = NaN, ownH: number = NaN, transfer = true, cyclic = false, along = false): number {
  // A contribution is clamped by the box's own min/max widths, where a cyclic percentage leaves
  // the width alone (CSS Sizing 3 §5.2.1). A width keyword contributes what it names: `fit-content`
  // has no space to fit into while a contribution is measured, so it is the max-content width.
  const u = el.su[P.P_WIDTH];
  let w: number;
  if (u === P.U_MIN_CONTENT) w = contentMinWidth(el, cbW, true, cbH, ownH, transfer, along);
  else if (isIntrinsicSize(u)) w = contentMaxWidth(el, cbW, cbH, ownH, transfer, along);
  else {
    const spec = specW(el, cbW);
    w = Number.isNaN(spec) ? contentMaxWidth(el, cbW, cbH, ownH, transfer, along) : spec;
  }
  const out = clampContributionW(el, w, cbW, cyclic);
  // A table can't be narrower than its columns, so its max-width never caps its contribution
  // below its min-content width (CSS Tables 3).
  if (isTableDisplay(display(el))) return Math.max(out, contentMinWidth(el, cbW, true, cbH, ownH, transfer));
  return out;
}

/**
 * A min-height or max-height as a border-box height, or NaN when it leaves the height alone. An
 * intrinsic keyword on a replaced box names the block size the box takes at its inline size: the
 * natural size, given the box's own proportions.
 */
function sizedHeight(el: Node, p: number, cbW: number, cbH: number): number {
  const adjV = el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : padV(el, cbW);
  const u = el.su[p];
  if (isIntrinsicSize(u)) {
    if (!isReplaced(el)) return NaN;
    if (!(aspectRatio(el) > 0)) return intrinsicSize(el)[1] + padV(el, cbW);
    const spec = specW(el, cbW);
    const w = Number.isNaN(spec) ? intrinsicSize(el)[0] + padH(el, cbW) : clampW(el, spec, cbW);
    return aspectH(el, w, cbW);
  }
  const v = len(el, p, cbH);
  return Number.isNaN(v) ? NaN : v + adjV;
}

/**
 * The content width a definite block size transfers through the box's preferred aspect ratio, or
 * NaN when the box has no ratio or no definite height to transfer (CSS Sizing 4 §5.1). A box whose
 * min-width is `auto` has an automatic minimum that the transferred width can't undercut, so its
 * content's own min-content width floors it.
 */
function ratioContentWidth(el: Node, cbW: number, cbH: number): number {
  if (!(aspectRatio(el) > 0)) return NaN;
  const adjV = el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : padV(el, cbW);
  let h = specH(el, cbW, cbH);
  if (Number.isNaN(h)) return NaN;
  const min = sizedHeight(el, P.P_MIN_HEIGHT, cbW, cbH);
  if (!Number.isNaN(min) && h < min) h = min;
  const max = sizedHeight(el, P.P_MAX_HEIGHT, cbW, cbH);
  if (!Number.isNaN(max) && h > max) h = max;
  const w = aspectW(el, h, cbW);
  if (!isReplaced(el) && el.su[P.P_MIN_WIDTH] === P.U_AUTO) {
    // The automatic minimum is the content's own min-content width, measured with the box's
    // definite height still standing as the basis its content's percentage heights resolve against.
    return Math.max(w, contentMinWidth(el, cbW, false, cbH));
  }
  return w;
}

/**
 * Clamps an intrinsic width by the min/max block sizes the ratio transfers to the inline axis: a
 * max-height caps the width the ratio would give it, and a min-height floors it.
 */
function transferRatioWidth(el: Node, w: number, cbW: number, cbH: number = NaN): number {
  if (!(aspectRatio(el) > 0)) return w;
  const adjV = el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : padV(el, cbW);
  const max = sizedHeight(el, P.P_MAX_HEIGHT, cbW, cbH);
  if (!Number.isNaN(max)) {
    const t = aspectW(el, max, cbW);
    if (w > t) w = t;
  }
  const min = sizedHeight(el, P.P_MIN_HEIGHT, cbW, cbH);
  if (!Number.isNaN(min)) {
    let t = aspectW(el, min, cbW);
    // The transferred minimum is capped by a definite max-width, which the box can't exceed
    // (CSS Sizing 4 §4.4). An indefinite one leaves it alone.
    const cap = len(el, P.P_MAX_WIDTH, cbW) + (el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : padH(el, cbW));
    if (!Number.isNaN(cap) && t > cap) t = cap;
    if (w < t) w = t;
  }
  return w;
}

/**
 * The inline size one item of a row flex container contributes to the container's intrinsic
 * width: its own intrinsic width, or, for an item with a preferred ratio and no width of its own,
 * the width the cross size it is stretched to gives it (CSS Flexbox 9.2.3). A definite height is
 * that cross size, and a percentage height resolves against the container's own.
 */
function rowItemWidth(el: Node, c: Node, cbW: number, basis: number, min: boolean): number {
  const own = min ? intrinsicMinWidth(c, cbW, basis) : intrinsicMaxWidth(c, cbW, basis);
  if (aspectRatio(c) <= 0 || c.su[P.P_WIDTH] !== P.U_AUTO) return own;
  if (Number.isNaN(basis)) return own;
  let h = specH(c, cbW, basis);
  if (Number.isNaN(h) && c.su[P.P_HEIGHT] === P.U_AUTO) {
    // An auto cross size that the line stretches takes the container's definite height.
    const self = c.sv[P.P_ALIGN_SELF];
    const eff = self === P.A_AUTO ? el.sv[P.P_ALIGN_ITEMS] : self;
    if (eff === P.A_NORMAL || eff === P.A_STRETCH) h = basis;
  }
  if (Number.isNaN(h)) return own;
  return Math.max(own, aspectW(c, clampH(c, h, cbW, basis), cbW));
}

/**
 * The max-content content width of an element, whatever its own specified width, plus its
 * padding and border: a flex item's flex base size, which ignores its own min/max-width.
 */
export function contentMaxWidth(el: Node, cbW: number, cbH: number = NaN, ownH: number = NaN, transfer = true, along = false): number {
  const key = SZ_CMAX_W | sizeFlags(transfer, false, along, false);
  const at = sizeAt(el, key, cbW, cbH, ownH);
  if (at >= 0) return el.szK[at];
  return sizeKeep(el, key, cbW, cbH, ownH, contentMaxWidthInner(el, cbW, cbH, ownH, transfer, along));
}

function contentMaxWidthInner(el: Node, cbW: number, cbH: number = NaN, ownH: number = NaN, transfer = true, along = false): number {
  const ratio = ratioContentWidth(el, cbW, cbH);
  if (!Number.isNaN(ratio)) return ratio;
  // Inline-size containment: the content adds nothing to the box's inline size.
  if (containsInline(el) && !isReplaced(el) && !isTableDisplay(display(el))) {
    const held = clampW(el, padH(el, cbW), cbW);
    return transfer ? transferRatioWidth(el, held, cbW, cbH) : held;
  }
  // A vertical box's width is its block size, measured by laying the content out at the inline
  // size the box has (see verticalContentWidth).
  if (!along && isVerticalText(el) && !isReplaced(el)) {
    const vw = verticalContentWidth(el, cbW, cbH, ownH);
    if (!Number.isNaN(vw)) return transfer ? transferRatioWidth(el, vw, cbW, cbH) : vw;
  }
  // The box's own height is what its content's percentage heights resolve against, given here
  // when the caller knows it better than the box's own properties do.
  const basis = Number.isNaN(ownH) ? heightBasis(el, cbW, cbH) : ownH;
  let content = 0;
  if (isReplaced(el)) {
    content = intrinsicSize(el)[0];
    const held = replacedHeightWidth(el, cbW, cbH);
    if (!Number.isNaN(held)) content = held;
  } else if (isGridContainer(el) || isLanesContainer(el)) {
    // A grid's (or a lanes container's) widths come from its tracks, not from its children as a block.
    const w = clampW(el, gridIntrinsicWidth(el, cbW, basis, false, cbH) + padH(el, cbW), cbW);
    return transfer ? transferRatioWidth(el, w, cbW, cbH) : w;
  } else if (el instanceof HTMLInputElement) {
    // A checkbox and a radio are their own small box, a range its own width, a button input the
    // width of its label, and an empty text field the width of ~20 characters.
    const kind = controlKind(el.type);
    content = kind === CONTROL_CHECKBOX || kind === CONTROL_RADIO ? 13 : kind === CONTROL_RANGE ? 129
      : buttonInputType(el.type) ? textWidth(el, el.displayText) : 150;
  } else if (el instanceof HTMLSelectElement) {
    // A select is as wide as the widest label it holds, since the label it shows is one of them.
    content = selectMaxContent(el);
  } else if (el instanceof HTMLTextAreaElement) {
    // cols is the field's width in characters, and a column is the advance of "0" in its font.
    content = columns(el) * textWidth(el, "0");
  } else if (hasOwnText(el)) {
    content = ownTextWidth(el);
  } else if (isTableDisplay(display(el))) {
    // A table's preferred width is the sum of its columns, not the widest of its parts.
    const table = tableMaxContentWidth(el, cbW);
    return transfer ? transferRatioWidth(el, table, cbW, cbH) : table;
  } else if (hasTableInternalChild(el)) {
    // Table parts outside a table form anonymous tables, which sum their columns too.
    content = tableRunsWidth(el, cbW, false);
  } else if (!isFlexContainer(el) && hasInlineContent(el)) {
    content = hasBlockLevelChild(el) ? anonBlockWidth(el, cbW, basis, false) : inlineMaxContent(el, cbW, basis);
  } else if (isFlexContainer(el) && !isRowDirection(el.sv[P.P_FLEX_DIRECTION]) &&
    el.sv[P.P_FLEX_WRAP] !== P.FW_NOWRAP && !isVerticalText(el) && !Number.isNaN(wrapBasis(el, cbW, basis)) && wrapBasis(el, cbW, basis) > 0) {
    // A column-wrap container's max-content width is the sum of its flex lines' widths: the
    // container's definite height decides how many items a line (column) takes, and a line is as
    // wide as its widest item (CSS Flexbox 9.9.1). Items are visited in their paint order, so
    // `order` decides which ones share a line.
    const wrap = wrapBasis(el, cbW, basis);
    const gapMain = zeroIfNaN(len(el, P.P_ROW_GAP, wrap));
    const ordered = visibleChildren(el).slice().sort((a, b) => a.sv[P.P_ORDER] - b.sv[P.P_ORDER]);
    let used = 0;
    let colWidth = 0;
    let sum = 0;
    for (const k of ordered) {
      const described = len(k, P.P_FLEX_BASIS, wrap);
      const outerMain = (Number.isNaN(described) ? zeroIfNaN(specH(k, cbW, wrap)) : described) +
        zeroIfNaN(len(k, P.P_MARGIN_TOP, wrap)) + zeroIfNaN(len(k, P.P_MARGIN_BOTTOM, wrap));
      if (used > 0 && used + outerMain > wrap) {
        sum += colWidth;
        colWidth = 0;
        used = 0;
      }
      colWidth = Math.max(colWidth, intrinsicMaxWidth(k, wrap, wrap) + marginH(k, 0));
      used += outerMain + (used > 0 ? gapMain : 0);
    }
    content = sum + colWidth;
  } else {
    const kids = visibleChildren(el);
    const dir = el.sv[P.P_FLEX_DIRECTION];
    const row = isFlexContainer(el) && isRowDirection(dir);
    // Floats sit side by side until one clears a side a float before it is on: that one starts a
    // new row, and the widest row is what the max-content width takes (CSS 2.1 9.5) — a float
    // that clears is never beside the float it clears.
    let floatRow = 0;
    let widestRow = 0;
    let leftFloat = false;
    let rightFloat = false;
    for (let i = 0; i < kids.length; i++) {
      // A child's percentage margins resolve against this box's own width, which is what is being
      // measured: they are cyclic, and a cyclic percentage resolves against zero here.
      let outer = (row ? rowItemWidth(el, kids[i], cbW, basis, false) : intrinsicMaxWidth(kids[i], cbW, basis)) + marginH(kids[i], 0);
      if (row) {
        // A definite flex-basis is the item's max-content contribution, never below what its
        // content cannot break: the basis replaces the content's own preferred size (CSS Flexbox
        // 9.9.1). Only an auto basis contributes the content's max-content size.
        const base = len(kids[i], P.P_FLEX_BASIS, cbW);
        if (!Number.isNaN(base)) outer = Math.max(intrinsicMinWidth(kids[i], cbW, basis), base) + marginH(kids[i], 0);
        content += outer + (i > 0 ? zeroIfNaN(len(el, P.P_COLUMN_GAP, cbW)) : 0);
      } else if (isFloat(kids[i])) {
        const clear = kids[i].sv[P.P_CLEAR];
        const side = kids[i].sv[P.P_FLOAT];
        if ((clear === P.CL_LEFT && leftFloat) || (clear === P.CL_RIGHT && rightFloat) ||
          (clear === P.CL_BOTH && (leftFloat || rightFloat))) {
          widestRow = Math.max(widestRow, floatRow);
          floatRow = 0;
          leftFloat = false;
          rightFloat = false;
        }
        floatRow += outer;
        if (side === P.FL_LEFT) leftFloat = true;
        else if (side === P.FL_RIGHT) rightFloat = true;
      } else content = Math.max(content, outer);
    }
    content += Math.max(widestRow, floatRow);
  }
  const w = content + padH(el, cbW);
  return transfer ? transferRatioWidth(el, w, cbW, cbH) : w;
}

/**
 * A child's max-content width for its parent's intrinsic size. A percentage width counts as auto
 * unless it belongs to a table, whose grid is laid out within the space available to it.
 */
export function intrinsicMaxWidth(el: Node, cbW: number, cbH: number = NaN): number {
  const key = SZ_IMAX_W | 0;
  const at = sizeAt(el, key, cbW, cbH, NaN);
  if (at >= 0) return el.szK[at];
  return sizeKeep(el, key, cbW, cbH, NaN, intrinsicMaxWidthInner(el, cbW, cbH));
}

function intrinsicMaxWidthInner(el: Node, cbW: number, cbH: number = NaN): number {
  // The box sits inside the one whose width is being measured, so its percentage min/max-width is
  // cyclic there.
  if (el.su[P.P_WIDTH] === P.U_PCT && !isTableDisplay(display(el))) return contentMaxWidth(el, cbW, cbH);
  return maxContentWidth(el, cbW, cbH, NaN, true, true);
}

/** The same for min-content. */
export function intrinsicMinWidth(el: Node, cbW: number, cbH: number = NaN): number {
  const key = SZ_IMIN_W | 0;
  const at = sizeAt(el, key, cbW, cbH, NaN);
  if (at >= 0) return el.szK[at];
  return sizeKeep(el, key, cbW, cbH, NaN, intrinsicMinWidthInner(el, cbW, cbH));
}

function intrinsicMinWidthInner(el: Node, cbW: number, cbH: number = NaN): number {
  if (el.su[P.P_WIDTH] === P.U_PCT) return contentMinWidth(el, cbW, true, cbH);
  return minContentWidth(el, cbW, cbH, NaN, true, true);
}

/** Min-content border-box width: no narrower than the widest thing that can't be broken. */
export function minContentWidth(el: Node, cbW: number, cbH: number = NaN, ownH: number = NaN, transfer = true, cyclic = false, along = false): number {
  const key = SZ_MIN_W | sizeFlags(transfer, cyclic, along, false);
  const at = sizeAt(el, key, cbW, cbH, ownH);
  if (at >= 0) return el.szK[at];
  return sizeKeep(el, key, cbW, cbH, ownH, minContentWidthInner(el, cbW, cbH, ownH, transfer, cyclic, along));
}

function minContentWidthInner(el: Node, cbW: number, cbH: number = NaN, ownH: number = NaN, transfer = true, cyclic = false, along = false): number {
  const replaced = isReplaced(el);
  const u = el.su[P.P_WIDTH];
  let w: number;
  if (u === P.U_MAX_CONTENT) w = contentMaxWidth(el, cbW, cbH, ownH, transfer, along);
  else if (isIntrinsicSize(u)) w = contentMinWidth(el, cbW, true, cbH, ownH, transfer, along);
  else {
    const spec = specW(el, cbW);
    w = Number.isNaN(spec) ? contentMinWidth(el, cbW, true, cbH, ownH, transfer, along) : spec;
  }
  const out = clampContributionW(el, w, cbW, cyclic, replaced);
  if (isTableDisplay(display(el))) return Math.max(out, contentMinWidth(el, cbW, true, cbH, ownH, transfer));
  return out;
}

/**
 * The min-content border-box width of an element's content, whatever its own specified width.
 * `allowRatio` lets a preferred aspect ratio transfer a definite height into that width; the box's
 * automatic minimum is the content's own, with no transfer.
 */
export function contentMinWidth(el: Node, cbW: number, allowRatio = true, cbH: number = NaN, ownH: number = NaN, transfer = true, along = false): number {
  const key = SZ_CMIN_W | sizeFlags(transfer, false, along, allowRatio);
  const at = sizeAt(el, key, cbW, cbH, ownH);
  if (at >= 0) return el.szK[at];
  return sizeKeep(el, key, cbW, cbH, ownH, contentMinWidthInner(el, cbW, allowRatio, cbH, ownH, transfer, along));
}

function contentMinWidthInner(el: Node, cbW: number, allowRatio = true, cbH: number = NaN, ownH: number = NaN, transfer = true, along = false): number {
  const ratio = allowRatio ? ratioContentWidth(el, cbW, cbH) : NaN;
  if (!Number.isNaN(ratio)) return ratio;
  // Inline-size containment: the content adds nothing to the box's inline size.
  if (containsInline(el) && !isReplaced(el) && !isTableDisplay(display(el))) {
    const held = clampW(el, padH(el, cbW), cbW);
    return allowRatio && transfer ? transferRatioWidth(el, held, cbW, cbH) : held;
  }
  // A vertical box's width is its block size, measured by laying the content out at the inline
  // size the box has (see verticalContentWidth).
  if (isVerticalText(el) && !isReplaced(el)) {
    const vw = verticalContentWidth(el, cbW, cbH, ownH);
    if (!Number.isNaN(vw)) return allowRatio && transfer ? transferRatioWidth(el, vw, cbW, cbH) : vw;
  }
  const basis = Number.isNaN(ownH) ? heightBasis(el, cbW, cbH) : ownH;
  let content = 0;
  if (isReplaced(el)) {
    if (el.su[P.P_WIDTH] === P.U_PCT) {
      // A percentage that depends on the containing block is cyclic here, and a cyclic size
      // resolves against zero in a replaced box's min-content contribution (CSS Sizing 3 §5.2.1).
      content = 0;
    } else {
      content = intrinsicSize(el)[0];
      const held = replacedHeightWidth(el, cbW, cbH);
      if (!Number.isNaN(held)) content = held;
    }
  } else if (isGridContainer(el) || isLanesContainer(el)) {
    // A grid's widths come from its tracks, not from its children as a block.
    const w = clampW(el, gridIntrinsicWidth(el, cbW, basis, true, cbH) + padH(el, cbW), cbW);
    return allowRatio && transfer ? transferRatioWidth(el, w, cbW, cbH) : w;
  } else if (el instanceof HTMLInputElement) {
    content = buttonInputType(el.type) ? textWidth(el, el.displayText) : 150;
  } else if (el instanceof HTMLSelectElement) {
    content = selectMaxContent(el);
  } else if (el instanceof HTMLTextAreaElement) {
    content = columns(el) * textWidth(el, "0");
  } else if (hasOwnText(el)) {
    content = ownTextMinWidth(el);
  } else if (isTableDisplay(display(el))) {
    // A table can't shrink below the sum of its columns' minimum widths.
    const table = tableRunContentWidth(el, visibleChildren(el), cbW, true);
    return allowRatio && transfer ? transferRatioWidth(el, table, cbW, cbH) : table;
  } else if (hasTableInternalChild(el)) {
    content = tableRunsWidth(el, cbW, true);
  } else if (!isFlexContainer(el) && hasInlineContent(el)) {
    content = hasBlockLevelChild(el) ? anonBlockWidth(el, cbW, basis, true) : inlineMinContent(el, cbW, basis);
  } else {
    const kids = visibleChildren(el);
    const row = isFlexContainer(el) && isRowDirection(el.sv[P.P_FLEX_DIRECTION]);
    for (let i = 0; i < kids.length; i++) {
      let outer = (row ? rowItemWidth(el, kids[i], cbW, basis, true) : intrinsicMinWidth(kids[i], cbW, basis)) + marginH(kids[i], 0);
      if (row) {
        // A definite flex-basis bounds what an item can contribute to the container's min-content
        // width: an item that can't shrink is at least its basis, and one that can't grow is at
        // most it (CSS Flexbox 9.9.1) — a 200px-wide child inside `flex: 0 1 100px` gives 100px.
        const base = len(kids[i], P.P_FLEX_BASIS, cbW);
        if (!Number.isNaN(base)) {
          if (kids[i].sv[P.P_FLEX_SHRINK] === 0) outer = Math.max(outer, base + marginH(kids[i], 0));
          else if (kids[i].sv[P.P_FLEX_GROW] === 0) outer = base + marginH(kids[i], 0);
        }
        content += outer + (i > 0 ? zeroIfNaN(len(el, P.P_COLUMN_GAP, cbW)) : 0);
      } else content = Math.max(content, outer);
    }
  }
  const w = clampW(el, content + padH(el, cbW), cbW);
  return allowRatio && transfer ? transferRatioWidth(el, w, cbW, cbH) : w;
}

/**
 * Whether a block-level box is in the flow, so that it forms an anonymous block of its own. A
 * block inside an inline box breaks that box open just the same, so it counts too.
 */
function hasBlockLevelChild(el: Node): boolean {
  for (const c of visibleChildren(el)) {
    if (isFloat(c) || isOutOfFlow(c)) continue;
    if (!isInlineLevel(c)) return true;
    if (!c.isTextNode && display(c) === P.D_INLINE && hasBlockLevelChild(c)) return true;
  }
  return false;
}

/**
 * The content width of a box that mixes block-level boxes with inline content. CSS wraps each run
 * of inline content in an anonymous block, so the box is as wide as its widest anonymous block,
 * not as wide as all of them set side by side. A block inside an inline box splits that box's run
 * in two, so the flow is split apart the same way the layout splits it.
 */
function anonBlockWidth(el: Node, cbW: number, basis: number, minContent: boolean): number {
  let widest = 0;
  for (const e of splitFlow(visibleChildren(el), cbW, basis)) {
    if (e.block !== null) {
      // A float sits outside the flow, and doesn't make the box any wider intrinsically.
      if (isFloat(e.block)) continue;
      const w = minContent ? intrinsicMinWidth(e.block, cbW, basis) : intrinsicMaxWidth(e.block, cbW, basis);
      widest = Math.max(widest, w + marginH(e.block, 0));
      continue;
    }
    if (e.pieces.length === 0) continue;
    measurePieces(e.pieces, cbW, false, basis);
    const w = minContent ? piecesMinContent(e.pieces) : piecesMaxContent(e.pieces);
    widest = Math.max(widest, w);
  }
  return widest;
}

/**
 * Intrinsic content width of a block that holds table-internal children: each run of them (white
 * space between aside) is one anonymous table, and the block is as wide as its widest child.
 */
function tableRunsWidth(el: Node, cbW: number, minContent: boolean): number {
  let widest = 0;
  let run: Node[] = [];
  for (const c of visibleChildren(el)) {
    if (isTableInternal(display(c))) {
      run.push(c);
      continue;
    }
    // White space never ends a run: the parts either side share the one anonymous table.
    if (isIgnorableWhitespace(c)) continue;
    if (run.length > 0) {
      widest = Math.max(widest, tableRunContentWidth(el, run, cbW, minContent));
      run = [];
    }
    const outer = (minContent ? minContentWidth(c, cbW) : maxContentWidth(c, cbW)) + marginH(c, cbW);
    widest = Math.max(widest, outer);
  }
  if (run.length > 0) widest = Math.max(widest, tableRunContentWidth(el, run, cbW, minContent));
  return widest;
}

// ---------------------------------------------------------------------------
// Text

/** The first line's indent in px; a percentage resolves against the content box's width. */
export function firstLineIndent(el: Node, innerW: number): number {
  const u = el.su[P.P_TEXT_INDENT];
  const v = el.sv[P.P_TEXT_INDENT];
  if (u === P.U_EXPR) return exprLength(el, v, innerW, el.sv[P.P_FONT_SIZE]);
  if (u === P.U_PCT) return (v / 100) * innerW;
  if (u === P.U_EM) return v * el.sv[P.P_FONT_SIZE];
  if (u === P.U_REM) return v * rootFontSize();
  if (u === P.U_VW) return (v / 100) * viewport.w;
  if (u === P.U_VH) return (v / 100) * viewport.h;
  return v;
}

/** A spacing property in px. `normal` is none, and an em takes the element's font size. */
export function spacingPx(el: Node, p: number): number {
  const u = el.su[p];
  if (u === P.U_NORMAL || u === P.U_NONE) return 0;
  const v = el.sv[p];
  if (u === P.U_EM) return v * el.sv[P.P_FONT_SIZE];
  if (u === P.U_REM) return v * rootFontSize();
  if (u === P.U_VW) return (v / 100) * viewport.w;
  if (u === P.U_VH) return (v / 100) * viewport.h;
  return v;
}

/** The letter and word spacing are asked of every run a paint draws; work them out once per
 *  generation, which a style pass or an attribute write moves. */
function spacingPair(el: Node): void {
  if (el.spaceGen === el.styleGen) return;
  el.spaceGen = el.styleGen;
  el.spaceLetter = spacingPx(el, P.P_LETTER_SPACING);
  el.spaceWord = spacingPx(el, P.P_WORD_SPACING);
}

export function letterSpacingPx(el: Node): number {
  spacingPair(el);
  return el.spaceLetter;
}

export function wordSpacingPx(el: Node): number {
  spacingPair(el);
  return el.spaceWord;
}

/**
 * The width of a run of text in an element's font, with its letter and word spacing. Browsers add
 * the letter spacing after every character, the last one included, so the run's width has one
 * more spacing than the gaps between its glyphs.
 */
export function textWidth(el: Node, text: string): number {
  const size = el.sv[P.P_FONT_SIZE];
  const letter = letterSpacingPx(el);
  const word = wordSpacingPx(el);
  if (letter === 0 && word === 0) return measure(text, size, fontKey(el));
  // At a zero font size every glyph has a zero advance. The host's font API clamps the size, so
  // asking it for the run would come back with a whole font's worth of glyphs; only the spacing
  // is left, one per character plus the word spacing on each space.
  if (!(size > 0)) {
    let spaces = 0;
    for (let i = 0; i < text.length; i++) if (text[i] === " ") spaces++;
    return letter * text.length + word * spaces;
  }
  const key = `${size}|${fontKey(el)}|${letter}|${word}|${text}`;
  const hit = spacedCache.get(key);
  if (hit !== undefined) return hit;
  const w = hostMeasureText(text, size, fontKey(el), letter, word);
  spacedCache.set(key, w);
  return w;
}

/**
 * The text an element renders for `text`: `text-transform` changes how it is drawn and measured
 * without touching the DOM. `capitalize` uppercases the first letter of each word, which starts
 * after white space or punctuation (so "don't" keeps its apostrophe).
 */
export function transformText(el: Node, text: string): string {
  const t = el.sv[P.P_TEXT_TRANSFORM];
  if (t === P.TT_UPPERCASE) return text.toUpperCase();
  if (t === P.TT_LOWERCASE) return text.toLowerCase();
  if (t === P.TT_CAPITALIZE) return capitalizeText(text, "");
  return text;
}

/** A preserved tab advances to the next tab stop, `tabSize` characters wide. */
function expandTabs(line: string, tabSize: number): string {
  if (line.indexOf("\t") < 0) return line;
  let out = "";
  for (let i = 0; i < line.length; i++) {
    if (line[i] !== "\t") { out += line[i]; continue; }
    const n = tabSize > 0 ? tabSize - (out.length % tabSize) : 0;
    for (let k = 0; k < n; k++) out += " ";
  }
  return out;
}

/** The element's own text as logical lines: whitespace collapsed or preserved per `white-space`. */
function ownTextLines(el: Node): string[] {
  const ws = el.sv[P.P_WHITE_SPACE];
  let text = transformText(el, el.flowText);
  if (ws !== P.W_NORMAL && ws !== P.W_NOWRAP && ws !== P.W_PRE_LINE) {
    const tabSize = el.sv[P.P_TAB_SIZE];
    const lines = text.replace(/\r\n?/g, "\n").split("\n").map((line) => expandTabs(line, tabSize));
    // A segment break at the end of the block ends the last line rather than starting a new one.
    if (lines.length > 1 && lines[lines.length - 1] === "") lines.length = lines.length - 1;
    return lines;
  }
  if (ws === P.W_PRE_LINE) {
    // Segment breaks survive; runs of spaces (and tabs) between them collapse to one space.
    text = text.replace(/\r\n|\r|\n/g, "\u0000").replace(/[ \t\f]+/g, " ").replace(/\u0000/g, "\n");
  } else {
    // A lone CR is a segment break too, so it collapses with the spaces around it.
    text = text.replace(/[ \t\f\r\n]+/g, " ");
  }
  // Collapsed white space at a line edge produces nothing. An ideographic space isn't white
  // space that collapses, so it survives at a line edge and hangs there.
  return text.split("\n").map((line) => line.replace(/^[ \t\f]+|[ \t\f]+$/g, ""));
}

/** Max-content width of an element's own text: its widest logical line. */
/**
 * `s` without the separators at its end: a space or word separator that ends a line hangs past
 * the edge, so it takes no room in the box's width.
 */
function withoutHangingEnd(s: string): string {
  let end = s.length;
  while (end > 0 && hangsAtEdge(s.charCodeAt(end - 1))) end--;
  return s.slice(0, end);
}

/** Does this character hang past the end of a line rather than take room in it? */
function hangsAtEdge(c: number): boolean {
  return c === 0x20 || c === 0xa0 || c === 0x1680 || (c >= 0x2000 && c <= 0x200a) ||
    c === 0x202f || c === 0x205f || c === 0x3000 || c === 0x1361 || c === 0x1039f || c === 0x1091f;
}

/** The index just past the separators that start at `i`. */
function skipHanging(s: string, i: number): number {
  while (i < s.length && hangsAtEdge(s.charCodeAt(i))) i++;
  return i;
}

/** The index just past the run of non-separators that starts at `i`. */
function skipWord(s: string, i: number): number {
  while (i < s.length && !hangsAtEdge(s.charCodeAt(i))) i++;
  return i;
}

function ownTextWidth(el: Node): number {
  let max = 0;
  // break-spaces wraps its preserved spaces rather than hanging them, so they always count.
  const hangs = el.sv[P.P_WHITE_SPACE] !== P.W_BREAK_SPACES;
  const lines = ownTextLines(el);
  for (let i = 0; i < lines.length; i++) {
    // The separators that end a line hang past it — but a line that the text's own end finishes
    // has no edge to hang past while the box is being sized to its widest line.
    const line = hangs && i < lines.length - 1 ? withoutHangingEnd(lines[i]) : lines[i];
    max = Math.max(max, textWidth(el, line));
  }
  return max;
}

/** Min-content width of an element's own text: its widest unbreakable run. */
/** The width of a select's widest label: its options', drawn in the select's own font. */
function selectMaxContent(el: Node): number {
  let max = 0;
  for (const option of optionsOf(el)) {
    const label = option.label === "" ? option.text : option.label;
    max = Math.max(max, textWidth(el, label));
  }
  return max;
}

/** The options a select holds, in document order, option groups included. */
function optionsOf(el: Node): HTMLOptionElement[] {
  const out: HTMLOptionElement[] = [];
  const walk = (node: Node): void => {
    for (const kid of boxKids(node)) {
      if (kid instanceof HTMLOptionElement) out.push(kid);
      else walk(kid);
    }
  };
  walk(el);
  return out;
}

/** The number of columns a textarea's box is wide, from its cols attribute (20 by default). */
function columns(el: Node): number {
  const raw = (el as Element).getAttribute("cols");
  if (raw === null) return 20;
  const n = parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : 20;
}

function ownTextMinWidth(el: Node): number {
  // A line that may start at any character is no wider than the widest one.
  if (breaksAnywhere(el)) {
    let max = 0;
    for (const line of ownTextLines(el)) for (const ch of line) max = Math.max(max, textWidth(el, ch));
    return max;
  }
  const ws = el.sv[P.P_WHITE_SPACE];
  if (ws === P.W_BREAK_SPACES) {
    // Each preserved space is a break opportunity after it, so a run ends at a space and the
    // widest run is the longest stretch of text up to and including one.
    let max = 0;
    for (const line of ownTextLines(el)) {
      let i = 0;
      while (i < line.length) {
        const sp = line.indexOf(" ", i);
        const end = sp < 0 ? line.length : sp + 1;
        max = Math.max(max, textWidth(el, line.slice(i, end)));
        i = end;
      }
    }
    return max;
  }
  // pre-wrap keeps its spaces but still breaks at them, and a preserved space that ends a line
  // hangs, so the spaces between two words take no room: the widest run is a word on its own.
  // The separators a line opens with can't hang, so they stay with the word after them.
  if (ws === P.W_PRE_WRAP) {
    let max = 0;
    for (const full of ownTextLines(el)) {
      const line = withoutHangingEnd(full);
      const start = skipHanging(line, 0);
      for (let i = start; i < line.length; i = skipHanging(line, skipWord(line, i))) {
        const from = i === start ? 0 : i;
        max = Math.max(max, textWidth(el, line.slice(from, skipWord(line, i))));
      }
    }
    return max;
  }
  if (ws !== P.W_NORMAL && ws !== P.W_PRE_LINE) return ownTextWidth(el);
  let max = 0;
  const hangs = el.sv[P.P_WHITE_SPACE] !== P.W_BREAK_SPACES;
  const lines = ownTextLines(el);
  for (let i = 0; i < lines.length; i++) {
    const line = hangs && i < lines.length - 1 ? withoutHangingEnd(lines[i]) : lines[i];
    for (const word of line.split(" ")) max = Math.max(max, textWidth(el, word));
  }
  return max;
}

/**
 * Cuts `text` back so that it and an ellipsis fit in `avail`. The ellipsis is drawn where the
 * clipped line ends, as `text-overflow: ellipsis` asks.
 */
export function ellipsize(el: Node, text: string, avail: number): string {
  const ell = "\u2026";
  if (textWidth(el, ell) > avail) return ell;
  let lo = 0;
  let hi = text.length;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (textWidth(el, text.slice(0, mid) + ell) <= avail) lo = mid;
    else hi = mid - 1;
  }
  // Spaces cut off at the end would sit between the last glyph and the ellipsis.
  return text.slice(0, lo).replace(/ +$/, "") + ell;
}

/**
 * Wraps an element's own text into `el.lines`. It goes through the same pieces and line breaker
 * as inline content, so white space, an ideographic space at a line edge and `white-space`
 * behave the same whether an element holds plain text or a mix of text and inline elements.
 */
/**
 * The ::first-line box whose rule changes the first line's metrics — its font, spacing or line
 * height — or null when the line is laid out exactly as the rest of the block.
 */
function firstLineMetricStyle(el: Node): Element | null {
  if (!(el instanceof Element)) return null;
  const fl = el.firstLinePseudo;
  if (fl === null) return null;
  // font-key covers the family, weight and italic, but not the size.
  if (fl.sv[P.P_FONT_SIZE] !== el.sv[P.P_FONT_SIZE] || fontKey(fl) !== fontKey(el)) return fl;
  if (fl.sv[P.P_LETTER_SPACING] !== el.sv[P.P_LETTER_SPACING] ||
    fl.sv[P.P_WORD_SPACING] !== el.sv[P.P_WORD_SPACING] ||
    fl.sv[P.P_LINE_HEIGHT] !== el.sv[P.P_LINE_HEIGHT]) return fl;
  return null;
}

/** The characters of a broken line. */
function lineCharacters(line: { items: { text: string }[] }): number {
  let n = 0;
  for (const item of line.items) n += item.text.length;
  return n;
}

/** The first `count` characters' pieces, re-carried by `style` so they measure in its font. */
function restyleFirst(pieces: Piece[], count: number, style: Node): Piece[] {
  const out: Piece[] = [];
  let left = count;
  for (const p of pieces) {
    if (left <= 0 || p.text === "") {
      out.push(p);
      continue;
    }
    if (p.text.length <= left) {
      const c = new Piece(p.kind, style, p.owner, p.text);
      c.brk = p.brk;
      out.push(c);
      left -= p.text.length;
      continue;
    }
    const head = new Piece(p.kind, style, p.owner, p.text.slice(0, left));
    head.brk = p.brk;
    out.push(head);
    out.push(new Piece(p.kind, p.style, p.owner, p.text.slice(left)));
    left = 0;
  }
  return out;
}

export function wrapText(el: Node, maxWidth: number): void {
  el.lines = [];
  el.lineWidths = [];
  el.lineForced = [];
  el.firstLineStyle = null;
  if (el.flowText === "") return;
  const ws = el.sv[P.P_WHITE_SPACE];
  const collapsing = ws === P.W_NORMAL || ws === P.W_NOWRAP || ws === P.W_PRE_LINE;
  const pieces: Piece[] = [];
  pushText(el, el, el.flowText, pieces);
  measurePieces(pieces, maxWidth, false);
  const indent = firstLineIndent(el, maxWidth);
  el.textIndent = indent;
  const firstStyle = firstLineMetricStyle(el);
  el.firstLineStyle = firstStyle;
  let lines = breakLines(pieces, maxWidth, undefined, indent);
  // A ::first-line that changes the font does its own line breaking: the first line is measured
  // with its font, and how much fits there decides which pieces take it; repeat until the first
  // line stops changing (usually once or twice).
  if (firstStyle !== null) {
    let count = lineCharacters(lines[0]);
    for (let pass = 0; pass < 4; pass++) {
      const styled = restyleFirst(pieces, count, firstStyle);
      measurePieces(styled, maxWidth, false);
      lines = breakLines(styled, maxWidth, undefined, indent);
      const next = lineCharacters(lines[0]);
      if (next === count) break;
      count = next;
    }
  }
  // `text-wrap: balance` and `pretty` shape the lines a block's own text wraps to, as they do
  // the lines of its inline content.
  const wrapStyle = el.sv[P.P_TEXT_WRAP_STYLE];
  // A block whose words may be broken by `overflow-wrap`, or whose lines `line-clamp` trims, is
  // left as it wrapped: what "the same number of lines" means there is not what balance wants.
  const mayBreakWords = breaksAnywhere(el) || el.sv[P.P_OVERFLOW_WRAP] === P.OW_BREAK_WORD;
  if (wrapStyle === P.TWS_BALANCE && !mayBreakWords && el.sv[P.P_LINE_CLAMP] <= 0) {
    lines = balanceLines(pieces, maxWidth, lines, indent);
  } else if (wrapStyle === P.TWS_PRETTY) {
    lines = prettyLines(pieces, maxWidth, lines, indent);
  }
  if (collapsing) {
    // A segment break at the edge of the block doesn't make an empty line box.
    let a = 0, b = lines.length;
    while (a < b && lines[a].items.length === 0) a++;
    while (b > a && lines[b - 1].items.length === 0) b--;
    lines = lines.slice(a, b);
  }
  for (const line of lines) {
    if (line.items.length === 0 && !line.forced) continue;
    let text = "";
    let w = 0;
    for (const item of line.items) {
      text += item.text;
      w = Math.max(w, item.x + item.w);
    }
    el.lines.push(text);
    el.lineWidths.push(w);
    el.lineForced.push(line.forced ? 1 : 0);
  }
  // A justified block's own text carries the same extra spacing the inline path applies: the
  // spare room of each line but the last (and the lines a forced break ends) goes between its
  // word separators, or between its characters when text-justify says inter-character.
  el.lineExtraWord.length = 0;
  el.lineExtraLetter.length = 0;
  const align = lineAlign(el);
  const alignLast = lastLineAlign(el);
  const method = el.sv[P.P_TEXT_JUSTIFY];
  for (let i = 0; i < el.lines.length; i++) {
    let extraWord = 0, extraLetter = 0;
    const last = i === el.lines.length - 1 || el.lineForced[i] === 1;
    const alignNow = alignLast >= 0 && last ? alignLast : align;
    if (alignNow === P.T_JUSTIFY && method !== P.TJUST_NONE && el.vtext === 0 && (!last || alignLast === P.T_JUSTIFY)) {
      const avail = maxWidth - (i === 0 ? indent : 0);
      const line = el.lines[i];
      // The separators that end the line hang past its edge: they take none of the room, and
      // the room they cover is not spare room to share out.
      const end = line.length - trailingSeparators(line);
      const free = avail - (el.lineWidths[i] - textWidth(el, line.slice(end)));
      if (free > 0) {
        const [spaces, chars] = itemTextSpacing(line.slice(0, end));
        if (method === P.TJUST_INTER_CHARACTER) {
          if (chars > 1) extraLetter = free / (chars - 1);
        } else if (spaces > 0) {
          extraWord = free / spaces;
        }
      }
    }
    el.lineExtraWord[i] = extraWord;
    el.lineExtraLetter[i] = extraLetter;
  }
  // `line-clamp` keeps the first lines and ends the last one it keeps with an ellipsis.
  // `auto` keeps as many lines as the box's max-height holds instead.
  let clamp = el.sv[P.P_LINE_CLAMP];
  if (clamp < 0) clamp = autoClamp(el);
  if (clamp > 0 && el.lines.length > clamp) {
    el.lines.length = clamp;
    el.lineWidths.length = clamp;
    el.lineForced.length = clamp;
    // block-ellipsis: no-ellipsis keeps the last line as it is, without the ellipsis.
    if (el.sv[P.P_BLOCK_ELLIPSIS] !== P.BE_NO_ELLIPSIS) {
      const i = clamp - 1;
      const avail = maxWidth - (i === 0 ? indent : 0);
      el.lines[i] = ellipsize(el, el.lines[i], avail);
      el.lineWidths[i] = textWidth(el, el.lines[i]);
    }
  }
  // A line that runs past the content edge ends in an ellipsis when `text-overflow` asks for
  // one; the rest is clipped away (so this only shows with `overflow` other than visible).
  if (el.sv[P.P_TEXT_OVERFLOW] === P.TO_ELLIPSIS && clipsX(el)) {
    for (let i = 0; i < el.lines.length; i++) {
      const avail = maxWidth - (i === 0 ? indent : 0);
      if (el.lineWidths[i] > avail + 0.5) {
        el.lines[i] = ellipsize(el, el.lines[i], avail);
        el.lineWidths[i] = textWidth(el, el.lines[i]);
      }
    }
  }
}
