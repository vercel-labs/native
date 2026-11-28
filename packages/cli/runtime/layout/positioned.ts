// Out-of-flow boxes: absolute and fixed positioning against their containing blocks.

import * as P from "../../shared/props.ts";
import { Node, document, boxKids } from "../dom.ts";
import { fitHeight, layoutBox } from "./box.ts";
import { aspectRatio, aspectW, borderBottom, borderLeft, borderRight, borderTop, boundedRatioH, clampH, clampW, clipsX, clipsY, display, isIntrinsicSize, isOutOfFlow, isReplaced, len, lenPhys, padV, place, sizeUnit, specH, specW, viewport, zeroIfNaN, allChildren } from "./box-model.ts";
import { contentMinWidth, maxContentWidth } from "./text.ts";
import { isRtl, isVerticalText, lineHeightPx, usedWritingMode } from "../style.ts";
import { hasTransform, pageMatrix } from "../transform.ts";
import { mul } from "../../shared/css/transforms.ts";
import type { Matrix } from "../../shared/css/transforms.ts";
import { hasFilterContext } from "../filters.ts";
import { hasClipPath } from "../clip.ts";
import { hasMask } from "../mask.ts";

// ---------------------------------------------------------------------------
// Out-of-flow boxes
//
// Absolute and fixed boxes are laid out once the rest of the tree has its final geometry: their
// containing block is the padding box of the nearest positioned ancestor (the viewport for fixed
// boxes and for boxes with no positioned ancestor), which only exists then.

/**
 * The containing block of an out-of-flow box, or null for the initial containing block. A
 * transformed box is a containing block for all its descendants, positioned or fixed, as though
 * it had been positioned itself; a filtered one is too (CSS Filter Effects), and so is one
 * clipped to a shape or masked (CSS Masking: clip-path and mask-image both make the box a
 * containing block for its out-of-flow descendants).
 */
export function containingBlock(el: Node): Node | null {
  const fixed = el.sv[P.P_POSITION] === P.POS_FIXED;
  let a = el.parentElement;
  while (a !== null) {
    if (hasTransform(a) || hasFilterContext(a) || hasClipPath(a) || hasMask(a) ||
      a.sv[P.P_PERSPECTIVE] >= 0 || a.sv[P.P_BACKFACE_VISIBILITY] === P.BFV_HIDDEN ||
      (a.sv[P.P_CONTAIN] & P.CONTAIN_LAYOUT) !== 0) return a;
    if (!fixed && a.sv[P.P_POSITION] !== P.POS_STATIC) return a;
    a = a.parentElement;
  }
  return null;
}

// The inline box a split inline element forms is the bounding box of its fragments, as the
// padding box of its first and last fragments (CSS 2.1 10.1). These carry the box found for the
// containing block, in the border box coordinates of the block container that holds the
// fragments, and that container.
let inlineBoxX = 0;
let inlineBoxY = 0;
let inlineBoxW = 0;
let inlineBoxH = 0;
let inlineBoxContainer: Node | null = null;

/**
 * Finds the inline box `el` generates: the union of the fragments it owns in the block container
 * around it. Returns false when it generates no fragment (an empty inline still gets its two
 * edges, so this only happens outside any line box).
 */
function findInlineBox(el: Node): boolean {
  for (let c = el.parentElement; c !== null; c = c.parentElement) {
    let left = NaN;
    let top = NaN;
    let right = NaN;
    let bottom = NaN;
    for (let i = 0; i < c.fragStyle.length; i++) {
      if (c.fragStyle[i] !== el) continue;
      const x = c.fragX[i];
      const t = c.fragTop[i];
      const r = x + c.fragW[i];
      const b = t + lineHeightPx(el);
      if (Number.isNaN(left) || x < left) left = x;
      if (Number.isNaN(top) || t < top) top = t;
      if (Number.isNaN(right) || r > right) right = r;
      if (Number.isNaN(bottom) || b > bottom) bottom = b;
    }
    if (!Number.isNaN(left)) {
      // Fragments start at the inline's content edge; the padding box reaches back over its
      // padding. Padding percentages resolve against the block container's content width.
      const basis = c.contentW;
      const pl = zeroIfNaN(len(el, P.P_PADDING_LEFT, basis));
      const pr = zeroIfNaN(len(el, P.P_PADDING_RIGHT, basis));
      const pt = zeroIfNaN(len(el, P.P_PADDING_TOP, basis));
      const pb = zeroIfNaN(len(el, P.P_PADDING_BOTTOM, basis));
      inlineBoxX = left - pl;
      inlineBoxY = top - pt;
      inlineBoxW = right - left + pl + pr;
      inlineBoxH = bottom - top + pt + pb;
      inlineBoxContainer = c;
      return true;
    }
  }
  return false;
}

