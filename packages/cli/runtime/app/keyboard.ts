// Keyboard input: key events, focus cycling and text-field editing.

import * as P from "../../shared/props.ts";
import { Node, Element, HTMLButtonElement, HTMLInputElement, HTMLSelectElement, HTMLTextAreaElement, InputEvent, KeyboardEvent, document, dispatch, trusted, implicitSubmit, markPaintDirty, invalidatePaint, focusState, setFocus, noteInput, noteUserActivation, dismissPopover, openSelectMenu, controlKind, rangeSpec, setRangeValue, CONTROL_NONE, CONTROL_RANGE, inDisabledFormControl, dateKind, dateSegments, dateTypeText, dateStepActive, dateMoveActive, dateClearActive, dateSetActive, editingHostFor } from "../dom.ts";
import { deleteTextIn, insertTextInto, moveCaretIn, selectHost } from "../editable.ts";
import { datePickerKey, closeDatePicker } from "../date-picker.ts";
import { caret, textAreaLineStarts } from "../paint.ts";
import { textWidth } from "../layout.ts";
import { padV } from "../layout/box-model.ts";
import { lineHeightPx } from "../style.ts";
import { dispatchWindow } from "../window.ts";
import { copyFieldText, copySelection, cutFieldText, cutSelection, pasteAt } from "../editing.ts";
import { hostEventKey, hostEventMods, hostEventRepeat, hostEventText, hostCompositionPhase, hostCompositionText, KEY_TEXT, KEY_BACKSPACE, KEY_ENTER, KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_HOME, KEY_END, KEY_ESCAPE, KEY_TAB, KEY_DELETE, KEY_SELECT_ALL, KEY_COPY, KEY_CUT, KEY_PASTE, MOD_META, MOD_SHIFT, MOD_ALT, MOD_CTRL } from "../host.ts";
import { POPUP_HANDLED, selectPopupKey, selectPopupOpen } from "../select-popup.ts";
import { compositionCancel, compositionEnd, compositionStart, compositionUpdate, isComposing } from "../composition.ts";

// ---------------------------------------------------------------------------
// Keyboard

/** A key a test presses by name rather than by character (a modifier): it types nothing. */
const KEY_MODIFIER = -3;

function keyName(code: number, text: string): string {
  if (code === KEY_TEXT) return text;
  if (code === KEY_MODIFIER) return text;
  if (code === KEY_BACKSPACE) return "Backspace";
  if (code === KEY_ENTER) return "Enter";
  if (code === KEY_LEFT) return "ArrowLeft";
  if (code === KEY_RIGHT) return "ArrowRight";
  if (code === KEY_UP) return "ArrowUp";
  if (code === KEY_DOWN) return "ArrowDown";
  if (code === KEY_HOME) return "Home";
  if (code === KEY_END) return "End";
  if (code === KEY_ESCAPE) return "Escape";
  if (code === KEY_TAB) return "Tab";
  if (code === KEY_DELETE) return "Delete";
  if (code === KEY_SELECT_ALL) return "a";
  if (code === KEY_COPY) return "c";
  if (code === KEY_CUT) return "x";
  if (code === KEY_PASTE) return "v";
  return "Unidentified";
}

/** The physical key's name, as a browser reports it: "KeyA", "Space", "ArrowLeft" and so on. */
function keyCodeName(code: number, text: string): string {
  if (code === KEY_MODIFIER) {
    if (text === "Shift") return "ShiftLeft";
    if (text === "Control") return "ControlLeft";
    if (text === "Alt") return "AltLeft";
    if (text === "Meta") return "MetaLeft";
    return text;
  }
  if (code === KEY_TEXT) {
    if (text === " ") return "Space";
    if (text.length === 1 && text >= "a" && text <= "z") return "Key" + text.toUpperCase();
    if (text.length === 1 && text >= "0" && text <= "9") return "Digit" + text;
    return "";
  }
  if (code === KEY_COPY) return "KeyC";
  if (code === KEY_CUT) return "KeyX";
  if (code === KEY_PASTE) return "KeyV";
  return keyName(code, text);
}

function isSpace(ch: string): boolean {
  return ch === " " || ch === "\t";
}

