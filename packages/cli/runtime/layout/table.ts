// Table layout: the box tree of a table (rows, row groups, columns, captions), automatic and
// fixed column widths, row heights, and the placement of cells and their contents.
//
// CSS 2.1 §17 defines the model: a table box holds captions and row groups (rows directly in the
// table, or cells directly in a row, get anonymous boxes around them), and cells form a grid with
// colspan/rowspan. The grid is built on every layout from the DOM: rows and cells stay the
// elements they are, and anonymous table boxes are virtual, since they have no style of their own.
// Anonymous cells (stray content in a table or row) lay their content out into fragments stored
// on their nearest real ancestor, which is what paints them.

import * as P from "../../shared/props.ts";
import { settleNode } from "./incremental.ts";
import { Node, Element, boxKids } from "../dom.ts";
import { exprLength, isVerticalText, lineHeightPx } from "../style.ts";
import { layoutBox } from "./box.ts";
import {
  Piece, atomicBaseline, breakLines, gatherPieces, isCollapsibleRun, isInlineLevel, measurePieces, piecesMaxContent,
  piecesMinContent, placeAbsOfBlankRun, pushText, splitFlow,
} from "./inline.ts";
import { baselineOffset, intrinsicMaxWidth, intrinsicMinWidth, maxContentWidth, minContentWidth } from "./text.ts";
import {
  allChildren, borderLeft, borderPx, borderRight, borderTop, clampW, display, isFloat, isIntrinsicSize, isOutOfFlow, len,
  marginH, padH, padV, place, relativeOffset, specH, specW, visibleChildren, zeroIfNaN,
} from "./box-model.ts";
import { FloatBox, FloatCtx, floatFitY, floatSlot } from "./floats.ts";

// ---------------------------------------------------------------------------
// Display classification

export function isTableDisplay(d: number): boolean {
  return d === P.D_TABLE || d === P.D_INLINE_TABLE;
}

export function isTableRowGroup(d: number): boolean {
  return d === P.D_TABLE_ROW_GROUP || d === P.D_TABLE_HEADER_GROUP || d === P.D_TABLE_FOOTER_GROUP;
}

/** A display value that only makes sense inside a table (row groups, rows, cells, ...). */
export function isTableInternal(d: number): boolean {
  return d >= P.D_TABLE_ROW_GROUP && d <= P.D_TABLE_CAPTION;
}

/**
 * A row with no cells, or a row group with no rows, generates no box: it paints no background or
 * border, whatever those properties say.
 */
/**
 * True for a cell that `empty-cells: hide` leaves unpainted: it holds nothing but white space.
 * The property only applies to cells, and only in the separate borders model.
 */
export function isEmptyCell(el: Node): boolean {
  if (display(el) !== P.D_TABLE_CELL) return false;
  if (el.sv[P.P_EMPTY_CELLS] !== P.EC_HIDE) return false;
  if (el.sv[P.P_BORDER_COLLAPSE] !== P.BC_SEPARATE) return false;
  return !/[^ \t\f\r\n]/.test(el.ownText) && visibleChildren(el).length === 0;
}

