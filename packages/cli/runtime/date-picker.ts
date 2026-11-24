// The popup a date or time field opens from its button, drawn by the runtime above the page.
//
// A calendar for the date kinds, a month grid for a month field and a small hour-and-minute picker
// for a time; a datetime-local field gets the calendar with the time under it. The popup is painted
// after the top layer, so nothing on the page covers it, and a press inside it is the popup's
// rather than the page's. Picking a value sets the field and sends "input" and "change", as a
// browser's picker does.

import * as P from "../shared/props.ts";
import { HTMLInputElement, Event, InputEvent, dispatch, trusted, setFocus, invalidatePaint, dateKind, dateSetActive, inDisabledFormControl } from "./dom.ts";
import type { DateKind, DateParts } from "./date-times.ts";
import {
  monthName, daysInMonth, dayOfWeek, daysFromCivil, weekOfDays, formatDateText, parseDateText,
} from "./date-times.ts";
import { viewport, absolutePosition } from "./layout.ts";
import { textWidth } from "./layout/text.ts";
import { fontKey } from "./style.ts";
import { hostFillRect, hostText, hostFillPoly, KEY_ENTER, KEY_ESCAPE, KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN } from "./host.ts";

// Geometry, in CSS px. The popup is a fixed size so its cells are easy to reach and to test.
const PAD = 8;
const W = 272;
const HEADER = 30;
const WEEKDAY_H = 20;
const CELL_W = 36;
const CELL_H = 30;
const CAL_ROWS = 6;
const CAL_H = PAD + HEADER + WEEKDAY_H + CAL_ROWS * CELL_H + PAD;
const MONTH_GRID_H = PAD + HEADER + 4 * 40 + PAD;
const TIME_H = 52;
const TIME_W = 200;
const TIME_ONLY_H = 56;

const WHITE = 0xffffffff;
const TEXT = 0x202124ff;
const MUTED = 0x5f6368ff;
const BORDER = 0xc4c4c4ff;
const ACCENT = 0x0075ffff;
const WEEKDAYS = ["S", "M", "T", "W", "T", "F", "S"];
/** A week field's rows are ISO weeks, which start on Monday, so its calendar does too. */
const WEEKDAYS_MONDAY = ["M", "T", "W", "T", "F", "S", "S"];
const MONTH_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

interface Picker {
  input: HTMLInputElement;
  kind: DateKind;
  /** The month the calendar shows, 0 through 11. */
  viewMonth: number;
  viewYear: number;
  /** The day the keyboard would pick, or 0 when none is marked. */
  highlighted: number;
  /** The time of day a time picker shows, on the 24-hour clock. */
  hour: number;
  minute: number;
}

let picker: Picker | null = null;
/** Whether the last press was inside the popup, so its release isn't the page's. */
let pressOwned = false;

export function isDatePickerOpen(): boolean {
  return picker !== null;
}

/** The field a picker is open for, or null. */
export function datePickerInput(): HTMLInputElement | null {
  return picker === null ? null : picker.input;
}

/**
 * Opens the picker for a field, at the month its value names (or this month when it has none),
 * with the time its value names (or midnight). A read-only or disabled field opens nothing.
 */
export function openDatePicker(input: HTMLInputElement): void {
  const kind = dateKind(input);
  if (kind === null || input.readOnly || inDisabledFormControl(input)) return;
  const now = new Date();
  let year = now.getFullYear();
  let month = now.getMonth();
  let day = 0;
  let hour = 0;
  let minute = 0;
  // A value names the month the calendar starts at, the day it marks, and the time it shows.
  const parts = parseDateText(kind, input.value);
  if (parts !== null) {
    if (kind !== "time") {
      year = parts.year;
      month = parts.month - 1;
      day = kind === "date" || kind === "datetime-local" || kind === "week" ? parts.day : 0;
    }
    hour = parts.hour;
    minute = parts.minute;
  }
  picker = {
    input, kind, viewMonth: month, viewYear: year, highlighted: day, hour, minute,
  };
  pressOwned = false;
  // The field marks its first segment while the picker is open, as it does when focused.
  dateSetActive(input, 0);
  invalidatePaint();
}

export function closeDatePicker(): void {
  if (picker === null) return;
  picker = null;
  pressOwned = false;
  invalidatePaint();
}