function wordStartBefore(s: string, i: number): number {
  while (i > 0 && isSpace(s[i - 1])) i--;
  while (i > 0 && !isSpace(s[i - 1])) i--;
  return i;
}

function wordEndAfter(s: string, i: number): number {
  while (i < s.length && isSpace(s[i])) i++;
  while (i < s.length && !isSpace(s[i])) i++;
  return i;
}

function focusables(el: Node, out: Element[]): Element[] {
  if (el.sv[P.P_DISPLAY] === P.D_NONE) return out;
  // An inert subtree is out of the tab order entirely.
  if (el instanceof Element && el.inertRoot() !== null) return out;
  if (el instanceof Element && el.isFocusable) out.push(el);
  for (const c of el.kids) focusables(c, out);
  return out;
}

/**
 * The page's sequential focus order, as Chrome walks it: positive tabindex values first, ascending
 * and then in document order, then everything else in document order. Links, buttons and form
 * controls are all in it whatever the system's keyboard-navigation setting is.
 */
function sequentialFocus(): Element[] {
  const all = focusables(document.documentElement, []);
  const positive: Element[] = [];
  const rest: Element[] = [];
  for (const el of all) {
    if (el.tabIndex > 0) positive.push(el);
    else rest.push(el);
  }
  // Array.prototype.sort is stable, so equal tabindex values keep document order.
  positive.sort((a, b) => a.tabIndex - b.tabIndex);
  return positive.concat(rest);
}

function cycleFocus(step: number): void {
  const list = sequentialFocus();
  if (list.length === 0) return;
  const i = focusState.el !== null ? list.indexOf(focusState.el) : -1;
  const next = list[(i + step + list.length) % list.length];
  setFocus(next, true);
  if (next instanceof HTMLInputElement) next.select();
}

/** Applies an editing key to a focused input. Returns true if the value changed. */
function editInput(input: HTMLInputElement, code: number, mods: number, text: string): boolean {
  const v = input.value;
  const s = input.selectionStart;
  const e = input.selectionEnd;
  const collapsed = s === e;
  const extend = (mods & MOD_SHIFT) !== 0;
  const byWord = (mods & MOD_ALT) !== 0;
  const byLine = (mods & MOD_META) !== 0;
  const at = input.caretEnd;

  if (code === KEY_TEXT) {
    input.replaceSelection(text);
    return true;
  }
  if (code === KEY_BACKSPACE || code === KEY_DELETE) {
    if (collapsed) {
      const back = code === KEY_BACKSPACE;
      let to = back ? s - 1 : s + 1;
      if (byLine) to = back ? 0 : v.length;
      else if (byWord) to = back ? wordStartBefore(v, s) : wordEndAfter(v, s);
      to = Math.max(0, Math.min(to, v.length));
      if (to === s) return false;
      input.setSelectionRange(Math.min(s, to), Math.max(s, to));
    }
    input.replaceSelection("");
    return true;
  }
  if (code === KEY_LEFT || code === KEY_RIGHT) {
    const left = code === KEY_LEFT;
    let to = left ? at - 1 : at + 1;
    if (byLine) to = left ? 0 : v.length;
    else if (byWord) to = left ? wordStartBefore(v, at) : wordEndAfter(v, at);
    else if (!collapsed && !extend) to = left ? s : e;
    input.moveCaret(to, extend);
    return false;
  }
  if (code === KEY_HOME || code === KEY_UP) {
    input.moveCaret(0, extend);
    return false;
  }
  if (code === KEY_END || code === KEY_DOWN) {
    input.moveCaret(v.length, extend);
    return false;
  }
  if (code === KEY_SELECT_ALL) {
    input.select();
    return false;
  }
  if (code === KEY_ENTER) input.commit();
  return false;
}

/**
 * Applies an editing key to a focused textarea. Returns true if the text changed. Enter inserts a
 * newline here, and Home and End take the caret to the ends of the line it is on.
 */
