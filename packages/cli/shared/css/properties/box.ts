// CSS display, positioning, sizing, margins, padding, box-sizing and overflow. Returns undefined for a property this module doesn't handle.

import * as P from "../../props.ts";
import { BORDER_COLORS, BORDER_SIDES, BORDER_WIDTHS, borderColor, borderColors, borderShorthand, borderStyles, borderWidth, borderWidths, cornerRadius } from "../borders.ts";
import { parseColor } from "../colors.ts";
import { colorDecl, kw, lengths, pair, parseLength, single } from "../declarations.ts";
import type { Len } from "../declarations.ts";
import { splitValue } from "../fonts.ts";
import { RowTable } from "../rows.ts";
import { boxShadow } from "../shadows.ts";
import type { Decl, FontContext } from "../types.ts";

/** The keywords `break-before` and `break-after` take, with the CSS 2.1 aliases. */
const BREAK_SIDE: Record<string, number> = {
  auto: P.BK_AUTO, avoid: P.BK_AVOID, "avoid-page": P.BK_AVOID_PAGE, "avoid-column": P.BK_AVOID_COLUMN,
  "avoid-region": P.BK_AVOID_REGION, page: P.BK_PAGE, column: P.BK_COLUMN, region: P.BK_REGION,
  left: P.BK_LEFT, right: P.BK_RIGHT, recto: P.BK_RECTO, verso: P.BK_VERSO,
  always: P.BK_PAGE, // CSS 2.1's page-break-before: always
};

/** The keywords `break-inside` takes. */
const BREAK_INSIDE: Record<string, number> = {
  auto: P.BK_AUTO, avoid: P.BK_AVOID, "avoid-page": P.BK_AVOID_PAGE, "avoid-column": P.BK_AVOID_COLUMN,
  "avoid-region": P.BK_AVOID_REGION,
};