export function isVoidTablePart(el: Node): boolean {
  const d = display(el);
  // A column box carries column styling; it never paints a box of its own here.
  if (d === P.D_TABLE_COLUMN || d === P.D_TABLE_COLUMN_GROUP) return true;
  if (d === P.D_TABLE_ROW) {
    if (el.bgCells) return false;
    for (const c of boxKids(el)) if (display(c) === P.D_TABLE_CELL) return false;
    return true;
  }
  if (isTableRowGroup(d)) {
    // A group whose rows are anonymous has no row elements to find, but the table layout still
    // gives it a box to paint its background in.
    if (el.bgbox.length >= 4) return false;
    for (const c of boxKids(el)) if (display(c) === P.D_TABLE_ROW) return false;
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Intrinsic sizes

const K_ATOMIC = 4; // see inline.ts
const K_ATABLE = 9; // see inline.ts

/**
 * The min- and max-content widths of a list of children: each anonymous inline run sits on a
 * line of its own, and so does each block-level box, so the widest of them wins.
 */
function childrenIntrinsic(kids: Node[], cbW: number): number[] {
  let min = 0;
  let max = 0;
  let run: Node[] = [];
  const flush = () => {
    if (run.length === 0) return;
    const pieces: Piece[] = [];
    for (const c of run) gatherPieces([c], pieces);
    measurePieces(pieces, cbW, false);
    const rmin = piecesMinContent(pieces);
    const rmax = piecesMaxContent(pieces);
    if (rmin > min) min = rmin;
    if (rmax > max) max = rmax;
    run = [];
  };
  for (const c of kids) {
    if (display(c) === P.D_NONE || isOutOfFlow(c)) continue;
    if (isInlineLevel(c) || c.isTextNode) {
      run.push(c);
      continue;
    }
    flush();
    const cmin = intrinsicMinWidth(c, cbW) + marginH(c, cbW);
    const cmax = intrinsicMaxWidth(c, cbW) + marginH(c, cbW);
    if (cmin > min) min = cmin;
    if (cmax > max) max = cmax;
  }
  flush();
  return [min, max];
}

/**
 * True when `el` is inside a table that collapses its borders. `border-collapse` is inherited, so
 * the property on a table part answers for the table it belongs to.
 */
function isCollapse(el: Node): boolean {
  return el.sv[P.P_BORDER_COLLAPSE] === P.BC_COLLAPSE;
}

/**
 * A cell's horizontal padding, plus its borders in the separate model. Under `border-collapse` a
 * cell's borders are drawn on the shared grid lines, half outside the cell, so they don't add to
 * the column width: a column is the cell's content and padding.
 */
function cellPadH(el: Node, cbW: number): number {
  // Padding can't be negative: a calc() that comes out below zero pads by nothing.
  let pad = Math.max(0, zeroIfNaN(len(el, P.P_PADDING_LEFT, cbW)))
    + Math.max(0, zeroIfNaN(len(el, P.P_PADDING_RIGHT, cbW)));
  if (!isCollapse(el)) pad += borderLeft(el) + borderRight(el);
  return pad;
}

/**
 * The padding a cell counts with when the table works out how wide its columns have to be. A
 * percentage padding depends on the cell's width, which is not known yet, so it counts as zero;
 * it is resolved once the cell has a width to resolve it against.
 */
function cellPadIntrinsic(el: Node, cbW: number): number {
  // A percentage padding — alone, or as one term of a calc() — has no width to be a percentage of
  // yet, so it counts as zero, and only the lengths around it count. The whole padding resolves
  // once the cell has the table's width.
  const pad = (p: number): number => {
    const u = el.su[p];
    if (u === P.U_PCT) return 0;
    // Padding can't be negative, so a calc() that comes out below zero pads by nothing.
    if (u === P.U_EXPR) return Math.max(0, zeroIfNaN(exprLength(el, el.sv[p], 0, el.sv[P.P_FONT_SIZE])));
    return Math.max(0, zeroIfNaN(len(el, p, cbW)));
  };
  let total = pad(P.P_PADDING_LEFT) + pad(P.P_PADDING_RIGHT);
  if (!isCollapse(el)) total += borderLeft(el) + borderRight(el);
  return total;
}

/**
 * A cell's specified width as the column's padding box: what the column holds. `halves` is the
 * part of the collapsed grid lines either side of the cell that sits inside its border box, which
 * a border-box width covers and a content-box width sits inside.
 */
function cellSpecW(el: Node, cbW: number, halves: number = 0): number {
  const w = len(el, P.P_WIDTH, cbW);
  if (Number.isNaN(w)) return NaN;
  const pad = cellPadH(el, cbW);
  // A border-box width is at least the padding and borders: a cell's content box can't be
  // negative, so a width smaller than them asks for just them.
  return el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? Math.max(w - halves, pad) : w + pad;
}

/**
 * The halves of the collapsed grid lines that sit inside a cell's border box, left and right of
 * its column span. Zero in the separate model, where a cell's borders are its own.
 */
function cellHalves(model: TableModel, cell: Cell): number {
  if (model.lines === null) return 0;
  return (model.lines.x[cell.col] + model.lines.x[cell.col + cell.colspan]) / 2;
}

/** True when every column a cell covers is collapsed, so the cell has no room at all. */
function noColumnRoom(model: TableModel, cell: Cell): boolean {
  for (let i = cell.col; i < cell.col + cell.colspan; i++) if (!model.colCollapsed[i]) return false;
  return true;
}

/** True when any column a cell covers is collapsed: its width asks for nothing. */
function spansCollapsedColumn(model: TableModel, cell: Cell): boolean {
  for (let i = cell.col; i < cell.col + cell.colspan; i++) if (model.colCollapsed[i]) return true;
  return false;
}

/** True when any row a cell covers is collapsed: its height asks for nothing. */
function spansCollapsedRow(model: TableModel, cell: Cell): boolean {
  for (let r = cell.row; r < cell.row + cell.rowspan; r++) if (model.rowCollapsed[r]) return true;
  return false;
}

/** True when every row a cell covers is collapsed, so the cell has no height at all. */
function noRowRoom(model: TableModel, cell: Cell): boolean {
  for (let r = cell.row; r < cell.row + cell.rowspan; r++) if (!model.rowCollapsed[r]) return false;
  return true;
}

/**
 * True where the element's width is a length: a resolvable px/em/vw/... value, rather than auto,
 * a percentage (which asks for a share of the table instead of naming a width) or one of the
 * intrinsic sizing keywords (which makes the element as wide as its content needs).
 */
function isLengthWidth(el: Node, cbW: number): boolean {
  const u = el.su[P.P_WIDTH];
  if (u === P.U_PCT || u === P.U_AUTO || isIntrinsicSize(u)) return false;
  return Number.isFinite(len(el, P.P_WIDTH, cbW));
}

/**
 * The width a `<col>` or `<colgroup>` gives its column, or NaN where it names none. Only a length
 * is definite: a percentage asks for a share of a table width that its own content hasn't fixed
 * yet, and a calc() is resolved against a percentage basis the column doesn't have. `min-width`
 * alone still names a width (it clamps), but `max-width` alone doesn't. A width of 0 is a column
 * of no width, which the caller takes as auto.
 */
function colSpecW(col: Node, cbW: number): number {
  const definite = (unit: number): boolean =>
    unit !== P.U_PCT && unit !== P.U_EXPR && unit !== P.U_AUTO && !isIntrinsicSize(unit);
  let w = definite(col.su[P.P_WIDTH]) ? len(col, P.P_WIDTH, cbW) : NaN;
  const min = definite(col.su[P.P_MIN_WIDTH]) ? len(col, P.P_MIN_WIDTH, cbW) : NaN;
  const max = definite(col.su[P.P_MAX_WIDTH]) ? len(col, P.P_MAX_WIDTH, cbW) : NaN;
  if (Number.isNaN(w)) w = min;
  if (Number.isNaN(w)) return NaN;
  if (!Number.isNaN(max) && max < w) w = max;
  if (!Number.isNaN(min) && min > w) w = min;
  return w;
}

/**
 * The percentage a width asks for, as a fraction (0.5 for 50%), or NaN where it asks for a length.
 * `calc(50% + 0px)` asks for exactly what `50%` asks for — a share of the table — so a calc() that
 * is a percentage with nothing added counts as one; every other calc() is some other width.
 */
function widthPercent(el: Node): number {
  if (el.su[P.P_WIDTH] === P.U_PCT) return el.sv[P.P_WIDTH] / 100;
  if (el.su[P.P_WIDTH] !== P.U_EXPR) return NaN;
  const id = el.sv[P.P_WIDTH];
  const fontSize = el.sv[P.P_FONT_SIZE];
  const none = exprLength(el, id, 0, fontSize);
  const once = exprLength(el, id, 100, fontSize);
  const twice = exprLength(el, id, 200, fontSize);
  // A share is 0 with no table to be a share of, and grows in step with one. A length added to it,
  // or a min()/max() that stops growing, is a width of its own.
  if (none !== 0 || !(once > 0) || Math.abs(twice - 2 * once) > 0.001) return NaN;
  return once / 100;
}

/**
 * A cell's min- and max-content widths, as the column's padding box. `halves` is the part of the
 * collapsed grid lines either side of the cell that sits inside its border box.
 */
function cellIntrinsic(el: Node, cbW: number, halves: number = 0): number[] {
  const sizes = boxKids(el).length === 0
    ? [0, 0]
    : childrenIntrinsic(visibleChildren(el), cbW);
  let min = sizes[0];
  let max = sizes[1];
  if (boxKids(el).length === 0 && el.ownText !== "") {
    const pieces: Piece[] = [];
    pushText(el, el, el.ownText, pieces);
    measurePieces(pieces, cbW, false);
    min = piecesMinContent(pieces);
    max = piecesMaxContent(pieces);
  }
  // The column holds the cell's padding box: under border-collapse the cell's borders are grid
  // lines half outside it, so they don't count (see cellPadH), and a percentage padding has no
  // width to resolve against yet (cellPadIntrinsic).
  const pad = cellPadIntrinsic(el, cbW);
  const share = widthPercent(el);
  if (!Number.isNaN(share)) {
    // A percentage width asks for that share of the table: the cell needs its own content
    // width divided by the percentage (a 150px cell at 50% makes a 300px table), not a share of
    // whatever containing block happened to be at hand.
    if (share > 0 && max > 0) {
      const preferred = Math.ceil(max / share);
      // A percentage that would need more room than the table has is unresolvable: the cell
      // keeps its content width.
      if (preferred > max && preferred <= cbW) max = preferred;
    }
  } else {
    // The cell's own width is the width it would like; the column adds the padding box around
    // it, and under border-collapse its borders are grid lines outside the column, so they don't
    // count (cellSpecW, not specW). It raises what the column asks for but not the floor under
    // it: an auto-width table still shrinks to the room it has, down to what its cell contents
    // need (CSS 2.1 17.5.2.2).
    const spec = el.sv[P.P_BOX_SIZING] === P.BS_BORDER
      ? len(el, P.P_WIDTH, cbW) - pad - halves : len(el, P.P_WIDTH, cbW);
    if (!Number.isNaN(spec) && spec > max) max = spec;
  }
  return [clampCellW(el, min + pad, cbW, pad, halves), clampCellW(el, max + pad, cbW, pad, halves)];
}

/**
 * Clamps a cell's width by its min/max-width, with `pad` (its padding box) as the box edge.
 * `halves` is the part of the collapsed grid lines inside a border-box width, which a border-box
 * min/max-width covers too.
 */
function clampCellW(el: Node, w: number, cbW: number, pad: number, halves: number = 0): number {
  const adj = el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? -halves : pad;
  const max = len(el, P.P_MAX_WIDTH, cbW);
  const min = len(el, P.P_MIN_WIDTH, cbW);
  if (!Number.isNaN(max) && w > max + adj) w = max + adj;
  if (!Number.isNaN(min) && w < min + adj) w = min + adj;
  return Math.max(w, pad);
}

/**
 * The content of an anonymous cell in flow order: inline runs, block-level boxes, and out-of-flow
 * boxes that only need a static position. It goes through the same split as a block container, so
 * a block inside an inline box splits the inline box open (§9.2.1.1).
 */
function anonymousFlow(content: Node[], w: number) {
  const kids: Node[] = [];
  for (const c of content) if (display(c) !== P.D_NONE) kids.push(c);
  return splitFlow(kids, w, NaN);
}

/** Border-box intrinsic widths of a run of anonymous content. */
function anonymousIntrinsic(content: Node[], cbW: number): number[] {
  let min = 0;
  let max = 0;
  for (const e of anonymousFlow(content, cbW)) {
    if (e.block !== null) {
      // A block in the cell wraps its own text, so it counts with its intrinsic widths rather
      // than as one unbreakable atomic.
      min = Math.max(min, minContentWidth(e.block, cbW) + marginH(e.block, cbW));
      max = Math.max(max, maxContentWidth(e.block, cbW) + marginH(e.block, cbW));
    } else if (e.pieces.length > 0) {
      measurePieces(e.pieces, cbW, false);
      min = Math.max(min, piecesMinContent(e.pieces));
      max = Math.max(max, piecesMaxContent(e.pieces));
    }
  }
  return [min, max];
}

/**
 * The used width of a box floating in an anonymous cell's content: its specified width, or its
 * shrink-to-fit width between its min- and max-content widths, as in a block formatting context.
 */
function anonFloatWidth(b: Node, w: number): number {
  const spec = specW(b, w);
  if (!Number.isNaN(spec)) return isTableDisplay(display(b)) ? tableUsedWidth(b, w, spec) : spec;
  let stf = Math.min(maxContentWidth(b, w), Math.max(0, w - marginH(b, w)));
  const min = minContentWidth(b, w);
  if (stf < min) stf = min;
  return clampW(b, stf, w);
}

/**
 * Lays out a float in an anonymous cell's content at (x, yTop) of the cell's own formatting
 * context, and returns the y of its bottom margin edge. A cell is a block formatting context, so
 * its floats are placed against the cell's edges and only the other floats in the same cell.
 */
function placeAnonFloat(b: Node, x: number, yTop: number, w: number, ctx: FloatCtx): number {
  const side = b.sv[P.P_FLOAT];
  const ml = zeroIfNaN(len(b, P.P_MARGIN_LEFT, w));
  const mr = zeroIfNaN(len(b, P.P_MARGIN_RIGHT, w));
  const mt = zeroIfNaN(len(b, P.P_MARGIN_TOP, w));
  const mb = zeroIfNaN(len(b, P.P_MARGIN_BOTTOM, w));
  const bw = anonFloatWidth(b, w);
  layoutBox(b, w, NaN, bw, NaN, false);
  const fit = floatFitY(ctx, x, x + w, yTop, bw + ml + mr, b.h, side);
  const slot = floatSlot(ctx, fit, Math.max(b.h, 1), x, w);
  const boxX = side === P.FL_RIGHT ? slot[1] - bw - ml - mr : slot[0];
  const bxl = side === P.FL_RIGHT ? slot[1] - mr - bw : slot[0] + ml;
  ctx.boxes.push(new FloatBox(boxX, fit, bw + ml + mr, b.h + mt + mb, side));
  b.x = bxl;
  b.y = fit + mt;
  return fit + mt + b.h + mb;
}

/**
 * Measured height of an anonymous cell's flow at width `w`. When `firstBase` is given, its
 * first entry is the distance from the content top to the baseline of the flow's first line,
 * which is what a cell's own baseline is when its content is anonymous.
 */
function anonymousFlowHeight(content: Node[], w: number, container: Node, firstBase?: number[]): number {
  let h = 0;
  // How far down the floats met so far reach; content goes below them.
  let floatBottom = 0;
  // The margin waiting to be placed: the largest positive and the most negative of the margins
  // that have collapsed together above the next box.
  let pendP = 0;
  let pendN = 0;
  for (const e of anonymousFlow(content, w)) {
    if (e.block !== null) {
      const b = e.block;
      const mt = zeroIfNaN(len(b, P.P_MARGIN_TOP, w));
      const mb = zeroIfNaN(len(b, P.P_MARGIN_BOTTOM, w));
      if (isFloat(b)) {
        // A float's margins never collapse: it sits below the margin above it, and that margin
        // stays for whatever follows.
        layoutBox(b, w, NaN, anonFloatWidth(b, w), NaN, false);
        const bottom = h + pendP + pendN + mt + b.h + mb;
        if (bottom > floatBottom) floatBottom = bottom;
        continue;
      }
      if (floatBottom > h) h = floatBottom;
      layoutBox(b, w, NaN, NaN, NaN, false);
      // The margin above the box is its own top margin collapsed with whatever escaped through
      // the top edge of the boxes inside it (CSS 2.1 8.3.1).
      const mtP = Math.max(0, mt, b.escTopP);
      const mtN = Math.min(0, mt, b.escTopN);
      if (mtP > pendP) pendP = mtP;
      if (mtN < pendN) pendN = mtN;
      if (b.collapsesThrough) {
        // It takes no space of its own, and the margins around it stay adjoining.
        const mbP = Math.max(0, mb, b.escBotP);
        const mbN = Math.min(0, mb, b.escBotN);
        if (mbP > pendP) pendP = mbP;
        if (mbN < pendN) pendN = mbN;
        continue;
      }
      const top = h + pendP + pendN;
      if (firstBase !== undefined && firstBase.length === 0) {
        // A block above the first line pushes its baseline down by the whole box, or by the
        // block's own first baseline when it draws one.
        const inner = firstBaseline(b);
        firstBase.push(top + (inner >= 0 ? inner : b.h));
      }
      h = top + b.h;
      pendP = Math.max(0, mb, b.escBotP);
      pendN = Math.min(0, mb, b.escBotN);
    } else if (e.pieces.length > 0) {
      // A run of nothing but white space makes no line box, so it leaves the margins on either
      // side of it adjoining.
      if (isCollapsibleRun(e.pieces)) continue;
      // Inline content makes an anonymous block box of its own, which takes the margin above it
      // as space and starts the collapsing afresh below.
      if (floatBottom > h) h = floatBottom;
      h += pendP + pendN;
      pendP = 0;
      pendN = 0;
      const base: number[] = [];
      const start = h;
      h += anonymousHeight(e.pieces, w, container, base);
      if (firstBase !== undefined && firstBase.length === 0 && base.length > 0) {
        firstBase.push(start + base[0]);
      }
    }
  }
  // The cell is a formatting context, so the bottom margin of its last block is inside it.
  h += pendP + pendN;
  return h > floatBottom ? h : floatBottom;
}

/**
 * How far above the line's baseline an atomic box reaches: its own baseline, which for an
 * inline-block is its last line's, not its bottom edge.
 */
function atomicAscent(c: Node, w: number): number {
  const a = atomicBaseline(c, w);
  return a < 0 ? 0 : a > c.h ? c.h : a;
}

/**
 * Measured height of inline content: each line's tallest style. `firstBase`, when given, gets
 * the first line's baseline distance from the content top.
 */
function anonymousHeight(pieces: Piece[], w: number, container: Node, firstBase?: number[]): number {
  // An atomic box's width comes from laying it out, so the pieces have to be measured before
  // the lines are broken: an inline-block that doesn't fit moves to the next line.
  measurePieces(pieces, w, true);
  const lines = breakLines(pieces, w);
  const strutA = baselineOffset(container);
  const strutD = lineHeightPx(container) - strutA;
  let total = 0;
  for (const line of lines) {
    let hasContent = false;
    let above = strutA;
    let below = strutD;
    for (const item of line.items) {
      if (item.kind === 0 || item.kind === K_ATOMIC || item.kind === K_ATABLE) hasContent = true;
    }
    if (!hasContent && !line.forced) continue;
    for (const item of line.items) {
      if (item.kind === K_ATABLE) {
        above = Math.max(above, item.asc);
        below = Math.max(below, item.h - item.asc);
      } else if (item.kind === K_ATOMIC) {
        const c = item.style;
        const asc = atomicAscent(c, w);
        above = Math.max(above, asc);
        below = Math.max(below, c.h - asc);
      } else {
        const a = baselineOffset(item.style);
        above = Math.max(above, a);
        below = Math.max(below, lineHeightPx(item.style) - a);
      }
    }
    if (firstBase !== undefined && firstBase.length === 0) firstBase.push(total + above);
    total += above + below;
  }
  return total;
}

// ---------------------------------------------------------------------------
// The grid

class Cell {
  /** The cell element, or null for an anonymous cell. */
  el: Node | null = null;
  /** An anonymous cell's content: the stray content of a row or table. */
  content: Node[] | null = null;
  row = 0;
  col = 0;
  rowspan = 1;
  colspan = 1;
  /** Border-box intrinsic widths. */
  min = 0;
  max = 0;
  /** Measured border-box height, before row spans are resolved. */
  measured = 0;
  /** Distance from the cell's border-box top to its first baseline, 0 when it has none. */
  baseline = 0;
}

class Row {
  el: Node | null = null;
  cells: Cell[] = [];
  group = 0;
}

class TableModel {
  rows: Row[] = [];
  cells: Cell[] = [];
  /** The horizontal border spacing between columns; 0 under the collapsed model. */
  spacingH = 0;
  /** The grid's column count. */
  cols = 0;
  colMin: number[] = [];
  colMax: number[] = [];
  /**
   * True where a length width was specified for the column, by a <col> or by a cell that spans
   * only it. Such a column keeps its width when a spanning cell or the table asks for more room;
   * the room goes to the columns the table is left to size (CSS 2.1 17.5.2.2).
   */
  colFixed: boolean[] = [];
  /**
   * The share of the table's width a column asks for, as a fraction (0.5 for 50%), from a <col>
   * or from a cell that spans only it; NaN for a column with none.
   */
  colPct: number[] = [];
  /** Column constraints from <col>/<colgroup>, one entry per grid column. */
  colEls: Node[] = [];
  captionsTop: Node[] = [];
  captionsBottom: Node[] = [];
  groupEls: Node[] = [];
  /** The element of each row group by group id; null for a group implied by stray rows. */
  groupElOf: (Node | null)[] = [];
  /** The last row index of each row's group, for rowspan=0. */
  groupEnd: number[] = [];
  /** A percentage width on a column or cell makes the table use the available width. */
  hasPercent = false;
  /** The collapsed border model's grid lines, resolved once the grid is known; null otherwise. */
  lines: TableLines | null = null;
  /**
   * Tracks a `visibility: collapse` row or column takes out of the layout: it holds no content and
   * its border spacing goes with it, as CSS 2.1 §17.6.4 asks for a collapsed row or column.
   */
  rowCollapsed: boolean[] = [];
  colCollapsed: boolean[] = [];
}

/** The gutters between and around the tracks that still take space: one more than their count. */
function gapCount(collapsed: boolean[]): number {
  let n = 0;
  for (const c of collapsed) if (!c) n++;
  return n > 0 ? n + 1 : 0;
}

/** CSS 2.1 §17.6.2.1's precedence among border styles: the higher value wins a shared edge. */
function borderStylePrecedence(style: number): number {
  switch (style) {
    case P.BRS_HIDDEN: return 9;
    case P.BRS_DOUBLE: return 8;
    case P.BRS_SOLID: return 7;
    case P.BRS_DASHED: return 6;
    case P.BRS_DOTTED: return 5;
    case P.BRS_RIDGE: return 4;
    case P.BRS_OUTSET: return 3;
    case P.BRS_GROOVE: return 2;
    case P.BRS_INSET: return 1;
    default: return 0;
  }
}

/** The number of gutters a span of columns or rows keeps between its visible tracks. */
function spanGaps(collapsed: boolean[], start: number, span: number): number {
  let n = 0;
  for (let i = start; i < start + span; i++) if (!collapsed[i]) n++;
  return n > 0 ? n - 1 : 0;
}

function attrNumber(el: Node | null, name: string, fallback: number): number {
  if (!(el instanceof Element)) return fallback;
  const v = el.getAttribute(name);
  if (v === null) return fallback;
  const n = parseInt(v, 10);
  return Number.isFinite(n) ? n : fallback;
}

/**
 * White space between table parts generates no boxes. CSS 2.1 §17.2.1 disposes of it as if it
 * were `display: none`, so this holds whatever `white-space` says: a preserved newline between a
 * row's cells must not become an anonymous cell.
 */
export function isIgnorableWhitespace(c: Node): boolean {
  return c.isTextNode && !/[^ \t\f\r\n]/.test(c.ownText);
}

/** White space that collapses, which is the only kind an inline run drops at its edges. */
function isCollapsibleWhitespace(c: Node): boolean {
  if (!isIgnorableWhitespace(c)) return false;
  const ws = c.sv[P.P_WHITE_SPACE];
  return ws === P.W_NORMAL || ws === P.W_NOWRAP || ws === P.W_PRE_LINE;
}

/**
 * Trims collapsible white space from the edges of a run of stray children, and drops a run that is
 * nothing but white space. Preserved white space between two of them stays: it's part of the one
 * anonymous cell they share, as it would be inside a real cell.
 */
function trimStray(kids: Node[]): Node[] {
  let allWhitespace = true;
  for (const k of kids) {
    if (!isIgnorableWhitespace(k)) {
      allWhitespace = false;
      break;
    }
  }
  if (allWhitespace) return [];
  let a = 0;
  let b = kids.length;
  while (a < b && isCollapsibleWhitespace(kids[a])) a++;
  while (b > a && isCollapsibleWhitespace(kids[b - 1])) b--;
  return a === 0 && b === kids.length ? kids : kids.slice(a, b);
}

/** The <col>/<colgroup> elements, expanded to one entry per grid column. */
function collectCols(kids: Node[], model: TableModel): void {
  for (const c of kids) {
    const d = display(c);
    if (d === P.D_TABLE_COLUMN) {
      const span = Math.max(1, attrNumber(c, "span", 1));
      for (let i = 0; i < span; i++) model.colEls.push(c);
    } else if (d === P.D_TABLE_COLUMN_GROUP) {
      const cols = visibleChildren(c).filter((k) => display(k) === P.D_TABLE_COLUMN);
      if (cols.length > 0) {
        for (const k of cols) {
          const span = Math.max(1, attrNumber(k, "span", 1));
          for (let i = 0; i < span; i++) model.colEls.push(k);
        }
      } else {
        const span = Math.max(1, attrNumber(c, "span", 1));
        for (let i = 0; i < span; i++) model.colEls.push(c);
      }
    }
  }
}

/** Splits a row's children into cells and runs of stray content (each an anonymous cell). */
function rowCells(kids: Node[]): Cell[] {
  const cells: Cell[] = [];
  let stray: Node[] = [];
  const flush = () => {
    const content = trimStray(stray);
    stray = [];
    if (content.length === 0) return;
    const cell = new Cell();
    cell.content = content;
    cells.push(cell);
  };
  for (const k of kids) {
    // A column box inside a row generates no box, so it neither paints nor takes a cell.
    const dk = display(k);
    if (dk === P.D_TABLE_COLUMN || dk === P.D_TABLE_COLUMN_GROUP) {
      flush();
      continue;
    }
    if (dk === P.D_TABLE_CELL) {
      flush();
      const cell = new Cell();
      cell.el = k;
      cells.push(cell);
    } else {
      stray.push(k);
    }
  }
  flush();
  return cells;
}

interface RowSource {
  el: Node | null;
  kids: Node[];
  group: number;
}

/** True when a cell covers the column. */
function columnHasCell(model: TableModel, i: number): boolean {
  for (const cell of model.cells) {
    if (cell.col <= i && i < cell.col + cell.colspan) return true;
  }
  return false;
}

function buildModel(table: Node, avail: number, kids: Node[] = visibleChildren(table),
    anon = false): TableModel {
  const model = new TableModel();
  model.spacingH = isCollapse(table) ? 0 : spacingOf(table, P.P_BORDER_SPACING_H, avail);
  collectCols(kids, model);

  // Rows in visual order: header groups first, then the rest, then footer groups. Header and
  // footer groups keep their document order among themselves.
  const headers: RowSource[] = [];
  const middles: RowSource[] = [];
  const footers: RowSource[] = [];
  // Only the first header group is the table's header and only the first footer group its
  // footer; any later ones are laid out where they stand, like a row group of the body.
  let headerSeen = false;
  let footerSeen = false;
  let gid = 0;
  let implicit = false;
  let stray: Node[] = [];
  const startGroup = () => {
    gid++;
    implicit = false;
  };
  const flushStray = (group: number, into: RowSource[]) => {
    const kids = trimStray(stray);
    stray = [];
    if (kids.length === 0) return;
    into.push({ el: null, kids, group });
  };
  const addGroup = (el: Node, into: RowSource[]): void => {
    startGroup();
    model.groupEls.push(el);
    model.groupElOf[gid] = el;
    let kids: Node[] = [];
    const flushKids = () => {
      const run = trimStray(kids);
      kids = [];
      if (run.length === 0) return;
      into.push({ el: null, kids: run, group: gid });
    };
    for (const c of visibleChildren(el)) {
      if (display(c) === P.D_TABLE_ROW) {
        flushKids();
        into.push({ el: c, kids: visibleChildren(c), group: gid });
      } else {
        kids.push(c);
      }
    }
    flushKids();
  };

  for (const c of kids) {
    const d = display(c);
    if (d === P.D_TABLE_CAPTION) {
      flushStray(gid, middles);
      if (c.sv[P.P_CAPTION_SIDE] === P.CS_BOTTOM) model.captionsBottom.push(c);
      else model.captionsTop.push(c);
      continue;
    }
    if (d === P.D_TABLE_COLUMN || d === P.D_TABLE_COLUMN_GROUP) {
      flushStray(gid, middles);
      continue;
    }
    if (d === P.D_TABLE_HEADER_GROUP) {
      flushStray(gid, middles);
      if (headerSeen) addGroup(c, middles);
      else addGroup(c, headers);
      headerSeen = true;
      continue;
    }
    if (d === P.D_TABLE_FOOTER_GROUP) {
      flushStray(gid, middles);
      if (footerSeen) addGroup(c, middles);
      else addGroup(c, footers);
      footerSeen = true;
      continue;
    }
    if (d === P.D_TABLE_ROW_GROUP) {
      flushStray(gid, middles);
      addGroup(c, middles);
      continue;
    }
    if (!implicit) {
      startGroup();
      implicit = true;
    }
    if (d === P.D_TABLE_ROW) {
      flushStray(gid, middles);
      middles.push({ el: c, kids: visibleChildren(c), group: gid });
    } else {
      stray.push(c);
    }
  }
  flushStray(gid, middles);

  const sources = [...headers, ...middles, ...footers];
  const nrows = sources.length;
  // Each row's group ends at the last row of that group (a group's rows are contiguous).
  const endOfGroup: number[] = [];
  for (let r = 0; r < nrows; r++) endOfGroup.push(r);
  for (let r = nrows - 1; r >= 0; r--) {
    if (r + 1 < nrows && sources[r + 1].group === sources[r].group) endOfGroup[r] = endOfGroup[r + 1];
  }
  model.groupEnd = endOfGroup;

  // Place cells into the grid. Occupancy is a flat array (index r * GRID_W + c): a cell's box
  // covers every grid slot its rowspan/colspan spans.
  const GRID_W = 4096;
  const occupied: number[] = [];
  const overlaps = (r: number, c: number, rs: number, cs: number): boolean => {
    for (let rr = r; rr < r + rs; rr++) {
      for (let cc = c; cc < c + cs; cc++) if (occupied[rr * GRID_W + cc] === 1) return true;
    }
    return false;
  };

  // A grid the `<col>` elements declare bounds how far a colspan reaches: a cell that spans past
  // the last declared column spans only the columns that are there, while a cell that starts past
  // it adds one column of its own (a table with no `<col>` elements is sized by its cells, so
  // there is no bound to apply).
  let gridCols = model.colEls.length > 0 ? model.colEls.length : Infinity;
  for (let r = 0; r < nrows; r++) {
    const src = sources[r];
    const row = new Row();
    row.el = src.el;
    row.group = src.group;
    row.cells = rowCells(src.kids);
    let col = 0;
    for (const cell of row.cells) {
      let colspan = Math.max(1, Math.min(1000, attrNumber(cell.el, "colspan", 1)));
      let rowspan = attrNumber(cell.el, "rowspan", 1);
      if (rowspan === 0) rowspan = Math.max(1, endOfGroup[r] - r + 1);
      rowspan = Math.max(1, Math.min(rowspan, nrows - r));
      // A cell starts at the first slot of its row that isn't already taken by a cell spanning
      // down from an earlier row. Its own span may then reach over such a slot: HTML's table
      // model lets the two cells overlap, rather than pushing the cell further right.
      while (overlaps(r, col, 1, 1)) col++;
      if (col >= gridCols) gridCols = col + 1;
      if (colspan > gridCols - col) colspan = gridCols - col;
      for (let rr = r; rr < r + rowspan; rr++) {
        for (let cc = col; cc < col + colspan; cc++) occupied[rr * GRID_W + cc] = 1;
      }
      cell.row = r;
      cell.col = col;
      cell.rowspan = rowspan;
      cell.colspan = colspan;
      model.cells.push(cell);
      col += colspan;
    }
    model.rows.push(row);
  }

  // The grid's column count is the widest row (or the columns the <col> elements declare).
  let cols = model.colEls.length;
  if (Number.isFinite(gridCols)) cols = Math.max(cols, gridCols);
  for (const cell of model.cells) {
    const end = cell.col + cell.colspan;
    if (end > cols) cols = end;
  }
  model.cols = cols;
  for (let i = 0; i < cols; i++) {
    model.colMin.push(0);
    model.colMax.push(0);
    model.colFixed.push(false);
    model.colPct.push(NaN);
  }

  // A `visibility: collapse` row or column keeps no room: its cells paint nothing and the border
  // spacing around it goes too (CSS 2.1 §17.6.4). Visibility is inherited, so a row inside a
  // collapsed row group carries it, and so do that row's cells.
  model.rowCollapsed = model.rows.map((r, idx) => {
    if (r.el === null) return false;
    if (r.el.sv[P.P_VISIBILITY] === P.VIS_COLLAPSE) return true;
    // A row group that collapses takes its rows with it, even a row that sets visibility: visible
    // (css-tables-3's visible tracks: the group is the track that collapsed).
    const g = groupElOf(model, idx);
    return g !== null && g.sv[P.P_VISIBILITY] === P.VIS_COLLAPSE;
  });
  for (let i = 0; i < model.cols; i++) {
    const col = i < model.colEls.length ? model.colEls[i] : null;
    const group = col === null ? null : col.parentElement;
    const byGroup = group !== null && display(group) === P.D_TABLE_COLUMN_GROUP &&
      group.sv[P.P_VISIBILITY] === P.VIS_COLLAPSE;
    model.colCollapsed.push(col !== null && (col.sv[P.P_VISIBILITY] === P.VIS_COLLAPSE || byGroup));
  }
  // The collapsed border model puts a border between the columns rather than inside them, so the
  // grid lines are resolved before the columns' own constraints are: a border-box width on a cell
  // covers the halves of the lines either side of it, which the widths have to leave out.
  if (!anon && isCollapse(table) && model.cols > 0 && model.rows.length > 0) {
    model.lines = resolveBorders(model, table);
  }
  // Column widths from the cells.
  for (const cell of model.cells) {
    let share = NaN;
    if (spansCollapsedColumn(model, cell)) {
      // A cell that spans a collapsed column asks for no width: its content overflows the columns
      // that are left, as a browser clips it (colspan-001's 30px cell in a 20px table).
      cell.min = 0;
      cell.max = 0;
      continue;
    }
    if (cell.el !== null) {
      share = widthPercent(cell.el);
      if (!Number.isNaN(share)) model.hasPercent = true;
      const w = cellIntrinsic(cell.el, avail, cellHalves(model, cell));
      cell.min = w[0];
      cell.max = w[1];
      // A cell that is alone in its column and declares a length width fixes that column: the
      // width it asks for is the column's, and the table's spare room goes elsewhere.
      if (cell.colspan === 1 && isLengthWidth(cell.el, avail)) model.colFixed[cell.col] = true;
    } else {
      const w = anonymousIntrinsic(cell.content!, avail);
      cell.min = w[0];
      cell.max = w[1];
    }
    if (cell.colspan === 1) {
      if (cell.min > model.colMin[cell.col]) model.colMin[cell.col] = cell.min;
      if (cell.max > model.colMax[cell.col]) model.colMax[cell.col] = cell.max;
      // A cell that spans only its column asks for that share of the table's width; the first
      // such cell in a column speaks for it.
      if (!Number.isNaN(share) && Number.isNaN(model.colPct[cell.col])) model.colPct[cell.col] = share;
    }
  }
  // Column widths from <col> and <colgroup>. In the collapsed model a column's declared width
  // covers the cell borders that adjoin it, so the column itself is what remains after half of
  // each of its grid lines.
  // An auto-width table sizes its columns from their contents: a percentage on a <col> has no
  // width to be a share of yet, so it acts as auto (CSS Tables 3, distributing width to columns).
  const autoWide = !anon && (Number.isNaN(specW(table, avail)) || table.su[P.P_WIDTH] === P.U_AUTO);
  for (let i = 0; i < model.colEls.length; i++) {
    const col = model.colEls[i];
    const share = widthPercent(col);
    if (!Number.isNaN(share)) {
      // A percentage in a table with a width of its own is a share of it, like a percentage cell's
      // share. A column no cell reaches is nothing to take a share of, so its percentage says
      // nothing either.
      if (!autoWide && columnHasCell(model, i)) {
        model.hasPercent = true;
        if (Number.isNaN(model.colPct[i])) model.colPct[i] = share;
      }
      continue;
    }
    let spec = colSpecW(col, avail);
    if (Number.isNaN(spec) || spec <= 0) continue;
    // A length width on the column itself fixes it, like a length width on a cell alone in it.
    const u = col.su[P.P_WIDTH];
    if (u !== P.U_PCT && u !== P.U_EXPR && !isIntrinsicSize(u)) model.colFixed[i] = true;
    if (model.lines !== null) spec = Math.max(0, spec - (model.lines.x[i] + model.lines.x[i + 1]) / 2);
    if (spec > model.colMin[i]) model.colMin[i] = spec;
    if (spec > model.colMax[i]) model.colMax[i] = spec;
  }
  // A collapsed column keeps no width, whatever its <col> or cells asked for.
  for (let i = 0; i < model.cols; i++) {
    if (!model.colCollapsed[i]) continue;
    model.colMin[i] = 0;
    model.colMax[i] = 0;
    model.colFixed[i] = false;
    model.colPct[i] = NaN;
  }
  // A declared column past the last cell holds nothing: with no width of its own it isn't part
  // of the table, so its border spacing doesn't widen it (a browser drops such columns).
  let used = model.cols;
  while (used > 0 && model.colMin[used - 1] <= 0 && model.colMax[used - 1] <= 0
      && !columnHasCell(model, used - 1)) {
    used--;
  }
  if (used < model.cols) {
    model.cols = used;
    if (model.colEls.length > used) model.colEls.length = used;
    // The gap counts walk this array, and a trimmed column is no track: leaving it in would put
    // gutters beside columns the table doesn't have (css-tables' col-definite-size-001).
    if (model.colCollapsed.length > used) model.colCollapsed.length = used;
  }
  resolveSpans(model);
  return model;
}

/** Widens the columns a spanning cell covers until they hold the cell's intrinsic widths. */
function resolveSpans(model: TableModel): void {
  const spans = model.cells.filter((c) => c.colspan > 1);
  spans.sort((a, b) => a.colspan - b.colspan);
  for (let pass = 0; pass < 4; pass++) {
    let changed = false;
    for (const cell of spans) {
      const add = (arr: number[], need: number): boolean => {
        let sum = 0;
        for (let i = cell.col; i < cell.col + cell.colspan; i++) sum += arr[i];
        // Under collapsed borders the grid lines between the spanned columns take part of the
        // cell's width, so they count towards what it will hold. In the separated model it is
        // the border spacing between them: a three-column cell spans two gutters as well.
        if (model.lines !== null) {
          for (let i = cell.col + 1; i < cell.col + cell.colspan; i++) sum += model.lines.x[i];
        } else {
          sum += model.spacingH * spanGaps(model.colCollapsed, cell.col, cell.colspan);
        }
        const deficit = need - sum;
        if (deficit <= 0.0001) return false;
        // The room a spanning cell needs goes to the columns the table is left to size: a column
        // with a specified width keeps it (CSS 2.1 17.5.2.2). When every column it spans is
        // fixed, they all grow.
        let share = 0;
        for (let i = cell.col; i < cell.col + cell.colspan; i++) if (!model.colFixed[i]) share++;
        const grow = share > 0 ? share : cell.colspan;
        for (let i = cell.col; i < cell.col + cell.colspan; i++) {
          if (share > 0 && model.colFixed[i]) continue;
          arr[i] += deficit / grow;
        }
        return true;
      };
      if (add(model.colMin, cell.min)) changed = true;
      if (add(model.colMax, cell.max)) changed = true;
    }
    if (!changed) break;
  }
  for (let i = 0; i < model.cols; i++) if (model.colMax[i] < model.colMin[i]) model.colMax[i] = model.colMin[i];
}

function sumOf(arr: number[]): number {
  let s = 0;
  for (const v of arr) s += v;
  return s;
}

// ---------------------------------------------------------------------------
// Collapsed borders (CSS 2.1 §17.6.2)

// A border side, in CSS's top, right, bottom, left order.
const SIDE_TOP = 0;
const SIDE_RIGHT = 1;
const SIDE_BOTTOM = 2;
const SIDE_LEFT = 3;

// Where a border comes from, for conflict resolution: lower wins a tie.
const RANK_CELL = 0;
const RANK_ROW = 1;
const RANK_ROWGROUP = 2;
const RANK_COL = 3;
const RANK_COLGROUP = 4;
const RANK_TABLE = 5;

function sideWidthProp(side: number): number {
  if (side === SIDE_TOP) return P.P_BORDER_TOP_WIDTH;
  if (side === SIDE_RIGHT) return P.P_BORDER_RIGHT_WIDTH;
  if (side === SIDE_BOTTOM) return P.P_BORDER_BOTTOM_WIDTH;
  return P.P_BORDER_LEFT_WIDTH;
}

function sideColorProp(side: number): number {
  if (side === SIDE_TOP) return P.P_BORDER_TOP_COLOR;
  if (side === SIDE_RIGHT) return P.P_BORDER_RIGHT_COLOR;
  if (side === SIDE_BOTTOM) return P.P_BORDER_BOTTOM_COLOR;
  return P.P_BORDER_LEFT_COLOR;
}

function sideStyleProp(side: number): number {
  if (side === SIDE_TOP) return P.P_BORDER_TOP_STYLE;
  if (side === SIDE_RIGHT) return P.P_BORDER_RIGHT_STYLE;
  if (side === SIDE_BOTTOM) return P.P_BORDER_BOTTOM_STYLE;
  return P.P_BORDER_LEFT_STYLE;
}

/** A border width as it's resolved: the device pixels a side actually takes up. */
function borderWidthOf(el: Node, side: number): number {
  return borderPx(el.sv[sideWidthProp(side)]);
}

function borderColorOf(el: Node, side: number): number {
  const c = el.sv[sideColorProp(side)];
  return c < 0 ? el.sv[P.P_COLOR] : c;
}

/**
 * How strongly a style claims a contested border, in CSS 2.1's order (§17.6.2.1): a double border
 * outranks a solid one, a solid a dashed, and so on down to `inset`. `none` never wins, and
 * `hidden` is handled ahead of every width.
 */
const STYLE_RANK: number[] = [
  0, // none
  9, // hidden
  7, // solid
  5, // dotted
  6, // dashed
  8, // double
  2, // groove
  4, // ridge
  1, // inset
  3, // outset
];

/**
 * The border that wins a conflict. A `hidden` border beats any other outright; then a wider border
 * beats a narrower one, then a stronger style wins, then an earlier source in CSS's order (a cell
 * over a row, a row over a row group, a column over a column group, and the table last), and
 * finally the leftmost (or topmost) border among equals.
 */
class BorderWin {
  taken = false;
  hidden = false;
  w = 0;
  style = 0;
  rank = 99;
  pos = 1e9;
  color = 0;
  /** Whether an offer of this border would win here. */
  wins(hidden: boolean, w: number, style: number, rank: number, pos: number): boolean {
    if (!this.taken) return true;
    if (hidden || this.hidden) {
      if (hidden !== this.hidden) return hidden;
      return rank < this.rank || (rank === this.rank && pos < this.pos);
    }
    if (w !== this.w) return w > this.w;
    const s = STYLE_RANK[style];
    const t = STYLE_RANK[this.style];
    if (s !== t) return s > t;
    return rank < this.rank || (rank === this.rank && pos < this.pos);
  }
  offer(w: number, style: number, rank: number, pos: number, color: number): void {
    if (style === P.BRS_NONE) return;
    const hidden = style === P.BRS_HIDDEN;
    if (!this.wins(hidden, w, style, rank, pos)) return;
    this.taken = true;
    this.hidden = hidden;
    this.w = hidden ? 0 : w;
    this.style = style;
    this.rank = rank;
    this.pos = pos;
    this.color = hidden ? 0 : color;
  }
  /** Folds an already-resolved segment (or line) into this one. */
  merge(o: BorderWin): void {
    if (!o.taken) return;
    if (!this.wins(o.hidden, o.w, o.style, o.rank, o.pos)) return;
    this.taken = true;
    this.hidden = o.hidden;
    this.w = o.w;
    this.style = o.style;
    this.rank = o.rank;
    this.pos = o.pos;
    this.color = o.color;
  }
}

/** The grid lines of a collapsing table: their widths and colors, and each segment's winner. */
class TableLines {
  /** Width of each vertical line, left to right (one per column edge). */
  x: number[] = [];
  /** Width of each horizontal line, top to bottom (one per row edge). */
  y: number[] = [];
  cx: number[] = [];
  cy: number[] = [];
  /** The winning color and width of each vertical segment, indexed row * (cols + 1) + line. */
  segXc: number[] = [];
  segXw: number[] = [];
  /** The winning style of each vertical segment. */
  segXs: number[] = [];
  /** The winning color and width of each horizontal segment, indexed line * cols + column. */
  segYc: number[] = [];
  segYw: number[] = [];
  /** The winning style of each horizontal segment. */
  segYs: number[] = [];
}

function offerSide(win: BorderWin, el: Node | null, side: number, rank: number, pos: number): void {
  if (el === null) return;
  win.offer(borderWidthOf(el, side), el.sv[sideStyleProp(side)], rank, pos, borderColorOf(el, side));
}

/** The `<colgroup>` a `<col>` styles, when it has one (an expanded group is its own column). */
function colGroupOf(col: Node): Node | null {
  const p = col.parentElement;
  return p !== null && display(p) === P.D_TABLE_COLUMN_GROUP ? p : null;
}

/**
 * Resolves the collapsed borders of every grid line. Borders of cells, rows, row groups, columns,
 * column groups and the table all compete for each segment of a line (§17.6.2.1); the widest
 * wins, and among equals the nearest element and then the leftmost or topmost border.
 */
function resolveBorders(model: TableModel, table: Node): TableLines {
  const lines = new TableLines();
  const cols = model.cols;
  const rows = model.rows.length;
  for (let j = 0; j <= cols; j++) {
    lines.x.push(0);
    lines.cx.push(0);
  }
  for (let i = 0; i <= rows; i++) {
    lines.y.push(0);
    lines.cy.push(0);
  }
  for (let i = 0; i < rows * (cols + 1); i++) {
    lines.segXc.push(0);
    lines.segXw.push(0);
    lines.segXs.push(P.BRS_NONE);
  }
  for (let i = 0; i < (rows + 1) * cols; i++) {
    lines.segYc.push(0);
    lines.segYw.push(0);
    lines.segYs.push(P.BRS_NONE);
  }
  // Which cell covers each grid slot, by index into model.cells (-1 for none).
  const grid: number[] = [];
  for (let i = 0; i < rows * cols; i++) grid.push(-1);
  for (let k = 0; k < model.cells.length; k++) {
    const cell = model.cells[k];
    for (let r = cell.row; r < cell.row + cell.rowspan; r++) {
      for (let c = cell.col; c < cell.col + cell.colspan; c++) grid[r * cols + c] = k;
    }
  }
  // Where a cell spans across a grid line, that stretch of the line has no border: it lies inside
  // the cell. Overlapping cells (HTML lets a colspan reach over a rowspan) make the slot grid
  // ambiguous, so these are marked from the cells themselves.
  const spansX: boolean[] = [];
  const spansY: boolean[] = [];
  for (let i = 0; i < rows * (cols + 1); i++) spansX.push(false);
  for (let i = 0; i < (rows + 1) * cols; i++) spansY.push(false);
  for (const cell of model.cells) {
    for (let r = cell.row; r < cell.row + cell.rowspan; r++) {
      for (let j = cell.col + 1; j < cell.col + cell.colspan; j++) spansX[r * (cols + 1) + j] = true;
    }
    for (let i = cell.row + 1; i < cell.row + cell.rowspan; i++) {
      for (let c = cell.col; c < cell.col + cell.colspan; c++) spansY[i * cols + c] = true;
    }
  }
  const cellAt = (r: number, c: number): Cell | null => {
    if (r < 0 || r >= rows || c < 0 || c >= cols) return null;
    const k = grid[r * cols + c];
    return k < 0 ? null : model.cells[k];
  };
  const groupFirst = (r: number): boolean => r === 0 || model.rows[r - 1].group !== model.rows[r].group;
  const groupLast = (r: number): boolean => r === rows - 1 || model.rows[r + 1].group !== model.rows[r].group;

  // Vertical lines: cell sides, then the ends of rows and row groups, the columns' own borders,
  // and the table's at the outer edges. A cell that spans across the line covers that stretch of
  // it: no border there belongs to it, and a row's or column's border underneath must not show
  // through (css-tables-3 §border-collapsing).
  for (let j = 0; j <= cols; j++) {
    const line = new BorderWin();
    for (let r = 0; r < rows; r++) {
      const seg = new BorderWin();
      if (j > 0 && j < cols && spansX[r * (cols + 1) + j]) {
        lines.segXw[r * (cols + 1) + j] = 0;
        lines.segXc[r * (cols + 1) + j] = 0;
        lines.segXs[r * (cols + 1) + j] = P.BRS_NONE;
        continue;
      }
      const left = cellAt(r, j - 1);
      const right = cellAt(r, j);
      if (left !== null) offerSide(seg, left.el, SIDE_RIGHT, RANK_CELL, left.col);
      if (right !== null) offerSide(seg, right.el, SIDE_LEFT, RANK_CELL, right.col);
      const rowEl = model.rows[r].el;
      const groupEl = groupElOf(model, r);
      if (j === 0) {
        offerSide(seg, rowEl, SIDE_LEFT, RANK_ROW, r);
        offerSide(seg, groupEl, SIDE_LEFT, RANK_ROWGROUP, r);
      }
      if (j === cols) {
        offerSide(seg, rowEl, SIDE_RIGHT, RANK_ROW, r);
        offerSide(seg, groupEl, SIDE_RIGHT, RANK_ROWGROUP, r);
      }
      // A column box (or group) styles only the columns it declares; the rest have none.
      if (j > 0) {
        const col = j - 1 < model.colEls.length ? model.colEls[j - 1] : null;
        offerSide(seg, col, SIDE_RIGHT, RANK_COL, j - 1);
        offerSide(seg, col === null ? null : colGroupOf(col), SIDE_RIGHT, RANK_COLGROUP, j - 1);
      }
      if (j < cols) {
        const col = j < model.colEls.length ? model.colEls[j] : null;
        offerSide(seg, col, SIDE_LEFT, RANK_COL, j);
        offerSide(seg, col === null ? null : colGroupOf(col), SIDE_LEFT, RANK_COLGROUP, j);
      }
      if (j === 0) offerSide(seg, table, SIDE_LEFT, RANK_TABLE, 0);
      if (j === cols) offerSide(seg, table, SIDE_RIGHT, RANK_TABLE, 0);
      lines.segXw[r * (cols + 1) + j] = seg.w;
      lines.segXc[r * (cols + 1) + j] = seg.w > 0 ? seg.color : 0;
      lines.segXs[r * (cols + 1) + j] = seg.w > 0 ? seg.style : P.BRS_NONE;
      line.merge(seg);
      if (seg.w > lines.x[j]) lines.x[j] = seg.w;
    }
    lines.cx[j] = line.w > 0 ? line.color : 0;
  }

  // Horizontal lines: the cells above and below (the one above wins a tie, as the topmost), then
  // the rows and row groups they end, and the table's top and bottom edges.
  for (let i = 0; i <= rows; i++) {
    const line = new BorderWin();
    for (let c = 0; c < cols; c++) {
      const seg = new BorderWin();
      if (i > 0 && i < rows && spansY[i * cols + c]) {
        lines.segYw[i * cols + c] = 0;
        lines.segYc[i * cols + c] = 0;
        lines.segYs[i * cols + c] = P.BRS_NONE;
        continue;
      }
      const below = cellAt(i, c);
      const above = cellAt(i - 1, c);
      if (below !== null) offerSide(seg, below.el, SIDE_TOP, RANK_CELL, i);
      if (above !== null && above.row + above.rowspan === i) offerSide(seg, above.el, SIDE_BOTTOM, RANK_CELL, i - 1);
      if (i < rows) offerSide(seg, model.rows[i].el, SIDE_TOP, RANK_ROW, i);
      if (i > 0) offerSide(seg, model.rows[i - 1].el, SIDE_BOTTOM, RANK_ROW, i - 1);
      if (i < rows && groupFirst(i)) offerSide(seg, groupElOf(model, i), SIDE_TOP, RANK_ROWGROUP, i);
      if (i > 0 && groupLast(i - 1)) offerSide(seg, groupElOf(model, i - 1), SIDE_BOTTOM, RANK_ROWGROUP, i - 1);
      if (i === 0) offerSide(seg, table, SIDE_TOP, RANK_TABLE, 0);
      if (i === rows) offerSide(seg, table, SIDE_BOTTOM, RANK_TABLE, 0);
      // A column's box runs the table's height, so its top and bottom borders join the conflict on
      // the table's own top and bottom lines.
      const col = c < model.colEls.length ? model.colEls[c] : null;
      if (i === 0) {
        offerSide(seg, col, SIDE_TOP, RANK_COL, c);
        offerSide(seg, col === null ? null : colGroupOf(col), SIDE_TOP, RANK_COLGROUP, c);
      }
      if (i === rows) {
        offerSide(seg, col, SIDE_BOTTOM, RANK_COL, c);
        offerSide(seg, col === null ? null : colGroupOf(col), SIDE_BOTTOM, RANK_COLGROUP, c);
      }
      lines.segYw[i * cols + c] = seg.w;
      lines.segYc[i * cols + c] = seg.w > 0 ? seg.color : 0;
      lines.segYs[i * cols + c] = seg.w > 0 ? seg.style : P.BRS_NONE;
      line.merge(seg);
      if (seg.w > lines.y[i]) lines.y[i] = seg.w;
    }
    lines.cy[i] = line.w > 0 ? line.color : 0;
  }
  return lines;
}

function groupElOf(model: TableModel, r: number): Node | null {
  const g = model.rows[r].group;
  const el = g < model.groupElOf.length ? model.groupElOf[g] : null;
  return el === undefined ? null : el;
}

/**
 * The borders a collapsing table box itself uses: half of each outer grid line, which is the part
 * the table's own box and background reach (its content box starts at the line's centre). The
 * table paints the whole grid itself afterwards; these widths only size the box.
 */
export function applyCollapsedBorders(el: Node, cbW: number): void {
  const model = buildModel(el, Math.max(0, cbW - padH(el, cbW)));
  const rows = model.rows.length;
  const cols = model.cols;
  // A table under border-collapse has no padding, whether or not it has any cells yet: the grid
  // lines take its place.
  el.bpad = [0, 0, 0, 0];
  const lines = model.lines;
  // A table with no cells has no grid for its borders to collapse into, and so no border box of
  // its own: its width and height are zero (`tbody-height-redistribution` #one).
  if (lines === null || cols === 0) {
    el.bw = [0, 0, 0, 0];
    el.bc = [0, 0, 0, 0];
    return;
  }
  el.bw = [lines.y[0] / 2, lines.x[cols] / 2, lines.y[rows] / 2, lines.x[0] / 2];
  el.bc = [lines.cy[0], lines.cx[cols], lines.cy[rows], lines.cx[0]];
}

/** Gives the rows, row groups and cells of a collapsing table the grid-line widths they occupy. */
function applyCellBorders(model: TableModel, table: Node, lines: TableLines | null): void {
  const cols = model.cols;
  for (const r of model.rows) {
    if (r.el === null) continue;
    r.el.bw = lines === null ? [] : [0, 0, 0, 0];
    r.el.bc = lines === null ? [] : [0, 0, 0, 0];
  }
  for (const g of model.groupEls) {
    g.bw = lines === null ? [] : [0, 0, 0, 0];
    g.bc = lines === null ? [] : [0, 0, 0, 0];
  }
  for (const cell of model.cells) {
    const c = cell.el;
    if (c === null) continue;
    if (lines === null) {
      c.bw = [];
      c.bc = [];
      continue;
    }
    const leftLine = cell.col;
    const rightLine = cell.col + cell.colspan;
    const topLine = cell.row;
    const bottomLine = cell.row + cell.rowspan;
    // Each side takes the width of the segment that meets it, not the widest one on that grid
    // line: the halves a cell's content sits inside are its own edges' winners.
    c.bw = [
      lines.segYw[topLine * cols + cell.col] / 2,
      lines.segXw[cell.row * (cols + 1) + rightLine] / 2,
      lines.segYw[bottomLine * cols + cell.col] / 2,
      lines.segXw[cell.row * (cols + 1) + leftLine] / 2,
    ];
    c.bc = [
      lines.segYc[topLine * cols + cell.col],
      lines.segXc[cell.row * (cols + 1) + rightLine],
      lines.segYc[bottomLine * cols + cell.col],
      lines.segXc[cell.row * (cols + 1) + leftLine],
    ];
  }
  // The table's own halves were set before its width was known; keep them in step with the model
  // this layout used (the grid is the same either way, but an anonymous table has no element).
  if (lines !== null && cols > 0 && table.bw.length > 0) {
    const rows = model.rows.length;
    table.bw = [lines.y[0] / 2, lines.x[cols] / 2, lines.y[rows] / 2, lines.x[0] / 2];
    table.bc = [lines.cy[0], lines.cx[cols], lines.cy[rows], lines.cx[0]];
  }
}

/**
 * Used column widths for a grid of `target` px (the column widths, without spacing). `tableW` is
 * the table's content width, which a percentage column's share is resolved against.
 */
function autoColumnWidths(model: TableModel, target: number, tableW: number): number[] {
  const n = model.cols;
  const widths: number[] = [];
  if (n === 0) return widths;
  // A percentage column is that share of the table's width and takes none of the room left over:
  // that goes to the columns the table sizes (CSS 2.1 17.5.2.2). The columns the table sizes from
  // their content keep the room their minimum needs first, so a share of the whole table cannot
  // push the table past its width: a 100% column beside a 5px one takes 95px of a 100px table, as
  // Chrome resolves it. The share is still a floor for the column's own content.
  let reserve = 0;
  for (let i = 0; i < n; i++) {
    if (Number.isNaN(model.colPct[i]) || model.colFixed[i]) continue;
    reserve += model.colMin[i];
  }
  let left = target - reserve;
  let taken = 0;
  for (let i = 0; i < n; i++) {
    const pct = model.colPct[i];
    if (Number.isNaN(pct)) {
      widths.push(NaN);
      continue;
    }
    const share = Math.max(model.colMin[i], Math.min(pct * tableW, Math.max(0, left)));
    left -= share;
    let w = share;
    if (model.lines !== null) w = Math.max(0, w - (model.lines.x[i] + model.lines.x[i + 1]) / 2);
    widths.push(w);
    taken += w;
  }
  // A column the table sizes is one without a percentage; the widths themselves are filled in below.
  const open = (i: number): boolean => Number.isNaN(model.colPct[i]);
  const rest = target - taken;
  let sumMin = 0;
  let sumMax = 0;
  let count = 0;
  let fixed = 0;
  for (let i = 0; i < n; i++) {
    if (!open(i)) continue;
    sumMin += model.colMin[i];
    sumMax += model.colMax[i];
    count++;
    if (model.colFixed[i]) fixed++;
  }
  if (count === 0) return widths;
  if (rest <= sumMin) {
    for (let i = 0; i < n; i++) if (open(i)) widths[i] = model.colMin[i];
    return widths;
  }
  if (rest >= sumMax) {
    const extra = rest - sumMax;
    for (let i = 0; i < n; i++) if (open(i)) widths[i] = model.colMax[i];
    // The room the table has to spare goes to the columns the table sizes, not to the ones with a
    // specified width: a 5px column stays 5px while the rest of a wider table gives way. Among
    // those, grow in proportion to the preferred widths, so a wide column stays wide; columns
    // with no preferred width share equally. With every column fixed, they all grow.
    let weight = 0;
    for (let i = 0; i < n; i++) if (open(i) && !model.colFixed[i]) weight += model.colMax[i];
    let growing = count - fixed;
    if (growing === 0) {
      for (let i = 0; i < n; i++) if (open(i)) weight += model.colMax[i];
      growing = count;
    }
    for (let i = 0; i < n; i++) {
      if (!open(i)) continue;
      if (growing !== count && model.colFixed[i]) continue;
      widths[i] += weight > 0 ? (extra * model.colMax[i]) / weight : extra / growing;
    }
    return widths;
  }
  const factor = (rest - sumMin) / (sumMax - sumMin);
  for (let i = 0; i < n; i++) {
    if (open(i)) widths[i] = model.colMin[i] + (model.colMax[i] - model.colMin[i]) * factor;
  }
  return widths;
}

/**
 * Column widths for table-layout: fixed, from the columns and the first row.
 *
 * The columns share the table's space as *extents*: a column's extent is its width plus the half
 * of each adjoining grid line that sits inside it, so under `border-collapse` a column between
 * wide borders is wider than its cells' content. A specified width declares the extent, the
 * remaining space is split equally between the columns left auto, and the width is the extent less
 * those line halves. With separate borders the halves are all zero and this is the usual rule.
 */
function fixedColumnWidths(model: TableModel, target: number): number[] {
  const n = model.cols;
  const half: number[] = [];
  let halves = 0;
  for (let i = 0; i < n; i++) {
    const h = model.lines !== null && i + 1 < model.lines.x.length
      ? (model.lines.x[i] + model.lines.x[i + 1]) / 2 : 0;
    half.push(h);
    halves += h;
  }
  // `target` is the space the widths share, so the extents share it plus the line halves.
  const budget = target + halves;
  const declared: number[] = []; // declared extents, NaN for a column the table sizes
  const pct: boolean[] = []; // the column's width came from a percentage
  for (let i = 0; i < n; i++) {
    declared.push(NaN);
    pct.push(false);
  }
  // A percentage width is a share of the space the columns share (CSS 2.1 §17.5.2.1): the table's
  // content width less the border spacing, but with the collapsed grid lines still in it, since
  // they belong half to each column rather than sitting in gaps between them.
  for (let i = 0; i < model.colEls.length; i++) {
    const col = model.colEls[i];
    const share = widthPercent(col);
    // A calc() width on a <col> is auto here too: fixed layout shares the table's width out.
    const spec = Number.isNaN(share) ? colSpecW(col, budget) : share * budget;
    if (Number.isNaN(spec)) continue;
    declared[i] = spec;
    pct[i] = !Number.isNaN(share);
  }
  if (model.rows.length > 0) {
    for (const cell of model.rows[0].cells) {
      if (cell.el === null) continue;
      // Under border-collapse the cells' borders are grid lines outside the column, so a declared
      // width is the column's content and padding (see cellSpecW) and the column's extent adds the
      // halves of the lines either side: a border-box width covers those halves itself.
      let halves = 0;
      for (let i = cell.col; i < cell.col + cell.colspan; i++) halves += half[i];
      const spec = cellSpecW(cell.el, budget, halves);
      if (Number.isNaN(spec)) continue;
      if (cell.colspan === 1) {
        // A `<col>` width comes first; the first row's cell only fills in what it left out.
        if (Number.isNaN(declared[cell.col])) {
          declared[cell.col] = spec + half[cell.col];
          pct[cell.col] = !Number.isNaN(widthPercent(cell.el));
        }
      } else if (spec > 0) {
        // A specified width on a spanning cell is shared by the columns it covers.
        const share = spec / cell.colspan;
        for (let i = cell.col; i < cell.col + cell.colspan; i++) {
          if (Number.isNaN(declared[i])) declared[i] = share + half[i];
        }
      }
    }
  }
  let used = 0;
  let auto = 0;
  for (let i = 0; i < n; i++) {
    if (Number.isNaN(declared[i])) auto++;
    else used += declared[i];
  }
  const extra = Math.max(0, budget - used);
  const widths: number[] = [];
  for (let i = 0; i < n; i++) {
    if (!Number.isNaN(declared[i])) widths.push(Math.max(0, declared[i] - half[i]));
    else widths.push(auto > 0 ? Math.max(0, extra / auto - half[i]) : 0);
  }
  if (auto === 0 && extra > 0 && n > 0) {
    // With no auto columns the extra goes to the columns with a length width, in proportion to
    // it: a percentage column keeps the share it asked for (CSS Tables 3, distributing width to
    // columns). With nothing but percentages, the columns share it equally.
    let weight = 0;
    for (let i = 0; i < n; i++) if (!pct[i]) weight += declared[i];
    for (let i = 0; i < n; i++) {
      if (weight > 0) {
        if (!pct[i]) widths[i] += (extra * declared[i]) / weight;
      } else {
        widths[i] += extra / n;
      }
    }
  }
  return widths;
}

function spacingOf(el: Node, p: number, base: number): number {
  const v = len(el, p, base);
  return Number.isNaN(v) ? 0 : v;
}

/** A table's horizontal padding, without the borders (padding-box edges are its content box's). */
function tablePadH(el: Node, cbW: number): number {
  return zeroIfNaN(len(el, P.P_PADDING_LEFT, cbW)) + zeroIfNaN(len(el, P.P_PADDING_RIGHT, cbW));
}

/**
 * The table's border-box width when its width is auto (shrink to fit). In the collapsed model the
 * border box is the columns plus the full width of every grid line.
 */
/** The table's border-box width when its width is auto (shrink to fit). */
export function tableShrinkWidth(el: Node, cbW: number, avail: number): number {
  const innerAvail = Math.max(0, avail - padH(el, cbW));
  const model = buildModel(el, innerAvail);
  const collapse = isCollapse(el);
  if (collapse) {
    // With no cells there is no grid, so no line and no border spacing takes any width.
    if (model.cols === 0) return clampW(el, withCaption(el, cbW, tablePadH(el, cbW), innerAvail), cbW);
    const lines = model.lines;
    const lineX = lines === null ? 0 : sumOf(lines.x);
    // The content box holds the columns and the inner halves of the outer lines.
    const innerH = lines === null ? 0 : lineX - lines.x[0] / 2 - lines.x[model.cols] / 2;
    let target = Math.max(0, innerAvail - innerH);
    if (!model.hasPercent) {
      target = Math.max(sumOf(model.colMin), Math.min(sumOf(model.colMax), target));
    }
    let total = lineX;
    for (const w of autoColumnWidths(model, target, innerAvail)) total += w;
    // A max-width caps the box, but not below what the columns must hold (CSS 2.1 17.5.2.2).
    const floor = withCaption(el, cbW, sumOf(model.colMin) + lineX + tablePadH(el, cbW), 0);
    return Math.max(clampW(el, withCaption(el, cbW, total + tablePadH(el, cbW), innerAvail), cbW), floor);
  }
  const gap = spacingOf(el, P.P_BORDER_SPACING_H, innerAvail);
  // The gutters are the ones between and around the columns: with no columns there are none.
  const gaps = gap * gapCount(model.colCollapsed);
  // An auto-width table shrinks to its preferred width, between its min and max content. A
  // percentage column (or cell) width instead makes it use the available width.
  let target = Math.max(0, innerAvail - gaps);
  if (!model.hasPercent) {
    const sumMin = sumOf(model.colMin);
    const sumMax = sumOf(model.colMax);
    target = Math.max(sumMin, Math.min(sumMax, target));
  }
  let total = gaps;
  for (const w of autoColumnWidths(model, target, innerAvail)) total += w;
  // A max-width caps the box, but not below what the columns must hold (CSS 2.1 17.5.2.2).
  const floor = withCaption(el, cbW, sumOf(model.colMin) + gaps + padH(el, cbW), 0);
  return Math.max(clampW(el, withCaption(el, cbW, total + padH(el, cbW), innerAvail), cbW), floor);
}

/** The table's border-box width: the wider of its grid and the captions beside it (CSS 2.1 17.4). */
function withCaption(el: Node, cbW: number, grid: number, avail: number): number {
  const cap = captionWidth(el, cbW, avail);
  return cap > grid ? cap : grid;
}

/**
 * The width a table's captions ask of the wrapper around the table and them (CSS 2.1 17.4): a
 * caption of its own width keeps it, and an auto-width one takes what `avail` leaves, within its
 * min and max content widths.
 */
function captionWidth(el: Node, cbW: number, avail: number): number {
  let w = 0;
  for (const c of visibleChildren(el)) {
    if (display(c) !== P.D_TABLE_CAPTION) continue;
    const spec = specW(c, cbW);
    const cw = Number.isNaN(spec) ? Math.max(minContentWidth(c, cbW), Math.min(maxContentWidth(c, cbW), avail))
      : spec;
    if (cw > w) w = cw;
  }
  return w;
}

/**
 * The border-box width of a table whose width is not auto: a table is never narrower than its
 * cells need, so a specified width is a floor under the grid rather than a cap on it (CSS 2.1
 * 17.5.2.2). Fixed table layout takes the width as given for distributing the extra space, but the
 * declared columns and the border spacing still add up to a floor under it (CSS 2.1 17.5.2.1).
 */
export function tableUsedWidth(el: Node, cbW: number, spec: number): number {
  const pad = isCollapse(el) ? tablePadH(el, cbW) : padH(el, cbW);
  const innerAvail = Math.max(0, spec - pad);
  if (el.sv[P.P_TABLE_LAYOUT] === P.TL_FIXED) {
    const model = buildModel(el, innerAvail);
    const lines = model.lines;
    if (lines !== null) {
      const lineX = model.cols === 0 ? 0 : sumOf(lines.x);
      // Under border-collapse the border box holds the full width of every grid line: the table's
      // own border is the outer half of the outer lines, and its content box the inner half, so a
      // specified width sizes that box and the columns get what the lines leave of it.
      const target = Math.max(0, innerAvail - lineX);
      let total = lineX;
      for (const w of fixedColumnWidths(model, target)) total += w;
      return clampW(el, withCaption(el, cbW, Math.max(spec, total + tablePadH(el, cbW)), innerAvail), cbW);
    }
    const gaps = model.cols > 0 ? spacingOf(el, P.P_BORDER_SPACING_H, innerAvail) * (model.cols + 1) : 0;
    const target = Math.max(0, innerAvail - gaps);
    let total = gaps;
    for (const w of fixedColumnWidths(model, target)) total += w;
    return clampW(el, withCaption(el, cbW, Math.max(spec, total + padH(el, cbW)), innerAvail), cbW);
  }
  // Percentages inside a table resolve against its own width, so the cells are measured against
  // the width the table asks for; one that has to grow is measured again at its new width.
  const need = tableRunContentWidth(el, visibleChildren(el), innerAvail, true) + pad;
  if (need <= spec) return spec;
  const grown = tableRunContentWidth(el, visibleChildren(el), need - pad, true) + pad;
  return grown > need ? grown : need;
}

/** The table's max-content (preferred) border-box width, for shrink-to-fit ancestors. */
export function tableMaxContentWidth(el: Node, cbW: number): number {
  const inner = Math.max(0, cbW - padH(el, cbW));
  const model = buildModel(el, inner);
  if (model.lines !== null) {
    const lines = model.lines;
    let total = model.cols === 0 ? 0 : sumOf(lines.x);
    for (const w of model.colMax) total += w;
    return clampW(el, withCaption(el, cbW, total + tablePadH(el, cbW), inner), cbW);
  }
  const gap = isCollapse(el) ? 0 : spacingOf(el, P.P_BORDER_SPACING_H, inner);
  let total = gap * gapCount(model.colCollapsed);
  for (const w of model.colMax) total += w;
  return clampW(el, withCaption(el, cbW, total + padH(el, cbW), inner), cbW);
}

/**
 * The intrinsic width of an anonymous table: the same column arithmetic as a real one, but the box
 * belongs to the block around the run, so `el` only supplies the inherited style (border spacing,
 * collapsing) and no width of its own is clamped in.
 */
export function tableRunContentWidth(el: Node, run: Node[], cbW: number, minContent: boolean): number {
  const inner = Math.max(0, cbW);
  const model = buildModel(el, inner, run, true);
  const collapse = el.sv[P.P_BORDER_COLLAPSE] === P.BC_COLLAPSE;
  const gap = collapse ? 0 : spacingOf(el, P.P_BORDER_SPACING_H, inner);
  let total = gap * gapCount(model.colCollapsed);
  for (const w of minContent ? model.colMin : model.colMax) total += w;
  return withCaption(el, cbW, total, minContent ? 0 : inner);
}

/** True when a box holds table-internal children, so it wraps some of them in anonymous tables. */
export function hasTableInternalChild(el: Node): boolean {
  for (const c of boxKids(el)) if (isTableInternal(display(c))) return true;
  return false;
}

// ---------------------------------------------------------------------------
// Cell contents

/** Applies a vertical-align shift to the fragments and lines of a container. */
function shiftFragments(container: Node, fragStart: number, lineStart: number, dy: number): void {
  if (dy === 0) return;
  for (let i = fragStart; i < container.fragTop.length; i++) container.fragTop[i] += dy;
  for (let i = lineStart; i < container.lineBaseline.length; i++) container.lineBaseline[i] += dy;
}

/** Moves a laid-out cell's content down by `dy`, for vertical-align. */
function shiftCellContent(cell: Node, dy: number): void {
  if (dy === 0) return;
  if (cell.lines.length > 0) cell.contentY += dy;
  for (let i = 0; i < cell.fragTop.length; i++) cell.fragTop[i] += dy;
  for (let i = 0; i < cell.lineBaseline.length; i++) cell.lineBaseline[i] += dy;
  for (const c of boxKids(cell)) {
    if (display(c) === P.D_NONE || isOutOfFlow(c)) continue;
    c.y += dy;
  }
}

/**
 * A cell's used vertical-align. Only the keywords position a cell's content; a length or a
 * keyword meant for inline boxes (sub, text-top) computes to baseline in a table cell.
 */
function cellAlign(el: Node): number {
  if (el.su[P.P_VERTICAL_ALIGN] !== P.U_NONE) return P.VA_BASELINE;
  return el.sv[P.P_VERTICAL_ALIGN];
}

/** The vertical-align offset of a cell's content within a cell of height `cellH`. */
function alignOffset(va: number, cellH: number, padTopBottom: number, used: number): number {
  const room = Math.max(0, cellH - padTopBottom - used);
  if (va === P.VA_MIDDLE) return room / 2;
  if (va === P.VA_BOTTOM) return room;
  return 0;
}

/** Distance from a box's border-box top to its first line's baseline, or -1 if it has none. */
function firstBaseline(el: Node): number {
  // A box showing an older layout's outputs lays out for real before its content is read.
  if (el.lPending >= 0) settleNode(el);
  if (el.lines.length > 0) return el.contentY + baselineOffset(el);
  // A line laid out from pieces records where its baseline is. A fragment's top is not the
  // baseline's anchor: an atomic box (an image, an inline-block) is a fragment too, and its top
  // sits where the line put the box, not at its own baseline.
  if (el.lineBaseline.length > 0) return el.lineBaseline[0];
  if (el.fragTop.length > 0) return el.fragTop[0] + baselineOffset(el.fragStyle[0]);
  for (const c of boxKids(el)) {
    if (display(c) === P.D_NONE || isOutOfFlow(c)) continue;
    const b = firstBaseline(c);
    return c.y + (b >= 0 ? b : c.h);
  }
  return -1;
}

// ---------------------------------------------------------------------------
// Table layout

/**
 * Lays out the contents of a table box (display: table or inline-table). `innerW`/`innerH` are
 * the content box size (innerH is NaN when auto). Returns the content height.
 */
export function layoutTable(el: Node, innerW: number, innerH: number, pl: number, pt: number): number {
  return layoutTableBox(el, visibleChildren(el), innerW, innerH, pl, pt, false);
}

/**
 * Lays out a run of table-internal boxes that has no table box of its own, as CSS generates an
 * anonymous table around them (CSS 2.1 §17.2.2). `availW` is the content width of the block they
 * are in, `y` where the run starts relative to that block's border box, and `pl` its left padding
 * and border. Returns the height the run takes.
 */
export function layoutAnonymousTable(el: Node, kids: Node[], availW: number, y: number, pl: number): number {
  return layoutTableBox(el, kids, availW, NaN, pl, y, true);
}

/**
 * The grid width the anonymous table CSS makes around a run of table-internal boxes takes when
 * it shrinks to fit `avail`: its preferred width, kept within its min and max content widths.
 */
export function anonymousTableWidth(el: Node, kids: Node[], avail: number): number {
  const model = buildModel(el, avail);
  const collapse = el.sv[P.P_BORDER_COLLAPSE] === P.BC_COLLAPSE;
  const spacingH = collapse ? 0 : spacingOf(el, P.P_BORDER_SPACING_H, avail);
  const gaps = spacingH * gapCount(model.colCollapsed);
  const target = Math.max(0, avail - gaps);
  if (model.hasPercent) return target + gaps;
  return Math.max(sumOf(model.colMin), Math.min(sumOf(model.colMax), target)) + gaps;
}

/**
 * The table algorithm itself. `el` supplies the inherited style (border spacing, collapsing) and
 * the ancestor that owns any anonymous cell's content. An anonymous table has no box of its own:
 * its width shrinks to fit, it has no padding, it is never `table-layout: fixed`, and captions sit
 * at `pt`, the run's top.
 */
function layoutTableBox(el: Node, kids: Node[], innerW: number, innerH: number, pl: number, pt: number,
    anon: boolean, info?: number[]): number {
  const model = buildModel(el, innerW, kids, anon);
  const collapse = isCollapse(el);
  const spacingH = collapse ? 0 : spacingOf(el, P.P_BORDER_SPACING_H, innerW);
  const spacingV = collapse ? 0 : spacingOf(el, P.P_BORDER_SPACING_V, innerW);
  const cols = model.cols;
  const rows = model.rows.length;
  // A vertical table's grid runs in its own frame: rows stack along the page's block axis and
  // cells down its inline axis. The rows and groups carry the frame's axes, so their cells lay
  // their content out turned and the table box maps every one of them back onto the page.
  if (isVerticalText(el)) {
    for (const r of model.rows) {
      if (r.el === null) continue;
      r.el.vtext = 1;
      r.el.inVtext = 1;
    }
    for (const g of model.groupEls) {
      g.vtext = 1;
      g.inVtext = 1;
    }
  }
  // In the collapsed model the grid lines take the place of the border spacing: a column is the
  // cells' content and padding, and the lines between them are shared half by each side.
  const lines = anon ? null : model.lines;
  applyCellBorders(model, el, lines);
  // A table with no cells has no grid, and so no border spacing or grid lines around it either.
  const gapsH = lines !== null ? (cols > 0 ? sumOf(lines.x) - lines.x[0] / 2 - lines.x[cols] / 2 : 0)
    : spacingH * gapCount(model.colCollapsed);
  // A table box with a width of its own — from its style, its content, or a caption wider than
  // its cells — has already been sized: the columns share the width the box ended up with, which
  // is how a wide caption or a stretched flex item gives its columns more room. An anonymous
  // table has no box to be sized, so it shrinks to its content within the room it has.
  let target = Math.max(0, innerW - gapsH);
  if (anon && !model.hasPercent) {
    const sumMin = sumOf(model.colMin);
    const sumMax = sumOf(model.colMax);
    target = Math.max(sumMin, Math.min(sumMax, target));
  }
  const fixed = !anon && el.sv[P.P_TABLE_LAYOUT] === P.TL_FIXED;
  const widths = fixed ? fixedColumnWidths(model, target) : autoColumnWidths(model, target, innerW);
  // A collapsed column keeps no width, whatever share of the table the distribution gave it.
  for (let i = 0; i < cols; i++) if (model.colCollapsed[i]) widths[i] = 0;
  // A caption's containing block is the table box: the border box, so it spans the padding and
  // borders too, and under collapsed borders runs out to the outer edges of the grid lines, half
  // of the first and last line sitting outside the content box (CSS 2.1 17.4).
  const capW = lines !== null ? innerW + lines.x[0] / 2 + lines.x[cols] / 2 : innerW + padH(el, innerW);
  // The grid is the columns and the spacing between them. Rows, row groups and cells are that
  // wide, and a cell resolves its percentage padding against it. A table with no columns gives
  // its rows the whole content width instead — unless it is an anonymous table around nothing
  // but empty parts, which has no grid at all and takes no room (a <script> passes it by).
  const gridW = lines !== null ? innerW
    : (cols > 0 ? sumOf(widths) + spacingH * spanGaps(model.colCollapsed, 0, cols)
      : anon ? 0 : innerW);
  // A vertical table's grid runs across the page's inline axis, so this extent is the content size
  // its own height has to hold (see layoutBox's height minimum for tables).
  if (isVerticalText(el)) el.tableInlineExtent = gridW;

  // Column edges, in table-local coordinates: the left edge of each column's content, which is
  // where a cell's border box starts.
  const colX: number[] = [];
  let cx = pl + spacingH;
  for (let i = 0; i < cols; i++) {
    colX.push(cx);
    // A collapsed column takes no room, and the border spacing beside it goes with it.
    cx += widths[i] + (model.colCollapsed[i] ? 0 : spacingH);
    if (lines !== null && i + 1 < cols) cx += (lines.x[i] + lines.x[i + 1]) / 2;
  }

  // A cell's border box holds its content and the half of each adjoining grid line it draws, and
  // a spanning cell covers the whole of the inner lines it crosses.
  const cellWidth = (cell: Cell): number => {
    let w = 0;
    for (let i = cell.col; i < cell.col + cell.colspan; i++) w += widths[i];
    if (lines !== null) {
      w += (lines.x[cell.col] + lines.x[cell.col + cell.colspan]) / 2;
      for (let i = cell.col + 1; i < cell.col + cell.colspan; i++) w += lines.x[i];
      return w;
    }
    return w + spacingH * spanGaps(model.colCollapsed, cell.col, cell.colspan);
  };
  // The border-box height of a cell spanning `rowspan` rows, lines included. A collapsed row
  // inside the span keeps neither its height nor its share of the lines: the cell shrinks to the
  // rows that are left (visibility-collapse-rowspan-002).
  const cellSpanH = (cell: Cell): number => {
    let h = 0;
    for (let r = cell.row; r < cell.row + cell.rowspan; r++) h += rowH[r];
    if (lines !== null) {
      if (spansCollapsedRow(model, cell)) return h;
      h += (lines.y[cell.row] + lines.y[cell.row + cell.rowspan]) / 2;
      for (let r = cell.row + 1; r < cell.row + cell.rowspan; r++) h += lines.y[r];
      return h;
    }
    return h + spacingV * spanGaps(model.rowCollapsed, cell.row, cell.rowspan);
  };

  for (const r of model.rows) if (r.el !== null) r.el.clearFragments();
  for (const g of model.groupEls) g.clearFragments();

  // Captions sit outside the table's border box: the top ones above it, in the element's box.
  // The table's border box (background, borders) starts below them (see el.boxTop).
  const capBase = anon ? pt : 0;
  let capTopH = 0;
  for (const cap of model.captionsTop) {
    // A caption of its own width keeps it; an auto-width one fills the table's space.
    const cw = specW(cap, capW);
    layoutBox(cap, capW, NaN, Number.isNaN(cw) ? capW : cw, NaN, false);
    // A caption is a block box, so its vertical margins take room beside it and don't collapse
    // with anything (CSS 2.1 §17.4): they sit between the caption and the table's row groups.
    const mt = zeroIfNaN(len(cap, P.P_MARGIN_TOP, capW));
    const mb = zeroIfNaN(len(cap, P.P_MARGIN_BOTTOM, capW));
    // A real table's captions sit at its border box's left edge; an anonymous one has no box of
    // its own, so they start at the container's content edge with the rest of the run.
    cap.x = (anon ? pl : 0) + zeroIfNaN(len(cap, P.P_MARGIN_LEFT, capW));
    cap.y = capBase + capTopH + mt;
    place(cap);
    capTopH += mt + cap.h + mb;
  }
  const boxTop = capTopH;
  const contentTop = boxTop + pt;
  const gridTop = contentTop + spacingV;

  // Row heights from the cells that span one row. A definite row group height is the base a row's
  // percentage height resolves against, as the test suite expects (`tbody-height-redistribution`).
  const groupSpec: number[] = [];
  for (let gid = 0; gid < model.groupElOf.length; gid++) {
    const g = model.groupElOf[gid];
    groupSpec.push(g === null || g === undefined ? NaN : len(g, P.P_HEIGHT, innerH));
  }
  const constrained: boolean[] = [];
  const rowH: number[] = [];
  // Each row's own specified height, which is the height a cell's percentage resolves against.
  const rowSpec: number[] = [];
  for (let r = 0; r < rows; r++) {
    let h = 0;
    const rowEl = model.rows[r].el;
    const gspec = groupSpec[model.rows[r].group];
    constrained.push(false);
    rowSpec.push(NaN);
    if (rowEl !== null) {
      const spec = len(rowEl, P.P_HEIGHT, Number.isNaN(gspec) ? innerH : gspec);
      // A row's specified height is the height of its border box. Under collapsed borders that
      // box runs from the centre of the line above it to the centre of the one below, so the
      // halves come out of the row's own height (the lines are drawn, and counted, separately).
      if (!Number.isNaN(spec)) {
        h = Math.max(0, lines !== null ? spec - (lines.y[r] + lines.y[r + 1]) / 2 : spec);
        constrained[r] = true;
        rowSpec[r] = spec;
      }
    }
    rowH.push(h);
  }
  // A side's used width: the collapsed grid line's half where there is one, else the computed
  // width. (A local helper, since `borderBottom` is a name of its own further down.)
  const usedSide = (n: Node, side: number, p: number): number => (n.bw.length > 0 ? n.bw[side] : n.sv[p]);
  const measureCell = (cell: Cell): number => {
    const w = cellWidth(cell);
    if (cell.el !== null) {
      const spec = specH(cell.el, gridW, NaN);
      if (Number.isNaN(spec)) {
        layoutBox(cell.el, gridW, NaN, w, NaN, false);
        return cell.el.h;
      }
      // A cell's height is a minimum, not a fixed size: content taller than it stretches the row
      // (CSS 2.1 §17.5.3). Measure it once with the height applied, so a child's percentage
      // resolves against it (a canvas with max-height: 100% is the cell's own height), and if the
      // content reaches past the cell, again with the height left out, as the intrinsic pass
      // does: there a percentage height resolves against nothing, so content that overflowed only
      // by measuring itself against the cell — an inline-block at height: 100% on a line with a
      // lower baseline — leaves the row at the cell's own height.
      const sides = usedSide(cell.el, 0, P.P_BORDER_TOP_WIDTH) + usedSide(cell.el, 2, P.P_BORDER_BOTTOM_WIDTH);
      layoutBox(cell.el, gridW, NaN, w, NaN, false);
      if (cell.el.naturalH + sides <= spec) return spec;
      layoutBox(cell.el, gridW, NaN, w, NaN, false, true);
      return Math.max(spec, cell.el.h + sides);
    }
    // An anonymous cell has no element to ask for a first baseline, so its content's own
    // first line supplies one, the way a real cell element's content does.
    const base: number[] = [];
    const h = anonymousFlowHeight(cell.content!, w, el, base);
    if (base.length > 0 && cellAlign(el) === P.VA_BASELINE) cell.baseline = base[0];
    return h;
  };
  for (const cell of model.cells) {
    if (spansCollapsedRow(model, cell) && !noRowRoom(model, cell)) {
      // A cell that spans a collapsed row and a visible one gives the visible row no height: the
      // rows that are left keep theirs (rowspan-002, "fourth row stays the same height"). A cell
      // wholly inside collapsed rows is still measured, since its content weighs the share a
      // fixed table height gives that row before the row is taken out (row-004).
      cell.measured = 0;
      continue;
    }
    cell.measured = measureCell(cell);
    // A cell's border box runs from the centre of the line above it to the centre of the one
    // below, so under collapsed borders the halves are not part of the row's own height.
    let need = cell.measured;
    if (lines !== null) need -= (lines.y[cell.row] + lines.y[cell.row + 1]) / 2;
    if (cell.rowspan === 1 && need > rowH[cell.row]) rowH[cell.row] = need;
    // A cell can name the height of its row (CSS 2.1 §17.5.3), and a row whose height comes from
    // a cell is a constrained row too: a table taller than its rows hands the extra height to
    // the rows that haven't got one. A percentage here is a share of the row's own height, not of
    // the table's: a cell at `height: 100%` of a 50px row is 50px, and it stays 50px however
    // tall the table ends up (css-tables' table-as-item-cell-percentage tests).
    if (cell.rowspan === 1 && cell.el !== null) {
      const spec = len(cell.el, P.P_HEIGHT, rowSpec[cell.row]);
      if (!Number.isNaN(spec)) {
        constrained[cell.row] = true;
        const specH = Math.max(0, lines !== null ? spec - (lines.y[cell.row] + lines.y[cell.row + 1]) / 2 : spec);
        if (specH > rowH[cell.row]) rowH[cell.row] = specH;
      }
    }
  }
  // Cells with vertical-align: baseline line up their first baselines across the row; a cell
  // whose baseline starts higher makes the row taller.
  const rowBase: number[] = [];
  for (let r = 0; r < rows; r++) rowBase.push(0);
  for (const cell of model.cells) {
    // A cell that spans a collapsed row and gave its rows no height wasn't laid out above: its
    // content is whatever an earlier layout left, so it has no baseline to line the row up on.
    if (spansCollapsedRow(model, cell) && !noRowRoom(model, cell)) continue;
    if (cell.el !== null) {
      if (cellAlign(cell.el) !== P.VA_BASELINE) continue;
      const b = firstBaseline(cell.el);
      if (b >= 0) cell.baseline = b;
    }
    if (cell.baseline > rowBase[cell.row]) rowBase[cell.row] = cell.baseline;
  }
  for (const cell of model.cells) {
    if (cell.baseline <= 0) continue;
    const shift = rowBase[cell.row] - cell.baseline;
    let need = cell.measured + shift;
    if (lines !== null) need -= (lines.y[cell.row] + lines.y[cell.row + 1]) / 2;
    if (shift > 0 && need > rowH[cell.row]) rowH[cell.row] = need;
  }
  // Rowspanning cells push the rows they cover taller.
  const spanning = model.cells.filter((c) => c.rowspan > 1);
  spanning.sort((a, b) => a.rowspan - b.rowspan);
  for (let pass = 0; pass < 3; pass++) {
    for (const cell of spanning) {
      const span = cellSpanH(cell);
      const take: number[] = [];
      for (let r = cell.row; r < cell.row + cell.rowspan; r++) if (!model.rowCollapsed[r]) take.push(r);
      if (take.length > 0 && cell.measured > span + 0.01) {
        const add = (cell.measured - span) / take.length;
        for (const r of take) rowH[r] += add;
      }
    }
  }

  // A definite row group height is a minimum for its rows: what it leaves over is shared among the
  // rows that have no height of their own, in proportion to the height each already needs, or
  // equally when they need none at all. Rows with a height of their own keep it.
  for (let gid = 0; gid < model.groupElOf.length; gid++) {
    const spec = groupSpec[gid];
    if (Number.isNaN(spec)) continue;
    const mine: number[] = [];
    let sum = 0;
    for (let r = 0; r < rows; r++) {
      if (model.rows[r].group !== gid || model.rowCollapsed[r]) continue;
      mine.push(r);
      sum += rowH[r];
    }
    if (mine.length === 0) continue;
    const extra = spec - sum;
    if (extra <= 0.01) continue;
    const open = mine.filter((r) => !constrained[r]);
    if (open.length === 0) {
      for (const r of mine) rowH[r] += extra / mine.length;
      continue;
    }
    let free = 0;
    for (const r of open) free += rowH[r];
    for (const r of open) rowH[r] += free > 0 ? (extra * rowH[r]) / free : extra / open.length;
  }

  // A definite table height gives its extra space to the rows.
  let gridH = 0;
  for (let r = 0; r < rows; r++) gridH += rowH[r];
  if (lines !== null) {
    // The content box is the rows and the inner halves of the outer lines. With no cells there is
    // no grid, and so no lines either.
    if (cols > 0) gridH += sumOf(lines.y) - (lines.y[0] + lines.y[rows]) / 2;
  } else if (rows > 0 && (cols > 0 || !Number.isNaN(innerH))) {
    // A table with no rows has no grid, and so no border spacing around it either. A table with
    // rows but no cells has no spacing either, unless it has a height of its own to divide up
    // (`table-rows-with-zero-columns`).
    gridH += spacingV * gapCount(model.rowCollapsed);
  }
  if (!Number.isNaN(innerH) && rows > 0 && innerH > gridH) {
    // The extra height goes to the rows that have no height of their own, in proportion to the
    // height each already needs, or equally when they need none at all. A table whose rows all
    // name a height shares it out in proportion to those heights instead.
    const extra = innerH - gridH;
    const open: number[] = [];
    let openSum = 0;
    // A collapsed row takes its share of the height here and loses it below, so the rows that
    // are left keep what the table's own height would have given them (row-004).
    for (let r = 0; r < rows; r++) {
      if (constrained[r]) continue;
      open.push(r);
      openSum += rowH[r];
    }
    let pool = open;
    let poolSum = openSum;
    if (pool.length === 0) {
      pool = [];
      poolSum = 0;
      for (let r = 0; r < rows; r++) {
        pool.push(r);
        poolSum += rowH[r];
      }
    }
    if (pool.length > 0) {
      for (const r of pool) rowH[r] += poolSum > 0 ? (extra * rowH[r]) / poolSum : extra / pool.length;
    }
    gridH = innerH;
  }
  // A collapsed row is taken out of the grid now, with the share of the table's height it was
  // weighed with, so the table shrinks by it.
  el.collapsedRowH = 0;
  if (model.rowCollapsed.some((c) => c)) {
    for (let r = 0; r < rows; r++) {
      if (!model.rowCollapsed[r]) continue;
      el.collapsedRowH += rowH[r];
      rowH[r] = 0;
    }
    gridH = sumOf(rowH);
    if (lines !== null) {
      if (cols > 0) gridH += sumOf(lines.y) - (lines.y[0] + lines.y[rows]) / 2;
    } else if (rows > 0 && (cols > 0 || !Number.isNaN(innerH))) {
      gridH += spacingV * gapCount(model.rowCollapsed);
    }
  }
  // A row group with no rows still has a box when it asks for a height, and it sits below the
  // grid, past the rows that are there.
  const rowlessY = new Map<number, number>();
  let tailY = contentTop + gridH;
  for (let gid = 0; gid < model.groupElOf.length; gid++) {
    if (model.rows.some((r) => r.group === gid)) continue;
    const spec = groupSpec[gid];
    if (Number.isNaN(spec) || spec <= 0) continue;
    rowlessY.set(gid, tailY);
    tailY += spec;
  }
  if (tailY > contentTop + gridH) gridH = tailY - contentTop;

  // Row tops, in table-local coordinates. A row starts at the centre of the line above it, which
  // is where the cells' border boxes start too.
  const rowY: number[] = [];
  let ry = gridTop;
  for (let r = 0; r < rows; r++) {
    rowY.push(ry);
    // A collapsed row takes no room, and the border spacing beside it goes with it.
    if (lines !== null) ry += rowH[r] + (lines.y[r] + lines.y[r + 1]) / 2;
    else ry += rowH[r] + (model.rowCollapsed[r] ? 0 : spacingV);
  }

  // The table paints the collapsed border grid itself, above its cells: the lines are shared, and
  // a horizontal line is one band whose colour changes only at the column edges, which no
  // cell-by-cell painting can reproduce.
  if (!anon) {
    const border: number[] = [];
    if (lines !== null && rows > 0 && cols > 0) {
      const boxH = gridH + padV(el, innerW);
      // A row's border box runs from the centre of the line above it to the centre of the one
      // below; the last row ends at the centre of the table's bottom line. Likewise each column's
      // border box left, and the centre of the table's right line.
      const rowEnd = boxH - lines.y[rows] / 2;
      const rowTop = (r: number): number => (r < rows ? rowY[r] - boxTop : rowEnd);
      const colLeft = (c: number): number => (c < cols ? colX[c] : el.w - lines.x[cols] / 2);
      // Vertical lines run down the rows, taking the width, colour and style their segment in each
      // row won: each edge is resolved on its own, so a cell's wider border widens only its own
      // segment. Each rect is x, y, w, h, colour, style, 1 for a vertical side (0 horizontal) and
      // the table position of the cell that owns it, which settles a crossing of equal borders.
      for (let j = 0; j <= cols; j++) {
        const cxLine = colLeft(j);
        const owner = Math.max(0, j - 1);
        let start = 0;
        let color = lines.segXc[j];
        let style = lines.segXs[j];
        let lw = lines.segXw[j];
        for (let r = 1; r <= rows; r++) {
          const nextC = r < rows ? lines.segXc[r * (cols + 1) + j] : -1;
          const nextS = r < rows ? lines.segXs[r * (cols + 1) + j] : P.BRS_NONE;
          const nextW = r < rows ? lines.segXw[r * (cols + 1) + j] : 0;
          if (nextC !== color || nextS !== style || nextW !== lw) {
            if (lw > 0) border.push(cxLine - lw / 2, rowTop(start), lw, rowTop(r) - rowTop(start), color, style, 1, start * cols + owner);
            start = r;
            color = nextC;
            style = nextS;
            lw = nextW;
          }
        }
      }
      // Horizontal lines are bands across the table, one stretch per column, each as tall as its
      // own segment's winner. A stretch ends at the outer edge of the vertical segment beside it —
      // the wider of the two rows it meets there, since a narrower line leaves the rest of the
      // table's outer edge blank.
      for (let i = 0; i <= rows; i++) {
        const cyLine = rowTop(i);
        const halfAt = (j: number): number => {
          const above = i > 0 ? lines.segXw[(i - 1) * (cols + 1) + j] : 0;
          const below = i < rows ? lines.segXw[i * (cols + 1) + j] : 0;
          return Math.max(above, below) / 2;
        };
        // Each column's stretch runs from the outer edge of the vertical line on its left to the
        // outer edge of the one on its right, covering both crossing squares: a 6px yellow cell
        // border beside a 4px green one owns the whole corner. The crossings are where the two
        // stretches overlap; conflict resolution decides those (see below), not paint order.
        for (let c = 0; c < cols; c++) {
          const lw = lines.segYw[i * cols + c];
          if (!(lw > 0)) continue;
          const x0 = colLeft(c) - halfAt(c);
          const x1 = colLeft(c + 1) + halfAt(c + 1);
          const above = Math.max(0, i - 1);
          border.push(x0, cyLine - lw / 2, x1 - x0, lw, lines.segYc[i * cols + c], lines.segYs[i * cols + c], 0, above * cols + c);
        }
      }
    }
    // Where a vertical and a horizontal line cross, the two share the square: CSS 2.1 §17.6.2.1
    // settles it the way it settles a shared edge — the wider border wins (a cell that paints a
    // 6px border beside a 2px one doesn't let the thin one cut its corner), then the style of
    // higher precedence, then the colour of the cell that comes first in the table, so the
    // top-left cell owns the corner and, of its own two borders, the horizontal one. The winner
    // is painted last, so the losers go down first.
    const segs: number[][] = [];
    for (let k = 0; k + 7 < border.length; k += 8) segs.push(border.slice(k, k + 8));
    const thickness = (s: number[]): number => (s[6] === 1 ? s[2] : s[3]);
    segs.sort((a, b) => {
      const dt = thickness(a) - thickness(b);
      if (dt !== 0) return dt;
      const ds = borderStylePrecedence(a[5]) - borderStylePrecedence(b[5]);
      if (ds !== 0) return ds;
      return b[7] - a[7];
    });
    const out: number[] = [];
    for (const s of segs) out.push(s[0], s[1], s[2], s[3], s[4], s[5], s[6]);
    el.tborder = out;
  }

  // Column backgrounds: a `<col>` or `<colgroup>` box paints nothing itself, so the table paints
  // them beneath its rows and cells, column groups first and then the columns. A background is
  // sized and positioned in the column's box, which spans from the first row's top to the last
  // one's bottom, but it shows only in the cell areas of each row: the border spacing between
  // rows belongs to the table and stays clear.
  el.tcols = [];
  if (!anon && cols > 0 && rows > 0) {
    const x0: number[] = [];
    const colW: number[] = [];
    for (let i = 0; i < cols; i++) {
      if (lines !== null) {
        // The column's box runs between the centres of the grid lines on either side of it: the
        // half of the left line inside the cell is the cell's, and the column covers it.
        x0.push(colX[i]);
        colW.push(widths[i] + (lines.x[i] + lines.x[i + 1]) / 2);
      } else {
        x0.push(colX[i]);
        colW.push(widths[i]);
      }
    }
    const bandTop = rowY[0] - boxTop;
    // In the collapsed model the column's box runs down to the far edge of the last row's share
    // of the bottom line, so the column background is continuous over the shared lines.
    const bandH = rowY[rows - 1] + rowH[rows - 1] - rowY[0]
      + (lines !== null ? (lines.y[rows - 1] + lines.y[rows]) / 2 : 0);
    const groups: Node[] = [];
    const columns: Node[] = [];
    const addRange = (into: Node[], part: Node, start: number, span: number): void => {
      const end = Math.min(cols, start + span);
      if (end <= start) return;
      const px = x0[start];
      const pw = x0[end - 1] + colW[end - 1] - px;
      part.bgbox = [px, bandTop, pw, bandH];
      // The background is laid out against the whole column, and shows only in the cells that
      // hold the column: the border spacing between rows is the table's, except where a cell
      // spans the rows across it.
      part.bgseg = [];
      for (const cell of model.cells) {
        const cs = Math.max(start, cell.col);
        const ce = Math.min(end, cell.col + cell.colspan);
        if (ce <= cs) continue;
        // The column's background shows over the whole area of every cell that reaches the
        // column: a cell spanning two columns shows it across its whole box, the image still
        // anchored at the column's own box.
        const cy = rowY[cell.row];
        const ch = lines !== null ? cellSpanH(cell)
          : rowY[Math.min(rows - 1, cell.row + cell.rowspan - 1)] + rowH[Math.min(rows - 1, cell.row + cell.rowspan - 1)] - cy;
        part.bgseg.push(colX[cell.col] - px, cy - boxTop - bandTop, cellWidth(cell), ch);
      }
      into.push(part);
    };
    let ci = 0;
    for (const k of kids) {
      const d = display(k);
      if (d === P.D_TABLE_COLUMN) {
        const span = Math.max(1, attrNumber(k, "span", 1));
        addRange(columns, k, ci, span);
        ci += span;
      } else if (d === P.D_TABLE_COLUMN_GROUP) {
        const colKids = visibleChildren(k).filter((c) => display(c) === P.D_TABLE_COLUMN);
        if (colKids.length > 0) {
          const start = ci;
          for (const c of colKids) {
            const span = Math.max(1, attrNumber(c, "span", 1));
            addRange(columns, c, ci, span);
            ci += span;
          }
          addRange(groups, k, start, ci - start);
        } else {
          const span = Math.max(1, attrNumber(k, "span", 1));
          addRange(groups, k, ci, span);
          ci += span;
        }
      }
    }
    el.tcols = groups.concat(columns);
  }

  // The top of each group's box: the top of its first row, without the border spacing above it,
  // which belongs to the table and not to the group (CSS Tables 3, bounding-box assignment).
  const groupY = new Map<number, number>();
  for (let r = 0; r < rows; r++) {
    if (!groupY.has(model.rows[r].group)) groupY.set(model.rows[r].group, rowY[r]);
  }
  // A table part's percentage relative offsets resolve against its containing block's specified
  // height: a row, row group or cell grows to hold its content, so its used height can be past
  // the height it was given, and the percentage follows the height it was given (CSS 2.1 §9.3.2).
  const relBasisH = (part: Node): number => {
    const parent = part.parentElement;
    if (parent === null) return NaN;
    return specH(parent, gridW, NaN);
  };
  /** The relative shift of a table part, for place() to add to its position. */
  const relativeShift = (part: Node, cbW: number): void => {
    const off = relativeOffset(part, cbW, relBasisH(part));
    part.relX = off[0];
    part.relY = off[1];
  };

  // Place rows, relative to their parent (a row group, or the table itself).
  for (let r = 0; r < rows; r++) {
    const row = model.rows[r];
    if (row.el === null) continue;
    const parent = row.el.parentElement;
    const grouped = parent !== null && isTableRowGroup(display(parent));
    row.el.x = grouped ? 0 : pl + spacingH;
    row.el.y = grouped ? rowY[r] - zeroIfNaN(groupY.get(row.group)!) : rowY[r];
    row.el.w = gridW;
    row.el.h = rowH[r];
    row.el.bgCells = model.cells.some((c) => c.row <= r && r < c.row + c.rowspan);
    row.el.bgseg = [];
    // A row's background box reaches down over its half of the grid line below it; rows in a
    // collapsing table share their lines, so their backgrounds meet edge to edge.
    row.el.bgbox = [0, 0, gridW, rowH[r] + (lines !== null ? (lines.y[r] + lines.y[r + 1]) / 2 : 0)];
    relativeShift(row.el, gridW);
    place(row.el);
  }
  // A row group's box covers exactly its rows, and the border spacing between them. The rows
  // belong to the group by its id rather than by their parent, since the rows of stray content
  // are anonymous.
  for (let gid = 0; gid < model.groupElOf.length; gid++) {
    const g = model.groupElOf[gid];
    if (g === null || g === undefined) continue;
    let first = -1;
    let last = -1;
    for (let r = 0; r < rows; r++) {
      if (model.rows[r].group !== gid) continue;
      if (first < 0) first = r;
      last = r;
    }
    if (first < 0) {
      // A group with no rows covers nothing; a definite height still gives it a box.
      const y = rowlessY.get(gid);
      const spec = groupSpec[gid];
      if (y === undefined || Number.isNaN(spec)) continue;
      g.x = pl + spacingH;
      g.y = y;
      g.w = gridW;
      g.h = spec;
      g.bgseg = [];
      g.bgbox = [0, 0, gridW, spec];
      relativeShift(g, gridW);
      place(g);
      continue;
    }
    g.x = pl + spacingH;
    g.y = zeroIfNaN(groupY.get(gid)!);
    g.w = gridW;
    // A group with a height of its own is exactly that tall, unless its rows need more: the rows
    // take the extra space and their border spacing can reach past the group's box.
    let rowsH = 0;
    for (let r = first; r <= last; r++) rowsH += rowH[r];
    const gspec = groupSpec[gid];
    g.h = Number.isNaN(gspec) ? rowY[last] + rowH[last] - g.y : Math.max(0, gspec, rowsH);
    g.bgseg = [];
    // A group's background is sized against the box its rows fill, which starts at the first
    // row's top rather than a border spacing above it.
    const tail = lines !== null ? (lines.y[last] + lines.y[last + 1]) / 2 : 0;
    g.bgbox = [0, rowY[first] - g.y, gridW, rowY[last] + rowH[last] + tail - rowY[first]];
    relativeShift(g, gridW);
    place(g);
  }

  // A row's background shows only in its cells' areas: the border spacing between columns is the
  // table's, not the row's. Each row's extents go in its own border box's coordinates, and its
  // row group's in the group's box, whose top is a row spacing above the first row.
  if (cols > 0) {
    const rowX = pl + spacingH;
    // One stretch per cell of the row: the row's background shows over the whole area of every
    // cell that reaches it, so a cell spanning two rows shows it down its whole height while the
    // image stays anchored at the row.
    const rowSegs: number[][] = [];
    for (let r = 0; r < rows; r++) {
      const segs: number[] = [];
      for (const cell of model.cells) {
        if (cell.row > r || cell.row + cell.rowspan <= r) continue;
        const lastRow = Math.min(rows - 1, cell.row + cell.rowspan - 1);
        segs.push(colX[cell.col] - rowX, rowY[cell.row] - rowY[r], cellWidth(cell),
          lines !== null ? cellSpanH(cell) : rowY[lastRow] + rowH[lastRow] - rowY[cell.row]);
      }
      rowSegs.push(segs);
    }
    for (let r = 0; r < rows; r++) {
      const row = model.rows[r];
      if (row.el === null) continue;
      row.el.bgseg = rowSegs[r];
    }
    for (let gid = 0; gid < model.groupElOf.length; gid++) {
      const g = model.groupElOf[gid];
      if (g === null || g === undefined) continue;
      // A group with no rows (an empty <tbody>) has no row to anchor a background at.
      if (!groupY.has(gid)) continue;
      const gy = zeroIfNaN(groupY.get(gid)!);
      const segs: number[] = [];
      for (let r = 0; r < rows; r++) {
        if (model.rows[r].group !== gid) continue;
        const s = rowSegs[r];
        for (let i = 0; i + 3 < s.length; i += 4) segs.push(s[i], s[i + 1] + rowY[r] - gy, s[i + 2], s[i + 3]);
      }
      g.bgseg = segs;
    }
  }

  // Lay out and place the cells.
  for (const cell of model.cells) {
    // A collapsed column takes the cell's width away but not its height (the row still needs the
    // content, as `col visibility:collapse doesn't change table height` asks); a collapsed row
    // takes the height and clips the cell away with everything in it.
    const noWidth = noColumnRoom(model, cell);
    const noHeight = noRowRoom(model, cell);
    const w = noWidth ? 0 : cellWidth(cell);
    const spanH = cellSpanH(cell);
    const x = colX[cell.col];
    const top = rowY[cell.row];
    if (cell.el !== null) {
      const c = cell.el;
      c.collapsedTrack = noWidth || noHeight;
      if (noHeight) {
        c.w = 0;
        c.h = 0;
        c.naturalH = 0;
        c.lines = [];
        c.x = x;
        c.y = top;
        place(c);
        continue;
      }
      layoutBox(c, gridW, NaN, w, spanH, false);
      const parent = c.parentElement;
      const inRow = parent !== null && display(parent) === P.D_TABLE_ROW;
      // The cell of an anonymous row is a child of the row group itself, so the group's box is
      // where its coordinates start.
      const inGroup = !inRow && parent !== null && isTableRowGroup(display(parent));
      const gTop = inGroup ? zeroIfNaN(groupY.get(model.rows[cell.row].group)!) : 0;
      c.x = inRow || inGroup ? x - pl - spacingH : x;
      c.y = inRow ? top - rowY[cell.row] : inGroup ? top - gTop : top;
      relativeShift(c, gridW);
      place(c);
      const va = cellAlign(c);
      if (va === P.VA_BASELINE) {
        if (cell.baseline > 0) shiftCellContent(c, rowBase[cell.row] - cell.baseline);
      } else if (va === P.VA_MIDDLE || va === P.VA_BOTTOM) {
        const used = Math.max(0, c.naturalH - padV(c, innerW));
        const dy = alignOffset(va, spanH, padV(c, innerW), used);
        shiftCellContent(c, dy);
      }
    } else {
      // An anonymous cell: its content lives in fragments of the nearest real ancestor.
      const container = anonymousContainer(cell, el);
      const containerAbsX = container === el ? 0 : container.x;
      const containerAbsY = container === el ? 0 : container.y;
      const fragStart = container.fragKind.length;
      const lineStart = container.lineBaseline.length;
      // The flow is walked in order, so a block inside an inline box takes its place between the
      // lines before and after it.
      let cursor = top;
      // A cell is a formatting context of its own, so its floats are placed against its edges and
      // the rest of the content goes below them. Its blocks' margins collapse with each other the
      // way they do in a block box (see anonymousFlowHeight).
      const fctx = new FloatCtx();
      let floatBottom = top;
      let pendP = 0;
      let pendN = 0;
      for (const e of anonymousFlow(cell.content!, w)) {
        if (e.abs !== null) {
          e.abs.staticX = x;
          e.abs.staticY = cursor;
          e.abs.staticValid = true;
          continue;
        }
        if (e.block !== null) {
          const b = e.block;
          const mt = zeroIfNaN(len(b, P.P_MARGIN_TOP, w));
          const mb = zeroIfNaN(len(b, P.P_MARGIN_BOTTOM, w));
          if (isFloat(b)) {
            const bottom = placeAnonFloat(b, x, cursor + pendP + pendN, w, fctx);
            if (bottom > floatBottom) floatBottom = bottom;
            b.x -= containerAbsX;
            b.y -= containerAbsY;
            place(b);
            continue;
          }
          if (floatBottom > cursor) cursor = floatBottom;
          layoutBox(b, w, NaN, NaN, NaN, false);
          const ml = zeroIfNaN(len(b, P.P_MARGIN_LEFT, w));
          const mtP = Math.max(0, mt, b.escTopP);
          const mtN = Math.min(0, mt, b.escTopN);
          if (mtP > pendP) pendP = mtP;
          if (mtN < pendN) pendN = mtN;
          if (b.collapsesThrough) {
            const mbP = Math.max(0, mb, b.escBotP);
            const mbN = Math.min(0, mb, b.escBotN);
            if (mbP > pendP) pendP = mbP;
            if (mbN < pendN) pendN = mbN;
            b.x = x - containerAbsX + ml + e.shiftX;
            b.y = cursor - containerAbsY + pendP + pendN + e.shiftY;
            place(b);
            continue;
          }
          const y = cursor + pendP + pendN;
          b.x = x - containerAbsX + ml + e.shiftX;
          b.y = y - containerAbsY + e.shiftY;
          place(b);
          cursor = y + b.h;
          pendP = Math.max(0, mb, b.escBotP);
          pendN = Math.min(0, mb, b.escBotN);
          continue;
        }
        if (e.pieces.length > 0) {
          // A run of nothing but white space makes no line box; it leaves the margins on either
          // side of it adjoining, and only gives the boxes out of flow in it a static position.
          if (isCollapsibleRun(e.pieces)) {
            placeAbsOfBlankRun(e.pieces, x, cursor + pendP + pendN);
            continue;
          }
          if (floatBottom > cursor) cursor = floatBottom;
          cursor += pendP + pendN;
          pendP = 0;
          pendN = 0;
          cursor += layoutAnonInline(container, e.pieces, x - containerAbsX, cursor - containerAbsY, w);
        }
      }
      cursor += pendP + pendN;
      const used = cursor - top;
      const va = cellAlign(el);
      // A baseline-aligned cell moves its content so its first line shares the row's baseline
      // with the other cells; the other alignments use the room the row leaves.
      const dy = va === P.VA_BASELINE
        ? cell.baseline > 0 ? rowBase[cell.row] - cell.baseline : 0
        : alignOffset(va, spanH, 0, used);
      shiftFragments(container, fragStart, lineStart, dy);
    }
  }

  // Bottom captions sit below the table's border box, in the element's box.
  let bottom = boxTop + gridH + (anon ? 0 : padV(el, innerW));
  const borderBottom = bottom;
  for (const cap of model.captionsBottom) {
    const cw = specW(cap, capW);
    layoutBox(cap, capW, NaN, Number.isNaN(cw) ? capW : cw, NaN, false);
    const mt = zeroIfNaN(len(cap, P.P_MARGIN_TOP, capW));
    const mb = zeroIfNaN(len(cap, P.P_MARGIN_BOTTOM, capW));
    // Bottom captions sit where the top ones do: at the table's left edge, or for an anonymous
    // table at the container's content edge, after their own left margin.
    cap.x = (anon ? pl : 0) + zeroIfNaN(len(cap, P.P_MARGIN_LEFT, capW));
    cap.y = capBase + bottom + mt;
    place(cap);
    bottom += mt + cap.h + mb;
  }
  // An anonymous table has no element box to inset.
  if (!anon) {
    el.boxTop = boxTop;
    el.boxBottom = bottom - borderBottom;
  }
  // The table's own baseline is its first row's, counted from its border box's top. An
  // inline-table element is an atomic box on the line, so it has to leave that baseline where
  // the line machinery can find it, the way a block container's lines leave theirs. A first cell
  // whose content holds no line box still gives a baseline: CSS 2.1 17.5.1 puts it at the bottom
  // of the cell's content edge, which an empty cell of a row the table sized sits where its own
  // content ends, not at the row's bottom. A table with no rows leaves the line the margin edge.
  let firstRowBase = -1;
  if (rows > 0) {
    const first = model.cells.length > 0 && model.cells[0].row === 0 ? model.cells[0] : null;
    const c = first !== null ? first.el : null;
    const fallback = c !== null
      ? borderTop(c) + zeroIfNaN(len(c, P.P_PADDING_TOP, gridW)) + c.contentH
      : rowH[0];
    firstRowBase = rowY[0] - pt + (rowBase[0] > 0 ? rowBase[0] : fallback);
  }
  if (!anon && firstRowBase >= 0) el.lineBaseline.push(firstRowBase);
  if (info !== undefined) {
    // An anonymous inline-table's box: the columns and the border spacing around them. It sits
    // on the line by its first row's baseline, or by its bottom edge when it has no rows.
    info.push(gridW + (lines !== null || cols === 0 ? 0 : 2 * spacingH));
    info.push(firstRowBase >= 0 ? firstRowBase : boxTop + gridH);
  }
  // The content height includes the caption space; a real table's border box is inset by it.
  return boxTop + gridH + (bottom - borderBottom);
}

/**
 * Lays out a run of table parts that sits in inline content (CSS 2.1 §17.2.2): the anonymous
 * inline-table they make is one atomic box on the line. `el` supplies the inherited style and
 * owns the anonymous cells' content, and `top` is the table's top relative to it. Returns the
 * height, and pushes the box width and first-row baseline (as the distance from the top) into
 * `info`.
 */
export function layoutInlineTableRun(el: Node, run: Node[], availW: number, top: number, info: number[],
    left: number = 0): number {
  return layoutTableBox(el, run, availW, NaN, left, top, true, info);
}

/** The real ancestor whose fragments paint an anonymous cell's content. */
function anonymousContainer(cell: Cell, table: Node): Node {
  const content = cell.content;
  if (content !== null && content.length > 0) {
    const p = content[0].parentElement;
    if (p !== null) return p;
  }
  return table;
}

/** Inline lines of anonymous content, laid out at (x, y) relative to `container`. */
function layoutAnonInline(container: Node, pieces: Piece[], x: number, y: number, w: number): number {
  measurePieces(pieces, w, true);
  const lines = breakLines(pieces, w);
  const strutA = baselineOffset(container);
  const strutD = lineHeightPx(container) - strutA;
  let top = 0;
  for (const line of lines) {
    let hasContent = false;
    for (const item of line.items) if (item.kind === 0 || item.kind === K_ATOMIC || item.kind === K_ATABLE) hasContent = true;
    if (!hasContent && !line.forced) continue;
    let above = strutA;
    let below = strutD;
    for (const item of line.items) {
      if (item.kind === K_ATABLE) {
        above = Math.max(above, item.asc);
        below = Math.max(below, item.h - item.asc);
      } else if (item.kind === K_ATOMIC) {
        const c = item.style;
        const asc = atomicAscent(c, w);
        above = Math.max(above, asc);
        below = Math.max(below, c.h - asc);
      } else {
        const a = baselineOffset(item.style);
        above = Math.max(above, a);
        below = Math.max(below, lineHeightPx(item.style) - a);
      }
    }
    const baseline = top + above;
    const lineIndex = container.lineBaseline.length;
    container.lineBaseline.push(baseline);
    for (const item of line.items) {
      if (item.kind === K_ATABLE) {
        // A nested anonymous inline-table, laid out again where the line put it.
        layoutInlineTableRun(item.owner, item.run!, w, y + baseline - item.asc, [], x + item.x);
        continue;
      }
      if (item.kind === K_ATOMIC) {
        const c = item.style;
        c.x = x + item.x;
        c.y = y + baseline - atomicAscent(c, w);
        place(c);
        continue;
      }
      container.fragKind.push(item.kind === 0 ? 0 : 1);
      container.fragStyle.push(item.style);
      container.fragOwner.push(item.owner);
      container.fragText.push(item.kind === 0 ? item.text : item.kind === 2 ? "<" : ">");
      const a = baselineOffset(item.style);
      container.fragX.push(x + item.x);
      container.fragTop.push(y + baseline - a);
      container.fragW.push(item.w);
      container.fragLine.push(lineIndex);
    }
    top = baseline + below;
  }
  return top;
}