function editTextArea(ta: HTMLTextAreaElement, code: number, mods: number, text: string): boolean {
  const v = ta.value;
  const s = ta.selectionStart;
  const e = ta.selectionEnd;
  const collapsed = s === e;
  const extend = (mods & MOD_SHIFT) !== 0;
  const byWord = (mods & MOD_ALT) !== 0;
  const byLine = (mods & MOD_META) !== 0;
  const at = ta.caretEnd;

  if (code === KEY_TEXT) {
    ta.replaceSelection(text);
    return true;
  }
  if (code === KEY_ENTER) {
    ta.replaceSelection("\n");
    return true;
  }
  if (code === KEY_BACKSPACE || code === KEY_DELETE) {
    if (collapsed) {
      const back = code === KEY_BACKSPACE;
      let to = back ? at - 1 : at + 1;
      if (byLine) to = back ? 0 : v.length;
      else if (byWord) to = back ? wordStartBefore(v, at) : wordEndAfter(v, at);
      to = Math.max(0, Math.min(to, v.length));
      if (to === at) return false;
      ta.setSelectionRange(Math.min(at, to), Math.max(at, to));
    }
    ta.replaceSelection("");
    return true;
  }
  if (code === KEY_LEFT || code === KEY_RIGHT) {
    const left = code === KEY_LEFT;
    let to = left ? at - 1 : at + 1;
    if (byLine) to = left ? 0 : v.length;
    else if (byWord) to = left ? wordStartBefore(v, at) : wordEndAfter(v, at);
    else if (!collapsed && !extend) to = left ? s : e;
    ta.moveCaret(to, extend);
    return false;
  }
  if (code === KEY_UP || code === KEY_DOWN) {
    moveByLine(ta, code === KEY_DOWN, extend);
    return false;
  }
  if (code === KEY_HOME) {
    ta.moveCaret(lineStartAt(v, at), extend);
    return false;
  }
  if (code === KEY_END) {
    ta.moveCaret(lineEndAt(v, at), extend);
    return false;
  }
  if (code === KEY_SELECT_ALL) {
    ta.select();
    return false;
  }
  return false;
}

/** The line of the wrapped lines the caret is on. */
function caretLine(ta: HTMLTextAreaElement, starts: number[]): number {
  let line = 0;
  for (let i = 0; i < starts.length; i++) if (starts[i] <= ta.caretEnd) line = i;
  return line;
}

/** Moves the caret a wrapped line up or down, keeping how far into the line it was. */
function moveByLine(ta: HTMLTextAreaElement, down: boolean, extend: boolean): void {
  const starts = textAreaLineStarts(ta);
  if (starts.length === 0) return;
  const line = caretLine(ta, starts);
  const x = textWidth(ta, ta.lines[line].slice(0, Math.max(0, ta.caretEnd - starts[line])));
  const next = Math.max(0, Math.min(starts.length - 1, line + (down ? 1 : -1)));
  const text = ta.lines[next];
  let best = 0;
  let bestDist = Infinity;
  for (let i = 0; i <= text.length; i++) {
    const d = Math.abs(textWidth(ta, text.slice(0, i)) - x);
    if (d < bestDist) {
      bestDist = d;
      best = i;
    }
  }
  ta.moveCaret(starts[next] + best, extend);
}

/** Scrolls a textarea so the line the caret is on is inside it, as typing at an edge does. */
function caretIntoView(ta: HTMLTextAreaElement): void {
  const starts = textAreaLineStarts(ta);
  if (starts.length === 0) return;
  const line = caretLine(ta, starts);
  const lh = lineHeightPx(ta);
  const top = line * lh;
  // The field shows its content box plus the padding at each edge, so the last line it can show
  // ends one padding below the content box's bottom; a caret at that edge scrolls it into view.
  let pad = padV(ta, ta.contentW) / 2;
  if (!(pad > 0)) pad = 0;
  let y = ta.scrollY;
  if (top < y) y = Math.max(0, top - pad);
  else if (top + lh > ta.contentH + pad) y = Math.max(0, top + lh - ta.contentH - pad);
  if (y === y && y !== ta.scrollY) ta.scrollInstant(ta.scrollX, y);
}

/** Where the line the index sits on starts: the text after the newline before it. */
function lineStartAt(v: string, at: number): number {
  let i = at;
  while (i > 0 && v[i - 1] !== "\n") i--;
  return i;
}