export function boxProperty(prop: string, value: string, out: Decl[], fonts?: FontContext): string | null | undefined {
  switch (prop) {
    case "display": {
      // The two-keyword form of CSS Display 3, either way round: `inline flex`, `block grid`, …
      const two = /^(\S+)\s+(\S+)$/.exec(value.trim().toLowerCase());
      if (two !== null) {
        const pair: Record<string, number> = {
          "inline flex": P.D_INLINE_FLEX, "flex inline": P.D_INLINE_FLEX,
          "block flex": P.D_FLEX, "flex block": P.D_FLEX,
          "inline grid": P.D_INLINE_GRID, "grid inline": P.D_INLINE_GRID,
          "block grid": P.D_GRID, "grid block": P.D_GRID,
          "inline table": P.D_INLINE_TABLE, "table inline": P.D_INLINE_TABLE,
          "block table": P.D_TABLE, "table block": P.D_TABLE,
          "inline grid-lanes": P.D_INLINE_GRID_LANES, "grid-lanes inline": P.D_INLINE_GRID_LANES,
          "block grid-lanes": P.D_GRID_LANES, "grid-lanes block": P.D_GRID_LANES,
          "inline flow-root": P.D_INLINE_BLOCK, "flow-root inline": P.D_INLINE_BLOCK,
          "block flow-root": P.D_FLOW_ROOT, "flow-root block": P.D_FLOW_ROOT,
          "inline flow": P.D_INLINE, "flow inline": P.D_INLINE,
          "block flow": P.D_BLOCK, "flow block": P.D_BLOCK,
        };
        const d = pair[two[1] + " " + two[2]];
        if (d !== undefined) {
          out.push({ p: P.P_DISPLAY, v: d, u: P.U_NONE });
          return null;
        }
      }
      return kw(prop, value, {
        block: P.D_BLOCK, flex: P.D_FLEX, none: P.D_NONE, "inline-block": P.D_INLINE_BLOCK, inline: P.D_INLINE,
        "inline-flex": P.D_INLINE_FLEX, "list-item": P.D_LIST_ITEM, grid: P.D_GRID, "inline-grid": P.D_INLINE_GRID,
        "grid-lanes": P.D_GRID_LANES, "inline-grid-lanes": P.D_INLINE_GRID_LANES,
        "flow-root": P.D_FLOW_ROOT, contents: P.D_CONTENTS,
        // The vendor aliases earlier engines wrote for the same two layout modes.
        "-webkit-flex": P.D_FLEX, "-webkit-inline-flex": P.D_INLINE_FLEX,
        // The old webkit box is a block container; line-clamp works on it as on any block.
        "-webkit-box": P.D_BLOCK, "-webkit-inline-box": P.D_INLINE_BLOCK,
      }, P.P_DISPLAY, out);
    }
    case "break-before":
    case "break-after": {
      const p = prop === "break-before" ? P.P_BREAK_BEFORE : P.P_BREAK_AFTER;
      const k = BREAK_SIDE[value.trim().toLowerCase()];
      if (k === undefined) return `unsupported value '${value}' for '${prop}'`;
      out.push({ p, v: k, u: P.U_NONE });
      return null;
    }
    case "break-inside": {
      const k = BREAK_INSIDE[value.trim().toLowerCase()];
      if (k === undefined) return `unsupported value '${value}' for 'break-inside'`;
      out.push({ p: P.P_BREAK_INSIDE, v: k, u: P.U_NONE });
      return null;
    }
    case "orphans":
    case "widows": {
      const v = Number(value.trim());
      if (!Number.isInteger(v) || v < 1) return `unsupported value '${value}' for '${prop}'`;
      out.push({ p: prop === "orphans" ? P.P_ORPHANS : P.P_WIDOWS, v, u: P.U_NONE });
      return null;
    }
    case "print-color-adjust": {
      const k = value.trim().toLowerCase();
      if (k !== "economy" && k !== "exact") return `unsupported value '${value}' for 'print-color-adjust'`;
      out.push({ p: P.P_PRINT_COLOR_ADJUST, v: k === "exact" ? P.PCA_EXACT : P.PCA_ECONOMY, u: P.U_NONE });
      return null;
    }
    case "page": {
      const k = value.trim().toLowerCase();
      if (k === "auto") { out.push({ p: P.P_PAGE, v: -1, u: P.U_LIST }); return null; }
      if (!/^-?[a-z_][\w-]*$/i.test(k) || k === "auto") return `unsupported value '${value}' for 'page'`;
      const id = fonts === undefined || fonts.containerNames === undefined ? -1 : fonts.containerNames(k);
      if (id < 0) return `unsupported value '${value}' for 'page'`;
      out.push({ p: P.P_PAGE, v: id, u: P.U_LIST });
      return null;
    }
    case "scroll-marker-group":
      return kw(prop, value, {
        none: P.SG_NONE, before: P.SG_BEFORE, after: P.SG_AFTER,
      }, P.P_SCROLL_MARKER_GROUP, out);
    case "visibility":
      return kw(prop, value, {
        visible: P.VIS_VISIBLE, hidden: P.VIS_HIDDEN, collapse: P.VIS_COLLAPSE,
      }, P.P_VISIBILITY, out);
    case "-webkit-box-orient":
      // A vertical box is what a block container already is; the other orientations are no
      // different from it here.
      return null;
    case "position":
      return kw(prop, value, {
        static: P.POS_STATIC, relative: P.POS_RELATIVE, absolute: P.POS_ABSOLUTE, fixed: P.POS_FIXED,
        sticky: P.POS_STICKY,
      }, P.P_POSITION, out);
    case "z-index":
      if (value.toLowerCase() === "auto") {
        out.push({ p: P.P_Z_INDEX, v: 0, u: P.U_AUTO });
        return null;
      }
      if (/^[-+]?\d+$/.test(value)) {
        out.push({ p: P.P_Z_INDEX, v: parseInt(value, 10), u: P.U_NONE });
        return null;
      }
      return `invalid value '${value}' for 'z-index'`;
    // The logical margins, padding and offsets name a side of the box's own axes; which physical
    // side that is depends on the writing mode and direction, so the runtime settles it after the
    // cascade (see resolveLogicalSides in style.ts).
    case "margin-block-start":
      return single(prop, value, P.P_MARGIN_BLOCK_START, true, out);
    case "margin-block-end":
      return single(prop, value, P.P_MARGIN_BLOCK_END, true, out);
    case "margin-inline-start":
      return single(prop, value, P.P_MARGIN_INLINE_START, true, out);
    case "margin-inline-end":
      return single(prop, value, P.P_MARGIN_INLINE_END, true, out);
    case "margin-block":
      return pair(prop, value, P.P_MARGIN_BLOCK_START, P.P_MARGIN_BLOCK_END, true, out);
    case "margin-inline":
      return pair(prop, value, P.P_MARGIN_INLINE_START, P.P_MARGIN_INLINE_END, true, out);
    case "padding-block-start":
      return single(prop, value, P.P_PADDING_BLOCK_START, false, out, true);
    case "padding-block-end":
      return single(prop, value, P.P_PADDING_BLOCK_END, false, out, true);
    case "padding-inline-start":
      return single(prop, value, P.P_PADDING_INLINE_START, false, out, true);
    case "padding-inline-end":
      return single(prop, value, P.P_PADDING_INLINE_END, false, out, true);
    case "padding-block":
      return pair(prop, value, P.P_PADDING_BLOCK_START, P.P_PADDING_BLOCK_END, false, out, true);
    case "padding-inline":
      return pair(prop, value, P.P_PADDING_INLINE_START, P.P_PADDING_INLINE_END, false, out, true);
    case "inset-block-start":
      return single(prop, value, P.P_INSET_BLOCK_START, true, out);
    case "inset-block-end":
      return single(prop, value, P.P_INSET_BLOCK_END, true, out);
    case "inset-inline-start":
      return single(prop, value, P.P_INSET_INLINE_START, true, out);
    case "inset-inline-end":
      return single(prop, value, P.P_INSET_INLINE_END, true, out);
    case "inset-block":
      return pair(prop, value, P.P_INSET_BLOCK_START, P.P_INSET_BLOCK_END, true, out);
    case "inset-inline":
      return pair(prop, value, P.P_INSET_INLINE_START, P.P_INSET_INLINE_END, true, out);
    case "inset":
      return lengths(prop, value, [P.P_TOP, P.P_RIGHT, P.P_BOTTOM, P.P_LEFT], true, out);
    case "top":
      return single(prop, value, P.P_TOP, true, out);
    case "right":
      return single(prop, value, P.P_RIGHT, true, out);
    case "bottom":
      return single(prop, value, P.P_BOTTOM, true, out);
    case "left":
      return single(prop, value, P.P_LEFT, true, out);
    case "width":
      return single(prop, value, P.P_WIDTH, true, out, true, true);
    case "height":
      return single(prop, value, P.P_HEIGHT, true, out, true, true);
    case "min-width":
      return single(prop, value, P.P_MIN_WIDTH, false, out, true, true);
    case "min-height":
      return single(prop, value, P.P_MIN_HEIGHT, false, out, true, true);
    case "max-width":
      return value === "none" ? (out.push({ p: P.P_MAX_WIDTH, v: 0, u: P.U_AUTO }), null) : single(prop, value, P.P_MAX_WIDTH, false, out, true, true);
    case "max-height":
      return value === "none" ? (out.push({ p: P.P_MAX_HEIGHT, v: 0, u: P.U_AUTO }), null) : single(prop, value, P.P_MAX_HEIGHT, false, out, true, true);
    // A logical size names a width or height by the box's own axes; the runtime settles which
    // once the element's writing mode is known.
    case "inline-size":
      return single(prop, value, P.P_INLINE_SIZE, true, out, true, true);
    case "block-size":
      return single(prop, value, P.P_BLOCK_SIZE, true, out, true, true);
    case "min-inline-size":
      return single(prop, value, P.P_MIN_INLINE_SIZE, false, out, true, true);
    case "min-block-size":
      return single(prop, value, P.P_MIN_BLOCK_SIZE, false, out, true, true);
    case "max-inline-size":
      return value === "none" ? (out.push({ p: P.P_MAX_INLINE_SIZE, v: 0, u: P.U_AUTO }), null) : single(prop, value, P.P_MAX_INLINE_SIZE, false, out, true, true);
    case "max-block-size":
      return value === "none" ? (out.push({ p: P.P_MAX_BLOCK_SIZE, v: 0, u: P.U_AUTO }), null) : single(prop, value, P.P_MAX_BLOCK_SIZE, false, out, true, true);
    // A logical corner names a physical one by its block and inline sides; the runtime settles
    // which corner that is once the element's writing mode and direction are known.
    case "border-start-start-radius":
      return cornerRadius(prop, value, [P.P_BORDER_START_START_RADIUS, P.P_BORDER_START_START_RADIUS_Y], out);
    case "border-start-end-radius":
      return cornerRadius(prop, value, [P.P_BORDER_START_END_RADIUS, P.P_BORDER_START_END_RADIUS_Y], out);
    case "border-end-start-radius":
      return cornerRadius(prop, value, [P.P_BORDER_END_START_RADIUS, P.P_BORDER_END_START_RADIUS_Y], out);
    case "border-end-end-radius":
      return cornerRadius(prop, value, [P.P_BORDER_END_END_RADIUS, P.P_BORDER_END_END_RADIUS_Y], out);
    case "aspect-ratio":
      return aspectRatio(value, out);
    case "margin":
      return lengths(prop, value, [P.P_MARGIN_TOP, P.P_MARGIN_RIGHT, P.P_MARGIN_BOTTOM, P.P_MARGIN_LEFT], true, out);
    case "padding":
      return lengths(prop, value, [P.P_PADDING_TOP, P.P_PADDING_RIGHT, P.P_PADDING_BOTTOM, P.P_PADDING_LEFT], false, out, true);
    case "margin-top":
      return single(prop, value, P.P_MARGIN_TOP, true, out);
    case "margin-right":
      return single(prop, value, P.P_MARGIN_RIGHT, true, out);
    case "margin-bottom":
      return single(prop, value, P.P_MARGIN_BOTTOM, true, out);
    case "margin-left":
      return single(prop, value, P.P_MARGIN_LEFT, true, out);
    case "padding-top":
      return single(prop, value, P.P_PADDING_TOP, false, out, true);
    case "padding-right":
      return single(prop, value, P.P_PADDING_RIGHT, false, out, true);
    case "padding-bottom":
      return single(prop, value, P.P_PADDING_BOTTOM, false, out, true);
    case "padding-left":
      return single(prop, value, P.P_PADDING_LEFT, false, out, true);
    // The insets a scroll stops short by: the margin belongs to the box being brought into view
    // and takes `auto` (a zero here), the padding to the container it scrolls in and doesn't.
    case "scroll-margin":
      return lengths(prop, value, [P.P_SCROLL_MARGIN_TOP, P.P_SCROLL_MARGIN_RIGHT,
        P.P_SCROLL_MARGIN_BOTTOM, P.P_SCROLL_MARGIN_LEFT], true, out);
    case "scroll-margin-top":
      return single(prop, value, P.P_SCROLL_MARGIN_TOP, true, out);
    case "scroll-margin-right":
      return single(prop, value, P.P_SCROLL_MARGIN_RIGHT, true, out);
    case "scroll-margin-bottom":
      return single(prop, value, P.P_SCROLL_MARGIN_BOTTOM, true, out);
    case "scroll-margin-left":
      return single(prop, value, P.P_SCROLL_MARGIN_LEFT, true, out);
    case "scroll-padding":
      return lengths(prop, value, [P.P_SCROLL_PADDING_TOP, P.P_SCROLL_PADDING_RIGHT,
        P.P_SCROLL_PADDING_BOTTOM, P.P_SCROLL_PADDING_LEFT], false, out, true);
    case "scroll-padding-top":
      return single(prop, value, P.P_SCROLL_PADDING_TOP, false, out, true);
    case "scroll-padding-right":
      return single(prop, value, P.P_SCROLL_PADDING_RIGHT, false, out, true);
    case "scroll-padding-bottom":
      return single(prop, value, P.P_SCROLL_PADDING_BOTTOM, false, out, true);
    case "scroll-padding-left":
      return single(prop, value, P.P_SCROLL_PADDING_LEFT, false, out, true);
    // The same insets in the box's own frame: the runtime settles them onto the physical sides
    // once the element's writing mode and direction are known.
    case "scroll-margin-block-start":
      return single(prop, value, P.P_SCROLL_MARGIN_BLOCK_START, true, out);
    case "scroll-margin-block-end":
      return single(prop, value, P.P_SCROLL_MARGIN_BLOCK_END, true, out);
    case "scroll-margin-inline-start":
      return single(prop, value, P.P_SCROLL_MARGIN_INLINE_START, true, out);
    case "scroll-margin-inline-end":
      return single(prop, value, P.P_SCROLL_MARGIN_INLINE_END, true, out);
    case "scroll-margin-block":
      return pair(prop, value, P.P_SCROLL_MARGIN_BLOCK_START, P.P_SCROLL_MARGIN_BLOCK_END, true, out);
    case "scroll-margin-inline":
      return pair(prop, value, P.P_SCROLL_MARGIN_INLINE_START, P.P_SCROLL_MARGIN_INLINE_END, true, out);
    case "scroll-padding-block-start":
      return single(prop, value, P.P_SCROLL_PADDING_BLOCK_START, false, out, true);
    case "scroll-padding-block-end":
      return single(prop, value, P.P_SCROLL_PADDING_BLOCK_END, false, out, true);
    case "scroll-padding-inline-start":
      return single(prop, value, P.P_SCROLL_PADDING_INLINE_START, false, out, true);
    case "scroll-padding-inline-end":
      return single(prop, value, P.P_SCROLL_PADDING_INLINE_END, false, out, true);
    case "scroll-padding-block":
      return pair(prop, value, P.P_SCROLL_PADDING_BLOCK_START, P.P_SCROLL_PADDING_BLOCK_END, false, out, true);
    case "scroll-padding-inline":
      return pair(prop, value, P.P_SCROLL_PADDING_INLINE_START, P.P_SCROLL_PADDING_INLINE_END, false, out, true);
    case "float":
      // The logical values follow the writing mode, which is always left-to-right here.
      return kw(prop, value === "inline-start" ? "left" : value === "inline-end" ? "right" : value,
        { none: P.FL_NONE, left: P.FL_LEFT, right: P.FL_RIGHT }, P.P_FLOAT, out);
    case "clear":
      return kw(prop, value === "inline-start" ? "left" : value === "inline-end" ? "right" : value,
        { none: P.CL_NONE, left: P.CL_LEFT, right: P.CL_RIGHT, both: P.CL_BOTH }, P.P_CLEAR, out);
    case "box-sizing":
      return kw(prop, value, { "content-box": P.BS_CONTENT, "border-box": P.BS_BORDER }, P.P_BOX_SIZING, out);
    case "box-shadow":
      return boxShadow(prop, value, out, fonts);
    case "margin-trim": {
      const parts = value.trim().toLowerCase().split(/\s+/);
      const table: Record<string, number> = {
        block: P.MT_BLOCK, inline: P.MT_INLINE, "block-start": P.MT_BLOCK_START,
        "block-end": P.MT_BLOCK_END, "inline-start": P.MT_INLINE_START, "inline-end": P.MT_INLINE_END,
      };
      if (parts.length === 1 && parts[0] === "none") {
        out.push({ p: P.P_MARGIN_TRIM, v: P.MT_NONE, u: P.U_NONE });
        return null;
      }
      let bits = 0;
      for (const t of parts) {
        const bit = table[t];
        if (bit === undefined || (bits & bit) !== 0) {
          return `unsupported value '${value}' for 'margin-trim' (none, or some of ${Object.keys(table).join(", ")})`;
        }
        bits |= bit;
      }
      out.push({ p: P.P_MARGIN_TRIM, v: bits, u: P.U_NONE });
      return null;
    }
    case "content-visibility":
      // `hidden` skips the box's content entirely; `auto` may skip it while off screen, which
      // this build doesn't track, so it behaves as `visible`.
      return kw(prop, value, { visible: P.CV_VISIBLE, auto: P.CV_AUTO, hidden: P.CV_HIDDEN },
        P.P_CONTENT_VISIBILITY, out);
    case "box-decoration-break":
    case "-webkit-box-decoration-break":
      return kw("box-decoration-break", value, { slice: P.BDB_SLICE, clone: P.BDB_CLONE },
        P.P_BOX_DECORATION_BREAK, out);
    case "scroll-snap-align": {
      // One keyword sets both axes; two set the block axis then the inline one.
      const parts = value.trim().toLowerCase().split(/\s+/);
      const table: Record<string, number> = { none: P.SSA_NONE, start: P.SSA_START, end: P.SSA_END, center: P.SSA_CENTER };
      if (parts.length > 2 || table[parts[0]] === undefined ||
        (parts.length > 1 && table[parts[1]] === undefined)) {
        return `unsupported value '${value}' for 'scroll-snap-align' (none, start, end or center, once or per axis)`;
      }
      out.push({ p: P.P_SCROLL_SNAP_ALIGN, v: table[parts[0]], u: P.U_NONE });
      out.push({ p: P.P_SCROLL_SNAP_ALIGN_INLINE, v: parts.length > 1 ? table[parts[1]] : table[parts[0]], u: P.U_NONE });
      return null;
    }
    case "scroll-snap-stop":
      return kw(prop, value, { normal: P.SSS_NORMAL, always: P.SSS_ALWAYS }, P.P_SCROLL_SNAP_STOP, out);
    case "scrollbar-gutter": {
      const parts = value.trim().toLowerCase().split(/\s+/);
      const v = parts.length === 1 && parts[0] === "auto" ? P.SBG_AUTO
        : parts.length === 1 && parts[0] === "stable" ? P.SBG_STABLE
        : parts.length === 2 && parts[0] === "stable" && parts[1] === "both-edges" ? P.SBG_BOTH
        : -1;
      if (v < 0) return `unsupported value '${value}' for 'scrollbar-gutter' (auto, stable or stable both-edges)`;
      out.push({ p: P.P_SCROLLBAR_GUTTER, v, u: P.U_NONE });
      return null;
    }
    case "scrollbar-width":
      // A scrollbar the platform draws at its own width, a thinner one, or none at all.
      return kw(prop, value, { auto: P.SBW_AUTO, thin: P.SBW_THIN, none: P.SBW_NONE }, P.P_SCROLLBAR_WIDTH, out);
    case "scrollbar-color": {
      // `auto`, or a thumb colour then a track colour.
      const parts = value.trim().split(/\s+/);
      if (parts.length === 1 && parts[0].toLowerCase() === "auto") {
        out.push({ p: P.P_SCROLLBAR_COLOR, v: -1, u: P.U_NONE });
        out.push({ p: P.P_SCROLLBAR_COLOR_TRACK, v: -1, u: P.U_NONE });
        return null;
      }
      const thumb = parts.length === 2 ? parseColor(parts[0]) : null;
      const track = parts.length === 2 ? parseColor(parts[1]) : null;
      if (thumb === null || track === null) {
        return `unsupported value '${value}' for 'scrollbar-color' (auto, or a thumb and track colour)`;
      }
      out.push({ p: P.P_SCROLLBAR_COLOR, v: thumb, u: P.U_NONE });
      out.push({ p: P.P_SCROLLBAR_COLOR_TRACK, v: track, u: P.U_NONE });
      return null;
    }
    case "overscroll-behavior":
    case "overscroll-behavior-x":
    case "overscroll-behavior-y":
    case "overscroll-behavior-block":
    case "overscroll-behavior-inline": {
      const table: Record<string, number> = { auto: P.OVS_AUTO, contain: P.OVS_CONTAIN, none: P.OVS_NONE };
      const set = (tok: string, id: number): string | null => {
        const v = table[tok];
        if (v === undefined) return `unsupported value '${value}' for '${prop}' (auto, contain or none)`;
        out.push({ p: id, v, u: P.U_NONE });
        return null;
      };
      const parts = value.trim().split(/\s+/);
      // The shorthand writes both physical axes: one keyword sets them alike, two set x then y.
      if (prop === "overscroll-behavior") {
        if (parts.length > 2) return `unsupported value '${value}' for 'overscroll-behavior' (one or two keywords)`;
        const x = set(parts[0], P.P_OVERSCROLL_BEHAVIOR_X);
        if (x !== null) return x;
        return set(parts.length > 1 ? parts[1] : parts[0], P.P_OVERSCROLL_BEHAVIOR_Y);
      }
      if (parts.length > 1) return `unsupported value '${value}' for '${prop}' (one keyword)`;
      const id = prop === "overscroll-behavior-x" ? P.P_OVERSCROLL_BEHAVIOR_X
        : prop === "overscroll-behavior-y" ? P.P_OVERSCROLL_BEHAVIOR_Y
        : prop === "overscroll-behavior-block" ? P.P_OVERSCROLL_BEHAVIOR_BLOCK
        : P.P_OVERSCROLL_BEHAVIOR_INLINE;
      return set(parts[0], id);
    }
    case "overflow":
    case "overflow-y":
    case "overflow-x":
      {
      const parts = value.split(/\s+/);
      const table: Record<string, number> = { visible: P.OV_VISIBLE, hidden: P.OV_HIDDEN, auto: P.OV_AUTO, scroll: P.OV_SCROLL, clip: P.OV_CLIP };
      // `overflow` writes both axes: one keyword sets them alike, two set x then y.
      const x = parts[0];
      const y = prop === "overflow" && parts.length > 1 ? parts[1] : x;
      if ((prop === "overflow" && parts.length > 2) || table[x] === undefined ||
        (prop === "overflow" && table[y] === undefined)) {
        return `unsupported value '${value}' for '${prop}' (supported: ${Object.keys(table).join(", ")})`;
      }
      if (prop !== "overflow-y") out.push({ p: P.P_OVERFLOW_X, v: table[x], u: P.U_NONE });
      if (prop !== "overflow-x") out.push({ p: P.P_OVERFLOW_Y, v: table[y], u: P.U_NONE });
      return null;
    }
    case "overflow-clip-margin":
      return clipMargin(prop, value, out);
    default:
      return undefined;
  }
}

