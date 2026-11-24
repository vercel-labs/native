import { boxKids } from "../dom.ts";
// Multi-column layout: a block box's content flows down one column, then the next, with a gutter
// and a rule between them (CSS Multicol 1). A box is a multicol container when it names a column
// count or a column width; everything else about it is a block box.

import * as P from "../../shared/props.ts";
import type { Node } from "../dom.ts";
import { layoutBox } from "./box.ts";
import { display, isOutOfFlow, len, padV, place, zeroIfNaN } from "./box-model.ts";
import { fragmentedRun } from "./fragment.ts";
import type { FragmentedRun, Piece } from "./fragment.ts";

/** Does this box lay its content out into columns? A column height of its own makes a box a
 *  one-column container whose content wraps into rows. */
export function isMulticol(el: Node): boolean {
  return el.su[P.P_COLUMN_COUNT] !== P.U_AUTO || el.su[P.P_COLUMN_WIDTH] !== P.U_AUTO ||
    el.su[P.P_COLUMN_HEIGHT] !== P.U_AUTO;
}

/** The gutter between columns: `normal` is one em in multi-column layout. */
function columnGap(el: Node, innerW: number): number {
  if (el.su[P.P_COLUMN_GAP] === P.U_NORMAL) return el.sv[P.P_FONT_SIZE];
  return zeroIfNaN(len(el, P.P_COLUMN_GAP, innerW));
}

/** The gutter between rows of wrapped columns: `normal` is one em here too, as Chrome reads it. */
function rowGap(el: Node, innerW: number): number {
  const u = el.su[P.P_ROW_GAP];
  if (u === P.U_NORMAL) return el.sv[P.P_FONT_SIZE];
  if (u === P.U_AUTO) return 0;
  return zeroIfNaN(len(el, P.P_ROW_GAP, innerW));
}

/**
 * The used column count, column width and gutter (CSS Multicol 1's pseudo-algorithm): a set
 * count fixes the number, a set width gives as many as fit, and both cap each other.
 */
function columnsOf(el: Node, innerW: number): { n: number; w: number; gap: number } {
  const gap = columnGap(el, innerW);
  const countAuto = el.su[P.P_COLUMN_COUNT] === P.U_AUTO;
  const widthAuto = el.su[P.P_COLUMN_WIDTH] === P.U_AUTO;
  const count = countAuto ? 0 : Math.max(1, el.sv[P.P_COLUMN_COUNT]);
  const width = widthAuto ? NaN : Math.max(1, len(el, P.P_COLUMN_WIDTH, innerW));
  let n: number;
  if (countAuto && widthAuto) n = 1;
  else if (!countAuto && widthAuto) n = count;
  else if (countAuto) n = Math.max(1, Math.floor((innerW + gap) / (width + gap)));
  else n = Math.min(count, Math.max(1, Math.floor((innerW + gap) / (width + gap))));
  return { n, w: Math.max(0, (innerW + gap) / n - gap), gap };
}

/**
 * The column height that fits the content into `n` columns: the smallest height at which the
 * columns no longer need more than the count. A box taller than the height still takes its own
 * room, as a monolithic fragment does.
 */
function balancedHeight(run: FragmentedRun, n: number, total: number): number {
  // A column of no height puts the whole content in one column, so the search starts above it.
  let lo = 1;
  let hi = Math.max(0, Math.ceil(total));
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    if (run.columns(mid) <= n) hi = mid;
    else lo = mid + 1;
  }
  return lo;
}

/**
 * Lays out a multi-column box: its children fill one column after another, then it is as tall as
 * its columns when it has no height of its own. Returns the content height it takes.
 */
