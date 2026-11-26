// Paint: walks the laid-out tree and records draw commands with the native host.

import * as P from "../shared/props.ts";
import { firstLetterLength } from "../shared/css/first-letter.ts";
import { autoInsetPx } from "../shared/css/anim.ts";
import { Element, HTMLElement, HTMLCanvasElement, HTMLDialogElement, HTMLVideoElement, HTMLInputElement, HTMLOptionElement, HTMLSelectElement, HTMLTextAreaElement, EMPTY_LINE, DOMRect, document, focusState, controlKind, CONTROL_NONE, buttonInputType, isInTopLayer, topLayerElements, rangeStreamSpan, langOf, boxKids, dateKind, dateFieldView, editingHostFor } from "./dom.ts";
import type { Node, Text, ValueRangeGeometry } from "./dom.ts";
import { lineHeightPx, fontKey, isFlexContainer, isGridContainer, lastLineAlign, lineAlign, isRtl, isLanesContainer, usedWritingMode } from "./style.ts";
import { hostBegin, hostCompositorOn, hostDamageBegin, hostDamageCanMerge, hostPresentDamage, hostVerifyDamage, hostClipPushShape, hostFillRect, hostVideoDraw, hostFillLine, hostFillRing, hostFillPoly, hostClipPushPoly, hostFillRoundRect, hostFillRoundRing, hostText, hostTextShadow, hostPresent, hostClipPush, hostClipPushRound, hostClipPop, hostCanvasDraw, hostShadowOuter, hostShadowInset, hostTransformPush, hostTransformPushIndexed, hostStatePop, hostEffectPush, hostEffectPushIndexed, hostEffectPop, hostMaskPop, hostPerspectivePush, hostPerspectivePop, hostLayerPush, hostLayerPop } from "./host.ts";
import { drawImagePath, orientedImage } from "./images.ts";
import { viewport, measure, isOutOfFlow, baselineOffset, fontMetrics, textWidth, letterSpacingPx, wordSpacingPx, FRAG_TEXT, absolutePosition, containingBlock } from "./layout.ts";
import { itemTextSpacing, trailingSeparators } from "./layout/inline.ts";
import { layoutPasses } from "./layout/box.ts";
import { paintControl } from "./controls.ts";
import { paintDatePicker } from "./date-picker.ts";
import { borderBottom, borderLeft, borderPx, borderRight, borderTop, clipMargin, display, clipsX, clipsY, flattenContents, isBfcRoot, isFloat, isReplaced, isSvgElement, len, objectSize, propagatesBodyOverflow, viewportOverflowX, viewportOverflowY, viewportScrollsX, viewportScrollsY } from "./layout/box-model.ts";
import { paintSvg } from "./svg.ts";
import { contentRect, smoothImage } from "./image-fit.ts";
import { isEmptyCell, isVoidTablePart } from "./layout/table.ts";
import { paintBackgroundImages, paintCanvasImages, hasBackgroundImage, backgroundClipBox, backgroundClipRadii, boxRect, scrollsWithContents } from "./background.ts";
import { hasBorderImage, paintBorderImage } from "./border-image.ts";
import { borderRadii, insetRadii, rounded } from "./radius.ts";
import type { Radii } from "./radius.ts";
import { clipRect, hasClipPath, pushClipPath, pushClipRect } from "./clip.ts";
import { hasMask, pushMask } from "./mask.ts";
import { hostFocusRingColor } from "./host.ts";
import { systemColorValue } from "./system-colors.ts";
import { registeredHighlights } from "./highlights.ts";
import { targetTextSpan } from "./target-text.ts";
import { beginSelectionPaint, endSelectionPaint, fragmentSelection, fragmentStream, lineSelection, lineStream } from "./selection.ts";
import { boxShadows, textShadows } from "./shadows.ts";
import { hasTransform, isBackFacing, pageMatrix, pageQuad, toLocalPoint } from "./transform.ts";
import { compositableBits } from "./animation.ts";
import { LAYER_TRANSFORM, willChangeBits } from "./layers.ts";
import { setPointHitsHook } from "./point-hook.ts";
import { backdropReuses, damage, damageSerialsText, damageVerify, lastInkHitsDamage,noteScrollThumb, onDamagePath, paintBoundsOf, recordFullInk } from "./paint-damage.ts";
import { setPaintBoundsHook } from "./invalidation.ts";
import { flushLayoutHook } from "./layout-flush-hook.ts";
import { elementFilter, elementBackdropFilter } from "./filters.ts";
import type { FilterOp } from "./filters.ts";
import { paintSelectPopup } from "./select-popup.ts";
import { willChangeRows } from "../shared/css/willchange.ts";
import { BAR_DRAWN, BAR_FADED, BAR_NONE, clearPending, clearRecorded, noteOpacity, noteOutsideScrollTransform, noteScroll, noteScrollBar, noteScrollBarState, noteTransform, scrollContentRecorded } from "./compositor.ts";
import { frameTimes } from "./frame-times.ts";

setPaintBoundsHook(paintBoundsOf);

export const caret = { visible: true };

/** Whether the host's display list holds only damaged regions: a composite frame can't edit a
 *  partial list, since the commands outside the damage were never recorded. */
export const paintState = { partial: false };

/** The colour a field's caret is drawn in: its caret-color when that names one, else its text's. */
function caretColor(el: Node): number {
  const c = el.sv[P.P_CARET_COLOR];
  // -1 is `auto` and -2 an explicit `currentColor`: both follow the field's text colour.
  return c < 0 ? el.sv[P.P_COLOR] : c;
}

/**
 * Paints a field's caret at `x`, the top of its line box. Its shape is the element's caret-shape:
 * the bar (what `auto` draws), a block over the character the caret sits on, or an underscore
 * below the line. A block is a filled rect in the caret's colour: the host doesn't blend a rect
 * with what it covers, so it doesn't invert the glyph the way Chrome's does.
 */
function paintCaret(el: Node, x: number, ty: number, lh: number, charW: number, opacity: number): void {
  const color = withOpacity(caretColor(el), opacity);
  const shape = el.sv[P.P_CARET_SHAPE];
  if (shape === P.CSP_BLOCK) {
    hostFillRect(Math.round(x), ty, charW > 0 ? Math.round(charW) : Math.max(4, Math.round(lh / 2)), lh, 0, color);
  } else if (shape === P.CSP_UNDERSCORE) {
    hostFillRect(Math.round(x), ty + lh - 2, charW > 0 ? Math.round(charW) : Math.max(4, Math.round(lh / 2)), 2, 0, color);
  } else {
    hostFillRect(Math.round(x), ty + 1, 1.5, lh - 2, 0, color);
  }
}

interface EditableCaretBox {
  left: number;
  top: number;
  height: number;
}

function charCaretRect(node: Text, from: number, to: number): DOMRect | null {
  const range = document.createRange();
  range.setStart(node, from);
  range.setEnd(node, to);
  const rects = range.getClientRects();
  if (rects.length > 0) return rects[0];
  const one = range.getBoundingClientRect();
  return one.width > 0 || one.height > 0 ? one : null;
}

function firstTextNode(node: Node): Text | null {
  if (node.nodeType === 3) return node as Text;
  if (node.nodeType !== 1) return null;
  const kids = node.childNodes;
  for (let i = 0; i < kids.length; i++) {
    const t = firstTextNode(kids[i]);
    if (t !== null) return t;
  }
  return null;
}

function lastTextNode(node: Node): Text | null {
  if (node.nodeType === 3) return node as Text;
  if (node.nodeType !== 1) return null;
  const kids = node.childNodes;
  for (let i = kids.length - 1; i >= 0; i--) {
    const t = lastTextNode(kids[i]);
    if (t !== null) return t;
  }
  return null;
}

/** Where a collapsed selection inside an editing host draws its caret, in viewport coordinates. */
function editableCaretBox(host: Element, node: Node, offset: number): EditableCaretBox | null {
  if (node.nodeType === 3) {
    const text = node as Text;
    const len = text.data.length;
    if (len > 0 && offset < len) {
      const r = charCaretRect(text, offset, offset + 1);
      if (r !== null) return { left: r.left, top: r.top, height: Math.max(8, r.height) };
    }
    if (len > 0 && offset > 0) {
      const r = charCaretRect(text, offset - 1, offset);
      if (r !== null) return { left: r.right, top: r.top, height: Math.max(8, r.height) };
    }
  }
  if (node.nodeType === 1) {
    const el = node as Element;
    const kids = el.childNodes;
    const index = Math.max(0, Math.min(offset, kids.length));
    if (index < kids.length) {
      const first = firstTextNode(kids[index]);
      if (first !== null) {
        const r = charCaretRect(first, 0, Math.min(1, first.data.length));
        if (r !== null) return { left: r.left, top: r.top, height: Math.max(8, r.height) };
      }
    }
    if (index > 0) {
      const last = lastTextNode(kids[index - 1]);
      if (last !== null) {
        const len = last.data.length;
        const r = charCaretRect(last, Math.max(0, len - 1), len);
        if (r !== null) return { left: r.right, top: r.top, height: Math.max(8, r.height) };
      }
    }
  }
  const r = host.getBoundingClientRect();
  if (r.width === 0 && r.height === 0) return null;
  return { left: r.left + 1, top: r.top + 1, height: Math.max(8, lineHeightPx(host)) };
}

function caretHitsDamage(left: number, top: number, height: number): boolean {
  if (!damage.limited) return true;
  for (const r of damage.rects) {
    if (left + 2 > r[0] && left < r[0] + r[2] && top + height > r[1] && top < r[1] + r[3]) return true;
  }
  return false;
}

/** A focused contenteditable host draws its caret at the collapsed selection, as a field does. */
function paintEditableCaret(): void {
  if (!caret.visible) return;
  const sel = document.getSelection();
  if (sel === null || sel.focusNode === null || sel.focusNode === undefined ||
    sel.anchorNode === null || sel.anchorNode === undefined) return;
  if (sel.anchorNode !== sel.focusNode || sel.anchorOffset !== sel.focusOffset) return;
  const host = editingHostFor(sel.focusNode);
  if (host === null) return;
  const focused = focusState.el;
  if (focused === null || focused === undefined || (focused !== host && !host.contains(focused))) return;
  const box = editableCaretBox(host, sel.focusNode, sel.focusOffset);
  if (box === null || !caretHitsDamage(box.left, box.top, box.height)) return;
  paintCaret(host, box.left, box.top, box.height, 2, 1);
}

/** Chrome on macOS draws :focus-visible as the system's keyboard focus ring: a rounded halo in the
 *  system's focus colour, three pixels wide, just outside the border box. */
let focusRingColor = -1;

function systemFocusRingColor(): number {
  if (focusRingColor < 0) focusRingColor = hostFocusRingColor();
  return focusRingColor;
}

/** Whether the element is drawn in the dark scheme, which the style pass marks on each element. */
function schemeDark(el: Node | null): boolean {
  let n = el;
  while (n !== null && !(n instanceof Element)) n = n.parentNode;
  return n !== null && (n.state & P.S_SCHEME_DARK) !== 0;
}

/** The colour the system paints behind selected text, in the element's scheme. */
function systemSelectionColor(el: Node | null): number {
  const v = systemColorValue("highlight", schemeDark(el));
  return v === null ? 0x80bcfe99 : v;
}

/** The colour selected text paints in, as the system names it for the element's scheme. */
function systemSelectionTextColor(el: Node | null): number {
  const v = systemColorValue("highlighttext", schemeDark(el));
  return v === null ? 0x000000ff : v;
}

/** One highlight cover for this paint: a character span of the document's stream and its name. */
interface HighlightCover {
  name: string;
  a: number;
  b: number;
  priority: number;
}

/** The pale yellow a browser paints a text fragment in when ::target-text gives no colour. */
const TARGET_TEXT_BACKGROUND = 0xffff0066;

/** The covers the registry holds, lowest priority first, read once for each paint pass. */
let highlightCovers: HighlightCover[] = [];

/** Reads the registry's ranges into character spans, lowest priority first. */
function readHighlightCovers(): void {
  highlightCovers = [];
  const entries = registeredHighlights();
  for (let i = 0; i < entries.length; i++) {
    const name = entries[i][0];
    const hl = entries[i][1];
    for (let k = 0; k < hl.ranges.length; k++) {
      const span = rangeStreamSpan(hl.ranges[k]);
      if (span === null) continue;
      highlightCovers.push({ name, a: span[0], b: span[1], priority: hl.priority });
    }
  }
  highlightCovers.sort((x, y) => x.priority - y.priority);
  // ::target-text paints over the custom highlights, and under the selection.
  const target = targetTextSpan();
  if (target !== null) highlightCovers.push({ name: "", a: target[0], b: target[1], priority: 0 });
}

/**
 * The ::highlight() carrier that gives `el`'s text a named highlight's colours, or null: its own,
 * or the nearest ancestor's, since a highlight's style inherits down the tree.
 */
function highlightCarrier(el: Node, name: string): Element | null {
  let node: Node | null = el;
  while (node !== null) {
    if (node instanceof Element) {
      // A cover with no name is the target text, whose carrier is its own kind.
      if (name === "" && node.targetTextPseudo !== null) return node.targetTextPseudo;
      const list = node.highlightPseudos;
      for (let i = 0; i < list.length; i++) if (list[i].pseudoName === name) return list[i];
    }
    node = node.parentNode;
  }
  return null;
}

/** Paints the label a select shows: the text of the option it has chosen, in its own field. */
function paintSelectLabel(el: HTMLSelectElement, x: number, y: number, opacity: number): void {
  const label = el.chosenLabel;
  if (label === "" || el.sv[P.P_FONT_SIZE] <= 0) return;
  const lh = lineHeightPx(el);
  const cx = x + el.contentX;
  const cw = el.contentW;
  const ty = y + el.contentY + (el.contentH - lh) / 2;
  hostClipPush(el.serial, P.PK_CLIP_RECT, cx, y + el.contentY, cw, el.contentH, 0);
  hostText(label, cx, ty, lh, el.sv[P.P_FONT_SIZE], fontKey(el),
    withOpacity(el.sv[P.P_COLOR], opacity), letterSpacingPx(el),
    wordSpacingPx(el), 0, 0);
  hostClipPop();
}

/** Paints a button input's label in its box, placed by the box's text alignment and centred vertically. */
function paintInputLabel(el: HTMLInputElement, x: number, y: number, opacity: number): void {
  const text = el.displayText;
  if (text === "" || el.sv[P.P_FONT_SIZE] <= 0) return;
  const lh = lineHeightPx(el);
  const cx = x + el.contentX;
  const cw = el.contentW;
  const tw = textWidth(el, text);
  const align = lineAlign(el);
  const tx = align === P.T_CENTER ? cx + Math.max(0, (cw - tw) / 2)
    : align === P.T_RIGHT ? cx + Math.max(0, cw - tw) : cx;
  const ty = y + el.contentY + (el.contentH - lh) / 2;
  hostClipPush(el.serial, P.PK_CLIP_RECT, cx, y + el.contentY, cw, el.contentH, 0);
  hostText(text, tx, ty, lh, el.sv[P.P_FONT_SIZE], fontKey(el),
    withOpacity(el.sv[P.P_COLOR], opacity), letterSpacingPx(el),
    wordSpacingPx(el), 0, 0);
  hostClipPop();
}

/** The accent a control's lit parts take, as Chrome's default accent is. */
const DATE_ACCENT = 0x0075ffff;
/** How far the calendar or clock button sits from the field's right edge. */
const DATE_ICON_INSET = 4;

/**
 * The box of a date field's picker button: a calendar for the date kinds and a clock for a time,
 * drawn inside the content box at its right end. Returns [x, y, size].
 */
function dateIconBox(el: HTMLInputElement, x: number, y: number): number[] {
  const size = Math.max(8, Math.min(16, el.contentH - 4, el.contentW));
  return [
    x + el.contentX + el.contentW - size - DATE_ICON_INSET,
    y + el.contentY + (el.contentH - size) / 2,
    size,
  ];
}

/** Paints a date field's button: a small calendar, or a clock for a time field. */
function paintDateIcon(el: HTMLInputElement, x: number, y: number, opacity: number): void {
  const box = dateIconBox(el, x, y);
  const s = box[2];
  const left = box[0];
  const top = box[1];
  const color = withOpacity(el.sv[P.P_COLOR], opacity * (focusState.el === el ? 0.9 : 0.65));
  if (dateKind(el) === "time") {
    const r = s / 2;
    hostFillRing(left, top, s, s, r, Math.max(1, s / 14), color);
    hostFillRect(left + r - 0.5, top + s * 0.22, 1, s * 0.3, 0, color);
    hostFillRect(left + r - 0.5, top + r - 0.5, s * 0.28, 1, 0, color);
    return;
  }
  const line = Math.max(1, s / 14);
  const bodyTop = top + s * 0.2;
  const bodyH = s * 0.72;
  // Two binding rings above the calendar's body, then the body's outline and a row of days.
  hostFillRect(left + s * 0.24, top, line, s * 0.24, 0, color);
  hostFillRect(left + s * 0.68, top, line, s * 0.24, 0, color);
  hostFillRect(left, bodyTop, s, line, 0, color);
  hostFillRect(left, bodyTop, line, bodyH, 0, color);
  hostFillRect(left + s - line, bodyTop, line, bodyH, 0, color);
  hostFillRect(left, top + s - line, s, line, 0, color);
  hostFillRect(left + s * 0.2, bodyTop + s * 0.28, s - s * 0.4, line, 0, color);
}

/** Paints a date or time field as its segments, the edited one lit, with its picker button. */
function paintDateInput(el: HTMLInputElement, x: number, y: number, opacity: number): void {
  const view = dateFieldView(el);
  if (view === null) return;
  const size = el.sv[P.P_FONT_SIZE];
  if (size <= 0 || view.segments.length === 0) {
    if (size > 0) paintDateIcon(el, x, y, opacity);
    return;
  }
  const lh = lineHeightPx(el);
  const weight = fontKey(el);
  const cx = x + el.contentX;
  const cw = el.contentW;
  const ty = y + el.contentY + (el.contentH - lh) / 2;
  const letter = letterSpacingPx(el);
  const word = wordSpacingPx(el);
  const focused = focusState.el === el;
  const accent = el.sv[P.P_ACCENT_COLOR] < 0 ? DATE_ACCENT : el.sv[P.P_ACCENT_COLOR];
  const normal = withOpacity(el.sv[P.P_COLOR], opacity);
  const faded = withOpacity(el.sv[P.P_COLOR], opacity * 0.55);
  const icon = dateIconBox(el, x, y);
  const avail = Math.max(0, icon[0] - cx - 6);

  hostClipPush(el.serial, P.PK_CLIP_RECT, cx - 1, y + el.contentY, avail + 2, el.contentH, 0);
  let px = cx;
  for (const seg of view.segments) {
    hostText(seg.prefix, px, ty, lh, size, weight, normal, letter, word, 0, 0);
    px += textWidth(el, seg.prefix);
    const tw = textWidth(el, seg.text);
    if (seg.active) {
      // The edited segment sits on an accent block with its text knocked out, as Chrome draws it.
      hostFillRect(px - 1, ty, tw + 2, lh, 2, withOpacity(accent, opacity));
      hostText(seg.text, px, ty, lh, size, weight, 0xffffffff, letter, word, 0, 0);
    } else {
      hostText(seg.text, px, ty, lh, size, weight, seg.placeholder ? faded : normal, letter, word, 0, 0);
    }
    px += tw;
  }
  hostClipPop();
  paintDateIcon(el, x, y, opacity);
}

/** The push of a date field's segments as viewport x ranges, so a press can pick one. */
export function dateSegmentBoxes(el: HTMLInputElement): number[][] {
  flushLayoutHook();
  const view = dateFieldView(el);
  const out: number[][] = [];
  if (view === null) return out;
  const p = absolutePosition(el);
  let px = p[0] + el.contentX - el.scrollX;
  for (const seg of view.segments) {
    px += textWidth(el, seg.prefix);
    const w = textWidth(el, seg.text);
    out.push([px, px + w]);
    px += w;
  }
  return out;
}

/** The segment a viewport x falls in, or the last one when it falls past them all. */
export function dateSegmentAtPoint(el: HTMLInputElement, px: number): number {
  const boxes = dateSegmentBoxes(el);
  if (boxes.length === 0) return -1;
  for (let i = 0; i < boxes.length; i++) if (px < boxes[i][1]) return i;
  return boxes.length - 1;
}

/** Whether a viewport point falls on a date field's picker button. */
export function dateIconContains(el: HTMLInputElement, px: number, py: number): boolean {
  flushLayoutHook();
  const p = absolutePosition(el);
  const box = dateIconBox(el, p[0], p[1]);
  const size = box[2];
  return px >= box[0] && px <= box[0] + size && py >= box[1] && py <= box[1] + size;
}

function paintInput(el: HTMLInputElement, x: number, y: number, opacity: number): void {
  // A button input shows a label, not text to edit: it never scrolls and has no caret.
  if (buttonInputType(el.type)) {
    paintInputLabel(el, x, y, opacity);
    return;
  }
  // A date or time field draws a segment per value part, and a button that opens its picker.
  if (dateKind(el) !== null) {
    paintDateInput(el, x, y, opacity);
    return;
  }
  const lh = lineHeightPx(el);
  const size = el.sv[P.P_FONT_SIZE];
  const weight = fontKey(el);
  const cx = x + el.contentX;
  const cw = el.contentW;
  const ty = y + el.contentY + (el.contentH - lh) / 2; // text is vertically centered, as in browsers
  const focused = focusState.el === el;
  const text = el.displayText;
  const textW = textWidth(el, text);
  const letter = letterSpacingPx(el);
  const word = wordSpacingPx(el);

  // Keep the caret in view.
  const caretX = textWidth(el, text.slice(0, el.caretEnd));
  if (caretX - el.scrollX > cw - 1) el.scrollX = caretX - cw + 1;
  if (caretX - el.scrollX < 0) el.scrollX = caretX;
  el.scrollX = Math.max(0, Math.min(el.scrollX, Math.max(0, textW - cw + 1)));
  const ox = cx - el.scrollX;

  hostClipPush(el.serial, P.PK_CLIP_RECT, cx - 1, y + el.contentY, cw + 2, el.contentH, 0);
  // A zero font size draws no glyph; see the fragment loop below for why.
  const drawText = size > 0;
  if (text === "") {
    if (drawText && el.placeholder !== "") {
      // ::placeholder carries the style the text is drawn with. Without a colour of its own the
      // placeholder is the field's colour at half opacity, which is what it has always looked
      // like here; a declared colour is drawn at the placeholder's own opacity.
      const ph = el.placeholderPseudo;
      const styled = ph !== null && ph.declaredProps !== null && ph.declaredProps[P.P_COLOR] !== 0;
      const phColor = styled
        ? withOpacity(ph!.sv[P.P_COLOR], opacity * ph!.sv[P.P_OPACITY])
        : withOpacity(el.sv[P.P_COLOR], opacity * 0.5);
      const phSize = styled ? ph!.sv[P.P_FONT_SIZE] : size;
      hostText(el.placeholder, cx, ty, lh, phSize, styled ? fontKey(ph!) : weight, phColor, letter, word, 0, 0);
    }
  } else {
    if (focused && el.selectionStart !== el.selectionEnd) {
      const x0 = textWidth(el, text.slice(0, el.selectionStart));
      const x1 = textWidth(el, text.slice(0, el.selectionEnd));
      hostFillRect(ox + x0, ty, x1 - x0, lh, 0, withOpacity(systemSelectionColor(el), opacity));
    }
    if (drawText) hostText(text, ox, ty, lh, size, weight, withOpacity(el.sv[P.P_COLOR], opacity), letter, word, 0, 0);
  }
  // An input method's marked text is underlined where it sits, as a browser draws it.
  if (focused && el.composeStart >= 0 && el.composeEnd > el.composeStart) {
    const x0 = textWidth(el, text.slice(0, Math.min(el.composeStart, text.length)));
    const x1 = textWidth(el, text.slice(0, Math.min(el.composeEnd, text.length)));
    hostFillRect(ox + x0, ty + lh - 1, x1 - x0, 1, 0, withOpacity(el.sv[P.P_COLOR], opacity));
  }
  if (focused && caret.visible && el.selectionStart === el.selectionEnd) {
    paintCaret(el, ox + caretX, ty, lh, textWidth(el, text.slice(el.caretEnd, el.caretEnd + 1)), opacity);
  }
  hostClipPop();
}

