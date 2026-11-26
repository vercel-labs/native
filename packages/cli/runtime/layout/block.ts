// Block flow with margin collapsing.

import * as P from "../../shared/props.ts";
import { Element, Node, boxKids, hasLineFragment } from "../dom.ts";
import { layoutBox } from "./box.ts";
import { allChildren, aspectRatio, blockEndBorder, blockStartBorder, borderBottom, borderLeft, borderRight, borderTop, clampW, display, inlineStartBorder, isBfcRoot, isButtonBox, isFloat, isOutOfFlow, isReplaced, len, marginH, padH, padV, place, sizeUnit, specW, zeroIfNaN } from "./box-model.ts";
import { clearBottom, FloatBox, FloatCtx, floatBottom, floatFitY, floatSides, Flow, floatSlot, lineFitY } from "./floats.ts";
import { breakLines, floatLineTop, isBlankPieces, isCollapsibleRun, layoutInlinePieces, measurePieces, piecesClearFloat, placeAbsOfBlankRun, Piece, splitFlow } from "./inline.ts";
import { anonymousTableWidth, isTableDisplay, isTableInternal, layoutAnonymousTable, tableShrinkWidth, tableUsedWidth } from "./table.ts";
import { maxContentWidth, minContentWidth } from "./text.ts";
import { floatShapePolygon } from "../clip.ts";

/** Whether a block-level box takes its width from its content rather than its containing block.
 * A button's box does: the HTML button layout rules lay it out as an inline-block does, whatever
 * its display value is. */
function shrinksToFit(el: Node): boolean {
  return isButtonBox(el) && sizeUnit(el, P.P_WIDTH) === P.U_AUTO;
}

/** Horizontal offset of a block-level child: its left margin, solving auto margins. */
function blockOffset(c: Node, innerW: number): number {
  return blockOffsetIn(c, innerW, innerW);
}

/** The same, when the space the box has is narrower than the containing block (floats). */
function blockOffsetIn(c: Node, avail: number, cbW: number): number {
  let ml = zeroIfNaN(len(c, P.P_MARGIN_LEFT, cbW));
  const autoL = sizeUnit(c, P.P_MARGIN_LEFT) === P.U_AUTO;
  const autoR = sizeUnit(c, P.P_MARGIN_RIGHT) === P.U_AUTO;
  const spare = avail - c.w - marginH(c, cbW);
  if (autoL && autoR) ml += spare / 2;
  else if (autoL) ml += spare;
  return ml;
}

/** The rendered legend of a fieldset: its first legend child, unless that one is hidden. The
 *  others are ordinary blocks, as are a legend anywhere but a fieldset (HTML rendering). */
function fieldsetLegend(el: Node): Node | null {
  if (el.localName !== "fieldset") return null;
  for (const c of allChildren(el)) {
    if (c.localName !== "legend") continue;
    return display(c) === P.D_NONE ? null : c;
  }
  return null;
}

/**
 * Lays out block-level children, collapsing vertical margins as CSS does. Adjacent margins
 * collapse into the largest positive one plus the most negative one. The first child's top
 * margin escapes through this box's top edge (and the last child's bottom margin through its
 * bottom edge) when no border, padding or definite height separates them, so it collapses with
 * the margin above (below) the box itself. A box with no height of its own collapses through
 * its own margins, leaving the margins around it to collapse together.
 */
/** The lines a box's flow has laid out, its block descendants' included. */
function flowLines(el: Node): number {
  let n = Math.max(el.lineBaseline.length, el.lines.length);
  for (const k of boxKids(el)) {
    if (display(k) === P.D_NONE || isOutOfFlow(k) || isFloat(k)) continue;
    if (isBfcRoot(k)) continue;
    n += flowLines(k);
  }
  return n;
}

/** Whether a box holds a forced line break, which splits its text into runs of their own. */
function hasBreak(el: Node): boolean {
  for (const k of boxKids(el)) {
    if (!k.isTextNode && (k as Element).localName === "br") return true;
    if (hasBreak(k)) return true;
  }
  return false;
}

/** Drops a clamp budget left on a box and the layouts it made stale. */
function clearClamp(n: Node): void {
  if (n.clampBudget < 0 && !n.clampEllipsis) return;
  n.clampBudget = -1;
  n.clampEllipsis = false;
  n.lN = 0;
  for (const k of boxKids(n)) clearClamp(k);
}

