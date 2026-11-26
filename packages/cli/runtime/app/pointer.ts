// Pointer input: :hover/:active state, focus on press, click synthesis and text selection.

import * as P from "../../shared/props.ts";
import { Node, Element, Event, HTMLDialogElement, HTMLInputElement, HTMLOptionElement, HTMLSelectElement, HTMLTextAreaElement, MouseEvent, PointerEvent, document, dispatch, trusted, invalidateStyle, focusState, setFocus, runClickDefault, inDisabledFormControl, noteInput, noteUserActivation, lightDismissPopovers, controlKind, setRangeValue, notePointerActive, pointerCaptureElement, endPointerCapture, CONTROL_NONE, CONTROL_RANGE, topLayerElements, dateKind, dateSetActive } from "../dom.ts";
import { restyleForState } from "../style.ts";
import { invalidateLayout } from "../invalidation.ts";
import { inputIndexAt } from "../layout.ts";
import { rangeValueAt } from "../controls.ts";
import { hitTest, caret, textAreaIndexAt, dateSegmentAtPoint, dateIconContains } from "../paint.ts";
import { openDatePicker, datePickerPress, datePickerRelease, datePickerContains, isDatePickerOpen } from "../date-picker.ts";
import { hostSetCursor, hostSetCursorImage, MOD_META, MOD_SHIFT, MOD_ALT, MOD_CTRL } from "../host.ts";
import { appRegionAt, dragWindow } from "./titlebar.ts";
import { selectPopupPointerDown, selectPopupPointerMove, selectPopupPointerUp } from "../select-popup.ts";
import { beginSelectionAt, endSelectionDrag, extendSelectionTo, selectParagraphAt, selectWordAt } from "../selection.ts";
import { dragMove, dragUp, endDragPress, noteDragPress } from "./dnd.ts";
import { showContextMenu } from "../menus.ts";

// ---------------------------------------------------------------------------
// Pointer: :hover / :active, focus, click synthesis, text selection

export const pointer = {
  hovered: [] as Node[], pressed: null as Node | null, down: false, cursor: -1,
  /** The image cursor the pointer shows: its IMAGE_FILES id and hotspot, or -1 for a keyword. */
  cursorImage: -1, cursorX: 0, cursorY: 0,
  /** Where the pointer last was, and the modifiers it last carried, for the boundary events a
   *  crossing sends when the code that answers it also moves the window or scrolls the page. */
  x: 0, y: 0, mods: 0,
};

/** The range field a press began on, which follows the pointer until the button lifts. */
let rangeDrag: HTMLInputElement | null = null;
/** The row a list box's last plain press chose, which a Shift-press extends from. */
let selectAnchor = 0;
/** The value the dragged range had when the press landed, for deciding whether a change is due. */
let rangeStart = "";
/** The box whose resize grip the press took hold of: where it started, and the size it began at. */
const resizeDrag: { el: Element | null; x: number; y: number; w: number; h: number } =
  { el: null, x: 0, y: 0, w: 0, h: 0 };

/**
 * The box whose resize grip — the bottom-right corner a resizable box shows — holds the point.
 * Only the element under the pointer has a grip: an ancestor's corner isn't a child's.
 */
function resizeGripAt(target: Node | null, x: number, y: number): Element | null {
  let el: Node | null = target;
  while (el !== null && !el.isElementNode) el = el.parentNode;
  if (!(el instanceof Element)) return null;
  if (el.sv[P.P_RESIZE] === 0) return null;
  if (el.sv[P.P_OVERFLOW_X] === P.OV_VISIBLE && el.sv[P.P_OVERFLOW_Y] === P.OV_VISIBLE) return null;
  const r = el.getBoundingClientRect();
  const s = Math.min(16, r.width, r.height);
  return x >= r.right - s && y >= r.bottom - s ? el : null;
}

