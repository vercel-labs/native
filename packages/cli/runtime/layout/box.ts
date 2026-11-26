// layoutBox: sizes one box and dispatches to block, inline or flex layout for its contents.

import * as P from "../../shared/props.ts";
import { Node, Element, HTMLInputElement, HTMLSelectElement, HTMLTextAreaElement, hasLineFragment, controlKind, CONTROL_CHECKBOX, CONTROL_RADIO, CONTROL_RANGE, boxKids } from "../dom.ts";
import { isFlexContainer, isGridContainer, isLanesContainer, isRowDirection, isRtl, isVerticalText, lineHeightPx, usedWritingMode } from "../style.ts";
import { layoutBlock } from "./block.ts";
import { aspectH, aspectRatio, aspectW, blockStartBorder, borderLeft, borderTop, boundedRatioH, clampH, clampW, clipsX, clipsY, containsBlock, display, hasNaturalSize, hasOwnText, inlineStartBorder, intrinsicBoxW, intrinsicSize, isBfcRoot, isScroller, isFloat, isIntrinsicSize, isOutOfFlow, isReplaced, len, marginH, marginV, padH, padV, place, propagatesBodyOverflow, relativeOffset, sizeUnit, specH, specW, viewport, zeroIfNaN } from "./box-model.ts";
import { isScrollContainer, layoutFlexColumn, layoutFlexRow } from "./flex.ts";
import { gridIntrinsicWidth, gridLanesShrinkWidth, gridShrinkWidth, layoutGrid, layoutGridLanes } from "./grid.ts";
import { isMulticol, layoutMulticol } from "./multicol.ts";
import { FloatCtx, Flow } from "./floats.ts";
import { elideOverflowText, hasInlineContent, layoutOwnText } from "./inline.ts";
import { clampScroll, clampScrollOf } from "./geometry.ts";
import { placeNestedOutOfFlow, placeOutOfFlow, growTransformedOverflow } from "./positioned.ts";
import { isQuirks } from "../quirk.ts";
import { contentMaxWidth, contentMinWidth, maxContentWidth, minContentWidth, wrapText, bumpSizeCache } from "./text.ts";
import { boxChanges, incremental, layoutEpoch, unsupportedLayout } from "../invalidation.ts";
import { clearLayoutDirty, endLayoutPass, laidOutNaturalH, laidOutNaturalW, printMisses, keepOlderLayout, recordLayout, relaidRoots, relayoutDirtyRoots, resetNaturalSize, resetNaturalSizes, reuseLayout, setRelayoutHook, settleLayouts, startLayoutPass, verifyLayout } from "./incremental.ts";
import { applyCollapsedBorders, isTableDisplay, isTableInternal, layoutTable, tableShrinkWidth, tableUsedWidth } from "./table.ts";
import { frameTimes } from "../frame-times.ts";

// ---------------------------------------------------------------------------
// Box layout

/**
 * The border-box block size an intrinsic keyword names: the content's height with the box laid out
 * at the inline size the same keyword names (CSS Sizing 3). A box that is already being measured
 * for its own height doesn't measure again; that height comes back as unknown.
 */
function intrinsicBlockH(el: Node, u: number, cbW: number, cbH: number): number {
  // A replaced box's block size at a definite inline size is that size through its ratio: the
  // image's own proportions decide it, not the size its content would take.
  if (isReplaced(el)) {
    const w = specW(el, cbW);
    if (!Number.isNaN(w) && aspectRatio(el) > 0) return aspectH(el, clampW(el, w, cbW), cbW);
  }
  if (el.measuringH) return NaN;
  el.measuringH = true;
  let out = measuredBlockH(el, u, cbW, cbH);
  if (u === P.U_FIT_CONTENT) {
    const max = measuredBlockH(el, P.U_MAX_CONTENT, cbW, cbH);
    const min = measuredBlockH(el, P.U_MIN_CONTENT, cbW, cbH);
    // The block axis has no space of its own to fit into unless the containing block gives it one.
    const avail = Number.isNaN(cbH) ? max : cbH - marginV(el, cbW);
    out = Math.min(max, Math.max(min, avail));
  }
  el.measuringH = false;
  return out;
}

/** Lays the box out at the inline size `u` names and returns the border-box height it takes. */
/** The number of rows a textarea's box is tall, from its rows attribute (2 by default). */
function rowsOf(el: Node): number {
  const raw = (el as Element).getAttribute("rows");
  if (raw === null) return 2;
  const n = parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : 2;
}

function measuredBlockH(el: Node, u: number, cbW: number, cbH: number): number {
  const w = intrinsicBoxW(el, u, cbW);
  // The box is laid out at the inline size the keyword names to measure its block size. The
  // layout that asked for the measurement had laid it out at the inline size it is taking, so the
  // box is put back that way before the measured height goes back to the caller: a text block
  // stretched to its line's width must not come out as wide as its longest word.
  const keep = el.w;
  layoutBox(el, cbW, cbH, Number.isNaN(w) ? NaN : w, NaN, false, true);
  const h = el.h;
  if (!Number.isNaN(keep) && keep !== el.w) layoutBox(el, cbW, cbH, keep, NaN, false, true);
  return h;
}

/**
 * A vertical box's width is its block size — what its content takes across the lines the inline
 * axis stacks. To measure it, the box is laid out once at the inline size it has and the width it
 * came to is read back; no text measurement alone gives it, since the lines run down the page. A
 * box with no inline size of its own, or one already being measured, has none to report.
 */
const measuringVw = new Set<Node>();

export function verticalContentWidth(el: Node, cbW: number, cbH: number, ownH: number): number {
  // Only a box in a horizontal flow turns its own content here: one already inside a turned frame
  // has its sizes in that frame's axes, which the frame's own layout reads.
  if (el.inVtext !== 0) return NaN;
  let spec = Number.isNaN(ownH) ? specH(el, cbW, cbH) : ownH;
  if (Number.isNaN(spec)) {
    // With no inline size of its own, measure against the content's own inline extent: the lines
    // stay unbroken, so the block size comes out as one line's worth (which is what an
    // absolutely positioned vertical box with `auto` sides shrinks its width to).
    spec = contentMaxWidth(el, cbW, cbH, ownH, true, true);
  }
  if (Number.isNaN(spec) || measuringVw.has(el)) return NaN;
  measuringVw.add(el);
  layoutBox(el, cbW, cbH, NaN, spec, false, true);
  const w = el.w;
  measuringVw.delete(el);
  return w;
}

/**
 * Clamps a border-box height, resolving min-height and max-height keywords too: each names the
 * block size the box takes at the inline size it names.
 */
export function fitHeight(el: Node, h: number, cbW: number, cbH: number): number {
  const adj = el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : padV(el, cbW);
  const uMax = el.su[P.P_MAX_HEIGHT];
  const uMin = el.su[P.P_MIN_HEIGHT];
  const max = isIntrinsicSize(uMax) ? intrinsicBlockH(el, uMax, cbW, cbH) : NaN;
  const min = isIntrinsicSize(uMin) ? intrinsicBlockH(el, uMin, cbW, cbH) : NaN;
  if (!Number.isNaN(max) && h > max + adj) h = max + adj;
  h = clampH(el, h, cbW, cbH);
  // An intrinsic minimum is applied after the clamp, so a minimum bigger than the maximum wins,
  // as it does for any other size (CSS Sizing 3 §5.2).
  if (!Number.isNaN(min) && h < min + adj) h = min + adj;
  return h;
}

/**
 * Whether content taller than the height a preferred aspect ratio gives the box makes the box
 * taller: the ratio's height is the box's automatic minimum, so it applies while min-height is
 * `auto`, in a box with visible overflow whose content lays out in it. A scrolling box, a flex
 * container and a box with a min-height of its own keep the ratio's height and let their content
 * overflow instead.
 */
function growsWithRatioContent(el: Node): boolean {
  if (isTableDisplay(display(el))) return false;
  if (el.su[P.P_MIN_HEIGHT] !== P.U_AUTO) return false;
  return !clipsY(el);
}

/**
 * The longest line the content of an orthogonal box makes along the axis its inline size runs:
 * its text and inline content give their own inline extent, a block-level child that runs the same
 * way gives its inline extent, and one that runs across gives its block size — it lies across the
 * line rather than along it.
 */