export function layoutBlock(el: Node, innerW: number, innerH: number, pl: number, pt: number, flow?: Flow): number {
  // A fieldset's rendered legend sits in its top border, out of the flow its content runs in:
  // what it adds beyond that border pushes the content down.
  const legend = fieldsetLegend(el);
  let legendShift = 0;
  if (legend !== null) {
    layoutBox(legend, innerW, NaN, innerW, NaN, false);
    legend.x = pl;
    legend.y = 0;
    place(legend);
    legendShift = Math.max(0, legend.h - blockStartBorder(el));
  }
  let y = legendShift;
  const f = flow === undefined ? new Flow(new FloatCtx(), pl, pt) : flow;
  const ctx = f.ctx;
  // Where this box's border box sits in the float context, for the boxes placed inside it.
  const bx = f.x - pl;
  const by = f.y - pt;
  const openTop = !isBfcRoot(el) && blockStartBorder(el) === 0 &&
    zeroIfNaN(len(el, P.P_PADDING_TOP, innerW)) === 0;
  // A preferred aspect ratio gives an auto height a definite size from the width, so it closes the
  // bottom edge as a specified height does: the last child's margin stays inside the box.
  const openBottom = !isBfcRoot(el) && !(aspectRatio(el) > 0) && blockEndBorder(el) === 0 &&
    zeroIfNaN(len(el, P.P_PADDING_BOTTOM, innerW)) === 0 &&
    Number.isNaN(len(el, P.P_HEIGHT, innerH)) && Number.isNaN(len(el, P.P_MAX_HEIGHT, innerH)) &&
    zeroIfNaN(len(el, P.P_MIN_HEIGHT, innerH)) === 0;
  // The margin waiting to be placed, as the largest positive and most negative part.
  let pendP = 0;
  let pendN = 0;
  // True while nothing has been laid out yet, so the pending margin is at the top edge and can
  // escape upward.
  let leading = openTop;
  let allThrough = true;
  // True once a cleared box has taken the pending margin into this box with it: the margin at
  // the bottom edge is real then, and does not collapse with this box's bottom margin.
  let fixedPend = false;
  const addEscape = (top: boolean, p: number, n: number) => {
    if (top) {
      if (p > el.escTopP) el.escTopP = p;
      if (n < el.escTopN) el.escTopN = n;
    } else {
      if (p > el.escBotP) el.escBotP = p;
      if (n < el.escBotN) el.escBotN = n;
    }
  };
  // Consecutive inline-level children form one inline formatting context (an anonymous block
  // box, in CSS terms) between block-level siblings. A block box inside an inline one is hoisted
  // to a segment of its own, so it takes part in this block flow like any other child.
  // A list item's outside marker is not part of its content flow: it hangs in the margin
  // beside the content box and layoutBox places it there. An inside marker flows as inline
  // content, first in the item.
  const entries = splitFlow(allChildren(el).filter((c) => c !== legend && (c.pseudoKind !== P.PE_MARKER ||
    c.sv[P.P_LIST_STYLE_POSITION] !== P.LSP_OUTSIDE)), innerW, innerH);
  // Inline-level content between block-level siblings, floats included, forms one anonymous
  // block box. The floats in it are out of flow, so they don't start a new inline formatting
  // context: the runs on either side of one share its lines, laid out together. They go as high
  // as the box itself, before any of its lines are laid out, so the lines above them are
  // shortened too (CSS 2.1 9.5.1, rules 5 to 8).
  const preplaced: number[] = [];
  for (let i = 0; i < entries.length; i++) preplaced.push(0);
  // line-clamp counts the lines of the whole box, its block children's included (CSS Overflow 4):
  // a child lays out only the lines left of the budget, and the ones past it make nothing.
  const clampBase = el.sv[P.P_LINE_CLAMP] > 0 ? el.sv[P.P_LINE_CLAMP] : el.clampBudget;
  let clampBlocks = 0;
  let clampPending: Node | null = null;
  // The children that take part in the flow, counted once: a clamp only needs to know whether one
  // child holds the whole flow.
  const flowKids = entries.filter((e) => e.block !== null && !isFloat(e.block)).length;
  // The budget this box came in with: the runs below lend it the block children's spend, and it
  // is put back once the flow is placed.
  const clampIncoming = el.clampBudget;
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i];
    if (entry.abs !== null) {
      // Out of flow: the box takes no room here. Remember where it would have gone, for the
      // auto offsets to fall back on. A pending margin above it is real space in the flow, so
      // the box would have gone below it; a margin at the top edge escapes the box instead.
      const a = entry.abs;
      a.staticX = pl;
      a.staticY = pt + y + (leading ? 0 : pendP + pendN);
      a.staticValid = true;
      continue;
    }
    const isRun = entry.block === null;
    if (isRun || (entry.block !== null && isFloat(entry.block))) {
      // The block child just placed has spent its lines of the budget, and the run that follows
      // it is laid out with what is left: the child's lines are only counted once the flow
      // reaches the next block child, which is too late for this run.
      if (clampPending !== null) {
        clampBlocks += flowLines(clampPending);
        clampPending = null;
      }
      // The container's own runs share its budget with the block children: what those took is
      // spent before a run's lines are counted.
      if (clampBase >= 0) el.clampBudget = Math.max(0, clampBase - clampBlocks);
      // The whole anonymous box, from its first piece of inline content to the last, including
      // the floats in it.
      const before = el.fragKind.length;
      const top = y + pendP + pendN;
      let pieces: Piece[] = [];
      // Where the inline content laid out so far ends.
      let next = top;
      const flush = () => {
        if (pieces.length === 0) return;
        next += layoutInlinePieces(el, pieces, innerW, pl, pt + next, innerH, ctx, f.x, f.y + next);
        pieces = [];
      };
      let j = i;
      for (; j < entries.length; j++) {
        const e = entries[j];
        if (e.abs !== null) {
          e.abs.staticX = pl;
          e.abs.staticY = pt + y + (leading ? 0 : pendP + pendN);
          e.abs.staticValid = true;
          continue;
        }
        if (e.block === null) {
          // A run of nothing but collapsible white space makes no line box; the boxes out of
          // flow in it still need their static position.
          if (isCollapsibleRun(e.pieces)) {
            placeAbsOfBlankRun(e.pieces, pl, pt + y + (leading ? 0 : pendP + pendN));
            continue;
          }
          for (const p of e.pieces) pieces.push(p);
          continue;
        }
        if (!isFloat(e.block)) break;
        // A float that was inline-level in the source belongs to the inline content around it:
        // it goes at the top of the line it is on, shortening that line (CSS 2.1 9.5). Which
        // line that is depends on how the content before it broke, so the content laid out so
        // far is measured once to find where its last line starts. A block-level one comes
        // after the content before it in the flow, so it goes below the line boxes that content
        // made unless the last of them still leaves room beside it for its own content
        // (CSS 2.1 9.5.1, rules 5 and 6).
        // A float after a `<br clear>` starts where that break cleared to, which means laying out
        // the content holding the break once. Doing it before the row's first float leaves the
        // rest of the row the same place to start from, rather than each one sliding below the
        // float placed before it.
        if (pieces.length > 0 && piecesClearFloat(pieces, e.block.sv[P.P_FLOAT])) flush();
        if (e.block.wasInline && pieces.length > 0) {
          const at = next + floatLineTop(el, pieces, innerW, pl, pt + next, innerH, ctx, f.x, f.y + next);
          placeFloat(e.block, innerW, innerH, pl, pt, f, at);
        } else {
          if (!e.block.wasInline && pieces.length > 0 && !fitsBeside(ctx, f, next, innerW, pieces, e.block)) flush();
          placeFloat(e.block, innerW, innerH, pl, pt, f, next);
        }
        preplaced[j] = 1;
      }
      flush();
      // A fragment on no line at all is an inline box around nothing: it is recorded for the
      // DOM's rects, but it drew no line box, so it doesn't stop the margins from collapsing
      // through.
      if (next > top || hasLineFragment(el, before)) {
        y = next;
        pendP = 0;
        pendN = 0;
        fixedPend = false;
        leading = false;
        allThrough = false;
      }
      i = j - 1;
      continue;
    }
    if (entry.block === null) continue;
    const c: Node = entry.block;
    // The lines the previous block child took count against the budget.
    if (clampPending !== null && clampPending !== c) {
      clampBlocks += flowLines(clampPending);
      // The budget stays on the child as the record of the pass, so a later layout with the clamp
      // gone can tell it was clamped and drop the layouts that clamped pass made.
      clampPending = null;
    }
    // A child with a formatting context of its own keeps its lines to itself: line-clamp skips
    // them (CSS Overflow 4, and the line-clamp-007 test).
    // A box that was not clamped last time must not keep the budget it had then, and the layout
    // it kept from under that budget is stale.
    if (clampBase < 0 && (c.clampBudget >= 0 || c.clampEllipsis)) clearClamp(c);
    // A child that became a formatting context of its own keeps its lines to itself, so a budget
    // an earlier pass left on it has to go: its text is not part of the clamp any more.
    if (isBfcRoot(c) && (c.clampBudget >= 0 || c.clampEllipsis) && !isFloat(c)) clearClamp(c);
    // One block child holding a flow full of forced breaks lays its lines out in runs the budget
    // can't count straight; the clamp inside it is left to itself.
    const alone = flowKids <= 1 && hasBreak(c);
    if (clampBase >= 0 && !alone && !isFloat(c) && !isBfcRoot(c)) {
      c.clampBudget = Math.max(0, clampBase - el.lineBaseline.length - clampBlocks);
      // Content after this box, or after the box that holds it, means the clamp cuts the flow
      // there, and the last line it keeps ends in an ellipsis even when that line fits. The
      // continuation the container was given has to reach the deepest box that shows the line:
      // a wrapper with nothing after it inside would otherwise drop it.
      c.clampEllipsis = el.clampEllipsis;
      for (let k = i + 1; k < entries.length; k++) {
        const e = entries[k];
        if (e.block !== null || !isBlankPieces(e.pieces)) { c.clampEllipsis = true; break; }
      }
      clampPending = c;
    }
    if (isFloat(c)) {
      // A float leaves the flow: it is placed beside the floats before it, and the content
      // after it flows around it. One that followed a run was placed with it already.
      if (preplaced[i] === 0) placeFloat(c, innerW, innerH, pl, pt, f, y + pendP + pendN);
      continue;
    }
    if (isTableInternal(display(c)) && entry.shiftX === 0 && entry.shiftY === 0) {
      // Table-internal boxes outside a table get an anonymous table around them (CSS 2.1
      // §17.2.2), so the whole run goes through the table algorithm together.
      const run = [c];
      let j = i + 1;
      for (; j < entries.length; j++) {
        const next = entries[j];
        if (next.abs !== null || next.shiftX !== 0 || next.shiftY !== 0) break;
        if (next.block !== null) {
          if (!isTableInternal(display(next.block))) break;
          run.push(next.block);
        } else if (!isBlankPieces(next.pieces)) break;
      }
      i = j - 1;
      // A table box takes no part in margin collapsing.
      if (leading) addEscape(true, pendP, pendN);
      else y += pendP + pendN;
      pendP = 0;
      pendN = 0;
      fixedPend = false;
      leading = false;
      allThrough = false;
      const tTop = pt + y;
      let th = layoutAnonymousTable(el, run, innerW, tTop, pl);
      if (ctx.boxes.length > 0) {
        // A table must not overlap the floats beside it (CSS 2.1 9.5): it goes into the space
        // they leave when its preferred width fits there, and below them when it does not.
        const tW = anonymousTableWidth(el, run, innerW);
        const fit = lineFitY(ctx, by + tTop, th, f.x, innerW, tW);
        const slot = floatSlot(ctx, fit, th, f.x, innerW);
        const tLeft = pl + slot[0] - f.x;
        if (fit > by + tTop + 0.01 || tLeft > pl + 0.01) {
          th = layoutAnonymousTable(el, run, innerW, fit - by, tLeft);
          y = fit - by - pt + th;
          continue;
        }
      }
      y += th;
      continue;
    }
    const mt = zeroIfNaN(len(c, P.P_MARGIN_TOP, innerW));
    const mb = zeroIfNaN(len(c, P.P_MARGIN_BOTTOM, innerW));
    const startsBfc = isBfcRoot(c);
    if (startsBfc && ctx.boxes.length > 0) {
      // A box with its own formatting context avoids the floats itself: it narrows into the
      // space beside them, and goes below them when there is none (CSS 2.1 9.5, 10.3.3).
      const pP = Math.max(pendP, Math.max(0, mt));
      const pN = Math.min(pendN, Math.min(0, mt));
      const clearY = c.sv[P.P_CLEAR] === P.CL_NONE ? -Infinity : clearBottom(ctx, c.sv[P.P_CLEAR]) - f.y;
      let top = leading ? y : y + pP + pN;
      // The margin escapes through this box's top edge only when nothing moves the box down:
      // a float below its place separates the margin from that edge, as clearance does.
      const escapedTop = top;
      const escape = leading && clearY <= top;
      if (clearY > top) top = clearY;
      leading = false;
      allThrough = false;
      pendP = 0;
      pendN = 0;
      fixedPend = false;
      const spec = specW(c, innerW);
      const margins = marginH(c, innerW);
      // An auto-width table beside a float still sizes from its own content, between its min and
      // max content widths, so it may stick out of the space left: only a block that can shrink
      // to the space moves below the float.
      const table = isTableDisplay(display(c));
      // An auto margin becomes zero in an auto-width box (CSS 2.1 10.3.3).
      const autoL = sizeUnit(c, P.P_MARGIN_LEFT) === P.U_AUTO;
      const autoR = sizeUnit(c, P.P_MARGIN_RIGHT) === P.U_AUTO;
      const ml = autoL ? 0 : zeroIfNaN(len(c, P.P_MARGIN_LEFT, innerW));
      const mr = autoR ? 0 : zeroIfNaN(len(c, P.P_MARGIN_RIGHT, innerW));
      // The width an auto-width box takes when no float is in the way.
      const avail0 = Math.max(0, innerW - margins);
      let xoff = ml;
      let fixed = avail0;
      let sw = innerW;
      let slotL = 0;
      let slotR = innerW;
      let h = 0;
      for (let pass = 0; pass < 6; pass++) {
        const slot = floatSlot(ctx, by + pt + top, Math.max(h, 1), f.x, innerW);
        slotL = slot[0] - f.x;
        slotR = slot[1] - f.x;
        sw = Math.max(0, slotR - slotL);
        // A table narrows to the space left beside a float only as far as its min-content width:
        // when the floats leave less than that beside it, it goes below them instead (CSS 2.1
        // 9.5), where it sizes against its containing block again.
        if (pass < 5 && table) {
          const need = Math.max(Number.isNaN(spec) ? 0 : spec, tableShrinkWidth(c, innerW, 0));
          const fit = lineFitY(ctx, by + pt + top, Math.max(h, 1), f.x, innerW, need);
          if (fit > by + pt + top) {
            top = fit - by - pt;
            continue;
          }
        }
        if (pass < 5 && !Number.isNaN(spec)) {
          const fit = avoidFloats(ctx, f.x, innerW, spec, ml, mr, margins, autoL, autoR,
            by + pt + top, Math.max(h, 1));
          if (fit > by + pt + top) {
            top = fit - by - pt;
            continue;
          }
        }
        if (Number.isNaN(spec)) {
          // A float cuts the space beside the box down to what it leaves (CSS 2.1 9.5, 10.3.3).
          // A float on a side bounds the box's border box there: a margin that would push it
          // into or past the float holds at the float's edge instead, and the width shrinks to
          // the space that is left. On a side no float faces, a negative margin may hang the box
          // out of its containing block, and a table sizes from its content even when that
          // overlaps a float.
          const narrowed = slotL > 0.01 || slotR < innerW - 0.01;
          const sides = narrowed ? floatSides(ctx, by + pt + top, Math.max(h, 1)) : [false, false];
          xoff = sides[0] ? Math.max(slotL, ml) : ml;
          const right = sides[1] ? Math.min(ml + avail0, slotR) : ml + avail0;
          const space = Math.max(0, right - xoff);
          fixed = table ? tableShrinkWidth(c, innerW, space) : Math.min(avail0, space);
          // No room beside the floats for the height the box took: it goes below the float that
          // ends first and tries again there, as a float would (CSS 2.1 9.5, 10.3.3).
          // Only a box whose containing block has room to find can gain by moving: one squeezed
          // to zero width by its own parent (a fit-content box) stays where it is.
          // The room to look for is the box's own: from the offset its margins give it, `avail0`
          // wide. Asking for a 1px slot anywhere beside the floats finds the strip on the far side
          // of them, which leaves the box at zero width next to the float it cannot fit beside.
          if (fixed <= 0.01 && avail0 > 0.01) {
            const fit = lineFitY(ctx, by + pt + top, Math.max(h, 1), f.x + xoff,
              Math.max(0, innerW - xoff), avail0);
            if (fit > by + pt + top) {
              top = fit - by - pt;
              continue;
            }
          }
        }
        // A button's box is as wide as its content even beside a float, so its width comes from
        // the shrink-to-fit rule rather than from the space the float leaves.
        const shrink = shrinksToFit(c);
        layoutBox(c, innerW, innerH, Number.isNaN(spec) ? (shrink ? NaN : fixed) : NaN, NaN, shrink);
        if (c.h === h) break;
        h = c.h;
      }
      if (escape && top === escapedTop) addEscape(true, pP, pN);
      // A box beside floats keeps the position its margins give it in the containing block, and
      // the float absorbs as much of the start margin as it covers (CSS 2.1 10.3.3). Only an auto
      // margin, which shares out the space beside the float, is measured against that space.
      const autoM = sizeUnit(c, P.P_MARGIN_LEFT) === P.U_AUTO || sizeUnit(c, P.P_MARGIN_RIGHT) === P.U_AUTO;
      const off = blockOffsetIn(c, innerW, innerW);
      c.x = pl + (Number.isNaN(spec) ? xoff
        : autoM ? slotL + blockOffsetIn(c, sw, innerW)
          : slotL > 0.01 ? Math.max(slotL, off) : off);
      c.y = pt + top;
      place(c);
      c.x += entry.shiftX;
      c.y += entry.shiftY;
      y = top + c.h;
      pendP = Math.max(0, mb);
      pendN = Math.min(0, mb);
      continue;
    }
    const cl = c.sv[P.P_CLEAR];
    const clearY = cl === P.CL_NONE ? -Infinity : clearBottom(ctx, cl) - f.y;
    // The margin collapsed above the child's top border edge, and where that edge will be: after
    // the margin above it, and below the floats it clears. A leading child's margin escapes
    // through this box's top edge instead, so its border edge sits at this box's content top. A
    // margin that escapes through the child's own top edge can only add to this, once the child
    // has been laid out. Its own margin counts here even when it escapes, so that the content
    // laid out inside it starts where the box does.
    const mgP = Math.max(pendP, Math.max(0, mt));
    const mgN = Math.min(pendN, Math.min(0, mt));
    let top = leading ? y : y + mgP + mgN;
    if (clearY > top) top = clearY;
    // Where the child's content box will be, in the coordinates of this float context, so its
    // line boxes and floats avoid the floats already placed here. A box that establishes its
    // own formatting context starts afresh.
    const cx = pl + zeroIfNaN(len(c, P.P_MARGIN_LEFT, innerW)) + inlineStartBorder(c) +
      zeroIfNaN(len(c, P.P_PADDING_LEFT, innerW));
    const childFlow = startsBfc ? undefined
      : new Flow(ctx, bx + cx, by + pt + top + blockStartBorder(c) + zeroIfNaN(len(c, P.P_PADDING_TOP, innerW)), mgP, mgN);
    const boxesBefore = ctx.boxes.length;
    // A button's box is as wide as its content, even as a block-level box.
    const shrink = shrinksToFit(c);
    if (childFlow !== undefined) layoutBox(c, innerW, innerH, NaN, NaN, shrink, undefined, childFlow);
    else layoutBox(c, innerW, innerH, NaN, NaN, shrink);
    // The child's top margin, collapsed with whatever escapes the child's own top edge. That is
    // the margin above its top border edge, which is where a box that collapses through sits.
    const mtP = Math.max(0, mt, c.escTopP);
    const mtN = Math.min(0, mt, c.escTopN);
    // The margin above the child's top border edge, before its own joins it.
    const preP = pendP;
    const preN = pendN;
    if (mtP > pendP) pendP = mtP;
    if (mtN < pendN) pendN = mtN;
    const aboveP = pendP;
    const aboveN = pendN;
    if (c.collapsesThrough) {
      // Its margins collapse through it: it takes no space, and the margins around it stay
      // adjoining.
      const mbP = Math.max(0, mb, c.escBotP);
      const mbN = Math.min(0, mb, c.escBotN);
      if (mbP > pendP) pendP = mbP;
      if (mbN < pendN) pendN = mbN;
      // Its top border edge sits after the margin above it, as if it had a bottom border;
      // when nothing is above it inside this box, it sits at the box's top edge instead.
      // Clearance still moves it below the floats it clears, and takes real room there: what
      // follows starts below it, and its margin no longer escapes this box's top edge. A margin
      // that already carries the box past the floats is left alone instead, unless a float in
      // this same box bounds it (CSS 2.1 9.5.2). A leading margin joins the group above this
      // box's top edge, which starts that far above its content top, so the border edge is
      // measured from where that group starts.
      const hyp = y + aboveP + aboveN - (leading ? f.mgP + f.mgN : 0);
      let at = leading ? y : hyp;
      let cleared = false;
      if (leading) {
        if (clearY > y) {
          if (hyp > clearY && !adjoiningFloat(ctx, el, cl)) at = y;
          else {
            at = clearY;
            cleared = true;
          }
        }
      } else if (clearY >= hyp) {
        at = clearY;
        cleared = true;
      }
      c.x = pl + blockOffset(c, innerW);
      c.y = pt + at;
      place(c);
      c.x += entry.shiftX;
      c.y += entry.shiftY;
      if (cleared) {
        // The box sits where it would inside its collapsed margin, and clearance moved that
        // whole margin down with it: the margin stays inside this box, and the group it belongs
        // to no longer collapses with this box's bottom margin (CSS 2.1 8.3.1). A leading child's
        // margin is separated from this box's top edge by the clearance now, so what escaped
        // above before stays above, and only its own margin is inside.
        if (leading) {
          // The margin that was above the child before its own joined it stays outside this
          // box: it escaped through the top edge, and the clearance pushed the child's own
          // margin down with the child.
          addEscape(true, preP, preN);
          y = clearY - (mtP + mtN);
          pendP = Math.max(mtP, mbP);
          pendN = Math.min(mtN, mbN);
        } else {
          y = clearY - (aboveP + aboveN);
        }
        leading = false;
        allThrough = false;
        fixedPend = true;
      }
      continue;
    }
    allThrough = false;
    // clear moves the child's top border edge below the floats it clears, and its top margin
    // no longer escapes this box's top edge.
    let top2 = 0;
    if (leading) {
      // A leading child's margin escapes through this box's top edge, so where its border edge
      // lands depends on the margin collapsed above this box too: the margin escaping here joins
      // that group, and the box moves down with it. Clearance is only needed when the child would
      // still be beside a float once the whole group has been placed (CSS 2.1 9.5.2). That group
      // starts `f.mgP + f.mgN` above this box's content top, so the border edge is measured
      // from where it starts.
      const hyp = y + Math.max(f.mgP, pendP) + Math.min(f.mgN, pendN) - (f.mgP + f.mgN);
      if (clearY > y) {
        if (hyp > clearY && !adjoiningFloat(ctx, el, cl)) {
          // The margin carries the box, and the floats it would clear would move down with it,
          // so it is already past them without any clearance.
          addEscape(true, pendP, pendN);
          top2 = y;
        } else {
          top2 = clearY;
        }
      } else {
        // Nothing above the child inside this box: its margin escapes the top edge and
        // collapses with the margin above this box.
        addEscape(true, pendP, pendN);
        top2 = y;
      }
    } else {
      top2 = y + pendP + pendN;
      if (clearY > top2) top2 = clearY;
    }
    if (top2 !== top && !startsBfc) {
      // A margin that escaped the child's own top edge moved it from where the margin above it
      // alone had put it. What is inside the child has to start from where the box really is, so
      // lay it out again there; the floats it placed the first time go with the old position.
      top = top2;
      c.escTopP = 0;
      c.escTopN = 0;
      while (ctx.boxes.length > boxesBefore) ctx.boxes.pop();
      const again = new Flow(ctx, bx + cx, by + pt + top + blockStartBorder(c) +
        zeroIfNaN(len(c, P.P_PADDING_TOP, innerW)), mtP, mtN);
      layoutBox(c, innerW, innerH, NaN, NaN, shrink, undefined, again);
    }
    top = top2;
    pendP = 0;
    pendN = 0;
    fixedPend = false;
    leading = false;
    const xLeft = pl + blockOffset(c, innerW);
    c.x = xLeft;
    c.y = pt + top;
    if (isReplaced(c)) {
      // The border box of a block-level replaced element may not overlap the margin box of a
      // float (CSS 2.1 9.5): it takes the space beside the floats, and goes below them when it
      // does not fit there.
      const bw = c.w + padH(c, innerW) + borderLeft(c) + borderRight(c);
      const bh = c.h + padV(c, innerW) + borderTop(c) + borderBottom(c);
      const left = bx + c.x;
      const topCtx = by + c.y;
      // Only a float on that side holds the box back: with none, a negative margin may hang it
      // out of the line to the left, as it does for any box.
      let slot = floatSlot(ctx, topCtx, bh, f.x, innerW);
      let dx = floatSides(ctx, topCtx, bh)[0] && slot[0] > left + 0.01 ? slot[0] - left : 0;
      if (dx > 0 && left + dx + bw > slot[1] + 0.01) {
        const fit = lineFitY(ctx, topCtx, bh, f.x, innerW, bw);
        if (fit > topCtx + 0.01) {
          c.y = fit - by;
          top = c.y - pt;
          slot = floatSlot(ctx, fit, bh, f.x, innerW);
          dx = slot[0] > left + 0.01 ? slot[0] - left : 0;
        }
      }
      c.x += dx;
    }
    place(c);
    c.x += entry.shiftX;
    c.y += entry.shiftY;
    y = top + c.h;
    // The margin below the child, collapsed with whatever escapes its own bottom edge.
    pendP = Math.max(0, mb, c.escBotP);
    pendN = Math.min(0, mb, c.escBotN);
  }
  // The runs above lent the container's budget to the block children's spend; the box leaves
  // with the budget it came in with.
  el.clampBudget = clampIncoming;
  if (leading) {
    // Everything collapsed through, so the margin is at both edges of this box at once: it
    // escapes upward, and downward too when nothing separates it from the bottom edge.
    addEscape(true, pendP, pendN);
    if (openBottom) addEscape(false, pendP, pendN);
  } else if (openBottom) {
    // A margin that a cleared box brought inside stays inside: it does not collapse with the
    // bottom margin of this box (CSS 2.1 8.3.1).
    if (fixedPend) y += pendP + pendN;
    else addEscape(false, pendP, pendN);
  } else {
    y += pendP + pendN;
  }
  el.collapsesThrough = allThrough;
  // A formatting context root is as tall as its lowest float, margins included (CSS 2.1 10.6.7).
  if (isBfcRoot(el)) {
    const bottom = floatBottom(ctx) - f.y;
    if (bottom > y) y = bottom;
  }
  return y;
}

