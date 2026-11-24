import { boxKids } from "../dom.ts";
import type { Node } from "../dom.ts";
// Fragmentation: the content of a column run fills one column, and when it runs past the column's
// bottom the fill stops at the last break between boxes -- or at the column's bottom when there
// is none -- and carries on at the top of the next column. A box that the break cuts through
// draws in every column it reaches (CSS Fragmentation 3).

import * as P from "../../shared/props.ts";
import { usedWritingMode } from "../style.ts";
import { hasTransform } from "../transform.ts";
import {
  clipsX, clipsY, display, hasSizeContainment, isFloat, isOutOfFlow, isReplaced, place,
} from "./box-model.ts";

/** One child of a column run, as the run sizes it. */
export interface Piece {
  c: Node;
  span: boolean;
  h: number;
  ml: number;
  mr: number;
  mt: number;
  mb: number;
  /** The child's `break-before` and `break-after`, as the `BK_*` keywords. */
  bb: number;
  ba: number;
}

/** One box of the run, in the run's coordinates: `top` is the flow position of its top edge. */
interface Box {
  el: Node;
  top: number;
  h: number;
  /** The margin collapsed above the box, when it is a child of the run itself. */
  margin: number;
  /** Whether the fill may cut through this box: it is a block box whose content is a stack of
   *  boxes that stay inside it, and nothing about it keeps its box in one piece. */
  open: boolean;
  /** Whether the fill may cut this box anywhere: it holds nothing, so its box alone is all there
   *  is to keep in one piece. */
  sliced: boolean;
  kids: Box[];
}

const EPS = 1e-6;

/** A forced break value opens a new column wherever it falls. */
function forcedBreak(v: number): boolean {
  return v === P.BK_PAGE || v === P.BK_COLUMN || v === P.BK_REGION || v === P.BK_LEFT ||
    v === P.BK_RIGHT || v === P.BK_RECTO || v === P.BK_VERSO;
}

/** Whether a break between the box before and the box after is avoided in column layout. */
function avoidedBreak(after: number, before: number): boolean {
  return before === P.BK_AVOID || before === P.BK_AVOID_COLUMN ||
    after === P.BK_AVOID || after === P.BK_AVOID_COLUMN;
}

/** Whether a break is avoided inside this box, so that its box goes to the next column whole. */
function avoidsInside(el: Node): boolean {
  const v = el.sv[P.P_BREAK_INSIDE];
  return v === P.BK_AVOID || v === P.BK_AVOID_COLUMN || v === P.BK_AVOID_PAGE ||
    v === P.BK_AVOID_REGION;
}

/** Whether a box is one the columns may cut through: a block box in the flow that nothing keeps
 *  in one piece. */
function plainBlock(el: Node): boolean {
  if (el.isTextNode || isReplaced(el)) return false;
  const d = display(el);
  if (d !== P.D_BLOCK && d !== P.D_LIST_ITEM && d !== P.D_FLOW_ROOT) return false;
  if (isOutOfFlow(el) || isFloat(el)) return false;
  // The columns run down the page in these layouts, so a box in another writing mode is left
  // in one piece rather than cut across its own inline axis.
  if (usedWritingMode(el) !== P.WM_HORIZONTAL_TB) return false;
  if (hasTransform(el)) return false;
  // A clipped, contained or column box paints and clips its content as a unit.
  if (clipsX(el) || clipsY(el) || hasSizeContainment(el)) return false;
  if (el.su[P.P_COLUMN_COUNT] !== P.U_AUTO || el.su[P.P_COLUMN_WIDTH] !== P.U_AUTO ||
    el.su[P.P_COLUMN_HEIGHT] !== P.U_AUTO) return false;
  // Inline content is laid out as lines, which a column break doesn't split yet.
  return el.fragKind.length === 0;
}

/** Whether the fill may break between a box's children and cut through the box itself. */
function opens(el: Node): boolean {
  return plainBlock(el) && !avoidsInside(el);
}

/** Whether a box holds nothing at all, so a column may cut its box wherever the column ends. A
 *  box whose height is all padding and border has no content area to cut, and stays whole. */
function hollow(el: Node): boolean {
  if (el.isTextNode || !plainBlock(el) || avoidsInside(el)) return false;
  if (el.contentH <= 0) return false;
  for (const c of boxKids(el)) {
    if (display(c) === P.D_NONE || isOutOfFlow(c)) continue;
    if (c.isTextNode && /^[ \t\n\r\f]*$/.test(c.ownText)) continue;
    return false;
  }
  return true;
}