function inlineExtent(el: Node, cbW: number, cbH: number, min: boolean = false): number {
  const vertical = isVerticalText(el);
  // A vertical box's width is its block size; this asks for the extent along the inline axis, so
  // its content is measured along that axis instead of across it, and the padding and margins that
  // come off and add on are the ones on that axis too (the frame's `x` runs down the page there).
  // Content whose elements sit on one line — a text node and an inline span, say — is measured as
  // the line it makes, not as its widest child.
  const alongPad = vertical ? padV(el, cbW) : padH(el, cbW);
  let ext = hasOwnText(el) || hasInlineContent(el)
    ? (min ? minContentWidth(el, cbW, cbH, NaN, true, false, vertical)
      : contentMaxWidth(el, cbW, cbH, NaN, true, vertical)) - alongPad : 0;
  for (const c of boxKids(el)) {
    if (c.isTextNode || display(c) === P.D_NONE || isOutOfFlow(c) || isFloat(c)) continue;
    const size = isVerticalText(c) === vertical
      ? (min ? minContentWidth(c, cbW, cbH, NaN, true, false, vertical)
        : maxContentWidth(c, cbW, cbH, NaN, true, false, vertical))
      : intrinsicBlockH(c, P.U_MAX_CONTENT, cbW, cbH);
    if (!Number.isNaN(size)) ext = Math.max(ext, size + (vertical ? marginV(c, cbW) : marginH(c, cbW)));
  }
  return ext;
}

/**
 * Marks the content a vertical box holds as being in its frame, for a measurement that has to read
 * the boxes' sizes before layout sets the flags: an out-of-flow box is placed in page coordinates.
 */
function markFrame(el: Node): void {
  for (const c of boxKids(el)) {
    c.inVtext = isOutOfFlow(c) ? 0 : 1;
    if (c.inVtext !== 0) markFrame(c);
  }
}

/**
 * The space an orthogonal flow gets across its inline axis when its containing block has none of
 * its own: the nearest scroll container's, the page's at worst.
 */
function scrollSpace(el: Node, vertical: boolean): number {
  for (let a = el.parentElement; a !== null && a.parentElement !== null; a = a.parentElement) {
    if (isScroller(a) && !Number.isNaN(a.h) && a.h > 0) return vertical ? a.h : a.w;
  }
  return vertical ? viewport.h : viewport.w;
}

/** Whether the box has element children in its flow. */
function hasBlockKids(el: Node): boolean {
  for (const c of boxKids(el)) {
    if (c.isTextNode || display(c) === P.D_NONE || isOutOfFlow(c)) continue;
    return true;
  }
  return false;
}

/**
 * Whether the box lies inside a table cell. The percentage-height quirk doesn't reach into one:
 * a cell's children resolve their percentages as `auto` however tall the cell is (css-tables's
 * `percentages-grandchildren-quirks-mode`).
 */
function insideTableCell(el: Node): boolean {
  for (let a: Node | null = el; a !== null; a = a.parentElement) {
    const d = display(a);
    if (d === P.D_TABLE_CELL) return true;
    if (d === P.D_TABLE || d === P.D_INLINE_TABLE) return false;
  }
  return false;
}

/**
 * Whether a percentage height inside the box resolves against the box's own height. That is a
 * child whose height, min-height or max-height is a percentage, or a child with an auto height
 * that holds one: a box with a height of its own gives the percentages inside it that height
 * instead, and the quirks rule stops at a flex or grid container (see `quirkHeight`).
 */
function resolvesAgainstOwnHeight(el: Node): boolean {
  for (const c of boxKids(el)) {
    if (display(c) === P.D_NONE || isOutOfFlow(c)) continue;
    // A float takes its percentage height from the first ancestor with a height of its own (see
    // `quirkHeight`), not from the height its parent ends up with, so a box that holds one is
    // left to that rule.
    if (isFloat(c)) return false;
    if (c.su[P.P_HEIGHT] === P.U_PCT || c.su[P.P_MIN_HEIGHT] === P.U_PCT ||
      c.su[P.P_MAX_HEIGHT] === P.U_PCT) return true;
    if (isFlexContainer(c) || isGridContainer(c) || isLanesContainer(c)) continue;
    if (c.su[P.P_HEIGHT] !== P.U_AUTO) continue;
    if (resolvesAgainstOwnHeight(c)) return true;
  }
  return false;
}

/** Drops the collapsed-border overrides a box kept; an empty list (the usual case) stays. */
function clearCollapsedBorders(el: Node): void {
  if (el.bw.length > 0) el.bw = [];
  if (el.bc.length > 0) el.bc = [];
  if (el.bpad.length > 0) el.bpad = [];
  if (el.tborder.length > 0) el.tborder = [];
  if (el.tcols.length > 0) el.tcols = [];
}

/**
 * Lays out `el`. cbW/cbH are the containing block's content size (cbH may be NaN).
 * fixedW/fixedH force the border-box size (NaN = compute). `shrink` selects shrink-to-fit width,
 * and `autoHeight` sizes the box from its content however its own height is specified, which is
 * how a flex item's min-content height is measured. `flow` is the float context the box's content
 * lives in, when it continues the one around it; a box that establishes a block formatting
 * context gets its own.
 */
export function layoutBox(el: Node, cbW: number, cbH: number, fixedW: number, fixedH: number, shrink: boolean,
  autoHeight?: boolean, flow?: Flow): void {
  if (incremental.on) {
    // A box in a float context its parent shares depends on the floats in it, and adds its own:
    // its layout is only reused while there are none either way. The margin collapsed above it
    // is then the one part of the context it reads.
    const inFlow = flow !== undefined;
    const before = inFlow ? flow.ctx.boxes.length : 0;
    const mgP = inFlow ? flow.mgP : 0;
    const mgN = inFlow ? flow.mgN : 0;
    if (before === 0 && reuseLayout(el, cbW, cbH, fixedW, fixedH, shrink, autoHeight, inFlow, mgP, mgN)) return;
    keepOlderLayout(el);
    layoutBoxFull(el, cbW, cbH, fixedW, fixedH, shrink, autoHeight, flow);
    const floatFree = before === 0 && (!inFlow || flow.ctx.boxes.length === 0);
    recordLayout(el, cbW, cbH, fixedW, fixedH, shrink, autoHeight, inFlow, mgP, mgN, floatFree);
    return;
  }
  layoutBoxFull(el, cbW, cbH, fixedW, fixedH, shrink, autoHeight, flow);
}

