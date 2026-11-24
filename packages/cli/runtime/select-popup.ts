// The menulist a closed <select> opens. A browser draws that picker itself rather than asking the
// platform for a menu, so the runtime draws it too: a panel over the whole page, its rows painted
// from the options, with the arrow keys, type-ahead, Enter, Escape and the pointer all handled
// here. Drawing it in the runtime keeps the hosts thin and makes the picker the same on every
// host. A list box (size over one, or multiple) shows its rows in the page's own layout and never
// comes here.

import * as P from "../shared/props.ts";
import { KEY_TEXT, KEY_ENTER, KEY_UP, KEY_DOWN, KEY_HOME, KEY_END, KEY_ESCAPE, KEY_TAB, MOD_ALT } from "./host.ts";
import { hostClipPop, hostClipPush, hostFillRect, hostShadowOuter, hostText } from "./host.ts";
import { invalidatePaint } from "./invalidation.ts";
import { viewport } from "./viewport.ts";

/** A row of the picker is one of its options or an option group's label. */
export const ROW_OPTION = 0;
export const ROW_GROUP = 1;

export interface SelectPopupRow {
  /** ROW_OPTION or ROW_GROUP. */
  kind: number;
  /** The option's index in its select, or -1 for a group's label. */
  index: number;
  label: string;
  /** A disabled option, or an option in a disabled group: shown, but not pickable. */
  disabled: boolean;
}

/** What the picker draws with, read from the field that opened it. */
export interface SelectPopupStyle {
  /** The field's font, as the host keys it. */
  font: number;
  size: number;
  lineHeight: number;
  letter: number;
  word: number;
  /** The field's ink, which its options' labels take. */
  color: number;
  /** The accent colour the highlighted row takes, or a negative number for the UA's own. */
  accent: number;
  dark: boolean;
}

export interface SelectPopupOptions {
  rows: SelectPopupRow[];
  /** The field's Node.serial, which the panel's display list commands name as their owner. */
  serial: number;
  /** The index of the option the field has chosen, or -1 when it has none. */
  selected: number;
  style: SelectPopupStyle;
  /** The field's border box in viewport pixels, read as the picker opens. */
  rect(): number[];
  /** The width `text` takes in the field's font. */
  measure(text: string): number;
  /** Whether the field is still in the page; one that left takes its picker with it. */
  alive(): boolean;
  /** Puts the option at `index` in the field, as a pick a user made does. */
  choose(index: number): void;
  /** Told when the picker opens or closes, so a client reading the field's state sees the change. */
  changed?(): void;
}

/** What a key did to an open picker. */
export const POPUP_NONE = 0;
export const POPUP_HANDLED = 1;
/** Tab closes the picker and then moves focus, which the keyboard handler does. */
export const POPUP_TAB = 2;

// The panel's measurements, as Chrome's menulist has them: a hairline edge, room around the rows,
// padding at each row's sides, rounded corners, and a margin to the window's edge.
const BORDER = 1;
const PAD = 4;
const ITEM_PAD = 10;
const CORNER = 4;
const MARGIN = 4;
const SCROLLBAR = 6;
const ROW_GAP = 4;

const LIGHT = { bg: 0xffffffff, border: 0x767676ff, disabled: 0x8a8a8aff, group: 0x5f5f5fff, shadow: 0x00000026 };
const DARK = { bg: 0x1f1f1fff, border: 0x5f5f5fff, disabled: 0x8a8a8aff, group: 0xbfbfbfff, shadow: 0x00000066 };
const ACCENT = 0x0075ffff;
const HIGHLIGHT_TEXT = 0xffffffff;

interface OpenPopup {
  opts: SelectPopupOptions;
  serial: number;
  /** The highlighted row, an index into rows. */
  active: number;
  /** How far the rows are scrolled up, in pixels. */
  scroll: number;
  /** Whether the press that is down began in the panel. */
  pressing: boolean;
  /** The letters typed in a row, and when the last one landed, for type-ahead. */
  typed: string;
  typedAt: number;
  /** The panel and its content, in viewport pixels, as the last layout left them. */
  x: number;
  y: number;
  w: number;
  h: number;
  innerH: number;
  maxScroll: number;
  rowTop: number[];
  rowH: number[];
  contentH: number;
  /** The field's border box as the open read it: the panel keeps its place from then on. */
  anchor: number[];
  /** The row the panel was placed against: the option the field had chosen when it opened. */
  anchorRow: number;
}