/** Grows or shrinks the dragged box by how far the pointer has moved since the press. */
function dragResize(x: number, y: number): void {
  const el = resizeDrag.el;
  if (el === null) return;
  const resize = el.sv[P.P_RESIZE];
  if ((resize & P.RESIZE_H) !== 0) el.resizeW = Math.max(0, Math.round(resizeDrag.w + (x - resizeDrag.x)));
  if ((resize & P.RESIZE_V) !== 0) el.resizeH = Math.max(0, Math.round(resizeDrag.h + (y - resizeDrag.y)));
  el.lOwnChanged = true;
  invalidateLayout(el);
}

function chain(el: Node | null): Node[] {
  const out: Node[] = [];
  let e = el;
  while (e !== null) {
    out.push(e);
    e = e.parentElement;
  }
  return out;
}

function setState(els: Node[], bit: number, on: boolean): void {
  for (const el of els) {
    const next = on ? el.state | bit : el.state & ~bit;
    if (next !== el.state) {
      el.state = next;
      restyleForState(el, bit);
    }
  }
}

export function updateHover(target: Node | null): void {
  const next = chain(target);
  const leaving: Node[] = [];
  for (const el of pointer.hovered) if (next.indexOf(el) < 0) leaving.push(el);
  const entering: Node[] = [];
  for (const el of next) if (pointer.hovered.indexOf(el) < 0) entering.push(el);
  const from = pointer.hovered.length > 0 ? pointer.hovered[0] : null;
  setState(leaving, P.S_HOVER, false);
  setState(next, P.S_HOVER, true);
  pointer.hovered = next;
  // A crossing sends its boundary events before anything else the move does, in the order the
  // web fires them: the target left hears out (even when the pointer only moved onto its child),
  // the elements it left behind hear leave, then the target entered hears over and the elements
  // newly entered hear enter. The pointer events go first, the mouse ones after, and each
  // event's related target names the other side of the crossing.
  if (from !== target) {
    const buttons = pointer.down ? 1 : 0;
    if (from !== null) {
      dispatch(pointerEvent("pointerout", pointer.x, pointer.y, buttons, 0, pointer.mods, target, true), from);
    }
    for (const el of leaving) dispatch(pointerEvent("pointerleave", pointer.x, pointer.y, buttons, 0, pointer.mods, target, false), el);
    if (target !== null) {
      dispatch(pointerEvent("pointerover", pointer.x, pointer.y, buttons, 0, pointer.mods, from, true), target);
    }
    // The outermost element entered hears first, the way a pointer crossing the edges in turn
    // would reach it.
    for (let i = entering.length - 1; i >= 0; i--) {
      dispatch(pointerEvent("pointerenter", pointer.x, pointer.y, buttons, 0, pointer.mods, from, false), entering[i]);
    }
    if (from !== null) {
      dispatch(mouseEvent("mouseout", pointer.x, pointer.y, 0, pointer.mods, 0, buttons, target, true), from);
    }
    for (const el of leaving) dispatch(mouseEvent("mouseleave", pointer.x, pointer.y, 0, pointer.mods, 0, buttons, target, false), el);
    if (target !== null) {
      dispatch(mouseEvent("mouseover", pointer.x, pointer.y, 0, pointer.mods, 0, buttons, from, true), target);
    }
    for (let i = entering.length - 1; i >= 0; i--) {
      dispatch(mouseEvent("mouseenter", pointer.x, pointer.y, 0, pointer.mods, 0, buttons, from, false), entering[i]);
    }
  }
  const cursor = target !== null ? target.sv[P.P_CURSOR] : P.C_DEFAULT;
  // A `cursor: url(…)` image wins over the keyword; its hotspot is in the image's pixels.
  const image = target !== null ? target.sv[P.P_CURSOR_IMAGE] : -1;
  const hx = target !== null ? target.sv[P.P_CURSOR_IMAGE_X] : 0;
  const hy = target !== null ? target.sv[P.P_CURSOR_IMAGE_Y] : 0;
  if (image >= 0) {
    if (image !== pointer.cursorImage || hx !== pointer.cursorX || hy !== pointer.cursorY) {
      pointer.cursorImage = image;
      pointer.cursorX = hx;
      pointer.cursorY = hy;
      pointer.cursor = -1;
      hostSetCursorImage(image, hx, hy);
    }
  } else if (cursor !== pointer.cursor) {
    pointer.cursor = cursor;
    pointer.cursorImage = -1;
    hostSetCursor(cursor);
  }
}