/** Whether a box is one the block flow puts after its siblings, at block level. */
function blockLevel(el: Node): boolean {
  const d = display(el);
  return d !== P.D_NONE && d !== P.D_INLINE && d !== P.D_INLINE_BLOCK && d !== P.D_INLINE_TABLE &&
    d !== P.D_INLINE_FLEX && d !== P.D_INLINE_GRID && d !== P.D_INLINE_GRID_LANES &&
    d !== P.D_CONTENTS;
}

/**
 * The box `el` makes in the run, with the boxes its content stacks below it. A box whose content
 * reaches past its own bottom, or whose children overlap or leave a gap in the stack, is kept in
 * one piece: the fill has no stack of boxes to cut it between.
 */
function build(el: Node, top: number, margin: number): Box {
  const box: Box = { el, top, h: el.h, margin, open: false, sliced: hollow(el), kids: [] };
  if (!opens(el)) return box;
  const kids: Box[] = [];
  let bottom = top;
  for (const c of boxKids(el)) {
    if (display(c) === P.D_NONE) continue;
    // Collapsible whitespace between boxes makes no box of its own, as it makes no line between
    // blocks. A no-break space is not collapsible white space and does make a line.
    if (c.isTextNode && /^[ \t\n\r\f]*$/.test(c.ownText)) continue;
    if (isOutOfFlow(c) || isFloat(c) || !blockLevel(c)) return box;
    const kid = build(c, top + c.y, 0);
    if (kid.top < bottom - EPS || kid.top + kid.h > top + el.h + EPS) return box;
    bottom = kid.top + kid.h;
    kids.push(kid);
  }
  // The fill cuts a box between the boxes its content stacks, so a box with one piece of content
  // has no break of its own unless that content can be cut through.
  if (kids.length === 0 || (kids.length === 1 && !kids[0].open)) return box;
  box.open = true;
  box.kids = kids;
  return box;
}

/** The boxes of the run, in flow order, each parent before its content. */
function flatten(boxes: Box[], out: Box[]): void {
  for (const b of boxes) {
    out.push(b);
    flatten(b.kids, out);
  }
}

/**
 * Where the fill breaks a column that starts at `s` and ends at `s + h`, walking one level of the
 * run's tree. Returns null when everything at this level fits above the column's bottom.
 *
 * A box that begins in the column and does not fit there moves to the next one, together with the
 * box before it when the break between them is avoided. Content that begins the run overflows the
 * column whole, as a monolithic fragment does: no break can move it anywhere better.
 */
function cutIn(boxes: Box[], s: number, L: number, split: boolean): number | null {
  let placed = -1;
  for (let i = 0; i < boxes.length; i++) {
    const b = boxes[i];
    const bottom = b.top + b.h;
    if (bottom <= s + EPS) continue;
    const forced = forcedBreak(b.el.sv[P.P_BREAK_BEFORE]) ||
      (i > 0 && forcedBreak(boxes[i - 1].el.sv[P.P_BREAK_AFTER]));
    // A forced break cuts where the margin above the box ends, so that margin opens the next
    // column with the box.
    if (forced && placed >= s - EPS && b.top - b.margin > s + EPS &&
      b.top - b.margin <= L + EPS) {
      return b.top - b.margin;
    }
    if (b.open && split) {
      const inner = cutIn(b.kids, s, L, split);
      if (bottom <= L + EPS) {
        // The box fits the column. Only a break its content asks for, a forced one, ends it early.
        if (inner !== null && inner <= L + EPS) return inner;
        placed = bottom;
        continue;
      }
      // A break the content takes inside the column segments the box there.
      if (inner !== null && inner <= L + EPS) return inner;
      // Otherwise content above the box has a column of its own already, so the box moves to the
      // next column whole rather than being cut through its own box.
      if (placed >= s - EPS && b.top > s + EPS) return b.top;
      // The box begins this column: its content carries on in the next, or its own box is cut at
      // the column's bottom when its content fits.
      if (inner !== null) return inner;
      return L;
    }
    if (b.sliced && split) {
      if (bottom <= L + EPS) { placed = bottom; continue; }
      // A box begins beyond the column's bottom: the next column starts at its top.
      if (b.top > L + EPS) return b.top;
      // A box that holds nothing has no content to keep in one piece, so the column cuts its box
      // at the bottom, and the box carries on in the next column.
      if (b.top < s - EPS || placed < s - EPS) return L;
    }
    if (bottom <= L + EPS) { placed = bottom; continue; }
    if (b.top < s - EPS) return bottom;
    if (placed < s - EPS) {
      // Nothing is placed in this column yet: the box overflows it whole. Content after the box
      // still starts the next column at its own top, with the margin between them cut away.
      const next = boxes[i + 1];
      if (next !== undefined && next.top > bottom + EPS) return next.top;
      return bottom;
    }
    // Break before the box, moving up past any break the pair avoids.
    let k = i;
    while (k > 0 && avoidedBreak(boxes[k].el.sv[P.P_BREAK_BEFORE],
      boxes[k - 1].el.sv[P.P_BREAK_AFTER])) k--;
    if (k > 0 && boxes[k].top > s + EPS) return boxes[k].top;
    return b.top;
  }
  return null;
}