/** Where each wrapped line of a textarea starts in its value, so a caret index maps to a line. */
export function textAreaLineStarts(el: HTMLTextAreaElement): number[] {
  // The lines are what layout produced, so a value set a moment ago counts before they are read.
  flushLayoutHook();
  const out: number[] = [];
  const v = el.value;
  const lines = el.lines;
  let pos = 0;
  for (let i = 0; i < lines.length; i++) {
    const text = lines[i];
    let at = text === "" ? pos : v.indexOf(text, pos);
    if (at < 0) at = pos;
    out.push(at);
    pos = at + text.length;
    // A forced break consumed the newline the line ended at.
    if (v[pos] === "\n") pos++;
  }
  return out;
}

/**
 * The caret index a viewport point gives a textarea: the line under the point, then the character
 * boundary nearest the pointer on it.
 */
export function textAreaIndexAt(el: HTMLTextAreaElement, px: number, py: number): number {
  const lines = el.lines;
  if (lines.length === 0) return 0;
  const p = absolutePosition(el);
  const lh = lineHeightPx(el);
  const top = p[1] + el.contentY - el.scrollY;
  const line = Math.max(0, Math.min(lines.length - 1, Math.floor((py - top) / lh)));
  const text = lines[line];
  const left = p[0] + el.contentX - el.scrollX;
  let best = 0;
  let bestDist = Infinity;
  for (let i = 0; i <= text.length; i++) {
    const d = Math.abs(left + textWidth(el, text.slice(0, i)) - px);
    if (d < bestDist) {
      bestDist = d;
      best = i;
    }
  }
  return textAreaLineStarts(el)[line] + best;
}

/** The selection a focused textarea draws on one of its lines, as [x0, x1] within the line. */
function textAreaSelection(el: HTMLTextAreaElement, line: string, start: number, tx: number): number[] {
  const s = Math.min(el.selectionStart, el.selectionEnd);
  const e = Math.max(el.selectionStart, el.selectionEnd);
  const lineEnd = start + line.length;
  if (e <= s || s > lineEnd || e < start) return [];
  const from = Math.max(0, s - start);
  const to = Math.min(line.length, e - start);
  return [tx + textWidth(el, line.slice(0, from)), tx + textWidth(el, line.slice(0, to))];
}

/** Where a focused textarea's caret is drawn on one of its lines, or NaN when it is elsewhere. */
function textAreaCaretX(el: HTMLTextAreaElement, line: string, start: number, last: boolean, tx: number): number {
  if (el.selectionStart !== el.selectionEnd || !caret.visible) return NaN;
  const at = el.caretEnd;
  const lineEnd = start + line.length;
  if (at < start || at > lineEnd) return NaN;
  if (at === lineEnd && !last && at !== start) return NaN;
  return tx + textWidth(el, line.slice(0, Math.max(0, Math.min(at - start, line.length))));
}

/**
 * The boxes a stretch of a field's value is drawn in, one per line, and the box around them. A
 * collapsed range has no rects but reports a caret box, as a browser's does.
 */
export function valueRangeGeometry(el: HTMLElement, start: number, end: number): ValueRangeGeometry {
  const noRects: DOMRect[] = [];
  const none: ValueRangeGeometry = { rects: noRects, bound: new DOMRect(0, 0, 0, 0) };
  if (!(el instanceof HTMLInputElement) && !(el instanceof HTMLTextAreaElement)) return none;
  // The boxes come from layout, so read it as it stands after any value set a moment ago. An
  // element with no box at all (display: none itself or on an ancestor, or removed) has none.
  flushLayoutHook();
  if (!el.isConnected) return none;
  for (let n: Element | null = el; n !== null; n = n.parentElement) {
    if (n.sv[P.P_DISPLAY] === P.D_NONE) return none;
  }
  const p = absolutePosition(el);
  const lh = lineHeightPx(el);
  const left = p[0] + el.contentX - el.scrollX;

  if (el instanceof HTMLInputElement) {
    const text = el.displayText;
    const top = p[1] + el.contentY + (el.contentH - lh) / 2; // centered, as paintInput draws it
    const s = Math.max(0, Math.min(start, text.length));
    const e = Math.max(s, Math.min(end, text.length));
    if (s === e) return { rects: noRects, bound: new DOMRect(left + textWidth(el, text.slice(0, s)), top, 0, lh) };
    const x0 = left + textWidth(el, text.slice(0, s));
    const x1 = left + textWidth(el, text.slice(0, e));
    const rect = new DOMRect(Math.min(x0, x1), top, Math.abs(x1 - x0), lh);
    return { rects: [rect], bound: rect };
  }

  let lines = el.lines;
  let starts = textAreaLineStarts(el);
  // A field the layout has not wrapped yet still has its value's lines: one per hard break.
  if (lines.length === 0) {
    lines = el.value.split("\n");
    starts = [];
    let at = 0;
    for (let i = 0; i < lines.length; i++) {
      starts.push(at);
      at += lines[i].length + 1;
    }
  }
  const top = p[1] + el.contentY - el.scrollY;
  const rects: DOMRect[] = [];
  let lo = Infinity;
  let hi = -Infinity;
  let firstTop = top;
  let lastBottom = top;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const lineStart = starts[i];
    const lineEnd = lineStart + line.length;
    const y = top + i * lh;
    if (start === end) {
      // The caret sits on the line the offset falls in; at a wrapped boundary it is the start of
      // the line below, which the loop reaches next.
      if (start < lineStart || start > lineEnd) continue;
      const x = left + textWidth(el, line.slice(0, Math.max(0, Math.min(start - lineStart, line.length))));
      return { rects: noRects, bound: new DOMRect(x, y, 0, lh) };
    }
    if (end <= lineStart || start >= lineEnd) continue;
    const from = Math.max(0, start - lineStart);
    const to = Math.min(line.length, end - lineStart);
    if (to < from) continue;
    const x0 = left + textWidth(el, line.slice(0, from));
    const x1 = left + textWidth(el, line.slice(0, to));
    rects.push(new DOMRect(Math.min(x0, x1), y, Math.abs(x1 - x0), lh));
    lo = Math.min(lo, Math.min(x0, x1));
    hi = Math.max(hi, Math.max(x0, x1));
    if (rects.length === 1) firstTop = y;
    lastBottom = y + lh;
  }
  if (rects.length === 0) return none;
  return { rects, bound: new DOMRect(lo, firstTop, hi - lo, lastBottom - firstTop) };
}

function withOpacity(color: number, opacity: number): number {
  if (opacity >= 1) return color;
  const a = Math.round((color % 256) * opacity);
  return color - (color % 256) + a;
}

function alpha(color: number): number {
  return color % 256;
}

/** `top` painted over `bottom`, both opaque or not: the colour a browser shows on a page. */
function overColor(top: number, bottom: number): number {
  const a = alpha(top) / 255;
  if (a >= 1) return top;
  const ch = (shift: number): number =>
    Math.round(((top >>> shift) & 255) * a + ((bottom >>> shift) & 255) * (1 - a));
  return ((ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | 255) >>> 0;
}

/**
 * The text-emphasis mark an element's text draws, as the host takes it: the style in the low byte
 * and 1 in the next when the mark goes under the text, and 0 when there is no mark.
 */
function emphasisSpec(el: Node): number {
  const style = el.sv[P.P_TEXT_EMPHASIS_STYLE];
  if (style === P.TEXTE_NONE) return 0;
  const pos = el.sv[P.P_TEXT_EMPHASIS_POSITION];
  return style | ((pos === P.TEXTE_POS_UNDER_RIGHT || pos === P.TEXTE_POS_UNDER_LEFT ? 1 : 0) << 8);
}

/** The colour an element's emphasis marks are drawn in: its own, or the text's for currentColor. */
function emphasisColor(el: Node, opacity: number): number {
  const c = el.sv[P.P_TEXT_EMPHASIS_COLOR];
  return withOpacity(c < 0 ? el.sv[P.P_COLOR] : c, opacity);
}

function borderColorAt(e: Node, p: number): number {
  // A side the collapsed border model resolved carries its own color (P_BORDER_*_COLOR ids are in
  // top, right, bottom, left order, so the offset is the side).
  if (e.bc.length > 0) return e.bc[p - P.P_BORDER_TOP_COLOR];
  const c = e.sv[p];
  return c < 0 ? e.sv[P.P_COLOR] : c;
}

function hasBorder(e: Node): boolean {
  return borderTop(e) > 0 || borderRight(e) > 0 || borderBottom(e) > 0 || borderLeft(e) > 0;
}

/** The width when all four sides share one width, color and style, else -1 (drawn side by side). */
function uniformBorder(e: Node): number {
  const t = borderPx(borderTop(e));
  if (borderPx(borderRight(e)) !== t || borderPx(borderBottom(e)) !== t || borderPx(borderLeft(e)) !== t) return -1;
  const c = borderColorAt(e, P.P_BORDER_TOP_COLOR);
  if (borderColorAt(e, P.P_BORDER_RIGHT_COLOR) !== c) return -1;
  if (borderColorAt(e, P.P_BORDER_BOTTOM_COLOR) !== c) return -1;
  if (borderColorAt(e, P.P_BORDER_LEFT_COLOR) !== c) return -1;
  const st = e.sv[P.P_BORDER_TOP_STYLE];
  if (e.sv[P.P_BORDER_RIGHT_STYLE] !== st || e.sv[P.P_BORDER_BOTTOM_STYLE] !== st ||
    e.sv[P.P_BORDER_LEFT_STYLE] !== st) return -1;
  return t;
}

/** A color's channels moved toward white (factor > 0) or toward black (factor < 0). */
function shade(color: number, factor: number): number {
  const a = color & 255;
  const mix = (c: number) => Math.round(factor > 0 ? c + (255 - c) * factor : c * (1 + factor));
  return (((mix((color >>> 24) & 255) << 24) | (mix((color >>> 16) & 255) << 16) |
    (mix((color >>> 8) & 255) << 8) | a) >>> 0);
}

/** Fills a rounded rect, falling back to the square fill (which the host snaps) when it isn't rounded. */
function fillRoundRect(x: number, y: number, w: number, h: number, r: Radii, color: number): void {
  if (!rounded(r)) {
    hostFillRect(x, y, w, h, 0, color);
    return;
  }
  hostFillRoundRect(x, y, w, h, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], color);
}

/**
 * Fills the band between a rounded rect and the same rect inset by `t`. A square ring is one
 * path — the outer rect with the inner one cut out of it — whose vertices the host snaps to the
 * pixel grid, the grid the sides' mitered quads sit on, so a whole ring's edges land exactly
 * where those quads' edges would.
 */
function fillRoundRing(x: number, y: number, w: number, h: number, r: Radii, t: number, color: number): void {
  if (!rounded(r)) {
    const iw = w - 2 * t;
    const ih = h - 2 * t;
    if (!(iw > 0 && ih > 0)) {
      hostFillRect(x, y, w, h, 0, color);
      return;
    }
    const ix = x + t, iy = y + t;
    // The inner rect runs the other way round, so the non-zero fill leaves it as a hole.
    hostFillPoly(polyText([
      [x, y, x + w, y, x + w, y + h, x, y + h],
      [ix, iy + ih, ix + iw, iy + ih, ix + iw, iy, ix, iy],
    ]), color);
    return;
  }
  hostFillRoundRing(x, y, w, h, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], t, color);
}

/**
 * The element's box shadows of one kind. The list's first shadow is painted on top, so they go
 * down in reverse: an outer shadow before the background, an inset one after it.
 */
function paintShadows(el: Node, inset: boolean, x: number, y: number, w: number, h: number,
  r: Radii, padX: number, padY: number, padW: number, padH: number, padR: Radii, opacity: number): void {
  const list = boxShadows(el);
  for (let i = list.length - 1; i >= 0; i--) {
    const sh = list[i];
    if (sh.inset !== inset) continue;
    const color = withOpacity(sh.color < 0 ? el.sv[P.P_COLOR] : sh.color, opacity);
    if (alpha(color) === 0) continue;
    if (inset) {
      hostShadowInset(padX, padY, padW, padH, padR[0], padR[1], padR[2], padR[3], padR[4], padR[5], padR[6], padR[7],
        sh.dx, sh.dy, sh.blur, sh.spread, color);
    } else {
      hostShadowOuter(x, y, w, h, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7],
        sh.dx, sh.dy, sh.blur, sh.spread, color);
    }
  }
}

function clipRound(serial: number, x: number, y: number, w: number, h: number, r: Radii): void {
  if (!rounded(r)) {
    hostClipPush(serial, P.PK_CLIP_RECT, x, y, w, h, 0);
    return;
  }
  hostClipPushRound(serial, P.PK_CLIP_RECT, x, y, w, h, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]);
}

/**
 * The radii of a rounded box grown by a margin on each axis, the way an outer shadow's spread
 * grows its corners: each corner's radius grows by the same margin in the same direction.
 */
function grownRadii(r: Radii, dx: number, dy: number): Radii {
  return [
    Math.max(0, r[0] + dx), Math.max(0, r[1] + dy), Math.max(0, r[2] + dx), Math.max(0, r[3] + dy),
    Math.max(0, r[4] + dx), Math.max(0, r[5] + dy), Math.max(0, r[6] + dx), Math.max(0, r[7] + dy),
  ];
}

/**
 * The box content is clipped to: the visual box overflow-clip-margin names (the padding box
 * unless one is named), in page coordinates and before the clip margin grows it. The insets that
 * led to it from the border box come along, for the radii of the rounded clip edge. The box only
 * counts when an axis clips with `overflow: clip` — a scroller's box clips at its padding box
 * whatever the value says. A replaced element's image lives in its content box, so its default
 * clip is there.
 */
function overflowClipBox(el: Node, x: number, y: number): number[] {
  const bl = borderPx(borderLeft(el));
  const bt = borderPx(borderTop(el));
  // A table's captions sit inside its element box but outside its border box, and they are not
  // clipped by its overflow: the clip is the table's own box, without the caption space.
  const by = y + el.boxTop;
  const bh = Math.max(0, el.h - el.boxTop - el.boxBottom);
  const clipAxis = el.sv[P.P_OVERFLOW_X] === P.OV_CLIP || el.sv[P.P_OVERFLOW_Y] === P.OV_CLIP;
  const named = clipAxis ? clipMargin(el)[0] : P.OCM_PADDING_BOX;
  if (named === P.OCM_BORDER_BOX) return [x, by, el.w, bh, 0, 0, 0, 0];
  if (named === P.OCM_CONTENT_BOX || isReplaced(el)) {
    const insetL = Math.max(0, el.contentX);
    const insetT = Math.max(0, el.contentY);
    const insetR = Math.max(0, el.w - el.contentX - el.contentW);
    const insetB = Math.max(0, bh - el.contentY - el.contentH);
    return [x + el.contentX, by + el.contentY, el.contentW, el.contentH, insetL, insetT, insetR, insetB];
  }
  const br = borderPx(borderRight(el));
  const bb = borderPx(borderBottom(el));
  return [x + bl, by + bt, el.w - bl - br, bh - bt - bb, bl, bt, br, bb];
}

/**
 * A dashed or dotted side: dashes three widths long with one width between them, or round dots
 * one width across with one width between them, laid along the side from its start corner.
 */
function paintDashes(x: number, y: number, w: number, h: number, t: number, vertical: boolean, round: boolean, color: number): void {
  const len = vertical ? h : w;
  if (!(len > 0) || !(t > 0)) return;
  const piece = round ? t : Math.min(t * 3, len);
  const step = round ? t * 2 : t * 4;
  const r = round ? t / 2 : 0;
  let p = 0;
  while (p < len) {
    const l = Math.min(piece, len - p);
    if (vertical) hostFillRect(x, y + p, w, l, r, color);
    else hostFillRect(x + p, y, l, h, r, color);
    p += step;
  }
}

/** A double side: two lines a third of the border's width, with a third between them. */
function paintDoubleSide(x: number, y: number, w: number, h: number, t: number, vertical: boolean, color: number): void {
  const l = Math.max(1, Math.floor(t / 3));
  if (vertical) {
    hostFillRect(x, y, l, h, 0, color);
    hostFillRect(x + t - l, y, l, h, 0, color);
  } else {
    hostFillRect(x, y, w, l, 0, color);
    hostFillRect(x, y + t - l, w, l, 0, color);
  }
}

/** A side split into an outer and an inner band, as the 3D border styles shade it. */
function paintTwoToneSide(x: number, y: number, w: number, h: number, t: number, vertical: boolean,
  outerFirst: boolean, outer: number, inner: number): void {
  const half = t / 2;
  if (vertical) {
    hostFillRect(outerFirst ? x : x + t - half, y, half, h, 0, outer);
    hostFillRect(outerFirst ? x + half : x, y, half, h, 0, inner);
  } else {
    hostFillRect(x, outerFirst ? y : y + t - half, w, half, 0, outer);
    hostFillRect(x, outerFirst ? y + half : y, w, half, 0, inner);
  }
}

/**
 * One border side in its own style. `outerFirst` says whether the side's outer edge (away from
 * the box's content) comes first: it is the top of a horizontal side, the left of a vertical one.
 */
function paintBorderSide(style: number, color: number, x: number, y: number, w: number, h: number,
  vertical: boolean, outerFirst: boolean): void {
  if (alpha(color) === 0) return;
  const t = vertical ? w : h;
  if (!(t > 0)) return;
  switch (style) {
    case P.BRS_SOLID:
      hostFillRect(x, y, w, h, 0, color);
      return;
    case P.BRS_DOTTED:
      paintDashes(x, y, w, h, t, vertical, true, color);
      return;
    case P.BRS_DASHED:
      paintDashes(x, y, w, h, t, vertical, false, color);
      return;
    case P.BRS_DOUBLE:
      paintDoubleSide(x, y, w, h, t, vertical, color);
      return;
    case P.BRS_GROOVE:
    case P.BRS_RIDGE: {
      // A groove's outer band is dark on the top and left, light on the bottom and right; a
      // ridge is the other way round.
      const outerDark = style === P.BRS_RIDGE ? !outerFirst : outerFirst;
      paintTwoToneSide(x, y, w, h, t, vertical, outerFirst, shade(color, outerDark ? -0.5 : 0.5), shade(color, outerDark ? 0.5 : -0.5));
      return;
    }
    case P.BRS_INSET:
    case P.BRS_OUTSET: {
      // An inset's top and left sides are dark, an outset's light.
      const darkSide = style === P.BRS_INSET ? outerFirst : !outerFirst;
      hostFillRect(x, y, w, h, 0, shade(color, darkSide ? -0.5 : 0.5));
      return;
    }
    default:
      return;
  }
}

/**
 * A rounded border whose four sides share one width, color and style. A dash pattern can't
 * follow the rounded outline, so each corner's arc is drawn whole and the straight runs between
 * the corners take the style; the 3D styles shade the ring's outer and inner halves.
 */
function paintRoundedBorder(serial: number, style: number, color: number, x: number, y: number, w: number, h: number,
  r: Radii, t: number): void {
  if (style === P.BRS_SOLID) {
    fillRoundRing(x, y, w, h, r, t, color);
    return;
  }
  if (style === P.BRS_DOUBLE) {
    const l = Math.max(1, Math.floor(t / 3));
    fillRoundRing(x, y, w, h, r, l, color);
    fillRoundRing(x + 2 * l, y + 2 * l, w - 4 * l, h - 4 * l, insetRadii(r, 2 * l, 2 * l, 2 * l, 2 * l), l, color);
    return;
  }
  if (style === P.BRS_DASHED || style === P.BRS_DOTTED) {
    const round = style === P.BRS_DOTTED;
    // Each corner's arc is drawn whole, clipped to the corner's own square.
    const corners = [
      [x, y, r[0], r[1]],
      [x + w - r[2], y, r[2], r[3]],
      [x + w - r[4], y + h - r[5], r[4], r[5]],
      [x, y + h - r[7], r[6], r[7]],
    ];
    for (const c of corners) {
      if (!(c[2] > 0) || !(c[3] > 0)) continue;
      hostClipPush(serial, P.PK_CLIP_RECT, c[0], c[1], c[2], c[3], 0);
      fillRoundRing(x, y, w, h, r, t, color);
      hostClipPop();
    }
    // The straight runs between the arcs take the dash pattern.
    const runW = w - r[0] - r[2];
    const runH = h - r[1] - r[7];
    if (runW > 0) {
      paintDashes(x + r[0], y, runW, t, t, false, round, color);
      paintDashes(x + r[6], y + h - t, w - r[6] - r[4], t, t, false, round, color);
    }
    if (runH > 0) {
      paintDashes(x, y + r[1], t, runH, t, true, round, color);
      paintDashes(x + w - t, y + r[3], t, h - r[3] - r[5], t, true, round, color);
    }
    return;
  }
  // groove, ridge, inset and outset: one ring, its outer half shaded against its inner half.
  const outerLight = style === P.BRS_RIDGE || style === P.BRS_OUTSET;
  const half = t / 2;
  fillRoundRing(x, y, w, h, r, half, shade(color, outerLight ? 0.5 : -0.5));
  fillRoundRing(x + half, y + half, w - 2 * half, h - 2 * half, insetRadii(r, half, half, half, half), half, shade(color, outerLight ? -0.5 : 0.5));
}

/** The border widths that fit the box, and the padding box they leave inside it. */
interface BorderBox {
  bt: number; br: number; bb: number; bl: number;
  iw: number; ih: number;
}

/**
 * The border widths and the padding box they leave. Two opposite borders that can't both fit are
 * shrunk in proportion, as browsers shrink them, so the padding box never goes negative.
 */
function borderBox(w: number, h: number, bt: number, br: number, bb: number, bl: number): BorderBox {
  if (bl + br > w) {
    const k = bl + br > 0 ? w / (bl + br) : 0;
    bl *= k;
    br *= k;
  }
  if (bt + bb > h) {
    const k = bt + bb > 0 ? h / (bt + bb) : 0;
    bt *= k;
    bb *= k;
  }
  return { bt, br, bb, bl, iw: Math.max(0, w - bl - br), ih: Math.max(0, h - bt - bb) };
}

/**
 * One side of a border as a quadrilateral, in the miter geometry browsers use: its outer edge is
 * the border box's, its inner edge the padding box's, so neighbouring sides split each corner
 * along the line between the two. A zero-size box leaves a triangle per side.
 */
function sideQuad(side: number, x: number, y: number, w: number, h: number, b: BorderBox): number[] {
  const ix = x + b.bl, iy = y + b.bt, iw = b.iw, ih = b.ih;
  if (side === 0) return [x, y, x + w, y, ix + iw, iy, ix, iy];
  if (side === 1) return [x + w, y, x + w, y + h, ix + iw, iy + ih, ix + iw, iy];
  if (side === 2) return [x, y + h, ix, iy + ih, ix + iw, iy + ih, x + w, y + h];
  return [x, y, ix, iy, ix, iy + ih, x, y + h];
}

/**
 * The band one side is painted in: the side's own thickness, running the full length of the edge
 * so it reaches into both corners, where the side's quad cuts it back along the corner's miter.
 * Every style needs that corner reach: a double side's rounded corner square, a dash that starts
 * at the corner, and a dot centred on it all lie in the band's last stretch.
 */
function sideBand(side: number, x: number, y: number, w: number, h: number, b: BorderBox): number[] {
  if (side === 0) return [x, y, w, b.bt];
  if (side === 1) return [x + w - b.br, y, b.br, h];
  if (side === 2) return [x, y + h - b.bb, w, b.bb];
  return [x, y, b.bl, h];
}

/** Whether a side's quad is just its band (no miter at either end), so it needs no clip. */
function quadIsBand(q: number[], band: number[]): boolean {
  const near = (v: number, a: number, b: number) => Math.abs(v - a) < 1e-6 || Math.abs(v - b) < 1e-6;
  for (let i = 0; i < 8; i += 2) {
    if (!near(q[i], band[0], band[0] + band[2]) || !near(q[i + 1], band[1], band[1] + band[3])) return false;
  }
  return true;
}

// Each corner's outer arc runs from the edge of the side before it to the edge of the side it
// belongs to: top-left from the left edge (π) round to the top edge (3π/2), and so on clockwise.
// The third angle is the middle of the arc, where the two sides split the corner.
const CORNER_ANGLES = [
  [Math.PI, 1.5 * Math.PI, 1.25 * Math.PI],
  [1.5 * Math.PI, 2 * Math.PI, 1.75 * Math.PI],
  [0, 0.5 * Math.PI, 0.25 * Math.PI],
  [0.5 * Math.PI, Math.PI, 0.75 * Math.PI],
];