/**
 * Whether one of the floats `clear` applies to lives inside this box's own flow. Such a float
 * moves down with the box, so a margin escaping through this box's top edge cannot carry a
 * cleared child past it: the space between them is clearance (CSS 2.1 9.5.2).
 */
function adjoiningFloat(ctx: FloatCtx, el: Node, side: number): boolean {
  for (const f of ctx.boxes) {
    if (f.owner === null || !el.contains(f.owner)) continue;
    if (side === P.CL_BOTH || (side === P.CL_LEFT && f.side === P.FL_LEFT) ||
      (side === P.CL_RIGHT && f.side === P.FL_RIGHT)) return true;
  }
  return false;
}

/**
 * Lays out a float and places it against the floats already in the context (CSS 2.1 9.5.1):
 * pushed down until it fits beside them, then held to the left or right content edge. Its
 * margins never collapse, and its width shrinks to fit the space it gets.
 */
function placeFloat(c: Node, innerW: number, innerH: number, pl: number, pt: number, f: Flow, yTop: number): void {
  const ctx = f.ctx;
  const side = c.sv[P.P_FLOAT];
  const ml = zeroIfNaN(len(c, P.P_MARGIN_LEFT, innerW));
  const mr = zeroIfNaN(len(c, P.P_MARGIN_RIGHT, innerW));
  const mt = zeroIfNaN(len(c, P.P_MARGIN_TOP, innerW));
  const mb = zeroIfNaN(len(c, P.P_MARGIN_BOTTOM, innerW));
  const mw = ml + mr;
  const left = f.x;
  const right = f.x + innerW;
  let yy = f.y + yTop;
  // A float with clear goes below the floats it clears too.
  const cl = c.sv[P.P_CLEAR];
  if (cl !== P.CL_NONE) {
    const bottom = clearBottom(ctx, cl);
    if (bottom > yy) yy = bottom;
  }
  const spec = specW(c, innerW);
  // A float shrinks to fit the width of its containing block, not the room left beside the
  // floats it is next to: one that no longer fits there slides below them instead.
  const avail = Math.max(0, innerW - mw);
  // The width depends on the height it ends up at, and the height on the width, so settle the
  // two together.
  let w = Number.isNaN(spec) ? 0 : spec;
  let h = 0;
  for (let pass = 0; pass < 4; pass++) {
    let fixed = spec;
    if (!Number.isNaN(spec) && isTableDisplay(display(c))) fixed = tableUsedWidth(c, innerW, spec);
    if (Number.isNaN(spec)) {
      let stf = Math.min(maxContentWidth(c, innerW), avail);
      const min = minContentWidth(c, innerW);
      if (stf < min) stf = min;
      fixed = clampW(c, stf, innerW);
    }
    layoutBox(c, innerW, innerH, fixed, NaN, false);
    const settled = fixed === w && c.h + mb === h;
    w = fixed;
    h = c.h + mb;
    if (settled) break;
  }
  // A float is fitted by its border box and bottom margin; its top margin then shifts the box
  // from there (CSS 2.1 9.5.1). A negative one hangs the float up over the floats above it.
  const fit = floatFitY(ctx, left, right, yy, w + mw, h, side);
  // The float is held to the edge of the space left beside the floats of its own side; it sticks
  // out of its containing block on the other side only when it is too wide to fit there.
  const slot = floatSlot(ctx, fit, Math.max(h, 1), left, innerW);
  const boxX = side === P.FL_RIGHT ? slot[1] - w - mw : slot[0];
  const bxl = side === P.FL_RIGHT ? slot[1] - mr - w : slot[0] + ml;
  // The box recorded for the floats that follow is the margin box: it starts where the border box
  // was fitted, since fitting it there is what the margins then shift it away from.
  const box = new FloatBox(boxX, fit, w + mw, c.h + mt + mb, side);
  box.owner = c;
  // A float's `shape-outside` turns its rectangle into the outline lines wrap around, taken
  // against the margin box unless it names another.
  if (c.sv[P.P_SHAPE_OUTSIDE] >= 0 && c instanceof Element) {
    const bl2 = borderLeft(c), br2 = borderRight(c), bt2 = borderTop(c), bb2 = borderBottom(c);
    const pl2 = zeroIfNaN(len(c, P.P_PADDING_LEFT, innerW)), pr2 = zeroIfNaN(len(c, P.P_PADDING_RIGHT, innerW));
    const pt2 = zeroIfNaN(len(c, P.P_PADDING_TOP, innerW)), pb2 = zeroIfNaN(len(c, P.P_PADDING_BOTTOM, innerW));
    box.shape = floatShapePolygon(c, {
      margin: [boxX, fit, w + mw, c.h + mt + mb],
      border: [bxl, fit + mt, w, c.h],
      padding: [bxl + bl2, fit + mt + bt2, Math.max(0, w - bl2 - br2), Math.max(0, c.h - bt2 - bb2)],
      content: [bxl + bl2 + pl2, fit + mt + bt2 + pt2, Math.max(0, w - bl2 - br2 - pl2 - pr2),
        Math.max(0, c.h - bt2 - bb2 - pt2 - pb2)],
    });
  }
  ctx.boxes.push(box);
  c.x = bxl - (f.x - pl);
  c.y = fit + mt - (f.y - pt);
  place(c);
}

