// CSS grid: the container's track lists and auto-placement flow, and an item's placement.
// Returns undefined for a property this module doesn't handle.

import * as P from "../../props.ts";
import { kw, parseLength } from "../declarations.ts";
import { splitValue } from "../fonts.ts";
import { CSS_WIDE, stringToken } from "../syntax.ts";
import type { Decl, FontContext } from "../types.ts";
import { ITEMS_INVALID, ITEMS_WORDS, NO_AUTO, NO_INVALID, SELF_INVALID, SELF_POSITION, SELF_WORDS, alignValue, placeValues } from "./alignment.ts";

/** Splits on the commas outside any function's parentheses. */
function splitCommas(text: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (ch === "," && depth === 0) {
      out.push(text.slice(start, i));
      start = i + 1;
    }
  }
  out.push(text.slice(start));
  return out;
}

/** Splits on the slashes outside any function's parentheses. */
function splitSlashes(text: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (ch === "/" && depth === 0) {
      out.push(text.slice(start, i));
      start = i + 1;
    }
  }
  out.push(text.slice(start));
  return out;
}

/** A size that isn't auto, min-content, max-content or fr: a length, or fit-content()'s limit. */
function lengthSlot(text: string): number[] | null {
  const fr = /^([-+]?(?:\d+\.?\d*|\.\d+))fr$/.exec(text.toLowerCase());
  if (fr !== null) {
    const n = parseFloat(fr[1]);
    return n >= 0 ? slot(P.GT_FR, n, P.U_NONE) : null;
  }
  const l = parseLength(text, true, true);
  if (l === null) return null;
  if (l.u === P.U_MIN_CONTENT) return slot(P.GT_MIN_CONTENT);
  if (l.u === P.U_MAX_CONTENT) return slot(P.GT_MAX_CONTENT);
  // `fit-content` is a track size only as a function: `fit-content(<length>)`.
  if (l.u === P.U_FIT_CONTENT) return null;
  if (l.u === P.U_AUTO) return slot(P.GT_AUTO);
  return slot(P.GT_LEN, l.v, l.u);
}

/** Seven numbers: one side of a track's minmax(). */
function slot(kind: number, v: number = 0, u: number = 0): number[] {
  return [kind, v, u, 0, 0, 0, 0];
}

/** One track size from its text: seven numbers for the min of its minmax and seven for the max. */
function trackSize(text: string): number[] | null {
  const s = text.trim().toLowerCase();
  const open = s.indexOf("(");
  if (open > 0 && s.endsWith(")")) {
    const name = s.slice(0, open);
    const inner = s.slice(open + 1, -1);
    if (name === "fit-content") {
      const l = parseLength(inner, false);
      return l === null ? null : [...slot(P.GT_FIT_CONTENT, l.v, l.u), ...slot(P.GT_FIT_CONTENT, l.v, l.u)];
    }
    if (name === "minmax") {
      const args = splitCommas(inner);
      if (args.length !== 2) return null;
      const min = lengthSlot(args[0].trim());
      const max = lengthSlot(args[1].trim());
      if (min === null || max === null) return null;
      // A flex factor can't be a track's minimum, and putting one there already means auto.
      if (min[0] === P.GT_FR) return null;
      return [...min, ...max];
    }
    return null;
  }
  const fr = /^([-+]?(?:\d+\.?\d*|\.\d+))fr$/.exec(s);
  if (fr !== null) {
    const n = parseFloat(fr[1]);
    if (!(n >= 0)) return null;
    // `<flex>` stands for minmax(auto, <flex>).
    return [...slot(P.GT_AUTO), ...slot(P.GT_FR, n, P.U_NONE)];
  }
  const one = lengthSlot(s);
  if (one === null) return null;
  // A plain size is its own minimum and maximum; an auto track is minmax(auto, auto).
  return [...one, ...one];
}

/**
 * The tokens of a track list: split on whitespace outside parentheses, and a `[a b]` line-name
 * group stays one token.
 */