/** The modifier flags a pointer event carries, from the host's MOD_* bits. */
function modInit(mods: number): {
  metaKey: boolean; shiftKey: boolean; altKey: boolean; ctrlKey: boolean;
} {
  return {
    metaKey: (mods & MOD_META) !== 0,
    shiftKey: (mods & MOD_SHIFT) !== 0,
    altKey: (mods & MOD_ALT) !== 0,
    ctrlKey: (mods & MOD_CTRL) !== 0,
  };
}

function mouseEvent(type: string, x: number, y: number, detail: number = 0, mods: number = 0,
  button: number = 0, buttons: number = 0, related: Node | null = null, bubbles: boolean = true): MouseEvent {
  // A mouse event crosses shadow boundaries, so a page hears about a press inside a widget's tree.
  // `mouseenter`/`mouseleave` are the exception: they go to the element on its own, no bubbling,
  // and nothing about them is cancelable.
  return trusted(new MouseEvent(type, {
    bubbles, cancelable: bubbles, composed: bubbles, clientX: x, clientY: y, detail, button, buttons,
    relatedTarget: related, ...modInit(mods),
  }));
}

/**
 * The element under the pointer, top-layer elements first: they paint above the page, so they
 * take its presses. A modal dialog's backdrop swallows a press that reaches nothing in the layer.
 */
export function hitAt(x: number, y: number): Node | null {
  const layer = topLayerElements();
  let modal: Element | null = null;
  for (let i = layer.length - 1; i >= 0; i--) {
    const el = layer[i];
    const hit = hitTest(el, x, y, 0, 0);
    if (hit !== null) return hit;
    if (el instanceof HTMLDialogElement && el.isModal) modal = el;
  }
  // A modal dialog's backdrop covers the page, so a press on it reaches the dialog and not what
  // lies behind. Anything else falls through to the tree as before.
  return modal === null ? hitTest(document.documentElement, x, y, 0, 0) : modal;
}

/** The pointer event a mouse sends beside each of its own: the input here is always a mouse. */
function pointerEvent(type: string, x: number, y: number, buttons: number, detail: number = 0,
  mods: number = 0, related: Node | null = null, bubbles: boolean = true): PointerEvent {
  return trusted(new PointerEvent(type, {
    bubbles, cancelable: bubbles, composed: bubbles, clientX: x, clientY: y, detail,
    pointerId: 1, pointerType: "mouse", isPrimary: true, button: 0, buttons,
    relatedTarget: related, ...modInit(mods),
  }));
}

/** The option a hit falls in, if any. */
function optionAt(target: Node | null): HTMLOptionElement | null {
  let n: Node | null = target;
  while (n !== null) {
    if (n instanceof HTMLOptionElement) return n;
    if (n.isElementNode) return null;
    n = n.parentNode;
  }
  return null;
}

/** The list box a press on `option` chooses in: the select it sits in, through an option group. */
function listBoxOf(option: HTMLOptionElement): HTMLSelectElement | null {
  let n: Node | null = option.parentElement;
  while (n !== null) {
    if (n instanceof HTMLSelectElement) return n.isListBox ? n : null;
    n = n.parentElement;
  }
  return null;
}

/**
 * The textarea a hit falls in, if any: the hit may land on the field's own text node rather than
 * the field, so a press climbs from there to the element that draws the caret.
 */
function textAreaAt(target: Node | null): HTMLTextAreaElement | null {
  let n: Node | null = target;
  while (n !== null) {
    if (n instanceof HTMLTextAreaElement) return n;
    if (n.isElementNode) return null;
    n = n.parentNode;
  }
  return null;
}