function layoutBoxFull(el: Node, cbW: number, cbH: number, fixedW: number, fixedH: number, shrink: boolean,
  autoHeight?: boolean, flow?: Flow): void {
  // A table cell moves its content down for vertical-align by adding to its children's y
  // (table.ts shiftCellContent). An inline box or a display: contents element has no position
  // its own layout sets, so it starts from nothing here, or the shift would pile up on every layout.
  if (display(el) === P.D_TABLE_CELL) {
    for (const c of boxKids(el)) {
      const d = display(c);
      if (d === P.D_CONTENTS || (d === P.D_INLINE && !isReplaced(c))) c.y = 0;
    }
  }
  // Counted here, so a layout reused whole is not.
  frameTimes.laidOut++;
  el.escTopP = 0;
  // A box the user's resize drag sized takes that size, whatever its style asks for.
  if (el.resizeW >= 0) fixedW = el.resizeW;
  if (el.resizeH >= 0) fixedH = el.resizeH;
  // The frame this box's box model lives in is its containing block's: inside a box whose content
  // runs down the page, this box's width is the frame's block size and its height the frame's
  // inline size. An out-of-flow box is placed later, in page coordinates, so it isn't in one.
  const parent = el.parentElement;
  // An out-of-flow box is placed by the positioned pass, which knows its containing block and sets
  // the frame it belongs to itself.
  if (!isOutOfFlow(el)) el.inVtext = parent !== null && parent.vtext !== 0 ? 1 : 0;
  el.escTopN = 0;
  el.escBotP = 0;
  el.escBotN = 0;
  // Out-of-flow placement sets this again for a fixed box anchored to the viewport.
  el.fixedViewport = false;
  el.collapsesThrough = false;
  el.boxTop = 0;
  el.boxBottom = 0;
  if (el.fragBoxes.length > 0) el.fragBoxes = [];
  // Collapsed borders live on the table's grid lines: the table itself paints them (see
  // layout/table.ts), and its parts get the widths they occupy so they size their cells. Any
  // other box uses its computed borders, so a stale override is cleared.
  if (isTableDisplay(display(el))) {
    if (el.sv[P.P_BORDER_COLLAPSE] === P.BC_COLLAPSE) applyCollapsedBorders(el, cbW);
    else clearCollapsedBorders(el);
  } else if (!isTableInternal(display(el))) {
    clearCollapsedBorders(el);
  }
  if (isReplaced(el)) {
    layoutReplaced(el, cbW, cbH, fixedW, fixedH);
    // An out-of-flow box in a frame was sized in that frame, like any other box there.
    if (isOutOfFlow(el) && el.inVtext !== 0) {
      const m = el.sv[P.P_WRITING_MODE];
      unturnBox(el, m !== P.WM_VERTICAL_LR && m !== P.WM_SIDEWAYS_LR);
    }
    return;
  }
  // Width
  let w = fixedW;
  // Whether the width came from the box's own style rather than filling its containing block:
  // a vertical box's block size, unlike a horizontal block's, shrinks to its content when auto.
  let autoW = false;
  if (Number.isNaN(w)) {
    autoW = true;
    // A box with a preferred aspect ratio and a definite height takes its width from the ratio.
    // A min-height or max-height that bounds the height makes it definite for that purpose too.
    let hSpec = !Number.isNaN(fixedH) ? fixedH : specH(el, cbW, cbH);
    if (Number.isNaN(hSpec) && aspectRatio(el) > 0) hSpec = boundedRatioH(el, cbW, cbH);
    // The ratio transfers the height the box actually takes, so min/max-height clamp it first.
    else if (aspectRatio(el) > 0) hSpec = fitHeight(el, hSpec, cbW, cbH);
    // Percentage heights in the content resolve against the box's own height when it has one.
    const basisH = Number.isNaN(hSpec) ? cbH : hSpec;
    const ownH = Number.isNaN(hSpec) ? NaN : Math.max(0, hSpec - padV(el, cbW));
    const spec = specW(el, cbW, basisH, ownH);
    const avail = cbW - marginH(el, cbW);
    // A preferred aspect ratio decides the size on its axis even over an intrinsic sizing keyword:
    // a definite height transfers to `width: min-content`, `max-content` or `fit-content`.
    const ratioWins = isIntrinsicSize(sizeUnit(el, P.P_WIDTH)) && aspectRatio(el) > 0 && !Number.isNaN(hSpec);
    // A vertical box's block axis runs across the page, so an intrinsic keyword on its width names
    // the size the content takes there — a size the box has only once its content is laid out. The
    // keyword behaves as `auto` here, and the block-size shrink below gives the box that size.
    const intrinsicBlock = el.inVtext === 0 && isVerticalText(el) && isIntrinsicSize(sizeUnit(el, P.P_WIDTH));
    if (!Number.isNaN(spec) && !ratioWins && !intrinsicBlock) {
      w = isTableDisplay(display(el)) ? tableUsedWidth(el, cbW, spec) : spec;
      autoW = false;
    }
    else if (aspectRatio(el) > 0 && !Number.isNaN(hSpec)) {
      // The transferred width can't undercut the box's automatic minimum size, which is its
      // content's own min-content width. That minimum only applies while min-width is `auto` and
      // the box doesn't scroll: otherwise it keeps the ratio's width and lets content overflow.
      // A width the author names intrinsically already states the width the content asks for.
      w = aspectW(el, hSpec, cbW);
      if (!ratioWins && sizeUnit(el, P.P_MIN_WIDTH) === P.U_AUTO && !clipsX(el)) {
        w = Math.max(w, contentMinWidth(el, cbW, false, basisH, ownH));
      }
    }
    else if (isTableDisplay(display(el))) w = tableShrinkWidth(el, cbW, avail);
    // An inline-grid (and any other intrinsically sized grid) is as wide as its tracks' content.
    else if (shrink && isLanesContainer(el)) w = Math.min(avail, gridLanesShrinkWidth(el, cbW, basisH) + padH(el, cbW));
    else if (shrink && isGridContainer(el)) w = Math.min(avail, gridShrinkWidth(el, cbW, basisH, cbH) + padH(el, cbW));
    else if (shrink) {
      // Shrink-to-fit: the available width, but never narrower than the content's min-content
      // width nor wider than its max-content width (CSS 2.1 §10.3.5).
      w = Math.min(Math.max(minContentWidth(el, cbW, basisH, ownH), avail), maxContentWidth(el, cbW, basisH, ownH));
    }
    else w = avail;
    w = clampW(el, w, cbW);
  }
  // A table is never narrower than the width its grid needs: a max-width — or a specified width
  // that is too small — caps the box, and the columns keep their minimum (CSS 2.1 17.5.2.2).
  if (isTableDisplay(display(el))) w = Math.max(w, tableShrinkWidth(el, cbW, 0));

  // Height, if definite before laying out children. An intrinsic height is measured by laying the
  // box out, which sizes it too, so the width is set after that.
  let h = fixedH;
  // An `auto` ratio only gives the height a floor: the content can still make the box taller.
  let ratioFloorH = NaN;
  // Measuring the box's height from its content leaves out its own min/max-height, which the
  // caller applies where it matters; a preferred aspect ratio still decides the height.
  if (Number.isNaN(h) && autoHeight === true && aspectRatio(el) > 0) {
    const ratioH = aspectH(el, w, cbW);
    ratioFloorH = ratioH;
    if (el.sv[P.P_ASPECT_RATIO_AUTO] !== 1) h = ratioH;
  }
  if (Number.isNaN(h) && autoHeight !== true) {
    const u = sizeUnit(el, P.P_HEIGHT);
    // In the block axis an intrinsic sizing keyword behaves as `auto` when a preferred aspect
    // ratio decides the height from the width.
    if (isIntrinsicSize(u) && !(aspectRatio(el) > 0)) {
      const measured = intrinsicBlockH(el, u, cbW, cbH);
      if (Number.isNaN(measured)) h = NaN;
      else h = fitHeight(el, measured, cbW, cbH);
    } else {
      const spec = specH(el, cbW, cbH);
      if (!Number.isNaN(spec)) h = fitHeight(el, spec, cbW, cbH);
      // A preferred aspect ratio decides an auto height from the width, and the content's own
      // height doesn't take part. Its height is still a definite size for the content to resolve
      // percentages against, and an in-flow block box can grow past it.
      else if (aspectRatio(el) > 0) {
        const ratioH = fitHeight(el, aspectH(el, w, cbW), cbW, cbH);
        ratioFloorH = ratioH;
        if (el.sv[P.P_ASPECT_RATIO_AUTO] !== 1) h = ratioH;
      }
    }
  }
  el.w = w;
  // A height the box doesn't take from its content — it was stretched into a grid area or a flex
  // line, or has one of its own. A column flex container packs its main axis against that height
  // instead of shrinking to its items, which is what fills a stretched box with them.
  const definiteMain = !Number.isNaN(h) && Number.isNaN(ratioFloorH);

  const pl = zeroIfNaN(len(el, P.P_PADDING_LEFT, cbW)) + inlineStartBorder(el);
  const pt = zeroIfNaN(len(el, P.P_PADDING_TOP, cbW)) + blockStartBorder(el);
  const innerW = Math.max(0, w - padH(el, cbW));
  let innerH = Number.isNaN(h) ? NaN : Math.max(0, h - padV(el, cbW));
  // A table cell's height is its row's unless the cell sets one of its own. While the row is being
  // measured that height isn't definite, so a percentage height inside the cell resolves as auto
  // would (CSS 2.1 17.5.3); once the row's height is known the cell's content is laid out again
  // with it as the basis. A cell that sets a height of its own gives its content that height
  // instead, however tall the row ends up.
  if (display(el) === P.D_TABLE_CELL) {
    const own = el.su[P.P_HEIGHT] === P.U_AUTO ? NaN : specH(el, cbW, cbH);
    if (!Number.isNaN(own)) innerH = Math.max(0, own - padV(el, cbW));
    else if (Number.isNaN(fixedH)) innerH = NaN;
  }
  // The ratio's height is only the box's automatic minimum here, so a row flex container still
  // sizes its lines to their items and grows to them; a column needs it as its main size. Only
  // `aspect-ratio: auto <ratio>` makes that minimum, though: a plain ratio fixes the height, and
  // the items lay out inside it (a green strip of the ratio's height, not of the content's).
  if (isFlexContainer(el) && isRowDirection(el.sv[P.P_FLEX_DIRECTION]) &&
    el.sv[P.P_ASPECT_RATIO_AUTO] === 1 && !Number.isNaN(ratioFloorH) && growsWithRatioContent(el)) innerH = NaN;
  if (Number.isNaN(innerH) && isFlexContainer(el)) {
    // A positive min-height gives a flex container with auto height a main size for its own
    // layout (justify-content, percentage heights of items), though it doesn't shrink to less
    // than its content.
    const adj = el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? padV(el, cbW) : 0;
    const minH = len(el, P.P_MIN_HEIGHT, cbH);
    if (!Number.isNaN(minH) && minH > 0) innerH = Math.max(0, minH - adj);
    if (!isRowDirection(el.sv[P.P_FLEX_DIRECTION])) {
      // A max-height caps the space a column's items wrap and pack within; the container itself
      // still shrinks to its content afterwards.
      const maxH = len(el, P.P_MAX_HEIGHT, cbH);
      if (!Number.isNaN(maxH)) innerH = Math.max(0, maxH - adj);
    }
  }
  // The page's root is sized by the initial containing block, the viewport: a writing mode that
  // runs down the page takes the viewport's inline size for its height.
  if (el.parentElement === null && isVerticalText(el) && Number.isNaN(innerH)) {
    h = fitHeight(el, viewport.h, cbW, cbH);
    innerH = Math.max(0, h - padV(el, cbW));
  }
  // A box whose writing mode runs across its containing block's is an orthogonal flow: with no
  // inline size of its own it takes the longest line its content makes, wrapped at the space the
  // containing block leaves across its block axis. A vertical box in the page's frame gets its
  // height that way, a horizontal box in a turned frame its width, and either then lays its content
  // out turned like any other box in that frame.
  const orthogonal = el.parentElement !== null && isVerticalText(el) !== isVerticalText(el.parentElement);
  // The space the box's inline axis has: what its containing block leaves across its block axis,
  // or, when that is indefinite, the nearest scroll container's — the page's at worst (CSS Writing
  // Modes 3 §7.3).
  const space = !orthogonal ? Infinity : !Number.isNaN(cbH) ? Math.max(0, cbH - marginV(el, cbW))
    : scrollSpace(el, isVerticalText(el));
  if (orthogonal && Number.isNaN(innerH) && autoHeight !== true && !isReplaced(el) && !el.measuringV) {
    // The content lies in the frame whether or not the box turns, so the measurement reads it so.
    if (isVerticalText(el)) markFrame(el);
    else for (const c of boxKids(el)) c.inVtext = 0;
    el.measuringV = true;
    // A grid asks for its tracks, not for the longest line its items make: the items' own
    // contributions are what the tracks are sized from, so the set of them is the inline size
    // (CSS Grid 11.5).
    const gridMax = isLanesContainer(el) ? gridLanesShrinkWidth(el, cbW, cbH)
      : isGridContainer(el) ? gridShrinkWidth(el, cbW, cbH) : NaN;
    const gridMin = isLanesContainer(el) ? gridMax
      : isGridContainer(el) ? gridIntrinsicWidth(el, cbW, cbH, true) : NaN;
    const measured = (Number.isNaN(gridMax) ? inlineExtent(el, cbW, cbH) : gridMax) + padV(el, cbW);
    const floor = (Number.isNaN(gridMin) ? inlineExtent(el, cbW, cbH, true) : gridMin) + padV(el, cbW);
    el.measuringV = false;
    const inline = Math.max(floor, Math.min(measured, space));
    if (!Number.isNaN(inline)) {
      h = fitHeight(el, inline, cbW, cbH);
      innerH = Math.max(0, h - padV(el, cbW));
    }
  }
  el.contentX = pl;
  el.contentY = pt;
  el.contentW = innerW;

  // A vertical writing mode runs the line down the page: its inline axis is the box's height and
  // its block axis its width. The content branches below lay a line out across their `inlineAvail`
  // and stack lines along the block axis.
  //
  // Whether the content runs down the page (the frame's axes) or across it. A vertical box turns
  // whenever its inline size is definite — measured above when it had none — and a horizontal box
  // in a turned frame lays its content out across the page, swapping the frame's axes back.
  const frame = el.inVtext !== 0;
  const vtext = isVerticalText(el) && (frame || !Number.isNaN(innerH));
  const swap = vtext !== frame;
  const inlineAvail = swap ? innerH : innerW;
  const blockAvail = swap ? innerW : innerH;
  // A vertical box takes its block size from its content when nothing states one (the page's own
  // writing mode is the one exception: its boxes keep the page's size).
  const contentBlock = swap && autoW &&
    (el.parentElement !== null || el.sv[P.P_WRITING_MODE] !== usedWritingMode(el));
  // The content origin in the content's own axes. A vertical box's content starts at the page's
  // top edge, and its block axis at the right edge of a right-to-left frame (the left of a
  // left-to-right one); a horizontal box's content starts at that axis' end instead.
  const wm = usedWritingMode(el);
  const vlr = wm === P.WM_VERTICAL_LR || wm === P.WM_SIDEWAYS_LR;
  const blockBorder = Number.isNaN(h) ? 0 : h;
  const plL = swap ? (frame ? (vlr ? pt : blockBorder - pt - innerH) : pt) : pl;
  const ptL = swap ? (frame ? pl : (vlr ? pl : w - pl - innerW)) : pt;
  el.vtext = vtext ? 1 : 0;
  el.inlineAvail = inlineAvail;
  // The children are placed in this box's frame, and their own box models read the frame's axes
  // before they are laid out (their margins decide where they go), so they are told now.
  for (const c of boxKids(el)) c.inVtext = vtext && !isOutOfFlow(c) ? 1 : 0;

  let contentH = 0;
  let blockFlow = false;
  // Lays the content out once, with `basis` as the block size the percentage heights inside it
  // resolve against, and returns how tall the content came out. Quirks mode runs it a second time
  // once the box's own height is known (see below), so it leaves no line or fragment behind.
  const layContent = (basis: number): number => {
    let h = 0;
    blockFlow = false;
    // `content-visibility: hidden` skips the box's content: it is neither laid out nor painted.
    if (el.sv[P.P_CONTENT_VISIBILITY] === P.CV_HIDDEN) return 0;
    el.clearFragments();
    // Own text is wrapped again below; a box that no longer holds its own text (one whose
    // children replaced it) must not keep painting the old lines.
    if (el.lines.length > 0) el.lines = [];
    if (el.lineWidths.length > 0) el.lineWidths = [];
    if (el instanceof HTMLInputElement) {
      el.lines = [];
      // A drawn control takes its own height: the box a checkbox and a radio are, the strip a range
      // is. A text field is one line tall.
      const kind = controlKind(el.type);
      h = kind === CONTROL_CHECKBOX || kind === CONTROL_RADIO ? 13
        : kind === CONTROL_RANGE ? 16 : lineHeightPx(el);
    } else if (el instanceof HTMLTextAreaElement) {
      // The field's text wraps inside its box, and the rows attribute gives the box a height of its
      // own: the text scrolls once it is longer than that.
      wrapText(el, inlineAvail);
      // The rows attribute fixes the height; longer text scrolls rather than growing the box. The
      // field's scroll extent is its text's height, which scrollHeight reads from its lines.
      h = rowsOf(el) * lineHeightPx(el);
      blockFlow = true;
    } else if (el instanceof HTMLSelectElement) {
      // A menu is one line, the label of the option it shows; a list box lays its options out as
      // rows and is as tall as the rows it shows.
      if (el.isListBox) {
        const f = flow === undefined ? new Flow(new FloatCtx(), plL, ptL) : flow;
        layoutBlock(el, inlineAvail, basis, plL, ptL, f);
        h = el.listRows * lineHeightPx(el);
        blockFlow = true;
      } else {
        h = lineHeightPx(el);
      }
    } else if (isTableDisplay(display(el))) {
      h = layoutTable(el, inlineAvail, basis, plL, ptL);
      blockFlow = true;
    } else if (hasOwnText(el) || el.isTextNode) {
      if (flow !== undefined && flow.ctx.boxes.length > 0) {
        // Floats reach into the text, so it needs the line breaker that knows where they are.
        h = layoutOwnText(el, inlineAvail, plL, ptL, flow.ctx, flow.x, flow.y);
        blockFlow = true;
      } else {
        wrapText(el, inlineAvail);
        // A ::first-line that re-broke the line in its own font takes the height that font asks
        // for; the rest of the block keeps the element's line height.
        h = el.lines.length === 0 ? 0
          : el.firstLineStyle !== null
            ? lineHeightPx(el.firstLineStyle) + (el.lines.length - 1) * lineHeightPx(el)
            : el.lines.length * lineHeightPx(el);
      }
    } else if (isFlexContainer(el)) {
      h = isRowDirection(el.sv[P.P_FLEX_DIRECTION])
        ? layoutFlexRow(el, inlineAvail, basis, plL, ptL)
        : layoutFlexColumn(el, inlineAvail, basis, plL, ptL, definiteMain);
    } else if (isLanesContainer(el)) {
      h = layoutGridLanes(el, inlineAvail, basis, plL, ptL);
    } else if (isGridContainer(el)) {
      h = layoutGrid(el, inlineAvail, basis, plL, ptL);
    } else if (isMulticol(el)) {
      h = layoutMulticol(el, inlineAvail, basis, plL, ptL);
      blockFlow = true;
    } else {
      const f = flow === undefined ? new Flow(new FloatCtx(), plL, ptL) : flow;
      h = layoutBlock(el, inlineAvail, basis, plL, ptL, f);
      blockFlow = true;
    }
    return h;
  };
  // A vertical box whose block size comes from its content has none of its own while that content
  // is measured, so nothing inside resolves a percentage against one.
  contentH = layContent(contentBlock && vtext ? NaN : blockAvail);
  // Text that runs past the content edge of a box that clips it ends in an ellipsis when
  // `text-overflow` asks for one, just as the box's own text does (see wrapText).
  elideOverflowText(el, inlineAvail, plL);
  if (contentBlock) {
    // A vertical box's block size, unlike a horizontal block's width, shrinks to its content:
    // the stack of lines is as wide as the columns it holds.
    w = clampW(el, contentH + padH(el, cbW), cbW);
    el.w = w;
    el.contentW = Math.max(0, w - padH(el, cbW));
  }

  // A list item's outside marker hangs beyond the content edge it starts at, right-aligned
  // against that edge, and takes no room in the item's own content: left of the item in a
  // left-to-right line, right of it in a right-to-left one.
  const marker = el.markerPseudo;
  if (marker !== null && display(el) === P.D_LIST_ITEM && display(marker) !== P.D_NONE &&
    marker.sv[P.P_LIST_STYLE_POSITION] === P.LSP_OUTSIDE) {
    layoutBox(marker, inlineAvail, blockAvail, NaN, NaN, true);
    marker.x = isRtl(el) ? plL + el.contentW : plL - marker.w;
    marker.y = 0;
    place(marker);
  }

  if (Number.isNaN(h)) {
    // Size containment: the content doesn't decide the box's block size, which is its padding
    // alone; the content overflows instead, as it does in a browser.
    // A vertical table's content extent along its inline axis is its grid's width; the rows it
    // stacked are its block extent, which the width above already took.
    const inlineExtentNow = vtext && isTableDisplay(display(el)) ? el.tableInlineExtent : contentH;
    const auto = containsBlock(el) ? padV(el, cbW) : inlineExtentNow + padV(el, cbW);
    // A table's height can't shrink below the rows it holds, `max-height` included: a table is
    // as tall as its content even when it is capped.
    if (autoHeight === true) h = auto;
    else h = isTableDisplay(display(el)) ? Math.max(auto, fitHeight(el, auto, cbW, cbH)) : fitHeight(el, auto, cbW, cbH);
    if (!Number.isNaN(ratioFloorH) && h < ratioFloorH) h = ratioFloorH;
    // A max-height that caps a row flex container makes its height definite: lay its items out
    // again against the cap, so stretched items and the percentage heights inside them resolve
    // against it instead of the content height the cap cut off.
    if (h < auto && isFlexContainer(el) && isRowDirection(el.sv[P.P_FLEX_DIRECTION])) {
      contentH = layoutFlexRow(el, innerW, Math.max(0, h - padV(el, cbW)), pl, pt);
    }
    // A min-height or max-height that decides a grid's height makes it definite in the same way:
    // lay its tracks out again against it, so percentage gaps and align-content see it.
    if (h !== auto && isLanesContainer(el)) {
      contentH = layoutGridLanes(el, innerW, Math.max(0, h - padV(el, cbW)), pl, pt);
    }
    if (h !== auto && isGridContainer(el)) {
      contentH = layoutGrid(el, innerW, Math.max(0, h - padV(el, cbW)), pl, pt);
    }
    // In quirks mode a percentage height inside a box resolves against the height the box ends
    // up with, even when that height came from its content (see `quirkHeight`), so the content is
    // laid out once more now that the height is known. A flex or grid container gives a percentage
    // inside it the container's own height, not the height it happens to end up with, so this is
    // a plain block's rule.
    if (isQuirks() && Number.isNaN(blockAvail) && !containsBlock(el) && !isFlexContainer(el) &&
      !isGridContainer(el) && !isLanesContainer(el) && !insideTableCell(el) &&
      resolvesAgainstOwnHeight(el)) {
      const again = layContent(Math.max(0, h - padV(el, cbW)));
      if (again !== contentH) {
        contentH = again;
        const auto2 = contentH + padV(el, cbW);
        h = isTableDisplay(display(el)) ? Math.max(auto2, fitHeight(el, auto2, cbW, cbH)) : fitHeight(el, auto2, cbW, cbH);
        if (!Number.isNaN(ratioFloorH) && h < ratioFloorH) h = ratioFloorH;
      }
    }
  }
  // The ratio's height is the box's automatic minimum: content taller than it grows an in-flow
  // block box that doesn't scroll, while a box that scrolls or lays its content out itself keeps
  // the size the ratio gives it and lets the content overflow.
  else if (!Number.isNaN(ratioFloorH) && growsWithRatioContent(el)) {
    // A definite max-height still wins over that minimum.
    const grown = Math.max(h, contentH + padV(el, cbW));
    h = autoHeight === true ? grown : fitHeight(el, grown, cbW, cbH);
    // The grown height is the one the grid lays its tracks out in, so align-content and the
    // flexible rows see it: lay them out again against it.
    if (isLanesContainer(el)) contentH = layoutGridLanes(el, innerW, Math.max(0, h - padV(el, cbW)), pl, pt);
    else if (isGridContainer(el)) contentH = layoutGrid(el, innerW, Math.max(0, h - padV(el, cbW)), pl, pt);
  }
  // A table's height can't shrink below the rows it holds: `height` is a minimum there, so a
  // flexed main size smaller than the content still leaves the table as tall as its content. A
  // collapsed row's share of that height is taken out, as the row itself was (row-004).
  else if (isTableDisplay(display(el))) {
    const inlineExtentNow = vtext ? el.tableInlineExtent : contentH;
    h = Math.max(h - el.collapsedRowH, inlineExtentNow + padV(el, cbW));
  }
  el.h = h;
  el.contentH = Math.max(0, h - padV(el, cbW));
  // A box that ends up with no height of its own, no line boxes and only margins collapsing
  // through it is self-collapsing: its top and bottom margins are adjoining. A box that
  // establishes its own formatting context keeps its two margins apart, so it never collapses
  // through: the margin above it stops at its top edge and the margin below it starts there.
  el.collapsesThrough = el.collapsesThrough && blockFlow && el.h === 0 && el.lines.length === 0 &&
    !hasLineFragment(el) && !isBfcRoot(el);

  const rel = relativeOffset(el, cbW, cbH);
  el.relX = rel[0];
  el.relY = rel[1];

  // Natural height: how far the content reaches, plus padding. A scroll container's
  // scrollHeight comes from this.
  let extent = el.lines.length > 0 || el instanceof HTMLInputElement || blockFlow ? contentH : 0;
  // A float only reaches the height of the box that contains it, which is a block formatting
  // context root; anywhere else its bottom is past the content but not part of it.
  const containsFloats = isBfcRoot(el);
  // Natural width: how far the content reaches to the right, plus the padding. A box's
  // scrollWidth comes from this, and out-of-flow descendants add to it (see positioned.ts).
  // A frame root measures its content in the frame's axes: its own reach down the page is its
  // inline size, not the block size its width holds.
  const frameRoot = vtext && el.inVtext === 0;
  let extentW = frameRoot ? innerH + pt : innerW + pl;
  for (const c of boxKids(el)) {
    if (display(c) === P.D_NONE || isOutOfFlow(c)) continue;
    if (isFloat(c) && !containsFloats) continue;
    // A child that doesn't clip keeps its own overflow in view, so it reaches as far as its
    // content does; one that clips it (or the overflow that went to the viewport) ends at its box.
    const clips = (clipsX(c) || clipsY(c)) && !propagatesBodyOverflow(c);
    // Incremental layout reads the child's extent as its own layout left it, before positioned
    // boxes grew it (laidOutNaturalW), so it comes out the same however many passes ago that was.
    const cw = incremental.on ? laidOutNaturalW(c) : c.naturalW;
    const ch = incremental.on ? laidOutNaturalH(c) : c.naturalH;
    const reach = !clips && cw > c.w ? cw : c.w;
    const vertical = !clips && ch > c.h ? ch : c.h;
    extent = Math.max(extent, c.y - pt + vertical + zeroIfNaN(len(c, P.P_MARGIN_BOTTOM, innerW)));
    extentW = Math.max(extentW, c.x + reach + zeroIfNaN(len(c, P.P_MARGIN_RIGHT, innerW)));
  }
  // Inline content that runs past the content edge — a `nowrap` line, or a fragment placed wide of
  // it — is scrollable overflow too, as it is in a browser.
  for (let i = 0; i < el.lineWidths.length; i++) {
    extentW = Math.max(extentW, el.lineWidths[i] + (i === 0 ? el.textIndent : 0) + (frameRoot ? pt : pl));
  }
  for (let i = 0; i < el.fragKind.length; i++) {
    extentW = Math.max(extentW, el.fragX[i] + el.fragW[i]);
  }
  el.naturalH = Math.max(extent + padV(el, cbW), Number.isNaN(fixedH) && Number.isNaN(specH(el, cbW, cbH)) ? h : 0);
  // The box's own width is not overflow: padding swallows the room up to the padding edge, so the
  // scrollable reach stays the content box's right edge until something goes past it.
  el.naturalW = extentW;

  // A button centers its content vertically, as browsers do. Block flow starts the anonymous
  // content box at the content edge, so when the button is taller than what it holds, the content
  // moves down to the middle: the fragments and line baselines it made, and the boxes those lines
  // placed. This happens for every layout of the button, so a later one (after its text changed,
  // say) puts the content where the first one did.
  if (el.tagName === "BUTTON" && blockFlow && el.lines.length === 0) {
    const spare = el.contentH - contentH;
    if (spare > 0) shiftContent(el, spare / 2);
  }
  // A box that turned laid its content out in the frame's axes; now that it is all placed, put it
  // back on the page. Everything that reads a box's geometry from here on — painting, rects,
  // hit testing — then works in page coordinates, and a border or an outline is the plain one.
  if (vtext && (el.inVtext === 0 || isOutOfFlow(el))) {
    const rl = el.sv[P.P_WRITING_MODE] !== P.WM_VERTICAL_LR && el.sv[P.P_WRITING_MODE] !== P.WM_SIDEWAYS_LR;
    // A frame root's own box is already the page's; an out-of-flow box in a frame was sized in it.
    if (el.inVtext === 0) {
      unturn(el, rl);
      // The content's reach was measured in the frame's axes too, so what ran past the edge down
      // the page is the page's height and what ran past it across the page is its width.
      const nw = el.naturalW;
      el.naturalW = el.naturalH;
      el.naturalH = nw;
    } else unturnBox(el, rl);
  }
}

