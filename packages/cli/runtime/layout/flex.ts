// Flexbox layout: single-line and multi-line, either direction and either wrap mode.

import * as P from "../../shared/props.ts";
import { settleNode } from "./incremental.ts";
import { Node, boxKids } from "../dom.ts";
import { isFlexContainer, isGridContainer, isLanesContainer, isRtl, isVerticalText, lineHeightPx, usedWritingMode } from "../style.ts";
import { fitHeight, layoutBox } from "./box.ts";
import { alignEdge, alignOffset, aspectH, aspectRatio, aspectW, clampH, clampW, contentEdge, display, hasNaturalSize, inlineMirrored, intrinsicSize, isOutOfFlow, isReplaced, isScroller, len, marginH, marginV, padH, padV, place, sizeUnit, specH, specW, visibleChildren, zeroIfNaN, isSvgElement, isIntrinsicSize } from "./box-model.ts";
import { baselineOffset, contentMaxWidth, contentMinWidth, maxContentWidth, minContentWidth } from "./text.ts";

/** justify-content's packing for the flex main axis. `start` and `end` name the edges of the
 *  inline axis, so a reversed main flow puts them on the other side — unlike `flex-start` and
 *  `flex-end`, which name the main axis itself. The physical left/right keywords follow the page's
 *  direction where the main axis runs across it; on a main axis that runs down the page they pack
 *  at its start, except that a row reads right as its other end (CSS Align 5.2, CSS Flexbox 8.2). */
function mainPacking(el: Node, row: boolean, v: number): number {
  const vert = isVerticalText(el);
  const reversed = el.sv[P.P_FLEX_DIRECTION] === (row ? P.FD_ROW_REVERSE : P.FD_COLUMN_REVERSE);
  if (row !== vert) {
    // A horizontal inline axis: left and right follow the page's direction.
    const wm = usedWritingMode(el);
    const rl = row ? isRtl(el) : wm === P.WM_VERTICAL_RL || wm === P.WM_SIDEWAYS_RL;
    if (rl) {
      if (v === P.J_LEFT) v = P.J_RIGHT;
      else if (v === P.J_RIGHT) v = P.J_LEFT;
    }
    if (v === P.J_LEFT) v = P.J_START;
    else if (v === P.J_RIGHT) v = P.J_END;
  } else if (v === P.J_LEFT) {
    v = P.J_START;
  } else if (v === P.J_RIGHT) {
    // A column's main axis is parallel with neither physical side, so both of these keywords pack
    // at its start there; a row in a vertical writing mode reads right as the other end of it.
    v = row ? P.J_END : P.J_START;
  }
  if (reversed) {
    if (v === P.J_START) v = P.J_END;
    else if (v === P.J_END) v = P.J_START;
  }
  return contentEdge(v);
}

function alignRaw(parent: Node, child: Node): number {
  const self = child.sv[P.P_ALIGN_SELF];
  const mode = self === P.A_AUTO ? parent.sv[P.P_ALIGN_ITEMS] : self;
  // `normal` is flex's stretch: a flex item always fills its line's cross size.
  return mode === P.A_NORMAL ? P.A_STRETCH : mode;
}

function alignFor(parent: Node, child: Node): number {
  return alignEdge(alignRaw(parent, child));
}

/** Whether the box's own content starts at the far edge — the bottom or the right one — of the
 *  page's x axis (`alongX`) or y axis. Whichever of its own axes runs that way decides it: the
 *  inline axis of a box written across that way, and otherwise the block axis (CSS Writing Modes 3). */
function startsAtFarEdge(el: Node, alongX: boolean): boolean {
  const vertical = isVerticalText(el);
  if (alongX) {
    // A horizontal box's inline axis runs along the page's x axis, a vertical box's block axis does.
    if (!vertical) return inlineMirrored(el);
    const wm = usedWritingMode(el);
    return wm === P.WM_VERTICAL_RL || wm === P.WM_SIDEWAYS_RL;
  }
  // A horizontal box's block axis runs down the page, a vertical box's inline axis does.
  return vertical && inlineMirrored(el);
}

/** The cross-axis alignment a child asks for, with a self-relative keyword following the item's own
 *  writing mode: it names the edge the item's own content starts from, which is the container's
 *  cross-start edge only where the two run that axis the same way. A column's cross axis is the inline
 *  axis and a row's the block one, so an item written the other way round reads it as its other axis
 *  (CSS Align 4). */
function crossRaw(el: Node, c: Node, row: boolean): number {
  let mode = alignRaw(el, c);
  const alongX = row === isVerticalText(el);
  if (startsAtFarEdge(el, alongX) !== startsAtFarEdge(c, alongX)) {
    if (mode === P.A_SELF_START) mode = P.A_SELF_END;
    else if (mode === P.A_SELF_END) mode = P.A_SELF_START;
  }
  return mode;
}

/** The cross-axis alignment as the edge it settles on. */
function crossAlign(el: Node, c: Node, row: boolean): number {
  return alignEdge(crossRaw(el, c, row));
}

/** Whether the cross-axis alignment winning for a child carries `safe`, which clamps an
 *  overflowing child to the start edge. */
function alignSafe(parent: Node, child: Node): boolean {
  const self = child.sv[P.P_ALIGN_SELF];
  return self === P.A_AUTO ? parent.su[P.P_ALIGN_ITEMS] === P.U_SAFE : child.su[P.P_ALIGN_SELF] === P.U_SAFE;
}

function justifyOffsets(mode: number, free: number, n: number, safe: boolean): number[] {
  // Returns [leading offset, extra space between items]. Centering overflowing items gives a
  // negative leading offset (they overflow both edges); the spacing modes clamp to the start,
  // and so does a `safe` position when the content overflows (CSS Align 4).
  if (n === 0) return [0, 0];
  if (safe && free < 0) return [0, 0];
  if (mode === P.J_CENTER) return [free / 2, 0];
  if (mode === P.J_END) return [free, 0];
  // A spacing mode given less room than its items need: space-between packs at the start, while
  // the two that leave room at both edges fall back to centering (CSS Align 5.4).
  if (mode === P.J_SPACE_BETWEEN) return n > 1 && free > 0 ? [0, free / (n - 1)] : [0, 0];
  if (mode === P.J_SPACE_AROUND) return [free / n / 2, free / n];
  if (mode === P.J_SPACE_EVENLY) return [free / (n + 1), free / (n + 1)];
  return [0, 0];
}

/** align-content's packing of a set of flex lines. `wrap-reverse` turns the lines' cross axis
 *  around, but `start` and `end` name the writing mode's own edges, which it leaves where they
 *  are — only the flex-relative `flex-start`, `flex-end` and the spacing modes turn with it
 *  (CSS Align 5.2, CSS Flexbox 8.2). */
function contentPacking(el: Node, crossReverse: boolean): number {
  let v = el.sv[P.P_ALIGN_CONTENT];
  if (crossReverse) {
    if (v === P.J_START) v = P.J_END;
    else if (v === P.J_END) v = P.J_START;
  }
  return contentEdge(v);
}

/** The lead and the gap between flex lines, packed by align-content. A set that overflows the
 *  container packs against the cross-start edge: `space-between` names that edge as its start,
 *  and the two spacing modes that leave room at both edges fall back to a *safe* center, which
 *  the overflow puts at the start as well (CSS Align 5.4). */