export function pointerDown(x: number, y: number, clicks: number = 1, mods: number = 0): void {
  noteInput("pointer");
  noteUserActivation();
  pointer.x = x;
  pointer.y = y;
  pointer.mods = mods;
  // An open select picker takes the press itself: a row under it becomes the highlight, and a
  // press anywhere else dismisses it, so neither reaches the page below.
  if (selectPopupPointerDown(x, y)) return;
  // The press makes pointer 1 active, which is what setPointerCapture() asks for.
  notePointerActive(1, true);
  // An open date picker takes a press inside it; one outside closes it and carries on as a press
  // on the page under it.
  if (datePickerPress(x, y)) return;
  const target = hitAt(x, y);
  // A press in an app-region: drag area moves the window and is never seen by the page, as in a
  // browser's Window Controls Overlay; the drag runs until the button is released.
  if (appRegionAt(target) === P.AR_DRAG) {
    dragWindow();
    return;
  }
  // A press outside an open auto popover closes it, before the press itself is handled.
  lightDismissPopovers(target);
  updateHover(target);
  pointer.pressed = target;
  pointer.down = true;
  setState(chain(target), P.S_ACTIVE, true);
  if (target === null) return;
  // A mouse sends pointerdown first, then mousedown; preventing the pointerdown suppresses the
  // compatibility mouse events, as a browser does.
  const pointerDownEvent = pointerEvent("pointerdown", x, y, 1, clicks, mods);
  dispatch(pointerDownEvent, target);
  if (pointerDownEvent.defaultPrevented) return;
  const down = mouseEvent("mousedown", x, y, clicks, mods);
  dispatch(down, target);
  if (down.defaultPrevented) return;
  // Focus the nearest focusable ancestor, or clear focus.
  let f: Node | null = target;
  while (f !== null && !(f instanceof Element && f.isFocusable)) f = f.parentNode;
  setFocus(f instanceof Element ? f : null);
  // A press on a resizable box's grip starts a size drag, not a caret or a selection.
  const grip = resizeGripAt(target, x, y);
  if (grip !== null) {
    resizeDrag.el = grip;
    resizeDrag.x = x;
    resizeDrag.y = y;
    resizeDrag.w = grip.w;
    resizeDrag.h = grip.h;
    return;
  }
  // A press on a list box's row chooses it, as a browser's list box does, and the change follows.
  const option = optionAt(target);
  if (option !== null) {
    const box = listBoxOf(option);
    if (box !== null && !inDisabledFormControl(box)) {
      const index = box.options.indexOf(option);
      const mode = (mods & MOD_META) !== 0 ? "toggle" : (mods & MOD_SHIFT) !== 0 ? "extend" : "plain";
      if (mode === "plain") selectAnchor = index;
      setFocus(box);
      box.selectRow(index, mode, selectAnchor);
    }
    return;
  }
  // A press in a textarea puts the caret where the pointer is, and a drag that follows takes the
  // selection with it.
  const area = textAreaAt(target);
  if (area !== null) {
    if (!inDisabledFormControl(area)) {
      area.moveCaret(textAreaIndexAt(area, x, y), false);
      caret.visible = true;
      invalidateStyle();
    }
    return;
  }
  if (target instanceof HTMLInputElement) {
    const kind = controlKind(target.type);
    if (kind === CONTROL_RANGE) {
      // A press on the track puts the thumb under the pointer at once; the drag that follows
      // keeps it there.
      if (!inDisabledFormControl(target)) {
        rangeDrag = target;
        rangeStart = target.value;
        setRangeValue(target, rangeValueAt(target, x), false);
      }
      return;
    }
    // A date or time field has segments rather than a caret: a press on its button opens the
    // picker, and a press elsewhere picks the segment under the pointer.
    if (dateKind(target) !== null) {
      if (dateIconContains(target, x, y)) openDatePicker(target);
      else dateSetActive(target, dateSegmentAtPoint(target, x));
      return;
    }
    // Only a field a user types into has a caret to move. `user-select` doesn't enter into it: a
    // browser lets a press take a field's text whatever the field says, as Chrome does.
    if (kind === CONTROL_NONE) {
      target.moveCaret(inputIndexAt(target, x), false);
      caret.visible = true;
    }
    return;
  }
  // A press on something draggable may start a drag once the pointer moves; until then it is a
  // press like any other, so a click on a draggable element still works.
  noteDragPress(target, x, y);
  // Text outside a field: a press starts a selection there, a drag extends it, and the host's
  // click count (the system double-click speed AppKit applies) takes the word or the paragraph.
  if (clicks === 2) selectWordAt(x, y);
  else if (clicks >= 3) selectParagraphAt(x, y);
  else beginSelectionAt(x, y);
}