function trackTokens(text: string): string[] {
  const parts: string[] = [];
  let depth = 0, bracket = 0, cur = "";
  for (const ch of text.trim()) {
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    else if (depth === 0 && ch === "[") bracket++;
    else if (depth === 0 && ch === "]") bracket--;
    if (/\s/.test(ch) && depth === 0 && bracket === 0) {
      if (cur !== "") parts.push(cur);
      cur = "";
    } else cur += ch;
  }
  if (cur !== "") parts.push(cur);
  return parts;
}

/** The line names a `[a b]` group writes, or null when the group is malformed. */
function nameGroup(token: string): string[] | null {
  if (!token.endsWith("]")) return null;
  const names: string[] = [];
  for (const n of token.slice(1, -1).split(/\s+/)) {
    if (n === "") continue;
    if (!/^-?[A-Za-z_][\w-]*$/.test(n)) return null;
    names.push(n);
  }
  return names.length === 0 ? null : names;
}

/**
 * One line's names as whole blocks of a track list: a marker block holding the count, then the
 * name ids twelve to a block. Every track-list entry is a whole block, so the marker is padded
 * out to the stride before the names start.
 */
function nameSlots(names: string[], fonts: FontContext): number[] | null {
  const ids: number[] = [];
  for (const n of names) ids.push(fonts.trackName(n));
  if (ids.length > 400) return null;
  const out = slot(P.GT_NAMES, ids.length);
  while (out.length < P.GRID_TRACK_STRIDE) out.push(0);
  const blocks = Math.ceil(ids.length / P.GT_NAMES_PER_BLOCK);
  for (let b = 0; b < blocks; b++) {
    for (let k = 0; k < P.GRID_TRACK_STRIDE; k++) {
      out.push(k < P.GT_NAMES_PER_BLOCK ? ids[b * P.GT_NAMES_PER_BLOCK + k] ?? 0 : 0);
    }
  }
  return out;
}

/** A whole track list: every track's fourteen numbers, with repeat() expanded. */
function trackList(text: string, fonts: FontContext, depth: number = 0): number[] | null {
  const out: number[] = [];
  // Line names written since the last track: they name the line before the next one.
  let pending: string[] = [];
  for (const token of trackTokens(text)) {
    if (token.startsWith("[")) {
      const names = nameGroup(token);
      if (names === null) return null;
      for (const n of names) pending.push(n);
      continue;
    }
    const lower = token.toLowerCase();
    if (lower.startsWith("repeat(") && lower.endsWith(")")) {
      if (depth > 2) return null;
      const args = splitCommas(token.slice(7, -1));
      if (args.length !== 2) return null;
      const count = args[0].trim();
      const auto = count === "auto-fill" || count === "auto-fit";
      // repeat(auto-fill, …) and repeat(auto-fit, …) need the space a track list has to fit in,
      // which only layout knows: the list is kept once, behind a marker that names it.
      if (auto) {
        if (pending.length > 0) {
          const names = nameSlots(pending, fonts);
          if (names === null) return null;
          for (const v of names) out.push(v);
          pending = [];
        }
        const once = trackList(args[1], fonts, depth + 1);
        if (once === null) return null;
        const kind = count === "auto-fit" ? P.GT_AUTO_FIT : P.GT_AUTO_FILL;
        for (const v of slot(kind, once.length / P.GRID_TRACK_STRIDE)) out.push(v);
        for (const v of slot(0)) out.push(v);
        for (const v of once) out.push(v);
        continue;
      }
      if (!/^[1-9]\d{0,2}$/.test(count)) return null;
      const once = trackList(args[1], fonts, depth + 1);
      if (once === null) return null;
      const n = parseInt(count, 10);
      if (once.length * n + out.length > 400 * P.GRID_TRACK_STRIDE) return null;
      for (let k = 0; k < n; k++) for (const v of once) out.push(v);
      continue;
    }
    const t = trackSize(token);
    if (t === null) return null;
    if (pending.length > 0) {
      const names = nameSlots(pending, fonts);
      if (names === null) return null;
      for (const v of names) out.push(v);
      pending = [];
    }
    for (const v of t) out.push(v);
  }
  // Names after the last track name the line the list ends on.
  if (pending.length > 0) {
    const names = nameSlots(pending, fonts);
    if (names === null) return null;
    for (const v of names) out.push(v);
  }
  return out.length === 0 ? null : out;
}