/**
 * Sum of x (or y) from the element's parent up to, but not including, `stop`. A null stop sums
 * all the way through the root, whose own x/y place it in the viewport.
 */
function chainOffset(el: Node, stop: Node | null, horizontal: boolean): number {
  let s = 0;
  let a = el.parentElement;
  while (a !== null && a !== stop) {
    s += horizontal ? a.x : a.y;
    a = a.parentElement;
  }
  return s;
}

/** Lays out and places one out-of-flow box, then the out-of-flow boxes inside it. */
export function placeOutOfFlow(el: Node): void {
  const cb = containingBlock(el);
  // An inline box is a containing block for its absolutely positioned descendants; it is the
  // padding box of the fragments it generates (CSS 2.1 10.1).
  const inlineCb = cb !== null && display(cb) === P.D_INLINE && !isReplaced(cb) && findInlineBox(cb);
  let cbW: number;
  let cbH: number;
  // A grid child placed in a definite area takes that area as its containing block, which starts
  // inside the grid's padding box (CSS Grid 9.2).
  const gridArea = cb !== null && el.gridCbValid &&
    (display(cb) === P.D_GRID || display(cb) === P.D_INLINE_GRID ||
      display(cb) === P.D_GRID_LANES || display(cb) === P.D_INLINE_GRID_LANES);
  let aox = 0;
  let aoy = 0;
  if (cb === null) {
    // The initial containing block is the viewport.
    cbW = viewport.w;
    cbH = viewport.h;
  } else if (gridArea) {
    cbW = Math.max(0, el.gridCbW);
    cbH = Math.max(0, el.gridCbH);
    aox = el.gridCbX - borderLeft(cb);
    aoy = el.gridCbY - borderTop(cb);
  } else if (inlineCb) {
    cbW = Math.max(0, inlineBoxW);
    cbH = Math.max(0, inlineBoxH);
  } else {
    cbW = Math.max(0, cb.w - borderLeft(cb) - borderRight(cb));
    cbH = Math.max(0, cb.h - borderTop(cb) - borderBottom(cb));
  }
  // Offsets are from the containing block's padding box, which starts just inside its border. An
  // inline containing block's box is where its fragments were placed, not at an ancestor's x/y.
  const padX = cb === null || inlineCb ? 0 : borderLeft(cb);
  const padY = cb === null || inlineCb ? 0 : borderTop(cb);
  const coX = inlineCb ? chainOffset(el, inlineBoxContainer, true) - inlineBoxX : chainOffset(el, cb, true);
  const coY = inlineCb ? chainOffset(el, inlineBoxContainer, false) - inlineBoxY : chainOffset(el, cb, false);
  // A vertical containing block measures its flow in its own axes (CSS Writing Modes 3 §7.1): the
  // box would go one block step across from the block-start edge — the right one in a right-to-left
  // frame — at the inline start down the page. The static positions are recorded in those axes, so
  // the two swap over. The initial containing block is the viewport, which takes the page's axes.
  const cbEl = cb !== null ? cb : document.documentElement as Node;
  const turnedCb = cb !== null
    ? !inlineCb && !gridArea && cb.vtext !== 0
    : isVerticalText(cbEl);
  const cbWm = usedWritingMode(cbEl);
  const cbRl = turnedCb && cbWm !== P.WM_VERTICAL_LR && cbWm !== P.WM_SIDEWAYS_LR;
  const blockPadStart = turnedCb ? (cbRl ? borderRight(cbEl) : borderLeft(cbEl)) : padX;
  // Where the box would go in the flow, from the containing block's padding box. An auto offset
  // takes that place, so an auto width has only the room from there to the block's end (CSS 2.1
  // 10.3.7), which a grid area can leave larger than the area itself.
  // The static position is a flow position, so it is read in the flow's axes: the box would have
  // gone one block step from the block-start edge, and the inline start down the page. The
  // specified offsets stay physical; only where the box would have gone swaps over.
  const staticBlock = el.staticY - blockPadStart;
  const staticRelX = el.staticX + coX - padX - aox;
  const staticRelY = turnedCb ? el.staticX - padY : el.staticY + coY - padY;
  const autoL = sizeUnit(el, P.P_MARGIN_LEFT) === P.U_AUTO;
  const autoR = sizeUnit(el, P.P_MARGIN_RIGHT) === P.U_AUTO;
  let ml = zeroIfNaN(len(el, P.P_MARGIN_LEFT, cbW));
  const mr = zeroIfNaN(len(el, P.P_MARGIN_RIGHT, cbW));
  const mt = zeroIfNaN(len(el, P.P_MARGIN_TOP, cbW));
  const mb = zeroIfNaN(len(el, P.P_MARGIN_BOTTOM, cbW));
  const left = len(el, P.P_LEFT, cbW);
  const right = len(el, P.P_RIGHT, cbW);
  // A percentage offset measures the containing block's padding box, however its height was
  // reached; an auto height is its used height by the time an out-of-flow box is placed.
  const top = len(el, P.P_TOP, cbH);
  const bottom = len(el, P.P_BOTTOM, cbH);
  const hasL = !Number.isNaN(left);
  const hasR = !Number.isNaN(right);
  const hasT = !Number.isNaN(top);
  const hasB = !Number.isNaN(bottom);
  // A stretch size is the inset-modified containing block's: a definite side keeps it, an `auto`
  // start side takes the box's static position, and an `auto` end side the padding edge — so the
  // box fills from where it would have gone to the block's end (CSS Sizing 4 §5, Position 3).
  const stretchW = sizeUnit(el, P.P_WIDTH) === P.U_STRETCH;
  const stretchH = sizeUnit(el, P.P_HEIGHT) === P.U_STRETCH;

  const replaced = isReplaced(el);
  // A box in a vertical containing block has its content laid out in that frame: its width is the
  // frame's block size and its height the frame's inline size, so layoutBox takes the height as its
  // first size and the width as the second (CSS Writing Modes 3 §7.1). The offsets it is placed by
  // stay physical, which is why the equations below run on the physical sizes as usual.
  // Only a box whose own writing mode runs down the page as well lays its content out in that
  // frame: a horizontal box inside a vertical one keeps the page's axes, so its width stays its
  // inline size and the height its block size (CSS Writing Modes 3 §7.1).
  el.inVtext = turnedCb && isVerticalText(el) ? 1 : 0;
  if (turnedCb) {
    // The inline size — the height — is the one asked for, or the one top and bottom pin, or the
    // longest line the content makes.
    let inline = specW(el, cbW);
    if (Number.isNaN(inline) && hasT && hasB && !replaced) inline = Math.max(0, cbH - top - bottom - mt - mb);
    if (Number.isNaN(inline)) inline = maxContentWidth(el, cbW, cbH);
    inline = clampW(el, inline, cbW);
    // The block size — the width — is the one asked for, or the one left and right pin; an auto one
    // is the stack of lines the content makes, which layoutBox measures.
    let block = specH(el, cbW, cbH);
    if (Number.isNaN(block) && hasL && hasR && !replaced) block = Math.max(0, cbW - left - right - ml - mr);
    if (!Number.isNaN(block)) block = clampH(el, block, cbW, cbH);
    layoutBox(el, cbW, cbH, inline, block, false);
    if (Number.isNaN(block)) el.h = clampH(el, el.h, cbW, cbH);
    el.fixedViewport = el.sv[P.P_POSITION] === P.POS_FIXED && cb === null;
    placeInFrame(el, cbW, cbH, cbRl, isRtl(cbEl), staticBlock, staticRelY, padX, padY, coX, coY, scrolledOf(el, cb));
    return;
  }
  // A box whose top and bottom say how tall it is has a definite height already, and its content's
  // percentage heights resolve against it while its width is being measured.
  let h = specH(el, cbW, cbH);
  if (stretchH) {
    const startY = hasT ? top : hasB ? 0 : staticRelY;
    h = clampH(el, Math.max(0, cbH - startY - (hasB ? bottom : 0) - mt - mb), cbW, cbH);
  }
  // An intrinsic height keyword is a definite size of its own: the offsets don't pin it to the
  // containing block, they only leave it room to be measured in (CSS Sizing 3, Position 3).
  const intrinsicH = isIntrinsicSize(el.su[P.P_HEIGHT]);
  const pinned = Number.isNaN(h) && hasT && hasB && !replaced && !intrinsicH
    ? Math.max(0, cbH - top - bottom - mt - mb) : NaN;
  const contentH = Number.isNaN(pinned) ? NaN : Math.max(0, pinned - padV(el, cbW));
  const basisH = Number.isNaN(h) ? contentH : Math.max(0, h - padV(el, cbW));

  // Width: a specified width wins; otherwise the offsets pin it, or it shrinks to fit. A replaced
  // box has its intrinsic size when auto, so its offsets can over-constrain the equation and the
  // overflowing end is simply ignored (as CSS does for replaced elements).
  let w = specW(el, cbW);
  if (stretchW) {
    const startX = hasL ? left : hasR ? 0 : staticRelX;
    w = clampW(el, Math.max(0, cbW - startX - (hasR ? right : 0) - ml - mr), cbW);
  }
  const specWidth = !Number.isNaN(w);
  // A table's available size can't exceed its containing block's (css-tables-3, abspos): an offset
  // that reaches outside the block doesn't give the table room to be wider than the block is.
  const table = display(el) === P.D_TABLE;
  if (!specWidth && !replaced) {
    // A table with `width: auto` is shrink-to-fit whatever its offsets say: two offsets
    // over-constrain the equation and the one at the inline end is ignored (CSS 2.1 §17.5.2,
    // §10.3.7), which is what browsers do with `position: absolute; left: 1px; right: 1px`.
    if (hasL && hasR && !table) {
      const pinned = Math.max(0, cbW - left - right - ml - mr);
      w = clampW(el, pinned, cbW);
    } else {
      const start = hasL ? left : hasR ? 0 : staticRelX;
      let avail = (cbW - start - (hasR ? right : 0) - ml - mr);
      if (table && avail > cbW) avail = cbW;
      w = clampW(el, Math.min(maxContentWidth(el, cbW, NaN, basisH), Math.max(0, avail)), cbW);
    }
  } else if (specWidth) {
    w = clampW(el, w, cbW);
  }

  // Height: the same, with the contents deciding an auto height. A box with a preferred aspect
  // ratio takes an auto width from a definite height and an auto height from the width it ends up
  // with; when both would be definite, the offsets give way and only one offset of the pair counts.
  const ratio = !replaced && aspectRatio(el) > 0;
  // A height the box measured for itself counts as definite for the offsets' margin equation.
  const specHeight = !Number.isNaN(h) || intrinsicH;
  if (ratio && !(specWidth && specHeight)) {
    if (specHeight) {
      // The height is specified: the width follows the ratio, and the offsets over-constrain it.
      // The width is still no less than the box's automatic minimum, its content's min-content
      // width, while min-width is `auto` and the box doesn't scroll.
      w = clampW(el, aspectW(el, h, cbW), cbW);
      if (el.su[P.P_MIN_WIDTH] === P.U_AUTO && !clipsX(el)) {
        w = clampW(el, Math.max(w, contentMinWidth(el, cbW, false)), cbW);
      }
    } else if (!specWidth && !Number.isNaN(boundedRatioH(el, cbW, cbH))) {
      // A max-height bounds the height, and the ratio transfers that bound to the width, which
      // the offsets then over-constrain.
      h = boundedRatioH(el, cbW, cbH) as number;
      w = clampW(el, aspectW(el, h, cbW), cbW);
      if (el.su[P.P_MIN_WIDTH] === P.U_AUTO && !clipsX(el)) {
        w = clampW(el, Math.max(w, contentMinWidth(el, cbW, false)), cbW);
      }
    } else if (!specWidth && !(hasL && hasR) && hasT && hasB) {
      // Only the offsets give a definite size, and it is the height: the width follows the ratio.
      h = pinned;
      w = clampW(el, aspectW(el, h, cbW), cbW);
    } else {
      // The width is definite (specified, or pinned by both offsets, or shrunk to fit): the
      // height follows the ratio.
      h = NaN;
    }
  } else if (Number.isNaN(h) && !Number.isNaN(pinned)) {
    h = pinned;
  }

  layoutBox(el, cbW, cbH, w, Number.isNaN(h) ? NaN : fitHeight(el, h, cbW, cbH), false);
  // A fixed box with no transformed ancestor is anchored to the viewport: the page's scrolling
  // moves everything else past it, so painting never adds an ancestor's scroll offset.
  el.fixedViewport = el.sv[P.P_POSITION] === P.POS_FIXED && cb === null;

  // Horizontal position within the containing block's padding box.
  let x: number;
  if (hasL && hasR && specWidth) {
    // Both offsets and the width are fixed: auto margins take the rest (margin: auto centers).
    const spare = cbW - left - right - el.w - (autoL ? 0 : ml) - (autoR ? 0 : mr);
    if (autoL && autoR) {
      ml = spare / 2;
      x = aox + left + ml;
    } else if (autoL) x = aox + left + spare;
    else x = aox + left + ml;
  } else if (hasL) x = aox + left + ml;
  else if (hasR) x = aox + cbW - right - el.w - mr;
  // static position: where the box would have gone, which the block axis measures from the
  // block-start edge — the right one in a right-to-left frame. A box in a grid area goes there
  // relative to the area's own origin, which the offsets above already carry.
  else if (turnedCb) x = cbRl ? cbW - staticBlock - el.w - mr : staticBlock + ml;
  else x = el.staticX + coX - padX + ml;

  // Vertical position. With both offsets and a specified height, auto margins take the spare, which
  // is how `inset: 0; margin: auto` centers a box in its containing block (CSS 2.1 10.6.4).
  const autoT = sizeUnit(el, P.P_MARGIN_TOP) === P.U_AUTO;
  const autoB = sizeUnit(el, P.P_MARGIN_BOTTOM) === P.U_AUTO;
  let y: number;
  if (hasT && hasB && specHeight) {
    const spare = cbH - top - bottom - el.h - (autoT ? 0 : mt) - (autoB ? 0 : mb);
    if (autoT && autoB) y = aoy + top + spare / 2;
    else if (autoT) y = aoy + top + spare;
    else y = aoy + top + mt;
  } else if (hasT) y = aoy + top + mt;
  else if (hasB) y = aoy + cbH - bottom - el.h - mb;
  else y = staticRelY + mt;

  // A fixed box is anchored to the viewport: its local position ignores the scrolling of its
  // ancestors, and painting leaves that scrolling out too (see fixedViewport). One rooted in a
  // transformed ancestor is placed in that ancestor's own space and scrolls with it.
  let scrolled = 0;
  let scrolledX = 0;
  if (el.sv[P.P_POSITION] === P.POS_FIXED && cb !== null) {
    for (let a = el.parentElement; a !== null && a !== cb; a = a.parentElement) {
      scrolled += a.scrollY;
      scrolledX += a.scrollX;
    }
  }
  el.x = padX + x - coX + scrolledX;
  el.y = padY + y - coY + scrolled;

  growOverflow(el, cb, mr, mb);
  placeNestedOutOfFlow(el);
}