/**
 * overflow-clip-margin: a visual box (padding-box unless named) and a length, in either order,
 * one of each. The length takes no percentage (CSS Overflow 3); it may be negative, and the clip
 * then shrinks, as in a browser.
 */
function clipMargin(prop: string, value: string, out: Decl[]): string | null {
  const parts = value.trim().toLowerCase().split(/\s+/);
  let box: number | null = null;
  let length: Len | null = null;
  for (const part of parts) {
    if (part === "") continue;
    const named = part === "content-box" ? P.OCM_CONTENT_BOX
      : part === "padding-box" ? P.OCM_PADDING_BOX
        : part === "border-box" ? P.OCM_BORDER_BOX : -1;
    if (named >= 0) {
      if (box !== null) return `invalid value '${value}' for '${prop}'`;
      box = named;
      continue;
    }
    const len = parseLength(part, false);
    if (len === null || len.u === P.U_PCT || length !== null) {
      return `unsupported value '${value}' for '${prop}' (a visual box and a length, such as 'content-box 5px')`;
    }
    length = len;
  }
  const b = box === null ? P.OCM_PADDING_BOX : box;
  const v = length === null ? 0 : length.v;
  const u = length === null ? P.U_PX : length.u;
  out.push({ p: P.P_OVERFLOW_CLIP_MARGIN, v: clipMarginRows.register([b, v, u]), u: P.U_LIST });
  return null;
}