/** The popup's [x, y, width, height] in viewport coordinates. */
export function datePickerRect(): number[] {
  if (picker === null) return [0, 0, 0, 0];
  const input = picker.input;
  const p = absolutePosition(input);
  const width = picker.kind === "time" ? TIME_W : W;
  const height = picker.kind === "time" ? TIME_ONLY_H
    : picker.kind === "month" ? MONTH_GRID_H
      : picker.kind === "datetime-local" ? CAL_H + TIME_H : CAL_H;
  let x = p[0];
  let y = p[1] + input.h + 4;
  if (y + height > viewport.h && p[1] - height - 4 >= 0) y = p[1] - height - 4;
  x = Math.max(0, Math.min(x, viewport.w - width));
  y = Math.max(0, Math.min(y, viewport.h - height));
  return [x, y, width, height];
}

/** Whether a viewport point falls inside the open popup. */
export function datePickerContains(x: number, y: number): boolean {
  const r = datePickerRect();
  return x >= r[0] && x <= r[0] + r[2] && y >= r[1] && y <= r[1] + r[3];
}

// ---------------------------------------------------------------------------
// Painting

/** A string's width at a font size other than the field's own. */
function widthAt(el: HTMLInputElement, text: string, size: number): number {
  const base = el.sv[P.P_FONT_SIZE];
  if (base <= 0) return text.length * size * 0.55;
  return textWidth(el, text) * size / base;
}

function drawText(el: HTMLInputElement, text: string, x: number, y: number, size: number, color: number): number {
  hostText(text, x, y, size * 1.3, size, fontKey(el), color, 0, 0, 0, 0);
  return widthAt(el, text, size);
}

function centerText(el: HTMLInputElement, text: string, cx: number, y: number, size: number, color: number): void {
  drawText(el, text, cx - widthAt(el, text, size) / 2, y, size, color);
}

function accentOf(el: HTMLInputElement): number {
  return el.sv[P.P_ACCENT_COLOR] < 0 ? ACCENT : el.sv[P.P_ACCENT_COLOR];
}

/** A chevron pointing left or right, as a small filled triangle drawn flat. */
function chevron(x: number, y: number, size: number, right: boolean, color: number): void {
  const tip = right ? x + size : x;
  const back = right ? x : x + size;
  hostFillPoly(`${back},${y - 4} ${back},${y + 4} ${tip},${y}`, color);
}

/** A small triangle pointing up or down, for a time picker's steppers. */
function triangle(cx: number, cy: number, up: boolean, color: number): void {
  const d = up ? -1 : 1;
  hostFillPoly(`${cx - 3},${cy - 2 * d} ${cx + 3},${cy - 2 * d} ${cx},${cy + 3 * d}`, color);
}

/** The month view's day cells: the column the first day sits in, and how many days there are. */
function monthGrid(year: number, month: number): number[] {
  const dow = dayOfWeek(daysFromCivil(year, month + 1, 1));
  const first = picker !== null && picker.kind === "week" ? (dow + 6) % 7 : dow;
  return [first, daysInMonth(year, month + 1)];
}

/** The day cell at a viewport point, or 0 when the point isn't on one. */
function dayAt(x: number, y: number, rect: number[]): number {
  const gridTop = rect[1] + PAD + HEADER + WEEKDAY_H;
  if (x < rect[0] + PAD || x >= rect[0] + PAD + 7 * CELL_W) return 0;
  const col = Math.floor((x - rect[0] - PAD) / CELL_W);
  const row = Math.floor((y - gridTop) / CELL_H);
  if (row < 0 || row >= CAL_ROWS || col < 0 || col > 6) return 0;
  const grid = monthGrid(picker!.viewYear, picker!.viewMonth);
  const day = row * 7 + col - grid[0] + 1;
  return day >= 1 && day <= grid[1] ? day : 0;
}