/**
 * An out-of-flow box is part of the scrollable overflow of every ancestor: its margin box can
 * reach past an ancestor's content box, which grows that ancestor's scrollWidth and scrollHeight.
 * A fixed box anchored to the viewport doesn't scroll with the page, so it adds nothing.
 */
function growOverflow(el: Node, cb: Node | null, mr: number, mb: number): void {
  if (el.sv[P.P_POSITION] === P.POS_FIXED && cb === null) return;
  let ox = el.x;
  let oy = el.y;
  let a = el.parentElement;
  while (a !== null) {
    const right = ox + el.w + mr;
    const bottom = oy + el.h + mb;
    if (right > a.naturalW) a.naturalW = right;
    if (bottom > a.naturalH) a.naturalH = bottom;
    ox += a.x;
    oy += a.y;
    a = a.parentElement;
  }
}

/**
 * A transformed box draws past its layout box, and that reach is part of the scrollable overflow
 * of every ancestor (CSS Overflow 3): the corners it paints at grow its ancestors' natural size,
 * the same way an out-of-flow box's margin box does. Only the affine path is taken here; a box a
 * perspective projects keeps to its layout box for scrolling.
 *
 * The walk is bottom up and linear: each box hands its parent the reach its subtree paints in the
 * parent's own coordinates, with its own transform applied, and every box grows itself once from
 * what its children hand it. A clipping box hands on its own edge instead (what it hides cannot
 * paint outside it), a box anchored to the viewport hands on nothing, and an out-of-flow box hands
 * its reach to its containing block rather than to the boxes between.
 */