let open: OpenPopup | null = null;
/** Set by a press that dismissed the picker, so its release reaches nothing else. */
let swallowUp = false;

export function selectPopupOpen(): boolean {
  return open !== null;
}

/** The field whose picker is open, by its serial, or -1: a client reads the field as expanded. */
export function selectPopupSerial(): number {
  return open !== null ? open.serial : -1;
}

/** Whether the point is inside the panel. */
function inside(p: OpenPopup, x: number, y: number): boolean {
  return x >= p.x && x < p.x + p.w && y >= p.y && y < p.y + p.h;
}

/** Where the rows begin, the top of the panel's padding inside its edge. */
function rowsTop(p: OpenPopup): number {
  return p.y + BORDER + PAD;
}

/** How tall the stretch of rows the panel shows is. */
function rowsViewH(p: OpenPopup): number {
  return Math.max(0, p.innerH - PAD * 2);
}

/** The row heights in the field's font: the line box plus a little room, as Chrome gives them. */
function rowHeight(st: SelectPopupStyle): number {
  return Math.max(16, Math.round(Math.max(st.lineHeight, st.size * 1.2) + ROW_GAP));
}

/**
 * Works out the panel's size and place: as wide as its widest row or the field, tall enough for
 * its rows up to the window's height, with the highlighted row level with the field and the whole
 * panel kept inside the window. The place comes from the field's box and chosen option as the
 * open read them, so a highlight that moves never drags the panel with it.
 */
function layout(p: OpenPopup): void {
  const st = p.opts.style;
  const rh = rowHeight(st);
  const rows = p.opts.rows;
  // The rows' own stretch of the panel starts after its padding, so a row's top is its index
  // times the row height.
  const tops: number[] = [];
  const heights: number[] = [];
  for (let i = 0; i < rows.length; i++) {
    tops.push(i * rh);
    heights.push(rh);
  }
  const rowsH = rows.length * rh;
  p.rowTop = tops;
  p.rowH = heights;
  p.contentH = rowsH;
  const room = Math.max(0, viewport.h - MARGIN * 2);
  const scrollable = rowsH + PAD * 2 + BORDER * 2 > room;
  let widest = 0;
  for (let i = 0; i < rows.length; i++) widest = Math.max(widest, p.opts.measure(rows[i].label));
  const r = p.anchor;
  let w = Math.ceil(Math.max(r[2], widest + ITEM_PAD * 2 + BORDER * 2 + (scrollable ? SCROLLBAR + 3 : 0)));
  w = Math.min(w, Math.max(0, viewport.w - MARGIN * 2));
  const innerH = Math.min(rowsH + PAD * 2, Math.max(0, room - BORDER * 2));
  const h = innerH + BORDER * 2;
  p.innerH = innerH;
  p.maxScroll = Math.max(0, rowsH + PAD * 2 - innerH);
  if (p.scroll > p.maxScroll) p.scroll = p.maxScroll;
  // The active row's middle goes level with the field's, and the panel then moves as far as it
  // must to stand inside the window.
  const at = p.anchorRow >= 0 ? tops[p.anchorRow] : 0;
  let y = r[1] + r[3] / 2 - (BORDER + PAD + at + rh / 2);
  if (y + h > viewport.h - MARGIN) y = viewport.h - MARGIN - h;
  if (y < MARGIN) y = MARGIN;
  let x = r[0];
  if (x + w > viewport.w - MARGIN) x = viewport.w - MARGIN - w;
  if (x < MARGIN) x = MARGIN;
  p.x = x;
  p.y = y;
  p.w = Math.max(0, w);
  p.h = Math.max(0, h);
}

/**
 * Scrolls a list too long for the panel so the option the field had chosen sits over the field,
 * as a browser's picker opens on the selection. The panel's own place never moves for this.
 */