/** A corner arc's centre: the corner point pulled in by the corner's radii. */
function cornerCentre(corner: number, x: number, y: number, w: number, h: number, r: Radii, out: number[]): void {
  const rx = r[2 * corner];
  const ry = r[2 * corner + 1];
  out[0] = corner === 1 || corner === 2 ? x + w - rx : x + rx;
  out[1] = corner >= 2 ? y + h - ry : y + ry;
}

/** Appends a corner's elliptical arc from angle `t0` to `t1`, flattened into straight segments. */
function arcPoints(out: number[], cx: number, cy: number, rx: number, ry: number, t0: number, t1: number): void {
  if (!(rx > 0) || !(ry > 0)) return;
  const steps = Math.max(2, Math.min(24, Math.ceil(Math.max(rx, ry) / 2)));
  for (let i = 1; i <= steps; i++) {
    const t = t0 + ((t1 - t0) * i) / steps;
    out.push(cx + rx * Math.cos(t), cy + ry * Math.sin(t));
  }
}

/**
 * One side of a rounded border box, as a polygon: its stretch of the outer rounded edge, the
 * corner splits it shares with its neighbours, and the matching stretch of the padding box's
 * rounded edge. A square corner is its box point and a neighbour with no border gives up the
 * whole corner, as the square miter does.
 */
function roundedSidePolygon(side: number, x: number, y: number, w: number, h: number, r: Radii,
  inner: Radii, b: BorderBox): number[] {
  const widths = [b.bt, b.br, b.bb, b.bl];
  // The side's arc ends at the corner it is numbered after and starts at the next corner round.
  const end = side;
  const start = (side + 1) % 4;
  // Where the corner splits between the two sides: at its arc's middle when both have a border,
  // or at the far end of the arc when the neighbour has none and the corner is all this side's.
  const endAngle = widths[(side + 3) % 4] > 0 ? CORNER_ANGLES[end][2] : CORNER_ANGLES[end][0];
  const startAngle = widths[start] > 0 ? CORNER_ANGLES[start][2] : CORNER_ANGLES[start][1];
  const c = [0, 0];
  const pts: number[] = [];
  cornerCentre(end, x, y, w, h, r, c);
  const ex = c[0], ey = c[1], erx = r[2 * end], ery = r[2 * end + 1];
  pts.push(ex + erx * Math.cos(endAngle), ey + ery * Math.sin(endAngle));
  arcPoints(pts, ex, ey, erx, ery, endAngle, CORNER_ANGLES[end][1]);
  cornerCentre(start, x, y, w, h, r, c);
  const orx = r[2 * start], ory = r[2 * start + 1];
  pts.push(c[0] + orx * Math.cos(CORNER_ANGLES[start][0]), c[1] + ory * Math.sin(CORNER_ANGLES[start][0]));
  arcPoints(pts, c[0], c[1], orx, ory, CORNER_ANGLES[start][0], startAngle);
  const ix = x + b.bl, iy = y + b.bt, iw = b.iw, ih = b.ih;
  cornerCentre(start, ix, iy, iw, ih, inner, c);
  const sx = c[0], sy = c[1], irx = inner[2 * start], iry = inner[2 * start + 1];
  pts.push(sx + irx * Math.cos(startAngle), sy + iry * Math.sin(startAngle));
  arcPoints(pts, sx, sy, irx, iry, startAngle, CORNER_ANGLES[start][0]);
  cornerCentre(end, ix, iy, iw, ih, inner, c);
  const drx = inner[2 * end], dry = inner[2 * end + 1];
  pts.push(c[0] + drx * Math.cos(CORNER_ANGLES[end][1]), c[1] + dry * Math.sin(CORNER_ANGLES[end][1]));
  arcPoints(pts, c[0], c[1], drx, dry, CORNER_ANGLES[end][1], endAngle);
  return pts;
}

/** The host's point list for these polygons, each a flat run of x,y vertices. */
function polyText(polys: number[][]): string {
  const parts: string[] = [];
  for (const p of polys) {
    const v: string[] = [];
    for (let i = 0; i < p.length; i += 2) v.push(`${p[i]},${p[i + 1]}`);
    parts.push(v.join(" "));
  }
  return parts.join(";");
}

/** A sliced piece's radii: the corners at its own ends, none at a break. */
function pieceRadii(r: Radii, first: boolean, last: boolean, block: boolean = false): Radii {
  if (block) {
    return [
      first ? r[0] : 0, first ? r[1] : 0,
      first ? r[2] : 0, first ? r[3] : 0,
      last ? r[4] : 0, last ? r[5] : 0,
      last ? r[6] : 0, last ? r[7] : 0,
    ];
  }
  return [
    first ? r[0] : 0, first ? r[1] : 0,
    last ? r[2] : 0, last ? r[3] : 0,
    last ? r[4] : 0, last ? r[5] : 0,
    first ? r[6] : 0, first ? r[7] : 0,
  ];
}

/**
 * Fills each side of a border box in its style, cut to the mitered quad its corners make with its
 * neighbours, or to the rounded edge those corners curve into. A piece broken off an inline box
 * (first or last of its pieces) leaves out the side at the break, as box-decoration-break: slice
 * draws it.
 */
function paintBorderSides(e: Node, x: number, y: number, w: number, h: number, opacity: number,
  first: boolean, last: boolean, r: Radii | null, block: boolean = false): void {
  // A piece broken off a box draws no side at the break, so its corner geometry starts from the
  // break's edge instead of tapering to a border that isn't there. A column break cuts the top
  // and bottom sides; an inline break cuts the left and right ones.
  const lw = borderPx(e.sv[P.P_BORDER_LEFT_WIDTH]);
  const rw = borderPx(e.sv[P.P_BORDER_RIGHT_WIDTH]);
  const tw = borderPx(e.sv[P.P_BORDER_TOP_WIDTH]);
  const bw = borderPx(e.sv[P.P_BORDER_BOTTOM_WIDTH]);
  const bl = block || first ? lw : 0;
  const br = block || last ? rw : 0;
  const bt = block && !first ? 0 : tw;
  const bb = block && !last ? 0 : bw;
  const b = borderBox(w, h, bt, br, bb, bl);
  const widths = [b.bt, b.br, b.bb, b.bl];
  const styles = [e.sv[P.P_BORDER_TOP_STYLE], e.sv[P.P_BORDER_RIGHT_STYLE], e.sv[P.P_BORDER_BOTTOM_STYLE], e.sv[P.P_BORDER_LEFT_STYLE]];
  const colors = [P.P_BORDER_TOP_COLOR, P.P_BORDER_RIGHT_COLOR, P.P_BORDER_BOTTOM_COLOR, P.P_BORDER_LEFT_COLOR];
  // A rounded box's sides follow the corner arcs. A piece broken off an inline box keeps the
  // corners at its own ends and squares off the ones at a break: slicing the whole box's border
  // leaves those corners outside the piece.
  const piece = r !== null && rounded(r) ? pieceRadii(r, first, last, block) : null;
  const round = piece !== null && rounded(piece) ? piece : null;
  const inner = round === null ? null : insetRadii(round, b.bl, b.bt, b.br, b.bb);
  // Solid sides that share a colour go into one path: their shapes meet along a diagonal at each
  // corner, and filling them separately would leave an antialiased seam there.
  const solid: number[][][] = [];
  const solidColors: number[] = [];
  for (let side = 0; side < 4; side++) {
    if (!(widths[side] > 0)) continue;
    const color = withOpacity(borderColorAt(e, colors[side]), opacity);
    if (alpha(color) === 0) continue;
    if (styles[side] === P.BRS_SOLID) {
      let g = solidColors.indexOf(color);
      if (g < 0) {
        g = solidColors.length;
        solidColors.push(color);
        solid.push([]);
      }
      solid[g].push(round !== null && inner !== null
        ? roundedSidePolygon(side, x, y, w, h, round, inner, b)
        : sideQuad(side, x, y, w, h, b));
      continue;
    }
    const q = sideQuad(side, x, y, w, h, b);
    const band = sideBand(side, x, y, w, h, b);
    const vertical = side === 1 || side === 3;
    const outerFirst = side === 0 || side === 3;
    const clip = !quadIsBand(q, band);
    if (round !== null) {
      hostClipPushRound(e.serial, P.PK_CLIP_RECT, x, y, w, h, round[0], round[1], round[2], round[3], round[4], round[5], round[6], round[7]);
      if (clip) hostClipPushPoly(e.serial, P.PK_CLIP_POLY, polyText([q]));
      paintBorderSide(styles[side], color, band[0], band[1], band[2], band[3], vertical, outerFirst);
      if (clip) hostClipPop();
      hostClipPop();
    } else if (clip) {
      // The side's band in its style, cut to the quad its corners miter into.
      hostClipPushPoly(e.serial, P.PK_CLIP_POLY, polyText([q]));
      paintBorderSide(styles[side], color, band[0], band[1], band[2], band[3], vertical, outerFirst);
      hostClipPop();
    } else {
      paintBorderSide(styles[side], color, band[0], band[1], band[2], band[3], vertical, outerFirst);
    }
  }
  for (let g = 0; g < solidColors.length; g++) hostFillPoly(polyText(solid[g]), solidColors[g]);
}

/** Paints a border box: one rounded shape when all four sides agree, else each side in place. */
function paintBorder(e: Node, x: number, y: number, w: number, h: number, r: Radii,
  opacity: number, first: boolean, last: boolean, block: boolean = false): void {
  // A border image replaces the border styles, and is not cut by a rounded corner.
  if (hasBorderImage(e)) {
    paintBorderImage(e, x, y, w, h, opacity, first, last);
    return;
  }
  const b = uniformBorder(e);
  if (b === 0) return;
  if (b > 0 && first && last) {
    // A style that is the same all the way round is drawn as whole rings (or whole runs of
    // dashes), which keeps corners solid where per-side pieces would meet along a seam. The 3D
    // styles are the exception: their shading changes from side to side, so each side is drawn
    // in its own place.
    const style = e.sv[P.P_BORDER_TOP_STYLE];
    const whole = rounded(r) || style === P.BRS_SOLID || style === P.BRS_DOUBLE ||
      style === P.BRS_DASHED || style === P.BRS_DOTTED;
    if (whole) {
      const color = withOpacity(borderColorAt(e, P.P_BORDER_TOP_COLOR), opacity);
      if (alpha(color) > 0) {
        if (!rounded(r) && (style === P.BRS_DASHED || style === P.BRS_DOTTED)) {
          // The pattern is laid out along the edges' lengths, so it is laid out on the pixel
          // grid the box is painted on: a 50.1px box spaces its dots as a 50px one does.
          const x0 = Math.round(x), y0 = Math.round(y);
          paintRoundedBorder(e.serial, style, color, x0, y0, Math.round(x + w) - x0, Math.round(y + h) - y0, r, b);
        } else {
          paintRoundedBorder(e.serial, style, color, x, y, w, h, r, b);
        }
      }
      return;
    }
  }
  paintBorderSides(e, x, y, w, h, opacity, first, last, r, block);
}

/**
 * The element whose background becomes the canvas's: the root, or the body when the root's own
 * background is transparent (neither a colour nor an image). Null when neither has one.
 */
function canvasSource(root: Node): Node | null {
  // A display:none root isn't rendered, and a root with paint containment paints into its own
  // box: neither contributes to the canvas.
  if (root.sv[P.P_DISPLAY] === P.D_NONE) return null;
  if ((root.sv[P.P_CONTAIN] & P.CONTAIN_PAINT) !== 0) return null;
  const has = (e: Node): boolean => alpha(e.sv[P.P_BACKGROUND_COLOR]) > 0 || hasBackgroundImage(e);
  if (has(root)) return root;
  for (const c of boxKids(root)) {
    if (c.tagName !== "BODY") continue;
    // The body's background reaches the canvas only while the body generates a box of its own
    // and doesn't contain its painting.
    if (c.sv[P.P_DISPLAY] === P.D_NONE || c.sv[P.P_DISPLAY] === P.D_CONTENTS) continue;
    if ((c.sv[P.P_CONTAIN] & P.CONTAIN_PAINT) !== 0) continue;
    if (has(c)) return c;
  }
  return null;
}

/** The element painted as the canvas's background, so paintBox doesn't paint it a second time. */
let canvasEl: Node | null = null;

/** Canvas background colour: the propagated element's, or white when it has none. */
export function canvasColor(root: Node): number {
  // A page painted in the UA's dark colours has a dark canvas behind it, as a browser's dark
  // scheme does, unless its own background covers it.
  const base = (root.state & P.S_SCHEME_DARK) !== 0 ? 0x121212ff : 0xffffffff;
  const el = canvasSource(root);
  if (el === null) return base;
  const c = el.sv[P.P_BACKGROUND_COLOR];
  // The canvas sits on the page's white backdrop, so a translucent propagated colour shows the
  // two mixed rather than a see-through canvas.
  return alpha(c) > 0 ? overColor(c, base) : base;
}

/**
 * Whether a decoration stops at this box: an atomic inline box, a float or an out-of-flow box
 * takes its own layout, so a decoration declared above it is not drawn over its text.
 */
function decorationStops(e: Node): boolean {
  const d = display(e);
  if (d === P.D_INLINE_BLOCK || d === P.D_INLINE_FLEX || d === P.D_INLINE_TABLE) return true;
  if (d === P.D_INLINE && isReplaced(e)) return true;
  return isOutOfFlow(e) || isFloat(e);
}

/**
 * Draws the decorations over one run of text: each element from the run's own up that declared a
 * decoration draws its lines in its own colour, style and thickness, until a box that stops the
 * propagation. A decoration's `currentColor` is the colour of the element that declared it.
 */
function decorate(style: Node, x: number, baseline: number, w: number, opacity: number): void {
  let e: Node | null = style;
  while (e !== null) {
    if (e.decorDeclared) drawDecoration(e, x, baseline, w, opacity);
    if (decorationStops(e)) break;
    e = e.parentElement;
  }
}

/** One element's lines: the underline, overline and line-through its own style names. */
function drawDecoration(style: Node, x: number, baseline: number, w: number, opacity: number): void {
  const td = style.sv[P.P_TEXT_DECORATION];
  if (td === P.TD_NONE) return;
  const size = style.sv[P.P_FONT_SIZE];
  // `text-decoration-inset` pulls the lines back from both ends of the run they decorate; an
  // inset that swallows the run draws nothing. `auto` is the line's own metric, and a percentage
  // is relative to the font size.
  const insetOf = (p: number): number => {
    const u = style.su[p];
    if (u === P.U_AUTO) return autoInsetPx(size);
    if (u === P.U_PCT) return (style.sv[p] / 100) * size;
    if (u === P.U_EXPR) return 0;
    return len(style, p, size);
  };
  const insStart = insetOf(P.P_TEXT_DECORATION_INSET);
  const insEnd = insetOf(P.P_TEXT_DECORATION_INSET_END);
  if (insStart !== 0 || insEnd !== 0) {
    x += insStart;
    w -= insStart + insEnd;
    if (!(w > 0)) return;
  }
  const [ascent, , xHeight] = fontMetrics(style);
  // A thickness of `auto` or `from-font` is the font's own, scaled to the text's size; a
  // percentage is relative to the font size, as the spec defines both percentages.
  let thickness = style.sv[P.P_TEXT_DECORATION_THICKNESS];
  const tu = style.su[P.P_TEXT_DECORATION_THICKNESS];
  if (tu === P.U_AUTO || tu === P.U_FROM_FONT) thickness = Math.max(1, size / 16);
  else if (tu === P.U_PCT) thickness = (thickness / 100) * size;
  if (thickness <= 0) return;
  const c = style.sv[P.P_TEXT_DECORATION_COLOR];
  const paint = c < 0 ? withOpacity(style.sv[P.P_COLOR], opacity) : c;
  const kind = style.sv[P.P_TEXT_DECORATION_STYLE];
  if (td & P.TD_UNDERLINE) {
    // `auto` puts the line just below the baseline, clear of the descenders' tops.
    let offset = style.sv[P.P_UNDERLINE_OFFSET];
    const ou = style.su[P.P_UNDERLINE_OFFSET];
    if (ou === P.U_AUTO) offset = Math.max(1, size * 0.09);
    else if (ou === P.U_PCT) offset = (offset / 100) * size;
    hostFillLine(x, x + w, baseline + offset, thickness, paint, kind);
  }
  if (td & P.TD_OVERLINE) hostFillLine(x, x + w, baseline - ascent, thickness, paint, kind);
  if (td & P.TD_LINE_THROUGH) {
    // Through the middle of the x-height, which is where a strikeout sits.
    hostFillLine(x, x + w, baseline - xHeight / 2 - thickness / 2, thickness, paint, kind);
  }
}

function inlineDepth(e: Node, container: Node): number {
  let d = 0;
  let p = e.parentElement;
  while (p !== null && p !== container) {
    d++;
    p = p.parentElement;
  }
  return d;
}

/**
 * The element whose inline box a fragment belongs to: the owner of a text run, or for an edge or
 * an atomic box the inline box it sits in (an atomic box's own style isn't inline).
 */
function fragmentBox(el: Node, i: number): Node | null {
  if (el.fragKind[i] === FRAG_TEXT) return el.fragOwner[i];
  const s = el.fragStyle[i];
  // A replaced inline (an image) is display:inline but paints its own box, so it is an atomic
  // box to the line like an inline-block, not an inline box whose background the line draws.
  if (display(s) === P.D_INLINE && !isReplaced(s)) return s;
  return s.parentElement;
}

/**
 * The opacity a box's fragments paint at: its own and every inline box's between it and the
 * container whose fragments they are. A plain inline box doesn't paint a group of its own — its
 * pieces go down in line order with the text around them — so its opacity multiplies into them
 * instead, fading its background and its text one drawing at a time.
 */
function inlineOpacity(el: Node, from: Node, opacity: number): number {
  let n: Node | null = from;
  while (n !== null && n !== el) {
    opacity *= n.sv[P.P_OPACITY];
    n = n.parentElement;
  }
  return opacity;
}

/**
 * Inline fragments of a block container: each line's inline boxes and text, in document order.
 * `bsign` is -1 for a turned frame whose block axis runs towards the page's right (the -lr
 * modes), whose fragments the quarter turn would otherwise place on the page's left.
 */
function paintFragments(el: Node, x: number, y: number, opacity: number, bsign: number): void {
  const n = el.fragKind.length;
  if (n === 0) return;
  // Where a box of `h` starting `top` into the line box goes in the turned frame's coordinates.
  const blockTop = (top: number, h: number): number => (bsign > 0 ? y + top : y - top - h);
  // Where a baseline at `top` in the line box goes.
  const blockBase = (top: number): number => (bsign > 0 ? y + top : y - top);

  // The first and last line each inline box appears on. A box broken by a block, or by a line
  // break, keeps its left border only on its first piece and its right border only on its last,
  // as box-decoration-break: slice draws it.
  const extent = new Map<Node, number[]>();
  for (let i = 0; i < n; i++) {
    // A fragment on no line is an inline box around nothing: it is there for the DOM's rects and
    // paints nothing, so it doesn't make a box's first or last piece.
    if (el.fragLine[i] === EMPTY_LINE) continue;
    let e: Node | null = fragmentBox(el, i);
    while (e !== null && e !== el && display(e) === P.D_INLINE) {
      const m = extent.get(e);
      if (m === undefined) extent.set(e, [el.fragLine[i], el.fragLine[i]]);
      else {
        if (el.fragLine[i] < m[0]) m[0] = el.fragLine[i];
        if (el.fragLine[i] > m[1]) m[1] = el.fragLine[i];
      }
      e = e.parentElement;
    }
  }

  // Each line's vertical band, from the fragments that sit on it: a line the clip cannot see is
  // skipped before its boxes and runs are gathered, so a long block's paint costs what the
  // scrollport shows rather than what the block holds.
  const lineTop: number[] = [];
  const lineBottom: number[] = [];
  for (let i = 0; i < n; i++) {
    const ln = el.fragLine[i];
    if (ln < 0) continue;
    while (lineTop.length <= ln) {
      lineTop.push(Infinity);
      lineBottom.push(-Infinity);
    }
    const t = el.fragTop[i];
    if (t < lineTop[ln]) lineTop[ln] = t;
    if (t > lineBottom[ln]) lineBottom[ln] = t;
  }
  const lhAll = lineHeightPx(el);
  // A turned frame's fragments are drawn through the quarter turn, in their own coordinates:
  // the clip is not in that space, so its lines are painted as before.
  const cull = cullingOn() && el.vtext === 0;
  for (let line = 0; line < el.lineBaseline.length; line++) {
    if (cull && line < lineTop.length && lineTop[line] !== Infinity) {
      const top = lineTop[line];
      const bottom = lineBottom[line] + lhAll;
      const y0 = bsign > 0 ? y + top : y - bottom;
      if (!inClip(x, y0, el.w, bottom - top)) continue;
    }
    // One background rect per inline element per line, spanning its fragments, and the fragment
    // each box first shows on there. A line paints its inline boxes and its runs as they come,
    // in document order, so a box's shadow or background covers the text before it and is
    // covered by the text after it.
    const boxes: Node[] = [];
    const x0: number[] = [];
    const x1: number[] = [];
    const at: number[] = [];
    for (let i = 0; i < n; i++) {
      if (el.fragLine[i] !== line) continue;
      let e: Node | null = fragmentBox(el, i);
      while (e !== null && e !== el && display(e) === P.D_INLINE) {
        let left = el.fragX[i];
        let right = el.fragX[i] + el.fragW[i];
        if (el.fragKind[i] !== FRAG_TEXT && e === el.fragStyle[i]) {
          if (el.fragText[i] === "<") left += e.sv[P.P_MARGIN_LEFT];
          else if (el.fragText[i] === ">") right -= e.sv[P.P_MARGIN_RIGHT];
        }
        const k = boxes.indexOf(e);
        if (k < 0) {
          boxes.push(e);
          x0.push(left);
          x1.push(right);
          at.push(i);
        } else {
          x0[k] = Math.min(x0[k], left);
          x1[k] = Math.max(x1[k], right);
        }
        e = e.parentElement;
      }
    }
    // The text run that ends the line: the separators at its end hang past the line's edge, so
    // a justified line draws them without the extra spacing it spreads over its other spaces.
    let lastRun = -1;
    for (let i = 0; i < n; i++) if (el.fragLine[i] === line && el.fragKind[i] === FRAG_TEXT) lastRun = i;
    const order: number[] = [];
    for (let k = 0; k < boxes.length; k++) order.push(k);
    order.sort((a, b) => at[a] - at[b] || inlineDepth(boxes[b], el) - inlineDepth(boxes[a], el));
    const baseline = el.lineBaseline[line];
    // ::first-line and ::first-letter style the first line's runs: their own colour and the
    // line's background, with the letter's own glyph. The boxes are carriers; layout still
    // measures with each run's own font.
    const firstLineStyle = line === 0 && el instanceof Element ? el.firstLinePseudo : null;
    // A floated first letter is a box of its own; the line does not paint it.
    const firstLetterStyle = line === 0 && el instanceof Element && el.firstLetterFloat === null
      ? el.firstLetterPseudo : null;
    if (firstLineStyle !== null) {
      const bg = firstLineStyle.sv[P.P_BACKGROUND_COLOR];
      if ((bg & 255) !== 0) {
        let left = Infinity, right = -Infinity, top = NaN;
        for (let i = 0; i < n; i++) {
          if (el.fragLine[i] !== line || el.fragKind[i] !== FRAG_TEXT) continue;
          if (el.fragX[i] < left) left = el.fragX[i];
          if (el.fragX[i] + el.fragW[i] > right) right = el.fragX[i] + el.fragW[i];
          if (Number.isNaN(top)) top = el.fragTop[i];
        }
        if (right > left && !Number.isNaN(top)) {
          hostFillRect(x + left, blockTop(top, lineHeightPx(el)), right - left, lineHeightPx(el), 0, withOpacity(bg, opacity));
        }
      }
    }
    let letterDone = false;
    let next = 0;
    const flush = (i: number): void => {
      while (next < order.length && at[order[next]] <= i) {
        const k = order[next++];
        // A relative or vertical-align shift moved the fragments, not the line's baseline: the
        // box's background goes where its own fragment went. A box whose first fragment on the
        // line is an atomic box (an image, say) is placed by that box's baseline, so its own
        // fragment top says nothing about where the inline box sits.
        const f = at[k];
        const dy = el.fragStyle[f] === boxes[k] ? el.fragTop[f] - (baseline - baselineOffset(boxes[k])) : 0;
        paintInlineBox(el, boxes[k], x0[k], x1[k], line, baseline, dy, x, y, inlineOpacity(el, boxes[k], opacity), extent, bsign);
      }
    };
    for (let i = 0; i < n; i++) {
      if (el.fragLine[i] !== line) continue;
      flush(i);
      if (el.fragKind[i] !== FRAG_TEXT) continue;
      const s = el.fragStyle[i];
      if (s.sv[P.P_VISIBILITY] !== P.VIS_VISIBLE) continue;
      // A zero font size draws no glyph, and no underline: the host's font API clamps the size it
      // is given, so it would otherwise paint letters the layout gave no room to. (measure() stops
      // at the same point, in layout/box-model.ts.)
      if (s.sv[P.P_FONT_SIZE] <= 0) continue;
      const lh = lineHeightPx(s);
      const sop = inlineOpacity(el, s, opacity);
      const baseColor = firstLineStyle !== null ? firstLineStyle.sv[P.P_COLOR] : s.sv[P.P_COLOR];
      const color = withOpacity(baseColor, sop);
      const tx = x + el.fragX[i];
      const text = el.fragText[i];
      const part = el instanceof Element ? fragmentSelection(el, i) : null;
      const colors = part === null ? NO_SELECTION_COLORS : selectionColors(s);
      const start = el instanceof Element && highlightCovers.length > 0 ? fragmentStream(el, i)[0] : 0;
      // A run that opts out of justification takes none of a justified line's spare room.
      const ownsJustify = s.sv[P.P_TEXT_JUSTIFY] !== P.TJUST_NONE;
      const extraWord = ownsJustify ? el.lineExtraWord[line] ?? 0 : 0;
      const extraLetter = ownsJustify ? el.lineExtraLetter[line] ?? 0 : 0;
      // The separators that end the line hang, so they take none of that room.
      const hang = i === lastRun && (extraWord !== 0 || extraLetter !== 0) ? trailingSeparators(text) : 0;
      // The line box's top in the turned frame's coordinates, which the block axis may flip.
      const top = blockTop(el.fragTop[i], lh);
      paintTextShadows(s, text, tx, top, lh, color, sop, extraWord, extraLetter);
      paintHighlightBackgrounds(s, s, text, tx, top, lh, start);
      if (part !== null) {
        paintSelectionPart(s, text, tx, top, lh, part, colors[0] >= 0 ? colors[0] : systemSelectionColor(s));
      }
      // ::first-letter paints the very first glyph of the first line, and the rest of that run
      // keeps the line's colour.
      let letter: Element | null = null;
      if (firstLetterStyle !== null && !letterDone && text.trim() !== "") {
        letterDone = true;
        letter = firstLetterStyle;
      }
      paintLineText(s, text, tx, top, lh, color, sop, letter, part,
        colors[1] >= 0 ? colors[1] : systemSelectionTextColor(s), start, extraWord, extraLetter, hang);
      decorate(s, tx, blockBase(el.lineBaseline[el.fragLine[i]]), el.fragW[i], sop);
    }
    flush(n);
  }
}