export function growTransformedOverflow(page: Node): void {
  takeBackTransformGrowth(page);
  // Reaches on their way to a containing block further up: the boxes between are not in the
  // out-of-flow box's chain, so they neither clip it nor grow by it.
  const pending = new Map<Node, number[]>();
  const route = (cb: Node | null, r: number[]): void => {
    const at = pending.get(cb === null ? page : cb);
    if (at === undefined) pending.set(cb === null ? page : cb, r.slice());
    else {
      // The entry holds the page maxima and the box, as the walk returns them: merge both.
      if (r[0] > at[0]) at[0] = r[0];
      if (r[1] > at[1]) at[1] = r[1];
      if (r[2] < at[2]) at[2] = r[2];
      if (r[3] < at[3]) at[3] = r[3];
      if (r[4] > at[4]) at[4] = r[4];
      if (r[5] > at[5]) at[5] = r[5];
    }
  };
  // Each box hands its parent two things: the right and bottom edges every box in its subtree
  // paints at, each through the transforms above it (exact: every box is transformed on its own),
  // and the bounding box of the subtree in the parent's coordinates, for the parent's own scroll
  // extents when the parent carries a transform of its own.
  const walk = (el: Node, m: Matrix | null, ex: number, ey: number): number[] => {
    let pageX = -Infinity;
    let pageY = -Infinity;
    const box = [Infinity, Infinity, -Infinity, -Infinity];
    for (const c of allChildren(el)) {
      if (display(c) === P.D_NONE) continue;
      const cx = ex + c.x;
      const cy = ey + c.y;
      const own = hasTransform(c) ? pageMatrix(c, cx, cy) : null;
      // The ancestors' transforms carry the box too: a translation inside a translated box
      // paints at the sum of the two, so the reach is the composed matrix, outermost last.
      const total = own === null ? m : m === null ? own : mul(own, m);
      const under = walk(c, total, cx, cy);
      if (under[0] === -Infinity && under[1] === -Infinity && under[4] === -Infinity) continue;
      // A fixed box anchored to the viewport scrolls with nothing: nothing it paints reaches a
      // box outside it. A transform, filter or container above it anchors it instead, and then
      // it moves with the page and does pass its reach on.
      if (isOutOfFlow(c) && c.sv[P.P_POSITION] === P.POS_FIXED && containingBlock(c) === null) continue;
      // An out-of-flow box belongs to its containing block's scroll extents, not to the boxes
      // between the two.
      const cb = isOutOfFlow(c) ? containingBlock(c) : el;
      if (cb !== el) {
        route(cb, under);
        continue;
      }
      if (under[0] > pageX) pageX = under[0];
      if (under[1] > pageY) pageY = under[1];
      unionInto(box, under);
    }
    const arrived = pending.get(el);
    if (arrived !== undefined) {
      pending.delete(el);
      if (arrived[0] > pageX) pageX = arrived[0];
      if (arrived[1] > pageY) pageY = arrived[1];
      unionInto(box, arrived);
    }
    // The box's own scroll extents take in what its subtree paints (CSS Overflow 3). A box with a
    // transform of its own measures the subtree in its own coordinates, so the transform it
    // carries is not part of its own scroll range.
    if (hasTransform(el) || m !== null) growReach(el, box[2], box[3], ex, ey);
    else growReach(el, pageX, pageY, ex, ey);
    // Content a clipping box hides cannot paint outside it: the boxes above see the box's edge.
    const clipX = clipsForOverflow(el, true);
    const clipY = clipsForOverflow(el, false);
    if (clipX) {
      box[0] = ex;
      box[2] = ex + el.w;
    } else {
      if (ex < box[0]) box[0] = ex;
      if (ex + el.w > box[2]) box[2] = ex + el.w;
    }
    if (clipY) {
      box[1] = ey;
      box[3] = ey + el.h;
    } else {
      if (ey < box[1]) box[1] = ey;
      if (ey + el.h > box[3]) box[3] = ey + el.h;
    }
    // The box itself is painted, and the boxes above it see it through the transforms above.
    let ownX = ex + el.w;
    let ownY = ey + el.h;
    if (m !== null) {
      const r = transformBox(m, ex, ey, ex + el.w, ey + el.h);
      ownX = r[2];
      ownY = r[3];
    }
    if (clipX) pageX = ownX;
    else if (ownX > pageX) pageX = ownX;
    if (clipY) pageY = ownY;
    else if (ownY > pageY) pageY = ownY;
    const own = hasTransform(el) ? pageMatrix(el, ex, ey) : null;
    const out = own === null ? box : transformBox(own, box[0], box[1], box[2], box[3]);
    return [pageX, pageY, out[0], out[1], out[2], out[3]];
  };
  walk(page, null, page.x, page.y);
}