function alignScroll(p: OpenPopup): void {
  if (p.maxScroll <= 0 || p.anchorRow < 0) return;
  const rh = p.rowH[p.anchorRow];
  const top = rowsTop(p);
  const view = rowsViewH(p);
  let want = p.anchor[1] + p.anchor[3] / 2 - rh / 2;
  if (want < top) want = top;
  if (want > top + view - rh) want = top + view - rh;
  const s = p.rowTop[p.anchorRow] + top - want;
  p.scroll = s < 0 ? 0 : s > p.maxScroll ? p.maxScroll : s;
}

/** Scrolls the rows so the active one shows whole. */
function revealActive(p: OpenPopup): void {
  if (p.active < 0 || p.active >= p.rowTop.length) return;
  const view = rowsViewH(p);
  const top = p.rowTop[p.active];
  const bottom = top + p.rowH[p.active];
  if (top - p.scroll < 0) p.scroll = top;
  else if (bottom - p.scroll > view) p.scroll = bottom - view;
  if (p.scroll < 0) p.scroll = 0;
  if (p.scroll > p.maxScroll) p.scroll = p.maxScroll;
}

/** The row a point falls in, or -1 for the panel's padding or outside it. */
function rowAt(p: OpenPopup, x: number, y: number): number {
  if (!inside(p, x, y)) return -1;
  const top = rowsTop(p);
  const at = y - top + p.scroll;
  if (y < top || y >= top + rowsViewH(p)) return -1;
  for (let i = 0; i < p.rowTop.length; i++) {
    const t = p.rowTop[i];
    if (at >= t && at < t + p.rowH[i]) return i;
  }
  return -1;
}

/** The first row at or after `from` that a user can move to, or -1. */
function nextSelectable(p: OpenPopup, from: number, step: number): number {
  const rows = p.opts.rows;
  let i = from;
  while (i >= 0 && i < rows.length) {
    if (rows[i].kind === ROW_OPTION && !rows[i].disabled) return i;
    i += step;
  }
  return -1;
}

/** Puts the highlighted row's option in the field, sending input then change when it moved. */
function commitActive(p: OpenPopup): void {
  const row = p.active >= 0 && p.active < p.opts.rows.length ? p.opts.rows[p.active] : null;
  if (row === null || row.kind !== ROW_OPTION || row.disabled) return;
  p.opts.choose(row.index);
}

/** Highlights the row at `i`, revealing it, and moves the field to its option, as arrows do. */
function setActive(p: OpenPopup, i: number): void {
  if (i < 0) return;
  p.active = i;
  revealActive(p);
  layout(p);
  commitActive(p);
  invalidatePaint();
}

/**
 * Opens the picker over the field: the chosen option is highlighted, with the rows around it, and
 * the whole panel is placed against the field.
 */
export function openSelectPopup(opts: SelectPopupOptions): void {
  if (open !== null) return;
  const rows = opts.rows;
  let active = -1;
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].kind === ROW_OPTION && rows[i].index === opts.selected) active = i;
  }
  if (active < 0) {
    for (let i = 0; i < rows.length && active < 0; i++) {
      if (rows[i].kind === ROW_OPTION && !rows[i].disabled) active = i;
    }
  }
  const p: OpenPopup = {
    opts, serial: opts.serial, active, scroll: 0, pressing: false, typed: "", typedAt: 0,
    x: 0, y: 0, w: 0, h: 0, innerH: 0, maxScroll: 0, rowTop: [], rowH: [], contentH: 0,
    anchor: opts.rect(), anchorRow: active,
  };
  open = p;
  layout(p);
  alignScroll(p);
  layout(p);
  if (opts.changed) opts.changed();
  invalidatePaint();
}

/** Closes the picker. The field keeps whatever choice the arrows or a pick already put in it. */
export function closeSelectPopup(): void {
  const p = open;
  if (p === null) return;
  open = null;
  swallowUp = false;
  if (p.opts.changed) p.opts.changed();
  invalidatePaint();
}

/**
 * A press while the picker is open: one on a row takes it as the highlight and waits for the
 * release to pick it, and one anywhere else dismisses the picker and goes no further, as Chrome's
 * light dismiss does. The press and its release are both consumed.
 */