/**
 * Where the fill breaks the run for columns of height `h`. A forced break opens a new column
 * wherever one falls; otherwise a column holds every box that fits above its bottom, breaking
 * before the first one that does not. A column of no height takes the whole content in one piece
 * and overflows it.
 */
function choose(root: Box[], h: number, total: number, split: boolean, start = 0): number[] {
  const out: number[] = [];
  let s = start;
  while (s < total - EPS) {
    if (h <= EPS) {
      out.push(total);
      break;
    }
    const found = cutIn(root, s, s + h, split);
    if (found === null) break;
    let cut = found;
    if (cut <= s + EPS) cut = s + h;
    if (cut > total) cut = total;
    out.push(cut);
    s = cut;
  }
  return out;
}

/** The height each column takes. */
function columnHeights(root: Box[], breaks: number[], total: number, split: boolean): number[] {
  const flat: Box[] = [];
  flatten(root, flat);
  const out: number[] = [];
  for (let j = 0; j <= breaks.length; j++) {
    const lo = j > 0 ? breaks[j - 1] : 0;
    const hi = j < breaks.length ? breaks[j] : total;
    // Boxes kept whole run to the break, trailing margins and all; a column the fill cuts through
    // is as tall as the content it holds.
    let tall = split ? 0 : hi - lo;
    for (const b of flat) {
      const bottom = b.top + b.h;
      if (bottom <= lo + EPS || b.top >= hi - EPS) continue;
      const reach = Math.min(bottom, hi) - lo;
      if (reach > tall) tall = reach;
    }
    out.push(tall);
  }
  return out;
}

/** How many columns hold content: a break at the very end leaves the last column empty. */
function usedCount(heights: number[]): number {
  let n = 0;
  for (const v of heights) if (v > EPS) n++;
  return Math.max(1, n);
}

/** A run laid out into columns. */
export interface FragmentedRun {
  /** How many columns of height `h` the content needs. */
  columns(h: number): number;
  /**
   * Places the run's boxes into columns of height `h`, starting at `pt` in the box whose content
   * edge is `pl`, and returns the height it takes, how many columns it used and how many rows of
   * columns those made. With `split`, a box that does not fit is cut between its own children;
   * without it, boxes stay whole. With `rowCols`, the columns wrap into rows of that many, each
   * row `rowGap` below the one above (CSS Multicol 2's column-wrap). With `balanceLastRow`, the
   * columns of the last row balance what is left of the content instead of filling in order.
   */
  layout(h: number, pl: number, pt: number, w: number, gap: number, split: boolean,
    rowCols?: number, rowGap?: number,
    balanceLastRow?: boolean): { height: number; columns: number; rows: number };
}