/**
 * Paints one inline box on one line: its background, its shadows and its border, across the
 * [left, right] span its fragments take up on that line. `extent` holds each element's first and
 * last line, so a box broken across lines draws the sides it has a piece for.
 */
function paintInlineBox(el: Node, e: Node, left: number, right: number, line: number, baseline: number,
  dy: number, x: number, y: number, opacity: number, extent: Map<Node, number[]>, bsign: number): void {
  if (e.sv[P.P_VISIBILITY] !== P.VIS_VISIBLE) return;
  const bg = e.sv[P.P_BACKGROUND_COLOR];
  const b = uniformBorder(e);
  const shadowed = boxShadows(e).length > 0;
  if (alpha(bg) === 0 && b === 0 && !hasBackgroundImage(e) && !shadowed) return;
  const m = fontMetrics(e);
  const top = baseline - m[0] - e.sv[P.P_PADDING_TOP] - e.sv[P.P_BORDER_TOP_WIDTH] + dy;
  const h = m[0] + m[1] + e.sv[P.P_PADDING_TOP] + e.sv[P.P_PADDING_BOTTOM] +
    e.sv[P.P_BORDER_TOP_WIDTH] + e.sv[P.P_BORDER_BOTTOM_WIDTH];
  const w = right - left;
  // A turned frame's block axis may run towards the page's right, which the turn already mirrors.
  const bx = x + left, by = bsign > 0 ? y + top : y - top - h;
  const ext = extent.get(e);
  const first = ext === undefined || line === ext[0];
  const last = ext === undefined || line === ext[1];
  // A piece of a sliced box is drawn as a box of its own: only the first piece has a left edge
  // and only the last a right one, so the corners on the missing side stay square.
  const r = borderRadii(e, w, h, first, last);
  if (!first) {
    r[0] = 0;
    r[1] = 0;
    r[6] = 0;
    r[7] = 0;
  }
  if (!last) {
    r[2] = 0;
    r[3] = 0;
    r[4] = 0;
    r[5] = 0;
  }
  // The fragment's padding box: its border, less the sides this piece doesn't draw.
  const bl = first ? borderPx(e.sv[P.P_BORDER_LEFT_WIDTH]) : 0;
  const br = last ? borderPx(e.sv[P.P_BORDER_RIGHT_WIDTH]) : 0;
  const bt = borderPx(e.sv[P.P_BORDER_TOP_WIDTH]);
  const bb = borderPx(e.sv[P.P_BORDER_BOTTOM_WIDTH]);
  if (shadowed) {
    paintShadows(e, false, bx, by, w, h, r, bx + bl, by + bt, w - bl - br, h - bt - bb,
      insetRadii(r, bl, bt, br, bb), opacity);
  }
  if (alpha(bg) > 0) fillRoundRect(bx, by, w, h, r, withOpacity(bg, opacity));
  paintBackgroundImages(e, bx, by, w, h, r, opacity);
  if (shadowed) {
    paintShadows(e, true, bx, by, w, h, r, bx + bl, by + bt, w - bl - br, h - bt - bb,
      insetRadii(r, bl, bt, br, bb), opacity);
  }
  if (b !== 0 || hasBorder(e) || hasBorderImage(e)) paintBorder(e, bx, by, w, h, r, opacity, first, last);
}

/**
 * Paints a run's text shadows. The written order puts the first shadow on top, so they are drawn
 * in reverse. A hard shadow is the run drawn in the shadow color at the offset; a blurred one is
 * the shadow of the glyphs, which the text itself covers again when it is drawn.
 */
/** The background and colour a ::selection rule didn't set, so the painter takes its own. */
const NO_SELECTION_COLORS: [number, number] = [-1, -1];

/**
 * The colours ::selection gives text in `el`, from the nearest carrier above it. The highlight
 * takes the ::selection style's own colours. A background the rule leaves unset doesn't inherit
 * the way a text colour does: the highlight takes the originating element's background, and a
 * transparent element paints none, as Chrome does. -1 means no ::selection rule styles the text
 * there, so the painter uses the system's highlight colour and the text's own colour.
 */
function selectionColors(el: Node): [number, number] {
  const out: [number, number] = [-1, -1];
  let node: Node | null = el;
  while (node !== null && (out[0] < 0 || out[1] < 0)) {
    if (node instanceof Element && node.selectionPseudo !== null) {
      const p = node.selectionPseudo;
      const d = p.declaredProps;
      if (out[0] < 0) {
        out[0] = d !== null && d[P.P_BACKGROUND_COLOR] !== 0
          ? p.sv[P.P_BACKGROUND_COLOR] : node.sv[P.P_BACKGROUND_COLOR];
      }
      if (out[1] < 0 && d !== null && d[P.P_COLOR] !== 0) out[1] = p.sv[P.P_COLOR];
    }
    node = node.parentNode;
  }
  return out;
}

/** Fills the highlight behind the stretch of one text run that the selection covers. */
function paintSelectionPart(style: Node, text: string, tx: number, ty: number, lh: number,
  part: [number, number] | null, color: number): void {
  if (part === null) return;
  const x1 = tx + textWidth(style, text.slice(0, part[0]));
  const x2 = tx + textWidth(style, text.slice(0, part[1]));
  if (x2 > x1) hostFillRect(x1, ty, x2 - x1, lh, 0, color);
}

/**
 * Paints a text run, splitting it where the selection starts and ends so the selected stretch
 * takes ::selection's own colour. A run with no selection colour of its own is drawn in one call.
 */
function paintTextRun(el: Node, text: string, tx: number, ty: number, lh: number, color: number,
  opacity: number, part: [number, number] | null, selColor: number, start: number,
  extraWord = 0, extraLetter = 0, hang = 0): void {
  const styleWord = wordSpacingPx(el);
  const spacing = letterSpacingPx(el) + extraLetter;
  const word = styleWord + extraWord;
  const size = el.sv[P.P_FONT_SIZE];
  const key = fontKey(el);
  const emph = emphasisSpec(el);
  const emphColor = emphasisColor(el, opacity);
  // The separators that end a justified line hang past its edge, so they take none of the
  // extra spacing: the run is drawn in two pieces, the second without it.
  const hangFrom = hang > 0 ? Math.max(0, text.length - hang) : -1;
  // Where a stretch of the run starts: the width of what comes before it, with the extra
  // spacing those glyphs draw with (the host kerns after every character, and after a word
  // separator by the extra word spacing as well).
  const xAt = (i: number): number => {
    const head = text.slice(0, i);
    let x = tx + textWidth(el, head);
    if (extraWord !== 0 || extraLetter !== 0) {
      const [sep, chars] = itemTextSpacing(head);
      x += sep * extraWord + chars * extraLetter;
    }
    return x;
  };
  const draw = (lo: number, hi: number, c: number): void => {
    if (hi <= lo) return;
    if (hangFrom >= 0 && hangFrom <= lo) {
      hostText(text.slice(lo, hi), xAt(lo), ty, lh, size, key, c, spacing, styleWord, emph, emphColor);
    } else if (hangFrom >= 0 && hangFrom < hi) {
      hostText(text.slice(lo, hangFrom), xAt(lo), ty, lh, size, key, c, spacing, word, emph, emphColor);
      hostText(text.slice(hangFrom, hi), xAt(hangFrom), ty, lh, size, key, c, spacing, styleWord, emph, emphColor);
    } else {
      hostText(text.slice(lo, hi), xAt(lo), ty, lh, size, key, c, spacing, word, emph, emphColor);
    }
  };
  const a = part === null ? 0 : Math.max(0, Math.min(text.length, part[0]));
  const b = part === null ? 0 : Math.max(a, Math.min(text.length, part[1]));
  const covered = highlightCovers.length > 0 ? coversIn(start, text.length) : [];
  if (hangFrom < 0 && (part === null || selColor < 0 || b <= a) && covered.length === 0) {
    hostText(text, tx, ty, lh, size, key, color, spacing, word, emph, emphColor);
    return;
  }
  // The run is cut where the selection and the highlights start and end, and each piece takes the
  // colour of the selection if it is selected, else of the highest-priority highlight over it.
  const bounds: number[] = [0, text.length];
  const selected = part !== null && selColor >= 0 && b > a;
  if (selected) {
    bounds.push(a);
    bounds.push(b);
  }
  const colors: number[] = [];
  for (const c of covered) {
    const lo = Math.max(0, c.a - start), hi = Math.min(text.length, c.b - start);
    bounds.push(lo);
    bounds.push(hi);
    const carrier = highlightCarrier(el, c.name);
    const hides = carrier !== null && carrier.declaredProps !== null && carrier.declaredProps[P.P_COLOR] !== 0;
    colors.push(hides ? carrier!.sv[P.P_COLOR] : -1);
  }
  bounds.sort((x, y) => x - y);
  for (let i = 0; i + 1 < bounds.length; i++) {
    const lo = bounds[i], hi = bounds[i + 1];
    if (hi <= lo) continue;
    let c = -1;
    if (selected && lo >= a && hi <= b) {
      c = selColor;
    } else {
      let best = -1;
      for (let k = 0; k < covered.length; k++) {
        const cov = covered[k];
        if (colors[k] < 0) continue;
        if (cov.a - start > lo || cov.b - start < hi) continue;
        best = colors[k];
      }
      c = best;
    }
    draw(lo, hi, c < 0 ? color : withOpacity(c, opacity));
  }
}

/** The highlight covers that meet a run of `len` characters starting at stream offset `start`. */
function coversIn(start: number, len: number): HighlightCover[] {
  const out: HighlightCover[] = [];
  for (const c of highlightCovers) if (c.b > start && c.a < start + len) out.push(c);
  return out;
}

/**
 * Fills the highlights' backgrounds behind a run, in priority order, so a higher one paints over
 * the lower ones and the selection paints over them all.
 */
function paintHighlightBackgrounds(style: Node, el: Node, text: string, tx: number, ty: number, lh: number,
  start: number): void {
  if (highlightCovers.length === 0) return;
  for (const c of coversIn(start, text.length)) {
    const carrier = highlightCarrier(el, c.name);
    const declared = carrier !== null && carrier.declaredProps !== null &&
      carrier.declaredProps[P.P_BACKGROUND_COLOR] !== 0;
    // A text fragment paints the browser's pale yellow when the page gives no rule of its own.
    const bg = declared ? carrier!.sv[P.P_BACKGROUND_COLOR] : c.name === "" ? TARGET_TEXT_BACKGROUND : -1;
    if (bg < 0) continue;
    const lo = Math.max(0, c.a - start), hi = Math.min(text.length, c.b - start);
    const x1 = tx + textWidth(style, text.slice(0, lo));
    const x2 = tx + textWidth(style, text.slice(0, hi));
    if (x2 > x1) hostFillRect(x1, ty, x2 - x1, lh, 0, bg);
  }
}

/**
 * Draws one line of an element's own text, with ::first-letter's colour on its first glyph when
 * that pseudo-element styles the line.
 */
function paintLineText(el: Node, text: string, tx: number, ty: number, lh: number, color: number,
  opacity: number, letter: Element | null, part: [number, number] | null = null, selColor = -1,
  start = 0, extraWord = 0, extraLetter = 0, hang = 0): void {
  if (letter === null) {
    paintTextRun(el, text, tx, ty, lh, color, opacity, part, selColor, start, extraWord, extraLetter, hang);
    return;
  }
  const spacing = letterSpacingPx(el) + extraLetter;
  const word = wordSpacingPx(el) + extraWord;
  const size = el.sv[P.P_FONT_SIZE];
  const key = fontKey(el);
  const emph = emphasisSpec(el);
  const emphColor = emphasisColor(el, opacity);
  if (text.length < 2) {
    const selected = selColor >= 0 && part !== null && part[0] <= 0 && part[1] > 0;
    const only = selected ? withOpacity(selColor, opacity) : withOpacity(letter.sv[P.P_COLOR], opacity);
    hostText(text, tx, ty, lh, size, key, only, spacing, word, emph, emphColor);
    return;
  }
  // The letter takes the punctuation that belongs to it: "T" of "(T)est", not just "T".
  const n = firstLetterLength(text, langOf(el));
  const first = text.slice(0, n);
  const rest = text.slice(n);
  const firstW = textWidth(el, first);
  // The letter is its own box, so its opacity applies to the background it paints and to the
  // text it draws.
  const letterOp = opacity * letter.sv[P.P_OPACITY];
  const letterBg = letter.sv[P.P_BACKGROUND_COLOR];
  if (alpha(letterBg) !== 0) hostFillRect(tx, ty, firstW, lh, 0, withOpacity(letterBg, letterOp));
  // The letter keeps its own colour unless the selection paints it.
  const selected = selColor >= 0 && part !== null && part[0] <= 0 && part[1] > 0;
  let markColor = -1;
  if (!selected) {
    for (const c of coversIn(start, text.length)) {
      const carrier = highlightCarrier(el, c.name);
      if (carrier !== null && carrier.declaredProps !== null && carrier.declaredProps[P.P_COLOR] !== 0) markColor = carrier.sv[P.P_COLOR];
    }
  }
  const firstColor = selected ? withOpacity(selColor, opacity)
    : markColor >= 0 ? withOpacity(markColor, opacity) : withOpacity(letter.sv[P.P_COLOR], letterOp);
  hostText(first, tx, ty, lh, size, key, firstColor, spacing, word, emph, emphColor);
  const from = part === null ? 0 : Math.max(0, part[0] - n);
  const to = part === null ? 0 : Math.max(0, part[1] - n);
  paintTextRun(el, rest, tx + firstW, ty, lh, color, opacity, part === null ? null : [from, to], selColor,
    start + n, extraWord, extraLetter, hang > n ? hang - n : 0);
}

function paintTextShadows(el: Node, text: string, x: number, y: number, lh: number, color: number,
  opacity: number, extraWord = 0, extraLetter = 0): void {
  const list = textShadows(el);
  if (list.length === 0) return;
  const size = el.sv[P.P_FONT_SIZE];
  const weight = fontKey(el);
  const letter = letterSpacingPx(el) + extraLetter;
  const word = wordSpacingPx(el) + extraWord;
  for (let i = list.length - 1; i >= 0; i--) {
    const sh = list[i];
    const sc = withOpacity(sh.color < 0 ? el.sv[P.P_COLOR] : sh.color, opacity);
    if (alpha(sc) === 0) continue;
    // The marks are drawn with the text itself, once, in their own colour.
    const em = emphasisSpec(el);
    const emc = emphasisColor(el, opacity);
    if (sh.blur <= 0) hostText(text, x + sh.dx, y + sh.dy, lh, size, weight, sc, letter, word, em, emc);
    else hostTextShadow(text, x, y, lh, size, weight, color, sc, letter, word, sh.dx, sh.dy, sh.blur, em, emc);
  }
}

/** A positioned box (relative, absolute or fixed) is painted in the positioned layer. */
function isPositioned(el: Node): boolean {
  return el.sv[P.P_POSITION] !== P.POS_STATIC;
}

/** A flex or grid item, which takes part in painting order like an inline block, not a block. */
function isFlexItem(el: Node): boolean {
  const p = el.parentElement;
  return p !== null && (isFlexContainer(p) || isGridContainer(p) || isLanesContainer(p));
}

/**
 * A flex, grid or lanes item paints as one unit of its own, the way an inline block does: its
 * background, the floats it holds and its inline content all go down together, in the order the
 * items stand in, rather than its content joining the rest of the formatting context's inline
 * content (CSS Flexbox 5.4, CSS Grid 4.4). An out-of-flow child of such a container is not an
 * item and paints as a positioned box does.
 */
function paintsAsUnit(el: Node): boolean {
  return isFlexItem(el) && !isOutOfFlow(el);
}

/**
 * A box that is painted in the positioned layer of its parent stacking context: a positioned
 * box, or a flex or grid item with a z-index, which establishes a stacking context even while it
 * is statically positioned (CSS Flexbox 5.4, CSS Grid 4.4).
 */
function isStackingItem(el: Node): boolean {
  return isPositioned(el) || (isFlexItem(el) && el.su[P.P_Z_INDEX] !== P.U_AUTO);
}

/** A stacking item with a z-index establishes a stacking context. */
function createsContext(el: Node): boolean {
  return (isStackingItem(el) && el.su[P.P_Z_INDEX] !== P.U_AUTO) || effectKind(el) !== 0 ||
    hasClipPath(el) || hasMask(el) || willChangeBits(el) !== 0;
}

/**
 * Whether a box paints through a wrapper of its own: a transform, an effect layer, a clip path, a
 * mask, or a `will-change` that makes it a stacking context with a box the compositor can move.
 */
function paintsGroup(el: Node): boolean {
  return hasTransform(el) || effectKind(el) !== 0 || hasClipPath(el) || hasMask(el) ||
    willChangeBits(el) !== 0;
}

/**
 * Whether a box paints through a layer of its own: a filter, a blend mode other than normal,
 * `isolation: isolate`, or a backdrop-filter, each of which makes it a stacking context whose
 * subtree the host draws as one image (and filters or blends). 0 for a box that paints plainly.
 */
function effectKind(el: Node): number {
  if (el.sv[P.P_FILTER] >= 0) return 1;
  if (el.sv[P.P_MIX_BLEND_MODE] !== P.MB_NORMAL) return 2;
  if (el.sv[P.P_ISOLATION] === P.ISO_ISOLATE) return 3;
  if (el.sv[P.P_BACKDROP_FILTER] >= 0) return 4;
  if (el.sv[P.P_OPACITY] < 1) return 5;
  return 0;
}

/**
 * A layer's filters as the host reads them: the blend mode, then each list — the `filter` chain and
 * the `backdrop-filter` chain — as its function count and six numbers per function: the kind, the
 * function's value, drop-shadow's offsets and blur, and the colour, with currentColor resolved
 * against the element.
 */
function filterSpec(el: Node, ops: FilterOp[], backdrop: FilterOp[], reuseBackdrop: boolean = false): string {
  // The layer's alpha comes first: it multiplies the whole group once it composites, after any
  // filter has run on its contents (see the host's replay_effect).
  const parts: string[] = [String(el.sv[P.P_OPACITY]), String(el.sv[P.P_MIX_BLEND_MODE])];
  for (const list of [ops, backdrop]) {
    // A negative backdrop count tells the host the pixels behind the box are unchanged: the
    // filtered result it kept for the box still stands (see the host's apply_backdrop).
    parts.push(String(list === backdrop && reuseBackdrop ? -backdrop.length : list.length));
    for (const op of list) {
      parts.push(String(op.kind), String(op.a), String(op.dx), String(op.dy), String(op.blur),
        String(op.color < 0 ? el.sv[P.P_COLOR] : op.color));
    }
  }
  return parts.join(" ");
}

/**
 * A box that is a stacking context without being positioned: `opacity` below 1 or a transform
 * paints its subtree as one unit, in the same layer as positioned boxes with z-index 0 (CSS 2.1
 * Appendix E, steps 6 and 7; CSS Color 3 §3.2 puts an opacity group there). A filter, a blend mode
 * or `isolation: isolate` joins them when the effects layer lands.
 */
function paintsOwnContext(el: Node): boolean {
  // A box with a hidden backface is a stacking context too (CSS Transforms 2 §3.2): its subtree
  // is one unit, since the whole plane may vanish when it turns away.
  return hasTransform(el) || el.sv[P.P_OPACITY] < 1 || el.sv[P.P_PERSPECTIVE] >= 0 ||
    el.sv[P.P_BACKFACE_VISIBILITY] === P.BFV_HIDDEN;
}

/**
 * A box that paints in its context's z-index: 0 layer rather than in tree order: the unpositioned
 * box that is a stacking context of its own, floats included. A plain inline box keeps the line's
 * pass, since its fragments paint with the text around them.
 */
function deferredContext(el: Node): boolean {
  return paintsOwnContext(el) && !isPositioned(el) && !isPlainInline(el) && !paintsInFlow(el);
}

/** A non-replaced `display: inline` box, whose fragments paint with the text they sit in. */
function isPlainInline(el: Node): boolean {
  return display(el) === P.D_INLINE && !isReplaced(el);
}

/** True when a box is painted by its context's positioned layer instead of by its parent. */
function paintedByContext(el: Node): boolean {
  return (isStackingItem(el) && !paintsInFlow(el)) || deferredContext(el);
}

/** A box whose subtree is painted as one unit of its own, positioned or not. */
function paintsItsOwnLayer(el: Node): boolean {
  return createsContext(el) || paintsOwnContext(el);
}

/** Whether a table part, or a part inside it, takes a share of a collapsing table's grid. */
function takesGrid(el: Node): boolean {
  for (const w of el.bw) if (w !== 0) return true;
  for (const c of boxKids(el)) if (takesGrid(c)) return true;
  return false;
}

/**
 * A part of a collapsing table that is positioned still paints with the table's in-flow content
 * when it takes a share of the border grid: the table draws that grid after the cells, so lifting
 * the part into the positioned layer would leave the borders beneath its contents. A part whose
 * collapsed borders are all zero, and whose cells have none either — a row or row group of a
 * borderless table, or a cell in one — has no grid of its own to keep above, and paints like any
 * other positioned box.
 */