export function selectPopupPointerDown(x: number, y: number): boolean {
  const p = open;
  if (p === null) return false;
  if (!p.opts.alive()) {
    closeSelectPopup();
    return false;
  }
  layout(p);
  if (!inside(p, x, y)) {
    swallowUp = true;
    closeSelectPopup();
    return true;
  }
  p.pressing = true;
  const i = rowAt(p, x, y);
  const row = i >= 0 ? p.opts.rows[i] : null;
  if (row !== null && row.kind === ROW_OPTION && !row.disabled && i !== p.active) {
    p.active = i;
    invalidatePaint();
  }
  return true;
}

/** A move with the picker open: the row under the pointer takes the highlight. */
export function selectPopupPointerMove(x: number, y: number): boolean {
  const p = open;
  if (p === null) return false;
  layout(p);
  if (!inside(p, x, y)) return true;
  const i = rowAt(p, x, y);
  const row = i >= 0 ? p.opts.rows[i] : null;
  if (row !== null && row.kind === ROW_OPTION && !row.disabled && i !== p.active) {
    p.active = i;
    invalidatePaint();
  }
  return true;
}

/** The release of a press that began in the panel: a row under it is picked and the picker closes. */
export function selectPopupPointerUp(x: number, y: number): boolean {
  if (swallowUp) {
    swallowUp = false;
    return true;
  }
  const p = open;
  if (p === null) return false;
  layout(p);
  const pressed = p.pressing;
  p.pressing = false;
  if (!inside(p, x, y)) {
    closeSelectPopup();
    return true;
  }
  const i = rowAt(p, x, y);
  const row = i >= 0 ? p.opts.rows[i] : null;
  if (pressed && row !== null && row.kind === ROW_OPTION && !row.disabled) {
    p.active = i;
    commitActive(p);
    closeSelectPopup();
  }
  return true;
}

/** Which row the last type-ahead search landed on, so a repeated letter can walk on. */
function typeAhead(p: OpenPopup, ch: string): void {
  const now = Date.now();
  if (now - p.typedAt > 1000) p.typed = "";
  p.typedAt = now;
  const letter = ch.toLowerCase();
  const rows = p.opts.rows;
  let prefix = p.typed + letter;
  let hit = searchRows(rows, prefix, p.active);
  if (hit < 0 && p.typed !== "") {
    prefix = letter;
    hit = searchRows(rows, prefix, p.active);
  }
  if (hit < 0) return;
  p.typed = prefix;
  setActive(p, hit);
}

/** The first selectable option after `from`, wrapping round, whose label starts with `prefix`. */
function searchRows(rows: SelectPopupRow[], prefix: string, from: number): number {
  if (prefix === "") return -1;
  const n = rows.length;
  for (let k = 1; k <= n; k++) {
    const i = (from + k) % n;
    const row = rows[i];
    if (row.kind !== ROW_OPTION || row.disabled) continue;
    if (row.label.toLowerCase().startsWith(prefix)) return i;
  }
  return -1;
}

/**
 * A key while the picker is open. The arrows, Home and End move the highlight and put its option in
 * the field, as Chrome's menulist does; typed letters move it to the option they start; Enter and
 * Space pick the highlighted row and close; Escape closes and keeps the choice already made; Tab
 * closes and lets the keyboard handler move focus on.
 */
export function selectPopupKey(code: number, mods: number, text: string): number {
  const p = open;
  if (p === null) return POPUP_NONE;
  if (!p.opts.alive()) {
    closeSelectPopup();
    return POPUP_NONE;
  }
  layout(p);
  if (code === KEY_ESCAPE) {
    closeSelectPopup();
    return POPUP_HANDLED;
  }
  if (code === KEY_TAB) {
    closeSelectPopup();
    return POPUP_TAB;
  }
  if (code === KEY_ENTER || (code === KEY_TEXT && text === " ")) {
    if (p.active >= 0) commitActive(p);
    closeSelectPopup();
    return POPUP_HANDLED;
  }
  if (code === KEY_UP && (mods & MOD_ALT) !== 0) {
    if (p.active >= 0) commitActive(p);
    closeSelectPopup();
    return POPUP_HANDLED;
  }
  if (code === KEY_DOWN || code === KEY_UP) {
    const at = p.active >= 0 ? p.active : (code === KEY_DOWN ? -1 : p.rowTop.length);
    const next = nextSelectable(p, at + (code === KEY_DOWN ? 1 : -1), code === KEY_DOWN ? 1 : -1);
    if (next >= 0) setActive(p, next);
    return POPUP_HANDLED;
  }
  if (code === KEY_HOME || code === KEY_END) {
    const next = code === KEY_HOME ? nextSelectable(p, 0, 1)
      : nextSelectable(p, p.opts.rows.length - 1, -1);
    if (next >= 0) setActive(p, next);
    return POPUP_HANDLED;
  }
  if (code === KEY_TEXT && text.length > 0 && text !== " ") {
    typeAhead(p, text);
    return POPUP_HANDLED;
  }
  return POPUP_NONE;
}

