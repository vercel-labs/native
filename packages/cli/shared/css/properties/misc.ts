// CSS cursor, opacity and the SVG paint properties. Returns undefined for a property this module
// doesn't handle.

import * as P from "../../props.ts";
import { BORDER_COLORS, BORDER_SIDES, BORDER_WIDTHS, borderColor, borderColors, borderShorthand, borderStyles, borderWidth, borderWidths } from "../borders.ts";
import { parseColor } from "../colors.ts";
import { contentProperty } from "../content.ts";
import { colorDecl, kw, lengths, parseLength, single } from "../declarations.ts";
import type { Len } from "../declarations.ts";
import { clipRows } from "../clip.ts";
import { WC_LIST_AUTO, WC_LIST_CONTENTS, WC_LIST_SCROLL_POSITION, willChangeRows } from "../willchange.ts";
import { dashLen, dashRows, parseDashArray } from "../dasharray.ts";
import { splitValue } from "../fonts.ts";
import type { ContentContext, Decl, FontContext, Loc } from "../types.ts";

const NUMBER = /^-?[\d.]+$/;

const CURSOR_KEYWORDS: Record<string, number> = {
  auto: P.C_DEFAULT, default: P.C_DEFAULT, pointer: P.C_POINTER, text: P.C_TEXT,
  "context-menu": P.C_CONTEXT_MENU, help: P.C_HELP, progress: P.C_PROGRESS, wait: P.C_WAIT,
  cell: P.C_CELL, crosshair: P.C_CROSSHAIR, "vertical-text": P.C_VERTICAL_TEXT, alias: P.C_ALIAS,
  copy: P.C_COPY, move: P.C_MOVE, "no-drop": P.C_NO_DROP, "not-allowed": P.C_NOT_ALLOWED,
  grab: P.C_GRAB, grabbing: P.C_GRABBING, "all-scroll": P.C_ALL_SCROLL, "col-resize": P.C_COL_RESIZE,
  "row-resize": P.C_ROW_RESIZE, "n-resize": P.C_N_RESIZE, "e-resize": P.C_E_RESIZE,
  "s-resize": P.C_S_RESIZE, "w-resize": P.C_W_RESIZE, "ne-resize": P.C_NE_RESIZE,
  "nw-resize": P.C_NW_RESIZE, "se-resize": P.C_SE_RESIZE, "sw-resize": P.C_SW_RESIZE,
  "ew-resize": P.C_EW_RESIZE, "ns-resize": P.C_NS_RESIZE, "nesw-resize": P.C_NESW_RESIZE,
  "nwse-resize": P.C_NWSE_RESIZE, "zoom-in": P.C_ZOOM_IN, "zoom-out": P.C_ZOOM_OUT,
};

/**
 * `cursor`: a keyword, or a list of `url()` images with an optional hotspot, ending in the
 * keyword to fall back to. The image part needs a host cursor made from an image, which isn't
 * here yet, so a list takes its fallback keyword.
 */
