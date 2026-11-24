// Scroll snap: the position a scroll lands on.
//
// A scroll container with a scroll-snap-type snaps its offset onto a snap position: the offset at
// which one of its snap areas lines up with the snapport. A snap area is a box that sets
// scroll-snap-align on an axis and whose nearest scroll container on that axis is this one; the
// snapport is the scrollport shrunk by scroll-padding; and each area counts grown by its
// scroll-margin. A scroll lands on the nearest such position it can reach — any of them when the
// type is mandatory — and on a container that snaps both axes the two axes agree on a pair of
// positions whose areas stay visible together (CSS Scroll Snap 1, 3-6).
//
// The layout calls `snapAfterLayout()` once a flush has settled, so positions follow the boxes
// they belong to, the first layout included, and the DOM passes its script scrolls through
// `snapScrollPosition()` before they jump or travel.

import * as P from "../../shared/props.ts";
import { Element, Node, boxKids, document } from "../dom.ts";
import { isRtl, usedWritingMode } from "../style.ts";
import { lenPhys, scriptScrollsX, scriptScrollsY, zeroIfNaN } from "./box-model.ts";
import { containingBlock } from "./positioned.ts";
import { stickyShift } from "./sticky.ts";
import { invalidatePaint } from "../invalidation.ts";
import { setSnapScrollPositionHook } from "../snap-hook.ts";
import { forEachScroller } from "./box.ts";

const AXIS_NONE = 0;
const AXIS_START = 1;
const AXIS_END = 2;
const AXIS_CENTER = 3;

/** How much of the snapport a proximity snap may reach from the offset a scroll asks for. */
const PROXIMITY_RATIO = 1 / 3;

/** A border box in the scroll container's border-box frame, before this scroll's own offset. */
interface SnapRect {
  l: number;
  t: number;
  r: number;
  b: number;
}

/** A snap area, with the alignment it carries on each axis of the container. */
interface AreaData {
  el: Element;
  rect: SnapRect;
  ax: number;
  ay: number;
  /** Whether this container takes the area on each axis, through the containing-block chain. */
  x: boolean;
  y: boolean;
}

/** A position an area offers on an axis, and the cross offsets at which the area shows there. */
interface Cand {
  pos: number;
  area: Element;
  visible: number[];
}

/** What a snap search found: the offset on each axis, and whether that axis found a position. */
interface SnapResult {
  x: number;
  y: number;
  foundX: boolean;
  foundY: boolean;
}

/**
 * The axis group a scroll-snap-type names, and its strictness. The stored value spells each
 * group's three keywords together — `x`, `x mandatory`, `x proximity` — so the group counts from
 * one (1 x, 2 y, 3 block, 4 inline, 5 both, 6 pair) and the mandatory spelling ends in 2.
 */
function snapKind(box: Element): number[] {
  const t = box.sv[P.P_SCROLL_SNAP_TYPE];
  if (t === P.SST_NONE) return [0, 0];
  return [Math.floor((t - 1) / 3) + 1, t % 3 === 2 ? 1 : 2];
}

/** Whether the box's writing mode runs down the page, so its block axis is horizontal. */
function verticalBox(box: Element): boolean {
  return usedWritingMode(box) !== P.WM_HORIZONTAL_TB;
}

/** Whether a writing mode's block direction runs right to left. */
function flippedBlocks(wm: number): boolean {
  return wm === P.WM_VERTICAL_RL || wm === P.WM_SIDEWAYS_RL;
}

/** Whether the element's x axis runs right to left. */
function flippedX(el: Element): boolean {
  const wm = usedWritingMode(el);
  return wm === P.WM_HORIZONTAL_TB ? isRtl(el) : flippedBlocks(wm);
}

/** Whether the element's y axis runs bottom to top. */
function flippedY(el: Element): boolean {
  const wm = usedWritingMode(el);
  if (wm === P.WM_HORIZONTAL_TB) return false;
  return isRtl(el) !== (wm === P.WM_SIDEWAYS_LR);
}

/** A start alignment names the end edge on a flipped axis, and the other way round. */
function flipAlign(v: number): number {
  if (v === AXIS_START) return AXIS_END;
  if (v === AXIS_END) return AXIS_START;
  return v;
}