/** A wheel over the open picker scrolls its rows, and nothing else. */
export function selectPopupWheel(x: number, y: number, dy: number): boolean {
  const p = open;
  if (p === null) return false;
  layout(p);
  if (!inside(p, x, y) || p.maxScroll <= 0) return inside(p, x, y);
  p.scroll -= dy;
  if (p.scroll < 0) p.scroll = 0;
  if (p.scroll > p.maxScroll) p.scroll = p.maxScroll;
  invalidatePaint();
  return true;
}

/** Paints the open picker over the page: its shadow, its edge and face, its rows and its bar. */
export function paintSelectPopup(): void {
  const p = open;
  if (p === null) return;
  if (!p.opts.alive()) {
    open = null;
    return;
  }
  layout(p);
  const st = p.opts.style;
  const box = st.dark ? DARK : LIGHT;
  const accent = st.accent < 0 ? ACCENT : st.accent;
  const x = p.x;
  const y = p.y;
  const w = p.w;
  const h = p.h;
  if (w <= 0 || h <= 0) return;
  hostShadowOuter(x, y, w, h, CORNER, CORNER, CORNER, CORNER, CORNER, CORNER, CORNER, CORNER,
    0, 2, 8, 0, box.shadow);
  hostFillRect(x, y, w, h, CORNER, box.border);
  if (w > 2 && h > 2) hostFillRect(x + BORDER, y + BORDER, w - BORDER * 2, h - BORDER * 2, CORNER, box.bg);
  const top = rowsTop(p);
  const view = rowsViewH(p);
  const scrollable = p.maxScroll > 0;
  const textRight = w - BORDER * 2 - (scrollable ? SCROLLBAR + 3 : 0);
  const lh = st.lineHeight;
  hostClipPush(p.serial, P.PK_CLIP_RECT, x + BORDER, top, w - BORDER * 2, view, 0);
  for (let i = 0; i < p.opts.rows.length; i++) {
    const row = p.opts.rows[i];
    const rt = top + p.rowTop[i] - p.scroll;
    const rh = p.rowH[i];
    if (rt + rh <= top || rt >= top + view) continue;
    if (row.kind === ROW_GROUP) {
      hostText(row.label, x + BORDER + ITEM_PAD, rt + (rh - lh) / 2, lh, st.size, st.font,
        box.group, st.letter, st.word, 0, 0);
      continue;
    }
    const lit = i === p.active;
    if (lit) hostFillRect(x + BORDER, rt, Math.max(0, textRight), rh, 0, accent);
    const color = lit ? HIGHLIGHT_TEXT : row.disabled ? box.disabled : st.color;
    hostText(row.label, x + BORDER + ITEM_PAD, rt + (rh - lh) / 2, lh, st.size, st.font,
      color, st.letter, st.word, 0, 0);
  }
  hostClipPop();
  if (scrollable) {
    const track = Math.max(0, view - 4);
    const thumb = Math.max(20, (track * view) / (p.contentH + PAD * 2));
    const ty = top + 2 + ((track - thumb) * p.scroll) / p.maxScroll;
    const color = st.dark ? 0xffffff55 : 0x00000055;
    hostFillRect(x + w - BORDER - 3 - SCROLLBAR, ty, SCROLLBAR, thumb, SCROLLBAR / 2, color);
  }
}