export function pointerUp(x: number, y: number, clicks: number = 1, mods: number = 0): void {
  pointer.x = x;
  pointer.y = y;
  pointer.mods = mods;
  // The release of a press the date picker took never reaches the page, whose element lies under
  // it; the select picker's release picks the row under it, or ends a dismissal.
  if (datePickerRelease()) {
    pointer.pressed = null;
    pointer.down = false;
    notePointerActive(1, false);
    endSelectionDrag();
    return;
  }
  if (selectPopupPointerUp(x, y)) return;
  const hit = hitAt(x, y);
  // A captured pointer's release goes to the element that holds it, wherever the pointer is.
  const captured = pointerCaptureElement();
  const target = captured !== null ? captured : hit;
  // A drag takes the release: it sends drop and dragend, and a browser sends no click for a
  // release that ends a drag.
  if (dragUp(x, y, hit, mods)) {
    const dragged = pointer.pressed;
    pointer.pressed = null;
    pointer.down = false;
    endSelectionDrag();
    if (dragged !== null) setState(chain(dragged), P.S_ACTIVE, false);
    endDragPress();
    endPointerCapture(1);
    notePointerActive(1, false);
    return;
  }
  endDragPress();
  const pressed = pointer.pressed;
  pointer.pressed = null;
  pointer.down = false;
  endSelectionDrag();
  resizeDrag.el = null;
  if (pressed !== null) setState(chain(pressed), P.S_ACTIVE, false);
  if (target !== null) {
    dispatch(pointerEvent("pointerup", x, y, 0, clicks, mods), target);
    dispatch(mouseEvent("mouseup", x, y, clicks, mods), target);
  }
  // A click fires on the nearest common ancestor of the press and release targets.
  if (pressed !== null && target !== null) {
    const ups = chain(target);
    let common: Node | null = pressed;
    while (common !== null && ups.indexOf(common) < 0) common = common.parentElement;
    // A disabled control takes no click event, as in a browser.
    if (common !== null && !inDisabledFormControl(common) && dispatch(mouseEvent("click", x, y, clicks, mods), common)) runClickDefault(common, true);
  }
  // The capture ends with the release, and the element hears that it lost the pointer.
  endPointerCapture(1);
  notePointerActive(1, false);
  // A range that moved while it was dragged sends its one "change" when the button lifts.
  if (rangeDrag !== null) {
    const dragged = rangeDrag;
    rangeDrag = null;
    const moved = dragged.value !== rangeStart;
    rangeStart = "";
    if (moved) dispatch(trusted(new Event("change", { bubbles: true })), dragged);
  }
}

/**
 * The second button's press (EV_CONTEXT): the element under it hears a cancelable `contextmenu`,
 * which a page answers with a menu of its own (`menu.popup()`). The runtime shows none of its own,
 * so a press nothing listens for does nothing.
 */
export function pointerContext(x: number, y: number, mods: number = 0): void {
  const target = hitAt(x, y);
  if (target === null) return;
  const ev = mouseEvent("contextmenu", x, y, 1, mods, 2, 2);
  dispatch(ev, target);
  // A press nothing cancelled shows the menu the contextmenu attribute nearest it names.
  if (!ev.defaultPrevented) showContextMenu(target, x, y);
}