/**
 * The alignment an area carries on each physical axis of its container. The container's writing
 * mode puts the area's block and inline values on physical axes, and a start or end edge runs
 * from the right or bottom on a flipped axis. An area bigger than the snapport is aligned by its
 * own writing mode instead, so a box too large to show at once still starts where its text does
 * (CSS Scroll Snap 1, 3).
 */
function areaAlign(box: Element, area: Element, rect: SnapRect, portW: number, portH: number): number[] {
  const block = area.sv[P.P_SCROLL_SNAP_ALIGN];
  const inline = area.sv[P.P_SCROLL_SNAP_ALIGN_INLINE];
  let fx = flippedX(box);
  let fy = flippedY(box);
  if (rect.r - rect.l > portW) fx = flippedX(area);
  if (rect.b - rect.t > portH) fy = flippedY(area);
  const inlineAlign = fx ? flipAlign(inline) : inline;
  const blockAlign = fy ? flipAlign(block) : block;
  return usedWritingMode(box) === P.WM_HORIZONTAL_TB
    ? [inlineAlign, blockAlign]
    : [blockAlign, inlineAlign];
}

/** The box an area is laid out against: its containing block when it is out of flow. */
function containingParent(el: Element): Element | null {
  const pos = el.sv[P.P_POSITION];
  if (pos === P.POS_ABSOLUTE || pos === P.POS_FIXED) {
    const cb = containingBlock(el);
    if (cb !== null) return cb as Element;
    // A box with no containing block is laid out against the viewport: an absolute box scrolls
    // with the page, while a fixed one stays where it is and so is no scroll container's area.
    return el.fixedViewport ? null : (document.documentElement as Element);
  }
  return el.parentElement;
}

/**
 * Whether this scroll container takes the area on an axis: walking out through containing blocks,
 * the first scroll container that scrolls that axis owns it, and one between the area and this
 * box keeps it instead. A container that scrolls only one axis hands the other axis on to its
 * ancestors (CSS Scroll Snap 1, 4.1).
 */
function capturedBy(area: Element, box: Element, axisX: boolean): boolean {
  let a = containingParent(area);
  while (a !== null && a !== box) {
    if (axisX ? scriptScrollsX(a) : scriptScrollsY(a)) return false;
    a = containingParent(a);
  }
  return a === box;
}

/** The border-box origin of a box, relative to the container's border box before it scrolls. */
function localOrigin(el: Element, box: Element): number[] {
  let x = 0;
  let y = 0;
  let e: Element | null = el;
  while (e !== null && e !== box) {
    x += e.x + stickyShift(e, true);
    y += e.y + stickyShift(e, false);
    e = e.parentElement;
  }
  return [x, y];
}

/** The snapport of a box in its border-box frame: the scrollport less its scroll-padding. */
function snapport(box: Element): number[] {
  const root = box === (document.documentElement as Element);
  const clientW = box.clientWidth;
  const clientH = box.clientHeight;
  const pl = zeroIfNaN(lenPhys(box, P.P_SCROLL_PADDING_LEFT, clientW));
  const pt = zeroIfNaN(lenPhys(box, P.P_SCROLL_PADDING_TOP, clientH));
  const pr = zeroIfNaN(lenPhys(box, P.P_SCROLL_PADDING_RIGHT, clientW));
  const pb = zeroIfNaN(lenPhys(box, P.P_SCROLL_PADDING_BOTTOM, clientH));
  // The root element's border box starts where the viewport does; any other box starts at its
  // border edge, and the padding box — the scrollport — sits inside the border.
  const bl = root ? 0 : box.clientLeft;
  const bt = root ? 0 : box.clientTop;
  return [bl + pl, bt + pt, bl + clientW - pr, bt + clientH - pb];
}

/** The farthest offset the box can scroll on each axis. */
function maxOffsets(box: Element): number[] {
  return [Math.max(0, box.scrollWidth - box.clientWidth), Math.max(0, box.scrollHeight - box.clientHeight)];
}