/**
 * Maps a turned box's content back onto the page. The frame's x ran down the page and its y across
 * it, so each box's inline and block sizes swap, and its position turns a quarter around its
 * parent's border box: a block coordinate is measured from the block-start border edge, which is
 * the page's right edge in a right-to-left frame.
 */
function unturn(el: Node, rl: boolean): void {
  unturnKids(el, el.w, rl);
}

function unturnKids(el: Node, block: number, rl: boolean): void {
  for (const c of boxKids(el)) {
    if (display(c) === P.D_NONE || c.isTextNode) continue;
    // A marker is a box of its own in the frame; an inline pseudo box paints through its line's
    // fragments, and the other pseudo boxes are style carriers whose coordinates mean nothing.
    if (c.pseudoKind !== P.PE_NONE && c.pseudoKind !== P.PE_MARKER && display(c) === P.D_INLINE) continue;
    // Its extent across the block axis is its block size, which is its width on the page.
    const extent = c.inVtext !== 0 ? c.h : c.w;
    const x = c.x;
    const y = c.y;
    // Only a box in the turned frame itself needs its own sizes and children converted; an
    // out-of-flow box is already in page coordinates.
    if (c.inVtext !== 0) unturnBox(c, rl);
    c.x = rl ? block - y - extent : y;
    c.y = x;
  }
}