export function pointerMove(x: number, y: number, mods: number = 0): void {
  pointer.x = x;
  pointer.y = y;
  pointer.mods = mods;
  // The popup is painted over the page, so a pointer over it hovers nothing on the page. Over an
  // open select picker the row under the pointer takes the highlight, and nothing below the panel
  // hears the move.
  if (isDatePickerOpen() && datePickerContains(x, y)) {
    updateHover(null);
    return;
  }
  if (selectPopupPointerMove(x, y)) return;
  const pressed = pointer.pressed;
  const hit = hitAt(x, y);
  // Moving something draggable takes the move: the drag sends its own events, and the press
  // selects no text while it lasts.
  if (pointer.down && dragMove(x, y, hit, mods)) {
    updateHover(hit);
    return;
  }
  // A grip drag sizes the box; a plain drag takes the text selection with it.
  if (resizeDrag.el !== null) dragResize(x, y);
  else if (pointer.down && pressed !== null) extendSelectionTo(x, y);
  // Movement reaches the element under the pointer, and bubbles, so a drag a script tracks on
  // window or on a covering element hears every step of it. A captured pointer keeps reaching the
  // element that holds it instead, which is what a drag that leaves its element relies on.
  const captured = pointerCaptureElement();
  const target = captured !== null ? captured : hit;
  // A crossing over an edge sends its over/out and enter/leave before the move that crossed it,
  // as a browser does.
  updateHover(hit);
  if (target !== null) {
    dispatch(pointerEvent("pointermove", x, y, pointer.down ? 1 : 0, 0, mods), target);
    dispatch(mouseEvent("mousemove", x, y, 0, mods), target);
  }
  if (pointer.down && rangeDrag !== null) {
    setRangeValue(rangeDrag, rangeValueAt(rangeDrag, x), false);
    return;
  }
  const areaDrag = textAreaAt(pressed);
  if (pointer.down && areaDrag !== null && focusState.el === areaDrag) {
    areaDrag.moveCaret(textAreaIndexAt(areaDrag, x, y), true);
    return;
  }
  if (pointer.down && pressed instanceof HTMLInputElement && focusState.el === pressed
    && controlKind(pressed.type) === CONTROL_NONE) {
    pressed.moveCaret(inputIndexAt(pressed, x), true);
    return;
  }
}

/**
 * An accessibility client's press on an element: the click an assistive technology simulates, as
 * a browser runs its default action. The events go to the element itself, at its centre, rather
 * than to whatever the hit test finds there, so a control scrolled out of view or under another
 * box is pressed all the same. The press focuses as a pointer's does, and a select opens its
 * picker, since the press is the user's gesture.
 */
export function pressElement(el: Element): void {
  if (!el.isConnected || inDisabledFormControl(el)) return;
  // A press from an accessibility client is the user's own input, as a pointer press is: it counts
  // as a gesture, so a control it activates may open a window as a clicked one can.
  noteUserActivation();
  noteInput("pointer");
  const r = el.getBoundingClientRect();
  const x = r.x + r.width / 2;
  const y = r.y + r.height / 2;
  const down = pointerEvent("pointerdown", x, y, 1, 1);
  dispatch(down, el);
  if (!down.defaultPrevented) {
    const mouseDown = mouseEvent("mousedown", x, y, 1);
    dispatch(mouseDown, el);
    if (!mouseDown.defaultPrevented) {
      let f: Node | null = el;
      while (f !== null && !(f instanceof Element && f.isFocusable)) f = f.parentNode;
      if (f instanceof Element) setFocus(f);
    }
  }
  dispatch(pointerEvent("pointerup", x, y, 0, 1), el);
  dispatch(mouseEvent("mouseup", x, y, 1), el);
  if (el.isConnected && !inDisabledFormControl(el) && dispatch(mouseEvent("click", x, y, 1), el)) runClickDefault(el, true);
}

/** An accessibility client's request for an element's menu: contextmenu at its centre, as the
 *  second button would send. */
export function contextMenuFor(el: Element): void {
  if (!el.isConnected) return;
  const r = el.getBoundingClientRect();
  const x = r.x + r.width / 2;
  const y = r.y + r.height / 2;
  const ev = mouseEvent("contextmenu", x, y, 1, 0, 2, 2);
  dispatch(ev, el);
  if (!ev.defaultPrevented) showContextMenu(el, x, y);
}