/** The area's border box grown by its scroll margin, in the container's border-box frame. */
function areaRect(area: Element, box: Element, clientW: number, clientH: number): SnapRect {
  const o = localOrigin(area, box);
  const ml = zeroIfNaN(lenPhys(area, P.P_SCROLL_MARGIN_LEFT, clientW));
  const mr = zeroIfNaN(lenPhys(area, P.P_SCROLL_MARGIN_RIGHT, clientW));
  const mt = zeroIfNaN(lenPhys(area, P.P_SCROLL_MARGIN_TOP, clientH));
  const mb = zeroIfNaN(lenPhys(area, P.P_SCROLL_MARGIN_BOTTOM, clientH));
  const l = o[0] - ml;
  const t = o[1] - mt;
  return { l, t, r: l + area.w + ml + mr, b: t + area.h + mt + mb };
}

/** Collects the snap areas under a box, in flat-tree order, with their alignments resolved. */
function collectAreas(box: Element, node: Node, portW: number, portH: number, out: AreaData[]): void {
  const clientW = box.clientWidth;
  const clientH = box.clientHeight;
  for (const kid of boxKids(node)) {
    if (!kid.isElementNode) continue;
    const el = kid as Element;
    if (el.pseudoKind !== P.PE_NONE) continue;
    const rect = areaRect(el, box, clientW, clientH);
    const al = areaAlign(box, el, rect, portW, portH);
    out.push({
      el,
      rect,
      ax: al[0],
      ay: al[1],
      x: capturedBy(el, box, true),
      y: capturedBy(el, box, false),
    });
    collectAreas(box, el, portW, portH, out);
  }
}

/** The offset at which an area's edge or middle sits on the snapport's. */
function alignedPos(align: number, start: number, end: number, portStart: number, portEnd: number): number {
  if (align === AXIS_START) return start - portStart;
  if (align === AXIS_END) return end - portEnd;
  return (start + end - portStart - portEnd) / 2;
}

/** An aligned position, kept inside what the box can scroll. */
function clippedPos(align: number, start: number, end: number, portStart: number, portEnd: number, max: number): number {
  const v = alignedPos(align, start, end, portStart, portEnd);
  return v < 0 ? 0 : v > max ? max : v;
}

/**
 * The range of cross offsets at which an area stays visible in the snapport, closed at both ends:
 * a zero-sized area at an edge still counts, and an area in negative overflow or clipped past the
 * scrollable range has an empty range, so no offset shows it (CSS Scroll Snap 1, 6).
 */
function visibleRange(lo: number, hi: number, portStart: number, portEnd: number, max: number): number[] {
  let a = lo - portEnd;
  let b = hi - portStart;
  if (a < 0) a = 0;
  if (b > max) b = max;
  return [a, b];
}

function inRange(range: number[], v: number): boolean {
  return v >= range[0] && v <= range[1];
}

/** The position an area offers on an axis, the axis's alignment already resolved. */
function posOf(a: AreaData, axisX: boolean, portX: number[], portY: number[], max: number[]): number {
  return axisX
    ? clippedPos(a.ax, a.rect.l, a.rect.r, portX[0], portX[1], max[0])
    : clippedPos(a.ay, a.rect.t, a.rect.b, portY[0], portY[1], max[1]);
}

/** The cross offsets at which the area shows, measured for the axis it is a candidate on. */
function visibleOf(a: AreaData, axisX: boolean, portX: number[], portY: number[], max: number[]): number[] {
  return axisX
    ? visibleRange(a.rect.t, a.rect.b, portY[0], portY[1], max[1])
    : visibleRange(a.rect.l, a.rect.r, portX[0], portX[1], max[0]);
}

/** The candidates the box's areas offer on one axis, in flat-tree order. */
function candidates(list: AreaData[], axisX: boolean, pair: boolean, portX: number[], portY: number[], max: number[]): Cand[] {
  const out: Cand[] = [];
  for (const a of list) {
    // A paired type keeps only areas that snap on both axes: the two axes have to agree.
    if (pair) {
      if (a.ax === AXIS_NONE || a.ay === AXIS_NONE || !a.x || !a.y) continue;
    } else if (axisX ? (!a.x || a.ax === AXIS_NONE) : (!a.y || a.ay === AXIS_NONE)) continue;
    out.push({ pos: posOf(a, axisX, portX, portY, max), area: a.el, visible: visibleOf(a, axisX, portX, portY, max) });
  }
  return out;
}