/** The time cells' boxes: hour and minute columns with steppers, and the AM or PM box. */
function timeBoxes(rect: number[]): number[][] {
  const groupW = 52 + 8 + 52 + 8 + 44;
  const bx = rect[0] + (rect[2] - groupW) / 2;
  const baseY = rect[1] + rect[3] - PAD - 40;
  return [
    [bx, baseY, 52, 10], // hour up
    [bx, baseY + 10, 52, 24], // hour value
    [bx, baseY + 34, 52, 10], // hour down
    [bx + 60, baseY, 52, 10], // minute up
    [bx + 60, baseY + 10, 52, 24], // minute value
    [bx + 60, baseY + 34, 52, 10], // minute down
    [bx + 120, baseY + 10, 44, 24], // AM/PM
  ];
}

function paintDayCell(el: HTMLInputElement, rect: number[], row: number, col: number, day: number, selected: boolean, weekLit: boolean): void {
  const x = rect[0] + PAD + col * CELL_W;
  const y = rect[1] + PAD + HEADER + WEEKDAY_H + row * CELL_H;
  const accent = accentOf(el);
  if (weekLit) hostFillRect(x, y, CELL_W, CELL_H, 0, 0xe8f0feff);
  if (selected) hostFillRect(x + 8, y + 4, CELL_W - 16, CELL_H - 8, 15, accent);
  centerText(el, String(day), x + CELL_W / 2, y + 8, 13, selected ? WHITE : TEXT);
}

/** Paints the open picker, if there is one. Called after the top layer by the painter. */
export function paintDatePicker(): void {
  if (picker === null) return;
  const el = picker.input;
  // A field that left the document takes its popup with it.
  if (!el.isConnected) {
    closeDatePicker();
    return;
  }
  const rect = datePickerRect();
  const accent = accentOf(el);
  // The body and its border, then the month header.
  hostFillRect(rect[0] - 1, rect[1] - 1, rect[2] + 2, rect[3] + 2, 0, BORDER);
  hostFillRect(rect[0], rect[1], rect[2], rect[3], 0, WHITE);
  // A time field's popup is only the hour and minute picker.
  if (picker.kind === "time") {
    paintTimeRow(el, rect);
    return;
  }
  const headerY = rect[1] + PAD;
  chevron(rect[0] + PAD + 6, headerY + 10, 8, false, TEXT);
  chevron(rect[0] + rect[2] - PAD - 12, headerY + 10, 8, true, TEXT);
  if (picker.kind === "month") {
    centerText(el, String(picker.viewYear), rect[0] + rect[2] / 2, headerY, 14, TEXT);
    for (let i = 0; i < 12; i++) {
      const col = i % 3;
      const row = Math.floor(i / 3);
      const cx = rect[0] + PAD + col * ((rect[2] - PAD * 2) / 3);
      const cy = rect[1] + PAD + HEADER + row * 40;
      const selected = i === picker.viewMonth;
      if (selected) hostFillRect(cx + 2, cy, (rect[2] - PAD * 2) / 3 - 4, 32, 14, accent);
      centerText(el, MONTH_SHORT[i], cx + ((rect[2] - PAD * 2) / 3) / 2, cy + 7, 13, selected ? WHITE : TEXT);
    }
    return;
  }
  centerText(el, monthName(picker.viewMonth + 1) + " " + picker.viewYear,
    rect[0] + rect[2] / 2, headerY, 14, TEXT);
  // The weekday row, then the blank cells and days of the month.
  const labels = picker.kind === "week" ? WEEKDAYS_MONDAY : WEEKDAYS;
  for (let i = 0; i < 7; i++) {
    centerText(el, labels[i], rect[0] + PAD + i * CELL_W + CELL_W / 2,
      rect[1] + PAD + HEADER + 2, 11, MUTED);
  }
  const grid = monthGrid(picker.viewYear, picker.viewMonth);
  const selectedWeek = picker.highlighted > 0
    ? weekOfDays(daysFromCivil(picker.viewYear, picker.viewMonth + 1, picker.highlighted))
    : [0, 0];
  for (let i = 0; i < grid[1]; i++) {
    const day = i + 1;
    const cell = grid[0] + i;
    const row = Math.floor(cell / 7);
    const col = cell % 7;
    if (row >= CAL_ROWS) break;
    const sel = day === picker.highlighted && picker.kind !== "week";
    let weekLit = false;
    if (picker.kind === "week" && picker.highlighted > 0) {
      const w = weekOfDays(daysFromCivil(picker.viewYear, picker.viewMonth + 1, day));
      weekLit = w[0] === selectedWeek[0] && w[1] === selectedWeek[1];
    }
    paintDayCell(el, rect, row, col, day, sel, weekLit);
  }
  if (picker.kind === "datetime-local") paintTimeRow(el, rect);
}