/** Splits a value on whitespace outside quotes and parentheses, keeping each string whole. */
function areaTokens(text: string): string[] {
  const parts: string[] = [];
  let depth = 0, quote = "", cur = "";
  for (const ch of text.trim()) {
    if (quote !== "") {
      cur += ch;
      if (ch === quote) quote = "";
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; cur += ch; continue; }
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    if (/\s/.test(ch) && depth === 0) {
      if (cur !== "") parts.push(cur);
      cur = "";
    } else cur += ch;
  }
  if (cur !== "") parts.push(cur);
  return parts;
}

/**
 * The grid-template-areas value: one string per row, each holding a cell per column — a
 * `<custom-ident>` naming the area that cell belongs to, or dots for none. Every area has to be a
 * filled rectangle, and every row the same number of cells (CSS Grid 7.3). The row stores, per
 * area, the name id and the four lines it spans, one-based.
 */
function areaList(prop: string, value: string, fonts: FontContext | undefined, out: Decl[], p: number): string | null {
  const unsupported = `unsupported value '${value}' for '${prop}'`;
  if (value.trim().toLowerCase() === "none") {
    out.push({ p, v: -1, u: P.U_LIST });
    return null;
  }
  if (fonts === undefined) return `'${prop}' needs a build to register its areas`;
  const rows: (string | null)[][] = [];
  for (const token of areaTokens(value)) {
    if (!token.startsWith('"') && !token.startsWith("'")) return unsupported;
    const text = stringToken(token);
    if (text === null) return unsupported;
    const cells: (string | null)[] = [];
    for (const cell of text.split(/\s+/)) {
      if (cell === "") continue;
      if (/^\.+$/.test(cell)) cells.push(null);
      else if (/^-?[A-Za-z_][\w-]*$/.test(cell) && !CSS_WIDE.has(cell.toLowerCase())) cells.push(cell);
      else return unsupported;
    }
    if (cells.length === 0) return unsupported;
    if (rows.length > 0 && cells.length !== rows[0].length) return unsupported;
    rows.push(cells);
  }
  if (rows.length === 0) return unsupported;
  const cols = rows[0].length;
  // Each name's cells have to fill one rectangle.
  const rect = new Map<string, [number, number, number, number]>();
  for (let r = 0; r < rows.length; r++) {
    for (let c = 0; c < cols; c++) {
      const name = rows[r][c];
      if (name === null) continue;
      const hit = rect.get(name);
      if (hit === undefined) rect.set(name, [r, r, c, c]);
      else {
        hit[0] = Math.min(hit[0], r);
        hit[1] = Math.max(hit[1], r);
        hit[2] = Math.min(hit[2], c);
        hit[3] = Math.max(hit[3], c);
      }
    }
  }
  for (const [name, [r0, r1, c0, c1]] of rect) {
    for (let r = r0; r <= r1; r++) {
      for (let c = c0; c <= c1; c++) if (rows[r][c] !== name) return unsupported;
    }
  }
  const row: number[] = [rect.size];
  for (const [name, [r0, r1, c0, c1]] of rect) {
    // Lines are one-based: a cell in row r starts on line r + 1 and ends on line r + 2.
    row.push(fonts.trackName(name), r0 + 1, r1 + 2, c0 + 1, c1 + 2);
  }
  out.push({ p, v: fonts.areaList(row), u: P.U_LIST });
  return null;
}

/** Registers a track list and returns the id its property holds. */
function trackRow(prop: string, text: string, fonts: FontContext | undefined, out: Decl[], p: number): string | null {
  if (fonts === undefined) return `'${prop}' needs a build to register its tracks`;
  const row = trackList(text, fonts);
  if (row === null) return `unsupported value '${text}' for '${prop}'`;
  out.push({ p, v: fonts.tracks(row), u: P.U_LIST });
  return null;
}

/**
 * grid-column-start & co: auto, a line number, a span, or a line name with an optional occurrence
 * count (CSS Grid 8.3). `span` may carry a number, a name or both, and the name may come either
 * side of the count.
 */