/**
 * The candidate nearest `base` whose area shows in the cross axis at `cross`, within the
 * threshold. Candidates arrive in flat-tree order, so the first of equally near areas wins; and
 * an area exactly at the threshold is out, as the proximity range is open there.
 */
function closest(list: Cand[], base: number, cross: number, threshold: number): Cand | null {
  let best: Cand | null = null;
  let bestD = threshold;
  for (const c of list) {
    const d = Math.abs(c.pos - base);
    if (d >= bestD) continue;
    if (!inRange(c.visible, cross)) continue;
    best = c;
    bestD = d;
  }
  return best;
}

/**
 * The candidate nearest `base` that stays in sight with an area chosen on the other axis: the
 * chosen offset has to sit in the candidate's visible range, and the candidate's offset in the
 * chosen area's.
 */
function seekOther(list: Cand[], base: number, chosen: Cand, threshold: number): Cand | null {
  let best: Cand | null = null;
  let bestD = threshold;
  for (const c of list) {
    const d = Math.abs(c.pos - base);
    if (d >= bestD) continue;
    if (!inRange(c.visible, chosen.pos)) continue;
    if (!inRange(chosen.visible, c.pos)) continue;
    best = c;
    bestD = d;
  }
  return best;
}

/** The area a stored target names, when the box still has it and it aligns on the axis. */
function targetOf(list: AreaData[], el: Element | null, axisX: boolean): AreaData | null {
  if (el === null) return null;
  for (const a of list) {
    if (a.el !== el) continue;
    if (axisX ? a.ax === AXIS_NONE || !a.x : a.ay === AXIS_NONE || !a.y) return null;
    return a;
  }
  return null;
}

/** Whether a stored target is still one of the box's areas, whatever its alignment. */
function stillThere(list: AreaData[], el: Element | null): Element | null {
  if (el === null) return null;
  for (const a of list) if (a.el === el) return el;
  return null;
}

/** The distance a 2D candidate sits outside the snapport's box, block axis first. */
function corridor(dx: number, dy: number, portW: number, portH: number): number[] {
  return [dx < 0 ? -dx : dx > portW ? dx - portW : 0, dy < 0 ? -dy : dy > portH ? dy - portH : 0];
}

/** A selection as a candidate, so that one axis can hand its area to the other. */
function candFor(a: AreaData, axisX: boolean, portX: number[], portY: number[], max: number[]): Cand {
  return { pos: posOf(a, axisX, portX, portY, max), area: a.el, visible: visibleOf(a, axisX, portX, portY, max) };
}

/**
 * Chooses the offsets a scroll of `box` to (x, y) lands on. `snapX`/`snapY` name the axes the
 * scroll sets — a scrollTop setter only snaps the y axis, scrollTo() snaps the axes it names,
 * and under a paired type an axis the scroll leaves alone follows the one it sets. `prioritize`
 * has stored targets win over the nearest area, as a relayout does.
 */