function paintTimeRow(el: HTMLInputElement, rect: number[]): void {
  const boxes = timeBoxes(rect);
  const hour = picker!.hour % 12 === 0 ? 12 : picker!.hour % 12;
  const minute = picker!.minute;
  const ampm = picker!.hour < 12 ? "AM" : "PM";
  const accent = accentOf(el);
  for (const at of [1, 4]) {
    const bx = boxes[at];
    hostFillRect(bx[0], bx[1], bx[2], bx[3], 3, 0xf1f3f4ff);
  }
  triangle(boxes[0][0] + 26, boxes[0][1] + 6, true, MUTED);
  triangle(boxes[0][0] + 26, boxes[2][1] + 6, false, MUTED);
  triangle(boxes[3][0] + 26, boxes[3][1] + 6, true, MUTED);
  triangle(boxes[3][0] + 26, boxes[5][1] + 6, false, MUTED);
  centerText(el, String(hour), boxes[1][0] + 26, boxes[1][1] + 4, 14, TEXT);
  centerText(el, minute < 10 ? "0" + minute : String(minute), boxes[4][0] + 26, boxes[4][1] + 4, 14, TEXT);
  hostFillRect(boxes[6][0], boxes[6][1], boxes[6][2], boxes[6][3], 3, 0xf1f3f4ff);
  centerText(el, ampm, boxes[6][0] + boxes[6][2] / 2, boxes[6][1] + 4, 13, accent);
}

// ---------------------------------------------------------------------------
// Pointer

/** The new value a picked day in the calendar names, keeping the field's time where it has one. */
function valueForDay(day: number): string {
  const p = picker!;
  if (p.kind === "datetime-local") {
    return formatDateText("datetime-local", {
      year: p.viewYear, month: p.viewMonth + 1, day,
      hour: p.hour, minute: p.minute, second: 0, millisecond: 0,
    });
  }
  const parts: DateParts = {
    year: p.viewYear, month: p.viewMonth + 1, day, hour: 0, minute: 0, second: 0, millisecond: 0,
  };
  return formatDateText(p.kind === "week" ? "week" : "date", parts);
}

/** Sets the field's value and sends the events a user's pick sends. */
function pickValue(text: string): void {
  const el = picker!.input;
  closeDatePicker();
  if (text !== "" && text !== el.value) {
    el.value = text;
    dispatch(trusted(new InputEvent("input", { bubbles: true })), el);
    dispatch(trusted(new Event("change", { bubbles: true })), el);
  }
  setFocus(el);
  dateSetActive(el, 0);
  invalidatePaint();
}

function pickDay(day: number): void {
  pickValue(valueForDay(day));
}

function pickMonth(month: number): void {
  const p = picker!;
  pickValue(formatDateText("month", {
    year: p.viewYear, month: month + 1, day: 1, hour: 0, minute: 0, second: 0, millisecond: 0,
  }));
}

function pickTime(): void {
  const p = picker!;
  const parts: DateParts = {
    year: p.viewYear, month: p.viewMonth + 1, day: p.highlighted > 0 ? p.highlighted : 1,
    hour: p.hour, minute: p.minute, second: 0, millisecond: 0,
  };
  pickValue(formatDateText(p.kind, parts));
}

/**
 * Handles a press. Returns true when the popup took it; a press outside closes the popup and
 * returns false, so the page handles it as the press it was.
 */