/** Adds the box in `r`'s last four entries (or a child's `box`) to `into`. */
function unionInto(into: number[], r: number[]): void {
  if (r[2] < into[0]) into[0] = r[2];
  if (r[3] < into[1]) into[1] = r[3];
  if (r[4] > into[2]) into[2] = r[4];
  if (r[5] > into[3]) into[3] = r[5];
}

/** The bounding box a box from (x0, y0) to (x1, y1) paints at, through `m`. */
function transformBox(m: Matrix, x0: number, y0: number, x1: number, y1: number): number[] {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const [lx, ly] of [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]) {
    const tx = m.a * lx + m.c * ly + m.e;
    const ty = m.b * lx + m.d * ly + m.f;
    if (tx < minX) minX = tx;
    if (ty < minY) minY = ty;
    if (tx > maxX) maxX = tx;
    if (ty > maxY) maxY = ty;
  }
  return [minX, minY, maxX, maxY];
}

/**
 * Undoes what the last pass added to the scroll extents. A box whose layout was reused still
 * carries it, and a translation that shrank since must not leave the larger extent behind.
 */
function takeBackTransformGrowth(el: Node): void {
  if (el.tW !== 0) {
    el.naturalW -= el.tW;
    el.tW = 0;
  }
  if (el.tH !== 0) {
    el.naturalH -= el.tH;
    el.tH = 0;
  }
  for (const c of allChildren(el)) takeBackTransformGrowth(c);
}