/** Swaps one box's sizes back to the page's axes, and the boxes its content placed with them. */
function unturnBox(el: Node, rl: boolean): void {
  const inline = el.w;
  const block = el.h;
  const cx = el.contentX;
  const cy = el.contentY;
  const ci = el.contentW;
  const cb = el.contentH;
  el.w = block;
  el.h = inline;
  el.contentX = rl ? block - cy - cb : cy;
  el.contentY = cx;
  el.contentW = cb;
  el.contentH = ci;
  const nw = el.naturalW;
  el.naturalW = el.naturalH;
  el.naturalH = nw;
  // A table part draws its row bands in its own box's axes, which were the frame's.
  if (el.bgbox.length === 4) {
    const bx = el.bgbox[0];
    const by = el.bgbox[1];
    const bw = el.bgbox[2];
    const bh = el.bgbox[3];
    el.bgbox[0] = by;
    el.bgbox[1] = bx;
    el.bgbox[2] = bh;
    el.bgbox[3] = bw;
    for (let i = 0; i + 3 < el.bgseg.length; i += 4) {
      const sx = el.bgseg[i];
      const sy = el.bgseg[i + 1];
      const sw = el.bgseg[i + 2];
      const sh = el.bgseg[i + 3];
      el.bgseg[i] = sy;
      el.bgseg[i + 1] = sx;
      el.bgseg[i + 2] = sh;
      el.bgseg[i + 3] = sw;
    }
  }
  if (el.vtext !== 0) unturnKids(el, block, rl);
}