function findSnap(box: Element, x: number, y: number, snapX: boolean, snapY: boolean, prioritize: boolean): SnapResult {
  const kind = snapKind(box);
  if (kind[1] === 0) {
    box.snapAreaX = null;
    box.snapAreaY = null;
    return { x, y, foundX: false, foundY: false };
  }
  const both = kind[0] === 5 || kind[0] === 6;
  const pair = kind[0] === 6;
  const setX = snapX && (kind[0] === 1 || both);
  const setY = snapY && (kind[0] === 2 || both);
  if (!setX && !setY) return { x, y, foundX: false, foundY: false };
  // Only a box that scrolls an axis has positions along it; the root scrolls the viewport
  // whatever its own overflow says.
  const root = box === (document.documentElement as Element);
  const canX = setX && (root || scriptScrollsX(box));
  const canY = setY && (root || scriptScrollsY(box));
  if (!canX && !canY) return { x, y, foundX: false, foundY: false };

  const max = maxOffsets(box);
  const port = snapport(box);
  const portX = [port[0], port[2]];
  const portY = [port[1], port[3]];
  // The searches start from the offsets the scroll asks for, kept inside what the box can
  // scroll, so that an area is judged by where the scroll really lands.
  const baseX = x < 0 ? 0 : x > max[0] ? max[0] : x;
  const baseY = y < 0 ? 0 : y > max[1] ? max[1] : y;
  const thresholdX = kind[1] === 2 ? (portX[1] - portX[0]) * PROXIMITY_RATIO : Number.POSITIVE_INFINITY;
  const thresholdY = kind[1] === 2 ? (portY[1] - portY[0]) * PROXIMITY_RATIO : Number.POSITIVE_INFINITY;
  const list: AreaData[] = [];
  collectAreas(box, box, portX[1] - portX[0], portY[1] - portY[0], list);
  const candX = canX ? candidates(list, true, pair, portX, portY, max) : [];
  const candY = canY ? candidates(list, false, pair, portX, portY, max) : [];
  const storedX = box.snapAreaX;
  const storedY = box.snapAreaY;

  // Each axis takes the position nearest the offset asked for, among areas the other axis shows
  // at the offset it will land on — or, after a relayout, the area it was already snapped to.
  let xSel: Cand | null = null;
  let ySel: Cand | null = null;
  if (canX) {
    const target = prioritize ? targetOf(list, storedX, true) : null;
    xSel = target !== null ? candFor(target, true, portX, portY, max) : closest(candX, baseX, baseY, thresholdX);
  }
  if (canY) {
    const target = prioritize ? targetOf(list, storedY, false) : null;
    ySel = target !== null ? candFor(target, false, portX, portY, max) : closest(candY, baseY, baseX, thresholdY);
  }

  if (!pair && canX && canY &&
    (xSel === null || ySel === null || !inRange(xSel.visible, ySel.pos) || !inRange(ySel.visible, xSel.pos))) {
    // Snapping one axis would push the other axis's area out of sight. Keep the axis that asks
    // for less movement — or, after a relayout, the axis whose target is stored — and search the
    // other axis again against it, taking what it finds even when that is nothing.
    let followX: boolean;
    if (xSel !== null && ySel !== null) {
      if (prioritize) {
        // After a relayout, an axis with no stored target follows the one that has one; with
        // both stored, the block axis leads.
        if (storedX === null) followX = false;
        else if (storedY === null) followX = true;
        else followX = verticalBox(box);
      } else {
        followX = Math.abs(xSel.pos - baseX) <= Math.abs(ySel.pos - baseY);
      }
    } else {
      followX = xSel !== null;
    }
    if (followX) {
      if (xSel !== null) ySel = seekOther(candY, baseY, xSel, thresholdY);
    } else if (ySel !== null) {
      xSel = seekOther(candX, baseX, ySel, thresholdX);
    }
  }

  if (pair) {
    // Every pair candidate snaps on both axes, so the axis the scroll leaves alone takes its
    // position from the area the other axis chose.
    if (xSel === null && ySel !== null) {
      const a = targetOf(list, ySel.area, true);
      if (a !== null) xSel = candFor(a, true, portX, portY, max);
    }
    if (ySel === null && xSel !== null) {
      const a = targetOf(list, xSel.area, false);
      if (a !== null) ySel = candFor(a, false, portX, portY, max);
    }
    if (xSel !== null && ySel !== null && xSel.area !== ySel.area) {
      // The two axes chose different areas: keep the pair nearer the offset asked for, and the
      // block axis's pair when the two are equally near.
      const xa = targetOf(list, xSel.area, false);
      const ya = targetOf(list, ySel.area, true);
      const fromX = xa === null ? xSel.pos : posOf(xa, false, portX, portY, max);
      const fromY = ya === null ? ySel.pos : posOf(ya, true, portX, portY, max);
      const dx = xSel.pos - baseX;
      const dy = ySel.pos - baseY;
      const nearX = dx * dx + (fromX - baseY) * (fromX - baseY);
      const nearY = (fromY - baseX) * (fromY - baseX) + dy * dy;
      if (nearX > nearY || (nearX === nearY && !verticalBox(box))) {
        if (ya !== null) xSel = candFor(ya, true, portX, portY, max);
      } else if (xa !== null) {
        ySel = candFor(xa, false, portX, portY, max);
      }
    }
  }

  if (xSel === null && ySel === null && canX && canY) {
    // Neither axis found a position in its own corridor: an area aligned on both axes may still
    // offer a pair, and the pair that keeps the block axis nearest wins (CSS Scroll Snap 1, 6).
    let bestY = Number.POSITIVE_INFINITY;
    let bestX = Number.POSITIVE_INFINITY;
    for (const a of list) {
      if (a.ax === AXIS_NONE || a.ay === AXIS_NONE || !a.x || !a.y) continue;
      const px = posOf(a, true, portX, portY, max);
      const py = posOf(a, false, portX, portY, max);
      const dx = px - baseX;
      const dy = py - baseY;
      if (Math.abs(dx) > thresholdX || Math.abs(dy) > thresholdY) continue;
      const d = corridor(dx, dy, portX[1] - portX[0], portY[1] - portY[0]);
      if (!(d[1] < bestY || (d[1] === bestY && d[0] < bestX))) continue;
      bestY = d[1];
      bestX = d[0];
      xSel = candFor(a, true, portX, portY, max);
      ySel = candFor(a, false, portX, portY, max);
    }
  }

  // An axis that a script scroll sets but finds no position on ends unsnapped, so a later layout
  // must not pull the box back to the area it was on. An axis the scroll leaves alone — and every
  // axis of a relayout — keeps the target it has (CSS Scroll Snap 1, 4.1.3).
  box.snapAreaX = xSel !== null ? xSel.area : canX && !prioritize ? null : stillThere(list, storedX);
  box.snapAreaY = ySel !== null ? ySel.area : canY && !prioritize ? null : stillThere(list, storedY);
  return {
    x: xSel === null ? x : xSel.pos,
    y: ySel === null ? y : ySel.pos,
    foundX: xSel !== null,
    foundY: ySel !== null,
  };
}