export function datePickerPress(x: number, y: number): boolean {
  if (picker === null) return false;
  const rect = datePickerRect();
  if (!datePickerContains(x, y)) {
    closeDatePicker();
    return false;
  }
  const p = picker;
  const headerY = rect[1] + PAD;
  pressOwned = true;
  // The header's two chevrons move a month, or a year in the month grid; the title between them
  // does nothing.
  if (y >= headerY && y <= headerY + HEADER) {
    const before = x < rect[0] + PAD + 28;
    const after = x > rect[0] + rect[2] - PAD - 28;
    if (before || after) {
      if (p.kind === "month") {
        p.viewYear += before ? -1 : 1;
      } else if (before) {
        p.viewMonth--;
        if (p.viewMonth < 0) { p.viewMonth = 11; p.viewYear--; }
      } else {
        p.viewMonth++;
        if (p.viewMonth > 11) { p.viewMonth = 0; p.viewYear++; }
      }
      invalidatePaint();
    }
    return true;
  }
  if (p.kind === "month") {
    const col = Math.floor((x - rect[0] - PAD) / ((rect[2] - PAD * 2) / 3));
    const row = Math.floor((y - rect[1] - PAD - HEADER) / 40);
    if (col >= 0 && col <= 2 && row >= 0 && row <= 3) pickMonth(row * 3 + col);
    return true;
  }
  const timeTop = rect[1] + rect[3] - PAD - 40;
  if ((p.kind === "datetime-local" || p.kind === "time") && y >= timeTop) {
    const boxes = timeBoxes(rect);
    for (let i = 0; i < boxes.length; i++) {
      const b = boxes[i];
      if (x < b[0] || x > b[0] + b[2] || y < b[1] || y > b[1] + b[3]) continue;
      if (i === 0) p.hour = (p.hour + 1) % 24;
      else if (i === 2) p.hour = (p.hour + 23) % 24;
      else if (i === 3) p.minute = (p.minute + 1) % 60;
      else if (i === 5) p.minute = (p.minute + 59) % 60;
      else if (i === 6) p.hour = (p.hour + 12) % 24;
      else if (p.kind === "time") pickTime();
      invalidatePaint();
      return true;
    }
    return true;
  }
  const day = dayAt(x, y, rect);
  if (day !== 0) pickDay(day);
  return true;
}

/** The release that follows a press the popup took: true when it isn't the page's to see. */
export function datePickerRelease(): boolean {
  const owned = pressOwned;
  pressOwned = false;
  return owned;
}

// ---------------------------------------------------------------------------
// Keyboard

function dayCount(): number {
  return daysInMonth(picker!.viewYear, picker!.viewMonth + 1);
}

/** Moves the marked day within the shown month, opening the month's first day when none is marked. */
function moveHighlight(days: number): void {
  const p = picker!;
  let day = p.highlighted === 0 ? 1 : p.highlighted + days;
  while (day < 1) {
    p.viewMonth--;
    if (p.viewMonth < 0) { p.viewMonth = 11; p.viewYear--; }
    day += dayCount();
  }
  while (day > dayCount()) {
    day -= dayCount();
    p.viewMonth++;
    if (p.viewMonth > 11) { p.viewMonth = 0; p.viewYear++; }
  }
  p.highlighted = day;
}

/**
 * Handles a key for the open popup. Arrows move the day (a week at a time up and down), Enter or
 * Space picks it, and Escape closes the popup. Returns true when the popup used the key.
 */
export function datePickerKey(code: number, mods: number, text: string): boolean {
  if (picker === null) return false;
  if (code === KEY_ESCAPE) {
    closeDatePicker();
    return true;
  }
  const p = picker;
  if (p.kind === "time" || (p.kind === "datetime-local" && p.highlighted === 0 && code !== KEY_ENTER && text !== " ")) {
    if (code === KEY_UP) { p.hour = (p.hour + 1) % 24; invalidatePaint(); return true; }
    if (code === KEY_DOWN) { p.hour = (p.hour + 23) % 24; invalidatePaint(); return true; }
    if (code === KEY_RIGHT) { p.minute = (p.minute + 1) % 60; invalidatePaint(); return true; }
    if (code === KEY_LEFT) { p.minute = (p.minute + 59) % 60; invalidatePaint(); return true; }
    if (code === KEY_ENTER || text === " ") { pickTime(); return true; }
    return false;
  }
  if (code === KEY_LEFT) { moveHighlight(-1); invalidatePaint(); return true; }
  if (code === KEY_RIGHT) { moveHighlight(1); invalidatePaint(); return true; }
  if (code === KEY_UP) { moveHighlight(-7); invalidatePaint(); return true; }
  if (code === KEY_DOWN) { moveHighlight(7); invalidatePaint(); return true; }
  if (code === KEY_ENTER || text === " ") {
    if (p.highlighted > 0) pickDay(p.highlighted);
    return true;
  }
  void mods;
  return false;
}
