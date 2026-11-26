// Out-of-flow boxes: absolute and fixed positioning against their containing blocks.

import * as P from "../../shared/props.ts";
import { Node, document, boxKids } from "../dom.ts";
import { fitHeight, layoutBox } from "./box.ts";
import { aspectRatio, aspectW, borderBottom, borderLeft, borderRight, borderTop, boundedRatioH, clampH, clampW, clipsX, display, isIntrinsicSize, isOutOfFlow, isReplaced, len, lenPhys, padV, place, sizeUnit, specH, specW, viewport, zeroIfNaN, allChildren } from "./box-model.ts";
import { contentMinWidth, maxContentWidth } from "./text.ts";
import { isRtl, isVerticalText, lineHeightPx, usedWritingMode } from "../style.ts";
import { hasTransform, pageMatrix } from "../transform.ts";
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
 */
export function growTransformedOverflow(page: Node): void {
  const walk = (el: Node): void => {
    for (const c of allChildren(el)) {
      if (display(c) === P.D_NONE) continue;
      walk(c);
      if (!hasTransform(c)) continue;
      let px = 0;
      let py = 0;
      for (let a: Node | null = c; a !== null; a = a.parentElement) {
        px += a.x;
        py += a.y;
      }
      const m = pageMatrix(c, px, py);
      if (m === null) continue;
      let maxX = -Infinity;
      let maxY = -Infinity;
      for (const [lx, ly] of [[0, 0], [c.w, 0], [c.w, c.h], [0, c.h]]) {
        const x = px + lx;
        const y = py + ly;
        const tx = m.a * x + m.c * y + m.e;
        const ty = m.b * x + m.d * y + m.f;
        if (tx > maxX) maxX = tx;
        if (ty > maxY) maxY = ty;
      }
      for (let a = c.parentElement; a !== null; a = a.parentElement) {
        let ox = 0;
        let oy = 0;
        for (let b: Node | null = a; b !== null; b = b.parentElement) {
          ox += b.x;
          oy += b.y;
        }
        // A box that a transform leaves entirely before an ancestor's start edge is in the
        // unreachable part of its overflow and grows nothing there (CSS Overflow 3).
        if (maxX - ox <= 0.01 || maxY - oy <= 0.01) continue;
        if (maxX - ox > a.naturalW) a.naturalW = maxX - ox;
        // naturalH is the box's own block extent, border box and all, so the bottom border the
        // content reaches over is part of it.
        const bottom = maxY - oy + borderBottom(a);
        if (bottom > a.naturalH) a.naturalH = bottom;
      }
    }
  };
  walk(page);
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