/**
 * Moves the content of `el` down by `dy`: the fragments and line baselines el holds, and the boxes
 * its content placed. A nested inline box isn't placed itself (its fragments are), so what it
 * holds moves instead.
 */
function shiftContent(el: Node, dy: number): void {
  for (let i = 0; i < el.fragTop.length; i++) el.fragTop[i] += dy;
  for (let i = 0; i < el.lineBaseline.length; i++) el.lineBaseline[i] += dy;
  for (let i = 0; i < el.lineCentral.length; i++) el.lineCentral[i] += dy;
  for (const c of boxKids(el)) shiftPlacedBox(c, dy);
}

function shiftPlacedBox(c: Node, dy: number): void {
  if (display(c) === P.D_INLINE && !isReplaced(c)) {
    for (const k of boxKids(c)) shiftPlacedBox(k, dy);
    return;
  }
  c.y += dy;
  if (c.staticValid) c.staticY += dy;
}

/**
 * Sizes a replaced box (<img>) from its intrinsic size and the used width/height. When one
 * dimension is auto it follows the intrinsic ratio; min/max constraints transfer through the
 * ratio too, as CSS does for replaced elements.
 */
function layoutReplaced(el: Node, cbW: number, cbH: number, fixedW: number, fixedH: number): void {
  el.clearFragments();
  el.lines = [];
  const size = intrinsicSize(el);
  // A box in a turned frame measures its inline size down the page, so the image's own size
  // arrives with its axes swapped as well.
  const iw = el.inVtext !== 0 ? size[1] : size[0];
  const ih = el.inVtext !== 0 ? size[0] : size[1];
  // The ratio the box sizes with: `aspect-ratio` overrides the image's own ratio, and an image
  // with none takes the one the property gives it.
  const ratio = aspectRatio(el);
  const padsW = padH(el, cbW);
  const padsV = padV(el, cbW);
  let bw = fixedW;
  // A percentage height resolves against a definite containing block height, and through the
  // box's ratio it decides what an intrinsic-keyword width names.
  if (Number.isNaN(bw)) bw = specW(el, cbW, cbH);
  let bh = fixedH;
  if (Number.isNaN(bh)) bh = specH(el, cbW, cbH);
  const knownW = !Number.isNaN(bw);
  const knownH = !Number.isNaN(bh);
  const hasRatio = ratio > 0;
  // An auto side follows the ratio, and the ratio's box is the one `aspect-ratio` says: the
  // content box for an image's own ratio and for `auto <ratio>`, the border box for a bare one.
  let w: number;
  let h: number;
  if (knownW && knownH) {
    w = bw;
    h = bh;
  } else if (knownW) {
    w = bw;
    h = hasRatio ? aspectH(el, bw, cbW) : ih + padsV;
  } else if (knownH) {
    h = bh;
    w = hasRatio ? aspectW(el, bh, cbW) : iw + padsW;
  } else {
    // An image with a ratio but no size of its own fills the inline space it is given, and the
    // ratio gives the block size; otherwise the natural inline size is where an auto size starts
    // and the ratio gives the block size (CSS Sizing 4 §5.2.2).
    w = !hasNaturalSize(el) && hasRatio ? Math.max(0, cbW - marginH(el, cbW)) : iw + padsW;
    h = hasRatio ? aspectH(el, w, cbW) : ih + padsV;
  }
  // min/max sizes transfer through the ratio: a width the clamp changed changes the height too.
  const wClamped = clampW(el, w, cbW);
  if (hasRatio && !knownH && wClamped !== w) h = aspectH(el, wClamped, cbW);
  const hClamped = fitHeight(el, h, cbW, cbH);
  if (hasRatio && !knownW && hClamped !== h) w = clampW(el, aspectW(el, hClamped, cbW), cbW);
  else w = wClamped;
  h = fitHeight(el, h, cbW, cbH);
  el.w = w;
  el.h = h;
  el.contentX = zeroIfNaN(len(el, P.P_PADDING_LEFT, cbW)) + inlineStartBorder(el);
  el.contentY = zeroIfNaN(len(el, P.P_PADDING_TOP, cbW)) + blockStartBorder(el);
  el.contentW = Math.max(0, w - padsW);
  el.contentH = Math.max(0, h - padsV);
  el.naturalH = h;
  el.naturalW = w;
  const rel = relativeOffset(el, cbW, cbH);
  el.relX = rel[0];
  el.relY = rel[1];
}