/** The width of the first run of content the pieces lay out: what a line box must hold. */
function firstLineWidth(pieces: Piece[], innerW: number): number {
  measurePieces(pieces, innerW, true);
  const lines = breakLines(pieces, innerW);
  return lines.length > 0 ? lines[0].first : 0;
}

/**
 * True when the line the content before a float is on still leaves room for the float beside its
 * content, so the float can sit at the top of that line instead of below it.
 */
function fitsBeside(ctx: FloatCtx, f: Flow, y: number, innerW: number, pieces: Piece[],
  fl: Node): boolean {
  const w = specW(fl, innerW);
  if (Number.isNaN(w)) return true;
  const room = floatSlot(ctx, f.y + y, 1, f.x, innerW);
  return firstLineWidth(pieces, innerW) + w + marginH(fl, innerW) <= room[1] - room[0] + 0.5;
}

/**
 * The y (in the context's coordinates) at which a formatting context root keeps clear of the
 * floats: beside them when the space they leave holds its border box, or else below the float it
 * runs into, as clearance would put it (CSS 2.1 9.5, 9.5.2).
 */
function avoidFloats(ctx: FloatCtx, left: number, cbW: number, spec: number, ml: number, mr: number,
  margins: number, autoL: boolean, autoR: boolean, y: number, h: number): number {
  let yy = y;
  for (let guard = 0; guard < 32; guard++) {
    const s = floatSlot(ctx, yy, Math.max(h, 1), left, cbW);
    // The spare space in the slot goes to whichever margins are auto.
    const spare = s[1] - s[0] - spec - margins;
    // A margin is measured from the containing block, not from the space a float leaves: a float
    // absorbs as much of the start margin as it covers, and the border box keeps the rest of it
    // (CSS 2.1 10.3.3). Adding the margin to the float's own edge instead pushed a box with a
    // margin-left of 40px past a 20px float and below both floats, where its border box runs from
    // 40 to 70 beside them.
    // Only a float on the start side can absorb the margin: with none there the slot starts at the
    // containing block and a negative margin hangs the box out of it, as CSS allows.
    let x = s[0] > left + 0.01 ? Math.max(s[0], left + ml) : left + ml;
    if (autoL && autoR) x += Math.max(0, spare) / 2;
    else if (autoL) x += Math.max(0, spare);
    // A box reaching past the space the floats leave at its own top has nowhere to go but below
    // them, and so has one whose left margin runs its border box into a float. A negative right
    // margin pulls the box's margin box back into the space, though, which is what has to fit.
    if (x + spec + Math.min(0, mr) <= s[1] + 0.01 && !overlapsFloats(ctx, x, spec, yy, h)) return yy;
    let next = Infinity;
    for (const b of ctx.boxes) {
      const bb = b.y + b.h;
      if (bb <= yy + 0.01 || b.y >= yy + h - 0.01) continue;
      if (bb < next) next = bb;
    }
    if (next === Infinity || !(next > yy)) return yy;
    yy = next;
  }
  return yy;
}

/** True when a border box at x, w wide and y to y + h would overlap a float of the context. */
function overlapsFloats(ctx: FloatCtx, x: number, w: number, y: number, h: number): boolean {
  for (const b of ctx.boxes) {
    if (b.y + b.h <= y + 0.01 || b.y >= y + h - 0.01) continue;
    if (b.x >= x + w - 0.01 || b.x + b.w <= x + 0.01) continue;
    return true;
  }
  return false;
}