/** The overflow-clip-margin rows, by value id (see shared/css/rows.ts). */
export const clipMarginRows: RowTable = new RowTable();

/**
 * aspect-ratio: `auto`, a <ratio> such as `16 / 9` or `1.5`, or both in either order. The ratio
 * is stored as one number (width / height); a ratio with a zero or infinite side is no ratio.
 */
function aspectRatio(value: string, out: Decl[]): string | null {
  const parts = value.trim().toLowerCase().replace(/\s*\/\s*/g, " / ").split(/\s+/);
  let auto = 0;
  let slashes = 0;
  const nums: number[] = [];
  for (const part of parts) {
    if (part === "") continue;
    if (part === "auto") auto = 1;
    else if (part === "/") slashes++;
    else if (/^[0-9]*\.?[0-9]+$/.test(part)) nums.push(parseFloat(part));
    else return `invalid value '${value}' for 'aspect-ratio'`;
  }
  if (nums.length > 2 || slashes > 1 || (slashes === 1 && nums.length !== 2)) {
    return `invalid value '${value}' for 'aspect-ratio'`;
  }
  // A ratio with a zero or infinite side isn't one: `0 / 1` leaves the box without a ratio.
  const den = nums.length > 1 ? nums[1] : 1;
  const ratio = nums.length > 0 && nums[0] > 0 && den > 0 ? nums[0] / den : 0;
  out.push({ p: P.P_ASPECT_RATIO, v: ratio, u: P.U_NONE });
  out.push({ p: P.P_ASPECT_RATIO_AUTO, v: auto, u: P.U_NONE });
  return null;
}