/**
 * Whether a box clips what it holds on an axis, as the page's scroll extents see it. The body's
 * own overflow is the viewport's when the root's is visible (CSS Overflow 3): the body itself
 * then holds nothing back, and the page's scroll range is the one that grows.
 */
function clipsForOverflow(el: Node, x: boolean): boolean {
  // document.body is a getter that walks the root's children and compares tag and namespace
  // strings, and this runs twice for every box a page level walk visits. Only a box whose own
  // name says it is a body or a frameset can be that element, so the rest never ask.
  if (el.localName === "body" || el.localName === "frameset") {
    const root = document.documentElement;
    if (el === document.body && el.parentElement === root && (x ? !clipsX(root) : !clipsY(root))) return false;
  }
  return x ? clipsX(el) : clipsY(el);
}

/**
 * Grows a box by the reach its subtree paints, given as right and bottom edges in page
 * coordinates: `ox`/`oy` are the box's own position there. What it adds is remembered, so the
 * next pass can take it back before it measures again.
 */
function growReach(a: Node, maxX: number, maxY: number, ox: number, oy: number): void {
  // A box that a transform leaves entirely before an ancestor's start edge is in the
  // unreachable part of its overflow and grows nothing there (CSS Overflow 3).
  if (maxX - ox > 0.01 && maxX - ox > a.naturalW) {
    a.tW += maxX - ox - a.naturalW;
    a.naturalW = maxX - ox;
  }
  if (maxY - oy > 0.01) {
    // naturalH is the box's own block extent, border box and all, so the bottom border the
    // content reaches over is part of it.
    const bottom = maxY - oy + borderBottom(a);
    if (bottom > a.naturalH) {
      a.tH += bottom - a.naturalH;
      a.naturalH = bottom;
    }
  }
}