export function layoutMulticol(el: Node, innerW: number, innerH: number, pl: number, pt: number): number {
  const { n, w, gap } = columnsOf(el, innerW);
  const rgap = rowGap(el, innerW);
  const fill = el.sv[P.P_COLUMN_FILL];
  // Collapsible whitespace between the box's children makes no box of its own, as it makes no
  // line between block-level boxes.
  const kids = boxKids(el).filter((c) => display(c) !== P.D_NONE && !isOutOfFlow(c) &&
    !(c.isTextNode && /^[ \t\n\r\f]*$/.test(c.ownText)));

  // Measure every child once, at the width its column gives it, to know how much room it takes.
  const pieces: Piece[] = [];
  for (const c of kids) {
    const span = c.sv[P.P_COLUMN_SPAN] === P.CS_ALL;
    layoutBox(c, span ? innerW : w, Number.isNaN(innerH) ? NaN : innerH, NaN, NaN, false);
    pieces.push({
      c, span, h: c.h,
      ml: zeroIfNaN(len(c, P.P_MARGIN_LEFT, w)), mr: zeroIfNaN(len(c, P.P_MARGIN_RIGHT, w)),
      mt: zeroIfNaN(len(c, P.P_MARGIN_TOP, w)), mb: zeroIfNaN(len(c, P.P_MARGIN_BOTTOM, w)),
      bb: c.sv[P.P_BREAK_BEFORE], ba: c.sv[P.P_BREAK_AFTER],
    });
  }

  el.colRulesX = [];
  el.colRulesH = 0;
  // The column height and whether the columns wrap are the box's own, not a run's.
  const own = el.su[P.P_COLUMN_HEIGHT] !== P.U_AUTO ? len(el, P.P_COLUMN_HEIGHT, innerW) : NaN;
  // A column height of the author's wraps the columns the content cannot fit in one row on its
  // own; the box's own height wraps only when the author asks for it, and `nowrap` never does.
  const wrapKw = el.sv[P.P_COLUMN_WRAP];
  const wrapping = wrapKw !== P.CW_NOWRAP &&
    (!Number.isNaN(own) || (wrapKw === P.CW_WRAP && !Number.isNaN(innerH)));
  let base = 0;
  let contentH = 0;
  let ruleTop = 0;
  let ruleH = 0;
  let wrapped = false;
  // How far apart the rows of columns start: a column height of the author's, else the box's own
  // height, and the gap between rows on top of that.
  const columnH = !Number.isNaN(own) ? own : innerH;
  let rowStep = wrapping && !Number.isNaN(columnH) ? columnH + rgap : 0;

  // A run of columns, then a spanner, then another run: each run is laid out on its own and the
  // whole content stacks down the box.
  let i = 0;
  while (i < pieces.length) {
    let j = i;
    while (j < pieces.length && !pieces[j].span) j++;
    const run = pieces.slice(i, j);
    if (run.length > 0) {
      const frag = fragmentedRun(run);
      let total = 0;
      for (let k = 0; k < run.length; k++) {
        total += (k === 0 ? run[k].mt : Math.max(run[k - 1].mb, run[k].mt)) + run[k].h;
      }
      // A column height of its own fixes each column; otherwise the box's height does, and with
      // neither the content is balanced (or filled in order) inside the max-height when it has one.
      const maxH = Number.isNaN(innerH) ? len(el, P.P_MAX_HEIGHT, NaN) : NaN;
      const capped = Number.isNaN(maxH) ? NaN : el.sv[P.P_BOX_SIZING] === P.BS_BORDER
        ? Math.max(0, maxH - padV(el, innerW)) : maxH;
      // A column the author fixed (or a max-height that caps one) lets the fill cut through a box
      // that does not fit; so does a balanced column, which a box taller than it overflows in a
      // browser only when the box is one piece to begin with.
      const split = true;
      // The height of a column: the author's column height, else the box's own height, capped by
      // the height the content balances at. With an auto height and a fill in order, one column
      // takes the whole content.
      const inOrder = fill === P.CF_AUTO;
      let h: number;
      if (wrapping) {
        // Rows of columns are as tall as the column height; content that fits in one row instead
        // balances inside it.
        h = !inOrder && frag.columns(columnH) <= n ? balancedHeight(frag, n, total) : columnH;
      } else if (!Number.isNaN(own)) h = inOrder ? own : Math.min(own, balancedHeight(frag, n, total));
      else if (!Number.isNaN(innerH)) {
        h = inOrder ? innerH : Math.min(innerH, balancedHeight(frag, n, total));
      } else if (inOrder) h = total;
      else h = balancedHeight(frag, n, total);
      if (!Number.isNaN(capped) && h > capped) h = capped;
      // The fill breaks the run into columns, moving the boxes below a break into the next one.
      const used = frag.layout(h, pl, pt + base, w, gap, split, wrapping ? n : 0, rgap,
        wrapping && !inOrder);
      const blockH = wrapping && !Number.isNaN(own) ? Math.max(used.height, own) : used.height;
      contentH = Math.max(contentH, base + blockH);
      if (ruleH === 0 && blockH > 0) { ruleTop = base; ruleH = blockH; }
      if (wrapping) {
        // A row of columns is as tall as its columns, and each row holds the rules between them,
        // whether or not content reached every column.
        const rowH = Number.isNaN(own) ? h : Math.max(h, own);
        if (rowStep === 0) rowStep = rowH + rgap;
        for (let k = 1; k < n; k++) el.colRulesX.push(pl + k * (w + gap) - gap / 2);
        for (let r = 0; r < used.rows; r++) el.colRuleYs.push(base + r * rowStep);
        if (rowH > el.colRulesH) el.colRulesH = rowH;
        wrapped = true;
      } else {
        for (let k = 1; k < Math.min(n, used.columns); k++) {
          el.colRulesX.push(pl + k * (w + gap) - gap / 2);
        }
      }
      base += blockH;
    }
    if (j < pieces.length) {
      // The spanner takes the whole width below the columns it follows. It takes whole rows of
      // them, so the columns after it start at the next row boundary below it (CSS Multicol 2).
      const p = pieces[j];
      // A spanner takes whole rows: it starts at the row boundary below the row before it.
      if (rowStep > 0 && base > 1e-6) base = Math.ceil((base - 1e-6) / rowStep) * rowStep;
      const top = base + p.mt;
      p.c.x = pl + p.ml;
      p.c.y = pt + top;
      place(p.c);
      contentH = Math.max(contentH, top + p.h);
      base = contentH;
      if (rowStep > 0) base = Math.ceil((base - 1e-6) / rowStep) * rowStep;
      i = j + 1;
    } else {
      i = j;
    }
  }
  if (wrapped) {
    // Every row of columns drew its own rules, a row of columns tall.
    if (!Number.isNaN(own) && own > el.colRulesH) el.colRulesH = own;
  } else if (!Number.isNaN(own)) {
    el.colRulesH = own;
    el.colRuleYs.push(0);
  } else if (Number.isNaN(innerH)) {
    el.colRulesH = ruleH;
    el.colRuleYs.push(ruleTop);
  } else {
    el.colRulesH = innerH;
    el.colRuleYs.push(0);
  }
  return Math.max(contentH, 0);
}