function paintsInFlow(el: Node): boolean {
  // A collapsing table paints its grid in its own layer, as any positioned box does.
  if (el.tborder.length > 0) return false;
  return takesGrid(el);
}

/** A box's z-index, which only a positioned box or a flex item takes part in. */
function zIndexOf(el: Node): number {
  if (!isStackingItem(el) || el.su[P.P_Z_INDEX] === P.U_AUTO) return 0;
  return el.sv[P.P_Z_INDEX];
}

/** One layer of the page the dev inspector lists: a box that paints its subtree as a unit. */
export interface PaintLayer {
  node: Node;
  /** How many layers enclose it; the root context is 0. */
  depth: number;
  /** What makes the box a layer: a z-index, a transform, opacity, a filter, a clip or a mask. */
  reason: string;
  zIndex: number;
}

/** The compositable properties `will-change` asks a layer for, as the inspector names them. */
function willChangeReason(el: Node): string {
  const row = willChangeRows.row(el.sv[P.P_WILL_CHANGE]);
  if (row === null) return "";
  const names: string[] = [];
  for (const prop of row) {
    const name = prop === P.P_TRANSFORM || prop === P.P_TRANSLATE || prop === P.P_ROTATE || prop === P.P_SCALE
      ? "transform"
      : prop === P.P_OPACITY ? "opacity" : prop === P.P_FILTER ? "filter" : "";
    if (name !== "" && names.indexOf(name) < 0) names.push(name);
  }
  return names.length === 0 ? "" : "will-change: " + names.join(", ");
}

/** What gives a box a layer of its own, for a person reading the inspector. */
function layerReason(el: Node): string {
  const reasons: string[] = [];
  const asked = willChangeReason(el);
  if (asked !== "") reasons.push(asked);
  if (isStackingItem(el) && el.su[P.P_Z_INDEX] !== P.U_AUTO) reasons.push("z-index");
  if (hasTransform(el)) reasons.push("transform");
  if (el.sv[P.P_OPACITY] < 1) reasons.push("opacity");
  if (el.sv[P.P_PERSPECTIVE] >= 0) reasons.push("perspective");
  if (el.sv[P.P_BACKFACE_VISIBILITY] === P.BFV_HIDDEN) reasons.push("backface-visibility");
  const effect = effectKind(el);
  if (effect === 1) reasons.push("filter");
  else if (effect === 2) reasons.push("mix-blend-mode");
  else if (effect === 3) reasons.push("isolation");
  else if (effect === 4) reasons.push("backdrop-filter");
  if (hasClipPath(el)) reasons.push("clip-path");
  if (hasMask(el)) reasons.push("mask");
  return reasons.length === 0 ? "layer" : reasons.join(", ");
}

/**
 * The page's layers, in paint order: each box whose subtree the renderer draws as one unit, with
 * the reason CSS gave it one. The dev inspector's layer panel reads this; a box without a layer of
 * its own paints in its parent's.
 */
export function paintLayers(root: Node): PaintLayer[] {
  const layers: PaintLayer[] = [{ node: root, depth: 0, reason: "root", zIndex: 0 }];
  const walk = (el: Node, depth: number): void => {
    for (const c of childOrder(el)) {
      if (c.sv[P.P_DISPLAY] === P.D_NONE) continue;
      const own = paintsItsOwnLayer(c) || willChangeReason(c) !== "";
      if (own) layers.push({ node: c, depth, reason: layerReason(c), zIndex: zIndexOf(c) });
      walk(c, own ? depth + 1 : depth);
    }
  };
  walk(root, 1);
  return layers;
}

/** A box the dev inspector highlights, drawn over the page; null when nothing is selected. */
export const devHighlight: { box: { x: number; y: number; w: number; h: number } | null } = { box: null };

function paintDevHighlight(): void {
  const box = devHighlight.box;
  if (box === null) return;
  const x = box.x;
  const y = box.y;
  const w = box.w;
  const h = box.h;
  hostFillRect(x, y, w, h, 0, 0x1e88e533);
  hostFillRect(x, y, w, 1, 0, 0x1e88e5ff);
  hostFillRect(x, y + h - 1, w, 1, 0, 0x1e88e5ff);
  hostFillRect(x, y, 1, h, 0, 0x1e88e5ff);
  hostFillRect(x + w - 1, y, 1, h, 0, 0x1e88e5ff);
}

/**
 * The positioned boxes of a stacking context, in tree order: those of its in-flow subtree that
 * belong to it. A positioned box with a z-index starts a context of its own, so its own
 * positioned descendants are collected by that context instead.
 */
function collectPositioned(node: Node, list: Node[], damageLimited: boolean = true): void {
  for (const c of childOrder(node)) {
    if (c.sv[P.P_DISPLAY] === P.D_NONE) continue;
    // Nothing in a box whose recorded ink misses the damage can paint in it, positioned boxes
    // included: skip the whole subtree here as the paint walk does. A hit test collects the whole
    // layer, since a box the last limited paint left alone is still under the pointer.
    if (damageLimited && damage.limited && !onDamagePath(c) && !lastInkHitsDamage(c)) continue;
    if (paintedByContext(c)) {
      list.push(c);
      // A box that paints its own layer paints its positioned descendants itself.
      if (!paintsItsOwnLayer(c)) collectPositioned(c, list, damageLimited);
      continue;
    }
    collectPositioned(c, list, damageLimited);
  }
}

/**
 * A container's children in painting order: flex and grid items paint in order-modified document
 * order, the same order they are laid out in. An out-of-flow child is not an item, so `order`
 * leaves it where it is in the tree.
 */
function childOrder(el: Node): Node[] {
  // A `display: contents` child has no box: its own children paint in its place.
  const kids = el instanceof Element ? flattenContents(boxKids(el)) : boxKids(el);
  if (!isFlexContainer(el) && !isGridContainer(el) && !isLanesContainer(el)) return kids;
  let sorted = false;
  for (const c of kids) if (!isOutOfFlow(c) && c.sv[P.P_ORDER] !== 0) sorted = true;
  if (!sorted) return kids;
  const flow: number[] = [];
  for (let i = 0; i < kids.length; i++) if (!isOutOfFlow(kids[i])) flow.push(i);
  flow.sort((a, b) => {
    const d = kids[a].sv[P.P_ORDER] - kids[b].sv[P.P_ORDER];
    return d !== 0 ? d : a - b;
  });
  const out: Node[] = [];
  let k = 0;
  for (const c of kids) out.push(isOutOfFlow(c) ? c : kids[flow[k++]]);
  return out;
}

/**
 * The clips that apply to a box painted on its own, in viewport coordinates. Every ancestor that
 * clips does so, whether the box is static, relative or sticky. An absolutely positioned box may
 * leave the box of any ancestor between it and its containing block, so those clip nothing; the
 * containing block and everything above it still do. A fixed box's containing block is the
 * viewport, outside the tree, so no ancestor clips it.
 */
/** How far a clip that covers one axis only reaches along the other. */
const UNCLIPPED = 1e7;

/**
 * The box a clip starts from and the margin `overflow-clip-margin` grows it by (see
 * layout/box-model.ts): [left, top, width, height, margin] in page coordinates, `x`/`y` being the
 * border box's origin. A replaced box clips to its content box, where its image lives, unless
 * the property names another box. The named box counts only while an axis clips with `clip`.
 */
function clipFrame(el: Node, x: number, y: number, contentBase: boolean): number[] {
  const bl = borderLeft(el);
  const bt = borderTop(el);
  const m = clipMargin(el);
  const named = el.sv[P.P_OVERFLOW_X] === P.OV_CLIP || el.sv[P.P_OVERFLOW_Y] === P.OV_CLIP
    ? m[0] : P.OCM_PADDING_BOX;
  let left = x + bl;
  let top = y + bt;
  let w = el.w - bl - borderRight(el);
  let h = el.h - bt - borderBottom(el);
  if (named === P.OCM_CONTENT_BOX || (contentBase && named === P.OCM_PADDING_BOX)) {
    left = x + el.contentX;
    top = y + el.contentY;
    w = el.contentW;
    h = el.contentH;
  } else if (named === P.OCM_BORDER_BOX) {
    left = x;
    top = y;
    w = el.w;
    h = el.h;
  }
  return [left, top, w, h, m[1]];
}

/** The margin a clip grows by along one axis: only `overflow: clip` takes one. */
function clipGrowth(el: Node, axis: number): number {
  return el.sv[axis] === P.OV_CLIP ? clipMargin(el)[1] : 0;
}

function clipChain(el: Node): number[][] {
  const out: number[][] = [];
  const pos = el.sv[P.P_POSITION];
  const outOfFlow = pos === P.POS_ABSOLUTE || pos === P.POS_FIXED;
  const cb = outOfFlow ? containingBlock(el) : null;
  // An out-of-flow box is clipped from its containing block up; an in-flow one from its parent up.
  let inside = !outOfFlow;
  let a = el.parentElement;
  while (a !== null) {
    if (a === cb) inside = true;
    const cx = inside && clipsX(a) && !propagatesBodyOverflow(a);
    const cy = inside && clipsY(a) && !propagatesBodyOverflow(a);
    if (cx || cy) {
      const p = absolutePosition(a);
      const f = clipFrame(a, p[0], p[1], isReplaced(a));
      const gx = clipGrowth(a, P.P_OVERFLOW_X);
      const gy = clipGrowth(a, P.P_OVERFLOW_Y);
      // A box may clip one axis only (overflow-x: clip with overflow-y: visible), so the other
      // axis stays unbounded.
      out.push([cx ? f[0] - gx : -UNCLIPPED, cy ? f[1] - gy : -UNCLIPPED,
        cx ? f[2] + 2 * gx : 2 * UNCLIPPED, cy ? f[3] + 2 * gy : 2 * UNCLIPPED]);
    }
    a = a.parentElement;
  }
  // `clip` on an ancestor clips everything that ancestor paints, a fixed descendant included:
  // unlike a transform or a clip-path it is no containing block, so a fixed box under one still
  // paints in the viewport, outside the overflow chain above.
  for (let c = el.parentElement; c !== null; c = c.parentElement) {
    if (c.su[P.P_CLIP] !== P.U_LIST) continue;
    const p = absolutePosition(c);
    const r = clipRect(c, p[0], p[1], c.w, c.h);
    if (r !== null) out.push(r);
  }
  out.reverse();
  return out;
}