function contentOffsets(mode: number, free: number, n: number, safe: boolean): number[] {
  if (free < 0 && (mode === P.J_SPACE_AROUND || mode === P.J_SPACE_EVENLY)) return [0, 0];
  return justifyOffsets(mode, free, n, safe);
}

function flexBase(c: Node, mainSize: number, row: boolean, innerW: number): number {
  const basis = len(c, P.P_FLEX_BASIS, mainSize);
  if (!Number.isNaN(basis)) {
    return c.sv[P.P_BOX_SIZING] === P.BS_BORDER ? basis : basis + (row ? padH(c, innerW) : padV(c, innerW));
  }
  return NaN;
}

/** Whether the box's baseline is the one its own layout settled on for its first line of items,
 *  rather than a line box of its own: a grid container's baseline is its first row's, a flex
 *  container's its first line's (CSS Grid 10.1, CSS Flexbox 8.5). */
function containerBaseline(c: Node): boolean {
  return isGridContainer(c) || isLanesContainer(c) || isFlexContainer(c);
}

/** Whether `k` is the rendered legend of the fieldset `c`. It sits in the fieldset's border, out
 *  of the flow its content runs in, and so gives the fieldset no baseline. */
function isFieldsetLegend(c: Node, k: Node): boolean {
  if (c.localName !== "fieldset" || k.localName !== "legend") return false;
  for (const kid of boxKids(c)) {
    if (kid.localName === "legend" && display(kid) !== P.D_NONE) return kid === k;
  }
  return false;
}

/** The block-axis position of a line box's alignment baseline, from the border box: a horizontal
 *  line sits on its font's baseline, while a line running down the page is aligned on its middle,
 *  which is where vertical text has its central baseline (CSS Align 9.2). */
function alignedBaseline(c: Node, entry: number): number {
  if (c.vtext === 0) return entry;
  return entry - baselineOffset(c) + lineHeightPx(c) / 2;
}

/** Distance from an element's border-box top to its first baseline, or -1 when it has one of its
 *  own: the highest baseline of the line boxes it holds, be they its own or a child's. A box that
 *  mixes blocks with inline content holds its first line in the block before its anonymous one. */
export function naturalBaseline(c: Node): number {
  // A box showing an older layout's outputs lays out for real before its content is read.
  if (c.lPending >= 0) settleNode(c);
  if (isReplaced(c)) return -1; // a replaced box's baseline is synthesized from its bottom edge
  if (containerBaseline(c) && c.lineBaseline.length > 0) return c.lineBaseline[0];
  let best = c.lines.length > 0 ? alignedBaseline(c, c.contentY + baselineOffset(c)) : -1;
  // A line running down the page keeps its middle in `lineCentral`; a horizontal line's entry is
  // its font baseline already.
  const central = c.vtext !== 0 && c.lineCentral.length === c.lineBaseline.length;
  for (let i = 0; i < c.lineBaseline.length; i++) {
    const a = central ? c.lineCentral[i] : alignedBaseline(c, c.lineBaseline[i]);
    if (best < 0 || a < best) best = a;
  }
  for (const k of boxKids(c)) {
    if (display(k) === P.D_NONE || isOutOfFlow(k) || isFieldsetLegend(c, k)) continue;
    const b = naturalBaseline(k);
    if (b < 0) continue;
    if (best < 0 || k.y + b < best) best = k.y + b;
  }
  return best;
}

/** Distance from an element's border-box top to its last baseline, or -1 when it has one of its
 *  own: the lowest baseline of the line boxes it holds, be they its own or a child's. */
export function naturalLastBaseline(c: Node): number {
  if (c.lPending >= 0) settleNode(c);
  if (isReplaced(c)) return -1; // a replaced box's baseline is synthesized from its bottom edge
  if (containerBaseline(c) && c.lineBaseline.length > 0) return c.lineBaseline[c.lineBaseline.length - 1];
  let best = -1;
  if (c.lines.length > 0) {
    best = alignedBaseline(c, c.contentY + (c.lines.length - 1) * lineHeightPx(c) + baselineOffset(c));
  }
  const central = c.vtext !== 0 && c.lineCentral.length === c.lineBaseline.length;
  for (let i = 0; i < c.lineBaseline.length; i++) {
    const a = central ? c.lineCentral[i] : alignedBaseline(c, c.lineBaseline[i]);
    if (a > best) best = a;
  }
  for (const k of boxKids(c)) {
    if (display(k) === P.D_NONE || isOutOfFlow(k) || isFieldsetLegend(c, k)) continue;
    const b = naturalLastBaseline(k);
    if (b < 0) continue;
    if (k.y + b > best) best = k.y + b;
  }
  return best;
}

/** One flex line's part of a container baseline set: the baseline its own baseline-aligned items
 *  share, whichever kind each of them lines up on, or else the alignment baseline of the item at
 *  the line's start (`atStart`) or end (`atEnd`) edge, synthesized from its border box when it has
 *  none. A line along the cross axis has no such group to share, so it always takes the edge item
 *  (CSS Flexbox 8.5). */
function lineBaselineSet(el: Node, items: Node[], ln: number[], startEdge: boolean, atStart: number, atEnd: number,
  participate: boolean): number {
  if (participate) {
    let shared = NaN;
    for (const i of ln) {
      const c = items[i];
      const mode = alignFor(el, c);
      if (mode !== P.A_BASELINE && mode !== P.A_LAST_BASELINE) continue;
      if (sizeUnit(c, P.P_MARGIN_TOP) === P.U_AUTO || sizeUnit(c, P.P_MARGIN_BOTTOM) === P.U_AUTO) continue;
      const b = mode === P.A_LAST_BASELINE ? naturalLastBaseline(c) : naturalBaseline(c);
      const off = c.y + (b >= 0 ? b : c.h);
      if (Number.isNaN(shared) || off > shared) shared = off;
    }
    if (!Number.isNaN(shared)) return shared;
  }
  const c = items[startEdge ? atStart : atEnd];
  const b = startEdge ? naturalBaseline(c) : naturalLastBaseline(c);
  return c.y + (b >= 0 ? b : c.h);
}

/** A column flex item's inline-axis baseline: its offset across the container from the item's
 *  border-box inline-start edge, and the side of the cross axis it lines up on (`true` for the
 *  end group). A vertical item brings the baseline of its block axis, the one that can run
 *  across a column container; a horizontal item has none, so one is synthesized from its edge.
 *  A box without a baseline of its own gets the line-under edge, its block-end side
 *  (CSS Align 9, CSS Flexbox 8.5). */
function crossBaseline(el: Node, c: Node, last: boolean): [number, boolean] {
  const cw = usedWritingMode(el);
  const iw = usedWritingMode(c);
  const cVert = cw !== P.WM_HORIZONTAL_TB;
  const iVert = iw !== P.WM_HORIZONTAL_TB;
  // Only an item whose block axis runs across the container's inline axis — one of the other
  // orientation — brings a block-axis baseline to this axis. A horizontal item in a horizontal
  // column has none and takes an edge. Vertical text's baseline runs along the line, through the
  // middle of its line box: the central baseline, which a box with no line boxes synthesizes in
  // the middle of its border box (CSS Align 9.2, CSS Flexbox 8.5).
  if (cVert === iVert) {
    if (!cVert) return [last ? c.w : 0, last];
    const own = last ? naturalLastBaseline(c) : naturalBaseline(c);
    return [own >= 0 ? own : c.w / 2, false];
  }
  const rl = iw === P.WM_VERTICAL_RL || iw === P.WM_SIDEWAYS_RL;
  const own = last ? naturalLastBaseline(c) : naturalBaseline(c);
  const b = own >= 0 ? own : c.w;
  // The first line of an lr block sits at the container's cross-start and an rl one at its
  // cross-end; a synthesized baseline sits at the block-end, the other way round.
  return [rl ? c.w - b : b, (last ? !rl : rl) !== (own < 0)];
}