function placement(text: string, fonts: FontContext | undefined):
  { v: number; u: number; custom: boolean } | null {
  const s = text.trim();
  if (s.toLowerCase() === "auto") return { v: 0, u: P.U_AUTO, custom: false };
  const tokens = splitValue(s);
  if (tokens.length === 0 || tokens.length > 3) return null;
  let span = false;
  let count = NaN;
  let name = "";
  for (const token of tokens) {
    if (token.toLowerCase() === "span") {
      if (span) return null;
      span = true;
    } else if (/^[-+]?\d+$/.test(token)) {
      if (!Number.isNaN(count)) return null;
      count = parseInt(token, 10);
    } else if (/^-?[A-Za-z_][\w-]*$/.test(token)) {
      if (name !== "") return null;
      name = token;
    } else return null;
  }
  if (name !== "") {
    // A count of zero names no line: the first line of that name is the default.
    if (count === 0 || count === -0) return null;
    if (fonts === undefined) return null;
    const row = [fonts.trackName(name), Number.isNaN(count) ? 0 : count, span ? 1 : 0];
    return { v: fonts.placement(row), u: P.U_NAME, custom: !span };
  }
  if (span) {
    // A bare `span` with nothing to count is invalid.
    return Number.isNaN(count) || count < 1 ? null : { v: count, u: P.U_SPAN, custom: false };
  }
  if (Number.isNaN(count)) return null;
  // Line 0 doesn't exist; negative lines count back from the end of the explicit grid.
  return count === 0 ? null : { v: count, u: P.U_NONE, custom: false };
}

/** The start and end of a `grid-column: 1 / span 2` style value, either half optional. */
function placementPair(prop: string, value: string, start: number, end: number, out: Decl[], fonts: FontContext | undefined): string | null {
  const parts = value.split("/").map((s) => s.trim());
  if (parts.length > 2 || parts.some((s) => s === "")) {
    return `'${prop}' takes a start and an end, separated by '/'`;
  }
  const s = placement(parts[0], fonts);
  if (s === null) return `unsupported value '${parts[0]}' for '${prop}'`;
  out.push({ p: start, v: s.v, u: s.u });
  // An omitted end is the start's own name, or auto when the start isn't a name (CSS Grid 8.4).
  if (parts.length > 1) {
    const e = placement(parts[1], fonts);
    if (e === null) return `unsupported value '${parts[1]}' for '${prop}'`;
    out.push({ p: end, v: e.v, u: e.u });
  } else if (s.custom) {
    out.push({ p: end, v: s.v, u: s.u });
  } else {
    out.push({ p: end, v: 0, u: P.U_AUTO });
  }
  return null;
}

/** One side of a template shorthand: a track list, or `none` for no tracks at all. */
function templateTrack(prop: string, text: string, p: number, fonts: FontContext | undefined, out: Decl[]): string | null {
  const lower = text.trim().toLowerCase();
  // `subgrid` adopts the tracks the item spans in its parent grid; local line names are read
  // but not yet used for placement.
  if (lower === "subgrid" || lower.startsWith("subgrid ")) {
    // The line names written after it name the line the subgrid stands on, and are what the
    // computed value prints beside `subgrid`.
    const rest = text.trim().slice("subgrid".length).trim();
    let v = -1;
    if (rest !== "") {
      if (fonts === undefined) return `'${prop}' needs a build to register its line names`;
      // Each bracket group names the next line of the subgrid — `[a] [b]` names line 1 a and
      // line 2 b — so each is stored as an entry of its own, in order.
      const row: number[] = [];
      for (const token of trackTokens(rest)) {
        if (!token.startsWith("[")) return `unsupported value '${text}' for '${prop}' (only line names after subgrid)`;
        const names = nameGroup(token);
        if (names === null) return `unsupported value '${text}' for '${prop}'`;
        const slots = nameSlots(names, fonts);
        if (slots === null) return `unsupported value '${text}' for '${prop}'`;
        for (const x of slots) row.push(x);
      }
      if (row.length === 0) return `unsupported value '${text}' for '${prop}'`;
      v = fonts.tracks(row);
    }
    out.push({ p, v, u: P.U_SUBGRID });
    return null;
  }
  if (lower === "none") {
    out.push({ p, v: -1, u: P.U_LIST });
    return null;
  }
  return trackRow(prop, text.trim(), fonts, out, p);
}