/** The position a programmatic scroll of `box` to (x, y) lands on. */
export function snapScrollPosition(box: Element, x: number, y: number, snapX: boolean, snapY: boolean): number[] {
  const found = findSnap(box, x, y, snapX, snapY, false);
  return [found.x, found.y];
}

/**
 * Snaps a container again after a flush: the areas it was snapped to keep their position — a
 * target that moved drags the scroll with it — and a container with no target takes the nearest
 * position to where it is now.
 */
function resnapBox(box: Element): void {
  const found = findSnap(box, box.scrollX, box.scrollY, true, true, true);
  const x = found.foundX ? found.x : box.scrollX;
  const y = found.foundY ? found.y : box.scrollY;
  if (x === box.scrollX && y === box.scrollY) return;
  box.scrollX = x;
  box.scrollY = y;
  invalidatePaint();
}

/** Resnaps every scroll container under a node. */
function resnapTree(node: Node): void {
  if (node.isElementNode) {
    const el = node as Element;
    if (el.pseudoKind === P.PE_NONE &&
      (scriptScrollsX(el) || scriptScrollsY(el) || el === (document.documentElement as Element))) {
      resnapBox(el);
    }
  }
  for (const kid of boxKids(node)) {
    if (!kid.isElementNode || (kid as Element).pseudoKind !== P.PE_NONE) continue;
    resnapTree(kid);
  }
}

/** Snaps the page's scroll containers once a style or layout flush has settled. */
export function snapAfterLayout(root: Node): void {
  // With incremental layout's set of scroll containers current, only those (and the root, which
  // scrolls the viewport) can have a snap position to keep.
  const visited = forEachScroller(root, (el: Node) => {
    const e = el as Element;
    if (e.isElementNode && e.pseudoKind === P.PE_NONE && (scriptScrollsX(e) || scriptScrollsY(e))) resnapBox(e);
  });
  if (!visited) {
    resnapTree(root);
    return;
  }
  if (root.isElementNode && root === (document.documentElement as Node)) resnapBox(root as Element);
}

setSnapScrollPositionHook(snapScrollPosition);