/** Distributes free space by flex-grow or flex-shrink, as the CSS flexbox algorithm does. `grow`
 *  picks the axis of distribution from the hypothetical main sizes. Items that run into their
 *  minimum or maximum size are frozen there and the rest is redistributed. */
function resolveFlexible(items: Node[], bases: number[], free: number, mins: number[], maxes: number[],
  grow: boolean): number[] {
  const sizes = bases.slice();
  const frozen: boolean[] = [];
  for (let i = 0; i < items.length; i++) {
    // An item with no room to grow (or shrink) stays at its hypothetical main size.
    const factor = grow ? items[i].sv[P.P_FLEX_GROW] : items[i].sv[P.P_FLEX_SHRINK];
    frozen.push(factor === 0);
    sizes[i] = factor === 0 ? Math.max(mins[i], Math.min(bases[i], maxes[i])) : bases[i];
  }
  for (let round = 0; round <= items.length; round++) {
    let remaining = free;
    for (let i = 0; i < items.length; i++) if (frozen[i]) remaining -= sizes[i] - bases[i];
    // With the flex factors summing to less than one, only that share of the free space is
    // distributed, and the rest of the line stays empty (CSS Flexbox 9.7).
    let factors = 0;
    for (let i = 0; i < items.length; i++) {
      if (!frozen[i]) factors += grow ? items[i].sv[P.P_FLEX_GROW] : items[i].sv[P.P_FLEX_SHRINK];
    }
    if (factors < 1) remaining *= factors;
    let weight = 0;
    for (let i = 0; i < items.length; i++) {
      if (!frozen[i]) weight += grow ? items[i].sv[P.P_FLEX_GROW] : items[i].sv[P.P_FLEX_SHRINK] * bases[i];
    }
    for (let i = 0; i < items.length; i++) {
      if (frozen[i]) continue;
      const share = grow ? items[i].sv[P.P_FLEX_GROW] : items[i].sv[P.P_FLEX_SHRINK] * bases[i];
      sizes[i] = bases[i] + (weight > 0 && remaining !== 0 ? (remaining * share) / weight : 0);
    }
    let violated = false;
    for (let i = 0; i < items.length; i++) {
      if (frozen[i]) continue;
      if (sizes[i] < mins[i]) {
        sizes[i] = mins[i];
        frozen[i] = true;
        violated = true;
      } else if (sizes[i] > maxes[i]) {
        sizes[i] = maxes[i];
        frozen[i] = true;
        violated = true;
      }
    }
    if (!violated) break;
  }
  return sizes;
}

export function isScrollContainer(el: Node): boolean {
  // `overflow: clip` clips but never scrolls, so it is not a scroll container: a flex item with
  // it keeps its automatic minimum size instead of collapsing to nothing.
  return isScroller(el);
}

/**
 * The content size suggestion of an item in a row: its min-content width, except that a replaced
 * item with an intrinsic ratio transfers its cross size, clamped by min/max-height, to the main
 * axis instead (CSS Flexbox 4.5).
 */
/** The height a row item gets by stretching into its line, or NaN when it isn't stretched. */
function stretchedHeight(c: Node, innerW: number, innerH: number): number {
  if (Number.isNaN(innerH) || c.su[P.P_HEIGHT] !== P.U_AUTO) return NaN;
  const parent = c.parentElement;
  if (parent === null || alignFor(parent, c) !== P.A_STRETCH) return NaN;
  if (sizeUnit(c, P.P_MARGIN_TOP) === P.U_AUTO || sizeUnit(c, P.P_MARGIN_BOTTOM) === P.U_AUTO) return NaN;
  return Math.max(0, innerH - marginV(c, innerW));
}

function contentSuggestion(c: Node, innerW: number, innerH: number): number {
  if (isReplaced(c)) {
    const sz = intrinsicSize(c);
    if (sz[1] > 0) {
      // A definite height wins, and a stretched item's height is definite too; otherwise the
      // intrinsic height stands in. min/max-height clamp whichever it is, and the height becomes
      // a width through the item's preferred ratio, which `aspect-ratio` may override.
      let cross = specH(c, innerW, innerH);
      if (Number.isNaN(cross)) cross = stretchedHeight(c, innerW, innerH);
      if (Number.isNaN(cross)) cross = sz[1];
      return aspectW(c, clampH(c, cross, innerW, innerH), innerW);
    }
  }
  return contentMinWidth(c, innerW, true, innerH);
}

/**
 * The automatic minimum size of a row item (`min-width: auto`): its content size suggestion,
 * capped by a definite width, so a long unbreakable word keeps the item from collapsing
 * (CSS Flexbox 4.5).
 */
function automaticMinWidth(c: Node, innerW: number, innerH: number): number {
  // An item that scrolls overflows instead of pushing its line wider, so it can shrink to nothing.
  if (isScrollContainer(c)) return 0;
  let content = contentSuggestion(c, innerW, innerH);
  // A definite cross size — the item's own, or the line's when it stretches — transfers through a
  // preferred aspect ratio to give a main size the item can't shrink below (CSS Flexbox 4.5).
  if (!isReplaced(c) && aspectRatio(c) > 0 && c.su[P.P_WIDTH] === P.U_AUTO) {
    let cross = specH(c, innerW, innerH);
    if (Number.isNaN(cross)) cross = stretchedHeight(c, innerW, innerH);
    if (!Number.isNaN(cross)) content = Math.max(content, aspectW(c, clampH(c, cross, innerW, innerH), innerW));
  }
  const spec = specW(c, innerW);
  const min = Number.isNaN(spec) ? content : Math.min(content, spec);
  return Math.max(0, clampW(c, min, innerW));
}

/** An item's minimum main size: an explicit min-width, or the automatic one when it is auto. */
function minMainWidth(c: Node, innerW: number, innerH: number): number {
  const min = len(c, P.P_MIN_WIDTH, innerW);
  if (c.su[P.P_MIN_WIDTH] !== P.U_AUTO && !Number.isNaN(min)) {
    return Math.max(0, min + (c.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : padH(c, innerW)));
  }
  return automaticMinWidth(c, innerW, innerH);
}

/** An item's maximum main size in a row: max-width as a border-box width, unbounded when unset. */
function maxMainWidth(c: Node, innerW: number): number {
  const max = len(c, P.P_MAX_WIDTH, innerW);
  const pads = padH(c, innerW);
  if (Number.isNaN(max)) return Infinity;
  return Math.max(pads, max + (c.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : pads));
}

/** The same for a column item: max-height as a border-box height. */
function maxMainHeight(c: Node, innerW: number, innerH: number): number {
  const max = len(c, P.P_MAX_HEIGHT, innerH);
  const pads = padV(c, innerW);
  if (Number.isNaN(max)) return Infinity;
  return Math.max(pads, max + (c.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : pads));
}

/** The items of a flex container, sorted by `order` and then by document order. */
function orderedItems(el: Node): Node[] {
  const items = visibleChildren(el);
  const idx: number[] = [];
  for (let i = 0; i < items.length; i++) idx.push(i);
  idx.sort((a, b) => {
    const d = items[a].sv[P.P_ORDER] - items[b].sv[P.P_ORDER];
    return d !== 0 ? d : a - b;
  });
  const out: Node[] = [];
  for (const i of idx) out.push(items[i]);
  return out;
}