/** The `auto-flow && dense?` side of the `grid` shorthand: its flow direction, and its auto tracks. */
function autoSide(text: string): { dense: boolean; tracks: string } | null {
  const rest: string[] = [];
  let autoFlow = false;
  let dense = false;
  for (const t of splitValue(text)) {
    const l = t.toLowerCase();
    if (l === "auto-flow") autoFlow = true;
    else if (l === "dense") dense = true;
    else rest.push(t);
  }
  return autoFlow ? { dense, tracks: rest.join(" ") } : null;
}

/**
 * The `grid` shorthand: two template sides, or a template side paired with an auto-flowing one.
 * Every longhand it sets starts at its initial value, as a shorthand does (CSS Grid 7.4).
 */
function gridShorthand(value: string, fonts: FontContext | undefined, out: Decl[]): string | null {
  const unsupported = `unsupported value '${value}' for 'grid'`;
  const decls: Decl[] = [
    { p: P.P_GRID_TEMPLATE_ROWS, v: -1, u: P.U_LIST }, { p: P.P_GRID_TEMPLATE_COLUMNS, v: -1, u: P.U_LIST },
    { p: P.P_GRID_AUTO_ROWS, v: -1, u: P.U_LIST }, { p: P.P_GRID_AUTO_COLUMNS, v: -1, u: P.U_LIST },
    { p: P.P_GRID_AUTO_FLOW, v: P.GF_ROW, u: P.U_NONE },
  ];
  const done = (): string | null => {
    for (const d of decls) out.push(d);
    return null;
  };
  if (value.trim().toLowerCase() === "none") return done();
  const parts = splitSlashes(value);
  if (parts.length !== 2 || parts.some((s) => s.trim() === "")) return unsupported;
  const left = parts[0].trim();
  const right = parts[1].trim();
  const lAuto = autoSide(left);
  const rAuto = autoSide(right);
  if (lAuto !== null && rAuto !== null) return unsupported;
  const set = (p: number, v: number, u: number): void => {
    for (const d of decls) if (d.p === p) { d.v = v; d.u = u; return; }
  };
  if (lAuto === null && rAuto === null) {
    // `<rows> / <columns>`: both sides name tracks, and the flow is rows.
    const err = templateTrack("grid", left, P.P_GRID_TEMPLATE_ROWS, fonts, decls);
    if (err !== null) return err;
    const err2 = templateTrack("grid", right, P.P_GRID_TEMPLATE_COLUMNS, fonts, decls);
    return err2 !== null ? err2 : done();
  }
  // An auto-flowing column side leaves the rows to the template and the columns to the flow.
  if (rAuto !== null) {
    const err = templateTrack("grid", left, P.P_GRID_TEMPLATE_ROWS, fonts, decls);
    if (err !== null) return err;
    set(P.P_GRID_AUTO_FLOW, rAuto.dense ? P.GF_COLUMN_DENSE : P.GF_COLUMN, P.U_NONE);
    if (rAuto.tracks !== "") {
      const err2 = templateTrack("grid", rAuto.tracks, P.P_GRID_AUTO_COLUMNS, fonts, decls);
      if (err2 !== null) return err2;
    }
    return done();
  }
  const err = templateTrack("grid", right, P.P_GRID_TEMPLATE_COLUMNS, fonts, decls);
  if (err !== null) return err;
  set(P.P_GRID_AUTO_FLOW, lAuto!.dense ? P.GF_ROW_DENSE : P.GF_ROW, P.U_NONE);
  if (lAuto!.tracks !== "") {
    const err2 = templateTrack("grid", lAuto!.tracks, P.P_GRID_AUTO_ROWS, fonts, decls);
    if (err2 !== null) return err2;
  }
  return done();
}