function insideAny(rects: number[][], px: number, py: number): boolean {
  for (const r of rects) {
    if (px < r[0] || px >= r[0] + r[2] || py < r[1] || py >= r[1] + r[3]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Collapsing tables and their inline content

// A collapsing table paints its border grid above the backgrounds of its cells but below the
// inline content that overflows them: CSS paints collapsed borders in the background phase, yet
// after the block backgrounds they meet. Inline-level boxes inside such a table are therefore held
// back, with the position they would have been painted at, until the table has drawn its grid.

const heldBoxes: Node[] = [];
const heldX: number[] = [];
const heldY: number[] = [];
const heldOpacity: number[] = [];
/** How many collapsing tables the painter is inside; inline boxes wait while this is above zero. */
let holdDepth = 0;

function isInlineLevelBox(el: Node): boolean {
  const d = display(el);
  return d === P.D_INLINE || d === P.D_INLINE_BLOCK || d === P.D_INLINE_FLEX || d === P.D_INLINE_TABLE ||
    d === P.D_INLINE_GRID || d === P.D_INLINE_GRID_LANES;
}

/** Holds an inline-level box back until the collapsing table around it has painted its grid. */
function holdBox(el: Node, x: number, y: number, opacity: number): void {
  heldBoxes.push(el);
  heldX.push(x);
  heldY.push(y);
  heldOpacity.push(opacity);
}

/** Paints the boxes a collapsing table held back, under the clips their ancestors impose. */
function paintHeld(from: number): void {
  const to = heldBoxes.length;
  for (let i = from; i < to; i++) {
    const holder = heldBoxes[i];
    const clips = clipChain(holder);
    // The clips were recorded before the scroll transforms now open moved the content: pushing
    // their page-space rectangles under this CTM would put them where the scroll has not reached,
    // so the boxes they hold could be cut away. Shift them into the current painting space.
    for (const r of clips) hostClipPush(holder.serial, P.PK_CLIP_RECT, r[0] + openScrollX, r[1] + openScrollY, r[2], r[3], 0);
    paintBox(holder, heldX[i], heldY[i], heldOpacity[i], false, null, 1);
    for (let k = 0; k < clips.length; k++) hostClipPop();
  }
  heldBoxes.length = from;
  heldX.length = from;
  heldY.length = from;
  heldOpacity.length = from;
}

/**
 * A box's scrollbar waits until the box's own part of the stacking context around it is painted,
 * so that the bar sits above the box's content: a sticky header or a positioned row never covers
 * it. A positioned box outside the bar's box is painted later and does cover it, as it does in a
 * browser. Boxes record theirs here with the position they were painted at (see flushBar).
 */
interface PendingBar {
  el: Element;
  x: number;
  y: number;
  opacity: number;
}

const pendingBars: PendingBar[] = [];

/** Paints the scrollbar recorded at `i`, under the clips its ancestors impose. */
function flushBar(i: number): void {
  const b = pendingBars[i];
  const el = b.el;
  const x = b.x;
  const y = b.y;
  const bl = borderLeft(el);
  const bt = borderTop(el);
  const br = borderRight(el);
  const bb = borderBottom(el);
  const clips = clipChain(el);
  for (const r of clips) hostClipPush(el.serial, P.PK_CLIP_RECT, r[0], r[1], r[2], r[3], 0);
  hostClipPush(el.serial, P.PK_CLIP_RECT, x + bl, y + bt, el.w - bl - br, el.h - bt - bb, 0);
  paintScrollbar(el, x, y, b.opacity);
  hostClipPop();
  for (let k = 0; k < clips.length; k++) hostClipPop();
  pendingBars.splice(i, 1);
}

/** Paints the scrollbars recorded since `from`, in the order their boxes were painted. */
function flushScrollbars(from: number): void {
  while (pendingBars.length > from) flushBar(from);
}

/** Whether `node` is inside `holder`'s subtree. */
function isInside(node: Node, holder: Node): boolean {
  for (let p: Node | null = node.parentElement; p !== null; p = p.parentElement) {
    if (p === holder) return true;
  }
  return false;
}

/**
 * Flushes the bars at or after `from` that have no positioned box left to cover: a bar waits for
 * the positioned boxes in its own subtree, which are painted among `above` from `next` on, and for
 * nothing else.
 */
function flushBarsReady(from: number, above: Node[], next: number): void {
  let i = from;
  while (i < pendingBars.length) {
    const holder = pendingBars[i].el;
    let waits = false;
    for (let j = next; j < above.length; j++) {
      if (isInside(above[j], holder)) { waits = true; break; }
    }
    if (waits) i++;
    else flushBar(i);
  }
}

/** Paints a box's own background: the colour, then the images painted over it. */
function paintBoxBackground(el: Node, x: number, y: number, w: number, h: number, radii: Radii,
  opacity: number, skipBg: boolean): void {
  const bg = el.sv[P.P_BACKGROUND_COLOR];
  if (!skipBg && alpha(bg) > 0) {
    // The colour is clipped to the last layer's painting area, which is the border box by default.
    const cr = backgroundClipBox(el, x, y, w, h);
    const rr = backgroundClipRadii(el, radii);
    // A colour that scrolls with its element's contents fills a strip that reaches past the
    // padding box's curve: the scrollport's rounded shape clips it, rather than the strip taking
    // the curve as its own at the wrong corners.
    if (rounded(rr) && el instanceof Element && scrollsWithContents(el)) {
      const pad = boxRect(el, x, y, w, h, P.BX_PADDING);
      hostClipPush(el.serial, P.PK_CLIP_RECT, cr[0], cr[1], cr[2], cr[3], 0);
      fillRoundRect(pad[0], pad[1], pad[2], pad[3], rr, withOpacity(bg, opacity));
      hostClipPop();
    } else {
      fillRoundRect(cr[0], cr[1], cr[2], cr[3], rr, withOpacity(bg, opacity));
    }
  }
  // Images are the ones the element itself paints; a propagated one is painted on the canvas.
  paintBackgroundImages(el, x, y, w, h, radii, opacity);
}

/**
 * Paints a box that a column break cut through, once for each column it reaches. The piece that
 * holds the box's top edge draws the top border and keeps the top corners, the piece that holds
 * its bottom edge does the same for the bottom, and the background covers every piece, as
 * box-decoration-break: slice draws the box.
 */
function paintFragmentBoxes(el: Node, frags: number[], x: number, boxY: number, opacity: number,
  skipBg: boolean): void {
  const image = el.bw.length === 0 && hasBorderImage(el);
  const borders = el.bw.length === 0 && hasBorder(el);
  for (let i = 0; i + 5 < frags.length; i += 6) {
    const fx = x + frags[i];
    const fy = boxY + frags[i + 1];
    const fw = frags[i + 2];
    const fh = frags[i + 3];
    const first = frags[i + 4] !== 0;
    const last = frags[i + 5] !== 0;
    const r = borderRadii(el, fw, fh);
    if (!first) r[0] = r[1] = r[2] = r[3] = 0;
    if (!last) r[4] = r[5] = r[6] = r[7] = 0;
    paintBoxBackground(el, fx, fy, fw, fh, r, opacity, skipBg);
    // A border image is cut in the inline axis only, so a piece of a split box draws the whole
    // image scaled into the piece.
    if (image) paintBorderImage(el, fx, fy, fw, fh, opacity, true, true);
    else if (borders) paintBorder(el, fx, fy, fw, fh, r, opacity, first, last, true);
  }
}

/**
 * Inline content held back until its formatting context's floats are painted: CSS 2.1 Appendix E
 * paints every in-flow block's background first (step 4), then the floats (step 5), then the
 * inline content (step 6). A box whose content has no clip of its own can wait; one that clips is
 * painted where it stands, since its clip ends when its own painting does. Content waiting inside
 * a box that does clip carries those clips with it (`clips`): that box pops them before the
 * formatting context that flushes this goes down, and content painted without them would show
 * outside the box it belongs to.
 */
interface TextJob { run: () => void; clips: number[][]; sx: number; sy: number }
let textJobs: TextJob[] = [];
/** How many context boxes are holding their inline content back for their floats. */
let deferDepth = 0;
/**
 * The clips pushed around content, as [serial, x, y, w, h, r0…r7]: the ones a held-back job has
 * to put back while it paints (see `TextJob`).
 */
const paintedClips: number[][] = [];
/**
 * The scroll offset open at each content clip, in the same order: a clip's rectangle is in the
 * space its push stood in, while the boxes painted under it are in a space the scroll transforms
 * opened since then have moved. Culling puts a box into the clip's space with these.
 */
const clipScrollX: number[] = [];
const clipScrollY: number[] = [];
/** The scroll offsets the scroll transforms still open have moved the content by, in total. */
let openScrollX = 0;
let openScrollY = 0;
/** How deep `paintedClips` stood when the innermost formatting context took its hold. */
let heldClipMark = 0;
/** How many positioned boxes are painting: their layer holds its own content, so nothing waits. */
let positionedDepth = 0;
/** While the held-back content is going down, anything it paints is painted where it stands. */
let flushingText = false;

/** Pushes the clip around a box's content and keeps it, for content held back inside it. */
function pushContentClip(serial: number, x: number, y: number, w: number, h: number, r: Radii): void {
  clipRound(serial, x, y, w, h, r);
  paintedClips.push([serial, x, y, w, h, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]]);
  clipScrollX.push(openScrollX);
  clipScrollY.push(openScrollY);
}

/** Takes back the content clip a box's paint pushed. */
function popContentClip(): void {
  hostClipPop();
  paintedClips.pop();
  clipScrollX.pop();
  clipScrollY.pop();
}

/**
 * How far the space a box is painted in has moved from the space the innermost clip is in: the
 * scroll transforms opened since the clip was pushed. A rectangle in painting space is put into
 * clip space by adding this.
 */
function clipShiftX(): number {
  return (clipScrollX.length > 0 ? clipScrollX[clipScrollX.length - 1] : 0) - openScrollX;
}
function clipShiftY(): number {
  return (clipScrollY.length > 0 ? clipScrollY[clipScrollY.length - 1] : 0) - openScrollY;
}

/** Whether a rectangle painted at (x, y) can reach the active clip, given the scrolls open now. */
function inClip(x: number, y: number, w: number, h: number): boolean {
  return reachesClip(x + clipShiftX(), y + clipShiftY(), w, h, activeClip());
}

/** Paints the content held back since `mark`, in the order it was laid out. */
function flushTextJobs(mark: number): void {
  const outer = flushingText;
  flushingText = true;
  for (let i = mark; i < textJobs.length; i++) {
    const job = textJobs[i];
    // The clips the content stood inside go back on while it paints, in the order they were
    // pushed, and come off again before the next job.
    for (const c of job.clips) {
      clipRound(c[0], c[1], c[2], c[3], c[4], [c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12]]);
    }
    // The content was laid out inside the scroll containers that were open when it was held
    // back. Their transforms may have closed since, so one that has goes back around the job.
    const mx = job.sx - openScrollX, my = job.sy - openScrollY;
    const serial = job.clips.length > 0 ? job.clips[0][0] : 0;
    if (mx !== 0 || my !== 0) hostTransformPush(serial, P.PK_TRANSFORM, 1, 0, 0, 1, -mx, -my);
    job.run();
    if (mx !== 0 || my !== 0) hostStatePop();
    for (let k = 0; k < job.clips.length; k++) hostClipPop();
  }
  flushingText = outer;
  textJobs.length = mark;
}

/**
 * The box's inline content: its own text, the column rules and the fragments its inline boxes
 * made, all drawn through the quarter turn a vertical box paints in. Held back until the
 * context's floats are painted when the box doesn't clip, it paints as it stands otherwise.
 */
function paintInlineContent(el: Node, x: number, y: number, opacity: number, scrollX: number, scrollY: number): void {
  // A box that laid its content out along a vertical inline axis painted its background and
  // border above; its content is in that axis's coordinates, so it is drawn through a quarter
  // turn: the line runs down the page and the lines stack across it, right to left for
  // vertical-rl (and sideways-rl), left to right for the -lr modes.
  const vturn = el.vtext !== 0;
  const vmode = usedWritingMode(el);
  const vlr = vmode === P.WM_VERTICAL_LR || vmode === P.WM_SIDEWAYS_LR;
  if (vturn) {
    const cx = x + el.contentX;
    const cy = y + el.contentY;
    // The same clockwise turn for every vertical mode: a line's text runs down the page and each
    // glyph's own top faces right, as browsers draw Latin in vertical text. What the modes differ
    // in is where the stack starts, which is the translation: the right edge for -rl, the left
    // edge for -lr, whose lines then step up the page's block coordinate (see the line loop).
    hostTransformPush(el.serial, P.PK_TRANSFORM, 0, 1, -1, 0, vlr ? cx : cx + el.contentW, cy);
  }

  // A zero font size draws no glyph; see the fragment loop above for why.
  if (el.lines.length > 0 && el.sv[P.P_FONT_SIZE] > 0) {
    const lh = lineHeightPx(el);
    // The box's own text scrolls with its content, like its fragments and children do. In a
    // vertical box the text's own space is the content box's, with the inline axis down the page.
    const left = vturn ? 0 : x - scrollX + el.contentX;
    const innerW = vturn ? el.contentH : el.contentW;
    // The quarter turn maps a line box a whole line's height to the left of its block
    // coordinate, so a vertical-lr box starts its first line one height below the content's
    // top to put it against the left edge.
    let ty = vturn ? (vlr ? -lh : 0) : y - scrollY + el.contentY;
    // Buttons center their content vertically, as browsers do.
    if (el.tagName === "BUTTON") ty += Math.max(0, (el.contentH - el.lines.length * lh) / 2);
    const align = lineAlign(el);
    const alignLast = lastLineAlign(el);
    const rtl = isRtl(el);
    const color = withOpacity(el.sv[P.P_COLOR], opacity);
    // ::first-line and ::first-letter paint their own colour, background and, for the letter,
    // its own glyph. Their boxes are carriers only; layout still uses the element's own font.
    const firstLine = el instanceof Element ? el.firstLinePseudo : null;
    const firstLetter = el instanceof Element && el.firstLetterFloat === null ? el.firstLetterPseudo : null;
    // A focused textarea paints its selection under the glyphs and its caret over them, on the
    // node that holds its lines — the field itself, or the text child its value made.
    const editing = el instanceof HTMLTextAreaElement && focusState.el === el ? el : null;
    const lineStarts = editing !== null ? textAreaLineStarts(editing) : [];
    // Where each line starts in the box's text, counted once rather than from the start of the
    // block for every line.
    const textStart: number[] = [];
    let textCount = 0;
    for (let i = 0; i < el.lines.length; i++) {
      textStart.push(textCount);
      textCount += el.lines[i].length;
    }
    for (let i = 0; i < el.lines.length; i++) {
      // The first line's indent shifts it and narrows the room it aligns in. An rtl line takes
      // the indent off its start edge, the right one, so the line stays put and only shrinks.
      const first = i === 0;
      const ind = first ? el.textIndent : 0;
      const availW = innerW - ind;
      const base = rtl ? left : left + ind;
      // A line the clip cannot see draws nothing, whatever its heap of text says: a long block
      // otherwise shapes and hands every one of its lines to the host on every paint. The line's
      // own height is the ::first-line font's on the first line, which may be taller.
      const cullH = first && firstLine !== null && el.firstLineStyle !== null ? lineHeightPx(firstLine) : lh;
      if (!vturn && cullingOn() && !inClip(left, ty, innerW, cullH)) {
        ty += cullH;
        continue;
      }
      // A line the text wraps, or a forced break ends, hangs the separators at its end past the
      // edge, so they take no room in the centring or the end alignment. The line the text's own
      // end finishes has no such edge: its trailing separator is part of the box.
      const hangsHere = i < el.lines.length - 1 || el.lineForced[i] === 1;
      const trail = hangsHere ? trailingSeparators(el.lines[i]) : 0;
      const trailW = trail > 0 ? textWidth(el, el.lines[i].slice(el.lines[i].length - trail)) : 0;
      const lineW = el.lineWidths[i] - trailW;
      let tx = base;
      if (align === P.T_CENTER) tx = base + (availW - lineW) / 2;
      else if (align === P.T_RIGHT) tx = base + availW - lineW;
      // `text-align-last` takes the last line of the block and the lines a forced break ended.
      // With no `text-align-last` of its own, a justified block's last line starts where its
      // text does.
      const lastLine = i === el.lines.length - 1 || el.lineForced[i] === 1;
      const lineAlignNow = alignLast >= 0 && lastLine ? alignLast
        : lastLine && align === P.T_JUSTIFY ? (rtl ? P.T_RIGHT : P.T_LEFT) : align;
      if (lineAlignNow === P.T_CENTER) tx = base + (availW - lineW) / 2;
      else if (lineAlignNow === P.T_RIGHT) tx = base + availW - lineW;
      const lineColor = first && firstLine !== null ? withOpacity(firstLine.sv[P.P_COLOR], opacity) : color;
      // A ::first-line whose rule changed the metrics laid the line out in its own font, so the
      // line paints in it, and its line box is the height that font asks for.
      const styledLine = first && firstLine !== null && el.firstLineStyle !== null;
      const lineLH = styledLine ? lineHeightPx(firstLine) : lh;
      const linePaint = styledLine ? firstLine : el;
      // ::first-line's background goes under the highlight, which the selection paints over it.
      if (first && firstLine !== null) {
        const bg = firstLine.sv[P.P_BACKGROUND_COLOR];
        if ((bg & 255) !== 0) hostFillRect(tx, ty, el.lineWidths[i], lineLH, 0, withOpacity(bg, opacity));
      }
      const lineEl: Element | null = el instanceof Element ? el : null;
      // A drop cap's letter is drawn in its own box, so the drawn text starts after it in the
      // element's text; the lines map into that text one character further in.
      const letterShift = lineEl !== null && lineEl.firstLetterFloat !== null ? 1 : 0;
      const before = lineEl !== null ? textStart[i] + letterShift : 0;
      const part = lineEl !== null ? lineSelection(lineEl, el.lines[i], before) : null;
      const colors = part === null ? NO_SELECTION_COLORS : selectionColors(el);
      const start = lineEl !== null && highlightCovers.length > 0 ? lineStream(lineEl, el.lines[i], before)[0] : 0;
      paintHighlightBackgrounds(el, linePaint, el.lines[i], tx, ty, lineLH, start);
      if (part !== null) {
        paintSelectionPart(linePaint, el.lines[i], tx, ty, lineLH, part, colors[0] >= 0 ? colors[0] : systemSelectionColor(el));
      }
      let fieldCaret = NaN;
      if (editing !== null) {
        const sel = textAreaSelection(editing, el.lines[i], lineStarts[i], tx);
        if (sel.length === 2) hostFillRect(sel[0], ty, sel[1] - sel[0], lh, 0, withOpacity(systemSelectionColor(el), opacity));
        fieldCaret = textAreaCaretX(editing, el.lines[i], lineStarts[i], i === el.lines.length - 1, tx);
      }
      const extraWord = el.lineExtraWord[i] ?? 0;
      const extraLetter = el.lineExtraLetter[i] ?? 0;
      // A justified line's hanging separators take none of its extra spacing.
      const hang = extraWord !== 0 || extraLetter !== 0 ? trailingSeparators(el.lines[i]) : 0;
      paintTextShadows(linePaint, el.lines[i], tx, ty, lineLH, lineColor, opacity, extraWord, extraLetter);
      paintLineText(linePaint, el.lines[i], tx, ty, lineLH, lineColor, opacity,
        first ? firstLetter : null, part, colors[1], start, extraWord, extraLetter, hang);
      decorate(el, tx, ty + baselineOffset(el), el.lineWidths[i], opacity);
      // The marked text an input method is composing is underlined where it sits on the line.
      if (editing !== null && editing.composeStart >= 0 && editing.composeEnd > editing.composeStart) {
        const lineStart = lineStarts[i];
        const line = el.lines[i];
        const a = Math.max(editing.composeStart, lineStart);
        const b = Math.min(editing.composeEnd, lineStart + line.length);
        if (b > a) {
          const x0 = tx + textWidth(editing, line.slice(0, a - lineStart));
          const x1 = tx + textWidth(editing, line.slice(0, b - lineStart));
          hostFillRect(x0, ty + lh - 1, x1 - x0, 1, 0, withOpacity(editing.sv[P.P_COLOR], opacity));
        }
      }
      if (fieldCaret === fieldCaret && editing !== null) {
        const at = editing.caretEnd - lineStarts[i];
        const line = el.lines[i];
        const ch = at >= 0 && at < line.length ? line.slice(at, at + 1) : "";
        paintCaret(editing, fieldCaret, ty, lh, textWidth(editing, ch), opacity);
      }
      // A vertical-rl box stacks its lines from the right edge leftwards and a vertical-lr box
      // from the left edge rightwards. The quarter turn above maps a line's block coordinate to
      // the width the other way round, so the -lr modes step up the page's y in that space.
      ty += vturn && vlr ? -lineLH : lineLH;
    }
  }

  // Inline content — the box's own text, the fragments its inline boxes made, and the column
  // rules — is in the turned frame's coordinates, so it is drawn through the turn from the
  // content box's corner. Its element children are not: layout mapped them back onto the page,
  // so they are drawn outside the turn, at the page rect they take up, where a background, a
  // border ring and an outline are the ordinary physical ones.
  // Fragments are placed from the border box in the frame's axes, so the turn, which starts at the
  // content box's corner, takes the padding and border off them. The turn maps a block offset
  // towards the page's left, while a -lr frame's block axis runs towards its right, so those
  // modes hand the offset over with the axis flipped.
  const bsign = vturn && vlr ? -1 : 1;
  const dx = vturn ? -el.contentY : x - scrollX;
  const dy = vturn ? (vlr ? el.contentX : -(el.w - el.contentX - el.contentW)) : y - scrollY;
  // A multi-column box draws the rule in each gutter between its columns.
  if (el.colRulesX.length > 0 && el.sv[P.P_COLUMN_RULE_STYLE] !== P.BRS_NONE) {
    const rw = Math.max(0, borderPx(len(el, P.P_COLUMN_RULE_WIDTH, el.contentW)));
    if (rw > 0) {
      const rc = el.sv[P.P_COLUMN_RULE_COLOR] < 0 ? el.sv[P.P_COLOR] : el.sv[P.P_COLUMN_RULE_COLOR];
      const color = withOpacity(rc, opacity);
      for (const ry of el.colRuleYs) {
        for (const rx of el.colRulesX) hostFillRect(dx + rx - rw / 2, dy + ry, rw, el.colRulesH, 0, color);
      }
    }
  }
  paintFragments(el, dx, dy, opacity, bsign);
  if (vturn) hostStatePop();
}

/**
 * Paints the box and its in-flow subtree. Positioned children are left to the stacking context
 * they belong to, which paints them after the in-flow content.
 *
 * Floats are painted in a pass of their own, in tree order, once the in-flow block boxes of the
 * subtree have theirs (CSS 2.1 E.2, steps 5 and 6), so a float covers the background of a block
 * it overlaps. `mode` picks the pass: 0 paints the box and its subtree but not its floats, 1
 * does that and then paints the subtree's floats, and 2 paints only the floats of the subtree.
 */
/**
 * The grip a resizable box shows in its bottom-right corner, the way Chrome draws a textarea's:
 * three short diagonal strokes, in the box's own text colour at half strength.
 */
function paintResizeGrip(el: Element, x: number, y: number, opacity: number): void {
  const right = x + el.w - el.usedBorder(1, P.P_BORDER_RIGHT_WIDTH);
  const bottom = y + el.h - el.usedBorder(2, P.P_BORDER_BOTTOM_WIDTH);
  const color = withOpacity(el.sv[P.P_COLOR], opacity * 0.5);
  for (let line = 0; line < 3; line++) {
    for (let i = 0; i < 4; i++) {
      hostFillRect(Math.round(right - 4 - line * 3 + i), Math.round(bottom - 1 - i), 1, 1, 0, color);
    }
  }
}

/**
 * Whether the box can scroll its content: `overflow: auto` or `scroll`, and `hidden`, which a
 * script still scrolls (though a user's wheel doesn't). A scroll position it holds moves what it
 * paints, so the pass has to carry it wherever the box can have one.
 */
function scrollsContent(el: Element): boolean {
  const ox = el.sv[P.P_OVERFLOW_X], oy = el.sv[P.P_OVERFLOW_Y];
  return (ox !== P.OV_VISIBLE && ox !== P.OV_CLIP) || (oy !== P.OV_VISIBLE && oy !== P.OV_CLIP);
}

function paintBox(el: Node, x: number, y: number, parentOpacity: number, skipBg: boolean,
  below: Node[] | null = null, mode: number = 0, wrapped: boolean = false, groupApplied: boolean = false): void {
  frameTimes.painted++;
  // A top-layer element paints from paintTopLayer instead, after the whole tree.
  if (!paintingTopLayer && isInTopLayer(el)) return;
  // A box turned so its back faces the viewer is not painted when backface-visibility says so,
  // and neither is anything it holds: the whole plane is hidden.
  if (el.sv[P.P_BACKFACE_VISIBILITY] === P.BFV_HIDDEN && isBackFacing(el)) return;
  // A damaged frame paints only what can reach a damaged rectangle: a subtree whose ink misses
  // them all has no pixels to change.
  if (damage.limited && !onDamagePath(el) && !lastInkHitsDamage(el)) return;
  // A transformed box paints, and hit tests, as a stacking context of its own: its positioned
  // descendants belong inside the transform, not in the ancestor's positioned layer. A filtered
  // box paints the same way, into a layer the host filters before it reaches the page, and one
  // that blends or isolates paints through a layer too.
  if (!wrapped) {
    const m = hasTransform(el) ? pageMatrix(el, x, y) : null;
    const effect = effectKind(el);
    const shaped = hasClipPath(el);
    const masked = hasMask(el);
    // A box a perspective ancestor projects paints into a layer warped onto its projected quad;
    // the ordinary affine push stays for everything whose plane divides by w = 1.
    const quad = pageQuad(el, x, y);
    const willChange = willChangeBits(el);
    // A `will-change` of transform asks for a layer before there is a transform to give it: an
    // identity matrix opens the wrapper its commands go inside, ready for the frames that move it.
    const identity = m === null && quad === null && (willChange & LAYER_TRANSFORM) !== 0;
    if (m !== null || quad !== null || identity || effect !== 0 || shaped || masked || willChange !== 0) {
      // A layer holds the box's own content, inside the transform, clip, mask and effect pushes:
      // its raster is untransformed and unfaded, and those stay properties of the parent list.
      // The floats-only pass paints the same content a second time, so it gets no layer of its own.
      const layerBits = (el instanceof Element ? compositableBits(el) : 0) | willChange;
      const layered = layerBits !== 0 && mode !== 2;
      if (quad !== null) {
        hostPerspectivePush(el.serial, P.PK_PERSPECTIVE, x, y, el.w, el.h, quad[0], quad[1], quad[2], quad[3], quad[4], quad[5], quad[6], quad[7]);
      } else if (m !== null) {
        // The command is kept, so a frame that only moves this element's transform edits it
        // instead of painting the page again (see compositor.ts).
        noteTransform(el, hostTransformPushIndexed(el.serial, P.PK_TRANSFORM, m.a, m.b, m.c, m.d, m.e, m.f), x, y,
          [m.a, m.b, m.c, m.d, m.e, m.f]);
      } else if (identity) {
        // A will-change layer's identity transform is the command a later frame moves.
        noteTransform(el, hostTransformPushIndexed(el.serial, P.PK_TRANSFORM, 1, 0, 0, 1, 0, 0), x, y,
          [1, 0, 0, 1, 0, 0]);
      }
      // A layer, a shape and a mask all measure from the border box, in the box's own space,
      // inside the transform: they move with the box.
      const top = el.boxTop;
      const bw = el.w;
      const bh = Math.max(0, el.h - top - el.boxBottom);
      // `clip` cuts what the element paints, filtering included, so its region goes outside the
      // effect layer: the host clips the layer's composite, not the content that feeds it.
      const clipping = pushClipRect(el, x, y + top, bw, bh);
      // The shape is resolved inside the transform, and the layer it clips is cut to the shape
      // once the box has painted into it.
      let clipped = false;
      if (shaped) {
        const bl = borderPx(borderLeft(el));
        const br = borderPx(borderRight(el));
        const bt = borderPx(borderTop(el));
        const bb = borderPx(borderBottom(el));
        clipped = pushClipPath(el,
          [x, y + top, bw, bh],
          [x + bl, y + top + bt, Math.max(0, bw - bl - br), Math.max(0, bh - bt - bb)],
          [x + el.contentX, y + el.contentY, el.contentW, el.contentH]);
      }
      // The mask wraps the filtered layer, so the filter runs on the content and the mask takes
      // the alpha off the result, as CSS Masking orders them.
      const masking = masked && pushMask(el, x, y + top, bw, bh);
      if (effect !== 0) {
        // A floats-only pass paints into a layer of its own, after the box's content has been
        // composited. The backdrop was filtered by the first pass, so filtering it again here
        // would invert (or blur) it twice.
        const backdrop = mode === 2 ? [] : elementBackdropFilter(el);
        const spec = filterSpec(el, elementFilter(el), backdrop, damage.limited && backdropReuses(el));
        // An opacity group alone can fade in place; filters, blend modes and backdrops are part
        // of the recorded spec and need the page painted for a new value.
        if (effect === 5) {
          noteOpacity(el, hostEffectPushIndexed(el.serial, P.PK_EFFECT, x, y + top, bw, bh, spec));
        } else {
          hostEffectPush(el.serial, P.PK_EFFECT, x, y + top, bw, bh, spec);
        }
      }
      if (layered) hostLayerPush(el.serial, (layerBits & LAYER_TRANSFORM) !== 0 ? P.PK_TRANSFORM : P.PK_EFFECT);
      // The floats-only pass stays a floats-only pass: it runs again once the box's own content
      // has been painted, so it must not paint that content a second time.
      if (mode === 2) paintBox(el, x, y, parentOpacity, skipBg, below, 2, true);
      else paintContext(el, x, y, parentOpacity, skipBg, true);
      if (layered) hostLayerPop();
      if (effect !== 0) hostEffectPop();
      if (masking) hostMaskPop();
      if (clipped) hostClipPop();
      if (clipping) hostClipPop();
      if (quad !== null) hostPerspectivePop();
      else if (m !== null || identity) hostStatePop();
      return;
    }
  }
  const own = mode !== 2;
  // A hidden box takes its room in the layout but paints none of itself; a descendant that says
  // `visible` still paints, so the walk below goes on (CSS 2.1 11.2).
  const shown = el.sv[P.P_VISIBILITY] === P.VIS_VISIBLE;
  const draw = own && shown;
  // A transparent group's own alpha is on the layer its effect push opened, so it isn't applied
  // again to each drawing inside it.
  const opacity = groupApplied ? parentOpacity : parentOpacity * el.sv[P.P_OPACITY];
  // The box that paints a context's floats (mode 1) owns the queue of inline content held back
  // for them; anything deferred inside it, however deep, is flushed once its floats are painted.
  // A flex, grid or lanes item paints as a unit of its own, so it holds its content the same way:
  // what it paints belongs to it, not to the formatting context around it.
  const opened = mode > 0 || (own && paintsAsUnit(el));
  if (el.sv[P.P_DISPLAY] === P.D_NONE || opacity <= 0) return;
  const textMark = textJobs.length;
  const outerClipMark = heldClipMark;
  if (opened) {
    deferDepth++;
    // The content this box holds back goes down here, where the clips it stood inside are gone:
    // from this depth on, a job keeps the clips pushed after it (see `TextJob`).
    heldClipMark = paintedClips.length;
  }
  // A collapsing table paints a border grid of its own; see paintHeld.
  const grid = el.tborder.length > 0;
  const holdStart = heldBoxes.length;
  if (grid) holdDepth++;
  const replaced = isReplaced(el);
  if (!replaced && (display(el) === P.D_INLINE || el.isTextNode)) {
    // Drawn through the container's fragments; only atomic descendants paint themselves. An
    // inline box's own opacity reaches those descendants from here, its fragments apart.
    if (el.lines.length === 0) {
      const kids = childOrder(el);
      const sub = parentOpacity * el.sv[P.P_OPACITY];
      if (own) {
        for (const c of kids) {
          if (paintedByContext(c) || isFloat(c)) continue;
          paintBox(c, x + el.x + c.x, y + el.y + c.y, sub, false, null, 0);
        }
      }
      if (opened) paintFloats(kids, x + el.x, y + el.y, sub);
      if (opened) {
        deferDepth--;
        flushTextJobs(textMark);
        heldClipMark = outerClipMark;
      }
      return;
    }
  }
  const radii = borderRadii(el, el.w, el.h);
  // A box the fill cut through draws once per column it reaches (see layout/fragment.ts).
  const frags = el.fragBoxes;

  // A table's captions take the top and bottom of the element's box; its background and border
  // cover only the table's own border box in between.
  const boxY = y + el.boxTop;
  const boxH = Math.max(0, el.h - el.boxTop - el.boxBottom);
  // A row with no cells, or a row group with no rows, generates no box at all; and
  // `empty-cells: hide` leaves an empty cell's background and border unpainted.
  // A cell in a collapsed row or column is clipped away with everything it holds.
  const voidPart = isVoidTablePart(el) || isEmptyCell(el) || el.collapsedTrack;
  // `clip: rect()` clips an absolutely positioned box, everything it paints included. A box that
  // paints through a wrapper already pushed it there, outside its layer, so it is not pushed here.
  const clippedToRect = !wrapped && pushClipRect(el, x, boxY, el.w, boxH);
  const canvasNode = el === canvasEl;
  // The padding box inside the drawn borders: where an inset shadow lives. A collapsing cell's
  // borders are the grid lines outside it, and it keeps only its share of them (see `borderLeft`).
  const bl = borderPx(borderLeft(el));
  const br = borderPx(borderRight(el));
  const bt = borderPx(borderTop(el));
  const bb = borderPx(borderBottom(el));
  const padR = insetRadii(radii, bl, bt, br, bb);
  const padX = x + bl, padY = boxY + bt, padW = el.w - bl - br, padH = boxH - bt - bb;
  // An outer shadow sits behind the background.
  // Shadows never propagate to the canvas, so the body's are painted on its own box even when
  // it is the element whose background became the canvas's.
  if (draw && !voidPart && frags.length === 0) paintShadows(el, false, x, boxY, el.w, boxH, radii, padX, padY, padW, padH, padR, opacity);
  // A row, row group or column's background shows only in its cells' areas: the border spacing
  // between them belongs to the table, so the background is painted once per segment and clipped
  // to it (see layout/table.ts). Anything else paints across its whole box. A table part's
  // background box can differ from its own box: a row group's starts at its first row.
  if (draw && !canvasNode && !voidPart && frags.length > 0) {
    paintFragmentBoxes(el, frags, x, boxY, opacity, skipBg);
  } else if (draw && !canvasNode && !voidPart) {
    const bb = el.bgbox;
    let bgX = bb.length >= 4 ? x + bb[0] : x;
    let bgY = bb.length >= 4 ? boxY + bb[1] : boxY;
    let bgW = bb.length >= 4 ? bb[2] : el.w;
    let bgH = bb.length >= 4 ? bb[3] : boxH;
    // In a collapsing table a cell's borders are its shares of the grid lines between cells,
    // not borders of its own: its background stops at its padding edge, so it never shows in a
    // neighbour's border space (CSS 2.1 17.6.2).
    if (bb.length < 4 && display(el) === P.D_TABLE_CELL && el.sv[P.P_BORDER_COLLAPSE] === P.BC_COLLAPSE) {
      bgX += bl;
      bgY += bt;
      bgW = Math.max(0, bgW - bl - br);
      bgH = Math.max(0, bgH - bt - borderPx(borderBottom(el)));
    }
    if (el.bgseg.length === 0) {
      paintBoxBackground(el, bgX, bgY, bgW, bgH, radii, opacity, skipBg);
    } else {
      for (let i = 0; i + 3 < el.bgseg.length; i += 4) {
        const sx = x + el.bgseg[i];
        const sy = boxY + el.bgseg[i + 1];
        const sw = el.bgseg[i + 2];
        const sh = el.bgseg[i + 3];
        hostClipPush(el.serial, P.PK_CLIP_RECT, sx, sy, sw, sh, 0);
        // The background shows over the whole area of the cell that reaches the row, while the
        // image is laid out against the row's own box: the colour fills the cell.
        if (!skipBg) {
          const bg = el.sv[P.P_BACKGROUND_COLOR];
          if (alpha(bg) > 0) fillRoundRect(sx, sy, sw, sh, radii, withOpacity(bg, opacity));
        }
        paintBackgroundImages(el, bgX, bgY, bgW, bgH, radii, opacity);
        hostClipPop();
      }
    }
  }
  // An inset shadow sits above the background and below the border.
  if (draw && !voidPart && frags.length === 0) paintShadows(el, true, x, boxY, el.w, boxH, radii, padX, padY, padW, padH, padR, opacity);

  // A box that generates nothing paints no border either. A collapsing table's borders are the
  // grid lines between its cells, which the table itself paints (see the end of this function), so
  // none of its boxes draws a border of its own. A box the fill cut through draws its border in
  // each column (see paintFragmentBoxes).
  if (draw && !voidPart && frags.length === 0 && el.bw.length === 0 && (hasBorder(el) || hasBorderImage(el))) {
    paintBorder(el, x, boxY, el.w, boxH, radii, opacity, true, true);
  }

  // Column backgrounds sit above the table's own background and below its rows and cells: the
  // `<col>` and `<colgroup>` boxes have none of their own (see layout/table.ts). A background is
  // laid out against the column's whole box, but painted only in the cell areas of each row.
  if (draw) {
    const SQUARE: Radii = [0, 0, 0, 0, 0, 0, 0, 0];
    for (const part of el.tcols) {
      const b = part.bgbox;
      if (b.length < 4) continue;
      if (part.bgseg.length === 0) {
        paintBoxBackground(part, x + b[0], boxY + b[1], b[2], b[3], SQUARE, opacity, false);
        continue;
      }
      for (let i = 0; i + 3 < part.bgseg.length; i += 4) {
        const sx = x + b[0] + part.bgseg[i];
        const sy = boxY + b[1] + part.bgseg[i + 1];
        const sw = part.bgseg[i + 2];
        const sh = part.bgseg[i + 3];
        hostClipPush(part.serial, P.PK_CLIP_RECT, sx, sy, sw, sh, 0);
        // A cell that spans the column shows the column's background over its whole area: the
        // colour fills the cell, while the image is still laid out against the column's own box.
        const bg = part.sv[P.P_BACKGROUND_COLOR];
        if (alpha(bg) > 0) fillRoundRect(sx, sy, sw, sh, SQUARE, withOpacity(bg, opacity));
        paintBackgroundImages(part, x + b[0], boxY + b[1], b[2], b[3], SQUARE, opacity);
        hostClipPop();
      }
    }
  }

  // Negative z-index boxes of this stacking context sit above its background, below its content.
  if (own && below !== null) for (const c of below) paintPositioned(c, opacity);

  // Content (the element's own text too) is clipped to its padding box when overflow says so,
  // grown by any overflow-clip-margin and shaped with the rounded corner of the box it names.
  // Body's overflow goes to the viewport instead while the root's is visible, so the body's own
  // box clips nothing: it still scrolls, but the canvas bounds it.
  const propagate = propagatesBodyOverflow(el);
  const clipX = clipsX(el) && !propagate;
  const clipY = clipsY(el) && !propagate;
  const clipped = clipX || clipY;
  if (clipped) {
    // Only `overflow: clip` takes a clip margin, and it takes it on that axis alone; the other
    // axis of a one-axis clip stays unbounded (`overflow-x: clip` with `overflow-y: visible`).
    const gx = clipGrowth(el, P.P_OVERFLOW_X);
    const gy = clipGrowth(el, P.P_OVERFLOW_Y);
    const f = overflowClipBox(el, x, y);
    if (!(clipX && clipY)) {
      pushContentClip(el.serial, clipX ? f[0] - gx : -UNCLIPPED, clipY ? f[1] - gy : -UNCLIPPED,
        clipX ? f[2] + 2 * gx : 2 * UNCLIPPED, clipY ? f[3] + 2 * gy : 2 * UNCLIPPED,
        [0, 0, 0, 0, 0, 0, 0, 0]);
    } else {
      // The clip edge's corners grow with the margin, as an outer shadow's spread would.
      const fr = insetRadii(radii, f[4], f[5], f[6], f[7]);
      pushContentClip(el.serial, f[0] - gx, f[1] - gy, f[2] + 2 * gx, f[3] + 2 * gy,
        gx !== 0 || gy !== 0 ? grownRadii(fr, gx, gy) : fr);
    }
  }
  // The root element is the viewport's scroller: its scroll position moves the whole page,
  // whether or not the page clips its own overflow.
  const scrollY = clipY || el === document.documentElement ? el.scrollY : 0;
  const scrollX = clipX || el === document.documentElement ? el.scrollX : 0;

  if (replaced) {
    // The content is fitted into the content box with object-fit and object-position, above the
    // background and border, and clipped to that box (CSS Images 3 §3.1, which the UA sheet's
    // `overflow: clip` asks for): an object-position that shifts the object, or object-fit:
    // none, draws nothing outside it. An author `overflow: visible` lets it spill instead.
    const spill = !clipsX(el) && !clipsY(el);
    if (draw) {
      if (!spill) hostClipPush(el.serial, P.PK_CLIP_RECT, x + el.contentX, y + el.contentY, el.contentW, el.contentH, 0);
      // object-fit fits the image's default object size into the box, which for an image with
      // only a ratio is the 300 by 150 default, not the zero intrinsic size layout starts from.
      const size = objectSize(el, orientedImage(el));
      const r = contentRect(el, x + el.contentX, y + el.contentY, el.contentW, el.contentH,
        size[0], size[1], el.sv[P.P_FONT_SIZE]);
      const smooth = smoothImage(el);
      if (el instanceof HTMLVideoElement) {
        if (el._videoId >= 0) hostVideoDraw(el._videoId, r[0], r[1], r[2], r[3], opacity);
      } else if (el instanceof HTMLCanvasElement) {
        const id = el.hostBitmapId();
        if (id >= 0) hostCanvasDraw(id, r[0], r[1], r[2], r[3], opacity, smooth);
      } else if (isSvgElement(el)) {
        // An inline <svg> draws its own subtree; its viewport is the content box, so object-fit
        // has nothing to fit.
        paintSvg(el as Element, x + el.contentX, y + el.contentY, el.contentW, el.contentH, opacity);
      } else {
        drawImagePath(el.imagePath, orientedImage(el), r[0], r[1], r[2], r[3], opacity, smooth);
      }
      if (!spill) hostClipPop();
    }
    if (clipped) popContentClip();
    if (clippedToRect) hostClipPop();
    if (draw) paintOutline(el, x, y, opacity);
    return;
  }

  if (draw && el instanceof HTMLInputElement) {
    // A checkbox, a radio, a range and a colour field's swatch are the widgets the UA draws;
    // every other field is a text field.
    if (controlKind(el.type) === CONTROL_NONE) paintInput(el, x, y, opacity);
    else paintControl(el, x, y, opacity);
  }
  if (draw && el instanceof HTMLSelectElement) paintSelectLabel(el, x, y, opacity);

  // Inline content is what Appendix E puts after the floats: held back for them when nothing
  // here clips it, painted where it stands otherwise.
  // A list marker keeps its place among the inline content around it: it is inline content of the
  // item itself, and the boxes after it paint over it, as they do in a browser.
  const holdText = draw && !clipped && !clippedToRect && holdDepth === 0 && deferDepth > 0 &&
    positionedDepth === 0 && !flushingText && el.pseudoKind !== P.PE_MARKER;
  const skipContent = el.sv[P.P_CONTENT_VISIBILITY] === P.CV_HIDDEN;
  // A scroll container paints its content under a transform: a scroll step edits that command
  // and the compositor moves what was rastered, instead of the page being painted again (see
  // compositor.ts). The content is painted in page space, and the transform puts it where the
  // offset says, so the flat replay draws what it always did.
  const scrollsOurs = el instanceof Element &&
    (el === document.documentElement || scrollsContent(el));
  if (scrollsOurs) {
    noteScroll(el, hostTransformPushIndexed(el.serial, P.PK_SCROLL, 1, 0, 0, 1, -scrollX, -scrollY), !paintState.partial);
    scrolledContent.push(el);
    openScrollX += scrollX;
    openScrollY += scrollY;
  }
  if (own && !skipContent) {
    if (holdText) {
      textJobs.push({
        run: () => paintInlineContent(el, x, y, opacity, 0, 0),
        clips: paintedClips.slice(heldClipMark),
        sx: openScrollX, sy: openScrollY,
      });
    } else paintInlineContent(el, x, y, opacity, 0, 0);
  }
  const px = x;
  const py = y;
  // A box whose content is skipped paints nothing of its subtree (see layout/box.ts).
  const kids = el.sv[P.P_CONTENT_VISIBILITY] === P.CV_HIDDEN ? [] : childOrder(el);
  if (own) {
    for (const c of kids) {
      if (paintedByContext(c) || isFloat(c)) continue;
      const cy = py + c.y;
      if (holdDepth > 0 && isInlineLevelBox(c)) holdBox(c, px + c.x, cy, opacity);
      // An inline-level box is inline content too: it keeps its place among the held-back text,
      // so it stays above the earlier text and below the later, as it would without floats. An
      // atomic inline box (an inline-block and the like) roots its own formatting context, though:
      // its background has to go down before the floats inside it, so it paints where it stands.
      else if (holdText && isInlineLevelBox(c) && !isBfcRoot(c)) {
        const cx = px + c.x;
        textJobs.push({
          run: () => paintBox(c, cx, cy, opacity, false, null, 0),
          clips: paintedClips.slice(heldClipMark),
          sx: openScrollX, sy: openScrollY,
        });
      } else {
        // A box that paints only inside itself, and misses the clip, is not painted at all: this
        // is what keeps a full paint proportional to the visible rows rather than to the list.
        const bx = px + c.x;
        if (cullingOn() && paintsInsideBox(c) && !inClip(bx, cy, c.w, c.h)) continue;
        // A caption sits outside the table's border box, so the table's own overflow clip doesn't
        // cut it, though it still cuts everything else the table paints.
        const caption = clipped && display(c) === P.D_TABLE_CAPTION && paintedClips.length > 0;
        const saved = caption ? paintedClips[paintedClips.length - 1] : null;
        if (saved !== null) popContentClip();
        paintBox(c, px + c.x, cy, opacity, false, null, 0);
        if (saved !== null) {
          pushContentClip(saved[0], saved[1], saved[2], saved[3], saved[4],
            [saved[5], saved[6], saved[7], saved[8], saved[9], saved[10], saved[11], saved[12]]);
        }
      }
    }
  }
  if (opened) paintFloats(kids, px, py, opacity);
  // The inline content held back for the floats goes down now, inside this box's own clip.
  if (opened) {
    deferDepth--;
    flushTextJobs(textMark);
    heldClipMark = outerClipMark;
  }
  if (scrollsOurs) {
    hostStatePop();
    scrolledContent.pop();
    openScrollX -= scrollX;
    openScrollY -= scrollY;
  }
  if (clipped) {
    // The scrollbar is deferred: it belongs above everything in this container, positioned and
    // sticky descendants included, so it is drawn once the stacking context around the box has
    // painted (see paintContext).
    if (draw && el instanceof Element) pendingBars.push({ el, x, y, opacity });
    if (!propagatesBodyOverflow(el)) popContentClip();
  }
  // A collapsing table paints its whole border grid, above the backgrounds of its cells but below
  // the inline content held back above: the lines are shared between neighbours, so only the
  // table can draw them (see layout/table.ts).
  if (grid) {
    holdDepth--;
    if (draw) {
      for (let i = 0; i + 6 < el.tborder.length; i += 7) {
        const gx = x + el.tborder[i];
        const gy = boxY + el.tborder[i + 1];
        const gw = el.tborder[i + 2];
        const gh = el.tborder[i + 3];
        const style = el.tborder[i + 5];
        // Each piece of the grid is one side of the winning border, drawn in that border's style.
        paintBorderSide(style, withOpacity(el.tborder[i + 4], opacity), gx, gy, gw, gh, el.tborder[i + 6] === 1, true);
      }
      paintHeld(holdStart);
    }
  }
  // The outline is drawn last, over the box's content, and outside its border box.
  if (draw && el instanceof Element && el.sv[P.P_RESIZE] !== 0 &&
    (el.sv[P.P_OVERFLOW_X] !== P.OV_VISIBLE || el.sv[P.P_OVERFLOW_Y] !== P.OV_VISIBLE)) {
    paintResizeGrip(el, x, y, opacity);
  }
  // A box the fill cut through has no outline of its own: each of its columns would need one, and
  // an outline draws around the box's whole box, not around a piece of it.
  if (draw && frags.length === 0) paintOutline(el, x, y, opacity);
  if (clippedToRect) hostClipPop();
}

// ---------------------------------------------------------------------------
// Culling
//
// A full paint records every box on the page, including the rows far outside the scrollport that
// happen to be in it: a three-thousand-row list pays for all of them to show a dozen. A box whose
// painting cannot leave its own border box is skipped when it misses the clip it sits in, so a
// paint costs what the visible boxes cost.

/** Room a box's own painting may need beyond its border box: an outline, an antialiased edge. */
const CULL_SLACK = 24;

/** Culling can be turned off for a comparison run: `NATIVE_PAINT_CULL=0`. */
let cullOff = -1;
function cullingOn(): boolean {
  if (cullOff < 0) {
    const env = process.env.NATIVE_PAINT_CULL;
    cullOff = env !== undefined && env === "0" ? 1 : 0;
  }
  return cullOff === 0;
}

/**
 * Whether the box paints nothing outside its border box: no children, no shadow, transform,
 * filter, mask or clip-path, no positioned box, and no text overflowing it. Anything else could
 * reach into the clip from a box that misses it by its own rect, and is painted as before.
 */
function paintsInsideBox(el: Node): boolean {
  if (!(el instanceof Element)) return false;
  if (el.vtext !== 0) return false;
  // A text node is this box's own inline content, painted inside it; an element child can paint
  // anywhere, including outside this box.
  for (const kid of childOrder(el)) if (kid instanceof Element) return false;
  if (hasTransform(el) || effectKind(el) !== 0) return false;
  if (hasClipPath(el) || hasMask(el) || willChangeBits(el) !== 0) return false;
  const pos = el.sv[P.P_POSITION];
  if (pos === P.POS_ABSOLUTE || pos === P.POS_FIXED || pos === P.POS_STICKY) return false;
  if (boxShadows(el).length > 0) return false;
  // A text shadow is painted beyond the glyphs, outside the box as easily as inside it.
  if (textShadows(el).length > 0) return false;
  if (el.sv[P.P_OUTLINE_STYLE] !== 0 && el.sv[P.P_OUTLINE_WIDTH] > 0) return false;
  // A replaced box or a control draws what its own object says, not only its box's decoration.
  const name = el.localName;
  if (name === "img" || name === "canvas" || name === "video" || name === "svg" ||
      name === "input" || name === "select" || name === "textarea") return false;
  // Text that outgrows its box is drawn past the box's edge.
  if (el.naturalW > el.w + 0.5 || el.naturalH > el.h + 0.5) return false;
  return true;
}

/**
 * Whether a box and everything under it stays inside the box's own rectangle: in-flow children
 * only, no shadow, transform, filter, mask, outline or replaced content anywhere, and every
 * child's laid-out box inside its parent's. A positioned box's paint is then bounded by its own
 * rectangle, and a clip that misses it can skip the whole subtree.
 */
let fitsFull = -1;
let fitsLocal = -1;
const fitsCache = new Map<Node, boolean>();
function subtreeFitsBox(el: Node): boolean {
  // Counted against each and every layout pass, full or local: a pass can grow a box inside its
  // parent, which changes the answer for every box above it.
  if (fitsFull !== layoutPasses.full || fitsLocal !== layoutPasses.local) {
    fitsFull = layoutPasses.full;
    fitsLocal = layoutPasses.local;
    fitsCache.clear();
  }
  const hit = fitsCache.get(el);
  if (hit !== undefined) return hit;
  const fits = computeFits(el);
  fitsCache.set(el, fits);
  return fits;
}

function computeFits(el: Node): boolean {
  if (!(el instanceof Element)) return true;
  if (el.vtext !== 0) return false;
  if (hasTransform(el) || effectKind(el) !== 0) return false;
  if (hasClipPath(el) || hasMask(el) || willChangeBits(el) !== 0) return false;
  if (boxShadows(el).length > 0 || textShadows(el).length > 0) return false;
  if (el.sv[P.P_OUTLINE_STYLE] !== 0 && el.sv[P.P_OUTLINE_WIDTH] > 0) return false;
  const name = el.localName;
  if (name === "img" || name === "canvas" || name === "video" || name === "svg" ||
      name === "input" || name === "select" || name === "textarea") return false;
  if (el.naturalW > el.w + 0.5 || el.naturalH > el.h + 0.5) return false;
  for (const c of childOrder(el)) {
    if (c.sv[P.P_DISPLAY] === P.D_NONE) continue;
    const pos = c.sv[P.P_POSITION];
    if (pos === P.POS_ABSOLUTE || pos === P.POS_FIXED || pos === P.POS_STICKY) return false;
    // A child that grew out of the box (a negative margin, an overflowing line) can draw there.
    if (c.x < -0.5 || c.y < -0.5 || c.x + c.w > el.w + 0.5 || c.y + c.h > el.h + 0.5) return false;
    if (!computeFits(c)) return false;
  }
  return true;
}

/**
 * Whether a rectangle in the page's screen space can reach the active clip. Used where a box is
 * painted in screen coordinates (a positioned box): with a scroll transform open the clip's own
 * space is not the screen's, and the box is painted rather than guessed at.
 */
function screenInClip(x: number, y: number, w: number, h: number): boolean {
  if (openScrollX !== 0 || openScrollY !== 0) return true;
  return reachesClip(x, y, w, h, activeClip());
}

/** Whether a box could reach the clip it is painted inside, with the room a border or edge needs. */
function reachesClip(x: number, y: number, w: number, h: number, clip: number[] | null): boolean {
  const cx = clip === null ? 0 : clip[1];
  const cy = clip === null ? 0 : clip[2];
  const cw = clip === null ? viewport.w : clip[3];
  const ch = clip === null ? viewport.h : clip[4];
  return x - CULL_SLACK < cx + cw && x + w + CULL_SLACK > cx &&
         y - CULL_SLACK < cy + ch && y + h + CULL_SLACK > cy;
}

/** The innermost clip the paint is inside, or null at the page's own top. */
function activeClip(): number[] | null {
  return paintedClips.length > 0 ? paintedClips[paintedClips.length - 1] : null;
}

/** Paints the floats of a box's children in tree order, each with its own content. */
function paintFloats(kids: Node[], x: number, y: number, opacity: number): void {
  for (const c of kids) {
    if (paintedByContext(c)) continue;
    // An item painted its own floats along with itself (see `paintsAsUnit`).
    if (paintsAsUnit(c)) continue;
    if (!isFloat(c)) paintBox(c, x + c.x, y + c.y, opacity, false, null, 2);
    else if (holdDepth > 0) holdBox(c, x + c.x, y + c.y, opacity);
    else paintBox(c, x + c.x, y + c.y, opacity, false, null, 1);
  }
}

/**
 * The scroll containers whose content transform the paint is inside a wrapper for, while it
 * paints a positioned box: a box painted inside another box's wrapper already moves with the
 * scroll and takes no command of its own for the same container.
 */
const wrappedScrollers: Node[] = [];
/** The scroll containers whose content transform the paint is inside, outermost first: a box
 *  painted in there already moves with that scroll and takes no wrapper for it. */
const scrolledContent: Node[] = [];

/**
 * Pushes a transform command for each scroll container this positioned box was painted outside
 * of, up to the nearest box that paints its own layer (whose painting is inside every container
 * above it). Answers the containers it wrapped, for the caller to unwrap.
 */
function pushOutsideScrollTransforms(el: Node): Node[] {
  const pushed: Node[] = [];
  for (let p: Node | null = el.parentElement; p !== null; p = p.parentElement) {
    if (p instanceof Element && wrappedScrollers.indexOf(p) < 0 && scrolledContent.indexOf(p) < 0 &&
      scrollContentRecorded(p)) {
      noteOutsideScrollTransform(p, hostTransformPushIndexed(el.serial, P.PK_TRANSFORM, 1, 0, 0, 1, 0, 0));
      wrappedScrollers.push(p);
      pushed.push(p);
    }
    if (p instanceof Element && paintsItsOwnLayer(p)) break;
  }
  return pushed;
}

/** Paints one positioned box and, when it is a stacking context, its own positioned layer. */
function paintPositioned(el: Node, parentOpacity: number): void {
  if (el.sv[P.P_DISPLAY] === P.D_NONE) return;
  const p = absolutePosition(el);
  // A positioned box whose own rectangle, children and shadows all stay inside it is skipped
  // when the clip misses that rectangle, as the in-flow walk skips its children.
  if (cullingOn() && subtreeFitsBox(el) && !screenInClip(p[0], p[1], el.w, el.h)) return;
  const clips = clipChain(el);
  for (const r of clips) hostClipPush(el.serial, P.PK_CLIP_RECT, r[0], r[1], r[2], r[3], 0);
  // This box is painted by the context around it, outside the content transform of every scroll
  // container between it and that context. It still scrolls with the content: it carries a
  // transform of its own for each, identity where it was painted, which the scroll edits along
  // with the content transform instead of the container painting the page again (compositor.ts).
  // The ancestor clips stay outside those commands: a scrollport does not move with its content.
  // A fixed box doesn't scroll and carries none.
  const scrolling = el.sv[P.P_POSITION] === P.POS_FIXED ? [] : pushOutsideScrollTransforms(el);
  // A transformed box pushes its matrix in paintBox, which then paints the box's own context
  // inside it; going through paintContext here would paint that context's positioned layer a
  // second time, outside the transform.
  positionedDepth++;
  if (!hasTransform(el) && paintsItsOwnLayer(el)) paintContext(el, p[0], p[1], parentOpacity, false);
  else paintBox(el, p[0], p[1], parentOpacity, false, null, 1);
  positionedDepth--;
  for (let k = scrolling.length - 1; k >= 0; k--) {
    wrappedScrollers.pop();
    hostStatePop();
  }
  for (let k = 0; k < clips.length; k++) hostClipPop();
}

/**
 * Paints a stacking context: its in-flow content, then its positioned layer by z-index. `wrapped`
 * says the caller already pushed this box's transform.
 */
function paintContext(el: Node, x: number, y: number, parentOpacity: number, skipBg: boolean,
  wrapped: boolean = false): void {
  if (el.sv[P.P_DISPLAY] === P.D_NONE) return;
  if (parentOpacity * el.sv[P.P_OPACITY] <= 0) return;
  // An `opacity` below 1 makes the box a transparent group: its drawings go into the layer its
  // effect push opens and fade once, together, rather than one at a time (CSS Color 3 §3.2).
  const group = el.sv[P.P_OPACITY] < 1;
  const opacity = group ? parentOpacity : parentOpacity * el.sv[P.P_OPACITY];
  const list: Node[] = [];
  collectPositioned(el, list);
  // Painting order within a context is by z-index, and tree order among equals; negative
  // z-index boxes go below the in-flow content, the rest above it.
  list.sort((a, b) => zIndexOf(a) - zIndexOf(b));
  const below: Node[] = [];
  const above: Node[] = [];
  for (const c of list) (zIndexOf(c) < 0 ? below : above).push(c);
  // The box's own background and border come first, then the negative z-index boxes, then its
  // in-flow content, then the rest of the positioned layer. Each scrollbar joins the layer as soon
  // as the last positioned box inside its own box has been painted: above the content it must
  // cover, below anything the context paints after it (see flushBarsReady).
  const bars = pendingBars.length;
  paintBox(el, x, y, parentOpacity, skipBg, below, 1, wrapped, group);
  // A box that paints through a transform, a layer or a clip paints its own positioned layer
  // inside that wrapper, so the boxes above its content were already painted there, scrollbars
  // included: painting them again here would draw them a second time, outside the wrapper.
  const byWrapper = !wrapped && paintsGroup(el);
  if (!byWrapper) {
    for (let i = 0; i < above.length; i++) {
      flushBarsReady(bars, above, i);
      paintPositioned(above[i], opacity);
    }
    flushScrollbars(bars);
  }
}

/**
 * Paints an outline: a ring of `outline-width` around the border box, moved out by
 * `outline-offset`. It takes no room in layout, so it can overlap whatever is beside the box.
 * The four sides are drawn in the outline's style, as border sides are, and `auto` paints solid.
 */
function paintOutline(el: Node, x: number, y: number, opacity: number): void {
  const style = el.sv[P.P_OUTLINE_STYLE];
  if (style === P.OLS_NONE) return;
  const t = el.sv[P.P_OUTLINE_WIDTH];
  if (!(t > 0)) return;
  const o = el.sv[P.P_OUTLINE_OFFSET];
  const X = x - o - t;
  const Y = y - o - t;
  const W = el.w + 2 * (o + t);
  const H = el.h + 2 * (o + t);
  if (W <= 0 || H <= 0) return;
  const c = el.sv[P.P_OUTLINE_COLOR];
  const color = withOpacity(c < 0 ? el.sv[P.P_COLOR] : c, opacity);
  if (style === P.OLS_AUTO) {
    hostFillRing(X - 1, Y - 1, W + 2, H + 2, 6, t + 2, withOpacity(systemFocusRingColor(), opacity));
    return;
  }
  const drawn = style + 1;
  const sideH = Math.max(0, H - 2 * t);
  paintBorderSide(drawn, color, X, Y, W, t, false, true);
  paintBorderSide(drawn, color, X, Y + H - t, W, t, false, false);
  paintBorderSide(drawn, color, X, Y + t, t, sideH, true, true);
  paintBorderSide(drawn, color, X + W - t, Y + t, t, sideH, true, false);
}

/** Overlay scrollbar: shown while scrolling (and briefly after), like macOS. */

/** How wide a box's scrollbar is: the platform's six pixels, or three under `thin`. */
function scrollbarThickness(el: Node): number {
  return el.sv[P.P_SCROLLBAR_WIDTH] === P.SBW_THIN ? 3 : 6;
}

/** The colour its thumb takes: the one `scrollbar-color` names, else the platform's grey. */
function scrollbarThumbColor(el: Node): number {
  return el.sv[P.P_SCROLLBAR_COLOR] < 0 ? 0x00000066 : el.sv[P.P_SCROLLBAR_COLOR];
}

/** The scrollbar thumb down a scroll box's right edge, at the box's scroll position. */
function paintScrollbarThumb(el: Element, right: number, top: number, view: number, total: number,
    offset: number, opacity: number): void {
  const w = scrollbarThickness(el);
  const track = view - 4;
  const thumb = Math.max(24, (track * view) / total);
  // The thumb rides a transform of its own: on a scrolled frame the compositor moves it without
  // painting the page (see compositor.ts, which computes the same shift from the element).
  const shift = ((track - thumb) * offset) / (total - view);
  noteScrollBar(el, hostTransformPushIndexed(el.serial, P.PK_SCROLL, 1, 0, 0, 1, 0, shift), false);
  noteScrollThumb(el, right - (w + 3), top + 2 + shift, w, thumb, false);
  hostFillRect(right - (w + 3), top + 2, w, thumb, w / 2, withOpacity(scrollbarThumbColor(el), opacity));
  hostStatePop();
}

/** The same thumb along a scroll box's bottom edge, for its horizontal scroll. */
function paintScrollbarThumbH(el: Element, left: number, bottom: number, view: number, total: number,
    offset: number, opacity: number): void {
  const w = scrollbarThickness(el);
  const track = view - 4;
  const thumb = Math.max(24, (track * view) / total);
  const shift = ((track - thumb) * offset) / (total - view);
  noteScrollBar(el, hostTransformPushIndexed(el.serial, P.PK_SCROLL, 1, 0, 0, 1, shift, 0), true);
  noteScrollThumb(el, left + 2 + shift, bottom - (w + 3), thumb, w, true);
  hostFillRect(left + 2, bottom - (w + 3), thumb, w, w / 2, withOpacity(scrollbarThumbColor(el), opacity));
  hostStatePop();
}

function paintScrollbar(el: Element, x: number, y: number, opacity: number): void {
  // The root's scrollbar is the viewport's, drawn at the window's edge instead (paintViewportScrollbar).
  if ((el as Node) === document.documentElement) return;
  // `scrollbar-width: none` draws no bar however far the content reaches.
  if (el.sv[P.P_SCROLLBAR_WIDTH] === P.SBW_NONE) {
    noteScrollBarState(el, BAR_NONE);
    return;
  }
  const alwaysX = el.sv[P.P_OVERFLOW_X] === P.OV_SCROLL;
  const alwaysY = el.sv[P.P_OVERFLOW_Y] === P.OV_SCROLL;
  if (!alwaysX && !alwaysY && Date.now() - el.lastScroll > P.SCROLLBAR_VISIBLE_MS) {
    // A faded bar comes back with the next scroll, which only a paint can draw.
    noteScrollBarState(el, BAR_FADED);
    return;
  }
  noteScrollBarState(el, BAR_DRAWN);
  // `overflow: hidden` and `overflow: clip` never show a bar, however far the content reaches.
  const barX = el.sv[P.P_OVERFLOW_X] === P.OV_AUTO || alwaysX;
  const barY = el.sv[P.P_OVERFLOW_Y] === P.OV_AUTO || alwaysY;
  const total = el.scrollHeight;
  const view = el.clientHeight;
  if (barY && total > view + 0.5) {
    const bt = borderPx(el.sv[P.P_BORDER_TOP_WIDTH]);
    const br = borderPx(el.sv[P.P_BORDER_RIGHT_WIDTH]);
    paintScrollbarThumb(el, x + el.w - br, y + bt, view, total, el.scrollY, opacity);
  }
  const totalW = el.scrollWidth;
  const viewW = el.clientWidth;
  if (barX && totalW > viewW + 0.5) {
    const bl = borderPx(el.sv[P.P_BORDER_LEFT_WIDTH]);
    const bb = borderPx(el.sv[P.P_BORDER_BOTTOM_WIDTH]);
    paintScrollbarThumbH(el, x + bl, y + el.h - bb, viewW, totalW, el.scrollX, opacity);
  }
}

/** The viewport's own scrollbars, for the page the root element scrolls. */
function paintViewportScrollbar(root: Element): void {
  // The page's scrollbar follows the root's `scrollbar-width` as any box's does.
  if (root.sv[P.P_SCROLLBAR_WIDTH] === P.SBW_NONE) {
    noteScrollBarState(root, BAR_NONE);
    return;
  }
  const scrollsX = viewportScrollsX();
  const scrollsY = viewportScrollsY();
  if (!scrollsX && !scrollsY) {
    noteScrollBarState(root, BAR_NONE);
    return;
  }
  const always = viewportOverflowX() === P.OV_SCROLL || viewportOverflowY() === P.OV_SCROLL;
  if (!always && Date.now() - root.lastScroll > P.SCROLLBAR_VISIBLE_MS) {
    noteScrollBarState(root, BAR_FADED);
    return;
  }
  noteScrollBarState(root, BAR_DRAWN);
  const total = root.scrollHeight;
  const view = viewport.h;
  if (scrollsY && total > view + 0.5) paintScrollbarThumb(root, viewport.w, 0, view, total, root.scrollY, 1);
  const totalW = root.scrollWidth;
  const viewW = viewport.w;
  if (scrollsX && totalW > viewW + 0.5) paintScrollbarThumbH(root, 0, viewport.h, viewW, totalW, root.scrollX, 1);
}

/** A display list of only the damaged regions: the page is walked once with a clip made of every
 *  damaged rectangle, so the commands recorded are the ones the retained backing has to repaint. */
export function paintRootDamage(root: Node, rects: number[][]): void {
  clearRecorded();
  clearPending();
  wrappedScrollers.length = 0;
  scrolledContent.length = 0;
  readHighlightCovers();
  beginSelectionPaint();
  openScrollX = 0;
  openScrollY = 0;
  const background = canvasColor(root);
  const spec = rectsText(rects);
  // On a compositing window a damaged frame is patched over the picture the last frame presented:
  // when the host has no picture to patch, or can't place the damaged boxes in it, it answers no
  // and the frame paints the whole page instead.
  if (hostCompositorOn() !== 0 && hostDamageCanMerge(damageSerialsText(), spec) === 0) {
    paintRoot(root);
    return;
  }
  // The list from here holds only the damaged regions, so a scroll of what it paints can't be
  // composited from it: noteScroll records that for the scroll containers it walks.
  paintState.partial = true;
  hostDamageBegin(background, spec);
  // One clip holding every damaged rectangle, so the walk happens once. Culling uses their
  // bounding box: a box outside it is skipped, and one inside is painted (the clip cuts the rest).
  const bbox = rectsBBox(rects);
  hostClipPushShape(root.serial, P.PK_CLIP_SHAPE, rectsPath(rects), 0);
  paintedClips.push([root.serial, bbox[0], bbox[1], bbox[2], bbox[3], 0, 0, 0, 0, 0, 0, 0, 0]);
  clipScrollX.push(openScrollX);
  clipScrollY.push(openScrollY);
  canvasEl = canvasSource(root);
  for (const r of rects) hostFillRect(r[0], r[1], r[2], r[3], 0, background);
  if (canvasEl !== null) paintCanvasImages(canvasEl, root, canvasEl.sv[P.P_OPACITY]);
  paintContext(root, root.x, root.y, 1, true);
  paintViewportScrollbar(root as Element);
  paintEditableCaret();
  paintTopLayer();
  paintDatePicker();
  paintSelectPopup();
  paintDevHighlight();
  popContentClip();
  canvasEl = null;
  if (damageVerify.on) hostVerifyDamage(spec, viewport.w, viewport.h);
  hostPresentDamage(spec, widthOf(root), heightOf(root));
  endSelectionPaint();
}

/** The damage rectangles as the host reads them: "x,y,w,h" for each, joined by ";". */
function widthOf(root: Node): number { return viewport.w; }
function heightOf(root: Node): number { return viewport.h; }

function rectsText(rects: number[][]): string {
  let out = "";
  for (let i = 0; i < rects.length; i++) {
    if (i > 0) out += ";";
    out += rects[i][0] + "," + rects[i][1] + "," + rects[i][2] + "," + rects[i][3];
  }
  return out;
}

/** The damage rectangles as closed subpaths of one clip shape. */
function rectsPath(rects: number[][]): string {
  let out = "";
  for (let i = 0; i < rects.length; i++) {
    const r = rects[i];
    if (i > 0) out += ";";
    out += r[0] + "," + r[1] + " " + (r[0] + r[2]) + "," + r[1] + " " +
      (r[0] + r[2]) + "," + (r[1] + r[3]) + " " + r[0] + "," + (r[1] + r[3]);
  }
  return out;
}

function rectsBBox(rects: number[][]): number[] {
  let x0 = rects[0][0], y0 = rects[0][1], x1 = x0 + rects[0][2], y1 = y0 + rects[0][3];
  for (let i = 1; i < rects.length; i++) {
    const r = rects[i];
    if (r[0] < x0) x0 = r[0];
    if (r[1] < y0) y0 = r[1];
    if (r[0] + r[2] > x1) x1 = r[0] + r[2];
    if (r[1] + r[3] > y1) y1 = r[1] + r[3];
  }
  return [x0, y0, x1 - x0, y1 - y0];
}

export function paintRoot(root: Node): void {
  // A full paint records every box. The last damaged frame's limit would otherwise still cull the
  // walk to that frame's damaged boxes and rectangles, leaving the rest of the page out of a list
  // that replaces the whole picture: a snapshot taken after a click, or a damaged frame the host
  // couldn't patch and asked to paint whole, came out mostly blank.
  damage.limited = false;
  recordFull(root, true);
}

/**
 * Records the whole page without presenting it, for the damage verification pass: the painter
 * records this frame flat, then the damaged list, and the host compares the two.
 */
export function paintRootReference(root: Node): void {
  const limited = damage.limited;
  damage.limited = false;
  recordFull(root, false);
  damage.limited = limited;
}

function recordFull(root: Node, present: boolean): void {
  // This pass records every composited element anew; the tags and pending moves the last frame
  // left are behind it.
  clearRecorded();
  clearPending();
  paintState.partial = false;
  wrappedScrollers.length = 0;
  scrolledContent.length = 0;
  readHighlightCovers();
  beginSelectionPaint();
  // A pass that left its bookkeeping behind (an aborted paint) starts clean: the offsets and the
  // clips are pushed and popped in pairs within one pass.
  openScrollX = 0;
  openScrollY = 0;
  hostBegin(canvasColor(root));
  // The canvas takes the root's (or body's) background as a whole: its colour and its images.
  canvasEl = canvasSource(root);
  if (canvasEl !== null) {
    paintCanvasImages(canvasEl, root, canvasEl.sv[P.P_OPACITY]);
  }
  // The root's (or body's) background has already been used for the whole canvas.
  paintContext(root, root.x, root.y, 1, true);
  paintViewportScrollbar(root as Element);
  paintEditableCaret();
  paintTopLayer();
  // A date or time field's picker paints above everything, as a browser's own popup does, and so
  // does a select's open picker.
  paintDatePicker();
  paintSelectPopup();
  canvasEl = null;
  paintDevHighlight();
  // Every box's ink, for the damaged frames that follow to cull against.
  recordFullInk(root);
  if (present) hostPresent(widthOf(root), heightOf(root));
  endSelectionPaint();
}

/**
 * Paints the top layer: open popovers and modal dialogs, bottom-most first, each at its own
 * place in the viewport rather than where it sits in the tree. A modal dialog's ::backdrop fills
 * the viewport under it.
 */
function paintTopLayer(): void {
  const layer = topLayerElements();
  if (layer.length === 0) return;
  paintingTopLayer = true;
  for (const el of layer) {
    // Only a modal dialog draws a ::backdrop: a popover on the top layer has none, and a dialog
    // the page doesn't render draws neither itself nor its backdrop.
    if (el instanceof HTMLDialogElement && el.isModal && display(el) !== P.D_NONE) paintBackdrop(el);
    paintContext(el, el.x, el.y, 1, false);
  }
  paintingTopLayer = false;
}

/**
 * Paints the ::backdrop a top-layer element carries: the whole viewport, under the element and
 * over everything below it in the layer. The box's own opacity and backdrop-filter count, as
 * they do in a browser; the UA sheet keeps the carrier display:none so it never paints in the
 * tree, which is why this reads its style rather than laying the box out.
 */
function paintBackdrop(el: Element): void {
  let backdrop: Node | null = el.backdropPseudo;
  if (backdrop === null) {
    for (const kid of boxKids(el)) if (kid.pseudoKind === P.PE_BACKDROP) backdrop = kid;
    if (backdrop === null) return;
  }
  // A backdrop the author hides is not drawn; one positioned and sized by its own style is
  // drawn in that box, which is the whole viewport for the sheet's fixed inset:0.
  if (backdrop.sv[P.P_DISPLAY] === P.D_NONE) return;
  let bx = 0;
  let by = 0;
  let bw = viewport.w;
  let bh = viewport.h;
  // A backdrop is always a positioned box, whatever position its style says (static and relative
  // compute to absolute in the top layer), so its insets and size decide the box.
  {
    const leftAuto = backdrop.su[P.P_LEFT] === P.U_AUTO;
    const topAuto = backdrop.su[P.P_TOP] === P.U_AUTO;
    const rightAuto = backdrop.su[P.P_RIGHT] === P.U_AUTO;
    const bottomAuto = backdrop.su[P.P_BOTTOM] === P.U_AUTO;
    bx = leftAuto ? 0 : len(backdrop, P.P_LEFT, viewport.w);
    by = topAuto ? 0 : len(backdrop, P.P_TOP, viewport.h);
    if (backdrop.su[P.P_WIDTH] !== P.U_AUTO) bw = len(backdrop, P.P_WIDTH, viewport.w);
    else bw = viewport.w - bx - (rightAuto ? 0 : len(backdrop, P.P_RIGHT, viewport.w));
    if (backdrop.su[P.P_HEIGHT] !== P.U_AUTO) bh = len(backdrop, P.P_HEIGHT, viewport.h);
    else bh = viewport.h - by - (bottomAuto ? 0 : len(backdrop, P.P_BOTTOM, viewport.h));
    if (bw < 0) bw = 0;
    if (bh < 0) bh = 0;
  }
  const color = backdrop.sv[P.P_BACKGROUND_COLOR];
  const opacity = backdrop.sv[P.P_OPACITY];
  const filters = elementFilter(backdrop);
  const behind = elementBackdropFilter(backdrop);
  const layered = filters.length > 0 || behind.length > 0;
  if (layered) hostEffectPush(backdrop.serial, P.PK_EFFECT, bx, by, bw, bh, filterSpec(backdrop, filters, behind));
  if ((color & 255) * opacity >= 1) {
    hostFillRect(bx, by, bw, bh, 0, withOpacity(color, opacity));
  }
  if (layered) hostEffectPop();
}

/** True while the top-layer elements are being painted, which the tree walk skips. */
let paintingTopLayer = false;

/**
 * Whether the node is inside an inert subtree. Its boxes draw, but take no pointer events, so
 * the hit test falls through them to whatever they cover.
 */
function inertSubtree(el: Node): boolean {
  let n: Node | null = el;
  while (n !== null) {
    if (n instanceof Element && (n.inert || n.sv[P.P_INTERACTIVITY] === P.IA_INERT)) return true;
    n = n.parentNode;
  }
  return false;
}

export function hitTest(el: Node, px: number, py: number, ox: number, oy: number): Node | null {
  if (el.sv[P.P_DISPLAY] === P.D_NONE) return null;
  let hit = hitContext(el, px, py, ox + el.x, oy + el.y);
  // A generated box isn't in the DOM: pointers over it reach the element that generates it. A
  // scroll marker keeps the hit: it is the thing a click activates.
  while (hit !== null && hit.pseudoKind !== P.PE_NONE && hit.pseudoKind !== P.PE_SCROLL_MARKER &&
    hit.parentElement !== null) hit = hit.parentElement;
  return hit;
}

/**
 * Every element the pointer could reach at a viewport point, topmost first: the whole stack a
 * single hit test walks past, which is what elementsFromPoint() answers with. Chrome leaves out a
 * box the pointer can't reach — see-through or inert — and an ancestor that has no box under the
 * point, so this is the single test's walk, recording every hit instead of stopping at the first.
 */
export function hitTestAll(el: Node, px: number, py: number, ox: number, oy: number): Element[] {
  const out: Node[] = [];
  if (el.sv[P.P_DISPLAY] === P.D_NONE) return [];
  hitContext(el, px, py, ox + el.x, oy + el.y, false, out);
  const els: Element[] = [];
  for (const n of out) {
    const e = n.pseudoKind !== P.PE_NONE && n.parentElement !== null ? n.parentElement : n;
    if (e instanceof Element && els.indexOf(e) < 0) els.push(e);
  }
  return els;
}

/**
 * Whether a hit ends the walk. A single hit test stops at the first one; a collecting pass records
 * it and carries on behind it, which is how the stack under the pointer is read.
 */
function endsWalk(out: Node[] | null, hit: Node): boolean {
  if (out === null) return true;
  out.push(hit);
  return false;
}

// The DOM's elementFromPoint() and elementsFromPoint() ask this module, which owns the hit test.
setPointHitsHook((x, y) => hitTestAll(document.documentElement, x, y, 0, 0));

/** Hit tests a stacking context: its positioned layer first, then its in-flow content. */
function hitContext(el: Node, px: number, py: number, x: number, y: number,
  mapped: boolean = false, out: Node[] | null = null): Node | null {
  if (el.sv[P.P_BACKFACE_VISIBILITY] === P.BFV_HIDDEN && isBackFacing(el)) return null;
  if (!mapped && hasTransform(el)) {
    const p = toLocalPoint(el, px, py, x, y);
    if (p === null) return null;
    px = p[0];
    py = p[1];
    mapped = true;
  }
  const list: Node[] = [];
  collectPositioned(el, list, false);
  list.sort((a, b) => zIndexOf(a) - zIndexOf(b));
  // Reverse painting order, so the topmost box wins: positive and zero z-index first, then the
  // in-flow content, then the negative z-index boxes.
  for (let i = list.length - 1; i >= 0; i--) {
    if (zIndexOf(list[i]) < 0) continue;
    const hit = hitPositioned(list[i], px, py, out);
    if (hit !== null && endsWalk(out, hit)) return hit;
  }
  const inFlow = hitInFlow(el, px, py, x, y, mapped, out);
  if (inFlow !== null && endsWalk(out, inFlow)) return inFlow;
  for (let i = list.length - 1; i >= 0; i--) {
    if (zIndexOf(list[i]) >= 0) continue;
    const hit = hitPositioned(list[i], px, py, out);
    if (hit !== null && endsWalk(out, hit)) return hit;
  }
  return null;
}

function hitPositioned(el: Node, px: number, py: number, out: Node[] | null): Node | null {
  if (el.sv[P.P_DISPLAY] === P.D_NONE || inertSubtree(el)) return null;
  if (!insideAny(clipChain(el), px, py)) return null;
  const p = absolutePosition(el);
  // As in the in-flow walk: a positioned box that keeps everything inside its own rectangle is
  // skipped when the point is outside it.
  if (cullingOn() && subtreeFitsBox(el) &&
      (px < p[0] || px >= p[0] + el.w || py < p[1] || py >= p[1] + el.h)) return null;
  // A box that paints its own layer is a stacking context, so its positioned layer is tested with it.
  return paintsItsOwnLayer(el) ? hitContext(el, px, py, p[0], p[1], false, out) : hitInFlow(el, px, py, p[0], p[1], false, out);
}

/** Hit tests the box and its in-flow subtree; positioned children belong to the context above. */
function hitInFlow(el: Node, px: number, py: number, x: number, y: number,
  mapped: boolean = false, out: Node[] | null = null): Node | null {
  if (el.sv[P.P_DISPLAY] === P.D_NONE || inertSubtree(el)) return null;
  if (el.sv[P.P_BACKFACE_VISIBILITY] === P.BFV_HIDDEN && isBackFacing(el)) return null;
  // A transformed box is tested in its own, untransformed space: the point is mapped back
  // through the matrix, and the box and its children are then ordinary boxes.
  if (!mapped && hasTransform(el)) {
    const p = toLocalPoint(el, px, py, x, y);
    if (p === null) return null;
    px = p[0];
    py = p[1];
    mapped = true;
  }
  if (!isReplaced(el) && (display(el) === P.D_INLINE || el.isTextNode)) {
    if (el.lines.length === 0) {
      const kids = childOrder(el);
      for (let i = kids.length - 1; i >= 0; i--) {
        const c = kids[i];
        if (paintedByContext(c)) continue;
        const hit = hitInFlow(c, px, py, x + el.x + c.x, y + el.y + c.y, false, out);
        if (hit !== null && endsWalk(out, hit)) return hit;
      }
      return null;
    }
  }
  // An element with `pointer-events: none` is see-through: the pointer reaches what is behind it,
  // and a descendant that asks for events again with `auto` can still be hit. A hidden box is not
  // a target either, but a descendant that says `visible` still is.
  const seeThrough = el.sv[P.P_POINTER_EVENTS] === P.PTR_NONE;
  const hidden = el.sv[P.P_VISIBILITY] !== P.VIS_VISIBLE;
  const inside = px >= x && px < x + el.w && py >= y && py < y + el.h;
  // A box clips its content on each axis its overflow says so: a point outside it is out of reach
  // when it is out on an axis the box clips. Body's overflow went to the viewport instead.
  if (!propagatesBodyOverflow(el)) {
    // The clip edge is the visual box overflow-clip-margin names, grown by the margin: a point
    // beyond it on an axis the box clips is out of reach, while the box's own area is where its
    // border box is (a replaced box still takes a hit over its padding).
    const cx = clipsX(el);
    const cy = clipsY(el);
    if (cx || cy) {
      const f: number[] = isReplaced(el) ? [x, y, el.w, el.h] : overflowClipBox(el, x, y);
      const gx = cx ? clipGrowth(el, P.P_OVERFLOW_X) : 0;
      const gy = cy ? clipGrowth(el, P.P_OVERFLOW_Y) : 0;
      if (cx && (px < f[0] - gx || px >= f[0] + f[2] + gx)) return null;
      if (cy && (py < f[1] - gy || py >= f[1] + f[3] + gy)) return null;
    }
  }
  // A replaced box draws no children of its own: an inline <svg>'s subtree is its picture, not
  // boxes, so nothing under it can be hit.
  const kids = isReplaced(el) ? [] : childOrder(el);
  for (let i = kids.length - 1; i >= 0; i--) {
    const c = kids[i];
    if (paintedByContext(c)) continue;
    const cx = x - el.scrollX + c.x;
    const cy = y - el.scrollY + c.y;
    // A box whose whole subtree stays inside its own rectangle can't be hit from outside it, so
    // the walk skips it: a point in the detail pane doesn't visit every row of the list beside it.
    if (cullingOn() && subtreeFitsBox(c) &&
        (px < cx || px >= cx + c.w || py < cy || py >= cy + c.h)) continue;
    const hit = hitInFlow(c, px, py, cx, cy, false, out);
    if (hit !== null && endsWalk(out, hit)) return hit;
  }
  // Inline fragments: a word belongs to the innermost inline element containing it, as long as
  // that element shows.
  const fy = y - el.scrollY;
  const fx0 = x - el.scrollX;
  for (let i = el.fragKind.length - 1; i >= 0; i--) {
    const fx = fx0 + el.fragX[i];
    const top = fy + el.fragTop[i];
    if (el.fragStyle[i].sv[P.P_VISIBILITY] !== P.VIS_VISIBLE) continue;
    if (px >= fx && px < fx + el.fragW[i] && py >= top && py < top + lineHeightPx(el.fragStyle[i])) {
      const frag = el.fragKind[i] === FRAG_TEXT ? el.fragOwner[i] : el.fragStyle[i];
      if (frag.sv[P.P_POINTER_EVENTS] !== P.PTR_NONE && endsWalk(out, frag)) return frag;
    }
  }
  if (inside && !seeThrough && !hidden && !el.isTextNode && (isReplaced(el) || display(el) !== P.D_INLINE)) {
    if (endsWalk(out, el)) return el;
  }
  return null;
}

export function viewportSize(): number[] {
  return [viewport.w, viewport.h];
}