/** How many layout passes laid the whole page out, and how many only redid dirty boxes: a full
 *  pass since the last paint means the damage it would repaint is unknown. */
export const layoutPasses = { full: 0, local: 0 };

export function layoutRoot(root: Node): void {
  if (!incremental.on) {
    bumpSizeCache();
    layoutRootPass(root);
    growTransformedOverflow(root);
    layoutPasses.full++;
    return;
  }
  if (unsupportedLayout.nodes > 0) {
    // The page uses a layout incremental layout can't reuse around yet: lay it out in full, and
    // keep nothing from this pass for a later one.
    incremental.on = false;
    try {
      bumpSizeCache();
      layoutRootPass(root);
      growTransformedOverflow(root);
    } finally {
      incremental.on = true;
    }
    layoutEpoch.n++;
    boxChanges.kind.length = 0;
    boxChanges.placement.length = 0;
    boxChanges.stamp++;
    return;
  }
  // Handed over here rather than when the modules load, which a cycle between them orders.
  setRelayoutHook(relayout);
  // The viewport is the root's containing block, and viewport units and fixed boxes resolve
  // against it: whoever changed it (a window resize, a page mount, the host settling the
  // window's size), nothing laid out against the old one holds.
  viewport.w = Math.max(1, viewport.w);
  if (viewport.w !== laidOutViewW || viewport.h !== laidOutViewH) {
    laidOutViewW = viewport.w;
    laidOutViewH = viewport.h;
    layoutEpoch.n++;
  }
  startLayoutPass();
  // When every dirty box sits in a relayout root whose size came out the same, those roots are
  // all that needs laying out; the out-of-flow pass still places every positioned box, since a
  // row that only moved has nothing marked.
  if (relayoutDirtyRoots(root)) {
    layoutPasses.local++;
    placeAndClamp(root);
    growTransformedOverflow(root);
  } else {
    layoutPasses.full++;
    layoutRootPass(root);
    growTransformedOverflow(root);
    // The pass placed every positioned box; the sets still follow the boxes that changed.
    updateBoxSets(root);
    boxChanges.placement.length = 0;
    boxChanges.growthStale = false;
  }
  if (incremental.verify) {
    verifyLayout(root, () => {
      startLayoutPass();
      layoutRootPass(root);
    });
  }
  clearLayoutDirty(root);
  endLayoutPass();
  printMisses();
}

/** The viewport size the last incremental pass laid the page out in. */
let laidOutViewW = -1;
let laidOutViewH = -1;

/** How incremental.ts lays a box out again with the arguments one of its layouts kept. */
function relayout(el: Node, cbW: number, cbH: number, fixedW: number, fixedH: number, shrink: boolean,
  autoHeight: boolean | undefined, inFlow: boolean, mgP: number, mgN: number): void {
  // A layout made in its parent's float context had no floats there, so a context of its own
  // with the same collapsed margin above it stands in for that one.
  layoutBox(el, cbW, cbH, fixedW, fixedH, shrink, autoHeight, inFlow ? new Flow(new FloatCtx(), 0, 0, mgP, mgN) : undefined);
}

/**
 * The out-of-flow pass for an incremental layout: boxes that took an older layout's outputs are
 * laid out for real first (settleLayouts), and the scroll extents reused layouts carry go back to
 * what layout gave them before out-of-flow boxes grow them again. Placing a positioned box can
 * reuse an older layout too, which is settled and placed once more.
 */
function placeAfterReuse(root: Node): void {
  settleLayouts();
  for (let i = 0; i < 3; i++) {
    resetNaturalSizes(root);
    placeNestedOutOfFlow(root);
    if (!settleLayouts()) return;
  }
}

// The positioned boxes and scroll containers of the page, kept between passes: placing the one
// and clamping the other is all the page-wide work a pass that only laid out relayout roots has
// left. The sets are kept up to date from the boxes whose own style changed (boxChanges) rather
// than made again from a walk over every box; a box that left the tree, or isn't rendered, stays
// in them until a pass finds it there.
const oofSet = new Set<Node>();
const scrollerSet = new Set<Node>();
/** The epoch the sets were last made in from a whole walk. */
let setsEpoch = -1;

/** Brings the sets up to date: from a whole walk in a new epoch, else from the boxes that changed. */
function updateBoxSets(root: Node): void {
  if (setsEpoch !== layoutEpoch.n) {
    // The positioned boxes found by the walk may not be the ones there were: their extents are
    // made again too.
    if (oofSet.size > 0) boxChanges.growthStale = true;
    for (const el of oofSet) el.lInOof = false;
    for (const el of scrollerSet) el.lInScrollers = false;
    oofSet.clear();
    scrollerSet.clear();
    collectFrom(root);
    setsEpoch = layoutEpoch.n;
  } else {
    for (const el of boxChanges.kind) noteBoxKind(el);
  }
  boxChanges.kind.length = 0;
  boxChanges.stamp++;
}