/**
 * Whether a line distributes free space by growing or by shrinking: the side of the line's
 * hypothetical main sizes against the space it has (CSS Flexbox 9.7).
 */
function lineGrows(items: Node[], ln: number[], hypo: number[], gap: number, mainSize: number, row: boolean,
  cbW: number): boolean {
  let total = gap * Math.max(0, ln.length - 1);
  for (const i of ln) total += hypo[i] + (row ? marginH(items[i], cbW) : marginV(items[i], cbW));
  return total < mainSize;
}

/**
 * Splits items into flex lines: an item starts a new line when it doesn't fit in the space left
 * on the current one, unless the container doesn't wrap or the line is still empty.
 */
function flexLines(items: Node[], bases: number[], gap: number, mainSize: number, wrap: boolean,
  cbW: number): number[][] {
  const lines: number[][] = [];
  let line: number[] = [];
  let used = 0;
  for (let i = 0; i < items.length; i++) {
    const outer = bases[i] + marginH(items[i], cbW);
    if (wrap && line.length > 0 && used + gap + outer > mainSize) {
      lines.push(line);
      line = [i];
      used = outer;
    } else {
      if (line.length > 0) used += gap;
      line.push(i);
      used += outer;
    }
  }
  if (line.length > 0) lines.push(line);
  return lines;
}

/** The same, with the vertical margins of a column container. */
function flexLinesV(items: Node[], bases: number[], gap: number, mainSize: number, wrap: boolean,
  cbW: number): number[][] {
  const lines: number[][] = [];
  let line: number[] = [];
  let used = 0;
  for (let i = 0; i < items.length; i++) {
    const outer = bases[i] + marginV(items[i], cbW);
    if (wrap && line.length > 0 && used + gap + outer > mainSize) {
      lines.push(line);
      line = [i];
      used = outer;
    } else {
      if (line.length > 0) used += gap;
      line.push(i);
      used += outer;
    }
  }
  if (line.length > 0) lines.push(line);
  return lines;
}

/**
 * Places the out-of-flow children of a flex container. Their static position is where they would
 * go as the container's only flex item: justify-content places it on the main axis and
 * align-self on the cross axis, with `stretch` treated as the start (CSS Flexbox 4.1).
 */
function placeOutOfFlowChildren(el: Node, innerW: number, innerH: number, mainExtent: number,
  crossExtent: number, pl: number, pt: number, row: boolean, reverse: boolean): void {
  for (const c of boxKids(el)) {
    if (display(c) === P.D_NONE || !isOutOfFlow(c)) continue;
    // The axes turn a quarter around a vertical container: its inline axis runs down the page, so
    // the box a child of it lays itself out in is as wide as the container is tall.
    const vertical = isVerticalText(el);
    const cbW = vertical ? innerH : innerW;
    // Its own size decides where the static position is; the offsets resolve around it later.
    layoutBox(c, cbW, vertical ? innerW : innerH, NaN, NaN, true);
    // The frame's x axis is the inline one — a row's main axis, a column's cross axis — and that is
    // the page's height when the container runs vertically.
    const mainAcross = row !== vertical;
    const mainSize = mainAcross ? c.w + marginH(c, cbW) : c.h + marginV(c, cbW);
    const crossSize = mainAcross ? c.h + marginV(c, cbW) : c.w + marginH(c, cbW);
    const jc = mainPacking(el, row, el.sv[P.P_JUSTIFY_CONTENT]);
    const [lead] = justifyOffsets(jc, mainExtent - mainSize, 1, el.su[P.P_JUSTIFY_CONTENT] === P.U_SAFE);
    // A baseline position falls back to the edge it would synthesize one from: the start edge,
    // or the end edge for `last baseline` (CSS Align 9.1).
    const raw = crossRaw(el, c, row);
    // `flex-start`, `flex-end` and the `stretch` a static position reads as `flex-start` name the
    // flex line's own edges; `start` and `end` name the box's writing mode edges, and the two
    // differ once `wrap-reverse` turns the line's cross axis around (CSS Flexbox 4.1, CSS Align 4).
    const lineEdge = raw === P.A_FLEX_START || raw === P.A_FLEX_END || raw === P.A_STRETCH;
    const am = alignEdge(raw);
    const ay = am === P.A_BASELINE ? P.A_START : am === P.A_LAST_BASELINE ? P.A_END : am;
    const crossPos = alignOffset(ay, crossExtent - crossSize, alignSafe(el, c));
    // A right-to-left direction turns the inline axis around: a row's main axis and a column's
    // cross axis run the other way.
    const rtl = inlineMirrored(el);
    const mainFlip = row && rtl;
    const crossFlip = !row && rtl;
    const crossTurn = lineEdge ? (el.sv[P.P_FLEX_WRAP] === P.FW_WRAP_REVERSE) !== crossFlip : crossFlip;
    const crossStart = crossTurn ? crossExtent - crossSize - crossPos : crossPos;
    const mainPos = reverse !== mainFlip ? mainExtent - lead - mainSize : lead;
    // Margins are added by the out-of-flow placement, which these positions feed.
    if (row) {
      c.staticX = pl + mainPos;
      c.staticY = pt + crossStart;
    } else {
      c.staticX = pl + crossStart;
      c.staticY = pt + mainPos;
    }
    c.staticValid = true;
  }
}