/** Where the line the index sits on ends: the newline at or after it, or the end of the text. */
function lineEndAt(v: string, at: number): number {
  let i = at;
  while (i < v.length && v[i] !== "\n") i++;
  return i;
}

/**
 * The WPT harness's test_driver.send_keys(): sends each key a test names to the focused element
 * through the same path the host's key events take. The keys are WebDriver's, where U+E003 is
 * Backspace, U+E017 Delete, U+E007 Enter, U+E008 Shift, U+E03D Meta and so on; every other
 * character is typed text.
 */
export function __nativeSendKeys(element: any, keys: any): void {
  if (element !== null && element !== undefined && typeof element.focus === "function") element.focus();
  let mods = 0;
  const text = String(keys);
  for (const ch of text) {
    const at = ch.charCodeAt(0);
    if (at === 0x00e003) keyDown(KEY_BACKSPACE, mods, "");
    else if (at === 0x00e004) keyDown(KEY_TAB, mods, "");
    else if (at === 0x00e006 || at === 0x00e007) keyDown(KEY_ENTER, mods, "");
    else if (at === 0x00e00c) keyDown(KEY_ESCAPE, mods, "");
    else if (at === 0x00e00d) keyDown(KEY_TEXT, mods, " ");
    else if (at === 0x00e010) keyDown(KEY_END, mods, "");
    else if (at === 0x00e011) keyDown(KEY_HOME, mods, "");
    else if (at === 0x00e012) keyDown(KEY_LEFT, mods, "");
    else if (at === 0x00e013) keyDown(KEY_UP, mods, "");
    else if (at === 0x00e014) keyDown(KEY_RIGHT, mods, "");
    else if (at === 0x00e015) keyDown(KEY_DOWN, mods, "");
    else if (at === 0x00e017) keyDown(KEY_DELETE, mods, "");
    else if (at === 0x00e008) mods |= MOD_SHIFT;
    else if (at === 0x00e009) mods |= MOD_CTRL;
    else if (at === 0x00e00a) mods |= MOD_ALT;
    else if (at === 0x00e03d) mods |= MOD_META;
    else keyDown(KEY_TEXT, mods, ch);
  }
}

/**
 * One WebDriver key value from a test_driver.Actions source: presses or releases it through the
 * same path the host's keys take, so the event is trusted, and answers the modifier state that
 * holds afterwards. The values are WebDriver's: U+E003 Backspace, U+E007 Enter, U+E008 Shift,
 * U+E03D Meta and so on; every other character is typed text.
 */
export function actionKey(value: string, mods: number, down: boolean): number {
  const ch = value.length === 0 ? 0 : value.charCodeAt(0);
  let code = KEY_TEXT;
  let text = value;
  let mod = 0;
  if (ch === 0x00e003) { code = KEY_BACKSPACE; text = ""; }
  else if (ch === 0x00e004) { code = KEY_TAB; text = ""; }
  else if (ch === 0x00e006 || ch === 0x00e007) { code = KEY_ENTER; text = ""; }
  else if (ch === 0x00e00c) { code = KEY_ESCAPE; text = ""; }
  else if (ch === 0x00e00d) { text = " "; }
  else if (ch === 0x00e010) { code = KEY_END; text = ""; }
  else if (ch === 0x00e011) { code = KEY_HOME; text = ""; }
  else if (ch === 0x00e012) { code = KEY_LEFT; text = ""; }
  else if (ch === 0x00e013) { code = KEY_UP; text = ""; }
  else if (ch === 0x00e014) { code = KEY_RIGHT; text = ""; }
  else if (ch === 0x00e015) { code = KEY_DOWN; text = ""; }
  else if (ch === 0x00e017) { code = KEY_DELETE; text = ""; }
  else if (ch === 0x00e008) { mod = MOD_SHIFT; code = KEY_MODIFIER; text = "Shift"; }
  else if (ch === 0x00e009) { mod = MOD_CTRL; code = KEY_MODIFIER; text = "Control"; }
  else if (ch === 0x00e00a) { mod = MOD_ALT; code = KEY_MODIFIER; text = "Alt"; }
  else if (ch === 0x00e03d) { mod = MOD_META; code = KEY_MODIFIER; text = "Meta"; }
  if (down) {
    keyDown(code, mods | mod, text);
    return mods | mod;
  }
  keyUp(code, mods & ~mod, text);
  return mods & ~mod;
}