export function fragmentedRun(pieces: Piece[]): FragmentedRun {
  const root: Box[] = [];
  let total = 0;
  let prevMb = 0;
  for (let i = 0; i < pieces.length; i++) {
    const p = pieces[i];
    const m = i === 0 ? p.mt : Math.max(prevMb, p.mt);
    root.push(build(p.c, total + m, m));
    total += m + p.h;
    prevMb = p.mb;
  }
  function layout(h: number, pl: number, pt: number, w: number, gap: number,
    split: boolean, rowCols = 0, rowGap = gap,
    balanceLastRow = false): { height: number; columns: number; rows: number } {
    let breaks = choose(root, h, total, split);
    // Rows above the last fill their columns to the column height; the last row balances what is
    // left over its share of columns, when the box balances its content (column-fill: balance).
    if (rowCols > 0 && balanceLastRow) {
      // A break at the very end opens an empty column, which holds nothing and counts for none.
      const columnsOf = (b: number[]): number =>
        b.length + 1 - (b.length > 0 && b[b.length - 1] >= total - EPS ? 1 : 0);
      const rows = Math.ceil(columnsOf(breaks) / rowCols);
      if (rows > 1) {
        const first = (rows - 1) * rowCols;
        const s0 = breaks[first - 1];
        let lo = 1;
        let hi = h;
        while (lo < hi) {
          const mid = Math.floor((lo + hi) / 2);
          if (columnsOf(choose(root, mid, total, split, s0)) <= rowCols) hi = mid;
          else lo = mid + 1;
        }
        breaks = breaks.slice(0, first).concat(choose(root, lo, total, split, s0));
      }
    }
    // Columns sit side by side and share their top edge, so a box in column k starts `breaks[k-1]`
    // higher up the flow than the column's top.
    const shift = (k: number): number => (k > 0 ? -breaks[k - 1] : 0);
    // Columns of a column height wrap into rows that hold `rowCols` of them, the next row starting
    // below the one above once all of them are full.
    const wrap = rowCols > 0;
    const colX = (k: number): number => (wrap ? k % rowCols : k) * (w + gap);
    const colY = (k: number): number => (wrap ? Math.floor(k / rowCols) * (h + rowGap) : 0);
    const column = (y: number): number => {
      let k = 0;
      while (k < breaks.length && breaks[k] <= y + EPS) k++;
      return k;
    };
    // The column a box starts in. A box with no height that begins exactly at a break was placed
    // above it, so it stays in the column before; anything else at a break starts the next one.
    const columnOf = (b: Box): number => {
      let k = 0;
      while (k < breaks.length && breaks[k] < b.top - EPS) k++;
      if (k < breaks.length && breaks[k] <= b.top + EPS && b.h > EPS) k++;
      return k;
    };
    // A box draws in each column it reaches: its own part there, and whether it holds the box's
    // start or end edge, which are the edges a cut keeps the border and padding of.
    const fragments = (b: Box, k0: number): void => {
      const k1 = column(b.top + b.h - EPS);
      if (k1 <= k0) {
        if (b.el.fragBoxes.length > 0) b.el.fragBoxes = [];
        return;
      }
      const out: number[] = [];
      for (let j = k0; j <= k1; j++) {
        const lo = j > 0 ? breaks[j - 1] : 0;
        const hi = j < breaks.length ? breaks[j] : total;
        const t = Math.max(b.top, lo);
        const bt = Math.min(b.top + b.h, hi);
        if (bt - t <= EPS) continue;
        out.push(colX(j) - colX(k0),
          (t - b.top) + (colY(j) - colY(k0)) + (shift(j) - shift(k0)), b.el.w, bt - t,
          t <= b.top + EPS ? 1 : 0, bt >= b.top + b.h - EPS ? 1 : 0);
      }
      // One piece is the box itself, not a box cut across columns: leave it drawn whole.
      if (out.length <= 6) {
        if (b.el.fragBoxes.length > 0) b.el.fragBoxes = [];
        return;
      }
      b.el.fragBoxes = out;
    };
    // A column break moves a box's content by the difference of its column and its parent's.
    const walk = (boxes: Box[], parentColumn: number, parentShift: number): void => {
      for (const b of boxes) {
        const k = columnOf(b);
        if (k !== parentColumn) {
          b.el.x += colX(k) - colX(parentColumn);
          b.el.y += colY(k) - colY(parentColumn) + shift(k) - parentShift;
        }
        walk(b.kids, k, shift(k));
        fragments(b, k);
      }
    };
    for (let i = 0; i < root.length; i++) {
      const b = root[i], p = pieces[i];
      const k = columnOf(b);
      b.el.x = pl + p.ml + colX(k);
      b.el.y = pt + colY(k) + b.top + shift(k);
      place(b.el);
      walk(b.kids, k, shift(k));
      fragments(b, k);
    }
    const heights = columnHeights(root, breaks, total, split);
    let tall = 0;
    for (const v of heights) if (v > tall) tall = v;
    const columns = usedCount(heights);
    // Columns beyond a row's share start a row of their own below it, a row gap apart.
    const rows = wrap ? Math.ceil(columns / rowCols) : 1;
    const height = wrap && h > 0 ? rows * (h + rowGap) - rowGap : tall;
    return { height, columns, rows };
  }

  // The balance search asks how many columns a height needs, cutting boxes that a column can cut
  // through just as the layout would.
  return {
    columns: (h: number) => usedCount(columnHeights(root, choose(root, h, total, true), total, true)),
    layout,
  };
}