/** The scrolling of the ancestors above a fixed box, which its own position leaves out. */
function scrolledOf(el: Node, cb: Node | null): number[] {
  let scrolled = 0;
  let scrolledX = 0;
  if (el.sv[P.P_POSITION] === P.POS_FIXED && cb !== null) {
    for (let a = el.parentElement; a !== null && a !== cb; a = a.parentElement) {
      scrolled += a.scrollY;
      scrolledX += a.scrollX;
    }
  }
  return [scrolledX, scrolled];
}

/**
 * Places an out-of-flow box inside a vertical containing block: the block axis runs across the
 * page from the block-start edge and the inline axis down it, and the box's physical offsets and
 * margins decide where it goes on each, as they do in a horizontal containing block.
 */
function placeInFrame(el: Node, cbW: number, cbH: number, rl: boolean, rtlLine: boolean, staticBlock: number,
  staticInline: number, padX: number, padY: number, coX: number, coY: number, scrolled: number[]): void {
  const ml = zeroIfNaN(lenPhys(el, P.P_MARGIN_LEFT, cbW));
  const mr = zeroIfNaN(lenPhys(el, P.P_MARGIN_RIGHT, cbW));
  const mt = zeroIfNaN(lenPhys(el, P.P_MARGIN_TOP, cbW));
  const mb = zeroIfNaN(lenPhys(el, P.P_MARGIN_BOTTOM, cbW));
  const left = lenPhys(el, P.P_LEFT, cbW);
  const right = lenPhys(el, P.P_RIGHT, cbW);
  const top = lenPhys(el, P.P_TOP, cbH);
  const bottom = lenPhys(el, P.P_BOTTOM, cbH);
  const hasL = !Number.isNaN(left);
  const hasR = !Number.isNaN(right);
  const hasT = !Number.isNaN(top);
  const hasB = !Number.isNaN(bottom);
  const autoL = sizeUnit(el, P.P_MARGIN_LEFT) === P.U_AUTO;
  const autoR = sizeUnit(el, P.P_MARGIN_RIGHT) === P.U_AUTO;
  const autoT = sizeUnit(el, P.P_MARGIN_TOP) === P.U_AUTO;
  const autoB = sizeUnit(el, P.P_MARGIN_BOTTOM) === P.U_AUTO;
  // The block axis: the box's width and its left and right offsets. The offsets are physical, so
  // only the static position comes from the flow, which runs away from the block-start edge — the
  // right one in a right-to-left frame.
  let block: number;
  if (hasL && hasR && !Number.isNaN(specH(el, cbW, cbH))) {
    const spare = cbW - left - right - el.w - (autoL ? 0 : ml) - (autoR ? 0 : mr);
    block = autoL && autoR ? left + spare / 2 : autoL ? left + spare : left + ml;
  } else if (hasL) block = left + ml;
  else if (hasR) block = cbW - right - el.w - mr;
  else block = rl ? cbW - staticBlock - el.w - mr : staticBlock + ml;
  // The inline axis: its height and its top and bottom offsets. A right-to-left line runs from the
  // bottom up, so a box that follows the text sits above it, mirrored by its own inline extent.
  const mirrored = el.wasInline && rtlLine;
  const startInline = mirrored ? cbH - el.staticFlow - el.h - mb : staticInline + mt;
  let inline: number;
  if (hasT && hasB && !Number.isNaN(specW(el, cbW))) {
    const spare = cbH - top - bottom - el.h - (autoT ? 0 : mt) - (autoB ? 0 : mb);
    inline = autoT && autoB ? top + spare / 2 : autoT ? top + spare : top + mt;
  } else if (hasT) inline = top + mt;
  else if (hasB) inline = cbH - bottom - el.h - mb;
  else inline = startInline;
  el.x = padX + block - coX + scrolled[0];
  el.y = padY + inline - coY + scrolled[1];
  growOverflow(el, containingBlock(el), mr, mb);
  placeNestedOutOfFlow(el);
}

/** Positions the out-of-flow boxes inside a subtree that has already been laid out. */
export function placeNestedOutOfFlow(el: Node): void {
  for (const c of boxKids(el)) {
    if (display(c) === P.D_NONE) continue;
    if (isOutOfFlow(c)) placeOutOfFlow(c);
    else placeNestedOutOfFlow(c);
  }
}