/**
 * A key came up. The event bubbles from the focused element, or the page when nothing is
 * focused, and reaches the window's listeners. Editing happens on keydown, so keyup only tells
 * the page the key is no longer held.
 */
export function keyUp(code: number, mods: number, text: string = ""): void {
  noteInput("key");
  const target: Node = focusState.el !== null ? focusState.el :
    document.body !== null ? document.body : document.documentElement;
  const ev = trusted(new KeyboardEvent("keyup", {
    bubbles: true,
    cancelable: true,
    key: keyName(code, text),
    code: keyCodeName(code, text),
    repeat: false,
    metaKey: (mods & MOD_META) !== 0,
    shiftKey: (mods & MOD_SHIFT) !== 0,
    altKey: (mods & MOD_ALT) !== 0,
    ctrlKey: (mods & MOD_CTRL) !== 0,
    isComposing: isComposing(),
  }));
  dispatch(ev, target);
  if (!ev.propagationStopped) dispatchWindow(ev);
}

export function keyDown(code: number, mods: number, text: string, repeat: boolean = false): void {
  noteInput("key");
  noteUserActivation();
  const target: Node = focusState.el !== null ? focusState.el :
    document.body !== null ? document.body : document.documentElement;
  const ev = trusted(new KeyboardEvent("keydown", {
    bubbles: true,
    cancelable: true,
    key: keyName(code, text),
    code: keyCodeName(code, text),
    repeat,
    metaKey: (mods & MOD_META) !== 0,
    shiftKey: (mods & MOD_SHIFT) !== 0,
    altKey: (mods & MOD_ALT) !== 0,
    ctrlKey: (mods & MOD_CTRL) !== 0,
    isComposing: isComposing(),
  }));
  dispatch(ev, target);
  // A key event bubbles past the document to the window, unless a listener stopped it.
  if (!ev.propagationStopped) dispatchWindow(ev);
  if (ev.defaultPrevented) return;
  // An input method owns the keys while it composes: the text it commits arrives as composition
  // events, and a key it leaves to the page (an arrow, say) must not edit the field under it.
  // The keys that leave the field end the composition first, as a browser does: Tab and Enter
  // commit the text, and Escape abandons it.
  if (isComposing()) {
    if (code === KEY_TAB || code === KEY_ENTER) compositionEnd();
    else if (code === KEY_ESCAPE) compositionCancel();
    else return;
  }
  // An open date picker owns the keys it uses: arrows move the day it would pick, Enter picks it
  // and Escape closes it.
  if (datePickerKey(code, mods, text)) return;
  // So does an open select picker: it moves its highlight, picks and closes. Tab closes it too,
  // and then goes on to move focus, as a browser's picker does.
  if (selectPopupOpen() && selectPopupKey(code, mods, text) === POPUP_HANDLED) return;
  if (code === KEY_TAB) {
    closeDatePicker();
    cycleFocus(ev.shiftKey ? -1 : 1);
    return;
  }
  // Escape is the open auto popover's light dismiss; a cancelled keydown never gets here.
  if (code === KEY_ESCAPE) {
    dismissPopover();
    return;
  }
  // Enter or Space on a focused button clicks it, as a browser does.
  const space = code === KEY_TEXT && text === " ";
  if (code === KEY_ENTER || space) {
    if (target instanceof HTMLButtonElement) {
      target.click();
      return;
    }
    if (target instanceof HTMLInputElement) {
      const t = target.type.toLowerCase();
      if (t === "button" || t === "reset" || t === "submit" || t === "image") {
        target.click();
        return;
      }
    }
  }
  // Cmd+C, Cmd+X and Cmd+V: the copy, cut and paste events, with a focused field's own selected
  // text or else the page's selection.
  if (code === KEY_COPY || code === KEY_CUT || code === KEY_PASTE) {
    // Both fields carry selectionStart and selectionEnd, so either takes the field path.
    const field = target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement ? target : null;
    if (code === KEY_COPY) {
      if (field !== null) copyFieldText(field);
      else copySelection();
    } else if (code === KEY_CUT) {
      if (field !== null) cutFieldText(field);
      else cutSelection();
    } else {
      pasteAt(target);
    }
    return;
  }
  // A contenteditable host edits its text through the selection: typing, Backspace and Delete
  // replace or remove what the caret covers, each behind a cancelable beforeinput.
  const host = target instanceof Element ? editingHostFor(target) : null;
  if (host !== null) {
    const command = (mods & (MOD_META | MOD_CTRL)) !== 0;
    // Cmd/Ctrl+A selects the host; other command and option keys are shortcuts, not text.
    if (code === KEY_SELECT_ALL || (command && text.toLowerCase() === "a")) {
      selectHost(host);
      return;
    }
    if (command || (mods & MOD_ALT) !== 0) return;
    if (code === KEY_TEXT && text !== "") {
      insertTextInto(host, text);
      return;
    }
    if (code === KEY_BACKSPACE) {
      deleteTextIn(host, false);
      return;
    }
    if (code === KEY_DELETE) {
      deleteTextIn(host, true);
      return;
    }
    const extend = (mods & MOD_SHIFT) !== 0;
    if (code === KEY_LEFT) { moveCaretIn(host, "left", extend); return; }
    if (code === KEY_RIGHT) { moveCaretIn(host, "right", extend); return; }
    if (code === KEY_HOME) { moveCaretIn(host, "home", extend); return; }
    if (code === KEY_END) { moveCaretIn(host, "end", extend); return; }
    if (code === KEY_UP || code === KEY_DOWN) return;
  }
  // A textarea edits its own text: Enter is a newline, and the caret walks the text it has.
  if (target instanceof HTMLTextAreaElement) {
    caret.visible = true;
    paintField(target);
    if (editTextArea(target, code, mods, text)) {
      dispatch(trusted(new InputEvent("input", { bubbles: true })), target);
    }
    caretIntoView(target);
    return;
  }
  // A focused select: a list box moves its choice with the arrows, and typing letters reaches the
  // option they start (type-ahead). A closed field opens its menu on Space, Enter or an arrow, and
  // the menu then owns the keys.
  if (target instanceof HTMLSelectElement) {
    if (target.isListBox) {
      if (code === KEY_UP || code === KEY_DOWN) {
        const at = target.selectedIndex;
        const next = Math.max(0, Math.min(target.options.length - 1, (at < 0 ? 0 : at) + (code === KEY_DOWN ? 1 : -1)));
        target.selectRow(next, "plain", next);
        return;
      }
    } else if (space || code === KEY_ENTER || code === KEY_UP || code === KEY_DOWN) {
      openSelectMenu(target);
      return;
    }
    if (code === KEY_TEXT) {
      typeAhead(target, text);
      return;
    }
    return;
  }
  if (target instanceof HTMLInputElement) {
    const kind = controlKind(target.type);
    if (kind !== CONTROL_NONE) {
      // Space ticks a checkbox or radio. A range takes the arrows as steps and Home and End as the
      // ends of its range; neither kind takes typed text.
      if (kind === CONTROL_RANGE) rangeKey(target, code);
      else if (space) target.click();
      return;
    }
    // A date or time field edits one segment at a time: digits fill it, the arrows step it up or
    // down, and left and right move between segments. A read-only field keeps its value.
    if (dateKind(target) !== null) {
      if (code === KEY_ENTER) {
        target.commit();
        implicitSubmit(target);
        return;
      }
      if (target.readOnly || inDisabledFormControl(target)) return;
      const count = dateSegments(target).length;
      if (code === KEY_TEXT) dateTypeText(target, text);
      else if (code === KEY_UP) dateStepActive(target, 1);
      else if (code === KEY_DOWN) dateStepActive(target, -1);
      else if (code === KEY_LEFT) dateMoveActive(target, -1);
      else if (code === KEY_RIGHT) dateMoveActive(target, 1);
      else if (code === KEY_BACKSPACE || code === KEY_DELETE) dateClearActive(target);
      else if (code === KEY_HOME) dateSetActive(target, 0);
      else if (code === KEY_END) dateSetActive(target, count - 1);
      else if (code === KEY_SELECT_ALL) dateSetActive(target, 0);
      return;
    }
    caret.visible = true;
    paintField(target);
    if (editInput(target, code, mods, text)) dispatch(trusted(new InputEvent("input", { bubbles: true })), target);
    // Enter in a single-line field submits the form it is in, as HTML's implicit submission has it.
    if (code === KEY_ENTER) implicitSubmit(target);
  }
}