export function layoutFlexRow(el: Node, innerW: number, innerH: number, pl: number, pt: number): number {
  const items = orderedItems(el);
  // A right-to-left direction turns the inline axis around — right to left in a horizontal
  // writing mode, bottom to top in a vertical one — and a row's main axis is that inline axis.
  const rtl = inlineMirrored(el);
  const gap = zeroIfNaN(len(el, P.P_COLUMN_GAP, innerW)); // between items on a line
  const crossGap = zeroIfNaN(len(el, P.P_ROW_GAP, innerW)); // between lines
  const wrapMode = el.sv[P.P_FLEX_WRAP];
  const wrap = wrapMode !== P.FW_NOWRAP;
  const reverse = el.sv[P.P_FLEX_DIRECTION] === P.FD_ROW_REVERSE;
  const crossReverse = wrapMode === P.FW_WRAP_REVERSE;

  // Hypothetical main sizes: flex-basis, else width, else max-content.
  const bases: number[] = [];
  const mins: number[] = [];
  const maxes: number[] = [];
  for (const c of items) {
    let base = flexBase(c, innerW, true, innerW);
    if (Number.isNaN(base)) base = specW(c, innerW);
    // A definite cross size — the item's own, or the line's when it stretches — transfers through
    // a preferred aspect ratio to give the main size (CSS Flexbox 9.2.3, step C). A replaced box
    // transfers only a size it states itself: its intrinsic size is the fallback below.
    if (Number.isNaN(base) && aspectRatio(c) > 0) {
      let cross = specH(c, innerW, innerH);
      if (Number.isNaN(cross) && !isReplaced(c)) cross = stretchedHeight(c, innerW, innerH);
      if (!Number.isNaN(cross)) base = aspectW(c, clampH(c, cross, innerW, innerH), innerW);
    }
    // The content size, not clamped by the item's own min/max-width (CSS Flexbox 9.2.3). An image
    // with a ratio but no size of its own takes the main space it is given.
    if (Number.isNaN(base) && !hasNaturalSize(c) && aspectRatio(c) > 0) {
      let fill = Math.max(0, innerW - marginH(c, innerW));
      // A max-height that bounds the height transfers through the ratio as a cap on this width.
      const maxH = len(c, P.P_MAX_HEIGHT, innerH);
      if (!Number.isNaN(maxH)) fill = Math.min(fill, aspectW(c, clampH(c, maxH, innerW, innerH), innerW));
      base = fill;
    }
    if (Number.isNaN(base)) base = contentMaxWidth(c, innerW, innerH);
    bases.push(Math.max(0, base));
    mins.push(minMainWidth(c, innerW, innerH));
    maxes.push(maxMainWidth(c, innerW));
  }
  // A line breaks on the hypothetical main sizes: the base sizes held within min/max-width.
  const hypo: number[] = [];
  for (let i = 0; i < items.length; i++) hypo.push(Math.max(mins[i], Math.min(bases[i], maxes[i])));
  const lines = flexLines(items, hypo, gap, innerW, wrap, innerW);

  // Each line's items share its main size, and their heights give the line's cross size.
  const lineCross: number[] = [];
  for (const ln of lines) {
    let used = gap * Math.max(0, ln.length - 1);
    const lb: number[] = [];
    const lmins: number[] = [];
    const lmaxes: number[] = [];
    const li: Node[] = [];
    for (const i of ln) {
      used += bases[i] + marginH(items[i], innerW);
      lb.push(bases[i]);
      lmins.push(mins[i]);
      lmaxes.push(maxes[i]);
      li.push(items[i]);
    }
    const sizes = resolveFlexible(li, lb, innerW - used, lmins, lmaxes, lineGrows(items, ln, hypo, gap, innerW, true, innerW));
    let cross = 0;
    for (let k = 0; k < ln.length; k++) {
      const c = items[ln[k]];
      layoutBox(c, innerW, innerH, clampW(c, sizes[k], innerW), NaN, false);
      cross = Math.max(cross, c.h + marginV(c, innerW));
    }
    lineCross.push(cross);
  }

  // A nowrap container's line fills its inner cross size; wrapped lines are sized to their items
  // and share any space left over through align-content.
  if (!Number.isNaN(innerH) && !wrap) lineCross[0] = innerH;
  let usedCross = crossGap * Math.max(0, lines.length - 1);
  for (const h of lineCross) usedCross += h;
  const mode = contentPacking(el, crossReverse);
  let freeCross = Number.isNaN(innerH) ? 0 : innerH - usedCross;
  // align-content: stretch grows every line, even a lone one, by an equal share of the space.
  if (mode === P.AC_STRETCH && freeCross > 0) {
    for (let l = 0; l < lineCross.length; l++) lineCross[l] += freeCross / lines.length;
    usedCross = innerH;
    freeCross = 0;
  }

  // Stretch the items that ask for it to their line's cross size.
  for (let l = 0; l < lines.length; l++) {
    for (const i of lines[l]) {
      const c = items[i];
      // A row's cross axis lies across the page in a container that runs down it, so the cross
      // size the stretch fills is the item's width; `sizeUnit` asks the property that names it
      // in the item's own axes.
      if (alignFor(el, c) === P.A_STRETCH && sizeUnit(c, P.P_HEIGHT) === P.U_AUTO &&
        sizeUnit(c, P.P_MARGIN_TOP) !== P.U_AUTO && sizeUnit(c, P.P_MARGIN_BOTTOM) !== P.U_AUTO) {
        // Stretching stops at the item's own min/max-height.
        const want = clampH(c, lineCross[l] - marginV(c, innerW), innerW, innerH);
        // An item sized against an indefinite height has to lay out again even when its content
        // already happened to fill the line: percentages inside it need the definite height.
        if (want !== c.h || Number.isNaN(innerH)) layoutBox(c, innerW, innerH, c.w, want, false);
      }
    }
  }

  const [leadCross, betweenCross] = contentOffsets(mode === P.AC_STRETCH ? P.J_START : mode, freeCross, lines.length, el.su[P.P_ALIGN_CONTENT] === P.U_SAFE);
  const totalCross = Number.isNaN(innerH) ? usedCross : innerH;
  const lineTop: number[] = [];
  let top = leadCross;
  for (let l = 0; l < lines.length; l++) {
    lineTop.push(top);
    top += lineCross[l] + (lines.length > 1 ? crossGap + betweenCross : 0);
  }
  // `space-between` leaves the last line's end edge on the container's, and a set of lines that
  // fills it does the same; that line takes its position from the end edge, since adding up the
  // shares of the space before it can land a fraction of a pixel short of it.
  if (lines.length > 1 && !Number.isNaN(leadCross) &&
    ((mode === P.J_SPACE_BETWEEN && betweenCross > 0) || usedCross === totalCross)) {
    lineTop[lines.length - 1] = totalCross - lineCross[lines.length - 1];
  }

  for (let l = 0; l < lines.length; l++) {
    const ln = lines[l];
    const lineY = crossReverse ? totalCross - lineTop[l] - lineCross[l] : lineTop[l];
    let total = gap * Math.max(0, ln.length - 1);
    let autos = 0;
    for (const i of ln) {
      total += items[i].w + marginH(items[i], innerW);
      if (items[i].su[P.P_MARGIN_LEFT] === P.U_AUTO) autos++;
      if (items[i].su[P.P_MARGIN_RIGHT] === P.U_AUTO) autos++;
    }
    // The line's baselines: the items that line up on a first baseline share the largest distance
    // from the line's cross-start edge to one of theirs, and the ones that line up on a last
    // baseline share the largest distance from one of theirs to the cross-end edge (CSS Flexbox
    // 8.5). An item with no baseline of its own synthesizes one from its border box's end edge.
    let lineBaseline = -Infinity;
    let lineLastBaseline = -Infinity;
    for (const i of ln) {
      const c = items[i];
      const mode = alignFor(el, c);
      if (mode !== P.A_BASELINE && mode !== P.A_LAST_BASELINE) continue;
      if (sizeUnit(c, P.P_MARGIN_TOP) === P.U_AUTO || sizeUnit(c, P.P_MARGIN_BOTTOM) === P.U_AUTO) continue;
      if (mode === P.A_LAST_BASELINE) {
        const b = naturalLastBaseline(c);
        const off = (c.h - (b >= 0 ? b : c.h)) + zeroIfNaN(len(c, P.P_MARGIN_BOTTOM, innerW));
        if (off > lineLastBaseline) lineLastBaseline = off;
      } else {
        const b = naturalBaseline(c);
        const off = zeroIfNaN(len(c, P.P_MARGIN_TOP, innerW)) + (b >= 0 ? b : c.h);
        if (off > lineBaseline) lineBaseline = off;
      }
    }
    // Auto margins take the free space, each an equal share, before justify-content gets any.
    const autoSpace = autos > 0 ? Math.max(0, innerW - total) / autos : 0;
    const jc = mainPacking(el, true, el.sv[P.P_JUSTIFY_CONTENT]);
    const [lead, between] = autos > 0 ? [0, 0] : justifyOffsets(jc, innerW - total, ln.length, el.su[P.P_JUSTIFY_CONTENT] === P.U_SAFE);
    // Auto margins and `space-between` both leave the last item's end edge on the container's, so
    // that item takes its position from the end edge: adding up the shares of the space before it
    // can land a fraction of a pixel short of it. Items spilling out of the container keep their
    // packed positions instead.
    const toEnd = (autos > 0 && innerW > total) || (jc === P.J_SPACE_BETWEEN && between > 0);
    let pos = lead;
    let k = -1;
    for (const i of ln) {
      k++;
      const c = items[i];
      const ml = sizeUnit(c, P.P_MARGIN_LEFT) === P.U_AUTO ? autoSpace : zeroIfNaN(len(c, P.P_MARGIN_LEFT, innerW));
      const mr = sizeUnit(c, P.P_MARGIN_RIGHT) === P.U_AUTO ? autoSpace : zeroIfNaN(len(c, P.P_MARGIN_RIGHT, innerW));
      const autoT = sizeUnit(c, P.P_MARGIN_TOP) === P.U_AUTO;
      const autoB = sizeUnit(c, P.P_MARGIN_BOTTOM) === P.U_AUTO;
      const mt = autoT ? 0 : zeroIfNaN(len(c, P.P_MARGIN_TOP, innerW));
      const mb = autoB ? 0 : zeroIfNaN(len(c, P.P_MARGIN_BOTTOM, innerW));
      const outerW = c.w + ml + mr;
      const outerH = c.h + mt + mb;
      if (toEnd && k === ln.length - 1) pos = innerW - outerW;
      // An auto margin in the cross axis takes the slack there, and align-self has no say.
      let y = 0;
      if (autoT || autoB) {
        const slack = Math.max(0, lineCross[l] - outerH);
        if (autoT && autoB) y = slack / 2;
        else if (autoT) y = slack;
      } else if (lineBaseline > -Infinity && alignFor(el, c) === P.A_BASELINE) {
        // Its baseline lands on the line's, whichever edge of its box that leaves at.
        const b = naturalBaseline(c);
        y = lineBaseline - ((b >= 0 ? b : c.h) + mt);
      } else if (lineLastBaseline > -Infinity && alignFor(el, c) === P.A_LAST_BASELINE) {
        // The last group packs against the cross-end: the item reaching furthest past its baseline
        // takes the group's line there and the rest hang before it.
        const b = naturalLastBaseline(c);
        y = (lineCross[l] - lineLastBaseline) - (b >= 0 ? b : c.h) - mt;
      } else {
        y = alignOffset(alignFor(el, c), lineCross[l] - outerH, alignSafe(el, c));
      }
      // wrap-reverse turns the cross axis around, so the line and the item are measured from it.
      if (crossReverse) y = lineCross[l] - outerH - y;
      c.x = pl + (reverse !== rtl ? innerW - pos - outerW : pos) + ml;
      c.y = pt + lineY + y + mt;
      place(c);
      pos += outerW + gap + between;
    }
  }

  // The container's first baseline set comes from the line at the cross-start edge and its last
  // from the one at the cross-end, which `wrap-reverse` turns around (CSS Flexbox 8.5). A
  // max-height can lay the container out again, so the earlier pass's baselines are replaced.
  if (lines.length > 0 && lines[0].length > 0) {
    const first = lines[crossReverse ? lines.length - 1 : 0];
    const last = lines[crossReverse ? 0 : lines.length - 1];
    el.lineBaseline.length = 0;
    el.lineCentral.length = 0;
    el.lineBaseline.push(lineBaselineSet(el, items, first, true,
      reverse ? first[first.length - 1] : first[0], reverse ? first[0] : first[first.length - 1], true));
    el.lineBaseline.push(lineBaselineSet(el, items, last, false,
      reverse ? last[last.length - 1] : last[0], reverse ? last[0] : last[last.length - 1], true));
  }
  placeOutOfFlowChildren(el, innerW, innerH, innerW, totalCross, pl, pt, true, reverse);
  return totalCross;
}