function noteBoxKind(el: Node): void {
  const shown = display(el) !== P.D_NONE;
  setMember(el, shown && isOutOfFlow(el), shown && isScrollContainer(el));
}

function setMember(el: Node, oof: boolean, scroller: boolean): void {
  if (oof !== el.lInOof) {
    el.lInOof = oof;
    if (oof) oofSet.add(el);
    else {
      oofSet.delete(el);
      boxChanges.growthStale = true;
    }
  }
  if (scroller !== el.lInScrollers) {
    el.lInScrollers = scroller;
    if (scroller) scrollerSet.add(el);
    else scrollerSet.delete(el);
  }
}

function collectFrom(el: Node): void {
  for (const c of boxKids(el)) {
    if (display(c) === P.D_NONE) continue;
    setMember(c, isOutOfFlow(c), isScrollContainer(c));
    collectFrom(c);
  }
}

/**
 * Calls `fn` for each scroll container incremental layout knows of, when its set is up to date,
 * and returns whether it was: the snap pass then visits those rather than every box.
 */
export function forEachScroller(root: Node, fn: (el: Node) => void): boolean {
  if (!incremental.on || setsEpoch !== layoutEpoch.n || boxChanges.kind.length > 0) return false;
  for (const el of scrollerSet) if (rendered(el, root)) fn(el);
  return true;
}

/** Whether layout reaches a box: it is in the page, and neither it nor an ancestor isn't rendered. */
function rendered(el: Node, root: Node): boolean {
  for (let n: Node | null = el; n !== null; n = n.parentElement) {
    if (display(n) === P.D_NONE) return false;
    if (n === root) return true;
  }
  return false;
}

/** Whether a positioned box sits inside another one, which places it when it is placed. */
function insideOof(el: Node, root: Node): boolean {
  for (let n = el.parentElement; n !== null && n !== root; n = n.parentElement) {
    if (n.lInOof) return true;
  }
  return false;
}

/**
 * Places the positioned boxes and clamps scroll offsets after a pass of relayout roots only. The
 * positioned boxes are placed again (and the scroll extents they grow made again) only when one
 * of them sits inside a box laid out this pass or its insets moved; otherwise every one keeps the
 * place, and the extents, the last pass gave it. Either way the cost follows the positioned boxes
 * and scroll containers there are, not the size of the page.
 */
function placeAndClamp(root: Node): void {
  settleLayouts();
  updateBoxSets(root);
  rootStamp++;
  for (const r of relaidRoots) r.lStamp = rootStamp;
  // A positioned box that left the page or stopped being rendered still has its growth in the
  // boxes it was in.
  const gone: Node[] = [];
  for (const el of oofSet) if (!rendered(el, root)) gone.push(el);
  for (const el of gone) {
    oofSet.delete(el);
    el.lInOof = false;
    boxChanges.growthStale = true;
  }
  if (boxChanges.growthStale) {
    boxChanges.growthStale = false;
    boxChanges.placement.length = 0;
    resetNaturalSizes(root);
    regrowAll(root);
    clampScrollOf(root);
    for (const el of scrollerSet) if (rendered(el, root)) clampScrollOf(el);
    return;
  }
  let place = false;
  for (const el of boxChanges.placement) {
    if (el.lInOof && rendered(el, root)) place = true;
  }
  boxChanges.placement.length = 0;
  if (!place && relaidRoots.length > 0) {
    for (const el of oofSet) {
      if (insideStamped(el) && rendered(el, root)) {
        place = true;
        break;
      }
    }
  }
  if (place || settleLayouts()) regrowAll(root);
  clampScrollOf(root);
  for (const el of scrollerSet) if (rendered(el, root)) clampScrollOf(el);
}

/** Marks the boxes laid out alone this pass, for insideStamped. */
let rootStamp = 0;

/** Whether a box is one laid out alone this pass, or inside one. */
function insideStamped(el: Node): boolean {
  for (let n: Node | null = el; n !== null; n = n.parentElement) {
    if (n.lStamp === rootStamp) return true;
  }
  return false;
}

/** Makes every scroll extent positioned boxes grow again, from every positioned box. */
function regrowAll(root: Node): void {
  const top: Node[] = [];
  for (const el of oofSet) {
    if (!rendered(el, root)) continue;
    for (let a = el.parentElement; a !== null; a = a.parentElement) resetNaturalSize(a);
    if (!insideOof(el, root)) top.push(el);
  }
  for (let i = 0; i < 3; i++) {
    for (const el of top) placeOutOfFlow(el);
    if (!settleLayouts()) break;
  }
}

function layoutRootPass(root: Node): void {
  viewport.w = Math.max(1, viewport.w);
  const pos = root.sv[P.P_POSITION];
  if (pos === P.POS_ABSOLUTE || pos === P.POS_FIXED) {
    // An out-of-flow root takes the initial containing block — the viewport — as its own, so its
    // insets resolve against the viewport and a pair of them decides each size, as they would for
    // any absolutely positioned box (CSS Position 3 §6). An auto side is where the box would have
    // gone: its margin against the viewport's edge.
    const ml = zeroIfNaN(len(root, P.P_MARGIN_LEFT, viewport.w));
    const mr = zeroIfNaN(len(root, P.P_MARGIN_RIGHT, viewport.w));
    const mt = zeroIfNaN(len(root, P.P_MARGIN_TOP, viewport.w));
    const mb = zeroIfNaN(len(root, P.P_MARGIN_BOTTOM, viewport.w));
    const left = len(root, P.P_LEFT, viewport.w);
    const right = len(root, P.P_RIGHT, viewport.w);
    const top = len(root, P.P_TOP, viewport.h);
    const bottom = len(root, P.P_BOTTOM, viewport.h);
    const pinnedW = !Number.isNaN(left) && !Number.isNaN(right)
      ? clampW(root, Math.max(0, viewport.w - left - right - ml - mr), viewport.w) : NaN;
    const pinnedH = !Number.isNaN(top) && !Number.isNaN(bottom)
      ? fitHeight(root, Math.max(0, viewport.h - top - bottom - mt - mb), viewport.w, viewport.h) : NaN;
    layoutBox(root, viewport.w, viewport.h, pinnedW, pinnedH, false);
    root.x = !Number.isNaN(left) ? left + ml
      : !Number.isNaN(right) ? viewport.w - right - root.w - mr : ml;
    root.y = !Number.isNaN(top) ? top + mt
      : !Number.isNaN(bottom) ? viewport.h - bottom - root.h - mb : mt;
    root.fixedViewport = pos === P.POS_FIXED;
  } else {
    // The root element fills the viewport width; its height grows with content but is at least the viewport.
    layoutBox(root, viewport.w, viewport.h, NaN, NaN, false);
    if (root.h < viewport.h && root.su[P.P_HEIGHT] === P.U_AUTO) root.h = viewport.h;
    // A root with a width of its own still lets an auto margin take the space left in the
    // viewport, as a block's auto margins do in their containing block (CSS 2.1 10.3.3).
    const autoL = sizeUnit(root, P.P_MARGIN_LEFT) === P.U_AUTO;
    const autoR = sizeUnit(root, P.P_MARGIN_RIGHT) === P.U_AUTO;
    let ml = autoL ? 0 : zeroIfNaN(len(root, P.P_MARGIN_LEFT, viewport.w));
    const mr = autoR ? 0 : zeroIfNaN(len(root, P.P_MARGIN_RIGHT, viewport.w));
    // A box wider than the viewport leaves no free space, and an auto margin then comes to
    // zero rather than going negative (CSS 2.1 10.3.3).
    const free = viewport.w - root.w - ml - mr;
    if (free > 0) {
      if (autoL && autoR) ml += free / 2;
      else if (autoL) ml += free;
    }
    root.x = ml;
    root.y = zeroIfNaN(len(root, P.P_MARGIN_TOP, viewport.w));
  }
  // Out-of-flow boxes are placed once everything else has its final geometry. They grow their
  // ancestors' scroll extents, which a reused layout still holds from the last time.
  if (incremental.on) placeAfterReuse(root);
  else placeNestedOutOfFlow(root);
  clampScroll(root);
}