function cursorValue(prop: string, value: string, out: Decl[], fonts?: FontContext, loc?: Loc): string | null {
  // A comma separates the images from each other and from the keyword, and attaches to the token
  // before it ("2," when the hotspot is the last thing before the comma).
  const toks = splitValue(value.trim()).map((t) => t.endsWith(",") ? t.slice(0, -1) : t).filter((t) => t !== "");
  if (toks.length === 0) return `unsupported ${prop} '${value}'`;
  const fallback = toks[toks.length - 1].toLowerCase();
  if (CURSOR_KEYWORDS[fallback] === undefined) {
    return `unsupported ${prop} '${value}' (a cursor keyword, or url() images before one)`;
  }
  // The keyword is the fallback, and the first image before it, if one parses, is the cursor.
  out.push({ p: P.P_CURSOR, v: CURSOR_KEYWORDS[fallback], u: P.U_NONE });
  const items = toks.slice(0, toks.length - 1);
  for (let i = 0; i < items.length;) {
    const m = /^url\(\s*(['"]?)([^'")]*)\1\s*\)$/i.exec(items[i]);
    if (m === null) return `unsupported ${prop} '${value}' (a cursor keyword, or url() images before one)`;
    i++;
    // An image may carry a hotspot: two numbers, x then y, in the image's own pixels.
    let hx = 0, hy = 0;
    if (i < items.length && NUMBER.test(items[i])) {
      hx = Math.max(0, Number(items[i]));
      i++;
      if (i < items.length && NUMBER.test(items[i])) {
        hy = Math.max(0, Number(items[i]));
        i++;
      }
    }
    const id = fonts === undefined ? -1 : fonts.image(m[2], loc ? loc[0] : 0, loc ? loc[1] : 0);
    if (id < 0) continue; // not a file this build has: the fallback keyword carries the cursor
    out.push({ p: P.P_CURSOR_IMAGE, v: id, u: P.U_NONE });
    out.push({ p: P.P_CURSOR_IMAGE_X, v: hx, u: P.U_PX });
    out.push({ p: P.P_CURSOR_IMAGE_Y, v: hy, u: P.U_PX });
    return null;
  }
  return null;
}

export function miscProperty(prop: string, value: string, out: Decl[], fonts?: FontContext, _loc?: Loc, content?: ContentContext): string | null | undefined {
  switch (prop) {
    case "content":
      return contentProperty(prop, value, out, content);
    case "app-region":
    case "-webkit-app-region":
      // `drag` makes the area move the window when it's pressed; `no-drag` keeps a control inside
      // a drag area clickable. Only the pressed element's nearest app-region counts.
      return kw("app-region", value, { none: P.AR_NONE, drag: P.AR_DRAG, "no-drag": P.AR_NO_DRAG }, P.P_APP_REGION, out);
    case "cursor":
      return cursorValue(prop, value, out, fonts, _loc);
    case "scroll-snap-type":
      return snapType(value, out);
    case "scroll-behavior":
      // Whether a scroll a script asks for travels (`smooth`) or jumps there (`auto`).
      return kw(prop, value, { auto: P.SB_AUTO, smooth: P.SB_SMOOTH }, P.P_SCROLL_BEHAVIOR, out);
    case "pointer-events":
      // `none` is see-through to the pointer; a widget or SVG keyword hits as `auto` does.
      return kw("pointer-events", value, POINTER_EVENTS_KEYWORDS, P.P_POINTER_EVENTS, out);
    case "user-select":
    case "-webkit-user-select":
      // `contain` is the one keyword not taken: it needs a selection that can cross an element,
      // which is not something native has.
      return kw("user-select", value, USER_SELECT_KEYWORDS, P.P_USER_SELECT, out);
    case "appearance":
    case "-webkit-appearance":
      // `none` hands the control's box to the author; a widget keyword paints it as `auto` does.
      return kw("appearance", value, APPEARANCE_KEYWORDS, P.P_APPEARANCE, out);
    case "accent-color": {
      const raw = value.trim().toLowerCase();
      if (raw === "auto") {
        out.push({ p: P.P_ACCENT_COLOR, v: -1, u: P.U_NONE });
        return null;
      }
      const c = parseColor(raw);
      if (c === null) return `unsupported accent-color '${value}' (a colour or auto)`;
      out.push({ p: P.P_ACCENT_COLOR, v: c, u: P.U_NONE });
      return null;
    }
    case "caret-color": {
      // The caret's colour: `auto` (the field's text colour), `currentColor`, or a colour.
      const raw = value.trim().toLowerCase();
      if (raw === "auto") {
        out.push({ p: P.P_CARET_COLOR, v: -1, u: P.U_NONE });
        return null;
      }
      if (raw === "currentcolor") {
        out.push({ p: P.P_CARET_COLOR, v: -2, u: P.U_NONE });
        return null;
      }
      const caret = parseColor(raw);
      if (caret === null) return `unsupported caret-color '${value}' (a colour, currentColor or auto)`;
      out.push({ p: P.P_CARET_COLOR, v: caret, u: P.U_NONE });
      return null;
    }
    case "caret-shape":
      return kw("caret-shape", value, {
        auto: P.CSP_AUTO, bar: P.CSP_BAR, block: P.CSP_BLOCK, underscore: P.CSP_UNDERSCORE,
      }, P.P_CARET_SHAPE, out);
    case "resize":
      // Which edges the user can drag: the bits stand for the horizontal and the vertical one.
      return kw("resize", value, {
        none: 0, both: P.RESIZE_H | P.RESIZE_V, horizontal: P.RESIZE_H, vertical: P.RESIZE_V,
      }, P.P_RESIZE, out);
    case "interactivity":
      return kw("interactivity", value, { auto: P.IA_AUTO, inert: P.IA_INERT }, P.P_INTERACTIVITY, out);
    case "touch-action": {
      // auto, none or manipulation stand alone; otherwise a list of pan edges and pinch-zoom.
      // The bits record what a touch may do; this runtime has a pointer and no touchscreen.
      const words = value.trim().toLowerCase().split(/\s+/).filter((w) => w !== "");
      if (words.length === 1 && (words[0] === "auto" || words[0] === "none" || words[0] === "manipulation")) {
        const bits = words[0] === "auto" ? P.TA_AUTO : words[0] === "none" ? P.TA_NONE
          : P.TA_PAN_LEFT | P.TA_PAN_RIGHT | P.TA_PAN_UP | P.TA_PAN_DOWN | P.TA_PINCH_ZOOM;
        out.push({ p: P.P_TOUCH_ACTION, v: bits, u: P.U_NONE });
        return null;
      }
      let bits = 0;
      for (const word of words) {
        if (word === "pan-x") bits |= P.TA_PAN_LEFT | P.TA_PAN_RIGHT;
        else if (word === "pan-left") bits |= P.TA_PAN_LEFT;
        else if (word === "pan-right") bits |= P.TA_PAN_RIGHT;
        else if (word === "pan-y") bits |= P.TA_PAN_UP | P.TA_PAN_DOWN;
        else if (word === "pan-up") bits |= P.TA_PAN_UP;
        else if (word === "pan-down") bits |= P.TA_PAN_DOWN;
        else if (word === "pinch-zoom") bits |= P.TA_PINCH_ZOOM;
        else return `unsupported touch-action '${value}'`;
      }
      if (bits === 0) return `unsupported touch-action '${value}'`;
      out.push({ p: P.P_TOUCH_ACTION, v: bits, u: P.U_NONE });
      return null;
    }
    case "color-scheme": {
      // `normal`, or a list of `light` and `dark` (with `only` allowed, which changes nothing
      // here because the page is the only document). The bits record which schemes are named.
      let bits = 0;
      for (const word of value.trim().toLowerCase().split(/\s+/)) {
        if (word === "normal") {
          if (value.trim().toLowerCase() !== "normal") return `unsupported color-scheme '${value}'`;
          bits = 0;
          continue;
        }
        if (word === "only") continue;
        if (word === "light") bits |= P.CS_LIGHT;
        else if (word === "dark") bits |= P.CS_DARK;
        else return `unsupported color-scheme '${value}'`;
      }
      out.push({ p: P.P_COLOR_SCHEME, v: bits, u: P.U_NONE });
      return null;
    }
    case "opacity":
      {
      // A percentage is the number it stands for: 75% is 0.75.
      const raw = value.trim();
      const pct = raw.endsWith("%");
      const n = Number(pct ? raw.slice(0, -1) : raw);
      if (!Number.isFinite(n) || raw === "") return `unsupported opacity '${value}'`;
      out.push({ p: P.P_OPACITY, v: Math.max(0, Math.min(1, pct ? n / 100 : n)), u: 0 });
      return null;
    }
    case "color-interpolation-filters":
      return kw(prop, value, { auto: P.ICF_AUTO, srgb: P.ICF_SRGB, linearrgb: P.ICF_LINEARRGB },
        P.P_COLOR_INTERPOLATION_FILTERS, out);
    // The SVG filter colours and the light a feDiffuseLighting primitive gives off.
    case "flood-color":
    case "lighting-color": {
      const c = parseColor(value.trim());
      if (c === null) return `unsupported ${prop} '${value}'`;
      out.push({ p: prop === "flood-color" ? P.P_FLOOD_COLOR : P.P_LIGHTING_COLOR, v: c, u: P.U_NONE });
      return null;
    }
    case "flood-opacity":
    case "shape-image-threshold": {
      const raw = value.trim();
      const pct = raw.endsWith("%");
      const n = Number(pct ? raw.slice(0, -1) : raw);
      if (!Number.isFinite(n) || raw === "") return `unsupported ${prop} '${value}'`;
      out.push({ p: prop === "flood-opacity" ? P.P_FLOOD_OPACITY : P.P_SHAPE_IMAGE_THRESHOLD,
        v: Math.max(0, Math.min(1, pct ? n / 100 : n)), u: P.U_NONE });
      return null;
    }
    case "will-change": {
      // A comma-separated list of property names, or the keywords auto, contents and
      // scroll-position (auto stands alone).
      const row: number[] = [];
      for (const part of value.split(",")) {
        const name = part.trim().toLowerCase();
        if (name === "") return `unsupported will-change '${value}'`;
        if (name === "auto") row.push(WC_LIST_AUTO);
        else if (name === "contents") row.push(WC_LIST_CONTENTS);
        else if (name === "scroll-position") row.push(WC_LIST_SCROLL_POSITION);
        else {
          const pid = /^[a-z-]+$/.test(name) ? P.propId(name) : -1;
          if (pid < 0) return `unsupported will-change '${value}' (not a property name this build knows)`;
          row.push(pid);
        }
      }
      out.push({ p: P.P_WILL_CHANGE, v: willChangeRows.register(row), u: P.U_LIST });
      return null;
    }
    // SVG painting: a colour, `currentColor`, `none` or a paint server (`url(#id)`).
    case "fill":
    case "stroke": {
      const ref = paintRef(value);
      let paint: number | null;
      if (ref !== null) {
        // The paint URL table belongs to the app, which the context knows; without one the
        // reference still gets an index, and the painter finds no server for it.
        paint = P.PAINT_URL - (fonts === undefined ? 0 : Math.max(0, fonts.paint(ref)));
      } else {
        paint = paintValue(value);
      }
      if (paint === null) return `unsupported ${prop} '${value}' (a colour, currentColor, none or url(#id))`;
      out.push({ p: prop === "fill" ? P.P_FILL : P.P_STROKE, v: paint, u: P.U_NONE });
      return null;
    }
    case "fill-opacity":
    case "stroke-opacity": {
      const raw = value.trim();
      const pct = raw.endsWith("%");
      const n = Number(pct ? raw.slice(0, -1) : raw);
      if (!Number.isFinite(n) || raw === "") return `unsupported ${prop} '${value}'`;
      out.push({ p: prop === "fill-opacity" ? P.P_FILL_OPACITY : P.P_STROKE_OPACITY,
        v: Math.max(0, Math.min(1, pct ? n / 100 : n)), u: P.U_NONE });
      return null;
    }
    case "stroke-width": {
      // SVG writes a bare number for a length in user units; CSS Transforms' SVG rules take it too.
      const bare = /^(\d+\.?\d*|\.\d+)$/.exec(value.trim());
      if (bare !== null) {
        out.push({ p: P.P_STROKE_WIDTH, v: parseFloat(bare[1]), u: P.U_PX });
        return null;
      }
      return single(prop, value, P.P_STROKE_WIDTH, false, out, true);
    }
    case "stroke-linecap":
      return kw(prop, value, { butt: P.SLC_BUTT, round: P.SLC_ROUND, square: P.SLC_SQUARE }, P.P_STROKE_LINECAP, out);
    case "stroke-linejoin":
      return kw(prop, value, { miter: P.SLJ_MITER, round: P.SLJ_ROUND, bevel: P.SLJ_BEVEL }, P.P_STROKE_LINEJOIN, out);
    case "fill-rule":
      return kw(prop, value, { nonzero: P.FR_NONZERO, evenodd: P.FR_EVENODD }, P.P_FILL_RULE, out);
    // The dash pattern a stroke is broken into, and how far into it the stroke starts. A bare
    // number is user units in the SVG attribute grammar, so both parsers take one.
    case "stroke-dasharray": {
      if (value.trim().toLowerCase() === "none") {
        out.push({ p: P.P_STROKE_DASHARRAY, v: -1, u: P.U_NONE });
        return null;
      }
      const row = parseDashArray(value);
      if (typeof row === "string") return row;
      out.push({ p: P.P_STROKE_DASHARRAY, v: dashRows.register(row), u: P.U_LIST });
      return null;
    }
    case "stroke-dashoffset": {
      const l = dashLen(value);
      if (l === null) return `unsupported value '${value}' for 'stroke-dashoffset'`;
      out.push({ p: P.P_STROKE_DASHOFFSET, v: l.v, u: l.u });
      return null;
    }
    case "clip":
      {
      if (value.toLowerCase() === "auto") {
        out.push({ p: P.P_CLIP, v: -1, u: P.U_NONE });
        return null;
      }
      const m = /^rect\(([\s\S]*)\)$/.exec(value.toLowerCase());
      if (m === null) return `unsupported value '${value}' for 'clip' (use 'auto' or rect(top, right, bottom, left))`;
      // The four sides may be separated by commas or by whitespace, but not by both: a value that
      // mixes the two is a parse error, and the declaration is dropped as browsers drop it.
      const inner = m[1].trim();
      const sides = inner.includes(",") ? inner.split(",").map((s) => s.trim()) : inner.split(/\s+/);
      if (sides.length !== 4 || sides.some((s) => s === "" || /\s/.test(s))) return null;
      const row: number[] = [];
      for (const side of sides) {
        const l = parseLength(side, true);
        // rect() takes lengths or auto; a percentage has no box to resolve against.
        if (l === null || (l.u !== P.U_PX && l.u !== P.U_AUTO)) return `unsupported length '${side}' in 'clip: rect()'`;
        row.push(l.v, l.u);
      }
      out.push({ p: P.P_CLIP, v: clipRows.register(row), u: P.U_LIST });
      return null;
    }
    default:
      return undefined;
  }
}

/**
 * `scroll-snap-type` takes `none`, or an axis (`x`, `y`, `block`, `inline`, `both`, `pair`) with
 * an optional `mandatory` or `proximity` (proximity at first).
 */
function snapType(value: string, out: Decl[]): string | null {
  const parts = value.trim().toLowerCase().split(/\s+/).filter((p) => p !== "");
  if (parts.length === 1 && parts[0] === "none") {
    out.push({ p: P.P_SCROLL_SNAP_TYPE, v: P.SST_NONE, u: P.U_NONE });
    return null;
  }
  let axis = "";
  let strictness = "proximity";
  for (const part of parts) {
    if (part === "x" || part === "y" || part === "block" || part === "inline" || part === "both" ||
      part === "pair") {
      if (axis !== "") return `invalid scroll-snap-type: ${value}`;
      axis = part;
    } else if (part === "mandatory" || part === "proximity") {
      strictness = part;
    } else {
      return `invalid scroll-snap-type: ${value}`;
    }
  }
  if (axis === "") return `invalid scroll-snap-type: ${value}`;
  const base = axis === "x" ? P.SST_X : axis === "y" ? P.SST_Y
    : axis === "block" ? P.SST_BLOCK : axis === "inline" ? P.SST_INLINE
      : axis === "pair" ? P.SST_PAIR : P.SST_BOTH;
  out.push({ p: P.P_SCROLL_SNAP_TYPE, v: base + (strictness === "mandatory" ? 1 : 2), u: P.U_NONE });
  return null;
}

/**
 * The keywords `pointer-events` takes, each stored as its index in POINTER_EVENTS_NAMES: only
 * `none` keeps the pointer out, and the SVG ones hit as `auto` because a picture is drawn whole.
 */
const POINTER_EVENTS_KEYWORDS: Record<string, number> = {
  auto: 0, none: 1, visiblepainted: 2, visiblefill: 3, visiblestroke: 4, visible: 5,
  painted: 6, fill: 7, stroke: 8, all: 9,
};

/** The keywords `user-select` takes, each stored as its index in USER_SELECT_NAMES. */
const USER_SELECT_KEYWORDS: Record<string, number> = { auto: 0, text: 1, none: 2, all: 3 };

/**
 * The keywords `appearance` takes, each stored as its index in APPEARANCE_NAMES. A widget keyword
 * asks for the same UA painting `auto` gets, so only `none` changes how a control paints.
 */
const APPEARANCE_KEYWORDS: Record<string, number> = {
  auto: 0, none: 1, button: 2, "button-bevel": 3, checkbox: 4, listbox: 5, menulist: 6,
  "menulist-button": 7, meter: 8, "progress-bar": 9, "push-button": 10, radio: 11,
  searchfield: 12, "slider-horizontal": 13, "square-button": 14, textarea: 15, textfield: 16,
  "inner-spin-button": 17, "media-slider": 18, "media-sliderthumb": 19, "media-volume-slider": 20,
  "media-volume-sliderthumb": 21, "slider-vertical": 22, base: 23, "base-select": 24,
};

/** An SVG paint: `none`, `currentColor` or a colour, packed as the value fill/stroke hold. */
function paintValue(value: string): number | null {
  const s = value.trim().toLowerCase();
  if (s === "none") return P.PAINT_NONE;
  if (s === "currentcolor") return P.PAINT_CURRENT;
  return parseColor(s);
}

/** The id a `url(#id)` paint names, or null when the value isn't one. A fallback paint after it
 *  isn't read, so a server that can't be found paints nothing rather than the fallback. */
function paintRef(value: string): string | null {
  const m = /^url\(\s*(['"]?)#([^'")]+)\1\s*\)/i.exec(value.trim());
  return m === null ? null : m[2];
}