export function layoutFlexColumn(el: Node, innerW: number, innerH: number, pl: number, pt: number,
  mainDefinite = false): number {
  const items = orderedItems(el);
  // A column's cross axis is the inline one, which a right-to-left direction runs the other way.
  const rtl = inlineMirrored(el);
  const gap = zeroIfNaN(len(el, P.P_ROW_GAP, innerW)); // between items in a column
  const crossGap = zeroIfNaN(len(el, P.P_COLUMN_GAP, innerW)); // between lines
  const wrapMode = el.sv[P.P_FLEX_WRAP];
  // Without a definite height there is nothing to wrap against, so the items share one line.
  const wrap = wrapMode !== P.FW_NOWRAP && !Number.isNaN(innerH);
  const reverse = el.sv[P.P_FLEX_DIRECTION] === P.FD_COLUMN_REVERSE;
  const crossReverse = wrapMode === P.FW_WRAP_REVERSE;

  // Hypothetical sizes: the main size at the cross size the item would have, which is the
  // container's width when it stretches into a single line. In a wrapping container the lines
  // are as wide as their items' fit-content widths.
  const bases: number[] = [];
  // Automatic minimum sizes (min-height: auto): the item's min-content height, measured with its
  // percentage heights unresolved, since the height it would resolve them against comes from
  // this very flexing. A scroll container can shrink to zero instead.
  const minH: number[] = [];
  for (const c of items) {
    const stretch = !wrap && alignFor(el, c) === P.A_STRETCH && c.su[P.P_WIDTH] === P.U_AUTO;
    const avail = innerW - marginH(c, innerW);
    // An auto cross size is fit-content for the measurement: it is what decides the main size of
    // an item whose main size comes from its preferred aspect ratio (CSS Flexbox 9.2.3, part E).
    // The flex base size ignores the item's own min/max main sizes, so its min-height and
    // max-height don't transfer into this width either.
    // Only an item that neither stretches nor sits in a column of one line without a ratio uses
    // it, so the others aren't asked for their content widths at all.
    const fitUsed = !stretch && (wrap || (aspectRatio(c) > 0 && c.su[P.P_WIDTH] === P.U_AUTO));
    const fitCross = !fitUsed ? NaN
      : Math.min(maxContentWidth(c, innerW, innerH, NaN, false), Math.max(minContentWidth(c, innerW, innerH, NaN, false), avail));
    // An image with a ratio but no size of its own fills the cross space it is given, while an
    // inline <svg> that states a block size takes its inline size from the ratio.
    const svgH = isSvgElement(c) ? specH(c, innerW, innerH) : NaN;
    const cross = aspectRatio(c) > 0 && !hasNaturalSize(c)
      ? (!Number.isNaN(svgH) ? aspectW(c, svgH, innerW) : avail)
      : fitCross;
    const fw = stretch ? avail : wrap ? fitCross : aspectRatio(c) > 0 && c.su[P.P_WIDTH] === P.U_AUTO ? cross : NaN;
    const specMin = len(c, P.P_MIN_HEIGHT, innerH);
    if (isIntrinsicSize(c.su[P.P_MIN_HEIGHT])) {
      // A min-content (or max-content, fit-content) minimum in the block axis is the height the
      // content takes at the inline size the keyword names, and beats a smaller maximum.
      minH.push(Math.max(0, fitHeight(c, 0, innerW, innerH)));
    } else if (c.su[P.P_MIN_HEIGHT] !== P.U_AUTO && !Number.isNaN(specMin)) {
      minH.push(Math.max(0, specMin + (c.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : padV(c, innerW))));
    } else if (isScrollContainer(c)) {
      minH.push(0);
    } else {
      // Its content as a height of its own, capped by a definite height (CSS Flexbox 4.5).
      layoutBox(c, innerW, NaN, fw, NaN, !stretch && !wrap, true);
      const spec = specH(c, innerW, innerH);
      let content = clampH(c, Number.isNaN(spec) ? c.h : Math.min(c.h, spec), innerW, innerH);
      // A definite width — the item's own, or the line's when it stretches — transfers through a
      // preferred aspect ratio to give a height the item can't shrink below.
      if (!isReplaced(c) && aspectRatio(c) > 0) {
        let cross = specW(c, innerW);
        if (Number.isNaN(cross)) cross = stretch ? avail : NaN;
        if (!Number.isNaN(cross)) {
          content = Math.max(content, clampH(c, aspectH(c, clampW(c, cross, innerW), innerW), innerW, innerH));
        }
        // A max-width transfers through the ratio as an upper bound on the height the content
        // asks for (CSS Flexbox 4.5).
        const maxW = len(c, P.P_MAX_WIDTH, innerW);
        if (!Number.isNaN(maxW)) {
          const border = c.sv[P.P_BOX_SIZING] === P.BS_BORDER;
          const width = Math.max(padH(c, innerW), maxW + (border ? 0 : padH(c, innerW)));
          content = Math.min(content, clampH(c, aspectH(c, width, innerW), innerW, innerH));
        }
      }
      minH.push(Math.max(0, content));
    }
    layoutBox(c, innerW, innerH, fw, NaN, !stretch && !wrap);
    let base = flexBase(c, innerH, false, innerW);
    if (Number.isNaN(base) && c.su[P.P_FLEX_BASIS] === P.U_PCT && Number.isNaN(innerH)) {
      // A percentage flex-basis against an indefinite height behaves as `content`, so the item's
      // specified height is ignored (CSS Flexbox 9.2.3).
      layoutBox(c, innerW, NaN, fw, NaN, !stretch && !wrap, true);
      base = c.h;
      layoutBox(c, innerW, innerH, fw, NaN, !stretch && !wrap);
    }
    if (Number.isNaN(base)) {
      if (aspectRatio(c) > 0 && c.su[P.P_HEIGHT] === P.U_AUTO) {
        // The flex base size leaves out the item's own min/max-height (CSS Flexbox 9.2.3), so the
        // height a preferred aspect ratio gives it stands as measured.
        layoutBox(c, innerW, innerH, c.w, NaN, false, true);
      }
      base = c.h;
    }
    bases.push(base);
  }
  // A line breaks on the hypothetical main sizes: the base sizes held inside min/max-height.
  const hypo: number[] = [];
  for (let i = 0; i < items.length; i++) {
    hypo.push(Math.max(minH[i], Math.min(bases[i], maxMainHeight(items[i], innerW, innerH))));
  }
  const lines = flexLinesV(items, hypo, gap, Number.isNaN(innerH) ? 0 : innerH, wrap, innerW);

  const lineCross: number[] = [];
  for (const ln of lines) {
    let used = gap * Math.max(0, ln.length - 1);
    const lb: number[] = [];
    const lmins: number[] = [];
    const lmaxes: number[] = [];
    const li: Node[] = [];
    for (const i of ln) {
      used += bases[i] + marginV(items[i], innerW);
      lb.push(bases[i]);
      lmins.push(minH[i]);
      lmaxes.push(maxMainHeight(items[i], innerW, innerH));
      li.push(items[i]);
    }
    const sizes = Number.isNaN(innerH) ? lb : resolveFlexible(li, lb, innerH - used, lmins, lmaxes, lineGrows(items, ln, hypo, gap, innerH, false, innerW));
    // Without a definite height there is no free space to distribute, so a hypothetical main size
    // is the flex base size held within min/max-height. A minimum above the maximum wins, as it
    // does everywhere else a size is clamped (CSS Sizing 3 §5.2).
    if (Number.isNaN(innerH)) for (let k = 0; k < ln.length; k++) sizes[k] = Math.max(Math.min(sizes[k], lmaxes[k]), lmins[k]);
    let cross = 0;
    for (let k = 0; k < ln.length; k++) {
      const c = items[ln[k]];
      const autoW = c.su[P.P_WIDTH] === P.U_AUTO;
      const stretch = !wrap && alignFor(el, c) === P.A_STRETCH && autoW;
      // A definite main size makes the items' main sizes definite too, so their content's
      // percentage heights resolve against them however the measurement pass came out. An auto
      // width is then measured again: the size the main size gives the content is what it takes.
      const definite = !Number.isNaN(innerH);
      const fitW = definite && autoW && !stretch && !wrap;
      const keepW = autoW && (aspectRatio(c) > 0 || fitW) ? NaN : c.w;
      if (definite || sizes[k] !== c.h) layoutBox(c, innerW, innerH, keepW, sizes[k], fitW);
      cross = Math.max(cross, c.w + marginH(c, innerW));
    }
    lineCross.push(cross);
  }

  // A nowrap column is as wide as the container; wrapped columns share its width through align-content.
  if (!wrap) lineCross[0] = innerW;
  let usedCross = crossGap * Math.max(0, lines.length - 1);
  for (const w of lineCross) usedCross += w;
  const mode = contentPacking(el, crossReverse);
  let freeCross = innerW - usedCross;
  // align-content: stretch grows every line, even a lone one, by an equal share of the space.
  if (mode === P.AC_STRETCH && freeCross > 0) {
    for (let l = 0; l < lineCross.length; l++) lineCross[l] += freeCross / lines.length;
    usedCross = innerW;
    freeCross = 0;
  }
  for (let l = 0; l < lines.length; l++) {
    for (const i of lines[l]) {
      const c = items[i];
      // A column's cross axis runs down the page in a container that runs down it, so the cross
      // size the stretch fills is the item's height; `sizeUnit` asks the property that names it
      // in the item's own axes.
      if (alignFor(el, c) === P.A_STRETCH && sizeUnit(c, P.P_WIDTH) === P.U_AUTO &&
        sizeUnit(c, P.P_MARGIN_LEFT) !== P.U_AUTO && sizeUnit(c, P.P_MARGIN_RIGHT) !== P.U_AUTO) {
        // Stretching stops at the item's own min/max-width.
        const want = clampW(c, lineCross[l] - marginH(c, innerW), innerW);
        // A narrower item can wrap into more lines, so an auto height is measured again; a height
        // that the flexing settled keeps its size.
        const keepH = Number.isNaN(innerH) && c.su[P.P_HEIGHT] === P.U_AUTO ? NaN : c.h;
        if (want !== c.w) layoutBox(c, innerW, innerH, want, keepH, false);
      }
    }
  }

  const [leadCross, betweenCross] = contentOffsets(mode === P.AC_STRETCH ? P.J_START : mode, freeCross, lines.length, el.su[P.P_ALIGN_CONTENT] === P.U_SAFE);
  const lineLeft: number[] = [];
  let left = leadCross;
  for (let l = 0; l < lines.length; l++) {
    lineLeft.push(left);
    left += lineCross[l] + (lines.length > 1 ? crossGap + betweenCross : 0);
  }
  // `space-between` leaves the last line's end edge on the container's, and a set of lines that
  // fills it does the same; that line takes its position from the end edge, since adding up the
  // shares of the space before it can land a fraction of a pixel short of it.
  if (lines.length > 1 && !Number.isNaN(innerW) && !Number.isNaN(leadCross) &&
    ((mode === P.J_SPACE_BETWEEN && betweenCross > 0) || usedCross === innerW)) {
    lineLeft[lines.length - 1] = innerW - lineCross[lines.length - 1];
  }

  // The lines run side by side, so the content height is the tallest of them.
  let usedMain = 0;
  for (const ln of lines) {
    let s = gap * Math.max(0, ln.length - 1);
    for (const i of ln) s += items[i].h + marginV(items[i], innerW);
    usedMain = Math.max(usedMain, s);
  }
  // An auto height ends up at the content height, held between min-height and max-height;
  // justify-content and a reversed axis pack against that size, not against the room a
  // max-height allowed for wrapping. A box whose height is already definite — it was stretched
  // into a grid area, say — packs against that height instead of shrinking to its items.
  let main = innerH;
  if (!mainDefinite && el.su[P.P_HEIGHT] === P.U_AUTO) {
    const adj = el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? padV(el, innerW) : 0;
    const minH = len(el, P.P_MIN_HEIGHT, innerH);
    const maxH = len(el, P.P_MAX_HEIGHT, innerH);
    main = usedMain;
    if (!Number.isNaN(minH)) main = Math.max(main, minH - adj);
    if (!Number.isNaN(maxH)) main = Math.min(main, maxH - adj);
  }
  if (Number.isNaN(main)) main = usedMain;
  for (let l = 0; l < lines.length; l++) {
    const ln = lines[l];
    const lineX = crossReverse ? innerW - lineLeft[l] - lineCross[l] : lineLeft[l];
    let total = gap * Math.max(0, ln.length - 1);
    let autos = 0;
    for (const i of ln) {
      total += items[i].h + marginV(items[i], innerW);
      if (items[i].su[P.P_MARGIN_TOP] === P.U_AUTO) autos++;
      if (items[i].su[P.P_MARGIN_BOTTOM] === P.U_AUTO) autos++;
    }
    // Baseline alignment across the cross axis: each item supplies a baseline across the
    // container, and the items line up in two groups, one nearest the cross-start and one
    // nearest the cross-end (CSS Flexbox 8.5, CSS Align 9). `offsets` holds the items that
    // take part, and `sides` which group each is in.
    const offsets: number[] = [];
    const sides: boolean[] = [];
    let startTop = -Infinity;
    let endBottom = -Infinity;
    for (const i of ln) {
      const c = items[i];
      const mode = alignFor(el, c);
      const noAuto = sizeUnit(c, P.P_MARGIN_LEFT) !== P.U_AUTO && sizeUnit(c, P.P_MARGIN_RIGHT) !== P.U_AUTO;
      if (!noAuto || (mode !== P.A_BASELINE && mode !== P.A_LAST_BASELINE)) {
        offsets.push(NaN);
        sides.push(false);
        continue;
      }
      const [b, side] = crossBaseline(el, c, mode === P.A_LAST_BASELINE);
      offsets.push(b);
      sides.push(side);
      if (!side) startTop = Math.max(startTop, zeroIfNaN(len(c, P.P_MARGIN_LEFT, innerW)) + b);
      else endBottom = Math.max(endBottom, (c.w - b) + zeroIfNaN(len(c, P.P_MARGIN_RIGHT, innerW)));
    }
    // Auto margins take the free space, each an equal share, before justify-content gets any.
    const mainSize = main;
    const autoSpace = autos > 0 ? Math.max(0, mainSize - total) / autos : 0;
    const jc = mainPacking(el, false, el.sv[P.P_JUSTIFY_CONTENT]);
    const [lead, between] = autos > 0 ? [0, 0] : justifyOffsets(jc, mainSize - total, ln.length, el.su[P.P_JUSTIFY_CONTENT] === P.U_SAFE);
    // Auto margins and `space-between` both leave the last item's end edge on the container's, so
    // that item takes its position from the end edge: adding up the shares of the space before it
    // can land a fraction of a pixel short of it. Items spilling out of the container keep their
    // packed positions instead.
    const toEnd = (autos > 0 && mainSize > total) || (jc === P.J_SPACE_BETWEEN && between > 0);
    let pos = lead;
    let k = -1;
    for (const i of ln) {
      k++;
      const c = items[i];
      const mt = sizeUnit(c, P.P_MARGIN_TOP) === P.U_AUTO ? autoSpace : zeroIfNaN(len(c, P.P_MARGIN_TOP, innerW));
      const mb = sizeUnit(c, P.P_MARGIN_BOTTOM) === P.U_AUTO ? autoSpace : zeroIfNaN(len(c, P.P_MARGIN_BOTTOM, innerW));
      const autoL = sizeUnit(c, P.P_MARGIN_LEFT) === P.U_AUTO;
      const autoR = sizeUnit(c, P.P_MARGIN_RIGHT) === P.U_AUTO;
      const ml = autoL ? 0 : zeroIfNaN(len(c, P.P_MARGIN_LEFT, innerW));
      const mr = autoR ? 0 : zeroIfNaN(len(c, P.P_MARGIN_RIGHT, innerW));
      const outerW = c.w + ml + mr;
      const outerH = c.h + mt + mb;
      if (toEnd && k === ln.length - 1) pos = mainSize - outerH;
      // An auto margin in the cross axis takes the slack there, and align-self has no say.
      let x = 0;
      if (autoL || autoR) {
        const slack = Math.max(0, lineCross[l] - outerW);
        if (autoL && autoR) x = slack / 2;
        else if (autoL) x = slack;
      } else if (!Number.isNaN(offsets[k])) {
        // Its baseline lands on its group's: the group is as far from its edge as the item
        // reaching furthest across the container.
        const base = sides[k] ? lineCross[l] - endBottom : startTop;
        x = base - offsets[k] - ml;
      } else {
        x = alignOffset(crossAlign(el, c, false), lineCross[l] - outerW, alignSafe(el, c));
      }
      if (crossReverse) x = lineCross[l] - outerW - x;
      // A baseline group in a vertical writing mode sits from the block axis's start edge,
      // which a right-to-left direction does not turn there — only wrap-reverse moves it
      // (Chrome's behaviour; the vertical-axis baseline is synthesized).
      const mirror = rtl && !(isVerticalText(el) && !Number.isNaN(offsets[k]));
      c.x = mirror ? pl + innerW - lineX - x - outerW + ml : pl + lineX + x + ml;
      c.y = pt + (reverse ? main - pos - outerH : pos) + mt;
      place(c);
      pos += outerH + gap + between;
    }
  }

  // A column's baselines come from its cross-start and cross-end lines, which `wrap-reverse`
  // turns around, and are the item at each line's main-axis start or end: an item that lines up
  // on a baseline here does so across the inline axis, not along this one (CSS Flexbox 8.5).
  if (lines.length > 0 && lines[0].length > 0) {
    const first = lines[crossReverse ? lines.length - 1 : 0];
    const last = lines[crossReverse ? 0 : lines.length - 1];
    el.lineBaseline.length = 0;
    el.lineCentral.length = 0;
    el.lineBaseline.push(lineBaselineSet(el, items, first, true,
      reverse ? first[first.length - 1] : first[0], reverse ? first[0] : first[first.length - 1], false));
    el.lineBaseline.push(lineBaselineSet(el, items, last, false,
      reverse ? last[last.length - 1] : last[0], reverse ? last[0] : last[last.length - 1], false));
  }
  placeOutOfFlowChildren(el, innerW, innerH, main, usedCross, pl, pt, false, reverse);
  // With an auto height the container shrinks to its content (clamped by min/max-height later);
  // an innerH taken from a max-height is only the space the items pack within.
  return el.su[P.P_HEIGHT] === P.U_AUTO ? usedMain : main;
}