export function gridProperty(prop: string, value: string, out: Decl[], fonts?: FontContext): string | null | undefined {
  switch (prop) {
    case "grid-lanes-direction": {
      const words = value.trim().toLowerCase().split(/\s+/);
      let v = 0;
      for (const w of words) {
        if (w === "normal") { out.push({ p: P.P_GRID_LANES_DIRECTION, v: 0, u: P.U_AUTO }); return null; }
        if (w === "row") v = (v & ~1) | P.GL_ROW;
        else if (w === "column") v = v & ~1;
        else if (w === "fill-reverse") v |= P.GL_FILL_REVERSE;
        else if (w === "track-reverse") v |= P.GL_TRACK_REVERSE;
        else return `unsupported value '${value}' for 'grid-lanes-direction'`;
      }
      out.push({ p: P.P_GRID_LANES_DIRECTION, v, u: P.U_NONE });
      return null;
    }
    case "grid-lanes-pack":
      if (value.trim().toLowerCase() === "dense") { out.push({ p: P.P_GRID_LANES_PACK, v: 1, u: P.U_NONE }); return null; }
      if (value.trim().toLowerCase() === "normal") { out.push({ p: P.P_GRID_LANES_PACK, v: 0, u: P.U_NONE }); return null; }
      return `unsupported value '${value}' for 'grid-lanes-pack'`;
    case "fit-tolerance": {
      const t = value.trim().toLowerCase();
      if (t === "normal") { out.push({ p: P.P_FIT_TOLERANCE, v: 0, u: P.U_NORMAL }); return null; }
      if (t === "infinite") { out.push({ p: P.P_FIT_TOLERANCE, v: 1e7, u: P.U_PX }); return null; }
      const l = parseLength(t, false);
      // A negative tolerance zeroes: a distance from the shortest position can't be negative.
      if (l === null || (l.u === P.U_PX && l.v < 0)) return `unsupported value '${value}' for 'fit-tolerance'`;
      out.push({ p: P.P_FIT_TOLERANCE, v: l.v, u: l.u });
      return null;
    }
    case "grid-template": {
      // `<rows> / <columns>`; the areas form names its tracks through a template-areas value.
      const decls: Decl[] = [];
      const fail = (): string => `unsupported value '${value}' for 'grid-template'`;
      const ok = (): string | null => { for (const d of decls) out.push(d); return null; };
      if (value.trim().toLowerCase() === "none") return ok();
      const parts = splitSlashes(value);
      if (parts.length !== 2 || parts.some((s) => s.trim() === "")) return fail();
      const err = templateTrack("grid-template", parts[0], P.P_GRID_TEMPLATE_ROWS, fonts, decls);
      if (err !== null) return err;
      const err2 = templateTrack("grid-template", parts[1], P.P_GRID_TEMPLATE_COLUMNS, fonts, decls);
      return err2 !== null ? err2 : ok();
    }
    case "grid":
      return gridShorthand(value, fonts, out);
    case "grid-template-columns":
    case "grid-template-rows": {
      const p = prop === "grid-template-columns" ? P.P_GRID_TEMPLATE_COLUMNS : P.P_GRID_TEMPLATE_ROWS;
      // `subgrid` and the line names written after it are one value: templateTrack keeps them,
      // and the `grid` shorthand's own side comes through the same function.
      if (/^subgrid(\s|$)/i.test(value.trim())) return templateTrack(prop, value, p, fonts, out);
      if (value.trim().toLowerCase() === "none") {
        out.push({ p, v: -1, u: P.U_LIST });
        return null;
      }
      return trackRow(prop, value, fonts, out, p);
    }
    case "grid-auto-columns":
    case "grid-auto-rows": {
      const p = prop === "grid-auto-columns" ? P.P_GRID_AUTO_COLUMNS : P.P_GRID_AUTO_ROWS;
      const lower = value.trim().toLowerCase();
      if (lower === "auto") {
        out.push({ p, v: -1, u: P.U_LIST });
        return null;
      }
      return trackRow(prop, value, fonts, out, p);
    }
    case "grid-auto-flow": {
      const parts = splitValue(value).map((s) => s.toLowerCase());
      const dense = parts.includes("dense");
      const axis = parts.find((s) => s === "row" || s === "column");
      if (parts.some((s) => s !== "dense" && s !== "row" && s !== "column")) {
        return `unsupported value '${value}' for 'grid-auto-flow'`;
      }
      if (axis === "column") out.push({ p: P.P_GRID_AUTO_FLOW, v: dense ? P.GF_COLUMN_DENSE : P.GF_COLUMN, u: P.U_NONE });
      else out.push({ p: P.P_GRID_AUTO_FLOW, v: dense ? P.GF_ROW_DENSE : P.GF_ROW, u: P.U_NONE });
      return null;
    }
    case "grid-column-start":
      return placementDecl(prop, value, P.P_GRID_COLUMN_START, out, fonts);
    case "grid-column-end":
      return placementDecl(prop, value, P.P_GRID_COLUMN_END, out, fonts);
    case "grid-row-start":
      return placementDecl(prop, value, P.P_GRID_ROW_START, out, fonts);
    case "grid-row-end":
      return placementDecl(prop, value, P.P_GRID_ROW_END, out, fonts);
    case "grid-column":
      return placementPair(prop, value, P.P_GRID_COLUMN_START, P.P_GRID_COLUMN_END, out, fonts);
    case "grid-row":
      return placementPair(prop, value, P.P_GRID_ROW_START, P.P_GRID_ROW_END, out, fonts);
    case "grid-template-areas":
      return areaList(prop, value, fonts, out, P.P_GRID_TEMPLATE_AREAS);
    case "grid-area": {
      // row-start / column-start / row-end / column-end, each optional (CSS Grid 8.4).
      const parts = value.split("/").map((s) => s.trim());
      if (parts.length > 4 || parts.some((s) => s === "")) {
        return `unsupported value '${value}' for 'grid-area'`;
      }
      const pls: { v: number; u: number; custom: boolean }[] = [];
      for (const part of parts) {
        const pl = placement(part, fonts);
        if (pl === null) return `unsupported value '${part}' for 'grid-area'`;
        pls.push(pl);
      }
      const auto = { v: 0, u: P.U_AUTO, custom: false };
      const rowStart = pls[0];
      // An omitted side takes the value its axis's start has when that is a bare name, so a
      // single name sets all four sides and `grid-area: <name>` fills the named area.
      const colStart = pls[1] ?? (rowStart.custom ? rowStart : auto);
      const rowEnd = pls[2] ?? (rowStart.custom ? rowStart : auto);
      const colEnd = pls[3] ?? (colStart.custom ? colStart : auto);
      out.push({ p: P.P_GRID_ROW_START, v: rowStart.v, u: rowStart.u });
      out.push({ p: P.P_GRID_COLUMN_START, v: colStart.v, u: colStart.u });
      out.push({ p: P.P_GRID_ROW_END, v: rowEnd.v, u: rowEnd.u });
      out.push({ p: P.P_GRID_COLUMN_END, v: colEnd.v, u: colEnd.u });
      return null;
    }
    case "justify-items":
      return alignValue(prop, value, ITEMS_WORDS, SELF_POSITION, NO_AUTO, P.P_JUSTIFY_ITEMS, out, true);
    case "justify-self":
      return alignValue(prop, value, SELF_WORDS, SELF_POSITION, NO_INVALID, P.P_JUSTIFY_SELF, out);
    case "place-items":
    case "place-self": {
      // The block-axis value, then the inline-axis one, which defaults to the first. Each side
      // takes what its own property takes: the block axis has no physical edges, and only the
      // self properties have `auto`.
      const pair = placeValues(value);
      const words = prop === "place-items" ? ITEMS_WORDS : SELF_WORDS;
      const firstInvalid = prop === "place-items" ? ITEMS_INVALID : SELF_INVALID;
      const secondInvalid = prop === "place-items" ? NO_AUTO : NO_INVALID;
      const first = prop === "place-items" ? P.P_ALIGN_ITEMS : P.P_ALIGN_SELF;
      const second = prop === "place-items" ? P.P_JUSTIFY_ITEMS : P.P_JUSTIFY_SELF;
      if (pair === null) return `invalid value '${value}' for '${prop}'`;
      const decls: Decl[] = [];
      const err = alignValue(prop, pair[0], words, SELF_POSITION, firstInvalid, first, decls);
      if (err !== null) return err;
      const err2 = alignValue(prop, pair[1], words, SELF_POSITION, secondInvalid, second, decls);
      if (err2 !== null) return err2;
      for (const d of decls) out.push(d);
      return null;
    }
  }
  return undefined;
}

function placementDecl(prop: string, value: string, p: number, out: Decl[], fonts: FontContext | undefined): string | null {
  const pl = placement(value, fonts);
  if (pl === null) return `unsupported value '${value}' for '${prop}'`;
  out.push({ p, v: pl.v, u: pl.u });
  return null;
}