/** Repaints a field for a caret move or an edit: the field's box holds the caret and the text,
 *  so a damaged frame records it alone instead of the whole page. */
function paintField(el: Element): void {
  markPaintDirty(el);
}

/** How long a typed prefix keeps collecting letters before it starts a new search, in ms. */
const TYPE_AHEAD_MS = 1000;
let typeAheadText = "";
let typeAheadAt = 0;

/**
 * Type-ahead on a select: the letters typed in a row pick the first option whose label starts with
 * them, ignoring case, and a repeat of the same letter walks through the options that start with
 * it. The field sends input then change when the choice moves, as a browser's does.
 */
function typeAhead(el: HTMLSelectElement, ch: string): void {
  if (ch === "" || ch === " ") return;
  const now = Date.now();
  if (now - typeAheadAt > TYPE_AHEAD_MS) typeAheadText = "";
  typeAheadAt = now;
  const letter = ch.toLowerCase();
  const options = el.options;
  const labels: string[] = [];
  for (const o of options) labels.push((o.label === "" ? o.text : o.label).toLowerCase());
  let prefix = typeAheadText + letter;
  let hits: number[] = [];
  for (let i = 0; i < labels.length; i++) if (labels[i].startsWith(prefix)) hits.push(i);
  if (hits.length === 0) {
    // A fresh letter starts over; a letter that matches nothing leaves the choice alone.
    typeAheadText = letter;
    prefix = letter;
    for (let i = 0; i < labels.length; i++) if (labels[i].startsWith(prefix)) hits.push(i);
    if (hits.length === 0) return;
  }
  // The same letter twice walks to the next option that starts with it.
  const repeat = typeAheadText.length === 1 && typeAheadText === letter;
  typeAheadText = prefix;
  let pick = hits[0];
  if (repeat) {
    const at = el.selectedIndex;
    for (const i of hits) if (i > at) {
      pick = i;
      break;
    }
  }
  el.selectRow(pick, "plain", pick);
}

/** A range field's own keys: the arrows move it a step, Home and End take it to its ends. */
function rangeKey(el: HTMLInputElement, code: number): void {
  const spec = rangeSpec(el);
  // `step="any"` has no steps to take, so a key moves by a hundredth of the range.
  const step = spec.step > 0 ? spec.step : (spec.max - spec.min) / 100;
  if (code === KEY_RIGHT || code === KEY_UP) setRangeValue(el, spec.value + step, true);
  else if (code === KEY_LEFT || code === KEY_DOWN) setRangeValue(el, spec.value - step, true);
  else if (code === KEY_HOME) setRangeValue(el, spec.min, true);
  else if (code === KEY_END) setRangeValue(el, spec.max, true);
}

export function hostKey(): void {
  const code = hostEventKey();
  let text = "";
  if (code === KEY_TEXT) hostEventText((t) => {
    text = t;
  });
  keyDown(code, hostEventMods(), text, hostEventRepeat() !== 0);
}

/** A key came up: the page hears keyup, which bubbles to the window like keydown does. */
export function hostKeyUp(): void {
  const code = hostEventKey();
  let text = "";
  if (code === KEY_TEXT) hostEventText((t) => {
    text = t;
  });
  keyUp(code, hostEventMods(), text);
}

/** An input method's composition changed: starts it, updates the marked text, commits it or
 *  cancels it, as the host's phase says. */
export function hostComposition(): void {
  const phase = hostCompositionPhase();
  let text = "";
  hostCompositionText((t) => {
    text = t;
  });
  if (phase === 0) compositionStart(text);
  else if (phase === 1) compositionUpdate(text);
  else if (phase === 2) compositionEnd(text);
  else if (phase === 3) compositionCancel();
}
